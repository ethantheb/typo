package editor

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "buffer"
import "markdown"
import "syntax"
import sdl "../vendor/sdl3"
import "textedit"
import "mdview"

// Editing state for one open file. All edits go through `textedit.apply`, which
// works on every selection at once, so multi-cursor is the general case and a
// single caret is just a list of one


Selection :: buffer.Selection

Editor :: struct {
	// The document, its selections and scroll position, and the kind of view
	// it is shown in: TEXT_KIND, or mdview.KIND for a rendered Markdown file
	using tv: textedit.View,
	hl:       syntax.Highlighter,
	md:       ^markdown.Doc, // block structure of a Markdown file, else nil
	md_view:  mdview.View,   // the rendered view of a Markdown file
	new_file: bool,          // path doesn't exist yet; the first save creates it
	status:   File_Status,

	// View state, in logical pixels. The scroll position is in tv; it eases
	// toward its target (see editor_animate)
	scrollbar_drag: Maybe(f32), // grab offset within the thumb while dragging it
	char_w:         f32,        // monospace advance of the editor font
	gutter_w:       f32,

	// Set once laid out at its real size with nothing in view still loading
	// (editor_ready); until then the pane is drawn empty
	shown:     bool,
	opened_at: u64, // ticks

	dragging:    bool,
	drag_mode:   enum {
		Char,
		Word,
		Line,
		Block, // a triple click on what the view selects instead of the line (a table cell)
	},
	drag_origin: Selection, // selection made by the initial click, for word/line/block drag
	drag_from:   [2]f32,    // where the press was; the drag starts once the pointer leaves it
	drag_moved:  bool,      // the pointer has left drag_from since the press

	// The primary caret's line and visual column, cached: on a long line the
	// column takes a scan from the line start
	caret_pos: struct {
		head, line, col: int,
		version:         u64,
	},
}

File_Status :: enum {
	None,
	Text,
	Binary,
	Error,
}


// The editor whose view tv is
editor_of :: proc(tv: ^textedit.View) -> ^Editor {
	return container_of(tv, Editor, "tv")
}


// Sets up an editor's view as the text view, with its edits passed on. Call
// after editor_close, which clears it
editor_attach :: proc(e: ^Editor) {
	e.kind = &TEXT_KIND
	e.on_edit = editor_on_edit
}


// Passes the buffer's edits to the highlighter and the Markdown structure
@(private = "file")
editor_on_edit :: proc(v: ^textedit.View, changes: []buffer.Change) {
	e := editor_of(v)
	syntax.highlighter_update(&e.hl, &e.buf, changes)

	if e.md != nil {
		markdown.doc_edit(e.md, changes)
		mdview.edit(&e.md_view, changes)
	}
}


// --- Open / save -------------------------------------------------------------------

editor_open :: proc(e: ^Editor, path: string) {
	editor_close(e)
	editor_attach(e)
	e.path = strings.clone(path)

	// Read the file
	data: []u8
	if os.exists(path) {
		err: os.Error
		data, err = os.read_entire_file(path, context.allocator)
		if err != nil {
			e.status = .Error
			return
		}

		// Anything with a NUL byte in its first 8KB is binary
		if slice.contains(data[:min(len(data), 8192)], 0) {
			delete(data)
			e.status = .Binary
			return
		}
	} else {
		// A path that doesn't exist opens as an empty, unsaved file
		e.new_file = true
	}

	// The document, its highlighting and Markdown structure
	buffer.buffer_init(&e.buf, data)
	syntax.highlighter_open(&e.hl, &e.buf, path)
	if is_markdown_path(path) {
		e.md = new(markdown.Doc)
		markdown.doc_open(e.md, &e.buf)
		mdview.attach(&e.md_view, e, e.md, &TEXT_KIND, md_initial_mode(e))
	}

	e.status = .Text
	e.opened_at = sdl.GetTicksNS()
	append(&e.sels, Selection{0, 0, -1})
}


// Whether a Markdown file is shown rendered
md_rendered :: proc(e: ^Editor) -> bool {
	return e.md != nil && mdview.rendered(&e.md_view)
}


// The mode a Markdown file opens in: as last toggled, else from the settings
md_initial_mode :: proc(e: ^Editor) -> mdview.Mode {
	if mode, ok := g.md_modes[e.path]; ok {
		return mode
	}
	return mdview.default_mode(buffer.length(&e.buf))
}


// Switches the Markdown view, remembering the choice for the file until typo exits
md_toggle_view :: proc(e: ^Editor) {
	mode := mdview.toggle_view(&e.md_view)

	if e.path in g.md_modes {
		g.md_modes[e.path] = mode
	} else {
		g.md_modes[strings.clone(e.path)] = mode
	}
}


// After the file was renamed to e.path: highlighting follows the new name, and
// the editor gains or drops its Markdown structure and rendered view
editor_path_changed :: proc(e: ^Editor) {
	if e.status != .Text do return

	syntax.highlighter_open(&e.hl, &e.buf, e.path)

	markdown_now := is_markdown_path(e.path)
	if markdown_now == (e.md != nil) do return

	if markdown_now {
		e.md = new(markdown.Doc)
		markdown.doc_open(e.md, &e.buf)
		mdview.attach(&e.md_view, e, e.md, &TEXT_KIND, md_initial_mode(e))
	} else {
		markdown.doc_destroy(e.md)
		free(e.md)
		e.md = nil
		mdview.destroy(&e.md_view.mdv)
		e.md_view = {}
		editor_attach(e)
		e.kind_data = nil
	}
	textedit.normalize(e)
}


is_markdown_path :: proc(path: string) -> bool {
	ext := filepath.ext(path)
	return strings.equal_fold(ext, ".md") ||
	       strings.equal_fold(ext, ".markdown") ||
	       strings.equal_fold(ext, ".mdx")
}


editor_close :: proc(e: ^Editor) {
	if e.status == .Text {
		syntax.highlighter_close(&e.hl)
		buffer.buffer_destroy(&e.buf)
	}
	if e.md != nil {
		markdown.doc_destroy(e.md)
		free(e.md)
	}
	mdview.destroy(&e.md_view.mdv)
	delete(e.path)

	// The selections' array is kept for the next file
	clear(&e.sels)
	sels := e.sels
	e^ = {}
	e.sels = sels
}


editor_destroy :: proc(e: ^Editor) {
	editor_close(e)
	delete(e.sels)
}


editor_is_modified :: proc(e: ^Editor) -> bool {
	return e.status == .Text && buffer.is_modified(&e.buf)
}


// Writes to a temporary file and renames it over the original, so a failed
// save never leaves a half-written file
editor_save :: proc(e: ^Editor) -> bool {
	if e.status != .Text do return false
	if e.new_file do _ = os.make_directory_all(os.dir(e.path))

	// Write the temporary file
	tmp := strings.concatenate({e.path, ".typo.tmp"}, context.temp_allocator)
	f, err := os.create(tmp)
	if err != nil {
		sdl.Log("save: cannot create %s", strings.clone_to_cstring(tmp, context.temp_allocator))
		return false
	}
	for chunk in buffer.chunks(&e.buf) {
		if _, werr := os.write(f, chunk); werr != nil {
			os.close(f)
			os.remove(tmp)
			sdl.Log("save: write failed")
			return false
		}
	}
	os.close(f)

	// Put it in place of the original
	if os.rename(tmp, e.path) != nil {
		os.remove(tmp)
		sdl.Log("save: rename failed")
		return false
	}

	buffer.mark_saved(&e.buf)
	e.new_file = false
	return true
}


// --- Text helpers ------------------------------------------------------------------

// Line and visual column of the primary caret
caret_line_col :: proc(e: ^Editor) -> (line, col: int) {
	head := e.sels[e.primary].head
	c := &e.caret_pos

	// The zero value is right for a new file: head 0 is line 0, column 0
	if c.head != head || c.version != e.buf.version {
		line = buffer.offset_to_line(&e.buf, head)
		text, start := textedit.line_text(e, line)
		c^ = {head, line, textedit.visual_col(text, head - start), e.buf.version}
	}
	return c.line, c.col
}


// --- Keyboard ----------------------------------------------------------------------

// A key in the editor's view (see textedit.key). Returns true if it was handled
editor_handle_key :: proc(e: ^Editor, key: sdl.KeyboardEvent) -> bool {
	if e.status != .Text do return false
	return textedit.key(e, key)
}


// Runs an editing command (bound in the settings). Returns false if it doesn't
// apply, e.g. no text file is open
editor_run_command :: proc(e: ^Editor, cmd: Command) -> bool {
	if e.status != .Text do return false

	if textedit.caret_hidden(e) {
		// Nothing to copy; pasting shows the caret, as typing does, and
		// commands that select show it where it is
		#partial switch cmd {
		case .Copy, .Cut:
			return true
		case .Paste:
			textedit.show_caret(e, true)
		case .Select_All, .Undo, .Redo, .Add_Cursor_Above, .Add_Cursor_Below:
			textedit.show_caret(e, false)
		}
	}

	#partial switch cmd {
	case .Save:             editor_save(e)
	case .Undo:             textedit.undo(e)
	case .Redo:             textedit.redo(e)
	case .Select_All:       textedit.select_all(e)
	case .Copy, .Cut:       editor_copy(e, cmd == .Cut)
	case .Paste:            editor_paste(e)
	case .Add_Cursor_Above: textedit.add_cursor_vertical(e, -1)
	case .Add_Cursor_Below: textedit.add_cursor_vertical(e, +1)
	case .Toggle_Markdown_View:
		if e.md == nil do return false
		md_toggle_view(e)
	case:                   return false
	}
	return true
}


editor_text_input :: proc(e: ^Editor, text: string) {
	if e.status != .Text do return

	textedit.show_caret(e, true)
	e.kind.text_input(e, text)
}


// Copies the selected text (see textedit.copy_text) to the clipboard
editor_copy :: proc(e: ^Editor, cut: bool) {
	text := textedit.copy_text(e, cut)
	_ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}


editor_paste :: proc(e: ^Editor) {
	raw := sdl.GetClipboardText()
	if raw == nil do return
	defer sdl.free(raw)

	textedit.paste(e, string(cstring(raw)))
}
