package markdown

import "core:strings"

import "../buffer"

// Queries over the parsed lines: the blocks whose text is parsed for inlines
// together, and structure found by looking at nearby lines.

// Longer paragraphs are parsed for inlines in pieces of this many lines, from
// their first line.
MAX_BLOCK_LINES :: 200

// One line's part of a block's inline text.
Segment :: struct {
	line:    int,
	doc_lo:  int, // document offset of text[lo]
	lo, hi:  int, // range in Block_Text.text
}

// The inline text of lines [first, last]: each line's content, joined by '\n'.
Block_Text :: struct {
	text:        string,
	segs:        []Segment,
	first, last: int,
}

// Whether line i continues the paragraph that line i-1 is part of.
@(private = "file")
continues_paragraph :: proc(doc: ^Doc, i: int) -> bool {
	l := doc.lines[i]
	if l.kind != .Paragraph || .Block_Start in l.flags || i == 0 do return false
	prev := doc.lines[i - 1].kind
	return prev == .Paragraph || prev == .Footnote_Def
}

// Whether line i is a table header (the line before a delimiter row).
is_table_header :: proc(doc: ^Doc, i: int) -> bool {
	return i + 1 < len(doc.lines) && doc.lines[i + 1].kind == .Table_Delim
}

// The lines of the inline block containing line i: a paragraph (with a setext
// underline, the lines above it) or a single line. ok = false for lines without
// inline content (code, fences, blank lines, ...).
block_extent :: proc(doc: ^Doc, i: int) -> (first, last: int, ok: bool) {
	if i < 0 || i >= len(doc.lines) do return
	#partial switch doc.lines[i].kind {
	case .Atx_Heading, .Table_Row, .Link_Ref_Def:
		return i, i, true
	case .Paragraph, .Footnote_Def:
		if is_table_header(doc, i) do return i, i, true
		// After the link reference definitions it may start with.
		first = block_first(doc, i)
		for first < i && !continues_paragraph(doc, first + 1) do first += 1
		first += (i - first) / MAX_BLOCK_LINES * MAX_BLOCK_LINES
		last = i
		for last + 1 < len(doc.lines) && last + 1 < first + MAX_BLOCK_LINES && continues_paragraph(doc, last + 1) && !is_table_header(doc, last + 1) {
			last += 1
		}
		return first, last, true
	}
	return
}

// Where a line's inline content starts and ends within the line.
content_range :: proc(doc: ^Doc, i: int, text: string, d: Line_Detail) -> (lo, hi: int) {
	lo, hi = int(d.content[0]), len(text)
	#partial switch doc.lines[i].kind {
	case .Atx_Heading:
		lo = int(d.open[1])
		if d.close != {} do hi = int(d.close[0])
	case .Footnote_Def, .Link_Ref_Def:
		// After "[label]:".
		if d.label[1] > 0 do lo = min(int(d.label[1]) + 2, hi)
	}
	for lo < hi && (text[lo] == ' ' || text[lo] == '\t') do lo += 1
	if d.task != {} do lo = min(int(d.task[1]) + 1, hi)
	return
}

// Reads the inline text of lines [first, last].
block_text :: proc(doc: ^Doc, b: ^buffer.Buffer, first, last: int) -> Block_Text {
	sb := strings.builder_make(context.temp_allocator)
	segs := make([]Segment, last - first + 1, context.temp_allocator)
	start := buffer.line_start(b, first)
	end := buffer.line_end(b, last)
	all := string(buffer.read_alloc(b, start, end))
	pos := 0
	for i in first ..= last {
		nl := strings.index_byte(all[pos:], '\n')
		line_end := nl < 0 ? len(all) : pos + nl
		text := all[pos:line_end]
		if len(text) > 0 && text[len(text) - 1] == '\r' do text = text[:len(text) - 1]
		lo, hi := content_range(doc, i, text, line_detail(doc, i, text))
		if i > first do strings.write_byte(&sb, '\n')
		segs[i - first] = {line = i, doc_lo = start + pos + lo, lo = strings.builder_len(sb), hi = strings.builder_len(sb) + hi - lo}
		strings.write_string(&sb, text[lo:hi])
		pos = line_end + 1
	}
	return {text = strings.to_string(sb), segs = segs, first = first, last = last}
}

// Document offset of position `at` in a block's text.
block_to_doc :: proc(bt: ^Block_Text, at: int) -> int {
	for s in bt.segs {
		if at <= s.hi do return s.doc_lo + max(at - s.lo, 0)
	}
	last := bt.segs[len(bt.segs) - 1]
	return last.doc_lo + last.hi - last.lo
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
