package lsp

// Install commands: a server lists several (lsp.SERVERS, or its [lsp.<name>]
// table), and the app offers those whose program is on PATH, lightest
// installer first. How heavy an installer is comes from INSTALLERS

import "core:path/filepath"
import "core:slice"
import "core:strings"


// A program that installs servers
Installer :: struct {
	program: string, // the command's first word, lower case, without folder or extension
	name:    string, // what "Needs ..." calls it
	weight:  int,    // lighter ones are offered first
	builds:  bool,   // compiles the server from source
}

// Lightest first: prebuilt Python tools, then pip and npm, then system package
// managers, then rustup's prebuilt components, then compilers. pip is also
// run as `py -m pip` and `python -m pip`, which is often the only way to reach
// it on Windows
INSTALLERS := [?]Installer {
	{program = "uv", name = "uv", weight = 0},
	{program = "pipx", name = "pipx", weight = 0},
	{program = "pip", name = "pip", weight = 1},
	{program = "pip3", name = "pip", weight = 1},
	{program = "py", name = "pip", weight = 1},
	{program = "python", name = "pip", weight = 1},
	{program = "python3", name = "pip", weight = 1},
	{program = "npm", name = "npm", weight = 1},
	{program = "winget", name = "winget", weight = 2},
	{program = "scoop", name = "scoop", weight = 2},
	{program = "choco", name = "choco", weight = 2},
	{program = "brew", name = "brew", weight = 2},
	{program = "rustup", name = "rustup", weight = 3},
	{program = "go", name = "go", weight = 4, builds = true},
	{program = "cargo", name = "cargo", weight = 6, builds = true},
}

// A program INSTALLERS doesn't list goes after go and before cargo
UNKNOWN_INSTALLER_WEIGHT :: 5


// The program a command line runs: its first word, without the quotes around
// it (a slice of `command`)
command_program :: proc(command: string) -> string {
	s := strings.trim_left_space(command)
	if strings.has_prefix(s, `"`) {
		end := strings.index_byte(s[1:], '"')
		return end < 0 ? s[1:] : s[1:][:end]
	}

	end := strings.index_any(s, " \t")
	return end < 0 ? s : s[:end]
}


// What INSTALLERS says about the program a command runs. A program it doesn't
// list is named as it is and weighs UNKNOWN_INSTALLER_WEIGHT
installer_for :: proc(command: string) -> Installer {
	program := command_program(command)
	base := filepath.base(program)
	stem := strings.to_lower(base, context.temp_allocator)
	for ext in ([]string{".exe", ".cmd", ".bat", ".com"}) {
		stem = strings.trim_suffix(stem, ext)
	}

	for x in INSTALLERS {
		if x.program == stem do return x
	}
	return {program = stem, name = base, weight = UNKNOWN_INSTALLER_WEIGHT}
}


// Install commands in the order they are offered: lightest installer first,
// equals in the order given (temp)
order_installs :: proc(commands: []string) -> []string {
	ordered := slice.clone(commands, context.temp_allocator)
	slice.stable_sort_by(ordered, lighter)
	return ordered
}


@(private = "file")
lighter :: proc(a, b: string) -> bool {
	return installer_for(a).weight < installer_for(b).weight
}
