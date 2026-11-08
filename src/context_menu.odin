package editor

import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"

// The right-click menu: on a file or folder in the tree, on a pane's title, or
// on a terminal on the shelf. A chosen item runs at the start of the next frame
// (context_menu_frame). A press outside the menu, or Esc, closes it


Menu_Command :: enum {
	New_File,
	New_Folder,
	Rename_File,
	Delete_File,
	Rename_Terminal,
	Restart_Terminal,
	Close_Pane,
}

Menu_Item :: struct {
	label:  string,
	icon:   gfx.Icon,
	cmd:    Menu_Command,
	danger: bool,
}

Context_Menu :: struct {
	open:   bool,
	at:     [2]f32,
	items:  [4]Menu_Item,
	count:  int,
	path:   string,       // owned; the file or folder it is for
	pane:   ^Pane,        // the pane it is for
	place:  Rename_Place, // where it was opened, where Rename edits the name
	chosen: Maybe(Menu_Command),
	opened: u64,          // frame
}

MENU_WIDTH      :: 180
MENU_ROW_HEIGHT :: 28

@(private = "file")
FILE_ITEMS := [?]Menu_Item {
	{"Rename", .Pencil, .Rename_File, false},
	{"Delete", .Trash,  .Delete_File, true},
}

// A folder; with path the workspace root, the empty space under the tree
@(private = "file")
FOLDER_ITEMS := [?]Menu_Item {
	{"New file",   .File_Plus,   .New_File,    false},
	{"New folder", .Folder_Plus, .New_Folder,  false},
	{"Rename",     .Pencil,      .Rename_File, false},
	{"Delete",     .Trash,       .Delete_File, true},
}

@(private = "file")
TERMINAL_ITEMS := [?]Menu_Item {
	{"Rename",  .Pencil,  .Rename_Terminal,  false},
	{"Restart", .Restart, .Restart_Terminal, false},
	{"Close",   .Close,   .Close_Pane,       false},
}

@(private = "file")
FILE_PANE_ITEMS := [?]Menu_Item {
	{"Rename", .Pencil, .Rename_File, false},
	{"Delete", .Trash,  .Delete_File, true},
	{"Close",  .Close,  .Close_Pane,  false},
}


@(private = "file")
menu_open :: proc(items: []Menu_Item, path: string, pane: ^Pane, place: Rename_Place) {
	menu_close()

	m := &g.menu
	m.open = true
	m.at = g.mouse_pos
	m.count = copy(m.items[:], items)
	m.path = strings.clone(path)
	m.pane = pane
	m.place = place
	m.opened = g.frame
}


menu_close :: proc() {
	m := &g.menu
	delete(m.path)
	m^ = {}
}


// Before the panes' frames: runs a chosen item, closes the menu on a press
// outside it (which does nothing else), opens one on a right-click
context_menu_frame :: proc() {
	m := &g.menu

	if cmd, ok := m.chosen.?; ok {
		m.chosen = nil
		run_menu_command(cmd)
		menu_close()
	}

	// A press outside closes it
	pressed := g.mouse_pressed || g.right_pressed
	if m.open && pressed && m.opened != g.frame && !pointer_in(clay.ID("ContextMenu")) {
		menu_close()
		g.mouse_pressed = false
	}

	if !g.right_pressed || !ui_interactive() || g.panes.drag.pane != nil {
		return
	}

	// A pane's title, or a terminal on the shelf
	for p in g.panes.open {
		if pane_live(p) && pointer_in(clay.ID("PaneTitle", p.id)) {
			switch c in p.content {
			case ^Editor:   menu_open(FILE_PANE_ITEMS[:], c.path, p, .Title)
			case ^Terminal: menu_open(TERMINAL_ITEMS[:], "", p, .Title)
			}
			return
		}

		on_shelf := pointer_in(clay.ID("ShelfRow", p.id)) && pointer_in(clay.ID("ShelfList"))
		if g.sidebar_visible && on_shelf {
			menu_open(TERMINAL_ITEMS[:], "", p, .Shelf)
			return
		}
	}

	// A file or folder in the tree, or the space under it
	if index, ok := tree_row_under_pointer(); ok {
		node := g.workspace.nodes[index]
		items := node.is_dir ? FOLDER_ITEMS[:] : FILE_ITEMS[:]
		menu_open(items, node.path, nil, .Tree)
	} else if g.sidebar_visible && pointer_in(clay.ID("SidebarFiles")) {
		menu_open(FOLDER_ITEMS[:2], g.workspace.root, nil, .Tree)
	}
}


@(private = "file")
run_menu_command :: proc(cmd: Menu_Command) {
	m := &g.menu

	switch cmd {
	case .New_File:        create_start(m.path, folder = false)
	case .New_Folder:      create_start(m.path, folder = true)
	case .Rename_File:     rename_start_file(m.path, m.place, m.pane)
	case .Delete_File:     ask_delete_file(m.path)
	case .Rename_Terminal: rename_start_terminal(m.pane, m.place)
	case .Close_Pane:      pane_close(m.pane)
	case .Restart_Terminal:
		if t, ok := m.pane.content.(^Terminal); ok {
			terminal_restart(t)
			pane_show(m.pane)
		}
	}
}


context_menu_ui :: proc() {
	m := &g.menu
	if !m.open do return

	g.in_popup = true
	defer g.in_popup = false

	// Below the pointer, or above it where there is no room below
	header: f32 = m.path != "" ? 26 : 0
	h := f32(m.count) * MENU_ROW_HEIGHT + 8 + header
	x := clamp(m.at.x, 4, f32(g.window_w) - MENU_WIDTH - 4)
	y := m.at.y
	if y + h > f32(g.window_h) - 4 {
		y = max(m.at.y - h, 4)
	}

	if clay.UI(clay.ID("ContextMenu"))({
		layout = {
			sizing = {width = clay.SizingFixed(MENU_WIDTH)},
			layoutDirection = .TopToBottom,
			padding = {4, 4, 4, 4},
		},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 120},
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		// The name of what it is for
		if m.path != "" {
			if clay.UI()({
				layout = {
					sizing = {width = clay.SizingGrow()},
					padding = {left = 8, right = 8, top = 2, bottom = 4},
				},
				clip = {horizontal = true},
			}) {
				label(filepath.base(m.path), gfx.theme.text_faint, FONT_SIZE_SMALL)
			}
		}

		for item, i in m.items[:m.count] {
			id := clay.ID("MenuItem", u32(i))
			if clay.UI(id)({
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingFixed(MENU_ROW_HEIGHT)},
					padding = {left = 8, right = 8},
					childGap = 9,
					childAlignment = {y = .Center},
				},
				backgroundColor = clay.Hovered() ? gfx.theme.hover : {},
				cornerRadius = clay.CornerRadiusAll(5),
			}) {
				icon(item.icon, item.danger ? gfx.theme.error : gfx.theme.text_dim, 14)
				label(item.label, item.danger ? gfx.theme.error : gfx.theme.text, FONT_SIZE_SIDEBAR)
			}

			if clicked(id) do m.chosen = item.cmd
		}
	}
}
