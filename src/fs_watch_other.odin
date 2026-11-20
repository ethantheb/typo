#+build !windows
package editor

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// The watcher's notifications elsewhere: the folder is walked every
// TREE_POLL and compared with the walk before (inotify isn't recursive and
// FSEvents needs CoreServices bindings; either can replace this behind the same
// procedures). Folders the finder ignores aren't walked


@(private = "file")
TREE_POLL :: 2 * time.Second

@(private = "file")
TREE_POLL_MAX :: 200_000 // entries; a bigger folder is only watched this far

@(private = "file")
Snapshot_Entry :: struct {
	stamp:  File_Stamp,
	is_dir: bool,
}

Watch_Platform :: struct {
	wake:      sync.Sema,
	root:      string,                    // owned; "" when not watching
	snapshot:  map[string]Snapshot_Entry, // path (owned) -> what it was at the last walk
	next_walk: time.Tick,
}


platform_init :: proc(p: ^Watch_Platform) {}


platform_destroy :: proc(p: ^Watch_Platform) {
	platform_close(p)
}


platform_open :: proc(p: ^Watch_Platform, root: string) -> bool {
	p.root = strings.clone(root)
	walk_snapshot(p.root, &p.snapshot)
	p.next_walk = time.tick_add(time.tick_now(), TREE_POLL)
	return true
}


platform_close :: proc(p: ^Watch_Platform) {
	clear_snapshot(&p.snapshot)
	delete(p.snapshot)
	delete(p.root)
	p.snapshot = nil
	p.root = ""
}


platform_active :: proc(p: ^Watch_Platform) -> bool {
	return p.root != ""
}


// Ends a wait early. Safe from any thread
platform_wake :: proc(p: ^Watch_Platform) {
	sync.sema_post(&p.wake)
}


// Waits up to `timeout`, walking the folder when due and appending what changed
// since the last walk to `events`. Never reports an overflow
platform_wait :: proc(
	p: ^Watch_Platform,
	root: string,
	timeout: time.Duration,
	events: ^[dynamic]Watch_Event,
) -> (
	overflow: bool,
) {
	wait := timeout
	if p.root != "" {
		wait = min(wait, max(time.tick_diff(time.tick_now(), p.next_walk), 0))
	}
	if sync.sema_wait_with_timeout(&p.wake, wait) do return false
	if p.root == "" || time.tick_diff(p.next_walk, time.tick_now()) < 0 {
		return false
	}

	// The walk, compared with the one before
	now: map[string]Snapshot_Entry
	walk_snapshot(p.root, &now)
	for path, entry in now {
		before, found := p.snapshot[path]
		switch {
		case !found:
			append(events, Watch_Event{strings.clone(path, context.temp_allocator), .Added})
		case !entry.is_dir && before.stamp != entry.stamp:
			append(events, Watch_Event{strings.clone(path, context.temp_allocator), .Modified})
		}
	}
	for path in p.snapshot {
		if path in now do continue
		append(events, Watch_Event{strings.clone(path, context.temp_allocator), .Removed})
	}

	clear_snapshot(&p.snapshot)
	delete(p.snapshot)
	p.snapshot = now
	p.next_walk = time.tick_add(time.tick_now(), TREE_POLL)
	return false
}


// Every file and folder under root, but inside ignored folders
@(private = "file")
walk_snapshot :: proc(root: string, out: ^map[string]Snapshot_Entry) {
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, strings.trim_right(root, "/"))

	for len(stack) > 0 && len(out) < TREE_POLL_MAX {
		dir := pop(&stack)
		entries, ok := list_directory(dir)
		if !ok do continue

		for e in entries {
			path := strings.concatenate({dir, "/", e.name})
			stamp, _ := file_stamp(path)
			out[path] = {stamp, e.is_dir}

			ignored := slice.contains(FINDER_IGNORED_DIRS[:], e.name)
			if e.is_dir && !e.is_link && !ignored {
				append(&stack, strings.clone(path, context.temp_allocator))
			}
		}
	}
}


@(private = "file")
clear_snapshot :: proc(m: ^map[string]Snapshot_Entry) {
	for path in m do delete(path)
	clear(m)
}


// --- Reading files -----------------------------------------------------------------

file_stamp :: proc(path: string) -> (stamp: File_Stamp, exists: bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}, false

	return {info.size, time.to_unix_nanoseconds(info.modification_time)}, true
}


// Reads a whole file. Files here aren't locked against reading, so never Busy
read_file_shared :: proc(path: string, allocator := context.allocator) -> ([]u8, Read_Error) {
	data, err := os.read_entire_file(path, allocator)
	if err == nil do return data, .None
	if !os.exists(path) do return nil, .Missing
	return nil, .Failed
}
