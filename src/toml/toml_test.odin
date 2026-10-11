package toml

import "core:strings"
import "core:testing"

@(test)
test_settings_like :: proc(t: ^testing.T) {
	src := `# typo settings
title = "editor" # trailing comment

[appearance]
theme = 'dark'
font_size = 15
scale = 1.25
big = 1_000_000
hex = 0xFF
on = true

[keybindings]
find_file = "Ctrl+E"
redo = ["Ctrl+Y", "Ctrl+Shift+Z",]
quoted."with space" = "a\tb é"
nested = [[1, 2], [],
  [3]]
inline = { a = 1, b.c = "x" }
`
	doc, err := parse(src)
	defer destroy(doc)
	if !testing.expectf(t, err.line == 0, "parse error at line %d: %s", err.line, err.msg) do return

	v, ok := get(doc.root, "title")
	testing.expect_value(t, v.(string), "editor")
	v, ok = get(doc.root, "appearance.theme");      testing.expect_value(t, v.(string), "dark")
	v, ok = get(doc.root, "appearance.font_size");  testing.expect_value(t, v.(i64), 15)
	v, ok = get(doc.root, "appearance.scale");      testing.expect_value(t, v.(f64), 1.25)
	v, ok = get(doc.root, "appearance.big");        testing.expect_value(t, v.(i64), 1_000_000)
	v, ok = get(doc.root, "appearance.hex");        testing.expect_value(t, v.(i64), 255)
	v, ok = get(doc.root, "appearance.on");         testing.expect_value(t, v.(bool), true)
	v, ok = get(doc.root, "keybindings.find_file"); testing.expect_value(t, v.(string), "Ctrl+E")
	v, ok = get(doc.root, "keybindings.redo")
	arr := v.([]Value)
	testing.expect_value(t, len(arr), 2)
	testing.expect_value(t, arr[1].(string), "Ctrl+Shift+Z")
	v, ok = get(doc.root, "keybindings.quoted")
	inner := v.(^Table)
	testing.expect_value(t, inner["with space"].(string), "a\tb é")
	v, ok = get(doc.root, "keybindings.nested")
	testing.expect_value(t, len(v.([]Value)), 3)
	v, ok = get(doc.root, "keybindings.inline.b.c")
	testing.expect_value(t, v.(string), "x")
	_, ok = get(doc.root, "appearance.missing")
	testing.expect(t, !ok)
}

@(test)
test_errors :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"a = ", "expected a value"},
		{"a = 1\na = 2", "duplicate key 'a'"},
		{"[x\n", "expected ']'"},
		{"s = \"open", "unterminated string"},
		{"a = 1 2", "expected end of line"},
		{"a = [1 2]", "expected ',' or ']' in array"},
		{"\n\nd = 1979-05-27", "dates and times are not supported"},
		{"[[arr]]", "arrays of tables ([[...]]) are not supported"},
	}
	for c in cases {
		doc, err := parse(c[0], context.temp_allocator)
		destroy(doc)
		testing.expectf(t, err.msg == c[1], "%q: got %q, want %q", c[0], err.msg, c[1])
	}
	_, err := parse("ok = 1\n\nbad = ", context.temp_allocator)
	testing.expect_value(t, err.line, 3)

	original := `a"b\c` + "\n"
	q := quote(original)
	doc, perr := parse(strings.concatenate({"k = ", q}, context.temp_allocator))
	defer destroy(doc)
	testing.expect_value(t, perr.line, 0)
	testing.expect_value(t, doc.root["k"].(string), original)
}

@(test)
test_bom :: proc(t: ^testing.T) {
	// UTF-8 byte-order mark (EF BB BF) followed by a key.
	bom := [3]u8{0xEF, 0xBB, 0xBF}
	src := strings.concatenate({string(bom[:]), "a = 1"}, context.temp_allocator)
	doc, err := parse(src)
	defer destroy(doc)
	testing.expect_value(t, err.line, 0)
	if doc != nil do testing.expect_value(t, doc.root["a"].(i64), 1)
}
