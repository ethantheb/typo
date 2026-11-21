package editor

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "buffer"
import "syntax"

// Reading files to open and writing files to save, off the UI thread. Loads go
// to a small pool of loader threads sharing one queue, so one huge file doesn't
// hold up the small ones opened after it; writes go to one writer thread, in
// the order they were asked for, so two saves of a file land in that order.
// Finished results wait for the UI thread (io_take), which wires them up
// (file_load.odin).
//
// Without the threads (unit tests that don't start them) a job runs at once on
// the calling thread, which gets its result back directly


LOAD_THREADS :: 2

// Asks for a file to be read and made into a document
Load_Job :: struct {
	id:        u64,    // the editor's load (Load_State.id)
	path:      string, // owned
	ask_above: i64,    // a larger file is measured but not read; 0 reads any size
}

Load_Status :: enum {
	Text,      // read, and its buffer and highlighter built
	New_File,  // doesn't exist: opens empty, created on first save
	Binary,
	Error,
	Too_Large, // above the job's ask_above: not read
}

// A file read for an editor
Load_Result :: struct {
	id:     u64,
	status: Load_Status,
	size:   i64,
	stamp:  File_Stamp,         // the file's before it was read
	hash:   u64,                // of the text read
	buf:    buffer.Buffer,      // Text, New_File: owned, newline index built
	hl:     syntax.Highlighter, // Text, New_File: owned, tree-sitter's first parse done
}

// A file's size, known before it is read (for the loading message)
Load_Sized :: struct {
	id:   u64,
	size: i64,
}

// Asks for a snapshot of a buffer to be written to its file
Write_Job :: struct {
	id:        u64,
	path:      string,          // owned; what the watcher knows the file by too
	text:      buffer.Snapshot, // owned
	make_dirs: bool,            // create the folders it goes in (a new or deleted file)
}

Write_Result :: struct {
	id:         u64,
	path:       string, // owned
	ok:         bool,
	hash:       u64,        // of what was written
	stamp:      File_Stamp, // the file's after the write
	generation: u32,        // the watcher's, told of the write before this was handed over
	problem:    string,     // owned; why it failed
}

IO_Result :: union {
	Load_Result,
	Load_Sized,
	Write_Result,
}

@(private = "file")
io: struct {
	running:    bool, // UI thread only
	loaders:    [LOAD_THREADS]^thread.Thread,
	writer:     ^thread.Thread,

	// Shared, under the mutex
	mutex:      sync.Mutex,
	load_cond:  sync.Cond,
	write_cond: sync.Cond,
	stop:       bool,
	loads:      [dynamic]Load_Job,  // waiting
	loading:    [dynamic]u64,       // loads under way
	cancelled:  [dynamic]u64,       // of those, ones nobody waits for anymore
	writes:     [dynamic]Write_Job, // waiting
	writing:    int,                // writes waiting or under way
	results:    [dynamic]IO_Result,
}


// --- UI thread ---------------------------------------------------------------------

// Starts the loader and writer threads, which run until io_destroy
io_init :: proc() {
	if io.running do return
	io.running = true

	ctx := runtime.default_context()
	ctx.allocator = context.allocator
	for &t in io.loaders {
		t = thread.create_and_start(loader_proc, ctx)
	}
	io.writer = thread.create_and_start(writer_proc, ctx)
}


// Stops the threads: loads not started are dropped, writes are all finished
// first
io_destroy :: proc() {
	if !io.running do return

	if sync.guard(&io.mutex) {
		io.stop = true
	}
	sync.cond_broadcast(&io.load_cond)
	sync.cond_broadcast(&io.write_cond)
	for t in io.loaders {
		thread.join(t)
		thread.destroy(t)
	}
	thread.join(io.writer)
	thread.destroy(io.writer)

	// What was left
	for job in io.loads do delete(job.path)
	delete(io.loads)
	delete(io.loading)
	delete(io.cancelled)
	delete(io.writes)
	for r in io.results do io_result_destroy(r)
	delete(io.results)

	io = {}
}


io_running :: proc() -> bool {
	return io.running
}


// Queues a load (taking the job). Without the threads it runs at once: `done`,
// with its result
io_post_load :: proc(job: Load_Job) -> (r: Load_Result, done: bool) {
	if !io.running {
		r, _ = load_file(job, report = false)
		delete(job.path)
		return r, true
	}

	if sync.guard(&io.mutex) {
		append(&io.loads, job)
	}
	sync.cond_signal(&io.load_cond)
	return
}


// Nobody waits for the load anymore: a waiting one is dropped, one under way
// stops at its next step and its result is freed
io_cancel_load :: proc(id: u64) {
	if !io.running do return

	sync.guard(&io.mutex)
	for job, i in io.loads {
		if job.id == id {
			delete(job.path)
			ordered_remove(&io.loads, i)
			return
		}
	}
	if slice.contains(io.loading[:], id) {
		append(&io.cancelled, id)
	}
}


// Queues a write (taking the job). Without the threads it runs at once: `done`,
// with its result
io_post_write :: proc(job: Write_Job) -> (r: Write_Result, done: bool) {
	if !io.running {
		job := job
		r = write_file(&job)
		write_job_destroy(&job)
		return r, true
	}

	if sync.guard(&io.mutex) {
		append(&io.writes, job)
		io.writing += 1
	}
	sync.cond_signal(&io.write_cond)
	return
}


// Whether writes are waiting or under way
io_writing :: proc() -> bool {
	if !io.running do return false

	sync.guard(&io.mutex)
	return io.writing > 0
}


// Whether every load asked for has finished: its result waits, or was taken
io_loads_done :: proc() -> bool {
	sync.guard(&io.mutex)
	return len(io.loads) == 0 && len(io.loading) == 0
}


// Takes the results handed over since the last call (the caller owns them),
// in the temp allocator
io_take :: proc() -> []IO_Result {
	if !io.running do return nil

	sync.guard(&io.mutex)
	results := slice.clone(io.results[:], context.temp_allocator)
	clear(&io.results)
	return results
}


io_result_destroy :: proc(r: IO_Result) {
	r := r
	switch &r in r {
	case Load_Result:
		load_result_destroy(&r)
	case Load_Sized:
	case Write_Result:
		delete(r.path)
		delete(r.problem)
	}
}


load_result_destroy :: proc(r: ^Load_Result) {
	if r.status == .Text || r.status == .New_File {
		syntax.highlighter_close(&r.hl)
		buffer.buffer_destroy(&r.buf)
	}
	r^ = {}
}


// --- Loader threads ----------------------------------------------------------------

@(private = "file")
loader_proc :: proc() {
	for {
		job, ok := next_load()
		if !ok do return

		r, done := load_file(job, report = true)
		finish_load(job.id, r, done)
		delete(job.path)
		free_all(context.temp_allocator)
	}
}


// Waits for a load to do; false once stopping
@(private = "file")
next_load :: proc() -> (job: Load_Job, ok: bool) {
	sync.guard(&io.mutex)
	for !io.stop && len(io.loads) == 0 {
		sync.cond_wait(&io.load_cond, &io.mutex)
	}
	if io.stop do return

	job = io.loads[0]
	ordered_remove(&io.loads, 0)
	append(&io.loading, job.id)
	return job, true
}


// Hands the result over, unless the load was cancelled meanwhile
@(private = "file")
finish_load :: proc(id: u64, r: Load_Result, done: bool) {
	r := r
	cancelled := false

	if sync.guard(&io.mutex) {
		remove_id(&io.loading, id)
		cancelled = remove_id(&io.cancelled, id)
		if done && !cancelled {
			append(&io.results, r)
		}
	}

	if !done do return

	if cancelled {
		load_result_destroy(&r)
	} else {
		wake_main_loop(nil)
	}
}


@(private = "file")
load_cancelled :: proc(id: u64) -> bool {
	sync.guard(&io.mutex)
	return slice.contains(io.cancelled[:], id)
}


@(private = "file")
remove_id :: proc(ids: ^[dynamic]u64, id: u64) -> bool {
	i, found := slice.linear_search(ids[:], id)
	if found do unordered_remove(ids, i)
	return found
}


// Reads a file and makes its document: the buffer with its newline index, and
// the highlighter with tree-sitter's first parse. `report` hands the file's
// size over first and stops early once the load is cancelled (on the loader
// threads); `done` is false then, with nothing owned
@(private = "file")
load_file :: proc(job: Load_Job, report: bool) -> (r: Load_Result, done: bool) {
	r.id = job.id

	// A path that doesn't exist opens as an empty, new file
	stamp, exists := file_stamp(job.path)
	if !exists {
		r.status = .New_File
		r.hash = file_hash(nil)
		buffer.buffer_init(&r.buf, nil)
		syntax.highlighter_open(&r.hl, &r.buf, job.path)
		return r, true
	}

	// Its size first: a large file waits for the user before it is read
	r.stamp, r.size = stamp, stamp.size
	if job.ask_above > 0 && stamp.size > job.ask_above {
		r.status = .Too_Large
		return r, true
	}
	if report {
		post_result(Load_Sized{job.id, stamp.size})
		if load_cancelled(job.id) do return {}, false
	}

	// The text. Anything with a NUL byte in its first 8 KB is binary
	data, err := read_file_shared(job.path)
	if err != .None {
		r.status = .Error
		return r, true
	}
	if slice.contains(data[:min(len(data), 8192)], 0) {
		delete(data)
		r.status = .Binary
		return r, true
	}
	if report && load_cancelled(job.id) {
		delete(data)
		return {}, false
	}

	// The document
	r.hash = file_hash(data)
	buffer.buffer_init(&r.buf, data)
	syntax.highlighter_open(&r.hl, &r.buf, job.path)
	r.status = .Text
	return r, true
}


@(private = "file")
post_result :: proc(r: IO_Result) {
	if sync.guard(&io.mutex) {
		append(&io.results, r)
	}
	wake_main_loop(nil)
}


// --- Writer thread -----------------------------------------------------------------

@(private = "file")
writer_proc :: proc() {
	for {
		job, ok := next_write()
		if !ok do return

		r := write_file(&job)
		write_job_destroy(&job)
		if sync.guard(&io.mutex) {
			append(&io.results, r)
			io.writing -= 1
		}
		wake_main_loop(nil)
		free_all(context.temp_allocator)
	}
}


// Waits for a write to do; false once stopping with none left
@(private = "file")
next_write :: proc() -> (job: Write_Job, ok: bool) {
	sync.guard(&io.mutex)
	for !io.stop && len(io.writes) == 0 {
		sync.cond_wait(&io.write_cond, &io.mutex)
	}
	if len(io.writes) == 0 do return

	job = io.writes[0]
	ordered_remove(&io.writes, 0)
	return job, true
}


// Writes to a temporary file and renames it over the original, so a failed
// write never leaves a half-written file. The watcher is told what was written
// before the result is handed over, so it never takes the write for a change
@(private = "file")
write_file :: proc(job: ^Write_Job) -> (r: Write_Result) {
	r.id = job.id
	r.path = strings.clone(job.path)
	if job.make_dirs {
		_ = os.make_directory_all(os.dir(job.path))
	}

	// The temporary file, hashing what is written
	tmp := strings.concatenate({job.path, ".typo.tmp"}, context.temp_allocator)
	f, err := os.create(tmp)
	if err != nil {
		r.problem = fmt.aprintf("it can't be created (%s)", os.error_string(err))
		return
	}

	hasher, _ := xxhash.XXH3_create_state(context.temp_allocator)
	for span in job.text.spans {
		if _, werr := os.write(f, span.text); werr != nil {
			os.close(f)
			os.remove(tmp)
			r.problem = fmt.aprintf("writing it failed (%s)", os.error_string(werr))
			return
		}
		xxhash.XXH3_64_update(hasher, span.text)
	}
	os.close(f)

	// In place of the original
	if rerr := os.rename(tmp, job.path); rerr != nil {
		os.remove(tmp)
		r.problem = fmt.aprintf("it can't be replaced (%s)", os.error_string(rerr))
		return
	}

	r.ok = true
	r.hash = xxhash.XXH3_64_digest(hasher)
	r.stamp, _ = file_stamp(job.path)
	r.generation = watch_file_synced(job.path, r.hash, r.stamp)
	return
}


@(private = "file")
write_job_destroy :: proc(job: ^Write_Job) {
	delete(job.path)
	buffer.snapshot_release(&job.text)
	job^ = {}
}
