package lsp

// What the UI thread does with a document's changes before they reach the
// client's thread: a frame's buffer changes as edits to send, and problems
// moved through edits until the server reports again

import "../buffer"


// More changes than this in a frame are sent as the whole text if they are in
// no order (each is worked out against the later ones), or if the text is
// shorter than CHANGE_COST bytes a change (reading and copying it costs less)
@(private = "file")
MAX_CHANGES :: 256
@(private = "file")
CHANGE_COST :: 512

@(private = "file")
Change_Order :: enum {
	In_Order, // each change at or after the end of the text the one before inserted
	Reverse,  // each change ends at or before where the one before starts
	Mixed,
}


// A frame's changes of a buffer (now edited) as edits, each against the text
// the edits before it left (temp). An edit's inserted text is read from the
// buffer where the later changes moved it. The whole text is the one edit
// instead when a later change edited it, or when there are many changes and the
// text is shorter than they would be
edits_for_changes :: proc(b: ^buffer.Buffer, changes: []buffer.Change) -> []Edit {
	order := change_order(changes)
	many := len(changes) > MAX_CHANGES
	shorter := buffer.length(b) < len(changes) * CHANGE_COST
	if many && (shorter || order == .Mixed) {
		return whole_text(b)
	}

	edits := make([]Edit, len(changes), context.temp_allocator)

	// In text order, or in reverse (one edit of many places, e.g. a rename, or
	// its undo): a change's text is moved by all the later ones, or by none
	if order != .Mixed {
		shift := 0
		for i := len(changes) - 1; i >= 0; i -= 1 {
			c := changes[i]
			lo := order == .Reverse ? c.offset + shift : c.offset
			text := string(buffer.read_alloc(b, lo, lo + c.new_len))
			edits[i] = {c.offset, c.old_len, text}
			shift += c.new_len - c.old_len
		}
		return edits
	}

	for c, i in changes {
		// Where its inserted text is now
		lo, hi := c.offset, c.offset + c.new_len
		for later in changes[i + 1:] {
			later_end := later.offset + later.old_len
			if later_end <= lo {
				delta := later.new_len - later.old_len
				lo += delta
				hi += delta
			} else if later.offset < hi {
				return whole_text(b)
			}
		}

		text := string(buffer.read_alloc(b, lo, hi))
		edits[i] = {c.offset, c.old_len, text}
	}
	return edits
}


// The buffer's whole text as the one edit (temp)
@(private = "file")
whole_text :: proc(b: ^buffer.Buffer) -> []Edit {
	edits := make([]Edit, 1, context.temp_allocator)
	edits[0] = {0, -1, string(buffer.read_alloc(b, 0, buffer.length(b)))}
	return edits
}


@(private = "file")
change_order :: proc(changes: []buffer.Change) -> Change_Order {
	in_order := true
	reverse := true
	for i in 1 ..< len(changes) {
		prev := changes[i - 1]
		c := changes[i]
		if c.offset < prev.offset + prev.new_len do in_order = false
		if c.offset + c.old_len > prev.offset do reverse = false
	}

	switch {
	case in_order: return .In_Order
	case reverse:  return .Reverse
	}
	return .Mixed
}


// --- Problems ----------------------------------------------------------------------

// Moves problems with one edit: those after it shift by its length; one it
// touches stretches over the new text. They stay sorted
shift_problems :: proc(problems: []Problem, offset, old_len, new_len: int) {
	old_end := offset + old_len
	delta := new_len - old_len
	for &p in problems {
		switch {
		case p.lo >= old_end:
			// After the edit (an insertion right at its start pushes it)
			p.lo += delta
			p.hi += delta
		case p.hi <= offset:
			// Before it
		case:
			// Overlapping: covers what is left of it and the new text
			p.lo = min(p.lo, offset)
			p.hi = max(p.hi + delta, offset + new_len, p.lo)
		}
	}
}


// Merges sorted problems into a sorted list
merge_problems :: proc(into: ^[dynamic]Problem, more: []Problem) {
	if len(more) == 0 do return

	n := len(into)
	resize(into, n + len(more))
	i := n - 1
	j := len(more) - 1
	for k := len(into) - 1; j >= 0; k -= 1 {
		if i >= 0 && into[i].lo > more[j].lo {
			into[k] = into[i]
			i -= 1
		} else {
			into[k] = more[j]
			j -= 1
		}
	}
}


// Frees problems with their strings
problems_destroy :: proc(problems: []Problem) {
	for p in problems {
		delete(p.message)
		delete(p.source)
	}
	delete(problems)
}
