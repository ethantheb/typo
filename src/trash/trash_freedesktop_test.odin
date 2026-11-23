#+build linux, freebsd, openbsd, netbsd
package trash

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// A file moves into the home trash under its name, with a .trashinfo saying
// where it was; a second file of the same name gets another name there. The
// home trash is a temp folder (XDG_DATA_HOME), so nothing reaches the real one
@(test)
test_freedesktop_move :: proc(t: ^testing.T) {
	root, _ := os.make_directory_temp("", "typo-trash-test", context.temp_allocator)
	defer os.remove_all(root)

	saved := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", root)
	defer os.set_env("XDG_DATA_HOME", saved)

	// Two files called "a b.txt", in turn
	source, _ := filepath.join({root, "a b.txt"}, context.temp_allocator)
	for _ in 0 ..< 2 {
		_ = os.write_entire_file(source, transmute([]u8)string("x"))
		testing.expect_value(t, move(source), Result.Done)
		testing.expect(t, !os.exists(source))
	}

	// Both in files/, each with its info
	trash, _ := filepath.join({root, "Trash"}, context.temp_allocator)
	for name in ([]string{"a b.txt", "a b.txt.2"}) {
		file, _ := filepath.join({trash, "files", name}, context.temp_allocator)
		testing.expect(t, os.exists(file), name)

		info_name := strings.concatenate({name, ".trashinfo"}, context.temp_allocator)
		info, _ := filepath.join({trash, "info", info_name}, context.temp_allocator)
		text, ok := os.read_entire_file(info, context.temp_allocator)
		testing.expect(t, ok == nil, info_name)
		testing.expect(t, strings.has_prefix(string(text), "[Trash Info]\nPath="))
		testing.expect(t, strings.contains(string(text), "a%20b.txt\nDeletionDate="))
	}
}
