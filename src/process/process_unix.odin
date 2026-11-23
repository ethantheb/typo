#+build !windows
package process

// A process with its stdin, stdout and stderr on pipes

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"


Process :: struct {
	process: os.Process,
	started: bool,
	exited:  bool,
	code:    int,
	stdin:   ^os.File, // our end: we write requests here
	stdout:  ^os.File, // our end: the reader thread reads responses here
	stderr:  ^os.File, // our end: the log thread reads here
}


// Starts `command` (program and arguments) in `cwd`, looking the program up on
// PATH. Returns a reason on failure
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

	// Writing to a server that has exited must fail, not end typo
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	// The pipes
	child_in, child_out, child_err: ^os.File
	err: os.Error
	child_in, p.stdin, err = os.pipe()
	if err != nil do return false, "could not create pipes"
	p.stdout, child_out, err = os.pipe()
	if err != nil {
		close_files(child_in, p.stdin)
		return false, "could not create pipes"
	}
	if options.discard_stderr {
		child_err, err = os.open("/dev/null", {.Write})
	} else {
		p.stderr, child_err, err = os.pipe()
	}
	if err != nil {
		close_files(child_in, p.stdin, p.stdout, child_out)
		return false, "could not create pipes"
	}
	defer close_files(child_in, child_out, child_err)

	// The process
	args := make([]string, len(command), context.temp_allocator)
	copy(args, command)
	args[0] = exe
	desc := os.Process_Desc {
		working_dir = cwd,
		command     = args,
		stdin       = child_in,
		stdout      = child_out,
		stderr      = child_err,
	}
	if len(options.env) > 0 {
		inherited, _ := os.environ(context.temp_allocator)
		desc.env = merged_env(inherited, options.env)
	}
	p.process, err = os.process_start(desc)
	if err != nil {
		close_files(p.stdin, p.stdout, p.stderr)
		return false, fmt.tprintf("could not start %s", exe)
	}

	p.started = true
	return true, ""
}


@(private = "file")
close_files :: proc(files: ..^os.File) {
	for f in files {
		if f != nil do os.close(f)
	}
}


// Blocks until the process writes to `from` (stdout or stderr). Returns 0 once
// the pipe is closed (the process ended)
process_read :: proc(p: ^Process, from: Stream, buf: []u8) -> int {
	f := from == .Stdout ? p.stdout : p.stderr
	n, err := os.read(f, buf)
	if err != nil do return 0
	return n
}


// Writes all of `data` to the process's stdin; false if the pipe is closed
process_write :: proc(p: ^Process, data: []u8) -> bool {
	data := data
	for len(data) > 0 {
		n, err := os.write(p.stdin, data)
		if err != nil || n <= 0 {
			return false
		}
		data = data[n:]
	}
	return true
}


// Closes our end of stdin, which tells most servers to exit
process_close_input :: proc(p: ^Process) {
	if p.stdin == nil do return

	os.close(p.stdin)
	p.stdin = nil
}


// Waits up to `ms` milliseconds for the process to end; true if it has
process_wait :: proc(p: ^Process, ms: int) -> bool {
	if !p.started || p.exited {
		return true
	}

	state, err := os.process_wait(p.process, time.Duration(ms) * time.Millisecond)
	if err != nil || !state.exited {
		return false
	}

	p.exited = true
	p.code = state.exit_code
	return true
}


process_kill :: proc(p: ^Process) {
	if p.started && !p.exited {
		_ = os.process_kill(p.process)
	}
}


process_exit_code :: proc(p: ^Process) -> int {
	return p.exited ? p.code : -1
}


// Closes the pipes; the process must have ended and the threads reading its
// output finished
process_close :: proc(p: ^Process) {
	process_close_input(p)
	close_files(p.stdout, p.stderr)
	if p.started && !p.exited {
		_, _ = os.process_wait(p.process)
	}
	p^ = {}
}
