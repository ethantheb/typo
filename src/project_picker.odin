package editor

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "fuzzy"
import "gfx"

// Recent projects: a small popup (Open project, or the sidebar's open folder
// button) listing the folders typo opened, most recent first (state.json),
// filtered as typed. Enter or a click opens one in this window; Ctrl+Enter or
// a row's window button in another typo window. Its last row shows the
// system's folder dialog, whose choice opens the same way. Under the open
// folder button while the sidebar shows, else at the top of the window


@(private = "file")
PICKER_WIDTH :: 400
@(private = "file")
PICKER_ROW_HEIGHT :: 28
@(private = "file")
PICKER_ROWS :: 8 // listed before the rows scroll
@(private = "file")
PICKER_PAD :: 6

Project_Picker :: struct {
	open:      bool,
	opened_at: u64,
	filter:    Line_Edit,
	selected:  int,                  // a row: a project, or past them Open folder…
	reveal:    bool,                 // scroll the selected row into view when next laid out
	clicked:   Maybe(Picker_Choice), // a row clicked, applied next frame
}

// What a row opens, and where
Picker_Choice :: struct {
	row:        int, // a project's, or the projects' count for Open folder…
	new_window: bool,
}


// Open project: shows the popup, or closes it
project_picker_toggle :: proc() {
	pp := &g.project_picker
	if pp.open {
		pp.open = false
		return
	}

	if g.finder.open do finder_close()
	g.sidebar_search.open = false
	pp^ = {open = true, opened_at = g.frame, filter = pp.filter}
	line_edit_clear(&pp.filter)
}


project_picker_destroy :: proc() {
	line_edit_destroy(&g.project_picker.filter)
}


// Before the panes' frames: opens a row clicked last frame, and closes on a
// press outside the popup
project_picker_frame :: proc() {
	pp := &g.project_picker
	if !pp.open do return

	if choice, was_clicked := pp.clicked.?; was_clicked {
		pp.clicked = nil
		picker_choose(choice)
		return
	}

	pressed := g.mouse_pressed || g.right_pressed
	if pressed && pp.opened_at != g.frame && !pointer_in(clay.ID("ProjectPicker")) {
		pp.open = false
		g.mouse_pressed = false
	}
}


// Whether the popup is over the pointer, as last laid out
project_picker_covers_pointer :: proc() -> bool {
	return g.project_picker.open && pointer_in(clay.ID("ProjectPicker"))
}


@(private = "file")
Scored_Project :: struct {
	path:  string,
	score: f32,
}


// The recent projects matching the filter, best first (temp)
@(private = "file")
picker_projects :: proc() -> []string {
	query := line_edit_string(&g.project_picker.filter)
	shown := make([dynamic]string, context.temp_allocator)
	if query == "" {
		append(&shown, ..state_recent_projects())
		return shown[:]
	}

	// Scored on the folder's name and path, the name counting more
	scored := make([dynamic]Scored_Project, context.temp_allocator)
	for path in state_recent_projects() {
		name_score, in_name := fuzzy.score(query, folder_name(path))
		path_score, in_path := fuzzy.score(query, path)
		if !in_name && !in_path {
			continue
		}
		append(&scored, Scored_Project{path, max(name_score + 1, path_score)})
	}
	for i in 1 ..< len(scored) {
		for j := i; j > 0 && scored[j].score > scored[j - 1].score; j -= 1 {
			scored[j], scored[j - 1] = scored[j - 1], scored[j]
		}
	}
	for s in scored do append(&shown, s.path)
	return shown[:]
}


// Opens a row's project here or in another window, or shows the folder dialog
@(private = "file")
picker_choose :: proc(choice: Picker_Choice) {
	g.project_picker.open = false
	projects := picker_projects()

	if choice.row >= len(projects) {
		show_open_folder_dialog(choice.new_window)
		return
	}

	path := projects[choice.row]
	switch {
	case choice.new_window:
		defer_action(Open_Window(strings.clone(path)))
	case !same_path(path, g.workspace.root):
		defer_action(Open_Folder(strings.clone(path)))
	}
}


// --- Keys --------------------------------------------------------------------------

// Keys while the popup is open: the filter's own, Up/Down through the rows,
// Enter to open one here, Ctrl+Enter in another window, Esc to close. Other
// shortcuts close it and run
project_picker_handle_event :: proc(event: ^sdl.Event) -> bool {
	pp := &g.project_picker
	if !pp.open do return false

	if handled, changed := line_edit_event(&pp.filter, event); handled {
		if changed do pp.selected = 0
		return true
	}
	if event.type != .KEY_DOWN do return true

	last := len(picker_projects()) // Open folder…
	switch event.key.key {
	case sdl.K_ESCAPE:
		pp.open = false
	case sdl.K_UP:
		picker_select(pp.selected - 1, last)
	case sdl.K_DOWN:
		picker_select(pp.selected + 1, last)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		picker_choose({row = pp.selected, new_window = ctrl})
	case:
		cmd, is_command := command_for_key(event.key)
		if is_command && field_lets_through(cmd) {
			pp.open = false
			run_command(cmd)
		}
	}
	return true
}


@(private = "file")
picker_select :: proc(row, last: int) {
	pp := &g.project_picker
	pp.selected = clamp(row, 0, last)
	pp.reveal = true
}


// --- Another window ----------------------------------------------------------------

@(private = "file")
Launch :: struct {
	exe:    string, // owned by the launch's thread
	folder: string,
}


// Starts another typo on `folder` (a new window: a typo started outside its
// terminals never hands its folder to this one), off the UI thread
launch_window :: proc(folder: string) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return

	heap := runtime.heap_allocator()
	l := new(Launch, heap)
	l.exe = strings.clone(exe, heap)
	l.folder = strings.clone(folder, heap)
	thread.create_and_start_with_poly_data(l, launch_proc, self_cleanup = true)
}


// Runs on the launch's thread, which then waits for the new typo to end:
// waiting is how its handle is freed. The new typo doesn't depend on it, and
// goes on if this one quits first
@(private = "file")
launch_proc :: proc(l: ^Launch) {
	heap := runtime.heap_allocator()
	desc := os.Process_Desc{command = {l.exe, l.folder}}
	p, err := os.process_start(desc)

	delete(l.exe, heap)
	delete(l.folder, heap)
	free(l, heap)
	if err == nil do _, _ = os.process_wait(p)
}


// --- UI ----------------------------------------------------------------------------

// The popup, declared with the popups: under the open folder button while the
// sidebar shows, else at the top of the window
project_picker_ui :: proc() {
	pp := &g.project_picker
	if !pp.open do return

	g.in_project_picker = true
	defer g.in_project_picker = false

	// Where it shows
	width := min(PICKER_WIDTH, f32(g.window_w) - 2 * PANE_GAP)
	floating := clay.FloatingElementConfig {
		attachTo = .Root,
		offset   = {(f32(g.window_w) - width) / 2, 60},
		zIndex   = POPUP_LAYER,
	}
	button, has_button := element_rect(clay.ID("OpenButton"))
	if g.sidebar_visible && has_button {
		x := clamp(button.x, PANE_GAP, f32(g.window_w) - width - PANE_GAP)
		floating.offset = {x, button.y + button.h + 4}
	}

	if clay.UI(clay.ID("ProjectPicker"))({
		layout = {
			sizing = {width = clay.SizingFixed(width)},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(PICKER_PAD),
			childGap = 4,
		},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = floating,
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		look := Field_Look{height = 28, size = FONT_SIZE_SMALL, padding = 8}
		text_field(clay.ID("ProjectPickerFilter"), &pp.filter, "Recent projects", true, look)
		picker_rows()
	}
}


// The projects, then Open folder…
@(private = "file")
picker_rows :: proc() {
	pp := &g.project_picker
	projects := picker_projects()

	if len(projects) == 0 {
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(PICKER_ROW_HEIGHT)},
				padding = {left = 8},
				childAlignment = {y = .Center},
			},
		}) {
			empty := len(state_recent_projects()) == 0
			message := empty ? "No recent projects" : "No matching projects"
			label(message, gfx.theme.text_faint, FONT_SIZE_SIDEBAR)
		}
	}

	// The projects, scrolling past PICKER_ROWS
	list := clay.ID("ProjectPickerList")
	if len(projects) > 0 {
		wheel_scroll_list(list)
		if pp.reveal && pp.selected < len(projects) {
			list_reveal_row(clay.GetScrollContainerData(list), pp.selected, PICKER_ROW_HEIGHT)
		}
		pp.reveal = false

		rows := f32(min(len(projects), PICKER_ROWS))
		if clay.UI(list)({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(rows * PICKER_ROW_HEIGHT)},
				layoutDirection = .TopToBottom,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for path, i in projects do picker_row(i, path, list)
		}
	}

	// A line, then the folder dialog
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}},
		backgroundColor = gfx.theme.border,
	}) {}
	picker_row(len(projects), "", {})
}


// A row: a project (its name, its folder dim, "current" for the one open
// here), or with no path Open folder…; on hover or while selected, a button
// opening it in another window
@(private = "file")
picker_row :: proc(row: int, path: string, list: clay.ElementId) {
	pp := &g.project_picker
	id := clay.ID("ProjectPickerRow", u32(row))
	window_id := clay.ID("ProjectPickerWindow", u32(row))
	selected := row == pp.selected
	hovered := pointer_in(id) && ui_interactive()

	dialog := path == ""
	name := dialog ? "Open folder…" : folder_name(path)
	folder := dialog ? "" : parent_folder_shown(path)
	current := !dialog && same_path(path, g.workspace.root)

	background: clay.Color
	if selected {
		background = gfx.theme.selected
	} else if hovered {
		background = gfx.theme.hover
	}

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(PICKER_ROW_HEIGHT)},
			padding = {left = 8, right = 4},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = background,
		cornerRadius = clay.CornerRadiusAll(5),
	}) {
		icon(dialog ? .Folder_Open : .Folder, selected ? gfx.theme.accent : gfx.theme.text_dim, 14)

		// The name and folder, cut off before what is at the right
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			clip = row_clip(),
		}) {
			label(name, selected ? gfx.theme.text_bright : gfx.theme.text, FONT_SIZE_SIDEBAR)
			if folder != "" do label(folder, gfx.theme.text_faint, FONT_SIZE_SMALL)
		}

		if current do label("current", gfx.theme.text_faint, FONT_SIZE_SMALL)
		if selected || hovered {
			tip := dialog ? "Open a folder in a new window" : "Open in a new window"
			if icon_button(window_id, .App_Window, 22, 14, tip, "Ctrl+Enter") {
				pp.clicked = Picker_Choice{row = row, new_window = true}
			}
		}
	}

	// A press on the row, but not on its window button
	on_button := pointer_in(window_id)
	if clicked(id, list) && !on_button {
		pp.clicked = Picker_Choice{row = row}
	}
}


// A project's parent folder, as the row shows it (temp)
@(private = "file")
parent_folder_shown :: proc(path: string) -> string {
	parent := filepath.dir(strings.trim_right(path, "/\\"))
	home := os.get_env("USERPROFILE" when ODIN_OS == .Windows else "HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(parent, home) {
		return strings.concatenate({"~", parent[len(home):]}, context.temp_allocator)
	}
	return parent
}
