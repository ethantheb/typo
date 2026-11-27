package editor

// Control requests: `typo ctl <command>` run in one of this window's terminals
// (docs/agent_control.md). A request is answered on its connection's thread
// (ipc.Control_Handler): it is refused unless the caller runs under one of the
// window's terminals, which the UI thread publishes (`roots`); else it is
// decoded there and queued for the UI thread, which applies it at the start of
// a frame and fills its slot

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import "ipc"
import "term"
import "uitime"


// How far up from the caller its terminal's shell is looked for
CONTROL_MAX_ANCESTORS :: 32

// The UI thread's share of control requests (perf)
control_ui: uitime.Share

// A request as `typo ctl` sends it: the command and its arguments
Control_Args :: struct {
	cmd:     string,
	exe:     string,   // restart: the executable to start (absolute)
	pane:    string,   // screenshot: the pane to take ("" for the window)
	out:     string,   // screenshot: the PNG to write (absolute)
	keys:    []string, // keys: chords, as settings.toml writes them
	text:    string,   // type
	target:  string,   // click, drag: an element id ("Name" or "Name:index") or "x,y"
	to:      string,   // drag: where the button comes up, likewise
	right:   bool,     // click
	double:  bool,     // click
	timeout: f64,      // wait: seconds (0 for the default)
	ids:     []string, // ui: element ids
	lines:   int,      // log: how many (0 for all kept)

	// Panes
	command: string, // do: a command's settings.toml key; terminal: a command line
	path:    string, // open, diff: a file (absolute)
	line:    int,    // open: 1-based, 0 for none
	col:     int,    // open: 1-based, 0 for none
	at:      string, // open, terminal: the pane to go beside
	side:    string, // left, right, top or bottom
	of:      string, // move: the pane to go beside
	edge:    string, // move: a side of the whole work area
	shelf:   bool,   // move
	focus:   bool,   // open, terminal, diff: focus it
	pinned:  bool,   // terminal: in herdr-core, whatever new terminals are
	local:   bool,   // terminal: here, whatever new terminals are
	hidden:  bool,   // terminal: on the shelf
	name:    string, // terminal, rename
	staged:  bool,   // diff
	off:     bool,   // maximize: restore instead
	git:     string, // git: "open" or "message"
}

// A request waiting for the UI thread, or in the flow it started
Control_Job :: struct {
	args:  Control_Args, // its strings in `arena`
	self:  u32,          // the caller's pane
	slot:  ^ipc.Slot,
	exe:   string,       // restart: what to start, in `arena`
	arena: virtual.Arena,

	// Requests that take frames (click, wait, screenshot)
	step:  int,
	frame: u64,       // the frame it was applied in
	start: time.Tick, // when it was applied
	pos:   [2]f32,    // click: where; drag: from
	to:    [2]f32,    // drag: to
}

// The terminals whose shells may control the window, by their shell's process
@(private = "file")
Control_Root :: struct {
	pane: u32,
	pid:  int,
}

@(private = "file")
roots: struct {
	mutex: sync.Mutex,
	list:  [dynamic]Control_Root,
}

@(private)
jobs: struct {
	mutex:  sync.Mutex,
	queue:  [dynamic]^Control_Job,
	active: ^Control_Job, // UI thread: a request that takes frames, under way
}

// A restart under way: the connection's thread starts the new typo, then the
// window quits
@(private = "file")
restart: struct {
	mutex:  sync.Mutex,
	result: enum {
		None,
		Launched,
		Failed,
	},
}

// The new typo, for `restart --exe`, runs from a copy here
@(private = "file")
RESTART_RUN_DIR :: "run"


// --- The connection's thread -------------------------------------------------------

// Answers a control request (ipc.Control_Handler)
control_answer :: proc(call: ipc.Control_Call, userdata: rawptr) -> ipc.Control_Reply {
	// Who is calling
	self, mine := caller_pane(call.caller)
	if !mine {
		return {.Not_Mine, ipc.error_json("not run in one of this window's terminals")}
	}

	// The request
	job := new(Control_Job)
	job.self = self
	arena := virtual.arena_allocator(&job.arena)
	err := json.unmarshal_string(call.json, &job.args, allocator = arena)
	if err != nil {
		job_free(job)
		return {.Error, ipc.error_json("typo could not read the request")}
	}
	if problem := job_prepare(job); problem != "" {
		job_free(job)
		return {.Error, ipc.error_json(problem)}
	}

	// The log needs nothing of the UI thread
	if job.args.cmd == "log" {
		reply := ipc.Control_Reply{.Ok, log_json(job.args.lines)}
		job_free(job)
		return reply
	}

	// The UI thread takes it next frame (and frees it)
	cmd := strings.clone(job.args.cmd, context.temp_allocator)
	out := strings.clone(job.args.out, context.temp_allocator)
	job.start = time.tick_now()
	job.slot = ipc.slot_new()
	slot := job.slot
	sync.lock(&jobs.mutex)
	append(&jobs.queue, job)
	sync.unlock(&jobs.mutex)
	wake_main_loop(nil)

	answered := ipc.slot_wait(call, slot)
	reply := ipc.slot_reply(slot)
	data := ipc.slot_data(slot)
	ipc.slot_release(slot)
	if !answered do return {.Error, ipc.error_json("the request was dropped")}

	// What the UI thread handed over, encoded here: a screenshot's pixels, the
	// panes; a restart the window agreed to: the new typo, then the reply
	if data != nil {
		if cmd == "screenshot" do return screenshot_save(data, out)
		return ls_encode((^Ls_Data)(data))
	}
	if job_is_restart(reply) {
		return restart_launch(call, reply)
	}
	return reply
}


// The pane whose shell the process `pid` runs under, if one of this window's
@(private = "file")
caller_pane :: proc(pid: int) -> (pane: u32, mine: bool) {
	chain := term.process_ancestors(pid, CONTROL_MAX_ANCESTORS, context.temp_allocator)

	sync.guard(&roots.mutex)
	for p in chain {
		for r in roots.list {
			if r.pid == p do return r.pane, true
		}
	}
	return 0, false
}


// Checks a request before it is queued and does what it needs off the UI
// thread; returns why it can't go, or ""
@(private = "file")
job_prepare :: proc(job: ^Control_Job) -> string {
	switch job.args.cmd {
	case "ls", "keys", "type", "click", "drag", "hover", "wait", "ui", "log":
		return ""

	case "do", "open", "terminal", "move", "focus", "maximize", "close", "rename", "diff",
	     "git":
		return panes_prepare(job)

	case "screenshot":
		if !filepath.is_abs(job.args.out) do return "screenshot needs --out <file.png>"
		return ""

	case "restart":
		return restart_prepare(job)
	}
	return fmt.tprintf("typo doesn't know the command %q", job.args.cmd)
}


@(private = "file")
job_free :: proc(job: ^Control_Job) {
	virtual.arena_destroy(&job.arena)
	free(job)
}


// --- The UI thread -----------------------------------------------------------------

// Per frame, from ipc_frame: publishes which terminals may control the window,
// goes on with a request that takes frames, else applies the next request
// unless the user is being asked something
control_frame :: proc() {
	uitime.timed(&control_ui)
	publish_roots()
	restart_frame()

	// One that takes frames comes first, and holds up the rest
	if jobs.active != nil {
		active_frame()
		return
	}
	if user_asked() {
		turn_away_queued()
		return
	}
	if control_waits() do return

	// The next request, one a frame
	sync.lock(&jobs.mutex)
	job: ^Control_Job
	if len(jobs.queue) > 0 do job = pop_front(&jobs.queue)
	sync.unlock(&jobs.mutex)
	if job == nil do return

	if ipc.slot_abandoned(job.slot) {
		job_done(job)
		return
	}

	job.frame = g.frame
	switch job.args.cmd {
	case "ls":
		ls_reply(job)
	case "restart":
		restart_begin(job)
	case "keys":
		keys_apply(job)
	case "type":
		type_apply(job)
	case "hover":
		hover_apply(job)
	case "ui":
		job_reply(job, .Ok, ui_json(job.args.ids))
	case "click", "drag", "wait", "screenshot":
		jobs.active = job
		active_frame()
	case:
		panes_apply(job)
	}
}


// Answers every queued request that the user is being asked something, so no
// client waits on them (holding a connection) and none answers it for them
@(private = "file")
turn_away_queued :: proc() {
	sync.lock(&jobs.mutex)
	queued := slice.clone(jobs.queue[:], context.temp_allocator)
	clear(&jobs.queue)
	sync.unlock(&jobs.mutex)

	problem := "typo is asking the user something; try again once they answer"
	for job in queued do job_reply(job, .Error, ipc.error_json(problem))
}


// Requests can be applied, or one under way takes frames (frames keep coming
// until they are done; `wait` lets the loop sleep, as that's what it waits for)
control_busy :: proc() -> bool {
	if jobs.active != nil do return jobs.active.args.cmd != "wait"
	if control_waits() do return false

	sync.guard(&jobs.mutex)
	return len(jobs.queue) > 0
}


// Whether requests wait: for the project to load or an action pending
@(private = "file")
control_waits :: proc() -> bool {
	return project_loading() || g.pending != nil
}


// Whether the user is being asked something (a dialog, the unsaved-changes
// flow): requests are turned away meanwhile, so none answers it for them
user_asked :: proc() -> bool {
	return g.unsaved.then != nil || g.dialog.open
}


control_destroy :: proc() {
	if jobs.active != nil do job_done(jobs.active)
	jobs.active = nil

	// A restart still in the unsaved-changes flow (typo quit meanwhile)
	if r, restarting := g.unsaved.then.(Restarting); restarting {
		g.unsaved.then = nil
		restart_declined((^Control_Job)(r))
	}

	sync.guard(&jobs.mutex)
	for job in jobs.queue do job_done(job)
	delete(jobs.queue)
	jobs.queue = nil

	sync.guard(&roots.mutex)
	delete(roots.list)
	roots.list = nil
}


// Answers a request and lets it go
job_reply :: proc(job: ^Control_Job, status: ipc.Control_Status, json: string) {
	ipc.slot_fill(job.slot, status, json)
	job_done(job)
}


// Lets a request go (its slot, its memory); the reply, if any, was given
job_done :: proc(job: ^Control_Job) {
	if jobs.active == job do jobs.active = nil
	ipc.slot_fill(job.slot, .Error, ipc.error_json("typo dropped the request"))
	ipc.slot_release(job.slot)
	job_free(job)
}


// The terminals whose shells are alive, by shell process, when that changed
@(private = "file")
publish_roots :: proc() {
	list := make([dynamic]Control_Root, context.temp_allocator)
	for p in g.panes.open {
		if !terminal_alive(p) do continue

		t := p.content.(^Terminal)
		pid := term.session_pid(&t.session)
		if pid > 0 do append(&list, Control_Root{p.id, pid})
	}

	sync.guard(&roots.mutex)
	if slice_equal(list[:], roots.list[:]) do return

	clear(&roots.list)
	append(&roots.list, ..list[:])
}


@(private = "file")
slice_equal :: proc(a, b: []Control_Root) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		if x != b[i] do return false
	}
	return true
}


// The pane a request names: "self", "focused", "p<id>" or an open file's path
control_pane :: proc(ref: string, self: u32) -> ^Pane {
	id: u32
	switch {
	case ref == "self":
		id = self
	case ref == "focused":
		return g.panes.focused
	case strings.has_prefix(ref, "p"):
		n, ok := strconv.parse_uint(ref[1:], 10)
		if !ok do return pane_with_file(ref)
		id = u32(n)
	case:
		return pane_with_file(ref)
	}

	for p in g.panes.open {
		if p.id == id do return p
	}
	return nil
}


// --- ls ----------------------------------------------------------------------------

@(private = "file")
Ls :: struct {
	project: string,
	window:  int, // typo's process
	self:    string,
	focused: string,
	panes:   []Ls_Pane,
	layout:  Ls_Tile, // empty when nothing is shown
	shelf:   []string,
}

@(private = "file")
Ls_Pane :: struct {
	id:        string,
	kind:      string,
	title:     string,
	shown:     bool,
	focused:   bool,
	maximized: bool,
	rect:      [4]f32, // x, y, width, height in the layout's units, as last laid out
	path:      string `json:",omitempty"`, // an editor's or a diff's file
	modified:  bool `json:",omitempty"`,
	pinned:    bool `json:",omitempty"`,   // a terminal in herdr-core
	address:   string `json:",omitempty"`, // its herdr-core terminal
	message:   string `json:",omitempty"`, // the Git pane's commit message
}

@(private = "file")
Ls_Tile :: struct {
	pane:     string `json:",omitempty"`, // a leaf
	axis:     string `json:",omitempty"`, // a split: "row" or "column"
	ratio:    f32 `json:",omitempty"`,    // the first child's share
	children: []Ls_Tile `json:",omitempty"`,
}


// The window's panes and layout, gathered here and encoded on the connection's
// thread (ls_encode)
Ls_Data :: struct {
	arena: virtual.Arena, // holds `ls` and its strings
	ls:    Ls,
}


// Gathers the window's panes and layout and hands them to the connection's
// thread with the reply
@(private = "file")
ls_reply :: proc(job: ^Control_Job) {
	data := new(Ls_Data)
	a := virtual.arena_allocator(&data.arena)
	ps := &g.panes

	data.ls = Ls {
		project = strings.clone(g.workspace.root, a),
		window  = os.get_pid(),
		self    = pane_ref(job.self, a),
	}
	if ps.focused != nil do data.ls.focused = pane_ref(ps.focused.id, a)

	// The panes, and those on the shelf
	panes := make([dynamic]Ls_Pane, a)
	shelf := make([dynamic]string, a)
	for p in ps.open {
		append(&panes, ls_pane(p, a))
		if !pane_shown(p) do append(&shelf, pane_ref(p.id, a))
	}
	data.ls.panes = panes[:]
	data.ls.shelf = shelf[:]
	if ps.root != nil do data.ls.layout = ls_tile(ps.root, a)

	if !ipc.slot_fill(job.slot, .Ok, "", data) do ls_free(data)
	job_done(job)
}


// On the connection's thread: the panes as JSON, freeing what was handed over
@(private = "file")
ls_encode :: proc(data: ^Ls_Data) -> ipc.Control_Reply {
	defer ls_free(data)

	encoded, err := json.marshal(data.ls, allocator = context.temp_allocator)
	if err != nil do return {.Error, ipc.error_json("typo couldn't encode the panes")}
	return {.Ok, string(encoded)}
}


@(private = "file")
ls_free :: proc(data: ^Ls_Data) {
	virtual.arena_destroy(&data.arena)
	free(data)
}


@(private = "file")
ls_pane :: proc(p: ^Pane, a: runtime.Allocator) -> Ls_Pane {
	ps := &g.panes
	out := Ls_Pane {
		id        = pane_ref(p.id, a),
		title     = strings.clone(pane_title(p), a),
		shown     = pane_shown(p),
		focused   = ps.focused == p,
		maximized = ps.maximized == p,
		rect      = {p.rect.x, p.rect.y, p.rect.w, p.rect.h},
	}

	switch c in p.content {
	case ^Editor:
		out.kind = "editor"
		out.path = strings.clone(c.path, a)
		out.modified = pane_modified(p)
	case ^Terminal:
		out.kind = "terminal"
		out.pinned = c.persistent
		out.address = strings.clone(c.address, a)
	case ^Git_View:
		out.kind = "git"
		out.message = strings.clone(text_area_string(&c.message), a)
	case ^Diff_View:
		out.kind = "diff"
		out.path = strings.clone(c.path, a)
	}
	return out
}


// A tile and those under it
@(private = "file")
ls_tile :: proc(t: ^Tile, a: runtime.Allocator) -> (out: Ls_Tile) {
	if t.pane != nil {
		out.pane = pane_ref(t.pane.id, a)
		return
	}

	out.axis = t.axis == .Row ? "row" : "column"
	out.ratio = t.ratio
	out.children = make([]Ls_Tile, 2, a)
	for child, i in t.children {
		if child != nil do out.children[i] = ls_tile(child, a)
	}
	return
}


// "p<id>"
@(private = "file")
pane_ref :: proc(id: u32, a: runtime.Allocator) -> string {
	return fmt.aprintf("p%d", id, allocator = a)
}


// --- restart -----------------------------------------------------------------------

// On the connection's thread: the executable the new typo runs. One given is
// copied (and older copies removed), so the build folder's stays free for the
// next build
@(private = "file")
restart_prepare :: proc(job: ^Control_Job) -> string {
	arena := virtual.arena_allocator(&job.arena)
	if job.args.exe == "" {
		own, err := os.get_executable_path(arena)
		if err != nil do return "typo can't find its own executable"
		job.exe = own
		return ""
	}

	if !os.is_file(job.args.exe) do return fmt.tprintf("%s isn't a file", job.args.exe)
	dir := restart_run_dir()
	if dir == "" do return "typo can't make a folder to run the new build from"
	remove_old_runs(dir)

	stamp := time.to_unix_nanoseconds(time.now())
	copy_path, _ := filepath.join({dir, fmt.tprintf("typo-%d.exe", stamp)}, arena)
	if os.copy_file(copy_path, job.args.exe) != nil {
		return fmt.tprintf("typo couldn't copy %s to %s", job.args.exe, dir)
	}
	job.exe = copy_path
	return ""
}


// %LOCALAPPDATA%\typo\run (made if missing); "" if it can't be
@(private = "file")
restart_run_dir :: proc() -> string {
	base, err := os.user_data_dir(context.temp_allocator)
	if err != nil do return ""

	dir, _ := filepath.join({base, "typo", RESTART_RUN_DIR}, context.temp_allocator)
	if !os.is_dir(dir) && os.make_directory_all(dir) != nil {
		return ""
	}
	return dir
}


// Removes the copies no typo runs from anymore (one running can't be removed)
@(private = "file")
remove_old_runs :: proc(dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return

	for e in entries {
		if strings.has_prefix(e.name, "typo-") && strings.has_suffix(e.name, ".exe") {
			_ = os.remove(e.fullpath)
		}
	}
}


// A restart asked for: only from a pinned terminal (a local one would end with
// the window) in a project (its session brings the panes back). Then the
// unsaved-changes flow, as quitting has
@(private = "file")
restart_begin :: proc(job: ^Control_Job) {
	p := control_pane("self", job.self)
	t: ^Terminal
	if p != nil do t, _ = p.content.(^Terminal)
	if t == nil || !t.persistent {
		problem := "restart works from a pinned terminal: this one would end with typo"
		job_reply(job, .Error, ipc.error_json(problem))
		return
	}
	if !g.project.keeps {
		problem := "this folder isn't a project (no .typo folder), so nothing would come back"
		job_reply(job, .Error, ipc.error_json(problem))
		return
	}

	resolve_unsaved(g.panes.open[:], Restarting(job))
}


// The unsaved-changes flow agreed: the session is saved and the connection's
// thread starts the new typo, after which the window quits (restart_frame)
restart_go :: proc(job: ^Control_Job) {
	session_save()

	exe := ipc.json_string(job.exe)
	project := ipc.json_string(g.workspace.root)
	parts := []string{`{"restart":`, exe, `,"project":`, project, "}"}
	job_reply(job, .Ok, strings.concatenate(parts, context.temp_allocator))
}


// The unsaved-changes flow was cancelled or replaced
restart_declined :: proc(job: ^Control_Job) {
	job_reply(job, .Declined, ipc.error_json("the restart was cancelled"))
}


// Quits once the new typo started
@(private = "file")
restart_frame :: proc() {
	sync.guard(&restart.mutex)
	switch restart.result {
	case .None:
	case .Launched:
		// Seen at the start of a frame: the loop may be about to sleep
		g.quit = true
		wake_main_loop(nil)
	case .Failed:
		show_notice("Couldn't restart", "typo couldn't start the new window.")
	}
	restart.result = .None
}


// Whether a reply is restart_go's
@(private = "file")
job_is_restart :: proc(reply: ipc.Control_Reply) -> bool {
	return reply.status == .Ok && strings.has_prefix(reply.json, `{"restart":`)
}


// On the connection's thread: starts the new typo, which waits for this one to
// end, and tells the window to quit; the reply for the client
@(private = "file")
restart_launch :: proc(call: ipc.Control_Call, reply: ipc.Control_Reply) -> ipc.Control_Reply {
	Plan :: struct {
		restart: string,
		project: string,
	}
	plan: Plan
	if json.unmarshal_string(reply.json, &plan, allocator = context.temp_allocator) != nil {
		return {.Error, ipc.error_json("typo could not read its restart")}
	}

	after := fmt.tprintf("%d", os.get_pid())
	desc := os.Process_Desc {
		command = {plan.restart, "--after", after, plan.project},
	}
	// Its handle goes with this process, which quits next
	_, err := os.process_start(desc)

	if err != nil {
		restart_result(.Failed)
		return {.Error, ipc.error_json(fmt.tprintf("typo couldn't start %s", plan.restart))}
	}

	// The window quits once the reply was sent: quitting cuts off what's unsent
	call.after^ = proc() {restart_result(.Launched)}
	project := ipc.json_string(plan.project)
	return {.Ok, strings.concatenate({`{"restarting":`, project, "}"}, context.temp_allocator)}
}


// Tells the window how the launch went, from the connection's thread
@(private = "file")
restart_result :: proc(result: type_of(restart.result)) {
	sync.guard(&restart.mutex)
	restart.result = result
	wake_main_loop(nil)
}
