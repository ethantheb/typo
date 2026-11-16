package lsp

// One server for one project root, as the UI thread sees it. The UI thread
// starts it, queues commands (documents, their edits, requests) and takes
// events (problems, answers), already decoded. Everything else runs on the
// client's own thread (worker.odin): starting the process, the handshake, JSON
// both ways, a copy of each document's text to convert positions against, and
// the log. Nothing here waits on the server or reads a file

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"


State :: enum {
	Starting, // the process starting, or initialize sent
	Running,
	Stopping, // shutdown sent, waiting for it to exit
	Stopped,
	Crashed,  // exited on its own, or never started
}

Client_Config :: struct {
	name:         string,
	root:         string,
	command:      []string,
	settings:     string, // JSON: the workspace configuration
	init_options: string, // JSON
	log_path:     string, // "" for no log
}

Client :: struct {
	using config: Client_Config, // owned copies; both threads read them

	// The UI thread's view of it, updated by client_poll
	state:        State,
	reason:       string,       // why it crashed or failed to start (owned)
	encoding:     Encoding,
	caps:         Capabilities, // once Running (owned)
	progress:     [dynamic]Progress,
	next_id:      int,          // of the next request

	// Shared with the client thread, guarded by mutex
	mutex:        sync.Mutex,
	cond:         sync.Cond,    // wakes the client thread
	commands:     [dynamic]Command,
	events:       [dynamic]Event,
	signaled:     bool,         // its connection has something
	stop:         Stop_Request, // the latest asked for
	stops:        int,          // how many were asked for

	// The log, written by the client thread; the UI thread closes it when a new
	// client takes the file over
	log_mutex:    sync.Mutex,
	log:          ^os.File,
	log_closed:   bool,

	thread:       ^thread.Thread,
	allocator:    runtime.Allocator, // of commands and events; both threads use it
	wake:         Notify_Proc,
	wake_data:    rawptr,
	taken:        [dynamic]Event, // client_poll's
	worker:       Worker,         // the client thread's own
}

// Work the server reports ($/progress), e.g. indexing
Progress :: struct {
	token:      string, // owned
	title:      string, // owned
	message:    string, // owned
	percentage: int,    // -1 if not reported
}

// One replacement in a document: [offset, offset+old_len) of the text the
// edits before it left becomes `text`. A negative old_len replaces it all
Edit :: struct {
	offset:  int,
	old_len: int,
	text:    string,
}

@(private)
Stop_Request :: struct {
	fast: bool, // send exit without waiting for shutdown's reply
	wait: time.Duration, // before the process is ended
}

// How long a server may take to shut down and exit before it is ended
STOP_TIMEOUT :: 2 * time.Second


// --- Events ------------------------------------------------------------------------

// What the client thread reports. client_poll applies Status_Change and
// Progress_Change itself and hands the rest on
Event :: union {
	Diagnostics,
	Response,
	Apply_Edit,
	Show_Message,
	Status_Change,
	Progress_Change,
}

// The problems a server reports in an open document, sorted by start, as byte
// ranges in its text at `version`
Diagnostics :: struct {
	uri:      string,    // owned; as the document was opened
	version:  u64,
	problems: []Problem, // owned, with their strings
}

Problem :: struct {
	lo, hi:   int,
	severity: int,    // 1 error, 2 warning, 3 information, 4 hint
	message:  string,
	source:   string, // who found it ("ruff", "ols"), may be ""
}

// The answer to a request. For one about a document, `version` is the
// document's when the answer was read: offsets in it are in that text
Response :: struct {
	id:      int,
	version: u64,
	error:   string, // owned; "" unless it failed
	result:  Result,
}

Result :: union {
	Hover,
	[]Place,
	[]Symbol,
	Completions,
	Completion, // a resolved item
	Signature_Help,
	Prepare_Rename,
	Workspace_Edit,
	Raw_Result,
}

// What a rename may change: the name as offsets (-1 when the server leaves that
// to the client: the word at the place), and the name to start from
Prepare_Rename :: struct {
	renamable:   bool, // false: nothing there can be renamed
	lo, hi:      int,
	placeholder: string, // owned; may be ""
}

// Completions at a place, as offsets in the document at the response's version
Completions :: struct {
	items:      []Completion, // owned
	incomplete: bool,         // typing more should ask again
}

Completion :: struct {
	label:         string, // owned
	signature:     string, // owned; shown after the label, e.g. "(a, b)"
	detail:        string, // owned; e.g. its type or module
	kind:          int,    // CompletionItemKind, 1-25
	filter:        string, // owned; matched against the word typed ("" = the label)
	sort:          string, // owned; the server's order ("" = the label)
	text:          string, // owned; inserted (a snippet reduced to plain text)
	select:        [2]int, // what is selected after inserting it, in `text`
	lo, hi:        int,    // what it replaces
	more:          []Edit, // owned; edits elsewhere (e.g. an import), in the same text
	preselect:     bool,
	documentation: string, // owned; Markdown
	resolve:       string, // owned; the item as JSON, to ask for the rest ("" if not)
}

// The call the caret is in. `count` is 0 when it is in none
Signature_Help :: struct {
	label:         string, // owned; the active signature
	param_lo:      int,    // the active parameter in label (bytes), or -1
	param_hi:      int,
	documentation: string, // owned; Markdown
	index, count:  int,    // which signature of how many
}

Hover :: struct {
	markdown: string, // owned; "" when there is nothing
	lo, hi:   int,    // the text it is about, if the server said; else -1
}

// A place in a file, e.g. a definition. If the file is an open document,
// `offset` is the place in its text at `version`, else -1
Place :: struct {
	path:     string, // owned; "" if the URI isn't a file
	position: Position,
	offset:   int,
	version:  u64,
	preview:  string, // owned; its line, trimmed, for a list of places (else "")
}

// A symbol of a document's outline or of the workspace, at its name
Symbol :: struct {
	name:   string, // owned
	detail: string, // owned; its detail (e.g. a signature), or what it is in
	kind:   int,    // SymbolKind, 1-26
	depth:  int,    // nesting in a document's outline
	place:  Place,
}

// The result of a request typo doesn't decode, as JSON (owned)
Raw_Result :: distinct string

// window/showMessage
Show_Message :: struct {
	text: string, // owned
}

Status_Change :: struct {
	state:    State,
	reason:   string, // owned
	encoding: Encoding,
	caps:     Maybe(Capabilities), // owned; when it starts running
}

Progress_Change :: struct {
	list: []Progress, // owned
}


// --- Commands ----------------------------------------------------------------------

@(private)
Command :: union {
	Open_Command,
	Change_Command,
	Save_Command,
	Close_Command,
	Request_Command,
	Cancel_Command,
	Reply_Command,
	Files_Changed_Command,
}

@(private)
Open_Command :: struct {
	uri:      string, // owned
	language: string, // owned
	version:  u64,
	text:     []u8,   // owned
}

@(private)
Change_Command :: struct {
	uri:     string, // owned
	version: u64,
	edits:   []Edit, // owned, with their text
}

@(private)
Save_Command :: struct {
	uri: string, // owned
}

@(private)
Close_Command :: struct {
	uri: string, // owned
}

@(private)
Request_Command :: struct {
	id:     int,
	method: string, // owned
	uri:    string, // owned; the document asked about at offset, or ""
	offset: int,
	params: string, // owned; JSON, when not about a document
	query:  string, // owned; of a workspace/symbol request, a completion's trigger, a new name
	reason: Completion_Trigger, // why completions are asked for
}

@(private)
Cancel_Command :: struct {
	id: int,
}

// The answer to a server's workspace/applyEdit
@(private)
Reply_Command :: struct {
	id:      string, // owned; the request's id, as JSON
	applied: bool,
	reason:  string, // owned; why it wasn't
}

@(private)
Files_Changed_Command :: struct {
	paths: []string, // owned
}


// --- Starting and stopping ---------------------------------------------------------

// Starts the client's thread, which starts the server. `wake` is called from
// that thread when there are events to take. `c` must not move until destroyed
client_start :: proc(c: ^Client, config: Client_Config, wake: Notify_Proc, wake_data: rawptr) {
	c^ = {}
	c.name = strings.clone(config.name)
	c.root = strings.clone(config.root)
	c.command = make([]string, len(config.command))
	for arg, i in config.command do c.command[i] = strings.clone(arg)
	c.settings = strings.clone(config.settings)
	c.init_options = strings.clone(config.init_options)
	c.log_path = strings.clone(config.log_path)
	c.next_id = 1
	c.allocator = context.allocator
	c.wake = wake
	c.wake_data = wake_data

	ctx := runtime.default_context()
	ctx.allocator = c.allocator
	c.thread = thread.create_and_start_with_poly_data(c, worker_proc, ctx)
}


// Asks the server to shut down, then exit; it is ended if it takes longer than
// STOP_TIMEOUT. The state becomes Stopped
client_stop :: proc(c: ^Client) {
	request_stop(c, {fast = false, wait = STOP_TIMEOUT})
}


// Tells the server to exit without waiting for anything, ending it after
// `wait`; for a client being replaced or freed (see client_done)
client_retire :: proc(c: ^Client, wait := STOP_TIMEOUT) {
	request_stop(c, {fast = true, wait = wait})
}


// Whether the client's thread has finished: the server exited or was ended
client_done :: proc(c: ^Client) -> bool {
	return c.thread == nil || thread.is_done(c.thread)
}


// Frees everything. A server still running is told to exit and given up to
// `wait_ms` (less if client_retire asked for less), then ended
client_destroy :: proc(c: ^Client, wait_ms := 500) {
	if c.thread != nil {
		if !thread.is_done(c.thread) {
			request_stop(c, {fast = true, wait = time.Duration(wait_ms) * time.Millisecond})
		}
		thread.destroy(c.thread) // waits for it
	}

	// What the threads left
	for &cmd in c.commands do command_destroy(&cmd)
	for &ev in c.events do event_destroy(&ev)
	delete(c.commands)
	delete(c.events)
	delete(c.taken)

	delete(c.name)
	delete(c.root)
	for arg in c.command do delete(arg)
	delete(c.command)
	delete(c.settings)
	delete(c.init_options)
	delete(c.log_path)
	delete(c.reason)
	capabilities_destroy(&c.caps)
	for &p in c.progress do progress_destroy(&p)
	delete(c.progress)
	if c.log != nil do os.close(c.log)
	c^ = {}
}


// Stops writing the log, e.g. for a client being replaced by one that will
// write the same file
client_close_log :: proc(c: ^Client) {
	sync.guard(&c.log_mutex)
	c.log_closed = true
	if c.log == nil do return

	os.close(c.log)
	c.log = nil
}


@(private = "file")
request_stop :: proc(c: ^Client, stop: Stop_Request) {
	sync.guard(&c.mutex)
	c.stop = stop
	c.stops += 1
	sync.cond_signal(&c.cond)
}


// --- Documents ---------------------------------------------------------------------

// Opens a document on the server (once it is running). Takes `text`, which
// must come from the allocator the client was started with
client_open :: proc(c: ^Client, uri, language: string, version: u64, text: []u8) {
	push(c, Open_Command {
		uri      = strings.clone(uri, c.allocator),
		language = strings.clone(language, c.allocator),
		version  = version,
		text     = text,
	})
}


// A document's edits, in order, bringing it to `version`
client_change :: proc(c: ^Client, uri: string, version: u64, edits: []Edit) {
	owned := make([]Edit, len(edits), c.allocator)
	for edit, i in edits {
		owned[i] = {edit.offset, edit.old_len, strings.clone(edit.text, c.allocator)}
	}
	push(c, Change_Command{strings.clone(uri, c.allocator), version, owned})
}


client_save :: proc(c: ^Client, uri: string) {
	push(c, Save_Command{strings.clone(uri, c.allocator)})
}


client_close :: proc(c: ^Client, uri: string) {
	push(c, Close_Command{strings.clone(uri, c.allocator)})
}


// --- Requests ----------------------------------------------------------------------

// Asks about the text at `offset` of an open document (`method` takes a
// document and a position: hover, definition, references), or about the whole
// document (documentSymbol, offset unused). The answer comes as a Response with
// the returned id
request :: proc(c: ^Client, method, uri: string, offset: int) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone(method, c.allocator),
		uri    = strings.clone(uri, c.allocator),
		offset = offset,
	})
	return id
}


// Sends a request with its parameters as JSON; the answer is a Raw_Result
request_json :: proc(c: ^Client, method, params: string) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone(method, c.allocator),
		params = strings.clone(params, c.allocator),
	})
	return id
}


// Asks for the workspace's symbols matching `query`; the answer is a []Symbol
request_symbols :: proc(c: ^Client, query: string) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone("workspace/symbol", c.allocator),
		query  = strings.clone(query, c.allocator),
	})
	return id
}


// Asks for completions at `offset` of an open document, for `reason` (on a
// trigger character, `trigger`). The answer is Completions
request_completion :: proc(
	c: ^Client,
	uri: string,
	offset: int,
	reason: Completion_Trigger,
	trigger := "",
) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone("textDocument/completion", c.allocator),
		uri    = strings.clone(uri, c.allocator),
		offset = offset,
		query  = strings.clone(trigger, c.allocator),
		reason = reason,
	})
	return id
}


// Asks for the rest of a completion item (its documentation, edits), given as
// Completion.resolve; the answer is a Completion
request_resolve :: proc(c: ^Client, uri, item: string) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone("completionItem/resolve", c.allocator),
		uri    = strings.clone(uri, c.allocator),
		params = strings.clone(item, c.allocator),
	})
	return id
}


// Asks to rename the symbol at `offset` of an open document; the answer is a
// Workspace_Edit (asked for first with textDocument/prepareRename, whose answer
// is a Prepare_Rename)
request_rename :: proc(c: ^Client, uri: string, offset: int, new_name: string) -> int {
	id := c.next_id
	c.next_id += 1
	push(c, Request_Command {
		id     = id,
		method = strings.clone("textDocument/rename", c.allocator),
		uri    = strings.clone(uri, c.allocator),
		offset = offset,
		query  = strings.clone(new_name, c.allocator),
	})
	return id
}


// Tells the server a request's answer is no longer wanted
cancel :: proc(c: ^Client, id: int) {
	push(c, Cancel_Command{id})
}


// Answers the server's workspace/applyEdit (Apply_Edit.id): whether the edit
// was made, and if not, why
reply_apply_edit :: proc(c: ^Client, id: string, applied: bool, reason := "") {
	push(c, Reply_Command {
		id      = strings.clone(id, c.allocator),
		applied = applied,
		reason  = strings.clone(reason, c.allocator),
	})
}


// Tells the server files changed on disk (e.g. a rename rewrote them)
client_files_changed :: proc(c: ^Client, paths: []string) {
	owned := make([]string, len(paths), c.allocator)
	for path, i in paths do owned[i] = strings.clone(path, c.allocator)
	push(c, Files_Changed_Command{owned})
}


@(private = "file")
push :: proc(c: ^Client, cmd: Command) {
	cmd := cmd
	if c.state == .Stopped || c.state == .Crashed {
		command_destroy(&cmd)
		return
	}

	sync.guard(&c.mutex)
	append(&c.commands, cmd)
	sync.cond_signal(&c.cond)
}


// --- Events ------------------------------------------------------------------------

// Takes what the client thread reported: applies changes of state and progress,
// and appends the rest to `out`. The caller frees those with event_destroy
client_poll :: proc(c: ^Client, out: ^[dynamic]Event) {
	if sync.guard(&c.mutex) {
		c.events, c.taken = c.taken, c.events
	}

	for &ev in c.taken {
		#partial switch &x in ev {
		case Status_Change:
			c.state = x.state
			c.encoding = x.encoding
			delete(c.reason)
			c.reason, x.reason = x.reason, ""
			if caps, has_caps := x.caps.?; has_caps {
				capabilities_destroy(&c.caps)
				c.caps = caps
				x.caps = nil
			}
			event_destroy(&ev)

		case Progress_Change:
			for &p in c.progress do progress_destroy(&p)
			clear(&c.progress)
			append(&c.progress, ..x.list)
			delete(x.list)

		case:
			append(out, ev)
		}
	}
	clear(&c.taken)
}


event_destroy :: proc(ev: ^Event) {
	switch &x in ev {
	case Diagnostics:
		delete(x.uri)
		problems_destroy(x.problems)

	case Response:
		delete(x.error)
		switch r in x.result {
		case Hover:
			delete(r.markdown)
		case []Place:
			for place in r {
				delete(place.path)
				delete(place.preview)
			}
			delete(r)
		case []Symbol:
			for s in r {
				delete(s.name)
				delete(s.detail)
				delete(s.place.path)
				delete(s.place.preview)
			}
			delete(r)
		case Completions:
			for &item in r.items do completion_destroy(&item)
			delete(r.items)
		case Completion:
			item := r
			completion_destroy(&item)
		case Signature_Help:
			delete(r.label)
			delete(r.documentation)
		case Prepare_Rename:
			delete(r.placeholder)
		case Workspace_Edit:
			edit := r
			workspace_edit_destroy(&edit)
		case Raw_Result:
			delete(string(r))
		}

	case Apply_Edit:
		delete(x.id)
		delete(x.label)
		workspace_edit_destroy(&x.edit)

	case Show_Message:
		delete(x.text)

	case Status_Change:
		delete(x.reason)
		if caps, has_caps := x.caps.?; has_caps {
			capabilities_destroy(&caps)
		}

	case Progress_Change:
		for &p in x.list do progress_destroy(&p)
		delete(x.list)
	}
	ev^ = nil
}


// Frees a completion item's strings and edits
completion_destroy :: proc(c: ^Completion) {
	delete(c.label)
	delete(c.signature)
	delete(c.detail)
	delete(c.filter)
	delete(c.sort)
	delete(c.text)
	for edit in c.more do delete(edit.text)
	delete(c.more)
	delete(c.documentation)
	delete(c.resolve)
	c^ = {}
}


@(private)
command_destroy :: proc(cmd: ^Command) {
	switch &x in cmd {
	case Open_Command:
		delete(x.uri)
		delete(x.language)
		delete(x.text)
	case Change_Command:
		delete(x.uri)
		for edit in x.edits do delete(edit.text)
		delete(x.edits)
	case Save_Command:
		delete(x.uri)
	case Close_Command:
		delete(x.uri)
	case Request_Command:
		delete(x.method)
		delete(x.uri)
		delete(x.params)
		delete(x.query)
	case Cancel_Command:
	case Reply_Command:
		delete(x.id)
		delete(x.reason)
	case Files_Changed_Command:
		for path in x.paths do delete(path)
		delete(x.paths)
	}
	cmd^ = nil
}


@(private)
progress_destroy :: proc(p: ^Progress) {
	delete(p.token)
	delete(p.title)
	delete(p.message)
}
