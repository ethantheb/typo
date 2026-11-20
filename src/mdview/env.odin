package mdview

import sdl "../../vendor/sdl3"
import "../textedit"

// What the rendered view needs from the app, which sets `env` at startup. The
// procs are called whenever the value is needed, so a change in the app
// (a setting, the mouse) is seen at once


// The settings the view reads. Sizes are at 100%; a view scales them by its
// zoom (textedit.zoom)
Config :: struct {
	font_size:       int,  // of rendered text
	line_height:     f64,  // of rendered text, as a multiple of its size
	max_width:       int,  // of the text column; 0 for the whole pane
	text_by_default: bool, // Markdown files open as text
	letter_spacing:  bool, // the editor font has letter spacing (code is drawn char by char)
}

// The pointer, the keyboard's modifiers and the frame count
Input :: struct {
	mouse_pos:     [2]f32,
	mouse_down:    bool,
	mouse_pressed: bool, // went down this frame
	mods:          sdl.Keymod,
	frame:         u64,
}

Env :: struct {
	config:       proc() -> Config,
	input:        proc() -> Input,

	// The text view's row height at the view's zoom, kept when switching views
	text_line_height: proc(v: ^textedit.View) -> int,

	// Makes an idle main loop run a frame; called from the image decoding threads
	wake:         proc "contextless" (userdata: rawptr),

	// The files of the workspace (empty until indexed), and a request to index it
	files:        proc() -> []string,
	ensure_index: proc(),

	// A link to another file, at the heading it names ("" for none)
	open_file:    proc(path, heading: string),
}

env: Env
