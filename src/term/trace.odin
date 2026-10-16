package term

// Optional I/O trace for diagnosing terminal programs: when TYPO_TERM_TRACE
// names a file, every chunk read from the shell and every byte written to it
// is appended there with a timestamp (ms since the session started).

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

@(private = "file")
tracer: struct {
	mutex: sync.Mutex,
	file:  ^os.File,
	start: time.Tick,
}

@(private)
trace_open :: proc() {
	path := os.get_env("TYPO_TERM_TRACE", context.temp_allocator)
	if path == "" || tracer.file != nil do return
	f, err := os.create(path)
	if err != nil do return
	tracer.file = f
	tracer.start = time.tick_now()
}

@(private)
trace_close :: proc() {
	if tracer.file == nil do return
	os.close(tracer.file)
	tracer.file = nil
}

// `dir` is "<" for shell output, or what kind of write went to the shell.
@(private)
trace :: proc(dir: string, data: []u8) {
	if tracer.file == nil do return
	sync.guard(&tracer.mutex)
	ms := time.duration_milliseconds(time.tick_since(tracer.start))
	line := fmt.tprintf("%10.3f %-6s %d %q\n", ms, dir, len(data), string(data))
	_, _ = os.write(tracer.file, transmute([]u8)line)
}
