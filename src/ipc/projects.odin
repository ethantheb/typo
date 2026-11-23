package ipc

// Endpoints by project, for shells that outlive the typo that started them
// (persistent terminals in herdr-core). Their ENV_NAME can't name an endpoint,
// which ends with its typo, so it holds a project's name instead
// ("project:<hash of its folder>"). Each typo window lists its endpoint under
// the project it shows, in a folder only the current user can use (a file
// named after its process, holding the endpoint); a client tries the newest
// first. Endpoints read there still go through connect's checks

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"


PROJECT_PREFIX :: "project:"


// A project's name for ENV_NAME (temp)
project_name :: proc(root: string) -> string {
	key, _ := filepath.clean(root, context.temp_allocator)
	when ODIN_OS == .Windows {
		key = strings.to_lower(key, context.temp_allocator)
	}
	return fmt.tprintf("%s%016x", PROJECT_PREFIX, hash.fnv64a(transmute([]u8)key))
}


// Lists `endpoint` under the project `name`; false if it can't be written
project_register :: proc(name, endpoint: string) -> bool {
	dir := project_dir(name, create = true)
	if dir == "" do return false

	path := entry_path(dir)
	return os.write_entire_file(path, transmute([]u8)endpoint) == nil
}


// Takes this process's entry off the project's list
project_unregister :: proc(name: string) {
	dir := project_dir(name, create = false)
	if dir == "" do return

	_ = os.remove(entry_path(dir))
	_ = os.remove(dir) // only once empty
}


// The project's endpoints, the most recently listed first (temp)
project_endpoints :: proc(name: string) -> []string {
	dir := project_dir(name, create = false)
	if dir == "" do return nil

	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil
	slice.sort_by(infos, newer)

	endpoints := make([dynamic]string, context.temp_allocator)
	for info in infos {
		if info.type != .Regular do continue

		data, read_err := os.read_entire_file(info.fullpath, context.temp_allocator)
		if read_err == nil && len(data) > 0 && len(data) < 1024 {
			append(&endpoints, string(data))
		}
	}
	return endpoints[:]
}


// Drops an entry whose endpoint no longer answers (its typo has exited)
project_forget :: proc(name, endpoint: string) {
	dir := project_dir(name, create = false)
	if dir == "" do return

	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return

	for info in infos {
		data, read_err := os.read_entire_file(info.fullpath, context.temp_allocator)
		if read_err == nil && string(data) == endpoint {
			_ = os.remove(info.fullpath)
		}
	}
}


@(private = "file")
newer :: proc(a, b: os.File_Info) -> bool {
	return time.diff(b.modification_time, a.modification_time) < 0
}


// The project's folder in the registry, or "" (made if `create`). Only a
// name project_name makes is used
@(private = "file")
project_dir :: proc(name: string, create: bool) -> string {
	if !strings.has_prefix(name, PROJECT_PREFIX) do return ""

	key := name[len(PROJECT_PREFIX):]
	if len(key) != 16 do return ""
	for c in key {
		if !strings.contains_rune("0123456789abcdef", c) do return ""
	}

	root := registry_root(create)
	if root == "" do return ""

	dir, _ := filepath.join({root, key}, context.temp_allocator)
	user_only := os.Permissions{.Read_User, .Write_User, .Execute_User}
	if create && !os.is_dir(dir) && os.make_directory(dir, user_only) != nil {
		return ""
	}
	return dir
}


@(private = "file")
entry_path :: proc(dir: string) -> string {
	path, _ := filepath.join({dir, fmt.tprint(os.get_pid())}, context.temp_allocator)
	return path
}
