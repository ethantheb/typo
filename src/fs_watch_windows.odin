#+build windows
package editor

import "core:strings"
import win32 "core:sys/windows"
import "core:time"

// The watcher's notifications on Windows: ReadDirectoryChangesW on the root,
// recursive, overlapped, so the thread waits on it, on a wake event (stop, a
// new root, a job) and on a timeout at once. Also reading files with full
// sharing, so typo never stops another program writing, renaming or deleting


// The most a network share passes at once; events that don't fit are lost and
// reported as an overflow, after which everything is looked at again
@(private = "file")
NOTIFY_BUFFER_SIZE :: 64 * 1024

@(private = "file")
NOTIFY_FILTER ::
	win32.FILE_NOTIFY_CHANGE_FILE_NAME |
	win32.FILE_NOTIFY_CHANGE_DIR_NAME |
	win32.FILE_NOTIFY_CHANGE_SIZE |
	win32.FILE_NOTIFY_CHANGE_LAST_WRITE

@(private = "file")
SHARE_ALL :: win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE

Watch_Platform :: struct {
	wake:    win32.HANDLE, // set from any thread to end a wait
	dir:     win32.HANDLE, // the root, or nil
	done:    win32.HANDLE, // set when a read of changes completes
	ov:      win32.OVERLAPPED,
	buffer:  []u32, // DWORD aligned, as the call requires
	reading: bool,  // a read is under way
}


platform_init :: proc(p: ^Watch_Platform) {
	p.wake = win32.CreateEventW(nil, false, false, nil)
	p.done = win32.CreateEventW(nil, true, false, nil)
	p.buffer = make([]u32, NOTIFY_BUFFER_SIZE / 4)
}


platform_destroy :: proc(p: ^Watch_Platform) {
	platform_close(p)
	win32.CloseHandle(p.wake)
	win32.CloseHandle(p.done)
	delete(p.buffer)
	p^ = {}
}


// Starts watching a folder and everything in it
platform_open :: proc(p: ^Watch_Platform, root: string) -> bool {
	flags := win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED
	h := win32.CreateFileW(
		win32.utf8_to_wstring(root),
		win32.FILE_LIST_DIRECTORY,
		SHARE_ALL,
		nil,
		win32.OPEN_EXISTING,
		flags,
		nil,
	)
	if h == win32.INVALID_HANDLE_VALUE do return false

	p.dir = h
	return start_read(p)
}


platform_close :: proc(p: ^Watch_Platform) {
	if p.dir == nil do return

	// The read must finish before its buffer and handle go
	if p.reading {
		win32.CancelIoEx(p.dir, &p.ov)
		bytes: win32.DWORD
		win32.GetOverlappedResult(p.dir, &p.ov, &bytes, true)
		p.reading = false
	}
	win32.CloseHandle(p.dir)
	p.dir = nil
}


// Whether notifications are coming: a read is under way
platform_active :: proc(p: ^Watch_Platform) -> bool {
	return p.reading
}


// Ends a wait early. Safe from any thread
platform_wake :: proc(p: ^Watch_Platform) {
	win32.SetEvent(p.wake)
}


// Waits up to `timeout` for notifications, appending them to `events` (paths
// in the temp allocator). Returns true if some were lost
platform_wait :: proc(
	p: ^Watch_Platform,
	root: string,
	timeout: time.Duration,
	events: ^[dynamic]Watch_Event,
) -> (
	overflow: bool,
) {
	handles := [2]win32.HANDLE{p.wake, p.done}
	count: win32.DWORD = p.reading ? 2 : 1
	ms := win32.DWORD(clamp(time.duration_milliseconds(timeout) + 1, 0, 3_600_000))

	woke := win32.WaitForMultipleObjects(count, &handles[0], false, ms)
	if woke != win32.WAIT_OBJECT_0 + 1 do return false

	// A read finished
	p.reading = false
	bytes: win32.DWORD
	if !win32.GetOverlappedResult(p.dir, &p.ov, &bytes, false) {
		// Too many changes to list (ERROR_NOTIFY_ENUM_DIR), or the folder went away
		overflow = true
	} else if bytes == 0 {
		overflow = true // the buffer overflowed
	} else {
		data := ([^]u8)(raw_data(p.buffer))[:bytes]
		parse_notifications(data, root, events)
	}

	start_read(p)
	return overflow
}


@(private = "file")
start_read :: proc(p: ^Watch_Platform) -> bool {
	p.ov = {}
	p.ov.hEvent = p.done
	win32.ResetEvent(p.done)

	p.reading = bool(
		win32.ReadDirectoryChangesW(
			p.dir,
			raw_data(p.buffer),
			win32.DWORD(len(p.buffer) * 4),
			true,
			NOTIFY_FILTER,
			nil,
			&p.ov,
			nil,
		),
	)
	return p.reading
}


// FILE_NOTIFY_INFORMATION records: relative paths in UTF-16 with an action each
@(private = "file")
parse_notifications :: proc(data: []u8, root: string, events: ^[dynamic]Watch_Event) {
	sep := is_separator(root[len(root) - 1]) ? "" : `\`

	offset := 0
	for offset + size_of(win32.FILE_NOTIFY_INFORMATION) <= len(data) {
		info := (^win32.FILE_NOTIFY_INFORMATION)(&data[offset])
		name := ([^]u16)(&info.FileName[0])[:info.FileNameLength / 2]
		rel, _ := win32.utf16_to_utf8(name, context.temp_allocator)

		action: Watch_Action
		switch info.Action {
		case win32.FILE_ACTION_ADDED:            action = .Added
		case win32.FILE_ACTION_REMOVED:          action = .Removed
		case win32.FILE_ACTION_RENAMED_OLD_NAME: action = .Renamed_From
		case win32.FILE_ACTION_RENAMED_NEW_NAME: action = .Renamed_To
		case:                                    action = .Modified
		}
		path := strings.concatenate({root, sep, rel}, context.temp_allocator)
		append(events, Watch_Event{path, action})

		if info.NextEntryOffset == 0 do break
		offset += int(info.NextEntryOffset)
	}
}


// --- Reading files -----------------------------------------------------------------

// A file's size and last write time, without opening it
file_stamp :: proc(path: string) -> (stamp: File_Stamp, exists: bool) {
	info: win32.WIN32_FILE_ATTRIBUTE_DATA
	wpath := win32.utf8_to_wstring(path)
	if !win32.GetFileAttributesExW(wpath, win32.GetFileExInfoStandard, &info) {
		return {}, false
	}

	size := i64(info.nFileSizeHigh) << 32 | i64(info.nFileSizeLow)
	write := info.ftLastWriteTime
	mtime := i64(write.dwHighDateTime) << 32 | i64(write.dwLowDateTime)
	return {size, mtime}, true
}


// Reads a whole file, letting other programs read, write, rename and delete it
// meanwhile. Busy when another program holds it locked
read_file_shared :: proc(path: string, allocator := context.allocator) -> ([]u8, Read_Error) {
	h := win32.CreateFileW(
		win32.utf8_to_wstring(path),
		win32.GENERIC_READ,
		SHARE_ALL,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_SEQUENTIAL_SCAN,
		nil,
	)
	if h == win32.INVALID_HANDLE_VALUE {
		return nil, open_error(win32.GetLastError())
	}
	defer win32.CloseHandle(h)

	size: win32.LARGE_INTEGER
	if !win32.GetFileSizeEx(h, &size) do return nil, .Failed

	// It may shrink while read; what is there is read
	data, alloc_err := make([]u8, int(size), allocator)
	if alloc_err != nil do return nil, .Failed

	n := 0
	for n < len(data) {
		chunk := win32.DWORD(min(len(data) - n, 1 << 30))
		got: win32.DWORD
		if !win32.ReadFile(h, &data[n], chunk, &got, nil) {
			delete(data, allocator)
			return nil, open_error(win32.GetLastError())
		}
		if got == 0 do break
		n += int(got)
	}
	return data[:n], .None
}


@(private = "file")
open_error :: proc(err: win32.DWORD) -> Read_Error {
	switch err {
	case win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND:
		return .Missing
	case win32.ERROR_SHARING_VIOLATION, win32.ERROR_LOCK_VIOLATION:
		return .Busy
	}
	return .Failed
}
