package textedit

import "core:strings"

import "../buffer"
import "../gfx"
import sdl "../../vendor/sdl3"

// A kind of view: how a View shows its document and edits it. The app's plain
// text view and the rendered Markdown view (mdview.KIND) are the two kinds; a
// View's `kind` can change while it is open (toggling a Markdown file's view).
// A kind keeps its own state in View.kind_data. Procs marked optional may be
// nil, which means the plain behavior. Points are in window coordinates
Kind :: struct {
	// Per frame: before the mouse is handled (lay out what is in view, with the
	// bounds from the last layout), and after scrolling
	frame_begin:  proc(v: ^View),
	frame_end:    proc(v: ^View),
	// Whether what is in view is ready to be drawn (nothing still loading). Optional
	ready:        proc(v: ^View) -> bool,
	draw:         proc(v: ^View, b: gfx.Rect, scale: f32, caret_on: bool),

	// The document offset nearest to a point
	offset_at:    proc(v: ^View, p: [2]f32) -> int,
	// Whether a point is over the text, where a click places the caret
	over_text:    proc(v: ^View, p: [2]f32) -> bool,
	max_scroll:   proc(v: ^View) -> f64,
	// The height of a line, for wheel steps and scrolling while dragging
	scroll_step:  proc(v: ^View) -> f64,
	// Moves the scroll target so the primary caret shows
	reveal:       proc(v: ^View),
	// Whether two offsets are on the same visual row
	same_row:     proc(v: ^View, a, b: int) -> bool,

	// Caret movement for Left, Right, Up, Down, Page_Up, Page_Down, Home and
	// End (the others are the same in every view); col is the goal kept for
	// vertical movement (Selection.col)
	move:         proc(v: ^View, m: Move, s: Selection) -> (head, col: int),
	page_height:  proc(v: ^View) -> f64,

	// Moves carets out of text they can't be in (rendered table syntax); run
	// by normalize. Optional
	snap:         proc(v: ^View),
	// An editing key, after caret movement keys (see `key`). Returns whether it
	// was handled
	edit_key:     proc(v: ^View, key: sdl.KeyboardEvent) -> bool,
	text_input:   proc(v: ^View, text: string),
	// What copying [lo, hi) takes, with text that goes before and after it
	// (the rendered view adds the markers of a partly selected line). Optional
	copy_range:   proc(v: ^View, lo, hi: int) -> (from, to: int, before, after: string),
	// Replaces the selections with pasted text, or with nothing for a cut, its
	// own way (cells of a rendered table). Returns false to have it done as
	// plain text. Optional
	replace:      proc(v: ^View, text: string) -> bool,
	// After a cut or paste changed the document. Optional
	edited:       proc(v: ^View),

	// A view can hide its caret (the rendered view until a click in the text).
	// Optional, with show_caret: a key while it is hidden goes to hidden_key
	// first (done: no further handling, and whether it was handled);
	// show_caret shows it, moving it into view first if `place`
	caret_hidden: proc(v: ^View) -> bool,
	hidden_key:   proc(v: ^View, key: sdl.KeyboardEvent) -> (done, handled: bool),
	show_caret:   proc(v: ^View, place: bool),

	// The mouse, all optional. press: a press (with its modifiers and click
	// count) that the view handles itself, selecting nothing (a link, a task
	// box, a button, a click beside the text); returns true if so. capture:
	// called every frame, true while the view's own controls own the mouse
	// (sideways scroll bars). wheel_x: a sideways wheel step of dx pixels at p;
	// true if the view took it. block_at: what a triple click selects instead
	// of the line (a table cell). drag: extends a drag-selection from `origin`
	// (made by a press, a triple click's block if `block`) to `offset` its own
	// way; true if it did. drag_x: scrolls sideways while drag-selecting near
	// the edges. release: the button went up after a drag-selection. pointer:
	// how the pointer looks at p, if not the usual I-beam over text
	press:        proc(v: ^View, p: [2]f32, mods: sdl.Keymod, clicks: int) -> bool,
	capture:      proc(v: ^View) -> bool,
	wheel_x:      proc(v: ^View, p: [2]f32, dx: f32) -> bool,
	block_at:     proc(v: ^View, offset: int) -> (lo, hi: int, ok: bool),
	drag:         proc(v: ^View, origin: Selection, offset: int, block: bool) -> bool,
	drag_x:       proc(v: ^View, p: [2]f32),
	release:      proc(v: ^View),
	pointer:      proc(v: ^View, p: [2]f32, over_text: bool) -> Pointer,
}

Pointer :: enum {
	Text,  // the I-beam over text, or the arrow elsewhere
	Arrow, // over a control
	Hand,  // over something a click acts on
}


// The first proc a kind needs but lacks (those not marked optional), or ""
missing_proc :: proc(k: ^Kind) -> string {
	required := [?]struct {
		name: string,
		set:  bool,
	} {
		{"frame_begin", k.frame_begin != nil},
		{"frame_end", k.frame_end != nil},
		{"draw", k.draw != nil},
		{"offset_at", k.offset_at != nil},
		{"over_text", k.over_text != nil},
		{"max_scroll", k.max_scroll != nil},
		{"scroll_step", k.scroll_step != nil},
		{"reveal", k.reveal != nil},
		{"same_row", k.same_row != nil},
		{"move", k.move != nil},
		{"page_height", k.page_height != nil},
		{"edit_key", k.edit_key != nil},
		{"text_input", k.text_input != nil},
	}
	for r in required {
		if !r.set do return r.name
	}

	// The caret procs come together
	hides_caret := k.caret_hidden != nil
	shows_caret := k.hidden_key != nil && k.show_caret != nil
	if hides_caret != shows_caret {
		return "caret_hidden, hidden_key and show_caret"
	}
	return ""
}


// --- Movement ----------------------------------------------------------------------

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


// Moves every selection's head (and its anchor too unless `extend`)
move :: proc(v: ^View, m: Move, extend: bool) {
	for &s in v.sels {
		// Left/Right on a selection without Shift collapses it to that side
		if !extend && s.anchor != s.head && (m == .Left || m == .Right) {
			p := m == .Left ? sel_lo(s) : sel_hi(s)
			s = {p, p, -1}
			continue
		}

		col := -1
		head := s.head
		switch m {
		case .Word_Left:  head = word_boundary(v, head, -1)
		case .Word_Right: head = word_boundary(v, head, +1)
		case .Doc_Start:  head = 0
		case .Doc_End:    head = buffer.length(&v.buf)
		case .Left, .Right, .Up, .Down, .Page_Up, .Page_Down, .Home, .End:
			head, col = v.kind.move(v, m, s)
		}
		s = {extend ? s.anchor : head, head, col}
	}

	// Paging scrolls by a page too
	if m == .Page_Up || m == .Page_Down {
		dir: f64 = m == .Page_Up ? -1 : 1
		v.target_y += dir * v.kind.page_height(v)
	}

	normalize(v)
	v.reveal = true
}


// Caret movement and selection keys, the same in every view
navigation_key :: proc(v: ^View, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}

	switch key.key {
	case sdl.K_LEFT:     move(v, ctrl ? .Word_Left : .Left, shift)
	case sdl.K_RIGHT:    move(v, ctrl ? .Word_Right : .Right, shift)
	case sdl.K_UP:       move(v, .Up, shift)
	case sdl.K_DOWN:     move(v, .Down, shift)
	case sdl.K_PAGEUP:   move(v, .Page_Up, shift)
	case sdl.K_PAGEDOWN: move(v, .Page_Down, shift)
	case sdl.K_HOME:     move(v, ctrl ? .Doc_Start : .Home, shift)
	case sdl.K_END:      move(v, ctrl ? .Doc_End : .End, shift)
	case sdl.K_ESCAPE:
		if len(v.sels) == 1 && v.sels[0].anchor == v.sels[0].head {
			return false
		}
		single_cursor(v)
	case:
		return false
	}
	return true
}


// A key in the view: while its caret is hidden, the kind's hidden_key first;
// then caret movement; then the kind's editing keys
key :: proc(v: ^View, key: sdl.KeyboardEvent) -> bool {
	if caret_hidden(v) {
		if done, handled := v.kind.hidden_key(v, key); done {
			return handled
		}
	}

	if navigation_key(v, key) do return true
	return v.kind.edit_key(v, key)
}


caret_hidden :: proc(v: ^View) -> bool {
	return v.kind.caret_hidden != nil && v.kind.caret_hidden(v)
}


// Shows a hidden caret, moving it into view first if `place`
show_caret :: proc(v: ^View, place: bool) {
	if caret_hidden(v) do v.kind.show_caret(v, place)
}


// Collapses to the primary caret (Escape)
single_cursor :: proc(v: ^View) {
	p := v.sels[v.primary].head
	set_single_selection(v, {p, p, -1})
}


select_all :: proc(v: ^View) {
	set_single_selection(v, {0, buffer.length(&v.buf), -1})
}


// Adds a caret on the row above (dir = -1) or below the outermost caret
add_cursor_vertical :: proc(v: ^View, dir: int) {
	edge := dir < 0 ? v.sels[0] : v.sels[len(v.sels) - 1]
	head, col := v.kind.move(v, dir < 0 ? .Up : .Down, edge)
	if v.kind.same_row(v, head, edge.head) do return

	append(&v.sels, Selection{head, head, col})
	v.primary = len(v.sels) - 1
	normalize(v)
	v.reveal = true
}


// --- Undo --------------------------------------------------------------------------

undo :: proc(v: ^View) {
	if sels, ok := buffer.undo(&v.buf); ok {
		restore_selections(v, sels)
	}
}


redo :: proc(v: ^View) {
	if sels, ok := buffer.redo(&v.buf); ok {
		restore_selections(v, sels)
	}
}


@(private = "file")
restore_selections :: proc(v: ^View, sels: []Selection) {
	clear(&v.sels)
	append(&v.sels, ..sels)
	v.primary = len(v.sels) - 1
	normalize(v)
	v.reveal = true
}


// --- Clipboard ---------------------------------------------------------------------

// The text copying the selections takes (carets without a selection copy their
// whole line), and with `cut` removes it
copy_text :: proc(v: ^View, cut: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	whole_lines := true
	for s in v.sels {
		if s.anchor != s.head do whole_lines = false
	}

	// Each selection's text, a line apart
	ranges := make([][2]int, len(v.sels), context.temp_allocator)
	for s, i in v.sels {
		lo, hi := sel_lo(s), sel_hi(s)
		before, after: string
		if whole_lines {
			lo, hi = line_span(v, buffer.offset_to_line(&v.buf, lo))
		} else if v.kind.copy_range != nil {
			lo, hi, before, after = v.kind.copy_range(v, lo, hi)
			// Grown ranges can overlap: start each after the previous one
			if i > 0 do lo = min(max(lo, ranges[i - 1][1]), hi)
		}
		ranges[i] = {lo, hi}

		if i > 0 && !whole_lines {
			strings.write_string(&sb, buffer.newline(&v.buf))
		}
		strings.write_string(&sb, before)
		strings.write_bytes(&sb, buffer.read_alloc(&v.buf, lo, hi))
		strings.write_string(&sb, after)
	}

	if cut {
		version := v.buf.version
		if v.kind.replace == nil || !v.kind.replace(v, "") {
			apply(v, .Other, ranges, {""})
		}
		if v.kind.edited != nil && v.buf.version != version {
			v.kind.edited(v)
		}
	}
	return strings.to_string(sb)
}


// Pastes text, with its line endings made the document's. With as many lines
// as carets, each caret gets one
paste :: proc(v: ^View, text: string) {
	if len(text) == 0 do return

	text, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	if v.buf.crlf do text, _ = strings.replace_all(text, "\n", "\r\n", context.temp_allocator)

	version := v.buf.version
	defer if v.kind.edited != nil && v.buf.version != version {
		v.kind.edited(v)
	}
	if v.kind.replace != nil && v.kind.replace(v, text) {
		return
	}

	// One line per caret, or the whole text at each
	parts := strings.split(text, buffer.newline(&v.buf), context.temp_allocator)
	if len(v.sels) > 1 && len(parts) == len(v.sels) {
		apply(v, .Other, selection_ranges(v), parts)
	} else {
		apply(v, .Other, selection_ranges(v), {text})
	}
}


// Replaces [lo, hi) with text of the same length as one undo step, leaving the
// selections where they are (toggling a task box)
replace_in_place :: proc(v: ^View, lo, hi: int, text: string) {
	assert(hi - lo == len(text))

	buffer.begin(&v.buf, .Other, now(), v.sels[:])
	buffer.replace(&v.buf, lo, hi - lo, text)
	buffer.end(&v.buf, v.sels[:])
}
