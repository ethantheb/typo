package editor

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "buffer"
import "diff"

// Watching for changes other programs make to the workspace folder and to open
// files. A thread waits on the system's notifications (fs_watch_windows.odin;
// elsewhere it polls, fs_watch_other.odin), gathers a burst of them until it
// settles, and hands finished results to the UI thread (watch_take): the tree's
// changed folders listed again, and new versions of open files, read once they
// hold still. It also diffs a file's new version against the editor's text, so
// a reload is a few line edits. The UI thread applies results (file_sync.odin).
//
// Open files are known by the text typo last read or wrote (its hash) and the
// file's size and write time then, so typo's own saves are never reported


WATCH_QUIET      :: 100 * time.Millisecond // a burst is handed over once quiet this long
WATCH_MAX_DELAY  :: time.Second            // or once it has gone on this long
WATCH_STABLE     :: 50 * time.Millisecond  // a file's size and time must hold this long
WATCH_SETTLE_MAX :: 5 * time.Second        // a file that never holds still is read anyway
WATCH_MISSING    :: 300 * time.Millisecond // a vanished file is gone if still missing then
WATCH_BUSY_MAX   :: 30 * time.Second       // a file others keep locked is retried this long
WATCH_POLL       :: time.Second            // files no notification covers are looked at

// A file's size and last write time (in the system's units); {} when unknown
File_Stamp :: struct {
	size:  i64,
	mtime: i64,
}

// A version of a file on disk
Disk_Version :: struct {
	data:  []u8, // owned
	hash:  u64,
	stamp: File_Stamp,
}

Read_Error :: enum {
	None,
	Missing,
	Busy, // another program holds it locked
	Failed,
}

Watch_Action :: enum u8 {
	Added,
	Removed,
	Modified,
	Renamed_From,
	Renamed_To,
}

// A notification, as the platform reports it
Watch_Event :: struct {
	path:   string, // full path
	action: Watch_Action,
}

// What a burst of events changed, gathered until it settles
Watch_Pending :: struct {
	dirs:      map[string]string,   // folders whose entries changed: key -> path (owned)
	paths:     map[string]struct{}, // keys (owned) of every path changed in any way
	structure: bool,                // files or folders were added, removed or renamed
	overflow:  bool,                // events were lost: everything is looked at again
	count:     int,                 // events gathered
	first:     time.Tick,
	last:      time.Tick,
}

// --- Results, handed to the UI thread ---

Folder_Listing :: struct {
	dir:     string,      // owned
	entries: []Dir_Entry, // owned, names too; in tree order
}

// A burst of changes in the workspace (handed over for any, so the Git status
// follows files written in place): folders of the tree listed again, and
// `structure` when files were added, removed or renamed (the finder's index is
// stale)
Watch_Batch :: struct {
	listings:  []Folder_Listing,
	structure: bool,
}

// An open file has a version typo doesn't have. `same`: it is the text typo
// last read or wrote, back after the file was missing
File_Changed :: struct {
	path:       string, // owned
	generation: u32,
	version:    Disk_Version,
	same:       bool,
}

// An open file was deleted or moved away
File_Missing :: struct {
	path:       string, // owned
	generation: u32,
}

// A new version diffed against an editor's text (`Reload_Job`)
Reload_Ready :: struct {
	path:           string, // owned
	serial:         int,
	buffer_version: u64,
	version:        Disk_Version,
	hunks:          []diff.Hunk, // owned
}

Watch_Result :: union {
	Watch_Batch,
	File_Changed,
	File_Missing,
	Reload_Ready,
}

// Asks for a new version diffed against an editor's text (`old`)
Reload_Job :: struct {
	path:    string,          // owned
	serial:  int,
	old:     buffer.Snapshot, // owned
	version: Disk_Version,
}

// An open file, as the watcher knows it
@(private = "file")
Watched_File :: struct {
	path:       string, // owned
	users:      int,    // editors with it open
	hash:       u64,        // of the text typo last read or wrote
	stamp:      File_Stamp, // the file's then, or of a version the user kept theirs over
	generation: u32,        // counts reads and writes; results about older ones are dropped
	seen:       File_Stamp, // the last version handed over, not handed over twice
	missing:    bool,       // handed over as missing
}

// A look at an open file that may have changed, repeated until it is done
@(private = "file")
File_Check :: struct {
	key:     string, // owned
	path:    string, // owned
	due:     time.Tick,
	started: time.Tick,
	stamp:   File_Stamp, // at the previous look, to tell whether it holds still
	looks:   int,
	busy:    int,  // reads refused because another program holds the file
	absent:  bool, // missing at the previous look
}

// The watcher thread's own state
@(private = "file")
Watch_Thread :: struct {
	root:      string, // owned; "" for none
	root_gen:  int,
	watching:  bool, // notifications cover the root
	pending:   Watch_Pending,
	checks:    [dynamic]File_Check,
	events:    [dynamic]Watch_Event,
	next_poll: time.Tick,
}

@(private = "file")
watch: struct {
	thread:   ^thread.Thread,
	platform: Watch_Platform,
	running:  bool, // UI thread only

	// Set by the UI thread, under the mutex
	mutex:    sync.Mutex,
	stop:     bool,
	root:     string,                  // owned
	root_gen: int,                     // counts root changes
	dirs:     map[string]string,       // the tree's loaded folders: key -> path (owned)
	files:    map[string]Watched_File, // open files, by key (owned)
	opened:   [dynamic]string,         // keys (owned) of files registered since the thread looked
	jobs:     [dynamic]Reload_Job,

	// Handed to the UI thread, under the mutex
	results:  [dynamic]Watch_Result,
}


// --- UI thread ---------------------------------------------------------------------

// Starts the watcher thread, which runs until watch_destroy
watch_init :: proc() {
	if watch.running do return

	watch.running = true
	platform_init(&watch.platform)

	ctx := runtime.default_context()
	ctx.allocator = context.allocator
	watch.thread = thread.create_and_start(watch_thread_proc, ctx)
}


watch_destroy :: proc() {
	if !watch.running do return

	if sync.guard(&watch.mutex) {
		watch.stop = true
	}
	platform_wake(&watch.platform)
	thread.join(watch.thread)
	thread.destroy(watch.thread)
	platform_destroy(&watch.platform)

	// What was left
	delete(watch.root)
	for key, dir in watch.dirs {
		delete(key)
		delete(dir)
	}
	delete(watch.dirs)
	for key, f in watch.files {
		delete(key)
		delete(f.path)
	}
	delete(watch.files)
	for key in watch.opened do delete(key)
	delete(watch.opened)
	for job in watch.jobs do reload_job_destroy(job)
	delete(watch.jobs)
	for r in watch.results do watch_result_destroy(r)
	delete(watch.results)

	watch = {}
}


// Watches a new workspace folder ("" for none)
watch_set_root :: proc(root: string) {
	if !watch.running do return

	if sync.guard(&watch.mutex) {
		delete(watch.root)
		watch.root = strings.clone(root)
		watch.root_gen += 1
	}
	platform_wake(&watch.platform)
}


// The folders the tree has listed, whose changes it shows
watch_set_dirs :: proc(dirs: []string) {
	if !watch.running do return

	sync.guard(&watch.mutex)
	for key, dir in watch.dirs {
		delete(key)
		delete(dir)
	}
	clear(&watch.dirs)
	for dir in dirs {
		watch.dirs[path_key(dir)] = strings.clone(dir)
	}
}


// Starts watching a file an editor opened: `hash` and `stamp` are of the text
// it read (`exists` false for a new file). Returns the file's generation. The
// thread looks at it once, as it may have changed since it was read
watch_file_open :: proc(path: string, hash: u64, stamp: File_Stamp, exists: bool) -> u32 {
	if !watch.running do return 0

	generation: u32
	if sync.guard(&watch.mutex) {
		key := path_key(path)
		f, found := &watch.files[key]
		if found {
			delete(key)
		} else {
			watch.files[key] = {path = strings.clone(path)}
			f = &watch.files[key]
		}

		f.users += 1
		f.hash, f.stamp = hash, stamp
		f.seen = {}
		f.missing = !exists
		f.generation += 1
		generation = f.generation
		append(&watch.opened, path_key(path))
	}

	platform_wake(&watch.platform)
	return generation
}


// After typo wrote the file or read it again: its text is the editor's.
// Returns the file's new generation
watch_file_synced :: proc(path: string, hash: u64, stamp: File_Stamp) -> u32 {
	if !watch.running do return 0

	sync.guard(&watch.mutex)
	key := path_key(path)
	defer delete(key)

	f, found := &watch.files[key]
	if !found do return 0

	f.hash, f.stamp = hash, stamp
	f.seen = {}
	f.missing = false
	f.generation += 1
	return f.generation
}


// The user kept their text over the version on disk with `stamp`: it isn't a
// change anymore
watch_file_kept :: proc(path: string, stamp: File_Stamp) {
	if !watch.running do return

	sync.guard(&watch.mutex)
	key := path_key(path)
	defer delete(key)

	if f, found := &watch.files[key]; found {
		f.stamp = stamp
	}
}


// An editor closed the file
unwatch_file :: proc(path: string) {
	if !watch.running do return

	sync.guard(&watch.mutex)
	key := path_key(path)
	defer delete(key)

	f, found := &watch.files[key]
	if !found do return

	f.users -= 1
	if f.users > 0 do return

	delete(f.path)
	stored, _ := delete_key(&watch.files, key)
	delete(stored)
}


// Asks the thread to diff a new version against an editor's text (taken)
watch_post_job :: proc(job: Reload_Job) {
	if !watch.running {
		reload_job_destroy(job)
		return
	}

	if sync.guard(&watch.mutex) {
		append(&watch.jobs, job)
	}
	platform_wake(&watch.platform)
}


// Takes the results handed over since the last call (the caller owns them),
// in the temp allocator
watch_take :: proc() -> []Watch_Result {
	if !watch.running do return nil

	sync.guard(&watch.mutex)
	results := slice.clone(watch.results[:], context.temp_allocator)
	clear(&watch.results)
	return results
}


watch_result_destroy :: proc(r: Watch_Result) {
	switch r in r {
	case Watch_Batch:
		for l in r.listings do folder_listing_destroy(l)
		delete(r.listings)
	case File_Changed:
		delete(r.path)
		delete(r.version.data)
	case File_Missing:
		delete(r.path)
	case Reload_Ready:
		delete(r.path)
		delete(r.version.data)
		delete(r.hunks)
	}
}


// Lists a folder for the tree (read_tree_folder), owning what it lists
folder_listing_read :: proc(dir: string) -> (l: Folder_Listing, ok: bool) {
	entries := read_tree_folder(dir) or_return

	owned := make([]Dir_Entry, len(entries))
	for e, i in entries {
		owned[i] = e
		owned[i].name = strings.clone(e.name)
	}
	return {strings.clone(dir), owned}, true
}


folder_listing_destroy :: proc(l: Folder_Listing) {
	delete(l.dir)
	for e in l.entries do delete(e.name)
	delete(l.entries)
}


@(private = "file")
reload_job_destroy :: proc(job: Reload_Job) {
	job := job
	delete(job.path)
	buffer.snapshot_release(&job.old)
	delete(job.version.data)
}


// The hash typo keeps of a file's text
file_hash :: proc(data: []u8) -> u64 {
	// The hash refuses a nil slice, which an empty file reads as
	empty: [1]u8
	return xxhash.XXH3_64_default(len(data) > 0 ? data : empty[:0])
}


// --- Paths -------------------------------------------------------------------------

// A path as a map key: on Windows, where names ignore case, folded to lower
// case with backslashes. Allocated
path_key :: proc(path: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Windows {
		lower := strings.to_lower(path, allocator)
		for i in 0 ..< len(lower) {
			if lower[i] == '/' do (transmute([]u8)lower)[i] = '\\'
		}
		return lower
	} else {
		return strings.clone(path, allocator)
	}
}


// A path key as path_key makes it, but with only ASCII letters folded, written
// to `buf` (the temp allocator if it doesn't fit): for lookups in hot loops.
// Keys compared with it are all made with it
path_key_ascii :: proc(path: string, buf: []u8) -> string {
	when ODIN_OS != .Windows do return path

	key: []u8
	if len(path) <= len(buf) {
		key = buf[:len(path)]
	} else {
		key = make([]u8, len(path), context.temp_allocator)
	}

	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'A' ..= 'Z': key[i] = c + ('a' - 'A')
		case '/':         key[i] = '\\'
		case:             key[i] = c
		}
	}
	return string(key)
}


// The folder a path is in; a drive root keeps its separator ("C:\")
parent_dir :: proc(path: string) -> string {
	i := len(path) - 1
	for i > 0 && !is_separator(path[i]) {
		i -= 1
	}
	if i <= 0 {
		return len(path) > 0 && is_separator(path[0]) ? path[:1] : ""
	}

	parent := path[:i]
	if strings.has_suffix(parent, ":") do return path[:i + 1]
	return parent
}


// Whether an event is inside a folder the finder ignores (.git, node_modules,
// build outputs), or is typo's own project state being saved (.typo's
// session.json and its temp file, written as the user works: no reason to
// list the tree or refresh Git). The ignored folder itself still counts, as
// the tree shows it
watch_ignored :: proc(root, path: string) -> bool {
	rel := path
	if len(path) > len(root) && strings.has_prefix(path, root) {
		rel = strings.trim_left(path[len(root):], "/\\")
	}

	slashed, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
	if strings.has_prefix(slashed, PROJECT_DIR + "/" + PROJECT_SESSION) do return true

	// Every part but the last
	start := 0
	for i in 0 ..< len(rel) {
		if !is_separator(rel[i]) do continue

		part := rel[start:i]
		if slice.contains(FINDER_IGNORED_DIRS[:], part) do return true
		start = i + 1
	}
	return false
}


// --- Gathering events --------------------------------------------------------------

// Adds an event to the burst
pending_add :: proc(p: ^Watch_Pending, root: string, e: Watch_Event, now: time.Tick) {
	if watch_ignored(root, e.path) do return

	key := path_key(e.path)
	if key in p.paths {
		delete(key)
	} else {
		p.paths[key] = {}
	}

	// Anything but a write changes its folder's entries
	if e.action != .Modified {
		parent := parent_dir(e.path)
		parent_key := path_key(parent)
		if parent_key in p.dirs {
			delete(parent_key)
		} else {
			p.dirs[parent_key] = strings.clone(parent)
		}
		p.structure = true
	}

	pending_touch(p, now)
}


// Notes that something happened now
pending_touch :: proc(p: ^Watch_Pending, now: time.Tick) {
	if p.count == 0 do p.first = now
	p.last = now
	p.count += 1
}


// When the burst is to be handed over: once quiet, or once it went on too long.
// Ok is false with nothing gathered
pending_due_at :: proc(p: ^Watch_Pending) -> (at: time.Tick, ok: bool) {
	if p.count == 0 do return {}, false

	quiet := time.tick_add(p.last, WATCH_QUIET)
	longest := time.tick_add(p.first, WATCH_MAX_DELAY)
	return tick_min(quiet, longest), true
}


// Whether the burst changed `key` or a folder it is in
pending_touches :: proc(p: ^Watch_Pending, key: string) -> bool {
	if key in p.paths do return true

	for i := len(key) - 1; i > 0; i -= 1 {
		if is_separator(key[i]) && key[:i] in p.paths {
			return true
		}
	}
	return false
}


pending_reset :: proc(p: ^Watch_Pending) {
	for key, dir in p.dirs {
		delete(key)
		delete(dir)
	}
	delete(p.dirs)
	for key in p.paths do delete(key)
	delete(p.paths)
	p^ = {}
}


@(private = "file")
tick_min :: proc(a, b: time.Tick) -> time.Tick {
	return time.tick_diff(a, b) > 0 ? a : b
}


// --- Watcher thread ----------------------------------------------------------------

@(private = "file")
watch_thread_proc :: proc() {
	t: Watch_Thread
	t.root_gen = -1
	defer {
		platform_close(&watch.platform)
		pending_reset(&t.pending)
		for c in t.checks do check_destroy(c)
		delete(t.checks)
		delete(t.events)
		delete(t.root)
	}

	for {
		defer free_all(context.temp_allocator)

		// What the UI thread asked for
		jobs: []Reload_Job
		opened: []string
		root_changed := false
		if sync.guard(&watch.mutex) {
			if watch.stop do return

			if watch.root_gen != t.root_gen {
				delete(t.root)
				t.root = strings.clone(watch.root)
				t.root_gen = watch.root_gen
				root_changed = true
			}
			jobs = slice.clone(watch.jobs[:], context.temp_allocator)
			clear(&watch.jobs)
			opened = slice.clone(watch.opened[:], context.temp_allocator)
			clear(&watch.opened)
		}

		if root_changed {
			platform_close(&watch.platform)
			pending_reset(&t.pending)
			t.watching = t.root != "" && platform_open(&watch.platform, t.root)
		}
		for job in jobs do run_job(job)
		look_at_opened(&t, opened)

		// Wait for notifications, or the next thing due
		clear(&t.events)
		timeout := next_wait(&t)
		overflow := platform_wait(&watch.platform, t.root, timeout, &t.events)
		t.watching = t.watching && platform_active(&watch.platform)

		now := time.tick_now()
		for e in t.events do pending_add(&t.pending, t.root, e, now)
		if overflow {
			t.pending.overflow = true
			t.pending.structure = true
			pending_touch(&t.pending, now)
		}

		// Hand over a settled burst; look at files
		if at, ok := pending_due_at(&t.pending); ok && time.tick_diff(at, now) >= 0 {
			hand_over_burst(&t, now)
		}
		if time.tick_diff(t.next_poll, now) >= 0 {
			poll_files(&t, now)
			t.next_poll = time.tick_add(now, WATCH_POLL)
		}
		run_checks(&t, now)
	}
}


// How long to wait for notifications before something is due
@(private = "file")
next_wait :: proc(t: ^Watch_Thread) -> time.Duration {
	now := time.tick_now()
	at := t.next_poll
	if due, ok := pending_due_at(&t.pending); ok {
		at = tick_min(at, due)
	}
	for c in t.checks {
		at = tick_min(at, c.due)
	}
	return max(time.tick_diff(now, at), 0)
}


// Lists the tree's folders the burst changed, and looks at the open files it
// may have changed
@(private = "file")
hand_over_burst :: proc(t: ^Watch_Thread, now: time.Tick) {
	p := &t.pending

	// What is affected, copied out so no lock is held while reading folders
	dirs := make([dynamic]string, context.temp_allocator)
	if sync.guard(&watch.mutex) {
		for key, dir in watch.dirs {
			if p.overflow || key in p.dirs {
				append(&dirs, strings.clone(dir, context.temp_allocator))
			}
		}
		for key, f in watch.files {
			if p.overflow || pending_touches(p, key) {
				add_check(t, key, f.path, now)
			}
		}
	}

	// The folders' entries, as the tree shows them
	listings := make([dynamic]Folder_Listing)
	for dir in dirs {
		if l, ok := folder_listing_read(dir); ok {
			append(&listings, l)
		}
	}

	hand_over(Watch_Batch{listings[:], p.structure})
	pending_reset(p)
}


// Looks at open files no notification covers: outside the root, or all of them
// when the root isn't watched
@(private = "file")
poll_files :: proc(t: ^Watch_Thread, now: time.Tick) {
	root_key := path_key(t.root, context.temp_allocator)
	candidates := make([dynamic]Poll_Candidate, context.temp_allocator)
	if sync.guard(&watch.mutex) {
		for key, f in watch.files {
			covered := t.watching && under_root(key, root_key)
			if covered do continue

			c := Poll_Candidate {
				key     = strings.clone(key, context.temp_allocator),
				path    = strings.clone(f.path, context.temp_allocator),
				known   = f.stamp,
				seen    = f.seen,
				missing = f.missing,
			}
			append(&candidates, c)
		}
	}

	look_at(t, candidates[:], now)
}


// Looks at files just registered (taking their keys): a change made while one
// was read, before the watcher knew it, may have had no notification since
@(private = "file")
look_at_opened :: proc(t: ^Watch_Thread, keys: []string) {
	if len(keys) == 0 do return

	candidates := make([dynamic]Poll_Candidate, context.temp_allocator)
	if sync.guard(&watch.mutex) {
		for key in keys {
			f, found := watch.files[key]
			if !found do continue

			c := Poll_Candidate {
				key     = strings.clone(key, context.temp_allocator),
				path    = strings.clone(f.path, context.temp_allocator),
				known   = f.stamp,
				seen    = f.seen,
				missing = f.missing,
			}
			append(&candidates, c)
		}
	}
	for key in keys do delete(key)

	look_at(t, candidates[:], time.tick_now())
}


// Schedules a check of each file that came, went, or isn't the version known
@(private = "file")
look_at :: proc(t: ^Watch_Thread, candidates: []Poll_Candidate, now: time.Tick) {
	for c in candidates {
		stamp, exists := file_stamp(c.path)
		came_or_went := exists == c.missing
		rewritten := exists && stamp != c.known && stamp != c.seen
		if came_or_went || rewritten {
			add_check(t, c.key, c.path, now)
		}
	}
}


// Whether a path is inside the root, which may be a drive root ("C:\")
@(private = "file")
under_root :: proc(path, root: string) -> bool {
	if root == "" do return false
	if is_separator(root[len(root) - 1]) do return strings.has_prefix(path, root)
	return path_within(path, root)
}


// An open file poll_files looks at, copied out of the registry
@(private = "file")
Poll_Candidate :: struct {
	key, path: string,
	known:     File_Stamp,
	seen:      File_Stamp,
	missing:   bool,
}


// Schedules a look at an open file, or starts the one under way again
@(private = "file")
add_check :: proc(t: ^Watch_Thread, key, path: string, now: time.Tick) {
	for &c in t.checks {
		if c.key != key do continue

		c.looks = 0
		c.due = now
		return
	}

	check := File_Check {
		key     = strings.clone(key),
		path    = strings.clone(path),
		due     = now,
		started = now,
	}
	append(&t.checks, check)
}


@(private = "file")
check_destroy :: proc(c: File_Check) {
	delete(c.key)
	delete(c.path)
}


@(private = "file")
run_checks :: proc(t: ^Watch_Thread, now: time.Tick) {
	for i := len(t.checks) - 1; i >= 0; i -= 1 {
		c := &t.checks[i]
		if time.tick_diff(c.due, now) < 0 do continue

		if check_file(c, now) {
			check_destroy(c^)
			unordered_remove(&t.checks, i)
		}
	}
}


// One look at an open file: hands over a new version once it holds still, or
// that it is gone. Returns true when done
@(private = "file")
check_file :: proc(c: ^File_Check, now: time.Tick) -> bool {
	// What typo has of it
	f: Watched_File
	registered: bool
	if sync.guard(&watch.mutex) {
		f, registered = watch.files[c.key]
	}
	if !registered do return true

	// Gone: unless it comes back soon, as when an editor replaces it
	stamp, exists := file_stamp(c.path)
	if !exists {
		if f.missing do return true
		if !c.absent {
			c.absent = true
			c.due = time.tick_add(now, WATCH_MISSING)
			return false
		}
		hand_over_missing(c)
		return true
	}
	c.absent = false

	// Unchanged since typo read or wrote it, or since it was handed over
	if !f.missing && (stamp == f.stamp || stamp == f.seen) {
		return true
	}

	// Wait until it holds still, unless it never does
	settled := c.looks > 0 && stamp == c.stamp
	if !settled && time.tick_diff(c.started, now) < WATCH_SETTLE_MAX {
		c.stamp = stamp
		c.looks += 1
		c.due = time.tick_add(now, WATCH_STABLE)
		return false
	}

	// Read it, waiting while another program holds it
	data, err := read_file_shared(c.path)
	switch err {
	case .None:
	case .Missing:
		c.looks = 0
		c.due = now
		return false
	case .Busy:
		c.busy += 1
		if time.tick_diff(c.started, now) > WATCH_BUSY_MAX do return true

		backoff := min(WATCH_STABLE << uint(min(c.busy, 5)), time.Second)
		c.due = time.tick_add(now, backoff)
		return false
	case .Failed:
		return true
	}

	// Written to while it was read
	after, _ := file_stamp(c.path)
	if after != stamp {
		delete(data)
		c.stamp = after
		c.looks = 1
		c.due = time.tick_add(now, WATCH_STABLE)
		return false
	}

	hand_over_version(c, Disk_Version{data, file_hash(data), stamp})
	return true
}


// Hands over a version of an open file, unless it is typo's own text
@(private = "file")
hand_over_version :: proc(c: ^File_Check, v: Disk_Version) {
	sync.guard(&watch.mutex)

	f, registered := &watch.files[c.key]
	if !registered || (v.hash == f.hash && !f.missing) {
		if registered do f.stamp = v.stamp
		delete(v.data)
		return
	}

	same := v.hash == f.hash
	if same do f.stamp = v.stamp
	f.seen = v.stamp
	f.missing = false

	changed := File_Changed {
		path       = strings.clone(f.path),
		generation = f.generation,
		version    = v,
		same       = same,
	}
	hand_over_locked(changed)
}


@(private = "file")
hand_over_missing :: proc(c: ^File_Check) {
	sync.guard(&watch.mutex)

	f, registered := &watch.files[c.key]
	if !registered do return

	f.missing = true
	f.seen = {}
	hand_over_locked(File_Missing{strings.clone(f.path), f.generation})
}


// Diffs a new version against the editor's text
@(private = "file")
run_job :: proc(job: Reload_Job) {
	job := job
	old := buffer.snapshot_read_alloc(&job.old, 0, job.old.length, context.allocator)
	defer delete(old)

	ready := Reload_Ready {
		path           = job.path,
		serial         = job.serial,
		buffer_version = job.old.version,
		version        = job.version,
		hunks          = diff.lines(old, job.version.data),
	}
	buffer.snapshot_release(&job.old)
	hand_over(ready)
}


@(private = "file")
hand_over :: proc(r: Watch_Result) {
	sync.guard(&watch.mutex)
	hand_over_locked(r)
}


@(private = "file")
hand_over_locked :: proc(r: Watch_Result) {
	append(&watch.results, r)
	wake_main_loop(nil)
}
