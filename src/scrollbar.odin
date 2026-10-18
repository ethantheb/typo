package editor

import clay "../vendor/clay-odin"

// Scroll bars: a thumb along the right edge of a scrolling area. Dragging it
// scrolls; clicking the track jumps there. The editor draws its own in
// draw_editor; Clay scroll containers get one from list_scrollbar.

SCROLLBAR_WIDTH :: 12
SCROLLBAR_MIN_THUMB :: 28
// Right padding a scrolling list leaves for its bar, a little wider than the bar
// so the thumb stays clear of a selected row's outline.
SCROLLBAR_GUTTER :: SCROLLBAR_WIDTH + 6

// Track and thumb for `area` scrolled down by `scroll` out of `max_scroll`
// (the content is max_scroll plus one area). ok = false when nothing scrolls.
scrollbar_geometry :: proc(area: Rect, scroll, max_scroll: f64) -> (track, thumb: Rect, ok: bool) {
	if max_scroll <= 0 || area.h <= 0 do return
	track = {area.x + area.w - SCROLLBAR_WIDTH, area.y, SCROLLBAR_WIDTH, area.h}
	h := max(area.h * area.h / f32(max_scroll + f64(area.h)), min(SCROLLBAR_MIN_THUMB, area.h))
	y := area.y + f32(clamp(scroll / max_scroll, 0, 1)) * (area.h - h)
	thumb = {track.x, y, track.w, h}
	return track, thumb, true
}

// Pressing and dragging the bar. `drag` holds the grab offset within the thumb
// while dragging. Returns the scroll position to show while it owns the mouse.
scrollbar_mouse :: proc(drag: ^Maybe(f32), track, thumb: Rect, max_scroll: f64) -> (scroll: f64, active: bool) {
	if g.mouse_pressed && rect_contains(track, g.mouse_pos) {
		// Clicking the track centres the thumb there.
		drag^ = rect_contains(thumb, g.mouse_pos) ? g.mouse_pos.y - thumb.y : thumb.h / 2
	}
	grab, dragging := drag.?
	if !dragging do return
	if !g.mouse_down {
		drag^ = nil
		return
	}
	frac: f32
	if span := track.h - thumb.h; span > 0 do frac = clamp((g.mouse_pos.y - grab - track.y) / span, 0, 1)
	return f64(frac) * max_scroll, true
}

// The thumb as drawn: inset in its track, stronger while hovered or dragged.
scrollbar_thumb_look :: proc(thumb: Rect, active: bool) -> (r: Rect, color: clay.Color) {
	color = theme.text_dim
	color.a = active ? 150 : 70
	inset: f32 = active ? 2 : 3
	return {thumb.x + inset, thumb.y + 2, thumb.w - inset * 2, thumb.h - 4}, color
}

// A scroll bar over the right edge of a Clay scroll container, which should
// leave SCROLLBAR_GUTTER of padding there for it. Declare it after the
// container; `drag` is kept per container. Works from last frame's layout.
list_scrollbar :: proc(list: clay.ElementId, drag: ^Maybe(f32)) {
	data := clay.GetScrollContainerData(list)
	area, ok := element_rect(list)
	if !data.found || !ok do return
	max_scroll := f64(data.contentDimensions.height - data.scrollContainerDimensions.height)
	track, thumb, scrolls := scrollbar_geometry(area, f64(-data.scrollPosition.y), max_scroll)
	if !scrolls {
		drag^ = nil
		return
	}
	interactive := ui_interactive()
	if interactive {
		if scroll, active := scrollbar_mouse(drag, track, thumb, max_scroll); active {
			data.scrollPosition.y = -f32(scroll)
			_, thumb, _ = scrollbar_geometry(area, scroll, max_scroll)
		}
	}
	r, color := scrollbar_thumb_look(thumb, drag^ != nil || (interactive && rect_contains(track, g.mouse_pos)))
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}},
		backgroundColor = color,
		cornerRadius = clay.CornerRadiusAll(r.w / 2),
		floating = {
			attachTo = .ElementWithId,
			parentId = list.id,
			offset = {r.x - area.x, r.y - area.y},
			zIndex = 200, // above popups (100), below tooltips (300)
			pointerCaptureMode = .Passthrough,
		},
	}) {}
}
