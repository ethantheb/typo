package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"

// The recent files: their order, their bounds, files deleted and renamed, and
// the session keeping them


@(test)
test_recent_order :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	// Most recent first; a file used again moves to the front, once
	recent_add(&r, "/w", "/w/a")
	recent_add(&r, "/w", "/w/b")
	recent_add(&r, "/w", "/w/c")
	recent_add(&r, "/w", "/w/a")
	recent_add(&r, "/w", "/w/a")
	expect_files(t, recent_list(&r, "/w"), {"/w/a", "/w/c", "/w/b"})

	// Each folder has its own list
	recent_add(&r, "/v", "/v/x")
	expect_files(t, recent_list(&r, "/v"), {"/v/x"})
	expect_files(t, recent_list(&r, "/w"), {"/w/a", "/w/c", "/w/b"})
	testing.expect(t, recent_list(&r, "/none") == nil)

	// Paths ignore case on Windows
	when ODIN_OS == .Windows {
		recent_add(&r, "/W", "/W/B")
		expect_files(t, recent_list(&r, "/w"), {"/w/b", "/w/a", "/w/c"})
	}
}


@(test)
test_recent_bounds :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	// The oldest file goes once a folder has RECENT_MAX_FILES
	for i in 0 ..= RECENT_MAX_FILES {
		recent_add(&r, "/w", fmt.tprintf("/w/%d", i))
	}
	files := recent_list(&r, "/w")
	testing.expect_value(t, len(files), RECENT_MAX_FILES)
	testing.expect_value(t, files[0], fmt.tprintf("/w/%d", RECENT_MAX_FILES))
	testing.expect_value(t, files[len(files) - 1], "/w/1")

	// And the folder used longest ago once there are RECENT_MAX_FOLDERS
	for i in 1 ..= RECENT_MAX_FOLDERS {
		root := fmt.tprintf("/f%d", i)
		recent_add(&r, root, fmt.tprintf("%s/x", root))
	}
	testing.expect_value(t, len(r.folders), RECENT_MAX_FOLDERS)
	testing.expect(t, recent_list(&r, "/w") == nil, "the oldest folder is kept")
	testing.expect(t, recent_list(&r, "/f1") != nil)
}


@(test)
test_recent_deleted_and_renamed :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	sep := filepath.SEPARATOR_STRING
	a := in_w("/w", "src", "a.odin")
	b := in_w("/w", "src", "b.odin")
	notes := in_w("/w", "notes.md")
	recent_add(&r, "/w", a)
	recent_add(&r, "/w", notes)
	recent_add(&r, "/w", b)

	// A folder renamed: the files in it follow
	src := in_w("/w", "src")
	lib := in_w("/w", "lib")
	recent_renamed(&r, src, lib)
	lib_b := fmt.tprintf("%s%sb.odin", lib, sep)
	lib_a := fmt.tprintf("%s%sa.odin", lib, sep)
	expect_files(t, recent_list(&r, "/w"), {lib_b, notes, lib_a})

	// A file deleted, then a folder: they and what was in it leave
	recent_forget(&r, notes)
	expect_files(t, recent_list(&r, "/w"), {lib_b, lib_a})
	recent_forget(&r, lib)
	expect_files(t, recent_list(&r, "/w"), {})
}


// session.json keeps the lists, also when the session isn't restored
@(test)
test_recent_session_round_trip :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	// Settings (and so session.json) in a folder of their own
	tmp := os.temp_directory(context.temp_allocator) or_else "."
	dir := fmt.tprintf("%s%ctypo-recent-test-%d", tmp, os.Path_Separator, os.get_pid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	saved_settings := g.settings
	saved_root := g.workspace.root
	defer {
		g.settings = saved_settings
		g.workspace.root = saved_root
		recent_destroy(&g.recent)
	}
	g.settings.path = fmt.tprintf("%s%csettings.toml", dir, os.Path_Separator)
	g.settings.restore_session = false
	g.workspace.root = "/w"

	recent_add(&g.recent, "/v", "/v/x")
	recent_add(&g.recent, "/w", "/w/a")
	recent_add(&g.recent, "/w", "/w/b")
	session_save()

	s, ok := session_read()
	testing.expect(t, ok, "no session saved")
	testing.expect_value(t, s.root, "") // only the recent files

	loaded: Recent_Files
	defer recent_destroy(&loaded)
	recent_load(&loaded, s.recent)
	expect_files(t, recent_list(&loaded, "/w"), {"/w/b", "/w/a"})
	expect_files(t, recent_list(&loaded, "/v"), {"/v/x"})
	testing.expect_value(t, loaded.folders[0].root, "/w") // the folder used last first
}


@(private = "file")
in_w :: proc(parts: ..string) -> string {
	return filepath.join(parts, context.temp_allocator) or_else ""
}


@(private = "file")
expect_files :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for path, i in want {
		if i < len(got) do testing.expect_value(t, got[i], path, loc)
	}
}
