package editor

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"

// Perf phase: the recent projects popup (project_picker.odin). Open project
// shows it under the sidebar's open folder button, the project open here first
// among the recent ones; Esc closes it; the button opens it again, and a press
// outside closes it


@(private = "file")
Picker_Step :: enum {
	Shown,  // Open project ran: laid out under the button, this project listed
	Closed, // Esc closed it; the button is pressed
	Button, // the button opened it; a press outside
	Done,   // the press outside closed it
}

@(private = "file")
ps: struct {
	step:  Picker_Step,
	mark:  int,    // the frame the step began
	mouse: [2]f32, // the pointer before the phase
}


@(private)
phase_project_picker :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 {
		ps = {mouse = g.mouse_pos}
		g.sidebar_visible = true
		run_command(.Open_Project)
		next_step(.Shown, frame)
		return false
	}
	if frame < ps.mark + 2 || g.animating {
		return false
	}

	switch ps.step {
	case .Shown:
		popup, shown := element_rect(clay.ID("ProjectPicker"))
		button, _ := element_rect(clay.ID("OpenButton"))
		check(p, "Open project shows the recent projects", g.project_picker.open && shown)
		check(p, "under the open folder button", shown && popup.y >= button.y + button.h)

		recent := state_recent_projects()
		first := len(recent) > 0 && same_path(recent[0], g.workspace.root)
		_, row := element_rect(clay.ID("ProjectPickerRow", 0))
		check(p, "this project first among them", first && row)

		escape: sdl.Event
		escape.type = .KEY_DOWN
		escape.key.key = sdl.K_ESCAPE
		project_picker_handle_event(&escape)
		check(p, "Esc closes it", !g.project_picker.open)

		g.mouse_pos = {button.x + button.w / 2, button.y + button.h / 2}
		g.mouse_pressed, g.mouse_down, g.mouse_clicks = true, true, 1
		next_step(.Closed, frame)

	case .Closed:
		g.mouse_down = false
		next_step(.Button, frame)

	case .Button:
		check(p, "the open folder button opens it", g.project_picker.open)

		// A press in the middle of the window, outside it
		g.mouse_pos = {f32(g.window_w) * 0.7, f32(g.window_h) * 0.7}
		g.mouse_pressed, g.mouse_down, g.mouse_clicks = true, true, 1
		next_step(.Done, frame)

	case .Done:
		g.mouse_down = false
		check(p, "a press outside closes it", !g.project_picker.open && g.pending == nil)
		g.mouse_pos = ps.mouse
		return true
	}
	return false
}


@(private = "file")
next_step :: proc(step: Picker_Step, frame: int) {
	ps.step = step
	ps.mark = frame
}
