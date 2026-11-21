package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "buffer"
import "textedit"

// Tests of opening and saving files on the loader and writer threads: results
// land once and only for the load they belong to, what waits for the text is
// applied once, a large file waits for the user, writes mark what they wrote


// A temp file with the text, named by the test; removed by the caller
@(private = "file")
temp_file :: proc(name, text: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.tprintf("%s%ctypo-load-%s-%d.txt", dir, os.Path_Separator, name, os.get_pid())
	_ = os.write_entire_file(path, text)
	return path
}


@(private = "file")
editor_text :: proc(e: ^Editor) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf), context.temp_allocator))
}


// The editor waits Loading until the loader's result lands; then the text is
// there and what waited for it (a jump's place) is applied once. A result for
// an earlier load of the editor is dropped
@(test)
test_load_lands_once :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	io_init()
	defer io_destroy()

	first := temp_file("first", "first file\n")
	second := temp_file("second", "one\ntwo\nthree\n")
	defer os.remove(first)
	defer os.remove(second)

	e := new(Editor)
	defer {
		editor_destroy(e)
		free(e)
	}

	// The first file's load is replaced once its result waits to be taken
	editor_open(e, first)
	for i := 0; i < 2000 && !io_loads_done(); i += 1 {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, io_loads_done())
	editor_open(e, second)
	testing.expect_value(t, e.status, File_Status.Loading)

	target := len("one\n")
	editor_when_ready(e, {target = target, heading = strings.clone("unused")})
	editor_wait_loaded(e)

	testing.expect_value(t, e.status, File_Status.Text)
	testing.expect_value(t, editor_text(e), "one\ntwo\nthree\n")
	testing.expect_value(t, e.sels[0].head, target)
	testing.expect(t, e.load == {}, "nothing waits anymore")

	// Moved since, the caret stays: nothing is applied twice, and the replaced
	// load's result never lands
	textedit.set_single_selection(e, {0, 0, -1})
	for _ in 0 ..< 20 do file_load_frame()
	testing.expect_value(t, e.sels[0].head, 0)
	testing.expect_value(t, editor_text(e), "one\ntwo\nthree\n")
}


// Closing an editor while its file loads drops the load, whether it hasn't
// started or its result already waits; nothing leaks
@(test)
test_close_while_loading :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	io_init()

	path := temp_file("closing", strings.repeat("some text\n", 400_000, context.temp_allocator))
	defer os.remove(path)

	// Closed at once
	e := new(Editor)
	editor_open(e, path)
	editor_when_ready(e, {heading = strings.clone("dropped")})
	editor_close(e)

	// Closed once its result waits: freed when it lands
	editor_open(e, path)
	for i := 0; i < 5000 && !io_loads_done(); i += 1 {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, io_loads_done())
	editor_destroy(e)
	free(e)

	file_load_frame()
	io_destroy()
}


// A file larger than the setting is only measured: a dialog asks, and Open
// reads it
@(test)
test_large_file_asks_first :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	io_init()
	defer io_destroy()
	defer dialog_close()

	g.settings.ask_above_mb = 1
	defer g.settings.ask_above_mb = 0

	text := strings.repeat("0123456789abcdef\n", 70_000, context.temp_allocator)
	path := temp_file("large", text)
	defer os.remove(path)

	e := new(Editor)
	defer {
		editor_destroy(e)
		free(e)
	}
	editor_open(e, path)
	editor_wait_loaded(e)
	file_load_frame()

	// Asked about, not read
	testing.expect_value(t, e.status, File_Status.Loading)
	testing.expect_value(t, e.load.size, i64(len(text)))
	asking, is_large := g.dialog.purpose.(Opening_Large)
	testing.expect(t, g.dialog.open && is_large && asking.id == e.load.id)

	// Open
	large_file_answer(asking.id, open = true)
	editor_wait_loaded(e)
	testing.expect_value(t, e.status, File_Status.Text)
	testing.expect_value(t, buffer.length(&e.buf), len(text))
}


// Opens a file in a pane of its own (not in the layout), waiting for its text
@(private = "file")
open_pane :: proc(path: string) -> (^Pane, ^Editor) {
	e := new(Editor)
	pane := new(Pane)
	pane.content = e
	append(&g.panes.open, pane)

	editor_open(e, path)
	editor_wait_loaded(e)
	return pane, e
}


// Runs the frame steps that land writes and move the unsaved-changes flow on,
// until `done` or a few seconds pass
@(private = "file")
flow_frames :: proc(done: proc() -> bool) -> bool {
	for _ in 0 ..< 5000 {
		dialog_frame()
		file_load_frame()
		unsaved_frame()
		if done() do return true
		time.sleep(time.Millisecond)
	}
	return false
}


// Closing a file with unsaved changes and choosing Save closes it once the
// write has landed; quitting while a write is under way waits for it, and
// doesn't ask about the file it saves
@(test)
test_unsaved_flow_waits_for_writes :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	io_init()
	defer io_destroy()

	path := temp_file("flow", "hello\n")
	defer os.remove(path)

	defer {
		for len(g.panes.open) > 0 do pane_close(g.panes.open[0], ask = false)
		delete(g.panes.open)
		g.panes.open = {}
		delete(g.unsaved.asking)
		g.unsaved.asking = {}
		g.quit = false
	}

	// Close, Save: still open until the write lands
	pane, e := open_pane(path)
	textedit.insert(e, "a")
	resolve_unsaved({pane}, Closing_Pane(pane))
	_, asking := g.dialog.purpose.(Unsaved_Step)
	testing.expect(t, g.dialog.open && asking)

	g.dialog.choice = 0
	dialog_frame()
	testing.expect(t, slice.contains(g.panes.open[:], pane), "open while it is written")
	closed := flow_frames(proc() -> bool { return len(g.panes.open) == 0 })
	testing.expect(t, closed, "closed once written")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "ahello\n")

	// Quit while a write is under way: no question, and the write lands first
	_, e = open_pane(path)
	textedit.insert(e, "b")
	editor_save(e)
	resolve_unsaved(g.panes.open[:], Quit{})
	testing.expect(t, !g.quit && !g.dialog.open, "waits for the write")
	quit := flow_frames(proc() -> bool { return g.quit })
	testing.expect(t, quit && !g.dialog.open, "then quits, unasked")
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "bahello\n")
}


// A save writes the text as it was when asked; edits made before the write
// lands keep the file modified, and undoing them gets back to the saved text
@(test)
test_save_marks_what_it_wrote :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	io_init()
	defer io_destroy()

	path := temp_file("save", "hello\n")
	defer os.remove(path)

	e := new(Editor)
	defer {
		editor_destroy(e)
		free(e)
	}
	editor_open(e, path)
	editor_wait_loaded(e)

	// "!" typed, saved, then "?" typed before the write lands
	textedit.set_single_selection(e, {5, 5, -1})
	textedit.insert(e, "!")
	testing.expect(t, editor_save(e))
	testing.expect(t, editor_is_modified(e), "not saved before the write lands")
	textedit.insert(e, "?")
	wait_for_saves()

	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "hello!\n")
	testing.expect_value(t, e.disk.hash, file_hash(data))
	testing.expect(t, editor_is_modified(e), "typed during the write")

	textedit.undo(e)
	testing.expect_value(t, editor_text(e), "hello!\n")
	testing.expect(t, !editor_is_modified(e), "back to the written text")
}
