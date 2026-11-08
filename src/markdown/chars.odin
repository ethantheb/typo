package markdown

// ASCII character classes used by the parsers


@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}


@(private)
is_blank :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !is_space(c) do return false
	}
	return true
}


@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}


@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}


@(private)
is_alnum :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c)
}


@(private)
is_ascii_punct :: proc(c: u8) -> bool {
	switch c {
	case '!' ..= '/', ':' ..= '@', '[' ..= '`', '{' ..= '~':
		return true
	}
	return false
}
