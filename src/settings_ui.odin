package editor

import "core:fmt"
import "core:math"
import "core:strings"

import clay "../vendor/clay-odin"
import "syntax"
import "term"
import sdl "../vendor/sdl3"
import "gfx"
import "langs"

// The settings window: a modal with a search field, then the settings grouped
// into sections, which collapse (kept in collapsed_sections). Every change is
// applied immediately and written to settings.toml.
//
// A switch by the title shows the user's settings or the project's (scope).
// In Project scope a change is written to the project's .typo/settings.toml,
// a setting it doesn't set shows the user's value it follows, Delete makes a
// set one follow the user's again, and what is the user's only (keybindings,
// language servers, user_only settings) isn't listed. In User scope a
// setting the project sets says so.
//
// A setting chosen from a list (theme, font) opens the list in the same panel,
// which moves to the right edge so the editor shows (a Clay transition) while
// the list fades in. Each option is applied as the selection moves onto it;
// Enter keeps it and closes the window, Esc puts the old value back and returns
// to the settings


SETTINGS_WIDTH    :: 640
PICKER_WIDTH      :: 320
PICKER_MARGIN     :: 12
PICKER_ROW_HEIGHT :: 32

Settings_Window :: struct {
	open:            bool,
	opened_at:       u64, // frame it was opened on
	scope:           Settings_Scope, // the settings shown and changed
	search:          Line_Edit,

	// Keybindings: each binding is a chip. A focused keybinding row's chips
	// take the focus with ←→ (the row itself is chip -1)
	recording:       Maybe(Command), // waiting for a key press to add as a binding
	chip:            int,            // the focused row's focused chip, or -1
	chip_command:    Command,        // the row `chip` is in
	bind_note:       string,         // owned; what the last binding added did, or ""
	bind_note_for:   Command,        // the row it shows under

	// Keyboard focus: an index into `items`, or -1 for the search field.
	// `items` lists the rows shown last frame, in order
	focus:           int,
	items:           [dynamic]Setting_Item,
	reveal:          bool, // scroll the focused row (or server field) into view
	refocus:         Maybe(Setting_Item), // focused once listed (rows above it may come or go)
	collapse_to:     Maybe(bit_set[Section]), // clicked; applied before the next frame's rows

	editing:         Maybe(Setting), // text setting being typed into
	edit:            Line_Edit, // the text setting or server field being typed into

	// The option list of a picker setting, and the settings shown below it
	picking:         bool,
	picker:          Setting,      // the list shown
	original:        string,       // its value when the list opened, restored on cancel
	original_extras: [Setting]f64, // likewise for picker_extras
	original_set:    bit_set[Setting], // the settings the project set then
	filter:          Line_Edit,
	picker_reveal:   bool,         // scroll the current option into view
	extra_focus:     int,          // keyboard focus: -1 = the list, else a picker_extras index
	scrollbar_drag:  Maybe(f32),   // of the list shown (see list_scrollbar)
	dark_themes:     bool,         // the theme list shows dark themes, else light ones
	picker_click:    Picker_Click, // applied before the next frame's layout

	// A language server's page, shown in place of the list (settings_servers.odin)
	server_page:     string, // owned; the server's name, or ""
	server_focus:    langs.Server_Field,
	server_editing:  Maybe(langs.Server_Field), // being typed into, in edit
	server_ops:      [dynamic]Server_Op,  // applied next frame
}

// A click in a picker's page. It is applied at the start of the next frame
// (settings_window_frame): applying an option replaces a settings string and
// may reopen fonts, which this frame's layout and drawing still use
Picker_Click :: union {
	Picker_Option_Click, // an option: apply it, or keep it if it was applied
	Picker_Themes,       // the dark or light themes
	Picker_Back,         // back to the settings, the value restored
}

Picker_Option_Click :: struct {
	value: string, // owned
	keep:  bool,   // a second click on the applied option: keep it and close
}

Picker_Themes :: struct {
	dark: bool,
}

Picker_Back :: struct {}

// A row in the settings list
Setting_Item :: union {
	Setting,
	Command,
	Server_Item,
	Add_Server_Item,
	Section, // its header, which collapses it
}

// Settings adjusted in a picker's panel along with its list, shown below it, so
// the editor can be watched while changing them
FONT_EXTRAS := [?]Setting{.Font_Size, .Font_Weight, .Line_Height, .Letter_Spacing}
MARKDOWN_FONT_EXTRAS := [?]Setting {
	.Markdown_Font_Size,
	.Markdown_Line_Height,
	.Markdown_Max_Width,
}

// An entry in a picker's list
Picker_Option :: struct {
	value:    string, // stored in the setting
	label:    string,
	keywords: string, // extra filter terms
}

// What a picker button's tooltip says when the chosen font isn't installed
@(private = "file")
MISSING_FONT_TIP :: "Not installed; showing " + gfx.BUNDLED_FAMILY
@(private = "file")
MISSING_SANS_FONT_TIP :: "Not installed; showing " + gfx.BUNDLED_MD_FAMILY

// segmented's ids for the scope switch: past the settings', before the servers'
@(private = "file")
SCOPE_SWITCH_ID :: 4000


// The element id of a side of the scope switch
scope_switch_side :: proc(scope: Settings_Scope) -> clay.ElementId {
	return clay.ID("SettingOption", SCOPE_SWITCH_ID * 64 + u32(scope))
}


// --- Scope -------------------------------------------------------------------------

// The values the window shows for a setting: the scope's, or the user's for
// one the project doesn't set (it follows them)
@(private = "file")
shown_values :: proc(x: Setting) -> ^Setting_Values {
	s := &g.settings
	if g.settings_window.scope == .Project && x in s.project.set {
		return &s.project.values
	}
	return &s.user
}


// The values a change to a setting goes to: the user's, or the project's,
// which then sets it, starting from the value it followed. Called only for a
// change
@(private = "file")
edit_values :: proc(x: Setting) -> ^Setting_Values {
	s := &g.settings
	if g.settings_window.scope == .User do return &s.user

	if x not_in s.project.set {
		setting_copy(&s.project.values, &s.user, x)
		s.project.set += {x}
	}
	return &s.project.values
}


// A change made in the window: the values in effect are worked out again, the
// scope's file saved, and the change applied
@(private = "file")
scope_changed :: proc() {
	if g.settings_window.scope == .Project {
		project_settings_changed()
	} else {
		settings_changed()
	}
}


// A change shown but not saved yet (a picker's preview)
@(private = "file")
scope_previewed :: proc() {
	settings_resolve(&g.settings)
	apply_settings()
}


// Shows the user's settings or the project's
@(private = "file")
set_scope :: proc(scope: Settings_Scope) {
	w := &g.settings_window
	if w.scope == scope do return

	finish_text_edit(commit = true)
	w.scope = scope
	w.recording = nil
	w.focus = -1
	w.refocus = nil
	set_string(&w.bind_note, "")
}


// Whether a row is listed in the scope shown
@(private = "file")
in_scope :: proc(x: Setting) -> bool {
	return g.settings_window.scope == .User || !SETTINGS[x].user_only
}


// The line under a setting's name, and its color, that says how the layers
// stand where the project sets a value: in Project scope, the user's value it
// replaces (in the accent); in User scope, the project's in its place. A
// setting it doesn't set has none
@(private = "file")
scope_note :: proc(x: Setting) -> (note: string, color: clay.Color) {
	s := &g.settings
	if x not_in s.project.set do return "", {}

	switch g.settings_window.scope {
	case .Project:
		yours := setting_display(&s.user, x)
		return fmt.tprintf("Set for this project · yours is %s", yours), gfx.theme.accent

	case .User:
		theirs := setting_display(&s.project.values, x)
		return fmt.tprintf("This project uses %s", theirs), gfx.theme.text_dim
	}
	return "", {}
}


// A setting's value as the window says it in a sentence (temp)
@(private = "file")
setting_display :: proc(s: ^Setting_Values, x: Setting) -> string {
	switch v in setting_value(s, x) {
	case ^bool:
		return v^ ? "On" : "Off"
	case ^int:
		return fmt.tprintf("%d", v^)
	case ^f64:
		return format_decimal(v^)
	case ^string:
		i, is_theme := gfx.theme_index(v^)
		if x == .Theme && is_theme {
			return gfx.THEMES[i].name
		}
		if v^ == "" do return "the default"
		return v^
	}
	return ""
}


settings_window_toggle :: proc() {
	w := &g.settings_window
	if w.picking do close_picker(commit = false)
	if w.server_page != "" do close_server_page()

	w.open = !w.open
	w.opened_at = g.frame
	w.recording = nil
	w.chip = -1
	set_string(&w.bind_note, "")
	w.editing = nil
	w.focus = -1
	w.refocus = nil
	w.collapse_to = nil
	line_edit_clear(&w.search)

	if w.open {
		g.finder.open = false
		langs.recheck_programs() // servers and installers may have been installed since
		persist_look_again()
	}
}


settings_window_destroy :: proc() {
	w := &g.settings_window
	line_edit_destroy(&w.search)
	delete(w.items)
	line_edit_destroy(&w.edit)
	line_edit_destroy(&w.filter)
	delete(w.original)
	delete(w.bind_note)
	delete(w.server_page)
	for op in w.server_ops {
		delete(op.name)
		delete(op.value)
	}
	delete(w.server_ops)
}


// Returns true if the event was consumed by the settings window
settings_window_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window
	if !w.open do return false
	if w.picking do return picker_handle_event(event)
	if w.server_page != "" do return server_page_handle_event(event)

	// Typing into a text setting
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

		line_edit_event(&w.edit, event)
		return true
	}

	// Waiting for a keybinding
	if w.recording != nil {
		if event.type == .KEY_DOWN {
			switch {
			case event.key.key == sdl.K_ESCAPE:
				w.recording = nil
			case is_modifier_key(event.key.key):
				// Wait for the actual key
			case:
				settings_window_record(chord_from_event(event.key))
			}
		}
		return true
	}

	// Backspace on a focused binding removes it
	backspace := event.type == .KEY_DOWN && event.key.key == sdl.K_BACKSPACE
	if backspace {
		if cmd, i, on_chip := focused_chip(); on_chip {
			remove_binding(cmd, i)
			return true
		}
	}

	// The search field has the keys while no row is focused. Typing or
	// Backspace on a row goes back to it
	if event.type == .TEXT_INPUT || backspace {
		w.focus = -1
	}
	if w.focus < 0 {
		handled, _ := line_edit_event(&w.search, event)
		if handled do return true
	}
	if event.type != .KEY_DOWN do return event.type == .TEXT_INPUT

	// Keys on the focused row
	key := event.key
	focused: Setting_Item
	if w.focus >= 0 && w.focus < len(w.items) {
		focused = w.items[w.focus]
	}

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
		// A picker setting is only changed in its list (Enter)
		dir := key.key == sdl.K_LEFT ? -1 : +1
		#partial switch x in focused {
		case Setting:
			if !SETTINGS[x].picker {
				setting_step(edit_values(x), x, dir)
				scope_changed()
			}
		case Server_Item:
			server_item_step(x, dir)
		case Section:
			set_collapsed(x, dir < 0)
		case Command:
			move_chip(x, dir)
		}

	case sdl.K_RETURN, sdl.K_KP_ENTER:
		if focused == nil && len(w.items) > 0 {
			// Enter in the search field jumps to the first result
			w.focus = 0
			w.reveal = true
		} else if focused != nil {
			activate_item(focused)
		}

	case sdl.K_DELETE:
		if cmd, i, on_chip := focused_chip(); on_chip {
			remove_binding(cmd, i)
		} else if focused != nil {
			reset_item(focused)
		}

	case:
		// Find goes to the search field. Let the "open settings" shortcut close
		// the window; swallow the rest
		if cmd, ok := command_for_key(key); ok {
			#partial switch cmd {
			case .Find:
				w.focus = -1
				line_edit_select_all(&w.search)
			case .Open_Settings:
				return false
			}
		}
	}
	return true
}


// Starts typing into a text setting, with the caret at the end
@(private = "file")
start_text_edit :: proc(x: Setting) {
	w := &g.settings_window
	w.editing = x

	value := setting_value(shown_values(x), x).(^string)^
	line_edit_set(&w.edit, value, len(value), len(value))
}


@(private = "file")
finish_text_edit :: proc(commit: bool) {
	w := &g.settings_window
	x, editing := w.editing.?
	if !editing do return

	w.editing = nil
	if !commit do return

	value := strings.trim_space(line_edit_string(&w.edit))
	if value != setting_value(shown_values(x), x).(^string)^ {
		set_string(setting_value(edit_values(x), x).(^string), value)
		scope_changed()
	}
}


// Moves keyboard focus through the rows; -1 is the search field
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
		// Cycle search field -> rows -> search field
		next = (next + 1 + (n + 1)) % (n + 1) - 1
	} else {
		next = clamp(next, -1, n - 1)
	}

	w.focus = next
	w.reveal = true
}


// Page Up/Down: moves focus to the row about one list height away (rows differ
// in height), using last frame's layout
@(private = "file")
page_focus :: proc(dir: int) {
	w := &g.settings_window
	l, ok := element_rect(clay.ID("SettingsList"))
	if !ok || len(w.items) == 0 {
		return
	}

	from := clamp(w.focus, 0, len(w.items) - 1)
	r, _ := element_rect(item_row_id(w.items[from]))
	target := r.y + f32(dir) * l.h

	// The row nearest the target
	best, best_d := from, max(f32)
	for item, i in w.items {
		ir, found := element_rect(item_row_id(item))
		d := abs(ir.y - target)
		if found && d < best_d {
			best = i
			best_d = d
		}
	}

	w.focus = best
	w.reveal = true
}


// Enter on a row: flip a choice, edit text, open a list, or record a keybinding
@(private = "file")
activate_item :: proc(item: Setting_Item) {
	switch x in item {
	case Setting:
		info := SETTINGS[x]
		switch v in setting_value(shown_values(x), x) {
		case ^bool:
			on := !v^
			setting_value(edit_values(x), x).(^bool)^ = on

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

			// The next choice
			i := 0
			for c, j in info.choices {
				if c == v^ do i = j
			}
			next := info.choices[(i + 1) % len(info.choices)]
			set_string(setting_value(edit_values(x), x).(^string), next)
		}
		scope_changed()

	case Command:
		start_recording(x)

	case Server_Item, Add_Server_Item:
		server_item_activate(item)

	case Section:
		set_collapsed(x, x not_in collapsed_set())
	}
}


// Delete on a row: put it back to its default, or in Project scope have it
// follow the user's setting again
@(private = "file")
reset_item :: proc(item: Setting_Item) {
	switch x in item {
	case Setting:
		s := &g.settings
		if g.settings_window.scope == .User {
			setting_reset(&s.user, x)
			settings_changed()
		} else if x in s.project.set {
			s.project.set -= {x}
			project_settings_changed()
		}
	case Command:
		g.settings.bindings[x] = default_bindings(x)
		g.settings.terminal_commands -= {x}
		g.settings.terminal_commands += DEFAULT_TERMINAL_COMMANDS & {x}
		settings_changed()
		set_bind_note(x, "")
	case Server_Item:
		server_item_reset(x)
	case Add_Server_Item, Section:
	}
}


@(private = "file")
confirm_reset_all :: proc() {
	ask_reset_settings(g.settings_window.scope)
}


// --- Keybindings -------------------------------------------------------------------

// Waits for a chord to add to a command's bindings, unless it has all it can
@(private = "file")
start_recording :: proc(cmd: Command) {
	w := &g.settings_window
	if bindings_count(g.settings.bindings[cmd]) >= MAX_CHORDS {
		set_bind_note(cmd, full_note())
		return
	}

	set_bind_note(cmd, "")
	w.recording = cmd
}


// While a keybinding waits for keys, adds the chord pressed (a key, or a mouse
// button) to its command's bindings, taking it from the command that had it,
// which the row then says. Returns whether it was waiting
settings_window_record :: proc(chord: Chord) -> bool {
	w := &g.settings_window
	cmd, recording := w.recording.?
	if !w.open || !recording {
		return false
	}
	w.recording = nil

	result, from, taken := bindings_add(&g.settings.bindings, cmd, chord)
	switch result {
	case .Added:
		settings_changed()
		if taken {
			note := fmt.tprintf("%s was taken from %s", format_chord(chord), COMMANDS[from].name)
			set_bind_note(cmd, note)
		}
	case .Already_Bound:
		set_bind_note(cmd, fmt.tprintf("%s is bound to this already", format_chord(chord)))
	case .Full:
		set_bind_note(cmd, full_note())
	}
	return true
}


@(private = "file")
full_note :: proc() -> string {
	return fmt.tprintf("At most %d bindings: remove one first", MAX_CHORDS)
}


@(private = "file")
set_bind_note :: proc(cmd: Command, note: string) {
	w := &g.settings_window
	set_string(&w.bind_note, note)
	w.bind_note_for = cmd
}


// The focused binding chip, if the focused row has one focused
@(private = "file")
focused_chip :: proc() -> (cmd: Command, i: int, ok: bool) {
	w := &g.settings_window
	row, is_command := focused_row_command()
	if !is_command || row != w.chip_command {
		return
	}
	if w.chip < 0 || w.chip >= bindings_count(g.settings.bindings[row]) {
		return
	}
	return row, w.chip, true
}


// ←→ on a keybinding row: the focus moves between its chips and the row
@(private = "file")
move_chip :: proc(cmd: Command, dir: int) {
	w := &g.settings_window
	current := w.chip_command == cmd ? w.chip : -1
	last := bindings_count(g.settings.bindings[cmd]) - 1

	w.chip = clamp(current + dir, -1, last)
	w.chip_command = cmd
}


// Removes a command's binding i; the focus goes to the chip now in its place,
// else the one before
@(private = "file")
remove_binding :: proc(cmd: Command, i: int) {
	w := &g.settings_window
	bindings_remove(&g.settings.bindings, cmd, i)
	settings_changed()
	set_bind_note(cmd, "")

	if w.chip_command == cmd {
		w.chip = min(w.chip, bindings_count(g.settings.bindings[cmd]) - 1)
	}
}


// Scrolls a list so a row in it is visible, using last frame's layout. Returns
// true if the row was already in view
@(private)
scroll_into_view :: proc(list, row: clay.ElementId) -> bool {
	scroll := clay.GetScrollContainerData(list)
	r, row_ok := element_rect(row)
	l, list_ok := element_rect(list)
	if !scroll.found || !row_ok || !list_ok {
		return false
	}

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
	if w.focus < 0 || w.focus >= len(w.items) {
		return
	}
	scroll_into_view(clay.ID("SettingsList"), item_row_id(w.items[w.focus]))
}


@(private)
item_row_id :: proc(item: Setting_Item) -> clay.ElementId {
	switch x in item {
	case Setting:         return clay.ID("SettingRow", u32(x))
	case Command:         return clay.ID("BindingRow", u32(x))
	case Server_Item:     return clay.ID("ServerRow", u32(x))
	case Add_Server_Item: return clay.ID("AddServerRow")
	case Section:         return clay.ID("SectionHeader", u32(x))
	}
	return {}
}


// Lists a row as shown this frame (for keyboard focus). Returns its index
@(private = "file")
add_item :: proc(item: Setting_Item) -> int {
	w := &g.settings_window
	append(&w.items, item)
	index := len(w.items) - 1

	if w.refocus == item {
		w.focus = index
		w.refocus = nil
		w.reveal = true
	}
	return index
}


// --- Collapsed sections ------------------------------------------------------------

// The sections collapsed_sections lists
@(private)
collapsed_set :: proc() -> (set: bit_set[Section]) {
	list := g.settings.collapsed_sections
	for key in strings.split_iterator(&list, ",") {
		for k, section in SECTION_KEYS {
			if strings.trim_space(key) == k do set += {section}
		}
	}
	return
}


// The collapsed sections with one collapsed or expanded
@(private = "file")
with_collapsed :: proc(section: Section, collapsed: bool) -> bit_set[Section] {
	set := collapsed_set()
	if collapsed {
		set += {section}
	} else {
		set -= {section}
	}
	return set
}


// Collapses or expands a section from the keyboard
@(private = "file")
set_collapsed :: proc(section: Section, collapsed: bool) {
	set_collapsed_sections(with_collapsed(section, collapsed), clicked = false)
}


// Makes `set` the collapsed sections, saved to settings.toml. Keyboard focus
// stays on its row; on a row a section collapsing hides, it goes to that
// section's header, or after a click, back to the search field (a click
// doesn't highlight anything). Needs last frame's rows (`items`)
@(private = "file")
set_collapsed_sections :: proc(set: bit_set[Section], clicked: bool) {
	w := &g.settings_window
	if w.focus >= 0 && w.focus < len(w.items) {
		item := w.items[w.focus]
		section := item_section(item)
		hidden := section in set && item != Setting_Item(section)

		switch {
		case hidden && clicked: w.focus = -1
		case hidden:            w.refocus = Setting_Item(section)
		case:                   w.refocus = item
		}
	}

	keys := make([dynamic]string, context.temp_allocator)
	for section in set {
		append(&keys, SECTION_KEYS[section])
	}
	joined := strings.join(keys[:], ", ", context.temp_allocator)
	set_string(&g.settings.user.collapsed_sections, joined)
	settings_resolve(&g.settings)
	settings_save_later(&g.settings)
}


// The section a row is in
@(private = "file")
item_section :: proc(item: Setting_Item) -> Section {
	switch x in item {
	case Setting:                      return SETTINGS[x].section
	case Command:                      return .Keybindings
	case Server_Item, Add_Server_Item: return .Language_Servers
	case Section:                      return x
	}
	return .General
}


// --- Picker ------------------------------------------------------------------------

@(private = "file")
open_picker :: proc(x: Setting) {
	w := &g.settings_window
	finish_text_edit(commit = true)
	w.recording = nil

	// Remember the values to restore on cancel
	w.picking = true
	w.picker = x
	set_string(&w.original, current_value(x))
	for e in picker_extras(x) do w.original_extras[e] = number_value(e)
	w.original_set = g.settings.project.set

	line_edit_clear(&w.filter)
	w.picker_reveal = true
	w.extra_focus = -1

	if i, ok := gfx.theme_index(current_value(.Theme)); ok {
		w.dark_themes = gfx.THEMES[i].dark
	}
	if is_font_setting(x) do gfx.fonts_scan(&g.fonts, walk_files, again = true)
}


// Whether a picker chooses a font family (listing the installed fonts)
@(private = "file")
is_font_setting :: proc(x: Setting) -> bool {
	return x == .Font_Family || x == .Markdown_Font || x == .Ui_Font
}


// Leaves the list, keeping what is now applied or restoring the old values
@(private = "file")
close_picker :: proc(commit: bool) {
	w := &g.settings_window
	if !w.picking do return

	w.picking = false
	drop_picker_click()
	if commit {
		scope_changed()
		return
	}

	// The values as they were, and in Project scope which of them it set
	set_string(setting_value(shown_values(w.picker), w.picker).(^string), w.original)
	for e in picker_extras(w.picker) do set_number_value(e, w.original_extras[e])
	if w.scope == .Project {
		changed := bit_set[Setting]{w.picker}
		for e in picker_extras(w.picker) do changed += {e}

		project := &g.settings.project
		project.set = (project.set - changed) + (w.original_set & changed)
	}
	scope_previewed()
}


// Before the layout: applies the picker's click from the last frame
settings_window_frame :: proc() {
	w := &g.settings_window
	click := w.picker_click
	w.picker_click = nil
	if !w.open || !w.picking {
		free_picker_click(click)
		return
	}

	switch c in click {
	case Picker_Option_Click:
		if c.keep {
			close_picker(commit = true)
			settings_window_toggle()
		} else {
			preview_option(c.value)
		}
		delete(c.value)

	case Picker_Themes:
		show_dark_themes(c.dark)

	case Picker_Back:
		close_picker(commit = false)
	}
}


// Queues a click in the picker's page for the next frame, in place of any queued
@(private = "file")
queue_picker_click :: proc(click: Picker_Click) {
	w := &g.settings_window
	free_picker_click(w.picker_click)
	w.picker_click = click
}


@(private = "file")
drop_picker_click :: proc() {
	w := &g.settings_window
	free_picker_click(w.picker_click)
	w.picker_click = nil
}


@(private = "file")
free_picker_click :: proc(click: Picker_Click) {
	if c, is_option := click.(Picker_Option_Click); is_option {
		delete(c.value)
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


// A number setting's value as shown, as f64 whether it is an int or not
@(private = "file")
number_value :: proc(x: Setting) -> f64 {
	#partial switch v in setting_value(shown_values(x), x) {
	case ^int: return f64(v^)
	case ^f64: return v^
	}
	return 0
}


// Puts back a number setting's value as shown (a picker cancelled)
@(private = "file")
set_number_value :: proc(x: Setting, n: f64) {
	#partial switch v in setting_value(shown_values(x), x) {
	case ^int: v^ = int(n)
	case ^f64: v^ = n
	}
}


// Steps one of the picker's extra settings, applied without saving
@(private = "file")
step_extra :: proc(x: Setting, dir: int) {
	setting_step(edit_values(x), x, dir)
	scope_previewed()
}


// Switches the theme list between dark and light, applying the current family's
// theme of that kind (or the first one)
@(private = "file")
show_dark_themes :: proc(dark: bool) {
	w := &g.settings_window
	if w.dark_themes == dark do return

	w.dark_themes = dark
	i, _ := gfx.theme_index(current_value(.Theme))

	next := -1
	for spec, j in gfx.THEMES {
		if spec.dark != dark do continue

		same_family := spec.family == gfx.THEMES[i].family
		if next < 0 || same_family {
			next = j
		}
		if same_family do break
	}

	line_edit_clear(&w.filter)
	preview_option(gfx.THEMES[next].key)
	w.picker_reveal = true
}


@(private = "file")
picker_handle_event :: proc(event: ^sdl.Event) -> bool {
	w := &g.settings_window

	// The filter has the keys while the list is focused, but for Left and Right
	// in an empty filter (they switch between dark and light themes). Typing or
	// Backspace on an extra setting goes back to the list
	is_key := event.type == .KEY_DOWN
	if event.type == .TEXT_INPUT || (is_key && event.key.key == sdl.K_BACKSPACE) {
		w.extra_focus = -1
	}
	arrow := is_key && (event.key.key == sdl.K_LEFT || event.key.key == sdl.K_RIGHT)
	if w.extra_focus < 0 && !(arrow && len(w.filter.text) == 0) {
		handled, changed := line_edit_event(&w.filter, event)
		if changed do filter_changed()
		if handled do return true
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
		// Cycle the list -> each extra setting -> the list
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
		// window, cancelling the list
		if cmd, ok := command_for_key(key); ok {
			#partial switch cmd {
			case .Find:
				w.extra_focus = -1
				line_edit_select_all(&w.filter)
			case .Open_Settings:
				return false
			}
		}
	}
	return true
}


// The filter changed: the current option stays while it still matches, else
// the first match shows
@(private = "file")
filter_changed :: proc() {
	w := &g.settings_window
	options := picker_options(w.picker, line_edit_string(&w.filter))
	if len(options) > 0 && option_index(options, current_value(w.picker)) < 0 {
		preview_option(options[0].value)
	}
	w.picker_reveal = true
}


// The options of a picker setting that match `filter`
@(private = "file")
picker_options :: proc(x: Setting, filter: string) -> []Picker_Option {
	all := make([dynamic]Picker_Option, context.temp_allocator)

	#partial switch x {
	case .Theme:
		// Dark and light themes are listed apart, so moving through the list
		// doesn't flash between them
		for spec in gfx.THEMES {
			if spec.dark == g.settings_window.dark_themes {
				append(&all, Picker_Option{spec.key, spec.name, ""})
			}
		}

	case .Font_Family:
		for name in gfx.font_family_names(&g.fonts) {
			append(&all, Picker_Option{name, name, ""})
		}

	case .Markdown_Font, .Ui_Font:
		for name in gfx.all_family_names(&g.fonts) {
			append(&all, Picker_Option{name, name, ""})
		}
	}
	if filter == "" do return all[:]

	query := strings.to_lower(filter, context.temp_allocator)
	shown := make([dynamic]Picker_Option, context.temp_allocator)
	for o in all {
		if matches(query, o.label, o.keywords) do append(&shown, o)
	}
	return shown[:]
}


// A string setting's value as shown
@(private = "file")
current_value :: proc(x: Setting) -> string {
	return setting_value(shown_values(x), x).(^string)^
}


@(private = "file")
option_index :: proc(options: []Picker_Option, value: string) -> int {
	for o, i in options {
		if o.value == value do return i
	}
	return -1
}


// Applies an option without saving it
@(private = "file")
preview_option :: proc(value: string) {
	x := g.settings_window.picker
	set_string(setting_value(edit_values(x), x).(^string), value)
	scope_previewed()
}


// How many options Page Up/Down moves: one fewer than fit in the list
@(private = "file")
picker_page_rows :: proc() -> int {
	l, ok := element_rect(clay.ID("PickerList"))
	if !ok do return 1

	return max(int(l.h / (PICKER_ROW_HEIGHT + 2)) - 1, 1)
}


@(private = "file")
move_option :: proc(dir: int) {
	w := &g.settings_window
	options := picker_options(w.picker, line_edit_string(&w.filter))
	if len(options) == 0 do return

	// From the current option, or from an end if none is shown
	i := option_index(options, current_value(w.picker))
	last := len(options) - 1
	next: int
	if i < 0 {
		next = dir > 0 ? 0 : last
	} else {
		next = clamp(i + dir, 0, last)
	}

	preview_option(options[next].value)
	w.picker_reveal = true
}


// --- UI ----------------------------------------------------------------------------

settings_window_ui :: proc() {
	w := &g.settings_window
	if !w.open do return

	r := w.picking ? picker_rect() : settings_rect()
	backdrop := gfx.theme.backdrop
	if w.picking do backdrop.a = 0 // leave the editor undimmed for previewing

	// The panel moves and resizes to the new page, which fades in. Pages are laid
	// out at the panel's final size, which it clips them to while it moves.
	// The list leaves the rest of the window usable: files can be opened and the
	// editor scrolled to see the change on other text (see ui_interactive)
	panel := clay.ID("Settings")
	if modal_at(panel, r, backdrop, modal = !w.picking) {
		switch {
		case w.picking:          picker_page(r.w, r.h)
		case w.server_page != "": server_page(r.w, r.h)
		case:                    settings_page(r.w, r.h)
		}
	}

	if !w.picking && clicked_outside(panel, w.opened_at) {
		settings_window_toggle()
	}
}


// The settings window is showing an option list at the side, not covering the window
settings_window_docked :: proc() -> bool {
	return g.settings_window.open && g.settings_window.picking
}


@(private = "file")
settings_rect :: proc() -> gfx.Rect {
	w := min(SETTINGS_WIDTH, f32(g.window_w) - 32)
	h := max(f32(g.window_h) - 96, 200)
	x := math.floor((f32(g.window_w) - w) / 2) // modal_at places it on whole pixels
	return {x, 48, w, h}
}


// At the right edge, above the status bar
@(private = "file")
picker_rect :: proc() -> gfx.Rect {
	w := min(PICKER_WIDTH, f32(g.window_w) - 2 * PICKER_MARGIN)
	h := max(f32(g.window_h) - STATUSBAR_HEIGHT - 2 * PICKER_MARGIN, 200)
	return {f32(g.window_w) - w - PICKER_MARGIN, PICKER_MARGIN, w, h}
}


@(private = "file")
settings_page :: proc(width, height: f32) {
	w := &g.settings_window
	reveal_focus()

	// A click's collapsing, with last frame's rows still listed
	if set, clicked := w.collapse_to.?; clicked {
		set_collapsed_sections(set, clicked = true)
		w.collapse_to = nil
	}
	clear(&w.items)

	if clay.UI(clay.ID("SettingsPage"))({
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		transition = transition({.OverlayColor}, enter = .Fade),
		layout = {
			sizing = {clay.SizingFixed(width), clay.SizingFixed(height)},
			layoutDirection = .TopToBottom,
			padding = {left = 20, right = 20, top = 16, bottom = 14},
			childGap = 14,
		},
	}) {
		// Title, the scope switch and the close button
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childAlignment = {y = .Center},
				childGap = 14,
			},
		}) {
			label("Settings", gfx.theme.text_bright, 16, .SemiBold)
			scope_switch()
			push_right()
			if len(w.search.text) == 0 do collapse_all_button() // a search shows every section
			close_id := clay.ID("SettingsClose")
			if icon_button(close_id, .Close, 26, 18, "Close", "Esc") {
				settings_window_toggle()
			}
		}

		search_field()
		problem := w.scope == .User ? g.settings.error : g.settings.project_error
		if problem != "" do error_banner(problem)
		settings_list()
		footer()
	}
}


// User or Project: whose settings the window shows. The project's name is in
// the tooltip of its side
@(private = "file")
scope_switch :: proc() {
	w := &g.settings_window
	choice, changed := segmented(SCOPE_SWITCH_ID, {"User", "Project"}, int(w.scope))
	if changed do set_scope(Settings_Scope(choice))

	name := folder_name(g.project.root)
	tooltip(scope_switch_side(.Project), fmt.tprintf("Settings for %s only, over yours", name))
}


// "Collapse all", or "Expand all" once every section is collapsed
@(private = "file")
collapse_all_button :: proc() {
	none := bit_set[Section]{} // spelled out: a bare {} would be a nil Maybe below
	all := ~none
	expand := collapsed_set() == all

	text := expand ? "Expand all" : "Collapse all"
	tip := expand ? "Show every section's settings" : "Show only the sections' names"
	if button(clay.ID("SettingsCollapseAll"), text, tip) {
		g.settings_window.collapse_to = expand ? none : all
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
	text_field(id, &w.search, "Search settings", focused, {height = 34})
}


@(private = "file")
error_banner :: proc(msg: string) {
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			padding = clay.PaddingAll(10),
		},
		backgroundColor = gfx.theme.hover,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.error, width = {left = 3}},
	}) {
		paragraph(msg)
	}
}


@(private = "file")
settings_list :: proc() {
	list := clay.ID("SettingsList")
	if clay.UI(list)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {right = SCROLLBAR_GUTTER},
			childGap = 18,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		w := &g.settings_window
		search := line_edit_string(&w.search)
		query := strings.to_lower(search, context.temp_allocator)
		collapsed := query == "" ? collapsed_set() : {} // a search shows what it finds
		user := w.scope == .User
		shown := 0
		for key, section in SECTION_KEYS {
			// The section's rows that match the search, of those in the scope
			rows := make([dynamic]Setting_Item, context.temp_allocator)
			if section == .Keybindings && user {
				for info, cmd in COMMANDS {
					bound := bindings_label(g.settings.bindings[cmd], " ")
					if matches(query, key, info.name, bound) do append(&rows, cmd)
				}
			} else if section != .Keybindings {
				for info, x in SETTINGS {
					in_window := info.section == section && info.name != "" && in_scope(x)
					if in_window && matches(query, key, info.name, info.keywords) {
						append(&rows, x)
					}
				}
			}
			servers := user && section == .Language_Servers && servers_match(query)
			if len(rows) == 0 && !servers {
				continue
			}

			// The section, with its rows unless collapsed
			shown += 1
			count := len(rows)
			if servers do count += len(server_rows())
			header := Section_Header {
				section   = section,
				title     = key,
				count     = count,
				collapsed = section in collapsed,
				toggles   = query == "",
			}
			if section_header(header, list) {
				for item in rows {
					#partial switch x in item {
					case Setting:
						info := SETTINGS[x]
						detail, color := setting_detail(x)
						if setting_row(
							x,
							info.name,
							info.description,
							list,
							detail = detail,
							detail_color = color,
						) {
							setting_control(x)
						}
					case Command:
						// The note copied: a click in the row may replace it
						note := ""
						if w.bind_note_for == x {
							note = strings.clone(w.bind_note, context.temp_allocator)
						}
						if setting_row(x, COMMANDS[x].name, "", list, detail = note) {
							keybinding_control(x, list)
						}
					}
				}
				if servers do servers_list(query, list)
			}
		}

		if shown == 0 {
			if clay.UI()({layout = {padding = {left = 4, top = 8}}}) {
				label("No settings match your search", gfx.theme.text_dim)
			}
		}
	}
	list_scrollbar(list, &g.settings_window.scrollbar_drag, POPUP_LAYER)
}


// Whether a lower-case query is in one of the parts (any case)
@(private)
matches :: proc(query: string, parts: ..string) -> bool {
	if query == "" do return true

	for p in parts {
		if strings.contains(strings.to_lower(p, context.temp_allocator), query) {
			return true
		}
	}
	return false
}


// A section's header: what it shows, and whether it collapses
@(private = "file")
Section_Header :: struct {
	section:   Section,
	title:     string,
	count:     int, // its rows, shown while collapsed
	collapsed: bool,
	toggles:   bool, // a click or Enter collapses or expands it (not while searching)
}


// A titled group of rows. Use as: if section_header(...) { rows }; false while
// it is collapsed
@(private = "file", deferred_none = close_element)
section_header :: proc(h: Section_Header, list: clay.ElementId) -> bool {
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 2,
		},
	})

	upper := strings.to_upper(h.title, context.temp_allocator)
	if !h.toggles {
		if clay.UI()({layout = {padding = {left = 4, bottom = 6}}}) {
			label(upper, gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		}
		return true
	}

	// A row of its own, which collapses or expands the section
	w := &g.settings_window
	index := add_item(h.section)
	focused := index == w.focus
	id := item_row_id(h.section)
	if clicked(id, list) {
		w.collapse_to = with_collapsed(h.section, !h.collapsed)
	}

	if clay.UI(id)({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(26)},
			padding = {left = 2, right = 8},
			childGap = 4,
			childAlignment = {y = .Center},
		},
		backgroundColor = focused || clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(5),
		border = {
			color = focused ? gfx.theme.accent : {},
			width = focused ? clay.BorderOutside(1) : {},
		},
	}) {
		icon(h.collapsed ? .Chevron_Right : .Chevron_Down, gfx.theme.text_dim, 14)
		label(upper, gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		if h.collapsed {
			spacer_x(4)
			label(fmt.tprintf("%d", h.count), gfx.theme.text_faint, FONT_SIZE_SMALL)
		}
	}
	return !h.collapsed
}


// One row: name and description on the left (after a dot of `mark`'s color,
// if any), its control on the right. `detail` is one more line, cut off where
// the row ends (it may hold a path, which can't wrap), dim unless given a
// color. Use as: if setting_row(...) { control }
@(private, deferred_none = close_element)
setting_row :: proc(
	item: Setting_Item,
	name, description: string,
	list: clay.ElementId,
	mark := clay.Color{},
	detail := "",
	detail_color := clay.Color{},
) -> bool {
	w := &g.settings_window
	index := add_item(item)
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
		backgroundColor = focused || clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(6),
		border = {
			color = focused ? gfx.theme.accent : {},
			width = focused ? clay.BorderOutside(1) : {},
		},
	})

	// Name, description, and the detail line
	state_mark(mark)
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			childGap = 2,
		},
	}) {
		label(name, gfx.theme.text)
		if description != "" do paragraph(description, gfx.theme.text_dim)
		if detail != "" {
			color := detail_color.a > 0 ? detail_color : gfx.theme.text_dim
			clipped_line(detail, color)
		}
	}
	return true
}


// A line under a setting, or "" (temp): where the project sets it, else how
// things stand for it. No color is the row's default
@(private = "file")
setting_detail :: proc(x: Setting) -> (detail: string, color: clay.Color) {
	if note, note_color := scope_note(x); note != "" {
		return note, note_color
	}

	#partial switch x {
	case .Terminal_Backend: return persist_status_note(), {}
	}
	return "", {}
}


// A line of small text, clipped: its width doesn't widen what holds it
@(private = "file")
clipped_line :: proc(text: string, color: clay.Color) {
	if clay.UI()({
		layout = {sizing = {width = clay.SizingGrow()}},
		clip = row_clip(),
	}) {
		label(text, color, FONT_SIZE_SMALL)
	}
}


@(private)
close_element :: proc() {
	clay._CloseElement()
}


// A list row's fill: selected, else hovered (call it inside the row's config)
@(private = "file")
row_fill :: proc(selected: bool) -> clay.Color {
	if selected do return gfx.theme.selected
	if clay.Hovered() do return gfx.theme.hover
	return {}
}


// --- Controls ----------------------------------------------------------------------

// A setting's control, showing its value in the scope; a change goes to the
// scope's values
@(private = "file")
setting_control :: proc(x: Setting) {
	info := SETTINGS[x]
	list := clay.ID("SettingsList")

	switch v in setting_value(shown_values(x), x) {
	case ^bool:
		choice, changed := segmented(u32(x), {"Off", "On"}, int(v^), list)
		if changed {
			setting_value(edit_values(x), x).(^bool)^ = choice == 1
			scope_changed()
		}

	case ^int, ^f64:
		dir := stepper(x, list)
		if dir != 0 {
			setting_step(edit_values(x), x, dir)
			scope_changed()
		}

	case ^string:
		if info.picker {
			picker_button(x, v^)
		} else if info.choices != nil {
			// The choices, capitalized
			names := make([]string, len(info.choices), context.temp_allocator)
			current := 0
			for c, i in info.choices {
				first := strings.to_upper(c[:1], context.temp_allocator)
				names[i] = strings.concatenate({first, c[1:]}, context.temp_allocator)
				if c == v^ do current = i
			}

			choice, changed := segmented(u32(x), names, current, list)
			if changed {
				set_string(setting_value(edit_values(x), x).(^string), info.choices[choice])
				scope_changed()
			}
		} else {
			text_setting_field(x, v^)
		}
	}
}


// A row of mutually exclusive options; `id_base` tells its options' ids apart
// from other rows' (a Setting, or past them). Returns the clicked option if it
// changed
@(private)
segmented :: proc(
	id_base: u32,
	options: []string,
	selected: int,
	within := clay.ElementId{},
) -> (
	choice: int,
	changed: bool,
) {
	if clay.UI()({
		layout = {padding = clay.PaddingAll(2), childGap = 2},
		backgroundColor = gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		for option, i in options {
			id := clay.ID("SettingOption", id_base * 64 + u32(i))
			is_selected := i == selected

			if clay.UI(id)({
				layout = {
					sizing = {
						width = clay.SizingFit({min = 64}),
						height = clay.SizingFixed(26),
					},
					padding = {left = 10, right = 10},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = row_fill(is_selected),
				cornerRadius = clay.CornerRadiusAll(4),
			}) {
				label(option, is_selected ? gfx.theme.text_bright : gfx.theme.text_dim)
			}

			if clicked(id, within) && !is_selected {
				choice = i
				changed = true
			}
		}
	}
	return
}


// "-" value "+" for a number setting. Returns the direction clicked, or 0.
// `within` is the scroll area it sits in, if any
@(private = "file")
stepper :: proc(x: Setting, within: clay.ElementId) -> (dir: int) {
	value: string
	#partial switch v in setting_value(shown_values(x), x) {
	case ^int: value = fmt.tprintf("%d", v^)
	case ^f64: value = format_decimal(v^)
	}

	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		if stepper_button(clay.ID("Decrease", u32(x)), "-", within) do dir = -1

		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingFixed(44)},
				childAlignment = {x = .Center},
			},
		}) {
			label(value, gfx.theme.text_bright)
		}

		if stepper_button(clay.ID("Increase", u32(x)), "+", within) do dir = +1
	}
	return
}


@(private = "file")
stepper_button :: proc(id: clay.ElementId, text: string, within: clay.ElementId) -> bool {
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(28), clay.SizingFixed(26)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		label(text, gfx.theme.text)
	}
	return clicked(id, within)
}


// Shows a picker setting's value; click or Enter to open its list
@(private = "file")
picker_button :: proc(x: Setting, value: string) {
	id := clay.ID("PickerButton", u32(x))

	// The value's name, and whether its font is missing
	text := value
	missing := false
	#partial switch x {
	case .Theme:
		if i, ok := gfx.theme_index(value); ok {
			text = gfx.THEMES[i].name
		}
	case .Font_Family, .Markdown_Font, .Ui_Font:
		missing = gfx.font_family_missing(&g.fonts, value)
	}

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(220), clay.SizingFixed(28)},
			padding = {left = 10, right = 6},
			childGap = 6,
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}},
			clip = row_clip(),
		}) {
			label(text, missing ? gfx.theme.error : gfx.theme.text_bright, 13)
		}
		icon(.Chevron_Right, gfx.theme.text_dim, 15)
	}

	if clicked(id, clay.ID("SettingsList")) do open_picker(x)

	tip := "Choose"
	if missing {
		tip = x == .Font_Family ? MISSING_FONT_TIP : MISSING_SANS_FONT_TIP
	}
	tooltip(id, tip, "Enter")
}


// A one-line text field; click or Enter to edit. Shows the default, dimmed, when empty
@(private = "file")
text_setting_field :: proc(x: Setting, value: string) {
	w := &g.settings_window
	id := clay.ID("SettingField")
	editing := w.editing == x

	list := clay.ID("SettingsList")
	if clicked(id, list) {
		if !editing do start_text_edit(x)
	} else if editing && g.mouse_pressed && !pointer_in(id) {
		finish_text_edit(commit = true) // clicking elsewhere keeps what was typed
	}
	editing = w.editing == x

	default := x == .Terminal_Shell ? fmt.tprintf("%s (default)", term.default_shell()) : ""
	look := Field_Look{width = 260, height = 28, size = 13, within = list}
	text_field(id, editing ? &w.edit : nil, default, editing, look, value)
	if !editing do tooltip(id, "Edit", "Enter")
}


// A keybinding may be a key or a mouse side button (MOUSE_BUTTONS)
@(private = "file")
RECORDING_PROMPT :: "Press a key or side button…  (Esc cancels)"


// A command's bindings, each a chip with an x on hover that removes it, then
// Add (the prompt while recording), whether it works in terminals and, when
// any of it isn't the default, Reset
@(private = "file")
keybinding_control :: proc(cmd: Command, list: clay.ElementId) {
	w := &g.settings_window
	recording := w.recording == cmd
	chords := g.settings.bindings[cmd] // a copy: a click below may change them
	in_terminals := cmd in g.settings.terminal_commands
	changed := chords != default_bindings(cmd) ||
	           in_terminals != (cmd in DEFAULT_TERMINAL_COMMANDS)

	if clay.UI()({layout = {childGap = 6, childAlignment = {y = .Center}}}) {
		// Reset, when changed
		if !recording && changed {
			reset_id := clay.ID("BindingReset", u32(cmd))
			if button(reset_id, "Reset", "Reset to default", "Del", list) {
				reset_item(cmd)
			}
		}

		// The chips
		for chord, i in chords {
			if chord_bound(chord) do binding_chip(cmd, i, chord, list)
		}

		// Add, or the prompt
		count := bindings_count(chords)
		if count < MAX_CHORDS || recording {
			add_binding_button(cmd, count, recording, list)
		}

		terminal_toggle(cmd, in_terminals, list)
	}
}


// Whether the command works while a terminal has focus: a terminal icon, lit
// while it does. Editor commands always go to the shell: an empty slot keeps
// the other rows' toggles in a column
@(private = "file")
terminal_toggle :: proc(cmd: Command, on: bool, list: clay.ElementId) {
	slot := clay.SizingFixed(BINDING_CHIP_HEIGHT)
	if cmd in EDITOR_COMMANDS {
		if clay.UI()({layout = {sizing = {slot, slot}}}) {}
		return
	}

	id := clay.ID("BindingTerminal", u32(cmd))
	hovered := pointer_in(id) && pointer_in(list)
	color := gfx.theme.text_faint
	switch {
	case on:      color = gfx.theme.accent
	case hovered: color = gfx.theme.text_dim
	}

	if clay.UI(id)({
		layout = {sizing = {slot, slot}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = hovered ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(5),
	}) {
		icon(.Terminal, color, 14)
	}

	tip := on ? "Works while a terminal has focus" : "Goes to the shell while a terminal has focus"
	tooltip(id, tip)
	if clicked(id, list) {
		set_terminal_command(cmd, !on)
	}
}


// Makes a command work while a terminal has focus, or go to the shell
set_terminal_command :: proc(cmd: Command, on: bool) {
	if on {
		g.settings.terminal_commands += {cmd}
	} else {
		g.settings.terminal_commands -= {cmd}
	}
	settings_changed()
}


// The height of a binding chip and the add button, and the slot for a chip's x
@(private = "file")
BINDING_CHIP_HEIGHT :: 26
@(private = "file")
BINDING_X_SLOT :: 16


// A binding: the chord, centered between the x shown while the pointer is on
// it and a slot as wide on the other side. A press on the chip focuses it, on
// the x removes the binding
@(private = "file")
binding_chip :: proc(cmd: Command, i: int, chord: Chord, list: clay.ElementId) {
	w := &g.settings_window
	n := u32(cmd) * MAX_CHORDS + u32(i)
	id := clay.ID("BindingChip", n)
	remove := clay.ID("BindingRemove", n)

	_, row_focused := focused_row_command()
	focused := row_focused && w.chip_command == cmd && w.chip == i
	hovered := pointer_in(id) && pointer_in(list)

	if clay.UI(id)({
		layout = {
			sizing = {height = clay.SizingFixed(BINDING_CHIP_HEIGHT)},
			padding = {left = 4, right = 4},
			childGap = 2,
			childAlignment = {y = .Center},
		},
		backgroundColor = hovered ? gfx.theme.hover : gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {
			color = focused ? gfx.theme.accent : gfx.theme.border,
			width = clay.BorderOutside(1),
		},
	}) {
		// The chord between two slots of the same width, so it is centered
		x_slot := clay.SizingFixed(BINDING_X_SLOT)
		if clay.UI(clay.ID("BindingBalance", n))({layout = {sizing = {x_slot, x_slot}}}) {}
		label(format_chord(chord), gfx.theme.text, FONT_SIZE_SMALL)

		// The x, in a slot that is there either way so chips don't move
		if clay.UI(remove)({
			layout = {
				sizing = {x_slot, x_slot},
				childAlignment = {x = .Center, y = .Center},
			},
			cornerRadius = clay.CornerRadiusAll(3),
			backgroundColor = hovered && clay.Hovered() ? gfx.theme.selected : {},
		}) {
			if hovered do icon(.Close, gfx.theme.text_dim, 12)
		}
	}
	if hovered do tooltip(remove, "Remove", "Del")

	switch {
	case clicked(remove, list):
		remove_binding(cmd, i)
	case clicked(id, list):
		w.chip = i
		w.chip_command = cmd
	}
}


// Adds a binding: records the next chord pressed. Says what it does while
// none is bound, the prompt while recording
@(private = "file")
add_binding_button :: proc(cmd: Command, count: int, recording: bool, list: clay.ElementId) {
	w := &g.settings_window
	id := clay.ID("BindingAdd", u32(cmd))

	// Just the + is a square, centered; with words, padded alike on both sides
	icon_only := !recording && count > 0
	height := clay.SizingFixed(BINDING_CHIP_HEIGHT)
	width := icon_only ? height : clay.SizingFit()
	padding: u16 = icon_only ? 0 : 8

	if clay.UI(id)({
		layout = {
			sizing = {width, height},
			padding = {left = padding, right = padding},
			childGap = 4,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = clay.Hovered() || recording ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(5),
		border = {
			color = recording ? gfx.theme.accent : gfx.theme.border,
			width = clay.BorderOutside(1),
		},
	}) {
		switch {
		case recording:
			label(RECORDING_PROMPT, gfx.theme.accent, FONT_SIZE_SMALL)
		case count == 0:
			icon(.Plus, gfx.theme.text_dim, 13)
			label("Add binding", gfx.theme.text_dim, FONT_SIZE_SMALL)
		case:
			icon(.Plus, gfx.theme.text_dim, 13)
		}
	}

	if !recording do tooltip(id, "Add binding", "Enter")
	if clicked(id, list) {
		if recording {
			w.recording = nil
		} else {
			start_recording(cmd)
		}
	}
}


// The focused row's command, if it is a keybinding row
@(private = "file")
focused_row_command :: proc() -> (cmd: Command, ok: bool) {
	w := &g.settings_window
	if w.focus < 0 || w.focus >= len(w.items) {
		return
	}
	return w.items[w.focus].(Command)
}


// The keys that do something on the focused row
@(private = "file")
footer_hint :: proc() -> string {
	w := &g.settings_window
	if w.editing != nil do return "Enter save  Esc cancel"
	if w.focus < 0 || w.focus >= len(w.items) {
		return "↑↓ select  Enter first result"
	}

	switch x in w.items[w.focus] {
	case Section:
		if x in collapsed_set() do return "↑↓ select  Enter or → expand"
		return "↑↓ select  Enter or ← collapse"
	case Server_Item:
		return "↑↓ select  ←→ off/on  Enter configure  Del reset"
	case Add_Server_Item:
		return "↑↓ select  Enter add a server"
	case Command:
		if _, _, on_chip := focused_chip(); on_chip {
			return "←→ choose  Del remove  Enter add a binding"
		}
		return "↑↓ select  Enter add a binding  → choose one  Del reset"
	case Setting:
		// In Project scope Delete makes a set value follow the user's
		reset := "  Del reset"
		if w.scope == .Project {
			reset = x in g.settings.project.set ? "  Del use yours" : ""
		}

		info := SETTINGS[x]
		switch _ in setting_value(&g.settings, x) {
		case ^string:
			if info.picker do return fmt.tprintf("↑↓ select  Enter choose%s", reset)
			if info.choices == nil do return fmt.tprintf("↑↓ select  Enter edit%s", reset)
		case ^bool, ^int, ^f64:
		}
		return fmt.tprintf("↑↓ select  ←→ change%s", reset)
	}
	return "↑↓ select  ←→ change  Del reset"
}


@(private = "file")
footer :: proc() {
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			childAlignment = {y = .Center},
			childGap = 8,
		},
	}) {
		// The keys for the focused row
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}},
			clip = {horizontal = true},
		}) {
			label(footer_hint(), gfx.theme.text_dim, FONT_SIZE_SMALL)
		}

		// Buttons: the scope's reset and file
		w := &g.settings_window
		reset_id := clay.ID("SettingsResetAll")
		edit_id := clay.ID("SettingsEditFile")
		switch w.scope {
		case .User:
			if button(reset_id, "Reset all", "Reset every setting to its default") {
				confirm_reset_all()
			}
			if g.settings.path != "" {
				if button(edit_id, "Edit settings.toml", g.settings.path) {
					g.pending = Open_File(strings.clone(g.settings.path))
					settings_window_toggle()
				}
			}

		case .Project:
			if button(reset_id, "Reset all", "Have every setting follow yours") {
				confirm_reset_all()
			}
			path := project_file(g.project.root, PROJECT_SETTINGS)
			if button(edit_id, "Edit .typo/settings.toml", path) {
				project_edit_settings()
				settings_window_toggle()
			}
		}
	}
}


// --- Picker page -------------------------------------------------------------------

@(private = "file")
picker_page :: proc(width, height: f32) {
	w := &g.settings_window
	x := w.picker
	options := picker_options(x, line_edit_string(&w.filter))
	current := current_value(x)
	list := clay.ID("PickerList")

	// Done once the row is in view; the list may not be laid out yet
	if w.picker_reveal {
		i := option_index(options, current)
		if i < 0 || scroll_into_view(list, clay.ID("PickerRow", u32(i))) {
			w.picker_reveal = false
		}
	}

	if clay.UI(clay.ID("PickerPage"))({
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		transition = transition({.OverlayColor}, enter = .Fade),
		layout = {
			sizing = {clay.SizingFixed(width), clay.SizingFixed(height)},
			layoutDirection = .TopToBottom,
			padding = {left = 12, right = 12, top = 12, bottom = 10},
			childGap = 10,
		},
	}) {
		// Back button and title
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childAlignment = {y = .Center},
				childGap = 4,
			},
		}) {
			back_id := clay.ID("PickerBack")
			if icon_button(back_id, .Chevron_Left, 26, 18, "Back to settings", "Esc") {
				queue_picker_click(Picker_Back{})
			}
			label(SETTINGS[x].name, gfx.theme.text_bright, 16, .SemiBold)
		}

		// Dark or light themes, and the filter
		if x == .Theme {
			shown := w.dark_themes ? 0 : 1
			choice, changed := segmented(u32(Setting.Theme), {"Dark", "Light"}, shown)
			if changed do queue_picker_click(Picker_Themes{dark = choice == 0})
		}
		// The filter has the keys while the list (not an extra setting) does
		placeholder := x == .Theme ? "Filter themes" : "Filter fonts"
		filter_id := clay.ID("PickerFilter")
		if clicked(filter_id) do w.extra_focus = -1
		text_field(filter_id, &w.filter, placeholder, w.extra_focus < 0)

		// The options
		if clay.UI(list)({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				layoutDirection = .TopToBottom,
				padding = {right = SCROLLBAR_GUTTER},
				childGap = 2,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for o, i in options do option_row(x, o, i, o.value == current, list)

			scanning := is_font_setting(x) && !g.fonts.scanned
			note := ""
			switch {
			case scanning:          note = "Looking for installed fonts…"
			case len(options) == 0: note = "No matches"
			}
			if note != "" {
				if clay.UI()({layout = {padding = {left = 8, top = 8}}}) {
					label(note, gfx.theme.text_dim, FONT_SIZE_SMALL)
				}
			}
		}
		list_scrollbar(list, &w.scrollbar_drag, POPUP_LAYER)

		// The settings adjusted along with the list
		extras := picker_extras(x)
		if len(extras) > 0 {
			if clay.UI()({
				layout = {
					sizing = {width = clay.SizingGrow()},
					layoutDirection = .TopToBottom,
					padding = {top = 8},
					childGap = 2,
				},
				border = {color = gfx.theme.border, width = {top = 1}},
			}) {
				for e, i in extras do extra_row(e, i)
			}
		}

		// The keys
		hint: string
		switch {
		case w.extra_focus >= 0: hint = "←→ adjust  ↑↓ row  Enter apply"
		case len(extras) > 0:    hint = "↑↓ font  Tab size  Enter apply  Esc back"
		case x == .Theme:        hint = "↑↓ preview  ←→ dark/light  Enter apply"
		case:                    hint = "↑↓ preview  Enter apply  Esc back"
		}
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}},
			clip = {horizontal = true},
		}) {
			label(hint, gfx.theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}


// One of the settings below a picker's list: its name and a stepper
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
		backgroundColor = focused || clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(5),
		border = {
			color = focused ? gfx.theme.accent : {},
			width = focused ? clay.BorderOutside(1) : {},
		},
	}) {
		label(SETTINGS[x].name, gfx.theme.text)
		push_right()
		dir := stepper(x, {})
		if dir != 0 do step_extra(x, dir)
	}
}


// One option. A click applies it; a second click on the applied one keeps it
// and closes the window, like Enter
@(private = "file")
option_row :: proc(
	x: Setting,
	o: Picker_Option,
	index: int,
	selected: bool,
	list: clay.ElementId,
) {
	id := clay.ID("PickerRow", u32(index))
	if clicked(id, list) {
		keep := selected && g.mouse_clicks >= 2
		queue_picker_click(Picker_Option_Click{value = strings.clone(o.value), keep = keep})
	}

	if clay.UI(id)({
		layout = {
			sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(PICKER_ROW_HEIGHT)},
			padding = {left = 8, right = 8},
			childGap = 10,
			childAlignment = {y = .Center},
		},
		backgroundColor = row_fill(selected),
		cornerRadius = clay.CornerRadiusAll(5),
		border = {
			color = selected ? gfx.theme.accent : {},
			width = selected ? clay.BorderOutside(1) : {},
		},
	}) {
		if x == .Theme {
			if i, ok := gfx.theme_index(o.value); ok {
				theme_swatch(gfx.THEMES[i])
			}
		}

		label(o.label, selected ? gfx.theme.text_bright : gfx.theme.text)

		bundled_mono := x == .Font_Family && o.value == gfx.BUNDLED_FAMILY
		bundled_sans := (x == .Markdown_Font || x == .Ui_Font) && gfx.is_bundled_family(o.value)
		if bundled_mono || bundled_sans {
			push_right()
			label("bundled", gfx.theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}


// A small sample of a theme: its background with a few of its syntax colors
@(private = "file")
theme_swatch :: proc(spec: gfx.Theme_Spec) {
	SAMPLE :: [?]syntax.Highlight{.Keyword, .String, .Function, .Type}

	if clay.UI()({
		layout = {
			sizing = {clay.SizingFixed(44), clay.SizingFixed(20)},
			padding = {left = 6, right = 6},
			childGap = 3,
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.rgb(spec.bg),
		cornerRadius = clay.CornerRadiusAll(4),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		for h in SAMPLE {
			if clay.UI()({
				layout = {sizing = {clay.SizingFixed(5), clay.SizingFixed(10)}},
				backgroundColor = gfx.rgb(spec.syntax[h]),
				cornerRadius = clay.CornerRadiusAll(1),
			}) {}
		}
	}
}
