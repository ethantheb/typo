package herdr

// Frames of a framed herdr-core connection: after `hello` with framed on,
// each message both ways is
//
//     u32 channel (little endian) | u8 kind | u32 length (little endian) | payload
//
// Channel 0 carries JSON-RPC; an attach or an event subscription gets a
// channel of its own

import "core:encoding/endian"


Kind :: enum u8 {
	Data            = 0, // bytes: output, typed input, or JSON
	Credit          = 1, // u32: bytes of Data the receiver has consumed
	Close           = 2, // ends a stream; from the core, JSON saying why
	Resize          = 3, // u16 cols, u16 rows
	Focus           = 4, // u8: 1 focused, 0 not
	Facts           = 5,
	Automatic_Input = 6, // replies a viewer's terminal sends on its own
}

Frame :: struct {
	channel: u32,
	kind:    Kind,
	payload: []u8,
}

HEADER :: 9

// The largest frame taken; the core sends at most 16 KiB of data per frame
MAX_FRAME :: 16 * 1024 * 1024

// Splits a byte stream into frames
Frame_Reader :: struct {
	buf: [dynamic]u8,
	pos: int, // start of the first frame not taken
}

Next :: enum {
	Frame,
	Need_More,
	Too_Large, // the stream is broken
}


// Appends a frame to `out`
frame_append :: proc(out: ^[dynamic]u8, channel: u32, kind: Kind, payload: []u8) {
	header: [HEADER]u8
	endian.put_u32(header[0:4], .Little, channel)
	header[4] = u8(kind)
	endian.put_u32(header[5:9], .Little, u32(len(payload)))

	append(out, ..header[:])
	append(out, ..payload)
}


// A Resize frame's payload
resize_payload :: proc(cols, rows: u16) -> (payload: [4]u8) {
	endian.put_u16(payload[0:2], .Little, cols)
	endian.put_u16(payload[2:4], .Little, rows)
	return
}


// A Credit frame's payload
credit_payload :: proc(bytes: int) -> (payload: [4]u8) {
	endian.put_u32(payload[:], .Little, u32(bytes))
	return
}


reader_feed :: proc(r: ^Frame_Reader, data: []u8) {
	// Drop what was taken before growing
	if r.pos > 0 && r.pos == len(r.buf) {
		clear(&r.buf)
		r.pos = 0
	} else if r.pos > 64 * 1024 {
		remove_range(&r.buf, 0, r.pos)
		r.pos = 0
	}

	append(&r.buf, ..data)
}


// The next whole frame. Its payload points into the reader and is valid until
// the next reader_feed
reader_next :: proc(r: ^Frame_Reader) -> (f: Frame, next: Next) {
	rest := r.buf[r.pos:]
	if len(rest) < HEADER do return {}, .Need_More

	channel, _ := endian.get_u32(rest[0:4], .Little)
	n, _ := endian.get_u32(rest[5:9], .Little)
	if n > MAX_FRAME do return {}, .Too_Large
	if len(rest) < HEADER + int(n) do return {}, .Need_More

	f = {
		channel = channel,
		kind    = Kind(rest[4]),
		payload = rest[HEADER:][:n],
	}
	r.pos += HEADER + int(n)
	return f, .Frame
}


// Takes a line ending in '\n' (the plain hello reply), without it
reader_line :: proc(r: ^Frame_Reader) -> (line: []u8, ok: bool) {
	rest := r.buf[r.pos:]
	for c, i in rest {
		if c != '\n' do continue

		r.pos += i + 1
		return rest[:i], true
	}
	return nil, false
}


reader_destroy :: proc(r: ^Frame_Reader) {
	delete(r.buf)
	r^ = {}
}
