package editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import "toml"
import sdl "../vendor/sdl3"
import "gfx"
import "langs"

// Settings, in two layers of TOML: the user's settings.toml in the per-user
// config directory (%APPDATA%\typo\settings.toml on Windows, or TYPO_SETTINGS
// if set), and over it the open project's .typo/settings.toml, where a value
// set wins for that project (project.odin). The values in effect, read through
// g.settings, are worked out from the two (settings_resolve). Keybindings and
// language servers' tables are the user's only, as are settings marked
// user_only. settings.toml is created with defaults on first run, rewritten
// whenever the settings window changes it, and read again when edited by hand;
// after startup both files are read and written on the config thread
// (config_io.odin).
//
// Each setting is described once in SETTINGS; loading, saving, resetting and
// the settings window all work from that table


Settings :: struct {
	using values:      Setting_Values, // in effect: the project's over the user's
	user:              Setting_Values, // settings.toml's
	project:           Setting_Layer,  // the open project's .typo/settings.toml
	bindings:          Bindings,
	terminal_commands: bit_set[Command], // work while a terminal has focus
	servers:           [dynamic]langs.Server_Override, // [lsp.<name>] tables

	path:              string, // settings.toml
	error:             string, // problem with settings.toml as last read, or ""
	project_error:     string, // likewise for the project's
}

// A value for each setting in SETTINGS (strings owned)
Setting_Values :: struct {
	restore_session:      bool,
	ask_above_mb:         int, // a larger file is asked about before it is read; 0 = never
	collapsed_sections:   string, // settings window sections shown collapsed: keys, ", "-separated
	theme:                string,
	ui_font:              string,
	font_family:          string,
	font_size:            int,
	font_weight:          int,
	line_height:          f64, // times the font size
	letter_spacing:       f64, // logical pixels
	smooth_scroll:        bool,
	text_contrast:        f64,
	text_antialiasing:    string, // "auto", "subpixel" or "grayscale"
	terminal_shell:       string, // "" = platform default
	bundled_conpty:       bool,   // Windows only
	terminal_backend:     string, // new terminals: "local" or "herdr" (herdr-core)
	renderer:             string, // SDL render backend; applies on restart
	show_fps:             bool,
	markdown_view:        string, // "rendered" or "text"
	markdown_font:        string,
	markdown_font_size:   int,
	markdown_line_height: f64, // times the font size
	markdown_max_width:   int, // logical pixels; 0 = the pane's width
	words:                string, // word completions: "fallback", "enabled" or "disabled"
	words_min_length:     int,    // a word typed this long gets word completions
	words_in_text_files:  bool,   // also in Markdown and plain text files
	lsp_fetch_timeout:    int,    // ms the server has before words show; 0 = no limit
	lsp_enabled:          bool,
	lsp_hover_delay:      int, // ms; 0 = no hover on the pointer
	recent_files:         int, // unpinned files under RECENT in the sidebar
}

// The values a project's settings file sets
Setting_Layer :: struct {
	values: Setting_Values, // those in `set`
	set:    bit_set[Setting],
}

// Which layer the settings window shows and changes
Settings_Scope :: enum {
	User,
	Project,
}

Setting :: enum {
	Restore_Session,
	Recent_Files,
	Ask_Above_Mb,
	Collapsed_Sections,
	Theme,
	Ui_Font,
	Smooth_Scroll,
	Text_Contrast,
	Text_Antialiasing,
	Font_Family,
	Font_Size,
	Font_Weight,
	Line_Height,
	Letter_Spacing,
	Terminal_Shell,
	Terminal_Backend,
	Bundled_Conpty,
	Renderer,
	Show_Fps,
	Markdown_View,
	Markdown_Font,
	Markdown_Font_Size,
	Markdown_Line_Height,
	Markdown_Max_Width,
	Words,
	Words_Min_Length,
	Words_In_Text_Files,
	Lsp_Fetch_Timeout,
	Lsp_Enabled,
	Lsp_Hover_Delay,
}

// Sections of settings.toml and the settings window, in order
Section :: enum u8 {
	General,
	Appearance,
	Font,
	Markdown,
	Completions,
	Keybindings,
	Terminal,
	Language_Servers,
	Advanced,
}

SECTION_KEYS := [Section]string {
	.General          = "general",
	.Appearance       = "appearance",
	.Font             = "font",
	.Markdown         = "markdown",
	.Completions      = "completions",
	.Keybindings      = "keybindings",
	.Terminal         = "terminal",
	.Language_Servers = "lsp",
	.Advanced         = "advanced",
}

// The small fields go last, together, which keeps SETTINGS under the size LLVM
// warns about
Setting_Info :: struct {
	key:         string, // within the section in settings.toml
	name:        string, // in the settings window; "" = only in settings.toml
	description: string,
	keywords:    string, // extra search terms
	default:     union {bool, int, f64, string},
	choices:     []string, // allowed values of a string setting; nil = any text
	min, max:    f64,      // range of a number setting
	step:        f64,      // of a number setting in the settings window; 0 = 1
	section:     Section,
	picker:      bool, // a string setting chosen from a list (see settings_ui.odin)
	user_only:   bool, // not set per project: it applies before or across projects
}

RENDERERS         := [?]string{"auto", "direct3d11", "direct3d12", "vulkan", "gpu", "opengl"}
MARKDOWN_VIEWS    := [?]string{"rendered", "text"}
WORDS_MODES       := [?]string{"fallback", "enabled", "disabled"}
ANTIALIASING      := [?]string{"auto", "subpixel", "grayscale"}
TERMINAL_BACKENDS := [?]string{"local", "herdr"}

SETTINGS := [Setting]Setting_Info {
	.Theme = {
		section     = .Appearance,
		key         = "theme",
		name        = "Theme",
		description = "Color scheme for the whole window.",
		keywords    = "dark light mode colors color scheme",
		default     = gfx.DEFAULT_THEME,
		choices     = gfx.THEME_NAMES[:],
		picker      = true,
	},
	.Ui_Font = {
		section     = .Appearance,
		key         = "ui_font",
		name        = "Interface font",
		description = "Font for the file tree, pane titles, the status bar, menus and " +
		              "dialogs: one of the bundled " + gfx.BUNDLED_MD_FAMILY + ", " +
		              gfx.BUNDLED_PLEX_SANS + " or " + gfx.BUNDLED_FAMILY +
		              ", or an installed font.",
		keywords    = "font family typeface ui interface sidebar menu",
		default     = gfx.BUNDLED_MD_FAMILY,
		picker      = true,
	},
	.Restore_Session = {
		section     = .General,
		key         = "restore_session",
		name        = "Restore projects",
		description = "Open a project as it was left, with its files and terminals where " +
		              "they were. Started without a folder or file, reopen the last project.",
		keywords    = "startup reopen workspace panes session project",
		default     = true,
		user_only   = true,
	},
	.Recent_Files = {
		section     = .General,
		key         = "recent_files",
		name        = "Recent files",
		description = "How many recently used files the sidebar lists under RECENT, after " +
		              "the pinned ones. 0 lists only pinned files.",
		keywords    = "sidebar recent history pinned files",
		default     = int(5),
		min         = 0,
		max         = 20,
	},
	.Ask_Above_Mb = {
		section     = .General,
		key         = "ask_above_mb",
		name        = "Ask before opening files larger than",
		description = "In megabytes: a larger file opens only once you choose to, as it " +
		              "takes at least that much memory. 0 never asks.",
		keywords    = "large big huge file size memory open warning",
		default     = int(256),
		min         = 0,
		max         = 65536,
		step        = 64,
	},
	.Collapsed_Sections = {
		section     = .General,
		key         = "collapsed_sections",
		description = "Sections the settings window shows collapsed, e.g. \"keybindings, lsp\".",
		default     = "",
		user_only   = true,
	},
	.Smooth_Scroll = {
		section     = .Appearance,
		key         = "smooth_scroll",
		name        = "Smooth scrolling",
		description = "Ease the view when scrolling, instead of moving in notches.",
		keywords    = "scroll animation wheel",
		default     = true,
	},
	.Text_Contrast = {
		section     = .Appearance,
		key         = "text_contrast",
		name        = "Text contrast",
		description = "How solid the edges of letters are drawn; raise it for thin or " +
		              "small text. 0 draws them as the font is rasterized.",
		keywords    = "font smoothing antialiasing gamma thin dim weight sharp",
		default     = f64(0.5),
		min         = 0,
		max         = 4,
		step        = 0.25,
	},
	.Text_Antialiasing = {
		section     = .Appearance,
		key         = "text_antialiasing",
		name        = "Text antialiasing",
		description = "\"subpixel\" smooths letters with the red, green and blue stripes " +
		              "of LCD screens, like ClearType: sharper below 200% scaling. " +
		              "\"grayscale\" suits OLED and rotated screens. \"auto\" uses " +
		              "subpixel below 200% when the system does.",
		keywords    = "cleartype lcd subpixel grayscale smoothing sharp blurry font",
		default     = "auto",
		choices     = ANTIALIASING[:],
	},
	.Font_Family = {
		section     = .Font,
		key         = "family",
		name        = "Font",
		description = "Editor and terminal font: the bundled " + gfx.BUNDLED_FAMILY +
		              " or an installed monospace font.",
		keywords    = "font family typeface monospace",
		default     = gfx.BUNDLED_FAMILY,
		picker      = true,
	},
	.Font_Size = {
		section     = .Font,
		key         = "size",
		name        = "Font size",
		description = "Editor and terminal text size.",
		keywords    = "font text zoom",
		default     = int(15),
		min         = 8,
		max         = 40,
	},
	.Font_Weight = {
		section     = .Font,
		key         = "weight",
		name        = "Font weight",
		description = "Stroke thickness, from 100 (thin) to 900 (black). The font's " +
		              "nearest weight is used.",
		keywords    = "font thickness bold light thin heavy",
		default     = int(500),
		min         = 100,
		max         = 900,
		step        = 100,
	},
	.Line_Height = {
		section     = .Font,
		key         = "line_height",
		name        = "Line height",
		description = "Space from one line to the next, as a multiple of the font size.",
		keywords    = "font spacing leading",
		default     = f64(1.35),
		min         = 1,
		max         = 2.5,
		step        = 0.05,
	},
	.Letter_Spacing = {
		section     = .Font,
		key         = "letter_spacing",
		name        = "Letter spacing",
		description = "Extra space between characters, in pixels. Columns stay on " +
		              "whole pixels of the screen, so small steps can round away.",
		keywords    = "font spacing tracking width",
		default     = f64(0),
		min         = -2,
		max         = 5,
		step        = 0.25,
	},
	.Terminal_Shell = {
		section     = .Terminal,
		key         = "shell",
		name        = "Shell",
		description = "Command line to run, e.g. \"pwsh -NoLogo\". Empty uses the " +
		              "default. Applies on restart.",
		keywords    = "pwsh powershell cmd bash command line",
		default     = "",
	},
	.Terminal_Backend = {
		section     = .Terminal,
		key         = "backend",
		name        = "Keep terminals running",
		description = "Where new terminals run: \"local\" ends a shell with typo; \"herdr\" " +
		              "runs it in herdr-core, so it keeps running after typo quits and " +
		              "shows again, with its history, when the folder is reopened. " +
		              "Terminals already open keep theirs.",
		keywords    = "herdr persistent background session detach",
		default     = "local",
		choices     = TERMINAL_BACKENDS[:],
	},
	.Bundled_Conpty = {
		section     = .Terminal,
		key         = "bundled_conpty",
		name        = ODIN_OS == .Windows ? "Bundled console host" : "",
		description = "Use the faster console host from Windows Terminal, saved once to " +
		              "%LOCALAPPDATA%\\typo. Off uses the built-in one and deletes the " +
		              "saved copy. Applies on restart.",
		keywords    = "conpty openconsole windows terminal",
		default     = true,
		user_only   = true,
	},
	.Renderer = {
		section     = .Advanced,
		key         = "renderer",
		description = "Graphics backend; \"auto\" lets SDL choose. Applies on restart.",
		default     = "auto",
		choices     = RENDERERS[:],
		user_only   = true,
	},
	.Show_Fps = {
		section     = .Advanced,
		key         = "show_fps",
		name        = "Show FPS",
		description = "Redraw every frame and show the frame rate in the status bar.",
		keywords    = "frame rate performance",
		default     = false,
	},
	.Markdown_View = {
		section     = .Markdown,
		key         = "view",
		name        = "Open Markdown as",
		description = "How Markdown files open: \"rendered\" (editable, with the syntax " +
		              "shown where the caret is) or \"text\". Toggle a file with the eye " +
		              "in the status bar.",
		keywords    = "markdown preview rendered source live",
		default     = "rendered",
		choices     = MARKDOWN_VIEWS[:],
	},
	.Markdown_Font = {
		section     = .Markdown,
		key         = "font",
		name        = "Markdown font",
		description = "Font for rendered Markdown text: the bundled " + gfx.BUNDLED_MD_FAMILY +
		              " or " + gfx.BUNDLED_PLEX_SANS + ", or an installed font. Code uses " +
		              "the editor font.",
		keywords    = "markdown font family typeface prose",
		default     = gfx.BUNDLED_MD_FAMILY,
		picker      = true,
	},
	.Markdown_Font_Size = {
		section     = .Markdown,
		key         = "font_size",
		name        = "Markdown font size",
		description = "Text size of rendered Markdown; headings are larger.",
		keywords    = "markdown font text zoom",
		default     = int(16),
		min         = 10,
		max         = 32,
	},
	.Markdown_Line_Height = {
		section     = .Markdown,
		key         = "line_height",
		name        = "Markdown line height",
		description = "Space from one line of rendered Markdown to the next, as a " +
		              "multiple of the font size.",
		keywords    = "markdown spacing leading",
		default     = f64(1.7),
		min         = 1.2,
		max         = 2.5,
		step        = 0.05,
	},
	.Markdown_Max_Width = {
		section     = .Markdown,
		key         = "max_width",
		name        = "Markdown text width",
		description = "Widest rendered Markdown text, in pixels, centered in the pane. " +
		              "0 uses the whole pane. Wider tables may extend past it.",
		keywords    = "markdown readable line length width column wrap",
		default     = int(760),
		min         = 0,
		max         = 4000,
		step        = 20,
	},
	.Words = {
		section     = .Completions,
		key         = "words",
		name        = "Word completions",
		description = "Complete words from the file: \"fallback\" when the language server " +
		              "has nothing (no server, an empty answer or an error) or doesn't " +
		              "answer in time, \"enabled\" alongside the server's, or \"disabled\".",
		keywords    = "completion words buffer autocomplete suggestions",
		default     = "fallback",
		choices     = WORDS_MODES[:],
	},
	.Words_Min_Length = {
		section     = .Completions,
		key         = "words_min_length",
		name        = "Word completions after",
		description = "Characters typed before words are offered on their own. Trigger " +
		              "completion offers them at any length.",
		keywords    = "completion words minimum length characters",
		default     = int(3),
		min         = 1,
		max         = 10,
	},
	.Words_In_Text_Files = {
		section     = .Completions,
		key         = "words_in_text_files",
		name        = "Words in prose",
		description = "Offer word completions in Markdown and plain text files too.",
		keywords    = "completion words markdown text prose",
		default     = false,
	},
	.Lsp_Fetch_Timeout = {
		section     = .Completions,
		key         = "lsp_fetch_timeout_ms",
		name        = "Server wait",
		description = "How long the language server has to answer, in milliseconds, before " +
		              "the file's words show instead (with \"fallback\") or without its " +
		              "items (with \"enabled\"). 0 waits for its answer.",
		keywords    = "completion timeout language server lsp words",
		default     = int(500),
		min         = 0,
		max         = 5000,
		step        = 50,
	},
	.Lsp_Enabled = {
		section     = .Language_Servers,
		key         = "enabled",
		name        = "Language servers",
		description = "Start the installed language servers for open files: hover, go to " +
		              "definition, symbols and diagnostics. Each server can be turned on or " +
		              "off, pointed at a program (path) or changed in an [lsp.<name>] table.",
		keywords    = "lsp language server intellisense diagnostics completion",
		default     = true,
	},
	.Lsp_Hover_Delay = {
		section     = .Language_Servers,
		key         = "hover_delay",
		name        = "Hover delay",
		description = "How long the pointer rests on code before what the language server " +
		              "knows about it shows, in milliseconds. 0 shows it only on Show hover.",
		keywords    = "lsp hover tooltip documentation popup",
		default     = int(400),
		min         = 0,
		max         = 3000,
		step        = 50,
	},
}

Setting_Value :: union {
	^bool,
	^int,
	^f64,
	^string,
}


setting_value :: proc(s: ^Setting_Values, x: Setting) -> Setting_Value {
	switch x {
	case .Restore_Session:      return &s.restore_session
	case .Recent_Files:         return &s.recent_files
	case .Ask_Above_Mb:         return &s.ask_above_mb
	case .Collapsed_Sections:   return &s.collapsed_sections
	case .Theme:                return &s.theme
	case .Ui_Font:              return &s.ui_font
	case .Font_Family:          return &s.font_family
	case .Font_Size:            return &s.font_size
	case .Font_Weight:          return &s.font_weight
	case .Line_Height:          return &s.line_height
	case .Letter_Spacing:       return &s.letter_spacing
	case .Smooth_Scroll:        return &s.smooth_scroll
	case .Text_Contrast:        return &s.text_contrast
	case .Text_Antialiasing:    return &s.text_antialiasing
	case .Terminal_Shell:       return &s.terminal_shell
	case .Terminal_Backend:     return &s.terminal_backend
	case .Bundled_Conpty:       return &s.bundled_conpty
	case .Renderer:             return &s.renderer
	case .Show_Fps:             return &s.show_fps
	case .Markdown_View:        return &s.markdown_view
	case .Markdown_Font:        return &s.markdown_font
	case .Markdown_Font_Size:   return &s.markdown_font_size
	case .Markdown_Line_Height: return &s.markdown_line_height
	case .Markdown_Max_Width:   return &s.markdown_max_width
	case .Words:                return &s.words
	case .Words_Min_Length:     return &s.words_min_length
	case .Words_In_Text_Files:  return &s.words_in_text_files
	case .Lsp_Fetch_Timeout:    return &s.lsp_fetch_timeout
	case .Lsp_Enabled:          return &s.lsp_enabled
	case .Lsp_Hover_Delay:      return &s.lsp_hover_delay
	}
	return nil
}


// "appearance.theme"
setting_path :: proc(x: Setting) -> string {
	section := SECTION_KEYS[SETTINGS[x].section]
	return strings.concatenate({section, ".", SETTINGS[x].key}, context.temp_allocator)
}


set_string :: proc(dst: ^string, value: string) {
	if dst^ == value do return

	delete(dst^)
	dst^ = strings.clone(value)
}


setting_reset :: proc(s: ^Setting_Values, x: Setting) {
	switch v in setting_value(s, x) {
	case ^bool:   v^ = SETTINGS[x].default.(bool)
	case ^int:    v^ = SETTINGS[x].default.(int)
	case ^f64:    v^ = SETTINGS[x].default.(f64)
	case ^string: set_string(v, SETTINGS[x].default.(string))
	}
}


// Copies one setting's value from `src` to `dst`
setting_copy :: proc(dst, src: ^Setting_Values, x: Setting) {
	switch v in setting_value(dst, x) {
	case ^bool:   v^ = setting_value(src, x).(^bool)^
	case ^int:    v^ = setting_value(src, x).(^int)^
	case ^f64:    v^ = setting_value(src, x).(^f64)^
	case ^string: set_string(v, setting_value(src, x).(^string)^)
	}
}


setting_values_destroy :: proc(s: ^Setting_Values) {
	for x in Setting {
		v, is_string := setting_value(s, x).(^string)
		if is_string do delete(v^)
	}
	s^ = {}
}


// Puts the user's settings back to their defaults: every value, the
// keybindings and the servers' tables
settings_reset_all :: proc(s: ^Settings) {
	for x in Setting do setting_reset(&s.user, x)
	for cmd in Command do s.bindings[cmd] = default_bindings(cmd)
	s.terminal_commands = DEFAULT_TERMINAL_COMMANDS
	langs.server_overrides_clear(&s.servers)
	settings_resolve(s)
}


// Drops every value the project sets: the user's apply again
settings_clear_project :: proc(s: ^Settings) {
	setting_values_destroy(&s.project.values)
	s.project.set = {}
	settings_resolve(s)
}


// Works out the values in effect: the project's where it sets one, else the
// user's
settings_resolve :: proc(s: ^Settings) {
	for x in Setting {
		from := x in s.project.set ? &s.project.values : &s.user
		setting_copy(&s.values, from, x)
	}
}


// Steps a choice, bool or number setting by `dir` (-1 or +1), clamped
setting_step :: proc(s: ^Setting_Values, x: Setting, dir: int) {
	info := SETTINGS[x]
	step := info.step != 0 ? info.step : 1

	switch v in setting_value(s, x) {
	case ^bool:
		v^ = dir > 0

	case ^int:
		v^ = clamp(v^ + dir * int(step), int(info.min), int(info.max))

	case ^f64:
		v^ = clamp(math.round(v^ / step + f64(dir)) * step, info.min, info.max)

	case ^string:
		if len(info.choices) == 0 do return

		i := 0
		for c, j in info.choices {
			if c == v^ do i = j
		}
		last := len(info.choices) - 1
		set_string(v, info.choices[clamp(i + dir, 0, last)])
	}
}


// --- Load / save -------------------------------------------------------------------

// Called once at startup, before the window shows: works out the path, then
// reads (or creates) the file at once, and has the config thread watch it
settings_init :: proc(s: ^Settings) {
	settings_reset_all(s)

	// Where the file is
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

	mtime, _ := os.last_write_time_by_name(s.path)
	config_watch(.User_Settings, s.path, mtime)
}


settings_destroy :: proc(s: ^Settings) {
	setting_values_destroy(&s.values)
	setting_values_destroy(&s.user)
	setting_values_destroy(&s.project.values)
	for &o in s.servers do langs.server_override_destroy(&o)
	delete(s.servers)
	delete(s.path)
	delete(s.error)
	delete(s.project_error)
	s^ = {}
}


// Reads settings.toml at once (at startup, and in tests). On a syntax error
// the current settings are kept; invalid values fall back to their defaults.
// Either way the problem is shown in the settings window
settings_load :: proc(s: ^Settings) {
	loaded := settings_read_file(s.path, .User)
	settings_take_user(s, &loaded)
}


// What a settings file says, owned: read on the config thread, or at once
Loaded_Settings :: struct {
	read:              bool, // read and parsed; else `problems` says why, and nothing is set
	missing:           bool, // there is no such file (not read)
	values:            Setting_Values,
	set:               bit_set[Setting], // the values it sets: all, for the user's
	bindings:          Bindings,                       // the user's
	terminal_commands: bit_set[Command],               // the user's
	servers:           [dynamic]langs.Server_Override, // the user's
	pinned:            [dynamic]string,                // a project's, as written
	problems:          string,
}


// Reads and parses a settings file of either layer (on any thread). The
// user's gives every value, the defaults where it leaves one out or has an
// invalid one; a project's only what it sets
settings_read_file :: proc(path: string, scope: Settings_Scope) -> (l: Loaded_Settings) {
	if !os.exists(path) {
		l.missing = true
		return
	}

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		l.problems = fmt.aprintf("could not read %s", path)
		return
	}
	return settings_parse(string(data), scope)
}


// Parses a settings file's text (see settings_read_file)
settings_parse :: proc(text: string, scope: Settings_Scope) -> (l: Loaded_Settings) {
	name := scope == .User ? "settings.toml" : ".typo/settings.toml"
	doc, err := toml.parse(text, context.temp_allocator)
	defer toml.destroy(doc, context.temp_allocator)
	if err.line != 0 {
		l.problems = fmt.aprintf("%s line %d: %s", name, err.line, err.msg)
		return
	}

	l.read = true
	problems := make([dynamic]string, context.temp_allocator)

	// The settings: the user's from their defaults
	if scope == .User {
		for x in Setting do setting_reset(&l.values, x)
		l.set = ~bit_set[Setting]{}
	}
	for x in Setting {
		v, found := toml.get(doc.root, setting_path(x))
		if !found do continue

		switch {
		case scope == .Project && SETTINGS[x].user_only:
			problem := fmt.tprintf("%s is set in your own settings.toml", setting_path(x))
			append(&problems, problem)
		case !set_from_toml(&l.values, x, v):
			append(&problems, setting_problem(&l.values, x))
		case:
			l.set += {x}
		}
	}

	switch scope {
	case .User:
		parse_bindings(&l.bindings, doc, &problems)
		parse_terminal_commands(&l.terminal_commands, doc, &problems)
		langs.load_server_overrides(&l.servers, doc, &problems)

	case .Project:
		if _, found := toml.get(doc.root, "keybindings"); found {
			append(&problems, "keybindings are set in your own settings.toml")
		}
		if _, found := toml.get(doc.root, TERMINAL_COMMANDS_KEY); found {
			append(&problems, TERMINAL_COMMANDS_KEY + " is set in your own settings.toml")
		}
		parse_pinned(&l.pinned, doc, &problems)
	}

	l.problems = strings.join(problems[:], "; ")
	return
}


loaded_settings_destroy :: proc(l: ^Loaded_Settings) {
	setting_values_destroy(&l.values)
	for &o in l.servers do langs.server_override_destroy(&o)
	delete(l.servers)
	for path in l.pinned do delete(path)
	delete(l.pinned)
	delete(l.problems)
	l^ = {}
}


// The keybindings: one chord, or a list of them, from the defaults
@(private = "file")
parse_bindings :: proc(b: ^Bindings, doc: ^toml.Document, problems: ^[dynamic]string) {
	for cmd in Command do b[cmd] = default_bindings(cmd)

	for info, cmd in COMMANDS {
		path := strings.concatenate({"keybindings.", info.key}, context.temp_allocator)
		v, found := toml.get(doc.root, path)
		if !found do continue

		texts := make([dynamic]string, context.temp_allocator)
		#partial switch x in v {
		case string:
			append(&texts, x)
		case []toml.Value:
			for item in x {
				str, is_str := item.(string)
				if is_str do append(&texts, str)
			}
		}

		b[cmd] = {}
		n := 0
		for text in texts {
			chord, ok := parse_chord(text)
			if !ok {
				append(problems, fmt.tprintf("keybindings.%s: unknown key %q", info.key, text))
			} else if n < MAX_CHORDS {
				b[cmd][n] = chord
				n += 1
			}
		}
	}
}


// Where settings.toml lists the commands that work while a terminal has focus
TERMINAL_COMMANDS_SECTION :: "terminal"
TERMINAL_COMMANDS_NAME    :: "commands"
TERMINAL_COMMANDS_KEY     :: TERMINAL_COMMANDS_SECTION + "." + TERMINAL_COMMANDS_NAME


// The commands that work while a terminal has focus: terminal.commands, a list
// of command names, else the defaults
@(private = "file")
parse_terminal_commands :: proc(
	set: ^bit_set[Command],
	doc: ^toml.Document,
	problems: ^[dynamic]string,
) {
	set^ = DEFAULT_TERMINAL_COMMANDS
	v, found := toml.get(doc.root, TERMINAL_COMMANDS_KEY)
	if !found do return

	list, is_list := v.([]toml.Value)
	if !is_list {
		append(problems, TERMINAL_COMMANDS_KEY + " must be a list of command names")
		return
	}

	set^ = {}
	for item in list {
		name, _ := item.(string)
		cmd, known := command_from_key(name)
		switch {
		case !known:
			append(problems, fmt.tprintf("%s: unknown command %q", TERMINAL_COMMANDS_KEY, name))
		case cmd in EDITOR_COMMANDS:
			problem := fmt.tprintf("%s: %s only acts in editors", TERMINAL_COMMANDS_KEY, name)
			append(problems, problem)
		case:
			set^ += {cmd}
		}
	}
}


// A project's pinned files: project.pinned, a list of paths
@(private = "file")
parse_pinned :: proc(pinned: ^[dynamic]string, doc: ^toml.Document, problems: ^[dynamic]string) {
	v, found := toml.get(doc.root, PINNED_KEY)
	if !found do return

	list, is_list := v.([]toml.Value)
	if !is_list {
		append(problems, PINNED_KEY + " must be a list of paths")
		return
	}
	for item in list {
		path, is_string := item.(string)
		if is_string && path != "" {
			append(pinned, strings.clone(path))
		}
	}
}


// Where a project's settings file keeps its pinned files
PINNED_SECTION :: "project"
PINNED_NAME    :: "pinned"
PINNED_KEY     :: PINNED_SECTION + "." + PINNED_NAME


// Puts what settings.toml says in place of the user's settings (taking it). On
// a problem reading it, the settings stay as they were
settings_take_user :: proc(s: ^Settings, l: ^Loaded_Settings) {
	defer loaded_settings_destroy(l)

	set_string(&s.error, l.problems)
	if !l.read do return

	setting_values_destroy(&s.user)
	s.user, l.values = l.values, {}
	s.bindings = l.bindings
	s.terminal_commands = l.terminal_commands
	for &o in s.servers do langs.server_override_destroy(&o)
	delete(s.servers)
	s.servers, l.servers = l.servers, {}
	settings_resolve(s)
}


// Puts what a project's settings file says in place of the project's layer
// (taking it; its pinned files are the project's to take first). A missing
// file sets nothing; on a problem reading it, the layer stays as it was
settings_take_project :: proc(s: ^Settings, l: ^Loaded_Settings) {
	defer loaded_settings_destroy(l)

	set_string(&s.project_error, l.problems)
	if !l.read && !l.missing {
		return
	}

	setting_values_destroy(&s.project.values)
	s.project.values, l.values = l.values, {}
	s.project.set = l.set
	settings_resolve(s)
}


@(private = "file")
set_from_toml :: proc(s: ^Setting_Values, x: Setting, v: toml.Value) -> bool {
	info := SETTINGS[x]

	switch dst in setting_value(s, x) {
	case ^bool:
		b := v.(bool) or_return
		dst^ = b

	case ^int:
		n := v.(i64) or_return
		if f64(n) < info.min || f64(n) > info.max {
			return false
		}
		dst^ = int(n)

	case ^f64:
		n: f64
		#partial switch x in v {
		case f64: n = x
		case i64: n = f64(x)
		case:     return false
		}
		if n < info.min || n > info.max {
			return false
		}
		dst^ = n

	case ^string:
		str := strings.trim_space(v.(string) or_return)
		if info.choices != nil && !contains(info.choices, str) {
			return false
		}
		set_string(dst, str)
	}
	return true
}


@(private = "file")
setting_problem :: proc(s: ^Setting_Values, x: Setting) -> string {
	info := SETTINGS[x]
	path := setting_path(x)

	switch _ in setting_value(s, x) {
	case ^bool:
		return fmt.tprintf("%s must be true or false", path)

	case ^int:
		lo, hi := int(info.min), int(info.max)
		return fmt.tprintf("%s must be a whole number from %d to %d", path, lo, hi)

	case ^f64:
		lo, hi := format_decimal(info.min), format_decimal(info.max)
		return fmt.tprintf("%s must be a number from %s to %s", path, lo, hi)

	case ^string:
		if info.choices != nil {
			choices := strings.join(info.choices, ", ", context.temp_allocator)
			return fmt.tprintf("%s must be one of: %s", path, choices)
		}
	}
	return fmt.tprintf("%s must be a string", path)
}


// A number with up to two decimals and at least one: "1.35", "2.0", "-0.25"
format_decimal :: proc(v: f64) -> string {
	s := strings.trim_right(fmt.tprintf("%.2f", v), "0")
	if strings.has_suffix(s, ".") do s = fmt.tprintf("%s0", s)
	return s == "-0.0" ? "0.0" : s
}


@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s do return true
	}
	return false
}


// Writes the user's settings, replacing the file atomically, before returning
// (at startup, and in tests). The file then holds valid settings, so a problem
// reported by the last load no longer applies
settings_save :: proc(s: ^Settings) {
	if s.path == "" do return

	if _, ok := write_file_atomic(s.path, settings_text(s)); ok {
		set_string(&s.error, "")
	}
}


// Like settings_save, but the file is written on the config thread. A save
// that is still waiting is replaced
settings_save_later :: proc(s: ^Settings) {
	if s.path == "" do return

	config_post(Config_Write{
		path    = strings.clone(s.path),
		text    = strings.clone(settings_text(s)),
		watched = .User_Settings,
	})
	set_string(&s.error, "")
}


// Writes a temp file, then moves it into place (on any thread). Returns the
// file's new time
write_file_atomic :: proc(path, text: string) -> (mtime: time.Time, ok: bool) {
	_ = os.make_directory_all(os.dir(path))

	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	write_err := os.write_entire_file(tmp, text)
	if write_err != nil || os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		sdl.Log("could not write %s", strings.clone_to_cstring(path, context.temp_allocator))
		return {}, false
	}

	mtime, _ = os.last_write_time_by_name(path)
	return mtime, true
}


// settings.toml's text for the user's settings (temp)
@(private = "file")
settings_text :: proc(s: ^Settings) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for key, section in SECTION_KEYS {
		lines := make([dynamic]Toml_Line, context.temp_allocator)

		if section == .Keybindings {
			for info, cmd in COMMANDS {
				chords := make([dynamic]string, context.temp_allocator)
				for c in s.bindings[cmd] {
					if chord_bound(c) do append(&chords, toml.quote(format_chord(c)))
				}

				value: string
				if len(chords) == 1 {
					value = chords[0]
				} else {
					joined := strings.join(chords[:], ", ", context.temp_allocator)
					value = fmt.tprintf("[%s]", joined)
				}
				append(&lines, Toml_Line{info.key, value})
			}
		} else {
			for info, x in SETTINGS {
				if info.section != section do continue
				append(&lines, Toml_Line{info.key, toml_value(&s.user, x)})
			}
		}
		if key == TERMINAL_COMMANDS_SECTION {
			append(&lines, Toml_Line{TERMINAL_COMMANDS_NAME, terminal_commands_toml(s)})
		}

		if section != min(Section) do strings.write_byte(&sb, '\n')
		write_toml_section(&sb, key, lines[:])

		if section == .Language_Servers do langs.write_server_overrides(&sb, s.servers[:])
	}
	return strings.to_string(sb)
}


// The commands that work while a terminal has focus, as a TOML list (temp)
@(private = "file")
terminal_commands_toml :: proc(s: ^Settings) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for cmd in s.terminal_commands {
		append(&names, toml.quote(COMMANDS[cmd].key))
	}
	return fmt.tprintf("[%s]", strings.join(names[:], ", ", context.temp_allocator))
}


// A project's .typo/settings.toml text (temp): the values it sets, then its
// pinned files (paths as written)
project_settings_text :: proc(layer: ^Setting_Layer, pinned: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for key, section in SECTION_KEYS {
		lines := make([dynamic]Toml_Line, context.temp_allocator)
		for info, x in SETTINGS {
			if info.section == section && x in layer.set {
				append(&lines, Toml_Line{info.key, toml_value(&layer.values, x)})
			}
		}
		if len(lines) == 0 do continue

		if strings.builder_len(sb) > 0 do strings.write_byte(&sb, '\n')
		write_toml_section(&sb, key, lines[:])
	}

	// The pinned files, one to a line
	if len(pinned) > 0 {
		if strings.builder_len(sb) > 0 do strings.write_byte(&sb, '\n')

		fmt.sbprintf(&sb, "[%s]\n%s = [\n", PINNED_SECTION, PINNED_NAME)
		for path in pinned do fmt.sbprintf(&sb, "\t%s,\n", toml.quote(path))
		strings.write_string(&sb, "]\n")
	}
	return strings.to_string(sb)
}


// A key and its value, as a line of a settings file
@(private = "file")
Toml_Line :: struct {
	key, value: string,
}


// "[section]", then its lines, their values lined up in one column
@(private = "file")
write_toml_section :: proc(sb: ^strings.Builder, section: string, lines: []Toml_Line) {
	width := 0
	for line in lines do width = max(width, len(line.key))

	fmt.sbprintf(sb, "[%s]\n", section)
	for line in lines do fmt.sbprintf(sb, "%-*s = %s\n", width, line.key, line.value)
}


// A setting's value as TOML (temp)
@(private = "file")
toml_value :: proc(s: ^Setting_Values, x: Setting) -> string {
	switch v in setting_value(s, x) {
	case ^bool:   return fmt.tprintf("%v", v^)
	case ^int:    return fmt.tprintf("%d", v^)
	case ^f64:    return format_decimal(v^)
	case ^string: return toml.quote(v^)
	}
	return ""
}


// The user's settings changed (a value, the keybindings or the servers'
// tables): they are worked out again, saved (on the config thread) and pushed
// into the running editor
settings_changed :: proc() {
	settings_resolve(&g.settings)
	settings_save_later(&g.settings)
	apply_settings()
}


// The project's layer changed: it is saved with the project's pinned files
// and pushed into the running editor
project_settings_changed :: proc() {
	settings_resolve(&g.settings)
	project_save_settings()
	apply_settings()
}


// A settings file changed on disk was read again (config_io.odin): its values
// replace its layer's, and apply
settings_file_read :: proc(file: Watched_File, l: ^Loaded_Settings) {
	switch file {
	case .User_Settings:
		settings_take_user(&g.settings, l)
	case .Project_Settings:
		if l.read || l.missing {
			project_pins_read(l.pinned[:])
			g.project.has_file = !l.missing
		}
		settings_take_project(&g.settings, l)
	}
	apply_settings()
}


apply_settings :: proc() {
	gfx.theme = gfx.theme_by_name(g.settings.theme)

	// Not for each theme the theme list previews: that re-rasterizes all text
	w := &g.settings_window
	previewing_theme := w.picking && w.picker == .Theme
	if !previewing_theme {
		gfx.text_set_contrast(&gfx.text_system, gfx.theme.text, f32(g.settings.text_contrast))
	}

	// A new antialiasing reopens every font: Clay measures again next frame
	before := gfx.text_system.generation
	gfx.text_set_antialiasing(&gfx.text_system, antialiasing_setting())
	if gfx.text_system.generation != before do g.measure_stale = true

	for p in g.panes.open {
		t, is_terminal := p.content.(^Terminal)
		if is_terminal do terminal_apply_theme(t)
	}

	apply_ui_font()
	apply_editor_font()
	apply_markdown_font()
	langs.settings_changed()
}


@(private = "file")
antialiasing_setting :: proc() -> gfx.Antialiasing {
	switch g.settings.text_antialiasing {
	case "subpixel":  return .Subpixel
	case "grayscale": return .Grayscale
	}
	return .Auto
}


// Points the interface (everything Clay lays out as text) at the configured
// family, like apply_editor_font. Clay keeps what it measured with the old
// faces; that is reset at the start of the next frame, outside any layout
apply_ui_font :: proc() {
	if gfx.text_system.engine == nil do return

	regular, semibold, bold, found := gfx.ui_family_sources(&g.fonts, g.settings.ui_font)
	if !found do gfx.fonts_scan(&g.fonts, walk_files)

	before := gfx.text_system.generation
	gfx.text_set_source(&gfx.text_system, .Body, regular)
	gfx.text_set_source(&gfx.text_system, .SemiBold, semibold)
	gfx.text_set_source(&gfx.text_system, .Bold, bold)
	if gfx.text_system.generation != before do g.measure_stale = true
}


// Points rendered Markdown at the configured family, like apply_editor_font
apply_markdown_font :: proc() {
	if gfx.text_system.engine == nil do return

	sources, found := gfx.markdown_family_sources(&g.fonts, g.settings.markdown_font)
	if !found do gfx.fonts_scan(&g.fonts, walk_files)

	for src, face in sources {
		gfx.text_set_source(&gfx.text_system, gfx.MD_FONTS[face], src)
	}
}


// Points the editor and terminal at the configured family. One that isn't
// bundled needs the installed fonts scanned; this runs again once that is done
// (see app_iterate)
apply_editor_font :: proc() {
	if gfx.text_system.engine == nil do return

	regular, bold, italic, found := gfx.font_family_sources(
		&g.fonts,
		g.settings.font_family,
		g.settings.font_weight,
	)
	if !found do gfx.fonts_scan(&g.fonts, walk_files)

	gfx.text_set_source(&gfx.text_system, .Editor, regular)
	gfx.text_set_source(&gfx.text_system, .Editor_Bold, bold)
	gfx.text_set_source(&gfx.text_system, .Editor_Italic, italic)
}
