package editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"

// Panes: the open files and terminals (g.panes.open). The ones shown are the
// leaves of a split tree (Tile) that fills the work area beside the sidebar;
// terminals that aren't shown wait on the shelf, the list under the file tree.
// A file comes from the tree, and closes when another takes its place unless it
// has unsaved changes. Each pane is a floating Clay element
// at the rect its leaf gets, always a child of "Main" wherever it sits in the
// tree, so a change to the tree only moves and resizes panes, which their
// transitions animate. Every change of place (opening, splitting, swapping,
// docking, putting on the shelf) is a Drop applied by drop_apply.

PANE_GAP :: 6 // between panes, and around them
PANE_RADIUS :: 8
PANE_HEADER_HEIGHT :: 30
PANE_MIN_SIZE :: 100 // a divider keeps both sides at least this big
DRAG_THRESHOLD :: 4 // how far a press on a title, shelf row or file moves before it drags
EDGE_ZONE :: 32 // a drop this close to the work area's edge takes half of the area
CENTER_ZONE :: 0.3 // a drop at least this far into a pane from each edge takes its place

Pane_Content :: union {
	^Editor,
	^Terminal,
}

Pane :: struct {
	id:      u32,          // for Clay element ids; never reused
	content: Pane_Content, // owned
	number:  int,          // terminals: 1, 2, ..., to tell them apart in titles
	name:    string,       // owned; a terminal's name, given by renaming it
	fade_in: bool,         // appears with a fade (not when it takes another pane's place)
	visible: bool,         // declared in the last layout
	rect:    gfx.Rect,     // where the last layout put it
}

Axis :: enum {
	Row,    // children side by side
	Column, // children stacked
}

Side :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

// A node of the layout: a pane, or a split of its rect between two children.
Tile :: struct {
	pane:     ^Pane, // a leaf; nil for a split
	axis:     Axis,
	ratio:    f32, // the first child's share
	children: [2]^Tile,
	parent:   ^Tile,
	rect:     gfx.Rect, // from the last layout
}

// Where a pane goes.
Drop :: struct {
	kind:   enum {
		None,
		Shelf, // out of the layout
		Fill,  // the whole work area, which is empty
		Edge,  // one side of the whole work area
		Split, // one side of target
		Swap,  // target's place; target takes the pane's, or goes to the shelf
	},
	target: ^Pane,
	side:   Side,
	share:  f32, // Edge, Split: the pane's share of the split; 0 for half
}

// A pane that left the layout: an empty frame shrinking and fading out.
Leaving :: struct {
	id:   u32,
	rect: gfx.Rect, // where it ends
}

Panes :: struct {
	open:        [dynamic]^Pane, // every open pane, in opening order
	root:        ^Tile,          // nil when nothing is shown
	focused:     ^Pane,          // gets the keyboard: a shown pane, or nil
	last_editor: ^Pane,          // the editor focused last, where files open
	maximized:   ^Pane,          // fills the work area, over the others
	next_id:     u32,
	leaving:     [dynamic]Leaving,
	drag:        struct {
		pane:    ^Pane,  // &incoming for a file not open yet
		file:    string, // owned; that file
		from:    [2]f32, // where the press was
		source:  enum {
			Title,
			Shelf, // a click shows the pane
			Tree,  // a click opens the file
		},
		active:  bool, // moved past DRAG_THRESHOLD
		drop:    Drop,
		preview: gfx.Rect,
	},
	divider:     struct {
		tile: ^Tile, // the split whose divider is being dragged
		grab: f32,   // pointer offset from the divider when the drag began
	},
}

// Stands for a file dragged from the tree before it is opened.
@(private = "file")
incoming: Pane

pane_id :: proc(p: ^Pane) -> clay.ElementId {
	return clay.ID("Pane", p.id)
}

@(private = "file")
body_id :: proc(p: ^Pane) -> clay.ElementId {
	return clay.ID("PaneBody", p.id)
}

// --- Queries ---------------------------------------------------------------------

pane_shown :: proc(p: ^Pane) -> bool {
	return tile_find(g.panes.root, p) != nil
}

// Shown, and not under a maximized pane.
pane_live :: proc(p: ^Pane) -> bool {
	m := g.panes.maximized
	return p.visible && (m == nil || m == p)
}

focused_editor :: proc() -> ^Editor {
	if p := g.panes.focused; p != nil {
		if e, ok := p.content.(^Editor); ok do return e
	}
	return nil
}

focused_terminal :: proc() -> ^Terminal {
	if p := g.panes.focused; p != nil {
		if t, ok := p.content.(^Terminal); ok do return t
	}
	return nil
}

// The focused editor, else the one focused last if still shown.
active_editor :: proc() -> ^Editor {
	if e := focused_editor(); e != nil do return e
	if p := g.panes.last_editor; p != nil && pane_shown(p) do return p.content.(^Editor)
	return nil
}

@(private = "file")
is_terminal :: proc(p: ^Pane) -> bool {
	_, ok := p.content.(^Terminal)
	return ok
}

@(private = "file")
is_editor :: proc(p: ^Pane) -> bool {
	_, ok := p.content.(^Editor)
	return ok
}

pane_with_file :: proc(path: string) -> ^Pane {
	for p in g.panes.open {
		if e, ok := p.content.(^Editor); ok && e.path == path do return p
	}
	return nil
}

pane_title :: proc(p: ^Pane) -> string {
	switch c in p.content {
	case ^Editor:
		return filepath.base(c.path)
	case ^Terminal:
		if p.name != "" do return p.name
		name := terminal_title(c)
		return p.number > 1 ? fmt.tprintf("%s %d", name, p.number) : name
	}
	return ""
}

pane_icon :: proc(p: ^Pane) -> gfx.Icon {
	switch c in p.content {
	case ^Editor:   return file_icon(c.path)
	case ^Terminal: return .Terminal
	}
	return .File_Text
}

@(private = "file")
file_icon :: proc(path: string) -> gfx.Icon {
	ext := filepath.ext(path)
	return is_markdown_path(path) || strings.equal_fold(ext, ".txt") || ext == "" ? .File_Text : .File_Code
}

pane_modified :: proc(p: ^Pane) -> bool {
	e, ok := p.content.(^Editor)
	return ok && editor_is_modified(e)
}

// Whether every shown editor is ready to be drawn (see Editor.shown).
panes_ready :: proc() -> bool {
	for p in g.panes.open {
		if e, ok := p.content.(^Editor); ok && p.visible && e.status == .Text && !e.shown do return false
	}
	return true
}

// --- Opening and closing ---------------------------------------------------------

@(private = "file")
pane_add :: proc(content: Pane_Content) -> ^Pane {
	ps := &g.panes
	ps.next_id += 1
	p := new(Pane)
	p^ = {id = ps.next_id, content = content, fade_in = true}
	if _, ok := content.(^Terminal); ok do p.number = next_terminal_number()
	append(&ps.open, p)
	return p
}

// The lowest number no open terminal has.
@(private = "file")
next_terminal_number :: proc() -> int {
	n := 1
	outer: for {
		for p in g.panes.open {
			if is_terminal(p) && p.number == n {
				n += 1
				continue outer
			}
		}
		return n
	}
}

// Opens a file, or finds the pane it is open in, shows it and focuses it.
panes_open_file :: proc(path: string) -> ^Pane {
	p := pane_for_file(path)
	pane_show(p)
	workspace_reveal(&g.workspace, path)
	return p
}

// The pane a file is open in, opening it (not shown) if it isn't.
pane_for_file :: proc(path: string) -> ^Pane {
	if p := pane_with_file(path); p != nil do return p
	e := new(Editor)
	editor_open(e, path)
	return pane_add(e)
}

// Starts a terminal on the shelf; its shell starts once it is shown.
panes_add_terminal :: proc() -> ^Pane {
	t := new(Terminal)
	terminal_init(t)
	return pane_add(t)
}

// Focuses the maximized pane, else the editor focused last if shown, else the
// first shown pane, or nothing.
panes_focus_any :: proc() {
	ps := &g.panes
	ps.focused = nil
	if ps.maximized != nil {
		pane_focus(ps.maximized)
		return
	}
	if p := ps.last_editor; p != nil && pane_shown(p) {
		ps.focused = p
		return
	}
	for q in ps.open {
		if pane_shown(q) {
			pane_focus(q)
			return
		}
	}
}

// Starts a terminal, shown beside the one in use or under the other panes.
panes_new_terminal :: proc() -> ^Pane {
	p := panes_add_terminal()
	pane_show(p)
	return p
}

// Shows a pane (where its kind goes, if it is only on the shelf) and focuses it.
pane_show :: proc(p: ^Pane) {
	if !pane_shown(p) do pane_move(p, place_for(p))
	pane_focus(p)
}

// Where a pane from the shelf goes: a file in place of the editor in use, else
// above the rest; a terminal beside the terminal in use, else under the rest.
@(private = "file")
place_for :: proc(p: ^Pane) -> Drop {
	ps := &g.panes
	if ps.root == nil do return {kind = .Fill}
	candidates := [?]^Pane{ps.focused, ps.last_editor}
	if is_editor(p) {
		for q in candidates do if q != nil && is_editor(q) && pane_shown(q) do return {kind = .Swap, target = q}
		return {kind = .Edge, side = .Top, share = 0.65}
	}
	if q := ps.focused; q != nil && is_terminal(q) do return {kind = .Split, target = q, side = .Right}
	for q in ps.open do if q != p && is_terminal(q) && pane_shown(q) do return {kind = .Split, target = q, side = .Right}
	return {kind = .Edge, side = .Bottom, share = 0.35}
}

// Moves a pane where `d` says, in the layout or out of it. A file that loses its
// place to it closes, unless it has unsaved changes.
pane_move :: proc(p: ^Pane, d: Drop) {
	ps := &g.panes
	if d.kind == .None do return
	if d.kind == .Shelf {
		if p.visible do append(&ps.leaving, Leaving{p.id, shrink(p.rect)})
	} else {
		forget_leaving(p.id)
		p.fade_in = d.kind != .Swap
	}
	drop_apply(&ps.root, p, d)
	tree_changed()
	if q := d.target; d.kind == .Swap && q != p && is_editor(q) && !pane_shown(q) && !pane_modified(q) {
		pane_close(q, ask = false)
	}
}

pane_hide :: proc(p: ^Pane) {
	pane_move(p, {kind = .Shelf})
}

// Focuses a pane; a maximized pane that would cover it is restored.
pane_focus :: proc(p: ^Pane) {
	ps := &g.panes
	if p != nil && ps.maximized != nil && ps.maximized != p do ps.maximized = nil
	ps.focused = p
	if p != nil && is_editor(p) do ps.last_editor = p
}

// Closes a pane: a file or a terminal and its shell. A file with unsaved
// changes is asked about first (unless `ask` is false) and closes once
// answered; returns false then.
pane_close :: proc(p: ^Pane, ask := true) -> bool {
	ps := &g.panes
	if ask && pane_modified(p) {
		resolve_unsaved({p}, Closing_Pane(p))
		return false
	}
	if pane_shown(p) do pane_hide(p)
	for q, i in ps.open {
		if q == p {
			ordered_remove(&ps.open, i)
			break
		}
	}
	if ps.last_editor == p do ps.last_editor = nil
	if ps.drag.pane == p do drag_clear()
	if g.rename.pane == p do rename_end()
	if g.menu.pane == p do menu_close()
	if op, ok := g.pending.(Pane_Op); ok && op.pane == p do g.pending = nil
	switch c in p.content {
	case ^Editor:
		editor_destroy(c)
		free(c)
	case ^Terminal:
		terminal_destroy(c)
		free(c)
	}
	delete(p.name)
	free(p)
	return true
}

panes_destroy :: proc() {
	ps := &g.panes
	for len(ps.open) > 0 do pane_close(ps.open[len(ps.open) - 1], ask = false)
	drag_clear()
	delete(ps.open)
	delete(ps.leaving)
	ps^ = {}
}

// After any change to the tree: what pointed into it, or relied on a pane being
// shown, is updated.
@(private = "file")
tree_changed :: proc() {
	ps := &g.panes
	ps.divider.tile = nil
	if ps.maximized != nil && !pane_shown(ps.maximized) do ps.maximized = nil
	if ps.focused != nil && !pane_shown(ps.focused) do panes_focus_any()
}

@(private = "file")
forget_leaving :: proc(id: u32) {
	ps := &g.panes
	for i := len(ps.leaving) - 1; i >= 0; i -= 1 do if ps.leaving[i].id == id do unordered_remove(&ps.leaving, i)
}

@(private = "file")
shrink :: proc(r: gfx.Rect) -> gfx.Rect {
	dx, dy := math.round(r.w * 0.04), math.round(r.h * 0.04)
	return {r.x + dx, r.y + dy, r.w - 2 * dx, r.h - 2 * dy}
}

// --- Commands ----------------------------------------------------------------------

// Focuses a shown terminal; hides the focused one; or shows the newest terminal
// on the shelf, starting one if there is none.
terminal_toggle :: proc() {
	ps := &g.panes
	if p := ps.focused; p != nil && is_terminal(p) {
		pane_hide(p)
		return
	}
	for p in ps.open {
		if is_terminal(p) && pane_shown(p) {
			pane_focus(p)
			return
		}
	}
	for i := len(ps.open) - 1; i >= 0; i -= 1 {
		if is_terminal(ps.open[i]) {
			pane_show(ps.open[i])
			return
		}
	}
	panes_new_terminal()
}

pane_toggle_maximized :: proc() {
	ps := &g.panes
	if ps.focused == nil do return
	ps.maximized = ps.maximized == ps.focused ? nil : ps.focused
}

// Focuses the next shown pane in layout order (and maximizes it in place of a
// maximized one).
pane_focus_next :: proc() {
	ps := &g.panes
	shown := make([dynamic]^Pane, context.temp_allocator)
	collect :: proc(t: ^Tile, out: ^[dynamic]^Pane) {
		if t == nil do return
		if t.pane != nil {
			append(out, t.pane)
			return
		}
		collect(t.children[0], out)
		collect(t.children[1], out)
	}
	collect(ps.root, &shown)
	if len(shown) == 0 do return
	next := shown[0]
	for p, i in shown do if p == ps.focused do next = shown[(i + 1) % len(shown)]
	if ps.maximized != nil do ps.maximized = next
	pane_focus(next)
}

// --- The split tree ----------------------------------------------------------------

// The leaf showing p.
tile_find :: proc(t: ^Tile, p: ^Pane) -> ^Tile {
	if t == nil do return nil
	if t.pane != nil do return t.pane == p ? t : nil
	if found := tile_find(t.children[0], p); found != nil do return found
	return tile_find(t.children[1], p)
}

// The leaf whose last rect holds `pos`.
@(private = "file")
tile_at :: proc(t: ^Tile, pos: [2]f32) -> ^Tile {
	if t == nil || !gfx.rect_contains(t.rect, pos) do return nil
	if t.pane != nil do return t
	if found := tile_at(t.children[0], pos); found != nil do return found
	return tile_at(t.children[1], pos)
}

// Sets each tile's rect, splitting `r` down the tree.
@(private)
layout_tile :: proc(t: ^Tile, r: gfx.Rect) {
	if t == nil do return
	t.rect = r
	if t.pane != nil do return
	a, b := split_rects(t, r)
	layout_tile(t.children[0], a)
	layout_tile(t.children[1], b)
}

@(private = "file")
split_rects :: proc(t: ^Tile, r: gfx.Rect) -> (a, b: gfx.Rect) {
	if t.axis == .Row {
		w := max(r.w - PANE_GAP, 0)
		aw := math.round(w * t.ratio)
		return {r.x, r.y, aw, r.h}, {r.x + aw + PANE_GAP, r.y, w - aw, r.h}
	}
	h := max(r.h - PANE_GAP, 0)
	ah := math.round(h * t.ratio)
	return {r.x, r.y, r.w, ah}, {r.x, r.y + ah + PANE_GAP, r.w, h - ah}
}

// Puts `with` where `t` is in its parent (or at the root).
@(private = "file")
tile_replace :: proc(root: ^^Tile, t, with: ^Tile) {
	parent := t.parent
	with.parent = parent
	if parent == nil {
		root^ = with
	} else {
		parent.children[parent.children[0] == t ? 0 : 1] = with
	}
}

// Takes p's leaf out; its sibling takes the place of their split.
@(private = "file")
tree_remove :: proc(root: ^^Tile, p: ^Pane) {
	leaf := tile_find(root^, p)
	if leaf == nil do return
	split := leaf.parent
	if split == nil {
		root^ = nil
	} else {
		tile_replace(root, split, split.children[0] == leaf ? split.children[1] : split.children[0])
		free(split)
	}
	free(leaf)
}

// Splits `t` (a leaf, or any subtree), putting a new leaf for p at `side` with
// `share` of the space.
@(private = "file")
tree_split :: proc(root: ^^Tile, t: ^Tile, p: ^Pane, side: Side, share: f32) {
	leaf := new(Tile)
	leaf.pane = p
	split := new(Tile)
	tile_replace(root, t, split)
	first := side == .Left || side == .Top
	split.axis = side == .Left || side == .Right ? .Row : .Column
	split.ratio = first ? share : 1 - share
	split.children = first ? {leaf, t} : {t, leaf}
	leaf.parent, t.parent = split, split
}

// Applies a drop to the tree at `root`. Allocates and frees tiles with
// context.allocator; a preview runs it on a copy in the temp allocator.
@(private)
drop_apply :: proc(root: ^^Tile, p: ^Pane, d: Drop) {
	share := d.share > 0 ? d.share : 0.5
	switch d.kind {
	case .None:
	case .Shelf:
		tree_remove(root, p)
	case .Fill:
		tree_remove(root, p)
		if root^ == nil {
			root^ = new(Tile)
			root^.pane = p
		}
	case .Swap:
		target := tile_find(root^, d.target)
		if target == nil || d.target == p do return
		if own := tile_find(root^, p); own != nil do own.pane = d.target
		target.pane = p
	case .Edge, .Split:
		if d.kind == .Split && (d.target == p || tile_find(root^, d.target) == nil) do return
		tree_remove(root, p)
		t := d.kind == .Split ? tile_find(root^, d.target) : root^
		if t == nil {
			root^ = new(Tile)
			root^.pane = p
			return
		}
		tree_split(root, t, p, d.side, share)
	}
}

@(private = "file")
tree_clone :: proc(t: ^Tile, parent: ^Tile) -> ^Tile {
	if t == nil do return nil
	c := new_clone(t^)
	c.parent = parent
	if t.pane == nil {
		c.children[0] = tree_clone(t.children[0], c)
		c.children[1] = tree_clone(t.children[1], c)
	}
	return c
}

// Where p would be after drop `d`.
@(private = "file")
drop_rect :: proc(p: ^Pane, d: Drop) -> gfx.Rect {
	context.allocator = context.temp_allocator
	root := tree_clone(g.panes.root, nil)
	drop_apply(&root, p, d)
	layout_tile(root, work_rect())
	leaf := tile_find(root, p)
	return leaf != nil ? leaf.rect : {}
}

// The area panes fill: the window above the status bar, beside the sidebar.
work_rect :: proc() -> gfx.Rect {
	x: f32 = PANE_GAP
	if g.sidebar_visible do x += SIDEBAR_WIDTH + PANE_GAP
	h := f32(g.window_h) - STATUSBAR_HEIGHT
	return {x, PANE_GAP, max(f32(g.window_w) - x - PANE_GAP, 0), max(h - 2 * PANE_GAP, 0)}
}

// --- Per frame -----------------------------------------------------------------------

// Before layout: divider and pane drags, then each pane's own frame. Terminals
// on the shelf keep reading their shell's output.
panes_frame :: proc() {
	ps := &g.panes
	interactive := ui_interactive()
	divider_mouse(interactive)
	drag_mouse(interactive)
	busy := ps.divider.tile != nil || ps.drag.active
	for p in ps.open {
		live := interactive && pane_live(p) && !busy
		switch c in p.content {
		case ^Editor:   if p.visible do editor_frame(c, body_id(p), live)
		case ^Terminal: terminal_frame(c, body_id(p), p.visible, live)
		}
	}
}

panes_busy :: proc() -> bool {
	ps := &g.panes
	if ps.divider.tile != nil || ps.drag.pane != nil do return true
	for p in ps.open {
		switch c in p.content {
		case ^Editor:   if p.visible && editor_busy(c) do return true
		case ^Terminal: if c.busy do return true
		}
	}
	return false
}

// A press in a pane focuses it.
update_focus :: proc() {
	if !g.mouse_pressed || !ui_interactive() do return
	for p in g.panes.open {
		if pane_live(p) && pointer_in(pane_id(p)) {
			pane_focus(p)
			return
		}
	}
}

// The split whose divider (the gap between its children) is at `pos`.
divider_at :: proc(t: ^Tile, pos: [2]f32) -> ^Tile {
	if t == nil || t.pane != nil || g.panes.maximized != nil do return nil
	a := t.children[0].rect
	GRAB :: 2 // beyond the gap on each side
	r: gfx.Rect
	if t.axis == .Row {
		r = {a.x + a.w - GRAB, t.rect.y, PANE_GAP + 2 * GRAB, t.rect.h}
	} else {
		r = {t.rect.x, a.y + a.h - GRAB, t.rect.w, PANE_GAP + 2 * GRAB}
	}
	if gfx.rect_contains(r, pos) do return t
	if found := divider_at(t.children[0], pos); found != nil do return found
	return divider_at(t.children[1], pos)
}

@(private = "file")
divider_mouse :: proc(interactive: bool) {
	ps := &g.panes
	dv := &ps.divider
	if g.mouse_pressed && interactive && ps.drag.pane == nil {
		if t := divider_at(ps.root, g.mouse_pos); t != nil {
			a := t.children[0].rect
			dv.tile = t
			dv.grab = t.axis == .Row ? g.mouse_pos.x - (a.x + a.w) : g.mouse_pos.y - (a.y + a.h)
		}
	}
	if !g.mouse_down do dv.tile = nil
	t := dv.tile
	if t == nil do return
	r := t.rect
	horizontal := t.axis == .Row
	span := (horizontal ? r.w : r.h) - PANE_GAP
	if span <= 0 do return
	at := (horizontal ? g.mouse_pos.x - r.x : g.mouse_pos.y - r.y) - dv.grab
	lo := min(PANE_MIN_SIZE / span, 0.5)
	t.ratio = clamp(at / span, lo, 1 - lo)
}

// Pressing a pane's title, a shelf row or a file in the tree, and dragging it
// to a drop. A press that doesn't move is a click.
@(private = "file")
drag_mouse :: proc(interactive: bool) {
	ps := &g.panes
	d := &ps.drag
	if d.pane == nil && g.mouse_pressed && interactive && ps.divider.tile == nil do drag_press()
	if d.pane == nil do return
	if !g.mouse_down {
		switch {
		case d.active && d.drop.kind != .None:
			p := d.pane == &incoming ? pane_for_file(d.file) : d.pane
			pane_move(p, d.drop)
			if d.drop.kind != .Shelf do pane_focus(p)
		case d.active:
		case d.source == .Shelf:
			pane_show(d.pane)
		case d.source == .Tree:
			if d.pane == &incoming do panes_open_file(d.file)
			else do pane_show(d.pane)
		}
		drag_clear()
		return
	}
	if !d.active {
		m := g.mouse_pos - d.from
		if abs(m.x) + abs(m.y) < DRAG_THRESHOLD do return
		d.active = true
		ps.maximized = nil
	}
	d.drop = drop_at(d.pane, g.mouse_pos)
	#partial switch d.drop.kind {
	case .None:
	case .Shelf:
		d.preview, _ = element_rect(clay.ID("Shelf"))
	case:
		d.preview = drop_rect(d.pane, d.drop)
	}
}

@(private = "file")
drag_press :: proc() {
	ps := &g.panes
	d := &ps.drag
	if g.rename.active && pointer_in(clay.ID("RenameField")) do return
	for p in ps.open {
		if pane_live(p) && pointer_in(clay.ID("PaneTitle", p.id)) {
			if g.mouse_clicks == 2 {
				pane_focus(p)
				pane_toggle_maximized()
				return
			}
			d^ = {pane = p, from = g.mouse_pos}
			return
		}
		if g.sidebar_visible && pointer_in(clay.ID("ShelfRow", p.id)) && pointer_in(clay.ID("ShelfList")) && !pointer_in(clay.ID("ShelfClose", p.id)) {
			d^ = {pane = p, from = g.mouse_pos, source = .Shelf}
			return
		}
	}
	index, on_row := tree_row_under_pointer()
	if !on_row || g.workspace.nodes[index].is_dir do return
	path := g.workspace.nodes[index].path
	if p := pane_with_file(path); p != nil {
		d^ = {pane = p, from = g.mouse_pos, source = .Tree}
	} else {
		incoming = {}
		d^ = {pane = &incoming, file = strings.clone(path), from = g.mouse_pos, source = .Tree}
	}
}

// Ends a drag, or the press that might have started one.
drag_clear :: proc() {
	d := &g.panes.drag
	delete(d.file)
	d^ = {}
}

// What dropping p at `pos` does.
@(private = "file")
drop_at :: proc(p: ^Pane, pos: [2]f32) -> Drop {
	ps := &g.panes
	if g.sidebar_visible && pointer_in(clay.ID("Sidebar")) {
		return is_terminal(p) && pane_shown(p) ? {kind = .Shelf} : {}
	}
	work := work_rect()
	if !gfx.rect_contains(work, pos) do return {}
	if ps.root == nil do return {kind = .Fill}
	if ps.root.pane == p do return {} // the only pane
	near := min(pos.x - work.x, work.x + work.w - pos.x, pos.y - work.y, work.y + work.h - pos.y)
	if near < EDGE_ZONE do return {kind = .Edge, side = nearest_side(work, pos)}
	leaf := tile_at(ps.root, pos)
	if leaf == nil || leaf.pane == p do return {}
	r := leaf.rect
	side := nearest_side(r, pos)
	inside := min((pos.x - r.x) / r.w, (r.x + r.w - pos.x) / r.w, (pos.y - r.y) / r.h, (r.y + r.h - pos.y) / r.h)
	if inside > CENTER_ZONE do return {kind = .Swap, target = leaf.pane}
	return {kind = .Split, target = leaf.pane, side = side}
}

// The side of `r` nearest `pos`, relative to r's size.
@(private = "file")
nearest_side :: proc(r: gfx.Rect, pos: [2]f32) -> Side {
	d := [Side]f32 {
		.Left   = (pos.x - r.x) / r.w,
		.Right  = (r.x + r.w - pos.x) / r.w,
		.Top    = (pos.y - r.y) / r.h,
		.Bottom = (r.y + r.h - pos.y) / r.h,
	}
	best := Side.Left
	for s in Side do if d[s] < d[best] do best = s
	return best
}

// --- UI --------------------------------------------------------------------------------

// The panes, as floating children of the element being declared ("Main").
panes_ui :: proc() {
	ps := &g.panes
	work := work_rect()
	layout_tile(ps.root, work)
	// The maximized pane grows over the others, which go once it covers them.
	covered := ps.maximized != nil && element_at(pane_id(ps.maximized), work)
	for i := len(ps.leaving) - 1; i >= 0; i -= 1 {
		l := ps.leaving[i]
		if element_at(clay.ID("Pane", l.id), l.rect) do unordered_remove(&ps.leaving, i)
	}
	for l in ps.leaving do leaving_pane(l)
	if ps.root == nil do empty_work(work)
	for p in ps.open {
		p.visible = false
		leaf := tile_find(ps.root, p)
		if leaf == nil || (covered && p != ps.maximized) do continue
		p.rect = p == ps.maximized ? work : leaf.rect
		p.visible = true
		pane_element(p)
	}
	drag_ui()
}

// Panes ease to their places, except while a divider is dragged.
@(private = "file")
pane_transition :: proc(p: ^Pane) -> clay.TransitionElementConfig {
	props := clay.TransitionPropertyBoundingBox + {.OverlayColor, .BorderColor}
	config := transition(props, p != nil && p.fade_in ? .Fade : .None)
	config.handler = pane_ease
	return config
}

@(private = "file")
pane_ease :: proc "c" (args: clay.TransitionCallbackArguments) -> bool {
	if g.panes.divider.tile != nil {
		args.current^ = args.target
		return true
	}
	done := clay.EaseOut(args)
	if !done do g.animating = true
	return done
}

// The overlay a pane rests at: the window color, clear. Faded in from opaque.
@(private = "file")
window_overlay :: proc(alpha: f32 = 0) -> clay.Color {
	c := gfx.theme.panel
	c.a = alpha
	return c
}

@(private = "file")
pane_element :: proc(p: ^Pane) {
	ps := &g.panes
	r := p.rect
	focused := p == ps.focused
	dragged := ps.drag.active && ps.drag.pane == p
	// The focused pane is outlined, unless it is the only one in view.
	border := gfx.theme.border
	alone := ps.maximized != nil || (ps.root != nil && ps.root.pane != nil)
	if focused && !alone {
		border = gfx.theme.accent
		border.a = 70
	}
	if clay.UI(pane_id(p))({
		layout = {
			sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)},
			layoutDirection = .TopToBottom,
			padding = {left = 1, right = 1, top = 1, bottom = PANE_RADIUS / 2},
		},
		backgroundColor = gfx.theme.bg,
		overlayColor = window_overlay(dragged ? 150 : 0),
		cornerRadius = clay.CornerRadiusAll(PANE_RADIUS),
		border = {color = border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Parent, offset = {r.x, r.y}, zIndex = p == ps.maximized ? 3 : 2},
		transition = pane_transition(p),
	}) {
		pane_header(p, focused)
		switch c in p.content {
		case ^Editor:
			switch c.status {
			case .Text:   custom_element(body_id(p), c)
			case .Error:  centered_message("Could not read file")
			case .Binary: centered_message("Binary file not shown")
			case .None:
			}
		case ^Terminal:
			custom_element(body_id(p), c)
		}
	}
}

// Icon and title (the handle to drag the pane by), then the pane's buttons.
@(private = "file")
pane_header :: proc(p: ^Pane, focused: bool) {
	ps := &g.panes
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(PANE_HEADER_HEIGHT)}, padding = {left = 10, right = 4}, childGap = 2, childAlignment = {y = .Center}},
	}) {
		title := clay.ID("PaneTitle", p.id)
		if clay.UI(title)({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = 6, childAlignment = {y = .Center}},
			clip = {horizontal = true},
		}) {
			icon(pane_icon(p), focused ? gfx.theme.accent : gfx.theme.text_dim, 14)
			if renaming(.Title, pane = p) {
				rename_field(FONT_SIZE_SMALL)
			} else {
				label(pane_title(p), focused ? gfx.theme.text : gfx.theme.text_dim, FONT_SIZE_SMALL)
				if pane_modified(p) do label("•", gfx.theme.text_dim, FONT_SIZE_SMALL)
			}
		}
		if e, ok := p.content.(^Editor); ok do tooltip(title, relative_to_root(e.path))
		if t, ok := p.content.(^Terminal); ok {
			if icon_button(clay.ID("PaneRestart", p.id), .Restart, 22, 14, "Restart shell") {
				terminal_restart(t)
				pane_focus(p)
			}
		}
		maximized := p == ps.maximized
		if icon_button(clay.ID("PaneMaximize", p.id), maximized ? .Restore : .Maximize, 22, 14, maximized ? "Restore" : "Maximize", first_chord_label(.Maximize_Pane)) {
			defer_action(Pane_Op{p, .Maximize})
		}
		if is_terminal(p) && icon_button(clay.ID("PaneHide", p.id), .Minus, 22, 14, "Put on the shelf") {
			defer_action(Pane_Op{p, .Hide})
		}
		if icon_button(clay.ID("PaneClose", p.id), .Close, 22, 14, "Close", first_chord_label(.Close_Pane)) {
			defer_action(Pane_Op{p, .Close})
		}
	}
}

@(private = "file")
centered_message :: proc(s: string) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}}}) {
		label(s, gfx.theme.text_dim)
	}
}

// What the work area says while no pane is shown.
@(private = "file")
empty_work :: proc(r: gfx.Rect) {
	if clay.UI(clay.ID("EmptyWork"))({
		layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}, childAlignment = {x = .Center, y = .Center}},
		floating = {attachTo = .Parent, offset = {r.x, r.y}, zIndex = 1, pointerCaptureMode = .Passthrough},
	}) {
		label(fmt.tprintf("Select a file in the explorer, or press %s", first_chord_label(.Find_File)), gfx.theme.text_dim)
	}
}

// A pane that left: its frame, empty, shrinking and fading into the window.
@(private = "file")
leaving_pane :: proc(l: Leaving) {
	r := l.rect
	if clay.UI(clay.ID("Pane", l.id))({
		layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}},
		backgroundColor = gfx.theme.bg,
		overlayColor = window_overlay(255),
		cornerRadius = clay.CornerRadiusAll(PANE_RADIUS),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Parent, offset = {r.x, r.y}, zIndex = 1, pointerCaptureMode = .Passthrough},
		transition = pane_transition(nil),
	}) {}
}

// While dragging: where the pane would go, easing between places, and its title
// under the pointer.
@(private = "file")
drag_ui :: proc() {
	d := &g.panes.drag
	if !d.active do return
	if d.drop.kind != .None {
		r := d.preview
		fill, edge := gfx.theme.accent, gfx.theme.accent
		fill.a, edge.a = 40, 200
		if clay.UI(clay.ID("DropPreview"))({
			layout = {sizing = {clay.SizingFixed(r.w), clay.SizingFixed(r.h)}},
			backgroundColor = fill,
			cornerRadius = clay.CornerRadiusAll(PANE_RADIUS),
			border = {color = edge, width = clay.BorderOutside(2)},
			floating = {attachTo = .Parent, offset = {r.x, r.y}, zIndex = 40, pointerCaptureMode = .Passthrough},
			transition = transition(clay.TransitionPropertyBoundingBox),
		}) {}
	}
	if clay.UI(clay.ID("DragChip"))({
		layout = {padding = {left = 8, right = 10, top = 4, bottom = 4}, childGap = 6, childAlignment = {y = .Center}},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Root, offset = g.mouse_pos + {14, 12}, zIndex = 50, pointerCaptureMode = .Passthrough},
	}) {
		file := d.pane == &incoming
		icon(file ? file_icon(d.file) : pane_icon(d.pane), gfx.theme.accent, 14)
		label(file ? filepath.base(d.file) : pane_title(d.pane), gfx.theme.text, FONT_SIZE_SMALL)
	}
}

// --- Shelf -------------------------------------------------------------------------------

@(private = "file")
SHELF_ROW_HEIGHT :: 24

// The terminals, under the file tree. A click shows one; a drag places it.
shelf :: proc(max_height: f32) {
	if clay.UI(clay.ID("Shelf"))({
		layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = {top = 4}},
		border = {color = gfx.theme.border, width = {top = 1}},
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(26)}, padding = {left = 12, right = 6}, childAlignment = {y = .Center}},
		}) {
			label("TERMINALS", gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
			push_right()
			if icon_button(clay.ID("NewTerminal"), .Plus, 20, 14, "New terminal", first_chord_label(.New_Terminal)) {
				defer_action(Run_Command(.New_Terminal))
			}
		}
		list := clay.ID("ShelfList")
		wheel_scroll_list(list)
		if clay.UI(list)({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFit({max = max_height})}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			any := false
			for p in g.panes.open {
				if !is_terminal(p) do continue
				shelf_row(p, list)
				any = true
			}
			if !any {
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, padding = {left = 12, right = 12, top = 2, bottom = 6}}}) {
					paragraph("No terminals open", gfx.theme.text_faint)
				}
			}
		}
	}
}

@(private = "file")
shelf_row :: proc(p: ^Pane, list: clay.ElementId) {
	id := clay.ID("ShelfRow", p.id)
	shown := pane_shown(p)
	if list_row(id, p == g.panes.focused, SHELF_ROW_HEIGHT, 8, 7) {
		hovered := clay.Hovered()
		icon(pane_icon(p), shown ? gfx.theme.accent : gfx.theme.text_faint, 14)
		if renaming(.Shelf, pane = p) {
			rename_field(FONT_SIZE_SIDEBAR)
		} else if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}, clip = {horizontal = true}}) {
			label(pane_title(p), shown ? gfx.theme.text : gfx.theme.text_dim, FONT_SIZE_SIDEBAR)
		}
		if hovered {
			if icon_button(clay.ID("ShelfClose", p.id), .Close, 18, 13, "Close") do defer_action(Pane_Op{p, .Close})
		}
	}
}
