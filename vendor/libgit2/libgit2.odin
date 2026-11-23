package libgit2

// Bindings to libgit2 (the release pinned in build.py, built without SHA-256,
// so object ids are 20 bytes) for what typo uses: opening a repository, its
// status, HEAD and the upstream, the index (reading blobs, staging and
// unstaging), and checking files out of the index. Check the struct layouts
// against include/git2 when LIBGIT2_VERSION changes

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib {
		"../../build/obj/libgit2/lib/git2.lib",
		"system:ws2_32.lib",
		"system:secur32.lib",
		"system:advapi32.lib",
		"system:rpcrt4.lib",
		"system:ole32.lib",
		"system:crypt32.lib",
	}
} else when ODIN_OS == .Darwin {
	foreign import lib {
		"../../build/obj/libgit2/lib/libgit2.a",
		"system:iconv",
		"system:CoreFoundation.framework",
		"system:Security.framework",
	}
} else {
	foreign import lib {
		"../../build/obj/libgit2/lib/libgit2.a",
		"system:pthread",
	}
}


// --- Opaque types ------------------------------------------------------------------

Repository  :: struct {}
Reference   :: struct {}
Index       :: struct {}
Status_List :: struct {}
Object      :: struct {}
Tree        :: struct {}
Tree_Entry  :: struct {}
Blob        :: struct {}


// --- Values ------------------------------------------------------------------------

OID_SIZE :: 20

Oid :: struct {
	id: [OID_SIZE]u8,
}

Object_Size :: u64

Strarray :: struct {
	strings: [^]cstring,
	count:   c.size_t,
}

Error :: struct {
	message: cstring,
	klass:   c.int,
}

// Return codes typo looks at
OK            :: 0
ERROR         :: -1
ENOTFOUND     :: -3
EUNBORNBRANCH :: -9
ELOCKED       :: -14
EOWNER        :: -36

// git_repository_open_flag_t
REPOSITORY_OPEN_NO_SEARCH :: 1 << 0
REPOSITORY_OPEN_CROSS_FS  :: 1 << 1

Repository_State :: enum c.int {
	None,
	Merge,
	Revert,
	Revert_Sequence,
	Cherrypick,
	Cherrypick_Sequence,
	Bisect,
	Rebase,
	Rebase_Interactive,
	Rebase_Merge,
	Apply_Mailbox,
	Apply_Mailbox_Or_Rebase,
}

// git_status_t
Status_Flag :: enum c.uint {
	Index_New        = 0,
	Index_Modified   = 1,
	Index_Deleted    = 2,
	Index_Renamed    = 3,
	Index_Typechange = 4,
	Wt_New           = 7,
	Wt_Modified      = 8,
	Wt_Deleted       = 9,
	Wt_Typechange    = 10,
	Wt_Renamed       = 11,
	Wt_Unreadable    = 12,
	Ignored          = 14,
	Conflicted       = 15,
}
Status_Flags :: distinct bit_set[Status_Flag; c.uint]

Status_Show :: enum c.int {
	Index_And_Workdir = 0,
	Index_Only        = 1,
	Workdir_Only      = 2,
}

// git_status_opt_t
STATUS_OPT_INCLUDE_UNTRACKED       :: 1 << 0
STATUS_OPT_EXCLUDE_SUBMODULES      :: 1 << 3
STATUS_OPT_RECURSE_UNTRACKED_DIRS  :: 1 << 4
STATUS_OPT_DISABLE_PATHSPEC_MATCH  :: 1 << 5
STATUS_OPT_RENAMES_HEAD_TO_INDEX   :: 1 << 7
STATUS_OPT_SORT_CASE_INSENSITIVELY :: 1 << 10

STATUS_OPTIONS_VERSION :: 1

Status_Options :: struct {
	version:          c.uint,
	show:             Status_Show,
	flags:            c.uint,
	pathspec:         Strarray,
	baseline:         ^Tree,
	rename_threshold: u16,
}

Diff_File :: struct {
	id:        Oid,
	path:      cstring,
	size:      Object_Size,
	flags:     u32,
	mode:      u16,
	id_abbrev: u16,
}

Diff_Delta :: struct {
	status:     c.int,
	flags:      u32,
	similarity: u16,
	nfiles:     u16,
	old_file:   Diff_File,
	new_file:   Diff_File,
}

Status_Entry :: struct {
	status:           Status_Flags,
	head_to_index:    ^Diff_Delta,
	index_to_workdir: ^Diff_Delta,
}

Index_Time :: struct {
	seconds:     i32,
	nanoseconds: u32,
}

Index_Entry :: struct {
	ctime:          Index_Time,
	mtime:          Index_Time,
	dev:            u32,
	ino:            u32,
	mode:           u32,
	uid:            u32,
	gid:            u32,
	file_size:      u32,
	id:             Oid,
	flags:          u16,
	flags_extended: u16,
	path:           cstring,
}

// A buffer libgit2 fills; freed with buf_dispose
Buf :: struct {
	ptr:      [^]u8,
	reserved: c.size_t,
	size:     c.size_t,
}

// git_blob_filter_flag_t
BLOB_FILTER_CHECK_FOR_BINARY :: 1 << 0

BLOB_FILTER_OPTIONS_VERSION :: 1

Blob_Filter_Options :: struct {
	version:        c.int,
	flags:          u32,
	commit_id:      ^Oid,
	attr_commit_id: Oid,
}

Filter_List :: struct {}

Filter_Mode :: enum c.int {
	To_Worktree = 0, // smudge: as checked out
	To_Odb      = 1, // clean: as stored
}

// git_checkout_strategy_t
CHECKOUT_FORCE                  :: 1 << 1
CHECKOUT_DISABLE_PATHSPEC_MATCH :: 1 << 13

CHECKOUT_OPTIONS_VERSION :: 1

Checkout_Options :: struct {
	version:           c.uint,
	checkout_strategy: c.uint,
	disable_filters:   c.int,
	dir_mode:          c.uint,
	file_mode:         c.uint,
	file_open_flags:   c.int,
	notify_flags:      c.uint,
	notify_cb:         rawptr,
	notify_payload:    rawptr,
	progress_cb:       rawptr,
	progress_payload:  rawptr,
	paths:             Strarray,
	baseline:          ^Tree,
	baseline_index:    ^Index,
	target_directory:  cstring,
	ancestor_label:    cstring,
	our_label:         cstring,
	their_label:       cstring,
	perfdata_cb:       rawptr,
	perfdata_payload:  rawptr,
}


// --- Functions ---------------------------------------------------------------------

@(default_calling_convention = "c", link_prefix = "git_")
foreign lib {
	libgit2_init     :: proc() -> c.int ---
	libgit2_shutdown :: proc() -> c.int ---
	error_last       :: proc() -> ^Error ---

	repository_open_ext :: proc(
		out: ^^Repository,
		path: cstring,
		flags: c.uint,
		ceiling_dirs: cstring,
	) -> c.int ---
	repository_free          :: proc(repo: ^Repository) ---
	repository_workdir       :: proc(repo: ^Repository) -> cstring ---
	repository_path          :: proc(repo: ^Repository) -> cstring ---
	repository_commondir     :: proc(repo: ^Repository) -> cstring ---
	repository_head          :: proc(out: ^^Reference, repo: ^Repository) -> c.int ---
	repository_head_detached :: proc(repo: ^Repository) -> c.int ---
	repository_state         :: proc(repo: ^Repository) -> Repository_State ---
	repository_index         :: proc(out: ^^Index, repo: ^Repository) -> c.int ---

	reference_free            :: proc(ref: ^Reference) ---
	reference_name            :: proc(ref: ^Reference) -> cstring ---
	reference_shorthand       :: proc(ref: ^Reference) -> cstring ---
	reference_target          :: proc(ref: ^Reference) -> ^Oid ---
	reference_symbolic_target :: proc(ref: ^Reference) -> cstring ---
	reference_lookup          :: proc(
		out: ^^Reference,
		repo: ^Repository,
		name: cstring,
	) -> c.int ---
	branch_upstream     :: proc(out: ^^Reference, branch: ^Reference) -> c.int ---
	graph_ahead_behind  :: proc(
		ahead, behind: ^c.size_t,
		repo: ^Repository,
		local, upstream: ^Oid,
	) -> c.int ---

	status_options_init    :: proc(opts: ^Status_Options, version: c.uint) -> c.int ---
	status_list_new        :: proc(
		out: ^^Status_List,
		repo: ^Repository,
		opts: ^Status_Options,
	) -> c.int ---
	status_list_entrycount :: proc(list: ^Status_List) -> c.size_t ---
	status_byindex         :: proc(list: ^Status_List, idx: c.size_t) -> ^Status_Entry ---
	status_list_free       :: proc(list: ^Status_List) ---

	index_read            :: proc(index: ^Index, force: c.int) -> c.int ---
	index_write           :: proc(index: ^Index) -> c.int ---
	index_add             :: proc(index: ^Index, entry: ^Index_Entry) -> c.int ---
	index_add_bypath      :: proc(index: ^Index, path: cstring) -> c.int ---
	index_remove_bypath   :: proc(index: ^Index, path: cstring) -> c.int ---
	index_get_bypath      :: proc(index: ^Index, path: cstring, stage: c.int) -> ^Index_Entry ---
	index_add_from_buffer :: proc(
		index: ^Index,
		entry: ^Index_Entry,
		buffer: rawptr,
		len: c.size_t,
	) -> c.int ---
	index_free            :: proc(index: ^Index) ---

	reset_default   :: proc(repo: ^Repository, target: ^Object, pathspecs: ^Strarray) -> c.int ---
	revparse_single :: proc(out: ^^Object, repo: ^Repository, spec: cstring) -> c.int ---
	object_free     :: proc(object: ^Object) ---

	tree_entry_bypath   :: proc(out: ^^Tree_Entry, root: ^Tree, path: cstring) -> c.int ---
	tree_entry_id       :: proc(entry: ^Tree_Entry) -> ^Oid ---
	tree_entry_filemode :: proc(entry: ^Tree_Entry) -> c.uint ---
	tree_entry_free     :: proc(entry: ^Tree_Entry) ---

	blob_lookup     :: proc(out: ^^Blob, repo: ^Repository, id: ^Oid) -> c.int ---
	blob_rawcontent :: proc(blob: ^Blob) -> rawptr ---
	blob_rawsize    :: proc(blob: ^Blob) -> Object_Size ---
	blob_free       :: proc(blob: ^Blob) ---

	blob_filter_options_init :: proc(opts: ^Blob_Filter_Options, version: c.uint) -> c.int ---
	blob_filter              :: proc(
		out: ^Buf,
		blob: ^Blob,
		as_path: cstring,
		opts: ^Blob_Filter_Options,
	) -> c.int ---
	filter_list_load            :: proc(
		filters: ^^Filter_List,
		repo: ^Repository,
		blob: ^Blob,
		path: cstring,
		mode: Filter_Mode,
		flags: u32,
	) -> c.int ---
	filter_list_apply_to_buffer :: proc(
		out: ^Buf,
		filters: ^Filter_List,
		input: [^]u8,
		in_len: c.size_t,
	) -> c.int ---
	filter_list_free            :: proc(filters: ^Filter_List) ---
	buf_dispose                 :: proc(buf: ^Buf) ---

	checkout_options_init :: proc(opts: ^Checkout_Options, version: c.uint) -> c.int ---
	checkout_index        :: proc(
		repo: ^Repository,
		index: ^Index,
		opts: ^Checkout_Options,
	) -> c.int ---
}
