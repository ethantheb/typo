package editor

import "core:strings"

import sdl "../vendor/sdl3"

// Commands that can be bound to keys, and the chords that trigger them. Text
// navigation (arrows, Home/End, Backspace, ...) is fixed (editor_handle_key)


Command :: enum {
	Find_File,
	Find,
	Find_Next,
	Find_Previous,
	Find_Match_Case,
	Find_Whole_Word,
	Find_Regex,
	Toggle_Sidebar,
	Toggle_Terminal,
	New_Terminal,
	Maximize_Pane,
	Close_Pane,
	Rename,
	Rename_Symbol,
	Focus_Next_Pane,
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
	Move_Line_Up,
	Move_Line_Down,
	Toggle_Markdown_View,
	Go_To_Definition,
	Find_References,
	Go_To_File_Symbol,
	Go_To_Symbol,
	Trigger_Completion,
	Show_Signature_Help,
	Go_Back,
	Go_Forward,
	Show_Hover,
	Next_Problem,
	Previous_Problem,
}

Command_Info :: struct {
	key:      string, // name in settings.toml
	name:     string, // shown in the settings window
	defaults: []string,
}

COMMANDS := [Command]Command_Info {
	.Find_File            = {"find_file", "Find file", {"Ctrl+E"}},
	.Find                 = {"find", "Find", {"Ctrl+F"}},
	.Find_Next            = {"find_next", "Find next", {"F3"}},
	.Find_Previous        = {"find_previous", "Find previous", {"Shift+F3"}},
	.Find_Match_Case      = {"find_match_case", "Find: match case", {"Alt+C"}},
	.Find_Whole_Word      = {"find_whole_word", "Find: whole word", {"Alt+W"}},
	.Find_Regex           = {"find_regex", "Find: regular expression", {"Alt+R"}},
	.Toggle_Sidebar       = {"toggle_sidebar", "Toggle sidebar", {"Ctrl+B"}},
	.Toggle_Terminal      = {"toggle_terminal", "Toggle terminal", {"Ctrl+`"}},
	.New_Terminal         = {"new_terminal", "New terminal", {"Ctrl+Shift+`"}},
	.Maximize_Pane        = {"maximize_pane", "Maximize pane", {"Ctrl+Shift+Return"}},
	.Close_Pane           = {"close_pane", "Close pane", {"Ctrl+W"}},
	.Rename               = {"rename", "Rename symbol or pane", {"F2"}},
	.Rename_Symbol        = {"rename_symbol", "Rename symbol", {}},
	.Focus_Next_Pane      = {"focus_next_pane", "Focus next pane", {"Ctrl+Tab"}},
	.Open_Settings        = {"open_settings", "Open settings", {"Ctrl+,"}},
	.Save                 = {"save", "Save file", {"Ctrl+S"}},
	.Undo                 = {"undo", "Undo", {"Ctrl+Z"}},
	.Redo                 = {"redo", "Redo", {"Ctrl+Y", "Ctrl+Shift+Z"}},
	.Select_All           = {"select_all", "Select all", {"Ctrl+A"}},
	.Copy                 = {"copy", "Copy", {"Ctrl+C"}},
	.Cut                  = {"cut", "Cut", {"Ctrl+X"}},
	.Paste                = {"paste", "Paste", {"Ctrl+V"}},
	.Add_Cursor_Above     = {"add_cursor_above", "Add cursor above", {"Ctrl+Alt+Up"}},
	.Add_Cursor_Below     = {"add_cursor_below", "Add cursor below", {"Ctrl+Alt+Down"}},
	.Move_Line_Up         = {"move_line_up", "Move line up", {"Alt+Up"}},
	.Move_Line_Down       = {"move_line_down", "Move line down", {"Alt+Down"}},
	.Toggle_Markdown_View = {"toggle_markdown_view", "Toggle Markdown view", {"Ctrl+Shift+V"}},
	.Go_To_Definition     = {"go_to_definition", "Go to definition", {"F12"}},
	.Find_References      = {"find_references", "Find references", {"Shift+F12"}},
	.Go_To_File_Symbol    = {"go_to_file_symbol", "Go to symbol in file", {"Ctrl+Shift+O"}},
	.Go_To_Symbol         = {"go_to_symbol", "Go to symbol in project", {"Ctrl+T"}},
	.Trigger_Completion   = {"trigger_completion", "Trigger completion", {"Ctrl+Space"}},
	.Show_Signature_Help  = {"show_signature_help", "Show signature help", {"Ctrl+Shift+Space"}},
	.Go_Back              = {"go_back", "Go back", {"Alt+Left"}},
	.Go_Forward           = {"go_forward", "Go forward", {"Alt+Right"}},
	.Show_Hover           = {"show_hover", "Show hover", {"Ctrl+K"}},
	.Next_Problem         = {"next_problem", "Next problem", {"F8"}},
	.Previous_Problem     = {"previous_problem", "Previous problem", {"Shift+F8"}},
}

// App commands that still work while the terminal has focus; every other chord
// goes to the shell
TERMINAL_COMMANDS :: bit_set[Command]{
	.Find,
	.Find_Next,
	.Find_Previous,
	.Toggle_Terminal,
	.New_Terminal,
	.Maximize_Pane,
	.Focus_Next_Pane,
	.Open_Settings,
}

Chord :: struct {
	key:   sdl.Keycode,
	ctrl:  bool,
	shift: bool,
	alt:   bool,
}

MAX_CHORDS :: 4

// Unused slots have key == 0
Bindings :: [Command][MAX_CHORDS]Chord


// Runs a command. Returns false if it doesn't apply (e.g. Save with no file open)
run_command :: proc(cmd: Command) -> bool {
	#partial switch cmd {
	case .Find_File:       finder_toggle()
	case .Go_To_Symbol:    lsp_find_workspace_symbols()
	case .Toggle_Sidebar:  g.sidebar_visible = !g.sidebar_visible
	case .Toggle_Terminal: terminal_toggle()
	case .New_Terminal:    panes_new_terminal()
	case .Focus_Next_Pane: pane_focus_next()
	case .Open_Settings:   settings_window_toggle()

	case .Maximize_Pane:
		if g.panes.focused == nil do return false
		pane_toggle_maximized()

	case .Close_Pane:
		if g.panes.focused == nil do return false
		pane_close(g.panes.focused)

	case .Rename:
		// The symbol at the caret, when the editor's server renames
		e := focused_editor()
		if e != nil && e.status == .Text && lsp_rename_start(e) {
			return true
		}
		return rename_focused_pane()

	case .Go_Back:
		return jump_back()

	case .Go_Forward:
		return jump_forward()

	case .Find, .Find_Next, .Find_Previous, .Find_Match_Case, .Find_Whole_Word, .Find_Regex:
		return find_run_command(cmd)

	case:
		e := focused_editor()
		return e != nil && editor_run_command(e, cmd)
	}
	return true
}


// The command bound to a key press, if any
command_for_key :: proc(key: sdl.KeyboardEvent) -> (cmd: Command, ok: bool) {
	pressed := chord_from_event(key)

	for chords, c in g.settings.bindings {
		for chord in chords {
			if chord.key != 0 && chord == pressed {
				return c, true
			}
		}
	}
	return {}, false
}


// Key names may be upper or lower case ("Ctrl+E", "ctrl+e")
@(private = "file")
normalize_key :: proc(k: sdl.Keycode) -> sdl.Keycode {
	if k >= 'A' && k <= 'Z' {
		return k + ('a' - 'A')
	}
	return k
}


parse_chord :: proc(s: string) -> (c: Chord, ok: bool) {
	parts := strings.split(s, "+", context.temp_allocator)

	// "Ctrl++" means Ctrl and the '+' key
	if strings.has_suffix(s, "++") {
		parts = parts[:len(parts) - 1]
		parts[len(parts) - 1] = "+"
	}
	if len(parts) == 0 do return {}, false

	// The modifiers
	for part in parts[:len(parts) - 1] {
		switch strings.to_lower(strings.trim_space(part), context.temp_allocator) {
		case "ctrl", "control", "cmd": c.ctrl = true
		case "shift":                 c.shift = true
		case "alt", "option":         c.alt = true
		case:                         return {}, false
		}
	}

	// The key
	name := strings.trim_space(parts[len(parts) - 1])
	if name == "" do return {}, false

	cname := strings.clone_to_cstring(name, context.temp_allocator)
	c.key = normalize_key(sdl.GetKeyFromName(cname))
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
// for `), while chords name the key and Shift separately
base_key :: proc(key: sdl.KeyboardEvent) -> sdl.Keycode {
	return sdl.GetKeyFromScancode(key.scancode, {}, true)
}


is_modifier_key :: proc(k: sdl.Keycode) -> bool {
	switch k {
	case sdl.K_LCTRL, sdl.K_RCTRL,
	     sdl.K_LSHIFT, sdl.K_RSHIFT,
	     sdl.K_LALT, sdl.K_RALT,
	     sdl.K_LGUI, sdl.K_RGUI:
		return true
	}
	return false
}


default_bindings :: proc(cmd: Command) -> (chords: [MAX_CHORDS]Chord) {
	for text, i in COMMANDS[cmd].defaults do chords[i], _ = parse_chord(text)
	return
}


// The bound chords, formatted and joined with `sep`
bindings_label :: proc(chords: [MAX_CHORDS]Chord, sep: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for c in chords {
		if c.key != 0 do append(&parts, format_chord(c))
	}
	return strings.join(parts[:], sep, context.temp_allocator)
}


// "Ctrl+E" (the first binding) for showing in the UI, or "" if unbound
first_chord_label :: proc(cmd: Command) -> string {
	for c in g.settings.bindings[cmd] {
		if c.key != 0 do return format_chord(c)
	}
	return ""
}
