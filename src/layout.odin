package editor

import "core:fmt"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import sdl "../vendor/sdl3"

// The window layout: sidebar, editor pane, terminal panel and status bar, plus
// which pane has focus and the mouse cursor shape.

FONT_SIZE_SIDEBAR :: 13
STATUSBAR_HEIGHT :: 24
SIDEBAR_WIDTH :: 240
TERMINAL_HEADER_HEIGHT :: 28
TERMINAL_DEFAULT_HEIGHT :: 280
TERMINAL_MIN_HEIGHT :: 90
SPLITTER_GRAB :: 5 // grab area of the editor/terminal divider

// The pane that receives keyboard input.
Focus :: enum {
	Editor,
	Terminal,
}

// The terminal area under the editor.
Terminal_Panel :: struct {
	terminal:   Terminal,
	visible:    bool,
	maximized:  bool, // fills the window in place of the sidebar and editor
	height:     f32,
	split_drag: bool,
	split_grab: f32, // mouse y minus the splitter's top when the drag began
}

build_ui :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()
	if clay.UI(clay.ID("Root"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = theme.bg,
	}) {
		if clay.UI(clay.ID("Main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			maximized := terminal_maximized()
			if g.sidebar_visible && !maximized do sidebar()
			if clay.UI(clay.ID("Work"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
				if !maximized do editor_pane()
				if g.terminal_panel.visible {
					if !maximized do terminal_splitter()
					terminal_pane()
				}
			}
		}
		status_bar()
		finder_ui()
		settings_window_ui()
	}
	g.animating = false // set again by any transition still running (see transition)
	return clay.EndLayout(g.dt)
}

// A press in a pane gives it keyboard focus.
update_focus :: proc() {
	if !g.mouse_pressed || !ui_interactive() do return
	// Hidden panes keep their last bounds in Clay, so check visibility first.
	if g.terminal_panel.visible && pointer_in(clay.ID("TerminalPane")) do g.focus = .Terminal
	else if !terminal_maximized() && pointer_in(clay.ID("EditorPane")) do g.focus = .Editor
}

// --- Sidebar ---------------------------------------------------------------------

@(private = "file")
sidebar :: proc() {
	if clay.UI(clay.ID("Sidebar"))({
		layout = {sizing = {clay.SizingFixed(SIDEBAR_WIDTH), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {top = 8}},
		backgroundColor = theme.panel,
		border = {color = theme.border, width = {right = 1}},
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(24)}, padding = {left = 12, right = 6}, childGap = 2, childAlignment = {y = .Center}},
		}) {
			name_id := clay.ID("FolderName")
			if clay.UI(name_id)({}) {
				label(strings.to_upper(folder_name(g.workspace.root), context.temp_allocator), theme.text_dim, FONT_SIZE_SMALL, .Bold)
			}
			tooltip(name_id, g.workspace.root)
			push_right()
			if button(clay.ID("OpenButton"), "Open…", "Open a folder") do show_open_folder_dialog()
		}
		files_id := clay.ID("SidebarFiles")
		smooth_scroll_list(files_id)
		if clay.UI(files_id)({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for index in g.workspace.visible {
				node := g.workspace.nodes[index]
				if tree_row(index, node, node.path == g.editor.path, files_id) {
					g.pending = node.is_dir ? Toggle_Node(index) : Open_File(strings.clone(node.path))
				}
			}
		}
	}
}

// One explorer row: indent, chevron for directories, name. Returns true when clicked.
@(private = "file")
tree_row :: proc(index: int, node: Node, selected: bool, list: clay.ElementId) -> bool {
	id := clay.ID("TreeRow", u32(index))
	if clay.UI(id)({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(22)},
			padding = {left = u16(8 + node.depth * 12), right = 8},
			childGap = 2,
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
	}) {
		if node.is_dir {
			icon(node.expanded ? .Chevron_Down : .Chevron_Right, theme.text_dim)
		} else {
			spacer_x(16)
		}
		label(node.name, selected ? theme.text : theme.text_dim, FONT_SIZE_SIDEBAR)
	}
	return clicked(id, list)
}

// --- Editor pane -----------------------------------------------------------------

@(private = "file")
editor_pane :: proc() {
	if clay.UI(clay.ID("EditorPane"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = theme.bg,
	}) {
		switch g.editor.status {
		case .None:   centered_message(fmt.tprintf("Select a file in the explorer, or press %s", first_chord_label(.Find_File)))
		case .Error:  centered_message("Could not read file")
		case .Binary: centered_message("Binary file not shown")
		case .Text:   editor_text_element(&g.editor)
		}
	}
}

@(private = "file")
centered_message :: proc(s: string) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}}}) {
		label(s, theme.text_dim)
	}
}

// --- Terminal panel ----------------------------------------------------------------

// Shows (and focuses) the terminal, focuses it if shown but unfocused, or hides it.
terminal_toggle :: proc() {
	p := &g.terminal_panel
	if p.visible && g.focus != .Terminal {
		g.focus = .Terminal
		return
	}
	if p.visible {
		terminal_hide()
	} else {
		terminal_show(maximized = false)
	}
}

// Expands the terminal to fill the window, or puts it back under the editor.
terminal_toggle_maximized :: proc() {
	p := &g.terminal_panel
	terminal_show(maximized = !p.maximized || !p.visible)
}

terminal_maximized :: proc() -> bool {
	return g.terminal_panel.visible && g.terminal_panel.maximized
}

@(private = "file")
terminal_show :: proc(maximized: bool) {
	p := &g.terminal_panel
	if p.height == 0 do p.height = TERMINAL_DEFAULT_HEIGHT
	p.visible, p.maximized = true, maximized
	g.focus = .Terminal
	terminal_init(&p.terminal)
}

@(private = "file")
terminal_hide :: proc() {
	p := &g.terminal_panel
	p.visible, p.maximized = false, false
	g.focus = .Editor
}

// Per frame, before layout: the divider drag, then the terminal itself.
terminal_panel_frame :: proc() {
	p := &g.terminal_panel
	if !p.terminal.initialized do return
	if p.visible && ui_interactive() do splitter_mouse(p)
	terminal_frame(&p.terminal, clay.ID("TerminalText"), p.visible, ui_interactive() && !p.split_drag)
}

terminal_panel_busy :: proc() -> bool {
	p := &g.terminal_panel
	return p.split_drag || (p.terminal.initialized && p.terminal.busy)
}

@(private = "file")
terminal_pane :: proc() {
	p := &g.terminal_panel
	if clay.UI(clay.ID("TerminalPane"))({
		layout = {sizing = {clay.SizingGrow(), p.maximized ? clay.SizingGrow() : clay.SizingFixed(p.height)}, layoutDirection = .TopToBottom},
		backgroundColor = theme.bg,
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(TERMINAL_HEADER_HEIGHT)}, padding = {left = 12, right = 6}, childGap = 8, childAlignment = {y = .Center}},
		}) {
			label(terminal_title(&p.terminal), g.focus == .Terminal ? theme.text : theme.text_dim, FONT_SIZE_SMALL, .Bold)
			push_right()
			max_tip := p.maximized ? "Restore terminal" : "Maximize terminal"
			if icon_button(clay.ID("TerminalMaximize"), p.maximized ? .Restore : .Maximize, 22, 15, max_tip, first_chord_label(.Maximize_Terminal)) {
				terminal_toggle_maximized()
			}
			if icon_button(clay.ID("TerminalRestart"), .Restart, 22, 15, "Restart shell") {
				terminal_restart(&p.terminal)
				g.focus = .Terminal
			}
			if icon_button(clay.ID("TerminalClose"), .Chevron_Down, 22, 18, "Hide terminal", first_chord_label(.Toggle_Terminal)) {
				terminal_hide()
			}
		}
		custom_element(clay.ID("TerminalText"), &p.terminal)
	}
}

// The divider between the editor and the terminal; drag to resize.
@(private = "file")
terminal_splitter :: proc() {
	if clay.UI(clay.ID("TerminalSplitter"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}},
		backgroundColor = g.terminal_panel.split_drag ? theme.accent : theme.border,
	}) {}
}

@(private = "file")
splitter_mouse :: proc(p: ^Terminal_Panel) {
	r, ok := element_rect(clay.ID("TerminalSplitter"))
	if !ok do return
	if g.mouse_pressed && splitter_hit(g.mouse_pos) {
		p.split_drag = true
		p.split_grab = g.mouse_pos.y - r.y
	}
	if !g.mouse_down do p.split_drag = false
	if p.split_drag {
		bottom := f32(g.window_h) - STATUSBAR_HEIGHT
		max_height := max(bottom - 120, TERMINAL_MIN_HEIGHT) // keep some editor visible
		p.height = clamp(bottom - (g.mouse_pos.y - p.split_grab), TERMINAL_MIN_HEIGHT, max_height)
	}
}

// Whether a point is on the divider's grab area (a few pixels around the line).
@(private = "file")
splitter_hit :: proc(pos: [2]f32) -> bool {
	if !g.terminal_panel.visible || g.terminal_panel.maximized do return false
	r, ok := element_rect(clay.ID("TerminalSplitter"))
	return ok && rect_contains({r.x, r.y - SPLITTER_GRAB / 2 - 1, r.w, SPLITTER_GRAB + 2}, pos)
}

// --- Status bar --------------------------------------------------------------------

@(private = "file")
status_bar :: proc() {
	if clay.UI(clay.ID("StatusBar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(STATUSBAR_HEIGHT)}, padding = {left = 3, right = 12}, childGap = 16, childAlignment = {y = .Center}},
		backgroundColor = theme.statusbar,
		border = {color = theme.border, width = {top = 1}},
	}) {
		if clay.UI()({layout = {childGap = 2}}) {
			if icon_button(clay.ID("SidebarToggle"), .Sidebar, 20, 15, "Toggle sidebar", first_chord_label(.Toggle_Sidebar)) {
				run_command(.Toggle_Sidebar)
			}
			if icon_button(clay.ID("TerminalToggle"), .Terminal, 20, 15, "Toggle terminal", first_chord_label(.Toggle_Terminal)) {
				run_command(.Toggle_Terminal)
			}
			if icon_button(clay.ID("SettingsButton"), .Settings, 20, 15, "Settings", first_chord_label(.Open_Settings)) {
				run_command(.Open_Settings)
			}
		}
		e := &g.editor
		if e.status != .None {
			name := relative_to_root(e.path)
			if e.new_file do name = fmt.tprintf("%s (new)", name)
			label(editor_is_modified(e) ? fmt.tprintf("%s •", name) : name, theme.text, FONT_SIZE_SMALL)
		}
		if e.status == .Text {
			if !md_caret_hidden(e) do label(cursor_status(e), theme.text_dim, FONT_SIZE_SMALL)
			label(fmt.tprintf("%d lines", buffer.line_count(&e.buf)), theme.text_dim, FONT_SIZE_SMALL)
			label(e.buf.crlf ? "CRLF" : "LF", theme.text_dim, FONT_SIZE_SMALL)
			if e.md != nil {
				rendered := md_rendered(e)
				if icon_button(clay.ID("MarkdownView"), rendered ? .Code : .Eye, 20, 15, rendered ? "Show Markdown source" : "Show rendered Markdown", first_chord_label(.Toggle_Markdown_View)) {
					run_command(.Toggle_Markdown_View)
				}
			}
		}
		push_right()
		label(fmt.tprintf("%dx%d @%.2fx", g.window_w, g.window_h, g.ui_scale), theme.text_dim, FONT_SIZE_SMALL)
		if g.settings.show_fps do label(fmt.tprintf("%.0f fps", g.fps), theme.text_dim, FONT_SIZE_SMALL)
	}
}

// "Ln 12, Col 5", plus caret/selection counts when relevant.
@(private = "file")
cursor_status :: proc(e: ^Editor) -> string {
	line, col := caret_line_col(e)
	status := fmt.tprintf("Ln %d, Col %d", line + 1, col + 1)
	selected := 0
	for s in e.sels do selected += sel_hi(s) - sel_lo(s)
	if len(e.sels) > 1 do status = fmt.tprintf("%s  (%d carets)", status, len(e.sels))
	if selected > 0 do status = fmt.tprintf("%s  (%d selected)", status, selected)
	return status
}

// --- Mouse cursor ------------------------------------------------------------------

@(private = "file")
cursors: [sdl.SystemCursor]^sdl.Cursor // created on first use
@(private = "file")
current_cursor := sdl.SystemCursor.DEFAULT

// An I-beam over editable text, a resize arrow on the splitter, the normal
// arrow elsewhere. Call after layout.
update_mouse_cursor :: proc() {
	want := sdl.SystemCursor.DEFAULT
	e := &g.editor
	switch {
	case g.finder.open:
		if pointer_in(clay.ID("FinderInput")) do want = .TEXT
	case g.settings_window.open && !ui_interactive():
		if settings_window_over_text() do want = .TEXT
	case g.terminal_panel.split_drag || splitter_hit(g.mouse_pos):
		want = .NS_RESIZE
	case e.status != .Text || terminal_maximized():
	case e.dragging && g.mouse_down:
		want = .TEXT // keep the I-beam while drag-selecting, wherever the mouse goes
	case md_rendered(e) && (e.mdv.code_drag.active || code_bar_under_pointer(e)):
		want = .DEFAULT
	case md_rendered(e) && md_pointer_target(e):
		want = .POINTER
	case e.scrollbar_drag == nil && editor_text_hit(e, g.mouse_pos):
		want = .TEXT
	}
	if want == current_cursor do return
	cursor := sdl.GetDefaultCursor()
	if want != .DEFAULT {
		if cursors[want] == nil do cursors[want] = sdl.CreateSystemCursor(want)
		cursor = cursors[want]
	}
	if cursor != nil && sdl.SetCursor(cursor) do current_cursor = want
}

@(private = "file")
code_bar_under_pointer :: proc(e: ^Editor) -> bool {
	_, _, _, _, ok := md_code_bar_at(e, g.mouse_pos)
	return ok
}

destroy_mouse_cursors :: proc() {
	for &c in cursors {
		if c != nil do sdl.DestroyCursor(c)
		c = nil
	}
}
