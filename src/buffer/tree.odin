package buffer

// The document is an ordered sequence of pieces kept in an implicit treap
// (a randomized balanced binary tree keyed by position). Each node caches the
// byte length and line-feed count of its subtree, so offset/line lookups and
// split/merge are O(log pieces). Nodes live in one pool and refer to each other
// by index, which keeps the tree compact and allocation-free in steady state.

Source :: enum u8 {
	Original, // the file as loaded; never modified
	Added,    // append-only store for inserted text
}

Piece :: struct {
	start:  int,
	length: int,
	lf:     int, // line feeds within the piece
	source: Source,
}

NIL :: u32(0) // nodes[0] is a sentinel with zero length

Node :: struct {
	piece:       Piece,
	left, right: u32,
	priority:    u32,
	len:         int, // subtree byte length
	lf:          int, // subtree line-feed count
}

@(private)
new_node :: proc(b: ^Buffer, piece: Piece) -> u32 {
	b.rng ~= b.rng << 13
	b.rng ~= b.rng >> 17
	b.rng ~= b.rng << 5
	node := Node{piece = piece, priority = b.rng, len = piece.length, lf = piece.lf}
	if n, ok := pop_safe(&b.free); ok {
		b.nodes[n] = node
		return n
	}
	append(&b.nodes, node)
	return u32(len(b.nodes) - 1)
}

@(private)
free_subtree :: proc(b: ^Buffer, t: u32) {
	if t == NIL do return
	free_subtree(b, b.nodes[t].left)
	free_subtree(b, b.nodes[t].right)
	append(&b.free, t)
}

@(private)
update :: proc(b: ^Buffer, t: u32) {
	n := &b.nodes[t]
	l, r := &b.nodes[n.left], &b.nodes[n.right]
	n.len = l.len + n.piece.length + r.len
	n.lf = l.lf + n.piece.lf + r.lf
}

@(private)
merge :: proc(b: ^Buffer, x, y: u32) -> u32 {
	if x == NIL do return y
	if y == NIL do return x
	if b.nodes[x].priority > b.nodes[y].priority {
		b.nodes[x].right = merge(b, b.nodes[x].right, y)
		update(b, x)
		return x
	}
	b.nodes[y].left = merge(b, x, b.nodes[y].left)
	update(b, y)
	return y
}

// Splits t into the first `offset` bytes and the rest, cutting a piece in two
// if the offset falls inside it.
@(private)
split :: proc(b: ^Buffer, t: u32, offset: int) -> (l, r: u32) {
	if t == NIL do return NIL, NIL
	left_len := b.nodes[b.nodes[t].left].len
	piece := b.nodes[t].piece

	switch {
	// Recursive splits can allocate (and so move) nodes: assign results after the call.
	case offset <= left_len:
		sl, sr := split(b, b.nodes[t].left, offset)
		b.nodes[t].left = sr
		update(b, t)
		return sl, t

	case offset >= left_len + piece.length:
		sl, sr := split(b, b.nodes[t].right, offset - left_len - piece.length)
		b.nodes[t].right = sl
		update(b, t)
		return t, sr

	case:
		k := offset - left_len
		store := &b.stores[piece.source]
		head_lf := lf_count(store, piece.start, piece.start + k)
		tail := Piece{piece.start + k, piece.length - k, piece.lf - head_lf, piece.source}

		b.nodes[t].piece = Piece{piece.start, k, head_lf, piece.source}
		old_right := b.nodes[t].right
		b.nodes[t].right = NIL
		update(b, t)

		tail_node := new_node(b, tail) // may reallocate nodes; no pointers held
		return t, merge(b, tail_node, old_right)
	}
}

// Appends the pieces of t, in order, to out.
@(private)
collect :: proc(b: ^Buffer, t: u32, out: ^[dynamic]Piece) {
	if t == NIL do return
	collect(b, b.nodes[t].left, out)
	append(out, b.nodes[t].piece)
	collect(b, b.nodes[t].right, out)
}

// If the last piece of t is the most recent text in the add store, grows it by
// `piece` (which must directly follow it) and returns true. This makes
// sequential typing extend one node instead of creating one per keystroke.
@(private)
try_extend_last :: proc(b: ^Buffer, t: u32, piece: Piece) -> bool {
	if t == NIL do return false
	n := &b.nodes[t]
	if n.right != NIL {
		if !try_extend_last(b, n.right, piece) do return false
	} else {
		p := &n.piece
		if p.source != .Added || p.start + p.length != piece.start do return false
		p.length += piece.length
		p.lf += piece.lf
	}
	update(b, t)
	return true
}
