package editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import sdl "../vendor/sdl3"

// A lazily loaded directory tree. Directory contents are read the first time a
// directory is expanded, so opening a large folder (or a drive root) is cheap


Node :: struct {
	name:     string,
	path:     string, // full path
	is_dir:   bool,
	expanded: bool,
	loaded:   bool,
	depth:    int,
	children: [dynamic]int,
}

Workspace :: struct {
	root:           string,
	nodes:          [dynamic]Node, // nodes[0] is the root directory
	visible:        [dynamic]int,  // flattened, in display order; rebuilt when the tree changes
	loaded_version: int,           // counts changes to the folders loaded (kept across opens)
}


// A folder's display name: its last path element, or the path itself for a
// drive root like "C:\"
folder_name :: proc(path: string) -> string {
	name := filepath.base(strings.trim_right(path, "/\\"))
	is_drive := name == "" || name == "." || strings.has_suffix(name, ":")
	return is_drive ? path : name
}


// `path` relative to the workspace root, or unchanged if outside it
relative_to_root :: proc(path: string) -> string {
	root := g.workspace.root
	if len(path) <= len(root) || !strings.has_prefix(path, root) {
		return path
	}

	if is_separator(root[len(root) - 1]) do return path[len(root):] // a drive root like "C:\"
	if is_separator(path[len(root)]) do return path[len(root) + 1:]
	return path
}


workspace_open :: proc(ws: ^Workspace, root: string) {
	workspace_destroy(ws)

	ws.root = strings.clone(root)
	root_node := Node {
		name   = strings.clone(folder_name(root)),
		path   = strings.clone(root),
		is_dir = true,
	}
	append(&ws.nodes, root_node)

	workspace_toggle(ws, 0)
}


workspace_destroy :: proc(ws: ^Workspace) {
	for &n in ws.nodes {
		delete(n.name)
		delete(n.path)
		delete(n.children)
	}
	delete(ws.nodes)
	delete(ws.visible)
	delete(ws.root)

	version := ws.loaded_version
	ws^ = {}
	ws.loaded_version = version + 1
}


// Reads the tree again after files changed, keeping open folders open
workspace_refresh :: proc(ws: ^Workspace) {
	expanded := make([dynamic]string, context.temp_allocator)
	for n, i in ws.nodes {
		if i > 0 && n.expanded {
			append(&expanded, strings.clone(n.path, context.temp_allocator))
		}
	}

	workspace_open(ws, strings.clone(ws.root, context.temp_allocator))
	workspace_expand(ws, expanded[:])
}


// Expands the folders at `paths`, parents listed before their children
workspace_expand :: proc(ws: ^Workspace, paths: []string) {
	// A parent comes before its children, so each is loaded by its turn
	for path in paths {
		for n, i in ws.nodes {
			if n.is_dir && !n.expanded && n.path == path {
				workspace_toggle(ws, i)
				break
			}
		}
	}
}


// Expands or collapses a directory, reading its contents on first expand
workspace_toggle :: proc(ws: ^Workspace, index: int) {
	if !ws.nodes[index].is_dir do return

	if !ws.nodes[index].loaded {
		load_children(ws, index)
	}
	ws.nodes[index].expanded = !ws.nodes[index].expanded
	rebuild_visible(ws)
}


// Expands every directory between the root and `path` so it shows in the tree
workspace_reveal :: proc(ws: ^Workspace, path: string) {
	index := 0
	outer: for {
		for child in ws.nodes[index].children {
			node := ws.nodes[child]
			if !node.is_dir || !is_path_prefix(node.path, path) {
				continue
			}

			if !node.loaded do load_children(ws, child)
			ws.nodes[child].expanded = true
			index = child
			continue outer
		}
		break
	}

	rebuild_visible(ws)
}


@(private = "file")
is_path_prefix :: proc(dir, path: string) -> bool {
	return len(path) > len(dir) &&
	       strings.has_prefix(path, dir) &&
	       is_separator(path[len(dir)])
}


is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}


@(private = "file")
load_children :: proc(ws: ^Workspace, index: int) {
	ws.nodes[index].loaded = true
	ws.loaded_version += 1

	entries, ok := read_tree_folder(ws.nodes[index].path)
	if !ok do return

	for entry in entries {
		child := add_node(ws, index, entry)
		// ws.nodes may have reallocated, so index rather than holding a pointer
		append(&ws.nodes[index].children, child)
	}
}


// Adds a node for an entry of the folder at `parent`, not yet among its
// children. Returns its index
@(private = "file")
add_node :: proc(ws: ^Workspace, parent: int, entry: Dir_Entry) -> int {
	dir_path := ws.nodes[parent].path
	depth := ws.nodes[parent].depth + (parent == 0 ? 0 : 1)

	// A drive root like "C:\" already ends in a separator
	sep := is_separator(dir_path[len(dir_path) - 1]) ? "" : os.Path_Separator_String
	append(&ws.nodes, Node {
		name   = strings.clone(entry.name),
		path   = strings.concatenate({dir_path, sep, entry.name}),
		is_dir = entry.is_dir,
		depth  = depth,
	})
	return len(ws.nodes) - 1
}


// --- Changes on disk ---------------------------------------------------------------

// The folders whose entries the tree has read, in the temp allocator
workspace_loaded_dirs :: proc(ws: ^Workspace) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	for n in ws.nodes {
		if n.is_dir && n.loaded {
			append(&dirs, n.path)
		}
	}
	return dirs[:]
}


// Brings loaded folders in line with their entries listed again: new entries
// get rows and gone ones lose theirs, with everything under them. The rest stay
// as they were, expanded or not, keyed by path as before
workspace_apply_listings :: proc(ws: ^Workspace, listings: []Folder_Listing) {
	if len(ws.nodes) == 0 || len(listings) == 0 {
		return
	}

	loaded := make(map[string]int, allocator = context.temp_allocator)
	for n, i in ws.nodes {
		if n.is_dir && n.loaded {
			loaded[path_key(n.path, context.temp_allocator)] = i
		}
	}

	removed := false
	for l in listings {
		index, found := loaded[path_key(l.dir, context.temp_allocator)]
		if !found do continue

		if update_children(ws, index, l.entries) do removed = true
	}

	// New nodes aren't loaded, so only removals change the loaded folders
	if removed {
		drop_unreachable(ws)
		ws.loaded_version += 1
	}
	rebuild_visible(ws)
}


// Gives a folder's node the listed entries as children, keeping the nodes of
// those it had. Returns true if some are gone (left unreachable)
@(private = "file")
update_children :: proc(ws: ^Workspace, index: int, entries: []Dir_Entry) -> bool {
	old := ws.nodes[index].children
	by_name := make(map[string]int, allocator = context.temp_allocator)
	for child in old {
		by_name[ws.nodes[child].name] = child
	}

	children := make([dynamic]int, 0, len(entries))
	for entry in entries {
		child, had := by_name[entry.name]
		if had && ws.nodes[child].is_dir == entry.is_dir {
			delete_key(&by_name, entry.name)
		} else {
			child = add_node(ws, index, entry)
		}
		append(&children, child)
	}

	delete(old)
	ws.nodes[index].children = children
	return len(by_name) > 0
}


// Frees the nodes no longer reachable from the root, keeping the order of the
// rest (the root stays first)
@(private = "file")
drop_unreachable :: proc(ws: ^Workspace) {
	// Reachable from the root
	reachable := make([]bool, len(ws.nodes), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, 0)
	for len(stack) > 0 {
		i := pop(&stack)
		reachable[i] = true
		append(&stack, ..ws.nodes[i].children[:])
	}

	// Kept nodes move down; the rest are freed
	new_index := make([]int, len(ws.nodes), context.temp_allocator)
	kept := 0
	for i in 0 ..< len(ws.nodes) {
		n := ws.nodes[i]
		if !reachable[i] {
			delete(n.name)
			delete(n.path)
			delete(n.children)
			continue
		}

		new_index[i] = kept
		ws.nodes[kept] = n
		kept += 1
	}
	resize(&ws.nodes, kept)

	for &n in ws.nodes {
		for &child in n.children do child = new_index[child]
	}
}


@(private = "file")
rebuild_visible :: proc(ws: ^Workspace) {
	clear(&ws.visible)
	add_visible(ws, 0)
}


// Adds the children of a node to the visible list, and theirs while expanded
@(private = "file")
add_visible :: proc(ws: ^Workspace, index: int) {
	for child in ws.nodes[index].children {
		append(&ws.visible, child)
		if ws.nodes[child].expanded do add_visible(ws, child)
	}
}


// --- Folder picker -----------------------------------------------------------------

// SDL may invoke the dialog callback on another thread, so the result is handed
// over through a mutex and applied on the main thread

@(private = "file")
picked: struct {
	mutex: sync.Mutex,
	path:  string,
}


show_open_folder_dialog :: proc() {
	location := strings.clone_to_cstring(g.workspace.root, context.temp_allocator)
	sdl.ShowOpenFolderDialog(folder_dialog_callback, nil, g.window, location, false)
}


@(private = "file")
folder_dialog_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = g.ctx

	// An error, or cancelled
	if filelist == nil || filelist[0] == nil {
		return
	}

	sync.lock(&picked.mutex)
	delete(picked.path)
	picked.path = strings.clone_from_cstring(filelist[0])
	sync.unlock(&picked.mutex)

	wake_main_loop(nil)
}


// Returns a folder chosen in the dialog since the last call, if any. Caller owns
// the string
take_picked_folder :: proc() -> (path: string, ok: bool) {
	sync.guard(&picked.mutex)
	path, picked.path = picked.path, ""
	return path, path != ""
}
