package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
Reset_Settings :: struct {}
Notice :: struct {}

Dialog_Purpose :: union {
	Unsaved_Step,
	Deleting,
	Reset_Settings,
	Notice,
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
	if del, is_delete := d.purpose.(Deleting); is_delete {
		delete(del.path)
	}

	serial := d.serial
	d^ = {choice = -1, serial = serial}
}


dialog_destroy :: proc() {
	dialog_close()
	unsaved_reset()
	delete(g.unsaved.asking)
}


// A message with an OK button
@(private = "file")
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
		if confirmed {
			settings_reset_all(&g.settings)
			settings_changed()
		}

	case Unsaved_Step:
		unsaved_answer((^Pane)(p), choice)

	case Deleting:
		if !confirmed do return

		path := strings.clone(p.path, context.temp_allocator)
		switch delete_path(path, p.permanent) {
		case .Done:
			path_deleted(path)
		case .Not_Recyclable:
			ask_delete_file(path, permanent = true)
		case .Failed:
			// Some of a folder may be gone
			workspace_refresh(&g.workspace)
			finder_invalidate()
			message := fmt.tprintf("%s could not be deleted.", relative_to_root(path))
			show_notice("Couldn't delete", message)
		}
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

// Closing a file, opening a folder or quitting first asks about each file with
// unsaved changes, one dialog at a time; then does what was asked, unless
// cancelled

Closing_Pane :: distinct ^Pane
Quit :: struct {}

After_Unsaved :: union {
	Closing_Pane,
	Open_Folder, // owned
	Quit,
}

Unsaved_Flow :: struct {
	asking: [dynamic]^Pane, // files with unsaved changes still to ask about
	then:   After_Unsaved,
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
	clear(&u.asking)
}


// Asks about the next file, or, with none left, does what was asked
@(private = "file")
unsaved_next :: proc() {
	u := &g.unsaved

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

	switch t in u.then {
	case Closing_Pane:
		pane_close((^Pane)(t), ask = false)

	case Open_Folder:
		for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
			p := g.panes.open[i]
			if is_editor(p) do pane_close(p, ask = false)
		}
		open_folder(string(t))

	case Quit:
		g.quit = true
	}

	unsaved_reset()
}


// Save, Don't save or Cancel for the file asked about
@(private = "file")
unsaved_answer :: proc(p: ^Pane, choice: int) {
	u := &g.unsaved

	switch choice {
	case 0: // Save
		e := p.content.(^Editor)
		if !editor_save(e) {
			name := strings.clone(relative_to_root(e.path), context.temp_allocator)
			unsaved_reset()
			message := fmt.tprintf("%s could not be saved, so nothing was closed.", name)
			show_notice("Couldn't save", message)
			return
		}
		ordered_remove(&u.asking, 0)
		unsaved_next()

	case 1: // Don't save
		ordered_remove(&u.asking, 0)
		unsaved_next()

	case: // Cancel
		unsaved_reset()
	}
}


// --- Files -------------------------------------------------------------------------

// Asks before deleting a file or folder: to the Recycle Bin, or, where there is
// none or the item can't go there, permanently
ask_delete_file :: proc(path: string, permanent := !DELETE_TO_TRASH) {
	name := filepath.base(path)
	what := os.is_dir(path) ? "The folder and everything in it" : "The file"

	message, button: string
	switch {
	case !permanent:
		message = fmt.tprintf("%s will be moved to the Recycle Bin.", what)
		button = "Move to Recycle Bin"
	case DELETE_TO_TRASH:
		message = fmt.tprintf(
			"%s can't be moved to the Recycle Bin, so it would be deleted permanently. %s",
			what,
			"This can't be undone.",
		)
		button = "Delete permanently"
	case:
		message = fmt.tprintf("%s will be deleted permanently. This can't be undone.", what)
		button = "Delete"
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

	title := permanent && DELETE_TO_TRASH ? "Delete \"%s\" permanently?" : "Delete \"%s\"?"
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


ask_reset_settings :: proc() {
	dialog_show(
		"Reset settings",
		"Reset all settings, including keybindings, to their defaults?",
		.Alert,
		{{"Reset all", .Danger}, {"Cancel", .Normal}},
		focus = 1,
		cancel = 1,
		purpose = Reset_Settings{},
	)
}
