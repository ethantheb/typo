#+build windows
package ipc

// The endpoint is a named pipe, \\.\pipe\typo-<pid>-<random>, open to the
// current user only (its own DACL: the default one lets everyone read) and to
// local clients only. All I/O is overlapped, so each wait can time out and
// the server's waits also end when it is told to stop

import "core:crypto"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:thread"


@(private = "file")
PIPE_PREFIX :: `\\.\pipe\typo-`

@(private = "file")
PIPE_BUFFER :: 4096

@(private = "file")
PIPE_UNLIMITED_INSTANCES :: 255

@(private = "file")
SECURITY_IDENTIFICATION :: 0x00010000 // SecurityIdentification << 16

@(private = "file")
SDDL_REVISION_1 :: 1

foreign import kernel32 "system:Kernel32.lib"
foreign import advapi32 "system:Advapi32.lib"
foreign import user32 "system:User32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	GetNamedPipeServerProcessId :: proc(
		Pipe: win.HANDLE,
		ServerProcessId: ^win.ULONG,
	) -> win.BOOL ---
	GetNamedPipeClientProcessId :: proc(
		Pipe: win.HANDLE,
		ClientProcessId: ^win.ULONG,
	) -> win.BOOL ---
}

@(private = "file", default_calling_convention = "system")
foreign advapi32 {
	ConvertSidToStringSidW :: proc(Sid: rawptr, StringSid: ^win.LPWSTR) -> win.BOOL ---
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(
		StringSecurityDescriptor: win.LPCWSTR,
		StringSDRevision: win.DWORD,
		SecurityDescriptor: ^rawptr,
		SecurityDescriptorSize: ^win.ULONG,
	) -> win.BOOL ---
}

@(private = "file", default_calling_convention = "system")
foreign user32 {
	AllowSetForegroundWindow :: proc(dwProcessId: win.DWORD) -> win.BOOL ---
}

Server_OS :: struct {
	name:     win.wstring, // the endpoint, for new instances
	security: rawptr,      // the pipe's security descriptor (LocalAlloc'ed)
	pipe:     win.HANDLE,  // the instance waiting for a client
	stop:     win.HANDLE,  // event set by server_stop
}

@(private)
Conn :: struct {
	pipe:  win.HANDLE,
	event: win.HANDLE, // for overlapped I/O
	stop:  win.HANDLE, // the server's stop event; nil for a client
}


// Creates the pipe's first instance, so the name is taken before anyone can
// see it
@(private)
listen :: proc(s: ^Server) -> bool {
	random: u64
	crypto.rand_bytes(mem.ptr_to_bytes(&random))
	s.endpoint = fmt.aprintf("%s%d-%016x", PIPE_PREFIX, os.get_pid(), random)
	s.name = win.utf8_to_wstring(s.endpoint, context.allocator)

	s.security = user_only_security()
	s.stop = win.CreateEventW(nil, true, false, nil)
	if s.security != nil && s.stop != nil {
		s.pipe = create_instance(s, first = true)
	}

	if s.pipe == nil {
		close_listener(s)
		delete(s.endpoint)
		s.endpoint = ""
		return false
	}
	return true
}


// A security descriptor whose DACL allows the current user and nobody else,
// or nil if it can't be made
@(private = "file")
user_only_security :: proc() -> rawptr {
	// The user's SID
	token: win.HANDLE
	if !win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) do return nil
	defer win.CloseHandle(token)

	// Aligned for the TOKEN_USER at its start (else ERROR_NOACCESS)
	size: win.DWORD
	win.GetTokenInformation(token, .TokenUser, nil, 0, &size)
	align := align_of(win.TOKEN_USER)
	info, _ := mem.alloc_bytes(int(size), align, context.temp_allocator)
	got := win.GetTokenInformation(token, .TokenUser, raw_data(info), size, &size)
	if !got do return nil

	user := (^win.TOKEN_USER)(raw_data(info))
	sid: win.LPWSTR
	if !ConvertSidToStringSidW(user.User.Sid, &sid) do return nil
	defer win.LocalFree(sid)

	// Protected (P): no inherited entries; GA: full access
	sid_text, _ := win.wstring_to_utf8(win.wstring(sid), -1, context.temp_allocator)
	sddl := fmt.tprintf("D:P(A;;GA;;;%s)", sid_text)
	wide := win.utf8_to_wstring(sddl, context.temp_allocator)

	descriptor: rawptr
	made := ConvertStringSecurityDescriptorToSecurityDescriptorW(
		wide,
		SDDL_REVISION_1,
		&descriptor,
		nil,
	)
	return made ? descriptor : nil
}


// A new instance of the pipe for the next client; nil if it can't be made
@(private = "file")
create_instance :: proc(s: ^Server, first: bool) -> win.HANDLE {
	sa := win.SECURITY_ATTRIBUTES {
		nLength              = size_of(win.SECURITY_ATTRIBUTES),
		lpSecurityDescriptor = s.security,
	}

	open_mode := win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED
	if first do open_mode |= win.FILE_FLAG_FIRST_PIPE_INSTANCE
	pipe_mode := win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_REJECT_REMOTE_CLIENTS

	pipe := win.CreateNamedPipeW(
		s.name,
		open_mode,
		pipe_mode,
		PIPE_UNLIMITED_INSTANCES,
		PIPE_BUFFER,
		PIPE_BUFFER,
		0,
		&sa,
	)
	return pipe != win.INVALID_HANDLE_VALUE ? pipe : nil
}


// The server's thread: waits for a client and hands it to a thread of its
// own. The next instance is made before that, so the name never lapses
@(private)
serve :: proc(s: ^Server) {
	event := win.CreateEventW(nil, true, false, nil)
	defer win.CloseHandle(event)

	for !server_stopping(s) {
		if !wait_for_client(s, event) do break

		next := create_instance(s, first = false)
		pipe := s.pipe
		s.pipe = next

		if !connection_begin(s) {
			win.DisconnectNamedPipe(pipe)
			win.CloseHandle(pipe)
		} else {
			c := new(Connection, s.allocator)
			c^ = {server = s, pipe = pipe}
			thread.create_and_start_with_poly_data(c, run_connection, self_cleanup = true)
		}

		if next == nil do break
	}
}


// A client being answered on its own thread
@(private = "file")
Connection :: struct {
	server: ^Server,
	pipe:   win.HANDLE,
}


@(private = "file")
run_connection :: proc(conn: ^Connection) {
	s := conn.server
	context.allocator = s.allocator
	pipe := conn.pipe
	free(conn)

	event := win.CreateEventW(nil, true, false, nil)
	c := Conn{pipe = pipe, event = event, stop = s.stop}
	replied := event != nil && serve_connection(s, &c)

	// Disconnecting drops what the client hasn't read: wait for it to close
	if replied {
		rest: [1]u8
		_ = conn_read(&c, rest[:], IO_TIMEOUT_MS)
	}

	win.DisconnectNamedPipe(pipe)
	win.CloseHandle(pipe)
	if event != nil do win.CloseHandle(event)
	free_all(context.temp_allocator)
	connection_end(s)
}


// The client's process id; 0 if it can't be had
@(private)
conn_client_pid :: proc(c: ^Conn) -> int {
	pid: win.ULONG
	if !GetNamedPipeClientProcessId(c.pipe, &pid) do return 0
	return int(pid)
}


// --- Slots -------------------------------------------------------------------------

Slot_OS :: struct {
	event: win.HANDLE, // set when the slot is filled
}


@(private)
slot_os_init :: proc(s: ^Slot) {
	s.event = win.CreateEventW(nil, true, false, nil)
}


@(private)
slot_os_signal :: proc(s: ^Slot) {
	win.SetEvent(s.event)
}


@(private)
slot_os_destroy :: proc(s: ^Slot) {
	win.CloseHandle(s.event)
}


// Waits until the slot is filled; false (and the slot abandoned) if the client
// goes away or the server stops first. A read stays pending on the connection
// meanwhile: a client sends nothing more, so it ends only when it goes
slot_wait :: proc(call: Control_Call, s: ^Slot) -> bool {
	c := call.conn
	ov := win.OVERLAPPED{hEvent = c.event}
	win.ResetEvent(c.event)
	b: [1]u8
	started := win.ReadFile(c.pipe, &b[0], 1, nil, &ov)
	pending := !started && win.GetLastError() == win.ERROR_IO_PENDING

	// The slot, the client going away, or the server stopping
	handles := [3]win.HANDLE{s.event, c.event, c.stop}
	woke := win.WaitForMultipleObjects(pending ? 3 : 1, &handles[0], false, win.INFINITE)
	if !pending {
		// The read ended at once: the client went away
		woke = slot_is_filled(s) ? win.WAIT_OBJECT_0 : win.WAIT_OBJECT_0 + 1
	}

	if pending {
		n: win.DWORD
		win.CancelIoEx(c.pipe, &ov)
		win.GetOverlappedResult(c.pipe, &ov, &n, true)
	}

	if woke == win.WAIT_OBJECT_0 do return true
	slot_abandon(s)
	return slot_is_filled(s)
}


// Waits until a client connects to the waiting instance; false once the
// server stops or the wait fails
@(private = "file")
wait_for_client :: proc(s: ^Server, event: win.HANDLE) -> bool {
	ov := win.OVERLAPPED{hEvent = event}
	win.ResetEvent(event)
	started := win.ConnectNamedPipe(s.pipe, &ov)

	// A client that came between creating the instance and this call
	if !started && win.GetLastError() == win.ERROR_PIPE_CONNECTED {
		return true
	}

	_, ok := finish_io(s.pipe, &ov, bool(started), s.stop, win.INFINITE)
	return ok
}


@(private)
wake_server :: proc(s: ^Server) {
	win.SetEvent(s.stop)
}


@(private)
close_listener :: proc(s: ^Server) {
	if s.pipe != nil do win.CloseHandle(s.pipe)
	if s.stop != nil do win.CloseHandle(s.stop)
	if s.security != nil do win.LocalFree(s.security)
	delete(s.name)
	s.os = {}
}


// Connects to a typo's pipe. Only a name typo would make is tried, and only
// a pipe served by the process the name gives is used
@(private)
connect :: proc(endpoint: string) -> (c: Conn, ok: bool) {
	pid, named := endpoint_pid(endpoint)
	if !named do return {}, false

	wide := win.utf8_to_wstring(endpoint, context.temp_allocator)
	flags := win.FILE_FLAG_OVERLAPPED | win.SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION
	access := win.GENERIC_READ | win.GENERIC_WRITE

	// Every instance may be busy with another client for a moment
	pipe := win.INVALID_HANDLE_VALUE
	for _ in 0 ..< 2 {
		pipe = win.CreateFileW(wide, access, 0, nil, win.OPEN_EXISTING, flags, nil)
		if pipe != win.INVALID_HANDLE_VALUE do break
		if win.GetLastError() != win.ERROR_PIPE_BUSY do return {}, false
		if !win.WaitNamedPipeW(wide, IO_TIMEOUT_MS) do return {}, false
	}
	if pipe == win.INVALID_HANDLE_VALUE do return {}, false

	server: win.ULONG
	if !GetNamedPipeServerProcessId(pipe, &server) || int(server) != pid {
		win.CloseHandle(pipe)
		return {}, false
	}

	// The server's window may come to the front
	AllowSetForegroundWindow(win.DWORD(pid))

	c = {pipe = pipe, event = win.CreateEventW(nil, true, false, nil)}
	return c, true
}


// The process id in a pipe name typo makes; false for any other name
@(private = "file")
endpoint_pid :: proc(endpoint: string) -> (pid: int, ok: bool) {
	if !strings.has_prefix(endpoint, PIPE_PREFIX) do return 0, false

	rest := endpoint[len(PIPE_PREFIX):]
	dash := strings.index_byte(rest, '-')
	if dash <= 0 do return 0, false

	return strconv.parse_int(rest[:dash], 10)
}


@(private)
conn_close :: proc(c: ^Conn) {
	win.CloseHandle(c.pipe)
	if c.event != nil do win.CloseHandle(c.event)
	c^ = {}
}


// Reads exactly len(buf) bytes; false on a timeout, an error or the other end
// closing first
@(private)
conn_read :: proc(c: ^Conn, buf: []u8, timeout_ms: u32) -> bool {
	at := 0
	for at < len(buf) {
		ov := win.OVERLAPPED{hEvent = c.event}
		win.ResetEvent(c.event)
		rest := buf[at:]
		started := win.ReadFile(c.pipe, raw_data(rest), win.DWORD(len(rest)), nil, &ov)

		n, ok := finish_io(c.pipe, &ov, bool(started), c.stop, timeout_ms)
		if !ok do return false
		if n == 0 do return false
		at += int(n)
	}
	return true
}


@(private)
conn_write :: proc(c: ^Conn, data: []u8, timeout_ms: u32) -> bool {
	at := 0
	for at < len(data) {
		ov := win.OVERLAPPED{hEvent = c.event}
		win.ResetEvent(c.event)
		rest := data[at:]
		started := win.WriteFile(c.pipe, raw_data(rest), win.DWORD(len(rest)), nil, &ov)

		n, ok := finish_io(c.pipe, &ov, bool(started), c.stop, timeout_ms)
		if !ok do return false
		if n == 0 do return false
		at += int(n)
	}
	return true
}


// Waits for an overlapped operation (`started`: the call that began it
// returned true; else it must be pending). Cancels it on a timeout or when
// `stop` (if any) is set
@(private = "file")
finish_io :: proc(
	h: win.HANDLE,
	ov: ^win.OVERLAPPED,
	started: bool,
	stop: win.HANDLE,
	timeout_ms: u32,
) -> (
	n: win.DWORD,
	ok: bool,
) {
	if !started && win.GetLastError() != win.ERROR_IO_PENDING {
		return 0, false
	}

	handles := [2]win.HANDLE{ov.hEvent, stop}
	count: win.DWORD = stop != nil ? 2 : 1
	woke := win.WaitForMultipleObjects(count, &handles[0], false, timeout_ms)

	if woke != win.WAIT_OBJECT_0 {
		win.CancelIoEx(h, ov)
		win.GetOverlappedResult(h, ov, &n, true)
		return 0, false
	}

	ok = bool(win.GetOverlappedResult(h, ov, &n, false))
	return n, ok
}


// The registry of endpoints by project (projects.odin):
// %LOCALAPPDATA%\typo\ipc, in the user's profile, which only the user may
// use; "" if LOCALAPPDATA isn't set
@(private)
registry_root :: proc(create: bool) -> string {
	local := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if local == "" do return ""

	root := fmt.tprintf(`%s\typo\ipc`, local)
	if create && !os.is_dir(root) && os.make_directory_all(root) != nil {
		return ""
	}
	return root
}
