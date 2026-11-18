package editor

import "term"

// Find in a terminal, with libghostty's search: it covers the active area and
// the scrollback and keeps its matches in step with new output. Its matching
// ignores ASCII case and has no whole-word or regex mode, so the bar's option
// buttons are off for terminals. "Next" goes up, toward older output, as a
// search from the prompt usually wants


Find_Term :: struct {
	search:   term.Search,
	vt:       term.Terminal, // the terminal it searches
	status:   term.Search_Status,
	jump:     bool, // select the newest match once there is one
}

// Ticks per frame; each does a bounded amount of work
@(private = "file")
FIND_TERM_TICKS :: 64


// A match's cells on one row of the grid, to draw behind the text
Term_Mark :: struct {
	row:         int,
	first, last: int, // columns, inclusive
}


find_term_restart :: proc(f: ^Find, t: ^Terminal) {
	ft := &f.term
	vt := t.session.vt
	if vt == nil do return

	// A search is bound to one terminal: a new one for another (or restarted)
	if ft.search == nil || ft.vt != vt {
		find_term_destroy(f)
		if term.search_new(nil, &ft.search, vt) != .Success {
			ft.search = nil
			return
		}
		ft.vt = vt
	}

	needle := term.Ghostty_String{raw_data(f.query), uint(len(f.query))}
	value := len(f.query) > 0 ? rawptr(&needle) : nil
	term.search_set(ft.search, .Needle, value)

	ft.status = .Feed_Required
	ft.jump = true
}


find_term_close :: proc(f: ^Find) {
	ft := &f.term
	if ft.search != nil do term.search_set(ft.search, .Needle, nil)

	if t, ok := f.pane.content.(^Terminal); ok {
		clear(&t.marks)
	}
}


find_term_destroy :: proc(f: ^Find) {
	ft := &f.term
	if ft.search != nil do term.search_free(ft.search)
	ft^ = {}
}


// A step of the search, then the matches in view as marks to draw
find_term_frame :: proc(f: ^Find, t: ^Terminal) {
	ft := &f.term

	// The query changed, or the terminal was restarted
	query := line_edit_string(&f.edit)
	if query != f.query || ft.vt != t.session.vt {
		find_restart(f, jump = true)
	}
	if ft.search == nil do return

	// Catch up with the terminal, a bounded amount. A search whose terminal was
	// freed (a restart) starts over on the new one
	if term.search_feed(ft.search) == .Invalid_Value {
		find_term_destroy(f)
		find_restart(f, jump = true)
		return
	}
	for _ in 0 ..< FIND_TERM_TICKS {
		term.search_tick(ft.search, &ft.status)
		if ft.status != .Running do break
	}

	// A new query selects the newest match, by the prompt
	total, _, _ := find_term_counts(f)
	if ft.jump && total > 0 {
		ft.jump = false
		find_term_select(f, t, older = true)
	}

	find_term_marks(f, t)
}


find_term_busy :: proc(f: ^Find) -> bool {
	return f.term.search != nil && f.query != "" && f.term.status != .Complete
}


// The next match (dir = +1, toward older output) or the previous one
find_term_step :: proc(f: ^Find, t: ^Terminal, dir: int) {
	if f.term.search == nil do return
	find_term_select(f, t, older = dir > 0)
}


// Selects the next match toward older output, or toward newer (libghostty
// scrolls to it), and makes it the terminal's selection, which is drawn as one
@(private = "file")
find_term_select :: proc(f: ^Find, t: ^Terminal, older: bool) {
	ft := &f.term
	moved := older ? term.search_select_next(ft.search) : term.search_select_prev(ft.search)
	if moved != .Success do return

	match: term.Selection
	if term.search_get(ft.search, .Selected_Match, &match) == .Success {
		term.terminal_set(ft.vt, .Selection, &match)
	}
	t.full_redraw = true
}


// The total, the selected match's index, and whether the search is caught up
find_term_counts :: proc(f: ^Find) -> (total, current: int, complete: bool) {
	ft := &f.term
	current = -1
	if ft.search == nil do return

	n: uint
	if term.search_get(ft.search, .Total_Matches, &n) == .Success do total = int(n)

	selected: uint
	if term.search_get(ft.search, .Selected_Index, &selected) == .Success {
		current = int(selected)
	}
	complete = ft.status == .Complete
	return
}


// The matches in view, as cells on rows of the grid
@(private = "file")
find_term_marks :: proc(f: ^Find, t: ^Terminal) {
	ft := &f.term
	clear(&t.marks)

	// Ask for the count first, then read them
	buf := term.Selection_Buffer{}
	result := term.search_get(ft.search, .Viewport_Matches, &buf)
	if result != .Out_Of_Space || buf.len == 0 {
		return
	}

	matches := make([]term.Selection, buf.len, context.temp_allocator)
	buf ={raw_data(matches), uint(len(matches)), 0}
	if term.search_get(ft.search, .Viewport_Matches, &buf) != .Success do return

	rows := int(t.session.rows)
	cols := int(t.session.cols)
	for &m in matches[:buf.len] {
		start, end: term.Point_Coordinate
		if term.terminal_point_from_grid_ref(ft.vt, &m.start, .Viewport, &start) != .Success {
			continue
		}
		if term.terminal_point_from_grid_ref(ft.vt, &m.end, .Viewport, &end) != .Success {
			continue
		}

		// One mark per row it covers, within the rows in view
		for row in int(start.y) ..= int(end.y) {
			if row >= rows do break

			first := row == int(start.y) ? int(start.x) : 0
			last := row == int(end.y) ? int(end.x) : cols - 1
			append(&t.marks, Term_Mark{row, first, last})
		}
	}
}
