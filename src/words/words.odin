package words

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:thread"

import "../buffer"
import "../textedit"

// The words of a document, for word completions: identifier-like runs (letters,
// digits, '_' and non-ASCII characters, not starting with a digit), each once,
// from the lines around the caret. They are collected on a thread of their own
// from buffer snapshots (an `Indexer`) and handed over as an `Index`


// Words come from this many lines either side of the caret's, and no more than
// WINDOW_BYTES either side of it (a long line)
WINDOW_LINES :: 5000
WINDOW_BYTES :: 512 << 10

MIN_LEN :: 2  // shorter runs are left out
MAX_LEN :: 64 // so are longer ones (hashes, encoded data)

// A document's words, sorted
Index :: struct {
	words:     []string,
	data:      []u8, // the words' bytes
	version:   u64,  // the buffer version they were read from
	lo, hi:    int,  // the bytes read
	length:    int,  // the document's
	refs:      int,  // holders, all on one thread
	allocator: runtime.Allocator,
}

// The bytes a collection reads
@(private = "file")
Window :: struct {
	lo, hi:     int,
	cut_lo: bool, // inside a line: a run starting at lo may be cut short
	cut_hi: bool,
	caret:  int,  // the run that holds or ends here is left out
}


// Collects the words of the snapshot's lines around `caret_line`. The run that
// holds or ends at `caret` (the word being typed there) is left out; the same
// word elsewhere counts
collect :: proc(
	text: ^buffer.Snapshot,
	caret, caret_line: int,
	allocator := context.allocator,
) -> ^Index {
	// The lines around the caret's, cut WINDOW_BYTES from it
	first := max(caret_line - WINDOW_LINES, 0)
	last := min(caret_line + WINDOW_LINES, text.lines - 1)
	lo := buffer.snapshot_line_start(text, first)
	hi := last + 1 < text.lines ? buffer.snapshot_line_start(text, last + 1) : text.length
	w := Window {
		lo    = max(lo, caret - WINDOW_BYTES),
		hi    = min(hi, caret + WINDOW_BYTES),
		caret = caret,
	}
	w.cut_lo = w.lo > lo
	w.cut_hi = w.hi < hi

	// Each word once, its bytes in an arena that doesn't move them
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	seen := make(map[string]struct{}, virtual.arena_allocator(&arena))
	scan(text, w, &seen)

	index := new(Index, allocator)
	index^ = {
		version   = text.version,
		lo        = w.lo,
		hi        = w.hi,
		length    = text.length,
		refs      = 1,
		allocator = allocator,
	}
	pack(index, &seen)
	return index
}


// Adds the runs of the window to `seen`
@(private = "file")
scan :: proc(text: ^buffer.Snapshot, w: Window, seen: ^map[string]struct{}) {
	lo, hi := w.lo, w.hi
	run: [MAX_LEN]u8
	run_len := 0   // bytes of the current run, up to MAX_LEN + 1 (too long)
	run_start := 0

	for span in text.spans {
		span_end := span.offset + len(span.text)
		if span_end <= lo do continue
		if span.offset >= hi do break

		from := max(lo, span.offset) - span.offset
		to := min(hi, span_end) - span.offset
		for c, i in span.text[from:to] {
			offset := span.offset + from + i
			if textedit.is_word_byte(c) {
				if run_len == 0 do run_start = offset
				if run_len < MAX_LEN do run[run_len] = c
				run_len = min(run_len + 1, MAX_LEN + 1)
				continue
			}

			add_run(w, run[:], run_len, run_start, offset, seen)
			run_len = 0
		}
	}
	add_run(w, run[:], run_len, run_start, hi, seen)
}


@(private = "file")
add_run :: proc(w: Window, run: []u8, n, start, end: int, seen: ^map[string]struct{}) {
	// Too short or long, a number, or the word being typed
	if n < MIN_LEN || n > MAX_LEN {
		return
	}
	if is_digit(run[0]) do return
	if start <= w.caret && w.caret <= end {
		return
	}

	// Cut by the window's edge
	if (w.cut_lo && start == w.lo) || (w.cut_hi && end == w.hi) {
		return
	}

	word := string(run[:n])
	if word in seen do return

	key := make([]u8, n, seen.allocator)
	copy(key, word)
	seen[string(key)] = {}
}


// Stores the words, sorted, in one block of bytes
@(private = "file")
pack :: proc(index: ^Index, seen: ^map[string]struct{}) {
	context.allocator = index.allocator

	total := 0
	for word in seen do total += len(word)
	index.data = make([]u8, total)
	index.words = make([]string, len(seen))

	at := 0
	i := 0
	for word in seen {
		copy(index.data[at:], word)
		index.words[i] = string(index.data[at:][:len(word)])
		at += len(word)
		i += 1
	}
	slice.sort(index.words)
}


index_retain :: proc(index: ^Index) {
	index.refs += 1
}


// Lets go of the index; the last holder frees it
index_release :: proc(index: ^Index) {
	if index == nil do return

	index.refs -= 1
	if index.refs > 0 do return

	context.allocator = index.allocator
	delete(index.words)
	delete(index.data)
	free(index)
}


// Whether a word has a digit in it
has_digit :: proc(word: string) -> bool {
	for c in transmute([]u8)word {
		if is_digit(c) do return true
	}
	return false
}


@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}


// --- The indexer ---------------------------------------------------------------------

// A thread that collects documents' words
Indexer :: struct {
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Job,
	results:   [dynamic]Result,
	stopping:  bool,
	thread:    ^thread.Thread,
	wake:      proc "contextless" (data: rawptr), // called from the thread with results
	wake_data: rawptr,
	allocator: runtime.Allocator,
}

Job :: struct {
	id:         u64, // the asker's, given back with the result
	text:       buffer.Snapshot, // owned
	caret:      int,
	caret_line: int,
}

Result :: struct {
	id:    u64,
	index: ^Index, // owned
}


// Starts the thread. `ix` must not move until stopped
indexer_start :: proc(
	ix: ^Indexer,
	wake: proc "contextless" (data: rawptr),
	wake_data: rawptr,
) {
	ix^ = {}
	ix.wake = wake
	ix.wake_data = wake_data
	ix.allocator = context.allocator

	ctx := runtime.default_context()
	ctx.allocator = ix.allocator
	ix.thread = thread.create_and_start_with_poly_data(ix, indexer_proc, ctx)
}


// Waits for the thread to end; jobs not started and results not taken are freed
indexer_stop :: proc(ix: ^Indexer) {
	if ix.thread == nil do return

	sync.mutex_lock(&ix.mutex)
	ix.stopping = true
	sync.cond_signal(&ix.cond)
	sync.mutex_unlock(&ix.mutex)

	thread.join(ix.thread)
	thread.destroy(ix.thread)

	for &job in ix.jobs do buffer.snapshot_release(&job.text)
	for r in ix.results do index_release(r.index)
	delete(ix.jobs)
	delete(ix.results)
	ix^ = {}
}


// Queues a job, taking its snapshot. One waiting with the same id is replaced
indexer_post :: proc(ix: ^Indexer, job: Job) {
	sync.guard(&ix.mutex)

	for &waiting in ix.jobs {
		if waiting.id != job.id do continue

		buffer.snapshot_release(&waiting.text)
		waiting = job
		return
	}

	append(&ix.jobs, job)
	sync.cond_signal(&ix.cond)
}


// The results ready, from the temp allocator; each index is the taker's
indexer_take :: proc(ix: ^Indexer) -> []Result {
	sync.guard(&ix.mutex)

	out := slice.clone(ix.results[:], context.temp_allocator)
	clear(&ix.results)
	return out
}


@(private = "file")
indexer_proc :: proc(ix: ^Indexer) {
	for {
		sync.mutex_lock(&ix.mutex)
		for len(ix.jobs) == 0 && !ix.stopping {
			sync.cond_wait(&ix.cond, &ix.mutex)
		}
		if ix.stopping {
			sync.mutex_unlock(&ix.mutex)
			return
		}
		job := pop_front(&ix.jobs)
		sync.mutex_unlock(&ix.mutex)

		index := collect(&job.text, job.caret, job.caret_line, ix.allocator)
		buffer.snapshot_release(&job.text)

		sync.mutex_lock(&ix.mutex)
		append(&ix.results, Result{job.id, index})
		sync.mutex_unlock(&ix.mutex)
		ix.wake(ix.wake_data)
	}
}
