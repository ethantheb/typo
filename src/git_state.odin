package editor

// Git in the app: the repository the workspace folder is in, followed by
// package git's worker thread. The worker opens the repository when the folder
// opens, refreshes the status when the file watcher reports changes in the work
// tree (git_workspace_changed) and on its own when the repository's files
// change. Each frame git_frame takes its events: the status the Git pane
// (git_pane.odin) and diff views (diff_view.odin) show, and how commands went.
// Staging, unstaging and discarding are requests to the worker; commit, push,
// pull and fetch run the git command line on its command thread

import "core:fmt"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "git"
import "gfx"
import "uitime"


Git_State :: struct {
	worker:  git.Worker,
	running: bool,
	info:    git.Repo_Info, // owned; info.workdir is "" outside a repository
	status:  git.Status,    // the latest, empty until one arrives
	loaded:  bool,          // a status of this repository arrived
	problem: string,        // owned; why the folder's repository couldn't open
	remote:  Maybe(git.Remote_Op), // a command under way
	since:   u64,           // when it started (SDL ticks, ns)
	ticker:  sdl.TimerID,   // wakes the loop each second while it runs, for its time
	note:    Git_Note,      // how the last command went, shown in the pane

	// History (the Git pane's HISTORY section)
	log:       git.Log,           // the branch's commits, as of `log_head`
	log_head:  string,            // owned; the HEAD the log was last asked for at
	detail:    git.Commit_Detail, // the open commit's message and files, once read
	detail_id: Maybe(git.Oid),    // the commit open in the section
	detail_at: int,               // where it is in the log; -1 for none
}

// A line the Git pane shows under its buttons; one saying a command went
// through goes after GIT_NOTE_SHOW
Git_Note :: struct {
	text:  string, // owned
	error: bool,
	at:    u64,    // when it was set (SDL ticks, ns)
}

// How long a note that a command went through shows
GIT_NOTE_SHOW :: 6 * 1_000_000_000 // ns

// Git's share of the UI thread, which the perf suite limits
@(thread_local)
git_ui: uitime.Share

// Output a failed command's dialog shows, at most
@(private = "file")
GIT_OUTPUT_LINES :: 12


git_init :: proc() {
	git.worker_start(&g.git.worker, wake_main_loop, nil)
	g.git.running = true
	g.git.detail_at = -1
}


git_destroy :: proc() {
	gs := &g.git
	if gs.running do git.worker_stop(&gs.worker)
	remote_ended()
	git.repo_info_destroy(&gs.info)
	git.status_destroy(&gs.status)
	history_forget()
	delete(gs.problem)
	delete(gs.note.text)
	gs^ = {}
}


// Drops the history and the open commit (another repository, or quitting)
@(private = "file")
history_forget :: proc() {
	gs := &g.git
	git.log_destroy(&gs.log)
	git.commit_detail_destroy(&gs.detail)
	delete(gs.log_head)
	gs.log_head = ""
	gs.detail_id = nil
	gs.detail_at = -1
}


// A new workspace folder: the repository it is in, if any, is looked for
git_open_folder :: proc(folder: string) {
	gs := &g.git
	if !gs.running do return

	git.repo_info_destroy(&gs.info)
	git.status_destroy(&gs.status)
	history_forget()
	gs.loaded = false
	git_set_note("", false)
	git.worker_set_folder(&gs.worker, folder)

	// A command under way is the old repository's: its result is dropped
	remote_ended()

	// Diffs of the repository before close
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		p := g.panes.open[i]
		_, is_diff := p.content.(^Diff_View)
		if is_diff do pane_close(p, ask = false)
	}
}


// The watcher saw files change in the workspace: the status may have
git_workspace_changed :: proc() {
	gs := &g.git
	if gs.running && gs.info.workdir != "" {
		git.worker_refresh(&gs.worker)
	}
}


// Whether the workspace is in a repository
git_available :: proc() -> bool {
	return g.git.info.workdir != ""
}


// Whether the worker still has requests or a refresh under way (tests and the
// perf suite wait for it)
git_busy :: proc() -> bool {
	return g.git.running && git.worker_busy(&g.git.worker)
}


// Takes the worker's events: the repository found, a new status (the diff
// views follow it), and how requests and commands went
git_frame :: proc() {
	uitime.timed(&git_ui)
	gs := &g.git
	if !gs.running do return

	for &e in git.worker_take(&gs.worker) {
		switch &x in e {
		case git.Repo_Opened:
			git.repo_info_destroy(&gs.info)
			gs.info = x.info
			x.info = {}
			set_string(&gs.problem, "")

		case git.Repo_None:
			git.repo_info_destroy(&gs.info)
			git.status_destroy(&gs.status)
			gs.loaded = false
			set_string(&gs.problem, x.problem)

		case git.Status_Ready:
			git.status_destroy(&gs.status)
			gs.status = x.status
			gs.loaded = true
			x.status = {}
			diff_views_follow_status()

		case git.Op_Failed:
			git_set_note(x.message, true)

		case git.Remote_Done:
			remote_done(&x)

		case git.Log_Ready:
			git.log_destroy(&gs.log)
			gs.log = x.log
			x.log = {}

			// The open commit's place, or closed if HEAD moved off it (an amend,
			// a reset, a rebase)
			if id, open := gs.detail_id.?; open {
				gs.detail_at = log_index(id)
				if gs.detail_at < 0 do commit_close()
			}

		case git.Commit_Ready:
			// Only the commit still open; one that couldn't be read closes
			id, open := gs.detail_id.?
			switch {
			case !open || id != x.detail.id:
			case x.detail.failed:
				commit_close()
			case:
				git.commit_detail_destroy(&gs.detail)
				gs.detail = x.detail
				x.detail = {}
			}
		}
		git.event_destroy(&e)
	}
}


// Sets the line under the Git pane's buttons ("" for none). One that isn't an
// error goes after GIT_NOTE_SHOW: a timer wakes the loop then
git_set_note :: proc(text: string, error: bool) {
	set_string(&g.git.note.text, text)
	g.git.note.error = error
	g.git.note.at = sdl.GetTicksNS()
	if text != "" && !error {
		_ = sdl.AddTimer(GIT_NOTE_SHOW / 1_000_000 + 50, note_expired, nil)
	}
}


// The note to show under the buttons, or "" once a success's has had its time
// (a command's stays while it runs)
git_note_shown :: proc() -> string {
	n := &g.git.note
	finished := !n.error && g.git.remote == nil
	if finished && sdl.GetTicksNS() - n.at > GIT_NOTE_SHOW do return ""
	return n.text
}


@(private = "file")
note_expired :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return 0
}


// --- History -----------------------------------------------------------------------

// The Git pane shows its history: the log is asked for again whenever HEAD
// moved since it was last asked for (a commit, a checkout, a pull)
git_history_follow :: proc() {
	uitime.timed(&git_ui)
	gs := &g.git
	if !gs.running || !gs.loaded || gs.status.unborn {
		return
	}
	if gs.log_head == gs.status.head do return

	set_string(&gs.log_head, gs.status.head)
	git.worker_post(&gs.worker, git.Read_Log{git.LOG_LIMIT})
}


// Opens a commit in the history (its message and files are read), or closes
// it if it is the one open
git_commit_toggle :: proc(id: git.Oid) {
	uitime.timed(&git_ui)
	gs := &g.git
	open, is_open := gs.detail_id.?
	commit_close()
	if is_open && open == id do return

	gs.detail_at = log_index(id)
	if gs.detail_at < 0 do return
	gs.detail_id = id
	git.worker_post(&gs.worker, git.Read_Commit{id})
}


// Closes the open commit, freeing its files (not while a frame declares them)
@(private = "file")
commit_close :: proc() {
	gs := &g.git
	git.commit_detail_destroy(&gs.detail)
	gs.detail_id = nil
	gs.detail_at = -1
}


// Where a commit is in the log, or -1
@(private = "file")
log_index :: proc(id: git.Oid) -> int {
	for c, i in g.git.log.commits {
		if c.id == id do return i
	}
	return -1
}


// Whether the open commit's files are in (else they are being read)
git_commit_loaded :: proc() -> bool {
	id, open := g.git.detail_id.?
	return open && g.git.detail.id == id
}


// --- Changing the repository -------------------------------------------------------

// Stages files (paths relative to the work tree)
git_stage :: proc(paths: []string) {
	uitime.timed(&git_ui)
	if len(paths) == 0 do return
	git.worker_post(&g.git.worker, git.Stage{paths = clone_strings(paths)})
}


// Unstages files; a rename's old path comes along
git_unstage :: proc(entries: []git.Entry) {
	uitime.timed(&git_ui)
	paths := make([dynamic]string, context.temp_allocator)
	for e in entries {
		append(&paths, e.path)
		if e.old_path != "" do append(&paths, e.old_path)
	}
	if len(paths) == 0 do return
	git.worker_post(&g.git.worker, git.Unstage{paths = clone_strings(paths[:])})
}


// Asks before discarding the changes of files: those of tracked files go back
// to the staged version, untracked files are deleted
git_discard_ask :: proc(entries: []git.Entry) {
	tracked := make([dynamic]string, context.temp_allocator)
	untracked := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.area == .Untracked {
			append(&untracked, e.path)
		} else if e.area == .Changes {
			append(&tracked, e.path)
		}
	}
	total := len(tracked) + len(untracked)
	if total == 0 do return

	// What is lost, in words
	title := fmt.tprintf("Discard %d files?", total)
	if total == 1 {
		title = fmt.tprintf("Discard %s?", git_file_name(entries[0].path))
	}
	message: string
	switch {
	case len(untracked) == 0:
		message = "The changes go back to the staged version. This can't be undone."
	case len(tracked) == 0 && len(untracked) == 1:
		message = fmt.tprintf("The untracked file is moved to the %s.", TRASH_NAME)
	case len(tracked) == 0:
		message = fmt.tprintf("The untracked files are moved to the %s.", TRASH_NAME)
	case:
		message = fmt.tprintf(
			"Changes go back to the staged version (this can't be undone); untracked " +
			"files are moved to the %s.",
			TRASH_NAME,
		)
	}

	purpose := Git_Discarding{
		tracked   = clone_strings(tracked[:]),
		untracked = clone_strings(untracked[:]),
	}
	buttons := []Dialog_Button{{"Discard", .Danger}, {"Cancel", .Normal}}
	dialog_show(title, message, .Trash, buttons, 1, 1, purpose)
}


// The discard dialog's answer
git_discard_answer :: proc(d: Git_Discarding, confirmed: bool) {
	uitime.timed(&git_ui)
	if !confirmed do return

	w := &g.git.worker
	if len(d.tracked) > 0 do git.worker_post(w, git.Discard{paths = clone_strings(d.tracked)})
	if len(d.untracked) > 0 {
		request := git.Delete_Untracked{paths = clone_strings(d.untracked), to_trash = true}
		git.worker_post(w, request)
	}
}


// Replaces bytes [lo, hi) of a file's staged text, which must still be `base`
// (staging or unstaging a hunk)
git_splice_index :: proc(rel: string, base: git.Oid, lo, hi: int, text: []u8) {
	uitime.timed(&git_ui)
	splice := git.Splice_Index{
		path = strings.clone(rel),
		base = base,
		lo   = lo,
		hi   = hi,
		text = clone_bytes(text),
	}
	git.worker_post(&g.git.worker, splice)
}


// Commits the staged changes with a message. False if it can't start: no
// message, nothing staged, or a command still runs
git_commit :: proc(message: string) -> bool {
	uitime.timed(&git_ui)
	gs := &g.git
	if !git_can_commit(message) do return false

	args := git.op_args(.Commit, &gs.status)
	if !git.worker_run(&gs.worker, .Commit, args, message) do return false

	remote_started(.Commit)
	return true
}


// Whether a commit could start: a message, something staged, no command running
git_can_commit :: proc(message: string) -> bool {
	gs := &g.git
	return gs.remote == nil &&
	       gs.status.counts[.Staged] > 0 &&
	       strings.trim_space(message) != ""
}


// Pushes, pulls or fetches. False if a command still runs
git_remote :: proc(op: git.Remote_Op) -> bool {
	uitime.timed(&git_ui)
	gs := &g.git
	if gs.remote != nil || !git_available() {
		return false
	}

	args := git.op_args(op, &gs.status)
	if !git.worker_run(&gs.worker, op, args) do return false

	remote_started(op)
	return true
}


// Ends the push, pull or fetch under way. A commit isn't ended: killed in its
// middle, git can leave the index locked
git_remote_cancel :: proc() {
	if !git_can_cancel() do return
	git.worker_cancel(&g.git.worker)
}


// Whether the command under way can be cancelled
git_can_cancel :: proc() -> bool {
	op, running := g.git.remote.?
	return running && op != .Commit
}


// How long the command under way has run, in whole seconds
git_remote_seconds :: proc() -> int {
	if g.git.remote == nil do return 0
	return int((sdl.GetTicksNS() - g.git.since) / 1_000_000_000)
}


// A command started: the note says so, and counts its seconds
@(private = "file")
remote_started :: proc(op: git.Remote_Op) {
	gs := &g.git
	gs.remote = op
	gs.since = sdl.GetTicksNS()
	gs.ticker = sdl.AddTimer(1000, remote_tick, nil)
	git_set_note(remote_doing(op), false)
}


@(private = "file")
remote_tick :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return interval
}


// The command under way ended, or the folder changed under it
@(private = "file")
remote_ended :: proc() {
	gs := &g.git
	gs.remote = nil
	if gs.ticker != 0 {
		_ = sdl.RemoveTimer(gs.ticker)
		gs.ticker = 0
	}
}


// A command finished: the note says how; a failure shows git's words, and a
// push, pull or fetch that failed can run in a terminal instead
@(private = "file")
remote_done :: proc(d: ^git.Remote_Done) {
	remote_ended()

	if d.cancelled {
		git_set_note(fmt.tprintf("%s cancelled", remote_name(d.op)), false)
		return
	}

	if d.ok {
		git_set_note(remote_did(d.op), false)
		if d.op == .Commit do git_pane_committed()
		return
	}

	git_set_note(fmt.tprintf("%s failed", remote_name(d.op)), true)
	output := last_lines(d.output, GIT_OUTPUT_LINES)
	if output == "" do output = "git gave no reason."
	if g.dialog.open do return

	title := fmt.tprintf("%s failed", remote_name(d.op))
	if d.op == .Commit {
		show_notice(title, output)
		return
	}

	message := output
	if d.auth {
		hint := "It needs credentials typo can't ask for. Run it in a terminal to give them."
		message = fmt.tprintf("%s\n\n%s", output, hint)
	}
	purpose := Git_Remote_Failed{line = strings.clone(d.line)}
	buttons := []Dialog_Button{{"Run in terminal", .Primary}, {"Close", .Normal}}
	dialog_show(title, message, .Alert, buttons, 0, 1, purpose)
}


// The failed command dialog's answer: the command in a new terminal
git_remote_failed_answer :: proc(d: Git_Remote_Failed, run: bool) {
	if run do panes_run_in_terminal(d.line)
}


@(private = "file")
remote_name :: proc(op: git.Remote_Op) -> string {
	switch op {
	case .Commit: return "Commit"
	case .Push:   return "Push"
	case .Pull:   return "Pull"
	case .Fetch:  return "Fetch"
	}
	return ""
}


@(private = "file")
remote_doing :: proc(op: git.Remote_Op) -> string {
	switch op {
	case .Commit: return "Committing…"
	case .Push:   return "Pushing…"
	case .Pull:   return "Pulling…"
	case .Fetch:  return "Fetching…"
	}
	return ""
}


@(private = "file")
remote_did :: proc(op: git.Remote_Op) -> string {
	switch op {
	case .Commit: return "Committed"
	case .Push:   return "Pushed"
	case .Pull:   return "Pulled"
	case .Fetch:  return "Fetched"
	}
	return ""
}


// The last `n` lines of text (temp)
@(private = "file")
last_lines :: proc(text: string, n: int) -> string {
	text := strings.trim_space(text)
	count := 0
	for i := len(text) - 1; i >= 0; i -= 1 {
		if text[i] != '\n' do continue
		count += 1
		if count == n do return strings.clone(text[i + 1:], context.temp_allocator)
	}
	return strings.clone(text, context.temp_allocator)
}


// --- Paths -------------------------------------------------------------------------

// A file's full path from its path in the work tree (temp)
git_full_path :: proc(rel: string) -> string {
	return git.full_path(g.git.info.workdir, rel)
}


// The name of a path relative to the work tree
git_file_name :: proc(rel: string) -> string {
	slash := strings.last_index_byte(rel, '/')
	return rel[slash + 1:]
}


// The folder of a path relative to the work tree, "" at its top
git_file_folder :: proc(rel: string) -> string {
	slash := strings.last_index_byte(rel, '/')
	return slash < 0 ? "" : rel[:slash]
}


// The color of a change's letter and mark
git_kind_color :: proc(k: git.Kind) -> clay.Color {
	switch k {
	case .Added, .Untracked:    return gfx.theme.git_added
	case .Modified:             return gfx.theme.git_modified
	case .Deleted:              return gfx.theme.git_deleted
	case .Renamed, .Typechange: return gfx.theme.git_renamed
	case .Conflicted:           return gfx.theme.git_conflict
	}
	return gfx.theme.text_dim
}


@(private = "file")
clone_strings :: proc(list: []string) -> []string {
	out := make([]string, len(list))
	for s, i in list do out[i] = strings.clone(s)
	return out
}


@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}


// --- Status bar --------------------------------------------------------------------

// The branch and how many files changed, at the left of the status bar while
// the workspace is in a repository; a click opens the Git pane
git_status_item :: proc() {
	gs := &g.git
	if !git_available() do return

	branch := gs.status.branch
	if branch == "" do branch = gs.status.head
	if branch == "" do branch = "Git"
	changed := len(gs.status.entries)

	id := clay.ID("GitStatus")
	if clay.UI(id)({
		layout = {
			padding = {left = 6, right = 7, top = 1, bottom = 1},
			childGap = 5,
			childAlignment = {y = .Center},
		},
		backgroundColor = clay.Hovered() ? gfx.theme.hover : {},
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		icon(.Git_Branch, gfx.theme.text_dim, 13)
		label(branch, gfx.theme.text_dim, FONT_SIZE_SMALL)
		if changed > 0 {
			count_label(changed, gfx.theme.git_modified)
		}
	}

	tip := changed == 1 ? "1 change" : fmt.tprintf("%d changes", changed)
	if changed == 0 do tip = "No changes"
	tooltip(id, fmt.tprintf("Git: %s", tip), first_chord_label(.Open_Git))
	if clicked(id) do defer_action(Run_Command(.Open_Git))
}
