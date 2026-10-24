package editor

import "core:hash"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import "markdown"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"
import "syntax"

// The rendered Markdown view: the same document and selections as the text
// view, drawn with real typography and edited in place. Lines have their own
// heights (wrapped rows, headings), kept in a height map; lines not yet laid
// out have estimated heights, corrected as they come into view without moving
// what is on screen (see md_layout_visible).

// Larger files open as text.
MD_RENDER_MAX_BYTES :: 8 << 20
// Space on each side of the text column.
MD_COLUMN_PAD :: 32

Md_Mode :: enum u8 {
	Text,
	Rendered,
}

Md_View :: struct {
	mode:            Md_Mode,
	// No caret is shown (and no syntax revealed) until a click in the text;
	// a click beside it hides the caret again.
	caretless:       bool,
	heights:         Height_Map,
	col_x, col_w:    f32, // the text column, from the view's left
	// What the estimated heights are for; a change re-estimates every line.
	measured:        struct {
		col_w:       f32,
		generation:  u64,
		size:        int,
		line_height: f64,
	},
	layouts:         map[u64]^Line_Layout,
	code_scroll:     map[int]f32, // sideways scroll of code blocks, by first line
	code_scroll_gen: u64,         // bumped when one changes
	code_drag:       struct {
		active: bool,
		last:   int, // the block's last line, which holds its scroll bar
		grab:   f32, // pointer x minus the thumb's left when the drag began
	},
	// Caches for the current document, cleared when it (or the column or
	// fonts) changes, and the lines laid out for the current selections too
	// (see md_begin).
	arena:           virtual.Arena,
	doc_allocator:   mem.Allocator,
	doc_token:       u64,
	blocks:          map[int]^Md_Block,
	tables:          map[int]^Md_Table, // by delimiter row
	code_blocks:     [dynamic]^Md_Code_Block,
	code_hl:         struct {
		lo: int, // document offset of hl[0]
		hl: []syntax.Highlight,
	},
	token:           u64,
	memo:            map[int]^Line_Layout,
}

// A code block's lines, and the width of its widest line and of its box once
// measured.
Md_Code_Block :: struct {
	first, last: int,
	width, box:  f32,
	measured:    bool,
}

md_rendered :: proc(e: ^Editor) -> bool {
	return e.md != nil && e.mdv.mode == .Rendered
}

md_view_destroy :: proc(mv: ^Md_View) {
	for _, L in mv.layouts do md_layout_destroy(L)
	delete(mv.layouts)
	delete(mv.code_scroll)
	hm_destroy(&mv.heights)
	if mv.doc_allocator.procedure != nil do virtual.arena_destroy(&mv.arena)
	mv^ = {}
}

// Switches between the text and rendered views, keeping the top line in place.
md_set_mode :: proc(e: ^Editor, mode: Md_Mode) {
	if e.md == nil || e.mdv.mode == mode do return
	mv := &e.mdv
	top: int
	if mode == .Rendered {
		top = int(e.scroll_y) / editor_line_height()
	} else {
		top, _ = hm_find(&mv.heights, e.scroll_y)
	}
	mv.mode = mode
	mv.caretless = false
	mv.measured = {}
	for &s in e.sels do s.col = -1
	e.scroll_x, e.target_x = 0, 0
	if mode == .Rendered {
		md_column(e)
		md_check_heights(e)
		scroll_to(e, hm_y(&mv.heights, top))
	} else {
		scroll_to(e, f64(top * editor_line_height()))
	}
	e.reveal = true
}

// Toggles the view, remembering the choice for the file until typo exits.
md_toggle_view :: proc(e: ^Editor) {
	mode: Md_Mode = e.mdv.mode == .Rendered ? .Text : .Rendered
	md_set_mode(e, mode)
	if e.path in g.md_modes {
		g.md_modes[e.path] = mode
	} else {
		g.md_modes[strings.clone(e.path)] = mode
	}
}

// The mode a Markdown file opens in: as last toggled, else from the settings.
md_default_mode :: proc(e: ^Editor) -> Md_Mode {
	if mode, ok := g.md_modes[e.path]; ok do return mode
	if g.settings.markdown_view == "text" || buffer.length(&e.buf) > MD_RENDER_MAX_BYTES do return .Text
	return .Rendered
}

// --- Caches -----------------------------------------------------------------------------

// Starts (or keeps) the caches that depend on the document, and the line
// layouts, which also depend on the selections.
md_begin :: proc(e: ^Editor) {
	mv := &e.mdv
	if mv.doc_allocator.procedure == nil {
		_ = virtual.arena_init_growing(&mv.arena)
		mv.doc_allocator = virtual.arena_allocator(&mv.arena)
	}
	doc := [?]u64 {
		e.buf.version,
		e.md.version,
		e.md.refdef_gen,
		u64(transmute(u32)mv.col_w),
		g.text.generation,
		u64(transmute(u32)g.text.scale),
		u64(g.settings.markdown_font_size),
		transmute(u64)g.settings.markdown_line_height,
		u64(transmute(u32)e.view.w),
	}
	h := hash.fnv64a(mem.slice_to_bytes(doc[:]))
	if h != mv.doc_token || mv.memo == nil {
		mv.doc_token = h
		virtual.arena_free_all(&mv.arena)
		mv.blocks = make(map[int]^Md_Block, mv.doc_allocator)
		mv.tables = make(map[int]^Md_Table, mv.doc_allocator)
		mv.code_blocks = make([dynamic]^Md_Code_Block, mv.doc_allocator)
		mv.code_hl = {}
		mv.memo = make(map[int]^Line_Layout, mv.doc_allocator)
		mv.token = 0
	}
	h = hash.fnv64a(mem.slice_to_bytes(e.sels[:]), h)
	view := [?]u64{u64(mv.caretless), mv.code_scroll_gen}
	h = hash.fnv64a(mem.slice_to_bytes(view[:]), h)
	if h == mv.token do return
	mv.token = h
	clear(&mv.memo)
}

// Drops layouts that haven't been used for a while.
md_end_frame :: proc(e: ^Editor) {
	mv := &e.mdv
	if g.frame % 64 != 0 || len(mv.layouts) == 0 do return
	stale := make([dynamic]u64, context.temp_allocator)
	for key, L in mv.layouts do if g.frame - L.last_used > TEXT_CACHE_EVICT_FRAMES do append(&stale, key)
	for key in stale {
		md_layout_destroy(mv.layouts[key])
		delete_key(&mv.layouts, key)
	}
	// The memo may point at them.
	if len(stale) > 0 do mv.token = 0
}

// Whether some selection touches [lo, hi] (a caret at either end counts).
md_touches :: proc(e: ^Editor, lo, hi: int) -> bool {
	if e.mdv.caretless do return false
	i := first_selection_at(e, lo)
	return i < len(e.sels) && sel_lo(e.sels[i]) <= hi
}

// --- Frame --------------------------------------------------------------------------------

// Places the text column in the view.
md_column :: proc(e: ^Editor) {
	mv := &e.mdv
	avail := max(e.view.w - 2 * MD_COLUMN_PAD, 120)
	w := avail
	if g.settings.markdown_max_width > 0 do w = min(f32(g.settings.markdown_max_width), avail)
	mv.col_w = math.round(w)
	mv.col_x = math.round((e.view.w - w) / 2)
}

// Re-estimates every line's height when the column or fonts changed.
md_check_heights :: proc(e: ^Editor) {
	mv := &e.mdv
	m := &mv.measured
	n := buffer.line_count(&e.buf)
	if m.col_w == mv.col_w && m.generation == g.text.generation && m.size == g.settings.markdown_font_size && m.line_height == g.settings.markdown_line_height && mv.heights.lines == n do return
	m^ = {mv.col_w, g.text.generation, g.settings.markdown_font_size, g.settings.markdown_line_height}
	hm_destroy(&mv.heights)
	est := make([]f32, n, context.temp_allocator)
	for &h, i in est do h = md_estimate(e, i)
	hm_splice(&mv.heights, 0, 0, est)
}

// A line's height before it is laid out, from its kind and length.
md_estimate :: proc(e: ^Editor, i: int) -> f32 {
	size := f32(md_font_size())
	body := math.round(size * md_line_factor())
	if i >= len(e.md.lines) do return body
	l := e.md.lines[i]
	code := math.round(f32(md_code_size(md_font_size())) * MD_CODE_LINE_FACTOR)
	#partial switch l.kind {
	case .Blank:                                             return body
	case .Atx_Heading:                                       return size * MD_HEADING_SCALE[clamp(int(l.aux), 1, 6) - 1] * 1.9
	case .Fence_Open, .Fence_Close, .Math_Fence, .Front_Matter_Fence: return md_fence_row_height()
	case .Setext_Underline:                                  return MD_SETEXT_ROW
	case .Fence_Body, .Indented_Code, .Html, .Math_Body, .Front_Matter_Body:
		return code
	case .Table_Delim: return 2
	case .Table_Row:   return body + 2 * MD_CELL_VPAD
	}
	per_row := max(e.mdv.col_w / (size * 0.48), 1)
	return body * max(math.ceil(f32(l.len) / per_row), 1)
}

// Follows the buffer's edits in the height map.
md_view_edit :: proc(e: ^Editor, changes: []buffer.Change) {
	if !md_rendered(e) do return
	for c in changes {
		removed := c.old_end.row - c.start.row
		inserted := c.new_end.row - c.start.row
		if removed == 0 && inserted == 0 do continue
		shift_code_scroll(&e.mdv, c.start.row, c.old_end.row, inserted - removed)
		est := make([]f32, inserted, context.temp_allocator)
		for &h in est do h = math.round(md_body_line_height())
		hm_splice(&e.mdv.heights, c.start.row + 1, removed, est)
	}
}

// The view's part of editor_frame, before the mouse: column, heights and parsing.
md_frame_begin :: proc(e: ^Editor) {
	if md_images_poll() do e.mdv.token = 0
	md_column(e)
	md_check_heights(e)
	last, _ := hm_find(&e.mdv.heights, e.scroll_y + f64(e.view.h))
	markdown.doc_update(e.md, &e.buf, last + markdown.LOOKAHEAD_LINES, markdown.PARSE_BUDGET)
}

// Lays out the visible lines, putting their real heights in the height map,
// and keeps the top line where it was on screen.
md_layout_visible :: proc(e: ^Editor) {
	mv := &e.mdv
	hm := &mv.heights
	if hm.lines == 0 do return
	top, top_y := hm_find(hm, e.scroll_y)
	offset := e.scroll_y - top_y
	line := max(top - 1, 0)
	y := hm_y(hm, line)
	bottom := e.scroll_y + f64(e.view.h)
	for line < hm.lines && y <= bottom + 1 {
		L := md_line_layout(e, line)
		hm_set(hm, line, L.height)
		y += f64(L.height)
		line += 1
	}
	delta := hm_y(hm, top) + offset - e.scroll_y
	if delta != 0 {
		e.scroll_y += delta
		e.target_y += delta
	}
}

md_max_scroll :: proc(e: ^Editor) -> f64 {
	hm := &e.mdv.heights
	if hm.lines == 0 do return 0
	return max(hm.total - f64(hm_get(hm, hm.lines - 1)), 0)
}

// --- Caret and navigation -------------------------------------------------------------

Md_Caret :: struct {
	line:  int,
	L:     ^Line_Layout,
	row:   int,
	x:     f32,
	text:  string,
	start: int,
}

md_caret :: proc(e: ^Editor, offset: int) -> (c: Md_Caret) {
	c.line = buffer.offset_to_line(&e.buf, offset)
	c.L = md_line_layout(e, c.line)
	c.text, c.start = md_line_text(e, c.line)
	c.row, c.x = md_caret_x(c.L, c.text, offset - c.start)
	return
}

// Moves `rows` visual rows up or down, keeping the goal x (Selection.col).
md_vertical :: proc(e: ^Editor, s: Selection, rows: int) -> (head, col: int) {
	c := md_caret(e, s.head)
	goal := s.col >= 0 ? f32(s.col) : c.x
	line, L, row := c.line, c.L, c.row
	n := buffer.line_count(&e.buf)
	for _ in 0 ..< abs(rows) {
		if rows < 0 {
			switch {
			case row > 0:  row -= 1
			case line > 0:
				line -= 1
				L = md_line_layout(e, line)
				row = len(L.rows) - 1
			case:          return 0, int(goal)
			}
		} else {
			switch {
			case row < len(L.rows) - 1: row += 1
			case line < n - 1:
				line += 1
				L = md_line_layout(e, line)
				row = 0
			case:                       return buffer.length(&e.buf), int(goal)
			}
		}
	}
	text, start := md_line_text(e, line)
	r := L.rows[row]
	return start + md_index_at(L, text, goal, r.y + r.h / 2), int(goal)
}

// Moves a page up or down (dir = -1 or 1), keeping the goal x.
md_page :: proc(e: ^Editor, s: Selection, dir: int) -> (head, col: int) {
	c := md_caret(e, s.head)
	goal := s.col >= 0 ? f32(s.col) : c.x
	hm := &e.mdv.heights
	r := c.L.rows[c.row]
	y := hm_y(hm, c.line) + f64(r.y + r.h / 2) + f64(dir) * md_page_height(e)
	if y < 0 do return 0, int(goal)
	if y >= hm.total do return buffer.length(&e.buf), int(goal)
	line, top := hm_find(hm, y)
	L := md_line_layout(e, line)
	text, start := md_line_text(e, line)
	return start + md_index_at(L, text, goal, f32(y - top)), int(goal)
}

md_page_height :: proc(e: ^Editor) -> f64 {
	return max(f64(e.view.h) - f64(md_body_line_height()), f64(md_body_line_height()))
}

// Home: the start of the caret's visual row, then of the line.
md_home :: proc(e: ^Editor, offset: int) -> int {
	c := md_caret(e, offset)
	lo, _ := md_row_bounds(c.L, c.row, len(c.text))
	if offset != c.start + lo do return c.start + lo
	if c.row == 0 do return c.start
	return offset
}

// End: the end of the caret's visual row.
md_end :: proc(e: ^Editor, offset: int) -> int {
	c := md_caret(e, offset)
	if c.row == len(c.L.rows) - 1 do return c.start + len(c.text)
	next := int(c.L.rows[c.row + 1].lo)
	// Before the space the row wrapped at.
	if next > 0 && (c.text[next - 1] == ' ' || c.text[next - 1] == '\t') do next -= 1
	return c.start + next
}

// Scrolls so the primary caret's row is visible (see editor_reveal).
md_reveal :: proc(e: ^Editor) {
	c := md_caret(e, e.sels[e.primary].head)
	r := c.L.rows[c.row]
	top := hm_y(&e.mdv.heights, c.line) + f64(r.y)
	bottom := top + f64(r.h)
	ty := e.target_y
	margin := f64(md_body_line_height())
	if top < ty do ty = max(top - margin, 0)
	if bottom > ty + f64(e.view.h) do ty = bottom + margin - f64(e.view.h)
	if ty != e.target_y do scroll_to(e, clamp(ty, 0, md_max_scroll(e)))

	// Sideways, in a code block.
	b, in_code := md_code_block(e, c.line)
	if !in_code do return
	content := int(markdown.line_detail(e.md, c.line, c.text).content[0])
	at := e.sels[e.primary].head - c.start
	if at < content do return
	cw := text_char_width(&g.text, .Editor, md_code_size(md_font_size()))
	x := f32(visual_col(c.text[content:], at - content)) * cw
	width, box := md_code_widths(e, b)
	scroll := e.mdv.code_scroll[b.first]
	if x < scroll do scroll = max(x - 4 * cw, 0)
	if x > scroll + box - cw do scroll = x - box + 2 * cw
	md_set_code_scroll(e, b.first, clamp(scroll, 0, max(width - box, 0)))
}

// The code block (fenced, indented, math or front matter) containing line i.
md_code_block :: proc(e: ^Editor, i: int) -> (block: ^Md_Code_Block, ok: bool) {
	doc := e.md
	group := code_group(doc.lines[i].kind)
	if group == 0 do return
	md_begin(e)
	mv := &e.mdv
	for b in mv.code_blocks do if b.first <= i && i <= b.last do return b, true
	first, last := i, i
	if group == 2 {
		for first > 0 && code_group(doc.lines[first - 1].kind) == 2 do first -= 1
		for last + 1 < len(doc.lines) && code_group(doc.lines[last + 1].kind) == 2 do last += 1
	} else {
		first, last = md_fenced_block(doc, i)
	}
	block = new_clone(Md_Code_Block{first = first, last = last}, mv.doc_allocator)
	append(&mv.code_blocks, block)
	return block, true
}

// The width of a code block's widest line, and of the box it shows in.
md_code_widths :: proc(e: ^Editor, b: ^Md_Code_Block) -> (width, box: f32) {
	if !b.measured {
		cw := text_char_width(&g.text, .Editor, md_code_size(md_font_size()))
		cols := 0
		for line in b.first ..= min(b.last, b.first + 2000) {
			text, _ := md_line_text(e, line)
			content := int(markdown.line_detail(e.md, line, text).content[0])
			cols = max(cols, visual_col(text[content:], len(text) - content))
		}
		L := md_line_layout(e, b.first)
		b.width, b.box = f32(cols) * cw, L.code_bg[1] - L.code_bg[0] - 2 * MD_CODE_PAD
		b.measured = true
	}
	return b.width, b.box
}

// A code block under line i that is wider than its box, to scroll sideways.
@(private = "file")
scrollable_code :: proc(e: ^Editor, i: int) -> (b: ^Md_Code_Block, width, box: f32, ok: bool) {
	b = md_code_block(e, i) or_return
	width, box = md_code_widths(e, b)
	return b, width, box, width > box
}

// Moves code blocks' scroll with their first lines when lines from `first`
// through `last` are replaced by ones `delta` lines more; blocks starting in
// between are dropped.
@(private = "file")
shift_code_scroll :: proc(mv: ^Md_View, first, last, delta: int) {
	if len(mv.code_scroll) == 0 do return
	moved := make([dynamic][2]f32, context.temp_allocator)
	for line, x in mv.code_scroll {
		if line <= first do continue
		if line > last do append(&moved, [2]f32{f32(line + delta), x})
	}
	for line in mv.code_scroll do if line > first do delete_key(&mv.code_scroll, line)
	for m in moved do mv.code_scroll[int(m[0])] = m[1]
	mv.code_scroll_gen += 1
}

// The line under a y position (logical window coordinates), and the position
// within it.
md_line_at_y :: proc(e: ^Editor, y: f32) -> (line: int, local_y: f32, ok: bool) {
	hm := &e.mdv.heights
	doc_y := f64(y - e.view.y) + e.scroll_y
	if doc_y < 0 || doc_y >= hm.total do return
	top: f64
	line, top = hm_find(hm, doc_y)
	return line, f32(doc_y - top), true
}

// The sideways scroll bar of a code block wider than its box, drawn under its
// last line `line`, in logical window coordinates.
md_code_bar :: proc(e: ^Editor, line: int) -> (track, thumb: Rect, first: int, ok: bool) {
	b, width, box := scrollable_code(e, line) or_return
	if line != b.last do return
	mv := &e.mdv
	L := md_line_layout(e, line)
	track = {e.view.x + mv.col_x + L.code_bg[0] + MD_CODE_PAD, e.view.y + f32(hm_y(&mv.heights, line) - e.scroll_y) + L.height - 5, box, 3}
	tw := max(box * box / width, 24)
	thumb = {track.x + (box - tw) * mv.code_scroll[b.first] / (width - box), track.y, tw, track.h}
	return track, thumb, b.first, true
}

// Where a code block's thin scroll bar takes the pointer: taller than drawn.
@(private = "file")
code_bar_grab_area :: proc(track: Rect) -> Rect {
	return {track.x, track.y - 6, track.w, track.h + 9}
}

// The code block scroll bar under a point, if any.
md_code_bar_at :: proc(e: ^Editor, p: [2]f32) -> (track, thumb: Rect, first, last: int, ok: bool) {
	line, _ := md_line_at_y(e, p.y) or_return
	// The grab area reaches a little into the next line.
	for l in max(line - 1, 0) ..= line {
		if track, thumb, first, ok = md_code_bar(e, l); ok && rect_contains(code_bar_grab_area(track), p) do return track, thumb, first, l, true
	}
	return {}, {}, 0, 0, false
}

// Pressing and dragging a code block's scroll bar. Returns true while it owns the mouse.
md_code_bar_mouse :: proc(e: ^Editor) -> bool {
	d := &e.mdv.code_drag
	if !d.active {
		if !g.mouse_pressed do return false
		_, thumb, _, last, ok := md_code_bar_at(e, g.mouse_pos)
		if !ok do return false
		// Clicking the track centres the thumb there.
		d^ = {true, last, rect_contains(thumb, g.mouse_pos) ? g.mouse_pos.x - thumb.x : thumb.w / 2}
	}
	if !g.mouse_down {
		d.active = false
		return true
	}
	track, thumb, first, ok := md_code_bar(e, d.last)
	if !ok {
		d.active = false
		return true
	}
	b, _ := md_code_block(e, first)
	width, box := md_code_widths(e, b)
	frac := clamp((g.mouse_pos.x - d.grab - track.x) / max(track.w - thumb.w, 1), 0, 1)
	md_set_code_scroll(e, first, frac * (width - box))
	return true
}

// While drag-selecting past the side of a code block, scrolls it that way.
md_drag_scroll_code :: proc(e: ^Editor) {
	line, _, in_view := md_line_at_y(e, clamp(g.mouse_pos.y, e.view.y, e.view.y + e.view.h - 1))
	if !in_view do return
	b, width, box, ok := scrollable_code(e, line)
	if !ok do return
	L := md_line_layout(e, line)
	x0 := e.view.x + e.mdv.col_x + L.code_bg[0] + MD_CODE_PAD
	x1 := x0 + box
	dx: f32
	if g.mouse_pos.x < x0 do dx = -((x0 - g.mouse_pos.x) * 0.25 + 2)
	if g.mouse_pos.x > x1 do dx = (g.mouse_pos.x - x1) * 0.25 + 2
	if dx != 0 do md_set_code_scroll(e, b.first, clamp(e.mdv.code_scroll[b.first] + dx, 0, width - box))
}

md_set_code_scroll :: proc(e: ^Editor, first: int, x: f32) {
	mv := &e.mdv
	if mv.code_scroll[first] == x do return
	mv.code_scroll[first] = x
	mv.code_scroll_gen += 1
}

// Scrolls the code block under a point sideways. Returns false if there is
// none, or it fits.
md_scroll_code_at :: proc(e: ^Editor, y: f32, dx: f32) -> bool {
	line, _ := md_line_at_y(e, y) or_return
	b, width, box := scrollable_code(e, line) or_return
	md_set_code_scroll(e, b.first, clamp(e.mdv.code_scroll[b.first] + dx, 0, width - box))
	return true
}

// The document offset under a point (logical window coordinates).
md_offset_at_point :: proc(e: ^Editor, x, y: f32) -> int {
	hm := &e.mdv.heights
	doc_y := f64(y - e.view.y) + e.scroll_y
	if doc_y < 0 do return 0
	if doc_y >= hm.total do return buffer.length(&e.buf)
	line, top := hm_find(hm, doc_y)
	L := md_line_layout(e, line)
	text, start := md_line_text(e, line)
	return start + md_index_at(L, text, x - e.view.x - e.mdv.col_x, f32(doc_y - top))
}

// Whether a point (logical window coordinates) is over the text column, or a
// table wider than it.
md_column_hit :: proc(e: ^Editor, x, y: f32) -> bool {
	mv := &e.mdv
	lx := x - e.view.x - mv.col_x
	if lx >= 0 && lx <= mv.col_w do return true
	line, _ := md_line_at_y(e, y) or_return
	L := md_line_layout(e, line)
	return len(L.edges) > 1 && lx >= L.edges[0] && lx <= L.edges[len(L.edges) - 1]
}

// Shows the caret again (from the keyboard): where it was if that is on
// screen, else at the start of the first line in view.
md_show_caret :: proc(e: ^Editor) {
	mv := &e.mdv
	if !mv.caretless do return
	mv.caretless = false
	head := e.sels[e.primary].head
	line := buffer.offset_to_line(&e.buf, head)
	top := hm_y(&mv.heights, line)
	if top < e.scroll_y || top + f64(hm_get(&mv.heights, line)) > e.scroll_y + f64(e.view.h) {
		first, first_top := hm_find(&mv.heights, e.scroll_y)
		if first_top < e.scroll_y && first + 1 < mv.heights.lines do first += 1
		at := buffer.line_start(&e.buf, first)
		set_single_selection(e, {at, at, -1})
	}
}

// Keys while the caret is hidden: paging and Ctrl+Home/End scroll, other
// movement shows the caret, and edits do nothing. Returns false for keys
// handled elsewhere (commands).
md_caretless_key :: proc(e: ^Editor, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	switch key.key {
	case sdl.K_PAGEUP:   e.target_y -= md_page_height(e)
	case sdl.K_PAGEDOWN: e.target_y += md_page_height(e)
	case sdl.K_HOME, sdl.K_END:
		if !ctrl {
			md_show_caret(e)
			return true
		}
		e.target_y = key.key == sdl.K_HOME ? 0 : md_max_scroll(e)
	case sdl.K_UP, sdl.K_DOWN, sdl.K_LEFT, sdl.K_RIGHT:
		md_show_caret(e)
	case sdl.K_BACKSPACE, sdl.K_DELETE, sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_TAB:
	case:
		return false
	}
	e.target_y = clamp(e.target_y, 0, md_max_scroll(e))
	return true
}

// The task box under a point, if any: its document range.
md_checkbox_at :: proc(e: ^Editor, x, y: f32) -> (lo, hi: int, ok: bool) {
	line, ly := md_line_at_y(e, y) or_return
	L := md_line_layout(e, line)
	start := buffer.line_start(&e.buf, line)
	lx := x - e.view.x - e.mdv.col_x
	for run in L.runs {
		if run.kind != .Checkbox do continue
		r := L.rows[run.row]
		if lx >= run.x - 2 && lx <= run.x + run.w + 2 && ly >= r.y && ly <= r.y + r.h {
			return start + int(run.lo), start + int(run.hi), true
		}
	}
	return
}

// --- Drawing --------------------------------------------------------------------------------

draw_markdown :: proc(renderer: ^sdl.Renderer, e: ^Editor, b: clay.BoundingBox, scale: f32) {
	mv := &e.mdv
	hm := &mv.heights
	if hm.lines == 0 do return
	push_clip_box(renderer, b)
	defer pop_clip(renderer)

	left := b.x + mv.col_x * scale
	first, top := hm_find(hm, e.scroll_y)
	y := f64(b.y) + (top - e.scroll_y) * f64(scale)

	// The visible lines, and syntax colors for the code among them that names
	// its language (the only text drawn in them).
	Visible :: struct {
		line: int,
		y:    f32,
		L:    ^Line_Layout,
	}
	lines := make([dynamic]Visible, context.temp_allocator)
	for line := first; line < hm.lines && y < f64(b.y + b.height); line += 1 {
		L := md_line_layout(e, line)
		append(&lines, Visible{line, f32(y), L})
		y += f64(hm_get(hm, line)) * f64(scale)
	}
	if len(lines) == 0 do return
	code_lo, code_hi := -1, -1
	for v in lines {
		if e.md.lines[v.line].kind != .Fence_Body || markdown.line_state(e.md, v.line).fence_lang == .None do continue
		if code_lo < 0 do code_lo = v.line
		code_hi = v.line
	}
	hl_lo := 0
	hl: []syntax.Highlight
	if code_lo >= 0 {
		hl_lo = buffer.line_start(&e.buf, code_lo)
		n := min(buffer.line_end(&e.buf, code_hi) - hl_lo, MAX_LINE_SCAN)
		c := &mv.code_hl
		if c.hl == nil || c.lo != hl_lo || len(c.hl) != n {
			c.lo = hl_lo
			c.hl = make([]syntax.Highlight, n, mv.doc_allocator)
			markdown.highlight_range(e.md, &e.buf, hl_lo, c.hl, make([]markdown.Text_Styles, n, context.temp_allocator))
		}
		hl = c.hl
	}

	caret_on := g.focus == .Editor && !mv.caretless && ((sdl.GetTicksNS() - e.blink_t0) / CARET_BLINK_NS) % 2 == 0
	for v in lines {
		text, start := md_line_text(e, v.line)
		line_hl := hl[clamp(start - hl_lo, 0, len(hl)):clamp(start - hl_lo + len(text), 0, len(hl))]
		draw_md_line(renderer, e, v.line, v.L, text, start, line_hl, left, v.y, scale, caret_on)
	}
}

@(private = "file")
draw_md_line :: proc(renderer: ^sdl.Renderer, e: ^Editor, line: int, L: ^Line_Layout, text: string, start: int, hl: []syntax.Highlight, left, y: f32, scale: f32, caret_on: bool) {
	mv := &e.mdv
	px :: proc(left, x, scale: f32) -> f32 {return math.round(left + x * scale)}
	h := L.height * scale

	for box in L.images {
		r := clay.BoundingBox{px(left, box.x, scale), math.round(y + box.y * scale), math.round(box.w * scale), math.round(box.h * scale)}
		img := md_image(string(L.strings[box.path[0]:box.path[1]]))
		if img.state == .Ready {
			dst := sdl.FRect{r.x, r.y, r.width, r.height}
			_ = sdl.RenderTexture(renderer, img.texture, nil, &dst)
			continue
		}
		fill_rounded_rect(renderer, r, clay.CornerRadiusAll(6 * scale), theme.md_code_bg)
		if img.state == .Failed {
			icon_box := clay.BoundingBox{r.x, r.y, r.width, r.height * 0.6}
			draw_icon(renderer, {.Image_Off, theme.text_faint, u16(24)}, icon_box)
		}
		if box.alt[1] > box.alt[0] {
			if font := text_get_font(&g.text, .Md_Italic, md_font_size()); font != nil {
				if t := text_get(&g.text, font, text[box.alt[0]:box.alt[1]]); t != nil {
					tw, th: i32
					_ = ttf.GetTextSize(t, &tw, &th)
					draw_text(t, math.round(r.x + (r.width - f32(tw)) / 2), math.round(r.y + r.height * 0.62), theme.text_dim)
				}
			}
		}
	}

	if L.code_bg != {} {
		radius := 6 * scale
		r := clay.CornerRadius{L.round[0] ? radius : 0, L.round[0] ? radius : 0, L.round[1] ? radius : 0, L.round[1] ? radius : 0}
		x0 := px(left, L.code_bg[0], scale)
		fill_rounded_rect(renderer, {x0, math.round(y), px(left, L.code_bg[1], scale) - x0, math.ceil(h)}, r, theme.md_code_bg)
	}
	for bar in L.bars[:L.n_bars] {
		fill_rect(renderer, px(left, bar, scale), math.round(y), max(math.round(3 * scale), 1), math.ceil(h), theme.md_rule)
	}
	clipped := false
	if L.code_bg != {} {
		x0 := px(left, L.code_bg[0] + MD_CODE_PAD, scale)
		x1 := px(left, L.code_bg[1] - MD_CODE_PAD, scale)
		if L.round[1] {
			if track, thumb, _, ok := md_code_bar(e, line); ok {
				active := mv.code_drag.active || rect_contains(code_bar_grab_area(track), g.mouse_pos)
				r := clay.BoundingBox{math.round(thumb.x * scale), math.round(thumb.y * scale), math.round(thumb.w * scale), max(math.round(thumb.h * scale), 2)}
				fill_rounded_rect(renderer, r, clay.CornerRadiusAll(r.height / 2), active ? theme.text_dim : theme.md_rule)
			}
		}
		// Code scrolled sideways stays inside its box; markers hanging left
		// of it are drawn first.
		if L.kind == .Code {
			for run in L.runs do if run.x < L.indent - 0.5 do draw_md_run(renderer, L, run, text, hl, left, y, scale)
			push_clip_box(renderer, {x0 - 2 * scale, math.round(y), x1 - x0 + 4 * scale, math.ceil(h)})
			clipped = true
		}
	}
	defer if clipped do pop_clip(renderer)
	if L.kind == .Rule {
		fill_rect(renderer, px(left, L.indent, scale), math.round(y + h / 2), (mv.col_w - L.indent) * scale, max(math.round(scale), 1), theme.md_rule)
	}
	if len(L.edges) > 1 {
		// Table borders: around each cell, the header on a background.
		x0, x1 := px(left, L.edges[0], scale), px(left, L.edges[len(L.edges) - 1], scale)
		line := max(math.round(scale), 1)
		top, bottom := math.round(y), math.round(y + h)
		if L.kind == .Thin {
			fill_rect(renderer, x0, top, x1 - x0, bottom - top, theme.md_rule)
		} else {
			if L.header {
				fill_rect(renderer, x0, top, x1 - x0, bottom - top, theme.md_code_bg)
				fill_rect(renderer, x0, top, x1 - x0, line, theme.md_rule)
			}
			for edge in L.edges do fill_rect(renderer, px(left, edge, scale), top, line, bottom - top, theme.md_rule)
			fill_rect(renderer, x0, bottom - line, x1 - x0, line, theme.md_rule)
		}
	}

	// Selections.
	end := start + len(text)
	for j := mv.caretless ? len(e.sels) : first_selection_at(e, start); j < len(e.sels); j += 1 {
		lo, hi := sel_lo(e.sels[j]), sel_hi(e.sels[j])
		if lo > end do break
		if hi < start || lo == hi do continue
		for r, ri in L.rows {
			row_lo := start + int(r.lo)
			row_hi := ri + 1 < len(L.rows) ? start + int(L.rows[ri + 1].lo) : end
			if hi < row_lo || lo > row_hi || (lo == row_hi && ri + 1 < len(L.rows)) do continue
			_, x1 := md_caret_x(L, text, max(lo, row_lo) - start)
			_, x2 := md_caret_x(L, text, min(hi, row_hi) - start)
			if hi > end && ri == len(L.rows) - 1 do x2 += f32(md_font_size()) * 0.4
			fill_rect(renderer, px(left, x1, scale), math.round(y + r.y * scale), (x2 - x1) * scale, math.ceil(r.h * scale), theme.selection)
		}
	}

	for run in L.runs {
		// Code lines drew their hanging markers outside the clip.
		if clipped && run.x < L.indent - 0.5 do continue
		draw_md_run(renderer, L, run, text, hl, left, y, scale)
	}

	if caret_on {
		caret_w := max(math.round(2 * scale), 1)
		for j := first_selection_at(e, start); j < len(e.sels); j += 1 {
			h := e.sels[j].head
			if sel_lo(e.sels[j]) > end do break
			if h < start || h > end do continue
			row, x := md_caret_x(L, text, h - start)
			r := L.rows[row]
			fill_rect(renderer, px(left, x, scale), math.round(y + r.y * scale), caret_w, math.ceil(r.h * scale), theme.caret)
		}
	}
}

@(private = "file")
draw_md_run :: proc(renderer: ^sdl.Renderer, L: ^Line_Layout, run: Md_Run, text: string, hl: []syntax.Highlight, left, y: f32, scale: f32) {
	px :: proc(left, x, scale: f32) -> f32 {return math.round(left + x * scale)}
	r := L.rows[run.row]
	ry := y + r.y * scale
	m := font_metrics(&g.text, run.font, run.size)
	baseline := ry + (r.baseline + run.dy) * scale
	x := px(left, run.x, scale)
	#partial switch run.kind {
	case .Text:
		s := run.subst != {} ? string(L.strings[run.subst[0]:run.subst[1]]) : text[run.lo:run.hi]
		if .Code in run.style {
			pad := (MD_CODE_SPAN_PAD - 1) * scale
			fill_rounded_rect(renderer, {x - pad, math.round(baseline - (m.ascent + 2) * scale), run.w * scale + 2 * pad, math.round((m.ascent + m.descent + 4) * scale)}, clay.CornerRadiusAll(4 * scale), theme.md_code_bg)
		}
		if .Mark in run.style {
			fill_rect(renderer, x, math.round(baseline - m.ascent * scale), run.w * scale, math.round((m.ascent + m.descent) * scale), theme.md_mark_bg)
		}
		font := text_get_font(&g.text, run.font, run.size)
		if font == nil do return
		color := md_color(run.color)
		rise := .Super in run.style ? f32(run.size) * 0.5 * scale : 0
		if t := text_get(&g.text, font, s); t != nil {
			draw_text(t, x, math.round(baseline - m.ascent * scale - rise), color)
		}
		thick := max(math.round(scale), 1)
		if .Underline in run.style do fill_rect(renderer, x, math.round(baseline + 2 * scale), run.w * scale, thick, color)
		if .Strike in run.style do fill_rect(renderer, x, math.round(baseline - f32(run.size) * 0.3 * scale), run.w * scale, thick, color)
	case .Mono:
		font := text_get_font(&g.text, .Editor, run.size)
		if font == nil do return
		seg := text[run.lo:run.hi]
		seg_hl := run.color == .Code && int(run.hi) <= len(hl) ? hl[run.lo:run.hi] : nil
		for part in visible_runs(seg, seg_hl, nil, 0, max(int)) {
			color := run.color == .Code ? md_color(.Code, part.hl) : md_color(run.color)
			if t := text_get(&g.text, font, part.text); t != nil {
				draw_text(t, math.round(x + f32(part.col) * L.char_w * scale), math.round(baseline - m.ascent * scale), color)
			}
		}
	case .Bullet:
		size := f32(run.size) * scale
		radius := math.round(size * 0.16)
		cx := x + run.w * scale / 2
		cy := math.round(baseline - size * 0.33)
		box := clay.BoundingBox{math.round(cx - radius), cy - radius, radius * 2, radius * 2}
		switch (run.depth - 1) % 3 {
		case 0: fill_rounded_rect(renderer, box, clay.CornerRadiusAll(radius), theme.text_dim)
		case 1:
			fill_rounded_rect(renderer, box, clay.CornerRadiusAll(radius), theme.text_dim)
			inner := max(math.round(1.5 * scale), 1)
			fill_rounded_rect(renderer, {box.x + inner, box.y + inner, box.width - 2 * inner, box.height - 2 * inner}, clay.CornerRadiusAll(radius - inner), theme.bg)
		case:   fill_rect(renderer, box.x, box.y, box.width, box.height, theme.text_dim)
		}
	case .Checkbox:
		box := run.w * scale
		bx := clay.BoundingBox{x, math.round(baseline - m.ascent * scale + (m.ascent * scale - box) * 0.5 + 1), math.round(box), math.round(box)}
		radius := clay.CornerRadiusAll(3 * scale)
		if run.checked {
			fill_rounded_rect(renderer, bx, radius, theme.accent)
			draw_icon(renderer, {.Check, theme.bg, u16(math.round(f32(run.size) * 0.8))}, bx)
		} else {
			fill_rounded_rect(renderer, bx, radius, theme.text_dim)
			inner := max(math.round(1.5 * scale), 1)
			fill_rounded_rect(renderer, {bx.x + inner, bx.y + inner, bx.width - 2 * inner, bx.height - 2 * inner}, clay.CornerRadiusAll(2 * scale), theme.bg)
		}
	}
}

// --- Height map -------------------------------------------------------------------------------

// Per-line heights in chunks with running sums, so that finding the line at a
// y position and splicing lines in or out are cheap on large documents.

@(private = "file")
HM_CHUNK :: 512

Height_Map :: struct {
	chunks: [dynamic]Height_Chunk,
	total:  f64,
	lines:  int,
}

Height_Chunk :: struct {
	h:   [dynamic]f32,
	sum: f64,
}

hm_destroy :: proc(hm: ^Height_Map) {
	for c in hm.chunks do delete(c.h)
	delete(hm.chunks)
	hm^ = {}
}

// The chunk and index within it of a line (or one past the last line).
@(private = "file")
hm_locate :: proc(hm: ^Height_Map, line: int) -> (c, k: int) {
	line := line
	for &ch, i in hm.chunks {
		if line < len(ch.h) || i == len(hm.chunks) - 1 do return i, min(line, len(ch.h))
		line -= len(ch.h)
	}
	return 0, 0
}

hm_get :: proc(hm: ^Height_Map, line: int) -> f32 {
	if line < 0 || line >= hm.lines do return 0
	c, k := hm_locate(hm, line)
	return hm.chunks[c].h[k]
}

hm_set :: proc(hm: ^Height_Map, line: int, h: f32) {
	if line < 0 || line >= hm.lines do return
	c, k := hm_locate(hm, line)
	ch := &hm.chunks[c]
	d := f64(h) - f64(ch.h[k])
	ch.h[k] = h
	ch.sum += d
	hm.total += d
}

// The y of a line's top.
hm_y :: proc(hm: ^Height_Map, line: int) -> f64 {
	y: f64
	line := clamp(line, 0, hm.lines)
	for &ch in hm.chunks {
		if line < len(ch.h) {
			for h in ch.h[:line] do y += f64(h)
			return y
		}
		line -= len(ch.h)
		y += ch.sum
	}
	return y
}

// The line at y, and its top.
hm_find :: proc(hm: ^Height_Map, y: f64) -> (line: int, top: f64) {
	if hm.lines == 0 do return 0, 0
	for &ch, ci in hm.chunks {
		if y < top + ch.sum || ci == len(hm.chunks) - 1 {
			for h, k in ch.h {
				if y < top + f64(h) || k == len(ch.h) - 1 do return line + k, top
				top += f64(h)
			}
			return line, top
		}
		top += ch.sum
		line += len(ch.h)
	}
	return hm.lines - 1, top
}

// Removes `removed` lines at `at` and inserts lines of the given heights there.
hm_splice :: proc(hm: ^Height_Map, at, removed: int, inserted: []f32) {
	if len(hm.chunks) == 0 do append(&hm.chunks, Height_Chunk{})
	at := clamp(at, 0, hm.lines)
	removed := min(removed, hm.lines - at)
	hm.lines -= removed
	for removed > 0 {
		c, k := hm_locate(hm, at)
		ch := &hm.chunks[c]
		take := min(removed, len(ch.h) - k)
		remove_range(&ch.h, k, k + take)
		removed -= take
		if len(ch.h) == 0 && len(hm.chunks) > 1 {
			delete(ch.h)
			ordered_remove(&hm.chunks, c)
		}
	}
	if len(inserted) > 0 {
		c, k := hm_locate(hm, at)
		hm.lines += len(inserted)
		if len(hm.chunks[c].h) + len(inserted) <= 2 * HM_CHUNK {
			inject_at(&hm.chunks[c].h, k, ..inserted)
		} else {
			// Re-chunk the chunk with the new lines in it.
			all := make([dynamic]f32, 0, len(hm.chunks[c].h) + len(inserted), context.temp_allocator)
			append(&all, ..hm.chunks[c].h[:k])
			append(&all, ..inserted)
			append(&all, ..hm.chunks[c].h[k:])
			delete(hm.chunks[c].h)
			ordered_remove(&hm.chunks, c)
			parts := make([dynamic]Height_Chunk, 0, len(all) / HM_CHUNK + 1, context.temp_allocator)
			for lo := 0; lo < len(all); lo += HM_CHUNK {
				h := make([dynamic]f32, 0, HM_CHUNK)
				append(&h, ..all[lo:min(lo + HM_CHUNK, len(all))])
				append(&parts, Height_Chunk{h = h})
			}
			inject_at(&hm.chunks, c, ..parts[:])
		}
	}
	hm.total = 0
	for &ch in hm.chunks {
		ch.sum = 0
		for h in ch.h do ch.sum += f64(h)
		hm.total += ch.sum
	}
}
