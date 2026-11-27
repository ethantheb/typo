package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "diff"
import "gfx"
import "git"
import "process"

// Perf phases: the Git pane and diff views (git_pane.odin, diff_view.odin) on a
// repository of their own in the workspace's temp folder, opened as the
// workspace: its status, the pane's keys and message box, a diff of a large
// file loaded, scrolled and its hunks reverted and staged with their buttons.
// The workspace and the file open before come back at the end


@(private = "file")
WAIT_LIMIT :: 15 * time.Second

@(private = "file")
BIG_LINES :: 200_000

@(private = "file")
BIG_EVERY :: 1000 // a line in this many is changed

@(private = "file")
git_perf: struct {
	repo:   string, // owned; the repository's folder, "" when git isn't on PATH
	before: string, // owned; the file open before
	since:  time.Tick,
}


// A line of the large file, changed or as committed
@(private = "file")
big_line :: proc(sb: ^strings.Builder, i: int, changed: bool) {
	fmt.sbprintf(sb, "\tvalue_%d := compute(%d, %d) // line %d", i, i, i * 7, i)
	if changed do strings.write_string(sb, " changed")
	strings.write_byte(sb, '\n')
}


// The large file's text: committed, or with every BIG_EVERY-th line changed
@(private = "file")
big_text :: proc(changed: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "package big\n\n")
	for i in 0 ..< BIG_LINES {
		big_line(&sb, i, changed && i % BIG_EVERY == 0)
	}
	return strings.to_string(sb)
}


@(private = "file")
perf_git :: proc(dir: string, args: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "git")
	append(&all, ..args)
	_, output := git.run(all[:], dir, nil, context.temp_allocator)
	return output
}


@(private = "file")
repo_file :: proc(name: string) -> string {
	return fmt.tprintf("%s%c%s", git_perf.repo, os.Path_Separator, name)
}


// The Git pane, or nil
@(private = "file")
perf_git_view :: proc() -> ^Git_View {
	p := git_pane()
	if p == nil do return nil
	return p.content.(^Git_View)
}


// The diff pane, or nil
@(private = "file")
perf_diff_view :: proc() -> (^Pane, ^Diff_View) {
	for p in g.panes.open {
		dv, ok := p.content.(^Diff_View)
		if ok do return p, dv
	}
	return nil, nil
}


@(private = "file")
git_waiting :: proc(done: bool) -> bool {
	return !done && time.tick_since(git_perf.since) < WAIT_LIMIT
}


// A press on an element laid out last frame, as the mouse would
@(private = "file")
click_element :: proc(id: clay.ElementId) -> bool {
	r, found := element_rect(id)
	if !found do return false

	g.mouse_pos = {r.x + r.w / 2, r.y + r.h / 2}
	g.mouse_pressed = true
	g.mouse_clicks = 1
	return true
}


// The repository with a large file and small ones, committed, then changed in
// each way the pane lists; then it becomes the workspace and the Git pane opens
phase_git_pane :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	gp := &git_perf

	if frame == 0 {
		step = 0
		if process.find_executable("git", context.temp_allocator) == "" {
			check(p, "git is on PATH", false)
			return true
		}

		// The repository, committed
		gp.repo = strings.clone(path_in_dir(p, "git-repo"))
		_ = os.remove_all(gp.repo)
		_ = os.make_directory_all(gp.repo)
		perf_git(gp.repo, "init", "-q", "-b", "main")
		perf_git(gp.repo, "config", "user.name", "Typo Perf")
		perf_git(gp.repo, "config", "user.email", "perf@example.com")
		perf_git(gp.repo, "config", "core.autocrlf", "false")
		_ = os.write_entire_file(repo_file("big.odin"), big_text(changed = false))
		_ = os.write_entire_file(repo_file("main.odin"), "package big\n\nmain :: proc() {}\n")
		_ = os.write_entire_file(repo_file("notes.md"), "# Notes\n\nFirst.\n")
		perf_git(gp.repo, "add", "-A")
		perf_git(gp.repo, "commit", "-q", "-m", "first")

		// Changed, staged and untracked
		_ = os.write_entire_file(repo_file("big.odin"), big_text(changed = true))
		_ = os.write_entire_file(repo_file("main.odin"), "package big\n\nmain :: proc() {\n}\n")
		_ = os.write_entire_file(repo_file("notes.md"), "# Notes\n\nFirst.\nSecond.\n")
		perf_git(gp.repo, "add", "notes.md")
		_ = os.write_entire_file(repo_file("new.txt"), "new\n")

		// The repository as the workspace
		if e := focused_editor(); e != nil {
			gp.before = strings.clone(e.path)
		}
		close_files()
		open_folder(gp.repo)
		gp.since = time.tick_now()
		return false
	}

	s := &g.git.status
	switch step {
	case 0: // the repository and its status
		counted := s.counts[.Staged] == 1 && s.counts[.Changes] == 2 && s.counts[.Untracked] == 1
		ready := git_available() && g.git.loaded && counted
		if git_waiting(ready) do return false

		check(p, "the workspace's repository opens with its status", ready)
		result(p, "status after opening", ms_since(gp.since), "ms", 3000)
		check(p, "the branch is known", s.branch == "main" && len(s.head) == git.SHORT_ID)
		run_command(.Open_Git)

		// A message set before the box was ever laid out (typo ctl git message)
		if gv := perf_git_view(); gv != nil do text_area_set(&gv.message, "A draft message")
		p.mark_frame = frame
		step = 1

	case 1: // the pane, focused with its message box, once it settled
		if frame < p.mark_frame + 3 || g.animating {
			return false
		}

		gp_pane := git_pane()
		gv := perf_git_view()
		focused := gp_pane != nil && g.panes.focused == gp_pane && gv.typing
		check(p, "Open Git pane opens it, its message box with the keys", focused)
		if gv == nil do return true

		_, bar := element_rect(clay.ID("GitStatus"))
		_, list := element_rect(clay.ID("GitFiles", gp_pane.id))
		check(p, "the status bar shows the branch, the pane its files", bar && list)
		check(p, "nothing to commit without a message", !git_can_commit(""))
		in_view := gv.message.scroll_x == 0 && gv.message.view.w > 0
		check(p, "a message set before the box's first layout stays in view", in_view)
		text_area_clear(&gv.message)

		// A message typed, then the list's keys
		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "Perf commit"
		handle_key_event(&event)
		message := text_area_string(&gv.message)
		check(p, "typing goes to the message box", message == "Perf commit")
		check(p, "a message and staged changes can commit", git_can_commit(message))

		press_key(sdl.K_ESCAPE)
		press_key(sdl.K_DOWN)
		press_key(sdl.K_DOWN)
		moved := !gv.typing && gv.selected.area == .Staged && gv.selected.path == "notes.md"
		check(p, "Esc leaves the box; Down selects rows", moved)

		// Opening it again focuses the one there is
		run_command(.Open_Git)
		panes := 0
		for q in g.panes.open {
			_, is_git := q.content.(^Git_View)
			if is_git do panes += 1
		}
		check(p, "Open Git pane again keeps one Git pane", panes == 1)

		// The large file's diff
		git_open_diff("big.odin", .Changes, focus = true)
		gp.since = time.tick_now()
		step = 2

	case 2: // the diff loaded
		_, dv := perf_diff_view()
		ready := dv != nil && dv.status == .Ready && dv.areas[.Right].w > 0
		if git_waiting(ready) do return false

		check(p, "a diff of the large file loads", ready)
		if dv == nil do return true
		result(p, "diff of the large file shown after", ms_since(gp.since), "ms", 5000)

		hunks := BIG_LINES / BIG_EVERY
		counted := len(dv.rows.hunks) == hunks && dv.added == hunks && dv.removed == hunks
		check(p, "each changed line is a hunk, side by side", counted)
		if len(dv.rows.hunks) == 0 do return true

		h := dv.rows.hunks[0]
		row := diff.row_at(&dv.rows, dv.rows.starts[0])
		paired := h.old_hi - h.old_lo == 1 && row.kind == .Changed && row.old == row.new
		check(p, "a changed line is paired with its old one", paired)
		check(p, "changed words are found", len(dv.right_words) == hunks)
		return true
	}
	return false
}


// Scrolling the large diff with the keys, a few lines each frame
phase_git_diff_scroll :: proc(p: ^Perf, frame: int) -> bool {
	pane, dv := perf_diff_view()
	if dv == nil || dv.status != .Ready {
		check(p, "the diff is open", false)
		return true
	}
	if frame == 0 do pane_focus(pane)

	FRAMES :: 240
	if frame < FRAMES {
		press_key(frame % 40 == 39 ? sdl.K_PAGEDOWN : sdl.K_DOWN)
		return false
	}

	check(p, "the keys scroll the diff", dv.target_y > 0 && dv.scroll_y > 0)

	// Next problem (F8) goes to the next change
	before := dv.target_y
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .F8
	event.key.key = sdl.GetKeyFromScancode(.F8, {}, true)
	handle_key_event(&event)
	check(p, "F8 goes to the next change", dv.target_y > before)
	return true
}


// The hunk buttons, clicked: the first hunk reverted in the file on disk (no
// editor has it open), the next staged. Then the workspace comes back
phase_git_hunks :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) hunks: int
	gp := &git_perf
	pane, dv := perf_diff_view()

	if frame == 0 {
		step = 0
		if dv == nil || dv.status != .Ready {
			check(p, "the diff is open", false)
			git_perf_end()
			return true
		}
		hunks = len(dv.rows.hunks)
		dv.scroll_y, dv.target_y = 0, 0
		return false
	}

	switch step {
	case 0: // the first hunk's arrow
		if frame < 3 do return false // laid out at the top

		key := u32(pane.id) << 20 | 0
		check(p, "the first hunk has its buttons", click_element(clay.ID("DiffRevert", key)))
		gp.since = time.tick_now()
		step = 1

	case 1: // reverted on disk, and the diff loads again
		reverted := dv.status == .Ready && len(dv.rows.hunks) == hunks - 1
		if git_waiting(reverted) do return false

		check(p, "the arrow reverts its hunk, and the diff follows", reverted)
		data, _ := os.read_entire_file(repo_file("big.odin"), context.temp_allocator)
		first := strings.contains(string(data), "// line 0\n")
		check(p, "the file on disk has the old line back", first)
		result(p, "reverted and shown again after", ms_since(gp.since), "ms", 5000)

		// The next hunk at the top
		lh := f64(diff_line_height(dv))
		dv.scroll_y = f64(dv.rows.starts[0]) * lh
		dv.target_y = dv.scroll_y
		p.mark_frame = frame
		step = 2

	case 2: // its +, once laid out there
		if frame < p.mark_frame + 3 do return false

		key := u32(pane.id) << 20 | 0
		check(p, "the next hunk stages", click_element(clay.ID("DiffStageHunk", key)))
		gp.since = time.tick_now()
		step = 3

	case 3: // staged: the large file is in both lists
		s := &g.git.status
		_, staged := git.find_entry(s, .Staged, "big.odin")
		_, changed := git.find_entry(s, .Changes, "big.odin")
		both := staged && changed
		if git_waiting(both) do return false

		// The staged diff: one hunk, the line staged
		check(p, "+ stages only its hunk", both)
		cached := perf_git(gp.repo, "diff", "--cached", "--unified=0", "--no-color", "big.odin")
		one_hunk := strings.count(cached, "\n@@") == 1
		has_line := strings.contains(cached, "// line 1000 changed")
		check(p, "the index has just the staged line", one_hunk && has_line)
		return true
	}
	return false
}


@(private = "file")
NARROW :: 120 // narrower than either pane's content


// The Git pane, then the diff pane, narrower than their content: each is cut
// off at its edge, nothing of it shows beside it, and a button laid out past
// the edge doesn't take a press there
phase_git_narrow :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) mouse: [2]f32
	git_p := git_pane()
	diff_p, _ := perf_diff_view()

	if frame == 0 {
		step = 0
		mouse = g.mouse_pos
		laid_out := git_p != nil && diff_p != nil && narrow_pane(git_p, first = true)
		check(p, "the Git and diff panes are side by side", laid_out)
		if !laid_out {
			git_perf_end()
			return true
		}
		p.mark_frame = frame
		return false
	}
	if frame < p.mark_frame + 3 || g.animating {
		return false
	}

	switch step {
	case 0: // the Git pane narrow: the gap right of it read back
		check(p, "the Git pane is narrower than its content", git_p.rect.w < GIT_MIN_WIDTH)
		want_frame(p, gap_right_of(git_p))
		p.mark_frame = frame
		step = 1

	case 1: // nothing beside it; a press on Fetch, laid out past its edge
		check(p, "nothing of the Git pane shows beside it", read_back_clean(p))

		fetch, found := element_rect(clay.ID("GitFetch"))
		past := found && fetch.x > git_p.rect.x + git_p.rect.w
		check(p, "its controls go on past its edge", past)
		git_set_note("", false) // any command run sets it
		click_element(clay.ID("GitFetch"))
		p.mark_frame = frame
		step = 2

	case 2: // the press went to the diff pane; then the diff pane narrow
		ran := g.git.remote != nil || g.git.note.text != "" || g.dialog.open
		missed := !ran && g.panes.focused == diff_p
		check(p, "a button past the edge doesn't take a press there", missed)
		g.mouse_pos = mouse
		narrow_pane(diff_p, first = false)
		p.mark_frame = frame
		step = 3

	case 3:
		check(p, "the diff pane is narrower than its content", diff_p.rect.w < DIFF_MIN_WIDTH)
		want_frame(p, gap_right_of(diff_p))
		p.mark_frame = frame
		step = 4

	case 4:
		check(p, "nothing of the diff pane shows beside it", read_back_clean(p))
		return true
	}
	return false
}


// The history: the branch's commits listed, the newest opened to its files,
// one file's commit diff opened (nothing in it stages or reverts), the diff's
// divider dragged left; another commit clicked while one is open (its rows
// were declared with the open one's strings); the open commit amended away,
// which closes it. The workspace of before comes back at the end
phase_git_history :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) left_before: f32
	gs := &g.git
	_, dv := perf_diff_view()

	if frame == 0 {
		step = 0
		git_perf.since = time.tick_now()

		// A second commit (what the Git pane's phase staged); the panes wide again
		perf_git(git_perf.repo, "commit", "-q", "-m", "second")
		if t := tile_find(g.panes.root, git_pane()); t != nil && t.parent != nil {
			t.parent.ratio = 0.4
		}
		return false
	}

	switch step {
	case 0: // the log, read once the pane shows
		listed := len(gs.log.commits) == 2
		if git_waiting(listed) do return false

		check(p, "the history lists the branch's commits", listed)
		if !listed {
			git_perf_end()
			return true
		}
		summaries := gs.log.commits[0].summary == "second" && gs.log.commits[1].summary == "first"
		check(p, "newest first, with each one's summary", summaries)
		git_commit_toggle(gs.log.commits[0].id)
		git_perf.since = time.tick_now()
		step = 1

	case 1: // its files, then one's commit diff
		if git_waiting(git_commit_loaded()) do return false

		files := len(gs.detail.files)
		check(p, "a commit opens to the files it changed", files > 0)
		if files == 0 {
			git_perf_end()
			return true
		}
		git_open_commit_diff(gs.detail.files[0].path, gs.detail.id, focus = false)
		git_perf.since = time.tick_now()
		step = 2

	case 2: // the commit diff, laid out; its divider taken
		_, dv = perf_diff_view()
		ready := dv != nil && dv.commit != nil && dv.status == .Ready && dv.areas[.Left].w > 0
		if git_waiting(ready && !g.animating) do return false

		check(p, "a file of it opens as the commit's diff", ready)
		if !ready {
			git_perf_end()
			return true
		}
		revert, stage := hunk_actions_of(dv)
		check(p, "nothing in a commit's diff stages or reverts", !revert && !stage)

		left, right := dv.areas[.Left], dv.areas[.Right]
		left_before = left.w
		g.mouse_pos = {(left.x + left.w + right.x) / 2, left.y + left.h - 20}
		g.mouse_down, g.mouse_pressed, g.mouse_clicks = true, true, 1
		step = 3

	case 3: // dragged left
		g.mouse_pos.x -= 120
		step = 4

	case 4: // let go
		g.mouse_down = false
		p.mark_frame = frame
		step = 5

	case 5: // the divider moved; then a press on the older commit, under the open
		// one's file rows
		if frame < p.mark_frame + 2 do return false
		moved := dv != nil && dv.split > 0 && dv.areas[.Left].w < left_before - 80
		check(p, "the divider between a diff's sides drags", moved)

		header, found := element_rect(clay.ID("GitHistory", git_pane().id))
		rows := 1 + len(gs.detail.files) // the newest commit and its files, under the header
		older_y := header.y + f32(1 + rows) * GIT_ROW_HEIGHT + GIT_ROW_HEIGHT / 2
		check(p, "the history is laid out", found)
		g.mouse_pos = {header.x + 60, older_y}
		g.mouse_pressed, g.mouse_clicks = true, 1
		git_perf.since = time.tick_now()
		step = 6

	case 6: // the older commit open (and nothing freed under the frame)
		older := gs.log.commits[1].id
		open, has_open := gs.detail_id.?
		switched := has_open && open == older && git_commit_loaded()
		if git_waiting(switched) do return false
		check(p, "clicking another commit opens it instead", switched)

		// The newest open again, then amended away
		git_commit_toggle(gs.log.commits[0].id)
		perf_git(git_perf.repo, "commit", "-q", "--amend", "-m", "second, amended")
		git_perf.since = time.tick_now()
		step = 7

	case 7: // the log read again without it: it closes, and no rows are left over
		amended := len(gs.log.commits) == 2 && gs.log.commits[0].summary == "second, amended"
		closed := gs.detail_id == nil && gs.detail_at == -1
		if git_waiting(amended && closed) do return false
		check(p, "a commit HEAD moved off closes", amended && closed)
		git_perf_end()
		return true
	}
	return false
}


// Splits the pane's row so the pane is NARROW wide; false if it isn't in a row
@(private = "file")
narrow_pane :: proc(pane: ^Pane, first: bool) -> bool {
	t := tile_find(g.panes.root, pane)
	if t == nil || t.parent == nil || t.parent.axis != .Row {
		return false
	}
	if (t.parent.children[0] == t) != first do return false

	share := NARROW / t.parent.rect.w
	t.parent.ratio = first ? share : 1 - share
	return true
}


// The gap right of a pane, clear of its edge and corners
@(private = "file")
gap_right_of :: proc(pane: ^Pane) -> gfx.Rect {
	r := pane.rect
	return {r.x + r.w + 1.5, r.y + PANE_RADIUS, PANE_GAP - 3, r.h - 2 * PANE_RADIUS}
}


// Whether every pixel read back (want_frame) is the window's color
@(private = "file")
read_back_clean :: proc(p: ^Perf) -> bool {
	if len(p.read_back) == 0 do return false

	bg := gfx.theme.panel
	for px in p.read_back {
		differs := abs(int(px[0]) - int(bg.r)) > 8 ||
		           abs(int(px[1]) - int(bg.g)) > 8 ||
		           abs(int(px[2]) - int(bg.b)) > 8
		if differs do return false
	}
	return true
}


// Closes the Git and diff panes, and opens the workspace and file of before
@(private = "file")
git_perf_end :: proc() {
	gp := &git_perf
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		q := g.panes.open[i]
		#partial switch _ in q.content {
		case ^Git_View, ^Diff_View: pane_close(q, ask = false)
		}
	}

	open_folder(g.perf.dir)
	if gp.before != "" do open_loaded(gp.before)
	if gp.repo != "" do _ = os.remove_all(gp.repo)

	delete(gp.before)
	delete(gp.repo)
	gp^ = {}
}


@(private = "file")
press_key :: proc(key: sdl.Keycode) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	handle_key_event(&event)
}
