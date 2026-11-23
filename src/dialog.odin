package editor

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// Dialogs: a panel over the dimmed window with a message and up to three
// buttons. Enter presses the focused button (arrows and Tab move the focus), Esc
// the cancel button. A choice, by key or click, is applied at the start of the
// next frame (dialog_frame), since it may free strings this frame's render
// commands use. What a choice does is the dialog's Dialog_Purpose


Dialog_Role :: enum {
	Normal,
	Primary,
	Danger,
}

Dialog_Button :: struct {
	label: string,
	role:  Dialog_Role,
}

// What a dialog is for
Unsaved_Step :: distinct ^Pane // a file in the unsaved-changes flow
Deleting :: struct {
	path:      string, // owned, a file or folder
	permanent: bool,
}
Reset_Settings :: struct {
	scope: Settings_Scope, // the user's settings, or the project's values
}
Notice :: struct {}
Removing_Server :: struct {
	name: string, // owned; a server the settings added
}
Applying_Edit :: struct {} // a language server's edit of files that aren't open
Reloading :: struct {
	path: string, // owned; a file changed on disk under unsaved edits (file_sync.odin)
}
Overwriting :: struct {
	path: string, // owned; a file being saved over a version typo hasn't read
}
Opening_Large :: struct {
	id: u64, // the load of a file larger than the ask_above_mb setting
}
Ending_Programs :: struct {} // the unsaved-changes flow's step for running programs
Git_Discarding :: struct {
	tracked:   []string, // owned; files whose changes go back to the staged version
	untracked: []string, // owned; files deleted
}
Git_Remote_Failed :: struct {
	line: string, // owned; the git command that failed, to run in a terminal
}

Dialog_Purpose :: union {
	Unsaved_Step,
	Deleting,
	Reset_Settings,
	Notice,
	Removing_Server,
	Applying_Edit,
	Reloading,
	Overwriting,
	Opening_Large,
	Ending_Programs,
	Git_Discarding,
	Git_Remote_Failed,
}

Dialog :: struct {
	open:    bool,
	title:   string, // owned
	message: string, // owned
	icon:    gfx.Icon,
	buttons: [3]Dialog_Button,
	count:   int,
	focus:   int, // the button Enter presses
	cancel:  int, // the button Esc presses
	purpose: Dialog_Purpose,
	choice:  int, // pressed, applied next frame; -1 for none
	serial:  int, // counts dialogs shown, to tell whether applying a choice showed another
}


dialog_show :: proc(
	title, message: string,
	icon: gfx.Icon,
	buttons: []Dialog_Button,
	focus, cancel: int,
	purpose: Dialog_Purpose,
) {
	dialog_close()
	menu_close()

	d := &g.dialog
	d.open = true
	d.serial += 1
	d.title = strings.clone(title)
	d.message = strings.clone(message)
	d.icon = icon
	d.count = min(len(buttons), len(d.buttons))
	copy(d.buttons[:], buttons)
	d.focus, d.cancel = focus, cancel
	d.purpose = purpose
	d.choice = -1
}


// Closes the dialog, freeing what it owns
dialog_close :: proc() {
	d := &g.dialog
	if !d.open do return

	delete(d.title)
	delete(d.message)
	#partial switch p in d.purpose {
	case Deleting:        delete(p.path)
	case Removing_Server: delete(p.name)
	case Reloading:       delete(p.path)
	case Overwriting:     delete(p.path)
	case Git_Remote_Failed: delete(p.line)
	case Git_Discarding:
		for path in p.tracked do delete(path)
		for path in p.untracked do delete(path)
		delete(p.tracked)
		delete(p.untracked)
	}

	serial := d.serial
	d^ = {choice = -1, serial = serial}
}


dialog_destroy :: proc() {
	dialog_close()
	unsaved_reset()
	delete(g.unsaved.asking)
	delete(g.unsaved.ending)
}


// A message with an OK button
show_notice :: proc(title, message: string) {
	dialog_show(title, message, .Alert, {{"OK", .Primary}}, 0, 0, Notice{})
}


// --- Per frame ---------------------------------------------------------------------

// Applies a choice made last frame
dialog_frame :: proc() {
	d := &g.dialog
	if !d.open || d.choice < 0 {
		return
	}

	choice, serial := d.choice, d.serial
	d.choice = -1
	dialog_apply(choice)

	// Unless applying it showed another dialog
	if d.serial == serial do dialog_close()
}


// What a choice does. A dialog shown here replaces this one
@(private = "file")
dialog_apply :: proc(choice: int) {
	d := &g.dialog
	confirmed := choice != d.cancel

	switch p in d.purpose {
	case Notice:

	case Reset_Settings:
		if !confirmed do break

		switch p.scope {
		case .User:
			settings_reset_all(&g.settings)
			settings_changed()
		case .Project:
			settings_clear_project(&g.settings)
			project_settings_changed()
		}

	case Removing_Server:
		if confirmed do settings_remove_server(p.name)

	case Applying_Edit:
		lsp_edit_confirmed(confirmed)

	case Reloading:
		reload_answer(p.path, reload = confirmed)

	case Overwriting:
		overwrite_answer(p.path, confirmed)

	case Opening_Large:
		large_file_answer(p.id, open = confirmed)

	case Git_Discarding:
		git_discard_answer(p, confirmed)

	case Git_Remote_Failed:
		git_remote_failed_answer(p, run = confirmed)

	case Unsaved_Step:
		unsaved_answer((^Pane)(p), choice)

	case Ending_Programs:
		programs_answer(confirmed)

	case Deleting:
		if confirmed do delete_path(p.path, p.permanent)
	}
}


// Keys while the dialog is open; it takes them all
dialog_handle_event :: proc(event: ^sdl.Event) -> bool {
	d := &g.dialog
	if !d.open do return false
	if event.type != .KEY_DOWN do return true

	shift := event.key.mod & sdl.KMOD_SHIFT != {}
	step := shift ? d.count - 1 : 1

	switch event.key.key {
	case sdl.K_RETURN, sdl.K_KP_ENTER: d.choice = d.focus
	case sdl.K_ESCAPE:                 d.choice = d.cancel
	case sdl.K_TAB:                    d.focus = (d.focus + step) % d.count
	case sdl.K_LEFT:                   d.focus = max(d.focus - 1, 0)
	case sdl.K_RIGHT:                  d.focus = min(d.focus + 1, d.count - 1)
	}
	return true
}


// --- UI ----------------------------------------------------------------------------

DIALOG_WIDTH :: 420

dialog_ui :: proc() {
	d := &g.dialog
	if !d.open do return

	g.in_popup = true
	defer g.in_popup = false

	window := [2]f32{f32(g.window_w), f32(g.window_h)}

	// The dimmed window, with the panel in its middle
	if clay.UI(clay.ID("DialogBackdrop"))({
		layout = {
			sizing = {clay.SizingFixed(window.x), clay.SizingFixed(window.y)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = gfx.theme.backdrop,
		floating = {attachTo = .Root, zIndex = 150},
		transition = transition({.BackgroundColor}, .Clear),
	}) {
		if clay.UI(clay.ID("Dialog"))({
			layout = {
				sizing = {width = clay.SizingFixed(min(DIALOG_WIDTH, window.x - 32))},
				layoutDirection = .TopToBottom,
				padding = {left = 20, right = 20, top = 18, bottom = 18},
				childGap = 12,
			},
			backgroundColor = gfx.theme.panel,
			overlayColor = clear_overlay(gfx.theme.panel),
			cornerRadius = clay.CornerRadiusAll(10),
			border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
			transition = transition({.OverlayColor}, .Fade, 0.15),
		}) {
			// Icon and title
			if clay.UI()({layout = {childGap = 10, childAlignment = {y = .Center}}}) {
				danger := d.buttons[d.focus].role == .Danger
				icon(d.icon, danger ? gfx.theme.error : gfx.theme.accent, 18)
				label(d.title, gfx.theme.text_bright, 15, .SemiBold)
			}

			if d.message != "" do paragraph(d.message, gfx.theme.text_dim)

			// Buttons, on the right
			if clay.UI()({
				layout = {sizing = {width = clay.SizingGrow()}, padding = {top = 6}, childGap = 8},
			}) {
				push_right()
				for b, i in d.buttons[:d.count] {
					if dialog_button(clay.ID("DialogButton", u32(i)), b, i == d.focus) {
						d.choice = i
					}
				}
			}
		}
	}
}


@(private = "file")
dialog_button :: proc(id: clay.ElementId, b: Dialog_Button, focused: bool) -> bool {
	bg, fg := gfx.theme.hover, gfx.theme.text
	switch b.role {
	case .Normal:
	case .Primary: bg, fg = gfx.theme.accent, gfx.theme.bg
	case .Danger:  bg, fg = gfx.theme.error, gfx.theme.bg
	}

	border: clay.BorderElementConfig
	if focused {
		border = {color = gfx.theme.text_bright, width = clay.BorderOutside(1)}
	}

	if clay.UI(id)({
		layout = {
			padding = {left = 14, right = 14, top = 6, bottom = 6},
			childAlignment = {y = .Center},
		},
		backgroundColor = bg,
		overlayColor = clay.Hovered() ? {255, 255, 255, 30} : {},
		cornerRadius = clay.CornerRadiusAll(6),
		border = border,
	}) {
		label(b.label, fg, 13, .SemiBold)
	}
	return clicked(id)
}


// --- Unsaved changes ---------------------------------------------------------------

// Closing a pane, opening a folder or quitting first asks about each file with
// unsaved changes, one dialog at a time, then, if programs run in terminals it
// would end, about those (terminal_programs.odin); then does what was asked,
// unless cancelled. Before each question, and before doing it, the flow waits
// for every write under way to land (the writer thread saves): a file a write
// saved isn't asked about, and a failed write stops the flow

Closing_Pane :: distinct ^Pane
Quit :: struct {}
Repinning :: struct {
	pane:   ^Pane, // a terminal, restarted pinned (in herdr-core) or here
	pinned: bool,
}

After_Unsaved :: union {
	Closing_Pane,
	Open_Folder, // owned
	Quit,
	Repinning,
}

Unsaved_Flow :: struct {
	asking:   [dynamic]^Pane, // files with unsaved changes still to ask about
	then:     After_Unsaved,
	waiting:  bool, // for writes under way to land (unsaved_frame)

	// The terminals `then` ends, and what runs in them
	programs: Programs_Step,
	ending:   [dynamic]^Pane, // checked terminals; nil for one closed meanwhile
	check:    ^Programs_Check,
}

Programs_Step :: enum {
	Unchecked,
	Checking,  // the check's thread lists them (unsaved_frame)
	Asking,    // the dialog asks whether to end them
	Confirmed, // none run, or ending them was confirmed
}


// Asks about the unsaved changes in `panes`, then does `then`
resolve_unsaved :: proc(panes: []^Pane, then: After_Unsaved) {
	unsaved_reset()

	u := &g.unsaved
	for p in panes {
		if pane_modified(p) do append(&u.asking, p)
	}
	u.then = then

	unsaved_next()
}


panes_unsaved :: proc() -> bool {
	for p in g.panes.open {
		if pane_modified(p) do return true
	}
	return false
}


@(private = "file")
unsaved_reset :: proc() {
	u := &g.unsaved
	if path, is_folder := u.then.(Open_Folder); is_folder {
		delete(string(path))
	}
	u.then = nil
	u.waiting = false
	clear(&u.asking)

	programs_check_release(u.check)
	u.check = nil
	u.programs = .Unchecked
	clear(&u.ending)
}


// Per frame: goes on once the writes the flow waits for have landed, or the
// programs in the terminals were listed
unsaved_frame :: proc() {
	u := &g.unsaved
	listed := u.programs == .Checking && programs_check_done(u.check)
	if (u.waiting && !saves_pending()) || listed {
		unsaved_next()
	}
}


// A write failed while the flow runs: it stops, and says so. False if no flow
// runs
unsaved_save_failed :: proc(e: ^Editor, problem: string) -> bool {
	if g.unsaved.then == nil do return false

	unsaved_reset()
	message := fmt.tprintf(
		"%s could not be saved (%s), so nothing was closed.",
		relative_to_root(e.path),
		problem,
	)
	show_notice("Couldn't save", message)
	return true
}


// A pane closed while the flow runs: it isn't asked about, or closed, anymore
unsaved_forget :: proc(p: ^Pane) {
	u := &g.unsaved
	if i, found := slice.linear_search(u.asking[:], p); found {
		ordered_remove(&u.asking, i)
	}
	if i, found := slice.linear_search(u.ending[:], p); found {
		u.ending[i] = nil // still the check's i-th shell
	}
	if closing, ok := u.then.(Closing_Pane); ok && (^Pane)(closing) == p {
		u.then = nil
	}
	if repin, ok := u.then.(Repinning); ok && repin.pane == p {
		u.then = nil
	}
}


// Asks about the next file, or, with none left, does what was asked. Waits
// for writes under way first; files saved meanwhile aren't asked about
@(private = "file")
unsaved_next :: proc() {
	u := &g.unsaved
	u.waiting = saves_pending()
	if u.waiting do return

	for len(u.asking) > 0 && !pane_modified(u.asking[0]) {
		ordered_remove(&u.asking, 0)
	}

	if len(u.asking) > 0 {
		e := u.asking[0].content.(^Editor)
		name := relative_to_root(e.path)
		dialog_show(
			"Unsaved changes",
			fmt.tprintf("Save the changes to %s? They are lost if you don't.", name),
			.Alert,
			{{"Save", .Primary}, {"Don't save", .Normal}, {"Cancel", .Normal}},
			focus = 0,
			cancel = 2,
			purpose = Unsaved_Step(u.asking[0]),
		)
		return
	}

	// Nothing left to do: its pane closed meanwhile (a check under way is let go)
	if u.then == nil {
		unsaved_reset()
		return
	}

	// Programs running in terminals it ends are asked about
	if u.programs != .Confirmed {
		check_programs()
		if u.programs != .Confirmed do return
	}

	switch t in u.then {
	case Closing_Pane:
		pane_close((^Pane)(t), ask = false)

	case Open_Folder:
		project_leave()
		open_folder(string(t))

	case Quit:
		g.quit = true

	case Repinning:
		terminal_repin(t.pane, t.pinned)
	}

	unsaved_reset()
}


// The flow's step for running programs: starts listing what runs in the
// terminals it ends, then, once listed, asks if any runs a program
@(private = "file")
check_programs :: proc() {
	u := &g.unsaved

	switch u.programs {
	case .Unchecked:
		append(&u.ending, ..terminals_ended_by(u.then))
		if len(u.ending) == 0 {
			u.programs = .Confirmed
			return
		}
		u.check = programs_check_start(u.ending[:])
		u.programs = .Checking

	case .Checking:
		if !programs_check_done(u.check) do return

		// The terminals that run one, each with the first it runs
		running := make([dynamic]^Pane, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		for p, i in u.ending {
			name := programs_check_first(u.check, i)
			if p == nil || name == "" {
				continue
			}

			append(&running, p)
			append(&names, strings.clone(name, context.temp_allocator))
		}
		programs_check_release(u.check)
		u.check = nil

		if len(running) == 0 {
			u.programs = .Confirmed
			return
		}
		u.programs = .Asking
		ask_ending_programs(running[:], names[:])

	case .Asking, .Confirmed:
	}
}


// Asks whether to end the programs running in terminals, naming them
@(private = "file")
ask_ending_programs :: proc(running: []^Pane, names: []string) {
	u := &g.unsaved

	// What ends them
	title, button, doing: string
	switch t in u.then {
	case Closing_Pane:
		title, button, doing = "Close the terminal?", "Close terminal", "Closing the terminal"
	case Open_Folder:
		title, button, doing = "Open another folder?", "Open folder", "Opening another folder"
	case Quit:
		title, button, doing = "Quit typo?", "Quit", "Quitting"
	case Repinning:
		if t.pinned {
			title, button = "Pin the terminal?", "Pin"
			doing = "Pinning restarts the terminal in herdr-core, which"
		} else {
			title, button = "Unpin the terminal?", "Unpin"
			doing = "Unpinning restarts the terminal here, which"
		}
	}

	message: string
	if len(running) == 1 {
		place := pane_title(running[0])
		message = fmt.tprintf("%s is still running in %s. %s ends it.", names[0], place, doing)
	} else {
		list := strings.join(names, ", ", context.temp_allocator)
		message = fmt.tprintf(
			"Programs are still running in %d terminals (%s). %s ends them.",
			len(running),
			list,
			doing,
		)
	}

	dialog_show(
		title,
		message,
		.Terminal,
		{{button, .Danger}, {"Cancel", .Normal}},
		focus = 1,
		cancel = 1,
		purpose = Ending_Programs{},
	)
}


// End them, or Cancel
@(private = "file")
programs_answer :: proc(confirmed: bool) {
	u := &g.unsaved
	if !confirmed || u.programs != .Asking {
		unsaved_reset()
		return
	}

	u.programs = .Confirmed
	unsaved_next()
}


// Save, Don't save or Cancel for the file asked about
@(private = "file")
unsaved_answer :: proc(p: ^Pane, choice: int) {
	u := &g.unsaved

	switch choice {
	case 0: // Save; asked again if edited before the write landed
		e := p.content.(^Editor)
		if !editor_save(e) {
			name := strings.clone(relative_to_root(e.path), context.temp_allocator)
			unsaved_reset()
			message := fmt.tprintf("%s could not be saved, so nothing was closed.", name)
			show_notice("Couldn't save", message)
			return
		}
		unsaved_next()

	case 1: // Don't save
		ordered_remove(&u.asking, 0)
		unsaved_next()

	case: // Cancel
		unsaved_reset()
	}
}


// --- Files -------------------------------------------------------------------------

// Asks before deleting a file or folder: to the trash, or, when the item
// can't go there, permanently
ask_delete_file :: proc(path: string, permanent := false) {
	name := filepath.base(path)
	what := workspace_is_folder(&g.workspace, path) ? "The folder and everything in it" : "The file"

	message, button: string
	if permanent {
		message = fmt.tprintf(
			"%s can't be moved to the %s, so it would be deleted permanently. %s",
			what,
			TRASH_NAME,
			"This can't be undone.",
		)
		button = "Delete permanently"
	} else {
		message = fmt.tprintf("%s will be moved to the %s.", what, TRASH_NAME)
		button = fmt.tprintf("Move to %s", TRASH_NAME)
	}

	// Unsaved changes in it go too
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if is_editor && editor_is_modified(e) && path_within(e.path, path) {
			lost := filepath.base(e.path)
			message = fmt.tprintf("%s Unsaved changes in %s are lost.", message, lost)
			break
		}
	}

	title := permanent ? "Delete \"%s\" permanently?" : "Delete \"%s\"?"
	buttons := []Dialog_Button{{button, .Danger}, {"Cancel", .Normal}}
	dialog_show(
		fmt.tprintf(title, name),
		message,
		.Trash,
		buttons,
		focus = permanent ? 1 : 0,
		cancel = 1,
		purpose = Deleting{strings.clone(path), permanent},
	)
}


// Asks before resetting the user's settings, or removing the project's values
ask_reset_settings :: proc(scope := Settings_Scope.User) {
	message := "Reset all settings, including keybindings, to their defaults?"
	if scope == .Project {
		message = "Remove every setting this project sets, so yours apply? Its pinned " +
		          "files stay."
	}

	dialog_show(
		"Reset settings",
		message,
		.Alert,
		{{"Reset all", .Danger}, {"Cancel", .Normal}},
		focus = 1,
		cancel = 1,
		purpose = Reset_Settings{scope},
	)
}


// Asks before removing a server the settings added
ask_remove_server :: proc(name: string) {
	dialog_show(
		"Remove server",
		fmt.tprintf("Remove the language server \"%s\" from the settings?", name),
		.Trash,
		{{"Remove", .Danger}, {"Cancel", .Normal}},
		focus = 1,
		cancel = 1,
		purpose = Removing_Server{strings.clone(name)},
	)
}
