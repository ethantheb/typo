package lsp

import "core:testing"


// Install commands are offered lightest installer first: uv and pipx, then pip
// (also through py and python) and npm, then package managers, rustup, go,
// programs INSTALLERS doesn't list, and cargo last. Equals keep their order
@(test)
test_install_order :: proc(t: ^testing.T) {
	commands := []string {
		"cargo install x --locked",
		"go install example.com/x@latest",
		"./install-x.sh",
		"rustup component add x",
		"brew install x",
		"npm install -g x",
		"python -m pip install x",
		"pip install x",
		"py -m pip install x",
		"choco install x",
		"pipx install x",
		"uv tool install x",
	}
	want := []string {
		"pipx install x",
		"uv tool install x",
		"npm install -g x",
		"python -m pip install x",
		"pip install x",
		"py -m pip install x",
		"brew install x",
		"choco install x",
		"rustup component add x",
		"go install example.com/x@latest",
		"./install-x.sh",
		"cargo install x --locked",
	}

	ordered := order_installs(commands)
	testing.expect_value(t, len(ordered), len(want))
	for command, i in want {
		if i < len(ordered) do testing.expect_value(t, ordered[i], command)
	}

	// The given list is left as it was
	testing.expect_value(t, commands[0], "cargo install x --locked")
}


// A command's program: its first word, unquoted; its installer found by name,
// whatever its folder, case or Windows extension
@(test)
test_command_program :: proc(t: ^testing.T) {
	testing.expect_value(t, command_program("  uv tool install x"), "uv")
	testing.expect_value(t, command_program("npm"), "npm")
	quoted := `"C:/Program Files/x/x.exe" --copy-to y`
	testing.expect_value(t, command_program(quoted), "C:/Program Files/x/x.exe")
	testing.expect_value(t, command_program(""), "")

	testing.expect_value(t, installer_for(`C:\nodejs\NPM.cmd install -g x`).name, "npm")
	testing.expect_value(t, installer_for("/usr/bin/cargo install x").weight, 6)
	testing.expect_value(t, installer_for("py -m pip install x").name, "pip")
	testing.expect(t, installer_for("go install x").builds)
	testing.expect(t, !installer_for("rustup component add x").builds)

	// One it doesn't list goes before cargo, named as it is
	unknown := installer_for("C:/tools/get-x.exe")
	testing.expect_value(t, unknown.weight, UNKNOWN_INSTALLER_WEIGHT)
	testing.expect_value(t, unknown.name, "get-x.exe")
	testing.expect(t, unknown.weight < installer_for("cargo install x").weight)
}
