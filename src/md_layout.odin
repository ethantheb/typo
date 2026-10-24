package editor

import "core:encoding/entity"
import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import "buffer"
import "markdown"
import "syntax"

// Layout of rendered Markdown. Each document line becomes rows of runs: styled
// text, monospace code, or a widget (bullet, task box). A line's syntax is
// split into items (shown or hidden bytes, widgets), which are then wrapped to
// the text column. Layouts are cached by a hash of everything they depend on,
// so typing re-lays out only the edited line and moving the caret only the
// lines whose syntax it reveals or hides.

MD_HEADING_LINE_FACTOR :: 1.3
MD_CODE_LINE_FACTOR :: 1.45
MD_HEADING_SCALE := [6]f32{2.0, 1.6, 1.35, 1.15, 1.0, 0.9}
MD_QUOTE_INDENT :: 22
MD_LIST_INDENT :: 26
MD_CODE_PAD :: 12 // inside a code block, left and right
MD_CODE_SPAN_PAD :: 5 // around a code span, for its background
MD_SETEXT_ROW :: 4 // a hidden setext underline
MD_TAB :: "    " // drawn for a tab in prose
// Bytes of a line laid out; the rest of an enormous line isn't shown.
MD_MAX_LAYOUT_BYTES :: 64 << 10
MD_CELL_PAD :: 10 // in a table cell, left and right
MD_CELL_VPAD :: 5 // ... top and bottom
// Rows measured for a table's column widths.
MD_TABLE_MAX_ROWS :: 500

Md_Style_Flag :: enum u8 {
	Strong,
	Em,
	Strike,
	Code, // a code span: monospace on a background
	Mark, // ==highlight==
	Underline,
	Super, // a footnote reference
}

Md_Style :: bit_set[Md_Style_Flag;u8]

Md_Color :: enum u8 {
	Text,
	Heading,
	Link,
	Marker,
	Code, // fenced code: colored by its language
	Dim,
	Math,
	Html,
}

Md_Run_Kind :: enum u8 {
	Text,
	Mono, // code on a column grid
	Bullet,
	Checkbox,
	Image, // an item only: laid out as an Md_Image_Box below the text
}

// An image below a line's text.
Md_Image_Box :: struct {
	path:       [2]i32, // in Line_Layout.strings
	alt:        [2]i32, // bytes of the line
	x, y, w, h: f32,
}

Md_Run :: struct {
	lo, hi:  i32, // bytes of the line
	x, w:    f32, // from the text column's left
	row:     i32,
	font:    Font_Id,
	size:    u16,
	kind:    Md_Run_Kind,
	style:   Md_Style,
	color:   Md_Color,
	depth:   u8,     // a bullet's list depth
	checked: bool,
	subst:   [2]i32, // text drawn in place of the bytes (a decoded entity), in Line_Layout.strings
	dy:      f32,    // below the row's baseline: a wrapped line within a table cell
}

// Rows partition a line's bytes: row r has [lo, next row's lo).
Md_Row :: struct {
	y, h, baseline: f32,
	lo:             i32,
	runs:           [2]i32, // range in Line_Layout.runs
}

Md_Line_Kind :: enum u8 {
	Prose,
	Code,
	Thin, // a hidden fence or underline: a short empty row
	Rule, // a thematic break
	Table, // a table row, its cells on the table's columns
}

Line_Layout :: struct {
	rows:      [dynamic]Md_Row,
	runs:      [dynamic]Md_Run,
	strings:   [dynamic]u8,
	height:    f32,
	kind:      Md_Line_Kind,
	indent:    f32,    // content start, from the column's left
	code_bg:   [2]f32, // x range of a code block background; {0, 0} = none
	round:     [2]bool, // round its top / bottom corners
	bars:      [markdown.MAX_DEPTH]f32, // quote bar x positions
	n_bars:    int,
	char_w:    f32, // of Mono runs
	edges:     [dynamic]f32, // a table's column edges
	header:    bool,         // a table's header row
	images:    [dynamic]Md_Image_Box,
	last_used: u64,
}

Md_Hang :: enum u8 {
	None,
	Left,  // drawn starting at x, left of the content
	Right, // drawn ending at x
}

// One part of a line, before wrapping.
Md_Item :: struct {
	lo, hi:  i32,
	kind:    Md_Run_Kind,
	hidden:  bool,
	hang:    Md_Hang,
	x:       f32,
	style:   Md_Style,
	color:   Md_Color,
	depth:   u8,
	checked: bool,
	subst:   string, // also an image's path
	cell:    i8, // a table cell
	size:    [2]f32, // an image's, or its placeholder's
}

Md_Params :: struct {
	kind:       Md_Line_Kind,
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
	table:      ^Md_Table,
	header:     bool,
	no_wrap:    bool, // a code block line: one row, scrolled sideways by `scroll`
	scroll:     f32,
}

// A table's columns, shared by the layouts of its rows.
Md_Table :: struct {
	first, last: int,   // lines: the header to the last row
	x:           f32,   // left edge, from the text column's left
	edges:       []f32, // column edges from x, one more than the columns
	aligns:      []u8,  // per column: 0 left, 1 center, 2 right
}

md_font_size :: proc() -> u16 {
	return u16(g.settings.markdown_font_size)
}

md_code_size :: proc(size: u16) -> u16 {
	return max(u16(math.round(f32(size) * 0.88)), 8)
}

// Line height of rendered text, as a multiple of its size.
md_line_factor :: proc() -> f32 {
	return f32(g.settings.markdown_line_height)
}

// A code block's first or last line: a code row and the block's padding.
md_fence_row_height :: proc() -> f32 {
	return math.round(f32(md_code_size(md_font_size())) * MD_CODE_LINE_FACTOR) + 6
}

md_body_line_height :: proc() -> f32 {
	return f32(md_font_size()) * md_line_factor()
}

@(private = "file")
heading_size :: proc(level: u8) -> u16 {
	return u16(math.round(f32(md_font_size()) * MD_HEADING_SCALE[clamp(int(level), 1, 6) - 1]))
}

// --- Items -----------------------------------------------------------------------------

// A paragraph's (or heading's) inline spans, parsed once per frame.
Md_Block :: struct {
	bt:    markdown.Block_Text,
	spans: []markdown.Span,
}

md_block :: proc(e: ^Editor, i: int) -> ^Md_Block {
	first, last, ok := markdown.block_extent(e.md, i)
	if !ok do return nil
	mv := &e.mdv
	if b, found := mv.blocks[first]; found do return b
	context.temp_allocator = mv.doc_allocator
	b := new(Md_Block, mv.doc_allocator)
	b.bt = markdown.block_text(e.md, &e.buf, first, last)
	spans := make([dynamic]markdown.Span, mv.doc_allocator)
	markdown.inline_parse(b.bt.text, markdown.doc_labels(e.md, &e.buf), &spans)
	b.spans = spans[:]
	mv.blocks[first] = b
	return b
}

@(private = "file")
Item_Builder :: struct {
	items:  [dynamic]Md_Item,
	// Per byte of the line, for the inline content.
	hidden: []bool,
	style:  []Md_Style,
	color:  []Md_Color,
	subst:  []string, // text replacing bytes [i, subst_end[i])
	subst_end: []i32,
	cell:   i8, // given to the items flush_bytes adds
}

@(private = "file")
add_item :: proc(ib: ^Item_Builder, it: Md_Item) {
	if it.hi > it.lo || it.kind != .Text do append(&ib.items, it)
}

@(private = "file")
hide :: proc(ib: ^Item_Builder, lo, hi: int) {
	if hi > lo do append(&ib.items, Md_Item{lo = i32(lo), hi = i32(hi), hidden = true})
}

// The baseline that centres a font's text in a row h high.
@(private = "file")
centered_baseline :: proc(m: Font_Metrics, h: f32) -> f32 {
	return (h - (m.ascent + m.descent)) / 2 + m.ascent
}

// Gives the builder per-byte looks for a line of n bytes.
@(private = "file")
item_builder_bytes :: proc(ib: ^Item_Builder, n: int) {
	ib.hidden = make([]bool, n, context.temp_allocator)
	ib.style = make([]Md_Style, n, context.temp_allocator)
	ib.color = make([]Md_Color, n, context.temp_allocator)
	ib.subst = make([]string, n, context.temp_allocator)
	ib.subst_end = make([]i32, n, context.temp_allocator)
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
@(private = "file")
flush_bytes :: proc(ib: ^Item_Builder, lo, hi: int) {
	k := lo
	for k < hi {
		if ib.subst[k] != "" {
			append(&ib.items, Md_Item{lo = i32(k), hi = ib.subst_end[k], subst = ib.subst[k], style = ib.style[k], color = ib.color[k], cell = ib.cell})
			k = int(ib.subst_end[k])
			continue
		}
		j := k + 1
		for j < hi && ib.hidden[j] == ib.hidden[k] && ib.style[j] == ib.style[k] && ib.color[j] == ib.color[k] && ib.subst[j] == "" do j += 1
		append(&ib.items, Md_Item{lo = i32(k), hi = i32(j), hidden = ib.hidden[k], style = ib.style[k], color = ib.color[k], cell = ib.cell})
		k = j
	}
}

// Which kind of code block a line belongs to: 1 fenced, 2 indented, 3 math,
// 4 front matter; 0 none.
code_group :: proc(k: markdown.Line_Kind) -> int {
	#partial switch k {
	case .Fence_Open, .Fence_Body, .Fence_Close:             return 1
	case .Indented_Code:                                       return 2
	case .Math_Fence, .Math_Body:                              return 3
	case .Front_Matter_Fence, .Front_Matter_Body:              return 4
	}
	return 0
}

// The lines of the fenced block (code, math or front matter) containing line i.
md_fenced_block :: proc(doc: ^markdown.Doc, i: int) -> (first, last: int) {
	MAX :: 5000
	opening :: proc(doc: ^markdown.Doc, k: int) -> bool {
		#partial switch doc.lines[k].kind {
		case .Fence_Open:         return true
		case .Math_Fence:         return markdown.line_state(doc, k).leaf == .Math
		case .Front_Matter_Fence: return markdown.line_state(doc, k).leaf == .Front_Matter
		}
		return false
	}
	closing :: proc(doc: ^markdown.Doc, k: int) -> bool {
		#partial switch doc.lines[k].kind {
		case .Fence_Close:        return true
		case .Math_Fence:         return markdown.line_state(doc, k).leaf != .Math
		case .Front_Matter_Fence: return markdown.line_state(doc, k).leaf != .Front_Matter
		}
		return false
	}
	group := code_group(doc.lines[i].kind)
	first = i
	for !opening(doc, first) && first > 0 && i - first < MAX && code_group(doc.lines[first - 1].kind) == group && !closing(doc, first - 1) {
		first -= 1
	}
	last = i
	for !closing(doc, last) && last + 1 < len(doc.lines) && last - i < MAX && code_group(doc.lines[last + 1].kind) == group && !opening(doc, last + 1) {
		last += 1
	}
	return
}

// Splits line i into items and picks how it is laid out.
@(private = "file")
md_items :: proc(e: ^Editor, i: int, text: string, start: int) -> (items: []Md_Item, p: Md_Params) {
	doc := e.md
	info := doc.lines[i]
	d := markdown.line_detail(doc, i, text)
	state := markdown.line_state(doc, i)
	n := len(text)
	p.size = md_font_size()
	p.right = e.mdv.col_w
	revealed := md_touches(e, start, start + n)

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
			x += MD_QUOTE_INDENT
		} else {
			x += MD_LIST_INDENT
			lists += 1
		}
		content_x[k] = x
		list_depth[k] = lists
	}
	if info.kind == .Blank do p.n_bars = 0 // a blank line ends a quote
	p.indent = x

	ib := Item_Builder{items = make([dynamic]Md_Item, context.temp_allocator)}
	pos := 0
	for m in d.marks[:d.n_marks] {
		hide(&ib, pos, int(m.lo))
		k := int(m.container)
		touched := md_touches(e, start + int(m.lo), start + int(m.hi))
		switch m.kind {
		case .Quote:
			if revealed {
				add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Left, x = content_x[k] - MD_QUOTE_INDENT, color = .Marker})
			} else {
				hide(&ib, int(m.lo), int(m.hi))
			}
		case .Bullet:
			if touched {
				add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Right, x = content_x[k] - 8, color = .Marker})
			} else {
				add_item(&ib, {lo = m.lo, hi = m.hi, kind = .Bullet, x = content_x[k] - MD_LIST_INDENT / 2 - 2, depth = list_depth[k]})
			}
		case .Ordered:
			add_item(&ib, {lo = m.lo, hi = m.hi, hang = .Right, x = content_x[k] - 7, color = touched ? .Marker : .Dim})
		}
		pos = int(m.hi)
	}
	content := int(d.content[0])
	// After a list marker, spaces beyond the first are shown.
	if d.n_marks > 0 && d.marks[d.n_marks - 1].kind != .Quote && pos < content {
		hide(&ib, pos, pos + 1)
		for k in pos + 1 ..< content do add_item(&ib, {lo = i32(k), hi = i32(k + 1), subst = text[k] == '\t' ? MD_TAB : ""})
		pos = content
	}
	if d.task != {} {
		hide(&ib, pos, int(d.task[0]))
		pos = int(d.task[1])
		if md_touches(e, start + int(d.task[0]), start + int(d.task[1])) {
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

	if b, ok := md_code_block(e, i); ok {
		first, last := b.first, b.last
		p.code_bg = true
		p.round = {i == first, i == last}
		is_fence := info.kind == .Fence_Open || info.kind == .Fence_Close || info.kind == .Math_Fence || info.kind == .Front_Matter_Fence
		if is_fence && !md_touches(e, buffer.line_start(&e.buf, first), buffer.line_start(&e.buf, last) + int(doc.lines[last].len)) {
			// As tall as when shown, so revealing the fences moves nothing; the
			// opening one shows the language.
			p.kind = .Thin
			p.thin_h = md_fence_row_height()
			if info.kind == .Fence_Open && d.info[1] > d.info[0] {
				hide(&ib, content, int(d.info[0]))
				add_item(&ib, {lo = d.info[0], hi = d.info[1], hang = .Right, x = p.right - MD_CODE_PAD, color = .Dim})
				hide(&ib, int(d.info[1]), n)
			} else {
				hide(&ib, content, n)
			}
		} else {
			p.kind = .Code
			p.no_wrap = true
			p.scroll = e.mdv.code_scroll[first]
			// Colored by language only when the fence names one.
			color := Md_Color.Code
			switch {
			case is_fence:                                       color = .Marker
			case info.kind == .Math_Body:                        color = .Math
			case code_group(info.kind) == 4:                     color = .Dim
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
			if info.kind == .Setext_Underline do p.kind, p.thin_h = .Thin, MD_SETEXT_ROW
		}
		return ib.items[:], p
	case .Link_Ref_Def:
		add_item(&ib, {lo = i32(content), hi = i32(n), color = .Dim})
		return ib.items[:], p
	case .Blank:
		// Its spaces only while being edited.
		if revealed {
			for k in content ..< n do add_item(&ib, {lo = i32(k), hi = i32(k + 1), subst = text[k] == '\t' ? MD_TAB : ""})
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
	color := Md_Color.Text
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
		p.pad_top = f32(p.size) * (heading <= 2 ? 0.7 : 0.5)
		p.pad_bottom = f32(p.size) * 0.15
	}

	item_builder_bytes(&ib, n)
	for &c in ib.color[content:content_hi] do c = color
	if info.kind == .Footnote_Def && d.label[1] > 0 {
		// "[^label]:" before the text.
		for k in max(int(d.label[0]) - 2, 0) ..< min(int(d.label[1]) + 2, n) do ib.color[k] = .Link
		content = max(int(d.label[0]) - 2, content)
	}

	images := make([dynamic]Md_Item, context.temp_allocator)
	if b := md_block(e, i); b != nil {
		seg := b.bt.segs[i - b.bt.first]
		line_off := seg.doc_lo - start - seg.lo // block text position -> line byte
		for s in b.spans {
			if int(s.hi) < seg.lo || int(s.lo) > seg.hi do continue
			touched := md_touches(e, markdown.block_to_doc(&b.bt, int(s.lo)), markdown.block_to_doc(&b.bt, int(s.hi)))
			apply_span(&ib, s, line_off, seg.lo, seg.hi, touched, text)
			// An image starting on this line: shown below it, its syntax hidden
			// unless touched.
			if s.kind == .Image && int(s.lo) >= seg.lo {
				dest := b.bt.text[s.url[0]:s.url[1]]
				if s.reference do dest, _ = markdown.reference_destination(doc, &e.buf, dest)
				path := md_image_path(e, dest)
				img := md_image(path)
				lo, hi := int(s.lo) + line_off, min(int(s.hi), seg.hi) + line_off
				if !touched do for k in lo ..< hi do ib.hidden[k] = true
				size := [2]f32{260, img.state == .Loading ? 140 : 72}
				if img.state == .Ready do size = {f32(img.w), f32(img.h)}
				append(&images, Md_Item{lo = i32(int(s.open_hi) + line_off), hi = i32(min(int(s.close_lo), seg.hi) + line_off), kind = .Image, subst = path, size = size, checked = img.state == .Failed})
			}
		}
	}
	for k in content ..< content_hi {
		if text[k] == '\t' && !ib.hidden[k] && ib.subst[k] == "" do ib.subst[k], ib.subst_end[k] = MD_TAB, i32(k + 1)
	}
	flush_bytes(&ib, content, content_hi)
	marker_or_hide(&ib, content_hi, n, revealed)
	append(&ib.items, ..images[:])
	return ib.items[:], p
}

// --- Tables --------------------------------------------------------------------------------

// Byte ranges of a table row's cells (without the pipes), from `content`.
table_cells :: proc(text: string, content: int) -> [][2]int {
	cells := make([dynamic][2]int, context.temp_allocator)
	i := content
	for i < len(text) && (text[i] == ' ' || text[i] == '\t') do i += 1
	if i < len(text) && text[i] == '|' do i += 1
	lo := i
	for k := i; k <= len(text); k += 1 {
		if k < len(text) && text[k] == '\\' {
			k += 1
			continue
		}
		if k < len(text) && text[k] != '|' do continue
		// Nothing after a closing pipe.
		if k >= len(text) && len(cells) > 0 && strings.trim_space(text[lo:]) == "" do break
		append(&cells, [2]int{lo, min(k, len(text))})
		lo = k + 1
	}
	return cells[:]
}

// The table containing line i (its header, delimiter row or a body row), with
// column widths from its cells' text; nil if i isn't in one.
md_table :: proc(e: ^Editor, i: int) -> ^Md_Table {
	doc := e.md
	delim := -1
	#partial switch doc.lines[i].kind {
	case .Table_Delim:
		delim = i
	case .Table_Row:
		for k := i - 1; k >= 0 && i - k <= MD_TABLE_MAX_ROWS * 4; k -= 1 {
			if doc.lines[k].kind == .Table_Delim {
				delim = k
				break
			}
			if doc.lines[k].kind != .Table_Row do break
		}
	case .Paragraph:
		if markdown.is_table_header(doc, i) do delim = i + 1
	}
	if delim < 1 do return nil
	mv := &e.mdv
	if t, ok := mv.tables[delim]; ok do return t
	context.temp_allocator = mv.doc_allocator
	t := new(Md_Table, mv.doc_allocator)
	mv.tables[delim] = t
	t.first, t.last = delim - 1, delim
	for t.last + 1 < len(doc.lines) && doc.lines[t.last + 1].kind == .Table_Row do t.last += 1
	cols := max(int(doc.lines[delim].aux), 1)
	t.aligns = make([]u8, cols, mv.doc_allocator)
	delim_text, _ := md_line_text(e, delim)
	for c, k in table_cells(delim_text, int(markdown.line_detail(doc, delim, delim_text).content[0])) {
		if k >= cols do break
		cell := strings.trim_space(delim_text[c[0]:c[1]])
		left, right := strings.has_prefix(cell, ":"), strings.has_suffix(cell, ":")
		t.aligns[k] = left && right ? 1 : (right ? 2 : 0)
	}

	size := md_font_size()
	widths := make([]f32, cols, context.temp_allocator)
	for line in t.first ..= min(t.last, t.first + MD_TABLE_MAX_ROWS) {
		if line == delim do continue
		text, _ := md_line_text(e, line)
		content := int(markdown.line_detail(doc, line, text).content[0])
		font: Font_Id = line == t.first ? .Md_Bold : .Md_Regular
		for c, k in table_cells(text, content) {
			if k >= cols do break
			widths[k] = max(widths[k], text_width(&g.text, font, size, shown_cell_text(strings.trim_space(text[c[0]:c[1]]))))
		}
	}
	total: f32
	for &w in widths {
		w = max(w + 2 * MD_CELL_PAD, 3 * MD_CELL_PAD)
		total += w
	}
	// Within the text column if it fits, else wider (centered in the pane),
	// and shrunk to fit the pane if even that isn't enough.
	full := max(e.view.w - 2 * MD_COLUMN_PAD, mv.col_w)
	if total > full {
		for &w in widths do w *= full / total
		total = full
	}
	t.x = total <= mv.col_w ? 0 : math.round((mv.col_w - total) / 2)
	t.edges = make([]f32, cols + 1, mv.doc_allocator)
	for w, k in widths do t.edges[k + 1] = t.edges[k] + math.round(w)
	return t
}

// A cell's text without its inline syntax, to measure.
@(private = "file")
shown_cell_text :: proc(cell: string) -> string {
	spans := make([dynamic]markdown.Span, context.temp_allocator)
	markdown.inline_parse(cell, nil, &spans)
	if len(spans) == 0 do return cell
	keep := make([]bool, len(cell), context.temp_allocator)
	for &k in keep do k = true
	for s in spans {
		if s.kind == .Html || s.kind == .Entity do continue
		for k in s.lo ..< s.open_hi do keep[k] = false
		for k in s.close_lo ..< s.hi do keep[k] = false
	}
	sb := strings.builder_make(context.temp_allocator)
	for k in 0 ..< len(cell) do if keep[k] do strings.write_byte(&sb, cell[k])
	return strings.to_string(sb)
}

// Items of a table line: its source when a selection is in the table, else
// cells on the table's columns (the delimiter row as a thin rule).
@(private = "file")
table_items :: proc(e: ^Editor, ib: ^Item_Builder, p: ^Md_Params, i: int, text: string, start, content: int) {
	n := len(text)
	t := md_table(e, i)
	kind := e.md.lines[i].kind
	if t == nil || md_touches(e, buffer.line_start(&e.buf, t.first), buffer.line_end(&e.buf, t.last)) {
		p.kind = .Code
		add_item(ib, {lo = i32(content), hi = i32(n), kind = .Mono, color = kind == .Table_Delim ? .Marker : .Text})
		return
	}
	p.table = t
	if kind == .Table_Delim {
		p.kind = .Thin
		p.thin_h = 2
		hide(ib, content, n)
		return
	}
	p.kind = .Table
	p.header = i == t.first
	item_builder_bytes(ib, n)
	pos := content
	spans := make([dynamic]markdown.Span, context.temp_allocator)
	labels := markdown.doc_labels(e.md, &e.buf)
	for c, k in table_cells(text, content) {
		if k >= len(t.edges) - 1 do break
		lo, hi := c[0], c[1]
		for lo < hi && (text[lo] == ' ' || text[lo] == '\t') do lo += 1
		for hi > lo && (text[hi - 1] == ' ' || text[hi - 1] == '\t') do hi -= 1
		hide(ib, pos, lo)
		if p.header do for &s in ib.style[lo:hi] do s += {.Strong}
		clear(&spans)
		markdown.inline_parse(text[lo:hi], labels, &spans)
		for s in spans do apply_span(ib, s, lo, 0, hi - lo, false, text)
		ib.cell = i8(k)
		flush_bytes(ib, lo, hi)
		pos = hi
	}
	hide(ib, pos, n)
}

@(private = "file")
layout_table :: proc(L: ^Line_Layout, text: string, items: []Md_Item, p: ^Md_Params) {
	t := p.table
	size := p.size
	lh := math.round(f32(size) * md_line_factor())
	m := font_metrics(&g.text, .Md_Regular, size)
	top := centered_baseline(m, lh)
	lines := 1
	for c in 0 ..< len(t.edges) - 1 {
		x0 := t.x + t.edges[c] + MD_CELL_PAD
		x1 := t.x + t.edges[c + 1] - MD_CELL_PAD
		pieces := build_pieces(items, text, p, c)
		x := x0
		line := 0
		first_run := len(L.runs)
		i := 0
		for i < len(pieces) {
			j := i + 1
			for j < len(pieces) && pieces[j].glue do j += 1
			word: f32
			for k in i ..< j do word += k == j - 1 ? pieces[k].w_word : pieces[k].w_full
			if x + word > x1 && x > x0 {
				align_cell(L, first_run, x - x0, x1 - x0, t.aligns[c])
				line += 1
				x = x0
				first_run = len(L.runs)
			}
			for k in i ..< j {
				pc := pieces[k]
				it := items[pc.item]
				font, fsize := prose_font(it.style, 0, size)
				append(&L.runs, Md_Run{lo = i32(pc.lo), hi = i32(pc.hi), x = x + pc.pad[0], w = pc.w_full - pc.pad[0] - pc.pad[1], font = font, size = fsize, style = it.style, color = it.color, dy = f32(line) * lh})
				x += pc.w_full
			}
			i = j
		}
		align_cell(L, first_run, x - x0, x1 - x0, t.aligns[c])
		lines = max(lines, line + 1)
	}
	h := f32(lines) * lh + 2 * MD_CELL_VPAD
	append(&L.rows, Md_Row{h = h, baseline = MD_CELL_VPAD + top, runs = {0, i32(len(L.runs))}})
	L.height = h
	L.header = p.header
	for edge in t.edges do append(&L.edges, t.x + edge)
}

// Moves the runs of one line in a cell for the column's alignment.
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
// shown dimmed when touched by a selection), its content styled.
@(private = "file")
apply_span :: proc(ib: ^Item_Builder, s: markdown.Span, line_off, seg_lo, seg_hi: int, touched: bool, text: string) {
	n := len(ib.hidden)
	to_line :: proc(pos: i32, line_off, seg_lo, seg_hi, n: int) -> int {
		return clamp(clamp(int(pos), seg_lo, seg_hi) + line_off, 0, n)
	}
	lo := to_line(s.lo, line_off, seg_lo, seg_hi, n)
	open_hi := to_line(s.open_hi, line_off, seg_lo, seg_hi, n)
	close_lo := to_line(s.close_lo, line_off, seg_lo, seg_hi, n)
	hi := to_line(s.hi, line_off, seg_lo, seg_hi, n)

	marker :: proc(ib: ^Item_Builder, lo, hi: int, touched: bool) {
		for k in lo ..< hi {
			if touched {
				ib.color[k] = .Marker
			} else {
				ib.hidden[k] = true
			}
		}
	}
	add_style :: proc(ib: ^Item_Builder, lo, hi: int, st: Md_Style) {
		for k in lo ..< hi do ib.style[k] += st
	}
	set_color :: proc(ib: ^Item_Builder, lo, hi: int, c: Md_Color) {
		for k in lo ..< hi do if ib.color[k] != .Marker do ib.color[k] = c
	}

	switch s.kind {
	case .Emph:      add_style(ib, open_hi, close_lo, {.Em})
	case .Strong:    add_style(ib, open_hi, close_lo, {.Strong})
	case .Strike:    add_style(ib, open_hi, close_lo, {.Strike})
	case .Highlight: add_style(ib, open_hi, close_lo, {.Mark})
	case .Code:      add_style(ib, open_hi, close_lo, {.Code})
	case .Math:
		add_style(ib, open_hi, close_lo, {.Code})
		set_color(ib, open_hi, close_lo, .Math)
	case .Html:
		set_color(ib, lo, hi, .Html)
		return
	case .Link, .Wikilink, .Image:
		add_style(ib, open_hi, close_lo, {.Underline})
		set_color(ib, open_hi, close_lo, .Link)
	case .Autolink, .Url:
		add_style(ib, open_hi, close_lo, {.Underline})
		set_color(ib, open_hi, close_lo, .Link)
	case .Footnote_Ref:
		add_style(ib, open_hi, close_lo, {.Super})
		set_color(ib, open_hi, close_lo, .Link)
	case .Escape, .Hard_Break:
	case .Entity:
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
	marker(ib, lo, open_hi, touched)
	marker(ib, close_lo, hi, touched)
}

// --- Wrapping ------------------------------------------------------------------------

// The font for prose with a style, at a text size.
@(private = "file")
prose_font :: proc(st: Md_Style, heading: u8, size: u16) -> (Font_Id, u16) {
	if .Code in st do return .Editor, md_code_size(size)
	bold := .Strong in st || heading > 0
	italic := .Em in st
	f: Font_Id
	switch {
	case bold && italic:                     f = .Md_Bold_Italic
	case italic:                             f = .Md_Italic
	case heading > 0 && .Strong not_in st && heading > 2: f = .Md_SemiBold
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
}

// Splits the shown items (of one table cell, if cell >= 0) into pieces: words,
// split where the style changes; "glue" joins the parts of one word.
@(private = "file")
build_pieces :: proc(items: []Md_Item, text: string, p: ^Md_Params, cell := -1) -> []Piece {
	pieces := make([dynamic]Piece, context.temp_allocator)
	for it, idx in items {
		if it.hidden || it.kind == .Bullet || it.kind == .Image || it.hang != .None do continue
		if cell >= 0 && int(it.cell) != cell do continue
		font, size := prose_font(it.style, p.heading, p.size)
		prev_space := len(pieces) == 0 || pieces[len(pieces) - 1].space_after
		if it.kind == .Checkbox {
			box := f32(p.size) * 0.95
			append(&pieces, Piece{idx, int(it.lo), int(it.hi), box, box + f32(p.size) * 0.4, true, false, {}})
			continue
		}
		if it.subst != "" {
			sw := text_width(&g.text, font, size, it.subst)
			append(&pieces, Piece{idx, int(it.lo), int(it.hi), sw, sw, false, !prev_space, {}})
			continue
		}
		s := text[it.lo:it.hi]
		k := 0
		for k < len(s) {
			j := k
			for j < len(s) && s[j] != ' ' && s[j] != '\t' do j += 1
			e := j
			for e < len(s) && (s[e] == ' ' || s[e] == '\t') do e += 1
			ww := text_width(&g.text, font, size, s[k:j])
			wf := e > j ? text_width(&g.text, font, size, s[k:e]) : ww
			glue := k == 0 && !prev_space
			pad: [2]f32
			if .Code in it.style {
				if k == 0 do pad[0] = MD_CODE_SPAN_PAD
				if e == len(s) do pad[1] = MD_CODE_SPAN_PAD
			}
			append(&pieces, Piece{idx, int(it.lo) + k, int(it.lo) + e, ww + pad[0] + pad[1], wf + pad[0] + pad[1], e > j, glue, pad})
			prev_space = e > j
			k = e
		}
	}
	return pieces[:]
}

@(private = "file")
Wrapper :: struct {
	L:       ^Line_Layout,
	p:       ^Md_Params,
	text:    string,
	items:   []Md_Item,
	x0:      f32,
	x:       f32,
	y:       f32,
	row:     Md_Row,
	base:    struct {
		font: Font_Id,
		size: u16,
	},
	factor:  f32,
}

// Lays out a line's items.
md_layout :: proc(L: ^Line_Layout, text: string, items: []Md_Item, p: Md_Params) {
	clear(&L.rows)
	clear(&L.runs)
	clear(&L.strings)
	L.kind = p.kind
	L.indent = p.indent
	L.round = p.round
	L.bars = p.bars
	L.n_bars = p.n_bars
	L.code_bg = p.code_bg ? {p.indent, p.right} : {}
	L.header = false
	clear(&L.edges)
	clear(&L.images)
	p := p
	switch p.kind {
	case .Thin:
		append(&L.rows, Md_Row{h = p.thin_h})
		L.height = p.thin_h
		add_hanging(L, text, items, &p)
		// A label at the right (a code block's language), small and centred.
		for it in items {
			if it.hidden || it.hang != .Right || it.x <= p.indent do continue
			size := md_code_size(p.size) - 1
			m := font_metrics(&g.text, .Md_Regular, size)
			w := text_width(&g.text, .Md_Regular, size, text[it.lo:it.hi])
			L.rows[0].baseline = centered_baseline(m, p.thin_h)
			append(&L.runs, Md_Run{lo = it.lo, hi = it.hi, x = it.x - w, w = w, font = .Md_Regular, size = size, color = it.color})
			L.rows[0].runs = {0, i32(len(L.runs))}
		}
		if p.table != nil do for edge in p.table.edges do append(&L.edges, p.table.x + edge)
	case .Rule:
		h := f32(p.size) * md_line_factor()
		append(&L.rows, Md_Row{h = h, baseline = h / 2})
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
layout_code :: proc(L: ^Line_Layout, text: string, items: []Md_Item, p: ^Md_Params) {
	size := md_code_size(p.size)
	cw := max(text_char_width(&g.text, .Editor, size), 1)
	L.char_w = cw
	m := font_metrics(&g.text, .Editor, size)
	row_h := math.round(f32(size) * MD_CODE_LINE_FACTOR)
	baseline := centered_baseline(m, row_h)
	pad_top := p.round[0] && p.code_bg ? f32(6) : 0
	pad_bottom := p.round[1] && p.code_bg ? f32(6) : 0
	x0 := p.indent + (p.code_bg ? MD_CODE_PAD : 0)
	cols := max(int((p.right - x0 - (p.code_bg ? MD_CODE_PAD : 0)) / cw), 8)
	if p.no_wrap {
		cols = max(int)
		x0 -= p.scroll
	}
	y := pad_top
	append(&L.rows, Md_Row{y = y, h = row_h, baseline = baseline})
	add_hanging(L, text, items, p)
	for it in items {
		if it.hidden || it.kind != .Mono do continue
		lo := int(it.lo)
		col, row_col := 0, 0
		k := lo
		for r, j in text[lo:it.hi] {
			next := next_col(col, r)
			if next - row_col > cols && k < lo + j {
				add_mono(L, it, k, lo + j, x0, row_col, col, cw, size)
				L.rows[len(L.rows) - 1].runs[1] = i32(len(L.runs))
				y += row_h
				append(&L.rows, Md_Row{y = y, h = row_h, baseline = baseline, lo = i32(lo + j), runs = {i32(len(L.runs)), i32(len(L.runs))}})
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
add_mono :: proc(L: ^Line_Layout, it: Md_Item, lo, hi: int, x0: f32, row_col, col: int, cw: f32, size: u16) {
	if hi <= lo do return
	append(&L.runs, Md_Run{
		lo = i32(lo), hi = i32(hi), x = x0, w = f32(col - row_col) * cw, row = i32(len(L.rows) - 1),
		font = .Editor, size = size, kind = .Mono, color = it.color,
	})
}

// Bullets and list or quote markers, which hang left of the content, as runs
// of the first row.
@(private = "file")
add_hanging :: proc(L: ^Line_Layout, text: string, items: []Md_Item, p: ^Md_Params) {
	for it in items {
		if it.hidden do continue
		switch {
		case it.kind == .Bullet:
			font, size := prose_font({}, p.heading, p.size)
			append(&L.runs, Md_Run{lo = it.lo, hi = it.hi, x = it.x - f32(size) * 0.25, w = f32(size) * 0.5, font = font, size = size, kind = .Bullet, depth = it.depth})
		case it.hang != .None && it.x <= p.indent:
			font, size := prose_font(it.style, p.heading, p.size)
			tw := text_width(&g.text, font, size, text[it.lo:it.hi])
			x := it.hang == .Right ? it.x - tw : it.x
			append(&L.runs, Md_Run{lo = it.lo, hi = it.hi, x = x, w = tw, font = font, size = size, color = it.color})
		}
	}
}

@(private = "file")
layout_prose :: proc(L: ^Line_Layout, text: string, items: []Md_Item, p: ^Md_Params) {
	w := Wrapper{L = L, p = p, text = text, items = items, x0 = p.indent, x = p.indent, y = p.pad_top}
	w.factor = p.heading > 0 ? MD_HEADING_LINE_FACTOR : md_line_factor()
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
				fit := text_fit(&g.text, font, size, text[pc.lo:pc.hi], right - w.x)
				part := Piece{pc.item, pc.lo, pc.lo + fit, 0, text_width(&g.text, font, size, text[pc.lo:pc.lo + fit]), false, false, {}}
				place(&w, part)
				new_row(&w, pc.lo + fit)
				pc.lo += fit
				pc.w_word = text_width(&g.text, font, size, text[pc.lo:pc.hi])
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
		append(&L.images, Md_Image_Box{path = {lo, i32(len(L.strings))}, alt = {it.lo, it.hi}, x = w.x0, y = w.y + 6, w = iw, h = ih})
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
		append(&L.runs, Md_Run{lo = it.lo, hi = it.hi, x = w.x, w = pc.w_word, row = row, font = font, size = size, kind = .Checkbox, checked = it.checked})
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
	run := Md_Run{lo = i32(pc.lo), hi = i32(pc.hi), x = w.x + pc.pad[0], w = pc.w_full - pc.pad[0] - pc.pad[1], row = row, font = font, size = size, style = it.style, color = it.color}
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
	w.row = Md_Row{lo = i32(lo)}
	w.x = w.x0
}

@(private = "file")
finish_row :: proc(w: ^Wrapper) {
	L := w.L
	row := i32(len(L.rows))
	first := len(L.runs)
	for first > 0 && L.runs[first - 1].row == row do first -= 1
	h, top: f32
	measure :: proc(font: Font_Id, size: u16, factor: f32) -> (h, top: f32) {
		m := font_metrics(&g.text, font, size)
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
		whole := text_width(&g.text, r.font, r.size, w.text[r.lo:r.hi])
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
	w.row.h = max(h, top + font_metrics(&g.text, w.base.font, w.base.size).descent)
	w.row.baseline = top
	w.row.runs = {i32(first), i32(len(L.runs))}
	append(&L.rows, w.row)
	w.y += w.row.h
}

// --- Caret positions -------------------------------------------------------------------

// The row holding byte k of a line.
md_row_of :: proc(L: ^Line_Layout, k: int) -> int {
	r := 0
	for r + 1 < len(L.rows) && int(L.rows[r + 1].lo) <= k do r += 1
	return r
}

// Width of run bytes [run.lo, k).
@(private = "file")
run_prefix_w :: proc(L: ^Line_Layout, run: Md_Run, text: string, k: int) -> f32 {
	if k <= int(run.lo) do return 0
	if k >= int(run.hi) do return run.w
	#partial switch run.kind {
	case .Mono:
		return f32(visual_col(text[run.lo:run.hi], k - int(run.lo))) * L.char_w
	case .Text:
		if run.subst != {} do return run.w
		return text_width(&g.text, run.font, run.size, text[run.lo:k])
	case .Bullet, .Checkbox:
		return run.w
	}
	return 0
}

// Row and x (from the column's left) of the caret before byte k of a line.
md_caret_x :: proc(L: ^Line_Layout, text: string, k: int) -> (row: int, x: f32) {
	row = md_row_of(L, k)
	r := L.rows[row]
	x = L.indent
	after := -1 // first run starting after k
	for ri in r.runs[0] ..< r.runs[1] {
		run := L.runs[ri]
		if run.kind == .Bullet do continue
		if int(run.lo) <= k && k <= int(run.hi) && run.hi > run.lo {
			if run.kind == .Checkbox do return row, k <= int(run.lo) ? run.x : run.x + run.w
			return row, run.x + run_prefix_w(L, run, text, k)
		}
		// A marker hanging left of the content holds only carets within it.
		if md_hanging(L, run) do continue
		if int(run.lo) > k && after < 0 do after = int(ri)
		if int(run.hi) <= k do x = run.x + run.w
	}
	if after >= 0 do x = L.runs[after].x
	return
}

// The byte of a line nearest to a point (from the column's left and the line's top).
md_index_at :: proc(L: ^Line_Layout, text: string, x, y: f32) -> int {
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
		run := L.runs[ri]
		if run.kind == .Bullet || run.hi <= run.lo do continue
		right = max(right, run.x + run.w)
		if x >= run.x && x <= run.x + run.w {
			#partial switch run.kind {
			case .Mono:
				return row, int(run.lo) + byte_at_col(text[run.lo:run.hi], int(math.round((x - run.x) / L.char_w)))
			case .Text:
				if run.subst != {} do return row, x - run.x < run.w / 2 ? int(run.lo) : int(run.hi)
				return row, int(run.lo) + text_index_at(&g.text, run.font, run.size, text[run.lo:run.hi], x - run.x)
			case .Checkbox, .Bullet:
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
	run := L.runs[best]
	if x < run.x do return row, int(run.lo)
	if x < right do return row, int(run.hi)
	// Past the end of the row: the end of the line, after any hidden syntax.
	return row, end
}

// Whether a run is a bullet or marker hanging left of the content (code
// scrolled sideways starts left of it too).
md_hanging :: proc(L: ^Line_Layout, run: Md_Run) -> bool {
	return run.kind != .Mono && run.x < L.indent - 0.5
}

// The first and last caret positions of a row's text.
md_row_bounds :: proc(L: ^Line_Layout, row: int, text_len: int) -> (lo, hi: int) {
	r := L.rows[row]
	lo, hi = -1, int(r.lo)
	for ri in r.runs[0] ..< r.runs[1] {
		run := L.runs[ri]
		if run.kind == .Bullet || run.hi <= run.lo do continue
		if md_hanging(L, run) do continue
		if lo < 0 do lo = run.kind == .Checkbox ? int(run.hi) : int(run.lo)
		hi = int(run.hi)
	}
	if lo < 0 do lo = int(r.lo)
	if row == len(L.rows) - 1 do hi = max(hi, lo)
	return
}

// --- Cache keys ---------------------------------------------------------------------------

@(private = "file")
hash_value :: proc(h: u64, v: $T) -> u64 {
	v := v
	return hash.fnv64a(mem.ptr_to_bytes(&v), h)
}

md_layout_key :: proc(text: string, items: []Md_Item, p: Md_Params, col_w: f32) -> u64 {
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
	h = hash_value(h, p.scroll)
	if p.table != nil {
		h = hash_value(h, p.table.x)
		for x in p.table.edges do h = hash_value(h, x)
		h = hash.fnv64a(p.table.aligns, h)
	}
	for it in items do h = hash_value(h, it.cell)
	h = hash_value(h, g.text.generation)
	h = hash_value(h, g.text.scale)
	h = hash_value(h, g.settings.markdown_line_height)
	return h
}

// Lays out line i, through the caches.
md_line_layout :: proc(e: ^Editor, i: int) -> ^Line_Layout {
	mv := &e.mdv
	md_begin(e)
	if L, ok := mv.memo[i]; ok do return L
	text, start := md_line_text(e, i)
	items, p := md_items(e, i, text, start)
	key := md_layout_key(text, items, p, mv.col_w)
	L, found := mv.layouts[key]
	if !found {
		L = new(Line_Layout)
		md_layout(L, text, items, p)
		mv.layouts[key] = L
	}
	L.last_used = g.frame
	mv.memo[i] = L
	return L
}

// Line i's text (capped), and its document offset.
md_line_text :: proc(e: ^Editor, i: int) -> (text: string, start: int) {
	start = buffer.line_start(&e.buf, i)
	end := min(buffer.line_end(&e.buf, i), start + MD_MAX_LAYOUT_BYTES)
	text = string(buffer.read_alloc(&e.buf, start, end))
	// Don't split a character at the cap.
	for len(text) > 0 && end - start == MD_MAX_LAYOUT_BYTES && !utf8.valid_string(text[max(len(text) - 4, 0):]) do text = text[:len(text) - 1]
	return
}

md_layout_destroy :: proc(L: ^Line_Layout) {
	delete(L.rows)
	delete(L.runs)
	delete(L.strings)
	delete(L.edges)
	delete(L.images)
	free(L)
}

// Colors of rendered Markdown.
md_color :: proc(c: Md_Color, hl: syntax.Highlight = .None) -> clay.Color {
	switch c {
	case .Text:    return theme.text
	case .Heading: return theme.md_heading
	case .Link:    return theme.md_link
	case .Marker:  return theme.md_marker
	case .Code:    return theme.syntax[hl]
	case .Dim:     return theme.text_dim
	case .Math:    return theme.syntax[.Number]
	case .Html:    return theme.syntax[.Attribute]
	}
	return theme.text
}
