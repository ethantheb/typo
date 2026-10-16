package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "toml"
import sdl "../vendor/sdl3"

// User settings, stored as TOML in the per-user config directory
// (%APPDATA%\typo\settings.toml on Windows, or TYPO_SETTINGS if set). The file
// is created with defaults on first run, rewritten whenever the settings window
// changes something, and reloaded when edited by hand.
//
// Each setting is described once in SETTINGS; loading, saving, resetting and
// the settings window all work from that table.

Settings :: struct {
	theme:          string,
	font_size:      int,
	smooth_scroll:  bool,
	terminal_shell: string, // "" = platform default
	bundled_conpty: bool,   // Windows only
	renderer:       string, // SDL render backend; applies on restart
	show_fps:       bool,
	bindings:       Bindings,

	path:           string,    // settings.toml
	mtime:          time.Time, // of the file as last read or written by us
	error:          string,    // problem with the file as last loaded, or ""
	// The watcher runs on SDL's timer thread; these are guarded by watch_mutex.
	watcher:        sdl.TimerID,
	watch_mutex:    sync.Mutex,
	disk_mtime:     time.Time, // as last seen by the watcher
	disk_changed:   bool,
}

Setting :: enum {
	Theme,
	Font_Size,
	Smooth_Scroll,
	Terminal_Shell,
	Bundled_Conpty,
	Renderer,
	Show_Fps,
}

// Sections of settings.toml and the settings window, in order.
Section :: enum {
	Appearance,
	Keybindings,
	Terminal,
	Advanced,
}

SECTION_KEYS := [Section]string {
	.Appearance  = "appearance",
	.Keybindings = "keybindings",
	.Terminal    = "terminal",
	.Advanced    = "advanced",
}

Setting_Info :: struct {
	section:     Section,
	key:         string,   // within the section in settings.toml
	name:        string,   // in the settings window; "" = only in settings.toml
	description: string,
	keywords:    string,   // extra search terms
	default:     union {bool, int, string},
	choices:     []string, // allowed values of a string setting; nil = any text
	min, max:    int,      // range of an int setting
}

RENDERERS := [?]string{"auto", "direct3d11", "direct3d12", "vulkan", "gpu", "opengl"}

SETTINGS := [Setting]Setting_Info {
	.Theme = {
		section = .Appearance, key = "theme", name = "Theme",
		description = "Color scheme for the whole window.", keywords = "dark light mode colors",
		default = "dark", choices = THEME_NAMES[:],
	},
	.Font_Size = {
		section = .Appearance, key = "font_size", name = "Font size",
		description = "Editor and terminal text size.", keywords = "text zoom",
		default = 15, min = 8, max = 40,
	},
	.Smooth_Scroll = {
		section = .Appearance, key = "smooth_scroll", name = "Smooth scrolling",
		description = "Ease the view when scrolling, instead of moving in notches.", keywords = "scroll animation wheel",
		default = true,
	},
	.Terminal_Shell = {
		section = .Terminal, key = "shell", name = "Shell",
		description = "Command line to run, e.g. \"pwsh -NoLogo\". Empty uses the default. Applies on restart.",
		keywords = "pwsh powershell cmd bash command line",
		default = "",
	},
	.Bundled_Conpty = {
		section = .Terminal, key = "bundled_conpty", name = ODIN_OS == .Windows ? "Bundled console host" : "",
		description = "Use the faster console host from Windows Terminal, saved once to %LOCALAPPDATA%\\typo. Off uses the built-in one and deletes the saved copy. Applies on restart.",
		keywords = "conpty openconsole windows terminal",
		default = true,
	},
	.Renderer = {
		section = .Advanced, key = "renderer",
		description = "Graphics backend; \"auto\" lets SDL choose. Applies on restart.",
		default = "auto", choices = RENDERERS[:],
	},
	.Show_Fps = {
		section = .Advanced, key = "show_fps", name = "Show FPS",
		description = "Redraw every frame and show the frame rate in the status bar.", keywords = "frame rate performance",
		default = false,
	},
}

SETTINGS_POLL_MS :: 500

Setting_Value :: union {
	^bool,
	^int,
	^string,
}

setting_value :: proc(s: ^Settings, x: Setting) -> Setting_Value {
	switch x {
	case .Theme:          return &s.theme
	case .Font_Size:      return &s.font_size
	case .Smooth_Scroll:  return &s.smooth_scroll
	case .Terminal_Shell: return &s.terminal_shell
	case .Bundled_Conpty: return &s.bundled_conpty
	case .Renderer:       return &s.renderer
	case .Show_Fps:       return &s.show_fps
	}
	return nil
}

// "appearance.theme"
setting_path :: proc(x: Setting) -> string {
	return strings.concatenate({SECTION_KEYS[SETTINGS[x].section], ".", SETTINGS[x].key}, context.temp_allocator)
}

set_string :: proc(dst: ^string, value: string) {
	if dst^ == value do return
	delete(dst^)
	dst^ = strings.clone(value)
}

setting_reset :: proc(s: ^Settings, x: Setting) {
	switch v in setting_value(s, x) {
	case ^bool:   v^ = SETTINGS[x].default.(bool)
	case ^int:    v^ = SETTINGS[x].default.(int)
	case ^string: set_string(v, SETTINGS[x].default.(string))
	}
}

settings_reset_all :: proc(s: ^Settings) {
	for x in Setting do setting_reset(s, x)
	for cmd in Command do s.bindings[cmd] = default_bindings(cmd)
}

// Steps a choice, bool or number setting by `dir` (-1 or +1), clamped.
setting_step :: proc(s: ^Settings, x: Setting, dir: int) {
	info := SETTINGS[x]
	switch v in setting_value(s, x) {
	case ^bool:
		v^ = dir > 0
	case ^int:
		v^ = clamp(v^ + dir, info.min, info.max)
	case ^string:
		if len(info.choices) == 0 do return
		i := 0
		for c, j in info.choices do if c == v^ do i = j
		set_string(v, info.choices[clamp(i + dir, 0, len(info.choices) - 1)])
	}
}

// --- Load / save ------------------------------------------------------------------

// Called once at startup: works out the path, then loads (or creates) the file.
settings_init :: proc(s: ^Settings) {
	settings_reset_all(s)
	if override := os.get_env("TYPO_SETTINGS", context.temp_allocator); override != "" {
		s.path = strings.clone(override)
	} else if pref := sdl.GetPrefPath("", "typo"); pref != nil {
		s.path = strings.concatenate({string(cstring(pref)), "settings.toml"})
		sdl.free(pref)
	} else {
		s.error = strings.clone("no settings directory available; using defaults")
		return
	}
	if os.exists(s.path) {
		settings_load(s)
	} else {
		settings_save(s)
	}
	sync.guard(&s.watch_mutex)
	s.disk_mtime = s.mtime
	s.watcher = sdl.AddTimer(SETTINGS_POLL_MS, watch_callback, s)
}

settings_destroy :: proc(s: ^Settings) {
	if s.watcher != 0 {
		sync.guard(&s.watch_mutex)
		_ = sdl.RemoveTimer(s.watcher)
		s.watcher = 0
	}
	for x in Setting do if v, ok := setting_value(s, x).(^string); ok do delete(v^)
	delete(s.path)
	delete(s.error)
	s^ = {}
}

// Reads the file. On a syntax error the current settings are kept; invalid
// values fall back to their defaults. Either way the problem is shown in the
// settings window.
settings_load :: proc(s: ^Settings) {
	data, read_err := os.read_entire_file(s.path, context.temp_allocator)
	s.mtime, _ = os.last_write_time_by_name(s.path)
	if read_err != nil {
		set_string(&s.error, fmt.tprintf("could not read %s", s.path))
		return
	}
	doc, err := toml.parse(string(data), context.temp_allocator)
	defer toml.destroy(doc, context.temp_allocator)
	if err.line != 0 {
		set_string(&s.error, fmt.tprintf("settings.toml line %d: %s", err.line, err.msg))
		return
	}

	problems := make([dynamic]string, context.temp_allocator)
	settings_reset_all(s)
	for x in Setting {
		v, found := toml.get(doc.root, setting_path(x))
		if found && !set_from_toml(s, x, v) do append(&problems, setting_problem(s, x))
	}
	for info, cmd in COMMANDS {
		v, found := toml.get(doc.root, strings.concatenate({"keybindings.", info.key}, context.temp_allocator))
		if !found do continue
		texts := make([dynamic]string, context.temp_allocator)
		#partial switch x in v {
		case string:
			append(&texts, x)
		case []toml.Value:
			for item in x do if str, is_str := item.(string); is_str do append(&texts, str)
		}
		s.bindings[cmd] = {}
		n := 0
		for text in texts {
			chord, ok := parse_chord(text)
			if !ok {
				append(&problems, fmt.tprintf("keybindings.%s: unknown key %q", info.key, text))
			} else if n < MAX_CHORDS {
				s.bindings[cmd][n] = chord
				n += 1
			}
		}
	}
	set_string(&s.error, strings.join(problems[:], "; ", context.temp_allocator))
}

@(private = "file")
set_from_toml :: proc(s: ^Settings, x: Setting, v: toml.Value) -> bool {
	info := SETTINGS[x]
	switch dst in setting_value(s, x) {
	case ^bool:
		b := v.(bool) or_return
		dst^ = b
	case ^int:
		n := v.(i64) or_return
		if n < i64(info.min) || n > i64(info.max) do return false
		dst^ = int(n)
	case ^string:
		str := strings.trim_space(v.(string) or_return)
		if info.choices != nil && !contains(info.choices, str) do return false
		set_string(dst, str)
	}
	return true
}

@(private = "file")
setting_problem :: proc(s: ^Settings, x: Setting) -> string {
	info := SETTINGS[x]
	path := setting_path(x)
	switch _ in setting_value(s, x) {
	case ^bool:
		return fmt.tprintf("%s must be true or false", path)
	case ^int:
		return fmt.tprintf("%s must be a whole number from %d to %d", path, info.min, info.max)
	case ^string:
		if info.choices != nil do return fmt.tprintf("%s must be one of: %s", path, strings.join(info.choices, ", ", context.temp_allocator))
	}
	return fmt.tprintf("%s must be a string", path)
}

@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

// Writes all settings, replacing the file atomically.
settings_save :: proc(s: ^Settings) {
	if s.path == "" do return
	sb := strings.builder_make(context.temp_allocator)
	for key, section in SECTION_KEYS {
		// Each section's values line up in one column.
		Line :: struct {
			key, value: string,
		}
		lines := make([dynamic]Line, context.temp_allocator)
		if section == .Keybindings {
			for info, cmd in COMMANDS {
				chords := make([dynamic]string, context.temp_allocator)
				for c in s.bindings[cmd] do if c.key != 0 do append(&chords, toml.quote(format_chord(c)))
				value := len(chords) == 1 ? chords[0] : fmt.tprintf("[%s]", strings.join(chords[:], ", ", context.temp_allocator))
				append(&lines, Line{info.key, value})
			}
		} else {
			for info, x in SETTINGS {
				if info.section != section do continue
				value: string
				switch v in setting_value(s, x) {
				case ^bool:   value = fmt.tprintf("%v", v^)
				case ^int:    value = fmt.tprintf("%d", v^)
				case ^string: value = toml.quote(v^)
				}
				append(&lines, Line{info.key, value})
			}
		}
		width := 0
		for line in lines do width = max(width, len(line.key))
		if section != min(Section) do strings.write_byte(&sb, '\n')
		fmt.sbprintf(&sb, "[%s]\n", key)
		for line in lines do fmt.sbprintf(&sb, "%-*s = %s\n", width, line.key, line.value)
	}

	_ = os.make_directory_all(os.dir(s.path))
	tmp := strings.concatenate({s.path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, strings.to_string(sb)) != nil || os.rename(tmp, s.path) != nil {
		sdl.Log("could not write %s", strings.clone_to_cstring(s.path, context.temp_allocator))
		return
	}
	s.mtime, _ = os.last_write_time_by_name(s.path)
}

// Checks settings.toml on SDL's timer thread and wakes the main loop only when
// it changed, so an idle editor isn't woken just to look.
@(private = "file")
watch_callback :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	s := (^Settings)(userdata)
	sync.guard(&s.watch_mutex)
	if s.watcher == 0 do return 0 // being destroyed
	if mtime, err := os.last_write_time_by_name(s.path); err == nil && mtime != s.disk_mtime {
		s.disk_mtime = mtime
		s.disk_changed = true
		wake_main_loop(nil)
	}
	return interval
}

// Reloads the file if the watcher saw it change, unless that was our own save.
settings_poll :: proc(s: ^Settings) {
	changed: bool
	if sync.guard(&s.watch_mutex) do changed, s.disk_changed = s.disk_changed, false
	if !changed do return
	mtime, err := os.last_write_time_by_name(s.path)
	if err == nil && mtime != s.mtime {
		settings_load(s)
		apply_settings()
	}
}

// Saves the settings and pushes them into the running editor.
settings_changed :: proc() {
	settings_save(&g.settings)
	apply_settings()
}

apply_settings :: proc() {
	theme = theme_by_name(g.settings.theme)
	terminal_apply_theme(&g.terminal_panel.terminal)
}
