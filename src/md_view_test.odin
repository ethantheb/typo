package editor

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "buffer"
import "markdown"
import sdl "../vendor/sdl3"

// Tests for the rendered Markdown view. Without a text engine, every character
// is half the font size wide (see text_width).

@(private = "file")
make_md_editor :: proc(text: string, width: f32 = 400) -> ^Editor {
	g.settings.font_size = 15
	g.settings.line_height = 1.35
	g.settings.markdown_font_size = 16
	g.settings.markdown_line_height = 1.5
	g.settings.markdown_max_width = 0
	e := new(Editor)
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(text))
	e.status = .Text
	append(&e.sels, Selection{0, 0, -1})
	e.md = new(markdown.Doc)
	markdown.doc_open(e.md, &e.buf)
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	e.mdv.mode = .Rendered
	e.view = {0, 0, width + 2 * MD_COLUMN_PAD, 300}
	md_column(e)
	md_check_heights(e)
	return e
}

@(private = "file")
destroy_md_editor :: proc(e: ^Editor) {
	editor_destroy(e)
	free(e)
}

// The text of a line's visible runs, joined.
@(private = "file")
shown :: proc(e: ^Editor, line: int) -> string {
	L := md_line_layout(e, line)
	text, _ := md_line_text(e, line)
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

@(test)
test_md_hides_syntax :: proc(t: ^testing.T) {
	e := make_md_editor("first\n# Title #\nSome **bold** and `code`, $x = 0$.\n- [x] done\n> quote &amp; more")
	defer destroy_md_editor(e)
	// The caret is on line 0, so the other lines show no syntax.
	testing.expect_value(t, shown(e, 1), "Title")
	testing.expect_value(t, shown(e, 2), "Some bold and code, x = 0.")
	testing.expect_value(t, shown(e, 3), "•☑done")
	testing.expect_value(t, shown(e, 4), "quote & more")

	// A caret in a span shows its markers; on a line, the line's markers.
	set_single_selection(e, {buffer.line_start(&e.buf, 2) + 7, buffer.line_start(&e.buf, 2) + 7, -1})
	testing.expect_value(t, shown(e, 2), "Some **bold** and code, x = 0.")
	set_single_selection(e, {buffer.line_start(&e.buf, 1) + 3, buffer.line_start(&e.buf, 1) + 3, -1})
	testing.expect_value(t, shown(e, 1), "# Title #")
}


@(test)
test_md_wrapped_rows :: proc(t: ^testing.T) {
	// 8 px per character in a 400 px column: 50 characters per row.
	para := strings.repeat("word ", 24, context.temp_allocator)
	e := make_md_editor(strings.concatenate({para, "\nnext"}, context.temp_allocator))
	defer destroy_md_editor(e)
	L := md_line_layout(e, 0)
	testing.expect_value(t, len(L.rows), 3)
	testing.expect_value(t, L.rows[1].lo, 50)

	// Down keeps the x through the rows, then reaches the next line.
	set_single_selection(e, {7, 7, -1})
	editor_move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 57)
	editor_move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 107)
	editor_move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 121 + 4) // "next" is shorter
	editor_move(e, .Up, false)
	testing.expect_value(t, e.sels[0].head, 107)

	// Home and End work on the visual row.
	set_single_selection(e, {57, 57, -1})
	editor_move(e, .Home, false)
	testing.expect_value(t, e.sels[0].head, 50)
	editor_move(e, .End, false)
	testing.expect_value(t, e.sels[0].head, 99) // before the space it wrapped at
	editor_move(e, .Home, false)
	editor_move(e, .Home, false)
	testing.expect_value(t, e.sels[0].head, 50)

	// Points and offsets agree.
	text, _ := md_line_text(e, 0)
	for k in 0 ..= len(text) {
		row, x := md_caret_x(L, text, k)
		r := L.rows[row]
		got := md_index_at(L, text, x, r.y + r.h / 2)
		ok := got == k || (k == int(r.lo) && row > 0 && got == k - 1)
		testing.expectf(t, ok, "offset %d: point %v gives %d", k, x, got)
	}
}

@(test)
test_md_carets_never_in_hidden_text :: proc(t: ^testing.T) {
	text := "# Head\n\nSome **bold** `code` [link](http://x) &amp; ~~s~~\n- [ ] task\n> quote\n\n```odin\nx := 1\n```\n---\nend"
	e := make_md_editor(text)
	defer destroy_md_editor(e)
	for k in 0 ..= len(text) {
		set_single_selection(e, {k, k, -1})
		testing.expectf(t, caret_shown(e, k), "caret at %d is in hidden text", k)
	}
}

@(test)
test_md_toggle_keeps_top_line :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 do strings.write_string(&sb, i % 10 == 0 ? "# Heading\n" : "Some text on a line.\n")
	e := make_md_editor(strings.to_string(sb))
	defer destroy_md_editor(e)
	md_set_mode(e, .Text)
	scroll_to(e, f64(60 * editor_line_height()))
	md_set_mode(e, .Rendered)
	line, _ := hm_find(&e.mdv.heights, e.scroll_y)
	testing.expect_value(t, line, 60)
	md_set_mode(e, .Text)
	testing.expect_value(t, int(e.scroll_y) / editor_line_height(), 60)

	// Page Down moves the caret about a screen.
	md_set_mode(e, .Rendered)
	set_single_selection(e, {0, 0, -1})
	scroll_to(e, 0)
	editor_move(e, .Page_Down, false)
	moved := hm_y(&e.mdv.heights, buffer.offset_to_line(&e.buf, e.sels[0].head))
	testing.expect(t, moved > md_page_height(e) - 60 && moved < md_page_height(e) + 60)
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
	e := make_md_editor("x\n\n| Name | Value |\n|:--|--:|\n| *one* | 1 |\n| two | 22 |\n\nafter")
	defer destroy_md_editor(e)
	testing.expect_value(t, shown(e, 2), "NameValue")
	testing.expect_value(t, shown(e, 4), "one1")
	tbl := md_table(e, 5)
	testing.expect(t, tbl != nil && tbl.first == 2 && tbl.last == 5)
	testing.expect_value(t, len(tbl.edges), 3)
	testing.expect_value(t, tbl.aligns[1], 2)
	// Right aligned: "1" ends where "22" ends.
	L4, L5 := md_line_layout(e, 4), md_line_layout(e, 5)
	r4, r5 := L4.runs[len(L4.runs) - 1], L5.runs[len(L5.runs) - 1]
	testing.expect_value(t, r4.x + r4.w, r5.x + r5.w)
	testing.expect_value(t, md_line_layout(e, 3).kind, Md_Line_Kind.Thin)

	// With the caret in it, the table shows its source.
	at := buffer.line_start(&e.buf, 4) + 3
	set_single_selection(e, {at, at, -1})
	testing.expect_value(t, shown(e, 4), "| *one* | 1 |")
	testing.expect_value(t, md_line_layout(e, 2).kind, Md_Line_Kind.Code)

	cells := table_cells(`| a \| b | c |`, 0)
	testing.expect_value(t, len(cells), 2)
}

@(test)
test_md_checkbox_and_links :: proc(t: ^testing.T) {
	e := make_md_editor("x\n- [ ] task\n\nSee [docs][ref] and [site](https://example.com).\n\n[ref]: notes/doc.md")
	defer destroy_md_editor(e)
	e.view = {0, 0, e.view.w, 600}

	// Clicking a task box toggles it as one undoable edit, leaving the caret.
	L := md_line_layout(e, 1)
	box: Md_Run
	for run in L.runs do if run.kind == .Checkbox do box = run
	testing.expect_value(t, box.kind, Md_Run_Kind.Checkbox)
	y := f32(hm_y(&e.mdv.heights, 1)) + L.rows[0].y + L.rows[0].h / 2
	lo, hi, ok := md_checkbox_at(e, e.mdv.col_x + box.x + box.w / 2, y)
	testing.expect(t, ok)
	editor_replace_in_place(e, lo, hi, "[x]")
	testing.expect_value(t, string(buffer.read_alloc(&e.buf, lo, hi)), "[x]")
	testing.expect_value(t, e.sels[0].head, 0)
	editor_undo(e)
	testing.expect_value(t, string(buffer.read_alloc(&e.buf, lo, hi)), "[ ]")

	// Links resolve under their text, references through the definition.
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	L = md_line_layout(e, 3)
	text, _ := md_line_text(e, 3)
	targets := make([dynamic]string, context.temp_allocator)
	for run in L.runs {
		if .Underline not_in run.style do continue
		ly := f32(hm_y(&e.mdv.heights, 3)) + L.rows[run.row].y + 2
		target, wiki, found := md_link_at(e, e.mdv.col_x + run.x + 1, ly)
		testing.expectf(t, found && !wiki, "no link at %q", text[run.lo:run.hi])
		append(&targets, target)
	}
	testing.expect_value(t, len(targets), 2)
	if len(targets) == 2 {
		testing.expect_value(t, targets[0], "notes/doc.md")
		testing.expect_value(t, targets[1], "https://example.com")
	}
}

@(private = "file")
md_text :: proc(e: ^Editor) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
}

// Places the caret at the "|" in `text` and returns an editor without it.
@(private = "file")
md_editor_at :: proc(text: string) -> ^Editor {
	at := strings.index_byte(text, '|')
	e := make_md_editor(strings.concatenate({text[:at], text[at + 1:]}, context.temp_allocator))
	set_single_selection(e, {at, at, -1})
	return e
}

@(private = "file")
expect_after :: proc(t: ^testing.T, e: ^Editor, want: string, loc := #caller_location) {
	got := md_text(e)
	at := e.sels[0].head
	got = strings.concatenate({got[:at], "|", got[at:]}, context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}

@(test)
test_md_enter_continues_lists :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"- one|", "- one\n- |"},
		{"* one|", "* one\n* |"},
		{"1. one|", "1. one\n2. |"},
		{"9) nine|", "9) nine\n10) |"},
		{"- [x] done|", "- [x] done\n- [ ] |"},
		{"- one|two", "- one\n- |two"},
		{"> quote|", "> quote\n> |"},
		{"> - in quote|", "> - in quote\n> - |"},
		{"- a\n  - nested|", "- a\n  - nested\n  - |"},
		// An empty item leaves the list, or moves out a level when nested.
		{"- a\n- |", "- a\n|"},
		{"- a\n- [ ] |", "- a\n|"},
		{"- a\n  - |", "- a\n- |"},
		{"> a\n> |", "> a\n|"},
		// Before an item's text, Enter is a plain newline.
		{"|- one", "\n|- one"},
		{"plain|", "plain\n|"},
	}
	for c in cases do expect_typing(t, c[0], {{"⏎", c[1], ""}})
}

@(test)
test_md_list_indent :: proc(t: ^testing.T) {
	e := md_editor_at("- a\n- b|")
	defer destroy_md_editor(e)
	testing.expect(t, md_indent(e, 1))
	expect_after(t, e, "- a\n  - b|")
	testing.expect(t, md_indent(e, -1))
	expect_after(t, e, "- a\n- b|")
	// Shift+Tab at the top level leaves the list.
	testing.expect(t, md_indent(e, -1))
	expect_after(t, e, "- a\nb|")
	testing.expect(t, !md_indent(e, 1))
	editor_undo(e)
	expect_after(t, e, "- a\n- b|")

	o := md_editor_at("1. a\n2. b|")
	defer destroy_md_editor(o)
	md_indent(o, 1)
	expect_after(t, o, "1. a\n   2. b|")

	// Backspace at the start of an item's text removes its marker.
	b := md_editor_at("- a\n- |b")
	defer destroy_md_editor(b)
	testing.expect(t, md_backspace(b))
	expect_after(t, b, "- a\n|b")
	b2 := md_editor_at("- a\n- b|")
	defer destroy_md_editor(b2)
	testing.expect(t, !md_backspace(b2))
}

@(test)
test_md_click_past_line_end :: proc(t: ^testing.T) {
	e := make_md_editor("x\nplain text\nends **bold**\nlink [here](http://x)")
	defer destroy_md_editor(e)
	for line in 1 ..= 3 {
		L := md_line_layout(e, line)
		text, _ := md_line_text(e, line)
		r := L.rows[len(L.rows) - 1]
		got := md_index_at(L, text, 390, r.y + r.h / 2)
		testing.expectf(t, got == len(text), "line %d: past the end gives %d, want %d", line, got, len(text))
	}
	// Past a wrapped row: before the space it wrapped at.
	para := strings.repeat("word ", 24, context.temp_allocator)
	w := make_md_editor(para)
	defer destroy_md_editor(w)
	L := md_line_layout(w, 0)
	text, _ := md_line_text(w, 0)
	testing.expect_value(t, md_index_at(L, text, 399, L.rows[0].y + 1), 49)
}

@(test)
test_md_caretless :: proc(t: ^testing.T) {
	e := make_md_editor("# Title\n\nSome **bold** text.")
	defer destroy_md_editor(e)
	e.mdv.caretless = true
	// With no caret, nothing is revealed and typing does nothing.
	testing.expect_value(t, shown(e, 0), "Title")
	editor_text_input(e, "x")
	testing.expect_value(t, md_text(e), "# Title\n\nSome **bold** text.")
	testing.expect(t, editor_run_command(e, .Paste))

	// Beside the text column is outside it; the column is inside.
	testing.expect(t, !md_column_hit(e, e.view.x + 2, 10))
	testing.expect(t, md_column_hit(e, e.view.x + e.mdv.col_x + 10, 10))

	// An arrow key shows the caret, here where it was (on screen).
	key: sdl.KeyboardEvent
	key.key = sdl.K_DOWN
	testing.expect(t, editor_handle_key(e, key))
	testing.expect(t, !e.mdv.caretless)
	testing.expect_value(t, shown(e, 0), "# Title")
}

@(test)
test_md_code_blocks :: proc(t: ^testing.T) {
	long := strings.repeat("abcdefghij", 12, context.temp_allocator)
	e := make_md_editor(strings.concatenate({"x\n\n```\n", long, "\nshort\n```\n\n```odin\ny := 1\n```"}, context.temp_allocator))
	defer destroy_md_editor(e)
	e.view.h = 600
	// A long line stays on one row, and plain fences aren't colored.
	L := md_line_layout(e, 3)
	testing.expect_value(t, len(L.rows), 1)
	testing.expect_value(t, L.runs[0].color, Md_Color.Text)
	testing.expect_value(t, md_line_layout(e, 8).runs[0].color, Md_Color.Code)

	// Sideways scrolling over the block moves its lines, within bounds.
	x0 := L.runs[0].x
	y := f32(hm_y(&e.mdv.heights, 3)) + 2
	testing.expect(t, md_scroll_code_at(e, y, 100))
	testing.expect_value(t, md_line_layout(e, 3).runs[0].x, x0 - 100)
	testing.expect_value(t, md_line_layout(e, 4).runs[0].x, x0 - 100)
	md_scroll_code_at(e, y, 1e6)
	width, box := md_code_widths(e, md_code_block(e, 2) or_else nil)
	testing.expect_value(t, e.mdv.code_scroll[2], width - box)
	testing.expect(t, !md_scroll_code_at(e, f32(hm_y(&e.mdv.heights, 8)) + 2, 10))

	// Moving the caret to the start of the line scrolls back to it.
	at := buffer.line_start(&e.buf, 3)
	set_single_selection(e, {at, at, -1})
	md_reveal(e)
	testing.expect_value(t, e.mdv.code_scroll[2], 0)
}

@(test)
test_md_code_scroll_bar :: proc(t: ^testing.T) {
	long := strings.repeat("abcdefghij", 12, context.temp_allocator)
	e := make_md_editor(strings.concatenate({"x\n\n```\n", long, "\n```\n\nafter"}, context.temp_allocator))
	defer destroy_md_editor(e)
	e.view.h = 600
	track, thumb, first, ok := md_code_bar(e, 4)
	testing.expect(t, ok && first == 2)
	_, _, _, ok = md_code_bar(e, 3) // only under the block's last line
	testing.expect(t, !ok)
	width, box := md_code_widths(e, md_code_block(e, 2) or_else nil)

	// Dragging the thumb to the end of its track scrolls to the end.
	defer g.mouse_pos, g.mouse_pressed, g.mouse_down = {}, false, false
	g.mouse_pos = {thumb.x + 2, thumb.y + 1}
	g.mouse_pressed, g.mouse_down = true, true
	testing.expect(t, md_code_bar_mouse(e))
	g.mouse_pressed = false
	g.mouse_pos.x = track.x + track.w + 50
	md_code_bar_mouse(e)
	testing.expect_value(t, e.mdv.code_scroll[2], width - box)
	g.mouse_down = false
	md_code_bar_mouse(e)
	testing.expect(t, !e.mdv.code_drag.active)

	// Clicking the track's left end jumps back.
	g.mouse_pos = {track.x + 1, track.y + 1}
	g.mouse_pressed, g.mouse_down = true, true
	md_code_bar_mouse(e)
	testing.expect_value(t, e.mdv.code_scroll[2], 0)
	g.mouse_pressed, g.mouse_down = false, false
	md_code_bar_mouse(e)

	// Drag-selecting past the block's right side scrolls it.
	g.mouse_pos = {e.view.x + e.view.w + 20, e.view.y + f32(hm_y(&e.mdv.heights, 3)) + 4}
	md_drag_scroll_code(e)
	testing.expect(t, e.mdv.code_scroll[2] > 0)
}

@(test)
test_md_fences_keep_height :: proc(t: ^testing.T) {
	e := make_md_editor("x\n\n```odin\ny := 1\n```\n\nafter")
	defer destroy_md_editor(e)
	open_h, close_h := md_line_layout(e, 2).height, md_line_layout(e, 4).height
	testing.expect_value(t, shown(e, 2), "odin") // the language, as a label
	at := buffer.line_start(&e.buf, 3)
	set_single_selection(e, {at, at, -1})
	testing.expect_value(t, shown(e, 2), "```odin")
	testing.expect_value(t, md_line_layout(e, 2).height, open_h)
	testing.expect_value(t, md_line_layout(e, 4).height, close_h)
}

// Blank and lazy lines are indented only as far as their own text continues
// their containers.
@(test)
test_md_line_indent :: proc(t: ^testing.T) {
	indent :: proc(e: ^Editor, line: int) -> f32 {
		text, _ := md_line_text(e, line)
		_, x := md_caret_x(md_line_layout(e, line), text, 0)
		return x
	}
	item := make_md_editor("- a\n  b")
	defer destroy_md_editor(item)
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
		e := make_md_editor(c.text)
		defer destroy_md_editor(e)
		x := indent(e, len(e.md.lines) - 1)
		testing.expectf(t, (x == in_item) == c.inside, "%q: last line at x %v", c.text, x)
	}

	// An empty item's text starts where a full one's does.
	for s in ([]string{"x\n\n- ", "- a\n- ", "x\n\n1. "}) {
		e := make_md_editor(s)
		defer destroy_md_editor(e)
		line := len(e.md.lines) - 1
		text, _ := md_line_text(e, line)
		_, x := md_caret_x(md_line_layout(e, line), text, len(text))
		testing.expectf(t, x == in_item || s == "x\n\n1. " && x > 0, "%q: empty item text at x %v", s, x)
	}

	// Leaving a list with Enter puts the caret back at the margin.
	e := md_editor_at("- a\n- |")
	defer destroy_md_editor(e)
	md_newline(e)
	editor_take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	testing.expect_value(t, indent(e, 1), 0)
}

// --- Typing sequences ----------------------------------------------------------------
// Keys replayed through the editor's handlers: characters are typed, except
// ⏎ Enter, ⌫ Backspace, ⇥ Tab and ⇤ Shift+Tab. After every key the incremental
// parse must match a full one and the caret must be in shown text.

@(private = "file")
Typing_Step :: struct {
	keys:     string,
	text:     string, // after the keys, "|" at the caret
	rendered: string, // see `rendered`; "" skips the check
}

// The lines as drawn: two spaces per indentation level, "H " on a heading,
// then the shown text.
@(private = "file")
rendered :: proc(e: ^Editor) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in 0 ..< len(e.md.lines) {
		L := md_line_layout(e, line)
		heading := false
		for run in L.runs do if run.kind == .Text && run.size > md_font_size() do heading = true
		level := int(L.indent / MD_LIST_INDENT + 0.5)
		append(&lines, strings.concatenate({strings.repeat("  ", level, context.temp_allocator), heading ? "H " : "", shown(e, line)}, context.temp_allocator))
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// Whether bytes [k, k + n) are drawn as text (n = 0: a caret at k is in or
// at the edge of drawn text). A run drawn in place of its bytes (a tab, an
// entity) has no inner positions.
@(private = "file")
shown_at :: proc(e: ^Editor, k: int, n := 0) -> bool {
	line := buffer.offset_to_line(&e.buf, k)
	at := k - buffer.line_start(&e.buf, line)
	for run in md_line_layout(e, line).runs {
		if run.kind != .Text && run.kind != .Mono do continue
		if run.subst == {} ? int(run.lo) <= at && at + n <= int(run.hi) : at == int(run.lo) && (n == 0 || at + n == int(run.hi)) || n == 0 && at == int(run.hi) do return true
	}
	return false
}

// Whether only hidden spaces separate byte k from what is drawn after it (text,
// a bullet or a task box) on its line, or from where the line's text starts
// after its list and quote markers: indentation, which is syntax.
@(private = "file")
before_shown :: proc(e: ^Editor, k: int) -> bool {
	line := buffer.offset_to_line(&e.buf, k)
	text, start := md_line_text(e, line)
	at := k - start
	content := int(markdown.line_detail(e.md, line, text).content[0])
	if p := md_prefix(e, line); p.ok do content = p.content
	if at <= content && strings.trim_space(text[at:content]) == "" do return true
	next := -1
	for run in md_line_layout(e, line).runs {
		if int(run.lo) >= at && run.hi > run.lo && (next < 0 || int(run.lo) < next) do next = int(run.lo)
	}
	return next >= 0 && strings.trim_space(text[at:next]) == ""
}

// Whether a caret at byte k is drawn where it is in the text.
@(private = "file")
caret_shown :: proc(e: ^Editor, k: int) -> bool {
	return shown_at(e, k) || before_shown(e, k)
}

// Where the primary caret is drawn: its line, row and x.
@(private = "file")
caret_place :: proc(e: ^Editor) -> [3]f32 {
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	text, start := md_line_text(e, line)
	row, x := md_caret_x(md_line_layout(e, line), text, head - start)
	return {f32(line), f32(row), x}
}

@(private = "file")
press :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod = {}) {
	editor_handle_key(e, {key = key, mod = mod})
}

@(private = "file")
play :: proc(t: ^testing.T, e: ^Editor, keys: string, label := "", loc := #caller_location) {
	for r, i in keys {
		before, version := caret_place(e), e.buf.version
		switch r {
		case '⏎': press(e, sdl.K_RETURN)
		case '⌫': press(e, sdl.K_BACKSPACE)
		case '⇥': press(e, sdl.K_TAB)
		case '⇤': press(e, sdl.K_TAB, sdl.KMOD_SHIFT)
		case:
			buf, n := utf8.encode_rune(r)
			editor_text_input(e, string(buf[:n]))
		}
		editor_take_changes(e)
		markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
		md_check_heights(e)

		full: markdown.Doc
		defer markdown.doc_destroy(&full)
		markdown.doc_open(&full, &e.buf)
		markdown.doc_update(&full, &e.buf, max(int), time.Hour)
		for l, k in full.lines {
			a := e.md.lines[k]
			same := a.kind == l.kind && a.aux == l.aux && a.flags == l.flags && markdown.line_state(e.md, k) == markdown.line_state(&full, k)
			testing.expectf(t, same, "%safter %q: line %d parsed as %v, a full parse gives %v", label, keys[:i + utf8.rune_size(r)], k, a.kind, l.kind, loc = loc)
		}
		testing.expectf(t, caret_shown(e, e.sels[0].head), "%safter %q: caret in hidden text", label, keys[:i + utf8.rune_size(r)], loc = loc)
		// What is typed is drawn, unless it is indentation; Enter moves the caret.
		head := e.sels[0].head
		typed := r == '⇥' ? '\t' : r
		n := utf8.rune_size(typed)
		switch {
		case e.buf.version == version, r == '⌫', r == '⇤':
		case r == '⏎':
			testing.expectf(t, caret_place(e) != before, "%safter %q: the caret didn't move", label, keys[:i + utf8.rune_size(r)], loc = loc)
		case head >= n && string(buffer.read_alloc(&e.buf, head - n, head)) == utf8.runes_to_string({typed}, context.temp_allocator):
			whitespace := typed == ' ' || typed == '\t'
			testing.expectf(t, shown_at(e, head - n, n) || whitespace && before_shown(e, head - n), "%safter %q: %q isn't shown", label, keys[:i + utf8.rune_size(r)], typed, loc = loc)
		}
	}
}

// Replays steps from `start` ("|" at the caret), checking each one's result.
@(private = "file")
expect_typing :: proc(t: ^testing.T, start: string, steps: []Typing_Step, loc := #caller_location) {
	e := md_editor_at(start)
	defer destroy_md_editor(e)
	for s in steps {
		play(t, e, s.keys, loc = loc)
		expect_after(t, e, s.text, loc)
		if s.rendered != "" do testing.expectf(t, rendered(e) == s.rendered, "after %q: rendered\n%s\nwant\n%s", s.keys, rendered(e), s.rendered, loc = loc)
	}
}

@(test)
test_md_typing_lists :: proc(t: ^testing.T) {
	// A list started under a paragraph doesn't make it a heading, and leaving
	// it goes back to the margin.
	expect_typing(t, "|", {
		{"Para⏎-", "Para\n-|", "Para\n-"},
		{" ", "Para\n- |", "Para\n  •"},
		{"one", "Para\n- one|", "Para\n  •one"},
		{"⏎", "Para\n- one\n- |", "Para\n  •one\n  •"},
		{"two⏎⏎", "Para\n- one\n- two\n|", "Para\n  •one\n  •two\n"},
		{"after", "Para\n- one\n- two\nafter|", "Para\n  •one\n  •two\nafter"},
	})
	expect_typing(t, "|", {
		{"Para⏎1. ", "Para\n1. |", ""},
		{"a⏎b⏎⏎c", "Para\n1. a\n2. b\nc|", "Para\n  1.a\n  2.b\nc"},
	})
	// A real underline still makes a heading.
	expect_typing(t, "|", {{"Title⏎--⏎", "Title\n--\n|", "H Title\n\n"}})

	// Tab and Shift+Tab.
	expect_typing(t, "|", {
		{"- a⏎⇥b", "- a\n  - b|", "  •a\n    •b"},
		{"⇤", "- a\n- b|", "  •a\n  •b"},
		{"⇤", "- a\nb|", "  •a\nb"},
	})

	// Backspace at an item's text moves it out a level at a time, then
	// removes its marker.
	expect_typing(t, "|", {
		{"- a⏎⇥b⏎⇥", "- a\n  - b\n    - |", ""},
		{"⌫", "- a\n  - b\n  - |", ""},
		{"⌫", "- a\n  - b\n- |", ""},
		{"⌫", "- a\n  - b\n|", "  •a\n    •b\n"},
		{"⌫", "- a\n  - b|", ""},
	})
	expect_typing(t, "- a\n  - b\n    - |c", {
		{"⌫", "- a\n  - b\n  - |c", ""},
		{"⌫", "- a\n  - b\n- |c", ""},
		{"⌫", "- a\n  - b\n|c", ""},
	})

	// Backspace in the indentation under a list deletes a level at a time.
	expect_typing(t, "- a\n  - b\n    |", {
		{"⌫", "- a\n  - b\n  |", ""},
		{"⌫", "- a\n  - b\n|", ""},
	})
	expect_typing(t, "- a\n  - b\n    |c", {
		{"⌫", "- a\n  - b\n  |c", "  •a\n    •b\n  c"},
		{"⌫", "- a\n  - b\n|c", "  •a\n    •b\nc"},
	})
	expect_typing(t, "- a\n|", {{"   ⌫", "- a\n  |", ""}})
	// Outside a list, one space at a time.
	expect_typing(t, "x\n    |y", {{"⌫", "x\n   |y", ""}})

	// Quotes.
	expect_typing(t, "|", {
		{"> a⏎", "> a\n> |", ""},
		{"⏎b", "> a\nb|", ""},
	})
}

@(test)
test_md_typing_indentation :: proc(t: ^testing.T) {
	// An item indents only under the item before it, after it is written too.
	expect_typing(t, "- a|", {{"⇥", "- a|", ""}})
	expect_typing(t, "|", {
		{"- a⏎b⇥", "- a\n  - b|", "  •a\n    •b"},
		{"⇥", "- a\n  - b|", ""},
		{"⏎c⇥", "- a\n  - b\n    - c|", ""},
	})
	expect_typing(t, "Para\n- a|", {{"⇥", "Para\n- a|", ""}})

	// Tab types a tab outside list items, shown while the line is edited.
	expect_typing(t, "|", {{"Hello⏎⇥⇥", "Hello\n\t\t|", "Hello\n        "}})
	expect_typing(t, "|Hello", {{"⇥", "\t|Hello", ""}})
	expect_typing(t, "Hello|", {{"⇥", "Hello\t|", "Hello    "}})
	expect_typing(t, "Hel|lo", {{"⇥", "Hel\t|lo", "Hel    lo"}})

	// Enter keeps indentation only as far as it places the line in its block.
	expect_typing(t, "x\n\n\t\t|", {{"⏎Hello", "x\n\n\t\t\nHello|", "x\n\n\nHello"}})
	expect_typing(t, "- a\n  b|", {{"⏎c", "- a\n  b\n  c|", "  •a\n  b\n  c"}})
	expect_typing(t, "x\n\n    code|", {{"⏎", "x\n\n    code\n    |", ""}})
	expect_typing(t, "```\n\tcode|\n```", {{"⏎", "```\n\tcode\n\t|\n```", ""}})

	// Spaces show while their line is edited, even on a blank line, and
	// Backspace deletes them one at a time.
	expect_typing(t, "x\n\n|", {
		{"  ", "x\n\n  |", "x\n\n  "},
		{"\t", "x\n\n  \t|", "x\n\n      "},
		{"⌫⌫", "x\n\n |", ""},
		{"⏎", "x\n\n \n|", "x\n\n\n"},
	})
}

// The text view edits Markdown like any other file.
@(test)
test_md_text_view_plain_keys :: proc(t: ^testing.T) {
	e := md_editor_at("- a\n  - |")
	defer destroy_md_editor(e)
	md_set_mode(e, .Text)
	press(e, sdl.K_RETURN)
	expect_after(t, e, "- a\n  - \n  |")
	press(e, sdl.K_TAB)
	expect_after(t, e, "- a\n  - \n  \t|")
	press(e, sdl.K_TAB, sdl.KMOD_SHIFT)
	expect_after(t, e, "- a\n  - \n  \t|")
	press(e, sdl.K_BACKSPACE)
	press(e, sdl.K_BACKSPACE)
	expect_after(t, e, "- a\n  - \n |")
}

// Every key at every caret position of small documents covering each kind of
// line, through the checks in `play`.
@(test)
test_md_typing_everywhere :: proc(t: ^testing.T) {
	docs := [?]string {
		"Hello world",
		"Para\nmore\n\nNext",
		"# Heading",
		"Title\n--",
		"- item\n- second",
		"1. one\n2. two",
		"- [ ] task",
		"- a\n  - nested\n\n  b",
		"> quote\n> more",
		"> - in quote",
		"| a | b |\n|---|---|\n| 1 | 2 |",
		"```odin\nx := 1\n```",
		"x\n\n    code",
		"**bold** and `code` [link](u)",
		"x\n\n\t\t\n  ",
		"",
	}
	keys := [?]string{"a", " ", "-", "#", "*", "`", ">", "⏎", "⌫", "⇥", "⇤"}
	for doc in docs {
		for at := 0; at <= len(doc); at += 1 {
			for key in keys {
				e := make_md_editor(doc)
				defer destroy_md_editor(e)
				set_single_selection(e, {at, at, -1})
				// Only where a click or the arrow keys can put the caret.
				if !caret_shown(e, at) do break
				play(t, e, key, fmt.tprintf("%q at %d: ", doc, at))
			}
		}
	}
}
