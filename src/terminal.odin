package editor

import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import "term"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"

// One terminal: a term.Session (libghostty-vt plus a shell on a pty) and the
// view of it.
//
// Each frame, terminal_frame feeds pending shell output to the terminal and
// refreshes a per-row cache (text runs and background runs with resolved
// colors) for the rows libghostty-vt reports as changed. Drawing only walks
// that cache, so an unchanged terminal costs almost nothing per frame.

TERMINAL_PUMP_BUDGET :: 4 * time.Millisecond
TERMINAL_PADDING :: 8 // logical pixels around the cell grid

Terminal :: struct {
	session:     term.Session,
	initialized: bool,
	spawned:     bool, // a shell has been started at least once
	// Shown in the header, e.g. "POWERSHELL". A fixed buffer: restarting sets it
	// while this frame's render commands may still point at it.
	shell_name:  [32]u8,
	shell_len:   int,
	busy:        bool, // output is still waiting to be parsed
	full_redraw: bool, // colors changed: rebuild every row
	rows:        [dynamic]Term_Row,
	cursor:      term.Render_Cursor,
	colors:      term.Render_Colors,
	view:        Rect, // cell grid area from the last layout
	cell_w:      f32,
	cell_h:      f32,
	selecting:   bool, // left button went down on the grid and selects text
	reporting:   bool, // left button went down on the grid and is sent to the program
	last_cell:   [2]int, // cell under the pointer at the last mouse report
	blink_t0:    u64,    // cursor blink phase starts here; reset by output and typing
	last_parsed: u64,
}

Term_Run :: struct {
	text:      [2]int, // byte range in Term_Row.text
	col:       int,
	end_col:   int,
	fg:        clay.Color,
	bold:      bool,
	underline: bool,
	strike:    bool,
}

Term_Bg :: struct {
	col, count: int,
	color:      clay.Color,
}

Term_Row :: struct {
	text:  [dynamic]u8,
	runs:  [dynamic]Term_Run,
	bgs:   [dynamic]Term_Bg,
	cells: [dynamic]rune, // first codepoint per column (0 = blank), for the block cursor
	sel:   [2]int,        // selected columns, inclusive, or {-1, -1}
}

// --- Lifecycle ---------------------------------------------------------------

// Creates the terminal state; the shell starts on the first frame it is shown,
// once its size is known.
terminal_init :: proc(t: ^Terminal) -> bool {
	if t.initialized do return true
	t.initialized = term.session_init(&t.session, 80, 24, wake_main_loop, nil)
	terminal_apply_theme(t)
	return t.initialized
}

terminal_destroy :: proc(t: ^Terminal) {
	if t.initialized do term.session_destroy(&t.session)
	for &row in t.rows do row_destroy(&row)
	delete(t.rows)
	t^ = {}
}

terminal_start_shell :: proc(t: ^Terminal) {
	shell := g.settings.terminal_shell != "" ? g.settings.terminal_shell : term.default_shell()
	t.shell_len = copy(t.shell_name[:], shell_display_name(shell))
	if !term.session_spawn(&t.session, shell, g.workspace.root, g.settings.bundled_conpty) {
		term.session_print_notice(&t.session, "Could not start the shell. Press Enter to try again.")
	}
	t.spawned = true
}

terminal_restart :: proc(t: ^Terminal) {
	term.session_kill(&t.session)
	term.session_print_notice(&t.session, "Restarting…")
	terminal_start_shell(t)
}

terminal_title :: proc(t: ^Terminal) -> string {
	return t.shell_len > 0 ? string(t.shell_name[:t.shell_len]) : "TERMINAL"
}

// The program a shell command line runs, for the header: its first word (or
// quoted path) without directory or extension, uppercased.
shell_display_name :: proc(command: string) -> string {
	cmd := strings.trim_space(command)
	program := cmd
	if strings.has_prefix(cmd, `"`) {
		end := strings.index_byte(cmd[1:], '"')
		program = end < 0 ? cmd[1:] : cmd[1:][:end]
	} else if space := strings.index_byte(cmd, ' '); space >= 0 {
		program = cmd[:space]
	}
	if slash := strings.last_index_any(program, `/\`); slash >= 0 do program = program[slash + 1:]
	if dot := strings.last_index_byte(program, '.'); dot > 0 do program = program[:dot]
	name := strings.to_upper(program, context.temp_allocator)
	switch name {
	case "PWSH": return "POWERSHELL"
	case "":     return "TERMINAL"
	}
	return name
}

// Terminal colors follow the editor theme.
terminal_apply_theme :: proc(t: ^Terminal) {
	if !t.initialized do return
	palette: [256]term.Color_Rgb
	term.color_palette_default(&palette[0])
	for c, i in theme.ansi do palette[i] = to_rgb(c)
	fg, bg, cursor := to_rgb(theme.text), to_rgb(theme.bg), to_rgb(theme.caret)
	vt := t.session.vt
	term.terminal_set(vt, .Color_Palette, &palette)
	term.terminal_set(vt, .Color_Foreground, &fg)
	term.terminal_set(vt, .Color_Background, &bg)
	term.terminal_set(vt, .Color_Cursor, &cursor)
	t.full_redraw = true
}

@(private = "file")
to_rgb :: proc(c: clay.Color) -> term.Color_Rgb {
	return {u8(c.r), u8(c.g), u8(c.b)}
}

@(private = "file")
to_color :: proc(c: term.Color_Rgb) -> clay.Color {
	return {f32(c.r), f32(c.g), f32(c.b), 255}
}

// --- Per frame ---------------------------------------------------------------

// Parses pending output, and while visible, sizes the grid to its element,
// handles the mouse and refreshes the row cache.
terminal_frame :: proc(t: ^Terminal, element: clay.ElementId, visible, interactive: bool) {
	s := &t.session
	busy, exited := term.session_pump(s, TERMINAL_PUMP_BUDGET)
	t.busy = busy
	if s.parsed != t.last_parsed {
		t.last_parsed = s.parsed
		t.blink_t0 = sdl.GetTicksNS()
	}
	if exited do term.session_print_notice(s, "Process exited. Press Enter to restart.")
	if !visible do return

	t.cell_w = editor_char_width()
	t.cell_h = f32(editor_line_height())
	if r, ok := element_rect(element); ok {
		t.view = {r.x + TERMINAL_PADDING, r.y + TERMINAL_PADDING / 2, r.w - TERMINAL_PADDING * 2, r.h - TERMINAL_PADDING}
		cols := u16(max(t.view.w / t.cell_w, 2))
		rows := u16(max(t.view.h / t.cell_h, 1))
		term.session_resize(s, cols, rows, u32(t.cell_w * g.ui_scale), u32(t.cell_h * g.ui_scale))
		// The shell starts once the real size is known, so it never sees 80x24.
		if !t.spawned do terminal_start_shell(t)
	}

	if interactive do terminal_mouse(t, element)
	update_rows(t)
}

@(private = "file")
update_rows :: proc(t: ^Terminal) {
	s := &t.session
	term.render_state_update(s.render, s.vt)
	t.cursor = term.init_sized(term.Render_Cursor)
	term.render_state_get(s.render, .Cursor, &t.cursor)
	t.colors = term.init_sized(term.Render_Colors)
	term.render_state_get(s.render, .Colors, &t.colors)

	n: u16
	term.render_state_get(s.render, .Rows, &n)
	for len(t.rows) > int(n) {
		row_destroy(&t.rows[len(t.rows) - 1])
		pop(&t.rows)
	}
	resized := len(t.rows) < int(n)
	for len(t.rows) < int(n) do append(&t.rows, Term_Row{})

	dirty: term.Render_Dirty
	term.render_state_get(s.render, .Dirty, &dirty)
	full := dirty == .Full || t.full_redraw || resized
	if dirty == .False && !full do return

	term.render_state_get(s.render, .Row_Iterator, &s.row_iter)
	for y := 0; term.render_state_row_iterator_next(s.row_iter) && y < len(t.rows); y += 1 {
		row_dirty: bool
		term.render_state_row_get(s.row_iter, .Dirty, &row_dirty)
		if full || row_dirty do build_row(t, &t.rows[y])
	}
	term.render_state_clean(s.render)
	t.full_redraw = false
}

@(private = "file")
row_destroy :: proc(row: ^Term_Row) {
	delete(row.text)
	delete(row.runs)
	delete(row.bgs)
	delete(row.cells)
}

// Reads one row from the render state into its cache: background runs, and
// text runs that each share a color and font. Blank cells extend the current
// run as spaces; a wide (2-cell) character, or one drawn by a fallback font,
// gets a run of its own so its advance can't shift the cells after it. With
// letter spacing every character does.
@(private = "file")
build_row :: proc(t: ^Terminal, row: ^Term_Row) {
	s := &t.session
	clear(&row.text)
	clear(&row.runs)
	clear(&row.bgs)
	clear(&row.cells)

	sel := term.init_sized(term.Row_Selection)
	row.sel = {-1, -1}
	if term.render_state_row_get(s.row_iter, .Selection, &sel) == .Success do row.sel = {int(sel.start_x), int(sel.end_x)}

	default_fg, default_bg := to_color(t.colors.foreground), to_color(t.colors.background)
	term.render_state_row_get(s.row_iter, .Cells, &s.cells)
	open := false // the last run may still be extended
	for col := 0; term.render_state_row_cells_next(s.cells); col += 1 {
		raw: term.Cell
		term.render_state_row_cells_get(s.cells, .Raw, &raw)
		wide: term.Cell_Wide
		term.cell_get(raw, .Wide, &wide)
		if wide == .Spacer_Tail || wide == .Spacer_Head {
			append(&row.cells, 0)
			continue
		}
		cells := wide == .Wide ? 2 : 1

		style := term.init_sized(term.Style)
		has_style: bool
		term.render_state_row_cells_get(s.cells, .Has_Styling, &has_style)
		if has_style do term.render_state_row_cells_get(s.cells, .Style, &style)
		fg_rgb, bg_rgb: term.Color_Rgb
		has_fg := term.render_state_row_cells_get(s.cells, .Fg_Color, &fg_rgb) == .Success
		has_bg := term.render_state_row_cells_get(s.cells, .Bg_Color, &bg_rgb) == .Success
		fg := has_fg ? to_color(fg_rgb) : default_fg
		bg := has_bg ? to_color(bg_rgb) : default_bg
		if style.inverse {
			fg, bg = bg, fg
			has_bg = true
		}
		if style.faint do fg.a = 140

		if has_bg {
			if last := len(row.bgs) - 1; last >= 0 && row.bgs[last].col + row.bgs[last].count == col && row.bgs[last].color == bg {
				row.bgs[last].count += cells
			} else {
				append(&row.bgs, Term_Bg{col, cells, bg})
			}
		}

		n: u32
		term.render_state_row_cells_get(s.cells, .Graphemes_Len, &n)
		if n == 0 || style.invisible {
			append(&row.cells, 0)
			// A blank continues the open run as a space (spaces draw nothing,
			// so the run's color doesn't matter for them).
			if open {
				r := &row.runs[len(row.runs) - 1]
				if r.end_col == col {
					append(&row.text, ' ')
					r.text[1] = len(row.text)
					r.end_col += 1
				}
			}
			continue
		}

		cps_buf: [8]u32
		cps := cps_buf[:]
		if n > len(cps_buf) do cps = make([]u32, n, context.temp_allocator)
		term.render_state_row_cells_get(s.cells, .Graphemes_Buf, raw_data(cps))
		append(&row.cells, rune(cps[0]))

		bold, underline, strike := style.bold, style.underline != 0, style.strikethrough
		solo := cells == 2 || g.settings.letter_spacing != 0 || !font_has_own_glyph(&g.text, .Editor, rune(cps[0]))
		if open {
			r := &row.runs[len(row.runs) - 1]
			open = r.end_col == col && r.fg == fg && r.bold == bold && r.underline == underline && r.strike == strike && !solo
		}
		if !open {
			append(&row.runs, Term_Run{text = {len(row.text), len(row.text)}, col = col, end_col = col, fg = fg, bold = bold, underline = underline, strike = strike})
		}
		r := &row.runs[len(row.runs) - 1]
		for cp in cps[:n] {
			bytes, size := utf8.encode_rune(rune(cp))
			append(&row.text, ..bytes[:size])
		}
		r.text[1] = len(row.text)
		r.end_col = col + cells
		open = !solo
	}
}

// --- Drawing -----------------------------------------------------------------

draw_terminal :: proc(renderer: ^sdl.Renderer, t: ^Terminal, b: clay.BoundingBox, scale: f32) {
	if t.cell_w <= 0 do return
	font := text_get_font(&g.text, .Editor, editor_font_size())
	if font == nil do return
	bold_font := text_get_font(&g.text, .Editor_Bold, editor_font_size())
	if bold_font == nil do bold_font = font
	push_clip_box(renderer, b)
	defer pop_clip(renderer)

	ox, oy := t.view.x * scale, t.view.y * scale
	adv, lh := t.cell_w * scale, t.cell_h * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)
	line_w := max(math.round(scale), 1)
	cell_x :: proc(ox, adv: f32, col: int) -> f32 {return math.round(ox + f32(col) * adv)}

	for &row, y in t.rows {
		ry := math.round(oy + f32(y) * lh)
		ry2 := math.round(oy + f32(y + 1) * lh)
		for bg in row.bgs {
			x := cell_x(ox, adv, bg.col)
			fill_rect(renderer, x, ry, cell_x(ox, adv, bg.col + bg.count) - x, ry2 - ry, bg.color)
		}
		if row.sel[0] >= 0 {
			x := cell_x(ox, adv, row.sel[0])
			fill_rect(renderer, x, ry, cell_x(ox, adv, row.sel[1] + 1) - x, ry2 - ry, theme.selection)
		}
		for run in row.runs {
			x := cell_x(ox, adv, run.col)
			draw_text(text_get(&g.text, run.bold ? bold_font : font, string(row.text[run.text[0]:run.text[1]])), x, ry + text_dy, run.fg)
			w := cell_x(ox, adv, run.end_col) - x
			if run.underline do fill_rect(renderer, x, ry2 - 2 * line_w, w, line_w, run.fg)
			if run.strike do fill_rect(renderer, x, math.round((ry + ry2) / 2), w, line_w, run.fg)
		}
	}

	draw_cursor(renderer, t, font, ox, oy, adv, lh, text_dy, line_w)
}

@(private = "file")
draw_cursor :: proc(renderer: ^sdl.Renderer, t: ^Terminal, font: ^ttf.Font, ox, oy, adv, lh, text_dy, line_w: f32) {
	c := t.cursor
	if !c.visible || !c.viewport_has_value || int(c.viewport_y) >= len(t.rows) do return
	col := int(c.viewport_x)
	if c.wide_tail && col > 0 do col -= 1
	row := &t.rows[c.viewport_y]
	glyph := col < len(row.cells) ? row.cells[col] : 0
	cells := col + 1 < len(row.cells) && glyph != 0 && row.cells[col + 1] == 0 && is_wide_rune(glyph) ? 2 : 1

	x := math.round(ox + f32(col) * adv)
	y := math.round(oy + f32(c.viewport_y) * lh)
	w := math.round(ox + f32(col + cells) * adv) - x
	h := math.round(oy + f32(c.viewport_y + 1) * lh) - y
	color := t.colors.cursor_has_value ? to_color(t.colors.cursor) : theme.caret

	style := c.visual_style
	if g.focus != .Terminal do style = .Block_Hollow
	else if !terminal_cursor_on(t) do return
	switch style {
	case .Block:
		fill_rect(renderer, x, y, w, h, color)
		if glyph != 0 {
			buf, n := utf8.encode_rune(glyph)
			draw_text(text_get(&g.text, font, string(buf[:n])), x, y + text_dy, to_color(t.colors.background))
		}
	case .Bar:
		fill_rect(renderer, x, y, max(2 * line_w, 1), h, color)
	case .Underline:
		fill_rect(renderer, x, y + h - 2 * line_w, w, 2 * line_w, color)
	case .Block_Hollow:
		fill_rect(renderer, x, y, w, line_w, color)
		fill_rect(renderer, x, y + h - line_w, w, line_w, color)
		fill_rect(renderer, x, y, line_w, h, color)
		fill_rect(renderer, x + w - line_w, y, line_w, h, color)
	}
}

// The blink phase: the cursor shows for CARET_BLINK_NS, hides for as long.
@(private = "file")
terminal_cursor_on :: proc(t: ^Terminal) -> bool {
	return !t.cursor.blinking || ((sdl.GetTicksNS() - t.blink_t0) / CARET_BLINK_NS) % 2 == 0
}

// Nanoseconds until the focused terminal's cursor next blinks, if it blinks.
terminal_blink_delay :: proc(t: ^Terminal) -> (ns: u64, ok: bool) {
	if !t.cursor.blinking || !t.cursor.visible do return 0, false
	since := sdl.GetTicksNS() - t.blink_t0
	return CARET_BLINK_NS - since % CARET_BLINK_NS, true
}

// Rough East Asian Wide / emoji test, used only to size the block cursor.
@(private = "file")
is_wide_rune :: proc(r: rune) -> bool {
	return r >= 0x1100 && (r <= 0x115F || (r >= 0x2E80 && r <= 0xA4CF) || (r >= 0xAC00 && r <= 0xD7A3) ||
		(r >= 0xF900 && r <= 0xFAFF) || (r >= 0xFE30 && r <= 0xFE4F) || (r >= 0xFF00 && r <= 0xFF60) ||
		(r >= 0xFFE0 && r <= 0xFFE6) || (r >= 0x1F300 && r <= 0x1FAFF) || (r >= 0x20000 && r <= 0x3FFFD))
}
