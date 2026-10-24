package markdown

import "../buffer"
import "../syntax"

// Highlighting for the plain-text view: Markdown elements mapped onto the code
// highlight colors, plus bold/italic/strikethrough styles. Fenced code is
// colored by its language's lexer.

Text_Style :: enum u8 {
	Bold,
	Italic,
	Strike,
}

Text_Styles :: bit_set[Text_Style;u8]

// Lines lexed upward from a visible fence body line to find its lexer state.
@(private = "file")
MAX_FENCE_LOOKBACK :: 2000

@(private = "file")
Painter :: struct {
	start: int, // document offset of hl[0]
	hl:    []syntax.Highlight,
	style: []Text_Styles,
}

@(private = "file")
paint :: proc(p: ^Painter, lo, hi: int, h: syntax.Highlight) {
	for i in max(lo, p.start) ..< min(hi, p.start + len(p.hl)) do p.hl[i - p.start] = h
}

@(private = "file")
paint_style :: proc(p: ^Painter, lo, hi: int, s: Text_Styles) {
	for i in max(lo, p.start) ..< min(hi, p.start + len(p.hl)) do p.style[i - p.start] += s
}

// Fills hl[i] and style[i] for document bytes [start, start+len(hl)).
highlight_range :: proc(doc: ^Doc, b: ^buffer.Buffer, start: int, hl: []syntax.Highlight, style: []Text_Styles) {
	for &x in hl do x = .None
	for &x in style do x = {}
	if len(hl) == 0 || len(doc.lines) == 0 do return
	p := Painter{start, hl, style}
	first := buffer.offset_to_line(b, start)
	last := min(buffer.offset_to_line(b, start + len(hl) - 1), len(doc.lines) - 1)
	labels := doc_labels(doc, b)
	spans := make([dynamic]Span, context.temp_allocator)
	fence: struct {
		rules: ^syntax.Lang_Rules,
		state: syntax.Lex_State,
		line:  int, // the line `state` is at the end of
	}
	fence.line = -1

	for i := first; i <= last; i += 1 {
		info := doc.lines[i]
		line_lo := buffer.line_start(b, i)
		text := string(buffer.read_alloc(b, line_lo, line_lo + int(info.len)))
		d := line_detail(doc, i, text)
		at :: proc(line_lo: int, x: i32) -> int {return line_lo + int(x)}

		for m in d.marks[:d.n_marks] {
			paint(&p, at(line_lo, m.lo), at(line_lo, m.hi), m.kind == .Quote ? .Punctuation : .Operator)
		}
		if quoted(doc, i) do paint(&p, at(line_lo, d.content[0]), line_lo + len(text), .Comment)
		if d.task != {} {
			paint(&p, at(line_lo, d.task[0]), at(line_lo, d.task[1]), .Task_Checked in info.flags ? .Keyword : .Operator)
		}

		#partial switch info.kind {
		case .Atx_Heading:
			paint(&p, at(line_lo, d.open[0]), at(line_lo, d.open[1]), .Punctuation)
			paint(&p, at(line_lo, d.open[1]), line_lo + len(text), .Keyword)
			paint_style(&p, at(line_lo, d.open[1]), line_lo + len(text), {.Bold})
			if d.close != {} do paint(&p, at(line_lo, d.close[0]), at(line_lo, d.close[1]), .Punctuation)
		case .Setext_Underline, .Thematic_Break, .Table_Delim, .Fence_Close, .Math_Fence, .Front_Matter_Fence:
			paint(&p, at(line_lo, d.content[0]), line_lo + len(text), .Punctuation)
		case .Fence_Open:
			paint(&p, at(line_lo, d.open[0]), line_lo + len(text), .Punctuation)
			paint(&p, at(line_lo, d.info[0]), at(line_lo, d.info[1]), .Type)
			fence.rules = syntax.rules_for(line_state(doc, i).fence_lang)
			fence.state, fence.line = {}, i
		case .Fence_Body:
			// Colored by language only when the fence names one.
			if line_state(doc, i).fence_lang == .None {
				paint(&p, at(line_lo, d.content[0]), line_lo + len(text), .String)
				continue
			}
			if fence.line != i - 1 {
				fence.rules = syntax.rules_for(line_state(doc, i).fence_lang)
				fence.state = fence_state_before(doc, b, fence.rules, i)
			}
			body := text[d.content[0]:]
			out := make([]syntax.Highlight, len(body), context.temp_allocator)
			fence.state = syntax.lex_line(fence.rules, fence.state, transmute([]u8)body, out)
			fence.line = i
			for h, k in out do paint(&p, at(line_lo, d.content[0]) + k, at(line_lo, d.content[0]) + k + 1, h)
		case .Indented_Code:
			paint(&p, at(line_lo, d.content[0]), line_lo + len(text), .String)
		case .Html:
			paint(&p, line_lo, line_lo + len(text), .Attribute)
		case .Front_Matter_Body:
			paint(&p, line_lo, line_lo + len(text), .Comment)
		case .Math_Body:
			paint(&p, line_lo, line_lo + len(text), .Number)
		case .Link_Ref_Def, .Footnote_Def:
			paint(&p, at(line_lo, d.label[0] - 1), at(line_lo, d.label[1] + 2), .Punctuation)
			paint(&p, at(line_lo, d.label[0]), at(line_lo, d.label[1]), info.kind == .Footnote_Def ? .Label : .Function)
			if info.kind == .Link_Ref_Def do paint(&p, at(line_lo, d.label[1] + 2), line_lo + len(text), .Attribute)
		}

		// Inline syntax, for the whole block at once, over the colors of its
		// lines painted above.
		lo, hi, ok := block_extent(doc, i)
		if !ok || info.kind == .Link_Ref_Def || i != min(hi, last) do continue
		heading := info.kind == .Atx_Heading || setext_heading(doc, hi) || is_table_header(doc, i)
		if info.kind == .Table_Row || is_table_header(doc, i) {
			highlight_table_row(&p, text, line_lo, d, heading)
			continue
		}
		bt := block_text(doc, b, lo, hi)
		clear(&spans)
		inline_parse(bt.text, labels, &spans)
		for s in bt.segs {
			if heading && doc.lines[s.line].kind == .Paragraph {
				paint(&p, s.doc_lo, s.doc_lo + s.hi - s.lo, .Keyword)
				paint_style(&p, s.doc_lo, s.doc_lo + s.hi - s.lo, {.Bold})
			}
		}
		paint_spans(&p, &bt, spans[:])
	}
}

// Whether the paragraph ending at line `last` is a setext heading.
setext_heading :: proc(doc: ^Doc, last: int) -> bool {
	return last + 1 < len(doc.lines) && doc.lines[last + 1].kind == .Setext_Underline
}

// Whether line i is inside a block quote.
quoted :: proc(doc: ^Doc, i: int) -> bool {
	s := line_state(doc, i)
	if doc.lines[i].kind == .Blank do return false
	for c in s.containers[:s.depth] do if c.kind == .Quote do return true
	return false
}

// The lexer state at the start of fence body line i, lexing up from its fence.
@(private = "file")
fence_state_before :: proc(doc: ^Doc, b: ^buffer.Buffer, rules: ^syntax.Lang_Rules, i: int) -> syntax.Lex_State {
	open := i - 1
	for open > 0 && i - open < MAX_FENCE_LOOKBACK && doc.lines[open].kind == .Fence_Body do open -= 1
	state: syntax.Lex_State
	for j in open + 1 ..< i {
		lo := buffer.line_start(b, j)
		text := string(buffer.read_alloc(b, lo, lo + int(doc.lines[j].len)))
		d := line_detail(doc, j, text)
		state = syntax.lex_line(rules, state, transmute([]u8)text[d.content[0]:], nil)
	}
	return state
}

@(private = "file")
highlight_table_row :: proc(p: ^Painter, text: string, line_lo: int, d: Line_Detail, heading: bool) {
	row := text[d.content[0]:]
	base := line_lo + int(d.content[0])
	spans := make([dynamic]Span, context.temp_allocator)
	cell_lo := 0
	for k := 0; k <= len(row); k += 1 {
		if k < len(row) && row[k] == '\\' {
			k += 1
			continue
		}
		if k < len(row) && row[k] != '|' do continue
		if k < len(row) do paint(p, base + k, base + k + 1, .Punctuation)
		cell := row[cell_lo:k]
		if heading do paint_style(p, base + cell_lo, base + k, {.Bold})
		clear(&spans)
		inline_parse(cell, nil, &spans)
		bt := Block_Text{text = cell, segs = {{doc_lo = base + cell_lo, lo = 0, hi = len(cell)}}}
		paint_spans(p, &bt, spans[:])
		cell_lo = k + 1
	}
}

@(private = "file")
paint_spans :: proc(p: ^Painter, bt: ^Block_Text, spans: []Span) {
	doc :: proc(bt: ^Block_Text, x: i32) -> int {return block_to_doc(bt, int(x))}
	for s in spans {
		lo, open_hi, close_lo, hi := doc(bt, s.lo), doc(bt, s.open_hi), doc(bt, s.close_lo), doc(bt, s.hi)
		switch s.kind {
		case .Emph:      paint_style(p, open_hi, close_lo, {.Italic})
		case .Strong:    paint_style(p, open_hi, close_lo, {.Bold})
		case .Strike:    paint_style(p, open_hi, close_lo, {.Strike})
		case .Highlight: paint(p, open_hi, close_lo, .Constant)
		case .Code:      paint(p, open_hi, close_lo, .String)
		case .Math:      paint(p, open_hi, close_lo, .Number)
		case .Html:      paint(p, lo, hi, .Attribute)
		case .Entity:    paint(p, lo, hi, .Escape)
		case .Escape, .Hard_Break:
		case .Link, .Image, .Wikilink:
			paint(p, open_hi, close_lo, .Function)
			paint(p, close_lo, hi, .Punctuation)
			if s.kind != .Wikilink && !s.reference do paint(p, doc(bt, s.url[0]), doc(bt, s.url[1]), .Attribute)
		case .Autolink, .Url:
			paint(p, open_hi, close_lo, .Attribute)
		case .Footnote_Ref:
			paint(p, open_hi, close_lo, .Label)
		}
		paint(p, lo, open_hi, .Punctuation)
		if s.kind != .Link && s.kind != .Image && s.kind != .Wikilink do paint(p, close_lo, hi, .Punctuation)
	}
}
