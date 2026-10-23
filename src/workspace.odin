package editor

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import sdl "../vendor/sdl3"

// A lazily loaded directory tree. Directory contents are read the first time a
// directory is expanded, so opening a large folder (or a drive root) is cheap.

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
	root:    string,
	nodes:   [dynamic]Node, // nodes[0] is the root directory
	visible: [dynamic]int,  // flattened, in display order; rebuilt when the tree changes
}

// A folder's display name: its last path element, or the path itself for a
// drive root like "C:\".
folder_name :: proc(path: string) -> string {
	name := filepath.base(strings.trim_right(path, "/\\"))
	return name == "" || name == "." || strings.has_suffix(name, ":") ? path : name
}

// `path` relative to the workspace root, or unchanged if outside it.
relative_to_root :: proc(path: string) -> string {
	root := g.workspace.root
	if len(path) <= len(root) || !strings.has_prefix(path, root) do return path
	if is_separator(root[len(root) - 1]) do return path[len(root):] // a drive root like "C:\"
	if is_separator(path[len(root)]) do return path[len(root) + 1:]
	return path
}

workspace_open :: proc(ws: ^Workspace, root: string) {
	workspace_destroy(ws)
	ws.root = strings.clone(root)
	append(&ws.nodes, Node{name = strings.clone(folder_name(root)), path = strings.clone(root), is_dir = true})
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
	ws^ = {}
}

// Expands or collapses a directory, reading its contents on first expand.
workspace_toggle :: proc(ws: ^Workspace, index: int) {
	if !ws.nodes[index].is_dir do return
	if !ws.nodes[index].loaded {
		load_children(ws, index)
	}
	ws.nodes[index].expanded = !ws.nodes[index].expanded
	rebuild_visible(ws)
}

// Expands every directory between the root and `path` so it shows in the tree.
workspace_reveal :: proc(ws: ^Workspace, path: string) {
	index := 0
	outer: for {
		for child in ws.nodes[index].children {
			node := ws.nodes[child]
			if !node.is_dir || !is_path_prefix(node.path, path) do continue
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
	return len(path) > len(dir) && strings.has_prefix(path, dir) && is_separator(path[len(dir)])
}

@(private = "file")
is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}

@(private = "file")
load_children :: proc(ws: ^Workspace, index: int) {
	ws.nodes[index].loaded = true
	dir_path := ws.nodes[index].path
	depth := ws.nodes[index].depth + (index == 0 ? 0 : 1)

	entries, ok := list_directory(dir_path)
	if !ok do return
	// As in core:os, directory symlinks and junctions show as files.
	for &e in entries do e.is_dir = e.is_dir && !e.is_link

	slice.sort_by(entries, proc(a, b: Dir_Entry) -> bool {
		if a.is_dir != b.is_dir do return a.is_dir
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})

	sep := is_separator(dir_path[len(dir_path) - 1]) ? "" : os.Path_Separator_String // a drive root like "C:\"
	for entry in entries {
		child := len(ws.nodes)
		append(&ws.nodes, Node {
			name   = strings.clone(entry.name),
			path   = strings.concatenate({dir_path, sep, entry.name}),
			is_dir = entry.is_dir,
			depth  = depth,
		})
		// ws.nodes may have reallocated, so index rather than holding a pointer.
		append(&ws.nodes[index].children, child)
	}
}

@(private = "file")
rebuild_visible :: proc(ws: ^Workspace) {
	clear(&ws.visible)
	add :: proc(ws: ^Workspace, index: int) {
		for child in ws.nodes[index].children {
			append(&ws.visible, child)
			if ws.nodes[child].expanded do add(ws, child)
		}
	}
	add(ws, 0)
}

// --- Folder picker ------------------------------------------------------------
// SDL may invoke the dialog callback on another thread, so the result is handed
// over through a mutex and applied on the main thread.

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
	if filelist == nil || filelist[0] == nil do return // error or cancelled
	sync.lock(&picked.mutex)
	delete(picked.path)
	picked.path = strings.clone_from_cstring(filelist[0])
	sync.unlock(&picked.mutex)
	wake_main_loop(nil)
}

// Returns a folder chosen in the dialog since the last call, if any. Caller owns the string.
take_picked_folder :: proc() -> (path: string, ok: bool) {
	sync.guard(&picked.mutex)
	path, picked.path = picked.path, ""
	return path, path != ""
}
