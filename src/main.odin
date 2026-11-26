package editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"
import "ipc"
import "process"
import sdl "../vendor/sdl3"
import "langs"
import "mdview"

App :: struct {
	ctx:             runtime.Context,
	window:          ^sdl.Window,
	clay_memory:     []u8,

	// Logical window size
	window_w:        i32,
	window_h:        i32,
	window_size:     [2]i32, // the size while not maximized, for the session
	coord_scale:     f32,    // window coordinates per layout unit

	// Input collected from events, consumed once per frame
	mouse_pos:       [2]f32,
	mouse_down:      bool,
	mouse_pressed:   bool,
	mouse_clicks:    int, // 1, 2, 3 for single/double/triple click of the last press
	last_press_pos:  [2]f32,
	wheel:           [2]f32,
	button_chord:    Maybe(Chord), // a mouse button a binding may name went down

	frame:           u64,
	window_shown:    bool,
	last_ticks:      u64,
	dt:              f32,
	fps:             f32, // frames presented per second, measured over FPS_WINDOW
	fps_frames:      int,
	fps_t0:          u64,

	// Frames are only drawn while something changes (see schedule_next_frame)
	wake_frames:     int,  // frames still to draw after input
	sleeping:        bool, // the frame being built is the last before sleeping

	workspace:       Workspace,
	panes:           Panes,
	md_modes:        map[string]mdview.Mode, // Markdown files toggled this session, by path
	sidebar_visible: bool,
	sidebar_search:  Sidebar_Search,
	in_sidebar:      bool, // building the sidebar (see ui_interactive)
	in_search_popup: bool, // building the sidebar search's popup (see ui_interactive)
	project_picker:  Project_Picker,
	in_project_picker: bool, // building the recent projects popup (see ui_interactive)
	row_clips:       int,    // row_clip's taken this frame
	frame_clips:     int,    // clipping elements the last frame drew (perf)
	clay_errors:     struct {
		count:    int,              // errors Clay reported, ever
		kind:     clay.ErrorType,   // the last one's
		last:     [160]u8,          // the last one's text (cut short)
		last_len: int,
	},
	dialog:          Dialog,
	unsaved:         Unsaved_Flow,
	menu:            Context_Menu,
	rename:          Inline_Rename,
	find:            Find,
	goto_line:       Goto_Line,
	in_popup:        bool, // building the dialog's or context menu's UI (see ui_interactive)
	in_find_bar:     bool, // building the find bar (see ui_interactive)
	in_goto_bar:     bool, // building the go to line bar (see ui_interactive)
	in_pane:         ^Pane, // building this pane's header or body (see ui_interactive)
	right_pressed:   bool, // the right button went down this frame
	quit:            bool, // set once quitting was confirmed
	finder:          Finder,
	lsp:             Lsp_State,
	git:             Git_State,
	zoom_popup:      Zoom_Popup,
	settings:        Settings,
	fonts:           gfx.System_Fonts,
	settings_window: Settings_Window,
	in_modal:        bool, // building a popup's UI (see ui_interactive)
	animating:       bool, // a Clay transition was unfinished at the end of the last layout
	over_text_field: bool, // the pointer is over a text field (or selecting in one) this frame
	measure_stale:   bool, // the interface font changed: Clay's measurements are reset next frame
	tooltip:         Tooltip_State,
	pending:         Action,
	open_heading:    string, // owned; where the caret goes in the file `pending` opens
	open_target:     Maybe(Open_Target), // or this: a place in it
	jumps:           Jumps,              // Go back and Go forward
	project:         Project,            // the folder open, its settings and state
	recent:          Recent_Files,       // the project's recently used files
	perf:            ^Perf,  // set by --perf
}

g: App

FPS_WINDOW :: 500_000_000 // ns

// How far apart (logical pixels) presses may be to count as a double/triple click
MULTI_CLICK_DISTANCE :: 4

// Frames drawn after each input event before going idle. More than one, since
// some UI reactions (e.g. a click's action) land on the following frame
WAKE_FRAMES :: 3


main :: proc() {
	g.ctx = context

	// `typo ctl <command>`: a control request to the window this runs in, never
	// a window of its own (control_cli.odin)
	if len(os.args) > 1 && os.args[1] == CONTROL_WORD {
		os.exit(control_main(os.args[2:]))
	}
	startup = parse_args()

	// A restart: the window that started this one ends first (control.odin)
	if startup.after > 0 do _ = process.wait_for_exit(startup.after, AFTER_WAIT_MS)

	// In one of typo's terminals, files open in that window
	if code, forwarded := forward_to_window(startup); forwarded {
		os.exit(code)
	}

	// This window's children never see another window's endpoint
	os.unset_env(ipc.ENV_NAME)
	for name in AGENT_SESSION_ENV do os.unset_env(name)

	result := sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
	os.exit(int(result))
}


// What a coding agent (Claude Code) marks its own processes with. A typo started
// by one would hand them to its shells and herdr-core, and an agent started in
// those would take itself for that agent's child
@(private = "file")
AGENT_SESSION_ENV := [?]string {
	"CLAUDECODE",
	"CLAUDE_PID",
	"CLAUDE_AGENT_SDK_VERSION",
	"CLAUDE_CODE_ENTRYPOINT",
	"CLAUDE_CODE_CHILD_SESSION",
	"CLAUDE_CODE_CHILD_NOTES_DIR",
	"CLAUDE_CODE_SESSION_ID",
	"CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_CODE_MESSAGING_SOCKET",
	"CLAUDE_CODE_MESSAGING_TOKEN",
}


Args :: struct {
	paths:      []string, // a folder or files, then more files; the working directory if none
	terminal:   bool,     // start with a terminal filling the window (folders only)
	new_window: bool,     // in a typo terminal, open a new window instead of using that one
	perf:       bool,     // run the performance suite (perf.odin) and exit
	after:      int,      // a restart: the typo to wait for, whose session is restored
}

@(private = "file")
startup: Args

// How long a restarted typo waits for the one it replaces to end (quitting
// waits for writes and threads to finish)
@(private = "file")
AFTER_WAIT_MS :: 60_000


// typo [--terminal | -t] [--new | -n] [--perf] [--after <pid>] [folder | file] [file...]
@(private = "file")
parse_args :: proc() -> (args: Args) {
	paths := make([dynamic]string)
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		switch arg {
		case "--terminal", "-t": args.terminal = true
		case "--new", "-n":      args.new_window = true
		case "--perf":           args.perf = true
		case "--after":
			if i + 1 < len(os.args) {
				i += 1
				args.after = strconv.parse_int(os.args[i], 10) or_else 0
			}
		case:
			append(&paths, arg)
		}
	}

	args.paths = paths[:]
	return
}


app_init :: proc "c" (appstate: ^rawptr, argc: i32, argv: [^]cstring) -> sdl.AppResult {
	context = g.ctx

	args := startup
	if args.perf do args.paths = []string{perf_begin()}

	// SDL, its log kept for `typo ctl log` (control_input.odin)
	control_log_init()
	_ = sdl.SetAppMetadata("typo", "0.1", "dev.typo")
	// Without this, the click that focuses the window is swallowed
	_ = sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1")
	// The perf suite's window doesn't take the keys from what the user is doing
	if args.perf do _ = sdl.SetHint(sdl.HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0")
	if !sdl.Init({.VIDEO}) {
		sdl.Log("SDL_Init failed: %s", sdl.GetError())
		return .FAILURE
	}

	// The window, shown after the first frame drawn with the editor ready (see
	// app_iterate), so it never appears half drawn
	window_flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN}
	size := WINDOW_SIZE
	g.window = sdl.CreateWindow("typo", size.x, size.y, window_flags + window_frame_flags())
	set_window_icon()
	if g.window == nil {
		sdl.Log("SDL_CreateWindow failed: %s", sdl.GetError())
		return .FAILURE
	}
	window_frame_init()

	// Settings, then the renderer (its backend is a setting) and text. The
	// config thread reads and writes settings files and projects' state from
	// here on (config_io.odin)
	gfx.wake = wake_main_loop
	md_env_init()
	config_init()
	settings_init(&g.settings)
	state_init()
	if !create_renderer(g.settings.renderer) do return .FAILURE
	update_window_metrics()
	window_set_size(WINDOW_SIZE, center = true)
	if !gfx.text_init(&gfx.text_system) do return .FAILURE
	apply_settings()

	// Language servers, which the perf suite starts only in its own phase
	if g.perf == nil do lsp_init()

	// `typo <file>` from this window's terminals
	ipc_init()

	// Terminals that keep running in herdr-core (terminal_persist.odin)
	persist_init()

	// Changes other programs make to files (fs_watch.odin)
	watch_init()

	// Reading files to open and writing files to save (file_io.odin)
	io_init()

	// The words of files, for word completions
	words_init()

	// The workspace's repository, and the diff views' loader (git_state.odin,
	// diff_load.odin)
	git_init()
	diff_load_init()

	// Clay
	min_memory := uint(clay.MinMemorySize())
	g.clay_memory = make([]u8, min_memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory, raw_data(g.clay_memory))
	clay.Initialize(arena, {f32(g.window_w), f32(g.window_h)}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)

	// With no arguments the last project, else what the arguments name. Its
	// state is restored once its files are read (project.odin)
	last := state_last_project()
	reopen := len(os.args) == 1 && g.perf == nil && g.settings.restore_session
	if reopen && last != "" && os.is_dir(last) {
		open_folder(last)
		g.sidebar_visible = true
	} else {
		// A restart brings its session back whatever restore_session says
		g.project.restore_forced = args.after > 0
		open_paths(args.paths, args.terminal)
	}

	// Text input stays on; the focused pane or popup consumes TEXT_INPUT events
	_ = sdl.StartTextInput(g.window)
	g.last_ticks = sdl.GetTicksNS()
	return .CONTINUE
}

// The named SDL backend, or SDL's default when it can't be created
@(private = "file")
create_renderer :: proc(name: string) -> bool {
	// Direct3D 11 presents through a blit-model swap chain (patches/sdl.patch): a
	// flip-model present isn't synchronized with the window's size, so on an
	// integrated GPU the content trails the edges while the window is resized
	_ = sdl.SetHint("SDL_RENDER_DIRECT3D11_BLIT_MODEL", "1")

	name := name == "auto" ? "" : name
	if name != "" {
		cname := strings.clone_to_cstring(name, context.temp_allocator)
		gfx.renderer = sdl.CreateRenderer(g.window, cname)
		if gfx.renderer == nil {
			sdl.Log("renderer %s unavailable (%s); using the default", cname, sdl.GetError())
		}
	}

	if gfx.renderer == nil do gfx.renderer = sdl.CreateRenderer(g.window, nil)
	if gfx.renderer == nil {
		sdl.Log("SDL_CreateRenderer failed: %s", sdl.GetError())
		return false
	}

	_ = sdl.SetRenderVSync(gfx.renderer, g.perf != nil ? 0 : 1)
	_ = sdl.SetRenderDrawBlendMode(gfx.renderer, {.BLEND})
	return true
}


// Opens the startup paths: a folder (with the sidebar), or a file in its
// folder's workspace, then any further files (further folders are ignored). A
// first path ending in a separator that doesn't exist is created as a folder;
// any other missing path opens as a new file, created on first save. The
// files, and with `terminal` a terminal, open once the project's state is
// restored
@(private = "file")
open_paths :: proc(paths: []string, terminal: bool) {
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	root := len(paths) > 0 ? paths[0] : cwd

	if !os.exists(root) && ends_in_separator(root) {
		_ = os.make_directory_all(root)
	}

	// The workspace: a folder, or a file's folder (a project only if it is one)
	files := paths
	is_folder := os.is_dir(root)
	if is_folder {
		open_folder(root)
		g.sidebar_visible = true

		// The folder was the first path, unless none was given (the working directory)
		files = len(paths) > 0 ? paths[1:] : nil
	} else {
		file := os.get_absolute_path(root, context.temp_allocator) or_else root
		dir := filepath.dir(file)
		open_folder(os.is_dir(dir) ? dir : cwd, as_folder = false)
	}

	// The files
	opening := make([dynamic]string)
	for path in files {
		if os.is_dir(path) do continue

		file := os.get_absolute_path(path, context.temp_allocator) or_else path
		append(&opening, strings.clone(file))
	}

	start_terminal := terminal && is_folder
	if len(opening) > 0 || start_terminal {
		g.pending = Open_Files{paths = opening[:], terminal = start_terminal}
	} else {
		delete(opening)
	}
}


// Whether a path names a folder by its form ("notes/")
ends_in_separator :: proc(path: string) -> bool {
	return strings.has_suffix(path, "/") || strings.has_suffix(path, `\`)
}


// Called every frame, including during Windows' modal resize loop, which is
// what lets the layout reflow live while the window edge is being dragged
app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = g.ctx

	// Timing. Frames are counted over a window; restarted after sleeping
	now := sdl.GetTicksNS()
	g.dt = f32(now - g.last_ticks) / 1e9
	g.last_ticks = now
	if g.sleeping {
		g.fps_frames, g.fps_t0 = 0, now
		g.dt = 1.0 / 240
	}
	g.fps_frames += 1
	if elapsed := now - g.fps_t0; elapsed >= FPS_WINDOW {
		g.fps = f32(f64(g.fps_frames) / (f64(elapsed) / 1e9))
		g.fps_frames, g.fps_t0 = 0, now
	}

	if g.perf != nil {
		done, ok := perf_frame()
		if done {
			return ok ? .SUCCESS : .FAILURE
		}
	}
	if g.quit do return .SUCCESS
	if window_frame_skips_frame() do return .CONTINUE

	// Window and input
	update_window_metrics()
	track_window_size()
	clay.SetLayoutDimensions({f32(g.window_w), f32(g.window_h)})
	clay.SetPointerState(g.mouse_pos, g.mouse_down)
	update_scroll_containers()

	// Update
	config_frame()
	if gfx.fonts_poll(&g.fonts) {
		apply_ui_font()
		apply_editor_font()
		apply_markdown_font()
	}
	ipc_frame()
	window_frame_frame()
	apply_pending_action()
	dialog_frame()
	file_load_frame()
	unsaved_frame()
	file_sync_frame()
	git_frame()
	diff_views_frame()
	context_menu_frame()
	zoom_popup_frame()
	settings_window_frame()
	settings_servers_frame()
	lsp_frame()
	lsp_edits_frame()
	lsp_rename_frame()
	rename_frame()
	update_focus()
	button_chord_frame()
	finder_frame()
	project_picker_frame()
	sidebar_frame()
	find_frame()
	goto_line_frame()
	panes_frame()
	words_frame()
	lsp_completion_frame()
	lsp_hover_frame()
	g.wake_frames = max(g.wake_frames - 1, 0)
	g.sleeping = g.wake_frames == 0 && !needs_continuous_frames()

	// Clay's text measurements, outside any layout, once the interface font changed
	if g.measure_stale {
		clay.ResetMeasureTextCache()
		g.measure_stale = false
	}

	// Layout
	tooltip_begin_frame()
	commands := build_ui()
	tooltip_end_frame()
	update_mouse_cursor()
	if g.perf != nil do perf_mark(.Update)

	// Draw
	bg := gfx.theme.panel
	_ = sdl.SetRenderDrawColor(gfx.renderer, u8(bg.r), u8(bg.g), u8(bg.b), 255)
	_ = sdl.RenderClear(gfx.renderer)
	render_clay_commands(&commands, gfx.scale)
	gfx.flush_text()
	if g.perf != nil do perf_mark(.Render)
	control_capture()
	_ = sdl.RenderPresent(gfx.renderer)
	if !g.window_shown && !project_loading() && panes_ready() {
		_ = sdl.ShowWindow(g.window)
		g.window_shown = true
		if g.perf != nil do send_window_to_back(window_handle())
	}
	if g.perf != nil do perf_mark(.Present)

	// End of the frame: the state it left saved, if it changed
	session_save_frame()
	g.wheel = {}
	g.over_text_field = false
	g.mouse_pressed = false
	g.right_pressed = false
	g.button_chord = nil
	g.frame += 1
	gfx.text_end_frame(&gfx.text_system)
	control_frame_end()
	schedule_next_frame()
	free_all(context.temp_allocator)
	return .CONTINUE
}


// Whether the next frame should follow immediately even without input
needs_continuous_frames :: proc() -> bool {
	switch {
	case g.pending != nil,
	     loads_busy(),
	     ipc_busy(),
	     finder_busy(),
	     sidebar_search_busy(),
	     find_busy(),
	     panes_busy(),
	     diff_views_busy(),
	     langs.busy(),
	     lsp_hover_busy(),
	     lsp_completion_busy(),
	     words_busy(),
	     smooth_scrolling(),
	     g.settings.show_fps, // measure the real frame rate
	     tooltip_pending(),
	     g.animating,
	     g.measure_stale,
	     g.perf != nil && perf_running():
		return true
	}
	return false
}


// Draws continuously while something is changing; otherwise sleeps until the
// next event
schedule_next_frame :: proc() {
	_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, g.sleeping ? "waitevent" : "0")
}


// Makes an idle main loop run a frame. Safe to call from any thread
wake_main_loop :: proc "contextless" (userdata: rawptr) {
	event: sdl.Event
	event.type = .USER
	_ = sdl.PushEvent(&event)
}


app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = g.ctx

	// The performance suite drives the app itself. Anything else, such as input,
	// the user covering its window or another app's clipboard change, would
	// disturb it and wake the idle phases
	if g.perf != nil {
		#partial switch event.type {
		case .QUIT, .USER, .WINDOW_DISPLAY_SCALE_CHANGED:
		case:
			return .CONTINUE
		}
	}

	// Input wakes the loop for a few frames; a wake event asks for just one
	if event.type == .USER {
		g.wake_frames = max(g.wake_frames, 1)
	} else {
		g.wake_frames = WAKE_FRAMES
		_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "0")
	}

	#partial switch event.type {
	case .QUIT:
		// Writes under way finish first, and running programs are asked about
		ends_shells := len(terminals_ended_by(Quit{})) > 0
		if !panes_unsaved() && !saves_pending() && !ends_shells {
			return .SUCCESS
		}
		resolve_unsaved(g.panes.open[:], Quit{})

	case .KEY_DOWN, .TEXT_INPUT:
		handle_key_event(event)

	case .MOUSE_MOTION:
		g.mouse_pos = window_to_layout(event.motion.x, event.motion.y)

	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		mouse_button_event(event)

	case .MOUSE_WHEEL:
		g.wheel += {event.wheel.x, event.wheel.y}

	case .WINDOW_DISPLAY_SCALE_CHANGED:
		update_window_metrics()
	}
	return .CONTINUE
}


mouse_button_event :: proc(event: ^sdl.Event) {
	right_down := event.button.button == sdl.BUTTON_RIGHT && event.button.down
	if right_down do g.right_pressed = true

	// A button bindings may name (the side buttons) acts like a key, next frame
	chord, is_chord := chord_from_button(event.button.button)
	if is_chord && event.button.down {
		g.button_chord = chord
	}

	if event.button.button == sdl.BUTTON_LEFT {
		g.mouse_down = event.button.down
		if event.button.down {
			g.mouse_pressed = true

			// SDL times double/triple clicks, but its distance tolerance spans
			// more than a line of text; only chain clicks on the same spot
			p := window_to_layout(event.button.x, event.button.y)
			d := p - g.last_press_pos
			same_spot := abs(d.x) <= MULTI_CLICK_DISTANCE && abs(d.y) <= MULTI_CLICK_DISTANCE
			chained := event.button.clicks > 1 && same_spot
			g.mouse_clicks = chained ? g.mouse_clicks + 1 : 1
			g.last_press_pos = p
		}
	}

	g.mouse_pos = window_to_layout(event.button.x, event.button.y)
}


// A point in window coordinates, in the layout's units
window_to_layout :: proc(x, y: f32) -> [2]f32 {
	s := g.coord_scale > 0 ? g.coord_scale : 1
	return {x, y} / s
}


// The window's size before a session gives one, in the layout's units
WINDOW_SIZE :: [2]i32{1280, 800}


// Sizes the window to `size` in the layout's units, no larger than the display
// it is on
window_set_size :: proc(size: [2]i32, center := false) {
	s := g.coord_scale > 0 ? g.coord_scale : 1
	w := i32(math.round(f32(size.x) * s))
	h := i32(math.round(f32(size.y) * s))

	bounds: sdl.Rect
	if sdl.GetDisplayUsableBounds(sdl.GetDisplayForWindow(g.window), &bounds) {
		w = min(w, bounds.w)
		h = min(h, bounds.h)
	}
	if w <= 0 || h <= 0 {
		return
	}

	_ = sdl.SetWindowSize(g.window, w, h)
	if center {
		_ = sdl.SetWindowPosition(g.window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
	}
	update_window_metrics()
}


// A mouse button bound as a chord, pressed since last frame: recorded while the
// settings window waits for a keybinding, else its command runs on the pane under
// the pointer, which it focuses as a click would
@(private = "file")
button_chord_frame :: proc() {
	chord, pressed := g.button_chord.?
	if !pressed do return

	if settings_window_record(chord) do return
	if !ui_interactive() do return

	cmd, bound := command_for_chord(chord)
	if !bound do return

	p := pane_under_pointer()
	if p != nil do pane_focus(p)
	run_command(cmd)
}


// Keyboard input goes to the open popup, else the focused pane; keys nobody
// uses are tried as command shortcuts
handle_key_event :: proc(event: ^sdl.Event) {
	escape := event.type == .KEY_DOWN && event.key.key == sdl.K_ESCAPE

	// Popups
	if escape && g.panes.drag.active {
		drag_clear()
		return
	}
	if dialog_handle_event(event) do return
	if rename_handle_event(event) do return
	if lsp_rename_handle_event(event) do return
	if g.menu.open {
		if escape do menu_close()
		return
	}
	if g.lsp.popup.open && escape {
		lsp_popup_close()
		return
	}
	if g.zoom_popup.open && escape {
		zoom_popup_close()
		return
	}

	// A key (not a modifier alone) closes the hover popup; Esc only does that
	if g.lsp.hover.open && event.type == .KEY_DOWN && !is_modifier(event.key.key) {
		lsp_hover_close()
		if escape do return
	}
	if settings_window_handle_event(event) do return
	if finder_handle_event(event) do return
	if project_picker_handle_event(event) do return
	if sidebar_search_handle_event(event) do return
	if goto_line_handle_event(event) do return
	if find_handle_event(event) do return
	if lsp_completion_handle_key(event) do return

	// The focused pane
	t := focused_terminal()
	if t != nil && t.initialized && terminal_handle_event(t, event) {
		return
	}
	if p := g.panes.focused; p != nil {
		#partial switch c in p.content {
		case ^Git_View:
			if git_view_handle_event(p, c, event) do return
		case ^Diff_View:
			if diff_view_handle_key(c, event) do return
		}
	}
	e := focused_editor()
	if event.type == .TEXT_INPUT {
		if e != nil do editor_text_input(e, string(event.text.text))
		return
	}

	// Shortcuts
	ctrl := event.key.mod & sdl.KMOD_CTRL != {}
	if event.key.key == sdl.K_F12 && ctrl {
		clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		return
	}
	cmd, ok := command_for_key(event.key)
	if ok && run_command(cmd) {
		return
	}
	if e != nil do editor_handle_key(e, event.key)
}


@(private = "file")
is_modifier :: proc(key: sdl.Keycode) -> bool {
	switch key {
	case sdl.K_LCTRL, sdl.K_RCTRL, sdl.K_LSHIFT, sdl.K_RSHIFT, sdl.K_LALT, sdl.K_RALT,
	     sdl.K_LGUI, sdl.K_RGUI:
		return true
	}
	return false
}


app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = g.ctx

	session_save()

	// Gone at once, as the threads below may still be finishing their work
	_ = sdl.HideWindow(g.window)

	// The writer tells the watcher what it wrote: stopped first, its writes done
	io_destroy()
	config_destroy() // its writes done too
	diff_load_destroy()
	git_destroy()
	ipc_destroy()
	watch_destroy()
	finder_destroy()
	sidebar_search_destroy()
	project_picker_destroy()
	find_destroy()
	goto_line_destroy()
	menu_close()
	rename_destroy()
	dialog_destroy()
	panes_destroy()
	persist_destroy()
	file_load_destroy()
	words_destroy()
	lsp_destroy()
	jumps_destroy()
	recent_destroy(&g.recent)
	project_destroy()
	state_destroy()
	settings_window_destroy()
	settings_destroy(&g.settings)
	gfx.fonts_destroy(&g.fonts)
	mdview.images_destroy()
	delete(g.open_heading)
	destroy_mouse_cursors()
	for path in g.md_modes do delete(path)
	delete(g.md_modes)
	workspace_destroy(&g.workspace)
	gfx.text_destroy(&gfx.text_system)
	gfx.box_glyphs_destroy()
	delete(g.clay_memory)

	if g.perf != nil do perf_end()
	control_log_destroy()
	// SDL destroys the window and renderer and calls SDL_Quit after this returns
}


// Refreshes the logical size and display scale; a new scale re-rasterizes text.
// Window coordinates are points where the system scales (macOS) and pixels
// where it doesn't (Windows): the layout's units are the display scale's
update_window_metrics :: proc() {
	scale := sdl.GetWindowDisplayScale(g.window)
	if scale <= 0 do scale = 1

	density := sdl.GetWindowPixelDensity(g.window)
	if density <= 0 do density = 1
	g.coord_scale = scale / density

	w, h: i32
	_ = sdl.GetWindowSize(g.window, &w, &h)
	g.window_w = i32(math.round(f32(w) / g.coord_scale))
	g.window_h = i32(math.round(f32(h) / g.coord_scale))

	if scale == gfx.scale do return

	gfx.set_scale(&gfx.text_system, scale)
	if gfx.text_system.engine != nil do clay.ResetMeasureTextCache()
}


// Clay reports what it couldn't lay out: logged, and counted with the last
// one's text kept, so the perf suite fails a phase that causes one
clay_error_handler :: proc "c" (error: clay.ErrorData) {
	context = g.ctx
	text := string(error.errorText.chars[:error.errorText.length])
	sdl.Log("Clay error: %.*s", i32(len(text)), raw_data(text))

	g.clay_errors.count += 1
	g.clay_errors.kind = error.errorType
	n := copy(g.clay_errors.last[:], text)
	g.clay_errors.last_len = n
}


// The window's icon at a few sizes, for SDL to pick the nearest
@(private = "file")
ICON_PNGS := [?][]u8 {
	#load("../assets/icon/typo-192.png"),
	#load("../assets/icon/typo-32.png"),
	#load("../assets/icon/typo-16.png"),
}


// The window's native handle on Windows, else nil
@(private = "file")
window_handle :: proc() -> rawptr {
	props := sdl.GetWindowProperties(g.window)
	return sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
}


// Brings the window to the front, restoring it if minimized. Windows lets a
// window come forward only while its process or the one that asked (typo in
// a terminal allows it) is in front; otherwise its taskbar button flashes.
// The perf suite's window stays behind
@(private = "file")
raise_window :: proc() {
	if g.perf != nil do return

	if .MINIMIZED in sdl.GetWindowFlags(g.window) {
		_ = sdl.RestoreWindow(g.window)
	}
	_ = sdl.RaiseWindow(g.window)
}


@(private = "file")
set_window_icon :: proc() {
	if g.window == nil do return

	// The first size, with the others as alternates
	icon: ^sdl.Surface
	for png in ICON_PNGS {
		s := sdl.LoadPNG_IO(sdl.IOFromConstMem(raw_data(png), uint(len(png))), true)
		if s == nil do continue
		if icon == nil {
			icon = s
			continue
		}
		_ = sdl.AddSurfaceAlternateImage(icon, s)
		sdl.DestroySurface(s)
	}
	if icon == nil do return

	_ = sdl.SetWindowIcon(g.window, icon)
	sdl.DestroySurface(icon)
}


// --- Actions -----------------------------------------------------------------------

// UI actions that replace the tree, a buffer or the panes. They are applied at
// the start of the next frame, because this frame's render commands still point
// at the strings they would free

Toggle_Node  :: distinct int
Open_File    :: distinct string // owned, full path
Open_Beside  :: distinct string // owned, full path; in a new pane beside the one in use
Open_Folder  :: distinct string // owned
Open_Window  :: distinct string // owned; a folder, in another typo window
Run_Command  :: distinct Command

// Files from the command line or a typo started in a terminal, each in a new
// pane: the first beside the editor in use, the others each beside the one
// before. No open file loses its place
Open_Files :: struct {
	paths:    []string, // owned, full paths
	raise:    bool,     // bring the window to the front
	terminal: bool,     // a new terminal first (typo -t)
}

Pane_Op :: struct {
	pane: ^Pane,
	op:   enum {
		Close,
		Hide,
		Maximize,
	},
}

Action :: union {
	Toggle_Node,
	Open_File,
	Open_Beside,
	Open_Files,
	Open_Folder,
	Open_Window,
	Run_Command,
	Pane_Op,
}


// Sets the pending action, unless one is already waiting
defer_action :: proc(a: Action) {
	if g.pending == nil do g.pending = a
}


@(private = "file")
apply_pending_action :: proc() {
	// Until the project's files are read: its restored panes come first
	if project_loading() do return

	// A folder picked in the dialog, for this window or another
	if path, new_window, ok := take_picked_folder(); ok {
		picked: Action = new_window ? Open_Window(path) : Open_Folder(path)
		if g.pending == nil {
			g.pending = picked
		} else {
			delete(path)
		}
	}

	switch a in g.pending {
	case Toggle_Node:
		workspace_toggle(&g.workspace, int(a))

	case Open_File:
		// The heading or place, once its text is there
		p := panes_open_file(string(a))
		if e, is_file := p.content.(^Editor); is_file {
			editor_when_ready(e, {target = g.open_target, heading = g.open_heading})
			g.open_heading = ""
		}
		delete(string(a))
		delete(g.open_heading)
		g.open_heading = ""
		g.open_target = nil

	case Open_Beside:
		panes_open_file_beside(string(a))
		delete(string(a))

	case Open_Files:
		if a.terminal do panes_new_terminal()

		beside: ^Pane
		for path in a.paths do beside = panes_open_file_beside(path, beside)
		if a.raise do raise_window()
		delete_paths(a.paths)

	case Open_Folder:
		resolve_unsaved(g.panes.open[:], a) // takes the string

	case Open_Window:
		launch_window(string(a))
		delete(string(a))

	case Run_Command:
		run_command(Command(a))

	case Pane_Op:
		switch a.op {
		case .Close: pane_close(a.pane)
		case .Hide:  pane_hide(a.pane)
		case .Maximize:
			pane_focus(a.pane)
			pane_toggle_maximized()
		}
	}
	g.pending = nil
}


// Opens a folder as the workspace and the project (see project_open)
open_folder :: proc(path: string, as_folder := true) {
	path := os.get_absolute_path(path, context.temp_allocator) or_else path
	if len(path) > 3 do path = strings.trim_right(path, "/\\") // keep "C:\"

	langs.stop_all()
	workspace_open(&g.workspace, path)
	project_open(path, as_folder)
	watch_set_root(path)
	git_open_folder(path)
	title := fmt.ctprintf("%s - typo", folder_name(path))
	_ = sdl.SetWindowTitle(g.window, title)
	finder_invalidate()

	scroll := clay.GetScrollContainerData(clay.ID("SidebarFiles"))
	if scroll.found do scroll.scrollPosition^ = {}
}
