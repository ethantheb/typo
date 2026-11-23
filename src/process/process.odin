package process

// Child processes with their stdin, stdout and stderr on pipes, started without
// a console window, and programs looked up on PATH. Language servers (package
// lsp), the git command line (package git) and herdr-core's `hc connect`
// (package herdr) run this way. Nothing here waits on the UI thread's behalf:
// the callers run it on their own threads


Stream :: enum {
	Stdout,
	Stderr,
}

// How a process is started, beyond its command and folder
Spawn_Options :: struct {
	// Variables added to the inherited environment ("NAME=value"), replacing
	// any of the same name
	env:            []string,
	// Its stderr goes nowhere, so there is no pipe to read
	discard_stderr: bool,
	// What it starts may outlive typo: on Windows no job object of its own
	// (which ends everything in it with typo), and out of typo's job when that
	// allows it
	detached:       bool,
}


// The environment's entries, each "NAME=value", with `extra` in place of the
// ones they name (temp)
merged_env :: proc(inherited, extra: []string) -> []string {
	out := make([dynamic]string, 0, len(inherited) + len(extra), context.temp_allocator)

	// What is inherited and not replaced
	for entry in inherited {
		if !replaced(entry, extra) do append(&out, entry)
	}
	append(&out, ..extra)
	return out[:]
}


// Whether `extra` sets the variable `entry` names
@(private = "file")
replaced :: proc(entry: string, extra: []string) -> bool {
	name := env_name(entry)
	for e in extra {
		if same_name(env_name(e), name) do return true
	}
	return false
}


// The part of "NAME=value" before the '='. Windows keeps entries such as
// "=C:=C:\dir", whose name starts with '='
@(private = "file")
env_name :: proc(entry: string) -> string {
	for i in 1 ..< len(entry) {
		if entry[i] == '=' do return entry[:i]
	}
	return entry
}


@(private = "file")
same_name :: proc(a, b: string) -> bool {
	when ODIN_OS == .Windows {
		if len(a) != len(b) do return false
		for i in 0 ..< len(a) {
			if ascii_lower(a[i]) != ascii_lower(b[i]) do return false
		}
		return true
	} else {
		return a == b
	}
}


@(private = "file")
ascii_lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c
}
