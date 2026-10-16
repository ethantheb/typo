#+build windows
package term

// A shell attached to a Windows pseudo console (ConPTY). The shell's output is
// read from `output` on the session's reader thread; input goes to `input`.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

@(private = "file")
HPCON :: distinct win.HANDLE

@(private = "file")
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

@(private = "file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount: win.DWORD, dwFlags: win.DWORD, lpSize: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: win.DWORD, Attribute: win.DWORD_PTR, lpValue: rawptr, cbSize: win.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
	SearchPathW :: proc(lpPath, lpFileName, lpExtension: win.LPCWSTR, nBufferLength: win.DWORD, lpBuffer: win.LPWSTR, lpFilePart: ^win.LPWSTR) -> win.DWORD ---
}

// Pseudo console implementations: the newer conpty.dll and OpenConsole.exe that
// Windows Terminal ships, and the one built into Windows. The bundled files are
// compiled in (build.py puts them in build/obj/conpty) and written out on first
// use, since conpty.dll starts OpenConsole.exe from its own folder.
@(private = "file")
CONPTY_DLL := #load("../../build/obj/conpty/conpty.dll")
@(private = "file")
OPENCONSOLE_EXE := #load("../../build/obj/conpty/OpenConsole.exe")
@(private = "file")
CONPTY_HASH :: #load_hash("../../build/obj/conpty/conpty.dll", "fnv64a") ~ #load_hash("../../build/obj/conpty/OpenConsole.exe", "fnv64a")

@(private = "file")
Conpty :: struct {
	create: proc "system" (size: win.COORD, hInput, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^HPCON) -> win.HRESULT,
	resize: proc "system" (hPC: HPCON, size: win.COORD) -> win.HRESULT,
	close:  proc "system" (hPC: HPCON),
}

@(private = "file")
bundled: struct {
	using api: Conpty,
	tried:     bool,
	lib:       win.HMODULE,
	users:     int, // open consoles created by it
}

@(private = "file")
builtin: Conpty

// The bundled ConPTY, written out and loaded on first use; nil if unavailable.
@(private = "file")
load_bundled_conpty :: proc() -> ^Conpty {
	b := &bundled
	if !b.tried {
		b.tried = true
		path := extract_conpty()
		b.lib = path != "" ? win.LoadLibraryW(win.utf8_to_wstring(path, context.temp_allocator)) : nil
		if b.lib != nil {
			b.create = auto_cast win.GetProcAddress(b.lib, "ConptyCreatePseudoConsole")
			b.resize = auto_cast win.GetProcAddress(b.lib, "ConptyResizePseudoConsole")
			b.close = auto_cast win.GetProcAddress(b.lib, "ConptyClosePseudoConsole")
		}
	}
	return b.create != nil && b.resize != nil && b.close != nil ? &b.api : nil
}

// Unloads the bundled conpty.dll once no console uses it, so its folder can be
// deleted. Loading it again later starts over.
@(private = "file")
unload_bundled_conpty :: proc() {
	if bundled.users > 0 do return
	if bundled.lib != nil do win.FreeLibrary(bundled.lib)
	bundled = {}
}

@(private = "file")
close_console :: proc(p: ^Pty) {
	p.conpty.close(p.hpc)
	if p.conpty == &bundled.api do bundled.users -= 1
}

@(private = "file")
load_builtin_conpty :: proc() -> ^Conpty {
	c := &builtin
	if c.create == nil {
		kernel := win.GetModuleHandleW(win.L("kernel32.dll"))
		c.create = auto_cast win.GetProcAddress(kernel, "CreatePseudoConsole")
		c.resize = auto_cast win.GetProcAddress(kernel, "ResizePseudoConsole")
		c.close = auto_cast win.GetProcAddress(kernel, "ClosePseudoConsole")
	}
	return c
}

// Writes the embedded ConPTY to %LOCALAPPDATA%\typo\conpty-<hash>, unless an
// earlier run already did, and returns the path of conpty.dll there ("" if it
// can't be written). Writing a new version removes the folders of older ones.
@(private = "file")
extract_conpty :: proc() -> string {
	root := conpty_root()
	if root == "" do return ""
	dir := fmt.tprintf(`%s\conpty-%016x`, root, CONPTY_HASH)
	dll := fmt.tprintf(`%s\conpty.dll`, dir)
	exe := fmt.tprintf(`%s\OpenConsole.exe`, dir)
	if os.exists(dll) && os.exists(exe) do return dll
	if os.make_directory_all(dir) != nil do return ""
	if !write_new_file(exe, OPENCONSOLE_EXE) || !write_new_file(dll, CONPTY_DLL) do return ""
	remove_conpty_folders(keep = dir)
	return dll
}

// %LOCALAPPDATA%\typo, or "" if LOCALAPPDATA isn't set.
@(private = "file")
conpty_root :: proc() -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	return local != "" ? fmt.tprintf(`%s\typo`, local) : ""
}

// Deletes extracted ConPTY folders other than `keep`. A folder another running
// typo is using can't be fully deleted; a later call removes the rest.
@(private = "file")
remove_conpty_folders :: proc(keep := "") {
	root := conpty_root()
	if root == "" do return
	infos, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return
	for info in infos {
		if info.type == .Directory && strings.has_prefix(info.name, "conpty-") && info.fullpath != keep {
			_ = os.remove_all(info.fullpath)
		}
	}
}

// Writes under a temporary name and renames, so another typo starting its
// terminal at the same moment never loads a partly written file.
@(private = "file")
write_new_file :: proc(path: string, data: []u8) -> bool {
	tmp := fmt.tprintf("%s.%d.tmp", path, os.get_pid())
	if os.write_entire_file(tmp, data) != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return os.exists(path) // the other typo won
	}
	return true
}

Pty :: struct {
	hpc:     HPCON,
	conpty:  ^Conpty,    // the implementation hpc came from
	input:   win.HANDLE, // we write keystrokes here
	output:  win.HANDLE, // the reader thread reads shell output here
	process: win.HANDLE,
	wait:    win.HANDLE, // exit watcher registered with the thread pool
	exited:  bool,       // set (atomically) when the shell process ends
	on_exit: Notify_Proc,
	userdata: rawptr,
}

// The shell to run when none is configured: PowerShell 7, then Windows
// PowerShell, then cmd.
default_shell :: proc() -> string {
	for name in ([]string{"pwsh.exe", "powershell.exe"}) {
		buf: [win.MAX_PATH]u16
		if SearchPathW(nil, win.utf8_to_wstring(name, context.temp_allocator), nil, len(buf), &buf[0], nil) > 0 {
			return name
		}
	}
	return "cmd.exe"
}

// Starts `command` (a full command line) in `cwd` with a cols x rows console.
// `on_exit` runs on a thread-pool thread when the process ends. With
// `bundled_conpty` it tries the bundled ConPTY first; without, it uses the
// built-in one and deletes any extracted copies.
pty_spawn :: proc(p: ^Pty, command, cwd: string, cols, rows: u16, on_exit: Notify_Proc, userdata: rawptr, bundled_conpty: bool) -> bool {
	p^ = {on_exit = on_exit, userdata = userdata}
	// Inherited by the shell; tells programs that 24-bit color works.
	win.SetEnvironmentVariableW(win.L("COLORTERM"), win.L("truecolor"))

	// The pseudo console reads from in_read and writes to out_write; we keep
	// the other ends.
	in_read, out_write: win.HANDLE
	if !win.CreatePipe(&in_read, &p.input, nil, 0) do return false
	if !win.CreatePipe(&p.output, &out_write, nil, 0) {
		win.CloseHandle(in_read)
		win.CloseHandle(p.input)
		return false
	}
	size := win.COORD{i16(cols), i16(rows)}
	hr := win.HRESULT(-1)
	if !bundled_conpty {
		unload_bundled_conpty()
		remove_conpty_folders()
	} else if p.conpty = load_bundled_conpty(); p.conpty != nil {
		hr = p.conpty.create(size, in_read, out_write, 0, &p.hpc)
		if hr >= 0 do bundled.users += 1
	}
	// Also when the bundled host can't start, e.g. blocked by security software.
	if hr < 0 {
		p.conpty = load_builtin_conpty()
		hr = p.conpty.create(size, in_read, out_write, 0, &p.hpc)
	}
	// The console holds its own references to these now.
	win.CloseHandle(in_read)
	win.CloseHandle(out_write)
	if hr < 0 {
		win.CloseHandle(p.input)
		win.CloseHandle(p.output)
		return false
	}

	attr_size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	attrs := make([]u8, attr_size, context.temp_allocator)
	si: STARTUPINFOEXW
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	// Without this a console-subsystem parent (debug builds) can leak its own
	// std handles to the child, bypassing the pseudo console.
	si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	si.lpAttributeList = raw_data(attrs)
	ok := bool(InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size)) &&
		bool(UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, rawptr(p.hpc), size_of(HPCON), nil, nil))
	defer if si.lpAttributeList != nil do DeleteProcThreadAttributeList(si.lpAttributeList)

	pi: win.PROCESS_INFORMATION
	if ok {
		cmd := win.utf8_to_wstring(command, context.temp_allocator)
		dir := cwd != "" ? win.utf8_to_wstring(cwd, context.temp_allocator) : nil
		ok = bool(win.CreateProcessW(nil, cmd, nil, nil, false, win.EXTENDED_STARTUPINFO_PRESENT, nil, dir, &si.StartupInfo, &pi))
	}
	if !ok {
		close_console(p)
		win.CloseHandle(p.input)
		win.CloseHandle(p.output)
		return false
	}
	win.CloseHandle(pi.hThread)
	p.process = pi.hProcess
	win.RegisterWaitForSingleObject(&p.wait, p.process, pty_exit_callback, p, win.INFINITE, win.WT_EXECUTEONLYONCE)
	return true
}

@(private = "file")
pty_exit_callback :: proc "system" (param: rawptr, timed_out: win.BOOLEAN) {
	p := (^Pty)(param)
	sync.atomic_store(&p.exited, true)
	p.on_exit(p.userdata)
}

pty_exited :: proc(p: ^Pty) -> bool {
	return sync.atomic_load(&p.exited)
}

// Blocks until the shell writes something. Returns 0 once the console is closed.
pty_read :: proc(p: ^Pty, buf: []u8) -> int {
	n: win.DWORD
	if !win.ReadFile(p.output, raw_data(buf), win.DWORD(len(buf)), &n, nil) do return 0
	return int(n)
}

pty_write :: proc "contextless" (p: ^Pty, data: []u8) {
	data := data
	for len(data) > 0 {
		n: win.DWORD
		if !win.WriteFile(p.input, raw_data(data), win.DWORD(len(data)), &n, nil) do return
		data = data[n:]
	}
}

pty_resize :: proc(p: ^Pty, cols, rows: u16) {
	p.conpty.resize(p.hpc, {i16(cols), i16(rows)})
}

// Closing the console ends the shell (if still running) and makes pty_read
// return 0, so the reader thread can be joined afterwards.
pty_close :: proc(p: ^Pty) {
	if p.wait != nil do win.UnregisterWaitEx(p.wait, win.INVALID_HANDLE_VALUE)
	close_console(p)
	win.CloseHandle(p.input)
	if !pty_exited(p) do win.TerminateProcess(p.process, 1)
	win.CloseHandle(p.process)
}

// Called after the reader thread has finished.
pty_close_output :: proc(p: ^Pty) {
	win.CloseHandle(p.output)
}
