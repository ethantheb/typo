package herdr

// The client: one `hc connect` line to the core, shared by every stream (a
// terminal shown in typo). Two threads: the reader finds hc, starts
// `hc connect`, says hello, subscribes to events and reads frames, starting
// over with a backoff when the line drops; the writer turns queued commands
// into frames. The UI thread only queues commands and takes a stream's bytes
// and state. Everything shared is guarded by `mutex`

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../process"
import "../uitime"

Notify_Proc :: #type proc "contextless" (userdata: rawptr)

Status :: enum {
	Stopped,    // not started
	Looking,    // finding hc
	Not_Found,  // hc isn't installed; looked for again on client_look_again
	Found,      // hc is there; connects once a stream needs it
	Connecting,
	Connected,
	Failed,     // hc connect didn't start or answer; tried again after a while
}

Stream_State :: enum {
	Starting, // the terminal is starting, or being attached
	Attached,
	Lost,     // the line or the program was lost; attached again once possible
	Ended,    // the program exited or was killed (Stream_Info.ended)
	Gone,     // no such terminal (removed, or on another core)
	Failed,   // it couldn't be started (Stream_Info.failure)
}

// A new terminal
Spec :: struct {
	argv:   []string,
	line:   string, // a shell line, when argv is empty
	cwd:    string,
	env:    []string, // "NAME=value"
	labels: []string, // "key=value"
}

// What the UI thread reads about a stream, in the temp allocator
Stream_Info :: struct {
	state:   Stream_State,
	address: string,
	ended:   Ended,
	failure: string,
	pid:     int,  // its program's process, as of the last attach; 0 if unknown
	asked:   Size, // the size the last attach asked for (the size of its repaint)
}

Status_Info :: struct {
	status:  Status,
	hc:      string, // where hc is, once found
	core_id: string,
	version: string,
}

Client :: struct {
	allocator: runtime.Allocator,
	wake:      Notify_Proc,
	wake_data: rawptr,
	labels:    []string, // owned; the events subscribed to: typo's terminals

	reader:    ^thread.Thread,
	writer:    ^thread.Thread,
	line:      process.Process, // hc connect
	frames:    Frame_Reader,    // the reader thread's, for the current connection

	// The line's two locks. io_mutex is held while writing to it, closing it or
	// replacing it; line_mutex (taken after it) while killing, closing or
	// replacing it, never across a write, so a write stuck on a core that
	// stopped reading can't hold up the kill that ends it
	io_mutex:   sync.Mutex,
	line_mutex: sync.Mutex,

	mutex:     sync.Mutex,
	cond:      sync.Cond, // commands queued or written, connected, look again, stopping
	stopping:  bool,
	writing:   bool, // the writer took commands and hasn't written them yet
	look:      bool, // look for hc again
	status:    Status,
	hc:        string, // owned
	core_id:   string, // owned
	version:   string, // owned
	gen:       int, // connections so far: channels belong to one
	events:    u32, // the events channel, 0 until subscribed
	next_id:   int, // request ids
	next_sid:  int, // stream ids
	streams:   [dynamic]^Stream,
	commands:  [dynamic]Command,
	pending:   [dynamic]Pending,
}

Stream :: struct {
	id:        int,
	spec:      Spec, // owned; for a terminal not started yet
	address:   string, // owned; "" until it has started
	core:      string, // owned; the core it is on, if known: on another, it is gone
	size:      Size,
	display:   Display, // owned strings
	history:   int,
	state:     Stream_State,
	ended:     Ended, // owned reason
	failure:   string, // owned
	channel:   u32, // while attached, on connection `gen`
	gen:       int,
	automatic: bool, // the core takes Automatic_Input
	asked:     Size, // the size the last attach asked for
	sent:      [8]Size, // sizes typo set lately, to tell another viewer's
	sent_at:   int,
	taken:     bool, // another viewer set the size since typo did
	pid:       int,  // the program's process, from the last attach (on this machine)
	incoming:  [dynamic]u8, // output not taken yet
	reset:     bool, // the next output is a repaint: reset the terminal first
	owed:      int, // credit held back while too much output waits
	held:      [dynamic]u8, // input typed while starting
}

// The paint after an attach: this many lines of scrollback
DEFAULT_HISTORY :: 10_000

// Output waiting beyond this holds back credit, so the core pauses
@(private = "file")
MAX_PENDING :: 8 * 1024 * 1024

// Input kept while a terminal starts
@(private = "file")
MAX_HELD :: 64 * 1024

@(private = "file")
READ_CHUNK :: 64 * 1024

// Waits before connecting again: doubles from the first to the last
@(private = "file")
RETRY_FIRST :: 250 * time.Millisecond
@(private = "file")
RETRY_LAST :: 5 * time.Second

// How long client_stop waits for queued commands (closing panes) to go out
@(private = "file")
STOP_FLUSH :: 1 * time.Second

@(private)
Command :: union {
	Cmd_Open,
	Cmd_Input,
	Cmd_Resize,
	Cmd_Focus,
	Cmd_Credit,
	Cmd_Detach,
	Cmd_Kill,
}

// Start the stream's terminal, or attach it
@(private)
Cmd_Open :: struct {
	stream: int,
}

// Input for a stream, or (stream -1) a request's frame, made for the
// connection `gen`: after a reconnect it is dropped, as the request was
@(private)
Cmd_Input :: struct {
	stream:    int,
	data:      []u8, // owned
	automatic: bool,
	gen:       int,
}

@(private)
Cmd_Resize :: struct {
	stream: int,
	size:   Size,
}

@(private)
Cmd_Focus :: struct {
	stream:  int,
	focused: bool,
}

@(private)
Cmd_Credit :: struct {
	channel: u32,
	gen:     int,
	bytes:   int,
}

// Close a channel without ending its terminal
@(private)
Cmd_Detach :: struct {
	channel: u32,
	gen:     int,
}

// End a terminal and remove it, unless it is on another core than the one
// connected (`core`, if known)
@(private)
Cmd_Kill :: struct {
	address: string, // owned
	core:    string, // owned
}

@(private)
Pending :: struct {
	id:      int,
	kind:    Pending_Kind,
	stream:  int,
	address: string, // owned, for Kill
}

@(private)
Pending_Kind :: enum {
	Subscribe,
	Run,
	Get,
	Attach,
	Read,
	Kill,
	Remove,
}


// The client's share of the UI thread (its procs the UI thread calls), which
// the perf suite limits
@(thread_local)
ui_share: uitime.Share


// --- UI thread: the client -----------------------------------------------------

// Starts the threads; the reader looks for hc and connects. `labels` ("k=v")
// pick the terminals whose events matter. `c` must not move while running
client_start :: proc(c: ^Client, labels: []string, wake: Notify_Proc, wake_data: rawptr) {
	if c.reader != nil do return

	c^ = {
		allocator = context.allocator,
		wake      = wake,
		wake_data = wake_data,
		status    = .Looking,
		next_id   = 1,
		next_sid  = 1,
	}
	c.labels = clone_strings(labels)

	ctx := runtime.default_context()
	ctx.allocator = c.allocator
	c.reader = thread.create_and_start_with_poly_data(c, reader_proc, ctx)
	c.writer = thread.create_and_start_with_poly_data(c, writer_proc, ctx)
}


// Stops the threads and frees the streams; their terminals go on. Commands
// queued (a pane just closed) still go out if connected
client_stop :: proc(c: ^Client) {
	if c.reader == nil do return

	// Let the writer send what is queued: it signals once it has written
	deadline := time.tick_add(time.tick_now(), STOP_FLUSH)
	sync.lock(&c.mutex)
	for c.status == .Connected && (len(c.commands) > 0 || c.writing) {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do break
		_ = sync.cond_wait_with_timeout(&c.cond, &c.mutex, left)
	}
	c.stopping = true
	sync.cond_broadcast(&c.cond)
	sync.unlock(&c.mutex)

	// Ending hc connect ends the reader's read, and a write stuck on it
	kill_line(c)

	thread.join(c.writer)
	thread.join(c.reader)
	thread.destroy(c.writer)
	thread.destroy(c.reader)

	for s in c.streams do stream_free(c, s)
	delete(c.streams)
	for cmd in c.commands do command_free(cmd)
	delete(c.commands)
	for p in c.pending do delete(p.address)
	delete(c.pending)
	reader_destroy(&c.frames)
	delete_strings(c.labels)
	delete(c.hc)
	delete(c.core_id)
	delete(c.version)
	c^ = {}
}


client_status :: proc(c: ^Client) -> Status_Info {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	return {
		status = c.status,
		hc = strings.clone(c.hc, context.temp_allocator),
		core_id = strings.clone(c.core_id, context.temp_allocator),
		version = strings.clone(c.version, context.temp_allocator),
	}
}


// Looks for hc again if it wasn't found (it may have been installed since)
client_look_again :: proc(c: ^Client) {
	if c.reader == nil do return

	sync.guard(&c.mutex)
	c.look = true
	sync.cond_broadcast(&c.cond)
}


// --- UI thread: streams --------------------------------------------------------

// A stream for a new terminal, started once connected
stream_start :: proc(
	c: ^Client,
	spec: Spec,
	size: Size,
	display: Display,
	history: int,
) -> ^Stream {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	s := new_stream(c, size, display, history)
	s.spec = {
		argv   = clone_strings(spec.argv),
		line   = strings.clone(spec.line),
		cwd    = strings.clone(spec.cwd),
		env    = clone_strings(spec.env),
		labels = clone_strings(spec.labels),
	}
	queue(c, Cmd_Open{s.id})
	return s
}


// A stream for a terminal that exists (its address, on the core `core_id` if
// known), attached once connected
stream_attach :: proc(
	c: ^Client,
	address, core_id: string,
	size: Size,
	display: Display,
	history: int,
) -> ^Stream {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	s := new_stream(c, size, display, history)
	s.address = strings.clone(address)
	s.core = strings.clone(core_id)
	queue(c, Cmd_Open{s.id})
	return s
}


@(private = "file")
new_stream :: proc(c: ^Client, size: Size, display: Display, history: int) -> ^Stream {
	s := new(Stream)
	s^ = {
		id = c.next_sid,
		size = size,
		history = history,
		state = .Starting,
	}
	s.display = clone_display(display)
	c.next_sid += 1
	append(&c.streams, s)
	return s
}


// Moves the output received to `out` (after what it holds). `reset`: it
// starts a repaint, so the terminal must be reset before it
stream_take :: proc(s: ^Stream, c: ^Client, out: ^[dynamic]u8) -> (reset: bool) {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	append(out, ..s.incoming[:])
	clear(&s.incoming)
	reset = s.reset
	s.reset = false

	// Credit held back while the output waited
	if s.owed > 0 && s.state == .Attached && s.gen == c.gen {
		queue(c, Cmd_Credit{s.channel, s.gen, s.owed})
		s.owed = 0
	}
	return
}


// Whether output is waiting
stream_has_output :: proc(s: ^Stream, c: ^Client) -> bool {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	return len(s.incoming) > 0 || s.reset
}


stream_info :: proc(s: ^Stream, c: ^Client) -> Stream_Info {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	ended := s.ended
	ended.reason = strings.clone(s.ended.reason, context.temp_allocator)
	return {
		state = s.state,
		address = strings.clone(s.address, context.temp_allocator),
		ended = ended,
		failure = strings.clone(s.failure, context.temp_allocator),
		pid = s.pid,
		asked = s.asked,
	}
}


// Sends input: typed (Data), or a reply the terminal made on its own
stream_write :: proc(s: ^Stream, c: ^Client, data: []u8, automatic := false) {
	uitime.timed(&ui_share)
	if len(data) == 0 do return

	sync.guard(&c.mutex)
	owned := make([]u8, len(data), c.allocator)
	copy(owned, data)
	queue(c, Cmd_Input{stream = s.id, data = owned, automatic = automatic})
}


stream_resize :: proc(s: ^Stream, c: ^Client, cols, rows: u16, cell_w, cell_h: u32) {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	s.display.cell = {cell_w, cell_h}
	if s.size == {cols, rows} do return

	s.size = {cols, rows}
	queue(c, Cmd_Resize{s.id, s.size})
}


stream_focus :: proc(s: ^Stream, c: ^Client, focused: bool) {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	queue(c, Cmd_Focus{s.id, focused})
}


// Lets go of a stream: detaches, and with `kill` ends and removes its
// terminal. `s` is freed
stream_close :: proc(s: ^Stream, c: ^Client, kill: bool) {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	if s.state == .Attached && s.gen == c.gen {
		queue(c, Cmd_Detach{s.channel, s.gen})
	}
	if kill && s.address != "" {
		address := strings.clone(s.address, c.allocator)
		queue(c, Cmd_Kill{address, strings.clone(s.core, c.allocator)})
	}

	for x, i in c.streams {
		if x == s {
			ordered_remove(&c.streams, i)
			break
		}
	}
	stream_free(c, s)
}


// Ends and removes the terminal at `address` (on the core `core_id`, if
// given) that no stream shows: one the session had, closed before it was shown
client_kill :: proc(c: ^Client, address, core_id: string) {
	uitime.timed(&ui_share)
	sync.guard(&c.mutex)
	core := strings.clone(core_id, c.allocator)
	queue(c, Cmd_Kill{strings.clone(address, c.allocator), core}) // and connects
}


@(private = "file")
stream_free :: proc(c: ^Client, s: ^Stream) {
	delete_strings(s.spec.argv)
	delete_strings(s.spec.env)
	delete_strings(s.spec.labels)
	delete(s.spec.line)
	delete(s.spec.cwd)
	delete(s.address)
	delete(s.core)
	delete_display(s.display)
	delete(s.ended.reason)
	delete(s.failure)
	delete(s.incoming)
	delete(s.held)
	free(s)
}


// --- Shared helpers (any thread, mutex held) ----------------------------------

@(private = "file")
queue :: proc(c: ^Client, cmd: Command) {
	append(&c.commands, cmd)
	sync.cond_broadcast(&c.cond)
}


@(private = "file")
command_free :: proc(cmd: Command) {
	#partial switch x in cmd {
	case Cmd_Input: delete(x.data)
	case Cmd_Kill:
		delete(x.address)
		delete(x.core)
	}
}


@(private = "file")
find_stream :: proc(c: ^Client, id: int) -> ^Stream {
	for s in c.streams {
		if s.id == id do return s
	}
	return nil
}


// The stream, if attached on this connection
@(private = "file")
attached_stream :: proc(c: ^Client, id: int) -> ^Stream {
	s := find_stream(c, id)
	if s == nil || s.state != .Attached || s.gen != c.gen {
		return nil
	}
	return s
}


@(private = "file")
stream_by_address :: proc(c: ^Client, address: string) -> ^Stream {
	if address == "" do return nil

	for s in c.streams {
		if s.address == address do return s
	}
	return nil
}


@(private = "file")
stream_by_channel :: proc(c: ^Client, channel: u32) -> ^Stream {
	for s in c.streams {
		if s.state == .Attached && s.gen == c.gen && s.channel == channel {
			return s
		}
	}
	return nil
}


@(private = "file")
set_state :: proc(c: ^Client, s: ^Stream, state: Stream_State) {
	s.state = state
	if state != .Starting do clear(&s.held)
	c.wake(c.wake_data)
}


@(private = "file")
set_ended :: proc(c: ^Client, s: ^Stream, ended: Ended) {
	delete(s.ended.reason)
	s.ended = {ended.has_code, ended.code, strings.clone(ended.reason, c.allocator)}
	set_state(c, s, .Ended)
}


@(private = "file")
set_failed :: proc(c: ^Client, s: ^Stream, why: string) {
	delete(s.failure)
	s.failure = strings.clone(why, c.allocator)
	set_state(c, s, .Failed)
}


@(private = "file")
set_string :: proc(c: ^Client, field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value, c.allocator)
}


// --- The reader thread ---------------------------------------------------------

@(private = "file")
reader_proc :: proc(c: ^Client) {
	retry := RETRY_FIRST
	for !stopping(c) {
		// hc, looked for until found, then a reason to connect
		if !find(c) do continue
		if !wait_for_work(c) do break

		connected := connect(c)
		if connected {
			retry = RETRY_FIRST
			read_frames(c)
			disconnected(c)
		} else {
			set_status(c, .Failed)
		}

		// Wait before trying again, longer each time it fails at once
		sync.lock(&c.mutex)
		if !c.stopping {
			_ = sync.cond_wait_with_timeout(&c.cond, &c.mutex, retry)
		}
		sync.unlock(&c.mutex)
		if !connected do retry = min(retry * 2, RETRY_LAST)
		free_all(context.temp_allocator)
	}
}


@(private = "file")
stopping :: proc(c: ^Client) -> bool {
	sync.guard(&c.mutex)
	return c.stopping
}


@(private = "file")
set_status :: proc(c: ^Client, status: Status) {
	sync.guard(&c.mutex)
	c.status = status
	sync.cond_broadcast(&c.cond)
	c.wake(c.wake_data)
}


// Finds hc; while it isn't there, waits until asked to look again
@(private = "file")
find :: proc(c: ^Client) -> bool {
	sync.lock(&c.mutex)
	known := c.hc != ""
	sync.unlock(&c.mutex)
	if known do return true

	set_status(c, .Looking)
	path := find_hc(context.temp_allocator)

	sync.guard(&c.mutex)
	if path != "" {
		set_string(c, &c.hc, path)
		return true
	}

	c.status = .Not_Found
	c.look = false
	for s in c.streams {
		if s.state == .Starting do set_failed(c, s, "herdr-core isn't installed")
	}
	c.wake(c.wake_data)
	for !c.look && !c.stopping {
		sync.cond_wait(&c.cond, &c.mutex)
	}
	return false
}


// Waits until a stream or a command needs the core; false once stopping
@(private = "file")
wait_for_work :: proc(c: ^Client) -> bool {
	sync.guard(&c.mutex)
	if len(c.streams) == 0 && len(c.commands) == 0 {
		c.status = .Found
		c.wake(c.wake_data)
	}
	for !c.stopping && len(c.streams) == 0 && len(c.commands) == 0 {
		sync.cond_wait(&c.cond, &c.mutex)
	}
	return !c.stopping
}


// Starts hc connect and says hello; true once the line is framed
@(private = "file")
connect :: proc(c: ^Client) -> bool {
	set_status(c, .Connecting)

	sync.lock(&c.mutex)
	hc := strings.clone(c.hc, context.temp_allocator)
	sync.unlock(&c.mutex)

	// Not after client_stop ended the last one: nothing would end this one
	sync.lock(&c.io_mutex)
	sync.lock(&c.line_mutex)
	started := !stopping(c) && connect_start(&c.line, hc)
	sync.unlock(&c.line_mutex)
	hello_sent := started && process.process_write(&c.line, transmute([]u8)string(HELLO_LINE))
	sync.unlock(&c.io_mutex)
	if !started do return false
	if !hello_sent {
		close_process(c)
		return false
	}

	// The reply is one line; frames follow it
	r := &c.frames
	buf: [4096]u8
	line: []u8
	for {
		got: bool
		line, got = reader_line(r)
		if got do break

		n := process.process_read(&c.line, .Stdout, buf[:])
		if n <= 0 {
			close_process(c)
			return false
		}
		reader_feed(r, buf[:n])
	}

	m, ok := decode_message(line)
	if !ok || m.error.kind != "" {
		close_process(c)
		return false
	}
	core_id, version := decode_hello(m.result)

	// Connected: subscribe, and start or attach the streams again
	sync.guard(&c.mutex)
	set_string(c, &c.core_id, core_id)
	set_string(c, &c.version, version)
	c.gen += 1
	c.events = 0
	c.status = .Connected
	subscribe := Subscribe_Params{pairs_map(c.labels)}
	send_request(c, .Subscribe, -1, "", "events.subscribe", subscribe)
	for s in c.streams {
		if s.state == .Starting || s.state == .Lost || s.state == .Attached {
			s.state = .Starting
			queue(c, Cmd_Open{s.id})
		}
	}
	sync.cond_broadcast(&c.cond)
	c.wake(c.wake_data)
	return true
}


// Reads frames until the line drops
@(private = "file")
read_frames :: proc(c: ^Client) {
	buf := make([]u8, READ_CHUNK)
	defer delete(buf)

	// Frames that came with the hello's reply
	dispatch_bytes(c, nil)

	for {
		n := process.process_read(&c.line, .Stdout, buf)
		if n <= 0 do return

		dispatch_bytes(c, buf[:n])
		free_all(context.temp_allocator)
	}
}


@(private = "file")
dispatch_bytes :: proc(c: ^Client, data: []u8) {
	reader_feed(&c.frames, data)
	for {
		f, next := reader_next(&c.frames)
		switch next {
		case .Need_More:
			return
		case .Too_Large:
			// The line is broken: drop it, and connect again
			kill_line(c)
			return
		case .Frame:
			dispatch_frame(c, f)
		}
	}
}


@(private = "file")
dispatch_frame :: proc(c: ^Client, f: Frame) {
	sync.guard(&c.mutex)

	switch {
	case f.channel == 0:
		if f.kind == .Data do reply_arrived(c, f.payload)

	case f.channel == c.events:
		if f.kind != .Data do return

		queue(c, Cmd_Credit{f.channel, c.gen, len(f.payload)})
		lines := string(f.payload)
		for line in strings.split_lines_iterator(&lines) {
			if line == "" do continue

			m, ok := decode_message(transmute([]u8)line)
			if ok && m.method == "event" {
				event_arrived(c, decode_event(m.params))
			}
		}

	case:
		s := stream_by_channel(c, f.channel)
		if s == nil do return

		#partial switch f.kind {
		case .Data:
			append(&s.incoming, ..f.payload)
			if len(s.incoming) <= MAX_PENDING {
				queue(c, Cmd_Credit{f.channel, c.gen, len(f.payload) + s.owed})
				s.owed = 0
			} else {
				s.owed += len(f.payload)
			}
			c.wake(c.wake_data)

		case .Close:
			stream_closed(c, s, f.payload)
		}
	}
}


// A Close frame from the core: the program ended or was lost, or (without a
// reason) the core let go of the stream, which is attached again
@(private = "file")
stream_closed :: proc(c: ^Client, s: ^Stream, payload: []u8) {
	s.channel = 0
	s.owed = 0
	if len(payload) == 0 {
		s.state = .Starting
		queue(c, Cmd_Open{s.id})
		return
	}

	ended := decode_close(payload)
	if ended_by_loss(ended) {
		set_state(c, s, .Lost)
	} else {
		set_ended(c, s, ended)
	}
}


@(private = "file")
reply_arrived :: proc(c: ^Client, payload: []u8) {
	m, ok := decode_message(payload)
	if !ok || m.id < 0 {
		return
	}

	// What it answers
	p: Pending
	found := false
	for x, i in c.pending {
		if x.id == m.id {
			p = x
			found = true
			ordered_remove(&c.pending, i)
			break
		}
	}
	if !found do return
	defer delete(p.address)

	failed := m.error.kind != ""
	if p.kind == .Subscribe {
		channel, _ := get_int(m.result, "channel")
		if !failed do c.events = u32(channel)
		return
	}
	if p.kind == .Kill {
		// Then removed, unless it is already gone
		if m.error.kind != "not_found" {
			send_terminal_request(c, .Remove, -1, "terminal.rm", p.address)
		}
		return
	}
	if p.kind == .Remove do return

	s := find_stream(c, p.stream)
	if s == nil {
		// Closed while starting: end what it started
		if p.kind == .Run && !failed {
			address := get_string(m.result, "address")
			queue(c, Cmd_Kill{address = strings.clone(address, c.allocator)})
		}
		return
	}

	switch p.kind {
	case .Run:      run_answered(c, s, m)
	case .Get:      get_answered(c, s, m)
	case .Attach:   attach_answered(c, s, m)
	case .Read:     read_answered(c, s, m)
	case .Subscribe, .Kill, .Remove:
	}
}


@(private = "file")
run_answered :: proc(c: ^Client, s: ^Stream, m: Message) {
	if m.error.kind != "" {
		why := strings.concatenate({"herdr-core couldn't start the shell: ", m.error.message})
		defer delete(why)
		set_failed(c, s, why)
		return
	}

	set_string(c, &s.address, get_string(m.result, "address"))
	send_attach(c, s)
}


@(private = "file")
get_answered :: proc(c: ^Client, s: ^Stream, m: Message) {
	if m.error.kind == "not_found" {
		set_state(c, s, .Gone)
		return
	}
	if m.error.kind != "" {
		set_state(c, s, .Lost)
		return
	}

	facts := decode_facts(m.result)
	if facts.state == "live" {
		send_attach(c, s)
		return
	}

	// Finished while nobody watched: its last screen and history, then the end
	set_string(c, &s.ended.reason, facts.ended.reason)
	s.ended.has_code, s.ended.code = facts.ended.has_code, facts.ended.code
	params := Read_Params{s.address, s.history}
	send_request(c, .Read, s.id, "", "terminal.read", params)
}


@(private = "file")
attach_answered :: proc(c: ^Client, s: ^Stream, m: Message) {
	switch m.error.kind {
	case "":
	case "finished":
		// Ended between the get and the attach
		send_terminal_request(c, .Get, s.id, "terminal.get", s.address)
		return
	case "not_found":
		set_state(c, s, .Gone)
		return
	case:
		set_state(c, s, .Lost)
		return
	}

	// A repaint follows on the channel
	channel, _ := get_int(m.result, "channel")
	s.channel = u32(channel)
	s.gen = c.gen
	s.automatic = get_bool(m.result, "automatic_input")
	s.pid, _ = get_int(m.result, "terminal", "pid")
	s.taken = false
	clear(&s.incoming)
	s.reset = true
	s.owed = 0

	held := s.held
	s.held = {}
	set_state(c, s, .Attached)
	if len(held) > 0 do queue(c, Cmd_Input{stream = s.id, data = held[:]})

	// Resized while the attach was on its way
	if s.size != s.asked do queue(c, Cmd_Resize{s.id, s.size})
}


@(private = "file")
read_answered :: proc(c: ^Client, s: ^Stream, m: Message) {
	clear(&s.incoming)
	if m.error.kind == "" {
		text := text_as_output(get_string(m.result, "text"), context.temp_allocator)
		append(&s.incoming, ..text)
	}
	s.reset = true

	ended := s.ended
	s.ended = {}
	set_ended(c, s, ended)
	delete(ended.reason)
}


@(private = "file")
event_arrived :: proc(c: ^Client, ev: Event) {
	s := stream_by_address(c, ev.terminal)
	if s == nil do return

	switch ev.type {
	case "restarted":
		// A kept terminal has a new shell after a loss
		if s.state == .Lost {
			s.state = .Starting
			queue(c, Cmd_Open{s.id})
		}

	case "finished":
		if s.state == .Lost do set_ended(c, s, ev.ended)

	case "removed":
		if s.state != .Ended do set_state(c, s, .Gone)

	case "size":
		if s.state != .Attached do return

		// Another viewer took the terminal; once typo has it back, a repaint
		// puts typo's screen in step with the core's again
		ours := false
		for size in s.sent {
			if size == ev.size do ours = true
		}
		if !ours {
			s.taken = true
		} else if s.taken && ev.size == s.size {
			queue(c, Cmd_Detach{s.channel, s.gen})
			s.state = .Starting
			s.channel = 0
			send_attach(c, s)
		}
	}
}


// The line dropped: streams wait for the next connection
@(private = "file")
disconnected :: proc(c: ^Client) {
	close_process(c)
	reader_destroy(&c.frames)

	sync.guard(&c.mutex)
	c.status = .Connecting
	c.events = 0
	for p in c.pending do delete(p.address)
	clear(&c.pending)

	for s in c.streams {
		if s.state == .Attached || s.state == .Starting {
			s.channel = 0
			s.state = .Lost
		}
	}
	c.wake(c.wake_data)
}


// Ends hc connect and closes the line: killed first, which ends a write stuck
// on it, then closed once no write is under way
@(private = "file")
close_process :: proc(c: ^Client) {
	kill_line(c)

	sync.guard(&c.io_mutex)
	sync.guard(&c.line_mutex)
	process.process_close(&c.line)
}


// Ends hc connect, whatever a write is doing
@(private = "file")
kill_line :: proc(c: ^Client) {
	sync.guard(&c.line_mutex)
	process.process_kill(&c.line)
}


// --- Requests (mutex held) -----------------------------------------------------

@(private = "file")
send_attach :: proc(c: ^Client, s: ^Stream) {
	s.asked = s.size
	remember_size(s, s.size)
	params := Attach_Params {
		terminal = s.address,
		cols     = s.size.cols,
		rows     = s.size.rows,
		history  = s.history,
		display  = s.display,
	}
	send_request(c, .Attach, s.id, "", "terminal.attach", params)
}


@(private = "file")
send_terminal_request :: proc(
	c: ^Client,
	kind: Pending_Kind,
	stream: int,
	method, address: string,
) {
	send_request(c, kind, stream, address, method, Terminal_Params{address})
}


// Registers a request and queues its frame for the writer
@(private = "file")
send_request :: proc(
	c: ^Client,
	kind: Pending_Kind,
	stream: int,
	address: string,
	method: string,
	params: any,
) {
	id := c.next_id
	pending := Pending {
		id      = id,
		kind    = kind,
		stream  = stream,
		address = strings.clone(address, c.allocator),
	}
	append(&c.pending, pending)
	request(c, id, method, params)
}


// Queues a request's frame (the id is registered by the caller)
@(private = "file")
request :: proc(c: ^Client, id: int, method: string, params: any) {
	c.next_id = max(c.next_id, id + 1)
	body := encode_request(id, method, params)
	out := make([dynamic]u8, 0, len(body) + HEADER, c.allocator)
	frame_append(&out, 0, .Data, transmute([]u8)body)
	queue(c, Cmd_Input{stream = -1, data = out[:], gen = c.gen})
}


@(private = "file")
remember_size :: proc(s: ^Stream, size: Size) {
	s.sent[s.sent_at] = size
	s.sent_at = (s.sent_at + 1) % len(s.sent)
}


// --- The writer thread ---------------------------------------------------------

@(private = "file")
writer_proc :: proc(c: ^Client) {
	out: [dynamic]u8
	defer delete(out)

	for {
		// Commands, once connected
		sync.lock(&c.mutex)
		for !c.stopping && (len(c.commands) == 0 || c.status != .Connected) {
			sync.cond_wait(&c.cond, &c.mutex)
		}
		if c.stopping {
			sync.unlock(&c.mutex)
			return
		}

		clear(&out)
		commands := c.commands
		c.commands = {}
		for cmd in commands do encode_command(c, cmd, &out)
		delete(commands)
		c.writing = true
		sync.unlock(&c.mutex)

		// Written outside the client's lock: the core may be slow to read
		sync.lock(&c.io_mutex)
		_ = process.process_write(&c.line, out[:])
		sync.unlock(&c.io_mutex)

		sync.lock(&c.mutex)
		c.writing = false
		sync.cond_broadcast(&c.cond)
		sync.unlock(&c.mutex)
		free_all(context.temp_allocator)
	}
}


// A command's frames, appended to `out` (mutex held). Commands for channels
// of an earlier connection are dropped
@(private = "file")
encode_command :: proc(c: ^Client, cmd: Command, out: ^[dynamic]u8) {
	defer command_free(cmd)

	switch x in cmd {
	case Cmd_Open:
		s := find_stream(c, x.stream)
		if s == nil do return

		switch {
		case s.address == "":
			send_request(c, .Run, s.id, "", "terminal.run", run_params(s))
		case s.core != "" && s.core != c.core_id:
			set_state(c, s, .Gone)
		case:
			send_terminal_request(c, .Get, s.id, "terminal.get", s.address)
		}

	case Cmd_Input:
		// A request's frame, already made, unless for an earlier connection
		if x.stream < 0 {
			if x.gen == c.gen do append(out, ..x.data)
			return
		}

		s := find_stream(c, x.stream)
		if s == nil do return

		if s.state == .Starting {
			if len(s.held) + len(x.data) <= MAX_HELD {
				append(&s.held, ..x.data)
			}
			return
		}
		if attached_stream(c, x.stream) == nil do return

		kind := x.automatic && s.automatic ? Kind.Automatic_Input : Kind.Data
		frame_append(out, s.channel, kind, x.data)

	case Cmd_Resize:
		s := attached_stream(c, x.stream)
		if s == nil do return

		remember_size(s, x.size)
		payload := resize_payload(x.size.cols, x.size.rows)
		frame_append(out, s.channel, .Resize, payload[:])

	case Cmd_Focus:
		s := attached_stream(c, x.stream)
		if s == nil do return

		payload := [1]u8{x.focused ? 1 : 0}
		frame_append(out, s.channel, .Focus, payload[:])

	case Cmd_Credit:
		if x.gen != c.gen do return

		payload := credit_payload(x.bytes)
		frame_append(out, x.channel, .Credit, payload[:])

	case Cmd_Detach:
		if x.gen != c.gen do return
		frame_append(out, x.channel, .Close, nil)

	case Cmd_Kill:
		on_another_core := x.core != "" && x.core != c.core_id
		if on_another_core do return
		send_terminal_request(c, .Kill, -1, "terminal.kill", x.address)
	}
}


// terminal.run's params for a stream's spec, in the temp allocator
@(private = "file")
run_params :: proc(s: ^Stream) -> Run_Params {
	p := Run_Params {
		argv           = s.spec.argv,
		env            = pairs_map(s.spec.env),
		labels         = pairs_map(s.spec.labels),
		size           = s.size,
		display        = s.display,
		keep           = true,
		outlive_parent = true,
		no_parent      = true,
		no_notify      = true,
	}
	if len(s.spec.argv) == 0 && s.spec.line != "" {
		p.line = s.spec.line
	}
	if s.spec.cwd != "" do p.cwd = s.spec.cwd
	return p
}


// --- Small helpers --------------------------------------------------------------

// "k=v" pairs as a map, in the temp allocator
@(private = "file")
pairs_map :: proc(pairs: []string) -> map[string]string {
	m := make(map[string]string, len(pairs), context.temp_allocator)
	for pair in pairs {
		eq := strings.index_byte(pair, '=')
		if eq > 0 do m[pair[:eq]] = pair[eq + 1:]
	}
	return m
}


@(private = "file")
clone_strings :: proc(list: []string) -> []string {
	out := make([]string, len(list))
	for s, i in list do out[i] = strings.clone(s)
	return out
}


@(private = "file")
delete_strings :: proc(list: []string) {
	for s in list do delete(s)
	delete(list)
}


@(private = "file")
clone_display :: proc(d: Display) -> Display {
	return {
		fg = strings.clone(d.fg),
		bg = strings.clone(d.bg),
		cursor = strings.clone(d.cursor),
		cell = d.cell,
	}
}


@(private = "file")
delete_display :: proc(d: Display) {
	delete(d.fg)
	delete(d.bg)
	delete(d.cursor)
}
