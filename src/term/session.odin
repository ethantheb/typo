package term

// A terminal session: a libghostty-vt terminal and a backend, where its
// program runs. The backend is `Local` (a shell on a pty here) or `Remote` (a
// herdr-core terminal, which keeps running without typo). Rendering, the
// grid, selection, search and input encoding don't depend on which; the
// procs under "Backends" below are the only ones that do.
//
// Output arrives on another thread (the local reader thread, or the herdr
// client's), which calls `wake` so an idle UI loop runs a frame. The UI thread
// moves that output into the terminal in session_pump, within a time budget,
// so a flood of output (cat on a large file) never stalls a frame

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../herdr"


MULTI_CLICK_NS :: 500 * time.Millisecond

Notify_Proc :: #type proc "contextless" (userdata: rawptr)

@(private = "file")
READ_CHUNK :: 64 * 1024

// The reader pauses while this much output is waiting to be parsed
@(private = "file")
MAX_PENDING :: 8 * 1024 * 1024

// Scrollback kept per terminal (libghostty-vt counts it in bytes)
@(private = "file")
SCROLLBACK_BYTES :: 16 * 1024 * 1024

Session :: struct {
	vt:         Terminal,
	render:     Render_State,
	row_iter:   Row_Iterator,
	cells:      Row_Cells,
	key_enc:    Key_Encoder,
	key_ev:     Key_Event,
	mouse_enc:  Mouse_Encoder,
	mouse_ev:   Mouse_Event,
	gesture:    Selection_Gesture,
	gesture_ev: [Gesture_Event_Type]Gesture_Event,
	cols:       u16,
	rows:       u16,
	cell_w:     u32,
	cell_h:     u32,

	backend:    Backend,
	running:    bool, // a program is attached and takes input
	work:       [dynamic]u8, // UI-thread copy being fed to the terminal
	work_pos:   int,
	parsed:     u64, // bytes of program output fed to the terminal so far
	wake:       Notify_Proc,
	wake_data:  rawptr,
}

// Where the program runs; nil before it starts and after it ends
Backend :: union {
	Local,
	Remote,
}

// A shell on a pty, read by a reader thread
Local :: struct {
	pty:      Pty,
	closing:  bool, // set by local_stop for the reader thread (atomic)
	reader:   ^thread.Thread,
	mutex:    sync.Mutex,
	incoming: [dynamic]u8, // written by the reader thread, guarded by mutex
}

// A herdr-core terminal, through the client's stream
Remote :: struct {
	client: ^herdr.Client,
	stream: ^herdr.Stream,
	state:  herdr.Stream_State, // as last seen by the pump
}

// What session_pump found
Pump :: struct {
	busy:   bool,   // output is still waiting
	notice: string, // a line to show in the terminal (temp), or ""
	ended:  bool,   // the program ended (once): nothing takes input now
}


// Creates the terminal state. No shell runs until session_spawn.
// `s` must not move afterwards: callbacks hold its address
session_init :: proc(
	s: ^Session,
	cols, rows: u16,
	wake: Notify_Proc,
	wake_data: rawptr,
) -> bool {
	s.cols, s.rows = max(cols, 1), max(rows, 1)
	s.wake, s.wake_data = wake, wake_data
	trace_open()

	// The terminal
	if terminal_new(nil, &s.vt, s.cols, s.rows) != .Success do return false
	scrollback: uint = SCROLLBACK_BYTES
	terminal_set(s.vt, .Scrollback_Max_Bytes, &scrollback)
	pty_semantics(s)

	terminal_set(s.vt, .Userdata, s)
	terminal_set(s.vt, .Write_Pty, rawptr(Write_Pty_Fn(on_write_pty)))

	// The cursor blinks unless a program asks for a steady one
	blink := true
	terminal_set(s.vt, .Default_Cursor_Blink, &blink)
	blink_mode := Mode_Config{mode = MODE_CURSOR_BLINKING, value = true}
	terminal_set(s.vt, .Mode_Default, &blink_mode)

	// Rendering, input encoding and selection
	render_state_new(nil, &s.render)
	render_state_row_iterator_new(nil, &s.row_iter)
	render_state_row_cells_new(nil, &s.cells)
	key_encoder_new(nil, &s.key_enc)
	key_event_new(nil, &s.key_ev)
	mouse_encoder_new(nil, &s.mouse_enc)
	mouse_event_new(nil, &s.mouse_ev)
	selection_gesture_new(nil, &s.gesture)
	for &ev, type in s.gesture_ev do selection_gesture_event_new(nil, &ev, type)

	return true
}


// Frees the session. A remote terminal is let go, not ended
session_destroy :: proc(s: ^Session) {
	session_detach(s)
	if s.vt == nil do return

	for ev in s.gesture_ev do selection_gesture_event_free(ev)
	selection_gesture_free(s.gesture, s.vt)
	mouse_event_free(s.mouse_ev)
	mouse_encoder_free(s.mouse_enc)
	key_event_free(s.key_ev)
	key_encoder_free(s.key_enc)
	render_state_row_cells_free(s.cells)
	render_state_row_iterator_free(s.row_iter)
	render_state_free(s.render)
	terminal_free(s.vt)

	delete(s.work)
	trace_close()
	s^ = {}
}


// --- Backends ----------------------------------------------------------------------

// Starts `command` (a full command line) on a pty here, in `cwd`, with `env`
// ("NAME=value" each) added to its environment. On Windows, `bundled_conpty`
// runs it through the bundled ConPTY when possible (see pty_spawn)
session_spawn :: proc(
	s: ^Session,
	command, cwd: string,
	bundled_conpty := true,
	env: []string = nil,
) -> bool {
	if s.backend != nil do return true

	pty_semantics(s)
	s.backend = Local{}
	l := &s.backend.(Local)
	spawned := pty_spawn(
		&l.pty,
		command,
		cwd,
		s.cols,
		s.rows,
		s.wake,
		s.wake_data,
		bundled_conpty,
		env,
	)
	if !spawned {
		s.backend = nil
		return false
	}

	s.running = true
	l.reader = thread.create_and_start_with_poly_data2(s, l, reader_proc)
	return true
}


// Starts a new herdr-core terminal (`spec`) through `client`, sized and
// colored like this session, and shows it
session_start_remote :: proc(
	s: ^Session,
	client: ^herdr.Client,
	spec: herdr.Spec,
	display: herdr.Display,
	history: int,
) {
	session_detach(s)
	pty_semantics(s)

	size := herdr.Size{s.cols, s.rows}
	stream := herdr.stream_start(client, spec, size, with_cell(s, display), history)
	s.backend = Remote{client = client, stream = stream, state = .Starting}
	s.running = true
}


// Shows the herdr-core terminal at `address` (on the core `core_id`, if
// given), with `history` lines of its scrollback
session_attach_remote :: proc(
	s: ^Session,
	client: ^herdr.Client,
	address, core_id: string,
	display: herdr.Display,
	history: int,
) {
	session_detach(s)
	pty_semantics(s)

	size := herdr.Size{s.cols, s.rows}
	cell := with_cell(s, display)
	stream := herdr.stream_attach(client, address, core_id, size, cell, history)
	s.backend = Remote{client = client, stream = stream, state = .Starting}
	s.running = true
}


// The size a herdr-core terminal was last attached at (its repaint's), or {}
session_remote_size :: proc(s: ^Session) -> herdr.Size {
	r, is_remote := s.backend.(Remote)
	if !is_remote do return {}
	return herdr.stream_info(r.stream, r.client).asked
}


// The herdr-core terminal's address, "" for a local one (temp)
session_remote_address :: proc(s: ^Session) -> string {
	r, is_remote := s.backend.(Remote)
	if !is_remote do return ""
	return herdr.stream_info(r.stream, r.client).address
}


// The process of the program it runs (the shell), on this machine: a local
// shell's, or a remote terminal's as of its last attach. 0 when none runs or
// it isn't known yet
session_pid :: proc(s: ^Session) -> int {
	switch &b in s.backend {
	case Local:
		return pty_pid(&b.pty)
	case Remote:
		return herdr.stream_info(b.stream, b.client).pid
	}
	return 0
}


// Whether the program runs here, ending with typo, rather than in herdr-core
session_is_local :: proc(s: ^Session) -> bool {
	_, local := s.backend.(Local)
	return local
}


// The screen here must stay row for row the same as the pty's, or the shell
// draws in the wrong place. On Windows that is ConPTY's, which keeps its own
// screen without scrollback: growing taller adds blank rows at the bottom
// instead of pulling scrollback down, and rewrapping drops trailing spaces
// (patches/ghostty.patch). A herdr-core terminal's live output is its own
// ConPTY's (the core runs on this machine), so both backends resize this way
@(private = "file")
pty_semantics :: proc(s: ^Session) {
	pull := ODIN_OS != .Windows
	terminal_set(s.vt, .Resize_Pull_Scrollback, &pull)
}


// What a remote shell is told about its terminal (temp): the variables
// pty_spawn gives a local shell, and TERM_PROGRAM, which herdr-core would
// otherwise set to its own (Ghostty's)
shell_identity :: proc() -> []string {
	ids := make([dynamic]string, context.temp_allocator)
	when ODIN_OS != .Windows {
		append(&ids, "TERM=xterm-256color")
	}
	append(&ids, "COLORTERM=truecolor", "TERM_PROGRAM=typo")
	return ids[:]
}


@(private = "file")
with_cell :: proc(s: ^Session, display: herdr.Display) -> herdr.Display {
	d := display
	d.cell = {max(s.cell_w, 1), max(s.cell_h, 1)}
	return d
}


// Ends the program: a local shell, or a remote terminal (killed and removed
// from herdr-core). Waits for a local shell's last output
session_kill :: proc(s: ^Session) {
	switch &b in s.backend {
	case Local:
		local_stop(s, &b)
	case Remote:
		herdr.stream_close(b.stream, b.client, kill = true)
	}
	s.backend = nil
	s.running = false
}


// Lets go of the program without ending a remote terminal, which goes on in
// herdr-core. A local shell can't outlive typo: it ends
session_detach :: proc(s: ^Session) {
	switch &b in s.backend {
	case Local:
		local_stop(s, &b)
	case Remote:
		herdr.stream_close(b.stream, b.client, kill = false)
	}
	s.backend = nil
	s.running = false
}


// Ends the shell and joins the reader thread (keeping what it read)
@(private = "file")
local_stop :: proc(s: ^Session, l: ^Local) {
	sync.atomic_store(&l.closing, true)
	pty_close(&l.pty)
	thread.join(l.reader)
	thread.destroy(l.reader)
	pty_close_output(&l.pty)

	// What the reader read last, for the terminal
	append(&s.work, ..l.incoming[:])
	delete(l.incoming)
	l^ = {}
}


@(private = "file")
reader_proc :: proc(s: ^Session, l: ^Local) {
	buf := make([]u8, READ_CHUNK)
	defer delete(buf)

	for {
		n := pty_read(&l.pty, buf)
		if n <= 0 do break
		trace("<", buf[:n])

		sync.lock(&l.mutex)
		append(&l.incoming, ..buf[:n])
		pending := len(l.incoming)
		sync.unlock(&l.mutex)
		s.wake(s.wake_data)

		// Back-pressure: let the UI thread catch up before reading more. Not
		// while closing: the UI thread is waiting for this thread to finish, and
		// the pty may only close once its output is drained
		for pending > MAX_PENDING && !sync.atomic_load(&l.closing) {
			time.sleep(time.Millisecond)
			sync.lock(&l.mutex)
			pending = len(l.incoming)
			sync.unlock(&l.mutex)
		}
	}
}


// Replies to terminal queries (cursor position, device attributes, ...). A
// remote terminal's go back marked as automatic: herdr-core answers display
// queries itself, and tells these from typing
@(private = "file")
on_write_pty :: proc "c" (t: Terminal, userdata: rawptr, data: [^]u8, len: uint) {
	s := (^Session)(userdata)
	context = runtime.default_context()
	trace("reply", data[:len])

	switch &b in s.backend {
	case Local:  pty_write(&b.pty, data[:len])
	case Remote: herdr.stream_write(b.stream, b.client, data[:len], automatic = true)
	}
}


// Sends raw bytes to the program
session_write :: proc(s: ^Session, data: []u8) {
	if !s.running || len(data) == 0 {
		return
	}

	trace("input", data)
	switch &b in s.backend {
	case Local:  pty_write(&b.pty, data)
	case Remote: herdr.stream_write(b.stream, b.client, data)
	}
}


// Tells the program whether its terminal has the keys (programs that asked
// for focus reports get them; herdr-core relays them for remote terminals)
session_focus :: proc(s: ^Session, focused: bool) {
	if r, is_remote := s.backend.(Remote); is_remote {
		herdr.stream_focus(r.stream, r.client, focused)
	}
}


// Moves output the backend received to `s.work`. `reset`: it is a repaint of
// a remote terminal, so the terminal must be reset first
@(private = "file")
take_output :: proc(s: ^Session) -> (reset: bool) {
	switch &b in s.backend {
	case Local:
		sync.lock(&b.mutex)
		s.work, b.incoming = b.incoming, s.work
		sync.unlock(&b.mutex)
	case Remote:
		reset = herdr.stream_take(b.stream, b.client, &s.work)
	}
	return
}


// Whether the program ended since the last pump, and what to say about it
@(private = "file")
check_backend :: proc(s: ^Session) -> (p: Pump) {
	switch &b in s.backend {
	case Local:
		// The reader thread ends once the console is closed; everything it
		// read is then in s.work and is parsed without a budget
		if pty_exited(&b.pty) {
			local_stop(s, &b)
			s.backend = nil
			s.running = false
			return {notice = "Process exited.", ended = true}
		}

	case Remote:
		info := herdr.stream_info(b.stream, b.client)
		if info.state == b.state do return
		b.state = info.state

		p = remote_notice(info)
		if p.ended {
			// Kept until closed or restarted: an ended terminal still has its address
			s.running = false
		}
	}
	return
}


// What to say when a remote terminal changes state
@(private = "file")
remote_notice :: proc(info: herdr.Stream_Info) -> Pump {
	#partial switch info.state {
	case .Lost:
		return {notice = "Lost herdr-core; showing this terminal again once it is back…"}
	case .Gone:
		return {notice = "This terminal is no longer in herdr-core.", ended = true}
	case .Failed:
		return {notice = fmt.tprintf("%s.", info.failure), ended = true}
	case .Ended:
		e := info.ended
		switch {
		case e.has_code && e.code != 0:
			return {notice = fmt.tprintf("Process exited with code %d.", e.code), ended = true}
		case e.reason == "killed":
			return {notice = "Process was ended.", ended = true}
		}
		return {notice = "Process exited.", ended = true}
	}
	return {}
}


// Feeds pending output to the terminal for up to `budget`. `busy` while output
// is still waiting, so the caller keeps drawing frames. A notice comes with
// changes in the program's state, and `ended` once it ended (after its last
// output was consumed)
session_pump :: proc(s: ^Session, budget: time.Duration) -> (p: Pump) {
	p = check_backend(s)

	start := time.tick_now()
	unlimited := p.ended
	for {
		// Take what the backend has gathered
		if s.work_pos >= len(s.work) {
			clear(&s.work)
			s.work_pos = 0
			if take_output(s) {
				// A repaint follows: parsed in one go, so a half-drawn screen
				// never shows
				terminal_reset(s.vt)
				unlimited = true
			}
			if len(s.work) == 0 {
				p.busy = false
				return
			}
		}

		// Feed the terminal a chunk of it
		end := min(s.work_pos + READ_CHUNK, len(s.work))
		terminal_vt_write(s.vt, &s.work[s.work_pos], uint(end - s.work_pos))
		s.parsed += u64(end - s.work_pos)
		s.work_pos = end

		if !unlimited && time.tick_since(start) > budget {
			p.busy = true
			return
		}
	}
}


// --- Input -------------------------------------------------------------------------

// Sends typed input to the program. Like most terminals, this snaps the view
// back to the bottom and drops the selection
session_input :: proc(s: ^Session, data: []u8) {
	if !s.running || len(data) == 0 {
		return
	}

	terminal_scroll_viewport(s.vt, {tag = .Bottom})
	session_clear_selection(s)
	session_write(s, data)
}


// Encodes a key press the way the running program asked for (legacy, kitty,
// application cursor keys, ...) and sends it. `unshifted` is the key's
// character without modifiers, or 0
session_send_key :: proc(s: ^Session, key: Key, mods: Mods, repeat: bool, unshifted: rune) {
	ev := s.key_ev
	key_encoder_set_from_terminal(s.key_enc, s.vt)
	key_event_set_action(ev, repeat ? .Repeat : .Press)
	key_event_set_key(ev, key)
	key_event_set_mods(ev, mods)
	key_event_set_utf8(ev, {})
	key_event_set_unshifted_codepoint(ev, u32(unshifted))

	buf: [64]u8
	n: uint
	result := key_encoder_encode(s.key_enc, ev, &buf[0], len(buf), &n)
	if result == .Success do session_input(s, buf[:n])
}


// Reports a mouse event to a program that turned mouse tracking on; the
// encoder drops events its mode doesn't want. `pos` is in pixels from the
// grid's top-left corner
session_send_mouse :: proc(
	s: ^Session,
	action: Mouse_Action,
	button: Mouse_Button,
	mods: Mods,
	pos: [2]f32,
	any_pressed: bool,
) {
	// The encoder, set up for the grid and the terminal's modes
	size := init_sized(Mouse_Encoder_Size)
	size.screen_width, size.screen_height = u32(s.cols) * s.cell_w, u32(s.rows) * s.cell_h
	size.cell_width, size.cell_height = s.cell_w, s.cell_h
	pressed := any_pressed
	mouse_encoder_set_from_terminal(s.mouse_enc, s.vt)
	mouse_encoder_set(s.mouse_enc, .Size, &size)
	mouse_encoder_set(s.mouse_enc, .Any_Button_Pressed, &pressed)

	// The event
	ev := s.mouse_ev
	mouse_event_set_action(ev, action)
	if button == .Unknown {
		mouse_event_clear_button(ev)
	} else {
		mouse_event_set_button(ev, button)
	}
	mouse_event_set_mods(ev, mods)
	mouse_event_set_position(ev, {pos.x, pos.y})

	buf: [64]u8
	n: uint
	result := mouse_encoder_encode(s.mouse_enc, ev, &buf[0], len(buf), &n)
	if result == .Success do session_write(s, buf[:n])
}


// Pastes text, bracketed if the program asked for it, with unsafe control
// bytes stripped
session_paste :: proc(s: ^Session, text: string) {
	if len(text) == 0 do return

	// The encoder rewrites the data in place
	data := make([]u8, len(text), context.temp_allocator)
	copy(data, text)
	out := make([]u8, len(text) + 16, context.temp_allocator)

	n: uint
	bracketed := session_mode(s, MODE_BRACKETED_PASTE)
	result := paste_encode(raw_data(data), len(data), bracketed, raw_data(out), len(out), &n)
	if result == .Success {
		session_input(s, out[:n])
	}
}


// Sends `count` up or down arrow keys, in the encoding the program expects
session_send_arrows :: proc(s: ^Session, up: bool, count: int) {
	arrow := up ? "\x1b[A" : "\x1b[B"
	if session_mode(s, MODE_CURSOR_KEYS) {
		arrow = up ? "\x1bOA" : "\x1bOB"
	}

	for _ in 0 ..< count do session_write(s, transmute([]u8)arrow)
}


// --- State -------------------------------------------------------------------------

// Whether the program asked for mouse events
session_mouse_tracking :: proc(s: ^Session) -> bool {
	tracking: bool
	terminal_get(s.vt, .Mouse_Tracking, &tracking)
	return tracking
}


// Whether a full-screen program (pager, editor) is running: it switched to the
// alternate screen, or turned on application cursor keys. The second matters on
// Windows, where ConPTY keeps the alternate screen to itself but passes the
// cursor-key mode through
session_full_screen :: proc(s: ^Session) -> bool {
	screen: i32
	terminal_get(s.vt, .Active_Screen, &screen)
	return screen == 1 || session_mode(s, MODE_CURSOR_KEYS)
}


session_resize :: proc(s: ^Session, cols, rows: u16, cell_w, cell_h: u32) {
	cols, rows := max(cols, 1), max(rows, 1)
	if cols == s.cols &&
	   rows == s.rows &&
	   cell_w == s.cell_w &&
	   cell_h == s.cell_h {
		return
	}

	s.cols, s.rows, s.cell_w, s.cell_h = cols, rows, cell_w, cell_h
	terminal_resize(s.vt, cols, rows, cell_w, cell_h)

	switch &b in s.backend {
	case Local:  pty_resize(&b.pty, cols, rows)
	case Remote: herdr.stream_resize(b.stream, b.client, cols, rows, cell_w, cell_h)
	}
}


// Writes a status line into the terminal itself, e.g. after the shell exits
session_print_notice :: proc(s: ^Session, msg: string) {
	line := fmt.tprintf("\r\n\x1b[2m%s\x1b[0m\r\n", msg)
	terminal_vt_write(s.vt, raw_data(line), len(line))
}


session_scroll :: proc(s: ^Session, rows: int) {
	terminal_scroll_viewport(s.vt, {tag = .Delta, value = {delta = rows}})
}


session_mode :: proc(s: ^Session, mode: Mode) -> bool {
	cfg := Mode_Config{mode = mode}
	terminal_get(s.vt, .Mode, &cfg)
	return cfg.value
}


// --- Selection ---------------------------------------------------------------------

// Mouse selection goes through libghostty-vt's gesture tracker, which counts
// clicks itself: a double click selects a word, a triple click a line. The
// selection lives in the terminal and is drawn from the render state

// A cell in the visible viewport, clamped to the grid
@(private = "file")
viewport_ref :: proc(s: ^Session, col, row: int) -> (ref: Grid_Ref, ok: bool) {
	p := Point{tag = .Viewport}
	p.value.coordinate = {
		u16(clamp(col, 0, int(s.cols) - 1)),
		u32(clamp(row, 0, int(s.rows) - 1)),
	}
	ok = terminal_grid_ref(s.vt, p, &ref) == .Success
	return
}


// `pos` is the pointer in pixels relative to the grid's top-left corner
session_select_event :: proc(
	s: ^Session,
	type: Gesture_Event_Type,
	col, row: int,
	pos: [2]f64,
	time_ns: u64,
) {
	ref, ok := viewport_ref(s, col, row)
	if !ok do return

	ev := s.gesture_ev[type]
	position := Surface_Position{pos.x, pos.y}
	geometry := Gesture_Geometry {
		columns       = u32(s.cols),
		cell_width    = s.cell_w,
		screen_height = u32(s.rows) * s.cell_h,
	}

	// Options are per event type; setting one a type doesn't take is rejected
	selection_gesture_event_set(ev, .Ref, &ref)
	if type != .Release do selection_gesture_event_set(ev, .Position, &position)
	if type == .Drag do selection_gesture_event_set(ev, .Geometry, &geometry)
	if type == .Press {
		// Presses chain into double/triple clicks within this time and distance
		time := time_ns
		interval := u64(MULTI_CLICK_NS)
		distance := max(f64(s.cell_w) / 2, 4)
		selection_gesture_event_set(ev, .Time_Ns, &time)
		selection_gesture_event_set(ev, .Repeat_Interval_Ns, &interval)
		selection_gesture_event_set(ev, .Repeat_Distance, &distance)
	}

	sel: Selection
	#partial switch selection_gesture_event(s.gesture, s.vt, ev, &sel) {
	case .Success:
		terminal_set(s.vt, .Selection, &sel)
	case .No_Value:
		// A plain press starts a new gesture: drop the old selection
		if type == .Press do terminal_set(s.vt, .Selection, nil)
	}
}


session_clear_selection :: proc(s: ^Session) {
	terminal_set(s.vt, .Selection, nil)
}


session_has_selection :: proc(s: ^Session) -> bool {
	sel: Selection
	return terminal_get(s.vt, .Selection, &sel) == .Success
}


// The selected text as plain UTF-8 (soft-wrapped lines joined, trailing
// spaces trimmed), or "" without a selection
session_selection_text :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	sel: Selection
	if terminal_get(s.vt, .Selection, &sel) != .Success do return ""

	// Plain text, wrapped lines joined and trailing spaces trimmed, as Ghostty copies
	f: Formatter
	if formatter_terminal_new(nil, &f, s.vt) != .Success do return ""
	defer formatter_free(f)

	emit := Formatter_Format.Plain
	unwrap := true
	formatter_set(f, .Emit, &emit)
	formatter_set(f, .Unwrap, &unwrap)
	formatter_set(f, .Selection, &sel)

	ptr: [^]u8
	n: uint
	result := formatter_format_alloc(f, nil, &ptr, &n)
	if result != .Success || ptr == nil {
		return ""
	}
	defer ghostty_free(nil, ptr, n)

	return strings.clone(string(ptr[:n]), allocator)
}
