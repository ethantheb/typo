package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"
import sdl "../vendor/sdl3"
import "mdview"

App :: struct {
	ctx:             runtime.Context,
	window:          ^sdl.Window,
	clay_memory:     []u8,

	// Logical window size and pixels-per-logical-unit.
	window_w:        i32,
	window_h:        i32,
	window_size:     [2]i32, // the size while not maximized, for the session

	// Input collected from events, consumed once per frame.
	mouse_pos:       [2]f32,
	mouse_down:      bool,
	mouse_pressed:   bool,
	mouse_clicks:    int, // 1, 2, 3 for single/double/triple click of the last press
	last_press_pos:  [2]f32,
	wheel:           [2]f32,

	frame:           u64,
	window_shown:    bool,
	last_ticks:      u64,
	dt:              f32,
	fps:             f32, // frames presented per second, measured over FPS_WINDOW
	fps_frames:      int,
	fps_t0:          u64,

	// Frames are only drawn while something changes (see schedule_next_frame).
	wake_frames:     int,  // frames still to draw after input
	sleeping:        bool, // the frame being built is the last before sleeping

	workspace:       Workspace,
	panes:           Panes,
	md_modes:        map[string]mdview.Mode, // Markdown files toggled this session, by path
	sidebar_visible: bool,
	sidebar_gone:    bool, // hidden, and done sliding out
	dialog:          Dialog,
	unsaved:         Unsaved_Flow,
	menu:            Context_Menu,
	rename:          Inline_Rename,
	in_popup:        bool, // building the dialog's or context menu's UI (see ui_interactive)
	right_pressed:   bool, // the right button went down this frame
	quit:            bool, // set once quitting was confirmed
	finder:          Finder,
	settings:        Settings,
	fonts:           gfx.System_Fonts,
	settings_window: Settings_Window,
	in_modal:        bool, // building a popup's UI (see ui_interactive)
	animating:       bool, // a Clay transition was unfinished at the end of the last layout
	tooltip:         Tooltip_State,
	pending:         Action,
	open_heading:    string, // owned; where the caret goes in the file `pending` opens
	perf:           ^Perf, // set by --perf
}

g: App

FPS_WINDOW :: 500_000_000 // ns
// How far apart (logical pixels) presses may be to count as a double/triple click.
MULTI_CLICK_DISTANCE :: 4
// Frames drawn after each input event before going idle. More than one, since
// some UI reactions (e.g. a click's action) land on the following frame.
WAKE_FRAMES :: 3

main :: proc() {
	g.ctx = context
	os.exit(int(sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)))
}

Args :: struct {
	path:     string, // folder to open, or a file; the working directory if empty
	terminal: bool,   // start with a terminal filling the window (folders only)
	perf:     bool,   // run the performance suite (perf.odin) and exit
}

// typo [--terminal | -t] [--perf] [folder | file]
@(private = "file")
parse_args :: proc() -> (args: Args) {
	for arg in os.args[1:] {
		switch arg {
		case "--terminal", "-t": args.terminal = true
		case "--perf":           args.perf = true
		case:                    if args.path == "" do args.path = arg
		}
	}
	return
}

app_init :: proc "c" (appstate: ^rawptr, argc: i32, argv: [^]cstring) -> sdl.AppResult {
	context = g.ctx
	args := parse_args()
	if args.perf do args.path = perf_begin()

	_ = sdl.SetAppMetadata("typo", "0.1", "dev.typo")
	// Without this, the click that focuses the window is swallowed.
	_ = sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1")
	if !sdl.Init({.VIDEO}) {
		sdl.Log("SDL_Init failed: %s", sdl.GetError())
		return .FAILURE
	}
	// Shown after the first frame drawn with the editor ready (see app_iterate),
	// so it never appears half drawn.
	g.window = sdl.CreateWindow("typo", 1280, 800, {.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN})
	set_window_icon()
	if g.window == nil {
		sdl.Log("SDL_CreateWindow failed: %s", sdl.GetError())
		return .FAILURE
	}
	gfx.wake = wake_main_loop
	md_env_init()
	// The renderer backend is a setting.
	settings_init(&g.settings)
	if !create_renderer(g.settings.renderer) do return .FAILURE
	update_window_metrics()
	if !gfx.text_init(&gfx.text_system) do return .FAILURE
	apply_settings()

	min_memory := uint(clay.MinMemorySize())
	g.clay_memory = make([]u8, min_memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory, raw_data(g.clay_memory))
	clay.Initialize(arena, {f32(g.window_w), f32(g.window_h)}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)

	// With no arguments, the last session if there is one (session.odin).
	if !(len(os.args) == 1 && g.perf == nil && g.settings.restore_session && session_restore()) {
		open_path(args.path, args.terminal)
	}
	// Text input stays on; the focused pane or popup consumes TEXT_INPUT events.
	_ = sdl.StartTextInput(g.window)
	g.last_ticks = sdl.GetTicksNS()
	return .CONTINUE
}

// The named SDL backend, or SDL's default (Direct3D 11 on Windows) for "auto"
// or when the named one can't be created.
@(private = "file")
create_renderer :: proc(name: string) -> bool {
	if name != "auto" {
		cname := strings.clone_to_cstring(name, context.temp_allocator)
		gfx.renderer = sdl.CreateRenderer(g.window, cname)
		if gfx.renderer == nil do sdl.Log("renderer %s unavailable (%s); using the default", cname, sdl.GetError())
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

// Opens the startup path: a folder (with the sidebar), or a single file in its
// folder's workspace. A path ending in a separator that doesn't exist is created
// as a folder; any other missing path opens as a new file, created on first save.
@(private = "file")
open_path :: proc(path: string, terminal: bool) {
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	root := path != "" ? path : cwd
	if !os.exists(root) && (strings.has_suffix(root, "/") || strings.has_suffix(root, `\`)) {
		_ = os.make_directory_all(root)
	}
	if os.is_dir(root) {
		open_folder(root)
		g.sidebar_visible = true
		if terminal do panes_new_terminal()
		return
	}
	file := os.get_absolute_path(root, context.temp_allocator) or_else root
	dir := filepath.dir(file)
	open_folder(os.is_dir(dir) ? dir : cwd)
	g.pending = Open_File(strings.clone(file))
}

// Called every frame, including during Windows' modal resize loop, which is
// what lets the layout reflow live while the window edge is being dragged.
app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = g.ctx

	now := sdl.GetTicksNS()
	g.dt = f32(now - g.last_ticks) / 1e9
	g.last_ticks = now
	// Frames are counted over a window; restarted after sleeping.
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
		if done, ok := perf_frame(); done do return ok ? .SUCCESS : .FAILURE
	}
	if g.quit do return .SUCCESS

	update_window_metrics()
	track_window_size()
	clay.SetLayoutDimensions({f32(g.window_w), f32(g.window_h)})
	clay.SetPointerState(g.mouse_pos, g.mouse_down)
	update_scroll_containers()

	settings_poll(&g.settings)
	if gfx.fonts_poll(&g.fonts) {
		apply_editor_font()
		apply_markdown_font()
	}
	apply_pending_action()
	dialog_frame()
	context_menu_frame()
	rename_frame()
	update_focus()
	finder_frame()
	panes_frame()
	g.wake_frames = max(g.wake_frames - 1, 0)
	g.sleeping = g.wake_frames == 0 && !needs_continuous_frames()
	tooltip_begin_frame()
	commands := build_ui()
	tooltip_end_frame()
	update_mouse_cursor()
	if g.perf != nil do perf_mark(.Update)

	_ = sdl.SetRenderDrawColor(gfx.renderer, u8(gfx.theme.panel.r), u8(gfx.theme.panel.g), u8(gfx.theme.panel.b), 255)
	_ = sdl.RenderClear(gfx.renderer)
	render_clay_commands(&commands, gfx.scale)
	if g.perf != nil do perf_mark(.Render)
	_ = sdl.RenderPresent(gfx.renderer)
	if !g.window_shown && panes_ready() {
		_ = sdl.ShowWindow(g.window)
		g.window_shown = true
	}
	if g.perf != nil do perf_mark(.Present)

	g.wheel = {}
	g.mouse_pressed = false
	g.right_pressed = false
	g.frame += 1
	gfx.text_end_frame(&gfx.text_system)
	schedule_next_frame()
	free_all(context.temp_allocator)
	return .CONTINUE
}

// Whether the next frame should follow immediately even without input.
needs_continuous_frames :: proc() -> bool {
	switch {
	case g.pending != nil,
	     finder_busy(),
	     panes_busy(),
	     smooth_scrolling(),
	     g.settings.show_fps, // measure the real frame rate
	     tooltip_pending(),
	     g.animating,
	     g.perf != nil && perf_running():
		return true
	}
	return false
}

// Draws continuously while something is changing; otherwise sleeps until the
// next event.
schedule_next_frame :: proc() {
	_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, g.sleeping ? "waitevent" : "0")
}

// Makes an idle main loop run a frame. Safe to call from any thread.
wake_main_loop :: proc "contextless" (userdata: rawptr) {
	event: sdl.Event
	event.type = .USER
	_ = sdl.PushEvent(&event)
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = g.ctx
	// The performance suite drives the app itself; real input would disturb it
	// and wake the idle phases.
	if g.perf != nil {
		#partial switch event.type {
		case .KEY_DOWN, .KEY_UP, .TEXT_INPUT, .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
			return .CONTINUE
		}
	}
	// Input wakes the loop for a few frames; a wake event asks for just one.
	if event.type == .USER {
		g.wake_frames = max(g.wake_frames, 1)
	} else {
		g.wake_frames = WAKE_FRAMES
		_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "0")
	}

	#partial switch event.type {
	case .QUIT:
		if !panes_unsaved() do return .SUCCESS
		resolve_unsaved(g.panes.open[:], Quit{})
	case .KEY_DOWN, .TEXT_INPUT:
		handle_key_event(event)
	case .MOUSE_MOTION:
		g.mouse_pos = {event.motion.x, event.motion.y}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if event.button.button == sdl.BUTTON_RIGHT && event.button.down do g.right_pressed = true
		if event.button.button == sdl.BUTTON_LEFT {
			g.mouse_down = event.button.down
			if event.button.down {
				g.mouse_pressed = true
				// SDL times double/triple clicks, but its distance tolerance spans
				// more than a line of text; only chain clicks on the same spot.
				p := [2]f32{event.button.x, event.button.y}
				d := p - g.last_press_pos
				same_spot := abs(d.x) <= MULTI_CLICK_DISTANCE && abs(d.y) <= MULTI_CLICK_DISTANCE
				g.mouse_clicks = event.button.clicks > 1 && same_spot ? g.mouse_clicks + 1 : 1
				g.last_press_pos = p
			}
		}
		g.mouse_pos = {event.button.x, event.button.y}
	case .MOUSE_WHEEL:
		g.wheel += {event.wheel.x, event.wheel.y}
	case .WINDOW_DISPLAY_SCALE_CHANGED:
		update_window_metrics()
	}
	return .CONTINUE
}

// Keyboard input goes to the open popup, else the focused pane; keys nobody
// uses are tried as command shortcuts.
handle_key_event :: proc(event: ^sdl.Event) {
	if event.type == .KEY_DOWN && event.key.key == sdl.K_ESCAPE && g.panes.drag.active {
		drag_clear()
		return
	}
	if dialog_handle_event(event) do return
	if rename_handle_event(event) do return
	if g.menu.open {
		if event.type == .KEY_DOWN && event.key.key == sdl.K_ESCAPE do menu_close()
		return
	}
	if settings_window_handle_event(event) do return
	if finder_handle_event(event) do return
	if t := focused_terminal(); t != nil && t.initialized && terminal_handle_event(t, event) do return
	e := focused_editor()
	if event.type == .TEXT_INPUT {
		if e != nil do editor_text_input(e, string(event.text.text))
		return
	}
	if event.key.key == sdl.K_F12 {
		clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		return
	}
	if cmd, ok := command_for_key(event.key); ok && run_command(cmd) do return
	if e != nil do editor_handle_key(e, event.key)
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = g.ctx
	session_save()
	finder_destroy()
	menu_close()
	rename_destroy()
	dialog_destroy()
	panes_destroy()
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
	delete(g.clay_memory)
	if g.perf != nil do perf_end()
	// SDL destroys the window/renderer and calls SDL_Quit after this returns.
}

// Refreshes the logical size and display scale; a new scale re-rasterizes text.
update_window_metrics :: proc() {
	_ = sdl.GetWindowSize(g.window, &g.window_w, &g.window_h)
	scale := sdl.GetWindowDisplayScale(g.window)
	if scale <= 0 do scale = 1
	if scale == gfx.scale do return
	gfx.set_scale(&gfx.text_system, scale)
	if gfx.text_system.engine != nil do clay.ResetMeasureTextCache()
}

clay_error_handler :: proc "c" (error: clay.ErrorData) {
	context = g.ctx
	sdl.Log("Clay error: %.*s", error.errorText.length, error.errorText.chars)
}

// The window's icon at a few sizes, for SDL to pick the nearest.
@(private = "file")
ICON_PNGS := [?][]u8 {
	#load("../assets/icon/typo-192.png"),
	#load("../assets/icon/typo-32.png"),
	#load("../assets/icon/typo-16.png"),
}

@(private = "file")
set_window_icon :: proc() {
	if g.window == nil do return
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

// --- Actions --------------------------------------------------------------------
// UI actions that replace the tree, a buffer or the panes. They are applied at
// the start of the next frame, because this frame's render commands still point
// at the strings they would free.

Toggle_Node :: distinct int
Open_File :: distinct string   // owned, full path
Open_Folder :: distinct string // owned
Run_Command :: distinct Command

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
	Open_Folder,
	Run_Command,
	Pane_Op,
}

// Sets the pending action, unless one is already waiting.
defer_action :: proc(a: Action) {
	if g.pending == nil do g.pending = a
}

@(private = "file")
apply_pending_action :: proc() {
	if path, ok := take_picked_folder(); ok {
		if g.pending == nil do g.pending = Open_Folder(path)
		else do delete(path)
	}

	switch a in g.pending {
	case Toggle_Node:
		workspace_toggle(&g.workspace, int(a))
	case Open_File:
		p := panes_open_file(string(a))
		if e, ok := p.content.(^Editor); ok && e.md != nil && g.open_heading != "" {
			mdview.jump_to_heading(&e.md_view, g.open_heading)
		}
		delete(string(a))
		delete(g.open_heading)
		g.open_heading = ""
	case Open_Folder:
		files := make([dynamic]^Pane, context.temp_allocator)
		for p in g.panes.open do if _, ok := p.content.(^Editor); ok do append(&files, p)
		resolve_unsaved(files[:], a) // takes the string
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

open_folder :: proc(path: string) {
	path := os.get_absolute_path(path, context.temp_allocator) or_else path
	if len(path) > 3 do path = strings.trim_right(path, "/\\") // keep "C:\"
	workspace_open(&g.workspace, path)
	title := fmt.ctprintf("%s - typo", folder_name(path))
	_ = sdl.SetWindowTitle(g.window, title)
	finder_invalidate()
	scroll := clay.GetScrollContainerData(clay.ID("SidebarFiles"))
	if scroll.found do scroll.scrollPosition^ = {}
}
