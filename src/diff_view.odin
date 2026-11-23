package editor

// A diff pane: two versions of a file side by side, the old on the left and the
// new on the right (diff_load.odin builds them). Rows pair the lines both have,
// a hunk's changed lines, and filler where one side has more; added and
// removed lines are shaded, and what changed within a changed line more so.
// Both sides scroll together; only the rows in view are drawn, so a huge file
// costs no more than a small one. Markdown shows as plain text.
//
// Between the sides each hunk has buttons: the arrow reverts the hunk to the
// left side's text (in the open editor as one undo step, left unsaved, or in
// the file on disk on the writer thread if it is unchanged), and in a diff of
// changes, + stages it. In a diff of staged changes the arrow unstages it. The
// view follows the file: a new status (git_frame) or the open editor's edits
// load it again, which changes nothing when its versions are the same

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"
import "buffer"
import "diff"
import "git"
import "gfx"
import "syntax"
import "textedit"
import "uitime"


DIFF_GUTTER      :: 52  // between the sides, for each hunk's buttons
DIFF_TOOLBAR     :: 30
DIFF_BUTTON      :: 20
DIFF_EDIT_DELAY  :: 150 * time.Millisecond // typing rests this long before the diff follows
DIFF_TEXT_MARGIN :: 8   // between the line numbers and the text
DIFF_MIN_WIDTH   :: 280 // a narrower pane cuts the diff off at its edge

Diff_Status :: enum u8 {
	Loading,
	Ready,
	Binary,
	Error,
}

Diff_Pane_Side :: enum u8 {
	Left,
	Right,
}

// What a side's custom element draws
Diff_Draw :: struct {
	view: ^Diff_View,
	side: Diff_Pane_Side,
}

// A hunk button pressed, applied at the start of the next frame
Hunk_Action :: struct {
	kind: enum u8 {
		Revert,  // to the left side's text
		Stage,   // into the index
		Unstage, // out of the index (the staged diff's revert)
	},
	hunk: int,
}

Diff_View :: struct {
	id:          u64,    // for the loader; never reused
	path:        string, // owned; the file's full path
	rel:         string, // owned; relative to the work tree, once it is known
	area:        git.Area,

	// What is shown, from the loader
	status:      Diff_Status,
	problem:     string, // owned; why it couldn't load
	signature:   Diff_Signature,
	left:        Diff_Side,
	right:       Diff_Side,
	rows:        diff.Rows,
	left_words:  []Word_Span,
	right_words: []Word_Span,
	right_size:  int, // the file on disk as read, for a revert written there
	right_hash:  u64,
	added:       int, // lines
	removed:     int,

	// Following the file
	loads:       u64,       // loads asked for
	serial:      u64,       // the load waited for, 0 for none
	stale:       bool,      // a load is due
	opened_at:   u64,       // ticks, for the loading message
	seen:        u64,       // the open editor's buffer version last looked at
	edited_at:   time.Tick, // when it changed, until the load it causes
	clicked:     Maybe(Hunk_Action),

	// The view, in logical pixels
	zoom:        int,
	scroll_y:    f64,
	target_y:    f64,
	scroll_x:    f32,
	widest:      int, // columns of the widest line shown since it loaded
	char_w:      f32,
	areas:       [Diff_Pane_Side]gfx.Rect, // each side's, from the last layout
	scroll_drag: [gfx.Axis]Maybe(f32),
}

@(private = "file")
next_view_id: u64

@(private = "file")
next_patch_id: u64


// --- Opening -----------------------------------------------------------------------

// Shows a file (its full path) of one of the Git pane's areas, loading once
// the workspace's repository is known. The view keeps its zoom
diff_view_open :: proc(dv: ^Diff_View, path: string, area: git.Area) {
	diff_view_close(dv)
	next_view_id += 1

	dv.id = next_view_id
	dv.path = strings.clone(path)
	dv.area = area
	dv.status = .Loading
	dv.stale = true
	dv.opened_at = sdl.GetTicksNS()
}


// Frees what the view shows; it can be opened again
diff_view_close :: proc(dv: ^Diff_View) {
	delete(dv.rel)
	delete(dv.path)
	delete(dv.problem)
	drop_shown(dv)

	zoom := dv.zoom
	dv^ = {}
	dv.zoom = zoom
}


// Lets go of the sides shown, which the loader thread frees
@(private = "file")
drop_shown :: proc(dv: ^Diff_View) {
	old := Diff_Result {
		left        = dv.left,
		right       = dv.right,
		rows        = dv.rows,
		left_words  = dv.left_words,
		right_words = dv.right_words,
	}
	diff_load_retire(old)

	dv.left, dv.right, dv.rows = {}, {}, {}
	dv.left_words, dv.right_words = nil, nil
}


// Whether a view shows this file (full path) of this area
diff_view_is :: proc(dv: ^Diff_View, path: string, area: git.Area) -> bool {
	return same_path(dv.path, path) && dv.area == area
}


// The pane's title: the file's name and what it compares
diff_view_title :: proc(dv: ^Diff_View) -> string {
	return fmt.tprintf("%s (%s)", filepath.base(dv.path), DIFF_AREA_NAMES[dv.area])
}


// What each area's diff is called: in titles and in the session
DIFF_AREA_NAMES := [git.Area]string {
	.Conflicts = "conflict",
	.Staged    = "staged",
	.Changes   = "changes",
	.Untracked = "new",
}


// The area a name in DIFF_AREA_NAMES is of
diff_area_named :: proc(name: string) -> (area: git.Area, ok: bool) {
	for n, a in DIFF_AREA_NAMES {
		if n == name do return a, true
	}
	return
}


// --- Following the file ------------------------------------------------------------

// A new status: every diff view loads again (unchanged versions cost nothing)
diff_views_follow_status :: proc() {
	for p in g.panes.open {
		dv, is_diff := p.content.(^Diff_View)
		if is_diff do dv.stale = true
	}
}


// Before the panes' frames: applies last frame's hunk buttons, takes the
// loader's results, and asks for loads that are due: views marked stale, and
// views of an open editor's text once its edits rest
diff_views_frame :: proc() {
	uitime.timed(&git_ui)

	// The buttons first: their hunk is an index into the rows they were drawn
	// with, which a result would replace
	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if !ok do continue

		if action, pressed := dv.clicked.?; pressed {
			dv.clicked = nil
			hunk_action(dv, action)
		}
	}

	for &r in diff_load_take() {
		dv := diff_view_with_id(r.view)
		if dv == nil || dv.serial != r.serial {
			diff_load_retire(r)
			continue
		}
		result_landed(dv, &r)
	}

	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if !ok do continue

		follow_editor(dv)
		if dv.stale && dv.serial == 0 {
			post_load(dv)
		}
	}
}


// Whether frames must keep coming: an editor's edits wait to rest, or a view
// is scrolling
diff_views_busy :: proc() -> bool {
	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if !ok do continue

		// Loading, or loaded and not laid out yet (its scroll bars and gutter
		// follow the sides' bounds)
		waiting := dv.status == .Loading || dv.status == .Ready && dv.areas[.Right].w == 0
		if waiting || dv.edited_at != {} || dv.scroll_y != dv.target_y {
			return true
		}
	}
	return false
}


@(private = "file")
diff_view_with_id :: proc(id: u64) -> ^Diff_View {
	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if ok && dv.id == id {
			return dv
		}
	}
	return nil
}


// A view of the work tree follows the open editor's text: a new version (or the
// editor opening or closing) loads it again once edits rest
@(private = "file")
follow_editor :: proc(dv: ^Diff_View) {
	if dv.area == .Staged do return

	e := editor_with_path(dv.path)
	open := e != nil && e.status == .Text
	shown_open := dv.signature.right == .Editor

	if open != shown_open && dv.status != .Loading {
		dv.stale = true
	}
	if open && e.buf.version != dv.seen {
		dv.seen = e.buf.version
		dv.edited_at = time.tick_now()
	}

	if dv.edited_at != {} && time.tick_since(dv.edited_at) >= DIFF_EDIT_DELAY {
		dv.edited_at = {}
		dv.stale = true
	}
}


// Asks the loader for the view's versions, with what it shows now. Waits for
// the repository; a file outside it can't be shown
@(private = "file")
post_load :: proc(dv: ^Diff_View) {
	if !git_available() do return

	rel, inside := git.relative_path(g.git.info.workdir, dv.path)
	if !inside {
		dv.stale = false
		dv.status = .Error
		set_string(&dv.problem, "the file isn't in the repository")
		return
	}
	set_string(&dv.rel, rel)

	dv.loads += 1
	dv.serial = dv.loads
	dv.stale = false
	job := Diff_Job {
		view    = dv.id,
		serial  = dv.serial,
		workdir = strings.clone(g.git.info.workdir),
		rel     = strings.clone(dv.rel),
		path    = strings.clone(dv.path),
		area    = dv.area,
	}

	// The open editor's text, unless the diff is of staged changes
	e := editor_with_path(dv.path)
	if e != nil && e.status == .Text && dv.area != .Staged {
		job.editor = buffer.snapshot(&e.buf)
		dv.seen = e.buf.version
	}
	if dv.status == .Ready do job.known = dv.signature

	if r, done := diff_load_post(job); done {
		result_landed(dv, &r)
	}
}


// A load finished: what it found takes the place of what was shown (taking the
// result), the scroll kept where it was
@(private = "file")
result_landed :: proc(dv: ^Diff_View, r: ^Diff_Result) {
	dv.serial = 0
	defer diff_result_destroy(r)

	switch r.status {
	case .Unchanged:
		return
	case .Binary, .Error:
		drop_shown(dv)
		dv.status = r.status == .Binary ? .Binary : .Error
		set_string(&dv.problem, r.problem)
		dv.signature = r.signature
		return
	case .Ready:
	}

	drop_shown(dv)
	dv.status = .Ready
	dv.signature = r.signature
	dv.left, r.left = r.left, {}
	dv.right, r.right = r.right, {}
	dv.rows, r.rows = r.rows, {}
	dv.left_words, r.left_words = r.left_words, nil
	dv.right_words, r.right_words = r.right_words, nil
	dv.right_size, dv.right_hash = r.right_size, r.right_hash
	dv.widest = 0

	// Lines added and removed
	dv.added, dv.removed = 0, 0
	for h in dv.rows.hunks {
		dv.added += h.new_hi - h.new_lo
		dv.removed += h.old_hi - h.old_lo
	}
	clamp_diff_scroll(dv)
}


// --- Hunks -------------------------------------------------------------------------

// What a hunk's buttons do in this view, if anything: revert, stage or unstage
@(private = "file")
hunk_actions :: proc(dv: ^Diff_View) -> (revert, stage: bool) {
	both := dv.left.exists && dv.right.exists
	switch dv.area {
	case .Changes: return both, both
	case .Staged:  return both, false
	case .Untracked, .Conflicts:
	}
	return false, false
}


// Bytes [lo, hi) of lines [first, last) of a side, as a hunk replaces them.
// Lines that reach the text's end take the line break before them, as the
// last line has none of its own
@(private = "file")
hunk_bytes :: proc(b: ^buffer.Buffer, first, last: int) -> (lo, hi: int) {
	count := buffer.line_count(b)
	lo = first < count ? buffer.line_start(b, first) : buffer.length(b)
	hi = last < count ? buffer.line_start(b, last) : buffer.length(b)
	if last == count && first > 0 && first < count {
		lo -= 1
	}
	return
}


// Applies a hunk button: the right side's lines get the left side's
// (reverting), or the index gets the work tree's (staging) or HEAD's
// (unstaging). Ignored when the view no longer shows what the button was for
@(private = "file")
hunk_action :: proc(dv: ^Diff_View, action: Hunk_Action) {
	uitime.timed(&git_ui)
	if dv.status != .Ready || action.hunk >= len(dv.rows.hunks) {
		return
	}

	h := dv.rows.hunks[action.hunk]
	left_lo, left_hi := hunk_bytes(&dv.left.buf, h.old_lo, h.old_hi)
	right_lo, right_hi := hunk_bytes(&dv.right.buf, h.new_lo, h.new_hi)
	left_text := buffer.read_alloc(&dv.left.buf, left_lo, left_hi)
	right_text := buffer.read_alloc(&dv.right.buf, right_lo, right_hi)

	switch action.kind {
	case .Revert:
		text := with_line_endings(string(left_text), dv.right.buf.crlf)
		revert_hunk(dv, right_lo, right_hi, text)
	case .Stage:
		git_splice_index(dv.rel, dv.signature.left_id, left_lo, left_hi, right_text)
	case .Unstage:
		git_splice_index(dv.rel, dv.signature.right_id, right_lo, right_hi, left_text)
	}
}


// Text with "\r\n" line endings, or "\n" (temp): the side a revert writes to
// keeps its own, as the diff doesn't count them
@(private = "file")
with_line_endings :: proc(text: string, crlf: bool) -> string {
	lf, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	if !crlf do return lf

	out, _ := strings.replace_all(lf, "\n", "\r\n", context.temp_allocator)
	return out
}


// Replaces bytes [lo, hi) of the work tree's version with `text`: in the open
// editor if it shows it (one undo step), else in the file if it is still as
// read. The view loads again once it changed
@(private = "file")
revert_hunk :: proc(dv: ^Diff_View, lo, hi: int, text: string) {
	e := editor_with_path(dv.path)

	switch dv.signature.right {
	case .Editor:
		dv.stale = true
		if e == nil || e.status != .Text || e.buf.version != dv.signature.right_version {
			return
		}
		edit := textedit.Text_Edit{lo = lo, hi = hi, text = text}
		textedit.apply_edits(e, .Other, {edit}, reveal = false)

	case .Work_Tree:
		// Opened meanwhile: its text is what to revert
		if e != nil {
			dv.stale = true
			return
		}

		next_patch_id += 1
		job := Patch_Job {
			id   = next_patch_id,
			path = strings.clone(dv.path),
			size = dv.right_size,
			hash = dv.right_hash,
			lo   = lo,
			hi   = hi,
			text = transmute([]u8)strings.clone(text),
		}
		if r, done := io_post_patch(job); done {
			diff_patch_landed(r)
			io_result_destroy(r)
		}

	case .None, .Head, .Index:
	}
}


// The writer patched a file for a revert, or couldn't: its diffs load again,
// and so does the status
diff_patch_landed :: proc(r: Patch_Result) {
	for p in g.panes.open {
		dv, is_diff := p.content.(^Diff_View)
		if is_diff && same_path(dv.path, r.path) {
			dv.stale = true
		}
	}

	if r.problem == "" {
		git_workspace_changed()
		return
	}
	if !g.dialog.open {
		message := fmt.tprintf("%s wasn't changed: %s.", relative_to_root(r.path), r.problem)
		show_notice("Couldn't revert", message)
	}
}


// The row the next (dir > 0) or previous hunk starts at, from the top of the
// view; -1 if there is none
@(private = "file")
hunk_row_from_view :: proc(dv: ^Diff_View, dir: int) -> int {
	top := int(dv.target_y / f64(diff_line_height(dv)) + 0.5)
	if dir > 0 {
		for start in dv.rows.starts {
			if start > top do return start
		}
		return -1
	}

	for i := len(dv.rows.starts) - 1; i >= 0; i -= 1 {
		if dv.rows.starts[i] < top do return dv.rows.starts[i]
	}
	return -1
}


// Scrolls to the next or previous hunk, a few rows below the top. Returns false
// if there is none that way
diff_step_hunk :: proc(dv: ^Diff_View, dir: int) -> bool {
	row := hunk_row_from_view(dv, dir)
	if row < 0 do return false

	dv.target_y = f64(max(row - 3, 0) * diff_line_height(dv))
	clamp_diff_scroll(dv)
	return true
}


// --- Per frame ---------------------------------------------------------------------

// The row height at the view's zoom
diff_line_height :: proc(dv: ^Diff_View) -> int {
	return editor_line_height(textedit.zoom_factor(dv.zoom))
}


// Zooms the view's text, keeping its top row at the top
diff_view_set_zoom :: proc(dv: ^Diff_View, step: int) {
	before := f64(diff_line_height(dv))
	top := dv.target_y / before

	dv.zoom = textedit.clamp_zoom(step)
	after := f64(diff_line_height(dv))
	dv.scroll_y, dv.target_y = top * after, top * after
	dv.scroll_x = 0
}


// Before layout: each side's place, the mouse and scrolling. `left`, `right` are
// the sides' elements
diff_view_frame :: proc(dv: ^Diff_View, left, right: clay.ElementId, interactive: bool) {
	for side in Diff_Pane_Side {
		r, placed := element_rect(side == .Left ? left : right)
		if placed do dv.areas[side] = r
	}
	dv.char_w = editor_char_width(textedit.zoom_factor(dv.zoom))
	if dv.status != .Ready do return

	if interactive do diff_mouse(dv)
	clamp_diff_scroll(dv)
	animate_diff_scroll(dv)
}


// The wheel scrolls (sideways with Shift), and the scroll bars drag
@(private = "file")
diff_mouse :: proc(dv: ^Diff_View) {
	over := gfx.rect_contains(dv.areas[.Left], g.mouse_pos) ||
	        gfx.rect_contains(dv.areas[.Right], g.mouse_pos)
	if over && g.wheel != {} {
		dx, dy := g.wheel.x, g.wheel.y
		if sdl.GetModState() & sdl.KMOD_SHIFT != {} do dx, dy = dy, 0
		dv.target_y -= f64(dy * WHEEL_LINES) * f64(diff_line_height(dv))
		dv.scroll_x -= dx * WHEEL_COLUMNS * dv.char_w
	}

	for axis in gfx.Axis {
		track, thumb, ok := diff_scrollbar(dv, axis)
		if !ok {
			dv.scroll_drag[axis] = nil
			continue
		}

		max_scroll := axis == .Vertical ? diff_max_scroll_y(dv) : f64(diff_max_scroll_x(dv))
		to, active := scrollbar_mouse(&dv.scroll_drag[axis], track, thumb, axis, max_scroll)
		if !active do continue

		if axis == .Vertical {
			dv.scroll_y, dv.target_y = to, to
		} else {
			dv.scroll_x = f32(to)
		}
	}
}


// The last row can scroll to the top
@(private = "file")
diff_max_scroll_y :: proc(dv: ^Diff_View) -> f64 {
	return f64(max(dv.rows.count - 1, 0) * diff_line_height(dv))
}


// As far as the widest line shown, with a little room after it
@(private = "file")
diff_max_scroll_x :: proc(dv: ^Diff_View) -> f32 {
	text_w := dv.areas[.Right].w - side_gutter(dv) - DIFF_TEXT_MARGIN - 2 * dv.char_w
	return max(f32(dv.widest) * dv.char_w - text_w, 0)
}


@(private = "file")
clamp_diff_scroll :: proc(dv: ^Diff_View) {
	max_y := diff_max_scroll_y(dv)
	dv.target_y = clamp(dv.target_y, 0, max_y)
	dv.scroll_y = clamp(dv.scroll_y, 0, max_y)
	dv.scroll_x = clamp(dv.scroll_x, 0, diff_max_scroll_x(dv))
}


// Eases toward the scroll target as the editor does
@(private = "file")
animate_diff_scroll :: proc(dv: ^Diff_View) {
	if !g.settings.smooth_scroll {
		dv.scroll_y = dv.target_y
		return
	}

	t := scroll_ease_step()
	dv.scroll_y += (dv.target_y - dv.scroll_y) * t
	if abs(dv.target_y - dv.scroll_y) < 0.25 do dv.scroll_y = dv.target_y
}


// The vertical bar along the right side's right edge, the sideways one along
// its bottom (short of the corner when both show)
@(private = "file")
diff_scrollbar :: proc(dv: ^Diff_View, axis: gfx.Axis) -> (track, thumb: gfx.Rect, ok: bool) {
	area := dv.areas[.Right]
	if axis == .Vertical {
		return scrollbar_geometry(area, .Vertical, dv.scroll_y, diff_max_scroll_y(dv))
	}

	gutter := side_gutter(dv)
	text := gfx.Rect{area.x + gutter, area.y, area.w - gutter, area.h}
	if diff_max_scroll_y(dv) > 0 do text.w -= SCROLLBAR_WIDTH
	return scrollbar_geometry(text, .Horizontal, f64(dv.scroll_x), f64(diff_max_scroll_x(dv)))
}


// Keys while the diff pane has them: scrolling, and F8 / Shift+F8 (next and
// previous problem) to the next and previous hunk
diff_view_handle_key :: proc(dv: ^Diff_View, event: ^sdl.Event) -> bool {
	if event.type != .KEY_DOWN || dv.status != .Ready {
		return false
	}

	lh := f64(diff_line_height(dv))
	page := max(f64(dv.areas[.Right].h) - lh, lh)
	switch event.key.key {
	case sdl.K_UP:       dv.target_y -= lh
	case sdl.K_DOWN:     dv.target_y += lh
	case sdl.K_PAGEUP:   dv.target_y -= page
	case sdl.K_PAGEDOWN: dv.target_y += page
	case sdl.K_HOME:     dv.target_y = 0
	case sdl.K_END:      dv.target_y = diff_max_scroll_y(dv)
	case:
		cmd, bound := command_for_key(event.key)
		if !bound do return false
		#partial switch cmd {
		case .Next_Problem:     diff_step_hunk(dv, +1)
		case .Previous_Problem: diff_step_hunk(dv, -1)
		case:                   return false
		}
	}
	clamp_diff_scroll(dv)
	return true
}


// --- UI ----------------------------------------------------------------------------

// The pane's body: a toolbar over the two sides, with each hunk's buttons
// between them
diff_view_ui :: proc(p: ^Pane, dv: ^Diff_View, left, right: clay.ElementId) {
	diff_toolbar(p, dv)

	switch dv.status {
	case .Loading:
		if sdl.GetTicksNS() - dv.opened_at > EDITOR_SHOW_WAIT {
			centered_message("Loading…")
		}
		return
	case .Binary:
		centered_message("Binary file not shown")
		return
	case .Error:
		centered_message(fmt.tprintf("Couldn't show the diff: %s", dv.problem))
		return
	case .Ready:
	}

	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
		border = {color = gfx.theme.border, width = {top = 1}},
	}) {
		custom_element(left, Diff_Draw{dv, .Left})
		hunk_gutter(p, dv)
		custom_element(right, Diff_Draw{dv, .Right})
	}
}


// Each side's name and lines, aligned with the side, then going from hunk to
// hunk, staging or unstaging the file and opening it
@(private = "file")
diff_toolbar :: proc(p: ^Pane, dv: ^Diff_View) {
	left_name, right_name := side_names(dv)

	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(DIFF_TOOLBAR)},
			childAlignment = {y = .Center},
		},
	}) {
		// The old side
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				padding = {left = 12},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		}) {
			label(left_name, gfx.theme.text_dim, FONT_SIZE_SMALL, .SemiBold)
			if dv.removed > 0 {
				label(fmt.tprintf("−%d", dv.removed), gfx.theme.git_deleted, FONT_SIZE_SMALL)
			}
		}

		spacer_x(DIFF_GUTTER)

		// The new side, and the buttons
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				padding = {left = 12, right = 6},
				childGap = 8,
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true},
		}) {
			label(right_name, gfx.theme.text_dim, FONT_SIZE_SMALL, .SemiBold)
			if dv.added > 0 {
				label(fmt.tprintf("+%d", dv.added), gfx.theme.git_added, FONT_SIZE_SMALL)
			}
			if dv.status == .Ready && len(dv.rows.hunks) == 0 {
				label("No changes", gfx.theme.text_faint, FONT_SIZE_SMALL)
			}
			push_right()
			diff_toolbar_buttons(p, dv)
		}
	}
}


@(private = "file")
diff_toolbar_buttons :: proc(p: ^Pane, dv: ^Diff_View) {
	if clay.UI()({layout = {childGap = 2, childAlignment = {y = .Center}}}) {
		has_hunks := dv.status == .Ready && len(dv.rows.hunks) > 0
		if has_hunks {
			prev := clay.ID("DiffPrevious", p.id)
			next := clay.ID("DiffNext", p.id)
			chord_prev := first_chord_label(.Previous_Problem)
			chord_next := first_chord_label(.Next_Problem)
			if icon_button(prev, .Chevron_Up, 22, 14, "Previous change", chord_prev) {
				diff_step_hunk(dv, -1)
			}
			if icon_button(next, .Chevron_Down, 22, 14, "Next change", chord_next) {
				diff_step_hunk(dv, +1)
			}
		}

		// The whole file in or out of the index, once it is known in the repository
		entry := git.Entry{path = dv.rel, area = dv.area}
		switch {
		case dv.rel == "":
		case dv.area == .Staged:
			if icon_button(clay.ID("DiffUnstage", p.id), .Minus, 22, 14, "Unstage file") {
				git_unstage({entry})
			}
		case:
			if icon_button(clay.ID("DiffStage", p.id), .Plus, 22, 14, "Stage file") {
				git_stage({dv.rel})
			}
		}

		open_tip := "Open file"
		if icon_button(clay.ID("DiffOpen", p.id), .File_Code, 22, 14, open_tip) {
			defer_action(Open_File(strings.clone(dv.path)))
		}
	}
}


// What each side is
@(private = "file")
side_names :: proc(dv: ^Diff_View) -> (left, right: string) {
	switch dv.area {
	case .Changes:   return "Staged", "Working tree"
	case .Staged:    return "HEAD", "Staged"
	case .Untracked: return "Not in Git", "Working tree"
	case .Conflicts: return "HEAD", "Working tree"
	}
	return "", ""
}


// The strip between the sides: each hunk's buttons beside its first row, for
// the hunks in view (the pane's height bounds the rows). Its rows scroll with
// the sides
@(private = "file")
hunk_gutter :: proc(p: ^Pane, dv: ^Diff_View) {
	lh := f32(diff_line_height(dv))
	first := int(dv.scroll_y / f64(lh))
	shown := int(p.rect.h / lh) + 2
	offset := f32(dv.scroll_y - f64(first) * f64(lh))
	revert, stage := hunk_actions(dv)

	if clay.UI(clay.ID("DiffGutter", p.id))({
		layout = {
			sizing = {clay.SizingFixed(DIFF_GUTTER), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = gfx.theme.gutter,
		border = {color = gfx.theme.border, width = {left = 1, right = 1}},
		clip = {vertical = true, childOffset = {0, -offset}},
	}) {
		if !revert && !stage {
			return
		}

		at := first
		for start, k in dv.rows.starts {
			if start < first do continue
			if start >= first + shown do break

			gap := f32(start - at) * lh
			if gap > 0 {
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(gap)}}}) {}
			}
			hunk_buttons(p, dv, k, lh, revert, stage)
			at = start + 1
		}
	}
}


// A hunk's buttons, in a row as tall as a line
@(private = "file")
hunk_buttons :: proc(p: ^Pane, dv: ^Diff_View, k: int, lh: f32, revert, stage: bool) {
	size := min(f32(DIFF_BUTTON), lh)
	key := u32(p.id) << 20 | u32(k)

	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(lh)},
			childGap = 2,
			childAlignment = {x = .Center, y = .Center},
		},
	}) {
		if revert {
			unstaging := dv.area == .Staged
			tip := unstaging ? "Unstage this change" : "Revert this change"
			if icon_button(clay.ID("DiffRevert", key), .Arrow_Right, size, 13, tip) {
				dv.clicked = Hunk_Action{unstaging ? .Unstage : .Revert, k}
			}
		}
		if stage {
			if icon_button(clay.ID("DiffStageHunk", key), .Plus, size, 13, "Stage this change") {
				dv.clicked = Hunk_Action{.Stage, k}
			}
		}
	}
}


// --- Drawing -----------------------------------------------------------------------

// The width of a side's line numbers
@(private = "file")
side_gutter :: proc(dv: ^Diff_View) -> f32 {
	lines := max(dv.rows.old_lines, dv.rows.new_lines)
	digits := len(fmt.tprintf("%d", lines))
	return f32(max(digits, 3)) * dv.char_w + 20
}


// Draws one side's rows in view (pixels): shading, changed words, the text and
// its line numbers; the right side also draws the scroll bars
draw_diff_side :: proc(d: Diff_Draw, b: clay.BoundingBox, scale: f32) {
	dv := d.view
	if dv.status != .Ready || dv.char_w <= 0 {
		return
	}

	zoom := textedit.zoom_factor(dv.zoom)
	font := gfx.text_get_font(&gfx.text_system, .Editor, editor_font_size(zoom))
	if font == nil do return

	gfx.push_clip_box(b)
	defer gfx.pop_clip()

	side := d.side == .Left ? &dv.left : &dv.right
	words := d.side == .Left ? dv.left_words : dv.right_words

	// Metrics
	adv := dv.char_w * scale
	line_height := diff_line_height(dv)
	lh := f32(line_height) * scale
	gutter := math.round(side_gutter(dv) * scale)
	text_x := b.x + gutter + DIFF_TEXT_MARGIN * scale - dv.scroll_x * scale
	text_dy := math.round((lh - f32(ttf.GetFontHeight(font))) / 2)
	first_col := int(dv.scroll_x / dv.char_w)
	col_count := int((b.width - gutter) / adv) + 2

	// The rows in view, and this side's line in each
	first := int(dv.scroll_y) / line_height
	y0 := b.y - f32(dv.scroll_y - f64(first * line_height)) * scale
	last := min(first + int(b.height / lh) + 2, dv.rows.count)
	if first >= last do return

	rows := make([]diff.Row, last - first, context.temp_allocator)
	lo_line, hi_line := max(int), -1
	for &row, i in rows {
		row = diff.row_at(&dv.rows, first + i)
		line := d.side == .Left ? row.old : row.new
		if line < 0 do continue
		lo_line = min(lo_line, line)
		hi_line = max(hi_line, line)
	}

	// The side's text and highlights for those lines, in one read each
	text, text_start, hl := side_span(side, lo_line, hi_line)

	// Shading behind each row, and the changed words in it
	for row, i in rows {
		y := math.round(y0 + f32(i) * lh)
		y2 := math.round(y0 + f32(i + 1) * lh)
		line := d.side == .Left ? row.old : row.new

		shade := row_shade(row.kind, d.side, line < 0)
		if shade.a > 0 do gfx.fill_rect(b.x, y, b.width, y2 - y, shade)
		if line < 0 || row.kind != .Changed {
			continue
		}

		line_text, _ := span_line(side, text, text_start, line)
		word := d.side == .Left ? gfx.theme.diff_removed_word : gfx.theme.diff_added_word
		for w in words_on_line(words, line) {
			x1 := diff_col_x(line_text, w.lo, text_x, adv)
			x2 := diff_col_x(line_text, min(w.hi, len(line_text)), text_x, adv)
			gfx.fill_rect(x1, y, max(x2 - x1, math.round(scale)), y2 - y, word)
		}
	}

	// The text
	for row, i in rows {
		line := d.side == .Left ? row.old : row.new
		if line < 0 do continue

		y := math.round(y0 + f32(i) * lh)
		line_text, start := span_line(side, text, text_start, line)
		dv.widest = max(dv.widest, textedit.visual_col(line_text, len(line_text)))

		lo := clamp(start - text_start, 0, len(hl))
		hi := clamp(lo + len(line_text), lo, len(hl))
		for run in editor_runs(line_text, hl[lo:hi], nil, first_col, col_count) {
			x := math.round(text_x + f32(run.col) * adv)
			t := gfx.text_get(&gfx.text_system, font, run.text)
			gfx.draw_text(t, x, y + text_dy, gfx.theme.syntax[run.hl])
		}
	}

	// Line numbers, over the text scrolled under them
	draw_line_numbers(dv, d.side, rows, {b.x, y0, gutter, lh}, font, text_dy, b.height, scale)

	if d.side == .Right do draw_diff_scrollbars(dv, scale)
}


// A row's shading on a side: removed lines red on the left, added lines green
// on the right, filler where the side has no line
@(private = "file")
row_shade :: proc(kind: diff.Row_Kind, side: Diff_Pane_Side, filler: bool) -> clay.Color {
	if filler do return gfx.theme.diff_filler

	switch kind {
	case .Same:             return {}
	case .Changed:          return side == .Left ? gfx.theme.diff_removed : gfx.theme.diff_added
	case .Removed:          return gfx.theme.diff_removed
	case .Added:            return gfx.theme.diff_added
	}
	return {}
}


// The text of lines [lo, hi] of a side and their highlights (temp), capped
// like the editor's; empty when no line shows
@(private = "file")
side_span :: proc(
	side: ^Diff_Side,
	lo, hi: int,
) -> (
	text: string,
	start: int,
	hl: []syntax.Highlight,
) {
	if hi < lo do return

	b := &side.buf
	start = buffer.line_start(b, lo)
	end := hi + 1 < buffer.line_count(b) ? buffer.line_start(b, hi + 1) : buffer.length(b)
	end = min(end, start + textedit.MAX_LINE_SCAN)

	text = string(buffer.read_alloc(b, start, end))
	hl = make([]syntax.Highlight, len(text), context.temp_allocator)
	syntax.highlight_range(&side.hl, b, start, hl)
	return
}


// A line's text within a span read by side_span, without its line break, and
// where it starts in the document
@(private = "file")
span_line :: proc(side: ^Diff_Side, text: string, text_start, line: int) -> (string, int) {
	b := &side.buf
	start := buffer.line_start(b, line)
	end := buffer.line_end(b, line)

	lo := clamp(start - text_start, 0, len(text))
	hi := clamp(end - text_start, lo, len(text))
	return text[lo:hi], start
}


// The changed-word spans of a line, out of a side's (sorted by line)
@(private = "file")
words_on_line :: proc(words: []Word_Span, line: int) -> []Word_Span {
	lo, hi := 0, len(words)
	for lo < hi {
		mid := (lo + hi) / 2
		if words[mid].line < line {
			lo = mid + 1
		} else {
			hi = mid
		}
	}

	end := lo
	for end < len(words) && words[end].line == line {
		end += 1
	}
	return words[lo:end]
}


@(private = "file")
diff_col_x :: proc(text: string, i: int, text_x, adv: f32) -> f32 {
	return math.round(text_x + f32(textedit.visual_col(text, i)) * adv)
}


// The line numbers of a side's rows, right-aligned in its gutter, in the
// gutter's color shaded like the rows. `grid` is the gutter's left and width,
// the first row's top and a row's height
@(private = "file")
draw_line_numbers :: proc(
	dv: ^Diff_View,
	side: Diff_Pane_Side,
	rows: []diff.Row,
	grid: gfx.Rect,
	font: ^ttf.Font,
	text_dy, height, scale: f32,
) {
	zoom := textedit.zoom_factor(dv.zoom)
	gfx.fill_rect(grid.x, grid.y - grid.h, grid.w, height + 2 * grid.h, gfx.theme.gutter)

	num_font := gfx.text_get_font(&gfx.text_system, .Editor, gutter_font_size(zoom))
	if num_font == nil do return
	num_dy := text_dy + f32(ttf.GetFontAscent(font) - ttf.GetFontAscent(num_font))
	right := grid.x + grid.w - math.round(10 * scale)

	for row, i in rows {
		y := math.round(grid.y + f32(i) * grid.h)
		y2 := math.round(grid.y + f32(i + 1) * grid.h)
		line := side == .Left ? row.old : row.new

		shade := row_shade(row.kind, side, line < 0)
		if shade.a > 0 do gfx.fill_rect(grid.x, y, grid.w, y2 - y, shade)
		if line < 0 do continue

		t := gfx.text_get(&gfx.text_system, num_font, fmt.tprintf("%d", line + 1))
		if t == nil do continue

		w, h: i32
		_ = ttf.GetTextSize(t, &w, &h)
		color := row.kind == .Same ? gfx.theme.text_faint : gfx.theme.text_dim
		gfx.draw_text(t, right - f32(w), y + num_dy, color)
	}
}


// The scroll bars' thumbs, each brighter while hovered or dragged
@(private = "file")
draw_diff_scrollbars :: proc(dv: ^Diff_View, scale: f32) {
	for axis in gfx.Axis {
		track, thumb, ok := diff_scrollbar(dv, axis)
		if !ok do continue

		hot := dv.scroll_drag[axis] != nil || gfx.rect_contains(track, g.mouse_pos)
		r, c := gfx.scrollbar_thumb_look(thumb, axis, hot)

		b := clay.BoundingBox{r.x * scale, r.y * scale, r.w * scale, r.h * scale}
		radius := min(b.width, b.height) / 2
		gfx.fill_rounded_rect(b, {radius, radius, radius, radius}, c)
	}
}
