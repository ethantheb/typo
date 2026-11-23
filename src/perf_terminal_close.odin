package editor

import "core:slice"
import "core:strings"
import "core:time"

import "term"

// Perf phase: closing a terminal that runs a program (terminal_programs.odin).
// A new terminal runs ping for a few seconds; closing its pane asks, naming
// it, and Cancel keeps the terminal. Once ping has ended, the idle terminal
// closes without asking. Programs under a shell are only looked up on Windows


@(private = "file")
CLOSE_LIMIT :: 15 * time.Second // for each step to show what it waits for

@(private = "file")
Close_Step :: enum {
	Starting,  // the shell's prompt
	Running,   // ping, given time to start
	Asking,    // closing the pane asks
	Cancelled, // Cancel keeps it
	Ending,    // ping, given time to end
	Closing,   // closing it again doesn't ask
}

@(private = "file")
tc: struct {
	step:  Close_Step,
	since: time.Tick,
	pane:  ^Pane,
}


@(private)
phase_terminal_close :: proc(p: ^Perf, frame: int) -> bool {
	when ODIN_OS != .Windows do return true

	if frame == 0 {
		tc.pane = panes_new_terminal()
		pane_focus(tc.pane)
		next_step(.Starting)
		return false
	}

	open := slice.contains(g.panes.open[:], tc.pane)
	t := open ? tc.pane.content.(^Terminal) : nil
	waited := time.tick_since(tc.since) > CLOSE_LIMIT

	switch tc.step {
	case .Starting:
		if !terminal_shows(t, ">") && !waited {
			return false
		}
		check(p, "a new terminal shows its prompt", terminal_shows(t, ">"))
		if waited do return close_phase_end()

		// About 3 s
		command := "ping -n 4 127.0.0.1\r"
		term.session_input(&t.session, transmute([]u8)command)
		next_step(.Running)

	case .Running:
		if time.tick_since(tc.since) < 1 * time.Second do return false

		pane_close(tc.pane)
		next_step(.Asking)

	case .Asking:
		d := &g.dialog
		_, ending := d.purpose.(Ending_Programs)
		asked := d.open && ending
		if !asked && !waited {
			return false
		}
		check(p, "closing a terminal that runs a program asks first", asked && open)
		if !asked do return close_phase_end()

		names_it := strings.contains(strings.to_lower(d.message, context.temp_allocator), "ping")
		check(p, "naming the program", names_it)
		d.choice = d.cancel
		next_step(.Cancelled)

	case .Cancelled:
		if g.dialog.open do return false

		check(p, "Cancel keeps the terminal", open && terminal_alive(tc.pane))
		if !open do return close_phase_end()
		next_step(.Ending)

	case .Ending:
		if time.tick_since(tc.since) < 5 * time.Second do return false

		pane_close(tc.pane)
		next_step(.Closing)

	case .Closing:
		if open && !g.dialog.open && !waited {
			return false
		}
		check(p, "an idle terminal closes without asking", !open && !g.dialog.open)
		return close_phase_end()
	}
	return false
}


@(private = "file")
next_step :: proc(step: Close_Step) {
	tc.step = step
	tc.since = time.tick_now()
}


// Closes what is left of the phase's terminal and any dialog
@(private = "file")
close_phase_end :: proc() -> bool {
	dialog_close()
	if slice.contains(g.panes.open[:], tc.pane) {
		pane_close(tc.pane, ask = false)
	}
	tc = {}
	return true
}
