package git

// The git command line, for what has to behave as it does in a terminal:
// commit (hooks, signing), push, pull and fetch (credential helpers). It runs
// without a console window and without prompts in a terminal
// (GIT_TERMINAL_PROMPT=0): a credential helper's own window still shows, but
// git never waits for typing. A command that fails for want of credentials can
// be run in a typo terminal instead (Remote_Done.line)

import "core:strings"
import "core:sync"
import "core:thread"

import "../process"


Remote_Op :: enum u8 {
	Commit,
	Push,
	Pull,
	Fetch,
}

// The output kept of a command, from its end
@(private = "file")
MAX_OUTPUT :: 64 * 1024

@(private = "file")
READ_CHUNK :: 16 * 1024

// Environment for every git command typo runs
@(private = "file")
GIT_ENV := []string{"GIT_TERMINAL_PROMPT=0"}

// What git prints when it would have asked for credentials or a passphrase
@(private = "file")
AUTH_SIGNS := []string{
	"authentication failed",
	"could not read username",
	"could not read password",
	"terminal prompts disabled",
	"permission denied (publickey",
	"host key verification failed",
	"invalid username or password",
	"logon failed",
}


// The command line for an operation, as typed in a terminal ("git push")
op_command_line :: proc(op: Remote_Op, s: ^Status) -> string {
	args := op_args(op, s)
	return strings.join(args[:], " ", context.temp_allocator)
}


// git and its arguments for an operation (temp). Pushing a branch without an
// upstream publishes it to origin
op_args :: proc(op: Remote_Op, s: ^Status) -> []string {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "git")

	switch op {
	case .Commit:
		append(&args, "commit", "--file=-")
	case .Push:
		append(&args, "push")
		if s != nil && s.upstream == "" && s.branch != "" {
			append(&args, "--set-upstream", "origin", s.branch)
		}
	case .Pull:
		append(&args, "pull", "--no-edit")
	case .Fetch:
		append(&args, "fetch")
	}
	return args[:]
}


// A command another thread may end (quitting while a push waits on the
// network or a credential window)
Running :: struct {
	mutex:   sync.Mutex,
	process: ^process.Process, // while it runs
	ended:   bool,             // running_end was called: a command started later ends at once
}


// Ends the command `r` follows, and any started after
running_end :: proc(r: ^Running) {
	sync.guard(&r.mutex)
	r.ended = true
	if r.process != nil do process.process_kill(r.process)
}


// Runs git with `args` (git first) in `workdir`, writing `input` to its stdin.
// Returns its exit code and output (stderr, then stdout), in `allocator`;
// code -1 and the output says why when it can't start. With `running`,
// another thread can end it
run :: proc(
	args: []string,
	workdir: string,
	input: []u8,
	allocator := context.allocator,
	running: ^Running = nil,
) -> (
	code: int,
	output: string,
) {
	p: process.Process
	ok, reason := process.process_spawn(&p, args, workdir, {env = GIT_ENV})
	if !ok do return -1, strings.clone(reason, allocator)

	if running != nil {
		sync.guard(&running.mutex)
		running.process = &p
		if running.ended do process.process_kill(&p)
	}

	// Both pipes are read while its stdin is written, so neither side waits on
	// the other (a hook printing much before git reads a long message)
	errors := Pipe_Reader{p = &p, from = .Stderr, data = make([dynamic]u8, allocator)}
	out := Pipe_Reader{p = &p, from = .Stdout, data = make([dynamic]u8, allocator)}
	error_reader := thread.create_and_start_with_poly_data(&errors, read_pipe)
	out_reader := thread.create_and_start_with_poly_data(&out, read_pipe)
	if len(input) > 0 do process.process_write(&p, input)
	process.process_close_input(&p)
	thread.destroy(error_reader) // joins
	thread.destroy(out_reader)

	process.process_wait(&p, -1)
	code = process.process_exit_code(&p)
	if running != nil {
		sync.guard(&running.mutex)
		running.process = nil
	}
	process.process_close(&p)

	sb := strings.builder_make(allocator)
	both := len(errors.data) > 0 && len(out.data) > 0
	strings.write_string(&sb, strings.trim_space(string(errors.data[:])))
	if both do strings.write_byte(&sb, '\n')
	strings.write_string(&sb, strings.trim_space(string(out.data[:])))
	delete(errors.data)
	delete(out.data)
	return code, strings.to_string(sb)
}


// Whether git's output says it wanted credentials it couldn't ask for
auth_failed :: proc(output: string) -> bool {
	lower := strings.to_lower(output, context.temp_allocator)
	for sign in AUTH_SIGNS {
		if strings.contains(lower, sign) do return true
	}
	return false
}


// One of a process's output pipes, read to its end, keeping the last
// MAX_OUTPUT bytes in `data` (made in the caller's allocator: the reader's
// thread has the default context, which frees its own temp memory)
@(private = "file")
Pipe_Reader :: struct {
	p:    ^process.Process,
	from: process.Stream,
	data: [dynamic]u8,
}


@(private = "file")
read_pipe :: proc(r: ^Pipe_Reader) {
	buf: [READ_CHUNK]u8
	for {
		n := process.process_read(r.p, r.from, buf[:])
		if n <= 0 do break

		append(&r.data, ..buf[:n])
		if len(r.data) > MAX_OUTPUT {
			remove_range(&r.data, 0, len(r.data) - MAX_OUTPUT)
		}
	}
}


// --- The command thread ------------------------------------------------------------

// One command at a time, on a thread of its own, so a slow push never holds up
// the status
@(private)
Cli :: struct {
	thread:     ^thread.Thread,
	busy:       bool, // under the worker's mutex
	op:         Remote_Op,
	args:       []string, // owned
	input:      []u8,     // owned
	cwd:        string,   // owned
	worker:     ^Worker,
	folder_gen: int,     // the worker's when it started: a later folder drops its result
	running:    Running, // cli_stop ends it
}


// Starts a command unless one runs. Called under the worker's mutex
@(private)
cli_start :: proc(w: ^Worker, op: Remote_Op, args: []string, input: string, cwd: string) -> bool {
	c := &w.cli
	if c.busy do return false

	// The thread of the command before, which has finished
	if c.thread != nil {
		thread.destroy(c.thread)
		c.thread = nil
	}

	args_owned := make([]string, len(args))
	for a, i in args do args_owned[i] = strings.clone(a)

	c^ = {
		busy       = true,
		op         = op,
		args       = args_owned,
		input      = transmute([]u8)strings.clone(input),
		cwd        = strings.clone(cwd),
		worker     = w,
		folder_gen = w.folder_gen,
	}

	// The default context, which frees the thread's temp memory as it ends
	c.thread = thread.create_and_start_with_poly_data(c, cli_proc)
	return true
}


// Ends the command under way, if any (git and what it started), and waits
// for its thread
@(private)
cli_stop :: proc(c: ^Cli) {
	if c.thread == nil do return

	running_end(&c.running)
	thread.destroy(c.thread)
	c.thread = nil
}


@(private = "file")
cli_proc :: proc(c: ^Cli) {
	context.allocator = c.worker.ctx.allocator // the UI thread frees the result

	code, output := run(c.args, c.cwd, c.input, running = &c.running)
	done := Remote_Done {
		op     = c.op,
		ok     = code == 0,
		output = output,
		auth   = code != 0 && auth_failed(output),
		line   = strings.join(c.args, " "),
	}

	for a in c.args do delete(a)
	delete(c.args)
	delete(c.input)
	delete(c.cwd)

	// Handed over, unless the folder changed meanwhile
	w := c.worker
	if sync.guard(&w.mutex) {
		c.busy = false
		if c.folder_gen == w.folder_gen {
			append(&w.events, done)
		} else {
			e := Event(done)
			event_destroy(&e)
		}
		w.refresh_wanted = true
		sync.cond_signal(&w.cond)
	}
	w.wake(w.wake_data)
}
