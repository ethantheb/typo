package editor

import "core:fmt"

import clay "../vendor/clay-odin"
import "buffer"
import sdl "../vendor/sdl3"
import "gfx"
import "textedit"

// The window layout: the sidebar (sidebar.odin) at the left of "Main" and the
// panes (panes.odin) floating beside it, or over it while it is hidden, at rects
// computed from the window size, with the status bar under them; and the mouse
// cursor shape


STATUSBAR_HEIGHT :: 24


build_ui :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()
	g.row_clips = 0

	if clay.UI(clay.ID("Root"))({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = gfx.theme.panel,
	}) {
		if clay.UI(clay.ID("Main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			sidebar()
			panes_ui()
		}
		status_bar()
		sidebar_search_popup()
		project_picker_ui()
		finder_ui()
		settings_window_ui()
		lsp_hover_ui()
		lsp_completion_ui()
		lsp_rename_ui()
		lsp_popup_ui()
		zoom_popup_ui()
		context_menu_ui()
		dialog_ui()
	}

	g.animating = false // set again by any transition still running (see transition)
	return clay.EndLayout(g.dt)
}


// --- Status bar --------------------------------------------------------------------

@(private = "file")
status_bar :: proc() {
	if clay.UI(clay.ID("StatusBar"))({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(STATUSBAR_HEIGHT)},
			padding = {left = 3, right = 12, bottom = 2},
			childGap = 16,
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.theme.statusbar,
	}) {
		status_buttons()
		git_status_item()

		// The focused pane
		if e := focused_editor(); e != nil {
			editor_status(e)
		} else if p := g.panes.focused; p != nil {
			label(pane_title(p), gfx.theme.text, FONT_SIZE_SMALL)
		}

		// The language servers and the pane's zoom, on the right
		push_right()
		lsp_status_item()
		zoom_status_item()
		if g.settings.show_fps {
			label(fmt.tprintf("%.0f fps", g.fps), gfx.theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}


// The sidebar, terminal and settings buttons
@(private = "file")
status_buttons :: proc() {
	if clay.UI()({layout = {childGap = 2}}) {
		if icon_button(
			clay.ID("SidebarToggle"),
			.Sidebar,
			20,
			15,
			"Toggle sidebar",
			first_chord_label(.Toggle_Sidebar),
		) {
			run_command(.Toggle_Sidebar)
		}

		// With a pin while new terminals are pinned; right-click picks which
		// (context_menu.odin)
		pinned := persist_wanted()
		badge: Maybe(gfx.Icon_Badge)
		if pinned do badge = gfx.Icon_Badge{.Pin, gfx.theme.accent}
		if icon_button(
			clay.ID("TerminalToggle"),
			.Terminal,
			20,
			15,
			pinned ? "Toggle terminal · new terminals are pinned" : "Toggle terminal",
			first_chord_label(.Toggle_Terminal),
			badge,
		) {
			defer_action(Run_Command(.Toggle_Terminal))
		}

		if icon_button(
			clay.ID("SettingsButton"),
			.Settings,
			20,
			15,
			"Settings",
			first_chord_label(.Open_Settings),
		) {
			run_command(.Open_Settings)
		}
	}
}


// The focused file's name, and for text its caret, lines, line endings and
// Markdown view button
@(private = "file")
editor_status :: proc(e: ^Editor) {
	name := relative_to_root(e.path)
	if e.new_file do name = fmt.tprintf("%s (new)", name)
	if e.disk.missing do name = fmt.tprintf("%s (deleted)", name)
	title := editor_is_modified(e) ? fmt.tprintf("%s •", name) : name
	label(title, gfx.theme.text, FONT_SIZE_SMALL)

	if e.status != .Text do return

	if !textedit.caret_hidden(e) {
		label(cursor_status(e), gfx.theme.text_dim, FONT_SIZE_SMALL)
	}
	lines := fmt.tprintf("%d lines", buffer.line_count(&e.buf))
	label(lines, gfx.theme.text_dim, FONT_SIZE_SMALL)
	label(e.buf.crlf ? "CRLF" : "LF", gfx.theme.text_dim, FONT_SIZE_SMALL)

	if e.md != nil {
		rendered := md_rendered(e)
		if icon_button(
			clay.ID("MarkdownView"),
			rendered ? .Code : .Eye,
			20,
			15,
			rendered ? "Show Markdown source" : "Show rendered Markdown",
			first_chord_label(.Toggle_Markdown_View),
		) {
			run_command(.Toggle_Markdown_View)
		}
	}
}


// "Ln 12, Col 5", plus caret/selection counts when relevant
@(private = "file")
cursor_status :: proc(e: ^Editor) -> string {
	line, col := caret_line_col(e)
	status := fmt.tprintf("Ln %d, Col %d", line + 1, col + 1)

	selected := 0
	for s in e.sels do selected += textedit.sel_hi(s) - textedit.sel_lo(s)

	if len(e.sels) > 1 do status = fmt.tprintf("%s  (%d carets)", status, len(e.sels))
	if selected > 0 do status = fmt.tprintf("%s  (%d selected)", status, selected)
	return status
}


// --- Mouse cursor ------------------------------------------------------------------

@(private = "file")
cursors: [sdl.SystemCursor]^sdl.Cursor // created on first use
@(private)
current_cursor := sdl.SystemCursor.DEFAULT


// An I-beam over editable text, a resize arrow on a divider between panes, a
// move arrow while dragging a pane, the normal arrow elsewhere. Call after layout
update_mouse_cursor :: proc() {
	want := sdl.SystemCursor.DEFAULT
	ps := &g.panes

	divider := ps.divider.tile
	if divider == nil && ui_interactive() && ps.drag.pane == nil {
		divider = divider_at(ps.root, g.mouse_pos)
	}

	switch {
	case g.dialog.open,
	     g.menu.open && pointer_in(clay.ID("ContextMenu")),
	     g.lsp.popup.open && pointer_in(clay.ID("LspPopup")),
	     lsp_hover_covers_pointer(),
	     lsp_completion_covers_pointer():
		// The arrow over popups that cover what is under them
	case g.over_text_field:
		want = .TEXT
	case lsp_rename_covers_pointer(),
	     search_popup_covers_pointer(),
	     project_picker_covers_pointer(),
	     g.finder.open,
	     g.find.open && pointer_in(clay.ID("FindBar")),
	     g.settings_window.open && !ui_interactive():
		// The arrow over the rest of a popup
	case ps.drag.active:
		want = .MOVE
	case divider != nil:
		want = divider.axis == .Row ? .EW_RESIZE : .NS_RESIZE
	case:
		want = editor_cursor()
	}
	if want == current_cursor do return

	cursor := sdl.GetDefaultCursor()
	if want != .DEFAULT {
		if cursors[want] == nil do cursors[want] = sdl.CreateSystemCursor(want)
		cursor = cursors[want]
	}
	if cursor != nil && sdl.SetCursor(cursor) {
		current_cursor = want
	}
}


// The cursor over the editors: the I-beam while drag-selecting, wherever the
// mouse goes, else whatever the view under the pointer shows there
@(private = "file")
editor_cursor :: proc() -> sdl.SystemCursor {
	// Drag-selecting
	for p in g.panes.open {
		e, ok := p.content.(^Editor)
		if ok && pane_live(p) && e.status == .Text && e.dragging && g.mouse_down {
			return .TEXT
		}
	}

	// The view under the pointer
	for p in g.panes.open {
		e, ok := p.content.(^Editor)
		if !ok || !pane_live(p) || e.status != .Text {
			continue
		}
		if !gfx.rect_contains(e.view, g.mouse_pos) do continue

		over_text := editor_text_hit(e, g.mouse_pos)
		look := textedit.Pointer.Text
		if e.kind.pointer != nil do look = e.kind.pointer(e, g.mouse_pos, over_text)

		switch look {
		case .Arrow: return .DEFAULT
		case .Hand:  return .POINTER
		case .Text:  return over_text && !editor_scrollbar_dragged(e) ? .TEXT : .DEFAULT
		}
	}
	return .DEFAULT
}


destroy_mouse_cursors :: proc() {
	for &c in cursors {
		if c != nil do sdl.DestroyCursor(c)
		c = nil
	}
}
