package editor

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "lsp"
import "textedit"

// Perf phases: opening and saving files on the loader and writer threads
// (file_io.odin, file_load.odin). Frames go on while a large file loads or is
// written, what waits for a file's text lands with it (a jump's place, the
// session's caret and scroll), a file over the size setting waits for the
// user, and a file closed while it loads opens nothing


@(private = "file")
LOAD_LIMIT :: 20 * time.Second // for a load or a write to land

@(private = "file")
BIG_FILE :: "big.txt" // over LARGE_FILE_BYTES, so it opens without language servers

@(private = "file")
BIG_BYTES :: 48 << 20 // loads over several frames


// Opens a file as panes_open_file does and waits for its text: for phases that
// use it at once
@(private)
open_loaded :: proc(path: string) -> ^Pane {
	pane := panes_open_file(path)
	wait_loaded(pane)
	return pane
}


// pane_for_file, waiting for the file's text
@(private)
pane_loaded :: proc(path: string) -> ^Pane {
	pane := pane_for_file(path)
	wait_loaded(pane)
	return pane
}


@(private = "file")
wait_loaded :: proc(pane: ^Pane) {
	e, is_file := pane.content.(^Editor)
	if is_file do editor_wait_loaded(e)
}


// The UI thread's share of loading and saving since the last call, in ms
@(private = "file")
take_io_ms :: proc() -> f64 {
	ms := time.duration_milliseconds(io_ui_time)
	io_ui_time = 0
	return ms
}


// Whether the editor's text begins and ends as `text` does, and is as long
@(private = "file")
same_ends :: proc(e: ^Editor, text: string) -> bool {
	n := buffer.length(&e.buf)
	if n != len(text) do return false

	k := min(n, 4096)
	head := string(buffer.read_alloc(&e.buf, 0, k))
	tail := string(buffer.read_alloc(&e.buf, n - k, n))
	return head == text[:k] && tail == text[n - k:]
}


// Opens the 64 MB file as a click does: frames go on while the loader reads it,
// its pane waits to be drawn, a key typed into it is ignored, and it then shows
// with its text
@(private)
phase_open_large :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	@(static) loading_frames: int
	@(static) waited: bool // not drawn while loading
	@(static) worst: f64   // the UI thread's share in a frame

	worst = max(worst, take_io_ms())

	if frame == 0 {
		close_files()
		loading_frames, waited, worst = 0, true, 0
		since = time.tick_now()
		panes_open_file(path_in_dir(p, "large.odin"))
		return false
	}

	// Loading: typing does nothing, and the pane isn't drawn before its message
	e := focused_editor()
	waiting := time.tick_since(since) < LOAD_LIMIT
	if e.status == .Loading && waiting {
		loading_frames += 1
		editor_text_input(e, "x")
		if !editor_loading_shown(e) && panes_ready() {
			waited = false
		}
		return false
	}
	if e.status == .Text && !e.shown && waiting {
		return false
	}

	result(p, "open until shown", ms_since(since), "ms", 1500)
	check(p, "frames go on while it loads", loading_frames >= 2)
	check(p, "its pane waits to be drawn while it loads", waited)
	shows := e.status == .Text && same_ends(e, p.large_text)
	check(p, "then it shows with its text, nothing typed", shows)
	check(p, "a large file isn't sent to language servers", e.large)
	result(p, "UI thread's share of the load, per frame", worst, "ms", 1)
	return true
}


// Saves the 64 MB file, edited by the phases before: frames go on while it is
// written, it is saved once the write lands, and the watcher doesn't take the
// write for a change
@(private)
phase_save_large :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	@(static) written: time.Tick
	@(static) version: u64
	@(static) writing_frames: int
	@(static) worst: f64

	worst = max(worst, take_io_ms())
	e := focused_editor()

	if frame == 0 {
		since, written = time.tick_now(), {}
		writing_frames, worst = 0, 0
		check(p, "the file has unsaved changes", editor_is_modified(e))

		run_command(.Save)
		check(p, "it isn't saved before the write lands", editor_is_modified(e))
		return false
	}

	// Written
	if written == {} {
		if saves_pending() && time.tick_since(since) < LOAD_LIMIT {
			writing_frames += 1
			return false
		}

		written = time.tick_now()
		version = e.buf.version
		result(p, "save until written", ms_since(since), "ms", 2000)
		check(p, "frames go on while it is written", writing_frames >= 2)

		stamp, _ := file_stamp(e.path)
		saved := !editor_is_modified(e) && stamp.size == i64(buffer.length(&e.buf))
		check(p, "it is saved once written", saved)
		return false
	}

	// Long enough for the watcher to have looked at it
	if time.tick_since(written) < WATCH_QUIET + WATCH_STABLE + time.Second {
		return false
	}

	quiet := !g.dialog.open && e.disk.pending == nil && e.disk.reload == 0
	check(p, "the watcher doesn't take the write for a change", quiet && e.buf.version == version)
	result(p, "UI thread's share of the save, per frame", worst, "ms", 1)
	return true
}


// The 64 MB file restored from the session with its caret and scroll near its
// end: both are put back once it has loaded
@(private)
phase_restore_slow :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	@(static) pane: ^Pane
	@(static) saved: Session_Pane

	if frame == 0 {
		// Saved with the caret on a line near the end, in view
		e := focused_editor()
		line := buffer.line_count(&e.buf) - 200
		saved = {
			file     = strings.clone(e.path),
			caret    = buffer.line_start(&e.buf, line) + 3,
			scroll_y = f64((line - 10) * text_line_height(e)),
		}

		close_files()
		pane = restore_panes({saved})[0]
		pane_show(pane)
		since = time.tick_now()

		loading := pane != nil && pane.content.(^Editor).status == .Loading
		check(p, "the restored file is still loading", loading)
		return false
	}

	e := pane.content.(^Editor)
	waiting := e.status == .Loading || e.status == .Text && !e.shown
	if waiting && time.tick_since(since) < LOAD_LIMIT {
		return false
	}

	caret := e.status == .Text && e.sels[0].head == saved.caret
	check(p, "the session's caret is put back once it loads", caret)
	check(p, "and its scroll", e.target_y == saved.scroll_y && e.scroll_y == saved.scroll_y)
	delete(saved.file)
	return true
}


// A file over the size setting: a dialog asks before it is read, its pane says
// so once it has waited, and Cancel opens nothing, putting back the file it
// would have replaced
@(private)
phase_large_asks :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) since: time.Tick
	@(static) before: ^Pane // the file in use, whose place it takes
	@(static) setting: int

	big := path_in_dir(p, BIG_FILE)
	d := &g.dialog
	pane := pane_with_file(big)

	if frame == 0 {
		text := strings.repeat("0123456789 abcdef\n", BIG_BYTES / 18, context.temp_allocator)
		_ = os.write_entire_file(big, text)

		setting = g.settings.ask_above_mb
		g.settings.ask_above_mb = 1
		before = g.panes.focused
		panes_open_file(big)
		step, since = 0, time.tick_now()
		return false
	}

	switch step {
	case 0: // asked
		_, large := d.purpose.(Opening_Large)
		asking := d.open && large
		if !asking && time.tick_since(since) < LOAD_LIMIT {
			return false
		}

		loading := pane != nil && pane.content.(^Editor).status == .Loading
		check(p, "a file over the limit asks before it is read", asking && loading)
		waits := slice.contains(g.panes.open[:], before) && !pane_shown(before)
		check(p, "the file it takes the place of waits", waits)
		step, since = 1, time.tick_now()

	case 1: // waited
		if time.tick_since(since) < time.Duration(EDITOR_SHOW_WAIT) + 100 * time.Millisecond {
			return false
		}

		e := pane.content.(^Editor)
		says := editor_loading_shown(e) && panes_ready()
		check(p, "and its pane says so once it has waited", says)
		d.choice = d.cancel
		step = 2

	case 2: // cancelled
		if d.open do return false

		check(p, "Cancel opens nothing", pane == nil)
		back := pane_shown(before) && g.panes.focused == before
		check(p, "and the file it would have replaced is back", back)
		g.settings.ask_above_mb = setting
		return true
	}
	return false
}


// A file closed while it loads, before its load starts and while it is under
// way: nothing opens, and the loads stop
@(private)
phase_close_loading :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	@(static) was_loading: bool

	big := path_in_dir(p, BIG_FILE)

	switch frame {
	case 0:
		pane_close(panes_open_file(big), ask = false)
		panes_open_file(big)
		since = time.tick_now()
		return false

	case 1:
		pane := pane_with_file(big)
		was_loading = pane != nil && pane.content.(^Editor).status == .Loading
		if pane != nil do pane_close(pane, ask = false)
		return false
	}

	if !io_loads_done() && time.tick_since(since) < LOAD_LIMIT {
		return false
	}

	check(p, "closed while it loads", was_loading)
	check(p, "a file closed while it loads opens nothing", pane_with_file(big) == nil)
	check(p, "and its load stops", io_loads_done() && !loads_busy())
	return true
}


// Go to definition into a file that isn't open (as jump_to from a server's
// answer): the caret lands on the place once the file has loaded, in view, and
// Go back returns to where it was in the first file, which loads again too
@(private)
phase_jump_closed :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) since: time.Tick
	@(static) back_to: int  // the caret in notes.md before the jump
	@(static) target: lsp.Position

	notes := path_in_dir(p, "notes.md")
	code := path_in_dir(p, "code.odin")

	if frame == 0 {
		close_files()
		open_loaded(notes)
		e := focused_editor()
		at := buffer.line_start(&e.buf, 12) + 2
		textedit.set_single_selection(e, {at, at, -1})
		back_to = e.sels[0].head

		target = {line = 300, character = 4}
		jump_to(code, Lsp_Target{target, .UTF8})
		check(p, "the file isn't open before the jump", pane_with_file(code) == nil)
		step, since = 0, time.tick_now()
		return false
	}

	e := focused_editor()
	waiting := e == nil || e.status == .Loading || !e.shown
	if waiting && time.tick_since(since) < LOAD_LIMIT {
		return false
	}

	switch step {
	case 0: // in code.odin
		if e == nil || !same_path(e.path, code) || g.pending != nil {
			if time.tick_since(since) < LOAD_LIMIT do return false
		}

		ok := e != nil && same_path(e.path, code) && e.status == .Text
		check(p, "go to definition opens the file", ok)
		if !ok do return true

		at := lsp.offset_at(&e.buf, target, .UTF8)
		check(p, "and lands on the place once it has loaded", e.sels[0].head == at)
		caret, shows := e.kind.char_rect(e, at)
		in_view := shows && caret.y >= e.view.y && caret.y + caret.h <= e.view.y + e.view.h
		check(p, "in view", in_view)

		check(p, "Go back", jump_back())
		step, since = 1, time.tick_now()

	case 1: // back in notes.md
		if e == nil || !same_path(e.path, notes) || g.pending != nil {
			if time.tick_since(since) < LOAD_LIMIT do return false
		}

		back := e != nil && same_path(e.path, notes) && e.sels[0].head == back_to
		check(p, "Go back returns to the caret before the jump", back)
		return true
	}
	return false
}
