package mdview

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "../buffer"
import "../markdown"
import sdl "../../vendor/sdl3"
import "../textedit"

// Tests for editing in the rendered view: keys replayed through textedit.key
// and the view's kind, in scripted sequences and at every caret position of
// sample documents. Without a text engine, every character is half the font
// size wide (see text_width in gfx)


// Held by tests that set the pointer (test_input); tests run on several threads
@(private = "file")
mouse_lock: sync.Mutex

// Held by tests that load images or resolve wikilinks, whose caches are global;
// they free them with images_destroy
@(private = "file")
media_lock: sync.Mutex


// Typed text, as the app passes it to the view
@(private = "file")
type_text :: proc(e: ^View, text: string) {
	textedit.show_caret(e, true)
	e.kind.text_input(e, text)
}


@(test)
test_md_wrapped_rows :: proc(t: ^testing.T) {
	// 8 px per character in a 400 px column: 50 characters per row
	para := strings.repeat("word ", 24, context.temp_allocator)
	e := make_view(strings.concatenate({para, "\nnext"}, context.temp_allocator))
	defer destroy_view(e)

	L := line_layout(e, 0)
	testing.expect_value(t, len(L.rows), 3)
	testing.expect_value(t, L.rows[1].lo, 50)

	// Down keeps the x through the rows, then reaches the next line
	textedit.set_single_selection(e, {7, 7, -1})
	textedit.move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 57)
	textedit.move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 107)
	textedit.move(e, .Down, false)
	testing.expect_value(t, e.sels[0].head, 121 + 4) // "next" is shorter
	textedit.move(e, .Up, false)
	testing.expect_value(t, e.sels[0].head, 107)

	// Home and End work on the visual row
	textedit.set_single_selection(e, {57, 57, -1})
	textedit.move(e, .Home, false)
	testing.expect_value(t, e.sels[0].head, 50)
	textedit.move(e, .End, false)
	testing.expect_value(t, e.sels[0].head, 99) // before the space it wrapped at
	textedit.move(e, .Home, false)
	textedit.move(e, .Home, false)
	testing.expect_value(t, e.sels[0].head, 50)

	// Points and offsets agree
	text, _ := line_text(e, 0)
	for k in 0 ..= len(text) {
		row, x := caret_row_x(L, text, k)
		r := L.rows[row]
		got := index_at(L, text, x, r.y + r.h / 2)
		ok := got == k || (k == int(r.lo) && row > 0 && got == k - 1)
		testing.expectf(t, ok, "offset %d: point %v gives %d", k, x, got)
	}

	// A selection across the wraps covers each row to its end
	for r, ri in L.rows {
		x1, x2, ok := selection_span(L, text, ri, 0, len(text))
		end := L.runs[r.runs[1] - 1]
		testing.expectf(t, ok && x1 == 0 && x2 == end.x + end.w, "row %d: %v..%v", ri, x1, x2)
	}
	x1, x2, _ := selection_span(L, text, 0, 3, int(L.rows[1].lo))
	testing.expectf(t, x1 > 0 && x2 > x1, "to the wrap: %v..%v", x1, x2)
}


@(test)
test_md_carets_never_in_hidden_text :: proc(t: ^testing.T) {
	sync.guard(&media_lock)
	defer images_destroy()

	texts := [?]string {
		"# Head\n\nSome **bold** `code` [link](http://x) &amp; ~~s~~\n- [ ] task\n> quote\n\n" +
		"```odin\nx := 1\n```\n---\nend\n\n> > a\n> b",
		"---\ntitle: x\n---\n# h\n\n$$\nx^2\n$$\n\n<div>\nhtml\n</div>\n\n" +
		"![[pic.png]] [[Note]] ![[Note#Part]]",
		"| [r] | **b** |\n|---|---|\n| [r] | `2` |\n\n[r]: /u\n\n" +
		"Text[^1] mail a@b.co\n\n[^1]: note\n- [-] task",
		"# Head\r\n- a\r\n  - b\r\n> q\r\n> b\r\n\r\n```\r\nx\r\n```\r\n",
	}
	for text in texts {
		e := make_view(text)
		defer destroy_view(e)

		for k in 0 ..= len(text) {
			if k > 0 && text[k - 1] == '\r' {
				continue
			}

			// Placing it may move it out of syntax that stays hidden (a table's)
			textedit.set_single_selection(e, {k, k, -1})
			head := e.sels[0].head
			testing.expectf(
				t,
				caret_shown(e, head),
				"%q: caret at %d (put at %d) is in hidden text",
				text,
				head,
				k,
			)
		}
	}
}


@(test)
test_md_toggle_keeps_top_line :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		strings.write_string(&sb, i % 10 == 0 ? "# Heading\n" : "Some text on a line.\n")
	}
	e := make_view(strings.to_string(sb))
	defer destroy_view(e)

	set_mode(e, .Text)
	textedit.scroll_to(e, f64(60 * env.config().text_line_height))
	set_mode(e, .Rendered)
	line, _ := hm_find(&e.mdv.heights, e.scroll_y)
	testing.expect_value(t, line, 60)
	set_mode(e, .Text)
	testing.expect_value(t, int(e.scroll_y) / env.config().text_line_height, 60)

	// Page Down moves the caret about a screen
	set_mode(e, .Rendered)
	textedit.set_single_selection(e, {0, 0, -1})
	textedit.scroll_to(e, 0)
	textedit.move(e, .Page_Down, false)
	moved := hm_y(&e.mdv.heights, buffer.offset_to_line(&e.buf, e.sels[0].head))
	testing.expect(t, moved > page_height(e) - 60 && moved < page_height(e) + 60)
}


// While the mouse button is down, what is revealed stays as it was
@(test)
test_md_hold_reveal :: proc(t: ^testing.T) {
	e := make_view("# Title\n\nSome **bold** text.")
	defer destroy_view(e)

	hold_reveal(e)
	at := buffer.line_start(&e.buf, 2) + 7
	textedit.set_single_selection(e, {at, buffer.line_end(&e.buf, 2), -1})
	testing.expect_value(t, shown(e, 0), "# Title")
	testing.expect_value(t, shown(e, 2), "Some bold text.")

	e.mdv.holding = false
	testing.expect_value(t, shown(e, 0), "Title")
	testing.expect_value(t, shown(e, 2), "Some **bold** text.")
}


@(test)
test_md_checkbox_and_links :: proc(t: ^testing.T) {
	e := make_view(
		"x\n- [ ] task\n\nSee [docs][ref] and [site](https://example.com).\n\n[ref]: notes/doc.md",
	)
	defer destroy_view(e)
	e.view = {0, 0, e.view.w, 600}

	// Clicking a task box toggles it as one undoable edit, leaving the caret
	L := line_layout(e, 1)
	box: Run
	for run in L.runs {
		if run.kind == .Checkbox do box = run
	}
	testing.expect_value(t, box.kind, Run_Kind.Checkbox)
	y := f32(hm_y(&e.mdv.heights, 1)) + L.rows[0].y + L.rows[0].h / 2
	lo, hi, ok := checkbox_at(e, e.mdv.col_x + box.x + box.w / 2, y)
	testing.expect(t, ok)
	textedit.replace_in_place(e, lo, hi, "[x]")
	testing.expect_value(t, string(buffer.read_alloc(&e.buf, lo, hi)), "[x]")
	testing.expect_value(t, e.sels[0].head, 0)
	textedit.undo(e)
	testing.expect_value(t, string(buffer.read_alloc(&e.buf, lo, hi)), "[ ]")

	// Links resolve under their text, references through the definition
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	L = line_layout(e, 3)
	text, _ := line_text(e, 3)
	targets := make([dynamic]string, context.temp_allocator)
	for run in L.runs {
		if .Underline not_in run.style do continue

		ly := f32(hm_y(&e.mdv.heights, 3)) + L.rows[run.row].y + 2
		target, wiki, found := link_at(e, e.mdv.col_x + run.x + 1, ly)
		testing.expectf(t, found && !wiki, "no link at %q", text[run.lo:run.hi])
		append(&targets, target)
	}
	testing.expect_value(t, len(targets), 2)
	if len(targets) == 2 {
		testing.expect_value(t, targets[0], "notes/doc.md")
		testing.expect_value(t, targets[1], "https://example.com")
	}
}


// --- Tables ------------------------------------------------------------------------

// A view of `text` with "‸" removed and the caret where it was
@(private = "file")
caret_view :: proc(text: string) -> ^View {
	k := strings.index(text, "‸")
	e := make_view(strings.concatenate({text[:k], text[k + len("‸"):]}, context.temp_allocator))
	textedit.set_single_selection(e, {k, k, -1})
	return e
}


// Plays `keys`, then checks the text ("‸" at the caret) and that the first
// line is still a rendered table row
@(private = "file")
expect_cell_keys :: proc(t: ^testing.T, e: ^View, keys, want: string, loc := #caller_location) {
	play(t, e, keys, loc = loc)

	got := md_text(e)
	h := e.sels[0].head
	with_caret := strings.concatenate({got[:h], "‸", got[h:]}, context.temp_allocator)
	testing.expect_value(t, with_caret, want, loc = loc)
	testing.expect_value(t, line_layout(e, 0).kind, Line_Kind.Table, loc = loc)
}


// A table is edited rendered. Tab and Shift+Tab move between cells and Enter
// down a row, adding a row after the last; arrows cross cells and skip the
// delimiter row; Backspace stops at a cell's start; a typed "|" is escaped
// ("‸" marks the caret)
@(test)
test_md_table_editing :: proc(t: ^testing.T) {
	e := caret_view("| a‸ | b |\n|---|---|\n| 1 | 2 |")
	defer destroy_view(e)
	expect_cell_keys(t, e, "x", "| ax‸ | b |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "⇥", "| ax | b‸ |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "⇥", "| ax | b |\n|---|---|\n| 1‸ | 2 |")
	expect_cell_keys(t, e, "⇤", "| ax | b‸ |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "⏎", "| ax | b |\n|---|---|\n| 1 | 2‸ |")
	expect_cell_keys(t, e, "⏎", "| ax | b |\n|---|---|\n| 1 | 2 |\n|  |  ‸|")
	expect_cell_keys(t, e, "y", "| ax | b |\n|---|---|\n| 1 | 2 |\n|  |  y‸|")
	expect_cell_keys(t, e, "←", "| ax | b |\n|---|---|\n| 1 | 2 |\n|  |  ‸y|")
	expect_cell_keys(t, e, "←", "| ax | b |\n|---|---|\n| 1 | 2 |\n|  ‸|  y|")
	expect_cell_keys(t, e, "⌫", "| ax | b |\n|---|---|\n| 1 | 2 |\n| ‸|  y|")
	expect_cell_keys(t, e, "⌫", "| ax | b |\n|---|---|\n| 1 | 2 |\n| ‸|  y|")
	expect_cell_keys(t, e, "|", "| ax | b |\n|---|---|\n| 1 | 2 |\n| \\|‸|  y|")

	// Enter on an empty last row leaves the table, the row becoming an empty line
	x := caret_view("| a | b |\n|---|---|\n| 1 | 2‸ |\n\nafter")
	defer destroy_view(x)
	expect_cell_keys(t, x, "⏎", "| a | b |\n|---|---|\n| 1 | 2 |\n|  |  ‸|\n\nafter")
	expect_cell_keys(t, x, "⏎", "| a | b |\n|---|---|\n| 1 | 2 |\n‸\n\nafter")
	testing.expect_value(t, x.md.lines[3].kind, markdown.Line_Kind.Blank)
	expect_cell_keys(t, x, "↶", "| a | b |\n|---|---|\n| 1 | 2 |\n|  |  ‸|\n\nafter")

	// Not from a last row with text
	expect_cell_keys(t, x, "z⏎", "| a | b |\n|---|---|\n| 1 | 2 |\n|  |  z|\n|  |  ‸|\n\nafter")
	q := caret_view("> | a |\n> |---|\n> | ‸ |")
	defer destroy_view(q)
	expect_cell_keys(t, q, "⏎", "> | a |\n> |---|\n> ‸")

	v := caret_view("| a | b‸ |\n|---|---|\n| 1 | 2 |")
	defer destroy_view(v)
	expect_cell_keys(t, v, "↓", "| a | b |\n|---|---|\n| 1 | 2‸ |")
	expect_cell_keys(t, v, "↑", "| a | b‸ |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, v, "→", "| a | b |\n|---|---|\n| ‸1 | 2 |")
	expect_cell_keys(t, v, "←", "| a | b‸ |\n|---|---|\n| 1 | 2 |")

	// Shift+Tab stops at the first cell; a short row gets the cell Tab goes to
	s := caret_view("| a | b |\n|---|---|\n| ‸1 |")
	defer destroy_view(s)
	expect_cell_keys(t, s, "⇥", "| a | b |\n|---|---|\n| 1 |  ‸|")
	expect_cell_keys(t, s, "⇤⇤⇤", "| a‸ | b |\n|---|---|\n| 1 |  |")
	expect_cell_keys(t, s, "⇤", "| a‸ | b |\n|---|---|\n| 1 |  |")

	// A caret put on the delimiter row or a pipe moves into a cell
	on_delim := buffer.line_start(&v.buf, 1) + 2
	textedit.set_single_selection(v, {on_delim, on_delim, -1})
	testing.expect_value(t, v.sels[0].head, 7)
	textedit.set_single_selection(v, {0, 0, -1})
	testing.expect_value(t, v.sels[0].head, 2)
}


// Shift+Enter in a cell adds a line break (<br>), which the cell draws as a
// new line and Backspace or Delete remove whole; Up and Down move between the
// cell's lines
@(test)
test_md_table_line_breaks :: proc(t: ^testing.T) {
	e := caret_view("| a | b‸ |\n|---|---|\n| 1 | 2 |")
	defer destroy_view(e)
	one_line := line_layout(e, 0).height
	expect_cell_keys(t, e, "↵", "| a | b<br>‸ |\n|---|---|\n| 1 | 2 |")
	testing.expect_value(t, caret_cell_line(e), 1)
	testing.expect(t, line_layout(e, 0).height > one_line)
	expect_cell_keys(t, e, "c", "| a | b<br>c‸ |\n|---|---|\n| 1 | 2 |")
	testing.expect_value(t, caret_cell_line(e), 1)

	// Away from the break, the tag is hidden and the cell has two lines
	textedit.set_single_selection(e, {2, 2, -1})
	L := line_layout(e, 0)
	text, _ := line_text(e, 0)
	for run in L.runs do testing.expect(t, !strings.contains(text[run.lo:run.hi], "<"))
	testing.expect_value(t, table_cell_lines(L, L.edges[1] + 1), 2)

	// Up and Down stay in the cell while it has lines; then other rows
	textedit.set_single_selection(e, {6, 6, -1})
	expect_cell_keys(t, e, "↓", "| a | b<br>‸c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "↓", "| a | b<br>c |\n|---|---|\n| 1 | ‸2 |")
	expect_cell_keys(t, e, "↑", "| a | b<br>‸c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "↑", "| a | ‸b<br>c |\n|---|---|\n| 1 | 2 |")

	// Left and Right step over a break whole
	expect_cell_keys(t, e, "→", "| a | b‸<br>c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "→", "| a | b<br>‸c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "←", "| a | b‸<br>c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "⌦", "| a | b‸c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "↵⌫", "| a | b‸c |\n|---|---|\n| 1 | 2 |")
	expect_cell_keys(t, e, "↵↵", "| a | b<br><br>‸c |\n|---|---|\n| 1 | 2 |")
	testing.expect_value(t, caret_cell_line(e), 2)

	// Over a selection; over cells, which it empties like typing
	s := caret_view("| ab‸ | cd |\n|---|---|")
	defer destroy_view(s)
	textedit.set_single_selection(s, {2, 4, -1})
	expect_cell_keys(t, s, "↵", "| <br>‸ | cd |\n|---|---|")
	cell_drag(s, {2, 2, -1}, strings.index(md_text(s), "cd") + 1)
	expect_cell_keys(t, s, "↵", "| <br>‸ | |\n|---|---|")
}


// The line of its cell the caret is on, in the first line's table row
@(private = "file")
caret_cell_line :: proc(e: ^View) -> int {
	L := line_layout(e, 0)
	text, _ := line_text(e, 0)
	_, _, top, _ := caret_box(L, text, e.sels[0].head)
	return int(math.round((top - L.rows[0].y - CELL_VPAD) / L.cell_h))
}


// Dragging from a cell into others selects the rectangle of cells, a selection
// per row, drawn as whole cells; within a cell, the text. Typing or deleting
// over cells empties them and keeps the pipes
@(test)
test_md_table_cell_selection :: proc(t: ^testing.T) {
	e := make_view("| a | bb |\n|---|---|\n| 1 | 22 |\n| 3 | 44 |")
	defer destroy_view(e)

	// A triple click selects the text of its cell
	at := strings.index(md_text(e), "22")
	lo, hi, ok := cell_text_at(e, at + 1)
	testing.expect(t, ok)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{at, at + 2})
	_, _, ok = cell_text_at(e, strings.index(md_text(e), "---"))
	testing.expect(t, !ok)

	// Into another cell: a selection per row
	origin := Selection{2, 2, -1}
	textedit.set_single_selection(e, origin)
	testing.expect(t, cell_drag(e, origin, strings.index(md_text(e), "44") + 1))
	testing.expect_value(t, len(e.sels), 3)
	testing.expect_value(t, selected_text(e, e.sels[0]), "a | bb ")
	testing.expect_value(t, selected_text(e, e.sels[2]), "3 | 44 ")
	testing.expect_value(t, e.primary, 2)
	snap_selection(e)
	testing.expect_value(t, len(e.sels), 3)

	// Whole cells, each inside its borders; part of a cell, its text
	L := line_layout(e, 0)
	text, _ := line_text(e, 0)
	boxes := table_selection(L, text, 2, 9)
	testing.expect_value(t, len(boxes), 2)
	if len(boxes) == 2 {
		testing.expect_value(t, boxes[0].x, L.edges[0] + 1)
		testing.expect_value(t, boxes[1].x + boxes[1].w, L.edges[2])
		testing.expect_value(t, boxes[0].h, L.rows[0].h - 1)
	}
	part := table_selection(L, text, 2, 3)
	testing.expect_value(t, len(part), 1)
	if len(part) == 1 {
		testing.expect(t, part[0].x > L.edges[0] && part[0].x + part[0].w < L.edges[1])
		testing.expect_value(t, part[0].h, L.cell_h)
	}

	// Back in the first cell, one selection again
	testing.expect(t, cell_drag(e, origin, 3))
	testing.expect_value(t, len(e.sels), 1)
	testing.expect_value(t, e.sels[0], Selection{2, 3, -1})
	testing.expect(t, !cell_drag(e, origin, 3))

	// Typing over them is one undo step, the first character (which empties
	// the cells) and the rest
	cell_drag(e, origin, strings.index(md_text(e), "44") + 1)
	play(t, e, "xy")
	testing.expect_value(t, md_text(e), "| xy | |\n|---|---|\n| xy | |\n| xy | |")
	textedit.undo(e)
	testing.expect_value(t, md_text(e), "| a | bb |\n|---|---|\n| 1 | 22 |\n| 3 | 44 |")

	// Deleting over them
	e.mdv.cell_drag = false
	textedit.set_single_selection(e, {2, 2, -1})
	cell_drag(e, {2, 2, -1}, strings.index(md_text(e), "22") + 1)
	play(t, e, "⌫")
	testing.expect_value(t, md_text(e), "|  | |\n|---|---|\n|  | |\n| 3 | 44 |")
	testing.expect_value(t, line_layout(e, 0).kind, Line_Kind.Table)
}


@(private = "file")
selected_text :: proc(e: ^View, s: Selection) -> string {
	return string(buffer.read_alloc(&e.buf, textedit.sel_lo(s), textedit.sel_hi(s)))
}


@(private = "file")
md_text :: proc(e: ^View) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
}


@(private = "file")
expect_after :: proc(t: ^testing.T, e: ^View, want: string, loc := #caller_location) {
	got := md_text(e)
	at := e.sels[0].head
	got = strings.concatenate({got[:at], "|", got[at:]}, context.temp_allocator)
	testing.expect_value(t, got, want, loc = loc)
}


// --- Lists, fences, links, copying -------------------------------------------------

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
		// An empty item leaves the list, or moves out a level when nested
		{"- a\n- |", "- a\n|"},
		{"- a\n- [ ] |", "- a\n|"},
		{"- a\n  - |", "- a\n- |"},
		{"> a\n> |", "> a\n|"},
		// Before an item's text, Enter is a plain newline
		{"|- one", "\n|- one"},
		{"plain|", "plain\n|"},
	}
	for c in cases do expect_typing(t, c[0], {{"⏎", c[1], ""}})
}


// A typed opening fence gets its closing fence when its block would otherwise
// take in the text after it, but not when it pairs with an unmatched fence
@(test)
test_md_typed_fence_closes :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"|", "```|\n```"},
		{"text\n|", "text\n```|\n```"},
		{"|\n\n```\ncode\n```", "```|\n```\n\n```\ncode\n```"},
		{"|\ncode\n```", "```|\ncode\n```"},
		{"- |", "- ```|\n  ```"},
		{"> |", "> ```|\n> ```"},
		{"```\n|\n```", "```\n```|\n```"},
	}
	for c in cases do expect_typing(t, c[0], {{"```", c[1], ""}})
	expect_typing(t, "|", {{"~~~", "~~~|\n~~~", ""}, {"go⏎x", "~~~go\nx|\n~~~", ""}})
}


// Wikilinks name notes (without ".md", even with a dot in the name) and files,
// next to the document or anywhere in the workspace; "#..." names a heading
@(test)
test_md_wiki_links :: proc(t: ^testing.T) {
	sync.guard(&media_lock)
	dir, err := os.make_directory_temp("", "typo-wiki-*", context.allocator)
	testing.expect(t, err == nil)
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	_ = os.make_directory(path_in(dir, "sub"))
	for name in ([]string{"Note.v2.md", "pic.png", "sub/Deep.md"}) {
		_ = os.write_entire_file(path_in(dir, name), "x")
	}

	e := make_view("# Intro\ntext\n## My *Heading*\nx\nSetext Title\n---\nend")
	defer destroy_view(e)
	defer images_destroy()
	e.path = strings.clone(path_in(dir, "index.md"))

	path, ok := wiki_path(e, "Note.v2")
	testing.expect(t, ok && same_path(path, path_in(dir, "Note.v2.md")), path)
	path, ok = wiki_path(e, "pic.png")
	testing.expect(t, ok && same_path(path, path_in(dir, "pic.png")), path)
	_, ok = wiki_path(e, "Deep")
	testing.expect(t, !ok)

	// Found once the workspace index has it
	deep := path_in(dir, "sub/Deep.md")
	append(&test_files, deep)
	defer clear(&test_files)
	defer delete(test_files)
	path, ok = wiki_path(e, "Deep")
	testing.expect(t, ok && same_path(path, deep), path)
	path, ok = wiki_path(e, "sub/deep")
	testing.expect(t, ok && same_path(path, deep), path)

	// Headings in the same document, by text or slug
	headings := [][2]string {
		{"#my-heading", "## My *Heading*"},
		{"#Setext Title", "Setext Title"},
		{"#intro", "# Intro"},
	}
	for c in headings {
		textedit.set_single_selection(e, {buffer.length(&e.buf), buffer.length(&e.buf), -1})
		open_link(e, c[0], true)
		line := buffer.offset_to_line(&e.buf, e.sels[0].head)
		text, _ := line_text(e, line)
		testing.expectf(t, text == c[1], "%q goes to %q", c[0], text)
	}
	testing.expect(t, test_opened == "")

	// An image embed shows the image in place of its syntax; a note embed
	// shows as a link
	em := make_view("x\n![[pic.png]] and ![[Note.v2|v2]]")
	defer destroy_view(em)
	em.path = strings.clone(path_in(dir, "index.md"))
	testing.expect_value(t, shown(em, 1), " and v2")
	testing.expect_value(t, len(line_layout(em, 1).images), 1)

	// A link to a missing note is dimmed; a heading in a link shows after ">"
	wl := make_view("x\n[[Note.v2#Part]] [[Missing]]")
	defer destroy_view(wl)
	wl.path = strings.clone(path_in(dir, "index.md"))
	testing.expect_value(t, shown(wl, 1), "Note.v2 > Part Missing")
	testing.expect_value(t, run_color_at(line_layout(wl, 1), 2), Color.Link)
	testing.expect_value(t, run_color_at(line_layout(wl, 1), 19), Color.Dim)
}


@(private = "file")
path_in :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}


@(private = "file")
same_path :: proc(a, b: string) -> bool {
	return strings.equal_fold(a, b)
}


// The color of the text run at byte `at` of a line
@(private = "file")
run_color_at :: proc(L: ^Line_Layout, at: int) -> Color {
	for run in L.runs {
		if run.kind == .Text && int(run.lo) <= at && at < int(run.hi) {
			return run.color
		}
	}
	return .Text
}


// An editor for `text` with "«" and "»" removed, selecting what they enclose
@(private = "file")
md_editor_selecting :: proc(text: string) -> ^View {
	lo := strings.index(text, "«")
	hi := strings.index(text, "»") - len("«")
	text, _ := strings.remove_all(text, "«", context.temp_allocator)
	text, _ = strings.remove_all(text, "»", context.temp_allocator)

	e := make_view(text)
	textedit.set_single_selection(e, {lo, hi, -1})
	return e
}


// Copying in the rendered view keeps the Markdown of what is selected:
// formatting markers (added when only part of formatted text is selected), and
// list, quote and heading markers of lines selected from their text
@(test)
test_md_copy_takes_markers :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"- «a\n- b»", "- a\n- b"},
		{"- a«\n- b»", "\n- b"},
		{"- «a»\n- b", "a"},
		{"- [ ] «t\nx»", "- [ ] t\nx"},
		{"1. «a\n2. b»", "1. a\n2. b"},
		{"> «q\nx»", "> q\nx"},
		{"## «H\nx»", "## H\nx"},
		{"> - «a\n> - b»", "> - a\n> - b"},
		{"x\n  - «a\nb»", "  - a\nb"},
		{"p«ara\nx»", "ara\nx"},
		{"Some **«bold»** text", "**bold**"},
		{"So«me **bo»ld** text", "me **bo**"},
		{"Some **b«ol»d** text", "**ol**"},
		{"Some **«bold** te»xt", "**bold** te"},
		{"«Some **»bold** text", "Some "},
		{"Some **bold«** text»", " text"},
		{"***«x»***", "***x***"},
		{"***x«y»z***", "***y***"},
		{"a **b«\nc» d** e", "**\nc**"},
		{"[l«ink»](http://a) after", "[ink](http://a)"},
		{"`«code»`", "`code`"},
		{"~~«gone»~~", "~~gone~~"},
		{"a \\«*» b", "\\*"},
		{"- **«a**\n- b»", "- **a**\n- b"},
		// Table cells are parsed one by one: no emphasis across a pipe
		{"| *«a» | b* |\n|---|---|", "a"},
	}
	for c in cases {
		e := md_editor_selecting(c[0])
		s := e.sels[0]
		lo, hi, before, after := copy_range(e, textedit.sel_lo(s), textedit.sel_hi(s))
		copied := string(buffer.read_alloc(&e.buf, lo, hi))
		got := strings.concatenate({before, copied, after}, context.temp_allocator)
		testing.expectf(t, got == c[1], "%q copies %q, want %q", c[0], got, c[1])
		destroy_view(e)
	}

	// Cut takes the same range: no empty item or markers left behind
	cuts := [?][2]string {
		{"- «a\n- b»\n- c", "\n- c"},
		{"Some **«bold»** text", "Some  text"},
		{"Some **b«ol»d** text", "Some **bd** text"},
	}
	for c in cuts {
		e := md_editor_selecting(c[0])
		_ = textedit.copy_text(e, true)
		testing.expect_value(t, md_text(e), c[1])
		destroy_view(e)
	}

	// A mouse selection snaps to the same range when released, either way round
	e := md_editor_selecting("- **«a**\n- b» c")
	defer destroy_view(e)
	snap_selection(e)
	testing.expect_value(t, e.sels[0], Selection{0, 11, -1})
	textedit.set_single_selection(e, {11, 4, -1})
	snap_selection(e)
	testing.expect_value(t, e.sels[0], Selection{11, 0, -1})
	textedit.set_single_selection(e, {6, 6, -1})
	snap_selection(e)
	testing.expect_value(t, e.sels[0], Selection{6, 6, -1})
}


@(test)
test_md_list_indent :: proc(t: ^testing.T) {
	e := view_at("- a\n- b|")
	defer destroy_view(e)
	testing.expect(t, md_indent(e, 1))
	expect_after(t, e, "- a\n  - b|")
	testing.expect(t, md_indent(e, -1))
	expect_after(t, e, "- a\n- b|")

	// Shift+Tab at the top level leaves the item as it is
	testing.expect(t, md_indent(e, -1))
	expect_after(t, e, "- a\n- b|")
	textedit.undo(e)
	expect_after(t, e, "- a\n  - b|")

	o := view_at("1. a\n2. b|")
	defer destroy_view(o)
	md_indent(o, 1)
	expect_after(t, o, "1. a\n   1. b|")

	// Backspace at the start of an item's text removes its marker; a nested
	// item's text goes on in the item it was in
	b := view_at("- a\n- |b")
	defer destroy_view(b)
	testing.expect(t, backspace(b))
	expect_after(t, b, "- a\n|b")
	n := view_at("- a\n  - |b")
	defer destroy_view(n)
	testing.expect(t, backspace(n))
	expect_after(t, n, "- a\n  |b")
	b2 := view_at("- a\n- b|")
	defer destroy_view(b2)
	testing.expect(t, !backspace(b2))
}


@(test)
test_md_caretless :: proc(t: ^testing.T) {
	e := make_view("# Title\n\nSome **bold** text.")
	defer destroy_view(e)
	e.mdv.caretless = true

	// With no caret, nothing is revealed
	testing.expect_value(t, shown(e, 0), "Title")

	// Beside the text column is outside it; the column is inside
	testing.expect(t, !column_hit(e, e.view.x + 2, 10))
	testing.expect(t, column_hit(e, e.view.x + e.mdv.col_x + 10, 10))

	// An arrow key shows the caret, here where it was (on screen)
	key: sdl.KeyboardEvent
	key.key = sdl.K_DOWN
	testing.expect(t, textedit.key(e, key))
	testing.expect(t, !e.mdv.caretless)
	testing.expect_value(t, shown(e, 0), "# Title")

	// Typing shows the caret and types there, and so does an editing key
	e.mdv.caretless = true
	type_text(e, "x")
	testing.expect(t, !e.mdv.caretless)
	testing.expect_value(t, md_text(e), "x# Title\n\nSome **bold** text.")
	e.mdv.caretless = true
	key.key = sdl.K_BACKSPACE
	testing.expect(t, textedit.key(e, key))
	testing.expect(t, !e.mdv.caretless)
	testing.expect_value(t, md_text(e), "# Title\n\nSome **bold** text.")
}


@(test)
test_md_code_scroll_bar :: proc(t: ^testing.T) {
	long := strings.repeat("abcdefghij", 12, context.temp_allocator)
	doc := strings.concatenate({"x\n\n```\n", long, "\n```\n\nafter"}, context.temp_allocator)
	e := make_view(doc)
	defer destroy_view(e)
	e.view.h = 600

	track, thumb, first, ok := code_bar(e, 4)
	testing.expect(t, ok && first == 2)
	_, _, _, ok = code_bar(e, 3) // only under the block's last line
	testing.expect(t, !ok)
	width, box := code_widths(e, code_block_at(e, 2) or_else nil)

	// Dragging the thumb to the end of its track scrolls to the end
	sync.guard(&mouse_lock)
	defer {
		test_input.mouse_pos = {}
		test_input.mouse_pressed = false
		test_input.mouse_down = false
	}
	test_input.mouse_pos = {thumb.x + 2, thumb.y + 1}
	test_input.mouse_pressed, test_input.mouse_down = true, true
	testing.expect(t, code_bar_mouse(e))
	test_input.mouse_pressed = false
	test_input.mouse_pos.x = track.x + track.w + 50
	code_bar_mouse(e)
	testing.expect_value(t, e.mdv.code_scroll[2], width - box)
	test_input.mouse_down = false
	code_bar_mouse(e)
	testing.expect(t, !e.mdv.code_drag.active)

	// Clicking the track's left end jumps back
	test_input.mouse_pos = {track.x + 1, track.y + 1}
	test_input.mouse_pressed, test_input.mouse_down = true, true
	code_bar_mouse(e)
	testing.expect_value(t, e.mdv.code_scroll[2], 0)
	test_input.mouse_pressed, test_input.mouse_down = false, false
	code_bar_mouse(e)

	// Drag-selecting past the block's right side scrolls it
	test_input.mouse_pos = {e.view.x + e.view.w + 20, e.view.y + f32(hm_y(&e.mdv.heights, 3)) + 4}
	drag_scroll_code(e)
	testing.expect(t, e.mdv.code_scroll[2] > 0)
}


// --- Replaying keys ----------------------------------------------------------------

@(private = "file")
Typing_Step :: struct {
	keys:     string,
	text:     string, // after the keys, "|" at the caret
	rendered: string, // see `rendered`; "" skips the check
}


// The lines as drawn: two spaces per indentation level, "H " on a heading,
// then the shown text
@(private = "file")
rendered :: proc(e: ^View) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in 0 ..< len(e.md.lines) {
		L := line_layout(e, line)
		heading := false
		for run in L.runs {
			if run.kind == .Text && run.size > font_size() {
				heading = true
			}
		}

		level := int(L.indent / LIST_INDENT + 0.5)
		indent := strings.repeat("  ", level, context.temp_allocator)
		mark := heading ? "H " : ""
		append(&lines, strings.concatenate({indent, mark, shown(e, line)}, context.temp_allocator))
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}


// Whether bytes [k, k + n) are drawn as text (n = 0: a caret at k is in or
// at the edge of drawn text). A run drawn in place of its bytes (a tab, an
// entity) has no inner positions
@(private = "file")
shown_at :: proc(e: ^View, k: int, n := 0) -> bool {
	line := buffer.offset_to_line(&e.buf, k)
	at := k - buffer.line_start(&e.buf, line)
	for run in line_layout(e, line).runs {
		if run.kind != .Text && run.kind != .Mono {
			continue
		}

		drawn: bool
		if run.subst == {} {
			drawn = int(run.lo) <= at && at + n <= int(run.hi)
		} else {
			// All of it, or a caret at either edge
			from_start := at == int(run.lo) && (n == 0 || at + n == int(run.hi))
			drawn = from_start || (n == 0 && at == int(run.hi))
		}
		if drawn do return true
	}
	return false
}


// Whether only hidden spaces separate byte k from what is drawn after it (text,
// a bullet or a task box) on its line, or from where the line's text starts
// after its list and quote markers: indentation, which is syntax (after a list
// marker, only its first space)
@(private = "file")
before_shown :: proc(e: ^View, k: int) -> bool {
	line := buffer.offset_to_line(&e.buf, k)
	text, start := line_text(e, line)
	at := k - start

	// Where the line's text starts
	d := markdown.line_detail(e.md, line, text)
	content := int(d.content[0])
	if d.n_marks > 0 && d.marks[d.n_marks - 1].kind != .Quote {
		content = min(content, int(d.marks[d.n_marks - 1].hi) + 1)
	}
	if d.task != {} do content = min(int(d.task[1]) + 1, len(text))
	if at <= content && strings.trim_space(text[at:content]) == "" {
		return true
	}

	// What is drawn next
	next := -1
	for run in line_layout(e, line).runs {
		if int(run.lo) >= at && run.hi > run.lo && (next < 0 || int(run.lo) < next) {
			next = int(run.lo)
		}
	}
	return next >= 0 && strings.trim_space(text[at:next]) == ""
}


// Whether a space or tab typed at byte k is drawn: it or another in the same
// run of whitespace, unless it is syntax: indentation that containers or an
// indented code block consume, before the line's markers, or the one space
// after a list marker or a task box
@(private = "file")
space_shown :: proc(e: ^View, k: int) -> bool {
	line := buffer.offset_to_line(&e.buf, k)
	text, start := line_text(e, line)
	at := k - start

	// The run of whitespace it is in
	lo, hi := at, at + 1
	for lo > 0 && (text[lo - 1] == ' ' || text[lo - 1] == '\t') {
		lo -= 1
	}
	for hi < len(text) && (text[hi] == ' ' || text[hi] == '\t') {
		hi += 1
	}
	for b in lo ..< hi {
		if shown_at(e, start + b, 1) do return true
	}

	d := markdown.line_detail(e.md, line, text)
	if d.task != {} && at == int(d.task[1]) {
		return true
	}
	if at >= int(d.content[0]) do return false
	if d.n_marks == 0 do return true

	last := d.marks[d.n_marks - 1]
	if e.md.lines[line].kind == .Indented_Code && at >= int(last.hi) {
		return true
	}
	return at < int(last.lo) || at == int(last.hi)
}


// Whether a caret at byte k is drawn where it is in the text
@(private = "file")
caret_shown :: proc(e: ^View, k: int) -> bool {
	return shown_at(e, k) || before_shown(e, k)
}


// Whether the primary caret is drawn in the text column, or on a marker
// hanging left of it that it is in
@(private = "file")
caret_in_column :: proc(e: ^View) -> bool {
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	text, start := line_text(e, line)
	L := line_layout(e, line)
	at := head - start
	_, x := caret_row_x(L, text, at)

	// A code block's text is clipped to inside its padding (and scrolls)
	left := L.indent - 0.5
	if L.kind == .Code {
		if L.code_bg != {} {
			left = L.code_bg[0] + CODE_PAD - 2 - L.scroll
		} else {
			left = min(left, -L.scroll)
		}
	}
	if x >= left do return true

	for run in L.runs {
		if hanging(L, run) && int(run.lo) <= at && at <= int(run.hi) {
			return true
		}
	}
	return false
}


// Where the primary caret is drawn: its line, row and x
@(private = "file")
caret_place :: proc(e: ^View) -> [3]f32 {
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	text, start := line_text(e, line)
	row, x := caret_row_x(line_layout(e, line), text, head - start)
	return {f32(line), f32(row), x}
}


@(private = "file")
press :: proc(e: ^View, key: sdl.Keycode, mod: sdl.Keymod = {}) {
	textedit.key(e, {key = key, mod = mod})
}


// Plays each key, checking after it that the incremental parse matches a full
// parse, the caret is drawn in the text, and what was typed is drawn
@(private = "file")
play :: proc(t: ^testing.T, e: ^View, keys: string, label := "", loc := #caller_location) {
	for r, i in keys {
		before := caret_place(e)
		version := e.buf.version

		// The key
		switch r {
		case '⏎': press(e, sdl.K_RETURN)
		case '↵': press(e, sdl.K_RETURN, sdl.KMOD_SHIFT)
		case '⌫': press(e, sdl.K_BACKSPACE)
		case '⇥': press(e, sdl.K_TAB)
		case '⇤': press(e, sdl.K_TAB, sdl.KMOD_SHIFT)
		case '⌦': press(e, sdl.K_DELETE)
		case '←': press(e, sdl.K_LEFT)
		case '→': press(e, sdl.K_RIGHT)
		case '↑': press(e, sdl.K_UP)
		case '↓': press(e, sdl.K_DOWN)
		case '↶': textedit.undo(e)
		case:
			buf, n := utf8.encode_rune(r)
			type_text(e, string(buf[:n]))
		}
		textedit.take_changes(e)
		markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
		check_heights(e)
		played := keys[:i + utf8.rune_size(r)]

		// The incremental parse matches a full parse
		full: markdown.Doc
		defer markdown.doc_destroy(&full)
		markdown.doc_open(&full, &e.buf)
		markdown.doc_update(&full, &e.buf, max(int), time.Hour)
		for l, k in full.lines {
			a := e.md.lines[k]
			same := a.kind == l.kind &&
			        a.aux == l.aux &&
			        a.flags == l.flags &&
			        markdown.line_state(e.md, k) == markdown.line_state(&full, k)
			testing.expectf(
				t,
				same,
				"%safter %q: line %d parsed as %v, a full parse gives %v",
				label,
				played,
				k,
				a.kind,
				l.kind,
				loc = loc,
			)
		}

		// The caret is drawn in the text
		testing.expectf(
			t,
			caret_shown(e, e.sels[0].head),
			"%safter %q: caret in hidden text",
			label,
			played,
			loc = loc,
		)
		testing.expectf(
			t,
			caret_in_column(e),
			"%safter %q: caret drawn left of the text",
			label,
			played,
			loc = loc,
		)

		// What is typed is drawn, unless it is indentation; Enter moves the caret
		head := e.sels[0].head
		typed := r == '⇥' ? '\t' : r
		n := utf8.rune_size(typed)
		switch {
		case e.buf.version == version, r == '⌫', r == '⌦', r == '⇤', r == '↶':
		case r == '⏎':
			testing.expectf(
				t,
				caret_place(e) != before,
				"%safter %q: the caret didn't move",
				label,
				played,
				loc = loc,
			)
		case typed_before(e, head, typed):
			is_space := typed == ' ' || typed == '\t'
			drawn := is_space ? space_shown(e, head - n) : shown_at(e, head - n, n)
			testing.expectf(t, drawn, "%safter %q: %q isn't shown", label, played, typed, loc = loc)
		}
	}
}


// Whether the character before byte `head` is `typed`
@(private = "file")
typed_before :: proc(e: ^View, head: int, typed: rune) -> bool {
	n := utf8.rune_size(typed)
	if head < n do return false

	text := string(buffer.read_alloc(&e.buf, head - n, head))
	return text == utf8.runes_to_string({typed}, context.temp_allocator)
}


// Replays steps from `start` ("|" at the caret), checking each one's result
@(private = "file")
expect_typing :: proc(
	t: ^testing.T,
	start: string,
	steps: []Typing_Step,
	loc := #caller_location,
) {
	e := view_at(start)
	defer destroy_view(e)

	for s in steps {
		play(t, e, s.keys, loc = loc)
		expect_after(t, e, s.text, loc)
		if s.rendered != "" {
			testing.expectf(
				t,
				rendered(e) == s.rendered,
				"after %q: rendered\n%s\nwant\n%s",
				s.keys,
				rendered(e),
				s.rendered,
				loc = loc,
			)
		}
	}
}


// --- Typing ------------------------------------------------------------------------

@(test)
test_md_typing_lists :: proc(t: ^testing.T) {
	// A list started under a paragraph doesn't make it a heading, and leaving
	// it goes back to the margin
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

	// Spaces typed after a marker show while the line is edited, and Backspace
	// deletes them before the marker; Enter keeps them
	expect_typing(t, "|", {
		{"Para⏎1. a⏎ ", "Para\n1. a\n2.  |", "Para\n  1.a\n  2. "},
		{"b", "Para\n1. a\n2.  b|", "Para\n  1.a\n  2. b"},
		{"⏎", "Para\n1. a\n2.  b\n3.  |", ""},
		{"⌫⌫", "Para\n1. a\n2.  b\n|", "Para\n  1.a\n  2.b\n"},
	})
	expect_typing(t, "- a\n- |b", {
		{"  ", "- a\n-   |b", "  •a\n  •  b"},
		{"⌫", "- a\n-  |b", "  •a\n  • b"},
		{"⌫", "- a\n- |b", "  •a\n  •b"},
		{"⌫", "- a\n|b", "  •a\nb"},
	})

	// Numbered lists stay in sequence, as one undo step with the edit
	expect_typing(t, "1. a\n2. b|\n3. c", {
		{"⏎x", "1. a\n2. b\n3. x|\n4. c", ""},
		{"⇥", "1. a\n2. b\n   1. x|\n3. c", "  1.a\n  2.b\n    1.x\n  3.c"},
		{"⏎y", "1. a\n2. b\n   1. x\n   2. y|\n3. c", ""},
		{"⇤", "1. a\n2. b\n   1. x\n3. y|\n4. c", ""},
	})
	expect_typing(t, "1. a\n2. |b\n3. c", {{"⌫", "1. a\n|b\n2. c", ""}})
	expect_typing(t, "1) a\n2) |\n3) c\n\n- d", {{"⏎", "1) a\n|\n2) c\n\n- d", ""}})
	expect_typing(t, "5. a|\n6. b", {{"⏎", "5. a\n6. |\n7. b", ""}})

	// Also after Delete, deleting a selection and cut; a number being edited
	// stays as typed
	expect_typing(t, "1. a|\n2. b\n3. c", {{"⌦", "1. a|2. b\n2. c", ""}})
	expect_typing(t, "1. a\n2. b\n13|. c", {{"⌫", "1. a\n2. b\n1|. c", ""}})
	for cut in ([]bool{false, true}) {
		e := md_editor_selecting("1. a\n«2. b\n»3. c")
		defer destroy_view(e)
		if cut {
			_ = textedit.copy_text(e, true)
		} else {
			press(e, sdl.K_BACKSPACE)
		}
		testing.expect_value(t, md_text(e), "1. a\n2. c")
		textedit.undo(e)
		testing.expect_value(t, md_text(e), "1. a\n2. b\n3. c")
	}
	{
		e := view_at("1. a|\n2. b")
		defer destroy_view(e)
		play(t, e, "⏎")
		textedit.undo(e)
		expect_after(t, e, "1. a|\n2. b")
	}

	// A real underline still makes a heading
	expect_typing(t, "|", {{"Title⏎--⏎", "Title\n--\n|", "H Title\n\n"}})

	// Tab and Shift+Tab
	expect_typing(t, "|", {
		{"- a⏎⇥b", "- a\n  - b|", "  •a\n    •b"},
		{"⇤", "- a\n- b|", "  •a\n  •b"},
		{"⇤", "- a\n- b|", "  •a\n  •b"},
	})

	// An item moves with the lines inside it
	expect_typing(t, "- a\n- b|\n  - c\n    more\n- d", {
		{"⇥", "- a\n  - b|\n    - c\n      more\n- d", "  •a\n    •b\n      •c\n      more\n  •d"},
		{"⇤", "- a\n- b|\n  - c\n    more\n- d", "  •a\n  •b\n    •c\n    more\n  •d"},
	})
	expect_typing(t, "- a\n  - |b\n    - c", {{"⌫", "- a\n  |b\n    - c", "  •a\n  b\n    •c"}})
	expect_typing(t, "1. a\n2. b|\n   1. x\n3. c", {
		{"⇥", "1. a\n   1. b|\n      1. x\n2. c", "  1.a\n    1.b\n      1.x\n  2.c"},
	})

	// Lists indented with tabs get tabs
	expect_typing(t, "- a\n\t- b\n- c|", {
		{"⇥", "- a\n\t- b\n\t- c|", "  •a\n    •b\n    •c"},
		{"⇤", "- a\n\t- b\n- c|", "  •a\n    •b\n  •c"},
	})
	expect_typing(t, "- a\n- b|\n\t- c", {{"⇥", "- a\n\t- b|\n\t\t- c", "  •a\n    •b\n      •c"}})

	// Backspace at an item's text removes its marker, the text going on in the
	// item it was in; then it deletes the indentation a level at a time
	expect_typing(t, "|", {
		{"- a⏎⇥b⏎⇥", "- a\n  - b\n    - |", ""},
		{"⌫", "- a\n  - b\n    |", ""},
		{"⌫", "- a\n  - b\n  |", ""},
		{"⌫", "- a\n  - b\n|", "  •a\n    •b\n"},
		{"⌫", "- a\n  - b|", ""},
	})
	expect_typing(t, "- a\n  - b\n    - |c", {
		{"⌫", "- a\n  - b\n    |c", ""},
		{"⌫", "- a\n  - b\n  |c", ""},
		{"⌫", "- a\n  - b\n|c", ""},
	})

	// Tab-indented items move out one tab at a time
	expect_typing(t, "- a\n\t- b\n\t\t- c|", {{"⇤", "- a\n\t- b\n\t- c|", "  •a\n    •b\n    •c"}})
	expect_typing(t, "- a\n\t- b\n\t\t- |c", {{"⌫", "- a\n\t- b\n\t  |c", ""}})

	// Backspace in the indentation under a list deletes a level at a time
	expect_typing(t, "- a\n  - b\n    |", {
		{"⌫", "- a\n  - b\n  |", ""},
		{"⌫", "- a\n  - b\n|", ""},
	})
	expect_typing(t, "- a\n  - b\n    |c", {
		{"⌫", "- a\n  - b\n  |c", "  •a\n    •b\n  c"},
		{"⌫", "- a\n  - b\n|c", "  •a\n    •b\nc"},
	})
	expect_typing(t, "- a\n|", {{"   ⌫", "- a\n  |", ""}})

	// Outside a list, one space at a time
	expect_typing(t, "x\n    |y", {{"⌫", "x\n   |y", ""}})

	// Quotes
	expect_typing(t, "|", {
		{"> a⏎", "> a\n> |", ""},
		{"⏎b", "> a\nb|", ""},
	})
}


@(test)
test_md_typing_indentation :: proc(t: ^testing.T) {
	// An item indents only under the item before it, after it is written too
	expect_typing(t, "- a|", {{"⇥", "- a|", ""}})
	expect_typing(t, "|", {
		{"- a⏎b⇥", "- a\n  - b|", "  •a\n    •b"},
		{"⇥", "- a\n  - b|", ""},
		{"⏎c⇥", "- a\n  - b\n    - c|", ""},
	})
	expect_typing(t, "Para\n- a|", {{"⇥", "Para\n- a|", ""}})

	// Tab types a tab outside list items, shown while the line is edited
	expect_typing(t, "|", {{"Hello⏎⇥⇥", "Hello\n\t\t|", "Hello\n        "}})
	expect_typing(t, "|Hello", {{"⇥", "\t|Hello", ""}})
	expect_typing(t, "Hello|", {{"⇥", "Hello\t|", "Hello    "}})
	expect_typing(t, "Hel|lo", {{"⇥", "Hel\t|lo", "Hel    lo"}})

	// Enter keeps indentation only as far as it places the line in its block
	expect_typing(t, "x\n\n\t\t|", {{"⏎Hello", "x\n\n\t\t\nHello|", "x\n\n\nHello"}})
	expect_typing(t, "- a\n  b|", {{"⏎c", "- a\n  b\n  c|", "  •a\n  b\n  c"}})
	expect_typing(t, "x\n\n    code|", {{"⏎", "x\n\n    code\n    |", ""}})
	expect_typing(t, "```\n\tcode|\n```", {{"⏎", "```\n\tcode\n\t|\n```", ""}})

	// Spaces show while their line is edited, even on a blank line, and
	// Backspace deletes them one at a time
	expect_typing(t, "x\n\n|", {
		{"  ", "x\n\n  |", "x\n\n  "},
		{"\t", "x\n\n  \t|", "x\n\n      "},
		{"⌫⌫", "x\n\n |", ""},
		{"⏎", "x\n\n \n|", "x\n\n\n"},
	})
}


// Editing as someone used to Obsidian's live preview expects it to work
@(test)
test_md_typing_like_obsidian :: proc(t: ^testing.T) {
	// Headings: the marker shows while the line is edited, Enter starts a
	// paragraph, and the heading is drawn as one once the caret leaves
	expect_typing(t, "|", {
		{"# Title", "# Title|", "H # Title"},
		{"⏎body", "# Title\nbody|", "H Title\nbody"},
		{"↑", "# Ti|tle\nbody", "H # Title\nbody"}, // keeping its x
	})
	expect_typing(t, "|", {{"## A⏎### B⏎", "## A\n### B\n|", "H A\nH B\n"}})

	// "#" without a space is text; adding the space makes the heading
	expect_typing(t, "|", {
		{"#tag", "#tag|", "#tag"},
		{"←←← ", "# |tag", "H # tag"},
	})

	// Inline styles hide their markers once the caret leaves the span
	expect_typing(t, "|", {
		{
			"some **bold** and *it* and `c`",
			"some **bold** and *it* and `c`|",
			"some bold and it and `c`",
		},
		{"←←←←←←←←←", "some **bold** and *it|* and `c`", "some bold and *it* and c"},
		{"→→→→→→→→→", "some **bold** and *it* and `c`|", ""},
		{"⏎", "some **bold** and *it* and `c`\n|", "some bold and it and c\n"},
	})

	// A task list: "- [ ] " makes a box, Enter continues with an empty one,
	// and Enter on an empty one leaves the list
	expect_typing(t, "|", {
		{"- [ ] buy milk", "- [ ] buy milk|", ""},
		{"⏎", "- [ ] buy milk\n- [ ] |", "  •☐buy milk\n  •☐"},
		{"eggs⏎⏎", "- [ ] buy milk\n- [ ] eggs\n|", "  •☐buy milk\n  •☐eggs\n"},
	})

	// Enter at the start of an item's text pushes it down as a new item
	expect_typing(t, "- one\n- |two", {{"⏎", "- one\n- \n- |two", "  •one\n  •\n  •two"}})

	// Nesting three levels with Tab, then back out with Shift+Tab, which stops
	// at the top level
	expect_typing(t, "|", {
		{"- a⏎⇥b⏎⇥c", "- a\n  - b\n    - c|", "  •a\n    •b\n      •c"},
		{"⇤⇤", "- a\n  - b\n- c|", "  •a\n    •b\n  •c"},
		{"⇤", "- a\n  - b\n- c|", "  •a\n    •b\n  •c"},
	})

	// Undo takes back a list edit and its renumbering in one step
	expect_typing(t, "1. a\n2. b|\n3. c", {
		{"⇥", "1. a\n   1. b|\n2. c", ""},
		{"↶", "1. a\n2. b|\n3. c", ""},
		{"⏎", "1. a\n2. b\n3. |\n4. c", ""},
		{"↶", "1. a\n2. b|\n3. c", ""},
	})

	// Quotes: continued by Enter, nested items inside them, left by Enter on
	// an empty line
	expect_typing(t, "|", {
		{"> a⏎- b⏎", "> a\n> - b\n> - |", ""},
		{"⏎", "> a\n> - b\n> |", ""},
		{"⏎", "> a\n> - b\n|", ""},
	})

	// Typing after the last item, then going back up into the list
	expect_typing(t, "- a\n- b\n\n|", {
		{"text", "- a\n- b\n\ntext|", "  •a\n  •b\n\ntext"},
		{"↑↑", "- a\n- b|\n\ntext", ""},
		{"⏎c", "- a\n- b\n- c|\n\ntext", "  •a\n  •b\n  •c\n\ntext"},
	})

	// Delete at the end of an item joins the next line's text
	expect_typing(t, "- a|\nb", {{"⌦", "- a|b", "  •ab"}})

	// A rule after a blank line, a heading underline right under a paragraph
	expect_typing(t, "x\n\n|", {{"---⏎", "x\n\n---\n|", ""}})
	{
		e := view_at("x\n\n|")
		defer destroy_view(e)
		play(t, e, "---⏎")
		testing.expect_value(t, line_layout(e, 2).kind, Line_Kind.Rule)
	}

	// Numbers keep going past 9, and the text stays aligned in the column
	expect_typing(t, "8. a|", {{"⏎b⏎c", "8. a\n9. b\n10. c|", ""}})

	// Multiple carets each continue their own item
	{
		e := view_at("- a|\n- b")
		defer destroy_view(e)
		end := buffer.length(&e.buf)
		append(&e.sels, Selection{end, end, -1})
		play(t, e, "⏎x")
		testing.expect_value(t, md_text(e), "- a\n- x\n- b\n- x")
	}

	// Tab on several selected items indents each under the one before
	{
		e := view_at("- a\n- b\n- c|")
		defer destroy_view(e)
		textedit.set_single_selection(e, {buffer.line_start(&e.buf, 1), buffer.length(&e.buf), -1})
		play(t, e, "⇥")
		testing.expect_value(t, md_text(e), "- a\n  - b\n  - c")
		play(t, e, "⇤")
		testing.expect_value(t, md_text(e), "- a\n- b\n- c")
	}
}


// Every key at every caret position of small documents covering each kind of
// line, through the checks in `play`
@(test)
test_md_typing_everywhere :: proc(t: ^testing.T) {
	sync.guard(&media_lock)
	defer images_destroy()

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
		"```\na\n\n\tb\n```",
		"- x\n\n  ```\n\n  ```",
		"x\n\n    code",
		"**bold** and `code` [link](u)",
		"x\n\n\t\t\n  ",
		"",
		"1. a\n2. ",
		"> - a\n> - ",
		"-  two spaces\n- [ ]  task",
		"8. a\n9. b\n10. c",
		"# Head\n- a\n> q\n\n---",
		"> a\n>\n> > b\n> c",
		"- a\n\t- b\n\t\t- c",
		"---\nk: v\n---\nx",
		"---\nunclosed",
		"$$\nx\n$$",
		"<div>\nx\n</div>",
		"a\r\n- b\r\n> c",
		"| [r] | b |\n|---|---|\n\n[r]: /u",
		"![[pic.png]] x",
	}
	keys := [?]string{"a", " ", "-", "#", "*", "`", ">", "⏎", "⌫", "⇥", "⇤"}
	for doc in docs {
		for at := 0; at <= len(doc); at += 1 {
			if at > 0 && doc[at - 1] == '\r' {
				continue
			}

			for key in keys {
				e := make_view(doc)
				defer destroy_view(e)
				textedit.set_single_selection(e, {at, at, -1})

				// Only where a click or the arrow keys can put the caret
				if !caret_shown(e, at) do break
				play(t, e, key, fmt.tprintf("%q at %d: ", doc, at))
			}
		}
	}
}


// Left and Right step over a list item's hidden marker in one move
@(test)
test_md_marker_steps :: proc(t: ^testing.T) {
	expect_typing(t, "Para\n- |one\n  - two", {
		{"←", "Para|\n- one\n  - two", ""},
		{"→", "Para\n- |one\n  - two", ""},
		{"→→→→", "Para\n- one\n  - |two", ""},
		{"←", "Para\n- one|\n  - two", ""},
	})

	// From the line start, where the marker shows, it is stepped through
	expect_typing(t, "Para\n|- one", {{"→", "Para\n-| one", ""}})
}
