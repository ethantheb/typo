package markdown

import "core:encoding/entity"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Inline syntax (CommonMark + GFM, plus ==highlight==, $math$, [[wikilinks]] and
// [^footnote] references) over one block's text. Spans record the exact bytes
// of their markers so the view can hide or show them.

Span_Kind :: enum u8 {
	Emph,
	Strong,
	Strike,
	Highlight,
	Code,
	Link,
	Image,
	Autolink, // <https://...>
	Url,      // a bare www. / http(s):// link
	Wikilink,
	Footnote_Ref,
	Html,
	Math,
	Escape,
	Entity,
	Hard_Break,
}

// Byte offsets into the parsed text. The opening marker is [lo, open_hi), the
// closing one [close_lo, hi) and the content between them.
Span :: struct {
	lo, hi:            i32,
	open_hi, close_lo: i32,
	url:               [2]i32, // a link's destination, or a reference link's label
	kind:              Span_Kind,
	reference:         bool, // url is a reference label, resolved through the definitions
}

// Link reference definitions by label_hash: the line of the first one with
// each label.
Labels :: map[u64]int

@(private = "file")
Delim :: struct {
	pos:       i32, // of the remaining run
	count:     i32, // characters left in the run
	orig:      i32, // run length as parsed
	ch:        u8,
	can_open:  bool,
	can_close: bool,
	removed:   bool,
}

@(private = "file")
Bracket :: struct {
	pos:    i32,
	image:  bool,
	active: bool,
	delims: int, // delimiter stack size when pushed
}

@(private = "file")
Parser :: struct {
	s:        string,
	labels:   ^Labels,
	out:      ^[dynamic]Span,
	delims:   [dynamic]Delim,
	brackets: [dynamic]Bracket,
}

// Appends the spans of `text` (a block's content, lines joined by '\n') to `out`.
inline_parse :: proc(text: string, labels: ^Labels, out: ^[dynamic]Span) {
	p := Parser {
		s        = text,
		labels   = labels,
		out      = out,
		delims   = make([dynamic]Delim, context.temp_allocator),
		brackets = make([dynamic]Bracket, context.temp_allocator),
	}
	s := text
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
				add_span(&p, .Escape, i, i + 2, i + 1, i + 2)
				i += 2
				continue
			}
			if i + 1 < len(s) && s[i + 1] == '\n' {
				add_span(&p, .Hard_Break, i, i + 1, i + 1, i + 1)
			}
		case '`':
			if end := code_span(s, i); end > 0 {
				run := run_length(s, i, '`')
				add_span(&p, .Code, i, end, i + run, end - run)
				i = end
				continue
			}
			i += run_length(s, i, '`')
			continue
		case '<':
			if end, url_lo, url_hi := autolink(s, i); end > 0 {
				sp := make_span(.Autolink, i, end, i + 1, end - 1)
				sp.url = {i32(url_lo), i32(url_hi)}
				append(p.out, sp)
				i = end
				continue
			}
			if l := html_tag_len(s[i:]); l > 0 {
				add_span(&p, .Html, i, i + l, i, i + l)
				i += l
				continue
			}
		case '&':
			if _, w, j := entity.unescape_entity(s[i:]); w > 0 && j > 1 && i + j <= len(s) && s[i + j - 1] == ';' {
				add_span(&p, .Entity, i, i + j, i + j, i + j)
				i += j
				continue
			}
		case '$':
			if end, run := math_span(s, i); end > 0 {
				add_span(&p, .Math, i, end, i + run, end - run)
				i = end
				continue
			}
		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				if end, target_hi, alias_lo := wikilink(s, i); end > 0 {
					sp := make_span(.Wikilink, i, end, alias_lo, end - 2)
					sp.url = {i32(i + 2), i32(target_hi)}
					append(p.out, sp)
					i = end
					continue
				}
			}
			if i + 1 < len(s) && s[i + 1] == '^' {
				if end := footnote_ref(s, i); end > 0 {
					add_span(&p, .Footnote_Ref, i, end, i + 2, end - 1)
					i = end
					continue
				}
			}
			append(&p.brackets, Bracket{i32(i), false, true, len(p.delims)})
		case '!':
			if i + 1 < len(s) && s[i + 1] == '[' {
				append(&p.brackets, Bracket{i32(i), true, true, len(p.delims)})
				i += 2
				continue
			}
		case ']':
			if end := close_bracket(&p, i); end > 0 {
				i = end
				continue
			}
		case '*', '_', '~', '=':
			i = push_delimiter(&p, i)
			continue
		case 'w', 'h':
			if end := bare_url(s, i); end > 0 {
				sp := make_span(.Url, i, end, i, end)
				sp.url = {i32(i), i32(end)}
				append(p.out, sp)
				i = end
				continue
			}
		}
		i += 1
	}
	process_emphasis(&p, 0)
}

// FNV-1a of a normalized reference label: case-folded, whitespace runs as one
// space, trimmed.
label_hash :: proc(label: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	space := false
	started := false
	for r in label {
		if unicode.is_space(r) {
			space = started
			continue
		}
		if space {
			h = (h ~ ' ') * 0x100000001b3
			space = false
		}
		started = true
		buf, n := utf8.encode_rune(unicode.to_lower(r))
		for b in buf[:n] do h = (h ~ u64(b)) * 0x100000001b3
	}
	return h
}

@(private = "file")
make_span :: proc(kind: Span_Kind, lo, hi, open_hi, close_lo: int) -> Span {
	return {lo = i32(lo), hi = i32(hi), open_hi = i32(open_hi), close_lo = i32(close_lo), kind = kind}
}

@(private = "file")
add_span :: proc(p: ^Parser, kind: Span_Kind, lo, hi, open_hi, close_lo: int) {
	append(p.out, make_span(kind, lo, hi, open_hi, close_lo))
}

@(private = "file")
run_length :: proc(s: string, i: int, c: u8) -> int {
	n := 0
	for i + n < len(s) && s[i + n] == c do n += 1
	return n
}

// End of the code span opened by the backtick run at i, or 0.
@(private = "file")
code_span :: proc(s: string, i: int) -> int {
	n := run_length(s, i, '`')
	j := i + n
	for j < len(s) {
		k := strings.index_byte(s[j:], '`')
		if k < 0 do return 0
		j += k
		m := run_length(s, j, '`')
		if m == n do return j + m
		j += m
	}
	return 0
}

// An autolink `<scheme:...>` or `<user@host>`: its end and the destination.
@(private = "file")
autolink :: proc(s: string, i: int) -> (end, url_lo, url_hi: int) {
	j := i + 1
	// URI: a scheme of 2-32 characters, ':', then no spaces, '<' or '>'.
	k := j
	for k < len(s) && (is_alnum(s[k]) || s[k] == '+' || s[k] == '.' || s[k] == '-') do k += 1
	if k - j >= 2 && k - j <= 32 && is_alpha(s[j]) && k < len(s) && s[k] == ':' {
		for k < len(s) && s[k] > ' ' && s[k] != '<' && s[k] != '>' do k += 1
		if k < len(s) && s[k] == '>' do return k + 1, j, k
		return
	}
	// Email.
	k = j
	for k < len(s) && (is_alnum(s[k]) || strings.index_byte(".!#$%&'*+/=?^_`{|}~-", s[k]) >= 0) do k += 1
	if k == j || k >= len(s) || s[k] != '@' do return
	k += 1
	host := k
	for k < len(s) && (is_alnum(s[k]) || s[k] == '-' || s[k] == '.') do k += 1
	if k == host || k >= len(s) || s[k] != '>' do return
	return k + 1, j, k
}

// `$x$` or `$$x$$` on one line: the end and the marker length, or 0. The
// content can't start or end with a space, and a closing `$` can't be followed
// by a digit (so prices stay text).
@(private = "file")
math_span :: proc(s: string, i: int) -> (end, run: int) {
	run = min(run_length(s, i, '$'), 2)
	if run_length(s, i, '$') > 2 do return 0, 0
	lo := i + run
	if lo >= len(s) || is_space(s[lo]) do return 0, 0
	for j := lo; j < len(s); j += 1 {
		switch s[j] {
		case '\n': return 0, 0
		case '\\': j += 1
		case '$':
			if run_length(s, j, '$') != run || is_space(s[j - 1]) || j == lo do continue
			after := j + run
			if after < len(s) && is_digit(s[after]) do continue
			return after, run
		}
	}
	return 0, 0
}

// `[[target]]` or `[[target|alias]]` on one line: the end, where the target
// ends and where the shown text starts.
@(private = "file")
wikilink :: proc(s: string, i: int) -> (end, target_hi, text_lo: int) {
	j := i + 2
	target_hi = -1
	for j < len(s) {
		switch s[j] {
		case '\n', '[':
			return 0, 0, 0
		case '|':
			if target_hi < 0 do target_hi = j
		case ']':
			if j + 1 >= len(s) || s[j + 1] != ']' || j == i + 2 do return 0, 0, 0
			if target_hi < 0 do return j + 2, j, i + 2
			return j + 2, target_hi, target_hi + 1
		}
		j += 1
	}
	return 0, 0, 0
}

// `[^label]` with no spaces in the label: its end, or 0.
@(private = "file")
footnote_ref :: proc(s: string, i: int) -> int {
	j := i + 2
	for j < len(s) && s[j] != ']' {
		if is_space(s[j]) || s[j] == '[' do return 0
		j += 1
	}
	if j >= len(s) || j == i + 2 do return 0
	return j + 1
}

// A GFM extended autolink starting at i (www. or http(s)://), or 0.
@(private = "file")
bare_url :: proc(s: string, i: int) -> int {
	if i > 0 {
		b := s[i - 1]
		if !is_space(b) && b != '*' && b != '_' && b != '~' && b != '(' do return 0
	}
	rest := s[i:]
	lo := 0
	switch {
	case strings.has_prefix(rest, "www."):     lo = 4
	case strings.has_prefix(rest, "http://"):  lo = 7
	case strings.has_prefix(rest, "https://"): lo = 8
	case:                                      return 0
	}
	end := lo
	for end < len(rest) && !is_space(rest[end]) && rest[end] != '<' do end += 1
	// Trailing punctuation isn't part of the link, nor an unbalanced ')'.
	for end > lo {
		c := rest[end - 1]
		if strings.index_byte("?!.,:*_~'\"", c) >= 0 {
			end -= 1
			continue
		}
		if c == ')' && strings.count(rest[:end], "(") < strings.count(rest[:end], ")") {
			end -= 1
			continue
		}
		break
	}
	domain := rest[lo:end]
	if slash := strings.index_byte(domain, '/'); slash >= 0 do domain = domain[:slash]
	if domain == "" || (lo == 4 && strings.index_byte(domain, '.') < 0) do return 0
	return i + end
}

// --- Emphasis -----------------------------------------------------------------------

@(private = "file")
is_unicode_space :: proc(r: rune) -> bool {
	return r == utf8.RUNE_ERROR || unicode.is_space(r)
}

@(private = "file")
is_unicode_punct :: proc(r: rune) -> bool {
	if r < 0x80 do return is_ascii_punct(u8(r))
	return unicode.is_punct(r) || unicode.is_symbol(r)
}

// Pushes the delimiter run at i (*, _, ~ or =) and returns where it ends.
@(private = "file")
push_delimiter :: proc(p: ^Parser, i: int) -> int {
	s := p.s
	c := s[i]
	n := run_length(s, i, c)
	end := i + n
	if (c == '=' && n != 2) || (c == '~' && n > 2) do return end

	before: rune = ' '
	if i > 0 do before, _ = utf8.decode_last_rune_in_string(s[:i])
	after: rune = ' '
	if end < len(s) do after, _ = utf8.decode_rune_in_string(s[end:])
	if before == '\n' do before = ' '
	left := !is_unicode_space(after) && (!is_unicode_punct(after) || is_unicode_space(before) || is_unicode_punct(before))
	right := !is_unicode_space(before) && (!is_unicode_punct(before) || is_unicode_space(after) || is_unicode_punct(after))

	can_open, can_close := left, right
	if c == '_' {
		can_open = left && (!right || is_unicode_punct(before))
		can_close = right && (!left || is_unicode_punct(after))
	}
	if can_open || can_close {
		append(&p.delims, Delim{pos = i32(i), count = i32(n), orig = i32(n), ch = c, can_open = can_open, can_close = can_close})
	}
	return end
}

// Matches emphasis delimiters above stack index `bottom` (CommonMark's
// "process emphasis"), then drops them.
@(private = "file")
process_emphasis :: proc(p: ^Parser, bottom: int) {
	d := p.delims[:]
	// Lowest index an opener for a closer of each kind can be at; below it a
	// search already failed. Keyed by character, closer length % 3 and can_open.
	openers_bottom: [4][3][2]int
	for &a in openers_bottom do for &b in a do for &x in b do x = bottom
	char_index :: proc(c: u8) -> int {
		switch c {
		case '*': return 0
		case '_': return 1
		case '~': return 2
		}
		return 3
	}

	for ci := bottom; ci < len(d); ci += 1 {
		closer := &d[ci]
		if closer.removed || !closer.can_close do continue
		for closer.count > 0 {
			key := &openers_bottom[char_index(closer.ch)][closer.orig % 3][closer.can_open ? 1 : 0]
			found := -1
			for oi := ci - 1; oi >= key^; oi -= 1 {
				o := &d[oi]
				if o.removed || o.ch != closer.ch || !o.can_open || o.count == 0 do continue
				switch closer.ch {
				case '*', '_':
					odd := (o.can_close || closer.can_open) && (o.orig + closer.orig) % 3 == 0 && !(o.orig % 3 == 0 && closer.orig % 3 == 0)
					if odd do continue
				case '~':
					if o.count != closer.count do continue
				}
				found = oi
				break
			}
			if found < 0 {
				key^ = ci
				if !closer.can_open do closer.removed = true
				break
			}
			o := &d[found]
			use := i32(1)
			kind := Span_Kind.Emph
			switch closer.ch {
			case '*', '_':
				if o.count >= 2 && closer.count >= 2 {
					use = 2
					kind = .Strong
				}
			case '~':
				use = closer.count
				kind = .Strike
			case '=':
				use = 2
				kind = .Highlight
			}
			o.count -= use
			lo := o.pos + o.count
			append(p.out, Span{lo = lo, open_hi = lo + use, close_lo = closer.pos, hi = closer.pos + use, kind = kind})
			closer.pos += use
			closer.count -= use
			for k in found + 1 ..< ci do d[k].removed = true
			if o.count == 0 do o.removed = true
		}
		if closer.count == 0 do closer.removed = true
	}
	resize(&p.delims, bottom)
}

// --- Links ----------------------------------------------------------------------------

// Handles a ']' at i: a link or image if an opener matches and a destination or
// a defined label follows. Returns the end of the link, or 0.
@(private = "file")
close_bracket :: proc(p: ^Parser, i: int) -> int {
	if len(p.brackets) == 0 do return 0
	b := pop(&p.brackets)
	if !b.active do return 0
	s := p.s
	text_lo := int(b.pos) + (b.image ? 2 : 1)

	end, url_lo, url_hi := -1, 0, 0
	reference := false
	if i + 1 < len(s) && s[i + 1] == '(' {
		end, url_lo, url_hi = inline_destination(s, i + 2)
	}
	if end < 0 {
		label_lo, label_hi := text_lo, i
		after := i + 1
		if i + 1 < len(s) && s[i + 1] == '[' {
			close := strings.index_byte(s[i + 2:], ']')
			if close >= 0 && close <= 999 {
				if close > 0 do label_lo, label_hi = i + 2, i + 2 + close
				after = i + 2 + close + 1
			}
		}
		if p.labels != nil && label_hi > label_lo && strings.index_byte(s[label_lo:label_hi], ']') < 0 && label_hash(s[label_lo:label_hi]) in p.labels {
			end, url_lo, url_hi = after, label_lo, label_hi
			reference = true
		}
	}
	if end < 0 do return 0

	process_emphasis(p, b.delims)
	sp := make_span(b.image ? .Image : .Link, int(b.pos), end, text_lo, i)
	sp.url = {i32(url_lo), i32(url_hi)}
	sp.reference = reference
	append(p.out, sp)
	// No links inside links.
	if !b.image do for &o in p.brackets do if !o.image do o.active = false
	return end
}

// Parses `(dest "title")` from just after the '('. Returns the end (after ')')
// and the destination, or end = -1.
@(private = "file")
inline_destination :: proc(s: string, from: int) -> (end, lo, hi: int) {
	j := skip_link_space(s, from)
	lo = j
	if j < len(s) && s[j] == '<' {
		k := j + 1
		for k < len(s) && s[k] != '>' && s[k] != '\n' && s[k] != '<' {
			if s[k] == '\\' do k += 1
			k += 1
		}
		if k >= len(s) || s[k] != '>' do return -1, 0, 0
		lo, hi = j + 1, k
		j = k + 1
	} else {
		depth := 0
		for j < len(s) && s[j] > ' ' {
			if s[j] == '\\' && j + 1 < len(s) {
				j += 2
				continue
			}
			if s[j] == '(' do depth += 1
			if s[j] == ')' {
				if depth == 0 do break
				depth -= 1
			}
			j += 1
		}
		if depth != 0 do return -1, 0, 0
		hi = j
	}
	k := skip_link_space(s, j)
	if k < len(s) && k > j && (s[k] == '"' || s[k] == '\'' || s[k] == '(') {
		close := s[k] == '(' ? u8(')') : s[k]
		m := k + 1
		for m < len(s) && s[m] != close {
			if s[m] == '\\' do m += 1
			m += 1
		}
		if m >= len(s) do return -1, 0, 0
		k = skip_link_space(s, m + 1)
	}
	if k >= len(s) || s[k] != ')' do return -1, 0, 0
	return k + 1, lo, hi
}

// Skips spaces and tabs with at most one line break.
@(private = "file")
skip_link_space :: proc(s: string, j: int) -> int {
	j := j
	newline := false
	for j < len(s) && is_space(s[j]) {
		if s[j] == '\n' {
			if newline do break
			newline = true
		}
		j += 1
	}
	return j
}
