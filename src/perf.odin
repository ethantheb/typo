package editor

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "buffer"
import "fuzzy"
import "langs"
import "lsp"
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
	frame_t0:         time.Tick,           // when the current frame's work began
	marks:            [Frame_Part]time.Tick,
	first_present_ns: i64,

	gpu:              Gpu_Counter,
	results:          int,
	failures:         [dynamic]string,
	window_size:      [2]i32, // before a resizing phase

	// Terminal output phase
	flood_parsed:     u64,
	flood_last:       time.Tick,
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
	idle:        bool, // let the app sleep between frames
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
	{name = "moving lines", step = phase_move_lines},
	{name = "find in a file (tree-sitter)", step = phase_find, frame_limit = 8},
	{name = "scrolling (tree-sitter)", step = phase_scroll, frame_limit = 8},
	{name = "resizing the window (tree-sitter)", step = phase_resize, frame_limit = 8},
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
	{name = "file finder", step = phase_finder, frame_limit = 8},
	{name = "settings window", step = phase_settings, frame_limit = 8},
	{name = "settings sections collapsing", step = phase_settings_collapse, frame_limit = 8},
	{name = "context menu and dialogs", step = phase_menu_dialogs},
	{name = "theme list (every theme)", step = phase_theme_picker, frame_limit = 8},
	{name = "font list", step = phase_font_picker, frame_limit = 25},
	{name = "scrolling with letter spacing", step = phase_letter_spacing, frame_limit = 8},
	{name = "open 64 MB file (lexer)", step = phase_open_large, frame_limit = 8},
	{name = "jumping through 64 MB file", step = phase_jump_large, frame_limit = 12},
	{name = "typing in 64 MB file", step = phase_type, frame_limit = 8},
	{name = "find in 64 MB file", step = phase_find, frame_limit = 12},
	{name = "8 MB single-line file", step = phase_long_line, frame_limit = 25},
	{name = "terminal full-screen redraws", step = phase_terminal_redraw, frame_limit = 12},
	{name = "terminal shell output (4 MB)", step = phase_terminal_output, frame_limit = 16},
	{name = "find in the terminal", step = phase_find_terminal, frame_limit = 16},
	{
		name        = "typing beside other panes (tree-sitter)",
		step        = phase_panes_typing,
		frame_limit = 8,
	},
	{name = "moving panes", step = phase_panes_moving, frame_limit = 8},
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
	for f in p.failures do delete(f)
	delete(p.failures)
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
		append(&p.lsp_times, time.duration_milliseconds(langs.state.ui_time))
	}
	langs.state.ui_time = 0

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

	gpu_counter_start(&p.gpu) // first: querying the counters costs CPU time
	p.phase_t0 = time.tick_now()
	p.cpu0 = process_cpu_ns()
}


@(private = "file")
finish_phase :: proc(p: ^Perf) {
	phase := PHASES[p.phase]
	if phase.lsp_limit > 0 {
		worst := slice.max(p.lsp_times[:]) if len(p.lsp_times) > 0 else 0
		result(p, "language servers, UI thread, worst", worst, "ms", phase.lsp_limit)
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
@(private = "file")
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

// Opens a file as the only one open
@(private = "file")
open_timed :: proc(p: ^Perf, name: string) {
	close_files()

	t := time.tick_now()
	panes_open_file(path_in_dir(p, name))
	result(p, "open", ms_since(t), "ms", name == "large.odin" ? 1500 : 250)
}


// Closes every file without asking about changes
@(private = "file")
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
phase_open_large :: proc(p: ^Perf, frame: int) -> bool {
	if frame == 0 do open_timed(p, "large.odin")
	return frame == 30
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


@(private = "file")
phase_scroll :: proc(p: ^Perf, frame: int) -> bool {
	textedit.move(focused_editor(), .Page_Down, false)
	return frame == 120
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
		found := len(f.results) > 0 &&
		         strings.has_suffix(f.files[f.results[0].index], "code.odin")
		check(p, "finds code.odin", found)
		finder_toggle()
		return true
	}
	return false
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
		append(&w.search, search[frame - 1])

	case frame == 5:
		clear(&w.search)

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
		append(&w.search, "font")
		next_step(p, &step, frame)

	case 6: // then Expand all
		if waited < 2 do return false

		found := count_items(Setting) > 0 && count_items(Section) == 0
		check(p, "a search shows settings in collapsed sections", found)
		clear(&w.search)
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
	case 0: // right-click the file's row
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

		menu_open := g.menu.open && g.menu.items[0].cmd == .Rename_File
		check(p, "right-click opens the menu", menu_open)
		at, _ := element_center(clay.ID("MenuItem", 0))
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

		pane := panes_open_file(renamed)
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
		b := pane_for_file(moved)
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
		if before != "" do panes_open_file(before)
		delete(before)
		before = ""
		return true
	}
	return false
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
		perf_panes.code = panes_open_file(path_in_dir(p, "code.odin"))
		perf_panes.notes = pane_for_file(path_in_dir(p, "notes.md"))
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
		fake := lsp.find_executable(PERF_FAKE_SERVER, context.temp_allocator)
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
		lh := f64(editor_line_height())
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
// with its line, pages through them, goes to one, and Go back returns
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

	case 7: // page through them, then go to one
		if waited < 60 {
			press(sdl.K_PAGEDOWN)
			return false
		}

		row := f.results[f.selected].index
		chosen, _ = f.items[row].target.(int)
		press(sdl.K_RETURN)
		step, p.mark_frame, step_at = 8, frame, time.tick_now()

	case 8: // there; then back
		there := e.sels[e.primary].head == chosen && chosen > from
		if !there && waited_ms < 1000 {
			return false
		}

		check(p, "Enter goes to a reference", there && !f.open)
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
// item's documentation comes; Enter inserts it. "(" shows the signature, a
// comma moves to the next parameter, ")" closes it. A snippet goes in as text
// with its placeholder selected; an item's import goes in with it, and one undo
// takes both back; Esc closes the list
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
		press(sdl.K_RETURN)
		step, p.mark_frame = 3, frame

	case 3: // inserted once; then a call
		line, _ := caret_line(e)
		check(p, "Enter inserts it", line == "\titem_42" && !cs.open)
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
// keys and Delete puts it back; a server is added and removed; and Install runs
// a server's install command (the fake server copying itself onto PATH) in a
// terminal, after which that server starts
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
		fake := lsp.find_executable(PERF_FAKE_SERVER, context.temp_allocator)
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
		perf_server("fake", fake, "")
		perf_server("fake-install", "fake-install", fmt.tprintf("%s --copy-to %s", fake, target))

		// And one whose program is a path too long to show whole
		perf_server("fake-far", "fake-far", "")
		far_name := strings.repeat("far", 40, context.temp_allocator)
		far, _ := os.join_path({bin, far_name, far_name}, context.temp_allocator)
		langs.server_override(&g.settings.servers, "fake-far").path = strings.clone(far)
		settings_changed()

		focused = g.panes.focused
		terminals = count_terminals()
		settings_window_toggle()
		append(&w.search, "fake")
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
		clear(&w.search)
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
		append(&w.search, "fake")
		next_step(p, &step, frame)

	case 11: // Install
		if waited < 2 do return false
		click_element(clay.ID("ServerInstall", u32(server_row_index("fake-install"))))
		next_step(p, &step, frame)

	case 12: // a terminal runs it, and once it is found the server starts
		last := g.panes.open[len(g.panes.open) - 1]
		opened := count_terminals() == terminals + 1 && is_terminal(last) && !w.open
		if !opened && waited < 10 {
			return false
		}

		check(p, "Install runs it in a terminal", opened)
		if opened do install_pane = last
		next_step(p, &step, frame)

	case 13:
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

	case 14: // once the terminal's frame and the servers have gone
		gone := !g.animating && len(langs.state.retiring) == 0
		if !gone && waited < 600 {
			return false
		}
		settled = time.tick_now()
		next_step(p, &step, frame)

	case 15: // and the terminal left has redrawn at its new size
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
// on PATH
@(private = "file")
perf_server :: proc(name, program, install: string) {
	o := langs.server_override(&g.settings.servers, name)
	o.command = make([]string, 1)
	o.command[0] = strings.clone(program)
	o.languages = make([]string, 1)
	o.languages[0] = strings.clone("odin")
	if install != "" do o.install = strings.clone(install)
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
