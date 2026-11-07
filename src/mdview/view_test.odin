package mdview

import "core:math"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"

import "../buffer"
import "../markdown"
import "../textedit"

// Tests for the rendered view that need no app around it. Without a text
// engine, every character is half the font size wide (see text_width in gfx).

// What the tests' env reports as the pointer and the workspace's files, and
// the last file a link opened.
@(private)
test_input: Input
@(private)
test_files: [dynamic]string
@(private)
test_opened: string

@(private)
test_env :: proc() {
	env = {
		config = proc() -> Config {
			return {font_size = 16, line_height = 1.5, text_line_height = 20}
		},
		input = proc() -> Input {return test_input},
		files = proc() -> []string {return test_files[:]},
		ensure_index = proc() {},
		open_file = proc(path, heading: string) {test_opened = "opened"},
	}
}

@(private)
make_view :: proc(text: string, width: f32 = 400) -> ^View {
	test_env()
	e := new(View)
	tv := new(textedit.View)
	tv.on_edit = proc(v: ^textedit.View, changes: []buffer.Change) {
		e := (^View)(v.kind_data)
		markdown.doc_edit(e.md, changes)
		edit(e, changes)
	}
	buffer.buffer_init(&tv.buf, transmute([]u8)strings.clone(text))
	append(&tv.sels, textedit.Selection{0, 0, -1})
	doc := new(markdown.Doc)
	markdown.doc_open(doc, &tv.buf)
	markdown.doc_update(doc, &tv.buf, max(int), time.Hour)
	attach(e, tv, doc, nil, .Rendered)
	e.mdv.caretless = false
	e.view = {0, 0, width + 2 * COLUMN_PAD, 300}
	column(e)
	check_heights(e)
	return e
}

@(private)
destroy_view :: proc(e: ^View) {
	buffer.buffer_destroy(&e.buf)
	markdown.doc_destroy(e.md)
	free(e.md)
	destroy(&e.mdv)
	delete(e.sels)
	delete(e.path)
	free(e.tv)
	free(e)
}

// The text of a line's visible runs, joined.
@(private)
shown :: proc(e: ^View, line: int) -> string {
	L := line_layout(e, line)
	text, _ := line_text(e, line)
	sb := strings.builder_make(context.temp_allocator)
	for run in L.runs {
		#partial switch run.kind {
		case .Text, .Mono:
			strings.write_string(&sb, run.subst != {} ? string(L.strings[run.subst[0]:run.subst[1]]) : text[run.lo:run.hi])
		case .Bullet:   strings.write_string(&sb, "•")
		case .Checkbox: strings.write_string(&sb, run.checked ? "☑" : "☐")
		}
	}
	return strings.to_string(sb)
}

// Places the caret at the "|" in `text` and returns an editor without it.
@(private)
view_at :: proc(text: string) -> ^View {
	at := strings.index_byte(text, '|')
	e := make_view(strings.concatenate({text[:at], text[at + 1:]}, context.temp_allocator))
	textedit.set_single_selection(e, {at, at, -1})
	return e
}

@(test)
test_md_hides_syntax :: proc(t: ^testing.T) {
	e := make_view("first\n# Title #\nSome **bold** and `code`, $x = 0$.\n- [x] done\n> quote &amp; more")
	defer destroy_view(e)
	// The caret is on line 0, so the other lines show no syntax.
	testing.expect_value(t, shown(e, 1), "Title")
	testing.expect_value(t, shown(e, 2), "Some bold and code, x = 0.")
	testing.expect_value(t, shown(e, 3), "•☑done")
	testing.expect_value(t, shown(e, 4), "quote & more")

	// A caret in a span shows its markers; on a line, the line's markers.
	textedit.set_single_selection(e, {buffer.line_start(&e.buf, 2) + 7, buffer.line_start(&e.buf, 2) + 7, -1})
	testing.expect_value(t, shown(e, 2), "Some **bold** and code, x = 0.")
	textedit.set_single_selection(e, {buffer.line_start(&e.buf, 1) + 3, buffer.line_start(&e.buf, 1) + 3, -1})
	testing.expect_value(t, shown(e, 1), "# Title #")
}


// A quote's bar runs through its blank ">" lines, and stops at a blank line.
@(test)
test_md_quote_bars :: proc(t: ^testing.T) {
	e := make_view("> a\n>\n> b\n\nc")
	defer destroy_view(e)
	for line in 0 ..< 3 do testing.expectf(t, line_layout(e, line).n_bars == 1, "line %d has no bar", line)
	testing.expect_value(t, line_layout(e, 3).n_bars, 0)
}

// The first line starts below a margin; a click in it is on the first line.
@(test)
test_md_top_margin :: proc(t: ^testing.T) {
	e := make_view("# Title\nbody")
	defer destroy_view(e)
	testing.expect(t, hm_y(&e.mdv.heights, 0) >= f64(body_line_height()) - 1)
	testing.expect_value(t, offset_at_point(e, e.view.x + e.mdv.col_x + 1, e.view.y + 2), 0)
	set_mode(e, .Text)
	set_mode(e, .Rendered)
	testing.expect_value(t, e.scroll_y, 0)
}

// The height map against a plain array, through random splices and updates.
@(test)
test_height_map :: proc(t: ^testing.T) {
	rand.reset(3)
	hm: Height_Map
	defer hm_destroy(&hm)
	ref := make([dynamic]f32)
	defer delete(ref)
	for step in 0 ..< 400 {
		switch rand.int_max(3) {
		case 0:
			at := rand.int_max(len(ref) + 1)
			removed := rand.int_max(min(len(ref) - at, 40) + 1)
			ins := make([]f32, rand.int_max(step % 50 == 0 ? 3000 : 30), context.temp_allocator)
			for &h in ins do h = f32(1 + rand.int_max(40))
			hm_splice(&hm, at, removed, ins)
			remove_range(&ref, at, at + removed)
			inject_at(&ref, at, ..ins)
		case:
			if len(ref) == 0 do continue
			i := rand.int_max(len(ref))
			h := f32(1 + rand.int_max(40))
			hm_set(&hm, i, h)
			ref[i] = h
		}
		testing.expect_value(t, hm.lines, len(ref))
		if len(ref) == 0 do continue
		y: f64
		probe := rand.int_max(len(ref))
		for h in ref[:probe] do y += f64(h)
		testing.expect_value(t, hm_y(&hm, probe), y)
		line, top := hm_find(&hm, y + 0.5)
		testing.expect_value(t, line, probe)
		testing.expect_value(t, top, y)
	}
}

@(test)
test_md_tables :: proc(t: ^testing.T) {
	e := make_view("x\n\n| Name | Value |\n|:--|--:|\n| *one* | 1 |\n| two | 22 |\n\nafter")
	defer destroy_view(e)
	testing.expect_value(t, shown(e, 2), "NameValue")
	testing.expect_value(t, shown(e, 4), "one1")
	tbl := table_at(e, 5)
	testing.expect(t, tbl != nil && tbl.first == 2 && tbl.last == 5)
	testing.expect_value(t, len(tbl.edges), 3)
	testing.expect_value(t, tbl.aligns[1], 2)
	// Right aligned: "1" ends where "22" ends.
	L4, L5 := line_layout(e, 4), line_layout(e, 5)
	r4, r5 := L4.runs[len(L4.runs) - 1], L5.runs[len(L5.runs) - 1]
	testing.expect_value(t, r4.x + r4.w, r5.x + r5.w)
	testing.expect_value(t, line_layout(e, 3).kind, Line_Kind.Thin)

	// With the caret in it, the table stays rendered; the caret's cell shows its
	// syntax and its spaces but the one after its pipe.
	at := buffer.line_start(&e.buf, 4) + 3
	textedit.set_single_selection(e, {at, at, -1})
	testing.expect_value(t, shown(e, 4), "*one* 1")
	testing.expect_value(t, line_layout(e, 4).kind, Line_Kind.Table)

	cells := markdown.row_cells(`| a \| b | c |`)
	testing.expect_value(t, len(cells), 2)

	// Columns are as wide as their cells are laid out: code spans in the code
	// font with their padding, reference links without their labels.
	w := make_view("x\n\n| h |\n|---|\n| `abcd` `efgh` |\n| [ref][r] |\n\n[r]: http://x")
	defer destroy_view(w)
	testing.expect_value(t, line_layout(w, 4).kind, Line_Kind.Table)
	for run in line_layout(w, 4).runs do testing.expect_value(t, run.dy, 0)
	testing.expect_value(t, table_at(w, 4).widths[0], 2 * (4 * 7 + 2 * CODE_SPAN_PAD) + 8 + 2 * CELL_PAD)
	testing.expect_value(t, shown(w, 5), "ref")
}

// A wider pane keeps the caches that depend only on the document, and refits
// tables wider than the text column.
@(test)
test_md_resize :: proc(t: ^testing.T) {
	e := make_view("a *b*\n\n| aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | b |\n|--|--|\n| c | d |", 200)
	defer destroy_view(e)
	begin_caches(e)
	block, tbl, token := block_at(e, 0), table_at(e, 2), e.mdv.doc_token
	testing.expect(t, abs(tbl.edges[2] - 200) <= 1)
	testing.expect_value(t, line_layout(e, 4).edges[2], tbl.x + tbl.edges[2])

	e.view.w = 1000
	column(e)
	begin_caches(e)
	testing.expect(t, block_at(e, 0) == block && table_at(e, 2) == tbl)
	testing.expect_value(t, e.mdv.doc_token, token)
	testing.expect(t, tbl.edges[2] > 200)
	L := line_layout(e, 4)
	testing.expect_value(t, L.edges[2], tbl.x + tbl.edges[2])
}

// Ctrl+click on a footnote reference goes to its definition.
@(test)
test_md_footnote_link :: proc(t: ^testing.T) {
	e := make_view("See this[^1].\n\nmore\n\n[^1]: The note.")
	defer destroy_view(e)
	L := line_layout(e, 0)
	refs := 0
	for run in L.runs {
		if .Super not_in run.style do continue
		refs += 1
		ly := f32(hm_y(&e.mdv.heights, 0)) + L.rows[run.row].y + 2
		target, wiki, found := link_at(e, e.mdv.col_x + run.x + 1, ly)
		testing.expect(t, found && !wiki)
		testing.expect_value(t, target, "#^1")
		open_link(e, target, false)
	}
	testing.expect_value(t, refs, 1)
	testing.expect_value(t, buffer.offset_to_line(&e.buf, e.sels[0].head), 4)
}

// A table fills the text column. When its text doesn't fit on one line it
// wraps, narrow columns keeping their width, and an expand button by its
// header widens it to its text (up to the pane) and back.
@(test)
test_md_table_width :: proc(t: ^testing.T) {
	e := make_view("x\n\n| a | bbbb |\n|---|---|\n| 1 | 2 |", 400)
	defer destroy_view(e)
	begin_caches(e)
	tbl := table_at(e, 2)
	testing.expect_value(t, tbl.x, 0)
	testing.expect_value(t, tbl.edges[2], e.mdv.col_w)
	testing.expect(t, !tbl.wraps)
	// Stretched in proportion to the text.
	testing.expect(t, tbl.edges[2] - tbl.edges[1] > tbl.edges[1])
	_, _, has_button := table_button(e, 2)
	testing.expect(t, !has_button)
	// The rule under the header is one pixel, as the other borders.
	testing.expect_value(t, line_layout(e, 3).height, 1)

	long := strings.repeat("word ", 15, context.temp_allocator)
	w := make_view(strings.concatenate({"x\n\n| h | ", long, "|\n|---|---|\n| 1 | 2 |"}, context.temp_allocator), 200)
	defer destroy_view(w)
	begin_caches(w)
	tbl = table_at(w, 2)
	testing.expect(t, tbl.wraps)
	testing.expect_value(t, tbl.edges[2], w.mdv.col_w)
	testing.expect_value(t, tbl.edges[1], math.round(tbl.widths[0]))
	wrapped := false
	for run in line_layout(w, 2).runs do if run.dy > 0 do wrapped = true
	testing.expect(t, wrapped)

	// The button, in a pane wider than the column.
	w.view.w = 1000
	box, _, ok := table_button(w, 2)
	testing.expect(t, ok)
	y := w.view.y + f32(hm_y(&w.mdv.heights, 2) - w.scroll_y) + box.y + box.h / 2
	x := w.view.x + w.mdv.col_x + box.x + box.w / 2
	testing.expect(t, table_button_click(w, x, y))
	testing.expect(t, tbl.edges[2] > w.mdv.col_w && tbl.x < 0)
	for run in line_layout(w, 2).runs do testing.expect_value(t, run.dy, 0)

	// It stays expanded through edits above it.
	textedit.set_single_selection(w, {0, 0, -1})
	textedit.insert(w, "\n")
	textedit.take_changes(w)
	markdown.doc_update(w.md, &w.buf, max(int), time.Hour)
	testing.expect(t, w.mdv.wide_tables[3])
	begin_caches(w)
	tbl = table_at(w, 3)
	testing.expect(t, tbl.edges[2] > w.mdv.col_w)
	box, _, ok = table_button(w, 3)
	y = w.view.y + f32(hm_y(&w.mdv.heights, 3) - w.scroll_y) + box.y + box.h / 2
	x = w.view.x + w.mdv.col_x + box.x + box.w / 2
	testing.expect(t, ok && table_button_click(w, x, y))
	testing.expect_value(t, tbl.edges[2], w.mdv.col_w)
}

@(test)
test_md_click_past_line_end :: proc(t: ^testing.T) {
	e := make_view("x\nplain text\nends **bold**\nlink [here](http://x)")
	defer destroy_view(e)
	for line in 1 ..= 3 {
		L := line_layout(e, line)
		text, _ := line_text(e, line)
		r := L.rows[len(L.rows) - 1]
		got := index_at(L, text, 390, r.y + r.h / 2)
		testing.expectf(t, got == len(text), "line %d: past the end gives %d, want %d", line, got, len(text))
	}
	// Past a wrapped row: before the space it wrapped at.
	para := strings.repeat("word ", 24, context.temp_allocator)
	w := make_view(para)
	defer destroy_view(w)
	L := line_layout(w, 0)
	text, _ := line_text(w, 0)
	testing.expect_value(t, index_at(L, text, 399, L.rows[0].y + 1), 49)
}

@(test)
test_md_code_blocks :: proc(t: ^testing.T) {
	long := strings.repeat("abcdefghij", 12, context.temp_allocator)
	e := make_view(strings.concatenate({"x\n\n```\n", long, "\nshort\n```\n\n```odin\ny := 1\n```"}, context.temp_allocator))
	defer destroy_view(e)
	e.view.h = 600
	// A long line stays on one row, and plain fences aren't colored.
	L := line_layout(e, 3)
	testing.expect_value(t, len(L.rows), 1)
	testing.expect_value(t, L.runs[0].color, Color.Text)
	testing.expect_value(t, line_layout(e, 8).runs[0].color, Color.Code)

	// Sideways scrolling over the block moves its lines, within bounds,
	// without laying them out again.
	x0 := L.runs[0].x
	y := f32(hm_y(&e.mdv.heights, 3)) + 2
	for line in 2 ..= 5 do line_layout(e, line)
	layouts := len(e.mdv.layouts)
	testing.expect(t, scroll_code_at(e, y, 100))
	for line in 2 ..= 5 do line_layout(e, line)
	testing.expect_value(t, len(e.mdv.layouts), layouts)
	testing.expect(t, line_layout(e, 3) == L)
	testing.expect_value(t, md_run(line_layout(e, 3), 0).x, x0 - 100)
	testing.expect_value(t, md_run(line_layout(e, 4), 0).x, x0 - 100)
	// Scrolled code is still code, not a marker hanging left of the text.
	L3 := line_layout(e, 3)
	testing.expect(t, !hanging(L3, md_run(L3, 0)))
	text3, _ := line_text(e, 3)
	_, cx := caret_row_x(L3, text3, 20)
	testing.expect_value(t, cx, md_run(L3, 0).x + 20 * L3.char_w)
	testing.expect_value(t, index_at(L3, text3, cx, L3.rows[0].y + 1), 20)
	scroll_code_at(e, y, 1e6)
	width, box := code_widths(e, code_block_at(e, 2) or_else nil)
	testing.expect_value(t, e.mdv.code_scroll[2], width - box)
	testing.expect(t, !scroll_code_at(e, f32(hm_y(&e.mdv.heights, 8)) + 2, 10))

	// Moving the caret to the start of the line scrolls back to it.
	at := buffer.line_start(&e.buf, 3)
	textedit.set_single_selection(e, {at, at, -1})
	reveal_caret(e)
	testing.expect_value(t, e.mdv.code_scroll[2], 0)
}

// On an empty line of a code block, the caret is where the block's text
// starts (inside the box, scrolled with it), like on its other lines.
@(test)
test_md_code_empty_line_caret :: proc(t: ^testing.T) {
	e := make_view("x\n\n```\na\n\nb\n```")
	defer destroy_view(e)
	e.view.h = 600
	start_x :: proc(e: ^View, line: int) -> f32 {
		at := buffer.line_start(&e.buf, line)
		textedit.set_single_selection(e, {at, at, -1})
		text, _ := line_text(e, line)
		_, x, _, _ := caret_box(line_layout(e, line), text, 0)
		return x
	}
	testing.expect_value(t, start_x(e, 4), start_x(e, 3))
	set_code_scroll(e, 2, 30)
	testing.expect_value(t, start_x(e, 4), start_x(e, 3))
}

@(test)
test_md_fences_keep_height :: proc(t: ^testing.T) {
	e := make_view("x\n\n```odin\ny := 1\n```\n\nafter")
	defer destroy_view(e)
	open_h, close_h := line_layout(e, 2).height, line_layout(e, 4).height
	testing.expect_value(t, shown(e, 2), "odin") // the language, as a label
	at := buffer.line_start(&e.buf, 3)
	textedit.set_single_selection(e, {at, at, -1})
	testing.expect_value(t, shown(e, 2), "```odin")
	testing.expect_value(t, line_layout(e, 2).height, open_h)
	testing.expect_value(t, line_layout(e, 4).height, close_h)
}

// Blank and lazy lines are indented only as far as their own text continues
// their containers.
@(test)
test_md_line_indent :: proc(t: ^testing.T) {
	indent :: proc(e: ^View, line: int) -> f32 {
		text, _ := line_text(e, line)
		_, x := caret_row_x(line_layout(e, line), text, 0)
		return x
	}
	item := make_view("- a\n  b")
	defer destroy_view(item)
	in_item := indent(item, 1)
	testing.expect(t, in_item > 0)

	cases := [?]struct{text: string, inside: bool} {
		{"- a\n", false},
		{"- a\nb", false},
		{"- a\n  ", true},
		{"- a\n\n  b", true},
		{"> - a\n> ", false},
	}
	for c in cases {
		e := make_view(c.text)
		defer destroy_view(e)
		x := indent(e, len(e.md.lines) - 1)
		testing.expectf(t, (x == in_item) == c.inside, "%q: last line at x %v", c.text, x)
	}

	// An empty item's text starts where a full one's does.
	for s in ([]string{"x\n\n- ", "- a\n- ", "x\n\n1. "}) {
		e := make_view(s)
		defer destroy_view(e)
		line := len(e.md.lines) - 1
		text, _ := line_text(e, line)
		_, x := caret_row_x(line_layout(e, line), text, len(text))
		testing.expectf(t, x == in_item || s == "x\n\n1. " && x > 0, "%q: empty item text at x %v", s, x)
	}

	// Leaving a list with Enter puts the caret back at the margin.
	e := view_at("- a\n- |")
	defer destroy_view(e)
	insert_newline(e)
	textedit.take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	testing.expect_value(t, indent(e, 1), 0)
}

// --- Typing sequences ----------------------------------------------------------------
// Keys replayed through the editor's handlers: characters are typed, except
// ⏎ Enter, ⌫ Backspace, ⌦ Delete, ⇥ Tab, ⇤ Shift+Tab, the arrows ← → ↑ ↓ and
// ↶ undo. After every key the incremental parse must match a full one and the
// caret must be in shown text.

