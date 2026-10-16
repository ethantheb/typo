package editor

import "core:strings"

import sdl "../vendor/sdl3"

// Commands that can be bound to keys, and the chords that trigger them. Text
// navigation (arrows, Home/End, Backspace, ...) is fixed (editor_handle_key).

Command :: enum {
	Find_File,
	Toggle_Sidebar,
	Toggle_Terminal,
	Maximize_Terminal,
	Open_Settings,
	Save,
	Undo,
	Redo,
	Select_All,
	Copy,
	Cut,
	Paste,
	Add_Cursor_Above,
	Add_Cursor_Below,
}

Command_Info :: struct {
	key:      string, // name in settings.toml
	name:     string, // shown in the settings window
	defaults: []string,
}

COMMANDS := [Command]Command_Info {
	.Find_File         = {"find_file", "Find file", {"Ctrl+E"}},
	.Toggle_Sidebar    = {"toggle_sidebar", "Toggle sidebar", {"Ctrl+B"}},
	.Toggle_Terminal   = {"toggle_terminal", "Toggle terminal", {"Ctrl+`"}},
	.Maximize_Terminal = {"maximize_terminal", "Maximize terminal", {"Ctrl+Shift+`"}},
	.Open_Settings     = {"open_settings", "Open settings", {"Ctrl+,"}},
	.Save              = {"save", "Save file", {"Ctrl+S"}},
	.Undo              = {"undo", "Undo", {"Ctrl+Z"}},
	.Redo              = {"redo", "Redo", {"Ctrl+Y", "Ctrl+Shift+Z"}},
	.Select_All        = {"select_all", "Select all", {"Ctrl+A"}},
	.Copy              = {"copy", "Copy", {"Ctrl+C"}},
	.Cut               = {"cut", "Cut", {"Ctrl+X"}},
	.Paste             = {"paste", "Paste", {"Ctrl+V"}},
	.Add_Cursor_Above  = {"add_cursor_above", "Add cursor above", {"Ctrl+Alt+Up"}},
	.Add_Cursor_Below  = {"add_cursor_below", "Add cursor below", {"Ctrl+Alt+Down"}},
}

// App commands that still work while the terminal has focus; every other chord
// goes to the shell.
TERMINAL_COMMANDS :: bit_set[Command]{.Toggle_Terminal, .Maximize_Terminal, .Open_Settings}

Chord :: struct {
	key:   sdl.Keycode,
	ctrl:  bool,
	shift: bool,
	alt:   bool,
}

MAX_CHORDS :: 4

// Unused slots have key == 0.
Bindings :: [Command][MAX_CHORDS]Chord

// Runs a command. Returns false if it doesn't apply (e.g. Save with no file open).
run_command :: proc(cmd: Command) -> bool {
	#partial switch cmd {
	case .Find_File:         finder_toggle()
	case .Toggle_Sidebar:    g.sidebar_visible = !g.sidebar_visible
	case .Toggle_Terminal:   terminal_toggle()
	case .Maximize_Terminal: terminal_toggle_maximized()
	case .Open_Settings:     settings_window_toggle()
	case:                    return editor_run_command(&g.editor, cmd)
	}
	return true
}

// The command bound to a key press, if any.
command_for_key :: proc(key: sdl.KeyboardEvent) -> (cmd: Command, ok: bool) {
	pressed := chord_from_event(key)
	for chords, c in g.settings.bindings {
		for chord in chords do if chord.key != 0 && chord == pressed do return c, true
	}
	return {}, false
}

// Key names may be upper or lower case ("Ctrl+E", "ctrl+e").
@(private = "file")
normalize_key :: proc(k: sdl.Keycode) -> sdl.Keycode {
	if k >= 'A' && k <= 'Z' do return k + ('a' - 'A')
	return k
}

parse_chord :: proc(s: string) -> (c: Chord, ok: bool) {
	parts := strings.split(s, "+", context.temp_allocator)
	// "Ctrl++" means Ctrl and the '+' key.
	if strings.has_suffix(s, "++") {
		parts = parts[:len(parts) - 1]
		parts[len(parts) - 1] = "+"
	}
	if len(parts) == 0 do return {}, false
	for part in parts[:len(parts) - 1] {
		switch strings.to_lower(strings.trim_space(part), context.temp_allocator) {
		case "ctrl", "control", "cmd": c.ctrl = true
		case "shift":                 c.shift = true
		case "alt", "option":         c.alt = true
		case:                         return {}, false
		}
	}
	name := strings.trim_space(parts[len(parts) - 1])
	if name == "" do return {}, false
	c.key = normalize_key(sdl.GetKeyFromName(strings.clone_to_cstring(name, context.temp_allocator)))
	return c, c.key != sdl.K_UNKNOWN
}

format_chord :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if c.ctrl do strings.write_string(&sb, "Ctrl+")
	if c.shift do strings.write_string(&sb, "Shift+")
	if c.alt do strings.write_string(&sb, "Alt+")
	strings.write_string(&sb, string(sdl.GetKeyName(c.key)))
	return strings.to_string(sb)
}

chord_from_event :: proc(key: sdl.KeyboardEvent) -> Chord {
	return {
		key   = base_key(key),
		ctrl  = key.mod & sdl.KMOD_CTRL != {},
		shift = key.mod & sdl.KMOD_SHIFT != {},
		alt   = key.mod & sdl.KMOD_ALT != {},
	}
}

// The key without modifiers. SDL applies Shift to `key.key` ('A' for a, '~'
// for `), while chords name the key and Shift separately.
base_key :: proc(key: sdl.KeyboardEvent) -> sdl.Keycode {
	return sdl.GetKeyFromScancode(key.scancode, {}, true)
}

is_modifier_key :: proc(k: sdl.Keycode) -> bool {
	switch k {
	case sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI:
		return true
	}
	return false
}

default_bindings :: proc(cmd: Command) -> (chords: [MAX_CHORDS]Chord) {
	for text, i in COMMANDS[cmd].defaults do chords[i], _ = parse_chord(text)
	return
}

// The bound chords, formatted and joined with `sep`.
bindings_label :: proc(chords: [MAX_CHORDS]Chord, sep: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for c in chords do if c.key != 0 do append(&parts, format_chord(c))
	return strings.join(parts[:], sep, context.temp_allocator)
}

// "Ctrl+E" (the first binding) for showing in the UI, or "" if unbound.
first_chord_label :: proc(cmd: Command) -> string {
	for c in g.settings.bindings[cmd] do if c.key != 0 do return format_chord(c)
	return ""
}
