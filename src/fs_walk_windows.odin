#+build windows
package editor

import "core:strings"
import win32 "core:sys/windows"

// FindFirstFileW-based directory listing (see fs_walk.odin)


@(private)
list_directory_windows :: proc(dir: string) -> (entries: []Dir_Entry, ok: bool) {
	trimmed := strings.trim_right(dir, "/\\")
	glob := strings.concatenate({trimmed, `\*`}, context.temp_allocator)
	pattern := win32.utf8_to_wstring(glob)

	data: win32.WIN32_FIND_DATAW
	h := win32.FindFirstFileW(pattern, &data)
	if h == win32.INVALID_HANDLE_VALUE do return nil, false
	defer win32.FindClose(h)

	list := make([dynamic]Dir_Entry, context.temp_allocator)
	for {
		name, _ := win32.wstring_to_utf8(cstring16(&data.cFileName[0]), -1, context.temp_allocator)
		if name != "." && name != ".." && name != "" {
			// A symlink or junction
			attrs, tag := data.dwFileAttributes, data.dwReserved0
			is_reparse_point := attrs & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0
			is_link_tag :=
				tag == win32.IO_REPARSE_TAG_SYMLINK ||
				tag == win32.IO_REPARSE_TAG_MOUNT_POINT

			append(&list, Dir_Entry {
				name    = name,
				is_dir  = attrs & win32.FILE_ATTRIBUTE_DIRECTORY != 0,
				is_link = is_reparse_point && is_link_tag,
			})
		}

		if !win32.FindNextFileW(h, &data) do break
	}
	return list[:], true
}
