#+build windows
package editor

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

// Process CPU time, process age and GPU utilization for the performance suite.
// GPU utilization comes from the "GPU Engine" performance counters (the ones
// Task Manager shows), filtered to this process.

foreign import pdh "system:pdh.lib"

@(private = "file", default_calling_convention = "system")
foreign pdh {
	PdhOpenQueryW :: proc(data_source: win.LPCWSTR, user_data: uintptr, query: ^win.HANDLE) -> u32 ---
	PdhAddEnglishCounterW :: proc(query: win.HANDLE, path: win.LPCWSTR, user_data: uintptr, counter: ^win.HANDLE) -> u32 ---
	PdhCollectQueryData :: proc(query: win.HANDLE) -> u32 ---
	PdhGetFormattedCounterArrayW :: proc(counter: win.HANDLE, format: u32, buffer_size, item_count: ^u32, items: rawptr) -> u32 ---
	PdhCloseQuery :: proc(query: win.HANDLE) -> u32 ---
}

@(private = "file")
PDH_FMT_DOUBLE :: 0x200

// PDH_FMT_COUNTERVALUE_ITEM_W with a double value.
@(private = "file")
Counter_Item :: struct {
	name:   win.wstring,
	status: u32,
	value:  f64,
}

Gpu_Counter :: struct {
	query, counter: win.HANDLE,
}

@(private = "file")
ATTACH_PARENT_PROCESS :: ~win.DWORD(0)

@(private = "file")
console_out: ^os.File

// A release build has no console, so its output goes nowhere unless redirected.
// When started from a terminal, print to that terminal instead. The shell
// doesn't wait for a GUI program, so the output follows its next prompt.
attach_console :: proc() {
	if win.GetStdHandle(win.STD_OUTPUT_HANDLE) != nil do return // a console or a redirect
	if !win.AttachConsole(ATTACH_PARENT_PROCESS) do return
	handle := win.CreateFileW(win.L("CONOUT$"), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
	if handle == win.INVALID_HANDLE_VALUE do return
	console_out = os.new_file(uintptr(handle), "CONOUT$")
	os.stdout = console_out
	fmt.println()
}

detach_console :: proc() {
	if console_out == nil do return
	_ = os.close(console_out)
	console_out = nil
}

// CPU time (user + kernel) used by this process so far.
process_cpu_ns :: proc() -> i64 {
	creation, exit, kernel, user: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &creation, &exit, &kernel, &user) do return 0
	return (filetime(kernel) + filetime(user)) * 100
}

// Time since the process was created, or -1 if unknown.
process_age_ns :: proc() -> i64 {
	creation, exit, kernel, user, now: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &creation, &exit, &kernel, &user) do return -1
	win.GetSystemTimePreciseAsFileTime(&now)
	return (filetime(now) - filetime(creation)) * 100
}

@(private = "file")
filetime :: proc(t: win.FILETIME) -> i64 {
	return i64(t.dwHighDateTime) << 32 | i64(t.dwLowDateTime)
}

gpu_counter_open :: proc() -> (c: Gpu_Counter) {
	if PdhOpenQueryW(nil, 0, &c.query) != 0 do return {}
	path := fmt.tprintf(`\GPU Engine(pid_%d_*)\Utilization Percentage`, win.GetCurrentProcessId())
	if PdhAddEnglishCounterW(c.query, win.utf8_to_wstring(path, context.temp_allocator), 0, &c.counter) != 0 {
		gpu_counter_close(&c)
		return {}
	}
	PdhCollectQueryData(c.query)
	return
}

gpu_counter_close :: proc(c: ^Gpu_Counter) {
	if c.query != nil do PdhCloseQuery(c.query)
	c^ = {}
}

// Starts a measurement interval.
gpu_counter_start :: proc(c: ^Gpu_Counter) {
	if c.query != nil do PdhCollectQueryData(c.query)
}

// Average utilization (percent) of the busiest engine type (3D, copy, ...)
// since gpu_counter_start, or -1 if unavailable.
gpu_counter_read :: proc(c: ^Gpu_Counter) -> f64 {
	if c.query == nil || PdhCollectQueryData(c.query) != 0 do return -1
	size, count: u32
	PdhGetFormattedCounterArrayW(c.counter, PDH_FMT_DOUBLE, &size, &count, nil)
	if size == 0 do return 0 // no engine used yet
	buf := make([]u8, size, context.temp_allocator)
	if PdhGetFormattedCounterArrayW(c.counter, PDH_FMT_DOUBLE, &size, &count, raw_data(buf)) != 0 do return -1

	per_type := make(map[string]f64, context.temp_allocator)
	for item in ([^]Counter_Item)(raw_data(buf))[:count] {
		name, _ := win.wstring_to_utf8(item.name, -1, context.temp_allocator)
		engine := name
		if i := strings.index(name, "engtype_"); i >= 0 do engine = name[i + len("engtype_"):]
		per_type[engine] += item.value
	}
	busiest := 0.0
	for _, v in per_type do busiest = max(busiest, v)
	return busiest
}
