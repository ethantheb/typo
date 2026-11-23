package git

// A Git repository, as typo shows and changes it. libgit2 does the reads and
// the index in-process (repo.odin): finding the repository, its status, HEAD
// and the upstream, blobs for diffs, staging, unstaging and discarding. The
// git command line does commit, push, pull and fetch (cli.odin), so hooks,
// signing and credential helpers work as they do in a terminal.
//
// None of it runs on the UI thread. A worker thread owns the repository
// (worker.odin): the UI thread queues requests and takes finished events. The
// worker follows the repository by itself: it refreshes the status when asked
// (the app asks when the file watcher reports changes in the work tree) and
// when the files that describe the repository change (the index, HEAD, the
// branch's and the upstream's refs), which it polls, as they may be outside
// the workspace (a linked worktree's) and the watcher ignores .git

import "core:strings"

import lg "../../vendor/libgit2"


// A blob's id
Oid :: lg.Oid

// Which list of the Git pane an entry is in
Area :: enum u8 {
	Conflicts, // unmerged
	Staged,    // HEAD to the index
	Changes,   // the index to the work tree
	Untracked, // in the work tree only
}

Kind :: enum u8 {
	Modified,
	Added,
	Deleted,
	Renamed,
	Typechange,
	Untracked,
	Conflicted,
}

// A file in one area. A file staged and then changed again is in two
Entry :: struct {
	path:     string, // relative to the work tree, '/' between folders
	old_path: string, // where a rename came from, else ""
	area:     Area,
	kind:     Kind,
}

// What a merge or rebase under way is called, or ""
Operation :: enum u8 {
	None,
	Merging,
	Rebasing,
	Cherry_Picking,
	Reverting,
	Bisecting,
}

// A repository's state at one refresh. Its strings are slices of `text`, so a
// status is two allocations however many files it lists, and may be copied
Status :: struct {
	entries:    []Entry, // owned; by area, then path
	counts:     [Area]int,
	branch:     string,  // "" when HEAD is detached
	head:       string,  // HEAD's short id ("" before the first commit)
	upstream:   string,  // the branch's upstream, e.g. "origin/main", or ""
	ahead:      int,     // commits the branch has that the upstream hasn't
	behind:     int,
	unborn:     bool,    // no commit yet
	operation:  Operation,
	generation: u64,     // counts refreshes
	text:       []u8,    // owned; the strings above
}

// A repository found for a folder
Repo_Info :: struct {
	workdir: string, // the work tree, without a trailing separator
	gitdir:  string, // where its HEAD and index are
	common:  string, // where its refs are (the main repository's, for a linked worktree)
}

// Which version of a file a diff side shows
Version :: enum u8 {
	Head,  // the last commit's
	Index, // the staged one
}


// Frees a status and everything in it
status_destroy :: proc(s: ^Status) {
	delete(s.entries)
	delete(s.text)
	s^ = {}
}


repo_info_destroy :: proc(info: ^Repo_Info) {
	delete(info.workdir)
	delete(info.gitdir)
	delete(info.common)
	info^ = {}
}


repo_info_clone :: proc(info: Repo_Info, allocator := context.allocator) -> Repo_Info {
	return {
		workdir = strings.clone(info.workdir, allocator),
		gitdir  = strings.clone(info.gitdir, allocator),
		common  = strings.clone(info.common, allocator),
	}
}


// An entry's file as a full path, with the system's separators (temp)
full_path :: proc(workdir, rel: string) -> string {
	joined := strings.concatenate({workdir, "/", rel}, context.temp_allocator)
	return native_path(joined, context.temp_allocator)
}


// A path relative to the work tree, '/' between folders, if `path` is in it
relative_path :: proc(workdir, path: string) -> (rel: string, ok: bool) {
	if len(path) <= len(workdir) do return "", false

	head := path[:len(workdir)]
	if !same_text(head, workdir) || !is_separator(path[len(workdir)]) {
		return "", false
	}

	rel = path[len(workdir) + 1:]
	return forward_slashes(rel, context.temp_allocator), true
}


// The status's entries of one area
entries_in :: proc(s: ^Status, area: Area) -> []Entry {
	start := 0
	for a in Area {
		if a == area do return s.entries[start:start + s.counts[a]]
		start += s.counts[a]
	}
	return nil
}


// The entry for a path in an area, if any
find_entry :: proc(s: ^Status, area: Area, rel: string) -> (Entry, bool) {
	for e in entries_in(s, area) {
		if e.path == rel do return e, true
	}
	return {}, false
}


// A status letter, as git status --short shows it
kind_letter :: proc(k: Kind) -> string {
	switch k {
	case .Modified:   return "M"
	case .Added:      return "A"
	case .Deleted:    return "D"
	case .Renamed:    return "R"
	case .Typechange: return "T"
	case .Untracked:  return "U"
	case .Conflicted: return "!"
	}
	return "?"
}


operation_name :: proc(op: Operation) -> string {
	switch op {
	case .None:           return ""
	case .Merging:        return "Merging"
	case .Rebasing:       return "Rebasing"
	case .Cherry_Picking: return "Cherry-picking"
	case .Reverting:      return "Reverting"
	case .Bisecting:      return "Bisecting"
	}
	return ""
}


// --- Paths -------------------------------------------------------------------------

// A path with the system's separators and no trailing one (but "C:\" keeps it)
native_path :: proc(path: string, allocator := context.allocator) -> string {
	out := strings.clone(path, allocator)
	when ODIN_OS == .Windows {
		bytes := transmute([]u8)out
		for &c in bytes {
			if c == '/' do c = '\\'
		}
	}

	for len(out) > 1 && is_separator(out[len(out) - 1]) && out[len(out) - 2] != ':' {
		out = out[:len(out) - 1]
	}
	return out
}


@(private)
forward_slashes :: proc(path: string, allocator := context.allocator) -> string {
	out := strings.clone(path, allocator)
	bytes := transmute([]u8)out
	for &c in bytes {
		if c == '\\' do c = '/'
	}
	return out
}


@(private)
is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}


// Paths compare without case on Windows, and either separator matches
@(private)
same_text :: proc(a, b: string) -> bool {
	if len(a) != len(b) do return false

	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if is_separator(x) && is_separator(y) {
			continue
		}
		when ODIN_OS == .Windows {
			x = ascii_lower(x)
			y = ascii_lower(y)
		}
		if x != y do return false
	}
	return true
}


@(private)
ascii_lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c
}


// libgit2's message for the last error on this thread (temp)
@(private)
last_error :: proc(fallback: string) -> string {
	e := lg.error_last()
	if e == nil || e.message == nil {
		return fallback
	}
	return strings.clone(string(e.message), context.temp_allocator)
}
