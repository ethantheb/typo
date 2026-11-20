package diff

// Line diffs with Myers' O(ND) algorithm ("An O(ND) Difference Algorithm and
// Its Variations", 1986), the one git and most editors use by default. A file
// changed on disk is reloaded as edits of the lines that changed, so carets,
// undo and incremental parsers see a small change, not a new document

import "core:hash"
import "core:slice"


// Lines added or removed beyond which the diff gives up and replaces the whole
// middle (what is left after the common first and last lines) in one hunk.
// Keeps the time and the trace's memory (MAX_EDITS² offsets) bounded
MAX_EDITS :: 1000

// Bytes [old_lo, old_hi) of the old text are replaced by [new_lo, new_hi) of the
// new one. Hunks are sorted and don't overlap; each covers whole lines
Hunk :: struct {
	old_lo, old_hi: int,
	new_lo, new_hi: int,
}

@(private = "file")
Line :: struct {
	start, end: int, // bytes, the line break included
	hash:       u64,
}

// One line removed from the old text at x, or inserted from the new one at y
@(private = "file")
Step :: struct {
	x, y:    int,
	removed: bool,
}


// The hunks that turn `old` into `new`, in `allocator`. Empty when they're equal
lines :: proc(old, new: []u8, allocator := context.allocator) -> []Hunk {
	context.allocator = allocator

	a := split_lines(old, context.temp_allocator)
	b := split_lines(new, context.temp_allocator)

	// The lines both start and end with
	prefix := 0
	for prefix < len(a) && prefix < len(b) && same_line(old, new, a[prefix], b[prefix]) {
		prefix += 1
	}
	suffix := 0
	for suffix < len(a) - prefix && suffix < len(b) - prefix {
		x, y := a[len(a) - 1 - suffix], b[len(b) - 1 - suffix]
		if !same_line(old, new, x, y) do break
		suffix += 1
	}
	a_mid := a[prefix:len(a) - suffix]
	b_mid := b[prefix:len(b) - suffix]

	hunks := make([dynamic]Hunk)
	if len(a_mid) == 0 && len(b_mid) == 0 {
		return hunks[:]
	}

	// The middle, line by line; past MAX_EDITS, as one hunk
	if !myers(old, new, a_mid, b_mid, &hunks) {
		clear(&hunks)
		append(&hunks, span(old, new, a, b, prefix, len(a) - suffix, prefix, len(b) - suffix))
		return hunks[:]
	}

	// Line indexes in the middle -> bytes of the whole texts
	for &h in hunks {
		h = span(
			old,
			new,
			a,
			b,
			prefix + h.old_lo,
			prefix + h.old_hi,
			prefix + h.new_lo,
			prefix + h.new_hi,
		)
	}
	return hunks[:]
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


@(private = "file")
split_lines :: proc(text: []u8, allocator := context.allocator) -> []Line {
	lines := make([dynamic]Line, 0, len(text) / 32 + 1, allocator)

	start := 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		end = min(end + 1, len(text))

		append(&lines, Line{start, end, hash.fnv64a(text[start:end])})
		start = end
	}
	return lines[:]
}


@(private = "file")
same_line :: proc(old, new: []u8, x, y: Line) -> bool {
	if x.hash != y.hash || x.end - x.start != y.end - y.start {
		return false
	}
	return slice.equal(old[x.start:x.end], new[y.start:y.end])
}


// The bytes of lines [a_lo, a_hi) of old and [b_lo, b_hi) of new
@(private = "file")
span :: proc(old, new: []u8, a, b: []Line, a_lo, a_hi, b_lo, b_hi: int) -> Hunk {
	return {
		old_lo = line_offset(a, a_lo, len(old)),
		old_hi = line_offset(a, a_hi, len(old)),
		new_lo = line_offset(b, b_lo, len(new)),
		new_hi = line_offset(b, b_hi, len(new)),
	}
}


// Where line i starts; the end of the text past the last line
@(private = "file")
line_offset :: proc(lines: []Line, i: int, text_len: int) -> int {
	return i < len(lines) ? lines[i].start : text_len
}


// Appends the hunks between a and b as line indexes into them. Returns false
// if they differ by more than MAX_EDITS lines
@(private = "file")
myers :: proc(old, new: []u8, a, b: []Line, hunks: ^[dynamic]Hunk) -> bool {
	n, m := len(a), len(b)
	max_d := min(n + m, MAX_EDITS)
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
		append(hunks, Hunk{lo_a, hi_a, lo_b, hi_b})
	}
	return true
}
