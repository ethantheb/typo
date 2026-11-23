package herdr

import "core:strings"
import "core:testing"


// Frames as `hc attach` sends them (captured): a Credit of 430 bytes on
// channel 1 and a Resize to 70x20
@(test)
test_frame_bytes :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)

	credit := credit_payload(0x1ae)
	frame_append(&out, 1, .Credit, credit[:])
	want := []u8{1, 0, 0, 0, 1, 4, 0, 0, 0, 0xae, 0x01, 0, 0}
	testing.expect(t, slice_equal(out[:], want), "credit frame")

	clear(&out)
	resize := resize_payload(70, 20)
	frame_append(&out, 1, .Resize, resize[:])
	want = []u8{1, 0, 0, 0, 3, 4, 0, 0, 0, 0x46, 0, 0x14, 0}
	testing.expect(t, slice_equal(out[:], want), "resize frame")
}


// Frames come apart however the bytes are split, and a line before them (the
// hello's reply) is taken whole
@(test)
test_frame_reader :: proc(t: ^testing.T) {
	stream: [dynamic]u8
	defer delete(stream)
	append(&stream, ..transmute([]u8)string("{\"id\":0}\n"))
	frame_append(&stream, 0, .Data, transmute([]u8)string(`{"id":1}`))
	frame_append(&stream, 7, .Data, transmute([]u8)string("output"))
	frame_append(&stream, 7, .Close, nil)

	// One byte at a time
	r: Frame_Reader
	defer reader_destroy(&r)
	got_line := false
	frames := make([dynamic]string, context.temp_allocator)
	kinds := make([dynamic]Kind, context.temp_allocator)
	for b in stream {
		reader_feed(&r, {b})
		if !got_line {
			line, ok := reader_line(&r)
			if ok {
				testing.expect_value(t, string(line), `{"id":0}`)
				got_line = true
			}
			continue
		}
		for {
			f, next := reader_next(&r)
			if next != .Frame do break

			append(&frames, strings.clone(string(f.payload), context.temp_allocator))
			append(&kinds, f.kind)
		}
	}

	testing.expect(t, got_line)
	testing.expect_value(t, len(frames), 3)
	if len(frames) == 3 {
		testing.expect_value(t, frames[0], `{"id":1}`)
		testing.expect_value(t, frames[1], "output")
		testing.expect_value(t, kinds[2], Kind.Close)
		testing.expect_value(t, frames[2], "")
	}
}


// A length past MAX_FRAME breaks the stream instead of waiting for it
@(test)
test_frame_too_large :: proc(t: ^testing.T) {
	r: Frame_Reader
	defer reader_destroy(&r)
	reader_feed(&r, {0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f})
	_, next := reader_next(&r)
	testing.expect_value(t, next, Next.Too_Large)
}


@(test)
test_decode_messages :: proc(t: ^testing.T) {
	// A reply
	reply := `{"id":3,"jsonrpc":"2.0","result":{"channel":2,"automatic_input":true}}`
	m, ok := decode_message(transmute([]u8)reply)
	testing.expect(t, ok)
	testing.expect_value(t, m.id, 3)
	testing.expect_value(t, m.error.kind, "")
	channel, _ := get_int(m.result, "channel")
	testing.expect_value(t, channel, 2)

	// An error, by its stable kind
	failed := `{"id":4,"jsonrpc":"2.0","error":{"code":-32000,"message":"no such terminal",` +
	          `"data":{"kind":"not_found"}}}`
	m, ok = decode_message(transmute([]u8)failed)
	testing.expect(t, ok)
	testing.expect_value(t, m.error.kind, "not_found")
	testing.expect_value(t, m.error.message, "no such terminal")

	// A notification: no id
	note := `{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":76}}`
	m, ok = decode_message(transmute([]u8)note)
	testing.expect(t, ok)
	testing.expect_value(t, m.id, -1)
	testing.expect_value(t, m.method, "heartbeat")

	_, ok = decode_message(transmute([]u8)string("not json"))
	testing.expect(t, !ok)
}


// Close frames and events as the core sends them (captured)
@(test)
test_decode_ends_and_events :: proc(t: ^testing.T) {
	exited := `{"exit_code":7,"finished_ms":1795373430129,"reason":"exited","signal":null}`
	e := decode_close(transmute([]u8)exited)
	testing.expect(t, e.has_code)
	testing.expect_value(t, e.code, 7)
	testing.expect(t, !ended_by_loss(e))

	lost := `{"exit_code":null,"finished_ms":null,"reason":"holder_lost","signal":null}`
	e = decode_close(transmute([]u8)lost)
	testing.expect(t, !e.has_code)
	testing.expect(t, ended_by_loss(e))

	size := `{"jsonrpc":"2.0","method":"event","params":{"data":{"cols":50,"rows":11},` +
	        `"seq":73,"terminal":"t8","type":"size"}}`
	m, _ := decode_message(transmute([]u8)size)
	ev := decode_event(m.params)
	testing.expect_value(t, ev.type, "size")
	testing.expect_value(t, ev.terminal, "t8")
	testing.expect_value(t, ev.size, Size{50, 11})

	facts :: `{"address":"t3","state":"finished","exit_code":1,"reason":"killed"}`
	m, _ = decode_message(transmute([]u8)string(`{"id":1,"result":` + facts + `}`))
	f := decode_facts(m.result)
	testing.expect_value(t, f.address, "t3")
	testing.expect_value(t, f.state, "finished")
	testing.expect_value(t, f.ended.reason, "killed")
}


// Requests carry their params as JSON objects; optional ones left out are null
@(test)
test_encode_request :: proc(t: ^testing.T) {
	params := Attach_Params {
		terminal = "t7",
		cols     = 80,
		rows     = 24,
		history  = 100,
		display  = {fg = "#ffffff", bg = "#000000", cursor = "#ff0000", cell = {9, 18}},
	}
	text := encode_request(5, "terminal.attach", params)
	m, ok := decode_message(transmute([]u8)text)
	testing.expect(t, ok)
	testing.expect_value(t, m.id, 5)
	testing.expect_value(t, m.method, "terminal.attach")
	testing.expect_value(t, get_string(m.params, "terminal"), "t7")
	cols, _ := get_int(m.params, "cols")
	testing.expect_value(t, cols, 80)
	testing.expect_value(t, get_string(m.params, "display", "bg"), "#000000")

	run := Run_Params{argv = {"cmd.exe"}, keep = true}
	text = encode_request(6, "terminal.run", run)
	m, ok = decode_message(transmute([]u8)text)
	testing.expect(t, ok)
	testing.expect(t, get_bool(m.params, "keep"))
	testing.expect(t, strings.contains(text, `"line":null`))
}


// A finished terminal's text is shown as output: lines end in CRLF
@(test)
test_text_as_output :: proc(t: ^testing.T) {
	out := text_as_output("one\ntwo\n\n", context.temp_allocator)
	testing.expect_value(t, string(out), "one\r\ntwo")
}


@(private = "file")
slice_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		if x != b[i] do return false
	}
	return true
}
