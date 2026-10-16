package buffer

import "base:runtime"

// A text document: a piece table stored in a balanced tree, plus undo history.
// Offsets are byte offsets into the document. Lines are separated by '\n'; a
// preceding '\r' is treated as part of the line ending by the line queries.

Buffer :: struct {
	stores:  [Source]Store,
	nodes:   [dynamic]Node,
	free:    [dynamic]u32,
	root:    u32,
	rng:     u32,
	history: History,
	changes: [dynamic]Change, // edits not yet consumed by take_changes
	version: u64,  // incremented by every change
	crlf:    bool, // the file's line endings, used for newly inserted lines
}

// A line/column position; col is in bytes (what tree-sitter expects).
Point :: struct {
	row, col: int,
}

// One contiguous replacement, as seen by consumers that track the document
// incrementally (syntax highlighting). Positions before the edit are start and
// old_end; new_end is where the inserted text ends afterwards.
Change :: struct {
	offset:  int,
	old_len: int,
	new_len: int,
	start:   Point,
	old_end: Point,
	new_end: Point,
}

// Takes ownership of `data`, which must have been allocated with context.allocator.
buffer_init :: proc(b: ^Buffer, data: []u8) {
	b^ = {}
	b.rng = 0x9E3779B9
	append(&b.nodes, Node{}) // NIL sentinel
	store_init(&b.stores[.Original], adopt(data))

	if len(data) > 0 {
		b.root = new_node(b, Piece{0, len(data), b.stores[.Original].total_lf, .Original})
	}
	if lf := index_byte(data, '\n'); lf > 0 && data[lf - 1] == '\r' {
		b.crlf = true
	}
}

buffer_destroy :: proc(b: ^Buffer) {
	for &s in b.stores do store_destroy(&s)
	delete(b.nodes)
	delete(b.free)
	history_destroy(&b.history)
	delete(b.changes)
	b^ = {}
}

length :: proc(b: ^Buffer) -> int {
	return b.nodes[b.root].len
}

line_count :: proc(b: ^Buffer) -> int {
	return b.nodes[b.root].lf + 1
}

newline :: proc(b: ^Buffer) -> string {
	return b.crlf ? "\r\n" : "\n"
}

// --- Line queries -------------------------------------------------------------

// Offset of the first byte of `line` (clamped to the last line).
line_start :: proc(b: ^Buffer, line: int) -> int {
	line := clamp(line, 0, line_count(b) - 1)
	if line == 0 do return 0

	// Find the line feed that ends line-1: the `line`-th line feed (1-based).
	t := b.root
	target := line
	base := 0
	for t != NIL {
		n := &b.nodes[t]
		left := &b.nodes[n.left]
		if target <= left.lf {
			t = n.left
			continue
		}
		target -= left.lf
		base += left.len
		if target <= n.piece.lf {
			store := &b.stores[n.piece.source]
			lf := find_lf(store, lf_before(store, n.piece.start) + target - 1)
			return base + (lf - n.piece.start) + 1
		}
		target -= n.piece.lf
		base += n.piece.length
		t = n.right
	}
	return length(b)
}

// Offset just past the line's content, i.e. before its "\n" or "\r\n".
line_end :: proc(b: ^Buffer, line: int) -> int {
	if line >= line_count(b) - 1 do return length(b)
	end := line_start(b, line + 1) - 1
	if end > 0 && byte_at(b, end - 1) == '\r' do end -= 1
	return end
}

// Zero-based line containing `offset`.
offset_to_line :: proc(b: ^Buffer, offset: int) -> int {
	t := b.root
	offset := offset
	line := 0
	for t != NIL {
		n := &b.nodes[t]
		left := &b.nodes[n.left]
		if offset < left.len {
			t = n.left
			continue
		}
		offset -= left.len
		line += left.lf
		if offset < n.piece.length {
			store := &b.stores[n.piece.source]
			return line + lf_count(store, n.piece.start, n.piece.start + offset)
		}
		offset -= n.piece.length
		line += n.piece.lf
		t = n.right
	}
	return line
}

point_at :: proc(b: ^Buffer, offset: int) -> Point {
	row := offset_to_line(b, offset)
	return {row, offset - line_start(b, row)}
}

// Returns (and clears) the edits made since the last call, oldest first.
take_changes :: proc(b: ^Buffer, allocator := context.temp_allocator) -> []Change {
	out := make([]Change, len(b.changes), allocator)
	copy(out, b.changes[:])
	clear(&b.changes)
	return out
}

// Call before replacing [offset, offset+old_len); finish with end_change.
@(private)
begin_change :: proc(b: ^Buffer, offset, old_len: int) -> Change {
	return {offset = offset, old_len = old_len, start = point_at(b, offset), old_end = point_at(b, offset + old_len)}
}

@(private)
end_change :: proc(b: ^Buffer, c: Change, new_len: int) {
	c := c
	c.new_len = new_len
	c.new_end = point_at(b, c.offset + new_len)
	append(&b.changes, c)
	b.version += 1
}

// --- Reading ------------------------------------------------------------------

// Copies document bytes [start, end) into dst (which must be large enough) and
// returns the filled slice.
read :: proc(b: ^Buffer, start, end: int, dst: []u8) -> []u8 {
	start, end := max(start, 0), min(end, length(b))
	if end <= start do return dst[:0]
	n := 0
	read_node(b, b.root, 0, start, end, dst, &n)
	return dst[:n]
}

@(private)
read_node :: proc(b: ^Buffer, t: u32, base: int, start, end: int, dst: []u8, n: ^int) {
	if t == NIL do return
	node := &b.nodes[t]
	piece_start := base + b.nodes[node.left].len
	piece_end := piece_start + node.piece.length

	if start < piece_start {
		read_node(b, node.left, base, start, end, dst, n)
	}
	lo, hi := max(start, piece_start), min(end, piece_end)
	if lo < hi {
		src := b.stores[node.piece.source].data[node.piece.start + lo - piece_start:][:hi - lo]
		copy(dst[n^:], src)
		n^ += hi - lo
	}
	if end > piece_end {
		read_node(b, node.right, piece_end, start, end, dst, n)
	}
}

// The bytes from `offset` to the end of the piece containing it, without
// copying. Valid until the next edit. Empty at the end of the document.
chunk_at :: proc(b: ^Buffer, offset: int) -> []u8 {
	t := b.root
	offset := offset
	for t != NIL {
		n := &b.nodes[t]
		left := b.nodes[n.left].len
		if offset < left {
			t = n.left
			continue
		}
		offset -= left
		if offset < n.piece.length {
			return b.stores[n.piece.source].data[n.piece.start + offset:][:n.piece.length - offset]
		}
		offset -= n.piece.length
		t = n.right
	}
	return nil
}

// Reads [start, end) into a new slice from `allocator`.
read_alloc :: proc(b: ^Buffer, start, end: int, allocator := context.temp_allocator) -> []u8 {
	start, end := max(start, 0), min(end, length(b))
	return read(b, start, end, make([]u8, max(end - start, 0), allocator))
}

byte_at :: proc(b: ^Buffer, offset: int) -> u8 {
	buf: [1]u8
	r := read(b, offset, offset + 1, buf[:])
	return len(r) == 1 ? r[0] : 0
}

// The document's contents as a list of slices into the stores, in order. Valid
// until the next edit. Useful for saving without building one contiguous copy.
chunks :: proc(b: ^Buffer, allocator := context.temp_allocator) -> [][]u8 {
	pieces := make([dynamic]Piece, context.temp_allocator)
	collect(b, b.root, &pieces)
	out := make([][]u8, len(pieces), allocator)
	for p, i in pieces {
		out[i] = b.stores[p.source].data[p.start:][:p.length]
	}
	return out
}

// --- Raw edits (no history) ---------------------------------------------------

// Inserts text at offset and returns the piece describing it.
@(private)
insert_text :: proc(b: ^Buffer, offset: int, text: string) -> Piece {
	added := &b.stores[.Added]
	start := store_append(added, transmute([]u8)text)
	piece := Piece{start, len(text), lf_count(added, start, start + len(text)), .Added}

	l, r := split(b, b.root, offset)
	if !try_extend_last(b, l, piece) {
		l = merge(b, l, new_node(b, piece))
	}
	b.root = merge(b, l, r)
	return piece
}

@(private)
insert_pieces :: proc(b: ^Buffer, offset: int, pieces: []Piece) {
	if len(pieces) == 0 do return
	l, r := split(b, b.root, offset)
	for p in pieces {
		l = merge(b, l, new_node(b, p))
	}
	b.root = merge(b, l, r)
}

// Removes [offset, offset+count), appending the removed pieces to `removed` if given.
@(private)
remove_range :: proc(b: ^Buffer, offset, count: int, removed: ^[dynamic]Piece) {
	if count <= 0 do return
	l, rest := split(b, b.root, offset)
	m, r := split(b, rest, count)
	if removed != nil do collect(b, m, removed)
	free_subtree(b, m)
	b.root = merge(b, l, r)
}

// Wraps an allocated slice as a full dynamic array that owns it (no copy).
@(private)
adopt :: proc(data: []u8, allocator := context.allocator) -> [dynamic]u8 {
	raw := runtime.Raw_Dynamic_Array {
		data      = raw_data(data),
		len       = len(data),
		cap       = len(data),
		allocator = allocator,
	}
	return transmute([dynamic]u8)raw
}

@(private)
index_byte :: proc(data: []u8, c: u8) -> int {
	for x, i in data {
		if x == c do return i
	}
	return -1
}
