package editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "fuzzy"
import "herdr"
import "langs"
import "lsp"
import "markdown"
import "process"
import "syntax"
import "term"
import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"
import "gfx"
import "textedit"
import "mdview"
import "uitime"
import "words"

// The performance suite: `typo --perf` (run by `python build.py --test` on an
// optimized build). It drives the real app, with a real window and renderer,
// through the phases in PHASES, one step per frame, and checks each result
// against its limit. Headless phases time the core packages directly; UI phases
// time whole frames. Exits non-zero if any limit is exceeded.
//
// Frames are timed in three parts: update (input, model, layout), render
// (turning Clay commands into SDL draw calls) and present (submitting to the
// GPU; VSync is off, so this includes waiting on the GPU). Limits apply to the
// CPU part, update + render, with a phase's first frame reported on its own


PERF_IDLE_NS :: 5 * time.Second // process CPU time is counted in ~16 ms ticks on Windows
PERF_SEED    :: 7

Perf :: struct {
	begin:            time.Tick,
	dir:              string, // temp folder: the workspace and generated files
	code_text:        string, // generated Odin source, small enough for tree-sitter
	md_text:          string, // generated Markdown
	large_text:       string, // the same at ~64 MB, highlighted by the lexer

	phase:            int,
	frame:            int, // frame within the phase
	mark_frame:       int, // a phase's own reference frame, for phases that wait between steps
	phase_t0:         time.Tick,
	cpu0:             i64,
	frames:           [dynamic]Frame_Time, // of the current phase
	lsp_times:        [dynamic]f64,        // language server work on the UI thread, per frame
	words_times:      [dynamic]f64,        // word completion work on the UI thread, per frame
	herdr_times:      [dynamic]f64,        // herdr-core client work on the UI thread, per frame
	git_times:        [dynamic]f64,        // Git and diff view work on the UI thread, per frame
	frame_t0:         time.Tick,           // when the current frame's work began
	marks:            [Frame_Part]time.Tick,
	first_present_ns: i64,

	gpu:              Gpu_Counter,
	results:          int,
	failures:         [dynamic]string,
	window_size:      [2]i32, // before a resizing phase
	clay_errors:      int,    // Clay's error count when the phase began
	most_clips:       int,    // the most clipping elements a frame of the phase drew

	// Terminal output phase
	flood_parsed:     u64,
	flood_last:       time.Tick,

	// What a frame showed, read back once drawn (read_frame)
	read_wanted:      bool,
	read_area:        sdl.Rect, // device pixels
	read_back:        [][4]u8,  // owned; the area as last read, row by row
}

Frame_Part :: enum {
	Update,
	Render,
	Present,
}

Frame_Time :: [Frame_Part]f64 // ms

Phase :: struct {
	name:        string,
	// Called at the start of each frame of the phase; returns true when done
	step:        proc(p: ^Perf, frame: int) -> bool,
	// p95 limit (ms) on the CPU time of the phase's frames; 0 = frames not reported
	frame_limit: f64,
	// Limit (ms) on the slowest frame after the first; 0 = none
	max_limit:   f64,
	// Limit (ms) on the language server work done on the UI thread in any frame
	// (lsp_frame, document sync); 0 = not reported
	lsp_limit:   f64,
	// Limit (ms) on the word completion work done on the UI thread in any frame
	// (taking and asking for words, filtering them); 0 = not reported
	words_limit: f64,
	// Limit (ms) on the herdr-core client's work on the UI thread in any frame
	// (persistent terminals' output, input and state); 0 = not reported
	herdr_limit: f64,
	// Limit (ms) on the Git work done on the UI thread in any frame (taking the
	// worker's and the diff loader's results, asking for changes); 0 = not reported
	git_limit:   f64,
	idle:        bool, // let the app sleep between frames
}

PHASES := [?]Phase {
	{name = "startup", step = phase_startup},
	{name = "fonts", step = phase_fonts},
	{name = "text in cells and subpixels", step = phase_text_rendering},
	{name = "selection shapes", step = phase_selection_shape},
	{name = "generate test files", step = phase_generate},
	{name = "buffer (64 MB)", step = phase_buffer},
	{name = "syntax", step = phase_syntax},
	{name = "markdown", step = phase_markdown},
	{name = "fuzzy file search", step = phase_fuzzy},
	{name = "terminal emulation", step = phase_vt},
	{name = "open code file (tree-sitter)", step = phase_open_code, frame_limit = 8},
	{name = "idle with a file open", step = phase_idle, idle = true},
	{name = "typing (tree-sitter)", step = phase_type, frame_limit = 8, words_limit = 1},
	{
		name        = "word completions",
		step        = phase_word_completion,
		frame_limit = 8,
		words_limit = 1,
	},
	{name = "clicking places the caret", step = phase_click_caret},
	{name = "moving lines", step = phase_move_lines},
	{name = "find in a file (tree-sitter)", step = phase_find, frame_limit = 8},
	{name = "scrolling (tree-sitter)", step = phase_scroll, frame_limit = 8},
	{name = "resizing the window (tree-sitter)", step = phase_resize, frame_limit = 8},
	{name = "sideways scroll bar", step = phase_sideways},
	{name = "list numbers (rendered)", step = phase_list_numbers},
	{name = "go to definition into a file not open", step = phase_jump_closed},
	{name = "open Markdown (rendered)", step = phase_open_markdown, frame_limit = 8},
	{name = "scrolling Markdown (rendered)", step = phase_scroll, frame_limit = 8},
	{name = "typing in Markdown (rendered)", step = phase_type, frame_limit = 8},
	{name = "clicking places the caret (rendered)", step = phase_click_caret},
	{name = "find in Markdown (rendered)", step = phase_find, frame_limit = 8},
	{
		name        = "moving through a table and code block (rendered)",
		step        = phase_move_markdown,
		frame_limit = 8,
	},
	{
		name        = "typing above a long table (rendered)",
		step        = phase_type_above_table,
		frame_limit = 8,
	},
	{
		name        = "typing in a long table's cell (rendered)",
		step        = phase_type_in_table,
		frame_limit = 8,
	},
	{name = "resizing the window, Markdown (rendered)", step = phase_resize, frame_limit = 8},
	{name = "spaces and tabs in Markdown (rendered)", step = phase_md_whitespace},
	{name = "zooming 4 MB Markdown (rendered)", step = phase_zoom_markdown, frame_limit = 8},
	{name = "file finder", step = phase_finder, frame_limit = 8},
	{name = "open and recent files in the finder", step = phase_finder_ranks},
	{name = "settings window", step = phase_settings, frame_limit = 8},
	{name = "settings scrolling at any size", step = phase_settings_scrolls},
	{name = "settings sections collapsing", step = phase_settings_collapse, frame_limit = 8},
	{name = "several bindings for a command", step = phase_settings_bindings},
	{name = "context menu and dialogs", step = phase_menu_dialogs},
	{name = "sidebar behind the panes, its search", step = phase_sidebar, frame_limit = 8},
	{name = "recent and pinned files, project settings", step = phase_recent},
	{name = "files changed on disk", step = phase_disk_changes}, // perf_watch.odin
	{name = "Git pane on a repository", step = phase_git_pane, git_limit = 1}, // perf_git.odin
	{
		name        = "scrolling a diff of a large file",
		step        = phase_git_diff_scroll,
		frame_limit = 8,
		git_limit   = 1,
	},
	{name = "reverting and staging hunks", step = phase_git_hunks, git_limit = 1},
	{name = "narrow Git and diff panes", step = phase_git_narrow, git_limit = 1},
	{name = "theme list (every theme)", step = phase_theme_picker, frame_limit = 8},
	{name = "font list", step = phase_font_picker, frame_limit = 25},
	{name = "scrolling with letter spacing", step = phase_letter_spacing, frame_limit = 8},
	{
		name        = "open 64 MB file while frames go on (lexer)",
		step        = phase_open_large,
		frame_limit = 8,
		max_limit   = 16,
	},
	{name = "jumping through 64 MB file", step = phase_jump_large, frame_limit = 12},
	{name = "typing in 64 MB file", step = phase_type, frame_limit = 8, words_limit = 1},
	{name = "find in 64 MB file", step = phase_find, frame_limit = 12},
	{name = "saving 64 MB file while frames go on", step = phase_save_large, frame_limit = 8},
	{name = "session restore of a file that loads slowly", step = phase_restore_slow},
	{name = "a large file asks first; Cancel opens nothing", step = phase_large_asks},
	{name = "closing a file while it loads", step = phase_close_loading},
	{name = "8 MB single-line file", step = phase_long_line, frame_limit = 25},
	{name = "terminal full-screen redraws", step = phase_terminal_redraw, frame_limit = 12},
	{name = "block elements and box drawing fill their cells", step = phase_box_glyphs},
	{name = "terminal full of block characters", step = phase_terminal_blocks, frame_limit = 12},
	{name = "terminal shell output (4 MB)", step = phase_terminal_output, frame_limit = 16},
	{name = "find in the terminal", step = phase_find_terminal, frame_limit = 16},
	{
		name        = "typing beside other panes (tree-sitter)",
		step        = phase_panes_typing,
		frame_limit = 8,
	},
	{name = "moving panes", step = phase_panes_moving, frame_limit = 8},
	{name = "pane title bar and mouse buttons", step = phase_pane_header},
	{name = "typo <file> in the terminal", step = phase_ipc_open},
	{name = "closing a terminal that runs a program", step = phase_terminal_close},
	{
		name        = "persistent terminal (herdr-core)",
		step        = phase_persistent_terminal,
		herdr_limit = 1,
	},
	{name = "recent projects popup", step = phase_project_picker},
	{name = "typo's window frame", step = phase_window_frame},
	{name = "go to line", step = phase_goto_line},
	{name = "text fields with the mouse and keys", step = phase_text_fields},
	{name = "zooming panes", step = phase_zoom_panes},
	{
		name = "language server (typing)",
		step = phase_lsp_typing,
		frame_limit = 8,
		max_limit = 16,
		lsp_limit = 1,
	},
	{
		name = "scrolling with 10,000 problems",
		step = phase_lsp_problems,
		frame_limit = 8,
		max_limit = 16,
		lsp_limit = 1,
	},
	{name = "hover, go to definition, editor menu", step = phase_lsp_features, lsp_limit = 1},
	{
		name        = "symbols and references in the finder",
		step        = phase_lsp_finder,
		frame_limit = 8,
		lsp_limit   = 1,
	},
	{
		name        = "completion and signature help",
		step        = phase_lsp_completion,
		frame_limit = 8,
		lsp_limit   = 1,
	},
	{name = "renaming a symbol, a server's edit", step = phase_lsp_rename, lsp_limit = 1},
	{name = "language server popup", step = phase_lsp_popup, lsp_limit = 1},
	{
		name        = "language servers in the settings, installing one",
		step        = phase_lsp_settings,
		frame_limit = 8,
		lsp_limit   = 1,
	},
	{name = "idle with the terminal focused", step = phase_idle, idle = true},
}


// Called first thing at startup, before SDL: settings go to a scratch file so
// the user's don't affect results, and the workspace is an empty temp folder
perf_begin :: proc() -> (workspace: string) {
	p := new(Perf)
	g.perf = p
	p.begin = time.tick_now()

	// A scratch folder, with the settings in it
	tmp, _ := os.temp_directory(context.temp_allocator)
	p.dir = fmt.aprintf("%s%ctypo-perf-%d", tmp, os.Path_Separator, os.get_pid())
	_ = os.make_directory_all(p.dir)
	_ = os.set_env("TYPO_SETTINGS", path_in_dir(p, "settings.toml"))

	rand.reset(PERF_SEED)
	attach_console()
	fmt.println("typo performance suite")
	return p.dir
}


perf_end :: proc() {
	p := g.perf
	gpu_counter_close(&p.gpu)
	_ = os.remove_all(p.dir)

	delete(p.dir)
	delete(p.code_text)
	delete(p.md_text)
	delete(p.large_text)
	delete(p.frames)
	delete(p.lsp_times)
	delete(p.words_times)
	delete(p.herdr_times)
	delete(p.git_times)
	for f in p.failures do delete(f)
	delete(p.failures)
	delete(p.read_back)
	free(p)
	g.perf = nil

	detach_console()
}


// Whether the app should keep drawing frames back to back
perf_running :: proc() -> bool {
	return g.perf.phase < len(PHASES) && !PHASES[g.perf.phase].idle
}


perf_mark :: proc(part: Frame_Part) {
	p := g.perf
	p.marks[part] = time.tick_now()

	// The frame is drawn and not yet presented
	if part == .Render && p.read_wanted {
		read_frame(p)
	}

	if part == .Present && p.first_present_ns == 0 {
		p.first_present_ns = process_age_ns()
		if p.first_present_ns < 0 do p.first_present_ns = i64(time.tick_since(p.begin))
	}
}


// Called at the start of every frame. Records the previous frame's timings and
// runs the current phase's step; done is set once every phase has finished
perf_frame :: proc() -> (done, ok: bool) {
	p := g.perf

	// The previous frame's parts
	if p.frame_t0 != {} {
		t: Frame_Time
		prev := p.frame_t0
		for part in Frame_Part {
			t[part] = time.duration_milliseconds(time.tick_diff(prev, p.marks[part]))
			prev = p.marks[part]
		}
		append(&p.frames, t)
		p.most_clips = max(p.most_clips, g.frame_clips)
		append(&p.lsp_times, time.duration_milliseconds(langs.ui_share.total))
		append(&p.words_times, time.duration_milliseconds(words_ui.total))
		append(&p.herdr_times, time.duration_milliseconds(herdr.ui_share.total))
		append(&p.git_times, time.duration_milliseconds(git_ui.total))
	}

	// Each frame's from zero
	for share in ([]^uitime.Share{&langs.ui_share, &words_ui, &herdr.ui_share, &git_ui}) {
		uitime.take(share)
	}

	// This frame's step, moving on to the next phase when one finishes
	for p.phase < len(PHASES) {
		if p.frame == 0 do start_phase(p)
		finished := PHASES[p.phase].step(p, p.frame)
		p.frame += 1
		if !finished do break

		finish_phase(p)
		p.phase += 1
		p.frame = 0
	}
	p.frame_t0 = time.tick_now()
	if p.phase < len(PHASES) do return false, false

	// The summary
	fmt.println()
	if len(p.failures) == 0 {
		fmt.printfln("All %d results within limits.", p.results)
	} else {
		fmt.printfln("%d of %d results over their limits:", len(p.failures), p.results)
		for f in p.failures do fmt.printfln("  %s", f)
	}
	return true, len(p.failures) == 0
}


@(private = "file")
start_phase :: proc(p: ^Perf) {
	fmt.printfln("\n%s", PHASES[p.phase].name)
	clear(&p.frames)
	clear(&p.lsp_times)
	clear(&p.words_times)
	clear(&p.herdr_times)
	clear(&p.git_times)

	p.clay_errors = g.clay_errors.count
	p.most_clips = 0
	gpu_counter_start(&p.gpu) // first: querying the counters costs CPU time
	p.phase_t0 = time.tick_now()
	p.cpu0 = process_cpu_ns()
}


// The most clipping elements a frame may draw: Clay's store holds about 100,
// and a changed list's old rows linger in it a frame
@(private = "file")
CLIP_LIMIT :: 80


@(private = "file")
finish_phase :: proc(p: ^Perf) {
	phase := PHASES[p.phase]

	// Whatever a phase does, Clay must lay it out without an error, and its
	// clipping elements stay well under Clay's store (see ROW_CLIP_BUDGET)
	errors := g.clay_errors.count - p.clay_errors
	if errors > 0 {
		last := string(g.clay_errors.last[:g.clay_errors.last_len])
		fmt.printfln("  %d Clay errors, the last %v: %s", errors, g.clay_errors.kind, last)
	}
	check(p, "Clay lays it out without an error", errors == 0)
	if p.most_clips >= CLIP_LIMIT {
		fmt.printfln("  %d clipping elements in a frame", p.most_clips)
	}
	check(p, "and with clipping elements to spare", p.most_clips < CLIP_LIMIT)

	if phase.lsp_limit > 0 {
		worst := slice.max(p.lsp_times[:]) if len(p.lsp_times) > 0 else 0
		result(p, "language servers, UI thread, worst", worst, "ms", phase.lsp_limit)
	}
	if phase.words_limit > 0 {
		worst := slice.max(p.words_times[:]) if len(p.words_times) > 0 else 0
		result(p, "word completions, UI thread, worst", worst, "ms", phase.words_limit)
	}
	if phase.herdr_limit > 0 {
		worst := slice.max(p.herdr_times[:]) if len(p.herdr_times) > 0 else 0
		result(p, "herdr-core client, UI thread, worst", worst, "ms", phase.herdr_limit)
	}
	if phase.git_limit > 0 {
		worst := slice.max(p.git_times[:]) if len(p.git_times) > 0 else 0
		result(p, "Git, UI thread, worst", worst, "ms", phase.git_limit)
	}

	limit := phase.frame_limit
	if limit == 0 || len(p.frames) < 2 {
		return
	}

	// The first frame also loads fonts and shapes text not seen before
	first := p.frames[0]
	result(p, "first frame CPU", first[.Update] + first[.Render], "ms", 50)

	// The rest
	frames := p.frames[1:]
	cpu := make([]f64, len(frames), context.temp_allocator)
	present := make([]f64, len(frames), context.temp_allocator)
	for f, i in frames {
		cpu[i] = f[.Update] + f[.Render]
		present[i] = f[.Present]
	}
	slice.sort(cpu)
	slice.sort(present)

	result(p, fmt.tprintf("frames (%d) median CPU", len(cpu)), percentile(cpu, 0.5), "ms")
	result(p, "frames p95 CPU", percentile(cpu, 0.95), "ms", limit)
	result(p, "frames max CPU", cpu[len(cpu) - 1], "ms", phase.max_limit)
	result(p, "frames p95 present", percentile(present, 0.95), "ms")

	gpu := gpu_counter_read(&p.gpu)
	if gpu >= 0 do result(p, "GPU utilization", gpu, "%")
}


@(private = "file")
percentile :: proc(sorted: []f64, q: f64) -> f64 {
	return sorted[min(int(f64(len(sorted)) * q), len(sorted) - 1)]
}


// Prints a result; one over its limit (if it has one) fails the suite
@(private)
result :: proc(p: ^Perf, name: string, value: f64, unit: string, limit: f64 = 0) {
	p.results += 1
	over := limit > 0 && value > limit

	limit_text := limit > 0 ? fmt.tprintf("limit %.4g", limit) : ""
	value_text := fmt.tprintf("%.3f", value)
	verdict := over ? "OVER" : ""
	fmt.printfln("  %-36s %10s %-5s %-14s%s", name, value_text, unit, limit_text, verdict)

	if over {
		phase := PHASES[p.phase].name
		append(&p.failures, fmt.aprintf("%s: %s %.3f %s > %.4g", phase, name, value, unit, limit))
	}
}


// Records a functional check; a false one fails the suite
@(private)
check :: proc(p: ^Perf, name: string, ok: bool) {
	p.results += 1
	fmt.printfln("  %-36s %10s", name, ok ? "ok" : "FAILED")
	if !ok do append(&p.failures, fmt.aprintf("%s: %s", PHASES[p.phase].name, name))
}


@(private)
ms_since :: proc(t: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(t))
}


@(private)
path_in_dir :: proc(p: ^Perf, name: string) -> string {
	return fmt.tprintf("%s%c%s", p.dir, os.Path_Separator, name)
}


// --- Headless phases ---------------------------------------------------------------

@(private = "file")
phase_startup :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do return false // let the first frame present

	result(p, "launch to first frame", f64(p.first_present_ns) / 1e6, "ms", 1000)
	p.gpu = gpu_counter_open()
	return true
}


// A size no UI element uses, so the font is opened here
@(private = "file")
PERF_FONT_SIZE :: 37


@(private = "file")
phase_fonts :: proc(p: ^Perf, frame: int) -> bool {
	t := time.tick_now()
	font := gfx.text_get_font(&gfx.text_system, .Body, PERF_FONT_SIZE)
	result(p, "open a new font size", ms_since(t), "ms", 5)

	t = time.tick_now()
	_ = gfx.text_get(&gfx.text_system, font, "→ ✓ 漢字")
	result(p, "first text needing fallback fonts", ms_since(t), "ms")
	return true
}


// The editor font in whole-pixel cells, and subpixel (LCD) text drawn and read
// back from the window, with the real fonts and renderer
@(private = "file")
phase_text_rendering :: proc(p: ^Perf, frame: int) -> bool {
	ts := &gfx.text_system

	// A size the bundled font's advance has a fraction at (7.8 pixels at 1x)
	size := u16(13)

	// Columns on whole device pixels, at this size and the editor's (with its
	// letter spacing), for every face. Widths of strings that start and end
	// alike differ by exactly the columns between
	cell := gfx.text_char_width(ts, .Editor, size) * gfx.scale
	column := editor_char_width(1) * gfx.scale
	whole := is_whole(cell) && is_whole(column)
	check(p, "the editor font's columns are whole pixels", whole)

	regular := gfx.text_get_font(ts, .Editor, size)
	bold := gfx.text_get_font(ts, .Editor_Bold, size)
	italic := gfx.text_get_font(ts, .Editor_Italic, size)
	SAMPLE :: "0Wil_x.m0"
	cells := f32(len(SAMPLE) - 1) * cell
	check(p, "a run's glyphs advance by whole columns", columns_width(regular, SAMPLE) == cells)
	faces_keep := columns_width(bold, SAMPLE) == cells && columns_width(italic, SAMPLE) == cells
	check(p, "bold and italic keep the columns", faces_keep)

	// Subpixel text has colored edges, grayscale text gray ones; faded out,
	// subpixel text leaves the background as it was, and half faded it stays
	// between the background and its color, dimmer than unfaded
	setting := ts.antialiasing
	gfx.text_set_antialiasing(ts, .Subpixel)
	lcd := read_ink(INK_TEXT, 255)
	faded := read_ink(INK_TEXT, 0)
	half := read_ink(INK_TEXT, 128)
	lines := read_ink(INK_LINES, 255)
	long_ms := long_line_ms()
	gfx.text_set_antialiasing(ts, .Grayscale)
	gray := read_ink(INK_TEXT, 255)
	gfx.text_set_antialiasing(ts, setting)

	check(p, "subpixel text is drawn, with colored edges", lcd.pixels > 0 && lcd.spread > 40)
	check(p, "grayscale text is drawn in gray", gray.pixels > 0 && gray.spread <= 2)
	check(p, "faded subpixel text draws nothing", faded.pixels == 0)

	between := half.darkest >= int(INK_BG.r) && half.brightest <= int(INK_COLOR.r)
	dimmer := half.pixels > 0 && half.brightest < lcd.brightest
	check(p, "half faded subpixel text blends", between && dimmer)

	// Box drawing glyphs reach into the next cell; where they overlap they
	// must not add up past their color
	no_brighter := lines.pixels > 0 && lines.brightest <= int(INK_COLOR.r)
	check(p, "overlapping subpixel glyphs stay their color", no_brighter)

	// Unhinted proportional text keeps a bold i's dot apart from its stem
	md_bold := gfx.text_get_font(ts, .Md_Bold, 17)
	check(p, "a bold i's dot stays apart from its stem", glyph_dot_apart(md_bold, 'i'))

	result(p, "a long line past the window's edge", long_ms, "ms", 10)
	return true
}


// Whether a glyph's image has a row under half the ink's strength between ink
// above it and ink below (an i's dot and its stem)
@(private = "file")
glyph_dot_apart :: proc(font: ^ttf.Font, r: rune) -> bool {
	if font == nil do return false

	image := ttf.GetGlyphImage(font, u32(r), nil)
	if image == nil do return false
	defer sdl.DestroySurface(image)

	rgba := sdl.ConvertSurface(image, .RGBA32)
	if rgba == nil do return false
	defer sdl.DestroySurface(rgba)

	// Each row's strongest alpha, top to bottom: ink, a gap, then ink again
	pixels := ([^]u8)(rgba.pixels)
	inked := false
	gap := false
	for y in 0 ..< int(rgba.h) {
		alpha := 0
		for x in 0 ..< int(rgba.w) {
			alpha = max(alpha, int(pixels[y * int(rgba.pitch) + x * 4 + 3]))
		}

		switch {
		case alpha > 160 && gap:   return true
		case alpha > 160:          inked = true
		case alpha < 128 && inked: gap = true
		}
	}
	return false
}


// Milliseconds to draw one subpixel line of 20,000 characters, almost all of
// it past the window's right edge (as a long line in a rendered code block is)
@(private = "file")
long_line_ms :: proc() -> f64 {
	ts := &gfx.text_system
	font := gfx.text_get_font(ts, .Editor, 15)
	s := strings.repeat("abcdefghij", 2000, context.temp_allocator)
	text := gfx.text_get(ts, font, s)

	// Laid out and its glyphs rendered before timing
	gfx.draw_text(text, 4, 4, INK_COLOR)
	gfx.flush_text()

	start := time.tick_now()
	gfx.draw_text(text, 4, 4, INK_COLOR)
	gfx.flush_text()
	return time.duration_milliseconds(time.tick_since(start))
}


// Whether a width in pixels is whole, give or take float rounding
@(private = "file")
is_whole :: proc(px: f32) -> bool {
	return abs(px - math.round(px)) < 0.001
}


// Width of `s` beyond that of its first character, in pixels: the advances of
// all but the last character when s starts and ends with the same one
@(private = "file")
columns_width :: proc(font: ^ttf.Font, s: string) -> f32 {
	w, h, first_w: i32
	_ = ttf.GetStringSize(font, cstring(raw_data(s)), uint(len(s)), &w, &h)
	_ = ttf.GetStringSize(font, cstring(raw_data(s)), 1, &first_w, &h)
	return f32(w - first_w)
}


// What drawing text changed on its background
@(private = "file")
Ink :: struct {
	pixels:    int, // unlike the background
	spread:    int, // the largest difference between a pixel's red and blue
	brightest: int, // the largest channel of any pixel
	darkest:   int, // the smallest channel of any pixel
}


// Text for read_ink: letters, and a line of box drawing glyphs, light on gray
@(private = "file")
INK_TEXT :: "llll iiii wwww // Fonts"
@(private = "file")
INK_LINES :: "────────────────────"
@(private = "file")
INK_COLOR :: clay.Color{230, 230, 230, 255}
@(private = "file")
INK_BG :: clay.Color{60, 60, 60, 255}


// Draws a line of text with the given alpha on the background and reads back
// what it changed
@(private = "file")
read_ink :: proc(s: string, alpha: f32) -> (ink: Ink) {
	ts := &gfx.text_system
	area := sdl.Rect{0, 0, 300, 60}
	ink.darkest = 255

	// Drawn on the window, before this frame clears it
	gfx.fill_rect(0, 0, f32(area.w), f32(area.h), INK_BG)
	font := gfx.text_get_font(ts, .Editor, 15)
	text := gfx.text_get(ts, font, s)
	color := INK_COLOR
	color.a = alpha
	gfx.draw_text(text, 4, 4, color)

	pixels, ok := read_window(area)
	if !ok do return

	for px in pixels {
		r, g, b := int(px[0]), int(px[1]), int(px[2])
		if r != int(INK_BG.r) || g != int(INK_BG.g) || b != int(INK_BG.b) {
			ink.pixels += 1
		}
		ink.spread = max(ink.spread, abs(r - b))
		ink.brightest = max(ink.brightest, r, g, b)
		ink.darkest = min(ink.darkest, r, g, b)
	}
	return
}


// Asks for an area of this frame (logical pixels) once it is drawn, in
// p.read_back by the next frame's step
@(private)
want_frame :: proc(p: ^Perf, r: gfx.Rect) {
	s := gfx.scale
	p.read_area = {i32(r.x * s), i32(r.y * s), i32(r.w * s), i32(r.h * s)}
	p.read_wanted = true
}


// Reads back the area a step asked for, after the frame was drawn
@(private = "file")
read_frame :: proc(p: ^Perf) {
	p.read_wanted = false
	delete(p.read_back)
	p.read_back = nil

	pixels, ok := read_window(p.read_area)
	if ok do p.read_back = slice.clone(pixels)
}


// Reads back an area of what has been drawn on the window this frame: its
// pixels as RGBA, row by row (temp)
@(private = "file")
read_window :: proc(area: sdl.Rect) -> (pixels: [][4]u8, ok: bool) {
	gfx.flush_text()
	area := area

	read := sdl.RenderReadPixels(gfx.renderer, &area)
	if read == nil do return nil, false
	defer sdl.DestroySurface(read)

	rgba := sdl.ConvertSurface(read, .RGBA32)
	if rgba == nil do return nil, false
	defer sdl.DestroySurface(rgba)

	w, h := int(rgba.w), int(rgba.h)
	pixels = make([][4]u8, w * h, context.temp_allocator)
	src := ([^]u8)(rgba.pixels)
	for y in 0 ..< h {
		row := src[y * int(rgba.pitch):]
		for x in 0 ..< w {
			pixels[y * w + x] = {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
		}
	}
	return pixels, true
}


// Selections drawn as one shape and read back from the window: rounded outside
// corners, curves in the inside corners, no seam where rows meet; and the time
// a screenful of selected rows takes to draw
@(private = "file")
phase_selection_shape :: proc(p: ^Perf, frame: int) -> bool {
	// Two rows (pixels): the first reaches past the second on the right, the
	// second past the first on the left
	area := sdl.Rect{0, 0, 200, 80}
	gfx.fill_rect(0, 0, f32(area.w), f32(area.h), INK_BG)
	rows := []gfx.Rect{{40, 10, 100, 20}, {20, 30, 80, 20}}
	gfx.fill_selection(rows, 0, 6, INK_COLOR)

	pixels, ok := read_window(area)
	if !ok {
		check(p, "selection read back", false)
		return true
	}
	read := Read_Back{pixels, int(area.w)}

	// The corners' pixels, by their centres' distance from the curves
	outer := background_px(read, 40, 10) && background_px(read, 139, 29)
	outer &= background_px(read, 20, 49) && selected_px(read, 90, 20)
	check(p, "a selection's outside corners are round", outer)

	inner := selected_px(read, 39, 29) && selected_px(read, 100, 30)
	check(p, "its inside corners curve", inner)

	seam := true
	for x in 41 ..< 99 {
		seam &= selected_px(read, x, 29) && selected_px(read, x, 30)
	}
	check(p, "no seam where its rows meet", seam)

	// A screenful of rows of different lengths, as one shape
	screen := make([]gfx.Rect, 60, context.temp_allocator)
	for &r, i in screen {
		r = {10, f32(i * 20), f32(100 + (i * 37) % 400), 20}
	}
	start := time.tick_now()
	gfx.fill_selection(screen, 3, 5, INK_COLOR)
	gfx.flush_text()
	result(p, "drawing 60 selected rows", ms_since(start), "ms", 1)
	return true
}


// Pixels read back (read_window), with the width of their rows
@(private = "file")
Read_Back :: struct {
	pixels: [][4]u8,
	w:      int,
}


// Whether a pixel read back is mostly INK_COLOR, or INK_BG
@(private = "file")
selected_px :: proc(r: Read_Back, x, y: int) -> bool {
	return pixel_red(r, x, y) > (INK_BG.r + INK_COLOR.r) / 2 + 20
}


@(private = "file")
background_px :: proc(r: Read_Back, x, y: int) -> bool {
	return pixel_red(r, x, y) < INK_BG.r + 20
}


@(private = "file")
pixel_red :: proc(r: Read_Back, x, y: int) -> f32 {
	return f32(r.pixels[y * r.w + x].r)
}


// A format string: "{{" prints "{"
CODE_TEMPLATE :: `// Item %d, generated for the performance suite.
item_%d :: proc(values: []f32, scale: f32) -> (total: f32, ok: bool) {{
	/* block comment %d */
	for v, i in values {{
		if i %% 2 == 0 {{
			total += v * scale
		} else {{
			total -= f32(i) * 0.5
		}
	}
	name := "item-%d\n"
	return total, len(name) > 0
}

`


@(private = "file")
generate_code :: proc(bytes: int) -> string {
	sb := strings.builder_make_len_cap(0, bytes + 512)
	strings.write_string(&sb, "package perf\n\n")
	for i := 0; strings.builder_len(sb) < bytes; i += 1 {
		fmt.sbprintf(&sb, CODE_TEMPLATE, i, i, i, i)
	}
	return strings.to_string(sb)
}


MARKDOWN_TEMPLATE :: `## Section %d

Some *emphasis* and **strong** text with ` + "`code`" + ` and a [link](https://example.com/%d).
A second line of the same paragraph, long enough to wrap in a narrow window.

- item one with ~~strike~~
- [ ] task %d
  - nested item

> A quote with a lazy
continuation line.

| a | b |
|---|:-:|
| %d | x |

` + "```odin" + `
x := %d
` + "```" + `

`


@(private = "file")
generate_markdown :: proc(bytes: int) -> string {
	sb := strings.builder_make_len_cap(0, bytes + 512)
	strings.write_string(&sb, "# Notes\n\n")
	for i := 0; strings.builder_len(sb) < bytes; i += 1 {
		fmt.sbprintf(&sb, MARKDOWN_TEMPLATE, i, i, i, i, i)
	}
	return strings.to_string(sb)
}


// A long table followed by a long code block, its lines wider than the column
@(private = "file")
generate_markdown_blocks :: proc() -> string {
	CODE_LINE :: "value_%d := compute(%d, \"a line long enough to scroll sideways in " +
	             "its box\") // %d\n"

	sb := strings.builder_make()

	header := "# Blocks\n\nSome text.\n\n| name | value | note |\n|---|:-:|--:|\n"
	strings.write_string(&sb, header)
	for i in 0 ..< 300 do fmt.sbprintf(&sb, "| row %d | **%d** | `x` |\n", i, i)

	strings.write_string(&sb, "\n```odin\n")
	for i in 0 ..< 1500 do fmt.sbprintf(&sb, CODE_LINE, i, i, i)
	strings.write_string(&sb, "```\n")

	return strings.to_string(sb)
}


@(private = "file")
phase_generate :: proc(p: ^Perf, frame: int) -> bool {
	t := time.tick_now()

	// Code and Markdown
	p.code_text = generate_code(400 << 10)
	p.large_text = generate_code(64 << 20)
	p.md_text = generate_markdown(4 << 20)
	_ = os.write_entire_file(path_in_dir(p, "notes.md"), p.md_text)
	blocks := generate_markdown_blocks()
	_ = os.write_entire_file(path_in_dir(p, "blocks.md"), transmute([]u8)blocks)
	delete(blocks)
	_ = os.write_entire_file(path_in_dir(p, "code.odin"), p.code_text)
	_ = os.write_entire_file(path_in_dir(p, "large.odin"), p.large_text)

	// One long line
	long := strings.builder_make_len_cap(0, 8 << 20)
	for i := 0; strings.builder_len(long) < 8 << 20; i += 1 {
		fmt.sbprintf(&long, "value_%d = {{a: %d, b: \"text\"}}; ", i, i)
	}
	_ = os.write_entire_file(path_in_dir(p, "long.js"), strings.to_string(long))
	strings.builder_destroy(&long)

	// Lines for the terminal to print
	FLOOD_LINE :: "%08d The quick brown fox jumps over the lazy dog, again and again " +
	              "and again.\n"
	flood := strings.builder_make_len_cap(0, 4 << 20)
	for i := 0; strings.builder_len(flood) < 4 << 20; i += 1 {
		fmt.sbprintf(&flood, FLOOD_LINE, i)
	}
	_ = os.write_entire_file(path_in_dir(p, "flood.txt"), strings.to_string(flood))
	strings.builder_destroy(&flood)

	elapsed := fmt.tprintf("%.3f", ms_since(t))
	fmt.printfln("  %-36s %10s ms", "generated 80 MB in 5 files", elapsed)
	return true
}


@(private = "file")
phase_buffer :: proc(p: ^Perf, frame: int) -> bool {
	b: buffer.Buffer
	data := transmute([]u8)strings.clone(p.large_text)
	t := time.tick_now()
	buffer.buffer_init(&b, data)
	result(p, "load (index line breaks)", ms_since(t), "ms", 150)
	defer buffer.buffer_destroy(&b)

	// Lookups at random places
	N :: 100_000
	lines := buffer.line_count(&b)
	t = time.tick_now()
	sum := 0
	for _ in 0 ..< N {
		sum += buffer.line_start(&b, rand.int_max(lines))
		sum += buffer.offset_to_line(&b, rand.int_max(buffer.length(&b)))
	}
	result(p, "line lookup", f64(time.tick_since(t)) / (2 * N), "ns", 5000)

	// Edits at random places, then undoing them
	EDITS :: 10_000
	t = time.tick_now()
	for i in 0 ..< EDITS {
		buffer.begin(&b, .Other, u64(i) * 10 * buffer.COALESCE_NS, {})
		buffer.replace(&b, rand.int_max(buffer.length(&b)), rand.int_max(4), "edit\n")
		buffer.end(&b, {})
	}
	result(p, "random edit", f64(time.tick_since(t)) / EDITS / 1000, "µs", 50)

	// A snapshot copies the pieces, never the text
	t = time.tick_now()
	snapshot := buffer.snapshot(&b)
	result(p, "snapshot after the edits", ms_since(t), "ms", 2)

	// The words around the middle, as the words thread collects them
	middle := buffer.line_count(&b) / 2
	t = time.tick_now()
	index := words.collect(&snapshot, buffer.line_start(&b, middle), middle)
	name := fmt.tprintf("words of %d lines (words thread)", 2 * words.WINDOW_LINES)
	result(p, name, ms_since(t), "ms", 100)
	words.index_release(index)
	buffer.snapshot_release(&snapshot)

	t = time.tick_now()
	for _ in 0 ..< EDITS do buffer.undo(&b)
	result(p, "undo", f64(time.tick_since(t)) / EDITS / 1000, "µs", 50)

	_ = buffer.take_changes(&b)
	return true
}


@(private = "file")
phase_syntax :: proc(p: ^Perf, frame: int) -> bool {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(p.code_text))
	defer buffer.buffer_destroy(&b)

	// tree-sitter: the whole file
	h: syntax.Highlighter
	t := time.tick_now()
	syntax.highlighter_open(&h, &b, "code.odin")
	name := fmt.tprintf("tree-sitter parse (%d KB)", len(p.code_text) >> 10)
	result(p, name, ms_since(t), "ms", 250)

	// Typing in the middle: one incremental re-parse per keystroke
	EDITS :: 50
	mid := buffer.line_start(&b, buffer.line_count(&b) / 2)
	worst: f64
	t = time.tick_now()
	for i in 0 ..< EDITS {
		e := time.tick_now()
		buffer.begin(&b, .Typing, u64(i), {})
		buffer.replace(&b, mid + i, 0, "x")
		buffer.end(&b, {})
		syntax.highlighter_update(&h, &b, buffer.take_changes(&b))
		worst = max(worst, ms_since(e))
	}
	result(p, "tree-sitter re-parse per keystroke", ms_since(t) / EDITS, "ms", 5)
	result(p, "tree-sitter re-parse worst", worst, "ms")
	result(p, "tree-sitter highlight one screen", highlight_screen(&h, &b, mid), "ms", 2)
	syntax.highlighter_close(&h)

	// The lexer, on the large file
	large: buffer.Buffer
	buffer.buffer_init(&large, transmute([]u8)strings.clone(p.large_text))
	defer buffer.buffer_destroy(&large)
	syntax.highlighter_open(&h, &large, "large.odin")
	defer syntax.highlighter_close(&h)

	far := buffer.line_start(&large, buffer.line_count(&large) * 9 / 10)
	result(p, "lexer highlight one screen (cold)", highlight_screen(&h, &large, far), "ms", 2)

	t = time.tick_now()
	for syntax.highlighter_busy(&h, &large) do syntax.highlighter_update(&h, &large, nil)
	result(p, "lexer catch-up to 90% of 64 MB", ms_since(t), "ms", 2000)
	return true
}


@(private = "file")
phase_markdown :: proc(p: ^Perf, frame: int) -> bool {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(p.md_text))
	defer buffer.buffer_destroy(&b)
	doc: markdown.Doc
	defer markdown.doc_destroy(&doc)

	// The whole file
	t := time.tick_now()
	markdown.doc_open(&doc, &b)
	markdown.doc_update(&doc, &b, max(int), time.Hour)
	name := fmt.tprintf("block parse (%d MB)", len(p.md_text) >> 20)
	result(p, name, ms_since(t), "ms", 40)

	// Typing in the middle
	EDITS :: 50
	mid_line := buffer.line_count(&b) / 2
	mid := buffer.line_start(&b, mid_line)
	t = time.tick_now()
	for i in 0 ..< EDITS {
		buffer.begin(&b, .Typing, u64(i), {})
		buffer.replace(&b, mid + i, 0, "x")
		buffer.end(&b, {})
		markdown.doc_edit(&doc, buffer.take_changes(&b))
		markdown.doc_update(&doc, &b, mid_line + 60, markdown.PARSE_BUDGET)
	}
	result(p, "block re-parse per keystroke", ms_since(t) / EDITS * 1000, "µs", 100)

	// Text view highlighting: blocks, inlines and fenced code for 60 lines
	end := buffer.line_start(&b, mid_line + 60)
	hl := make([]syntax.Highlight, end - mid, context.temp_allocator)
	styles := make([]markdown.Text_Styles, end - mid, context.temp_allocator)
	RUNS :: 20
	t = time.tick_now()
	for _ in 0 ..< RUNS do markdown.highlight_range(&doc, &b, mid, hl, styles)
	result(p, "highlight one screen", ms_since(t) / RUNS, "ms", 0.5)

	// An unclosed fence turns the rest of the file into code: the visible part
	// is parsed at once, the rest in later frames
	buffer.begin(&b, .Other, EDITS, {})
	buffer.replace(&b, mid, 0, "```\n")
	buffer.end(&b, {})
	markdown.doc_edit(&doc, buffer.take_changes(&b))
	t = time.tick_now()
	markdown.doc_update(&doc, &b, mid_line + 60 + markdown.LOOKAHEAD_LINES, markdown.PARSE_BUDGET)
	result(p, "re-parse after opening a fence (frame)", ms_since(t), "ms", 3)
	return true
}


// Average time to highlight the 60 lines from `offset`
@(private = "file")
highlight_screen :: proc(h: ^syntax.Highlighter, b: ^buffer.Buffer, offset: int) -> f64 {
	line := buffer.offset_to_line(b, offset)
	end := buffer.line_start(b, line + 60)
	out := make([]syntax.Highlight, end - offset, context.temp_allocator)

	RUNS :: 20
	t := time.tick_now()
	for _ in 0 ..< RUNS do syntax.highlight_range(h, b, offset, out)
	return ms_since(t) / RUNS
}


@(private = "file")
phase_fuzzy :: proc(p: ^Perf, frame: int) -> bool {
	N :: 200_000
	paths := make([]string, N, context.temp_allocator)
	for &path, i in paths {
		path = fmt.tprintf(
			"src/module_%d/component_%d/file_name_%d.odin",
			i % 97,
			i % 1013,
			i,
		)
	}

	t := time.tick_now()
	matched := 0
	for path in paths {
		_, ok := fuzzy.score("modcompfile77", path)
		if ok do matched += 1
	}
	result(p, fmt.tprintf("score %dk paths", N / 1000), ms_since(t), "ms", 400)
	return true
}


@(private = "file")
phase_vt :: proc(p: ^Perf, frame: int) -> bool {
	s: term.Session
	if !term.session_init(&s, 200, 60, wake_main_loop, nil) do return true
	defer term.session_destroy(&s)

	// 1 MB of colored lines
	LINE :: "\x1b[3%dmline %d\x1b[0m: \x1b[1;34mlorem ipsum\x1b[0m dolor sit amet, " +
	        "consectetur \x1b[7madipiscing\x1b[27m elit\r\n"
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; strings.builder_len(sb) < 1 << 20; i += 1 {
		fmt.sbprintf(&sb, LINE, i % 8, i)
	}
	chunk := strings.to_string(sb)

	REPEAT :: 32
	t := time.tick_now()
	for _ in 0 ..< REPEAT do term.terminal_vt_write(s.vt, raw_data(chunk), len(chunk))
	secs := time.duration_seconds(time.tick_since(t))
	result(p, "parse colored output", f64(REPEAT * len(chunk)) / (1 << 20) / secs, "MB/s")
	result(p, "parse 1 MB of colored output", secs * 1000 / REPEAT, "ms", 100)
	return true
}


// --- UI phases ---------------------------------------------------------------------

// Opens a file as the only one open, waiting for the loader
@(private = "file")
open_timed :: proc(p: ^Perf, name: string) {
	close_files()

	t := time.tick_now()
	open_loaded(path_in_dir(p, name))
	result(p, "open", ms_since(t), "ms", 250)
}


// Closes every file without asking about changes
@(private)
close_files :: proc() {
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		pane := g.panes.open[i]
		_, is_editor := pane.content.(^Editor)
		if is_editor do pane_close(pane, ask = false)
	}
}


@(private = "file")
phase_open_code :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "code.odin")
	return frame == 30
}


@(private = "file")
phase_open_markdown :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 {
		open_timed(p, "notes.md")
		check(p, "opens rendered", md_rendered(focused_editor()))
	}
	return frame == 30
}


// Moves the caret down a line per frame, from a long table into a long code block
@(private = "file")
phase_move_markdown :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "blocks.md")

	e := focused_editor()
	if frame == 0 {
		textedit.show_caret(e, true)
		at := buffer.line_start(&e.buf, 252)
		textedit.set_single_selection(e, {at, at, -1})
		e.reveal = true
		return false
	}

	textedit.move(e, .Down, false)
	return frame == 120
}


// Types in the paragraph above blocks.md's table, which stays in view: each
// edit drops the caches of the document, the table's measured columns too
@(private = "file")
phase_type_above_table :: proc(p: ^Perf, frame: int) -> bool {
	e := focused_editor()
	if frame == 0 {
		at := buffer.line_end(&e.buf, 2)
		textedit.set_single_selection(e, {at, at, -1})
		textedit.scroll_to(e, 0)
		e.reveal = true
		return false
	}

	text := " more words"
	editor_text_input(e, text[frame % len(text):][:1])
	return frame == 120
}


// Types in a cell of blocks.md's table, which stays rendered: each edit
// measures the table's columns again, and the caret is kept in the cell
@(private = "file")
phase_type_in_table :: proc(p: ^Perf, frame: int) -> bool {
	e := focused_editor()
	if frame == 0 {
		at := buffer.line_start(&e.buf, 8) + 3
		textedit.set_single_selection(e, {at, at, -1})
		textedit.scroll_to(e, 0)
		e.reveal = true
		return false
	}

	text := " more words"
	editor_text_input(e, text[frame % len(text):][:1])
	if frame < 120 do return false

	row, _ := textedit.line_text(e, 8)
	in_cell := strings.count(row, "|") == 4 && strings.count(row, "more words") >= 10
	check(p, "typed text is in the cell", in_cell)
	return true
}


// A space or tab typed after a heading, on a blank line and after a paragraph
// moves the caret, measured with the real fonts
@(private = "file")
phase_md_whitespace :: proc(p: ^Perf, frame: int) -> bool {
	if frame > 0 do return true

	e := focused_editor()
	check(p, "space after a heading", whitespace_moves_caret(e, 0, sdl.K_SPACE))
	check(p, "tab after a heading", whitespace_moves_caret(e, 0, sdl.K_TAB))
	check(p, "space on a blank line", whitespace_moves_caret(e, 1, sdl.K_SPACE))
	check(p, "tab on a blank line", whitespace_moves_caret(e, 1, sdl.K_TAB))
	check(p, "space after a paragraph", whitespace_moves_caret(e, 2, sdl.K_SPACE))
	check(p, "tab after a paragraph", whitespace_moves_caret(e, 2, sdl.K_TAB))
	return false
}


// Whether a space or tab typed at the end of `line` moves the caret right. The
// edit is undone
@(private = "file")
whitespace_moves_caret :: proc(e: ^Editor, line: int, key: sdl.Keycode) -> bool {
	at := buffer.line_end(&e.buf, line)
	textedit.set_single_selection(e, {at, at, -1})
	before := mdview.caret_at(&e.md_view, at).x

	if key == sdl.K_SPACE {
		editor_text_input(e, " ")
	} else {
		editor_handle_key(e, {key = key})
	}
	settle_markdown(e)
	after := mdview.caret_at(&e.md_view, e.sels[0].head).x

	textedit.undo(e)
	settle_markdown(e)
	return after > before
}


// Applies the pending edits and parses the whole document
@(private = "file")
settle_markdown :: proc(e: ^Editor) {
	textedit.take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
}


@(private = "file")
phase_idle :: proc(p: ^Perf, frame: int) -> bool {
	// Nothing else wakes an idle app, so a timer ends the phase
	if frame == 0 {
		_ = sdl.AddTimer(u32(PERF_IDLE_NS / time.Millisecond) + 20, idle_over, nil)
	}
	elapsed := time.tick_since(p.phase_t0)
	if elapsed < PERF_IDLE_NS do return false

	secs := time.duration_seconds(elapsed)
	result(p, "frames per second", f64(frame) / secs, "fps", 5)

	// Process CPU includes other threads (SDL, the GPU driver, the pty reader),
	// so it is noisier than the frames' own time
	cpu_secs := f64(process_cpu_ns() - p.cpu0) / 1e9
	result(p, "process CPU (one core = 100%)", cpu_secs / secs * 100, "%", 1.5)

	worst: f64
	for f in p.frames do worst = max(worst, f[.Update] + f[.Render])
	result(p, "frame CPU max", worst, "ms", 2)

	gpu := gpu_counter_read(&p.gpu)
	if gpu >= 0 do result(p, "GPU utilization", gpu, "%", 2)
	return true
}


@(private = "file")
idle_over :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return 0 // one-shot
}


// Types 120 characters, one per frame, in the middle of the open file
@(private = "file")
phase_type :: proc(p: ^Perf, frame: int) -> bool {
	e := focused_editor()
	if frame == 0 {
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		textedit.show_caret(e, true)
		textedit.set_single_selection(e, {mid, mid, -1})
		e.reveal = true
		return false
	}

	text := "the quick brown fox "
	editor_text_input(e, text[frame % len(text):][:1])
	return frame == 120
}


// In code.odin, with no language server: a word typed lists the file's words
// once it is three letters long, each letter filters them again (with digits,
// thousands match), Enter inserts the chosen one and one undo takes it back.
// The text is then as it was
@(private = "file")
phase_word_completion :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) step_at: time.Tick
	@(static) typed: int
	@(static) length: int // of the text before

	cs := &g.lsp.completion
	e := focused_editor()
	waited := frame - p.mark_frame
	waited_ms := ms_since(step_at)
	word := "item_4"

	if frame == 0 {
		step, typed = 0, 0
		p.mark_frame, step_at = frame, time.tick_now()
		return false
	}

	switch step {
	case 0: // its words collected; a new line in item_0
		if e.words.index == nil && waited_ms < 3000 {
			return false
		}

		check(p, "the file's words are collected", e.words.index != nil)
		length = buffer.length(&e.buf)
		at := text_offset(e, "\treturn total") - 1
		textedit.set_single_selection(e, {at, at, -1})
		textedit.insert(e, "\n\t")
		step, p.mark_frame, step_at = 1, frame, time.tick_now()

	case 1: // three letters, then the list
		if typed < 3 {
			if waited % 2 == 0 {
				editor_text_input(e, word[typed:][:1])
				typed += 1
			}
			return false
		}
		if !(cs.open && len(cs.shown) > 0) && waited_ms < 3000 {
			return false
		}

		check(p, "three letters list the file's words", len(cs.shown) > 0)
		step, p.mark_frame = 2, frame

	case 2: // the rest, a letter every other frame
		if typed < len(word) {
			if waited % 2 == 0 {
				editor_text_input(e, word[typed:][:1])
				typed += 1
			}
			return false
		}

		listed := len(cs.shown) > 1 && cs.shown[0].index < 0
		check(p, "each letter filters them", listed && cs.shown[0].word != word)
		chosen := listed ? strings.clone(cs.shown[cs.selected].word) : ""
		defer delete(chosen)
		press(sdl.K_RETURN)

		line, _ := caret_line(e)
		check(p, "Enter inserts the chosen word", listed && line == fmt.tprintf("\t%s", chosen))
		run_command(.Undo)
		line, _ = caret_line(e)
		check(p, "one undo takes it back", line == fmt.tprintf("\t%s", word))

		// The text as it was
		for _ in 0 ..< 4 {
			if buffer.length(&e.buf) == length do break
			run_command(.Undo)
		}
		check(p, "the text is as it was", buffer.length(&e.buf) == length)
		return true
	}
	return false
}


@(private = "file")
phase_scroll :: proc(p: ^Perf, frame: int) -> bool {
	textedit.move(focused_editor(), .Page_Down, false)
	return frame == 120
}


// A file with one wide line out of view: no sideways scroll bar until the
// caret goes to that line's end, which shows; then the bar along the text's
// bottom drags to either end, jumps where its track is clicked and takes the
// pointer from the text, and a sideways wheel scrolls
@(private = "file")
phase_sideways :: proc(p: ^Perf, frame: int) -> bool {
	@(static) mouse: [2]f32
	e := focused_editor()

	switch frame {
	case 0:
		mouse = g.mouse_pos
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 300 {
			text := strings.repeat("w", i == 150 ? 600 : 40, context.temp_allocator)
			fmt.sbprintf(&sb, "line_%d := \"%s\"\n", i, text)
		}

		path := path_in_dir(p, "wide.odin")
		_ = os.write_entire_file(path, transmute([]u8)strings.to_string(sb))
		close_files()
		open_loaded(path)

	case 5:
		max_x, _ := editor_sideways(e)
		check(p, "no sideways bar while the lines fit", max_x == 0)
		end := buffer.line_end(&e.buf, 150)
		textedit.set_single_selection(e, {end, end, -1})
		e.reveal = true

	case 6:
		caret, shows := e.kind.char_rect(e, e.sels[0].head - 1)
		in_view := shows && caret.x + caret.w <= e.view.x + e.view.w
		check(p, "the caret at a wide line's end shows", in_view && e.scroll_x > 0)
		_, thumb, bar := editor_scrollbar(e, .Horizontal)
		check(p, "then a sideways bar shows", bar)

		// Its thumb pressed, then dragged to the left end and the right
		g.mouse_pos = {thumb.x + thumb.w / 2, thumb.y + thumb.h / 2}
		g.mouse_down, g.mouse_pressed, g.mouse_clicks = true, true, 1

	case 7:
		track, _, _ := editor_scrollbar(e, .Horizontal)
		g.mouse_pos.x = track.x - 40

	case 8:
		check(p, "dragging its thumb scrolls", e.scroll_x == 0)
		track, _, _ := editor_scrollbar(e, .Horizontal)
		g.mouse_pos.x = track.x + track.w + 40

	case 9:
		max_x, _ := editor_sideways(e)
		check(p, "to either end", max_x > 0 && e.scroll_x == max_x)
		g.mouse_down = false

	case 10:
		// A click near the track's left end
		track, _, _ := editor_scrollbar(e, .Horizontal)
		g.mouse_pos = {track.x + 4, track.y + track.h / 2}
		check(p, "the bar takes the pointer from the text", !editor_text_hit(e, g.mouse_pos))
		g.mouse_down, g.mouse_pressed = true, true

	case 11:
		check(p, "clicking its track jumps there", e.scroll_x == 0)
		g.mouse_down = false

	case 12:
		g.mouse_pos = {e.view.x + e.view.w / 2, e.view.y + e.view.h / 2}
		g.wheel = {-2, 0}

	case 13:
		check(p, "a sideways wheel scrolls", e.target_x > 0)
		g.mouse_pos = mouse
		return true
	}
	return false
}


// Ordered list numbers in the real Markdown font: each digit in a cell as wide
// as the widest, so single digits line up whatever their shapes, the dots line
// up and the items' text starts at one x
@(private = "file")
phase_list_numbers :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 {
		path := path_in_dir(p, "lists.md")
		_ = os.write_entire_file(path, "Lists\n\n1. one\n7. seven\n4. four\n10. ten\n")
		close_files()
		open_loaded(path)
		return false
	}
	if frame < 5 do return false

	// Before the units digit, after the dot, before the text
	e := focused_editor()
	digit, dot, item: [4]f32
	for i in 0 ..< 4 {
		text, start := textedit.line_text(e, 2 + i)
		at := start + strings.index_byte(text, '.')
		digit[i] = mdview.caret_at(&e.md_view, at - 1).x
		dot[i] = mdview.caret_at(&e.md_view, at + 1).x
		item[i] = mdview.caret_at(&e.md_view, at + 2).x
	}

	check(p, "opens rendered", md_rendered(e))
	check(p, "list numbers' digits line up", all_equal(digit[:]))
	check(p, "their dots line up", all_equal(dot[:]))
	check(p, "their items' text starts at one x", all_equal(item[:]))
	return true
}


// Whether the values are the same, give or take float rounding
@(private = "file")
all_equal :: proc(values: []f32) -> bool {
	for v in values {
		if abs(v - values[0]) > 0.01 do return false
	}
	return true
}


// Narrows the window 10 pixels a frame for 60 frames, then widens it back.
// Rendered Markdown first only re-centers its column, then rewraps every frame
@(private = "file")
phase_resize :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do _ = sdl.GetWindowSize(g.window, &p.window_size.x, &p.window_size.y)

	step := i32(frame <= 60 ? frame : 120 - frame)
	_ = sdl.SetWindowSize(g.window, p.window_size.x - 10 * step, p.window_size.y)
	return frame == 120
}


// Opens the finder and runs two queries, measuring the second: the first also
// loads the bold font used for matched characters
@(private = "file")
phase_finder :: proc(p: ^Perf, frame: int) -> bool {
	f := &g.finder

	switch {
	case frame == 0:
		finder_toggle()
		line_edit_set(&f.query, "large", 5, 5)
		finder_restart_search()
		p.mark_frame = -1

	case finder_busy() || frame < 10:

	case p.mark_frame < 0:
		p.mark_frame = frame
		clear(&p.frames)
		line_edit_set(&f.query, "codeodin", 8, 8)
		finder_restart_search()

	case frame < p.mark_frame + 20:

	case:
		found := len(f.results) > 0 &&
		         strings.has_suffix(f.files[f.results[0].index], "code.odin")
		check(p, "finds code.odin", found)
		finder_toggle()
		return true
	}
	return false
}


// Open and recent files in the finder: with the file focused, code.odin open
// beside it and two files used recently, the empty query lists code.odin,
// then the two most recent first, and not the focused file. Of two files a
// query matches equally ("data" in alpha/ and omega/), the recent one comes
// first, whichever it is
@(private = "file")
phase_finder_ranks :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) code: ^Pane // opened here, closed at the end
	f := &g.finder
	sep := os.Path_Separator
	alpha := path_in_dir(p, fmt.tprintf("ranked%calpha%cdata.txt", sep, sep))
	omega := path_in_dir(p, fmt.tprintf("ranked%comega%cdata.txt", sep, sep))

	if frame == 0 {
		// The two equal files, indexed again
		for path in ([]string{alpha, omega}) {
			_ = os.make_directory_all(parent_dir(path))
			_ = os.write_entire_file(path, transmute([]u8)string("data\n"))
		}
		finder_invalidate()

		// code.odin open beside the focused file, then two files used
		focused := g.panes.focused
		code = nil
		if pane_with_file(path_in_dir(p, "code.odin")) == nil {
			code = panes_open_file_beside(path_in_dir(p, "code.odin"))
		}
		pane_focus(focused)
		recent_add(&g.recent,path_in_dir(p, "long.js"))
		recent_add(&g.recent,path_in_dir(p, "flood.txt"))

		finder_toggle()
		step, p.mark_frame = 1, frame
		return false
	}
	if finder_busy() || frame < p.mark_frame + 2 {
		return false
	}

	switch step {
	case 1:
		listed := make([dynamic]string, context.temp_allocator)
		for m in f.results do append(&listed, finder_display_path(m.index))

		top := len(listed) >= 3 && listed[0] == "code.odin"
		top = top && listed[1] == "flood.txt" && listed[2] == "long.js"
		check(p, "no query: the open file, then the recent ones", top)

		current := focused_editor()
		skipped := current != nil
		for m in f.results {
			if current != nil && same_path(f.files[m.index], current.path) {
				skipped = false
			}
		}
		check(p, "no query: the focused file isn't listed", skipped)

		rank, ranked, _ := file_rank_of(path_in_dir(p, "code.odin"))
		check(p, "an open file is marked open", ranked && rank.open)

		// omega/ used recently
		recent_add(&g.recent,omega)
		reopen_finder("data")
		next_step(p, &step, frame)

	case 2:
		first := len(f.results) > 0 && same_path(f.files[f.results[0].index], omega)
		check(p, "a query ranks a recent file above an equal match", first)

		// alpha/ instead
		recent_forget(&g.recent, omega)
		recent_add(&g.recent,alpha)
		reopen_finder("data")
		next_step(p, &step, frame)

	case 3:
		first := len(f.results) > 0 && same_path(f.files[f.results[0].index], alpha)
		check(p, "... whichever of the two it is", first)

		finder_close()
		if code != nil do pane_close(code, ask = false)
		return true
	}
	return false
}


// Opens the finder's files again (ranks taken anew) with a query
@(private = "file")
reopen_finder :: proc(query: string) {
	finder_close()
	finder_toggle()
	line_edit_set(&g.finder.query, query, len(query), len(query))
	finder_restart_search()
}


// The finder's rank for a file it indexed
@(private = "file")
file_rank_of :: proc(path: string) -> (rank: Rank, ranked: bool, current: bool) {
	for file, i in g.finder.files {
		if same_path(file, path) do return search_file_rank(&g.finder.search, i)
	}
	return
}


// Opens the settings window, searches it, moves through the rows, scrolls it with
// the wheel (over a row's label, and over a horizontally clipped element such
// as an input box, which is a Clay scroll container of its own), and closes it
// while the list may still be easing
@(private = "file")
phase_settings :: proc(p: ^Perf, frame: int) -> bool {
	WHEEL_FRAMES :: 10
	w := &g.settings_window
	@(static) scrolled, start: int
	@(static) mouse: [2]f32

	switch {
	case frame == 0:
		settings_window_toggle()
		scrolled = 0
		start = 0

	case frame <= 4:
		search := "font"
		type_text(search[frame - 1:frame])

	case frame == 5:
		line_edit_clear(&w.search)

	case frame <= 30:
		w.focus = (frame - 6) % max(len(w.items), 1)
		w.reveal = true

	// The pointer reaches elements only once they stop moving
	case start == 0 && g.animating:

	case start == 0 || frame < start + 2 * WHEEL_FRAMES:
		if start == 0 do start = frame
		list := clay.ID("SettingsList")
		data := clay.GetScrollContainerData(list)
		r, ok := element_rect(list)
		if !data.found || !ok {
			break
		}

		// From the top of the list: the second step finds where to point, from
		// the layout scrolled back by the first
		step := (frame - start) % WHEEL_FRAMES
		switch step {
		case 0:
			if frame == start do mouse = g.mouse_pos
			data.scrollPosition.y = 0
		case 1:
			g.mouse_pos = {r.x + 40, r.y + r.h / 2}
			if frame == start + 1 {
				at, found := clipped_point(r)
				if !found do break
				g.mouse_pos = at
			}
			g.wheel = {0, -1}
		case WHEEL_FRAMES - 1:
			if data.scrollPosition.y < 0 do scrolled += 1
		}

	case:
		g.mouse_pos = mouse
		check(p, "the wheel scrolls the settings", scrolled == 2)

		file_only := 0
		for info in SETTINGS {
			if info.name == "" do file_only += 1
		}
		listed := len(Command) + len(Setting) - file_only + len(server_rows()) + 1
		listed += len(Section) // their headers
		check(p, "lists every setting, command and language server", len(w.items) == listed)

		settings_window_toggle()
		return true
	}
	return false
}


// A window short enough that a language server's page has to scroll
@(private = "file")
SHORT_WINDOW_H :: 420


// The settings window's pages fit its panel and scroll: the list at an odd
// window width, while the panel moves back from the theme picker, and at a new
// window size; a language server's page in a short window
@(private = "file")
phase_settings_scrolls :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) moving_frames: int
	@(static) moving_ok: int
	@(static) last_panel: gfx.Rect
	@(static) theme_before: string // owned
	@(static) clicked_rows: int
	if frame == 0 {
		_ = sdl.GetWindowSize(g.window, &p.window_size.x, &p.window_size.y)
		resize_for_check({p.window_size.x | 1, p.window_size.y})
		step = 1
		p.mark_frame = frame
		moving_frames = 0
		moving_ok = 0
		return false
	}
	waited := frame - p.mark_frame
	panel, _ := element_rect(clay.ID("Settings"))
	panel_moved := panel != last_panel
	last_panel = panel

	switch step {
	case 1: // the window at its odd width: open the settings
		if !resized_for_check(p, waited) do return false

		settings_window_toggle()
		next_step(p, &step, frame)

	case 2: // open: the theme's picker
		if (g.animating || waited < 2) && waited < 600 {
			return false
		}

		fits, more := list_scrolls(clay.ID("SettingsList"))
		check(p, "the settings list fits and scrolls", fits && more)
		focus_item(Setting.Theme)
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 3: // the picker shown: click the first theme
		if (g.animating || waited < 2) && waited < 600 {
			return false
		}

		set_string(&theme_before, g.settings.theme)
		click_element(clay.ID("PickerRow", 0))
		clicked_rows = 1
		next_step(p, &step, frame)

	case 4: // it applies on the next frame (the second if the first was applied)
		if waited < 3 do return false
		if g.settings.theme == theme_before && clicked_rows == 1 {
			click_element(clay.ID("PickerRow", 1))
			clicked_rows = 2
			p.mark_frame = frame
			return false
		}

		check(p, "clicking a theme applies it", g.settings.theme != theme_before)
		press(sdl.K_ESCAPE)
		check(p, "and Esc puts the theme back", g.settings.theme == theme_before)
		next_step(p, &step, frame)

	case 5: // the panel moving back, then there: make the window shorter
		if waited < 2 do return false // the list's first layout
		if panel_moved && waited < 600 {
			// The panel grows into the list, laid out at its final size
			_, more := list_scrolls(clay.ID("SettingsList"))
			moving_frames += 1
			if more do moving_ok += 1
			return false
		}
		if g.animating && waited < 600 {
			return false
		}

		moving := moving_frames > 0 && moving_ok == moving_frames
		check(p, "it scrolls while the panel moves", moving)
		resize_for_check({p.window_size.x | 1, p.window_size.y - 100})
		next_step(p, &step, frame)

	case 6: // the new size: a server's page in a short window
		if !resized_for_check(p, waited) do return false
		if waited < 3 do return false

		fits, more := list_scrolls(clay.ID("SettingsList"))
		check(p, "and at a new size", fits && more)
		resize_for_check({p.window_size.x, SHORT_WINDOW_H})
		next_step(p, &step, frame)

	case 7: // short: open a server's page
		if !resized_for_check(p, waited) do return false
		if waited < 3 do return false

		focus_item(Server_Item(server_row_index("clangd")))
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 8: // its fields scroll, the footer stays in the panel
		if (g.animating || waited < 3) && waited < 600 {
			return false
		}

		fits, more := list_scrolls(clay.ID("ServerList"))
		check(p, "a server's page fits and scrolls", fits && more)

		delete(theme_before)
		theme_before = ""
		press(sdl.K_ESCAPE)
		settings_window_toggle()
		_ = sdl.SetWindowSize(g.window, p.window_size.x, p.window_size.y)
		return true
	}
	return false
}


// The window size resize_for_check last asked for
@(private = "file")
wanted_size: [2]i32


// Asks for a window size for a check (applied on a later frame)
@(private = "file")
resize_for_check :: proc(size: [2]i32) {
	wanted_size = size
	_ = sdl.SetWindowSize(g.window, size.x, size.y)
}


// Whether the window has the size last asked for; after waiting long enough,
// fails a check saying it never got it
@(private = "file")
resized_for_check :: proc(p: ^Perf, waited: int) -> bool {
	size := wanted_size
	if g.window_w == size.x && g.window_h == size.y {
		return true
	}
	if waited < 600 do return false

	check(p, fmt.tprintf("the window resized to %dx%d", size.x, size.y), false)
	return true
}


// Whether a list in a settings page, in last frame's layout, fits the panel,
// and has more rows than it shows (so it has a scroll bar)
@(private = "file")
list_scrolls :: proc(list: clay.ElementId) -> (fits, more: bool) {
	data := clay.GetScrollContainerData(list)
	r, list_ok := element_rect(list)
	panel, panel_ok := element_rect(clay.ID("Settings"))
	if !data.found || !list_ok || !panel_ok {
		return
	}

	fits = r.y + r.h <= panel.y + panel.h + 0.5
	more = data.contentDimensions.height > data.scrollContainerDimensions.height
	return
}


// Collapses the keybindings from their header (Enter), the first section by a
// click (which leaves nothing focused), then every section (Collapse all); a
// search still finds settings in collapsed sections; Expand all shows them
// again, and ← and → collapse and expand the focused section
@(private = "file")
phase_settings_collapse :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	w := &g.settings_window
	if frame == 0 {
		settings_window_toggle()
		step, p.mark_frame = 1, frame
		return false
	}
	waited := frame - p.mark_frame

	switch step {
	case 1: // once the panel has arrived: Enter on the keybindings' header
		if g.animating && waited < 600 {
			return false
		}

		focus_item(Section.Keybindings)
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 2: // its rows go, focus stays on it
		if waited < 2 do return false

		collapsed := g.settings.collapsed_sections == "keybindings"
		check(p, "a section collapses", collapsed && count_items(Command) == 0)
		on_header := w.focus >= 0 && w.focus < len(w.items)
		on_header = on_header && w.items[w.focus] == Setting_Item(Section.Keybindings)
		check(p, "focus stays on its header", on_header)

		// The list at its top, for the first section's header
		data := clay.GetScrollContainerData(clay.ID("SettingsList"))
		if data.found do data.scrollPosition.y = 0
		next_step(p, &step, frame)

	case 3: // with a row in it focused, click the first section's header
		if waited < 2 do return false

		focus_item(Setting.Restore_Session)
		click_element(clay.ID("SectionHeader", u32(Section.General)))
		next_step(p, &step, frame)

	case 4: // it collapses, and nothing is focused; then Collapse all
		if waited < 2 do return false

		collapsed := g.settings.collapsed_sections == "general, keybindings"
		check(p, "a click collapses a section", collapsed)
		check(p, "a click doesn't focus the header", w.open && w.focus == -1)
		click_element(clay.ID("SettingsCollapseAll"))
		next_step(p, &step, frame)

	case 5: // only the headers; a search still finds settings
		if waited < 2 do return false

		check(p, "Collapse all leaves only the headers", count_items(Section) == len(w.items))
		line_edit_set(&w.search, "font", 4, 4)
		next_step(p, &step, frame)

	case 6: // then Expand all
		if waited < 2 do return false

		found := count_items(Setting) > 0 && count_items(Section) == 0
		check(p, "a search shows settings in collapsed sections", found)
		line_edit_clear(&w.search)
		next_step(p, &step, frame)

	case 7:
		if waited < 2 do return false
		click_element(clay.ID("SettingsCollapseAll"))
		next_step(p, &step, frame)

	case 8: // everything again; ← collapses the focused section and → expands it
		if waited < 2 do return false

		expanded := g.settings.collapsed_sections == "" && count_items(Command) == len(Command)
		check(p, "Expand all shows every section", expanded)
		focus_item(Section.Font)
		press(sdl.K_LEFT)
		check(p, "← collapses a section", g.settings.collapsed_sections == "font")
		press(sdl.K_RIGHT)
		check(p, "→ expands it", g.settings.collapsed_sections == "")
		if w.open do settings_window_toggle()
		return true
	}
	return false
}


// How many rows of the settings list shown last frame are a T
// Several bindings for Toggle sidebar, in the settings window: Enter on its
// row records a second (Ctrl+Shift+B), shown as a chip; Ctrl+G is taken from
// Go to line and the row says so. Ctrl+B and Ctrl+Shift+B both run it. Then
// → → and Delete remove the second, a press on a chip's x the third; the
// defaults come back
@(private = "file")
phase_settings_bindings :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) sidebar: bool
	w := &g.settings_window
	b := &g.settings.bindings
	n := u32(Command.Toggle_Sidebar) * MAX_CHORDS

	if frame == 0 {
		sidebar = g.sidebar_visible
		settings_window_toggle()
		step, p.mark_frame = 1, frame
		return false
	}
	waited := frame - p.mark_frame
	if (g.animating && waited < 600) || waited < 2 {
		return false
	}

	switch step {
	case 1: // Enter on the row, then Ctrl+Shift+B
		focus_item(Command.Toggle_Sidebar)
		w.reveal = true
		press(sdl.K_RETURN)
		check(p, "Enter on a keybinding records one more", w.recording == .Toggle_Sidebar)
		press_chord(.B, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		next_step(p, &step, frame)

	case 2: // a second chip; then Ctrl+G
		added := bindings_label(b[.Toggle_Sidebar], " ") == "Ctrl+B Ctrl+Shift+B"
		_, chip_shown := element_rect(clay.ID("BindingChip", n + 1))
		check(p, "the key pressed is a second binding, as a chip", added && chip_shown)

		// The + and each chord are centered in their boxes
		check(p, "the add button's + is centered", add_button_square(.Toggle_Sidebar))
		check(p, "a chip's chord is centered", chip_centered(n + 1))

		press(sdl.K_RETURN)
		press_chord(.G, sdl.KMOD_LCTRL)
		next_step(p, &step, frame)

	case 3: // taken from Go to line, which the row says
		taken := bindings_count(b[.Go_To_Line]) == 0 && bindings_count(b[.Toggle_Sidebar]) == 3
		said := w.bind_note == "Ctrl+G was taken from Go to line"
		check(p, "a chord bound elsewhere is taken, and the row says so", taken && said)

		// Both bindings run the command
		settings_window_toggle()
		press_chord(.B, sdl.KMOD_LCTRL)
		first := g.sidebar_visible != sidebar
		press_chord(.B, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		second := g.sidebar_visible == sidebar
		check(p, "each binding runs the command", first && second)

		settings_window_toggle()
		next_step(p, &step, frame)

	case 4: // → → and Delete remove the second
		focus_item(Command.Toggle_Sidebar)
		w.reveal = true
		press(sdl.K_RIGHT)
		press(sdl.K_RIGHT)
		press(sdl.K_DELETE)
		removed := bindings_label(b[.Toggle_Sidebar], " ") == "Ctrl+B Ctrl+G"
		check(p, "Delete on a focused chip removes its binding", removed)
		_, still := command_for_chord({key = sdl.K_B, ctrl = true, shift = true})
		check(p, "a removed binding no longer runs", !still)

		// The pointer on the next chip, to show its x
		at, _ := element_center(clay.ID("BindingChip", n + 1))
		g.mouse_pos = at
		next_step(p, &step, frame)

	case 5: // a press on the x removes it
		click_element(clay.ID("BindingRemove", n + 1))
		next_step(p, &step, frame)

	case 6:
		only := bindings_label(b[.Toggle_Sidebar], " ") == "Ctrl+B"
		check(p, "a press on a chip's x removes its binding", only)

		// Its terminal toggle; editor commands have none
		_, editor_toggle := element_rect(clay.ID("BindingTerminal", u32(Command.Save)))
		check(p, "editor commands have no terminal toggle", !editor_toggle)
		click_element(clay.ID("BindingTerminal", u32(Command.Toggle_Sidebar)))
		next_step(p, &step, frame)

	case 7:
		on := .Toggle_Sidebar in g.settings.terminal_commands
		_, reset := element_rect(clay.ID("BindingReset", u32(Command.Toggle_Sidebar)))
		check(p, "a press on the terminal toggle sets it, and Reset shows", on && reset)

		// The defaults back
		set_terminal_command(.Toggle_Sidebar, false)
		b[.Toggle_Sidebar] = default_bindings(.Toggle_Sidebar)
		b[.Go_To_Line] = default_bindings(.Go_To_Line)
		settings_changed()
		settings_window_toggle()
		g.sidebar_visible = sidebar
		return true
	}
	return false
}


// Whether a command's add button, showing just its +, is a square (the + is
// centered in it, by Clay's alignment)
@(private = "file")
add_button_square :: proc(cmd: Command) -> bool {
	r, ok := element_rect(clay.ID("BindingAdd", u32(cmd)))
	return ok && abs(r.w - r.h) < 0.5
}


// Whether chip n's chord sits between two slots of the same width, as far
// from either edge of the chip
@(private = "file")
chip_centered :: proc(n: u32) -> bool {
	chip, chip_ok := element_rect(clay.ID("BindingChip", n))
	left, left_ok := element_rect(clay.ID("BindingBalance", n))
	right, right_ok := element_rect(clay.ID("BindingRemove", n))
	if !chip_ok || !left_ok || !right_ok {
		return false
	}

	left_gap := left.x - chip.x
	right_gap := chip.x + chip.w - (right.x + right.w)
	return abs(left.w - right.w) < 0.5 && abs(left_gap - right_gap) < 0.5
}


@(private = "file")
count_items :: proc($T: typeid) -> int {
	n := 0
	for item in g.settings_window.items {
		_, ok := item.(T)
		if ok do n += 1
	}
	return n
}


// A point in `r` over an element that clips only horizontally
@(private = "file")
clipped_point :: proc(r: gfx.Rect) -> (at: [2]f32, found: bool) {
	defer clay.SetPointerState(g.mouse_pos, g.mouse_down)

	for y := r.y + 4; y < r.y + r.h; y += 6 {
		for x := r.x + 4; x < r.x + r.w - SCROLLBAR_GUTTER; x += 12 {
			clay.SetPointerState({x, y}, false)
			ids := clay.GetPointerOverIds()
			for id in ids.internalArray[:ids.length] {
				data := clay.GetScrollContainerData(id)
				if data.found && data.config.horizontal && !data.config.vertical {
					return {x, y}, true
				}
			}
		}
	}
	return
}


// How long phase_menu_dialogs leaves the menu, a field or a dialog up
@(private = "file")
MENU_SHOW_TIME :: 700 * time.Millisecond


// Where the open context menu has the item that runs `cmd`, or -1
@(private = "file")
menu_item_index :: proc(cmd: Menu_Command) -> int {
	for item, i in g.menu.items[:g.menu.count] {
		if !item.separator && item.cmd == cmd {
			return i
		}
	}
	return -1
}


// Right-clicks a file in the tree, picks Rename, types a new name in place of
// the selected one (the name before the extension) and presses Enter; then
// edits that file and closes it, answering "Don't save"; then makes a new file
// from the menu under the files. The menu, the fields and the dialog stay up
// for a moment so the window can be looked at
@(private = "file")
phase_menu_dialogs :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) since: time.Tick
	@(static) mouse: [2]f32
	@(static) before: string // the file open before, reopened at the end

	old := path_in_dir(p, "rename_me.txt")
	renamed := path_in_dir(p, "renamed.txt")
	created := path_in_dir(p, "created.txt")
	moved := path_in_dir(p, "zzz_created.txt")
	never := path_in_dir(p, "never.txt")

	if frame == 0 {
		step = 0
		mouse = g.mouse_pos
		if e := focused_editor(); e != nil {
			before = strings.clone(e.path)
		}

		g.sidebar_visible = true
		_ = os.write_entire_file(old, transmute([]u8)string("before"))
		_ = os.remove(renamed)
		_ = os.remove(moved)
		workspace_refresh(&g.workspace)
		return false
	}

	d := &g.dialog
	switch step {
	case 0: // right-click the file's row, once the sidebar is uncovered
		if g.animating do return false

		for index in g.workspace.visible {
			if g.workspace.nodes[index].path != old do continue

			at, ok := element_center(tree_row_id(old))
			if !ok do return false
			g.mouse_pos, g.right_pressed = at, true
			step, since = 1, time.tick_now()
		}
		if step == 0 && frame > 10 {
			check(p, "the file is in the tree", false)
			return true
		}

	case 1: // the menu is open; click Rename
		if menu_still_showing(since) do return false

		rename := menu_item_index(.Rename_File)
		check(p, "right-click opens the menu", g.menu.open && rename >= 0)
		at, _ := element_center(clay.ID("MenuItem", u32(max(rename, 0))))
		g.mouse_pos, g.mouse_pressed = at, true
		step, since = 2, time.tick_now()

	case 2: // the name is editable in the tree, without its extension selected
		if menu_still_showing(since) do return false

		r := &g.rename
		lo, hi := min(r.edit.caret, r.edit.anchor), max(r.edit.caret, r.edit.anchor)
		editing_name := r.active && r.place == .Tree && r.shown &&
		                line_edit_string(&r.edit) == "rename_me.txt" &&
		                lo == 0 && hi == len("rename_me")
		check(p, "Rename edits the name in the tree", editing_name)

		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "renamed"
		handle_key_event(&event)
		press(sdl.K_RETURN)
		step = 3

	case 3: // renamed; now leave unsaved changes in it and close it
		renamed_ok := !g.rename.active && os.exists(renamed) && !os.exists(old)
		check(p, "typing replaces the name and Enter renames", renamed_ok)

		pane := open_loaded(renamed)
		editor_text_input(focused_editor(), "x")
		run_command(.Close_Pane)
		_, asking := d.purpose.(Unsaved_Step)
		check(p, "closing unsaved changes asks", d.open && asking && pane_shown(pane))
		step, since = 4, time.tick_now()

	case 4: // Tab to "Don't save", Enter
		if menu_still_showing(since) do return false

		press(sdl.K_TAB)
		press(sdl.K_RETURN)
		step = 5

	case 5: // right-click under the files
		data, _ := os.read_entire_file(renamed, context.temp_allocator)
		closed_unsaved := !d.open &&
		                  pane_with_file(renamed) == nil &&
		                  string(data) == "before"
		check(p, "\"Don't save\" closes without saving", closed_unsaved)

		_ = os.remove(created)
		r, _ := element_rect(clay.ID("SidebarFiles"))
		g.mouse_pos, g.right_pressed = {r.x + 40, r.y + r.h - 10}, true
		step = 6

	case 6: // New file
		offers_new := g.menu.open &&
		              g.menu.items[0].cmd == .New_File &&
		              g.menu.path == g.workspace.root
		check(p, "right-click under the files offers New file", offers_new)

		at, _ := element_center(clay.ID("MenuItem", 0))
		g.mouse_pos, g.mouse_pressed = at, true
		step, since = 7, time.tick_now()

	case 7: // name it in the new row
		if menu_still_showing(since) do return false

		new_row := g.rename.active && g.rename.create == .File && g.rename.shown
		check(p, "New file adds a row to name it in", new_row)

		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "created.txt"
		handle_key_event(&event)
		press(sdl.K_RETURN)
		step = 8

	case 8: // rename it so that it sorts after renamed.txt, and click that row
		created_open := !g.rename.active &&
		                os.exists(created) &&
		                pane_with_file(created) != nil
		check(p, "Enter creates the file and opens it", created_open)

		rename_start_file(created, .Tree)
		line_edit_set(&g.rename.edit, "zzz_created.txt", 0, 0)
		step, since = 9, time.tick_now()

	case 9:
		if menu_still_showing(since) do return false

		at, _ := element_center(tree_row_id(renamed))
		g.mouse_pos, g.mouse_pressed, g.mouse_down, g.mouse_clicks = at, true, true, 1
		step = 10

	case 10:
		g.mouse_down = false
		step, since = 11, time.tick_now()

	case 11: // with the rename open, right-click a row, then a dialog comes up
		if menu_still_showing(since) do return false

		e := focused_editor()
		opened_row := os.exists(moved) && e != nil && e.path == renamed
		check(p, "a click that ends a rename opens the row clicked", opened_row)

		at, _ := element_center(tree_row_id(renamed))
		g.mouse_pos, g.right_pressed = at, true
		step = 12

	case 12:
		check(p, "right-click opens the menu again", g.menu.open)
		rename_start_file(renamed, .Tree)
		line_edit_set(&g.rename.edit, "never.txt", 0, 0)
		ask_reset_settings()
		check(p, "a dialog closes the context menu", d.open && !g.menu.open)

		// The pointer over text, where it would be an I-beam
		if e := focused_editor(); e != nil {
			for y := e.view.y; y < e.view.y + e.view.h; y += 4 {
				for x := e.view.x; x < e.view.x + e.view.w; x += 4 {
					if editor_text_hit(e, {x, y}) {
						g.mouse_pos = {x, y}
						break
					}
				}
				if editor_text_hit(e, g.mouse_pos) do break
			}
			check(p, "the pointer is over text", editor_text_hit(e, g.mouse_pos))
		}
		step, since = 13, time.tick_now()

	case 13: // click Cancel
		if menu_still_showing(since) do return false

		check(p, "the pointer is an arrow over the dialog", current_cursor == .DEFAULT)
		at, _ := element_center(clay.ID("DialogButton", 1))
		g.mouse_pos, g.mouse_pressed = at, true
		step = 14

	case 14:
		if d.open do return false

		// The rename, through the dialog and Esc
		still_renaming := g.rename.active && os.exists(renamed) && !os.exists(never)
		check(p, "a click on the dialog doesn't end the rename", still_renaming)
		press(sdl.K_ESCAPE)
		check(p, "Esc ends the rename", !g.rename.active && os.exists(renamed))
		refused := ODIN_OS != .Windows ||
		           (rename_path(renamed, "a:b") != "" &&
		            rename_path(renamed, "nul.txt") != "" &&
		            os.exists(renamed))
		check(p, "a name Windows can't use is refused", refused)

		// A maximized pane gives way to a pane that is focused
		ps := &g.panes
		a := ps.focused // renamed.txt
		b := pane_loaded(moved)
		pane_move(b, {kind = .Split, target = a, side = .Right})
		pane_focus(b)
		pane_toggle_maximized()
		pane_focus(a)
		restored := ps.maximized == nil && ps.focused == a
		check(p, "focusing another pane restores the maximized one", restored)
		pane_toggle_maximized()
		pane_focus_next()
		kept := ps.maximized == b && ps.focused == b
		check(p, "focusing the next pane keeps it maximized", kept)
		ps.maximized = nil
		pane_close(b, ask = false)

		// Back as it was
		g.mouse_pos = mouse
		if before != "" do open_loaded(before)
		delete(before)
		before = ""
		return true
	}
	return false
}


// The sidebar behind the panes and its search field. Two panes, one above the
// other, part across the search field. Shown: the panes start a gap right of it
// and its rows react. Hidden: it stays laid out under the panes, a rename in
// it is dropped, a press where a row was doesn't reach it, and nothing of it
// shows between the panes (read back from the window). Sliding back: rows the
// panes still cover don't react.
// A press on the field gives it the keys, typed keys list the files matching
// in place of the tree, a press on one opens it, and Escape brings the tree
// back. Each step waits for the panes to settle
@(private = "file")
phase_sidebar :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) row_at: [2]f32  // a folder's row, while shown
	@(static) before: string  // the file open before, reopened at the end
	@(static) mouse: [2]f32
	@(static) early: gfx.Rect // the search's popup as it opens
	sep := os.Path_Separator
	folder := path_in_dir(p, "sidebar_dir")
	// In a folder whose name makes its row in the search's popup wider than it
	deep := "deep_folder_with_a_name_long_enough_to_make_its_row_wider_than_the_popup"
	target := path_in_dir(p, fmt.tprintf("sidebar_dir%c%s%csidebar_target.txt", sep, deep, sep))
	below := path_in_dir(p, "sidebar_below.txt")

	if frame == 0 {
		step, mouse = 0, g.mouse_pos
		if e := focused_editor(); e != nil {
			before = strings.clone(e.path)
		}

		// A file in a folder, in the tree and the index; another to split with
		_ = os.make_directory_all(parent_dir(target))
		_ = os.write_entire_file(target, transmute([]u8)string("target\n"))
		_ = os.write_entire_file(below, transmute([]u8)string("below\n"))
		workspace_refresh(&g.workspace)
		finder_invalidate()

		g.sidebar_visible = true
		split_across_search(below)
		p.mark_frame = frame
		return false
	}
	// Step 4 looks while the panes slide back, step 6 while the popup opens
	sliding := step == 4 || step == 6
	if (g.animating && !sliding) || frame < p.mark_frame + 2 {
		return false
	}

	s := &g.sidebar_search
	sidebar, laid_out := element_rect(clay.ID("Sidebar"))
	area, _ := element_rect(clay.ID("WorkArea"))
	left := panes_left()
	switch step {
	case 0: // shown: the panes beside it, and its rows react
		edge := sidebar.x + sidebar.w + PANE_GAP
		beside := sidebar.x == 0 && left == edge && area.x == edge
		check(p, "shown: the panes start a gap right of the sidebar", beside)

		row_at, _ = element_center(tree_row_id(folder))
		g.mouse_pos = row_at
		index, on_row := tree_row_under_pointer()
		reachable := on_row && g.workspace.nodes[index].path == folder
		check(p, "shown: its rows react", reachable)

		// A rename in the tree, which hiding it drops
		rename_start_file(folder, .Tree)
		want_frame(p, sidebar)
		next_step(p, &step, frame)

	case 1: // shown: drawn where the panes part, so the hidden check means something
		lower: gfx.Rect
		if pane := pane_with_file(below); pane != nil {
			lower, _ = element_rect(pane_id(pane))
		}
		band := gfx.Rect{sidebar.x, lower.y - PANE_GAP, sidebar.w, PANE_GAP}
		check(p, "shown: the sidebar is drawn where the panes part", sidebar_ink(p, band) > 0)
		check(p, "shown: a rename in the tree stays", g.rename.active)

		g.sidebar_visible = false
		next_step(p, &step, frame)

	case 2: // hidden: still laid out, covered, and a press there doesn't reach it
		width: f32 = PANE_GAP + SIDEBAR_WIDTH
		covered := laid_out && sidebar.x == 0 && sidebar.w == width && left == PANE_GAP
		check(p, "hidden: laid out under the panes", covered)

		g.mouse_pos = row_at
		_, on_row := tree_row_under_pointer()
		check(p, "hidden: its rows don't react", !on_row)
		check(p, "hiding it drops a rename in the tree", !g.rename.active)

		want_frame(p, sidebar)
		g.mouse_pressed, g.mouse_down, g.mouse_clicks = true, true, 1
		next_step(p, &step, frame)

	case 3: // the press neither toggled the folder nor picked up a row
		g.mouse_down = false
		folder_row := folder_index(folder)
		untouched := g.pending == nil && folder_row >= 0 && !g.workspace.nodes[folder_row].expanded
		untouched = untouched && g.panes.drag.pane == nil
		check(p, "hidden: a press misses the tree", untouched)

		hidden := len(p.read_back) > 0 && sidebar_ink(p, sidebar) == 0
		check(p, "hidden: nothing of it shows between the panes", hidden)

		g.sidebar_visible = true
		next_step(p, &step, frame)

	case 4: // showing: the rows the panes still cover don't react yet
		g.mouse_pos = row_at
		_, on_row := tree_row_under_pointer()
		covered := g.sidebar_visible && area.x < row_at.x
		check(p, "showing: covered rows don't react", covered && !on_row)
		next_step(p, &step, frame)

	case 5: // press the search field
		at, _ := element_center(clay.ID("SidebarSearch"))
		g.mouse_pos, g.mouse_pressed, g.mouse_down, g.mouse_clicks = at, true, true, 1
		next_step(p, &step, frame)

	case 6: // the popup opens, growing
		g.mouse_down = false
		check(p, "a press on the field opens its popup", s.open)

		early, _ = element_rect(clay.ID("SidebarSearchPopup"))
		next_step(p, &step, frame)

	case 7: // grown out of the field, which stays in place; open files first
		if sidebar_search_busy() do return false

		popup, _ := element_rect(clay.ID("SidebarSearchPopup"))
		grew := early.h > 0 && early.h < popup.h && early.w < popup.w
		check(p, "the popup grows as it opens", grew)
		check(p, "and reaches over the panes", popup.x + popup.w > area.x)

		slot, _ := element_rect(clay.ID("SidebarSearchSlot"))
		field, _ := element_rect(clay.ID("SidebarSearch"))
		check(p, "its field is where the sidebar's was", field.x == slot.x && field.y == slot.y)

		results := s.search.results
		open_first := false
		if len(results) > 0 {
			rank, ranked, _ := search_file_rank(&s.search, results[0].index)
			open_first = ranked && rank.open
		}
		check(p, "with no query it lists the open files first", open_first)

		type_text("sidebar_target")
		next_step(p, &step, frame)

	case 8: // the files match in the popup, the tree stays; press the one found
		if sidebar_search_busy() do return false

		_, listed := element_rect(clay.ID("SidebarResults"))
		results := s.search.results
		found := listed && len(results) > 0 && same_path(g.finder.files[results[0].index], target)
		check(p, "typing lists the matching files", found)

		_, tree := element_rect(clay.ID("SidebarFiles"))
		check(p, "and the tree stays in the sidebar", tree)

		// A row wider than the popup cuts its text, and leaves the field alone
		popup, _ := element_rect(clay.ID("SidebarSearchPopup"))
		field, _ := element_rect(clay.ID("SidebarSearch"))
		clear, _ := element_rect(clay.ID("SidebarSearchClear"))
		right := popup.x + popup.w
		inside := field.x + field.w <= right && clear.x + clear.w <= right
		check(p, "a long path keeps the field and its clear button in the popup", inside)

		at, _ := element_center(search_row_id(target))
		g.mouse_pos, g.mouse_pressed, g.mouse_down, g.mouse_clicks = at, true, true, 1
		next_step(p, &step, frame)

	case 9:
		g.mouse_down = false
		next_step(p, &step, frame)

	case 10: // opened and focused; the popup closed; then Enter on a query
		e := focused_editor()
		opened := e != nil && same_path(e.path, target)
		check(p, "a press on a result opens it", opened)
		check(p, "and closes the popup", !s.open && len(s.field.text) == 0)

		if pane := pane_with_file(target); pane != nil {
			pane_close(pane, ask = false)
		}
		sidebar_search_open()
		type_text("sidebar_target")
		next_step(p, &step, frame)

	case 11: // Enter opens the first match
		if sidebar_search_busy() do return false

		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 12: // opened, and the popup closed; then Escape on a query
		e := focused_editor()
		opened := e != nil && same_path(e.path, target)
		check(p, "Enter opens the first match", opened)
		check(p, "and closes the popup", !s.open && len(s.field.text) == 0)

		// The tree selects the focused file's row, and none while a terminal is focused
		file_selected := opened && same_path(tree_selected_file(), target)
		pane_focus(perf_panes.terminal)
		none_selected := tree_selected_file() == ""
		pane_focus(pane_with_file(target))
		check(p, "the tree selects the focused file", file_selected)
		check(p, "and nothing while a terminal is focused", none_selected)

		sidebar_search_open()
		type_text("sidebar")
		press(sdl.K_ESCAPE)
		next_step(p, &step, frame)

	case 13:
		_, popup := element_rect(clay.ID("SidebarSearchPopup"))
		closed := !popup && !s.open && len(s.field.text) == 0
		check(p, "Escape empties the field and closes the popup", closed)

		// Find file opens the popup
		run_command(.Find_File)
		check(p, "Find file opens the popup", s.open && !g.finder.open)
		sidebar_search_close()

		// With the sidebar hidden, Find file opens the finder
		g.sidebar_visible = false
		run_command(.Find_File)
		check(p, "hidden, Find file opens the finder", g.finder.open)
		finder_close()
		g.sidebar_visible = true

		// Back as it was
		for path in ([]string{target, below}) {
			if pane := pane_with_file(path); pane != nil {
				pane_close(pane, ask = false)
			}
		}
		g.mouse_pos = mouse
		if before != "" do open_loaded(before)
		delete(before)
		before = ""
		return true
	}
	return false
}


// Opens a file in a pane under the focused one, the two parting across the
// sidebar's search field (as last laid out), so its edge shows between them
@(private = "file")
split_across_search :: proc(path: string) {
	above := g.panes.focused
	pane := pane_loaded(path)
	if above == nil || above == pane {
		return
	}

	work := work_rect()
	field, _ := element_rect(clay.ID("SidebarSearch"))
	gap_top := field.y + field.h / 2 - PANE_GAP / 2
	share := 1 - (gap_top - work.y) / (work.h - PANE_GAP)
	pane_move(pane, {kind = .Split, target = above, side = .Bottom, share = share})
}


// The left edge of the panes shown, as last laid out
@(private = "file")
panes_left :: proc() -> f32 {
	left := f32(g.window_w)
	for pane in g.panes.open {
		if !pane.visible do continue

		r, ok := element_rect(pane_id(pane))
		if ok do left = min(left, r.x)
	}
	return left
}


// The pixels read back (want_frame) within `area` that aren't the window's
// color, outside the panes shown and their edges
@(private = "file")
sidebar_ink :: proc(p: ^Perf, area: gfx.Rect) -> int {
	read := p.read_area
	if len(p.read_back) != int(read.w * read.h) do return 0

	// The panes as last laid out, a pixel larger for their antialiased edges
	panes := make([dynamic]gfx.Rect, context.temp_allocator)
	for pane in g.panes.open {
		r, ok := element_rect(pane_id(pane))
		if pane.visible && ok {
			append(&panes, gfx.Rect{r.x - 1, r.y - 1, r.w + 2, r.h + 2})
		}
	}

	// The pixels between them that differ from the window
	bg := gfx.theme.panel
	ink := 0
	for px, i in p.read_back {
		x := f32(int(read.x) + i % int(read.w)) / gfx.scale
		y := f32(int(read.y) + i / int(read.w)) / gfx.scale
		if !gfx.rect_contains(area, {x, y}) do continue
		if covered_by(panes[:], {x, y}) do continue

		differs := abs(int(px[0]) - int(bg.r)) > 8 ||
		           abs(int(px[1]) - int(bg.g)) > 8 ||
		           abs(int(px[2]) - int(bg.b)) > 8
		if differs do ink += 1
	}
	return ink
}


@(private = "file")
covered_by :: proc(rects: []gfx.Rect, at: [2]f32) -> bool {
	for r in rects {
		if gfx.rect_contains(r, at) do return true
	}
	return false
}


// The tree's node for a path, or -1
@(private = "file")
folder_index :: proc(path: string) -> int {
	for n, i in g.workspace.nodes {
		if same_path(n.path, path) do return i
	}
	return -1
}


// Whether what phase_menu_dialogs showed at `since` should stay up longer
@(private = "file")
menu_still_showing :: proc(since: time.Tick) -> bool {
	return time.tick_since(since) < MENU_SHOW_TIME
}


// The center of an element in last frame's layout
@(private = "file")
element_center :: proc(id: clay.ElementId) -> (c: [2]f32, ok: bool) {
	r := element_rect(id) or_return
	return {r.x + r.w / 2, r.y + r.h / 2}, true
}


// RECENT and pinned files, and the project's settings. The files used show
// under RECENT, newest first, above TERMINALS and lined up with its rows, the
// focused one drawn selected. A right-click pins one: it goes first, once, and
// is written to .typo/settings.toml in a folder made with its .gitignore. In
// Project scope the settings window lists no keybindings or user-only
// settings; a change there is the project's, written to its file, and leaves
// the user's value; Delete has it follow the user's again. A length of 0
// leaves only the pinned files, and RECENT hides with none. The scope switch
// takes the theme's colors, dark and light. Each state stays up a moment so
// the window can be looked at
@(private = "file")
phase_recent :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) since: time.Tick
	@(static) before: string // the file open before, reopened at the end
	@(static) shelved: ^Pane // a terminal on the shelf, whose row RECENT's line up with
	sep := os.Path_Separator
	files := [3]string {
		path_in_dir(p, fmt.tprintf("recent_dir%cone.txt", sep)),
		path_in_dir(p, fmt.tprintf("recent_dir%ctwo.txt", sep)),
		path_in_dir(p, fmt.tprintf("recent_dir%cthree.txt", sep)),
	}
	one, three := files[0], files[2]
	settings_path := project_file(g.project.root, PROJECT_SETTINGS)
	default_count := SETTINGS[.Recent_Files].default.(int)
	s := &g.settings
	w := &g.settings_window

	if frame == 0 {
		step = 0
		if e := focused_editor(); e != nil {
			before = strings.clone(e.path)
		}

		// Three files used, the last one focused, and a terminal on the shelf
		_ = os.make_directory_all(parent_dir(one))
		for path in files {
			_ = os.write_entire_file(path, transmute([]u8)string("recent\n"))
			open_loaded(path)
		}
		shelved = panes_add_terminal()
		g.sidebar_visible = true
		workspace_refresh(&g.workspace)
		p.mark_frame = frame
		return false
	}
	if g.animating || frame < p.mark_frame + 2 {
		return false
	}
	waited := frame - p.mark_frame

	switch step {
	case 0: // RECENT lists them above TERMINALS, lined up with its rows
		rows := recent_rows()
		newest := len(rows) >= 3 && same_path(rows[0].path, three) && same_path(rows[2].path, one)
		check(p, "RECENT lists the files used, newest first", newest)

		section, shown := element_rect(clay.ID("Recent"))
		shelf, _ := element_rect(clay.ID("Shelf"))
		check(p, "RECENT sits above TERMINALS", shown && section.y + section.h <= shelf.y)

		row, _ := element_rect(recent_row_id(three))
		terminal, _ := element_rect(clay.ID("ShelfRow", shelved.id))
		lined_up := row.x == terminal.x && row.w == terminal.w && row.h == terminal.h
		check(p, "its rows line up with the shelf's", lined_up)

		want_frame(p, row)
		next_step(p, &step, frame)

	case 1: // the focused file's row drawn selected; right-click the oldest
		selected := read_back_is(p, gfx.theme.selected)
		check(p, "the focused file's row is drawn selected", selected)

		at, _ := element_center(recent_row_id(one))
		g.mouse_pos, g.right_pressed = at, true
		next_step(p, &step, frame)

	case 2: // the menu offers Pin
		check(p, "a row's menu offers Pin", g.menu.open && g.menu.items[0].cmd == .Pin_File)
		click_element(clay.ID("MenuItem", 0))
		next_step(p, &step, frame)

	case 3: // pinned: first, with a pin, and listed once
		rows := recent_rows()
		listed := 0
		for row in rows {
			if same_path(row.path, one) do listed += 1
		}
		first := len(rows) > 0 && rows[0].pinned && same_path(rows[0].path, one)
		check(p, "Pin puts the file first, listed once", first && listed == 1)
		next_step(p, &step, frame)

	case 4: // written, once the config thread has
		written := file_has(settings_path, `"recent_dir/one.txt"`)
		if !written && waited < WRITE_WAIT_FRAMES {
			return false
		}

		check(p, "a pin is written to .typo/settings.toml", written)
		ignore := project_file(g.project.root, ".gitignore")
		check(p, "in a folder made with a .gitignore", file_has(ignore, TYPO_GITIGNORE))
		since = time.tick_now()
		next_step(p, &step, frame)

	case 5: // shown a moment; then the settings in Project scope, every section open
		if menu_still_showing(since) do return false

		set_string(&s.user.collapsed_sections, "")
		settings_resolve(s)
		settings_window_toggle()
		next_step(p, &step, frame)

	case 6:
		click_element(scope_switch_side(.Project))
		next_step(p, &step, frame)

	case 7: // only what a project may set; its recent files down to 0
		check(p, "the switch shows the project's settings", w.scope == .Project)
		check(p, "Project scope lists no keybindings", count_items(Command) == 0)
		users := false
		for item in w.items {
			x, is_setting := item.(Setting)
			users ||= is_setting && SETTINGS[x].user_only
		}
		check(p, "nor settings that are the user's only", !users)

		focus_item(Setting.Recent_Files)
		for _ in 0 ..< default_count do press(sdl.K_LEFT)
		next_step(p, &step, frame)

	case 8: // the project's value, the user's kept; only the pinned file listed
		project := .Recent_Files in s.project.set && s.recent_files == 0
		check(p, "a change in Project scope is the project's", project)
		check(p, "and leaves the user's value", s.user.recent_files == default_count)
		rows := recent_rows()
		check(p, "a length of 0 lists only the pinned files", len(rows) == 1 && rows[0].pinned)

		r, _ := element_rect(scope_switch_side(.Project))
		want_frame(p, r)
		next_step(p, &step, frame)

	case 9: // written to the project's file; the switch in the theme's colors
		written := file_has(settings_path, "recent_files = 0")
		if !written && waited < WRITE_WAIT_FRAMES {
			return false
		}

		check(p, "the project's value is written to its file", written)
		check(p, "the scope switch takes the theme's colors", read_back_is(p, gfx.theme.selected))
		since = time.tick_now()
		next_step(p, &step, frame)

	case 10: // shown a moment; then User scope
		if menu_still_showing(since) do return false

		click_element(scope_switch_side(.User))
		since = time.tick_now()
		next_step(p, &step, frame)

	case 11: // shown a moment; then both again in a light theme
		if menu_still_showing(since) do return false

		check(p, "the switch shows the user's settings", w.scope == .User)
		set_string(&s.user.theme, "typo-light")
		settings_changed()
		click_element(scope_switch_side(.Project))
		next_step(p, &step, frame)

	case 12:
		r, _ := element_rect(scope_switch_side(.Project))
		want_frame(p, r)
		next_step(p, &step, frame)

	case 13:
		light := read_back_is(p, gfx.theme.selected) && !gfx.THEMES[theme_at(s.theme)].dark
		check(p, "and in a light theme", light)
		since = time.tick_now()
		next_step(p, &step, frame)

	case 14:
		if menu_still_showing(since) do return false

		click_element(scope_switch_side(.User))
		since = time.tick_now()
		next_step(p, &step, frame)

	case 15: // back to Project scope
		if menu_still_showing(since) do return false

		click_element(scope_switch_side(.Project))
		next_step(p, &step, frame)

	case 16: // Delete there: the user's value again
		focus_item(Setting.Recent_Files)
		press(sdl.K_DELETE)
		follows := .Recent_Files not_in s.project.set && s.recent_files == default_count
		check(p, "Delete has it follow the user's setting again", follows)

		// 0 again, the window closed, and the pinned row's menu
		for _ in 0 ..< default_count do press(sdl.K_LEFT)
		settings_window_toggle()
		at, _ := element_center(recent_row_id(one))
		g.mouse_pos, g.right_pressed = at, true
		next_step(p, &step, frame)

	case 17: // the pinned file's menu offers Unpin
		unpin := g.menu.open && g.menu.items[0].cmd == .Unpin_File
		check(p, "a pinned row's menu offers Unpin", unpin)
		click_element(clay.ID("MenuItem", 0))
		next_step(p, &step, frame)

	case 18: // nothing to list: RECENT hides
		_, shown := element_rect(clay.ID("Recent"))
		check(p, "RECENT hides with nothing to list", len(recent_rows()) == 0 && !shown)

		// Back as it was: the project's settings empty, the default theme, the
		// window showing the user's settings
		settings_clear_project(s)
		project_settings_changed()
		set_string(&s.user.theme, gfx.DEFAULT_THEME)
		settings_changed()
		w.scope = .User
		next_step(p, &step, frame)

	case 19: // once the project's file is empty again
		emptied := !file_has(settings_path, "recent_files") && !file_has(settings_path, "pinned")
		if !emptied && waited < WRITE_WAIT_FRAMES {
			return false
		}

		check(p, "the project's file follows", emptied)
		for path in files {
			pane := pane_with_file(path)
			if pane != nil do pane_close(pane, ask = false)
		}
		pane_close(shelved, ask = false)
		shelved = nil
		if before != "" do open_loaded(before)
		delete(before)
		before = ""
		return true
	}
	return false
}


// How many frames phase_recent waits for the config thread to write a file
@(private = "file")
WRITE_WAIT_FRAMES :: 300


// Whether a file holds `text` (perf only: the UI thread reads it)
@(private = "file")
file_has :: proc(path, text: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && strings.contains(string(data), text)
}


// Whether the middle of the area read back (want_frame), a few pixels in from
// its left, is the color, give or take a little
@(private = "file")
read_back_is :: proc(p: ^Perf, c: clay.Color) -> bool {
	read := p.read_area
	if len(p.read_back) != int(read.w * read.h) || read.w < 8 {
		return false
	}

	x := int(3 * gfx.scale)
	y := int(read.h) / 2
	px := p.read_back[y * int(read.w) + x]
	return channel_near(px[0], c.r) && channel_near(px[1], c.g) && channel_near(px[2], c.b)
}


@(private = "file")
channel_near :: proc(a: u8, b: f32) -> bool {
	return abs(f32(a) - b) <= 6
}


// The theme's index in gfx.THEMES, or the first
@(private = "file")
theme_at :: proc(key: string) -> int {
	i, _ := gfx.theme_index(key)
	return i
}


// Move line down and up move the caret's line past the next one and back
@(private = "file")
phase_move_lines :: proc(p: ^Perf, frame: int) -> bool {
	e := focused_editor()

	third, _ := textedit.line_text(e, 3)
	fourth, _ := textedit.line_text(e, 4)
	third = strings.clone(third, context.temp_allocator)
	fourth = strings.clone(fourth, context.temp_allocator)

	start := buffer.line_start(&e.buf, 3)
	textedit.set_single_selection(e, {start, start, -1})

	run_command(.Move_Line_Down)
	now_third, _ := textedit.line_text(e, 3)
	now_fourth, _ := textedit.line_text(e, 4)
	check(p, "Move line down swaps it with the next", now_third == fourth && now_fourth == third)

	run_command(.Move_Line_Up)
	back, _ := textedit.line_text(e, 3)
	check(p, "Move line up puts it back", back == third)
	return true
}


// Opens the find bar on the focused editor, types a query and waits for every
// match; checks the count against a plain count (in files small enough to read
// whole), moves between matches, turns on match case, and closes the bar
@(private = "file")
phase_find :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) counts: [2]int // matches ignoring case and matching it; -1 when not counted
	@(static) since: time.Tick
	f := &g.find
	e := focused_editor()

	if frame == 0 {
		step = 0
		query := perf_find_query(e)
		counts = perf_find_counts(e, query)

		textedit.set_single_selection(e, {0, 0, -1})
		check(p, "Find opens the bar", run_command(.Find) && f.open && f.typing)

		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = strings.clone_to_cstring(query, context.temp_allocator)
		handle_key_event(&event)
		return false
	}

	switch step {
	case 0: // the whole document searched
		if !f.done && frame < 600 {
			return false
		}

		check(p, "the search finishes", f.done)
		if counts[0] >= 0 {
			check(p, "every match is found", len(f.matches) == counts[0])
		}
		check(p, "matches are marked", len(e.marks) == len(f.matches))
		if len(f.matches) > 0 {
			m := f.matches[max(f.current, 0)]
			s := e.sels[e.primary]
			check(p, "a match is selected", f.current >= 0 && s.anchor == m[0] && s.head == m[1])
		}
		step, since = 1, time.tick_now()

	case 1: // a moment to see the bar, then between matches
		if time.tick_since(since) < 600 * time.Millisecond do return false

		if len(f.matches) > 1 {
			first := f.current
			press(sdl.K_RETURN)
			went_on := f.current == (first + 1) % len(f.matches)
			run_command(.Find_Previous)
			check(p, "Enter and Find previous move between matches", went_on && f.current == first)
		}
		run_command(.Find_Match_Case)
		step = 2

	case 2: // match case searches again
		if f.searched != f.options || !f.done {
			return false
		}

		if counts[1] >= 0 {
			check(p, "match case finds fewer", len(f.matches) == counts[1])
		}
		run_command(.Find_Match_Case)
		press(sdl.K_ESCAPE)
		check(p, "Escape closes the bar", !f.open && e.marks == nil)
		return true
	}
	return false
}


// What each find phase searches for: a common word, or in the 64 MB file one
// that isn't there, so the whole file is read
@(private = "file")
perf_find_query :: proc(e: ^Editor) -> string {
	switch {
	case strings.has_suffix(e.path, "notes.md"):   return "the"
	case strings.has_suffix(e.path, "large.odin"): return "quokka"
	}
	return "proc"
}


// The matches a plain count finds ignoring ASCII case and matching it, or -1s
// for a file too big to read whole in a frame
@(private = "file")
perf_find_counts :: proc(e: ^Editor, query: string) -> [2]int {
	length := buffer.length(&e.buf)
	if length > 8 << 20 do return {-1, -1}

	text := string(buffer.read_alloc(&e.buf, 0, length))
	lower := strings.to_lower(text, context.temp_allocator)
	return {strings.count(lower, query), strings.count(text, query)}
}


// Finds in the terminal after the 4 MB of output: matches through the
// scrollback, the newest selected, the ones in view marked, then older ones
@(private = "file")
phase_find_terminal :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	f := &g.find
	t := focused_terminal()

	if frame == 0 {
		opened := run_command(.Find) && f.open && f.pane.content == Pane_Content(t)
		check(p, "Find opens the bar on the terminal", opened)

		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "lazy dog"
		handle_key_event(&event)
		since = time.tick_now()
		return false
	}

	// Until the scrollback is searched, and a moment to see it
	total, current, complete := find_term_counts(f)
	waited := time.tick_since(since)
	if !complete && waited < 20 * time.Second {
		return false
	}
	if waited < 600 * time.Millisecond do return false

	check(p, "matches are found in the scrollback", complete && total > 1)
	check(p, "the newest match is selected", current == 0)
	check(p, "matches in view are marked", len(t.marks) > 0)

	run_command(.Find_Next)
	_, next, _ := find_term_counts(f)
	check(p, "Find next goes to an older match", next == 1)

	press(sdl.K_ESCAPE)
	check(p, "Escape closes the bar", !f.open && len(t.marks) == 0)

	// Toggle sidebar's chord goes to the shell until it is set to work in terminals
	sidebar := g.sidebar_visible
	press_chord(.B, sdl.KMOD_LCTRL)
	shell := g.sidebar_visible == sidebar && focused_terminal() == t
	check(p, "a command not set for terminals leaves its chord to the shell", shell)

	// cmd.exe typed it as ^B, which the next phases' commands would start with
	press_chord(.BACKSPACE, {})

	// Set directly: settings_changed would resolve the settings again, dropping the
	// shell phase_terminal_redraw put in g.settings for the phases after this one
	g.settings.terminal_commands += {.Toggle_Sidebar}
	press_chord(.B, sdl.KMOD_LCTRL)
	check(p, "set to work in terminals, it runs there", g.sidebar_visible != sidebar)
	g.settings.terminal_commands -= {.Toggle_Sidebar}
	g.sidebar_visible = sidebar
	return true
}


// Presses in the text with the caret at the start, holds the button, drags,
// and lets go: the caret moves and shows on the press itself, hides while
// dragging, and shows again on release
@(private = "file")
phase_click_caret :: proc(p: ^Perf, frame: int) -> bool {
	@(static) mouse: [2]f32
	e := focused_editor()

	switch frame {
	case 0:
		mouse = g.mouse_pos
		textedit.set_single_selection(e, {0, 0, -1})
		g.mouse_pos = {e.view.x + e.view.w * 0.4, e.view.y + e.view.h * 0.4}
		g.mouse_down, g.mouse_pressed, g.mouse_clicks = true, true, 1

	case 1:
		shown_moved := e.sels[e.primary].head != 0 && editor_caret_on(e)
		check(p, "a press moves the caret and shows it", shown_moved)
		g.mouse_pos += {40, 30}

	case 2:
		check(p, "dragging hides the caret", !editor_caret_on(e))
		g.mouse_down = false

	case 3:
		check(p, "letting go shows it again", editor_caret_on(e))
		g.mouse_pos = mouse
		return true
	}
	return false
}


// A key press, as if typed
@(private = "file")
press :: proc(key: sdl.Keycode) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	handle_key_event(&event)
}


// A shortcut pressed, with the scancode chords match on
@(private = "file")
press_chord :: proc(scancode: sdl.Scancode, mod: sdl.Keymod) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.key = sdl.GetKeyFromScancode(scancode, {}, true)
	event.key.mod = mod
	handle_key_event(&event)
}


// Opens the settings window and focuses a setting's row (a frame later, once
// the rows exist). Returns true once focused
@(private = "file")
open_settings_at :: proc(x: Setting, frame: int) -> bool {
	w := &g.settings_window
	if frame == 0 {
		settings_window_toggle()
		return false
	}

	for item, i in w.items {
		s, is_setting := item.(Setting)
		if is_setting && s == x {
			w.focus = i
		}
	}
	return true
}


// Opens the theme list, switches to the light themes and moves down through
// them, switches back and moves up through the dark ones (each theme applied as
// it is selected), then cancels back to the settings and closes them
@(private = "file")
phase_theme_picker :: proc(p: ^Perf, frame: int) -> bool {
	w := &g.settings_window

	// How many of each, and the ends of the walk
	darks, lights: int
	first_dark, last_light: string
	for spec in gfx.THEMES {
		if spec.dark {
			if darks == 0 do first_dark = spec.key
			darks += 1
		} else {
			last_light = spec.key
			lights += 1
		}
	}

	step := frame - 2
	switch {
	case frame <= 1:
		if open_settings_at(.Theme, frame) do press(sdl.K_RETURN)

	case step == 0:
		press(sdl.K_RIGHT)

	case step < lights:
		press(sdl.K_DOWN)

	case step == lights:
		check(p, "steps through the light themes", g.settings.theme == last_light)
		press(sdl.K_LEFT)

	case step < lights + darks:
		press(sdl.K_UP)

	case step == lights + darks:
		check(p, "steps through the dark themes", g.settings.theme == first_dark)
		press(sdl.K_ESCAPE)

	case g.animating:

	case:
		restored := g.settings.theme == gfx.DEFAULT_THEME &&
		            gfx.theme == gfx.theme_by_name(gfx.DEFAULT_THEME)
		check(p, "Esc restores the theme", restored)
		settings_window_toggle()
		return !w.open
	}
	return false
}


// Opens the font list, waits for the installed fonts, moves through up to 12
// of them (each loaded as it is selected), then cancels
@(private = "file")
phase_font_picker :: proc(p: ^Perf, frame: int) -> bool {
	STEPS :: 12

	switch {
	case frame <= 1:
		p.mark_frame = 0
		if open_settings_at(.Font_Family, frame) do press(sdl.K_RETURN)

	case gfx.fonts_scanning(&g.fonts):
		if time.tick_since(p.phase_t0) < 30 * time.Second do return false
		check(p, "finds installed fonts", false)
		return true

	case p.mark_frame <= 0:
		result(p, "find installed fonts", g.fonts.scan_ms, "ms", 3000)
		result(p, "installed monospace families", f64(len(g.fonts.families)), "")
		p.mark_frame = frame
		clear(&p.frames)

	case frame < p.mark_frame + min(STEPS, len(g.fonts.families)):
		press(sdl.K_DOWN)

	case frame == p.mark_frame + min(STEPS, len(g.fonts.families)):
		press(sdl.K_ESCAPE)

	case g.animating:

	case:
		check(p, "Esc restores the font", g.settings.font_family == gfx.BUNDLED_FAMILY)
		settings_window_toggle()
		return true
	}
	return false
}


// Each character is drawn on its own with letter spacing
@(private = "file")
phase_letter_spacing :: proc(p: ^Perf, frame: int) -> bool {
	switch frame {
	case 0:
		g.settings.letter_spacing = 1
		textedit.move(focused_editor(), .Doc_Start, false)
	case 120:
		g.settings.letter_spacing = 0
		return true
	case:
		textedit.move(focused_editor(), .Page_Down, false)
	}
	return false
}


// Jumps to 120 places spread over the file, one per frame
@(private = "file")
phase_jump_large :: proc(p: ^Perf, frame: int) -> bool {
	@(static) worst: f64
	if frame == 0 do worst = 0

	e := focused_editor()
	textedit.scroll_to(e, max_scroll_y(e) * f64(frame) / 120)
	worst = max(worst, measure_view_ms(e))

	if frame < 120 do return false
	result(p, "measuring the lines in view, worst", worst, "ms", 0.5)
	return true
}


@(private = "file")
phase_long_line :: proc(p: ^Perf, frame: int) -> bool {
	@(static) worst: f64
	if frame == 0 {
		worst = 0
		open_timed(p, "long.js")
		return false
	}

	e := focused_editor()
	switch frame {
	case 1:
		textedit.move(e, .Doc_End, false)
	case:
		editor_text_input(e, "x")
	}

	worst = max(worst, measure_view_ms(e))
	if frame < 60 do return false

	result(p, "measuring the lines in view, worst", worst, "ms", 5)
	return true
}


// The time the text view takes to measure the lines in view for its sideways
// scrolling (which a frame does when they or the document changed), timed on
// its own. The frame measures them again, so its time includes it too
@(private = "file")
measure_view_ms :: proc(e: ^Editor) -> f64 {
	e.widest.first = -1
	defer e.widest.first = -1

	start := time.tick_now()
	measure_view(e)
	return ms_since(start)
}


@(private = "file")
phase_terminal_redraw :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 {
		when ODIN_OS == .Windows {
			set_string(&g.settings.terminal_shell, "cmd.exe /q /k prompt $G")
		} else {
			set_string(&g.settings.terminal_shell, "/bin/sh")
		}
		terminal_toggle()
		pane_toggle_maximized()
		return false
	}

	// Repaint every cell in a new color each frame, like a full-screen program
	t := focused_terminal()
	s := &t.session
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "\x1b[H")
	for row in 0 ..< int(s.rows) {
		fmt.sbprintf(&sb, "\x1b[%d;1H", row + 1)
		for col in 0 ..< int(s.cols) {
			color := (frame + row + col) % 256
			letter := 'a' + rune((frame + col) % 26)
			fmt.sbprintf(&sb, "\x1b[38;5;%dm%c", color, letter)
		}
	}
	strings.write_string(&sb, "\x1b[0m")

	term.terminal_vt_write(s.vt, raw_data(sb.buf), len(sb.buf))
	return frame == 120
}


// Rows of block elements and a box, from the terminal's top left
@(private = "file")
BOX_GLYPH_ROWS :: [?]string {
	"██████████",
	"▀▄▀▄▀▄▀▄",
	"╭──╮",
	"│  │",
	"│  │",
	"╰──╯",
}


@(private = "file")
perf_box: struct {
	stage:       enum {
		Terminal_Settling,
		Terminal_Drawn,
		Editor_Settling,
		Restoring,
	},
	font_size:   int,
	font_weight: int,
	line_height: f64,
	parsed:      u64, // shell output parsed when it was last seen changing
	quiet_since: int, // frame
	terminal:    ^Pane,
	file:        ^Pane,
}


// Block elements and box drawing at the user's font settings (the bundled IBM
// Plex Mono at 16, weight 300, line height 1.4: the font's advance has a
// fraction and its glyphs don't reach the row's height), drawn in the terminal
// and in an editor and read back from the window. Full blocks leave no seams
// and fill their rows, half blocks fill their halves, and a box's lines join
// across cells and rows
@(private = "file")
phase_box_glyphs :: proc(p: ^Perf, frame: int) -> bool {
	pb := &perf_box
	path := path_in_dir(p, "blocks.txt")

	if frame == 0 {
		pb.font_size, pb.font_weight = g.settings.font_size, g.settings.font_weight
		pb.line_height = g.settings.line_height
		g.settings.font_size = 16
		g.settings.font_weight = 300
		g.settings.line_height = 1.4
		apply_editor_font()

		lines := BOX_GLYPH_ROWS
		rows := strings.join(lines[:], "\n", context.temp_allocator)
		_ = os.write_entire_file(path, transmute([]u8)rows)

		pb.stage = .Terminal_Settling
		pb.terminal = g.panes.focused
		pb.parsed, pb.quiet_since = focused_terminal().session.parsed, 0
		return false
	}

	switch pb.stage {
	case .Terminal_Settling:
		// Once the grid has its new size and the shell has stopped repainting it
		s := &focused_terminal().session
		if s.parsed != pb.parsed || g.animating {
			pb.parsed, pb.quiet_since = s.parsed, frame
		}
		if frame - pb.quiet_since < 30 do return false

		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "\x1b[0m\x1b[2J")
		for line, row in BOX_GLYPH_ROWS {
			fmt.sbprintf(&sb, "\x1b[%d;1H%s", row + 1, line)
		}
		term.terminal_vt_write(s.vt, raw_data(sb.buf), len(sb.buf))
		pb.stage = .Terminal_Drawn

	case .Terminal_Drawn:
		check_terminal_box_glyphs(p, focused_terminal())

		// The same rows in a file, the caret after them
		pb.file = open_loaded(path)
		pane_focus(pb.file)
		textedit.move(focused_editor(), .Doc_End, false)
		pb.quiet_since = frame
		pb.stage = .Editor_Settling

	case .Editor_Settling:
		e := focused_editor()
		if g.animating || e == nil || !e.shown {
			pb.quiet_since = frame
		}
		if frame - pb.quiet_since < 10 do return false

		check_editor_box_glyphs(p, e)

		// Back to the terminal, maximized, at the suite's font settings
		pane_close(pb.file, ask = false)
		pane_focus(pb.terminal)
		if g.panes.maximized != pb.terminal do pane_toggle_maximized()

		g.settings.font_size, g.settings.font_weight = pb.font_size, pb.font_weight
		g.settings.line_height = pb.line_height
		apply_editor_font()
		pb.quiet_since = frame
		pb.stage = .Restoring

	case .Restoring:
		// Done once the terminal is back in place, at its full size
		if g.animating do pb.quiet_since = frame
		return frame - pb.quiet_since >= 10
	}
	return false
}


// Cells as draw_terminal or an editor places them, and what was read back over
// them (pixels, the window's)
@(private = "file")
Cell_Probe :: struct {
	ox, oy, adv, lh: f32,
	area:            sdl.Rect,
	pixels:          [][4]u8,
	fg:              clay.Color, // what the glyphs are drawn in
}


// Draws the terminal (showing BOX_GLYPH_ROWS) over its background and checks
// the rows' cells
@(private = "file")
check_terminal_box_glyphs :: proc(p: ^Perf, t: ^Terminal) {
	scale := gfx.scale
	fg, bg := t.colors.foreground, t.colors.background
	pr := Cell_Probe {
		ox  = t.view.x * scale,
		oy  = t.view.y * scale,
		adv = t.cell_w * scale,
		lh  = t.cell_h * scale,
		fg  = {f32(fg.r), f32(fg.g), f32(fg.b), 255},
	}
	pr.area = probe_area(pr)

	fill_area(pr.area, {f32(bg.r), f32(bg.g), f32(bg.b), 255})
	out_w, out_h: i32
	_ = sdl.GetCurrentRenderOutputSize(gfx.renderer, &out_w, &out_h)
	draw_terminal(t, {0, 0, f32(out_w), f32(out_h)}, scale)

	check_box_cells(p, &pr, "terminal")
}


// Draws an editor showing BOX_GLYPH_ROWS, scrolled to the top, over its
// background and checks the rows' cells
@(private = "file")
check_editor_box_glyphs :: proc(p: ^Perf, e: ^Editor) {
	scale := gfx.scale
	b := clay.BoundingBox{e.view.x * scale, e.view.y * scale, e.view.w * scale, e.view.h * scale}

	// As the text view places its columns and lines
	gutter := math.round(e.gutter_w * scale)
	pr := Cell_Probe {
		ox  = b.x + gutter + TEXT_MARGIN * scale - e.scroll_x * scale,
		oy  = b.y,
		adv = e.char_w * scale,
		lh  = f32(text_line_height(e)) * scale,
		fg  = gfx.theme.syntax[.None],
	}
	pr.area = probe_area(pr)

	fill_area(pr.area, gfx.theme.bg)
	draw_editor(e, b, scale)

	check_box_cells(p, &pr, "editor")
}


// The pixels of BOX_GLYPH_ROWS' cells, two columns wider
@(private = "file")
probe_area :: proc(pr: Cell_Probe) -> sdl.Rect {
	left, top := probe_x(pr, 0), probe_y(pr, 0)
	right, bottom := probe_x(pr, 12), probe_y(pr, len(BOX_GLYPH_ROWS))
	return {i32(left), i32(top), i32(right - left), i32(bottom - top)}
}


@(private = "file")
fill_area :: proc(area: sdl.Rect, c: clay.Color) {
	gfx.fill_rect(f32(area.x), f32(area.y), f32(area.w), f32(area.h), c)
}


// Reads back the cells drawn and checks BOX_GLYPH_ROWS in them
@(private = "file")
check_box_cells :: proc(p: ^Perf, pr: ^Cell_Probe, what: string) {
	ok: bool
	pr.pixels, ok = read_window(pr.area)
	check(p, fmt.tprintf("%s: read back", what), ok)
	if !ok do return

	full := full_blocks_filled(pr^, 0)
	halves := half_blocks_filled(pr^, 1)
	box := box_joined(pr^, 2, 5)
	check(p, fmt.tprintf("%s: full blocks leave no seams, fill the row", what), full)
	check(p, fmt.tprintf("%s: half blocks fill their halves", what), halves)
	check(p, fmt.tprintf("%s: a box's lines join across cells and rows", what), box)
}


// Whether the row's ten full blocks light every pixel of their cells
@(private = "file")
full_blocks_filled :: proc(pr: Cell_Probe, row: int) -> bool {
	for y in probe_y(pr, row) ..< probe_y(pr, row + 1) {
		for x in probe_x(pr, 0) ..< probe_x(pr, 10) {
			if !probe_lit(pr, x, y) do return false
		}
	}
	return true
}


// Whether the row's eight half blocks (upper, lower, ...) light the upper or
// lower part of every pixel column, all the same part, the two adding up to
// the row
@(private = "file")
half_blocks_filled :: proc(pr: Cell_Probe, row: int) -> bool {
	top, bottom := probe_y(pr, row), probe_y(pr, row + 1)
	upper_rows := -1

	for col in 0 ..< 8 {
		upper := col % 2 == 0
		for x in probe_x(pr, col) ..< probe_x(pr, col + 1) {
			lit := 0
			for y in top ..< bottom {
				if probe_lit(pr, x, y) do lit += 1
			}
			if lit == 0 do return false

			// Lit from the top (upper) or from the bottom (lower), nowhere else
			for y in top ..< bottom {
				want := upper ? y < top + lit : y >= bottom - lit
				if probe_lit(pr, x, y) != want do return false
			}

			above := upper ? lit : bottom - top - lit
			if upper_rows < 0 do upper_rows = above
			if above != upper_rows do return false
		}
	}
	return true
}


// Whether the box from row `top` to row `bottom` (columns 0 to 3) has sides
// unbroken from the end of its top corners' arcs to the start of its bottom
// corners', across the rows between, and its top likewise from corner to corner
@(private = "file")
box_joined :: proc(pr: Cell_Probe, top, bottom: int) -> bool {
	// Into the corners' cells: their arcs are straight by their last pixel
	INTO_CORNER :: 1

	// The sides, at the pixel column where │ is lit in the row below the corners
	for col in ([]int{0, 3}) {
		side := -1
		y_side := probe_mid_y(pr, top + 1)
		for x in probe_x(pr, col) ..< probe_x(pr, col + 1) {
			if probe_lit(pr, x, y_side) {
				side = x
				break
			}
		}
		if side < 0 do return false

		from := probe_y(pr, top + 1) - INTO_CORNER
		to := probe_y(pr, bottom) + INTO_CORNER
		for y in from ..< to {
			if !probe_lit(pr, side, y) do return false
		}
	}

	// The top, at the pixel row where ─ is lit
	edge := -1
	x_edge := probe_mid_x(pr, 1)
	for y in probe_y(pr, top) ..< probe_y(pr, top + 1) {
		if probe_lit(pr, x_edge, y) {
			edge = y
			break
		}
	}
	if edge < 0 do return false

	for x in probe_x(pr, 1) - INTO_CORNER ..< probe_x(pr, 3) + INTO_CORNER {
		if !probe_lit(pr, x, edge) do return false
	}
	return true
}


// A column's left edge and a row's top, and their middles, in window pixels
@(private = "file")
probe_x :: proc(pr: Cell_Probe, col: int) -> int {
	return int(math.round(pr.ox + f32(col) * pr.adv))
}


@(private = "file")
probe_y :: proc(pr: Cell_Probe, row: int) -> int {
	return int(math.round(pr.oy + f32(row) * pr.lh))
}


@(private = "file")
probe_mid_x :: proc(pr: Cell_Probe, col: int) -> int {
	return int(math.round(pr.ox + (f32(col) + 0.5) * pr.adv))
}


@(private = "file")
probe_mid_y :: proc(pr: Cell_Probe, row: int) -> int {
	return int(math.round(pr.oy + (f32(row) + 0.5) * pr.lh))
}


// Whether a window pixel read back shows the glyphs' color
@(private = "file")
probe_lit :: proc(pr: Cell_Probe, x, y: int) -> bool {
	px := pr.pixels[(y - int(pr.area.y)) * int(pr.area.w) + (x - int(pr.area.x))]
	for channel in 0 ..< 3 {
		if abs(int(px[channel]) - int(pr.fg[channel])) > 3 do return false
	}
	return true
}


// Repaints every cell with block elements and box drawing in a new color each
// frame, like a full-screen program drawing with them
@(private = "file")
phase_terminal_blocks :: proc(p: ^Perf, frame: int) -> bool {
	glyphs := []rune{'█', '▀', '▄', '▌', '▐', '░', '▒', '▓', '▛', '▟', '─', '│', '┼', '╭', '╯'}

	s := &focused_terminal().session
	sb := strings.builder_make(context.temp_allocator)
	for row in 0 ..< int(s.rows) {
		fmt.sbprintf(&sb, "\x1b[%d;1H", row + 1)
		for col in 0 ..< int(s.cols) {
			color := (frame + row + col) % 256
			glyph := glyphs[(frame + row + col) % len(glyphs)]
			fmt.sbprintf(&sb, "\x1b[38;5;%dm%c", color, glyph)
		}
	}
	strings.write_string(&sb, "\x1b[0m")

	term.terminal_vt_write(s.vt, raw_data(sb.buf), len(sb.buf))
	return frame == 120
}


// Runs a command that prints a 4 MB file through the real shell and pty, and
// waits until the output has stopped for a second
@(private = "file")
phase_terminal_output :: proc(p: ^Perf, frame: int) -> bool {
	s := &focused_terminal().session
	if frame == 0 {
		when ODIN_OS == .Windows {
			command := "cls & type flood.txt\r"
		} else {
			command := "clear; cat flood.txt\n"
		}
		term.session_input(s, transmute([]u8)command)
		p.flood_parsed, p.flood_last = s.parsed, time.tick_now()
		return false
	}

	if s.parsed != p.flood_parsed {
		p.flood_parsed, p.flood_last = s.parsed, time.tick_now()
	}
	quiet := time.tick_since(p.flood_last) > time.Second
	timeout := time.tick_since(p.phase_t0) > 60 * time.Second
	if !quiet && !timeout {
		return false
	}

	secs := time.duration_seconds(time.tick_diff(p.phase_t0, p.flood_last))
	result(p, "time until output stops", secs * 1000, "ms", 10_000)
	result(p, "throughput", 4 / secs, "MB/s")
	return true
}


// Code and Markdown side by side above the terminal; types in the code once
// the panes have settled
@(private = "file")
phase_panes_typing :: proc(p: ^Perf, frame: int) -> bool {
	ps := &g.panes
	if frame == 0 {
		// The panes
		ps.maximized = nil
		perf_panes.terminal = ps.focused
		close_files()
		perf_panes.code = open_loaded(path_in_dir(p, "code.odin"))
		perf_panes.notes = pane_loaded(path_in_dir(p, "notes.md"))
		pane_move(perf_panes.notes, {kind = .Split, target = perf_panes.code, side = .Right})
		pane_focus(perf_panes.code)

		// The caret in the middle of the code
		e := focused_editor()
		textedit.show_caret(e, true)
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		textedit.set_single_selection(e, {mid, mid, -1})
		e.reveal = true
		p.mark_frame = -1
		return false
	}

	// Frames count from when the panes have settled
	if p.mark_frame < 0 {
		if g.animating do return false
		p.mark_frame = frame
		clear(&p.frames)
	}

	text := "the quick brown fox "
	editor_text_input(focused_editor(), text[frame % len(text):][:1])
	return frame == p.mark_frame + 120
}


@(private = "file")
perf_panes: struct {
	code, notes, terminal: ^Pane,
	step:                  int,
	animated:              int, // steps that animated
}


// Moves the panes of phase_panes_typing, each move once the last has settled:
// the terminal docks at the right, the sidebar hides and comes back, the files
// swap, one is maximized and restored, one leaves the layout and comes back,
// and the focus moves
@(private = "file")
phase_panes_moving :: proc(p: ^Perf, frame: int) -> bool {
	pp := &perf_panes
	if frame == 0 {
		pp.step, pp.animated = 0, 0
		p.mark_frame = 0
		return false
	}
	if g.animating {
		if frame == p.mark_frame + 1 do pp.animated += 1
		return false
	}

	STEPS :: 9
	switch pp.step {
	case 0: pane_move(pp.terminal, {kind = .Edge, side = .Right, share = 0.3})
	case 1: g.sidebar_visible = false
	case 2: g.sidebar_visible = true
	case 3: pane_move(pp.code, {kind = .Swap, target = pp.notes})
	case 4:
		pane_focus(pp.code)
		pane_toggle_maximized()
	case 5: pane_toggle_maximized()
	case 6: pane_hide(pp.notes)
	case 7: pane_move(pp.notes, {kind = .Split, target = pp.code, side = .Right})
	case 8: pane_focus(pp.terminal)
	case STEPS:
		all_shown := pane_shown(pp.code) && pane_shown(pp.notes) && pane_shown(pp.terminal)
		check(p, "three panes shown", all_shown)
		check(p, "every move animates", pp.animated == STEPS)
		return true
	}

	pp.step += 1
	p.mark_frame = frame
	return false
}


// On the files of phase_panes_typing: the maximize button shows only while it
// does something, the title's tooltip appears at the pointer, and the mouse's
// back button goes back in the pane under the pointer. Each step waits for the
// panes to settle
@(private = "file")
phase_pane_header :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) mouse: [2]f32
	@(static) caret: int
	@(static) since: time.Tick

	pp := &perf_panes
	ps := &g.panes
	if frame == 0 {
		step = 0
		mouse = g.mouse_pos
		ps.maximized = nil
		pane_hide(pp.terminal)
		pane_focus(pp.code)
		p.mark_frame = frame
		return false
	}

	// Settled: no transition for a few frames, nothing waiting to open
	if g.animating || g.pending != nil {
		p.mark_frame = frame
		return false
	}
	if frame < p.mark_frame + 3 do return false

	e := pp.code.content.(^Editor)
	_, maximize_shown := element_rect(clay.ID("PaneMaximize", pp.code.id))
	switch step {
	case 0:
		beside := maximize_shown && pane_fill(pp.code) == .Shared
		check(p, "beside another pane: Maximize", beside)
		pane_toggle_maximized()

	case 1:
		over := maximize_shown && pane_fill(pp.code) == .Maximized
		check(p, "maximized over others: Restore", over)
		pane_toggle_maximized()
		pane_hide(pp.notes)

	case 2:
		pane_toggle_maximized()
		alone := !maximize_shown && ps.maximized == nil
		check(p, "the only pane: no button, no maximizing", alone)
		pane_move(pp.notes, {kind = .Split, target = pp.code, side = .Right})

	case 3:
		check(p, "with a second pane: Maximize again", maximize_shown)

		// The pointer rests on the code's title, right of its middle
		title, _ := element_rect(clay.ID("PaneTitle", pp.code.id))
		g.mouse_pos = {title.x + title.w * 0.7, title.y + title.h / 2}
		since = time.tick_now()

	case 4: // the tip placed (its first frame lays it out out of sight)
		tip, tip_shown := element_rect(clay.ID("Tooltip"))
		tip_shown &= g.tooltip.placed
		if !tip_shown && time.tick_since(since) < 2 * time.Second {
			return false
		}
		d := [2]f32{tip.x, tip.y} - g.mouse_pos
		near := tip_shown && abs(d.x) < 30 && d.y > 0 && d.y < 40
		check(p, "the title's tooltip is at the pointer", near)

		// A jump in the code
		caret = e.sels[e.primary].head
		target := buffer.line_start(&e.buf, 5)
		jump_to(e.path, target)

	case 5:
		check(p, "the jump moved the caret", e.sels[e.primary].head != caret)

		// The back button over the code, while the notes have the keys
		pane_focus(pp.notes)
		body, _ := element_rect(clay.ID("PaneBody", pp.code.id))
		press_mouse_button(sdl.BUTTON_X1, {body.x + body.w / 2, body.y + body.h / 2})

	case 6:
		back := ps.focused == pp.code && e.sels[e.primary].head == caret
		check(p, "Mouse4 goes back in the pane under it", back)

		// Back as it was
		g.mouse_pos = mouse
		pane_move(pp.terminal, {kind = .Edge, side = .Right, share = 0.3})
		pane_focus(pp.terminal)
		return true
	}

	step += 1
	p.mark_frame = frame
	return false
}


// --- Text fields -------------------------------------------------------------------

@(private = "file")
PERF_FIND_QUERY :: "the quick brown fox jumps over the lazy dog, again and again"

@(private = "file")
PERF_SEARCH :: "font size"


// The find bar's field on the code of phase_panes_typing: Ctrl+A selects the
// field's text and not the editor's; a press places the caret where the text
// is measured, dragging selects and past the end scrolls the text, a double
// press selects a word. Once another pane is focused, Enter goes to it; a press
// on the field takes the keys back; Find next in another pane moves the bar
// there. Then a press and a drag in the settings search, and Ctrl+A in the
// finder
@(private = "file")
phase_text_fields :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	pp := &perf_panes
	f := &g.find
	field := clay.ID("FindField")

	if frame == 0 {
		g.panes.maximized = nil
		pane_focus(pp.code)
		e := focused_editor()
		textedit.set_single_selection(e, {0, 0, -1})
		check(p, "Find opens on the code", run_command(.Find) && f.pane == pp.code)

		type_text(PERF_FIND_QUERY)
		press(sdl.K_HOME)
		step, p.mark_frame = 1, frame
		return false
	}

	waited := frame - p.mark_frame
	code := pp.code.content.(^Editor)
	notes := pp.notes.content.(^Editor)

	switch step {
	case 1: // Ctrl+A in the field
		if g.animating || waited < 2 {
			return false
		}

		before := code.sels[code.primary]
		press_chord(.A, sdl.KMOD_LCTRL)
		all := f.edit.anchor == 0 && f.edit.caret == len(PERF_FIND_QUERY)
		alone := len(code.sels) == 1 && code.sels[code.primary] == before
		check(p, "Ctrl+A in the find field selects its text", all)
		check(p, "Ctrl+A in the find field leaves the editor's selection", alone)
		press(sdl.K_HOME)

		// A space moves the caret, even last (the text's inked extent doesn't grow)
		after_quick := field_x(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY, 9)
		after_space := field_x(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY[:10], 10)
		check(p, "a caret after a space is right of it", after_space > after_quick + 1)
		next_step(p, &step, frame)

	case 2: // a press after "quick", once the text scrolled back
		if waited < 2 do return false

		press_field(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY, 9, clicks = 1)
		next_step(p, &step, frame)

	case 3: // then a drag to after "brown"
		placed := f.edit.anchor == 9 && f.edit.caret == 9
		check(p, "a press in the find field places the caret", placed && find_has_keys())
		g.mouse_pos.x = field_x(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY, 15)
		next_step(p, &step, frame)

	case 4: // and on past the field's end
		check(p, "dragging in the find field selects", f.edit.anchor == 9 && f.edit.caret == 15)
		r, _ := element_rect(field)
		g.mouse_pos.x = r.x + r.w + 40
		next_step(p, &step, frame)

	case 5:
		if waited < 20 do return false

		scrolled := f.edit.scroll > 0 && f.edit.caret > 15 && f.edit.anchor == 9
		check(p, "dragging past the find field's end scrolls its text", scrolled)
		g.mouse_down = false
		press(sdl.K_HOME)
		next_step(p, &step, frame)

	case 6: // a double press on "brown"
		if waited < 2 do return false

		press_field(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY, 12, clicks = 2)
		next_step(p, &step, frame)

	case 7:
		check(p, "a double press selects a word", f.edit.anchor == 10 && f.edit.caret == 15)
		g.mouse_down = false
		next_step(p, &step, frame)

	case 8: // a press in the notes
		g.mouse_pos = {notes.view.x + notes.view.w / 2, notes.view.y + notes.view.h / 2}
		g.mouse_pressed, g.mouse_down, g.mouse_clicks = true, true, 1
		next_step(p, &step, frame)

	case 9: // Enter goes to the notes, not the field
		g.mouse_down = false
		check(p, "focusing another pane takes the keys from the find field", !find_has_keys())

		length := buffer.length(&notes.buf)
		current := f.current
		press(sdl.K_RETURN)
		went := buffer.length(&notes.buf) > length && f.current == current
		check(p, "Enter goes to the pane focused after the find field", went)
		run_command(.Undo)
		next_step(p, &step, frame)

	case 10: // a press on the field
		press_field(field, 6, FONT_SIZE_SMALL, PERF_FIND_QUERY, 4, clicks = 1)
		next_step(p, &step, frame)

	case 11: // took the keys back, and reached nothing under the bar
		back := find_has_keys() && g.panes.focused == pp.code && f.edit.caret == 4
		check(p, "a press on the find field gives it the keys again", back)
		check(p, "a press on the find bar reaches nothing under it", g.panes.drag.pane == nil)
		g.mouse_down = false

		pane_focus(pp.notes)
		run_command(.Find_Next)
		check(p, "Find next in another pane moves the bar there", f.pane == pp.notes)
		press(sdl.K_ESCAPE)
		check(p, "Escape closes the bar", !f.open)

		settings_window_toggle()
		type_text(PERF_SEARCH)
		press(sdl.K_HOME)
		next_step(p, &step, frame)

	case 12: // a press in the settings search after "font"
		if g.animating || waited < 2 {
			return false
		}

		search := clay.ID("SettingsSearch")
		press_field(search, 10, FONT_SIZE_UI, PERF_SEARCH, 4, clicks = 1)
		next_step(p, &step, frame)

	case 13: // and a drag to its end
		w := &g.settings_window
		placed := w.search.anchor == 4 && w.search.caret == 4 && w.focus < 0
		check(p, "a press in the settings search places the caret", placed)
		search := clay.ID("SettingsSearch")
		g.mouse_pos.x = field_x(search, 10, FONT_SIZE_UI, PERF_SEARCH, len(PERF_SEARCH))
		next_step(p, &step, frame)

	case 14:
		w := &g.settings_window
		selected := w.search.anchor == 4 && w.search.caret == len(PERF_SEARCH)
		check(p, "dragging in the settings search selects", selected)
		g.mouse_down = false
		settings_window_toggle()

		// Ctrl+A in the finder, over the code
		pane_focus(pp.code)
		textedit.set_single_selection(code, {0, 0, -1})
		before := code.sels[code.primary]
		finder_toggle()
		type_text("code")
		press_chord(.A, sdl.KMOD_LCTRL)
		q := &g.finder.query
		check(p, "Ctrl+A in the finder selects its query", q.anchor == 0 && q.caret == 4)
		alone := len(code.sels) == 1 && code.sels[code.primary] == before
		check(p, "Ctrl+A in the finder leaves the editor's selection", alone)
		press(sdl.K_ESCAPE)

		pane_focus(pp.terminal)
		return true
	}
	return false
}


// Presses and releases a mouse button at a point, as SDL's events would
@(private = "file")
press_mouse_button :: proc(button: u8, at: [2]f32) {
	event: sdl.Event
	event.type = .MOUSE_BUTTON_DOWN
	event.button.button = button
	event.button.down = true
	event.button.clicks = 1
	event.button.x = at.x
	event.button.y = at.y
	mouse_button_event(&event)

	event.button.type = .MOUSE_BUTTON_UP
	event.button.down = false
	mouse_button_event(&event)
}


// Runs typo itself (this program) in the terminal's shell with two files and
// one in a folder that doesn't exist: the shell has the window's endpoint, so
// the two open here in new panes, the first beside the code (which stays
// open), the second beside the first and focused, the terminal still shown,
// and the third doesn't open. Then a file already open is sent again: its
// pane is focused and no pane is added
@(private = "file")
phase_ipc_open :: proc(p: ^Perf, frame: int) -> bool {
	@(static) since: time.Tick
	@(static) panes_before: int
	sep := os.Path_Separator
	first := path_in_dir(p, "ipc-first.md")
	second := path_in_dir(p, fmt.tprintf("sub%cipc-second.md", sep))
	missing := path_in_dir(p, fmt.tprintf("missing%cipc.md", sep))
	code := perf_panes.code

	if frame == 0 {
		// The files
		_ = os.make_directory_all(path_in_dir(p, "sub"))
		_ = os.write_entire_file(first, transmute([]u8)string("# first\n"))
		_ = os.write_entire_file(second, transmute([]u8)string("# second\n"))

		// The command, with paths relative to the shell's folder (the workspace)
		exe, _ := os.get_executable_path(context.temp_allocator)
		when ODIN_OS == .Windows {
			args := `ipc-first.md sub\ipc-second.md missing\ipc.md`
			command := fmt.tprintf("\"%s\" %s\r", exe, args)
		} else {
			args := "ipc-first.md sub/ipc-second.md missing/ipc.md"
			command := fmt.tprintf("'%s' %s\n", exe, args)
		}

		t := perf_panes.terminal
		pane_focus(t)
		term.session_input(&t.content.(^Terminal).session, transmute([]u8)command)
		since = time.tick_now()
		p.mark_frame = -1
		return false
	}

	// The file already open, sent again (the last step)
	if p.mark_frame == -2 {
		again := g.panes.focused == code && len(g.panes.open) == panes_before
		check(p, "a file already open is focused, in its pane", again)
		pane_focus(perf_panes.terminal)
		return true
	}

	// Until both are open, then until the panes have settled
	a, b := pane_with_file(first), pane_with_file(second)
	opened := a != nil && b != nil
	if !opened && time.tick_since(since) < 20 * time.Second {
		return false
	}
	if p.mark_frame < 0 {
		p.mark_frame = frame
		return false
	}
	if g.animating do return false

	check(p, "typo <file> in the terminal opens the files in this window", opened)
	if !opened do return true

	kept := pane_shown(code) && pane_shown(a) && code.rect.x < a.rect.x
	check(p, "the first file opens beside the code, which stays", kept)
	beside := pane_shown(a) && pane_shown(b) && a.rect.x < b.rect.x
	check(p, "the second file is beside the first, and focused", beside && g.panes.focused == b)
	check(p, "the terminal stays shown", pane_shown(perf_panes.terminal))
	check(p, "a file in a missing folder doesn't open", pane_with_file(missing) == nil)

	// Back as the later phases expect: the two files closed. Then the code is
	// sent again, as the listener would
	pane_close(b, ask = false)
	pane_close(a, ask = false)
	panes_before = len(g.panes.open)
	pane_focus(perf_panes.terminal)

	paths := make([]string, 1)
	paths[0] = strings.clone(code.content.(^Editor).path)
	g.pending = Open_Files{paths = paths}
	p.mark_frame = -2
	return false
}


// Go to line on the code of phase_panes_typing: Ctrl+G opens the bar, typing
// a line scrolls there (the line in the middle) with the caret on it, Enter
// keeps it and Go back returns; Esc puts caret and scroll back. Then a line
// of the notes, rendered
@(private = "file")
phase_goto_line :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) scroll: f64
	@(static) was_rendered: bool
	pp := &perf_panes
	code := pp.code.content.(^Editor)
	notes := pp.notes.content.(^Editor)

	if frame == 0 {
		g.panes.maximized = nil
		pane_focus(pp.code)
		textedit.set_single_selection(code, {0, 0, -1})
		textedit.scroll_to(code, 0)
		step, p.mark_frame = 1, frame
		return false
	}

	// Each step once the last has shown, and what it opened is open
	waited := frame - p.mark_frame
	if g.animating || g.pending != nil || waited < 2 {
		return false
	}

	switch step {
	case 1:
		press_chord(.G, sdl.KMOD_LCTRL)
		opened := g.goto_line.open && g.goto_line.pane == pp.code
		check(p, "Ctrl+G opens the go to line bar", opened)
		type_text("1200")
		next_step(p, &step, frame)

	case 2: // the line previewed in the middle
		_, bar_shown := element_rect(clay.ID("GotoBar"))
		check(p, "the bar shows on the editor", bar_shown)

		lh := f64(text_line_height(code))
		line_middle := 1199 * lh + lh / 2
		view_middle := code.scroll_y + f64(code.view.h) / 2
		centered := abs(line_middle - view_middle) <= lh
		check(p, "typing a line scrolls there, to the middle", centered)
		check(p, "with the caret on it", caret_line_of(code) == 1199)
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 3:
		kept := !g.goto_line.open && caret_line_of(code) == 1199
		check(p, "Enter moves the caret there", kept)
		run_command(.Go_Back)
		next_step(p, &step, frame)

	case 4:
		check(p, "Go back returns to where it was", code.sels[code.primary].head == 0)
		scroll = code.target_y
		press_chord(.G, sdl.KMOD_LCTRL)
		type_text("300")
		next_step(p, &step, frame)

	case 5: // previewed, then Esc
		moved := caret_line_of(code) == 299 && code.target_y != scroll
		press(sdl.K_ESCAPE)
		back := code.sels[code.primary].head == 0 && code.target_y == scroll
		check(p, "Esc puts the caret and the scroll back", moved && back && !g.goto_line.open)

		// The notes, rendered
		pane_focus(pp.notes)
		was_rendered = md_rendered(notes)
		if !was_rendered do run_command(.Toggle_Markdown_View)
		next_step(p, &step, frame)

	case 6:
		press_chord(.G, sdl.KMOD_LCTRL)
		type_text("40")
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 7:
		on_line := md_rendered(notes) && caret_line_of(notes) == 39
		check(p, "in rendered Markdown: the document's line", on_line)

		if !was_rendered do run_command(.Toggle_Markdown_View)
		pane_focus(pp.terminal)
		return true
	}
	return false
}


@(private = "file")
caret_line_of :: proc(e: ^Editor) -> int {
	return buffer.offset_to_line(&e.buf, e.sels[e.primary].head)
}


// The window x of a field's character boundary, its text not scrolled
@(private = "file")
field_x :: proc(id: clay.ElementId, padding: f32, size: u16, s: string, i: int) -> f32 {
	r, _ := element_rect(id)
	return r.x + padding + gfx.text_caret_x(&gfx.text_system, .Body, size, s, i)
}


// A press on a field's character boundary, held down
@(private = "file")
press_field :: proc(
	id: clay.ElementId,
	padding: f32,
	size: u16,
	s: string,
	i: int,
	clicks: int,
) {
	r, _ := element_rect(id)
	g.mouse_pos = {field_x(id, padding, size, s, i), r.y + r.h / 2}
	g.mouse_pressed, g.mouse_down, g.mouse_clicks = true, true, clicks
}


// The panes of phase_panes_typing before zooming
@(private = "file")
perf_zoom: struct {
	char_w:  f32,          // the code's column
	line_h:  int,          // the code's row
	kept:    textedit.Anchor, // the code's caret line on screen
	notes_h: f64,          // the notes' row (scroll step)
	cell:    [2]f32,       // the terminal's
	grid:    [2]u16,       // ... cols, rows
}


// Zooms the panes of phase_panes_typing, each step once the last has shown:
// the code with Ctrl+Keypad +/- (real chords), the notes from the status bar's
// popup, the terminal with Ctrl+Keypad +; then saves two of them as the
// session does and restores them
@(private = "file")
phase_zoom_panes :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	pp := &perf_panes
	z := &perf_zoom
	if frame == 0 {
		step = 0
		p.mark_frame = 0
	}
	if g.animating || frame - p.mark_frame < 3 {
		return false
	}

	code := pp.code.content.(^Editor)
	notes := pp.notes.content.(^Editor)
	t := pp.terminal.content.(^Terminal)
	ctrl := sdl.KMOD_LCTRL

	switch step {
	case 0: // the caret in the middle of the code, which has the keys
		pane_focus(pp.code)
		textedit.show_caret(code, true)
		mid := buffer.line_start(&code.buf, buffer.line_count(&code.buf) / 2)
		textedit.set_single_selection(code, {mid, mid, -1})
		code.center, code.reveal = true, true

	case 1: // zoom in
		_, shown := element_rect(clay.ID("ZoomStatus"))
		check(p, "the status bar shows the zoom", shown)
		z^ = {
			char_w  = code.char_w,
			line_h  = text_line_height(code),
			kept    = code.kind.anchor(code),
			notes_h = notes.kind.scroll_step(notes),
			cell    = {t.cell_w, t.cell_h},
			grid    = {t.session.cols, t.session.rows},
		}
		press_chord(.KP_PLUS, ctrl)

	case 2: // only the code zoomed, its caret line in place; zoom out twice
		zoomed := code.zoom == 1 && code.char_w > z.char_w && text_line_height(code) > z.line_h
		check(p, "Ctrl+= zooms the focused pane", zoomed)

		kept := code.kind.anchor(code)
		in_place := kept.line == z.kept.line && abs(kept.y - z.kept.y) <= 1
		check(p, "its caret's line stays in place", in_place)

		others := notes.kind.scroll_step(notes) == z.notes_h && t.cell_w == z.cell.x
		check(p, "the other panes keep their size", others)
		press_chord(.KP_MINUS, ctrl)
		press_chord(.KP_MINUS, ctrl)

	case 3: // the notes get the keys; open the zoom popup
		check(p, "Ctrl+- zooms out", code.zoom == -1 && text_line_height(code) < z.line_h)
		pane_focus(pp.notes)
		click_element(clay.ID("ZoomStatus"))

	case 4:
		check(p, "clicking the zoom opens its popup", g.zoom_popup.open)
		click_element(clay.ID("ZoomIn"))

	case 5:
		zoomed := notes.zoom == 1 && notes.kind.scroll_step(notes) > z.notes_h
		check(p, "the popup zooms rendered Markdown in", zoomed)
		check(p, "the other panes keep their zoom", code.zoom == -1 && t.zoom == 0)
		click_element(clay.ID("ZoomIn"))

	case 6:
		click_element(clay.ID("ZoomOut"))

	case 7:
		check(p, "the popup zooms out", notes.zoom == 1)
		click_element(clay.ID("ZoomReset"))

	case 8: // a click outside closes the popup
		check(p, "the popup's zoom resets it", notes.zoom == 0)
		r, _ := element_rect(pane_id(pp.code))
		g.mouse_pos, g.mouse_pressed = {r.x + r.w / 2, r.y + r.h / 2}, true

	case 9: // the terminal
		check(p, "a click outside closes the popup", !g.zoom_popup.open)
		check(p, "and does nothing else", g.panes.focused == pp.notes)
		pane_focus(pp.terminal)
		press_chord(.KP_PLUS, ctrl)

	case 10: // its cells grew and its grid has fewer of them
		grown := t.zoom == 1 && t.cell_w > z.cell.x && t.cell_h > z.cell.y
		check(p, "Ctrl+= zooms a terminal", grown)
		fewer := t.session.cols < z.grid.x && t.session.rows <= z.grid.y
		check(p, "the terminal's grid resizes", fewer)
		check(p, "the other panes keep their zoom", code.zoom == -1 && notes.zoom == 0)

	case 11: // the session: saved, then restored
		check(p, "zoom is restored from the session", zoom_restores(pp.code, pp.terminal))
		for pane in g.panes.open do pane_init_zoom(pane, 0)
		return true
	}

	step += 1
	p.mark_frame = frame
	return false
}


// Saves two zoomed panes as the session does (through JSON), restores them
// beside the others and compares their zoom
@(private = "file")
zoom_restores :: proc(panes: ..^Pane) -> bool {
	saved := make([dynamic]Session_Pane, context.temp_allocator)
	for pane in panes {
		sp, kept := session_pane(pane)
		if !kept do return false
		append(&saved, sp)
	}

	data, err := json.marshal(saved[:], allocator = context.temp_allocator)
	if err != nil do return false
	read: []Session_Pane
	if json.unmarshal(data, &read, allocator = context.temp_allocator) != nil {
		return false
	}

	// The file opens again in a new pane once its own is closed
	for pane in panes {
		if is_editor(pane) do pane_close(pane, ask = false)
	}
	restored := restore_panes(read)

	same := len(restored) == len(panes)
	for pane, i in restored {
		if pane == nil {
			same = false
			continue
		}

		step, _ := pane_zoom(pane)
		same &= step == textedit.zoom_step(read[i].zoom) && step != 0
		if is_terminal(pane) do pane_close(pane, ask = false)
	}
	return same
}


// Zooms rendered notes.md a step a frame, in and out, with the caret in the
// middle: each step re-estimates every line's height and lays out what is in
// view, keeping the caret's line in place. Frames count after a first round
@(private = "file")
phase_zoom_markdown :: proc(p: ^Perf, frame: int) -> bool {
	@(static) kept: textedit.Anchor
	@(static) moved: f64       // the most the caret's line moved on screen in a step
	@(static) rows: [2]f64     // the lowest and highest row height seen
	ZOOMS :: [?]int{1, 4, 7, 3, 0, -3, -5, -1} // 300% is 7 steps up, 50% 5 down

	if frame == 0 {
		close_files()
		open_loaded(path_in_dir(p, "notes.md"))
		e := focused_editor()
		textedit.show_caret(e, true)
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		textedit.set_single_selection(e, {mid, mid, -1})
		e.center, e.reveal = true, true
		p.mark_frame = -1
		moved = 0
		rows = {max(f64), 0}
		return false
	}

	// Frames count from when it shows and has settled
	e := focused_editor()
	if p.mark_frame < 0 {
		if !e.shown || frame < 10 {
			return false
		}
		p.mark_frame = frame
		clear(&p.frames)
	} else {
		a := e.kind.anchor(e)
		moved = max(moved, a.line == kept.line ? abs(a.y - kept.y) : max(f64))

		row := e.kind.scroll_step(e)
		rows = {min(rows[0], row), max(rows[1], row)}
	}

	// The first round opens the fonts at each size; the frames after it count
	zooms := ZOOMS
	n := frame - p.mark_frame
	if n == len(zooms) {
		worst: f64
		for f in p.frames do worst = max(worst, f[.Update] + f[.Render])
		result(p, "first step to each zoom, max CPU", worst, "ms")
		clear(&p.frames)
	}
	if n == 120 + len(zooms) {
		zoomed := md_rendered(e) && rows[1] > rows[0] * 3
		check(p, "rendered Markdown zooms (50% to 300%)", zoomed)
		check(p, "the caret's line stays in place", moved <= 1)
		pane_init_zoom(g.panes.focused, 0)
		return true
	}

	kept = e.kind.anchor(e)
	pane_set_zoom(g.panes.focused, zooms[n % len(zooms)])
	return false
}


// --- Language servers --------------------------------------------------------------

// The fake server's client, from the typing phase for the popup phase
@(private = "file")
perf_lsp_client: ^langs.Client

@(private = "file")
PERF_FAKE_SERVER :: "build/fake_lsp.exe" when ODIN_OS == .Windows else "build/fake_lsp"


// The fake server (src/lsp/fake_server) set up in settings.toml for Odin files:
// it starts when code.odin opens and follows typing (each keystroke a
// didChange of a 400 KB document)
@(private = "file")
phase_lsp_typing :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	client := &perf_lsp_client

	if frame == 0 {
		step = 0
		client^ = nil
		fake := process.find_executable(PERF_FAKE_SERVER, context.temp_allocator)
		check(p, "the fake server is built", fake != "")
		if fake == "" do return true

		// The server, then the file it serves
		langs.state.active = true
		o := langs.server_override(&g.settings.servers, "fake")
		o.command = make([]string, 1)
		o.command[0] = strings.clone(fake)
		o.languages = make([]string, 1)
		o.languages[0] = strings.clone("odin")
		settings_changed()
		open_timed(p, "code.odin")
		p.mark_frame = frame
		return false
	}

	e := focused_editor()
	switch step {
	case 0: // the server starts
		for dc in e.lsp.clients {
			if dc.client.name == "fake" && dc.opened && dc.client.state == .Running {
				client^ = dc.client
			}
		}
		if client^ == nil {
			if frame - p.mark_frame > 600 {
				check(p, "the server starts and gets the file", false)
				return true
			}
			return false
		}
		check(p, "the server starts and gets the file", true)
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		textedit.show_caret(e, true)
		textedit.set_single_selection(e, {mid, mid, -1})
		e.reveal = true
		step, p.mark_frame = 1, frame

	case 1: // typing, the server following
		text := "the quick brown fox "
		editor_text_input(e, text[frame % len(text):][:1])
		if frame - p.mark_frame < 120 do return false

		_, shown := element_rect(clay.ID("LspStatus"))
		check(p, "the status bar shows it", shown)
		check(p, "it is still running", client^.state == .Running)
		return true
	}
	return false
}


// A file with a problem on each of its 10,000 lines (the fake server reports
// each "FIXME"), scrolled a page a frame: every row in view is underlined
@(private = "file")
phase_lsp_problems :: proc(p: ^Perf, frame: int) -> bool {
	@(static) arrived: bool
	if perf_lsp_client == nil do return true

	if frame == 0 {
		arrived = false
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 10_000 {
			fmt.sbprintf(&sb, "value_%d := shared_name + %d // FIXME check it\n", i, i)
		}
		_ = os.write_entire_file(path_in_dir(p, "problems.odin"), strings.to_string(sb))
		open_timed(p, "problems.odin")
		p.mark_frame = frame
		return false
	}

	// The problems arrive
	e := focused_editor()
	if !arrived {
		arrived = len(e.lsp.problems) == 10_000
		if !arrived && frame - p.mark_frame < 600 {
			return false
		}
		check(p, "the server's 10,000 problems arrive", arrived)
		if !arrived do return true
		p.mark_frame = frame
	}

	textedit.move(e, .Page_Down, false)
	return frame - p.mark_frame >= 120
}


// With problems.odin open: the pointer resting on a word shows the server's
// hover and the problem there, and leaving closes it; Go to definition jumps
// and Go back returns; right-click opens the editor menu, whose Select all
// works; Next problem goes to one
@(private = "file")
phase_lsp_features :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) step_at: time.Tick // when the step began, for waits on the server
	@(static) from: int          // where Go to definition started
	if perf_lsp_client == nil do return true

	e := focused_editor()
	h := &g.lsp.hover
	waited := frame - p.mark_frame
	waited_ms := ms_since(step_at)

	if frame == 0 {
		step = 0
		textedit.set_single_selection(e, {0, 0, -1})
		textedit.scroll_to(e, 0)
		p.mark_frame = frame
		return false
	}

	switch step {
	case 0: // rest the pointer on "FIXME" on line 3
		if waited < 2 do return false
		r, ok := e.kind.char_rect(e, line_offset(e, 3, "FIXME", 1))
		check(p, "the word is in view", ok)
		g.mouse_pos = {r.x + r.w / 2, r.y + r.h / 2}
		step, p.mark_frame, step_at = 1, frame, time.tick_now()

	case 1: // after the hover delay, the server's text and the problem
		_, placed := element_rect(clay.ID("LspHover"))
		shown := h.open && h.text != "" && placed
		if !shown && waited_ms < 3000 {
			return false
		}

		check(p, "resting on a word shows its hover", shown && h.text == "**FIXME**")
		check(p, "the hover lists the problem there", len(langs.problems_at(&e.lsp, h.offset)) == 1)
		g.mouse_pos = {4, f32(g.window_h) - 4} // the status bar
		step, p.mark_frame, step_at = 2, frame, time.tick_now()

	case 2: // it closes once the pointer has been away a moment
		if h.open && waited_ms < 2000 {
			return false
		}

		check(p, "the hover closes when the pointer leaves", !h.open)
		from = line_offset(e, 500, "shared_name", 3)
		textedit.set_single_selection(e, {from, from, -1})
		run_command(.Go_To_Definition)
		step, p.mark_frame, step_at = 3, frame, time.tick_now()

	case 3: // at the first "shared_name", on line 0
		target := line_offset(e, 0, "shared_name")
		e = focused_editor()
		jumped := e.sels[e.primary].head == target
		if !jumped && waited_ms < 3000 {
			return false
		}

		check(p, "Go to definition jumps to it", jumped)
		run_command(.Go_Back)
		step, p.mark_frame, step_at = 4, frame, time.tick_now()

	case 4: // back where it started, in the middle of the view
		back := e.sels[e.primary].head == from && !e.reveal
		if !back && waited_ms < 1000 {
			return false
		}

		check(p, "Go back returns", back)
		lh := f64(text_line_height(e))
		line_middle := 500 * lh + lh / 2
		view_middle := e.target_y + f64(e.view.h) / 2
		check(p, "the place is in the middle of the view", abs(line_middle - view_middle) <= lh)
		r, _ := e.kind.char_rect(e, from)
		g.mouse_pos, g.right_pressed = {r.x + r.w / 2, r.y + r.h / 2}, true
		step, p.mark_frame = 5, frame

	case 5: // the editor menu; choose Select all
		if waited < 2 do return false

		m := &g.menu
		is_editor_menu := m.open && m.count == 9 && m.items[0].command == .Go_To_Definition
		check(p, "right-click opens the editor menu", is_editor_menu)
		check(p, "it offers Go to definition", is_editor_menu && !m.items[0].disabled)
		references := is_editor_menu && m.items[1].command == .Find_References
		check(p, "and Find references", references && !m.items[1].disabled)
		rename := is_editor_menu && m.items[2].command == .Rename_Symbol
		check(p, "and Rename symbol", rename && !m.items[2].disabled)
		at, _ := element_center(clay.ID("MenuItem", 8))
		g.mouse_pos, g.mouse_pressed = at, true
		step, p.mark_frame = 6, frame

	case 6: // everything is selected
		if waited < 3 do return false

		s := e.sels[e.primary]
		all := textedit.sel_lo(s) == 0 && textedit.sel_hi(s) == buffer.length(&e.buf)
		check(p, "its Select all selects everything", all && !g.menu.open)

		// Next problem: the first FIXME, shown in the hover
		textedit.set_single_selection(e, {0, 0, -1})
		run_command(.Next_Problem)
		at_problem := e.sels[e.primary].head == line_offset(e, 0, "FIXME")
		check(p, "Next problem goes to one and shows it", at_problem && h.open && h.sticky)
		lsp_hover_close()
		return true
	}
	return false
}


// With code.odin open (its functions "item_N :: proc" each hold "name :="):
// Go to symbol in file lists its outline with the caret's symbol selected, a
// query filters it and Enter goes there; Go to symbol in project asks as the
// query rests and goes to the one chosen; Find references lists every "total"
// with its line, pages through them, a click on one goes there (rows below it
// still laid out), and Go back returns
@(private = "file")
phase_lsp_finder :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) step_at: time.Tick
	@(static) from: int   // where Find references was asked
	@(static) chosen: int // the reference gone to
	if perf_lsp_client == nil do return true

	f := &g.finder
	e := focused_editor()
	waited := frame - p.mark_frame
	waited_ms := ms_since(step_at)

	if frame == 0 {
		step = 0
		open_timed(p, "code.odin")
		p.mark_frame, step_at = frame, time.tick_now()
		return false
	}
	if e == nil do return false

	switch step {
	case 0: // the server has the file; the outline, from item_10's line
		opened := false
		for dc in e.lsp.clients {
			if dc.client == perf_lsp_client && dc.opened {
				opened = true
			}
		}
		if !opened && waited_ms < 3000 {
			return false
		}

		check(p, "the server gets code.odin", opened)
		at := text_offset(e, "item_10 ::")
		textedit.set_single_selection(e, {at, at, -1})
		run_command(.Go_To_File_Symbol)
		step, p.mark_frame, step_at = 1, frame, time.tick_now()

	case 1: // every function and the variable in each; filter, and go to one
		listed := f.open && len(f.items) > 0 && !finder_busy()
		if !listed && waited_ms < 3000 {
			return false
		}

		functions := strings.count(buffer_text(e), " :: proc")
		outline := listed && len(f.items) == 2 * functions
		outline = outline && f.items[0].label == "item_0" && f.items[1].depth == 1
		check(p, "Go to symbol in file lists the outline", outline)
		check(p, "with the caret's symbol selected", selected_label() == "item_10")

		type_text("item_42")
		finder_restart_search()
		step, p.mark_frame, step_at = 2, frame, time.tick_now()

	case 2:
		if finder_busy() && waited_ms < 1000 {
			return false
		}

		check(p, "a query filters it", selected_label() == "item_42")
		press(sdl.K_RETURN)
		step, p.mark_frame, step_at = 3, frame, time.tick_now()

	case 3: // there; then the project's symbols
		e = focused_editor()
		target := text_offset(e, "item_42 ::")
		there := e.sels[e.primary].head == target
		if !there && waited_ms < 1000 {
			return false
		}

		check(p, "Enter goes to the symbol", there && !f.open)
		run_command(.Go_To_Symbol)
		type_text("item_77")
		finder_restart_search()
		lsp_finder_query_changed()
		step, p.mark_frame, step_at = 4, frame, time.tick_now()

	case 4: // asked once the query rested; go to it
		asked := g.lsp.finder.query == "item_77" && g.lsp.finder.request == 0
		found := asked && !finder_busy() && selected_label() == "item_77"
		if !found && waited_ms < 3000 {
			return false
		}

		check(p, "Go to symbol in project asks for the query", found)
		press(sdl.K_RETURN)
		step, p.mark_frame, step_at = 5, frame, time.tick_now()

	case 5: // there; then references to "total"
		e = focused_editor()
		target := text_offset(e, "item_77 ::")
		there := e.sels[e.primary].head == target
		if !there && waited_ms < 1000 {
			return false
		}

		check(p, "and goes to the symbol chosen", there && !f.open)
		from = text_offset(e, "total") + 1
		textedit.set_single_selection(e, {from, from, -1})
		run_command(.Find_References)
		step, p.mark_frame, step_at = 6, frame, time.tick_now()

	case 6: // every one, with its line
		listed := f.open && len(f.items) > 0 && !finder_busy()
		if !listed && waited_ms < 5000 {
			return false
		}

		uses := count_words(buffer_text(e), "total")
		check(p, "Find references lists every one", listed && len(f.items) == uses)
		first := listed ? f.items[0].label : ""
		check(p, "each with its line", strings.has_prefix(first, "item_0 :: proc"))
		step, p.mark_frame = 7, frame

	case 7: // page through them, then click one with rows below it
		if waited < 60 {
			press(sdl.K_PAGEDOWN)
			return false
		}

		at := f.selected - 3
		row := f.results[at].index
		chosen, _ = f.items[row].target.(int)
		click_element(clay.ID("FinderRow", u32(at)))
		step, p.mark_frame, step_at = 8, frame, time.tick_now()

	case 8: // there; then back
		there := e.sels[e.primary].head == chosen && chosen > from
		if !there && waited_ms < 1000 {
			return false
		}

		check(p, "clicking a reference goes there", there && !f.open)
		run_command(.Go_Back)
		step, p.mark_frame, step_at = 9, frame, time.tick_now()

	case 9:
		back := e.sels[e.primary].head == from
		if !back && waited_ms < 1000 {
			return false
		}

		check(p, "Go back returns to where it was asked", back)
		return true
	}
	return false
}


// In code.odin (the fake server completes every word of it): typing a word
// opens the list, more letters filter it (about 1,500 items) and the chosen
// item's documentation comes; clicking it (rows below it) inserts it. "("
// shows the signature, a comma moves to the next parameter, ")" closes it. A
// snippet goes in as text with its placeholder selected; an item's import goes
// in with it, and one undo takes both back; Esc closes the list
@(private = "file")
phase_lsp_completion :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) step_at: time.Tick
	@(static) typed: int // of the text being typed
	if perf_lsp_client == nil do return true

	cs := &g.lsp.completion
	sig := &g.lsp.signature
	e := focused_editor()
	waited := frame - p.mark_frame
	waited_ms := ms_since(step_at)

	if frame == 0 {
		step, typed = 0, 0
		p.mark_frame, step_at = frame, time.tick_now()
		return false
	}
	if e == nil do return false

	switch step {
	case 0: // a new line in item_0, then the first letter
		at := text_offset(e, "\treturn total") - 1 // the end of the line before
		textedit.set_single_selection(e, {at, at, -1})
		textedit.insert(e, "\n\t")
		editor_text_input(e, "i")
		step, p.mark_frame, step_at = 1, frame, time.tick_now()

	case 1: // the list opens; the rest of the word, a letter every few frames
		if !cs.open {
			if waited_ms < 3000 do return false
			check(p, "typing a word opens the list", false)
			return true
		}

		word := "tem_42"
		if typed < len(word) {
			if waited % 4 == 0 {
				editor_text_input(e, word[typed:][:1])
				typed += 1
			}
			return false
		}

		check(p, "typing a word opens the list", true)
		step, p.mark_frame, step_at = 2, frame, time.tick_now()

	case 2: // the best match chosen, its documentation asked for
		docs := chosen_completion().documentation
		if docs == "" && waited_ms < 3000 {
			return false
		}

		check(p, "typing filters it", chosen_completion().label == "item_42")
		check(p, "the chosen item's documentation comes", strings.contains(docs, "docs for"))
		check(p, "more items match below it", len(cs.shown) > 1)
		click_element(clay.ID("CompletionRow", 0))
		step, p.mark_frame, step_at = 3, frame, time.tick_now()

	case 3: // inserted once; then a call
		if cs.open && waited_ms < 1000 {
			return false
		}

		line, _ := caret_line(e)
		check(p, "clicking an item inserts it", line == "\titem_42" && !cs.open)
		editor_text_input(e, "(")
		step, p.mark_frame, step_at = 4, frame, time.tick_now()

	case 4: // its signature, the first parameter active
		if !sig.open && waited_ms < 3000 {
			return false
		}

		shown := sig.open && sig.help.label == "item_42(a, b, c)"
		check(p, "\"(\" shows the signature", shown)
		check(p, "with the first parameter active", signature_param() == "a")
		editor_text_input(e, "x")
		editor_text_input(e, ",")
		step, p.mark_frame, step_at = 5, frame, time.tick_now()

	case 5:
		if signature_param() != "b" && waited_ms < 3000 {
			return false
		}

		check(p, "a comma moves to the next", signature_param() == "b")
		editor_text_input(e, ")")
		step, p.mark_frame, step_at = 6, frame, time.tick_now()

	case 6: // closed after the call; then a snippet
		if sig.open && waited_ms < 3000 {
			return false
		}

		check(p, "\")\" closes it", !sig.open)
		textedit.insert(e, "\n\t")
		type_word(e, "fake_sn")
		step, p.mark_frame, step_at = 7, frame, time.tick_now()

	case 7:
		if !cs.open && waited_ms < 3000 {
			return false
		}
		press(sdl.K_RETURN)
		step, p.mark_frame = 8, frame

	case 8: // as text, its placeholder selected; then an item with an import
		line, _ := caret_line(e)
		s := e.sels[e.primary]
		lo, hi := textedit.sel_lo(s), textedit.sel_hi(s)
		chosen := string(buffer.read_alloc(&e.buf, lo, hi))
		check(p, "a snippet goes in as text", line == "\tcall(arg, )")
		check(p, "with its placeholder selected", chosen == "arg")

		textedit.set_single_selection(e, {hi + 3, hi + 3, -1})
		textedit.insert(e, "\n\t")
		type_word(e, "fake_im")
		step, p.mark_frame, step_at = 9, frame, time.tick_now()

	case 9:
		if !cs.open && waited_ms < 3000 {
			return false
		}
		press(sdl.K_RETURN)
		step, p.mark_frame = 10, frame

	case 10: // the import at the top, undone with the item in one step
		first, _ := textedit.line_text(e, 0)
		line, _ := caret_line(e)
		imported := first == "// imported" && line == "\tfake_import"
		check(p, "an item's import goes in with it", imported)
		run_command(.Undo)
		first, _ = textedit.line_text(e, 0)
		line, _ = caret_line(e)
		check(p, "one undo takes both back", first == "package perf" && line == "\tfake_im")

		// Then Esc closes a list
		editor_text_input(e, "p")
		step, p.mark_frame, step_at = 11, frame, time.tick_now()

	case 11:
		if !cs.open && waited_ms < 3000 {
			return false
		}
		press(sdl.K_ESCAPE)
		check(p, "Esc closes the list", !cs.open)
		return true
	}
	return false
}


// In code.odin, with uses.odin beside it on disk: Rename on "total" opens a
// field with the name selected, Esc drops it; a new name and Enter ask about the
// file that isn't open, and once confirmed every "total" in both files is
// renamed, the caret still in the name; one undo takes the open file's back. A
// server's workspace/applyEdit is made
@(private = "file")
phase_lsp_rename :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) step_at: time.Tick
	@(static) uses: int // of "total" in code.odin
	if perf_lsp_client == nil do return true

	sr := &g.lsp.rename
	e := focused_editor()
	waited_ms := ms_since(step_at)
	uses_path := path_in_dir(p, "uses.odin")

	if frame == 0 {
		step = 0
		text := "package perf\n\nuse_it :: proc() -> f32 {\n\treturn total + total\n}\n"
		_ = os.write_entire_file(uses_path, text)
		p.mark_frame, step_at = frame, time.tick_now()
		return false
	}
	if e == nil do return false

	switch step {
	case 0: // Rename on "total", then Esc
		uses = count_words(buffer_text(e), "total")
		at := text_offset(e, "total") + 2
		textedit.set_single_selection(e, {at, at, -1})
		run_command(.Rename)
		step, step_at = 1, time.tick_now()

	case 1:
		if !sr.open && waited_ms < 3000 {
			return false
		}

		field := line_edit_string(&sr.field)
		all := sr.field.anchor == 0 && sr.field.caret == len(field)
		check(p, "Rename opens a field with the name selected", sr.open && field == "total" && all)
		press(sdl.K_ESCAPE)
		check(p, "Esc drops it", !sr.open && sr.editor == nil)

		run_command(.Rename)
		step, step_at = 2, time.tick_now()

	case 2: // a new name; Enter
		if !sr.open && waited_ms < 3000 {
			return false
		}
		type_text("sum_all")
		press(sdl.K_RETURN)
		step, step_at = 3, time.tick_now()

	case 3: // the file that isn't open is asked about
		_, asking := g.dialog.purpose.(Applying_Edit)
		if !(g.dialog.open && asking) && waited_ms < 3000 {
			return false
		}

		check(p, "a file that isn't open is asked about", g.dialog.open && asking)
		press(sdl.K_RETURN)
		step, step_at = 4, time.tick_now()

	case 4: // both renamed; the caret stays in the name; undo
		if g.lsp.edits.active && waited_ms < 3000 {
			return false
		}

		text := buffer_text(e)
		renamed := count_words(text, "total") == 0 && count_words(text, "sum_all") == uses
		check(p, "every use in the open file is renamed", renamed)
		data, _ := os.read_entire_file(uses_path, context.temp_allocator)
		check(p, "and in the file on disk", strings.contains(string(data), "sum_all + sum_all"))
		caret := e.sels[e.primary].head
		in_name := caret == text_offset(e, "sum_all") + 2
		check(p, "the caret stays in the name", in_name)

		run_command(.Undo)
		check(p, "one undo takes it back", count_words(buffer_text(e), "total") == uses)

		// A line for the server's edit to change
		textedit.insert(e, "\n// FIXME\n")
		step, step_at = 5, time.tick_now()

	case 5: // the server asks for it (the line went out last frame)
		params := fmt.tprintf(`{{"uri":%s}}`, lsp.to_json(e.lsp.uri))
		lsp.request_json(perf_lsp_client.client, "fake/apply", params)
		step, step_at = 6, time.tick_now()

	case 6:
		made := strings.contains(buffer_text(e), "// FIXED")
		if !made && waited_ms < 3000 {
			return false
		}

		check(p, "a server's workspace/applyEdit is made", made)
		return true
	}
	return false
}


// The completion list's chosen item, or an empty one
@(private = "file")
chosen_completion :: proc() -> lsp.Completion {
	cs := &g.lsp.completion
	if cs.selected < 0 || cs.selected >= len(cs.shown) {
		return {}
	}
	return cs.items[cs.shown[cs.selected].index]
}


// The signature's active parameter, as text
@(private = "file")
signature_param :: proc() -> string {
	help := g.lsp.signature.help
	if !g.lsp.signature.open || help.param_lo < 0 {
		return ""
	}
	return help.label[help.param_lo:help.param_hi]
}


// The caret's line
@(private = "file")
caret_line :: proc(e: ^Editor) -> (text: string, start: int) {
	line := buffer.offset_to_line(&e.buf, e.sels[e.primary].head)
	return textedit.line_text(e, line)
}


// Types a word a letter at a time, as keys would
@(private = "file")
type_word :: proc(e: ^Editor, word: string) {
	for i in 0 ..< len(word) {
		editor_text_input(e, word[i:i + 1])
	}
}


// The label of the finder's selected row
@(private = "file")
selected_label :: proc() -> string {
	f := &g.finder
	if f.selected < 0 || f.selected >= len(f.results) {
		return ""
	}
	return f.items[f.results[f.selected].index].label
}


// An editor's whole text (temp)
@(private = "file")
buffer_text :: proc(e: ^Editor) -> string {
	return string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
}


// Where `s` first is in an editor's text, or 0
@(private = "file")
text_offset :: proc(e: ^Editor, s: string) -> int {
	return max(strings.index(buffer_text(e), s), 0)
}


// How many times a word is in text, as a whole word
@(private = "file")
count_words :: proc(text, word: string) -> int {
	n := 0
	from := 0
	for {
		at := strings.index(text[from:], word)
		if at < 0 do break
		at += from
		from = at + len(word)

		before := at == 0 || !is_word_byte(text[at - 1])
		after := from >= len(text) || !is_word_byte(text[from])
		if before && after {
			n += 1
		}
	}
	return n
}


@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}


// The status bar item's popup with the fake server running: Restart, then
// Locate… for a server pointed at a missing program and Turn on for one that
// is off, Turn off for the missing one, then removing the servers from the
// settings
@(private = "file")
phase_lsp_popup :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) running: ^lsp.Client // the fake server's, before another is turned on
	client := perf_lsp_client
	if client == nil do return true // the typing phase failed

	if frame == 0 {
		at, _ := element_center(clay.ID("LspStatus"))
		g.mouse_pos, g.mouse_pressed = at, true
		step, p.mark_frame = 2, frame
		return false
	}

	e := focused_editor()
	switch step {
	case 2: // the popup opens; click Restart
		if frame - p.mark_frame < 2 do return false

		check(p, "clicking it opens the popup", g.lsp.popup.open)
		index := 0
		for c, i in langs.state.clients {
			if c == client do index = i
		}
		at, found := element_center(clay.ID("LspRestart", u32(index)))
		check(p, "the popup lists it", found)
		g.mouse_pos, g.mouse_pressed = at, true
		step, p.mark_frame = 3, frame

	case 3: // it runs again with the file open
		reopened := false
		for dc in e.lsp.clients {
			if dc.client == client && dc.opened {
				reopened = true
			}
		}
		waited := frame - p.mark_frame
		restarted := reopened && client.state == .Running && waited > 2
		if !restarted && waited < 600 {
			return false
		}

		check(p, "Restart starts it again", restarted)

		// Two more servers for Odin: one off, one pointed at a program that isn't there
		off := langs.server_override(&g.settings.servers, "fake-off")
		off.enabled = false
		off.command = make([]string, 1)
		off.command[0] = strings.clone(client.command[0])
		off.languages = make([]string, 1)
		off.languages[0] = strings.clone("odin")
		lost := langs.server_override(&g.settings.servers, "fake-lost")
		lost.path = strings.clone("C:/no/such/server.exe")
		lost.languages = make([]string, 1)
		lost.languages[0] = strings.clone("odin")
		settings_changed()
		step, p.mark_frame = 4, frame

	case 4: // the popup lists them (once the missing program was looked for): Turn on one
		_, locate := element_rect(clay.ID("LspLocate", u32(server_index("fake-lost"))))
		at, turn_on := element_center(clay.ID("LspTurnOn", u32(server_index("fake-off"))))
		listed := locate && turn_on
		if !listed && frame - p.mark_frame < 600 {
			return false
		}

		check(p, "a server not found offers Locate", locate)
		check(p, "a server that is off offers Turn on", turn_on)
		g.mouse_pos, g.mouse_pressed = at, true
		running = client.client
		step, p.mark_frame = 5, frame

	case 5: // it starts
		started := false
		for dc in e.lsp.clients {
			if dc.client.name == "fake-off" && dc.opened && dc.client.state == .Running {
				started = true
			}
		}
		if !started && frame - p.mark_frame < 600 {
			return false
		}
		check(p, "Turn on starts it", started)

		// The server that ran goes on as it was, with the file open
		kept := false
		for dc in e.lsp.clients {
			if dc.client == client && client.client == running && dc.opened {
				kept = true
			}
		}
		check(p, "the other server keeps running with the file", kept)

		// Turn off the one not found
		at, turn_off := element_center(clay.ID("LspTurnOff", u32(server_index("fake-lost"))))
		check(p, "a server not found offers Turn off", turn_off)
		g.mouse_pos, g.mouse_pressed = at, true
		step, p.mark_frame = 6, frame

	case 6: // it is off, offering Turn on
		lost := langs.server("fake-lost")
		_, turn_on := element_rect(clay.ID("LspTurnOn", u32(server_index("fake-lost"))))
		turned_off := lost != nil && !lost.enabled && turn_on
		if !turned_off && frame - p.mark_frame < 600 {
			return false
		}

		check(p, "Turn off turns it off", turned_off)
		lsp_popup_close()

		// Back to no servers
		for i := len(g.settings.servers) - 1; i >= 0; i -= 1 {
			o := &g.settings.servers[i]
			if !strings.has_prefix(o.name, "fake") do continue
			langs.server_override_destroy(o)
			ordered_remove(&g.settings.servers, i)
		}
		t := time.tick_now()
		settings_changed()
		result(p, "removing it (not waiting)", ms_since(t), "ms", 20)
		check(p, "removing it from the settings stops it", len(langs.state.clients) == 0)
		langs.state.active = false
		return true
	}
	return false
}


// The language servers in the settings window, with the fake server: its row
// says it runs, Off stops it and On starts it again; its page edits a field by
// keys and Delete puts it back; a server is added and removed; with only uv
// and npm on PATH, only their install commands are offered, uv's first, and a
// server with neither says what installing needs; and Install runs a server's
// install command (the fake server copying itself onto PATH) in a terminal,
// after which that server starts
@(private = "file")
phase_lsp_settings :: proc(p: ^Perf, frame: int) -> bool {
	@(static) step: int
	@(static) old_path: string
	@(static) focused: ^Pane
	@(static) install_pane: ^Pane
	@(static) terminals: int
	@(static) settled: time.Tick
	w := &g.settings_window

	if frame == 0 {
		fake := process.find_executable(PERF_FAKE_SERVER, context.temp_allocator)
		check(p, "the fake server is built", fake != "")
		if fake == "" do return true
		fake, _ = os.get_absolute_path(fake, context.temp_allocator)

		// Install puts a copy in a folder on PATH
		bin := path_in_dir(p, "bin")
		old_path = strings.clone(os.get_env("PATH", context.temp_allocator))
		_ = os.set_env("PATH", fmt.tprintf("%s%c%s", bin, os.Path_List_Separator, old_path))
		copy_name := ODIN_OS == .Windows ? "fake-install.exe" : "fake-install"
		target, _ := os.join_path({bin, copy_name}, context.temp_allocator)

		// Two servers for Odin: one runs, one isn't installed yet
		langs.state.active = true
		perf_server("fake", fake)
		perf_server("fake-install", "fake-install", fmt.tprintf("%s --copy-to %s", fake, target))

		// And one whose program is a path too long to show whole
		perf_server("fake-far", "fake-far")
		far_name := strings.repeat("far", 40, context.temp_allocator)
		far, _ := os.join_path({bin, far_name, far_name}, context.temp_allocator)
		langs.server_override(&g.settings.servers, "fake-far").path = strings.clone(far)
		settings_changed()

		focused = g.panes.focused
		terminals = count_terminals()
		settings_window_toggle()
		line_edit_set(&w.search, "fake", 4, 4)
		step, p.mark_frame = 1, frame
		return false
	}

	waited := frame - p.mark_frame

	switch step {
	case 1: // the rows: one running, the other offering Install
		fake := server_row_index("fake")
		running := false
		if fake >= 0 {
			state := server_state(server_rows()[fake])
			running = strings.has_prefix(state.text, "Running")
		}
		install_id := clay.ID("ServerInstall", u32(server_row_index("fake-install")))
		_, install := element_rect(install_id)
		locate_id := clay.ID("ServerLocate", u32(server_row_index("fake-far")))
		_, located := element_rect(locate_id)
		if !(running && install && located) && waited < 600 {
			return false
		}

		check(p, "a running server's row says so", running)
		check(p, "a server not found offers Install", install)
		check(p, "rows fit the list, a long path too", rows_fit_list())
		click_element(clay.ID("SettingOption", (4096 + u32(fake)) * 64)) // Off
		next_step(p, &step, frame)

	case 2: // Off stops it
		stopped := perf_client("fake") == nil
		if !stopped && waited < 600 {
			return false
		}

		o := langs.find_server_override(g.settings.servers[:], "fake")
		check(p, "Off stops it", stopped && o != nil && o.enabled == false)
		on := clay.ID("SettingOption", (4096 + u32(server_row_index("fake"))) * 64 + 1)
		click_element(on)
		next_step(p, &step, frame)

	case 3: // On starts it again; Enter opens its page
		c := perf_client("fake")
		started := c != nil && c.state == .Running
		if !started && waited < 600 {
			return false
		}

		check(p, "On starts it again", started)
		focus_item(Server_Item(server_row_index("fake")))
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 4: // its page: type root markers
		check(p, "Enter opens its page", w.server_page == "fake")

		// Down to Root markers
		for _ in langs.Server_Field {
			if w.server_focus != .Root_Markers do press(sdl.K_DOWN)
		}
		press(sdl.K_RETURN)
		type_text("x.marker, y.marker")
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 5: // applied the next frame; Delete puts the built-in ones back
		o := langs.find_server_override(g.settings.servers[:], "fake")
		typed := o != nil && len(o.root_markers) == 2 && o.root_markers[1] == "y.marker"
		check(p, "a field is edited by keys", typed)
		press(sdl.K_DELETE)
		next_step(p, &step, frame)

	case 6: // Esc goes back to the list, cleared to show the row that adds a server
		o := langs.find_server_override(g.settings.servers[:], "fake")
		check(p, "Delete puts a field back as built in", o != nil && o.root_markers == nil)
		press(sdl.K_ESCAPE)
		check(p, "Esc goes back to the list", w.open && w.server_page == "")
		line_edit_clear(&w.search)
		next_step(p, &step, frame)

	case 7: // add a server
		focus_item(Add_Server_Item{})
		press(sdl.K_RETURN)
		next_step(p, &step, frame)

	case 8: // its page shows; remove it
		if waited < 2 do return false

		table := langs.find_server_override(g.settings.servers[:], "server")
		added := w.server_page == "server" && table != nil
		check(p, "Add a server opens a new server's page", added)
		click_element(clay.ID("ServerRemove"))
		next_step(p, &step, frame)

	case 9: // after asking
		_, removing := g.dialog.purpose.(Removing_Server)
		asking := g.dialog.open && removing
		if !asking && waited < 10 {
			return false
		}

		check(p, "Remove asks first", asking)
		g.dialog.choice = 0
		next_step(p, &step, frame)

	case 10:
		table := langs.find_server_override(g.settings.servers[:], "server")
		gone := table == nil && w.server_page == ""
		if !gone && waited < 10 {
			return false
		}

		check(p, "removing it goes back to the list", gone)
		line_edit_set(&w.search, "fake", 4, 4)

		// Installers: only uv and npm are on PATH
		installers := path_in_dir(p, "installers")
		_ = os.make_directory_all(installers)
		for name in ([]string{"uv", "npm"}) {
			stub := ODIN_OS == .Windows ? fmt.tprintf("%s.cmd", name) : name
			stub_path, _ := os.join_path({installers, stub}, context.temp_allocator)
			_ = os.write_entire_file(stub_path, transmute([]u8)string("exit 0\n"))
		}
		_ = os.set_env("PATH", installers)

		// One server with commands for both and for others, one with only others
		perf_server(
			"fake-light",
			"fake-light",
			"cargo install fake-light",
			"npm install -g fake-light",
			"brew install fake-light",
			"uv tool install fake-light",
		)
		perf_server("fake-none", "fake-none", "brew install fake-none", "cargo install fake-none")
		settings_changed()
		langs.recheck_programs()
		next_step(p, &step, frame)

	case 11: // the lightest installer found is offered; with none found, what they need
		light := langs.server_installs(langs.server("fake-light"))
		none := langs.server_installs(langs.server("fake-none"))
		install_id := clay.ID("ServerInstall", u32(server_row_index("fake-light")))
		_, install := element_rect(install_id)
		needs_id := clay.ID("ServerNeeds", u32(server_row_index("fake-none")))
		_, needs := element_rect(needs_id)
		none_install_id := clay.ID("ServerInstall", u32(server_row_index("fake-none")))
		_, none_install := element_rect(none_install_id)

		answered := !programs_checking() && light.known && none.known
		if !(answered && install && needs) && waited < 600 {
			return false
		}

		offered := make([dynamic]string, context.temp_allocator)
		for x in light.offered do append(&offered, x.command)
		want := []string{"uv tool install fake-light", "npm install -g fake-light"}
		lightest := slice.equal(offered[:], want)
		check(p, "only installers on PATH are offered, lightest first", lightest)
		check(p, "Install offered when an installer is found", install)
		check(p, "no Install when no installer is found", !none_install)
		check(p, "it says what installing needs", needs && none.needs == "brew or cargo")
		check(p, "rows fit the list, with what installing needs", rows_fit_list())
		open_server_page("fake-light")
		next_step(p, &step, frame)

	case 12: // the page lists every command found, each with its Install
		_, first := element_rect(clay.ID("ServerPageInstall", 0))
		_, second := element_rect(clay.ID("ServerPageInstall", 1))
		_, third := element_rect(clay.ID("ServerPageInstall", 2))
		if !(first && second) && waited < 600 {
			return false
		}

		check(p, "a server's page lists the commands found", first && second && !third)
		open_server_page("fake-none")
		next_step(p, &step, frame)

	case 13:
		_, needs := element_rect(clay.ID("ServerPageNeeds"))
		_, install := element_rect(clay.ID("ServerPageInstall", 0))
		if (!needs || programs_checking()) && waited < 600 {
			return false
		}

		check(p, "with none found, the page says what installing needs", needs && !install)
		close_server_page()

		// PATH back, and the test servers gone
		bin := path_in_dir(p, "bin")
		_ = os.set_env("PATH", fmt.tprintf("%s%c%s", bin, os.Path_List_Separator, old_path))
		langs.remove_server_override(&g.settings.servers, "fake-light")
		langs.remove_server_override(&g.settings.servers, "fake-none")
		settings_changed()
		langs.recheck_programs()
		next_step(p, &step, frame)

	case 14: // Install, once the programs were looked for on the PATH as it was
		install := clay.ID("ServerInstall", u32(server_row_index("fake-install")))
		_, shown := element_rect(install)
		if (programs_checking() || !shown) && waited < 600 {
			return false
		}
		click_element(install)
		next_step(p, &step, frame)

	case 15: // a terminal runs it, and once it is found the server starts
		last := g.panes.open[len(g.panes.open) - 1]
		opened := count_terminals() == terminals + 1 && is_terminal(last) && !w.open
		if !opened && waited < 10 {
			return false
		}

		check(p, "Install runs it in a terminal", opened)
		if opened do install_pane = last
		next_step(p, &step, frame)

	case 16:
		c := perf_client("fake-install")
		started := c != nil && c.state == .Running
		if !started && waited < 1800 {
			return false
		}
		check(p, "the installed server starts", started)

		// The terminal closes, and the servers go
		if install_pane != nil do pane_close(install_pane, ask = false)
		install_pane = nil
		if focused != nil && slice.contains(g.panes.open[:], focused) {
			pane_focus(focused)
		}
		langs.remove_server_override(&g.settings.servers, "fake")
		langs.remove_server_override(&g.settings.servers, "fake-install")
		langs.remove_server_override(&g.settings.servers, "fake-far")
		settings_changed()
		langs.state.active = false

		_ = os.set_env("PATH", old_path)
		delete(old_path)
		next_step(p, &step, frame)

	case 17: // once the terminal's frame and the servers have gone
		gone := !g.animating && len(langs.state.retiring) == 0
		if !gone && waited < 600 {
			return false
		}
		settled = time.tick_now()
		next_step(p, &step, frame)

	case 18: // and the terminal left has redrawn at its new size
		return time.tick_since(settled) > 500 * time.Millisecond
	}
	return false
}


// The next step of a phase, counting frames from now
@(private = "file")
next_step :: proc(p: ^Perf, step: ^int, frame: int) {
	step^ += 1
	p.mark_frame = frame
}


// Adds a server for Odin files to the settings, its program a path or a name
// on PATH, with its install commands
@(private = "file")
perf_server :: proc(name, program: string, install: ..string) {
	o := langs.server_override(&g.settings.servers, name)
	o.command = make([]string, 1)
	o.command[0] = strings.clone(program)
	o.languages = make([]string, 1)
	o.languages[0] = strings.clone("odin")

	if len(install) > 0 {
		commands := make([]string, len(install))
		for command, i in install do commands[i] = strings.clone(command)
		o.install = commands
	}
}


// Whether a program is being looked for
@(private = "file")
programs_checking :: proc() -> bool {
	for _, answer in langs.state.programs {
		if answer.checking do return true
	}
	return false
}


// The client of the server named `name`, if any
@(private = "file")
perf_client :: proc(name: string) -> ^langs.Client {
	for c in langs.state.clients {
		if c.name == name do return c
	}
	return nil
}


@(private = "file")
server_row_index :: proc(name: string) -> int {
	for row, i in server_rows() {
		if row.name == name do return i
	}
	return -1
}


// Whether the settings list shown last frame, every row in it and their
// controls end inside the panel
@(private = "file")
rows_fit_list :: proc() -> bool {
	page, page_ok := element_rect(clay.ID("SettingsPage"))
	list, list_ok := element_rect(clay.ID("SettingsList"))
	if !page_ok || !list_ok {
		return false
	}

	right := page.x + page.w + 0.5
	if list.x + list.w > right do return false

	for item in g.settings_window.items {
		r, found := element_rect(item_row_id(item))
		if found && r.x + r.w > right {
			return false
		}
	}
	return true
}


@(private = "file")
count_terminals :: proc() -> int {
	n := 0
	for pane in g.panes.open {
		if is_terminal(pane) do n += 1
	}
	return n
}


// Moves the settings window's keyboard focus to a row shown last frame
@(private = "file")
focus_item :: proc(item: Setting_Item) {
	w := &g.settings_window
	for x, i in w.items {
		if x == item do w.focus = i
	}
}


// A press at the center of an element of last frame's layout
@(private = "file")
click_element :: proc(id: clay.ElementId) {
	at, ok := element_center(id)
	if !ok do return
	g.mouse_pos, g.mouse_pressed = at, true
}


// Text typed, as one event
@(private = "file")
type_text :: proc(text: string) {
	event: sdl.Event
	event.type = .TEXT_INPUT
	event.text.text = strings.clone_to_cstring(text, context.temp_allocator)
	handle_key_event(&event)
}


// The offset of `word` in a line, plus `skip`
@(private = "file")
line_offset :: proc(e: ^Editor, line: int, word: string, skip := 0) -> int {
	text, start := textedit.line_text(e, line)
	return start + strings.index(text, word) + skip
}


// Where a server is in the list, which the popup's element ids use
@(private = "file")
server_index :: proc(name: string) -> int {
	for server, i in langs.state.servers {
		if server.name == name do return i
	}
	return -1
}
