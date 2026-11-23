package editor

import "core:math"

import clay "../vendor/clay-odin"
import "buffer"
import "markdown"
import "syntax"
import sdl "../vendor/sdl3"
import "gfx"
import "textedit"

// An editor in its pane: one Clay custom element. Per frame, editor_frame
// updates the view from the last layout and handles the mouse and scrolling;
// draw_editor then draws it. What differs between the plain text view
// (text_view.odin) and the rendered Markdown view goes through the view's kind
// (textedit.Kind)


// Scrolling, shared by every scrolling text: the editor, the diff view, the
// commit message box and lists
SCROLL_EASE   :: 18 // higher settles faster; ~150 ms to settle
WHEEL_LINES   :: 3  // lines a wheel notch scrolls a text
WHEEL_COLUMNS :: 6  // columns a sideways notch scrolls a text

// How long (ns) an opened file waits for images in view to load before it is
// drawn anyway
EDITOR_SHOW_WAIT :: 500_000_000


// The editor and terminal metrics below are for a pane's text at its zoom
// factor (textedit.zoom, textedit.zoom_factor); 1 for unzoomed text


editor_font_size :: proc(zoom: f32) -> u16 {
	size := math.round(f32(g.settings.font_size) * zoom)
	return u16(max(size, 1))
}


// Line numbers are a little smaller than the text they label
gutter_font_size :: proc(zoom: f32) -> u16 {
	return max(editor_font_size(zoom), 10) - 2
}


editor_line_height :: proc(zoom: f32) -> int {
	h := math.round(f64(editor_font_size(zoom)) * g.settings.line_height)
	return max(int(h), 1)
}


// The advance of one column: the font's cell plus the letter spacing, rounded
// to whole device pixels so every column starts on one
editor_char_width :: proc(zoom: f32) -> f32 {
	font_w := gfx.text_char_width(&gfx.text_system, .Editor, editor_font_size(zoom))
	w := font_w + f32(g.settings.letter_spacing) * zoom
	if gfx.scale <= 0 do return max(w, 1)

	return max(math.round(w * gfx.scale), 1) / gfx.scale
}


// Per-frame update before layout: syntax, view metrics, mouse, scrolling.
// `element` is the custom element showing it
editor_frame :: proc(e: ^Editor, element: clay.ElementId, interactive: bool) {
	if e.status != .Text do return

	textedit.take_changes(e)

	r, placed := element_rect(element)
	if placed do e.view = r
	e.char_w = editor_char_width(textedit.zoom(e))

	e.kind.frame_begin(e)
	if interactive do editor_mouse(e)
	editor_reveal(e)
	editor_animate(e)
	e.kind.frame_end(e)

	if !e.shown {
		ready := placed && editor_ready(e)
		e.shown = ready || sdl.GetTicksNS() - e.opened_at > EDITOR_SHOW_WAIT
	}
}


// Whether nothing in view is still loading (images in rendered Markdown)
@(private = "file")
editor_ready :: proc(e: ^Editor) -> bool {
	return e.kind.ready == nil || e.kind.ready(e)
}


// Whether the editor still has work for the coming frames: waiting to be shown,
// highlighting, parsing, scrolling or drag-selecting past an edge
editor_busy :: proc(e: ^Editor) -> bool {
	if e.status != .Text do return false

	return !e.shown ||
	       e.dragging && g.mouse_down ||
	       syntax.highlighter_busy(&e.hl, &e.buf) ||
	       e.md != nil && markdown.doc_busy(e.md) ||
	       editor_scrolling(e) ||
	       editor_scrollbar_dragged(e)
}


// Whether carets are drawn: in the focused editor, except while a selection is
// being dragged (a press shows the caret at once; it hides when the pointer
// moves). They don't blink
editor_caret_on :: proc(e: ^Editor) -> bool {
	return focused_editor() == e && !(e.dragging && e.drag_moved && g.mouse_down)
}


// textedit.visible_runs for the editor font
editor_runs :: proc(
	text: string,
	line_hl: []syntax.Highlight,
	line_style: []markdown.Text_Styles,
	first_col, count: int,
) -> []textedit.Run {
	spaced := g.settings.letter_spacing != 0
	return textedit.visible_runs(
		text,
		line_hl,
		line_style,
		first_col,
		count,
		spaced,
		editor_has_glyph,
	)
}


// Whether a character joins the runs of editor font text: the font has its own
// glyph for it, and it isn't drawn as shapes filling its cell
@(private = "file")
editor_has_glyph :: proc(r: rune) -> bool {
	return !gfx.is_box_glyph(r) && gfx.font_has_own_glyph(&gfx.text_system, .Editor, r)
}


// --- Mouse -------------------------------------------------------------------------

// Whether a point is over the text, where a click places the caret (not the
// gutter or the scroll bar)
editor_text_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	return !scrollbar_hit(e, p) && e.kind.over_text(e, p)
}


@(private = "file")
editor_mouse :: proc(e: ^Editor) {
	k := e.kind
	p := g.mouse_pos
	inside := gfx.rect_contains(e.view, p)

	// Wheel scrolling eases toward the new position; Shift or a horizontal
	// wheel scrolls sideways
	if inside && g.wheel != {} {
		dx, dy := g.wheel.x, g.wheel.y
		if sdl.GetModState() & sdl.KMOD_SHIFT != {} do dx, dy = dy, 0
		e.target_y -= f64(dy * WHEEL_LINES) * k.scroll_step(e)

		step_x := dx * WHEEL_COLUMNS * e.char_w
		if k.wheel_x == nil || !k.wheel_x(e, p, -step_x) {
			e.target_x -= step_x
		}
	}

	if editor_scrollbar_mouse(e) || (k.capture != nil && k.capture(e)) {
		clamp_scroll(e)
		return
	}

	if g.mouse_pressed && inside && !scrollbar_hit(e, p) {
		// A press: the view's own, else a caret or a selection by the click
		// count and modifiers
		mods := sdl.GetModState()
		if k.press != nil && k.press(e, p, mods, g.mouse_clicks) {
			e.dragging = false
			return
		}

		offset := k.offset_at(e, p)
		e.dragging = true
		e.drag_mode = .Char

		switch {
		case mods & sdl.KMOD_ALT != {}:
			append(&e.sels, Selection{offset, offset, -1})
			e.primary = len(e.sels) - 1

		case mods & sdl.KMOD_SHIFT != {}:
			s := e.sels[e.primary]
			textedit.set_single_selection(e, {s.anchor, offset, -1})

		case g.mouse_clicks == 2:
			lo, hi := textedit.word_at(e, offset)
			textedit.set_single_selection(e, {lo, hi, -1})
			e.drag_mode = .Word

		case g.mouse_clicks >= 3:
			lo, hi: int
			block: bool
			if k.block_at != nil do lo, hi, block = k.block_at(e, offset)
			if block {
				e.drag_mode = .Block
			} else {
				lo, hi = textedit.line_span(e, buffer.offset_to_line(&e.buf, offset))
				e.drag_mode = .Line
			}
			textedit.set_single_selection(e, {lo, hi, -1})

		case:
			textedit.set_single_selection(e, {offset, offset, -1})
		}

		e.drag_origin = e.sels[e.primary]
		e.drag_from = p
		e.drag_moved = false
		textedit.normalize(e)
	} else if e.dragging && g.mouse_down && near_press(e, p) {
		// Not dragging yet: the click can reveal syntax, which moves the text
		// under a pointer that hasn't moved
	} else if e.dragging && g.mouse_down {
		// Extend the primary selection; scroll when dragging past the edges
		e.drag_moved = true
		step := k.scroll_step(e)
		if p.y < e.view.y do textedit.scroll_to(e, e.scroll_y - step * 0.5)
		if p.y > e.view.y + e.view.h do textedit.scroll_to(e, e.scroll_y + step * 0.5)
		if k.drag_x != nil do k.drag_x(e, p)

		offset := k.offset_at(e, p)
		o := e.drag_origin
		block := e.drag_mode == .Block

		if (e.drag_mode == .Char || block) && k.drag != nil && k.drag(e, o, offset, block) {
			// The view extended it its own way
		} else if e.drag_mode == .Char {
			e.sels[e.primary] = {o.anchor, offset, -1}
		} else {
			// By words or lines, keeping the ones first selected
			lo, hi: int
			if e.drag_mode == .Word {
				lo, hi = textedit.word_at(e, offset)
			} else {
				lo, hi = textedit.line_span(e, buffer.offset_to_line(&e.buf, offset))
			}

			if lo < textedit.sel_lo(o) {
				e.sels[e.primary] = {textedit.sel_hi(o), lo, -1}
			} else {
				e.sels[e.primary] = {textedit.sel_lo(o), max(hi, textedit.sel_hi(o)), -1}
			}
		}
		textedit.normalize(e)
	} else if !g.mouse_down {
		if e.dragging && k.release != nil {
			k.release(e)
		}
		e.dragging = false
	}

	clamp_scroll(e)
}


// Whether the pointer is still within a few pixels of where the press was
@(private = "file")
near_press :: proc(e: ^Editor, p: [2]f32) -> bool {
	return abs(p.x - e.drag_from.x) + abs(p.y - e.drag_from.y) < 3
}


// --- Scrolling ---------------------------------------------------------------------

// Scrolls so the primary caret is visible (after keyboard edits/moves). Works
// on the scroll target: if the target already shows the caret (e.g. Page Down
// is easing there) nothing changes; otherwise the view jumps, so typing and
// arrow keys never wait on an animation
@(private = "file")
editor_reveal :: proc(e: ^Editor) {
	if !e.reveal || e.view.h <= 0 {
		return
	}

	e.kind.reveal(e)
	e.reveal = false
	e.center = false
	clamp_scroll(e)
}


max_scroll_y :: proc(e: ^Editor) -> f64 {
	return e.kind.max_scroll(e)
}


// How far the view scrolls sideways, and the part of it that does (nothing
// for a kind that doesn't scroll sideways as a whole)
editor_sideways :: proc(e: ^Editor) -> (max_scroll: f32, area: gfx.Rect) {
	if e.kind.sideways == nil do return 0, {}
	return e.kind.sideways(e)
}


@(private = "file")
clamp_scroll :: proc(e: ^Editor) {
	max_y := max_scroll_y(e)
	e.target_y = clamp(e.target_y, 0, max_y)
	e.scroll_y = clamp(e.scroll_y, 0, max_y)

	max_x, _ := editor_sideways(e)
	e.target_x = clamp(e.target_x, 0, max_x)
	e.scroll_x = clamp(e.scroll_x, 0, max_x)
}


// Moves the view toward the scroll target: eased (frame-rate independent) with
// smooth scrolling on, in one step with it off
@(private = "file")
editor_animate :: proc(e: ^Editor) {
	if !g.settings.smooth_scroll {
		e.scroll_y, e.scroll_x = e.target_y, e.target_x
		return
	}

	t := scroll_ease_step()
	e.scroll_y += (e.target_y - e.scroll_y) * t
	e.scroll_x += f32(f64(e.target_x - e.scroll_x) * t)

	// Settle on the target once close
	if abs(e.target_y - e.scroll_y) < 0.25 do e.scroll_y = e.target_y
	if abs(e.target_x - e.scroll_x) < 0.25 do e.scroll_x = e.target_x
}


// The part of the way to its target a scroll eases this frame (independent of
// the frame rate)
scroll_ease_step :: proc() -> f64 {
	return 1 - math.exp(-f64(clamp(g.dt, 0, 1.0 / 30)) * SCROLL_EASE)
}


editor_scrolling :: proc(e: ^Editor) -> bool {
	return e.status == .Text && (e.scroll_y != e.target_y || e.scroll_x != e.target_x)
}


// --- Scroll bar --------------------------------------------------------------------

// Track and thumb of a scroll bar (see scrollbar.odin): along the view's right
// edge, or sideways along the bottom of the part that scrolls sideways. The
// last line can scroll to the top, so the content is the document plus one
// screen. Where both show, the sideways one stops short of the corner
editor_scrollbar :: proc(e: ^Editor, axis: gfx.Axis) -> (track, thumb: gfx.Rect, ok: bool) {
	max_y := max_scroll_y(e)
	max_x, area := editor_sideways(e)

	if axis == .Vertical {
		return scrollbar_geometry(e.view, .Vertical, e.scroll_y, max_y)
	}

	if max_y > 0 do area.w -= SCROLLBAR_WIDTH
	return scrollbar_geometry(area, .Horizontal, f64(e.scroll_x), f64(max_x))
}


@(private = "file")
scrollbar_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	for axis in gfx.Axis {
		track, _, ok := editor_scrollbar(e, axis)
		if ok && gfx.rect_contains(track, p) {
			return true
		}
	}
	return false
}


// Whether a scroll bar is being dragged
editor_scrollbar_dragged :: proc(e: ^Editor) -> bool {
	return e.scrollbar_drag != {}
}


// Handles pressing and dragging the scroll bars. Returns true while one owns
// the mouse
@(private = "file")
editor_scrollbar_mouse :: proc(e: ^Editor) -> bool {
	owned := false
	for axis in gfx.Axis {
		drag := &e.scrollbar_drag[axis]
		track, thumb, ok := editor_scrollbar(e, axis)
		if !ok {
			drag^ = nil
			continue
		}

		max_x, _ := editor_sideways(e)
		max_scroll := axis == .Vertical ? max_scroll_y(e) : f64(max_x)
		scroll, active := scrollbar_mouse(drag, track, thumb, axis, max_scroll)
		if !active do continue

		if axis == .Vertical {
			textedit.scroll_to(e, scroll)
		} else {
			e.scroll_x, e.target_x = f32(scroll), f32(scroll)
		}
		owned = true
	}
	return owned
}


// --- Drawing -----------------------------------------------------------------------

draw_editor :: proc(e: ^Editor, b: clay.BoundingBox, scale: f32) {
	if e.status != .Text || e.char_w <= 0 || !e.shown {
		return
	}

	e.kind.draw(e, {b.x, b.y, b.width, b.height}, scale, editor_caret_on(e))
	draw_scrollbars(e, scale)
}


// The scroll bars' thumbs, each brighter while hovered or dragged
@(private = "file")
draw_scrollbars :: proc(e: ^Editor, scale: f32) {
	for axis in gfx.Axis {
		track, thumb, ok := editor_scrollbar(e, axis)
		if !ok do continue

		hot := e.scrollbar_drag[axis] != nil || gfx.rect_contains(track, g.mouse_pos)
		r, c := gfx.scrollbar_thumb_look(thumb, axis, hot)

		b := clay.BoundingBox{r.x * scale, r.y * scale, r.w * scale, r.h * scale}
		radius := min(b.width, b.height) / 2
		gfx.fill_rounded_rect(b, {radius, radius, radius, radius}, c)
	}
}
