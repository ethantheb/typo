package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "buffer"
import "git"
import "process"
import "textedit"

// The diff view on a repository of its own: its hunks, reverting one in the
// file on disk (the line breaks at the file's end too) and in an open editor
// (one undo step, left unsaved), and staging one through the Git worker. The
// diff loader isn't started, so loads run at once; the worker is


// A temp repository with `name` committed holding `text`, or "" without git
@(private = "file")
temp_repo :: proc(t: ^testing.T, tag, name, text: string) -> string {
	if process.find_executable("git", context.temp_allocator) == "" do return ""

	tmp := os.temp_directory(context.temp_allocator) or_else "."
	dir := fmt.tprintf("%s%ctypo-diff-%s-%d", tmp, os.Path_Separator, tag, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)

	run_git(t, dir, "init", "-q", "-b", "main")
	run_git(t, dir, "config", "user.name", "Typo Test")
	run_git(t, dir, "config", "user.email", "test@example.com")
	run_git(t, dir, "config", "core.autocrlf", "false")
	write_file(dir, name, text)
	run_git(t, dir, "add", name)
	run_git(t, dir, "commit", "-q", "-m", "first")
	return dir
}


@(private = "file")
run_git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "git")
	append(&all, ..args)

	code, output := git.run(all[:], dir, nil, context.temp_allocator)
	testing.expectf(t, code == 0, "git %v: %s", args, output, loc = loc)
	return output
}


@(private = "file")
write_file :: proc(dir, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s%c%s", dir, os.Path_Separator, name), text)
}


@(private = "file")
read_file :: proc(dir, name: string) -> string {
	path := fmt.tprintf("%s%c%s", dir, os.Path_Separator, name)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}


// Starts the Git worker on a folder and waits for its repository
@(private = "file")
open_repo :: proc(t: ^testing.T, dir: string) {
	git_init()
	git_open_folder(dir)
	for i := 0; i < 1000 && !(git_available() && g.git.loaded); i += 1 {
		git_frame()
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, git_available(), "the repository opens")
}


// Waits for the worker to finish what it was asked, taking its events
@(private = "file")
settle :: proc() {
	for i := 0; i < 1000; i += 1 {
		git_frame()
		if !git_busy() do break
		time.sleep(5 * time.Millisecond)
	}
	git_frame()
}


// A diff pane on a file, loaded
@(private = "file")
open_diff :: proc(pane: ^Pane, path: string, area: git.Area) -> ^Diff_View {
	dv := new(Diff_View)
	diff_view_open(dv, path, area)
	pane^ = {id = 900, content = dv}
	append(&g.panes.open, pane)
	diff_views_frame()
	return dv
}


// An editor pane on a file with its text, as if opened
@(private = "file")
open_editor :: proc(pane: ^Pane, path, text: string) -> ^Editor {
	e := new(Editor)
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(text))
	e.status = .Text
	e.kind = &TEXT_KIND
	e.path = strings.clone(path)
	append(&e.sels, Selection{0, 0, -1})

	pane^ = {id = 901, content = e}
	append(&g.panes.open, pane)
	return e
}


@(private = "file")
close_all :: proc() {
	for p in g.panes.open {
		switch c in p.content {
		case ^Diff_View:
			diff_view_close(c)
			free(c)
		case ^Editor:
			buffer.buffer_destroy(&c.buf)
			delete(c.path)
			delete(c.sels)
			free(c)
		case ^Terminal, ^Git_View:
		}
	}
	clear(&g.panes.open)
	delete(g.panes.open)
	g.panes = {}
	git_destroy()
}


@(private = "file")
press_hunk :: proc(dv: ^Diff_View, kind: type_of(Hunk_Action{}.kind), hunk: int) {
	dv.clicked = Hunk_Action{kind, hunk}
	diff_views_frame()
}


@(test)
test_diff_view_reverts_on_disk :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	dir := temp_repo(t, "disk", "a.txt", "one\ntwo\nthree\nfour")
	if dir == "" do return
	defer os.remove_all(dir)
	open_repo(t, dir)
	defer close_all()

	// A changed line, and lines added at the end of a file without a last
	// line break
	write_file(dir, "a.txt", "one\nTWO\nthree\nfour\nfive\nsix")
	pane: Pane
	dv := open_diff(&pane, git_full_path("a.txt"), .Changes)
	testing.expect_value(t, dv.status, Diff_Status.Ready)
	testing.expect_value(t, len(dv.rows.hunks), 2)
	testing.expect_value(t, dv.added, 3)
	testing.expect_value(t, dv.removed, 1)

	// The first hunk back to the staged text: only it changes, and the view loads again
	press_hunk(dv, .Revert, 0)
	testing.expect_value(t, read_file(dir, "a.txt"), "one\ntwo\nthree\nfour\nfive\nsix")
	testing.expect_value(t, len(dv.rows.hunks), 1)

	// Then the lines at the end, with the line break before them
	press_hunk(dv, .Revert, 0)
	testing.expect_value(t, read_file(dir, "a.txt"), "one\ntwo\nthree\nfour")
	testing.expect_value(t, len(dv.rows.hunks), 0)

	// Lines gone at the end come back with their line break
	write_file(dir, "a.txt", "one\ntwo")
	dv.stale = true
	diff_views_frame()
	testing.expect_value(t, len(dv.rows.hunks), 1)
	press_hunk(dv, .Revert, 0)
	testing.expect_value(t, read_file(dir, "a.txt"), "one\ntwo\nthree\nfour")

	// A file changed since the diff read it isn't touched
	write_file(dir, "a.txt", "one\nTWO\nthree\nfour")
	dv.stale = true
	diff_views_frame()
	write_file(dir, "a.txt", "changed meanwhile\n")
	press_hunk(dv, .Revert, 0)
	testing.expect_value(t, read_file(dir, "a.txt"), "changed meanwhile\n")
	dialog_close()
}


@(test)
test_diff_view_reverts_in_an_editor :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	dir := temp_repo(t, "editor", "a.txt", "one\r\ntwo\r\nthree\r\n")
	if dir == "" do return
	defer os.remove_all(dir)
	open_repo(t, dir)
	defer close_all()

	// The open editor's text is the diff's right side, unsaved edits and all
	path := git_full_path("a.txt")
	diff_pane, editor_pane: Pane
	e := open_editor(&editor_pane, path, "one\r\nTWO\r\nthree\r\nfour\r\n")
	dv := open_diff(&diff_pane, path, .Changes)
	testing.expect_value(t, dv.signature.right, Diff_Source.Editor)
	testing.expect_value(t, len(dv.rows.hunks), 2)

	// Reverting edits the buffer, one undo step, left unsaved; the file isn't written
	press_hunk(dv, .Revert, 0)
	text := string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
	testing.expect_value(t, text, "one\r\ntwo\r\nthree\r\nfour\r\n")
	testing.expect(t, buffer.is_modified(&e.buf))
	testing.expect_value(t, read_file(dir, "a.txt"), "one\r\ntwo\r\nthree\r\n")

	textedit.undo(e)
	text = string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
	testing.expect_value(t, text, "one\r\nTWO\r\nthree\r\nfour\r\n")

	// A revert pressed against an older version of the text does nothing
	textedit.take_changes(e)
	press_hunk(dv, .Revert, 0)
	text = string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
	testing.expect_value(t, text, "one\r\nTWO\r\nthree\r\nfour\r\n")
}


@(test)
test_diff_view_stages_a_hunk :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	dir := temp_repo(t, "stage", "a.txt", "one\ntwo\nthree\nfour\n")
	if dir == "" do return
	defer os.remove_all(dir)
	open_repo(t, dir)
	defer close_all()

	write_file(dir, "a.txt", "one\nTWO\nthree\nfour\nfive\n")
	pane: Pane
	dv := open_diff(&pane, git_full_path("a.txt"), .Changes)
	testing.expect_value(t, len(dv.rows.hunks), 2)

	// Staging the second hunk puts only it in the index
	press_hunk(dv, .Stage, 1)
	settle()
	staged := run_git(t, dir, "show", ":a.txt")
	testing.expect_value(t, staged, "one\ntwo\nthree\nfour\nfive")

	// The diff of staged changes unstages it again
	staged_pane: Pane
	sv := open_diff(&staged_pane, git_full_path("a.txt"), .Staged)
	testing.expect_value(t, len(sv.rows.hunks), 1)
	press_hunk(sv, .Unstage, 0)
	settle()
	staged = run_git(t, dir, "show", ":a.txt")
	testing.expect_value(t, staged, "one\ntwo\nthree\nfour")
}
