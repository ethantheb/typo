package mdview

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../buffer"
import "../markdown"
import sdl "../../vendor/sdl3"
import "../textedit"

// List and quote editing in the rendered Markdown view; the text view edits like
// any other file. Enter continues a list item (or quote) on a new line, and on
// an empty item leaves the list (or outdents a nested one). Tab and Shift+Tab
// indent and outdent list items (not past the top level). Backspace at the
// start of an item's text (after deleting any extra spaces after the marker)
// removes its marker, the text going on as part of the item it was in, and in
// a list's indentation deletes a level. In a table, Tab and Shift+Tab move
// between cells and Enter to the row below (adding a row after the last one,
// and on an empty last row leaving the table), Shift+Enter breaks the cell's
// line (with a <br> tag, which Backspace and Delete remove whole), Backspace
// and Delete stop at a cell's edge, and a typed "|" is escaped.
// Editing keys while the caret is hidden show it first. Numbered lists are
// renumbered after these keys, Delete, cut and paste


// The innermost list item or quote marker of a line
@(private)
Prefix :: struct {
	quote:   bool,
	lo, hi:  int,    // the marker
	content: int,    // where the text starts, after a task box
	task:    bool,
	level:   int,    // the item's container depth
	keep:    string, // the line before the marker, outer list markers blanked
	gap:     string, // between the marker and the text (or task box)
}


@(private)
md_prefix :: proc(e: ^View, line: int) -> (p: Prefix, ok: bool) {
	#partial switch e.md.lines[line].kind {
	case .Paragraph, .Blank, .Atx_Heading:
	case: return
	}

	text, _ := textedit.line_text(e, line)
	d := markdown.line_detail(e.md, line, text)
	if d.n_marks == 0 do return

	// The marker, and where the text after it starts
	m := d.marks[d.n_marks - 1]
	p.lo, p.hi = int(m.lo), int(m.hi)
	p.quote = m.kind == .Quote
	p.content = int(d.content[0])
	gap_hi := p.content
	if d.task != {} {
		p.task = true
		gap_hi = int(d.task[0])
		p.content = min(int(d.task[1]) + 1, len(text))
	}
	p.gap = text[p.hi:max(gap_hi, p.hi)]
	if p.gap == "" && !p.quote {
		p.gap = " "
	}

	// What comes before the marker, outer list markers blanked
	keep := transmute([]u8)strings.clone(text[:p.lo], context.temp_allocator)
	for outer in d.marks[:d.n_marks - 1] {
		if outer.kind == .Quote do continue
		for k in outer.lo ..< outer.hi do keep[k] = ' '
	}
	p.keep = string(keep)

	p.level = int(m.container)
	return p, true
}


// --- Copying -----------------------------------------------------------------------

// A span with markers, in document offsets
@(private = "file")
Marked_Span :: struct {
	lo, open_hi, close_lo, hi: int,
	open, close:               string,
}


// What copying or cutting [lo, hi] in the rendered view takes, so it pastes
// with the formatting that was seen selected:
// - [from, to]: the selection grown over the markers of formatted text it
//   covers ("**bold**", not "bold"), and shrunk off markers selected without
//   any of their text.
// - before, after: markers to add when it is inside formatted text ("ol" in
//   "**bold**" copies as "**ol**").
// - Over several lines, starting at a line's text: from the line's start, with
//   its list, quote or heading marker
@(private)
copy_range :: proc(e: ^View, lo, hi: int) -> (from, to: int, before, after: string) {
	textedit.take_changes(e)
	first, last := buffer.offset_to_line(&e.buf, lo), buffer.offset_to_line(&e.buf, hi)
	markdown.doc_update(e.md, &e.buf, last + markdown.MAX_BLOCK_LINES, 0)
	begin_caches(e)

	// The spans with markers in the blocks at either end
	spans := make([dynamic]Marked_Span, context.temp_allocator)
	for line, i in ([2]int{first, last}) {
		b := block_at(e, line)
		if b == nil || (i == 1 && b.bt.first <= first) {
			continue
		}

		bt := &b.bt
		for s in b.spans {
			#partial switch s.kind {
			case .Url, .Html, .Entity, .Hard_Break: continue
			}

			span := Marked_Span{
				lo       = markdown.block_to_doc(bt, int(s.lo)),
				open_hi  = markdown.block_to_doc(bt, int(s.open_hi)),
				close_lo = markdown.block_to_doc(bt, int(s.close_lo)),
				hi       = markdown.block_to_doc(bt, int(s.hi)),
				open     = bt.text[s.lo:s.open_hi],
				close    = bt.text[s.close_lo:s.hi],
			}
			append(&spans, span)
		}
	}

	// An end only moves left over an opening marker or right over a closing one,
	// to another span's boundary, and spans nest, so each end moves at most once
	// per span
	from, to = lo, hi
	for _ in 0 ..= 2 * len(spans) {
		was := [2]int{from, to}
		for s in spans {
			switch {
			case from > s.lo && from <= s.open_hi && to > s.open_hi: from = s.lo
			case from >= s.close_lo && from < s.hi && to >= s.hi:    from = s.hi
			}
			switch {
			case to >= s.close_lo && to < s.hi && from < s.close_lo: to = s.hi
			case to > s.lo && to <= s.open_hi && from <= s.lo:       to = s.lo
			}
		}
		if was == {from, to} do break
	}
	if from >= to do return lo, hi, "", ""

	// The opening markers of the spans `from` is inside, and the closing
	// markers of those `to` is inside, in document order
	opens := make([dynamic]Marked_Span, context.temp_allocator)
	closes := make([dynamic]Marked_Span, context.temp_allocator)
	for s in spans {
		if s.open_hi < from && from < s.close_lo {
			append(&opens, s)
		}
		if s.open_hi < to && to < s.close_lo {
			append(&closes, s)
		}
	}
	slice.sort_by(opens[:], marked_by_open)
	slice.sort_by(closes[:], marked_by_close)

	sb := strings.builder_make(context.temp_allocator)
	for s in opens do strings.write_string(&sb, s.open)
	before = strings.to_string(sb)

	sb = strings.builder_make(context.temp_allocator)
	for s in closes do strings.write_string(&sb, s.close)
	after = strings.to_string(sb)

	return copy_line_start(e, from, to), to, before, after
}


@(private = "file")
marked_by_open :: proc(a, b: Marked_Span) -> bool {
	return a.lo < b.lo
}


@(private = "file")
marked_by_close :: proc(a, b: Marked_Span) -> bool {
	return a.close_lo < b.close_lo
}


// Grows the primary selection to what copying it takes (copy_range), so the
// highlight shows what will be copied. Called when the mouse button is released
@(private)
snap_selection :: proc(e: ^View) {
	if e.mdv.cell_drag do return

	s := &e.sels[e.primary]
	if s.anchor == s.head do return

	from, to, _, _ := copy_range(e, textedit.sel_lo(s^), textedit.sel_hi(s^))
	s^ = s.anchor < s.head ? {from, to, -1} : {to, from, -1}
	textedit.normalize(e)
}


// The start of lo's line if [lo, hi] spans lines and starts at or before the
// line's text (after its markers), else lo
@(private = "file")
copy_line_start :: proc(e: ^View, lo, hi: int) -> int {
	line := buffer.offset_to_line(&e.buf, lo)
	if buffer.offset_to_line(&e.buf, hi) == line || line >= len(e.md.lines) {
		return lo
	}

	// Where the line's text starts
	text, start := textedit.line_text(e, line)
	d := markdown.line_detail(e.md, line, text)
	content := int(d.content[0])
	if d.task != {} do content = min(int(d.task[1]) + 1, len(text))
	if e.md.lines[line].kind == .Atx_Heading do content = max(content, int(d.open[1]))

	return lo - start <= content ? start : lo
}


// --- Lists -------------------------------------------------------------------------

// The marker of the item after one: the same bullet, or the next number
@(private = "file")
next_marker :: proc(marker: string) -> string {
	last := marker[len(marker) - 1]
	if len(marker) > 1 && (last == '.' || last == ')') {
		if n, ok := strconv.parse_int(marker[:len(marker) - 1]); ok {
			return fmt.tprintf("%d%c", n + 1, last)
		}
	}
	return marker
}


// Brings the block structure up to date, for edits made since the last frame
// (an item moved by Tab takes the lines inside it, however far they go)
@(private = "file")
md_sync :: proc(e: ^View) {
	textedit.take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), 0)
}


// Appends the edits that move the list item on `line` a level in (dir = 1),
// under the item before it, or out (dir = -1), beside its parent, with the
// lines inside it (its text's other lines, nested items). Out at the top level
// (or of a quote) removes the item's marker instead. Returns the item's last
// line; ok = false if it can't move
@(private = "file")
move_item :: proc(
	e: ^View,
	line: int,
	p: Prefix,
	dir: int,
	edits: ^[dynamic]Line_Edit,
) -> (last: int, ok: bool) {
	text, start := textedit.line_text(e, line)
	tabs := list_uses_tabs(e, line)

	// The column the marker moves to
	target: int
	if dir > 0 {
		can_nest(e, line, p) or_return
		_, sibling := item_mark(e, line - 1, p.level) or_return
		target = int(sibling.col)

		// A tab stop at or past the sibling's text still nests under it
		if tabs {
			target = (target + textedit.TAB_WIDTH - 1) / textedit.TAB_WIDTH * textedit.TAB_WIDTH
		}
	} else {
		if outermost(e, line, p) {
			append(edits, Line_Edit{start + p.lo, p.content - p.lo, ""})
			return line, true
		}
		parent_line, parent := item_mark(e, line, p.level - 1) or_return
		parent_text, _ := textedit.line_text(e, parent_line)
		target = textedit.visual_col(parent_text, int(parent.lo))
	}

	// The item's lines move with it
	delta := target - textedit.visual_col(text, p.lo)
	last = item_end(e, line, p.level)
	for j in line ..= last {
		shift_indent(e, j, p.level, delta, tabs, edits)

		// A numbered item starts the list it moves into at 1 (renumbering
		// follows the list)
		if j == line && dir > 0 && p.hi - p.lo > 1 {
			append(edits, Line_Edit{start + p.lo, p.hi - 1 - p.lo, "1"})
		}
	}
	return last, true
}


// Whether an item (or quote marker) is in no list item: at the top level or
// directly in a quote
@(private = "file")
outermost :: proc(e: ^View, line: int, p: Prefix) -> bool {
	state := markdown.line_state(e.md, line)
	return p.quote ||
	       p.level == 0 ||
	       int(state.depth) < p.level ||
	       state.containers[p.level - 1].kind == .Quote
}


// The nearest line at or above `from` with a list item at container level k,
// and its marker; ok = false if an item further out comes first
@(private = "file")
item_mark :: proc(e: ^View, from, k: int) -> (line: int, m: markdown.Mark, ok: bool) {
	for j := from; j >= 0; j -= 1 {
		text, _ := textedit.line_text(e, j)
		d := markdown.line_detail(e.md, j, text)
		#reverse for mark in d.marks[:d.n_marks] {
			if mark.kind == .Quote do continue
			if int(mark.container) == k do return j, mark, true
			if int(mark.container) < k do return
		}
		if int(markdown.line_state(e.md, j).depth) <= k do return
	}
	return
}


// The last non-blank line of the list item on `line` at container level k
@(private = "file")
item_end :: proc(e: ^View, line, k: int) -> int {
	last := line
	for j := line + 1; j < len(e.md.lines); j += 1 {
		if int(markdown.line_state(e.md, j).depth) <= k do break

		text, _ := textedit.line_text(e, j)
		d := markdown.line_detail(e.md, j, text)
		for m in d.marks[:d.n_marks] {
			// The next item at this level or further out
			if int(m.container) == k || (int(m.container) < k && m.kind != .Quote) {
				return last
			}
		}
		if strings.trim_space(text) != "" do last = j
	}
	return last
}


// Whether the items of the list around `line` are indented with tabs
@(private = "file")
list_uses_tabs :: proc(e: ^View, line: int) -> bool {
	// The list's lines
	first, last := line, line
	for first > 0 && markdown.line_state(e.md, first - 1).depth > 0 {
		first -= 1
	}
	for last + 1 < len(e.md.lines) && markdown.line_state(e.md, last).depth > 0 {
		last += 1
	}

	// A tab in the indentation before an item's marker
	for j in first ..= last {
		if .Item_Start not_in e.md.lines[j].flags do continue

		text, _ := textedit.line_text(e, j)
		d := markdown.line_detail(e.md, j, text)
		for m in d.marks[:d.n_marks] {
			if m.kind == .Quote do continue
			for b := int(m.lo) - 1; b >= 0 && (text[b] == ' ' || text[b] == '\t'); b -= 1 {
				if text[b] == '\t' do return true
			}
		}
	}
	return false
}


// Appends the edit that moves line j's text `delta` columns, at most back to
// where the containers outside level k start their content, its indentation
// rewritten with tabs or spaces. Blank lines are left as they are
@(private = "file")
shift_indent :: proc(e: ^View, j, k, delta: int, tabs: bool, edits: ^[dynamic]Line_Edit) {
	text, start := textedit.line_text(e, j)
	if strings.trim_space(text) == "" do return

	// The indentation, after the markers of the containers outside level k
	d := markdown.line_detail(e.md, j, text)
	lo, min_col := 0, 0
	for m in d.marks[:d.n_marks] {
		if int(m.container) < k {
			lo, min_col = int(m.hi), int(m.col)
		}
	}
	hi := lo
	for hi < len(text) && (text[hi] == ' ' || text[hi] == '\t') {
		hi += 1
	}

	// Rewritten to end `delta` columns away
	from := textedit.visual_col(text, lo)
	to := max(textedit.visual_col(text, hi) + delta, min_col)
	ws := indentation(from, to, tabs)
	if ws != text[lo:hi] do append(edits, Line_Edit{start + lo, hi - lo, ws})
}


// Whitespace from column `from` to column `to`, in tabs as far as they reach
// if `tabs`, then spaces
@(private = "file")
indentation :: proc(from, to: int, tabs: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	col := from
	for tabs && (col / textedit.TAB_WIDTH + 1) * textedit.TAB_WIDTH <= to {
		strings.write_byte(&sb, '\t')
		col = (col / textedit.TAB_WIDTH + 1) * textedit.TAB_WIDTH
	}
	for ; col < to; col += 1 {
		strings.write_byte(&sb, ' ')
	}
	return strings.to_string(sb)
}


// Whether a line is in code, where indentation is text
@(private = "file")
in_code :: proc(e: ^View, line: int) -> bool {
	kind := e.md.lines[line].kind
	return code_group(kind) != .None ||
	       kind == .Html ||
	       markdown.line_state(e.md, line).leaf == .Indented_Code
}


// --- Keys --------------------------------------------------------------------------

// The first step of a key in the rendered view, before caret movement: while the
// caret is hidden, keys scroll, show the caret or do nothing. Returns done when
// the key needs no further handling, and then whether it was handled
@(private)
begin_key :: proc(e: ^View, key: sdl.KeyboardEvent) -> (done, handled: bool) {
	if !e.mdv.caretless do return false, false

	switch key.key {
	case sdl.K_BACKSPACE, sdl.K_DELETE, sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_TAB:
		show_caret(e)
	case:
		return true, caretless_key(e, key)
	}
	return false, false
}


// Editing keys in the rendered view, after caret movement (see begin_key).
// Returns true if the key was handled
@(private)
handle_key :: proc(e: ^View, key: sdl.KeyboardEvent) -> bool {
	if table_key(e, key) do return true

	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	version := e.buf.version

	switch key.key {
	case sdl.K_BACKSPACE:
		if replace_cells(e, "", .Other) || delete_break(e, -1) || at_cell_edge(e, -1) {
			break
		}
		if ctrl || !backspace(e) {
			textedit.delete_text(e, -1, ctrl)
		}

	case sdl.K_DELETE:
		if replace_cells(e, "", .Other) || delete_break(e, +1) || at_cell_edge(e, +1) {
			break
		}
		textedit.delete_text(e, +1, ctrl)

	case sdl.K_RETURN, sdl.K_KP_ENTER:
		insert_newline(e)

	case sdl.K_TAB:
		if !md_indent(e, shift ? -1 : 1) && !shift {
			textedit.insert(e, "\t", .Other)
		}

	case:
		return false
	}

	if e.buf.version != version do renumber(e)
	return true
}


// Tab, Shift+Tab and Enter with one caret in a rendered table: to the next
// cell, the previous one, or the one below, adding a row after the last row
// and cells to a row short of them. Enter on an empty last row leaves the
// table, the row becoming an empty line. Shift+Enter with every selection in
// a table row puts a line break (<br>) in place of each. Returns false
// elsewhere
@(private = "file")
table_key :: proc(e: ^View, key: sdl.KeyboardEvent) -> bool {
	tab := key.key == sdl.K_TAB
	if !tab && key.key != sdl.K_RETURN && key.key != sdl.K_KP_ENTER {
		return false
	}
	if key.mod & (sdl.KMOD_CTRL | sdl.KMOD_ALT) != {} do return false

	md_sync(e)

	// Shift+Enter: line breaks
	if !tab && key.mod & sdl.KMOD_SHIFT != {} {
		for s in e.sels {
			line := buffer.offset_to_line(&e.buf, textedit.sel_lo(s))
			if buffer.offset_to_line(&e.buf, textedit.sel_hi(s)) != line do return false
			md_row_cells(e, line) or_return
		}
		if !replace_cells(e, "<br>", .Other) do textedit.insert(e, "<br>", .Other)
		return true
	}

	// The caret's cell
	if len(e.sels) != 1 || e.sels[0].anchor != e.sels[0].head {
		return false
	}
	head := e.sels[0].head
	line := buffer.offset_to_line(&e.buf, head)
	cells, start := md_row_cells(e, line) or_return
	t := table_at(e, line)
	cols := len(t.edges) - 1
	col := cell_index(cells, head - start)

	// The cell to go to
	switch {
	case tab && key.mod & sdl.KMOD_SHIFT != {}:
		switch {
		case col > 0:        col -= 1
		case line > t.first: line, col = table_step(t, line, -1), cols - 1
		}

	case tab:
		if col + 1 < cols {
			col += 1
		} else {
			line, col = table_step(t, line, 1), 0
		}

	case:
		// Leaving the table from an empty last row
		if line == t.last && line > t.first + 1 && row_empty(cells) {
			text, _ := line_text(e, line)
			content := int(markdown.line_detail(e.md, line, text).content[0])
			apply_line_edits(e, {{start + content, len(text) - content, ""}})
			return true
		}
		line = table_step(t, line, 1)
	}

	go_to_cell(e, t, line, col)
	return true
}


// The row after (or before) one, past the delimiter row
@(private = "file")
table_step :: proc(t: ^Table, line, dir: int) -> int {
	next := line + dir
	return next == t.first + 1 ? next + dir : next
}


@(private = "file")
row_empty :: proc(cells: []Table_Cell) -> bool {
	for c in cells {
		if c.text_hi > c.text_lo do return false
	}
	return true
}


// Puts the caret at the end of the text of cell `col` of table row `line`,
// adding the row (after the last) or the cell if it doesn't exist yet
@(private = "file")
go_to_cell :: proc(e: ^View, t: ^Table, line, col: int) {
	cols := len(t.edges) - 1

	// A new row, with its pipes where the header has them
	if line > t.last {
		header, _ := line_text(e, t.first)
		header_content := int(markdown.line_detail(e.md, t.first, header).content[0])
		h := strings.trim_space(header[header_content:])
		text, start := line_text(e, t.last)
		prefix := text[:int(markdown.line_detail(e.md, t.last, text).content[0])]

		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, buffer.newline(&e.buf))
		strings.write_string(&sb, prefix)
		if strings.has_prefix(h, "|") do strings.write_byte(&sb, '|')
		for k in 0 ..< cols {
			if k > 0 do strings.write_byte(&sb, '|')
			strings.write_string(&sb, "  ")
		}
		if strings.has_suffix(h, "|") do strings.write_byte(&sb, '|')

		apply_line_edits(e, {{start + len(text), 0, strings.to_string(sb)}})
		md_sync(e)
	}

	cells, start, ok := md_row_cells(e, line)
	if !ok do return

	// Cells added to a row short of them
	if col >= len(cells) {
		text, _ := line_text(e, line)
		end := len(strings.trim_right_space(text))
		sb := strings.builder_make(context.temp_allocator)
		if text[end - 1] != '|' do strings.write_string(&sb, " |")
		for _ in len(cells) ..= col do strings.write_string(&sb, "  |")

		apply_line_edits(e, {{start + end, len(text) - end, strings.to_string(sb)}})
		md_sync(e)
		cells, start, ok = md_row_cells(e, line)
		if !ok do return
	}

	at := start + cells[min(col, len(cells) - 1)].text_hi
	textedit.set_single_selection(e, {at, at, -1})
	e.reveal = true
}


// Whether a caret is at the start (dir = -1) or end (dir = 1) of a table cell,
// where Backspace or Delete would join it with the next
@(private = "file")
at_cell_edge :: proc(e: ^View, dir: int) -> bool {
	md_sync(e)

	for s in e.sels {
		if s.anchor != s.head do continue

		cells, start := md_row_cells(e, buffer.offset_to_line(&e.buf, s.head)) or_continue
		c := cells[cell_index(cells, s.head - start)]
		edge := dir < 0 ? c.lo : c.hi
		if s.head - start == edge do return true
	}
	return false
}


// Backspace (dir = -1) or Delete (dir = 1) with every caret just after (or
// before) a line break in a table cell: removes the <br> tags. Returns false,
// doing nothing, otherwise
@(private = "file")
delete_break :: proc(e: ^View, dir: int) -> bool {
	md_sync(e)

	ranges := make([][2]int, len(e.sels), context.temp_allocator)
	for s, i in e.sels {
		if s.anchor != s.head do return false

		line := buffer.offset_to_line(&e.buf, s.head)
		start := buffer.line_start(&e.buf, line)
		lo, hi := break_tag(e, line, s.head - start, dir) or_return
		edge := dir < 0 ? hi : lo
		if s.head - start != edge do return false

		ranges[i] = {start + lo, start + hi}
	}

	textedit.apply(e, .Other, ranges, {""})
	return true
}


// Text typed in the rendered view: a "|" in a table cell is escaped, so it
// doesn't start a new cell
@(private)
typed_text :: proc(e: ^View, text: string) -> string {
	if strings.index_byte(text, '|') < 0 do return text

	md_sync(e)
	for s in e.sels {
		line := buffer.offset_to_line(&e.buf, s.head)
		if _, _, ok := md_row_cells(e, line); ok {
			escaped, _ := strings.replace_all(text, "|", "\\|", context.temp_allocator)
			return escaped
		}
	}
	return text
}


// After `typed` was inserted: when it completed an opening fence ("```" or
// "~~~" with the caret after it) whose code block runs to the end of its
// container or leaves one open at the end of the document, adds the closing
// fence on the line below, so the new block doesn't take in the text after it.
// The caret stays after the opening fence, for an info string
@(private)
close_fence :: proc(e: ^View, typed: string) {
	if typed != "`" && typed != "~" {
		return
	}
	if len(e.sels) != 1 || e.sels[0].anchor != e.sels[0].head {
		return
	}

	md_sync(e)

	// The caret right after an opening fence of three
	caret := e.sels[0].head
	line := buffer.offset_to_line(&e.buf, caret)
	if e.md.lines[line].kind != .Fence_Open do return

	text, start := textedit.line_text(e, line)
	open := int(markdown.line_detail(e.md, line, text).open[0])
	fence := strings.repeat(typed, 3, context.temp_allocator)
	if caret - start != open + 3 || strings.trim_right_space(text[open:]) != fence {
		return
	}

	// Its block runs to the end of its container, or to a closing fence that
	// leaves a fence open at the end of the document
	n := len(e.md.lines)
	j := line + 1
	for j < n && e.md.lines[j].kind == .Fence_Body {
		j += 1
	}
	closed := j < n && e.md.lines[j].kind == .Fence_Close
	if closed && markdown.line_state(e.md, n - 1).leaf != .Fence {
		return
	}

	// The closing line keeps quote markers and blanks list markers
	prefix := transmute([]u8)strings.clone(text[:open], context.temp_allocator)
	for &c in prefix {
		if c != '>' && c != ' ' && c != '\t' {
			c = ' '
		}
	}
	newline := buffer.newline(&e.buf)
	insert := strings.concatenate({newline, string(prefix), fence}, context.temp_allocator)

	// Part of the typing's undo step
	if !buffer.amend(&e.buf) {
		buffer.begin(&e.buf, .Other, textedit.now(), e.sels[:])
	}
	buffer.replace(&e.buf, start + len(text), 0, insert)
	buffer.end(&e.buf, e.sels[:])
}


// --- Numbered lists ----------------------------------------------------------------

// Numbers the items of the ordered lists on and next to the selected lines in
// sequence from each list's first number, as part of the last undo step. A
// number with a caret in it or after it is being edited and is left as it is
@(private)
renumber :: proc(e: ^View) {
	textedit.take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), 0)

	edits := make([dynamic]Line_Edit, context.temp_allocator)
	done := make(map[[2]int]bool, context.temp_allocator) // lists, by first item and level
	n := len(e.md.lines)
	for s in e.sels {
		first := max(buffer.offset_to_line(&e.buf, textedit.sel_lo(s)) - 1, 0)
		last := min(buffer.offset_to_line(&e.buf, textedit.sel_hi(s)) + 1, n - 1)
		for line in first ..= last {
			text, _ := textedit.line_text(e, line)
			d := markdown.line_detail(e.md, line, text)
			for m in d.marks[:d.n_marks] {
				if m.kind != .Ordered do continue

				// Each list once
				items := list_items(e, line, int(m.container))
				key := [2]int{items[0].line, int(m.container)}
				if key in done do continue
				done[key] = true

				start, _ := strconv.parse_int(items[0].number)
				for it, k in items {
					want := fmt.tprint(start + k)
					if it.number != want && !caret_in(e, it.pos, it.pos + len(it.number)) {
						append(&edits, Line_Edit{it.pos, len(it.number), want})
					}
				}
			}
		}
	}
	if len(edits) == 0 do return

	slice.sort_by(edits[:], line_edit_before)
	apply_line_edits(e, edits[:], join = true)
}


@(private = "file")
line_edit_before :: proc(a, b: Line_Edit) -> bool {
	return a.pos < b.pos
}


@(private = "file")
caret_in :: proc(e: ^View, lo, hi: int) -> bool {
	for s in e.sels {
		if s.head > lo && s.head <= hi {
			return true
		}
	}
	return false
}


@(private = "file")
List_Item :: struct {
	line:   int,
	pos:    int, // document offset of its number
	number: string,
}


// The items of the ordered list that has an item at container level k on `line`
@(private = "file")
list_items :: proc(e: ^View, line, k: int) -> []List_Item {
	items := make([dynamic]List_Item, context.temp_allocator)
	it, delim, _, first := list_item_at(e, line, k)

	// The items before it
	for i := line - 1; i >= 0 && !first && list_open(e, i, k, delim); i -= 1 {
		prev, d, ok, outer := list_item_at(e, i, k)
		if ok && d == delim {
			append(&items, prev)
		}
		if outer do break
	}
	slice.reverse(items[:])
	append(&items, it)

	// The items after it
	for i := line + 1; i < len(e.md.lines) && list_open(e, i, k, delim); i += 1 {
		next, d, ok, outer := list_item_at(e, i, k)
		if outer do break
		if ok && d == delim {
			append(&items, next)
		}
	}

	return items[:]
}


// The line's item at level k, and whether it starts an item further out
// (which ends a list at level k)
@(private = "file")
list_item_at :: proc(e: ^View, line, k: int) -> (it: List_Item, delim: u8, ok, outer: bool) {
	text, start := textedit.line_text(e, line)
	d := markdown.line_detail(e.md, line, text)
	for m in d.marks[:d.n_marks] {
		if int(m.container) < k && m.kind != .Quote {
			outer = true
		}
		if int(m.container) == k && m.kind == .Ordered {
			it = {line, start + int(m.lo), text[m.lo:m.hi - 1]}
			delim = text[m.hi - 1]
			ok = true
		}
	}
	return
}


// Whether the list is still open at the end of a line
@(private = "file")
list_open :: proc(e: ^View, line, k: int, delim: u8) -> bool {
	st := markdown.line_state(e.md, line)
	return int(st.depth) > k &&
	       st.containers[k].kind == .Ordered &&
	       st.containers[k].marker == delim
}


// --- Enter, Tab and Backspace ------------------------------------------------------

// Enter. In a list item or quote's text it continues it; elsewhere the new
// line keeps only the indentation that places it in the same block
@(private)
insert_newline :: proc(e: ^View) {
	md_sync(e)

	ranges := textedit.selection_ranges(e)
	texts := make([]string, len(e.sels), context.temp_allocator)
	nl := buffer.newline(&e.buf)
	for s, i in e.sels {
		line := buffer.offset_to_line(&e.buf, textedit.sel_lo(s))
		text, start := textedit.line_text(e, line)

		// Not in an item's text: the indentation that keeps the block
		p, ok := md_prefix(e, line)
		if !ok || textedit.sel_lo(s) - start < p.content {
			indent := text[:block_indent(e, line, text)]
			texts[i] = strings.concatenate({nl, indent}, context.temp_allocator)
			continue
		}

		// An empty item moves out a level, or ends the list (or quote)
		if s.anchor == s.head && strings.trim_space(text[p.content:]) == "" {
			moved := make([dynamic]Line_Edit, context.temp_allocator)
			move_item(e, line, p, -1, &moved)
			ed := Line_Edit{start + p.lo, p.content - p.lo, ""}
			if len(moved) > 0 && moved[0].pos <= start + len(text) {
				ed = moved[0]
			}
			ranges[i] = {ed.pos, start + len(text)}
			rest := text[ed.pos + ed.remove - start:]
			texts[i] = strings.concatenate({ed.insert, rest}, context.temp_allocator)
			continue
		}

		// The next item, or the quote going on
		marker := text[p.lo:p.hi]
		if !p.quote do marker = next_marker(marker)
		task := p.task ? "[ ] " : ""
		texts[i] = strings.concatenate({nl, p.keep, marker, p.gap, task}, context.temp_allocator)
	}

	textedit.apply(e, .Other, ranges, texts)
}


// Bytes of a line's indentation that a line after it keeps: all of it in code,
// otherwise as much as reaches the content of the list items it is in (more
// would make an indented code block)
@(private = "file")
block_indent :: proc(e: ^View, line: int, text: string) -> int {
	n := textedit.indent_len(text)
	if in_code(e, line) do return n

	// The column where the list items' content starts
	state := markdown.line_state(e.md, line)
	cols := 0
	for k in 0 ..< int(state.depth) {
		if state.containers[k].kind == .Quote do return n
		cols += int(state.containers[k].indent)
	}

	col := 0
	for b in 0 ..< n {
		col = textedit.next_col(col, rune(text[b]))
		if col > cols do return b
	}
	return n
}


// Tab (dir = 1) and Shift+Tab (dir = -1) on the list items the selections
// touch, each with the lines inside it. An item indents only under an item
// before it (a selection whose first item can't stays as it is) and outdents
// only out of another item. Returns false if they touch no items
@(private)
md_indent :: proc(e: ^View, dir: int) -> bool {
	md_sync(e)

	edits := make([dynamic]Line_Edit, context.temp_allocator)
	items := false
	moved := -1 // the last line moved so far
	for s in e.sels {
		last := buffer.offset_to_line(&e.buf, textedit.sel_hi(s))
		first_item := true
		lines: for line in buffer.offset_to_line(&e.buf, textedit.sel_lo(s)) ..= last {
			if line <= moved do continue

			p, is_item := md_prefix(e, line)
			if !is_item || p.quote {
				continue
			}
			items = true
			if dir < 0 && outermost(e, line, p) {
				continue
			}

			end, ok := move_item(e, line, p, dir, &edits)
			if !ok && dir > 0 && first_item {
				break lines
			}
			first_item = false
			if ok do moved = end
		}
	}

	if len(edits) > 0 {
		apply_line_edits(e, edits[:])
		return true
	}
	return items
}


// Whether an item has an item before it, at its level, to become a child of
@(private = "file")
can_nest :: proc(e: ^View, line: int, p: Prefix) -> bool {
	if line == 0 do return false

	state := markdown.line_state(e.md, line - 1)
	return int(state.depth) > p.level && state.containers[p.level].kind != .Quote
}


// Backspace with every caret at the start of a list item's (or quote's) text,
// or in the indentation of a line in a list. At an item's text it removes the
// marker (and task box): a nested item's text is indented to go on in the item
// it was in. In the indentation it deletes back to the previous item's content
// column. Returns false otherwise
@(private)
backspace :: proc(e: ^View) -> bool {
	md_sync(e)

	edits := make([dynamic]Line_Edit, context.temp_allocator)
	moved := -1 // the last line moved so far
	for s in e.sels {
		if s.anchor != s.head do return false

		line := buffer.offset_to_line(&e.buf, s.head)
		if line <= moved do continue

		text, start := textedit.line_text(e, line)
		at := s.head - start
		p, ok := md_prefix(e, line)

		// At the item's text: its marker goes. Spaces shown after the marker
		// are deleted first
		if ok && at == p.content && len(p.gap) <= 1 {
			if outermost(e, line, p) {
				append(&edits, Line_Edit{start + p.lo, p.content - p.lo, ""})
			} else {
				join_parent(e, line, p, &edits) or_return
			}
			moved = line
			continue
		}

		// In the indentation: back a level
		if at == 0 || textedit.indent_len(text) < at {
			return false
		}
		lo := indent_stop(e, line, text, at) or_return
		append(&edits, Line_Edit{start + lo, at - lo, ""})
	}

	apply_line_edits(e, edits[:])
	return true
}


// Appends the edit that replaces a nested item's marker (and the indentation
// before it) with indentation to the content of the item it is in
@(private = "file")
join_parent :: proc(e: ^View, line: int, p: Prefix, edits: ^[dynamic]Line_Edit) -> bool {
	_, parent := item_mark(e, line, p.level - 1) or_return
	text, start := textedit.line_text(e, line)
	d := markdown.line_detail(e.md, line, text)

	// After the markers of the containers outside the item
	lo := 0
	for m in d.marks[:d.n_marks] {
		if int(m.container) < p.level do lo = int(m.hi)
	}

	ws := indentation(textedit.visual_col(text, lo), int(parent.col), list_uses_tabs(e, line))
	append(edits, Line_Edit{start + lo, p.content - lo, ws})
	return true
}


// For a caret at byte `at` (> 0) in a line's indentation, under list items
// only: the byte where the indentation level it is in starts
@(private = "file")
indent_stop :: proc(e: ^View, line: int, text: string, at: int) -> (lo: int, ok: bool) {
	if line == 0 do return

	state := markdown.line_state(e.md, line - 1)
	if state.depth == 0 do return

	// The column of the content start before the caret's
	cols := textedit.visual_col(text, at)
	target := 0
	stop := 0
	for k in 0 ..< int(state.depth) {
		c := state.containers[k]
		if c.kind == .Quote do return
		stop += int(c.indent)
		if stop < cols do target = stop
	}

	// Its byte
	col := 0
	for b in 0 ..< at {
		if col > target do break
		lo = b
		col = textedit.next_col(col, rune(text[b]))
	}
	return lo, true
}


// --- Line edits --------------------------------------------------------------------

// A replacement of `remove` bytes at `pos`
@(private)
Line_Edit :: struct {
	pos:    int,
	remove: int,
	insert: string,
}


// Applies edits (sorted, not overlapping) as one undo step, or as part of the
// last one, keeping each selection on the same text
@(private = "file")
apply_line_edits :: proc(e: ^View, edits: []Line_Edit, join := false) {
	if !join || !buffer.amend(&e.buf) {
		buffer.begin(&e.buf, .Other, textedit.now(), e.sels[:])
	}
	#reverse for ed in edits do buffer.replace(&e.buf, ed.pos, ed.remove, ed.insert)
	for &s in e.sels do s = {moved_offset(s.anchor, edits), moved_offset(s.head, edits), -1}
	textedit.normalize(e)
	buffer.end(&e.buf, e.sels[:])

	e.reveal = true
}


// Where offset x is after the edits; inside a replaced range, the end of what
// replaced it
@(private = "file")
moved_offset :: proc(x: int, edits: []Line_Edit) -> int {
	d := 0
	for ed in edits {
		if x >= ed.pos + ed.remove {
			d += len(ed.insert) - ed.remove
		} else if x > ed.pos {
			return ed.pos + d + len(ed.insert)
		} else {
			break
		}
	}
	return x + d
}
