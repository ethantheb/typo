package editor

import "core:strings"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"

// Small component layer on top of Clay: labels, buttons, icons, text fields,
// tooltips, modal popups and message boxes.

FONT_SIZE_UI      :: 14
FONT_SIZE_SMALL   :: 12
UI_LINE_HEIGHT    :: 20

// A rectangle in logical pixels.
Rect :: struct {
	x, y, w, h: f32,
}

rect_contains :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// An element's bounds from the last layout.
element_rect :: proc(id: clay.ElementId) -> (r: Rect, ok: bool) {
	data := clay.GetElementData(id)
	b := data.boundingBox
	return {b.x, b.y, b.width, b.height}, bool(data.found)
}

// Hit-tests the current mouse position against an element's last layout.
// Unlike clay.Hovered() this sees a click that arrives together with a move.
pointer_in :: proc(id: clay.ElementId) -> bool {
	r, ok := element_rect(id)
	return ok && rect_contains(r, g.mouse_pos)
}

// Whether ordinary UI under a popup may react to clicks: only while no popup is
// open, or for the popup's own controls (g.in_modal is set while they are built).
ui_interactive :: proc() -> bool {
	return g.in_modal || !(g.finder.open || g.settings_window.open)
}

// The element was clicked this frame. `within` is the scroll area it sits in,
// so rows scrolled out of view don't take clicks.
clicked :: proc(id: clay.ElementId, within := clay.ElementId{}) -> bool {
	return g.mouse_pressed && ui_interactive() && pointer_in(id) && (within.id == 0 || pointer_in(within))
}

text_config :: proc(color := theme.text, size: u16 = FONT_SIZE_UI, font := Font_Id.Body) -> clay.TextElementConfig {
	return {textColor = color, fontId = u16(font), fontSize = size, lineHeight = UI_LINE_HEIGHT, wrapMode = .None}
}

label :: proc(s: string, color := theme.text, size: u16 = FONT_SIZE_UI, font := Font_Id.Body) {
	clay.TextDynamic(s, text_config(color, size, font))
}

spacer_x :: proc(width: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(width), clay.SizingFixed(1)}}}) {}
}

// Takes up the free space in a row, pushing what follows to the right.
push_right :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
}

// --- Buttons ---------------------------------------------------------------------

// Small text button with hover feedback. Returns true when clicked.
button :: proc(id: clay.ElementId, s: string, tip := "", shortcut := "") -> bool {
	if clay.UI(id)({
		layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}, childAlignment = {y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		label(s, clay.Hovered() ? theme.text_bright : theme.text_dim, FONT_SIZE_SMALL)
	}
	if tip != "" do tooltip(id, tip, shortcut)
	return clicked(id)
}

// Square button showing an icon, brightened on hover.
icon_button :: proc(id: clay.ElementId, kind: Icon, size: f32 = 24, icon_size: u16 = 16, tip := "", shortcut := "") -> bool {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(size / 4),
	}) {
		icon(kind, clay.Hovered() ? theme.text : theme.text_dim, icon_size)
	}
	if tip != "" do tooltip(id, tip, shortcut)
	return clicked(id)
}

// --- Icons -----------------------------------------------------------------------

Icon :: enum u8 {
	Chevron_Right,
	Chevron_Down,
	Sidebar,
	Settings,
	Close,
	Restart,
	Terminal,
	Maximize,
	Restore,
}

// Codepoints in assets/fonts/lucide.ttf (see lucide-static's font/codepoints.json).
ICON_GLYPHS := [Icon]string {
	.Chevron_Right = "",
	.Chevron_Down  = "",
	.Sidebar       = "", // panel-left
	.Settings      = "",
	.Close         = "", // x
	.Restart       = "", // rotate-ccw
	.Terminal      = "", // square-terminal
	.Maximize      = "", // maximize-2
	.Restore       = "", // minimize-2
}

// What a Clay custom element asks the renderer to draw.
Custom_Data :: union {
	Icon_Data,
	^Editor,
	^Terminal,
}

// The color lives here rather than in backgroundColor, which Clay would draw
// as a filled rectangle.
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
}

icon :: proc(kind: Icon, color: clay.Color, size: u16 = 16) {
	custom_element({}, Icon_Data{kind, color, size}, f32(size))
}

// An element the renderer draws itself (see render_clay_commands): a square of
// `size`, or filling the space available if 0.
custom_element :: proc(id: clay.ElementId, data: Custom_Data, size: f32 = 0) {
	sizing := size > 0 ? clay.Sizing{clay.SizingFixed(size), clay.SizingFixed(size)} : clay.Sizing{clay.SizingGrow(), clay.SizingGrow()}
	// Only has to outlive this frame's render pass.
	config := clay.ElementDeclaration{layout = {sizing = sizing}, custom = {customData = new_clone(data, context.temp_allocator)}}
	if id.id == 0 {
		if clay.UI()(config) {}
	} else {
		if clay.UI(id)(config) {}
	}
}

// --- Text fields -------------------------------------------------------------------

// Edits a one-line text buffer: typing, Backspace (Ctrl+Backspace clears) and
// Ctrl+V. Returns whether the event was one of those, and whether it changed the text.
text_field_event :: proc(buf: ^[dynamic]u8, event: ^sdl.Event) -> (handled, changed: bool) {
	before := len(buf)
	#partial switch event.type {
	case .TEXT_INPUT:
		append(buf, string(event.text.text))
		return true, true
	case .KEY_DOWN:
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		switch {
		case event.key.key == sdl.K_BACKSPACE && ctrl:
			clear(buf)
		case event.key.key == sdl.K_BACKSPACE:
			_, size := utf8.decode_last_rune(buf[:])
			resize(buf, len(buf) - size)
		case base_key(event.key) == sdl.K_V && ctrl:
			raw := sdl.GetClipboardText()
			if raw == nil do return true, false
			defer sdl.free(raw)
			text, _ := strings.replace_all(string(cstring(raw)), "\r\n", " ", context.temp_allocator)
			text, _ = strings.replace_all(text, "\n", " ", context.temp_allocator)
			append(buf, text)
		case:
			return false, false
		}
		return true, len(buf) != before
	}
	return false, false
}

// The look of a one-line text field: the text with a caret while focused, or
// the placeholder (dimmed) while empty. A width of 0 fills the row.
input_box :: proc(id: clay.ElementId, text, placeholder: string, focused: bool, width: f32 = 0, height: f32 = 32, size: u16 = FONT_SIZE_UI) {
	if clay.UI(id)({
		layout = {sizing = {width > 0 ? clay.SizingFixed(width) : clay.SizingGrow(), clay.SizingFixed(height)}, padding = {left = 10, right = 10}, childAlignment = {y = .Center}},
		backgroundColor = theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = focused ? theme.accent : theme.border, width = clay.BorderOutside(1)},
	}) {
		// Clipped inside the field so the clip doesn't cut off the outline.
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}, clip = {horizontal = true}}) {
			if text == "" {
				if focused do text_caret()
				label(placeholder, theme.text_dim, size)
			} else {
				label(text, theme.text_bright, size)
				if focused do text_caret()
			}
		}
	}
}

@(private = "file")
text_caret :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(1.5), clay.SizingFixed(16)}}, backgroundColor = theme.text_bright}) {}
}

// --- Modal popups -----------------------------------------------------------------

// A panel centered over a dimmed window. Use as: if modal(...) { contents }
@(deferred_none = end_modal)
modal :: proc(id: clay.ElementId, width: f32, height: clay.SizingAxis, top: u16, padding: clay.Padding, gap: u16) -> bool {
	g.in_modal = true
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingFixed(f32(g.window_w)), clay.SizingFixed(f32(g.window_h))},
			childAlignment = {x = .Center},
			padding = {top = top},
		},
		backgroundColor = theme.backdrop,
		floating = {attachTo = .Root, zIndex = 100},
	})
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing = {clay.SizingFixed(min(width, f32(g.window_w) - 32)), height},
			layoutDirection = .TopToBottom,
			padding = padding,
			childGap = gap,
		},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = theme.border, width = clay.BorderOutside(1)},
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
// panel has no layout yet and the opening click may still be "pressed".
clicked_outside :: proc(panel: clay.ElementId, opened_frame: u64) -> bool {
	return g.mouse_pressed && opened_frame != g.frame && !pointer_in(panel)
}

// Shows a modal message box and returns the index of the chosen button.
// Enter picks `default`; Esc (or a failure to show the box) gives `cancel`.
ask :: proc(title, message: string, buttons: []string, default, cancel: int) -> int {
	data := make([]sdl.MessageBoxButtonData, len(buttons), context.temp_allocator)
	for text, i in buttons {
		data[i] = {buttonID = i32(i), text = strings.clone_to_cstring(text, context.temp_allocator)}
		if i == default do data[i].flags += {.RETURNKEY_DEFAULT}
		if i == cancel do data[i].flags += {.ESCAPEKEY_DEFAULT}
	}
	box := sdl.MessageBoxData {
		flags      = {.WARNING},
		window     = g.window,
		title      = strings.clone_to_cstring(title, context.temp_allocator),
		message    = strings.clone_to_cstring(message, context.temp_allocator),
		numbuttons = i32(len(data)),
		buttons    = raw_data(data),
	}
	choice := i32(cancel)
	if !sdl.ShowMessageBox(box, &choice) do return cancel
	return int(choice)
}

// --- Tooltips ------------------------------------------------------------------
// tooltip() goes right after the element it describes. When the pointer has
// rested on it for TOOLTIP_DELAY the tip appears beside it, on whichever side
// keeps it on screen. A click hides it until the pointer leaves.

TOOLTIP_DELAY :: 500_000_000 // ns

Tooltip_State :: struct {
	id:         u32,  // element being hovered, or 0
	since:      u64,  // when hovering it began
	seen:       bool, // a tooltip() call matched the pointer this frame
	suppressed: bool, // clicked; stay hidden until the pointer leaves
}

tooltip :: proc(id: clay.ElementId, text: string, shortcut := "") {
	if !ui_interactive() || !pointer_in(id) do return
	t := &g.tooltip
	t.seen = true
	now := sdl.GetTicksNS()
	if t.id != id.id do t^ = {id = id.id, since = now, seen = true}
	if g.mouse_down || g.mouse_pressed do t.suppressed = true
	if t.suppressed || now - t.since < TOOLTIP_DELAY do return

	box, _ := element_rect(id)
	above := box.y + box.h / 2 > f32(g.window_h) / 2
	right := box.x + box.w / 2 > f32(g.window_w) / 2
	attach: clay.FloatingAttachPoints
	switch {
	case above && right: attach = {element = .RightBottom, parent = .RightTop}
	case above:          attach = {element = .LeftBottom, parent = .LeftTop}
	case right:          attach = {element = .RightTop, parent = .RightBottom}
	case:                attach = {element = .LeftTop, parent = .LeftBottom}
	}
	if clay.UI(clay.ID("Tooltip"))({
		layout = {padding = {left = 8, right = 8, top = 4, bottom = 4}, childGap = 10, childAlignment = {y = .Center}},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .ElementWithId,
			parentId = id.id,
			attachment = attach,
			offset = {0, above ? -6 : 6},
			zIndex = 300,
			pointerCaptureMode = .Passthrough,
		},
	}) {
		label(text, theme.text, FONT_SIZE_SMALL)
		if shortcut != "" do label(shortcut, theme.text_dim, FONT_SIZE_SMALL)
	}
}

tooltip_begin_frame :: proc() {
	g.tooltip.seen = false
}

tooltip_end_frame :: proc() {
	if !g.tooltip.seen do g.tooltip = {}
}

// A tooltip is waiting for its delay to pass; keep drawing so it can appear.
tooltip_pending :: proc() -> bool {
	t := &g.tooltip
	return t.id != 0 && !t.suppressed && sdl.GetTicksNS() - t.since < TOOLTIP_DELAY + 50_000_000
}
