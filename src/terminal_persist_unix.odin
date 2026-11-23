#+build !windows
package editor


// A command line as its program and arguments: nil here, where herdr-core
// runs it as a shell line, as pty_spawn does with /bin/sh -c
command_argv :: proc(line: string) -> []string {
	return nil
}
