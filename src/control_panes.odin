package editor

// Control requests that arrange the window (docs/agent_control.md): commands by
// name, files, terminals, moving, focusing and closing panes, diffs and the
// commit message. Each runs the code the UI runs, and none takes the focus
// unless asked

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "git"
import "ipc"
import "lsp"


// Commands `do` won't run: they need a person at the keys (a field waiting for
// typing) or touch the clipboard (Paste into `self` would type it into the
// agent)
@(private = "file")
DO_REFUSED :: bit_set[Command]{
	.Copy,
	.Cut,
	.Paste,
	.Find,
	.Rename,
	.Rename_Symbol,
	.Go_To_Line,
	.Find_File,
	.Open_Project,
	.Go_To_File_Symbol,
	.Go_To_Symbol,
	.Find_References,
}


// On the connection's thread: checks a pane request's arguments; why it can't
// go, or ""
panes_prepare :: proc(job: ^Control_Job) -> string {
	a := &job.args
	switch a.cmd {
	case "do":
		cmd, known := command_from_key(a.command)
		if !known do return fmt.tprintf("typo has no command %q", a.command)
		if cmd in DO_REFUSED {
			return fmt.tprintf("%s needs a person at the keys", a.command)
		}

	case "open":
		if !filepath.is_abs(a.path) do return "open needs a file"
		if problem := open_problem(a.path); problem != "" {
			return fmt.tprintf("%s: %s", a.path, problem)
		}

	case "diff":
		if !filepath.is_abs(a.path) do return "diff needs a file"

	case "git":
		if a.git != "open" && a.git != "message" do return "git takes open or message"
	}

	if a.side != "" && !side_known(a.side) do return fmt.tprintf("%q isn't a side", a.side)
	if a.edge != "" && !side_known(a.edge) do return fmt.tprintf("%q isn't a side", a.edge)
	return ""
}


// On the UI thread: applies a pane request and answers it
panes_apply :: proc(job: ^Control_Job) {
	a := &job.args
	problem := ""
	result := `{}`

	switch a.cmd {
	case "do":
		problem, result = do_apply(job)
	case "open":
		problem, result = open_apply(job)
	case "terminal":
		problem, result = terminal_apply(job)
	case "move":
		problem = move_apply(job)
	case "focus":
		problem = focus_apply(job)
	case "maximize":
		problem = maximize_apply(job)
	case "close":
		problem, result = close_apply(job)
	case "rename":
		problem = rename_apply(job)
	case "diff":
		problem, result = diff_apply(job)
	case "git":
		problem = git_apply(job)
	}

	if problem != "" {
		job_reply(job, .Error, ipc.error_json(problem))
	} else {
		job_reply(job, .Ok, result)
	}
}


// --- Commands ----------------------------------------------------------------------

// Runs a command as its keys would, on `--pane` if given (focused for it, the
// focus put back after unless the command moved it)
@(private = "file")
do_apply :: proc(job: ^Control_Job) -> (problem, result: string) {
	cmd, _ := command_from_key(job.args.command)
	ps := &g.panes

	before := ps.focused
	target: ^Pane
	if job.args.pane != "" {
		target = control_pane(job.args.pane, job.self)
		if target == nil do return no_pane(job.args.pane), ""
		pane_focus(target)
	}

	ran := run_command(cmd)

	// The focus back where it was, if the command left it on the target
	back := target != nil && ps.focused == target && before != nil && before != target
	if back && pane_is_open(before) && pane_shown(before) && ps.maximized == nil {
		ps.focused = before
	}
	return "", fmt.tprintf(`{{"ran":%v}}`, ran)
}


// --- Files -------------------------------------------------------------------------

// Opens a file in a pane of its own (or the one it's in): beside `--at`, else
// where `typo <file>` puts it; at a line if given
@(private = "file")
open_apply :: proc(job: ^Control_Job) -> (problem, result: string) {
	a := &job.args
	p := pane_for_file(a.path)
	if !pane_shown(p) {
		d, d_problem := drop_at(job, p)
		if d_problem != "" do return d_problem, ""
		if d.kind == .None do d = place_beside(p, nil)
		pane_move(p, d)
	}
	if a.focus do pane_focus(p)

	// The line, once its text is there
	if e, is_editor := p.content.(^Editor); is_editor && a.line > 0 {
		editor_when_ready(e, {target = line_target(a.line, a.col)})
	}
	return "", pane_json(p)
}


// --- Terminals ---------------------------------------------------------------------

// Starts a terminal: pinned or local as asked (else as new terminals are),
// named, running a command, beside `--at` or where new terminals go, or on the
// shelf (its shell starts once shown)
@(private = "file")
terminal_apply :: proc(job: ^Control_Job) -> (problem, result: string) {
	a := &job.args
	d, d_problem := drop_at(job, nil)
	if d_problem != "" do return d_problem, ""

	p := panes_add_terminal()
	t := p.content.(^Terminal)
	if a.pinned do t.persistent = true
	if a.local do t.persistent = false
	if a.name != "" do set_string(&p.name, a.name)
	if a.command != "" do t.command = strings.clone(a.command)

	if !a.hidden {
		if d.kind == .None do d = place_for(p)
		pane_move(p, d)
		if a.focus do pane_focus(p)
	}
	return "", pane_json(p)
}


// --- Arranging ---------------------------------------------------------------------

// Moves a pane beside another, to an edge of the work area, or to the shelf
@(private = "file")
move_apply :: proc(job: ^Control_Job) -> string {
	a := &job.args
	p := control_pane(a.pane, job.self)
	if p == nil do return no_pane(a.pane)

	d: Drop
	switch {
	case a.shelf:
		d = {kind = .Shelf}
	case a.edge != "":
		d = {kind = g.panes.root == nil ? .Fill : .Edge, side = side_of(a.edge)}
	case a.of != "":
		q := control_pane(a.of, job.self)
		if q == nil || !pane_shown(q) do return no_pane(a.of)
		if q == p do return "a pane can't go beside itself"
		d = {kind = .Split, target = q, side = side_of(a.side)}
	case:
		return "move needs --side and --of, --edge or --shelf"
	}

	pane_move(p, d)
	return ""
}


@(private = "file")
focus_apply :: proc(job: ^Control_Job) -> string {
	p := control_pane(job.args.pane, job.self)
	if p == nil do return no_pane(job.args.pane)

	pane_show(p)
	return ""
}


// Maximizes a pane, or with --off restores the one maximized
@(private = "file")
maximize_apply :: proc(job: ^Control_Job) -> string {
	ps := &g.panes
	if job.args.off {
		if ps.maximized != nil {
			pane_focus(ps.maximized)
			pane_toggle_maximized()
		}
		return ""
	}

	p := control_pane(job.args.pane, job.self)
	if p == nil || !pane_shown(p) do return no_pane(job.args.pane)
	if ps.maximized != p {
		pane_focus(p)
		pane_toggle_maximized()
	}
	return ""
}


// Closes a pane; one with unsaved changes or a program running asks the user
// first, as the user's own close does
@(private = "file")
close_apply :: proc(job: ^Control_Job) -> (problem, result: string) {
	p := control_pane(job.args.pane, job.self)
	if p == nil do return no_pane(job.args.pane), ""

	closed := pane_close(p)
	return "", closed ? `{"closed":true}` : `{"closed":false,"asking":true}`
}


// Names a terminal
@(private = "file")
rename_apply :: proc(job: ^Control_Job) -> string {
	p := control_pane(job.args.pane, job.self)
	if p == nil do return no_pane(job.args.pane)
	if !is_terminal(p) do return "only terminals are named this way"

	set_string(&p.name, job.args.name)
	return ""
}


// --- Git ---------------------------------------------------------------------------

// Opens a file's diff: staged, or its changes (untracked or in conflict as it
// is), where the Git pane opens diffs
@(private = "file")
diff_apply :: proc(job: ^Control_Job) -> (problem, result: string) {
	if !g.git.loaded do return "this folder has no repository (or its status isn't in yet)", ""

	rel := git_relative(job.args.path)
	area, found := file_area(rel, job.args.staged)
	if !found {
		what := job.args.staged ? "staged changes" : "changes"
		return fmt.tprintf("%s has no %s", rel, what), ""
	}

	git_open_diff(rel, area, job.args.focus)
	for p in g.panes.open {
		dv, is_diff := p.content.(^Diff_View)
		if is_diff && pane_shown(p) && diff_view_is(dv, job.args.path, area) {
			return "", pane_json(p)
		}
	}
	return "", `{}`
}


// The Git pane, shown; or its commit message set (the pane opened for it)
@(private = "file")
git_apply :: proc(job: ^Control_Job) -> string {
	if !git_available() && git_pane() == nil do return "this folder has no repository"

	p := git_pane()
	if p == nil {
		gv := new(Git_View)
		git_view_init(gv)
		p = panes_add_git(gv)
	}
	if !pane_shown(p) do pane_move(p, place_for_git(p))
	if job.args.git == "open" do return ""

	text_area_set(&p.content.(^Git_View).message, job.args.text)
	return ""
}


// A file's path in the work tree, with forward slashes (temp)
@(private = "file")
git_relative :: proc(path: string) -> string {
	rel, err := filepath.rel(g.git.info.workdir, path, context.temp_allocator)
	if err != nil do return path
	rel, _ = strings.replace_all(rel, `\`, "/", context.temp_allocator)
	return rel
}


// The area a file's diff shows: staged, else the first it is listed in
@(private = "file")
file_area :: proc(rel: string, staged: bool) -> (area: git.Area, found: bool) {
	for e in g.git.status.entries {
		if e.path != rel do continue
		if staged == (e.area == .Staged) do return e.area, true
	}
	return {}, false
}


// --- Helpers -----------------------------------------------------------------------

// Where `--at P --side S` puts a pane; kind None when not given
@(private = "file")
drop_at :: proc(job: ^Control_Job, p: ^Pane) -> (d: Drop, problem: string) {
	a := &job.args
	if a.at == "" do return {}, ""

	q := control_pane(a.at, job.self)
	if q == nil || !pane_shown(q) do return {}, no_pane(a.at)
	if q == p do return {}, "a pane can't go beside itself"
	return {kind = .Split, target = q, side = side_of(a.side)}, ""
}


@(private = "file")
side_known :: proc(name: string) -> bool {
	switch name {
	case "left", "right", "top", "bottom":
		return true
	}
	return false
}


// A side by name; right when none is given
@(private = "file")
side_of :: proc(name: string) -> Side {
	switch name {
	case "left":   return .Left
	case "top":    return .Top
	case "bottom": return .Bottom
	}
	return .Right
}


@(private = "file")
no_pane :: proc(ref: string) -> string {
	return fmt.tprintf("no pane %q is open (or shown, where it must be)", ref)
}


@(private = "file")
pane_is_open :: proc(p: ^Pane) -> bool {
	for q in g.panes.open {
		if q == p do return true
	}
	return false
}


// {"pane": "p<id>"} (temp)
@(private = "file")
pane_json :: proc(p: ^Pane) -> string {
	return fmt.tprintf(`{{"pane":"p%d"}}`, p.id)
}


// A 1-based line and column (in bytes) as a place to open at, found once the
// file's text is there
@(private = "file")
line_target :: proc(line, col: int) -> Open_Target {
	position := lsp.Position{line - 1, max(col - 1, 0)}
	return Lsp_Target{position, .UTF8}
}
