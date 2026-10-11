#+build windows
package editor

import "core:slice"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

// FindFirstFileW-based directory walk (see fs_walk.odin).

@(private)
walk_files_windows :: proc(root: string, ignore: []string, cancel: ^bool, user: rawptr, visit: Walk_Visit) {
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

		pattern := win32.utf8_to_wstring(strings.concatenate({dir, "\\*"}, context.temp_allocator))
		data: win32.WIN32_FIND_DATAW
		h := win32.FindFirstFileW(pattern, &data)
		if h == win32.INVALID_HANDLE_VALUE do continue
		defer win32.FindClose(h)

		for {
			name_buf: [win32.MAX_PATH * 4]u8
			name := win32.wstring_to_utf8(name_buf[:], cstring16(&data.cFileName[0]))
			if name != "." && name != ".." && name != "" {
				attrs := data.dwFileAttributes
				is_dir := attrs & win32.FILE_ATTRIBUTE_DIRECTORY != 0
				if is_dir {
					is_link := attrs & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0
					if !is_link && !slice.contains(ignore, name) {
						append(&stack, strings.concatenate({dir, "\\", name}))
					}
				} else {
					path := strings.concatenate({dir, "\\", name}, context.temp_allocator)
					if !visit(path, user) do return
				}
			}
			if !win32.FindNextFileW(h, &data) do break
		}
	}
}
