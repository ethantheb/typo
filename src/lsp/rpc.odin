package lsp

// JSON-RPC framing: each message is a header ("Content-Length: n", possibly
// other fields, then a blank line) followed by n bytes of JSON

import "core:fmt"
import "core:strconv"
import "core:strings"


// Gathers bytes read from a server and splits them into messages
Framer :: struct {
	buf:   [dynamic]u8,
	start: int, // where the next message's header begins in buf
}

@(private = "file")
HEADER_END :: "\r\n\r\n"


framer_destroy :: proc(f: ^Framer) {
	delete(f.buf)
	f^ = {}
}


// Adds bytes read from the server
framer_feed :: proc(f: ^Framer, data: []u8) {
	// Drop what earlier messages used, once it is most of the buffer
	if f.start > 0 && f.start >= len(f.buf) / 2 {
		remove_range(&f.buf, 0, f.start)
		f.start = 0
	}
	append(&f.buf, ..data)
}


// The next complete message's JSON, if one has arrived. The slice points into
// the framer and is valid until the next framer_feed. A header without a
// length is skipped
framer_next :: proc(f: ^Framer) -> (body: []u8, ok: bool) {
	for {
		rest := string(f.buf[f.start:])
		header_len := strings.index(rest, HEADER_END)
		if header_len < 0 do return nil, false

		length, has_length := content_length(rest[:header_len])
		body_start := f.start + header_len + len(HEADER_END)
		if !has_length {
			f.start = body_start
			continue
		}

		if len(f.buf) - body_start < length do return nil, false

		f.start = body_start + length
		return f.buf[body_start:f.start], true
	}
}


// The Content-Length field of a header (field names ignore case)
@(private = "file")
content_length :: proc(header: string) -> (int, bool) {
	header := header
	for line in strings.split_lines_iterator(&header) {
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue

		name := strings.trim_space(line[:colon])
		if !strings.equal_fold(name, "Content-Length") do continue

		n, ok := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
		if ok && n >= 0 {
			return n, true
		}
	}
	return 0, false
}


// Appends a framed message to `out`
frame_append :: proc(out: ^[dynamic]u8, body: string) {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	append(out, header)
	append(out, body)
}
