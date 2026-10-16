package editor

import "core:math"
import "core:strings"

import clay "../vendor/clay-odin"
import "term"
import sdl "../vendor/sdl3"

// Keyboard and mouse input for a terminal: SDL events mapped to what
// libghostty-vt encodes for the running program.

// Keyboard and text input while the terminal has focus. Returns true if used.
terminal_handle_event :: proc(t: ^Terminal, event: ^sdl.Event) -> bool {
	s := &t.session
	t.blink_t0 = sdl.GetTicksNS()

	if event.type == .TEXT_INPUT {
		term.session_input(s, transmute([]u8)string(event.text.text))
		return true
	}
	key := event.key
	if is_modifier_key(key.key) do return true
	if cmd, ok := command_for_key(key); ok && cmd in TERMINAL_COMMANDS do return run_command(cmd)
	if key.key == sdl.K_F12 do return false // Clay debug view

	if !s.running {
		if key.key == sdl.K_RETURN || key.key == sdl.K_KP_ENTER do terminal_start_shell(t)
		return true
	}

	mods := term_mods(key.mod)
	ctrl, shift := mods & term.MOD_CTRL != {}, mods & term.MOD_SHIFT != {}
	base := base_key(key)
	switch {
	case ctrl && shift && base == sdl.K_V, shift && base == sdl.K_INSERT:
		clip := sdl.GetClipboardText()
		if clip == nil do return true
		defer sdl.free(clip)
		term.session_paste(s, string(cstring(clip)))
		return true
	case ctrl && shift && base == sdl.K_C:
		copy_selection(s)
		return true
	case ctrl && base == sdl.K_C && term.session_has_selection(s):
		// Like Windows Terminal: Ctrl+C copies a selection, else interrupts.
		copy_selection(s)
		term.session_clear_selection(s)
		return true
	}

	k, printable := term_key(key.scancode)
	if k == .Unidentified do return true
	// Plain typing arrives as TEXT_INPUT (which handles keyboard layouts and
	// IME composition); only keys with Ctrl/Alt, or non-text keys, are encoded
	// here. Ctrl+Alt is AltGr on Windows, which also produces text.
	alt := mods & term.MOD_ALT != {}
	if printable && (!ctrl && !alt || ctrl && alt) do return true
	unshifted := sdl.GetKeyFromScancode(key.scancode, {}, false)
	term.session_send_key(s, k, mods, key.repeat, unshifted < 0x110000 ? rune(unshifted) : 0)
	return true
}

@(private = "file")
copy_selection :: proc(s: ^term.Session) {
	text := term.session_selection_text(s)
	if text != "" do _ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

@(private = "file")
term_mods :: proc(m: sdl.Keymod) -> (mods: term.Mods) {
	if m & sdl.KMOD_SHIFT != {} do mods |= term.MOD_SHIFT
	if m & sdl.KMOD_CTRL != {} do mods |= term.MOD_CTRL
	if m & sdl.KMOD_ALT != {} do mods |= term.MOD_ALT
	if m & sdl.KMOD_GUI != {} do mods |= term.MOD_SUPER
	return
}

// Maps a physical key to libghostty-vt's key; `printable` keys produce text.
@(private = "file")
term_key :: proc(sc: sdl.Scancode) -> (k: term.Key, printable: bool) {
	#partial switch sc {
	case .A ..= .Z:       return term.Key(int(term.Key.A) + int(sc) - int(sdl.Scancode.A)), true
	case ._1 ..= ._9:     return term.Key(int(term.Key.Digit_1) + int(sc) - int(sdl.Scancode._1)), true
	case ._0:             return .Digit_0, true
	case .SPACE:          return .Space, true
	case .MINUS:          return .Minus, true
	case .EQUALS:         return .Equal, true
	case .LEFTBRACKET:    return .Bracket_Left, true
	case .RIGHTBRACKET:   return .Bracket_Right, true
	case .BACKSLASH:      return .Backslash, true
	case .SEMICOLON:      return .Semicolon, true
	case .APOSTROPHE:     return .Quote, true
	case .GRAVE:          return .Backquote, true
	case .COMMA:          return .Comma, true
	case .PERIOD:         return .Period, true
	case .SLASH:          return .Slash, true
	case .NONUSBACKSLASH: return .Intl_Backslash, true
	case .RETURN:         return .Enter, false
	case .ESCAPE:         return .Escape, false
	case .BACKSPACE:      return .Backspace, false
	case .TAB:            return .Tab, false
	case .INSERT:         return .Insert, false
	case .DELETE:         return .Delete, false
	case .HOME:           return .Home, false
	case .END:            return .End, false
	case .PAGEUP:         return .Page_Up, false
	case .PAGEDOWN:       return .Page_Down, false
	case .UP:             return .Arrow_Up, false
	case .DOWN:           return .Arrow_Down, false
	case .LEFT:           return .Arrow_Left, false
	case .RIGHT:          return .Arrow_Right, false
	case .F1 ..= .F12:    return term.Key(int(term.Key.F1) + int(sc) - int(sdl.Scancode.F1)), false
	case .KP_ENTER:       return .Numpad_Enter, false
	case .KP_DIVIDE:      return .Numpad_Divide, true
	case .KP_MULTIPLY:    return .Numpad_Multiply, true
	case .KP_MINUS:       return .Numpad_Subtract, true
	case .KP_PLUS:        return .Numpad_Add, true
	case .KP_PERIOD:      return .Numpad_Decimal, true
	case .KP_1 ..= .KP_9: return term.Key(int(term.Key.Numpad_1) + int(sc) - int(sdl.Scancode.KP_1)), true
	case .KP_0:           return .Numpad_0, true
	}
	return .Unidentified, false
}

// Mouse over the cell grid: selection, the wheel, and mouse reporting for
// programs that ask for it (vim, htop, ...). Holding Shift selects text even
// while a program has mouse reporting on.
terminal_mouse :: proc(t: ^Terminal, element: clay.ElementId) {
	s := &t.session
	rel := g.mouse_pos - {t.view.x, t.view.y}
	px := rel * g.ui_scale
	col := int(math.floor(rel.x / t.cell_w))
	row := int(math.floor(rel.y / t.cell_h))
	inside := pointer_in(element)
	mods := term_mods(sdl.GetModState())
	report := s.running && mods & term.MOD_SHIFT == {} && term.session_mouse_tracking(s)
	now := sdl.GetTicksNS()

	if g.mouse_pressed && inside {
		if report {
			t.reporting = true
			term.session_send_mouse(s, .Press, .Left, mods, px, true)
		} else {
			t.selecting = true
			term.session_select_event(s, .Press, col, row, {f64(px.x), f64(px.y)}, now)
		}
		t.last_cell = {col, row}
	}
	moved := [2]int{col, row} != t.last_cell
	switch {
	case t.selecting && g.mouse_down:
		if moved do term.session_select_event(s, .Drag, col, row, {f64(px.x), f64(px.y)}, now)
	case t.selecting:
		term.session_select_event(s, .Release, col, row, {f64(px.x), f64(px.y)}, now)
		t.selecting = false
	case t.reporting && !g.mouse_down:
		term.session_send_mouse(s, .Release, .Left, mods, px, false)
		t.reporting = false
	case report && inside && moved:
		// Motion with the button held, or hovering (any-event tracking).
		term.session_send_mouse(s, .Motion, t.reporting ? .Left : .Unknown, mods, px, t.reporting)
	}
	t.last_cell = {col, row}

	if !inside || g.wheel.y == 0 do return
	notches := int(math.round(g.wheel.y))
	if notches == 0 do notches = g.wheel.y > 0 ? 1 : -1
	switch {
	case report:
		for _ in 0 ..< abs(notches) do term.session_send_mouse(s, .Press, notches > 0 ? .Four : .Five, mods, px, t.reporting)
	case s.running && term.session_full_screen(s):
		// Full-screen programs without mouse support (less, man) get arrow keys.
		term.session_send_arrows(s, notches > 0, abs(notches) * 3)
	case:
		term.session_scroll(s, -notches * 3)
	}
}
