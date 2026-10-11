package editor

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"

// The settings window: a rounded modal with a search bar at the top, then the
// settings grouped into sections. Every change is applied immediately and
// written to settings.toml.

Settings_Window :: struct {
	open:      bool,
	search:    [dynamic]u8,
	recording: Maybe(Command), // waiting for a key press to bind
	opened_at: u64,            // frame it was opened on

	// Keyboard focus: an index into `items`, or -1 for the search field.
	// `items` lists the rows shown last frame, in order.
	focus:     int,
	items:     [dynamic]Setting_Item,
	reveal:    bool, // scroll the focused row into view
}

// A row in the settings list: one of the fixed settings, or a keybinding.
Setting :: enum {
	Theme,
	Font_Size,
	Smooth_Scroll,
	Show_Fps,
}

Setting_Item :: union {
	Setting,
	Command,
}

SETTINGS_WIDTH :: 640

settings_window_toggle :: proc() {
	w := &g.settings_window
	w.open = !w.open
	w.opened_at = g.text.frame
	w.recording = nil
	w.focus = -1
	clear(&w.search)
	if w.open do g.finder.open = false
}

settings_window_destroy :: proc() {
	delete(g.settings_window.search)
	delete(g.settings_window.items)
}

// Returns true if the event was consumed by the settings window.
settings_window_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window
	if !w.open do return false

	#partial switch event.type {
	case .TEXT_INPUT:
		if w.recording == nil {
			append(&w.search, string(event.text.text))
			w.focus = -1 // typing goes back to the search field
		}
		return true

	case .KEY_DOWN:
		key := event.key
		if cmd, recording := w.recording.?; recording {
			switch {
			case key.key == sdl.K_ESCAPE:
				w.recording = nil
			case is_modifier_key(key.key):
				// Wait for the actual key.
			case:
				bind_command(cmd, chord_from_event(key))
				w.recording = nil
			}
			return true
		}
		shift := key.mod & sdl.KMOD_SHIFT != {}
		focused: Setting_Item
		if w.focus >= 0 && w.focus < len(w.items) do focused = w.items[w.focus]
		switch key.key {
		case sdl.K_ESCAPE:
			settings_window_toggle()
		case sdl.K_BACKSPACE:
			if len(w.search) > 0 {
				if key.mod & sdl.KMOD_CTRL != {} {
					clear(&w.search)
				} else {
					_, size := utf8.decode_last_rune(w.search[:])
					resize(&w.search, len(w.search) - size)
				}
				w.focus = -1
			}
		case sdl.K_DOWN:
			move_focus(+1, wrap = false)
		case sdl.K_UP:
			move_focus(-1, wrap = false)
		case sdl.K_TAB:
			move_focus(shift ? -1 : +1, wrap = true)
		case sdl.K_LEFT:
			if focused != nil do adjust_item(focused, -1)
		case sdl.K_RIGHT:
			if focused != nil do adjust_item(focused, +1)
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if focused == nil && len(w.items) > 0 {
				w.focus, w.reveal = 0, true // Enter in the search field jumps to the first result
			} else if focused != nil {
				activate_item(focused)
			}
		case sdl.K_DELETE:
			if focused != nil do reset_item(focused)
		case:
			// Let the "open settings" shortcut close the window; swallow the rest.
			if cmd, ok := command_for_key(key); ok && cmd == .Open_Settings do return false
		}
		return true
	}
	return false
}

// Moves keyboard focus through the rows; -1 is the search field.
@(private = "file")
move_focus :: proc(dir: int, wrap: bool) {
	w := &g.settings_window
	n := len(w.items)
	if n == 0 {
		w.focus = -1
		return
	}
	next := w.focus + dir
	if wrap {
		// Cycle search field -> rows -> search field.
		next = (next + 1 + (n + 1)) % (n + 1) - 1
	} else {
		next = clamp(next, -1, n - 1)
	}
	w.focus = next
	w.reveal = true
}

// Left/Right on a row.
@(private = "file")
adjust_item :: proc(item: Setting_Item, dir: int) {
	s := &g.settings
	switch v in item {
	case Setting:
		switch v {
		case .Theme:         s.theme = dir < 0 ? .Dark : .Light
		case .Font_Size:     s.font_size = clamp(s.font_size + dir, FONT_SIZE_MIN, FONT_SIZE_MAX)
		case .Smooth_Scroll: s.smooth_scroll = dir > 0
		case .Show_Fps:      s.show_fps = dir > 0
		}
		settings_changed()
	case Command:
	}
}

// Delete on a row: put that setting back to its default.
@(private = "file")
reset_item :: proc(item: Setting_Item) {
	s := &g.settings
	defaults: Settings
	settings_defaults(&defaults)
	defer delete(defaults.renderer)
	switch v in item {
	case Setting:
		switch v {
		case .Theme:         s.theme = defaults.theme
		case .Font_Size:     s.font_size = defaults.font_size
		case .Smooth_Scroll: s.smooth_scroll = defaults.smooth_scroll
		case .Show_Fps:      s.show_fps = defaults.show_fps
		}
	case Command:
		set_default_bindings(s, v)
	}
	settings_changed()
}

// Asks first: this also throws away every custom keybinding.
@(private = "file")
confirm_reset_all :: proc() {
	buttons := [?]sdl.MessageBoxButtonData {
		{buttonID = 0, text = "Reset all"},
		{flags = {.RETURNKEY_DEFAULT, .ESCAPEKEY_DEFAULT}, buttonID = 1, text = "Cancel"},
	}
	data := sdl.MessageBoxData {
		flags      = {.WARNING},
		window     = g.window,
		title      = "Reset settings",
		message    = "Reset all settings, including keybindings, to their defaults?",
		numbuttons = len(buttons),
		buttons    = &buttons[0],
	}
	choice: i32 = 1
	if sdl.ShowMessageBox(data, &choice) && choice == 0 {
		settings_reset_all(&g.settings)
		settings_changed()
	}
}

// Enter on a row: flip a choice, or start recording a keybinding.
@(private = "file")
activate_item :: proc(item: Setting_Item) {
	s := &g.settings
	switch v in item {
	case Setting:
		switch v {
		case .Theme:         s.theme = s.theme == .Dark ? .Light : .Dark
		case .Font_Size:     return
		case .Smooth_Scroll: s.smooth_scroll = !s.smooth_scroll
		case .Show_Fps:      s.show_fps = !s.show_fps
		}
		settings_changed()
	case Command:
		g.settings_window.recording = v
	}
}

// Scrolls the settings list so the focused row is visible. Uses last frame's
// layout, which is what the user is looking at.
@(private = "file")
reveal_focus :: proc() {
	w := &g.settings_window
	if !w.reveal do return
	w.reveal = false
	if w.focus < 0 || w.focus >= len(w.items) do return
	scroll := clay.GetScrollContainerData(clay.ID("SettingsList"))
	row := clay.GetElementData(item_row_id(w.items[w.focus]))
	list := clay.GetElementData(clay.ID("SettingsList"))
	if !scroll.found || !row.found || !list.found do return
	r, l := row.boundingBox, list.boundingBox
	if r.y < l.y {
		scroll.scrollPosition.y += l.y - r.y
	} else if r.y + r.height > l.y + l.height {
		scroll.scrollPosition.y -= r.y + r.height - (l.y + l.height)
	}
}

@(private = "file")
item_row_id :: proc(item: Setting_Item) -> clay.ElementId {
	switch v in item {
	case Setting: return clay.ID("SettingRow", u32(v))
	case Command: return clay.ID("SettingRow", 100 + u32(v))
	}
	return {}
}

// Binds a single chord to cmd, taking it away from any other command.
@(private = "file")
bind_command :: proc(cmd: Command, chord: Chord) {
	s := &g.settings
	for &chords in s.bindings {
		for &c in chords do if c == chord do c = {}
	}
	s.bindings[cmd] = {}
	s.bindings[cmd][0] = chord
	settings_changed()
}

@(private = "file")
settings_changed :: proc() {
	settings_save(&g.settings)
	apply_settings()
}

// --- UI ------------------------------------------------------------------------------

settings_window_ui :: proc() {
	w := &g.settings_window
	if !w.open do return
	g.in_modal = true
	defer g.in_modal = false
	reveal_focus()
	clear(&w.items)

	if clay.UI(clay.ID("SettingsBackdrop"))({
		layout = {
			sizing = {clay.SizingFixed(f32(g.window_w)), clay.SizingFixed(f32(g.window_h))},
			childAlignment = {x = .Center},
			padding = {top = 48},
		},
		backgroundColor = theme.backdrop,
		floating = {attachTo = .Root, zIndex = 100},
	}) {
		panel_id := clay.ID("Settings")
		if clay.UI(panel_id)({
			layout = {
				sizing = {clay.SizingFixed(min(SETTINGS_WIDTH, f32(g.window_w) - 32)), clay.SizingFixed(max(f32(g.window_h) - 96, 200))},
				layoutDirection = .TopToBottom,
				padding = {left = 20, right = 20, top = 16, bottom = 14},
				childGap = 14,
			},
			backgroundColor = theme.panel,
			cornerRadius = clay.CornerRadiusAll(10),
			border = {color = theme.border, width = clay.BorderOutside(1)},
		}) {
			header()
			search_field()
			if g.settings.error != "" do error_banner(g.settings.error)
			settings_list()
			footer()
		}

		// A click outside the panel closes it. Not on the frame it opened: the
		// click that opened it is still "pressed", and the panel has no layout yet.
		if g.mouse_pressed && w.opened_at != g.text.frame && !pointer_in(panel_id) do settings_window_toggle()
	}
}

@(private = "file")
header :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
		label("Settings", theme.text_bright, 16, .SemiBold)
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		if icon_button(clay.ID("SettingsClose"), .Close, size = 26, icon_size = 18) do settings_window_toggle()
		tooltip(clay.ID("SettingsClose"), "Close", "Esc")
	}
}

@(private = "file")
search_field :: proc() {
	w := &g.settings_window
	id := clay.ID("SettingsSearch")
	if g.mouse_pressed && pointer_in(id) {
		w.focus = -1
		w.recording = nil
	}
	focused := w.recording == nil && w.focus < 0
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(34)},
			padding = {left = 12, right = 12},
			childAlignment = {y = .Center},
		},
		backgroundColor = theme.bg,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = focused ? theme.accent : theme.border, width = clay.BorderOutside(1)},
	}) {
		if len(w.search) == 0 {
			if focused do text_caret()
			label("Search settings", theme.text_dim)
		} else {
			label(string(w.search[:]), theme.text_bright)
			if focused do text_caret()
		}
	}
}

@(private = "file")
error_banner :: proc(msg: string) {
	if clay.UI()({
		layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)},
		backgroundColor = theme.hover,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = theme.syntax[.Keyword], width = {left = 3}},
	}) {
		clay.TextDynamic(msg, {textColor = theme.text, fontId = u16(Font_Id.Body), fontSize = 12, lineHeight = 17, wrapMode = .Words})
	}
}

@(private = "file")
settings_list :: proc() {
	if clay.UI(clay.ID("SettingsList"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 18},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		query := strings.to_lower(string(g.settings_window.search[:]), context.temp_allocator)
		shown := 0

		appearance_theme := matches(query, "Appearance", "Theme", "dark light mode colors")
		appearance_font := matches(query, "Appearance", "Font size", "text editor zoom")
		appearance_scroll := matches(query, "Appearance", "Smooth scrolling", "scroll animation notched wheel")
		if appearance_theme || appearance_font || appearance_scroll {
			if section("Appearance") {
				if appearance_theme {
					if setting_row(Setting.Theme, "Theme", "Color scheme for the whole window.") do theme_control()
				}
				if appearance_font {
					if setting_row(Setting.Font_Size, "Font size", fmt.tprintf("Editor text size, %d to %d.", FONT_SIZE_MIN, FONT_SIZE_MAX)) do font_size_control()
				}
				if appearance_scroll {
					if setting_row(Setting.Smooth_Scroll, "Smooth scrolling", "Ease the view when scrolling, instead of moving in notches.") do smooth_scroll_control()
				}
			}
			shown += 1
		}

		any_binding := false
		for info, cmd in COMMANDS {
			if matches(query, "Keybindings", info.name, bindings_text(cmd)) do any_binding = true
		}
		if any_binding {
			if section("Keybindings") {
				for info, cmd in COMMANDS {
					if !matches(query, "Keybindings", info.name, bindings_text(cmd)) do continue
					if setting_row(cmd, info.name, "") do keybinding_control(cmd)
				}
			}
			shown += 1
		}

		if matches(query, "Advanced", "Show FPS", "frame rate performance") {
			if section("Advanced") {
				if setting_row(Setting.Show_Fps, "Show FPS", "Redraw every frame and show the frame rate in the status bar.") do show_fps_control()
			}
			shown += 1
		}

		if shown == 0 {
			if clay.UI()({layout = {padding = {left = 4, top = 8}}}) {
				label("No settings match your search", theme.text_dim)
			}
		}
	}
}

@(private = "file")
matches :: proc(query: string, parts: ..string) -> bool {
	if query == "" do return true
	for p in parts {
		if strings.contains(strings.to_lower(p, context.temp_allocator), query) do return true
	}
	return false
}

@(private = "file")
bindings_text :: proc(cmd: Command) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for c in g.settings.bindings[cmd] do if c.key != 0 do append(&parts, format_chord(c))
	return strings.join(parts[:], " ", context.temp_allocator)
}

// A titled group of rows. Use as: if section("Name") { rows }
@(deferred_none = end_section)
section :: proc(title: string) -> bool {
	clay._OpenElement()
	clay.ConfigureOpenElement({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}})
	if clay.UI()({layout = {padding = {left = 4, bottom = 6}}}) {
		label(strings.to_upper(title, context.temp_allocator), theme.text_dim, 12, .Bold)
	}
	return true
}

@(private = "file")
end_section :: proc() {
	clay._CloseElement()
}

// One setting: name and description on the left, its control on the right.
// Use as: if setting_row(...) { control }
@(deferred_none = end_setting_row)
setting_row :: proc(item: Setting_Item, name, description: string) -> bool {
	w := &g.settings_window
	append(&w.items, item)
	index := len(w.items) - 1
	focused := index == w.focus
	id := item_row_id(item)
	if clicked(id) do w.focus = index // clicking a row moves keyboard focus there
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = 40})},
			padding = {left = 10, right = 6, top = 6, bottom = 6},
			childAlignment = {y = .Center},
			childGap = 12,
		},
		backgroundColor = focused ? theme.hover : (clay.Hovered() ? theme.hover : {}),
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = focused ? theme.accent : {}, width = focused ? clay.BorderOutside(1) : {}},
	})
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}}) {
		label(name, theme.text)
		if description != "" do label(description, theme.text_dim, 12)
	}
	return true
}

@(private = "file")
end_setting_row :: proc() {
	clay._CloseElement()
}

// --- Controls -----------------------------------------------------------------------

@(private = "file")
theme_control :: proc() {
	if choice, changed := segmented("ThemeOption", {"Dark", "Light"}, int(g.settings.theme)); changed {
		g.settings.theme = Theme_Kind(choice)
		settings_changed()
	}
}

@(private = "file")
smooth_scroll_control :: proc() {
	if choice, changed := segmented("SmoothScroll", {"Off", "On"}, int(g.settings.smooth_scroll)); changed {
		g.settings.smooth_scroll = choice == 1
		settings_changed()
	}
}

@(private = "file")
show_fps_control :: proc() {
	if choice, changed := segmented("ShowFps", {"Off", "On"}, int(g.settings.show_fps)); changed {
		g.settings.show_fps = choice == 1
		settings_changed()
	}
}

// A row of mutually exclusive options. Returns the clicked option if it changed.
@(private = "file")
segmented :: proc(id_base: string, options: []string, selected: int) -> (choice: int, changed: bool) {
	if clay.UI()({
		layout = {padding = clay.PaddingAll(2), childGap = 2},
		backgroundColor = theme.bg,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		for option, i in options {
			id := clay.ID(id_base, u32(i))
			is_selected := i == selected
			if clay.UI(id)({
				layout = {sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = is_selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
				cornerRadius = clay.CornerRadiusAll(4),
			}) {
				label(option, is_selected ? theme.text_bright : theme.text_dim)
				if clicked(id) && !is_selected do choice, changed = i, true
			}
		}
	}
	return
}

@(private = "file")
font_size_control :: proc() {
	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if stepper_button(clay.ID("FontSmaller"), "-") && g.settings.font_size > FONT_SIZE_MIN {
			g.settings.font_size -= 1
			settings_changed()
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(36)}, childAlignment = {x = .Center}}}) {
			label(fmt.tprintf("%d", g.settings.font_size), theme.text_bright)
		}
		if stepper_button(clay.ID("FontLarger"), "+") && g.settings.font_size < FONT_SIZE_MAX {
			g.settings.font_size += 1
			settings_changed()
		}
	}
}

@(private = "file")
stepper_button :: proc(id: clay.ElementId, text: string) -> bool {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(28), clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		label(text, theme.text)
	}
	return clicked(id)
}

@(private = "file")
keybinding_control :: proc(cmd: Command) {
	w := &g.settings_window
	recording := w.recording == cmd
	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if !recording && !bindings_are_default(&g.settings, cmd) {
			reset_id := clay.ID("BindingReset", u32(cmd))
			if button(reset_id, "Reset") {
				set_default_bindings(&g.settings, cmd)
				settings_changed()
			}
			tooltip(reset_id, "Reset to default", "Del")
		}

		id := clay.ID("Binding", u32(cmd))
		if clay.UI(id)({
			layout = {
				sizing = {width = clay.SizingFit({min = 120}), height = clay.SizingFixed(26)},
				padding = {left = 8, right = 8},
				childGap = 6,
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = clay.Hovered() || recording ? theme.hover : theme.bg,
			cornerRadius = clay.CornerRadiusAll(5),
			border = {color = recording ? theme.accent : theme.border, width = clay.BorderOutside(1)},
		}) {
			if recording {
				label("Press keys…  (Esc cancels)", theme.accent, 12)
			} else {
				has_any := false
				for c, i in g.settings.bindings[cmd] {
					if c.key == 0 do continue
					if has_any do label("/", theme.text_dim, 12)
					label(format_chord(c), theme.text, 12)
					has_any = true
					_ = i
				}
				if !has_any do label("Unbound", theme.text_dim, 12)
			}
		}
		if clicked(id) do w.recording = recording ? nil : cmd
		if !recording do tooltip(id, "Change keybinding", "Enter")
	}
}

@(private = "file")
footer :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}, childGap = 8}}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			label("↑↓ select  ←→ change  Enter edit  Del reset", theme.text_dim, 12)
		}
		reset_id := clay.ID("SettingsResetAll")
		if button(reset_id, "Reset all") do confirm_reset_all()
		tooltip(reset_id, "Reset every setting to its default")
		if g.settings.path != "" {
			edit_id := clay.ID("SettingsEditFile")
			if button(edit_id, "Edit settings.toml") {
				g.pending = Open_File(strings.clone(g.settings.path))
				settings_window_toggle()
			}
			tooltip(edit_id, g.settings.path)
		}
	}
}

@(private = "file")
clicked :: proc(id: clay.ElementId) -> bool {
	return g.mouse_pressed && pointer_in(id) && pointer_in(clay.ID("SettingsList"))
}
