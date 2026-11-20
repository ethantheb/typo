package langs

// An open file's document on its language servers: attached to each server of
// its language once the server's program and the file's project root are
// known, opened on it (a copy of the text, handed to the client's thread), kept
// in step with each frame's edits, saved and closed with the file

import "core:slice"
import "core:strings"

import "../buffer"
import "../lsp"
import "../textedit"


// A file's document, on each server that serves its language
Doc :: struct {
	view:     ^textedit.View, // the file's text and path (set by the app)
	uri:      string,         // owned
	language: string,         // owned; the LSP language id
	clients:  [dynamic]Doc_Client,        // in the servers' order of preference
	edits:    [dynamic]Doc_Edit,          // the latest edits, for problems about older text
	problems: [dynamic]lsp.Problem,       // every client's, sorted by start (not owned)
	marks:    [dynamic]textedit.Problem,  // the same, as the view underlines them
}

Doc_Client :: struct {
	client:   ^Client,
	opened:   bool,          // sent to the client as it runs now
	problems: []lsp.Problem, // owned, with their strings; sorted by start
}

// An edit of the buffer, and the version it made
Doc_Edit :: struct {
	version: u64,
	offset:  int,
	old_len: int,
	new_len: int,
}

// Larger files aren't given to servers
@(private = "file")
MAX_DOC_BYTES :: 16 * 1024 * 1024

// Edits kept for problems that arrive about older text (a server's thread is
// at most a few frames behind)
@(private = "file")
MAX_DOC_EDITS :: 256


// After a file opened (or was renamed), or a lookup was answered: attaches its
// document to the servers of its language it doesn't use yet, starting them if
// needed. Servers whose program or root is still being looked up come later
doc_open :: proc(d: ^Doc) {
	timed()

	if !state.active || !env.config().enabled || d.view == nil {
		return
	}
	v := d.view
	if buffer.length(&v.buf) > MAX_DOC_BYTES do return

	language := lsp.language_for_path(v.path, state.languages[:])
	if language == "" do return

	attached := false
	for &s in state.servers {
		if !s.enabled || !lsp.serves(s, language) {
			continue
		}

		path, _ := server_path(&s)
		if path == "" do continue
		r, known := root(&s, v.path)
		if !known do continue

		c := client_for(&s, r)
		if c.stopped_by_user || uses_client(d, c) {
			continue
		}

		append(&d.clients, Doc_Client{client = c})
		attached = true
	}
	if !attached do return

	if d.uri == "" {
		d.uri = lsp.uri_from_path(v.path)
		d.language = strings.clone(language)
	}
	slice.sort_by(d.clients[:], preferred_first)
	doc_open_pending(d)
}


@(private = "file")
uses_client :: proc(d: ^Doc, c: ^Client) -> bool {
	for dc in d.clients {
		if dc.client == c do return true
	}
	return false
}


@(private = "file")
preferred_first :: proc(a, b: Doc_Client) -> bool {
	return server_rank(a.client.name) < server_rank(b.client.name)
}


@(private = "file")
server_rank :: proc(name: string) -> int {
	for s, i in state.servers {
		if s.name == name do return i
	}
	return len(state.servers)
}


// Before a file closes (or is renamed): closes its document on its servers
doc_close :: proc(d: ^Doc) {
	timed()
	env.doc_closing(d)
	for dc in d.clients {
		if dc.opened do lsp.client_close(dc.client.client, d.uri)
	}

	problems_clear(d)
	requests_forget(d)
	delete(d.uri)
	delete(d.language)
	delete(d.clients)
	delete(d.edits)
	view := d.view
	d^ = {view = view}
}


// The frame's edits, recorded and sent to each client the document is open on
doc_changed :: proc(d: ^Doc, changes: []buffer.Change) {
	if len(changes) == 0 || len(d.clients) == 0 {
		return
	}

	timed()
	buf := &d.view.buf

	// Each with the version it made
	first := buf.version - u64(len(changes))
	for c, i in changes {
		append(&d.edits, Doc_Edit{first + u64(i) + 1, c.offset, c.old_len, c.new_len})
	}
	if len(d.edits) > 2 * MAX_DOC_EDITS {
		remove_range(&d.edits, 0, len(d.edits) - MAX_DOC_EDITS)
	}

	problems_edited(d, changes)

	edits := lsp.edits_for_changes(buf, changes)
	for dc in d.clients {
		if dc.opened do lsp.client_change(dc.client.client, d.uri, buf.version, edits)
	}
}


doc_saved :: proc(d: ^Doc) {
	timed()
	for dc in d.clients {
		if dc.opened do lsp.client_save(dc.client.client, d.uri)
	}
}


// Opens documents on clients that were started (or restarted) since they were
// attached
open_pending_docs :: proc() {
	for d in env.documents() do doc_open_pending(d)
}


// A client starts over: its documents are opened again on the new one
docs_reset :: proc(c: ^Client) {
	for d in env.documents() {
		for &dc in d.clients {
			if dc.client == c do dc.opened = false
		}
	}
}


// A client goes away: documents stop using it
docs_detach :: proc(c: ^Client) {
	for d in env.documents() {
		problems_clear(d, only = c)
		for i := len(d.clients) - 1; i >= 0; i -= 1 {
			if d.clients[i].client == c do ordered_remove(&d.clients, i)
		}
	}
}


// Opens the document on its clients that don't have it yet. The client's
// thread keeps it until its server is ready
doc_open_pending :: proc(d: ^Doc) {
	timed()

	for &dc in d.clients {
		if dc.opened do continue
		#partial switch dc.client.state {
		case .Stopping, .Stopped, .Crashed:
			continue
		}

		text := buffer.snapshot(&d.view.buf)
		lsp.client_open(dc.client.client, d.uri, d.language, text)
		dc.opened = true
	}
}
