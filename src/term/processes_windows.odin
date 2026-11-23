package term

// Which programs run under a shell: what closing its terminal would end. A
// snapshot of every process gives each one's parent; the shell's descendants
// are found level by level from it

import "core:slice"
import "core:strings"
import win "core:sys/windows"


// Started for a program's console, not by the user
@(private = "file")
CONSOLE_HOSTS := [?]string{"conhost", "openconsole"}

@(private = "file")
Process_Entry :: struct {
	pid:    u32,
	parent: u32,
	name:   string, // without ".exe"
}


// The programs running under the process `pid` (a shell), by name without
// ".exe": its children first, then theirs. Takes a snapshot of every process,
// so call it off the UI thread
programs_under :: proc(pid: int, allocator := context.allocator) -> []string {
	if pid <= 0 do return nil

	snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
	if snapshot == win.INVALID_HANDLE_VALUE do return nil
	defer win.CloseHandle(snapshot)

	// Every process, with its parent
	entries := make([dynamic]Process_Entry, context.temp_allocator)
	entry := win.PROCESSENTRY32W{dwSize = size_of(win.PROCESSENTRY32W)}
	more := win.Process32FirstW(snapshot, &entry)
	for more {
		name, _ := win.wstring_to_utf8(cstring16(&entry.szExeFile[0]), -1, context.temp_allocator)
		append(&entries, Process_Entry{
			pid = entry.th32ProcessID,
			parent = entry.th32ParentProcessID,
			name = trim_exe(name),
		})
		more = win.Process32NextW(snapshot, &entry)
	}

	// Its descendants, level by level. A process whose parent id is one of
	// them but which started before the shell has a reused id, not a parent
	born, known := started_at(u32(pid))
	if !known do return nil

	names := make([dynamic]string, allocator)
	level := []u32{u32(pid)}
	for len(level) > 0 {
		next := make([dynamic]u32, context.temp_allocator)
		for e in entries {
			if !slice.contains(level, e.parent) || e.pid == u32(pid) {
				continue
			}
			if at, ok := started_at(e.pid); !ok || at < born {
				continue
			}

			append(&next, e.pid)
			if !is_console_host(e.name) {
				append(&names, strings.clone(e.name, allocator))
			}
		}
		level = next[:]
	}
	return names[:]
}


// When a process started (FILETIME ticks), if it can be asked
@(private = "file")
started_at :: proc(pid: u32) -> (at: u64, ok: bool) {
	process := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if process == nil do return 0, false
	defer win.CloseHandle(process)

	created, exited, kernel, user: win.FILETIME
	if !win.GetProcessTimes(process, &created, &exited, &kernel, &user) {
		return 0, false
	}
	return u64(created.dwHighDateTime) << 32 | u64(created.dwLowDateTime), true
}


@(private = "file")
trim_exe :: proc(name: string) -> string {
	if len(name) > 4 && strings.equal_fold(name[len(name) - 4:], ".exe") {
		return name[:len(name) - 4]
	}
	return name
}


@(private = "file")
is_console_host :: proc(name: string) -> bool {
	for host in CONSOLE_HOSTS {
		if strings.equal_fold(name, host) do return true
	}
	return false
}
