package editor

import "core:strings"
import "core:sync"
import "core:testing"
import "core:unicode/utf8"

import sdl "../vendor/sdl3"

// The one-line text field: keys replayed through line_edit_event at the start,
// middle and end of the text, checking the text, the selection and that the
// caret stays on a character boundary


@(private = "file")
press_key :: proc(
	le: ^Line_Edit,
	key: sdl.Keycode,
	mod: sdl.Keymod = {},
) -> (
	handled, changed: bool,
) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	event.key.mod = mod
	return line_edit_event(le, &event)
}


// A shortcut, with the scancode the chords match on
@(private = "file")
press_chord :: proc(le: ^Line_Edit, scancode: sdl.Scancode, mod: sdl.Keymod) -> bool {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.key = sdl.GetKeyFromScancode(scancode, {}, true)
	event.key.mod = mod
	handled, _ := line_edit_event(le, &event)
	return handled
}


@(private = "file")
type_into :: proc(le: ^Line_Edit, text: string) {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(text, context.temp_allocator)
	line_edit_event(le, &event)
}


// The text, with [ ] around the selection and | at the caret when nothing is
// selected; also checks the caret and anchor are on character boundaries
@(private = "file")
shown :: proc(t: ^testing.T, le: ^Line_Edit) -> string {
	s := string(le.text[:])
	testing.expect(t, on_boundary(s, le.caret), "the caret is on a character boundary")
	testing.expect(t, on_boundary(s, le.anchor), "the anchor is on a character boundary")

	lo, hi := min(le.caret, le.anchor), max(le.caret, le.anchor)
	if lo == hi {
		return strings.concatenate({s[:lo], "|", s[lo:]}, context.temp_allocator)
	}
	return strings.concatenate({s[:lo], "[", s[lo:hi], "]", s[hi:]}, context.temp_allocator)
}


@(private = "file")
on_boundary :: proc(s: string, i: int) -> bool {
	return i >= 0 && i <= len(s) && (i == len(s) || utf8.rune_start(s[i]))
}


@(private = "file")
field_at :: proc(text: string, caret: int) -> (le: Line_Edit) {
	line_edit_set(&le, text, caret, caret)
	return
}


@(test)
test_field_typing :: proc(t: ^testing.T) {
	Case :: struct {
		caret: int,
		typed: string,
		want:  string,
	}
	cases := []Case{
		{0, "x", "x|one two"},
		{3, " ", "one | two"},
		{4, "ab", "one ab|two"},
		{7, "s", "one twos|"},
		{7, "é", "one twoé|"},
	}
	for c in cases {
		le := field_at("one two", c.caret)
		defer line_edit_destroy(&le)

		type_into(&le, c.typed)
		testing.expect_value(t, shown(t, &le), c.want)
	}

	// Typing replaces the selection
	le := field_at("one two", 0)
	defer line_edit_destroy(&le)
	le.anchor, le.caret = 4, 7
	type_into(&le, "three")
	testing.expect_value(t, shown(t, &le), "one three|")
}


@(test)
test_field_deleting :: proc(t: ^testing.T) {
	Case :: struct {
		caret: int,
		key:   sdl.Keycode,
		mod:   sdl.Keymod,
		want:  string,
		changed: bool,
	}
	CTRL :: sdl.KMOD_LCTRL
	cases := []Case{
		{0, sdl.K_BACKSPACE, {}, "|one twé", false},
		{4, sdl.K_BACKSPACE, {}, "one|twé", true},
		{8, sdl.K_BACKSPACE, {}, "one tw|", true}, // é is two bytes
		{8, sdl.K_BACKSPACE, CTRL, "one |", true},
		{6, sdl.K_BACKSPACE, CTRL, "one |é", true},
		{0, sdl.K_DELETE, {}, "|ne twé", true},
		{6, sdl.K_DELETE, {}, "one tw|", true},
		{8, sdl.K_DELETE, {}, "one twé|", false},
		{0, sdl.K_DELETE, CTRL, "| twé", true},
		{3, sdl.K_DELETE, CTRL, "one|", true},
	}
	for c in cases {
		le := field_at("one twé", c.caret)
		defer line_edit_destroy(&le)

		handled, changed := press_key(&le, c.key, c.mod)
		testing.expect(t, handled)
		testing.expect_value(t, changed, c.changed)
		testing.expect_value(t, shown(t, &le), c.want)
	}

	// Backspace and Delete remove a selection
	for key in ([]sdl.Keycode{sdl.K_BACKSPACE, sdl.K_DELETE}) {
		le := field_at("one two", 1)
		defer line_edit_destroy(&le)
		le.anchor = 5

		press_key(&le, key)
		testing.expect_value(t, shown(t, &le), "o|wo")
	}
}


@(test)
test_field_moving :: proc(t: ^testing.T) {
	Case :: struct {
		caret: int,
		key:   sdl.Keycode,
		mod:   sdl.Keymod,
		want:  string,
	}
	CTRL :: sdl.KMOD_LCTRL
	SHIFT :: sdl.KMOD_LSHIFT
	cases := []Case{
		{0, sdl.K_LEFT, {}, "|ab_c dé.f"},
		{6, sdl.K_RIGHT, {}, "ab_c dé|.f"},
		{8, sdl.K_LEFT, {}, "ab_c d|é.f"},
		{10, sdl.K_RIGHT, {}, "ab_c dé.f|"},
		{5, sdl.K_HOME, {}, "|ab_c dé.f"},
		{5, sdl.K_END, {}, "ab_c dé.f|"},
		{0, sdl.K_RIGHT, CTRL, "ab_c| dé.f"}, // _ is part of a word
		{4, sdl.K_RIGHT, CTRL, "ab_c dé|.f"},
		{10, sdl.K_LEFT, CTRL, "ab_c dé.|f"},
		{5, sdl.K_LEFT, CTRL, "|ab_c dé.f"},
		{5, sdl.K_END, SHIFT, "ab_c [dé.f]"},
		{5, sdl.K_HOME, SHIFT, "[ab_c ]dé.f"},
		{4, sdl.K_RIGHT, SHIFT | CTRL, "ab_c[ dé].f"},
	}
	for c in cases {
		le := field_at("ab_c dé.f", c.caret)
		defer line_edit_destroy(&le)

		handled, changed := press_key(&le, c.key, c.mod)
		testing.expect(t, handled && !changed)
		testing.expect_value(t, shown(t, &le), c.want)
	}

	// With a selection, Left and Right go to its ends
	le := field_at("one two", 1)
	defer line_edit_destroy(&le)
	le.anchor = 5
	press_key(&le, sdl.K_LEFT)
	testing.expect_value(t, shown(t, &le), "o|ne two")
	le.anchor = 5
	press_key(&le, sdl.K_RIGHT)
	testing.expect_value(t, shown(t, &le), "one t|wo")

	// Alt combinations are left to the shortcuts (Go back)
	handled, _ := press_key(&le, sdl.K_LEFT, sdl.KMOD_LALT)
	testing.expect(t, !handled)
}


// Ctrl+A, the clipboard and undo go through the bindings, so the field takes
// them before any shortcut acting on the pane behind it
@(test)
test_field_commands :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	saved := g.settings.bindings
	defer g.settings.bindings = saved
	for cmd in Command do g.settings.bindings[cmd] = default_bindings(cmd)

	CTRL :: sdl.KMOD_LCTRL

	// Select all, at the start, middle and end
	for caret in ([]int{0, 3, 7}) {
		le := field_at("one two", caret)
		defer line_edit_destroy(&le)

		testing.expect(t, press_chord(&le, .A, CTRL))
		testing.expect_value(t, shown(t, &le), "[one two]")
		type_into(&le, "x")
		testing.expect_value(t, shown(t, &le), "x|")
	}

	// Commands for the pane behind never get through; others do
	testing.expect(t, !field_lets_through(.Select_All))
	testing.expect(t, !field_lets_through(.Paste))
	testing.expect(t, !field_lets_through(.Move_Line_Up))
	testing.expect(t, field_lets_through(.Find_File))
	testing.expect(t, field_lets_through(.Find_Next))

	// Undo takes back typing as one step, then a deletion; redo puts them back
	le := field_at("ab", 2)
	defer line_edit_destroy(&le)
	type_into(&le, " c")
	type_into(&le, "d")
	press_key(&le, sdl.K_BACKSPACE)
	testing.expect_value(t, shown(t, &le), "ab c|")

	testing.expect(t, press_chord(&le, .Z, CTRL))
	testing.expect_value(t, shown(t, &le), "ab cd|")
	testing.expect(t, press_chord(&le, .Z, CTRL))
	testing.expect_value(t, shown(t, &le), "ab|")
	testing.expect(t, !line_edit_command(&le, .Undo))
	testing.expect(t, press_chord(&le, .Y, CTRL))
	testing.expect_value(t, shown(t, &le), "ab cd|")
	testing.expect(t, press_chord(&le, .Z, CTRL | sdl.KMOD_LSHIFT))
	testing.expect_value(t, shown(t, &le), "ab c|")

	// A caret move ends a typing step; new typing drops what redo had
	press_key(&le, sdl.K_HOME)
	type_into(&le, "x")
	type_into(&le, "y")
	press_key(&le, sdl.K_END)
	type_into(&le, "z")
	line_edit_command(&le, .Undo)
	testing.expect_value(t, shown(t, &le), "xyab c|")
	line_edit_command(&le, .Undo)
	testing.expect_value(t, shown(t, &le), "|ab c")
	type_into(&le, "q")
	testing.expect(t, !line_edit_command(&le, .Redo))
}


@(test)
test_field_clipboard :: proc(t: ^testing.T) {
	le := field_at("one two", 0)
	defer line_edit_destroy(&le)

	// Copying keeps the text, cutting removes it
	le.anchor, le.caret = 0, 4
	testing.expect_value(t, line_edit_copy(&le, cut = false), "one ")
	testing.expect_value(t, shown(t, &le), "[one ]two")
	testing.expect_value(t, line_edit_copy(&le, cut = true), "one ")
	testing.expect_value(t, shown(t, &le), "|two")

	// Pasting at the start, middle and end, on one line
	testing.expect(t, line_edit_paste(&le, "a\r\nb"))
	testing.expect_value(t, shown(t, &le), "a b|two")
	le.anchor, le.caret = 4, 4
	line_edit_paste(&le, "\n")
	testing.expect_value(t, shown(t, &le), "a bt |wo")
	le.anchor, le.caret = 7, 7
	line_edit_paste(&le, "s")
	testing.expect_value(t, shown(t, &le), "a bt wos|")

	// Over a selection; pasting nothing over nothing changes nothing
	le.anchor, le.caret = 0, 8
	line_edit_paste(&le, "new")
	testing.expect_value(t, shown(t, &le), "new|")
	testing.expect(t, !line_edit_paste(&le, ""))

	// One undo step each
	line_edit_command(&le, .Undo)
	testing.expect_value(t, shown(t, &le), "[a bt wos]")
}
