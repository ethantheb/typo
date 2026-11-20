package ipc

// A typo's endpoint and its clients. The server listens on its own thread (a
// named pipe on Windows, a Unix domain socket elsewhere, both only for the
// current user), answers one connection at a time and hands each request to
// a handler on that thread. A client connects, sends one request and waits
// for the reply

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"


// Answers a request on the server's thread, whose context.allocator is the
// one server_start was called with. The reply's strings may be in the temp
// allocator, which is freed after each connection
Handler :: #type proc(req: Request, userdata: rawptr) -> Reply

Server :: struct {
	endpoint:  string, // owned; what clients connect to, ENV_NAME's value
	handler:   Handler,
	userdata:  rawptr,
	allocator: runtime.Allocator, // the handler's
	thread:    ^thread.Thread,
	stopping: bool, // atomic
	using os: Server_OS,
}

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
server_start :: proc(s: ^Server, handler: Handler, userdata: rawptr) -> bool {
	s^ = {handler = handler, userdata = userdata, allocator = context.allocator}
	if !listen(s) do return false

	s.thread = thread.create_and_start_with_poly_data(s, run_server)
	return true
}


@(private = "file")
run_server :: proc(s: ^Server) {
	context.allocator = s.allocator
	serve(s)
}


// Stops the thread, waiting for a connection it is answering, and removes the
// endpoint
server_stop :: proc(s: ^Server) {
	if s.thread == nil do return

	sync.atomic_store(&s.stopping, true)
	wake_server(s)
	thread.join(s.thread)
	thread.destroy(s.thread)

	close_listener(s)
	delete(s.endpoint)
	s^ = {}
}


@(private)
server_stopping :: proc(s: ^Server) -> bool {
	return sync.atomic_load(&s.stopping)
}


// Reads one request from a connection, answers it and sends the reply; false
// if no reply was sent
@(private)
serve_connection :: proc(s: ^Server, c: ^Conn) -> bool {
	payload, ok := read_frame(c, IO_TIMEOUT_MS)
	if !ok do return false

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
@(private = "file")
read_frame :: proc(c: ^Conn, timeout_ms: u32) -> (payload: []u8, ok: bool) {
	header: [FRAME_HEADER]u8
	if !conn_read(c, header[:], timeout_ms) do return nil, false
	n := frame_length(header) or_return

	payload = make([]u8, n, context.temp_allocator)
	if !conn_read(c, payload, timeout_ms) do return nil, false

	return payload, true
}
