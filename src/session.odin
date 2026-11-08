package editor

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "buffer"
import sdl "../vendor/sdl3"
import "mdview"
import "textedit"

// The session: the folder, the window, and the panes and where they are,
// saved to session.json beside settings.toml when typo exits. Started with no
// arguments, typo opens it again (the restore_session setting). Files come back
// as saved on disk, with their caret and scroll; terminals come back as new
// shells under their names. A file that is gone leaves its place to the others


Session :: struct {
	root:      string,
	sidebar:   bool,
	expanded:  []string, // open folders in the tree
	window:    struct {
		w, h:      i32, // size when not maximized
		maximized: bool,
	},
	panes:     []Session_Pane,
	layout:    []Session_Tile, // the tree's root, or none
	focused:   int,            // index into panes, or -1
	maximized: int,
}

Session_Pane :: struct {
	file:     string, // "" for a terminal
	name:     string, // a terminal's given name
	caret:    int,
	scroll_y: f64,
	scroll_x: f32,
	rendered: bool, // a Markdown file shown rendered
}

Session_Tile :: struct {
	pane:     int, // index into panes, or -1 for a split
	row:      bool,
	ratio:    f32,
	children: []Session_Tile,
}


@(private = "file")
session_path :: proc() -> string {
	if g.settings.path == "" do return ""

	dir := filepath.dir(g.settings.path)
	return filepath.join({dir, "session.json"}, context.temp_allocator) or_else ""
}


// The window's size while it isn't maximized, kept for the session
track_window_size :: proc() {
	if sdl.GetWindowFlags(g.window) & {.MAXIMIZED, .FULLSCREEN, .MINIMIZED} == {} {
		g.window_size = {g.window_w, g.window_h}
	}
}


// --- Saving ------------------------------------------------------------------------

// Writes the session (when restore_session is on)
session_save :: proc() {
	if g.perf != nil || !g.settings.restore_session || g.workspace.root == "" {
		return
	}
	path := session_path()
	if path == "" do return

	context.allocator = context.temp_allocator
	ps := &g.panes

	s := Session {
		root      = g.workspace.root,
		sidebar   = g.sidebar_visible,
		focused   = -1,
		maximized = -1,
	}
	s.window.w, s.window.h = g.window_size.x, g.window_size.y
	s.window.maximized = sdl.GetWindowFlags(g.window) & {.MAXIMIZED} != {}

	// Open folders in the tree
	expanded := make([dynamic]string)
	for n, i in g.workspace.nodes {
		if i > 0 && n.expanded {
			append(&expanded, n.path)
		}
	}
	s.expanded = expanded[:]

	// Shown panes, and terminals on the shelf; a file not shown is dropped
	panes := make([dynamic]Session_Pane)
	index := make(map[^Pane]int)
	for p in ps.open {
		sp: Session_Pane
		switch c in p.content {
		case ^Editor:
			if !pane_shown(p) || c.new_file {
				continue
			}

			sp = {
				file     = c.path,
				scroll_y = c.target_y,
				scroll_x = c.target_x,
				rendered = md_rendered(c),
			}
			if len(c.sels) > 0 {
				sp.caret = c.sels[c.primary].head
			}
		case ^Terminal:
			sp = {name = p.name}
		}
		index[p] = len(panes)
		append(&panes, sp)
	}
	s.panes = panes[:]

	if ps.focused != nil {
		s.focused = index[ps.focused] or_else -1
	}
	if ps.maximized != nil {
		s.maximized = index[ps.maximized] or_else -1
	}

	// Where they are
	if ps.root != nil {
		layout := make([]Session_Tile, 1)
		layout[0] = save_tile(ps.root, index)
		s.layout = layout
	}

	data, err := json.marshal(s, {pretty = true})
	if err == nil {
		_ = os.write_entire_file(path, data)
	}
}


// A tile of the split tree as saved, with panes as indices into the session's
@(private = "file")
save_tile :: proc(t: ^Tile, index: map[^Pane]int) -> Session_Tile {
	if t.pane != nil {
		return {pane = index[t.pane] or_else -1}
	}

	children := make([]Session_Tile, 2)
	children[0] = save_tile(t.children[0], index)
	children[1] = save_tile(t.children[1], index)
	return {pane = -1, row = t.axis == .Row, ratio = t.ratio, children = children}
}


// --- Restoring ---------------------------------------------------------------------

// Opens the saved session. Returns false if there is none to open
session_restore :: proc() -> bool {
	path := session_path()
	if path == "" do return false

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return false

	s := Session{focused = -1, maximized = -1} // if the file leaves them out
	if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil {
		return false
	}
	if !os.is_dir(s.root) do return false

	// The folder and the window
	open_folder(s.root)
	g.sidebar_visible = s.sidebar
	workspace_expand(&g.workspace, s.expanded)
	restore_window(s.window.w, s.window.h, s.window.maximized)

	// The panes, and where they were
	panes := restore_panes(s.panes)

	placed := make(map[^Pane]bool, context.temp_allocator)
	if len(s.layout) == 1 {
		g.panes.root = restore_tile(s.layout[0], panes, &placed, nil)
	}

	maximized := pane_at(panes, s.maximized)
	if maximized != nil && pane_shown(maximized) {
		g.panes.maximized = maximized
	}

	focused := pane_at(panes, s.focused)
	if focused != nil && pane_shown(focused) {
		pane_focus(focused)
	} else {
		panes_focus_any()
	}
	return true
}


// Sizes the window, no larger than the display it opens on
@(private = "file")
restore_window :: proc(w, h: i32, maximized: bool) {
	w, h := w, h
	bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(sdl.GetDisplayForWindow(g.window), &bounds) {
		w = min(w, bounds.w)
		h = min(h, bounds.h)
	}

	if w > 0 && h > 0 {
		_ = sdl.SetWindowSize(g.window, w, h)
	}
	if maximized {
		_ = sdl.MaximizeWindow(g.window)
	}
}


// Opens the saved panes: files with their caret and scroll, terminals under
// their names. A file that is gone, or listed twice, leaves a nil
@(private = "file")
restore_panes :: proc(saved: []Session_Pane) -> []^Pane {
	panes := make([]^Pane, len(saved), context.temp_allocator)

	for sp, i in saved {
		if sp.file == "" {
			panes[i] = panes_add_terminal()
			if sp.name != "" {
				panes[i].name = strings.clone(sp.name)
			}
			continue
		}
		if !os.is_file(sp.file) do continue

		if is_markdown_path(sp.file) {
			mode := sp.rendered ? mdview.Mode.Rendered : mdview.Mode.Text
			if sp.file in g.md_modes {
				g.md_modes[sp.file] = mode
			} else {
				g.md_modes[strings.clone(sp.file)] = mode
			}
		}

		p := pane_for_file(sp.file)
		if slice.contains(panes, p) do continue

		e, is_editor := p.content.(^Editor)
		if is_editor && e.status == .Text {
			at := caret_in(&e.buf, sp.caret)
			textedit.set_single_selection(e, {at, at, -1})
			e.scroll_y, e.target_y = sp.scroll_y, sp.scroll_y
			e.scroll_x, e.target_x = sp.scroll_x, sp.scroll_x
		}
		panes[i] = p
	}

	return panes
}


// A saved caret in a file that may have changed: not past its end, and not
// inside a character
@(private = "file")
caret_in :: proc(b: ^buffer.Buffer, saved: int) -> int {
	length := buffer.length(b)
	at := clamp(saved, 0, length)

	for at > 0 && at < length && buffer.byte_at(b, at) & 0xC0 == 0x80 {
		at -= 1
	}
	return at
}


// Rebuilds a saved tile of the split tree, without the leaves whose pane
// couldn't open. A pane is placed once; a second leaf for it is dropped too
@(private = "file")
restore_tile :: proc(
	st: Session_Tile,
	panes: []^Pane,
	placed: ^map[^Pane]bool,
	parent: ^Tile,
) -> ^Tile {
	// A leaf
	if st.pane >= 0 {
		p := pane_at(panes, st.pane)
		if p == nil || p in placed {
			return nil
		}

		placed[p] = true
		t := new(Tile)
		t^ = {pane = p, parent = parent}
		return t
	}

	// A split, unless it lost a side
	if len(st.children) != 2 do return nil

	t := new(Tile)
	t^ = {
		axis   = st.row ? .Row : .Column,
		ratio  = clamp(st.ratio, 0.05, 0.95),
		parent = parent,
	}
	a := restore_tile(st.children[0], panes, placed, t)
	b := restore_tile(st.children[1], panes, placed, t)
	if a != nil && b != nil {
		t.children = {a, b}
		return t
	}

	free(t)
	only := a != nil ? a : b
	if only != nil {
		only.parent = parent
	}
	return only
}


@(private = "file")
pane_at :: proc(panes: []^Pane, i: int) -> ^Pane {
	if i < 0 || i >= len(panes) {
		return nil
	}
	return panes[i]
}
