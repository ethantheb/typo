package editor

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import sdl "../vendor/sdl3"
import "mdview"
import "textedit"

// The session: the folder, the window, and the panes and where they are,
// saved to session.json beside settings.toml when typo exits. Started with no
// arguments, typo opens it again (the restore_session setting). Files come back
// as saved on disk, with their caret and scroll; terminals come back as new
// shells under their names. A file that is gone leaves its place to the others.
// The recent files of each folder (recent.odin) are saved with it, also when
// the session isn't restored


Session :: struct {
	root:      string, // "" when only the recent files are saved
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
	recent:    []Session_Recent,
}

Session_Recent :: struct {
	root:  string,
	files: []string, // most recent first
}

Session_Pane :: struct {
	file:     string, // "" for a terminal
	name:     string, // a terminal's given name
	caret:    int,
	scroll_y: f64,
	scroll_x: f32,
	rendered: bool, // a Markdown file shown rendered
	zoom:     int,  // percent; 0 (left out) for 100
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

// Writes the session: the recent files, and the rest when restore_session is on
session_save :: proc() {
	if g.perf != nil || g.workspace.root == "" {
		return
	}
	path := session_path()
	if path == "" do return
	recent_drop_missing()

	context.allocator = context.temp_allocator
	ps := &g.panes

	s := Session {
		focused   = -1,
		maximized = -1,
		recent    = recent_saved(&g.recent),
	}
	if !g.settings.restore_session {
		write_session(path, s)
		return
	}

	s.root = g.workspace.root
	s.sidebar = g.sidebar_visible
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
		sp, kept := session_pane(p)
		if !kept do continue

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

	write_session(path, s)
}


@(private = "file")
write_session :: proc(path: string, s: Session) {
	data, err := json.marshal(s, {pretty = true}, context.temp_allocator)
	if err == nil {
		_ = os.write_entire_file(path, data)
	}
}


// A pane as saved. A file not shown, or not created yet, isn't kept
session_pane :: proc(p: ^Pane) -> (sp: Session_Pane, kept: bool) {
	switch c in p.content {
	case ^Editor:
		if !pane_shown(p) || c.new_file || c.disk.missing {
			return
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

		// Still loading: as restored, and in the Markdown view it opens in
		if c.status == .Loading {
			if view, ok := c.load.ready.restore.?; ok {
				sp.caret, sp.scroll_y, sp.scroll_x = view.caret, view.scroll_y, view.scroll_x
			}

			mode, chosen := g.md_modes[c.path]
			if !chosen do mode = mdview.default_mode(int(c.load.size))
			sp.rendered = is_markdown_path(c.path) && mode == .Rendered
		}

	case ^Terminal:
		sp = {name = p.name}
	}

	if step, ok := pane_zoom(p); ok {
		sp.zoom = textedit.zoom_percent(step)
	}
	return sp, true
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

// Reads the saved session, in the temp allocator. Returns false if there is none
session_read :: proc() -> (s: Session, ok: bool) {
	s = {focused = -1, maximized = -1} // if the file leaves them out

	path := session_path()
	if path == "" do return

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return

	if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil {
		return {focused = -1, maximized = -1}, false
	}
	return s, true
}


// Opens a saved session. Returns false if it has no folder to open
session_restore :: proc(s: Session) -> bool {
	if s.root == "" || !os.is_dir(s.root) {
		return false
	}

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


// Opens the saved panes: files with their caret, scroll and zoom, terminals
// under their names with their zoom. A file that is gone, or listed twice,
// leaves a nil
restore_panes :: proc(saved: []Session_Pane) -> []^Pane {
	panes := make([]^Pane, len(saved), context.temp_allocator)

	for sp, i in saved {
		zoom := sp.zoom > 0 ? textedit.zoom_step(sp.zoom) : 0

		if sp.file == "" {
			p := panes_add_terminal()
			pane_init_zoom(p, zoom)
			if sp.name != "" {
				p.name = strings.clone(sp.name)
			}
			panes[i] = p
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

		// The zoom first (the scroll position is in its line heights), then the
		// caret and scroll once the text is there
		if e, is_editor := p.content.(^Editor); is_editor {
			pane_init_zoom(p, zoom)

			view := Restored_View{sp.caret, sp.scroll_y, sp.scroll_x}
			editor_when_ready(e, {restore = view})
		}
		panes[i] = p
	}

	return panes
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
