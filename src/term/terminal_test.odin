package term

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"

import "../herdr"

// Run with: python build.py --test  (builds libghostty-vt first)


// Struct sizes and enum values must match the library's own manifest, or calls
// read and write the wrong memory
@(test)
test_abi_matches_manifest :: proc(t: ^testing.T) {
	manifest, err := json.parse_string(string(type_json()), parse_integers = true)
	testing.expect(t, err == nil)
	defer json.destroy_value(manifest)
	types := manifest.(json.Object)["types"].(json.Object)

	// Struct sizes
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
	check_size(t, types, "GhosttySelectionBuffer", size_of(Selection_Buffer))
	check_size(t, types, "GhosttyPointCoordinate", size_of(Point_Coordinate))
	check_size(t, types, "GhosttyString", size_of(Ghostty_String))
	check_size(t, types, "GhosttySurfacePosition", size_of(Surface_Position))
	check_size(t, types, "GhosttySelectionGestureGeometry", size_of(Gesture_Geometry))
	check_size(t, types, "GhosttyCodepointBuffer", size_of(Codepoint_Buffer))
	check_size(t, types, "GhosttyTerminalScrollbar", size_of(Terminal_Scrollbar))

	// Every value of the enums we bind must be the one the library gives it
	check_enum(t, types, "GhosttyResult", Result)
	check_enum(t, types, "GhosttyStyleColorTag", Style_Color_Tag)
	check_enum(t, types, "GhosttyCellWide", Cell_Wide)
	check_enum(t, types, "GhosttyCellData", Cell_Data)
	check_enum(t, types, "GhosttyTerminalOption", Terminal_Option)
	check_enum(t, types, "GhosttyTerminalData", Terminal_Data)
	check_enum(t, types, "GhosttyTerminalScrollViewportTag", Scroll_Viewport_Tag)
	check_enum(t, types, "GhosttyRenderStateDirty", Render_Dirty)
	check_enum(t, types, "GhosttyCursorStyle", Cursor_Visual_Style)
	check_enum(t, types, "GhosttyRenderStateData", Render_Data)
	check_enum(t, types, "GhosttyRenderStateRowData", Row_Data)
	check_enum(t, types, "GhosttyRenderStateRowCellsData", Row_Cells_Data)
	check_enum(t, types, "GhosttyPointTag", Point_Tag)
	check_enum(t, types, "GhosttyFormatterFormat", Formatter_Format)
	check_enum(t, types, "GhosttyFormatterOption", Formatter_Option)
	check_enum(t, types, "GhosttySearchStatus", Search_Status)
	check_enum(t, types, "GhosttySearchData", Search_Data)
	check_enum(t, types, "GhosttySearchOption", Search_Option)
	check_enum(t, types, "GhosttySelectionGestureEventType", Gesture_Event_Type)
	check_enum(t, types, "GhosttySelectionGestureEventOption", Gesture_Event_Option)
	check_enum(t, types, "GhosttyKeyAction", Key_Action)
	check_enum(t, types, "GhosttyKey", Key)
	check_enum(t, types, "GhosttyMouseAction", Mouse_Action)
	check_enum(t, types, "GhosttyMouseButton", Mouse_Button)
	check_enum(t, types, "GhosttyMouseEncoderOption", Mouse_Encoder_Option)
}


// Each named value of E must be in the manifest's enum `name` with the same
// value (Odin's Ab_Cd is the manifest's AB_CD)
@(private = "file")
check_enum :: proc(
	t: ^testing.T,
	types: json.Object,
	name: string,
	$E: typeid,
	loc := #caller_location,
) {
	desc, found := types[name].(json.Object)
	testing.expectf(t, found, "%s missing from manifest", name, loc = loc)
	if !found do return

	values := desc["values"].(json.Object)
	for field in reflect.enum_fields_zipped(E) {
		key := strings.to_upper(field.name, context.temp_allocator)
		v, ok := values[key].(json.Integer)
		testing.expectf(
			t,
			ok && int(v) == int(field.value),
			"%s %s: manifest %v, ours %d",
			name,
			key,
			values[key],
			int(field.value),
			loc = loc,
		)
	}
}


@(private = "file")
check_size :: proc(
	t: ^testing.T,
	types: json.Object,
	name: string,
	size: int,
	loc := #caller_location,
) {
	desc, ok := types[name].(json.Object)
	testing.expectf(t, ok, "%s missing from manifest", name, loc = loc)
	if ok {
		testing.expectf(
			t,
			int(desc["size"].(json.Integer)) == size,
			"%s: size %v, ours %d",
			name,
			desc["size"],
			size,
			loc = loc,
		)
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

	// The text of the first two rows, and the style of the first cell
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
			if n == 0 {
				x += 1
				continue
			}

			cp: [8]u32
			graphemes := Codepoint_Buffer{&cp[0], len(cp), 0}
			render_state_row_cells_get(cells, .Graphemes_Buf, &graphemes)
			strings.write_rune(&texts[y], rune(cp[0]))
			if y == 0 && x == 0 {
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


// Queries like DSR (cursor position report) are answered through Write_Pty
@(test)
test_write_pty_reply :: proc(t: ^testing.T) {
	term: Terminal
	terminal_new(nil, &term, 20, 4)
	defer terminal_free(term)

	reply: strings.Builder
	defer strings.builder_destroy(&reply)
	terminal_set(term, .Userdata, &reply)
	terminal_set(term, .Write_Pty, rawptr(Write_Pty_Fn(on_write)))

	s := "ab\x1b[6n"
	terminal_vt_write(term, raw_data(s), len(s))
	testing.expect_value(t, strings.to_string(reply), "\x1b[1;3R")
}


// Appends what the terminal writes to the builder in userdata
@(private = "file")
on_write :: proc "c" (term: Terminal, userdata: rawptr, data: [^]u8, n: uint) {
	context = runtime.default_context()
	b := (^strings.Builder)(userdata)
	append(&b.buf, ..data[:n])
}


@(test)
test_key_encoding :: proc(t: ^testing.T) {
	enc: Key_Encoder
	key_encoder_new(nil, &enc)
	defer key_encoder_free(enc)
	ev: Key_Event
	key_event_new(nil, &ev)
	defer key_event_free(ev)

	testing.expect_value(t, encode(enc, ev, .Arrow_Up, {}), "\x1b[A")
	testing.expect_value(t, encode(enc, ev, .Enter, {}), "\r")
	key_event_set_unshifted_codepoint(ev, 'c')
	testing.expect_value(t, encode(enc, ev, .C, MOD_CTRL), "\x03")
}


// The bytes a key press encodes to
@(private = "file")
encode :: proc(enc: Key_Encoder, ev: Key_Event, key: Key, mods: Mods) -> string {
	key_event_set_action(ev, .Press)
	key_event_set_key(ev, key)
	key_event_set_mods(ev, mods)

	buf: [32]u8
	n: uint
	key_encoder_encode(enc, ev, &buf[0], len(buf), &n)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}


// Reads the visible text of the active screen, one string per row
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
			graphemes := Codepoint_Buffer{&cp[0], len(cp), 0}
			if n > 0 do render_state_row_cells_get(s.cells, .Graphemes_Buf, &graphemes)
			strings.write_rune(&b, n > 0 ? rune(cp[0]) : ' ')
		}
		append(&lines, strings.trim_right_space(strings.to_string(b)))
	}
	return lines[:]
}


// A wake callback for sessions that need none
@(private = "file")
noop :: proc "contextless" (userdata: rawptr) {}


// A real process on a pty: its output must reach the terminal grid, and its
// exit must be reported once all output is in
@(test)
test_session_runs_command :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	s: Session
	testing.expect(t, session_init(&s, 60, 10, noop, nil))
	defer session_destroy(&s)
	testing.expect(t, session_spawn(&s, "cmd.exe /c echo hello-from-pty", ""))

	// Pump until the exit is reported
	exited := false
	deadline := time.tick_now()
	for !exited && time.tick_since(deadline) < 10 * time.Second {
		exited = session_pump(&s, 4 * time.Millisecond).ended
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, exited, "process exit was not reported")

	found := false
	for line in screen_text(&s) {
		found ||= strings.contains(line, "hello-from-pty")
	}
	testing.expect(t, found, "command output not on screen")
}


// A shell at its prompt runs no program; one it starts is found under it by
// name, and is gone once it ends
@(test)
test_programs_under :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	s: Session
	testing.expect(t, session_init(&s, 80, 10, noop, nil))
	defer session_destroy(&s)
	testing.expect(t, session_spawn(&s, "cmd.exe /q /k", ""))

	pid := session_pid(&s)
	testing.expect(t, pid > 0)
	testing.expect_value(t, len(programs_under(pid, context.temp_allocator)), 0)

	// A program, once it has started
	command := "ping -n 3 127.0.0.1\r"
	session_input(&s, transmute([]u8)command)
	testing.expect(t, wait_for_ping(pid, true), "ping isn't found under the shell")

	// It ends on its own after about 2 s
	testing.expect(t, wait_for_ping(pid, false), "ping is still found once it ended")
	session_kill(&s)
}


// Waits up to 10 s for ping to be found under `pid`, or not to be
@(private = "file")
wait_for_ping :: proc(pid: int, running: bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 10 * time.Second {
		found := false
		for name in programs_under(pid, context.temp_allocator) {
			found ||= strings.equal_fold(name, "ping")
		}
		if found == running do return true

		time.sleep(50 * time.Millisecond)
	}
	return false
}


// Variables given to session_spawn reach the shell (replacing one of the same
// name), and typo's own environment stays as it was
@(test)
test_session_environment :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	os.set_env("TYPO_TEST_REPLACED", "old")
	defer os.unset_env("TYPO_TEST_REPLACED")

	s: Session
	testing.expect(t, session_init(&s, 80, 10, noop, nil))
	defer session_destroy(&s)
	env := []string{"TYPO_TEST_VAR=from-typo", "typo_test_replaced=new"}
	command := "cmd.exe /c echo [%TYPO_TEST_VAR%] [%TYPO_TEST_REPLACED%] [%COLORTERM%]"
	testing.expect(t, session_spawn(&s, command, "", env = env))

	exited := false
	deadline := time.tick_now()
	for !exited && time.tick_since(deadline) < 10 * time.Second {
		exited = session_pump(&s, 4 * time.Millisecond).ended
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, exited, "process exit was not reported")

	found := false
	for line in screen_text(&s) {
		found ||= strings.contains(line, "[from-typo] [new] [truecolor]")
	}
	testing.expect(t, found, "the variables are not in the shell's environment")

	own := os.get_env("TYPO_TEST_VAR", context.temp_allocator)
	testing.expect(t, own == "", "typo's own environment changed")
}


@(test)
test_selection_gestures :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	session_resize(&s, 20, 4, 10, 20)
	text := "hello world\r\nsecond line"
	terminal_vt_write(s.vt, raw_data(text), len(text))

	// A drag across "hello"
	testing.expect(t, !session_has_selection(&s))
	session_select_event(&s, .Press, 0, 0, {2, 10}, 1_000_000)
	session_select_event(&s, .Drag, 4, 0, {46, 10}, 1_100_000)
	session_select_event(&s, .Release, 4, 0, {46, 10}, 1_200_000)
	testing.expect_value(t, session_selection_text(&s), "hello")

	// Two quick presses on "world" select the word
	session_select_event(&s, .Press, 7, 0, {75, 10}, 5_000_000_000)
	session_select_event(&s, .Release, 7, 0, {75, 10}, 5_010_000_000)
	session_select_event(&s, .Press, 7, 0, {75, 10}, 5_100_000_000)
	testing.expect_value(t, session_selection_text(&s), "world")

	session_clear_selection(&s)
	testing.expect(t, !session_has_selection(&s))
}


// The cursor blinks by default; DECSCUSR can make it steady and back
@(test)
test_cursor_blink_default :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	testing.expect(t, cursor_blinks(&s))

	steady := "\x1b[2 q"
	terminal_vt_write(s.vt, raw_data(steady), len(steady))
	testing.expect(t, !cursor_blinks(&s))

	reset := "\x1b[0 q"
	terminal_vt_write(s.vt, raw_data(reset), len(reset))
	testing.expect(t, cursor_blinks(&s))
}


@(private = "file")
cursor_blinks :: proc(s: ^Session) -> bool {
	render_state_update(s.render, s.vt)
	c := init_sized(Render_Cursor)
	render_state_get(s.render, .Cursor, &c)
	return c.blinking
}


// On Windows, growing taller adds blank rows at the bottom, as ConPTY does,
// instead of pulling scrollback down: the cursor keeps its row
@(test)
test_grow_keeps_cursor_row :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	text := "a\r\nb\r\nc\r\nd\r\ne\r\nf"
	terminal_vt_write(s.vt, raw_data(text), len(text))
	session_resize(&s, 20, 8, 10, 20)

	render_state_update(s.render, s.vt)
	c := init_sized(Render_Cursor)
	render_state_get(s.render, .Cursor, &c)
	testing.expect_value(t, c.viewport_y, 3)

	lines := screen_text(&s)
	testing.expect_value(t, lines[0], "c")
	testing.expect_value(t, lines[4], "")
}


// On Windows, a narrower terminal rewraps lines without their trailing spaces,
// as ConPTY does: PowerShell pads table output to the full width, and those
// spaces must not become extra rows here
@(test)
test_narrow_trims_trailing_spaces :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows || !GHOSTTY_PATCHED {
		return
	}

	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	text := "abcdefg            \r\nx"
	terminal_vt_write(s.vt, raw_data(text), len(text))
	session_resize(&s, 5, 4, 10, 20)

	render_state_update(s.render, s.vt)
	c := init_sized(Render_Cursor)
	render_state_get(s.render, .Cursor, &c)
	testing.expect_value(t, c.viewport_y, 2)

	lines := screen_text(&s)
	testing.expect_value(t, lines[0], "abcde")
	testing.expect_value(t, lines[1], "fg")
	testing.expect_value(t, lines[2], "x")
}


// ConPTY keeps the cursor's row up to the cursor when it rewraps (a prompt
// ending in a space): the cursor lands where ConPTY puts it
@(test)
test_narrow_keeps_cursor_after_spaces :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	text := "READY\r\nabcdefg     "
	terminal_vt_write(s.vt, raw_data(text), len(text))
	session_resize(&s, 5, 4, 10, 20)

	render_state_update(s.render, s.vt)
	c := init_sized(Render_Cursor)
	render_state_get(s.render, .Cursor, &c)
	testing.expect_value(t, c.viewport_y, 3)
	testing.expect_value(t, c.viewport_x, 2)
}


// A remote terminal's repaint starts from a reset terminal: the scrollback
// it had is gone, so the repaint's history isn't shown twice
@(test)
test_reset_clears_scrollback :: proc(t: ^testing.T) {
	s: Session
	session_init(&s, 20, 4, noop, nil)
	defer session_destroy(&s)
	for i in 0 ..< 30 {
		line := fmt.tprintf("line %d\r\n", i)
		terminal_vt_write(s.vt, raw_data(line), len(line))
	}
	testing.expect(t, scrollback_rows(&s) > 4, "lines scrolled off")

	terminal_reset(s.vt)
	testing.expect_value(t, scrollback_rows(&s), 4)
	testing.expect_value(t, screen_text(&s)[0], "")
}


@(private = "file")
scrollback_rows :: proc(s: ^Session) -> u64 {
	bar: Terminal_Scrollbar
	terminal_get(s.vt, .Scrollbar, &bar)
	return bar.total
}


// A persistent terminal in a private herdr-core session: its output reaches
// the grid, and once typo let go of it and attached again, the screen and its
// history come back. Skipped when herdr-core isn't installed
@(test)
test_remote_session_reattach :: proc(t: ^testing.T) {
	sb: herdr.Sandbox
	ok, why := herdr.sandbox_begin(&sb, "typo-herdr-test")
	if !ok {
		log.infof("skipped: %s", why)
		return
	}
	defer herdr.sandbox_end(&sb)

	client: herdr.Client
	herdr.client_start(&client, {"typo=1"}, noop, nil)
	defer herdr.client_stop(&client)

	when ODIN_OS == .Windows {
		spec := herdr.Spec{argv = {"cmd.exe", "/q", "/k", "prompt $G"}, labels = {"typo=1"}}
		rows := "for /l %i in (1,1,40) do @echo row %i\r"
	} else {
		spec := herdr.Spec{argv = {"/bin/sh"}, labels = {"typo=1"}}
		rows := "for i in $(seq 1 40); do echo row $i; done\n"
	}
	display := herdr.Display{fg = "#ffffff", bg = "#000000", cursor = "#ffffff"}

	// A new terminal prints 40 rows
	s: Session
	session_init(&s, 60, 10, noop, nil)
	session_resize(&s, 60, 10, 9, 18)
	session_start_remote(&s, &client, spec, display, 1000)
	testing.expect(t, pump_until_shown(&s, ">"), "the shell's prompt never showed")
	session_input(&s, transmute([]u8)rows)
	testing.expect(t, pump_until_shown(&s, "row 40"), "the output never showed")
	address := strings.clone(session_remote_address(&s))
	defer delete(address)
	testing.expect(t, address != "", "no address")

	// Let go of it (typo quitting), and show it again
	session_destroy(&s)
	again: Session
	session_init(&again, 60, 10, noop, nil)
	defer session_destroy(&again)
	session_resize(&again, 60, 10, 9, 18)
	session_attach_remote(&again, &client, address, "", display, 1000)
	testing.expect(t, pump_until_shown(&again, "row 40"), "the screen didn't come back")
	testing.expect(t, scrollback_rows(&again) > 30, "the history didn't come back")

	// Its first rows are in the history
	terminal_scroll_viewport(again.vt, {tag = .Top})
	found := false
	for line in screen_text(&again) {
		if line == "row 1" do found = true
	}
	testing.expect(t, found, "row 1 isn't in the history")

	// Closing it ends it in herdr-core
	session_kill(&again)
	testing.expect(t, !again.running)
}


// Pumps until a row of the screen contains `text`; false after 20 seconds
@(private = "file")
pump_until_shown :: proc(s: ^Session, text: string) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 20 * time.Second {
		_ = session_pump(s, 4 * time.Millisecond)
		for line in screen_text(s) {
			if strings.contains(line, text) do return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}



// A persistent terminal resized after its screen filled (taller, shorter,
// narrower so its lines rewrap, and back): what the shell draws next lands
// where it means, right under the line typed. herdr-core's live output is its
// ConPTY's, so the screen here must resize as ConPTY's does. Skipped without
// herdr-core
@(test)
test_remote_resize_keeps_rows :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows do return

	sb: herdr.Sandbox
	ok, why := herdr.sandbox_begin(&sb, "typo-herdr-resize")
	if !ok {
		log.infof("skipped: %s", why)
		return
	}
	defer herdr.sandbox_end(&sb)

	client: herdr.Client
	herdr.client_start(&client, {"typo=1"}, noop, nil)
	defer herdr.client_stop(&client)

	// Sizes after the screen fills, from 60 x 10
	resizes := [][]Resize{
		{{60, 20}},
		{{60, 5}, {60, 20}},
		{{25, 10}, {60, 10}},
		{{25, 6}, {70, 20}},
	}
	for steps, n in resizes {
		spec := herdr.Spec{argv = {"cmd.exe", "/q", "/k", "prompt $G"}, labels = {"typo=1"}}
		display := herdr.Display{fg = "#ffffff", bg = "#000000", cursor = "#ffffff"}
		s: Session
		session_init(&s, 60, 10, noop, nil)
		defer session_destroy(&s)
		session_resize(&s, 60, 10, 9, 18)
		session_start_remote(&s, &client, spec, display, 1000)
		testing.expect(t, pump_until_shown(&s, ">"), "the shell's prompt never showed")

		// A full screen of long lines, then the resizes
		rows := "for /l %i in (1,1,30) do @echo row %i is a fairly long line of text\r"
		session_input(&s, transmute([]u8)rows)
		testing.expect(t, pump_until_shown(&s, "row 30"), "the output never showed")
		for size in steps {
			session_resize(&s, size.cols, size.rows, 9, 18)
			pump_for(&s, 1200 * time.Millisecond)
		}

		// The next command, and its output right under it
		mark := fmt.tprintf("MARK-%d", n)
		command := fmt.tprintf("echo %s\r", mark)
		session_input(&s, transmute([]u8)command)
		pump_for(&s, 1500 * time.Millisecond)

		lines := screen_text(&s)
		typed, output := -1, -1
		for line, i in lines {
			if strings.contains(line, fmt.tprintf("echo %s", mark)) do typed = i
			if strings.trim_space(line) == mark do output = i
		}
		screen := strings.join(lines, "\n", context.temp_allocator)
		ok := typed >= 0 && output == typed + 1
		testing.expectf(
			t,
			ok,
			"resizes %v: typed on row %d, output on %d:\n%s",
			steps,
			typed,
			output,
			screen,
		)
		session_kill(&s)
	}
}


@(private = "file")
Resize :: struct {
	cols, rows: u16,
}


// Pumps output for `d`
@(private = "file")
pump_for :: proc(s: ^Session, d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		_ = session_pump(s, 4 * time.Millisecond)
		time.sleep(10 * time.Millisecond)
	}
}

