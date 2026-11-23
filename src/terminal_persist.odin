package editor

// Persistent terminals: shells that run in herdr-core (docs/terminal_persistence.md)
// and keep running after typo quits. typo still draws them with its own
// terminal; term.Session's Remote backend carries the bytes. This file holds
// the app's side: the herdr client, starting and attaching terminals, what the
// session keeps of them, and what the settings say about herdr-core.
//
// The client's thread looks for hc at launch and connects only once a
// terminal needs it

import "core:fmt"
import "core:os"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"
import "herdr"
import "term"


// The labels typo's terminals carry (and the events typo follows)
@(private = "file")
LABEL_TYPO :: "typo=1"

@(private = "file")
persist: struct {
	client:  herdr.Client,
	started: bool,
}


// Starts the client's threads, which look for hc
persist_init :: proc() {
	if persist.started do return

	herdr.client_start(&persist.client, {LABEL_TYPO}, wake_main_loop, nil)
	persist.started = true
}


// Stops the client. Terminals were detached before (panes_destroy), so their
// shells go on; closing panes just before still reaches herdr-core
persist_destroy :: proc() {
	if !persist.started do return

	herdr.client_stop(&persist.client)
	persist = {}
}


// Looks for hc again, if it wasn't found: it may have been installed since
persist_look_again :: proc() {
	if !persist.started do return

	if herdr.client_status(&persist.client).status == .Not_Found {
		herdr.client_look_again(&persist.client)
	}
}


// Whether new terminals run in herdr-core (the terminal backend setting)
persist_wanted :: proc() -> bool {
	return g.settings.terminal_backend == "herdr"
}


// Sets what new terminals are (the terminal backend setting): pinned ones run
// in herdr-core. It changes the value in effect: the project's, if it sets
// one, else the user's
persist_set_wanted :: proc(pinned: bool) {
	s := &g.settings
	value := pinned ? "herdr" : "local"
	if .Terminal_Backend in s.project.set {
		set_string(&s.project.values.terminal_backend, value)
		project_settings_changed()
		return
	}

	set_string(&s.user.terminal_backend, value)
	settings_changed()
}


// Whether herdr-core is known not to be installed (so nothing can be pinned)
persist_missing :: proc() -> bool {
	if !persist.started do return true
	return herdr.client_status(&persist.client).status == .Not_Found
}


// What the settings window says under the terminal backend setting (temp)
persist_status_note :: proc() -> string {
	if !persist.started do return ""

	info := herdr.client_status(&persist.client)
	switch info.status {
	case .Stopped, .Looking:
		return "Looking for herdr-core…"
	case .Not_Found:
		return "herdr-core isn't installed (hc on PATH or in its install folder): " +
		       "new terminals run here."
	case .Found:
		return fmt.tprintf("herdr-core found: %s", info.hc)
	case .Connecting:
		return "Connecting to herdr-core…"
	case .Connected:
		return fmt.tprintf("Connected to herdr-core %s", info.version)
	case .Failed:
		return "herdr-core didn't answer; trying again…"
	}
	return ""
}


// Starts `line` (the shell's command line) in herdr-core, or attaches the
// terminal the session had. Without herdr-core it says so and asks for a
// local shell instead (`local`): the terminal is then a local one
persist_start :: proc(t: ^Terminal, line: string) -> (started, local: bool) {
	s := &t.session
	display := persist_display()

	// The terminal the session had
	if t.address != "" {
		term.session_attach_remote(
			s,
			&persist.client,
			t.address,
			t.core_id,
			display,
			herdr.DEFAULT_HISTORY,
		)
		delete(t.address)
		delete(t.core_id)
		t.address, t.core_id = "", ""
		return true, false
	}

	// Not installed: a local shell, which the caller starts
	if !persist.started || herdr.client_status(&persist.client).status == .Not_Found {
		t.persistent = false
		notice := "herdr-core isn't installed: this terminal runs here and ends with typo."
		term.session_print_notice(s, notice)
		return false, true
	}

	spec := herdr.Spec {
		argv   = command_argv(line),
		cwd    = g.workspace.root,
		env    = persist_env(),
		labels = persist_labels(),
	}
	if len(spec.argv) == 0 do spec.line = line
	term.session_start_remote(s, &persist.client, spec, display, herdr.DEFAULT_HISTORY)
	return true, false
}


// The ids the session keeps for a persistent terminal: its address and its
// core. A terminal not shown since the session opened keeps the ones it had
persist_ids :: proc(t: ^Terminal) -> (address, core_id: string) {
	if !t.persistent do return "", ""
	if t.address != "" do return t.address, t.core_id

	address = term.session_remote_address(&t.session)
	if address == "" || !persist.started {
		return "", ""
	}
	return address, herdr.client_status(&persist.client).core_id
}


// Ends a herdr-core terminal no pane shows: one from the session whose pane
// closed before it was shown
persist_kill :: proc(address, core_id: string) {
	if persist.started do herdr.client_kill(&persist.client, address, core_id)
}


// A terminal from the session: attached to its herdr-core terminal once shown
persist_restore :: proc(t: ^Terminal, address, core_id: string) {
	t.persistent = true
	t.address = strings.clone(address)
	t.core_id = strings.clone(core_id)
}


// The pane's colors, which herdr-core answers display queries with (the
// session adds the cell size) (temp)
@(private = "file")
persist_display :: proc() -> herdr.Display {
	return {
		fg = hex_color(gfx.theme.text),
		bg = hex_color(gfx.theme.bg),
		cursor = hex_color(gfx.theme.caret),
	}
}


// "#rrggbb" (temp)
@(private = "file")
hex_color :: proc(c: clay.Color) -> string {
	return herdr.hex_color(u8(c.r), u8(c.g), u8(c.b), context.temp_allocator)
}


// A persistent shell's environment (temp): what local shells get, typo's
// name as the terminal (herdr-core would give Ghostty's), and the stable
// name of the project's typo window for `typo <file>`. A shell in herdr-core
// starts from the core's environment, which is whatever started the core
// (some tools set NO_COLOR, which turns colors off in most programs); a local
// shell starts from typo's, so NO_COLOR follows typo's own. Empty counts as
// unset (no-color.org)
@(private = "file")
persist_env :: proc() -> []string {
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..term.shell_identity())
	append(&env, ..ipc_persistent_env())

	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	append(&env, fmt.tprintf("NO_COLOR=%s", no_color))
	return env[:]
}


@(private = "file")
persist_labels :: proc() -> []string {
	labels := make([]string, 2, context.temp_allocator)
	labels[0] = LABEL_TYPO
	labels[1] = fmt.tprintf("typo.project=%s", g.workspace.root)
	return labels
}
