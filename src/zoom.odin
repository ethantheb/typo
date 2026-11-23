package editor

import "core:fmt"

import clay "../vendor/clay-odin"
import "gfx"
import "textedit"

// Zoom: each pane's text has its own size, a step of textedit.ZOOM_LEVELS
// applied to the font sizes set. Zoom in, Zoom out and Reset zoom act on the
// focused pane, from their keys or from the status bar's zoom item, whose
// popup has zoom out, the zoom (a click resets it) and zoom in. Only the
// pane's text zooms; the interface keeps its size


Zoom_Popup :: struct {
	open:   bool,
	opened: u64,            // frame
	action: Maybe(Command), // a button's, run at the start of the next frame
}

@(private = "file")
ZOOM_POPUP_BUTTON :: 22


// The pane's zoom step; ok is false when it has no text to zoom
pane_zoom :: proc(p: ^Pane) -> (step: int, ok: bool) {
	if p == nil do return

	switch c in p.content {
	case ^Editor:    return c.zoom, c.status == .Text
	case ^Terminal:  return c.zoom, true
	case ^Diff_View: return c.zoom, true
	case ^Git_View:
	}
	return
}


// Zooms a pane's text to a step. An editor keeps its caret's line where it is
// on screen; a terminal's grid resizes to its new cells; a diff keeps its top
// row
pane_set_zoom :: proc(p: ^Pane, step: int) {
	switch c in p.content {
	case ^Editor:
		if c.status == .Text do textedit.set_zoom(c, step)
	case ^Terminal:
		c.zoom = textedit.clamp_zoom(step)
	case ^Diff_View:
		diff_view_set_zoom(c, step)
	case ^Git_View:
	}
}


// Sets the zoom of a pane not drawn yet, which has nothing to keep in place
pane_init_zoom :: proc(p: ^Pane, step: int) {
	switch c in p.content {
	case ^Editor:    c.zoom = textedit.clamp_zoom(step)
	case ^Terminal:  c.zoom = textedit.clamp_zoom(step)
	case ^Diff_View: c.zoom = textedit.clamp_zoom(step)
	case ^Git_View:
	}
}


// Zoom in, Zoom out or Reset zoom on the focused pane. Returns false if it
// can't zoom
zoom_run_command :: proc(cmd: Command) -> bool {
	p := g.panes.focused
	step, ok := pane_zoom(p)
	if !ok do return false

	#partial switch cmd {
	case .Zoom_In:    pane_set_zoom(p, step + 1)
	case .Zoom_Out:   pane_set_zoom(p, step - 1)
	case .Reset_Zoom: pane_set_zoom(p, 0)
	}
	return true
}


// --- Status bar and popup ------------------------------------------------------------

// Before the panes' frames: runs a button's command, and closes the popup on a
// press outside it (which does nothing else) or when the focused pane can't
// zoom
zoom_popup_frame :: proc() {
	popup := &g.zoom_popup

	if cmd, ok := popup.action.?; ok {
		popup.action = nil
		zoom_run_command(cmd)
	}

	if !popup.open do return

	if _, ok := pane_zoom(g.panes.focused); !ok {
		popup.open = false
		return
	}
	if clicked_outside(clay.ID("ZoomPopup"), popup.opened) {
		popup.open = false
		g.mouse_pressed = false
	}
}


zoom_popup_close :: proc() {
	g.zoom_popup.open = false
}


// The focused pane's zoom, at the right of the status bar; a click opens the
// popup. Not shown when the pane can't zoom
zoom_status_item :: proc() {
	step, ok := pane_zoom(g.panes.focused)
	if !ok do return

	popup := &g.zoom_popup
	id := clay.ID("ZoomStatus")
	if clay.UI(id)({
		layout = {
			padding = {left = 6, right = 6, top = 1, bottom = 1},
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() || popup.open ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		label(zoom_label(step), gfx.theme.text_dim, FONT_SIZE_SMALL)
	}

	if !popup.open do tooltip(id, "Zoom this pane")
	if clicked(id) {
		popup.open = true
		popup.opened = g.frame
	}
}


// "125%"
@(private = "file")
zoom_label :: proc(step: int) -> string {
	return fmt.tprintf("%d%%", textedit.zoom_percent(step))
}


// Over the status item: zoom out, the zoom (resets it), zoom in
zoom_popup_ui :: proc() {
	popup := &g.zoom_popup
	step, ok := pane_zoom(g.panes.focused)
	if !popup.open || !ok {
		return
	}

	g.in_popup = true
	defer g.in_popup = false

	if clay.UI(clay.ID("ZoomPopup"))({
		layout = {
			padding = {4, 4, 4, 4},
			childGap = 2,
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .ElementWithId,
			parentId = clay.ID("ZoomStatus").id,
			attachment = {element = .RightBottom, parent = .RightTop},
			offset = {0, -6},
			zIndex = 120,
		},
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		if icon_button(
			clay.ID("ZoomOut"),
			.Minus,
			ZOOM_POPUP_BUTTON,
			14,
			"Zoom out",
			first_chord_label(.Zoom_Out),
		) {
			popup.action = .Zoom_Out
		}

		if zoom_reset_button(step) do popup.action = .Reset_Zoom

		if icon_button(
			clay.ID("ZoomIn"),
			.Plus,
			ZOOM_POPUP_BUTTON,
			14,
			"Zoom in",
			first_chord_label(.Zoom_In),
		) {
			popup.action = .Zoom_In
		}
	}
}


// The zoom, wide enough for any level so the buttons beside it stay put
@(private = "file")
zoom_reset_button :: proc(step: int) -> bool {
	id := clay.ID("ZoomReset")
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFit({min = 48}), clay.SizingFixed(ZOOM_POPUP_BUTTON)},
			padding = {left = 4, right = 4},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(ZOOM_POPUP_BUTTON / 4),
	}) {
		color := clay.Hovered() ? gfx.theme.text_bright : gfx.theme.text
		label(zoom_label(step), color, FONT_SIZE_SMALL)
	}

	tooltip(id, "Reset to 100%", first_chord_label(.Reset_Zoom))
	return clicked(id)
}
