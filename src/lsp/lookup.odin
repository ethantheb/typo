package lsp

// Lookups that touch the file system, on a thread of their own: a program on
// PATH (each folder tried with each extension) and a file's project root
// (marker files looked for in each folder up to the workspace)

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"

import "../process"


Lookups :: struct {
	// Shared with the thread, guarded by mutex
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	wanted:    [dynamic]Lookup,
	found:     [dynamic]Lookup, // answered
	closing:   bool,

	thread:    ^thread.Thread, // started by the first lookup
	allocator: runtime.Allocator,
	wake:      Notify_Proc,
	wake_data: rawptr,
}

// A program to find, or a file whose project root to find. Every string is
// owned
Lookup :: struct {
	key:       string, // what the caller files the answer under
	program:   string,
	file:      string,
	workspace: string,
	markers:   []string,
	answer:    string, // the program's path ("" if not found), or the root
}


// `wake` is called from the thread when answers are ready
lookups_init :: proc(l: ^Lookups, wake: Notify_Proc, wake_data: rawptr) {
	l^ = {allocator = context.allocator, wake = wake, wake_data = wake_data}
}


// Waits for a lookup under way to finish, then frees everything
lookups_destroy :: proc(l: ^Lookups) {
	if l.thread != nil {
		if sync.guard(&l.mutex) {
			l.closing = true
			sync.cond_signal(&l.cond)
		}
		thread.destroy(l.thread)
	}

	for &x in l.wanted do lookup_destroy(&x)
	for &x in l.found do lookup_destroy(&x)
	delete(l.wanted)
	delete(l.found)
	l^ = {}
}


// Looks for a program: a path, or a name on PATH
lookup_program :: proc(l: ^Lookups, key, name: string) {
	push(l, {key = strings.clone(key, l.allocator), program = strings.clone(name, l.allocator)})
}


// Looks for the project root of `file` (see find_root)
lookup_root :: proc(l: ^Lookups, key, file, workspace: string, markers: []string) {
	owned := make([]string, len(markers), l.allocator)
	for m, i in markers do owned[i] = strings.clone(m, l.allocator)

	push(l, {
		key       = strings.clone(key, l.allocator),
		file      = strings.clone(file, l.allocator),
		workspace = strings.clone(workspace, l.allocator),
		markers   = owned,
	})
}


// Moves the answered lookups to `out`; free each with lookup_destroy
lookups_take :: proc(l: ^Lookups, out: ^[dynamic]Lookup) {
	sync.guard(&l.mutex)
	append(out, ..l.found[:])
	clear(&l.found)
}


lookup_destroy :: proc(x: ^Lookup) {
	delete(x.key)
	delete(x.program)
	delete(x.file)
	delete(x.workspace)
	for m in x.markers do delete(m)
	delete(x.markers)
	delete(x.answer)
	x^ = {}
}


@(private = "file")
push :: proc(l: ^Lookups, x: Lookup) {
	if l.thread == nil {
		ctx := runtime.default_context()
		ctx.allocator = l.allocator
		l.thread = thread.create_and_start_with_poly_data(l, lookups_proc, ctx)
	}

	sync.guard(&l.mutex)
	append(&l.wanted, x)
	sync.cond_signal(&l.cond)
}


@(private = "file")
lookups_proc :: proc(l: ^Lookups) {
	for {
		// The next one, if not closing
		sync.lock(&l.mutex)
		for len(l.wanted) == 0 && !l.closing {
			sync.cond_wait(&l.cond, &l.mutex)
		}
		if l.closing {
			sync.unlock(&l.mutex)
			break
		}
		x := pop_front(&l.wanted)
		sync.unlock(&l.mutex)

		if x.program != "" {
			x.answer = process.find_executable(x.program)
		} else {
			x.answer = find_root(x.file, x.workspace, x.markers)
		}

		if sync.guard(&l.mutex) {
			append(&l.found, x)
		}
		l.wake(l.wake_data)
		free_all(context.temp_allocator)
	}
}
