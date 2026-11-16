package lsp

// Workspace edits (a rename's answer, or a server's workspace/applyEdit), read on
// the client's thread as byte ranges of each file's text: an open document's,
// or the file's on disk. The UI thread edits open files itself; a file that
// isn't open is rewritten by write_file_edit, which first checks the file is
// still as it was read

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strings"

import "../buffer"


// Edits to files, sorted by path
Workspace_Edit :: struct {
	files: []File_Edit, // owned
}

// One file's edits, as byte ranges of its text before any of them: sorted, not
// overlapping (insertions at the same place in the server's order)
File_Edit :: struct {
	path:    string, // owned
	edits:   []Edit, // owned, with their text
	open:    bool,   // an open document: the offsets are in its text at `version`
	version: u64,
	stale:   bool,   // the server meant an older version of the open document
	size:    int,    // a file that isn't open: its size and hash when read, which
	hash:    u64,    // it must still have to be rewritten
}

// The server asks for edits (workspace/applyEdit); answered by reply_apply_edit
Apply_Edit :: struct {
	id:    string, // owned; the request's id, as JSON
	label: string, // owned; what the edit is, may be ""
	edit:  Workspace_Edit,
}


// Rewrites a file that isn't open with its edits, if it is still as it was read
// for them. Returns why it couldn't, or "". Reads and writes the file: not for
// the UI thread
write_file_edit :: proc(fe: File_Edit) -> string {
	data, read_err := os.read_entire_file(fe.path, context.temp_allocator)
	if read_err != nil do return "it couldn't be read"
	if len(data) != fe.size || hash.fnv64a(data) != fe.hash {
		return "it changed since the edit was worked out"
	}

	// The text between the edits, and their texts
	sb := strings.builder_make(context.temp_allocator)
	at := 0
	for edit in fe.edits {
		lo := clamp(edit.offset, at, len(data))
		hi := clamp(edit.offset + edit.old_len, lo, len(data))
		strings.write_bytes(&sb, data[at:lo])
		strings.write_string(&sb, edit.text)
		at = hi
	}
	strings.write_bytes(&sb, data[at:])

	// Written beside it, then put in its place, so it is never half written
	tmp := strings.concatenate({fe.path, ".typo.tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, sb.buf[:]) != nil {
		os.remove(tmp)
		return "it couldn't be written"
	}
	if os.rename(tmp, fe.path) != nil {
		os.remove(tmp)
		return "it couldn't be replaced"
	}
	return ""
}


workspace_edit_destroy :: proc(edit: ^Workspace_Edit) {
	for fe in edit.files {
		delete(fe.path)
		for e in fe.edits do delete(e.text)
		delete(fe.edits)
	}
	delete(edit.files)
	edit^ = {}
}


// --- Reading (the client's thread) -------------------------------------------------

// A WorkspaceEdit as byte ranges, in the open documents' texts or in the files
// read from disk. Fails, with the reason, if it does more than edit text, a file
// can't be read, or edits overlap
@(private)
read_workspace_edit :: proc(w: ^Worker, v: json.Value) -> (edit: Workspace_Edit, error: string) {
	docs, ok := parse_workspace_edit(v)
	if !ok do return {}, "it creates, renames or deletes files"

	files := make([dynamic]File_Edit)
	for info in docs {
		if len(info.edits) == 0 do continue

		path, is_file := path_from_uri(info.uri, context.temp_allocator)
		if !is_file {
			error = fmt.tprintf("%s isn't a file", info.uri)
			break
		}

		// A file named twice gets the edits together
		fe: ^File_Edit
		for &other in files {
			if same_file(other.path, path) do fe = &other
		}
		if fe == nil {
			append(&files, File_Edit{path = strings.clone(path)})
			fe = &files[len(files) - 1]
		}

		error = read_file_edits(w, fe, info)
		if error != "" do break
	}

	if error == "" do error = sort_edits(files[:])
	slice.sort_by(files[:], file_less)
	edit = {files[:]}
	if error != "" do workspace_edit_destroy(&edit)
	return
}


// Converts a document's edits to byte ranges, adding them to its file's: in the
// open document's text, else in the file's text read from disk
@(private = "file")
read_file_edits :: proc(w: ^Worker, fe: ^File_Edit, info: Document_Edit_Info) -> string {
	text: ^buffer.Buffer
	file_text: buffer.Buffer
	defer if text == &file_text do buffer.buffer_destroy(&file_text)

	if doc := find_doc(w, info.uri); doc != nil {
		fe.open = true
		fe.version = doc.version
		version, has_version := info.version.?
		if has_version && u64(version) != doc.version {
			fe.stale = true
		}
		text = &doc.text
	} else {
		data, err := os.read_entire_file(fe.path, context.allocator)
		if err != nil do return fmt.tprintf("%s couldn't be read", fe.path)

		fe.size = len(data)
		fe.hash = hash.fnv64a(data)
		buffer.buffer_init(&file_text, data)
		text = &file_text
	}

	// Added to what an earlier mention of the file gave
	edits := make([dynamic]Edit, 0, len(fe.edits) + len(info.edits))
	append(&edits, ..fe.edits)
	for e in info.edits {
		lo := offset_at(text, e.range.start, w.encoding)
		hi := max(offset_at(text, e.range.end, w.encoding), lo)
		append(&edits, Edit{lo, hi - lo, strings.clone(e.text)})
	}
	delete(fe.edits)
	fe.edits = edits[:]
	return ""
}


// Puts each file's edits in order; fails if any overlap
@(private = "file")
sort_edits :: proc(files: []File_Edit) -> string {
	for fe in files {
		slice.stable_sort_by(fe.edits, edit_less)
		for i in 1 ..< len(fe.edits) {
			prev := fe.edits[i - 1]
			if fe.edits[i].offset < prev.offset + prev.old_len {
				return fmt.tprintf("its edits of %s overlap", fe.path)
			}
		}
	}
	return ""
}


// By offset; at the same offset, insertions (in their order) before a
// replacement
@(private = "file")
edit_less :: proc(a, b: Edit) -> bool {
	if a.offset != b.offset do return a.offset < b.offset
	return a.old_len == 0 && b.old_len > 0
}


@(private = "file")
file_less :: proc(a, b: File_Edit) -> bool {
	return a.path < b.path
}
