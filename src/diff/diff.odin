package diff

// Line diffs with Myers' O(ND) algorithm ("An O(ND) Difference Algorithm and
// Its Variations", 1986), the one git and most editors use by default. A file
// changed on disk is reloaded as edits of the lines that changed, so carets,
// undo and incremental parsers see a small change, not a new document. The
// side-by-side diff view takes the hunks as line numbers (line_hunks, rows.odin)
// and the words that changed within a changed line (words)

import "core:hash"
import "core:slice"


// Lines added or removed beyond which the diff gives up and replaces the whole
// middle (what is left after the common first and last lines) in one hunk.
// Keeps the time and the trace's memory (MAX_EDITS² offsets) bounded
MAX_EDITS :: 1000

// Tokens added or removed beyond which two lines count as wholly different
MAX_WORD_EDITS :: 64

// Bytes [old_lo, old_hi) of the old text are replaced by [new_lo, new_hi) of the
// new one. Hunks are sorted and don't overlap; each covers whole lines
Hunk :: struct {
	old_lo, old_hi: int,
	new_lo, new_hi: int,
}

// Lines [old_lo, old_hi) of the old text are replaced by [new_lo, new_hi) of the
// new one, counting lines as an editor does: split at each '\n', the part
// after the last one a line too (empty when the text ends with one). A line's
// ending isn't part of it, "\r\n" or "\n" alike (as git sees a file checked
// out with other line endings than it stores)
Line_Hunk :: struct {
	old_lo, old_hi: int,
	new_lo, new_hi: int,
}

// A line of a text, or a token of a line: bytes [start, end) and their hash
@(private = "file")
Line :: struct {
	start, end: int,
	hash:       u64,
}

// How a text is split into lines
@(private = "file")
Split :: enum {
	With_Breaks,    // each line with its '\n'; no empty line after a last '\n'
	Without_Breaks, // as an editor counts lines, without their "\r\n" or "\n"
}

// One line removed from the old text at x, or inserted from the new one at y
@(private = "file")
Step :: struct {
	x, y:    int,
	removed: bool,
}


// The hunks that turn `old` into `new`, in `allocator`. Empty when they're equal
lines :: proc(old, new: []u8, allocator := context.allocator) -> []Hunk {
	a := split_lines(old, .With_Breaks, context.temp_allocator)
	b := split_lines(new, .With_Breaks, context.temp_allocator)
	found := diff_lines(old, new, a, b)

	// Line indexes -> bytes
	hunks := make([]Hunk, len(found), allocator)
	for h, i in found {
		hunks[i] = {
			old_lo = line_offset(a, h.old_lo, len(old)),
			old_hi = line_offset(a, h.old_hi, len(old)),
			new_lo = line_offset(b, h.new_lo, len(new)),
			new_hi = line_offset(b, h.new_hi, len(new)),
		}
	}
	return hunks
}


// The hunks that turn `old` into `new` as line numbers, in `allocator`, with
// each text's line count. Line endings don't count
line_hunks :: proc(
	old, new: []u8,
	allocator := context.allocator,
) -> (
	hunks: []Line_Hunk,
	old_lines, new_lines: int,
) {
	a := split_lines(old, .Without_Breaks, context.temp_allocator)
	b := split_lines(new, .Without_Breaks, context.temp_allocator)
	found := diff_lines(old, new, a, b)
	return slice.clone(found, allocator), len(a), len(b)
}


// What differs between two lines, word by word: the ranges of `a` removed and
// of `b` added, in `allocator`. Not ok when they differ in too many places to
// say (MAX_WORD_EDITS), or have nothing in common
words :: proc(
	a, b: string,
	allocator := context.allocator,
) -> (
	removed, added: [][2]int,
	ok: bool,
) {
	old, new := transmute([]u8)a, transmute([]u8)b
	x := split_tokens(old, context.temp_allocator)
	y := split_tokens(new, context.temp_allocator)

	// The tokens both start and end with, then the middle
	prefix, suffix := common_ends(old, new, x, y)
	x_mid := x[prefix:len(x) - suffix]
	y_mid := y[prefix:len(y) - suffix]

	found := make([dynamic]Line_Hunk, context.temp_allocator)
	if len(x_mid) > 0 || len(y_mid) > 0 {
		if !myers(old, new, x_mid, y_mid, MAX_WORD_EDITS, &found) do return
	}

	// Nothing in common: the whole line changed, which says nothing more
	if prefix == 0 && suffix == 0 && len(found) == 1 {
		h := found[0]
		whole := h.old_hi - h.old_lo == len(x) && h.new_hi - h.new_lo == len(y)
		if whole do return
	}

	// Token indexes -> bytes, each side's changes apart
	out_removed := make([dynamic][2]int, allocator)
	out_added := make([dynamic][2]int, allocator)
	for h in found {
		if h.old_hi > h.old_lo {
			lo := x_mid[h.old_lo].start
			hi := x_mid[h.old_hi - 1].end
			append(&out_removed, [2]int{lo, hi})
		}
		if h.new_hi > h.new_lo {
			lo := y_mid[h.new_lo].start
			hi := y_mid[h.new_hi - 1].end
			append(&out_added, [2]int{lo, hi})
		}
	}
	return out_removed[:], out_added[:], true
}


// Applies hunks to `old`, for tests and checks: the result is `new`
apply :: proc(old, new: []u8, hunks: []Hunk, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	at := 0
	for h in hunks {
		append(&out, ..old[at:h.old_lo])
		append(&out, ..new[h.new_lo:h.new_hi])
		at = h.old_hi
	}
	append(&out, ..old[at:])
	return out[:]
}


// The hunks between two texts split into lines, as line indexes (temp): the
// common first and last lines, then the middle line by line, or past MAX_EDITS
// as one hunk
@(private = "file")
diff_lines :: proc(old, new: []u8, a, b: []Line) -> []Line_Hunk {
	prefix, suffix := common_ends(old, new, a, b)
	a_mid := a[prefix:len(a) - suffix]
	b_mid := b[prefix:len(b) - suffix]

	hunks := make([dynamic]Line_Hunk, context.temp_allocator)
	if len(a_mid) == 0 && len(b_mid) == 0 {
		return hunks[:]
	}

	if !myers(old, new, a_mid, b_mid, MAX_EDITS, &hunks) {
		clear(&hunks)
		append(&hunks, Line_Hunk{0, len(a_mid), 0, len(b_mid)})
	}

	// Indexes in the middle -> in the whole texts
	for &h in hunks {
		h.old_lo += prefix
		h.old_hi += prefix
		h.new_lo += prefix
		h.new_hi += prefix
	}
	return hunks[:]
}


// How many lines (or tokens) a and b both start with, and then end with
@(private = "file")
common_ends :: proc(old, new: []u8, a, b: []Line) -> (prefix, suffix: int) {
	for prefix < len(a) && prefix < len(b) && same_line(old, new, a[prefix], b[prefix]) {
		prefix += 1
	}
	for suffix < len(a) - prefix && suffix < len(b) - prefix {
		x, y := a[len(a) - 1 - suffix], b[len(b) - 1 - suffix]
		if !same_line(old, new, x, y) do break
		suffix += 1
	}
	return
}


@(private = "file")
split_lines :: proc(text: []u8, split: Split, allocator := context.allocator) -> []Line {
	lines := make([dynamic]Line, 0, len(text) / 32 + 1, allocator)

	start := 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != '\n' {
			end += 1
		}

		if split == .With_Breaks {
			end = min(end + 1, len(text))
			append(&lines, Line{start, end, hash.fnv64a(text[start:end])})
			start = end
			continue
		}

		// Without the '\r' of a "\r\n"
		content := end
		if content > start && text[content - 1] == '\r' && end < len(text) {
			content -= 1
		}
		append(&lines, Line{start, content, hash.fnv64a(text[start:content])})
		start = end + 1
	}

	// The line after a last line break, or the only line of an empty text
	ends_open := len(text) == 0 || text[len(text) - 1] == '\n'
	if split == .Without_Breaks && ends_open {
		append(&lines, Line{len(text), len(text), hash.fnv64a(nil)})
	}
	return lines[:]
}


// A line's tokens: runs of word characters (letters, digits, '_', and any
// non-ASCII byte), runs of spaces and tabs, and each other character alone
@(private = "file")
split_tokens :: proc(text: []u8, allocator := context.allocator) -> []Line {
	tokens := make([dynamic]Line, 0, len(text) / 4 + 1, allocator)

	start := 0
	for start < len(text) {
		class := token_class(text[start])
		end := start + 1
		if class != .Other {
			for end < len(text) && token_class(text[end]) == class {
				end += 1
			}
		}

		append(&tokens, Line{start, end, hash.fnv64a(text[start:end])})
		start = end
	}
	return tokens[:]
}


@(private = "file")
Token_Class :: enum {
	Word,
	Space,
	Other,
}


@(private = "file")
token_class :: proc(c: u8) -> Token_Class {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xff:
		return .Word
	case ' ', '\t':
		return .Space
	}
	return .Other
}


@(private = "file")
same_line :: proc(old, new: []u8, x, y: Line) -> bool {
	if x.hash != y.hash || x.end - x.start != y.end - y.start {
		return false
	}
	return slice.equal(old[x.start:x.end], new[y.start:y.end])
}


// Where line i starts; the end of the text past the last line
@(private = "file")
line_offset :: proc(lines: []Line, i: int, text_len: int) -> int {
	return i < len(lines) ? lines[i].start : text_len
}


// Appends the hunks between a and b as indexes into them. Returns false if they
// differ by more than `limit` lines (or tokens)
@(private = "file")
myers :: proc(old, new: []u8, a, b: []Line, limit: int, hunks: ^[dynamic]Line_Hunk) -> bool {
	n, m := len(a), len(b)
	max_d := min(n + m, limit)
	offset := max_d + 1

	// v[k + offset] is the furthest x reached on diagonal k; the trace keeps a
	// copy of v's live part after each d, to walk back from the end
	v := make([]int, 2 * max_d + 3, context.temp_allocator)
	trace := make([dynamic][]int, context.temp_allocator)

	found := -1
	search: for d in 0 ..= max_d {
		for k := -d; k <= d; k += 2 {
			x: int
			if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
				x = v[k + 1 + offset] // down: a line of b inserted
			} else {
				x = v[k - 1 + offset] + 1 // right: a line of a removed
			}
			y := x - k
			for x < n && y < m && same_line(old, new, a[x], b[y]) {
				x += 1
				y += 1
			}
			v[k + offset] = x

			if x >= n && y >= m {
				append(&trace, slice.clone(v[offset - d:offset + d + 1], context.temp_allocator))
				found = d
				break search
			}
		}
		append(&trace, slice.clone(v[offset - d:offset + d + 1], context.temp_allocator))
	}
	if found < 0 do return false

	// Walk back from (n, m): each d ended a snake that began with one step from
	// where d - 1 ended. trace[d - 1] holds diagonals -(d - 1) ..= d - 1
	steps := make([dynamic]Step, context.temp_allocator)
	x, y := n, m
	for d := found; d > 0; d -= 1 {
		k := x - y
		prev := trace[d - 1]

		down := k == -d || (k != d && prev[k - 1 + d - 1] < prev[k + 1 + d - 1])
		prev_k := down ? k + 1 : k - 1
		prev_x := prev[prev_k + d - 1]
		prev_y := prev_x - prev_k

		append(&steps, Step{prev_x, prev_y, !down})
		x, y = prev_x, prev_y
	}

	// Steps in text order, grouped into hunks of adjacent lines
	slice.reverse(steps[:])
	for s in steps {
		lo_a, lo_b := s.x, s.y
		hi_a := s.removed ? lo_a + 1 : lo_a
		hi_b := s.removed ? lo_b : lo_b + 1

		if len(hunks) > 0 {
			last := &hunks[len(hunks) - 1]
			if last.old_hi == lo_a && last.new_hi == lo_b {
				last.old_hi, last.new_hi = hi_a, hi_b
				continue
			}
		}
		append(hunks, Line_Hunk{lo_a, hi_a, lo_b, hi_b})
	}
	return true
}
