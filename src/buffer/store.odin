package buffer

import "base:runtime"
import "core:math/bits"
import "core:sync"

// A byte store plus a sparse newline index.
//
// Bytes written to a store never move, so slices of them can be handed to other
// threads (snapshots). They live in blocks: the original store is one block (the
// file as loaded); the add store fills blocks in order, the first FIRST_BLOCK
// bytes and each next block as large as everything before it, so small documents
// stay small and a huge paste takes few blocks. A piece never spans two blocks.
// The blocks belong to a reference-counted `Store_Memory`, which snapshots hold
// too, so they outlive the buffer when a snapshot does.
//
// Pieces reference ranges of a store, and the piece tree needs "how many line
// feeds are in [a, b)" and "where is the n-th line feed" without scanning whole
// pieces (the original file is a single piece of arbitrary size). Storing every
// line start would cost 8 bytes per line; instead we keep one cumulative count
// per INDEX_SPAN bytes, so a query scans at most two partial spans while the
// index costs ~0.8% of the data size


INDEX_SHIFT :: 10 // 1 KB
INDEX_SPAN  :: 1 << INDEX_SHIFT

FIRST_SHIFT :: 14 // 16 KB
FIRST_BLOCK :: 1 << FIRST_SHIFT

// An index span never crosses a block boundary
#assert(INDEX_SHIFT <= FIRST_SHIFT)

Store :: struct {
	mem:      ^Store_Memory,
	len:      int,         // bytes written
	single:   bool,        // one block: the original store
	block_lf: [dynamic]int, // block_lf[k] = number of '\n' before offset k * INDEX_SPAN
	total_lf: int,
}

// A store's blocks, freed when the store and every snapshot holding them let go
Store_Memory :: struct {
	refs:      int, // atomic
	blocks:    [dynamic][]u8,
	allocator: runtime.Allocator,
}


// The original store: takes ownership of `data` (no copy), which must come from
// context.allocator
store_init_original :: proc(s: ^Store, data: []u8) {
	store_init_memory(s)
	s.single = true
	append(&s.mem.blocks, data)
	s.len = len(data)
	index_range(s, 0, s.len)
}


// An empty add store; blocks are allocated as text is appended
store_init_added :: proc(s: ^Store) {
	store_init_memory(s)
}


@(private = "file")
store_init_memory :: proc(s: ^Store) {
	s^ = {}
	s.mem = new(Store_Memory)
	s.mem.refs = 1
	s.mem.allocator = context.allocator
	s.mem.blocks = make([dynamic][]u8, context.allocator)
}


store_destroy :: proc(s: ^Store) {
	memory_release(s.mem)
	delete(s.block_lf)
	s^ = {}
}


// Takes another reference to the blocks
@(private)
memory_retain :: proc(m: ^Store_Memory) {
	sync.atomic_add_explicit(&m.refs, 1, .Relaxed)
}


// Lets go of a reference; the last one frees the blocks, on whichever thread
@(private)
memory_release :: proc(m: ^Store_Memory) {
	if m == nil do return
	if sync.atomic_sub_explicit(&m.refs, 1, .Acq_Rel) != 1 do return

	allocator := m.allocator
	for block in m.blocks do delete(block, allocator)
	delete(m.blocks)
	free(m, allocator)
}


// Appends text and returns the offset it starts at. Text that doesn't fit the
// last block continues in a new one
store_append :: proc(s: ^Store, text: []u8) -> int {
	start := s.len

	rest := text
	for len(rest) > 0 {
		k := block_of(s, s.len)
		if k == len(s.mem.blocks) {
			append(&s.mem.blocks, make([]u8, block_size(s, k), s.mem.allocator))
		}

		n := copy(s.mem.blocks[k][s.len - block_start(s, k):], rest)
		rest = rest[n:]
		s.len += n
	}

	index_range(s, start, s.len)
	return start
}


// The bytes [start, start + length) of the store, which must lie in one block
store_bytes :: proc(s: ^Store, start, length: int) -> []u8 {
	k := block_of(s, start)
	return s.mem.blocks[k][start - block_start(s, k):][:length]
}


// Where the block holding `offset` ends (the store's end in the original store)
block_end :: proc(s: ^Store, offset: int) -> int {
	if s.single do return s.len
	return block_start(s, block_of(s, offset) + 1)
}


// In the add store block 0 holds [0, FIRST_BLOCK), block k > 0
// [FIRST_BLOCK << (k - 1), FIRST_BLOCK << k)
@(private)
block_of :: proc(s: ^Store, offset: int) -> int {
	if s.single do return 0
	if offset < FIRST_BLOCK do return 0
	return bits.len(uint(offset) >> FIRST_SHIFT)
}


@(private = "file")
block_start :: proc(s: ^Store, k: int) -> int {
	if k == 0 do return 0
	return FIRST_BLOCK << uint(k - 1)
}


@(private = "file")
block_size :: proc(s: ^Store, k: int) -> int {
	return block_start(s, k + 1) - block_start(s, k)
}


@(private)
index_range :: proc(s: ^Store, from, to: int) {
	pos := from
	for pos < to {
		if pos & (INDEX_SPAN - 1) == 0 {
			append(&s.block_lf, s.total_lf)
		}

		next := min((pos | (INDEX_SPAN - 1)) + 1, to)
		s.total_lf += count_lf(store_bytes(s, pos, next - pos))
		pos = next
	}
}


count_lf :: proc(b: []u8) -> int {
	// Simple enough for LLVM to vectorize in optimized builds
	n := 0
	for c in b {
		n += int(c == '\n')
	}
	return n
}


// Number of '\n' in the store before offset x
lf_before :: proc(s: ^Store, x: int) -> int {
	k := x >> INDEX_SHIFT
	if k >= len(s.block_lf) {
		return s.total_lf // only when x == len on an index span boundary
	}

	span_start := k << INDEX_SHIFT
	return s.block_lf[k] + count_lf(store_bytes(s, span_start, x - span_start))
}


// Number of '\n' in [a, b), which must lie in one block (a piece's range)
lf_count :: proc(s: ^Store, a, b: int) -> int {
	if b - a <= INDEX_SPAN {
		return count_lf(store_bytes(s, a, b - a))
	}
	return lf_before(s, b) - lf_before(s, a)
}


// Offset of the n-th (0-based) '\n' in the store. n must be < total_lf
find_lf :: proc(s: ^Store, n: int) -> int {
	// Largest index span k with block_lf[k] <= n; the line feed lies in span k
	lo, hi := 0, len(s.block_lf) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if s.block_lf[mid] <= n {
			lo = mid
		} else {
			hi = mid - 1
		}
	}

	// Count line feeds from the span's start
	span_start := lo << INDEX_SHIFT
	span := store_bytes(s, span_start, min(INDEX_SPAN, s.len - span_start))
	remaining := n - s.block_lf[lo]
	for c, i in span {
		if c == '\n' {
			if remaining == 0 do return span_start + i
			remaining -= 1
		}
	}

	panic("find_lf: line feed index out of range")
}
