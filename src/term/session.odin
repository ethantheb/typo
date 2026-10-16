package term

// A terminal session: a libghostty-vt terminal fed by a shell on a pty.
//
// A reader thread blocks on the pty and appends output to `incoming`, then
// calls `wake` so an idle UI loop runs a frame. The UI thread moves that output
// into the terminal in session_pump, within a time budget, so a flood of output
// (cat on a large file) never stalls a frame. Everything except the reader
// thread runs on the UI thread.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

MULTI_CLICK_NS :: 500 * time.Millisecond

Notify_Proc :: #type proc "contextless" (userdata: rawptr)

@(private = "file")
READ_CHUNK :: 64 * 1024

// The reader pauses while this much output is waiting to be parsed.
@(private = "file")
MAX_PENDING :: 8 * 1024 * 1024

// Scrollback kept per terminal (libghostty-vt counts it in bytes).
@(private = "file")
SCROLLBACK_BYTES :: 16 * 1024 * 1024

Session :: struct {
	vt:        Terminal,
	render:    Render_State,
	row_iter:  Row_Iterator,
	cells:     Row_Cells,
	key_enc:   Key_Encoder,
	key_ev:    Key_Event,
	mouse_enc: Mouse_Encoder,
	mouse_ev:  Mouse_Event,
	gesture:   Selection_Gesture,
	gesture_ev: [Gesture_Event_Type]Gesture_Event,
	cols:      u16,
	rows:      u16,
	cell_w:    u32,
	cell_h:    u32,

	pty:       Pty,
	running:   bool, // a shell is attached
	closing:   bool, // set by session_kill for the reader thread (atomic)
	reader:    ^thread.Thread,
	mutex:     sync.Mutex,
	incoming:  [dynamic]u8, // written by the reader thread, guarded by mutex
	work:      [dynamic]u8, // UI-thread copy being fed to the terminal
	work_pos:  int,
	parsed:    u64, // bytes of shell output fed to the terminal so far
	wake:      Notify_Proc,
	wake_data: rawptr,
}

// Creates the terminal state. No shell runs until session_spawn.
// `s` must not move afterwards: callbacks hold its address.
session_init :: proc(s: ^Session, cols, rows: u16, wake: Notify_Proc, wake_data: rawptr) -> bool {
	s.cols, s.rows = max(cols, 1), max(rows, 1)
	s.wake, s.wake_data = wake, wake_data
	trace_open()
	if terminal_new(nil, &s.vt, s.cols, s.rows) != .Success do return false
	scrollback: uint = SCROLLBACK_BYTES
	terminal_set(s.vt, .Scrollback_Max_Bytes, &scrollback)
	terminal_set(s.vt, .Userdata, s)
	terminal_set(s.vt, .Write_Pty, rawptr(Write_Pty_Fn(on_write_pty)))
	// The cursor blinks unless a program asks for a steady one.
	blink := true
	terminal_set(s.vt, .Default_Cursor_Blink, &blink)
	blink_mode := Mode_Config{mode = MODE_CURSOR_BLINKING, value = true}
	terminal_set(s.vt, .Mode_Default, &blink_mode)
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

session_destroy :: proc(s: ^Session) {
	session_kill(s)
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
	delete(s.incoming)
	delete(s.work)
	trace_close()
	s^ = {}
}

// Starts `command` (a full command line) in `cwd`.
session_spawn :: proc(s: ^Session, command, cwd: string) -> bool {
	if s.running do return true
	if !pty_spawn(&s.pty, command, cwd, s.cols, s.rows, s.wake, s.wake_data) do return false
	s.running = true
	sync.atomic_store(&s.closing, false)
	s.reader = thread.create_and_start_with_poly_data(s, reader_proc)
	return true
}

// Ends the shell (if running) and waits for its last output.
session_kill :: proc(s: ^Session) {
	if !s.running do return
	sync.atomic_store(&s.closing, true)
	pty_close(&s.pty)
	thread.join(s.reader)
	thread.destroy(s.reader)
	pty_close_output(&s.pty)
	s.reader = nil
	s.running = false
}

@(private = "file")
reader_proc :: proc(s: ^Session) {
	buf := make([]u8, READ_CHUNK)
	defer delete(buf)
	for {
		n := pty_read(&s.pty, buf)
		if n <= 0 do break
		trace("<", buf[:n])
		sync.lock(&s.mutex)
		append(&s.incoming, ..buf[:n])
		pending := len(s.incoming)
		sync.unlock(&s.mutex)
		s.wake(s.wake_data)
		// Back-pressure: let the UI thread catch up before reading more. Not
		// while closing: the UI thread is waiting for this thread to finish, and
		// the pty may only close once its output is drained.
		for pending > MAX_PENDING && !sync.atomic_load(&s.closing) {
			time.sleep(time.Millisecond)
			sync.lock(&s.mutex)
			pending = len(s.incoming)
			sync.unlock(&s.mutex)
		}
	}
}

// Replies to terminal queries (cursor position, device attributes, ...).
@(private = "file")
on_write_pty :: proc "c" (t: Terminal, userdata: rawptr, data: [^]u8, len: uint) {
	s := (^Session)(userdata)
	context = runtime.default_context()
	trace("reply", data[:len])
	if s.running do pty_write(&s.pty, data[:len])
}

// Feeds pending shell output to the terminal for up to `budget`. Returns true
// while output is still waiting, so the caller keeps drawing frames.
// Returns `exited` once, on the frame the shell's last output was consumed.
session_pump :: proc(s: ^Session, budget: time.Duration) -> (busy, exited: bool) {
	if s.running && pty_exited(&s.pty) {
		// The reader thread ends once the console is closed; everything it
		// read is then in `incoming` and is parsed below without a budget.
		session_kill(s)
		exited = true
	}
	start := time.tick_now()
	for {
		if s.work_pos >= len(s.work) {
			clear(&s.work)
			s.work_pos = 0
			sync.lock(&s.mutex)
			s.work, s.incoming = s.incoming, s.work
			sync.unlock(&s.mutex)
			if len(s.work) == 0 do return false, exited
		}
		end := min(s.work_pos + READ_CHUNK, len(s.work))
		terminal_vt_write(s.vt, &s.work[s.work_pos], uint(end - s.work_pos))
		s.parsed += u64(end - s.work_pos)
		s.work_pos = end
		if !exited && time.tick_since(start) > budget do return true, false
	}
}

// Sends typed input to the shell. Like most terminals, this snaps the view
// back to the bottom and drops the selection.
session_input :: proc(s: ^Session, data: []u8) {
	if !s.running || len(data) == 0 do return
	terminal_scroll_viewport(s.vt, {tag = .Bottom})
	session_clear_selection(s)
	session_write(s, data)
}

// Sends raw bytes to the shell.
session_write :: proc(s: ^Session, data: []u8) {
	if !s.running || len(data) == 0 do return
	trace("input", data)
	pty_write(&s.pty, data)
}

// Encodes a key press the way the running program asked for (legacy, kitty,
// application cursor keys, ...) and sends it. `unshifted` is the key's
// character without modifiers, or 0.
session_send_key :: proc(s: ^Session, key: Key, mods: Mods, repeat: bool, unshifted: rune) {
	ev := s.key_ev
	key_encoder_setopt_from_terminal(s.key_enc, s.vt)
	key_event_set_action(ev, repeat ? .Repeat : .Press)
	key_event_set_key(ev, key)
	key_event_set_mods(ev, mods)
	key_event_set_utf8(ev, nil, 0)
	key_event_set_unshifted_codepoint(ev, u32(unshifted))
	buf: [64]u8
	n: uint
	if key_encoder_encode(s.key_enc, ev, &buf[0], len(buf), &n) == .Success do session_input(s, buf[:n])
}

// Reports a mouse event to a program that turned mouse tracking on; the
// encoder drops events its mode doesn't want. `pos` is in pixels from the
// grid's top-left corner.
session_send_mouse :: proc(s: ^Session, action: Mouse_Action, button: Mouse_Button, mods: Mods, pos: [2]f32, any_pressed: bool) {
	size := init_sized(Mouse_Encoder_Size)
	size.screen_width, size.screen_height = u32(s.cols) * s.cell_w, u32(s.rows) * s.cell_h
	size.cell_width, size.cell_height = s.cell_w, s.cell_h
	pressed := any_pressed
	mouse_encoder_setopt_from_terminal(s.mouse_enc, s.vt)
	mouse_encoder_setopt(s.mouse_enc, .Size, &size)
	mouse_encoder_setopt(s.mouse_enc, .Any_Button_Pressed, &pressed)

	ev := s.mouse_ev
	mouse_event_set_action(ev, action)
	if button == .Unknown do mouse_event_clear_button(ev)
	else do mouse_event_set_button(ev, button)
	mouse_event_set_mods(ev, mods)
	mouse_event_set_position(ev, {pos.x, pos.y})
	buf: [64]u8
	n: uint
	if mouse_encoder_encode(s.mouse_enc, ev, &buf[0], len(buf), &n) == .Success do session_write(s, buf[:n])
}

// Pastes text, bracketed if the program asked for it, with unsafe control
// bytes stripped.
session_paste :: proc(s: ^Session, text: string) {
	if len(text) == 0 do return
	// The encoder rewrites the data in place.
	data := make([]u8, len(text), context.temp_allocator)
	copy(data, text)
	out := make([]u8, len(text) + 16, context.temp_allocator)
	n: uint
	if paste_encode(raw_data(data), len(data), session_mode(s, MODE_BRACKETED_PASTE), raw_data(out), len(out), &n) == .Success {
		session_input(s, out[:n])
	}
}

// Sends `count` up or down arrow keys, in the encoding the program expects.
session_send_arrows :: proc(s: ^Session, up: bool, count: int) {
	arrow := up ? "\x1b[A" : "\x1b[B"
	if session_mode(s, MODE_CURSOR_KEYS) do arrow = up ? "\x1bOA" : "\x1bOB"
	for _ in 0 ..< count do session_write(s, transmute([]u8)arrow)
}

// Whether the program asked for mouse events.
session_mouse_tracking :: proc(s: ^Session) -> bool {
	tracking: bool
	terminal_get(s.vt, .Mouse_Tracking, &tracking)
	return tracking
}

// Whether a full-screen program (pager, editor) is running: it switched to the
// alternate screen, or turned on application cursor keys. The second matters on
// Windows, where ConPTY keeps the alternate screen to itself but passes the
// cursor-key mode through.
session_full_screen :: proc(s: ^Session) -> bool {
	screen: i32
	terminal_get(s.vt, .Active_Screen, &screen)
	return screen == 1 || session_mode(s, MODE_CURSOR_KEYS)
}

session_resize :: proc(s: ^Session, cols, rows: u16, cell_w, cell_h: u32) {
	cols, rows := max(cols, 1), max(rows, 1)
	if cols == s.cols && rows == s.rows && cell_w == s.cell_w && cell_h == s.cell_h do return
	s.cols, s.rows, s.cell_w, s.cell_h = cols, rows, cell_w, cell_h
	terminal_resize(s.vt, cols, rows, cell_w, cell_h)
	if s.running do pty_resize(&s.pty, cols, rows)
}

// Writes a status line into the terminal itself, e.g. after the shell exits.
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

// --- Selection ----------------------------------------------------------------
// Mouse selection goes through libghostty-vt's gesture tracker, which counts
// clicks itself: a double click selects a word, a triple click a line. The
// selection lives in the terminal and is drawn from the render state.

// A cell in the visible viewport, clamped to the grid.
@(private = "file")
viewport_ref :: proc(s: ^Session, col, row: int) -> (ref: Grid_Ref, ok: bool) {
	ref = init_sized(Grid_Ref)
	p := Point{tag = .Viewport}
	p.value.coordinate = {u16(clamp(col, 0, int(s.cols) - 1)), u32(clamp(row, 0, int(s.rows) - 1))}
	ok = terminal_grid_ref(s.vt, p, &ref) == .Success
	return
}

// `pos` is the pointer in pixels relative to the grid's top-left corner.
session_select_event :: proc(s: ^Session, type: Gesture_Event_Type, col, row: int, pos: [2]f64, time_ns: u64) {
	ref, ok := viewport_ref(s, col, row)
	if !ok do return
	ev := s.gesture_ev[type]
	position := Surface_Position{pos.x, pos.y}
	geometry := Gesture_Geometry{columns = u32(s.cols), cell_width = s.cell_w, screen_height = u32(s.rows) * s.cell_h}
	// Options are per event type; setting one a type doesn't take is rejected.
	selection_gesture_event_set(ev, .Ref, &ref)
	if type != .Release do selection_gesture_event_set(ev, .Position, &position)
	if type == .Drag do selection_gesture_event_set(ev, .Geometry, &geometry)
	if type == .Press {
		// Presses chain into double/triple clicks within this time and distance.
		time, interval := time_ns, u64(MULTI_CLICK_NS)
		distance := max(f64(s.cell_w) / 2, 4)
		selection_gesture_event_set(ev, .Time_Ns, &time)
		selection_gesture_event_set(ev, .Repeat_Interval_Ns, &interval)
		selection_gesture_event_set(ev, .Repeat_Distance, &distance)
	}
	sel := init_sized(Selection)
	switch selection_gesture_event(s.gesture, s.vt, ev, &sel) {
	case .Success:
		terminal_set(s.vt, .Selection, &sel)
	case .No_Value:
		// A plain press starts a new gesture: drop the old selection.
		if type == .Press do terminal_set(s.vt, .Selection, nil)
	case .Out_Of_Memory, .Invalid_Value, .Out_Of_Space, .Io_Error, .Limit_Exceeded, .Rejected:
	}
}

session_clear_selection :: proc(s: ^Session) {
	terminal_set(s.vt, .Selection, nil)
}

session_has_selection :: proc(s: ^Session) -> bool {
	sel := init_sized(Selection)
	return terminal_get(s.vt, .Selection, &sel) == .Success
}

// The selected text as plain UTF-8 (soft-wrapped lines joined, trailing
// spaces trimmed), or "" without a selection.
session_selection_text :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	sel := init_sized(Selection)
	if terminal_get(s.vt, .Selection, &sel) != .Success do return ""
	opts := init_sized(Selection_Format_Options)
	opts.emit = .Plain
	opts.unwrap = true
	opts.trim = true
	opts.selection = &sel
	ptr: [^]u8
	n: uint
	if terminal_selection_format_alloc(s.vt, nil, opts, &ptr, &n) != .Success || ptr == nil do return ""
	defer ghostty_free(nil, ptr, n)
	return strings.clone(string(ptr[:n]), allocator)
}
