package herdr

// A private herdr-core session, for tests and the perf suite: hc's session
// name and its state and config folders point at a temp folder, so the
// user's own core and terminals are never touched. Set in this process's
// environment, which `hc connect` (started by a client afterwards) inherits.
// So one at a time: a second waits for the first to end (tests run in
// parallel)

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "../process"


Sandbox :: struct {
	hc:      string, // owned
	dir:     string, // owned; the session's folders
	session: string, // owned; its name, as HC_SESSION
}

@(private = "file")
SANDBOX_VARS :: [?]string{"HC_SESSION", "XDG_STATE_HOME", "XDG_CONFIG_HOME"}

// Held from a sandbox's begin to its end
@(private = "file")
sandbox_lock: sync.Mutex


// Points hc at a private session named `name`. False (and a reason) when hc
// isn't installed
sandbox_begin :: proc(sb: ^Sandbox, name: string) -> (ok: bool, reason: string) {
	sb^ = {}
	sb.hc = find_hc()
	if sb.hc == "" do return false, "hc (herdr-core) is not installed"

	sync.lock(&sandbox_lock)
	temp, err := os.temp_directory(context.temp_allocator)
	if err != nil {
		delete(sb.hc)
		sync.unlock(&sandbox_lock)
		return false, "no temp folder"
	}

	// A folder of its own: sandbox_end removes it
	folder := fmt.tprintf("%s-%d", name, os.get_pid())
	sb.dir, _ = filepath.join({temp, folder})
	if os.exists(sb.dir) {
		delete(sb.dir)
		delete(sb.hc)
		sb^ = {}
		sync.unlock(&sandbox_lock)
		return false, "its folder is taken"
	}
	state, _ := filepath.join({sb.dir, "state"}, context.temp_allocator)
	config, _ := filepath.join({sb.dir, "config"}, context.temp_allocator)
	_ = os.make_directory_all(state)
	_ = os.make_directory_all(config)

	sb.session = strings.clone(folder)
	os.set_env("HC_SESSION", folder)
	os.set_env("XDG_STATE_HOME", state)
	os.set_env("XDG_CONFIG_HOME", config)
	return true, ""
}


// Stops the session's core (and every terminal in it) and removes its folders.
// The stop names the session in its own environment, whatever this process's
// holds now: hc takes the session only from HC_SESSION, and without it would
// stop the user's own core
sandbox_end :: proc(sb: ^Sandbox) {
	if sb.hc == "" do return

	if sb.session != "" {
		inherited, _ := os.environ(context.temp_allocator)
		own := fmt.tprintf("HC_SESSION=%s", sb.session)
		desc := os.Process_Desc {
			command = {sb.hc, "server", "stop"},
			env     = process.merged_env(inherited, {own}),
		}
		_, _, _, _ = os.process_exec(desc, context.temp_allocator)
	}

	for name in SANDBOX_VARS do os.unset_env(name)
	_ = os.remove_all(sb.dir)
	delete(sb.dir)
	delete(sb.hc)
	delete(sb.session)
	sb^ = {}
	sync.unlock(&sandbox_lock)
}
