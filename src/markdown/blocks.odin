package markdown

import "core:strings"

import "../buffer"

// Grouping lines into the blocks whose text is parsed for inlines together, and
// the link reference labels those inlines resolve against.

// Lines scanned up or down to find a block's extent.
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
		first = i
		for first > 0 && i - first < MAX_BLOCK_LINES && continues_paragraph(doc, first) do first -= 1
		last = i
		for last + 1 < len(doc.lines) && last - i < MAX_BLOCK_LINES && continues_paragraph(doc, last + 1) && !is_table_header(doc, last + 1) {
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

// The labels of the document's link reference definitions, rebuilt when a
// definition line has changed.
doc_labels :: proc(doc: ^Doc, b: ^buffer.Buffer) -> ^Labels {
	if doc.labels_gen == doc.refdef_gen && doc.labels_built do return &doc.labels
	doc.labels_gen = doc.refdef_gen
	doc.labels_built = true
	clear(&doc.labels)
	for l, i in doc.lines {
		if l.kind != .Link_Ref_Def do continue
		start := buffer.line_start(b, i)
		text := string(buffer.read_alloc(b, start, start + int(l.len)))
		d := line_detail(doc, i, text)
		if d.label[1] <= d.label[0] do continue
		h := label_hash(text[d.label[0]:d.label[1]])
		if h not_in doc.labels do doc.labels[h] = i
	}
	return &doc.labels
}

// The destination of the link reference definition for `label`.
reference_destination :: proc(doc: ^Doc, b: ^buffer.Buffer, label: string) -> (dest: string, ok: bool) {
	i := doc_labels(doc, b)[label_hash(label)] or_return
	start := buffer.line_start(b, i)
	text := string(buffer.read_alloc(b, start, start + int(doc.lines[i].len)))
	d := line_detail(doc, i, text)
	rest := strings.trim_left_space(text[min(int(d.label[1]) + 2, len(text)):])
	if strings.has_prefix(rest, "<") {
		end := strings.index_byte(rest, '>')
		return rest[1:max(end, 1)], true
	}
	end := strings.index_any(rest, " \t")
	return end < 0 ? rest : rest[:end], true
}
