package markdown

import "core:strings"
import "core:time"

import "../buffer"
import "../syntax"

// Block structure (CommonMark + GFM), parsed line by line. A line's info
// depends only on the state at the end of the previous line and its own text,
// so after an edit only the edited lines are reparsed, plus the lines after
// them until one ends in the same state as before. States are interned; lines
// store an id.
//
// Constructs that change how an earlier line reads are stored on the later line
// only: a setext underline (making the paragraph above a heading) and a table
// delimiter row (making the line above a header). Readers look ahead for them.

MAX_DEPTH :: 12
INVALID_STATE :: max(u32)
// Per-frame time for parsing beyond what the view needs.
PARSE_BUDGET :: 2 * time.Millisecond
// Lines parsed past the end of the view right away, so blocks that end below it
// (a table, a fence) are known.
LOOKAHEAD_LINES :: 256
// Bytes read from the buffer at a time while parsing.
@(private = "file")
PARSE_CHUNK :: 64 << 10
// The state pool is compacted when it grows past this many states.
@(private = "file")
POOL_COMPACT :: 1 << 16

Container_Kind :: enum u8 {
	Quote,
	Bullet,
	Ordered,
}

Container :: struct {
	kind:   Container_Kind,
	marker: u8, // the bullet, or '.' / ')' after an ordered item's number
	indent: u8, // columns from where the item's line starts (within its parent) to its content
}

Leaf :: enum u8 {
	None,
	Paragraph,
	Fence,
	Indented_Code,
	Html,
	Table,
	Front_Matter,
	Math,
}

// Parser state at the end of a line. Only u8-sized fields, so equal states have
// equal bytes (they are map keys).
State :: struct {
	containers:   [MAX_DEPTH]Container,
	depth:        u8,
	leaf:         Leaf, // the leaf block still open
	html_kind:    u8,   // CommonMark HTML block type 1-7
	fence_char:   u8,
	fence_len:    u8,
	fence_indent: u8,
	fence_lang:   syntax.Language,
	para_cells:   u8,   // table cells in the paragraph's last line, a header candidate
	para_refdefs: bool, // the paragraph so far holds only link reference definitions
	table_cols:   u8,
}

Line_Kind :: enum u8 {
	Blank,
	Paragraph,
	Atx_Heading,
	Setext_Underline,
	Thematic_Break,
	Fence_Open,
	Fence_Body,
	Fence_Close,
	Indented_Code,
	Html,
	Table_Delim,
	Table_Row,
	Front_Matter_Fence,
	Front_Matter_Body,
	Math_Fence,
	Math_Body,
	Link_Ref_Def,
	Footnote_Def,
}

Line_Flag :: enum u8 {
	Block_Start, // first line of a leaf block
	Lazy,        // paragraph continuation without its containers' markers
	Item_Start,  // a list item starts on this line
	Task,        // ... with a task box
	Task_Checked,
}

Line_Flags :: bit_set[Line_Flag;u8]

Line_Info :: struct {
	state: u32, // id in Doc.pool of the state at the end of the line
	len:   u32, // bytes, without the line ending
	kind:  Line_Kind,
	aux:   u8, // heading level; column count of a Table_Delim
	flags: Line_Flags,
	_:     u8,
}

Mark :: struct {
	kind:      Container_Kind,
	container: u8, // index in the line's container stack
	lo, hi:    i32,
}

// Byte ranges within one line, recomputed on demand by parse_line.
Line_Detail :: struct {
	marks:   [MAX_DEPTH]Mark, // quote and list item markers on this line
	n_marks: int,
	content: [2]i32, // after the container prefixes
	open:    [2]i32, // leaf syntax at the start: "## ", a fence line, a break or underline
	close:   [2]i32, // an ATX heading's closing #s, with the spaces before them
	info:    [2]i32, // a fence's info string
	task:    [2]i32, // "[ ]" or "[x]"
	label:   [2]i32, // a link reference or footnote definition's label, inside the brackets
	// Containers the line's own text continues or opens: fewer than its end
	// state's on a lazy line, or a blank one indented less than an item's content.
	reached: u8,
}

Doc :: struct {
	lines:      [dynamic]Line_Info,
	pool:       [dynamic]State,
	pool_ids:   map[State]u32,
	cursor:     int, // first line to (re)parse; len(lines) when up to date
	// Parsing can't stop before this line: earlier ones were edited, or their
	// stored info predates a reparse that was interrupted.
	must_until: int,
	version:    u64, // bumped when any line's info changes
	refdef_gen: u64, // bumped when a link reference or footnote definition line changes
	// Link reference labels, as of refdef generation labels_gen (see doc_labels).
	labels:       Labels,
	labels_gen:   u64,
	labels_built: bool,
}

doc_open :: proc(doc: ^Doc, b: ^buffer.Buffer) {
	doc_destroy(doc)
	resize(&doc.lines, buffer.line_count(b))
	for &l in doc.lines do l = {state = INVALID_STATE}
	append(&doc.pool, State{})
	doc.pool_ids[State{}] = 0
	doc.version += 1
}

doc_destroy :: proc(doc: ^Doc) {
	delete(doc.lines)
	delete(doc.pool)
	delete(doc.pool_ids)
	delete(doc.labels)
	doc^ = {}
}

doc_busy :: proc(doc: ^Doc) -> bool {
	return doc.cursor < len(doc.lines)
}

// Follows the buffer's edits (buffer.take_changes): lines are inserted and
// removed to match, and the edited ones are queued for doc_update.
doc_edit :: proc(doc: ^Doc, changes: []buffer.Change) {
	for c in changes {
		row := c.start.row
		removed := c.old_end.row - row
		inserted := c.new_end.row - row
		// The line after the edit was parsed after the old last edited line, so
		// the new last edited line keeps that line's info to compare against.
		last := doc.lines[c.old_end.row]
		if removed > 0 do remove_range(&doc.lines, row + 1, row + 1 + removed)
		if inserted > 0 do inject_at(&doc.lines, row + 1, ..make([]Line_Info, inserted, context.temp_allocator))
		for &l in doc.lines[row:c.new_end.row] do l = {state = INVALID_STATE}
		doc.lines[c.new_end.row] = last
		// A line index after the edit shifts with it; one inside the replaced
		// lines moves to the end of the new ones.
		shift :: proc(x: int, c: buffer.Change) -> int {
			if x > c.old_end.row do return x + (c.new_end.row - c.old_end.row)
			if x > c.start.row do return c.new_end.row + 1
			return x
		}
		doc.cursor = min(doc.cursor, row)
		doc.must_until = max(shift(doc.must_until, c), c.new_end.row + 1)
	}
}

// Parses queued lines: always through `need_line`, then until `budget` runs out.
doc_update :: proc(doc: ^Doc, b: ^buffer.Buffer, need_line: int, budget: time.Duration) {
	n := len(doc.lines)
	if doc.cursor >= n do return
	start := time.tick_now()
	i := doc.cursor
	prev, prev_id := State{}, u32(0)
	if i > 0 {
		prev_id = doc.lines[i - 1].state
		prev = doc.pool[prev_id]
	}
	pos := buffer.line_start(b, i)
	total := buffer.length(b)

	for i < n {
		hi := min(pos + PARSE_CHUNK, total)
		data := buffer.read_alloc(b, pos, hi)
		if hi < total {
			// Whole lines only; a line longer than the chunk is read in one piece.
			if nl := strings.last_index_byte(string(data), '\n'); nl >= 0 {
				data = data[:nl + 1]
			} else {
				hi = i + 1 < n ? buffer.line_start(b, i + 1) : total
				data = buffer.read_alloc(b, pos, hi)
			}
		}
		last_chunk := pos + len(data) >= total
		j := 0
		synced := false
		for i < n {
			nl := strings.index_byte(string(data[j:]), '\n')
			// Without a line feed, the rest is the last line or in the next chunk.
			if nl < 0 && !last_chunk do break
			end := nl < 0 ? len(data) : j + nl
			line := string(data[j:end])
			if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]

			info, _, s := parse_line(prev, line, i == 0)
			info.len = u32(len(line))
			id := s == prev ? prev_id : intern(doc, s)
			info.state = id
			old := doc.lines[i]
			if old != info {
				doc.version += 1
				if is_definition(old.kind) || is_definition(info.kind) do doc.refdef_gen += 1
			}
			doc.lines[i] = info
			synced = i + 1 >= doc.must_until && old.state != INVALID_STATE && int(old.state) < len(doc.pool) && doc.pool[old.state] == s
			prev, prev_id = s, id
			i += 1
			j = end + 1
			if synced do break
			if i > need_line && i % 32 == 0 && time.tick_since(start) > budget {
				// Lines from here on were parsed after a different line i-1.
				doc.cursor = i
				doc.must_until = max(doc.must_until, i + 1)
				return
			}
			if nl < 0 do break
		}
		if synced do break
		pos += len(data)
	}
	doc.cursor = n
	doc.must_until = 0
	compact_pool(doc)
}

// The state at the end of line i (the empty state for unparsed lines).
line_state :: proc(doc: ^Doc, i: int) -> State {
	if i < 0 || i >= len(doc.lines) do return {}
	id := doc.lines[i].state
	return id == INVALID_STATE ? {} : doc.pool[id]
}

// Byte ranges within line i, whose text is `text`.
line_detail :: proc(doc: ^Doc, i: int, text: string) -> Line_Detail {
	_, d, _ := parse_line(line_state(doc, i - 1), text, i == 0)
	return d
}

@(private = "file")
is_definition :: proc(k: Line_Kind) -> bool {
	return k == .Link_Ref_Def || k == .Footnote_Def
}

@(private = "file")
intern :: proc(doc: ^Doc, s: State) -> u32 {
	if id, ok := doc.pool_ids[s]; ok do return id
	id := u32(len(doc.pool))
	append(&doc.pool, s)
	doc.pool_ids[s] = id
	return id
}

// Drops states no line uses any more, once the pool is large.
@(private = "file")
compact_pool :: proc(doc: ^Doc) {
	if len(doc.pool) < POOL_COMPACT do return
	remap := make([]u32, len(doc.pool), context.temp_allocator)
	for &r in remap do r = INVALID_STATE
	remap[0] = 0
	kept := make([dynamic]State, 0, len(doc.pool) / 2)
	append(&kept, State{})
	clear(&doc.pool_ids)
	doc.pool_ids[State{}] = 0
	for &l in doc.lines {
		if l.state == INVALID_STATE do continue
		if remap[l.state] == INVALID_STATE {
			remap[l.state] = u32(len(kept))
			doc.pool_ids[doc.pool[l.state]] = u32(len(kept))
			append(&kept, doc.pool[l.state])
		}
		l.state = remap[l.state]
	}
	delete(doc.pool)
	doc.pool = kept
}

// --- Line classifier -------------------------------------------------------------

// Column-aware position in a line: tabs advance to the next multiple of 4, and
// a container can consume part of one.
@(private = "file")
Cursor :: struct {
	s:       string,
	pos:     int,
	col:     int,
	partial: int, // columns of the tab at pos not yet consumed, when it was partly consumed
}

// Columns of whitespace at the cursor.
@(private = "file")
indent_of :: proc(c: Cursor) -> int {
	col, partial := c.col, c.partial
	for p in c.pos ..< len(c.s) {
		switch c.s[p] {
		case ' ':  col += 1
		case '\t': col += partial > 0 ? partial : 4 - col % 4
		case:      return col - c.col
		}
		partial = 0
	}
	return col - c.col
}

// Byte position after the whitespace at the cursor.
@(private = "file")
after_indent :: proc(c: Cursor) -> int {
	p := c.pos
	for p < len(c.s) && (c.s[p] == ' ' || c.s[p] == '\t') do p += 1
	return p
}

@(private = "file")
consume_cols :: proc(c: ^Cursor, n: int) {
	n := n
	for n > 0 && c.pos < len(c.s) {
		switch c.s[c.pos] {
		case ' ':
			c.pos += 1
			c.col += 1
			n -= 1
		case '\t':
			w := c.partial > 0 ? c.partial : 4 - c.col % 4
			if w <= n {
				c.pos += 1
				c.col += w
				n -= w
				c.partial = 0
			} else {
				c.partial = w - n
				c.col += n
				n = 0
			}
		case:
			return
		}
	}
}

// Moves past one non-whitespace byte at p (after consuming the indent before it).
@(private = "file")
step_over :: proc(c: ^Cursor, p: int) {
	consume_cols(c, indent_of(c^))
	c.pos = p + 1
	c.col += 1
	c.partial = 0
}

@(private = "file")
add_mark :: proc(d: ^Line_Detail, kind: Container_Kind, lo, hi, container: int) {
	if d.n_marks >= MAX_DEPTH do return
	d.marks[d.n_marks] = {kind, u8(container), i32(lo), i32(hi)}
	d.n_marks += 1
}

// Classifies one line (no line ending) that follows a line ending in `prev`.
// `first_line` allows front matter.
parse_line :: proc(prev: State, text: string, first_line := false) -> (info: Line_Info, d: Line_Detail, next: State) {
	c := Cursor{s = text}
	info, d, next = classify(prev, &c, first_line)
	d.reached = min(d.reached, next.depth)
	d.content = {i32(min(c.pos, len(text))), i32(len(text))}
	// Fields of leaves that are no longer open.
	if next.leaf != .Paragraph {
		next.para_cells = 0
		next.para_refdefs = false
	}
	if next.leaf != .Fence {
		next.fence_char, next.fence_len, next.fence_indent = 0, 0, 0
		next.fence_lang = .None
	}
	if next.leaf != .Table do next.table_cols = 0
	if next.leaf != .Html do next.html_kind = 0
	return
}

@(private = "file")
classify :: proc(prev: State, c: ^Cursor, first_line: bool) -> (info: Line_Info, d: Line_Detail, next: State) {
	d.reached = MAX_DEPTH
	text := c.s
	n := len(text)
	next = prev

	// Continue the open containers.
	matched := 0
	match: for matched < int(prev.depth) {
		k := prev.containers[matched]
		switch k.kind {
		case .Quote:
			ind := indent_of(c^)
			p := after_indent(c^)
			if ind > 3 || p >= n || text[p] != '>' do break match
			add_mark(&d, .Quote, p, p + 1, matched)
			step_over(c, p)
			if c.pos < n && (text[c.pos] == ' ' || text[c.pos] == '\t') do consume_cols(c, 1)
		case .Bullet, .Ordered:
			// A blank line continues the item however little it is indented.
			switch {
			case d.reached == MAX_DEPTH && indent_of(c^) >= int(k.indent): consume_cols(c, int(k.indent))
			case after_indent(c^) < n:                                     break match
			case:                                                           d.reached = min(d.reached, u8(matched))
			}
		}
		matched += 1
	}
	all_matched := matched == int(prev.depth)

	// Leaf blocks that take whole lines until their end condition.
	if all_matched {
		#partial switch prev.leaf {
		case .Fence:
			ind := indent_of(c^)
			p := after_indent(c^)
			if ind <= 3 && is_fence_close(text[p:], prev.fence_char, prev.fence_len) {
				info.kind = .Fence_Close
				d.open = {i32(p), i32(n)}
				next.leaf = .None
			} else {
				consume_cols(c, min(ind, int(prev.fence_indent)))
				info.kind = .Fence_Body
			}
			return
		case .Html:
			blank := is_blank(text[c.pos:])
			if prev.html_kind >= 6 && blank {
				info.kind = .Blank
				next.leaf = .None
				return
			}
			info.kind = .Html
			if prev.html_kind <= 5 && html_block_ends(prev.html_kind, text[c.pos:]) do next.leaf = .None
			return
		case .Front_Matter:
			t := strings.trim_right_space(text)
			if t == "---" || t == "..." {
				info.kind = .Front_Matter_Fence
				d.open = {0, i32(n)}
				next.leaf = .None
			} else {
				info.kind = .Front_Matter_Body
			}
			return
		case .Math:
			p := after_indent(c^)
			if strings.has_prefix(text[p:], "$$") {
				info.kind = .Math_Fence
				d.open = {i32(p), i32(n)}
				next.leaf = .None
			} else {
				info.kind = .Math_Body
			}
			return
		case .Indented_Code:
			if is_blank(text[c.pos:]) {
				info.kind = .Blank
				return
			}
			if indent_of(c^) >= 4 {
				consume_cols(c, 4)
				info.kind = .Indented_Code
				return
			}
		}
	}

	// New containers and leaf blocks.
	next.containers = {}
	for k in 0 ..< matched do next.containers[k] = prev.containers[k]
	next.depth = u8(matched)
	leaf := prev.leaf
	switch {
	case leaf == .Paragraph:
	case leaf == .Table && all_matched:
	case:
		leaf = .None
	}
	next.leaf = .None
	opened := false // a container started on this line
	item_opened := false // ... and the innermost one is a list item

	blocks: for {
		// Text here could still continue the open paragraph (lazily if not all
		// containers matched); only some blocks may interrupt it.
		maybe_lazy := leaf == .Paragraph && !opened
		interrupting := maybe_lazy && all_matched
		ind := indent_of(c^)
		p := after_indent(c^)
		if p >= n do break blocks
		rest := text[p:]

		if ind >= 4 {
			if leaf == .Table && !opened {
				info.kind = .Table_Row
				next.leaf = .Table
				next.table_cols = prev.table_cols
				return
			}
			if maybe_lazy do break blocks
			consume_cols(c, 4)
			info.kind = .Indented_Code
			info.flags += {.Block_Start}
			next.leaf = .Indented_Code
			return
		}

		if rest[0] == '>' && int(next.depth) < MAX_DEPTH {
			add_mark(&d, .Quote, p, p + 1, int(next.depth))
			step_over(c, p)
			if c.pos < n && (text[c.pos] == ' ' || text[c.pos] == '\t') do consume_cols(c, 1)
			next.containers[next.depth] = {.Quote, '>', 0}
			next.depth += 1
			opened, item_opened = true, false
			leaf = .None
			continue
		}

		// A lone marker inside a list item, or one followed by a space, starts an
		// item where CommonMark would read it as a heading underline or more
		// text: it is what a new item looks like while it is being typed.
		in_item := matched > 0 && prev.containers[matched - 1].kind != .Quote
		new_item := interrupting && lone_marker(rest) && (in_item || len(strings.trim_right_space(rest)) < len(rest))

		// Before thematic breaks: "---" under a paragraph is a heading underline.
		if interrupting && !prev.para_refdefs && !new_item {
			if level := setext_level(rest); level > 0 {
				info.kind = .Setext_Underline
				info.aux = level
				d.open = {i32(p), i32(n)}
				return
			}
		}

		if first_line && matched == 0 && !opened && strings.trim_right_space(text) == "---" {
			info.kind = .Front_Matter_Fence
			info.flags += {.Block_Start}
			d.open = {0, i32(n)}
			next.leaf = .Front_Matter
			return
		}

		if is_thematic_break(rest) {
			info.kind = .Thematic_Break
			info.flags += {.Block_Start}
			d.open = {i32(p), i32(n)}
			return
		}

		if interrupting && prev.para_cells > 0 && strings.index_byte(rest, '|') >= 0 {
			if cols := delimiter_row_cells(rest); cols > 0 && cols == int(prev.para_cells) {
				info.kind = .Table_Delim
				info.aux = u8(cols)
				next.leaf = .Table
				next.table_cols = u8(cols)
				return
			}
		}

		if width, kind, marker, number := list_marker(rest); width > 0 && int(next.depth) < MAX_DEPTH {
			after := p + width
			empty := is_blank(text[after:])
			ok := after == n || text[after] == ' ' || text[after] == '\t'
			if interrupting && !new_item && (empty || (kind == .Ordered && number != 1)) do ok = false
			if ok {
				consume_cols(c, ind)
				c.pos, c.col, c.partial = after, c.col + width, 0
				spaces := indent_of(c^)
				if empty || spaces >= 5 {
					// No content yet, or indented code: the content column is one past the marker.
					consume_cols(c, empty ? spaces : 1)
					spaces = 1
				} else {
					consume_cols(c, spaces)
				}
				indent := ind + width + spaces
				add_mark(&d, kind, p, after, int(next.depth))
				next.containers[next.depth] = {kind, marker, u8(min(indent, 255))}
				next.depth += 1
				info.flags += {.Item_Start}
				opened, item_opened = true, true
				leaf = .None
				continue
			}
		}

		if level, mark_end := atx_heading(rest); level > 0 {
			info.kind = .Atx_Heading
			info.aux = level
			info.flags += {.Block_Start}
			d.open = {i32(p), i32(p + mark_end)}
			if lo := atx_closing(rest, mark_end); lo >= 0 do d.close = {i32(p + lo), i32(n)}
			return
		}

		if fence_char, fence_len, info_lo, ok := fence_open(rest); ok {
			info.kind = .Fence_Open
			info.flags += {.Block_Start}
			next.leaf = .Fence
			next.fence_char = fence_char
			next.fence_len = u8(min(fence_len, 255))
			next.fence_indent = u8(ind)
			after := rest[info_lo:]
			lang := strings.trim_space(after)
			info_hi := p + info_lo + len(strings.trim_right_space(after))
			d.open = {i32(p), i32(n)}
			d.info = {i32(min(n - len(strings.trim_left_space(after)), info_hi)), i32(info_hi)}
			if sp := strings.index_any(lang, " \t{"); sp >= 0 do lang = lang[:sp]
			next.fence_lang = syntax.language_for_name(lang)
			return
		}

		if rest[0] == '<' {
			if kind := html_block_start(rest, interrupting); kind > 0 {
				info.kind = .Html
				info.flags += {.Block_Start}
				next.leaf = .Html
				next.html_kind = kind
				if kind <= 5 && html_block_ends(kind, rest[2:]) do next.leaf = .None
				return
			}
		}

		if t := strings.trim_right_space(rest); strings.has_prefix(t, "$$") {
			if t == "$$" || (len(t) > 4 && strings.has_suffix(t, "$$")) {
				info.kind = .Math_Fence
				info.flags += {.Block_Start}
				d.open = {i32(p), i32(n)}
				if t == "$$" do next.leaf = .Math
				return
			}
		}

		if leaf == .Table && !opened {
			info.kind = .Table_Row
			next.leaf = .Table
			next.table_cols = prev.table_cols
			return
		}
		break blocks
	}

	if is_blank(text[min(c.pos, n):]) {
		info.kind = .Blank
		return
	}

	rest := text[after_indent(c^):]
	if leaf == .Paragraph && !opened {
		if !all_matched {
			// Lazy continuation: the paragraph stays inside its containers.
			next = prev
			d.reached = u8(matched)
			info.flags += {.Lazy}
			d.n_marks = 0
		}
		next.leaf = .Paragraph
		lo, hi, is_footnote, is_def := definition(rest)
		if prev.para_refdefs && is_def && !is_footnote {
			info.kind = .Link_Ref_Def
			off := i32(n - len(rest))
			d.label = {off + i32(lo), off + i32(hi)}
		} else {
			info.kind = .Paragraph
			next.para_refdefs = false
		}
		next.para_cells = u8(min(table_cells(rest), 255))
		return
	}

	info.kind = .Paragraph
	info.flags += {.Block_Start}
	next.leaf = .Paragraph
	next.para_cells = u8(min(table_cells(rest), 255))
	if item_opened {
		if checked, ok := task_box(rest); ok {
			lo := i32(n - len(rest))
			d.task = {lo, lo + 3}
			info.flags += {.Task}
			if checked do info.flags += {.Task_Checked}
		}
	}
	if lo, hi, is_footnote, ok := definition(rest); ok {
		off := i32(n - len(rest))
		d.label = {off + i32(lo), off + i32(hi)}
		info.kind = is_footnote ? .Footnote_Def : .Link_Ref_Def
		next.para_refdefs = !is_footnote
	}
	return
}

// --- Block syntax recognizers ------------------------------------------------------
// Each takes the line from its first non-blank character.

// A heading underline's level. A single "-" is not one: it is a list item
// being typed.
@(private = "file")
setext_level :: proc(s: string) -> u8 {
	t := strings.trim_right_space(s)
	if t == "" || (t[0] != '=' && t[0] != '-') || t == "-" do return 0
	for ch in transmute([]u8)t do if ch != t[0] do return 0
	return t[0] == '=' ? 1 : 2
}

// A list marker alone on a line ("-", "2.").
@(private = "file")
lone_marker :: proc(s: string) -> bool {
	width, _, _, _ := list_marker(s)
	return width > 0 && is_blank(s[width:])
}

@(private = "file")
is_thematic_break :: proc(s: string) -> bool {
	ch := s[0]
	if ch != '-' && ch != '*' && ch != '_' do return false
	count := 0
	for x in transmute([]u8)s {
		switch x {
		case ch:        count += 1
		case ' ', '\t':
		case:           return false
		}
	}
	return count >= 3
}

// Bytes in a list item marker ("-", "12."), its kind, bullet or delimiter, and number.
@(private = "file")
list_marker :: proc(s: string) -> (width: int, kind: Container_Kind, marker: u8, number: int) {
	switch s[0] {
	case '-', '+', '*':
		return 1, .Bullet, s[0], 0
	}
	i := 0
	for i < len(s) && i < 9 && is_digit(s[i]) {
		number = number * 10 + int(s[i] - '0')
		i += 1
	}
	if i == 0 || i >= len(s) || (s[i] != '.' && s[i] != ')') do return 0, .Bullet, 0, 0
	return i + 1, .Ordered, s[i], number
}

// Heading level and the end of its opening "#"s plus the spaces after them.
@(private = "file")
atx_heading :: proc(s: string) -> (level: u8, mark_end: int) {
	hashes := 0
	for hashes < len(s) && s[hashes] == '#' do hashes += 1
	if hashes == 0 || hashes > 6 || (hashes < len(s) && s[hashes] != ' ' && s[hashes] != '\t') do return 0, 0
	i := hashes
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') do i += 1
	return u8(hashes), i
}

// Start of an ATX heading's closing sequence (the spaces before trailing #s), or -1.
@(private = "file")
atx_closing :: proc(s: string, mark_end: int) -> int {
	t := strings.trim_right_space(s)
	end := len(t)
	i := end
	for i > mark_end && t[i - 1] == '#' do i -= 1
	if i == end do return len(t) < len(s) && end > mark_end ? end : -1
	if i == mark_end do return i // the content is only #s
	if t[i - 1] != ' ' && t[i - 1] != '\t' do return -1
	for i > mark_end && (t[i - 1] == ' ' || t[i - 1] == '\t') do i -= 1
	return i
}

@(private = "file")
fence_open :: proc(s: string) -> (ch: u8, length: int, info_lo: int, ok: bool) {
	ch = s[0]
	if ch != '`' && ch != '~' do return
	for length < len(s) && s[length] == ch do length += 1
	if length < 3 do return
	if ch == '`' && strings.index_byte(s[length:], '`') >= 0 do return
	return ch, length, length, true
}

@(private = "file")
is_fence_close :: proc(s: string, ch: u8, length: u8) -> bool {
	i := 0
	for i < len(s) && s[i] == ch do i += 1
	return i >= int(length) && i > 0 && is_blank(s[i:])
}

// Cells in a table row: '|'-separated, with optional outer pipes. 0 for a blank line.
table_cells :: proc(s: string) -> int {
	t := strings.trim_space(s)
	if t == "" do return 0
	if t[0] == '|' do t = t[1:]
	n := 1
	for i := 0; i < len(t); i += 1 {
		switch t[i] {
		case '\\': i += 1
		case '|':  if i < len(t) - 1 do n += 1
		}
	}
	return n
}

// Cells in a delimiter row ("| :-- | --: |"), or 0 if it isn't one.
@(private = "file")
delimiter_row_cells :: proc(s: string) -> int {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "|") do t = t[1:]
	if strings.has_suffix(t, "|") do t = t[:len(t) - 1]
	n := 0
	for cell in strings.split_iterator(&t, "|") {
		c := strings.trim_space(cell)
		if strings.has_prefix(c, ":") do c = c[1:]
		if strings.has_suffix(c, ":") do c = c[:len(c) - 1]
		if c == "" do return 0
		for ch in transmute([]u8)c do if ch != '-' do return 0
		n += 1
	}
	return n
}

// A task box "[ ]" / "[x]" followed by whitespace or the end of the line.
@(private = "file")
task_box :: proc(s: string) -> (checked, ok: bool) {
	if len(s) < 3 || s[0] != '[' || s[2] != ']' do return
	if len(s) > 3 && s[3] != ' ' && s[3] != '\t' do return
	switch s[1] {
	case ' ':      return false, true
	case 'x', 'X': return true, true
	}
	return
}

// A link reference definition `[label]: dest "title"` or a footnote definition
// `[^label]: text`, on one line. Returns the label's range.
@(private = "file")
definition :: proc(s: string) -> (lo, hi: int, footnote, ok: bool) {
	if len(s) < 4 || s[0] != '[' do return
	footnote = s[1] == '^'
	lo = footnote ? 2 : 1
	i := lo
	for i < len(s) && s[i] != ']' {
		switch s[i] {
		case '\\': i += 1
		case '[':  return 0, 0, false, false
		}
		i += 1
	}
	if i >= len(s) || i == lo || i - lo > 999 || i + 1 >= len(s) || s[i + 1] != ':' do return 0, 0, false, false
	if strings.trim_space(s[lo:i]) == "" do return 0, 0, false, false
	hi = i
	if footnote do return lo, hi, true, true
	rest := strings.trim_left_space(s[i + 2:])
	if rest == "" do return 0, 0, false, false
	// Destination, then an optional title.
	j := 0
	if rest[0] == '<' {
		end := strings.index_byte(rest, '>')
		if end < 0 do return 0, 0, false, false
		j = end + 1
	} else {
		for j < len(rest) && !is_space(rest[j]) do j += 1
	}
	title := strings.trim_space(rest[j:])
	if title != "" {
		if j < len(rest) && !is_space(rest[j]) do return 0, 0, false, false
		open := title[0]
		close := open == '(' ? u8(')') : open
		if (open != '"' && open != '\'' && open != '(') || len(title) < 2 || title[len(title) - 1] != close {
			return 0, 0, false, false
		}
	}
	return lo, hi, false, true
}

// --- Characters ---------------------------------------------------------------------

@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

@(private)
is_blank :: proc(s: string) -> bool {
	for c in transmute([]u8)s do if !is_space(c) do return false
	return true
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
is_alnum :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c)
}

@(private)
is_ascii_punct :: proc(c: u8) -> bool {
	switch c {
	case '!' ..= '/', ':' ..= '@', '[' ..= '`', '{' ..= '~':
		return true
	}
	return false
}
