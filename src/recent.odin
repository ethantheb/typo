package editor

import "core:strings"

// The open project's recently used files, most recent first: a file moves to
// the front when its pane is focused. The sidebar lists the first few under
// RECENT (sidebar_recent.odin); the finder lists them after the open files and
// ranks them up among its matches; the project's session keeps them
// (session.odin). A file deleted or renamed in typo leaves or follows; one gone
// otherwise isn't listed by the finder (it lists only files it found) and is
// dropped when the session is saved after the finder's index was built


RECENT_MAX_FILES :: 50

Recent_Files :: struct {
	files: [dynamic]string, // owned full paths, most recent first
}


// A file's pane was focused: it goes first in the project's list
recent_touch :: proc(path: string) {
	if path == "" || g.workspace.root == "" {
		return
	}

	recent_add(&g.recent, path)
}


// The project's recent files, most recent first
recent_files :: proc() -> []string {
	return g.recent.files[:]
}


// Puts a file first, keeping at most RECENT_MAX_FILES
recent_add :: proc(r: ^Recent_Files, path: string) {
	files := &r.files

	// Already first: focus changes with every press in a pane
	if len(files) > 0 && same_path(files[0], path) {
		return
	}

	// Taken from where it was, else new (the oldest makes room)
	kept := ""
	for f, i in files {
		if same_path(f, path) {
			kept = f
			ordered_remove(files, i)
			break
		}
	}
	if kept == "" {
		kept = strings.clone(path)
		if len(files) >= RECENT_MAX_FILES do delete(pop(files))
	}

	inject_at(files, 0, kept)
}


// A file or folder was deleted: it and what was inside it leave the list
recent_forget :: proc(r: ^Recent_Files, path: string) {
	for i := len(r.files) - 1; i >= 0; i -= 1 {
		if path_within(r.files[i], path) {
			delete(r.files[i])
			ordered_remove(&r.files, i)
		}
	}
}


// A file or folder was renamed: it and what was inside it follow
recent_renamed :: proc(r: ^Recent_Files, from, to: string) {
	for &f in r.files {
		if !path_within(f, from) do continue

		renamed := strings.concatenate({to, f[len(from):]})
		delete(f)
		f = renamed
	}
}


// Takes a list as the session saved it (copied), in its order, in place of the
// current one
recent_load :: proc(r: ^Recent_Files, saved: []string) {
	recent_clear(r)
	for path in saved {
		if len(r.files) >= RECENT_MAX_FILES do break
		if path == "" do continue

		duplicate := false
		for f in r.files {
			if same_path(f, path) do duplicate = true
		}
		if !duplicate do append(&r.files, strings.clone(path))
	}
}


recent_clear :: proc(r: ^Recent_Files) {
	for f in r.files do delete(f)
	clear(&r.files)
}


// Drops the recent files that the finder's index, once complete, shows are
// gone from the project's folder
recent_drop_missing :: proc() {
	files := &g.recent.files
	missing, known := finder_unindexed(files[:])
	if !known do return

	root := g.workspace.root
	for i := len(files) - 1; i >= 0; i -= 1 {
		if missing[i] && path_within(files[i], root) {
			delete(files[i])
			ordered_remove(files, i)
		}
	}
}


recent_destroy :: proc(r: ^Recent_Files) {
	recent_clear(r)
	delete(r.files)
	r^ = {}
}
