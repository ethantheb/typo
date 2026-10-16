#+build linux, darwin, freebsd, openbsd, netbsd
package term

// A shell attached to a Unix pseudo terminal. The child gets the slave side as
// its controlling terminal; we keep the master. Reading the master fails (EIO)
// once the child and everything it started have exited, which is how the
// reader thread notices the end.

import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

foreign import libc "system:c"

@(private = "file")
Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: c.ushort,
}

when ODIN_OS == .Linux {
	@(private = "file") TIOCSWINSZ :: 0x5414
	@(private = "file") TIOCSCTTY :: 0x540E
} else {
	@(private = "file") TIOCSWINSZ :: 0x80087467
	@(private = "file") TIOCSCTTY :: 0x20007461
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

Pty :: struct {
	master:   posix.FD,
	pid:      posix.pid_t,
	exited:   bool, // set (atomically) when reading the master fails
	on_exit:  Notify_Proc,
	userdata: rawptr,
}

default_shell :: proc() -> string {
	shell := os.get_env("SHELL", context.temp_allocator)
	return shell != "" ? shell : "/bin/sh"
}

pty_spawn :: proc(p: ^Pty, command, cwd: string, cols, rows: u16, on_exit: Notify_Proc, userdata: rawptr) -> bool {
	p^ = {on_exit = on_exit, userdata = userdata}
	p.master = posix.posix_openpt({.RDWR, .NOCTTY})
	if p.master < 0 do return false
	if posix.grantpt(p.master) != .OK || posix.unlockpt(p.master) != .OK {
		posix.close(p.master)
		return false
	}
	slave_name := strings.clone_to_cstring(string(posix.ptsname(p.master)), context.temp_allocator)
	ws := Winsize{ws_row = c.ushort(rows), ws_col = c.ushort(cols)}
	ioctl(c.int(p.master), TIOCSWINSZ, &ws)

	// Everything the child needs is prepared before fork: only async-signal-safe
	// calls are allowed between fork and exec.
	argv := [4]cstring{"/bin/sh", "-c", strings.clone_to_cstring(command, context.temp_allocator), nil}
	dir := strings.clone_to_cstring(cwd, context.temp_allocator)

	pid := posix.fork()
	if pid < 0 {
		posix.close(p.master)
		return false
	}
	if pid == 0 {
		posix.setsid()
		slave := posix.open(slave_name, {.RDWR})
		if slave < 0 do posix._exit(127)
		ioctl(c.int(slave), TIOCSCTTY, c.int(0))
		posix.dup2(slave, 0)
		posix.dup2(slave, 1)
		posix.dup2(slave, 2)
		if slave > 2 do posix.close(slave)
		posix.close(p.master)
		if cwd != "" do posix.chdir(dir)
		posix.setenv("TERM", "xterm-256color", true)
		posix.setenv("COLORTERM", "truecolor", true)
		posix.execvp(argv[0], &argv[0])
		posix._exit(127)
	}
	p.pid = pid
	return true
}

pty_exited :: proc(p: ^Pty) -> bool {
	return sync.atomic_load(&p.exited)
}

// Blocks until the shell writes something. Returns 0 once it has exited.
pty_read :: proc(p: ^Pty, buf: []u8) -> int {
	for {
		n := posix.read(p.master, raw_data(buf), uint(len(buf)))
		if n > 0 do return int(n)
		if n < 0 && posix.errno() == .EINTR do continue
		sync.atomic_store(&p.exited, true)
		p.on_exit(p.userdata)
		return 0
	}
}

pty_write :: proc "contextless" (p: ^Pty, data: []u8) {
	data := data
	for len(data) > 0 {
		n := posix.write(p.master, raw_data(data), uint(len(data)))
		if n <= 0 do return
		data = data[n:]
	}
}

pty_resize :: proc(p: ^Pty, cols, rows: u16) {
	ws := Winsize{ws_row = c.ushort(rows), ws_col = c.ushort(cols)}
	ioctl(c.int(p.master), TIOCSWINSZ, &ws)
}

// Hangs up on the shell (killing it if it ignores that) and reaps it. The
// reader thread's read then fails, so it can be joined afterwards.
pty_close :: proc(p: ^Pty) {
	status: c.int
	if posix.waitpid(p.pid, &status, {.NOHANG}) == 0 {
		posix.kill(p.pid, .SIGHUP)
		for _ in 0 ..< 20 {
			if posix.waitpid(p.pid, &status, {.NOHANG}) != 0 do return
			time.sleep(5 * time.Millisecond)
		}
		posix.kill(p.pid, .SIGKILL)
		posix.waitpid(p.pid, &status, {})
	}
}

// Called after the reader thread has finished.
pty_close_output :: proc(p: ^Pty) {
	posix.close(p.master)
}
