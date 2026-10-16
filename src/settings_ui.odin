package editor

import "core:fmt"
import "core:strings"

import clay "../vendor/clay-odin"
import "term"
import sdl "../vendor/sdl3"

// The settings window: a modal with a search field, then the settings grouped
// into sections. Every change is applied immediately and written to
// settings.toml.

SETTINGS_WIDTH :: 640

Settings_Window :: struct {
	open:      bool,
	opened_at: u64, // frame it was opened on
	search:    [dynamic]u8,
	recording: Maybe(Command), // waiting for a key press to bind

	// Keyboard focus: an index into `items`, or -1 for the search field.
	// `items` lists the rows shown last frame, in order.
	focus:     int,
	items:     [dynamic]Setting_Item,
	reveal:    bool, // scroll the focused row into view

	editing:   Maybe(Setting), // text setting being typed into
	edit_buf:  [dynamic]u8,
}

// A row in the settings list.
Setting_Item :: union {
	Setting,
	Command,
}

settings_window_toggle :: proc() {
	w := &g.settings_window
	w.open = !w.open
	w.opened_at = g.frame
	w.recording = nil
	w.editing = nil
	w.focus = -1
	clear(&w.search)
	if w.open do g.finder.open = false
}

settings_window_destroy :: proc() {
	delete(g.settings_window.search)
	delete(g.settings_window.items)
	delete(g.settings_window.edit_buf)
}

// Whether the pointer is over a text field (for the I-beam cursor).
settings_window_over_text :: proc() -> bool {
	return pointer_in(clay.ID("SettingsSearch")) || pointer_in(clay.ID("SettingField"))
}

// Returns true if the event was consumed by the settings window.
settings_window_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window
	if !w.open do return false

	if _, editing := w.editing.?; editing {
		if event.type == .KEY_DOWN {
			switch event.key.key {
			case sdl.K_RETURN, sdl.K_KP_ENTER:
				finish_text_edit(commit = true)
				return true
			case sdl.K_ESCAPE:
				finish_text_edit(commit = false)
				return true
			}
		}
		text_field_event(&w.edit_buf, event)
		return true
	}

	if cmd, recording := w.recording.?; recording {
		if event.type == .KEY_DOWN {
			switch {
			case event.key.key == sdl.K_ESCAPE:
				w.recording = nil
			case is_modifier_key(event.key.key):
				// Wait for the actual key.
			case:
				bind_command(cmd, chord_from_event(event.key))
				w.recording = nil
			}
		}
		return true
	}

	if _, changed := text_field_event(&w.search, event); changed {
		w.focus = -1 // typing goes back to the search field
		return true
	}
	if event.type != .KEY_DOWN do return event.type == .TEXT_INPUT

	key := event.key
	focused: Setting_Item
	if w.focus >= 0 && w.focus < len(w.items) do focused = w.items[w.focus]
	switch key.key {
	case sdl.K_ESCAPE:
		settings_window_toggle()
	case sdl.K_DOWN:
		move_focus(+1, wrap = false)
	case sdl.K_UP:
		move_focus(-1, wrap = false)
	case sdl.K_TAB:
		move_focus(key.mod & sdl.KMOD_SHIFT != {} ? -1 : +1, wrap = true)
	case sdl.K_LEFT, sdl.K_RIGHT:
		if x, ok := focused.(Setting); ok {
			setting_step(&g.settings, x, key.key == sdl.K_LEFT ? -1 : +1)
			settings_changed()
		}
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

@(private = "file")
start_text_edit :: proc(x: Setting) {
	w := &g.settings_window
	w.editing = x
	clear(&w.edit_buf)
	append(&w.edit_buf, setting_value(&g.settings, x).(^string)^)
}

@(private = "file")
finish_text_edit :: proc(commit: bool) {
	w := &g.settings_window
	x, editing := w.editing.?
	if !editing do return
	w.editing = nil
	if commit {
		set_string(setting_value(&g.settings, x).(^string), strings.trim_space(string(w.edit_buf[:])))
		settings_changed()
	}
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

// Enter on a row: flip a choice, edit text, or record a keybinding.
@(private = "file")
activate_item :: proc(item: Setting_Item) {
	switch x in item {
	case Setting:
		info := SETTINGS[x]
		switch v in setting_value(&g.settings, x) {
		case ^bool:
			v^ = !v^
		case ^int:
			return
		case ^string:
			if info.choices == nil {
				start_text_edit(x)
				return
			}
			i := 0
			for c, j in info.choices do if c == v^ do i = j
			set_string(v, info.choices[(i + 1) % len(info.choices)])
		}
		settings_changed()
	case Command:
		g.settings_window.recording = x
	}
}

// Delete on a row: put it back to its default.
@(private = "file")
reset_item :: proc(item: Setting_Item) {
	switch x in item {
	case Setting: setting_reset(&g.settings, x)
	case Command: g.settings.bindings[x] = default_bindings(x)
	}
	settings_changed()
}

@(private = "file")
confirm_reset_all :: proc() {
	if ask("Reset settings", "Reset all settings, including keybindings, to their defaults?", {"Reset all", "Cancel"}, default = 1, cancel = 1) == 0 {
		settings_reset_all(&g.settings)
		settings_changed()
	}
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

// Scrolls the list so the focused row is visible, using last frame's layout.
@(private = "file")
reveal_focus :: proc() {
	w := &g.settings_window
	if !w.reveal do return
	w.reveal = false
	if w.focus < 0 || w.focus >= len(w.items) do return
	scroll := clay.GetScrollContainerData(clay.ID("SettingsList"))
	r, row_ok := element_rect(item_row_id(w.items[w.focus]))
	l, list_ok := element_rect(clay.ID("SettingsList"))
	if !scroll.found || !row_ok || !list_ok do return
	if r.y < l.y {
		scroll.scrollPosition.y += l.y - r.y
	} else if r.y + r.h > l.y + l.h {
		scroll.scrollPosition.y -= r.y + r.h - (l.y + l.h)
	}
}

@(private = "file")
item_row_id :: proc(item: Setting_Item) -> clay.ElementId {
	switch x in item {
	case Setting: return clay.ID("SettingRow", u32(x))
	case Command: return clay.ID("BindingRow", u32(x))
	}
	return {}
}

// --- UI ------------------------------------------------------------------------------

settings_window_ui :: proc() {
	w := &g.settings_window
	if !w.open do return
	reveal_focus()
	clear(&w.items)
	panel := clay.ID("Settings")
	height := clay.SizingFixed(max(f32(g.window_h) - 96, 200))
	if modal(panel, SETTINGS_WIDTH, height, 48, {left = 20, right = 20, top = 16, bottom = 14}, 14) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			label("Settings", theme.text_bright, 16, .SemiBold)
			push_right()
			if icon_button(clay.ID("SettingsClose"), .Close, 26, 18, "Close", "Esc") do settings_window_toggle()
		}
		search_field()
		if g.settings.error != "" do error_banner(g.settings.error)
		settings_list()
		footer()
	}
	if clicked_outside(panel, w.opened_at) do settings_window_toggle()
}

@(private = "file")
search_field :: proc() {
	w := &g.settings_window
	id := clay.ID("SettingsSearch")
	if clicked(id) {
		w.focus = -1
		w.recording = nil
		finish_text_edit(commit = true)
	}
	focused := w.recording == nil && w.editing == nil && w.focus < 0
	input_box(id, string(w.search[:]), "Search settings", focused, height = 34)
}

@(private = "file")
error_banner :: proc(msg: string) {
	if clay.UI()({
		layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(10)},
		backgroundColor = theme.hover,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = theme.error, width = {left = 3}},
	}) {
		paragraph(msg)
	}
}

@(private = "file")
settings_list :: proc() {
	list := clay.ID("SettingsList")
	if clay.UI(list)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 18},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		query := strings.to_lower(string(g.settings_window.search[:]), context.temp_allocator)
		shown := 0
		for key, section in SECTION_KEYS {
			rows := make([dynamic]Setting_Item, context.temp_allocator)
			if section == .Keybindings {
				for info, cmd in COMMANDS {
					if matches(query, key, info.name, bindings_label(g.settings.bindings[cmd], " ")) do append(&rows, cmd)
				}
			} else {
				for info, x in SETTINGS {
					if info.section == section && info.name != "" && matches(query, key, info.name, info.keywords) do append(&rows, x)
				}
			}
			if len(rows) == 0 do continue
			shown += 1
			if section_header(key) {
				for item in rows {
					switch x in item {
					case Setting:
						if setting_row(x, SETTINGS[x].name, SETTINGS[x].description, list) do setting_control(x)
					case Command:
						if setting_row(x, COMMANDS[x].name, "", list) do keybinding_control(x, list)
					}
				}
			}
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

// A titled group of rows. Use as: if section_header("name") { rows }
@(private = "file", deferred_none = close_element)
section_header :: proc(title: string) -> bool {
	clay._OpenElement()
	clay.ConfigureOpenElement({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}})
	if clay.UI()({layout = {padding = {left = 4, bottom = 6}}}) {
		label(strings.to_upper(title, context.temp_allocator), theme.text_dim, FONT_SIZE_SMALL, .Bold)
	}
	return true
}

// One row: name and description on the left, its control on the right.
// Use as: if setting_row(...) { control }
@(private = "file", deferred_none = close_element)
setting_row :: proc(item: Setting_Item, name, description: string, list: clay.ElementId) -> bool {
	w := &g.settings_window
	append(&w.items, item)
	index := len(w.items) - 1
	focused := index == w.focus
	id := item_row_id(item)
	if clicked(id, list) do w.focus = index // clicking a row moves keyboard focus there
	clay._OpenElementWithId(id)
	clay.ConfigureOpenElement({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFit({min = 40})},
			padding = {left = 10, right = 6, top = 6, bottom = 6},
			childAlignment = {y = .Center},
			childGap = 12,
		},
		backgroundColor = focused || clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = focused ? theme.accent : {}, width = focused ? clay.BorderOutside(1) : {}},
	})
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = 2}}) {
		label(name, theme.text)
		if description != "" do paragraph(description, theme.text_dim)
	}
	return true
}

@(private = "file")
close_element :: proc() {
	clay._CloseElement()
}

// --- Controls -----------------------------------------------------------------------

@(private = "file")
setting_control :: proc(x: Setting) {
	info := SETTINGS[x]
	switch v in setting_value(&g.settings, x) {
	case ^bool:
		if choice, changed := segmented(x, {"Off", "On"}, int(v^)); changed {
			v^ = choice == 1
			settings_changed()
		}
	case ^int:
		if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
			if stepper_button(clay.ID("Decrease", u32(x)), "-") {
				setting_step(&g.settings, x, -1)
				settings_changed()
			}
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(36)}, childAlignment = {x = .Center}}}) {
				label(fmt.tprintf("%d", v^), theme.text_bright)
			}
			if stepper_button(clay.ID("Increase", u32(x)), "+") {
				setting_step(&g.settings, x, +1)
				settings_changed()
			}
		}
	case ^string:
		if info.choices != nil {
			names := make([]string, len(info.choices), context.temp_allocator)
			current := 0
			for c, i in info.choices {
				names[i] = strings.concatenate({strings.to_upper(c[:1], context.temp_allocator), c[1:]}, context.temp_allocator)
				if c == v^ do current = i
			}
			if choice, changed := segmented(x, names, current); changed {
				set_string(v, info.choices[choice])
				settings_changed()
			}
		} else {
			text_setting_field(x, v^)
		}
	}
}

// A row of mutually exclusive options. Returns the clicked option if it changed.
@(private = "file")
segmented :: proc(x: Setting, options: []string, selected: int) -> (choice: int, changed: bool) {
	if clay.UI()({
		layout = {padding = clay.PaddingAll(2), childGap = 2},
		backgroundColor = theme.bg,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		for option, i in options {
			id := clay.ID("SettingOption", u32(x) * 64 + u32(i))
			is_selected := i == selected
			if clay.UI(id)({
				layout = {sizing = {width = clay.SizingFixed(64), height = clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = is_selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
				cornerRadius = clay.CornerRadiusAll(4),
			}) {
				label(option, is_selected ? theme.text_bright : theme.text_dim)
			}
			if clicked(id, clay.ID("SettingsList")) && !is_selected do choice, changed = i, true
		}
	}
	return
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
	return clicked(id, clay.ID("SettingsList"))
}

// A one-line text field; click or Enter to edit. Shows the default, dimmed, when empty.
@(private = "file")
text_setting_field :: proc(x: Setting, value: string) {
	w := &g.settings_window
	id := clay.ID("SettingField")
	editing := w.editing == x
	if clicked(id, clay.ID("SettingsList")) {
		if !editing do start_text_edit(x)
	} else if editing && g.mouse_pressed && !pointer_in(id) {
		finish_text_edit(commit = true) // clicking elsewhere keeps what was typed
	}
	default := x == .Terminal_Shell ? fmt.tprintf("%s (default)", term.default_shell()) : ""
	text := editing ? string(w.edit_buf[:]) : value
	input_box(id, text, default, editing, 260, 28, 13)
	if !editing do tooltip(id, "Edit", "Enter")
}

@(private = "file")
keybinding_control :: proc(cmd: Command, list: clay.ElementId) {
	w := &g.settings_window
	recording := w.recording == cmd
	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if !recording && g.settings.bindings[cmd] != default_bindings(cmd) {
			if button(clay.ID("BindingReset", u32(cmd)), "Reset", "Reset to default", "Del") {
				reset_item(cmd)
			}
		}
		id := clay.ID("Binding", u32(cmd))
		if clay.UI(id)({
			layout = {
				sizing = {width = clay.SizingFit({min = 120}), height = clay.SizingFixed(26)},
				padding = {left = 8, right = 8},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = clay.Hovered() || recording ? theme.hover : theme.bg,
			cornerRadius = clay.CornerRadiusAll(5),
			border = {color = recording ? theme.accent : theme.border, width = clay.BorderOutside(1)},
		}) {
			bound := bindings_label(g.settings.bindings[cmd], " / ")
			switch {
			case recording:  label("Press keys…  (Esc cancels)", theme.accent, FONT_SIZE_SMALL)
			case bound == "": label("Unbound", theme.text_dim, FONT_SIZE_SMALL)
			case:            label(bound, theme.text, FONT_SIZE_SMALL)
			}
		}
		if clicked(id, list) do w.recording = recording ? nil : cmd
		if !recording do tooltip(id, "Change keybinding", "Enter")
	}
}

@(private = "file")
footer :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}, childGap = 8}}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			hint := g.settings_window.editing != nil ? "Enter save  Esc cancel" : "↑↓ select  ←→ change  Enter edit  Del reset"
			label(hint, theme.text_dim, FONT_SIZE_SMALL)
		}
		if button(clay.ID("SettingsResetAll"), "Reset all", "Reset every setting to its default") do confirm_reset_all()
		if g.settings.path != "" {
			if button(clay.ID("SettingsEditFile"), "Edit settings.toml", g.settings.path) {
				g.pending = Open_File(strings.clone(g.settings.path))
				settings_window_toggle()
			}
		}
	}
}
