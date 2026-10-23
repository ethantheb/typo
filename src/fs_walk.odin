package editor

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

// Directory listing for the sidebar and the file finder. On Windows this lists
// with FindFirstFileW (fs_walk_windows.odin), which reads names and attributes
// without opening each file as core:os does; that is slow on network and
// virtual drives and wakes antivirus scanning.

Dir_Entry :: struct {
	name:    string,
	is_dir:  bool,
	is_link: bool, // a symlink or junction
}

// The entries of one directory, without "." and "..", in the temp allocator.
list_directory :: proc(dir: string) -> (entries: []Dir_Entry, ok: bool) {
	when ODIN_OS == .Windows {
		return list_directory_windows(dir) // fs_walk_windows.odin
	} else {
		return list_directory_generic(dir)
	}
}

@(private = "file")
list_directory_generic :: proc(dir: string) -> (entries: []Dir_Entry, ok: bool) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil, false
	list := make([]Dir_Entry, len(infos), context.temp_allocator)
	for info, i in infos {
		is_link := info.type == .Symlink
		list[i] = {info.name, info.type == .Directory || (is_link && os.is_dir(info.fullpath)), is_link}
	}
	return list, true
}

Walk_Visit :: proc(path: string, user: rawptr) -> bool

// Recursive file listing for the file finder. Calls visit(path, user) for each
// file, with `path` valid only during the call; visit returns false to stop.
// Directories named in `ignore` are skipped, as are directory symlinks and
// junctions (which can loop or duplicate trees). `cancel` is polled once per
// directory. Frees the temp allocator after each directory.
walk_files :: proc(root: string, ignore: []string, cancel: ^bool, user: rawptr, visit: Walk_Visit) {
	stack := make([dynamic]string)
	defer {
		for d in stack do delete(d)
		delete(stack)
	}
	append(&stack, strings.clone(strings.trim_right(root, "/\\")))

	for len(stack) > 0 {
		if sync.atomic_load(cancel) do return
		dir := pop(&stack)
		defer delete(dir)
		defer free_all(context.temp_allocator)

		entries, ok := list_directory(dir)
		if !ok do continue
		for e in entries {
			if e.is_dir {
				if !e.is_link && !slice.contains(ignore, e.name) {
					append(&stack, strings.concatenate({dir, os.Path_Separator_String, e.name}))
				}
			} else {
				path := strings.concatenate({dir, os.Path_Separator_String, e.name}, context.temp_allocator)
				if !visit(path, user) do return
			}
		}
	}
}
