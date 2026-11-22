package editor

import "core:hash"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "fuzzy"
import "gfx"

// The sidebar is the window's background at its left edge: the folder's name,
// a search field over its files, the file tree (or the files the search
// matches) and the shelf, flat on the window's color and always laid out. The
// panes sit beside it (work_rect). Hiding it moves their left edge over it
// while it fades into the window, and showing it moves them back as it fades
// in, so it seems to have been under them all along


FONT_SIZE_SIDEBAR :: 13
SIDEBAR_WIDTH     :: 240 // its content, right of a PANE_GAP margin

// The key hint at the search field's right: a size under the placeholder, whose
// lower-case letters look smaller than the hint's capitals at the same size
@(private = "file")
SEARCH_HINT_SIZE :: FONT_SIZE_SMALL - 1

@(private = "file")
TREE_ROW_HEIGHT :: 22

// The search field above the tree
Sidebar_Search :: struct {
	field:    Line_Edit,
	typing:   bool,   // the field has the keys
	search:   Search, // the files matching the field, while it isn't empty
	selected: int,    // a row of search.results
	reveal:   bool,   // scroll the selected row into view when next laid out
}


// --- Per frame ---------------------------------------------------------------------

// Before the panes' frames: a press outside the search field, or hiding the
// sidebar, takes the field's keys; hiding it drops a rename in it; the search
// takes its next step
sidebar_frame :: proc() {
	s := &g.sidebar_search

	pressed := g.mouse_pressed || g.right_pressed
	on_field := pointer_on_sidebar() && pointer_in(clay.ID("SidebarSearch"))
	if (pressed && !on_field) || !g.sidebar_visible {
		s.typing = false
	}

	// Its fields fade with it, so they can't keep the keys
	r := &g.rename
	in_sidebar := r.place == .Tree || r.place == .Shelf
	if r.active && in_sidebar && !g.sidebar_visible {
		rename_end()
	}

	// The finder's search, while it is open, has the frame's time
	if sidebar_search_active() && !g.finder.open {
		finder_ensure_index()
		search_step(&s.search, line_edit_string(&s.field))
	}
}


// Find file: the sidebar's search field while the sidebar shows, its query
// selected so typing replaces it; else the finder
find_file :: proc() {
	if !g.sidebar_visible {
		finder_toggle()
		return
	}

	s := &g.sidebar_search
	if g.finder.open do finder_close()
	s.typing = true
	line_edit_select_all(&s.field)
}


// Whether the search field holds a query, so its files show in place of the tree
sidebar_search_active :: proc() -> bool {
	return len(g.sidebar_search.field.text) > 0
}


// Whether the search still has files to score
sidebar_search_busy :: proc() -> bool {
	if !sidebar_search_active() || g.finder.open {
		return false
	}
	return g.finder.indexing || search_busy(&g.sidebar_search.search)
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
// area as last laid out (it eases with the panes: work_area)
pointer_on_sidebar :: proc() -> bool {
	return g.sidebar_visible &&
	       pointer_in(clay.ID("Sidebar")) &&
	       !pointer_in(clay.ID("WorkArea"))
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


// The file of the tree row or search result under the pointer, if any
sidebar_file_under_pointer :: proc() -> (path: string, ok: bool) {
	if sidebar_search_active() {
		if !pointer_on_sidebar() || !pointer_in(clay.ID("SidebarResults")) {
			return
		}
		for m in g.sidebar_search.search.results {
			file := g.finder.files[m.index]
			if pointer_in(search_row_id(file)) do return file, true
		}
		return
	}

	index := tree_row_under_pointer() or_return
	node := g.workspace.nodes[index]
	if node.is_dir do return
	return node.path, true
}


// The node of the tree row under the pointer, if any
tree_row_under_pointer :: proc() -> (index: int, ok: bool) {
	if sidebar_search_active() || !pointer_on_sidebar() {
		return
	}
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


// A search result's element id, by path as a tree row's
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

// Keys while the search field has them: the field's own, Up/Down through the
// files, Enter to open one, Esc to empty it. Other shortcuts give the keys back
// to the panes and run
sidebar_search_handle_event :: proc(event: ^sdl.Event) -> bool {
	s := &g.sidebar_search
	if !s.typing do return false

	if handled, changed := line_edit_event(&s.field, event); handled {
		if changed {
			search_rank_files(&s.search)
			sidebar_search_restart()
		}
		return true
	}
	if event.type != .KEY_DOWN do return true

	last := len(s.search.results) - 1
	switch event.key.key {
	case sdl.K_ESCAPE:
		sidebar_search_close()
	case sdl.K_UP:
		select_result(max(s.selected - 1, 0))
	case sdl.K_DOWN:
		select_result(min(s.selected + 1, last))
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		open_result(s.selected)
	case:
		cmd, is_command := command_for_key(event.key)
		if is_command && field_lets_through(cmd) {
			s.typing = false
			run_command(cmd)
		}
	}
	return true
}


// Selects a search result, to be scrolled into view
@(private = "file")
select_result :: proc(row: int) {
	s := &g.sidebar_search
	s.selected = max(row, 0)
	s.reveal = true
}


// Opens a search result as a press on a tree row does, giving it the keys
@(private = "file")
open_result :: proc(row: int) {
	s := &g.sidebar_search
	if row < 0 || row >= len(s.search.results) {
		return
	}

	path := g.finder.files[s.search.results[row].index]
	if g.pending == nil {
		g.pending = Open_File(strings.clone(path))
		sidebar_search_close()
	}
}


// Empties the search field, bringing the tree back, and gives back the keys
// (Escape, or a result opened)
sidebar_search_close :: proc() {
	s := &g.sidebar_search
	line_edit_clear(&s.field)
	sidebar_search_restart()
	s.typing = false
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

		if sidebar_search_active() {
			search_results()
		} else {
			tree()
		}

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
		if icon_button(clay.ID("OpenButton"), .Folder_Open, 22, 14, "Open folder") {
			show_open_folder_dialog()
		}
	}
}


// The search field, with a button that empties it over its right end. A press
// on it gives it the keys
@(private = "file")
search_field :: proc() {
	s := &g.sidebar_search
	id := clay.ID("SidebarSearch")
	if clicked(id) do s.typing = true

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 6, right = 6, bottom = 6},
		},
	}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {
			look := Field_Look{height = 26, size = FONT_SIZE_SMALL, padding = 8}
			text_field(id, &s.field, "Search files", s.typing, look)

			// Its right end: the button that empties it, else the key that finds files
			if sidebar_search_active() {
				clear_button()
			} else {
				key_hint()
			}
		}
	}
}


// The first key bound to Find file, dim at the right of the empty field, which
// that key gives the keys to. Floating, so it fades with the sidebar on its own
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


// Floating over the field, so it fades with the sidebar on its own
@(private = "file")
clear_button :: proc() {
	s := &g.sidebar_search
	if clay.UI(clay.ID("SidebarSearchClearBox"))({
		floating = {
			attachTo = .Parent,
			attachment = {element = .RightCenter, parent = .RightCenter},
			offset = {-3, 0},
		},
		overlayColor = sidebar_fade(),
		transition = sidebar_fade_transition(),
	}) {
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


// The files matching the search field, in place of the tree. A press opens one
// or drags it into a pane, as a tree row (see drag_mouse)
@(private = "file")
search_results :: proc() {
	s := &g.sidebar_search
	list := clay.ID("SidebarResults")
	wheel_scroll_list(list)

	if s.reveal {
		scroll_to_selected(list)
		s.reveal = false
	}

	// Clipped only vertically, so the rows fit the sidebar and cut their own text
	if clay.UI(list)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {bottom = 4},
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		if len(s.search.results) == 0 {
			if clay.UI()({layout = {padding = {left = 14, top = 3}}}) {
				label(results_message(), gfx.theme.text_faint, FONT_SIZE_SIDEBAR)
			}
			return
		}

		query := line_edit_string(&s.field)
		for m, i in s.search.results {
			path := g.finder.files[m.index]
			result_row(path, finder_display_path(m.index), query, i == s.selected)
		}
	}
}


// Scrolls the results' list (as last laid out) to show the selected row
@(private = "file")
scroll_to_selected :: proc(list: clay.ElementId) {
	scroll := clay.GetScrollContainerData(list)
	if !scroll.found do return

	// scrollPosition is negative: content offset upward
	top := f32(g.sidebar_search.selected) * TREE_ROW_HEIGHT
	view := scroll.scrollContainerDimensions.height
	if top < -scroll.scrollPosition.y {
		scroll.scrollPosition.y = -top
	} else if top + TREE_ROW_HEIGHT > -scroll.scrollPosition.y + view {
		scroll.scrollPosition.y = -(top + TREE_ROW_HEIGHT - view)
	}
}


// Why no file is listed
@(private = "file")
results_message :: proc() -> string {
	switch {
	case g.finder.indexing, search_busy(&g.sidebar_search.search):
		return "Searching…"
	case len(g.finder.files) == 0:
		return "No files in this folder"
	}
	return "No matching files"
}


// A file the search found: its name, then its folder, with the matched
// characters highlighted
@(private = "file")
result_row :: proc(path, shown, query: string, selected: bool) {
	if list_row(search_row_id(path), selected, TREE_ROW_HEIGHT, 8) {
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
			clip = {horizontal = true},
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
	}
}
