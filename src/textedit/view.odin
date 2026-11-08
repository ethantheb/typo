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

	// Scroll position, in logical pixels
	scroll_y:  f64, // f64: line * line height exceeds f32 precision on huge files
	scroll_x:  f32,
	// Where scrolling is heading; scroll_x/y ease toward these
	target_y:  f64,
	target_x:  f32,
	view:      gfx.Rect, // the text area, from the last layout

	kind:      ^Kind,
	kind_data: rawptr, // the kind's own state
	// Run by `take_changes` with the edits since the last call. May be nil
	on_edit:   proc(v: ^View, changes: []buffer.Change),
}


// Passes the buffer's edits since the last call to the view's on_edit hook
take_changes :: proc(v: ^View) {
	changes := buffer.take_changes(&v.buf)
	if v.on_edit != nil do v.on_edit(v, changes)
}


// Jumps straight to a vertical position (no easing)
scroll_to :: proc(v: ^View, y: f64) {
	v.scroll_y, v.target_y = y, y
}
