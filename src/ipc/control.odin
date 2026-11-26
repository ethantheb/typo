package ipc

// Control requests: `typo ctl <command>`, run under one of a window's terminals,
// asks that window to act (docs/agent_control.md). The request is a JSON
// object; the reply a status and a JSON object.
//
//   request:  "typo-ipc/2" <JSON>
//   reply:    "typo-ipc/2" ("ok" | "error" | "declined" | "not_mine") <JSON>
//
// The server hands a request to the control handler on the connection's own
// thread, with the client's process id. The handler answers at once, or queues
// the work for the UI thread and waits for a Slot it fills (slot_wait), which
// also notices a client that goes away

import "core:strings"
import "core:sync"
import "core:unicode/utf8"


PROTOCOL_2 :: "typo-ipc/2"

Control_Status :: enum {
	Ok,
	Error,
	Declined, // the user said no
	Not_Mine, // the caller runs under none of this window's terminals
}

@(private = "file")
STATUS_NAMES := [Control_Status]string {
	.Ok       = "ok",
	.Error    = "error",
	.Declined = "declined",
	.Not_Mine = "not_mine",
}

Control_Reply :: struct {
	status: Control_Status,
	json:   string,
}

// A request as the handler gets it
Control_Call :: struct {
	json:   string,    // in the connection's temp allocator
	caller: int,       // the client's process id; 0 if unknown
	conn:   ^Conn,     // for slot_wait
	after:  ^proc(), // the handler may set it: run once the reply was sent (or couldn't be)
}

// Answers a control request on its connection's thread, whose context.allocator
// is the server's. The reply's strings may be in the temp allocator
Control_Handler :: #type proc(call: Control_Call, userdata: rawptr) -> Control_Reply


// --- Messages ----------------------------------------------------------------------

encode_control :: proc(json: string, allocator := context.allocator) -> ([]u8, bool) {
	clean, _ := strings.remove_all(json, "\x00", context.temp_allocator)
	return encode_frame({PROTOCOL_2, clean}, allocator)
}


// The request's JSON, pointing into `payload`
decode_control :: proc(payload: []u8) -> (json: string, err: Decode_Error) {
	word, rest := decode_fields(payload, PROTOCOL_2, context.temp_allocator) or_return
	if len(rest) != 0 do return "", .Bad_Command
	if !utf8.valid_string(word) do return "", .Bad_Text

	return word, .None
}


encode_control_reply :: proc(reply: Control_Reply, allocator := context.allocator) -> ([]u8, bool) {
	clean, _ := strings.remove_all(reply.json, "\x00", context.temp_allocator)
	return encode_frame({PROTOCOL_2, STATUS_NAMES[reply.status], clean}, allocator)
}


// The reply, its JSON pointing into `payload`
decode_control_reply :: proc(payload: []u8) -> (reply: Control_Reply, err: Decode_Error) {
	word, rest := decode_fields(payload, PROTOCOL_2, context.temp_allocator) or_return
	if len(rest) != 1 do return {}, .Bad_Status

	found := false
	for name, status in STATUS_NAMES {
		if word == name {
			reply.status = status
			found = true
		}
	}
	if !found do return {}, .Bad_Status
	if !utf8.valid_string(rest[0]) do return {}, .Bad_Text

	reply.json = rest[0]
	return reply, .None
}


// --- Slots -------------------------------------------------------------------------

// Where the UI thread puts a request's reply for the connection's thread. Both
// hold it (slot_release by each); a client that went away leaves it abandoned
Slot :: struct {
	mutex:     sync.Mutex,
	reply:     Control_Reply, // its JSON owned once filled
	data:      rawptr,        // handed to the connection's thread with the reply
	filled:    bool,
	abandoned: bool,
	refs:      int,
	using os:  Slot_OS,
}


slot_new :: proc() -> ^Slot {
	s := new(Slot)
	s.refs = 2
	slot_os_init(s)
	return s
}


// Gives the reply (the JSON is copied) and wakes the connection's thread. Once
// only: a later fill is ignored. `data` goes with it (slot_data); false if it
// didn't (the slot was filled, or the client went away), so the caller keeps it
slot_fill :: proc(s: ^Slot, status: Control_Status, json: string, data: rawptr = nil) -> bool {
	sync.guard(&s.mutex)
	if s.filled || s.abandoned do return false

	s.reply = {status, strings.clone(json)}
	s.data = data
	s.filled = true
	slot_os_signal(s)
	return true
}


// What came with the reply, after slot_wait returned true; the caller owns it
slot_data :: proc(s: ^Slot) -> rawptr {
	sync.guard(&s.mutex)
	return s.data
}


// Whether the client went away (or the server stopped) before the reply
slot_abandoned :: proc(s: ^Slot) -> bool {
	sync.guard(&s.mutex)
	return s.abandoned
}


// The reply, after slot_wait returned true, in the temp allocator
slot_reply :: proc(s: ^Slot) -> Control_Reply {
	sync.guard(&s.mutex)
	return {s.reply.status, strings.clone(s.reply.json, context.temp_allocator)}
}


slot_release :: proc(s: ^Slot) {
	sync.lock(&s.mutex)
	s.refs -= 1
	last := s.refs == 0
	sync.unlock(&s.mutex)
	if !last do return

	delete(s.reply.json)
	slot_os_destroy(s)
	free(s)
}


@(private)
slot_abandon :: proc(s: ^Slot) {
	sync.guard(&s.mutex)
	if !s.filled do s.abandoned = true
}


// Whether the slot was filled; under its mutex
@(private)
slot_is_filled :: proc(s: ^Slot) -> bool {
	sync.guard(&s.mutex)
	return s.filled
}


// --- The client --------------------------------------------------------------------

// Sends a control request and waits for the reply as long as it takes (the
// user may be asked first); the reply is in the temp allocator. A window whose
// typo is older answers that it can't read the request: .Too_Old
send_control :: proc(endpoint: string, json: string) -> (reply: Control_Reply, err: Control_Error) {
	frame, fits := encode_control(json, context.temp_allocator)
	if !fits do return {}, .Failed

	c, connected := connect(endpoint)
	if !connected do return {}, .Not_Running
	defer conn_close(&c)

	if !conn_write(&c, frame, IO_TIMEOUT_MS) do return {}, .Failed
	payload, ok := read_frame(&c, WAIT_FOREVER)
	if !ok do return {}, .Failed

	// An older window answers in version 1
	if payload_protocol(payload) == PROTOCOL do return {}, .Too_Old

	decoded, decode_err := decode_control_reply(payload)
	if decode_err != .None do return {}, .Failed
	return decoded, .None
}

Control_Error :: enum {
	None,
	Not_Running, // nothing answers there
	Too_Old,     // that window's typo doesn't know control requests
	Failed,      // connected, but no valid reply came
}

// A timeout that never ends
@(private)
WAIT_FOREVER :: max(u32)
