package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "toml"
import sdl "vendor:sdl3"

// User settings, stored as TOML in the per-user config directory
// (%APPDATA%\typo\settings.toml on Windows, overridable with the
// TYPO_SETTINGS environment variable). The file is created with
// defaults on first run, rewritten whenever the settings window changes
// something, and reloaded automatically when edited by hand.

Theme_Kind :: enum {
	Dark,
	Light,
}

FONT_SIZE_MIN :: 8
FONT_SIZE_MAX :: 40
DEFAULT_FONT_SIZE :: 15

// Commands that can be bound to keys. Text navigation (arrows, Home/End,
// Backspace, ...) stays fixed for now.
Command :: enum {
	Find_File,
	Toggle_Sidebar,
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
	.Find_File        = {"find_file", "Find file", {"Ctrl+E"}},
	.Toggle_Sidebar   = {"toggle_sidebar", "Toggle sidebar", {"Ctrl+B"}},
	.Open_Settings    = {"open_settings", "Open settings", {"Ctrl+,"}},
	.Save             = {"save", "Save file", {"Ctrl+S"}},
	.Undo             = {"undo", "Undo", {"Ctrl+Z"}},
	.Redo             = {"redo", "Redo", {"Ctrl+Y", "Ctrl+Shift+Z"}},
	.Select_All       = {"select_all", "Select all", {"Ctrl+A"}},
	.Copy             = {"copy", "Copy", {"Ctrl+C"}},
	.Cut              = {"cut", "Cut", {"Ctrl+X"}},
	.Paste            = {"paste", "Paste", {"Ctrl+V"}},
	.Add_Cursor_Above = {"add_cursor_above", "Add cursor above", {"Ctrl+Alt+Up"}},
	.Add_Cursor_Below = {"add_cursor_below", "Add cursor below", {"Ctrl+Alt+Down"}},
}

Chord :: struct {
	key:   sdl.Keycode,
	ctrl:  bool,
	shift: bool,
	alt:   bool,
}

MAX_CHORDS :: 4

Settings :: struct {
	theme:     Theme_Kind,
	font_size: int,
	bindings:  [Command][MAX_CHORDS]Chord, // unused slots have key == 0
	renderer:  string, // SDL render backend ("auto" = SDL's default); applies on restart
	show_fps:  bool,   // draw every frame and show the frame rate
	smooth_scroll: bool,

	path:      string,    // settings.toml
	mtime:     time.Time, // of the file as last read or written by us
	error:     string,    // problem with the file as last loaded, or ""
	poll_t:    u64,
}

// --- Chords ---------------------------------------------------------------------

// Letters arrive as lowercase or uppercase keycodes depending on Shift and
// keyboard layout; compare them case-insensitively.
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
		key   = normalize_key(key.key),
		ctrl  = key.mod & sdl.KMOD_CTRL != {},
		shift = key.mod & sdl.KMOD_SHIFT != {},
		alt   = key.mod & sdl.KMOD_ALT != {},
	}
}

is_modifier_key :: proc(k: sdl.Keycode) -> bool {
	switch k {
	case sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LALT, sdl.K_RALT, sdl.K_LGUI, sdl.K_RGUI:
		return true
	}
	return false
}

// The command bound to a key press, if any.
command_for_key :: proc(key: sdl.KeyboardEvent) -> (cmd: Command, ok: bool) {
	pressed := chord_from_event(key)
	for chords, c in g.settings.bindings {
		for chord in chords {
			if chord.key != 0 && chord == pressed do return c, true
		}
	}
	return {}, false
}

set_default_bindings :: proc(s: ^Settings, cmd: Command) {
	s.bindings[cmd] = {}
	for text, i in COMMANDS[cmd].defaults {
		s.bindings[cmd][i], _ = parse_chord(text)
	}
}

bindings_are_default :: proc(s: ^Settings, cmd: Command) -> bool {
	defaults: Settings
	set_default_bindings(&defaults, cmd)
	return defaults.bindings[cmd] == s.bindings[cmd]
}

RENDERERS := [?]string{"auto", "direct3d11", "direct3d12", "vulkan", "gpu", "opengl"}

@(private = "file")
set_renderer :: proc(s: ^Settings, name: string) {
	if s.renderer == name do return
	delete(s.renderer)
	s.renderer = strings.clone(name)
}

// --- Load / save ------------------------------------------------------------------

settings_defaults :: proc(s: ^Settings) {
	s.theme = .Dark
	s.font_size = DEFAULT_FONT_SIZE
	s.smooth_scroll = true
	set_renderer(s, "auto")
	for cmd in Command do set_default_bindings(s, cmd)
}

// Puts every setting back to its default (the file path and error stay).
settings_reset_all :: proc(s: ^Settings) {
	s.show_fps = false
	settings_defaults(s)
}

// Called once at startup: works out the path, then loads (or creates) the file.
settings_init :: proc(s: ^Settings) {
	settings_defaults(s)
	// TYPO_SETTINGS points at a different file (e.g. for testing).
	if override := os.get_env("TYPO_SETTINGS", context.temp_allocator); override != "" {
		s.path = strings.clone(override)
		if os.exists(s.path) do settings_load(s)
		else do settings_save(s)
		return
	}
	pref := sdl.GetPrefPath("", "typo")
	if pref == nil {
		s.error = strings.clone("no settings directory available; using defaults")
		return
	}
	dir := string(cstring(pref))
	s.path = strings.concatenate({dir, "settings.toml"})
	migrate_old_settings(dir, s.path)
	sdl.free(pref)

	if os.exists(s.path) {
		settings_load(s)
	} else {
		settings_save(s)
	}
}

// The editor used to be called odin_editor; carry its settings over once.
@(private = "file")
migrate_old_settings :: proc(dir, path: string) {
	if os.exists(path) do return
	trimmed := strings.trim_right(dir, "/\\")
	parent := trimmed[:max(strings.last_index_any(trimmed, "/\\"), 0)]
	old := strings.concatenate({parent, "/odin_editor/settings.toml"}, context.temp_allocator)
	if data, err := os.read_entire_file(old, context.temp_allocator); err == nil {
		_ = os.write_entire_file(path, data)
	}
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.path)
	delete(s.error)
	delete(s.renderer)
	s^ = {}
}

// Reads the file. On a syntax error the current settings are kept and the error
// is shown in the settings window; invalid individual values fall back to their
// defaults and are reported the same way.
settings_load :: proc(s: ^Settings) {
	set_error :: proc(s: ^Settings, msg: string) {
		delete(s.error)
		s.error = strings.clone(msg)
	}
	data, read_err := os.read_entire_file(s.path, context.temp_allocator)
	s.mtime, _ = os.last_write_time_by_name(s.path)
	if read_err != nil {
		set_error(s, fmt.tprintf("could not read %s", s.path))
		return
	}
	doc, err := toml.parse(string(data), context.temp_allocator)
	defer toml.destroy(doc, context.temp_allocator)
	if err.line != 0 {
		set_error(s, fmt.tprintf("settings.toml line %d: %s", err.line, err.msg))
		return
	}

	problems := make([dynamic]string, context.temp_allocator)
	next: Settings
	settings_defaults(&next)

	if v, found := toml.get(doc.root, "appearance.theme"); found {
		name, _ := v.(string)
		switch name {
		case "dark":  next.theme = .Dark
		case "light": next.theme = .Light
		case:         append(&problems, `appearance.theme must be "dark" or "light"`)
		}
	}
	if v, found := toml.get(doc.root, "appearance.font_size"); found {
		n, is_int := v.(i64)
		if is_int && n >= FONT_SIZE_MIN && n <= FONT_SIZE_MAX {
			next.font_size = int(n)
		} else {
			append(&problems, fmt.tprintf("appearance.font_size must be a whole number from %d to %d", FONT_SIZE_MIN, FONT_SIZE_MAX))
		}
	}
	if v, found := toml.get(doc.root, "advanced.renderer"); found {
		name, is_str := v.(string)
		known := false
		for r in RENDERERS do if r == name do known = true
		if is_str && known {
			set_renderer(&next, name)
		} else {
			append(&problems, fmt.tprintf("advanced.renderer must be one of: %s", strings.join(RENDERERS[:], ", ", context.temp_allocator)))
		}
	}
	if v, found := toml.get(doc.root, "appearance.smooth_scroll"); found {
		b, is_bool := v.(bool)
		if is_bool {
			next.smooth_scroll = b
		} else {
			append(&problems, "appearance.smooth_scroll must be true or false")
		}
	}
	if v, found := toml.get(doc.root, "advanced.show_fps"); found {
		b, is_bool := v.(bool)
		if is_bool {
			next.show_fps = b
		} else {
			append(&problems, "advanced.show_fps must be true or false")
		}
	}
	for info, cmd in COMMANDS {
		v, found := toml.get(doc.root, strings.concatenate({"keybindings.", info.key}, context.temp_allocator))
		if !found do continue
		texts: [dynamic]string
		texts.allocator = context.temp_allocator
		switch x in v {
		case string:
			append(&texts, x)
		case []toml.Value:
			for item in x {
				if str, is_str := item.(string); is_str do append(&texts, str)
			}
		case i64, f64, bool, ^toml.Table:
		}
		next.bindings[cmd] = {}
		n := 0
		for text in texts {
			chord, chord_ok := parse_chord(text)
			if !chord_ok {
				append(&problems, fmt.tprintf("keybindings.%s: unknown key %q", info.key, text))
				continue
			}
			if n < MAX_CHORDS {
				next.bindings[cmd][n] = chord
				n += 1
			}
		}
	}

	s.theme, s.font_size, s.bindings, s.show_fps = next.theme, next.font_size, next.bindings, next.show_fps
	s.smooth_scroll = next.smooth_scroll
	set_renderer(s, next.renderer)
	delete(next.renderer)
	set_error(s, strings.join(problems[:], "; ", context.temp_allocator))
}

// Writes all settings, with comments, replacing the file atomically.
settings_save :: proc(s: ^Settings) {
	if s.path == "" do return
	sb := strings.builder_make(context.temp_allocator)
	w :: strings.write_string
	w(&sb, "# typo settings. Edit here or in the settings window (")
	w(&sb, first_chord_label(s, .Open_Settings))
	w(&sb, ").\n# Changes made in this file apply as soon as it is saved.\n\n")
	w(&sb, "[appearance]\n")
	w(&sb, "# \"dark\" or \"light\"\n")
	fmt.sbprintf(&sb, "theme = %s\n", toml.quote(s.theme == .Dark ? "dark" : "light"))
	fmt.sbprintf(&sb, "# Editor font size, %d to %d\n", FONT_SIZE_MIN, FONT_SIZE_MAX)
	fmt.sbprintf(&sb, "font_size = %d\n", s.font_size)
	w(&sb, "# Ease the view when scrolling, instead of moving in notches\n")
	fmt.sbprintf(&sb, "smooth_scroll = %v\n\n", s.smooth_scroll)
	w(&sb, "[keybindings]\n")
	w(&sb, "# Modifiers: Ctrl, Shift, Alt. Use a list for several keys, e.g. [\"Ctrl+Y\", \"Ctrl+Shift+Z\"].\n")
	w(&sb, "# An empty list [] leaves a command unbound.\n")
	for info, cmd in COMMANDS {
		chords := make([dynamic]string, context.temp_allocator)
		for c in s.bindings[cmd] do if c.key != 0 do append(&chords, toml.quote(format_chord(c)))
		if len(chords) == 1 {
			fmt.sbprintf(&sb, "%s = %s\n", info.key, chords[0])
		} else {
			fmt.sbprintf(&sb, "%s = [%s]\n", info.key, strings.join(chords[:], ", ", context.temp_allocator))
		}
	}
	w(&sb, "\n[advanced]\n")
	fmt.sbprintf(&sb, "# Graphics backend, applied on restart: %s\n", strings.join(RENDERERS[:], ", ", context.temp_allocator))
	w(&sb, "# \"auto\" lets SDL choose (Direct3D 11 on Windows).\n")
	fmt.sbprintf(&sb, "renderer = %s\n", toml.quote(s.renderer))
	w(&sb, "# Redraw every frame and show the frame rate in the status bar.\n")
	fmt.sbprintf(&sb, "show_fps = %v\n", s.show_fps)

	dir := s.path[:max(strings.last_index_any(s.path, "/\\"), 0)]
	_ = os.make_directory_all(dir)
	tmp := strings.concatenate({s.path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.to_string(sb)) != nil || os.rename(tmp, s.path) != nil {
		sdl.Log("could not write %s", strings.clone_to_cstring(s.path, context.temp_allocator))
		return
	}
	s.mtime, _ = os.last_write_time_by_name(s.path)
}

// Reloads the file if it changed on disk (checked twice a second).
settings_poll :: proc(s: ^Settings) {
	now := sdl.GetTicksNS()
	if s.path == "" || now - s.poll_t < 500_000_000 do return
	s.poll_t = now
	mtime, err := os.last_write_time_by_name(s.path)
	if err == nil && mtime != s.mtime {
		settings_load(s)
		apply_settings()
	}
}

// Pushes the current settings into the running editor.
apply_settings :: proc() {
	theme = g.settings.theme == .Dark ? DARK_THEME : LIGHT_THEME
}

// "Ctrl+E" (first binding) for showing in the UI, or "" if unbound.
first_chord_label :: proc(s: ^Settings, cmd: Command) -> string {
	for c in s.bindings[cmd] do if c.key != 0 do return format_chord(c)
	return ""
}
