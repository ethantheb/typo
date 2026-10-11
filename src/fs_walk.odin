package editor

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

// Recursive file listing for the file finder.
//
// core:os's walker opens every file it visits to fill in File_Info (on Windows
// it calls CreateFile + GetFileInformationByHandleEx per entry), which makes
// big trees take minutes and triggers antivirus scans. On Windows we use
// FindFirstFileW/FindNextFileW directly: names and attributes only, no opens.
//
// Directories named in `ignore` are skipped, as are directory symlinks and
// junctions (which can loop or duplicate trees). Calls visit(path, user) for
// each file, with `path` valid only during the call; visit returns false to
// stop. `cancel` is polled once per directory.

Walk_Visit :: proc(path: string, user: rawptr) -> bool

walk_files :: proc(root: string, ignore: []string, cancel: ^bool, user: rawptr, visit: Walk_Visit) {
	when ODIN_OS == .Windows {
		walk_files_windows(root, ignore, cancel, user, visit) // fs_walk_windows.odin
	} else {
		walk_files_generic(root, ignore, cancel, user, visit)
	}
}

@(private = "file")
walk_files_generic :: proc(root: string, ignore: []string, cancel: ^bool, user: rawptr, visit: Walk_Visit) {
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if sync.atomic_load(cancel) do return
		if info.type == .Directory {
			if slice.contains(ignore, info.name) do os.walker_skip_dir(&w)
			continue
		}
		if !visit(info.fullpath, user) do return
	}
}
