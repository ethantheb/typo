package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "buffer"
import sdl "../vendor/sdl3"
import "textedit"

// Perf phase: files changed by other programs (fs_watch.odin, file_sync.odin).
// The phase writes to a folder in the workspace as another program would, and
// waits for the watcher to report it: the tree, an open file reloading, the
// dialogs, a deleted file, and a burst of new files


@(private = "file")
WAIT_LIMIT :: 5 * time.Second // for the watcher to report a change

@(private = "file")
BURST_FILES :: 300

@(private = "file")
OPEN_LINES :: 30


phase_disk_changes :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) since: time.Tick
	@(static) caret: int
	@(static) worst: f64
	@(static) before: string // the file open before, reopened at the end

	dir := path_in_dir(p, "watched")
	open := fmt.tprintf("%s%copen.txt", dir, os.Path_Separator)
	added := fmt.tprintf("%s%cadded.txt", dir, os.Path_Separator)
	renamed := fmt.tprintf("%s%crenamed.txt", dir, os.Path_Separator)

	// The UI thread's share of applying what the watcher found
	worst = max(worst, time.duration_milliseconds(watch_ui_time))
	watch_ui_time = 0

	if frame == 0 {
		step, worst = 0, 0
		_ = os.remove_all(dir)
		_ = os.make_directory_all(dir)
		_ = os.write_entire_file(open, transmute([]u8)numbered_lines(""))

		// The folder expanded in the tree, the file open with the caret on line 20
		if e := focused_editor(); e != nil {
			before = strings.clone(e.path)
		}
		close_files()
		workspace_refresh(&g.workspace)
		workspace_expand(&g.workspace, {dir})
		open_loaded(open)
		e := focused_editor()
		caret = buffer.line_start(&e.buf, 20) + 3
		textedit.set_single_selection(e, {caret, caret, -1})

		_ = os.write_entire_file(added, transmute([]u8)string("new"))
		since = time.tick_now()
		return false
	}

	e := focused_editor()
	d := &g.dialog

	switch step {
	case 0: // a file added
		shown := tree_shows(added)
		if waiting(shown, since) do return false

		check(p, "a file added on disk shows in the tree", shown)
		_ = os.rename(added, renamed)
		next_step(&step, &since)

	case 1: // renamed
		moved := tree_shows(renamed) && !tree_shows(added)
		if waiting(moved, since) do return false

		check(p, "a file renamed on disk is renamed in the tree", moved)
		check(p, "its folder stays expanded", tree_shows(open))
		_ = os.remove(renamed)
		next_step(&step, &since)

	case 2: // deleted; then the open file is rewritten
		gone := !tree_shows(renamed)
		if waiting(gone, since) do return false

		check(p, "a file deleted on disk leaves the tree", gone)
		_ = os.write_entire_file(open, transmute([]u8)numbered_lines("inserted\n"))
		next_step(&step, &since)

	case 3: // the unedited open file reloads, the caret on its text
		want := numbered_lines("inserted\n")
		reloaded := editor_text(e) == want
		if waiting(reloaded, since) do return false

		check(p, "an unedited open file reloads", reloaded)
		check(p, "the caret stays on its text", e.sels[e.primary].head == caret + len("inserted\n"))
		check(p, "and the file isn't unsaved", !editor_is_modified(e))
		textedit.undo(e)
		undone := editor_text(e) == numbered_lines("")
		textedit.redo(e)
		check(p, "the reload is one undo step", undone && !editor_is_modified(e))

		// Unsaved edits, then another version on disk
		editor_text_input(e, "x")
		_ = os.write_entire_file(open, transmute([]u8)numbered_lines("other\n"))
		next_step(&step, &since)

	case 4: // with unsaved edits, a dialog asks
		_, asking := d.purpose.(Reloading)
		asked := d.open && asking
		if waiting(asked, since) do return false

		check(p, "a change under unsaved edits asks", asked)
		key_press(sdl.K_ESCAPE) // keep my version
		next_step(&step, &since)

	case 5: // kept: saving doesn't ask again
		kept := !d.open && strings.contains(editor_text(e), "x") && editor_is_modified(e)
		check(p, "\"Keep my version\" keeps the edits", kept)

		run_command(.Save)
		wait_for_saves()
		data, _ := os.read_entire_file(open, context.temp_allocator)
		check(p, "then saving doesn't ask", !d.open && string(data) == editor_text(e))

		// Another version just before saving, before the watcher could see it
		_ = os.write_entire_file(open, transmute([]u8)numbered_lines("racing\n"))
		run_command(.Save)
		_, overwriting := d.purpose.(Overwriting)
		check(p, "saving over a newer version on disk asks", d.open && overwriting)
		key_press(sdl.K_ESCAPE)
		next_step(&step, &since)

	case 6: // that version reloads, as the file has no unsaved edits
		reloaded := editor_text(e) == numbered_lines("racing\n")
		if waiting(reloaded, since) do return false

		check(p, "and then reloads", reloaded && !editor_is_modified(e))
		_ = os.remove(open)
		next_step(&step, &since)

	case 7: // deleted: kept as unsaved
		missing := e.disk.missing
		if waiting(missing, since) do return false

		check(p, "a deleted open file stays open, unsaved", missing && editor_is_modified(e))
		_ = os.write_entire_file(open, transmute([]u8)numbered_lines("racing\n"))
		next_step(&step, &since)

	case 8: // back as it was
		back := !e.disk.missing && !editor_is_modified(e)
		if waiting(back, since) do return false

		check(p, "it is saved again when the file comes back", back)
		finder_open(.Files)
		next_step(&step, &since)

	case 9: // the finder lists files; then a burst of new files
		if waiting(!g.finder.indexing, since) do return false

		for i in 0 ..< BURST_FILES {
			_ = os.write_entire_file(burst_file(dir, i), transmute([]u8)string("burst"))
		}
		worst = 0
		next_step(&step, &since)

	case 10: // the burst reaches the tree
		all := tree_shows(burst_file(dir, 0)) && tree_shows(burst_file(dir, BURST_FILES - 1))
		if waiting(all, since) do return false

		check(p, "a burst of new files shows in the tree", all)
		result(p, "the burst seen in the tree after", ms_since(since), "ms", 2000)
		next_step(&step, &since)

	case 11: // and in the finder
		indexed := finder_lists(burst_file(dir, BURST_FILES - 1))
		if waiting(indexed, since) do return false

		check(p, "and the finder lists them", indexed)
		result(p, "file watching, UI thread, worst", worst, "ms", 2)

		finder_close()
		close_files()
		_ = os.remove_all(dir)

		// Later phases use the file open before
		if before != "" {
			open_loaded(before)
			delete(before)
			before = ""
		}
		return true
	}
	return false
}


@(private = "file")
burst_file :: proc(dir: string, i: int) -> string {
	return fmt.tprintf("%s%cburst-%03d.txt", dir, os.Path_Separator, i)
}


// Whether the finder's index has `path`, once indexing is done
@(private = "file")
finder_lists :: proc(path: string) -> bool {
	if g.finder.indexing do return false

	for f in g.finder.files {
		if f == path do return true
	}
	return false
}


// Whether to wait another frame for something the watcher reports: until it is
// done, or WAIT_LIMIT passed since the step began
@(private = "file")
waiting :: proc(done: bool, since: time.Tick) -> bool {
	return !done && time.tick_since(since) < WAIT_LIMIT
}


@(private = "file")
next_step :: proc(step: ^int, since: ^time.Tick) {
	step^ += 1
	since^ = time.tick_now()
}


// OPEN_LINES numbered lines after `first`, with line 5 in capitals when `first`
// is given, so a reload changes lines apart from each other
@(private = "file")
numbered_lines :: proc(first: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, first)
	for i in 0 ..< OPEN_LINES {
		word := i == 5 && first != "" ? "LINE" : "line"
		fmt.sbprintf(&sb, "%s %d\n", word, i)
	}
	return strings.to_string(sb)
}


@(private = "file")
editor_text :: proc(e: ^Editor) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf), context.temp_allocator))
}


// Whether the tree has a row for `path` in view
@(private = "file")
tree_shows :: proc(path: string) -> bool {
	for i in g.workspace.visible {
		if g.workspace.nodes[i].path == path do return true
	}
	return false
}


@(private = "file")
key_press :: proc(key: sdl.Keycode) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	handle_key_event(&event)
}
