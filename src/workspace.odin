package editor

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import sdl "vendor:sdl3"

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
	return len(path) > len(dir) && strings.has_prefix(path, dir) && (path[len(dir)] == '\\' || path[len(dir)] == '/')
}


@(private = "file")
load_children :: proc(ws: ^Workspace, index: int) {
	ws.nodes[index].loaded = true
	dir_path := ws.nodes[index].path
	depth := ws.nodes[index].depth + (index == 0 ? 0 : 1)

	infos, err := os.read_all_directory_by_path(dir_path, context.temp_allocator)
	if err != nil do return

	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {
		a_dir, b_dir := a.type == .Directory, b.type == .Directory
		if a_dir != b_dir do return a_dir
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})

	for info in infos {
		child := len(ws.nodes)
		append(&ws.nodes, Node {
			name   = strings.clone(info.name),
			path   = strings.clone(info.fullpath),
			is_dir = info.type == .Directory,
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
	sync.guard(&picked.mutex)
	delete(picked.path)
	picked.path = strings.clone_from_cstring(filelist[0])
}

// Returns a folder chosen in the dialog since the last call, if any. Caller owns the string.
take_picked_folder :: proc() -> (path: string, ok: bool) {
	sync.guard(&picked.mutex)
	path, picked.path = picked.path, ""
	return path, path != ""
}
