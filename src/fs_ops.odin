package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Creating, renaming and deleting files and folders from the tree, keeping open
// files, the tree and the finder's index in step


// Deleting moves to the Recycle Bin on Windows (fs_ops_windows.odin), unless an
// item can't go there; then, and elsewhere, it is permanent once confirmed
DELETE_TO_TRASH :: ODIN_OS == .Windows

Delete_Result :: enum {
	Done,
	Failed,
	Not_Recyclable, // nothing was deleted
}


delete_path :: proc(path: string, permanent: bool) -> Delete_Result {
	when DELETE_TO_TRASH {
		if !permanent do return move_to_trash(path)
	}

	if os.remove_all(path) != nil {
		return .Failed
	}
	return .Done
}


// Whether `path` is `dir` or inside it
path_within :: proc(path, dir: string) -> bool {
	if path == dir do return true

	return len(path) > len(dir) &&
	       strings.has_prefix(path, dir) &&
	       is_separator(path[len(dir)])
}


// Why `name` can't name a file or folder, or ""
@(private = "file")
name_problem :: proc(name: string) -> string {
	switch {
	case name == "":                  return "Enter a name."
	case name == "." || name == "..": return "That name is reserved."
	}

	for r in name {
		if r < ' ' {
			return "A name can't contain control characters."
		}
	}

	when ODIN_OS == .Windows {
		if strings.contains_any(name, `<>:"|?*`) {
			return `A name can't contain < > : " | ? or *.`
		}
		if strings.has_suffix(name, ".") || strings.has_suffix(name, " ") {
			return "A name can't end with a dot or a space."
		}

		// Device names, with any extension
		stem := name
		if dot := strings.index_byte(name, '.'); dot >= 0 {
			stem = name[:dot]
		}
		stem = strings.to_upper(strings.trim_right_space(stem), context.temp_allocator)

		RESERVED :: [?]string{
			"CON", "PRN", "AUX", "NUL",
			"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
			"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
		}
		for reserved in RESERVED {
			if stem == reserved {
				return fmt.tprintf("%s is reserved by Windows.", name)
			}
		}
	}

	return ""
}


// Renames a file or folder to `name` in the same folder. Returns why it
// couldn't, or ""
rename_path :: proc(path, name: string) -> (problem: string) {
	if strings.contains_any(name, `/\`) {
		return "A name can't contain slashes."
	}
	if problem := name_problem(name); problem != "" {
		return problem
	}
	if name == filepath.base(path) do return ""

	to, _ := filepath.join({filepath.dir(path), name}, context.temp_allocator)

	// Only the case differs: the same file on Windows, so no clash
	same_file := ODIN_OS == .Windows && strings.equal_fold(to, path)
	if os.exists(to) && !same_file {
		return fmt.tprintf("%s already exists.", name)
	}
	if err := os.rename(path, to); err != nil {
		return fmt.tprintf("Couldn't rename: %v", err)
	}

	// Open files follow their new path
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if !is_editor || !path_within(e.path, path) {
			continue
		}

		renamed := strings.concatenate({to, e.path[len(path):]})
		delete(e.path)
		e.path = renamed
		editor_path_changed(e)
	}

	// So do the Markdown modes chosen this session
	moved := make([dynamic]string, context.temp_allocator)
	for key in g.md_modes {
		if path_within(key, path) do append(&moved, key)
	}
	for key in moved {
		mode := g.md_modes[key]
		renamed := strings.concatenate({to, key[len(path):]})
		delete_key(&g.md_modes, key)
		delete(key)
		g.md_modes[renamed] = mode
	}

	workspace_refresh(&g.workspace)
	finder_invalidate()
	return ""
}


// Creates a file or folder `name` in `dir`; slashes in it make the folders
// between. A new file opens. Returns why it couldn't, or ""
create_path :: proc(dir, name: string, folder: bool) -> (problem: string) {
	if name == "" do return "Enter a name."

	for part in strings.split_multi(name, {"/", `\`}, context.temp_allocator) {
		if part == "" do return "That name isn't allowed."

		if problem := name_problem(part); problem != "" {
			return problem
		}
	}

	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.exists(path) {
		return fmt.tprintf("%s already exists.", name)
	}

	err: os.Error
	if folder {
		err = os.make_directory_all(path)
	} else {
		parent := filepath.dir(path)
		if parent != dir {
			err = os.make_directory_all(parent)
		}
		if err == nil {
			err = os.write_entire_file(path, []u8{})
		}
	}
	if err != nil {
		return fmt.tprintf("Couldn't create it: %v", err)
	}

	workspace_refresh(&g.workspace)
	workspace_reveal(&g.workspace, path)
	finder_invalidate()

	if !folder do panes_open_file(path)
	return ""
}


// After deleting a file or folder: its open files close (it was confirmed, so
// unsaved changes go too) and the tree and the finder forget it
path_deleted :: proc(path: string) {
	// Close the files that were inside it
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		if i >= len(g.panes.open) do continue

		pane := g.panes.open[i]
		e, is_editor := pane.content.(^Editor)
		if is_editor && path_within(e.path, path) {
			pane_close(pane, ask = false)
		}
	}

	workspace_refresh(&g.workspace)
	finder_invalidate()
}
