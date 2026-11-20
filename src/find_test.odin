package editor

import "core:strings"
import "core:sync"
import "core:testing"

import "buffer"
import "textedit"

// Find in an editor: matching with each option, moving between matches, and
// matches across the slices the search reads a frame at a time. The tests share
// g.find, so they take turns (app_state_lock)


// Runs the search on an editor to the end, as frames would
@(private = "file")
search :: proc(e: ^Editor, query: string, options: bit_set[Find_Option] = {}) {
	f := &g.find
	f.open = true
	f.options = options
	line_edit_set(&f.edit, query, 0, 0)

	for _ in 0 ..< 1000 {
		find_frame()
		if f.done || f.invalid {
			break
		}
	}
}


// A pane for an editor, with the bar open on it
@(private = "file")
open_on :: proc(pane: ^Pane, text: string) -> ^Editor {
	e := new(Editor)
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(text))
	e.status = .Text
	e.kind = &TEXT_KIND
	append(&e.sels, Selection{0, 0, -1})

	pane^ = {content = e}
	g.find.pane = pane
	return e
}


@(private = "file")
close_on :: proc(e: ^Editor) {
	find_close()
	buffer.buffer_destroy(&e.buf)
	delete(e.sels)
	free(e)

	delete(g.find.query)
	delete(g.find.matches)
	line_edit_destroy(&g.find.edit)
	g.find = {}
}


@(test)
test_find_options :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	pane: Pane
	e := open_on(&pane, "Foo foo FOO food\nfoo_bar")
	defer close_on(e)

	// ASCII case is ignored unless asked
	search(e, "foo")
	testing.expect_value(t, len(g.find.matches), 5)
	testing.expect_value(t, len(e.marks), 5)

	search(e, "foo", {.Match_Case})
	testing.expect_value(t, len(g.find.matches), 3)

	// Whole words: not "food", nor "foo_bar"
	search(e, "foo", {.Whole_Word})
	testing.expect_value(t, len(g.find.matches), 3)

	// Regular expressions, with the other options
	search(e, `fo+d`, {.Regex})
	testing.expect_value(t, len(g.find.matches), 1)
	testing.expect_value(t, g.find.matches[0], [2]int{12, 16})

	search(e, `f\w+`, {.Regex, .Match_Case, .Whole_Word})
	testing.expect_value(t, len(g.find.matches), 3)

	search(e, `(`, {.Regex})
	testing.expect(t, g.find.invalid, "an unclosed group is invalid")
}


@(test)
test_find_moves_between_matches :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	pane: Pane
	e := open_on(&pane, "a x a x a")
	defer close_on(e)

	// The first match at or after the caret is selected
	textedit.set_single_selection(e, {3, 3, -1})
	search(e, "a")
	testing.expect_value(t, g.find.current, 1)
	testing.expect_value(t, e.sels[0], Selection{4, 5, -1})

	// Next and previous, wrapping around both ends
	find_step(+1)
	testing.expect_value(t, g.find.current, 2)
	find_step(+1)
	testing.expect_value(t, g.find.current, 0)
	find_step(-1)
	testing.expect_value(t, g.find.current, 2)
	testing.expect_value(t, e.sels[0], Selection{8, 9, -1})

	// An edit searches again, keeping the selected match current
	textedit.set_single_selection(e, {0, 0, -1})
	textedit.insert(e, "a ")
	textedit.set_single_selection(e, {6, 7, -1})
	find_frame()
	testing.expect_value(t, len(g.find.matches), 4)
	testing.expect_value(t, g.find.current, 2)
}


// The search reads FIND_PLAIN_BYTES a frame: a match across that boundary is
// found once, and a whole-word check sees the byte before a slice
@(test)
test_find_across_slices :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for _ in 0 ..< FIND_PLAIN_BYTES - 3 do strings.write_byte(&sb, '.')
	strings.write_string(&sb, "needle.xneedle")

	pane: Pane
	e := open_on(&pane, strings.to_string(sb))
	defer close_on(e)

	search(e, "needle")
	testing.expect_value(t, len(g.find.matches), 2)
	testing.expect_value(t, g.find.matches[0][0], FIND_PLAIN_BYTES - 3)

	search(e, "needle", {.Whole_Word})
	testing.expect_value(t, len(g.find.matches), 1)
}
