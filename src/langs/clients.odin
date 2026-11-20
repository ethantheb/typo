package langs

// The app's language servers: which are configured (config.odin), the running
// clients, one per server and project root, attached when a file they serve
// opens (docs.odin), and what they report. All the work happens on other
// threads (package lsp): here the UI thread queues and takes. Each frame
// `frame` takes the clients' events and the lookups' answers; a client that
// crashes restarts, up to a limit. What the app has to say or know comes
// through `env`

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../lsp"


State :: struct {
	active:      bool, // servers may be started (set by the app; tests set it themselves)
	servers:     [dynamic]Server,
	languages:   [dynamic]lsp.Language, // added by settings.toml
	fingerprint: string,                // owned; the settings the server list was built from
	clients:     [dynamic]^Client,      // behind pointers: documents point at them
	retiring:    [dynamic]^lsp.Client,  // exiting on their threads; freed once they have
	events:      [dynamic]lsp.Event,    // this frame's, from one client at a time
	requests:    [dynamic]Request,      // waiting for their responses

	// Programs on PATH and project roots, looked up on the lookup thread
	lookups:     lsp.Lookups,
	answers:     [dynamic]lsp.Lookup, // this frame's
	programs:    map[string]Answer,   // by command name or path (keys owned)
	roots:       map[string]Answer,   // by folder and root markers (keys owned)

	ui_time:     time.Duration, // spent here since the perf suite last looked (`timed`)
	timing:      int,           // `timed` calls under way
}

Client :: struct {
	using client:    ^lsp.Client, // a restart retires it and starts a new one
	stopped_by_user: bool,
	crashes:         [dynamic]time.Tick, // recent crashes, for the restart limit
	restart_at:      Maybe(time.Tick),   // a restart waiting for its delay
	message:         string,             // owned; the last window/showMessage
	server_key:      string,             // owned; its server's settings as it started
}

// A command that installs a server, offered because its program is found
Install :: struct {
	command: string,
	builds:  bool, // compiles the server from source
}

// How a server can be installed (server_installs)
Installs :: struct {
	offered: []Install, // lightest first (temp)
	needs:   string,    // none offered: what any command needs, e.g. "uv, npm or pip" (temp)
	known:   bool,      // every command's program has been looked for
}

// A lookup's answer
Answer :: struct {
	value:    string, // owned; the program's path ("" if not found), or the root
	known:    bool,   // answered at least once
	checking: bool,   // a lookup is under way
}

// What the app tells and is told
Env :: struct {
	config:      proc() -> Config,
	documents:   proc() -> []^Doc,   // the open text documents (temp), their views set
	doc_closing: proc(doc: ^Doc),    // nothing of the app may keep pointing at it
	client_gone: proc(c: ^Client, removed: bool), // stopped, crashed, restarted, removed
	response:    proc(c: ^Client, r: Request, resp: lsp.Response),
	apply_edit:  proc(c: ^Client, x: ^lsp.Apply_Edit), // a server's workspace/applyEdit
	wake:        lsp.Notify_Proc,    // from any thread: run a frame
}

Config :: struct {
	enabled:        bool,
	overrides:      []Server_Override,
	settings_path:  string, // logs go beside it; "" for none
	workspace_root: string,
}

state: State
env: Env

// A server that crashes this often within CRASH_WINDOW is left stopped
@(private = "file")
MAX_CRASHES :: 3
@(private = "file")
CRASH_WINDOW :: 3 * time.Minute
@(private = "file")
RESTART_DELAY :: 500 * time.Millisecond

// How long quitting waits for the servers to exit
@(private = "file")
QUIT_WAIT :: 500 * time.Millisecond


// After the settings were loaded or changed: rebuilds the server list (it
// points into the settings, which a reload replaces), and when the servers'
// settings changed, reconnects the open files to it
settings_changed :: proc() {
	timed()
	l := &state
	config := env.config()
	build_server_list(config.overrides, &l.servers, &l.languages)

	fingerprint := servers_fingerprint(config.enabled, config.overrides)
	if fingerprint == l.fingerprint do return

	delete(l.fingerprint)
	l.fingerprint = strings.clone(fingerprint)
	reattach_all()
}


// Stops the clients of servers that are now off or set up differently (their
// documents detach), then attaches the open files to the servers as configured.
// The other clients keep their documents
reattach_all :: proc() {
	docs := env.documents()

	// A file whose language changed (extensions in the settings) starts over
	for d in docs {
		language := lsp.language_for_path(d.view.path, state.languages[:])
		if d.uri != "" && language != d.language {
			doc_close(d)
		}
	}

	for i := len(state.clients) - 1; i >= 0; i -= 1 {
		c := state.clients[i]
		if !keep_client(c) do client_remove(c)
	}

	for d in docs do doc_open(d)
}


// Whether a client's server is still on and set up as it was when the client
// started (a program still being looked up for it was found before: it runs)
@(private = "file")
keep_client :: proc(c: ^Client) -> bool {
	s := server(c.name)
	if !env.config().enabled || s == nil || !s.enabled {
		return false
	}
	if server_key(s) != c.server_key do return false

	path, known := server_path(s)
	return path != "" || !known
}


// What a client depends on of its server's settings (temp)
@(private = "file")
server_key :: proc(s: ^Server) -> string {
	return fmt.tprintf(
		"%s\x00%v\x00%v\x00%v\x00%s\x00%s",
		s.path,
		s.command,
		s.languages,
		s.root_markers,
		s.settings,
		s.init_options,
	)
}


// Stops every client, e.g. when another folder opens
stop_all :: proc() {
	timed()
	for len(state.clients) > 0 {
		client_remove(state.clients[len(state.clients) - 1])
	}
	forget_answers(&state.roots)
}


// At exit: tells every server to exit, then waits for them together
destroy :: proc() {
	l := &state
	for c in l.clients do lsp.client_retire(c.client, QUIT_WAIT)
	for rc in l.retiring do lsp.client_retire(rc, QUIT_WAIT)

	for c in l.clients {
		free_client(c.client)
		free_app_client(c)
	}
	for rc in l.retiring do free_client(rc)
	delete(l.clients)
	delete(l.retiring)

	lsp.lookups_destroy(&l.lookups)
	for &x in l.answers do lsp.lookup_destroy(&x)
	delete(l.answers)
	forget_answers(&l.programs)
	forget_answers(&l.roots)
	delete(l.programs)
	delete(l.roots)

	delete(l.servers)
	delete(l.languages)
	delete(l.fingerprint)
	delete(l.events)
	delete(l.requests)
	l^ = {}
}


// The configured server named `name`, or nil
server :: proc(name: string) -> ^Server {
	for &s in state.servers {
		if s.name == name do return &s
	}
	return nil
}


// --- Lookups -----------------------------------------------------------------------

// The program a server runs: its path from settings.toml if set, else its
// command's first word found on PATH; "" if it isn't installed. Not `known`
// until the lookup thread has answered (`frame` then attaches the open files)
server_path :: proc(s: ^Server) -> (path: string, known: bool) {
	return program_path(program_name(s))
}


// A program's path: `name` itself if it is a path, else found on PATH; "" if
// there is none. Not `known` until the lookup thread has answered
@(private)
program_path :: proc(name: string) -> (path: string, known: bool) {
	if name == "" do return "", true

	if answer, found := state.programs[name]; found {
		return answer.value, answer.known
	}

	state.programs[strings.clone(name)] = {checking = true}
	lsp.lookup_program(lookups(), name, name)
	return "", false
}


// The install commands of a server whose programs are found, lightest first.
// One set up with a path to its program has none
server_installs :: proc(s: ^Server) -> Installs {
	timed()
	if s.path != "" do return {known = true}

	offered := make([dynamic]Install, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	known := true

	for command in lsp.order_installs(s.install) {
		installer := lsp.installer_for(command)
		if !slice.contains(names[:], installer.name) {
			append(&names, installer.name)
		}

		path, answered := program_path(lsp.command_program(command))
		if !answered {
			known = false
		} else if path != "" {
			append(&offered, Install{command, installer.builds})
		}
	}

	needs := ""
	if known && len(offered) == 0 {
		needs = or_list(names[:])
	}
	return {offered[:], needs, known}
}


// "a", "a or b", "a, b or c" (temp)
@(private = "file")
or_list :: proc(items: []string) -> string {
	if len(items) <= 1 {
		return len(items) == 1 ? items[0] : ""
	}

	last := len(items) - 1
	start := strings.join(items[:last], ", ", context.temp_allocator)
	return fmt.tprintf("%s or %s", start, items[last])
}


// What is looked for to run a server: its path, else its command's program
@(private = "file")
program_name :: proc(s: ^Server) -> string {
	if s.path != "" do return s.path
	if len(s.command) > 0 do return s.command[0]
	return ""
}


// Looks for the programs again (e.g. one was installed), keeping what was found
// until the new answers come
recheck_programs :: proc() {
	for name, &answer in state.programs {
		if answer.checking do continue
		answer.checking = true
		lsp.lookup_program(lookups(), name, name)
	}
}


// Looks for a server's program again, unless that is under way. Returns false
// if it is
recheck_program :: proc(s: ^Server) -> bool {
	name := program_name(s)
	answer, found := &state.programs[name]
	if !found {
		server_path(s)
		return true
	}
	if answer.checking do return false

	answer.checking = true
	lsp.lookup_program(lookups(), name, name)
	return true
}


// The project root a server sees a file in: the nearest folder up to the
// workspace with one of its root markers. Not `known` until looked up
root :: proc(s: ^Server, file: string) -> (root: string, known: bool) {
	dir := filepath.dir(file)
	markers := strings.join(s.root_markers, "\x00", context.temp_allocator)
	key := strings.concatenate({dir, "\x00", markers}, context.temp_allocator)

	if answer, found := state.roots[key]; found {
		return answer.value, answer.known
	}

	state.roots[strings.clone(key)] = {checking = true}
	lsp.lookup_root(lookups(), key, file, env.config().workspace_root, s.root_markers)
	return "", false
}


// The lookup thread's state, set up by the first lookup
@(private = "file")
lookups :: proc() -> ^lsp.Lookups {
	l := &state.lookups
	if l.wake == nil do lsp.lookups_init(l, env.wake, nil)
	return l
}


// The lookups answered since last frame; open files attach to servers found
@(private = "file")
take_answers :: proc() {
	l := &state
	if l.lookups.wake == nil do return

	lsp.lookups_take(&l.lookups, &l.answers)
	if len(l.answers) == 0 do return

	for &x in l.answers {
		answers := x.program != "" ? &l.programs : &l.roots
		if answer, found := &answers[x.key]; found {
			delete(answer.value)
			answer^ = {value = x.answer, known = true}
			x.answer = ""
		}
		lsp.lookup_destroy(&x)
	}
	clear(&l.answers)

	for d in env.documents() do doc_open(d)
}


@(private)
forget_answers :: proc(answers: ^map[string]Answer) {
	for key, answer in answers {
		delete(key)
		delete(answer.value)
	}
	clear(answers)
}


// --- Clients -----------------------------------------------------------------------

// The client of `s` for `root`, started if there is none
client_for :: proc(s: ^Server, root: string) -> ^Client {
	for c in state.clients {
		if c.name == s.name && c.root == root {
			return c
		}
	}

	c := new(Client)
	append(&state.clients, c)
	start_client(c, s, root)
	return c
}


@(private = "file")
start_client :: proc(c: ^Client, s: ^Server, root: string) {
	// The program as found, with the command's arguments
	args := len(s.command) > 0 ? s.command[1:] : nil
	command := make([]string, 1 + len(args), context.temp_allocator)
	command[0], _ = server_path(s)
	copy(command[1:], args)

	config := lsp.Client_Config {
		name         = s.name,
		root         = root,
		command      = command,
		settings     = s.settings,
		init_options = s.init_options,
		log_path     = log_path(s.name, root),
	}
	c.client = new(lsp.Client)
	lsp.client_start(c.client, config, env.wake, nil)
	delete(c.server_key)
	c.server_key = strings.clone(server_key(s))
}


// logs/<server>.log beside settings.toml; another root of the same server gets
// a file of its own (<server>-2.log, the first number no other root uses)
@(private = "file")
log_path :: proc(name, root: string) -> string {
	settings_path := env.config().settings_path
	if settings_path == "" do return ""
	dir := filepath.dir(settings_path)

	for n := 1; ; n += 1 {
		file := n == 1 ? fmt.tprintf("%s.log", name) : fmt.tprintf("%s-%d.log", name, n)
		path, _ := filepath.join({dir, "logs", file}, context.temp_allocator)
		if !log_in_use(path, root) do return path
	}
}


// Whether a client of another root writes the log at `path`
@(private = "file")
log_in_use :: proc(path, root: string) -> bool {
	for c in state.clients {
		if c.client == nil do continue // the one being started
		if c.root != root && c.log_path == path {
			return true
		}
	}
	return false
}


// Starts a client over, e.g. after a crash or from the status popup. Its
// documents are opened again on the new one
client_restart :: proc(c: ^Client) {
	timed()
	s := server(c.name)
	if s == nil do return

	root := strings.clone(c.root, context.temp_allocator)
	retire(c.client)
	c.client = nil
	start_client(c, s, root)
	c.stopped_by_user = false
	c.restart_at = nil
	docs_reset(c)
	client_gone(c, removed = false)
}


// Starts a client over at the user's asking: its crashes are forgotten too
restart_by_user :: proc(c: ^Client) {
	clear(&c.crashes)
	client_restart(c)
}


// Asks a client's server to exit; it stays listed, stopped, until started again
client_stop :: proc(c: ^Client) {
	timed()
	lsp.client_stop(c.client)
	c.stopped_by_user = true
	c.restart_at = nil
	client_gone(c, removed = false)
}


// Stops a client and forgets it, detaching the documents that used it
client_remove :: proc(c: ^Client) {
	timed()
	docs_detach(c)
	client_gone(c, removed = true)
	for other, i in state.clients {
		if other == c {
			ordered_remove(&state.clients, i)
			break
		}
	}

	retire(c.client)
	free_app_client(c)
}


// A client stopped, crashed, restarted or is being removed: its requests won't
// be answered, and the app lets go of what waits on it
@(private = "file")
client_gone :: proc(c: ^Client, removed: bool) {
	requests_forget_client(c)
	env.client_gone(c, removed)
}


// Frees what is kept about a client (its lsp.Client is retired or freed)
@(private = "file")
free_app_client :: proc(c: ^Client) {
	delete(c.crashes)
	delete(c.message)
	delete(c.server_key)
	free(c)
}


// Tells a client's server to exit; its thread sees to it, and `frame` frees the
// client once it is done. A new client of the server takes the log over
@(private = "file")
retire :: proc(client: ^lsp.Client) {
	lsp.client_close_log(client)
	lsp.client_retire(client)
	append(&state.retiring, client)
}


@(private = "file")
free_client :: proc(client: ^lsp.Client) {
	lsp.client_destroy(client)
	free(client)
}


// --- Each frame --------------------------------------------------------------------

// Takes what the clients and lookups reported, restarts crashed clients, and
// opens documents on new ones
frame :: proc() {
	timed()
	l := &state
	take_answers()

	// Clients that have exited
	for i := len(l.retiring) - 1; i >= 0; i -= 1 {
		rc := l.retiring[i]
		if !lsp.client_done(rc) do continue
		free_client(rc)
		unordered_remove(&l.retiring, i)
	}

	for c in l.clients {
		was := c.state
		lsp.client_poll(c.client, &l.events)
		for &ev in l.events {
			dispatch(c, &ev)
			lsp.event_destroy(&ev)
		}
		clear(&l.events)

		if c.state == .Crashed && was != .Crashed {
			crashed(c)
		}

		restart_at, waiting := c.restart_at.?
		if waiting && time.tick_since(restart_at) >= 0 {
			client_restart(c)
		}
	}

	open_pending_docs()
}


// Counts the time to the end of the caller's scope as language server work on
// the UI thread, which the perf suite limits. Nested calls count once
@(deferred_out = timed_end)
timed :: proc() -> time.Tick {
	state.timing += 1
	return time.tick_now()
}


@(private)
timed_end :: proc(start: time.Tick) {
	state.timing -= 1
	if state.timing == 0 do state.ui_time += time.tick_since(start)
}


// Whether frames must keep coming: a restart is waiting for its delay. (Threads
// wake the loop when they have something)
busy :: proc() -> bool {
	for c in state.clients {
		if c.restart_at != nil do return true
	}
	return false
}


@(private = "file")
dispatch :: proc(c: ^Client, ev: ^lsp.Event) {
	#partial switch &x in ev {
	case lsp.Diagnostics:
		diagnostics_published(c, &x)
	case lsp.Response:
		response(c, x)
	case lsp.Apply_Edit:
		env.apply_edit(c, &x)
	case lsp.Show_Message:
		delete(c.message)
		c.message, x.text = x.text, ""
	}
}


// A crash: restart after a moment, unless it keeps crashing
@(private = "file")
crashed :: proc(c: ^Client) {
	now := time.tick_now()
	for len(c.crashes) > 0 && time.tick_diff(c.crashes[0], now) > CRASH_WINDOW {
		ordered_remove(&c.crashes, 0)
	}
	append(&c.crashes, now)

	docs_reset(c)
	client_gone(c, removed = false)
	if len(c.crashes) < MAX_CRASHES {
		c.restart_at = time.tick_add(now, RESTART_DELAY)
	}
}
