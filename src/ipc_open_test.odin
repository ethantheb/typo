package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "ipc"


// typo in a terminal sends its files to the window's listener, which queues
// those that can open (missing ones open empty) and refuses the others;
// folders, --new and an endpoint nobody serves start a new window instead.
// One test, since the listener and the environment are the process's
@(test)
test_forward_to_window :: proc(t: ^testing.T) {
	// A folder with a file in it
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s%ctypo-ipc-test-%d", tmp, os.Path_Separator, os.get_pid())
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	file := fmt.tprintf("%s%cnotes.md", dir, os.Path_Separator)
	testing.expect(t, os.write_entire_file(file, transmute([]u8)string("# notes\n")) == nil)
	new_file := fmt.tprintf("%s%cnew.md", dir, os.Path_Separator)
	no_folder := fmt.tprintf("%s%cmissing%cx.md", dir, os.Path_Separator, os.Path_Separator)

	// The window's listener, named in the environment as in its terminals
	ipc_init()
	defer ipc_destroy()
	env := ipc_shell_env()
	testing.expect_value(t, len(env), 1)
	if len(env) != 1 do return
	_, _, endpoint := strings.partition(env[0], "=")
	os.set_env(ipc.ENV_NAME, endpoint)
	defer os.unset_env(ipc.ENV_NAME)

	// Files open in the window, an existing one and a new one
	code, forwarded := forward_to_window({paths = {file, new_file}})
	testing.expect(t, forwarded && code == 0)
	expect_queued(t, {file, new_file})

	// A file in a folder that doesn't exist is refused; the rest still open
	code, forwarded = forward_to_window({paths = {no_folder, file}})
	testing.expect(t, forwarded && code == 1)
	expect_queued(t, {file})

	// New windows
	_, forwarded = forward_to_window({paths = {dir}})
	testing.expect(t, !forwarded, "a folder was sent")
	_, forwarded = forward_to_window({paths = {file}, new_window = true})
	testing.expect(t, !forwarded, "--new was sent")
	os.set_env(ipc.ENV_NAME, `\\.\pipe\typo-1-0` when ODIN_OS == .Windows else "/none/ipc.sock")
	_, forwarded = forward_to_window({paths = {file}})
	testing.expect(t, !forwarded, "sent to an endpoint nobody serves")
	testing.expect(t, !ipc_busy())
}


// The next queued request becomes the pending action, with these files
@(private = "file")
expect_queued :: proc(t: ^testing.T, paths: []string, loc := #caller_location) {
	g.pending = nil
	ipc_frame()

	a, is_open := g.pending.(Open_Files)
	testing.expect(t, is_open, "no files to open", loc = loc)
	if !is_open do return
	defer delete_paths(a.paths)
	g.pending = nil

	testing.expect(t, a.raise, "the window isn't raised", loc = loc)
	testing.expect_value(t, len(a.paths), len(paths), loc)
	for path, i in paths {
		if i < len(a.paths) do testing.expect_value(t, a.paths[i], path, loc)
	}
}
