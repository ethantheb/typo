package editor

import "core:path/filepath"
import "core:strings"

// The project: the folder open as the workspace, with its own data in a .typo
// folder inside it (as Zed's .zed): .typo/settings.toml holds its settings,
// layered over the user's (settings.odin), and its pinned files;
// .typo/session.json holds its last state (session.odin), which the
// .gitignore made with the folder keeps out of git. Opening a folder has both
// read on the config thread (project_open); once they land its settings apply
// and its state is restored (project_read). Until then the pending action
// waits, so files opened at startup or from a terminal go after the restored
// panes. Leaving a project, by quitting or opening another folder, saves its
// state (project_leave). .typo is made only when there is something to write.
//
// A folder opened for a file given alone (typo <file>) is a project only if it
// has a .typo folder: otherwise its state is neither restored nor saved


PROJECT_DIR      :: ".typo"
PROJECT_SETTINGS :: "settings.toml"
PROJECT_SESSION  :: "session.json"

Project :: struct {
	root:     string,          // owned; the workspace folder, "" before one opens
	keeps:    bool,            // its state is restored and saved (see above)
	has_dir:  bool,            // it has a .typo folder, as last read or written
	has_file: bool,            // it has a .typo/settings.toml, likewise
	pinned:   [dynamic]string, // owned full paths, in the order pinned
	loading:  u64,             // the read under way (Config_Read_Project.serial); 0 once landed
	serial:   u64,
	restored: bool,            // a session was restored this run: the window keeps its size
}


// A file in a project's .typo folder (temp); "" names the folder
project_file :: proc(root, name: string) -> string {
	parts := name == "" ? []string{root, PROJECT_DIR} : []string{root, PROJECT_DIR, name}
	return filepath.join(parts, context.temp_allocator) or_else ""
}


// --- Opening and leaving -----------------------------------------------------------

// The workspace opened a folder: its files are read on the config thread, and
// the recent files and pins start empty until they land. `as_folder` is false
// for the folder of a file given alone
project_open :: proc(root: string, as_folder: bool) {
	p := &g.project
	if as_folder do state_project_opened(root)
	set_string(&p.root, root)
	p.keeps = as_folder
	p.has_dir = false
	p.has_file = false
	pins_clear()
	recent_clear(&g.recent)

	// Its settings file is watched once read
	config_watch(.Project_Settings, "", {})
	p.serial += 1
	p.loading = p.serial
	config_post(Config_Read_Project{strings.clone(root), p.serial})
}


// Whether the project's files are still being read
project_loading :: proc() -> bool {
	return g.project.loading != 0
}


// The project's files landed: its settings apply, its pinned files and recent
// files are listed, and its last state is restored (the window's size only
// for the first project of the run). An older project's are dropped
project_read :: proc(r: ^Project_Read) {
	p := &g.project
	if r.serial != p.loading do return

	p.loading = 0
	p.has_dir = r.has_dir
	p.has_file = !r.settings.missing
	p.keeps ||= r.has_dir

	// Its settings, watched from here on
	settings_path := project_file(p.root, PROJECT_SETTINGS)
	config_watch(.Project_Settings, settings_path, r.settings_mtime)
	project_pins_read(r.settings.pinned[:])
	settings_take_project(&g.settings, &r.settings)
	apply_settings()

	// Its last state, or what an older typo kept for it
	s, has_session := r.session.?
	if !has_session {
		s, has_session = state_take_imported(p.root)
	}
	if !has_session do return

	recent_load(&g.recent, session_paths(s.recent_files))
	if p.keeps && g.settings.restore_session {
		session_restore(s, window = !p.restored)
		p.restored = true
	}
}


// Leaving the project for another folder: its state is saved, then its panes
// close (files with unsaved changes were asked about first). Local shells end;
// persistent ones go on in herdr-core, and come back when the project opens
project_leave :: proc() {
	session_save()
	panes_close_all()
}


// A write the config thread finished: one into .typo means the folder is
// there now, and so a project; one asked to open, opens
project_written :: proc(w: Config_Written) {
	p := &g.project
	if !w.ok do return

	in_project := p.root != "" && path_within(w.path, project_file(p.root, ""))
	if w.typo_dir && in_project {
		p.has_dir = true
		p.keeps = true
		if same_path(w.path, project_file(p.root, PROJECT_SETTINGS)) {
			p.has_file = true
		}
	}
	if w.open do panes_open_file(w.path)
}


project_destroy :: proc() {
	p := &g.project
	session_saving_destroy()
	pins_clear()
	delete(p.pinned)
	delete(p.root)
	p^ = {}
}


// --- Settings ----------------------------------------------------------------------

// The pinned files, as the project's settings write them: relative to it (temp)
@(private = "file")
pinned_rel :: proc() -> []string {
	pinned := make([]string, len(g.project.pinned), context.temp_allocator)
	for path, i in g.project.pinned do pinned[i] = project_rel(path)
	return pinned
}


// Writes the project's settings and pinned files to .typo/settings.toml (on
// the config thread), unless there is nothing to write and no .typo folder.
// Never before the file was read: what is in memory then isn't the project's
project_save_settings :: proc() {
	p := &g.project
	if p.root == "" || project_loading() {
		return
	}

	text := project_settings_text(&g.settings.project, pinned_rel())
	if text == "" && !p.has_dir {
		return
	}

	config_post(Config_Write{
		path     = strings.clone(project_file(p.root, PROJECT_SETTINGS)),
		text     = strings.clone(text),
		watched  = .Project_Settings,
		typo_dir = true,
	})
}


// Opens the project's settings file in an editor next frame, writing it first
// if there is none (so its folder gets its .gitignore)
project_edit_settings :: proc() {
	p := &g.project
	if p.root == "" do return

	path := project_file(p.root, PROJECT_SETTINGS)
	if p.has_file {
		if g.pending == nil do g.pending = Open_File(strings.clone(path))
		return
	}

	config_post(Config_Write{
		path     = strings.clone(path),
		text     = strings.clone(project_settings_text(&g.settings.project, pinned_rel())),
		watched  = .Project_Settings,
		typo_dir = true,
		open     = true,
	})
}


// --- Pinned files ------------------------------------------------------------------

project_pinned :: proc(path: string) -> bool {
	for pin in g.project.pinned {
		if same_path(pin, path) do return true
	}
	return false
}


// Pins a file: it is listed first under RECENT, saved with the project's
// settings
project_pin :: proc(path: string) {
	if project_pinned(path) || g.project.root == "" {
		return
	}

	append(&g.project.pinned, strings.clone(path))
	project_save_settings()
}


project_unpin :: proc(path: string) {
	pins := &g.project.pinned
	for pin, i in pins {
		if !same_path(pin, path) do continue

		delete(pin)
		ordered_remove(pins, i)
		project_save_settings()
		return
	}
}


// The pinned files as the settings file lists them, in place of the current
// ones (each once)
project_pins_read :: proc(written: []string) {
	pins_clear()
	for rel in written {
		path := project_abs(rel)
		if !project_pinned(path) {
			append(&g.project.pinned, strings.clone(path))
		}
	}
}


// A file or folder was renamed in typo: the pins in it follow
project_pins_renamed :: proc(from, to: string) {
	changed := false
	for &pin in g.project.pinned {
		if !path_within(pin, from) do continue

		renamed := strings.concatenate({to, pin[len(from):]})
		delete(pin)
		pin = renamed
		changed = true
	}
	if changed do project_save_settings()
}


// A file or folder was deleted in typo: the pins in it go
project_pins_forget :: proc(path: string) {
	pins := &g.project.pinned
	changed := false
	for i := len(pins) - 1; i >= 0; i -= 1 {
		if !path_within(pins[i], path) do continue

		delete(pins[i])
		ordered_remove(pins, i)
		changed = true
	}
	if changed do project_save_settings()
}


@(private = "file")
pins_clear :: proc() {
	for pin in g.project.pinned do delete(pin)
	clear(&g.project.pinned)
}


// --- Paths -------------------------------------------------------------------------

// A path as the project's files keep it (temp): relative to the project with
// forward slashes when inside it, else whole
project_rel :: proc(path: string) -> string {
	root := g.project.root
	if root == "" || path == root || !path_within(path, root) {
		return path
	}

	start := len(root)
	if !is_separator(root[len(root) - 1]) do start += 1 // not a drive root like "C:\"
	rel, _ := strings.replace_all(path[start:], "\\", "/", context.temp_allocator)
	return rel
}


// A path the project's files keep, as a full path (temp)
project_abs :: proc(path: string) -> string {
	if path == "" || filepath.is_abs(path) || g.project.root == "" {
		return path
	}

	native, _ := strings.replace_all(path, "/", filepath.SEPARATOR_STRING, context.temp_allocator)
	return filepath.join({g.project.root, native}, context.temp_allocator) or_else path
}


// Paths a project's files keep, as full paths (temp)
session_paths :: proc(paths: []string) -> []string {
	full := make([]string, len(paths), context.temp_allocator)
	for path, i in paths do full[i] = project_abs(path)
	return full
}
