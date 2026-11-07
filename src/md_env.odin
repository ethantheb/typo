package editor

import "core:strings"

import sdl "../vendor/sdl3"
import "mdview"

// Connects the rendered Markdown view (package mdview) to the app's state.

md_env_init :: proc() {
	mdview.env = {
		config       = md_config,
		input        = md_input,
		wake         = wake_main_loop,
		files        = md_files,
		ensure_index = finder_ensure_index,
		open_file    = md_open_file,
	}
}

@(private = "file")
md_config :: proc() -> mdview.Config {
	s := &g.settings
	return {
		font_size        = s.markdown_font_size,
		line_height      = s.markdown_line_height,
		max_width        = s.markdown_max_width,
		text_by_default  = s.markdown_view == "text",
		text_line_height = editor_line_height(),
		letter_spacing   = s.letter_spacing != 0,
	}
}

@(private = "file")
md_input :: proc() -> mdview.Input {
	return {g.mouse_pos, g.mouse_down, g.mouse_pressed, sdl.GetModState(), g.frame}
}

@(private = "file")
md_files :: proc() -> []string {
	return g.finder.files[:]
}

// Opens a linked file next frame, with the caret at the heading it names.
@(private = "file")
md_open_file :: proc(path, heading: string) {
	g.pending = Open_File(strings.clone(path))
	delete(g.open_heading)
	g.open_heading = strings.clone(heading)
}
