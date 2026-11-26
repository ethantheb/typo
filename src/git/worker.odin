package git

// The worker thread: it owns the repository and does everything that reads or
// changes it, in the order asked. The UI thread sets the folder, queues
// requests and takes events (worker_take). Each change is followed by a fresh
// status. Refreshes asked for while one runs are done once after it, and never
// closer together than the last one took (REFRESH_GAP at least), so a huge
// repository doesn't keep a core busy. Between requests the worker looks at the
// files that describe the repository (watched_files) every POLL, and refreshes
// when they change: a commit or checkout made in a terminal shows up

import "base:runtime"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import lg "../../vendor/libgit2"


POLL        :: 500 * time.Millisecond
REFRESH_GAP :: 100 * time.Millisecond

Notify_Proc :: #type proc "contextless" (userdata: rawptr)

Worker :: struct {
	ctx:            runtime.Context,
	thread:         ^thread.Thread,
	wake:           Notify_Proc, // from the worker's threads: events are waiting
	wake_data:      rawptr,

	// Shared, under the mutex
	mutex:          sync.Mutex,
	cond:           sync.Cond,
	stop:           bool,
	folder:         string, // owned; the workspace folder, "" for none
	folder_gen:     int,    // counts folder changes
	workdir:        string, // owned; the repository's work tree, "" for none
	requests:       [dynamic]Request,
	refresh_wanted: bool,
	working:        bool, // requests or a refresh under way
	events:         [dynamic]Event,
	cli:            Cli,
}

// What the UI thread asks for. Paths are relative to the work tree; every
// string is owned and taken by worker_post
Stage :: struct {
	paths: []string,
}
Unstage :: struct {
	paths: []string,
}
Discard :: struct {
	paths: []string, // checked out from the index
}
Delete_Untracked :: struct {
	paths:    []string,
	to_trash: bool, // else deleted for good
}
// Replaces [lo, hi) of a file's staged text, which must still be `base`
Splice_Index :: struct {
	path:   string,
	base:   lg.Oid,
	lo, hi: int,
	text:   []u8,
}

Request :: union {
	Stage,
	Unstage,
	Discard,
	Delete_Untracked,
	Splice_Index,
}

// What the worker hands over. The UI thread owns each event it takes
Repo_Opened :: struct {
	info: Repo_Info,
}
Repo_None :: struct {
	problem: string, // owned; why it couldn't open, "" for no repository
}
Status_Ready :: struct {
	status: Status,
}
Op_Failed :: struct {
	message: string, // owned
}
Remote_Done :: struct {
	op:        Remote_Op,
	ok:        bool,
	output:    string, // owned
	auth:      bool,   // failed for want of credentials
	line:      string, // owned; the command line it ran
	cancelled: bool,   // ended by worker_cancel
}

Event :: union {
	Repo_Opened,
	Repo_None,
	Status_Ready,
	Op_Failed,
	Remote_Done,
}


// --- UI thread ---------------------------------------------------------------------

// Starts the worker; `wake` is called from its threads when events wait
worker_start :: proc(w: ^Worker, wake: Notify_Proc, wake_data: rawptr) {
	library_init()

	w.ctx = runtime.default_context()
	w.ctx.allocator = context.allocator
	w.wake = wake
	w.wake_data = wake_data
	w.thread = thread.create_and_start_with_poly_data(w, worker_proc, w.ctx)
}


// Stops the worker after what it is doing, waiting for a command under way
worker_stop :: proc(w: ^Worker) {
	if w.thread == nil do return

	if sync.guard(&w.mutex) {
		w.stop = true
		sync.cond_signal(&w.cond)
	}
	thread.destroy(w.thread)
	cli_stop(&w.cli)

	for &r in w.requests do request_destroy(&r)
	delete(w.requests)
	for &e in w.events do event_destroy(&e)
	delete(w.events)
	delete(w.folder)
	delete(w.workdir)
	w^ = {}

	library_shutdown()
}


// Follows the repository `folder` is in ("" for none). Requests and events
// still queued are the old repository's: their paths mean other files in the
// new one, so they are dropped
worker_set_folder :: proc(w: ^Worker, folder: string) {
	sync.guard(&w.mutex)
	delete(w.folder)
	w.folder = strings.clone(folder)
	w.folder_gen += 1

	for &r in w.requests do request_destroy(&r)
	clear(&w.requests)
	for &e in w.events do event_destroy(&e)
	clear(&w.events)
	sync.cond_signal(&w.cond)
}


// Queues a request, taking what it owns
worker_post :: proc(w: ^Worker, r: Request) {
	sync.guard(&w.mutex)
	append(&w.requests, r)
	sync.cond_signal(&w.cond)
}


// Asks for a fresh status (the work tree changed)
worker_refresh :: proc(w: ^Worker) {
	sync.guard(&w.mutex)
	w.refresh_wanted = true
	sync.cond_signal(&w.cond)
}


// Runs a git command (git and its arguments) in the work tree, with `input` on
// its stdin. False if another command still runs, or there is no repository
worker_run :: proc(w: ^Worker, op: Remote_Op, args: []string, input := "") -> bool {
	sync.guard(&w.mutex)
	if w.workdir == "" do return false
	return cli_start(w, op, args, input, w.workdir)
}


// Ends the git command under way, if any, with what it started (a credential
// window included). Its Remote_Done comes as cancelled
worker_cancel :: proc(w: ^Worker) {
	sync.guard(&w.mutex)
	if !w.cli.busy do return

	w.cli.cancelled = true
	running_end(&w.cli.running)
}


// Whether a git command runs
worker_running :: proc(w: ^Worker) -> bool {
	sync.guard(&w.mutex)
	return w.cli.busy
}


// Whether anything is asked for or under way (for tests and the perf suite)
worker_busy :: proc(w: ^Worker) -> bool {
	sync.guard(&w.mutex)
	return w.working || w.refresh_wanted || len(w.requests) > 0 || w.cli.busy
}


// Takes the events handed over since the last call; the caller owns them
// (destroy each with event_destroy). The slice is in the temp allocator
worker_take :: proc(w: ^Worker) -> []Event {
	sync.guard(&w.mutex)
	events := slice.clone(w.events[:], context.temp_allocator)
	clear(&w.events)
	return events
}


event_destroy :: proc(e: ^Event) {
	switch &x in e {
	case Repo_Opened:  repo_info_destroy(&x.info)
	case Repo_None:    delete(x.problem)
	case Status_Ready: status_destroy(&x.status)
	case Op_Failed:    delete(x.message)
	case Remote_Done:
		delete(x.output)
		delete(x.line)
	}
	e^ = nil
}


request_destroy :: proc(r: ^Request) {
	switch &x in r {
	case Stage:            delete_paths(x.paths)
	case Unstage:          delete_paths(x.paths)
	case Discard:          delete_paths(x.paths)
	case Delete_Untracked: delete_paths(x.paths)
	case Splice_Index:
		delete(x.path)
		delete(x.text)
	}
	r^ = nil
}


@(private = "file")
delete_paths :: proc(paths: []string) {
	for p in paths do delete(p)
	delete(paths)
}


// --- Worker thread -----------------------------------------------------------------

// The worker's own state
@(private = "file")
Work :: struct {
	repo:         Repo,
	opened:       bool,
	folder_gen:   int,
	generation:   u64,
	next_refresh: time.Tick, // refreshes wait for this
	next_poll:    time.Tick,
	watched:      u64,       // the watched files' signature at the last refresh
	branch:       string,    // owned; the last refresh's branch and upstream, whose
	upstream:     string,    // refs the poll looks at
}


@(private = "file")
worker_proc :: proc(w: ^Worker) {
	work := Work{folder_gen = -1}
	defer {
		repo_close(&work.repo)
		forget_branch(&work)
	}

	for {
		defer free_all(context.temp_allocator)

		// What the UI thread asked for, waiting until something is due
		requests: []Request
		folder: string
		folder_changed, refresh: bool
		if sync.guard(&w.mutex) {
			for !w.stop && !has_work(w, &work) {
				timeout := time.tick_diff(time.tick_now(), next_due(w, &work))
				if timeout <= 0 do break
				sync.cond_wait_with_timeout(&w.cond, &w.mutex, timeout)
			}
			if w.stop do return

			if w.folder_gen != work.folder_gen {
				work.folder_gen = w.folder_gen
				folder = strings.clone(w.folder, context.temp_allocator)
				folder_changed = true
			}
			requests = slice.clone(w.requests[:], context.temp_allocator)
			clear(&w.requests)

			due := time.tick_diff(work.next_refresh, time.tick_now()) >= 0
			refresh = w.refresh_wanted && due
			if refresh do w.refresh_wanted = false
			w.working = true
		}

		if folder_changed {
			open_folder(w, &work, folder)
			refresh = work.opened
		}

		// The requests, in order; each changes the repository
		for &r in requests {
			if work.opened {
				problem := do_request(&work.repo, r)
				if problem != "" do hand_over(w, &work, Op_Failed{strings.clone(problem)})
				refresh = true
			}
			request_destroy(&r)
		}

		// The files that describe the repository
		now := time.tick_now()
		if work.opened && time.tick_diff(work.next_poll, now) >= 0 {
			work.next_poll = time.tick_add(now, POLL)
			if watched_signature(&work) != work.watched do refresh = true
		}

		if refresh && work.opened {
			refresh_status(w, &work)
		}

		if sync.guard(&w.mutex) {
			w.working = false
		}
	}
}


// Whether something can be done now. Called under the mutex
@(private = "file")
has_work :: proc(w: ^Worker, work: ^Work) -> bool {
	if w.folder_gen != work.folder_gen || len(w.requests) > 0 {
		return true
	}

	now := time.tick_now()
	refresh_due := w.refresh_wanted && time.tick_diff(work.next_refresh, now) >= 0
	poll_due := work.opened && time.tick_diff(work.next_poll, now) >= 0
	return refresh_due || poll_due
}


// When the next thing falls due without being asked: a refresh waiting for its
// gap, or the next poll
@(private = "file")
next_due :: proc(w: ^Worker, work: ^Work) -> time.Tick {
	at := time.tick_add(time.tick_now(), time.Hour)
	if work.opened do at = work.next_poll
	if w.refresh_wanted && time.tick_diff(work.next_refresh, at) < 0 {
		at = work.next_refresh
	}
	return at
}


// Opens the repository of a new folder, handing over what was found
@(private = "file")
open_folder :: proc(w: ^Worker, work: ^Work, folder: string) {
	repo_close(&work.repo)
	forget_branch(work)
	work.opened = false

	found, problem := false, ""
	if folder != "" {
		found, problem = repo_open(&work.repo, folder)
	}

	if sync.guard(&w.mutex) {
		delete(w.workdir)
		w.workdir = found ? strings.clone(work.repo.info.workdir) : ""
	}

	if !found {
		hand_over(w, work, Repo_None{strings.clone(problem)})
		return
	}
	work.opened = true
	hand_over(w, work, Repo_Opened{repo_info_clone(work.repo.info)})
}


@(private = "file")
do_request :: proc(r: ^Repo, req: Request) -> string {
	switch x in req {
	case Stage:            return stage(r, x.paths)
	case Unstage:          return unstage(r, x.paths)
	case Discard:          return discard(r, x.paths)
	case Delete_Untracked: return delete_untracked(r, x.paths, x.to_trash)
	case Splice_Index:     return splice_index(r, x.path, x.base, x.lo, x.hi, x.text)
	}
	return ""
}


// Reads the status and hands it over; the next refresh waits at least as long
// as this one took
@(private = "file")
refresh_status :: proc(w: ^Worker, work: ^Work) {
	start := time.tick_now()
	work.generation += 1

	s, problem := read_status(&work.repo, work.generation)
	if problem != "" {
		hand_over(w, work, Op_Failed{strings.clone(problem)})
	} else {
		// The branch names the poll looks for, then the status
		forget_branch(work)
		work.branch = strings.clone(s.branch)
		work.upstream = strings.clone(s.upstream)
		hand_over(w, work, Status_Ready{s})
	}

	took := time.tick_since(start)
	work.next_refresh = time.tick_add(time.tick_now(), max(took, REFRESH_GAP))
	work.watched = watched_signature(work)
}


@(private = "file")
forget_branch :: proc(work: ^Work) {
	delete(work.branch)
	delete(work.upstream)
	work.branch, work.upstream = "", ""
}


// A hash of the watched files' sizes and times (and whether each is there)
@(private = "file")
watched_signature :: proc(work: ^Work) -> u64 {
	h: u64 = 14695981039346656037
	for path in watched_files(&work.repo, work.branch, work.upstream) {
		stamp: [2]i64
		if info, err := os.stat(path, context.temp_allocator); err == nil {
			stamp = {info.size, time.to_unix_nanoseconds(info.modification_time)}
		}
		h = hash.fnv64a(transmute([]u8)path, h)
		h = hash.fnv64a(([^]u8)(&stamp)[:size_of(stamp)], h)
	}
	return h
}


// Hands an event over, unless the folder changed since the work it comes
// from began: then it is the old repository's, and dropped
@(private = "file")
hand_over :: proc(w: ^Worker, work: ^Work, e: Event) {
	e := e
	if sync.guard(&w.mutex) {
		if work.folder_gen == w.folder_gen {
			append(&w.events, e)
		} else {
			event_destroy(&e)
		}
	}
	w.wake(w.wake_data)
}
