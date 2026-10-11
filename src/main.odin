package editor

import "base:runtime"
import "core:os"
import "core:strings"

import clay "../vendor/clay-odin"
import "syntax"
import sdl "vendor:sdl3"

App :: struct {
	ctx:           runtime.Context,
	window:        ^sdl.Window,
	renderer:      ^sdl.Renderer,
	text:          Text_System,
	clay_memory:   []u8,

	// Logical window size and pixels-per-logical-unit.
	window_w:      i32,
	window_h:      i32,
	ui_scale:      f32,

	// Input collected from events, consumed once per frame.
	mouse_pos:     [2]f32,
	mouse_down:    bool,
	mouse_pressed: bool,
	mouse_clicks:  int, // 1, 2, 3 for single/double/triple click of the last press
	last_press_pos: [2]f32,
	wheel:         [2]f32,

	last_ticks:    u64,
	dt:            f32,
	fps:           f32, // frames presented per second, measured over FPS_WINDOW
	fps_frames:    int,
	fps_t0:        u64,

	// Idle handling: frames are only drawn while something changes (see
	// schedule_next_frame). `wake_frames` counts frames still to draw after input.
	wake_frames:   int,
	sleeping:      bool, // the frame being built is the last before sleeping
	wake_timer:    sdl.TimerID,

	workspace:     Workspace,
	editor:        Editor,
	pending:       Action,

	sidebar_visible: bool,
	finder:          Finder,
	settings:        Settings,
	settings_window: Settings_Window,
	in_modal:        bool, // building a popup's UI (see ui_interactive)
	tooltip:         Tooltip_State,
}

g: App

FPS_WINDOW :: 500_000_000 // ns
// How far apart (logical pixels) presses may be to count as a double/triple click.
MULTI_CLICK_DISTANCE :: 4
// Frames drawn after each input event before going idle. More than one, since
// some UI reactions (e.g. a click's action) land on the following frame.
WAKE_FRAMES :: 3
// While idle, wake at least this often to check the settings file.
IDLE_POLL_MS :: 500

main :: proc() {
	g.ctx = context
	sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
}

app_init :: proc "c" (appstate: ^rawptr, argc: i32, argv: [^]cstring) -> sdl.AppResult {
	context = g.ctx

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
	// Settings are needed before the renderer (it is chosen by them).
	settings_init(&g.settings)
	apply_settings()

	// SDL's default backend (Direct3D 11 on Windows) unless the settings ask for
	// another; fall back to the default if that one can't be created.
	if g.settings.renderer != "" && g.settings.renderer != "auto" {
		g.renderer = sdl.CreateRenderer(g.window, strings.clone_to_cstring(g.settings.renderer, context.temp_allocator))
		if g.renderer == nil do sdl.Log("renderer %s unavailable (%s); using the default", strings.clone_to_cstring(g.settings.renderer, context.temp_allocator), sdl.GetError())
	}
	if g.renderer == nil do g.renderer = sdl.CreateRenderer(g.window, nil)
	if g.renderer == nil {
		sdl.Log("SDL_CreateRenderer failed: %s", sdl.GetError())
		return .FAILURE
	}
	_ = sdl.SetRenderVSync(g.renderer, 1)
	_ = sdl.SetRenderDrawBlendMode(g.renderer, {.BLEND})

	update_window_metrics()

	if !text_init(&g.text, g.renderer) {
		return .FAILURE
	}

	min_memory := uint(clay.MinMemorySize())
	g.clay_memory = make([]u8, min_memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_memory, raw_data(g.clay_memory))
	clay.Initialize(arena, {f32(g.window_w), f32(g.window_h)}, {handler = clay_error_handler})
	clay.SetMeasureTextFunction(measure_text, nil)

	// Workspace root: first command-line argument, else the working directory.
	root := len(os.args) > 1 ? os.args[1] : (os.get_working_directory(context.temp_allocator) or_else ".")
	open_folder(root)
	g.sidebar_visible = true
	// Text input stays on; the finder or the editor consumes TEXT_INPUT events.
	_ = sdl.StartTextInput(g.window)

	g.last_ticks = sdl.GetTicksNS()
	return .CONTINUE
}

// Called every frame, including during Windows' modal resize loop, which is
// what lets the layout reflow live while the window edge is being dragged.
app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = g.ctx

	now := sdl.GetTicksNS()
	g.dt = f32(now - g.last_ticks) / 1e9
	g.last_ticks = now
	// Count frames over a window instead of averaging 1/dt, which overstates
	// the rate whenever frame times are uneven. Restarted after sleeping.
	if g.sleeping {
		g.fps_frames, g.fps_t0 = 0, now
		g.dt = 1.0 / 240
	}
	g.fps_frames += 1
	if elapsed := now - g.fps_t0; elapsed >= FPS_WINDOW {
		g.fps = f32(f64(g.fps_frames) / (f64(elapsed) / 1e9))
		g.fps_frames, g.fps_t0 = 0, now
	}

	update_window_metrics()
	clay.SetLayoutDimensions({f32(g.window_w), f32(g.window_h)})
	clay.SetPointerState(g.mouse_pos, g.mouse_down)
	clay.UpdateScrollContainers(false, g.wheel * 3, g.dt)

	settings_poll(&g.settings)
	apply_pending_action()
	finder_frame()
	editor_frame(&g.editor)
	g.wake_frames = max(g.wake_frames - 1, 0)
	g.sleeping = g.wake_frames == 0 && !needs_continuous_frames()
	tooltip_begin_frame()
	commands := build_ui()
	tooltip_end_frame()
	update_mouse_cursor()

	_ = sdl.SetRenderDrawColor(g.renderer, u8(theme.bg.r), u8(theme.bg.g), u8(theme.bg.b), 255)
	_ = sdl.RenderClear(g.renderer)
	render_clay_commands(g.renderer, &commands, g.ui_scale)
	_ = sdl.RenderPresent(g.renderer)

	g.wheel = {}
	g.mouse_pressed = false
	text_end_frame(&g.text)
	schedule_next_frame()
	free_all(context.temp_allocator)
	return .CONTINUE
}

// Whether the next frame should follow immediately even without input.
needs_continuous_frames :: proc() -> bool {
	if g.pending != nil do return true
	f := &g.finder
	if f.open && (f.indexing || f.scanned < len(f.files)) do return true
	e := &g.editor
	if e.dragging && g.mouse_down do return true // edge auto-scroll
	if e.status == .Text && syntax.highlighter_busy(&e.hl, &e.buf) do return true
	if editor_scrolling(e) || e.scrollbar_drag != nil do return true
	if g.settings.show_fps do return true // measure the real frame rate
	if tooltip_pending() do return true
	return false
}

// Draws continuously while something is changing; otherwise sleeps until the
// next input event, or until a timer wakes us for the caret blink or the
// settings-file check.
schedule_next_frame :: proc() {
	if !g.sleeping {
		_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "0")
		return
	}
	_ = sdl.SetHint(sdl.HINT_MAIN_CALLBACK_RATE, "waitevent")

	delay := u64(IDLE_POLL_MS) * 1_000_000
	e := &g.editor
	if e.status == .Text {
		// Wake for the next caret blink toggle.
		since := sdl.GetTicksNS() - e.blink_t0
		delay = min(delay, CARET_BLINK_NS - since % CARET_BLINK_NS + 1_000_000)
	}
	if g.wake_timer != 0 do _ = sdl.RemoveTimer(g.wake_timer)
	g.wake_timer = sdl.AddTimer(u32(max(delay / 1_000_000, 1)), wake_callback, nil)
}

// Runs on SDL's timer thread: push an event so the main loop runs a frame.
wake_callback :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	event: sdl.Event
	event.type = .USER
	_ = sdl.PushEvent(&event)
	return 0 // one-shot
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = g.ctx
	// Any input wakes the loop for a few frames. The wake timer's own event only
	// asks for one frame (to redraw the caret, poll settings).
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
		if settings_window_handle_event(event) do break
		if finder_handle_event(event) do break
		if event.type == .TEXT_INPUT {
			editor_text_input(&g.editor, string(event.text.text))
		} else if !handle_shortcut(event.key) {
			editor_handle_key(&g.editor, event.key)
		}
	case .MOUSE_MOTION:
		g.mouse_pos = {event.motion.x, event.motion.y}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if event.button.button == sdl.BUTTON_LEFT {
			g.mouse_down = event.button.down
			if event.button.down {
				g.mouse_pressed = true
				// SDL decides the timing of double/triple clicks, but its distance
				// tolerance spans more than a line of text; only chain clicks that
				// land where the previous one did.
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

// App-wide shortcuts. Returns true if the key was one of them.
handle_shortcut :: proc(key: sdl.KeyboardEvent) -> bool {
	if key.key == sdl.K_F12 {
		clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		return true
	}
	cmd := command_for_key(key) or_return
	return run_command(cmd)
}

run_command :: proc(cmd: Command) -> bool {
	#partial switch cmd {
	case .Find_File:      finder_toggle()
	case .Toggle_Sidebar: g.sidebar_visible = !g.sidebar_visible
	case .Open_Settings:  settings_window_toggle()
	case:                 return editor_run_command(&g.editor, cmd)
	}
	return true
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = g.ctx
	finder_destroy()
	settings_window_destroy()
	settings_destroy(&g.settings)
	destroy_mouse_cursors()
	editor_destroy(&g.editor)
	workspace_destroy(&g.workspace)
	text_destroy(&g.text)
	delete(g.clay_memory)
	// SDL destroys the window/renderer and calls SDL_Quit after this returns.
}

// Refreshes logical size and display scale. When the scale changes, fonts are
// re-rasterized at the new pixel size and Clay's measurement cache is dropped.
update_window_metrics :: proc() {
	_ = sdl.GetWindowSize(g.window, &g.window_w, &g.window_h)
	scale := sdl.GetWindowDisplayScale(g.window)
	if scale <= 0 do scale = 1
	if scale != g.ui_scale {
		old := g.ui_scale
		g.ui_scale = scale
		if old != 0 {
			text_clear_caches(&g.text)
			clay.ResetMeasureTextCache()
		}
	}
}

clay_error_handler :: proc "c" (error: clay.ErrorData) {
	context = g.ctx
	sdl.Log("Clay error: %.*s", error.errorText.length, error.errorText.chars)
}

