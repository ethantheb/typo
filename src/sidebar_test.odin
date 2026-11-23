package editor

import "core:strings"
import "core:sync"
import "core:testing"

import sdl "../vendor/sdl3"
import "fuzzy"

// The sidebar: the folders marked for unsaved files in them, and the search
// field's keys replayed through its handler over a small file index


@(test)
test_unsaved_marks :: proc(t: ^testing.T) {
	root := path_of({"", "w"})
	deep := path_of({root, "src", "gfx", "draw.odin"})
	top := path_of({root, "notes.md"})
	outside := path_of({"", "other", "x.txt"})

	marks := unsaved_marks(root, {deep, top, outside})

	// The files themselves, and every folder between them and the root
	testing.expect(t, marked(marks, deep))
	testing.expect(t, marked(marks, top))
	testing.expect(t, marked(marks, path_of({root, "src"})))
	testing.expect(t, marked(marks, path_of({root, "src", "gfx"})))

	// Not the root, nor folders outside it or beside the marked ones
	testing.expect(t, !marked(marks, root))
	testing.expect(t, !marked(marks, path_of({"", "other"})))
	testing.expect(t, !marked(marks, path_of({root, "src", "lsp"})))

	// Paths ignore case and either separator on Windows; a drive root works
	when ODIN_OS == .Windows {
		upper := unsaved_marks(`C:\`, {`C:/Proj/Src/A.odin`})
		testing.expect(t, marked(upper, `c:\proj\src`))
		testing.expect(t, marked(upper, `C:\PROJ`))
		testing.expect(t, !marked(upper, `C:\`))
	}
}


// A path from its parts, with the platform's separator
@(private = "file")
path_of :: proc(parts: []string) -> string {
	SEP :: "\\" when ODIN_OS == .Windows else "/"
	return strings.join(parts, SEP, context.temp_allocator)
}


@(private = "file")
marked :: proc(marks: map[string]bool, path: string) -> bool {
	buf: [512]u8
	return path_key_ascii(path, buf[:]) in marks
}


// With the popup open, typing filters the index, Up/Down move through the rows
// within their bounds, Backspace and Enter work, Escape empties the field and
// closes the popup, and a shortcut closes it and runs
@(test)
test_sidebar_search_keys :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	saved := g.settings.bindings
	saved_visible := g.sidebar_visible
	defer {
		g.settings.bindings = saved
		g.sidebar_visible = saved_visible
	}
	for cmd in Command do g.settings.bindings[cmd] = default_bindings(cmd)

	// A small index
	f := &g.finder
	for path in ([]string{"/w/src/sidebar.odin", "/w/src/main.odin", "/w/README.md"}) {
		append(&f.files, strings.clone(path))
	}
	f.root_len = len("/w/")
	s := &g.sidebar_search
	defer {
		for path in f.files do delete(path)
		delete(f.files)
		f.files = nil
		sidebar_search_destroy()
		s^ = {}
		fuzzy.destroy()
	}

	// Closed, the field doesn't take keys
	testing.expect(t, !send_text("s"))

	// Typing, with a slip taken back
	sidebar_search_open()
	for text in ([]string{"s", "i", "x"}) {
		testing.expect(t, send_text(text))
	}
	testing.expect(t, send_key(sdl.K_BACKSPACE))
	testing.expect(t, send_text("d"))
	testing.expect_value(t, line_edit_string(&s.field), "sid")
	testing.expect(t, s.open)

	// The search, as the frames run it
	query := line_edit_string(&s.field)
	for search_busy(&s.search) do search_step(&s.search, query)
	testing.expect(t, len(s.search.results) >= 1)
	if len(s.search.results) > 0 {
		testing.expect_value(t, f.files[s.search.results[0].index], "/w/src/sidebar.odin")
	}

	// A wider query has two rows; Up/Down stay within them
	testing.expect(t, send_key(sdl.K_BACKSPACE))
	testing.expect(t, send_key(sdl.K_BACKSPACE))
	testing.expect_value(t, s.search.scanned, 0) // started again
	query = line_edit_string(&s.field)
	for search_busy(&s.search) do search_step(&s.search, query)
	rows := len(s.search.results)
	testing.expect(t, rows >= 2)

	testing.expect(t, send_key(sdl.K_UP))
	testing.expect_value(t, s.selected, 0)
	for _ in 0 ..< rows + 2 do send_key(sdl.K_DOWN)
	testing.expect_value(t, s.selected, rows - 1)
	testing.expect(t, s.reveal)

	// Page Up goes to the first row
	testing.expect(t, send_key(sdl.K_PAGEUP))
	testing.expect_value(t, s.selected, 0)
	testing.expect(t, send_key(sdl.K_PAGEDOWN))
	testing.expect_value(t, s.selected, rows - 1)

	// Enter opens the selected file, next frame, empties the field and closes
	// the popup
	chosen := f.files[s.search.results[rows - 1].index]
	testing.expect(t, send_key(sdl.K_RETURN))
	opened, is_open := g.pending.(Open_File)
	testing.expect(t, is_open)
	if is_open {
		testing.expect_value(t, string(opened), chosen)
		delete(string(opened))
	}
	g.pending = nil
	testing.expect_value(t, len(s.field.text), 0)
	testing.expect(t, !s.open)
	testing.expect(t, !send_key(sdl.K_DOWN)) // the field doesn't have the keys

	// Escape empties the field and closes the popup
	sidebar_search_open()
	testing.expect(t, send_text("s"))
	testing.expect(t, send_key(sdl.K_ESCAPE))
	testing.expect_value(t, len(s.field.text), 0)
	testing.expect(t, !s.open)

	// A shortcut closes it and runs
	sidebar_search_open()
	visible := g.sidebar_visible
	testing.expect(t, send_chord(.B, sdl.KMOD_LCTRL)) // Toggle sidebar
	testing.expect(t, g.sidebar_visible != visible)
	testing.expect(t, !s.open)
}


@(private = "file")
send_text :: proc(text: string) -> bool {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(text, context.temp_allocator)
	return sidebar_search_handle_event(&event)
}


@(private = "file")
send_key :: proc(key: sdl.Keycode) -> bool {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	return sidebar_search_handle_event(&event)
}


// A shortcut, with the scancode the chords match on
@(private = "file")
send_chord :: proc(scancode: sdl.Scancode, mod: sdl.Keymod) -> bool {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.key = sdl.GetKeyFromScancode(scancode, {}, true)
	event.key.mod = mod
	return sidebar_search_handle_event(&event)
}
