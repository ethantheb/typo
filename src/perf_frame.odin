package editor

import clay "../vendor/clay-odin"
import "gfx"

// Perf phase: typo's own window frame (window_frame.odin). The caption strip is
// laid out across the top with the panes below it, and the system's hit test
// gets each kind of place right: the edges and corners resize, the strip drags,
// its buttons and the folder's name are typo's, as are the panes, and the
// background drags unless a popup is open; maximized, there are no edges


@(private = "file")
Frame_Step :: enum {
	Laid_Out, // the strip and the places in it; the recent projects are opened
	Popup,    // with them open the background is typo's
}

@(private = "file")
fs: struct {
	step: Frame_Step,
	mark: int, // the frame the step began
}


@(private)
phase_window_frame :: proc(p: ^Perf, frame: int) -> bool {
	if !window_frame.on {
		check(p, "without typo's frame the panes start at the top", frame_top() == 0)
		return true
	}

	if frame == 0 {
		fs = {}
		g.sidebar_visible = true
		return false
	}
	if frame < fs.mark + 2 || g.animating {
		return false
	}

	w := f32(g.window_w)
	h := f32(g.window_h)

	// Between the sidebar and the panes, only the window's background
	gap := [2]f32{work_rect().x - PANE_GAP / 2, h / 2}

	switch fs.step {
	case .Laid_Out:
		strip, laid_out := element_rect(clay.ID("TitleBar"))
		across := laid_out && strip.y == 0 && strip.w == w && strip.h == TITLE_BAR_HEIGHT
		check(p, "the caption strip is across the window's top", across)
		check(p, "and the panes start below it", work_rect().y >= strip.y + strip.h)

		// The edges and corners
		edges := hit({w / 2, 1}) == .Top &&
		         hit({w / 2, h - 1}) == .Bottom &&
		         hit({1, h / 2}) == .Left &&
		         hit({w - 1, h / 2}) == .Right
		check(p, "its edges resize the window", edges)

		corners := hit({1, 1}) == .Top_Left &&
		           hit({w - 1, 1}) == .Top_Right &&
		           hit({1, h - 1}) == .Bottom_Left &&
		           hit({w - 1, h - 1}) == .Bottom_Right
		check(p, "and so do its corners", corners)

		// The strip, its buttons and the folder's name
		b := &window_frame.buttons
		name, _ := element_rect(clay.ID("FolderName"))
		check(p, "the strip drags the window", hit({w / 2, TITLE_BAR_HEIGHT / 2}) == .Caption)
		check(p, "its maximize button is the system's", hit_middle(b[.Maximize]) == .Maximize)

		typos := hit_middle(b[.Minimize]) == .Client &&
		         hit_middle(b[.Close]) == .Client &&
		         hit_middle(name) == .Client
		check(p, "minimize, close and the folder's name are typo's", typos)

		// The panes and the background
		pane := g.panes.focused
		pane_rect, shown := element_rect(clay.ID("Pane", pane.id if pane != nil else 0))
		check(p, "a pane is typo's", shown && hit_middle(pane_rect) == .Client)
		check(p, "the background between them drags the window", hit(gap) == .Background)

		// Maximized
		maximized := hit({w / 2, 1}, true) == .Caption && hit({w - 1, h / 2}, true) != .Right
		check(p, "maximized, the edges don't resize", maximized)

		run_command(.Open_Project)
		fs.step = .Popup
		fs.mark = frame

	case .Popup:
		check(p, "the recent projects show", g.project_picker.open)
		check(p, "with them open the background is typo's", hit(gap) == .Client)
		check(p, "and the strip still drags", hit({w / 2, TITLE_BAR_HEIGHT / 2}) == .Caption)

		project_picker_toggle()
		return true
	}
	return false
}


// What the system's hit test answers at the point
@(private = "file")
hit :: proc(at: [2]f32, maximized := false) -> Frame_Hit {
	size := [2]f32{f32(g.window_w), f32(g.window_h)}
	return window_frame_hit(at, size, maximized)
}


@(private = "file")
hit_middle :: proc(r: gfx.Rect) -> Frame_Hit {
	return hit({r.x + r.w / 2, r.y + r.h / 2})
}
