package editor

import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "buffer"
import "syntax"
import sdl "vendor:sdl3"

// Editing state for one open file. All edits go through `apply`, which works on
// every selection at once, so multi-cursor is the general case and a single
// caret is just a list of one.

TAB_WIDTH :: 4
// Lines longer than this are only partly shown/edited by column (see line_text).
MAX_LINE_SCAN :: 1 << 20

Selection :: buffer.Selection

Editor :: struct {
	buf:      buffer.Buffer,
	hl:       syntax.Highlighter,
	path:     string, // full path; "" when nothing is open
	status:   enum {
		None,
		Text,
		Binary,
		Error,
	},
	sels:     [dynamic]Selection, // sorted, non-overlapping
	primary:  int,                // index into sels of the main caret

	// View state, in logical pixels.
	scroll_y: f64, // f64: line * line height exceeds f32 precision on huge files
	scroll_x: f32,
	// Where scrolling is heading; scroll_x/y ease toward these (see editor_animate).
	target_y: f64,
	target_x: f32,
	scrollbar_drag: Maybe(f32), // grab offset within the thumb while dragging it
	view:     clay_box, // text area bounds from the last layout
	char_w:   f32,      // monospace advance of the editor font
	gutter_w: f32,

	reveal:   bool, // scroll the primary caret into view next frame
	dragging: bool,
	drag_mode: enum {
		Char,
		Word,
		Line,
	},
	drag_origin: Selection, // selection made by the initial click, for word/line drag
	blink_t0: u64,          // caret blink phase start (reset on activity)
}

clay_box :: struct {
	x, y, w, h: f32,
}

// --- Open / save ----------------------------------------------------------------

editor_open :: proc(e: ^Editor, path: string) {
	editor_close(e)
	e.path = strings.clone(path)

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		e.status = .Error
		return
	}
	// Treat anything containing a NUL byte in its first 8KB as binary.
	if slice.contains(data[:min(len(data), 8192)], 0) {
		delete(data)
		e.status = .Binary
		return
	}
	buffer.buffer_init(&e.buf, data)
	syntax.highlighter_open(&e.hl, &e.buf, path)
	e.status = .Text
	append(&e.sels, Selection{0, 0, -1})
}

editor_close :: proc(e: ^Editor) {
	if e.status == .Text {
		syntax.highlighter_close(&e.hl)
		buffer.buffer_destroy(&e.buf)
	}
	delete(e.path)
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
// save never leaves a half-written file.
editor_save :: proc(e: ^Editor) -> bool {
	if e.status != .Text do return false
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
	if os.rename(tmp, e.path) != nil {
		os.remove(tmp)
		sdl.Log("save: rename failed")
		return false
	}
	buffer.mark_saved(&e.buf)
	return true
}

// Asks what to do with unsaved changes. Returns false if the user cancelled.
editor_confirm_discard :: proc(e: ^Editor) -> bool {
	if !editor_is_modified(e) do return true
	buttons := [?]sdl.MessageBoxButtonData {
		{flags = {.RETURNKEY_DEFAULT}, buttonID = 0, text = "Save"},
		{buttonID = 1, text = "Don't Save"},
		{flags = {.ESCAPEKEY_DEFAULT}, buttonID = 2, text = "Cancel"},
	}
	msg := strings.clone_to_cstring(
		strings.concatenate({"Save changes to ", relative_to_root(e.path), "?"}, context.temp_allocator),
		context.temp_allocator,
	)
	data := sdl.MessageBoxData {
		flags      = {.WARNING},
		window     = g.window,
		title      = "Unsaved changes",
		message    = msg,
		numbuttons = len(buttons),
		buttons    = &buttons[0],
	}
	choice: i32 = 2
	if !sdl.ShowMessageBox(data, &choice) do return false
	switch choice {
	case 0:
		return editor_save(e)
	case 1:
		return true
	}
	return false
}

// --- Selections -------------------------------------------------------------------

sel_lo :: proc(s: Selection) -> int {return min(s.anchor, s.head)}
sel_hi :: proc(s: Selection) -> int {return max(s.anchor, s.head)}

// Sorts selections and merges any that overlap (or are identical carets),
// keeping track of which one is primary.
normalize :: proc(e: ^Editor) {
	if len(e.sels) == 0 do return
	primary_head := e.sels[e.primary].head
	slice.sort_by(e.sels[:], proc(a, b: Selection) -> bool {return sel_lo(a) < sel_lo(b)})

	out := 0
	for i in 1 ..< len(e.sels) {
		cur := &e.sels[out]
		next := e.sels[i]
		overlaps := sel_lo(next) < sel_hi(cur^) || sel_lo(next) == sel_lo(cur^)
		if overlaps {
			lo, hi := min(sel_lo(cur^), sel_lo(next)), max(sel_hi(cur^), sel_hi(next))
			// Keep the direction of the existing selection.
			if cur.head >= cur.anchor {
				cur^ = {lo, hi, -1}
			} else {
				cur^ = {hi, lo, -1}
			}
		} else {
			out += 1
			e.sels[out] = next
		}
	}
	resize(&e.sels, out + 1)

	e.primary = 0
	for s, i in e.sels {
		if sel_lo(s) <= primary_head && primary_head <= sel_hi(s) {
			e.primary = i
			break
		}
	}
}

set_single_selection :: proc(e: ^Editor, s: Selection) {
	clear(&e.sels)
	append(&e.sels, s)
	e.primary = 0
}

// --- Text helpers -----------------------------------------------------------------

// Content of a line (without its line ending), capped at MAX_LINE_SCAN bytes.
line_text :: proc(e: ^Editor, line: int) -> (text: string, start: int) {
	start = buffer.line_start(&e.buf, line)
	end := min(buffer.line_end(&e.buf, line), start + MAX_LINE_SCAN)
	return string(buffer.read_alloc(&e.buf, start, end)), start
}

// Visual column of byte index i in a line, with tabs expanded.
visual_col :: proc(text: string, i: int) -> int {
	col := 0
	for r, j in text {
		if j >= i do break
		col = r == '\t' ? (col / TAB_WIDTH + 1) * TAB_WIDTH : col + 1
	}
	return col
}

// Byte index in a line nearest to visual column `col`.
byte_at_col :: proc(text: string, col: int) -> int {
	c := 0
	for r, j in text {
		next := r == '\t' ? (c / TAB_WIDTH + 1) * TAB_WIDTH : c + 1
		if col < next {
			// Inside a wide character (tab): snap to the nearer edge.
			return col - c <= next - col ? j : j + utf8.rune_size(r)
		}
		c = next
	}
	return len(text)
}

// Offset of the character boundary before `offset`, treating "\r\n" as one.
prev_boundary :: proc(e: ^Editor, offset: int) -> int {
	if offset <= 0 do return 0
	buf: [4]u8
	lo := max(offset - 4, 0)
	b := buffer.read(&e.buf, lo, offset, buf[:])
	if b[len(b) - 1] == '\n' && len(b) >= 2 && b[len(b) - 2] == '\r' do return offset - 2
	_, size := utf8.decode_last_rune(b)
	return offset - max(size, 1)
}

next_boundary :: proc(e: ^Editor, offset: int) -> int {
	n := buffer.length(&e.buf)
	if offset >= n do return n
	buf: [4]u8
	b := buffer.read(&e.buf, offset, min(offset + 4, n), buf[:])
	if b[0] == '\r' && len(b) >= 2 && b[1] == '\n' do return offset + 2
	_, size := utf8.decode_rune(b)
	return offset + max(size, 1)
}

Char_Class :: enum {
	Space,
	Word,
	Punct,
}

char_class :: proc(c: u8) -> Char_Class {
	switch c {
	case ' ', '\t', '\r', '\n':
		return .Space
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xff:
		return .Word
	}
	return .Punct
}

// Word boundary left/right of `offset`, staying within the line unless already
// at its edge (then it moves to the adjacent line).
word_boundary :: proc(e: ^Editor, offset: int, dir: int) -> int {
	line := buffer.offset_to_line(&e.buf, offset)
	text, start := line_text(e, line)
	i := offset - start
	if dir < 0 {
		if i <= 0 do return prev_boundary(e, offset)
		for i > 0 && char_class(text[i - 1]) == .Space do i -= 1
		if i > 0 {
			class := char_class(text[i - 1])
			for i > 0 && char_class(text[i - 1]) == class do i -= 1
		}
	} else {
		if i >= len(text) do return next_boundary(e, offset)
		for i < len(text) && char_class(text[i]) == .Space do i += 1
		if i < len(text) {
			class := char_class(text[i])
			for i < len(text) && char_class(text[i]) == class do i += 1
		}
	}
	return start + i
}

// The word (or run of punctuation/space) around offset, for double-click.
word_at :: proc(e: ^Editor, offset: int) -> (lo, hi: int) {
	line := buffer.offset_to_line(&e.buf, offset)
	text, start := line_text(e, line)
	i := offset - start
	if len(text) == 0 do return offset, offset
	probe := min(i, len(text) - 1)
	class := char_class(text[probe])
	a, b := probe, probe
	for a > 0 && char_class(text[a - 1]) == class do a -= 1
	for b < len(text) && char_class(text[b]) == class do b += 1
	return start + a, start + b
}

// --- Movement ---------------------------------------------------------------------

Move :: enum {
	Left,
	Right,
	Word_Left,
	Word_Right,
	Up,
	Down,
	Page_Up,
	Page_Down,
	Home,
	End,
	Doc_Start,
	Doc_End,
}

editor_move :: proc(e: ^Editor, m: Move, extend: bool) {
	lh := editor_line_height()
	page := max(int(e.view.h) / lh - 1, 1)
	for &s in e.sels {
		// Left/Right on a selection without Shift collapses it to that side.
		if !extend && s.anchor != s.head && (m == .Left || m == .Right) {
			p := m == .Left ? sel_lo(s) : sel_hi(s)
			s = {p, p, -1}
			continue
		}
		col := -1
		head := s.head
		switch m {
		case .Left:       head = prev_boundary(e, head)
		case .Right:      head = next_boundary(e, head)
		case .Word_Left:  head = word_boundary(e, head, -1)
		case .Word_Right: head = word_boundary(e, head, +1)
		case .Up:         head, col = vertical(e, s, -1)
		case .Down:       head, col = vertical(e, s, +1)
		case .Page_Up:    head, col = vertical(e, s, -page)
		case .Page_Down:  head, col = vertical(e, s, +page)
		case .Home:       head = smart_home(e, head)
		case .End:        head = buffer.line_end(&e.buf, buffer.offset_to_line(&e.buf, head))
		case .Doc_Start:  head = 0
		case .Doc_End:    head = buffer.length(&e.buf)
		}
		s = {extend ? s.anchor : head, head, col}
	}
	if m == .Page_Up || m == .Page_Down {
		e.target_y += f64((m == .Page_Up ? -page : page) * lh)
	}
	normalize(e)
	e.reveal = true
}

// Moves `lines` lines up/down keeping the preferred visual column.
vertical :: proc(e: ^Editor, s: Selection, lines: int) -> (head, col: int) {
	line := buffer.offset_to_line(&e.buf, s.head)
	col = s.col
	if col < 0 {
		text, start := line_text(e, line)
		col = visual_col(text, s.head - start)
	}
	target := line + lines
	if target < 0 do return 0, col
	if target >= buffer.line_count(&e.buf) do return buffer.length(&e.buf), col
	text, start := line_text(e, target)
	return start + byte_at_col(text, col), col
}

// Home goes to the first non-blank character, or to column 0 if already there.
smart_home :: proc(e: ^Editor, offset: int) -> int {
	line := buffer.offset_to_line(&e.buf, offset)
	text, start := line_text(e, line)
	indent := 0
	for indent < len(text) && (text[indent] == ' ' || text[indent] == '\t') do indent += 1
	return offset == start + indent ? start : start + indent
}

editor_select_all :: proc(e: ^Editor) {
	set_single_selection(e, {0, buffer.length(&e.buf), -1})
}

// Adds a caret on the line above/below the primary (or the outermost) caret.
editor_add_cursor_vertical :: proc(e: ^Editor, dir: int) {
	edge := dir < 0 ? e.sels[0] : e.sels[len(e.sels) - 1]
	head, col := vertical(e, edge, dir)
	if buffer.offset_to_line(&e.buf, head) == buffer.offset_to_line(&e.buf, edge.head) do return
	append(&e.sels, Selection{head, head, col})
	e.primary = len(e.sels) - 1
	normalize(e)
	e.reveal = true
}

// Collapses to the primary caret (Escape).
editor_single_cursor :: proc(e: ^Editor) {
	p := e.sels[e.primary]
	set_single_selection(e, {p.head, p.head, -1})
}

// --- Editing ------------------------------------------------------------------------

// Replaces ranges[i] with texts[i] (or texts[0] for all) as one undo step and
// leaves a caret after each insertion. Ranges must be sorted; overlapping ones
// are merged first.
apply :: proc(e: ^Editor, kind: buffer.Edit_Kind, ranges: [][2]int, texts: []string) {
	assert(len(ranges) == len(e.sels))
	// Merge overlapping ranges (e.g. word deletes from adjacent carets).
	merged := make([dynamic][2]int, 0, len(ranges), context.temp_allocator)
	merged_texts := make([dynamic]string, 0, len(ranges), context.temp_allocator)
	primary := 0
	for r, i in ranges {
		t := texts[min(i, len(texts) - 1)]
		if len(merged) > 0 && r[0] < merged[len(merged) - 1][1] {
			merged[len(merged) - 1][1] = max(merged[len(merged) - 1][1], r[1])
		} else {
			append(&merged, r)
			append(&merged_texts, t)
		}
		if i == e.primary do primary = len(merged) - 1
	}

	buffer.begin(&e.buf, kind, sdl.GetTicksNS(), e.sels[:])
	clear(&e.sels)
	delta := 0
	for r, i in merged {
		lo, hi := r[0] + delta, r[1] + delta
		t := merged_texts[i]
		buffer.replace(&e.buf, lo, hi - lo, t)
		caret := lo + len(t)
		append(&e.sels, Selection{caret, caret, -1})
		delta += len(t) - (hi - lo)
	}
	e.primary = primary
	normalize(e)
	buffer.end(&e.buf, e.sels[:])
	e.reveal = true
}

selection_ranges :: proc(e: ^Editor) -> [][2]int {
	ranges := make([][2]int, len(e.sels), context.temp_allocator)
	for s, i in e.sels do ranges[i] = {sel_lo(s), sel_hi(s)}
	return ranges
}

editor_insert :: proc(e: ^Editor, text: string, kind := buffer.Edit_Kind.Typing) {
	apply(e, kind, selection_ranges(e), {text})
}

// Newline that keeps the current line's indentation.
editor_newline :: proc(e: ^Editor) {
	texts := make([]string, len(e.sels), context.temp_allocator)
	for s, i in e.sels {
		text, _ := line_text(e, buffer.offset_to_line(&e.buf, sel_lo(s)))
		indent := 0
		for indent < len(text) && (text[indent] == ' ' || text[indent] == '\t') do indent += 1
		texts[i] = strings.concatenate({buffer.newline(&e.buf), text[:indent]}, context.temp_allocator)
	}
	apply(e, .Other, selection_ranges(e), texts)
}

// Backspace/Delete: removes the selection, or the character/word next to each caret.
editor_delete :: proc(e: ^Editor, dir: int, word: bool) {
	ranges := selection_ranges(e)
	for &r, i in ranges {
		if r[0] != r[1] do continue
		h := e.sels[i].head
		if dir < 0 {
			r[0] = word ? word_boundary(e, h, -1) : prev_boundary(e, h)
		} else {
			r[1] = word ? word_boundary(e, h, +1) : next_boundary(e, h)
		}
	}
	apply(e, .Deleting, ranges, {""})
}

editor_undo :: proc(e: ^Editor) {
	if sels, ok := buffer.undo(&e.buf); ok do restore_selections(e, sels)
}

editor_redo :: proc(e: ^Editor) {
	if sels, ok := buffer.redo(&e.buf); ok do restore_selections(e, sels)
}

@(private = "file")
restore_selections :: proc(e: ^Editor, sels: []Selection) {
	clear(&e.sels)
	append(&e.sels, ..sels)
	e.primary = len(e.sels) - 1
	normalize(e)
	e.reveal = true
}

// --- Clipboard ----------------------------------------------------------------------

// Copies the selected text; carets without a selection copy their whole line.
editor_copy :: proc(e: ^Editor, cut: bool) {
	sb := strings.builder_make(context.temp_allocator)
	whole_lines := true
	for s in e.sels do if s.anchor != s.head do whole_lines = false

	ranges := make([][2]int, len(e.sels), context.temp_allocator)
	for s, i in e.sels {
		lo, hi := sel_lo(s), sel_hi(s)
		if whole_lines {
			line := buffer.offset_to_line(&e.buf, lo)
			lo = buffer.line_start(&e.buf, line)
			hi = buffer.line_start(&e.buf, line + 1)
			if line + 1 >= buffer.line_count(&e.buf) do hi = buffer.length(&e.buf)
		}
		ranges[i] = {lo, hi}
		if i > 0 && !whole_lines do strings.write_string(&sb, buffer.newline(&e.buf))
		strings.write_bytes(&sb, buffer.read_alloc(&e.buf, lo, hi))
	}
	_ = sdl.SetClipboardText(strings.to_cstring(&sb))
	if cut do apply(e, .Other, ranges, {""})
}

editor_paste :: proc(e: ^Editor) {
	raw := sdl.GetClipboardText()
	if raw == nil do return
	defer sdl.free(raw)
	text := string(cstring(raw))
	if len(text) == 0 do return

	// Normalize line endings to the file's.
	text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	if e.buf.crlf {
		text, _ = strings.replace_all(text, "\n", "\r\n", context.temp_allocator)
	}

	// One line per caret when the counts match (e.g. copied from multiple carets).
	nl := buffer.newline(&e.buf)
	parts := strings.split(text, nl, context.temp_allocator)
	if len(e.sels) > 1 && len(parts) == len(e.sels) {
		apply(e, .Other, selection_ranges(e), parts)
	} else {
		apply(e, .Other, selection_ranges(e), {text})
	}
}

// --- Keyboard -----------------------------------------------------------------------

// Returns true if the key was handled.
editor_handle_key :: proc(e: ^Editor, key: sdl.KeyboardEvent) -> bool {
	if e.status != .Text do return false
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	e.blink_t0 = sdl.GetTicksNS()

	switch key.key {
	case sdl.K_LEFT:      editor_move(e, ctrl ? .Word_Left : .Left, shift)
	case sdl.K_RIGHT:     editor_move(e, ctrl ? .Word_Right : .Right, shift)
	case sdl.K_UP:        editor_move(e, .Up, shift)
	case sdl.K_DOWN:      editor_move(e, .Down, shift)
	case sdl.K_PAGEUP:    editor_move(e, .Page_Up, shift)
	case sdl.K_PAGEDOWN:  editor_move(e, .Page_Down, shift)
	case sdl.K_HOME:      editor_move(e, ctrl ? .Doc_Start : .Home, shift)
	case sdl.K_END:       editor_move(e, ctrl ? .Doc_End : .End, shift)
	case sdl.K_BACKSPACE: editor_delete(e, -1, ctrl)
	case sdl.K_DELETE:    editor_delete(e, +1, ctrl)
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		editor_newline(e)
	case sdl.K_TAB:       editor_insert(e, "\t", .Other)
	case sdl.K_ESCAPE:
		if len(e.sels) > 1 || e.sels[0].anchor != e.sels[0].head {
			editor_single_cursor(e)
		} else {
			return false
		}
	case:
		return false
	}
	return true
}

// Runs an editing command (bound in the settings). Returns false if it doesn't
// apply, e.g. no text file is open.
editor_run_command :: proc(e: ^Editor, cmd: Command) -> bool {
	if e.status != .Text do return false
	e.blink_t0 = sdl.GetTicksNS()
	#partial switch cmd {
	case .Save:             editor_save(e)
	case .Undo:             editor_undo(e)
	case .Redo:             editor_redo(e)
	case .Select_All:       editor_select_all(e)
	case .Copy:             editor_copy(e, false)
	case .Cut:              editor_copy(e, true)
	case .Paste:            editor_paste(e)
	case .Add_Cursor_Above: editor_add_cursor_vertical(e, -1)
	case .Add_Cursor_Below: editor_add_cursor_vertical(e, +1)
	case:                   return false
	}
	return true
}

editor_text_input :: proc(e: ^Editor, text: string) {
	if e.status != .Text do return
	e.blink_t0 = sdl.GetTicksNS()
	editor_insert(e, text)
}

// --- Mouse & scrolling --------------------------------------------------------------

// Document offset under a point (logical window coordinates).
offset_at_point :: proc(e: ^Editor, x, y: f32) -> int {
	line := int(f64(y - e.view.y) + e.scroll_y) / editor_line_height()
	line = clamp(line, 0, buffer.line_count(&e.buf) - 1)
	if f64(y - e.view.y) + e.scroll_y < 0 do return 0
	text, start := line_text(e, line)
	col := int((x - e.view.x - e.gutter_w - TEXT_MARGIN + e.scroll_x) / e.char_w + 0.5)
	return start + byte_at_col(text, max(col, 0))
}

editor_mouse :: proc(e: ^Editor) {
	if e.status != .Text do return
	v := e.view
	inside := g.mouse_pos.x >= v.x && g.mouse_pos.x < v.x + v.w && g.mouse_pos.y >= v.y && g.mouse_pos.y < v.y + v.h

	// Wheel scrolling (Shift or a horizontal wheel scrolls sideways). Eases
	// toward the new position rather than jumping.
	if inside && g.wheel != {} {
		shift := sdl.GetModState() & sdl.KMOD_SHIFT != {}
		dx, dy := g.wheel.x, g.wheel.y
		if shift do dx, dy = dy, 0
		e.target_y -= f64(dy * 3 * f32(editor_line_height()))
		e.target_x -= dx * 6 * e.char_w
	}

	if scrollbar_mouse(e) {
		clamp_scroll(e)
		return
	}
	on_scrollbar := scrollbar_hit(e, g.mouse_pos)

	if g.mouse_pressed && inside && !on_scrollbar {
		mods := sdl.GetModState()
		offset := offset_at_point(e, g.mouse_pos.x, g.mouse_pos.y)
		e.blink_t0 = sdl.GetTicksNS()
		e.dragging = true
		e.drag_mode = .Char

		switch {
		case mods & sdl.KMOD_ALT != {}:
			append(&e.sels, Selection{offset, offset, -1})
			e.primary = len(e.sels) - 1
		case mods & sdl.KMOD_SHIFT != {}:
			p := e.sels[e.primary]
			set_single_selection(e, {p.anchor, offset, -1})
		case g.mouse_clicks == 2:
			lo, hi := word_at(e, offset)
			set_single_selection(e, {lo, hi, -1})
			e.drag_mode = .Word
		case g.mouse_clicks >= 3:
			line := buffer.offset_to_line(&e.buf, offset)
			set_single_selection(e, {buffer.line_start(&e.buf, line), buffer.line_start(&e.buf, line + 1), -1})
			if line + 1 >= buffer.line_count(&e.buf) do e.sels[0].head = buffer.length(&e.buf)
			e.drag_mode = .Line
		case:
			set_single_selection(e, {offset, offset, -1})
		}
		e.drag_origin = e.sels[e.primary]
		normalize(e)
	} else if e.dragging && g.mouse_down {
		// Extend the primary selection; scroll when dragging past the edges.
		lh := f64(editor_line_height())
		if g.mouse_pos.y < v.y do scroll_to(e, e.scroll_y - lh * 0.5)
		if g.mouse_pos.y > v.y + v.h do scroll_to(e, e.scroll_y + lh * 0.5)
		offset := offset_at_point(e, g.mouse_pos.x, g.mouse_pos.y)
		o := e.drag_origin
		s := &e.sels[e.primary]
		switch e.drag_mode {
		case .Char:
			s^ = {o.anchor, offset, -1}
		case .Word, .Line:
			lo, hi: int
			if e.drag_mode == .Word {
				lo, hi = word_at(e, offset)
			} else {
				line := buffer.offset_to_line(&e.buf, offset)
				lo, hi = buffer.line_start(&e.buf, line), buffer.line_start(&e.buf, line + 1)
				if line + 1 >= buffer.line_count(&e.buf) do hi = buffer.length(&e.buf)
			}
			if lo < sel_lo(o) {
				s^ = {sel_hi(o), lo, -1}
			} else {
				s^ = {sel_lo(o), max(hi, sel_hi(o)), -1}
			}
		}
		normalize(e)
	} else if !g.mouse_down {
		e.dragging = false
	}

	clamp_scroll(e)
}

// Scrolls so the primary caret is visible (after keyboard edits/moves). Works
// on the scroll target: if the target already shows the caret (e.g. Page Down
// is easing there) nothing changes; otherwise the view jumps, so typing and
// arrow keys never wait on an animation.
editor_reveal :: proc(e: ^Editor) {
	if !e.reveal || e.status != .Text || e.view.h <= 0 do return
	e.reveal = false
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	lh := f64(editor_line_height())
	top := f64(line) * lh
	ty, tx := e.target_y, e.target_x
	if top < ty do ty = top
	if top + lh > ty + f64(e.view.h) do ty = top + lh - f64(e.view.h)

	text, start := line_text(e, line)
	x := f32(visual_col(text, head - start)) * e.char_w
	text_w := e.view.w - e.gutter_w - TEXT_MARGIN - e.char_w * 2
	if x < tx do tx = max(x - e.char_w * 4, 0)
	if x > tx + text_w do tx = x - text_w

	if ty != e.target_y do scroll_to(e, ty)
	if tx != e.target_x do e.scroll_x, e.target_x = tx, tx
	clamp_scroll(e)
}

// Jumps straight to a vertical position (no easing).
scroll_to :: proc(e: ^Editor, y: f64) {
	e.scroll_y, e.target_y = y, y
}

max_scroll_y :: proc(e: ^Editor) -> f64 {
	return max(f64((buffer.line_count(&e.buf) - 1) * editor_line_height()), 0)
}

clamp_scroll :: proc(e: ^Editor) {
	max_y := max_scroll_y(e)
	e.target_y = clamp(e.target_y, 0, max_y)
	e.scroll_y = clamp(e.scroll_y, 0, max_y)
	e.target_x = max(e.target_x, 0)
	e.scroll_x = max(e.scroll_x, 0)
}

SCROLL_EASE :: 18 // higher settles faster; ~150 ms to settle

// Moves the view toward the scroll target: eased (frame-rate independent) with
// smooth scrolling on, in one step with it off.
editor_animate :: proc(e: ^Editor) {
	if !g.settings.smooth_scroll {
		e.scroll_y, e.scroll_x = e.target_y, e.target_x
		return
	}
	t := 1 - math.exp(-f64(clamp(g.dt, 0, 1.0 / 30)) * SCROLL_EASE)
	e.scroll_y += (e.target_y - e.scroll_y) * t
	e.scroll_x += f32(f64(e.target_x - e.scroll_x) * t)
	if abs(e.target_y - e.scroll_y) < 0.25 do e.scroll_y = e.target_y
	if abs(e.target_x - e.scroll_x) < 0.25 do e.scroll_x = e.target_x
}

editor_scrolling :: proc(e: ^Editor) -> bool {
	return e.status == .Text && (e.scroll_y != e.target_y || e.scroll_x != e.target_x)
}

// --- Scroll bar ---------------------------------------------------------------------

SCROLLBAR_WIDTH :: 12
SCROLLBAR_MIN_THUMB :: 28

// Track and thumb rectangles (logical pixels) along the text area's right edge.
// ok = false when everything fits and there is nothing to scroll.
scrollbar_geometry :: proc(e: ^Editor) -> (track, thumb: clay_box, ok: bool) {
	max_y := max_scroll_y(e)
	v := e.view
	if max_y <= 0 || v.h <= 0 do return
	track = {v.x + v.w - SCROLLBAR_WIDTH, v.y, SCROLLBAR_WIDTH, v.h}
	// Content is the document plus one screen (the last line can scroll to the top).
	h := max(v.h * v.h / f32(max_y + f64(v.h)), min(SCROLLBAR_MIN_THUMB, v.h))
	y := v.y + f32(e.scroll_y / max_y) * (v.h - h)
	thumb = {track.x, y, track.w, h}
	return track, thumb, true
}

scrollbar_hit :: proc(e: ^Editor, p: [2]f32) -> bool {
	track, _, ok := scrollbar_geometry(e)
	return ok && p.x >= track.x && p.x < track.x + track.w && p.y >= track.y && p.y < track.y + track.h
}

// Handles pressing and dragging the scroll bar. Returns true while it owns the mouse.
@(private = "file")
scrollbar_mouse :: proc(e: ^Editor) -> bool {
	track, thumb, ok := scrollbar_geometry(e)
	if !ok {
		e.scrollbar_drag = nil
		return false
	}
	if g.mouse_pressed && scrollbar_hit(e, g.mouse_pos) {
		my := g.mouse_pos.y
		if my >= thumb.y && my < thumb.y + thumb.h {
			e.scrollbar_drag = my - thumb.y
		} else {
			e.scrollbar_drag = thumb.h / 2 // clicking the track centres the thumb there
		}
	}
	grab, dragging := e.scrollbar_drag.?
	if !dragging do return false
	if !g.mouse_down {
		e.scrollbar_drag = nil
		return false
	}
	span := track.h - thumb.h
	if span > 0 {
		frac := clamp((g.mouse_pos.y - grab - track.y) / span, 0, 1)
		scroll_to(e, f64(frac) * max_scroll_y(e))
	}
	return true
}
