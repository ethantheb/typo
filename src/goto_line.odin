package editor

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "buffer"
import "gfx"
import "textedit"

// Go to line (Ctrl+G): a small bar at the top of the focused editor, centered
// above the text like the find bar, so the place previewed shows below it. It
// takes "line" or "line:column" (from 1; numbers out of range clamp), and the
// editor scrolls there as it is typed, the caret on it. Enter keeps the place
// and records the jump (Go back returns); Esc puts the caret and scroll back.
// A press outside the bar, another shortcut or the editor losing the keys
// closes it, the caret put back and the view left where it is. Lines are the
// document's, in rendered Markdown too


Goto_Line :: struct {
	open:    bool,
	pane:    ^Pane,
	edit:    Line_Edit,
	invalid: bool, // the text isn't a place

	// Where the editor was, put back by Esc
	sels:    [dynamic]textedit.Selection,
	primary: int,
	scroll:  [2]f64, // target_x, target_y
}

GOTO_FIELD_WIDTH :: 220


// Opens the bar on the focused editor. Returns false if no editor is focused
goto_line_open :: proc() -> bool {
	p := g.panes.focused
	e := focused_editor()
	if e == nil || e.status != .Text {
		return false
	}

	gl := &g.goto_line
	if gl.open do goto_line_close(restore = false)

	gl.open = true
	gl.pane = p
	gl.invalid = false
	line_edit_clear(&gl.edit)

	// Where to come back to
	clear(&gl.sels)
	append(&gl.sels, ..e.sels[:])
	gl.primary = e.primary
	gl.scroll = {f64(e.target_x), e.target_y}
	return true
}


// Closes the bar. `restore` puts the caret back; `scroll` the view too
goto_line_close :: proc(restore := true, scroll := false) {
	gl := &g.goto_line
	if !gl.open do return

	e, is_editor := gl.pane.content.(^Editor)
	if restore && is_editor && e.status == .Text {
		put_back(gl, e, scroll)
	}

	gl.open = false
	gl.pane = nil
}


goto_line_destroy :: proc() {
	gl := &g.goto_line
	gl.open = false
	line_edit_destroy(&gl.edit)
	delete(gl.sels)
}


// Whether the pointer is over the bar, which keeps what is under it from
// taking the mouse (see ui_interactive)
goto_line_covers_pointer :: proc() -> bool {
	return g.goto_line.open && pointer_in(clay.ID("GotoBar"))
}


// Before the panes' frames: a press outside the bar, another pane focused or
// a popup over the editors closes it
goto_line_frame :: proc() {
	gl := &g.goto_line
	if !gl.open do return

	pressed := g.mouse_pressed || g.right_pressed
	pressed_outside := pressed && !pointer_in(clay.ID("GotoBar"))
	if pressed_outside || gl.pane != g.panes.focused || editors_covered() {
		goto_line_close()
	}
}


// Keys while the bar is open; it takes them all, letting through shortcuts
// that don't act on the editor behind it
goto_line_handle_event :: proc(event: ^sdl.Event) -> bool {
	gl := &g.goto_line
	if !gl.open do return false

	if event.type == .KEY_DOWN {
		switch event.key.key {
		case sdl.K_ESCAPE:
			goto_line_close(restore = true, scroll = true)
			return true
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			accept()
			return true
		}
	}

	handled, changed := line_edit_event(&gl.edit, event)
	if changed do preview()
	if handled || event.type != .KEY_DOWN {
		return true
	}

	// Go to line again selects the text; other shortcuts that leave the
	// editor's text alone close the bar (the caret put back) and run
	cmd, is_command := command_for_key(event.key)
	switch {
	case !is_command:
	case cmd == .Go_To_Line:
		line_edit_select_all(&gl.edit)
	case field_lets_through(cmd):
		goto_line_close()
		run_command(cmd)
	}
	return true
}


// --- Places ------------------------------------------------------------------------

// Reads "line", "line:column" or ":line" (spaces around are fine; a comma may
// stand for the colon). Numbers count from 1; column is 0 when not given.
// Numbers too large to hold are as large as can be (they clamp later)
goto_parse :: proc(text: string) -> (line, column: int, ok: bool) {
	s := strings.trim_space(text)
	s = strings.trim_prefix(s, ":")

	line_text, sep, column_text := strings.partition(s, ":")
	if sep == "" {
		line_text, sep, column_text = strings.partition(s, ",")
	}

	line, ok = parse_count(strings.trim_space(line_text))
	if !ok do return 0, 0, false
	if sep == "" do return line, 0, true

	column, ok = parse_count(strings.trim_space(column_text))
	if !ok do return 0, 0, false
	return line, column, true
}


// Digits only, saturating instead of overflowing
@(private = "file")
parse_count :: proc(s: string) -> (n: int, ok: bool) {
	if s == "" do return 0, false

	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}

		digit := int(c - '0')
		n = n > (max(int) - digit) / 10 ? max(int) : n * 10 + digit
	}
	return n, true
}


// The offset of a line and column (from 1; column 0 for the line's start),
// clamped into the document: the column counts characters and stops at the
// line's end
goto_offset :: proc(b: ^buffer.Buffer, line, column: int) -> int {
	last := buffer.line_count(b) - 1
	index := clamp(line - 1, 0, last)
	start := buffer.line_start(b, index)
	end := buffer.line_end(b, index)
	if column <= 1 do return start

	// A character takes 1 to 4 bytes: with more characters before the column
	// than the line has bytes, it is past the end; else within 4 bytes each
	chars := column - 1
	if chars >= end - start do return end

	text := string(buffer.read_alloc(b, start, min(end, start + 4 * chars)))
	i := 0
	for _ in 0 ..< chars {
		if i >= len(text) do break

		_, size := utf8.decode_rune(text[i:])
		i += size
	}
	return start + i
}


// Scrolls to the place typed, its line in the middle, with the caret there;
// back to where it was while there is none
@(private = "file")
preview :: proc() {
	gl := &g.goto_line
	e := gl.pane.content.(^Editor)

	text := line_edit_string(&gl.edit)
	line, column, ok := goto_parse(text)
	gl.invalid = !ok && strings.trim_space(text) != ""
	if !ok {
		put_back(gl, e, scroll = true)
		return
	}

	at := goto_offset(&e.buf, line, column)
	textedit.show_caret(e, false)
	textedit.set_single_selection(e, {at, at, -1})
	e.reveal = true
	e.center = true
}


// Enter: the place typed, recorded in the jump list from where the caret was
@(private = "file")
accept :: proc() {
	gl := &g.goto_line
	e := gl.pane.content.(^Editor)

	line, column, ok := goto_parse(line_edit_string(&gl.edit))
	if !ok {
		goto_line_close(restore = true, scroll = true)
		return
	}

	// The caret back where it was for the jump list; the view stays
	at := goto_offset(&e.buf, line, column)
	goto_line_close(restore = true)
	jump_to(e.path, at)
}


@(private = "file")
put_back :: proc(gl: ^Goto_Line, e: ^Editor, scroll: bool) {
	clear(&e.sels)
	append(&e.sels, ..gl.sels[:])
	e.primary = gl.primary
	textedit.normalize(e)

	if scroll {
		e.target_x = f32(gl.scroll.x)
		e.target_y = gl.scroll.y
		e.reveal = false
	}
}


// --- The bar -----------------------------------------------------------------------

// The bar, as a floating child of the pane element being declared
goto_line_ui :: proc(p: ^Pane) {
	gl := &g.goto_line
	if !gl.open || gl.pane != p {
		return
	}
	e := p.content.(^Editor)

	g.in_goto_bar = true
	defer g.in_goto_bar = false

	if clay.UI(clay.ID("GotoBar"))({
		layout = {padding = clay.PaddingAll(4)},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .Parent,
			attachment = {element = .CenterTop, parent = .CenterTop},
			offset = {0, PANE_HEADER_HEIGHT + 6},
			zIndex = 6, // over the find bar
		},
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		look := Field_Look {
			width   = GOTO_FIELD_WIDTH,
			height  = 26,
			size    = FONT_SIZE_SMALL,
			padding = 8,
		}
		if gl.invalid do look.edge = gfx.theme.error

		text_field(clay.ID("GotoField"), &gl.edit, goto_placeholder(e), true, look)
	}
}


// "Line 120 of 4,032": the caret's line (where it was) and the line count
@(private = "file")
goto_placeholder :: proc(e: ^Editor) -> string {
	gl := &g.goto_line
	head := gl.sels[gl.primary].head
	line := buffer.offset_to_line(&e.buf, head) + 1
	count := buffer.line_count(&e.buf)
	return fmt.tprintf("Line %s of %s", grouped(line), grouped(count))
}


// A count with its thousands grouped: 4,032
@(private)
grouped :: proc(n: int) -> string {
	digits := fmt.tprintf("%d", n)
	sb := strings.builder_make(context.temp_allocator)
	for c, i in transmute([]u8)digits {
		if i > 0 && (len(digits) - i) % 3 == 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}
