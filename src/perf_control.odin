package editor

// Perf phase for agent control (control.odin): `typo ctl ls` and a screenshot
// run in one of the window's terminals are answered, with that terminal as
// `self`; the same request from a process outside its terminals (this one) is
// refused, and one made while a dialog asks the user is turned away

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

import "ipc"


// How long a terminal's typo ctl may take to write its answers
@(private = "file")
CONTROL_WAIT :: 15 * time.Second

// Limit (ms) on reading a screenshot back on the UI thread: it waits for the
// GPU, in the one frame a test takes it
@(private = "file")
CAPTURE_LIMIT :: 10

@(private = "file")
pc: struct {
	step:     int,
	dir:      string, // owned; the answers and the scripts
	pane:     ^Pane,  // the terminal asking
	asker:    ^Pane,  // the one asking while the dialog is up
	since:    time.Tick,
	outsider: ^thread.Thread, // asks from outside the terminals
	refused:  bool,           // its answer was not_mine (set by its thread)
}


@(private)
phase_control :: proc(p: ^Perf, frame: int) -> bool {
	// Control requests are taken on Windows only
	when ODIN_OS != .Windows do return true

	switch pc.step {
	case 0:
		temp, _ := os.temp_directory(context.temp_allocator)
		pc.dir, _ = filepath.join({temp, fmt.tprintf("typo-perf-ctl-%d", os.get_pid())})
		_ = os.make_directory_all(pc.dir)

		// A terminal that lists the panes and takes a screenshot
		shot := fmt.tprintf("screenshot --out %q > shot.json", control_file("shot.png"))
		pc.pane = run_control_script("first", {"ls > ls.json", shot})

		// The same request from this process, on a thread (it isn't answered on
		// this one): refused, as it runs under no terminal
		pc.outsider = thread.create_and_start(ask_from_outside)
		pc.since = time.tick_now()
		pc.step = 1
		return false

	case 1:
		shot, _ := os.read_entire_file(control_file("shot.json"), context.temp_allocator)
		done := len(shot) > 0 && thread.is_done(pc.outsider)
		if !done && time.tick_since(pc.since) < CONTROL_WAIT do return false

		// The terminal's answer names it as the caller
		Ls :: struct {
			self:  string,
			panes: []struct {
				id: string,
			},
		}
		ls: Ls
		data, _ := os.read_entire_file(control_file("ls.json"), context.temp_allocator)
		parsed := json.unmarshal(data, &ls, allocator = context.temp_allocator) == nil
		answered := parsed && len(ls.panes) > 0
		if !answered do fmt.printfln("  (it wrote: %q)", string(data))
		check(p, "typo ctl in a terminal is answered", answered)
		check(p, "and its terminal is the caller", ls.self == fmt.tprintf("p%d", pc.pane.id))
		check(p, "a screenshot is written", os.is_file(control_file("shot.png")))
		result(p, "screenshot read back, UI thread", capture_ms, "ms", CAPTURE_LIMIT)

		thread.join(pc.outsider)
		thread.destroy(pc.outsider)
		check(p, "the same from outside its terminals is refused", pc.refused)

		// While a dialog asks the user, a request is turned away
		show_notice("A question", "Requests wait for the answer.")
		pc.asker = run_control_script("second", {"ls > busy.txt 2>&1"})
		pc.since = time.tick_now()
		pc.step = 2
		return false

	case 2:
		busy, _ := os.read_entire_file(control_file("busy.txt"), context.temp_allocator)
		if len(busy) == 0 && time.tick_since(pc.since) < CONTROL_WAIT do return false

		turned_away := strings.contains(string(busy), "asking the user")
		check(p, "a request while the user is asked is turned away", turned_away)

		dialog_close()
		pane_close(pc.pane, ask = false)
		pane_close(pc.asker, ask = false)
		_ = os.remove_all(pc.dir)
		delete(pc.dir)
		pc = {}
		return true
	}
	return true
}


// Starts a terminal running `typo ctl` with each line's arguments, in order,
// from a script any shell can start (cmd /c)
@(private = "file")
run_control_script :: proc(name: string, lines: []string) -> ^Pane {
	exe, _ := os.get_executable_path(context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "@cd /d \"%s\"\r\n", pc.dir)
	for line in lines do fmt.sbprintf(&b, "@\"%s\" ctl %s\r\n", exe, line)

	script := control_file(fmt.tprintf("%s.cmd", name))
	_ = os.write_entire_file(script, strings.to_string(b))
	return panes_run_in_terminal(fmt.tprintf(`cmd /c "%s"`, script))
}


// A file in the phase's folder (temp)
@(private = "file")
control_file :: proc(name: string) -> string {
	path, _ := filepath.join({pc.dir, name}, context.temp_allocator)
	return path
}


// On its own thread: `ls` sent to this window from this process
@(private = "file")
ask_from_outside :: proc() {
	defer free_all(context.temp_allocator)

	env := ipc_shell_env()
	if len(env) == 0 do return
	endpoint := env[0][strings.index_byte(env[0], '=') + 1:]

	reply, err := ipc.send_control(endpoint, `{"cmd":"ls"}`)
	pc.refused = err == .None && reply.status == .Not_Mine
}
