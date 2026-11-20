package textedit

import "../buffer"
import "../gfx"

// The editing core shared by the text view and the rendered Markdown view:
// a buffer, its selections and scroll position, and the operations on them.
// All edits go through `apply`, which works on every selection at once, so
// multi-cursor is the general case and a single caret is just a list of one


TAB_WIDTH :: 4
// Lines longer than this are only partly shown/edited by column (see line_text)
MAX_LINE_SCAN :: 1 << 20

Selection :: buffer.Selection

// One view of a document. Its kind (the plain text view, the rendered Markdown
// view) decides how it is drawn and how its keys and mouse edit
View :: struct {
	buf:       buffer.Buffer,
	sels:      [dynamic]Selection, // sorted, non-overlapping
	primary:   int,                // index into sels of the main caret
	path:      string,             // full path; "" when nothing is open
	reveal:    bool,               // scroll the primary caret into view next frame
	center:    bool,               // with reveal: a caret out of view goes to the middle

	// Scroll position, in logical pixels
	scroll_y:  f64, // f64: line * line height exceeds f32 precision on huge files
	scroll_x:  f32,
	// Where scrolling is heading; scroll_x/y ease toward these
	target_y:  f64,
	target_x:  f32,
	view:      gfx.Rect, // the text area, from the last layout

	// The text's size: steps from 100% in ZOOM_LEVELS
	zoom:      int,
	// Set when the text changes size: the line the kind keeps where it is on
	// screen on its next frame
	anchor:    Maybe(Anchor),

	// Ranges drawn highlighted behind the text (search matches): sorted and
	// non-overlapping. Not owned: set by whoever finds them, nil for none
	marks:     [][2]int,
	// Problems underlined in the text (language server diagnostics): sorted by
	// start, may overlap. Not owned
	problems:  []Problem,

	kind:      ^Kind,
	kind_data: rawptr, // the kind's own state
	// Run by `take_changes` with the edits since the last call. May be nil
	on_edit:   proc(v: ^View, changes: []buffer.Change),
}


// A line kept in place on screen: its top's distance below the view's top
Anchor :: struct {
	line: int,
	y:    f64,
}

// Zoom levels of a view's text, as factors of the font sizes set
ZOOM_LEVELS := [?]f32{0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}
ZOOM_ONE :: 5 // the index of 1 in ZOOM_LEVELS: change the two together

// A range underlined as a problem; an empty one marks the character after it
Problem :: struct {
	lo, hi:   int,
	severity: Severity,
}

Severity :: enum u8 {
	Error,
	Warning,
	Info,
	Hint,
}


// Index of the first problem that could reach `offset` (problems are sorted by
// start and short, so this backs up from the first starting after it)
first_problem_at :: proc(v: ^View, offset: int) -> int {
	lo, hi := 0, len(v.problems)
	for lo < hi {
		mid := (lo + hi) / 2
		if v.problems[mid].lo < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}

	// Earlier ones that start before `offset` but end after it
	for lo > 0 && v.problems[lo - 1].hi >= offset {
		lo -= 1
	}
	return lo
}


// Passes the buffer's edits since the last call to the view's on_edit hook
take_changes :: proc(v: ^View) {
	changes := buffer.take_changes(&v.buf)
	if v.on_edit != nil do v.on_edit(v, changes)
}


// Index of the first mark that ends at or after `offset`
first_mark_at :: proc(v: ^View, offset: int) -> int {
	lo, hi := 0, len(v.marks)
	for lo < hi {
		mid := (lo + hi) / 2
		if v.marks[mid][1] < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}


// Jumps straight to a vertical position (no easing)
scroll_to :: proc(v: ^View, y: f64) {
	v.scroll_y, v.target_y = y, y
}


// --- Zoom ------------------------------------------------------------------------------

// A zoom step (steps from 100%) within ZOOM_LEVELS
clamp_zoom :: proc(step: int) -> int {
	return clamp(step, -ZOOM_ONE, len(ZOOM_LEVELS) - 1 - ZOOM_ONE)
}


// The factor of a zoom step
zoom_factor :: proc(step: int) -> f32 {
	return ZOOM_LEVELS[ZOOM_ONE + clamp_zoom(step)]
}


// A zoom step as a percentage, e.g. 125
zoom_percent :: proc(step: int) -> int {
	return int(zoom_factor(step) * 100 + 0.5)
}


// The zoom step nearest a percentage (a saved zoom)
zoom_step :: proc(percent: int) -> int {
	best := 0
	for level, i in ZOOM_LEVELS {
		step := i - ZOOM_ONE
		if abs(f32(percent) - level * 100) < abs(f32(percent) - zoom_factor(best) * 100) {
			best = step
		}
	}
	return best
}


// The view's zoom factor
zoom :: proc(v: ^View) -> f32 {
	return zoom_factor(v.zoom)
}


// Zooms the view's text to a step, keeping the line the kind picks (the
// caret's) where it is on screen
set_zoom :: proc(v: ^View, step: int) {
	step := clamp_zoom(step)
	if step == v.zoom do return

	// The line to keep, picked before the text changes size. A caret kept on
	// screen stays in view, whatever its line's new height
	if v.anchor == nil && v.kind != nil && v.kind.anchor != nil {
		a := v.kind.anchor(v)
		v.anchor = a

		caret := buffer.offset_to_line(&v.buf, v.sels[v.primary].head)
		v.reveal = a.line == caret && !caret_hidden(v)
	}

	// Sideways, text widths follow the font size
	ratio := zoom_factor(step) / zoom(v)
	v.scroll_x *= ratio
	v.target_x *= ratio
	v.zoom = step
}
