package editor

// Language servers in the app. The servers, clients, documents, problems and
// request bookkeeping are package langs; it reaches the app through
// `langs.env` (set here): the open documents, the settings, and what the
// features do with answers. Here also: the features' state (hover, completion,
// rename...), install commands running in terminals, server actions for the
// status popup and the settings window, going to a definition, and the jump
// list (Go back, Go forward), which every jump to another place records into

import "core:fmt"
import "core:strings"

import "buffer"
import "langs"
import "lsp"
import "textedit"


// The language features' state; the servers themselves are langs.state
Lsp_State :: struct {
	popup:      Lsp_Popup,
	hover:      Hover,
	finder:     Lsp_Finder, // symbols and references listed in the finder
	completion: Completion_State,
	signature:  Signature_State,
	rename:     Symbol_Rename,
	edits:      Lsp_Edits, // a workspace edit being applied
	installs:   [dynamic]Lsp_Install,
}

// A server's install command running in a terminal
Lsp_Install :: struct {
	pane:   u32,    // the terminal's Pane.id
	server: string, // owned
	seen:   u64,    // the terminal's output parsed when last looked at
	again:  bool,   // output came since the program was last looked for
}

// Where the caret goes in a file opened by g.pending: a byte offset, or a
// server's position in a file that wasn't open (converted once it is)
Open_Target :: union {
	int,
	Lsp_Target,
}

Lsp_Target :: struct {
	position: lsp.Position,
	encoding: lsp.Encoding,
}

// A place jumped from, for Go back and Go forward
Jump :: struct {
	path:   string, // owned
	offset: int,
}

Jumps :: struct {
	back:    [dynamic]Jump,
	forward: [dynamic]Jump,
}

@(private = "file")
MAX_JUMPS :: 100


// langs' view of the app; set before anything runs (tests too)
@(init, private = "file")
set_langs_env :: proc "contextless" () {
	langs.env = {
		config      = langs_config,
		documents   = open_documents,
		doc_closing = doc_closing,
		client_gone = client_gone,
		response    = lsp_response,
		apply_edit  = lsp_apply_edit_request,
		wake        = wake_main_loop,
	}
}


// Called at startup, after the settings are loaded
lsp_init :: proc() {
	langs.state.active = true
	langs.settings_changed()
}


// At exit: the features let go, then every server is told to exit
lsp_destroy :: proc() {
	l := &g.lsp
	lsp_popup_destroy()
	lsp_rename_destroy()
	lsp_edits_destroy()
	langs.destroy()

	for x in l.installs do delete(x.server)
	delete(l.installs)

	lsp_hover_close()
	lsp_finder_destroy()
	lsp_completion_destroy()
	l^ = {}
}


// Each frame: the popup's and the completion list's clicks, what the clients
// and lookups reported, and installs under way
lsp_frame :: proc() {
	lsp_popup_frame()
	lsp_completion_click_frame()
	langs.frame()
	watch_installs()
}


// --- Documents ---------------------------------------------------------------------

// After a file opened (or was renamed): attaches it to its language's servers
lsp_doc_open :: proc(e: ^Editor) {
	e.lsp.view = &e.tv
	if editor_on_servers(e) do langs.doc_open(&e.lsp)
}


// Whether the editor's document goes to language servers: text, and not a
// large file
@(private = "file")
editor_on_servers :: proc(e: ^Editor) -> bool {
	return e.status == .Text && !e.large
}


// The editor a request was about, or nil (a request about the workspace)
request_editor :: proc(r: langs.Request) -> ^Editor {
	if r.doc == nil do return nil
	return container_of(r.doc, Editor, "lsp")
}


@(private = "file")
langs_config :: proc() -> langs.Config {
	return {
		enabled        = g.settings.lsp_enabled,
		overrides      = g.settings.servers[:],
		settings_path  = g.settings.path,
		workspace_root = g.workspace.root,
	}
}


// The documents of the open text files (temp)
@(private = "file")
open_documents :: proc() -> []^langs.Doc {
	docs := make([dynamic]^langs.Doc, context.temp_allocator)
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if !is_editor || !editor_on_servers(e) {
			continue
		}

		e.lsp.view = &e.tv
		append(&docs, &e.lsp)
	}
	return docs[:]
}


// A document is closing: nothing may point at its editor
@(private = "file")
doc_closing :: proc(d: ^langs.Doc) {
	e := container_of(d, Editor, "lsp")
	lsp_hover_forget(e)
	lsp_completion_forget(e)
	lsp_rename_forget(e)
}


// A client stopped, crashed, restarted or is going away: what waits on it or
// points at it lets go
@(private = "file")
client_gone :: proc(c: ^langs.Client, removed: bool) {
	if g.lsp.hover.client == c do lsp_hover_close()
	if g.lsp.rename.client == c do lsp_rename_close()
	lsp_completion_forget_client(c)

	if !removed do return
	lsp_edits_forget_client(c)
	if g.lsp.popup.target == c do g.lsp.popup.target = nil
}


// A response, handed to what asked. A hover or definition is dropped if the
// text changed since the answer was read (its offsets are in that text); lists
// of places check that per place
@(private = "file")
lsp_response :: proc(c: ^langs.Client, r: langs.Request, resp: lsp.Response) {
	e := request_editor(r)
	same_text := e != nil && e.buf.version == resp.version

	switch r.feature {
	case .Hover:
		if same_text do lsp_hover_response(r, resp)
	case .Definition:
		if same_text do definition_response(r, resp)
	case .References, .File_Symbols, .Workspace_Symbols:
		lsp_finder_response(r, resp)
	case .Completion, .Completion_Resolve:
		lsp_completion_response(r, resp)
	case .Signature_Help:
		lsp_signature_response(r, resp)
	case .Prepare_Rename, .Rename:
		lsp_rename_response(r, resp)
	}
}


// Moves the caret to the next problem after it (dir +1) or before it (-1),
// wrapping around, and shows what it is. False if there are none
lsp_step_problem :: proc(e: ^Editor, dir: int) -> bool {
	problems := e.lsp.problems[:]
	if len(problems) == 0 do return false

	head := e.sels[e.primary].head
	target := dir > 0 ? problems[0].lo : problems[len(problems) - 1].lo
	if dir > 0 {
		for p in problems {
			if p.lo > head {
				target = p.lo
				break
			}
		}
	} else {
		#reverse for p in problems {
			if p.lo < head {
				target = p.lo
				break
			}
		}
	}

	textedit.show_caret(e, false)
	textedit.set_single_selection(e, {target, target, -1})
	e.reveal = true
	e.center = true
	lsp_hover_at_caret(e)
	return true
}


// --- Installing --------------------------------------------------------------------

// Runs an install command of a server in a new terminal: `command`, else the
// lightest one offered. Its program is looked for again as the install's
// output comes, and once found the server starts for the open files
lsp_install :: proc(name: string, command := "") {
	server := langs.server(name)
	if server == nil do return

	command := command
	if command == "" {
		offered := langs.server_installs(server).offered
		if len(offered) == 0 do return
		command = offered[0].command
	}

	p := panes_run_in_terminal(command)
	append(&g.lsp.installs, Lsp_Install{pane = p.id, server = strings.clone(name)})
}


// The tooltip of a button that runs an install command (temp)
install_tip :: proc(x: langs.Install) -> string {
	if x.builds do return fmt.tprintf("Run %s in a terminal (builds from source)", x.command)
	return fmt.tprintf("Run %s in a terminal", x.command)
}


// What a server's install commands need when none can run, e.g. "Needs uv or
// npm"; "" when one can, or while they are looked for (temp)
install_needs :: proc(installs: langs.Installs) -> string {
	if installs.needs == "" do return ""
	return fmt.tprintf("Needs %s", installs.needs)
}


// Whether a server's install command is running in a terminal
lsp_installing :: proc(name: string) -> bool {
	for x in g.lsp.installs {
		if x.server == name do return true
	}
	return false
}


// Each frame: looks for the programs being installed after new output (one
// lookup at a time, so the last output is always followed by one), and
// forgets an install once its program is found or its terminal closes
@(private = "file")
watch_installs :: proc() {
	langs.timed()
	l := &g.lsp
	for i := len(l.installs) - 1; i >= 0; i -= 1 {
		x := &l.installs[i]
		t := terminal_with_id(x.pane)
		server := langs.server(x.server)

		found := false
		if server != nil {
			path, known := langs.server_path(server)
			found = known && path != ""
		}
		if t == nil || server == nil || found {
			delete(x.server)
			ordered_remove(&l.installs, i)
			continue
		}

		if t.session.parsed != x.seen {
			x.seen = t.session.parsed
			x.again = true
		}
		if x.again && langs.recheck_program(server) {
			x.again = false
		}
	}
}


// The terminal of the pane with this id, if it is open
@(private = "file")
terminal_with_id :: proc(id: u32) -> ^Terminal {
	for p in g.panes.open {
		t, is_terminal := p.content.(^Terminal)
		if is_terminal && p.id == id {
			return t
		}
	}
	return nil
}


// --- Server actions (the status popup, the settings window) -------------------------

// Turns a server on or off. Its table keeps `enabled` only where it differs
// from the default
lsp_set_server_enabled :: proc(name: string, on: bool) {
	spec, builtin := langs.builtin_server(name)
	default := builtin ? spec.enabled : true

	o := langs.server_override(&g.settings.servers, name)
	o.enabled = on
	if on == default do o.enabled = nil
	settings_changed()
}


// Opens a client's log beside the focused pane (next frame); false if it has
// none
lsp_open_log :: proc(c: ^langs.Client) -> bool {
	if c.log_path == "" do return false

	defer_action(Open_Beside(strings.clone(c.log_path)))
	return true
}


// --- Go to definition --------------------------------------------------------------

// Asks for hover information at `offset`; 0 and nil if no server of the
// editor has it
lsp_request_hover :: proc(e: ^Editor, offset: int) -> (id: int, c: ^langs.Client) {
	langs.timed()
	c = langs.client_with(&e.lsp, .Hover)
	if c == nil do return 0, nil
	return langs.send_request(&e.lsp, c, .Hover, "textDocument/hover", offset), c
}


// Asks where the symbol at `offset` is defined, and goes there when the answer
// comes. False if no server of the editor can say
lsp_go_to_definition :: proc(e: ^Editor, offset: int) -> bool {
	langs.timed()
	c := langs.client_with(&e.lsp, .Definition)
	if c == nil do return false

	langs.send_request(&e.lsp, c, .Definition, "textDocument/definition", offset)
	return true
}


@(private = "file")
definition_response :: proc(r: langs.Request, resp: lsp.Response) {
	places, _ := resp.result.([]lsp.Place)
	if resp.error != "" || len(places) == 0 {
		lsp_hover_message(request_editor(r), r.offset, "No definition found")
		return
	}

	// Several go to the finder to choose from
	if len(places) > 1 {
		lsp_list_places(r, places, "definitions")
		return
	}

	place := places[0]
	if place.path == "" do return
	jump_to(place.path, place_target(place, r.client.encoding, editor_with_path(place.path)))
}


// Where the caret goes for a place: its offset if it is in `e`, an open file
// whose text hasn't changed since, else the server's position
place_target :: proc(place: lsp.Place, encoding: lsp.Encoding, e: ^Editor) -> Open_Target {
	has_text := e != nil && e.status == .Text
	if has_text && place.offset >= 0 && e.buf.version == place.version {
		return place.offset
	}
	return Lsp_Target{place.position, encoding}
}


// --- The jump list -----------------------------------------------------------------

// Goes to a place in a file (opening it), remembering where the caret was so
// Go back returns there
jump_to :: proc(path: string, target: Open_Target) {
	if g.pending != nil do return

	if e := focused_editor(); e != nil && e.status == .Text {
		push_jump(&g.jumps.back, e.path, e.sels[e.primary].head)
		clear_jumps(&g.jumps.forward)
	}
	open_at(path, target)
}


// Back to the place before the last jump; false if there is none
jump_back :: proc() -> bool {
	return step_jump(&g.jumps.back, &g.jumps.forward)
}


jump_forward :: proc() -> bool {
	return step_jump(&g.jumps.forward, &g.jumps.back)
}


jumps_destroy :: proc() {
	clear_jumps(&g.jumps.back)
	clear_jumps(&g.jumps.forward)
	delete(g.jumps.back)
	delete(g.jumps.forward)
}


// Goes to the last place of `from`, recording where the caret is now in `to`
@(private = "file")
step_jump :: proc(from, to: ^[dynamic]Jump) -> bool {
	if len(from) == 0 || g.pending != nil {
		return false
	}

	j := pop(from)
	defer delete(j.path)

	if e := focused_editor(); e != nil && e.status == .Text {
		push_jump(to, e.path, e.sels[e.primary].head)
	}
	open_at(j.path, j.offset)
	return true
}


@(private = "file")
push_jump :: proc(list: ^[dynamic]Jump, path: string, offset: int) {
	if len(list) >= MAX_JUMPS {
		delete(list[0].path)
		ordered_remove(list, 0)
	}
	append(list, Jump{strings.clone(path), offset})
}


@(private = "file")
clear_jumps :: proc(list: ^[dynamic]Jump) {
	for j in list do delete(j.path)
	clear(list)
}


// Opens a file (next frame) with the caret at `target`
@(private = "file")
open_at :: proc(path: string, target: Open_Target) {
	if g.pending != nil do return

	g.pending = Open_File(strings.clone(path))
	g.open_target = target
}


// Puts the caret of a file just opened at its target, in view
apply_open_target :: proc(e: ^Editor, target: Open_Target) {
	if e.status != .Text do return

	offset: int
	switch t in target {
	case int:        offset = t
	case Lsp_Target: offset = lsp.offset_at(&e.buf, t.position, t.encoding)
	}
	offset = clamp(offset, 0, buffer.length(&e.buf))

	textedit.show_caret(e, false)
	textedit.set_single_selection(e, {offset, offset, -1})
	e.reveal = true
	e.center = true
}
