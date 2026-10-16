#+build linux, darwin, freebsd, openbsd, netbsd
package editor

import "core:sys/posix"

// Process CPU time for the performance suite. Process age and GPU utilization
// aren't measured on these platforms.

Gpu_Counter :: struct {}

attach_console :: proc() {}
detach_console :: proc() {}

process_cpu_ns :: proc() -> i64 {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK do return 0
	tv := proc(t: posix.timeval) -> i64 {return i64(t.tv_sec) * 1_000_000_000 + i64(t.tv_usec) * 1000}
	return tv(ru.ru_utime) + tv(ru.ru_stime)
}

process_age_ns :: proc() -> i64 {return -1}

gpu_counter_open :: proc() -> Gpu_Counter {return {}}
gpu_counter_close :: proc(c: ^Gpu_Counter) {}
gpu_counter_start :: proc(c: ^Gpu_Counter) {}
gpu_counter_read :: proc(c: ^Gpu_Counter) -> f64 {return -1}
