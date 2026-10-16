package syntax

import "core:strings"
import "core:time"

import "../buffer"

// Lexer backend: a line-based tokenizer whose only cross-line state is "inside
// a block comment (how deep)" or "inside a multi-line raw string". That state is
// saved every CHECKPOINT_LINES lines, so highlighting the visible lines only
// needs to lex from the nearest checkpoint above them, at any file size.
//
// Edits discard checkpoints after the edited line; they are rebuilt a little
// each frame (lexer_catch_up), working towards the line the view is showing.
// Until then the visible lines are lexed from the nearest valid checkpoint, or
// from a blank state if that is too far away, which can only mis-color text
// inside a multi-line comment/string for a moment.

CHECKPOINT_LINES :: 256
CATCH_UP_BUDGET :: 2 * time.Millisecond
// Lex at most this many lines above the view to reach the visible lines exactly.
MAX_LEAD_LINES :: 4 * CHECKPOINT_LINES

Lex_State :: struct {
	comment_depth: u8, // > 0 inside a block comment
	raw_string:    u8, // closing quote of a multi-line string, or 0
	triple:        bool, // the multi-line string closes with three quotes (Python)
}

Lexer_State :: struct {
	rules:       ^Lang_Rules,
	checkpoints: [dynamic]Lex_State, // checkpoints[k] = state at the start of line k*CHECKPOINT_LINES
	wanted_line: int,                // first visible line at the last highlight call
}

lexer_open :: proc(lx: ^Lexer_State, lang: Language) {
	lx.rules = rules_for(lang)
	append(&lx.checkpoints, Lex_State{})
}

lexer_close :: proc(lx: ^Lexer_State) {
	delete(lx.checkpoints)
	lx^ = {}
}

lexer_edit :: proc(lx: ^Lexer_State, changes: []buffer.Change) {
	for c in changes {
		// Checkpoint k depends only on lines before k*CHECKPOINT_LINES.
		keep := c.start.row / CHECKPOINT_LINES + 1
		if len(lx.checkpoints) > keep do resize(&lx.checkpoints, keep)
	}
}

// Rebuilds missing checkpoints up to the wanted line, within a time budget.
lexer_catch_up :: proc(lx: ^Lexer_State, b: ^buffer.Buffer) {
	target := min(lx.wanted_line, buffer.line_count(b) - 1) / CHECKPOINT_LINES
	if len(lx.checkpoints) > target do return
	deadline := time.tick_now()
	for len(lx.checkpoints) <= target {
		k := len(lx.checkpoints) - 1
		first := k * CHECKPOINT_LINES
		state := lex_lines(lx.rules, lx.checkpoints[k], b, first, first + CHECKPOINT_LINES, 0, nil)
		append(&lx.checkpoints, state)
		if time.tick_since(deadline) > CATCH_UP_BUDGET do break
	}
}

lexer_behind :: proc(lx: ^Lexer_State, b: ^buffer.Buffer) -> bool {
	target := min(lx.wanted_line, buffer.line_count(b) - 1) / CHECKPOINT_LINES
	return len(lx.checkpoints) <= target
}

lexer_highlight :: proc(lx: ^Lexer_State, b: ^buffer.Buffer, start: int, out: []Highlight) {
	first_line := buffer.offset_to_line(b, start)
	last_line := buffer.offset_to_line(b, start + len(out))
	lx.wanted_line = first_line

	// Start from the nearest valid checkpoint if it isn't too far above.
	k := min(first_line / CHECKPOINT_LINES, len(lx.checkpoints) - 1)
	from := k * CHECKPOINT_LINES
	state := lx.checkpoints[k]
	if first_line - from > MAX_LEAD_LINES {
		from, state = first_line, Lex_State{}
	}
	lex_lines(lx.rules, state, b, from, last_line + 1, start, out)
}

// Lexes lines [first, last) starting in `state` and returns the state after
// them. Highlights for document bytes [out_start, out_start+len(out)) are
// written to out; when there is an `out`, lexing stops at its end.
@(private = "file")
lex_lines :: proc(rules: ^Lang_Rules, state: Lex_State, b: ^buffer.Buffer, first, last: int, out_start: int, out: []Highlight) -> Lex_State {
	n := buffer.line_count(b)
	last := min(last, n)
	if first >= last do return state
	lo := buffer.line_start(b, first)
	hi := last >= n ? buffer.length(b) : buffer.line_start(b, last)
	if out != nil do hi = min(hi, out_start + len(out))
	text := buffer.read_alloc(b, lo, hi)

	state := state
	i := 0
	for i < len(text) {
		j := i
		for j < len(text) && text[j] != '\n' do j += 1
		line := text[i:j]
		line_lo := lo + i

		// Only produce highlights for lines overlapping the output range,
		// straight into `out` unless the line starts before it.
		out_end := out_start + len(out)
		switch {
		case len(out) == 0 || line_lo + len(line) < out_start || line_lo >= out_end:
			state = lex_line(rules, state, line, nil)
		case line_lo >= out_start:
			state = lex_line(rules, state, line, out[line_lo - out_start:][:len(line)])
		case:
			hl := make([]Highlight, len(line), context.temp_allocator)
			state = lex_line(rules, state, line, hl)
			copy(out, hl[out_start - line_lo:])
		}
		i = j + 1
	}
	return state
}

// --- Line tokenizer -------------------------------------------------------------

// Highlights one line (no '\n') and returns the state at its end. `out` may be
// nil when only the state is needed.
lex_line :: proc(r: ^Lang_Rules, state: Lex_State, line: []u8, out: []Highlight) -> Lex_State {
	state := state
	paint :: proc(out: []Highlight, lo, hi: int, h: Highlight) {
		if out == nil do return
		for i in lo ..< hi do out[i] = h
	}
	n := len(line)
	i := 0
	for i < n {
		// Continuations of multi-line constructs.
		if state.comment_depth > 0 {
			start := i
			for i < n {
				if i + 1 < n && line[i] == '*' && line[i + 1] == '/' {
					i += 2
					state.comment_depth -= 1
					if state.comment_depth == 0 do break
				} else if r.nested_comments && i + 1 < n && line[i] == '/' && line[i + 1] == '*' {
					i += 2
					state.comment_depth += 1
				} else {
					i += 1
				}
			}
			paint(out, start, i, .Comment)
			continue
		}
		if state.raw_string != 0 {
			start := i
			q := state.raw_string
			if state.triple {
				for i < n {
					if line[i] == '\\' {
						i += 2
					} else if i + 2 < n && line[i] == q && line[i + 1] == q && line[i + 2] == q {
						i += 3
						state.raw_string, state.triple = 0, false
						break
					} else {
						i += 1
					}
				}
				i = min(i, n)
			} else {
				for i < n && line[i] != q do i += 1
				if i < n {
					i += 1
					state.raw_string = 0
				}
			}
			paint(out, start, i, .String)
			continue
		}

		c := line[i]
		start := i
		switch {
		case r.line_comment != "" && strings.has_prefix(string(line[i:]), r.line_comment):
			paint(out, i, n, .Comment)
			return state
		case r.block_comments && c == '/' && i + 1 < n && line[i + 1] == '*':
			state.comment_depth = 1
			i += 2
			paint(out, start, i, .Comment)

		case r.triple_quotes && (c == '"' || c == '\'') && i + 2 < n && line[i + 1] == c && line[i + 2] == c:
			// Triple-quoted strings may span lines; the continuation code above finishes them.
			i += 3
			state.raw_string, state.triple = c, true
			paint(out, start, i, .String)

		case c == '"' || (c == '\'' && r.char_quote):
			i += 1
			for i < n && line[i] != c {
				if line[i] == '\\' && i + 1 < n {
					paint(out, start, i, .String)
					paint(out, i, i + 2, .Escape)
					i += 2
					start = i
					continue
				}
				i += 1
			}
			if i < n do i += 1
			paint(out, start, i, .String)

		case r.raw_quote != 0 && c == r.raw_quote:
			state.raw_string = c
			i += 1
			paint(out, start, i, .String)

		case is_digit(c) || (c == '.' && i + 1 < n && is_digit(line[i + 1])):
			i += 1
			for i < n && (is_ident(line[i]) || line[i] == '.' || ((line[i] == '+' || line[i] == '-') && (line[i - 1] == 'e' || line[i - 1] == 'E'))) {
				// Don't swallow a range operator (1..<n).
				if line[i] == '.' && i + 1 < n && line[i + 1] == '.' do break
				i += 1
			}
			paint(out, start, i, .Number)

		case is_ident_start(c):
			for i < n && is_ident(line[i]) do i += 1
			paint(out, start, i, classify_ident(r, string(line[start:i]), line[i:]))

		case c == '#' && r.directives:
			i += 1
			for i < n && is_ident(line[i]) do i += 1
			paint(out, start, i, r.directive_hl)

		case c == '@' && r.attributes:
			i += 1
			for i < n && is_ident(line[i]) do i += 1
			paint(out, start, i, .Attribute)

		case c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == ',' || c == ';' || c == '.' || c == ':':
			i += 1
			paint(out, start, i, .Punctuation)

		case is_operator(c):
			i += 1
			paint(out, start, i, .Operator)

		case:
			i += 1
		}
	}
	return state
}

@(private = "file")
classify_ident :: proc(r: ^Lang_Rules, word: string, rest: []u8) -> Highlight {
	for k in r.keywords do if k == word do return .Keyword
	for k in r.types do if k == word do return .Type
	for k in r.constants do if k == word do return .Constant
	for k in r.builtins do if k == word do return .Variable_Builtin

	// Heuristics: a call, an ALL_CAPS constant, a Capitalized type name.
	j := 0
	for j < len(rest) && (rest[j] == ' ' || rest[j] == '\t') do j += 1
	if j < len(rest) && rest[j] == '(' do return .Function
	upper, lower := false, false
	for ch in transmute([]u8)word {
		if ch >= 'A' && ch <= 'Z' do upper = true
		if ch >= 'a' && ch <= 'z' do lower = true
	}
	if upper && !lower && len(word) > 1 do return .Constant
	if word[0] >= 'A' && word[0] <= 'Z' && lower do return .Type
	return .None
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}

@(private = "file")
is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80
}

@(private = "file")
is_ident :: proc(c: u8) -> bool {return is_ident_start(c) || is_digit(c)}

@(private = "file")
is_operator :: proc(c: u8) -> bool {
	switch c {
	case '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?':
		return true
	}
	return false
}
