package editor

// The diff views' loader: a thread that reads the two versions a diff view
// compares (from git, an open editor's snapshot or the file on disk), diffs
// them, finds the words that changed within changed lines, and builds each
// side's buffer and highlighter. The UI thread posts a job per view
// (diff_load_post; a newer job for the same view replaces one still waiting)
// and takes finished results (diff_load_take). A job carries what its view
// shows (Diff_Signature): when nothing changed, the result says so without
// reading or diffing anything

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

import "buffer"
import "diff"
import "git"
import "syntax"


// Words are looked for in changed lines no longer than this, in at most this
// many pairs of lines; past them, changed lines are only shaded
WORD_LINE_MAX :: 1000
WORD_PAIRS_MAX :: 20_000

// Bytes looked at for a NUL that makes a file binary
BINARY_SNIFF :: 8000

// Where a side's text comes from
Diff_Source :: enum u8 {
	None,      // the version has no such file (an untracked file's old side)
	Head,
	Index,
	Work_Tree, // the file on disk
	Editor,    // the open editor's text
	Before,    // the file in a commit's parent
	Commit,    // the file in a commit
}

// What a diff view shows, to tell whether a new load would change it
Diff_Signature :: struct {
	left:          Diff_Source,
	right:         Diff_Source,
	left_id:       git.Oid,    // a git side's blob
	right_id:      git.Oid,
	right_stamp:   File_Stamp, // the file on disk's
	right_version: u64,        // the editor's buffer version
	left_found:    bool,
	right_found:   bool,
}

// What changed within a changed line: bytes [lo, hi) of a side's line
Word_Span :: struct {
	line:   int,
	lo, hi: int,
}

// One side of a diff
Diff_Side :: struct {
	buf:    buffer.Buffer,      // owned
	hl:     syntax.Highlighter, // owned
	exists: bool,               // the version has the file
}

Diff_Job :: struct {
	view:    u64, // the diff view's id
	serial:  u64, // its load
	workdir: string, // owned
	rel:     string, // owned; the file, relative to the work tree
	path:    string, // owned; its full path
	area:    git.Area,
	commit:  Maybe(git.Oid),         // a commit's change instead of the area's
	from:    string,                 // owned; where the commit's parent has it, if renamed
	editor:  Maybe(buffer.Snapshot), // owned; the open editor's text
	known:   Maybe(Diff_Signature),  // what the view shows now
}

Diff_Load_Status :: enum u8 {
	Ready,
	Unchanged, // as the view shows it
	Binary,
	Error,
}

Diff_Result :: struct {
	view:       u64,
	serial:     u64,
	status:     Diff_Load_Status,
	problem:    string, // owned; why it failed
	signature:  Diff_Signature,
	left:       Diff_Side,
	right:      Diff_Side,
	rows:       diff.Rows,    // owned
	left_words: []Word_Span, // owned
	right_words: []Word_Span, // owned
	right_size: int, // a file read from disk: its size and hash, which a revert
	right_hash: u64, // written there checks it still has
}

@(private = "file")
loader: struct {
	thread:  ^thread.Thread,
	running: bool, // UI thread only

	// Shared, under the mutex
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	stop:    bool,
	jobs:    [dynamic]Diff_Job,
	working: int, // jobs under way
	results: [dynamic]Diff_Result,
	retired: [dynamic]Diff_Result, // what views showed, to free
}


// --- UI thread ---------------------------------------------------------------------

diff_load_init :: proc() {
	if loader.running do return
	loader.running = true

	ctx := runtime.default_context()
	ctx.allocator = context.allocator
	loader.thread = thread.create_and_start(loader_proc, ctx)
}


diff_load_destroy :: proc() {
	if !loader.running do return

	if sync.guard(&loader.mutex) {
		loader.stop = true
	}
	sync.cond_signal(&loader.cond)
	thread.join(loader.thread)
	thread.destroy(loader.thread)

	for &job in loader.jobs do diff_job_destroy(&job)
	delete(loader.jobs)
	for &r in loader.results do diff_result_destroy(&r)
	delete(loader.results)
	for &r in loader.retired do diff_result_destroy(&r)
	delete(loader.retired)
	loader = {}
}


// Frees what a view showed (taking it) on the loader thread: a large file's
// two texts take the UI thread too long to free. At once without the thread
diff_load_retire :: proc(r: Diff_Result) {
	r := r
	if !loader.running {
		diff_result_destroy(&r)
		return
	}

	if sync.guard(&loader.mutex) {
		append(&loader.retired, r)
	}
	sync.cond_signal(&loader.cond)
}


// Queues a job (taking it), in place of one for the same view still waiting.
// Without the thread (unit tests that don't start it) it runs at once: `done`,
// with its result
diff_load_post :: proc(job: Diff_Job) -> (r: Diff_Result, done: bool) {
	job := job
	if !loader.running {
		r = load_diff(&job)
		diff_job_destroy(&job)
		return r, true
	}

	if sync.guard(&loader.mutex) {
		for i := len(loader.jobs) - 1; i >= 0; i -= 1 {
			if loader.jobs[i].view != job.view do continue
			diff_job_destroy(&loader.jobs[i])
			ordered_remove(&loader.jobs, i)
		}
		append(&loader.jobs, job)
	}
	sync.cond_signal(&loader.cond)
	return
}


// Takes the results handed over since the last call (the caller owns them), in
// the temp allocator
diff_load_take :: proc() -> []Diff_Result {
	if !loader.running do return nil

	sync.guard(&loader.mutex)
	results := slice.clone(loader.results[:], context.temp_allocator)
	clear(&loader.results)
	return results
}


// Whether jobs wait or run (tests and the perf suite wait for them)
diff_load_busy :: proc() -> bool {
	if !loader.running do return false

	sync.guard(&loader.mutex)
	return len(loader.jobs) > 0 || loader.working > 0
}


diff_job_destroy :: proc(job: ^Diff_Job) {
	delete(job.workdir)
	delete(job.rel)
	delete(job.path)
	delete(job.from)
	if snap, ok := &job.editor.?; ok {
		buffer.snapshot_release(snap)
	}
	job^ = {}
}


diff_side_destroy :: proc(s: ^Diff_Side) {
	syntax.highlighter_close(&s.hl)
	buffer.buffer_destroy(&s.buf)
	s^ = {}
}


diff_result_destroy :: proc(r: ^Diff_Result) {
	delete(r.problem)
	diff_side_destroy(&r.left)
	diff_side_destroy(&r.right)
	diff.rows_destroy(&r.rows)
	delete(r.left_words)
	delete(r.right_words)
	r^ = {}
}


// --- The loader thread -------------------------------------------------------------

@(private = "file")
loader_proc :: proc() {
	repo: git.Repo
	git.library_init()
	defer {
		git.repo_close(&repo)
		git.library_shutdown()
	}

	for {
		retired, job, has_job, ok := next_work()
		if !ok do return

		for &r in retired do diff_result_destroy(&r)
		delete(retired)
		if !has_job do continue

		r := load_diff(&job, &repo)
		diff_job_destroy(&job)
		if sync.guard(&loader.mutex) {
			append(&loader.results, r)
			loader.working -= 1
		}
		wake_main_loop(nil)
		free_all(context.temp_allocator)
	}
}


// Waits for something to do: what views showed to free (owned), and the next
// job if there is one. False once stopping
@(private = "file")
next_work :: proc() -> (retired: []Diff_Result, job: Diff_Job, has_job, ok: bool) {
	sync.guard(&loader.mutex)
	for !loader.stop && len(loader.jobs) == 0 && len(loader.retired) == 0 {
		sync.cond_wait(&loader.cond, &loader.mutex)
	}
	if loader.stop do return

	retired = slice.clone(loader.retired[:])
	clear(&loader.retired)
	if len(loader.jobs) > 0 {
		job = pop_front(&loader.jobs)
		has_job = true
		loader.working += 1
	}
	return retired, job, has_job, true
}


// Reads, diffs and builds a diff view's sides. `cached` is a repository the
// caller keeps open between jobs; without it one is opened for this job
@(private = "file")
load_diff :: proc(job: ^Diff_Job, cached: ^git.Repo = nil) -> (r: Diff_Result) {
	r.view, r.serial = job.view, job.serial

	// The repository, opened again for another work tree
	own: git.Repo
	repo := cached != nil ? cached : &own
	defer if repo == &own do git.repo_close(&own)
	if repo.handle == nil || repo.info.workdir != job.workdir {
		found, problem := git.repo_open(repo, job.workdir)
		if !found {
			r.status = .Error
			r.problem = clone_or(problem, "the repository can't be opened")
			return
		}
	}

	// What each side shows; nothing more when the view shows it already
	left, right := sources(job)
	r.signature = signature(repo, job, left, right)
	if known, ok := job.known.?; ok && known == r.signature {
		r.status = .Unchanged
		return
	}

	// The two texts
	old_text, old_problem := read_side(repo, job, left)
	new_text, new_problem := read_side(repo, job, right)
	if old_problem != "" || new_problem != "" {
		delete(old_text)
		delete(new_text)
		r.status = .Error
		r.problem = clone_or(old_problem != "" ? old_problem : new_problem, "")
		return
	}
	if right == .Work_Tree {
		r.right_size = len(new_text)
		r.right_hash = file_hash(new_text)
	}
	if is_binary(old_text) || is_binary(new_text) {
		delete(old_text)
		delete(new_text)
		r.status = .Binary
		return
	}

	// The diff, side by side
	hunks, old_lines, new_lines := diff.line_hunks(old_text, new_text)
	r.rows = diff.rows_make(hunks, old_lines, new_lines)

	// Each side's document and highlighting (the buffers take the texts)
	r.left.exists = r.signature.left_found
	r.right.exists = r.signature.right_found
	buffer.buffer_init(&r.left.buf, old_text)
	buffer.buffer_init(&r.right.buf, new_text)
	syntax.highlighter_open(&r.left.hl, &r.left.buf, job.path)
	syntax.highlighter_open(&r.right.hl, &r.right.buf, job.path)

	r.left_words, r.right_words = changed_words(&r)
	r.status = .Ready
	return
}


// Where a diff view's sides come from: the staged version beside the work
// tree's (an open editor's text, if any) for changes, HEAD's beside the staged
// version for staged changes, nothing beside the file for an untracked one,
// and HEAD's beside the file with its conflict markers for a conflict; a
// commit's: its parent's beside its own
@(private = "file")
sources :: proc(job: ^Diff_Job) -> (left, right: Diff_Source) {
	if job.commit != nil do return .Before, .Commit

	work: Diff_Source = job.editor != nil ? .Editor : .Work_Tree
	switch job.area {
	case .Changes:   return .Index, work
	case .Staged:    return .Head, .Index
	case .Untracked: return .None, work
	case .Conflicts: return .Head, work
	}
	return .None, work
}


// What the sides would show, found without reading them
@(private = "file")
signature :: proc(repo: ^git.Repo, job: ^Diff_Job, left, right: Diff_Source) -> Diff_Signature {
	s := Diff_Signature{left = left, right = right}

	#partial switch left {
	case .Head:  s.left_id, s.left_found = git.version_id(repo, job.rel, .Head)
	case .Index: s.left_id, s.left_found = git.version_id(repo, job.rel, .Index)
	case .Before:
		s.left_id, s.left_found = git.commit_version_id(repo, before_path(job), job.commit.?, true)
	}

	#partial switch right {
	case .Commit:
		s.right_id, s.right_found = git.commit_version_id(repo, job.rel, job.commit.?, false)
	case .Index:
		s.right_id, s.right_found = git.version_id(repo, job.rel, .Index)
	case .Work_Tree:
		s.right_stamp, s.right_found = file_stamp(job.path)
	case .Editor:
		s.right_version = job.editor.?.version
		s.right_found = true
	}
	return s
}


// A side's text, owned; empty when the version has no such file
@(private = "file")
read_side :: proc(repo: ^git.Repo, job: ^Diff_Job, source: Diff_Source) -> ([]u8, string) {
	switch source {
	case .None:
		return nil, ""

	case .Head, .Index:
		version: git.Version = source == .Head ? .Head : .Index
		text, _, _, problem := git.read_version(repo, job.rel, version)
		return text, problem

	case .Work_Tree:
		text, err := read_file_shared(job.path)
		#partial switch err {
		case .None, .Missing: return text, ""
		case .Busy:           return nil, "the file is locked by another program"
		}
		return nil, "the file can't be read"

	case .Editor:
		snap := &job.editor.?
		return buffer.snapshot_read_alloc(snap, 0, snap.length, context.allocator), ""

	case .Before, .Commit:
		parent := source == .Before
		rel := parent ? before_path(job) : job.rel
		text, _, _, problem := git.read_commit_version(repo, rel, job.commit.?, parent)
		return text, problem
	}
	return nil, ""
}


// Where a commit's parent has the file: where it was, if the commit renamed it
@(private = "file")
before_path :: proc(job: ^Diff_Job) -> string {
	return job.from != "" ? job.from : job.rel
}


@(private = "file")
is_binary :: proc(text: []u8) -> bool {
	return slice.contains(text[:min(len(text), BINARY_SNIFF)], 0)
}


// The words that changed in each pair of changed lines, within the limits
@(private = "file")
changed_words :: proc(r: ^Diff_Result) -> (left, right: []Word_Span) {
	old_words := make([dynamic]Word_Span)
	new_words := make([dynamic]Word_Span)
	pairs := 0

	pairing: for h in r.rows.hunks {
		n := min(h.old_hi - h.old_lo, h.new_hi - h.new_lo)
		for i in 0 ..< n {
			pairs += 1
			if pairs > WORD_PAIRS_MAX do break pairing

			old_line, new_line := h.old_lo + i, h.new_lo + i
			a := side_line(&r.left.buf, old_line)
			b := side_line(&r.right.buf, new_line)
			if len(a) > WORD_LINE_MAX || len(b) > WORD_LINE_MAX {
				continue
			}

			removed, added, ok := diff.words(a, b, context.temp_allocator)
			if !ok do continue
			for x in removed do append(&old_words, Word_Span{old_line, x[0], x[1]})
			for x in added do append(&new_words, Word_Span{new_line, x[0], x[1]})
		}
	}
	return old_words[:], new_words[:]
}


// A line of a side, without its line break (temp)
@(private = "file")
side_line :: proc(b: ^buffer.Buffer, line: int) -> string {
	start := buffer.line_start(b, line)
	end := buffer.line_end(b, line)
	return string(buffer.read_alloc(b, start, max(end, start)))
}


@(private = "file")
clone_or :: proc(s, fallback: string) -> string {
	return strings.clone(s != "" ? s : fallback)
}
