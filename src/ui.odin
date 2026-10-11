package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import sdl "vendor:sdl3"

// --- Small component layer on top of Clay -----------------------------------

text_config :: proc(color := theme.text, size: u16 = FONT_SIZE_UI, font := Font_Id.Body) -> clay.TextElementConfig {
	return {textColor = color, fontId = u16(font), fontSize = size, lineHeight = UI_LINE_HEIGHT, wrapMode = .None}
}

label :: proc(s: string, color := theme.text, size: u16 = FONT_SIZE_UI, font := Font_Id.Body) {
	clay.TextDynamic(s, text_config(color, size, font))
}

// Whether ordinary UI under a popup (finder, settings) may react to clicks: only
// while that popup is closed, or for the popup's own controls (g.in_modal is set
// while they are built).
ui_interactive :: proc() -> bool {
	return g.in_modal || !(g.finder.open || g.settings_window.open)
}

// Thin text cursor for input fields.
text_caret :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(1.5), clay.SizingFixed(16)}}, backgroundColor = theme.text_bright}) {}
}

// --- Tooltips -----------------------------------------------------------------------
// Call tooltip() right after declaring a button. When the pointer has rested on
// it for TOOLTIP_DELAY the tip appears beside it, above or below and left- or
// right-aligned depending on where the button is, so it stays on screen. A
// click hides it until the pointer leaves the button.

TOOLTIP_DELAY :: 500_000_000 // ns

Tooltip_State :: struct {
	id:         u32,  // button being hovered, or 0
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

	box := clay.GetElementData(id).boundingBox
	above := box.y + box.height / 2 > f32(g.window_h) / 2
	right := box.x + box.width / 2 > f32(g.window_w) / 2
	attach: clay.FloatingAttachPoints
	switch {
	case above && right:  attach = {element = .RightBottom, parent = .RightTop}
	case above:           attach = {element = .LeftBottom, parent = .LeftTop}
	case right:           attach = {element = .RightTop, parent = .RightBottom}
	case:                 attach = {element = .LeftTop, parent = .LeftBottom}
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
		label(text, theme.text, 12)
		if shortcut != "" do label(shortcut, theme.text_dim, 12)
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

// Mouse cursor shapes, created on first use.
@(private = "file")
cursors: [sdl.SystemCursor]^sdl.Cursor
@(private = "file")
current_cursor := sdl.SystemCursor.DEFAULT

// Shows an I-beam over editable text (the text area, the finder and settings
// search fields) and the normal arrow everywhere else. Call after layout.
update_mouse_cursor :: proc() {
	want := sdl.SystemCursor.DEFAULT
	e := &g.editor
	switch {
	case g.finder.open:
		if pointer_in(clay.ID("FinderInput")) do want = .TEXT
	case g.settings_window.open:
		if pointer_in(clay.ID("SettingsSearch")) do want = .TEXT
	case e.status == .Text && e.dragging && g.mouse_down:
		want = .TEXT // keep the I-beam while drag-selecting, wherever the mouse goes
	case e.status == .Text && e.scrollbar_drag == nil:
		v := e.view
		p := g.mouse_pos
		in_text := p.x >= v.x + e.gutter_w && p.x < v.x + v.w && p.y >= v.y && p.y < v.y + v.h
		if in_text && !scrollbar_hit(e, p) do want = .TEXT
	}
	if want == current_cursor do return
	cursor := sdl.GetDefaultCursor()
	if want != .DEFAULT {
		if cursors[want] == nil do cursors[want] = sdl.CreateSystemCursor(want)
		cursor = cursors[want]
	}
	if cursor != nil && sdl.SetCursor(cursor) do current_cursor = want
}

destroy_mouse_cursors :: proc() {
	for &c in cursors {
		if c != nil do sdl.DestroyCursor(c)
		c = nil
	}
}

// Hit-tests the current mouse position against an element's last laid-out bounds.
// Used for clicks instead of clay.Hovered(), which reflects the previous frame's
// pointer position and so misses a click that arrives together with a move.
pointer_in :: proc(id: clay.ElementId) -> bool {
	data := clay.GetElementData(id)
	if !data.found do return false
	b := data.boundingBox
	p := g.mouse_pos
	return p.x >= b.x && p.x < b.x + b.width && p.y >= b.y && p.y < b.y + b.height
}

// Small text button with hover feedback. Returns true when clicked this frame.
button :: proc(id: clay.ElementId, s: string) -> (clicked: bool) {
	if clay.UI(id)({
		layout = {padding = {left = 6, right = 6, top = 2, bottom = 2}, childAlignment = {y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		clicked = g.mouse_pressed && ui_interactive() && pointer_in(id)
		label(s, clay.Hovered() ? theme.text_bright : theme.text_dim, 12)
	}
	return
}

// Square button showing an icon, brightened on hover.
icon_button :: proc(id: clay.ElementId, kind: Icon, size: f32 = 24, icon_size: u16 = 16) -> (clicked: bool) {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(size / 4),
	}) {
		clicked = g.mouse_pressed && ui_interactive() && pointer_in(id)
		icon(kind, clay.Hovered() ? theme.text : theme.text_dim, icon_size)
	}
	return
}

Icon :: enum u8 {
	Chevron_Right,
	Chevron_Down,
	Sidebar,
	Settings,
	Close,
}

// Codepoints in assets/fonts/lucide.ttf (see lucide-static's font/codepoints.json).
ICON_GLYPHS := [Icon]string {
	.Chevron_Right = "\ue06f",
	.Chevron_Down  = "\ue06d",
	.Sidebar       = "\ue12a", // panel-left
	.Settings      = "\ue154",
	.Close         = "\ue1b2", // x
}

// What a Clay custom element asks the renderer to draw.
Custom_Data :: union {
	Icon_Data,
	^Editor,
}

// Passed to the renderer through a Clay custom element. Color lives here rather
// than in backgroundColor, which Clay would also draw as a filled rectangle.
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
}

icon :: proc(kind: Icon, color: clay.Color, size: u16 = 16) {
	// Temp-allocated: it only has to outlive this frame's render pass.
	data := new_clone(Custom_Data(Icon_Data{kind, color, size}), context.temp_allocator)
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(f32(size)), clay.SizingFixed(f32(size))}},
		custom = {customData = data},
	}) {}
}

// One explorer row: indent, chevron for directories, name. Returns true when clicked.
tree_row :: proc(index: int, node: Node, selected: bool) -> (clicked: bool) {
	if clay.UI(clay.ID("TreeRow", u32(index)))({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(22)},
			padding = {left = u16(8 + node.depth * 12), right = 8},
			childGap = 2,
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
	}) {
		clicked = g.mouse_pressed && ui_interactive() && pointer_in(clay.ID("TreeRow", u32(index))) && pointer_in(clay.ID("SidebarFiles"))
		if node.is_dir {
			icon(node.expanded ? .Chevron_Down : .Chevron_Right, theme.text_dim)
		} else {
			spacer_x(16)
		}
		label(node.name, selected ? theme.text : theme.text_dim, FONT_SIZE_SIDEBAR)
	}
	return
}

spacer_x :: proc(width: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(width), clay.SizingFixed(1)}}}) {}
}

// --- Layout -----------------------------------------------------------------

build_ui :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI(clay.ID("Root"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = theme.bg,
	}) {
		if clay.UI(clay.ID("Main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			if g.sidebar_visible do sidebar()
			editor_pane()
		}
		status_bar()
		finder_ui()
		settings_window_ui()
	}

	return clay.EndLayout(g.dt)
}


sidebar :: proc() {
	if clay.UI(clay.ID("Sidebar"))({
		layout = {
			sizing = {clay.SizingFixed(SIDEBAR_WIDTH), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {top = 8},
		},
		backgroundColor = theme.panel,
		border = {color = theme.border, width = {right = 1}},
	}) {
		if clay.UI(clay.ID("SidebarHeader"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(24)}, padding = {left = 12, right = 6}, childGap = 2, childAlignment = {y = .Center}},
		}) {
			name_id := clay.ID("FolderName")
			if clay.UI(name_id)({}) {
				label(strings.to_upper(folder_name(g.workspace.root), context.temp_allocator), theme.text_dim, 12, .Bold)
			}
			tooltip(name_id, g.workspace.root)
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			if button(clay.ID("OpenButton"), "Open…") do show_open_folder_dialog()
			tooltip(clay.ID("OpenButton"), "Open a folder")
		}
		if clay.UI(clay.ID("SidebarFiles"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for index in g.workspace.visible {
				node := g.workspace.nodes[index]
				if tree_row(index, node, node.path == g.editor.path) {
					g.pending = node.is_dir ? Toggle_Node(index) : Open_File(strings.clone(node.path))
				}
			}
		}
	}
}

// UI actions that change the tree or buffer. They are applied at the start of
// the next frame, because this frame's render commands still point at the
// strings they would free.
Toggle_Node :: distinct int
Open_File :: distinct string // owned, full path
Open_Folder :: distinct string // owned

Action :: union {
	Toggle_Node,
	Open_File,
	Open_Folder,
}

apply_pending_action :: proc() {
	if path, ok := take_picked_folder(); ok {
		g.pending = Open_Folder(path)
	}

	switch a in g.pending {
	case Toggle_Node:
		workspace_toggle(&g.workspace, int(a))
	case Open_File:
		if string(a) != g.editor.path && editor_confirm_discard(&g.editor) {
			editor_open(&g.editor, string(a))
			workspace_reveal(&g.workspace, string(a))
		}
		delete(string(a))
	case Open_Folder:
		if editor_confirm_discard(&g.editor) do open_folder(string(a))
		delete(string(a))
	}
	g.pending = nil
}

open_folder :: proc(path: string) {
	path := os.get_absolute_path(path, context.temp_allocator) or_else path
	if len(path) > 3 do path = strings.trim_right(path, "/\\") // keep "C:\"
	workspace_open(&g.workspace, path)
	title := fmt.tprintf("%s - typo", folder_name(path))
	_ = sdl.SetWindowTitle(g.window, strings.clone_to_cstring(title, context.temp_allocator))
	editor_close(&g.editor)
	finder_invalidate()
	reset_scroll("SidebarFiles")
}

reset_scroll :: proc(id: string) {
	scroll := clay.GetScrollContainerData(clay.ID(id))
	if scroll.found do scroll.scrollPosition^ = {}
}

editor_pane :: proc() {
	if clay.UI(clay.ID("EditorPane"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = theme.bg,
	}) {
		switch g.editor.status {
		case .None:
			centered_message("Select a file in the explorer, or press Ctrl+E")
		case .Error:
			centered_message("Could not read file")
		case .Binary:
			centered_message("Binary file not shown")
		case .Text:
			editor_text_element(&g.editor)
		}
	}
}

centered_message :: proc(s: string) {
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}},
	}) {
		label(s, theme.text_dim)
	}
}

status_bar :: proc() {
	if clay.UI(clay.ID("StatusBar"))({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(STATUSBAR_HEIGHT)},
			padding = {left = 3, right = 12},
			childGap = 16,
			childAlignment = {y = .Center},
		},
		backgroundColor = theme.statusbar,
		border = {color = theme.border, width = {top = 1}},
	}) {
		if clay.UI()({layout = {childGap = 2}}) {
			defer tooltip(clay.ID("SidebarToggle"), "Toggle sidebar", first_chord_label(&g.settings, .Toggle_Sidebar))
			defer tooltip(clay.ID("SettingsButton"), "Settings", first_chord_label(&g.settings, .Open_Settings))
			if icon_button(clay.ID("SidebarToggle"), .Sidebar, size = 20, icon_size = 15) {
				g.sidebar_visible = !g.sidebar_visible
			}
			if icon_button(clay.ID("SettingsButton"), .Settings, size = 20, icon_size = 15) {
				settings_window_toggle()
			}
		}
		e := &g.editor
		if e.status != .None {
			name := relative_to_root(e.path)
			label(editor_is_modified(e) ? fmt.tprintf("%s •", name) : name, theme.text, 12)
		}
		if e.status == .Text {
			label(cursor_status(e), theme.text_dim, 12)
			label(fmt.tprintf("%d lines", buffer.line_count(&e.buf)), theme.text_dim, 12)
			label(e.buf.crlf ? "CRLF" : "LF", theme.text_dim, 12)
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		label(fmt.tprintf("%dx%d @%.2fx", g.window_w, g.window_h, g.ui_scale), theme.text_dim, 12)
		if g.settings.show_fps do label(fmt.tprintf("%.0f fps", g.fps), theme.text_dim, 12)
	}
}

// "Ln 12, Col 5", plus caret/selection counts when relevant.
cursor_status :: proc(e: ^Editor) -> string {
	p := e.sels[e.primary]
	line := buffer.offset_to_line(&e.buf, p.head)
	text, start := line_text(e, line)
	status := fmt.tprintf("Ln %d, Col %d", line + 1, visual_col(text, p.head - start) + 1)
	selected := 0
	for s in e.sels do selected += sel_hi(s) - sel_lo(s)
	if len(e.sels) > 1 do status = fmt.tprintf("%s  (%d carets)", status, len(e.sels))
	if selected > 0 do status = fmt.tprintf("%s  (%d selected)", status, selected)
	return status
}

relative_to_root :: proc(path: string) -> string {
	root := g.workspace.root
	if len(path) > len(root) && path[:len(root)] == root {
		return strings.trim_left(path[len(root):], "/\\")
	}
	return path
}
