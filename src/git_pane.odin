package editor

// The Git pane: the branch and how far it is from its upstream, a commit
// message box with Commit, push, pull and fetch, and the changed files in
// collapsible sections (merge conflicts, staged changes, changes, untracked).
// Each row shows the file's icon, name, folder and a letter colored by its
// change; on hover, buttons stage, unstage or discard it, as the section's
// header does for all of them. A click on a row opens its diff
// (diff_view.odin): in the diff pane already shown, else in place of the editor
// in use, else beside the Git pane. Keys: Up/Down select a row, Enter opens
// its diff, Space stages or unstages it, Delete discards it; Ctrl+Enter
// commits from the message box, Esc leaves it. There is one Git pane, opened
// and focused by Open Git pane (Ctrl+Shift+G) or the status bar's branch

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "git"
import "gfx"
import "uitime"


GIT_ROW_HEIGHT :: 24
GIT_PADDING    :: 10
GIT_MIN_WIDTH  :: 240          // a narrower pane cuts the Git pane off at its edge
COMMIT_CHORD   :: "Ctrl+Enter" // in the message box

// The rows' insets and gaps: a section's chevron and name, then its files
// indented to line up with the name past the chevron
@(private = "file")
SECTION_INSET :: 4
@(private = "file")
SECTION_GAP :: 4
@(private = "file")
FILE_INSET :: 18
@(private = "file")
FILE_GAP :: 6

Git_View :: struct {
	message:   Text_Area,
	typing:    bool,           // the message box has the keys
	selected:  Git_Row_Key,    // owned path; the row the keys act on
	reveal:    bool,           // scroll the selected row into view when next laid out
	collapsed: bit_set[git.Area],
	list_drag: Maybe(f32),
	chosen:    Maybe(Git_Row_Key), // owned path; a row clicked, its diff opened next frame
}

// A row of the file list: an area's header (path "") or a file in it
Git_Row_Key :: struct {
	area: git.Area,
	path: string,
}

// The sections, top to bottom
@(private = "file")
SECTIONS := [git.Area]string {
	.Conflicts = "MERGE CONFLICTS",
	.Staged    = "STAGED CHANGES",
	.Changes   = "CHANGES",
	.Untracked = "UNTRACKED",
}


git_view_init :: proc(gv: ^Git_View) {
	text_area_init(&gv.message)
}


git_view_destroy :: proc(gv: ^Git_View) {
	text_area_destroy(&gv.message)
	delete(gv.selected.path)
	if chosen, ok := gv.chosen.?; ok {
		delete(chosen.path)
	}
	gv^ = {}
}


// The Git pane, if open
git_pane :: proc() -> ^Pane {
	for p in g.panes.open {
		_, is_git := p.content.(^Git_View)
		if is_git do return p
	}
	return nil
}


// Open Git pane: opens it beside the editor in use, or shows and focuses it,
// with the keys in its message box
git_pane_open :: proc() -> bool {
	if !git_available() && git_pane() == nil {
		return false
	}

	p := git_pane()
	if p == nil {
		gv := new(Git_View)
		git_view_init(gv)
		p = panes_add_git(gv)
	}
	if !pane_shown(p) do pane_move(p, place_for_git(p))
	pane_focus(p)

	gv := p.content.(^Git_View)
	gv.typing = true
	return true
}


// A commit went through: the message box empties (undo brings it back)
git_pane_committed :: proc() {
	p := git_pane()
	if p == nil do return

	gv := p.content.(^Git_View)
	text_area_clear(&gv.message)
}


// --- Per frame ---------------------------------------------------------------------

// Before layout: last frame's clicked row opens its diff; the message box
// loses the keys to a press elsewhere or another pane
git_view_frame :: proc(p: ^Pane, gv: ^Git_View) {
	if chosen, ok := gv.chosen.?; ok {
		gv.chosen = nil
		git_open_diff(chosen.path, chosen.area, focus = false)
		delete(chosen.path)
	}

	pressed := g.mouse_pressed && ui_interactive()
	if g.panes.focused != p || (pressed && !pointer_in(clay.ID("GitMessage"))) {
		gv.typing = false
	}
}


// Opens a file's diff: in the diff pane shown (unless it shows that file
// already), else a new one in place of the editor in use (which closes unless
// it has unsaved changes), else right of the Git pane
git_open_diff :: proc(rel: string, area: git.Area, focus: bool) {
	uitime.timed(&git_ui)
	path := git_full_path(rel)

	// The diff pane shown takes it
	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if !ok || !pane_shown(p) {
			continue
		}

		if !diff_view_is(dv, path, area) do diff_view_open(dv, path, area)
		if focus do pane_focus(p)
		return
	}

	dv := new(Diff_View)
	diff_view_open(dv, path, area)
	p := panes_add_diff(dv)
	pane_move(p, place_for_diff(p))
	if focus do pane_focus(p)
}


// --- Keys --------------------------------------------------------------------------

// Keys while the Git pane is focused: the message box's while it has them,
// else the list's. Returns whether the event was used
git_view_handle_event :: proc(p: ^Pane, gv: ^Git_View, event: ^sdl.Event) -> bool {
	if gv.typing do return message_event(gv, event)
	if event.type != .KEY_DOWN do return false

	count := row_count(gv)
	at := row_index(gv, gv.selected)
	row: Git_Row
	if at >= 0 do row = row_at(gv, at)

	switch event.key.key {
	case sdl.K_UP:
		select_row(gv, max(at - 1, 0))
	case sdl.K_DOWN:
		select_row(gv, min(at + 1, count - 1))
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		switch {
		case at < 0:
		case row.entry == nil: toggle_section(gv, row.area)
		case:                  git_open_diff(row.entry.path, row.area, focus = false)
		}
	case sdl.K_SPACE:
		if at >= 0 do stage_or_unstage(row)
	case sdl.K_DELETE, sdl.K_BACKSPACE:
		if at >= 0 do discard_row(row)
	case sdl.K_TAB:
		gv.typing = true
	case:
		return false
	}
	return true
}


// The message box's keys: Ctrl+Enter commits, Esc leaves the box, shortcuts
// that aren't the box's own go on
@(private = "file")
message_event :: proc(gv: ^Git_View, event: ^sdl.Event) -> bool {
	if event.type == .KEY_DOWN {
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		switch event.key.key {
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if ctrl {
				commit_message(gv)
				return true
			}
		case sdl.K_ESCAPE:
			gv.typing = false
			return true
		}

		// Shortcuts the box doesn't take go on
		cmd, bound := command_for_key(event.key)
		if bound && cmd not_in FIELD_COMMANDS {
			return false
		}
	}
	return text_area_event(&gv.message, event)
}


@(private = "file")
commit_message :: proc(gv: ^Git_View) {
	git_commit(text_area_string(&gv.message))
}


// --- The list ----------------------------------------------------------------------

// A row of the file list: a section's header, or one of its files. The list's
// rows aren't stored: a row is found from the sections' sizes, so a status of
// any size costs only the rows in view
@(private = "file")
Git_Row :: struct {
	area:  git.Area,
	entry: ^git.Entry, // the status's; nil for the header
}


// How many rows the list has: each section with files, its header, then its
// files unless collapsed
@(private = "file")
row_count :: proc(gv: ^Git_View) -> (n: int) {
	s := &g.git.status
	for area in git.Area {
		files := s.counts[area]
		if files == 0 do continue

		n += 1
		if area not_in gv.collapsed do n += files
	}
	return
}


@(private = "file")
row_at :: proc(gv: ^Git_View, i: int) -> Git_Row {
	s := &g.git.status
	i := i
	for area in git.Area {
		entries := git.entries_in(s, area)
		if len(entries) == 0 do continue

		if i == 0 do return {area, nil}
		i -= 1
		if area in gv.collapsed do continue

		if i < len(entries) do return {area, &entries[i]}
		i -= len(entries)
	}
	return {}
}


// The key a row is selected by
@(private = "file")
row_key :: proc(row: Git_Row) -> Git_Row_Key {
	return {row.area, row.entry != nil ? row.entry.path : ""}
}


// The index of the row with a key, or -1. Looks through the list: for keys and
// scrolling to the selection, not per frame
@(private = "file")
row_index :: proc(gv: ^Git_View, key: Git_Row_Key) -> int {
	for i in 0 ..< row_count(gv) {
		if same_row(row_key(row_at(gv, i)), key) do return i
	}
	return -1
}


@(private = "file")
select_row :: proc(gv: ^Git_View, i: int) {
	if i < 0 || i >= row_count(gv) {
		return
	}

	key := row_key(row_at(gv, i))
	gv.selected.area = key.area
	set_string(&gv.selected.path, key.path)
	gv.reveal = true
}


@(private = "file")
toggle_section :: proc(gv: ^Git_View, area: git.Area) {
	gv.collapsed ~= {area}
}


// A row's entries: its file's, or its section's
@(private = "file")
row_entries :: proc(row: Git_Row) -> []git.Entry {
	if row.entry != nil do return slice.from_ptr(row.entry, 1)
	return git.entries_in(&g.git.status, row.area)
}


@(private = "file")
stage_or_unstage :: proc(row: Git_Row) {
	entries := row_entries(row)
	if row.area == .Staged {
		git_unstage(entries)
		return
	}

	paths := make([]string, len(entries), context.temp_allocator)
	for e, i in entries do paths[i] = e.path
	git_stage(paths)
}


@(private = "file")
discard_row :: proc(row: Git_Row) {
	if row.area == .Changes || row.area == .Untracked {
		git_discard_ask(row_entries(row))
	}
}


// --- UI ----------------------------------------------------------------------------

// The pane's body
git_view_ui :: proc(p: ^Pane, gv: ^Git_View) {
	gs := &g.git
	if !git_available() {
		message := "The folder isn't in a Git repository"
		if gs.problem != "" do message = fmt.tprintf("No repository: %s", gs.problem)
		centered_message(message)
		return
	}
	if !gs.loaded {
		centered_message("Reading the repository…")
		return
	}

	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {left = GIT_PADDING, right = GIT_PADDING, top = 2, bottom = 4},
			childGap = 8,
		},
	}) {
		if clicked(clay.ID("GitMessage")) do gv.typing = true
		text_area(clay.ID("GitMessage"), &gv.message, "Message", gv.typing)
		action_row(gv)
		note_line()
		file_list(p, gv)
	}
}


// Beside the pane's title, faded: the upstream the branch follows (else the
// branch), then the operation under way (a merge or rebase)
git_title_note :: proc() {
	s := &g.git.status
	if !git_available() || !g.git.loaded {
		return
	}

	name := s.upstream
	switch {
	case name != "":
	case s.branch != "": name = s.branch
	case s.head != "":   name = fmt.tprintf("detached at %s", s.head)
	}
	if name != "" do label(name, gfx.theme.text_faint, FONT_SIZE_SMALL)

	if s.operation != .None {
		operation := git.operation_name(s.operation)
		label(operation, gfx.theme.git_conflict, FONT_SIZE_SMALL, .SemiBold)
	}
}


// Commit, then push, pull and fetch together
@(private = "file")
action_row :: proc(gv: ^Git_View) {
	if clay.UI()({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(30)},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	}) {
		commit_button(gv)
		remote_buttons()
	}
}


@(private = "file")
commit_button :: proc(gv: ^Git_View) {
	gs := &g.git
	id := clay.ID("GitCommit")
	message := text_area_string(&gv.message)
	enabled := git_can_commit(message)
	hovered := enabled && ui_interactive() && pointer_in(id)

	bg, fg := gfx.theme.accent, gfx.theme.bg
	if !enabled do bg, fg = gfx.theme.hover, gfx.theme.text_faint
	if hovered do bg = gfx.mix(bg, gfx.theme.text_bright, 0.12)

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			childGap = 6,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(6),
		transition = transition({.BackgroundColor}),
	}) {
		icon(.Check, fg, 14)
		label(commit_label(gs.status.counts[.Staged]), fg, FONT_SIZE_UI, .SemiBold)
	}

	// Its key in the tooltip, whether it can commit now or not
	tip := "Commit the staged changes"
	switch {
	case gs.remote != nil:                  tip = "A git command is running"
	case gs.status.counts[.Staged] == 0:    tip = "Stage changes to commit them"
	case strings.trim_space(message) == "": tip = "Write a message to commit"
	}
	tooltip(id, tip, COMMIT_CHORD)
	if enabled && clicked(id) {
		commit_message(gv)
	}
}


// "Commit 2 files", or "Commit" with nothing staged
@(private = "file")
commit_label :: proc(staged: int) -> string {
	if staged == 0 do return "Commit"
	return fmt.tprintf("Commit %d %s", staged, staged == 1 ? "file" : "files")
}


// "3 commits"
@(private = "file")
commits :: proc(n: int) -> string {
	return fmt.tprintf("%d %s", n, n == 1 ? "commit" : "commits")
}


// Push, pull and fetch as one group of buttons, with the commits to push and
// pull beside their arrows
@(private = "file")
remote_buttons :: proc() {
	gs := &g.git
	s := &gs.status
	busy := gs.remote != nil

	if clay.UI()({
		layout = {
			sizing = {height = clay.SizingGrow()},
			padding = clay.PaddingAll(2),
			childGap = 2,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		push_tip := "Push"
		switch {
		case s.ahead > 0:      push_tip = fmt.tprintf("Push %s", commits(s.ahead))
		case s.upstream == "": push_tip = "Publish the branch to origin"
		}
		if remote_button(clay.ID("GitPush"), .Cloud_Upload, s.ahead, push_tip, busy) {
			git_remote(.Push)
		}

		pull_tip := s.behind > 0 ? fmt.tprintf("Pull %s", commits(s.behind)) : "Pull"
		if remote_button(clay.ID("GitPull"), .Cloud_Download, s.behind, pull_tip, busy) {
			git_remote(.Pull)
		}

		if remote_button(clay.ID("GitFetch"), .Refresh, 0, "Fetch", busy) {
			git_remote(.Fetch)
		}
	}
}


// An icon button of the remote group, with a count when there is one
@(private = "file")
remote_button :: proc(
	id: clay.ElementId,
	kind: gfx.Icon,
	count: int,
	tip: string,
	busy: bool,
) -> bool {
	hovered := !busy && ui_interactive() && pointer_in(id)
	color := gfx.theme.text_dim
	if busy do color = gfx.theme.text_faint
	if hovered do color = gfx.theme.text_bright

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFit({min = 26}), clay.SizingGrow()},
			padding = {left = 5, right = 5},
			childGap = 3,
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hovered ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(4),
	}) {
		icon(kind, color, 15)
		if count > 0 do label(fmt.tprintf("%d", count), color, FONT_SIZE_SMALL)
	}

	tooltip(id, tip)
	return !busy && clicked(id)
}


// How the last command went
@(private = "file")
note_line :: proc() {
	note := &g.git.note
	if note.text == "" do return

	if clay.UI()({
		layout = {sizing = {width = clay.SizingGrow()}},
		clip = {horizontal = true},
	}) {
		label(note.text, note.error ? gfx.theme.error : gfx.theme.text_dim, FONT_SIZE_SMALL)
	}
}


// The sections and their files; only the rows in view are laid out
@(private = "file")
file_list :: proc(p: ^Pane, gv: ^Git_View) {
	count := row_count(gv)
	if count == 0 {
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				childAlignment = {x = .Center, y = .Center},
			},
		}) {
			label("No changes", gfx.theme.text_faint)
		}
		return
	}

	list := clay.ID("GitFiles", p.id)
	scroll := clay.GetScrollContainerData(list)
	if gv.reveal && scroll.found {
		reveal_selected(gv, scroll)
		gv.reveal = false
	}

	// The rows in view
	first, shown := 0, int(p.rect.h / GIT_ROW_HEIGHT) + 2
	if scroll.found {
		first = clamp(int(-scroll.scrollPosition.y / GIT_ROW_HEIGHT), 0, count)
	}
	last := min(first + shown, count)

	if clay.UI(list)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {right = SCROLLBAR_GUTTER - 6},
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		list_spacer(first)
		for i in first ..< last {
			row := row_at(gv, i)
			if row.entry == nil {
				section_row(p, gv, row, list)
			} else {
				file_row(p, gv, row, list)
			}
		}
		list_spacer(count - last)
	}
	list_scrollbar(list, &gv.list_drag, pane_layer(p))
}


@(private = "file")
list_spacer :: proc(rows: int) {
	if rows <= 0 do return

	height := f32(rows) * GIT_ROW_HEIGHT
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(height)}}}) {}
}


@(private = "file")
reveal_selected :: proc(gv: ^Git_View, scroll: clay.ScrollContainerData) {
	i := row_index(gv, gv.selected)
	if i >= 0 do list_reveal_row(scroll, i, GIT_ROW_HEIGHT)
}


// A section's header: a chevron, its name and count, and on hover its buttons
@(private = "file")
section_row :: proc(p: ^Pane, gv: ^Git_View, row: Git_Row, list: clay.ElementId) {
	key := row_key(row)
	id := clay.ID("GitSection", u32(p.id) << 4 | u32(row.area))
	selected := g.panes.focused == p && !gv.typing && same_row(gv.selected, key)
	collapsed := row.area in gv.collapsed

	if list_row(id, selected, GIT_ROW_HEIGHT, SECTION_INSET, SECTION_GAP) {
		hovered := clay.Hovered()
		icon(collapsed ? .Chevron_Right : .Chevron_Down, gfx.theme.text_dim, 13)
		label(SECTIONS[row.area], gfx.theme.text_dim, FONT_SIZE_SMALL, .Bold)
		count := g.git.status.counts[row.area]
		label(fmt.tprintf("%d", count), gfx.theme.text_faint, FONT_SIZE_SMALL)
		push_right()

		if hovered do row_buttons(p, row, list)
	}

	if clicked(id, list) && !on_row_button(p, key) {
		toggle_section(gv, row.area)
		set_selected(gv, key)
	}
}


// Selects a row by its key (a click)
@(private = "file")
set_selected :: proc(gv: ^Git_View, key: Git_Row_Key) {
	gv.selected.area = key.area
	set_string(&gv.selected.path, key.path)
}


// A file's row: its icon, name and folder, its buttons on hover, and the letter
// of its change
@(private = "file")
file_row :: proc(p: ^Pane, gv: ^Git_View, row: Git_Row, list: clay.ElementId) {
	e := row.entry
	key := row_key(row)
	id := clay.ID("GitFile", row_hash(p, key))
	selected := same_row(gv.selected, key)
	focused := g.panes.focused == p && !gv.typing

	if list_row(id, selected && focused, GIT_ROW_HEIGHT, FILE_INSET, FILE_GAP) {
		hovered := clay.Hovered()
		name_color := e.kind == .Deleted ? gfx.theme.text_dim : gfx.theme.text
		icon(file_icon(e.path), selected ? gfx.theme.accent : gfx.theme.text_dim, 14)

		// The name and folder, clipped together
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childGap = 6,
				childAlignment = {y = .Center},
			},
			clip = row_clip(),
		}) {
			label(git_file_name(e.path), name_color, FONT_SIZE_SIDEBAR)
			folder := git_file_folder(e.path)
			if e.old_path != "" do folder = fmt.tprintf("from %s", e.old_path)
			if folder != "" do label(folder, gfx.theme.text_faint, FONT_SIZE_SMALL)
		}

		if hovered do row_buttons(p, row, list)

		// The change's letter, in a cell of its own so they line up
		if clay.UI()({
			layout = {
				sizing = {clay.SizingFixed(16), clay.SizingGrow()},
				childAlignment = {x = .Center, y = .Center},
			},
		}) {
			label(git.kind_letter(e.kind), git_kind_color(e.kind), FONT_SIZE_SMALL, .Bold)
		}
	}
	tooltip(id, e.path)

	if clicked(id, list) && !on_row_button(p, key) {
		set_selected(gv, key)
		if gv.chosen == nil {
			gv.chosen = Git_Row_Key{key.area, strings.clone(key.path)}
		}
	}
}


// Stage, unstage and discard, as the row's area allows
@(private = "file")
row_buttons :: proc(p: ^Pane, row: Git_Row, list: clay.ElementId) {
	h := row_hash(p, row_key(row))
	file := row.entry != nil

	if row.area == .Changes || row.area == .Untracked {
		tip := file ? "Discard changes" : "Discard all changes"
		if row.area == .Untracked {
			tip = file ? "Delete file" : "Delete all untracked files"
		}
		if icon_button(clay.ID("GitDiscard", h), .Undo, 18, 13, tip) {
			discard_row(row)
		}
	}

	if row.area == .Staged {
		tip := file ? "Unstage" : "Unstage all"
		if icon_button(clay.ID("GitUnstage", h), .Minus, 18, 13, tip) {
			stage_or_unstage(row)
		}
	} else {
		tip := file ? "Stage" : "Stage all"
		if row.area == .Conflicts {
			tip = file ? "Mark resolved" : "Mark all resolved"
		}
		if icon_button(clay.ID("GitStage", h), .Plus, 18, 13, tip) {
			stage_or_unstage(row)
		}
	}
}


// Whether the pointer is on one of a row's buttons, which take the click
@(private = "file")
on_row_button :: proc(p: ^Pane, key: Git_Row_Key) -> bool {
	h := row_hash(p, key)
	return pointer_in(clay.ID("GitDiscard", h)) ||
	       pointer_in(clay.ID("GitUnstage", h)) ||
	       pointer_in(clay.ID("GitStage", h))
}


// A row's id: its pane, area and path, so a press matched against last
// frame's layout finds the same file after the list changed
@(private = "file")
row_hash :: proc(p: ^Pane, key: Git_Row_Key) -> u32 {
	seed := [2]u32{p.id, u32(key.area)}
	h := hash.fnv32a(([^]u8)(&seed)[:size_of(seed)])
	return hash.fnv32a(transmute([]u8)key.path, h)
}


@(private = "file")
same_row :: proc(a, b: Git_Row_Key) -> bool {
	return a.area == b.area && a.path == b.path
}
