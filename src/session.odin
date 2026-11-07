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
// shells under their names. A file that is gone leaves its place to the others.

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
	return filepath.join({filepath.dir(g.settings.path), "session.json"}, context.temp_allocator) or_else ""
}

// The window's size while it isn't maximized, kept for the session.
track_window_size :: proc() {
	if sdl.GetWindowFlags(g.window) & {.MAXIMIZED, .FULLSCREEN, .MINIMIZED} == {} {
		g.window_size = {g.window_w, g.window_h}
	}
}

// Writes the session (when restore_session is on).
session_save :: proc() {
	if g.perf != nil || !g.settings.restore_session || g.workspace.root == "" do return
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
	expanded := make([dynamic]string)
	for n, i in g.workspace.nodes do if i > 0 && n.expanded do append(&expanded, n.path)
	s.expanded = expanded[:]

	// Shown panes, and terminals on the shelf; a file not shown is dropped.
	panes := make([dynamic]Session_Pane)
	index := make(map[^Pane]int)
	for p in ps.open {
		sp: Session_Pane
		switch c in p.content {
		case ^Editor:
			if !pane_shown(p) || c.new_file do continue
			sp = {file = c.path, scroll_y = c.target_y, scroll_x = c.target_x, rendered = md_rendered(c)}
			if len(c.sels) > 0 do sp.caret = c.sels[c.primary].head
		case ^Terminal:
			sp = {name = p.name}
		}
		index[p] = len(panes)
		append(&panes, sp)
	}
	s.panes = panes[:]
	if ps.focused != nil do s.focused = index[ps.focused] or_else -1
	if ps.maximized != nil do s.maximized = index[ps.maximized] or_else -1
	save_tile :: proc(t: ^Tile, index: map[^Pane]int) -> Session_Tile {
		if t.pane != nil do return {pane = index[t.pane] or_else -1}
		children := make([]Session_Tile, 2)
		children[0], children[1] = save_tile(t.children[0], index), save_tile(t.children[1], index)
		return {pane = -1, row = t.axis == .Row, ratio = t.ratio, children = children}
	}
	if ps.root != nil {
		layout := make([]Session_Tile, 1)
		layout[0] = save_tile(ps.root, index)
		s.layout = layout
	}
	data, err := json.marshal(s, {pretty = true})
	if err == nil do _ = os.write_entire_file(path, data)
}

// Opens the saved session. Returns false if there is none to open.
session_restore :: proc() -> bool {
	path := session_path()
	if path == "" do return false
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return false
	s := Session{focused = -1, maximized = -1} // if the file leaves them out
	if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil || !os.is_dir(s.root) do return false

	open_folder(s.root)
	g.sidebar_visible = s.sidebar
	workspace_expand(&g.workspace, s.expanded)
	// No larger than the display it opens on.
	w, h := s.window.w, s.window.h
	bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(sdl.GetDisplayForWindow(g.window), &bounds) {
		w, h = min(w, bounds.w), min(h, bounds.h)
	}
	if w > 0 && h > 0 do _ = sdl.SetWindowSize(g.window, w, h)
	if s.window.maximized do _ = sdl.MaximizeWindow(g.window)

	panes := make([]^Pane, len(s.panes), context.temp_allocator)
	for sp, i in s.panes {
		if sp.file == "" {
			panes[i] = panes_add_terminal()
			if sp.name != "" do panes[i].name = strings.clone(sp.name)
			continue
		}
		if !os.is_file(sp.file) do continue
		if is_markdown_path(sp.file) {
			mode := sp.rendered ? mdview.Mode.Rendered : mdview.Mode.Text
			if sp.file in g.md_modes do g.md_modes[sp.file] = mode
			else do g.md_modes[strings.clone(sp.file)] = mode
		}
		p := pane_for_file(sp.file)
		if slice.contains(panes, p) do continue // the file is listed twice
		if e, ok := p.content.(^Editor); ok && e.status == .Text {
			// The file may have changed: not past its end or inside a character.
			at := clamp(sp.caret, 0, buffer.length(&e.buf))
			for at > 0 && at < buffer.length(&e.buf) && buffer.byte_at(&e.buf, at) & 0xC0 == 0x80 do at -= 1
			textedit.set_single_selection(e, {at, at, -1})
			e.scroll_y, e.target_y = sp.scroll_y, sp.scroll_y
			e.scroll_x, e.target_x = sp.scroll_x, sp.scroll_x
		}
		panes[i] = p
	}
	// The tree, without the leaves whose pane couldn't open.
	// A pane is placed once; a second leaf for it is dropped like a missing one.
	build :: proc(st: Session_Tile, panes: []^Pane, placed: ^map[^Pane]bool, parent: ^Tile) -> ^Tile {
		if st.pane >= 0 {
			if st.pane >= len(panes) || panes[st.pane] == nil || panes[st.pane] in placed do return nil
			placed[panes[st.pane]] = true
			t := new(Tile)
			t^ = {pane = panes[st.pane], parent = parent}
			return t
		}
		if len(st.children) != 2 do return nil
		t := new(Tile)
		t^ = {axis = st.row ? .Row : .Column, ratio = clamp(st.ratio, 0.05, 0.95), parent = parent}
		a, b := build(st.children[0], panes, placed, t), build(st.children[1], panes, placed, t)
		if a != nil && b != nil {
			t.children = {a, b}
			return t
		}
		free(t)
		only := a != nil ? a : b
		if only != nil do only.parent = parent
		return only
	}
	placed := make(map[^Pane]bool, context.temp_allocator)
	if len(s.layout) == 1 do g.panes.root = build(s.layout[0], panes, &placed, nil)
	at :: proc(panes: []^Pane, i: int) -> ^Pane {return i >= 0 && i < len(panes) ? panes[i] : nil}
	if p := at(panes, s.maximized); p != nil && pane_shown(p) do g.panes.maximized = p
	if p := at(panes, s.focused); p != nil && pane_shown(p) do pane_focus(p)
	else do panes_focus_any()
	return true
}
