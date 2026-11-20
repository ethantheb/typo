package ipc

import "core:encoding/endian"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"


@(private = "file")
ROOT :: `C:\work\` when ODIN_OS == .Windows else "/work/"


@(private = "file")
abs_path :: proc(name: string) -> string {
	return strings.concatenate({ROOT, name}, context.temp_allocator)
}


// The payload of a frame (without its length)
@(private = "file")
payload_of :: proc(frame: []u8) -> []u8 {
	return frame[FRAME_HEADER:]
}


// A payload made of the given fields, each ended by a NUL
@(private = "file")
fields_payload :: proc(fields: ..string) -> []u8 {
	sb := strings.builder_make(context.temp_allocator)
	for f in fields {
		strings.write_string(&sb, f)
		strings.write_byte(&sb, 0)
	}
	return sb.buf[:]
}


@(test)
test_request_round_trip :: proc(t: ^testing.T) {
	paths := []string{abs_path("a.md"), abs_path("dir/ünïcode b.odin")}
	frame, ok := encode_request({command = .Open, paths = paths}, context.temp_allocator)
	testing.expect(t, ok)

	// The header holds the payload's length
	header: [FRAME_HEADER]u8
	copy(header[:], frame)
	n, fits := frame_length(header)
	testing.expect(t, fits)
	testing.expect_value(t, n, len(frame) - FRAME_HEADER)

	req, err := decode_request(payload_of(frame), context.temp_allocator)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, req.command, Command.Open)
	testing.expect_value(t, len(req.paths), 2)
	for path, i in paths {
		testing.expect_value(t, req.paths[i], path)
	}
}


@(test)
test_request_rejects_malformed :: proc(t: ^testing.T) {
	good := abs_path("a.md")
	long := strings.repeat("x", MAX_PATH_BYTES + 1, context.temp_allocator)
	many := make([]string, MAX_PATHS + 3, context.temp_allocator)
	many[0], many[1] = PROTOCOL, "open"
	for &p in many[2:] do p = good

	Case :: struct {
		payload: []u8,
		want:    Decode_Error,
	}
	cases := []Case {
		{nil, .Truncated},
		{transmute([]u8)string("typo-ipc/1"), .Truncated}, // no NUL
		{fields_payload("typo-ipc/2", "open", good), .Wrong_Version},
		{fields_payload("other", "open", good), .Wrong_Version},
		{fields_payload(PROTOCOL), .Bad_Command},
		{fields_payload(PROTOCOL, "delete", good), .Bad_Command},
		{fields_payload(PROTOCOL, "open"), .No_Paths},
		{fields_payload(PROTOCOL, "open", ""), .Bad_Path},
		{fields_payload(PROTOCOL, "open", "relative/a.md"), .Bad_Path},
		{fields_payload(PROTOCOL, "open", good, abs_path(long)), .Bad_Path},
		{fields_payload(PROTOCOL, "open", abs_path("\xff\xfe")), .Bad_Path},
		{fields_payload(..many), .Too_Many},
	}

	for c, i in cases {
		req, err := decode_request(c.payload, context.temp_allocator)
		testing.expectf(t, err == c.want, "case %d: got %v, want %v", i, err, c.want)
		testing.expectf(t, req.paths == nil, "case %d: paths kept on an error", i)
	}
}


@(test)
test_frame_limits :: proc(t: ^testing.T) {
	// A length over the limit is refused before anything is read
	header: [FRAME_HEADER]u8
	endian.put_u32(header[:], .Little, MAX_MESSAGE + 1)
	_, ok := frame_length(header)
	testing.expect(t, !ok)

	// A request too big for a frame isn't encoded
	long := abs_path(strings.repeat("x", 4000, context.temp_allocator))
	paths := make([]string, 20, context.temp_allocator)
	for &p in paths do p = long
	_, fits := encode_request({command = .Open, paths = paths}, context.temp_allocator)
	testing.expect(t, !fits)

	_, empty := encode_request({command = .Open}, context.temp_allocator)
	testing.expect(t, !empty)
}


@(test)
test_reply_round_trip :: proc(t: ^testing.T) {
	messages := []string{"first", "has\x00nul"}
	frame, ok := encode_reply({ok = false, messages = messages}, context.temp_allocator)
	testing.expect(t, ok)

	reply, err := decode_reply(payload_of(frame), context.temp_allocator)
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect(t, !reply.ok)
	testing.expect_value(t, len(reply.messages), 2)
	testing.expect_value(t, reply.messages[0], "first")
	testing.expect_value(t, reply.messages[1], "hasnul")

	ok_frame, _ := encode_reply({ok = true}, context.temp_allocator)
	ok_reply, _ := decode_reply(payload_of(ok_frame), context.temp_allocator)
	testing.expect(t, ok_reply.ok && len(ok_reply.messages) == 0)

	_, bad := decode_reply(fields_payload(PROTOCOL, "maybe"), context.temp_allocator)
	testing.expect_value(t, bad, Decode_Error.Bad_Status)
}


// --- Server and client -------------------------------------------------------------

@(private = "file")
Seen :: struct {
	mutex:    sync.Mutex,
	requests: int,
	paths:    [dynamic]string,
}


// Accepts paths ending in ".ok", refuses others with a message each
@(private = "file")
test_handler :: proc(req: Request, userdata: rawptr) -> Reply {
	seen := (^Seen)(userdata)
	sync.guard(&seen.mutex)
	seen.requests += 1

	refused := make([dynamic]string, context.temp_allocator)
	for path in req.paths {
		append(&seen.paths, strings.clone(path))
		if !strings.has_suffix(path, ".ok") {
			append(&refused, strings.concatenate({path, ": refused"}, context.temp_allocator))
		}
	}
	return {ok = len(refused) == 0, messages = refused[:]}
}


@(private = "file")
seen_destroy :: proc(seen: ^Seen) {
	for p in seen.paths do delete(p)
	delete(seen.paths)
}


@(test)
test_server_answers :: proc(t: ^testing.T) {
	seen: Seen
	defer seen_destroy(&seen)

	s: Server
	testing.expect(t, server_start(&s, test_handler, &seen))
	defer server_stop(&s)
	testing.expect(t, s.endpoint != "")

	// Accepted
	reply, err := send(s.endpoint, {command = .Open, paths = {abs_path("a.ok")}})
	testing.expect_value(t, err, Send_Error.None)
	testing.expect(t, reply.ok)

	// One of two refused, with its message
	paths := []string{abs_path("b.ok"), abs_path("c.bad")}
	reply, err = send(s.endpoint, {command = .Open, paths = paths})
	testing.expect_value(t, err, Send_Error.None)
	testing.expect(t, !reply.ok)
	testing.expect_value(t, len(reply.messages), 1)
	if len(reply.messages) == 1 {
		testing.expect(t, strings.has_suffix(reply.messages[0], "c.bad: refused"))
	}

	sync.guard(&seen.mutex)
	testing.expect_value(t, seen.requests, 2)
	testing.expect_value(t, len(seen.paths), 3)
}


// Malformed data gets an error reply, or the connection dropped, and the
// handler never sees it
@(test)
test_server_refuses_malformed :: proc(t: ^testing.T) {
	seen: Seen
	defer seen_destroy(&seen)

	s: Server
	testing.expect(t, server_start(&s, test_handler, &seen))
	defer server_stop(&s)

	// Another version: an error reply
	{
		c, ok := connect(s.endpoint)
		testing.expect(t, ok)
		defer conn_close(&c)

		payload := fields_payload("typo-ipc/9", "open", abs_path("a.ok"))
		header: [FRAME_HEADER]u8
		endian.put_u32(header[:], .Little, u32(len(payload)))
		testing.expect(t, conn_write(&c, header[:], 1000))
		testing.expect(t, conn_write(&c, payload, 1000))

		reply_header: [FRAME_HEADER]u8
		testing.expect(t, conn_read(&c, reply_header[:], 2000))
		n, _ := frame_length(reply_header)
		reply_payload := make([]u8, n, context.temp_allocator)
		testing.expect(t, conn_read(&c, reply_payload, 2000))
		reply, err := decode_reply(reply_payload, context.temp_allocator)
		testing.expect(t, err == .None && !reply.ok)
	}

	// An oversized length: dropped without a reply
	{
		c, ok := connect(s.endpoint)
		testing.expect(t, ok)
		defer conn_close(&c)

		header: [FRAME_HEADER]u8
		endian.put_u32(header[:], .Little, 0xffff_ffff)
		testing.expect(t, conn_write(&c, header[:], 1000))
		reply_header: [FRAME_HEADER]u8
		testing.expect(t, !conn_read(&c, reply_header[:], 3000))
	}

	// The server still answers afterwards
	reply, err := send(s.endpoint, {command = .Open, paths = {abs_path("d.ok")}})
	testing.expect(t, err == .None && reply.ok)

	sync.guard(&seen.mutex)
	testing.expect_value(t, seen.requests, 1)
}


@(test)
test_send_without_server :: proc(t: ^testing.T) {
	req := Request{command = .Open, paths = {abs_path("a.ok")}}

	// A name nothing serves, and names typo wouldn't make
	when ODIN_OS == .Windows {
		missing := `\\.\pipe\typo-1-0000000000000000`
		foreign_names := []string{`\\.\pipe\other`, `C:\Windows\win.ini`, ""}
	} else {
		missing := "/tmp/typo-none/ipc.sock"
		foreign_names := []string{"/tmp/other.sock", "/etc/passwd", ""}
	}

	_, err := send(missing, req)
	testing.expect_value(t, err, Send_Error.Not_Running)
	for name in foreign_names {
		_, foreign_err := send(name, req)
		testing.expect_value(t, foreign_err, Send_Error.Not_Running)
	}
}


// Stopping an idle server is quick, and its endpoint is gone afterwards
@(test)
test_server_stops :: proc(t: ^testing.T) {
	seen: Seen
	defer seen_destroy(&seen)

	s: Server
	testing.expect(t, server_start(&s, test_handler, &seen))
	endpoint := strings.clone(s.endpoint, context.temp_allocator)

	start := time.tick_now()
	server_stop(&s)
	testing.expect(t, time.tick_since(start) < time.Second, "stopping took too long")

	_, err := send(endpoint, {command = .Open, paths = {abs_path("a.ok")}})
	testing.expect_value(t, err, Send_Error.Not_Running)
}
