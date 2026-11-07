package markdown

import "core:strings"

import "../buffer"

// Link reference and footnote definitions: their labels, and the destination
// and title a reference link resolves to.

// The labels of the document's link reference and footnote definitions, rebuilt
// when a definition line has changed.
doc_labels :: proc(doc: ^Doc, b: ^buffer.Buffer) -> ^Labels {
	if doc.labels_gen == doc.refdef_gen && doc.labels_built do return &doc.labels
	doc.labels_gen = doc.refdef_gen
	doc.labels_built = true
	clear(&doc.labels)
	for l, i in doc.lines {
		if l.kind != .Link_Ref_Def && l.kind != .Footnote_Def do continue
		start := buffer.line_start(b, i)
		text := string(buffer.read_alloc(b, start, start + int(l.len)))
		d := line_detail(doc, i, text)
		if d.label[1] <= d.label[0] do continue
		h := label_hash(text[d.label[0]:d.label[1]], l.kind == .Footnote_Def)
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

// The title of the link reference definition for `label`, without its quotes;
// "" if it has none.
reference_title :: proc(doc: ^Doc, b: ^buffer.Buffer, label: string) -> string {
	i, ok := doc_labels(doc, b)[label_hash(label)]
	if !ok do return ""
	start := buffer.line_start(b, i)
	text := string(buffer.read_alloc(b, start, start + int(doc.lines[i].len)))
	d := line_detail(doc, i, text)
	rest := strings.trim_left_space(text[min(int(d.label[1]) + 2, len(text)):])
	j := 0
	if strings.has_prefix(rest, "<") {
		j = strings.index_byte(rest, '>') + 1
	} else {
		for j < len(rest) && !is_space(rest[j]) do j += 1
	}
	title := strings.trim_space(rest[j:])
	return len(title) >= 2 ? title[1:len(title) - 1] : ""
}
