package mdview

import "core:hash"
import "core:math"
import "core:mem"
import "core:mem/virtual"

import "../buffer"
import "../markdown"
import sdl "../../vendor/sdl3"
import "../gfx"
import "../textedit"

// The rendered Markdown view: the same document and selections as the text
// view, drawn with real typography and edited in place. Lines have their own
// heights (wrapped rows, headings), kept in a height map; lines not yet laid
// out have estimated heights, corrected as they come into view without moving
// what is on screen (see layout_visible).

// Larger files open as text.
@(private)
RENDER_MAX_BYTES :: 8 << 20
// Space on each side of the text column.
COLUMN_PAD :: 32

Mode :: enum u8 {
	Text,
	Rendered,
}

// The rendered view of a Markdown document: the textedit.View it renders
// (whose kind is KIND while rendered, text_kind otherwise), the document's
// Markdown structure, and this view's own state. Set up by attach.
View :: struct {
	using tv:  ^textedit.View,
	md:        ^markdown.Doc, // the document's block structure (not owned)
	text_kind: ^textedit.Kind,
	mdv:       State,
}

@(private)
Selection :: textedit.Selection

@(private)
State :: struct {
	mode:            Mode,
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
	wide_tables:     map[int]bool, // tables expanded past the column, by header line
	// The mouse is selecting a rectangle of table cells (cell_drag).
	cell_drag:       bool,
	code_drag:       struct {
		active: bool,
		last:   int, // the block's last line, which holds its scroll bar
		grab:   f32, // pointer x minus the thumb's left when the drag began
	},
	// Caches for the document, cleared when it or the fonts change, then memo:
	// line layouts for the current selections and column width (see begin_caches).
	arena:           virtual.Arena,
	doc_allocator:   mem.Allocator,
	doc_token:       u64,
	fitted:          [2]f32, // the column and view widths tables are fitted to
	blocks:          map[int]^Block,
	tables:          map[int]^Table, // by delimiter row
	code_blocks:     map[int]^Code_Block, // by first line
	code_hl:         map[int]Code_Colors, // by line
	token:           u64,
	memo:            map[int]^Line_Layout,
	// While the mouse button is down, syntax is revealed for the selections
	// from before it was pressed, so the text doesn't move under the pointer.
	holding:         bool,
	held:            [dynamic]Selection,
}

// A code block's lines, and the width of its widest line once measured.
@(private)
Code_Block :: struct {
	first, last: int,
	width:       f32,
	measured:    bool,
}

rendered :: proc(e: ^View) -> bool {
	return e.md != nil && e.mdv.mode == .Rendered
}

// Connects a rendered view to the text view `tv` of a Markdown document and
// shows it in `mode`; in the text mode, tv's kind is `text_kind`.
attach :: proc(e: ^View, tv: ^textedit.View, md: ^markdown.Doc, text_kind: ^textedit.Kind, mode: Mode) {
	e.tv, e.md, e.text_kind = tv, md, text_kind
	e.mdv.mode = mode
	e.mdv.caretless = mode == .Rendered
	set_kind(e)
}

@(private)
set_kind :: proc(e: ^View) {
	if rendered(e) {
		e.kind, e.kind_data = &KIND, e
	} else {
		e.kind, e.kind_data = e.text_kind, nil
	}
}

destroy :: proc(mv: ^State) {
	for _, L in mv.layouts do layout_destroy(L)
	delete(mv.layouts)
	delete(mv.code_scroll)
	delete(mv.wide_tables)
	delete(mv.held)
	hm_destroy(&mv.heights)
	if mv.doc_allocator.procedure != nil do virtual.arena_destroy(&mv.arena)
	mv^ = {}
}

// Switches between the text and rendered views, keeping the top line in place.
set_mode :: proc(e: ^View, mode: Mode) {
	if e.md == nil || e.mdv.mode == mode do return
	mv := &e.mdv
	top: int
	if mode == .Rendered {
		top = int(e.scroll_y) / env.config().text_line_height
	} else {
		top, _ = hm_find(&mv.heights, e.scroll_y)
	}
	mv.mode = mode
	set_kind(e)
	mv.caretless = false
	mv.measured = {}
	for &s in e.sels do s.col = -1
	e.scroll_x, e.target_x = 0, 0
	if mode == .Rendered {
		column(e)
		check_heights(e)
		textedit.scroll_to(e, top == 0 ? 0 : hm_y(&mv.heights, top))
	} else {
		textedit.scroll_to(e, f64(top * env.config().text_line_height))
	}
	e.reveal = true
}

// Switches to the other view and returns the mode it is in now.
toggle_view :: proc(e: ^View) -> Mode {
	mode: Mode = e.mdv.mode == .Rendered ? .Text : .Rendered
	set_mode(e, mode)
	return mode
}

// The mode a Markdown file of `size` bytes opens in, from the settings.
default_mode :: proc(size: int) -> Mode {
	if env.config().text_by_default || size > RENDER_MAX_BYTES do return .Text
	return .Rendered
}

// --- Caches -----------------------------------------------------------------------------

// Starts (or keeps) the caches that depend on the document, and the line
// layouts, which also depend on the selections.
@(private)
begin_caches :: proc(e: ^View) {
	mv := &e.mdv
	fresh := mv.doc_allocator.procedure == nil
	if fresh {
		_ = virtual.arena_init_growing(&mv.arena)
		mv.doc_allocator = virtual.arena_allocator(&mv.arena)
	}
	doc := [?]u64 {
		e.buf.version,
		e.md.version,
		e.md.refdef_gen,
		gfx.text_system.generation,
		u64(transmute(u32)gfx.scale),
		u64(env.config().font_size),
		transmute(u64)env.config().line_height,
	}
	h := hash.fnv64a(mem.slice_to_bytes(doc[:]))
	if h != mv.doc_token || fresh {
		mv.doc_token = h
		virtual.arena_free_all(&mv.arena)
		mv.blocks = make(map[int]^Block, mv.doc_allocator)
		mv.tables = make(map[int]^Table, mv.doc_allocator)
		mv.code_blocks = make(map[int]^Code_Block, mv.doc_allocator)
		mv.code_hl = make(map[int]Code_Colors, mv.doc_allocator)
		mv.memo = make(map[int]^Line_Layout, mv.doc_allocator)
		mv.token = 0
	}
	fit := [2]f32{mv.col_w, e.view.w}
	if fit != mv.fitted {
		mv.fitted = fit
		for _, t in mv.tables do fit_table(e, t)
	}
	h = hash.fnv64a(mem.slice_to_bytes(reveal_sels(e)), h)
	view := [?]u64{u64(mv.caretless), u64(transmute(u32)mv.col_w), u64(transmute(u32)e.view.w)}
	h = hash.fnv64a(mem.slice_to_bytes(view[:]), h)
	if h == mv.token do return
	mv.token = h
	clear(&mv.memo)
}

// Drops layouts that haven't been used for a while.
@(private)
end_frame :: proc(e: ^View) {
	mv := &e.mdv
	if env.input().frame % 64 != 0 || len(mv.layouts) == 0 do return
	stale := make([dynamic]u64, context.temp_allocator)
	for key, L in mv.layouts do if env.input().frame - L.last_used > gfx.TEXT_CACHE_EVICT_FRAMES do append(&stale, key)
	for key in stale {
		layout_destroy(mv.layouts[key])
		delete_key(&mv.layouts, key)
	}
	// The memo may point at them.
	if len(stale) > 0 do clear(&mv.memo)
}

// Whether some selection touches [lo, hi] (a caret at either end counts).
@(private)
touches :: proc(e: ^View, lo, hi: int) -> bool {
	sels := reveal_sels(e)
	i := textedit.first_selection_in(sels, lo)
	return i < len(sels) && textedit.sel_lo(sels[i]) <= hi
}

// The selections that reveal syntax.
@(private = "file")
reveal_sels :: proc(e: ^View) -> []Selection {
	mv := &e.mdv
	if mv.holding do return mv.held[:]
	return mv.caretless ? nil : e.sels[:]
}

// Keeps what is revealed as it is until the mouse button is released.
@(private)
hold_reveal :: proc(e: ^View) {
	mv := &e.mdv
	clear(&mv.held)
	if !mv.caretless do append(&mv.held, ..e.sels[:])
	mv.holding = true
}

// --- Frame --------------------------------------------------------------------------------

// Places the text column in the view.
@(private)
column :: proc(e: ^View) {
	mv := &e.mdv
	avail := max(e.view.w - 2 * COLUMN_PAD, 120)
	w := avail
	if env.config().max_width > 0 do w = min(f32(env.config().max_width), avail)
	mv.col_w = math.round(w)
	mv.col_x = math.round((e.view.w - w) / 2)
}

// Re-estimates every line's height when the column or fonts changed.
@(private)
check_heights :: proc(e: ^View) {
	mv := &e.mdv
	m := &mv.measured
	n := buffer.line_count(&e.buf)
	if m.col_w == mv.col_w && m.generation == gfx.text_system.generation && m.size == env.config().font_size && m.line_height == env.config().line_height && mv.heights.lines == n do return
	m^ = {mv.col_w, gfx.text_system.generation, env.config().font_size, env.config().line_height}
	hm_destroy(&mv.heights)
	mv.heights.pad = math.round(f64(body_line_height()))
	est := make([]f32, n, context.temp_allocator)
	for &h, i in est do h = estimate(e, i)
	hm_splice(&mv.heights, 0, 0, est)
}

// A line's height before it is laid out, from its kind and length.
@(private)
estimate :: proc(e: ^View, i: int) -> f32 {
	size := f32(font_size())
	body := math.round(size * line_factor())
	if i >= len(e.md.lines) do return body
	l := e.md.lines[i]
	code := math.round(f32(code_size(font_size())) * CODE_LINE_FACTOR)
	#partial switch l.kind {
	case .Blank:                                             return body
	case .Atx_Heading:
		top, bottom := heading_pads(l.aux)
		hs := f32(heading_size(l.aux))
		row := math.round(hs * f32(HEADING_LINE_FACTOR))
		return top + row + bottom
	case .Fence_Open, .Fence_Close, .Math_Fence, .Front_Matter_Fence: return fence_row_height()
	case .Setext_Underline:                                  return SETEXT_ROW
	case .Fence_Body, .Indented_Code, .Html, .Math_Body, .Front_Matter_Body:
		return code
	case .Table_Delim: return 1
	case .Table_Row:   return body + 2 * CELL_VPAD
	}
	per_row := max(e.mdv.col_w / (size * 0.48), 1)
	return body * max(math.ceil(f32(l.len) / per_row), 1)
}

// Follows the buffer's edits in the height map.
edit :: proc(e: ^View, changes: []buffer.Change) {
	if !rendered(e) do return
	for c in changes {
		removed := c.old_end.row - c.start.row
		inserted := c.new_end.row - c.start.row
		if removed == 0 && inserted == 0 do continue
		shift_line_keys(&e.mdv.code_scroll, c.start.row, c.old_end.row, inserted - removed)
		shift_line_keys(&e.mdv.wide_tables, c.start.row, c.old_end.row, inserted - removed)
		est := make([]f32, inserted, context.temp_allocator)
		for &h in est do h = math.round(body_line_height())
		hm_splice(&e.mdv.heights, c.start.row + 1, removed, est)
	}
}

// Moves the keys of a map by line past an edit that replaced lines
// (first, last] with lines that end delta lines later; keys of replaced lines go.
@(private)
shift_line_keys :: proc(m: ^map[int]$T, first, last, delta: int) {
	if len(m) == 0 do return
	Moved :: struct {
		line:  int,
		value: T,
	}
	moved := make([dynamic]Moved, context.temp_allocator)
	for line, v in m do if line > last do append(&moved, Moved{line + delta, v})
	for line in m do if line > first do delete_key(m, line)
	for mv in moved do m[mv.line] = mv.value
}

// The view's part of the editor's per-frame update, before the mouse: column, heights and parsing.
@(private)
frame_begin :: proc(e: ^View) {
	loaded := images_poll()
	if wiki_poll() || loaded do e.mdv.token = 0
	column(e)
	check_heights(e)
	last, _ := hm_find(&e.mdv.heights, e.scroll_y + f64(e.view.h))
	markdown.doc_update(e.md, &e.buf, last + markdown.LOOKAHEAD_LINES, markdown.PARSE_BUDGET)
}

// Lays out the visible lines, putting their real heights in the height map,
// and keeps the top line where it was on screen.
@(private)
layout_visible :: proc(e: ^View) {
	mv := &e.mdv
	hm := &mv.heights
	if hm.lines == 0 do return
	top, top_y := hm_find(hm, e.scroll_y)
	offset := e.scroll_y - top_y
	line := max(top - 1, 0)
	y := hm_y(hm, line)
	bottom := e.scroll_y + f64(e.view.h)
	for line < hm.lines && y <= bottom + 1 {
		L := line_layout(e, line)
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

// Whether an image in view is still loading (its placeholder has another size).
@(private)
images_loading :: proc(e: ^View) -> bool {
	hm := &e.mdv.heights
	if hm.lines == 0 do return false
	line, y := hm_find(hm, e.scroll_y)
	for ; line < hm.lines && y < e.scroll_y + f64(e.view.h); line += 1 {
		L := line_layout(e, line)
		for box in L.images do if get_image(string(L.strings[box.path[0]:box.path[1]])).state == .Loading do return true
		y += f64(L.height)
	}
	return false
}

@(private)
max_scroll :: proc(e: ^View) -> f64 {
	hm := &e.mdv.heights
	if hm.lines == 0 do return 0
	return max(hm.total - f64(hm_get(hm, hm.lines - 1)), 0)
}

// --- Caret and navigation -------------------------------------------------------------

@(private)
Caret :: struct {
	line:  int,
	L:     ^Line_Layout,
	row:   int,
	x:     f32,
	text:  string,
	start: int,
}

caret_at :: proc(e: ^View, offset: int) -> (c: Caret) {
	c.line = buffer.offset_to_line(&e.buf, offset)
	c.L = line_layout(e, c.line)
	c.text, c.start = line_text(e, c.line)
	c.row, c.x = caret_row_x(c.L, c.text, offset - c.start)
	return
}

// The goal x of vertical movement, kept in Selection.col in 1/64 px.
@(private = "file")
GOAL_UNITS :: 64

@(private = "file")
goal_x :: proc(s: Selection, caret_x: f32) -> f32 {
	return s.col >= 0 ? f32(s.col) / GOAL_UNITS : caret_x
}

@(private = "file")
goal_col :: proc(x: f32) -> int {
	return int(math.round(x * GOAL_UNITS))
}

// Moves `rows` visual rows up or down, keeping the goal x. A table row's rows
// are the lines of the cell under the goal x (its delimiter row has none).
@(private)
move_vertical :: proc(e: ^View, s: Selection, rows: int) -> (head, col: int) {
	c := caret_at(e, s.head)
	goal := goal_x(s, c.x)
	line, L, row := c.line, c.L, c.row
	n := buffer.line_count(&e.buf)
	cl := 0 // the line of a table row's cell
	if L.kind == .Table {
		_, _, top, _ := caret_box(L, c.text, s.head - c.start)
		cl = int(math.round((top - L.rows[0].y - CELL_VPAD) / max(L.cell_h, 1)))
	}
	table_delim :: proc(e: ^View, line: int, L: ^Line_Layout) -> bool {
		return e.md.lines[line].kind == .Table_Delim && L.kind == .Thin && len(L.edges) > 1
	}
	for _ in 0 ..< abs(rows) {
		if rows < 0 {
			switch {
			case L.kind == .Table && cl > 0: cl -= 1
			case row > 0:  row -= 1
			case line > 0:
				line -= 1
				L = line_layout(e, line)
				if table_delim(e, line, L) && line > 0 {
					line -= 1
					L = line_layout(e, line)
				}
				row = len(L.rows) - 1
				if L.kind == .Table do cl = table_cell_lines(L, goal) - 1
			case:          return 0, goal_col(goal)
			}
		} else {
			switch {
			case L.kind == .Table && cl < table_cell_lines(L, goal) - 1: cl += 1
			case row < len(L.rows) - 1: row += 1
			case line < n - 1:
				line += 1
				L = line_layout(e, line)
				if table_delim(e, line, L) && line < n - 1 {
					line += 1
					L = line_layout(e, line)
				}
				row = 0
				cl = 0
			case:                       return buffer.length(&e.buf), goal_col(goal)
			}
		}
	}
	text, start := line_text(e, line)
	r := L.rows[row]
	y := r.y + r.h / 2
	if L.kind == .Table do y = r.y + CELL_VPAD + (f32(cl) + 0.5) * L.cell_h
	return start + index_at(L, text, goal, y), goal_col(goal)
}

// Moves a page up or down (dir = -1 or 1), keeping the goal x.
@(private)
move_page :: proc(e: ^View, s: Selection, dir: int) -> (head, col: int) {
	c := caret_at(e, s.head)
	goal := goal_x(s, c.x)
	hm := &e.mdv.heights
	r := c.L.rows[c.row]
	y := hm_y(hm, c.line) + f64(r.y + r.h / 2) + f64(dir) * page_height(e)
	if y < 0 do return 0, goal_col(goal)
	if y >= hm.total do return buffer.length(&e.buf), goal_col(goal)
	line, top := hm_find(hm, y)
	L := line_layout(e, line)
	text, start := line_text(e, line)
	return start + index_at(L, text, goal, f32(y - top)), goal_col(goal)
}

@(private)
page_height :: proc(e: ^View) -> f64 {
	return max(f64(e.view.h) - f64(body_line_height()), f64(body_line_height()))
}

// Left: from a list item's text start, to the end of the line before, over its
// hidden marker; from a table cell's text start, to the end of the cell before
// (or of the row above); over a line break in a cell, whole.
@(private)
move_left :: proc(e: ^View, offset: int) -> int {
	line := buffer.offset_to_line(&e.buf, offset)
	if cells, start, ok := md_row_cells(e, line); ok {
		k := cell_index(cells, offset - start)
		if lo, _, br := break_tag(e, line, offset - start, -1); br do return start + lo
		if offset - start <= cells[k].text_lo {
			if k > 0 do return start + cells[k - 1].text_hi
			above := line - 1
			if above > 0 && e.md.lines[above].kind == .Table_Delim do above -= 1
			if prev, prev_start, prev_ok := md_row_cells(e, above); prev_ok do return prev_start + prev[len(prev) - 1].text_hi
			return textedit.prev_boundary(e, start)
		}
	}
	if offset == item_text(e, line) do return textedit.prev_boundary(e, buffer.line_start(&e.buf, line))
	return textedit.prev_boundary(e, offset)
}

// Right: from the end of a line, to the text start of a list item after it;
// from a table cell's text end, to the start of the cell after (or of the row
// below); over a line break in a cell, whole.
@(private)
move_right :: proc(e: ^View, offset: int) -> int {
	line := buffer.offset_to_line(&e.buf, offset)
	if cells, start, ok := md_row_cells(e, line); ok {
		k := cell_index(cells, offset - start)
		if _, hi, br := break_tag(e, line, offset - start, 1); br do return start + hi
		if offset - start >= cells[k].text_hi {
			if k + 1 < len(cells) do return start + cells[k + 1].text_lo
			below := line + 1 < len(e.md.lines) && e.md.lines[line + 1].kind == .Table_Delim ? line + 2 : line + 1
			if next, next_start, next_ok := md_row_cells(e, below); next_ok do return next_start + next[0].text_lo
			return textedit.next_boundary(e, buffer.line_end(&e.buf, line))
		}
	}
	if line + 1 < buffer.line_count(&e.buf) && offset == buffer.line_end(&e.buf, line) {
		if at := item_text(e, line + 1); at >= 0 do return at
	}
	return textedit.next_boundary(e, offset)
}

// Where the text of the list item starting on `line` begins, if its marker is
// hidden while the caret is there; -1 otherwise.
@(private = "file")
item_text :: proc(e: ^View, line: int) -> int {
	if .Item_Start not_in e.md.lines[line].flags do return -1
	text, start := textedit.line_text(e, line)
	d := markdown.line_detail(e.md, line, text)
	if d.n_marks == 0 || d.marks[d.n_marks - 1].kind == .Quote || d.content[0] <= d.marks[d.n_marks - 1].hi do return -1
	return start + int(d.content[0])
}

// Home: the start of the caret's visual row, then of the line; in a table,
// of the cell's text.
@(private)
move_home :: proc(e: ^View, offset: int) -> int {
	if cells, start, ok := md_row_cells(e, buffer.offset_to_line(&e.buf, offset)); ok {
		return start + cells[cell_index(cells, offset - start)].text_lo
	}
	c := caret_at(e, offset)
	lo, _ := row_bounds(c.L, c.row, len(c.text))
	if offset != c.start + lo do return c.start + lo
	if c.row == 0 do return c.start
	return offset
}

// End: the end of the caret's visual row; in a table, of the cell's text.
@(private)
move_end :: proc(e: ^View, offset: int) -> int {
	if cells, start, ok := md_row_cells(e, buffer.offset_to_line(&e.buf, offset)); ok {
		return start + cells[cell_index(cells, offset - start)].text_hi
	}
	c := caret_at(e, offset)
	if c.row == len(c.L.rows) - 1 do return c.start + len(c.text)
	next := int(c.L.rows[c.row + 1].lo)
	// Before the space the row wrapped at.
	if next > 0 && (c.text[next - 1] == ' ' || c.text[next - 1] == '\t') do next -= 1
	return c.start + next
}

// Scrolls so the primary caret's row is visible (for the app's editor_reveal).
@(private)
reveal_caret :: proc(e: ^View) {
	c := caret_at(e, e.sels[e.primary].head)
	r := c.L.rows[c.row]
	top := hm_y(&e.mdv.heights, c.line) + f64(r.y)
	bottom := top + f64(r.h)
	ty := e.target_y
	margin := f64(body_line_height())
	if top < ty do ty = max(top - margin, 0)
	if bottom > ty + f64(e.view.h) do ty = bottom + margin - f64(e.view.h)
	if ty != e.target_y do textedit.scroll_to(e, clamp(ty, 0, max_scroll(e)))

	// Sideways, in a code block.
	b, in_code := code_block_at(e, c.line)
	if !in_code do return
	content := int(markdown.line_detail(e.md, c.line, c.text).content[0])
	at := e.sels[e.primary].head - c.start
	if at < content do return
	cw := gfx.text_char_width(&gfx.text_system, .Editor, code_size(font_size()))
	x := f32(textedit.visual_col(c.text[content:], at - content)) * cw
	width, box := code_widths(e, b)
	scroll := e.mdv.code_scroll[b.first]
	if x < scroll do scroll = max(x - 4 * cw, 0)
	if x > scroll + box - cw do scroll = x - box + 2 * cw
	set_code_scroll(e, b.first, clamp(scroll, 0, max(width - box, 0)))
}

// The line under a y position (logical window coordinates), and the position
// within it.
@(private)
line_at_y :: proc(e: ^View, y: f32) -> (line: int, local_y: f32, ok: bool) {
	hm := &e.mdv.heights
	doc_y := f64(y - e.view.y) + e.scroll_y
	if doc_y < 0 || doc_y >= hm.total do return
	top: f64
	line, top = hm_find(hm, doc_y)
	return line, f32(doc_y - top), true
}

// The document offset under a point (logical window coordinates).
@(private)
offset_at_point :: proc(e: ^View, x, y: f32) -> int {
	hm := &e.mdv.heights
	doc_y := f64(y - e.view.y) + e.scroll_y
	if doc_y < 0 do return 0
	if doc_y >= hm.total do return buffer.length(&e.buf)
	line, top := hm_find(hm, doc_y)
	L := line_layout(e, line)
	text, start := line_text(e, line)
	return start + index_at(L, text, x - e.view.x - e.mdv.col_x, f32(doc_y - top))
}

// Whether a point (logical window coordinates) is over the text column, or a
// table wider than it.
@(private)
column_hit :: proc(e: ^View, x, y: f32) -> bool {
	mv := &e.mdv
	lx := x - e.view.x - mv.col_x
	if lx >= 0 && lx <= mv.col_w do return true
	line, _ := line_at_y(e, y) or_return
	L := line_layout(e, line)
	return len(L.edges) > 1 && lx >= L.edges[0] && lx <= L.edges[len(L.edges) - 1]
}

// Shows the caret again (from the keyboard): where it was if that is on
// screen, else at the start of the first line in view.
@(private)
show_caret :: proc(e: ^View) {
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
		textedit.set_single_selection(e, {at, at, -1})
	}
}

// Keys while the caret is hidden: paging and Ctrl+Home/End scroll, other
// movement shows the caret, and edits do nothing. Returns false for keys
// handled elsewhere (commands).
@(private)
caretless_key :: proc(e: ^View, key: sdl.KeyboardEvent) -> bool {
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	switch key.key {
	case sdl.K_PAGEUP:   e.target_y -= page_height(e)
	case sdl.K_PAGEDOWN: e.target_y += page_height(e)
	case sdl.K_HOME, sdl.K_END:
		if !ctrl {
			show_caret(e)
			return true
		}
		e.target_y = key.key == sdl.K_HOME ? 0 : max_scroll(e)
	case sdl.K_UP, sdl.K_DOWN, sdl.K_LEFT, sdl.K_RIGHT:
		show_caret(e)
	case:
		return false
	}
	e.target_y = clamp(e.target_y, 0, max_scroll(e))
	return true
}

// The task box under a point, if any: its document range.
@(private)
checkbox_at :: proc(e: ^View, x, y: f32) -> (lo, hi: int, ok: bool) {
	line, ly := line_at_y(e, y) or_return
	L := line_layout(e, line)
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
