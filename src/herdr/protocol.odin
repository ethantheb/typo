package herdr

// herdr-core's JSON-RPC: the requests typo makes and what it reads from the
// answers, events and close frames. Everything here runs on the client's
// threads; values parsed from JSON are in the temp allocator

import "core:encoding/json"
import "core:fmt"
import "core:strings"


GENERATION :: 1

// The hello that switches a connection to frames, sent as one line
HELLO_LINE ::
	`{"jsonrpc":"2.0","id":0,"method":"hello",` +
	`"params":{"generation":1,"framed":true}}` +
	"\n"

Size :: struct {
	cols: u16,
	rows: u16,
}

// What the viewer looks like, for the program's color and cell size queries.
// Colors are "#rrggbb"; cell is in pixels
Display :: struct {
	fg:     string,
	bg:     string,
	cursor: string,
	cell:   [2]u32,
}

Run_Params :: struct {
	argv:           []string,
	line:           Maybe(string), // a shell line instead of argv
	cwd:            Maybe(string),
	env:            map[string]string,
	labels:         map[string]string,
	size:           Size,
	display:        Display,
	keep:           bool,
	outlive_parent: bool,
	no_parent:      bool,
	no_notify:      bool,
}

Attach_Params :: struct {
	terminal: string,
	cols:     u16,
	rows:     u16,
	history:  int,
	display:  Display,
}

Terminal_Params :: struct {
	terminal: string,
}

Read_Params :: struct {
	terminal: string,
	lines:    int,
}

Subscribe_Params :: struct {
	labels: map[string]string,
}

// A JSON-RPC message from channel 0: a reply (id >= 0) or a notification
Message :: struct {
	id:     int,
	result: json.Value,
	error:  Rpc_Error,
	method: string,
	params: json.Value,
}

Rpc_Error :: struct {
	kind:    string, // data.kind, stable ("not_found", "finished", ...); "" without an error
	message: string,
}

// Why a terminal's program ended, from a Close frame or a finished terminal
Ended :: struct {
	has_code: bool,
	code:     int,
	reason:   string, // exited, killed, holder_lost, signaled, ...
}

// A terminal's facts, as far as typo uses them
Facts :: struct {
	address: string,
	state:   string, // "live" or "finished"
	ended:   Ended,
}

Event :: struct {
	type:     string, // created, lost, restarted, finished, removed, size, ...
	terminal: string,
	size:     Size, // for "size"
	ended:    Ended, // for "lost" and "finished"
}


// A request as JSON text, from the temp allocator
encode_request :: proc(id: int, method: string, params: any) -> string {
	body, err := json.marshal(params, {}, context.temp_allocator)
	if err != nil do body = transmute([]u8)string("{}")

	return fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}}`, id, method, body)
}


// Parses a message from channel 0; false if it isn't JSON-RPC
decode_message :: proc(data: []u8) -> (m: Message, ok: bool) {
	v, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return {}, false

	obj, is_object := v.(json.Object)
	if !is_object do return {}, false

	m.id = -1
	if id, has_id := get_int(v, "id"); has_id {
		m.id = id
	}
	m.result = obj["result"]
	m.method = get_string(v, "method")
	m.params = obj["params"]

	if e, has_error := obj["error"]; has_error && e != nil {
		m.error.kind = get_string(e, "data", "kind")
		m.error.message = get_string(e, "message")
		if m.error.kind == "" do m.error.kind = m.error.message
		if m.error.kind == "" do m.error.kind = "error"
	}
	return m, true
}


// The core's identity from hello's result
decode_hello :: proc(result: json.Value) -> (core_id, version: string) {
	return get_string(result, "core", "id"), get_string(result, "version")
}


decode_facts :: proc(v: json.Value) -> Facts {
	return {
		address = get_string(v, "address"),
		state = get_string(v, "state"),
		ended = decode_ended(v),
	}
}


// {exit_code, reason}: a Close frame's payload, a finished terminal, a lost event
decode_ended :: proc(v: json.Value) -> (e: Ended) {
	e.code, e.has_code = get_int(v, "exit_code")
	e.reason = get_string(v, "reason")
	return
}


decode_close :: proc(payload: []u8) -> Ended {
	if len(payload) == 0 do return {}

	v, err := json.parse(payload, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return {}
	return decode_ended(v)
}


// An event notification's params
decode_event :: proc(params: json.Value) -> (ev: Event) {
	ev.type = get_string(params, "type")
	ev.terminal = get_string(params, "terminal")

	data := get(params, "data")
	cols, _ := get_int(data, "cols")
	rows, _ := get_int(data, "rows")
	ev.size = {u16(clamp(cols, 0, 65535)), u16(clamp(rows, 0, 65535))}
	ev.ended = decode_ended(data)
	return
}


// Whether an end is a loss the core recovers from (the program didn't exit
// or get killed); a kept terminal comes back with a new shell
ended_by_loss :: proc(e: Ended) -> bool {
	switch e.reason {
	case "exited", "killed", "":
		return false
	}
	return true
}


// "#rrggbb"
hex_color :: proc(r, g, b: u8, allocator := context.allocator) -> string {
	return fmt.aprintf("#%02x%02x%02x", r, g, b, allocator = allocator)
}


// A finished terminal's text as terminal output: lines end in CRLF
text_as_output :: proc(text: string, allocator := context.allocator) -> []u8 {
	trimmed := strings.trim_right(text, "\n")
	out, _ := strings.replace_all(trimmed, "\n", "\r\n", allocator)
	return transmute([]u8)out
}


// --- Reading JSON values ---------------------------------------------------------

@(private = "file")
get :: proc(v: json.Value, keys: ..string) -> json.Value {
	v := v
	for key in keys {
		obj, is_object := v.(json.Object)
		if !is_object do return nil
		v = obj[key]
	}
	return v
}


@(private)
get_string :: proc(v: json.Value, keys: ..string) -> string {
	s, _ := get(v, ..keys).(json.String)
	return s
}


@(private)
get_int :: proc(v: json.Value, keys: ..string) -> (int, bool) {
	#partial switch n in get(v, ..keys) {
	case json.Integer: return int(n), true
	case json.Float:   return int(n), true
	}
	return 0, false
}


@(private)
get_bool :: proc(v: json.Value, keys: ..string) -> bool {
	b, _ := get(v, ..keys).(json.Boolean)
	return b
}
