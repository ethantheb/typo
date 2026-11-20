package lsp

// A client's own thread: starts the server and does the handshake, turns the
// UI thread's commands into messages and the server's messages into events,
// answers the server's requests that need no UI, and writes the log. It keeps
// each open document's text as the server has it, so positions are converted
// here, against the text they were sent for

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "../buffer"


@(private)
Worker :: struct {
	conn:        Connection,
	state:       State,
	caps:        Capabilities,
	encoding:    Encoding,
	last_id:     int, // of the last request sent (servers may read ids as 32-bit)
	init_id:     int,
	shutdown_id: int,
	stops:       int,       // stop requests seen
	deadline:    time.Tick, // when a server that is stopping gets ended
	init_until:  time.Tick, // when a server that hasn't answered initialize fails
	exit_sent:   bool,
	last_error:  string,    // the last line the server wrote to stderr (owned)
	docs:        [dynamic]^Doc,
	requests:    map[int]Pending, // by the id it was sent with
	progress:    [dynamic]Progress,
	commands:    [dynamic]Command, // taken from the UI thread
	bodies:      [dynamic][]u8,
	events:      [dynamic]Event,   // for the UI thread
}

// A document open on the server, with its text as the server has it
@(private)
Doc :: struct {
	uri:     string, // owned
	path:    string, // owned; for URIs the server spells differently
	version: u64,
	text:    buffer.Buffer,
}

// A request of the UI thread's, waiting for its answer
@(private)
Pending :: struct {
	ui_id:  int,    // the id the UI thread knows it by
	method: string, // owned
	uri:     string, // owned; "" if not about a document
	offset:  int,    // in the document, where it asked about
	version: u64,    // of the document when it was sent
}

// How long a server may take to answer initialize
@(private = "file")
INIT_TIMEOUT :: 60 * time.Second

// Error codes of responses
@(private = "file")
METHOD_NOT_FOUND :: -32601

// For a list of places, the files that aren't open read for preview lines (at
// most this many per answer, none larger than MAX_PREVIEW_FILE_SIZE)
@(private = "file")
MAX_PREVIEW_FILES :: 200
@(private = "file")
MAX_PREVIEW_FILE_SIZE :: 4 * 1024 * 1024
@(private = "file")
MAX_PREVIEW_LEN :: 200 // bytes of a preview line kept

// The most completion items taken from an answer
@(private = "file")
MAX_COMPLETIONS :: 5000


@(private)
worker_proc :: proc(c: ^Client) {
	w := &c.worker
	open_log(c)
	start(c)
	post(c)

	for w.state != .Stopped && w.state != .Crashed {
		stop, stopping := wait(c)
		step(c)
		if stopping do begin_stop(c, stop)
		check_exit(c)
		post(c)
		free_all(context.temp_allocator)
	}

	worker_destroy(c)
}


// Starts the server and sends initialize; on failure the client is Crashed
@(private = "file")
start :: proc(c: ^Client) {
	w := &c.worker
	command := strings.join(c.command, " ", context.temp_allocator)
	log_line(c, "starting %s in %s", command, c.root)

	ok, reason := conn_start(&w.conn, c.command, c.root, signal, c)
	if !ok {
		fail(c, reason)
		return
	}

	root_uri := uri_from_path(c.root, context.temp_allocator)
	params := Initialize_Params {
		process_id   = os.get_pid(),
		client_info  = {"typo", "0.1"},
		root_uri     = root_uri,
		root_path    = c.root,
		folders      = {{root_uri, base_name(c.root)}},
		capabilities = client_capabilities(),
		init_options = parse_json(c.init_options),
	}
	w.init_id = next_id(w)
	w.init_until = time.tick_add(time.tick_now(), INIT_TIMEOUT)
	send(c, envelope(w.init_id, "initialize", to_json(params)), force = true)
}


@(private = "file")
worker_destroy :: proc(c: ^Client) {
	w := &c.worker
	conn_stop(&w.conn, 0)

	capabilities_destroy(&w.caps)
	for doc in w.docs do doc_destroy(doc)
	delete(w.docs)
	for _, p in w.requests {
		delete(p.method)
		delete(p.uri)
	}
	delete(w.requests)
	for &p in w.progress do progress_destroy(&p)
	delete(w.progress)
	for &cmd in w.commands do command_destroy(&cmd)
	delete(w.commands)
	delete(w.bodies)
	for &ev in w.events do event_destroy(&ev)
	delete(w.events)
	delete(w.last_error)

	sync.guard(&c.log_mutex)
	if c.log != nil do os.close(c.log)
	c.log = nil
}


// Called by the connection's threads when the server sent something or exited
@(private = "file")
signal :: proc "contextless" (data: rawptr) {
	c := (^Client)(data)
	sync.mutex_lock(&c.mutex)
	c.signaled = true
	sync.cond_signal(&c.cond)
	sync.mutex_unlock(&c.mutex)
}


// Waits until there is something to do: the server sent something, the UI
// thread sent commands (taken only while running) or asked it to stop, or a
// starting or stopping server ran out of time. Returns a new stop request, if any
@(private = "file")
wait :: proc(c: ^Client) -> (stop: Stop_Request, stopping: bool) {
	w := &c.worker
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)

	for !has_work(c) {
		timed := w.state == .Starting || w.state == .Stopping
		if !timed {
			sync.cond_wait(&c.cond, &c.mutex)
			continue
		}

		until := w.state == .Starting ? w.init_until : w.deadline
		left := time.tick_diff(time.tick_now(), until)
		if left <= 0 do break
		sync.cond_wait_with_timeout(&c.cond, &c.mutex, left)
	}

	c.signaled = false
	if w.state == .Running {
		w.commands, c.commands = c.commands, w.commands
	}
	if c.stops != w.stops {
		w.stops = c.stops
		return c.stop, true
	}
	return {}, false
}


// Whether the thread has something to do; c.mutex is held
@(private = "file")
has_work :: proc(c: ^Client) -> bool {
	w := &c.worker
	if c.signaled || c.stops != w.stops {
		return true
	}
	return w.state == .Running && len(c.commands) > 0
}


// What the server sent (first: it was about the text before these commands'
// edits), then the commands
@(private = "file")
step :: proc(c: ^Client) {
	w := &c.worker

	// Its stderr goes to the log; the last line explains a crash
	if errors := conn_take_errors(&w.conn); errors != "" {
		log_text(c, errors)
		if line := last_line(errors); line != "" {
			delete(w.last_error)
			w.last_error = strings.clone(line)
		}
	}

	// While stopping only shutdown's reply matters (a response has no method);
	// the rest goes unread
	clear(&w.bodies)
	conn_take(&w.conn, &w.bodies)
	for body in w.bodies {
		text := string(body)
		unread := w.state == .Stopping && (w.exit_sent || strings.contains(text, `"method"`))
		if !unread do receive(c, text)
		delete(body, w.conn.allocator)
	}

	for &cmd in w.commands do run_command(c, &cmd)
	clear(&w.commands)
}


// Hands the events to the UI thread and wakes it
@(private = "file")
post :: proc(c: ^Client) {
	w := &c.worker
	if len(w.events) == 0 do return

	if sync.guard(&c.mutex) {
		append(&c.events, ..w.events[:])
	}
	clear(&w.events)
	c.wake(c.wake_data)
}


@(private = "file")
set_state :: proc(c: ^Client, state: State, reason := "") {
	w := &c.worker
	w.state = state
	append(&w.events, Status_Change{state, strings.clone(reason), w.encoding, nil})
}


// The client can't run; `reason` is shown in the status popup
@(private = "file")
fail :: proc(c: ^Client, reason: string) {
	log_line(c, "failed: %s", reason)
	set_state(c, .Crashed, reason)
}


// The id for the next request sent: every request, the UI thread's too, is
// numbered here, from 1
@(private = "file")
next_id :: proc(w: ^Worker) -> int {
	w.last_id += 1
	return w.last_id
}


// --- Stopping ----------------------------------------------------------------------

@(private = "file")
begin_stop :: proc(c: ^Client, stop: Stop_Request) {
	w := &c.worker
	deadline := time.tick_add(time.tick_now(), stop.wait)

	#partial switch w.state {
	case .Starting:
		conn_stop(&w.conn, 0)
		log_line(c, "stopped while starting")
		set_state(c, .Stopped)

	case .Running:
		w.shutdown_id = next_id(w)
		send(c, envelope(w.shutdown_id, "shutdown", ""))
		if stop.fast do send_exit(c)
		w.deadline = deadline
		set_state(c, .Stopping)

	case .Stopping:
		// Asked again, e.g. at exit: maybe sooner
		if stop.fast do send_exit(c)
		if time.tick_diff(deadline, w.deadline) > 0 do w.deadline = deadline
	}
}


@(private = "file")
send_exit :: proc(c: ^Client) {
	w := &c.worker
	if w.exit_sent do return

	send(c, envelope(-1, "exit", ""))
	w.exit_sent = true
}


// Notices the server exiting (Stopped if it was asked to, else Crashed), or a
// stopping server taking too long, which is ended
@(private = "file")
check_exit :: proc(c: ^Client) {
	w := &c.worker

	#partial switch w.state {
	case .Stopping:
		if conn_ended(&w.conn) {
			conn_stop(&w.conn, 1000)
			log_line(c, "exited")
			set_state(c, .Stopped)
		} else if time.tick_diff(w.deadline, time.tick_now()) >= 0 {
			conn_stop(&w.conn, 0)
			log_line(c, "ended after shutdown timed out")
			set_state(c, .Stopped)
		}

	case .Starting, .Running:
		late := w.state == .Starting && time.tick_diff(w.init_until, time.tick_now()) >= 0
		if late {
			conn_stop(&w.conn, 0)
			fail(c, "it didn't answer initialize within a minute")
			return
		}
		if !conn_ended(&w.conn) do return

		code := process_exit_code(&w.conn.process)
		conn_stop(&w.conn, 1000)
		reason := fmt.tprintf("exited with code %d", code)
		if w.last_error != "" do reason = fmt.tprintf("%s: %s", reason, w.last_error)
		fail(c, reason)
	}
}


// --- Sending -----------------------------------------------------------------------

// A request or notification (id -1) as JSON; `params` is JSON, "" for none
@(private = "file")
envelope :: proc(id: int, method: string, params: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0",`)
	if id >= 0 do fmt.sbprintf(&sb, `"id":%d,`, id)
	fmt.sbprintf(&sb, `"method":%s`, to_json(method))
	if params != "" do fmt.sbprintf(&sb, `,"params":%s`, params)
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}


@(private = "file")
notify :: proc(c: ^Client, method: string, params: string) {
	send(c, envelope(-1, method, params))
}


// Replies to a request from the server
@(private = "file")
respond :: proc(c: ^Client, id: json.Value, result: any) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}}`, to_json(id), to_json(result))
	send(c, body, force = true)
}


@(private = "file")
respond_error :: proc(c: ^Client, id: json.Value, code: int, message: string) {
	Error :: struct {
		code:    int `json:"code"`,
		message: string `json:"message"`,
	}
	err := to_json(Error{code, message})
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":%s}}`, to_json(id), err)
	send(c, body, force = true)
}


// Writes a message. Until the server is initialized only `force`d ones go
// (initialize itself, replies); the UI thread's commands wait until then
@(private = "file")
send :: proc(c: ^Client, body: string, force := false) {
	w := &c.worker
	#partial switch w.state {
	case .Starting:
		if !force do return
	case .Running, .Stopping:
	case:
		return
	}

	log_line(c, "--> %s", summary(body))
	conn_send(&w.conn, body)
}


// --- Commands ----------------------------------------------------------------------

@(private = "file")
run_command :: proc(c: ^Client, cmd: ^Command) {
	switch &x in cmd {
	case Open_Command:    open_doc(c, &x)
	case Change_Command:  change_doc(c, x)
	case Save_Command:    save_doc(c, x)
	case Close_Command:   close_doc(c, x)
	case Request_Command: send_request(c, &x)
	case Cancel_Command:  cancel_request(c, x)
	case Reply_Command:
		result := Apply_Edit_Result{x.applied, x.reason}
		respond(c, parse_json(x.id), result)
	case Files_Changed_Command:
		files_changed(c, x)
	}
	command_destroy(cmd)
}


// didChangeWatchedFiles: the files changed on disk
@(private = "file")
files_changed :: proc(c: ^Client, x: Files_Changed_Command) {
	events := make([]File_Event, len(x.paths), context.temp_allocator)
	for path, i in x.paths {
		events[i] = {uri_from_path(path, context.temp_allocator), 2}
	}
	params := Did_Change_Watched_Files_Params{events}
	notify(c, "workspace/didChangeWatchedFiles", to_json(params))
}


// Keeps a copy of the document's text (read from the command's snapshot) and
// sends didOpen
@(private = "file")
open_doc :: proc(c: ^Client, x: ^Open_Command) {
	w := &c.worker
	if find_doc(w, x.uri) != nil do return

	doc := new(Doc)
	doc.uri, x.uri = x.uri, ""
	doc.path, _ = path_from_uri(doc.uri)
	doc.version = x.text.version

	data := buffer.snapshot_read_alloc(&x.text, 0, x.text.length, context.allocator)
	text := string(data)
	buffer.buffer_init(&doc.text, data)
	append(&w.docs, doc)

	item := Text_Document_Item{doc.uri, x.language, int(doc.version), text}
	notify(c, "textDocument/didOpen", to_json(Did_Open_Params{item}))
}


// Applies the edits to the document's text and sends them: as ranges in the
// server's encoding, worked out from the text before each edit, or as the
// whole text to a server that only takes that
@(private = "file")
change_doc :: proc(c: ^Client, x: Change_Command) {
	w := &c.worker
	doc := find_doc(w, x.uri)
	if doc == nil do return

	changes := make([dynamic]Content_Change, 0, len(x.edits), context.temp_allocator)
	for edit in x.edits {
		if edit.old_len < 0 {
			set_doc_text(doc, edit.text)
			append(&changes, Content_Change{text = edit.text})
			continue
		}

		length := buffer.length(&doc.text)
		lo := clamp(edit.offset, 0, length)
		hi := clamp(edit.offset + edit.old_len, lo, length)
		start := position_at(&doc.text, lo, w.encoding)
		end := position_at(&doc.text, hi, w.encoding)
		buffer.replace_untracked(&doc.text, lo, hi - lo, edit.text)
		append(&changes, Content_Change{range = Range{start, end}, text = edit.text})
	}
	doc.version = x.version

	switch w.caps.sync {
	case .None:
		return
	case .Full:
		clear(&changes)
		append(&changes, Content_Change{text = doc_text(doc)})
	case .Incremental:
	}
	params := Did_Change_Params{{doc.uri, int(doc.version)}, changes[:]}
	notify(c, "textDocument/didChange", to_json(params))
}


@(private = "file")
save_doc :: proc(c: ^Client, x: Save_Command) {
	w := &c.worker
	doc := find_doc(w, x.uri)
	if doc == nil || !w.caps.save {
		return
	}

	params := Did_Save_Params{document = {doc.uri}}
	if w.caps.save_text do params.text = doc_text(doc)
	notify(c, "textDocument/didSave", to_json(params))
}


@(private = "file")
close_doc :: proc(c: ^Client, x: Close_Command) {
	w := &c.worker
	doc := find_doc(w, x.uri)
	if doc == nil do return

	notify(c, "textDocument/didClose", to_json(Did_Close_Params{{doc.uri}}))
	for d, i in w.docs {
		if d == doc {
			ordered_remove(&w.docs, i)
			break
		}
	}
	doc_destroy(doc)
}


// Sends a request: about a place in a document (converted to the server's
// position), or with the UI thread's JSON parameters
@(private = "file")
send_request :: proc(c: ^Client, x: ^Request_Command) {
	w := &c.worker
	params := x.params
	about_place := x.uri != "" && x.method != "completionItem/resolve"
	if about_place {
		doc := find_doc(w, x.uri)
		if doc == nil {
			error := strings.clone("the document isn't open")
			append(&w.events, Response{id = x.id, error = error})
			return
		}

		position := position_at(&doc.text, x.offset, w.encoding)
		switch x.method {
		case "textDocument/documentSymbol":
			params = to_json(Document_Params{{doc.uri}})
		case "textDocument/references":
			params = to_json(Reference_Params{{doc.uri}, position, {include_declaration = true}})
		case "textDocument/completion":
			ctx := Completion_Context{int(x.reason), x.query}
			params = to_json(Completion_Params{{doc.uri}, position, ctx})
		case "textDocument/rename":
			params = to_json(Rename_Params{{doc.uri}, position, x.query})
		case:
			params = to_json(Text_Document_Position{{doc.uri}, position})
		}
	} else if x.method == "workspace/symbol" {
		params = to_json(Workspace_Symbol_Params{x.query})
	}

	version: u64
	if doc := find_doc(w, x.uri); doc != nil {
		version = doc.version
	}

	id := next_id(w)
	send(c, envelope(id, x.method, params))
	w.requests[id] = {x.id, x.method, x.uri, x.offset, version}
	x.method, x.uri = "", ""
}


@(private = "file")
cancel_request :: proc(c: ^Client, x: Cancel_Command) {
	w := &c.worker
	for id, pending in w.requests {
		if pending.ui_id != x.id do continue

		delete(pending.method)
		delete(pending.uri)
		delete_key(&w.requests, id)

		Cancel_Params :: struct {
			id: int `json:"id"`,
		}
		notify(c, "$/cancelRequest", to_json(Cancel_Params{id}))
		return
	}
}


// --- Documents ---------------------------------------------------------------------

// The open document a URI names, or nil
@(private)
find_doc :: proc(w: ^Worker, uri: string) -> ^Doc {
	if uri == "" do return nil
	for doc in w.docs {
		if doc.uri == uri do return doc
	}

	// The same file, spelled differently ("file:///e%3A/..." for "file:///E:/...")
	path, ok := path_from_uri(uri, context.temp_allocator)
	if !ok do return nil
	for doc in w.docs {
		if same_file(doc.path, path) do return doc
	}
	return nil
}


@(private)
same_file :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(a, b)
	} else {
		return a == b
	}
}


// The document's whole text, from the temp allocator
@(private = "file")
doc_text :: proc(doc: ^Doc) -> string {
	return string(buffer.read_alloc(&doc.text, 0, buffer.length(&doc.text)))
}


@(private = "file")
set_doc_text :: proc(doc: ^Doc, text: string) {
	buffer.buffer_destroy(&doc.text)
	buffer.buffer_init(&doc.text, transmute([]u8)strings.clone(text))
}


@(private = "file")
doc_destroy :: proc(doc: ^Doc) {
	delete(doc.uri)
	delete(doc.path)
	buffer.buffer_destroy(&doc.text)
	free(doc)
}


// --- Receiving ---------------------------------------------------------------------

@(private = "file")
receive :: proc(c: ^Client, text: string) {
	w := &c.worker
	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil {
		log_line(c, "<-- unreadable message: %v", err)
		return
	}

	method := get_string(v, "method")
	id := get(v, "id")
	switch {
	case method == "":
		// A response to a request
		n, _ := get_int(id)
		error := get_string(v, "error", "message")
		log_line(c, "<-- response %d%s", n, error != "" ? " (error)" : "")
		if error != "" do log_line(c, "    %s", error)

		result := get(v, "result")
		if n == w.init_id {
			initialized(c, result, error)
		} else if w.shutdown_id > 0 && n == w.shutdown_id {
			send_exit(c)
		} else {
			answer_ui(c, n, result, error)
		}

	case id != nil:
		log_line(c, "<-- request %s", method)
		answer_request(c, id, method, get(v, "params"))

	case:
		log_line(c, "<-- %s", method)
		notification(c, method, get(v, "params"))
	}
}


// The initialize result: what the server can do. The UI thread's commands are
// taken from now on
@(private = "file")
initialized :: proc(c: ^Client, result: json.Value, error: string) {
	w := &c.worker
	if error != "" {
		conn_stop(&w.conn, 0)
		fail(c, fmt.tprintf("initialize failed: %s", error))
		return
	}

	caps := get(result, "capabilities")
	w.caps = parse_capabilities(caps)
	w.encoding = get_string(caps, "positionEncoding") == "utf-8" ? .UTF8 : .UTF16
	w.state = .Running
	append(&w.events, Status_Change{.Running, "", w.encoding, parse_capabilities(caps)})

	notify(c, "initialized", "{}")
	if settings := parse_json(c.settings); settings != nil {
		Configuration :: struct {
			settings: json.Value `json:"settings"`,
		}
		notify(c, "workspace/didChangeConfiguration", to_json(Configuration{settings}))
	}
}


// A response to one of the UI thread's requests, decoded for it
@(private = "file")
answer_ui :: proc(c: ^Client, id: int, result: json.Value, error: string) {
	w := &c.worker
	pending, waiting := w.requests[id]
	if !waiting do return // cancelled
	delete_key(&w.requests, id)
	defer {
		delete(pending.method)
		delete(pending.uri)
	}

	r := Response{id = pending.ui_id, error = strings.clone(error)}
	doc := find_doc(w, pending.uri)
	if doc != nil do r.version = pending.version

	if error == "" {
		switch pending.method {
		case "textDocument/hover":
			r.result = read_hover(w, doc, result)
		case "textDocument/definition":
			r.result = read_places(w, result, previews = false)
		case "textDocument/references":
			places := read_places(w, result, previews = true)
			sort_places(places, doc != nil ? doc.path : "")
			r.result = places
		case "textDocument/documentSymbol":
			// In the document's order (some servers list them in any order)
			symbols := read_symbols(w, result, doc != nil ? doc.uri : "")
			slice.stable_sort_by(symbols, symbol_less)
			r.result = symbols
		case "workspace/symbol":
			r.result = read_symbols(w, result, "")
		case "textDocument/completion":
			r.result = read_completions(w, doc, pending.offset, result)
		case "completionItem/resolve":
			r.result = read_completion(w, doc, parse_completion(result), -1, -1)
		case "textDocument/signatureHelp":
			r.result = read_signature(w, result)
		case "textDocument/prepareRename":
			r.result = read_prepare_rename(w, doc, result)
		case "textDocument/rename":
			edit, reason := read_workspace_edit(w, result)
			if reason != "" {
				delete(r.error)
				r.error = fmt.aprintf("The rename can't be made: %s", reason)
			}
			r.result = edit
		case:
			r.result = Raw_Result(strings.clone(to_json(result)))
		}
	}

	// The document changed since: the offsets were read in newer text than the
	// server's, so the answer is marked as about the older version (the UI
	// thread drops or doesn't trust what is about older text)
	if doc != nil && doc.version != pending.version {
		mark_older(&r, doc.path, pending.version)
	}
	append(&w.events, r)
}


@(private = "file")
read_hover :: proc(w: ^Worker, doc: ^Doc, result: json.Value) -> Hover {
	h := Hover{markdown = strings.clone(hover_markdown(result)), lo = -1, hi = -1}
	range, has_range := hover_range(result)
	if has_range && doc != nil {
		h.lo = offset_at(&doc.text, range.start, w.encoding)
		h.hi = max(offset_at(&doc.text, range.end, w.encoding), h.lo)
	}
	return h
}


// The places of a definition or references result. A list of places (asked
// for with `previews`, or several definitions) gets each one's line
@(private = "file")
read_places :: proc(w: ^Worker, result: json.Value, previews: bool) -> []Place {
	locations := parse_locations(result)
	with_previews := previews || len(locations) > 1

	files: Preview_Files
	places := make([]Place, len(locations))
	for loc, i in locations {
		p := place_at(w, loc.uri, loc.range.start)
		if with_previews do p.preview = preview_line(w, &files, loc.uri, p)
		places[i] = p
	}
	return places
}


// The symbols of a documentSymbol or workspace/symbol result; `uri` is the
// document asked about, if any
@(private = "file")
read_symbols :: proc(w: ^Worker, result: json.Value, uri: string) -> []Symbol {
	infos := parse_symbols(result, uri)
	symbols := make([]Symbol, len(infos))
	for info, i in infos {
		detail := info.detail != "" ? info.detail : info.container
		symbols[i] = {
			name   = strings.clone(info.name),
			detail = single_line(detail),
			kind   = info.kind,
			depth  = info.depth,
			place  = place_at(w, info.uri, info.start),
		}
	}
	return symbols
}


// --- Completion and signature help ---------------------------------------------------

// Completions at `offset` of the document: each with what it replaces (items
// that don't say replace the word before the offset) as offsets
@(private = "file")
read_completions :: proc(w: ^Worker, doc: ^Doc, offset: int, result: json.Value) -> Completions {
	infos, incomplete := parse_completions(result)
	infos = infos[:min(len(infos), MAX_COMPLETIONS)]
	word := doc != nil ? word_start(doc, offset) : offset

	items := make([]Completion, len(infos))
	for info, i in infos {
		items[i] = read_completion(w, doc, info, word, offset)
	}
	return {items, incomplete}
}


// A completion item, with what it replaces as offsets: its range, else
// [word, offset)
@(private = "file")
read_completion :: proc(
	w: ^Worker,
	doc: ^Doc,
	info: Completion_Info,
	word, offset: int,
) -> Completion {
	item := Completion {
		label         = strings.clone(info.label),
		signature     = single_line(info.signature),
		detail        = single_line(info.detail),
		kind          = info.kind,
		filter        = strings.clone(info.filter),
		sort          = strings.clone(info.sort),
		preselect     = info.preselect,
		documentation = strings.clone(info.documentation),
		lo            = word,
		hi            = offset,
	}

	// Its text, a snippet reduced to plain text with what to select
	if info.snippet {
		text, sel := snippet_text(info.text)
		item.text = strings.clone(text)
		item.select = sel
	} else {
		item.text = strings.clone(info.text)
		item.select = {len(info.text), len(info.text)}
	}

	// Where it goes, and its other edits
	if range, has_range := info.range.?; has_range && doc != nil {
		item.lo = offset_at(&doc.text, range.start, w.encoding)
		item.hi = max(offset_at(&doc.text, range.end, w.encoding), item.lo)
	}
	if doc != nil {
		item.more = make([]Edit, len(info.more))
		for edit, i in info.more {
			lo := offset_at(&doc.text, edit.range.start, w.encoding)
			hi := max(offset_at(&doc.text, edit.range.end, w.encoding), lo)
			item.more[i] = {lo, hi - lo, strings.clone(edit.text)}
		}
	}

	// The item as the server sent it, to ask for the rest when it is chosen
	if w.caps.completion_resolve && info.raw != nil {
		item.resolve = strings.clone(to_json(info.raw))
	}
	return item
}


// Where the word ending at `offset` starts (letters, digits, '_' and non-ASCII)
@(private = "file")
word_start :: proc(doc: ^Doc, offset: int) -> int {
	line := buffer.offset_to_line(&doc.text, offset)
	start := buffer.line_start(&doc.text, line)
	text := buffer.read_alloc(&doc.text, start, offset)

	i := len(text)
	for i > 0 && is_word_char(text[i - 1]) {
		i -= 1
	}
	return start + i
}


@(private = "file")
is_word_char :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xff:
		return true
	}
	return false
}


// The active signature, its active parameter as bytes of its label
@(private = "file")
read_signature :: proc(w: ^Worker, result: json.Value) -> Signature_Help {
	info := parse_signature_help(result)
	help := Signature_Help {
		label         = strings.clone(info.label),
		documentation = strings.clone(info.documentation),
		index         = info.index,
		count         = info.count,
		param_lo      = -1,
		param_hi      = -1,
	}

	if columns, by_columns := info.param.?; by_columns {
		help.param_lo = from_column(info.label, columns[0], w.encoding)
		help.param_hi = max(from_column(info.label, columns[1], w.encoding), help.param_lo)
	} else if info.param_label != "" {
		// Its text in the label, after the name (a parameter may share it)
		paren := max(strings.index_byte(info.label, '('), 0)
		if at := strings.index(info.label[paren:], info.param_label); at >= 0 {
			help.param_lo = paren + at
			help.param_hi = help.param_lo + len(info.param_label)
		}
	}
	return help
}


// Marks what an answer says about a document as about its older `version`
@(private = "file")
mark_older :: proc(r: ^Response, path: string, version: u64) {
	#partial switch &x in r.result {
	case []Place:
		for &p in x {
			if same_file(p.path, path) do p.version = version
		}
	case []Symbol:
		for &s in x {
			if same_file(s.place.path, path) do s.place.version = version
		}
	case Workspace_Edit:
		for &fe in x.files {
			if fe.open && same_file(fe.path, path) {
				fe.stale = true
			}
		}
	}
}


// Where a rename may start, as offsets in the document
@(private = "file")
read_prepare_rename :: proc(w: ^Worker, doc: ^Doc, result: json.Value) -> Prepare_Rename {
	info, renamable := parse_prepare_rename(result)
	p := Prepare_Rename {
		renamable   = renamable,
		lo          = -1,
		hi          = -1,
		placeholder = strings.clone(info.placeholder),
	}

	if range, has_range := info.range.?; has_range && doc != nil {
		p.lo = offset_at(&doc.text, range.start, w.encoding)
		p.hi = max(offset_at(&doc.text, range.end, w.encoding), p.lo)
	}
	return p
}


// Sorts places by file and position, the file `first` (the one asked about)
// before the others
@(private = "file")
sort_places :: proc(places: []Place, first: string) {
	slice.stable_sort_by(places, place_less)

	// The first file's places to the front, in their order
	front := make([dynamic]Place, 0, len(places), context.temp_allocator)
	rest := make([dynamic]Place, 0, len(places), context.temp_allocator)
	for p in places {
		if same_file(p.path, first) {
			append(&front, p)
		} else {
			append(&rest, p)
		}
	}
	copy(places, front[:])
	copy(places[len(front):], rest[:])
}


@(private = "file")
place_less :: proc(a, b: Place) -> bool {
	if a.path != b.path do return a.path < b.path
	return position_less(a.position, b.position)
}


@(private = "file")
symbol_less :: proc(a, b: Symbol) -> bool {
	return position_less(a.place.position, b.place.position)
}


@(private = "file")
position_less :: proc(a, b: Position) -> bool {
	if a.line != b.line do return a.line < b.line
	return a.character < b.character
}


// A place in a file: its path, and its offset if the file is an open document
@(private = "file")
place_at :: proc(w: ^Worker, uri: string, position: Position) -> Place {
	p := Place{position = position, offset = -1}
	p.path, _ = path_from_uri(uri)
	if doc := find_doc(w, uri); doc != nil {
		p.offset = offset_at(&doc.text, position, w.encoding)
		p.version = doc.version
	}
	return p
}


// Text on one line, its runs of white space made single spaces (owned)
@(private = "file")
single_line :: proc(text: string) -> string {
	words := strings.fields(text, context.temp_allocator)
	return strings.join(words, " ")
}


// --- Preview lines -----------------------------------------------------------------

// Files read for an answer's previews, by path (temp)
@(private = "file")
Preview_Files :: struct {
	texts: map[string]Preview_File,
	read:  int,
}

@(private = "file")
Preview_File :: struct {
	text:   string,
	starts: [dynamic]int, // of its lines
}


// A place's line, trimmed and cut to MAX_PREVIEW_LEN (owned): from the open
// document, else from the file on disk
@(private = "file")
preview_line :: proc(w: ^Worker, files: ^Preview_Files, uri: string, p: Place) -> string {
	line := p.position.line
	text: string
	if doc := find_doc(w, uri); doc != nil {
		if line < 0 || line >= buffer.line_count(&doc.text) {
			return ""
		}

		start := buffer.line_start(&doc.text, line)
		end := min(buffer.line_end(&doc.text, line), start + 4 * MAX_PREVIEW_LEN)
		text = string(buffer.read_alloc(&doc.text, start, end))
	} else {
		f := preview_file(files, p.path)
		if f == nil || line < 0 || line >= len(f.starts) {
			return ""
		}

		start := f.starts[line]
		end := line + 1 < len(f.starts) ? f.starts[line + 1] : len(f.text)
		text = f.text[start:end]
	}

	// Trimmed, and cut where a character starts
	text = strings.trim_space(text)
	if len(text) > MAX_PREVIEW_LEN {
		cut := MAX_PREVIEW_LEN
		for cut > 0 && text[cut] & 0xC0 == 0x80 {
			cut -= 1
		}
		text = text[:cut]
	}
	return strings.clone(text)
}


// A file read for previews, once per answer; nil if it can't be read, is too
// large, or too many were read already
@(private = "file")
preview_file :: proc(files: ^Preview_Files, path: string) -> ^Preview_File {
	if path == "" do return nil
	if files.texts == nil {
		files.texts = make(map[string]Preview_File, context.temp_allocator)
	}
	if f, found := &files.texts[path]; found {
		return f.starts != nil ? f : nil
	}

	// Not read before: an empty entry stands for one that can't be
	files.texts[path] = {}
	if files.read >= MAX_PREVIEW_FILES do return nil
	files.read += 1

	info, stat_err := os.stat(path, context.temp_allocator)
	if stat_err != nil || info.size > MAX_PREVIEW_FILE_SIZE {
		return nil
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return nil

	// Where its lines start
	starts := make([dynamic]int, 1, context.temp_allocator)
	for b, i in data {
		if b == '\n' do append(&starts, i + 1)
	}

	f := &files.texts[path]
	f^ = {string(data), starts}
	return f
}


// Answers a request from the server
@(private = "file")
answer_request :: proc(c: ^Client, id: json.Value, method: string, params: json.Value) {
	switch method {
	case "workspace/configuration":
		// Each item's section of the settings, or null
		settings := parse_json(c.settings)
		items := get_array(params, "items")
		result := make([]json.Value, len(items), context.temp_allocator)
		for item, i in items {
			section := get_string(item, "section")
			result[i] = section == "" ? settings : get(settings, ..split_section(section))
		}
		respond(c, id, result)

	case "window/workDoneProgress/create",
	     "client/registerCapability",
	     "client/unregisterCapability":
		respond(c, id, nil)

	case "window/showMessageRequest":
		log_line(c, "    %s", get_string(params, "message"))
		respond(c, id, nil)

	case "workspace/workspaceFolders":
		folder := Workspace_Folder{uri_from_path(c.root, context.temp_allocator), base_name(c.root)}
		respond(c, id, []Workspace_Folder{folder})

	case "workspace/applyEdit":
		// The UI thread makes the edit and answers (reply_apply_edit)
		edit, reason := read_workspace_edit(&c.worker, get(params, "edit"))
		if reason != "" {
			respond(c, id, Apply_Edit_Result{false, reason})
			return
		}
		append(&c.worker.events, Apply_Edit {
			id    = strings.clone(to_json(id)),
			label = strings.clone(get_string(params, "label")),
			edit  = edit,
		})

	case:
		respond_error(c, id, METHOD_NOT_FOUND, fmt.tprintf("%s is not supported", method))
	}
}


@(private = "file")
split_section :: proc(section: string) -> []string {
	return strings.split(section, ".", context.temp_allocator)
}


@(private = "file")
notification :: proc(c: ^Client, method: string, params: json.Value) {
	w := &c.worker
	switch method {
	case "textDocument/publishDiagnostics":
		read_diagnostics(c, params)
	case "$/progress":
		update_progress(c, params)
	case "window/logMessage":
		log_line(c, "    %s", get_string(params, "message"))
	case "window/showMessage":
		text := strings.clone(get_string(params, "message"))
		append(&w.events, Show_Message{text})
	}
}


// A document's problems, as byte ranges in its text, sorted. Problems the
// server found in an older version of the text are dropped (they can't be
// placed in this one); it publishes again for the newer
@(private = "file")
read_diagnostics :: proc(c: ^Client, params: json.Value) {
	w := &c.worker
	doc := find_doc(w, get_string(params, "uri"))
	if doc == nil do return

	version, has_version := get_int(params, "version")
	if has_version && u64(version) != doc.version {
		log_line(c, "    for version %d, the document is at %d: dropped", version, doc.version)
		return
	}

	list := parse_diagnostics(params)
	problems := make([]Problem, len(list))
	for d, i in list {
		lo := offset_at(&doc.text, d.range.start, w.encoding)
		hi := max(offset_at(&doc.text, d.range.end, w.encoding), lo)
		problems[i] = {
			lo       = lo,
			hi       = hi,
			severity = d.severity,
			message  = strings.clone(d.message),
			source   = strings.clone(d.source),
		}
	}
	slice.sort_by(problems, problem_less)

	append(&w.events, Diagnostics{strings.clone(doc.uri), doc.version, problems})
}


@(private = "file")
problem_less :: proc(a, b: Problem) -> bool {
	return a.lo < b.lo
}


// $/progress: work begins, reports, or ends. The UI thread gets the new list
@(private = "file")
update_progress :: proc(c: ^Client, params: json.Value) {
	w := &c.worker
	token: string
	#partial switch t in get(params, "token") {
	case json.String:  token = t
	case json.Integer: token = fmt.tprintf("%d", t)
	case:              return
	}

	// The entry for this token
	index := -1
	for p, i in w.progress {
		if p.token == token do index = i
	}

	value := get(params, "value")
	switch get_string(value, "kind") {
	case "begin":
		if index < 0 {
			append(&w.progress, Progress{token = strings.clone(token), percentage = -1})
			index = len(w.progress) - 1
		}
		p := &w.progress[index]
		set_owned(&p.title, get_string(value, "title"))
		set_owned(&p.message, get_string(value, "message"))
		p.percentage = get_int(value, "percentage") or_else -1

	case "report":
		if index < 0 do return
		p := &w.progress[index]
		if message := get_string(value, "message"); message != "" {
			set_owned(&p.message, message)
		}
		if pct, ok := get_int(value, "percentage"); ok {
			p.percentage = pct
		}

	case "end":
		if index < 0 do return
		progress_destroy(&w.progress[index])
		ordered_remove(&w.progress, index)

	case:
		return
	}

	// A copy for the UI thread
	list := make([]Progress, len(w.progress))
	for p, i in w.progress {
		list[i] = {
			token      = strings.clone(p.token),
			title      = strings.clone(p.title),
			message    = strings.clone(p.message),
			percentage = p.percentage,
		}
	}
	append(&w.events, Progress_Change{list})
}


@(private = "file")
set_owned :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}


// The last line of text that isn't blank, trimmed
@(private = "file")
last_line :: proc(text: string) -> string {
	text := strings.trim_space(text)
	i := strings.last_index_byte(text, '\n')
	return strings.trim_space(text[i + 1:])
}


@(private = "file")
base_name :: proc(path: string) -> string {
	trimmed := strings.trim_right(path, `/\`)
	i := strings.last_index_any(trimmed, `/\`)
	return trimmed[i + 1:]
}


// --- The log -----------------------------------------------------------------------

// Started over each run, unless the UI thread closed it already
@(private = "file")
open_log :: proc(c: ^Client) {
	if c.log_path == "" do return
	_ = os.make_directory_all(os.dir(c.log_path))

	sync.guard(&c.log_mutex)
	if c.log_closed do return
	c.log, _ = os.create(c.log_path)
}


@(private = "file")
log_line :: proc(c: ^Client, format: string, args: ..any) {
	sync.guard(&c.log_mutex)
	if c.log == nil do return

	line := fmt.tprintf(format, ..args)
	fmt.fprintf(c.log, "%s\n", line)
}


@(private = "file")
log_text :: proc(c: ^Client, text: string) {
	sync.guard(&c.log_mutex)
	if c.log == nil do return

	_, _ = os.write_string(c.log, text)
	if !strings.has_suffix(text, "\n") do _, _ = os.write_string(c.log, "\n")
}


// "textDocument/didChange (1234 bytes)" for a message's JSON
@(private = "file")
summary :: proc(body: string) -> string {
	KEY :: `"method":"`

	method := "response"
	if i := strings.index(body, KEY); i >= 0 {
		rest := body[i + len(KEY):]
		end := strings.index_byte(rest, '"')
		if end >= 0 do method = rest[:end]
	}
	return fmt.tprintf("%s (%d bytes)", method, len(body))
}
