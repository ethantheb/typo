package term

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// Run with: python build.py --test  (builds libghostty-vt first)

// Struct sizes and enum values must match the library's own manifest, or calls
// read and write the wrong memory.
@(test)
test_abi_matches_manifest :: proc(t: ^testing.T) {
	manifest, err := json.parse_string(string(type_json()), parse_integers = true)
	testing.expect(t, err == nil)
	defer json.destroy_value(manifest)
	types := manifest.(json.Object)["types"].(json.Object)

	check_size :: proc(t: ^testing.T, types: json.Object, name: string, size: int, loc := #caller_location) {
		desc, ok := types[name].(json.Object)
		testing.expectf(t, ok, "%s missing from manifest", name, loc = loc)
		if ok do testing.expectf(t, int(desc["size"].(json.Integer)) == size, "%s: size %v, ours %d", name, desc["size"], size, loc = loc)
	}
	check_size(t, types, "GhosttyColorRgb", size_of(Color_Rgb))
	check_size(t, types, "GhosttyStyleColor", size_of(Style_Color))
	check_size(t, types, "GhosttyStyle", size_of(Style))
	check_size(t, types, "GhosttyTerminalScrollViewport", size_of(Scroll_Viewport))
	check_size(t, types, "GhosttyRenderStateCursor", size_of(Render_Cursor))
	check_size(t, types, "GhosttyRenderStateColors", size_of(Render_Colors))
	check_size(t, types, "GhosttyRenderStateRowSelection", size_of(Row_Selection))
	check_size(t, types, "GhosttyMouseEncoderSize", size_of(Mouse_Encoder_Size))
	check_size(t, types, "GhosttyTerminalModeConfig", size_of(Mode_Config))
	check_size(t, types, "GhosttyPoint", size_of(Point))
	check_size(t, types, "GhosttyGridRef", size_of(Grid_Ref))
	check_size(t, types, "GhosttySelection", size_of(Selection))
	check_size(t, types, "GhosttyTerminalSelectionFormatOptions", size_of(Selection_Format_Options))
	check_size(t, types, "GhosttySurfacePosition", size_of(Surface_Position))
	check_size(t, types, "GhosttySelectionGestureGeometry", size_of(Gesture_Geometry))

	// Every named Key must have the value the library gives it.
	keys := types["GhosttyKey"].(json.Object)["values"].(json.Object)
	for k in Key {
		name := strings.to_upper(fmt.tprint(k), context.temp_allocator)
		v, ok := keys[name].(json.Integer)
		testing.expectf(t, ok && int(v) == int(k), "GhosttyKey %s: manifest %v, ours %d", name, keys[name], int(k))
	}
}

@(test)
test_render_cells :: proc(t: ^testing.T) {
	term: Terminal
	testing.expect(t, terminal_new(nil, &term, 40, 5) == .Success)
	defer terminal_free(term)
	s := "\x1b[31mhi\x1b[0m\r\nthere"
	terminal_vt_write(term, raw_data(s), len(s))

	rs: Render_State
	testing.expect(t, render_state_new(nil, &rs) == .Success)
	defer render_state_free(rs)
	testing.expect(t, render_state_update(rs, term) == .Success)

	cols: u16
	render_state_get(rs, .Cols, &cols)
	testing.expect_value(t, cols, 40)

	rows: Row_Iterator
	render_state_row_iterator_new(nil, &rows)
	defer render_state_row_iterator_free(rows)
	render_state_get(rs, .Row_Iterator, &rows)
	cells: Row_Cells
	render_state_row_cells_new(nil, &cells)
	defer render_state_row_cells_free(cells)

	texts: [2]strings.Builder
	defer for &b in texts do strings.builder_destroy(&b)
	first_style: Style
	for y in 0 ..< 2 {
		testing.expect(t, render_state_row_iterator_next(rows))
		render_state_row_get(rows, .Cells, &cells)
		x := 0
		for render_state_row_cells_next(cells) {
			n: u32
			render_state_row_cells_get(cells, .Graphemes_Len, &n)
			if n == 0 {x += 1; continue}
			cp: [8]u32
			render_state_row_cells_get(cells, .Graphemes_Buf, &cp)
			strings.write_rune(&texts[y], rune(cp[0]))
			if y == 0 && x == 0 {
				first_style = init_sized(Style)
				render_state_row_cells_get(cells, .Style, &first_style)
			}
			x += 1
		}
	}
	testing.expect_value(t, strings.to_string(texts[0]), "hi")
	testing.expect_value(t, strings.to_string(texts[1]), "there")
	testing.expect_value(t, first_style.fg_color.tag, Style_Color_Tag.Palette)
	testing.expect_value(t, first_style.fg_color.value.palette, 1)

	cursor := init_sized(Render_Cursor)
	render_state_get(rs, .Cursor, &cursor)
	testing.expect(t, cursor.viewport_has_value)
	testing.expect_value(t, cursor.viewport_x, 5)
	testing.expect_value(t, cursor.viewport_y, 1)
}

// Queries like DSR (cursor position report) are answered through Write_Pty.
@(test)
test_write_pty_reply :: proc(t: ^testing.T) {
	term: Terminal
	terminal_new(nil, &term, 20, 4)
	defer terminal_free(term)
	reply: strings.Builder
	defer strings.builder_destroy(&reply)
	terminal_set(term, .Userdata, &reply)
	on_write :: proc "c" (term: Terminal, userdata: rawptr, data: [^]u8, n: uint) {
		context = runtime.default_context()
		b := (^strings.Builder)(userdata)
		append(&b.buf, ..data[:n])
	}
	terminal_set(term, .Write_Pty, rawptr(Write_Pty_Fn(on_write)))
	s := "ab\x1b[6n"
	terminal_vt_write(term, raw_data(s), len(s))
	testing.expect_value(t, strings.to_string(reply), "\x1b[1;3R")
}

@(test)
test_key_encoding :: proc(t: ^testing.T) {
	enc: Key_Encoder
	key_encoder_new(nil, &enc)
	defer key_encoder_free(enc)
	ev: Key_Event
	key_event_new(nil, &ev)
	defer key_event_free(ev)

	encode :: proc(enc: Key_Encoder, ev: Key_Event, key: Key, mods: Mods) -> string {
		key_event_set_action(ev, .Press)
		key_event_set_key(ev, key)
		key_event_set_mods(ev, mods)
		buf: [32]u8
		n: uint
		key_encoder_encode(enc, ev, &buf[0], len(buf), &n)
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	testing.expect_value(t, encode(enc, ev, .Arrow_Up, {}), "\x1b[A")
	testing.expect_value(t, encode(enc, ev, .Enter, {}), "\r")
	key_event_set_unshifted_codepoint(ev, 'c')
	testing.expect_value(t, encode(enc, ev, .C, MOD_CTRL), "\x03")
}

// Reads the visible text of the active screen, one string per row.
@(private = "file")
screen_text :: proc(s: ^Session) -> []string {
	render_state_update(s.render, s.vt)
	render_state_get(s.render, .Row_Iterator, &s.row_iter)
	lines := make([dynamic]string, context.temp_allocator)
	for render_state_row_iterator_next(s.row_iter) {
		render_state_row_get(s.row_iter, .Cells, &s.cells)
		b := strings.builder_make(context.temp_allocator)
		for render_state_row_cells_next(s.cells) {
			n: u32
			render_state_row_cells_get(s.cells, .Graphemes_Len, &n)
			cp: [8]u32
			if n > 0 do render_state_row_cells_get(s.cells, .Graphemes_Buf, &cp)
			strings.write_rune(&b, n > 0 ? rune(cp[0]) : ' ')
		}
		append(&lines, strings.trim_right_space(strings.to_string(b)))
	}
	return lines[:]
}

// A real process on a pty: its output must reach the terminal grid, and its
// exit must be reported once all output is in.
@(test)
test_session_runs_command :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return
	s: Session
	noop :: proc "contextless" (userdata: rawptr) {}
	testing.expect(t, session_init(&s, 60, 10, noop, nil))
	defer session_destroy(&s)
	testing.expect(t, session_spawn(&s, "cmd.exe /c echo hello-from-pty", ""))

	exited := false
	deadline := time.tick_now()
	for !exited && time.tick_since(deadline) < 10 * time.Second {
		_, exited = session_pump(&s, 4 * time.Millisecond)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, exited, "process exit was not reported")
	found := false
	for line in screen_text(&s) do found ||= strings.contains(line, "hello-from-pty")
	testing.expect(t, found, "command output not on screen")
}

@(test)
test_selection_gestures :: proc(t: ^testing.T) {
	s: Session
	noop :: proc "contextless" (userdata: rawptr) {}
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	session_resize(&s, 20, 4, 10, 20)
	text := "hello world\r\nsecond line"
	terminal_vt_write(s.vt, raw_data(text), len(text))

	testing.expect(t, !session_has_selection(&s))
	session_select_event(&s, .Press, 0, 0, {2, 10}, 1_000_000)
	session_select_event(&s, .Drag, 4, 0, {46, 10}, 1_100_000)
	session_select_event(&s, .Release, 4, 0, {46, 10}, 1_200_000)
	testing.expect_value(t, session_selection_text(&s), "hello")

	// Two quick presses on "world" select the word.
	session_select_event(&s, .Press, 7, 0, {75, 10}, 5_000_000_000)
	session_select_event(&s, .Release, 7, 0, {75, 10}, 5_010_000_000)
	session_select_event(&s, .Press, 7, 0, {75, 10}, 5_100_000_000)
	testing.expect_value(t, session_selection_text(&s), "world")

	session_clear_selection(&s)
	testing.expect(t, !session_has_selection(&s))
}

// The cursor blinks by default; DECSCUSR can make it steady and back.
@(test)
test_cursor_blink_default :: proc(t: ^testing.T) {
	s: Session
	noop :: proc "contextless" (userdata: rawptr) {}
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	blinking :: proc(s: ^Session) -> bool {
		render_state_update(s.render, s.vt)
		c := init_sized(Render_Cursor)
		render_state_get(s.render, .Cursor, &c)
		return c.blinking
	}
	testing.expect(t, blinking(&s))
	steady := "\x1b[2 q"
	terminal_vt_write(s.vt, raw_data(steady), len(steady))
	testing.expect(t, !blinking(&s))
	reset := "\x1b[0 q"
	terminal_vt_write(s.vt, raw_data(reset), len(reset))
	testing.expect(t, blinking(&s))
}
