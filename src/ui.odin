package editor

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// Small component layer on top of Clay: labels, buttons, icons, text fields,
// tooltips, modal popups and message boxes


FONT_SIZE_UI          :: 14
FONT_SIZE_SMALL       :: 12
UI_LINE_HEIGHT        :: 20
PARAGRAPH_LINE_HEIGHT :: 17


// An element's bounds from the last layout
element_rect :: proc(id: clay.ElementId) -> (r: gfx.Rect, ok: bool) {
	data := clay.GetElementData(id)
	b := data.boundingBox
	return {b.x, b.y, b.width, b.height}, bool(data.found)
}


// Hit-tests the current mouse position against an element's last layout.
// Unlike clay.Hovered() this sees a click that arrives together with a move
pointer_in :: proc(id: clay.ElementId) -> bool {
	r, ok := element_rect(id)
	return ok && gfx.rect_contains(r, g.mouse_pos)
}


// Whether UI may react to the pointer: a popup's own controls always may
// (g.in_modal is set while they are built), the rest only while no popup covers
// the window. The settings window's option list sits at the side and leaves the
// window usable outside it. The find bar covers what is under it (it can reach
// past a narrow pane)
ui_interactive :: proc() -> bool {
	switch {
	case g.dialog.open, g.menu.open, g.lsp.popup.open: return g.in_popup
	case g.zoom_popup.open:                           return g.in_popup
	case lsp_hover_covers_pointer():                  return g.in_popup
	case lsp_completion_covers_pointer():             return g.in_popup
	case lsp_rename_covers_pointer():                 return g.in_popup
	case g.in_modal:                                  return true
	case g.finder.open:                               return false
	case settings_window_docked():                    return !pointer_in(clay.ID("Settings"))
	case g.settings_window.open:                      return false
	case goto_line_covers_pointer():                  return g.in_goto_bar
	case find_bar_covers_pointer():                   return g.in_find_bar
	}
	return true
}


// The element was clicked this frame. `within` is the scroll area it sits in,
// so rows scrolled out of view don't take clicks
clicked :: proc(id: clay.ElementId, within := clay.ElementId{}) -> bool {
	return g.mouse_pressed &&
	       ui_interactive() &&
	       pointer_in(id) &&
	       (within.id == 0 || pointer_in(within))
}


text_config :: proc(
	color := gfx.theme.text,
	size: u16 = FONT_SIZE_UI,
	font := gfx.Font_Id.Body,
) -> clay.TextElementConfig {
	return {
		textColor = color,
		fontId = u16(font),
		fontSize = size,
		lineHeight = UI_LINE_HEIGHT,
		wrapMode = .None,
	}
}


label :: proc(
	s: string,
	color := gfx.theme.text,
	size: u16 = FONT_SIZE_UI,
	font := gfx.Font_Id.Body,
) {
	clay.TextDynamic(s, text_config(color, size, font))
}


// Small text that wraps at word boundaries to fit its container
paragraph :: proc(s: string, color := gfx.theme.text) {
	config := text_config(color, FONT_SIZE_SMALL)
	config.lineHeight = PARAGRAPH_LINE_HEIGHT
	config.wrapMode = .Words
	clay.TextDynamic(s, config)
}


spacer_x :: proc(width: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(width), clay.SizingFixed(1)}}}) {}
}


// Takes up the free space in a row, pushing what follows to the right
push_right :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
}


// --- Buttons -----------------------------------------------------------------------

// Small text button with hover feedback. Returns true when clicked. `within`
// is the scroll area it sits in, if any
button :: proc(
	id: clay.ElementId,
	s: string,
	tip := "",
	shortcut := "",
	within := clay.ElementId{},
) -> bool {
	if clay.UI(id)({
		layout = {
			padding = {left = 6, right = 6, top = 2, bottom = 2},
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		label(s, clay.Hovered() ? gfx.theme.text_bright : gfx.theme.text_dim, FONT_SIZE_SMALL)
	}

	if tip != "" do tooltip(id, tip, shortcut)
	return clicked(id, within)
}


// Square button showing an icon, brightened on hover
icon_button :: proc(
	id: clay.ElementId,
	kind: gfx.Icon,
	size: f32 = 24,
	icon_size: u16 = 16,
	tip := "",
	shortcut := "",
) -> bool {
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(size), clay.SizingFixed(size)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(size / 4),
	}) {
		icon(kind, clay.Hovered() ? gfx.theme.text : gfx.theme.text_dim, icon_size)
	}

	if tip != "" do tooltip(id, tip, shortcut)
	return clicked(id)
}


// A row of a sidebar list, inset from the list's sides, with a rounded
// highlight while selected or hovered. Use as: if list_row(...) { contents }
@(deferred_none = end_list_row)
list_row :: proc(
	id: clay.ElementId,
	selected: bool,
	height: f32,
	left: u16,
	gap: u16 = 2,
) -> bool {
	// The inset
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 6, right = 6},
		},
	})

	// The row
	clay._OpenElementWithId(id)
	background: clay.Color
	if selected {
		background = gfx.theme.selected
	} else if clay.Hovered() {
		background = gfx.theme.hover
	}
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(height)},
			padding = {left = left, right = 4},
			childGap = gap,
			childAlignment = {y = .Center},
		},
		backgroundColor = background,
		cornerRadius = clay.CornerRadiusAll(5),
	})
	return true
}


@(private = "file")
end_list_row :: proc() {
	clay._CloseElement()
	clay._CloseElement()
}


// --- Icons -------------------------------------------------------------------------

// What a Clay custom element asks the renderer to draw
Custom_Data :: union {
	gfx.Icon_Data,
	^Editor,
	^Terminal,
	Field_Draw,
}


icon :: proc(kind: gfx.Icon, color: clay.Color, size: u16 = 16) {
	custom_element({}, gfx.Icon_Data{kind, color, size}, f32(size))
}


// An element the renderer draws itself (see render_clay_commands): a square of
// `size`, or filling the space available if 0
custom_element :: proc(id: clay.ElementId, data: Custom_Data, size: f32 = 0) {
	sizing := clay.Sizing{clay.SizingGrow(), clay.SizingGrow()}
	if size > 0 {
		sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}
	}

	// The data only has to outlive this frame's render pass
	config := clay.ElementDeclaration{
		layout = {sizing = sizing},
		custom = {customData = new_clone(data, context.temp_allocator)},
	}

	if id.id == 0 {
		if clay.UI()(config) {}
	} else {
		if clay.UI(id)(config) {}
	}
}


// --- Modal popups ------------------------------------------------------------------

// A panel centered over a dimmed window. Use as: if modal(...) { contents }
@(deferred_none = end_modal)
modal :: proc(
	id: clay.ElementId,
	width: f32,
	height: clay.SizingAxis,
	top: u16,
	padding: clay.Padding,
	gap: u16,
) -> bool {
	g.in_modal = true

	// The backdrop
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingFixed(f32(g.window_w)), clay.SizingFixed(f32(g.window_h))},
			childAlignment = {x = .Center},
			padding = {top = top},
		},
		backgroundColor = gfx.theme.backdrop,
		floating = {attachTo = .Root, zIndex = 100},
	})

	// The panel
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingFixed(min(width, f32(g.window_w) - 32)), height},
			layoutDirection = .TopToBottom,
			padding = padding,
			childGap = gap,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	})
	return true
}


// A panel at `r` over a backdrop of the given color. Moving or resizing the
// panel, or changing the backdrop color, animates (see transition). Its children
// are laid out left to right, clipped to the panel as it moves. Size them to
// `r` (fixed, not grow): Clay grows a clipping element's children to their
// content, so a growing page would never fit the panel and its lists would
// never scroll. A `modal` backdrop takes the pointer from the window behind it;
// otherwise the pointer passes through and ui_interactive decides what may react
@(deferred_none = end_modal)
modal_at :: proc(
	id: clay.ElementId,
	r: gfx.Rect,
	backdrop: clay.Color,
	modal: bool,
) -> bool {
	g.in_modal = true

	// The backdrop
	clay._OpenElementWithId(clay.ID("Backdrop", id.id))
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingFixed(f32(g.window_w)), clay.SizingFixed(f32(g.window_h))},
			padding = {left = u16(max(r.x, 0)), top = u16(max(r.y, 0))},
		},
		backgroundColor = backdrop,
		floating = {
			attachTo = .Root,
			zIndex = 100,
			pointerCaptureMode = modal ? .Capture : .Passthrough,
		},
		transition = transition({.BackgroundColor}),
	})

	// The panel
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		clip = {horizontal = true, vertical = true},
		transition = transition(clay.TransitionPropertyBoundingBox),
	})
	return true
}


@(private = "file")
end_modal :: proc() {
	clay._CloseElement()
	clay._CloseElement()
	g.in_modal = false
}


// A click landed outside the popup. Ignored on the frame it opened, when the
// panel has no layout yet and the opening click may still be "pressed"
clicked_outside :: proc(panel: clay.ElementId, opened_frame: u64) -> bool {
	return g.mouse_pressed && opened_frame != g.frame && !pointer_in(panel)
}


// --- Tooltips ----------------------------------------------------------------------

// tooltip() goes right after the element it describes. When the pointer has
// rested on it for TOOLTIP_DELAY the tip appears at the pointer: below it, or
// above when there is no room, and shifted to stay in the window. A click hides
// it until the pointer leaves

TOOLTIP_DELAY :: 500_000_000 // ns

TOOLTIP_PAD_X  :: 8
TOOLTIP_PAD_Y  :: 4
TOOLTIP_GAP    :: 10 // between the text and the shortcut
TOOLTIP_BELOW  :: 20 // from the pointer down to a tip below it, clear of the arrow
TOOLTIP_ABOVE  :: 6  // from the pointer up to a tip above it
TOOLTIP_MARGIN :: 4  // from the window's edges

// Where a tip is laid out on its first frame, before Clay has measured it
TOOLTIP_OUT_OF_SIGHT :: [2]f32{-10_000, -10_000}

Tooltip_State :: struct {
	id:         u32,    // element being hovered, or 0
	since:      u64,    // when hovering it began
	seen:       bool,   // a tooltip() call matched the pointer this frame
	suppressed: bool,   // clicked; stay hidden until the pointer leaves
	shown:      bool,   // the tip is showing, anchored at `at`
	placed:     bool,   // measured by Clay and placed (not out of sight)
	at:         [2]f32, // where the pointer was when it appeared
}


tooltip :: proc(id: clay.ElementId, text: string, shortcut := "") {
	if !ui_interactive() || !pointer_in(id) {
		return
	}

	// Hovered: shown once the delay passed, unless clicked
	t := &g.tooltip
	t.seen = true
	now := sdl.GetTicksNS()
	if t.id != id.id do t^ = {id = id.id, since = now, seen = true}
	if g.mouse_down || g.mouse_pressed {
		t.suppressed = true
	}
	if t.suppressed || now - t.since < TOOLTIP_DELAY {
		return
	}

	// It stays where it appeared. Its first frame lays it out out of sight, so
	// Clay measures it; from then on it is placed by that size
	first := !t.shown
	if first {
		t.shown = true
		t.at = g.mouse_pos
	}

	tip := clay.ID("Tooltip")
	offset := TOOLTIP_OUT_OF_SIGHT
	if size, measured := element_rect(tip); measured && !first {
		offset = tooltip_place(t.at, {size.w, size.h})
		t.placed = true
	}

	if clay.UI(tip)({
		layout = {
			padding = {
				left = TOOLTIP_PAD_X,
				right = TOOLTIP_PAD_X,
				top = TOOLTIP_PAD_Y,
				bottom = TOOLTIP_PAD_Y,
			},
			childGap = TOOLTIP_GAP,
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .Root,
			offset = offset,
			zIndex = 300,
			pointerCaptureMode = .Passthrough,
		},
	}) {
		label(text, gfx.theme.text, FONT_SIZE_SMALL)
		if shortcut != "" do label(shortcut, gfx.theme.text_dim, FONT_SIZE_SMALL)
	}
}


// Where a tip of `size` goes for the pointer at `at`: below it, else above it,
// kept inside the window
@(private = "file")
tooltip_place :: proc(at, size: [2]f32) -> [2]f32 {
	window_w := f32(g.window_w)
	window_h := f32(g.window_h)

	y := at.y + TOOLTIP_BELOW
	if y + size.y > window_h - TOOLTIP_MARGIN {
		y = at.y - TOOLTIP_ABOVE - size.y
	}

	// The far edges it may reach, unless it is wider or taller than the window
	right := max(window_w - size.x - TOOLTIP_MARGIN, TOOLTIP_MARGIN)
	bottom := max(window_h - size.y - TOOLTIP_MARGIN, TOOLTIP_MARGIN)
	return {clamp(at.x, TOOLTIP_MARGIN, right), clamp(y, TOOLTIP_MARGIN, bottom)}
}


tooltip_begin_frame :: proc() {
	g.tooltip.seen = false
}


tooltip_end_frame :: proc() {
	if !g.tooltip.seen do g.tooltip = {}
}


// A tooltip is waiting for its delay to pass, or to be placed once Clay has
// measured it; keep drawing so it can appear
tooltip_pending :: proc() -> bool {
	t := &g.tooltip
	if t.id == 0 || t.suppressed {
		return false
	}

	waiting := sdl.GetTicksNS() - t.since < TOOLTIP_DELAY + 50_000_000
	return waiting || (t.shown && !t.placed)
}


// --- Animation ---------------------------------------------------------------------

// Clay transitions animate an element when its layout changes between frames:
// position, size, colors. Children are laid out within its animated bounds.
// Elements with a transition need a fixed id (not an automatic or loop one).
//
// Exit transitions (exit.setFinalState) aren't used: Clay keeps drawing an
// exiting subtree from the frame it was last declared in, and that frame's
// strings and custom data live in the temp allocator, which is reset. To
// animate something closing, keep declaring it at its closed size until
// element_at says it got there

TRANSITION_SECONDS :: 0.2

// How an element appears (an enter transition):
//   Fade: from its background color. Needs .OverlayColor in the properties, a
//         background, and overlayColor = clear_overlay(background).
//   Clear: from a transparent background. Needs .BackgroundColor.
//   From_Left/From_Right: offset by its own width to that side. Positions are
//         on screen, so this suits elements whose parent stays put.
Enter :: enum {
	None,
	Fade,
	Clear,
	From_Left,
	From_Right,
}


transition :: proc(
	properties: clay.TransitionPropertyFlags,
	enter := Enter.None,
	duration: f32 = TRANSITION_SECONDS,
) -> clay.TransitionElementConfig {
	config := clay.TransitionElementConfig {
		handler    = ease_out,
		duration   = duration,
		properties = properties,
	}

	switch enter {
	case .None:
	case .Fade:       config.enter.setInitialState = enter_fade
	case .Clear:      config.enter.setInitialState = enter_clear
	case .From_Left:  config.enter.setInitialState = enter_from_left
	case .From_Right: config.enter.setInitialState = enter_from_right
	}
	return config
}


// The resting overlay of an element that fades in (Enter.Fade): its background
// color, fully transparent, so only the alpha changes as it fades
clear_overlay :: proc(background: clay.Color) -> clay.Color {
	return {background.r, background.g, background.b, 0}
}


// Whether an element's last layout put it at `r`: an animation toward r is done
element_at :: proc(id: clay.ElementId, r: gfx.Rect) -> bool {
	e, ok := element_rect(id)
	return ok &&
	       abs(e.x - r.x) < 0.5 &&
	       abs(e.y - r.y) < 0.5 &&
	       abs(e.w - r.w) < 0.5 &&
	       abs(e.h - r.h) < 0.5
}


// Clay's ease-out, noting that a transition is still running so the frame loop
// keeps drawing (g.animating, cleared before each clay.EndLayout)
@(private = "file")
ease_out :: proc "c" (args: clay.TransitionCallbackArguments) -> bool {
	done := clay.EaseOut(args)
	if !done do g.animating = true
	return done
}


@(private = "file")
enter_fade :: proc "c" (
	target: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	start := target
	start.overlayColor = target.backgroundColor
	start.overlayColor.a = 255
	return start
}


@(private = "file")
enter_clear :: proc "c" (
	target: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	start := target
	start.backgroundColor.a = 0
	return start
}


@(private = "file")
enter_from_left :: proc "c" (
	target: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	start := target
	start.boundingBox.x -= target.boundingBox.width
	return start
}


@(private = "file")
enter_from_right :: proc "c" (
	target: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	start := target
	start.boundingBox.x += target.boundingBox.width
	return start
}
