package lsp

// A running server process and the threads that move bytes to and from it.
// Everything here except the thread procs runs on the client's thread

import "base:runtime"
import "core:sync"
import "core:thread"


Connection :: struct {
	process:   Process,
	running:   bool, // the process started and the threads are running
	reader:    ^thread.Thread,
	writer:    ^thread.Thread,
	logger:    ^thread.Thread,
	allocator: runtime.Allocator, // of the message bodies, shared with the threads
	wake:      Notify_Proc,
	wake_data: rawptr,

	// Shared with the threads, guarded by mutex
	mutex:     sync.Mutex,
	cond:      sync.Cond,   // signals the writer
	incoming:  [dynamic][]u8, // message bodies, each owned
	outgoing:  [dynamic]u8, // framed messages not yet written
	errors:    [dynamic]u8, // stderr not yet taken
	closing:   bool,
	ended:     bool, // the server closed its stdout (it exited)
}

@(private = "file")
READ_CHUNK :: 64 * 1024

// Stderr kept while nobody takes it
@(private = "file")
MAX_ERRORS :: 256 * 1024


// Starts the server and its threads. `wake` is called from the threads when
// there is something to take. `c` must not move while running
conn_start :: proc(
	c: ^Connection,
	command: []string,
	cwd: string,
	wake: Notify_Proc,
	wake_data: rawptr,
) -> (
	ok: bool,
	reason: string,
) {
	c^ = {allocator = context.allocator, wake = wake, wake_data = wake_data}

	ok, reason = process_spawn(&c.process, command, cwd)
	if !ok do return

	// Each thread has its own temp allocator; bodies come from ours
	ctx := runtime.default_context()
	ctx.allocator = c.allocator
	c.reader = thread.create_and_start_with_poly_data(c, reader_proc, ctx)
	c.writer = thread.create_and_start_with_poly_data(c, writer_proc, ctx)
	c.logger = thread.create_and_start_with_poly_data(c, logger_proc, ctx)
	c.running = true
	return true, ""
}


// Queues a message (its JSON) to be written to the server
conn_send :: proc(c: ^Connection, body: string) {
	if !c.running do return

	sync.guard(&c.mutex)
	frame_append(&c.outgoing, body)
	sync.cond_signal(&c.cond)
}


// Moves the messages that have arrived to `out`. Each body is owned by the
// caller, allocated with c.allocator
conn_take :: proc(c: ^Connection, out: ^[dynamic][]u8) {
	sync.guard(&c.mutex)
	append(out, ..c.incoming[:])
	clear(&c.incoming)
}


// The server's stderr since the last call
conn_take_errors :: proc(c: ^Connection, allocator := context.temp_allocator) -> string {
	sync.guard(&c.mutex)
	text := string(c.errors[:])
	defer clear(&c.errors)
	return text == "" ? "" : clone_string(text, allocator)
}


// Whether the server has exited (its stdout closed)
conn_ended :: proc(c: ^Connection) -> bool {
	sync.guard(&c.mutex)
	return c.ended
}


// Waits up to `wait_ms` for the server to exit (after an exit notification),
// then ends it if it hasn't, joins the threads and frees everything
conn_stop :: proc(c: ^Connection, wait_ms: int) {
	if !c.running do return

	if sync.guard(&c.mutex) {
		c.closing = true
		sync.cond_signal(&c.cond)
	}

	// Ended even if it exited: what it started (e.g. a build it ran) may hold
	// its pipes open, and then the threads reading them would never finish
	process_wait(&c.process, wait_ms)
	process_kill(&c.process)
	process_wait(&c.process, 1000)

	// The pipes are broken now, so each thread finishes (destroy joins)
	thread.destroy(c.reader)
	thread.destroy(c.writer)
	thread.destroy(c.logger)
	process_close(&c.process)

	for body in c.incoming do delete(body, c.allocator)
	delete(c.incoming)
	delete(c.outgoing)
	delete(c.errors)
	c^ = {}
}


// Splits stdout into messages
@(private = "file")
reader_proc :: proc(c: ^Connection) {
	buf := make([]u8, READ_CHUNK)
	defer delete(buf)
	framer: Framer
	defer framer_destroy(&framer)

	for {
		n := process_read(&c.process, .Stdout, buf)
		if n <= 0 do break

		framer_feed(&framer, buf[:n])
		got := false
		for body in framer_next(&framer) {
			owned := make([]u8, len(body))
			copy(owned, body)

			sync.guard(&c.mutex)
			append(&c.incoming, owned)
			got = true
		}
		if got do c.wake(c.wake_data)
	}

	if sync.guard(&c.mutex) {
		c.ended = true
	}
	c.wake(c.wake_data)
}


// Writes queued messages, so a server that is slow to read never blocks the UI
@(private = "file")
writer_proc :: proc(c: ^Connection) {
	pending: [dynamic]u8
	defer delete(pending)

	for {
		// Wait for something to write
		sync.lock(&c.mutex)
		for len(c.outgoing) == 0 && !c.closing {
			sync.cond_wait(&c.cond, &c.mutex)
		}
		done := c.closing && len(c.outgoing) == 0
		pending, c.outgoing = c.outgoing, pending
		sync.unlock(&c.mutex)
		if done do break

		if !process_write(&c.process, pending[:]) do break
		clear(&pending)
	}
}


// Keeps the tail of stderr for the log
@(private = "file")
logger_proc :: proc(c: ^Connection) {
	buf := make([]u8, READ_CHUNK)
	defer delete(buf)

	for {
		n := process_read(&c.process, .Stderr, buf)
		if n <= 0 do break

		if sync.guard(&c.mutex) {
			append(&c.errors, ..buf[:n])
			if len(c.errors) > MAX_ERRORS {
				remove_range(&c.errors, 0, len(c.errors) - MAX_ERRORS)
			}
		}
		c.wake(c.wake_data)
	}
}


@(private)
clone_string :: proc(s: string, allocator: runtime.Allocator) -> string {
	out := make([]u8, len(s), allocator)
	copy(out, s)
	return string(out)
}
