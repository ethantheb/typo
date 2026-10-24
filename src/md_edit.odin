package editor

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import "buffer"
import "markdown"
import sdl "../vendor/sdl3"

// List and quote editing in the rendered Markdown view; the text view edits like
// any other file. Enter continues a list item (or quote) on a new line, and on
// an empty item leaves the list (or outdents a nested one). Tab and Shift+Tab
// indent and outdent list items, the top level's Shift+Tab leaving the list.
// Backspace at the start of an item's text does the same as Shift+Tab (after
// deleting any extra spaces after the marker), and in a list's indentation
// deletes a level. Numbered lists these keys change are renumbered.

// The innermost list item or quote marker of a line.
Md_Prefix :: struct {
	ok:      bool,
	quote:   bool,
	lo, hi:  int,    // the marker
	ws_lo:   int,    // start of the indentation before it
	content: int,    // where the text starts, after a task box
	task:    bool,
	level:   int,    // the item's container depth
	indent:  int,    // spaces Tab adds: the marker's width and the gap after it
	outdent: int,    // bytes of indentation Shift+Tab removes; 0 at the top level
	keep:    string, // the line before the marker, outer list markers blanked
	gap:     string, // between the marker and the text (or task box)
}

md_prefix :: proc(e: ^Editor, line: int) -> (p: Md_Prefix) {
	#partial switch e.md.lines[line].kind {
	case .Paragraph, .Blank, .Atx_Heading:
	case: return
	}
	text, _ := line_text(e, line)
	d := markdown.line_detail(e.md, line, text)
	if d.n_marks == 0 do return
	m := d.marks[d.n_marks - 1]
	p.lo, p.hi = int(m.lo), int(m.hi)
	p.quote = m.kind == .Quote
	prev_hi := d.n_marks > 1 ? int(d.marks[d.n_marks - 2].hi) : 0
	p.ws_lo = p.lo
	for p.ws_lo > prev_hi && (text[p.ws_lo - 1] == ' ' || text[p.ws_lo - 1] == '\t') do p.ws_lo -= 1
	p.content = int(d.content[0])
	gap_hi := p.content
	if d.task != {} {
		p.task = true
		gap_hi = int(d.task[0])
		p.content = min(int(d.task[1]) + 1, len(text))
	}
	p.gap = text[p.hi:max(gap_hi, p.hi)]
	if p.gap == "" && !p.quote do p.gap = " "
	p.indent = p.hi - p.lo + len(p.gap)

	keep := transmute([]u8)strings.clone(text[:p.lo], context.temp_allocator)
	for outer in d.marks[:d.n_marks - 1] {
		if outer.kind != .Quote do for k in outer.lo ..< outer.hi do keep[k] = ' '
	}
	p.keep = string(keep)

	k := int(m.container)
	p.level = k
	state := markdown.line_state(e.md, line)
	if !p.quote && k > 0 && k <= int(state.depth) && state.containers[k - 1].kind != .Quote {
		p.outdent = min(p.lo - p.ws_lo, int(state.containers[k - 1].indent))
	}
	p.ok = true
	return
}

// The marker of the item after one: the same bullet, or the next number.
@(private = "file")
next_marker :: proc(marker: string) -> string {
	last := marker[len(marker) - 1]
	if len(marker) > 1 && (last == '.' || last == ')') {
		if n, ok := strconv.parse_int(marker[:len(marker) - 1]); ok do return fmt.tprintf("%d%c", n + 1, last)
	}
	return marker
}

// Brings the block structure up to date through the last selected line, for
// edits made since the last frame.
@(private = "file")
md_sync :: proc(e: ^Editor) {
	editor_take_changes(e)
	last := buffer.offset_to_line(&e.buf, sel_hi(e.sels[len(e.sels) - 1]))
	markdown.doc_update(e.md, &e.buf, last + 1, 0)
}

// The edit that moves an item out a level, or removes a top-level item's (or
// quote's) marker.
@(private = "file")
outdent_edit :: proc(start: int, p: Md_Prefix) -> Line_Edit {
	if p.outdent > 0 do return {start + p.ws_lo, p.outdent, ""}
	return {start + p.lo, p.content - p.lo, ""}
}

// Whether a line is in code, where indentation is text.
@(private = "file")
in_code :: proc(e: ^Editor, line: int) -> bool {
	kind := e.md.lines[line].kind
	return code_group(kind) != 0 || kind == .Html || markdown.line_state(e.md, line).leaf == .Indented_Code
}

// Keys in the rendered view. Returns true if the key was handled.
md_handle_key :: proc(e: ^Editor, key: sdl.KeyboardEvent) -> bool {
	if e.mdv.caretless do return md_caretless_key(e, key)
	if navigation_key(e, key) do return true
	ctrl := key.mod & sdl.KMOD_CTRL != {}
	shift := key.mod & sdl.KMOD_SHIFT != {}
	switch key.key {
	case sdl.K_BACKSPACE:
		if ctrl || !md_backspace(e) {
			editor_delete(e, -1, ctrl)
			return true
		}
	case sdl.K_DELETE:
		editor_delete(e, +1, ctrl)
		return true
	case sdl.K_RETURN, sdl.K_KP_ENTER: md_newline(e)
	case sdl.K_TAB:
		if !md_indent(e, shift ? -1 : 1) && !shift do editor_insert(e, "\t", .Other)
	case:
		return false
	}
	renumber(e)
	return true
}

// Numbers the items of the ordered lists on and next to the selected lines in
// sequence from each list's first number, as part of the last undo step.
@(private = "file")
renumber :: proc(e: ^Editor) {
	editor_take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), 0)
	edits := make([dynamic]Line_Edit, context.temp_allocator)
	done := make(map[[2]int]bool, context.temp_allocator) // lists, by first item and level
	n := len(e.md.lines)
	for s in e.sels {
		first := max(buffer.offset_to_line(&e.buf, sel_lo(s)) - 1, 0)
		last := min(buffer.offset_to_line(&e.buf, sel_hi(s)) + 1, n - 1)
		for line in first ..= last {
			text, _ := line_text(e, line)
			d := markdown.line_detail(e.md, line, text)
			for m in d.marks[:d.n_marks] {
				if m.kind != .Ordered do continue
				items := list_items(e, line, int(m.container))
				key := [2]int{items[0].line, int(m.container)}
				if key in done do continue
				done[key] = true
				start, _ := strconv.parse_int(items[0].number)
				for it, k in items {
					want := fmt.tprint(start + k)
					if it.number != want do append(&edits, Line_Edit{it.pos, len(it.number), want})
				}
			}
		}
	}
	if len(edits) == 0 do return
	slice.sort_by(edits[:], proc(a, b: Line_Edit) -> bool {return a.pos < b.pos})
	apply_line_edits(e, edits[:], join = true)
}

@(private = "file")
List_Item :: struct {
	line:   int,
	pos:    int,    // document offset of its number
	number: string,
}

// The items of the ordered list that has an item at container level k on `line`.
@(private = "file")
list_items :: proc(e: ^Editor, line, k: int) -> []List_Item {
	// The line's item at level k, and whether it starts an item further out
	// (which ends a list at level k).
	item_at :: proc(e: ^Editor, line, k: int) -> (it: List_Item, delim: u8, ok, outer: bool) {
		text, start := line_text(e, line)
		d := markdown.line_detail(e.md, line, text)
		for m in d.marks[:d.n_marks] {
			if int(m.container) < k && m.kind != .Quote do outer = true
			if int(m.container) == k && m.kind == .Ordered {
				it = {line, start + int(m.lo), text[m.lo:m.hi - 1]}
				delim, ok = text[m.hi - 1], true
			}
		}
		return
	}
	// Whether the list is still open at the end of a line.
	open :: proc(e: ^Editor, line, k: int, delim: u8) -> bool {
		st := markdown.line_state(e.md, line)
		return int(st.depth) > k && st.containers[k].kind == .Ordered && st.containers[k].marker == delim
	}
	items := make([dynamic]List_Item, context.temp_allocator)
	it, delim, _, first := item_at(e, line, k)
	for i := line - 1; i >= 0 && !first && open(e, i, k, delim); i -= 1 {
		prev, d, ok, outer := item_at(e, i, k)
		if ok && d == delim do append(&items, prev)
		if outer do break
	}
	slice.reverse(items[:])
	append(&items, it)
	for i := line + 1; i < len(e.md.lines) && open(e, i, k, delim); i += 1 {
		next, d, ok, outer := item_at(e, i, k)
		if outer do break
		if ok && d == delim do append(&items, next)
	}
	return items[:]
}

// Enter. In a list item or quote's text it continues it; elsewhere the new
// line keeps only the indentation that places it in the same block.
md_newline :: proc(e: ^Editor) {
	md_sync(e)
	ranges := selection_ranges(e)
	texts := make([]string, len(e.sels), context.temp_allocator)
	nl := buffer.newline(&e.buf)
	for s, i in e.sels {
		line := buffer.offset_to_line(&e.buf, sel_lo(s))
		text, start := line_text(e, line)
		p := md_prefix(e, line)
		if !p.ok || sel_lo(s) - start < p.content {
			texts[i] = strings.concatenate({nl, text[:block_indent(e, line, text)]}, context.temp_allocator)
			continue
		}
		if s.anchor == s.head && strings.trim_space(text[p.content:]) == "" {
			// An empty item moves out a level, or ends the list (or quote).
			ed := outdent_edit(start, p)
			ranges[i] = {ed.pos, start + len(text)}
			texts[i] = text[ed.pos + ed.remove - start:]
			continue
		}
		marker := text[p.lo:p.hi]
		if !p.quote do marker = next_marker(marker)
		texts[i] = strings.concatenate({nl, p.keep, marker, p.gap, p.task ? "[ ] " : ""}, context.temp_allocator)
	}
	apply(e, .Other, ranges, texts)
}

// Bytes of a line's indentation that a line after it keeps: all of it in code,
// otherwise as much as reaches the content of the list items it is in (more
// would make an indented code block).
@(private = "file")
block_indent :: proc(e: ^Editor, line: int, text: string) -> int {
	n := indent_len(text)
	if in_code(e, line) do return n
	state := markdown.line_state(e.md, line)
	cols := 0
	for k in 0 ..< int(state.depth) {
		if state.containers[k].kind == .Quote do return n
		cols += int(state.containers[k].indent)
	}
	col := 0
	for b in 0 ..< n {
		col = next_col(col, rune(text[b]))
		if col > cols do return b
	}
	return n
}

// Tab (dir = 1) and Shift+Tab (dir = -1) on the list items the selections
// touch. An item indents only under an item before it; a selection whose first
// item can't stays as it is. Returns false if they touch no items.
md_indent :: proc(e: ^Editor, dir: int) -> bool {
	md_sync(e)
	edits := make([dynamic]Line_Edit, context.temp_allocator)
	items := false
	last_line := -1
	for s in e.sels {
		first := max(buffer.offset_to_line(&e.buf, sel_lo(s)), last_line + 1)
		last := buffer.offset_to_line(&e.buf, sel_hi(s))
		first_item := true
		lines: for line in first ..= last {
			p := md_prefix(e, line)
			if !p.ok || p.quote do continue
			items = true
			start := buffer.line_start(&e.buf, line)
			nests := can_nest(e, line, p)
			if dir > 0 && !nests && first_item do break lines
			first_item = false
			switch {
			case dir < 0: append(&edits, outdent_edit(start, p))
			case nests:
				append(&edits, Line_Edit{start + p.ws_lo, 0, strings.repeat(" ", p.indent, context.temp_allocator)})
				// A numbered item starts the list it moves into at 1 (renumber
				// follows the list).
				if p.hi - p.lo > 1 do append(&edits, Line_Edit{start + p.lo, p.hi - 1 - p.lo, "1"})
			}
		}
		last_line = max(last_line, last)
	}
	if len(edits) > 0 {
		apply_line_edits(e, edits[:])
		return true
	}
	return items
}

// Whether an item has an item before it, at its level, to become a child of.
@(private = "file")
can_nest :: proc(e: ^Editor, line: int, p: Md_Prefix) -> bool {
	if line == 0 do return false
	state := markdown.line_state(e.md, line - 1)
	return int(state.depth) > p.level && state.containers[p.level].kind != .Quote
}

// Backspace with every caret at the start of a list item's (or quote's) text,
// or in the indentation of a line in a list. At an item's text it moves a
// nested item out a level and removes a top-level one's marker; in the
// indentation it deletes back to the previous item's content column. Returns
// false otherwise.
md_backspace :: proc(e: ^Editor) -> bool {
	md_sync(e)
	edits := make([dynamic]Line_Edit, context.temp_allocator)
	for s in e.sels {
		if s.anchor != s.head do return false
		line := buffer.offset_to_line(&e.buf, s.head)
		text, start := line_text(e, line)
		at := s.head - start
		p := md_prefix(e, line)
		// Spaces shown after the marker are deleted first.
		if p.ok && at == p.content && len(p.gap) <= 1 {
			append(&edits, outdent_edit(start, p))
			continue
		}
		if at == 0 || indent_len(text) < at do return false
		lo := indent_stop(e, line, text, at) or_return
		append(&edits, Line_Edit{start + lo, at - lo, ""})
	}
	apply_line_edits(e, edits[:])
	return true
}

// For a caret at byte `at` (> 0) in a line's indentation, under list items
// only: the byte where the indentation level it is in starts.
@(private = "file")
indent_stop :: proc(e: ^Editor, line: int, text: string, at: int) -> (lo: int, ok: bool) {
	if line == 0 do return
	state := markdown.line_state(e.md, line - 1)
	if state.depth == 0 do return
	cols := visual_col(text, at)
	target, stop := 0, 0
	for k in 0 ..< int(state.depth) {
		c := state.containers[k]
		if c.kind == .Quote do return
		stop += int(c.indent)
		if stop < cols do target = stop
	}
	col := 0
	for b in 0 ..< at {
		if col > target do break
		lo = b
		col = next_col(col, rune(text[b]))
	}
	return lo, true
}

// A replacement of `remove` bytes at `pos`.
Line_Edit :: struct {
	pos:    int,
	remove: int,
	insert: string,
}

// Applies edits (sorted, not overlapping) as one undo step, or as part of the
// last one, keeping each selection on the same text.
@(private = "file")
apply_line_edits :: proc(e: ^Editor, edits: []Line_Edit, join := false) {
	moved :: proc(x: int, edits: []Line_Edit) -> int {
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
	if !join || !buffer.amend(&e.buf) do buffer.begin(&e.buf, .Other, sdl.GetTicksNS(), e.sels[:])
	#reverse for ed in edits do buffer.replace(&e.buf, ed.pos, ed.remove, ed.insert)
	for &s in e.sels do s = {moved(s.anchor, edits), moved(s.head, edits), -1}
	normalize(e)
	buffer.end(&e.buf, e.sels[:])
	e.reveal = true
}
