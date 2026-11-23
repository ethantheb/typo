package diff

// A diff side by side: rows that put the old text's lines beside the new
// one's. Lines both texts share sit beside each other; a hunk's lines are
// paired (changed), and where one side has more lines, the other side has
// filler rows. Rows aren't stored: a row is found from the hunks, so a huge
// file costs no more than its hunks


Row_Kind :: enum u8 {
	Same,    // the line is in both texts
	Changed, // a hunk's old line beside its new line
	Removed, // a hunk's old line, filler beside it
	Added,   // a hunk's new line, filler beside it
}

// A row: the old and new line in it, -1 for filler
Row :: struct {
	kind:     Row_Kind,
	old, new: int,
	hunk:     int, // the hunk it is in, -1 for Same
}

Rows :: struct {
	hunks:     []Line_Hunk, // owned
	starts:    []int,       // owned; the row each hunk begins at
	old_lines: int,
	new_lines: int,
	count:     int,
}


// The rows of a diff (taking the hunks, from `allocator`)
rows_make :: proc(
	hunks: []Line_Hunk,
	old_lines, new_lines: int,
	allocator := context.allocator,
) -> Rows {
	r := Rows {
		hunks     = hunks,
		starts    = make([]int, len(hunks), allocator),
		old_lines = old_lines,
		new_lines = new_lines,
	}

	// Each hunk starts after the lines before it, and the hunks before it
	row := 0
	old_at := 0
	for h, i in hunks {
		row += h.old_lo - old_at
		r.starts[i] = row
		row += hunk_rows(h)
		old_at = h.old_hi
	}
	r.count = row + old_lines - old_at
	return r
}


rows_destroy :: proc(r: ^Rows, allocator := context.allocator) {
	delete(r.hunks, allocator)
	delete(r.starts, allocator)
	r^ = {}
}


// How many rows a hunk takes: the longer of its sides
hunk_rows :: proc(h: Line_Hunk) -> int {
	return max(h.old_hi - h.old_lo, h.new_hi - h.new_lo)
}


// The lines in row `row` (0 ..< r.count)
row_at :: proc(r: ^Rows, row: int) -> Row {
	k := hunk_before(r, row)
	if k < 0 {
		return {.Same, row, row, -1}
	}

	h := r.hunks[k]
	i := row - r.starts[k]
	old_n := h.old_hi - h.old_lo
	new_n := h.new_hi - h.new_lo

	// After the hunk: lines both have
	if i >= max(old_n, new_n) {
		after := i - max(old_n, new_n)
		return {.Same, h.old_hi + after, h.new_hi + after, -1}
	}

	switch {
	case i < min(old_n, new_n): return {.Changed, h.old_lo + i, h.new_lo + i, k}
	case old_n > new_n:         return {.Removed, h.old_lo + i, -1, k}
	}
	return {.Added, -1, h.new_lo + i, k}
}


// The row a line of the new text (`new_side`) or the old text is in
row_of_line :: proc(r: ^Rows, line: int, new_side: bool) -> int {
	// The last hunk that starts at or before the line
	lo, hi := 0, len(r.hunks)
	for lo < hi {
		mid := (lo + hi) / 2
		start := new_side ? r.hunks[mid].new_lo : r.hunks[mid].old_lo
		if start <= line {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	k := lo - 1
	if k < 0 do return line

	h := r.hunks[k]
	start := new_side ? h.new_lo : h.old_lo
	end := new_side ? h.new_hi : h.old_hi
	if line < end {
		return r.starts[k] + line - start
	}
	return r.starts[k] + hunk_rows(h) + line - end
}


// The index of the last hunk starting at or before `row`, or -1
@(private = "file")
hunk_before :: proc(r: ^Rows, row: int) -> int {
	lo, hi := 0, len(r.starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.starts[mid] <= row {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}
