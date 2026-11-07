package editor

import "core:math"

import clay "../vendor/clay-odin"
import "buffer"
import "markdown"
import "syntax"
import sdl "../vendor/sdl3"
import "gfx"
import "textedit"

// The editor pane: one Clay custom element. Per frame, editor_frame updates the
// view from the last layout and handles the mouse and scrolling; draw_editor
// then draws it. What differs between the plain text view (text_view.odin) and
// the rendered Markdown view goes through the view's kind (textedit.Kind).

CARET_BLINK_NS :: 530_000_000
SCROLL_EASE :: 18 // higher settles faster; ~150 ms to settle
// How long an opened file waits for images in view to load before it is drawn anyway.
EDITOR_SHOW_WAIT :: 500_000_000 // ns

editor_font_size :: proc() -> u16 {
	return u16(g.settings.font_size)
}

// Line numbers are a little smaller than the text they label.
gutter_font_size :: proc() -> u16 {
	return max(editor_font_size(), 10) - 2
}

editor_line_height :: proc() -> int {
	return max(int(math.round(f64(g.settings.font_size) * g.settings.line_height)), 1)
}

// The advance of one column: the font's, plus the letter spacing.
editor_char_width :: proc() -> f32 {
	return max(gfx.text_char_width(&gfx.text_system, .Editor, editor_font_size()) + f32(g.settings.letter_spacing), 1)
}

// Per-frame update before layout: syntax, view metrics, mouse, scrolling.
editor_frame :: proc(e: ^Editor, interactive: bool) {
	if e.status != .Text do return
	textedit.take_changes(e)
	r, placed := element_rect(clay.ID("EditorText"))
	if placed do e.view = r
	e.char_w = editor_char_width()
	e.kind.frame_begin(e)
	if interactive do editor_mouse(e)
	editor_reveal(e)
	editor_animate(e)
	e.kind.frame_end(e)
	if !e.shown do e.shown = (placed && editor_ready(e)) || sdl.GetTicksNS() - e.opened_at > EDITOR_SHOW_WAIT
}

// Whether nothing in view is still loading (images in rendered Markdown).
@(private = "file")
editor_ready :: proc(e: ^Editor) -> bool {
	return e.kind.ready == nil || e.kind.ready(e)
}

// Whether carets are drawn now: in the blink's on phase, and not while a
// selection is being dragged.
editor_caret_on :: proc(e: ^Editor) -> bool {
	if g.focus != .Editor || (e.dragging && g.mouse_down) do return false
	return ((sdl.GetTicksNS() - e.blink_t0) / CARET_BLINK_NS) % 2 == 0
}

// textedit.visible_runs for the editor font.
editor_runs :: proc(text: string, line_hl: []syntax.Highlight, line_style: []markdown.Text_Styles, first_col, count: int) -> []textedit.Run {
	has_glyph :: proc(r: rune) -> bool {
		return gfx.font_has_own_glyph(&gfx.text_system, .Editor, r)
	}
	return textedit.visible_runs(text, line_hl, line_style, first_col, count, g.settings.letter_spacing != 0, has_glyph)
}

// The Clay element hosting the text view.
editor_text_element :: proc(e: ^Editor) {
	custom_element(clay.ID("EditorText"), e)
}

// --- Mouse ---------------------------------------------------------------------

// Whether a point is over the text, where a click places the caret (not the
// gutter or the scroll bar).
editor_text_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	return !scrollbar_hit(e, p) && e.kind.over_text(e, p)
}

@(private = "file")
editor_mouse :: proc(e: ^Editor) {
	k := e.kind
	p := g.mouse_pos
	inside := gfx.rect_contains(e.view, p)

	// Wheel scrolling eases toward the new position; Shift or a horizontal
	// wheel scrolls sideways.
	if inside && g.wheel != {} {
		dx, dy := g.wheel.x, g.wheel.y
		if sdl.GetModState() & sdl.KMOD_SHIFT != {} do dx, dy = dy, 0
		e.target_y -= f64(dy * 3) * k.scroll_step(e)
		if k.wheel_x == nil || !k.wheel_x(e, p, -dx * 6 * e.char_w) do e.target_x -= dx * 6 * e.char_w
	}

	if editor_scrollbar_mouse(e) || (k.capture != nil && k.capture(e)) {
		clamp_scroll(e)
		return
	}

	if g.mouse_pressed && inside && !scrollbar_hit(e, p) {
		mods := sdl.GetModState()
		if k.press != nil && k.press(e, p, mods, g.mouse_clicks) {
			e.dragging = false
			return
		}
		offset := k.offset_at(e, p)
		e.blink_t0 = sdl.GetTicksNS()
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
		textedit.normalize(e)
	} else if e.dragging && g.mouse_down && abs(p.x - e.drag_from.x) + abs(p.y - e.drag_from.y) < 3 {
		// Not dragging yet: the click can reveal syntax, which moves the text
		// under a pointer that hasn't moved.
	} else if e.dragging && g.mouse_down {
		// Extend the primary selection; scroll when dragging past the edges.
		step := k.scroll_step(e)
		if p.y < e.view.y do textedit.scroll_to(e, e.scroll_y - step * 0.5)
		if p.y > e.view.y + e.view.h do textedit.scroll_to(e, e.scroll_y + step * 0.5)
		if k.drag_x != nil do k.drag_x(e, p)
		offset := k.offset_at(e, p)
		o := e.drag_origin
		block := e.drag_mode == .Block
		if (e.drag_mode == .Char || block) && k.drag != nil && k.drag(e, o, offset, block) {
			// The view extended it its own way.
		} else if e.drag_mode == .Char {
			e.sels[e.primary] = {o.anchor, offset, -1}
		} else {
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
		if e.dragging {
			if k.release != nil do k.release(e)
			e.blink_t0 = sdl.GetTicksNS()
		}
		e.dragging = false
	}

	clamp_scroll(e)
}

// --- Scrolling -----------------------------------------------------------------

// Scrolls so the primary caret is visible (after keyboard edits/moves). Works
// on the scroll target: if the target already shows the caret (e.g. Page Down
// is easing there) nothing changes; otherwise the view jumps, so typing and
// arrow keys never wait on an animation.
@(private = "file")
editor_reveal :: proc(e: ^Editor) {
	if !e.reveal || e.view.h <= 0 do return
	e.reveal = false
	e.kind.reveal(e)
	clamp_scroll(e)
}

max_scroll_y :: proc(e: ^Editor) -> f64 {
	return e.kind.max_scroll(e)
}

@(private = "file")
clamp_scroll :: proc(e: ^Editor) {
	max_y := max_scroll_y(e)
	e.target_y = clamp(e.target_y, 0, max_y)
	e.scroll_y = clamp(e.scroll_y, 0, max_y)
	e.target_x = max(e.target_x, 0)
	e.scroll_x = max(e.scroll_x, 0)
}

// Moves the view toward the scroll target: eased (frame-rate independent) with
// smooth scrolling on, in one step with it off.
@(private = "file")
editor_animate :: proc(e: ^Editor) {
	if !g.settings.smooth_scroll {
		e.scroll_y, e.scroll_x = e.target_y, e.target_x
		return
	}
	t := 1 - math.exp(-f64(clamp(g.dt, 0, 1.0 / 30)) * SCROLL_EASE)
	e.scroll_y += (e.target_y - e.scroll_y) * t
	e.scroll_x += f32(f64(e.target_x - e.scroll_x) * t)
	if abs(e.target_y - e.scroll_y) < 0.25 do e.scroll_y = e.target_y
	if abs(e.target_x - e.scroll_x) < 0.25 do e.scroll_x = e.target_x
}

editor_scrolling :: proc(e: ^Editor) -> bool {
	return e.status == .Text && (e.scroll_y != e.target_y || e.scroll_x != e.target_x)
}

// --- Scroll bar ----------------------------------------------------------------

// Track and thumb along the text area's right edge (see scrollbar.odin). The
// last line can scroll to the top, so the content is the document plus one screen.
@(private = "file")
editor_scrollbar :: proc(e: ^Editor) -> (track, thumb: gfx.Rect, ok: bool) {
	return scrollbar_geometry(e.view, e.scroll_y, max_scroll_y(e))
}

@(private = "file")
scrollbar_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	track, _, ok := editor_scrollbar(e)
	return ok && gfx.rect_contains(track, p)
}

// Handles pressing and dragging the scroll bar. Returns true while it owns the mouse.
@(private = "file")
editor_scrollbar_mouse :: proc(e: ^Editor) -> bool {
	track, thumb, ok := editor_scrollbar(e)
	if !ok {
		e.scrollbar_drag = nil
		return false
	}
	scroll, active := scrollbar_mouse(&e.scrollbar_drag, track, thumb, max_scroll_y(e))
	if active do textedit.scroll_to(e, scroll)
	return active
}

// --- Drawing -------------------------------------------------------------------

draw_editor :: proc(e: ^Editor, b: clay.BoundingBox, scale: f32) {
	if e.status != .Text || e.char_w <= 0 || !e.shown do return
	e.kind.draw(e, {b.x, b.y, b.width, b.height}, scale, editor_caret_on(e))
	draw_scrollbar(e, scale)
}

@(private = "file")
draw_scrollbar :: proc(e: ^Editor, scale: f32) {
	_, thumb, ok := editor_scrollbar(e)
	if !ok do return
	r, c := scrollbar_thumb_look(thumb, e.scrollbar_drag != nil || scrollbar_hit(e, g.mouse_pos))
	b := clay.BoundingBox{r.x * scale, r.y * scale, r.w * scale, r.h * scale}
	radius := b.width / 2
	gfx.fill_rounded_rect(b, {radius, radius, radius, radius}, c)
}
