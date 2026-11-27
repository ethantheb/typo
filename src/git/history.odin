package git

// Commit history, read with libgit2 on the worker's thread: the branch's
// commits newest first (read_log), what one changed (read_commit), and a
// file's text in a commit or its parent, for the diff view

import "core:mem/virtual"
import "core:strings"

import lg "../../vendor/libgit2"


// Commits read at most
LOG_LIMIT :: 500

Commit_Info :: struct {
	id:      Oid,
	short:   string,
	summary: string, // the message's first paragraph, on one line
	message: string, // all of it
	author:  string,
	time:    i64,    // seconds since the epoch
}

// The branch's commits newest first. Its strings and list live in `arena`
Log :: struct {
	commits: []Commit_Info,
	arena:   virtual.Arena,
}

Commit_File :: struct {
	path:     string,
	old_path: string, // where a rename came from, else ""
	kind:     Kind,
}

// What a commit changed, against its first parent (or nothing, for the first
// commit). Its strings and list live in `arena`
Commit_Detail :: struct {
	id:      Oid,
	message: string,
	files:   []Commit_File,
	failed:  bool, // it couldn't be read (the worker says why with Op_Failed)
	arena:   virtual.Arena,
}


// The commits HEAD reaches, newest first, up to `limit`. By time only: a
// topological order would walk the whole history before the first commit.
// None before the first commit
read_log :: proc(r: ^Repo, limit: int) -> (log: Log, problem: string) {
	a := virtual.arena_allocator(&log.arena)

	walk: ^lg.Revwalk
	if lg.revwalk_new(&walk, r.handle) != lg.OK {
		return log, last_error("the history can't be read")
	}
	defer lg.revwalk_free(walk)
	lg.revwalk_sorting(walk, lg.SORT_TIME)
	if lg.revwalk_push_head(walk) != lg.OK do return

	// Each commit's id, summary, author and time
	commits := make([dynamic]Commit_Info, 0, 64, a)
	id: lg.Oid
	for len(commits) < limit && lg.revwalk_next(&id, walk) == lg.OK {
		c: ^lg.Commit
		if lg.commit_lookup(&c, r.handle, &id) != lg.OK do continue
		defer lg.commit_free(c)

		info := Commit_Info {
			id      = id,
			short   = short_id(id, a),
			summary = strings.clone(string(lg.commit_summary(c)), a),
			message = strings.clone(strings.trim_space(string(lg.commit_message(c))), a),
			time    = lg.commit_time(c),
		}
		if author := lg.commit_author(c); author != nil {
			info.author = strings.clone(string(author.name), a)
		}
		append(&commits, info)
	}
	log.commits = commits[:]
	return
}


log_destroy :: proc(log: ^Log) {
	virtual.arena_destroy(&log.arena)
	log^ = {}
}


// A commit's message and the files it changed against its first parent, with
// renames found
read_commit :: proc(r: ^Repo, id: Oid) -> (detail: Commit_Detail, problem: string) {
	a := virtual.arena_allocator(&detail.arena)
	detail.id = id

	id := id
	c: ^lg.Commit
	if lg.commit_lookup(&c, r.handle, &id) != lg.OK {
		return detail, last_error("the commit can't be read")
	}
	defer lg.commit_free(c)
	detail.message = strings.clone(strings.trim_right_space(string(lg.commit_message(c))), a)

	// Its tree beside its parent's (none for the first commit)
	tree, parent_tree: ^lg.Tree
	if lg.commit_tree(&tree, c) != lg.OK do return detail, last_error("the commit can't be read")
	defer lg.tree_free(tree)
	if lg.commit_parentcount(c) > 0 {
		parent: ^lg.Commit
		if lg.commit_parent(&parent, c, 0) == lg.OK {
			defer lg.commit_free(parent)
			_ = lg.commit_tree(&parent_tree, parent)
		}
	}
	defer if parent_tree != nil do lg.tree_free(parent_tree)

	diff: ^lg.Diff
	if lg.diff_tree_to_tree(&diff, r.handle, parent_tree, tree, nil) != lg.OK {
		return detail, last_error("the commit's changes can't be read")
	}
	defer lg.diff_free(diff)
	_ = lg.diff_find_similar(diff, nil)

	// Each file
	n := int(lg.diff_num_deltas(diff))
	files := make([]Commit_File, n, a)
	for &f, i in files {
		d := lg.diff_get_delta(diff, uint(i))
		f.kind = delta_kind(d.status)
		gone := d.status == lg.DELTA_DELETED
		f.path = strings.clone(string(gone ? d.old_file.path : d.new_file.path), a)
		if d.status == lg.DELTA_RENAMED {
			f.old_path = strings.clone(string(d.old_file.path), a)
		}
	}
	detail.files = files
	return
}


commit_detail_destroy :: proc(d: ^Commit_Detail) {
	virtual.arena_destroy(&d.arena)
	d^ = {}
}


@(private = "file")
delta_kind :: proc(status: i32) -> Kind {
	switch status {
	case lg.DELTA_ADDED, lg.DELTA_COPIED: return .Added
	case lg.DELTA_DELETED:                return .Deleted
	case lg.DELTA_RENAMED:                return .Renamed
	case lg.DELTA_TYPECHANGE:             return .Typechange
	}
	return .Modified
}


// The id of a file's blob in a commit, or in its first parent; not found when
// that has no such file (or the commit has no parent)
commit_version_id :: proc(
	r: ^Repo,
	rel: string,
	id: Oid,
	parent: bool,
) -> (
	blob: Oid,
	found: bool,
) {
	id := id
	c: ^lg.Commit
	if lg.commit_lookup(&c, r.handle, &id) != lg.OK do return
	defer lg.commit_free(c)

	// The parent instead, if asked
	of := c
	if parent {
		if lg.commit_parentcount(c) == 0 do return
		if lg.commit_parent(&of, c, 0) != lg.OK do return
	}
	defer if of != c do lg.commit_free(of)

	tree: ^lg.Tree
	if lg.commit_tree(&tree, of) != lg.OK do return
	defer lg.tree_free(tree)

	te: ^lg.Tree_Entry
	crel := strings.clone_to_cstring(rel, context.temp_allocator)
	if lg.tree_entry_bypath(&te, tree, crel) != lg.OK do return
	defer lg.tree_entry_free(te)
	return lg.tree_entry_id(te)^, true
}


// A file's text in a commit or its first parent, as checked out, in
// `allocator`, with its blob's id. Not found when that has no such file
read_commit_version :: proc(
	r: ^Repo,
	rel: string,
	id: Oid,
	parent: bool,
	allocator := context.allocator,
) -> (
	data: []u8,
	blob: Oid,
	found: bool,
	problem: string,
) {
	blob, found = commit_version_id(r, rel, id, parent)
	if !found do return

	crel := strings.clone_to_cstring(rel, context.temp_allocator)
	data, problem = blob_text(r, &blob, crel, allocator)
	return data, blob, problem == "", problem
}
