package textedit

import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../buffer"
import "../markdown"
import "../syntax"

// --- Selections -------------------------------------------------------------------

sel_lo :: proc(s: Selection) -> int {return min(s.anchor, s.head)}
sel_hi :: proc(s: Selection) -> int {return max(s.anchor, s.head)}

// Sorts selections and merges any that overlap (or are identical carets),
// keeping track of which one is primary.
normalize :: proc(v: ^View) {
	if len(v.sels) == 0 do return
	if v.kind != nil && v.kind.snap != nil do v.kind.snap(v)
	primary_head := v.sels[v.primary].head
	slice.sort_by(v.sels[:], proc(a, b: Selection) -> bool {return sel_lo(a) < sel_lo(b)})

	out := 0
	for i in 1 ..< len(v.sels) {
		cur := &v.sels[out]
		next := v.sels[i]
		overlaps := sel_lo(next) < sel_hi(cur^) || sel_lo(next) == sel_lo(cur^)
		if overlaps {
			lo, hi := min(sel_lo(cur^), sel_lo(next)), max(sel_hi(cur^), sel_hi(next))
			// Keep the direction of the existing selection.
			if cur.head >= cur.anchor {
				cur^ = {lo, hi, -1}
			} else {
				cur^ = {hi, lo, -1}
			}
		} else {
			out += 1
			v.sels[out] = next
		}
	}
	resize(&v.sels, out + 1)

	v.primary = 0
	for s, i in v.sels {
		if sel_lo(s) <= primary_head && primary_head <= sel_hi(s) {
			v.primary = i
			break
		}
	}
}

set_single_selection :: proc(v: ^View, s: Selection) {
	clear(&v.sels)
	append(&v.sels, s)
	v.primary = 0
	normalize(v)
}

// Index of the first selection that ends at or after `offset`.
first_selection_at :: proc(v: ^View, offset: int) -> int {
	return first_selection_in(v.sels[:], offset)
}

first_selection_in :: proc(sels: []Selection, offset: int) -> int {
	lo, hi := 0, len(sels)
	for lo < hi {
		mid := (lo + hi) / 2
		if sel_hi(sels[mid]) < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

selection_ranges :: proc(v: ^View) -> [][2]int {
	ranges := make([][2]int, len(v.sels), context.temp_allocator)
	for s, i in v.sels do ranges[i] = {sel_lo(s), sel_hi(s)}
	return ranges
}

// --- Text helpers -----------------------------------------------------------------

// Content of a line (without its line ending), capped at MAX_LINE_SCAN bytes.
line_text :: proc(v: ^View, line: int) -> (text: string, start: int) {
	start = buffer.line_start(&v.buf, line)
	end := min(buffer.line_end(&v.buf, line), start + MAX_LINE_SCAN)
	return string(buffer.read_alloc(&v.buf, start, end)), start
}

// [lo, hi) of a whole line including its line break.
line_span :: proc(v: ^View, line: int) -> (lo, hi: int) {
	lo = buffer.line_start(&v.buf, line)
	hi = line + 1 < buffer.line_count(&v.buf) ? buffer.line_start(&v.buf, line + 1) : buffer.length(&v.buf)
	return
}

// Length of a line's leading spaces and tabs.
indent_len :: proc(text: string) -> int {
	n := 0
	for n < len(text) && (text[n] == ' ' || text[n] == '\t') do n += 1
	return n
}

// The visual column after character `r` at column `col` (tabs jump to the next stop).
next_col :: proc(col: int, r: rune) -> int {
	return r == '\t' ? (col / TAB_WIDTH + 1) * TAB_WIDTH : col + 1
}

// Visual column of byte index i in a line, with tabs expanded.
visual_col :: proc(text: string, i: int) -> int {
	col := 0
	for r, j in text {
		if j >= i do break
		col = next_col(col, r)
	}
	return col
}

// Byte index in a line nearest to visual column `col`.
byte_at_col :: proc(text: string, col: int) -> int {
	c := 0
	for r, j in text {
		next := next_col(c, r)
		if col < next {
			// Inside a wide character (tab): snap to the nearer edge.
			return col - c <= next - col ? j : j + utf8.rune_size(r)
		}
		c = next
	}
	return len(text)
}

// Offset of the character boundary before `offset`, treating "\r\n" as one.
prev_boundary :: proc(v: ^View, offset: int) -> int {
	if offset <= 0 do return 0
	buf: [4]u8
	lo := max(offset - 4, 0)
	b := buffer.read(&v.buf, lo, offset, buf[:])
	if b[len(b) - 1] == '\n' && len(b) >= 2 && b[len(b) - 2] == '\r' do return offset - 2
	_, size := utf8.decode_last_rune(b)
	return offset - max(size, 1)
}

next_boundary :: proc(v: ^View, offset: int) -> int {
	n := buffer.length(&v.buf)
	if offset >= n do return n
	buf: [4]u8
	b := buffer.read(&v.buf, offset, min(offset + 4, n), buf[:])
	if b[0] == '\r' && len(b) >= 2 && b[1] == '\n' do return offset + 2
	_, size := utf8.decode_rune(b)
	return offset + max(size, 1)
}

Char_Class :: enum {
	Space,
	Word,
	Punct,
}

char_class :: proc(c: u8) -> Char_Class {
	switch c {
	case ' ', '\t', '\r', '\n':
		return .Space
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xff:
		return .Word
	}
	return .Punct
}

// Word boundary left/right of `offset`, staying within the line unless already
// at its edge (then it moves to the adjacent line).
word_boundary :: proc(v: ^View, offset: int, dir: int) -> int {
	line := buffer.offset_to_line(&v.buf, offset)
	text, start := line_text(v, line)
	i := offset - start
	if dir < 0 {
		if i <= 0 do return prev_boundary(v, offset)
		for i > 0 && char_class(text[i - 1]) == .Space do i -= 1
		if i > 0 {
			class := char_class(text[i - 1])
			for i > 0 && char_class(text[i - 1]) == class do i -= 1
		}
	} else {
		if i >= len(text) do return next_boundary(v, offset)
		for i < len(text) && char_class(text[i]) == .Space do i += 1
		if i < len(text) {
			class := char_class(text[i])
			for i < len(text) && char_class(text[i]) == class do i += 1
		}
	}
	return start + i
}

// The word (or run of punctuation/space) around offset, for double-click.
word_at :: proc(v: ^View, offset: int) -> (lo, hi: int) {
	line := buffer.offset_to_line(&v.buf, offset)
	text, start := line_text(v, line)
	i := offset - start
	if len(text) == 0 do return offset, offset
	probe := min(i, len(text) - 1)
	class := char_class(text[probe])
	a, b := probe, probe
	for a > 0 && char_class(text[a - 1]) == class do a -= 1
	for b < len(text) && char_class(text[b]) == class do b += 1
	return start + a, start + b
}

// --- Editing ------------------------------------------------------------------------

// Replaces ranges[i] with texts[i] (or texts[0] for all) as one undo step and
// leaves a caret after each insertion. Ranges must be sorted; overlapping ones
// are merged first.
apply :: proc(v: ^View, kind: buffer.Edit_Kind, ranges: [][2]int, texts: []string) {
	assert(len(ranges) == len(v.sels))
	// Merge overlapping ranges (e.g. word deletes from adjacent carets).
	merged := make([dynamic][2]int, 0, len(ranges), context.temp_allocator)
	merged_texts := make([dynamic]string, 0, len(ranges), context.temp_allocator)
	primary := 0
	for r, i in ranges {
		t := texts[min(i, len(texts) - 1)]
		if len(merged) > 0 && r[0] < merged[len(merged) - 1][1] {
			merged[len(merged) - 1][1] = max(merged[len(merged) - 1][1], r[1])
		} else {
			append(&merged, r)
			append(&merged_texts, t)
		}
		if i == v.primary do primary = len(merged) - 1
	}

	buffer.begin(&v.buf, kind, now(), v.sels[:])
	clear(&v.sels)
	delta := 0
	for r, i in merged {
		lo, hi := r[0] + delta, r[1] + delta
		t := merged_texts[i]
		buffer.replace(&v.buf, lo, hi - lo, t)
		caret := lo + len(t)
		append(&v.sels, Selection{caret, caret, -1})
		delta += len(t) - (hi - lo)
	}
	v.primary = primary
	normalize(v)
	buffer.end(&v.buf, v.sels[:])
	v.reveal = true
}

// The time (ns) an edit is stamped with (buffer.begin), to tell which ones are
// close enough to merge. Every edit to a view's buffer uses it.
now :: proc() -> u64 {
	return u64(time.tick_now()._nsec)
}

insert :: proc(v: ^View, text: string, kind := buffer.Edit_Kind.Typing) {
	apply(v, kind, selection_ranges(v), {text})
}

// Backspace/Delete: removes the selection, or the character/word next to each caret.
delete_text :: proc(v: ^View, dir: int, word: bool) {
	ranges := selection_ranges(v)
	for &r, i in ranges {
		if r[0] != r[1] do continue
		h := v.sels[i].head
		if dir < 0 {
			r[0] = word ? word_boundary(v, h, -1) : prev_boundary(v, h)
		} else {
			r[1] = word ? word_boundary(v, h, +1) : next_boundary(v, h)
		}
	}
	apply(v, .Deleting, ranges, {""})
}

// --- Drawing helpers ----------------------------------------------------------------

Run :: struct {
	text:  string,
	col:   int, // visual column where the run starts
	hl:    syntax.Highlight,
	style: markdown.Text_Styles,
}

// Splits the part of a line covering visual columns [first_col, first_col+count)
// into runs of one highlight and style, with tabs expanded to spaces. Whitespace
// joins the current run (it draws nothing), so runs break only where the color
// or style changes. line_hl may be shorter than text (highlight cap); the rest
// is uncolored. line_style may be nil. A character the font lacks (`has_glyph`
// false) is drawn by a fallback font with its own advance, so it gets a run of
// its own, keeping later columns on the grid. With letter spacing (`spaced`)
// every character is a run of its own.
visible_runs :: proc(text: string, line_hl: []syntax.Highlight, line_style: []markdown.Text_Styles, first_col, count: int, spaced: bool, has_glyph: proc(r: rune) -> bool) -> []Run {
	Span :: struct {
		lo, hi: int, // into sb
		col:    int,
		hl:     syntax.Highlight,
		style:  markdown.Text_Styles,
	}
	spans := make([dynamic]Span, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	open := false // the last span may be extended
	col := 0
	for r, i in text {
		if col >= first_col + count do break
		next := next_col(col, r)
		defer col = next
		if next <= first_col do continue

		h := i < len(line_hl) ? line_hl[i] : .None
		st := i < len(line_style) ? line_style[i] : {}
		own := !spaced && has_glyph(r)
		space := r == ' ' || r == '\t'
		if !open || !own || (!space && (h != spans[len(spans) - 1].hl || st != spans[len(spans) - 1].style)) {
			append(&spans, Span{len(sb.buf), len(sb.buf), col, h, st})
		}
		if r == '\t' {
			for _ in col ..< next do strings.write_byte(&sb, ' ')
		} else {
			strings.write_rune(&sb, r)
		}
		spans[len(spans) - 1].hi = len(sb.buf)
		open = own
	}

	runs := make([dynamic]Run, 0, len(spans), context.temp_allocator)
	for span in spans {
		run := string(sb.buf[span.lo:span.hi])
		if len(strings.trim_space(run)) > 0 do append(&runs, Run{run, span.col, span.hl, span.style})
	}
	return runs[:]
}
