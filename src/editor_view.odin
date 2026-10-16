package editor

import "core:fmt"
import "core:math"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import "syntax"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"

// The text view: one Clay custom element. Per frame, editor_frame updates view
// state from the last layout and handles the mouse and scrolling; draw_editor
// then draws it. Only visible lines are read from the buffer, and only their
// visible columns are shaped, so the cost per frame doesn't grow with file size.

CARET_BLINK_NS :: 530_000_000
TEXT_MARGIN :: 8 // logical pixels between the gutter and the text
SCROLL_EASE :: 18 // higher settles faster; ~150 ms to settle
SCROLLBAR_WIDTH :: 12
SCROLLBAR_MIN_THUMB :: 28

editor_font_size :: proc() -> u16 {
	return u16(g.settings.font_size)
}

// Line numbers are a little smaller than the text they label.
gutter_font_size :: proc() -> u16 {
	return max(editor_font_size(), 10) - 2
}

editor_line_height :: proc() -> int {
	return int(math.round(f32(g.settings.font_size) * 1.35))
}

// Per-frame update before layout: syntax, view metrics, mouse, scrolling.
editor_frame :: proc(e: ^Editor, interactive: bool) {
	if e.status != .Text do return
	syntax.highlighter_update(&e.hl, &e.buf, buffer.take_changes(&e.buf))
	if r, ok := element_rect(clay.ID("EditorText")); ok do e.view = r
	e.char_w = text_char_width(&g.text, .Body, editor_font_size())
	digits := len(fmt.tprintf("%d", buffer.line_count(&e.buf)))
	e.gutter_w = f32(max(digits, 3)) * e.char_w + 28

	if interactive do editor_mouse(e)
	editor_reveal(e)
	editor_animate(e)
}

// The Clay element hosting the text view.
editor_text_element :: proc(e: ^Editor) {
	custom_element(clay.ID("EditorText"), e)
}

// --- Mouse ---------------------------------------------------------------------

// Document offset under a point (logical window coordinates).
offset_at_point :: proc(e: ^Editor, x, y: f32) -> int {
	if f64(y - e.view.y) + e.scroll_y < 0 do return 0
	line := int(f64(y - e.view.y) + e.scroll_y) / editor_line_height()
	line = clamp(line, 0, buffer.line_count(&e.buf) - 1)
	text, start := line_text(e, line)
	col := int((x - e.view.x - e.gutter_w - TEXT_MARGIN + e.scroll_x) / e.char_w + 0.5)
	return start + byte_at_col(text, max(col, 0))
}

// Whether a point is over the text (not the gutter or the scroll bar).
editor_text_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	v := e.view
	return rect_contains({v.x + e.gutter_w, v.y, v.w - e.gutter_w, v.h}, p) && !scrollbar_hit(e, p)
}

@(private = "file")
editor_mouse :: proc(e: ^Editor) {
	inside := rect_contains(e.view, g.mouse_pos)

	// Wheel scrolling eases toward the new position; Shift or a horizontal
	// wheel scrolls sideways.
	if inside && g.wheel != {} {
		dx, dy := g.wheel.x, g.wheel.y
		if sdl.GetModState() & sdl.KMOD_SHIFT != {} do dx, dy = dy, 0
		e.target_y -= f64(dy * 3 * f32(editor_line_height()))
		e.target_x -= dx * 6 * e.char_w
	}

	if scrollbar_mouse(e) {
		clamp_scroll(e)
		return
	}

	if g.mouse_pressed && inside && !scrollbar_hit(e, g.mouse_pos) {
		mods := sdl.GetModState()
		offset := offset_at_point(e, g.mouse_pos.x, g.mouse_pos.y)
		e.blink_t0 = sdl.GetTicksNS()
		e.dragging = true
		e.drag_mode = .Char

		switch {
		case mods & sdl.KMOD_ALT != {}:
			append(&e.sels, Selection{offset, offset, -1})
			e.primary = len(e.sels) - 1
		case mods & sdl.KMOD_SHIFT != {}:
			p := e.sels[e.primary]
			set_single_selection(e, {p.anchor, offset, -1})
		case g.mouse_clicks == 2:
			lo, hi := word_at(e, offset)
			set_single_selection(e, {lo, hi, -1})
			e.drag_mode = .Word
		case g.mouse_clicks >= 3:
			lo, hi := line_span(e, buffer.offset_to_line(&e.buf, offset))
			set_single_selection(e, {lo, hi, -1})
			e.drag_mode = .Line
		case:
			set_single_selection(e, {offset, offset, -1})
		}
		e.drag_origin = e.sels[e.primary]
		normalize(e)
	} else if e.dragging && g.mouse_down {
		// Extend the primary selection; scroll when dragging past the edges.
		v := e.view
		lh := f64(editor_line_height())
		if g.mouse_pos.y < v.y do scroll_to(e, e.scroll_y - lh * 0.5)
		if g.mouse_pos.y > v.y + v.h do scroll_to(e, e.scroll_y + lh * 0.5)
		offset := offset_at_point(e, g.mouse_pos.x, g.mouse_pos.y)
		o := e.drag_origin
		s := &e.sels[e.primary]
		switch e.drag_mode {
		case .Char:
			s^ = {o.anchor, offset, -1}
		case .Word, .Line:
			lo, hi: int
			if e.drag_mode == .Word {
				lo, hi = word_at(e, offset)
			} else {
				lo, hi = line_span(e, buffer.offset_to_line(&e.buf, offset))
			}
			if lo < sel_lo(o) {
				s^ = {sel_hi(o), lo, -1}
			} else {
				s^ = {sel_lo(o), max(hi, sel_hi(o)), -1}
			}
		}
		normalize(e)
	} else if !g.mouse_down {
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
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	lh := f64(editor_line_height())
	top := f64(line) * lh
	ty, tx := e.target_y, e.target_x
	if top < ty do ty = top
	if top + lh > ty + f64(e.view.h) do ty = top + lh - f64(e.view.h)

	text, start := line_text(e, line)
	x := f32(visual_col(text, head - start)) * e.char_w
	text_w := e.view.w - e.gutter_w - TEXT_MARGIN - e.char_w * 2
	if x < tx do tx = max(x - e.char_w * 4, 0)
	if x > tx + text_w do tx = x - text_w

	if ty != e.target_y do scroll_to(e, ty)
	if tx != e.target_x do e.scroll_x, e.target_x = tx, tx
	clamp_scroll(e)
}

// Jumps straight to a vertical position (no easing).
scroll_to :: proc(e: ^Editor, y: f64) {
	e.scroll_y, e.target_y = y, y
}

max_scroll_y :: proc(e: ^Editor) -> f64 {
	return max(f64((buffer.line_count(&e.buf) - 1) * editor_line_height()), 0)
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

// Track and thumb along the text area's right edge; ok = false when everything
// fits and there is nothing to scroll.
@(private = "file")
scrollbar_geometry :: proc(e: ^Editor) -> (track, thumb: Rect, ok: bool) {
	max_y := max_scroll_y(e)
	v := e.view
	if max_y <= 0 || v.h <= 0 do return
	track = {v.x + v.w - SCROLLBAR_WIDTH, v.y, SCROLLBAR_WIDTH, v.h}
	// Content is the document plus one screen (the last line can scroll to the top).
	h := max(v.h * v.h / f32(max_y + f64(v.h)), min(SCROLLBAR_MIN_THUMB, v.h))
	y := v.y + f32(e.scroll_y / max_y) * (v.h - h)
	thumb = {track.x, y, track.w, h}
	return track, thumb, true
}

@(private = "file")
scrollbar_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	track, _, ok := scrollbar_geometry(e)
	return ok && rect_contains(track, p)
}

// Handles pressing and dragging the scroll bar. Returns true while it owns the mouse.
@(private = "file")
scrollbar_mouse :: proc(e: ^Editor) -> bool {
	track, thumb, ok := scrollbar_geometry(e)
	if !ok {
		e.scrollbar_drag = nil
		return false
	}
	if g.mouse_pressed && rect_contains(track, g.mouse_pos) {
		if rect_contains(thumb, g.mouse_pos) {
			e.scrollbar_drag = g.mouse_pos.y - thumb.y
		} else {
			e.scrollbar_drag = thumb.h / 2 // clicking the track centres the thumb there
		}
	}
	grab, dragging := e.scrollbar_drag.?
	if !dragging do return false
	if !g.mouse_down {
		e.scrollbar_drag = nil
		return false
	}
	if span := track.h - thumb.h; span > 0 {
		frac := clamp((g.mouse_pos.y - grab - track.y) / span, 0, 1)
		scroll_to(e, f64(frac) * max_scroll_y(e))
	}
	return true
}

// --- Drawing -------------------------------------------------------------------

draw_editor :: proc(renderer: ^sdl.Renderer, e: ^Editor, b: clay.BoundingBox, scale: f32) {
	if e.status != .Text || e.char_w <= 0 do return
	font := text_get_font(&g.text, .Body, editor_font_size())
	if font == nil do return
	push_clip_box(renderer, b)
	defer pop_clip(renderer)

	adv := e.char_w * scale
	line_height := editor_line_height()
	lh := f32(line_height) * scale
	gutter := math.round(e.gutter_w * scale)
	text_x := b.x + gutter + TEXT_MARGIN * scale - e.scroll_x * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)

	line_count := buffer.line_count(&e.buf)
	first := int(e.scroll_y) / line_height
	y0 := b.y - f32(e.scroll_y - f64(first * line_height)) * scale
	last := min(first + int(b.height / lh) + 2, line_count)

	first_col := int(e.scroll_x / e.char_w)
	col_count := int((b.width - gutter) / adv) + 2

	// Syntax highlights for all visible bytes in one call (capped like the
	// visible text, for enormous lines).
	hl_start := buffer.line_start(&e.buf, first)
	hl_end := last < line_count ? buffer.line_start(&e.buf, last) : buffer.length(&e.buf)
	hl := make([]syntax.Highlight, min(hl_end, hl_start + MAX_LINE_SCAN) - hl_start, context.temp_allocator)
	syntax.highlight_range(&e.hl, &e.buf, hl_start, hl)

	primary := e.sels[e.primary]
	primary_line := buffer.offset_to_line(&e.buf, primary.head)
	caret_on := g.focus == .Editor && ((sdl.GetTicksNS() - e.blink_t0) / CARET_BLINK_NS) % 2 == 0
	caret_w := max(math.round(2 * scale), 1)

	lines := visible_lines(e, first, last, hl_start, hl_end)
	for l, i in lines {
		line := first + i
		y := math.round(y0 + f32(i) * lh)
		end := l.start + len(l.text)
		si := first_selection_at(e, l.start) // selections are sorted

		if line == primary_line && primary.anchor == primary.head {
			fill_rect(renderer, b.x + gutter, y, b.width - gutter, lh, theme.current_line)
		}

		// Selections. One continuing past the line end also covers one extra
		// cell, to show the line break is selected.
		for j := si; j < len(e.sels); j += 1 {
			lo, hi := sel_lo(e.sels[j]), sel_hi(e.sels[j])
			if lo > end do break
			if hi < l.start || lo == hi do continue
			x1 := col_x(l.text, max(lo, l.start) - l.start, text_x, adv)
			x2 := col_x(l.text, min(hi, end) - l.start, text_x, adv)
			if hi > end do x2 += math.round(adv * 0.6)
			fill_rect(renderer, x1, y, x2 - x1, lh, theme.selection)
		}

		lo := clamp(l.start - hl_start, 0, len(hl))
		line_hl := hl[lo:clamp(end - hl_start, lo, len(hl))]
		for run in visible_runs(l.text, line_hl, first_col, col_count) {
			draw_text(text_get(&g.text, font, run.text), math.round(text_x + f32(run.col) * adv), y + text_dy, theme.syntax[run.hl])
		}

		if caret_on {
			for j := si; j < len(e.sels); j += 1 {
				h := e.sels[j].head
				if sel_lo(e.sels[j]) > end do break
				// A caret at a line's end belongs to that line, not the next.
				if h < l.start || h > end do continue
				fill_rect(renderer, col_x(l.text, h - l.start, text_x, adv), y, caret_w, lh, theme.caret)
			}
		}
	}

	draw_scrollbar(renderer, e, scale)

	// Gutter, drawn last so horizontally scrolled text slides under it. Line
	// numbers use a smaller font, baseline-aligned with the text.
	fill_rect(renderer, b.x, b.y, gutter, b.height, theme.gutter)
	num_font := text_get_font(&g.text, .Body, gutter_font_size())
	if num_font == nil do return
	num_dy := text_dy + f32(ttf.GetFontAscent(font) - ttf.GetFontAscent(num_font))
	num_right := b.x + gutter - math.round(16 * scale)
	for line in first ..< last {
		t := text_get(&g.text, num_font, fmt.tprintf("%d", line + 1))
		if t == nil do continue
		w, h: i32
		_ = ttf.GetTextSize(t, &w, &h)
		y := math.round(y0 + f32(line - first) * lh)
		draw_text(t, num_right - f32(w), y + num_dy, line == primary_line ? theme.text_dim : theme.text_faint)
	}
}

@(private = "file")
draw_scrollbar :: proc(renderer: ^sdl.Renderer, e: ^Editor, scale: f32) {
	_, thumb, ok := scrollbar_geometry(e)
	if !ok do return
	active := e.scrollbar_drag != nil || scrollbar_hit(e, g.mouse_pos)
	c := theme.text_dim
	c.a = active ? 150 : 70
	inset: f32 = active ? 2 : 3
	b := clay.BoundingBox{(thumb.x + inset) * scale, (thumb.y + 2) * scale, (thumb.w - inset * 2) * scale, (thumb.h - 4) * scale}
	r := b.width / 2
	fill_rounded_rect(renderer, b, {r, r, r, r}, c)
}

Visible_Line :: struct {
	text:  string, // without the line ending
	start: int,    // document offset
}

// The text of lines [first, last), which span document bytes [lo, hi). Reads
// the range with one buffer read and splits it, or line by line (each capped at
// MAX_LINE_SCAN) when the range is enormous.
@(private = "file")
visible_lines :: proc(e: ^Editor, first, last, lo, hi: int) -> []Visible_Line {
	out := make([]Visible_Line, last - first, context.temp_allocator)
	if hi - lo > MAX_LINE_SCAN {
		for &l, i in out do l.text, l.start = line_text(e, first + i)
		return out
	}
	text := string(buffer.read_alloc(&e.buf, lo, hi))
	pos := 0
	for &l in out {
		nl := strings.index_byte(text[pos:], '\n')
		end := nl < 0 ? len(text) : pos + nl
		line := text[pos:end]
		if nl >= 0 && len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		l = {line, lo + pos}
		pos = min(end + 1, len(text))
	}
	return out
}

@(private = "file")
col_x :: proc(text: string, i: int, text_x, adv: f32) -> f32 {
	return math.round(text_x + f32(visual_col(text, i)) * adv)
}

// Index of the first selection that ends at or after `offset`.
@(private = "file")
first_selection_at :: proc(e: ^Editor, offset: int) -> int {
	lo, hi := 0, len(e.sels)
	for lo < hi {
		mid := (lo + hi) / 2
		if sel_hi(e.sels[mid]) < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

Run :: struct {
	text: string,
	col:  int, // visual column where the run starts
	hl:   syntax.Highlight,
}

// Splits the part of a line covering visual columns [first_col, first_col+count)
// into runs of one highlight, with tabs expanded to spaces. Whitespace joins the
// current run (it draws nothing), so runs break only where the color changes.
// line_hl may be shorter than text (highlight cap); the rest is uncolored. A
// character the font lacks is drawn by a fallback font with its own advance, so
// it gets a run of its own, keeping later columns on the grid.
@(private = "file")
visible_runs :: proc(text: string, line_hl: []syntax.Highlight, first_col, count: int) -> []Run {
	Span :: struct {
		lo, hi: int, // into sb
		col:    int,
		hl:     syntax.Highlight,
	}
	spans := make([dynamic]Span, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	open := false // the last span may be extended
	col := 0
	for r, i in text {
		if col >= first_col + count do break
		next := next_col(col, r)
		defer col = next
		if next <= first_col do continue

		h := i < len(line_hl) ? line_hl[i] : .None
		own := font_has_own_glyph(&g.text, .Body, r)
		space := r == ' ' || r == '\t'
		if !open || !own || (!space && h != spans[len(spans) - 1].hl) {
			append(&spans, Span{len(sb.buf), len(sb.buf), col, h})
		}
		if r == '\t' {
			for _ in col ..< next do strings.write_byte(&sb, ' ')
		} else {
			strings.write_rune(&sb, r)
		}
		spans[len(spans) - 1].hi = len(sb.buf)
		open = own
	}

	runs := make([dynamic]Run, 0, len(spans), context.temp_allocator)
	for span in spans {
		run := string(sb.buf[span.lo:span.hi])
		if len(strings.trim_space(run)) > 0 do append(&runs, Run{run, span.col, span.hl})
	}
	return runs[:]
}
