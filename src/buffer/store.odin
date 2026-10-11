package buffer

// A byte store plus a sparse newline index.
//
// Pieces reference ranges of a store, and the piece tree needs "how many line
// feeds are in [a, b)" and "where is the n-th line feed" without scanning whole
// pieces (the original file is a single piece of arbitrary size). Storing every
// line start would cost 8 bytes per line; instead we keep one cumulative count
// per BLOCK_SIZE bytes, so a query scans at most two partial blocks while the
// index costs ~0.8% of the data size.

BLOCK_SHIFT :: 10 // 1 KB
BLOCK_SIZE :: 1 << BLOCK_SHIFT

Store :: struct {
	data:     [dynamic]u8,
	block_lf: [dynamic]int, // block_lf[k] = number of '\n' in data[:k * BLOCK_SIZE]
	total_lf: int,
}

// Takes ownership of `data` (no copy).
store_init :: proc(s: ^Store, data: [dynamic]u8) {
	s.data = data
	index_range(s, 0, len(s.data))
}

store_destroy :: proc(s: ^Store) {
	delete(s.data)
	delete(s.block_lf)
	s^ = {}
}

// Appends text and returns the offset it starts at.
store_append :: proc(s: ^Store, text: []u8) -> int {
	start := len(s.data)
	append(&s.data, ..text)
	index_range(s, start, len(s.data))
	return start
}

@(private)
index_range :: proc(s: ^Store, from, to: int) {
	pos := from
	for pos < to {
		if pos & (BLOCK_SIZE - 1) == 0 {
			append(&s.block_lf, s.total_lf)
		}
		next := min((pos | (BLOCK_SIZE - 1)) + 1, to)
		s.total_lf += count_lf(s.data[pos:next])
		pos = next
	}
}

count_lf :: proc(b: []u8) -> int {
	// Simple enough for LLVM to vectorize in optimized builds.
	n := 0
	for c in b {
		n += int(c == '\n')
	}
	return n
}

// Number of '\n' in data[:x].
lf_before :: proc(s: ^Store, x: int) -> int {
	k := x >> BLOCK_SHIFT
	if k >= len(s.block_lf) {
		return s.total_lf // only when x == len(data) on a block boundary
	}
	return s.block_lf[k] + count_lf(s.data[k << BLOCK_SHIFT:x])
}

// Number of '\n' in data[a:b].
lf_count :: proc(s: ^Store, a, b: int) -> int {
	if b - a <= BLOCK_SIZE {
		return count_lf(s.data[a:b])
	}
	return lf_before(s, b) - lf_before(s, a)
}

// Offset of the n-th (0-based) '\n' in the store. n must be < total_lf.
find_lf :: proc(s: ^Store, n: int) -> int {
	// Largest block k with block_lf[k] <= n; the line feed lies in block k.
	lo, hi := 0, len(s.block_lf) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if s.block_lf[mid] <= n {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	remaining := n - s.block_lf[lo]
	for i in lo << BLOCK_SHIFT ..< len(s.data) {
		if s.data[i] == '\n' {
			if remaining == 0 do return i
			remaining -= 1
		}
	}
	panic("find_lf: line feed index out of range")
}
