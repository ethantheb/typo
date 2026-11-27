package git

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import lg "../../vendor/libgit2"
import "../process"


// The bound structs are the size libgit2's headers make them (x64), so a
// field left out or a version bump that adds one fails here, not by
// overwriting memory. Measured with sizeof against build/deps/libgit2/include
@(test)
test_libgit2_struct_sizes :: proc(t: ^testing.T) {
	when size_of(rawptr) != 8 do return

	testing.expect_value(t, size_of(lg.Oid), 20)
	testing.expect_value(t, size_of(lg.Strarray), 16)
	testing.expect_value(t, size_of(lg.Error), 16)
	testing.expect_value(t, size_of(lg.Status_Options), 48)
	testing.expect_value(t, size_of(lg.Diff_File), 48)
	testing.expect_value(t, size_of(lg.Diff_Delta), 112)
	testing.expect_value(t, size_of(lg.Status_Entry), 24)
	testing.expect_value(t, size_of(lg.Index_Time), 8)
	testing.expect_value(t, size_of(lg.Index_Entry), 72)
	testing.expect_value(t, size_of(lg.Buf), 24)
	testing.expect_value(t, size_of(lg.Blob_Filter_Options), 40)
	testing.expect_value(t, size_of(lg.Checkout_Options), 144)
	testing.expect_value(t, size_of(lg.Time), 16)
	testing.expect_value(t, size_of(lg.Signature), 32)
}


// The log lists commits newest first with their messages; a commit's files
// and its versions of a file (and its parent's) read back; ids round-trip as hex
@(test)
test_history :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	dir, ok := temp_repo(t, "history")
	if !ok do return
	defer os.remove_all(dir)

	// A second commit: a.txt changed, b.txt added
	write(dir, "a.txt", "one\nTWO\nthree\n")
	write(dir, "b.txt", "b\n")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "Second\n\nWith a body")

	r := open_test_repo(t, dir)
	defer repo_close(&r)
	log, problem := read_log(&r, LOG_LIMIT)
	defer log_destroy(&log)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(log.commits), 2)
	if len(log.commits) != 2 do return

	newest, first := log.commits[0], log.commits[1]
	testing.expect_value(t, newest.summary, "Second")
	testing.expect_value(t, newest.message, "Second\n\nWith a body")
	testing.expect_value(t, newest.author, "Typo Test")
	testing.expect_value(t, first.summary, "first")
	testing.expect_value(t, len(newest.short), SHORT_ID)

	// What the second commit changed
	detail, detail_problem := read_commit(&r, newest.id)
	defer commit_detail_destroy(&detail)
	testing.expect_value(t, detail_problem, "")
	testing.expect_value(t, len(detail.files), 2)
	for f in detail.files {
		switch f.path {
		case "a.txt": testing.expect_value(t, f.kind, Kind.Modified)
		case "b.txt": testing.expect_value(t, f.kind, Kind.Added)
		case:         testing.expectf(t, false, "unexpected file %s", f.path)
		}
	}

	// a.txt in the commit and in its parent; the first commit has no parent
	temp := context.temp_allocator
	after, _, in_commit, _ := read_commit_version(&r, "a.txt", newest.id, false, temp)
	before, _, in_parent, _ := read_commit_version(&r, "a.txt", newest.id, true, temp)
	testing.expect(t, in_commit && in_parent)
	testing.expect_value(t, string(after), "one\nTWO\nthree\n")
	testing.expect_value(t, string(before), "one\ntwo\nthree\n")
	_, b_before := commit_version_id(&r, "b.txt", newest.id, true)
	_, orphan := commit_version_id(&r, "a.txt", first.id, true)
	testing.expect(t, !b_before, "b.txt is new in the commit")
	testing.expect(t, !orphan, "the first commit has no parent")

	// Ids as hex
	hex := oid_hex(newest.id, context.temp_allocator)
	back, parsed := oid_from_hex(hex)
	testing.expect(t, parsed && back == newest.id)
	_, bad := oid_from_hex("xyz")
	testing.expect(t, !bad)
}


// A repository of its own for a test, in a temp folder, with a committed
// file "a.txt". Skipped (empty dir) without git on PATH
@(private = "file")
temp_repo :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
	if process.find_executable("git", context.temp_allocator) == "" {
		log.info("git isn't on PATH; skipped")
		return "", false
	}

	tmp, _ := os.temp_directory(context.temp_allocator)
	dir = fmt.tprintf("%s%ctypo-git-%s-%d", tmp, os.Path_Separator, name, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)

	git(t, dir, "init", "-q", "-b", "main")
	git(t, dir, "config", "user.name", "Typo Test")
	git(t, dir, "config", "user.email", "test@example.com")
	git(t, dir, "config", "commit.gpgsign", "false")
	git(t, dir, "config", "core.autocrlf", "false")
	write(dir, "a.txt", "one\ntwo\nthree\n")
	git(t, dir, "add", "a.txt")
	git(t, dir, "commit", "-q", "-m", "first")
	return dir, true
}


// Runs git in a folder; the test fails if it does
@(private = "file")
git :: proc(t: ^testing.T, dir: string, args: ..string, loc := #caller_location) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "git")
	append(&all, ..args)

	code, output := run(all[:], dir, nil, context.temp_allocator)
	testing.expectf(t, code == 0, "git %v: %s", args, output, loc = loc)
	return output
}


@(private = "file")
write :: proc(dir, name, text: string) {
	path := fmt.tprintf("%s/%s", dir, name)
	_ = os.make_directory_all(parent_folder_of(path))
	_ = os.write_entire_file(path, transmute([]u8)text)
}


@(private = "file")
read :: proc(dir, name: string) -> string {
	data, _ := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
	return string(data)
}


@(private = "file")
parent_folder_of :: proc(path: string) -> string {
	i := strings.last_index_any(path, `/\`)
	return i > 0 ? path[:i] : path
}


@(private = "file")
open_test_repo :: proc(t: ^testing.T, dir: string) -> (r: Repo) {
	found, problem := repo_open(&r, dir)
	testing.expectf(t, found, "opened: %s", problem)
	return
}


@(private = "file")
status_of :: proc(t: ^testing.T, r: ^Repo) -> Status {
	s, problem := read_status(r, 1)
	testing.expectf(t, problem == "", "status: %s", problem)
	return s
}


@(private = "file")
has :: proc(s: ^Status, area: Area, path: string, kind: Kind) -> bool {
	e, found := find_entry(s, area, path)
	return found && e.kind == kind
}


@(test)
test_status_lists_each_area :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	dir, ok := temp_repo(t, "status")
	if !ok do return
	defer os.remove_all(dir)

	// Staged, then changed again; another changed; an untracked file in a folder
	write(dir, "a.txt", "one\nTWO\nthree\n")
	git(t, dir, "add", "a.txt")
	write(dir, "a.txt", "one\nTWO\nthree\nfour\n")
	write(dir, "new/b.txt", "b\n")

	r := open_test_repo(t, dir)
	defer repo_close(&r)
	s := status_of(t, &r)
	defer status_destroy(&s)

	testing.expect(t, has(&s, .Staged, "a.txt", .Modified))
	testing.expect(t, has(&s, .Changes, "a.txt", .Modified))
	testing.expect(t, has(&s, .Untracked, "new/b.txt", .Untracked))
	testing.expect_value(t, s.counts[.Staged], 1)
	testing.expect_value(t, s.counts[.Changes], 1)
	testing.expect_value(t, s.counts[.Untracked], 1)
	testing.expect_value(t, s.branch, "main")
	testing.expect_value(t, len(s.head), SHORT_ID)
	testing.expect(t, !s.unborn)

	// Entries are by area
	for i in 1 ..< len(s.entries) {
		testing.expect(t, s.entries[i - 1].area <= s.entries[i].area)
	}
}


@(test)
test_stage_unstage_discard :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	dir, ok := temp_repo(t, "stage")
	if !ok do return
	defer os.remove_all(dir)

	write(dir, "a.txt", "changed\n")
	write(dir, "c.txt", "untracked\n")
	r := open_test_repo(t, dir)
	defer repo_close(&r)

	// Staging takes the work tree's version
	testing.expect_value(t, stage(&r, {"a.txt", "c.txt"}), "")
	s := status_of(t, &r)
	testing.expect(t, has(&s, .Staged, "a.txt", .Modified))
	testing.expect(t, has(&s, .Staged, "c.txt", .Added))
	testing.expect_value(t, s.counts[.Changes] + s.counts[.Untracked], 0)
	status_destroy(&s)

	// Unstaging puts HEAD's back, and drops a file HEAD hasn't
	testing.expect_value(t, unstage(&r, {"a.txt", "c.txt"}), "")
	s = status_of(t, &r)
	testing.expect(t, has(&s, .Changes, "a.txt", .Modified))
	testing.expect(t, has(&s, .Untracked, "c.txt", .Untracked))
	testing.expect_value(t, s.counts[.Staged], 0)
	status_destroy(&s)

	// Discarding checks out the index's version; deleting removes the file
	testing.expect_value(t, discard(&r, {"a.txt"}), "")
	testing.expect_value(t, read(dir, "a.txt"), "one\ntwo\nthree\n")
	testing.expect_value(t, delete_untracked(&r, {"c.txt"}, to_trash = false), "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/c.txt", dir)))

	s = status_of(t, &r)
	testing.expect_value(t, len(s.entries), 0)
	status_destroy(&s)
}


@(test)
test_versions_and_hunks_in_the_index :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	dir, ok := temp_repo(t, "splice")
	if !ok do return
	defer os.remove_all(dir)

	write(dir, "a.txt", "one\nTWO\nthree\nfour\n")
	r := open_test_repo(t, dir)
	defer repo_close(&r)

	// HEAD's and the index's versions, the same before staging
	head, head_id, in_head, _ := read_version(&r, "a.txt", .Head, context.temp_allocator)
	staged, staged_id, in_index, _ := read_version(&r, "a.txt", .Index, context.temp_allocator)
	testing.expect(t, in_head && in_index)
	testing.expect_value(t, string(head), "one\ntwo\nthree\n")
	testing.expect_value(t, string(staged), string(head))
	testing.expect(t, head_id == staged_id)
	_, _, missing, _ := read_version(&r, "nope.txt", .Index, context.temp_allocator)
	testing.expect(t, !missing)

	// Staging one hunk: "two" becomes "TWO" in the index, "four" stays unstaged
	lo := len("one\n")
	hi := lo + len("two\n")
	text := transmute([]u8)string("TWO\n")
	testing.expect_value(t, splice_index(&r, "a.txt", staged_id, lo, hi, text), "")
	staged, _, _, _ = read_version(&r, "a.txt", .Index, context.temp_allocator)
	testing.expect_value(t, string(staged), "one\nTWO\nthree\n")

	s := status_of(t, &r)
	testing.expect(t, has(&s, .Staged, "a.txt", .Modified))
	testing.expect(t, has(&s, .Changes, "a.txt", .Modified))
	status_destroy(&s)

	// A splice against a version that isn't staged anymore is refused
	problem := splice_index(&r, "a.txt", staged_id, 0, 0, transmute([]u8)string("x\n"))
	testing.expect(t, problem != "")
}


@(test)
test_line_endings_follow_the_work_tree :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	dir, ok := temp_repo(t, "crlf")
	if !ok do return
	defer os.remove_all(dir)

	// Stored with LF, checked out with CRLF
	git(t, dir, "config", "core.autocrlf", "true")
	r := open_test_repo(t, dir)
	defer repo_close(&r)

	text, id, found, _ := read_version(&r, "a.txt", .Index, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, string(text), "one\r\ntwo\r\nthree\r\n")

	// Text spliced in as checked out is stored with LF
	lo := len("one\r\n")
	hi := lo + len("two\r\n")
	two := transmute([]u8)string("2\r\n")
	testing.expect_value(t, splice_index(&r, "a.txt", id, lo, hi, two), "")
	stored := git(t, dir, "cat-file", "-p", ":a.txt")
	testing.expect_value(t, stored, "one\n2\nthree")
}


@(test)
test_unborn_branch :: proc(t: ^testing.T) {
	library_init()
	defer library_shutdown()
	if process.find_executable("git", context.temp_allocator) == "" do return

	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s%ctypo-git-unborn-%d", tmp, os.Path_Separator, os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	git(t, dir, "init", "-q", "-b", "trunk")
	write(dir, "x.txt", "x\n")

	r := open_test_repo(t, dir)
	defer repo_close(&r)
	s := status_of(t, &r)
	defer status_destroy(&s)

	testing.expect(t, s.unborn)
	testing.expect_value(t, s.branch, "trunk")
	testing.expect(t, has(&s, .Untracked, "x.txt", .Untracked))

	// Unstaging with no commit drops the file from the index
	testing.expect_value(t, stage(&r, {"x.txt"}), "")
	testing.expect_value(t, unstage(&r, {"x.txt"}), "")
}


// --- The worker --------------------------------------------------------------------

@(private = "file")
test_wake :: proc "contextless" (data: rawptr) {}


// Takes the worker's events until `want` returns true for one, or 10 s pass;
// returns whether it did. Statuses are kept in `last`
@(private = "file")
wait_for :: proc(
	w: ^Worker,
	last: ^Status,
	want: proc(e: ^Event) -> bool,
) -> (
	done: bool,
	failures: [dynamic]string,
) {
	failures = make([dynamic]string, context.temp_allocator)
	start := time.tick_now()
	for time.tick_since(start) < 10 * time.Second {
		for &e in worker_take(w) {
			if f, failed := e.(Op_Failed); failed {
				append(&failures, strings.clone(f.message, context.temp_allocator))
			}
			if want(&e) do done = true
			if s, is_status := &e.(Status_Ready); is_status {
				status_destroy(last)
				last^ = s.status
				s.status = {}
			}
			event_destroy(&e)
		}
		if done do return
		time.sleep(5 * time.Millisecond)
	}
	return
}


@(private = "file")
is_status :: proc(e: ^Event) -> bool {
	_, ok := e.(Status_Ready)
	return ok
}


@(test)
test_worker_stages_and_commits :: proc(t: ^testing.T) {
	dir, ok := temp_repo(t, "worker")
	if !ok do return
	defer os.remove_all(dir)

	w: Worker
	worker_start(&w, test_wake, nil)
	defer worker_stop(&w)

	last: Status
	defer status_destroy(&last)

	// The repository opens, with its first status
	write(dir, "a.txt", "changed\n")
	worker_set_folder(&w, dir)
	got, _ := wait_for(&w, &last, is_status)
	testing.expect(t, got)
	testing.expect(t, has(&last, .Changes, "a.txt", .Modified))

	// Staging is followed by a fresh status
	worker_post(&w, Stage{paths = clone_paths({"a.txt"})})
	got, _ = wait_for(&w, &last, is_status)
	testing.expect(t, got && has(&last, .Staged, "a.txt", .Modified))

	// Committing through the command line
	testing.expect(t, worker_run(&w, .Commit, op_args(.Commit, &last), "Second commit\n"))
	committed := proc(e: ^Event) -> bool {
		d, ok := e.(Remote_Done)
		return ok && d.op == .Commit && d.ok
	}
	got, _ = wait_for(&w, &last, committed)
	testing.expect(t, got)

	// The status after it is clean, and the log has the message
	for worker_busy(&w) do time.sleep(5 * time.Millisecond)
	wait_for(&w, &last, proc(e: ^Event) -> bool {return false})
	testing.expect_value(t, len(last.entries), 0)
	log := git(t, dir, "log", "-1", "--format=%s")
	testing.expect_value(t, log, "Second commit")
}


@(test)
test_worker_follows_commits_made_elsewhere :: proc(t: ^testing.T) {
	dir, ok := temp_repo(t, "elsewhere")
	if !ok do return
	defer os.remove_all(dir)

	w: Worker
	worker_start(&w, test_wake, nil)
	defer worker_stop(&w)

	last: Status
	defer status_destroy(&last)

	write(dir, "a.txt", "changed\n")
	worker_set_folder(&w, dir)
	got, _ := wait_for(&w, &last, is_status)
	testing.expect(t, got && len(last.entries) == 1)

	// A commit in "a terminal": the poll sees the index and the branch move
	git(t, dir, "commit", "-q", "-a", "-m", "elsewhere")
	clean := proc(e: ^Event) -> bool {
		s, ok := e.(Status_Ready)
		return ok && len(s.status.entries) == 0
	}
	got, _ = wait_for(&w, &last, clean)
	testing.expect(t, got)
}


@(test)
test_worker_reports_failures :: proc(t: ^testing.T) {
	dir, ok := temp_repo(t, "failures")
	if !ok do return
	defer os.remove_all(dir)

	w: Worker
	worker_start(&w, test_wake, nil)
	defer worker_stop(&w)

	last: Status
	defer status_destroy(&last)
	worker_set_folder(&w, dir)
	wait_for(&w, &last, is_status)

	// Nothing staged: the commit fails, with git's words
	testing.expect(t, worker_run(&w, .Commit, op_args(.Commit, &last), "Nothing\n"))
	failed := proc(e: ^Event) -> bool {
		d, ok := e.(Remote_Done)
		return ok && !d.ok && d.output != ""
	}
	got, _ := wait_for(&w, &last, failed)
	testing.expect(t, got)

	// Only git's words about credentials count as wanting them
	testing.expect(t, !auth_failed("fatal: No configured push destination."))
	testing.expect(t, auth_failed("fatal: Authentication failed for 'https://x'"))
}


@(test)
test_worker_cancels_a_command :: proc(t: ^testing.T) {
	dir, ok := temp_repo(t, "cancel")
	if !ok do return
	defer os.remove_all(dir)

	w: Worker
	worker_start(&w, test_wake, nil)
	defer worker_stop(&w)

	last: Status
	defer status_destroy(&last)
	worker_set_folder(&w, dir)
	wait_for(&w, &last, is_status)

	// Commands carry the stall limit
	testing.expect(t, worker_run(&w, .Fetch, {"git", "config", "http.lowSpeedTime"}))
	limited := proc(e: ^Event) -> bool {
		d, ok := e.(Remote_Done)
		return ok && d.ok && d.output == "60"
	}
	got, _ := wait_for(&w, &last, limited)
	testing.expect(t, got)

	// A command that would wait half a minute (a shell alias, so git runs a
	// process of its own) ends at once, cancelled, not failed
	for worker_running(&w) do time.sleep(5 * time.Millisecond)
	waiting := []string{"git", "-c", "alias.wait=!sleep 30", "wait"}
	testing.expect(t, worker_run(&w, .Fetch, waiting))
	time.sleep(300 * time.Millisecond)
	start := time.tick_now()
	worker_cancel(&w)

	cancelled := proc(e: ^Event) -> bool {
		d, ok := e.(Remote_Done)
		return ok && d.cancelled && !d.auth
	}
	got, _ = wait_for(&w, &last, cancelled)
	testing.expect(t, got)
	testing.expect(t, time.tick_since(start) < 5 * time.Second)
	testing.expect(t, !worker_running(&w))
}


@(private = "file")
clone_paths :: proc(paths: []string) -> []string {
	out := make([]string, len(paths))
	for p, i in paths do out[i] = strings.clone(p)
	return out
}
