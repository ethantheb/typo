package editor

import "core:hash"
import "core:path/filepath"

import clay "../vendor/clay-odin"
import "gfx"

// RECENT, the sidebar's section above the shelf: the project's pinned files,
// each with a pin, then its most recently used files (recent.odin), as many
// as the recent_files setting asks for, not repeating a pinned one. A row acts
// as a tree row: a click opens its file in place of the editor in use, a press
// can drag it into a pane (drag_press), and the focused file's row is
// selected. A right-click pins or unpins (context_menu.odin). The section
// isn't shown while it would list nothing


Recent_Row :: struct {
	path:   string, // full path
	pinned: bool,
}


// The rows, in the temp allocator: the pinned files, then the recent ones
recent_rows :: proc() -> []Recent_Row {
	rows := make([dynamic]Recent_Row, context.temp_allocator)
	for pin in g.project.pinned {
		append(&rows, Recent_Row{pin, true})
	}

	listed := 0
	for path in recent_files() {
		if listed >= g.settings.recent_files do break
		if project_pinned(path) do continue

		append(&rows, Recent_Row{path, false})
		listed += 1
	}
	return rows[:]
}


// A row's element id. It follows the path, as a tree row's does
recent_row_id :: proc(path: string) -> clay.ElementId {
	return clay.ID("RecentRow", hash.fnv32a(transmute([]u8)path))
}


// The file of the row under the pointer, if any
recent_file_under_pointer :: proc() -> (path: string, ok: bool) {
	if !pointer_on_sidebar() || !pointer_in(clay.ID("RecentList")) {
		return
	}

	for row in recent_rows() {
		if pointer_in(recent_row_id(row.path)) do return row.path, true
	}
	return
}


// --- UI ----------------------------------------------------------------------------

// The section: a heading as the shelf's, then the rows, scrolling past
// `max_height`
recent_section :: proc(max_height: f32) {
	rows := recent_rows()
	if len(rows) == 0 do return

	if clay.UI(clay.ID("Recent"))({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {top = 4, bottom = 4},
		},
		border = {color = gfx.theme.border, width = {top = 1}},
	}) {
		// The heading, as tall as the shelf's with its button
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(26)},
				padding = {left = 12, right = 6},
				childAlignment = {y = .Center},
			},
		}) {
			label("RECENT", gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		}

		// The rows
		list := clay.ID("RecentList")
		wheel_scroll_list(list)
		if clay.UI(list)({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFit({max = max_height})},
				layoutDirection = .TopToBottom,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			selected := tree_selected_file()
			for row in rows {
				recent_row(row, selected != "" && same_path(row.path, selected))
			}
		}
	}
}


// A file: a pin if pinned, else its kind's icon, then its name and, dimmer, its
// folder in the project. Its whole path shows in a tooltip
@(private = "file")
recent_row :: proc(row: Recent_Row, selected: bool) {
	id := recent_row_id(row.path)
	rel := project_rel(row.path)

	if list_row(id, selected, SHELF_ROW_HEIGHT, 8, 7) {
		if row.pinned {
			icon(.Pin, selected ? gfx.theme.accent : gfx.theme.text_dim, 14)
		} else {
			icon(file_icon(row.path), selected ? gfx.theme.accent : gfx.theme.text_faint, 14)
		}

		// Clipped, so a long name cuts off instead of widening the sidebar
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
			clip = row_clip(),
		}) {
			name := selected ? gfx.theme.text : gfx.theme.text_dim
			label(filepath.base(row.path), name, FONT_SIZE_SIDEBAR)

			folder := filepath.dir(rel)
			if folder != "." && folder != "" {
				spacer_x(8)
				label(folder, selected ? gfx.theme.text_dim : gfx.theme.text_faint, FONT_SIZE_SMALL)
			}
		}
	}
	tooltip(id, rel)
}
