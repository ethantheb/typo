package markdown

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

import "../buffer"

// The CommonMark spec's examples (testdata/commonmark.json, spec 0.31.2) and
// GFM's extension examples (testdata/gfm.json, from cmark-gfm's spec.txt),
// rendered to HTML from the line info and spans and compared with the HTML
// they expect. testdata/spec_failures.txt lists the examples known to fail,
// one per line: suite, number, why. The test fails if another one does, or if
// a listed one passes. -define:SPEC_WRITE=true rewrites the list, keeping the
// reasons given (new entries get their section's name).

SPEC_WRITE :: #config(SPEC_WRITE, false)
// Failures shown in full; the rest by number.
SPEC_DETAILS :: #config(SPEC_DETAILS, 10)

@(private = "file")
Spec_Example :: struct {
	markdown: string,
	html:     string,
	example:  int,
	section:  string,
}

@(test)
test_spec :: proc(t: ^testing.T) {
	dir := #directory
	list_path := strings.concatenate({dir, "/testdata/spec_failures.txt"}, context.temp_allocator)
	known := make(map[string]string, context.temp_allocator) // "cm 12" -> why
	if data, err := os.read_entire_file(list_path, context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) < 2 || strings.has_prefix(fields[0], "#") do continue
			key := strings.concatenate({fields[0], " ", fields[1]}, context.temp_allocator)
			known[key] = strings.trim_space(strings.trim_left_space(line)[len(key):])
		}
	}

	Failure :: struct {
		key, section: string,
		ex:           Spec_Example,
		got:          string,
	}
	failures := make([dynamic]Failure, context.temp_allocator)
	total := 0
	for suite in ([][2]string{{"cm", "commonmark.json"}, {"gfm", "gfm.json"}}) {
		data, err := os.read_entire_file(strings.concatenate({dir, "/testdata/", suite[1]}, context.temp_allocator), context.temp_allocator)
		if !testing.expectf(t, err == nil, "can't read %s", suite[1]) do return
		examples: []Spec_Example
		if !testing.expect(t, json.unmarshal(data, &examples, allocator = context.temp_allocator) == nil) do return
		for ex in examples {
			total += 1
			got := spec_html(ex.markdown)
			if got != ex.html do append(&failures, Failure{fmt.tprintf("%s %d", suite[0], ex.example), ex.section, ex, got})
		}
	}

	failed := make(map[string]bool, context.temp_allocator)
	shown := 0
	for f in failures {
		failed[f.key] = true
		if f.key in known do continue
		shown += 1
		if shown <= SPEC_DETAILS {
			testing.expectf(t, false, "spec %s (%s) fails:\n%s\nwant:\n%s\ngot:\n%s", f.key, f.section, f.ex.markdown, f.ex.html, f.got)
		} else {
			testing.expectf(t, false, "spec %s (%s) fails", f.key, f.section)
		}
	}
	for key in known do if key not_in failed do testing.expectf(t, false, "spec %s passes now: remove it from spec_failures.txt", key)
	log.infof("%d of %d spec examples pass", total - len(failures), total)

	when SPEC_WRITE {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "# Spec examples known to fail (see spec_test.odin): suite, example, why.\n")
		for f in failures do fmt.sbprintf(&sb, "%s %s\n", f.key, known[f.key] or_else f.section)
		_ = os.write_entire_file(list_path, strings.to_string(sb))
	}
}

// --- Block tree ----------------------------------------------------------------------------

@(private = "file")
Node_Kind :: enum {
	Document,
	Quote,
	List,
	Item,
	Paragraph,
	Heading,
	Code,
	Html,
	Rule,
	Table,
}

@(private = "file")
Node :: struct {
	kind:     Node_Kind,
	parent:   ^Node,
	children: [dynamic]^Node,
	blank:    bool, // ends with a blank line (cmark's last_line_blank)
	// List
	ordered:  bool,
	marker:   u8, // bullet, or the delimiter after a number
	start:    int,
	tight:    bool,
	// Item
	line:     int, // where it starts
	// Leaves: their lines, from where their content starts.
	lines:    [dynamic]string,
	pending:  [dynamic]string, // an indented code block's blank lines, until more code follows
	level:    int,
	fenced:   bool,
	info:     string,
	task:     int, // a paragraph starting with a task box: 1 unchecked, 2 checked
	aligns:   []u8, // a table's columns: 0 none, 1 left, 2 center, 3 right
}

@(private = "file")
add_node :: proc(parent: ^Node, kind: Node_Kind) -> ^Node {
	n := new(Node, context.temp_allocator)
	n.kind, n.parent = kind, parent
	n.children = make([dynamic]^Node, context.temp_allocator)
	n.lines = make([dynamic]string, context.temp_allocator)
	n.pending = make([dynamic]string, context.temp_allocator)
	append(&parent.children, n)
	return n
}

@(private = "file")
last_child :: proc(n: ^Node) -> ^Node {
	return len(n.children) > 0 ? n.children[len(n.children) - 1] : nil
}

// Drops up to `cols` columns of indentation.
@(private = "file")
strip_cols :: proc(s: string, cols: int) -> string {
	col, i := 0, 0
	for i < len(s) && col < cols {
		switch s[i] {
		case ' ':  col += 1
		case '\t': col = (col / 4 + 1) * 4
		case:      return s[i:]
		}
		i += 1
	}
	return s[i:]
}

@(private = "file")
spec_html :: proc(md: string) -> string {
	// A blank first line: no front matter.
	src := strings.concatenate({"\n", md}, context.temp_allocator)
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(src))
	defer buffer.buffer_destroy(&b)
	doc: Doc
	defer doc_destroy(&doc)
	doc_open(&doc, &b)
	doc_update(&doc, &b, max(int), time.Hour)
	lines := strings.split(src, "\n", context.temp_allocator)

	root := new(Node, context.temp_allocator)
	root.children = make([dynamic]^Node, context.temp_allocator)
	open := make([dynamic]^Node, context.temp_allocator) // the containers: root, quotes, items
	append(&open, root)
	leaf: ^Node // the open leaf in the innermost container
	for text, j in lines {
		// The line after the final line ending isn't one.
		if j == len(lines) - 1 && text == "" do break
		info := doc.lines[j]
		d := line_detail(&doc, j, text)
		if .Lazy not_in info.flags && 1 + int(d.matched) < len(open) {
			resize(&open, 1 + int(d.matched))
			leaf = nil
		}
		for m in d.marks[:d.n_marks] {
			if int(m.container) < int(d.matched) do continue
			parent := open[len(open) - 1]
			if m.kind == .Quote {
				append(&open, add_node(parent, .Quote))
			} else {
				marker := text[m.hi - 1]
				list := last_child(parent)
				if list == nil || list.kind != .List || list.ordered != (m.kind == .Ordered) || list.marker != marker {
					list = add_node(parent, .List)
					list.ordered, list.marker = m.kind == .Ordered, marker
					if list.ordered do list.start, _ = strconv.parse_int(text[m.lo:m.hi - 1])
				}
				item := add_node(list, .Item)
				item.line = j
				append(&open, item)
			}
			leaf = nil
		}
		c := open[len(open) - 1]
		content := text[min(int(d.content[0]), len(text)):]
		blank := false
		code_blank := false

		#partial switch info.kind {
		case .Blank:
			blank = true
			if leaf != nil && leaf.kind == .Code && !leaf.fenced {
				append(&leaf.pending, strip_cols(content, 4))
				code_blank = true
			} else {
				leaf = nil
			}
		case .Paragraph, .Footnote_Def, .Math_Fence, .Math_Body:
			if leaf != nil && leaf.kind == .Paragraph && .Block_Start not_in info.flags {
				append(&leaf.lines, strings.trim_left_space(content))
			} else {
				leaf = add_node(c, .Paragraph)
				if .Task in info.flags {
					leaf.task = .Task_Checked in info.flags ? 2 : 1
					content = text[min(int(d.task[1]) + 1, len(text)):]
				}
				append(&leaf.lines, strings.trim_left_space(content))
			}
		case .Link_Ref_Def:
			leaf = nil
		case .Atx_Heading:
			h := add_node(c, .Heading)
			h.level = int(info.aux)
			hi := d.close != {} ? int(d.close[0]) : len(text)
			append(&h.lines, strings.trim_space(text[min(int(d.open[1]), hi):hi]))
			leaf = nil
		case .Setext_Underline:
			if leaf != nil && leaf.kind == .Paragraph {
				leaf.kind = .Heading
				leaf.level = int(info.aux)
			}
			leaf = nil
		case .Thematic_Break:
			add_node(c, .Rule)
			leaf = nil
		case .Fence_Open:
			leaf = add_node(c, .Code)
			leaf.fenced = true
			leaf.info = text[d.info[0]:d.info[1]]
		case .Fence_Body:
			if leaf == nil || leaf.kind != .Code {
				leaf = add_node(c, .Code)
				leaf.fenced = true
			}
			append(&leaf.lines, content)
		case .Fence_Close:
			leaf = nil
		case .Indented_Code:
			if leaf == nil || leaf.kind != .Code || leaf.fenced || .Block_Start in info.flags {
				leaf = add_node(c, .Code)
			}
			append(&leaf.lines, ..leaf.pending[:])
			clear(&leaf.pending)
			append(&leaf.lines, content)
		case .Html:
			if leaf == nil || leaf.kind != .Html || .Block_Start in info.flags do leaf = add_node(c, .Html)
			append(&leaf.lines, content)
			if line_state(&doc, j).leaf != .Html do leaf = nil
		case .Table_Delim:
			// The paragraph's last line is the header.
			header: string
			if leaf != nil && leaf.kind == .Paragraph {
				header = pop(&leaf.lines)
				if len(leaf.lines) == 0 do pop(&c.children)
			}
			leaf = add_node(c, .Table)
			append(&leaf.lines, header)
			leaf.aligns = make([]u8, int(info.aux), context.temp_allocator)
			for cell, k in row_cells(content) {
				if k >= len(leaf.aligns) do break
				t := strings.trim_space(content[cell[0]:cell[1]])
				left, right := strings.has_prefix(t, ":"), strings.has_suffix(t, ":")
				leaf.aligns[k] = left && right ? 2 : (right ? 3 : (left ? 1 : 0))
			}
		case .Table_Row:
			if leaf != nil && leaf.kind == .Table do append(&leaf.lines, content)
		case:
			leaf = nil
		}

		// Blank lines, for tight and loose lists (as cmark tracks them).
		if blank && !code_blank {
			// A list stays open through a blank line, even after its last item ended.
			if last := last_child(c); last != nil && last.kind == .List do c = last
			if last := last_child(c); last != nil do last.blank = true
			c.blank = c.kind != .Quote && !(c.kind == .Item && len(c.children) == 0 && c.line == j)
		} else {
			c.blank = false
			if code_blank do leaf.blank = true
			else if leaf != nil do leaf.blank = false
		}
		for p := c.parent; p != nil; p = p.parent do p.blank = false
	}
	finish_lists(root)

	r := Spec_Renderer{doc = &doc, b = &b, sb = strings.builder_make(context.temp_allocator)}
	render_node(&r, root, false)
	return strings.to_string(r.sb)
}

@(private = "file")
ends_with_blank :: proc(n: ^Node) -> bool {
	if n.blank do return true
	if (n.kind == .List || n.kind == .Item) && len(n.children) > 0 do return ends_with_blank(last_child(n))
	return false
}

@(private = "file")
finish_lists :: proc(n: ^Node) {
	if n.kind == .List {
		n.tight = true
		check: for item, i in n.children {
			last_item := i == len(n.children) - 1
			if !last_item && ends_with_blank(item) {
				n.tight = false
				break
			}
			for sub, k in item.children {
				if (!last_item || k < len(item.children) - 1) && ends_with_blank(sub) {
					n.tight = false
					break check
				}
			}
		}
	}
	for c in n.children do finish_lists(c)
}

// --- HTML ------------------------------------------------------------------------------------

@(private = "file")
Spec_Renderer :: struct {
	doc:   ^Doc,
	b:     ^buffer.Buffer,
	sb:    strings.Builder,
	plain: bool, // an image's alt text: no tags
}

// A newline unless at the start of a line.
@(private = "file")
cr :: proc(r: ^Spec_Renderer) {
	s := strings.to_string(r.sb)
	if len(s) > 0 && s[len(s) - 1] != '\n' do strings.write_byte(&r.sb, '\n')
}

@(private = "file")
escape :: proc(r: ^Spec_Renderer, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(&r.sb, "&amp;")
		case '<': strings.write_string(&r.sb, "&lt;")
		case '>': strings.write_string(&r.sb, "&gt;")
		case '"': strings.write_string(&r.sb, "&quot;")
		case:     strings.write_byte(&r.sb, s[i])
		}
	}
}

@(private = "file")
render_node :: proc(r: ^Spec_Renderer, n: ^Node, tight: bool) {
	sb := &r.sb
	switch n.kind {
	case .Document:
		for c in n.children do render_node(r, c, false)
	case .Quote:
		cr(r)
		strings.write_string(sb, "<blockquote>")
		cr(r)
		for c in n.children do render_node(r, c, false)
		cr(r)
		strings.write_string(sb, "</blockquote>")
		cr(r)
	case .List:
		cr(r)
		switch {
		case !n.ordered:   strings.write_string(sb, "<ul>")
		case n.start == 1: strings.write_string(sb, "<ol>")
		case:              fmt.sbprintf(sb, "<ol start=\"%d\">", n.start)
		}
		cr(r)
		for c in n.children do render_node(r, c, n.tight)
		cr(r)
		strings.write_string(sb, n.ordered ? "</ol>" : "</ul>")
		cr(r)
	case .Item:
		cr(r)
		strings.write_string(sb, "<li>")
		for c in n.children do render_node(r, c, tight)
		strings.write_string(sb, "</li>")
		cr(r)
	case .Paragraph:
		if !tight {
			cr(r)
			strings.write_string(sb, "<p>")
		}
		switch n.task {
		case 1: strings.write_string(sb, "<input disabled=\"\" type=\"checkbox\"> ")
		case 2: strings.write_string(sb, "<input checked=\"\" disabled=\"\" type=\"checkbox\"> ")
		}
		render_text(r, strings.trim_right_space(strings.join(n.lines[:], "\n", context.temp_allocator)), false)
		if !tight {
			strings.write_string(sb, "</p>")
			cr(r)
		}
	case .Heading:
		cr(r)
		fmt.sbprintf(sb, "<h%d>", n.level)
		render_text(r, strings.trim_space(strings.join(n.lines[:], "\n", context.temp_allocator)), false)
		fmt.sbprintf(sb, "</h%d>", n.level)
		cr(r)
	case .Code:
		cr(r)
		strings.write_string(sb, "<pre><code")
		if word := strings.fields(n.info, context.temp_allocator); len(word) > 0 {
			strings.write_string(sb, " class=\"language-")
			escape(r, unescape(word[0]))
			strings.write_string(sb, "\"")
		}
		strings.write_string(sb, ">")
		for line in n.lines {
			escape(r, line)
			strings.write_byte(sb, '\n')
		}
		strings.write_string(sb, "</code></pre>")
		cr(r)
	case .Html:
		cr(r)
		for line in n.lines {
			strings.write_string(sb, line)
			strings.write_byte(sb, '\n')
		}
		cr(r)
	case .Rule:
		cr(r)
		strings.write_string(sb, "<hr />")
		cr(r)
	case .Table:
		cr(r)
		strings.write_string(sb, "<table>\n<thead>\n")
		for line, k in n.lines {
			if k == 1 do strings.write_string(sb, "<tbody>\n")
			strings.write_string(sb, "<tr>\n")
			cells := row_cells(line)
			for a, c in n.aligns {
				tag := k == 0 ? "th" : "td"
				fmt.sbprintf(sb, "<%s", tag)
				switch a {
				case 1: strings.write_string(sb, " align=\"left\"")
				case 2: strings.write_string(sb, " align=\"center\"")
				case 3: strings.write_string(sb, " align=\"right\"")
				}
				strings.write_string(sb, ">")
				if c < len(cells) do render_text(r, strings.trim_space(line[cells[c][0]:cells[c][1]]), true)
				fmt.sbprintf(sb, "</%s>\n", tag)
			}
			strings.write_string(sb, "</tr>\n")
			if k == 0 do strings.write_string(sb, "</thead>\n")
		}
		if len(n.lines) > 1 do strings.write_string(sb, "</tbody>\n")
		strings.write_string(sb, "</table>")
		cr(r)
	}
}

// A destination as an href: percent-encoded like cmark's houdini_escape_href.
@(private = "file")
href :: proc(r: ^Spec_Renderer, url: string) {
	hex := "0123456789ABCDEF"
	for i in 0 ..< len(url) {
		c := url[i]
		switch {
		case c == '&':  strings.write_string(&r.sb, "&amp;")
		case c == '\'': strings.write_string(&r.sb, "&#x27;")
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.index_byte("-_.+!*(),%#@?=;:/$~", c) >= 0:
			strings.write_byte(&r.sb, c)
		case:
			strings.write_byte(&r.sb, '%')
			strings.write_byte(&r.sb, hex[c >> 4])
			strings.write_byte(&r.sb, hex[c & 15])
		}
	}
}

// Inline content: the spans of `text` as HTML (a table cell's "\|" is a pipe).
@(private = "file")
render_text :: proc(r: ^Spec_Renderer, text: string, cell: bool) {
	spans := make([dynamic]Span, context.temp_allocator)
	inline_parse(text, doc_labels(r.doc, r.b), &spans)
	slice.sort_by(spans[:], proc(a, b: Span) -> bool {return a.lo < b.lo || (a.lo == b.lo && a.hi > b.hi)})
	render_spans(r, text, spans[:], 0, len(text), 0)
}

@(private = "file")
render_spans :: proc(r: ^Spec_Renderer, text: string, spans: []Span, lo, hi, from: int) {
	sb := &r.sb
	i := lo
	for k := from; k < len(spans); k += 1 {
		s := spans[k]
		if int(s.lo) >= hi do break
		if int(s.lo) < i || int(s.hi) > hi do continue
		plain_text(r, text[i:s.lo])
		i = int(s.hi)
		switch s.kind {
		case .Emph:
			tag(r, "<em>")
			inner(r, text, spans, s, k)
			tag(r, "</em>")
		case .Strong:
			tag(r, "<strong>")
			inner(r, text, spans, s, k)
			tag(r, "</strong>")
		case .Strike:
			tag(r, "<del>")
			inner(r, text, spans, s, k)
			tag(r, "</del>")
		case .Highlight:
			tag(r, "<mark>")
			inner(r, text, spans, s, k)
			tag(r, "</mark>")
		case .Code:
			code, _ := strings.replace_all(text[s.open_hi:s.close_lo], "\n", " ", context.temp_allocator)
			if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' && strings.trim_space(code) != "" do code = code[1:len(code) - 1]
			tag(r, "<code>")
			escape(r, code)
			tag(r, "</code>")
		case .Link, .Image:
			dest := text[s.url[0]:s.url[1]]
			title := text[s.title[0]:s.title[1]]
			if s.reference do dest, title = reference_destination(r.doc, r.b, dest) or_else "", reference_title(r.doc, r.b, dest)
			if s.kind == .Image && !r.plain {
				strings.write_string(sb, "<img src=\"")
				href(r, unescape(dest))
				strings.write_string(sb, "\" alt=\"")
				r.plain = true
				inner(r, text, spans, s, k)
				r.plain = false
				strings.write_string(sb, "\"")
				link_title(r, title)
				strings.write_string(sb, " />")
			} else if s.kind == .Image {
				inner(r, text, spans, s, k)
			} else {
				if !r.plain {
					strings.write_string(sb, "<a href=\"")
					href(r, unescape(dest))
					strings.write_string(sb, "\"")
					link_title(r, title)
					strings.write_string(sb, ">")
				}
				inner(r, text, spans, s, k)
				tag(r, "</a>")
			}
		case .Autolink, .Url:
			url := text[s.url[0]:s.url[1]]
			if !r.plain {
				strings.write_string(sb, "<a href=\"")
				switch {
				case s.kind == .Url && strings.has_prefix(url, "www."): strings.write_string(sb, "http://")
				case s.kind == .Url && strings.index(url, "://") < 0:   strings.write_string(sb, "mailto:")
				case s.kind == .Autolink && strings.index_byte(url, ':') < 0: strings.write_string(sb, "mailto:")
				}
				href(r, url)
				strings.write_string(sb, "\">")
			}
			escape(r, text[s.open_hi:s.close_lo])
			tag(r, "</a>")
		case .Html:
			if !r.plain do strings.write_string(sb, text[s.lo:s.hi])
		case .Escape:
			escape(r, text[s.open_hi:s.hi])
		case .Entity:
			escape(r, unescape(text[s.lo:s.hi]))
		case .Hard_Break:
			tag(r, "<br />")
		case .Wikilink, .Footnote_Ref, .Math:
			escape(r, text[s.lo:s.hi])
		}
	}
	plain_text(r, text[i:hi])
}

@(private = "file")
link_title :: proc(r: ^Spec_Renderer, title: string) {
	if title == "" do return
	strings.write_string(&r.sb, " title=\"")
	escape(r, unescape(title))
	strings.write_string(&r.sb, "\"")
}

// The content of span k.
@(private = "file")
inner :: proc(r: ^Spec_Renderer, text: string, spans: []Span, s: Span, k: int) {
	render_spans(r, text, spans, int(s.open_hi), int(s.close_lo), k + 1)
}

// A tag, unless in alt text.
@(private = "file")
tag :: proc(r: ^Spec_Renderer, s: string) {
	if !r.plain do strings.write_string(&r.sb, s)
}

// Text outside spans: escaped, a line break where two spaces end a line,
// spaces before other line endings dropped.
@(private = "file")
plain_text :: proc(r: ^Spec_Renderer, s: string) {
	for line, i in strings.split(s, "\n", context.temp_allocator) {
		if i > 0 do strings.write_byte(&r.sb, '\n')
		is_last := i == strings.count(s, "\n")
		if is_last {
			escape(r, line)
			continue
		}
		t := strings.trim_right(line, " ")
		escape(r, t)
		if len(line) - len(t) >= 2 && !r.plain do strings.write_string(&r.sb, "<br />")
	}
}
