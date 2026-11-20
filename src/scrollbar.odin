package editor

import "core:math"

import clay "../vendor/clay-odin"
import "gfx"

// Scroll bars: a thumb along the right edge of a scrolling area, or its bottom
// edge for sideways scrolling. Dragging it scrolls; clicking the track jumps
// there. The editor draws its own in draw_editor; Clay scroll containers get
// one from list_scrollbar. The geometry and dragging are gfx's (gfx/scrollbar.odin)


SCROLLBAR_WIDTH     :: 12
SCROLLBAR_MIN_THUMB :: 28

// Right padding a scrolling list leaves for its bar, a little wider than the bar
// so the thumb stays clear of a selected row's outline
SCROLLBAR_GUTTER :: SCROLLBAR_WIDTH + 6


// Track and thumb for `area` scrolled by `scroll` out of `max_scroll` along an
// axis (the content is max_scroll plus the area): the track runs along the
// area's right edge, or its bottom edge sideways. ok = false when nothing scrolls
scrollbar_geometry :: proc(
	area: gfx.Rect,
	axis: gfx.Axis,
	scroll, max_scroll: f64,
) -> (track, thumb: gfx.Rect, ok: bool) {
	page := f64(axis == .Vertical ? area.h : area.w)

	track = {area.x + area.w - SCROLLBAR_WIDTH, area.y, SCROLLBAR_WIDTH, area.h}
	if axis == .Horizontal {
		track = {area.x, area.y + area.h - SCROLLBAR_WIDTH, area.w, SCROLLBAR_WIDTH}
	}

	thumb, ok = gfx.scrollbar_thumb(track, axis, scroll, max_scroll, page, SCROLLBAR_MIN_THUMB)
	return track, thumb, ok
}


// Pressing and dragging a bar with the app's pointer. `drag` holds the grab
// offset within the thumb while dragging. Returns the scroll position to show
// while it owns the mouse
scrollbar_mouse :: proc(
	drag: ^Maybe(f32),
	track, thumb: gfx.Rect,
	axis: gfx.Axis,
	max_scroll: f64,
) -> (scroll: f64, active: bool) {
	pointer := gfx.Pointer_State{g.mouse_pos, g.mouse_pressed, g.mouse_down}
	return gfx.scrollbar_drag(drag, track, thumb, track, axis, max_scroll, pointer)
}


// A scroll bar over the right edge of a Clay scroll container, which should
// leave SCROLLBAR_GUTTER of padding there for it. Declare it after the
// container; `drag` is kept per container. Works from last frame's layout
list_scrollbar :: proc(list: clay.ElementId, drag: ^Maybe(f32)) {
	wheel_scroll_list(list)

	data := clay.GetScrollContainerData(list)
	area, ok := element_rect(list)
	if !data.found || !ok {
		return
	}

	max_scroll := f64(data.contentDimensions.height - data.scrollContainerDimensions.height)
	scroll := f64(-data.scrollPosition.y)
	track, thumb, scrolls := scrollbar_geometry(area, .Vertical, scroll, max_scroll)
	if !scrolls {
		drag^ = nil
		return
	}

	// Dragging
	interactive := ui_interactive()
	if interactive {
		if to, active := scrollbar_mouse(drag, track, thumb, .Vertical, max_scroll); active {
			data.scrollPosition.y = -f32(to)
			_, thumb, _ = scrollbar_geometry(area, .Vertical, to, max_scroll)
		}
	}

	// The thumb
	hovered := interactive && gfx.rect_contains(track, g.mouse_pos)
	r, color := gfx.scrollbar_thumb_look(thumb, .Vertical, drag^ != nil || hovered)
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}},
		backgroundColor = color,
		cornerRadius = clay.CornerRadiusAll(r.w / 2),
		floating = {
			attachTo = .ElementWithId,
			parentId = list.id,
			offset = {r.x - area.x, r.y - area.y},
			zIndex = 110, // above popups (100), below the context menu (120) and dialog (150)
			pointerCaptureMode = .Passthrough,
		},
	}) {}
}


// --- Wheel scrolling ---------------------------------------------------------------

// The wheel scrolls the list under the pointer, out of the Clay scroll containers
// declared with wheel_scroll_list. Clay's own wheel handling isn't used: it gives
// the wheel to any clipping element under the pointer, such as a horizontally
// clipped input box in a list, which then drops vertical scrolling. With smooth
// scrolling on, the list eases to where the wheel takes it, like the editor

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
	lists:    [MAX_WHEEL_LISTS]u32, // declared this frame
	n_lists:  int,
	moving:   [MAX_WHEEL_LISTS]Smooth_Scroll,
	n_moving: int,
}


// Lets the wheel scroll a Clay scroll container; call while declaring it
wheel_scroll_list :: proc(id: clay.ElementId) {
	for x in smooth.lists[:smooth.n_lists] {
		if x == id.id do return
	}

	if smooth.n_lists < MAX_WHEEL_LISTS {
		smooth.lists[smooth.n_lists] = id.id
		smooth.n_lists += 1
	}
}


// Whether a list is still easing toward its target
smooth_scrolling :: proc() -> bool {
	return smooth.n_moving > 0
}


@(private = "file")
scroll_data :: proc(id: u32) -> clay.ScrollContainerData {
	return clay.GetScrollContainerData(clay.ElementId{id = id})
}


// Applies the wheel to Clay's scroll containers (in place of
// clay.UpdateScrollContainers) and moves easing lists along
update_scroll_containers :: proc() {
	lists := smooth.lists
	n := smooth.n_lists
	smooth.n_lists = 0

	// Something else moving a list (its scroll bar, keyboard focus) ends its easing
	for i := 0; i < smooth.n_moving; {
		m := smooth.moving[i]
		data := scroll_data(m.id)
		if !data.found || data.scrollPosition.y != m.shown {
			smooth.n_moving -= 1
			smooth.moving[i] = smooth.moving[smooth.n_moving]
		} else {
			i += 1
		}
	}

	// The wheel. Of the lists under the pointer, the last declared is the one on top
	target: u32
	before: f32
	if g.wheel != {} {
		for i := n - 1; i >= 0; i -= 1 {
			if !clay.PointerOver({id = lists[i]}) do continue

			if data := scroll_data(lists[i]); data.found {
				target, before = lists[i], data.scrollPosition.y
				step := g.wheel * WHEEL_STEP
				if data.config.vertical do data.scrollPosition.y += step.y
				if data.config.horizontal do data.scrollPosition.x += step.x
			}
			break
		}
	}

	// Keeps every container's position within its content
	clay.UpdateScrollContainers(false, {}, g.dt)
	if !g.settings.smooth_scroll {
		smooth.n_moving = 0
		return
	}

	// With smooth scrolling, the list the wheel moved goes back and eases there
	if data := scroll_data(target); target != 0 && data.found && data.scrollPosition.y != before {
		m: ^Smooth_Scroll
		for &x in smooth.moving[:smooth.n_moving] {
			if x.id == target do m = &x
		}
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

	// Ease the lists along
	t := 1 - math.exp(-f32(clamp(g.dt, 0, 1.0 / 30)) * SCROLL_EASE)
	for i := 0; i < smooth.n_moving; {
		m := &smooth.moving[i]
		data := scroll_data(m.id)

		// UpdateScrollContainers drops a list that wasn't declared last frame
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
