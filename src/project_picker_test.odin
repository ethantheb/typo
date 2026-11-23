package editor

import "core:strings"
import "core:sync"
import "core:testing"

import sdl "../vendor/sdl3"
import "fuzzy"


// Opening a project puts it first among the recent ones, once, and the list
// keeps RECENT_PROJECTS_MAX
@(test)
test_recent_projects :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	defer state_destroy()

	state_project_opened("C:/a")
	state_project_opened("C:/b")
	state_project_opened("C:/A") // the same folder, as Windows sees it
	recent := state_recent_projects()
	testing.expect_value(t, len(recent), 2)
	if len(recent) == 2 {
		testing.expect_value(t, recent[0], "C:/A")
		testing.expect_value(t, recent[1], "C:/b")
	}

	for i in 0 ..< RECENT_PROJECTS_MAX + 4 {
		name := strings.repeat("x", i + 1, context.temp_allocator)
		state_project_opened(strings.concatenate({"C:/many", name}, context.temp_allocator))
	}
	testing.expect_value(t, len(state_recent_projects()), RECENT_PROJECTS_MAX)
}


// The popup's keys: typing filters, Down moves, Enter opens here, Ctrl+Enter
// in another window, Esc closes
@(test)
test_project_picker_keys :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	defer {
		state_destroy()
		project_picker_destroy()
		g.project_picker = {}
		fuzzy.destroy()
	}

	state_project_opened("C:/work/beta")
	state_project_opened("C:/work/alpha") // first: the most recent

	// Enter on the first row opens it here
	project_picker_toggle()
	testing.expect(t, g.project_picker.open)
	testing.expect(t, picker_key(sdl.K_RETURN, {}))
	testing.expect(t, !g.project_picker.open)
	folder, here := g.pending.(Open_Folder)
	testing.expect(t, here && string(folder) == "C:/work/alpha")
	take_pending()

	// Filtered to beta; Ctrl+Enter opens it in another window
	project_picker_toggle()
	type_filter("bet")
	testing.expect(t, picker_key(sdl.K_RETURN, sdl.KMOD_LCTRL))
	window, elsewhere := g.pending.(Open_Window)
	testing.expect(t, elsewhere && string(window) == "C:/work/beta")
	take_pending()

	// Down past the projects reaches Open folder…, and Esc closes
	project_picker_toggle()
	for _ in 0 ..< 5 do picker_key(sdl.K_DOWN, {})
	testing.expect_value(t, g.project_picker.selected, 2)
	testing.expect(t, picker_key(sdl.K_ESCAPE, {}))
	testing.expect(t, !g.project_picker.open)
	testing.expect(t, g.pending == nil)
}


@(private = "file")
picker_key :: proc(key: sdl.Keycode, mod: sdl.Keymod) -> bool {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	event.key.mod = mod
	return project_picker_handle_event(&event)
}


@(private = "file")
type_filter :: proc(text: string) {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(text, context.temp_allocator)
	project_picker_handle_event(&event)
}


// Frees the pending action's string
@(private = "file")
take_pending :: proc() {
	#partial switch a in g.pending {
	case Open_Folder: delete(string(a))
	case Open_Window: delete(string(a))
	}
	g.pending = nil
}
