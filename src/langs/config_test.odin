package langs

import "core:testing"


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

	// Empty unsets
	set_override_field_text(o, .Install, "pip install mine")
	testing.expect_value(t, o.install.? or_else "", "pip install mine")
	set_override_field_text(o, .Install, " ")
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
