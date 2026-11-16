package editor

// Workspace edits from language servers: a rename's answer, or a server's
// workspace/applyEdit. Files open in an editor are edited there, one undo step
// each, and left unsaved. Files that aren't open are rewritten on disk, after a
// dialog says how many, on a thread of their own (each only if it is still as
// the server read it). Nothing changes if an open file changed since the server
// worked the edit out. A server's request is answered once it is all done

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import "buffer"
import "langs"
import "lsp"
import "textedit"


Lsp_Edits :: struct {
	active:  bool,         // an edit waits for the dialog or for its files
	pending: Pending_Edit,
	writer:  ^thread.Thread,
	writing: File_Writing,
}

// An edit being applied
Pending_Edit :: struct {
	edit:   lsp.Workspace_Edit, // owned
	client: ^langs.Client,        // the server it is from
	conn:   ^lsp.Client,        // the client as it ran then: only it gets the answer
	reply:  string,             // owned; the workspace/applyEdit's id, "" for a rename
	what:   string,             // owned; "The rename", or the server's label
}

// The files the writer thread rewrites, and how it went
File_Writing :: struct {
	files:  []lsp.File_Edit,        // the pending edit's files that aren't open
	failed: [dynamic]Write_Failure, // filled by the thread
	done:   bool,                   // set by the thread when it finished
}

Write_Failure :: struct {
	index:  int,    // in files
	reason: string, // not owned (write_file_edit's constants)
}


// Applies an edit (taking it over): `reply` is the id of the server's request
// to answer, "" for a rename
lsp_apply_workspace_edit :: proc(c: ^langs.Client, edit: lsp.Workspace_Edit, reply, what: string) {
	langs.timed()
	edit := edit
	ed := &g.lsp.edits

	// One at a time
	if ed.active {
		answer(c, c.client, reply, false, "another edit is being applied")
		lsp.workspace_edit_destroy(&edit)
		return
	}

	ed.active = true
	ed.pending = {
		edit   = edit,
		client = c,
		conn   = c.client,
		reply  = strings.clone(reply),
		what   = strings.clone(what),
	}

	problem := check_edit(&ed.pending.edit)
	if problem != "" {
		finish(false, problem)
		return
	}

	// Files on disk: asked first, unless a dialog is up already
	on_disk := files_on_disk(&ed.pending.edit)
	if len(on_disk) == 0 {
		edit_open_files(&ed.pending.edit)
		finish(true, "")
		return
	}
	if g.dialog.open {
		finish(false, "a dialog is open")
		return
	}

	message := fmt.tprintf(
		"%s also changes %d %s that %s open. %s changed on disk, which undo can't take back.",
		ed.pending.what,
		len(on_disk),
		len(on_disk) == 1 ? "file" : "files",
		len(on_disk) == 1 ? "isn't" : "aren't",
		len(on_disk) == 1 ? "It is" : "They are",
	)
	buttons := []Dialog_Button{{"Change files", .Primary}, {"Cancel", .Normal}}
	dialog_show("Change files that aren't open?", message, .Alert, buttons, 0, 1, Applying_Edit{})
}


// The dialog's answer: the edit is made, or dropped
lsp_edit_confirmed :: proc(confirmed: bool) {
	ed := &g.lsp.edits
	if !ed.active || ed.writer != nil {
		return
	}
	if !confirmed {
		finish(false, "the user declined")
		return
	}

	// Things may have changed while the dialog was open
	problem := check_edit(&ed.pending.edit)
	if problem != "" {
		finish(false, problem)
		return
	}

	edit_open_files(&ed.pending.edit)
	start_writing(files_on_disk(&ed.pending.edit))
}


// Each frame: an edit whose dialog went away is dropped; once its files are
// written, the edit is done
lsp_edits_frame :: proc() {
	ed := &g.lsp.edits
	if !ed.active do return

	if ed.writer == nil {
		_, asking := g.dialog.purpose.(Applying_Edit)
		if !g.dialog.open || !asking {
			finish(false, "the user declined")
		}
		return
	}

	if !sync.atomic_load(&ed.writing.done) do return
	thread.destroy(ed.writer)
	ed.writer = nil

	// The server is told which files changed
	w := &ed.writing
	written := make([dynamic]string, context.temp_allocator)
	for fe, i in w.files {
		if !write_failed(w, i) do append(&written, fe.path)
	}
	p := &ed.pending
	running := p.client != nil && p.conn == p.client.client && p.client.state == .Running
	if len(written) > 0 && running {
		lsp.client_files_changed(p.conn, written[:])
	}

	if len(w.failed) == 0 {
		finish(true, "")
		return
	}

	// The files that couldn't be changed
	lines := make([dynamic]string, context.temp_allocator)
	for f in w.failed {
		name := relative_to_root(w.files[f.index].path)
		append(&lines, fmt.tprintf("%s: %s", name, f.reason))
	}
	list := strings.join(lines[:], "\n", context.temp_allocator)
	if !g.dialog.open do show_notice("Some files weren't changed", list)
	finish(false, list, quiet = true)
}


// The server's workspace/applyEdit: made, then answered
lsp_apply_edit_request :: proc(c: ^langs.Client, x: ^lsp.Apply_Edit) {
	what := x.label != "" ? x.label : fmt.tprintf("A change from %s", c.name)
	lsp_apply_workspace_edit(c, x.edit, x.id, what)
	x.edit = {}
}


// A client is going away: an edit from it is no longer answered
lsp_edits_forget_client :: proc(c: ^langs.Client) {
	ed := &g.lsp.edits
	if ed.active && ed.pending.client == c {
		ed.pending.client = nil
		ed.pending.conn = nil
	}
}


lsp_edits_destroy :: proc() {
	ed := &g.lsp.edits
	if ed.writer != nil {
		thread.destroy(ed.writer) // waits for it
		ed.writer = nil
	}
	if ed.active do finish(false, "typo is closing", quiet = true)
	delete(ed.writing.failed)
	ed^ = {}
}


// Why an edit can't be made now, or "": an open file changed since the server
// read it, or a file open in an editor (but not on the server) has unsaved
// changes or isn't what the server read
@(private = "file")
check_edit :: proc(edit: ^lsp.Workspace_Edit) -> string {
	for fe in edit.files {
		e := editor_with_path(fe.path)
		name := relative_to_root(fe.path)

		switch {
		case fe.open:
			changed := e == nil || e.status != .Text || e.buf.version != fe.version || fe.stale
			if changed do return fmt.tprintf("%s changed since the edit was worked out", name)
		case e != nil:
			if e.status != .Text || editor_is_modified(e) {
				return fmt.tprintf("%s has unsaved changes", name)
			}
			if buffer.length(&e.buf) != fe.size {
				return fmt.tprintf("%s isn't as the server read it", name)
			}
		}
	}
	return ""
}


// The files of an edit that no editor has open (temp)
@(private = "file")
files_on_disk :: proc(edit: ^lsp.Workspace_Edit) -> []lsp.File_Edit {
	out := make([dynamic]lsp.File_Edit, context.temp_allocator)
	for fe in edit.files {
		if !fe.open && editor_with_path(fe.path) == nil {
			append(&out, fe)
		}
	}
	return out[:]
}


// Edits the files open in editors, each as one undo step; the carets stay
// where they are in the text
@(private = "file")
edit_open_files :: proc(edit: ^lsp.Workspace_Edit) {
	for fe in edit.files {
		e := editor_with_path(fe.path)
		if e == nil do continue

		length := buffer.length(&e.buf)
		edits := make([]textedit.Text_Edit, len(fe.edits), context.temp_allocator)
		for x, i in fe.edits {
			lo := clamp(x.offset, 0, length)
			hi := clamp(x.offset + x.old_len, lo, length)
			edits[i] = {lo = lo, hi = hi, text = x.text}
		}
		textedit.apply_edits(e, .Other, edits, reveal = false)
	}
}


// Rewrites the files on a thread; lsp_edits_frame sees when it is done
@(private = "file")
start_writing :: proc(files: []lsp.File_Edit) {
	ed := &g.lsp.edits
	w := &ed.writing
	delete(w.files)
	w.files = make([]lsp.File_Edit, len(files))
	copy(w.files, files)
	clear(&w.failed)
	w.done = false

	ed.writer = thread.create_and_start_with_poly_data(w, write_files, context)
}


// The writer thread
@(private = "file")
write_files :: proc(w: ^File_Writing) {
	for fe, i in w.files {
		reason := lsp.write_file_edit(fe)
		if reason != "" do append(&w.failed, Write_Failure{i, reason})
		free_all(context.temp_allocator)
	}

	sync.atomic_store(&w.done, true)
	wake_main_loop(nil)
}


@(private = "file")
write_failed :: proc(w: ^File_Writing, index: int) -> bool {
	for f in w.failed {
		if f.index == index do return true
	}
	return false
}


// The edit is done or dropped: the server's request is answered, and a rename
// that couldn't be made says why
@(private = "file")
finish :: proc(applied: bool, reason: string, quiet := false) {
	ed := &g.lsp.edits
	p := &ed.pending
	answer(p.client, p.conn, p.reply, applied, reason)

	// Not over another dialog (e.g. the unsaved-changes flow would be lost)
	declined := reason == "the user declined"
	tell := !applied && !declined && !quiet && p.reply == ""
	if tell && !g.dialog.open {
		message := fmt.tprintf("%s wasn't made: %s.", p.what, reason)
		show_notice("Couldn't rename", message)
	}

	lsp.workspace_edit_destroy(&p.edit)
	delete(p.reply)
	delete(p.what)
	clear(&ed.writing.failed)
	delete(ed.writing.files)
	ed.writing.files = nil
	ed.pending = {}
	ed.active = false
}


// Answers a server's workspace/applyEdit (`reply` is its id; "" for none),
// if the client that asked still runs
@(private = "file")
answer :: proc(c: ^langs.Client, conn: ^lsp.Client, reply: string, applied: bool, reason: string) {
	if reply == "" || c == nil || conn != c.client || c.state != .Running {
		return
	}
	lsp.reply_apply_edit(conn, reply, applied, applied ? "" : reason)
}
