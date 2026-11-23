#+build !windows
package process

import "core:os"
import "core:path/filepath"
import "core:strings"


// The full path of the program `name` would run, or "" if there is none. A name
// without a folder is looked up on PATH
find_executable :: proc(name: string, allocator := context.allocator) -> string {
	if name == "" do return ""

	// A path, absolute or relative (to the working directory)
	if strings.contains_rune(name, '/') {
		if !os.is_file(name) do return ""

		full, err := os.get_absolute_path(name, allocator)
		return err == nil ? full : ""
	}

	// Each folder on PATH
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ":") {
		if dir == "" do continue

		full, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.is_file(full) do return strings.clone(full, allocator)
	}
	return ""
}
