package editor

import "core:math"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// The window draws its own caption strip: SDL's borderless window (on Windows it
// keeps the caption and sizing styles, so snapping, animations and the system
// menu stay native), with window_frame_windows.odin answering hit tests
CUSTOM_FRAME :: #config(CUSTOM_FRAME, ODIN_OS == .Windows)

TITLE_BAR_HEIGHT :: 32
CAPTION_BUTTON_W :: 46 // Windows 11's caption buttons
CAPTION_GLYPH    :: 10 // the box every caption glyph fills, as Windows 11's
RESTORE_OFFSET   :: 2  // how far the restore glyph's back square sits up and right
CAPTION_RADIUS   :: 5  // a caption button's highlight, as the sidebar's rows
CAPTION_INSET    :: clay.Padding{left = 2, right = 2, top = 4, bottom = 4}
RESIZE_BAND      :: 5  // the edges that resize the window, inside it
RESIZE_CORNER    :: 16 // how far a corner reaches along its two edges

CLOSE_HOVER   :: clay.Color{196, 43, 28, 255} // Windows 11's close button
CLOSE_PRESSED :: clay.Color{181, 43, 30, 255}

Caption_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

// What a point of the window does, as the system hit test asks
Frame_Hit :: enum u8 {
	Client,
	Caption,
	Background, // drags the window as the caption does, with the left button only
	Maximize,   // the system's maximize button: Snap Layouts on Windows 11
	Left,
	Right,
	Top,
	Bottom,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

Window_Frame :: struct {
	on:       bool,                     // the window has no native caption
	strip:    gfx.Rect,                 // as last laid out
	buttons:  [Caption_Button]gfx.Rect, // as last laid out
	controls: [1]gfx.Rect,              // other controls in the strip, as last laid out

	// The maximize button is a non-client area on Windows: its pointer arrives
	// as system messages (window_frame_windows.odin), not SDL events
	max_hover: bool,
	max_down:  bool,

	// The system's move and size loop: while it runs, each new size is drawn
	// at once (window_frame_windows.odin)
	size_move: bool,
	drawing:   bool,
	drawn_at:  u64, // when a new size was last drawn (SDL ticks, ns)

	pending: Caption_Button, // clicked, applied next frame
	border:  clay.Color,     // the border color last given to the system
}

// Named elements whose empty space is the window's background, which drags
// the window. Anonymous boxes and text count as the element they are in
@(private = "file")
BACKGROUND_IDS := [?]string {
	"Clay__RootContainer", // Clay's own, around the layout
	"Root",
	"Main",
	"TitleBar",
	"Sidebar",
	"SidebarFiles",
	"SidebarResults",
	"Recent",
	"RecentList",
	"Shelf",
	"ShelfList",
	"StatusBar",
	"WorkArea",
}

// A caption button's glyph, drawn as shapes (draw_caption_glyph)
Caption_Glyph :: struct {
	button:    Caption_Button,
	maximized: bool, // the maximize button shows Restore
	color:     clay.Color,
}

window_frame: Window_Frame

// How long the size loop's own frames wait after a new size was drawn
@(private = "file")
SIZE_LOOP_REST :: 100 * 1_000_000


// Whether this frame is left out: while the system's size loop runs, each new
// size is drawn at once, and SDL's timer frames between them would only draw
// the same again (each costs a swap chain present at the new size)
window_frame_skips_frame :: proc() -> bool {
	f := &window_frame
	if !f.size_move || f.drawing {
		return false
	}

	return sdl.GetTicksNS() - f.drawn_at < SIZE_LOOP_REST
}


// The window flags for the frame typo draws
window_frame_flags :: proc() -> sdl.WindowFlags {
	return CUSTOM_FRAME ? {.BORDERLESS} : {}
}


// After the window is created, before it is shown. Where typo can't draw its
// frame, the system's comes back
window_frame_init :: proc() {
	if !CUSTOM_FRAME do return

	window_frame.on = frame_platform_init(g.window)
	if !window_frame.on {
		_ = sdl.SetWindowBordered(g.window, true)
	}
}


// The height the caption strip takes at the window's top
frame_top :: proc() -> f32 {
	return window_frame.on ? TITLE_BAR_HEIGHT : 0
}


// Before layout: a caption button clicked last frame acts, and the system's
// border follows the theme
window_frame_frame :: proc() {
	if !window_frame.on do return

	if window_frame.border != gfx.theme.border {
		window_frame.border = gfx.theme.border
		frame_platform_border(gfx.theme.border)
	}

	button := window_frame.pending
	window_frame.pending = .None

	switch button {
	case .None:
	case .Minimize:
		_ = sdl.MinimizeWindow(g.window)
	case .Maximize:
		window_toggle_maximized()
	case .Close:
		event: sdl.Event
		event.type = .QUIT
		_ = sdl.PushEvent(&event)
	}
}


window_toggle_maximized :: proc() {
	if sdl.GetWindowFlags(g.window) & {.MAXIMIZED} != {} {
		_ = sdl.RestoreWindow(g.window)
	} else {
		_ = sdl.MaximizeWindow(g.window)
	}
}


// --- The strip ---------------------------------------------------------------------

// The caption strip across the window's top: the sidebar's header (the folder's
// name, which shows the recent projects) over the sidebar's column, and the minimize,
// maximize and close buttons at the right. The rest drags the window
window_frame_ui :: proc() {
	if !window_frame.on do return

	id := clay.ID("TitleBar")
	window_frame.strip, _ = element_rect(id)

	// Controls in the strip take the pointer rather than dragging the window
	window_frame.controls[0], _ = element_rect(clay.ID("FolderName"))

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(TITLE_BAR_HEIGHT)},
			childAlignment = {y = .Center},
		},
	}) {
		// The strip looks as tall as the space above the panes, which takes the
		// gap below it too: the header is centered there
		if clay.UI()({
			layout = {
				sizing = {clay.SizingFixed(PANE_GAP + SIDEBAR_WIDTH), clay.SizingGrow()},
				padding = {left = PANE_GAP, top = PANE_GAP},
			},
		}) {
			sidebar_header(TITLE_BAR_HEIGHT - PANE_GAP)
		}

		push_right()
		caption_button(.Minimize)
		caption_button(.Maximize)
		caption_button(.Close)
	}
}


// Dimmed while the window doesn't have the keys, as native captions are
@(private = "file")
frame_glyph_color :: proc() -> clay.Color {
	active := sdl.GetWindowFlags(g.window) & {.INPUT_FOCUS} != {}
	return active ? gfx.theme.text : gfx.theme.text_faint
}


@(private = "file")
CAPTION_IDS := [Caption_Button]string {
	.None     = "",
	.Minimize = "CaptionMinimize",
	.Maximize = "CaptionMaximize",
	.Close    = "CaptionClose",
}


// A caption button, square-cornered and as tall as the strip. A press records
// it for next frame (window_frame_frame); the maximize button's pointer comes
// from the system on Windows
@(private = "file")
caption_button :: proc(button: Caption_Button) {
	id := clay.ID(CAPTION_IDS[button])
	rect, _ := element_rect(id)
	window_frame.buttons[button] = rect

	// Hover and press, from SDL's pointer or the system's
	hovered, pressed: bool
	if button == .Maximize && ODIN_OS == .Windows {
		hovered = window_frame.max_hover
		pressed = window_frame.max_down
	} else {
		has_mouse := sdl.GetMouseFocus() == g.window && !window_frame.max_hover
		hovered = has_mouse && gfx.rect_contains(rect, g.mouse_pos)
		pressed = hovered && g.mouse_down
		if hovered && g.mouse_pressed {
			window_frame.pending = button
		}
	}

	// The look
	background: clay.Color
	color := frame_glyph_color()
	switch {
	case button == .Close && pressed:
		background = CLOSE_PRESSED
		color = {255, 255, 255, 255}
	case button == .Close && hovered:
		background = CLOSE_HOVER
		color = {255, 255, 255, 255}
	case pressed:
		background = gfx.theme.selected
	case hovered:
		background = gfx.theme.hover
	}

	// The button takes the pointer over its whole height (the screen's corner,
	// maximized); its highlight is inset and rounded
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(CAPTION_BUTTON_W), clay.SizingGrow()},
			padding = CAPTION_INSET,
		},
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
			backgroundColor = background,
			cornerRadius = clay.CornerRadiusAll(CAPTION_RADIUS),
		}) {
			maximized := sdl.GetWindowFlags(g.window) & {.MAXIMIZED} != {}
			custom_element({}, Caption_Glyph{button, maximized, color})
		}
	}
}


// The glyph centered in its button: Windows 11's shapes, all in one box of
// CAPTION_GLYPH, with strokes in whole device pixels so they stay sharp
draw_caption_glyph :: proc(glyph: Caption_Glyph, b: clay.BoundingBox, scale: f32) {
	stroke := max(math.round(scale), 1)
	size := math.round(CAPTION_GLYPH * scale)
	x := math.round(b.x + (b.width - size) / 2)
	y := math.round(b.y + (b.height - size) / 2)
	c := glyph.color

	switch glyph.button {
	case .None:
	case .Minimize:
		gfx.fill_rect(x, y + math.round((size - stroke) / 2), size, stroke, c)

	case .Maximize:
		if !glyph.maximized {
			outline(x, y, size, size, stroke, c)
			break
		}

		// Restore: a square in front, and the top and right edges of one behind
		back := math.round(RESTORE_OFFSET * scale)
		front := size - back
		outline(x, y + back, front, front, stroke, c)
		gfx.fill_rect(x + back, y, front, stroke, c)
		gfx.fill_rect(x + size - stroke, y, stroke, front, c)

	case .Close:
		gfx.fill_line({x, y}, {x + size, y + size}, stroke, c)
		gfx.fill_line({x + size, y}, {x, y + size}, stroke, c)
	}
}


@(private = "file")
outline :: proc(x, y, w, h, stroke: f32, c: clay.Color) {
	gfx.fill_rect(x, y, w, stroke, c)
	gfx.fill_rect(x, y + h - stroke, w, stroke, c)
	gfx.fill_rect(x, y + stroke, stroke, h - 2 * stroke, c)
	gfx.fill_rect(x + w - stroke, y + stroke, stroke, h - 2 * stroke, c)
}


// --- Hit testing -------------------------------------------------------------------

// What the point does, in the window's coordinates (as the layout's). The edges
// resize unless the window is maximized; the strip drags it, except over its
// buttons and controls, and so does the background elsewhere unless something
// is open that a press there would close
window_frame_hit :: proc(p: [2]f32, size: [2]f32, maximized: bool) -> Frame_Hit {
	// The edges, with corners reaching along both of theirs
	if !maximized {
		left := p.x < RESIZE_BAND
		right := p.x >= size.x - RESIZE_BAND
		top := p.y < RESIZE_BAND
		bottom := p.y >= size.y - RESIZE_BAND

		near_left := p.x < RESIZE_CORNER
		near_right := p.x >= size.x - RESIZE_CORNER
		near_top := p.y < RESIZE_CORNER
		near_bottom := p.y >= size.y - RESIZE_CORNER

		switch {
		case (top && near_left) || (left && near_top):         return .Top_Left
		case (top && near_right) || (right && near_top):       return .Top_Right
		case (bottom && near_left) || (left && near_bottom):   return .Bottom_Left
		case (bottom && near_right) || (right && near_bottom): return .Bottom_Right
		case top:                                              return .Top
		case bottom:                                           return .Bottom
		case left:                                             return .Left
		case right:                                            return .Right
		}
	}

	// The strip, its controls and its buttons
	for r in window_frame.controls {
		if gfx.rect_contains(r, p) do return .Client
	}

	b := &window_frame.buttons
	switch {
	case gfx.rect_contains(b[.Maximize], p):    return .Maximize
	case gfx.rect_contains(b[.Minimize], p):    return .Client
	case gfx.rect_contains(b[.Close], p):       return .Client
	case gfx.rect_contains(window_frame.strip, p): return .Caption
	}

	// The system takes a press on the background to drag, so typo never sees it
	if closes_on_press_outside() do return .Client

	return point_on_background(p) ? .Background : .Client
}


// Something is open that a press anywhere outside it closes or ends (a
// dialog isn't: a press outside it does nothing)
@(private = "file")
closes_on_press_outside :: proc() -> bool {
	return g.menu.open ||
	       g.lsp.popup.open ||
	       g.zoom_popup.open ||
	       g.lsp.completion.open ||
	       g.lsp.rename.open ||
	       g.sidebar_search.open ||
	       g.project_picker.open ||
	       g.finder.open ||
	       g.settings_window.open ||
	       g.goto_line.open ||
	       g.rename.active ||
	       find_has_keys()
}


// Whether the point is on the window's background as last laid out: only
// background elements and anonymous ones are under it, and no pane divider
@(private = "file")
point_on_background :: proc(p: [2]f32) -> bool {
	if divider_at(g.panes.root, p) != nil do return false

	// Clay hit-tests the last layout at the point; the pointer is put back after
	clay.SetPointerState(p, g.mouse_down)
	defer clay.SetPointerState(g.mouse_pos, g.mouse_down)

	ids := clay.GetPointerOverIds()
	for id in ids.internalArray[:ids.length] {
		name := string(id.stringId.chars[:id.stringId.length])
		if name == "" do continue

		is_background := false
		for b in BACKGROUND_IDS {
			if name == b do is_background = true
		}
		if !is_background do return false
	}
	return ids.length > 0
}
