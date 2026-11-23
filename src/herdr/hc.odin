package herdr

// Finding herdr-core's command line, `hc`, and starting `hc connect`: the
// client's line to the core, with stdin and stdout on pipes and stderr
// discarded. It is started detached (package process): a core it starts
// inherits its job, and must outlive typo. If typo dies, its end of stdin
// closes and `hc connect` exits; the core and its terminals go on

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../process"


// Where hc is: on PATH (as hc or herdr-core), else where its installer puts
// it. "" if not found
find_hc :: proc(allocator := context.allocator) -> string {
	for name in ([]string{"hc", "herdr-core"}) {
		if path := process.find_executable(name, allocator); path != "" {
			return path
		}
	}

	for full in install_places() {
		if os.is_file(full) do return strings.clone(full, allocator)
	}
	return ""
}


// Starts `hc connect`. False if it can't be started
@(private)
connect_start :: proc(p: ^process.Process, hc: string) -> bool {
	options := process.Spawn_Options{discard_stderr = true, detached = true}
	ok, _ := process.process_spawn(p, {hc, "connect"}, "", options)
	return ok
}


// Where herdr-core's installer puts hc (temp)
@(private = "file")
install_places :: proc() -> []string {
	places := make([dynamic]string, context.temp_allocator)
	when ODIN_OS == .Windows {
		local := os.get_env("LOCALAPPDATA", context.temp_allocator)
		if local != "" {
			append(&places, join({local, "Programs", "herdr-core", "hc.exe"}))
		}
	} else {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			append(&places, join({home, ".local", "bin", "hc"}))
			append(&places, join({home, ".cargo", "bin", "hc"}))
		}
	}
	return places[:]
}


@(private = "file")
join :: proc(parts: []string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}
