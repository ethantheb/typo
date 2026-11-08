package editor

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import sdl "../vendor/sdl3"
import "gfx"
import "textedit"

// The window layout: the sidebar and the panes (panes.odin) float over "Main"
// at rects computed from the window size, with the status bar under them; and
// the mouse cursor shape


FONT_SIZE_SIDEBAR :: 13
STATUSBAR_HEIGHT  :: 24
SIDEBAR_WIDTH     :: 240


build_ui :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

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
		finder_ui()
		settings_window_ui()
		context_menu_ui()
		dialog_ui()
	}

	g.animating = false // set again by any transition still running (see transition)
	return clay.EndLayout(g.dt)
}


// --- Sidebar -----------------------------------------------------------------------

// A pane at the left: the file tree, and the shelf under it. Hiding it slides it
// out of the window; it is declared until it gets there
@(private = "file")
sidebar :: proc() {
	id := clay.ID("Sidebar")
	work := work_rect()
	r := gfx.Rect{PANE_GAP, PANE_GAP, SIDEBAR_WIDTH, work.h}

	// Hidden: out of the window, and gone once it got there
	if !g.sidebar_visible {
		r.x = -SIDEBAR_WIDTH - PANE_GAP
		if g.sidebar_gone || element_at(id, r) {
			g.sidebar_gone = true
			return
		}
	}
	g.sidebar_gone = false

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)},
			layoutDirection = .TopToBottom,
			padding = {bottom = 4},
		},
		backgroundColor = gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(PANE_RADIUS),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Parent, offset = {r.x, r.y}, zIndex = 2},
		transition = transition(clay.TransitionPropertyBoundingBox, .From_Left),
	}) {
		sidebar_header()

		files_id := clay.ID("SidebarFiles")
		wheel_scroll_list(files_id)
		active := active_editor()

		// Open files with unsaved changes, marked in the tree
		modified := make([dynamic]string, context.temp_allocator)
		for p in g.panes.open {
			e, is_file := p.content.(^Editor)
			if is_file && editor_is_modified(e) {
				append(&modified, e.path)
			}
		}

		// The tree
		if clay.UI(files_id)({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {bottom = 4},
			},
			clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			if creating_in(g.workspace.root) do new_entry_row(0)

			for index in g.workspace.visible {
				node := g.workspace.nodes[index]
				selected := active != nil && node.path == active.path
				changed := !node.is_dir && slice.contains(modified[:], node.path)

				// Files open on release, or drag into a pane (see drag_mouse)
				pressed := tree_row(index, node, selected, changed, files_id)
				if pressed && node.is_dir && !renaming(.Tree, node.path) {
					g.pending = Toggle_Node(index)
				}

				if node.is_dir && creating_in(node.path) {
					new_entry_row(node.depth + 1)
				}
			}
		}

		shelf(r.h * 0.45)
	}
}


// The folder's name and the open folder button, laid out like a pane's header,
// level with the panes' titles
@(private = "file")
sidebar_header :: proc() {
	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(PANE_HEADER_HEIGHT)},
			padding = {left = 12, right = 4},
			childGap = 2,
			childAlignment = {y = .Center},
		},
	}) {
		name_id := clay.ID("FolderName")
		if clay.UI(name_id)({}) {
			name := strings.to_upper(folder_name(g.workspace.root), context.temp_allocator)
			label(name, gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		}
		tooltip(name_id, g.workspace.root)

		push_right()
		if icon_button(clay.ID("OpenButton"), .Folder_Open, 22, 14, "Open folder") {
			show_open_folder_dialog()
		}
	}
}


// A tree row's element id. It follows the path, not the row's place, so a
// press matched against last frame's layout finds the same file after the tree
// changed (a rename re-sorts it)
tree_row_id :: proc(path: string) -> clay.ElementId {
	return clay.ID("TreeRow", hash.fnv32a(transmute([]u8)path))
}


// The node of the tree row under the pointer, if any
tree_row_under_pointer :: proc() -> (index: int, ok: bool) {
	if !g.sidebar_visible || !pointer_in(clay.ID("SidebarFiles")) {
		return
	}

	for i in g.workspace.visible {
		if pointer_in(tree_row_id(g.workspace.nodes[i].path)) do return i, true
	}
	return
}


// One explorer row: indent, chevron for directories, name, and a dot for an
// open file with unsaved changes. Returns true when pressed
@(private = "file")
tree_row :: proc(
	index: int,
	node: Node,
	selected, modified: bool,
	list: clay.ElementId,
) -> bool {
	id := tree_row_id(node.path)

	if list_row(id, selected, 22, u16(2 + node.depth * 12)) {
		if node.is_dir {
			icon(node.expanded ? .Chevron_Down : .Chevron_Right, gfx.theme.text_dim)
		} else {
			spacer_x(16)
		}

		if renaming(.Tree, node.path) {
			rename_field(FONT_SIZE_SIDEBAR)
		} else {
			label(node.name, selected ? gfx.theme.text : gfx.theme.text_dim, FONT_SIZE_SIDEBAR)
			if modified do label(" •", gfx.theme.text_dim, FONT_SIZE_SIDEBAR)
		}
	}

	return clicked(id, list)
}


// The row a new file or folder is named in, at the top of its folder
@(private = "file")
new_entry_row :: proc(depth: int) {
	if list_row(clay.ID("NewEntryRow"), false, 22, u16(2 + depth * 12)) {
		if g.rename.create == .Folder {
			icon(.Chevron_Right, gfx.theme.text_dim)
		} else {
			spacer_x(16)
		}
		rename_field(FONT_SIZE_SIDEBAR)
	}
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

		// The focused pane
		if e := focused_editor(); e != nil {
			editor_status(e)
		} else if p := g.panes.focused; p != nil {
			label(pane_title(p), gfx.theme.text, FONT_SIZE_SMALL)
		}

		// The window, on the right
		push_right()
		size := fmt.tprintf("%dx%d @%.2fx", g.window_w, g.window_h, gfx.scale)
		label(size, gfx.theme.text_dim, FONT_SIZE_SMALL)
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

		if icon_button(
			clay.ID("TerminalToggle"),
			.Terminal,
			20,
			15,
			"Toggle terminal",
			first_chord_label(.Toggle_Terminal),
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
	case g.dialog.open, g.menu.open && pointer_in(clay.ID("ContextMenu")):
		// The arrow over popups that cover what is under them
	case g.finder.open:
		if pointer_in(clay.ID("FinderInput")) do want = .TEXT
	case g.settings_window.open && !ui_interactive():
		if settings_window_over_text() do want = .TEXT
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
		case .Text:  return over_text && e.scrollbar_drag == nil ? .TEXT : .DEFAULT
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
