package ipc

// Messages between a running typo and `typo <file>` started in one of its
// terminals. Every message is a frame: its payload's length (u32, little
// endian), then the payload, a list of fields each ended by a NUL byte (which
// no path can contain). The first field names the protocol and its version.
//
//   request:  "typo-ipc/1" "open" <absolute path>...
//   reply:    "typo-ipc/1" ("ok" | "error") <message>...

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:unicode/utf8"


// The environment variable that names a typo's endpoint, set in its terminals
ENV_NAME :: "TYPO_IPC"

PROTOCOL :: "typo-ipc/1"

MAX_MESSAGE    :: 64 * 1024 // payload bytes
MAX_PATHS      :: 256
MAX_PATH_BYTES :: 4096
MAX_LINES      :: MAX_PATHS + 1 // a reply's messages

FRAME_HEADER :: 4

Command :: enum {
	Open, // open files in the window
}

@(private = "file")
COMMAND_NAMES := [Command]string {
	.Open = "open",
}

Request :: struct {
	command: Command,
	paths:   []string,
}

Reply :: struct {
	ok:       bool,
	messages: []string, // shown to the user, one per line
}

Decode_Error :: enum {
	None,
	Truncated,     // a field without its NUL
	Wrong_Version, // another protocol or version
	Bad_Command,
	Bad_Status,
	No_Paths,
	Too_Many,
	Bad_Path,      // empty, too long, not UTF-8 or not absolute
	Bad_Text,      // a reply message that isn't UTF-8
}


// --- Frames ------------------------------------------------------------------------

// The payload length a frame header gives; false if it is over MAX_MESSAGE
frame_length :: proc(header: [FRAME_HEADER]u8) -> (n: int, ok: bool) {
	header := header
	length, _ := endian.get_u32(header[:], .Little)
	if length > MAX_MESSAGE do return 0, false

	return int(length), true
}


// The fields as one frame, header included; false if they don't fit
@(private = "file")
encode_frame :: proc(fields: []string, allocator := context.allocator) -> ([]u8, bool) {
	size := 0
	for f in fields do size += len(f) + 1
	if size > MAX_MESSAGE do return nil, false

	frame := make([]u8, FRAME_HEADER + size, allocator)
	endian.put_u32(frame[:FRAME_HEADER], .Little, u32(size))

	at := FRAME_HEADER
	for f in fields {
		at += copy(frame[at:], f)
		frame[at] = 0
		at += 1
	}
	return frame, true
}


// Splits a payload into its NUL-ended fields, which point into it: the
// protocol (checked), the command or status, and the rest (the list allocated)
@(private = "file")
decode_fields :: proc(
	payload: []u8,
	allocator := context.allocator,
) -> (
	word: string,
	rest: []string,
	err: Decode_Error,
) {
	if len(payload) == 0 || payload[len(payload) - 1] != 0 {
		return "", nil, .Truncated
	}

	// Each field ends with a NUL
	count := 0
	for b in payload {
		if b == 0 do count += 1
	}

	text := string(payload)
	protocol := next_field(&text)
	if protocol != PROTOCOL do return "", nil, .Wrong_Version
	if count < 2 do return "", nil, .None

	word = next_field(&text)
	rest = make([]string, count - 2, allocator)
	for &field in rest do field = next_field(&text)
	return word, rest, .None
}


// Takes the field at the start of `text`, up to its NUL
@(private = "file")
next_field :: proc(text: ^string) -> string {
	end := strings.index_byte(text^, 0)
	field := text[:end]
	text^ = text[end + 1:]
	return field
}


// --- Requests ----------------------------------------------------------------------

// The request as a frame; false if it has no paths or doesn't fit in one
encode_request :: proc(req: Request, allocator := context.allocator) -> ([]u8, bool) {
	if len(req.paths) == 0 || len(req.paths) > MAX_PATHS {
		return nil, false
	}

	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, PROTOCOL, COMMAND_NAMES[req.command])
	append(&fields, ..req.paths)
	return encode_frame(fields[:], allocator)
}


// Reads a request's payload. The paths point into `payload`; only their list
// is allocated. Each path must be absolute UTF-8, not empty, not too long
decode_request :: proc(
	payload: []u8,
	allocator := context.allocator,
) -> (
	req: Request,
	err: Decode_Error,
) {
	word, paths := decode_fields(payload, allocator) or_return
	defer if err != .None do delete(paths, allocator)

	// The command
	found := false
	for name, command in COMMAND_NAMES {
		if word == name {
			req.command = command
			found = true
		}
	}
	if !found do return {}, .Bad_Command

	// Its paths
	if len(paths) == 0 do return {}, .No_Paths
	if len(paths) > MAX_PATHS do return {}, .Too_Many
	for path in paths {
		if !valid_path(path) do return {}, .Bad_Path
	}

	req.paths = paths
	return req, .None
}


request_destroy :: proc(req: ^Request, allocator := context.allocator) {
	delete(req.paths, allocator)
	req^ = {}
}


@(private = "file")
valid_path :: proc(path: string) -> bool {
	if path == "" || len(path) > MAX_PATH_BYTES {
		return false
	}
	if !utf8.valid_string(path) do return false

	return os.is_absolute_path(path)
}


// --- Replies -----------------------------------------------------------------------

// The reply as a frame; NULs in its messages are dropped. False if it doesn't
// fit in one
encode_reply :: proc(reply: Reply, allocator := context.allocator) -> ([]u8, bool) {
	if len(reply.messages) > MAX_LINES do return nil, false

	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, PROTOCOL, reply.ok ? "ok" : "error")
	for m in reply.messages {
		clean, _ := strings.remove_all(m, "\x00", context.temp_allocator)
		append(&fields, clean)
	}
	return encode_frame(fields[:], allocator)
}


// Reads a reply's payload; the messages point into `payload`, only their list
// is allocated
decode_reply :: proc(
	payload: []u8,
	allocator := context.allocator,
) -> (
	reply: Reply,
	err: Decode_Error,
) {
	word, messages := decode_fields(payload, allocator) or_return
	defer if err != .None do delete(messages, allocator)

	// The status
	switch word {
	case "ok":    reply.ok = true
	case "error": reply.ok = false
	case:         return {}, .Bad_Status
	}

	// Its messages
	if len(messages) > MAX_LINES do return {}, .Too_Many
	for m in messages {
		if !utf8.valid_string(m) do return {}, .Bad_Text
	}

	reply.messages = messages
	return reply, .None
}


reply_destroy :: proc(reply: ^Reply, allocator := context.allocator) {
	delete(reply.messages, allocator)
	reply^ = {}
}
