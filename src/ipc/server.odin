package ipc

// A typo's endpoint and its clients. The server listens on its own thread (a
// named pipe on Windows, a Unix domain socket elsewhere, both only for the
// current user) and answers each connection on a thread of its own (at most
// MAX_CLIENTS at once), handing its request to a handler there: `typo <file>`
// (version 1) or a control request (version 2, control.odin). A client
// connects, sends one request and waits for the reply

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"


// Answers a request on the server's thread, whose context.allocator is the
// one server_start was called with. The reply's strings may be in the temp
// allocator, which is freed after each connection
Handler :: #type proc(req: Request, userdata: rawptr) -> Reply

Server :: struct {
	endpoint:  string, // owned; what clients connect to, ENV_NAME's value
	handler:   Handler,
	control:   Control_Handler, // nil: control requests are refused
	userdata:  rawptr,
	allocator: runtime.Allocator, // the handlers'
	thread:    ^thread.Thread,
	stopping:  bool, // atomic

	// Connections being answered, each on its own thread
	active:       int,
	active_mutex: sync.Mutex,
	active_done:  sync.Cond,

	using os: Server_OS,
}

// Connections answered at once; more are turned away
MAX_CLIENTS :: 8

Send_Error :: enum {
	None,
	Not_Running, // nothing answers there (that typo has exited)
	Failed,      // connected, but no valid reply came
}

// How long a connection may take to send its request or read the reply
@(private)
IO_TIMEOUT_MS :: 2000

// How long a client waits for the reply
@(private)
REPLY_TIMEOUT_MS :: 5000


// Creates the endpoint and starts answering on a new thread
server_start :: proc(
	s: ^Server,
	handler: Handler,
	userdata: rawptr,
	control: Control_Handler = nil,
) -> bool {
	s^ = {
		handler   = handler,
		control   = control,
		userdata  = userdata,
		allocator = context.allocator,
	}
	if !listen(s) do return false

	s.thread = thread.create_and_start_with_poly_data(s, run_server)
	return true
}


@(private = "file")
run_server :: proc(s: ^Server) {
	context.allocator = s.allocator
	serve(s)
}


// Stops the thread and the connections' threads (a request waiting for its
// reply gives up), and removes the endpoint
server_stop :: proc(s: ^Server) {
	if s.thread == nil do return

	sync.atomic_store(&s.stopping, true)
	wake_server(s)
	thread.join(s.thread)
	thread.destroy(s.thread)

	// The connections end once they see the server stopping
	sync.lock(&s.active_mutex)
	for s.active > 0 do sync.cond_wait(&s.active_done, &s.active_mutex)
	sync.unlock(&s.active_mutex)

	close_listener(s)
	delete(s.endpoint)
	s^ = {}
}


@(private)
server_stopping :: proc(s: ^Server) -> bool {
	return sync.atomic_load(&s.stopping)
}


// Counts a connection starting to be answered; false if MAX_CLIENTS are
@(private)
connection_begin :: proc(s: ^Server) -> bool {
	sync.guard(&s.active_mutex)
	if s.active >= MAX_CLIENTS do return false

	s.active += 1
	return true
}


@(private)
connection_end :: proc(s: ^Server) {
	sync.guard(&s.active_mutex)
	s.active -= 1
	sync.cond_broadcast(&s.active_done)
}


// Reads one request from a connection, answers it and sends the reply; false
// if no reply was sent
@(private)
serve_connection :: proc(s: ^Server, c: ^Conn) -> bool {
	payload, ok := read_frame(c, IO_TIMEOUT_MS)
	if !ok do return false
	if payload_protocol(payload) == PROTOCOL_2 {
		return serve_control(s, c, payload)
	}

	// The reply, or why the request was refused
	reply: Reply
	req, err := decode_request(payload, context.temp_allocator)
	if err == .None {
		reply = s.handler(req, s.userdata)
	} else {
		reason := fmt.tprintf("typo could not read the request (%v)", err)
		reply = {ok = false, messages = []string{reason}}
	}

	frame, fits := encode_reply(reply, context.temp_allocator)
	if !fits {
		too_long := []string{"the reply was too long"}
		frame, _ = encode_reply({ok = false, messages = too_long}, context.temp_allocator)
	}
	return conn_write(c, frame, IO_TIMEOUT_MS)
}


// Answers a control request through the control handler, with the client's
// process id; false if no reply was sent
@(private = "file")
serve_control :: proc(s: ^Server, c: ^Conn, payload: []u8) -> bool {
	reply: Control_Reply
	after: proc()
	json, err := decode_control(payload)
	switch {
	case err != .None:
		reply = {.Error, error_json(fmt.tprintf("typo could not read the request (%v)", err))}
	case s.control == nil:
		reply = {.Error, error_json("this window doesn't take control requests here")}
	case:
		call := Control_Call{json = json, caller = conn_client_pid(c), conn = c, after = &after}
		reply = s.control(call, s.userdata)
	}
	defer if after != nil do after()
	if server_stopping(s) do return false

	frame, fits := encode_control_reply(reply, context.temp_allocator)
	if !fits {
		too_long := Control_Reply{.Error, error_json("the reply was too long")}
		frame, _ = encode_control_reply(too_long, context.temp_allocator)
	}
	return conn_write(c, frame, IO_TIMEOUT_MS)
}


// {"message": <text>}, in the temp allocator
error_json :: proc(message: string) -> string {
	return strings.concatenate({`{"message":`, json_string(message), "}"}, context.temp_allocator)
}


// A string as a JSON string, quotes included (temp)
json_string :: proc(s: string) -> string {
	data, err := json.marshal(s, allocator = context.temp_allocator)
	if err != nil do return `""`
	return string(data)
}


// Sends a request to the endpoint and waits for the reply, which is in the
// temp allocator
send :: proc(
	endpoint: string,
	req: Request,
) -> (
	reply: Reply,
	err: Send_Error,
) {
	frame, fits := encode_request(req, context.temp_allocator)
	if !fits do return {}, .Failed

	c, connected := connect(endpoint)
	if !connected do return {}, .Not_Running
	defer conn_close(&c)

	// The request, then the reply
	if !conn_write(&c, frame, IO_TIMEOUT_MS) do return {}, .Failed
	payload, ok := read_frame(&c, REPLY_TIMEOUT_MS)
	if !ok do return {}, .Failed

	decoded, decode_err := decode_reply(payload, context.temp_allocator)
	if decode_err != .None do return {}, .Failed

	return decoded, .None
}


// Reads a frame's payload into the temp allocator; false on a timeout, a
// closed connection or a length over MAX_MESSAGE
@(private)
read_frame :: proc(c: ^Conn, timeout_ms: u32) -> (payload: []u8, ok: bool) {
	header: [FRAME_HEADER]u8
	if !conn_read(c, header[:], timeout_ms) do return nil, false
	n := frame_length(header) or_return

	payload = make([]u8, n, context.temp_allocator)
	if !conn_read(c, payload, timeout_ms) do return nil, false

	return payload, true
}
