#+build windows
package process

// A process with its stdin, stdout and stderr on pipes. Started without a
// console window (typo is a GUI app, so a console program would get a window
// of its own), inheriting only its three pipe ends, inside a job object so it
// and anything it starts end with typo or with process_kill

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"


Process :: struct {
	handle: win.HANDLE,
	job:    win.HANDLE,
	stdin:  win.HANDLE, // our end: we write requests here
	stdout: win.HANDLE, // our end: the reader thread reads responses here
	stderr: win.HANDLE, // our end: the log thread reads here
}

@(private = "file")
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002

@(private = "file")
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000

@(private = "file")
CREATE_BREAKAWAY_FROM_JOB :: 0x01000000

@(private = "file")
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9

@(private = "file")
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private = "file")
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: win.LARGE_INTEGER,
	PerJobUserTimeLimit:     win.LARGE_INTEGER,
	LimitFlags:              win.DWORD,
	MinimumWorkingSetSize:   win.SIZE_T,
	MaximumWorkingSetSize:   win.SIZE_T,
	ActiveProcessLimit:      win.DWORD,
	Affinity:                win.ULONG_PTR,
	PriorityClass:           win.DWORD,
	SchedulingClass:         win.DWORD,
}

@(private = "file")
IO_COUNTERS :: struct {
	ReadOperationCount:  u64,
	WriteOperationCount: u64,
	OtherOperationCount: u64,
	ReadTransferCount:   u64,
	WriteTransferCount:  u64,
	OtherTransferCount:  u64,
}

@(private = "file")
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    win.SIZE_T,
	JobMemoryLimit:        win.SIZE_T,
	PeakProcessMemoryUsed: win.SIZE_T,
	PeakJobMemoryUsed:     win.SIZE_T,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: rawptr,
		dwAttributeCount: win.DWORD,
		dwFlags: win.DWORD,
		lpSize: ^win.SIZE_T,
	) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr,
		dwFlags: win.DWORD,
		Attribute: win.DWORD_PTR,
		lpValue: rawptr,
		cbSize: win.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize: ^win.SIZE_T,
	) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
	CreateJobObjectW :: proc(lpJobAttributes: rawptr, lpName: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject :: proc(
		hJob: win.HANDLE,
		JobObjectInformationClass: i32,
		lpJobObjectInformation: rawptr,
		cbJobObjectInformationLength: win.DWORD,
	) -> win.BOOL ---
	AssignProcessToJobObject :: proc(hJob, hProcess: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(hJob: win.HANDLE, uExitCode: win.UINT) -> win.BOOL ---
}


// Starts `command` (program and arguments) in `cwd`. The program is looked up
// on PATH; a .cmd or .bat (how npm installs servers) runs through cmd.exe.
// Returns a reason on failure
process_spawn :: proc(
	p: ^Process,
	command: []string,
	cwd: string,
	options: Spawn_Options = {},
) -> (
	ok: bool,
	reason: string,
) {
	p^ = {}
	if len(command) == 0 do return false, "no command"

	exe := find_executable(command[0], context.temp_allocator)
	if exe == "" {
		return false, fmt.tprintf("%s not found on PATH", command[0])
	}

	// The pipes: the child's ends are inheritable, ours are not. A discarded
	// stderr goes to NUL
	child_in, child_out, child_err: win.HANDLE
	if !make_pipe(&child_in, &p.stdin, child_reads = true) {
		return false, "could not create pipes"
	}
	if !make_pipe(&p.stdout, &child_out, child_reads = false) {
		close_handles(child_in, p.stdin)
		return false, "could not create pipes"
	}
	err_ok: bool
	if options.discard_stderr {
		child_err, err_ok = open_null()
	} else {
		err_ok = make_pipe(&p.stderr, &child_err, child_reads = false)
	}
	if !err_ok {
		close_handles(child_in, p.stdin, p.stdout, child_out)
		return false, "could not create pipes"
	}
	defer close_handles(child_in, child_out, child_err)

	// Only the three pipe ends are inherited
	handles := [3]win.HANDLE{child_in, child_out, child_err}
	attr_size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)
	attrs := make([]u8, attr_size, context.temp_allocator)
	si: STARTUPINFOEXW
	si.StartupInfo.cb = size_of(STARTUPINFOEXW)
	si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	si.StartupInfo.hStdInput = child_in
	si.StartupInfo.hStdOutput = child_out
	si.StartupInfo.hStdError = child_err
	si.lpAttributeList = raw_data(attrs)

	attrs_ok := bool(InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size))
	if attrs_ok {
		updated := UpdateProcThreadAttribute(
			si.lpAttributeList,
			0,
			PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
			&handles[0],
			size_of(handles),
			nil,
			nil,
		)
		attrs_ok = bool(updated)
	}
	defer if attrs_ok do DeleteProcThreadAttributeList(si.lpAttributeList)
	if !attrs_ok {
		close_handles(p.stdin, p.stdout, p.stderr)
		return false, "could not set up the process attributes"
	}

	// The process: suspended until it is in its job, or a detached one out of
	// typo's job when that allows it
	line := command_line(exe, command[1:])
	cmd := win.utf8_to_wstring(line, context.temp_allocator)
	dir := cwd != "" ? win.utf8_to_wstring(cwd, context.temp_allocator) : nil
	flags := win.DWORD(win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_NO_WINDOW)
	if !options.detached do flags |= win.CREATE_SUSPENDED
	env: rawptr
	if len(options.env) > 0 {
		env = environment_block(options.env)
		flags |= win.CREATE_UNICODE_ENVIRONMENT
	}
	tries := []win.DWORD{flags}
	if options.detached {
		tries = []win.DWORD{flags | CREATE_BREAKAWAY_FROM_JOB, flags}
	}
	pi: win.PROCESS_INFORMATION
	started := false
	for try in tries {
		started = bool(
			win.CreateProcessW(nil, cmd, nil, nil, true, try, env, dir, &si.StartupInfo, &pi),
		)
		if started do break
	}
	if !started {
		close_handles(p.stdin, p.stdout, p.stderr)
		return false, fmt.tprintf("could not start %s (error %d)", exe, win.GetLastError())
	}

	if options.detached {
		win.CloseHandle(pi.hThread)
		p.handle = pi.hProcess
		return true, ""
	}

	// Its job: closing the job's last handle (typo exiting) ends everything in it
	p.job = CreateJobObjectW(nil, nil)
	if p.job != nil {
		info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
		info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		_ = SetInformationJobObject(
			p.job,
			JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
			&info,
			size_of(info),
		)
		_ = AssignProcessToJobObject(p.job, pi.hProcess)
	}

	win.ResumeThread(pi.hThread)
	win.CloseHandle(pi.hThread)
	p.handle = pi.hProcess
	return true, ""
}


// The inherited environment with `extra` in it, as CreateProcessW takes it:
// UTF-16 "NAME=value" entries, each ended by a NUL, then one more NUL (temp)
@(private = "file")
environment_block :: proc(extra: []string) -> rawptr {
	inherited, _ := os.environ(context.temp_allocator)
	entries := merged_env(inherited, extra)

	sb := strings.builder_make(context.temp_allocator)
	for entry in entries {
		strings.write_string(&sb, entry)
		strings.write_byte(&sb, 0)
	}
	strings.write_byte(&sb, 0)

	block := win.utf8_to_utf16(strings.to_string(sb), context.temp_allocator)
	return raw_data(block)
}


// An inheritable handle to NUL, for output that goes nowhere
@(private = "file")
open_null :: proc() -> (handle: win.HANDLE, ok: bool) {
	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	handle = win.CreateFileW(win.L("NUL"), win.GENERIC_WRITE, 0, &sa, win.OPEN_EXISTING, 0, nil)
	if handle == win.INVALID_HANDLE_VALUE do return nil, false
	return handle, true
}


// Creates a pipe whose child end is inheritable
@(private = "file")
make_pipe :: proc(read, write: ^win.HANDLE, child_reads: bool) -> bool {
	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	if !win.CreatePipe(read, write, &sa, 0) do return false

	ours := child_reads ? write^ : read^
	win.SetHandleInformation(ours, win.HANDLE_FLAG_INHERIT, 0)
	return true
}


@(private = "file")
close_handles :: proc(handles: ..win.HANDLE) {
	for h in handles {
		if h != nil do win.CloseHandle(h)
	}
}


// The command line for CreateProcessW. A batch file runs through cmd.exe, whose
// /s takes everything between the first and last quote as the command
@(private = "file")
command_line :: proc(exe: string, args: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	quote_arg(&sb, exe)
	for arg in args {
		strings.write_byte(&sb, ' ')
		quote_arg(&sb, arg)
	}
	line := strings.to_string(sb)

	ext := strings.to_lower(filepath.ext(exe), context.temp_allocator)
	if ext == ".cmd" || ext == ".bat" {
		return fmt.tprintf(`cmd.exe /d /s /c "%s"`, line)
	}
	return line
}


// Quotes an argument the way the C runtime's parser reads it back
@(private = "file")
quote_arg :: proc(sb: ^strings.Builder, arg: string) {
	needs_quotes := arg == "" || strings.contains_any(arg, " \t\"")
	if !needs_quotes {
		strings.write_string(sb, arg)
		return
	}

	strings.write_byte(sb, '"')
	backslashes := 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		switch c {
		case '\\':
			backslashes += 1
		case '"':
			// Backslashes before a quote are doubled, and the quote escaped
			for _ in 0 ..< backslashes * 2 + 1 do strings.write_byte(sb, '\\')
			backslashes = 0
		case:
			for _ in 0 ..< backslashes do strings.write_byte(sb, '\\')
			backslashes = 0
		}
		if c != '\\' do strings.write_byte(sb, c)
	}

	// Backslashes before the closing quote are doubled
	for _ in 0 ..< backslashes * 2 do strings.write_byte(sb, '\\')
	strings.write_byte(sb, '"')
}


// Blocks until the process writes to `from` (stdout or stderr). Returns 0 once
// the pipe is closed (the process ended)
process_read :: proc(p: ^Process, from: Stream, buf: []u8) -> int {
	h := from == .Stdout ? p.stdout : p.stderr
	n: win.DWORD
	if !win.ReadFile(h, raw_data(buf), win.DWORD(len(buf)), &n, nil) do return 0
	return int(n)
}


// Writes all of `data` to the process's stdin; false if the pipe is closed
process_write :: proc(p: ^Process, data: []u8) -> bool {
	data := data
	for len(data) > 0 {
		n: win.DWORD
		if !win.WriteFile(p.stdin, raw_data(data), win.DWORD(len(data)), &n, nil) {
			return false
		}
		data = data[n:]
	}
	return true
}


// Closes our end of stdin, which tells most servers to exit
process_close_input :: proc(p: ^Process) {
	if p.stdin == nil do return

	win.CloseHandle(p.stdin)
	p.stdin = nil
}


// Waits up to `ms` milliseconds for the process to end; true if it has
process_wait :: proc(p: ^Process, ms: int) -> bool {
	if p.handle == nil do return true
	return win.WaitForSingleObject(p.handle, win.DWORD(ms)) == win.WAIT_OBJECT_0
}


// Ends the process and anything it started
process_kill :: proc(p: ^Process) {
	if p.job != nil {
		TerminateJobObject(p.job, 1)
	} else if p.handle != nil {
		win.TerminateProcess(p.handle, 1)
	}
}


process_exit_code :: proc(p: ^Process) -> int {
	if p.handle == nil do return -1

	code: win.DWORD
	if !win.GetExitCodeProcess(p.handle, &code) do return -1
	return int(code)
}


// Closes the handles; the process must have ended and the threads reading its
// output finished
process_close :: proc(p: ^Process) {
	process_close_input(p)
	close_handles(p.stdout, p.stderr, p.handle, p.job)
	p^ = {}
}


// Waits up to `ms` milliseconds for any process `pid` (not one started here)
// to end; true if it has or there is none
wait_for_exit :: proc(pid: int, ms: int) -> bool {
	handle := win.OpenProcess(win.SYNCHRONIZE, false, win.DWORD(pid))
	if handle == nil do return true
	defer win.CloseHandle(handle)

	return win.WaitForSingleObject(handle, win.DWORD(ms)) == win.WAIT_OBJECT_0
}
