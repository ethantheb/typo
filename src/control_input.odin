package editor

// Control requests for testing a running typo (docs/agent_control.md): keys,
// text and clicks fed in as the perf suite feeds them, waiting until nothing
// moves, screenshots of the frame drawn, element rects, and the recent log

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import clay "../vendor/clay-odin"
import "gfx"
import "ipc"
import sdl "../vendor/sdl3"
import "uitime"


// How long `wait` waits for an idle frame by default
@(private = "file")
WAIT_DEFAULT :: 10 * time.Second

// Log lines kept for `log`
@(private = "file")
LOG_LINES :: 200

// How long the last screenshot took to read back, on the UI thread (perf)
capture_ms: f64

// The recent log: SDL's log (Clay errors and renderer problems go there) and
// notices shown to the user. Written from any thread
@(private = "file")
log_ring: struct {
	mutex:    sync.Mutex,
	lines:    [LOG_LINES]string, // owned
	next:     int,
	count:    int,
	previous: sdl.LogOutputFunction, // SDL's own output, still called
	prev_ud:  rawptr,
}


// --- Keys and text -----------------------------------------------------------------

// Presses chords as typed keys, in order; refuses all of them if one isn't a
// key chord. Stops when one has the user asked something (a dialog, the
// unsaved-changes flow): the rest would answer it for them
keys_apply :: proc(job: ^Control_Job) {
	chords := make([dynamic]Chord, context.temp_allocator)
	for name in job.args.keys {
		c, ok := parse_chord(name)
		if !ok || c.button != 0 {
			job_reply(job, .Error, ipc.error_json(fmt.tprintf("%q isn't a key chord", name)))
			return
		}
		append(&chords, c)
	}

	pressed := 0
	for c in chords {
		if user_asked() do break

		event: sdl.Event
		event.type = .KEY_DOWN
		event.key.key = c.key
		event.key.scancode = sdl.GetScancodeFromKey(c.key, nil)
		if c.ctrl do event.key.mod |= sdl.KMOD_LCTRL
		if c.shift do event.key.mod |= sdl.KMOD_LSHIFT
		if c.alt do event.key.mod |= sdl.KMOD_LALT
		handle_key_event(&event)
		pressed += 1
	}

	asked := pressed < len(chords) || user_asked()
	json := fmt.tprintf(`{{"pressed":%d,"user_asked":%v}}`, pressed, asked)
	job_reply(job, .Ok, json)
}


// Types text as text input
type_apply :: proc(job: ^Control_Job) {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(job.args.text, context.temp_allocator)
	handle_key_event(&event)
	job_reply(job, .Ok, fmt.tprintf(`{{"typed":%d}}`, len(job.args.text)))
}


// Moves the pointer there and leaves it (a tooltip shows after its delay)
hover_apply :: proc(job: ^Control_Job) {
	pos, ok := click_target(job.args.target)
	if !ok {
		problem := fmt.tprintf("no element %q was laid out", job.args.target)
		job_reply(job, .Error, ipc.error_json(problem))
		return
	}
	g.mouse_pos = pos
	job_reply(job, .Ok, fmt.tprintf(`{{"hovering":[%.1f,%.1f]}}`, pos.x, pos.y))
}


// --- Requests that take frames -----------------------------------------------------

// A frame of the request under way: a click's steps, a wait's check, a
// screenshot's capture (control_capture)
active_frame :: proc() {
	job := jobs.active
	if ipc.slot_abandoned(job.slot) {
		job_done(job)
		return
	}

	switch job.args.cmd {
	case "click":
		click_step(job)
	case "drag":
		drag_step(job)
	case "wait", "screenshot":
		// At the end of the frame: control_capture, control_frame_end
	}
}


// A click over frames: the pointer moves there (so hover state follows), the
// button goes down, then up; a double click presses twice
@(private = "file")
click_step :: proc(job: ^Control_Job) {
	if job.step == 0 {
		pos, ok := click_target(job.args.target)
		if !ok {
			problem := fmt.tprintf("no element %q was laid out", job.args.target)
			job_reply(job, .Error, ipc.error_json(problem))
			return
		}
		job.pos = pos
	}

	g.mouse_pos = job.pos
	presses := job.args.double ? 2 : 1
	switch {
	case job.step == 0:
	case job.step % 2 == 1:
		// Down
		if job.args.right {
			g.right_pressed = true
		} else {
			g.mouse_down = true
			g.mouse_pressed = true
			g.mouse_clicks = (job.step + 1) / 2
		}
	case:
		// Up
		g.mouse_down = false
		if job.step / 2 >= presses {
			json := fmt.tprintf(`{{"clicked":[%.1f,%.1f]}}`, job.pos.x, job.pos.y)
			job_reply(job, .Ok, json)
			return
		}
	}
	job.step += 1
}


// A drag over frames: the pointer moves to the start, the button goes down,
// the pointer moves to the end in DRAG_STEPS frames, then the button comes up
@(private = "file")
drag_step :: proc(job: ^Control_Job) {
	if job.step == 0 {
		from, from_ok := click_target(job.args.target)
		to, to_ok := click_target(job.args.to)
		if !from_ok || !to_ok {
			missing := from_ok ? job.args.to : job.args.target
			problem := fmt.tprintf("no element %q was laid out", missing)
			job_reply(job, .Error, ipc.error_json(problem))
			return
		}
		job.pos = from
		job.to = to
	}

	switch {
	case job.step == 0:
		g.mouse_pos = job.pos
	case job.step == 1:
		g.mouse_pos = job.pos
		g.mouse_down = true
		g.mouse_pressed = true
		g.mouse_clicks = 1
	case job.step <= DRAG_STEPS + 1:
		t := f32(job.step - 1) / DRAG_STEPS
		g.mouse_pos = job.pos + (job.to - job.pos) * t
	case:
		g.mouse_pos = job.to
		g.mouse_down = false
		json := fmt.tprintf(`{{"dragged":[%.1f,%.1f]}}`, job.to.x, job.to.y)
		job_reply(job, .Ok, json)
		return
	}
	job.step += 1
}

// The frames a drag's move takes
@(private = "file")
DRAG_STEPS :: 6


// Where a click goes: an element's center, or "x,y" in the layout's units
@(private = "file")
click_target :: proc(target: string) -> (pos: [2]f32, ok: bool) {
	if comma := strings.index_byte(target, ','); comma > 0 {
		x, x_ok := strconv.parse_f32(strings.trim_space(target[:comma]))
		y, y_ok := strconv.parse_f32(strings.trim_space(target[comma + 1:]))
		return {x, y}, x_ok && y_ok
	}

	r, found := element_rect(element_id(target))
	if !found do return {}, false
	return {r.x + r.w / 2, r.y + r.h / 2}, true
}


// An element id from "Name" or "Name:index"
@(private = "file")
element_id :: proc(name: string) -> clay.ElementId {
	colon := strings.last_index_byte(name, ':')
	if colon > 0 {
		index, ok := strconv.parse_uint(name[colon + 1:], 10)
		if ok do return clay.ID(name[:colon], u32(index))
	}
	return clay.ID(name)
}


// Before the frame is presented: a screenshot under way reads what was drawn,
// all of it or a pane's part, and hands the pixels to the connection's thread
control_capture :: proc() {
	job := jobs.active
	if job == nil || job.args.cmd != "screenshot" do return

	// Timed apart from control_ui: reading the frame back waits for the GPU,
	// which a test's screenshot may take, once
	start := time.tick_now()
	defer capture_ms = time.duration_milliseconds(time.tick_since(start))

	// The pane's part, in pixels
	rect: Maybe(^sdl.Rect)
	area: sdl.Rect
	if job.args.pane != "" {
		p := control_pane(job.args.pane, job.self)
		if p == nil || !pane_shown(p) {
			problem := fmt.tprintf("no pane %q is shown", job.args.pane)
			job_reply(job, .Error, ipc.error_json(problem))
			return
		}
		s := gfx.scale
		area = {i32(p.rect.x * s), i32(p.rect.y * s), i32(p.rect.w * s), i32(p.rect.h * s)}
		rect = &area
	}

	surface := sdl.RenderReadPixels(gfx.renderer, rect)
	if surface == nil {
		job_reply(job, .Error, ipc.error_json("typo couldn't read the frame"))
		return
	}
	if !ipc.slot_fill(job.slot, .Ok, "{}", surface) {
		sdl.DestroySurface(surface)
	}
	job_done(job)
}


// At the end of a frame: a wait under way is answered once a frame after it
// had nothing to do; else another frame is asked for, until its time is up
control_frame_end :: proc() {
	uitime.timed(&control_ui)
	job := jobs.active
	if job == nil || job.args.cmd != "wait" do return

	limit := WAIT_DEFAULT
	if job.args.timeout > 0 do limit = time.Duration(job.args.timeout * f64(time.Second))
	switch {
	case g.frame > job.frame && g.sleeping && !g.animating:
		job_reply(job, .Ok, `{"idle":true}`)
	case time.tick_since(job.start) > limit:
		problem := fmt.tprintf("typo was still busy after %v", limit)
		job_reply(job, .Error, ipc.error_json(problem))
	case:
		wake_main_loop(nil)
	}
}


// On the connection's thread: writes a screenshot's pixels as a PNG; the reply
screenshot_save :: proc(data: rawptr, out: string) -> ipc.Control_Reply {
	surface := (^sdl.Surface)(data)
	defer sdl.DestroySurface(surface)

	path := strings.clone_to_cstring(out, context.temp_allocator)
	if !sdl.SavePNG(surface, path) {
		return {.Error, ipc.error_json(fmt.tprintf("typo couldn't write %s", out))}
	}
	parts := []string{
		`{"saved":`,
		ipc.json_string(out),
		fmt.tprintf(`,"width":%d,"height":%d}}`, surface.w, surface.h),
	}
	return {.Ok, strings.concatenate(parts, context.temp_allocator)}
}


// --- Element rects -----------------------------------------------------------------

@(private = "file")
Ui_Element :: struct {
	id:    string,
	found: bool,
	x, y:  f32,
	w, h:  f32,
}


// Where the last layout put each element (temp JSON)
ui_json :: proc(ids: []string) -> string {
	out := make([]Ui_Element, len(ids), context.temp_allocator)
	for id, i in ids {
		r, found := element_rect(element_id(id))
		out[i] = {id, found, r.x, r.y, r.w, r.h}
	}

	data, err := json.marshal(out, allocator = context.temp_allocator)
	return err == nil ? string(data) : "[]"
}


// --- The log -----------------------------------------------------------------------

// Keeps SDL's log for `log`, still writing it where SDL does
control_log_init :: proc() {
	sdl.GetLogOutputFunction(&log_ring.previous, &log_ring.prev_ud)
	sdl.SetLogOutputFunction(log_output, nil)
}


control_log_destroy :: proc() {
	sdl.SetLogOutputFunction(log_ring.previous, log_ring.prev_ud)

	sync.guard(&log_ring.mutex)
	for &line in log_ring.lines {
		delete(line, runtime.heap_allocator())
		line = ""
	}
	log_ring.count = 0
}


// Adds a line to the log, from any thread
control_log :: proc(line: string) {
	sync.guard(&log_ring.mutex)
	slot := &log_ring.lines[log_ring.next]
	delete(slot^, runtime.heap_allocator())
	slot^ = strings.clone(line, runtime.heap_allocator())
	log_ring.next = (log_ring.next + 1) % LOG_LINES
	log_ring.count = min(log_ring.count + 1, LOG_LINES)
}


@(private = "file")
log_output :: proc "c" (
	userdata: rawptr,
	category: sdl.LogCategory,
	priority: sdl.LogPriority,
	message: cstring,
) {
	context = runtime.default_context()
	control_log(string(message))
	if log_ring.previous != nil {
		log_ring.previous(log_ring.prev_ud, category, priority, message)
	}
}


// The last `n` lines kept, oldest first (all of them for 0), as temp JSON
log_json :: proc(n: int) -> string {
	sync.guard(&log_ring.mutex)
	count := n > 0 ? min(n, log_ring.count) : log_ring.count

	lines := make([]string, count, context.temp_allocator)
	for i in 0 ..< count {
		at := (log_ring.next - count + i + LOG_LINES) % LOG_LINES
		lines[i] = log_ring.lines[at]
	}

	data, err := json.marshal(lines, allocator = context.temp_allocator)
	return err == nil ? string(data) : "[]"
}
