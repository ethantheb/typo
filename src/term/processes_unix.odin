#+build linux, darwin, freebsd, openbsd, netbsd
package term

// Which programs run under a shell. Not looked up on Unix yet (the shell runs
// under `sh -c`, and each system lists processes its own way), so closing a
// terminal there doesn't ask


// The programs running under the process `pid` (a shell): none known here
programs_under :: proc(pid: int, allocator := context.allocator) -> []string {
	return nil
}


// The process `pid` and those it runs under: not looked up here yet
process_ancestors :: proc(pid: int, limit: int, allocator := context.allocator) -> []int {
	return nil
}
