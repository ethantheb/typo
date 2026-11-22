package editor

import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"
import "langs"
import "textedit"

// The right-click menu: on a file or folder in the tree, on a pane's title, on
// a terminal on the shelf, or on an editor's text. A chosen item runs at the
// start of the next frame (context_menu_frame). A press outside the menu, or
// Esc, closes it


Menu_Command :: enum {
	New_File,
	New_Folder,
	Rename_File,
	Delete_File,
	Rename_Terminal,
	Restart_Terminal,
	Close_Pane,
	Editor_Command, // runs the item's `command` in the editor
}

Menu_Item :: struct {
	label:     string,
	icon:      gfx.Icon,
	cmd:       Menu_Command,
	danger:    bool,
	command:   Command, // of an Editor_Command item, its shortcut shown beside it
	disabled:  bool,
	separator: bool, // a line between groups, not an item
}

Context_Menu :: struct {
	open:   bool,
	at:     [2]f32,
	items:  [MENU_MAX_ITEMS]Menu_Item,
	count:  int,
	path:   string,       // owned; the file or folder it is for
	pane:   ^Pane,        // the pane it is for
	place:  Rename_Place, // where it was opened, where Rename edits the name
	chosen: Maybe(Menu_Command),
	chosen_index: int,    // the item chosen
	opened: u64,          // frame
}

MENU_WIDTH            :: 180
MENU_WIDTH_SHORTCUTS  :: 240 // with shortcuts beside the items
MENU_ROW_HEIGHT       :: 28
MENU_SEPARATOR_HEIGHT :: 9
MENU_MAX_ITEMS        :: 9

@(private = "file")
FILE_ITEMS := [?]Menu_Item {
	{label = "Rename", icon = .Pencil, cmd = .Rename_File},
	{label = "Delete", icon = .Trash,  cmd = .Delete_File, danger = true},
}

// A folder; with path the workspace root, the empty space under the tree
@(private = "file")
FOLDER_ITEMS := [?]Menu_Item {
	{label = "New file",   icon = .File_Plus,   cmd = .New_File},
	{label = "New folder", icon = .Folder_Plus, cmd = .New_Folder},
	{label = "Rename",     icon = .Pencil,      cmd = .Rename_File},
	{label = "Delete",     icon = .Trash,       cmd = .Delete_File, danger = true},
}

@(private = "file")
TERMINAL_ITEMS := [?]Menu_Item {
	{label = "Rename",  icon = .Pencil,  cmd = .Rename_Terminal},
	{label = "Restart", icon = .Restart, cmd = .Restart_Terminal},
	{label = "Close",   icon = .Close,   cmd = .Close_Pane},
}

@(private = "file")
FILE_PANE_ITEMS := [?]Menu_Item {
	{label = "Rename", icon = .Pencil, cmd = .Rename_File},
	{label = "Delete", icon = .Trash,  cmd = .Delete_File, danger = true},
	{label = "Close",  icon = .Close,  cmd = .Close_Pane},
}

// On an editor's text, each running its command (open_editor_menu sets them up
// and turns off what doesn't apply)
@(private = "file")
EDITOR_ITEMS := [?]Menu_Item {
	{label = "Go to definition", icon = .Go_To,      command = .Go_To_Definition},
	{label = "Find references",  icon = .Search,     command = .Find_References},
	{label = "Rename symbol",    icon = .Pencil,     command = .Rename_Symbol},
	{separator = true},
	{label = "Cut",              icon = .Scissors,   command = .Cut},
	{label = "Copy",             icon = .Copy,       command = .Copy},
	{label = "Paste",            icon = .Clipboard,  command = .Paste},
	{separator = true},
	{label = "Select all",       icon = .Select_All, command = .Select_All},
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
		if pointer_on_sidebar() && on_shelf {
			menu_open(TERMINAL_ITEMS[:], "", p, .Shelf)
			return
		}
	}

	// An editor's text
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if !is_editor || !pane_live(p) || e.status != .Text {
			continue
		}
		if pointer_in(clay.ID("PaneBody", p.id)) && editor_text_hit(e, g.mouse_pos) {
			open_editor_menu(p, e)
			return
		}
	}

	// A file or folder in the tree, or the space under it
	if index, ok := tree_row_under_pointer(); ok {
		node := g.workspace.nodes[index]
		items := node.is_dir ? FOLDER_ITEMS[:] : FILE_ITEMS[:]
		menu_open(items, node.path, nil, .Tree)
	} else if pointer_on_sidebar() && pointer_in(clay.ID("SidebarFiles")) {
		menu_open(FOLDER_ITEMS[:2], g.workspace.root, nil, .Tree)
	}
}


// The menu on an editor's text: a click outside the selection first moves the
// caret there, as in other editors, so the items act on what was clicked
@(private = "file")
open_editor_menu :: proc(p: ^Pane, e: ^Editor) {
	offset := e.kind.offset_at(e, g.mouse_pos)
	inside := false
	for s in e.sels {
		lo, hi := textedit.sel_lo(s), textedit.sel_hi(s)
		if lo != hi && offset >= lo && offset <= hi {
			inside = true
		}
	}
	if !inside {
		textedit.show_caret(e, false)
		textedit.set_single_selection(e, {offset, offset, -1})
		textedit.normalize(e)
	}
	pane_focus(p)

	// What applies here
	has_selection := false
	for s in e.sels {
		if s.anchor != s.head do has_selection = true
	}
	items := EDITOR_ITEMS
	for &item in items {
		if !item.separator do item.cmd = .Editor_Command
		#partial switch item.command {
		case .Go_To_Definition: item.disabled = langs.client_with(&e.lsp, .Definition) == nil
		case .Find_References:  item.disabled = langs.client_with(&e.lsp, .References) == nil
		case .Rename_Symbol:    item.disabled = langs.client_with(&e.lsp, .Rename) == nil
		case .Cut, .Copy:       item.disabled = !has_selection
		}
	}
	menu_open(items[:], "", p, .Title)
}


@(private = "file")
run_menu_command :: proc(cmd: Menu_Command) {
	m := &g.menu

	switch cmd {
	case .Editor_Command:
		// The item's command, in the editor the menu is on
		e, is_editor := m.pane.content.(^Editor)
		if is_editor do editor_run_command(e, m.items[m.chosen_index].command)
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


@(private = "file")
menu_separator :: proc() {
	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(MENU_SEPARATOR_HEIGHT)},
			padding = {left = 8, right = 8, top = 4},
		},
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}},
			backgroundColor = gfx.theme.border,
		}) {}
	}
}


context_menu_ui :: proc() {
	m := &g.menu
	if !m.open do return

	g.in_popup = true
	defer g.in_popup = false

	// Wider with shortcuts beside the items
	width: f32 = MENU_WIDTH
	h: f32 = 8 + (m.path != "" ? 26 : 0)
	for item in m.items[:m.count] {
		if item.cmd == .Editor_Command do width = MENU_WIDTH_SHORTCUTS
		h += item.separator ? MENU_SEPARATOR_HEIGHT : MENU_ROW_HEIGHT
	}

	// Below the pointer, or above it where there is no room below
	x := clamp(m.at.x, 4, f32(g.window_w) - width - 4)
	y := m.at.y
	if y + h > f32(g.window_h) - 4 {
		y = max(m.at.y - h, 4)
	}

	if clay.UI(clay.ID("ContextMenu"))({
		layout = {
			sizing = {width = clay.SizingFixed(width)},
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
			if item.separator {
				menu_separator()
				continue
			}

			// Its colors: red for a danger, faint while it doesn't apply
			id := clay.ID("MenuItem", u32(i))
			text_color := item.danger ? gfx.theme.error : gfx.theme.text
			icon_color := item.danger ? gfx.theme.error : gfx.theme.text_dim
			if item.disabled {
				text_color, icon_color = gfx.theme.text_faint, gfx.theme.text_faint
			}

			if clay.UI(id)({
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingFixed(MENU_ROW_HEIGHT)},
					padding = {left = 8, right = 8},
					childGap = 9,
					childAlignment = {y = .Center},
				},
				backgroundColor = clay.Hovered() && !item.disabled ? gfx.theme.hover : {},
				cornerRadius = clay.CornerRadiusAll(5),
			}) {
				icon(item.icon, icon_color, 14)
				label(item.label, text_color, FONT_SIZE_SIDEBAR)
				if item.cmd == .Editor_Command {
					push_right()
					label(first_chord_label(item.command), gfx.theme.text_faint, FONT_SIZE_SMALL)
				}
			}

			if clicked(id) && !item.disabled {
				m.chosen = item.cmd
				m.chosen_index = i
			}
		}
	}
}
