package editor

import "core:hash"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "fuzzy"
import "gfx"

// The sidebar is the window's background at its left edge: the folder's name,
// a search field over its files, the file tree, the recent files
// (sidebar_recent.odin) and the shelf, flat on the window's color and always
// laid out. The panes sit beside it (work_rect). Hiding it moves their left
// edge over it while it fades into the window, and showing it moves them back
// as it fades in, so it seems to have been under them all along.
//
// The search field opens a popup as a browser's address bar does: a panel grows
// out of the field, over the panes, with the field at its top and the files
// that match under it (open and recent ones first, and with no query only
// those, as the finder lists them)


FONT_SIZE_SIDEBAR :: 13
SIDEBAR_WIDTH     :: 240 // its content, right of a PANE_GAP margin

// The key hint at the search field's right: a size under the placeholder, whose
// lower-case letters look smaller than the hint's capitals at the same size
@(private = "file")
SEARCH_HINT_SIZE :: FONT_SIZE_SMALL - 1

@(private = "file")
TREE_ROW_HEIGHT :: 22

// The search field, inset from the sidebar's sides
@(private = "file")
FIELD_HEIGHT :: 26
@(private = "file")
FIELD_INSET :: 6
@(private = "file")
FIELD_WIDTH :: SIDEBAR_WIDTH - 2 * FIELD_INSET

// The popup: around the field by POPUP_PAD, its rows under it
@(private = "file")
POPUP_WIDTH :: 460
@(private = "file")
POPUP_PAD :: 4
@(private = "file")
POPUP_ROW_HEIGHT :: 24
@(private = "file")
POPUP_ROWS :: 12 // listed before the rows scroll
@(private = "file")
POPUP_SECONDS :: 0.12 // growing out of the field

// The search field above the tree, and its popup
Sidebar_Search :: struct {
	field:    Line_Edit,
	open:     bool,       // the popup shows, and the field has the keys
	search:   Search,     // the files matching the field, while open
	selected: int,        // a row of search.results
	reveal:   bool,       // scroll the selected row into view when next laid out
	clicked:  Maybe(int), // a file (in g.finder.files) clicked in the popup, opened next frame
}


// --- Per frame ---------------------------------------------------------------------

// Before the panes' frames: a file clicked in the popup opens; a press outside
// the popup, or hiding the sidebar, closes it; hiding it drops a rename in it;
// the search takes its next step
sidebar_frame :: proc() {
	s := &g.sidebar_search

	// Clicked in the last frame's popup, whose rows that frame's drawing used
	if file, was_clicked := s.clicked.?; was_clicked {
		s.clicked = nil
		open_file(file)
	}

	pressed := g.mouse_pressed || g.right_pressed
	on_popup := pointer_in(clay.ID("SidebarSearchPopup"))
	if s.open && ((pressed && !on_popup) || !g.sidebar_visible) {
		s.open = false
	}

	// Its fields fade with it, so they can't keep the keys
	r := &g.rename
	in_sidebar := r.place == .Tree || r.place == .Shelf
	if r.active && in_sidebar && !g.sidebar_visible {
		rename_end()
	}

	// The finder's search, while it is open, has the frame's time
	if s.open && !g.finder.open {
		finder_ensure_index()
		search_step(&s.search, line_edit_string(&s.field))
	}
}


// Find file: the sidebar's search popup while the sidebar shows, its query
// selected so typing replaces it; else the finder
find_file :: proc() {
	if !g.sidebar_visible {
		finder_toggle()
		return
	}

	if g.finder.open do finder_close()
	sidebar_search_open()
	line_edit_select_all(&g.sidebar_search.field)
}


// Opens the search's popup, giving the field the keys, with the open and
// recent files ranked first
sidebar_search_open :: proc() {
	s := &g.sidebar_search
	if s.open do return

	s.open = true
	s.clicked = nil
	search_rank_files(&s.search)
	sidebar_search_restart()
}


// Whether the search still has files to score, or a row to scroll to
sidebar_search_busy :: proc() -> bool {
	s := &g.sidebar_search
	if !s.open || g.finder.open {
		return false
	}
	return s.reveal || g.finder.indexing || search_busy(&s.search)
}


// Whether the search's popup is over the pointer, as last laid out
search_popup_covers_pointer :: proc() -> bool {
	return search_popup_shown() && pointer_in(clay.ID("SidebarSearchPopup"))
}


@(private = "file")
search_popup_shown :: proc() -> bool {
	return g.sidebar_search.open && g.sidebar_visible
}


// Scores the files again: the query or the index changed
sidebar_search_restart :: proc() {
	s := &g.sidebar_search
	search_restart(&s.search)
	s.selected = 0
}


sidebar_search_destroy :: proc() {
	s := &g.sidebar_search
	line_edit_destroy(&s.field)
	search_destroy(&s.search)
}


// Whether the pointer is on the sidebar while it shows, left of the panes'
// area as last laid out (it eases with the panes: work_area), and not on the
// search's popup over it
pointer_on_sidebar :: proc() -> bool {
	return g.sidebar_visible &&
	       pointer_in(clay.ID("Sidebar")) &&
	       !pointer_in(clay.ID("WorkArea")) &&
	       !search_popup_covers_pointer()
}


// The sidebar's fade: clear while it shows, the window's color while hidden.
// Its floating parts take it too, as Clay's overlays don't reach them
sidebar_fade :: proc() -> clay.Color {
	return window_overlay(g.sidebar_visible ? 0 : 255)
}


// Eases the sidebar's fade as the panes ease to their places
sidebar_fade_transition :: proc() -> clay.TransitionElementConfig {
	return transition({.OverlayColor})
}


// The file of the tree row or recent file under the pointer, if any, and which
// list it is in
sidebar_file_under_pointer :: proc() -> (path: string, source: Drag_Source, ok: bool) {
	if recent, on_recent := recent_file_under_pointer(); on_recent {
		return recent, .Recent, true
	}

	index := tree_row_under_pointer() or_return
	node := g.workspace.nodes[index]
	if node.is_dir do return
	return node.path, .Tree, true
}


// The node of the tree row under the pointer, if any
tree_row_under_pointer :: proc() -> (index: int, ok: bool) {
	if !pointer_on_sidebar() do return
	if !pointer_in(clay.ID("SidebarFiles")) do return

	for i in g.workspace.visible {
		if pointer_in(tree_row_id(g.workspace.nodes[i].path)) do return i, true
	}
	return
}


// A tree row's element id. It follows the path, not the row's place, so a
// press matched against last frame's layout finds the same file after the tree
// changed (a rename re-sorts it)
tree_row_id :: proc(path: string) -> clay.ElementId {
	return clay.ID("TreeRow", hash.fnv32a(transmute([]u8)path))
}


// A row of the search's popup, by path as a tree row's
search_row_id :: proc(path: string) -> clay.ElementId {
	return clay.ID("SearchRow", hash.fnv32a(transmute([]u8)path))
}


// The open files with unsaved changes and every folder they are in, below the
// workspace's folder, as path_key_ascii keys: what the tree marks with a dot
unsaved_marks :: proc(
	root: string,
	modified: []string,
	allocator := context.temp_allocator,
) -> map[string]bool {
	marks := make(map[string]bool, allocator = allocator)

	buf: [512]u8
	root_key := strings.clone(path_key_ascii(root, buf[:]), context.temp_allocator)
	root_key = strings.trim_right(root_key, "/\\") // a drive root like "C:\"

	for path in modified {
		key := strings.clone(path_key_ascii(path, buf[:]), allocator)
		marks[key] = true

		// Its folders, up to the workspace's
		dir := key
		for {
			cut := strings.last_index_any(dir, "/\\")
			if cut <= 0 do break

			dir = dir[:cut]
			inside := dir != root_key && path_within(dir, root_key)
			if !inside do break

			marks[dir] = true
		}
	}
	return marks
}


// --- Keys --------------------------------------------------------------------------

// Keys while the search's popup is open: the field's own, Up/Down and Page
// Up/Down through the files, Enter to open one, Esc to close it. Other
// shortcuts close it and run
sidebar_search_handle_event :: proc(event: ^sdl.Event) -> bool {
	s := &g.sidebar_search
	if !s.open do return false

	if handled, changed := line_edit_event(&s.field, event); handled {
		if changed do sidebar_search_restart()
		return true
	}
	if event.type != .KEY_DOWN do return true

	last := len(s.search.results) - 1
	switch event.key.key {
	case sdl.K_ESCAPE:
		sidebar_search_close()
	case sdl.K_UP:
		select_result(s.selected - 1)
	case sdl.K_DOWN:
		select_result(min(s.selected + 1, last))
	case sdl.K_PAGEUP:
		select_result(s.selected - POPUP_ROWS)
	case sdl.K_PAGEDOWN:
		select_result(min(s.selected + POPUP_ROWS, last))
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		if s.selected < len(s.search.results) {
			open_file(s.search.results[s.selected].index)
		}
	case:
		cmd, is_command := command_for_key(event.key)
		if is_command && field_lets_through(cmd) {
			s.open = false
			run_command(cmd)
		}
	}
	return true
}


// Selects a row of the popup, to be scrolled into view
@(private = "file")
select_result :: proc(row: int) {
	s := &g.sidebar_search
	s.selected = max(row, 0)
	s.reveal = true
}


// Opens a file of the index as a press on a tree row does (in place of the
// editor in use), and closes the popup
@(private = "file")
open_file :: proc(file: int) {
	if file < 0 || file >= len(g.finder.files) || g.pending != nil {
		return
	}

	g.pending = Open_File(strings.clone(g.finder.files[file]))
	sidebar_search_close()
}


// Empties the search field and closes its popup, giving back the keys (Escape,
// or a file opened)
sidebar_search_close :: proc() {
	s := &g.sidebar_search
	line_edit_clear(&s.field)
	sidebar_search_restart()
	s.open = false
}


// --- UI ----------------------------------------------------------------------------

// The sidebar, at the window's left edge beside the panes, faded into the
// window while they cover it
sidebar :: proc() {
	g.in_sidebar = true
	defer g.in_sidebar = false

	if clay.UI(clay.ID("Sidebar"))({
		layout = {
			sizing = {clay.SizingFixed(PANE_GAP + SIDEBAR_WIDTH), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = PANE_GAP, top = PANE_GAP, bottom = PANE_GAP + 4},
		},
		overlayColor = sidebar_fade(),
		transition = sidebar_fade_transition(),
	}) {
		sidebar_header()
		search_field()
		tree()
		recent_section(work_rect().h * 0.3)
		shelf(work_rect().h * 0.45)
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
		chord := first_chord_label(.Open_Project)
		if icon_button(clay.ID("OpenButton"), .Folder_Open, 22, 14, "Open project", chord) {
			project_picker_toggle()
		}
	}
}


// The search field's place. The field is in it while the popup is closed, and
// at the popup's top, over it, while open. A press on it opens the popup
@(private = "file")
search_field :: proc() {
	s := &g.sidebar_search
	if clicked(clay.ID("SidebarSearch")) do sidebar_search_open()

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = FIELD_INSET, right = FIELD_INSET, bottom = 6},
		},
	}) {
		slot := clay.ElementDeclaration {
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(FIELD_HEIGHT)}},
		}
		if clay.UI(clay.ID("SidebarSearchSlot"))(slot) {
			if !s.open do search_box(in_popup = false)
		}
	}
}


// The field, with a button that empties it over its right end, or while empty
// in the sidebar, the key that opens it
@(private = "file")
search_box :: proc(in_popup: bool) {
	s := &g.sidebar_search
	look := Field_Look{height = FIELD_HEIGHT, size = FONT_SIZE_SMALL, padding = 8}

	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {
		text_field(clay.ID("SidebarSearch"), &s.field, "Search files", s.open, look)

		if len(s.field.text) > 0 {
			clear_button(in_popup)
		} else if !in_popup {
			key_hint()
		}
	}
}


// The first key bound to Find file, dim at the right of the empty field, which
// that key opens. Floating, so it fades with the sidebar on its own
@(private = "file")
key_hint :: proc() {
	chord := first_chord_label(.Find_File)
	if chord == "" do return

	if clay.UI(clay.ID("SidebarSearchHint"))({
		floating = {
			attachTo = .Parent,
			attachment = {element = .RightCenter, parent = .RightCenter},
			offset = {-8, 0},
			pointerCaptureMode = .Passthrough,
		},
		overlayColor = sidebar_fade(),
		transition = sidebar_fade_transition(),
	}) {
		label(chord, gfx.theme.text_faint, SEARCH_HINT_SIZE)
	}
}


// Floating over the field: in the sidebar it fades with it on its own, and in
// the popup it is drawn over the popup and clipped to the field
@(private = "file")
clear_button :: proc(in_popup: bool) {
	s := &g.sidebar_search
	box := clay.ElementDeclaration {
		floating = {
			attachTo = .Parent,
			attachment = {element = .RightCenter, parent = .RightCenter},
			offset = {-3, 0},
		},
	}
	if in_popup {
		box.floating.zIndex = POPUP_LAYER + 1
		box.floating.clipTo = .AttachedParent
	} else {
		box.overlayColor = sidebar_fade()
		box.transition = sidebar_fade_transition()
	}

	if clay.UI(clay.ID("SidebarSearchClearBox"))(box) {
		id := clay.ID("SidebarSearchClear")
		if icon_button(id, .Close, 20, 12, "Clear", "Escape") {
			line_edit_clear(&s.field)
			sidebar_search_restart()
		}
	}
}


// The file whose tree row is selected: the focused file's, none while a
// terminal (or nothing) has the keys
tree_selected_file :: proc() -> string {
	e := focused_editor()
	return e != nil ? e.path : ""
}


// The file tree, with dots on files with unsaved changes and the folders they
// are in
@(private = "file")
tree :: proc() {
	files_id := clay.ID("SidebarFiles")
	wheel_scroll_list(files_id)
	selected_file := tree_selected_file()

	// Open files with unsaved changes, and their folders
	modified := make([dynamic]string, context.temp_allocator)
	for p in g.panes.open {
		e, is_file := p.content.(^Editor)
		if is_file && editor_is_modified(e) {
			append(&modified, e.path)
		}
	}
	marks := unsaved_marks(g.workspace.root, modified[:])

	if clay.UI(files_id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {bottom = 4},
		},
		clip = {horizontal = true, vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		if creating_in(g.workspace.root) do new_entry_row(0)

		buf: [512]u8
		for index in g.workspace.visible {
			node := g.workspace.nodes[index]
			selected := selected_file != "" && node.path == selected_file
			changed := len(marks) > 0 && path_key_ascii(node.path, buf[:]) in marks

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
}


// One explorer row: indent, chevron for directories, name, and a dot for an
// open file with unsaved changes or a folder holding one. Returns true when
// pressed
@(private = "file")
tree_row :: proc(
	index: int,
	node: Node,
	selected, modified: bool,
	list: clay.ElementId,
) -> bool {
	id := tree_row_id(node.path)

	if list_row(id, selected, TREE_ROW_HEIGHT, u16(2 + node.depth * 12)) {
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
	if list_row(clay.ID("NewEntryRow"), false, TREE_ROW_HEIGHT, u16(2 + depth * 12)) {
		if g.rename.create == .Folder {
			icon(.Chevron_Right, gfx.theme.text_dim)
		} else {
			spacer_x(16)
		}
		rename_field(FONT_SIZE_SIDEBAR)
	}
}


// --- The search's popup ------------------------------------------------------------


// The search's popup: a panel grown out of the search field's place in the
// sidebar, over the panes, with the field at its top (where it was) and the
// files that match under it. Declared after the sidebar, as popups are
sidebar_search_popup :: proc() {
	if !search_popup_shown() do return

	g.in_search_popup = true
	defer g.in_search_popup = false

	// As wide as the window leaves room for, at least the field's place
	slot_id := clay.ID("SidebarSearchSlot")
	slot, _ := element_rect(slot_id)
	room := f32(g.window_w) - PANE_GAP - slot.x + POPUP_PAD
	width := max(min(POPUP_WIDTH, room), slot.w + 2 * POPUP_PAD)

	// It grows out of the field, and eases as its rows come and go
	grow := transition(clay.TransitionPropertyBoundingBox, duration = POPUP_SECONDS)
	grow.enter.setInitialState = enter_from_field

	if clay.UI(clay.ID("SidebarSearchPopup"))({
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			padding = clay.PaddingAll(POPUP_PAD),
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		clip = {horizontal = true, vertical = true},
		floating = {
			attachTo = .ElementWithId,
			parentId = slot_id.id,
			offset = {-POPUP_PAD, -POPUP_PAD},
			zIndex = POPUP_LAYER,
		},
		transition = grow,
	}) {
		// Sized to the panel: Clay grows a clipping element's children to their
		// content, so a long path would widen the field past the panel's edge
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingFixed(width - 2 * POPUP_PAD)},
				layoutDirection = .TopToBottom,
				childGap = POPUP_PAD,
			},
		}) {
			search_box(in_popup = true)
			popup_results()
		}
	}
}


// Where the popup grows from: the field's place, around which it rests
@(private = "file")
enter_from_field :: proc "c" (
	target: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	start := target
	start.boundingBox.width = FIELD_WIDTH + 2 * POPUP_PAD
	start.boundingBox.height = FIELD_HEIGHT + 2 * POPUP_PAD
	return start
}


// The files that match, open and recent ones marked, or why none is listed
@(private = "file")
popup_results :: proc() {
	s := &g.sidebar_search
	if len(s.search.results) == 0 {
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(POPUP_ROW_HEIGHT)},
				padding = {left = 8},
				childAlignment = {y = .Center},
			},
		}) {
			label(results_message(), gfx.theme.text_faint, FONT_SIZE_SIDEBAR)
		}
		return
	}

	list := clay.ID("SidebarResults")
	wheel_scroll_list(list)
	if s.reveal {
		scroll := clay.GetScrollContainerData(list)
		list_reveal_row(scroll, s.selected, POPUP_ROW_HEIGHT)
		s.reveal = false
	}

	// Only the rows in view (and one more) are laid out, between spacers
	count := len(s.search.results)
	first := 0
	if scroll := clay.GetScrollContainerData(list); scroll.found {
		first = clamp(int(-scroll.scrollPosition.y / POPUP_ROW_HEIGHT), 0, count)
	}
	last := min(first + POPUP_ROWS + 1, count)

	rows := min(count, POPUP_ROWS)
	if clay.UI(list)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(f32(rows) * POPUP_ROW_HEIGHT)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		query := line_edit_string(&s.field)
		rows_gap(first)
		for i in first ..< last {
			m := s.search.results[i]
			rank, ranked, _ := search_file_rank(&s.search, m.index)
			mark := ""
			if ranked {
				mark = rank.open ? "open" : "recent"
			}

			path := g.finder.files[m.index]
			shown := finder_display_path(m.index)
			if popup_row(path, shown, query, mark, i == s.selected, list) {
				s.clicked = m.index
			}
		}
		rows_gap(count - last)
	}
}


// Room for rows of the popup not laid out
@(private = "file")
rows_gap :: proc(rows: int) {
	if rows <= 0 do return

	height := f32(rows) * POPUP_ROW_HEIGHT
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(height)}}}) {}
}


// Why no file is listed
@(private = "file")
results_message :: proc() -> string {
	switch {
	case g.finder.indexing, search_busy(&g.sidebar_search.search):
		return "Searching…"
	case len(g.finder.files) == 0:
		return "No files in this folder"
	case len(g.sidebar_search.field.text) == 0:
		return "No other files"
	}
	return "No matching files"
}


// A file: its name, then its folder, with the matched characters highlighted,
// and "open" or "recent" (`mark`) at the right. Its text lines up with the
// field's. Returns true when clicked
@(private = "file")
popup_row :: proc(
	path, shown, query, mark: string,
	selected: bool,
	list: clay.ElementId,
) -> bool {
	id := search_row_id(path)
	background: clay.Color
	if selected {
		background = gfx.theme.selected
	} else if pointer_in(id) && ui_interactive() {
		background = gfx.theme.hover
	}

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(POPUP_ROW_HEIGHT)},
			padding = {left = 8, right = 8},
			childAlignment = {y = .Center},
		},
		backgroundColor = background,
		cornerRadius = clay.CornerRadiusAll(5),
	}) {
		// Cut off before the mark
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
			clip = row_clip(),
		}) {
			slash := strings.last_index_any(shown, "/\\")
			matched := fuzzy.positions(query, shown, context.temp_allocator)

			name := selected ? gfx.theme.text_bright : gfx.theme.text
			end := len(shown)
			highlighted_text(shown, slash + 1, end, matched, name, .Body, FONT_SIZE_SIDEBAR)

			if slash > 0 {
				folder := gfx.theme.text_dim
				spacer_x(8)
				highlighted_text(shown, 0, slash, matched, folder, .Body, FONT_SIZE_SMALL)
			}
		}

		if mark != "" {
			spacer_x(8)
			label(mark, gfx.theme.text_faint, FONT_SIZE_SMALL)
		}
	}
	return clicked(id, list)
}
