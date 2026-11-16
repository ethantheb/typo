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
