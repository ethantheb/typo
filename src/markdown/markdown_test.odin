package markdown

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../buffer"
import "../syntax"

@(private = "file")
make_buffer :: proc(s: string) -> buffer.Buffer {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(s))
	return b
}

@(private = "file")
parse_all :: proc(doc: ^Doc, b: ^buffer.Buffer) {
	doc_open(doc, b)
	doc_update(doc, b, max(int), time.Hour)
}

// Line kinds of `text`, parsed from scratch.
@(private = "file")
kinds :: proc(text: string) -> []Line_Kind {
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)
	doc: Doc
	defer doc_destroy(&doc)
	parse_all(&doc, &b)
	out := make([]Line_Kind, len(doc.lines), context.temp_allocator)
	for l, i in doc.lines do out[i] = l.kind
	return out
}

@(private = "file")
infos :: proc(text: string) -> []Line_Info {
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)
	doc: Doc
	defer doc_destroy(&doc)
	parse_all(&doc, &b)
	out := make([]Line_Info, len(doc.lines), context.temp_allocator)
	copy(out, doc.lines[:])
	return out
}

@(private = "file")
expect_kinds :: proc(t: ^testing.T, text: string, want: []Line_Kind, loc := #caller_location) {
	got := kinds(text)
	ok := len(got) == len(want)
	if ok do for k, i in got do if k != want[i] do ok = false
	testing.expectf(t, ok, "%q: got %v, want %v", text, got, want, loc = loc)
}

// The state after the last line of `text`.
@(private = "file")
final_state :: proc(text: string) -> State {
	s: State
	for line, i in strings.split_lines(text, context.temp_allocator) {
		_, _, s = parse_line(s, line, i == 0)
	}
	return s
}

@(test)
test_headings :: proc(t: ^testing.T) {
	expect_kinds(t, "# a\n###### b\n####### c\n#5\n#", {.Atx_Heading, .Atx_Heading, .Paragraph, .Paragraph, .Atx_Heading})
	expect_kinds(t, "Foo\n===\nBar\n---", {.Paragraph, .Setext_Underline, .Paragraph, .Setext_Underline})
	expect_kinds(t, "---\n\n***\n_ _ _", {.Front_Matter_Fence, .Front_Matter_Body, .Front_Matter_Body, .Front_Matter_Body})
	expect_kinds(t, "x\n\n---\n***\n_ _ _", {.Paragraph, .Blank, .Thematic_Break, .Thematic_Break, .Thematic_Break})
	expect_kinds(t, "    # not", {.Indented_Code})

	l := infos("## Title ##\nx\n===")
	testing.expect_value(t, l[0].aux, 2)
	testing.expect_value(t, l[2].aux, 1)

	_, d, _ := parse_line({}, "## Title ##")
	testing.expect_value(t, d.open, [2]i32{0, 3})
	testing.expect_value(t, d.close, [2]i32{8, 11})
	_, d, _ = parse_line({}, "# a#")
	testing.expect_value(t, d.close, [2]i32{0, 0})
}

@(test)
test_quotes_and_lazy :: proc(t: ^testing.T) {
	l := infos("> a\nb\n> > c\n\nd")
	testing.expect_value(t, l[0].kind, Line_Kind.Paragraph)
	testing.expect_value(t, l[1].kind, Line_Kind.Paragraph)
	testing.expect(t, .Lazy in l[1].flags)
	testing.expect(t, .Block_Start in l[2].flags)
	testing.expect_value(t, final_state("> > c").depth, 2)
	testing.expect_value(t, l[4].kind, Line_Kind.Paragraph)
	testing.expect_value(t, final_state("> a\n\nd").depth, 0)

	_, d, _ := parse_line({}, "> > c")
	testing.expect_value(t, d.n_marks, 2)
	testing.expect_value(t, d.marks[1].lo, 2)
	testing.expect_value(t, d.content[0], 4)

	// A quote breaks a lazy continuation's paragraph.
	expect_kinds(t, "> a\n---", {.Paragraph, .Thematic_Break})
}

@(test)
test_lists :: proc(t: ^testing.T) {
	l := infos("- a\n- b\n  c\n\n  d\ne")
	testing.expect(t, .Item_Start in l[0].flags)
	testing.expect(t, .Item_Start in l[1].flags)
	testing.expect(t, .Item_Start not_in l[2].flags)
	testing.expect_value(t, final_state("- a\n\n  d").depth, 1)
	testing.expect_value(t, final_state("- a\n\nd").depth, 0)
	testing.expect(t, .Lazy in infos("- a\ne")[1].flags)

	// Ordered items: only "1." may interrupt a paragraph, but any number starts
	// a sibling item.
	testing.expect(t, .Item_Start not_in infos("a\n2. b")[1].flags)
	testing.expect(t, .Item_Start in infos("a\n1. b")[1].flags)
	testing.expect(t, .Item_Start in infos("1. a\n2. b")[1].flags)
	// An empty item can't interrupt a paragraph, except one nested in an item
	// or followed by a space; a single "-" is not a heading underline either.
	testing.expect_value(t, infos("a\n-")[1].kind, Line_Kind.Paragraph)
	testing.expect_value(t, infos("a\n--")[1].kind, Line_Kind.Setext_Underline)
	testing.expect_value(t, infos("a\n=")[1].kind, Line_Kind.Setext_Underline)
	testing.expect(t, .Item_Start in infos("a\n- ")[1].flags)
	testing.expect(t, .Item_Start in infos("a\n3. ")[1].flags)
	testing.expect(t, .Item_Start not_in infos("a\n+")[1].flags)
	testing.expect(t, .Item_Start in infos("- a\n  - ")[1].flags)
	testing.expect(t, .Item_Start in infos("1. a\n   2.")[1].flags)
	testing.expect_value(t, final_state("- a\n  -").depth, 2)

	// Nested lists and content indentation.
	s := final_state("- a\n  - b")
	testing.expect_value(t, s.depth, 2)
	testing.expect_value(t, s.containers[1].indent, 2)
	s = final_state("10.  x")
	testing.expect_value(t, s.containers[0].indent, 5)
	testing.expect_value(t, s.containers[0].marker, '.')
	s = final_state("-\tfoo")
	testing.expect_value(t, s.containers[0].indent, 4)
	s = final_state("-      code")
	testing.expect_value(t, s.containers[0].indent, 2)
	testing.expect_value(t, kinds("-      code")[0], Line_Kind.Indented_Code)

	_, d, _ := parse_line({}, "  12) item")
	testing.expect_value(t, d.marks[0].lo, 2)
	testing.expect_value(t, d.marks[0].hi, 5)
	testing.expect_value(t, d.content[0], 6)

	// A thematic break wins over a list item.
	expect_kinds(t, "- - -\n* * *", {.Thematic_Break, .Thematic_Break})
}

@(test)
test_tasks :: proc(t: ^testing.T) {
	l := infos("- [ ] a\n- [x] b\n- [X]\n- [y] c\n[ ] d")
	testing.expect(t, .Task in l[0].flags && .Task_Checked not_in l[0].flags)
	testing.expect(t, .Task_Checked in l[1].flags)
	testing.expect(t, .Task_Checked in l[2].flags)
	testing.expect(t, .Task not_in l[3].flags)
	testing.expect(t, .Task not_in l[4].flags)
	_, d, _ := parse_line({}, "- [x] b")
	testing.expect_value(t, d.task, [2]i32{2, 5})
}

@(test)
test_code :: proc(t: ^testing.T) {
	expect_kinds(t, "```odin\nx\n```\ny", {.Fence_Open, .Fence_Body, .Fence_Close, .Paragraph})
	expect_kinds(t, "````\n```\n````", {.Fence_Open, .Fence_Body, .Fence_Close})
	expect_kinds(t, "~~~\n```\n~~~", {.Fence_Open, .Fence_Body, .Fence_Close})
	expect_kinds(t, "``` a`b\nc", {.Paragraph, .Paragraph})
	expect_kinds(t, "```\nnever closed\n", {.Fence_Open, .Fence_Body, .Fence_Body})
	expect_kinds(t, "    x\n\n    y\nz", {.Indented_Code, .Blank, .Indented_Code, .Paragraph})
	expect_kinds(t, "a\n    b", {.Paragraph, .Paragraph})
	expect_kinds(t, "> ```\n> x\ny", {.Fence_Open, .Fence_Body, .Paragraph})

	testing.expect_value(t, final_state("```odin").fence_lang, syntax.Language.Odin)
	testing.expect_value(t, final_state("~~~ python {.x}").fence_lang, syntax.Language.Python)
	_, d, _ := parse_line({}, "```  rust  ")
	testing.expect_value(t, d.info, [2]i32{5, 9})
}

@(test)
test_html :: proc(t: ^testing.T) {
	expect_kinds(t, "<div>\nx\n\ny", {.Html, .Html, .Blank, .Paragraph})
	expect_kinds(t, "<!-- a\n\nb -->\nc", {.Html, .Html, .Html, .Paragraph})
	expect_kinds(t, "<!-- one line -->\nc", {.Html, .Paragraph})
	expect_kinds(t, "<script>\nx\n</script>\ny", {.Html, .Html, .Html, .Paragraph})
	expect_kinds(t, "a\n<span>", {.Paragraph, .Paragraph})
	expect_kinds(t, "<span class=\"x\">\na", {.Html, .Html})
	expect_kinds(t, "a\n<div>", {.Paragraph, .Html})
	expect_kinds(t, "<notatag x", {.Paragraph})
}

@(test)
test_tables :: proc(t: ^testing.T) {
	expect_kinds(t, "| a | b |\n|---|:-:|\n| 1 | 2 |\n3\n\nx", {.Paragraph, .Table_Delim, .Table_Row, .Table_Row, .Blank, .Paragraph})
	expect_kinds(t, "a | b\n--|--\n> q", {.Paragraph, .Table_Delim, .Paragraph})
	// Header and delimiter cell counts must match.
	expect_kinds(t, "| a | b |\n|---|", {.Paragraph, .Paragraph})
	expect_kinds(t, "a\n---", {.Paragraph, .Setext_Underline})
	testing.expect_value(t, infos("|a|b|c|\n|-|-|-|")[1].aux, 3)
	testing.expect_value(t, table_cells(`| a \| b | c |`), 2)
	testing.expect_value(t, table_cells("a"), 1)
}

@(test)
test_definitions_and_extras :: proc(t: ^testing.T) {
	expect_kinds(t, "[a]: /url\n[b]: <x y> 'title'\n[c]: /u bad", {.Link_Ref_Def, .Link_Ref_Def, .Paragraph})
	expect_kinds(t, "[a]: /url\n===", {.Link_Ref_Def, .Paragraph})
	expect_kinds(t, "[^1]: note\nmore", {.Footnote_Def, .Paragraph})
	expect_kinds(t, "$$\nx^2\n$$\n$$ y $$", {.Math_Fence, .Math_Body, .Math_Fence, .Math_Fence})
	expect_kinds(t, "---\ntitle: x\n---\n# h", {.Front_Matter_Fence, .Front_Matter_Body, .Front_Matter_Fence, .Atx_Heading})
	_, d, _ := parse_line({}, "[label]: /x")
	testing.expect_value(t, d.label, [2]i32{1, 6})
}

// Snippets that open and close blocks, for random edits.
@(private = "file")
SNIPPETS := [?]string {
	"```", "```odin\n", "~~~", "\n", "\n\n", "===", "---", "| a | b |", "|--|--|", "> ", "- ", "1. ", "2) ",
	"    ", "\t", "<div>", "<!--", "-->", "# ", "text ", "word", "[x]: /u", "$$", "- [ ] ", "*", "<span>",
}

@(private = "file")
random_snippets :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< n do strings.write_string(&sb, SNIPPETS[rand.int_max(len(SNIPPETS))])
	return strings.to_string(sb)
}

// Incremental parsing after random edits, sometimes interrupted (a small
// budget, as when parsing in the background), matches a full parse.
@(test)
test_incremental_matches_full :: proc(t: ^testing.T) {
	rand.reset(7)
	for round in 0 ..< 60 {
		b := make_buffer(random_snippets(60))
		defer buffer.buffer_destroy(&b)
		doc: Doc
		defer doc_destroy(&doc)
		doc_open(&doc, &b)
		doc_update(&doc, &b, rand.int_max(4), 0)

		sels := []buffer.Selection{{0, 0, -1}}
		for step in 0 ..< 50 {
			// A few edits per update, like several carets.
			for _ in 0 ..< 1 + rand.int_max(3) {
				n := buffer.length(&b)
				at := rand.int_max(n + 1)
				remove := rand.int_max(min(n - at, 12) + 1)
				buffer.begin(&b, .Other, u64(step), sels)
				buffer.replace(&b, at, remove, random_snippets(rand.int_max(3)))
				buffer.end(&b, sels)
			}
			doc_edit(&doc, buffer.take_changes(&b))
			if rand.int_max(3) == 0 {
				doc_update(&doc, &b, rand.int_max(buffer.line_count(&b)), 0)
			} else {
				doc_update(&doc, &b, max(int), time.Hour)
				check_against_full(t, &doc, &b, round, step)
			}
		}
		doc_update(&doc, &b, max(int), time.Hour)
		check_against_full(t, &doc, &b, round, -1)
	}
}

@(private = "file")
check_against_full :: proc(t: ^testing.T, doc: ^Doc, b: ^buffer.Buffer, round, step: int) {
	full: Doc
	defer doc_destroy(&full)
	parse_all(&full, b)
	if !testing.expectf(t, len(doc.lines) == len(full.lines), "round %d step %d: %d lines, want %d", round, step, len(doc.lines), len(full.lines)) do return
	testing.expect(t, !doc_busy(doc))
	for i in 0 ..< len(full.lines) {
		a, f := doc.lines[i], full.lines[i]
		same := a.kind == f.kind && a.aux == f.aux && a.flags == f.flags && a.len == f.len && line_state(doc, i) == line_state(&full, i)
		if !testing.expectf(t, same, "round %d step %d line %d: %v, want %v", round, step, i, a, f) do return
	}
}

@(test)
test_typing_reparses_one_line :: proc(t: ^testing.T) {
	text := strings.repeat("para text\n", 1000, context.temp_allocator)
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)
	doc: Doc
	defer doc_destroy(&doc)
	parse_all(&doc, &b)

	sels := []buffer.Selection{{0, 0, -1}}
	buffer.begin(&b, .Typing, 0, sels)
	buffer.replace(&b, 5000, 0, "x")
	buffer.end(&b, sels)
	doc_edit(&doc, buffer.take_changes(&b))
	testing.expect_value(t, doc.cursor, 500)
	doc_update(&doc, &b, 0, 0)
	testing.expect(t, !doc_busy(&doc))
	testing.expect_value(t, doc.lines[500].len, 10)
}

// --- Inlines ----------------------------------------------------------------------------

// Spans of `text` as "Kind:content" (plus "->url" for links), sorted.
@(private = "file")
describe :: proc(text: string, labels: ^Labels = nil) -> []string {
	spans := make([dynamic]Span, context.temp_allocator)
	inline_parse(text, labels, &spans)
	out := make([]string, len(spans), context.temp_allocator)
	for s, i in spans {
		out[i] = fmt.tprintf("%v:%s", s.kind, text[s.open_hi:s.close_lo])
		if s.url != {} do out[i] = fmt.tprintf("%s->%s", out[i], text[s.url[0]:s.url[1]])
	}
	slice.sort(out)
	return out
}

@(private = "file")
expect_spans :: proc(t: ^testing.T, text: string, want: []string, labels: ^Labels = nil, loc := #caller_location) {
	got := describe(text, labels)
	ok := len(got) == len(want)
	sorted := slice.clone(want, context.temp_allocator)
	slice.sort(sorted)
	if ok do for g, i in got do if g != sorted[i] do ok = false
	testing.expectf(t, ok, "%q: got %v, want %v", text, got, sorted, loc = loc)
}

@(test)
test_emphasis :: proc(t: ^testing.T) {
	expect_spans(t, "*a*", {"Emph:a"})
	expect_spans(t, "**a**", {"Strong:a"})
	expect_spans(t, "***a***", {"Emph:**a**", "Strong:a"})
	expect_spans(t, "*a **b** c*", {"Emph:a **b** c", "Strong:b"})
	expect_spans(t, "foo*bar*", {"Emph:bar"})
	expect_spans(t, "foo_bar_", {})
	expect_spans(t, "_foo_bar", {})
	expect_spans(t, "**foo*", {"Emph:foo"})
	expect_spans(t, "*foo**", {"Emph:foo"})
	expect_spans(t, "a * b *", {})
	expect_spans(t, "**a\nb**", {"Strong:a\nb"})
	expect_spans(t, "*(*foo*)*", {"Emph:(*foo*)", "Emph:foo"})
	expect_spans(t, "~~del~~ ~one~ ~~no~", {"Strike:del", "Strike:one"})
	expect_spans(t, "==mark== =no=", {"Highlight:mark"})
	expect_spans(t, "*foo [bar* baz](u)", {"Link:bar* baz->u"})
}

@(test)
test_code_and_escapes :: proc(t: ^testing.T) {
	expect_spans(t, "`code`", {"Code:code"})
	expect_spans(t, "`` a`b ``", {"Code: a`b "})
	expect_spans(t, "`unclosed", {})
	expect_spans(t, "`*no*`", {"Code:*no*"})
	expect_spans(t, `\*not\*`, {"Escape:*", "Escape:*"})
	expect_spans(t, "&amp; &copy; &#123; &bogus;", {"Entity:", "Entity:", "Entity:"})
	expect_spans(t, `<span class="x">hi</span>`, {`Html:<span class="x">`, "Html:</span>"})
	expect_spans(t, "$x^2$ and $$y$$", {"Math:x^2", "Math:y"})
	expect_spans(t, "$5 and $6", {})
}

@(test)
test_links :: proc(t: ^testing.T) {
	expect_spans(t, `[text](http://x "t")`, {"Link:text->http://x"})
	expect_spans(t, "![alt](img.png)", {"Image:alt->img.png"})
	expect_spans(t, "[a](<b c>)", {"Link:a->b c"})
	expect_spans(t, "[a](b(c))", {"Link:a->b(c)"})
	expect_spans(t, "[a [b](c) d](e)", {"Link:b->c"})
	expect_spans(t, "[a](b", {})

	labels: Labels
	defer delete(labels)
	labels[label_hash("Ref  One")] = 0
	expect_spans(t, "[ref one]", {"Link:ref one->ref one"}, &labels)
	expect_spans(t, "[REF ONE][]", {"Link:REF ONE->REF ONE"}, &labels)
	expect_spans(t, "[text][ref one]", {"Link:text->ref one"}, &labels)
	expect_spans(t, "[nope]", {}, &labels)

	expect_spans(t, "<https://a.b/c>", {"Autolink:https://a.b/c->https://a.b/c"})
	expect_spans(t, "<me@x.org>", {"Autolink:me@x.org->me@x.org"})
	expect_spans(t, "visit www.example.com.", {"Url:www.example.com->www.example.com"})
	expect_spans(t, "(see https://a.b/c).", {"Url:https://a.b/c->https://a.b/c"})
	expect_spans(t, "wwwx and http:", {})
	expect_spans(t, "[[Page]] [[Page|Alias]]", {"Wikilink:Page->Page", "Wikilink:Alias->Page"})
	expect_spans(t, "note[^1].", {"Footnote_Ref:1"})
}

@(test)
test_text_highlight :: proc(t: ^testing.T) {
	text := "# Title\n\nSome **bold** and `code`.\n\n```odin\nx := 1 // c\n```\n> quote\n- [x] done\n\n| a | b |\n|---|---|\n| *c* | d |"
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)
	doc: Doc
	defer doc_destroy(&doc)
	parse_all(&doc, &b)
	hl := make([]syntax.Highlight, len(text), context.temp_allocator)
	style := make([]Text_Styles, len(text), context.temp_allocator)
	highlight_range(&doc, &b, 0, hl, style)
	at :: proc(text, needle: string) -> int {return strings.index(text, needle)}

	testing.expect_value(t, hl[0], syntax.Highlight.Punctuation)
	testing.expect_value(t, hl[at(text, "Title")], syntax.Highlight.Keyword)
	testing.expect(t, .Bold in style[at(text, "bold")])
	testing.expect_value(t, hl[at(text, "**bold")], syntax.Highlight.Punctuation)
	testing.expect_value(t, hl[at(text, "code`")], syntax.Highlight.String)
	testing.expect_value(t, hl[at(text, "odin")], syntax.Highlight.Type)
	testing.expect_value(t, hl[at(text, "// c")], syntax.Highlight.Comment)
	testing.expect_value(t, hl[at(text, "1 //")], syntax.Highlight.Number)
	testing.expect_value(t, hl[at(text, "quote")], syntax.Highlight.Comment)
	testing.expect_value(t, hl[at(text, "[x]")], syntax.Highlight.Keyword)
	testing.expect(t, .Bold in style[at(text, "a |")])
	testing.expect(t, .Italic in style[at(text, "c*")])

	// A lazy line of a quoted paragraph is quoted too, under its inlines' colors.
	{
		lazy := "> q\nlazy `c`"
		lb := make_buffer(lazy)
		defer buffer.buffer_destroy(&lb)
		ldoc: Doc
		defer doc_destroy(&ldoc)
		parse_all(&ldoc, &lb)
		lhl := make([]syntax.Highlight, len(lazy), context.temp_allocator)
		lstyle := make([]Text_Styles, len(lazy), context.temp_allocator)
		highlight_range(&ldoc, &lb, 0, lhl, lstyle)
		testing.expect_value(t, lhl[at(lazy, "lazy")], syntax.Highlight.Comment)
		testing.expect_value(t, lhl[at(lazy, "c`")], syntax.Highlight.String)
	}

	// Highlighting part of the document gives the same result for that part.
	from := at(text, "x :=")
	part := make([]syntax.Highlight, 12, context.temp_allocator)
	part_style := make([]Text_Styles, 12, context.temp_allocator)
	highlight_range(&doc, &b, from, part, part_style)
	for h, i in part do testing.expect_value(t, h, hl[from + i])
}
