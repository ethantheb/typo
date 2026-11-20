package langs

import "core:strings"
import "core:testing"

import "../lsp"
import "../toml"


// The settings window's server fields: text typed into each sets its table's
// value and reads back the same; empty text unsets it
@(test)
test_server_fields :: proc(t: ^testing.T) {
	servers: [dynamic]Server_Override
	defer {
		server_overrides_clear(&servers)
		delete(servers)
	}
	o := server_override(&servers, "mine")

	// A command with a quoted word
	set_override_field_text(o, .Command, `  my-ls --stdio "C:/Program Files/x"  `)
	testing.expect_value(t, len(o.command), 3)
	if len(o.command) == 3 do testing.expect_value(t, o.command[2], "C:/Program Files/x")
	testing.expect_value(
		t,
		override_field_text(o, .Command),
		`my-ls --stdio "C:/Program Files/x"`,
	)

	// Lists: extensions lose their dots and are lower case
	set_override_field_text(o, .Extensions, ".Vue, svelte,, ")
	testing.expect_value(t, override_field_text(o, .Extensions), "vue, svelte")
	set_override_field_text(o, .Root_Markers, "Cargo.toml,  .git")
	testing.expect_value(t, override_field_text(o, .Root_Markers), "Cargo.toml, .git")

	// Install commands are separated by semicolons
	set_override_field_text(o, .Install, "pip install mine;  ; uv tool install mine ")
	install := o.install.? or_else nil
	testing.expect_value(t, len(install), 2)
	if len(install) == 2 do testing.expect_value(t, install[1], "uv tool install mine")
	testing.expect_value(
		t,
		override_field_text(o, .Install),
		"pip install mine; uv tool install mine",
	)

	// Empty unsets
	set_override_field_text(o, .Install, " ; ")
	testing.expect(t, o.install == nil)
	set_override_field_text(o, .Extensions, "")
	testing.expect(t, o.extensions == nil)

	// Names: not empty, not another server's
	testing.expect(t, !rename_server_override(servers[:], o, " "))
	testing.expect(t, !rename_server_override(servers[:], o, "pyright"))
	server_override(&servers, "taken")
	o = find_server_override(servers[:], "mine")
	testing.expect(t, !rename_server_override(servers[:], o, "taken"))
	testing.expect(t, rename_server_override(servers[:], o, "renamed"))
	testing.expect(t, find_server_override(servers[:], "renamed") != nil)

	remove_server_override(&servers, "renamed")
	testing.expect(t, find_server_override(servers[:], "renamed") == nil)
	testing.expect_value(t, len(servers), 1)
}


// Install commands in settings.toml: one string (as older files have it) or a
// list, an empty list for none; written back the same way, and winning over
// the built-in commands
@(test)
test_install_settings :: proc(t: ^testing.T) {
	src := `
[lsp.ruff]
install = "pip install ruff"

[lsp.tombi]
install = ["npm install -g tombi", "uv tool install tombi"]

[lsp.ty]
install = []

[lsp.gopls]
install = 3
`
	doc, err := toml.parse(src)
	testing.expect_value(t, err.line, 0)
	defer toml.destroy(doc)

	overrides: [dynamic]Server_Override
	problems: [dynamic]string
	defer {
		server_overrides_clear(&overrides)
		delete(overrides)
		delete(problems)
	}
	load_server_overrides(&overrides, doc, &problems)

	// Read
	ruff := find_server_override(overrides[:], "ruff")
	tombi := find_server_override(overrides[:], "tombi")
	ty := find_server_override(overrides[:], "ty")
	found := ruff != nil && tombi != nil && ty != nil
	testing.expect(t, found)
	if !found do return

	testing.expect_value(t, len(ruff.install.? or_else nil), 1)
	testing.expect_value(t, len(tombi.install.? or_else nil), 2)
	_, ty_set := ty.install.?
	testing.expect(t, ty_set)
	testing.expect_value(t, len(problems), 1) // the number

	// Written back
	sb := strings.builder_make(context.temp_allocator)
	write_server_overrides(&sb, overrides[:])
	written := strings.to_string(sb)
	testing.expect(t, strings.contains(written, `install = "pip install ruff"`))
	both := `install = ["npm install -g tombi", "uv tool install tombi"]`
	testing.expect(t, strings.contains(written, both))
	testing.expect(t, strings.contains(written, `install = []`))

	// The settings' commands replace the built-in ones; an empty list leaves none
	servers: [dynamic]Server
	languages: [dynamic]lsp.Language
	defer {
		delete(servers)
		delete(languages)
	}
	build_server_list(overrides[:], &servers, &languages)

	for s in servers {
		switch s.name {
		case "ruff":
			testing.expect_value(t, len(s.install), 1)
		case "tombi":
			testing.expect_value(t, s.install[0], "npm install -g tombi")
		case "ty":
			testing.expect_value(t, len(s.install), 0)
		case "pyright":
			testing.expect(t, len(s.install) > 1)
		}
	}
}


// A server's install commands offered: only those whose program was found,
// lightest first, equals in the server's order; when none is found, what they
// need. Looking them up isn't done yet until every program is answered
@(test)
test_server_installs :: proc(t: ^testing.T) {
	// What the lookups found
	test_answer("uv", "")
	test_answer("npm", "C:/node/npm.cmd")
	test_answer("cargo", "C:/cargo/cargo.exe")
	test_answer("brew", "")
	test_answer("winget", "")
	test_answer("pip", "C:/py/pip.exe")
	env.wake = proc "contextless" (_: rawptr) {}
	defer forget_test_answers()

	s := Server{}
	s.install = {
		"cargo install x",
		"brew install x",
		"npm install -g x",
		"pip install x",
		"uv tool install x",
	}

	// Found: npm and pip (the server's order), then cargo; brew and uv aren't
	installs := server_installs(&s)
	testing.expect(t, installs.known)
	testing.expect_value(t, len(installs.offered), 3)
	if len(installs.offered) == 3 {
		testing.expect_value(t, installs.offered[0].command, "npm install -g x")
		testing.expect_value(t, installs.offered[1].command, "pip install x")
		testing.expect_value(t, installs.offered[2].command, "cargo install x")
		testing.expect(t, installs.offered[2].builds && !installs.offered[0].builds)
	}
	testing.expect_value(t, installs.needs, "")

	// None found: what any of them needs, lightest first
	s.install = {"brew install x", "winget install x", "uv tool install x"}
	installs = server_installs(&s)
	testing.expect_value(t, len(installs.offered), 0)
	testing.expect_value(t, installs.needs, "uv, brew or winget")

	// A server set up with a path to its program has none
	s.path = "C:/x/x.exe"
	installs = server_installs(&s)
	testing.expect(t, installs.known && len(installs.offered) == 0 && installs.needs == "")
	s.path = ""

	// A program not looked up yet: not known, and nothing needed yet
	s.install = {"pipx install x", "npm install -g x"}
	installs = server_installs(&s)
	testing.expect(t, !installs.known)
	testing.expect_value(t, installs.needs, "")
	testing.expect_value(t, len(installs.offered), 1)
}


@(private = "file")
test_answer :: proc(program, path: string) {
	state.programs[strings.clone(program)] = {value = strings.clone(path), known = true}
}


@(private = "file")
forget_test_answers :: proc() {
	lsp.lookups_destroy(&state.lookups)
	forget_answers(&state.programs)
	delete(state.programs)
	state.programs = nil
	env = {}
}
