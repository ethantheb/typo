package mdview

import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import clay "../../vendor/clay-odin"
import "../buffer"
import "../markdown"
import "../syntax"
import "../gfx"
import "../textedit"

// Layout of rendered Markdown. Each document line becomes rows of runs: styled
// text, monospace code, or a widget (bullet, task box). A line's syntax is
// split into items (shown or hidden bytes, widgets), which are then wrapped to
// the text column. Layouts are cached by a hash of everything they depend on,
// so typing re-lays out only the edited line and moving the caret only the
// lines whose syntax it reveals or hides.

@(private)
HEADING_LINE_FACTOR :: 1.3
@(private)
CODE_LINE_FACTOR :: 1.45
@(private)
HEADING_SCALE := [6]f32{2.0, 1.6, 1.35, 1.15, 1.0, 0.9}
@(private)
QUOTE_INDENT :: 22
@(private)
LIST_INDENT :: 26
@(private)
CODE_PAD :: 12 // inside a code block, left and right
@(private)
CODE_SPAN_PAD :: 5 // around a code span, for its background
@(private)
SETEXT_ROW :: 4 // a hidden setext underline
@(private)
TAB :: "    " // drawn for a tab in prose
// Bytes of a line laid out; the rest of an enormous line isn't shown.
@(private)
MAX_LAYOUT_BYTES :: 64 << 10
@(private)
CELL_PAD :: 10 // in a table cell, left and right
@(private)
CELL_VPAD :: 5 // ... top and bottom
// Rows measured for a table's column widths.
@(private)
TABLE_MAX_ROWS :: 500

@(private)
Style_Flag :: enum u8 {
	Strong,
	Em,
	Strike,
	Code, // a code span: monospace on a background
	Mark, // ==highlight==
	Underline,
	Super, // a footnote reference
}

@(private)
Style :: bit_set[Style_Flag;u8]

@(private)
Color :: enum u8 {
	Text,
	Heading,
	Link,
	Marker,
	Code, // fenced code: colored by its language
	Dim,
	Math,
	Html,
}

@(private)
Run_Kind :: enum u8 {
	Text,
	Mono, // code on a column grid
	Bullet,
	Checkbox,
	Image, // an item only: laid out as an Image_Box below the text
}

// An image below a line's text.
@(private)
Image_Box :: struct {
	path:       [2]i32, // in Line_Layout.strings
	alt:        [2]i32, // bytes of the line
	x, y, w, h: f32,
}

@(private)
Run :: struct {
	lo, hi:  i32, // bytes of the line
	x, w:    f32, // from the text column's left
	row:     i32,
	font:    gfx.Font_Id,
	size:    u16,
	kind:    Run_Kind,
	style:   Style,
	color:   Color,
	depth:   u8,     // a bullet's list depth
	checked: bool,
	subst:   [2]i32, // text drawn in place of the bytes (a decoded entity), in Line_Layout.strings
	dy:      f32,    // below the row's baseline: a wrapped line within a table cell
}

// Rows partition a line's bytes: row r has [lo, next row's lo).
@(private)
Row :: struct {
	y, h, baseline: f32,
	lo:             i32,
	runs:           [2]i32, // range in Line_Layout.runs
}

@(private)
Line_Kind :: enum u8 {
	Prose,
	Code,
	Thin, // a hidden fence or underline: a short empty row
	Rule, // a thematic break
	Table, // a table row, its cells on the table's columns
}

@(private)
Line_Layout :: struct {
	rows:      [dynamic]Row,
	runs:      [dynamic]Run,
	strings:   [dynamic]u8,
	height:    f32,
	kind:      Line_Kind,
	indent:    f32,    // content start, from the column's left
	code_bg:   [2]f32, // x range of a code block background; {0, 0} = none
	round:     [2]bool, // round its top / bottom corners
	bars:      [markdown.MAX_DEPTH]f32, // quote bar x positions
	n_bars:    int,
	char_w:    f32, // of Mono runs
	edges:     [dynamic]f32, // a table's column edges
	header:    bool,         // a table's header row
	cells:     [dynamic][2]i32, // a table row's: where a caret can be in each cell
	cell_h:    f32,             // a table row's: height of a line in a cell
	images:    [dynamic]Image_Box,
	// A code block line's block (its first line; -1 if none), and that block's
	// sideways scroll, applied to Mono runs (see md_run), set when looked up.
	code_block: int,
	scroll:     f32,
	last_used:  u64,
}

@(private)
Hang :: enum u8 {
	None,
	Left,  // drawn starting at x, left of the content
	Right, // drawn ending at x
}

// One part of a line, before wrapping.
@(private)
Item :: struct {
	lo, hi:  i32,
	kind:    Run_Kind,
	hidden:  bool,
	hang:    Hang,
	x:       f32,
	style:   Style,
	color:   Color,
	depth:   u8,
	checked: bool,
	subst:   string, // also an image's path
	cell:    i8, // a table cell
	brk:     bool, // a line break in its table cell follows it (a <br> tag)
	size:    [2]f32, // an image's, or its placeholder's
}

@(private)
Params :: struct {
	kind:       Line_Kind,
	size:       u16, // text size
	heading:    u8,
	indent:     f32,
	right:      f32, // content end
	pad_top:    f32,
	pad_bottom: f32,
	thin_h:     f32,
	code_bg:    bool,
	round:      [2]bool,
	n_bars:     int,
	bars:       [markdown.MAX_DEPTH]f32,
	table:      ^Table,
	header:     bool,
	cells:      [][2]i32, // a table row's: where a caret can be in each cell
	no_wrap:    bool, // a code block line: one row, scrolled sideways with its block
	code_block: int,  // ... the block's first line
}

// A table's columns, shared by the layouts of its rows.
@(private)
Table :: struct {
	first, last: int,   // lines: the header to the last row
	widths:      []f32, // per column: its widest cell, padding included
	aligns:      []u8,  // per column: 0 left, 1 center, 2 right
	// Fitted to the pane (fit_table).
	x:           f32,   // left edge, from the text column's left
	edges:       []f32, // column edges from x, one more than the columns
	wraps:       bool,  // its text doesn't fit the text column on one line
}

@(private)
font_size :: proc() -> u16 {
	return u16(env.config().font_size)
}

@(private)
code_size :: proc(size: u16) -> u16 {
	return max(u16(math.round(f32(size) * 0.88)), 8)
}

// Line height of rendered text, as a multiple of its size.
@(private)
line_factor :: proc() -> f32 {
	return f32(env.config().line_height)
}

// A code block's first or last line: a code row and the block's padding.
@(private)
fence_row_height :: proc() -> f32 {
	return math.round(f32(code_size(font_size())) * CODE_LINE_FACTOR) + 6
}

@(private)
body_line_height :: proc() -> f32 {
	return f32(font_size()) * line_factor()
}

@(private)
heading_size :: proc(level: u8) -> u16 {
	return u16(math.round(f32(font_size()) * HEADING_SCALE[clamp(int(level), 1, 6) - 1]))
}

// Space above and below a heading's text.
@(private)
heading_pads :: proc(level: u8) -> (top, bottom: f32) {
	size := f32(heading_size(level))
	return size * (level <= 2 ? 0.7 : 0.5), size * 0.15
}

// --- Items -----------------------------------------------------------------------------

// A paragraph's (or heading's) inline spans, parsed once per frame.
@(private)
Block :: struct {
	bt:    markdown.Block_Text,
	spans: []markdown.Span,
}

@(private)
block_at :: proc(e: ^View, i: int) -> ^Block {
	first, last, ok := markdown.block_extent(e.md, i)
	if !ok do return nil
	mv := &e.mdv
	if b, found := mv.blocks[first]; found do return b
	context.temp_allocator = mv.doc_allocator
	b := new(Block, mv.doc_allocator)
	b.bt = markdown.block_text(e.md, &e.buf, first, last)
	spans := make([dynamic]markdown.Span, mv.doc_allocator)
	labels := markdown.doc_labels(e.md, &e.buf)
	if e.md.lines[first].kind == .Table_Row || markdown.is_table_header(e.md, first) {
		markdown.inline_parse_row(b.bt.text, labels, &spans)
	} else {
		markdown.inline_parse(b.bt.text, labels, &spans)
	}
	b.spans = spans[:]
	mv.blocks[first] = b
	return b
}

@(private)
Item_Builder :: struct {
	items:  [dynamic]Item,
	// Per byte of the line, for the inline content.
	hidden: []bool,
	style:  []Style,
	color:  []Color,
	subst:  []string, // text replacing bytes [i, subst_end[i])
	subst_end: []i32,
	breaks: []bool, // a line break in a table cell follows the byte
	cell:   i8, // given to the items flush_bytes adds
}

@(private)
add_item :: proc(ib: ^Item_Builder, it: Item) {
	if it.hi > it.lo || it.kind != .Text do append(&ib.items, it)
}

@(private)
hide :: proc(ib: ^Item_Builder, lo, hi: int) {
	if hi > lo do append(&ib.items, Item{lo = i32(lo), hi = i32(hi), hidden = true})
}

// The baseline that centres a font's text in a row h high.
@(private)
centered_baseline :: proc(m: gfx.Font_Metrics, h: f32) -> f32 {
	return (h - (m.ascent + m.descent)) / 2 + m.ascent
}

// Gives the builder per-byte looks for a line of n bytes.
@(private)
item_builder_bytes :: proc(ib: ^Item_Builder, n: int) {
	ib.hidden = make([]bool, n, context.temp_allocator)
	ib.style = make([]Style, n, context.temp_allocator)
	ib.color = make([]Color, n, context.temp_allocator)
	ib.subst = make([]string, n, context.temp_allocator)
	ib.subst_end = make([]i32, n, context.temp_allocator)
	ib.breaks = make([]bool, n, context.temp_allocator)
}

// Syntax shown as a marker where revealed, otherwise hidden.
@(private = "file")
marker_or_hide :: proc(ib: ^Item_Builder, lo, hi: int, revealed: bool) {
	if revealed {
		add_item(ib, {lo = i32(lo), hi = i32(hi), color = .Marker})
	} else {
		hide(ib, lo, hi)
	}
}

// Groups bytes [lo, hi) by their per-byte look into items.
@(private)
flush_bytes :: proc(ib: ^Item_Builder, lo, hi: int) {
	k := lo
	for k < hi {
		if ib.subst[k] != "" {
			append(&ib.items, Item{lo = i32(k), hi = ib.subst_end[k], subst = ib.subst[k], style = ib.style[k], color = ib.color[k], cell = ib.cell})
			k = int(ib.subst_end[k])
			continue
		}
		j := k + 1
		for j < hi && !ib.breaks[j - 1] && ib.hidden[j] == ib.hidden[k] && ib.style[j] == ib.style[k] && ib.color[j] == ib.color[k] && ib.subst[j] == "" do j += 1
		append(&ib.items, Item{lo = i32(k), hi = i32(j), hidden = ib.hidden[k], style = ib.style[k], color = ib.color[k], cell = ib.cell, brk = ib.breaks[j - 1]})
		k = j
	}
}

@(private)
Code_Group :: enum u8 {
	None,
	Fenced,
	Indented,
	Math,
	Front_Matter,
}

// Which kind of code block a line belongs to.
@(private)
code_group :: proc(k: markdown.Line_Kind) -> Code_Group {
	#partial switch k {
	case .Fence_Open, .Fence_Body, .Fence_Close:  return .Fenced
	case .Indented_Code:                          return .Indented
	case .Math_Fence, .Math_Body:                 return .Math
	case .Front_Matter_Fence, .Front_Matter_Body: return .Front_Matter
	}
	return .None
}

// The lines of the code block (fenced, indented, math or front matter)
// containing line i.
@(private)
code_lines :: proc(doc: ^markdown.Doc, i: int) -> (first, last: int) {
	first, last = markdown.block_first(doc, i), i
	for last + 1 < len(doc.lines) && markdown.block_first(doc, last + 1) == first do last += 1
	return
}

// Splits line i into items and picks how it is laid out.
@(private = "file")
md_items :: proc(e: ^View, i: int, text: string, start: int) -> (items: []Item, p: Params) {
	doc := e.md
	info := doc.lines[i]
	d := markdown.line_detail(doc, i, text)
	state := markdown.line_state(doc, i)
	n := len(text)
	p.size = font_size()
	p.right = e.mdv.col_w
	revealed := touches(e, start, start + n)

	// Containers: quote bars and list indentation.
	content_x: [markdown.MAX_DEPTH]f32
	list_depth: [markdown.MAX_DEPTH]u8
	x: f32
	lists: u8
	// Blank and lazy lines only as deep as their own text reaches, where text
	// typed on them would go.
	for c, k in state.containers[:d.reached] {
		if c.kind == .Quote {
			p.bars[p.n_bars] = x + 2
			p.n_bars += 1
			x += QUOTE_INDENT
		} else {
			x += LIST_INDENT
			lists += 1
		}
		content_x[k] = x
		list_depth[k] = lists
	}
	p.indent = x

	ib := Item_Builder{items = make([dynamic]Item, context.temp_allocator)}
	pos := 0
	for m in d.marks[:d.n_marks] {
		hide(&ib, pos, int(m.lo))
		k := int(m.container)
		touched := touches(e, start + int(m.lo), start + int(m.hi))
		switch m.kind {
		case .Quote:
			if revealed {
				add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Left, x = content_x[k] - QUOTE_INDENT, color = .Marker})
			} else {
				hide(&ib, int(m.lo), int(m.hi))
			}
		case .Bullet:
			if touched {
				add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Right, x = content_x[k] - 8, color = .Marker})
			} else {
				add_item(&ib, {lo = m.lo, hi = m.hi, kind = .Bullet, x = content_x[k] - LIST_INDENT / 2 - 2, depth = list_depth[k]})
			}
		case .Ordered:
			add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Right, x = content_x[k] - 7, color = touched ? .Marker : .Dim})
		}
		pos = int(m.hi)
	}
	content := int(d.content[0])
	// After a list marker, spaces beyond the first are shown while the line is
	// edited; elsewhere item text lines up however many follow the marker.
	if d.n_marks > 0 && d.marks[d.n_marks - 1].kind != .Quote && pos < content {
		hide(&ib, pos, pos + 1)
		if revealed {
			for k in pos + 1 ..< content do add_item(&ib, {lo = i32(k), hi = i32(k + 1), subst = text[k] == '\t' ? TAB : ""})
		} else {
			hide(&ib, pos + 1, content)
		}
		pos = content
	}
	if d.task != {} {
		hide(&ib, pos, int(d.task[0]))
		pos = int(d.task[1])
		if touches(e, start + int(d.task[0]), start + int(d.task[1])) {
			add_item(&ib, {lo = d.task[0], hi = d.task[1], color = .Marker})
		} else {
			add_item(&ib, {lo = d.task[0], hi = d.task[1], kind = .Checkbox, checked = .Task_Checked in info.flags})
			if pos < n && text[pos] == ' ' {
				hide(&ib, pos, pos + 1)
				pos += 1
			}
		}
		content = pos
	}
	hide(&ib, pos, content)

	if b, ok := code_block_at(e, i); ok {
		first, last := b.first, b.last
		p.code_bg = true
		p.round = {i == first, i == last}
		is_fence := info.kind == .Fence_Open || info.kind == .Fence_Close || info.kind == .Math_Fence || info.kind == .Front_Matter_Fence
		if is_fence && !touches(e, buffer.line_start(&e.buf, first), buffer.line_start(&e.buf, last) + int(doc.lines[last].len)) {
			// As tall as when shown, so revealing the fences moves nothing; the
			// opening one shows the language.
			p.kind = .Thin
			p.thin_h = fence_row_height()
			if info.kind == .Fence_Open && d.info[1] > d.info[0] {
				hide(&ib, content, int(d.info[0]))
				add_item(&ib, {lo = d.info[0], hi = d.info[1], hang = .Right, x = p.right - CODE_PAD, color = .Dim})
				hide(&ib, int(d.info[1]), n)
			} else {
				hide(&ib, content, n)
			}
		} else {
			p.kind = .Code
			p.no_wrap = true
			p.code_block = first
			// Colored by language only when the fence names one.
			color := Color.Code
			switch {
			case is_fence:                                       color = .Marker
			case info.kind == .Math_Body:                        color = .Math
			case code_group(info.kind) == .Front_Matter:         color = .Dim
			case state.fence_lang == .None:                      color = .Text
			}
			add_item(&ib, {lo = i32(content), hi = i32(n), kind = .Mono, color = color})
		}
		return ib.items[:], p
	}

	#partial switch info.kind {
	case .Html:
		p.kind = .Code
		add_item(&ib, {lo = i32(content), hi = i32(n), kind = .Mono, color = .Html})
		return ib.items[:], p
	case .Table_Delim, .Table_Row:
		table_items(e, &ib, &p, i, text, start, content)
		return ib.items[:], p
	case .Setext_Underline, .Thematic_Break:
		marker_or_hide(&ib, content, n, revealed)
		if !revealed {
			p.kind = .Rule
			if info.kind == .Setext_Underline do p.kind, p.thin_h = .Thin, SETEXT_ROW
		}
		return ib.items[:], p
	case .Link_Ref_Def:
		add_item(&ib, {lo = i32(content), hi = i32(n), color = .Dim})
		return ib.items[:], p
	case .Blank:
		// Its spaces only while being edited.
		if revealed {
			for k in content ..< n do add_item(&ib, {lo = i32(k), hi = i32(k + 1), subst = text[k] == '\t' ? TAB : ""})
		} else {
			hide(&ib, content, n)
		}
		return ib.items[:], p
	case .Paragraph:
		if markdown.is_table_header(doc, i) {
			table_items(e, &ib, &p, i, text, start, content)
			return ib.items[:], p
		}
	}

	// Prose: a heading or a paragraph, with inline syntax.
	color := Color.Text
	content_hi := n
	heading: u8
	switch {
	case info.kind == .Atx_Heading:
		heading = info.aux
		marker_or_hide(&ib, content, int(d.open[1]), revealed)
		content = int(d.open[1])
		if d.close != {} do content_hi = int(d.close[0])
	case info.kind == .Paragraph || info.kind == .Footnote_Def:
		if _, last, ok := markdown.block_extent(doc, i); ok && markdown.setext_heading(doc, last) {
			heading = doc.lines[last + 1].aux
		}
	}
	if heading > 0 {
		p.heading = heading
		p.size = heading_size(heading)
		color = heading == 6 ? .Dim : .Heading
		p.pad_top, p.pad_bottom = heading_pads(heading)
	}

	item_builder_bytes(&ib, n)
	for &c in ib.color[content:content_hi] do c = color
	if info.kind == .Footnote_Def && d.label[1] > 0 {
		// "[^label]:" before the text.
		for k in max(int(d.label[0]) - 2, 0) ..< min(int(d.label[1]) + 2, n) do ib.color[k] = .Link
		content = max(int(d.label[0]) - 2, content)
	}

	images := make([dynamic]Item, context.temp_allocator)
	if b := block_at(e, i); b != nil {
		seg := b.bt.segs[i - b.bt.first]
		line_off := seg.doc_lo - start - seg.lo // block text position -> line byte
		for s in b.spans {
			if int(s.hi) < seg.lo || int(s.lo) > seg.hi do continue
			touched := touches(e, markdown.block_to_doc(&b.bt, int(s.lo)), markdown.block_to_doc(&b.bt, int(s.hi)))
			apply_span(&ib, s, line_off, seg.lo, seg.hi, touched, text)
			if s.kind == .Wikilink && !s.embed && !touched do wikilink_look(e, &ib, b.bt.text, s, line_off, seg.lo, seg.hi)
			// An image starting on this line: shown below it, its syntax hidden
			// unless touched.
			if s.kind == .Image && int(s.lo) >= seg.lo {
				dest := b.bt.text[s.url[0]:s.url[1]]
				if s.reference do dest, _ = markdown.reference_destination(doc, &e.buf, dest)
				path := image_path(e, markdown.unescape(dest))
				if s.embed {
					found: bool
					if path, found = wiki_path(e, dest); !found do path = image_path(e, dest)
				}
				img := get_image(path)
				lo, hi := int(s.lo) + line_off, min(int(s.hi), seg.hi) + line_off
				if !touched do for k in lo ..< hi do ib.hidden[k] = true
				size := [2]f32{260, img.state == .Loading ? 140 : 72}
				if img.w > 0 do size = {f32(img.w), f32(img.h)}
				append(&images, Item{lo = i32(int(s.open_hi) + line_off), hi = i32(min(int(s.close_lo), seg.hi) + line_off), kind = .Image, subst = path, size = size, checked = img.state == .Failed})
			}
		}
	}
	for k in content ..< content_hi {
		if text[k] == '\t' && !ib.hidden[k] && ib.subst[k] == "" do ib.subst[k], ib.subst_end[k] = TAB, i32(k + 1)
	}
	flush_bytes(&ib, content, content_hi)
	marker_or_hide(&ib, content_hi, n, revealed)
	append(&ib.items, ..images[:])
	return ib.items[:], p
}

// A wikilink to a note that doesn't exist is dimmed, and without an alias
// "Note#Heading" shows as "Note > Heading".
@(private = "file")
wikilink_look :: proc(e: ^View, ib: ^Item_Builder, bt_text: string, s: markdown.Span, line_off, seg_lo, seg_hi: int) {
	target := bt_text[s.url[0]:s.url[1]]
	note := target
	if hash := strings.index_byte(target, '#'); hash >= 0 {
		note = target[:hash]
		if k := int(s.url[0]) + hash; hash > 0 && s.open_hi == s.url[0] && k >= seg_lo && k < seg_hi {
			ib.subst[k + line_off], ib.subst_end[k + line_off] = " > ", i32(k + line_off + 1)
		}
	}
	if note == "" do return
	if _, found := wiki_path(e, note); found do return
	for k in max(int(s.open_hi), seg_lo) ..< min(int(s.close_lo), seg_hi) do ib.color[k + line_off] = .Dim
}

// --- Wrapping ------------------------------------------------------------------------

// The font for prose with a style, at a text size.
@(private)
prose_font :: proc(st: Style, heading: u8, size: u16) -> (gfx.Font_Id, u16) {
	if .Code in st do return .Editor, code_size(size)
	bold := .Strong in st || heading > 0
	italic := .Em in st
	f: gfx.Font_Id
	switch {
	case bold && italic:                     f = .Md_Bold_Italic
	case italic:                             f = .Md_Italic
	case heading > 2 && .Strong not_in st:   f = .Md_SemiBold
	case bold:                               f = .Md_Bold
	case:                                    f = .Md_Regular
	}
	return f, .Super in st ? u16(f32(size) * 0.72) : size
}

@(private = "file")
Piece :: struct {
	item:        int,
	lo, hi:      int,  // line bytes
	w_word:      f32,  // without trailing spaces
	w_full:      f32,
	space_after: bool,
	glue:        bool, // continues the previous piece's word
	pad:         [2]f32, // space before and after, included in the widths (around code spans)
	brk:         bool, // an empty piece starting a new line of a table cell
}

// Splits the shown items (of one table cell, if cell >= 0) into pieces: words,
// split where the style changes; "glue" joins the parts of one word. A line
// break in a cell is an empty piece after its item.
@(private)
build_pieces :: proc(items: []Item, text: string, p: ^Params, cell := -1) -> []Piece {
	pieces := make([dynamic]Piece, context.temp_allocator)
	for it, idx in items {
		if cell >= 0 && int(it.cell) != cell do continue
		defer if it.brk do append(&pieces, Piece{item = idx, lo = int(it.hi), hi = int(it.hi), space_after = true, brk = true})
		if it.hidden || it.kind == .Bullet || it.kind == .Image || it.hang != .None do continue
		font, size := prose_font(it.style, p.heading, p.size)
		prev_space := len(pieces) == 0 || pieces[len(pieces) - 1].space_after
		if it.kind == .Checkbox {
			box := f32(p.size) * 0.95
			append(&pieces, Piece{idx, int(it.lo), int(it.hi), box, box + f32(p.size) * 0.4, true, false, {}, false})
			continue
		}
		if it.subst != "" {
			sw := gfx.text_width(&gfx.text_system, font, size, it.subst)
			append(&pieces, Piece{idx, int(it.lo), int(it.hi), sw, sw, false, !prev_space, {}, false})
			continue
		}
		s := text[it.lo:it.hi]
		k := 0
		for k < len(s) {
			j := k
			for j < len(s) && s[j] != ' ' && s[j] != '\t' do j += 1
			e := j
			for e < len(s) && (s[e] == ' ' || s[e] == '\t') do e += 1
			ww := gfx.text_width(&gfx.text_system, font, size, s[k:j])
			wf := e > j ? gfx.text_width(&gfx.text_system, font, size, s[k:e]) : ww
			glue := k == 0 && !prev_space
			pad: [2]f32
			if .Code in it.style {
				if k == 0 do pad[0] = CODE_SPAN_PAD
				if e == len(s) do pad[1] = CODE_SPAN_PAD
			}
			append(&pieces, Piece{idx, int(it.lo) + k, int(it.lo) + e, ww + pad[0] + pad[1], wf + pad[0] + pad[1], e > j, glue, pad, false})
			prev_space = e > j
			k = e
		}
	}
	return pieces[:]
}

@(private = "file")
Wrapper :: struct {
	L:       ^Line_Layout,
	p:       ^Params,
	text:    string,
	items:   []Item,
	x0:      f32,
	x:       f32,
	y:       f32,
	row:     Row,
	base:    struct {
		font: gfx.Font_Id,
		size: u16,
	},
	factor:  f32,
}

// Lays out a line's items.
@(private)
md_layout :: proc(L: ^Line_Layout, text: string, items: []Item, p: Params) {
	clear(&L.rows)
	clear(&L.runs)
	clear(&L.strings)
	L.kind = p.kind
	L.indent = p.indent
	L.round = p.round
	L.bars = p.bars
	L.n_bars = p.n_bars
	L.code_bg = p.code_bg ? {p.indent, p.right} : {}
	L.code_block = p.no_wrap ? p.code_block : -1
	L.header = false
	clear(&L.edges)
	clear(&L.cells)
	clear(&L.images)
	p := p
	switch p.kind {
	case .Thin:
		append(&L.rows, Row{h = p.thin_h})
		L.height = p.thin_h
		add_hanging(L, text, items, &p)
		// A label at the right (a code block's language), small and centred.
		for it in items {
			if it.hidden || it.hang != .Right || it.x <= p.indent do continue
			size := code_size(p.size) - 1
			m := gfx.font_metrics(&gfx.text_system, .Md_Regular, size)
			w := gfx.text_width(&gfx.text_system, .Md_Regular, size, text[it.lo:it.hi])
			L.rows[0].baseline = centered_baseline(m, p.thin_h)
			append(&L.runs, Run{lo = it.lo, hi = it.hi, x = it.x - w, w = w, font = .Md_Regular, size = size, color = it.color})
			L.rows[0].runs = {0, i32(len(L.runs))}
		}
		if p.table != nil do for edge in p.table.edges do append(&L.edges, p.table.x + edge)
	case .Rule:
		h := f32(p.size) * line_factor()
		append(&L.rows, Row{h = h, baseline = h / 2})
		L.height = h
	case .Code:
		layout_code(L, text, items, &p)
	case .Prose:
		layout_prose(L, text, items, &p)
	case .Table:
		layout_table(L, text, items, &p)
	}
}

@(private = "file")
layout_code :: proc(L: ^Line_Layout, text: string, items: []Item, p: ^Params) {
	size := code_size(p.size)
	cw := max(gfx.text_char_width(&gfx.text_system, .Editor, size), 1)
	L.char_w = cw
	m := gfx.font_metrics(&gfx.text_system, .Editor, size)
	row_h := math.round(f32(size) * CODE_LINE_FACTOR)
	baseline := centered_baseline(m, row_h)
	pad_top := p.round[0] && p.code_bg ? f32(6) : 0
	pad_bottom := p.round[1] && p.code_bg ? f32(6) : 0
	x0 := p.indent + (p.code_bg ? CODE_PAD : 0)
	cols := max(int((p.right - x0 - (p.code_bg ? CODE_PAD : 0)) / cw), 8)
	if p.no_wrap do cols = max(int)
	y := pad_top
	append(&L.rows, Row{y = y, h = row_h, baseline = baseline})
	add_hanging(L, text, items, p)
	for it in items {
		if it.hidden || it.kind != .Mono do continue
		lo := int(it.lo)
		col, row_col := 0, 0
		k := lo
		for r, j in text[lo:it.hi] {
			next := textedit.next_col(col, r)
			if next - row_col > cols && k < lo + j {
				add_mono(L, it, k, lo + j, x0, row_col, col, cw, size)
				L.rows[len(L.rows) - 1].runs[1] = i32(len(L.runs))
				y += row_h
				append(&L.rows, Row{y = y, h = row_h, baseline = baseline, lo = i32(lo + j), runs = {i32(len(L.runs)), i32(len(L.runs))}})
				k = lo + j
				row_col = col
			}
			col = next
		}
		add_mono(L, it, k, int(it.hi), x0, row_col, col, cw, size)
	}
	L.rows[len(L.rows) - 1].runs[1] = i32(len(L.runs))
	L.height = y + row_h + pad_bottom
}

@(private = "file")
add_mono :: proc(L: ^Line_Layout, it: Item, lo, hi: int, x0: f32, row_col, col: int, cw: f32, size: u16) {
	if hi <= lo do return
	append(&L.runs, Run{
		lo = i32(lo), hi = i32(hi), x = x0, w = f32(col - row_col) * cw, row = i32(len(L.rows) - 1),
		font = .Editor, size = size, kind = .Mono, color = it.color,
	})
}

// Bullets and list or quote markers, which hang left of the content, as runs
// of the first row.
@(private = "file")
add_hanging :: proc(L: ^Line_Layout, text: string, items: []Item, p: ^Params) {
	for it in items {
		if it.hidden do continue
		switch {
		case it.kind == .Bullet:
			font, size := prose_font({}, p.heading, p.size)
			append(&L.runs, Run{lo = it.lo, hi = it.hi, x = it.x - f32(size) * 0.25, w = f32(size) * 0.5, font = font, size = size, kind = .Bullet, depth = it.depth})
		case it.hang != .None && it.x <= p.indent:
			font, size := prose_font(it.style, p.heading, p.size)
			tw := gfx.text_width(&gfx.text_system, font, size, text[it.lo:it.hi])
			x := it.hang == .Right ? it.x - tw : it.x
			append(&L.runs, Run{lo = it.lo, hi = it.hi, x = x, w = tw, font = font, size = size, color = it.color})
		}
	}
}

@(private = "file")
layout_prose :: proc(L: ^Line_Layout, text: string, items: []Item, p: ^Params) {
	w := Wrapper{L = L, p = p, text = text, items = items, x0 = p.indent, x = p.indent, y = p.pad_top}
	w.factor = p.heading > 0 ? HEADING_LINE_FACTOR : line_factor()
	w.base.font, w.base.size = prose_font({}, p.heading, p.size)
	right := max(p.right, p.indent + 40)

	pieces := build_pieces(items, text, p)
	add_hanging(L, text, items, p)

	i := 0
	for i < len(pieces) {
		j := i + 1
		for j < len(pieces) && pieces[j].glue do j += 1
		word: f32
		for k in i ..< j do word += k == j - 1 ? pieces[k].w_word : pieces[k].w_full
		if w.x + word > right && w.x > w.x0 + 0.5 do new_row(&w, pieces[i].lo)
		for k in i ..< j {
			pc := pieces[k]
			// A word wider than the whole column breaks anywhere.
			for w.x + pc.w_word > right && w.x > w.x0 + 0.5 && word > right - w.x0 {
				it := items[pc.item]
				if it.kind == .Checkbox || it.subst != "" {
					new_row(&w, pc.lo)
					break
				}
				font, size := prose_font(it.style, p.heading, p.size)
				fit := gfx.text_fit(&gfx.text_system, font, size, text[pc.lo:pc.hi], right - w.x)
				part := Piece{pc.item, pc.lo, pc.lo + fit, 0, gfx.text_width(&gfx.text_system, font, size, text[pc.lo:pc.lo + fit]), false, false, {}, false}
				place(&w, part)
				new_row(&w, pc.lo + fit)
				pc.lo += fit
				pc.w_word = gfx.text_width(&gfx.text_system, font, size, text[pc.lo:pc.hi])
				pc.w_full = pc.w_word
				if pc.lo >= pc.hi do break
			}
			if pc.lo < pc.hi do place(&w, pc)
		}
		i = j
	}
	finish_row(&w)

	// Images, each on its own below the text; a line of only images has no text row.
	has_text := false
	for r in L.runs do if r.kind != .Bullet do has_text = true
	for it in items {
		if it.kind != .Image do continue
		if !has_text && len(L.rows) == 1 {
			L.rows[0].h = 2
			w.y = L.rows[0].y + 2
			has_text = true
		}
		iw := min(it.size.x, right - w.x0)
		ih := it.size.x > 0 ? it.size.y * iw / it.size.x : it.size.y
		lo := i32(len(L.strings))
		append(&L.strings, it.subst)
		append(&L.images, Image_Box{path = {lo, i32(len(L.strings))}, alt = {it.lo, it.hi}, x = w.x0, y = w.y + 6, w = iw, h = ih})
		w.y += ih + 12
	}
	L.height = w.y + p.pad_bottom
}

@(private = "file")
place :: proc(w: ^Wrapper, pc: Piece) {
	L := w.L
	it := w.items[pc.item]
	font, size := prose_font(it.style, w.p.heading, w.p.size)
	row := i32(len(L.rows))
	if it.kind == .Checkbox {
		append(&L.runs, Run{lo = it.lo, hi = it.hi, x = w.x, w = pc.w_word, row = row, font = font, size = size, kind = .Checkbox, checked = it.checked})
		w.x += pc.w_full
		return
	}
	if n := len(L.runs); n > 0 {
		last := &L.runs[n - 1]
		if last.row == row && last.kind == .Text && last.hi == i32(pc.lo) && last.font == font && last.size == size && last.style == it.style && last.color == it.color && last.subst == {} && it.subst == "" && pc.pad == {} && abs(last.x + last.w - w.x) < 0.01 {
			last.hi = i32(pc.hi)
			last.w += pc.w_full
			w.x += pc.w_full
			return
		}
	}
	run := Run{lo = i32(pc.lo), hi = i32(pc.hi), x = w.x + pc.pad[0], w = pc.w_full - pc.pad[0] - pc.pad[1], row = row, font = font, size = size, style = it.style, color = it.color}
	if it.subst != "" {
		lo := i32(len(L.strings))
		append(&L.strings, it.subst)
		run.subst = {lo, i32(len(L.strings))}
	}
	append(&L.runs, run)
	w.x += pc.w_full
}

// Ends the current row and starts one at byte `lo`.
@(private = "file")
new_row :: proc(w: ^Wrapper, lo: int) {
	finish_row(w)
	w.row = Row{lo = i32(lo)}
	w.x = w.x0
}

@(private = "file")
finish_row :: proc(w: ^Wrapper) {
	L := w.L
	row := i32(len(L.rows))
	first := len(L.runs)
	for first > 0 && L.runs[first - 1].row == row do first -= 1
	h, top: f32
	measure :: proc(font: gfx.Font_Id, size: u16, factor: f32) -> (h, top: f32) {
		m := gfx.font_metrics(&gfx.text_system, font, size)
		h = math.round(f32(size) * factor)
		return h, centered_baseline(m, h)
	}
	// Words were measured one at a time; measure each run whole, as it is
	// drawn, and move the runs after it to match.
	shift: f32
	for &r in L.runs[first:] {
		if r.x < w.x0 - 0.5 do continue // a hanging marker or bullet
		r.x += shift
		if r.kind != .Text || r.subst != {} do continue
		whole := gfx.text_width(&gfx.text_system, r.font, r.size, w.text[r.lo:r.hi])
		shift += whole - r.w
		r.w = whole
	}
	h, top = measure(w.base.font, w.base.size, w.factor)
	for r in L.runs[first:] {
		if r.kind != .Text do continue
		rh, rt := measure(r.font, r.size, w.factor)
		h = max(h, rh)
		top = max(top, rt)
	}
	w.row.y = w.y
	w.row.h = max(h, top + gfx.font_metrics(&gfx.text_system, w.base.font, w.base.size).descent)
	w.row.baseline = top
	w.row.runs = {i32(first), i32(len(L.runs))}
	append(&L.rows, w.row)
	w.y += w.row.h
}

// --- Caret positions -------------------------------------------------------------------

// The row holding byte k of a line.
@(private)
row_of :: proc(L: ^Line_Layout, k: int) -> int {
	r := 0
	for r + 1 < len(L.rows) && int(L.rows[r + 1].lo) <= k do r += 1
	return r
}

// Width of run bytes [run.lo, k).
@(private = "file")
run_prefix_w :: proc(L: ^Line_Layout, run: Run, text: string, k: int) -> f32 {
	if k <= int(run.lo) do return 0
	if k >= int(run.hi) do return run.w
	#partial switch run.kind {
	case .Mono:
		return f32(textedit.visual_col(text[run.lo:run.hi], k - int(run.lo))) * L.char_w
	case .Text:
		if run.subst != {} do return run.w
		return gfx.text_width(&gfx.text_system, run.font, run.size, text[run.lo:k])
	case .Bullet, .Checkbox:
		return run.w
	}
	return 0
}

// Where a line's text starts, from the column's left: in a code block, past
// its padding and moved by its sideways scroll.
@(private = "file")
text_left :: proc(L: ^Line_Layout) -> f32 {
	if L.kind != .Code do return L.indent
	return L.indent + (L.code_bg != {} ? CODE_PAD : 0) - L.scroll
}

// Row and x (from the column's left) of the caret before byte k of a line.
@(private)
caret_row_x :: proc(L: ^Line_Layout, text: string, k: int) -> (row: int, x: f32) {
	if L.kind == .Table {
		x, _ = table_caret(L, text, k)
		return
	}
	row = row_of(L, k)
	r := L.rows[row]
	x = text_left(L)
	after := -1 // first run starting after k
	for ri in r.runs[0] ..< r.runs[1] {
		run := md_run(L, int(ri))
		if run.kind == .Bullet do continue
		if int(run.lo) <= k && k <= int(run.hi) && run.hi > run.lo {
			if run.kind == .Checkbox do return row, k <= int(run.lo) ? run.x : run.x + run.w
			return row, run.x + run_prefix_w(L, run, text, k)
		}
		// A marker hanging left of the content holds only carets within it.
		if hanging(L, run) do continue
		if int(run.lo) > k && after < 0 do after = int(ri)
		if int(run.hi) <= k do x = run.x + run.w
	}
	if after >= 0 do x = md_run(L, after).x
	return
}

// Where the caret before byte k of a line is drawn: its row, x, and the top
// and height of the line of text it is on (in a table cell, one of its lines).
@(private)
caret_box :: proc(L: ^Line_Layout, text: string, k: int) -> (row: int, x, top, h: f32) {
	if L.kind == .Table {
		dy: f32
		x, dy = table_caret(L, text, k)
		return 0, x, L.rows[0].y + CELL_VPAD + dy, L.cell_h
	}
	row, x = caret_row_x(L, text, k)
	return row, x, L.rows[row].y, L.rows[row].h
}

// The cell of a table row a caret before byte k is in, or nearest to.
@(private)
table_cell_at :: proc(L: ^Line_Layout, k: int) -> int {
	for c, i in L.cells do if k <= int(c[1]) do return i
	return len(L.cells) - 1
}

// How many lines of text the cell of a table row whose column holds x has.
@(private)
table_cell_lines :: proc(L: ^Line_Layout, x: f32) -> int {
	if len(L.cells) == 0 do return 1
	c := 0
	for c + 1 < len(L.cells) && x >= L.edges[c + 1] do c += 1
	cell := L.cells[c]
	n := 1
	for run in L.runs do if run.lo >= cell[0] && run.hi <= cell[1] do n = max(n, int(math.round(run.dy / max(L.cell_h, 1))) + 1)
	return n
}

// The x of the caret before byte k of a table row, and the line of its cell
// it is on (its offset below the first).
@(private = "file")
table_caret :: proc(L: ^Line_Layout, text: string, k: int) -> (x, dy: f32) {
	if len(L.cells) == 0 do return L.edges[0] + CELL_PAD, 0
	c := table_cell_at(L, k)
	cell := L.cells[c]
	k := clamp(k, int(cell[0]), int(cell[1]))
	x = L.edges[c] + CELL_PAD
	// After a line break, the caret is at the start of the next line.
	for run in L.runs do if run.lo == run.hi && int(run.lo) == k && run.lo >= cell[0] && run.hi <= cell[1] do return run.x, run.dy
	before, after := -1, -1 // runs of the cell ending at or before k, starting after it
	for run, i in L.runs {
		if run.lo < cell[0] || run.hi > cell[1] || run.hi <= run.lo do continue
		if int(run.lo) <= k && k <= int(run.hi) do return run.x + run_prefix_w(L, run, text, k), run.dy
		if int(run.hi) <= k do before = i
		if int(run.lo) > k && after < 0 do after = i
	}
	switch {
	case before >= 0: return L.runs[before].x + L.runs[before].w, L.runs[before].dy
	case after >= 0:  return L.runs[after].x, L.runs[after].dy
	}
	return
}

// The byte of a table row nearest to a point: in the cell whose column holds
// x, on the line of it nearest to y.
@(private = "file")
table_index_at :: proc(L: ^Line_Layout, text: string, x, y: f32) -> int {
	if len(L.cells) == 0 do return int(L.rows[0].lo)
	c := 0
	for c + 1 < len(L.cells) && x >= L.edges[c + 1] do c += 1
	cell := L.cells[c]
	line_y := max(math.floor((y - L.rows[0].y - CELL_VPAD) / max(L.cell_h, 1)), 0) * L.cell_h
	best, best_line, best_x := -1, max(f32), max(f32)
	for run, i in L.runs {
		// Empty runs are line breaks, the only run on an empty line.
		if run.lo < cell[0] || run.hi > cell[1] || run.hi < run.lo do continue
		dl := abs(run.dy - line_y)
		dx := x < run.x ? run.x - x : max(x - (run.x + run.w), 0)
		if dl < best_line || (dl == best_line && dx < best_x) do best, best_line, best_x = i, dl, dx
	}
	if best < 0 do return int(cell[1])
	run := L.runs[best]
	switch {
	case x <= run.x:          return int(run.lo)
	case x >= run.x + run.w:  return int(run.hi)
	case run.subst != {}:     return x - run.x < run.w / 2 ? int(run.lo) : int(run.hi)
	}
	return int(run.lo) + gfx.text_index_at(&gfx.text_system, run.font, run.size, text[run.lo:run.hi], x - run.x)
}

// The boxes a selection of line bytes [lo, hi] covers in a table row: a cell
// that it covers and goes past, whole (inside its borders); within a cell,
// each line of the cell's text from the selection's start to its end.
@(private)
table_selection :: proc(L: ^Line_Layout, text: string, lo, hi: int) -> []gfx.Rect {
	boxes := make([dynamic]gfx.Rect, context.temp_allocator)
	if len(L.rows) == 0 do return nil
	row := L.rows[0]
	for cell, c in L.cells {
		c_lo, c_hi := int(cell[0]), int(cell[1])
		if lo <= c_lo && hi >= c_hi && (lo < c_lo || hi > c_hi) {
			append(&boxes, gfx.Rect{L.edges[c] + 1, row.y, L.edges[c + 1] - L.edges[c] - 1, row.h - 1})
			continue
		}
		a, b := max(lo, c_lo), min(hi, c_hi)
		if a >= b do continue
		first := len(boxes)
		for run in L.runs {
			if run.lo < cell[0] || run.hi > cell[1] || run.hi <= run.lo do continue
			ra, rb := max(a, int(run.lo)), min(b, int(run.hi))
			if ra >= rb do continue
			x1 := run.x + run_prefix_w(L, run, text, ra)
			x2 := run.x + run_prefix_w(L, run, text, rb)
			y := row.y + CELL_VPAD + run.dy
			merged := false
			for &box in boxes[first:] do if box.y == y {
				right := max(box.x + box.w, x2)
				box.x = min(box.x, x1)
				box.w = right - box.x
				merged = true
			}
			if !merged do append(&boxes, gfx.Rect{x1, y, x2 - x1, L.cell_h})
		}
	}
	return boxes[:]
}

// The byte of a line nearest to a point (from the column's left and the line's top).
@(private)
index_at :: proc(L: ^Line_Layout, text: string, x, y: f32) -> int {
	row, k := index_in_row(L, text, x, y)
	// A wrapped row's last position is the next row's first; keep the caret on
	// this one, before the space it wrapped at.
	if row + 1 < len(L.rows) {
		end := int(L.rows[row + 1].lo)
		if k >= end && end > int(L.rows[row].lo) && (text[end - 1] == ' ' || text[end - 1] == '\t') do k = end - 1
	}
	return k
}

@(private = "file")
index_in_row :: proc(L: ^Line_Layout, text: string, x, y: f32) -> (row, k: int) {
	if L.kind == .Table do return 0, table_index_at(L, text, x, y)
	row = len(L.rows) - 1
	for r, i in L.rows {
		if y < r.y + r.h {
			row = i
			break
		}
	}
	r := L.rows[row]
	end := row + 1 < len(L.rows) ? int(L.rows[row + 1].lo) : len(text)
	best := -1
	best_d := max(f32)
	right: f32
	for ri in r.runs[0] ..< r.runs[1] {
		run := md_run(L, int(ri))
		if run.kind == .Bullet || run.hi <= run.lo do continue
		right = max(right, run.x + run.w)
		if x >= run.x && x <= run.x + run.w {
			#partial switch run.kind {
			case .Mono:
				return row, int(run.lo) + textedit.byte_at_col(text[run.lo:run.hi], int(math.round((x - run.x) / L.char_w)))
			case .Text:
				if run.subst != {} do return row, x - run.x < run.w / 2 ? int(run.lo) : int(run.hi)
				return row, int(run.lo) + gfx.text_index_at(&gfx.text_system, run.font, run.size, text[run.lo:run.hi], x - run.x)
			case .Checkbox:
				return row, int(run.hi)
			}
		}
		d := x < run.x ? run.x - x : x - (run.x + run.w)
		if d < best_d {
			best_d = d
			best = int(ri)
		}
	}
	if best < 0 do return row, int(r.lo)
	run := md_run(L, best)
	if x < run.x do return row, int(run.lo)
	if x < right do return row, int(run.hi)
	// Past the end of the row: the end of the line, after any hidden syntax.
	return row, end
}

// Whether a run is a bullet or marker hanging left of the content.
@(private)
hanging :: proc(L: ^Line_Layout, run: Run) -> bool {
	return run.kind != .Mono && run.x < L.indent - 0.5
}

// The first and last caret positions of a row's text.
@(private)
row_bounds :: proc(L: ^Line_Layout, row: int, text_len: int) -> (lo, hi: int) {
	r := L.rows[row]
	lo, hi = -1, int(r.lo)
	for ri in r.runs[0] ..< r.runs[1] {
		run := L.runs[ri]
		if run.kind == .Bullet || run.hi <= run.lo do continue
		if hanging(L, run) do continue
		if lo < 0 do lo = run.kind == .Checkbox ? int(run.hi) : int(run.lo)
		hi = int(run.hi)
	}
	if lo < 0 do lo = int(r.lo)
	if row == len(L.rows) - 1 do hi = max(hi, lo)
	return
}

// The x range a selection of line bytes [lo, hi] covers on a row.
@(private)
selection_span :: proc(L: ^Line_Layout, text: string, row, lo, hi: int) -> (x1, x2: f32, ok: bool) {
	last := row == len(L.rows) - 1
	row_lo := int(L.rows[row].lo)
	row_hi := last ? len(text) : int(L.rows[row + 1].lo)
	if hi < row_lo || lo > row_hi || (lo == row_hi && !last) do return
	_, x1 = caret_row_x(L, text, max(lo, row_lo))
	if hi < row_hi || last {
		_, x2 = caret_row_x(L, text, min(hi, row_hi))
		return x1, x2, true
	}
	// It continues past this row: cover to the row's end, since a caret at
	// row_hi is drawn on the next row.
	r := L.rows[row]
	x2 = x1
	for ri in r.runs[0] ..< r.runs[1] {
		run := md_run(L, int(ri))
		if !hanging(L, run) do x2 = max(x2, run.x + run.w)
	}
	return x1, x2, true
}

// --- Cache keys ---------------------------------------------------------------------------

@(private = "file")
hash_value :: proc(h: u64, v: $T) -> u64 {
	v := v
	return hash.fnv64a(mem.ptr_to_bytes(&v), h)
}

@(private)
layout_key :: proc(text: string, items: []Item, p: Params, col_w: f32) -> u64 {
	h := hash.fnv64a(transmute([]u8)text)
	for it in items {
		h = hash_value(h, [4]i32{it.lo, it.hi, i32(it.kind) | i32(it.hang) << 8 | i32(transmute(u8)it.style) << 16, i32(it.color) | i32(it.depth) << 8 | i32(it.checked) << 16 | i32(it.hidden) << 24})
		h = hash_value(h, it.x)
		h = hash_value(h, it.size)
		h = hash.fnv64a(transmute([]u8)it.subst, h)
	}
	h = hash_value(h, [4]i32{i32(p.kind), i32(p.size), i32(p.heading), i32(p.n_bars)})
	h = hash_value(h, [6]f32{p.indent, p.right, p.pad_top, p.pad_bottom, p.thin_h, col_w})
	h = hash_value(h, [3]bool{p.code_bg, p.round[0], p.round[1]})
	h = hash_value(h, p.bars)
	h = hash_value(h, p.header)
	h = hash_value(h, p.no_wrap)
	h = hash_value(h, p.code_block)
	if p.table != nil {
		h = hash_value(h, p.table.x)
		for x in p.table.edges do h = hash_value(h, x)
		h = hash.fnv64a(p.table.aligns, h)
	}
	for it in items do h = hash_value(h, it.cell)
	for c in p.cells do h = hash_value(h, c)
	h = hash_value(h, gfx.text_system.generation)
	h = hash_value(h, gfx.scale)
	h = hash_value(h, env.config().line_height)
	return h
}

// Lays out line i, through the caches.
@(private)
line_layout :: proc(e: ^View, i: int) -> ^Line_Layout {
	mv := &e.mdv
	begin_caches(e)
	if L, ok := mv.memo[i]; ok {
		if L.code_block >= 0 do L.scroll = mv.code_scroll[L.code_block]
		return L
	}
	text, start := line_text(e, i)
	items, p := md_items(e, i, text, start)
	key := layout_key(text, items, p, mv.col_w)
	L, found := mv.layouts[key]
	if !found {
		L = new(Line_Layout)
		md_layout(L, text, items, p)
		mv.layouts[key] = L
	}
	L.last_used = env.input().frame
	if L.code_block >= 0 do L.scroll = mv.code_scroll[L.code_block]
	mv.memo[i] = L
	return L
}

// Run k of a layout, at its x as shown (code scrolled sideways).
@(private)
md_run :: proc(L: ^Line_Layout, k: int) -> Run {
	run := L.runs[k]
	if run.kind == .Mono do run.x -= L.scroll
	return run
}

// Line i's text (capped), and its document offset.
@(private)
line_text :: proc(e: ^View, i: int) -> (text: string, start: int) {
	start = buffer.line_start(&e.buf, i)
	end := min(buffer.line_end(&e.buf, i), start + MAX_LAYOUT_BYTES)
	text = string(buffer.read_alloc(&e.buf, start, end))
	if end - start == MAX_LAYOUT_BYTES {
		// Don't split a character at the cap.
		k := len(text)
		for k > 0 && len(text) - k < utf8.UTF_MAX - 1 && !utf8.rune_start(text[k - 1]) do k -= 1
		if k > 0 && !utf8.full_rune_in_string(text[k - 1:]) do text = text[:k - 1]
	}
	return
}

@(private)
layout_destroy :: proc(L: ^Line_Layout) {
	delete(L.rows)
	delete(L.runs)
	delete(L.strings)
	delete(L.edges)
	delete(L.cells)
	delete(L.images)
	free(L)
}

// Colors of rendered Markdown.
@(private)
md_color :: proc(c: Color, hl: syntax.Highlight = .None) -> clay.Color {
	switch c {
	case .Text:    return gfx.theme.text
	case .Heading: return gfx.theme.md_heading
	case .Link:    return gfx.theme.md_link
	case .Marker:  return gfx.theme.md_marker
	case .Code:    return gfx.theme.syntax[hl]
	case .Dim:     return gfx.theme.text_dim
	case .Math:    return gfx.theme.syntax[.Number]
	case .Html:    return gfx.theme.syntax[.Attribute]
	}
	return gfx.theme.text
}
