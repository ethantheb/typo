package editor

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// A one-line text editor: caret, selection, word jumps, clipboard. The caller
// handles Enter, Esc and Tab


Line_Edit :: struct {
	text:   [dynamic]u8,
	caret:  int, // byte offset
	anchor: int, // the selection's other end; caret when nothing is selected
}


line_edit_set :: proc(le: ^Line_Edit, s: string, select_lo, select_hi: int) {
	clear(&le.text)
	append(&le.text, s)
	le.anchor = clamp(select_lo, 0, len(s))
	le.caret = clamp(select_hi, 0, len(s))
}


line_edit_string :: proc(le: ^Line_Edit) -> string {
	return string(le.text[:])
}


@(private = "file")
selection :: proc(le: ^Line_Edit) -> (lo, hi: int) {
	return min(le.caret, le.anchor), max(le.caret, le.anchor)
}


@(private = "file")
replace_selection :: proc(le: ^Line_Edit, s: string) {
	lo, hi := selection(le)
	remove_range(&le.text, lo, hi)
	inject_at(&le.text, lo, s)
	le.caret = lo + len(s)
	le.anchor = le.caret
}


// Moves the caret, and the anchor with it unless extending the selection
@(private = "file")
move_caret :: proc(le: ^Line_Edit, to: int, extend: bool) {
	le.caret = to
	if !extend do le.anchor = to
}


@(private = "file")
prev_rune :: proc(s: string, i: int) -> int {
	if i <= 0 do return 0

	_, size := utf8.decode_last_rune(s[:i])
	return i - size
}


@(private = "file")
next_rune :: proc(s: string, i: int) -> int {
	if i >= len(s) do return len(s)

	_, size := utf8.decode_rune(s[i:])
	return i + size
}


@(private = "file")
is_word :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r)
}


// The start of the word before i, or the end of the word after it
@(private = "file")
word_step :: proc(s: string, i, dir: int) -> int {
	i := i

	if dir < 0 {
		// Back over what isn't a word, then over the word
		for i > 0 {
			r, _ := utf8.decode_last_rune(s[:i])
			if is_word(r) do break
			i = prev_rune(s, i)
		}
		for i > 0 {
			r, _ := utf8.decode_last_rune(s[:i])
			if !is_word(r) do break
			i = prev_rune(s, i)
		}
	} else {
		for i < len(s) {
			r, _ := utf8.decode_rune(s[i:])
			if is_word(r) do break
			i = next_rune(s, i)
		}
		for i < len(s) {
			r, _ := utf8.decode_rune(s[i:])
			if !is_word(r) do break
			i = next_rune(s, i)
		}
	}

	return i
}


// Typing and editing keys. Returns whether the event was one, and whether the
// text changed
line_edit_event :: proc(le: ^Line_Edit, event: ^sdl.Event) -> (handled, changed: bool) {
	#partial switch event.type {
	case .TEXT_INPUT:
		replace_selection(le, string(event.text.text))
		return true, true

	case .KEY_DOWN:
		return line_edit_key(le, event.key)
	}
	return false, false
}


@(private = "file")
line_edit_key :: proc(le: ^Line_Edit, key: sdl.KeyboardEvent) -> (handled, changed: bool) {
	s := string(le.text[:])
	lo, hi := selection(le)
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	selected := lo != hi

	switch key.key {
	case sdl.K_LEFT:
		switch {
		case ctrl:               move_caret(le, word_step(s, le.caret, -1), shift)
		case selected && !shift: move_caret(le, lo, false)
		case:                    move_caret(le, prev_rune(s, le.caret), shift)
		}

	case sdl.K_RIGHT:
		switch {
		case ctrl:               move_caret(le, word_step(s, le.caret, +1), shift)
		case selected && !shift: move_caret(le, hi, false)
		case:                    move_caret(le, next_rune(s, le.caret), shift)
		}

	case sdl.K_HOME:
		move_caret(le, 0, shift)

	case sdl.K_END:
		move_caret(le, len(s), shift)

	case sdl.K_BACKSPACE:
		// With nothing selected, the character or word before the caret
		if !selected {
			le.anchor = ctrl ? word_step(s, le.caret, -1) : prev_rune(s, le.caret)
		}
		changed = le.anchor != le.caret
		replace_selection(le, "")

	case sdl.K_DELETE:
		if !selected {
			le.anchor = ctrl ? word_step(s, le.caret, +1) : next_rune(s, le.caret)
		}
		changed = le.anchor != le.caret
		replace_selection(le, "")

	case:
		if !ctrl do return false, false
		return line_edit_shortcut(le, key)
	}

	return true, changed
}


// Ctrl+A, and the clipboard
@(private = "file")
line_edit_shortcut :: proc(le: ^Line_Edit, key: sdl.KeyboardEvent) -> (handled, changed: bool) {
	s := string(le.text[:])
	lo, hi := selection(le)

	switch base_key(key) {
	case sdl.K_A:
		le.anchor, le.caret = 0, len(s)

	case sdl.K_C, sdl.K_X:
		if lo == hi do return true, false

		_ = sdl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
		if base_key(key) == sdl.K_X {
			replace_selection(le, "")
			changed = true
		}

	case sdl.K_V:
		raw := sdl.GetClipboardText()
		if raw == nil do return true, false
		defer sdl.free(raw)

		// One line: line breaks become spaces
		text, _ := strings.replace_all(string(cstring(raw)), "\r\n", " ", context.temp_allocator)
		text, _ = strings.replace_all(text, "\n", " ", context.temp_allocator)
		replace_selection(le, text)
		changed = true

	case:
		return false, false
	}

	return true, changed
}


// The text with its selection and caret, laid out in a row (no box)
line_edit_ui :: proc(le: ^Line_Edit, size: u16, color: clay.Color) {
	s := string(le.text[:])
	lo, hi := selection(le)

	if lo > 0 do label(s[:lo], color, size)
	if le.caret == lo do line_edit_caret(size)

	if lo != hi {
		if clay.UI()({
			backgroundColor = gfx.theme.selection,
			cornerRadius = clay.CornerRadiusAll(2),
		}) {
			label(s[lo:hi], gfx.theme.text_bright, size)
		}
		if le.caret == hi do line_edit_caret(size)
	}

	if hi < len(s) do label(s[hi:], color, size)
}


@(private = "file")
line_edit_caret :: proc(size: u16) {
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(1.5), clay.SizingFixed(f32(size) + 3)}},
		backgroundColor = gfx.theme.caret,
	}) {}
}
