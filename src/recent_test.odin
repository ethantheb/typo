package editor

import "core:fmt"
import "core:path/filepath"
import "core:testing"

// The recent files: their order, their bound, files deleted and renamed. The
// project's session keeping them is in project_test.odin


@(test)
test_recent_order :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	// Most recent first; a file used again moves to the front, once
	recent_add(&r, "/w/a")
	recent_add(&r, "/w/b")
	recent_add(&r, "/w/c")
	recent_add(&r, "/w/a")
	recent_add(&r, "/w/a")
	expect_files(t, r.files[:], {"/w/a", "/w/c", "/w/b"})

	// Paths ignore case on Windows
	when ODIN_OS == .Windows {
		recent_add(&r, "/W/B")
		expect_files(t, r.files[:], {"/w/b", "/w/a", "/w/c"})
	}

	// A saved list replaces it, each file once
	recent_load(&r, {"/w/x", "/w/y", "/w/x", ""})
	expect_files(t, r.files[:], {"/w/x", "/w/y"})
}


@(test)
test_recent_bounds :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	// The oldest file goes once there are RECENT_MAX_FILES
	for i in 0 ..= RECENT_MAX_FILES {
		recent_add(&r, fmt.tprintf("/w/%d", i))
	}
	testing.expect_value(t, len(r.files), RECENT_MAX_FILES)
	testing.expect_value(t, r.files[0], fmt.tprintf("/w/%d", RECENT_MAX_FILES))
	testing.expect_value(t, r.files[len(r.files) - 1], "/w/1")
}


@(test)
test_recent_deleted_and_renamed :: proc(t: ^testing.T) {
	r: Recent_Files
	defer recent_destroy(&r)

	sep := filepath.SEPARATOR_STRING
	a := in_w("/w", "src", "a.odin")
	b := in_w("/w", "src", "b.odin")
	notes := in_w("/w", "notes.md")
	recent_add(&r, a)
	recent_add(&r, notes)
	recent_add(&r, b)

	// A folder renamed: the files in it follow
	src := in_w("/w", "src")
	lib := in_w("/w", "lib")
	recent_renamed(&r, src, lib)
	lib_b := fmt.tprintf("%s%sb.odin", lib, sep)
	lib_a := fmt.tprintf("%s%sa.odin", lib, sep)
	expect_files(t, r.files[:], {lib_b, notes, lib_a})

	// A file deleted, then a folder: they and what was in it leave
	recent_forget(&r, notes)
	expect_files(t, r.files[:], {lib_b, lib_a})
	recent_forget(&r, lib)
	expect_files(t, r.files[:], {})
}


@(private = "file")
in_w :: proc(parts: ..string) -> string {
	return filepath.join(parts, context.temp_allocator) or_else ""
}


expect_files :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for path, i in want {
		if i < len(got) do testing.expect_value(t, got[i], path, loc)
	}
}
