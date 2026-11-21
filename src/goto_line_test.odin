package editor

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

import "buffer"
import sdl "../vendor/sdl3"

// Go to line: reading what is typed, places clamped into the document, and
// the bar driven by keys (typing previews, Esc puts back, Enter jumps)


@(test)
test_goto_parse :: proc(t: ^testing.T) {
	Case :: struct {
		text:         string,
		line, column: int,
		ok:           bool,
	}
	cases := [?]Case {
		{"120", 120, 0, true},
		{"120:5", 120, 5, true},
		{" 7 , 3 ", 7, 3, true},
		{":42", 42, 0, true},
		{"0", 0, 0, true},
		{"99999999999999999999999", max(int), 0, true},
		{"", 0, 0, false},
		{"abc", 0, 0, false},
		{"12:", 0, 0, false},
		{"-3", 0, 0, false},
		{"1:2:3", 0, 0, false},
	}

	for c in cases {
		line, column, ok := goto_parse(c.text)
		testing.expectf(t, ok == c.ok, "%q: ok %v", c.text, ok)
		if !c.ok do continue

		testing.expectf(t, line == c.line, "%q: line %d", c.text, line)
		testing.expectf(t, column == c.column, "%q: column %d", c.text, column)
	}
}


@(test)
test_goto_offset :: proc(t: ^testing.T) {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone("one\ntwo\r\nhéllo"))
	defer buffer.buffer_destroy(&b)

	testing.expect_value(t, goto_offset(&b, 2, 0), 4)    // a line's start
	testing.expect_value(t, goto_offset(&b, 2, 3), 6)    // its third character
	testing.expect_value(t, goto_offset(&b, 2, 99), 7)   // a column past the end: before \r\n
	testing.expect_value(t, goto_offset(&b, 3, 3), 12)   // characters, not bytes: h é
	testing.expect_value(t, goto_offset(&b, 3, 6), 15)   // just past the last character
	testing.expect_value(t, goto_offset(&b, 0, 0), 0)    // before the first line: the first
	testing.expect_value(t, goto_offset(&b, 999, 0), 9)  // past the last: the last
	testing.expect_value(t, goto_offset(&b, max(int), max(int)), 15)
}


@(test)
test_grouped_counts :: proc(t: ^testing.T) {
	testing.expect_value(t, grouped(7), "7")
	testing.expect_value(t, grouped(120), "120")
	testing.expect_value(t, grouped(4032), "4,032")
	testing.expect_value(t, grouped(1234567), "1,234,567")
}


// Keys through the bar's handler: the text typed scrolls there with the caret,
// Esc puts caret and scroll back, Enter jumps (Go back would return)
@(test)
test_goto_line_keys :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	// An editor of 200 lines "line N", focused, the caret on line 10
	sb := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 200 do fmt.sbprintf(&sb, "line %d\n", i)

	e := new(Editor)
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(strings.to_string(sb)))
	e.status = .Text
	e.kind = &TEXT_KIND
	e.path = "/w/lines.txt"
	line_10 := buffer.line_start(&e.buf, 9)
	append(&e.sels, Selection{line_10, line_10, -1})
	e.target_y = 123

	pane := Pane{content = e}
	g.panes.focused = &pane
	defer {
		goto_line_destroy()
		g.goto_line = {}
		g.panes.focused = nil
		jumps_destroy()
		g.jumps = {}
		if path, ok := g.pending.(Open_File); ok {
			delete(string(path))
		}
		g.pending = nil
		g.open_target = nil
		buffer.buffer_destroy(&e.buf)
		delete(e.sels)
		free(e)
	}

	// Typing previews: the caret on the line, to be shown in the middle
	testing.expect(t, run_command(.Go_To_Line), "no bar on the focused editor")
	type_goto("50")
	line_50 := buffer.line_start(&e.buf, 49)
	testing.expect_value(t, e.sels[e.primary], Selection{line_50, line_50, -1})
	testing.expect(t, e.reveal && e.center, "the line isn't revealed in the middle")

	// Backspace to nothing goes back; out of range clamps
	press_goto(sdl.K_BACKSPACE)
	press_goto(sdl.K_BACKSPACE)
	testing.expect_value(t, e.sels[e.primary].head, line_10)
	type_goto("9000")
	last := buffer.line_start(&e.buf, buffer.line_count(&e.buf) - 1)
	testing.expect_value(t, e.sels[e.primary].head, last)

	// Esc: where it was, scroll too
	e.target_y = 9999
	press_goto(sdl.K_ESCAPE)
	testing.expect(t, !g.goto_line.open, "Esc leaves the bar open")
	testing.expect_value(t, e.sels[e.primary], Selection{line_10, line_10, -1})
	testing.expect_value(t, e.target_y, 123)

	// Enter: the jump from line 10 is recorded, and the file opens at the place
	run_command(.Go_To_Line)
	type_goto("70:3")
	press_goto(sdl.K_RETURN)
	testing.expect(t, !g.goto_line.open, "Enter leaves the bar open")
	testing.expect_value(t, len(g.jumps.back), 1)
	if len(g.jumps.back) == 1 {
		testing.expect_value(t, g.jumps.back[0].offset, line_10)
	}
	target, has_target := g.open_target.?
	testing.expect(t, has_target, "no place to open at")
	want := buffer.line_start(&e.buf, 69) + 2
	testing.expect_value(t, target.(int) or_else -1, want)
}


@(private = "file")
type_goto :: proc(text: string) {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(text, context.temp_allocator)
	goto_line_handle_event(&event)
}


@(private = "file")
press_goto :: proc(key: sdl.Keycode) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	goto_line_handle_event(&event)
}
