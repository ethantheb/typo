package editor

import "core:fmt"
import "core:os"
import "core:testing"

// Several bindings per command: adding one, taking a chord from the command
// that had it, removing one, and settings.toml keeping them


@(test)
test_bindings_add_remove :: proc(t: ^testing.T) {
	b: Bindings
	for cmd in Command do b[cmd] = default_bindings(cmd)

	ctrl_g, _ := parse_chord("Ctrl+G")
	ctrl_b, _ := parse_chord("Ctrl+B")
	f6, _ := parse_chord("F6")

	// A second binding, after the first
	result, _, taken := bindings_add(&b, .Save, f6)
	testing.expect_value(t, result, Binding_Added.Added)
	testing.expect(t, !taken)
	testing.expect_value(t, bindings_label(b[.Save], " "), "Ctrl+S F6")

	// The same again does nothing
	result, _, _ = bindings_add(&b, .Save, f6)
	testing.expect_value(t, result, Binding_Added.Already_Bound)

	// A chord another command has is taken from it
	from: Command
	result, from, taken = bindings_add(&b, .Save, ctrl_g)
	testing.expect_value(t, result, Binding_Added.Added)
	testing.expect(t, taken && from == .Go_To_Line, "Ctrl+G wasn't taken from Go to line")
	testing.expect_value(t, bindings_count(b[.Go_To_Line]), 0)
	testing.expect_value(t, bindings_label(b[.Save], " "), "Ctrl+S F6 Ctrl+G")

	// Full at MAX_CHORDS
	result, _, _ = bindings_add(&b, .Save, ctrl_b)
	testing.expect_value(t, result, Binding_Added.Added)
	f7, _ := parse_chord("F7")
	result, _, _ = bindings_add(&b, .Save, f7)
	testing.expect_value(t, result, Binding_Added.Full)

	// Removing one moves the rest up; each still runs the command
	bindings_remove(&b, .Save, 1)
	testing.expect_value(t, bindings_label(b[.Save], " "), "Ctrl+S Ctrl+G Ctrl+B")
	testing.expect(t, !chord_bound(b[.Save][3]))
	for chord in b[.Save][:3] {
		cmd, ok := bindings_command(&b, chord)
		testing.expect(t, ok && cmd == .Save, "a binding doesn't run its command")
	}
	_, f6_bound := bindings_command(&b, f6)
	testing.expect(t, !f6_bound, "a removed binding still runs")
}


// Several bindings are saved as a list and read back the same
@(test)
test_bindings_saved :: proc(t: ^testing.T) {
	tmp := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.tprintf("%s/typo-bindings-test-%d.toml", tmp, os.get_pid())
	defer os.remove(path)

	s: Settings
	settings_reset_all(&s)
	s.path = path
	f6, _ := parse_chord("F6")
	mouse4, _ := parse_chord("Mouse4")
	bindings_add(&s.bindings, .Find, f6)
	bindings_add(&s.bindings, .Find, mouse4) // taken from Go back
	settings_save(&s)
	s.path = ""
	settings_destroy(&s)

	again: Settings
	settings_reset_all(&again)
	again.path = path
	settings_load(&again)
	testing.expect_value(t, again.error, "")
	testing.expect_value(t, bindings_label(again.bindings[.Find], " "), "Ctrl+F F6 Mouse4")
	testing.expect_value(t, bindings_label(again.bindings[.Go_Back], " "), "Alt+Left")
	again.path = ""
	settings_destroy(&again)
}


// No command's defaults hold one chord twice, whichever names the layout gives
// its keys (Zoom in lists "Ctrl+=" and "Ctrl++", one key where + is Shift+=)
@(test)
test_default_bindings_distinct :: proc(t: ^testing.T) {
	for cmd in Command {
		chords := default_bindings(cmd)
		for c, i in chords {
			if !chord_bound(c) do continue

			for other in chords[i + 1:] {
				testing.expect(t, other != c, COMMANDS[cmd].key)
			}
		}
	}
}
