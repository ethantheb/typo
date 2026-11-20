package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "buffer"
import "gfx"
import "textedit"
import sdl "../vendor/sdl3"

// Unit tests for the main package: editing operations, matching and settings,
// without a window. Run with: python build.py --test


// Tests run on several threads; those that change the app's state in `g`
// (settings, find, language servers, the workspace) take turns with this
@(private)
app_state_lock: sync.Mutex


@(private = "file")
make_editor :: proc(text: string) -> (e: Editor) {
	g.settings.font_size = 15
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(text))
	e.status = .Text
	e.kind = &TEXT_KIND
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


// A path for a test file in the temp directory
@(private = "file")
temp_test_path :: proc(name: string) -> string {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	return fmt.tprintf("%s/%s-%d", dir, name, os.get_pid())
}


@(test)
test_multi_cursor_edits :: proc(t: ^testing.T) {
	e := make_editor("one\ntwo\nthree")
	defer destroy_editor(&e)

	textedit.add_cursor_vertical(&e, +1)
	textedit.add_cursor_vertical(&e, +1)
	testing.expect_value(t, len(e.sels), 3)

	textedit.insert(&e, "> ")
	testing.expect_value(t, contents(&e), "> one\n> two\n> three")

	textedit.delete_text(&e, -1, word = false)
	testing.expect_value(t, contents(&e), ">one\n>two\n>three")

	textedit.undo(&e)
	testing.expect_value(t, contents(&e), "> one\n> two\n> three")

	textedit.single_cursor(&e)
	testing.expect_value(t, len(e.sels), 1)
}


@(test)
test_newline_keeps_indent :: proc(t: ^testing.T) {
	e := make_editor("\tif x {")
	defer destroy_editor(&e)

	textedit.move(&e, .Doc_End, false)
	editor_handle_key(&e, {key = sdl.K_RETURN})
	textedit.insert(&e, "y")
	testing.expect_value(t, contents(&e), "\tif x {\n\ty")
}


@(test)
test_movement :: proc(t: ^testing.T) {
	e := make_editor("    foo_bar(baz)\r\nnext")
	defer destroy_editor(&e)
	testing.expect(t, e.buf.crlf)

	textedit.move(&e, .Home, false) // to the first non-blank
	testing.expect_value(t, e.sels[0].head, 4)

	textedit.move(&e, .Word_Right, false)
	testing.expect_value(t, e.sels[0].head, 11) // after foo_bar

	textedit.move(&e, .End, false)
	testing.expect_value(t, e.sels[0].head, 16)

	textedit.move(&e, .Right, false) // over "\r\n" in one step
	testing.expect_value(t, e.sels[0].head, 18)

	textedit.move(&e, .Up, true)
	testing.expect_value(t, e.sels[0], Selection{18, 0, 0})
}


// The text view scrolls sideways as far as the widest line it has shown, with
// room for the caret: lines come into view or under the caret, follow the
// lines edited above them, and an edit to the widest line has it measured again
@(test)
test_sideways_scrolling :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	long := strings.repeat("x", 200, context.temp_allocator)
	short := strings.repeat("s\n", 10, context.temp_allocator)
	e := make_editor(strings.concatenate({short, long, "\nend"}, context.temp_allocator))
	defer destroy_editor(&e)
	editor_attach(&e)

	g.settings.line_height = 1.4
	e.char_w = editor_char_width(textedit.zoom(&e))
	e.view = {0, 0, 400, f32(text_line_height(&e) * 2)}

	// The long line (10) is out of view
	next_frame(&e)
	testing.expect_value(t, sideways(&e), 0)

	// The caret goes to its end
	end := buffer.line_end(&e.buf, 10)
	textedit.set_single_selection(&e, {end, end, -1})
	e.kind.reveal(&e)
	text_w := e.view.w - e.gutter_w - TEXT_MARGIN - 2 * e.char_w
	testing.expect_value(t, sideways(&e), 200 * e.char_w - text_w)
	testing.expect(t, e.target_x > 0)

	// Typing on it widens it
	editor_text_input(&e, "y")
	next_frame(&e)
	testing.expect_value(t, sideways(&e), 201 * e.char_w - text_w)

	// Deleting its text narrows it
	start := buffer.line_start(&e.buf, 10)
	textedit.set_single_selection(&e, {start, end + 1, -1})
	editor_handle_key(&e, {key = sdl.K_BACKSPACE})
	next_frame(&e)
	testing.expect_value(t, sideways(&e), 0)

	// Back, then lines added above it
	textedit.undo(&e)
	next_frame(&e)
	testing.expect_value(t, e.widest.line, 10)
	testing.expect_value(t, e.widest.cols, 201)
	textedit.set_single_selection(&e, {0, 0, -1})
	editor_handle_key(&e, {key = sdl.K_RETURN})
	editor_handle_key(&e, {key = sdl.K_RETURN})
	textedit.take_changes(&e)
	testing.expect_value(t, e.widest.line, 12)
	testing.expect_value(t, e.widest.cols, 201)

	// A tab and wide characters count as columns, not bytes
	end = buffer.line_end(&e.buf, 12)
	textedit.set_single_selection(&e, {end, end, -1})
	editor_text_input(&e, "\té")
	next_frame(&e)
	testing.expect_value(t, e.widest.cols, 205) // the tab to 204
}


// What an editor's frame does with the edits and the lines in view before it
// scrolls
@(private = "file")
next_frame :: proc(e: ^Editor) {
	textedit.take_changes(e)
	e.kind.frame_begin(e)
}


@(private = "file")
sideways :: proc(e: ^Editor) -> f32 {
	max_x, _ := editor_sideways(e)
	return max_x
}


@(test)
test_shell_display_name :: proc(t: ^testing.T) {
	git_bash := `"C:\Program Files\Git\bin\bash.exe" --login`

	testing.expect_value(t, shell_display_name("pwsh -NoLogo"), "PowerShell")
	testing.expect_value(t, shell_display_name(git_bash), "bash")
	testing.expect_value(t, shell_display_name("/bin/zsh"), "zsh")
	testing.expect_value(t, shell_display_name(""), "Terminal")
}


@(test)
test_relative_to_root :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	g.workspace.root = `C:\work`
	defer g.workspace.root = ""

	testing.expect_value(t, relative_to_root(`C:\work\src\a.odin`), `src\a.odin`)
	testing.expect_value(t, relative_to_root(`C:\workshop\a.odin`), `C:\workshop\a.odin`)

	g.workspace.root = `C:\`
	testing.expect_value(t, relative_to_root(`C:\a.odin`), `a.odin`)
}


// Directories come first, then files, each sorted case-insensitively
@(test)
test_workspace_open :: proc(t: ^testing.T) {
	// A folder with a subfolder and two files
	root := temp_test_path("typo-workspace-test")
	root = os.get_absolute_path(root, context.temp_allocator) or_else root
	_ = os.make_directory_all(fmt.tprintf("%s/sub", root))
	_ = os.write_entire_file(fmt.tprintf("%s/b.txt", root), "")
	_ = os.write_entire_file(fmt.tprintf("%s/A.txt", root), "")
	defer os.remove_all(root)

	ws: Workspace
	workspace_open(&ws, root)
	defer workspace_destroy(&ws)

	names := [?]string{"sub", "A.txt", "b.txt"}
	testing.expect_value(t, len(ws.visible), len(names))
	if len(ws.visible) != len(names) do return

	for name, i in names {
		node := ws.nodes[ws.visible[i]]
		testing.expect_value(t, node.name, name)
		testing.expect_value(t, node.is_dir, i == 0)
		testing.expect_value(t, node.path, fmt.tprintf("%s%c%s", root, os.Path_Separator, name))
	}
}


// Valid values load, invalid ones fall back to their defaults and are
// reported, and saving then loading gives the same settings
@(test)
test_settings_round_trip :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s.toml", temp_test_path("typo-settings-test"))
	defer os.remove(path)

	_ = os.write_entire_file(path, `
[appearance]
theme = "one-light"
[font]
size = 99
line_height = 1.5
letter_spacing = 1
[terminal]
shell = "  bash  "
[keybindings]
save = ["Ctrl+Shift+S", "F2"]
undo = "Nonsense+Q"
go_back = ["Alt+Left", "ctrl+mouse4"]
`)

	// Load
	s: Settings
	settings_reset_all(&s)
	s.path = strings.clone(path)
	defer settings_destroy(&s)
	settings_load(&s)

	testing.expect_value(t, s.theme, "one-light")
	testing.expect_value(t, s.font_size, SETTINGS[.Font_Size].default.(int))
	testing.expect_value(t, s.line_height, 1.5)
	testing.expect_value(t, s.letter_spacing, 1.0)
	testing.expect_value(t, s.terminal_shell, "bash")
	testing.expect_value(t, bindings_label(s.bindings[.Save], " "), "Ctrl+Shift+S F2")
	testing.expect_value(t, bindings_label(s.bindings[.Go_Back], " "), "Alt+Left Ctrl+Mouse4")
	testing.expect(t, strings.contains(s.error, "font.size"))
	testing.expect(t, strings.contains(s.error, "Nonsense+Q"))

	// Save, and load again
	settings_save(&s)
	testing.expect_value(t, s.error, "") // the saved file has no problems

	again: Settings
	settings_reset_all(&again)
	again.path = strings.clone(path)
	defer settings_destroy(&again)
	settings_load(&again)

	testing.expect_value(t, again.error, "")
	testing.expect_value(t, again.theme, s.theme)
	testing.expect_value(t, again.line_height, s.line_height)
	testing.expect_value(t, again.letter_spacing, s.letter_spacing)
	testing.expect_value(t, again.terminal_shell, s.terminal_shell)
	testing.expect_value(t, again.bindings, s.bindings)
}


// Chords name a key or a mouse side button; the side buttons go back and forward
@(test)
test_mouse_button_chords :: proc(t: ^testing.T) {
	back, back_ok := parse_chord("Mouse4")
	testing.expect(t, back_ok)
	testing.expect_value(t, back, Chord{button = sdl.BUTTON_X1})
	testing.expect_value(t, format_chord(back), "Mouse4")

	forward, forward_ok := parse_chord("Shift+mouse5")
	testing.expect(t, forward_ok)
	testing.expect_value(t, forward, Chord{button = sdl.BUTTON_X2, shift = true})
	testing.expect_value(t, format_chord(forward), "Shift+Mouse5")

	// The buttons that click aren't chords
	_, left_ok := parse_chord("Mouse1")
	testing.expect(t, !left_ok)
	_, left_is_chord := chord_from_button(sdl.BUTTON_LEFT)
	testing.expect(t, !left_is_chord)

	testing.expect_value(t, bindings_label(default_bindings(.Go_Back), " "), "Alt+Left Mouse4")
	testing.expect_value(t, bindings_label(default_bindings(.Go_Forward), " "), "Alt+Right Mouse5")
}


@(test)
test_number_settings :: proc(t: ^testing.T) {
	s: Settings
	settings_reset_all(&s)
	defer settings_destroy(&s)

	setting_step(&s, .Line_Height, +1)
	testing.expect_value(t, format_decimal(s.line_height), "1.4")

	setting_step(&s, .Font_Weight, -1)
	testing.expect_value(t, s.font_weight, 400)

	for _ in 0 ..< 100 do setting_step(&s, .Letter_Spacing, -1)
	testing.expect_value(t, s.letter_spacing, SETTINGS[.Letter_Spacing].min)

	testing.expect_value(t, format_decimal(0), "0.0")
	testing.expect_value(t, format_decimal(-0.25), "-0.25")
	testing.expect_value(t, format_decimal(2), "2.0")
}


// Keys whose names end in '+' (zoom in), with modifiers, and back from their
// names as saved
@(test)
test_chords_with_plus :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		chord: Chord,
	}

	// SDL names '+' by the layout's key for it ('=' where it is Shift+=)
	plus := sdl.GetKeyFromName("+")
	cases := [?]Case {
		{"Ctrl++", {key = plus, ctrl = true}},
		{"Ctrl+Keypad +", {key = sdl.K_KP_PLUS, ctrl = true}},
		{"Ctrl+Shift+=", {key = '=', ctrl = true, shift = true}},
		{"Keypad -", {key = sdl.K_KP_MINUS}},
		{"+", {key = plus}},
	}
	for c in cases {
		chord, ok := parse_chord(c.text)
		testing.expect(t, ok, c.text)
		testing.expect_value(t, chord, c.chord)

		again, again_ok := parse_chord(format_chord(chord))
		testing.expect(t, again_ok && again == chord, c.text)
	}

	for text in ([?]string{"Ctrl+", "", "Ctrl+Nonsense+A"}) {
		_, ok := parse_chord(text)
		testing.expect(t, !ok, text)
	}
}


// A fresh install writes the defaults; they must load back without problems
@(test)
test_default_settings_are_valid :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	path := fmt.tprintf("%s.toml", temp_test_path("typo-defaults-test"))
	defer os.remove(path)

	s: Settings
	settings_reset_all(&s)
	s.path = strings.clone(path)
	defer settings_destroy(&s)

	settings_save(&s)
	settings_load(&s)
	testing.expect_value(t, s.error, "")
	testing.expect_value(t, s.theme, gfx.DEFAULT_THEME)
	testing.expect_value(t, s.font_family, gfx.BUNDLED_FAMILY)
}
