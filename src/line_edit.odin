package editor

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// A one-line text editor: caret, selection, word jumps, clipboard. The caller
// handles Enter, Esc and Tab.

Line_Edit :: struct {
	text:   [dynamic]u8,
	caret:  int, // byte offset
	anchor: int, // the selection's other end; caret when nothing is selected
}

line_edit_set :: proc(le: ^Line_Edit, s: string, select_lo, select_hi: int) {
	clear(&le.text)
	append(&le.text, s)
	le.anchor, le.caret = clamp(select_lo, 0, len(s)), clamp(select_hi, 0, len(s))
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

// The start of the word before i, or the end of the word after it.
@(private = "file")
word_step :: proc(s: string, i, dir: int) -> int {
	i := i
	if dir < 0 {
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
// text changed.
line_edit_event :: proc(le: ^Line_Edit, event: ^sdl.Event) -> (handled, changed: bool) {
	s := string(le.text[:])
	lo, hi := selection(le)
	#partial switch event.type {
	case .TEXT_INPUT:
		replace_selection(le, string(event.text.text))
		return true, true
	case .KEY_DOWN:
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		shift := event.key.mod & sdl.KMOD_SHIFT != {}
		move :: proc(le: ^Line_Edit, to: int, shift: bool) {
			le.caret = to
			if !shift do le.anchor = to
		}
		switch event.key.key {
		case sdl.K_LEFT:
			switch {
			case ctrl:            move(le, word_step(s, le.caret, -1), shift)
			case lo != hi && !shift: move(le, lo, false)
			case:                 move(le, prev_rune(s, le.caret), shift)
			}
		case sdl.K_RIGHT:
			switch {
			case ctrl:            move(le, word_step(s, le.caret, +1), shift)
			case lo != hi && !shift: move(le, hi, false)
			case:                 move(le, next_rune(s, le.caret), shift)
			}
		case sdl.K_HOME: move(le, 0, shift)
		case sdl.K_END:  move(le, len(s), shift)
		case sdl.K_BACKSPACE:
			if lo == hi do le.anchor = ctrl ? word_step(s, le.caret, -1) : prev_rune(s, le.caret)
			changed = le.anchor != le.caret
			replace_selection(le, "")
		case sdl.K_DELETE:
			if lo == hi do le.anchor = ctrl ? word_step(s, le.caret, +1) : next_rune(s, le.caret)
			changed = le.anchor != le.caret
			replace_selection(le, "")
		case:
			if !ctrl do return false, false
			switch base_key(event.key) {
			case sdl.K_A:
				le.anchor, le.caret = 0, len(s)
			case sdl.K_C, sdl.K_X:
				if lo != hi {
					_ = sdl.SetClipboardText(strings.clone_to_cstring(s[lo:hi], context.temp_allocator))
					if base_key(event.key) == sdl.K_X {
						replace_selection(le, "")
						changed = true
					}
				}
			case sdl.K_V:
				raw := sdl.GetClipboardText()
				if raw == nil do return true, false
				defer sdl.free(raw)
				text, _ := strings.replace_all(string(cstring(raw)), "\r\n", " ", context.temp_allocator)
				text, _ = strings.replace_all(text, "\n", " ", context.temp_allocator)
				replace_selection(le, text)
				changed = true
			case:
				return false, false
			}
		}
		return true, changed
	}
	return false, false
}

// The text with its selection and caret, laid out in a row (no box).
line_edit_ui :: proc(le: ^Line_Edit, size: u16, color: clay.Color) {
	s := string(le.text[:])
	lo, hi := selection(le)
	part :: proc(s: string, size: u16, color: clay.Color) {
		if s != "" do label(s, color, size)
	}
	caret :: proc(size: u16) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(1.5), clay.SizingFixed(f32(size) + 3)}}, backgroundColor = gfx.theme.caret}) {}
	}
	part(s[:lo], size, color)
	if le.caret == lo do caret(size)
	if lo != hi {
		if clay.UI()({backgroundColor = gfx.theme.selection, cornerRadius = clay.CornerRadiusAll(2)}) {
			label(s[lo:hi], gfx.theme.text_bright, size)
		}
		if le.caret == hi do caret(size)
	}
	part(s[hi:], size, color)
}
