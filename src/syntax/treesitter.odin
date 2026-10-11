package syntax

import "base:runtime"
import "core:fmt"
import "core:text/regex"

import "../buffer"

// Tree-sitter backend. The parser reads straight from the piece tree through
// TSInput (no contiguous copy of the document), re-parses incrementally after
// each batch of edits, and highlight queries run only over the visible range.

TS_State :: struct {
	parser: ^TSParser,
	tree:   ^TSTree,
	cursor: ^TSQueryCursor,
	query:  ^Lang_Query,
}

// A compiled highlights query plus everything needed to evaluate it. Shared by
// all files of a language and kept for the lifetime of the program.
Lang_Query :: struct {
	query:      ^TSQuery,
	capture_hl: []Maybe(Highlight), // by capture id; nil = paints nothing
	predicates: [][]Predicate,      // by pattern index
	capture:    regex.Capture,      // scratch for regex matching
}

Predicate :: struct {
	kind:    enum {
		Eq,
		Not_Eq,
		Any_Of,
		Match,
		Not_Match,
		Not_Has_Parent,
	},
	capture: u32,
	strings: []string, // literal operands (owned by the query's string table)
	other:   Maybe(u32), // second capture operand for #eq?
	re:      regex.Regular_Expression,
}

ODIN_HIGHLIGHTS :: #load("../../vendor/tree-sitter-odin/queries/highlights.scm", string)

@(private = "file")
queries: [Language]^Lang_Query

@(private = "file")
ts_language :: proc(lang: Language) -> (^TSLanguage, string) {
	#partial switch lang {
	case .Odin:
		return tree_sitter_odin(), ODIN_HIGHLIGHTS
	}
	return nil, ""
}

ts_open :: proc(s: ^TS_State, b: ^buffer.Buffer, lang: Language) -> bool {
	language, source := ts_language(lang)
	if language == nil do return false
	if queries[lang] == nil {
		queries[lang] = load_query(language, source) or_return
	}
	s.query = queries[lang]
	s.parser = ts_parser_new()
	if !ts_parser_set_language(s.parser, language) {
		ts_parser_delete(s.parser)
		s^ = {}
		return false
	}
	s.cursor = ts_query_cursor_new()
	s.tree = ts_parser_parse(s.parser, nil, buffer_input(b))
	return s.tree != nil
}

ts_close :: proc(s: ^TS_State) {
	if s.tree != nil do ts_tree_delete(s.tree)
	if s.cursor != nil do ts_query_cursor_delete(s.cursor)
	if s.parser != nil do ts_parser_delete(s.parser)
	s^ = {}
}

ts_edit :: proc(s: ^TS_State, b: ^buffer.Buffer, changes: []buffer.Change) {
	to_point :: proc(p: buffer.Point) -> TSPoint {return {u32(p.row), u32(p.col)}}
	for c in changes {
		edit := TSInputEdit {
			start_byte    = u32(c.offset),
			old_end_byte  = u32(c.offset + c.old_len),
			new_end_byte  = u32(c.offset + c.new_len),
			start_point   = to_point(c.start),
			old_end_point = to_point(c.old_end),
			new_end_point = to_point(c.new_end),
		}
		ts_tree_edit(s.tree, &edit)
	}
	new_tree := ts_parser_parse(s.parser, s.tree, buffer_input(b))
	ts_tree_delete(s.tree)
	s.tree = new_tree
}

ts_highlight :: proc(s: ^TS_State, b: ^buffer.Buffer, start: int, out: []Highlight) {
	q := s.query
	end := start + len(out)
	ts_query_cursor_set_byte_range(s.cursor, u32(start), u32(end))
	ts_query_cursor_exec(s.cursor, q.query, ts_tree_root_node(s.tree))

	// Captures arrive ordered by node start, and by pattern order for the same
	// node; painting in that order makes later, more specific patterns win.
	match: TSQueryMatch
	ci: u32
	checked_match := max(u32)
	match_ok := false
	for ts_query_cursor_next_capture(s.cursor, &match, &ci) {
		if match.id != checked_match {
			checked_match = match.id
			match_ok = predicates_pass(q, b, match)
		}
		if !match_ok do continue
		cap := match.captures[ci]
		hl, paints := q.capture_hl[cap.index].?
		if !paints do continue
		lo := max(int(ts_node_start_byte(cap.node)), start)
		hi := min(int(ts_node_end_byte(cap.node)), end)
		for i in lo ..< hi do out[i - start] = hl
	}
}

@(private = "file")
buffer_input :: proc(b: ^buffer.Buffer) -> TSInput {
	read :: proc "c" (payload: rawptr, byte_index: u32, position: TSPoint, bytes_read: ^u32) -> [^]u8 {
		context = runtime.default_context()
		chunk := buffer.chunk_at((^buffer.Buffer)(payload), int(byte_index))
		bytes_read^ = u32(len(chunk))
		return raw_data(chunk)
	}
	return {payload = b, read = read, encoding = .UTF8}
}

// --- Query loading ----------------------------------------------------------------

@(private = "file")
load_query :: proc(language: ^TSLanguage, source: string) -> (q: ^Lang_Query, ok: bool) {
	// Queries are cached for the life of the program: allocate them outside
	// whatever (possibly tracking) allocator the caller uses.
	context.allocator = runtime.heap_allocator()
	err_offset: u32
	err_type: TSQueryError
	query := ts_query_new(language, raw_data(source), u32(len(source)), &err_offset, &err_type)
	if query == nil {
		fmt.eprintfln("tree-sitter query error %v at byte %d", err_type, err_offset)
		return nil, false
	}

	q = new(Lang_Query)
	q.query = query
	q.capture = regex.preallocate_capture()

	q.capture_hl = make([]Maybe(Highlight), ts_query_capture_count(query))
	for &hl, id in q.capture_hl {
		if h, paints := highlight_for_capture(capture_name(query, u32(id))); paints do hl = h
	}

	q.predicates = make([][]Predicate, ts_query_pattern_count(query))
	for &preds, pattern in q.predicates {
		preds = parse_predicates(query, u32(pattern))
	}
	return q, true
}

@(private = "file")
capture_name :: proc(query: ^TSQuery, id: u32) -> string {
	n: u32
	p := ts_query_capture_name_for_id(query, id, &n)
	return string(p[:n])
}

@(private = "file")
string_value :: proc(query: ^TSQuery, id: u32) -> string {
	n: u32
	p := ts_query_string_value_for_id(query, id, &n)
	return string(p[:n])
}

// Predicates arrive as flat step lists: name, operands..., Done. We keep the
// ones we understand; unknown ones (#set!, directives) are ignored, which
// means "pass".
@(private = "file")
parse_predicates :: proc(query: ^TSQuery, pattern: u32) -> []Predicate {
	count: u32
	steps := ts_query_predicates_for_pattern(query, pattern, &count)
	out := make([dynamic]Predicate)
	i: u32 = 0
	for i < count {
		j := i
		for j < count && steps[j].type != .Done do j += 1
		group := steps[i:j]
		i = j + 1
		if len(group) < 2 || group[0].type != .String || group[1].type != .Capture do continue

		p := Predicate{capture = group[1].value_id}
		switch string_value(query, group[0].value_id) {
		case "eq?":             p.kind = .Eq
		case "not-eq?":         p.kind = .Not_Eq
		case "any-of?":         p.kind = .Any_Of
		case "match?", "lua-match?": p.kind = .Match // the Lua patterns used are also valid regexes
		case "not-match?":      p.kind = .Not_Match
		case "not-has-parent?": p.kind = .Not_Has_Parent
		case:                   continue
		}
		args := make([dynamic]string)
		for step in group[2:] {
			if step.type == .Capture {
				p.other = step.value_id
			} else {
				append(&args, string_value(query, step.value_id))
			}
		}
		p.strings = args[:]
		if p.kind == .Match || p.kind == .Not_Match {
			if len(p.strings) == 0 do continue
			re, err := regex.create(p.strings[0], {.No_Capture})
			if err != nil {
				fmt.eprintfln("tree-sitter query: bad regex %q: %v", p.strings[0], err)
				continue
			}
			p.re = re
		}
		append(&out, p)
	}
	return out[:]
}

// --- Predicate evaluation -----------------------------------------------------------

@(private = "file")
predicates_pass :: proc(q: ^Lang_Query, b: ^buffer.Buffer, match: TSQueryMatch) -> bool {
	for p in q.predicates[match.pattern_index] {
		node, found := capture_node(match, p.capture)
		if !found do continue
		ok: bool
		switch p.kind {
		case .Eq, .Not_Eq:
			text := node_text(b, node)
			equal: bool
			if other, is_capture := p.other.?; is_capture {
				other_node, _ := capture_node(match, other)
				equal = text == node_text(b, other_node)
			} else {
				equal = len(p.strings) > 0 && text == p.strings[0]
			}
			ok = equal == (p.kind == .Eq)
		case .Any_Of:
			text := node_text(b, node)
			for s in p.strings do if s == text do ok = true
		case .Match, .Not_Match:
			_, matched := regex.match_with_preallocated_capture(p.re, node_text(b, node), &q.capture)
			ok = matched == (p.kind == .Match)
		case .Not_Has_Parent:
			ok = true
			parent := ts_node_parent(node)
			if !ts_node_is_null(parent) {
				type := string(ts_node_type(parent))
				for s in p.strings do if s == type do ok = false
			}
		}
		if !ok do return false
	}
	return true
}

@(private = "file")
capture_node :: proc(match: TSQueryMatch, capture: u32) -> (TSNode, bool) {
	for i in 0 ..< match.capture_count {
		if match.captures[i].index == capture do return match.captures[i].node, true
	}
	return {}, false
}

// Text of a node, for predicates. Capped: predicates compare short identifiers.
@(private = "file")
node_text :: proc(b: ^buffer.Buffer, node: TSNode) -> string {
	lo := int(ts_node_start_byte(node))
	hi := min(int(ts_node_end_byte(node)), lo + 256)
	return string(buffer.read_alloc(b, lo, hi))
}
