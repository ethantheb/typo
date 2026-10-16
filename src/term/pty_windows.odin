#+build windows
package term

// A shell attached to a Windows pseudo console (ConPTY). The shell's output is
// read from `output` on the session's reader thread; input goes to `input`.

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

// The pseudo console implementation: conpty.dll (with OpenConsole.exe beside
// it, the same host Windows Terminal ships) when it sits next to the
// executable, else the one built into Windows.
@(private = "file")
conpty: struct {
	loaded: bool,
	create: proc "system" (size: win.COORD, hInput, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^HPCON) -> win.HRESULT,
	resize: proc "system" (hPC: HPCON, size: win.COORD) -> win.HRESULT,
	close:  proc "system" (hPC: HPCON),
}

@(private = "file")
load_conpty :: proc() {
	if conpty.loaded do return
	conpty.loaded = true
	lib := win.LoadLibraryW(win.L("conpty.dll"))
	if lib != nil {
		create := win.GetProcAddress(lib, "ConptyCreatePseudoConsole")
		resize := win.GetProcAddress(lib, "ConptyResizePseudoConsole")
		close := win.GetProcAddress(lib, "ConptyClosePseudoConsole")
		if create != nil && resize != nil && close != nil {
			conpty.create = auto_cast create
			conpty.resize = auto_cast resize
			conpty.close = auto_cast close
			return
		}
	}
	kernel := win.GetModuleHandleW(win.L("kernel32.dll"))
	conpty.create = auto_cast win.GetProcAddress(kernel, "CreatePseudoConsole")
	conpty.resize = auto_cast win.GetProcAddress(kernel, "ResizePseudoConsole")
	conpty.close = auto_cast win.GetProcAddress(kernel, "ClosePseudoConsole")
}

Pty :: struct {
	hpc:     HPCON,
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
// `on_exit` runs on a thread-pool thread when the process ends.
pty_spawn :: proc(p: ^Pty, command, cwd: string, cols, rows: u16, on_exit: Notify_Proc, userdata: rawptr) -> bool {
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
	load_conpty()
	hr := conpty.create({i16(cols), i16(rows)}, in_read, out_write, 0, &p.hpc)
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
		conpty.close(p.hpc)
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
	conpty.resize(p.hpc, {i16(cols), i16(rows)})
}

// Closing the console ends the shell (if still running) and makes pty_read
// return 0, so the reader thread can be joined afterwards.
pty_close :: proc(p: ^Pty) {
	if p.wait != nil do win.UnregisterWaitEx(p.wait, win.INVALID_HANDLE_VALUE)
	conpty.close(p.hpc)
	win.CloseHandle(p.input)
	if !pty_exited(p) do win.TerminateProcess(p.process, 1)
	win.CloseHandle(p.process)
}

// Called after the reader thread has finished.
pty_close_output :: proc(p: ^Pty) {
	win.CloseHandle(p.output)
}
