#+build linux, darwin, freebsd, openbsd, netbsd
package ipc

// The endpoint is a Unix domain socket in a folder only the current user can
// enter (mkdtemp makes it 0700), itself 0600, in the user's runtime folder
// (XDG_RUNTIME_DIR, else TMPDIR, else /tmp). The server's thread polls the
// socket and a pipe that server_stop writes to

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"


@(private = "file")
SOCKET_NAME :: "ipc.sock"

Server_OS :: struct {
	dir:    string, // owned; the private folder holding the socket
	socket: posix.FD,
	wake:   [2]posix.FD, // a pipe: server_stop writes, the thread wakes
}

@(private)
Conn :: struct {
	fd:   posix.FD,
	stop: posix.FD, // the server's wake pipe; -1 for a client
}


@(private)
listen :: proc(s: ^Server) -> bool {
	s.socket, s.wake = -1, {-1, -1}

	// The private folder
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	template := fmt.tprintf("%s/typo-XXXXXX\x00", base)
	made := posix.mkdtemp(raw_data(template))
	if made == nil do return false
	s.dir = strings.clone(string(made))

	// The socket in it
	s.endpoint = fmt.aprintf("%s/%s", s.dir, SOCKET_NAME)
	addr, fits := socket_address(s.endpoint)
	if !fits || !bind_socket(s, &addr) || posix.pipe(&s.wake) != .OK {
		close_listener(s)
		delete(s.endpoint)
		s.endpoint = ""
		return false
	}

	// Shells started in typo's terminals don't inherit these
	for fd in ([]posix.FD{s.socket, s.wake[0], s.wake[1]}) {
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	return true
}


@(private = "file")
bind_socket :: proc(s: ^Server, addr: ^posix.sockaddr_un) -> bool {
	s.socket = posix.socket(.UNIX, .STREAM)
	if s.socket < 0 do return false

	sa := (^posix.sockaddr)(addr)
	if posix.bind(s.socket, sa, size_of(posix.sockaddr_un)) != .OK do return false

	path := strings.clone_to_cstring(s.endpoint, context.temp_allocator)
	if posix.chmod(path, {.IRUSR, .IWUSR}) != .OK do return false

	return posix.listen(s.socket, 8) == .OK
}


// The address for a socket path; false if the path is too long for one
@(private = "file")
socket_address :: proc(path: string) -> (addr: posix.sockaddr_un, ok: bool) {
	if len(path) >= len(addr.sun_path) do return {}, false

	addr.sun_family = .UNIX
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	return addr, true
}


// The server's thread: waits for a client or the wake pipe, answers clients
// one at a time
@(private)
serve :: proc(s: ^Server) {
	for !server_stopping(s) {
		fds := [2]posix.pollfd {
			{fd = s.socket, events = {.IN}},
			{fd = s.wake[0], events = {.IN}},
		}
		if posix.poll(&fds[0], 2, -1) < 0 {
			if posix.errno() == .EINTR do continue
			break
		}
		if fds[1].revents != {} do break
		if .IN not_in fds[0].revents do continue

		fd := posix.accept(s.socket, nil, nil)
		if fd < 0 do continue
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)

		conn := Conn{fd = fd, stop = s.wake[0]}
		_ = serve_connection(s, &conn)
		conn_close(&conn)
		free_all(context.temp_allocator)
	}
}


// The client's process id: not looked up here yet, so control requests are
// refused (docs/agent_control.md)
@(private)
conn_client_pid :: proc(c: ^Conn) -> int {
	return 0
}


// --- Slots (unused until control requests are taken here) --------------------------

Slot_OS :: struct {}

@(private)
slot_os_init :: proc(s: ^Slot) {}

@(private)
slot_os_signal :: proc(s: ^Slot) {}

@(private)
slot_os_destroy :: proc(s: ^Slot) {}


// Waits until the slot is filled: never needed while control requests are
// refused, so it gives up at once
slot_wait :: proc(call: Control_Call, s: ^Slot) -> bool {
	slot_abandon(s)
	return slot_is_filled(s)
}


@(private)
wake_server :: proc(s: ^Server) {
	b := u8(1)
	posix.write(s.wake[1], &b, 1)
}


@(private)
close_listener :: proc(s: ^Server) {
	if s.socket >= 0 do posix.close(s.socket)
	for fd in s.wake {
		if fd >= 0 do posix.close(fd)
	}

	if s.endpoint != "" {
		posix.unlink(strings.clone_to_cstring(s.endpoint, context.temp_allocator))
	}
	if s.dir != "" {
		posix.rmdir(strings.clone_to_cstring(s.dir, context.temp_allocator))
	}
	delete(s.dir)
	s.os = {}
}


// Connects to a typo's socket: only a socket the current user owns
@(private)
connect :: proc(endpoint: string) -> (conn: Conn, ok: bool) {
	if !strings.has_suffix(endpoint, "/" + SOCKET_NAME) do return {}, false
	addr := socket_address(endpoint) or_return

	st: posix.stat_t
	path := strings.clone_to_cstring(endpoint, context.temp_allocator)
	if posix.lstat(path, &st) != .OK do return {}, false
	if !posix.S_ISSOCK(st.st_mode) do return {}, false
	if st.st_uid != posix.getuid() do return {}, false

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return {}, false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return {}, false
	}
	return {fd = fd, stop = -1}, true
}


@(private)
conn_close :: proc(conn: ^Conn) {
	posix.close(conn.fd)
	conn^ = {}
}


// Reads exactly len(buf) bytes; false on a timeout, an error or the other end
// closing first
@(private)
conn_read :: proc(conn: ^Conn, buf: []u8, timeout_ms: u32) -> bool {
	at := 0
	for at < len(buf) {
		if !wait_ready(conn, {.IN}, timeout_ms) do return false

		rest := buf[at:]
		n := posix.recv(conn.fd, raw_data(rest), c.size_t(len(rest)), {})
		if interrupted(int(n)) do continue
		if n <= 0 do return false
		at += int(n)
	}
	return true
}


@(private)
conn_write :: proc(conn: ^Conn, data: []u8, timeout_ms: u32) -> bool {
	at := 0
	for at < len(data) {
		if !wait_ready(conn, {.OUT}, timeout_ms) do return false

		// A closed peer is an error here, not SIGPIPE
		rest := data[at:]
		n := posix.send(conn.fd, raw_data(rest), c.size_t(len(rest)), {.NOSIGNAL})
		if interrupted(int(n)) do continue
		if n <= 0 do return false
		at += int(n)
	}
	return true
}


// Waits until the connection can be read or written; false on a timeout or
// once the server stops (poll skips a stop of -1)
@(private = "file")
wait_ready :: proc(conn: ^Conn, events: posix.Poll_Event, timeout_ms: u32) -> bool {
	for {
		fds := [2]posix.pollfd {
			{fd = conn.fd, events = events},
			{fd = conn.stop, events = {.IN}},
		}
		n := posix.poll(&fds[0], 2, c.int(timeout_ms))
		if interrupted(int(n)) do continue
		if fds[1].revents != {} do return false

		return n > 0
	}
}


// Whether a call's result means a signal interrupted it
@(private = "file")
interrupted :: proc(result: int) -> bool {
	return result < 0 && posix.errno() == .EINTR
}


// The registry of endpoints by project (projects.odin): a folder in the
// user's runtime folder that only the user may use, or "". One someone else
// made, or others may enter, is refused
@(private)
registry_root :: proc(create: bool) -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if base == "" do base = os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	root := fmt.tprintf("%s/typo-projects-%d", base, posix.getuid())
	path := strings.clone_to_cstring(root, context.temp_allocator)

	st: posix.stat_t
	if posix.lstat(path, &st) != .OK {
		if !create do return ""
		if posix.mkdir(path, {.IRUSR, .IWUSR, .IXUSR}) != .OK do return ""
		if posix.lstat(path, &st) != .OK do return ""
	}

	private := posix.S_ISDIR(st.st_mode) && st.st_uid == posix.getuid()
	others := st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	return private && others == {} ? root : ""
}
