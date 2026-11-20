package editor

import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// The one-line text field every text input uses: caret, selection, words,
// clipboard and undo (line_edit_event), and the box with the mouse (text_field):
// a press places the caret, Shift+press extends the selection, a double press
// selects a word, a triple press all, and dragging selects, scrolling the text
// past either end of the box. Text longer than the box scrolls sideways to keep
// the caret in view. Positions are measured with the font the text is drawn in.
// The caller decides focus and handles Enter, Esc, Tab and Up/Down


Line_Edit :: struct {
	text:     [dynamic]u8,
	caret:    int, // byte offset
	anchor:   int, // the selection's other end; caret when nothing is selected
	scroll:   f32, // how far the text is scrolled left, in logical pixels

	// Selecting with the mouse
	drag:     Field_Drag,
	drag_lo:  int, // the word a double press selected, which dragging keeps
	drag_hi:  int,

	undo:     [dynamic]Line_Edit_State,
	redo:     [dynamic]Line_Edit_State,
	typing:   bool, // the last change was typing, which the next one joins
}

Field_Drag :: enum {
	None,
	Chars,
	Words,
}

// Text to go back to, with its selection
Line_Edit_State :: struct {
	text:   string, // owned
	caret:  int,
	anchor: int,
}

// How a text field looks. Zero values take the defaults
Field_Look :: struct {
	width:   f32, // of the box; 0 fills the row
	height:  f32, // 0: 32
	size:    u16, // font size; 0: FONT_SIZE_UI
	padding: u16, // left and right; 0: 10
	radius:  f32, // 0: 5
	edge:    clay.Color, // the border; by default the accent while focused
	fit:     bool, // at least as wide as its text, so a Fit parent grows with it
	within:  clay.ElementId, // the scroll area it sits in, if any (see clicked)
}

// What the renderer draws in a text field's box
Field_Draw :: struct {
	text:        string, // or the placeholder, while there is no text
	placeholder: bool,
	lo, hi:      int, // the selection
	caret:       int,
	scroll:      f32,
	size:        u16,
	color:       clay.Color,
	focused:     bool, // draws the caret and the selection
}

// The commands a field takes itself
FIELD_COMMANDS :: bit_set[Command]{.Undo, .Redo, .Select_All, .Copy, .Cut, .Paste}

// Commands that act on the caret or text of the pane behind a field, which
// never reach it while a field has the keys
PANE_EDIT_COMMANDS :: bit_set[Command]{
	.Undo,
	.Redo,
	.Select_All,
	.Copy,
	.Cut,
	.Paste,
	.Add_Cursor_Above,
	.Add_Cursor_Below,
	.Move_Line_Up,
	.Move_Line_Down,
	.Trigger_Completion,
	.Show_Signature_Help,
}

UNDO_LIMIT        :: 100
FIELD_CARET_WIDTH :: 2
DRAG_SCROLL_SPEED :: 8 // per second, times the pointer's distance past the box


// --- The text ----------------------------------------------------------------------

// Replaces the text and selects [select_lo, select_hi); forgets the undo history
line_edit_set :: proc(le: ^Line_Edit, s: string, select_lo, select_hi: int) {
	clear(&le.text)
	append(&le.text, s)
	le.anchor = clamp(select_lo, 0, len(s))
	le.caret = clamp(select_hi, 0, len(s))
	le.scroll = 0
	le.drag = .None
	le.typing = false

	clear_states(&le.undo)
	clear_states(&le.redo)
}


line_edit_clear :: proc(le: ^Line_Edit) {
	line_edit_set(le, "", 0, 0)
}


line_edit_string :: proc(le: ^Line_Edit) -> string {
	return string(le.text[:])
}


line_edit_select_all :: proc(le: ^Line_Edit) {
	le.anchor = 0
	le.caret = len(le.text)
	le.typing = false
}


line_edit_destroy :: proc(le: ^Line_Edit) {
	clear_states(&le.undo)
	clear_states(&le.redo)
	delete(le.undo)
	delete(le.redo)
	delete(le.text)
	le^ = {}
}


// Whether a command may reach the pane behind a field that has the keys
field_lets_through :: proc(cmd: Command) -> bool {
	return cmd not_in PANE_EDIT_COMMANDS
}


@(private = "file")
selection :: proc(le: ^Line_Edit) -> (lo, hi: int) {
	return min(le.caret, le.anchor), max(le.caret, le.anchor)
}


// Replaces the selection, remembering the text before for undo. `typing` joins
// the change to the typing before it
@(private = "file")
replace_selection :: proc(le: ^Line_Edit, s: string, typing := false) {
	lo, hi := selection(le)
	if lo == hi && s == "" {
		return
	}
	remember(le, typing)

	remove_range(&le.text, lo, hi)
	inject_at(&le.text, lo, s)
	le.caret = lo + len(s)
	le.anchor = le.caret
}


// Deletes [lo, hi), remembering the text and selection before for undo.
// Returns whether anything was deleted
@(private = "file")
delete_range :: proc(le: ^Line_Edit, lo, hi: int) -> bool {
	if lo == hi do return false
	remember(le, typing = false)

	remove_range(&le.text, lo, hi)
	le.caret = lo
	le.anchor = lo
	return true
}


// Moves the caret, and the anchor with it unless extending the selection
@(private = "file")
move_caret :: proc(le: ^Line_Edit, to: int, extend: bool) {
	le.caret = to
	if !extend do le.anchor = to
	le.typing = false
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
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
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


// What a double press at i selects: the word there, or the run of spaces or of
// other characters
@(private = "file")
word_at :: proc(s: string, i: int) -> (lo, hi: int) {
	if len(s) == 0 do return 0, 0

	// The character at i, or before it at the end
	at := min(i, prev_rune(s, len(s)))
	r, _ := utf8.decode_rune(s[at:])
	class := rune_class(r)

	lo, hi = at, next_rune(s, at)
	for lo > 0 {
		before, _ := utf8.decode_last_rune(s[:lo])
		if rune_class(before) != class do break
		lo = prev_rune(s, lo)
	}
	for hi < len(s) {
		after, _ := utf8.decode_rune(s[hi:])
		if rune_class(after) != class do break
		hi = next_rune(s, hi)
	}
	return lo, hi
}


@(private = "file")
rune_class :: proc(r: rune) -> int {
	switch {
	case is_word(r):          return 0
	case unicode.is_space(r): return 1
	}
	return 2
}


// --- Undo --------------------------------------------------------------------------

// Before a change: keeps the text to go back to. Typing right after typing is
// the same step
@(private = "file")
remember :: proc(le: ^Line_Edit, typing: bool) {
	joins := typing && le.typing
	le.typing = typing
	if joins do return

	push_state(&le.undo, le)
	clear_states(&le.redo)
}


@(private = "file")
push_state :: proc(states: ^[dynamic]Line_Edit_State, le: ^Line_Edit) {
	if len(states) >= UNDO_LIMIT {
		delete(states[0].text)
		ordered_remove(states, 0)
	}

	state := Line_Edit_State{strings.clone(string(le.text[:])), le.caret, le.anchor}
	append(states, state)
}


@(private = "file")
clear_states :: proc(states: ^[dynamic]Line_Edit_State) {
	for s in states do delete(s.text)
	clear(states)
}


// Goes back to the last state in `from`, keeping the current one in `to`.
// Returns false if there is none
@(private = "file")
restore :: proc(le: ^Line_Edit, from, to: ^[dynamic]Line_Edit_State) -> bool {
	if len(from) == 0 do return false

	push_state(to, le)
	state := pop(from)
	defer delete(state.text)

	clear(&le.text)
	append(&le.text, state.text)
	le.caret = state.caret
	le.anchor = state.anchor
	le.typing = false
	return true
}


// --- Keys --------------------------------------------------------------------------

// Typing, editing keys and the field's commands. Returns whether the event was
// one, and whether the text changed
line_edit_event :: proc(le: ^Line_Edit, event: ^sdl.Event) -> (handled, changed: bool) {
	#partial switch event.type {
	case .TEXT_INPUT:
		replace_selection(le, string(event.text.text), typing = true)
		return true, true

	case .KEY_DOWN:
		if handled, changed = line_edit_key(le, event.key); handled {
			return
		}

		cmd, bound := command_for_key(event.key)
		if bound && cmd in FIELD_COMMANDS {
			return true, line_edit_command(le, cmd)
		}
	}
	return false, false
}


// Runs one of FIELD_COMMANDS on the field. Returns whether the text changed
line_edit_command :: proc(le: ^Line_Edit, cmd: Command) -> (changed: bool) {
	#partial switch cmd {
	case .Select_All:
		line_edit_select_all(le)

	case .Copy, .Cut:
		lo, hi := selection(le)
		if lo == hi do return false

		text := line_edit_copy(le, cut = cmd == .Cut)
		_ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
		return cmd == .Cut

	case .Paste:
		raw := sdl.GetClipboardText()
		if raw == nil do return false
		defer sdl.free(raw)

		return line_edit_paste(le, string(cstring(raw)))

	case .Undo:
		return restore(le, &le.undo, &le.redo)

	case .Redo:
		return restore(le, &le.redo, &le.undo)
	}
	return false
}


// The selected text (temp), removed when cutting
line_edit_copy :: proc(le: ^Line_Edit, cut: bool) -> string {
	lo, hi := selection(le)
	text := strings.clone(string(le.text[lo:hi]), context.temp_allocator)
	if cut do replace_selection(le, "")
	return text
}


// Replaces the selection with `text` on one line: line breaks become spaces.
// Returns whether the text changed
line_edit_paste :: proc(le: ^Line_Edit, text: string) -> bool {
	line, _ := strings.replace_all(text, "\r\n", " ", context.temp_allocator)
	line, _ = strings.replace_all(line, "\n", " ", context.temp_allocator)

	lo, hi := selection(le)
	if line == "" && lo == hi {
		return false
	}
	replace_selection(le, line)
	return true
}


// Caret movement and deletion. Alt combinations are left to the shortcuts
@(private = "file")
line_edit_key :: proc(le: ^Line_Edit, key: sdl.KeyboardEvent) -> (handled, changed: bool) {
	if key.mod & sdl.KMOD_ALT != {} do return false, false

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
			lo = ctrl ? word_step(s, le.caret, -1) : prev_rune(s, le.caret)
		}
		changed = delete_range(le, lo, hi)

	case sdl.K_DELETE:
		if !selected {
			hi = ctrl ? word_step(s, le.caret, +1) : next_rune(s, le.caret)
		}
		changed = delete_range(le, lo, hi)

	case:
		return false, false
	}

	return true, changed
}


// --- The box -----------------------------------------------------------------------

// A one-line text field. While `focused` it takes the mouse (decide focus
// before calling, so the press that focuses it also places the caret) and
// shows the caret and selection; its text scrolls to keep the caret in view.
// With no `le`, it shows `text` and takes nothing. The placeholder shows,
// dimmed, while it is empty
text_field :: proc(
	id: clay.ElementId,
	le: ^Line_Edit,
	placeholder: string,
	focused: bool,
	look: Field_Look = {},
	text := "",
) {
	look := field_look(look)
	focused := focused && le != nil

	// The mouse and the scroll, from last frame's layout
	if le != nil {
		if focused do field_mouse(id, le, look)
		field_scroll(id, le, look, focused)
	}

	edge := look.edge
	if edge == {} {
		edge = focused ? gfx.theme.accent : gfx.theme.border
	}
	box_width := look.width > 0 ? clay.SizingFixed(look.width) : clay.SizingGrow()

	if clay.UI(id)({
		layout = {
			sizing = {box_width, clay.SizingFixed(look.height)},
			padding = {left = look.padding, right = look.padding},
		},
		backgroundColor = gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(look.radius),
		border = {color = edge, width = clay.BorderOutside(1)},
	}) {
		draw := field_draw(le, placeholder, focused, look, text)

		// A fitting field is at least as wide as its text
		content := clay.SizingGrow()
		if look.fit {
			width := field_caret_x(look, draw.text, len(draw.text))
			content = clay.SizingGrow({min = width + FIELD_CARET_WIDTH})
		}

		config := clay.ElementDeclaration{
			layout = {sizing = {content, clay.SizingGrow()}},
			custom = {customData = new_clone(Custom_Data(draw), context.temp_allocator)},
		}
		if clay.UI()(config) {}
	}

	// The I-beam over it (and while selecting in it)
	hovered := ui_interactive() && pointer_in(id)
	scrolled_out := look.within.id != 0 && !pointer_in(look.within)
	selecting := le != nil && le.drag != .None && g.mouse_down
	if (hovered && !scrolled_out) || selecting {
		g.over_text_field = true
	}
}


@(private = "file")
field_look :: proc(look: Field_Look) -> Field_Look {
	look := look
	if look.height == 0 do look.height = 32
	if look.size == 0 do look.size = FONT_SIZE_UI
	if look.padding == 0 do look.padding = 10
	if look.radius == 0 do look.radius = 5
	return look
}


// What the box draws this frame. The strings only have to outlive the frame
@(private = "file")
field_draw :: proc(
	le: ^Line_Edit,
	placeholder: string,
	focused: bool,
	look: Field_Look,
	text: string,
) -> Field_Draw {
	d := Field_Draw{size = look.size, focused = focused, color = gfx.theme.text_bright}

	s := text
	if le != nil {
		s = string(le.text[:])
		d.lo, d.hi = selection(le)
		d.caret = le.caret
		d.scroll = le.scroll
	}
	if !focused do d.color = gfx.theme.text

	d.text = strings.clone(s, context.temp_allocator)
	if s == "" {
		d.text = placeholder
		d.placeholder = true
		d.color = gfx.theme.text_dim
		d.lo, d.hi, d.caret = 0, 0, 0
	}
	return d
}


// The x of a character boundary in the field's text, as drawn
@(private = "file")
field_caret_x :: proc(look: Field_Look, s: string, i: int) -> f32 {
	return gfx.text_caret_x(&gfx.text_system, .Body, look.size, s, i)
}


// Where the text starts and ends in the box (last frame's layout)
@(private = "file")
field_span :: proc(id: clay.ElementId, look: Field_Look) -> (left, right: f32, ok: bool) {
	r := element_rect(id) or_return
	left = r.x + f32(look.padding)
	right = r.x + r.w - f32(look.padding)
	return left, max(right, left), true
}


// The character boundary nearest to x, a window position
@(private = "file")
field_index_at :: proc(le: ^Line_Edit, look: Field_Look, left, x: f32) -> int {
	s := string(le.text[:])
	return gfx.text_caret_at(&gfx.text_system, .Body, look.size, s, x - left + le.scroll)
}


// A press places the caret (Shift extends the selection, a double press
// selects a word, a triple press all); dragging selects, scrolling the text
// while the pointer is past either end
@(private = "file")
field_mouse :: proc(id: clay.ElementId, le: ^Line_Edit, look: Field_Look) {
	left, right, ok := field_span(id, look)
	if !ok do return

	if clicked(id, look.within) {
		field_press(le, field_index_at(le, look, left, g.mouse_pos.x))
		return
	}

	if le.drag == .None do return
	if !g.mouse_down {
		le.drag = .None
		return
	}

	// Past either end, the text scrolls toward the pointer
	x := g.mouse_pos.x
	past := x < left ? x - left : max(x - right, 0)
	if past != 0 {
		le.scroll += past * DRAG_SCROLL_SPEED * g.dt
		le.scroll = clamp(le.scroll, 0, field_max_scroll(le, look, right - left))
		g.animating = true
	}

	at := field_index_at(le, look, left, clamp(x, left, right))
	field_drag_to(le, at)
}


@(private = "file")
field_press :: proc(le: ^Line_Edit, at: int) {
	s := string(le.text[:])
	shift := sdl.GetModState() & sdl.KMOD_SHIFT != {}
	le.typing = false

	switch {
	case g.mouse_clicks >= 3:
		line_edit_select_all(le)
		le.drag = .None

	case g.mouse_clicks == 2:
		le.drag_lo, le.drag_hi = word_at(s, at)
		le.anchor, le.caret = le.drag_lo, le.drag_hi
		le.drag = .Words

	case shift:
		le.caret = at
		le.drag = .Chars

	case:
		le.anchor, le.caret = at, at
		le.drag = .Chars
	}
}


// Extends a drag's selection to `at`; a drag that began on a word extends by words
@(private = "file")
field_drag_to :: proc(le: ^Line_Edit, at: int) {
	if le.drag == .Chars {
		le.caret = at
		return
	}

	s := string(le.text[:])
	lo, hi := word_at(s, at)
	switch {
	case at < le.drag_lo:
		le.anchor, le.caret = le.drag_hi, lo
	case at > le.drag_hi:
		le.anchor, le.caret = le.drag_lo, hi
	case:
		le.anchor, le.caret = le.drag_lo, le.drag_hi
	}
}


// How far the text can scroll: until its end (and the caret after it) shows
@(private = "file")
field_max_scroll :: proc(le: ^Line_Edit, look: Field_Look, inner: f32) -> f32 {
	s := string(le.text[:])
	total := field_caret_x(look, s, len(s)) + FIELD_CARET_WIDTH
	return max(total - inner, 0)
}


// Scrolls the text to keep the caret in view while focused, and never past its end
@(private = "file")
field_scroll :: proc(id: clay.ElementId, le: ^Line_Edit, look: Field_Look, focused: bool) {
	left, right, ok := field_span(id, look)
	if !ok {
		le.scroll = 0
		return
	}

	inner := right - left
	if focused {
		caret_x := field_caret_x(look, string(le.text[:]), le.caret)
		if caret_x + FIELD_CARET_WIDTH - le.scroll > inner {
			le.scroll = caret_x + FIELD_CARET_WIDTH - inner
		}
		if caret_x < le.scroll do le.scroll = caret_x
	}
	le.scroll = clamp(le.scroll, 0, field_max_scroll(le, look, inner))
}


// --- Drawing -----------------------------------------------------------------------

// Draws a text field's contents in its box (pixels): the selection, the text
// and the caret, clipped to the box
draw_text_field :: proc(d: Field_Draw, b: clay.BoundingBox, scale: f32) {
	ts := &gfx.text_system
	font := gfx.text_get_font(ts, .Body, d.size)
	if font == nil do return

	gfx.push_clip_box(b)
	defer gfx.pop_clip()

	// The line, centered in the box
	m := gfx.font_metrics(ts, .Body, d.size)
	height := m.height * scale
	x := math.round(b.x - d.scroll * scale)
	y := math.round(b.y + (b.height - height) / 2)

	if d.focused && d.lo != d.hi {
		lo := gfx.text_caret_x(ts, .Body, d.size, d.text, d.lo) * scale
		hi := gfx.text_caret_x(ts, .Body, d.size, d.text, d.hi) * scale
		r := 2 * scale
		box := clay.BoundingBox{x + lo, y, hi - lo, height}
		gfx.fill_rounded_rect(box, {r, r, r, r}, gfx.theme.selection)
	}

	text := gfx.text_get(ts, font, d.text)
	gfx.draw_text(text, x, y, d.color)

	if d.focused {
		caret := gfx.text_caret_x(ts, .Body, d.size, d.text, d.caret) * scale
		gfx.draw_caret(math.round(x + caret), y, height, scale, gfx.theme.caret)
	}
}
