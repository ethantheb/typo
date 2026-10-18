package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import clay "../vendor/clay-odin"
import "syntax"
import sdl "../vendor/sdl3"

App :: struct {
	ctx:             runtime.Context,
	window:          ^sdl.Window,
	renderer:        ^sdl.Renderer,
	text:            Text_System,
	clay_memory:     []u8,

	// Logical window size and pixels-per-logical-unit.
	window_w:        i32,
	window_h:        i32,
	ui_scale:        f32,

	// Input collected from events, consumed once per frame.
	mouse_pos:       [2]f32,
	mouse_down:      bool,
	mouse_pressed:   bool,
	mouse_clicks:    int, // 1, 2, 3 for single/double/triple click of the last press
	last_press_pos:  [2]f32,
	wheel:           [2]f32,

	frame:           u64,
	last_ticks:      u64,
	dt:              f32,
	fps:             f32, // frames presented per second, measured over FPS_WINDOW
	fps_frames:      int,
	fps_t0:          u64,

	// Frames are only drawn while something changes (see schedule_next_frame).
	wake_frames:     int,  // frames still to draw after input
	sleeping:        bool, // the frame being built is the last before sleeping
	wake_timer:      sdl.TimerID,

	workspace:       Workspace,
	editor:          Editor,
	terminal_panel:  Terminal_Panel,
	focus:           Focus,
	sidebar_visible: bool,
	finder:          Finder,
	settings:        Settings,
	fonts:           System_Fonts,
	settings_window: Settings_Window,
	in_modal:        bool, // building a popup's UI (see ui_interactive)
	animating:       bool, // a Clay transition was unfinished at the end of the last layout
	tooltip:         Tooltip_State,
	pending:         Action,
	perf:            ^Perf, // set by --perf
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
	terminal: bool,   // start with the terminal filling the window (folders only)
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
	g.window = sdl.CreateWindow("typo", 1280, 800, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if g.window == nil {
		sdl.Log("SDL_CreateWindow failed: %s", sdl.GetError())
		return .FAILURE
	}
	// The renderer backend is a setting.
	settings_init(&g.settings)
	if !create_renderer(g.settings.renderer) do return .FAILURE
	update_window_metrics()
	if !text_init(&g.text, g.renderer, g.ui_scale) do return .FAILURE
	apply_settings()

	min_memory := uint(clay.MinMemorySize())
	g.clay_memory = make([]u8, min_memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory, raw_data(g.clay_memory))
	clay.Initialize(arena, {f32(g.window_w), f32(g.window_h)}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)

	open_path(args.path, args.terminal)
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
		g.renderer = sdl.CreateRenderer(g.window, cname)
		if g.renderer == nil do sdl.Log("renderer %s unavailable (%s); using the default", cname, sdl.GetError())
	}
	if g.renderer == nil do g.renderer = sdl.CreateRenderer(g.window, nil)
	if g.renderer == nil {
		sdl.Log("SDL_CreateRenderer failed: %s", sdl.GetError())
		return false
	}
	_ = sdl.SetRenderVSync(g.renderer, g.perf != nil ? 0 : 1)
	_ = sdl.SetRenderDrawBlendMode(g.renderer, {.BLEND})
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
		if terminal do terminal_toggle_maximized()
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

	update_window_metrics()
	clay.SetLayoutDimensions({f32(g.window_w), f32(g.window_h)})
	clay.SetPointerState(g.mouse_pos, g.mouse_down)
	clay.UpdateScrollContainers(false, g.wheel * 3, g.dt)

	settings_poll(&g.settings)
	if fonts_poll(&g.fonts) do apply_editor_font()
	apply_pending_action()
	update_focus()
	finder_frame()
	terminal_panel_frame()
	// Not while the editor is hidden (its last layout is stale) or the splitter,
	// whose grab area overlaps it, is being dragged.
	editor_frame(&g.editor, ui_interactive() && !terminal_maximized() && !g.terminal_panel.split_drag)
	g.wake_frames = max(g.wake_frames - 1, 0)
	g.sleeping = g.wake_frames == 0 && !needs_continuous_frames()
	tooltip_begin_frame()
	commands := build_ui()
	tooltip_end_frame()
	update_mouse_cursor()
	if g.perf != nil do perf_mark(.Update)

	_ = sdl.SetRenderDrawColor(g.renderer, u8(theme.bg.r), u8(theme.bg.g), u8(theme.bg.b), 255)
	_ = sdl.RenderClear(g.renderer)
	render_clay_commands(g.renderer, &commands, g.ui_scale)
	if g.perf != nil do perf_mark(.Render)
	_ = sdl.RenderPresent(g.renderer)
	if g.perf != nil do perf_mark(.Present)

	g.wheel = {}
	g.mouse_pressed = false
	g.frame += 1
	text_end_frame(&g.text)
	schedule_next_frame()
	free_all(context.temp_allocator)
	return .CONTINUE
}

// Whether the next frame should follow immediately even without input.
needs_continuous_frames :: proc() -> bool {
	e := &g.editor
	switch {
	case g.pending != nil,
	     finder_busy(),
	     e.dragging && g.mouse_down, // edge auto-scroll
	     e.status == .Text && syntax.highlighter_busy(&e.hl, &e.buf),
	     editor_scrolling(e) || e.scrollbar_drag != nil,
	     g.settings.show_fps, // measure the real frame rate
	     tooltip_pending(),
	     g.animating,
	     terminal_panel_busy(),
	     g.perf != nil && perf_running():
		return true
	}
	return false
}

// Draws continuously while something is changing; otherwise sleeps until the
// next event, with a timer to wake for the next cursor blink.
schedule_next_frame :: proc() {
	if !g.sleeping {
		_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "0")
		return
	}
	_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "waitevent")
	if g.wake_timer != 0 do _ = sdl.RemoveTimer(g.wake_timer)
	g.wake_timer = 0

	delay: u64
	blinks: bool
	switch g.focus {
	case .Editor:
		if g.editor.status == .Text {
			since := sdl.GetTicksNS() - g.editor.blink_t0
			delay, blinks = CARET_BLINK_NS - since % CARET_BLINK_NS, true
		}
	case .Terminal:
		if g.terminal_panel.visible do delay, blinks = terminal_blink_delay(&g.terminal_panel.terminal)
	}
	if !blinks do return
	delay += 1_000_000 // land just after the blink toggles
	g.wake_timer = sdl.AddTimer(u32(delay / 1_000_000), wake_callback, nil)
}

// Runs on SDL's timer thread.
@(private = "file")
wake_callback :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return 0 // one-shot
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
		if editor_confirm_discard(&g.editor) do return .SUCCESS
	case .KEY_DOWN, .TEXT_INPUT:
		handle_key_event(event)
	case .MOUSE_MOTION:
		g.mouse_pos = {event.motion.x, event.motion.y}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
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
	if settings_window_handle_event(event) do return
	if finder_handle_event(event) do return
	p := &g.terminal_panel
	if g.focus == .Terminal && p.visible && p.terminal.initialized && terminal_handle_event(&p.terminal, event) do return
	if event.type == .TEXT_INPUT {
		editor_text_input(&g.editor, string(event.text.text))
		return
	}
	if event.key.key == sdl.K_F12 {
		clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		return
	}
	if cmd, ok := command_for_key(event.key); ok && run_command(cmd) do return
	editor_handle_key(&g.editor, event.key)
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = g.ctx
	finder_destroy()
	terminal_destroy(&g.terminal_panel.terminal)
	settings_window_destroy()
	settings_destroy(&g.settings)
	fonts_destroy(&g.fonts)
	destroy_mouse_cursors()
	editor_destroy(&g.editor)
	workspace_destroy(&g.workspace)
	text_destroy(&g.text)
	delete(g.clay_memory)
	if g.perf != nil do perf_end()
	// SDL destroys the window/renderer and calls SDL_Quit after this returns.
}

// Refreshes the logical size and display scale; a new scale re-rasterizes text.
update_window_metrics :: proc() {
	_ = sdl.GetWindowSize(g.window, &g.window_w, &g.window_h)
	scale := sdl.GetWindowDisplayScale(g.window)
	if scale <= 0 do scale = 1
	if scale == g.ui_scale do return
	g.ui_scale = scale
	if g.text.engine != nil {
		text_set_scale(&g.text, scale)
		clay.ResetMeasureTextCache()
	}
}

clay_error_handler :: proc "c" (error: clay.ErrorData) {
	context = g.ctx
	sdl.Log("Clay error: %.*s", error.errorText.length, error.errorText.chars)
}

// --- Actions --------------------------------------------------------------------
// UI actions that replace the tree or the buffer. They are applied at the start
// of the next frame, because this frame's render commands still point at the
// strings they would free.

Toggle_Node :: distinct int
Open_File :: distinct string   // owned, full path
Open_Folder :: distinct string // owned

Action :: union {
	Toggle_Node,
	Open_File,
	Open_Folder,
}

@(private = "file")
apply_pending_action :: proc() {
	if path, ok := take_picked_folder(); ok do g.pending = Open_Folder(path)

	switch a in g.pending {
	case Toggle_Node:
		workspace_toggle(&g.workspace, int(a))
	case Open_File:
		if string(a) != g.editor.path && editor_confirm_discard(&g.editor) {
			editor_open(&g.editor, string(a))
			workspace_reveal(&g.workspace, string(a))
			g.focus = .Editor
		}
		delete(string(a))
	case Open_Folder:
		if editor_confirm_discard(&g.editor) do open_folder(string(a))
		delete(string(a))
	}
	g.pending = nil
}

open_folder :: proc(path: string) {
	path := os.get_absolute_path(path, context.temp_allocator) or_else path
	if len(path) > 3 do path = strings.trim_right(path, "/\\") // keep "C:\"
	workspace_open(&g.workspace, path)
	title := fmt.ctprintf("%s - typo", folder_name(path))
	_ = sdl.SetWindowTitle(g.window, title)
	editor_close(&g.editor)
	finder_invalidate()
	scroll := clay.GetScrollContainerData(clay.ID("SidebarFiles"))
	if scroll.found do scroll.scrollPosition^ = {}
}
