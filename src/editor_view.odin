package editor

import "core:fmt"
import "core:math"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import "syntax"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// The text area is one Clay custom element; this file updates its view state
// from the last layout and draws it. Only visible lines are ever read from the
// buffer, and only their visible columns are shaped, so cost per frame is
// independent of file size.

CARET_BLINK_NS :: 530_000_000
MAX_HIGHLIGHT_BYTES :: 4 << 20
TEXT_MARGIN :: 8 // logical pixels between the gutter and the text

// Per-frame update before layout: view metrics, mouse, scroll-into-view.
editor_frame :: proc(e: ^Editor) {
	if e.status != .Text do return
	syntax.highlighter_edit(&e.hl, &e.buf)
	if data := clay.GetElementData(clay.ID("EditorText")); data.found {
		bb := data.boundingBox
		e.view = {bb.x, bb.y, bb.width, bb.height}
	}
	e.char_w = text_char_width(&g.text, .Body, editor_font_size())
	digits := len(fmt.tprintf("%d", buffer.line_count(&e.buf)))
	e.gutter_w = f32(max(digits, 3)) * e.char_w + 28

	if ui_interactive() do editor_mouse(e)
	editor_reveal(e)
	editor_animate(e)
}

// The Clay element hosting the text view.
editor_text_element :: proc(e: ^Editor) {
	data := new_clone(Custom_Data(e), context.temp_allocator)
	if clay.UI(clay.ID("EditorText"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
		custom = {customData = data},
	}) {}
}

draw_editor :: proc(renderer: ^sdl.Renderer, e: ^Editor, b: clay.BoundingBox, scale: f32) {
	if e.status != .Text || e.char_w <= 0 do return
	font := text_get_font(&g.text, .Body, editor_font_size())
	if font == nil do return

	clip := sdl.Rect{i32(b.x), i32(b.y), i32(math.ceil(b.width)), i32(math.ceil(b.height))}
	_ = sdl.SetRenderClipRect(renderer, &clip)
	defer _ = sdl.SetRenderClipRect(renderer, nil)

	adv := e.char_w * scale
	line_height := editor_line_height()
	lh := f32(line_height) * scale
	gutter := math.round(e.gutter_w * scale)
	text_x := b.x + gutter + TEXT_MARGIN * scale - e.scroll_x * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)

	line_count := buffer.line_count(&e.buf)
	first := int(e.scroll_y) / line_height
	y0 := b.y - f32(e.scroll_y - f64(first * line_height)) * scale
	last := min(first + int(b.height / lh) + 2, line_count)

	first_col := int(e.scroll_x / e.char_w)
	col_count := int((b.width - gutter) / adv) + 2

	// Syntax highlights for all visible bytes in one call (capped, for files
	// with enormous lines; bytes past the cap draw uncolored).
	hl_start := buffer.line_start(&e.buf, first)
	hl_end := last < line_count ? buffer.line_start(&e.buf, last) : buffer.length(&e.buf)
	hl := make([]syntax.Highlight, min(hl_end, hl_start + MAX_HIGHLIGHT_BYTES) - hl_start, context.temp_allocator)
	syntax.highlight_range(&e.hl, &e.buf, hl_start, hl)

	primary := e.sels[e.primary]
	primary_line := buffer.offset_to_line(&e.buf, primary.head)
	caret_on := ((sdl.GetTicksNS() - e.blink_t0) / CARET_BLINK_NS) % 2 == 0
	caret_w := max(math.round(2 * scale), 1)

	lines := visible_lines(e, first, last, hl_start, hl_end)
	for line in first ..< last {
		y := math.round(y0 + f32(line - first) * lh)
		text, start := lines[line - first].text, lines[line - first].start
		end := start + len(text)
		si := first_selection_at(e, start) // selections are sorted

		if line == primary_line && primary.anchor == primary.head {
			fill(renderer, b.x + gutter, y, b.width - gutter, lh, theme.current_line)
		}

		// Selection highlights. A selection continuing past the line end also
		// covers one extra cell to show the line break is selected.
		for j := si; j < len(e.sels); j += 1 {
			s := e.sels[j]
			lo, hi := sel_lo(s), sel_hi(s)
			if lo > end do break
			if hi < start || lo == hi do continue
			x1 := col_x(text, max(lo, start) - start, text_x, adv)
			x2 := col_x(text, min(hi, end) - start, text_x, adv)
			if hi > end do x2 += math.round(adv * 0.6)
			fill(renderer, x1, y, x2 - x1, lh, theme.selection)
		}

		// Text: only the visible columns, one draw per run of the same color.
		lo := clamp(start - hl_start, 0, len(hl))
		line_hl := hl[lo:clamp(end - hl_start, lo, len(hl))]
		for run in visible_runs(text, line_hl, first_col, col_count) {
			t := text_get(&g.text, font, run.text)
			if t == nil do continue
			c := theme.syntax[run.hl]
			_ = ttf.SetTextColor(t, u8(c.r), u8(c.g), u8(c.b), 255)
			_ = ttf.DrawRendererText(t, math.round(text_x + f32(run.col) * adv), y + text_dy)
		}

		// Carets.
		if caret_on {
			for j := si; j < len(e.sels); j += 1 {
				h := e.sels[j].head
				if sel_lo(e.sels[j]) > end do break
				if h < start || h > end do continue
				// A caret at a line's end belongs to that line, not the next.
				fill(renderer, col_x(text, h - start, text_x, adv), y, caret_w, lh, theme.caret)
			}
		}
	}

	draw_scrollbar(renderer, e, scale)

	// Gutter, drawn last so horizontally scrolled text slides under it. Line
	// numbers use a smaller font, baseline-aligned with the text.
	fill(renderer, b.x, b.y, gutter, b.height, theme.gutter)
	num_font := text_get_font(&g.text, .Body, gutter_font_size())
	if num_font == nil do return
	num_dy := text_dy + f32(ttf.GetFontAscent(font) - ttf.GetFontAscent(num_font))
	num_right := b.x + gutter - math.round(16 * scale)
	for line in first ..< last {
		y := math.round(y0 + f32(line - first) * lh)
		t := text_get(&g.text, num_font, fmt.tprintf("%d", line + 1))
		if t == nil do continue
		c := line == primary_line ? theme.text_dim : theme.text_faint
		_ = ttf.SetTextColor(t, u8(c.r), u8(c.g), u8(c.b), 255)
		w, h: i32
		_ = ttf.GetTextSize(t, &w, &h)
		_ = ttf.DrawRendererText(t, num_right - f32(w), y + num_dy)
	}
}

@(private = "file")
draw_scrollbar :: proc(renderer: ^sdl.Renderer, e: ^Editor, scale: f32) {
	_, thumb, ok := scrollbar_geometry(e)
	if !ok do return
	active := e.scrollbar_drag != nil || scrollbar_hit(e, g.mouse_pos)
	c := theme.text_dim
	c.a = active ? 150 : 70
	inset: f32 = active ? 2 : 3
	b := clay.BoundingBox {
		(thumb.x + inset) * scale,
		(thumb.y + 2) * scale,
		(thumb.w - inset * 2) * scale,
		(thumb.h - 4) * scale,
	}
	r := b.width / 2
	fill_rounded_rect(renderer, b, {r, r, r, r}, c)
}

Visible_Line :: struct {
	text:  string, // without the line ending
	start: int,    // document offset
}

// The text of lines [first, last), which span document bytes [lo, hi). Reads
// the whole range with one buffer read and splits it, rather than looking up
// each line separately. Falls back to per-line reads (capped at MAX_LINE_SCAN)
// when the range is huge, i.e. some visible line is enormous.
@(private = "file")
visible_lines :: proc(e: ^Editor, first, last, lo, hi: int) -> []Visible_Line {
	out := make([]Visible_Line, last - first, context.temp_allocator)
	if hi - lo > MAX_HIGHLIGHT_BYTES {
		for &l, i in out do l.text, l.start = line_text(e, first + i)
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
	return math.round(text_x + f32(visual_col(text, i)) * adv)
}

// Index of the first selection that ends at or after `offset`.
@(private = "file")
first_selection_at :: proc(e: ^Editor, offset: int) -> int {
	lo, hi := 0, len(e.sels)
	for lo < hi {
		mid := (lo + hi) / 2
		if sel_hi(e.sels[mid]) < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

Run :: struct {
	text: string,
	col:  int, // visual column where the run starts
	hl:   syntax.Highlight,
}

// Splits the part of a line covering visual columns [first_col, first_col+count)
// into runs of one highlight, with tabs expanded to spaces. Whitespace joins the
// current run (it draws nothing) so runs break only where the color changes.
// line_hl may be shorter than text (highlight cap); the rest is uncolored.
@(private = "file")
visible_runs :: proc(text: string, line_hl: []syntax.Highlight, first_col, count: int) -> []Run {
	runs := make([dynamic]Run, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	flush :: proc(runs: ^[dynamic]Run, sb: ^strings.Builder, run_start, run_col: int, hl: syntax.Highlight) {
		s := string(sb.buf[run_start:])
		if len(strings.trim_space(s)) > 0 do append(runs, Run{s, run_col, hl})
	}

	run_start, run_col := 0, 0
	run_hl := syntax.Highlight.None
	started := false
	col := 0
	last_col := first_col + count
	for r, i in text {
		next := r == '\t' ? (col / TAB_WIDTH + 1) * TAB_WIDTH : col + 1
		if next > first_col {
			h := i < len(line_hl) ? line_hl[i] : .None
			space := r == ' ' || r == '\t'
			if !started {
				started, run_col, run_hl = true, col, h
			} else if !space && h != run_hl {
				flush(&runs, &sb, run_start, run_col, run_hl)
				run_start, run_col, run_hl = len(sb.buf), col, h
			}
			if r == '\t' {
				for _ in col ..< next do strings.write_byte(&sb, ' ')
			} else {
				strings.write_string(&sb, text[i:][:len_rune(text[i:])])
			}
		}
		col = next
		if col >= last_col do break
	}
	if started do flush(&runs, &sb, run_start, run_col, run_hl)
	return runs[:]
}

@(private = "file")
len_rune :: proc(s: string) -> int {
	c := s[0]
	switch {
	case c < 0x80: return 1
	case c < 0xE0: return min(2, len(s))
	case c < 0xF0: return min(3, len(s))
	}
	return min(4, len(s))
}

@(private = "file")
fill :: proc(renderer: ^sdl.Renderer, x, y, w, h: f32, c: clay.Color) {
	if w <= 0 || h <= 0 do return
	_ = sdl.SetRenderDrawColor(renderer, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
	r := sdl.FRect{x, y, w, h}
	_ = sdl.RenderFillRect(renderer, &r)
}
