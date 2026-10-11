package buffer

// Undo history. Because store bytes are never modified, an edit is recorded as
// the piece descriptors it removed and inserted, never as copies of text, so
// undoing a huge deletion is as cheap as a small one. Everything lives in a few
// append-only arrays; redo branches are dropped by truncating them.

Selection :: struct {
	anchor: int,
	head:   int, // the end that moves; the caret is drawn here
	col:    int, // preferred visual column for vertical movement, or -1
}

Edit_Kind :: enum u8 {
	Other,
	Typing,
	Deleting,
}

@(private)
Range :: struct {
	lo, hi: int,
}

@(private)
Edit :: struct {
	offset:       int,
	removed:      Range, // into History.pieces
	inserted:     Range,
	removed_len:  int,
	inserted_len: int,
}

@(private)
Group :: struct {
	edits:      Range, // into History.edits
	sels_start: int,   // history arrays' lengths when the group began, for truncation
	pieces_start: int,
	before:     Range, // into History.selections
	after:      Range,
	kind:       Edit_Kind,
	time:       u64,
}

History :: struct {
	pieces:     [dynamic]Piece,
	edits:      [dynamic]Edit,
	groups:     [dynamic]Group,
	selections: [dynamic]Selection,
	applied:    int,  // groups[:applied] are in effect
	open:       bool, // between begin and end
	coalesced:  bool, // the open step continues the previous group
	save_point: int,  // value of `applied` when last saved; -1 if unreachable
}

// Groups of the same kind closer together than this merge into one undo step.
COALESCE_NS :: 1_000_000_000

history_destroy :: proc(h: ^History) {
	delete(h.pieces)
	delete(h.edits)
	delete(h.groups)
	delete(h.selections)
	h^ = {}
}

is_modified :: proc(b: ^Buffer) -> bool {
	return b.history.applied != b.history.save_point
}

mark_saved :: proc(b: ^Buffer) {
	b.history.save_point = b.history.applied
}

// Starts recording an undo step. Consecutive steps of the same kind (e.g.
// typing) coalesce if they follow quickly and the selections are unchanged
// since the previous step ended.
begin :: proc(b: ^Buffer, kind: Edit_Kind, now: u64, sels: []Selection) {
	h := &b.history
	assert(!h.open)
	h.open = true

	// Never coalesce into the saved state, so undo can always get back to it.
	h.coalesced = false
	if kind != .Other && h.applied == len(h.groups) && h.applied > 0 && h.applied != h.save_point {
		last := &h.groups[h.applied - 1]
		if last.kind == kind && now - last.time < COALESCE_NS && same_selections(h.selections[last.after.lo:last.after.hi], sels) {
			last.time = now
			h.coalesced = true
			return
		}
	}

	// A new step discards anything that was undone.
	if h.applied < len(h.groups) {
		g := h.groups[h.applied]
		resize(&h.edits, g.edits.lo)
		resize(&h.pieces, g.pieces_start)
		resize(&h.selections, g.sels_start)
		resize(&h.groups, h.applied)
		if h.save_point > h.applied do h.save_point = -1
	}

	g := Group {
		edits        = {len(h.edits), len(h.edits)},
		sels_start   = len(h.selections),
		pieces_start = len(h.pieces),
		kind         = kind,
		time         = now,
	}
	g.before = push_selections(h, sels)
	append(&h.groups, g)
	h.applied = len(h.groups)
}

// Finishes the step begun with `begin`, recording the selections after it.
end :: proc(b: ^Buffer, sels: []Selection) {
	h := &b.history
	assert(h.open)
	h.open = false
	g := &h.groups[len(h.groups) - 1]
	if !h.coalesced && g.edits.lo == len(h.edits) {
		// Nothing changed (e.g. backspace at the start of the file): drop the step.
		resize(&h.selections, g.sels_start)
		pop(&h.groups)
		h.applied = len(h.groups)
		return
	}
	g.edits.hi = len(h.edits)
	g.after = push_selections(h, sels)
}

// Replaces [offset, offset+remove_len) with text, recording it in the open step.
replace :: proc(b: ^Buffer, offset, remove_len: int, text: string) {
	h := &b.history
	assert(h.open, "replace outside begin/end")
	e := Edit{offset = offset, removed_len = remove_len, inserted_len = len(text)}
	change := begin_change(b, offset, remove_len)
	e.removed.lo = len(h.pieces)
	remove_range(b, offset, remove_len, &h.pieces)
	e.removed.hi = len(h.pieces)
	e.inserted.lo = len(h.pieces)
	if len(text) > 0 {
		append(&h.pieces, insert_text(b, offset, text))
	}
	e.inserted.hi = len(h.pieces)
	append(&h.edits, e)
	end_change(b, change, len(text))
}

// Reverts the most recent step. Returns the selections from before it.
undo :: proc(b: ^Buffer) -> (sels: []Selection, ok: bool) {
	h := &b.history
	if h.open || h.applied == 0 do return nil, false
	h.applied -= 1
	g := h.groups[h.applied]
	for i := g.edits.hi - 1; i >= g.edits.lo; i -= 1 {
		e := h.edits[i]
		change := begin_change(b, e.offset, e.inserted_len)
		remove_range(b, e.offset, e.inserted_len, nil)
		insert_pieces(b, e.offset, h.pieces[e.removed.lo:e.removed.hi])
		end_change(b, change, e.removed_len)
	}
	return h.selections[g.before.lo:g.before.hi], true
}

// Re-applies the most recently undone step. Returns the selections after it.
redo :: proc(b: ^Buffer) -> (sels: []Selection, ok: bool) {
	h := &b.history
	if h.open || h.applied == len(h.groups) do return nil, false
	g := h.groups[h.applied]
	h.applied += 1
	for i in g.edits.lo ..< g.edits.hi {
		e := h.edits[i]
		change := begin_change(b, e.offset, e.removed_len)
		remove_range(b, e.offset, e.removed_len, nil)
		insert_pieces(b, e.offset, h.pieces[e.inserted.lo:e.inserted.hi])
		end_change(b, change, e.inserted_len)
	}
	return h.selections[g.after.lo:g.after.hi], true
}

@(private)
push_selections :: proc(h: ^History, sels: []Selection) -> Range {
	lo := len(h.selections)
	append(&h.selections, ..sels)
	return {lo, len(h.selections)}
}

@(private)
same_selections :: proc(a, b: []Selection) -> bool {
	if len(a) != len(b) do return false
	for s, i in a {
		if s.anchor != b[i].anchor || s.head != b[i].head do return false
	}
	return true
}
