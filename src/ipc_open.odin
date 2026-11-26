package editor

// `typo <file>` in typo's own terminals opens the file in that window. The
// running typo listens on its endpoint (ipc.Server, on its own thread) and
// names it in its shells' environment (ipc.ENV_NAME); a typo started there
// sends the files it was given, prints what the window answers and exits.
// A folder, --new, or an endpoint that doesn't answer (that typo has exited)
// start a new window as usual.
//
// Persistent shells (terminal_persist.odin) outlive their typo, so they get
// the project's name instead (ipc/projects.odin): each window lists its
// endpoint under the project it shows, written by the registry thread here,
// and `typo <file>` there reaches whichever window shows the project

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

import "ipc"


@(private = "file")
remote: struct {
	server:  ipc.Server,
	running: bool,
	mutex:   sync.Mutex,
	queue:   [dynamic][]string, // owned; each request's files, from the server's thread
}

// Lists this window's endpoint under its project, off the UI thread
@(private = "file")
registry: struct {
	thread:   ^thread.Thread,
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	wanted:   string, // owned; the project to be listed under ("" for none)
	shown:    string, // owned, UI thread: the folder `wanted` was made from
	stopping: bool,
}


// --- The window's side -------------------------------------------------------------

// Starts listening for typo started in this window's terminals: files to open,
// and control requests (control.odin)
ipc_init :: proc() {
	remote.running = ipc.server_start(&remote.server, answer_request, nil, control_answer)
	if remote.running {
		// Its own temp allocator
		ctx := runtime.default_context()
		ctx.allocator = context.allocator
		registry.thread = thread.create_and_start(registry_proc, ctx)
	}
}


ipc_destroy :: proc() {
	// The registry thread takes this window off its project's list first
	if registry.thread != nil {
		sync.lock(&registry.mutex)
		registry.stopping = true
		sync.cond_signal(&registry.cond)
		sync.unlock(&registry.mutex)
		thread.join(registry.thread)
		thread.destroy(registry.thread)
	}
	delete(registry.wanted)
	delete(registry.shown)
	registry = {}

	if remote.running do ipc.server_stop(&remote.server)
	control_destroy()

	for paths in remote.queue do delete_paths(paths)
	delete(remote.queue)
	remote = {}
}


// The variables a terminal's shell gets, in the temp allocator: the endpoint.
// Only shells get it, not language servers or other programs typo starts
ipc_shell_env :: proc() -> []string {
	if !remote.running do return nil

	env := make([]string, 1, context.temp_allocator)
	env[0] = fmt.tprintf("%s=%s", ipc.ENV_NAME, remote.server.endpoint)
	return env
}


// The variables a persistent shell gets (temp): the project's name, which
// outlives this window's endpoint
ipc_persistent_env :: proc() -> []string {
	if !remote.running || g.workspace.root == "" {
		return nil
	}

	env := make([]string, 1, context.temp_allocator)
	env[0] = fmt.tprintf("%s=%s", ipc.ENV_NAME, ipc.project_name(g.workspace.root))
	return env
}


// The registry thread: lists the endpoint under the project wanted, until
// told to stop, then takes it off
@(private = "file")
registry_proc :: proc() {
	listed := ""
	defer delete(listed)

	sync.lock(&registry.mutex)
	defer sync.unlock(&registry.mutex)
	for {
		for !registry.stopping && registry.wanted == listed {
			sync.cond_wait(&registry.cond, &registry.mutex)
		}
		wanted := registry.stopping ? "" : strings.clone(registry.wanted)
		sync.unlock(&registry.mutex)

		// Off the old project's list, onto the new one's
		if listed != "" do ipc.project_unregister(listed)
		if wanted != "" do ipc.project_register(wanted, remote.server.endpoint)
		delete(listed)
		listed = wanted
		free_all(context.temp_allocator)

		sync.lock(&registry.mutex)
		if registry.stopping && listed == "" {
			return
		}
	}
}


// Has the registry thread list this window under the folder it shows
@(private = "file")
registry_follow :: proc() {
	if registry.thread == nil || registry.shown == g.workspace.root {
		return
	}
	set_string(&registry.shown, g.workspace.root)

	name := g.workspace.root != "" ? ipc.project_name(g.workspace.root) : ""
	sync.guard(&registry.mutex)
	set_string(&registry.wanted, name)
	sync.cond_signal(&registry.cond)
}


// On the server's thread: queues the files that can open, and says why the
// others can't
@(private = "file")
answer_request :: proc(req: ipc.Request, userdata: rawptr) -> ipc.Reply {
	accepted := make([dynamic]string)
	problems := make([dynamic]string, context.temp_allocator)
	for path in req.paths {
		problem := open_problem(path)
		if problem != "" {
			append(&problems, fmt.tprintf("%s: %s", path, problem))
			continue
		}
		append(&accepted, strings.clone(path))
	}

	// The UI thread takes them next frame
	if len(accepted) > 0 {
		sync.guard(&remote.mutex)
		append(&remote.queue, accepted[:])
		wake_main_loop(nil)
	} else {
		delete(accepted)
	}

	return {ok = len(problems) == 0, messages = problems[:]}
}


// Why a path can't open in a pane, or "". A file that doesn't exist opens
// empty and is created when saved, as on the command line
open_problem :: proc(path: string) -> string {
	if os.is_dir(path) do return "is a folder (folders open in a new window)"
	if !os.is_dir(filepath.dir(path)) do return "no such folder"
	return ""
}


// Hands the next queued request to apply_pending_action, when no other action
// waits
ipc_frame :: proc() {
	registry_follow()
	control_frame()
	if g.pending != nil do return

	sync.guard(&remote.mutex)
	if len(remote.queue) == 0 do return

	paths := pop_front(&remote.queue)
	g.pending = Open_Files{paths = paths, raise = true}
}


// Requests are waiting
ipc_busy :: proc() -> bool {
	if control_busy() do return true

	sync.guard(&remote.mutex)
	return len(remote.queue) > 0
}


delete_paths :: proc(paths: []string) {
	for p in paths do delete(p)
	delete(paths)
}


// --- The command line's side -------------------------------------------------------

// `typo <files>` run in a typo terminal: sends the files to that window,
// prints its answer and returns the exit code. Not forwarded (a new window
// starts) when there is no endpoint or it doesn't answer, with --new,
// --terminal or --perf, or when a path is a folder
forward_to_window :: proc(args: Args) -> (exit_code: int, forwarded: bool) {
	if args.new_window || args.terminal || args.perf || len(args.paths) == 0 {
		return 0, false
	}
	endpoint := os.get_env(ipc.ENV_NAME, context.temp_allocator)
	if endpoint == "" do return 0, false

	// Paths are relative to where typo was started
	paths := make([]string, len(args.paths), context.temp_allocator)
	for arg, i in args.paths {
		path, err := os.get_absolute_path(arg, context.temp_allocator)
		if err != nil do return 0, false
		if os.is_dir(path) || ends_in_separator(arg) {
			return 0, false
		}
		paths[i] = path
	}
	if len(paths) > ipc.MAX_PATHS {
		print_error(fmt.tprintf("at most %d files at once", ipc.MAX_PATHS))
		return 1, true
	}

	// A project's name: the windows showing it, newest first
	endpoints := []string{endpoint}
	project := strings.has_prefix(endpoint, ipc.PROJECT_PREFIX)
	if project do endpoints = ipc.project_endpoints(endpoint)

	for e in endpoints {
		reply, err := ipc.send(e, {command = .Open, paths = paths})
		switch err {
		case .Not_Running:
			if project do ipc.project_forget(endpoint, e)
			continue
		case .Failed:
			print_error("the typo window did not answer")
			return 1, true
		case .None:
		}

		for m in reply.messages do print_error(m)
		return reply.ok ? 0 : 1, true
	}
	return 0, false
}


// Prints to the terminal typo was started from (a release build has no
// console of its own)
@(private = "file")
print_error :: proc(message: string) {
	attach_console()
	fmt.eprintfln("typo: %s", message)
}
