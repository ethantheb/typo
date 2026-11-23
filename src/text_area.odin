package editor

import "core:math"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "buffer"
import "gfx"
import "textedit"

// A text field of several lines (the Git pane's commit message): a
// textedit.View in the interface font, with its own kind (AREA_KIND), so caret
// movement, selections, words, undo and the clipboard are the editor's. It
// grows with its lines up to a limit, then scrolls; a line wider than the box
// scrolls sideways to keep the caret in view. Its owner decides focus (before
// calling text_area, so the press that focuses it places the caret) and takes
// the keys it wants first (Esc, Ctrl+Enter); text_area_event does the rest


Text_Area :: struct {
	using tv:    textedit.View,
	focused:     bool,   // has the keys: draws the caret and the selection (set per frame)
	placeholder: string, // shown dimmed while empty (set per frame; not owned)
	dragging:    bool,
	drag_from:   int,    // where the press was, for word and line drags
	drag_mode:   enum {
		Char,
		Word,
		Line,
	},
}

// How a text area looks
TEXT_AREA_SIZE      :: FONT_SIZE_UI
TEXT_AREA_PADDING   :: 8 // above and below the text (beside it: area_inset_x)
TEXT_AREA_MIN_LINES :: 3
TEXT_AREA_MAX_LINES :: 10

AREA_KIND := textedit.Kind {
	frame_begin = area_frame_nothing,
	frame_end   = area_frame_nothing,
	draw        = draw_area,
	offset_at   = area_offset_at,
	over_text   = area_over_text,
	max_scroll  = area_max_scroll,
	scroll_step = area_scroll_step,
	reveal      = area_reveal,
	same_row    = area_same_row,
	move        = area_move,
	page_height = area_page_height,
	edit_key    = area_edit_key,
	text_input  = area_text_input,
}


text_area_init :: proc(ta: ^Text_Area) {
	buffer.buffer_init(&ta.buf, nil)
	append(&ta.sels, Selection{0, 0, -1})
	ta.kind = &AREA_KIND
}


text_area_destroy :: proc(ta: ^Text_Area) {
	buffer.buffer_destroy(&ta.buf)
	delete(ta.sels)
	ta^ = {}
}


// The text (temp)
text_area_string :: proc(ta: ^Text_Area) -> string {
	return string(buffer.read_alloc(&ta.buf, 0, buffer.length(&ta.buf)))
}


// Empties it; undo can bring the text back
text_area_clear :: proc(ta: ^Text_Area) {
	textedit.select_all(ta)
	textedit.apply(ta, .Other, textedit.selection_ranges(ta), {""})
	ta.scroll_x, ta.target_x = 0, 0
	textedit.scroll_to(ta, 0)
}


// A row's height
text_area_line_height :: proc() -> f32 {
	m := gfx.font_metrics(&gfx.text_system, .Body, TEXT_AREA_SIZE)
	return math.round(m.height * 1.3)
}


// The box's height for its lines, within its limits
text_area_height :: proc(ta: ^Text_Area) -> f32 {
	lines := clamp(buffer.line_count(&ta.buf), TEXT_AREA_MIN_LINES, TEXT_AREA_MAX_LINES)
	return f32(lines) * text_area_line_height() + 2 * TEXT_AREA_PADDING
}


// The text's inset from the box's sides: as far as its capitals are from the
// box's top (the padding, half the row's extra height and the font's own space
// above its capitals), so the gaps beside and above the text look the same
@(private = "file")
area_inset_x :: proc() -> f32 {
	m := gfx.font_metrics(&gfx.text_system, .Body, TEXT_AREA_SIZE)
	above := (text_area_line_height() - m.height) / 2 + m.ascent - m.cap_height
	return math.round(TEXT_AREA_PADDING + max(above, 0))
}


// --- Keys --------------------------------------------------------------------------

// Typing, editing keys and the field commands (select all, clipboard, undo).
// Returns whether the event was one
text_area_event :: proc(ta: ^Text_Area, event: ^sdl.Event) -> bool {
	#partial switch event.type {
	case .TEXT_INPUT:
		textedit.insert(ta, string(event.text.text))
		return true

	case .KEY_DOWN:
		cmd, bound := command_for_key(event.key)
		if bound && cmd in FIELD_COMMANDS {
			area_command(ta, cmd)
			return true
		}
		return textedit.key(ta, event.key)
	}
	return false
}


@(private = "file")
area_command :: proc(ta: ^Text_Area, cmd: Command) {
	#partial switch cmd {
	case .Select_All: textedit.select_all(ta)
	case .Undo:       textedit.undo(ta)
	case .Redo:       textedit.redo(ta)
	case .Copy, .Cut:
		text := textedit.copy_text(ta, cmd == .Cut)
		_ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	case .Paste:
		raw := sdl.GetClipboardText()
		if raw == nil do return
		defer sdl.free(raw)
		textedit.paste(ta, string(cstring(raw)))
	}
}


// --- The box -----------------------------------------------------------------------

// The text area's box. While `focused` it takes the mouse and shows the caret
text_area :: proc(id: clay.ElementId, ta: ^Text_Area, placeholder: string, focused: bool) {
	ta.focused = focused
	ta.placeholder = placeholder
	textedit.take_changes(ta)

	// The text's place from last frame's layout, then the mouse and the scroll
	inset := area_inset_x()
	if r, ok := element_rect(id); ok {
		pad := f32(TEXT_AREA_PADDING)
		ta.view = {r.x + inset, r.y + pad, max(r.w - 2 * inset, 0), max(r.h - 2 * pad, 0)}
	}
	if focused do area_mouse(id, ta)
	if ta.reveal {
		area_reveal(ta)
		ta.reveal = false
	}
	ta.scroll_y = clamp(ta.target_y, 0, area_max_scroll(ta))
	ta.target_y = ta.scroll_y

	edge := focused ? gfx.theme.accent : gfx.theme.border
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(text_area_height(ta))},
			padding = {
				left = u16(inset),
				right = u16(inset),
				top = TEXT_AREA_PADDING,
				bottom = TEXT_AREA_PADDING,
			},
		},
		backgroundColor = gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = edge, width = clay.BorderOutside(1)},
		transition = transition({.Height, .BorderColor}),
	}) {
		custom_element({}, ta)
	}

	// The I-beam over it (and while selecting in it)
	hovered := ui_interactive() && pointer_in(id)
	if hovered || (ta.dragging && g.mouse_down) {
		g.over_text_field = true
	}
}


// A press places the caret (Shift extends, a double press selects a word, a
// triple press the line); dragging selects; the wheel scrolls
@(private = "file")
area_mouse :: proc(id: clay.ElementId, ta: ^Text_Area) {
	if ui_interactive() && pointer_in(id) && g.wheel.y != 0 {
		ta.target_y -= f64(g.wheel.y) * WHEEL_LINES * f64(text_area_line_height())
	}

	if clicked(id) {
		at := area_offset_at(ta, g.mouse_pos)
		shift := sdl.GetModState() & sdl.KMOD_SHIFT != {}
		ta.dragging = true
		ta.drag_from = at
		ta.drag_mode = .Char

		switch {
		case g.mouse_clicks >= 3:
			lo, hi := textedit.line_span(ta, buffer.offset_to_line(&ta.buf, at))
			textedit.set_single_selection(ta, {lo, hi, -1})
			ta.drag_mode = .Line
		case g.mouse_clicks == 2:
			lo, hi := textedit.word_at(ta, at)
			textedit.set_single_selection(ta, {lo, hi, -1})
			ta.drag_mode = .Word
		case shift:
			s := ta.sels[ta.primary]
			textedit.set_single_selection(ta, {s.anchor, at, -1})
		case:
			textedit.set_single_selection(ta, {at, at, -1})
		}
		ta.reveal = true
		return
	}

	if !ta.dragging do return
	if !g.mouse_down {
		ta.dragging = false
		return
	}

	// Extending the selection, by characters, words or lines
	at := area_offset_at(ta, g.mouse_pos)
	switch ta.drag_mode {
	case .Char:
		ta.sels[ta.primary].head = at
	case .Word, .Line:
		lo, hi := area_unit_at(ta, ta.drag_from)
		at_lo, at_hi := area_unit_at(ta, at)
		if at < lo {
			ta.sels[ta.primary] = {hi, at_lo, -1}
		} else {
			ta.sels[ta.primary] = {lo, max(hi, at_hi), -1}
		}
	}
	textedit.normalize(ta)
	ta.reveal = true
}


// The word or line at an offset, as the drag selects
@(private = "file")
area_unit_at :: proc(ta: ^Text_Area, offset: int) -> (lo, hi: int) {
	if ta.drag_mode == .Word do return textedit.word_at(ta, offset)
	return textedit.line_span(ta, buffer.offset_to_line(&ta.buf, offset))
}


// --- The kind ----------------------------------------------------------------------

@(private = "file")
area_of :: proc(v: ^textedit.View) -> ^Text_Area {
	return container_of(v, Text_Area, "tv")
}


@(private = "file")
area_frame_nothing :: proc(v: ^textedit.View) {}


// The x of byte i of a line's text, from the text's left
@(private = "file")
area_x :: proc(text: string, i: int) -> f32 {
	return gfx.text_caret_x(&gfx.text_system, .Body, TEXT_AREA_SIZE, text, i)
}


@(private = "file")
area_offset_at :: proc(v: ^textedit.View, p: [2]f32) -> int {
	lh := f64(text_area_line_height())
	y := f64(p.y - v.view.y) + v.scroll_y
	line := clamp(int(y / lh), 0, buffer.line_count(&v.buf) - 1)

	text, start := textedit.line_text(v, line)
	x := p.x - v.view.x + v.scroll_x
	return start + gfx.text_caret_at(&gfx.text_system, .Body, TEXT_AREA_SIZE, text, x)
}


@(private = "file")
area_over_text :: proc(v: ^textedit.View, p: [2]f32) -> bool {
	return gfx.rect_contains(v.view, p)
}


@(private = "file")
area_max_scroll :: proc(v: ^textedit.View) -> f64 {
	content := f64(buffer.line_count(&v.buf)) * f64(text_area_line_height())
	return max(content - f64(v.view.h), 0)
}


@(private = "file")
area_scroll_step :: proc(v: ^textedit.View) -> f64 {
	return f64(text_area_line_height())
}


// Scrolls so the primary caret's line and column show
@(private = "file")
area_reveal :: proc(v: ^textedit.View) {
	lh := f64(text_area_line_height())
	head := v.sels[v.primary].head
	line := buffer.offset_to_line(&v.buf, head)

	// Vertically
	top := f64(line) * lh
	if top < v.target_y do v.target_y = top
	if top + lh > v.target_y + f64(v.view.h) {
		v.target_y = top + lh - f64(v.view.h)
	}

	// Sideways, keeping room for the caret
	text, start := textedit.line_text(v, line)
	x := area_x(text, head - start)
	room := max(v.view.w - FIELD_CARET_WIDTH, 0)
	if x < v.scroll_x do v.scroll_x = x
	if x > v.scroll_x + room do v.scroll_x = x - room
	v.target_x = v.scroll_x
}


@(private = "file")
area_same_row :: proc(v: ^textedit.View, a, b: int) -> bool {
	return buffer.offset_to_line(&v.buf, a) == buffer.offset_to_line(&v.buf, b)
}


@(private = "file")
area_page_height :: proc(v: ^textedit.View) -> f64 {
	return max(f64(v.view.h) - f64(text_area_line_height()), f64(text_area_line_height()))
}


// Left and Right by character, Up and Down by row keeping the caret's x (the
// selection's goal, in pixels), Home and End within the line
@(private = "file")
area_move :: proc(v: ^textedit.View, m: textedit.Move, s: Selection) -> (head, col: int) {
	line := buffer.offset_to_line(&v.buf, s.head)
	rows := 0

	#partial switch m {
	case .Left:      return textedit.prev_boundary(v, s.head), -1
	case .Right:     return textedit.next_boundary(v, s.head), -1
	case .Home:      return buffer.line_start(&v.buf, line), -1
	case .End:       return buffer.line_end(&v.buf, line), -1
	case .Up:        rows = -1
	case .Down:      rows = 1
	case .Page_Up:   rows = -page_rows(v)
	case .Page_Down: rows = page_rows(v)
	case:            return s.head, -1
	}

	// The goal x, kept across rows
	goal := s.col
	if goal < 0 {
		text, start := textedit.line_text(v, line)
		goal = int(area_x(text, s.head - start))
	}

	target := line + rows
	if target < 0 do return 0, goal
	if target >= buffer.line_count(&v.buf) do return buffer.length(&v.buf), goal

	text, start := textedit.line_text(v, target)
	at := gfx.text_caret_at(&gfx.text_system, .Body, TEXT_AREA_SIZE, text, f32(goal))
	return start + at, goal
}


@(private = "file")
page_rows :: proc(v: ^textedit.View) -> int {
	return max(int(v.view.h / text_area_line_height()) - 1, 1)
}


@(private = "file")
area_edit_key :: proc(v: ^textedit.View, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}

	switch key.key {
	case sdl.K_BACKSPACE:              textedit.delete_text(v, -1, ctrl)
	case sdl.K_DELETE:                 textedit.delete_text(v, +1, ctrl)
	case sdl.K_RETURN, sdl.K_KP_ENTER: textedit.insert(v, buffer.newline(&v.buf), .Other)
	case:
		return false
	}
	return true
}


@(private = "file")
area_text_input :: proc(v: ^textedit.View, text: string) {
	textedit.insert(v, text)
}


// --- Drawing -----------------------------------------------------------------------

// Draws the lines in view (pixels): selections, the text or the placeholder,
// and the caret while focused
draw_text_area :: proc(ta: ^Text_Area, b: clay.BoundingBox, scale: f32) {
	draw_area(ta, {b.x, b.y, b.width, b.height}, scale, ta.focused)
}


@(private = "file")
draw_area :: proc(v: ^textedit.View, b: gfx.Rect, scale: f32, caret_on: bool) {
	ta := area_of(v)
	ts := &gfx.text_system
	font := gfx.text_get_font(ts, .Body, TEXT_AREA_SIZE)
	if font == nil do return

	gfx.push_clip_box({b.x, b.y, b.w, b.h})
	defer gfx.pop_clip()

	lh := text_area_line_height() * scale
	m := gfx.font_metrics(ts, .Body, TEXT_AREA_SIZE)
	text_dy := math.round((lh - m.height * scale) / 2)
	x0 := b.x - ta.scroll_x * scale

	// The placeholder while empty
	if buffer.length(&ta.buf) == 0 {
		text := gfx.text_get(ts, font, ta.placeholder)
		gfx.draw_text(text, math.round(x0), math.round(b.y + text_dy), gfx.theme.text_faint)
		if caret_on do gfx.draw_caret(math.round(x0), math.round(b.y), lh, scale, gfx.theme.caret)
		return
	}

	// The lines in view
	count := buffer.line_count(&ta.buf)
	first := int(ta.scroll_y / f64(text_area_line_height()))
	last := min(first + int(b.h / lh) + 2, count)
	y0 := b.y - f32(ta.scroll_y) * scale + f32(first) * lh

	for line in first ..< last {
		text, start := textedit.line_text(ta, line)
		end := start + len(text)
		y := math.round(y0 + f32(line - first) * lh)

		// Selections on this line, a little past its end when they continue
		if caret_on {
			for s in ta.sels {
				lo, hi := textedit.sel_lo(s), textedit.sel_hi(s)
				if hi < start || lo > end || lo == hi {
					continue
				}

				x1 := area_x(text, max(lo, start) - start) * scale
				x2 := area_x(text, min(hi, end) - start) * scale
				if hi > end do x2 += math.round(4 * scale)
				r := 2 * scale
				box := clay.BoundingBox{x0 + x1, y, x2 - x1, lh}
				gfx.fill_rounded_rect(box, {r, r, r, r}, gfx.theme.selection)
			}
		}

		if len(text) > 0 {
			t := gfx.text_get(ts, font, text)
			gfx.draw_text(t, math.round(x0), y + text_dy, gfx.theme.text_bright)
		}

		// Carets
		if !caret_on do continue
		for s in ta.sels {
			if s.head < start || s.head > end {
				continue
			}

			x := math.round(x0 + area_x(text, s.head - start) * scale)
			gfx.draw_caret(x, y, lh, scale, gfx.theme.caret)
		}
	}
}
