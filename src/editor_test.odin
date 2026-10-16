package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "buffer"

// Unit tests for the main package: editing operations, matching and settings,
// without a window. Run with: python build.py --test

@(private = "file")
make_editor :: proc(text: string) -> (e: Editor) {
	g.settings.font_size = 15
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(text))
	e.status = .Text
	append(&e.sels, Selection{0, 0, -1})
	return
}

@(private = "file")
destroy_editor :: proc(e: ^Editor) {
	buffer.buffer_destroy(&e.buf)
	delete(e.sels)
}

@(private = "file")
contents :: proc(e: ^Editor) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
}

@(test)
test_multi_cursor_edits :: proc(t: ^testing.T) {
	e := make_editor("one\ntwo\nthree")
	defer destroy_editor(&e)
	editor_add_cursor_vertical(&e, +1)
	editor_add_cursor_vertical(&e, +1)
	testing.expect_value(t, len(e.sels), 3)
	editor_insert(&e, "> ")
	testing.expect_value(t, contents(&e), "> one\n> two\n> three")
	editor_delete(&e, -1, word = false)
	testing.expect_value(t, contents(&e), ">one\n>two\n>three")
	editor_undo(&e)
	testing.expect_value(t, contents(&e), "> one\n> two\n> three")
	editor_single_cursor(&e)
	testing.expect_value(t, len(e.sels), 1)
}

@(test)
test_newline_keeps_indent :: proc(t: ^testing.T) {
	e := make_editor("\tif x {")
	defer destroy_editor(&e)
	editor_move(&e, .Doc_End, false)
	editor_newline(&e)
	editor_insert(&e, "y")
	testing.expect_value(t, contents(&e), "\tif x {\n\ty")
}

@(test)
test_movement :: proc(t: ^testing.T) {
	e := make_editor("    foo_bar(baz)\r\nnext")
	defer destroy_editor(&e)
	testing.expect(t, e.buf.crlf)
	editor_move(&e, .Home, false) // to the first non-blank
	testing.expect_value(t, e.sels[0].head, 4)
	editor_move(&e, .Word_Right, false)
	testing.expect_value(t, e.sels[0].head, 11) // after foo_bar
	editor_move(&e, .End, false)
	testing.expect_value(t, e.sels[0].head, 16)
	editor_move(&e, .Right, false) // over "\r\n" in one step
	testing.expect_value(t, e.sels[0].head, 18)
	editor_move(&e, .Up, true)
	testing.expect_value(t, e.sels[0], Selection{18, 0, 0})
}

@(test)
test_columns :: proc(t: ^testing.T) {
	text := "\tab\tc"
	testing.expect_value(t, visual_col(text, 1), 4)
	testing.expect_value(t, visual_col(text, 4), 8)
	testing.expect_value(t, byte_at_col(text, 1), 0) // nearer the tab's start
	testing.expect_value(t, byte_at_col(text, 3), 1)
	testing.expect_value(t, byte_at_col(text, 9), 5)
}

@(test)
test_fuzzy :: proc(t: ^testing.T) {
	defer fuzzy_destroy()
	_, ok := fuzzy_score("edv", "src/editor_view.odin")
	testing.expect(t, ok)
	_, ok = fuzzy_score("xyz", "src/editor_view.odin")
	testing.expect(t, !ok)
	// Consecutive matches at a boundary beat scattered ones.
	a, _ := fuzzy_score("term", "src/terminal.odin")
	b, _ := fuzzy_score("term", "src/theme_error_map.odin")
	testing.expect(t, a > b)
	path := "src/terminal_edit.odin"
	picked := strings.builder_make(context.temp_allocator)
	for m, i in fuzzy_positions("ted", path) do if m do strings.write_byte(&picked, path[i])
	testing.expect_value(t, strings.to_string(picked), "ted")
}

@(test)
test_shell_display_name :: proc(t: ^testing.T) {
	testing.expect_value(t, shell_display_name("pwsh -NoLogo"), "POWERSHELL")
	testing.expect_value(t, shell_display_name(`"C:\Program Files\Git\bin\bash.exe" --login`), "BASH")
	testing.expect_value(t, shell_display_name("/bin/zsh"), "ZSH")
	testing.expect_value(t, shell_display_name(""), "TERMINAL")
}

@(test)
test_relative_to_root :: proc(t: ^testing.T) {
	g.workspace.root = `C:\work`
	defer g.workspace.root = ""
	testing.expect_value(t, relative_to_root(`C:\work\src\a.odin`), `src\a.odin`)
	testing.expect_value(t, relative_to_root(`C:\workshop\a.odin`), `C:\workshop\a.odin`)
	g.workspace.root = `C:\`
	testing.expect_value(t, relative_to_root(`C:\a.odin`), `a.odin`)
}

// Valid values load, invalid ones fall back to their defaults and are
// reported, and saving then loading gives the same settings.
@(test)
test_settings_round_trip :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/typo-settings-test-%d.toml", os.temp_directory(context.temp_allocator) or_else ".", os.get_pid())
	defer os.remove(path)
	_ = os.write_entire_file(path, `
[appearance]
theme = "light"
font_size = 99
[terminal]
shell = "  bash  "
[keybindings]
save = ["Ctrl+Shift+S", "F2"]
undo = "Nonsense+Q"
`)
	s: Settings
	settings_reset_all(&s)
	s.path = strings.clone(path)
	defer settings_destroy(&s)
	settings_load(&s)
	testing.expect_value(t, s.theme, "light")
	testing.expect_value(t, s.font_size, SETTINGS[.Font_Size].default.(int))
	testing.expect_value(t, s.terminal_shell, "bash")
	testing.expect_value(t, bindings_label(s.bindings[.Save], " "), "Ctrl+Shift+S F2")
	testing.expect(t, strings.contains(s.error, "appearance.font_size"))
	testing.expect(t, strings.contains(s.error, "Nonsense+Q"))

	settings_save(&s)
	again: Settings
	settings_reset_all(&again)
	again.path = strings.clone(path)
	defer settings_destroy(&again)
	settings_load(&again)
	testing.expect_value(t, again.error, "")
	testing.expect_value(t, again.theme, s.theme)
	testing.expect_value(t, again.terminal_shell, s.terminal_shell)
	testing.expect_value(t, again.bindings, s.bindings)
}
