package editor

// What runs in typo's terminals, asked before closing a terminal, quitting or
// opening another folder ends it (the unsaved-changes flow, dialog.odin). A
// terminal runs a program when its shell has processes under it. Listing them
// takes a snapshot of every process, so a check runs on a thread of its own,
// which hands the names over and wakes the UI

import "base:runtime"
import "core:sync"
import "core:thread"

import "term"


// A check of some shells, by process id. Its memory is the heap's, as either
// thread may free it
Programs_Check :: struct {
	pids:      []int,      // owned; 0 for a terminal whose shell isn't known
	found:     [][]string, // owned; per pid, the programs under it, once done
	mutex:     sync.Mutex,
	done:      bool,
	abandoned: bool, // nobody waits for it: the thread frees it
}


// The terminals that `then` ends whose shells are alive: closing a terminal,
// or pinning or unpinning it (which restarts it), ends it whatever its
// backend; quitting and leaving the folder end local ones, while persistent
// ones go on in herdr-core (temp)
terminals_ended_by :: proc(then: After_Unsaved) -> []^Pane {
	panes := make([dynamic]^Pane, context.temp_allocator)

	switch t in then {
	case Closing_Pane:
		p := (^Pane)(t)
		if terminal_alive(p) do append(&panes, p)

	case Repinning:
		if terminal_alive(t.pane) do append(&panes, t.pane)

	case Open_Folder, Quit:
		for p in g.panes.open {
			t, is_terminal := p.content.(^Terminal)
			if is_terminal && terminal_alive(p) && term.session_is_local(&t.session) {
				append(&panes, p)
			}
		}
	}
	return panes[:]
}


// Whether the pane is a terminal whose shell is alive
terminal_alive :: proc(p: ^Pane) -> bool {
	t, is_terminal := p.content.(^Terminal)
	return is_terminal && t.initialized && t.session.running
}


// Starts listing what runs under each pane's shell
programs_check_start :: proc(panes: []^Pane) -> ^Programs_Check {
	heap := runtime.heap_allocator()
	c := new(Programs_Check, heap)
	c.pids = make([]int, len(panes), heap)
	c.found = make([][]string, len(panes), heap)
	for p, i in panes {
		t := p.content.(^Terminal)
		c.pids[i] = term.session_pid(&t.session)
	}

	// The default context, which frees the thread's temp memory as it ends
	thread.create_and_start_with_poly_data(c, programs_check_proc, self_cleanup = true)
	return c
}


programs_check_done :: proc(c: ^Programs_Check) -> bool {
	sync.guard(&c.mutex)
	return c.done
}


// The first program running under the i-th shell, or "" for none. Only once done
programs_check_first :: proc(c: ^Programs_Check, i: int) -> string {
	if len(c.found[i]) == 0 do return ""
	return c.found[i][0]
}


// Lets go of a check: freed now if it is done, else by its thread when it is
programs_check_release :: proc(c: ^Programs_Check) {
	if c == nil do return

	sync.lock(&c.mutex)
	done := c.done
	c.abandoned = true
	sync.unlock(&c.mutex)

	if done do programs_check_free(c)
}


// Runs on the check's thread
@(private = "file")
programs_check_proc :: proc(c: ^Programs_Check) {
	for pid, i in c.pids {
		c.found[i] = term.programs_under(pid, runtime.heap_allocator())
	}

	sync.lock(&c.mutex)
	c.done = true
	abandoned := c.abandoned
	sync.unlock(&c.mutex)

	if abandoned {
		programs_check_free(c)
		return
	}
	wake_main_loop(nil)
}


@(private = "file")
programs_check_free :: proc(c: ^Programs_Check) {
	heap := runtime.heap_allocator()
	for names in c.found {
		for name in names do delete(name, heap)
		delete(names, heap)
	}
	delete(c.found, heap)
	delete(c.pids, heap)
	free(c, heap)
}
