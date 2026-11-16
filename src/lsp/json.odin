package lsp

// Reading parsed JSON (json.Value) by path, and writing values as JSON

import "core:encoding/json"


// The value at a path of object keys, or nil if any step is missing
get :: proc(v: json.Value, keys: ..string) -> json.Value {
	v := v
	for key in keys {
		obj, is_object := v.(json.Object)
		if !is_object do return nil
		v = obj[key]
	}
	return v
}


get_string :: proc(v: json.Value, keys: ..string) -> string {
	s, _ := get(v, ..keys).(json.String)
	return s
}


get_int :: proc(v: json.Value, keys: ..string) -> (int, bool) {
	#partial switch n in get(v, ..keys) {
	case json.Integer: return int(n), true
	case json.Float:   return int(n), true
	}
	return 0, false
}


get_bool :: proc(v: json.Value, keys: ..string) -> bool {
	b, _ := get(v, ..keys).(json.Boolean)
	return b
}


get_array :: proc(v: json.Value, keys: ..string) -> json.Array {
	a, _ := get(v, ..keys).(json.Array)
	return a
}


// Whether a capability is on: true, or an object of options
has :: proc(v: json.Value, keys: ..string) -> bool {
	#partial switch x in get(v, ..keys) {
	case json.Boolean: return bool(x)
	case json.Object:  return true
	}
	return false
}


// `v` as JSON, from the temp allocator
to_json :: proc(v: any) -> string {
	data, err := json.marshal(v, {}, context.temp_allocator)
	if err != nil do return "null"
	return string(data)
}


// Parses JSON text (from settings) into a value from the temp allocator; nil if
// the text is empty or not valid
parse_json :: proc(text: string) -> json.Value {
	if text == "" do return nil

	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return nil
	return v
}


// A position from {"line": n, "character": n}
get_position :: proc(v: json.Value) -> Position {
	line, _ := get_int(v, "line")
	character, _ := get_int(v, "character")
	return {line, character}
}


get_range :: proc(v: json.Value) -> Range {
	return {get_position(get(v, "start")), get_position(get(v, "end"))}
}
