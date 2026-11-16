#+build windows
package lsp

import "core:os"
import "core:path/filepath"
import "core:strings"


// The full path of the program `name` would run, or "" if there is none. A name
// without a folder is looked up on PATH, trying each PATHEXT extension when it
// has none of its own (npm installs servers as .cmd files)
find_executable :: proc(name: string, allocator := context.allocator) -> string {
	if name == "" do return ""

	// A path, absolute or relative (to the working directory)
	if strings.contains_any(name, `/\`) {
		found := try_extensions(name)
		if found == "" do return ""

		full, err := os.get_absolute_path(found, allocator)
		return err == nil ? full : ""
	}

	// Each folder on PATH
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ";") {
		if dir == "" do continue

		full, _ := filepath.join({strings.trim(dir, `"`), name}, context.temp_allocator)
		found := try_extensions(full)
		if found != "" do return strings.clone(found, allocator)
	}
	return ""
}


// `path` itself if it has an extension and exists, else the first PATHEXT
// extension that exists
@(private = "file")
try_extensions :: proc(path: string) -> string {
	if filepath.ext(path) != "" && os.is_file(path) {
		return path
	}

	exts := os.get_env("PATHEXT", context.temp_allocator)
	if exts == "" do exts = ".COM;.EXE;.BAT;.CMD"
	for ext in strings.split_iterator(&exts, ";") {
		if ext == "" do continue

		lower := strings.to_lower(ext, context.temp_allocator)
		candidate := strings.concatenate({path, lower}, context.temp_allocator)
		if os.is_file(candidate) do return candidate
	}
	return ""
}
