package process

import "core:log"
import "core:strings"
import "core:testing"


// Extra variables replace inherited ones of the same name (on Windows whatever
// the case), and the rest are kept
@(test)
test_merged_env :: proc(t: ^testing.T) {
	inherited := []string{"Path=a", "HOME=h", "=C:=C:\\dir"}
	extra := []string{"PATH=b", "NEW=1"}
	merged := merged_env(inherited, extra)

	testing.expect(t, has(merged, "PATH=b"))
	testing.expect(t, has(merged, "NEW=1"))
	testing.expect(t, has(merged, "HOME=h"))
	testing.expect(t, has(merged, "=C:=C:\\dir"))
	when ODIN_OS == .Windows {
		testing.expect(t, !has(merged, "Path=a"), "Path is PATH on Windows")
	}
}


// Arguments reach the program as given: spaces, quotes, backslashes and empty
// ones (git's --sq-quote prints each back, quoted). Skipped without git
@(test)
test_arguments_round_trip :: proc(t: ^testing.T) {
	if find_executable("git", context.temp_allocator) == "" {
		log.info("skipped: git is not on PATH")
		return
	}

	args := []string{"git", "rev-parse", "--sq-quote", "a b", `c"d`, `e\`, `f\"g`, ""}
	output, code := run_for_output(args, {})
	testing.expect_value(t, code, 0)
	testing.expect_value(t, output, ` 'a b' 'c"d' 'e\' 'f\"g' ''`)
}


// A discarded stderr leaves only stdout to read, and a detached process runs
// as any other
@(test)
test_spawn_options :: proc(t: ^testing.T) {
	if find_executable("git", context.temp_allocator) == "" {
		log.info("skipped: git is not on PATH")
		return
	}

	options := Spawn_Options{discard_stderr = true, detached = true}
	output, code := run_for_output({"git", "--version"}, options)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(output, "git version"), output)
}


@(private = "file")
has :: proc(list: []string, entry: string) -> bool {
	for e in list {
		if e == entry do return true
	}
	return false
}


// Runs a command to its end, returning its stdout (trimmed, temp) and exit
// code
@(private = "file")
run_for_output :: proc(command: []string, options: Spawn_Options) -> (string, int) {
	p: Process
	ok, reason := process_spawn(&p, command, "", options)
	if !ok do return reason, -1
	defer process_close(&p)

	process_close_input(&p)
	out := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n := process_read(&p, .Stdout, buf[:])
		if n <= 0 do break
		strings.write_bytes(&out, buf[:n])
	}
	process_wait(&p, -1)
	if options.discard_stderr && p.stderr != nil {
		return "stderr was piped", -1
	}
	return strings.trim_right_space(strings.to_string(out)), process_exit_code(&p)
}
