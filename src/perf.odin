package editor

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "syntax"
import "term"
import sdl "../vendor/sdl3"

// The performance suite: `typo --perf` (run by `python build.py --test` on an
// optimized build). It drives the real app, with a real window and renderer,
// through the phases in PHASES, one step per frame, and checks each result
// against its limit. Headless phases time the core packages directly; UI phases
// time whole frames. Exits non-zero if any limit is exceeded.
//
// Frames are timed in three parts: update (input, model, layout), render
// (turning Clay commands into SDL draw calls) and present (submitting to the
// GPU; VSync is off, so this includes waiting on the GPU). Limits apply to the
// CPU part, update + render, with a phase's first frame reported on its own.

PERF_IDLE_NS :: 5 * time.Second // process CPU time is counted in ~16 ms ticks on Windows
PERF_SEED :: 7

Perf :: struct {
	begin:      time.Tick,
	dir:        string, // temp folder: the workspace and generated files
	code_text:  string, // generated Odin source, small enough for tree-sitter
	large_text: string, // the same at ~64 MB, highlighted by the lexer

	phase:      int,
	frame:      int, // frame within the phase
	mark_frame: int, // a phase's own reference frame, for phases that wait between steps
	phase_t0:   time.Tick,
	cpu0:       i64,
	frames:     [dynamic]Frame_Time, // of the current phase
	frame_t0:   time.Tick,           // when the current frame's work began
	marks:      [Frame_Part]time.Tick,
	first_present_ns: i64,

	gpu:        Gpu_Counter,
	results:    int,
	failures:   [dynamic]string,
	// Terminal output phase.
	flood_parsed: u64,
	flood_last:   time.Tick,
}

Frame_Part :: enum {
	Update,
	Render,
	Present,
}

Frame_Time :: [Frame_Part]f64 // ms

Phase :: struct {
	name:       string,
	// Called at the start of each frame of the phase; returns true when done.
	step:       proc(p: ^Perf, frame: int) -> bool,
	// p95 limit (ms) on the CPU time of the phase's frames; 0 = frames not reported.
	frame_limit: f64,
	idle:       bool, // let the app sleep between frames
}

PHASES := [?]Phase {
	{name = "startup", step = phase_startup},
	{name = "fonts", step = phase_fonts},
	{name = "generate test files", step = phase_generate},
	{name = "buffer (64 MB)", step = phase_buffer},
	{name = "syntax", step = phase_syntax},
	{name = "fuzzy file search", step = phase_fuzzy},
	{name = "terminal emulation", step = phase_vt},
	{name = "open code file (tree-sitter)", step = phase_open_code, frame_limit = 8},
	{name = "idle with a file open", step = phase_idle, idle = true},
	{name = "typing (tree-sitter)", step = phase_type, frame_limit = 8},
	{name = "scrolling (tree-sitter)", step = phase_scroll, frame_limit = 8},
	{name = "file finder", step = phase_finder, frame_limit = 8},
	{name = "settings window", step = phase_settings, frame_limit = 8},
	{name = "theme list (every theme)", step = phase_theme_picker, frame_limit = 8},
	{name = "font list", step = phase_font_picker, frame_limit = 25},
	{name = "scrolling with letter spacing", step = phase_letter_spacing, frame_limit = 8},
	{name = "open 64 MB file (lexer)", step = phase_open_large, frame_limit = 8},
	{name = "jumping through 64 MB file", step = phase_jump_large, frame_limit = 12},
	{name = "typing in 64 MB file", step = phase_type, frame_limit = 8},
	{name = "8 MB single-line file", step = phase_long_line, frame_limit = 25},
	{name = "terminal full-screen redraws", step = phase_terminal_redraw, frame_limit = 12},
	{name = "terminal shell output (4 MB)", step = phase_terminal_output, frame_limit = 16},
	{name = "idle with the terminal focused", step = phase_idle, idle = true},
}

// Called first thing at startup, before SDL: settings go to a scratch file so
// the user's don't affect results, and the workspace is an empty temp folder.
perf_begin :: proc() -> (workspace: string) {
	p := new(Perf)
	g.perf = p
	p.begin = time.tick_now()
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
	delete(p.large_text)
	delete(p.frames)
	for f in p.failures do delete(f)
	delete(p.failures)
	free(p)
	g.perf = nil
	detach_console()
}

// Whether the app should keep drawing frames back to back.
perf_running :: proc() -> bool {
	return g.perf.phase < len(PHASES) && !PHASES[g.perf.phase].idle
}

perf_mark :: proc(part: Frame_Part) {
	p := g.perf
	p.marks[part] = time.tick_now()
	if part == .Present && p.first_present_ns == 0 {
		p.first_present_ns = process_age_ns()
		if p.first_present_ns < 0 do p.first_present_ns = i64(time.tick_since(p.begin))
	}
}

// Called at the start of every frame. Records the previous frame's timings and
// runs the current phase's step; done is set once every phase has finished.
perf_frame :: proc() -> (done, ok: bool) {
	p := g.perf
	if p.frame_t0 != {} {
		t: Frame_Time
		prev := p.frame_t0
		for part in Frame_Part {
			t[part] = time.duration_milliseconds(time.tick_diff(prev, p.marks[part]))
			prev = p.marks[part]
		}
		append(&p.frames, t)
	}
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
	gpu_counter_start(&p.gpu) // first: querying the counters costs CPU time
	p.phase_t0 = time.tick_now()
	p.cpu0 = process_cpu_ns()
}

@(private = "file")
finish_phase :: proc(p: ^Perf) {
	limit := PHASES[p.phase].frame_limit
	if limit == 0 || len(p.frames) < 2 do return
	// The first frame also loads fonts and shapes text not seen before.
	first := p.frames[0]
	result(p, "first frame CPU", first[.Update] + first[.Render], "ms", 50)
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
	result(p, "frames max CPU", cpu[len(cpu) - 1], "ms")
	result(p, "frames p95 present", percentile(present, 0.95), "ms")
	if gpu := gpu_counter_read(&p.gpu); gpu >= 0 do result(p, "GPU utilization", gpu, "%")
}

@(private = "file")
percentile :: proc(sorted: []f64, q: f64) -> f64 {
	return sorted[min(int(f64(len(sorted)) * q), len(sorted) - 1)]
}

// Prints a result; one over its limit (if it has one) fails the suite.
@(private = "file")
result :: proc(p: ^Perf, name: string, value: f64, unit: string, limit: f64 = 0) {
	p.results += 1
	over := limit > 0 && value > limit
	limit_text := limit > 0 ? fmt.tprintf("limit %.4g", limit) : ""
	fmt.printfln("  %-36s %10s %-5s %-14s%s", name, fmt.tprintf("%.3f", value), unit, limit_text, over ? "OVER" : "")
	if over do append(&p.failures, fmt.aprintf("%s: %s %.3f %s > %.4g", PHASES[p.phase].name, name, value, unit, limit))
}

// Records a functional check; a false one fails the suite.
@(private = "file")
check :: proc(p: ^Perf, name: string, ok: bool) {
	p.results += 1
	fmt.printfln("  %-36s %10s", name, ok ? "ok" : "FAILED")
	if !ok do append(&p.failures, fmt.aprintf("%s: %s", PHASES[p.phase].name, name))
}

@(private = "file")
ms_since :: proc(t: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(t))
}

@(private = "file")
path_in_dir :: proc(p: ^Perf, name: string) -> string {
	return fmt.tprintf("%s%c%s", p.dir, os.Path_Separator, name)
}

// --- Headless phases ----------------------------------------------------------------

@(private = "file")
phase_startup :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do return false // let the first frame present
	result(p, "launch to first frame", f64(p.first_present_ns) / 1e6, "ms", 1000)
	p.gpu = gpu_counter_open()
	return true
}

// A size no UI element uses, so the font is opened here.
@(private = "file")
PERF_FONT_SIZE :: 37

@(private = "file")
phase_fonts :: proc(p: ^Perf, frame: int) -> bool {
	t := time.tick_now()
	font := text_get_font(&g.text, .Body, PERF_FONT_SIZE)
	result(p, "open a new font size", ms_since(t), "ms", 5)
	t = time.tick_now()
	_ = text_get(&g.text, font, "→ ✓ 漢字")
	result(p, "first text needing fallback fonts", ms_since(t), "ms")
	return true
}

// A format string: "{{" prints "{".
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

@(private = "file")
phase_generate :: proc(p: ^Perf, frame: int) -> bool {
	t := time.tick_now()
	p.code_text = generate_code(400 << 10)
	p.large_text = generate_code(64 << 20)
	_ = os.write_entire_file(path_in_dir(p, "code.odin"), p.code_text)
	_ = os.write_entire_file(path_in_dir(p, "large.odin"), p.large_text)

	long := strings.builder_make_len_cap(0, 8 << 20)
	for i := 0; strings.builder_len(long) < 8 << 20; i += 1 do fmt.sbprintf(&long, "value_%d = {{a: %d, b: \"text\"}}; ", i, i)
	_ = os.write_entire_file(path_in_dir(p, "long.js"), strings.to_string(long))
	strings.builder_destroy(&long)

	flood := strings.builder_make_len_cap(0, 4 << 20)
	for i := 0; strings.builder_len(flood) < 4 << 20; i += 1 do fmt.sbprintf(&flood, "%08d The quick brown fox jumps over the lazy dog, again and again and again.\n", i)
	_ = os.write_entire_file(path_in_dir(p, "flood.txt"), strings.to_string(flood))
	strings.builder_destroy(&flood)
	fmt.printfln("  %-36s %10s ms", "generated 76 MB in 4 files", fmt.tprintf("%.3f", ms_since(t)))
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

	N :: 100_000
	lines := buffer.line_count(&b)
	t = time.tick_now()
	sum := 0
	for _ in 0 ..< N {
		sum += buffer.line_start(&b, rand.int_max(lines))
		sum += buffer.offset_to_line(&b, rand.int_max(buffer.length(&b)))
	}
	result(p, "line lookup", f64(time.tick_since(t)) / (2 * N), "ns", 5000)

	EDITS :: 10_000
	t = time.tick_now()
	for i in 0 ..< EDITS {
		buffer.begin(&b, .Other, u64(i) * 10 * buffer.COALESCE_NS, {})
		buffer.replace(&b, rand.int_max(buffer.length(&b)), rand.int_max(4), "edit\n")
		buffer.end(&b, {})
	}
	result(p, "random edit", f64(time.tick_since(t)) / EDITS / 1000, "µs", 50)
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
	h: syntax.Highlighter
	t := time.tick_now()
	syntax.highlighter_open(&h, &b, "code.odin")
	result(p, fmt.tprintf("tree-sitter parse (%d KB)", len(p.code_text) >> 10), ms_since(t), "ms", 250)

	// Typing in the middle: one incremental re-parse per keystroke.
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

// Average time to highlight the 60 lines from `offset`.
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
	for &path, i in paths do path = fmt.tprintf("src/module_%d/component_%d/file_name_%d.odin", i % 97, i % 1013, i)
	t := time.tick_now()
	matched := 0
	for path in paths {
		if _, ok := fuzzy_score("modcompfile77", path); ok do matched += 1
	}
	result(p, fmt.tprintf("score %dk paths", N / 1000), ms_since(t), "ms", 400)
	return true
}

@(private = "file")
phase_vt :: proc(p: ^Perf, frame: int) -> bool {
	s: term.Session
	if !term.session_init(&s, 200, 60, wake_main_loop, nil) do return true
	defer term.session_destroy(&s)
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; strings.builder_len(sb) < 1 << 20; i += 1 {
		fmt.sbprintf(&sb, "\x1b[3%dmline %d\x1b[0m: \x1b[1;34mlorem ipsum\x1b[0m dolor sit amet, consectetur \x1b[7madipiscing\x1b[27m elit\r\n", i % 8, i)
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

// --- UI phases ----------------------------------------------------------------------

@(private = "file")
open_timed :: proc(p: ^Perf, name: string) {
	t := time.tick_now()
	editor_open(&g.editor, path_in_dir(p, name))
	g.focus = .Editor
	result(p, "open", ms_since(t), "ms", name == "large.odin" ? 1500 : 250)
}

@(private = "file")
phase_open_code :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "code.odin")
	return frame == 30
}

@(private = "file")
phase_open_large :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "large.odin")
	return frame == 30
}

@(private = "file")
phase_idle :: proc(p: ^Perf, frame: int) -> bool {
	elapsed := time.tick_since(p.phase_t0)
	if elapsed < PERF_IDLE_NS do return false
	secs := time.duration_seconds(elapsed)
	result(p, "frames per second", f64(frame) / secs, "fps", 5)
	// Process CPU includes other threads (SDL, the GPU driver, the pty reader),
	// so it is noisier than the frames' own time.
	result(p, "process CPU (one core = 100%)", f64(process_cpu_ns() - p.cpu0) / 1e9 / secs * 100, "%", 1.5)
	worst: f64
	for f in p.frames do worst = max(worst, f[.Update] + f[.Render])
	result(p, "frame CPU max", worst, "ms", 2)
	if gpu := gpu_counter_read(&p.gpu); gpu >= 0 do result(p, "GPU utilization", gpu, "%", 2)
	return true
}

// Types 120 characters, one per frame, in the middle of the open file.
@(private = "file")
phase_type :: proc(p: ^Perf, frame: int) -> bool {
	e := &g.editor
	if frame == 0 {
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		set_single_selection(e, {mid, mid, -1})
		e.reveal = true
		return false
	}
	text := "the quick brown fox "
	editor_text_input(e, text[frame % len(text):][:1])
	return frame == 120
}

@(private = "file")
phase_scroll :: proc(p: ^Perf, frame: int) -> bool {
	editor_move(&g.editor, .Page_Down, false)
	return frame == 120
}

// Opens the finder and runs two queries, measuring the second: the first also
// loads the bold font used for matched characters.
@(private = "file")
phase_finder :: proc(p: ^Perf, frame: int) -> bool {
	f := &g.finder
	switch {
	case frame == 0:
		finder_toggle()
		append(&f.query, "large")
		finder_restart_search()
		p.mark_frame = -1
	case finder_busy() || frame < 10:
	case p.mark_frame < 0:
		p.mark_frame = frame
		clear(&p.frames)
		clear(&f.query)
		append(&f.query, "codeodin")
		finder_restart_search()
	case frame < p.mark_frame + 20:
	case:
		check(p, "finds code.odin", len(f.results) > 0 && strings.has_suffix(f.files[f.results[0].file], "code.odin"))
		finder_toggle()
		return true
	}
	return false
}

// Opens the settings window, searches it, moves through the rows and closes it.
@(private = "file")
phase_settings :: proc(p: ^Perf, frame: int) -> bool {
	w := &g.settings_window
	switch frame {
	case 0:
		settings_window_toggle()
	case 1 ..= 4:
		search := "font"
		append(&w.search, search[frame - 1])
	case 5:
		clear(&w.search)
	case 6 ..= 30:
		w.focus, w.reveal = (frame - 6) % max(len(w.items), 1), true
	case:
		file_only := 0
		for info in SETTINGS do if info.name == "" do file_only += 1
		check(p, "lists every setting and command", len(w.items) == len(Command) + len(Setting) - file_only)
		settings_window_toggle()
		return true
	}
	return false
}

// A key press, as if typed.
@(private = "file")
press :: proc(key: sdl.Keycode) {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	handle_key_event(&event)
}

// Opens the settings window and focuses a setting's row (a frame later, once
// the rows exist). Returns true once focused.
@(private = "file")
open_settings_at :: proc(x: Setting, frame: int) -> bool {
	w := &g.settings_window
	if frame == 0 {
		settings_window_toggle()
		return false
	}
	for item, i in w.items do if s, ok := item.(Setting); ok && s == x do w.focus = i
	return true
}

// Opens the theme list, switches to the light themes and moves down through
// them, switches back and moves up through the dark ones (each theme applied as
// it is selected), then cancels back to the settings and closes them.
@(private = "file")
phase_theme_picker :: proc(p: ^Perf, frame: int) -> bool {
	w := &g.settings_window
	darks, lights: int
	first_dark, last_light: string
	for spec in THEMES {
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
		check(p, "Esc restores the theme", g.settings.theme == DEFAULT_THEME && theme == theme_by_name(DEFAULT_THEME))
		settings_window_toggle()
		return !w.open
	}
	return false
}

// Opens the font list, waits for the installed fonts, moves through up to 12
// of them (each loaded as it is selected), then cancels.
@(private = "file")
phase_font_picker :: proc(p: ^Perf, frame: int) -> bool {
	STEPS :: 12
	switch {
	case frame <= 1:
		p.mark_frame = 0
		if open_settings_at(.Font_Family, frame) do press(sdl.K_RETURN)
	case fonts_scanning(&g.fonts):
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
		check(p, "Esc restores the font", g.settings.font_family == BUNDLED_FAMILY)
		settings_window_toggle()
		return true
	}
	return false
}

// Each character is drawn on its own with letter spacing.
@(private = "file")
phase_letter_spacing :: proc(p: ^Perf, frame: int) -> bool {
	switch frame {
	case 0:
		g.settings.letter_spacing = 1
		editor_move(&g.editor, .Doc_Start, false)
	case 120:
		g.settings.letter_spacing = 0
		return true
	case:
		editor_move(&g.editor, .Page_Down, false)
	}
	return false
}

// Jumps to 120 places spread over the file, one per frame.
@(private = "file")
phase_jump_large :: proc(p: ^Perf, frame: int) -> bool {
	e := &g.editor
	scroll_to(e, max_scroll_y(e) * f64(frame) / 120)
	return frame == 120
}

@(private = "file")
phase_long_line :: proc(p: ^Perf, frame: int) -> bool {
	e := &g.editor
	switch frame {
	case 0:
		open_timed(p, "long.js")
	case 1:
		editor_move(e, .Doc_End, false)
	case:
		editor_text_input(e, "x")
	}
	return frame == 60
}

@(private = "file")
phase_terminal_redraw :: proc(p: ^Perf, frame: int) -> bool {
	t := &g.terminal_panel.terminal
	if frame == 0 {
		when ODIN_OS == .Windows {
			set_string(&g.settings.terminal_shell, "cmd.exe /q /k prompt $G")
		} else {
			set_string(&g.settings.terminal_shell, "/bin/sh")
		}
		terminal_toggle_maximized()
		return false
	}
	// Repaint every cell in a new color each frame, like a full-screen program.
	s := &t.session
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "\x1b[H")
	for row in 0 ..< int(s.rows) {
		fmt.sbprintf(&sb, "\x1b[%d;1H", row + 1)
		for col in 0 ..< int(s.cols) {
			fmt.sbprintf(&sb, "\x1b[38;5;%dm%c", (frame + row + col) % 256, 'a' + rune((frame + col) % 26))
		}
	}
	strings.write_string(&sb, "\x1b[0m")
	term.terminal_vt_write(s.vt, raw_data(sb.buf), len(sb.buf))
	return frame == 120
}

// Runs a command that prints a 4 MB file through the real shell and pty, and
// waits until the output has stopped for a second.
@(private = "file")
phase_terminal_output :: proc(p: ^Perf, frame: int) -> bool {
	s := &g.terminal_panel.terminal.session
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
	if !quiet && !timeout do return false
	secs := time.duration_seconds(time.tick_diff(p.phase_t0, p.flood_last))
	result(p, "time until output stops", secs * 1000, "ms", 10_000)
	result(p, "throughput", 4 / secs, "MB/s")
	return true
}
