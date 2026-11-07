package editor

import "core:math"

import clay "../vendor/clay-odin"
import "gfx"

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
scrollbar_geometry :: proc(area: gfx.Rect, scroll, max_scroll: f64) -> (track, thumb: gfx.Rect, ok: bool) {
	if max_scroll <= 0 || area.h <= 0 do return
	track = {area.x + area.w - SCROLLBAR_WIDTH, area.y, SCROLLBAR_WIDTH, area.h}
	h := max(area.h * area.h / f32(max_scroll + f64(area.h)), min(SCROLLBAR_MIN_THUMB, area.h))
	y := area.y + f32(clamp(scroll / max_scroll, 0, 1)) * (area.h - h)
	thumb = {track.x, y, track.w, h}
	return track, thumb, true
}

// Pressing and dragging the bar. `drag` holds the grab offset within the thumb
// while dragging. Returns the scroll position to show while it owns the mouse.
scrollbar_mouse :: proc(drag: ^Maybe(f32), track, thumb: gfx.Rect, max_scroll: f64) -> (scroll: f64, active: bool) {
	if g.mouse_pressed && gfx.rect_contains(track, g.mouse_pos) {
		// Clicking the track centres the thumb there.
		drag^ = gfx.rect_contains(thumb, g.mouse_pos) ? g.mouse_pos.y - thumb.y : thumb.h / 2
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
scrollbar_thumb_look :: proc(thumb: gfx.Rect, active: bool) -> (r: gfx.Rect, color: clay.Color) {
	color = gfx.theme.text_dim
	color.a = active ? 150 : 70
	inset: f32 = active ? 2 : 3
	return {thumb.x + inset, thumb.y + 2, thumb.w - inset * 2, thumb.h - 4}, color
}

// A scroll bar over the right edge of a Clay scroll container, which should
// leave SCROLLBAR_GUTTER of padding there for it. Declare it after the
// container; `drag` is kept per container. Works from last frame's layout.
list_scrollbar :: proc(list: clay.ElementId, drag: ^Maybe(f32)) {
	wheel_scroll_list(list)
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
	r, color := scrollbar_thumb_look(thumb, drag^ != nil || (interactive && gfx.rect_contains(track, g.mouse_pos)))
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

// --- Wheel scrolling --------------------------------------------------------------
// The wheel scrolls the list under the pointer, out of the Clay scroll containers
// declared with wheel_scroll_list. Clay's own wheel handling isn't used: it gives
// the wheel to any clipping element under the pointer, such as a horizontally
// clipped input box in a list, which then drops vertical scrolling. With smooth
// scrolling on, the list eases to where the wheel takes it, like the editor.

@(private = "file")
WHEEL_STEP :: 30 // pixels per wheel notch

@(private = "file")
MAX_WHEEL_LISTS :: 16

@(private = "file")
Smooth_Scroll :: struct {
	id:     u32,
	target: f32,
	shown:  f32, // the position last set, to notice when something else moves it
}

@(private = "file")
smooth: struct {
	lists:      [MAX_WHEEL_LISTS]u32, // declared this frame
	n_lists:    int,
	moving:     [MAX_WHEEL_LISTS]Smooth_Scroll,
	n_moving:   int,
}

// Lets the wheel scroll a Clay scroll container; call while declaring it.
wheel_scroll_list :: proc(id: clay.ElementId) {
	for x in smooth.lists[:smooth.n_lists] do if x == id.id do return
	if smooth.n_lists < MAX_WHEEL_LISTS {
		smooth.lists[smooth.n_lists] = id.id
		smooth.n_lists += 1
	}
}

// Whether a list is still easing toward its target.
smooth_scrolling :: proc() -> bool {
	return smooth.n_moving > 0
}

// Applies the wheel to Clay's scroll containers (in place of
// clay.UpdateScrollContainers) and moves easing lists along.
update_scroll_containers :: proc() {
	lists := smooth.lists
	n := smooth.n_lists
	smooth.n_lists = 0
	data_of :: proc(id: u32) -> clay.ScrollContainerData {
		return clay.GetScrollContainerData(clay.ElementId{id = id})
	}

	// Something else moving a list (its scroll bar, keyboard focus) ends its easing.
	for i := 0; i < smooth.n_moving; {
		m := smooth.moving[i]
		data := data_of(m.id)
		if !data.found || data.scrollPosition.y != m.shown {
			smooth.n_moving -= 1
			smooth.moving[i] = smooth.moving[smooth.n_moving]
		} else {
			i += 1
		}
	}

	// Of the lists under the pointer, the last declared is the one on top.
	target: u32
	before: f32
	if g.wheel != {} {
		for i := n - 1; i >= 0; i -= 1 {
			if !clay.PointerOver({id = lists[i]}) do continue
			if data := data_of(lists[i]); data.found {
				target, before = lists[i], data.scrollPosition.y
				step := g.wheel * WHEEL_STEP
				if data.config.vertical do data.scrollPosition.y += step.y
				if data.config.horizontal do data.scrollPosition.x += step.x
			}
			break
		}
	}
	// Keeps every container's position within its content.
	clay.UpdateScrollContainers(false, {}, g.dt)
	if !g.settings.smooth_scroll {
		smooth.n_moving = 0
		return
	}

	if data := data_of(target); target != 0 && data.found && data.scrollPosition.y != before {
		m: ^Smooth_Scroll
		for &x in smooth.moving[:smooth.n_moving] do if x.id == target do m = &x
		if m == nil && smooth.n_moving < MAX_WHEEL_LISTS {
			m = &smooth.moving[smooth.n_moving]
			smooth.n_moving += 1
			m^ = {id = target, target = before}
		}
		if m != nil {
			m.target += data.scrollPosition.y - before
			data.scrollPosition.y = before
			m.shown = before
		}
	}

	t := 1 - math.exp(-f32(clamp(g.dt, 0, 1.0 / 30)) * SCROLL_EASE)
	for i := 0; i < smooth.n_moving; {
		m := &smooth.moving[i]
		data := data_of(m.id)
		// UpdateScrollContainers drops a list that wasn't declared last frame.
		if !data.found {
			smooth.n_moving -= 1
			smooth.moving[i] = smooth.moving[smooth.n_moving]
			continue
		}
		lowest := -max(data.contentDimensions.height - data.scrollContainerDimensions.height, 0)
		m.target = clamp(m.target, lowest, 0)
		y := data.scrollPosition.y + (m.target - data.scrollPosition.y) * t
		done := abs(m.target - y) < 0.5
		if done do y = m.target
		data.scrollPosition.y = y
		m.shown = y
		if done {
			smooth.n_moving -= 1
			smooth.moving[i] = smooth.moving[smooth.n_moving]
		} else {
			i += 1
		}
	}
}
