package markdown

import "core:strings"

// HTML recognition shared by block and inline parsing: CommonMark's HTML block
// start/end conditions and raw HTML tags.

@(private = "file")
BLOCK_TAGS := [?]string {
	"address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
	"colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
	"footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
	"html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
	"optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
	"th", "thead", "title", "tr", "track", "ul",
}

@(private = "file")
RAW_TAGS := [?]string{"pre", "script", "style", "textarea"}

@(private = "file")
RAW_ENDS := [?]string{"</pre>", "</script>", "</style>", "</textarea>"}

// The HTML block type (1-7) that `s` (starting at '<') opens, or 0. Type 7
// can't interrupt a paragraph.
html_block_start :: proc(s: string, interrupting: bool) -> u8 {
	if len(s) < 2 || s[0] != '<' do return 0
	switch {
	case strings.has_prefix(s, "<!--"):      return 2
	case s[1] == '?':                        return 3
	case strings.has_prefix(s, "<![CDATA["): return 5
	case s[1] == '!':                        return len(s) > 2 && is_alpha(s[2]) ? 4 : 0
	}
	closing := s[1] == '/'
	lo := closing ? 2 : 1
	n := lo
	for n < len(s) && (is_alnum(s[n]) || s[n] == '-') do n += 1
	name := s[lo:n]
	if name == "" || !is_alpha(name[0]) do return 0
	after := n < len(s) ? s[n] : ' '
	ends_name := after == ' ' || after == '\t' || after == '>'
	if !closing {
		for t in RAW_TAGS do if ends_name && strings.equal_fold(name, t) do return 1
	}
	for t in BLOCK_TAGS {
		if strings.equal_fold(name, t) && (ends_name || strings.has_prefix(s[n:], "/>")) do return 6
	}
	if interrupting do return 0
	if l := html_tag_len(s); l > 0 && (closing || html_open_tag_len(s) > 0) && is_blank(s[l:]) do return 7
	return 0
}

// Whether `s` contains the end condition of an HTML block of type 1-5.
html_block_ends :: proc(kind: u8, s: string) -> bool {
	switch kind {
	case 1:
		for e in RAW_ENDS do if contains_fold(s, e) do return true
		return false
	case 2: return strings.contains(s, "-->")
	case 3: return strings.contains(s, "?>")
	case 4: return strings.contains(s, ">")
	case 5: return strings.contains(s, "]]>")
	}
	return false
}

// Length of the raw HTML (tag, comment, processing instruction, declaration or
// CDATA) at the start of `s`, or 0.
html_tag_len :: proc(s: string) -> int {
	if len(s) < 3 || s[0] != '<' do return 0
	find_end :: proc(s: string, from: int, end: string) -> int {
		if from > len(s) do return 0
		i := strings.index(s[from:], end)
		return i < 0 ? 0 : from + i + len(end)
	}
	switch {
	case strings.has_prefix(s, "<!-->"):     return 5
	case strings.has_prefix(s, "<!--->"):    return 6
	case strings.has_prefix(s, "<!--"):      return find_end(s, 4, "-->")
	case strings.has_prefix(s, "<?"):        return find_end(s, 2, "?>")
	case strings.has_prefix(s, "<![CDATA["): return find_end(s, 9, "]]>")
	case s[1] == '!':                        return is_alpha(s[2]) ? find_end(s, 2, ">") : 0
	case s[1] == '/':
		n := 2
		if !is_alpha(s[n]) do return 0
		for n < len(s) && (is_alnum(s[n]) || s[n] == '-') do n += 1
		for n < len(s) && is_space(s[n]) do n += 1
		return n < len(s) && s[n] == '>' ? n + 1 : 0
	}
	return html_open_tag_len(s)
}

// Length of an open tag (`<name attr="v" ...>` or `<name/>`) at the start of `s`, or 0.
@(private = "file")
html_open_tag_len :: proc(s: string) -> int {
	if len(s) < 3 || s[0] != '<' || !is_alpha(s[1]) do return 0
	n := 2
	for n < len(s) && (is_alnum(s[n]) || s[n] == '-') do n += 1
	for {
		ws := n
		for n < len(s) && is_space(s[n]) do n += 1
		if n >= len(s) do return 0
		switch s[n] {
		case '>': return n + 1
		case '/': return n + 1 < len(s) && s[n + 1] == '>' ? n + 2 : 0
		}
		// An attribute needs whitespace before it.
		if n == ws || !(is_alpha(s[n]) || s[n] == '_' || s[n] == ':') do return 0
		for n < len(s) && (is_alnum(s[n]) || s[n] == '_' || s[n] == '.' || s[n] == ':' || s[n] == '-') do n += 1
		v := n
		for v < len(s) && is_space(s[v]) do v += 1
		if v >= len(s) || s[v] != '=' do continue
		v += 1
		for v < len(s) && is_space(s[v]) do v += 1
		if v >= len(s) do return 0
		switch q := s[v]; q {
		case '"', '\'':
			end := strings.index_byte(s[v + 1:], q)
			if end < 0 do return 0
			n = v + 1 + end + 1
		case:
			n = v
			for n < len(s) && !is_space(s[n]) && strings.index_byte("\"'=<>`", s[n]) < 0 do n += 1
			if n == v do return 0
		}
	}
}

@(private = "file")
contains_fold :: proc(s, needle: string) -> bool {
	for i in 0 ..= len(s) - len(needle) {
		if strings.equal_fold(s[i:][:len(needle)], needle) do return true
	}
	return false
}
