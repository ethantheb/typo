package editor

import "core:fmt"
import "core:strings"

import clay "../vendor/clay-odin"
import "syntax"
import "term"
import sdl "../vendor/sdl3"

// The settings window: a modal with a search field, then the settings grouped
// into sections. Every change is applied immediately and written to
// settings.toml.
//
// A setting chosen from a list (theme, font) opens the list in the same panel,
// which moves to the right edge so the editor shows (a Clay transition) while
// the list fades in. Each option is applied as the selection moves onto it;
// Enter keeps it and closes the window, Esc puts the old value back and returns
// to the settings.

SETTINGS_WIDTH :: 640
PICKER_WIDTH :: 320
PICKER_MARGIN :: 12
PICKER_ROW_HEIGHT :: 32

Settings_Window :: struct {
	open:          bool,
	opened_at:     u64, // frame it was opened on
	search:        [dynamic]u8,
	recording:     Maybe(Command), // waiting for a key press to bind

	// Keyboard focus: an index into `items`, or -1 for the search field.
	// `items` lists the rows shown last frame, in order.
	focus:         int,
	items:         [dynamic]Setting_Item,
	reveal:        bool, // scroll the focused row into view

	editing:       Maybe(Setting), // text setting being typed into
	edit_buf:      [dynamic]u8,

	// The option list of a picker setting, and the settings shown below it.
	picking:         bool,
	picker:          Setting,        // the list shown
	original:        string,         // its value when the list opened, restored on cancel
	original_extras: [Setting]f64,   // likewise for picker_extras
	filter:          [dynamic]u8,
	picker_reveal:   bool,           // scroll the current option into view
	extra_focus:     int,            // keyboard focus: -1 = the list, else an index into picker_extras
	scrollbar_drag:  Maybe(f32),     // of the list shown (see list_scrollbar)
	dark_themes:     bool,           // the theme list shows dark themes, else light ones
}

// A row in the settings list.
Setting_Item :: union {
	Setting,
	Command,
}

// Settings adjusted in a picker's panel along with its list, shown below it, so
// the editor can be watched while changing them.
FONT_EXTRAS := [?]Setting{.Font_Size, .Font_Weight, .Line_Height, .Letter_Spacing}
MARKDOWN_FONT_EXTRAS := [?]Setting{.Markdown_Font_Size, .Markdown_Line_Height, .Markdown_Max_Width}

// An entry in a picker's list.
Picker_Option :: struct {
	value:    string, // stored in the setting
	label:    string,
	keywords: string, // extra filter terms
}

settings_window_toggle :: proc() {
	w := &g.settings_window
	if w.picking do close_picker(commit = false)
	w.open = !w.open
	w.opened_at = g.frame
	w.recording = nil
	w.editing = nil
	w.focus = -1
	clear(&w.search)
	if w.open do g.finder.open = false
}

settings_window_destroy :: proc() {
	w := &g.settings_window
	delete(w.search)
	delete(w.items)
	delete(w.edit_buf)
	delete(w.filter)
	delete(w.original)
}

// Whether the pointer is over a text field (for the I-beam cursor).
settings_window_over_text :: proc() -> bool {
	return pointer_in(clay.ID("SettingsSearch")) || pointer_in(clay.ID("SettingField")) || pointer_in(clay.ID("PickerFilter"))
}

// Returns true if the event was consumed by the settings window.
settings_window_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window
	if !w.open do return false
	if w.picking do return picker_handle_event(event)

	if _, editing := w.editing.?; editing {
		if event.type == .KEY_DOWN {
			if cmd, ok := command_for_key(event.key); ok && cmd == .Find {
				finish_text_edit(commit = true)
				w.focus = -1
				return true
			}
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
	case sdl.K_PAGEDOWN:
		page_focus(+1)
	case sdl.K_PAGEUP:
		page_focus(-1)
	case sdl.K_TAB:
		move_focus(key.mod & sdl.KMOD_SHIFT != {} ? -1 : +1, wrap = true)
	case sdl.K_LEFT, sdl.K_RIGHT:
		// A picker setting is only changed in its list (Enter).
		if x, ok := focused.(Setting); ok && !SETTINGS[x].picker {
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
		// Find goes to the search field. Let the "open settings" shortcut close
		// the window; swallow the rest.
		if cmd, ok := command_for_key(key); ok {
			#partial switch cmd {
			case .Find:          w.focus = -1
			case .Open_Settings: return false
			}
		}
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

// Page Up/Down: moves focus to the row about one list height away (rows differ
// in height), using last frame's layout.
@(private = "file")
page_focus :: proc(dir: int) {
	w := &g.settings_window
	l, ok := element_rect(clay.ID("SettingsList"))
	if !ok || len(w.items) == 0 do return
	from := clamp(w.focus, 0, len(w.items) - 1)
	r, _ := element_rect(item_row_id(w.items[from]))
	target := r.y + f32(dir) * l.h
	best, best_d := from, max(f32)
	for item, i in w.items {
		ir, found := element_rect(item_row_id(item))
		if d := abs(ir.y - target); found && d < best_d do best, best_d = i, d
	}
	w.focus, w.reveal = best, true
}

// Enter on a row: flip a choice, edit text, open a list, or record a keybinding.
@(private = "file")
activate_item :: proc(item: Setting_Item) {
	switch x in item {
	case Setting:
		info := SETTINGS[x]
		switch v in setting_value(&g.settings, x) {
		case ^bool:
			v^ = !v^
		case ^int, ^f64:
			return
		case ^string:
			if info.picker {
				open_picker(x)
				return
			}
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

// Scrolls a list so a row in it is visible, using last frame's layout. Returns
// true if the row was already in view.
@(private = "file")
scroll_into_view :: proc(list, row: clay.ElementId) -> bool {
	scroll := clay.GetScrollContainerData(list)
	r, row_ok := element_rect(row)
	l, list_ok := element_rect(list)
	if !scroll.found || !row_ok || !list_ok do return false
	if r.y < l.y {
		scroll.scrollPosition.y += l.y - r.y
	} else if r.y + r.h > l.y + l.h {
		scroll.scrollPosition.y -= r.y + r.h - (l.y + l.h)
	} else {
		return true
	}
	return false
}

@(private = "file")
reveal_focus :: proc() {
	w := &g.settings_window
	if !w.reveal do return
	w.reveal = false
	if w.focus < 0 || w.focus >= len(w.items) do return
	scroll_into_view(clay.ID("SettingsList"), item_row_id(w.items[w.focus]))
}

@(private = "file")
item_row_id :: proc(item: Setting_Item) -> clay.ElementId {
	switch x in item {
	case Setting: return clay.ID("SettingRow", u32(x))
	case Command: return clay.ID("BindingRow", u32(x))
	}
	return {}
}

// --- Picker ------------------------------------------------------------------------

@(private = "file")
open_picker :: proc(x: Setting) {
	w := &g.settings_window
	finish_text_edit(commit = true)
	w.recording = nil
	w.picking, w.picker = true, x
	set_string(&w.original, current_value(x))
	for e in picker_extras(x) do w.original_extras[e] = number_value(e)
	clear(&w.filter)
	w.picker_reveal = true
	w.extra_focus = -1
	if i, ok := theme_index(g.settings.theme); ok do w.dark_themes = THEMES[i].dark
	if x == .Font_Family || x == .Markdown_Font do fonts_scan(&g.fonts, again = true)
}

// Leaves the list, keeping what is now applied or restoring the old values.
@(private = "file")
close_picker :: proc(commit: bool) {
	w := &g.settings_window
	if !w.picking do return
	w.picking = false
	if commit {
		settings_changed()
	} else {
		set_string(setting_value(&g.settings, w.picker).(^string), w.original)
		for e in picker_extras(w.picker) do set_number_value(e, w.original_extras[e])
		apply_settings()
	}
}

@(private = "file")
picker_extras :: proc(x: Setting) -> []Setting {
	#partial switch x {
	case .Font_Family:   return FONT_EXTRAS[:]
	case .Markdown_Font: return MARKDOWN_FONT_EXTRAS[:]
	}
	return nil
}

// A number setting's value, as f64 whether it is an int or not.
@(private = "file")
number_value :: proc(x: Setting) -> f64 {
	#partial switch v in setting_value(&g.settings, x) {
	case ^int: return f64(v^)
	case ^f64: return v^
	}
	return 0
}

@(private = "file")
set_number_value :: proc(x: Setting, n: f64) {
	#partial switch v in setting_value(&g.settings, x) {
	case ^int: v^ = int(n)
	case ^f64: v^ = n
	}
}

// Steps one of the picker's extra settings, applied without saving.
@(private = "file")
step_extra :: proc(x: Setting, dir: int) {
	setting_step(&g.settings, x, dir)
	apply_settings()
}

// Switches the theme list between dark and light, applying the current family's
// theme of that kind (or the first one).
@(private = "file")
show_dark_themes :: proc(dark: bool) {
	w := &g.settings_window
	if w.dark_themes == dark do return
	w.dark_themes = dark
	i, _ := theme_index(g.settings.theme)
	next := -1
	for spec, j in THEMES {
		if spec.dark != dark do continue
		if next < 0 || spec.family == THEMES[i].family do next = j
		if spec.family == THEMES[i].family do break
	}
	clear(&w.filter)
	preview_option(THEMES[next].key)
	w.picker_reveal = true
}

@(private = "file")
picker_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window
	if _, changed := text_field_event(&w.filter, event); changed {
		// Keep the current option while it still matches, else show the first match.
		options := picker_options(w.picker, string(w.filter[:]))
		if len(options) > 0 && option_index(options, current_value(w.picker)) < 0 do preview_option(options[0].value)
		w.picker_reveal = true
		w.extra_focus = -1 // typing goes back to the list
		return true
	}
	if event.type != .KEY_DOWN do return event.type == .TEXT_INPUT
	key := event.key
	extras := picker_extras(w.picker)
	switch key.key {
	case sdl.K_ESCAPE:
		close_picker(commit = false)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		close_picker(commit = true)
		settings_window_toggle()
	case sdl.K_TAB:
		// Cycle the list -> each extra setting -> the list.
		n := len(extras) + 1
		dir := key.mod & sdl.KMOD_SHIFT != {} ? -1 : +1
		w.extra_focus = (w.extra_focus + 1 + dir + n) % n - 1
	case sdl.K_UP, sdl.K_DOWN:
		dir := key.key == sdl.K_UP ? -1 : +1
		if w.extra_focus >= 0 {
			w.extra_focus = clamp(w.extra_focus + dir, -1, len(extras) - 1)
		} else {
			move_option(dir)
		}
	case sdl.K_LEFT, sdl.K_RIGHT:
		dir := key.key == sdl.K_LEFT ? -1 : +1
		if w.extra_focus >= 0 && w.extra_focus < len(extras) {
			step_extra(extras[w.extra_focus], dir)
		} else if w.picker == .Theme {
			show_dark_themes(dir < 0)
		}
	case sdl.K_PAGEUP:
		move_option(-picker_page_rows())
	case sdl.K_PAGEDOWN:
		move_option(+picker_page_rows())
	case:
		// Find goes to the filter field. The "open settings" shortcut closes the
		// window, cancelling the list.
		if cmd, ok := command_for_key(key); ok {
			#partial switch cmd {
			case .Find:          w.extra_focus = -1
			case .Open_Settings: return false
			}
		}
	}
	return true
}

// The options of a picker setting that match `filter`.
@(private = "file")
picker_options :: proc(x: Setting, filter: string) -> []Picker_Option {
	all := make([dynamic]Picker_Option, context.temp_allocator)
	#partial switch x {
	case .Theme:
		// Dark and light themes are listed apart, so moving through the list
		// doesn't flash between them.
		for spec in THEMES do if spec.dark == g.settings_window.dark_themes do append(&all, Picker_Option{spec.key, spec.name, ""})
	case .Font_Family:
		for name in font_family_names(&g.fonts) do append(&all, Picker_Option{name, name, ""})
	case .Markdown_Font:
		for name in markdown_family_names(&g.fonts) do append(&all, Picker_Option{name, name, ""})
	}
	if filter == "" do return all[:]
	query := strings.to_lower(filter, context.temp_allocator)
	shown := make([dynamic]Picker_Option, context.temp_allocator)
	for o in all do if matches(query, o.label, o.keywords) do append(&shown, o)
	return shown[:]
}

@(private = "file")
current_value :: proc(x: Setting) -> string {
	return setting_value(&g.settings, x).(^string)^
}

@(private = "file")
option_index :: proc(options: []Picker_Option, value: string) -> int {
	for o, i in options do if o.value == value do return i
	return -1
}

// Applies an option without saving it.
@(private = "file")
preview_option :: proc(value: string) {
	set_string(setting_value(&g.settings, g.settings_window.picker).(^string), value)
	apply_settings()
}

// How many options Page Up/Down moves: one fewer than fit in the list.
@(private = "file")
picker_page_rows :: proc() -> int {
	l, ok := element_rect(clay.ID("PickerList"))
	if !ok do return 1
	return max(int(l.h / (PICKER_ROW_HEIGHT + 2)) - 1, 1)
}

@(private = "file")
move_option :: proc(dir: int) {
	w := &g.settings_window
	options := picker_options(w.picker, string(w.filter[:]))
	if len(options) == 0 do return
	i := option_index(options, current_value(w.picker))
	next := i < 0 ? (dir > 0 ? 0 : len(options) - 1) : clamp(i + dir, 0, len(options) - 1)
	preview_option(options[next].value)
	w.picker_reveal = true
}

// --- UI ------------------------------------------------------------------------------

settings_window_ui :: proc() {
	w := &g.settings_window
	if !w.open do return
	r := w.picking ? picker_rect() : settings_rect()
	backdrop := theme.backdrop
	if w.picking do backdrop.a = 0 // leave the editor undimmed for previewing
	// The panel moves and resizes to the new page, which fades in; it clips the
	// page until it has arrived.
	// The list leaves the rest of the window usable: files can be opened and the
	// editor scrolled to see the change on other text (see ui_interactive).
	panel := clay.ID("Settings")
	if modal_at(panel, r, backdrop, clip = !element_at(panel, r), modal = !w.picking) {
		if w.picking do picker_page(r.w)
		else do settings_page(r.w)
	}
	if !w.picking && clicked_outside(panel, w.opened_at) do settings_window_toggle()
}

// The settings window is showing an option list at the side, not covering the window.
settings_window_docked :: proc() -> bool {
	return g.settings_window.open && g.settings_window.picking
}

@(private = "file")
settings_rect :: proc() -> Rect {
	w := min(SETTINGS_WIDTH, f32(g.window_w) - 32)
	return {(f32(g.window_w) - w) / 2, 48, w, max(f32(g.window_h) - 96, 200)}
}

// At the right edge, above the status bar.
@(private = "file")
picker_rect :: proc() -> Rect {
	w := min(PICKER_WIDTH, f32(g.window_w) - 2 * PICKER_MARGIN)
	h := max(f32(g.window_h) - STATUSBAR_HEIGHT - 2 * PICKER_MARGIN, 200)
	return {f32(g.window_w) - w - PICKER_MARGIN, PICKER_MARGIN, w, h}
}

@(private = "file")
settings_page :: proc(width: f32) {
	w := &g.settings_window
	reveal_focus()
	clear(&w.items)
	if clay.UI(clay.ID("SettingsPage"))({
		backgroundColor = theme.panel,
		overlayColor = clear_overlay(theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		transition = transition({.OverlayColor}, enter = .Fade),
		layout = {
			sizing = {clay.SizingFixed(width), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 20, right = 20, top = 16, bottom = 14},
			childGap = 14,
		},
	}) {
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
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {right = SCROLLBAR_GUTTER}, childGap = 18},
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
	list_scrollbar(list, &g.settings_window.scrollbar_drag)
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
		if choice, changed := segmented(x, {"Off", "On"}, int(v^), clay.ID("SettingsList")); changed {
			v^ = choice == 1
			settings_changed()
		}
	case ^int, ^f64:
		if dir := stepper(x, clay.ID("SettingsList")); dir != 0 {
			setting_step(&g.settings, x, dir)
			settings_changed()
		}
	case ^string:
		if info.picker {
			picker_button(x, v^)
		} else if info.choices != nil {
			names := make([]string, len(info.choices), context.temp_allocator)
			current := 0
			for c, i in info.choices {
				names[i] = strings.concatenate({strings.to_upper(c[:1], context.temp_allocator), c[1:]}, context.temp_allocator)
				if c == v^ do current = i
			}
			if choice, changed := segmented(x, names, current, clay.ID("SettingsList")); changed {
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
segmented :: proc(x: Setting, options: []string, selected: int, within := clay.ElementId{}) -> (choice: int, changed: bool) {
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
				layout = {sizing = {width = clay.SizingFit({min = 64}), height = clay.SizingFixed(26)}, padding = {left = 10, right = 10}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = is_selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
				cornerRadius = clay.CornerRadiusAll(4),
			}) {
				label(option, is_selected ? theme.text_bright : theme.text_dim)
			}
			if clicked(id, within) && !is_selected do choice, changed = i, true
		}
	}
	return
}

// "-" value "+" for a number setting. Returns the direction clicked, or 0.
// `within` is the scroll area it sits in, if any.
@(private = "file")
stepper :: proc(x: Setting, within: clay.ElementId) -> (dir: int) {
	value: string
	#partial switch v in setting_value(&g.settings, x) {
	case ^int: value = fmt.tprintf("%d", v^)
	case ^f64: value = format_decimal(v^)
	}
	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if stepper_button(clay.ID("Decrease", u32(x)), "-", within) do dir = -1
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(44)}, childAlignment = {x = .Center}}}) {
			label(value, theme.text_bright)
		}
		if stepper_button(clay.ID("Increase", u32(x)), "+", within) do dir = +1
	}
	return
}

@(private = "file")
stepper_button :: proc(id: clay.ElementId, text: string, within: clay.ElementId) -> bool {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(28), clay.SizingFixed(26)}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = clay.Hovered() ? theme.hover : theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		label(text, theme.text)
	}
	return clicked(id, within)
}

// Shows a picker setting's value; click or Enter to open its list.
@(private = "file")
picker_button :: proc(x: Setting, value: string) {
	id := clay.ID("PickerButton", u32(x))
	text := value
	missing := false
	#partial switch x {
	case .Theme:
		if i, ok := theme_index(value); ok do text = THEMES[i].name
	case .Font_Family, .Markdown_Font:
		missing = font_family_missing(&g.fonts, value)
	}
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(220), clay.SizingFixed(28)},
			padding = {left = 10, right = 6},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() ? theme.hover : theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			label(text, missing ? theme.error : theme.text_bright, 13)
		}
		icon(.Chevron_Right, theme.text_dim, 15)
	}
	if clicked(id, clay.ID("SettingsList")) do open_picker(x)
	tooltip(id, missing ? (x == .Markdown_Font ? "Not installed; showing " + BUNDLED_MD_FAMILY : "Not installed; showing " + BUNDLED_FAMILY) : "Choose", "Enter")
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

// The keys that do something on the focused row.
@(private = "file")
footer_hint :: proc() -> string {
	w := &g.settings_window
	if w.editing != nil do return "Enter save  Esc cancel"
	if w.focus < 0 || w.focus >= len(w.items) do return "↑↓ select  Enter first result"
	switch x in w.items[w.focus] {
	case Command:
		return "↑↓ select  Enter rebind  Del reset"
	case Setting:
		info := SETTINGS[x]
		switch _ in setting_value(&g.settings, x) {
		case ^string:
			if info.picker do return "↑↓ select  Enter choose  Del reset"
			if info.choices == nil do return "↑↓ select  Enter edit  Del reset"
		case ^bool, ^int, ^f64:
		}
	}
	return "↑↓ select  ←→ change  Del reset"
}

@(private = "file")
footer :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}, childGap = 8}}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			label(footer_hint(), theme.text_dim, FONT_SIZE_SMALL)
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

// --- Picker page ---------------------------------------------------------------------

@(private = "file")
picker_page :: proc(width: f32) {
	w := &g.settings_window
	x := w.picker
	options := picker_options(x, string(w.filter[:]))
	current := current_value(x)
	list := clay.ID("PickerList")
	if w.picker_reveal {
		// Done once the row is in view; the list may not be laid out yet.
		if i := option_index(options, current); i < 0 || scroll_into_view(list, clay.ID("PickerRow", u32(i))) {
			w.picker_reveal = false
		}
	}

	if clay.UI(clay.ID("PickerPage"))({
		backgroundColor = theme.panel,
		overlayColor = clear_overlay(theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		transition = transition({.OverlayColor}, enter = .Fade),
		layout = {
			sizing = {clay.SizingFixed(width), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = 12, right = 12, top = 12, bottom = 10},
			childGap = 10,
		},
	}) {
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}, childGap = 4}}) {
			if icon_button(clay.ID("PickerBack"), .Chevron_Left, 26, 18, "Back to settings", "Esc") do close_picker(commit = false)
			label(SETTINGS[x].name, theme.text_bright, 16, .SemiBold)
		}
		if x == .Theme {
			if choice, changed := segmented(.Theme, {"Dark", "Light"}, w.dark_themes ? 0 : 1); changed do show_dark_themes(choice == 0)
		}
		input_box(clay.ID("PickerFilter"), string(w.filter[:]), x == .Theme ? "Filter themes" : "Filter fonts", true)
		if clay.UI(list)({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {right = SCROLLBAR_GUTTER}, childGap = 2},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for o, i in options do option_row(x, o, i, o.value == current, list)
			note := ""
			switch {
			case (x == .Font_Family || x == .Markdown_Font) && !g.fonts.scanned: note = "Looking for installed fonts…"
			case len(options) == 0:                              note = "No matches"
			}
			if note != "" {
				if clay.UI()({layout = {padding = {left = 8, top = 8}}}) {
					label(note, theme.text_dim, FONT_SIZE_SMALL)
				}
			}
		}
		list_scrollbar(list, &w.scrollbar_drag)
		extras := picker_extras(x)
		if len(extras) > 0 {
			if clay.UI()({
				layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {top = 8}, childGap = 2},
				border = {color = theme.border, width = {top = 1}},
			}) {
				for e, i in extras do extra_row(e, i)
			}
		}
		hint: string
		switch {
		case w.extra_focus >= 0: hint = "←→ adjust  ↑↓ row  Enter apply"
		case len(extras) > 0:    hint = "↑↓ font  Tab size  Enter apply  Esc back"
		case x == .Theme:        hint = "↑↓ preview  ←→ dark/light  Enter apply"
		case:                    hint = "↑↓ preview  Enter apply  Esc back"
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			label(hint, theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}

// One of the settings below a picker's list: its name and a stepper.
@(private = "file")
extra_row :: proc(x: Setting, index: int) {
	w := &g.settings_window
	id := clay.ID("PickerExtra", u32(x))
	focused := w.extra_focus == index
	if clicked(id) do w.extra_focus = index
	if clay.UI(id)({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(34)},
			padding = {left = 8, right = 4},
			childAlignment = {y = .Center},
		},
		backgroundColor = focused || clay.Hovered() ? theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = focused ? theme.accent : {}, width = focused ? clay.BorderOutside(1) : {}},
	}) {
		label(SETTINGS[x].name, theme.text)
		push_right()
		if dir := stepper(x, {}); dir != 0 do step_extra(x, dir)
	}
}

// One option. A click applies it; a second click on the applied one keeps it
// and closes the window, like Enter.
@(private = "file")
option_row :: proc(x: Setting, o: Picker_Option, index: int, selected: bool, list: clay.ElementId) {
	id := clay.ID("PickerRow", u32(index))
	if clicked(id, list) {
		if selected && g.mouse_clicks >= 2 {
			close_picker(commit = true)
			settings_window_toggle()
		} else {
			preview_option(o.value)
		}
	}
	if clay.UI(id)({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(PICKER_ROW_HEIGHT)},
			padding = {left = 8, right = 8},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = selected ? theme.accent : {}, width = selected ? clay.BorderOutside(1) : {}},
	}) {
		if x == .Theme {
			if i, ok := theme_index(o.value); ok do theme_swatch(THEMES[i])
		}
		label(o.label, selected ? theme.text_bright : theme.text)
		if (x == .Font_Family && o.value == BUNDLED_FAMILY) || (x == .Markdown_Font && (o.value == BUNDLED_MD_FAMILY || o.value == BUNDLED_FAMILY)) {
			push_right()
			label("bundled", theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}

// A small sample of a theme: its background with a few of its syntax colors.
@(private = "file")
theme_swatch :: proc(spec: Theme_Spec) {
	SAMPLE :: [?]syntax.Highlight{.Keyword, .String, .Function, .Type}
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(44), clay.SizingFixed(20)}, padding = {left = 6, right = 6}, childGap = 3, childAlignment = {y = .Center}},
		backgroundColor = rgb(spec.bg),
		cornerRadius = clay.CornerRadiusAll(4),
		border = {color = theme.border, width = clay.BorderOutside(1)},
	}) {
		for h in SAMPLE {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(5), clay.SizingFixed(10)}}, backgroundColor = rgb(spec.syntax[h]), cornerRadius = clay.CornerRadiusAll(1)}) {}
		}
	}
}
