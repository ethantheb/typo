package gfx

import clay "../../vendor/clay-odin"

// Scroll bars along either axis: the thumb's place in its track, dragging it,
// and how it looks. The app's bars and rendered code blocks' share these


Axis :: enum u8 {
	Vertical,
	Horizontal,
}

// The pointer, as a scroll bar sees it
Pointer_State :: struct {
	pos:     [2]f32,
	pressed: bool, // went down this frame
	down:    bool,
}


// The start and length of a rect along an axis
@(private = "file")
span :: proc(r: Rect, axis: Axis) -> (start, length: f32) {
	if axis == .Vertical do return r.y, r.h
	return r.x, r.w
}


// The thumb in `track` for a view `page` long, scrolled by `scroll` out of
// `max_scroll` (the content is max_scroll plus a page), at least min_len long.
// ok = false when nothing scrolls
scrollbar_thumb :: proc(
	track: Rect,
	axis: Axis,
	scroll, max_scroll, page: f64,
	min_len: f32,
) -> (thumb: Rect, ok: bool) {
	start, length := span(track, axis)
	if max_scroll <= 0 || length <= 0 || page <= 0 {
		return
	}

	// As long as the share of the content that shows
	content := max_scroll + page
	thumb_len := max(f32(f64(length) * page / content), min(min_len, length))
	at := start + f32(clamp(scroll / max_scroll, 0, 1)) * (length - thumb_len)

	thumb = track
	if axis == .Vertical {
		thumb.y, thumb.h = at, thumb_len
	} else {
		thumb.x, thumb.w = at, thumb_len
	}
	return thumb, true
}


// Pressing and dragging a bar. A press in `grab_area` (the track, or more
// around a thin one) starts a drag that holds the place in the thumb it took,
// or the thumb's middle when the press was beside it. `drag` holds that place
// while dragging. Returns the scroll position while the bar owns the pointer
scrollbar_drag :: proc(
	drag: ^Maybe(f32),
	track, thumb, grab_area: Rect,
	axis: Axis,
	max_scroll: f64,
	pointer: Pointer_State,
) -> (scroll: f64, active: bool) {
	at := axis == .Vertical ? pointer.pos.y : pointer.pos.x
	thumb_start, thumb_len := span(thumb, axis)

	// A press: on the thumb it holds on there, beside it it centres the thumb
	if pointer.pressed && rect_contains(grab_area, pointer.pos) {
		on_thumb := at >= thumb_start && at < thumb_start + thumb_len
		drag^ = on_thumb ? at - thumb_start : thumb_len / 2
	}

	grab, dragging := drag.?
	if !dragging do return
	if !pointer.down {
		drag^ = nil
		return
	}

	// Where the thumb is dragged, as a share of the room it moves in
	track_start, track_len := span(track, axis)
	frac: f32
	room := track_len - thumb_len
	if room > 0 {
		frac = clamp((at - grab - track_start) / room, 0, 1)
	}
	return f64(frac) * max_scroll, true
}


// The thumb as drawn: inset in its track, stronger while hovered or dragged
scrollbar_thumb_look :: proc(
	thumb: Rect,
	axis: Axis,
	active: bool,
) -> (r: Rect, color: clay.Color) {
	color = theme.text_dim
	color.a = active ? 150 : 70

	across: f32 = active ? 2 : 3
	if axis == .Vertical {
		return {thumb.x + across, thumb.y + 2, thumb.w - across * 2, thumb.h - 4}, color
	}
	return {thumb.x + 2, thumb.y + across, thumb.w - 4, thumb.h - across * 2}, color
}
