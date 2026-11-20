package buffer

import "base:runtime"

// A buffer's text at one moment, which any thread may read while the buffer goes
// on being edited, or after it is destroyed: the pieces in order, as slices of
// the stores' blocks (which never move), and a reference to those blocks. Taking
// one copies the piece list, O(pieces), never the text


Snapshot :: struct {
	spans:     []Span, // the text, in order
	length:    int,
	lines:     int,    // line count
	version:   u64,    // the buffer's version when it was taken
	memory:    [Source]^Store_Memory,
	allocator: runtime.Allocator,
}

// A piece of a snapshot's text
Span :: struct {
	text:   []u8,
	offset: int, // where it starts in the document
	lf:     int, // line feeds before it
}


// Takes a snapshot of the buffer's text. Release it with snapshot_release, on
// any thread: `allocator` must be one that thread may free with
snapshot :: proc(b: ^Buffer, allocator := context.allocator) -> Snapshot {
	s := Snapshot {
		length    = length(b),
		lines     = line_count(b),
		version   = b.version,
		allocator = allocator,
	}

	// Every node but the sentinel and the free ones is in the tree
	nodes := len(b.nodes) - 1 - len(b.free)
	spans := make([dynamic]Span, 0, nodes, allocator)
	offset, lf := 0, 0
	collect_spans(b, b.root, &spans, &offset, &lf)
	s.spans = spans[:]

	for source in Source {
		s.memory[source] = b.stores[source].mem
		memory_retain(s.memory[source])
	}
	return s
}


@(private = "file")
collect_spans :: proc(b: ^Buffer, t: u32, out: ^[dynamic]Span, offset, lf: ^int) {
	if t == NIL do return

	n := b.nodes[t]
	collect_spans(b, n.left, out, offset, lf)

	text := store_bytes(&b.stores[n.piece.source], n.piece.start, n.piece.length)
	append(out, Span{text, offset^, lf^})
	offset^ += n.piece.length
	lf^ += n.piece.lf

	collect_spans(b, n.right, out, offset, lf)
}


// Lets go of the snapshot; the text's blocks are freed with the last holder
snapshot_release :: proc(s: ^Snapshot) {
	delete(s.spans, s.allocator)
	for m in s.memory do memory_release(m)
	s^ = {}
}


// Copies bytes [start, end) into dst (which must be large enough) and returns
// the filled slice
snapshot_read :: proc(s: ^Snapshot, start, end: int, dst: []u8) -> []u8 {
	start, end := max(start, 0), min(end, s.length)
	if end <= start do return dst[:0]

	n := 0
	for i := span_at(s, start); i < len(s.spans) && s.spans[i].offset < end; i += 1 {
		span := s.spans[i]
		lo := max(start, span.offset) - span.offset
		hi := min(end, span.offset + len(span.text)) - span.offset
		n += copy(dst[n:], span.text[lo:hi])
	}
	return dst[:n]
}


// Reads [start, end) into a new slice from `allocator`
snapshot_read_alloc :: proc(
	s: ^Snapshot,
	start, end: int,
	allocator := context.temp_allocator,
) -> []u8 {
	start, end := max(start, 0), min(end, s.length)
	return snapshot_read(s, start, end, make([]u8, max(end - start, 0), allocator))
}


// Offset of the first byte of `line` (clamped to the last line). Scans the span
// holding the line feed before it
snapshot_line_start :: proc(s: ^Snapshot, line: int) -> int {
	line := clamp(line, 0, s.lines - 1)
	if line == 0 do return 0

	// The last span with fewer line feeds before it than `line` holds the
	// `line`-th one (1-based)
	lo, hi := 0, len(s.spans) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if s.spans[mid].lf < line {
			lo = mid
		} else {
			hi = mid - 1
		}
	}

	span := s.spans[lo]
	remaining := line - span.lf
	for c, i in span.text {
		if c != '\n' do continue

		remaining -= 1
		if remaining == 0 do return span.offset + i + 1
	}
	return s.length
}


// Index of the span holding `offset`
@(private = "file")
span_at :: proc(s: ^Snapshot, offset: int) -> int {
	lo, hi := 0, len(s.spans) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if s.spans[mid].offset <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}
