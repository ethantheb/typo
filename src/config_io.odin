package editor

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import sdl "../vendor/sdl3"

// The settings files and the projects' state are read and written on one
// thread, the config thread, in the order asked, so a read after a write sees
// it; a write still waiting is replaced by a newer one to the same file.
// Finished results wait for the UI thread (config_frame). A timer on SDL's
// timer thread looks at the watched files' write times (the user's
// settings.toml, the project's .typo/settings.toml) and has a file read again
// when it changed, but not after the thread's own writes, so an idle editor
// isn't woken just to look. A read that typo's own write to the file overtook
// is dropped: that write replaces what was read.
//
// Without the thread (unit tests that don't start it) a job runs at once on
// the calling thread, which applies its result


CONFIG_POLL_MS :: 500

// The files whose changes on disk are read again
Watched_File :: enum {
	User_Settings,
	Project_Settings,
}

// Writes a file in place of the one there (a temp file, then a rename)
Config_Write :: struct {
	path:     string, // owned
	text:     string, // owned
	watched:  Maybe(Watched_File), // its new write time isn't a change
	typo_dir: bool,   // in a project's .typo folder: made, with its .gitignore, if missing
	open:     bool,   // opened in an editor once written
}

// Reads a watched settings file
Config_Read :: struct {
	file:   Watched_File,
	path:   string, // owned
	writes: u64,    // the file's Watch.writes when asked: a write since makes it stale
}

// Reads a project's settings and its last state
Config_Read_Project :: struct {
	root:   string, // owned
	serial: u64,
}

Config_Job :: union {
	Config_Write,
	Config_Read,
	Config_Read_Project,
}

Settings_Read :: struct {
	file:   Watched_File,
	path:   string, // owned
	writes: u64,
	loaded: Loaded_Settings,
}

// A project's files, read
Project_Read :: struct {
	root:           string,         // owned
	serial:         u64,
	settings:       Loaded_Settings,
	settings_mtime: time.Time,      // its settings file's write time as read
	session:        Maybe(Session), // in `arena`; none without a readable session.json
	arena:          ^virtual.Arena, // owned
	has_dir:        bool,           // it has a .typo folder
}

Config_Written :: struct {
	path:     string, // owned
	ok:       bool,
	typo_dir: bool, // it went in a project's .typo folder
	open:     bool,
}

Config_Result :: union {
	Settings_Read,
	Project_Read,
	Config_Written,
}

@(private = "file")
Watch :: struct {
	path:    string,    // owned; "" while not watched
	mtime:   time.Time, // as last read, written or seen
	writing: int,       // writes to it waiting or under way: its time isn't looked at
	writes:  u64,       // writes to it asked for, ever
}

@(private = "file")
config: struct {
	running:   bool, // UI thread only
	worker:    ^thread.Thread,
	timer:     sdl.TimerID,
	allocator: runtime.Allocator, // the app's: the timer's jobs are freed with it

	// Shared, under the mutex
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	stop:    bool,
	jobs:    [dynamic]Config_Job,
	results: [dynamic]Config_Result,
	watched: [Watched_File]Watch,
}


// --- UI thread ---------------------------------------------------------------------

// Starts the config thread and the watch timer, which run until config_destroy
config_init :: proc() {
	if config.running do return
	config.running = true

	ctx := runtime.default_context()
	ctx.allocator = context.allocator
	config.allocator = context.allocator
	config.worker = thread.create_and_start(config_proc, ctx)
	config.timer = sdl.AddTimer(CONFIG_POLL_MS, watch_callback, nil)
}


// Stops the timer and the thread, once every job asked for is done
config_destroy :: proc() {
	if config.running {
		_ = sdl.RemoveTimer(config.timer)
		if sync.guard(&config.mutex) {
			config.stop = true
		}
		sync.cond_signal(&config.cond)
		thread.join(config.worker)
		thread.destroy(config.worker)
	}

	for &job in config.jobs do job_destroy(&job)
	delete(config.jobs)
	for &r in config.results do config_result_destroy(&r)
	delete(config.results)
	for w in config.watched do delete(w.path)
	config = {}
}


// Queues a job (taking it); without the thread it runs at once and its result
// applies. A write replaces one to the same file still waiting
config_post :: proc(job: Config_Job) {
	job := job
	write, is_write := job.(Config_Write)
	if is_write do note_write(write.watched)

	if !config.running {
		result := run_job(&job)
		config_apply(&result)
		return
	}

	if sync.guard(&config.mutex) {
		replaced := is_write && replace_waiting_write(write)
		if !replaced do append(&config.jobs, job)
	}
	sync.cond_signal(&config.cond)
}


// Watches a settings file for changes made by others, from its write time as
// last read; "" stops watching it
config_watch :: proc(file: Watched_File, path: string, mtime: time.Time) {
	sync.guard(&config.mutex)
	w := &config.watched[file]
	delete(w.path)
	w.path = strings.clone(path)
	w.mtime = mtime
}


// Takes the results handed over since the last call (the caller owns them),
// in the temp allocator
config_take :: proc() -> []Config_Result {
	sync.guard(&config.mutex)
	results := make([]Config_Result, len(config.results), context.temp_allocator)
	copy(results, config.results[:])
	clear(&config.results)
	return results
}


// Per frame: applies what the config thread read and wrote
config_frame :: proc() {
	for &r in config_take() do config_apply(&r)
}


// Applies a result (taking it): a settings file read again, a project's files
// read, a file written
@(private = "file")
config_apply :: proc(r: ^Config_Result) {
	switch &x in r {
	case Settings_Read:
		if current(x.file, x.path, x.writes) {
			settings_file_read(x.file, &x.loaded)
		}
	case Project_Read:
		project_read(&x)
	case Config_Written:
		project_written(x)
	}
	config_result_destroy(r)
}


config_result_destroy :: proc(r: ^Config_Result) {
	switch &x in r {
	case Settings_Read:
		delete(x.path)
		loaded_settings_destroy(&x.loaded)
	case Project_Read:
		delete(x.root)
		loaded_settings_destroy(&x.settings)
		if x.arena != nil {
			virtual.arena_destroy(x.arena)
			free(x.arena)
		}
	case Config_Written:
		delete(x.path)
	}
	r^ = nil
}


// Whether a read of a watched file still holds: the file is still watched as
// `path` (not a project left since), and typo hasn't asked to write it since
// (its write replaces what was read)
@(private = "file")
current :: proc(file: Watched_File, path: string, writes: u64) -> bool {
	sync.guard(&config.mutex)
	w := config.watched[file]
	return w.path == path && w.writes == writes
}


// A write to a watched file was asked for
@(private = "file")
note_write :: proc(file: Maybe(Watched_File)) {
	f, ok := file.?
	if !ok do return

	sync.guard(&config.mutex)
	config.watched[f].writing += 1
	config.watched[f].writes += 1
}


// Puts a write's text in place of a waiting write's to the same file (taking
// the new write); false if none waits. Under the mutex
@(private = "file")
replace_waiting_write :: proc(new_write: Config_Write) -> bool {
	for &waiting in config.jobs {
		w, is_write := &waiting.(Config_Write)
		if !is_write || w.path != new_write.path || w.typo_dir != new_write.typo_dir {
			continue
		}

		delete(w.text)
		w.text = new_write.text
		w.open ||= new_write.open
		delete(new_write.path)

		// Counted once, for the waiting one
		if file, watched := new_write.watched.?; watched {
			config.watched[file].writing -= 1
		}
		return true
	}
	return false
}


@(private = "file")
job_destroy :: proc(job: ^Config_Job) {
	switch &x in job {
	case Config_Write:
		delete(x.path)
		delete(x.text)
	case Config_Read:
		delete(x.path)
	case Config_Read_Project:
		delete(x.root)
	}
	job^ = nil
}


// --- Config thread -----------------------------------------------------------------

@(private = "file")
config_proc :: proc() {
	for {
		job, ok := next_job()
		if !ok do return

		result := run_job(&job)
		if sync.guard(&config.mutex) {
			append(&config.results, result)
		}
		wake_main_loop(nil)
		free_all(context.temp_allocator)
	}
}


// Waits for a job; false once stopping with none left
@(private = "file")
next_job :: proc() -> (job: Config_Job, ok: bool) {
	sync.guard(&config.mutex)
	for !config.stop && len(config.jobs) == 0 {
		sync.cond_wait(&config.cond, &config.mutex)
	}
	if len(config.jobs) == 0 do return

	job = config.jobs[0]
	ordered_remove(&config.jobs, 0)
	return job, true
}


// Does a job (taking it)
@(private = "file")
run_job :: proc(job: ^Config_Job) -> (result: Config_Result) {
	defer job_destroy(job)

	switch x in job {
	case Config_Write:
		result = write_config(x)

	case Config_Read:
		mtime, err := os.last_write_time_by_name(x.path)
		if err != nil do mtime = {}
		loaded := settings_read_file(x.path, x.file == .User_Settings ? .User : .Project)
		seen(x.file, x.path, mtime)
		result = Settings_Read{x.file, strings.clone(x.path), x.writes, loaded}

	case Config_Read_Project:
		result = read_project(x.root, x.serial)
	}
	return
}


// Writes a file; one in a project's .typo folder makes the folder first if
// there is none, with a .gitignore keeping the personal state out of git
@(private = "file")
write_config :: proc(job: Config_Write) -> Config_Written {
	if job.typo_dir {
		dir := filepath.dir(job.path)
		if !os.is_dir(dir) {
			_ = os.make_directory_all(dir)
			ignore := filepath.join({dir, ".gitignore"}, context.temp_allocator) or_else ""
			_ = os.write_entire_file(ignore, transmute([]u8)string(TYPO_GITIGNORE))
		}
	}

	mtime, ok := write_file_atomic(job.path, job.text)

	// Its own write isn't a change for the watcher to report
	if file, watched := job.watched.?; watched {
		sync.guard(&config.mutex)
		w := &config.watched[file]
		if ok && w.path == job.path {
			w.mtime = mtime
		}
		w.writing -= 1
	}

	return {path = strings.clone(job.path), ok = ok, typo_dir = job.typo_dir, open = job.open}
}


// What a new .typo folder's .gitignore says: the personal state stays out,
// the settings are shared
TYPO_GITIGNORE :: "session.json\n"


// Reads a project's .typo/settings.toml and .typo/session.json
@(private = "file")
read_project :: proc(root: string, serial: u64) -> (r: Project_Read) {
	r.root = strings.clone(root)
	r.serial = serial
	r.has_dir = os.is_dir(project_file(root, ""))

	settings_path := project_file(root, PROJECT_SETTINGS)
	mtime, err := os.last_write_time_by_name(settings_path)
	if err == nil do r.settings_mtime = mtime
	r.settings = settings_read_file(settings_path, .Project)

	// The session, in an arena of its own that goes with the result
	session_path := project_file(root, PROJECT_SESSION)
	data, read_err := os.read_entire_file(session_path, context.temp_allocator)
	if read_err != nil do return

	r.arena = new(virtual.Arena)
	if virtual.arena_init_growing(r.arena) != nil {
		free(r.arena)
		r.arena = nil
		return
	}
	if s, ok := session_parse(data, virtual.arena_allocator(r.arena)); ok {
		session_mark_gone(&s, root)
		r.session = s
	}
	return
}


// A watched file was read at `mtime`: that isn't a change
@(private = "file")
seen :: proc(file: Watched_File, path: string, mtime: time.Time) {
	sync.guard(&config.mutex)
	w := &config.watched[file]
	if w.path == path do w.mtime = mtime
}


// --- Watch timer -------------------------------------------------------------------

// On SDL's timer thread: has each watched file whose write time changed read
// again, unless typo is writing it. A file deleted, or made, changes too. The
// times are looked up without the lock, which the UI thread takes every frame:
// a slow disk (a network drive) must not hold it up
@(private = "file")
watch_callback :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	// What to look at
	paths: [Watched_File]string
	if sync.guard(&config.mutex) {
		if config.stop do return 0

		for w, file in config.watched {
			if w.path != "" && w.writing == 0 {
				paths[file] = strings.clone(w.path, context.temp_allocator)
			}
		}
	}

	mtimes: [Watched_File]time.Time
	for path, file in paths {
		if path == "" do continue

		mtime, err := os.last_write_time_by_name(path)
		mtimes[file] = err == nil ? mtime : {} // {} when gone
	}

	// Read again what changed, if it is still watched and not being written
	sync.guard(&config.mutex)
	for &w, file in config.watched {
		changed := paths[file] != "" && mtimes[file] != w.mtime
		if !changed || w.path != paths[file] || w.writing > 0 {
			continue
		}

		w.mtime = mtimes[file]
		read := Config_Read{file, strings.clone(w.path, config.allocator), w.writes}
		append(&config.jobs, read)
		sync.cond_signal(&config.cond)
	}
	return interval
}
