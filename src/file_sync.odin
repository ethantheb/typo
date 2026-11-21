package editor

import "core:fmt"
import "core:strings"
import "core:time"

import "buffer"
import "diff"
import "textedit"

// What the watcher found (fs_watch.odin), applied on the UI thread. The tree's
// loaded folders and the finder's index follow files other programs add,
// remove and rename. Open files follow their changes on disk:
//  - Without unsaved edits, a file reloads quietly: the watcher diffs the new
//    version against the editor's text, and the changed lines are replaced as
//    one undo step (textedit.apply_edits), so carets, scroll, highlighting,
//    Markdown and language servers follow as with any edit.
//  - With unsaved edits, a dialog asks: reload from disk (one undo step back to
//    the edits), or keep them.
//  - A deleted or moved-away file keeps its text and counts as unsaved,
//    "(deleted)" in the status bar; saving writes it again. If it comes back,
//    that is a change like any other.
//  - Saving over a version on disk typo hasn't read asks first.


// An editor's file on disk
Disk_State :: struct {
	path:       string,     // owned; what the watcher knows the file by ("" for none)
	generation: u32,        // the watcher's, as of the last read or write
	hash:       u64,        // of the text last read or written
	stamp:      File_Stamp, // the file's then, or of a version the user kept theirs over
	missing:    bool,       // deleted or moved away
	pending:    Maybe(Disk_Version), // a newer version waiting for the user's choice
	reload:     int,                 // the reload under way (its serial), or 0
}

watch_ui_time: time.Duration // spent here since the perf suite last looked

@(private = "file")
pushed_dirs := -1 // the tree's loaded_version last given to the watcher

@(private = "file")
reload_serial: int


// Per frame: applies the watcher's results, and asks about a file changed on
// disk under unsaved edits once no other dialog is open
file_sync_frame :: proc() {
	start := time.tick_now()
	defer watch_ui_time += time.tick_since(start)

	// The folders whose changes the tree shows
	ws := &g.workspace
	if ws.loaded_version != pushed_dirs {
		watch_set_dirs(workspace_loaded_dirs(ws))
		pushed_dirs = ws.loaded_version
	}

	for r in watch_take() {
		switch r in r {
		case Watch_Batch:  apply_batch(r)
		case File_Changed: file_changed(r)
		case File_Missing: file_missing(r)
		case Reload_Ready: reload_ready(r)
		}
	}

	ask_about_change()
}


// --- An editor's file --------------------------------------------------------------

// After an editor read its file (`exists` false for a new one): the watcher
// starts watching it
disk_opened :: proc(e: ^Editor, hash: u64, stamp: File_Stamp, exists: bool) {
	e.disk = {
		path    = strings.clone(e.path),
		hash    = hash,
		stamp   = stamp,
		missing = false,
	}
	e.disk.generation = watch_file_open(e.path, hash, stamp, exists)
}


// After the writer wrote the editor's file: the hash of what it wrote, the
// file's stamp then, and the watcher's generation it was told the write in
disk_saved :: proc(e: ^Editor, hash: u64, stamp: File_Stamp, generation: u32) {
	drop_pending(e)
	e.disk.reload = 0
	e.disk.hash = hash
	e.disk.stamp = stamp
	e.disk.missing = false
	e.disk.generation = generation
	e.new_file = false
}


disk_closed :: proc(e: ^Editor) {
	if e.disk.path != "" do unwatch_file(e.disk.path)
	drop_pending(e)
	delete(e.disk.path)
	e.disk = {}
}


// After the file was renamed to e.path: it is watched under its new path
disk_path_changed :: proc(e: ^Editor) {
	if e.disk.path == e.path do return

	unwatch_file(e.disk.path)
	delete(e.disk.path)
	e.disk.path = strings.clone(e.path)

	stamp, exists := file_stamp(e.path)
	e.disk.stamp = stamp
	e.disk.generation = watch_file_open(e.path, e.disk.hash, stamp, exists)
}


// Saves, first asking if the file changed on disk since typo read it
save_or_ask :: proc(e: ^Editor) {
	if !changed_since_read(e) {
		editor_save(e)
		return
	}

	message := fmt.tprintf(
		"%s changed on disk since it was read. Save your version over it?",
		relative_to_root(e.path),
	)
	dialog_show(
		"Changed on disk",
		message,
		.Alert,
		{{"Save over it", .Danger}, {"Cancel", .Normal}},
		focus = 1,
		cancel = 1,
		purpose = Overwriting{strings.clone(e.disk.path)},
	)
}


// The answer to save_or_ask's dialog
overwrite_answer :: proc(path: string, confirmed: bool) {
	if !confirmed do return

	if e := editor_watching(path); e != nil {
		editor_save(e)
	}
}


// The answer to the dialog about a change under unsaved edits: reload, or keep
// the edits
reload_answer :: proc(path: string, reload: bool) {
	e := editor_watching(path)
	if e == nil do return

	version, waiting := e.disk.pending.?
	if !waiting do return
	e.disk.pending = nil

	if reload {
		start_reload(e, version)
		return
	}

	// The version on disk isn't a change anymore; saving replaces it unasked
	e.disk.stamp = version.stamp
	watch_file_kept(e.disk.path, version.stamp)
	delete(version.data)
}


// Whether the file on disk isn't the one typo last read or wrote: a version
// is waiting for an answer, or the file's size or time differ
@(private = "file")
changed_since_read :: proc(e: ^Editor) -> bool {
	if e.disk.pending != nil do return true
	if e.new_file || e.disk.missing {
		return false
	}

	stamp, exists := file_stamp(e.path)
	return exists && stamp != e.disk.stamp
}


// The editor's text is the file's again, after a write or a reload
@(private = "file")
disk_synced :: proc(e: ^Editor, hash: u64, stamp: File_Stamp) {
	e.disk.hash = hash
	e.disk.stamp = stamp
	e.disk.missing = false
	e.new_file = false
	e.disk.generation = watch_file_synced(e.disk.path, hash, stamp)
}


@(private = "file")
drop_pending :: proc(e: ^Editor) {
	if version, waiting := e.disk.pending.?; waiting {
		delete(version.data)
	}
	e.disk.pending = nil
}


// The open editor whose file the watcher knows by `path`
@(private = "file")
editor_watching :: proc(path: string) -> ^Editor {
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if is_editor && e.status == .Text && e.disk.path == path {
			return e
		}
	}
	return nil
}


// --- Results -----------------------------------------------------------------------

@(private = "file")
apply_batch :: proc(r: Watch_Batch) {
	workspace_apply_listings(&g.workspace, r.listings)
	if r.structure do finder_files_changed()
	watch_result_destroy(r)
}


@(private = "file")
file_changed :: proc(r: File_Changed) {
	e := editor_watching(r.path)
	delete(r.path)
	if e == nil || r.generation != e.disk.generation {
		delete(r.version.data)
		return
	}

	// Back after it was missing, as typo last had it
	e.disk.missing = false
	if r.same {
		e.disk.stamp = r.version.stamp
		delete(r.version.data)
		return
	}

	version_arrived(e, r.version)
}


@(private = "file")
file_missing :: proc(r: File_Missing) {
	e := editor_watching(r.path)
	delete(r.path)
	if e == nil || r.generation != e.disk.generation {
		return
	}

	e.disk.missing = true
	e.disk.reload = 0
	drop_pending(e)
}


// A new version of the editor's file: reloaded at once without unsaved edits,
// else kept for the user to decide
@(private = "file")
version_arrived :: proc(e: ^Editor, version: Disk_Version) {
	drop_pending(e)
	if buffer.is_modified(&e.buf) {
		e.disk.pending = version
		e.disk.reload = 0
		return
	}
	start_reload(e, version)
}


// Asks the watcher to diff the version against a snapshot of the editor's text
@(private = "file")
start_reload :: proc(e: ^Editor, version: Disk_Version) {
	reload_serial += 1
	e.disk.reload = reload_serial

	job := Reload_Job {
		path    = strings.clone(e.disk.path),
		serial  = reload_serial,
		old     = buffer.snapshot(&e.buf),
		version = version,
	}
	watch_post_job(job)
}


// A diff is ready: its hunks become one undo step, unless the text changed since
// it was asked for (then the version arrives again) or a newer one replaced it
@(private = "file")
reload_ready :: proc(r: Reload_Ready) {
	defer delete(r.path)
	defer delete(r.hunks)

	e := editor_watching(r.path)
	if e == nil || r.serial != e.disk.reload {
		delete(r.version.data)
		return
	}
	e.disk.reload = 0

	if e.buf.version != r.buffer_version {
		version_arrived(e, r.version)
		return
	}

	reload_apply(e, r.hunks, r.version.data)
	disk_synced(e, r.version.hash, r.version.stamp)
	delete(r.version.data)
}


// Turns the editor's text into `data` (the file's) with the hunks of their diff,
// as one undo step. Carets and scroll stay where they were in the text
@(private)
reload_apply :: proc(e: ^Editor, hunks: []diff.Hunk, data: []u8) {
	edits := make([]textedit.Text_Edit, len(hunks), context.temp_allocator)
	for h, i in hunks {
		edits[i] = {lo = h.old_lo, hi = h.old_hi, text = string(data[h.new_lo:h.new_hi])}
	}
	textedit.apply_edits(e, .Other, edits, reveal = false)
	buffer.mark_saved(&e.buf)
}


// Shows the dialog for the first file with a version waiting, if no dialog is
// open
@(private = "file")
ask_about_change :: proc() {
	if g.dialog.open do return

	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if !is_editor || e.status != .Text || e.disk.pending == nil {
			continue
		}

		message := fmt.tprintf(
			"%s changed on disk, and you have unsaved changes to it. %s",
			relative_to_root(e.path),
			"Reload it from disk (Undo brings your changes back), or keep your version?",
		)
		dialog_show(
			"Changed on disk",
			message,
			.Alert,
			{{"Reload", .Normal}, {"Keep my version", .Primary}},
			focus = 1,
			cancel = 1,
			purpose = Reloading{strings.clone(e.disk.path)},
		)
		return
	}
}
