package textedit

import "core:strings"
import "core:testing"

import "../buffer"

@(private = "file")
make_view :: proc(text: string) -> (v: View) {
	buffer.buffer_init(&v.buf, transmute([]u8)strings.clone(text))
	append(&v.sels, Selection{0, 0, -1})
	return
}


@(private = "file")
destroy_view :: proc(v: ^View) {
	buffer.buffer_destroy(&v.buf)
	delete(v.sels)
}


@(private = "file")
contents :: proc(v: ^View) -> string {
	return string(buffer.read_alloc(&v.buf, 0, buffer.length(&v.buf)))
}


@(test)
test_columns :: proc(t: ^testing.T) {
	text := "\tab\tc"
	testing.expect_value(t, visual_col(text, 1), 4)
	testing.expect_value(t, visual_col(text, 4), 8)
	testing.expect_value(t, byte_at_col(text, 1), 0) // nearer the tab's start
	testing.expect_value(t, byte_at_col(text, 3), 1)
	testing.expect_value(t, byte_at_col(text, 9), 5)
}


// Every caret edits at once, merging carets that end up together
@(test)
test_multiple_carets :: proc(t: ^testing.T) {
	v := make_view("one\ntwo\nthree")
	defer destroy_view(&v)
	append(&v.sels, Selection{4, 4, -1}, Selection{8, 8, -1})

	insert(&v, "> ")
	testing.expect_value(t, contents(&v), "> one\n> two\n> three")

	delete_text(&v, -1, word = false)
	testing.expect_value(t, contents(&v), ">one\n>two\n>three")
}


// Edits anywhere, made at once: the selections they ask for, and one undo
// step putting it all back
@(test)
test_apply_edits :: proc(t: ^testing.T) {
	v := make_view("fo\nfo")
	defer destroy_view(&v)
	clear(&v.sels)
	append(&v.sels, Selection{2, 2, -1}, Selection{5, 5, -1})

	// An insertion at the top, and each "fo" replaced by "foo(x)" with x selected
	edits := []Text_Edit {
		{lo = 0, hi = 0, text = "// top\n"},
		{lo = 0, hi = 2, text = "foo(x)", selects = true, sel = {4, 5}},
		{lo = 3, hi = 5, text = "foo(x)", selects = true, sel = {4, 5}, primary = true},
	}
	apply_edits(&v, .Other, edits)
	testing.expect_value(t, contents(&v), "// top\nfoo(x)\nfoo(x)")
	testing.expect_value(t, len(v.sels), 2)
	if len(v.sels) == 2 {
		testing.expect_value(t, v.sels[0], Selection{11, 12, -1})
		testing.expect_value(t, v.sels[1], Selection{18, 19, -1})
		testing.expect_value(t, v.primary, 1)
	}

	undo(&v)
	testing.expect_value(t, contents(&v), "fo\nfo")

	// Edits that select nothing (a rename): the carets stay in their words, at
	// the same distance in, and move with the text before them
	clear(&v.sels)
	append(&v.sels, Selection{1, 1, -1}, Selection{5, 5, -1})
	renames := []Text_Edit{{lo = 0, hi = 2, text = "bar"}, {lo = 3, hi = 5, text = "bar"}}
	apply_edits(&v, .Other, renames)
	testing.expect_value(t, contents(&v), "bar\nbar")
	testing.expect_value(t, len(v.sels), 2)
	if len(v.sels) == 2 {
		testing.expect_value(t, v.sels[0], Selection{1, 1, -1})
		testing.expect_value(t, v.sels[1], Selection{7, 7, -1})
	}
}


@(test)
test_word_at :: proc(t: ^testing.T) {
	v := make_view("foo_bar  (baz)")
	defer destroy_view(&v)

	lo, hi := word_at(&v, 2)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{0, 7})
	lo, hi = word_at(&v, 8)
	testing.expect_value(t, [2]int{lo, hi}, [2]int{7, 9})

	testing.expect_value(t, word_boundary(&v, 0, +1), 7)
	testing.expect_value(t, word_boundary(&v, 14, -1), 13)
}


// normalize runs the kind's snap first and merges carets that land together
@(test)
test_normalize_snap :: proc(t: ^testing.T) {
	v := make_view("abcdef")
	defer destroy_view(&v)
	kind := Kind {
		snap = snap_to_start,
	}
	v.kind = &kind

	append(&v.sels, Selection{3, 3, -1})
	normalize(&v)
	testing.expect_value(t, len(v.sels), 1)
}


@(private = "file")
snap_to_start :: proc(v: ^View) {
	for &s in v.sels do s = {0, 0, -1}
}


@(test)
test_visible_runs :: proc(t: ^testing.T) {
	runs := visible_runs("a\tb c", nil, nil, 0, 100, false, ascii_glyph)
	testing.expect_value(t, len(runs), 1)
	if len(runs) == 1 do testing.expect_value(t, runs[0].text, "a   b c")

	runs = visible_runs("ab", nil, nil, 0, 100, true, ascii_glyph)
	testing.expect_value(t, len(runs), 2)
	free_all(context.temp_allocator)
}


@(private = "file")
ascii_glyph :: proc(r: rune) -> bool {
	return r < 128
}


// Alt+Up/Down: the lines move with their selections, as one undo step
@(test)
test_move_lines :: proc(t: ^testing.T) {
	v := make_view("one\ntwo\nthree\nfour")
	defer destroy_view(&v)

	// A caret on "two" moves its line up, and stops at the top
	set_single_selection(&v, {5, 5, -1})
	move_lines(&v, -1)
	testing.expect_value(t, contents(&v), "two\none\nthree\nfour")
	testing.expect_value(t, v.sels[0].head, 1)
	move_lines(&v, -1)
	testing.expect_value(t, contents(&v), "two\none\nthree\nfour")

	// A selection ending at a line's start doesn't take that line
	set_single_selection(&v, {0, 8, -1})
	move_lines(&v, +1)
	testing.expect_value(t, contents(&v), "three\ntwo\none\nfour")
	testing.expect_value(t, v.sels[0], Selection{6, 14, -1})

	// Carets on touching lines move as one block, down to the last line
	clear(&v.sels)
	append(&v.sels, Selection{6, 6, -1}, Selection{10, 10, -1})
	move_lines(&v, +1)
	testing.expect_value(t, contents(&v), "three\nfour\ntwo\none")
	move_lines(&v, +1)
	testing.expect_value(t, contents(&v), "three\nfour\ntwo\none")

	// One undo step back
	undo(&v)
	testing.expect_value(t, contents(&v), "three\ntwo\none\nfour")
}


// The line break between the moved lines keeps its length
@(test)
test_move_lines_crlf :: proc(t: ^testing.T) {
	v := make_view("a\r\nbb\r\nc")
	defer destroy_view(&v)

	set_single_selection(&v, {3, 3, -1})
	move_lines(&v, +1)
	testing.expect_value(t, contents(&v), "a\r\nc\r\nbb")
	testing.expect_value(t, v.sels[0].head, 6)
}
