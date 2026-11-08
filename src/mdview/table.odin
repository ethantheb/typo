package mdview

import "core:encoding/entity"
import "core:math"
import "core:strings"

import "../buffer"
import "../markdown"
import "../gfx"
import "../textedit"

// Tables in the rendered Markdown view: columns stretched across the text
// column (text that doesn't fit wraps, unless the table is expanded with the
// button by its header), and each row's cells laid out side by side. A table
// stays rendered while it is edited: the cell a selection touches shows its
// inline syntax and spaces, carets stay in cells (snap_carets), a mouse drag
// across cells selects a rectangle of them (cell_drag), and typing or
// deleting over cells empties them, keeping the pipes (replace_cells).
// Everything here works on a row's cells as byte ranges (Table_Cell), from
// markdown.row_cells


// --- Columns -----------------------------------------------------------------------

// The table containing line i (its header, delimiter row or a body row), with
// column widths from its cells' text as laid out; nil if i isn't in one
@(private)
table_at :: proc(e: ^View, i: int) -> ^Table {
	doc := e.md

	// Its delimiter row
	delim := -1
	#partial switch doc.lines[i].kind {
	case .Table_Delim:
		delim = i
	case .Table_Row:
		// The table starts at its header
		delim = markdown.block_first(doc, i) + 1
	case .Paragraph:
		if markdown.is_table_header(doc, i) do delim = i + 1
	}
	if delim < 1 || delim >= len(doc.lines) || doc.lines[delim].kind != .Table_Delim {
		return nil
	}

	mv := &e.mdv
	if t, ok := mv.tables[delim]; ok {
		return t
	}

	// Its lines
	t := new(Table, mv.doc_allocator)
	mv.tables[delim] = t
	t.first, t.last = delim - 1, delim
	for t.last + 1 < len(doc.lines) && doc.lines[t.last + 1].kind == .Table_Row {
		t.last += 1
	}

	// Column alignments, from the delimiter row's colons
	cols := max(int(doc.lines[delim].aux), 1)
	t.aligns = make([]u8, cols, mv.doc_allocator)
	delim_text, _ := line_text(e, delim)
	delim_content := int(markdown.line_detail(doc, delim, delim_text).content[0])
	for c, k in markdown.row_cells(delim_text, delim_content) {
		if k >= cols do break

		cell := strings.trim_space(delim_text[c[0]:c[1]])
		left, right := strings.has_prefix(cell, ":"), strings.has_suffix(cell, ":")
		switch {
		case left && right: t.aligns[k] = 1 // centered
		case right:         t.aligns[k] = 2 // right
		case:               t.aligns[k] = 0 // left
		}
	}

	// Each cell's width with its text on one line (each line, where it has
	// line breaks), from the pieces layout_table places
	t.widths = make([]f32, cols, mv.doc_allocator)
	p := Params{size = font_size()}
	for line in t.first ..= min(t.last, t.first + TABLE_MAX_ROWS) {
		if line == delim do continue

		text, start := line_text(e, line)
		ib := Item_Builder{items = make([dynamic]Item, context.temp_allocator)}
		content := int(markdown.line_detail(doc, line, text).content[0])
		cell_items(e, &ib, line, text, start, content, cols, line == t.first, false)

		for k in 0 ..< cols {
			pieces := build_pieces(ib.items[:], text, &p, k)
			from := 0
			for end in 0 ..= len(pieces) {
				if end < len(pieces) && !pieces[end].brk {
					continue
				}

				// The line of pieces [from, end)
				w: f32
				for pc in pieces[from:end] do w += pc.w_full
				if end > from do w -= pieces[end - 1].w_full - pieces[end - 1].w_word
				t.widths[k] = max(t.widths[k], w)
				from = end
			}
		}
	}

	// Whole pixels, so that a column at its text's width holds it on one line
	for &w in t.widths do w = max(math.ceil(w + 2 * CELL_PAD), 3 * CELL_PAD)

	t.edges = make([]f32, cols + 1, mv.doc_allocator)
	fit_table(e, t)
	return t
}


// Places a table's columns across the text column, stretched to fill it. When
// the cells don't fit on one line, their text wraps, unless the table is
// expanded (toggle_wide_table): then it is as wide as its text, up to the
// pane, centered on the column
@(private)
fit_table :: proc(e: ^View, t: ^Table) {
	mv := &e.mdv
	natural: f32
	for w in t.widths do natural += w

	// The table's width and left
	t.wraps = natural > mv.col_w + 0.5
	width := mv.col_w
	if t.wraps && mv.wide_tables[t.first] {
		width = min(natural, max(e.view.w - 2 * COLUMN_PAD, mv.col_w))
	}
	t.x = width <= mv.col_w ? 0 : math.round((mv.col_w - width) / 2)

	// Narrowing: columns narrower than an equal share of what is left keep
	// their width, the others share the rest. Widening: in proportion
	fitted := make([]f32, len(t.widths), context.temp_allocator)
	copy(fitted, t.widths)
	if natural > width {
		fixed := make([]bool, len(t.widths), context.temp_allocator)
		left := width
		flex := len(t.widths)
		for flex > 0 {
			changed := false
			for w, k in t.widths {
				if !fixed[k] && w <= left / f32(flex) {
					fixed[k] = true
					changed = true
					left -= w
					flex -= 1
				}
			}
			if !changed do break
		}

		flex_total: f32
		for w, k in t.widths {
			if !fixed[k] do flex_total += w
		}
		for w, k in t.widths {
			if !fixed[k] do fitted[k] = max(w * left / flex_total, 3 * CELL_PAD)
		}
	} else if natural > 0 {
		for &w in fitted do w *= width / natural
	}

	// Column edges, on whole pixels
	sum: f32
	for w, k in fitted {
		sum += w
		t.edges[k + 1] = math.round(sum)
	}
}


// Expands a table whose text wraps to the width of its text, or fits it back
// into the text column
@(private)
toggle_wide_table :: proc(e: ^View, t: ^Table) {
	mv := &e.mdv
	if mv.wide_tables[t.first] {
		delete_key(&mv.wide_tables, t.first)
	} else {
		mv.wide_tables[t.first] = true
	}

	fit_table(e, t)
	clear(&mv.memo)
}


@(private)
TABLE_BUTTON :: 20 // the expand button's size
@(private)
TABLE_BUTTON_GAP :: 6 // between the table and its expand button


// The expand button of the table whose header is on `line`, beside the
// header's top right corner, from the text column's left and the line's top.
// Only a table whose text wraps, or that is expanded, has one
@(private)
table_button :: proc(e: ^View, line: int) -> (box: gfx.Rect, t: ^Table, ok: bool) {
	begin_caches(e)
	t = table_at(e, line)
	if t == nil || t.first != line || !t.wraps {
		return
	}

	L := line_layout(e, line)
	right := t.x + t.edges[len(t.edges) - 1]

	// Level with the header's first line of text
	y := math.round(CELL_VPAD + (L.cell_h - TABLE_BUTTON) / 2)
	return {right + TABLE_BUTTON_GAP, y, TABLE_BUTTON, TABLE_BUTTON}, t, true
}


// Toggles the table whose expand button is at a window point
@(private)
table_button_click :: proc(e: ^View, x, y: f32) -> bool {
	line, local_y := line_at_y(e, y) or_return
	box, t := table_button(e, line) or_return

	local_x := x - e.view.x - e.mdv.col_x
	if !gfx.rect_contains(box, {local_x, local_y}) do return false

	toggle_wide_table(e, t)
	return true
}


// --- Cells -------------------------------------------------------------------------

// Items of a table line: cells on the table's columns (the delimiter row as a
// thin rule), or its source if it isn't in a table
@(private)
table_items :: proc(
	e: ^View,
	ib: ^Item_Builder,
	p: ^Params,
	i: int,
	text: string,
	start, content: int,
) {
	n := len(text)
	t := table_at(e, i)
	kind := e.md.lines[i].kind
	if t == nil {
		p.kind = .Code
		color: Color = kind == .Table_Delim ? .Marker : .Text
		add_item(ib, {lo = i32(content), hi = i32(n), kind = .Mono, color = color})
		return
	}

	p.table = t
	if kind == .Table_Delim {
		p.kind = .Thin
		p.thin_h = 1
		hide(ib, content, n)
		return
	}

	p.kind = .Table
	p.header = i == t.first
	p.cells = cell_items(e, ib, i, text, start, content, len(t.edges) - 1, p.header, true)
}


// Items of a table row's first `cols` cells, its pipes and the spaces around
// the cells hidden; a header row's text is bold. With `reveal`, a cell that a
// selection touches shows its inline syntax and its spaces (but the one after
// its opening pipe). Returns where a caret can be in each cell
@(private = "file")
cell_items :: proc(
	e: ^View,
	ib: ^Item_Builder,
	i: int,
	text: string,
	start, content, cols: int,
	header, reveal: bool,
) -> [][2]i32 {
	n := len(text)
	item_builder_bytes(ib, n)

	// Inline spans
	if b := block_at(e, i); b != nil {
		seg := b.bt.segs[0]
		for s in b.spans {
			span_lo := markdown.block_to_doc(&b.bt, int(s.lo))
			span_hi := markdown.block_to_doc(&b.bt, int(s.hi))
			touched := reveal && touches(e, span_lo, span_hi)
			line_off := seg.doc_lo - start - seg.lo
			apply_span(ib, s, line_off, seg.lo, seg.hi, touched, text)

			// A <br> tag breaks the cell's line, dimmed where a selection
			// touches it and otherwise hidden
			lo := clamp(int(s.lo), seg.lo, seg.hi) + line_off
			hi := clamp(int(s.hi), seg.lo, seg.hi) + line_off
			if s.kind != .Html || !is_line_break(text[lo:hi]) {
				continue
			}
			for k in lo ..< hi {
				ib.color[k] = .Marker
				ib.hidden[k] = !touched
			}
			ib.breaks[hi - 1] = true
		}
	}

	// The cells, with what is around them hidden
	cells := table_cells_of(text, content, cols)
	ranges := make([][2]i32, len(cells), context.temp_allocator)
	pos := content
	for c, k in cells {
		lo, hi := c.text_lo, c.text_hi
		if reveal && touches(e, start + c.lo, start + c.hi) {
			lo, hi = c.lo, c.hi

			// An empty cell shows the space after its pipe, where the caret is
			if lo == hi && lo > content && (text[lo - 1] == ' ' || text[lo - 1] == '\t') {
				lo -= 1
			}
		}

		hide(ib, pos, lo)
		if header {
			for &s in ib.style[lo:hi] do s += {.Strong}
		}
		ib.cell = i8(k)
		flush_bytes(ib, lo, hi)
		ranges[k] = {i32(lo), i32(hi)}
		pos = hi
	}
	hide(ib, pos, n)

	return ranges
}


// Whether an HTML tag is a line break: <br>, <br/> or <br />, in any case
@(private)
is_line_break :: proc(tag: string) -> bool {
	return strings.equal_fold(tag, "<br>") ||
	       strings.equal_fold(tag, "<br/>") ||
	       strings.equal_fold(tag, "<br />")
}


// The <br> tag of a line break in a table cell on line `line` that a caret at
// line byte k is after or in (dir = -1), or before or in (dir = 1)
@(private)
break_tag :: proc(e: ^View, line, k, dir: int) -> (lo, hi: int, ok: bool) {
	text, _ := line_text(e, line)
	MAX :: len("<br />")

	for lt in max(k - MAX, 0) ..= min(k, len(text) - 1) {
		if text[lt] != '<' do continue

		gt := strings.index_byte(text[lt:min(lt + MAX, len(text))], '>')
		if gt < 0 || !is_line_break(text[lt:lt + gt + 1]) {
			continue
		}

		lo, hi = lt, lt + gt + 1
		near := dir < 0 ? lo < k && k <= hi : lo <= k && k < hi
		if near && break_at(e, line, hi) {
			return lo, hi, true
		}
	}
	return 0, 0, false
}


// Whether a line break in a table cell follows byte k of line `line`
@(private = "file")
break_at :: proc(e: ^View, line, k: int) -> bool {
	L := line_layout(e, line)
	if L.kind != .Table do return false

	for run in L.runs {
		if run.lo == run.hi && int(run.lo) == k {
			return true
		}
	}
	return false
}


// A cell of a table row: where a caret can be in it (after the space following
// its opening pipe, up to its closing pipe) and where its text is
@(private)
Table_Cell :: struct {
	lo, hi:           int,
	text_lo, text_hi: int,
}


// The cells of a table row's text from its content start, at most `cols`
@(private)
table_cells_of :: proc(text: string, content, cols: int) -> []Table_Cell {
	cells := make([dynamic]Table_Cell, context.temp_allocator)
	for c, k in markdown.row_cells(text, content) {
		if k >= cols do break

		cell := Table_Cell{c[0], c[1], c[0], c[1]}
		if cell.lo < cell.hi && is_cell_pad(text[cell.lo]) {
			cell.lo += 1
		}
		for cell.text_lo < cell.text_hi && is_cell_pad(text[cell.text_lo]) {
			cell.text_lo += 1
		}
		for cell.text_hi > cell.text_lo && is_cell_pad(text[cell.text_hi - 1]) {
			cell.text_hi -= 1
		}
		append(&cells, cell)
	}
	return cells[:]
}


@(private = "file")
is_cell_pad :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}


// The cells of line `line` if it is the header or a body row of a rendered
// table, and the line's start
@(private)
md_row_cells :: proc(e: ^View, line: int) -> (cells: []Table_Cell, start: int, ok: bool) {
	if line < 0 || line >= len(e.md.lines) || e.md.lines[line].kind == .Table_Delim {
		return
	}

	begin_caches(e)
	t := table_at(e, line)
	if t == nil do return

	text: string
	text, start = line_text(e, line)
	content := int(markdown.line_detail(e.md, line, text).content[0])
	cells = table_cells_of(text, content, len(t.edges) - 1)
	return cells, start, len(cells) > 0
}


// The cell of `cells` a caret at line byte `at` is in, or the nearest one
@(private)
cell_index :: proc(cells: []Table_Cell, at: int) -> int {
	for c, k in cells {
		if at <= c.hi do return k
	}
	return len(cells) - 1
}


// The text of the rendered table cell at (or nearest) `offset`, if its line is
// a table's header or body row
@(private)
cell_text_at :: proc(e: ^View, offset: int) -> (lo, hi: int, ok: bool) {
	cells, start := md_row_cells(e, buffer.offset_to_line(&e.buf, offset)) or_return
	c := cells[cell_index(cells, offset - start)]
	return start + c.text_lo, start + c.text_hi, true
}


// --- Editing -----------------------------------------------------------------------

// Moves carets that are in a rendered table's syntax (a pipe, the space after
// one, the delimiter row) to the nearest place in a cell, where what is typed
// is drawn
@(private)
snap_carets :: proc(e: ^View) {
	textedit.take_changes(e)

	// Parse up to the last caret
	last := 0
	for s in e.sels do last = max(last, s.head)
	last_line := buffer.offset_to_line(&e.buf, last)
	markdown.doc_update(e.md, &e.buf, last_line + markdown.LOOKAHEAD_LINES, 0)

	for &s in e.sels {
		if s.anchor != s.head do continue

		line := buffer.offset_to_line(&e.buf, s.head)
		kind := e.md.lines[line].kind
		if kind != .Table_Row && kind != .Table_Delim && !markdown.is_table_header(e.md, line) {
			continue
		}

		at := s.head
		if kind == .Table_Delim {
			// The end of the header's last cell
			if cells, start, ok := md_row_cells(e, line - 1); ok {
				at = start + cells[len(cells) - 1].text_hi
			}
		} else if cells, start, ok := md_row_cells(e, line); ok {
			k := cell_index(cells, s.head - start)
			c := cells[k]
			at = start + clamp(s.head - start, c.lo, c.hi)

			// Between two cells, the nearer one
			head := s.head - start
			if k > 0 && head < c.lo && head - cells[k - 1].hi < c.lo - head {
				at = start + cells[k - 1].hi
			}
		}
		if at != s.head do s = {at, at, s.col}
	}
}


// The selections of a mouse drag from `origin` to `offset` that started in a
// table cell and is now in another cell of the table: every cell of the
// rectangle between the two, a selection per row. Returns false (leaving the
// selections to the caller) when the drag is within one cell or has left the
// table; a rectangle selected before is then replaced by one selection
@(private)
cell_drag :: proc(e: ^View, origin: Selection, offset: int) -> bool {
	mv := &e.mdv
	if (len(e.sels) == 1 || mv.cell_drag) && cell_rectangle(e, origin, offset) {
		mv.cell_drag = true
		return true
	}
	if !mv.cell_drag do return false

	mv.cell_drag = false
	textedit.set_single_selection(e, {origin.anchor, offset, -1})
	return true
}


// Selects the rectangle of cells from the drag's origin to `offset`, if both
// are in one table and not in the same cell
@(private = "file")
cell_rectangle :: proc(e: ^View, origin: Selection, offset: int) -> bool {
	begin_caches(e)
	from := buffer.offset_to_line(&e.buf, origin.anchor)
	to := buffer.offset_to_line(&e.buf, offset)
	t := table_at(e, from)
	if t == nil || table_at(e, to) != t {
		return false
	}

	// The delimiter row counts as the header's
	if e.md.lines[to].kind == .Table_Delim do to -= 1

	// The cells at the two ends
	a_cells, a_start := md_row_cells(e, from) or_return
	h_cells, h_start := md_row_cells(e, to) or_return
	ca := cell_index(a_cells, origin.anchor - a_start)
	ch := cell_index(h_cells, offset - h_start)
	if from == to && ca == ch {
		return false
	}

	// A selection per row, from the first column to the last
	clear(&e.sels)
	c0, c1 := min(ca, ch), max(ca, ch)
	for line in min(from, to) ..= max(from, to) {
		cells, start := md_row_cells(e, line) or_continue
		if c0 >= len(cells) do continue

		lo := start + cells[c0].lo
		hi := start + cells[min(c1, len(cells) - 1)].hi
		append(&e.sels, ch < ca ? Selection{hi, lo, -1} : Selection{lo, hi, -1})
		if line == to do e.primary = len(e.sels) - 1
	}
	return true
}


// Replaces the selections with `text`, keeping the cells of table rows: where
// a selection spans cells of a row, the text of the cells it covers goes
// (their pipes stay) and `text` goes where it starts. Returns false, doing
// nothing, if no selection spans cells
@(private)
replace_cells :: proc(e: ^View, text: string, kind: buffer.Edit_Kind) -> bool {
	Plan :: struct {
		lo, hi, caret: int,
		insert:        string,
	}

	textedit.take_changes(e)

	// Parse up to the last selection
	last := 0
	for s in e.sels do last = max(last, textedit.sel_hi(s))
	last_line := buffer.offset_to_line(&e.buf, last)
	markdown.doc_update(e.md, &e.buf, last_line + markdown.LOOKAHEAD_LINES, 0)

	// What replaces each selection
	plans := make([]Plan, len(e.sels), context.temp_allocator)
	spans := false
	for s, i in e.sels {
		lo, hi := textedit.sel_lo(s), textedit.sel_hi(s)
		plans[i] = {lo, hi, len(text), text}
		line := buffer.offset_to_line(&e.buf, lo)
		if lo == hi || buffer.offset_to_line(&e.buf, hi) != line {
			continue
		}

		cells, start := md_row_cells(e, line) or_continue
		row, _ := line_text(e, line)
		c0, c1 := cell_index(cells, lo - start), cell_index(cells, hi - start)
		if c0 == c1 do continue

		// Across cells: the text before it in the first cell, `text`, a pipe
		// for each cell after, and the text after it in the last cell
		a := max(lo - start, cells[c0].lo)
		b := clamp(hi - start, cells[c1].lo, cells[c1].hi)
		sb := strings.builder_make(context.temp_allocator)
		prefix := row[cells[c0].lo:a]
		strings.write_string(&sb, prefix)
		strings.write_string(&sb, text)
		for _ in c0 + 1 ..= c1 {
			end_with_space(&sb)
			strings.write_string(&sb, "| ")
		}
		suffix := row[b:cells[c1].hi]
		if suffix == "" do end_with_space(&sb)
		strings.write_string(&sb, suffix)

		plans[i] = {
			start + cells[c0].lo,
			start + cells[c1].hi,
			len(prefix) + len(text),
			strings.to_string(sb),
		}
		spans = true
	}
	if !spans do return false

	// Nothing if any overlap
	for i in 1 ..< len(plans) {
		if plans[i].lo < plans[i - 1].hi do return false
	}

	// Apply them as one edit
	buffer.begin(&e.buf, kind, textedit.now(), e.sels[:])
	delta := 0
	for p, i in plans {
		buffer.replace(&e.buf, p.lo + delta, p.hi - p.lo, p.insert)
		caret := p.lo + delta + p.caret
		e.sels[i] = {caret, caret, -1}
		delta += len(p.insert) - (p.hi - p.lo)
	}
	textedit.normalize(e)
	buffer.end(&e.buf, e.sels[:])

	e.reveal = true
	return true
}


// Writes a space unless what is written ends with one
@(private = "file")
end_with_space :: proc(sb: ^strings.Builder) {
	s := strings.to_string(sb^)
	if s == "" || (s[len(s) - 1] != ' ' && s[len(s) - 1] != '\t') {
		strings.write_byte(sb, ' ')
	}
}


// --- Layout ------------------------------------------------------------------------

@(private)
layout_table :: proc(L: ^Line_Layout, text: string, items: []Item, p: ^Params) {
	t := p.table
	size := p.size
	lh := math.round(f32(size) * line_factor())
	m := gfx.font_metrics(&gfx.text_system, .Md_Regular, size)
	top := centered_baseline(m, lh)

	// Each cell's words, wrapped to its column
	lines := 1
	for c in 0 ..< len(t.edges) - 1 {
		x0 := t.x + t.edges[c] + CELL_PAD
		x1 := t.x + t.edges[c + 1] - CELL_PAD
		pieces := build_pieces(items, text, p, c)
		x := x0
		line := 0
		first_run := len(L.runs)
		i := 0
		for i < len(pieces) {
			// The word: pieces glued together
			j := i + 1
			for j < len(pieces) && pieces[j].glue {
				j += 1
			}
			word: f32
			for k in i ..< j {
				word += k == j - 1 ? pieces[k].w_word : pieces[k].w_full
			}

			// A new line at a break, or when it doesn't fit
			if pieces[i].brk || (x + word > x1 && x > x0) {
				align_cell(L, first_run, x - x0, x1 - x0, t.aligns[c])
				line += 1
				x = x0
				first_run = len(L.runs)
			}

			for k in i ..< j {
				pc := pieces[k]
				it := items[pc.item]
				font, fsize := prose_font(it.style, 0, size)
				run := Run{
					lo    = i32(pc.lo),
					hi    = i32(pc.hi),
					x     = x + pc.pad[0],
					w     = pc.w_full - pc.pad[0] - pc.pad[1],
					font  = font,
					size  = fsize,
					style = it.style,
					color = it.color,
					dy    = f32(line) * lh,
				}
				append(&L.runs, run)
				x += pc.w_full
			}
			i = j
		}
		align_cell(L, first_run, x - x0, x1 - x0, t.aligns[c])
		lines = max(lines, line + 1)
	}

	// One row as tall as the tallest cell
	h := f32(lines) * lh + 2 * CELL_VPAD
	append(&L.rows, Row{h = h, baseline = CELL_VPAD + top, runs = {0, i32(len(L.runs))}})
	L.height = h
	L.header = p.header
	L.cell_h = lh
	append(&L.cells, ..p.cells)
	for edge in t.edges do append(&L.edges, t.x + edge)
}


// Moves the runs of one line in a cell for the column's alignment
@(private = "file")
align_cell :: proc(L: ^Line_Layout, first: int, used, width: f32, align: u8) {
	shift: f32
	switch align {
	case 1: shift = math.round((width - used) / 2)
	case 2: shift = width - used
	}
	if shift <= 0 do return

	for &r in L.runs[first:] do r.x += shift
}


// Applies an inline span to the bytes of one line: its markers are hidden (or
// shown dimmed when touched by a selection), its content styled
@(private)
apply_span :: proc(
	ib: ^Item_Builder,
	s: markdown.Span,
	line_off, seg_lo, seg_hi: int,
	touched: bool,
	text: string,
) {
	n := len(ib.hidden)
	lo := span_to_line(s.lo, line_off, seg_lo, seg_hi, n)
	open_hi := span_to_line(s.open_hi, line_off, seg_lo, seg_hi, n)
	close_lo := span_to_line(s.close_lo, line_off, seg_lo, seg_hi, n)
	hi := span_to_line(s.hi, line_off, seg_lo, seg_hi, n)

	switch s.kind {
	case .Emph:      span_style(ib, open_hi, close_lo, {.Em})
	case .Strong:    span_style(ib, open_hi, close_lo, {.Strong})
	case .Strike:    span_style(ib, open_hi, close_lo, {.Strike})
	case .Highlight: span_style(ib, open_hi, close_lo, {.Mark})
	case .Code:      span_style(ib, open_hi, close_lo, {.Code})
	case .Math:
		span_style(ib, open_hi, close_lo, {.Code})
		span_color(ib, open_hi, close_lo, .Math)
	case .Html:
		span_color(ib, lo, hi, .Html)
		return
	case .Link, .Wikilink, .Image:
		span_style(ib, open_hi, close_lo, {.Underline})
		span_color(ib, open_hi, close_lo, .Link)
	case .Autolink, .Url:
		span_style(ib, open_hi, close_lo, {.Underline})
		span_color(ib, open_hi, close_lo, .Link)
	case .Footnote_Ref:
		span_style(ib, open_hi, close_lo, {.Super})
		span_color(ib, open_hi, close_lo, .Link)
	case .Escape, .Hard_Break:
	case .Entity:
		// Drawn decoded unless a selection touches it
		if !touched && open_hi > lo {
			buf, w, _ := entity.unescape_entity(text[lo:hi])
			if w > 0 {
				ib.subst[lo] = strings.clone(string(buf[:w]), context.temp_allocator)
				ib.subst_end[lo] = i32(hi)
				return
			}
		}
		return
	}

	span_marker(ib, lo, open_hi, touched)
	span_marker(ib, close_lo, hi, touched)
}


// A span position as a byte of the line
@(private = "file")
span_to_line :: proc(pos: i32, line_off, seg_lo, seg_hi, n: int) -> int {
	return clamp(clamp(int(pos), seg_lo, seg_hi) + line_off, 0, n)
}


// Hides a span's marker, or dims it when a selection touches it
@(private = "file")
span_marker :: proc(ib: ^Item_Builder, lo, hi: int, touched: bool) {
	for k in lo ..< hi {
		if touched {
			ib.color[k] = .Marker
		} else {
			ib.hidden[k] = true
		}
	}
}


@(private = "file")
span_style :: proc(ib: ^Item_Builder, lo, hi: int, st: Style) {
	for k in lo ..< hi do ib.style[k] += st
}


// Colors bytes that aren't markers
@(private = "file")
span_color :: proc(ib: ^Item_Builder, lo, hi: int, c: Color) {
	for k in lo ..< hi {
		if ib.color[k] != .Marker do ib.color[k] = c
	}
}
