package markdown

import "core:encoding/entity"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Inline syntax (CommonMark + GFM, plus ==highlight==, $math$, [[wikilinks]],
// ![[embeds]] and [^footnote] references to defined footnotes) over one block's
// text. Strikethrough takes exactly two tildes, as in Obsidian (GFM also allows
// one). Spans record the exact bytes of their markers so the view can hide or
// show them.

Span_Kind :: enum u8 {
	Emph,
	Strong,
	Strike,
	Highlight,
	Code,
	Link,
	Image,
	Autolink, // <https://...>
	Url,      // a bare www. / http(s):// link or email address
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
	title:             [2]i32, // an inline link's title, inside its quotes
	kind:              Span_Kind,
	reference:         bool, // url is a reference label, resolved through the definitions
	embed:             bool, // "![[target]]": url names a file or note, shown in place
}

// Link reference and footnote definitions by label_hash: the line of the first
// one with each label.
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
			if j := entity_len(s[i:]); j > 0 {
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
				if end := footnote_ref(s, i); end > 0 && p.labels != nil && label_hash(s[i + 2:end - 1], true) in p.labels {
					add_span(&p, .Footnote_Ref, i, end, i + 2, end - 1)
					i = end
					continue
				}
			}
			append(&p.brackets, Bracket{i32(i), false, true, len(p.delims)})
		case '!':
			// An embed: "![[image.png]]" is an image, "![[Note]]" a wikilink.
			if i + 2 < len(s) && s[i + 1] == '[' && s[i + 2] == '[' {
				if end, target_hi, alias_lo := wikilink(s, i + 1); end > 0 {
					sp := make_span(.Wikilink, i, end, alias_lo, end - 2)
					if is_image_name(s[i + 3:target_hi]) do sp = make_span(.Image, i, end, i + 3, target_hi)
					sp.url = {i32(i + 3), i32(target_hi)}
					sp.embed = true
					append(p.out, sp)
					i = end
					continue
				}
			}
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
		case 'w', 'h', 'f':
			if end := bare_url(s, i, in_link(&p)); end > 0 {
				sp := make_span(.Url, i, end, i, end)
				sp.url = {i32(i), i32(end)}
				append(p.out, sp)
				i = end
				continue
			}
		case '@':
			if lo, end := email(&p, i); end > 0 {
				sp := make_span(.Url, lo, end, lo, end)
				sp.url = {i32(lo), i32(end)}
				append(p.out, sp)
				i = end
				continue
			}
		}
		i += 1
	}
	process_emphasis(&p, 0)
}

// Appends the spans of a table row (see row_iterator): each cell parsed on its
// own, without the spaces around it, in offsets of `text`.
inline_parse_row :: proc(text: string, labels: ^Labels, out: ^[dynamic]Span) {
	it := row_iterator(text)
	for lo, hi in row_next(&it) {
		lo, hi := lo, hi
		for lo < hi && (text[lo] == ' ' || text[lo] == '\t') do lo += 1
		for hi > lo && (text[hi - 1] == ' ' || text[hi - 1] == '\t') do hi -= 1
		first := len(out)
		inline_parse(text[lo:hi], labels, out)
		for &s in out[first:] {
			s.lo, s.hi, s.open_hi, s.close_lo = s.lo + i32(lo), s.hi + i32(lo), s.open_hi + i32(lo), s.close_lo + i32(lo)
			s.url += i32(lo)
			s.title += i32(lo)
		}
	}
}

// FNV-1a of a normalized reference label: case-folded, whitespace runs as one
// space, trimmed. Footnote labels hash differently from link labels.
label_hash :: proc(label: string, footnote := false) -> u64 {
	h: u64 = 0xcbf29ce484222325
	if footnote do h = (h ~ '^') * 0x100000001b3
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
		for f in fold(r) {
			if f == 0 do break
			buf, n := utf8.encode_rune(f)
			for b in buf[:n] do h = (h ~ u64(b)) * 0x100000001b3
		}
	}
	return h
}

// Unicode case folding: lower case, plus the folds that differ from it.
@(private = "file")
fold :: proc(r: rune) -> [2]rune {
	switch r {
	case 'ß', 'ẞ': return {'s', 's'}
	case 'ς':      return {'σ', 0}
	case 'ſ':      return {'s', 0}
	}
	return {unicode.to_lower(r), 0}
}

// s with backslash escapes and entity references replaced by the characters
// they stand for, as in a link destination or title.
unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
			i += 1
			strings.write_byte(&sb, s[i])
			continue
		}
		if j := entity_len(s[i:]); s[i] == '&' && j > 0 {
			buf, w, _ := entity.unescape_entity(s[i:i + j])
			strings.write_string(&sb, string(buf[:w]))
			i += j - 1
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
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

// The length of the entity reference at the start of s ("&amp;", "&#123;",
// "&#x1F;"), or 0. Numeric ones have at most 7 decimal or 6 hex digits.
@(private)
entity_len :: proc(s: string) -> int {
	if len(s) > 2 && s[1] == '#' {
		hex := s[2] == 'x' || s[2] == 'X'
		lo := hex ? 3 : 2
		j := lo
		for j < len(s) && (is_digit(s[j]) || (hex && strings.index_byte("abcdefABCDEF", s[j]) >= 0)) do j += 1
		if j == lo || j - lo > (hex ? 6 : 7) || j >= len(s) || s[j] != ';' do return 0
		return j + 1
	}
	if _, w, j := entity.unescape_entity(s); w > 0 && j > 1 && j <= len(s) && s[j - 1] == ';' do return j
	return 0
}

// Whether a file name has an image extension.
@(private = "file")
is_image_name :: proc(name: string) -> bool {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 do return false
	switch strings.to_lower(name[dot + 1:], context.temp_allocator) {
	case "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "tga", "psd":
		return true
	}
	return false
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

// Whether an open bracket could still become a link.
@(private = "file")
in_link :: proc(p: ^Parser) -> bool {
	for b in p.brackets do if b.active && !b.image do return true
	return false
}

// A GFM extended autolink starting at i (www., http(s):// or ftp://), or 0.
// Inside a link's text it ends before a ']'.
@(private = "file")
bare_url :: proc(s: string, i: int, in_link: bool) -> int {
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
	case strings.has_prefix(rest, "ftp://"):   lo = 6
	case:                                      return 0
	}
	end := lo
	for end < len(rest) && !is_space(rest[end]) && rest[end] != '<' && !(in_link && rest[end] == ']') do end += 1
	// Trailing punctuation isn't part of the link, nor an unbalanced ')', nor
	// what looks like an entity reference ("&hl;").
	for end > lo {
		c := rest[end - 1]
		if strings.index_byte("?!.,:*_~'\"", c) >= 0 {
			end -= 1
			continue
		}
		if c == ';' {
			amp := end - 2
			for amp > lo && is_alnum(rest[amp]) do amp -= 1
			if amp < end - 2 && rest[amp] == '&' {
				end = amp
				continue
			}
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

// A GFM extended email autolink around the '@' at i: its start and end, or
// end = 0. The address doesn't start inside an earlier span or delimiter run.
@(private = "file")
email :: proc(p: ^Parser, i: int) -> (lo, end: int) {
	s := p.s
	lo = i
	for lo > 0 && (is_alnum(s[lo - 1]) || strings.index_byte(".+-_", s[lo - 1]) >= 0) do lo -= 1
	for sp in p.out do if int(sp.hi) > lo && int(sp.lo) < i do lo = max(lo, int(sp.hi))
	for d in p.delims do if int(d.pos + d.count) > lo && int(d.pos) < i do lo = max(lo, int(d.pos + d.count))
	if lo >= i do return 0, 0
	// The domain: letters, digits, '-', '_' and dots followed by one of those.
	dots := 0
	end = i + 1
	for end < len(s) {
		c := s[end]
		if c == '.' && end + 1 < len(s) && is_alnum(s[end + 1]) {
			dots += 1
		} else if !is_alnum(c) && c != '-' && c != '_' {
			break
		}
		end += 1
	}
	if dots == 0 || !is_alpha(s[end - 1]) do return 0, 0
	return lo, end
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
	if (c == '=' || c == '~') && n != 2 do return end

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
	title: [2]int
	reference := false
	if i + 1 < len(s) && s[i + 1] == '(' {
		end, url_lo, url_hi, title = inline_destination(s, i + 2)
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
		if p.labels != nil && label_hi > label_lo && !unescaped_bracket(s[label_lo:label_hi]) && label_hash(s[label_lo:label_hi]) in p.labels {
			end, url_lo, url_hi = after, label_lo, label_hi
			reference = true
		}
	}
	if end < 0 do return 0

	process_emphasis(p, b.delims)
	sp := make_span(b.image ? .Image : .Link, int(b.pos), end, text_lo, i)
	sp.url = {i32(url_lo), i32(url_hi)}
	sp.title = {i32(title[0]), i32(title[1])}
	sp.reference = reference
	if !b.image {
		// No links inside links.
		for &o in p.brackets do if !o.image do o.active = false
		#reverse for o, k in p.out do if o.kind == .Url && int(o.lo) >= text_lo && int(o.hi) <= i do ordered_remove(p.out, k)
	}
	append(p.out, sp)
	return end
}

// Whether a label holds a ']' not escaped by a backslash.
@(private = "file")
unescaped_bracket :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '\\': i += 1
		case ']':  return true
		}
	}
	return false
}

// Parses `(dest "title")` from just after the '('. Returns the end (after ')'),
// the destination and the title (inside its quotes), or end = -1.
@(private = "file")
inline_destination :: proc(s: string, from: int) -> (end, lo, hi: int, title: [2]int) {
	j := skip_link_space(s, from)
	lo = j
	if j < len(s) && s[j] == '<' {
		k := j + 1
		for k < len(s) && s[k] != '>' && s[k] != '\n' && s[k] != '<' {
			if s[k] == '\\' do k += 1
			k += 1
		}
		if k >= len(s) || s[k] != '>' do return -1, 0, 0, {}
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
		if depth != 0 do return -1, 0, 0, {}
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
		if m >= len(s) do return -1, 0, 0, {}
		title = {k + 1, m}
		k = skip_link_space(s, m + 1)
	}
	if k >= len(s) || s[k] != ')' do return -1, 0, 0, {}
	return k + 1, lo, hi, title
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
