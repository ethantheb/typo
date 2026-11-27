package git

// A repository through libgit2: what the worker thread and the diff view's
// loader do with it. Every procedure here blocks on the disk; a Repo belongs to
// the thread that opened it. File versions are read as they are checked out
// (smudged: with the work tree's line endings), so they compare with the files
// themselves, and text put in the index is cleaned first

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import lg "../../vendor/libgit2"
import "../trash"


Repo :: struct {
	handle: ^lg.Repository,
	info:   Repo_Info, // owned
}

// Short ids are this many hex digits, as git shows them
SHORT_ID :: 7


// libgit2's global state, counted: each user calls these in pairs. Any thread
library_init :: proc() {
	lg.libgit2_init()
}


library_shutdown :: proc() {
	lg.libgit2_shutdown()
}


// Opens the repository `folder` is in (it or a folder above it). Not found
// isn't a problem; anything else says what went wrong
repo_open :: proc(r: ^Repo, folder: string) -> (found: bool, problem: string) {
	repo_close(r)

	cfolder := strings.clone_to_cstring(folder, context.temp_allocator)
	code := lg.repository_open_ext(&r.handle, cfolder, 0, nil)
	switch code {
	case lg.OK:
	case lg.ENOTFOUND:
		return false, ""
	case lg.EOWNER:
		return false, "the repository belongs to another user (see git's safe.directory)"
	case:
		return false, last_error("the repository can't be opened")
	}

	// A bare repository has no work tree to show
	workdir := lg.repository_workdir(r.handle)
	if workdir == nil {
		repo_close(r)
		return false, ""
	}

	r.info = {
		workdir = native_path(string(workdir)),
		gitdir  = native_path(string(lg.repository_path(r.handle))),
		common  = native_path(string(lg.repository_commondir(r.handle))),
	}
	return true, ""
}


repo_close :: proc(r: ^Repo) {
	if r.handle != nil do lg.repository_free(r.handle)
	repo_info_destroy(&r.info)
	r^ = {}
}


// --- Status ------------------------------------------------------------------------

// The repository's status: its files' changes, the branch, the upstream and
// how far apart they are
read_status :: proc(r: ^Repo, generation: u64) -> (s: Status, problem: string) {
	s.generation = generation

	// The files, read before HEAD so a commit made meanwhile shows as clean
	opts: lg.Status_Options
	lg.status_options_init(&opts, lg.STATUS_OPTIONS_VERSION)
	opts.show = .Index_And_Workdir
	opts.flags =
		lg.STATUS_OPT_INCLUDE_UNTRACKED |
		lg.STATUS_OPT_RECURSE_UNTRACKED_DIRS |
		lg.STATUS_OPT_RENAMES_HEAD_TO_INDEX
	when ODIN_OS == .Windows {
		opts.flags |= lg.STATUS_OPT_SORT_CASE_INSENSITIVELY
	}

	list: ^lg.Status_List
	if lg.status_list_new(&list, r.handle, &opts) != lg.OK {
		return {}, last_error("the status can't be read")
	}
	defer lg.status_list_free(list)

	// Its strings are temp until own_strings moves them into the status
	count := int(lg.status_list_entrycount(list))
	entries := make([dynamic]Entry, 0, count)
	for i in 0 ..< count {
		add_entries(&entries, lg.status_byindex(list, c.size_t(i)))
	}

	// By area, keeping libgit2's order (by path) within each
	slice.stable_sort_by(entries[:], area_before)
	s.entries = entries[:]
	for e in s.entries do s.counts[e.area] += 1

	read_head(r, &s)
	own_strings(&s)
	return s, ""
}


// Moves the status's strings into its text
@(private = "file")
own_strings :: proc(s: ^Status) {
	total := len(s.branch) + len(s.head) + len(s.upstream)
	for e in s.entries do total += len(e.path) + len(e.old_path)
	s.text = make([]u8, total)

	at := 0
	for &e in s.entries {
		move_into(s.text, &at, &e.path)
		move_into(s.text, &at, &e.old_path)
	}
	move_into(s.text, &at, &s.branch)
	move_into(s.text, &at, &s.head)
	move_into(s.text, &at, &s.upstream)
}


// Copies a string into `text` at `at`, which it then is a slice of
@(private = "file")
move_into :: proc(text: []u8, at: ^int, s: ^string) {
	n := copy(text[at^:], s^)
	s^ = string(text[at^:at^ + n])
	at^ += n
}


@(private = "file")
area_before :: proc(a, b: Entry) -> bool {
	return a.area < b.area
}


// The entries one file's status makes: conflicted, or staged and changed (both
// at once), or untracked
@(private = "file")
add_entries :: proc(out: ^[dynamic]Entry, se: ^lg.Status_Entry) {
	flags := se.status
	head := se.head_to_index
	work := se.index_to_workdir

	if .Conflicted in flags {
		delta := work != nil ? work : head
		append(out, Entry{path = delta_path(delta), area = .Conflicts, kind = .Conflicted})
		return
	}

	// HEAD to the index
	staged := lg.Status_Flags{
		.Index_New,
		.Index_Modified,
		.Index_Deleted,
		.Index_Renamed,
		.Index_Typechange,
	}
	if flags & staged != {} && head != nil {
		e := Entry{path = delta_path(head), area = .Staged}
		switch {
		case .Index_New in flags:     e.kind = .Added
		case .Index_Deleted in flags: e.kind = .Deleted
		case .Index_Renamed in flags:
			e.kind = .Renamed
			e.old_path = strings.clone(string(head.old_file.path), context.temp_allocator)
		case .Index_Typechange in flags: e.kind = .Typechange
		case:                            e.kind = .Modified
		}
		append(out, e)
	}

	// The index to the work tree
	if .Wt_New in flags && work != nil {
		append(out, Entry{path = delta_path(work), area = .Untracked, kind = .Untracked})
		return
	}
	changed := lg.Status_Flags{.Wt_Modified, .Wt_Deleted, .Wt_Typechange, .Wt_Renamed}
	if flags & changed != {} && work != nil {
		e := Entry{path = delta_path(work), area = .Changes}
		switch {
		case .Wt_Deleted in flags:    e.kind = .Deleted
		case .Wt_Typechange in flags: e.kind = .Typechange
		case:                         e.kind = .Modified
		}
		append(out, e)
	}
}


// The path a change is about: the new file's, or the old one's if it is gone
// (temp)
@(private = "file")
delta_path :: proc(d: ^lg.Diff_Delta) -> string {
	path := d.new_file.path != nil ? d.new_file.path : d.old_file.path
	return strings.clone(string(path), context.temp_allocator)
}


// HEAD's branch and short id, the operation under way, and the upstream with
// how far ahead and behind the branch is (strings temp)
@(private = "file")
read_head :: proc(r: ^Repo, s: ^Status) {
	allocator := context.temp_allocator

	switch lg.repository_state(r.handle) {
	case .Merge:                                   s.operation = .Merging
	case .Rebase, .Rebase_Interactive, .Rebase_Merge,
	     .Apply_Mailbox, .Apply_Mailbox_Or_Rebase: s.operation = .Rebasing
	case .Cherrypick, .Cherrypick_Sequence:        s.operation = .Cherry_Picking
	case .Revert, .Revert_Sequence:                s.operation = .Reverting
	case .Bisect:                                  s.operation = .Bisecting
	case .None:
	}

	head: ^lg.Reference
	code := lg.repository_head(&head, r.handle)
	if code == lg.EUNBORNBRANCH || code == lg.ENOTFOUND {
		s.unborn = true
		s.branch = unborn_branch(r, allocator)
		return
	}
	if code != lg.OK do return
	defer lg.reference_free(head)

	if target := lg.reference_target(head); target != nil {
		s.head = short_id(target^, allocator)
	}
	if lg.repository_head_detached(r.handle) == 1 do return
	s.branch = strings.clone(string(lg.reference_shorthand(head)), allocator)

	// The upstream, if the branch has one
	upstream: ^lg.Reference
	if lg.branch_upstream(&upstream, head) != lg.OK do return
	defer lg.reference_free(upstream)
	s.upstream = strings.clone(string(lg.reference_shorthand(upstream)), allocator)

	local, remote := lg.reference_target(head), lg.reference_target(upstream)
	if local != nil && remote != nil {
		ahead, behind: c.size_t
		if lg.graph_ahead_behind(&ahead, &behind, r.handle, local, remote) == lg.OK {
			s.ahead, s.behind = int(ahead), int(behind)
		}
	}
}


// The branch HEAD names before its first commit
@(private = "file")
unborn_branch :: proc(r: ^Repo, allocator := context.allocator) -> string {
	head: ^lg.Reference
	if lg.reference_lookup(&head, r.handle, "HEAD") != lg.OK do return ""
	defer lg.reference_free(head)

	target := lg.reference_symbolic_target(head)
	if target == nil do return ""
	name := strings.trim_prefix(string(target), "refs/heads/")
	return strings.clone(name, allocator)
}


short_id :: proc(id: lg.Oid, allocator := context.allocator) -> string {
	hex := "0123456789abcdef"

	out := make([]u8, SHORT_ID, allocator)
	for i in 0 ..< SHORT_ID {
		b := id.id[i / 2]
		nibble := i % 2 == 0 ? b >> 4 : b & 0xf
		out[i] = hex[nibble]
	}
	return string(out)
}


// --- Reading versions --------------------------------------------------------------

// A file's text in HEAD or the index, as it is checked out, in `allocator`,
// with the blob's id. Not found when the version has no such file
read_version :: proc(
	r: ^Repo,
	rel: string,
	version: Version,
	allocator := context.allocator,
) -> (
	data: []u8,
	id: lg.Oid,
	found: bool,
	problem: string,
) {
	in_version: bool
	id, in_version = version_id(r, rel, version)
	if !in_version do return

	crel := strings.clone_to_cstring(rel, context.temp_allocator)
	data, problem = blob_text(r, &id, crel, allocator)
	return data, id, problem == "", problem
}


// The id of a file's blob in HEAD or the index, without reading it. Not found
// when the version has no such file
version_id :: proc(r: ^Repo, rel: string, version: Version) -> (id: lg.Oid, found: bool) {
	crel := strings.clone_to_cstring(rel, context.temp_allocator)

	switch version {
	case .Index:
		index: ^lg.Index
		if lg.repository_index(&index, r.handle) != lg.OK do return
		defer lg.index_free(index)
		lg.index_read(index, 0)

		entry := lg.index_get_bypath(index, crel, 0)
		if entry == nil do return
		return entry.id, true

	case .Head:
		tree: ^lg.Object
		if lg.revparse_single(&tree, r.handle, "HEAD^{tree}") != lg.OK do return
		defer lg.object_free(tree)

		te: ^lg.Tree_Entry
		if lg.tree_entry_bypath(&te, (^lg.Tree)(tree), crel) != lg.OK do return
		defer lg.tree_entry_free(te)
		return lg.tree_entry_id(te)^, true
	}
	return
}


// A blob's text as checked out to `path`
@(private)
blob_text :: proc(
	r: ^Repo,
	id: ^lg.Oid,
	path: cstring,
	allocator := context.allocator,
) -> (
	text: []u8,
	problem: string,
) {
	blob: ^lg.Blob
	if lg.blob_lookup(&blob, r.handle, id) != lg.OK {
		return nil, last_error("the file's version can't be read")
	}
	defer lg.blob_free(blob)

	opts: lg.Blob_Filter_Options
	lg.blob_filter_options_init(&opts, lg.BLOB_FILTER_OPTIONS_VERSION)
	opts.flags = lg.BLOB_FILTER_CHECK_FOR_BINARY

	out: lg.Buf
	if lg.blob_filter(&out, blob, path, &opts) != lg.OK {
		return nil, last_error("the file's version can't be read")
	}
	defer lg.buf_dispose(&out)

	return slice.clone(out.ptr[:out.size], allocator), ""
}


// --- Changing the index and the work tree ------------------------------------------

// Stages files: their work tree versions go in the index (a file gone from the
// work tree leaves it). Staging a conflicted file marks it resolved
stage :: proc(r: ^Repo, paths: []string) -> string {
	index: ^lg.Index
	if lg.repository_index(&index, r.handle) != lg.OK {
		return last_error("the index can't be read")
	}
	defer lg.index_free(index)
	lg.index_read(index, 0)

	for rel in paths {
		crel := strings.clone_to_cstring(rel, context.temp_allocator)
		full := full_path(r.info.workdir, rel)

		code: c.int
		if os.exists(full) {
			code = lg.index_add_bypath(index, crel)
		} else {
			code = lg.index_remove_bypath(index, crel)
		}
		if code != lg.OK do return last_error(fmt.tprintf("%s can't be staged", rel))
	}

	if lg.index_write(index) != lg.OK do return last_error("the index can't be written")
	return ""
}


// Unstages files: the index takes HEAD's version of each again, or drops a
// file HEAD hasn't
unstage :: proc(r: ^Repo, paths: []string) -> string {
	index: ^lg.Index
	if lg.repository_index(&index, r.handle) != lg.OK {
		return last_error("the index can't be read")
	}
	defer lg.index_free(index)
	lg.index_read(index, 0)

	tree: ^lg.Object
	if lg.revparse_single(&tree, r.handle, "HEAD^{tree}") != lg.OK {
		tree = nil // no commit yet: every file leaves the index
	}
	defer if tree != nil do lg.object_free(tree)

	for rel in paths {
		crel := strings.clone_to_cstring(rel, context.temp_allocator)

		te: ^lg.Tree_Entry
		in_head := tree != nil && lg.tree_entry_bypath(&te, (^lg.Tree)(tree), crel) == lg.OK
		code: c.int
		if in_head {
			entry := lg.Index_Entry {
				mode = u32(lg.tree_entry_filemode(te)),
				id   = lg.tree_entry_id(te)^,
				path = crel,
			}
			lg.tree_entry_free(te)
			code = lg.index_add(index, &entry)
		} else {
			code = lg.index_remove_bypath(index, crel)
		}
		if code != lg.OK do return last_error(fmt.tprintf("%s can't be unstaged", rel))
	}

	if lg.index_write(index) != lg.OK do return last_error("the index can't be written")
	return ""
}


// Discards files' changes in the work tree: each is checked out from the index
discard :: proc(r: ^Repo, paths: []string) -> string {
	if len(paths) == 0 do return ""

	cpaths := make([]cstring, len(paths), context.temp_allocator)
	for rel, i in paths {
		cpaths[i] = strings.clone_to_cstring(rel, context.temp_allocator)
	}

	opts: lg.Checkout_Options
	lg.checkout_options_init(&opts, lg.CHECKOUT_OPTIONS_VERSION)
	opts.checkout_strategy = lg.CHECKOUT_FORCE | lg.CHECKOUT_DISABLE_PATHSPEC_MATCH
	opts.paths = {raw_data(cpaths), c.size_t(len(cpaths))}

	if lg.checkout_index(r.handle, nil, &opts) != lg.OK {
		return last_error("the changes can't be discarded")
	}
	return ""
}


// Moves untracked files to the trash (or deletes them for good), and removes
// the folders they leave empty. A file that can't go to the trash stays, and
// says so
delete_untracked :: proc(r: ^Repo, paths: []string, to_trash: bool) -> string {
	for rel in paths {
		full := full_path(r.info.workdir, rel)
		if problem := remove_file(full, rel, to_trash); problem != "" {
			return problem
		}

		// Folders left empty, up to the work tree
		dir := parent_folder(full)
		for len(dir) > len(r.info.workdir) {
			if os.remove(dir) != nil do break
			dir = parent_folder(dir)
		}
	}
	return ""
}


// Why a file couldn't be removed, or ""
@(private = "file")
remove_file :: proc(full, rel: string, to_trash: bool) -> string {
	if !to_trash {
		if err := os.remove(full); err != nil {
			return fmt.tprintf("%s can't be deleted (%s)", rel, os.error_string(err))
		}
		return ""
	}

	switch trash.move(full) {
	case .Done:
	case .Not_Recyclable:
		return fmt.tprintf("%s can't be moved to the trash here, so it was kept", rel)
	case .Failed:
		return fmt.tprintf("%s can't be moved to the trash", rel)
	}
	return ""
}


@(private = "file")
parent_folder :: proc(path: string) -> string {
	i := len(path) - 1
	for i > 0 && !is_separator(path[i]) {
		i -= 1
	}
	return path[:max(i, 0)]
}


// Replaces bytes [lo, hi) of a file's staged text (as checked out) with
// `text`: staging or unstaging a hunk. Refused if the staged version isn't
// `base` anymore, as the offsets are in it
splice_index :: proc(r: ^Repo, rel: string, base: lg.Oid, lo, hi: int, text: []u8) -> string {
	index: ^lg.Index
	if lg.repository_index(&index, r.handle) != lg.OK {
		return last_error("the index can't be read")
	}
	defer lg.index_free(index)
	lg.index_read(index, 0)

	// The staged version, unchanged since the diff was made
	crel := strings.clone_to_cstring(rel, context.temp_allocator)
	found := lg.index_get_bypath(index, crel, 0)
	if found == nil || found.id != base {
		return fmt.tprintf("%s changed in the index meanwhile", rel)
	}
	entry := found^
	entry.path = crel

	staged, problem := blob_text(r, &entry.id, crel, context.temp_allocator)
	if problem != "" do return problem
	if lo < 0 || hi > len(staged) || lo > hi {
		return fmt.tprintf("%s changed in the index meanwhile", rel)
	}

	// The new text, cleaned as git add would
	spliced := make([dynamic]u8, 0, len(staged) - (hi - lo) + len(text), context.temp_allocator)
	append(&spliced, ..staged[:lo])
	append(&spliced, ..text)
	append(&spliced, ..staged[hi:])

	clean, clean_problem := cleaned(r, crel, spliced[:])
	if clean_problem != "" do return clean_problem

	if lg.index_add_from_buffer(index, &entry, raw_data(clean), c.size_t(len(clean))) != lg.OK {
		return last_error(fmt.tprintf("%s can't be staged", rel))
	}
	if lg.index_write(index) != lg.OK do return last_error("the index can't be written")
	return ""
}


// Text as git stores it for `path` (line endings and other filters undone),
// in the temp allocator
@(private = "file")
cleaned :: proc(r: ^Repo, path: cstring, text: []u8) -> ([]u8, string) {
	filters: ^lg.Filter_List
	if lg.filter_list_load(&filters, r.handle, nil, path, .To_Odb, 0) != lg.OK {
		return nil, last_error("the file's filters can't be loaded")
	}
	if filters == nil do return text, "" // no filter applies
	defer lg.filter_list_free(filters)

	out: lg.Buf
	applied := lg.filter_list_apply_to_buffer(&out, filters, raw_data(text), c.size_t(len(text)))
	if applied != lg.OK {
		return nil, last_error("the file's filters failed")
	}
	defer lg.buf_dispose(&out)
	return slice.clone(out.ptr[:out.size], context.temp_allocator), ""
}


// --- Following the repository ------------------------------------------------------

// The files whose change means the status may have: the index, HEAD, the
// refs (packed and loose) of the branch and of the upstream, and what a merge
// or fetch leaves (temp)
watched_files :: proc(r: ^Repo, branch, upstream: string) -> []string {
	files := make([dynamic]string, context.temp_allocator)

	gitdir, common := r.info.gitdir, r.info.common
	append(&files, in_folder(gitdir, "index"))
	append(&files, in_folder(gitdir, "HEAD"))
	append(&files, in_folder(gitdir, "MERGE_HEAD"))
	append(&files, in_folder(gitdir, "rebase-merge"))
	append(&files, in_folder(common, "packed-refs"))
	append(&files, in_folder(common, "FETCH_HEAD"))
	if branch != "" {
		append(&files, in_folder(common, "refs/heads/", branch))
	}
	if upstream != "" {
		append(&files, in_folder(common, "refs/remotes/", upstream))
	}
	return files[:]
}


// A path in a folder, from parts joined as they are (temp)
@(private = "file")
in_folder :: proc(dir: string, parts: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, dir)
	strings.write_byte(&sb, '/')
	for part in parts do strings.write_string(&sb, part)
	return native_path(strings.to_string(sb), context.temp_allocator)
}
