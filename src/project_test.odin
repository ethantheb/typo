package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

// Projects: their settings layered over the user's, pinned files kept in
// .typo/settings.toml, each project's state saved and restored by itself, and
// an older typo's session.json taken over. Tests don't start the config
// thread, so its jobs run at once


// A project's settings set only what they name, and win over the user's;
// user-only settings and keybindings are refused; the file reads back as written
@(test)
test_settings_layers :: proc(t: ^testing.T) {
	s: Settings
	settings_reset_all(&s)
	defer settings_destroy(&s)

	text := `[appearance]
theme = "one-light"

[general]
recent_files = 9
restore_session = false

[keybindings]
save = "F2"

[project]
pinned = ["src/a.odin", "notes.md"]
`
	loaded := settings_parse(text, .Project)
	testing.expect(t, loaded.read)
	testing.expect_value(t, loaded.set, bit_set[Setting]{.Theme, .Recent_Files})
	testing.expect(t, strings.contains(loaded.problems, "general.restore_session"))
	testing.expect(t, strings.contains(loaded.problems, "keybindings"))
	expect_files(t, loaded.pinned[:], {"src/a.odin", "notes.md"})
	settings_take_project(&s, &loaded)

	// The project's values in effect, the user's elsewhere
	default_theme := SETTINGS[.Theme].default.(string)
	testing.expect_value(t, s.theme, "one-light")
	testing.expect_value(t, s.recent_files, 9)
	testing.expect_value(t, s.user.theme, default_theme)
	testing.expect_value(t, s.restore_session, true)

	// A change of the user's: shadowed where the project sets it
	set_string(&s.user.theme, "one-dark")
	s.user.font_size = 18
	settings_resolve(&s)
	testing.expect_value(t, s.theme, "one-light")
	testing.expect_value(t, s.font_size, 18)

	// The project's file as written reads back the same
	again := settings_parse(project_settings_text(&s.project, {"src/a.odin"}), .Project)
	defer loaded_settings_destroy(&again)
	testing.expect(t, again.read && again.problems == "")
	testing.expect_value(t, again.set, s.project.set)
	testing.expect_value(t, again.values.theme, "one-light")
	testing.expect_value(t, again.values.recent_files, 9)
	expect_files(t, again.pinned[:], {"src/a.odin"})

	// Without it the user's apply again; an empty layer writes nothing
	settings_clear_project(&s)
	testing.expect_value(t, s.theme, "one-dark")
	testing.expect_value(t, s.recent_files, SETTINGS[.Recent_Files].default.(int))
	testing.expect_value(t, project_settings_text(&s.project, nil), "")
}


// Pins go to .typo/settings.toml, relative to the project with forward
// slashes, the folder made with a .gitignore; they follow a rename, and RECENT
// lists them first, then the recent files up to the setting
@(test)
test_project_pins_persist :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	root := temp_project("pins")
	defer os.remove_all(root)

	saved_count := g.settings.recent_files
	defer {
		g.settings.recent_files = saved_count
		project_destroy()
		recent_destroy(&g.recent)
	}
	set_string(&g.project.root, root)

	// Pinned: written, with the folder's .gitignore
	x := in_dir(root, "sub", "x.md")
	project_pin(x)
	project_pin(x)
	testing.expect(t, g.project.has_dir && g.project.has_file)
	ignore, _ := os.read_entire_file(in_dir(root, ".typo", ".gitignore"), context.temp_allocator)
	testing.expect_value(t, string(ignore), TYPO_GITIGNORE)
	expect_files(t, written_pins(root), {"sub/x.md"})

	// Read back as full paths
	project_pins_read({"sub/x.md", "sub/x.md", "other.txt"})
	expect_files(t, g.project.pinned[:], {x, in_dir(root, "other.txt")})
	project_unpin(in_dir(root, "other.txt"))

	// A folder renamed in typo: the pin follows
	project_pins_renamed(in_dir(root, "sub"), in_dir(root, "lib"))
	expect_files(t, written_pins(root), {"lib/x.md"})
	x = in_dir(root, "lib", "x.md")

	// RECENT: the pinned file, then the recent ones up to the setting
	y := in_dir(root, "y.txt")
	z := in_dir(root, "z.txt")
	recent_load(&g.recent, {x, y, z})
	g.settings.recent_files = 1
	expect_rows(t, recent_rows(), {{x, true}, {y, false}})
	g.settings.recent_files = 0
	expect_rows(t, recent_rows(), {{x, true}})

	// Unpinned: the file stays, without it
	project_unpin(x)
	expect_files(t, written_pins(root), {})
	testing.expect_value(t, len(recent_rows()), 0)
}


// Each project's state is its own: leaving one saves its panes and recent
// files in its .typo folder, and opening it again brings them back. A project
// with nothing to keep gets no .typo folder
@(test)
test_project_restore :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	a_root := temp_project("restore-a")
	b_root := temp_project("restore-b")
	defer os.remove_all(a_root)
	defer os.remove_all(b_root)

	a := in_dir(a_root, "a.txt")
	_ = os.write_entire_file(a, transmute([]u8)string("in a\n"))

	// The user's setting: a project's landing works out the values in effect
	saved_restore := g.settings.user.restore_session
	g.settings.user.restore_session = true
	g.project.restored = true // the window keeps its size
	defer {
		g.settings.user.restore_session = saved_restore
		settings_resolve(&g.settings)
		panes_destroy()
		project_destroy()
		recent_destroy(&g.recent)
		workspace_destroy(&g.workspace)
		state_destroy()
		config_destroy()
		lsp_destroy()
	}

	// A, with a file used
	open_project(a_root)
	p := panes_open_file(a)
	testing.expect(t, pane_shown(p))
	expect_files(t, recent_files(), {a})

	// Left for B: A's state saved, its panes closed
	project_leave()
	session_path := project_file(a_root, PROJECT_SESSION)
	testing.expect(t, os.is_file(session_path), "A's state saved")
	testing.expect_value(t, len(g.panes.open), 0)

	open_project(b_root)
	testing.expect_value(t, len(g.panes.open), 0)
	testing.expect_value(t, len(recent_files()), 0)
	project_leave()
	testing.expect(t, !os.exists(project_file(b_root, "")), "nothing to keep: no .typo")

	// Back to A: its file shown again, and its recent files
	open_project(a_root)
	again := pane_with_file(a)
	testing.expect(t, again != nil && pane_shown(again), "A's file restored")
	expect_files(t, recent_files(), {a})

	// The saved paths are relative to the project
	data, _ := os.read_entire_file(session_path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"a.txt"`))
	testing.expect(t, !strings.contains(string(data), a_root))
}


// Saving as it goes writes the state when it changed, and only then
@(test)
test_session_saved_as_it_goes :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	root := temp_project("as-it-goes")
	defer os.remove_all(root)

	file := in_dir(root, "a.txt")
	_ = os.write_entire_file(file, transmute([]u8)string("a\n"))
	saved_sidebar := g.sidebar_visible
	defer {
		g.sidebar_visible = saved_sidebar
		panes_destroy()
		project_destroy()
		recent_destroy(&g.recent)
		workspace_destroy(&g.workspace)
		state_destroy()
		config_destroy()
		lsp_destroy()
	}

	// A project with a file used: its state written
	open_project(root)
	panes_open_file(file)
	session_save(leaving = false)
	path := project_file(root, PROJECT_SESSION)
	testing.expect(t, os.is_file(path), "the state is written")

	// Nothing changed: not written again
	_ = os.write_entire_file(path, transmute([]u8)string("stale"))
	session_save(leaving = false)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "stale")

	// The sidebar toggled: written
	g.sidebar_visible = !g.sidebar_visible
	session_save(leaving = false)
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"sidebar"`), "the change is written")
}


// The first start without state.json takes over an older typo's session.json:
// its folder is reopened with its panes, and each folder gets its recent files
@(test)
test_old_session_imported :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	dir := temp_project("import")
	defer os.remove_all(dir)

	old := `{
	"root": "C:/w",
	"sidebar": true,
	"panes": [{"file": "C:/w/a.odin", "caret": 3}],
	"layout": [{"pane": 0}],
	"focused": 0,
	"maximized": -1,
	"recent": [
		{"root": "C:/v", "files": ["C:/v/x.md"]},
		{"root": "C:/w", "files": ["C:/w/a.odin", "C:/w/b.odin"]}
	]
}`
	_ = os.write_entire_file(in_dir(dir, "session.json"), transmute([]u8)old)

	saved_path := g.settings.path
	g.settings.path = in_dir(dir, "settings.toml")
	defer {
		g.settings.path = saved_path
		state_destroy()
	}

	state_init()
	testing.expect_value(t, state_last_project(), "C:/w")

	w, has_w := state_take_imported("C:/w")
	testing.expect(t, has_w)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, w.panes[0].caret, 3)
	expect_files(t, w.recent_files, {"C:/w/a.odin", "C:/w/b.odin"})

	v, has_v := state_take_imported("C:/v")
	testing.expect(t, has_v)
	expect_files(t, v.recent_files, {"C:/v/x.md"})

	_, again := state_take_imported("C:/w")
	testing.expect(t, !again, "taken once")
}


// Opens a folder as the workspace and the project, as open_folder does
// without the window
@(private = "file")
open_project :: proc(root: string) {
	workspace_open(&g.workspace, root)
	project_open(root, as_folder = true)
}


// An empty folder for a test, in the temp folder
@(private = "file")
temp_project :: proc(name: string) -> string {
	tmp := os.temp_directory(context.temp_allocator) or_else "."
	dir := fmt.tprintf("%s%ctypo-project-%s-%d", tmp, os.Path_Separator, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return dir
}


@(private = "file")
in_dir :: proc(parts: ..string) -> string {
	return filepath.join(parts, context.temp_allocator) or_else ""
}


// The pinned files as the project's settings file lists them
@(private = "file")
written_pins :: proc(root: string) -> []string {
	loaded := settings_read_file(project_file(root, PROJECT_SETTINGS), .Project)
	defer loaded_settings_destroy(&loaded)

	pins := make([]string, len(loaded.pinned), context.temp_allocator)
	for pin, i in loaded.pinned do pins[i] = strings.clone(pin, context.temp_allocator)
	return pins
}


@(private = "file")
expect_rows :: proc(t: ^testing.T, got, want: []Recent_Row, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc)
	for row, i in want {
		if i < len(got) do testing.expect_value(t, got[i], row, loc)
	}
}
