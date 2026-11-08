package markdown

import "core:strings"
import "core:time"

import "../buffer"

// The parsed document: each line's block info, kept up to date incrementally.
// After an edit only the edited lines are reparsed, plus the lines after them
// until one ends in the same state as before. States are interned; lines store
// an id


// Per-frame time for parsing beyond what the view needs
PARSE_BUDGET :: 2 * time.Millisecond

// Lines parsed past the end of the view right away, so blocks that end below it
// (a table, a fence) are known
LOOKAHEAD_LINES :: 256

// Bytes read from the buffer at a time while parsing
@(private = "file")
PARSE_CHUNK :: 64 << 10

// The state pool is compacted when it grows past this many states
@(private = "file")
POOL_COMPACT :: 1 << 16

Doc :: struct {
	lines:        [dynamic]Line_Info,
	pool:         [dynamic]State,
	pool_ids:     map[State]u32,
	cursor:       int, // first line to (re)parse; len(lines) when up to date
	// Parsing can't stop before this line: earlier ones were edited, or their
	// stored info predates a reparse that was interrupted
	must_until:   int,
	version:      u64, // bumped when any line's info changes
	refdef_gen:   u64, // bumped when a link reference or footnote definition line changes
	// Link reference labels, as of refdef generation labels_gen (see doc_labels)
	labels:       Labels,
	labels_gen:   u64,
	labels_built: bool,
	// Line 0 opens front matter: it is "---" and a closing "---" or "..." follows
	front_matter: bool,
}


doc_open :: proc(doc: ^Doc, b: ^buffer.Buffer) {
	doc_destroy(doc)

	resize(&doc.lines, buffer.line_count(b))
	for &l in doc.lines do l = {state = INVALID_STATE}

	append(&doc.pool, State{})
	doc.pool_ids[State{}] = 0
	doc.version += 1
}


doc_destroy :: proc(doc: ^Doc) {
	delete(doc.lines)
	delete(doc.pool)
	delete(doc.pool_ids)
	delete(doc.labels)
	doc^ = {}
}


doc_busy :: proc(doc: ^Doc) -> bool {
	return doc.cursor < len(doc.lines)
}


// Follows the buffer's edits (buffer.take_changes): lines are inserted and
// removed to match, and the edited ones are queued for doc_update
doc_edit :: proc(doc: ^Doc, changes: []buffer.Change) {
	for c in changes {
		row := c.start.row
		removed := c.old_end.row - row
		inserted := c.new_end.row - row

		// The line after the edit was parsed after the old last edited line, so
		// the new last edited line keeps that line's info to compare against
		last := doc.lines[c.old_end.row]
		if removed > 0 do remove_range(&doc.lines, row + 1, row + 1 + removed)
		if inserted > 0 {
			new_lines := make([]Line_Info, inserted, context.temp_allocator)
			inject_at(&doc.lines, row + 1, ..new_lines)
		}
		for &l in doc.lines[row:c.new_end.row] do l = {state = INVALID_STATE}
		doc.lines[c.new_end.row] = last

		doc.cursor = min(doc.cursor, row)
		doc.must_until = max(shift_line(doc.must_until, c), c.new_end.row + 1)
	}
}


// A line index after the edit shifts with it; one inside the replaced lines
// moves to the end of the new ones
@(private = "file")
shift_line :: proc(x: int, c: buffer.Change) -> int {
	if x > c.old_end.row do return x + (c.new_end.row - c.old_end.row)
	if x > c.start.row do return c.new_end.row + 1
	return x
}


// Parses queued lines: always through `need_line`, then until `budget` runs out
doc_update :: proc(doc: ^Doc, b: ^buffer.Buffer, need_line: int, budget: time.Duration) {
	if doc.cursor >= len(doc.lines) do return

	start := time.tick_now()
	if doc.cursor == 0 do doc.front_matter = is_front_matter_open(b)

	// Front matter opening or closing changes how every line before its end
	// reads: parse again from the top
	for _ in 0 ..< 3 {
		if !parse_lines(doc, b, need_line, budget, start) do return
		doc.cursor = 0
	}
}


// Parses from doc.cursor. Returns true to start again from line 0, after
// doc.front_matter changed
@(private = "file")
parse_lines :: proc(
	doc: ^Doc,
	b: ^buffer.Buffer,
	need_line: int,
	budget: time.Duration,
	start: time.Tick,
) -> (restart: bool) {
	n := len(doc.lines)
	i := doc.cursor
	prev, prev_id := State{}, u32(0)
	if i > 0 {
		prev_id = doc.lines[i - 1].state
		prev = doc.pool[prev_id]
	}
	pos := buffer.line_start(b, i)
	total := buffer.length(b)
	closer := -1 // the line closing the front matter, once looked for

	for i < n {
		// Read a chunk of whole lines; a line longer than the chunk is read in
		// one piece
		hi := min(pos + PARSE_CHUNK, total)
		data := buffer.read_alloc(b, pos, hi)
		if hi < total {
			if nl := strings.last_index_byte(string(data), '\n'); nl >= 0 {
				data = data[:nl + 1]
			} else {
				hi = i + 1 < n ? buffer.line_start(b, i + 1) : total
				data = buffer.read_alloc(b, pos, hi)
			}
		}
		last_chunk := pos + len(data) >= total

		j := 0
		synced := false
		for i < n {
			// Without a line feed, the rest is the last line or in the next chunk
			nl := strings.index_byte(string(data[j:]), '\n')
			if nl < 0 && !last_chunk {
				break
			}
			end := nl < 0 ? len(data) : j + nl
			line := string(data[j:end])
			if len(line) > 0 && line[len(line) - 1] == '\r' {
				line = line[:len(line) - 1]
			}

			// Parse it
			info, _, s := parse_line(prev, line, i == 0 && doc.front_matter)
			info.len = u32(len(line))
			info.first = block_distance(doc, i, info)
			id := s == prev ? prev_id : intern(doc, s)
			info.state = id

			old := doc.lines[i]
			if old != info {
				doc.version += 1
				if is_definition(old.kind) || is_definition(info.kind) {
					doc.refdef_gen += 1
				}
			}
			doc.lines[i] = info

			// Lines inserted or removed inside a block move the rest of it: parse
			// on to its end
			synced = i + 1 >= doc.must_until &&
			         old.state != INVALID_STATE &&
			         int(old.state) < len(doc.pool) &&
			         doc.pool[old.state] == s &&
			         old.first == info.first
			prev, prev_id = s, id
			i += 1
			j = end + 1

			// Front matter opening or closing
			flip := false
			if doc.front_matter && info.kind == .Front_Matter_Body && i > closer {
				closer = front_matter_close(b, i)
				flip = closer < 0
			} else if !doc.front_matter &&
			          i > 1 &&
			          len(line) >= 3 &&
			          (line[0] == '-' || line[0] == '.') &&
			          is_front_matter_fence(line) {
				flip = is_front_matter_open(b)
			}
			if flip {
				doc.front_matter = !doc.front_matter
				// Lines from here on were parsed after a different line i-1
				doc.must_until = max(doc.must_until, i + 1)
				return true
			}

			// Stop when in sync, or out of time
			if synced do break
			if i > need_line && i % 32 == 0 && time.tick_since(start) > budget {
				doc.cursor = i
				doc.must_until = max(doc.must_until, i + 1)
				return
			}
			if nl < 0 do break
		}
		if synced do break

		pos += len(data)
	}

	doc.cursor = n
	doc.must_until = 0
	compact_pool(doc)
	return
}


@(private = "file")
is_front_matter_fence :: proc(line: string) -> bool {
	t := strings.trim_right_space(line)
	return t == "---" || t == "..."
}


// Whether line 0 opens front matter: "---", with a closing line after it
@(private = "file")
is_front_matter_open :: proc(b: ^buffer.Buffer) -> bool {
	first := string(buffer.read_alloc(b, 0, buffer.line_end(b, 0)))
	return strings.trim_right_space(first) == "---" && front_matter_close(b, 1) >= 0
}


// The first line from `from` on that would close front matter, or -1
@(private = "file")
front_matter_close :: proc(b: ^buffer.Buffer, from: int) -> int {
	for i in from ..< buffer.line_count(b) {
		lo := buffer.line_start(b, i)
		line := string(buffer.read_alloc(b, lo, buffer.line_end(b, i)))
		if is_front_matter_fence(line) do return i
	}
	return -1
}


// Line_Info.first for line i, which follows the parsed line i-1. A table starts
// at its header, the paragraph line before its delimiter row; lines after a
// blank line start a block (an indented code block continued past one too)
@(private = "file")
block_distance :: proc(doc: ^Doc, i: int, info: Line_Info) -> u32 {
	if info.kind == .Table_Delim do return 1
	if i == 0 || info.kind == .Blank || .Block_Start in info.flags {
		return 0
	}

	prev := doc.lines[i - 1]
	if prev.kind == .Blank do return 0
	return prev.first + 1
}


// The first line of the leaf block line i is in (i itself for a blank line)
block_first :: proc(doc: ^Doc, i: int) -> int {
	return i - int(doc.lines[i].first)
}


// The state at the end of line i (the empty state for unparsed lines)
line_state :: proc(doc: ^Doc, i: int) -> State {
	if i < 0 || i >= len(doc.lines) {
		return {}
	}

	id := doc.lines[i].state
	return id == INVALID_STATE ? {} : doc.pool[id]
}


// Byte ranges within line i, whose text is `text`
line_detail :: proc(doc: ^Doc, i: int, text: string) -> Line_Detail {
	_, d, _ := parse_line(line_state(doc, i - 1), text, i == 0 && doc.front_matter)
	return d
}


@(private = "file")
is_definition :: proc(k: Line_Kind) -> bool {
	return k == .Link_Ref_Def || k == .Footnote_Def
}


@(private = "file")
intern :: proc(doc: ^Doc, s: State) -> u32 {
	if id, ok := doc.pool_ids[s]; ok {
		return id
	}

	id := u32(len(doc.pool))
	append(&doc.pool, s)
	doc.pool_ids[s] = id
	return id
}


// Drops states no line uses any more, once the pool is large
@(private = "file")
compact_pool :: proc(doc: ^Doc) {
	if len(doc.pool) < POOL_COMPACT do return

	remap := make([]u32, len(doc.pool), context.temp_allocator)
	for &r in remap do r = INVALID_STATE
	remap[0] = 0

	kept := make([dynamic]State, 0, len(doc.pool) / 2)
	append(&kept, State{})
	clear(&doc.pool_ids)
	doc.pool_ids[State{}] = 0

	// Renumber the states in use, in order of first use
	for &l in doc.lines {
		if l.state == INVALID_STATE do continue

		if remap[l.state] == INVALID_STATE {
			remap[l.state] = u32(len(kept))
			doc.pool_ids[doc.pool[l.state]] = u32(len(kept))
			append(&kept, doc.pool[l.state])
		}
		l.state = remap[l.state]
	}

	delete(doc.pool)
	doc.pool = kept
}
