package editor

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "markdown"
import "syntax"
import "term"
import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "gfx"
import "textedit"
import "mdview"

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
	md_text:    string, // generated Markdown
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
	window_size:  [2]i32, // before a resizing phase
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
	{name = "markdown", step = phase_markdown},
	{name = "fuzzy file search", step = phase_fuzzy},
	{name = "terminal emulation", step = phase_vt},
	{name = "open code file (tree-sitter)", step = phase_open_code, frame_limit = 8},
	{name = "idle with a file open", step = phase_idle, idle = true},
	{name = "typing (tree-sitter)", step = phase_type, frame_limit = 8},
	{name = "clicking places the caret", step = phase_click_caret},
	{name = "scrolling (tree-sitter)", step = phase_scroll, frame_limit = 8},
	{name = "resizing the window (tree-sitter)", step = phase_resize, frame_limit = 8},
	{name = "open Markdown (rendered)", step = phase_open_markdown, frame_limit = 8},
	{name = "scrolling Markdown (rendered)", step = phase_scroll, frame_limit = 8},
	{name = "typing in Markdown (rendered)", step = phase_type, frame_limit = 8},
	{name = "clicking places the caret (rendered)", step = phase_click_caret},
	{name = "moving through a table and code block (rendered)", step = phase_move_markdown, frame_limit = 8},
	{name = "typing above a long table (rendered)", step = phase_type_above_table, frame_limit = 8},
	{name = "typing in a long table's cell (rendered)", step = phase_type_in_table, frame_limit = 8},
	{name = "resizing the window, Markdown (rendered)", step = phase_resize, frame_limit = 8},
	{name = "spaces and tabs in Markdown (rendered)", step = phase_md_whitespace},
	{name = "file finder", step = phase_finder, frame_limit = 8},
	{name = "settings window", step = phase_settings, frame_limit = 8},
	{name = "context menu and dialogs", step = phase_menu_dialogs},
	{name = "theme list (every theme)", step = phase_theme_picker, frame_limit = 8},
	{name = "font list", step = phase_font_picker, frame_limit = 25},
	{name = "scrolling with letter spacing", step = phase_letter_spacing, frame_limit = 8},
	{name = "open 64 MB file (lexer)", step = phase_open_large, frame_limit = 8},
	{name = "jumping through 64 MB file", step = phase_jump_large, frame_limit = 12},
	{name = "typing in 64 MB file", step = phase_type, frame_limit = 8},
	{name = "8 MB single-line file", step = phase_long_line, frame_limit = 25},
	{name = "terminal full-screen redraws", step = phase_terminal_redraw, frame_limit = 12},
	{name = "terminal shell output (4 MB)", step = phase_terminal_output, frame_limit = 16},
	{name = "typing beside other panes (tree-sitter)", step = phase_panes_typing, frame_limit = 8},
	{name = "moving panes", step = phase_panes_moving, frame_limit = 8},
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
	delete(p.md_text)
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
	font := gfx.text_get_font(&gfx.text_system, .Body, PERF_FONT_SIZE)
	result(p, "open a new font size", ms_since(t), "ms", 5)
	t = time.tick_now()
	_ = gfx.text_get(&gfx.text_system, font, "→ ✓ 漢字")
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

// A long table followed by a long code block, its lines wider than the column.
@(private = "file")
generate_markdown_blocks :: proc() -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, "# Blocks\n\nSome text.\n\n| name | value | note |\n|---|:-:|--:|\n")
	for i in 0 ..< 300 do fmt.sbprintf(&sb, "| row %d | **%d** | `x` |\n", i, i)
	strings.write_string(&sb, "\n```odin\n")
	for i in 0 ..< 1500 do fmt.sbprintf(&sb, "value_%d := compute(%d, \"a line long enough to scroll sideways in its box\") // %d\n", i, i, i)
	strings.write_string(&sb, "```\n")
	return strings.to_string(sb)
}

@(private = "file")
phase_generate :: proc(p: ^Perf, frame: int) -> bool {
	t := time.tick_now()
	p.code_text = generate_code(400 << 10)
	p.large_text = generate_code(64 << 20)
	p.md_text = generate_markdown(4 << 20)
	_ = os.write_entire_file(path_in_dir(p, "notes.md"), p.md_text)
	blocks := generate_markdown_blocks()
	_ = os.write_entire_file(path_in_dir(p, "blocks.md"), transmute([]u8)blocks)
	delete(blocks)
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
	fmt.printfln("  %-36s %10s ms", "generated 80 MB in 5 files", fmt.tprintf("%.3f", ms_since(t)))
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

@(private = "file")
phase_markdown :: proc(p: ^Perf, frame: int) -> bool {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(p.md_text))
	defer buffer.buffer_destroy(&b)
	doc: markdown.Doc
	defer markdown.doc_destroy(&doc)
	t := time.tick_now()
	markdown.doc_open(&doc, &b)
	markdown.doc_update(&doc, &b, max(int), time.Hour)
	result(p, fmt.tprintf("block parse (%d MB)", len(p.md_text) >> 20), ms_since(t), "ms", 40)

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

	// Text view highlighting: blocks, inlines and fenced code for 60 lines.
	end := buffer.line_start(&b, mid_line + 60)
	hl := make([]syntax.Highlight, end - mid, context.temp_allocator)
	styles := make([]markdown.Text_Styles, end - mid, context.temp_allocator)
	RUNS :: 20
	t = time.tick_now()
	for _ in 0 ..< RUNS do markdown.highlight_range(&doc, &b, mid, hl, styles)
	result(p, "highlight one screen", ms_since(t) / RUNS, "ms", 0.5)

	// An unclosed fence turns the rest of the file into code: the visible part
	// is parsed at once, the rest in later frames.
	buffer.begin(&b, .Other, EDITS, {})
	buffer.replace(&b, mid, 0, "```\n")
	buffer.end(&b, {})
	markdown.doc_edit(&doc, buffer.take_changes(&b))
	t = time.tick_now()
	markdown.doc_update(&doc, &b, mid_line + 60 + markdown.LOOKAHEAD_LINES, markdown.PARSE_BUDGET)
	result(p, "re-parse after opening a fence (frame)", ms_since(t), "ms", 3)
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

// Opens a file as the only one open.
@(private = "file")
open_timed :: proc(p: ^Perf, name: string) {
	close_files()
	t := time.tick_now()
	panes_open_file(path_in_dir(p, name))
	result(p, "open", ms_since(t), "ms", name == "large.odin" ? 1500 : 250)
}

// Closes every file without asking about changes.
@(private = "file")
close_files :: proc() {
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		if _, ok := g.panes.open[i].content.(^Editor); ok do pane_close(g.panes.open[i], ask = false)
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

// Moves the caret down a line per frame, from a long table into a long code block.
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
// edit drops the caches of the document, the table's measured columns too.
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
// measures the table's columns again, and the caret is kept in the cell.
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
	check(p, "typed text is in the cell", strings.count(row, "|") == 4 && strings.count(row, "more words") >= 10)
	return true
}

// A space or tab typed after a heading, on a blank line and after a paragraph
// moves the caret, measured with the real fonts.
@(private = "file")
phase_md_whitespace :: proc(p: ^Perf, frame: int) -> bool {
	if frame > 0 do return true
	e := focused_editor()
	moves :: proc(e: ^Editor, line: int, key: sdl.Keycode) -> bool {
		settle :: proc(e: ^Editor) {
			textedit.take_changes(e)
			markdown.doc_update(e.md, &e.buf, max(int), time.Hour)
		}
		at := buffer.line_end(&e.buf, line)
		textedit.set_single_selection(e, {at, at, -1})
		before := mdview.caret_at(&e.md_view, at).x
		if key == sdl.K_SPACE {
			editor_text_input(e, " ")
		} else {
			editor_handle_key(e, {key = key})
		}
		settle(e)
		after := mdview.caret_at(&e.md_view, e.sels[0].head).x
		textedit.undo(e)
		settle(e)
		return after > before
	}
	check(p, "space after a heading", moves(e, 0, sdl.K_SPACE))
	check(p, "tab after a heading", moves(e, 0, sdl.K_TAB))
	check(p, "space on a blank line", moves(e, 1, sdl.K_SPACE))
	check(p, "tab on a blank line", moves(e, 1, sdl.K_TAB))
	check(p, "space after a paragraph", moves(e, 2, sdl.K_SPACE))
	check(p, "tab after a paragraph", moves(e, 2, sdl.K_TAB))
	return false
}

@(private = "file")
phase_open_large :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "large.odin")
	return frame == 30
}

@(private = "file")
phase_idle :: proc(p: ^Perf, frame: int) -> bool {
	// Nothing else wakes an idle app, so a timer ends the phase.
	if frame == 0 do _ = sdl.AddTimer(u32(PERF_IDLE_NS / time.Millisecond) + 20, idle_over, nil)
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

@(private = "file")
idle_over :: proc "c" (userdata: rawptr, id: sdl.TimerID, interval: u32) -> u32 {
	wake_main_loop(nil)
	return 0 // one-shot
}

// Types 120 characters, one per frame, in the middle of the open file.
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

@(private = "file")
phase_scroll :: proc(p: ^Perf, frame: int) -> bool {
	textedit.move(focused_editor(), .Page_Down, false)
	return frame == 120
}

// Narrows the window 10 pixels a frame for 60 frames, then widens it back.
// Rendered Markdown first only re-centers its column, then rewraps every frame.
@(private = "file")
phase_resize :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do _ = sdl.GetWindowSize(g.window, &p.window_size.x, &p.window_size.y)
	step := i32(frame <= 60 ? frame : 120 - frame)
	_ = sdl.SetWindowSize(g.window, p.window_size.x - 10 * step, p.window_size.y)
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

// Opens the settings window, searches it, moves through the rows, scrolls it with
// the wheel (over a row's label, and over a horizontally clipped element such
// as an input box, which is a Clay scroll container of its own), and closes it
// while the list may still be easing.
@(private = "file")
phase_settings :: proc(p: ^Perf, frame: int) -> bool {
	WHEEL_FRAMES :: 10
	w := &g.settings_window
	@(static) scrolled, start: int
	@(static) mouse: [2]f32
	switch {
	case frame == 0:
		settings_window_toggle()
		scrolled, start = 0, 0
	case frame <= 4:
		search := "font"
		append(&w.search, search[frame - 1])
	case frame == 5:
		clear(&w.search)
	case frame <= 30:
		w.focus, w.reveal = (frame - 6) % max(len(w.items), 1), true
	// The pointer reaches elements only once they stop moving.
	case start == 0 && g.animating:
	case start == 0 || frame < start + 2 * WHEEL_FRAMES:
		if start == 0 do start = frame
		list := clay.ID("SettingsList")
		data := clay.GetScrollContainerData(list)
		r, ok := element_rect(list)
		if !data.found || !ok do break
		// From the top of the list: the second step finds where to point, from
		// the layout scrolled back by the first.
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
		for info in SETTINGS do if info.name == "" do file_only += 1
		check(p, "lists every setting and command", len(w.items) == len(Command) + len(Setting) - file_only)
		settings_window_toggle()
		return true
	}
	return false
}

// A point in `r` over an element that clips only horizontally.
@(private = "file")
clipped_point :: proc(r: gfx.Rect) -> (at: [2]f32, found: bool) {
	defer clay.SetPointerState(g.mouse_pos, g.mouse_down)
	for y := r.y + 4; y < r.y + r.h; y += 6 {
		for x := r.x + 4; x < r.x + r.w - SCROLLBAR_GUTTER; x += 12 {
			clay.SetPointerState({x, y}, false)
			ids := clay.GetPointerOverIds()
			for id in ids.internalArray[:ids.length] {
				data := clay.GetScrollContainerData(id)
				if data.found && data.config.horizontal && !data.config.vertical do return {x, y}, true
			}
		}
	}
	return
}

// Right-clicks a file in the tree, picks Rename, types a new name in place of
// the selected one (the name before the extension) and presses Enter; then
// edits that file and closes it, answering "Don't save"; then makes a new file
// from the menu under the files. The menu, the fields and the dialog stay up
// for a moment so the window can be looked at.
@(private = "file")
phase_menu_dialogs :: proc(p: ^Perf, frame: int) -> bool {
	SHOW :: 700 * time.Millisecond
	@(static) step: int
	@(static) since: time.Tick
	@(static) mouse: [2]f32
	@(static) before: string // the file open before, reopened at the end
	old, renamed, created := path_in_dir(p, "rename_me.txt"), path_in_dir(p, "renamed.txt"), path_in_dir(p, "created.txt")
	moved, never := path_in_dir(p, "zzz_created.txt"), path_in_dir(p, "never.txt")
	wait :: proc(since: time.Tick) -> bool {return time.tick_since(since) < SHOW}
	center :: proc(id: clay.ElementId) -> (c: [2]f32, ok: bool) {
		r := element_rect(id) or_return
		return {r.x + r.w / 2, r.y + r.h / 2}, true
	}
	if frame == 0 {
		step, mouse = 0, g.mouse_pos
		if e := focused_editor(); e != nil do before = strings.clone(e.path)
		g.sidebar_visible = true
		_ = os.write_entire_file(old, transmute([]u8)string("before"))
		_ = os.remove(renamed)
		_ = os.remove(moved)
		workspace_refresh(&g.workspace)
		return false
	}
	d := &g.dialog
	switch step {
	case 0: // right-click the file's row
		for index in g.workspace.visible {
			if g.workspace.nodes[index].path != old do continue
			at, ok := center(tree_row_id(old))
			if !ok do return false
			g.mouse_pos, g.right_pressed = at, true
			step, since = 1, time.tick_now()
		}
		if step == 0 && frame > 10 {
			check(p, "the file is in the tree", false)
			return true
		}
	case 1: // the menu is open; click Rename
		if wait(since) do return false
		check(p, "right-click opens the menu", g.menu.open && g.menu.items[0].cmd == .Rename_File)
		at, _ := center(clay.ID("MenuItem", 0))
		g.mouse_pos, g.mouse_pressed = at, true
		step, since = 2, time.tick_now()
	case 2: // the name is editable in the tree, without its extension selected
		if wait(since) do return false
		r := &g.rename
		lo, hi := min(r.edit.caret, r.edit.anchor), max(r.edit.caret, r.edit.anchor)
		check(p, "Rename edits the name in the tree", r.active && r.place == .Tree && r.shown && line_edit_string(&r.edit) == "rename_me.txt" && lo == 0 && hi == len("rename_me"))
		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "renamed"
		handle_key_event(&event)
		press(sdl.K_RETURN)
		step = 3
	case 3: // renamed; now leave unsaved changes in it and close it
		check(p, "typing replaces the name and Enter renames", !g.rename.active && os.exists(renamed) && !os.exists(old))
		pane := panes_open_file(renamed)
		editor_text_input(focused_editor(), "x")
		run_command(.Close_Pane)
		_, asking := d.purpose.(Unsaved_Step)
		check(p, "closing unsaved changes asks", d.open && asking && pane_shown(pane))
		step, since = 4, time.tick_now()
	case 4: // Tab to "Don't save", Enter
		if wait(since) do return false
		press(sdl.K_TAB)
		press(sdl.K_RETURN)
		step = 5
	case 5: // right-click under the files
		data, _ := os.read_entire_file(renamed, context.temp_allocator)
		check(p, "\"Don't save\" closes without saving", !d.open && pane_with_file(renamed) == nil && string(data) == "before")
		_ = os.remove(created)
		r, _ := element_rect(clay.ID("SidebarFiles"))
		g.mouse_pos, g.right_pressed = {r.x + 40, r.y + r.h - 10}, true
		step = 6
	case 6: // New file
		check(p, "right-click under the files offers New file", g.menu.open && g.menu.items[0].cmd == .New_File && g.menu.path == g.workspace.root)
		at, _ := center(clay.ID("MenuItem", 0))
		g.mouse_pos, g.mouse_pressed = at, true
		step, since = 7, time.tick_now()
	case 7: // name it in the new row
		if wait(since) do return false
		check(p, "New file adds a row to name it in", g.rename.active && g.rename.create == .File && g.rename.shown)
		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = "created.txt"
		handle_key_event(&event)
		press(sdl.K_RETURN)
		step = 8
	case 8: // rename it so that it sorts after renamed.txt, and click that row
		check(p, "Enter creates the file and opens it", !g.rename.active && os.exists(created) && pane_with_file(created) != nil)
		rename_start_file(created, .Tree)
		line_edit_set(&g.rename.edit, "zzz_created.txt", 0, 0)
		step, since = 9, time.tick_now()
	case 9:
		if wait(since) do return false
		at, _ := center(tree_row_id(renamed))
		g.mouse_pos, g.mouse_pressed, g.mouse_down, g.mouse_clicks = at, true, true, 1
		step = 10
	case 10:
		g.mouse_down = false
		step, since = 11, time.tick_now()
	case 11: // with the rename open, right-click a row, then a dialog comes up
		if wait(since) do return false
		e := focused_editor()
		check(p, "a click that ends a rename opens the row clicked", os.exists(moved) && e != nil && e.path == renamed)
		at, _ := center(tree_row_id(renamed))
		g.mouse_pos, g.right_pressed = at, true
		step = 12
	case 12:
		check(p, "right-click opens the menu again", g.menu.open)
		rename_start_file(renamed, .Tree)
		line_edit_set(&g.rename.edit, "never.txt", 0, 0)
		ask_reset_settings()
		check(p, "a dialog closes the context menu", d.open && !g.menu.open)
		// The pointer over text, where it would be an I-beam.
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
		if wait(since) do return false
		check(p, "the pointer is an arrow over the dialog", current_cursor == .DEFAULT)
		at, _ := center(clay.ID("DialogButton", 1))
		g.mouse_pos, g.mouse_pressed = at, true
		step = 14
	case 14:
		if d.open do return false
		check(p, "a click on the dialog doesn't end the rename", g.rename.active && os.exists(renamed) && !os.exists(never))
		press(sdl.K_ESCAPE)
		check(p, "Esc ends the rename", !g.rename.active && os.exists(renamed))
		check(p, "a name Windows can't use is refused", ODIN_OS != .Windows || (rename_path(renamed, "a:b") != "" && rename_path(renamed, "nul.txt") != "" && os.exists(renamed)))

		// A maximized pane gives way to a pane that is focused.
		ps := &g.panes
		a := ps.focused // renamed.txt
		b := pane_for_file(moved)
		pane_move(b, {kind = .Split, target = a, side = .Right})
		pane_focus(b)
		pane_toggle_maximized()
		pane_focus(a)
		check(p, "focusing another pane restores the maximized one", ps.maximized == nil && ps.focused == a)
		pane_toggle_maximized()
		pane_focus_next()
		check(p, "focusing the next pane keeps it maximized", ps.maximized == b && ps.focused == b)
		ps.maximized = nil
		pane_close(b, ask = false)

		g.mouse_pos = mouse
		if before != "" do panes_open_file(before)
		delete(before)
		before = ""
		return true
	}
	return false
}

// Presses in the text with the caret at the start, holds the button, drags,
// and lets go: the caret moves and shows on the press itself, hides while
// dragging, and shows again on release.
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
		check(p, "a press moves the caret and shows it", e.sels[e.primary].head != 0 && editor_caret_on(e))
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
		check(p, "Esc restores the theme", g.settings.theme == gfx.DEFAULT_THEME && gfx.theme == gfx.theme_by_name(gfx.DEFAULT_THEME))
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

// Each character is drawn on its own with letter spacing.
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

// Jumps to 120 places spread over the file, one per frame.
@(private = "file")
phase_jump_large :: proc(p: ^Perf, frame: int) -> bool {
	e := focused_editor()
	textedit.scroll_to(e, max_scroll_y(e) * f64(frame) / 120)
	return frame == 120
}

@(private = "file")
phase_long_line :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 {
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
	return frame == 60
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
	t := focused_terminal()
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
	if !quiet && !timeout do return false
	secs := time.duration_seconds(time.tick_diff(p.phase_t0, p.flood_last))
	result(p, "time until output stops", secs * 1000, "ms", 10_000)
	result(p, "throughput", 4 / secs, "MB/s")
	return true
}

// Code and Markdown side by side above the terminal; types in the code once
// the panes have settled.
@(private = "file")
phase_panes_typing :: proc(p: ^Perf, frame: int) -> bool {
	ps := &g.panes
	if frame == 0 {
		ps.maximized = nil
		perf_panes.terminal = ps.focused
		close_files()
		perf_panes.code = panes_open_file(path_in_dir(p, "code.odin"))
		perf_panes.notes = pane_for_file(path_in_dir(p, "notes.md"))
		pane_move(perf_panes.notes, {kind = .Split, target = perf_panes.code, side = .Right})
		pane_focus(perf_panes.code)
		e := focused_editor()
		textedit.show_caret(e, true)
		mid := buffer.line_start(&e.buf, buffer.line_count(&e.buf) / 2)
		textedit.set_single_selection(e, {mid, mid, -1})
		e.reveal = true
		p.mark_frame = -1
		return false
	}
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
	step:     int,
	animated: int, // steps that animated
}

// Moves the panes of phase_panes_typing, each move once the last has settled:
// the terminal docks at the right, the sidebar hides and comes back, the files
// swap, one is maximized and restored, one leaves the layout and comes back,
// and the focus moves.
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
		check(p, "three panes shown", pane_shown(pp.code) && pane_shown(pp.notes) && pane_shown(pp.terminal))
		check(p, "every move animates", pp.animated == STEPS)
		return true
	}
	pp.step += 1
	p.mark_frame = frame
	return false
}
