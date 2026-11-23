package editor

// The language servers in the settings window: under "Language servers", a row
// for each server, grouped by language, with its state, Install (or what
// installing needs) and Locate… when its program isn't found, and an Off/On
// switch; then a row that adds a server. Enter or the chevron opens a server's
// page in place of the list, which edits its [lsp.<name>] table: program,
// command, languages, files and install commands, with the install commands
// found, Restart, its log, and Reset or Remove.
//
// Changes are queued and applied at the start of the next frame
// (settings_servers_frame): this frame's render commands may still use the
// strings they replace

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import "gfx"
import "langs"
import "lsp"
import sdl "../vendor/sdl3"


// A server's row in the settings list: its index in server_rows
Server_Item :: distinct int

// The row that adds a server
Add_Server_Item :: struct {}

// A server as the settings window lists it
Server_Row :: struct {
	name:     string,
	server:   ^langs.Server,      // nil while it has neither a command nor a path
	override: ^langs.Server_Override, // its [lsp.<name>] table, if it has one
	group:    string,           // the language it is listed under
}

// What a server's row says about it
Server_State :: struct {
	color:   clay.Color, // of its dot; clear for none
	text:    string,
	missing: bool,       // its program isn't found
}

// A change to a server, applied next frame
Server_Op :: struct {
	kind:  Server_Op_Kind,
	name:  string, // owned
	field: langs.Server_Field,
	value: string, // owned
}

Server_Op_Kind :: enum {
	Turn_On,
	Turn_Off,
	Reset,
	Remove,
	Add,
	Install, // the install command in `value`
	Locate,
	Restart,
	Show_Log,
	Set_Field,
}

SERVER_FIELD_NAMES := [langs.Server_Field]string {
	.Name         = "Name",
	.Path         = "Program",
	.Command      = "Command",
	.Languages    = "Languages",
	.Extensions   = "Extensions",
	.Root_Markers = "Root markers",
	.Install      = "Install",
}

// What each field is, shown in the page's footer while it has focus
SERVER_FIELD_HELP := [langs.Server_Field]string {
	.Name         = "The [lsp.<name>] table in settings.toml.",
	.Path         = "The program to run, with the command's arguments. Empty looks for " +
	                "the command on PATH.",
	.Command      = "The program and its arguments. Quote a word with spaces.",
	.Languages    = "Language ids it serves, separated by commas, e.g. python.",
	.Extensions   = "Files of a language typo doesn't know (the first language), " +
	                "e.g. vue.",
	.Root_Markers = "Files or folders that mark a project's root, e.g. pyproject.toml.",
	.Install      = "Command lines that install it, separated by semicolons. Install " +
	                "runs the lightest whose program is on PATH, in a terminal.",
}

// segmented's ids for the servers' switches start here, past the settings'
@(private = "file")
SERVER_SWITCH_IDS :: 4096

@(private = "file")
FIELD_LABEL_WIDTH :: 110

// The widest a row's "Needs ..." label gets
@(private = "file")
NEEDS_MAX_WIDTH :: 220


// --- Rows --------------------------------------------------------------------------

// The servers to list, grouped by language in the order the groups first
// appear (temp). Servers the settings added without a command or path come
// last, under "Other"
server_rows :: proc() -> []Server_Row {
	all := make([dynamic]Server_Row, context.temp_allocator)
	for &server in langs.state.servers {
		group := "Other"
		if len(server.languages) > 0 {
			group = lsp.language_name(server.languages[0], langs.state.languages[:])
		}
		override := langs.find_server_override(g.settings.servers[:], server.name)
		append(&all, Server_Row{server.name, &server, override, group})
	}

	// Added, but not runnable yet
	for &o in g.settings.servers {
		_, builtin := langs.builtin_server(o.name)
		if builtin || langs.server(o.name) != nil {
			continue
		}
		append(&all, Server_Row{name = o.name, override = &o, group = "Other"})
	}

	// Grouped
	rows := make([dynamic]Server_Row, 0, len(all), context.temp_allocator)
	for row, i in all {
		first := true
		for earlier in all[:i] {
			if earlier.group == row.group do first = false
		}
		if !first do continue

		for other in all[i:] {
			if other.group == row.group do append(&rows, other)
		}
	}
	return rows[:]
}


// The row of the server named `name`
@(private = "file")
find_row :: proc(name: string) -> (row: Server_Row, index: int, found: bool) {
	for r, i in server_rows() {
		if r.name == name do return r, i, true
	}
	return {}, -1, false
}


@(private = "file")
row_matches :: proc(row: Server_Row, query: string) -> bool {
	languages := ""
	if row.server != nil {
		names := make([]string, len(row.server.languages), context.temp_allocator)
		for id, i in row.server.languages {
			names[i] = lsp.language_name(id, langs.state.languages[:])
		}
		languages = strings.join(names, " ", context.temp_allocator)
	}
	return matches(query, "lsp language server", row.name, row.group, languages)
}


// Whether the search shows any server row, or the row that adds one
servers_match :: proc(query: string) -> bool {
	if matches(query, "lsp language server add") do return true

	for row in server_rows() {
		if row_matches(row, query) do return true
	}
	return false
}


// The server rows that match the search, under their languages, then the row
// that adds one. They go in the settings list's items
servers_list :: proc(query: string, list: clay.ElementId) {
	group := ""
	for row, i in server_rows() {
		if !row_matches(row, query) do continue

		if row.group != group {
			group = row.group
			if clay.UI()({layout = {padding = {left = 10, top = 8, bottom = 2}}}) {
				label(group, gfx.theme.text_dim, FONT_SIZE_SMALL, .SemiBold)
			}
		}
		server_row(row, i, list)
	}

	if matches(query, "lsp language server add") {
		description := "A server typo doesn't list: its command, languages and files"
		if setting_row(Add_Server_Item{}, "Add a server", description, list) {
			if icon_button(clay.ID("ServerAdd"), .Plus, 26, 16, "Add a server", "Enter") {
				queue_server_op(.Add, "")
			}
		}
	}
}


// A server's name and state, Install and Locate… when its program isn't
// found, its switch, and the chevron that opens its page
@(private = "file")
server_row :: proc(row: Server_Row, index: int, list: clay.ElementId) {
	state := server_state(row)
	detail := state.text
	if row.server != nil && len(row.server.languages) > 1 {
		detail = fmt.tprintf("%s · %s", language_names(row.server), state.text)
	}

	item := Server_Item(index)
	if setting_row(item, row.name, "", list, state.color, detail) {
		if state.missing do missing_buttons(row, index)

		on := server_on(row)
		switch_ids := SERVER_SWITCH_IDS + u32(index)
		choice, changed := segmented(switch_ids, {"Off", "On"}, int(on), list)
		if changed {
			queue_server_op(choice == 1 ? .Turn_On : .Turn_Off, row.name)
		}

		configure := clay.ID("ServerConfigure", u32(index))
		if icon_button(configure, .Chevron_Right, 26, 16, "Configure", "Enter") {
			open_server_page(row.name)
		}
	}
}


// Install, which runs the lightest install command found, or what installing
// needs when none is; then Locate…
@(private = "file")
missing_buttons :: proc(row: Server_Row, index: int) {
	installs := row_installs(row)
	if len(installs.offered) > 0 {
		lightest := installs.offered[0]
		if button(clay.ID("ServerInstall", u32(index)), "Install", install_tip(lightest)) {
			queue_server_op(.Install, row.name, value = lightest.command)
		}
	} else if installs.needs != "" {
		needs_label(clay.ID("ServerNeeds", u32(index)), install_needs(installs))
	}

	tip := "Choose where its program is installed"
	if button(clay.ID("ServerLocate", u32(index)), "Locate…", tip) {
		queue_server_op(.Locate, row.name)
	}
}


// How a server can be installed; nothing while it is being installed
@(private = "file")
row_installs :: proc(row: Server_Row) -> langs.Installs {
	if row.server == nil || lsp_installing(row.name) {
		return {}
	}
	return langs.server_installs(row.server)
}


// What installing a server needs, beside its row's buttons: cut short if it is
// long, the whole of it in its tooltip
@(private = "file")
needs_label :: proc(id: clay.ElementId, text: string) {
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingFit({max = NEEDS_MAX_WIDTH})}},
		clip = row_clip(),
	}) {
		label(text, gfx.theme.text_faint, FONT_SIZE_SMALL)
	}
	tooltip(id, text)
}


// Whether a server is on: as configured, or as its table says while it can't run
@(private = "file")
server_on :: proc(row: Server_Row) -> bool {
	if row.server != nil do return row.server.enabled
	if row.override == nil do return false

	enabled := row.override.enabled.? or_else true
	return enabled
}


@(private = "file")
language_names :: proc(server: ^langs.Server) -> string {
	names := make([]string, len(server.languages), context.temp_allocator)
	for id, i in server.languages {
		names[i] = lsp.language_name(id, langs.state.languages[:])
	}
	return strings.join(names, ", ", context.temp_allocator)
}


// Off, installing, looked for, not found, failed, running, or ready, with the
// program found (temp)
server_state :: proc(row: Server_Row) -> Server_State {
	faint := gfx.theme.text_faint
	server := row.server
	if server == nil do return {faint, "Needs a command or a program", false}
	if !server.enabled do return {faint, "Off", false}
	if lsp_installing(row.name) do return {faint, "Installing in a terminal…", false}

	program := short_path(server.path != "" ? server.path : server.command[0])
	path, known := langs.server_path(server)
	if !known do return {faint, fmt.tprintf("Looking for %s…", program), false}
	if path == "" {
		text := fmt.tprintf("%s isn't on PATH", program)
		if server.path != "" do text = fmt.tprintf("Not found at %s", program)
		return {gfx.theme.ansi[3], text, true} // yellow
	}

	// What its clients are doing
	failed, running, starting := "", false, false
	for c in langs.state.clients {
		if c.name != row.name do continue

		#partial switch c.state {
		case .Crashed:  failed = c.reason
		case .Running:  running = true
		case .Starting: starting = true
		}
	}

	path = short_path(path)
	green := gfx.theme.ansi[2]
	switch {
	case failed != "":
		return {gfx.theme.error, fmt.tprintf("Failed: %s · %s", failed, path), false}
	case running:
		return {green, fmt.tprintf("Running · %s", path), false}
	case starting:
		return {faint, fmt.tprintf("Starting · %s", path), false}
	case !g.settings.lsp_enabled:
		return {faint, fmt.tprintf("Language servers are off · %s", path), false}
	}
	return {gfx.theme.text_dim, fmt.tprintf("Ready · %s", path), false}
}


// A path short enough for a row: its start, an ellipsis, then its file name
// (temp). The page's Program field shows it whole
@(private)
short_path :: proc(path: string) -> string {
	MAX_PATH_SHOWN :: 48
	if len(path) <= MAX_PATH_SHOWN do return path

	// A file name too long to keep whole is cut at the end
	slash := strings.last_index_any(path, "/\\")
	room := MAX_PATH_SHOWN - (len(path) - slash)
	if slash < 0 || room < 8 {
		return fmt.tprintf("%s…", path[:rune_floor(path, MAX_PATH_SHOWN - 1)])
	}

	// Else as much of the start as still fits
	return fmt.tprintf("%s…%s", path[:rune_floor(path, room)], path[slash:])
}


// The start of the character at or before byte i
@(private = "file")
rune_floor :: proc(s: string, i: int) -> int {
	i := i
	for i > 0 && !utf8.rune_start(s[i]) {
		i -= 1
	}
	return i
}


// --- Keys on a row -----------------------------------------------------------------

// Enter on a server's row opens its page; on the last row, adds a server
server_item_activate :: proc(item: Setting_Item) {
	#partial switch x in item {
	case Server_Item:
		rows := server_rows()
		if int(x) < len(rows) do open_server_page(rows[x].name)
	case Add_Server_Item:
		queue_server_op(.Add, "")
	}
}


// Left and Right on a server's row turn it off and on
server_item_step :: proc(x: Server_Item, dir: int) {
	rows := server_rows()
	if int(x) >= len(rows) do return
	queue_server_op(dir < 0 ? .Turn_Off : .Turn_On, rows[x].name)
}


// Delete on a server's row puts a built-in server back as built in, and asks
// before removing one the settings added
server_item_reset :: proc(x: Server_Item) {
	rows := server_rows()
	if int(x) >= len(rows) do return

	row := rows[x]
	_, builtin := langs.builtin_server(row.name)
	if builtin && row.override == nil {
		return
	}
	queue_server_op(builtin ? .Reset : .Remove, row.name)
}


// --- Changes -----------------------------------------------------------------------

queue_server_op :: proc(
	kind: Server_Op_Kind,
	name: string,
	field := langs.Server_Field.Name,
	value := "",
) {
	op := Server_Op {
		kind  = kind,
		name  = strings.clone(name),
		field = field,
		value = strings.clone(value),
	}
	append(&g.settings_window.server_ops, op)
}


// At the start of a frame: applies the changes queued last frame, and leaves a
// server's page whose server is gone
settings_servers_frame :: proc() {
	w := &g.settings_window
	for op in w.server_ops {
		apply_server_op(op)
		delete(op.name)
		delete(op.value)
	}
	clear(&w.server_ops)

	if w.server_page != "" {
		if _, _, found := find_row(w.server_page); !found {
			close_server_page()
		}
	}
}


@(private = "file")
apply_server_op :: proc(op: Server_Op) {
	w := &g.settings_window
	switch op.kind {
	case .Turn_On, .Turn_Off:
		lsp_set_server_enabled(op.name, op.kind == .Turn_On)

	case .Reset:
		langs.remove_server_override(&g.settings.servers, op.name)
		settings_changed()

	case .Remove:
		ask_remove_server(op.name)

	case .Add:
		name := new_server_name()
		langs.server_override(&g.settings.servers, name)
		open_server_page(name)
		w.server_focus = .Command

	case .Install:
		lsp_install(op.name, op.value)
		if w.open do settings_window_toggle()

	case .Locate:
		lsp_locate_program(op.name)

	case .Restart:
		for c in langs.state.clients {
			if c.name == op.name do langs.restart_by_user(c)
		}

	case .Show_Log:
		for c in langs.state.clients {
			if c.name != op.name || !lsp_open_log(c) {
				continue
			}
			if w.open do settings_window_toggle()
			break
		}

	case .Set_Field:
		set_server_field(op.name, op.field, op.value)
	}
}


@(private = "file")
set_server_field :: proc(name: string, field: langs.Server_Field, text: string) {
	o := langs.server_override(&g.settings.servers, name)
	if field != .Name {
		langs.set_override_field_text(o, field, text)
		settings_changed()
		return
	}

	// The page follows the renamed server
	if langs.rename_server_override(g.settings.servers[:], o, text) {
		set_string(&g.settings_window.server_page, o.name)
		settings_changed()
	}
}


// "server", else "server-2", ... : a name no server has
@(private = "file")
new_server_name :: proc() -> string {
	for n := 1; ; n += 1 {
		name := n == 1 ? "server" : fmt.tprintf("server-%d", n)
		_, builtin := langs.builtin_server(name)
		if !builtin && langs.find_server_override(g.settings.servers[:], name) == nil {
			return name
		}
	}
}


// Removes a server the settings added (after ask_remove_server)
settings_remove_server :: proc(name: string) {
	langs.remove_server_override(&g.settings.servers, name)
	settings_changed()
}


// --- A server's page ---------------------------------------------------------------

open_server_page :: proc(name: string) {
	w := &g.settings_window
	finish_server_edit(commit = true)
	set_string(&w.server_page, name)
	w.server_focus = .Path
	w.server_editing = nil

	_, builtin := langs.builtin_server(name)
	if !builtin do w.server_focus = .Name
	langs.recheck_programs()
}


// Back to the list, keeping what is being typed
close_server_page :: proc() {
	w := &g.settings_window
	finish_server_edit(commit = true)
	delete(w.server_page)
	w.server_page = ""
}


// The fields a server's page shows: a built-in server's name can't change
@(private = "file")
page_fields :: proc(name: string) -> []langs.Server_Field {
	@(static) all := [?]langs.Server_Field {
		.Name,
		.Path,
		.Command,
		.Languages,
		.Extensions,
		.Root_Markers,
		.Install,
	}
	_, builtin := langs.builtin_server(name)
	return builtin ? all[1:] : all[:]
}


@(private = "file")
start_server_edit :: proc(field: langs.Server_Field) {
	w := &g.settings_window
	w.server_editing = field
	w.server_focus = field

	// The caret at the end of the text
	o := langs.find_server_override(g.settings.servers[:], w.server_page)
	text := langs.override_field_text(o, field)
	line_edit_set(&w.edit, text, len(text), len(text))
}


// Stops typing in a field; `commit` queues the text typed if it changed
finish_server_edit :: proc(commit: bool) {
	w := &g.settings_window
	field, editing := w.server_editing.?
	if !editing do return

	w.server_editing = nil
	if !commit do return

	o := langs.find_server_override(g.settings.servers[:], w.server_page)
	text := line_edit_string(&w.edit)
	if strings.trim_space(text) != langs.override_field_text(o, field) {
		queue_server_op(.Set_Field, w.server_page, field, text)
	}
}


// Moves the page's focus through its fields
@(private = "file")
move_field_focus :: proc(dir: int) {
	w := &g.settings_window
	fields := page_fields(w.server_page)

	at := 0
	for f, i in fields {
		if f == w.server_focus do at = i
	}
	w.server_focus = fields[(at + dir + len(fields)) % len(fields)]
	w.reveal = true
}


// Keys while a server's page shows. Returns true if the event was consumed
server_page_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window

	// Typing into a field
	if _, editing := w.server_editing.?; editing {
		if event.type == .KEY_DOWN {
			switch event.key.key {
			case sdl.K_RETURN, sdl.K_KP_ENTER:
				finish_server_edit(commit = true)
				return true
			case sdl.K_ESCAPE:
				finish_server_edit(commit = false)
				return true
			case sdl.K_TAB:
				finish_server_edit(commit = true)
				move_field_focus(event.key.mod & sdl.KMOD_SHIFT != {} ? -1 : +1)
				return true
			}
		}
		line_edit_event(&w.edit, event)
		return true
	}
	if event.type != .KEY_DOWN do return event.type == .TEXT_INPUT

	key := event.key
	switch key.key {
	case sdl.K_ESCAPE:
		close_server_page()

	case sdl.K_UP:
		move_field_focus(-1)

	case sdl.K_DOWN:
		move_field_focus(+1)

	case sdl.K_TAB:
		move_field_focus(key.mod & sdl.KMOD_SHIFT != {} ? -1 : +1)

	case sdl.K_RETURN, sdl.K_KP_ENTER:
		start_server_edit(w.server_focus)

	case sdl.K_DELETE:
		if w.server_focus != .Name {
			queue_server_op(.Set_Field, w.server_page, w.server_focus, "")
		}

	case sdl.K_LEFT, sdl.K_RIGHT:
		queue_server_op(key.key == sdl.K_LEFT ? .Turn_Off : .Turn_On, w.server_page)

	case:
		// The "open settings" shortcut closes the window; the rest is swallowed
		if cmd, ok := command_for_key(key); ok && cmd == .Open_Settings {
			return false
		}
	}
	return true
}


// The page: back, the server's name and switch, then its state, fields and
// actions (scrolling when the window is short), and the keys
server_page :: proc(width, height: f32) {
	w := &g.settings_window
	row, index, found := find_row(w.server_page)
	if !found do return

	// The focused field into view, after moving to it by keys
	list := clay.ID("ServerList")
	if w.reveal {
		w.reveal = false
		scroll_into_view(list, clay.ID("ServerFieldRow", u32(w.server_focus)))
	}

	if clay.UI(clay.ID("ServerPage"))({
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		transition = transition({.OverlayColor}, enter = .Fade),
		layout = {
			sizing = {clay.SizingFixed(width), clay.SizingFixed(height)},
			layoutDirection = .TopToBottom,
			padding = {left = 20, right = 20, top = 16, bottom = 14},
			childGap = 12,
		},
	}) {
		page_title(row, index)
		if clay.UI(list)({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {right = SCROLLBAR_GUTTER},
				childGap = 12,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			page_state(row)
			for field in page_fields(row.name) do field_row(row, field, list)
			page_installs(row, list)
			page_actions(row, list)
		}
		list_scrollbar(list, &w.scrollbar_drag, POPUP_LAYER)
		page_footer(row)
	}
}


@(private = "file")
page_title :: proc(row: Server_Row, index: int) {
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 4,
			childAlignment = {y = .Center},
		},
	}) {
		back := clay.ID("ServerBack")
		if icon_button(back, .Chevron_Left, 26, 18, "Back to settings", "Esc") {
			close_server_page()
		}
		label(row.name, gfx.theme.text_bright, 16, .SemiBold)
		push_right()

		on := server_on(row)
		choice, changed := segmented(SERVER_SWITCH_IDS + u32(index), {"Off", "On"}, int(on))
		if changed {
			queue_server_op(choice == 1 ? .Turn_On : .Turn_Off, row.name)
		}
	}
}


// A dot and what the server is doing, with its languages
@(private = "file")
page_state :: proc(row: Server_Row) {
	state := server_state(row)
	text := state.text
	if row.server != nil && len(row.server.languages) > 0 {
		text = fmt.tprintf("%s · %s", language_names(row.server), state.text)
	}

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 6, bottom = 4},
			childGap = 8,
		},
	}) {
		state_mark(state.color)
		paragraph(text, gfx.theme.text_dim)
	}
}


// A small round dot beside a row's name; nothing for a clear color
state_mark :: proc(color: clay.Color) {
	if color.a == 0 do return

	if clay.UI()({layout = {padding = {top = 6}}}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingFixed(7), clay.SizingFixed(7)}},
			backgroundColor = color,
			cornerRadius = clay.CornerRadiusAll(3.5),
		}) {}
	}
}


// A field's name and its text: what the table sets, else what is built in,
// dimmed. Click or Enter to edit. `list` is the scroll area it sits in
@(private = "file")
field_row :: proc(row: Server_Row, field: langs.Server_Field, list: clay.ElementId) {
	w := &g.settings_window
	id := clay.ID("ServerField", u32(field))
	editing := w.server_editing == field
	focused := w.server_focus == field

	if clicked(id, list) {
		if !editing do start_server_edit(field)
	} else if editing && g.mouse_pressed && !pointer_in(id) {
		finish_server_edit(commit = true) // clicking elsewhere keeps what was typed
	}
	editing = w.server_editing == field

	if clay.UI(clay.ID("ServerFieldRow", u32(field)))({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = 6, right = 4, top = 4, bottom = 4},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = focused && !editing ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(6),
	}) {
		name_color := focused ? gfx.theme.text_bright : gfx.theme.text
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(FIELD_LABEL_WIDTH)}}}) {
			label(SERVER_FIELD_NAMES[field], name_color)
		}

		text := langs.override_field_text(row.override, field)
		look := Field_Look{height = 28, size = 13, within = list}
		edit := editing ? &w.edit : nil
		text_field(id, edit, field_placeholder(row, field), editing, look, text)
	}
}


// What a field shows while the table doesn't set it: the built-in value, or for
// the program, where it was found
@(private = "file")
field_placeholder :: proc(row: Server_Row, field: langs.Server_Field) -> string {
	if field == .Path {
		if row.server == nil || len(row.server.command) == 0 {
			return "The program to run"
		}
		program := row.server.command[0]
		path, known := langs.server_path(row.server)
		switch {
		case row.server.path != "": return ""
		case !known:                return fmt.tprintf("Looking for %s on PATH…", program)
		case path == "":            return fmt.tprintf("%s, not found on PATH", program)
		}
		return path
	}

	if spec, builtin := langs.builtin_server(row.name); builtin {
		return langs.spec_field_text(spec, field)
	}

	#partial switch field {
	case .Command:      return "e.g. my-server --stdio"
	case .Languages:    return "e.g. python"
	case .Root_Markers: return "e.g. pyproject.toml"
	}
	return ""
}


// While a server's program isn't found: each install command whose program is,
// lightest first, with its Install button; else what they need. `list` is the
// scroll area they sit in
@(private = "file")
page_installs :: proc(row: Server_Row, list: clay.ElementId) {
	if !server_state(row).missing do return

	installs := row_installs(row)
	if len(installs.offered) == 0 && installs.needs == "" {
		return
	}

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = FIELD_LABEL_WIDTH + 12},
			childGap = 2,
		},
	}) {
		for x, i in installs.offered do install_line(row, x, i, list)

		// The text lines up with the buttons' labels
		if installs.needs != "" {
			if clay.UI(clay.ID("ServerPageNeeds"))({
				layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 6}},
			}) {
				paragraph(install_needs(installs), gfx.theme.text_faint)
			}
		}
	}
}


// An install command with its Install button
@(private = "file")
install_line :: proc(row: Server_Row, x: langs.Install, index: int, list: clay.ElementId) {
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	}) {
		id := clay.ID("ServerPageInstall", u32(index))
		if button(id, "Install", install_tip(x), within = list) {
			queue_server_op(.Install, row.name, value = x.command)
		}

		// The command, cut short if the page is narrow
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childGap = 8},
			clip = row_clip(),
		}) {
			label(x.command, gfx.theme.text_dim, FONT_SIZE_SMALL)
			if x.builds do label("builds from source", gfx.theme.text_faint, FONT_SIZE_SMALL)
		}
	}
}


// Locate…, Restart and Log; then Reset (a changed built-in server) or Remove
// (one the settings added). `list` is the scroll area they sit in
@(private = "file")
page_actions :: proc(row: Server_Row, list: clay.ElementId) {
	running := false
	logged := false
	for c in langs.state.clients {
		if c.name != row.name do continue
		running = true
		if c.log_path != "" do logged = true
	}

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = {left = FIELD_LABEL_WIDTH + 12, top = 4},
			childGap = 6,
			childAlignment = {y = .Center},
		},
	}) {
		if row.server != nil {
			tip := "Choose where its program is installed"
			if button(clay.ID("ServerPageLocate"), "Locate…", tip, within = list) {
				queue_server_op(.Locate, row.name)
			}
		}
		if running {
			if button(clay.ID("ServerRestart"), "Restart", within = list) {
				queue_server_op(.Restart, row.name)
			}
		}
		if logged {
			if button(clay.ID("ServerLog"), "Log", within = list) {
				queue_server_op(.Show_Log, row.name)
			}
		}
		push_right()

		_, builtin := langs.builtin_server(row.name)
		switch {
		case !builtin:
			remove := clay.ID("ServerRemove")
			if button(remove, "Remove server", "Del on its row", within = list) {
				queue_server_op(.Remove, row.name)
			}
		case row.override != nil:
			tip := "Undo the changes settings.toml makes to it"
			if button(clay.ID("ServerReset"), "Reset to built-in", tip, within = list) {
				queue_server_op(.Reset, row.name)
			}
		}
	}
}


// The focused field's help and the keys; the workspace settings are only in
// settings.toml
@(private = "file")
page_footer :: proc(row: Server_Row) {
	w := &g.settings_window

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {top = 10},
			childGap = 6,
		},
		border = {color = gfx.theme.border, width = {top = 1}},
	}) {
		paragraph(SERVER_FIELD_HELP[w.server_focus], gfx.theme.text_dim)
		note := fmt.tprintf(
			"Its workspace settings and initialization options are set in " +
			"settings.toml, in [lsp.%s].",
			row.name,
		)
		paragraph(note, gfx.theme.text_faint)

		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childAlignment = {y = .Center},
			},
		}) {
			hint := "↑↓ field  Enter edit  Del clear  ←→ off/on  Esc back"
			if w.server_editing != nil do hint = "Enter save  Tab next  Esc cancel"
			if clay.UI()({
				layout = {sizing = {width = clay.SizingGrow()}},
				clip = {horizontal = true},
			}) {
				label(hint, gfx.theme.text_dim, FONT_SIZE_SMALL)
			}

			if g.settings.path != "" {
				if button(clay.ID("ServerEditFile"), "Edit settings.toml", g.settings.path) {
					g.pending = Open_File(strings.clone(g.settings.path))
					settings_window_toggle()
				}
			}
		}
	}
}
