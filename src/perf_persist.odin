package editor

import "core:fmt"
import "core:strings"
import "core:time"

import clay "../vendor/clay-odin"
import "gfx"
import "herdr"
import "term"

// Perf phase: a persistent terminal in a private herdr-core session
// (terminal_persist.odin). A terminal started in herdr-core prints rows; typo
// lets go of it, as when quitting, and a pane from the session shows it again:
// the screen and its history come back, read back from a real frame. Skipped
// when herdr-core isn't installed


@(private = "file")
PERSIST_LIMIT :: 20 * time.Second // for each step to show what it waits for

@(private = "file")
PERSIST_ROWS :: 200

@(private = "file")
Persist_Step :: enum {
	Starting, // the new terminal's prompt
	Printing, // the rows
	Reopened, // the screen, from the pane the session would open
	Drawn,    // read back from a frame; its icon has a pin; then unpinned
	Unpinned, // restarted here, the pin gone; then the status bar's menu
	Menu,     // what new terminals are, from a right-click; Pinned chosen
	Chosen,   // new terminals are pinned
	Closed,   // closing the pane ends the terminal
}

@(private = "file")
pp: struct {
	sandbox:  herdr.Sandbox,
	step:     Persist_Step,
	since:    time.Tick,
	pane:     ^Pane,
	address:  string, // owned
	core_id:  string, // owned
	reopened: time.Tick,
}


@(private)
phase_persistent_terminal :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do return persist_phase_start(p)

	t := pp.pane != nil ? pp.pane.content.(^Terminal) : nil
	waited := time.tick_since(pp.since) > PERSIST_LIMIT

	switch pp.step {
	case .Starting:
		if !terminal_shows(t, ">") && !waited {
			return false
		}
		check(p, "a terminal starts in herdr-core", terminal_shows(t, ">"))
		if waited do return persist_phase_end()

		when ODIN_OS == .Windows {
			command := fmt.tprintf("for /l %%i in (1,1,%d) do @echo persisted %%i\r", PERSIST_ROWS)
		} else {
			command := fmt.tprintf(
				"for i in $(seq 1 %d); do echo persisted $i; done\n",
				PERSIST_ROWS,
			)
		}
		term.session_input(&t.session, transmute([]u8)command)
		next_step(.Printing)

	case .Printing:
		last := fmt.tprintf("persisted %d", PERSIST_ROWS)
		if !terminal_shows(t, last) && !waited {
			return false
		}
		check(p, "its output is drawn", terminal_shows(t, last))
		if waited do return persist_phase_end()

		// Let go of it, as quitting does, and open it as the session would
		address, core_id := persist_ids(t)
		pp.address = strings.clone(address)
		pp.core_id = strings.clone(core_id)
		check(p, "the session keeps its herdr-core address", pp.address != "")
		terminal_detach(t)
		pane_close(pp.pane, ask = false)

		pp.pane = panes_add_terminal()
		persist_restore(pp.pane.content.(^Terminal), pp.address, pp.core_id)
		pane_show(pp.pane)
		pane_focus(pp.pane)
		pp.reopened = time.tick_now()
		next_step(.Reopened)

	case .Reopened:
		last := fmt.tprintf("persisted %d", PERSIST_ROWS)
		if (!terminal_shows(t, last) || g.animating) && !waited {
			return false
		}

		shown := terminal_shows(t, last)
		check(p, "reopened, the terminal shows its screen again", shown)
		result(p, "time until it shows again", ms_since(pp.reopened), "ms", 5000)
		bar: term.Terminal_Scrollbar
		term.terminal_get(t.session.vt, .Scrollbar, &bar)
		check(p, "and its history", bar.total > u64(PERSIST_ROWS / 2))
		if !shown do return persist_phase_end()

		// Attached once its pane had settled: herdr-core painted it at the size
		// it keeps, as a repaint reflowed to another width splits long lines
		grid := herdr.Size{t.session.cols, t.session.rows}
		painted := term.session_remote_size(&t.session)
		check(p, "it is attached at its settled size", painted == grid)

		want_frame(p, t.view)
		next_step(.Drawn)

	case .Drawn:
		check(p, "the reopened terminal is drawn (read back)", terminal_ink(p) > 200)

		pin := clay.ID("PinnedIcon", u32(pp.pane.id) << 2 | u32(Rename_Place.Title))
		_, pinned := element_rect(pin)
		check(p, "a pinned terminal's icon has a pin", pinned && pane_badge(pp.pane) != nil)

		// Unpinned: restarted here once its idle shell was looked at
		terminal_ask_repin(pp.pane, pinned = false)
		next_step(.Unpinned)

	case .Unpinned:
		if (t.persistent || g.animating) && !waited {
			return false
		}

		local := !t.persistent && term.session_is_local(&t.session)
		check(p, "Unpin restarts it here, without asking while it is idle", local)
		check(p, "and its pin goes", pane_badge(pp.pane) == nil && !g.dialog.open)

		// A right-click on the status bar's terminal button
		button, laid_out := element_rect(clay.ID("TerminalToggle"))
		check(p, "the status bar has its terminal button", laid_out)
		g.mouse_pos = {button.x + button.w / 2, button.y + button.h / 2}
		g.right_pressed = true
		next_step(.Menu)

	case .Menu:
		m := &g.menu
		check(p, "right-click on it asks what new terminals are", m.title == "New terminals")
		check(p, "local, checked", m.count == 2 && m.items[0].checked && !m.items[1].checked)
		m.chosen = Menu_Command.Default_Pinned
		next_step(.Chosen)

	case .Chosen:
		check(p, "choosing Pinned makes new terminals pinned", persist_wanted() && !g.menu.open)
		persist_set_wanted(false)
		pane_close(pp.pane, ask = false)
		pp.pane = nil
		next_step(.Closed)

	case .Closed:
		// The kill goes out on the client's thread
		if time.tick_since(pp.since) < 500 * time.Millisecond do return false
		return persist_phase_end()
	}
	return false
}


// Points herdr at a private session and opens a persistent terminal; done at
// once when herdr-core isn't installed
@(private = "file")
persist_phase_start :: proc(p: ^Perf) -> bool {
	ok, why := herdr.sandbox_begin(&pp.sandbox, "typo-herdr-perf")
	if !ok {
		fmt.printfln("  skipped: %s", why)
		return true
	}

	// New terminals run in herdr-core while the pane opens
	set_string(&g.settings.terminal_backend, "herdr")
	pp.pane = panes_new_terminal()
	set_string(&g.settings.terminal_backend, "local")
	pane_focus(pp.pane)
	next_step(.Starting)
	return false
}


@(private = "file")
persist_phase_end :: proc() -> bool {
	if pp.pane != nil do pane_close(pp.pane, ask = false)
	herdr.sandbox_end(&pp.sandbox)
	delete(pp.address)
	delete(pp.core_id)
	pp = {}
	return true
}


@(private = "file")
next_step :: proc(step: Persist_Step) {
	pp.step = step
	pp.since = time.tick_now()
}


// Whether a row the terminal shows contains `text`
@(private)
terminal_shows :: proc(t: ^Terminal, text: string) -> bool {
	if t == nil do return false

	for row in t.rows {
		if strings.contains(string(row.text[:]), text) do return true
	}
	return false
}


// Pixels read back (want_frame) that differ from the terminal's background
@(private = "file")
terminal_ink :: proc(p: ^Perf) -> int {
	if len(p.read_back) != int(p.read_area.w * p.read_area.h) do return 0

	bg := gfx.theme.bg
	ink := 0
	for px in p.read_back {
		differs := abs(int(px[0]) - int(bg.r)) > 24 ||
		           abs(int(px[1]) - int(bg.g)) > 24 ||
		           abs(int(px[2]) - int(bg.b)) > 24
		if differs do ink += 1
	}
	return ink
}
