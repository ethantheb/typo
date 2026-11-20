package langs

// Language server settings: the [lsp.<name>] tables of settings.toml, which
// change a built-in server (lsp.SERVERS) or add one, and the server list that
// results from merging them

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import "../lsp"
import "../toml"


// A [lsp.<name>] table. Unset fields keep the built-in server's values
Server_Override :: struct {
	name:         string,
	enabled:      Maybe(bool),
	path:         string, // the program, run with the command's arguments; "" = on PATH
	command:      []string,
	languages:    []string,
	extensions:   []string, // of a language typo doesn't know (the first of `languages`)
	root_markers: []string,
	install:      Maybe([]string), // replaces the built-in commands; set and empty: none
	settings:     string, // JSON; "" keeps the built-in
	init_options: string, // JSON; "" keeps the built-in
}

// A server as configured: built in, changed or added by settings.toml
Server :: struct {
	using spec: lsp.Server_Spec,
	builtin:    bool,
	path:       string, // the program as set in settings.toml; "" = command[0] on PATH
}

// The fields of a [lsp.<name>] table the settings window edits as text
Server_Field :: enum {
	Name,
	Path,
	Command,
	Languages,
	Extensions,
	Root_Markers,
	Install,
}


server_override_destroy :: proc(o: ^Server_Override) {
	delete(o.name)
	delete(o.path)
	delete_strings(o.command)
	delete_strings(o.languages)
	delete_strings(o.extensions)
	delete_strings(o.root_markers)
	if install, ok := o.install.?; ok {
		delete_strings(install)
	}
	delete(o.settings)
	delete(o.init_options)
	o^ = {}
}


@(private = "file")
delete_strings :: proc(list: []string) {
	for s in list do delete(s)
	delete(list)
}


// The override for a server, added if it has none
server_override :: proc(list: ^[dynamic]Server_Override, name: string) -> ^Server_Override {
	if o := find_server_override(list[:], name); o != nil {
		return o
	}
	append(list, Server_Override{name = strings.clone(name)})
	return &list[len(list) - 1]
}


// The override for a server, or nil if it has none
find_server_override :: proc(list: []Server_Override, name: string) -> ^Server_Override {
	for &o in list {
		if o.name == name do return &o
	}
	return nil
}


// Removes a server's override: a built-in server goes back to how it is built
// in, one the settings added is gone
remove_server_override :: proc(list: ^[dynamic]Server_Override, name: string) {
	for &o, i in list {
		if o.name != name do continue

		server_override_destroy(&o)
		ordered_remove(list, i)
		return
	}
}


// Frees a list of overrides and empties it
server_overrides_clear :: proc(list: ^[dynamic]Server_Override) {
	for &o in list do server_override_destroy(&o)
	clear(list)
}


// The built-in server named `name`
builtin_server :: proc(name: string) -> (spec: lsp.Server_Spec, found: bool) {
	for x in lsp.SERVERS {
		if x.name == name do return x, true
	}
	return {}, false
}


// --- Fields as text ----------------------------------------------------------------

// A field of an override as the settings window shows it; "" if the table
// doesn't set it (temp)
override_field_text :: proc(o: ^Server_Override, field: Server_Field) -> string {
	if o == nil do return ""

	switch field {
	case .Name:         return o.name
	case .Path:         return o.path
	case .Command:      return command_text(o.command)
	case .Languages:    return list_text(o.languages)
	case .Extensions:   return list_text(o.extensions)
	case .Root_Markers: return list_text(o.root_markers)
	case .Install:      return install_text(o.install.? or_else nil)
	}
	return ""
}


// A field of a built-in server, as override_field_text shows it (temp)
spec_field_text :: proc(spec: lsp.Server_Spec, field: Server_Field) -> string {
	switch field {
	case .Name:         return spec.name
	case .Path:         return ""
	case .Command:      return command_text(spec.command)
	case .Languages:    return list_text(spec.languages)
	case .Extensions:   return ""
	case .Root_Markers: return list_text(spec.root_markers)
	case .Install:      return install_text(spec.install)
	}
	return ""
}


// Sets a field from text typed in the settings window; empty text unsets it.
// The name isn't set here (see rename_server_override)
set_override_field_text :: proc(o: ^Server_Override, field: Server_Field, text: string) {
	text := strings.trim_space(text)

	switch field {
	case .Name:
	case .Path:
		set_string(&o.path, text)
	case .Command:
		delete_strings(o.command)
		o.command = split_command(text)
	case .Languages:
		delete_strings(o.languages)
		o.languages = split_list(text, lower = true)
	case .Extensions:
		delete_strings(o.extensions)
		o.extensions = split_list(text, lower = true, strip = ".")
	case .Root_Markers:
		delete_strings(o.root_markers)
		o.root_markers = split_list(text)
	case .Install:
		if install, ok := o.install.?; ok {
			delete_strings(install)
		}
		o.install = nil

		commands := split_list(text, sep = ";")
		if commands != nil do o.install = commands
	}
}


// Renames a server the settings added. Refused (false) for an empty name or one
// another server has
rename_server_override :: proc(
	list: []Server_Override,
	o: ^Server_Override,
	name: string,
) -> bool {
	name := strings.trim_space(name)
	if name == "" do return false
	if name == o.name do return true

	_, builtin := builtin_server(name)
	if builtin || find_server_override(list, name) != nil {
		return false
	}

	set_string(&o.name, name)
	return true
}


// Words separated by spaces, a word in double quotes keeping its spaces
@(private = "file")
command_text :: proc(words: []string) -> string {
	quoted := make([]string, len(words), context.temp_allocator)
	for word, i in words {
		has_space := strings.contains_any(word, " \t")
		quoted[i] = has_space ? fmt.tprintf(`"%s"`, word) : word
	}
	return strings.join(quoted, " ", context.temp_allocator)
}


@(private = "file")
list_text :: proc(list: []string) -> string {
	return strings.join(list, ", ", context.temp_allocator)
}


// Install commands, separated by semicolons
@(private = "file")
install_text :: proc(commands: []string) -> string {
	return strings.join(commands, "; ", context.temp_allocator)
}


// A command line's words (see command_text), owned; nil for none
split_command :: proc(text: string) -> []string {
	words := make([dynamic]string)
	word := strings.builder_make(context.temp_allocator)
	quoted := false
	started := false

	for c in text {
		switch {
		case c == '"':
			quoted = !quoted
			started = true
		case (c == ' ' || c == '\t') && !quoted:
			if started do append(&words, strings.clone(strings.to_string(word)))
			strings.builder_reset(&word)
			started = false
		case:
			strings.write_rune(&word, c)
			started = true
		}
	}
	if started do append(&words, strings.clone(strings.to_string(word)))

	if len(words) == 0 {
		delete(words)
		return nil
	}
	return words[:]
}


// Items separated by commas (or `sep`), trimmed, the empty ones left out; owned,
// nil for none. `strip` is taken off the front of each item
split_list :: proc(text: string, lower := false, strip := "", sep := ",") -> []string {
	list := make([dynamic]string)
	for part in strings.split(text, sep, context.temp_allocator) {
		item := strings.trim_space(part)
		if strip != "" do item = strings.trim_left(item, strip)
		if item == "" do continue

		if lower {
			append(&list, strings.to_lower(item))
		} else {
			append(&list, strings.clone(item))
		}
	}

	if len(list) == 0 {
		delete(list)
		return nil
	}
	return list[:]
}


// --- Loading -----------------------------------------------------------------------

// Reads the [lsp.<name>] tables, appending what is wrong with them to `problems`
load_server_overrides :: proc(
	list: ^[dynamic]Server_Override,
	doc: ^toml.Document,
	problems: ^[dynamic]string,
) {
	section, found := toml.get(doc.root, "lsp")
	if !found do return
	tables, is_table := section.(^toml.Table)
	if !is_table do return

	// In name order, so the file and the settings window list them the same way
	names := make([dynamic]string, context.temp_allocator)
	for name, value in tables {
		_, is_server := value.(^toml.Table)
		if is_server do append(&names, name)
	}
	slice.sort(names[:])

	for name in names {
		o := Server_Override{name = strings.clone(name)}
		for key, value in tables[name].(^toml.Table) {
			if !set_override_field(&o, key, value) {
				append(problems, fmt.tprintf("lsp.%s.%s is not valid", name, key))
			}
		}
		append(list, o)
	}
}


@(private = "file")
set_override_field :: proc(o: ^Server_Override, key: string, value: toml.Value) -> bool {
	switch key {
	case "enabled":
		b := value.(bool) or_return
		o.enabled = b
	case "path":
		str := value.(string) or_return
		o.path = strings.clone(strings.trim_space(str))
	case "command":
		o.command = toml_strings(value) or_return
	case "languages":
		o.languages = toml_strings(value) or_return
	case "extensions":
		o.extensions = toml_strings(value) or_return
	case "root_markers":
		o.root_markers = toml_strings(value) or_return
	case "install":
		// One command line, or a list of them
		o.install = toml_strings(value) or_return
	case "settings":
		o.settings = toml_to_json(value)
	case "init_options":
		o.init_options = toml_to_json(value)
	case:
		return false
	}
	return true
}


// A list of strings, or one string as a list of one
@(private = "file")
toml_strings :: proc(value: toml.Value) -> (out: []string, ok: bool) {
	#partial switch v in value {
	case string:
		out = make([]string, 1)
		out[0] = strings.clone(v)
		return out, true

	case []toml.Value:
		list := make([dynamic]string, 0, len(v))
		for item in v {
			str, is_string := item.(string)
			if !is_string {
				delete_strings(list[:])
				return nil, false
			}
			append(&list, strings.clone(str))
		}
		return list[:], true
	}
	return nil, false
}


// A TOML value as JSON text (owned)
@(private = "file")
toml_to_json :: proc(value: toml.Value) -> string {
	sb := strings.builder_make()
	write_json(&sb, value)
	return strings.to_string(sb)
}


@(private = "file")
write_json :: proc(sb: ^strings.Builder, value: toml.Value) {
	switch v in value {
	case string: strings.write_string(sb, lsp.to_json(v))
	case i64:    fmt.sbprintf(sb, "%d", v)
	case f64:    fmt.sbprintf(sb, "%v", v)
	case bool:   fmt.sbprintf(sb, "%v", v)
	case []toml.Value:
		strings.write_byte(sb, '[')
		for item, i in v {
			if i > 0 do strings.write_byte(sb, ',')
			write_json(sb, item)
		}
		strings.write_byte(sb, ']')
	case ^toml.Table:
		keys := make([dynamic]string, context.temp_allocator)
		for key in v do append(&keys, key)
		slice.sort(keys[:])

		strings.write_byte(sb, '{')
		for key, i in keys {
			if i > 0 do strings.write_byte(sb, ',')
			fmt.sbprintf(sb, "%s:", lsp.to_json(key))
			write_json(sb, v[key])
		}
		strings.write_byte(sb, '}')
	}
}


// --- Saving ------------------------------------------------------------------------

// The [lsp.<name>] tables, as written to settings.toml
write_server_overrides :: proc(sb: ^strings.Builder, list: []Server_Override) {
	for o in list {
		Line :: struct {
			key, value: string,
		}
		lines := make([dynamic]Line, context.temp_allocator)

		if enabled, ok := o.enabled.?; ok {
			append(&lines, Line{"enabled", fmt.tprintf("%v", enabled)})
		}
		if o.path != "" do append(&lines, Line{"path", toml.quote(o.path)})
		if o.command != nil do append(&lines, Line{"command", toml_list(o.command)})
		if o.languages != nil do append(&lines, Line{"languages", toml_list(o.languages)})
		if o.extensions != nil do append(&lines, Line{"extensions", toml_list(o.extensions)})
		if o.root_markers != nil {
			append(&lines, Line{"root_markers", toml_list(o.root_markers)})
		}
		if install, ok := o.install.?; ok {
			// One command stays a string, as older settings files have it
			value := len(install) == 1 ? toml.quote(install[0]) : toml_list(install)
			append(&lines, Line{"install", value})
		}
		if o.settings != "" do append(&lines, Line{"settings", json_to_toml(o.settings)})
		if o.init_options != "" {
			append(&lines, Line{"init_options", json_to_toml(o.init_options)})
		}
		if len(lines) == 0 do continue

		width := 0
		for line in lines do width = max(width, len(line.key))

		fmt.sbprintf(sb, "\n[lsp.%s]\n", toml_key(o.name))
		for line in lines do fmt.sbprintf(sb, "%-*s = %s\n", width, line.key, line.value)
	}
}


@(private = "file")
toml_list :: proc(list: []string) -> string {
	quoted := make([]string, len(list), context.temp_allocator)
	for s, i in list do quoted[i] = toml.quote(s)
	return fmt.tprintf("[%s]", strings.join(quoted, ", ", context.temp_allocator))
}


// A bare key if it can be one, else quoted
@(private = "file")
toml_key :: proc(key: string) -> string {
	bare := key != ""
	for c in key {
		is_bare := c == '-' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		           (c >= '0' && c <= '9')
		if !is_bare do bare = false
	}
	return bare ? key : toml.quote(key)
}


// JSON text as a TOML inline value (null values are left out)
@(private = "file")
json_to_toml :: proc(text: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	write_toml(&sb, lsp.parse_json(text))
	return strings.to_string(sb)
}


@(private = "file")
write_toml :: proc(sb: ^strings.Builder, value: json.Value) {
	#partial switch v in value {
	case json.String:  strings.write_string(sb, toml.quote(v))
	case json.Integer: fmt.sbprintf(sb, "%d", v)
	case json.Float:   fmt.sbprintf(sb, "%v", v)
	case json.Boolean: fmt.sbprintf(sb, "%v", v)
	case json.Array:
		strings.write_byte(sb, '[')
		for item, i in v {
			if i > 0 do strings.write_string(sb, ", ")
			write_toml(sb, item)
		}
		strings.write_byte(sb, ']')
	case json.Object:
		keys := make([dynamic]string, context.temp_allocator)
		for key, item in v {
			if item != nil do append(&keys, key)
		}
		slice.sort(keys[:])

		strings.write_string(sb, "{")
		for key, i in keys {
			strings.write_string(sb, i > 0 ? ", " : " ")
			fmt.sbprintf(sb, "%s = ", toml_key(key))
			write_toml(sb, v[key])
		}
		strings.write_string(sb, len(keys) > 0 ? " }" : "}")
	case:
		strings.write_string(sb, `""`)
	}
}


// --- The server list ---------------------------------------------------------------

// The built-in servers with the overrides applied, then the servers the
// settings add. Strings point into lsp.SERVERS and the settings: rebuild after
// the settings are reloaded
build_server_list :: proc(
	overrides: []Server_Override,
	servers: ^[dynamic]Server,
	languages: ^[dynamic]lsp.Language,
) {
	clear(servers)
	clear(languages)

	// The built-in ones, changed by their tables
	for spec in lsp.SERVERS {
		server := Server{spec = spec, builtin = true}
		for &o in overrides {
			if o.name == spec.name do apply_override(&server, &o)
		}
		append(servers, server)
	}

	// The ones the settings add; a table without a command or path only changes a
	// server
	for &o in overrides {
		is_builtin := false
		for spec in lsp.SERVERS {
			if spec.name == o.name do is_builtin = true
		}
		runnable := len(o.command) > 0 || o.path != ""
		if is_builtin || !runnable {
			continue
		}

		server := Server{spec = {name = o.name, enabled = true}}
		apply_override(&server, &o)
		append(servers, server)
	}

	// Languages typo doesn't know, from the extensions given with them
	for o in overrides {
		if len(o.extensions) > 0 && len(o.languages) > 0 {
			append(languages, lsp.Language{id = o.languages[0], extensions = o.extensions})
		}
	}
}


@(private = "file")
apply_override :: proc(server: ^Server, o: ^Server_Override) {
	spec := &server.spec
	if o.path != "" do server.path = o.path
	spec.enabled = o.enabled.? or_else spec.enabled
	if install, ok := o.install.?; ok {
		spec.install = install
	}
	if o.command != nil do spec.command = o.command
	if o.languages != nil do spec.languages = o.languages
	if o.root_markers != nil do spec.root_markers = o.root_markers
	if o.settings != "" do spec.settings = o.settings
	if o.init_options != "" do spec.init_options = o.init_options
}


// What the server list depends on, to tell whether a reload changed it
servers_fingerprint :: proc(enabled: bool, overrides: []Server_Override) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%v;", enabled)
	write_server_overrides(&sb, overrides)
	return strings.to_string(sb)
}


// Replaces an owned string with a copy of `value`
@(private = "file")
set_string :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}
