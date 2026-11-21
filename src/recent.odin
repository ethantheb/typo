package editor

import "core:strings"

// Recently used files, kept per workspace folder, most recent first: a file
// moves to the front when its pane is focused. The finder lists them after the
// open files and ranks them up among its matches; the session (session.json)
// keeps them. A file deleted or renamed in typo leaves or follows; one gone
// otherwise isn't listed (the finder lists only files it found) and is dropped
// when the session is saved after the finder's index was built


RECENT_MAX_FILES   :: 50 // per folder
RECENT_MAX_FOLDERS :: 20

Recent_Files :: struct {
	folders: [dynamic]Recent_Folder, // most recently used first
}

Recent_Folder :: struct {
	root:  string,          // owned
	files: [dynamic]string, // owned full paths, most recent first
}


// A file's pane was focused: it goes first in the workspace folder's list
recent_touch :: proc(path: string) {
	if path == "" || g.workspace.root == "" {
		return
	}

	recent_add(&g.recent, g.workspace.root, path)
}


// The workspace folder's recent files, most recent first
recent_files :: proc() -> []string {
	return recent_list(&g.recent, g.workspace.root)
}


// Puts a file first in a folder's list (and the folder first), keeping at most
// RECENT_MAX_FILES files and RECENT_MAX_FOLDERS folders
recent_add :: proc(r: ^Recent_Files, root, path: string) {
	folder := recent_folder(r, root)
	files := &folder.files

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


// A folder's recent files, most recent first; nil if it has none
recent_list :: proc(r: ^Recent_Files, root: string) -> []string {
	for &folder in r.folders {
		if same_path(folder.root, root) do return folder.files[:]
	}
	return nil
}


// A file or folder was deleted: it and what was inside it leave every list
recent_forget :: proc(r: ^Recent_Files, path: string) {
	for &folder in r.folders {
		for i := len(folder.files) - 1; i >= 0; i -= 1 {
			if path_within(folder.files[i], path) {
				delete(folder.files[i])
				ordered_remove(&folder.files, i)
			}
		}
	}
}


// A file or folder was renamed: it and what was inside it follow
recent_renamed :: proc(r: ^Recent_Files, from, to: string) {
	for &folder in r.folders {
		for &f in folder.files {
			if !path_within(f, from) do continue

			renamed := strings.concatenate({to, f[len(from):]})
			delete(f)
			f = renamed
		}
	}
}


// Takes the lists saved with the session (copied), in their order
recent_load :: proc(r: ^Recent_Files, saved: []Session_Recent) {
	for s in saved {
		if s.root == "" || recent_list(r, s.root) != nil {
			continue
		}
		if len(r.folders) >= RECENT_MAX_FOLDERS do break

		folder := Recent_Folder{root = strings.clone(s.root)}
		for path in s.files[:min(len(s.files), RECENT_MAX_FILES)] {
			append(&folder.files, strings.clone(path))
		}
		append(&r.folders, folder)
	}
}


// The lists as the session saves them, in the temp allocator (the strings are
// the lists' own)
recent_saved :: proc(r: ^Recent_Files) -> []Session_Recent {
	saved := make([]Session_Recent, len(r.folders), context.temp_allocator)
	for folder, i in r.folders {
		saved[i] = {root = folder.root, files = folder.files[:]}
	}
	return saved
}


// Drops the workspace folder's recent files that the finder's index, once
// complete, shows are gone
recent_drop_missing :: proc() {
	root := g.workspace.root
	for &folder in g.recent.folders {
		if !same_path(folder.root, root) do continue

		missing, known := finder_unindexed(folder.files[:])
		if !known do return

		for i := len(folder.files) - 1; i >= 0; i -= 1 {
			if missing[i] && path_within(folder.files[i], root) {
				delete(folder.files[i])
				ordered_remove(&folder.files, i)
			}
		}
		return
	}
}


recent_destroy :: proc(r: ^Recent_Files) {
	for folder in r.folders do folder_destroy(folder)
	delete(r.folders)
	r^ = {}
}


@(private = "file")
folder_destroy :: proc(folder: Recent_Folder) {
	delete(folder.root)
	for f in folder.files do delete(f)
	delete(folder.files)
}


// A folder's entry, moved first; added if new (the oldest folder makes room)
@(private = "file")
recent_folder :: proc(r: ^Recent_Files, root: string) -> ^Recent_Folder {
	for folder, i in r.folders {
		if !same_path(folder.root, root) do continue

		if i > 0 {
			ordered_remove(&r.folders, i)
			inject_at(&r.folders, 0, folder)
		}
		return &r.folders[0]
	}

	if len(r.folders) >= RECENT_MAX_FOLDERS {
		folder_destroy(pop(&r.folders))
	}

	inject_at(&r.folders, 0, Recent_Folder{root = strings.clone(root)})
	return &r.folders[0]
}
