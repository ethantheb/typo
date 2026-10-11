package toml

import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// A small TOML reader covering what a settings file needs:
//   comments, [tables] / [dotted.tables], bare / "quoted" / dotted keys,
//   basic "..." strings (with escapes) and literal '...' strings,
//   integers (with _ separators, 0x/0o/0b), floats, booleans,
//   arrays (multi-line, trailing comma, nested) and inline tables.
// Not supported (reported as errors): multi-line strings, dates/times, and
// arrays of tables ([[...]]).
//
// Everything a Document holds lives in one arena, freed by destroy.

Table :: map[string]Value

Value :: union {
	string,
	i64,
	f64,
	bool,
	[]Value,
	^Table,
}

Document :: struct {
	root:  ^Table,
	arena: virtual.Arena,
}

Error :: struct {
	line: int, // 1-based; 0 when there is no error
	msg:  string,
}

// On error, err.msg is allocated with `allocator` (the caller frees it).
parse :: proc(src: string, allocator := context.allocator) -> (doc: ^Document, err: Error) {
	doc = new(Document, allocator)
	if virtual.arena_init_growing(&doc.arena) != nil {
		free(doc, allocator)
		return nil, {1, strings.clone("out of memory", allocator)}
	}
	p := Parser{src = src, line = 1}
	// Windows editors often save UTF-8 with a byte-order mark (EF BB BF); skip it.
	if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF do p.src = src[3:]
	ok: bool
	{
		context.allocator = virtual.arena_allocator(&doc.arena)
		doc.root = new(Table)
		p.root, p.current = doc.root, doc.root
		ok = parse_document(&p)
	}
	if !ok {
		err = {p.err.line, strings.clone(p.err.msg, allocator)} // copy out before the arena goes
		destroy(doc, allocator)
		return nil, err
	}
	return doc, {}
}

destroy :: proc(doc: ^Document, allocator := context.allocator) {
	if doc == nil do return
	virtual.arena_destroy(&doc.arena)
	free(doc, allocator)
}

// Looks up a dotted path like "appearance.theme".
get :: proc(t: ^Table, path: string) -> (v: Value, ok: bool) {
	t := t
	rest := path
	for {
		dot := strings.index_byte(rest, '.')
		if dot < 0 do return t[rest]
		inner, is_table := t[rest[:dot]].(^Table)
		if !is_table do return nil, false
		t = inner
		rest = rest[dot + 1:]
	}
}

// Returns s as a TOML basic string literal, quoted and escaped.
quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&sb, `\"`)
		case '\\': strings.write_string(&sb, `\\`)
		case '\n': strings.write_string(&sb, `\n`)
		case '\t': strings.write_string(&sb, `\t`)
		case '\r': strings.write_string(&sb, `\r`)
		case:      strings.write_rune(&sb, r)
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// --- Parser ------------------------------------------------------------------------

@(private)
Parser :: struct {
	src:     string,
	pos:     int,
	line:    int,
	root:    ^Table,
	current: ^Table, // table that key/value lines go into
	err:     Error,
}

@(private)
fail :: proc(p: ^Parser, msg: string) -> bool {
	if p.err.line == 0 do p.err = {p.line, msg}
	return false
}

@(private)
peek :: proc(p: ^Parser, ahead := 0) -> u8 {
	i := p.pos + ahead
	return i < len(p.src) ? p.src[i] : 0
}

@(private)
at_end :: proc(p: ^Parser) -> bool {return p.pos >= len(p.src)}

// Skips spaces/tabs and a trailing comment, but not newlines.
@(private)
skip_inline_space :: proc(p: ^Parser) {
	for !at_end(p) {
		switch peek(p) {
		case ' ', '\t':
			p.pos += 1
		case '#':
			for !at_end(p) && peek(p) != '\n' do p.pos += 1
		case:
			return
		}
	}
}

// Skips whitespace, comments and newlines.
@(private)
skip_space :: proc(p: ^Parser) {
	for !at_end(p) {
		skip_inline_space(p)
		switch peek(p) {
		case '\n':
			p.pos += 1
			p.line += 1
		case '\r':
			p.pos += 1
		case:
			return
		}
	}
}

@(private)
expect_line_end :: proc(p: ^Parser) -> bool {
	skip_inline_space(p)
	if at_end(p) do return true
	if peek(p) == '\r' do p.pos += 1
	if peek(p) == '\n' {
		p.pos += 1
		p.line += 1
		return true
	}
	return fail(p, "expected end of line")
}

@(private)
parse_document :: proc(p: ^Parser) -> bool {
	for {
		skip_space(p)
		if at_end(p) do return true
		if peek(p) == '[' {
			parse_table_header(p) or_return
		} else {
			parse_key_value(p, p.current) or_return
		}
		expect_line_end(p) or_return
	}
}

@(private)
parse_table_header :: proc(p: ^Parser) -> bool {
	p.pos += 1
	if peek(p) == '[' do return fail(p, "arrays of tables ([[...]]) are not supported")
	keys := parse_key(p) or_return
	skip_inline_space(p)
	if peek(p) != ']' do return fail(p, "expected ']'")
	p.pos += 1

	p.current = descend(p, p.root, keys) or_return
	return true
}

@(private)
parse_key_value :: proc(p: ^Parser, into: ^Table) -> bool {
	keys := parse_key(p) or_return
	skip_inline_space(p)
	if peek(p) != '=' do return fail(p, "expected '=' after key")
	p.pos += 1
	skip_inline_space(p)
	value := parse_value(p) or_return

	t := descend(p, into, keys[:len(keys) - 1]) or_return
	last := keys[len(keys) - 1]
	if last in t do return fail(p, strings.concatenate({"duplicate key '", last, "'"}))
	t[last] = value
	return true
}

// Walks (creating as needed) the tables named by keys, starting at t.
@(private)
descend :: proc(p: ^Parser, t: ^Table, keys: []string) -> (^Table, bool) {
	t := t
	for k in keys {
		if existing, found := t[k]; found {
			inner, is_table := existing.(^Table)
			if !is_table {
				fail(p, strings.concatenate({"'", k, "' is not a table"}))
				return nil, false
			}
			t = inner
		} else {
			inner := new(Table)
			t[k] = inner
			t = inner
		}
	}
	return t, true
}

// key or a.b."c d"
@(private)
parse_key :: proc(p: ^Parser) -> (keys: []string, ok: bool) {
	out := make([dynamic]string)
	for {
		skip_inline_space(p)
		switch c := peek(p); {
		case c == '"':
			s := parse_basic_string(p) or_return
			append(&out, s)
		case c == '\'':
			s := parse_literal_string(p) or_return
			append(&out, s)
		case is_bare_key_char(c):
			start := p.pos
			for is_bare_key_char(peek(p)) do p.pos += 1
			append(&out, strings.clone(p.src[start:p.pos]))
		case:
			fail(p, "expected a key")
			return nil, false
		}
		skip_inline_space(p)
		if peek(p) != '.' do break
		p.pos += 1
	}
	return out[:], true
}

@(private)
is_bare_key_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
}

@(private)
parse_value :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	c := peek(p)
	switch {
	case c == '"':
		if peek(p, 1) == '"' && peek(p, 2) == '"' do return nil, fail(p, "multi-line strings are not supported")
		return parse_basic_string(p)
	case c == '\'':
		if peek(p, 1) == '\'' && peek(p, 2) == '\'' do return nil, fail(p, "multi-line strings are not supported")
		return parse_literal_string(p)
	case c == '[':
		return parse_array(p)
	case c == '{':
		return parse_inline_table(p)
	case c == 't' || c == 'f':
		for word in ([]string{"true", "false"}) {
			if strings.has_prefix(p.src[p.pos:], word) && !is_bare_key_char(peek(p, len(word))) {
				p.pos += len(word)
				return word == "true", true
			}
		}
	case c == '+' || c == '-' || (c >= '0' && c <= '9') || c == 'i' || c == 'n':
		return parse_number(p)
	}
	return nil, fail(p, "expected a value")
}

@(private)
parse_number :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	start := p.pos
	for !at_end(p) {
		c := peek(p)
		if is_bare_key_char(c) || c == '+' || c == '.' {
			p.pos += 1
		} else {
			break
		}
	}
	text, _ := strings.remove_all(p.src[start:p.pos], "_", context.temp_allocator)
	switch text {
	case "inf", "+inf": return math.INF_F64, true
	case "-inf":        return math.NEG_INF_F64, true
	}
	if n, int_ok := strconv.parse_i64(text); int_ok do return n, true
	if strings.contains_any(text, ".eE") {
		if f, float_ok := strconv.parse_f64(text); float_ok do return f, true
	}
	if strings.contains_any(text, ":-") && len(text) >= 8 {
		return nil, fail(p, "dates and times are not supported")
	}
	return nil, fail(p, strings.concatenate({"invalid number '", p.src[start:p.pos], "'"}))
}

@(private)
parse_literal_string :: proc(p: ^Parser) -> (s: string, ok: bool) {
	p.pos += 1
	start := p.pos
	for !at_end(p) && peek(p) != '\'' {
		if peek(p) == '\n' do return "", fail(p, "unterminated string")
		p.pos += 1
	}
	if at_end(p) do return "", fail(p, "unterminated string")
	s = strings.clone(p.src[start:p.pos])
	p.pos += 1
	return s, true
}

@(private)
parse_basic_string :: proc(p: ^Parser) -> (s: string, ok: bool) {
	p.pos += 1
	sb := strings.builder_make()
	for {
		if at_end(p) || peek(p) == '\n' do return "", fail(p, "unterminated string")
		c := peek(p)
		p.pos += 1
		switch c {
		case '"':
			return strings.to_string(sb), true
		case '\\':
			e := peek(p)
			p.pos += 1
			switch e {
			case '"':  strings.write_byte(&sb, '"')
			case '\\': strings.write_byte(&sb, '\\')
			case 'n':  strings.write_byte(&sb, '\n')
			case 't':  strings.write_byte(&sb, '\t')
			case 'r':  strings.write_byte(&sb, '\r')
			case 'b':  strings.write_byte(&sb, '\b')
			case 'f':  strings.write_byte(&sb, '\f')
			case 'u', 'U':
				n := e == 'u' ? 4 : 8
				if p.pos + n > len(p.src) do return "", fail(p, "bad unicode escape")
				code, code_ok := strconv.parse_u64_of_base(p.src[p.pos:][:n], 16)
				if !code_ok do return "", fail(p, "bad unicode escape")
				p.pos += n
				buf, size := utf8.encode_rune(rune(code))
				strings.write_bytes(&sb, buf[:size])
			case:
				return "", fail(p, "unknown escape sequence")
			}
		case:
			strings.write_byte(&sb, c)
		}
	}
}

@(private)
parse_array :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	p.pos += 1
	items := make([dynamic]Value)
	for {
		skip_space(p)
		if peek(p) == ']' {
			p.pos += 1
			return items[:], true
		}
		item := parse_value(p) or_return
		append(&items, item)
		skip_space(p)
		switch peek(p) {
		case ',':
			p.pos += 1
		case ']':
			p.pos += 1
			return items[:], true
		case:
			return nil, fail(p, "expected ',' or ']' in array")
		}
	}
}

@(private)
parse_inline_table :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	p.pos += 1
	t := new(Table)
	skip_inline_space(p)
	if peek(p) == '}' {
		p.pos += 1
		return t, true
	}
	for {
		parse_key_value(p, t) or_return
		skip_inline_space(p)
		switch peek(p) {
		case ',':
			p.pos += 1
		case '}':
			p.pos += 1
			return t, true
		case:
			return nil, fail(p, "expected ',' or '}' in inline table")
		}
	}
}
