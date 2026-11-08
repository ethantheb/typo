package editor

import "core:os"
import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"

// Renaming in place: a file or folder in the tree, a terminal on the shelf, or
// a pane in its title becomes a text field. Enter keeps the new name (a refused
// one stays in the field with the reason under it), Esc puts the old one back,
// a press elsewhere keeps it if it can. Creating a file or folder is the same
// field, in a new row at the top of the folder's contents


Rename_Place :: enum {
	Tree,
	Shelf,
	Title,
}

Inline_Rename :: struct {
	active: bool,
	place:  Rename_Place,
	create: enum {
		None,
		File,
		Folder,
	},
	path:   string, // owned; the file or folder, the folder to create in, "" for a terminal
	pane:   ^Pane,  // the pane renamed on the shelf or in its title
	edit:   Line_Edit,
	error:  string, // owned; why the name was refused
	shown:  bool,   // the field was in the last layout
	opened: u64,    // frame
}


// Starts renaming a file or folder; for a file, the name before its extension
// is selected
rename_start_file :: proc(path: string, place: Rename_Place, pane: ^Pane = nil) {
	rename_end()

	r := &g.rename
	r^ = {
		active = true,
		place  = place,
		path   = strings.clone(path),
		pane   = pane,
		edit   = r.edit,
		opened = g.frame,
	}

	name := filepath.base(path)
	stem := len(name)
	ext := filepath.ext(name)
	if !os.is_dir(path) && ext != "" && len(ext) < len(name) {
		stem -= len(ext)
	}
	line_edit_set(&r.edit, name, 0, stem)
}


// Starts naming a new file or folder in `dir`, which opens in the tree
create_start :: proc(dir: string, folder: bool) {
	rename_end()

	ws := &g.workspace
	for n, i in ws.nodes {
		if i > 0 && n.is_dir && n.path == dir && !n.expanded {
			workspace_toggle(ws, i)
			break
		}
	}

	r := &g.rename
	r^ = {
		active = true,
		place  = .Tree,
		create = folder ? .Folder : .File,
		path   = strings.clone(dir),
		edit   = r.edit,
		opened = g.frame,
	}
}


// Whether a new entry is being named in `dir`
creating_in :: proc(dir: string) -> bool {
	r := &g.rename
	return r.active && r.create != .None && r.path == dir
}


rename_start_terminal :: proc(p: ^Pane, place: Rename_Place) {
	rename_end()

	r := &g.rename
	r^ = {active = true, place = place, pane = p, edit = r.edit, opened = g.frame}

	title := pane_title(p)
	line_edit_set(&r.edit, title, 0, len(title))
}


// Renames the focused pane in its title
rename_focused_pane :: proc() -> bool {
	p := g.panes.focused
	if p == nil do return false

	switch c in p.content {
	case ^Editor:   rename_start_file(c.path, .Title, p)
	case ^Terminal: rename_start_terminal(p, .Title)
	}
	return true
}


rename_end :: proc() {
	r := &g.rename
	delete(r.path)
	delete(r.error)

	// The text buffer is kept for the next rename
	text := r.edit.text
	clear(&text)
	r^ = {edit = {text = text}}
}


rename_destroy :: proc() {
	rename_end()
	delete(g.rename.edit.text)
}


// Keeps the new name. A refused one stays in the field when `keep_if_refused`,
// else the rename is dropped
@(private = "file")
rename_commit :: proc(keep_if_refused: bool) {
	r := &g.rename
	name := strings.trim_space(line_edit_string(&r.edit))

	problem: string
	switch {
	case r.create != .None:
		// Nothing typed: nothing to create
		if name == "" && !keep_if_refused {
			break
		}
		problem = create_path(r.path, name, r.create == .Folder)

	case r.path == "":
		delete(r.pane.name)
		r.pane.name = name != "" ? strings.clone(name) : ""

	case:
		problem = rename_path(r.path, name)
	}

	if problem != "" && keep_if_refused {
		delete(r.error)
		r.error = strings.clone(problem)
		return
	}
	rename_end()
}


// Whether the field for `place` and the given file or pane is showing
renaming :: proc(place: Rename_Place, path: string = "", pane: ^Pane = nil) -> bool {
	r := &g.rename
	if !r.active || r.place != place || r.create != .None {
		return false
	}

	if pane != nil do return r.pane == pane
	return r.path == path
}


// At the start of a frame: a press outside the field keeps the name (and still
// does what it does), unless it is on the dialog or the context menu; a field
// no longer shown is dropped
rename_frame :: proc() {
	r := &g.rename
	if !r.active do return

	on_popup := g.dialog.open || (g.menu.open && pointer_in(clay.ID("ContextMenu")))
	pressed_outside := g.mouse_pressed &&
	                   r.opened != g.frame &&
	                   !pointer_in(clay.ID("RenameField")) &&
	                   !on_popup

	if !r.shown && g.frame > r.opened + 1 {
		rename_end()
	} else if pressed_outside {
		rename_commit(keep_if_refused = false)
	}

	g.rename.shown = false
}


// Keys while renaming; it takes them all
rename_handle_event :: proc(event: ^sdl.Event) -> bool {
	r := &g.rename
	if !r.active do return false

	if event.type == .KEY_DOWN {
		switch event.key.key {
		case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_TAB:
			rename_commit(keep_if_refused = true)
			return true
		case sdl.K_ESCAPE:
			rename_end()
			return true
		}
	}

	// A changed name clears the reason the last one was refused
	if _, changed := line_edit_event(&r.edit, event); changed {
		delete(r.error)
		r.error = ""
	}
	return true
}


// The field, in place of a name
rename_field :: proc(size: u16) {
	r := &g.rename
	r.shown = true

	id := clay.ID("RenameField")
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(f32(size) + 7)},
			padding = {left = 4, right = 4},
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.theme.bg,
		cornerRadius = clay.CornerRadiusAll(4),
		border = {
			color = r.error != "" ? gfx.theme.error : gfx.theme.accent,
			width = clay.BorderOutside(1),
		},
		clip = {horizontal = true},
	}) {
		line_edit_ui(&r.edit, size, gfx.theme.text_bright)
	}

	if r.error == "" do return

	// Why the name was refused, in a bubble under the field
	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingFit({max = 260})},
			padding = {left = 8, right = 8, top = 4, bottom = 4},
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = gfx.theme.error, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .ElementWithId,
			parentId = id.id,
			attachment = {element = .LeftTop, parent = .LeftBottom},
			offset = {0, 3},
			zIndex = 130,
			pointerCaptureMode = .Passthrough,
		},
	}) {
		paragraph(r.error, gfx.theme.error)
	}
}
