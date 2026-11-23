#+build windows
package editor

import win "core:sys/windows"


// A command line as its program and arguments (temp), split as Windows
// programs split theirs; nil if it can't be split
command_argv :: proc(line: string) -> []string {
	count: i32
	wide := win.utf8_to_wstring(line, context.temp_allocator)
	args := win.CommandLineToArgvW(wide, &count)
	if args == nil do return nil
	defer win.LocalFree(args)

	argv := make([]string, count, context.temp_allocator)
	for i in 0 ..< int(count) {
		argv[i], _ = win.wstring_to_utf8(args[i], -1, context.temp_allocator)
	}
	return argv
}
