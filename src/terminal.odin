package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import "term"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"
import "gfx"
import "textedit"

// One terminal: a term.Session (libghostty-vt plus its program, on a pty here
// or in herdr-core: terminal_persist.odin) and the view of it.
//
// Each frame, terminal_frame feeds pending shell output to the terminal and
// refreshes a per-row cache (text runs and background runs with resolved
// colors) for the rows libghostty-vt reports as changed. Drawing only walks
// that cache, so an unchanged terminal costs almost nothing per frame


TERMINAL_PUMP_BUDGET :: 4 * time.Millisecond
TERMINAL_PADDING     :: 8 // logical pixels around the cell grid

Terminal :: struct {
	session:     term.Session,
	initialized: bool,
	spawned:     bool,   // a shell has been started at least once
	command:     string, // owned; run in the shell when it first starts
	persistent:  bool,   // runs in herdr-core, and outlives typo; kept on restart
	address:     string, // owned; the herdr-core terminal to show when first shown
	core_id:     string, // owned; the core that address is on
	has_focus:   bool,   // as the program was last told

	// Shown in titles, e.g. "PowerShell". A fixed buffer: restarting sets it
	// while this frame's render commands may still point at it
	shell_name:  [32]u8,
	shell_len:   int,

	busy:        bool, // output is still waiting to be parsed
	full_redraw: bool, // colors changed: rebuild every row
	rows:        [dynamic]Term_Row,
	cursor:      term.Render_Cursor,
	colors:      term.Render_Colors,
	view:        gfx.Rect, // cell grid area from the last layout
	last_view:   gfx.Rect, // the frame before's, to tell that the pane has settled
	zoom:        int,      // the text's size: steps from 100% in textedit.ZOOM_LEVELS
	cell_w:      f32,
	cell_h:      f32,
	marks:       [dynamic]Term_Mark, // search matches in view, set by find
	selecting:   bool,   // left button went down on the grid and selects text
	reporting:   bool,   // left button went down on the grid and is sent to the program
	last_cell:   [2]int, // cell under the pointer at the last mouse report
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


// --- Lifecycle ---------------------------------------------------------------------

// Creates the terminal state; the shell starts on the first frame it is shown,
// once its size is known. It runs in herdr-core if the setting says so
terminal_init :: proc(t: ^Terminal) -> bool {
	if t.initialized do return true

	t.initialized = term.session_init(&t.session, 80, 24, wake_main_loop, nil)
	t.persistent = persist_wanted()
	terminal_apply_theme(t)
	return t.initialized
}


// Frees the terminal, ending its program (a persistent one too: closing its
// pane ends it). terminal_detach before keeps a persistent one running
terminal_destroy :: proc(t: ^Terminal) {
	if t.initialized {
		term.session_kill(&t.session)
		term.session_destroy(&t.session)
	} else if t.address != "" {
		persist_kill(t.address, t.core_id) // from the session, never shown
	}
	for &row in t.rows do row_destroy(&row)
	delete(t.rows)
	delete(t.marks)
	delete(t.command)
	delete(t.address)
	delete(t.core_id)
	t^ = {}
}


// Lets go of the program without ending it: a persistent terminal goes on in
// herdr-core (typo quitting); a local shell ends. One from the session never
// shown forgets its address, so terminal_destroy doesn't end it
terminal_detach :: proc(t: ^Terminal) {
	if t.initialized {
		term.session_detach(&t.session)
		return
	}

	delete(t.address)
	delete(t.core_id)
	t.address, t.core_id = "", ""
}


// Starts the shell; the first time, running the terminal's command in it if
// it has one. A program that ended is let go of first
terminal_start_shell :: proc(t: ^Terminal) {
	term.session_kill(&t.session)
	shell := g.settings.terminal_shell != "" ? g.settings.terminal_shell : term.default_shell()
	t.shell_len = copy(t.shell_name[:], shell_display_name(shell))

	line := shell
	if t.command != "" {
		line = shell_running(shell, t.command)
		term.session_print_notice(&t.session, t.command)
		delete(t.command)
		t.command = ""
	}

	spawned := false
	local := !t.persistent
	if t.persistent {
		spawned, local = persist_start(t, line)
	}
	if local {
		spawned = term.session_spawn(
			&t.session,
			line,
			g.workspace.root,
			g.settings.bundled_conpty,
			ipc_shell_env(),
		)
	}
	if !spawned {
		notice := "Could not start the shell. Press Enter to try again."
		term.session_print_notice(&t.session, notice)
	}
	t.spawned = true
}


// A command line that starts `shell` running `command`, and leaves the shell
// open after it (temp)
shell_running :: proc(shell, command: string) -> string {
	when ODIN_OS == .Windows {
		switch strings.to_lower(shell_program(shell), context.temp_allocator) {
		case "pwsh", "powershell":
			return fmt.tprintf("%s -NoExit -Command %s", shell, command)
		case "cmd":
			// Everything after cmd's /k or /c is its command: add to that
			for word in strings.fields(shell, context.temp_allocator) {
				lower := strings.to_lower(word, context.temp_allocator)
				if lower == "/k" || lower == "/c" {
					return fmt.tprintf("%s & %s", shell, command)
				}
			}
			return fmt.tprintf("%s /K %s", shell, command)
		}

		// A shell typo doesn't know how to hand a command to
		if shell != term.default_shell() {
			return shell_running(term.default_shell(), command)
		}
		return shell
	} else {
		// Run by /bin/sh, which then becomes the shell
		return fmt.tprintf("%s; exec %s", command, shell)
	}
}


// Pins or unpins a terminal, asking first if a program runs in it (the
// unsaved-changes flow), as its shell restarts
terminal_ask_repin :: proc(p: ^Pane, pinned: bool) {
	resolve_unsaved({}, Repinning{p, pinned})
}


// Restarts a terminal pinned (in herdr-core) or here: its shell ends and a new
// one starts in its place. One from the session not shown yet ends in
// herdr-core, and one not started yet starts as asked when shown
terminal_repin :: proc(p: ^Pane, pinned: bool) {
	t := p.content.(^Terminal)
	if t.address != "" {
		persist_kill(t.address, t.core_id)
		delete(t.address)
		delete(t.core_id)
		t.address, t.core_id = "", ""
	}

	t.persistent = pinned
	if t.initialized do terminal_restart(t)
	pane_show(p)
}


terminal_restart :: proc(t: ^Terminal) {
	term.session_kill(&t.session)
	term.session_print_notice(&t.session, "Restarting…")
	terminal_start_shell(t)
}


terminal_title :: proc(t: ^Terminal) -> string {
	return t.shell_len > 0 ? string(t.shell_name[:t.shell_len]) : "Terminal"
}


// The program a shell command line runs, for titles
shell_display_name :: proc(command: string) -> string {
	program := shell_program(command)
	switch strings.to_lower(program, context.temp_allocator) {
	case "pwsh", "powershell": return "PowerShell"
	case "":                   return "Terminal"
	}
	return program
}


// The program of a command line: its first word (or quoted path) without
// directory or extension
@(private = "file")
shell_program :: proc(command: string) -> string {
	cmd := strings.trim_space(command)

	// The first word, or the quoted path
	program := cmd
	if strings.has_prefix(cmd, `"`) {
		end := strings.index_byte(cmd[1:], '"')
		program = end < 0 ? cmd[1:] : cmd[1:][:end]
	} else if space := strings.index_byte(cmd, ' '); space >= 0 {
		program = cmd[:space]
	}

	// Without directory or extension
	if slash := strings.last_index_any(program, `/\`); slash >= 0 {
		program = program[slash + 1:]
	}
	if dot := strings.last_index_byte(program, '.'); dot > 0 {
		program = program[:dot]
	}
	return program
}


// Terminal colors follow the editor theme
terminal_apply_theme :: proc(t: ^Terminal) {
	if !t.initialized do return

	palette: [256]term.Color_Rgb
	term.color_palette_default(&palette[0])
	for c, i in gfx.theme.ansi do palette[i] = to_rgb(c)
	fg, bg, cursor := to_rgb(gfx.theme.text), to_rgb(gfx.theme.bg), to_rgb(gfx.theme.caret)

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


// --- Per frame ---------------------------------------------------------------------

// Parses pending output, and while visible, sizes the grid to its element,
// handles the mouse and refreshes the row cache
terminal_frame :: proc(t: ^Terminal, element: clay.ElementId, visible, interactive: bool) {
	s := &t.session
	pump := term.session_pump(s, TERMINAL_PUMP_BUDGET)
	t.busy = pump.busy
	if pump.ended {
		term.session_print_notice(s, fmt.tprintf("%s Press Enter to restart.", pump.notice))
	} else if pump.notice != "" {
		term.session_print_notice(s, pump.notice)
	}

	// Programs that asked for focus reports hear when the keys come and go
	window_focused := sdl.GetWindowFlags(g.window) & {.INPUT_FOCUS} != {}
	has_focus := focused_terminal() == t && window_focused
	if has_focus != t.has_focus {
		t.has_focus = has_focus
		term.session_focus(s, has_focus)
	}
	if !visible do return

	zoom := textedit.zoom_factor(t.zoom)
	t.cell_w = editor_char_width(zoom)
	t.cell_h = f32(editor_line_height(zoom))

	if r, ok := element_rect(element); ok {
		t.view = {
			r.x + TERMINAL_PADDING,
			r.y + TERMINAL_PADDING / 2,
			r.w - TERMINAL_PADDING * 2,
			r.h - TERMINAL_PADDING,
		}

		// While panes move, the grid keeps its size until they settle, so the
		// shell isn't sent a resize every frame
		if !g.animating || !t.spawned {
			cols := u16(max(t.view.w / t.cell_w, 2))
			rows := u16(max(t.view.h / t.cell_h, 1))
			term.session_resize(s, cols, rows, u32(t.cell_w * gfx.scale), u32(t.cell_h * gfx.scale))
		}

		// The shell starts once the real size is known, so it never sees 80x24.
		// A pinned one waits for its pane to settle too (the same grid two
		// frames running), so herdr-core paints it once, at the size it keeps:
		// a repaint reflowed to another width splits its long lines
		settled := t.view == t.last_view
		t.last_view = t.view
		if !t.spawned {
			if settled || !t.persistent {
				terminal_start_shell(t)
			} else {
				wake_main_loop(nil) // another frame, to see it settled
			}
		}
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

	// As many cached rows as the grid has
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
	if dirty == .False && !full {
		return
	}

	// Rebuild the rows that changed
	term.render_state_get(s.render, .Row_Iterator, &s.row_iter)
	for y := 0; term.render_state_row_iterator_next(s.row_iter) && y < len(t.rows); y += 1 {
		row_dirty: bool
		term.render_state_row_get(s.row_iter, .Dirty, &row_dirty)
		if full || row_dirty {
			build_row(t, &t.rows[y])
		}
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
// gets a run of its own so its advance can't shift the cells after it, and so
// does one drawn as shapes (gfx.is_box_glyph). With letter spacing every
// character does
@(private = "file")
build_row :: proc(t: ^Terminal, row: ^Term_Row) {
	s := &t.session
	clear(&row.text)
	clear(&row.runs)
	clear(&row.bgs)
	clear(&row.cells)

	sel := term.init_sized(term.Row_Selection)
	row.sel = {-1, -1}
	has_sel := term.render_state_row_get(s.row_iter, .Selection, &sel) == .Success
	if has_sel do row.sel = {int(sel.start_x), int(sel.end_x)}

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

		// Its style and colors
		style: term.Style
		has_style: bool
		term.render_state_row_cells_get(s.cells, .Has_Styling, &has_style)
		if has_style do term.render_state_row_cells_get(s.cells, .Style, &style)
		attrs := style.flags

		fg_rgb, bg_rgb: term.Color_Rgb
		has_fg := term.render_state_row_cells_get(s.cells, .Fg_Color, &fg_rgb) == .Success
		has_bg := term.render_state_row_cells_get(s.cells, .Bg_Color, &bg_rgb) == .Success
		fg := has_fg ? to_color(fg_rgb) : default_fg
		bg := has_bg ? to_color(bg_rgb) : default_bg
		if attrs.inverse {
			fg, bg = bg, fg
			has_bg = true
		}
		if attrs.faint do fg.a = 140

		// The background extends the last run of its color, or starts one
		if has_bg {
			last := len(row.bgs) - 1
			extends := last >= 0 &&
			           row.bgs[last].col + row.bgs[last].count == col &&
			           row.bgs[last].color == bg
			if extends {
				row.bgs[last].count += cells
			} else {
				append(&row.bgs, Term_Bg{col, cells, bg})
			}
		}

		n: u32
		term.render_state_row_cells_get(s.cells, .Graphemes_Len, &n)
		if n == 0 || attrs.invisible {
			append(&row.cells, 0)

			// A blank continues the open run as a space (spaces draw nothing,
			// so the run's color doesn't matter for them)
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

		// Its codepoints
		cps_buf: [8]u32
		cps := cps_buf[:]
		if n > len(cps_buf) do cps = make([]u32, n, context.temp_allocator)
		graphemes := term.Codepoint_Buffer{raw_data(cps), uint(len(cps)), 0}
		term.render_state_row_cells_get(s.cells, .Graphemes_Buf, &graphemes)
		append(&row.cells, rune(cps[0]))

		// The open run takes it if it looks the same, else a new run starts
		bold, underline, strike := attrs.bold, attrs.underline != 0, attrs.strikethrough
		solo := cells == 2 ||
		        g.settings.letter_spacing != 0 ||
		        gfx.is_box_glyph(rune(cps[0])) ||
		        !gfx.font_has_own_glyph(&gfx.text_system, .Editor, rune(cps[0]))
		if open {
			r := &row.runs[len(row.runs) - 1]
			open = r.end_col == col &&
			       r.fg == fg &&
			       r.bold == bold &&
			       r.underline == underline &&
			       r.strike == strike &&
			       !solo
		}
		if !open {
			append(
				&row.runs,
				Term_Run {
					text = {len(row.text), len(row.text)},
					col = col,
					end_col = col,
					fg = fg,
					bold = bold,
					underline = underline,
					strike = strike,
				},
			)
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


// --- Drawing -----------------------------------------------------------------------

draw_terminal :: proc(t: ^Terminal, b: clay.BoundingBox, scale: f32) {
	if t.cell_w <= 0 do return

	size := editor_font_size(textedit.zoom_factor(t.zoom))
	font := gfx.text_get_font(&gfx.text_system, .Editor, size)
	if font == nil do return
	bold_font := gfx.text_get_font(&gfx.text_system, .Editor_Bold, size)
	if bold_font == nil do bold_font = font

	gfx.push_clip_box(b)
	defer gfx.pop_clip()

	ox, oy := t.view.x * scale, t.view.y * scale
	adv, lh := t.cell_w * scale, t.cell_h * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)
	line_w := max(math.round(scale), 1)
	box_line := gfx.box_line_width(.Editor, font, adv)
	boxes: gfx.Box_Batch

	for &row, y in t.rows {
		ry := math.round(oy + f32(y) * lh)
		ry2 := math.round(oy + f32(y + 1) * lh)

		// Backgrounds, then the selection
		for bg in row.bgs {
			x := term_cell_x(ox, adv, bg.col)
			gfx.fill_rect(x, ry, term_cell_x(ox, adv, bg.col + bg.count) - x, ry2 - ry, bg.color)
		}
		for m in t.marks {
			if m.row != y do continue

			x := term_cell_x(ox, adv, m.first)
			mark_w := term_cell_x(ox, adv, m.last + 1) - x
			gfx.fill_rect(x, ry, mark_w, ry2 - ry, gfx.theme.find_match)
		}
		if row.sel[0] >= 0 {
			x := term_cell_x(ox, adv, row.sel[0])
			sel_w := term_cell_x(ox, adv, row.sel[1] + 1) - x
			gfx.fill_rect(x, ry, sel_w, ry2 - ry, gfx.theme.selection)
		}

		// Text, and the characters drawn as shapes filling their cells
		for run in row.runs {
			x := term_cell_x(ox, adv, run.col)
			text := string(row.text[run.text[0]:run.text[1]])
			if r, is_box := gfx.box_glyph_in(text); is_box {
				w := term_cell_x(ox, adv, run.end_col) - x
				gfx.box_batch_add(&boxes, r, x, ry, w, ry2 - ry, box_line, run.fg)
				continue
			}

			run_font := run.bold ? bold_font : font
			gfx.draw_text(gfx.text_get(&gfx.text_system, run_font, text), x, ry + text_dy, run.fg)
		}
		gfx.box_batch_draw(&boxes)

		// Their lines
		for run in row.runs {
			x := term_cell_x(ox, adv, run.col)
			w := term_cell_x(ox, adv, run.end_col) - x
			if run.underline do gfx.fill_rect(x, ry2 - 2 * line_w, w, line_w, run.fg)
			if run.strike do gfx.fill_rect(x, math.round((ry + ry2) / 2), w, line_w, run.fg)
		}
	}

	draw_cursor(t, font, ox, oy, adv, lh, text_dy, line_w, box_line)
}


// The x of a column's left edge
@(private = "file")
term_cell_x :: proc(ox, adv: f32, col: int) -> f32 {
	return math.round(ox + f32(col) * adv)
}


// The cursor; `box_line` is the line width of characters drawn as shapes
@(private = "file")
draw_cursor :: proc(
	t: ^Terminal,
	font: ^ttf.Font,
	ox, oy, adv, lh, text_dy, line_w, box_line: f32,
) {
	c := t.cursor
	if !c.visible || !c.viewport_has_value || int(c.viewport_y) >= len(t.rows) {
		return
	}

	// Its cell, two wide on a wide character
	col := int(c.viewport_x)
	if c.wide_tail && col > 0 {
		col -= 1
	}
	row := &t.rows[c.viewport_y]
	glyph := col < len(row.cells) ? row.cells[col] : 0
	blank_after := col + 1 < len(row.cells) && glyph != 0 && row.cells[col + 1] == 0
	cells := blank_after && is_wide_rune(glyph) ? 2 : 1

	x := math.round(ox + f32(col) * adv)
	y := math.round(oy + f32(c.viewport_y) * lh)
	w := math.round(ox + f32(col + cells) * adv) - x
	h := math.round(oy + f32(c.viewport_y + 1) * lh) - y
	color := t.colors.cursor_has_value ? to_color(t.colors.cursor) : gfx.theme.caret

	// Steady: programs asking for a blinking cursor get it shown always
	style := c.visual_style
	if focused_terminal() != t do style = .Block_Hollow

	switch style {
	case .Block:
		gfx.fill_rect(x, y, w, h, color)
		if gfx.is_box_glyph(glyph) {
			gfx.draw_box_glyph(glyph, x, y, w, h, box_line, to_color(t.colors.background))
		} else if glyph != 0 {
			buf, n := utf8.encode_rune(glyph)
			text := gfx.text_get(&gfx.text_system, font, string(buf[:n]))
			gfx.draw_text(text, x, y + text_dy, to_color(t.colors.background))
		}

	case .Bar:
		gfx.draw_caret(x, y, h, gfx.scale, color)

	case .Underline:
		gfx.fill_rect(x, y + h - 2 * line_w, w, 2 * line_w, color)

	case .Block_Hollow:
		gfx.fill_rect(x, y, w, line_w, color)
		gfx.fill_rect(x, y + h - line_w, w, line_w, color)
		gfx.fill_rect(x, y, line_w, h, color)
		gfx.fill_rect(x + w - line_w, y, line_w, h, color)
	}
}


// Rough East Asian Wide / emoji test, used only to size the block cursor
@(private = "file")
is_wide_rune :: proc(r: rune) -> bool {
	if r < 0x1100 do return false

	return r <= 0x115F ||
	       (r >= 0x2E80 && r <= 0xA4CF) ||
	       (r >= 0xAC00 && r <= 0xD7A3) ||
	       (r >= 0xF900 && r <= 0xFAFF) ||
	       (r >= 0xFE30 && r <= 0xFE4F) ||
	       (r >= 0xFF00 && r <= 0xFF60) ||
	       (r >= 0xFFE0 && r <= 0xFFE6) ||
	       (r >= 0x1F300 && r <= 0x1FAFF) ||
	       (r >= 0x20000 && r <= 0x3FFFD)
}
