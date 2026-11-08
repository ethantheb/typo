package editor

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "buffer"
import "markdown"
import sdl "../vendor/sdl3"
import "textedit"
import "mdview"

// Tests of a Markdown file in the app's editor; the rendered view's own tests
// are in package mdview


// Held by tests that set the global mouse state (tests run on several threads)
@(private = "file")
mouse_lock: sync.Mutex


// An editor on a Markdown document, shown rendered, with the caret at the "|"
// in `text`
@(private = "file")
md_editor_at :: proc(text: string) -> ^Editor {
	g.settings.font_size = 15
	g.settings.line_height = 1.35
	g.settings.markdown_font_size = 16
	g.settings.markdown_line_height = 1.5
	g.settings.markdown_max_width = 0
	md_env_init()

	// The document without the "|"
	at := strings.index_byte(text, '|')
	e := new(Editor)
	editor_attach(e)
	doc := strings.concatenate({text[:at], text[at + 1:]})
	buffer.buffer_init(&e.buf, transmute([]u8)doc)
	e.status = .Text
	append(&e.sels, Selection{at, at, -1})

	// Parsed, and shown rendered
	e.md = new(markdown.Doc)
	markdown.doc_open(e.md, &e.buf)
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
	mdview.attach(&e.md_view, e, e.md, &TEXT_KIND, .Rendered)
	e.md_view.mdv.caretless = false
	e.view = {0, 0, 400 + 2 * mdview.COLUMN_PAD, 300}
	return e
}


@(private = "file")
destroy_md_editor :: proc(e: ^Editor) {
	editor_destroy(e)
	free(e)
}


@(private = "file")
expect_after :: proc(t: ^testing.T, e: ^Editor, want: string, loc := #caller_location) {
	got := string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
	at := e.sels[0].head
	with_caret := strings.concatenate({got[:at], "|", got[at:]}, context.temp_allocator)
	testing.expect_value(t, with_caret, want, loc = loc)
}


@(private = "file")
press :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod = {}) {
	editor_handle_key(e, {key = key, mod = mod})
}


// Switching to the text view makes it edit like any other file
@(test)
test_md_text_view_plain_keys :: proc(t: ^testing.T) {
	e := md_editor_at("- a\n  - |")
	defer destroy_md_editor(e)

	mdview.set_mode(&e.md_view, .Text)
	testing.expect(t, e.kind == &TEXT_KIND)

	press(e, sdl.K_RETURN)
	expect_after(t, e, "- a\n  - \n  |")
	press(e, sdl.K_TAB)
	expect_after(t, e, "- a\n  - \n  \t|")
	press(e, sdl.K_TAB, sdl.KMOD_SHIFT)
	expect_after(t, e, "- a\n  - \n  \t|")
	press(e, sdl.K_BACKSPACE)
	press(e, sdl.K_BACKSPACE)
	expect_after(t, e, "- a\n  - \n |")

	mdview.set_mode(&e.md_view, .Rendered)
	testing.expect(t, e.kind == &mdview.KIND)
}


// No caret is drawn while a selection is being dragged, but one is while the
// button is still down after a press that hasn't moved
@(test)
test_md_no_caret_while_dragging :: proc(t: ^testing.T) {
	e := md_editor_at("Some **bold** |text.")
	defer destroy_md_editor(e)
	sync.guard(&mouse_lock)

	// The editor focused in a pane
	pane := Pane{content = e}
	focused := g.panes.focused
	defer g.panes.focused, g.mouse_down = focused, false
	g.panes.focused = &pane

	e.dragging, g.mouse_down = true, true
	testing.expect(t, editor_caret_on(e))

	e.drag_moved = true
	testing.expect(t, !editor_caret_on(e))

	g.mouse_down = false
	testing.expect(t, editor_caret_on(e))
}


// With the caret hidden, Copy and Cut do nothing, a command that selects
// shows the caret, and typing shows it and types there
@(test)
test_md_hidden_caret_commands :: proc(t: ^testing.T) {
	e := md_editor_at("# Title\n\nSome |text.")
	defer destroy_md_editor(e)

	// Commands
	e.md_view.mdv.caretless = true
	testing.expect(t, editor_run_command(e, .Cut))
	expect_after(t, e, "# Title\n\nSome |text.")
	testing.expect(t, textedit.caret_hidden(e))
	testing.expect(t, editor_run_command(e, .Select_All))
	testing.expect(t, !textedit.caret_hidden(e))
	testing.expect_value(t, e.sels[0], Selection{0, buffer.length(&e.buf), -1})

	// Typing
	e.md_view.mdv.caretless = true
	editor_text_input(e, "x")
	testing.expect(t, !textedit.caret_hidden(e))
	expect_after(t, e, "x|")

	editor_run_command(e, .Undo)
	got := string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
	testing.expect_value(t, got, "# Title\n\nSome text.")
}


// Keys and typing through the app's handlers reach the rendered view's editing
@(test)
test_md_app_typing :: proc(t: ^testing.T) {
	e := md_editor_at("- a|")
	defer destroy_md_editor(e)

	press(e, sdl.K_RETURN)
	editor_text_input(e, "b")
	expect_after(t, e, "- a\n- b|")

	press(e, sdl.K_TAB)
	expect_after(t, e, "- a\n  - b|")
}


// Every kind of view has the procs it needs
@(test)
test_kinds_complete :: proc(t: ^testing.T) {
	testing.expect_value(t, textedit.missing_proc(&TEXT_KIND), "")
	testing.expect_value(t, textedit.missing_proc(&mdview.KIND), "")
}
