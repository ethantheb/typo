package mdview

import "core:math"

import clay "../../vendor/clay-odin"
import "../markdown"
import sdl "../../vendor/sdl3"
import ttf "../../vendor/sdl3/ttf"
import "../syntax"
import "../gfx"
import "../textedit"

// Drawing the rendered Markdown view: each visible line's layout, with code
// colored by its language


// A line being drawn: its layout and text, and its top in pixels
@(private = "file")
Visible :: struct {
	line:  int,
	y:     f32,
	L:     ^Line_Layout,
	text:  string,
	start: int,
}


// Draws the lines in view. `caret_on` is whether the editor's caret is in its
// visible phase
@(private)
draw :: proc(e: ^View, b: clay.BoundingBox, scale: f32, caret_on: bool) {
	mv := &e.mdv
	hm := &mv.heights
	if hm.lines == 0 do return

	gfx.push_clip_box(b)
	defer gfx.pop_clip()

	// The lines in view, with their tops
	left := b.x + mv.col_x * scale
	first, top := hm_find(hm, e.scroll_y)
	y := f64(b.y) + (top - e.scroll_y) * f64(scale)

	lines := make([dynamic]Visible, context.temp_allocator)
	for line := first; line < hm.lines && y < f64(b.y + b.height); line += 1 {
		append(&lines, visible(e, line, f32(y)))
		y += f64(hm_get(hm, line)) * f64(scale)
	}

	// What is behind their text, the selections, then the text
	for v in lines do draw_line_back(e, v, left, scale)
	if !mv.caretless do draw_selections(e, lines[:], left, scale)

	caret_on := !mv.caretless && caret_on
	for v in lines {
		hl := code_colors(e, v.line, v.text)
		draw_line_text(e, v, hl, left, scale, caret_on)
	}

	// Expand buttons of tables whose text wraps, brighter under the pointer
	for v in lines {
		box, t := table_button(e, v.line) or_continue

		r := clay.BoundingBox{
			math.round(left + box.x * scale),
			math.round(v.y + box.y * scale),
			math.round(box.w * scale),
			math.round(box.h * scale),
		}
		at := env.input().mouse_pos * scale
		hovered := at.x >= r.x && at.x < r.x + r.width && at.y >= r.y && at.y < r.y + r.height
		if hovered do gfx.fill_rounded_rect(r, clay.CornerRadiusAll(4 * scale), gfx.theme.hover)

		icon := mv.wide_tables[t.first] ? gfx.Icon.Fold_Horizontal : gfx.Icon.Move_Horizontal
		color := hovered ? gfx.theme.text : gfx.theme.text_faint
		gfx.draw_icon({icon, color, 15}, r)
	}
}


@(private)
Code_Colors :: struct {
	hl:    []syntax.Highlight, // by byte of the line
	state: syntax.Lex_State,   // at the end of the line
}


// Syntax colors of line i if it is code in a fence that names its language
// (the only text drawn in it), else nil. Lexed from the line before when that
// one is cached, so scrolling lexes only the lines coming into view
@(private = "file")
code_colors :: proc(e: ^View, i: int, text: string) -> []syntax.Highlight {
	mv := &e.mdv
	lang := markdown.line_state(e.md, i).fence_lang
	if e.md.lines[i].kind != .Fence_Body || lang == .None {
		return nil
	}
	if c, ok := mv.code_hl[i]; ok {
		return c.hl
	}

	// The lexer state at the line's start
	rules := syntax.rules_for(lang)
	state: syntax.Lex_State
	if prev, ok := mv.code_hl[i - 1]; ok && e.md.lines[i - 1].kind == .Fence_Body {
		state = prev.state
	} else {
		state = markdown.fence_state_before(e.md, &e.buf, rules, i)
	}

	// Lex the code, after the line's indentation
	d := markdown.line_detail(e.md, i, text)
	lo := min(int(d.content[0]), len(text))
	hl := make([]syntax.Highlight, len(text), mv.doc_allocator)
	state = syntax.lex_line(rules, state, transmute([]u8)text[lo:], hl[lo:])

	mv.code_hl[i] = {hl, state}
	return hl
}


// The pixel column of x, from the text column's left
@(private = "file")
screen_x :: proc(left, x, scale: f32) -> f32 {
	return math.round(left + x * scale)
}


// Line i laid out, with its top at y (pixels)
@(private = "file")
visible :: proc(e: ^View, i: int, y: f32) -> Visible {
	text, start := line_text(e, i)
	return {i, y, line_layout(e, i), text, start}
}


// What is drawn behind a line's text and its selections: images, a code
// block's background and scroll bar, quote bars, rules, table borders, marks
@(private = "file")
draw_line_back :: proc(e: ^View, v: Visible, left, scale: f32) {
	mv := &e.mdv
	L, y := v.L, v.y
	h := L.height * scale

	// Images, or a box with the alt text while one loads or when it can't
	for box in L.images {
		r := clay.BoundingBox{
			screen_x(left, box.x, scale),
			math.round(y + box.y * scale),
			math.round(box.w * scale),
			math.round(box.h * scale),
		}
		img := get_image(string(L.strings[box.path[0]:box.path[1]]))
		if img.state == .Ready {
			dst := sdl.FRect{r.x, r.y, r.width, r.height}
			gfx.flush_text()
			_ = sdl.RenderTexture(gfx.renderer, img.texture, nil, &dst)
			continue
		}

		gfx.fill_rounded_rect(r, clay.CornerRadiusAll(6 * scale), gfx.theme.md_code_bg)
		if img.state == .Failed {
			icon_box := clay.BoundingBox{r.x, r.y, r.width, r.height * 0.6}
			gfx.draw_icon({.Image_Off, gfx.theme.text_faint, u16(24)}, icon_box)
		}

		if box.alt[1] <= box.alt[0] do continue
		font := gfx.text_get_font(&gfx.text_system, .Md_Italic, font_size(e))
		if font == nil do continue
		alt := gfx.text_get(&gfx.text_system, font, v.text[box.alt[0]:box.alt[1]])
		if alt == nil do continue

		tw, th: i32
		_ = ttf.GetTextSize(alt, &tw, &th)
		alt_x := math.round(r.x + (r.width - f32(tw)) / 2)
		alt_y := math.round(r.y + r.height * 0.62)
		gfx.draw_text(alt, alt_x, alt_y, gfx.theme.text_dim)
	}

	// A code block's background, its first and last lines rounded
	if L.code_bg != {} {
		radius := 6 * scale
		top_radius := L.round[0] ? radius : 0
		bottom_radius := L.round[1] ? radius : 0
		corners := clay.CornerRadius{top_radius, top_radius, bottom_radius, bottom_radius}

		x0 := screen_x(left, L.code_bg[0], scale)
		x1 := screen_x(left, L.code_bg[1], scale)
		bg := clay.BoundingBox{x0, math.round(y), x1 - x0, math.ceil(h)}
		gfx.fill_rounded_rect(bg, corners, gfx.theme.md_code_bg)
	}

	// Quote bars
	for bar in L.bars[:L.n_bars] {
		bar_x := screen_x(left, bar, scale)
		bar_w := max(math.round(3 * scale), 1)
		gfx.fill_rect(bar_x, math.round(y), bar_w, math.ceil(h), gfx.theme.md_rule)
	}

	// A code block's scroll bar
	if L.code_bg != {} && L.round[1] {
		draw_code_bar(e, v.line, scale)
	}

	// A thematic break
	if L.kind == .Rule {
		gfx.fill_rect(
			screen_x(left, L.indent, scale),
			math.round(y + h / 2),
			(mv.col_w - L.indent) * scale,
			max(math.round(scale), 1),
			gfx.theme.md_rule,
		)
	}

	if len(L.edges) > 1 do draw_table_borders(L, left, y, h, scale)
	draw_marks(e, L, v.text, v.start, left, y, scale)
}


// A line's text, over its selections, and its carets
@(private = "file")
draw_line_text :: proc(
	e: ^View,
	v: Visible,
	hl: []syntax.Highlight,
	left, scale: f32,
	caret_on: bool,
) {
	L, y, text, start := v.L, v.y, v.text, v.start
	h := L.height * scale

	// Code scrolled sideways stays inside its box; markers hanging left of it
	// are drawn first
	clipped := false
	if L.code_bg != {} && L.kind == .Code {
		x0 := screen_x(left, L.code_bg[0] + CODE_PAD, scale)
		x1 := screen_x(left, L.code_bg[1] - CODE_PAD, scale)
		for run in L.runs {
			if hanging(L, run) do draw_run(L, run, text, hl, left, y, scale)
		}
		gfx.push_clip_box({x0 - 2 * scale, math.round(y), x1 - x0 + 4 * scale, math.ceil(h)})
		clipped = true
	}
	defer if clipped do gfx.pop_clip()

	// Text
	end := start + len(text)
	for _, k in L.runs {
		run := md_run(L, k)

		// Code lines drew their hanging markers outside the clip
		if clipped && hanging(L, run) {
			continue
		}
		draw_run(L, run, text, hl, left, y, scale)
	}

	// Carets
	if caret_on {
		for j := textedit.first_selection_at(e, start); j < len(e.sels); j += 1 {
			head := e.sels[j].head
			if textedit.sel_lo(e.sels[j]) > end do break
			if head < start || head > end {
				continue
			}

			_, x, top, ch := caret_box(L, text, head - start)
			gfx.draw_caret(
				screen_x(left, x, scale),
				math.round(y + top * scale),
				math.ceil(ch * scale),
				scale,
				gfx.theme.caret,
			)
		}
	}
}


// Each selection over the lines in view as one shape (gfx.fill_selection), the
// lines just outside the view included for the shape's ends. Where it goes on
// into the line before or after, a row reaches up to its line's top or down to
// its bottom, so rows join across a line's padding (not across an image under
// it). Selected table cells are boxes of their own
@(private = "file")
draw_selections :: proc(e: ^View, lines: []Visible, left, scale: f32) {
	if len(lines) == 0 do return
	hm := &e.mdv.heights

	// The lines in view and one either side
	around := make([dynamic]Visible, 0, len(lines) + 2, context.temp_allocator)
	top, bottom := lines[0], lines[len(lines) - 1]
	if top.line > 0 {
		y := top.y - f32(hm_get(hm, top.line - 1)) * scale
		append(&around, visible(e, top.line - 1, y))
	}
	append(&around, ..lines)
	if bottom.line + 1 < hm.lines {
		y := bottom.y + f32(hm_get(hm, bottom.line)) * scale
		append(&around, visible(e, bottom.line + 1, y))
	}

	view_lo := around[0].start
	last := around[len(around) - 1]
	view_hi := last.start + len(last.text)
	pad, radius := gfx.selection_look(f32(font_size(e)) * scale)
	rows := make([dynamic]gfx.Rect, context.temp_allocator)

	for j := textedit.first_selection_at(e, view_lo); j < len(e.sels); j += 1 {
		lo, hi := textedit.sel_lo(e.sels[j]), textedit.sel_hi(e.sels[j])
		if lo > view_hi do break
		if lo == hi do continue

		clear(&rows)
		for v in around {
			if v.start > hi do break

			if v.L.kind == .Table {
				draw_cell_selection(v, lo, hi, left, scale, radius)
			} else {
				add_selection_rows(e, &rows, v, lo, hi, left, scale)
			}
		}
		gfx.fill_selection(rows[:], pad, radius, gfx.theme.selection)
	}
}


// Adds the rows of line v that a selection [lo, hi] covers
@(private = "file")
add_selection_rows :: proc(
	e: ^View,
	rows: ^[dynamic]gfx.Rect,
	v: Visible,
	lo, hi: int,
	left, scale: f32,
) {
	L, start := v.L, v.start
	end := start + len(v.text)
	if hi < start || lo > end {
		return
	}

	for r, ri in L.rows {
		x1, x2, ok := selection_span(L, v.text, ri, lo - start, hi - start)
		if !ok do continue

		// Selected past the line's end: its newline
		last_row := ri == len(L.rows) - 1
		if hi > end && last_row {
			x2 += f32(font_size(e)) * 0.4
		}
		if x2 <= x1 do continue

		// Reaching the lines before and after, across the line's padding
		row_top := r.y
		row_bottom := r.y + r.h
		if ri == 0 && lo < start {
			row_top = 0
		}
		if last_row && hi > end && len(L.images) == 0 {
			row_bottom = L.height
		}

		x := screen_x(left, x1, scale)
		y := math.round(v.y + row_top * scale)
		w := screen_x(left, x2, scale) - x
		h := math.round(v.y + row_bottom * scale) - y
		append(rows, gfx.Rect{x, y, w, h})
	}
}


// A selection [lo, hi] over a table row: each box it covers (a whole cell, or
// a line of a cell's text) rounded on its own
@(private = "file")
draw_cell_selection :: proc(v: Visible, lo, hi: int, left, scale, radius: f32) {
	end := v.start + len(v.text)
	if hi < v.start || lo > end {
		return
	}

	for box in table_selection(v.L, v.text, lo - v.start, hi - v.start) {
		x := screen_x(left, box.x, scale)
		y := math.round(v.y + box.y * scale)
		w := screen_x(left, box.x + box.w, scale) - x
		h := math.round(v.y + (box.y + box.h) * scale) - y
		r := [1]gfx.Rect{{x, y, w, h}}
		gfx.fill_selection(r[:], 0, radius, gfx.theme.selection)
	}
}


// The marks (search matches) on a line, behind its text. Marks in hidden syntax
// have no width and draw nothing
@(private = "file")
draw_marks :: proc(
	e: ^View,
	L: ^Line_Layout,
	text: string,
	start: int,
	left, y: f32,
	scale: f32,
) {
	end := start + len(text)

	for j := textedit.first_mark_at(e.tv, start); j < len(e.tv.marks); j += 1 {
		lo := e.tv.marks[j][0] - start
		hi := e.tv.marks[j][1] - start
		if lo > len(text) do break

		lo = max(lo, 0)
		hi = min(hi, end - start)

		// In a table, by cell
		if L.kind == .Table {
			for box in table_selection(L, text, lo, hi) {
				x0 := screen_x(left, box.x, scale)
				x1 := screen_x(left, box.x + box.w, scale)
				box_y := math.round(y + box.y * scale)
				box_h := math.ceil(box.h * scale)
				gfx.fill_rect(x0, box_y, x1 - x0, box_h, gfx.theme.find_match)
			}
			continue
		}

		// Elsewhere, by wrapped row
		for r, ri in L.rows {
			x1, x2, ok := selection_span(L, text, ri, lo, hi)
			if !ok do continue

			row_x := screen_x(left, x1, scale)
			row_y := math.round(y + r.y * scale)
			row_h := math.ceil(r.h * scale)
			gfx.fill_rect(row_x, row_y, (x2 - x1) * scale, row_h, gfx.theme.find_match)
		}
	}
}


// A code block's sideways scroll bar, drawn on its last line when it scrolls;
// brighter while dragged or under the pointer
@(private = "file")
draw_code_bar :: proc(e: ^View, line: int, scale: f32) {
	track, thumb, _, ok := code_bar(e, line)
	if !ok do return

	active :=
		e.mdv.code_drag.grab != nil ||
		gfx.rect_contains(code_bar_grab_area(track), env.input().mouse_pos)
	r := clay.BoundingBox{
		math.round(thumb.x * scale),
		math.round(thumb.y * scale),
		math.round(thumb.w * scale),
		max(math.round(thumb.h * scale), 2),
	}
	color := active ? gfx.theme.text_dim : gfx.theme.md_rule
	gfx.fill_rounded_rect(r, clay.CornerRadiusAll(r.height / 2), color)
}


// Table borders: around each cell, the header on a background
@(private = "file")
draw_table_borders :: proc(L: ^Line_Layout, left, y, h, scale: f32) {
	x0 := screen_x(left, L.edges[0], scale)
	x1 := screen_x(left, L.edges[len(L.edges) - 1], scale)
	thick := max(math.round(scale), 1)
	top := math.round(y)
	bottom := math.round(y + h)

	// The delimiter row is the rule under the header, as thick as the others
	if L.kind == .Thin {
		gfx.fill_rect(x0, top, x1 - x0, max(bottom - top, thick), gfx.theme.md_rule)
		return
	}

	if L.header {
		gfx.fill_rect(x0, top, x1 - x0, bottom - top, gfx.theme.md_code_bg)
		gfx.fill_rect(x0, top, x1 - x0, thick, gfx.theme.md_rule)
	}
	for edge in L.edges {
		gfx.fill_rect(screen_x(left, edge, scale), top, thick, bottom - top, gfx.theme.md_rule)
	}
	if !L.header do gfx.fill_rect(x0, bottom - thick, x1 - x0, thick, gfx.theme.md_rule)
}


@(private = "file")
draw_run :: proc(
	L: ^Line_Layout,
	run: Run,
	text: string,
	hl: []syntax.Highlight,
	left, y: f32,
	scale: f32,
) {
	r := L.rows[run.row]
	ry := y + r.y * scale
	m := gfx.font_metrics(&gfx.text_system, run.font, run.size)
	baseline := ry + (r.baseline + run.dy) * scale
	x := screen_x(left, run.x + run.dx, scale)

	#partial switch run.kind {
	case .Text:
		if run.hi == run.lo do return // a line break in a table cell

		s := run.subst != {} ? string(L.strings[run.subst[0]:run.subst[1]]) : text[run.lo:run.hi]

		// Backgrounds
		if .Code in run.style {
			pad := (CODE_SPAN_PAD - 1) * scale
			bg := clay.BoundingBox{
				x - pad,
				math.round(baseline - (m.ascent + 2) * scale),
				run.w * scale + 2 * pad,
				math.round((m.ascent + m.descent + 4) * scale),
			}
			gfx.fill_rounded_rect(bg, clay.CornerRadiusAll(4 * scale), gfx.theme.md_code_bg)
		}
		if .Mark in run.style {
			mark_y := math.round(baseline - m.ascent * scale)
			mark_h := math.round((m.ascent + m.descent) * scale)
			gfx.fill_rect(x, mark_y, run.w * scale, mark_h, gfx.theme.md_mark_bg)
		}

		// The text, superscript raised
		font := gfx.text_get_font(&gfx.text_system, run.font, run.size)
		if font == nil do return
		color := md_color(run.color)
		rise := .Super in run.style ? f32(run.size) * 0.5 * scale : 0
		if t := gfx.text_get(&gfx.text_system, font, s); t != nil {
			gfx.draw_text(t, x, math.round(baseline - m.ascent * scale - rise), color)
		}

		// Lines through or under it
		thick := max(math.round(scale), 1)
		if .Underline in run.style {
			gfx.fill_rect(x, math.round(baseline + 2 * scale), run.w * scale, thick, color)
		}
		if .Strike in run.style {
			strike_y := math.round(baseline - f32(run.size) * 0.3 * scale)
			gfx.fill_rect(x, strike_y, run.w * scale, thick, color)
		}

	case .Mono:
		font := gfx.text_get_font(&gfx.text_system, .Editor, run.size)
		if font == nil do return

		seg := text[run.lo:run.hi]
		lexed := run.color == .Code && int(run.hi) <= len(hl)
		seg_hl := lexed ? hl[run.lo:run.hi] : nil
		for part in code_runs(seg, seg_hl) {
			color := run.color == .Code ? md_color(.Code, part.hl) : md_color(run.color)
			if t := gfx.text_get(&gfx.text_system, font, part.text); t != nil {
				part_x := math.round(x + f32(part.col) * L.char_w * scale)
				gfx.draw_text(t, part_x, math.round(baseline - m.ascent * scale), color)
			}
		}

	case .Bullet:
		size := f32(run.size) * scale
		radius := math.round(size * 0.16)
		cx := x + run.w * scale / 2
		cy := math.round(baseline - size * 0.33)
		box := clay.BoundingBox{math.round(cx - radius), cy - radius, radius * 2, radius * 2}

		// A disc, a ring or a square, by depth
		switch (run.depth - 1) % 3 {
		case 0:
			gfx.fill_rounded_rect(box, clay.CornerRadiusAll(radius), gfx.theme.text_dim)
		case 1:
			gfx.fill_rounded_rect(box, clay.CornerRadiusAll(radius), gfx.theme.text_dim)
			inner := max(math.round(1.5 * scale), 1)
			hole := clay.BoundingBox{
				box.x + inner,
				box.y + inner,
				box.width - 2 * inner,
				box.height - 2 * inner,
			}
			gfx.fill_rounded_rect(hole, clay.CornerRadiusAll(radius - inner), gfx.theme.bg)
		case:
			gfx.fill_rect(box.x, box.y, box.width, box.height, gfx.theme.text_dim)
		}

	case .Checkbox:
		box := run.w * scale
		bx := clay.BoundingBox{
			x,
			math.round(baseline - m.ascent * scale + (m.ascent * scale - box) * 0.5 + 1),
			math.round(box),
			math.round(box),
		}
		radius := clay.CornerRadiusAll(3 * scale)

		if run.checked {
			gfx.fill_rounded_rect(bx, radius, gfx.theme.accent)
			gfx.draw_icon({.Check, gfx.theme.bg, u16(math.round(f32(run.size) * 0.8))}, bx)
		} else {
			gfx.fill_rounded_rect(bx, radius, gfx.theme.text_dim)
			inner := max(math.round(1.5 * scale), 1)
			hole := clay.BoundingBox{
				bx.x + inner,
				bx.y + inner,
				bx.width - 2 * inner,
				bx.height - 2 * inner,
			}
			gfx.fill_rounded_rect(hole, clay.CornerRadiusAll(2 * scale), gfx.theme.bg)
		}
	}
}


// A code segment split into runs of one color, in the editor font
@(private = "file")
code_runs :: proc(text: string, hl: []syntax.Highlight) -> []textedit.Run {
	spacing := env.config().letter_spacing
	return textedit.visible_runs(text, hl, nil, 0, max(int), spacing, code_has_glyph)
}


@(private = "file")
code_has_glyph :: proc(r: rune) -> bool {
	return gfx.font_has_own_glyph(&gfx.text_system, .Editor, r)
}
