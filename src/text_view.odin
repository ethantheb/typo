package editor

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import "buffer"
import "markdown"
import "syntax"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"
import "gfx"
import "textedit"

// The plain text view, as a textedit.Kind: one row per line on a column grid
// with a line-number gutter, colored by the highlighter (or, for a Markdown
// file shown as text, by markdown.highlight_range). Only visible lines are
// read from the buffer, and only their visible columns are shaped, so the cost
// per frame doesn't grow with file size.
TEXT_KIND := textedit.Kind {
	frame_begin = text_frame_begin,
	frame_end   = text_frame_end,
	draw        = draw_text_view,
	offset_at   = text_offset_at,
	over_text   = text_over_text,
	max_scroll  = text_max_scroll,
	scroll_step = text_scroll_step,
	reveal      = text_reveal,
	same_row    = text_same_row,
	move        = text_move,
	page_height = text_page_height,
	edit_key    = text_edit_key,
	text_input  = text_input,
	drag_x      = text_drag_x,
}

TEXT_MARGIN :: 8 // logical pixels between the gutter and the text

@(private = "file")
text_frame_begin :: proc(v: ^textedit.View) {
	e := editor_of(v)
	digits := len(fmt.tprintf("%d", buffer.line_count(&e.buf)))
	e.gutter_w = f32(max(digits, 3)) * e.char_w + 28
}

// A Markdown file shown as text keeps its structure parsed for what is in view.
@(private = "file")
text_frame_end :: proc(v: ^textedit.View) {
	e := editor_of(v)
	if e.md == nil do return
	last := int(e.scroll_y + f64(e.view.h)) / editor_line_height() + 1
	markdown.doc_update(e.md, &e.buf, last + markdown.LOOKAHEAD_LINES, markdown.PARSE_BUDGET)
}

@(private = "file")
text_offset_at :: proc(v: ^textedit.View, p: [2]f32) -> int {
	e := editor_of(v)
	if f64(p.y - e.view.y) + e.scroll_y < 0 do return 0
	line := int(f64(p.y - e.view.y) + e.scroll_y) / editor_line_height()
	line = clamp(line, 0, buffer.line_count(&e.buf) - 1)
	text, start := textedit.line_text(e, line)
	col := int((p.x - e.view.x - e.gutter_w - TEXT_MARGIN + e.scroll_x) / e.char_w + 0.5)
	return start + textedit.byte_at_col(text, max(col, 0))
}

@(private = "file")
text_over_text :: proc(v: ^textedit.View, p: [2]f32) -> bool {
	e := editor_of(v)
	return gfx.rect_contains({e.view.x + e.gutter_w, e.view.y, e.view.w - e.gutter_w, e.view.h}, p)
}

// The last line can scroll to the top.
@(private = "file")
text_max_scroll :: proc(v: ^textedit.View) -> f64 {
	return max(f64((buffer.line_count(&v.buf) - 1) * editor_line_height()), 0)
}

@(private = "file")
text_scroll_step :: proc(v: ^textedit.View) -> f64 {
	return f64(editor_line_height())
}

@(private = "file")
text_reveal :: proc(v: ^textedit.View) {
	e := editor_of(v)
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	lh := f64(editor_line_height())
	top := f64(line) * lh
	ty, tx := e.target_y, e.target_x
	if top < ty do ty = top
	if top + lh > ty + f64(e.view.h) do ty = top + lh - f64(e.view.h)

	text, start := textedit.line_text(e, line)
	x := f32(textedit.visual_col(text, head - start)) * e.char_w
	text_w := e.view.w - e.gutter_w - TEXT_MARGIN - e.char_w * 2
	if x < tx do tx = max(x - e.char_w * 4, 0)
	if x > tx + text_w do tx = x - text_w

	if ty != e.target_y do textedit.scroll_to(e, ty)
	if tx != e.target_x do e.scroll_x, e.target_x = tx, tx
}

@(private = "file")
text_same_row :: proc(v: ^textedit.View, a, b: int) -> bool {
	return buffer.offset_to_line(&v.buf, a) == buffer.offset_to_line(&v.buf, b)
}

// Lines a page moves.
@(private = "file")
page_lines :: proc(v: ^textedit.View) -> int {
	return max(int(v.view.h) / editor_line_height() - 1, 1)
}

@(private = "file")
text_page_height :: proc(v: ^textedit.View) -> f64 {
	return f64(page_lines(v) * editor_line_height())
}

@(private = "file")
text_move :: proc(v: ^textedit.View, m: textedit.Move, s: Selection) -> (head, col: int) {
	#partial switch m {
	case .Left:      return textedit.prev_boundary(v, s.head), -1
	case .Right:     return textedit.next_boundary(v, s.head), -1
	case .Up:        return vertical(v, s, -1)
	case .Down:      return vertical(v, s, +1)
	case .Page_Up:   return vertical(v, s, -page_lines(v))
	case .Page_Down: return vertical(v, s, page_lines(v))
	case .Home:      return smart_home(v, s.head), -1
	case .End:       return buffer.line_end(&v.buf, buffer.offset_to_line(&v.buf, s.head)), -1
	}
	return s.head, -1
}

// Moves `lines` lines up/down keeping the preferred visual column.
@(private = "file")
vertical :: proc(v: ^textedit.View, s: Selection, lines: int) -> (head, col: int) {
	line := buffer.offset_to_line(&v.buf, s.head)
	col = s.col
	if col < 0 {
		text, start := textedit.line_text(v, line)
		col = textedit.visual_col(text, s.head - start)
	}
	target := line + lines
	if target < 0 do return 0, col
	if target >= buffer.line_count(&v.buf) do return buffer.length(&v.buf), col
	text, start := textedit.line_text(v, target)
	return start + textedit.byte_at_col(text, col), col
}

// Home goes to the first non-blank character, or to column 0 if already there.
@(private = "file")
smart_home :: proc(v: ^textedit.View, offset: int) -> int {
	text, start := textedit.line_text(v, buffer.offset_to_line(&v.buf, offset))
	indent := textedit.indent_len(text)
	return offset == start + indent ? start : start + indent
}

@(private = "file")
text_edit_key :: proc(v: ^textedit.View, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	switch key.key {
	case sdl.K_BACKSPACE: textedit.delete_text(v, -1, ctrl)
	case sdl.K_DELETE:    textedit.delete_text(v, +1, ctrl)
	case sdl.K_RETURN, sdl.K_KP_ENTER: newline(v)
	case sdl.K_TAB:
		if key.mod & sdl.KMOD_SHIFT == {} do textedit.insert(v, "\t", .Other)
	case:
		return false
	}
	return true
}

// Newline that keeps the current line's indentation.
@(private = "file")
newline :: proc(v: ^textedit.View) {
	texts := make([]string, len(v.sels), context.temp_allocator)
	for s, i in v.sels {
		text, _ := textedit.line_text(v, buffer.offset_to_line(&v.buf, textedit.sel_lo(s)))
		texts[i] = strings.concatenate({buffer.newline(&v.buf), text[:textedit.indent_len(text)]}, context.temp_allocator)
	}
	textedit.apply(v, .Other, textedit.selection_ranges(v), texts)
}

@(private = "file")
text_input :: proc(v: ^textedit.View, text: string) {
	textedit.insert(v, text)
}

// Drag-selecting past the text's left or right edge scrolls sideways.
@(private = "file")
text_drag_x :: proc(v: ^textedit.View, p: [2]f32) {
	e := editor_of(v)
	left := e.view.x + e.gutter_w
	dx: f32
	if p.x > e.view.x + e.view.w do dx = (p.x - e.view.x - e.view.w) * 0.25 + 2
	if p.x < left && e.scroll_x > 0 do dx = -((left - p.x) * 0.25 + 2)
	if dx != 0 do e.scroll_x, e.target_x = max(e.scroll_x + dx, 0), max(e.scroll_x + dx, 0)
}

// --- Drawing -------------------------------------------------------------------

@(private = "file")
draw_text_view :: proc(v: ^textedit.View, b: gfx.Rect, scale: f32, caret_on: bool) {
	e := editor_of(v)
	font := gfx.text_get_font(&gfx.text_system, .Editor, editor_font_size())
	if font == nil do return
	gfx.push_clip_box({b.x, b.y, b.w, b.h})
	defer gfx.pop_clip()

	adv := e.char_w * scale
	line_height := editor_line_height()
	lh := f32(line_height) * scale
	gutter := math.round(e.gutter_w * scale)
	text_x := b.x + gutter + TEXT_MARGIN * scale - e.scroll_x * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)

	line_count := buffer.line_count(&e.buf)
	first := int(e.scroll_y) / line_height
	y0 := b.y - f32(e.scroll_y - f64(first * line_height)) * scale
	last := min(first + int(b.h / lh) + 2, line_count)

	first_col := int(e.scroll_x / e.char_w)
	col_count := int((b.w - gutter) / adv) + 2

	// Syntax highlights for all visible bytes in one call (capped like the
	// visible text, for enormous lines).
	hl_start := buffer.line_start(&e.buf, first)
	hl_end := last < line_count ? buffer.line_start(&e.buf, last) : buffer.length(&e.buf)
	hl := make([]syntax.Highlight, min(hl_end, hl_start + textedit.MAX_LINE_SCAN) - hl_start, context.temp_allocator)
	styles: []markdown.Text_Styles
	if e.md != nil {
		styles = make([]markdown.Text_Styles, len(hl), context.temp_allocator)
		markdown.highlight_range(e.md, &e.buf, hl_start, hl, styles)
	} else {
		syntax.highlight_range(&e.hl, &e.buf, hl_start, hl)
	}
	// By style: regular, bold, italic, bold italic (drawn bold).
	bold := gfx.text_get_font(&gfx.text_system, .Editor_Bold, editor_font_size())
	fonts := [4]^ttf.Font{font, bold, gfx.text_get_font(&gfx.text_system, .Editor_Italic, editor_font_size()), bold}

	primary := e.sels[e.primary]
	primary_line := buffer.offset_to_line(&e.buf, primary.head)
	caret_w := max(math.round(2 * scale), 1)

	lines := visible_lines(e, first, last, hl_start, hl_end)
	for l, i in lines {
		line := first + i
		y := math.round(y0 + f32(i) * lh)
		end := l.start + len(l.text)
		si := textedit.first_selection_at(e, l.start) // selections are sorted

		if line == primary_line && primary.anchor == primary.head {
			gfx.fill_rect(b.x + gutter, y, b.w - gutter, lh, gfx.theme.current_line)
		}

		// Selections. One continuing past the line end also covers one extra
		// cell, to show the line break is selected.
		for j := si; j < len(e.sels); j += 1 {
			lo, hi := textedit.sel_lo(e.sels[j]), textedit.sel_hi(e.sels[j])
			if lo > end do break
			if hi < l.start || lo == hi do continue
			x1 := col_x(l.text, max(lo, l.start) - l.start, text_x, adv)
			x2 := col_x(l.text, min(hi, end) - l.start, text_x, adv)
			if hi > end do x2 += math.round(adv * 0.6)
			gfx.fill_rect(x1, y, x2 - x1, lh, gfx.theme.selection)
		}

		lo := clamp(l.start - hl_start, 0, len(hl))
		hi := clamp(end - hl_start, lo, len(hl))
		line_styles := styles != nil ? styles[lo:hi] : nil
		for run in editor_runs(l.text, hl[lo:hi], line_styles, first_col, col_count) {
			x := math.round(text_x + f32(run.col) * adv)
			run_font := fonts[(.Bold in run.style ? 1 : 0) + (.Italic in run.style ? 2 : 0)]
			if run_font == nil do run_font = font
			color := gfx.theme.syntax[run.hl]
			gfx.draw_text(gfx.text_get(&gfx.text_system, run_font, run.text), x, y + text_dy, color)
			if .Strike in run.style {
				gfx.fill_rect(x, math.round(y + lh / 2), f32(utf8.rune_count(run.text)) * adv, max(math.round(scale), 1), color)
			}
		}

		if caret_on {
			for j := si; j < len(e.sels); j += 1 {
				h := e.sels[j].head
				if textedit.sel_lo(e.sels[j]) > end do break
				// A caret at a line's end belongs to that line, not the next.
				if h < l.start || h > end do continue
				gfx.fill_rect(col_x(l.text, h - l.start, text_x, adv), y, caret_w, lh, gfx.theme.caret)
			}
		}
	}

	// Gutter, drawn last so horizontally scrolled text slides under it. Line
	// numbers use a smaller font, baseline-aligned with the text.
	gfx.fill_rect(b.x, b.y, gutter, b.h, gfx.theme.gutter)
	num_font := gfx.text_get_font(&gfx.text_system, .Editor, gutter_font_size())
	if num_font == nil do return
	num_dy := text_dy + f32(ttf.GetFontAscent(font) - ttf.GetFontAscent(num_font))
	num_right := b.x + gutter - math.round(16 * scale)
	for line in first ..< last {
		t := gfx.text_get(&gfx.text_system, num_font, fmt.tprintf("%d", line + 1))
		if t == nil do continue
		w, h: i32
		_ = ttf.GetTextSize(t, &w, &h)
		y := math.round(y0 + f32(line - first) * lh)
		gfx.draw_text(t, num_right - f32(w), y + num_dy, line == primary_line ? gfx.theme.text_dim : gfx.theme.text_faint)
	}
}

Visible_Line :: struct {
	text:  string, // without the line ending
	start: int,    // document offset
}

// The text of lines [first, last), which span document bytes [lo, hi). Reads
// the range with one buffer read and splits it, or line by line (each capped at
// MAX_LINE_SCAN) when the range is enormous.
@(private = "file")
visible_lines :: proc(e: ^Editor, first, last, lo, hi: int) -> []Visible_Line {
	out := make([]Visible_Line, last - first, context.temp_allocator)
	if hi - lo > textedit.MAX_LINE_SCAN {
		for &l, i in out do l.text, l.start = textedit.line_text(e, first + i)
		return out
	}
	text := string(buffer.read_alloc(&e.buf, lo, hi))
	pos := 0
	for &l in out {
		nl := strings.index_byte(text[pos:], '\n')
		end := nl < 0 ? len(text) : pos + nl
		line := text[pos:end]
		if nl >= 0 && len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		l = {line, lo + pos}
		pos = min(end + 1, len(text))
	}
	return out
}

@(private = "file")
col_x :: proc(text: string, i: int, text_x, adv: f32) -> f32 {
	return math.round(text_x + f32(textedit.visual_col(text, i)) * adv)
}
