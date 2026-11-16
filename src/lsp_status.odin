package editor

// The language servers in the status bar: the focused file's language with a
// dot for its servers' state (the servers in its tooltip), and a popup listing
// every running server with Restart,
// Stop/Start, Disable and its log, then the focused file's servers that are off
// (Turn on) or not found (Install, which runs its install command in a
// terminal, Locate…, which picks the program in a file dialog, and Turn off).
// A chosen action runs at the start of the next frame, since this frame's
// render commands still use the client's strings

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import clay "../vendor/clay-odin"
import "gfx"
import "langs"
import "lsp"
import sdl "../vendor/sdl3"


Lsp_Popup :: struct {
	open:     bool,
	opened:   u64,         // frame
	target:   ^langs.Client, // what a client action is for
	server:   string,      // owned; what a server action (Turn on, Locate) is for
	action:   Maybe(Lsp_Action),
	locating: string,      // owned; the server the file dialog is choosing a program for
}

Lsp_Action :: enum {
	Restart,
	Stop,
	Start,
	Disable,
	Show_Log,
	Turn_On,
	Turn_Off,
	Locate,
	Install,
}

@(private = "file")
POPUP_WIDTH :: 440

// SDL may call the file dialog's callback on another thread: the chosen program
// is handed over here and applied on the main thread
@(private = "file")
picked: struct {
	mutex: sync.Mutex,
	path:  string,
}


// Before the panes' frames: runs a chosen action, applies a program picked in
// the file dialog, and closes the popup on a press outside it (which does
// nothing else)
lsp_popup_frame :: proc() {
	p := &g.lsp.popup

	if action, ok := p.action.?; ok {
		p.action = nil
		if p.target != nil do run_action(p.target, action)
		if p.server != "" do run_server_action(p.server, action)
		p.target = nil
		delete(p.server)
		p.server = ""
	}

	// A program chosen for a server
	if path, ok := take_picked_program(); ok {
		if p.locating != "" do set_server_path(p.locating, path)
		delete(path)
		delete(p.locating)
		p.locating = ""
	}

	if p.open && g.mouse_pressed && p.opened != g.frame && !pointer_in(clay.ID("LspPopup")) {
		p.open = false
		g.mouse_pressed = false
	}
}


lsp_popup_close :: proc() {
	g.lsp.popup.open = false
}


lsp_popup_destroy :: proc() {
	p := &g.lsp.popup
	delete(p.server)
	delete(p.locating)
	p^ = {}

	sync.guard(&picked.mutex)
	delete(picked.path)
	picked.path = ""
}


// Turn on: the server starts for open files once it is found. Turn off: it is
// no longer looked for. Locate: opens the file dialog for its program
@(private = "file")
run_server_action :: proc(name: string, action: Lsp_Action) {
	#partial switch action {
	case .Turn_On:
		lsp_set_server_enabled(name, true)

	case .Turn_Off:
		lsp_set_server_enabled(name, false)

	case .Locate:
		lsp_locate_program(name)

	case .Install:
		lsp_install(name)
		lsp_popup_close()
	}
}


// Opens the file dialog to choose a server's program; the one chosen is saved
// as its path, and the server turned on
lsp_locate_program :: proc(name: string) {
	delete(g.lsp.popup.locating)
	g.lsp.popup.locating = strings.clone(name)

	// Starting in the folder of the program it was set to, if any
	start: cstring
	if server := langs.server(name); server != nil && server.path != "" {
		dir := filepath.dir(server.path)
		start = strings.clone_to_cstring(dir, context.temp_allocator)
	}

	when ODIN_OS == .Windows {
		filters := []sdl.DialogFileFilter{{"Programs", "exe;cmd;bat"}, {"All files", "*"}}
		sdl.ShowOpenFileDialog(
			program_dialog_callback,
			nil,
			g.window,
			raw_data(filters),
			i32(len(filters)),
			start,
			false,
		)
	} else {
		sdl.ShowOpenFileDialog(program_dialog_callback, nil, g.window, nil, 0, start, false)
	}
}


@(private = "file")
program_dialog_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = g.ctx

	// An error, or cancelled
	if filelist == nil || filelist[0] == nil {
		return
	}

	sync.lock(&picked.mutex)
	delete(picked.path)
	picked.path = strings.clone_from_cstring(filelist[0])
	sync.unlock(&picked.mutex)

	wake_main_loop(nil)
}


// A program chosen in the file dialog since the last call, if any; owned
@(private = "file")
take_picked_program :: proc() -> (path: string, ok: bool) {
	sync.guard(&picked.mutex)
	path, picked.path = picked.path, ""
	return path, path != ""
}


// Points a server at a program and turns it on; it starts for open files of
// its language
@(private = "file")
set_server_path :: proc(name, path: string) {
	o := langs.server_override(&g.settings.servers, name)
	set_string(&o.path, path)
	o.enabled = true
	settings_changed()
}


@(private = "file")
run_action :: proc(c: ^langs.Client, action: Lsp_Action) {
	#partial switch action {
	case .Restart, .Start:
		langs.restart_by_user(c)
	case .Stop:
		langs.client_stop(c)
	case .Disable:
		lsp_set_server_enabled(c.name, false)
	case .Show_Log:
		if lsp_open_log(c) do lsp_popup_close()
	}
}


// --- Status bar --------------------------------------------------------------------

// The item at the right of the status bar: the focused file's language, with a
// dot for its servers (gray off, red failed, green active); opens the popup
lsp_status_item :: proc() {
	e := focused_editor()
	language := ""
	if e != nil && e.status == .Text {
		language = lsp.language_for_path(e.path, langs.state.languages[:])
	}
	popup := &g.lsp.popup
	if language == "" && !popup.open {
		return
	}

	name := "Language servers"
	if language != "" do name = lsp.language_name(language, langs.state.languages[:])

	id := clay.ID("LspStatus")
	if clay.UI(id)({
		layout = {
			padding = {left = 6, right = 6, top = 1, bottom = 1},
			childGap = 5,
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() || popup.open ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		dot(status_color(e), size = 6, drop = 2)
		label(name, gfx.theme.text_dim, FONT_SIZE_SMALL)

		// The file's errors and warnings
		errors, warnings := 0, 0
		if e != nil do errors, warnings = langs.problem_counts(&e.lsp)
		if errors > 0 {
			icon(.Close, gfx.theme.error, 12)
			label(fmt.tprintf("%d", errors), gfx.theme.error, FONT_SIZE_SMALL)
		}
		if warnings > 0 {
			icon(.Alert, gfx.theme.ansi[3], 12)
			label(fmt.tprintf("%d", warnings), gfx.theme.ansi[3], FONT_SIZE_SMALL)
		}
	}

	if !popup.open do tooltip(id, status_detail(e, language))
	if clicked(id) {
		popup.open = true
		popup.opened = g.frame
		langs.recheck_programs() // it lists what isn't installed; something may be now
	}
}


// Red if one of the file's servers failed, else green if one runs, else gray
@(private = "file")
status_color :: proc(e: ^Editor) -> clay.Color {
	color := gfx.theme.text_faint
	if e == nil do return color

	for dc in e.lsp.clients {
		#partial switch dc.client.state {
		case .Crashed: return gfx.theme.error
		case .Running: color = gfx.theme.ansi[2] // green
		}
	}
	return color
}


// The item's tooltip: the file's servers and what they are doing
@(private = "file")
status_detail :: proc(e: ^Editor, language: string) -> string {
	if e == nil || len(e.lsp.clients) == 0 {
		switch {
		case !g.settings.lsp_enabled: return "Language servers are turned off"
		case has_server(language):    return "No language server running"
		}
		return "No language server for this language"
	}

	parts := make([dynamic]string, context.temp_allocator)
	for dc in e.lsp.clients {
		c := dc.client
		part := c.name
		#partial switch c.state {
		case .Starting: part = fmt.tprintf("%s (starting)", c.name)
		case .Stopping: part = fmt.tprintf("%s (stopping)", c.name)
		case .Stopped:  part = fmt.tprintf("%s (stopped)", c.name)
		case .Crashed:  part = fmt.tprintf("%s (failed)", c.name)
		case .Running:
			if len(c.progress) > 0 {
				part = fmt.tprintf("%s: %s", c.name, progress_text(c.progress[0]))
			}
		}
		append(&parts, part)
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}


// Whether some server is configured for a language
@(private = "file")
has_server :: proc(language: string) -> bool {
	for server in langs.state.servers {
		if lsp.serves(server, language) do return true
	}
	return false
}


// "Indexing 40%" or "Indexing: crates"
@(private = "file")
progress_text :: proc(p: lsp.Progress) -> string {
	text := p.title
	if p.message != "" {
		text = text != "" ? fmt.tprintf("%s: %s", text, p.message) : p.message
	}
	if p.percentage >= 0 do text = fmt.tprintf("%s %d%%", text, p.percentage)
	return text
}


// --- The popup ---------------------------------------------------------------------

lsp_popup_ui :: proc() {
	p := &g.lsp.popup
	if !p.open do return

	g.in_popup = true
	defer g.in_popup = false

	if clay.UI(clay.ID("LspPopup"))({
		layout = {
			sizing = {width = clay.SizingFixed(POPUP_WIDTH)},
			layoutDirection = .TopToBottom,
			padding = {8, 8, 8, 8},
			childGap = 4,
		},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .ElementWithId,
			parentId = clay.ID("LspStatus").id,
			attachment = {element = .RightBottom, parent = .RightTop},
			offset = {0, -6},
			zIndex = 120,
		},
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		if clay.UI()({layout = {padding = {left = 4, bottom = 4}}}) {
			label("LANGUAGE SERVERS", gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		}

		for c, i in langs.state.clients do client_row(c, i)
		if len(langs.state.clients) == 0 {
			if clay.UI()({layout = {padding = {left = 4, bottom = 2}}}) {
				label("None running", gfx.theme.text_faint, FONT_SIZE_SMALL)
			}
		}

		other_servers()
	}
}


// A client: its state, name and project, actions, then what it is doing
@(private = "file")
client_row :: proc(c: ^langs.Client, i: int) {
	if clay.UI(clay.ID("LspClient", u32(i)))({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 4, right = 0, top = 2, bottom = 2},
			childGap = 1,
		},
	}) {
		// State, name, project and actions
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 8,
				childAlignment = {y = .Center},
			},
		}) {
			state_dot(c.state)
			label(c.name, gfx.theme.text, FONT_SIZE_SIDEBAR)
			label(project_name(c.root), gfx.theme.text_faint, FONT_SIZE_SMALL)
			push_right()

			if c.state == .Stopped || c.state == .Crashed {
				if button(clay.ID("LspStart", u32(i)), "Start") do choose(c, .Start)
			} else {
				if button(clay.ID("LspRestart", u32(i)), "Restart") do choose(c, .Restart)
				if button(clay.ID("LspStop", u32(i)), "Stop") do choose(c, .Stop)
			}
			if button(clay.ID("LspDisable", u32(i)), "Disable", "Turn this server off") {
				choose(c, .Disable)
			}
			if button(clay.ID("LspLog", u32(i)), "Log") do choose(c, .Show_Log)
		}

		// What it is doing, or why it stopped
		if detail := client_detail(c); detail != "" {
			if clay.UI()({layout = {padding = {left = 16}}}) {
				paragraph(detail, c.state == .Crashed ? gfx.theme.error : gfx.theme.text_dim)
			}
		}
	}
}


@(private = "file")
choose :: proc(c: ^langs.Client, action: Lsp_Action) {
	g.lsp.popup.target = c
	g.lsp.popup.action = action
}


@(private = "file")
state_dot :: proc(state: lsp.State) {
	#partial switch state {
	case .Running: dot(gfx.theme.ansi[2]) // green
	case .Crashed: dot(gfx.theme.error)
	case:          dot(gfx.theme.text_faint)
	}
}


// A round dot, moved down by `drop` to sit on the middle of the text beside it
@(private = "file")
dot :: proc(color: clay.Color, size: f32 = 8, drop: u16 = 0) {
	if clay.UI()({layout = {padding = {top = drop}}}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}},
			backgroundColor = color,
			cornerRadius = clay.CornerRadiusAll(size / 2),
		}) {}
	}
}


// The project a client serves, as a path in the workspace
@(private = "file")
project_name :: proc(root: string) -> string {
	if root == g.workspace.root do return folder_name(root)
	return relative_to_root(root)
}


@(private = "file")
client_detail :: proc(c: ^langs.Client) -> string {
	switch c.state {
	case .Starting:
		return "Starting"
	case .Stopping:
		return "Stopping"
	case .Stopped:
		return c.stopped_by_user ? "Stopped" : ""
	case .Crashed:
		if c.restart_at != nil do return fmt.tprintf("%s; restarting", c.reason)
		if len(c.crashes) >= 3 do return fmt.tprintf("%s; crashed too often", c.reason)
		return c.reason
	case .Running:
		if len(c.progress) > 0 do return progress_text(c.progress[0])
		return c.message
	}
	return ""
}


// The focused file's servers that aren't running: those that are off (Turn on),
// and those whose program isn't found, with how to install it (Install,
// Locate…) or Turn off
@(private = "file")
other_servers :: proc() {
	e := focused_editor()
	if e == nil || e.status != .Text {
		return
	}
	language := lsp.language_for_path(e.path, langs.state.languages[:])
	if language == "" do return

	for &server, i in langs.state.servers {
		if !lsp.serves(server, language) do continue

		// Listed above once it runs; left out while its program is looked up
		path, known := langs.server_path(&server)
		off := !server.enabled
		missing := !off && known && path == ""
		if !off && !missing {
			continue
		}

		if clay.UI(clay.ID("LspServer", u32(i)))({
			layout = {
				sizing = {width = clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {left = 4, top = 2, bottom = 2},
				childGap = 1,
			},
		}) {
			// Name, state and its button
			if clay.UI()({
				layout = {
					sizing = {width = clay.SizingGrow()},
					childGap = 8,
					childAlignment = {y = .Center},
				},
			}) {
				state_dot(.Stopped)
				label(server.name, gfx.theme.text_dim, FONT_SIZE_SIDEBAR)
				label(off ? "off" : "not found", gfx.theme.text_faint, FONT_SIZE_SMALL)
				push_right()

				installing := lsp_installing(server.name)
				if off {
					if button(clay.ID("LspTurnOn", u32(i)), "Turn on") {
						choose_server(server.name, .Turn_On)
					}
				} else if installing {
					label("installing…", gfx.theme.text_faint, FONT_SIZE_SMALL)
				} else {
					if server.install != "" && server.path == "" {
						tip := fmt.tprintf("Run %s in a terminal", server.install)
						if button(clay.ID("LspInstall", u32(i)), "Install", tip) {
							choose_server(server.name, .Install)
						}
					}
					tip := "Choose where its program is installed"
					if button(clay.ID("LspLocate", u32(i)), "Locate…", tip) {
						choose_server(server.name, .Locate)
					}
				}
				if missing {
					tip := "Turn this server off"
					if button(clay.ID("LspTurnOff", u32(i)), "Turn off", tip) {
						choose_server(server.name, .Turn_Off)
					}
				}
			}

			// How to install it, or that the program it was pointed at is gone
			if missing {
				how := server.install != "" ? server.install : server.url
				if server.path != "" do how = fmt.tprintf("Not found at %s", server.path)
				if clay.UI()({layout = {padding = {left = 16}}}) {
					paragraph(how, gfx.theme.text_faint)
				}
			}
		}
	}
}


@(private = "file")
choose_server :: proc(name: string, action: Lsp_Action) {
	p := &g.lsp.popup
	delete(p.server)
	p.server = strings.clone(name)
	p.action = action
}
