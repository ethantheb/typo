package editor

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import sdl "../vendor/sdl3"
import "mdview"
import "textedit"

// A project's last state: the window, the panes and where they are, the
// tree's open folders and the recent files, saved to .typo/session.json in the
// project (project.odin) when it is left, by quitting or opening another
// folder, and restored when it opens again (the restore_session setting).
// Files come back as saved on disk, with their caret and scroll; terminals come
// back as new shells under their names, and persistent ones
// (terminal_persist.odin) as they are in herdr-core. A file that is gone leaves
// its place to the others. Paths inside the project are kept relative to it.
//
// What belongs to no project is kept in state.json beside settings.toml
// (App_State): the project typo reopens when started with no arguments. An
// older typo kept one session.json there, with every folder's recent files;
// the first start without state.json takes them over, and each project gets
// its part when it is next opened


Session :: struct {
	sidebar:      bool,
	expanded:     []string, // open folders in the tree
	window:       struct {
		w, h:      i32, // size when not maximized
		maximized: bool,
	},
	panes:        []Session_Pane,
	layout:       []Session_Tile, // the tree's root, or none
	focused:      int,            // index into panes, or -1
	maximized:    int,
	recent_files: []string,       // most recent first
}

Session_Pane :: struct {
	file:       string, // a file, or a diff's file; "" for a terminal or the Git pane
	git:        bool,   // the Git pane
	diff:       string, // a diff's area, as DIFF_AREA_NAMES calls it; "" for a file
	name:       string, // a terminal's given name
	herdr:      string, // a persistent terminal's herdr-core address
	herdr_core: string, // the core that address is on
	caret:      int,
	scroll_y:   f64,
	scroll_x:   f32,
	rendered:   bool, // a Markdown file shown rendered
	zoom:       int,  // percent; 0 (left out) for 100
	gone:       bool `json:"-"`, // its file wasn't there when the session was read
}

Session_Tile :: struct {
	pane:     int, // index into panes, or -1 for a split
	row:      bool,
	ratio:    f32,
	children: []Session_Tile,
}

// state.json
App_State :: struct {
	project:  string,             // reopened when typo starts with no arguments
	imported: []Imported_Project, // from an older typo's session.json, until opened
	recent:   []string,           // projects opened, most recent first
}

// Projects state.json keeps, at most
RECENT_PROJECTS_MAX :: 16

Imported_Project :: struct {
	root:    string,
	session: Session,
}

// What an older typo's session.json held besides a Session's fields
@(private = "file")
Legacy_Session :: struct {
	root:   string,
	recent: []struct {
		root:  string,
		files: []string,
	},
}

@(private = "file")
state: struct {
	project:  string, // owned
	imported: [dynamic]Imported_Project, // in arena
	recent:   [dynamic]string, // owned; projects opened, most recent first
	arena:    virtual.Arena,
}


// The window's size while it isn't maximized, kept for the session
track_window_size :: proc() {
	if sdl.GetWindowFlags(g.window) & {.MAXIMIZED, .FULLSCREEN, .MINIMIZED} == {} {
		g.window_size = {g.window_w, g.window_h}
	}
}


// --- Saving ------------------------------------------------------------------------

// Saves the project's state (on the config thread), and state.json. Not
// before the project's files landed, so a state not restored yet isn't
// overwritten; not for a folder that isn't a project; and no .typo folder is
// made for a state with nothing in it. `leaving` (quitting, or opening another
// folder) drops the recent files the index no longer has first, which walks
// the index; saving as it goes (session_save_frame) doesn't, and writes only
// what changed since the last write
session_save :: proc(leaving := true) {
	p := &g.project
	if g.perf != nil || p.root == "" || project_loading() {
		return
	}

	// state.json: the project to reopen
	if leaving {
		recent_drop_missing()
		if p.keeps do set_string(&state.project, p.root)
		state_save()
	} else if p.keeps && state.project != p.root {
		set_string(&state.project, p.root)
		state_save()
	}
	if !p.keeps do return

	s := session_build()
	if !p.has_dir && session_empty(s) {
		return
	}

	data, err := json.marshal(s, {pretty = true}, context.temp_allocator)
	if err != nil do return

	// Unless it is what was last written there
	path := project_file(p.root, PROJECT_SESSION)
	text := string(data)
	unchanged := path == saving.path && text == saving.text
	if unchanged && !leaving {
		return
	}

	set_string(&saving.path, path)
	set_string(&saving.text, text)
	config_post(Config_Write{
		path     = strings.clone(path),
		text     = strings.clone(text),
		typo_dir = true,
	})
}


// --- Saving as it goes -------------------------------------------------------------

// The state is saved as the user works, not only on quitting or leaving the
// project, so a crash loses little: persistent terminals above all, which
// herdr-core keeps running and the session is how typo finds again. A frame
// checks at most every SESSION_CHECK: the state is built (a few small
// structs) and written on the config thread only if it changed. After frames
// that weren't checked, a timer wakes an idle loop for one more check, so the
// last change is saved too and the loop sleeps again

SESSION_CHECK :: 3 * time.Second

@(private = "file")
saving: struct {
	path:    string,    // owned; the session file last written
	text:    string,    // owned; what was written there
	checked: time.Tick, // the last check
	wake:    time.Tick, // when the timer waking the loop goes off; {} for none
}


// At the end of a frame: checks the state if SESSION_CHECK passed since the
// last check, else sees that a check follows once it has
session_save_frame :: proc() {
	if g.perf != nil || g.project.root == "" {
		return
	}

	since := time.tick_since(saving.checked)
	if saving.checked == {} || since >= SESSION_CHECK {
		saving.checked = time.tick_now()
		session_save(leaving = false)
		return
	}

	// A check once the interval is up, even if the loop is idle by then
	now := time.tick_now()
	waiting := saving.wake != {} && time.tick_diff(now, saving.wake) > 0
	if waiting do return

	left := SESSION_CHECK - since
	saving.wake = time.tick_add(now, left)
	_ = sdl.AddTimer(u32(time.duration_milliseconds(left)) + 1, wake_for_check, nil)
}


session_saving_destroy :: proc() {
	delete(saving.path)
	delete(saving.text)
	saving = {}
}


@(private = "file")
wake_for_check :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return 0 // once
}


// Marks the panes whose file isn't there (paths relative to `root`, or full),
// so restoring doesn't look on the UI thread. Called where the session is read
session_mark_gone :: proc(s: ^Session, root: string) {
	for &sp in s.panes {
		if sp.file == "" do continue

		full := sp.file
		if !filepath.is_abs(full) {
			full = filepath.join({root, full}, context.temp_allocator) or_else full
		}
		sp.gone = !os.is_file(full)
	}
}


// The project's state as saved, in the temp allocator, with paths as the
// project keeps them
session_build :: proc() -> Session {
	context.allocator = context.temp_allocator
	ps := &g.panes

	s := Session {
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
			append(&expanded, project_rel(n.path))
		}
	}
	s.expanded = expanded[:]

	// Shown panes, and terminals on the shelf; a file not shown is dropped
	panes := make([dynamic]Session_Pane)
	index := make(map[^Pane]int)
	for p in ps.open {
		sp, kept := session_pane(p)
		if !kept do continue

		sp.file = project_rel(sp.file)
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

	// The recent files
	recent := make([]string, len(g.recent.files))
	for path, i in g.recent.files do recent[i] = project_rel(path)
	s.recent_files = recent
	return s
}


// Whether a state has nothing worth making a .typo folder for: no panes,
// recent files or open folders
@(private = "file")
session_empty :: proc(s: Session) -> bool {
	return len(s.panes) == 0 && len(s.recent_files) == 0 && len(s.expanded) == 0
}


// A pane as saved, with its file's full path. A file not shown, or not
// created yet, isn't kept
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
		sp.herdr, sp.herdr_core = persist_ids(c)

	case ^Git_View:
		sp = {git = true}

	case ^Diff_View:
		sp = {file = c.path, diff = DIFF_AREA_NAMES[c.area]}
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

// Parses a session.json (on any thread), in `allocator`
session_parse :: proc(data: []u8, allocator: mem.Allocator) -> (s: Session, ok: bool) {
	s = {focused = -1, maximized = -1} // if the file leaves them out
	if json.unmarshal(data, &s, allocator = allocator) != nil {
		return {}, false
	}
	return s, true
}


// Restores a state into the project just opened: the sidebar and the tree's
// folders, the window's size if `window`, and the panes where they were
session_restore :: proc(s: Session, window: bool) {
	g.sidebar_visible = s.sidebar
	workspace_expand(&g.workspace, session_paths(s.expanded))
	if window {
		restore_window(s.window.w, s.window.h, s.window.maximized)
	}

	// The panes, and where they were
	saved := slice.clone(s.panes, context.temp_allocator)
	for &sp in saved do sp.file = project_abs(sp.file)
	panes := restore_panes(saved)

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
// under their names with their zoom (a persistent one shows its herdr-core
// terminal). A file that is gone, or listed twice,
// leaves a nil
restore_panes :: proc(saved: []Session_Pane) -> []^Pane {
	panes := make([]^Pane, len(saved), context.temp_allocator)

	for sp, i in saved {
		zoom := sp.zoom > 0 ? textedit.zoom_step(sp.zoom) : 0

		if sp.git {
			if git_pane() == nil {
				gv := new(Git_View)
				git_view_init(gv)
				panes[i] = panes_add_git(gv)
			}
			continue
		}

		// A diff loads once the repository is known
		if area, is_diff := diff_area_named(sp.diff); is_diff {
			dv := new(Diff_View)
			diff_view_open(dv, sp.file, area)
			dv.zoom = zoom
			panes[i] = panes_add_diff(dv)
			continue
		}

		if sp.file == "" {
			p := panes_add_terminal()
			pane_init_zoom(p, zoom)
			if sp.name != "" {
				p.name = strings.clone(sp.name)
			}
			if sp.herdr != "" {
				persist_restore(p.content.(^Terminal), sp.herdr, sp.herdr_core)
			}
			panes[i] = p
			continue
		}
		if sp.gone do continue

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


// --- state.json --------------------------------------------------------------------

// Reads state.json at startup, before the first project opens; without one,
// takes over an older typo's session.json
state_init :: proc() {
	if virtual.arena_init_growing(&state.arena) != nil do return
	arena := virtual.arena_allocator(&state.arena)
	state.imported = make([dynamic]Imported_Project, arena)
	if g.settings.path == "" do return

	// state.json
	path := state_file("state.json")
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		saved: App_State
		if json.unmarshal(data, &saved, allocator = arena) == nil {
			state.project = strings.clone(saved.project)
			append(&state.imported, ..saved.imported)

			// Folders still there (read once, at startup, as settings.toml)
			for root in saved.recent {
				if os.is_dir(root) do append(&state.recent, strings.clone(root))
			}
		}
		return
	}

	// An older typo's session.json
	data, err := os.read_entire_file(state_file("session.json"), context.temp_allocator)
	if err != nil do return

	legacy: Legacy_Session
	session, ok := session_parse(data, arena)
	if !ok || json.unmarshal(data, &legacy, allocator = arena) != nil {
		return
	}
	state_import(legacy, session)
}


// A file beside settings.toml (temp)
@(private = "file")
state_file :: proc(name: string) -> string {
	dir := filepath.dir(g.settings.path)
	return filepath.join({dir, name}, context.temp_allocator) or_else ""
}


// Takes over an older typo's session: its folder is the project to reopen,
// with its panes, and each folder keeps its recent files
@(private = "file")
state_import :: proc(legacy: Legacy_Session, session: Session) {
	session := session
	session_mark_gone(&session, legacy.root)
	if legacy.root != "" {
		state.project = strings.clone(legacy.root)
		append(&state.imported, Imported_Project{legacy.root, session})
	}

	for folder in legacy.recent {
		found := false
		for &imported in state.imported {
			if !same_path(imported.root, folder.root) do continue

			imported.session.recent_files = folder.files
			found = true
		}
		if !found {
			s := Session {
				sidebar      = true,
				focused      = -1,
				maximized    = -1,
				recent_files = folder.files,
			}
			append(&state.imported, Imported_Project{folder.root, s})
		}
	}
}


// The project to reopen when typo starts with no arguments, or ""
state_last_project :: proc() -> string {
	return state.project
}


// The projects opened, most recent first
state_recent_projects :: proc() -> []string {
	return state.recent[:]
}


// A project opened: first among the recent ones, which state.json keeps
state_project_opened :: proc(root: string) {
	for r, i in state.recent {
		if same_path(r, root) {
			delete(r)
			ordered_remove(&state.recent, i)
			break
		}
	}
	inject_at(&state.recent, 0, strings.clone(root))
	for len(state.recent) > RECENT_PROJECTS_MAX {
		delete(pop(&state.recent))
	}
	state_save()
}


// What an older typo kept for a project, taken (once)
state_take_imported :: proc(root: string) -> (s: Session, ok: bool) {
	for imported, i in state.imported {
		if same_path(imported.root, root) {
			ordered_remove(&state.imported, i)
			return imported.session, true
		}
	}
	return
}


// Writes state.json (on the config thread)
@(private = "file")
state_save :: proc() {
	if g.settings.path == "" do return

	saved := App_State{state.project, state.imported[:], state.recent[:]}
	data, err := json.marshal(saved, {pretty = true}, context.temp_allocator)
	if err != nil do return

	path := strings.clone(state_file("state.json"))
	config_post(Config_Write{path = path, text = strings.clone(string(data))})
}


state_destroy :: proc() {
	delete(state.project)
	delete(state.imported)
	for root in state.recent do delete(root)
	delete(state.recent)
	virtual.arena_destroy(&state.arena)
	state = {}
}
