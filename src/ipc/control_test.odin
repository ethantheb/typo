package ipc

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"


@(test)
test_control_round_trip :: proc(t: ^testing.T) {
	// A request, its NULs dropped
	frame, ok := encode_control(`{"cmd":"ls"}` + "\x00", context.temp_allocator)
	testing.expect(t, ok)
	json, err := decode_control(frame[FRAME_HEADER:])
	testing.expect_value(t, err, Decode_Error.None)
	testing.expect_value(t, json, `{"cmd":"ls"}`)

	// Every status
	for status in Control_Status {
		reply_frame, fits := encode_control_reply({status, `{"a":1}`}, context.temp_allocator)
		testing.expect(t, fits)
		reply, reply_err := decode_control_reply(reply_frame[FRAME_HEADER:])
		testing.expect_value(t, reply_err, Decode_Error.None)
		testing.expect_value(t, reply.status, status)
		testing.expect_value(t, reply.json, `{"a":1}`)
	}

	// A version 1 request isn't one
	v1, _ := encode_request({command = .Open, paths = {`C:\a`}}, context.temp_allocator)
	_, v1_err := decode_control(v1[FRAME_HEADER:])
	testing.expect_value(t, v1_err, Decode_Error.Wrong_Version)
	testing.expect_value(t, payload_protocol(v1[FRAME_HEADER:]), PROTOCOL)
}


// An error's JSON reads back as its message, quotes and backslashes included
@(test)
test_error_json :: proc(t: ^testing.T) {
	Message :: struct {
		message: string,
	}
	text := `C:\a "b" {c}`
	m: Message
	err := json.unmarshal_string(error_json(text), &m, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.message, text)
}


// --- The server (control requests are taken on Windows only) -----------------------

when ODIN_OS == .Windows {

@(private = "file")
Waiting :: struct {
	mutex:     sync.Mutex,
	caller:    int,
	slot:      ^Slot, // the request waiting, until the test fills it
	answered:  bool,  // slot_wait returned true
	gave_up:   bool,  // slot_wait returned false
	handled:   int,
}


// Answers "now" at once; anything else waits for the test to fill its slot
@(private = "file")
waiting_handler :: proc(call: Control_Call, userdata: rawptr) -> Control_Reply {
	w := (^Waiting)(userdata)
	sync.lock(&w.mutex)
	w.caller = call.caller
	w.handled += 1
	sync.unlock(&w.mutex)
	if call.json == "now" do return {.Ok, `"now"`}

	slot := slot_new()
	sync.lock(&w.mutex)
	w.slot = slot
	sync.unlock(&w.mutex)

	answered := slot_wait(call, slot)
	reply := slot_reply(slot)
	slot_release(slot)

	sync.guard(&w.mutex)
	w.answered = answered
	w.gave_up = !answered
	return reply
}


// The slot of the request waiting, once the handler made it (nil after 2 s)
@(private = "file")
waiting_slot :: proc(w: ^Waiting) -> ^Slot {
	for _ in 0 ..< 200 {
		sync.lock(&w.mutex)
		slot := w.slot
		sync.unlock(&w.mutex)
		if slot != nil do return slot
		time.sleep(10 * time.Millisecond)
	}
	return nil
}


// Until `done` says so, at most 2 s
@(private = "file")
eventually :: proc(w: ^Waiting, done: proc(w: ^Waiting) -> bool) -> bool {
	for _ in 0 ..< 200 {
		sync.lock(&w.mutex)
		ok := done(w)
		sync.unlock(&w.mutex)
		if ok do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}


@(private = "file")
Sent :: struct {
	endpoint:  string,
	json:      string,
	reply:     Control_Reply, // its JSON cloned with `allocator`
	err:       Control_Error,
	allocator: runtime.Allocator, // the test's
}


@(private = "file")
send_on_thread :: proc(sent: ^Sent) {
	reply, err := send_control(sent.endpoint, sent.json)
	sent.reply = {reply.status, strings.clone(reply.json, sent.allocator)}
	sent.err = err
	free_all(context.temp_allocator)
}


// A request waits for its slot, filled from another thread, while the server
// answers another request meanwhile; the handler gets the client's process
@(test)
test_control_reply_later :: proc(t: ^testing.T) {
	w: Waiting
	s: Server
	testing.expect(t, server_start(&s, nil, &w, waiting_handler))
	defer server_stop(&s)

	sent := Sent{endpoint = s.endpoint, json = "later", allocator = context.allocator}
	sender := thread.create_and_start_with_poly_data(&sent, send_on_thread)
	slot := waiting_slot(&w)
	testing.expect(t, slot != nil, "the request never reached the handler")
	if slot == nil {
		server_stop(&s)
		thread.join(sender)
		thread.destroy(sender)
		delete(sent.reply.json)
		return
	}

	// Another request is answered while that one waits
	now, now_err := send_control(s.endpoint, "now")
	testing.expect_value(t, now_err, Control_Error.None)
	testing.expect_value(t, now.json, `"now"`)

	// The test holds the slot as the UI thread would
	slot_fill(slot, .Ok, `{"done":true}`)
	slot_release(slot)
	thread.join(sender)
	thread.destroy(sender)
	defer delete(sent.reply.json)

	testing.expect_value(t, sent.err, Control_Error.None)
	testing.expect_value(t, sent.reply.status, Control_Status.Ok)
	testing.expect_value(t, sent.reply.json, `{"done":true}`)

	sync.guard(&w.mutex)
	testing.expect_value(t, w.caller, os.get_pid())
	testing.expect(t, w.answered)
}


// A client that goes away while its request waits: the wait ends and the slot
// is abandoned, so the UI thread can drop the request
@(test)
test_control_client_gone :: proc(t: ^testing.T) {
	w: Waiting
	s: Server
	testing.expect(t, server_start(&s, nil, &w, waiting_handler))
	defer server_stop(&s)

	// Sends a request, then closes without reading the reply
	c, connected := connect(s.endpoint)
	testing.expect(t, connected)
	frame, _ := encode_control("later", context.temp_allocator)
	testing.expect(t, conn_write(&c, frame, 1000))
	slot := waiting_slot(&w)
	testing.expect(t, slot != nil, "the request never reached the handler")
	if slot == nil do return

	defer slot_release(slot) // the test's hold, as the UI thread's
	conn_close(&c)

	gave_up := eventually(&w, proc(w: ^Waiting) -> bool {return w.gave_up})
	testing.expect(t, gave_up, "the wait didn't end when the client went")
	testing.expect(t, slot_abandoned(slot))
}


// Stopping the server ends a request waiting for its slot, promptly
@(test)
test_control_stop_while_waiting :: proc(t: ^testing.T) {
	w: Waiting
	s: Server
	testing.expect(t, server_start(&s, nil, &w, waiting_handler))

	sent := Sent{endpoint = s.endpoint, json = "later", allocator = context.allocator}
	sender := thread.create_and_start_with_poly_data(&sent, send_on_thread)
	slot := waiting_slot(&w)
	testing.expect(t, slot != nil, "the request never reached the handler")
	defer if slot != nil do slot_release(slot)

	start := time.tick_now()
	server_stop(&s)
	testing.expect(t, time.tick_since(start) < time.Second, "stopping took too long")

	thread.join(sender)
	thread.destroy(sender)
	delete(sent.reply.json)
	testing.expect_value(t, sent.err, Control_Error.Failed)

	sync.guard(&w.mutex)
	testing.expect(t, w.gave_up)
}

}
