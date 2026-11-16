package lsp

// Positions and file URIs. typo counts columns in bytes; a server counts them
// in UTF-16 code units unless it agreed to UTF-8 when initialized

import "core:strings"

import "../buffer"


Encoding :: enum {
	UTF16,
	UTF8,
}

Position :: struct {
	line:      int `json:"line"`,
	character: int `json:"character"`,
}

Range :: struct {
	start: Position `json:"start"`,
	end:   Position `json:"end"`,
}


// The server's column for byte column `col` of a line's text
to_column :: proc(text: string, col: int, enc: Encoding) -> int {
	col := clamp(col, 0, len(text))
	return enc == .UTF8 ? col : utf16_len(text[:col])
}


// The byte column of the server's `column` in a line's text, clamped to the
// line and never inside a character
from_column :: proc(text: string, column: int, enc: Encoding) -> int {
	if column <= 0 do return 0

	if enc == .UTF8 {
		col := min(column, len(text))
		for col < len(text) && is_continuation(text[col]) {
			col += 1
		}
		return col
	}

	units := 0
	for i := 0; i < len(text); {
		if units >= column do return i

		size := char_size(text[i])
		units += size == 4 ? 2 : 1
		i += size
	}
	return len(text)
}


// UTF-16 code units in UTF-8 text. A byte that starts no valid character counts
// as one unit, as decoders replace it with U+FFFD
utf16_len :: proc(text: string) -> int {
	units := 0
	for i := 0; i < len(text); {
		size := char_size(text[i])
		units += size == 4 ? 2 : 1
		i += size
	}
	return units
}


// The byte length of the character starting with `lead`
@(private = "file")
char_size :: proc(lead: u8) -> int {
	switch {
	case lead < 0x80:        return 1
	case lead & 0xE0 == 0xC0: return 2
	case lead & 0xF0 == 0xE0: return 3
	case lead & 0xF8 == 0xF0: return 4
	}
	return 1
}


@(private = "file")
is_continuation :: proc(b: u8) -> bool {
	return b & 0xC0 == 0x80
}


// --- In a document -----------------------------------------------------------------

// A document offset as a server's position
position_at :: proc(b: ^buffer.Buffer, offset: int, enc: Encoding) -> Position {
	offset := clamp(offset, 0, buffer.length(b))
	line := buffer.offset_to_line(b, offset)
	start := buffer.line_start(b, line)
	if enc == .UTF8 do return {line, offset - start}

	text := string(buffer.read_alloc(b, start, offset))
	return {line, utf16_len(text)}
}


// A server's position as a document offset, clamped to its line and the
// document, never inside a character
offset_at :: proc(b: ^buffer.Buffer, p: Position, enc: Encoding) -> int {
	if p.line < 0 do return 0
	if p.line >= buffer.line_count(b) do return buffer.length(b)

	// Only as much of the line as the column can cover (a UTF-16 unit is at most
	// three bytes, a pair four), so a long line isn't read whole
	start := buffer.line_start(b, p.line)
	end := buffer.line_end(b, p.line)
	need := max(p.character, 0) * 3 + 4
	if end - start > need do end = start + need

	text := string(buffer.read_alloc(b, start, end))
	return start + from_column(text, p.character, enc)
}


// --- URIs --------------------------------------------------------------------------

// "file:///C:/src/a%20b.odin" for C:\src\a b.odin
uri_from_path :: proc(path: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "file://")

	p, _ := strings.replace_all(path, `\`, "/", context.temp_allocator)
	if strings.has_prefix(p, "//") {
		// A UNC path: //server/share/... has the server as the authority
		p = p[2:]
	} else if !strings.has_prefix(p, "/") {
		strings.write_byte(&sb, '/')
	}

	for i in 0 ..< len(p) {
		c := p[i]
		if is_uri_safe(c) {
			strings.write_byte(&sb, c)
		} else {
			hex := "0123456789ABCDEF"
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, hex[c >> 4])
			strings.write_byte(&sb, hex[c & 15])
		}
	}
	return strings.to_string(sb)
}


// The path of a file URI, in the platform's form (backslashes and an upper-case
// drive letter on Windows)
path_from_uri :: proc(uri: string, allocator := context.allocator) -> (path: string, ok: bool) {
	PREFIX :: "file://"
	if len(uri) < len(PREFIX) || !strings.equal_fold(uri[:len(PREFIX)], PREFIX) {
		return "", false
	}
	rest := uri[len(PREFIX):]

	// Decode the escapes
	sb := strings.builder_make(context.temp_allocator)
	if !strings.has_prefix(rest, "/") {
		strings.write_string(&sb, "//") // a server name: a UNC path
	}
	for i := 0; i < len(rest); i += 1 {
		c := rest[i]
		hi, lo: u8
		hex_ok := false
		if c == '%' && i + 2 < len(rest) {
			hi, lo = hex_value(rest[i + 1]), hex_value(rest[i + 2])
			hex_ok = hi < 16 && lo < 16
		}
		if hex_ok {
			strings.write_byte(&sb, hi << 4 | lo)
			i += 2
		} else {
			strings.write_byte(&sb, c)
		}
	}
	decoded := strings.to_string(sb)

	when ODIN_OS == .Windows {
		// "/c:/src" is C:\src
		bytes := transmute([]u8)decoded
		has_drive := len(bytes) >= 3 && bytes[0] == '/' && bytes[2] == ':'
		if has_drive {
			bytes = bytes[1:]
			if bytes[0] >= 'a' && bytes[0] <= 'z' {
				bytes[0] -= 'a' - 'A'
			}
		}
		native, allocated := strings.replace_all(string(bytes), "/", `\`, allocator)
		if !allocated do native = strings.clone(native, allocator)
		return native, true
	} else {
		return strings.clone(decoded, allocator), true
	}
}


@(private = "file")
is_uri_safe :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	case '-', '.', '_', '~', '/', ':':
		return true
	}
	return false
}


// 0-15, or 255 for a byte that isn't a hex digit
@(private = "file")
hex_value :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9': return c - '0'
	case 'a' ..= 'f': return c - 'a' + 10
	case 'A' ..= 'F': return c - 'A' + 10
	}
	return 255
}
