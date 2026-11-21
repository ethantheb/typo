package editor

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "langs"
import "markdown"
import sdl "../vendor/sdl3"
import "mdview"
import "textedit"

// Opening and saving files without the UI thread waiting on them. An editor
// opens Loading while the loader threads (file_io.odin) read its file, check
// it isn't binary, hash it for the watcher and build its buffer and highlighter
// (tree-sitter's first parse included). When the result lands, the UI thread
// only wires it up (load_landed): Markdown, language servers, the watcher, and
// then what waited for the text (When_Ready: a jump's place, a heading, the
// session's caret and scroll), applied once. A loading pane is drawn empty,
// with "Loading…" once it has waited EDITOR_SHOW_WAIT, and keys typed into it
// are ignored. A file larger than the ask_above_mb setting is only measured
// until the user chooses to open it; Cancel puts back the file it took the
// place of. Files over LARGE_FILE_BYTES open without language servers (sending
// and parsing them is the cost; highlighting and word completions only look at
// what is near the view).
//
// Saving hands a snapshot of the text to the writer thread. The file counts as
// saved once the write lands (save_landed), as the text it wrote: edits made
// meanwhile keep it modified


LARGE_FILE_BYTES :: 20 << 20

// What waits for an editor's text, applied once it is there (editor_when_ready)
When_Ready :: struct {
	target:  Maybe(Open_Target),   // the caret there, in the middle of the view (a jump)
	heading: string,               // owned; a Markdown heading or footnote to go to
	restore: Maybe(Restored_View), // the caret and scroll the session saved
}

Restored_View :: struct {
	caret:    int,
	scroll_y: f64,
	scroll_x: f32,
}

// An editor's file being read
Load_State :: struct {
	id:       u64,  // the load under way; results of others are dropped
	size:     i64,  // the file's size, once measured
	sized:    bool,
	ask:      enum {
		None,
		Waiting, // too large: the question waits for no other dialog to be open
		Asked,
	},
	ready:    When_Ready,
	replaced: ^Pane, // the file it took the place of: closed once this one loads, unless edited
}

// An editor's write under way
Save_State :: struct {
	id:     u64,  // the write, or 0
	again:  bool, // saved again meanwhile: written once this write lands
	failed: bool, // the last write failed
}

// Editors with a load or a write under way
@(private = "file")
waiting: [dynamic]^Editor

@(private = "file")
next_job: u64

io_ui_time: time.Duration // spent here since the perf suite last looked

@(private = "file")
io_timing: int // nesting of io_timed_begin


// Marks the UI thread's share of opening and saving files (io_ui_time), which
// the perf suite limits per frame. Nested calls count once
@(private = "file")
io_timed_begin :: proc() -> time.Tick {
	io_timing += 1
	return time.tick_now()
}


@(private = "file")
io_timed_end :: proc(start: time.Tick) {
	io_timing -= 1
	if io_timing == 0 do io_ui_time += time.tick_since(start)
}


// --- Opening -----------------------------------------------------------------------

// Opens a file in the editor: it is Loading until the loader's result lands.
// A path that doesn't exist opens as an empty, unsaved file
editor_open :: proc(e: ^Editor, path: string) {
	editor_close(e)
	editor_attach(e)
	e.path = strings.clone(path)
	e.status = .Loading
	e.opened_at = sdl.GetTicksNS()
	append(&waiting, e)

	load_post(e, ask = true)
}


// Asks the loader for the editor's file, again if it was asked before
@(private = "file")
load_post :: proc(e: ^Editor, ask: bool) {
	start := io_timed_begin()
	defer io_timed_end(start)

	if e.load.id != 0 do io_cancel_load(e.load.id)

	next_job += 1
	e.load.id = next_job

	ask_above := i64(g.settings.ask_above_mb) << 20
	job := Load_Job {
		id        = e.load.id,
		path      = strings.clone(e.path),
		ask_above = ask ? ask_above : 0,
	}
	if r, done := io_post_load(job); done {
		load_landed(e, &r)
	}
}


// After the file of a loading editor was renamed to e.path: it is read from
// there
editor_load_moved :: proc(e: ^Editor) {
	if e.status != .Loading do return

	e.load.ask = .None
	load_post(e, ask = true)
}


// Applies what waits for the editor's text, now or once it has loaded (taking
// w's heading). Later waiting replaces earlier where both set something
editor_when_ready :: proc(e: ^Editor, w: When_Ready) {
	w := w
	switch e.status {
	case .Loading:
		ready := &e.load.ready
		if w.target != nil do ready.target = w.target
		if w.restore != nil do ready.restore = w.restore
		if w.heading != "" {
			delete(ready.heading)
			ready.heading = w.heading
		}

	case .Text:
		when_ready_apply(e, w)
		delete(w.heading)

	case .None, .Binary, .Error:
		delete(w.heading)
	}
}


@(private = "file")
when_ready_apply :: proc(e: ^Editor, w: When_Ready) {
	if r, ok := w.restore.?; ok {
		at := caret_in(&e.buf, r.caret)
		textedit.set_single_selection(e, {at, at, -1})
		e.scroll_y, e.target_y = r.scroll_y, r.scroll_y
		e.scroll_x, e.target_x = r.scroll_x, r.scroll_x
	}

	if e.md != nil && w.heading != "" {
		mdview.jump_to_heading(&e.md_view, w.heading)
	}

	if target, ok := w.target.?; ok {
		apply_open_target(e, target)
	}
}


// A caret the session saved, in a file that may have changed: not past its
// end, and not inside a character
@(private = "file")
caret_in :: proc(b: ^buffer.Buffer, saved: int) -> int {
	length := buffer.length(b)
	at := clamp(saved, 0, length)

	for at > 0 && at < length && buffer.byte_at(b, at) & 0xC0 == 0x80 {
		at -= 1
	}
	return at
}


// The loader's result for a loading editor (taken)
@(private = "file")
load_landed :: proc(e: ^Editor, r: ^Load_Result) {
	switch r.status {
	case .Too_Large:
		e.load.size, e.load.sized = r.size, true
		e.load.ask = .Waiting
		return
	case .Text, .New_File:
		editor_wire(e, r)
	case .Binary:
		e.status = .Binary
	case .Error:
		e.status = .Error
	}

	// The file it took the place of goes, unless shown again meanwhile
	if q := e.load.replaced; q != nil && !pane_shown(q) && !pane_modified(q) {
		e.load.replaced = nil
		pane_close(q, ask = false)
	}
	load_state_reset(e)
	stop_waiting(e)
}


// Makes the loaded document the editor's: highlighting, Markdown, the watcher,
// language servers, then what waited for its text
@(private = "file")
editor_wire :: proc(e: ^Editor, r: ^Load_Result) {
	e.buf = r.buf
	e.hl = r.hl
	e.new_file = r.status == .New_File
	e.large = buffer.length(&e.buf) > LARGE_FILE_BYTES
	e.status = .Text
	e.opened_at = sdl.GetTicksNS()
	append(&e.sels, Selection{0, 0, -1})
	disk_opened(e, r.hash, r.stamp, exists = !e.new_file)
	r^ = {}

	if is_markdown_path(e.path) {
		e.md = new(markdown.Doc)
		markdown.doc_open(e.md, &e.buf)
		mdview.attach(&e.md_view, e, e.md, &TEXT_KIND, md_initial_mode(e))
	}
	lsp_doc_open(e)

	when_ready_apply(e, e.load.ready)
}


@(private = "file")
load_state_reset :: proc(e: ^Editor) {
	delete(e.load.ready.heading)
	e.load = {}
}


// The editor closes: its load stops (its result is dropped and freed), and a
// write under way finishes without it
editor_io_close :: proc(e: ^Editor) {
	if e.load.id != 0 do io_cancel_load(e.load.id)
	load_state_reset(e)
	e.save = {}
	stop_waiting(e)
}


@(private = "file")
stop_waiting :: proc(e: ^Editor) {
	if e.load.id != 0 || e.save.id != 0 {
		return
	}

	if i, found := slice.linear_search(waiting[:], e); found {
		unordered_remove(&waiting, i)
	}

	// Nothing kept while nothing waits
	if len(waiting) == 0 do file_load_destroy()
}


// The editor with this load under way
@(private = "file")
editor_loading :: proc(id: u64) -> ^Editor {
	for e in waiting {
		if e.load.id == id do return e
	}
	return nil
}


// --- A large file ------------------------------------------------------------------

// Asks about the first file too large to open unasked, once no other dialog is
// open
@(private = "file")
ask_about_large :: proc() {
	if g.dialog.open do return

	for e in waiting {
		if e.load.ask != .Waiting do continue

		e.load.ask = .Asked
		message := fmt.tprintf(
			"%s is %s. Opening it takes at least that much memory.",
			filepath.base(e.path),
			size_text(e.load.size),
		)
		dialog_show(
			"Open a large file?",
			message,
			.Alert,
			{{"Open", .Primary}, {"Cancel", .Normal}},
			focus = 0,
			cancel = 1,
			purpose = Opening_Large{e.load.id},
		)
		return
	}
}


// The answer about a large file: it is read, or its pane closes and the file
// it took the place of comes back
large_file_answer :: proc(id: u64, open: bool) {
	e := editor_loading(id)
	if e == nil do return

	if open {
		e.load.ask = .None
		load_post(e, ask = false)
		return
	}

	p := pane_of_editor(e)
	if p == nil {
		editor_close(e)
		return
	}

	// pane_move closes p when q takes its place
	q := e.load.replaced
	e.load.replaced = nil
	if q != nil && !pane_shown(q) && pane_shown(p) {
		focused := g.panes.focused == p
		pane_move(q, {kind = .Swap, target = p})
		if focused do pane_focus(q)
	} else {
		pane_close(p, ask = false)
	}
}


// "64.0 MB"
size_text :: proc(size: i64) -> string {
	switch {
	case size >= 1 << 30: return fmt.tprintf("%.1f GB", f64(size) / (1 << 30))
	case size >= 1 << 20: return fmt.tprintf("%.1f MB", f64(size) / (1 << 20))
	case size >= 1 << 10: return fmt.tprintf("%.0f KB", f64(size) / (1 << 10))
	}
	return fmt.tprintf("%d bytes", size)
}


// The pane showing an editor, if any
@(private = "file")
pane_of_editor :: proc(e: ^Editor) -> ^Pane {
	for p in g.panes.open {
		if c, ok := p.content.(^Editor); ok && c == e {
			return p
		}
	}
	return nil
}


// After a pane closed: loading editors no longer keep it to put back
loads_forget_pane :: proc(p: ^Pane) {
	for e in waiting {
		if e.load.replaced == p do e.load.replaced = nil
	}
}


// --- The loading message -----------------------------------------------------------

// Whether a loading editor shows "Loading…": once it has waited EDITOR_SHOW_WAIT
editor_loading_shown :: proc(e: ^Editor) -> bool {
	return e.status == .Loading && sdl.GetTicksNS() - e.opened_at > EDITOR_SHOW_WAIT
}


// "Loading notes.md… 64.0 MB", for the loading pane
loading_message :: proc(e: ^Editor) -> string {
	name := filepath.base(e.path)
	if e.load.ask != .None {
		return fmt.tprintf("%s is waiting to open", name)
	}
	if !e.load.sized {
		return fmt.tprintf("Loading %s…", name)
	}
	return fmt.tprintf("Loading %s… %s", name, size_text(e.load.size))
}


// Whether frames should keep coming: a loading editor has yet to show its
// message
loads_busy :: proc() -> bool {
	for e in waiting {
		if e.status == .Loading && !editor_loading_shown(e) {
			return true
		}
	}
	return false
}


// --- Saving ------------------------------------------------------------------------

// Starts writing the editor's text to its file (see Save_State). Returns false
// if there is nothing to write. A save asked for while one is under way is
// written once that one lands
editor_save :: proc(e: ^Editor) -> bool {
	if e.status != .Text do return false
	if e.save.id != 0 {
		e.save.again = true
		return true
	}

	start := io_timed_begin()
	defer io_timed_end(start)

	next_job += 1
	e.save = {id = next_job}
	if !slice.contains(waiting[:], e) do append(&waiting, e)

	buffer.begin_save(&e.buf)
	job := Write_Job {
		id        = e.save.id,
		path      = strings.clone(e.path),
		text      = buffer.snapshot(&e.buf),
		make_dirs = e.new_file || e.disk.missing,
	}
	if r, done := io_post_write(job); done {
		save_landed(e, r)
		return !e.save.failed
	}
	return true
}


// Whether files are being written, or will be once a write under way lands
saves_pending :: proc() -> bool {
	for e in waiting {
		if e.save.id != 0 do return true
	}
	return io_writing()
}


// The writer's result for an editor (taken). Written at the editor's path, the
// text written is the saved state; a failure is shown
@(private = "file")
save_landed :: proc(e: ^Editor, r: Write_Result) {
	defer delete(r.path)
	defer delete(r.problem)

	// Renamed while it was written: the file at its path isn't this text
	ok := r.ok && same_path(r.path, e.path)
	buffer.end_save(&e.buf, ok)
	e.save.id = 0
	e.save.failed = !ok

	if ok {
		disk_saved(e, r.hash, r.stamp, r.generation)
		langs.doc_saved(&e.lsp)
	} else if r.problem != "" {
		save_failed(e, r.problem)
	}

	if e.save.again {
		e.save.again = false
		editor_save(e)
	}
	stop_waiting(e)
}


// Shows why a file couldn't be saved, unless the unsaved-changes flow says so
@(private = "file")
save_failed :: proc(e: ^Editor, problem: string) {
	if unsaved_save_failed(e, problem) do return

	message := fmt.tprintf("%s could not be saved: %s.", relative_to_root(e.path), problem)
	show_notice("Couldn't save", message)
}


// The editor with this write under way
@(private = "file")
editor_saving :: proc(id: u64) -> ^Editor {
	for e in waiting {
		if e.save.id == id do return e
	}
	return nil
}


// --- Per frame ---------------------------------------------------------------------

// Applies the loader's and writer's results, and asks about a large file once
// no other dialog is open
file_load_frame :: proc() {
	start := io_timed_begin()
	defer io_timed_end(start)

	for &r in io_take() {
		switch &r in r {
		case Load_Sized:
			if e := editor_loading(r.id); e != nil {
				e.load.size, e.load.sized = r.size, true
			}

		case Load_Result:
			e := editor_loading(r.id)
			if e == nil {
				load_result_destroy(&r)
				continue
			}
			load_landed(e, &r)

		case Write_Result:
			e := editor_saving(r.id)
			if e == nil {
				io_result_destroy(r)
				continue
			}
			save_landed(e, r)
		}
	}

	ask_about_large()
}


// Waits for the editor's file to load, applying results meanwhile: for tests
// and the perf suite, which need its text at once. Stops at a large file's
// question
editor_wait_loaded :: proc(e: ^Editor) {
	for e.status == .Loading && e.load.ask == .None {
		file_load_frame()
		if e.status == .Loading do time.sleep(time.Millisecond)
	}
}


// Waits for every write under way to land, applying results meanwhile
wait_for_saves :: proc() {
	for saves_pending() {
		file_load_frame()
		if saves_pending() do time.sleep(time.Millisecond)
	}
}


file_load_destroy :: proc() {
	delete(waiting)
	waiting = {}
}
