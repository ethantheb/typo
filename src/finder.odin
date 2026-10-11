package editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"

// Ctrl+E file finder: fuzzy-matches a query against every file under the
// workspace root.
//
// Nothing here may block the UI, whatever the folder size:
//  - The file index is built by a background thread that hands paths over in
//    batches (finder_frame drains them); the finder is usable while it runs.
//  - Searching is incremental: each frame scores files for at most
//    SEARCH_BUDGET, keeping the best FINDER_MAX_RESULTS, and resumes next frame.
//    New keystrokes restart it; files that arrive later are scored as they come.

// Dependency, build-output and VCS folders, which are huge and rarely wanted.
FINDER_IGNORED_DIRS := [?]string {
	".git", ".hg", ".svn", "node_modules", "__pycache__", ".cache", ".zig-cache", "zig-cache",
	"target", ".venv", "venv", ".godot", ".vs", ".idea", ".gradle", ".next",
}
FINDER_MAX_FILES :: 200_000
FINDER_MAX_RESULTS :: 50
FINDER_VISIBLE_ROWS :: 14
FINDER_WIDTH :: 640
FINDER_ROW_HEIGHT :: 24
SEARCH_BUDGET :: 4 * time.Millisecond

Finder :: struct {
	open:       bool,
	query:      [dynamic]u8,
	selected:   int,

	// Index. `files` is only touched on the main thread; the indexer appends to
	// `shared.pending`, which finder_frame moves over.
	indexer:    ^thread.Thread,
	shared:     ^Index_Shared,
	indexing:   bool,
	files:      [dynamic]string, // full paths, in discovery order
	root_len:   int,             // prefix length to strip for display

	// Search state for the current query.
	results:    [dynamic]Match, // best matches so far, best first
	scanned:    int,            // files[:scanned] have been scored
}

Index_Shared :: struct {
	mutex:     sync.Mutex,
	pending:   [dynamic]string,
	done:      bool,
	truncated: bool,
	cancel:    bool, // read with atomics by the indexer
	root:      string,
}

Match :: struct {
	file:  int,
	score: f32,
}

finder_toggle :: proc() {
	if g.finder.open {
		finder_close()
		return
	}
	if g.finder.shared == nil do start_indexer()
	g.finder.open = true
	clear(&g.finder.query)
	finder_restart_search()
}

finder_close :: proc() {
	g.finder.open = false
}

// Drops the index (stopping the indexer); called when the workspace root changes.
finder_invalidate :: proc() {
	f := &g.finder
	stop_indexer()
	for path in f.files do delete(path)
	clear(&f.files)
	clear(&f.results)
	f.scanned = 0
}

finder_destroy :: proc() {
	finder_invalidate()
	delete(g.finder.files)
	delete(g.finder.results)
	delete(g.finder.query)
	delete(scratch)
}

// Per-frame work: take newly indexed files and continue the search.
finder_frame :: proc() {
	f := &g.finder
	if f.shared != nil && f.indexing {
		sync.guard(&f.shared.mutex)
		append(&f.files, ..f.shared.pending[:])
		clear(&f.shared.pending)
		f.indexing = !f.shared.done
	}
	if f.open do continue_search()
}

finder_status :: proc() -> (indexing: bool, files: int, truncated: bool) {
	f := &g.finder
	truncated = f.shared != nil && !f.indexing && f.shared.truncated
	return f.indexing, len(f.files), truncated
}

finder_display_path :: proc(i: int) -> string {
	path := g.finder.files[i]
	return path[min(g.finder.root_len, len(path)):]
}

// --- Background indexer -----------------------------------------------------------

@(private = "file")
start_indexer :: proc() {
	f := &g.finder
	f.root_len = len(strings.trim_right(g.workspace.root, "/\\")) + 1
	f.shared = new(Index_Shared)
	f.shared.root = strings.clone(g.workspace.root)
	f.indexing = true
	f.indexer = thread.create_and_start_with_poly_data(f.shared, index_files, init_context = runtime.default_context())
}

@(private = "file")
stop_indexer :: proc() {
	f := &g.finder
	if f.shared == nil do return
	sync.atomic_store(&f.shared.cancel, true)
	thread.join(f.indexer)
	thread.destroy(f.indexer)
	for path in f.shared.pending do delete(path)
	delete(f.shared.pending)
	delete(f.shared.root)
	free(f.shared)
	f.shared = nil
	f.indexer = nil
	f.indexing = false
}

// Runs on the indexer thread. Paths are allocated with the default heap
// allocator (thread-safe) and owned by the main thread once handed over.
@(private = "file")
index_files :: proc(shared: ^Index_Shared) {
	Walk_State :: struct {
		shared: ^Index_Shared,
		batch:  [dynamic]string,
		count:  int,
	}
	flush :: proc(st: ^Walk_State) {
		sync.guard(&st.shared.mutex)
		append(&st.shared.pending, ..st.batch[:])
		clear(&st.batch)
	}
	visit :: proc(path: string, user: rawptr) -> bool {
		st := (^Walk_State)(user)
		if st.count >= FINDER_MAX_FILES {
			st.shared.truncated = true
			return false
		}
		append(&st.batch, strings.clone(path))
		st.count += 1
		if len(st.batch) >= 512 do flush(st)
		return true
	}

	st := Walk_State{shared = shared, batch = make([dynamic]string, 0, 512)}
	defer delete(st.batch)
	walk_files(shared.root, FINDER_IGNORED_DIRS[:], &shared.cancel, &st, visit)
	flush(&st)
	sync.guard(&shared.mutex)
	shared.done = true
}

// --- Incremental search -------------------------------------------------------------

// Resets the search for a new query; finder_frame does the actual work (once
// per frame, however many keystrokes arrived).
finder_restart_search :: proc() {
	f := &g.finder
	clear(&f.results)
	f.scanned = 0
	f.selected = 0
}

// Scores more files against the query, within SEARCH_BUDGET.
@(private = "file")
continue_search :: proc() {
	f := &g.finder
	query := string(f.query[:])
	if len(query) == 0 {
		// No query: just list the first files found.
		for len(f.results) < FINDER_MAX_RESULTS && f.scanned < len(f.files) {
			append(&f.results, Match{f.scanned, 0})
			f.scanned += 1
		}
		return
	}

	start := time.tick_now()
	for f.scanned < len(f.files) {
		// Check the clock every 32 files (long paths can take ~20 µs each in debug builds).
		end := min(f.scanned + 32, len(f.files))
		for i in f.scanned ..< end {
			if score, ok := fuzzy_score(query, finder_display_path(i)); ok {
				insert_result(f, Match{i, score})
			}
		}
		f.scanned = end
		if time.tick_since(start) > SEARCH_BUDGET do break
	}
}

// Keeps results sorted best-first and capped at FINDER_MAX_RESULTS.
@(private = "file")
insert_result :: proc(f: ^Finder, m: Match) {
	better :: proc(a, b: Match) -> bool {
		if a.score != b.score do return a.score > b.score
		return len(g.finder.files[a.file]) < len(g.finder.files[b.file])
	}
	n := len(f.results)
	if n == FINDER_MAX_RESULTS && !better(m, f.results[n - 1]) do return
	pos := n
	for pos > 0 && better(m, f.results[pos - 1]) do pos -= 1
	if n < FINDER_MAX_RESULTS {
		inject_at(&f.results, pos, m)
	} else {
		copy(f.results[pos + 1:], f.results[pos:n - 1])
		f.results[pos] = m
	}
}

// Returns true if the event was consumed by the finder.
finder_handle_event :: proc(event: ^sdl.Event) -> bool {
	f := &g.finder
	if !f.open do return false

	#partial switch event.type {
	case .TEXT_INPUT:
		append(&f.query, string(event.text.text))
		finder_restart_search()
		return true

	case .KEY_DOWN:
		switch event.key.key {
		case sdl.K_ESCAPE:
			finder_close()
		case sdl.K_BACKSPACE:
			if len(f.query) > 0 {
				if event.key.mod & sdl.KMOD_CTRL != {} {
					clear(&f.query)
				} else {
					_, size := utf8.decode_last_rune(f.query[:])
					resize(&f.query, len(f.query) - size)
				}
				finder_restart_search()
			}
		case sdl.K_UP:
			f.selected = max(f.selected - 1, 0)
			finder_scroll_to_selected()
		case sdl.K_DOWN:
			f.selected = min(f.selected + 1, len(f.results) - 1)
			finder_scroll_to_selected()
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			finder_accept(f.selected)
		case:
			// Let global shortcuts (e.g. Ctrl+E to close) through.
			return false
		}
		return true
	}
	return false
}

@(private = "file")
finder_accept :: proc(index: int) {
	if index < 0 || index >= len(g.finder.results) do return
	g.pending = Open_File(strings.clone(g.finder.files[g.finder.results[index].file]))
	finder_close()
}

@(private = "file")
finder_scroll_to_selected :: proc() {
	scroll := clay.GetScrollContainerData(clay.ID("FinderResults"))
	if !scroll.found do return
	top := f32(g.finder.selected) * FINDER_ROW_HEIGHT
	view := scroll.scrollContainerDimensions.height
	// scrollPosition is negative: content offset upward.
	if top < -scroll.scrollPosition.y {
		scroll.scrollPosition.y = -top
	} else if top + FINDER_ROW_HEIGHT > -scroll.scrollPosition.y + view {
		scroll.scrollPosition.y = -(top + FINDER_ROW_HEIGHT - view)
	}
}

// --- UI -----------------------------------------------------------------------

finder_ui :: proc() {
	f := &g.finder
	if !f.open do return
	g.in_modal = true
	defer g.in_modal = false

	// Full-window backdrop; clicking it closes the finder.
	if clay.UI(clay.ID("FinderBackdrop"))({
		layout = {
			sizing = {clay.SizingFixed(f32(g.window_w)), clay.SizingFixed(f32(g.window_h))},
			childAlignment = {x = .Center},
			padding = {top = 64},
		},
		backgroundColor = theme.backdrop,
		floating = {attachTo = .Root, zIndex = 100},
	}) {
		if clay.UI(clay.ID("Finder"))({
			layout = {
				sizing = {clay.SizingFixed(min(FINDER_WIDTH, f32(g.window_w) - 32)), clay.SizingFit()},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(6),
				childGap = 6,
			},
			backgroundColor = theme.panel,
			cornerRadius = clay.CornerRadiusAll(6),
			border = {color = theme.border, width = clay.BorderOutside(1)},
		}) {
			finder_input()
			finder_results()
		}

		clicked_outside := g.mouse_pressed && !pointer_in(clay.ID("Finder"))
		if clicked_outside do finder_close()
	}
}

@(private = "file")
finder_input :: proc() {
	f := &g.finder
	if clay.UI(clay.ID("FinderInput"))({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(30)},
			padding = {left = 10, right = 10},
			childAlignment = {y = .Center},
		},
		backgroundColor = theme.bg,
		cornerRadius = clay.CornerRadiusAll(4),
		border = {color = theme.accent, width = clay.BorderOutside(1)},
	}) {
		if len(f.query) == 0 {
			text_caret()
			label("Search files by name", theme.text_dim)
		} else {
			label(string(f.query[:]), theme.text_bright)
			text_caret()
		}
	}
}


@(private = "file")
finder_results :: proc() {
	f := &g.finder
	indexing, file_count, truncated := finder_status()
	searching := f.scanned < len(f.files)
	defer finder_status_line(indexing, searching, file_count, truncated)

	if len(f.results) == 0 {
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(FINDER_ROW_HEIGHT)}, padding = {left = 10}, childAlignment = {y = .Center}}}) {
			msg := "No matching files"
			if indexing || searching {
				msg = "Searching…"
			} else if file_count == 0 {
				msg = "No files in this folder"
			}
			label(msg, theme.text_dim)
		}
		return
	}

	rows := min(len(f.results), FINDER_VISIBLE_ROWS)
	if clay.UI(clay.ID("FinderResults"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(f32(rows) * FINDER_ROW_HEIGHT)}, layoutDirection = .TopToBottom},
		clip = {vertical = true, horizontal = true, childOffset = clay.GetScrollOffset()},
	}) {
		query := string(f.query[:])
		for m, i in f.results {
			if finder_row(i, finder_display_path(m.file), query, i == f.selected) {
				finder_accept(i)
			}
		}
	}
}

@(private = "file")
finder_status_line :: proc(indexing, searching: bool, file_count: int, truncated: bool) {
	msg: string
	switch {
	case indexing:  msg = fmt.tprintf("Indexing… %d files so far", file_count)
	case truncated: msg = fmt.tprintf("Index stopped at %d files", file_count)
	case searching: msg = fmt.tprintf("Searching %d files…", file_count)
	case:           return
	}
	if clay.UI()({layout = {padding = {left = 10, bottom = 2}}}) {
		label(msg, theme.text_dim, 12)
	}
}

@(private = "file")
finder_row :: proc(index: int, path: string, query: string, selected: bool) -> (clicked: bool) {
	id := clay.ID("FinderRow", u32(index))
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(FINDER_ROW_HEIGHT)},
			padding = {left = 10, right = 10},
			childAlignment = {y = .Center},
		},
		backgroundColor = selected ? theme.selected : (clay.Hovered() ? theme.hover : {}),
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		clicked = g.mouse_pressed && pointer_in(id) && pointer_in(clay.ID("FinderResults"))

		// File name first, then its directory, with matched characters highlighted.
		slash := strings.last_index_any(path, "/\\")
		matched := fuzzy_positions(query, path, context.temp_allocator)
		highlighted_text(path, slash + 1, len(path), matched, theme.text_bright)
		if slash > 0 {
			spacer_x(10)
			highlighted_text(path, 0, slash, matched, theme.text_dim)
		}
	}
	return
}

// Emits s[lo:hi] as runs of plain and highlighted text.
@(private = "file")
highlighted_text :: proc(s: string, lo, hi: int, matched: []bool, color: clay.Color) {
	i := lo
	for i < hi {
		hl := len(matched) > 0 && matched[i]
		j := i + 1
		for j < hi && (len(matched) > 0 && matched[j]) == hl do j += 1
		label(s[i:j], hl ? theme.accent : color, FONT_SIZE_UI, hl ? .Bold : .Body)
		i = j
	}
}

// --- Fuzzy matching -----------------------------------------------------------
// A small fzy-style scorer: the query must appear as a case-insensitive
// subsequence; consecutive matches and matches at word/path boundaries score
// higher, gaps cost a little. Byte-based, which is fine for typical file names.

@(private = "file") SCORE_GAP_LEADING :: -0.005
@(private = "file") SCORE_GAP_TRAILING :: -0.005
@(private = "file") SCORE_GAP_INNER :: -0.01
@(private = "file") SCORE_MATCH_CONSECUTIVE :: 1.0
@(private = "file") SCORE_MATCH_SLASH :: 0.9
@(private = "file") SCORE_MATCH_WORD :: 0.8
@(private = "file") SCORE_MATCH_CAPITAL :: 0.7
@(private = "file") SCORE_MATCH_DOT :: 0.6
@(private = "file") SCORE_MIN :: min(f32)
@(private = "file") MAX_MATCH_LEN :: 512

@(private = "file")
lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private = "file")
bonus :: proc(prev, c: u8) -> f32 {
	switch prev {
	case '/', '\\':
		return SCORE_MATCH_SLASH
	case '-', '_', ' ':
		return SCORE_MATCH_WORD
	case '.':
		return SCORE_MATCH_DOT
	}
	if prev >= 'a' && prev <= 'z' && c >= 'A' && c <= 'Z' do return SCORE_MATCH_CAPITAL
	return 0
}

@(private = "file")
is_subsequence :: proc(needle, haystack: string) -> bool #no_bounds_check {
	i := 0
	for j in 0 ..< len(haystack) {
		if i < len(needle) && lower(needle[i]) == lower(haystack[j]) do i += 1
	}
	return i == len(needle)
}

// D[i*m+j]: best score with needle[i] matched exactly at haystack[j].
// M[i*m+j]: best score for needle[:i+1] within haystack[:j+1].
@(private = "file")
compute :: proc(needle, haystack: string, D, M: []f32) #no_bounds_check {
	n, m := len(needle), len(haystack)
	for i in 0 ..< n {
		prev_score: f32 = SCORE_MIN
		gap: f32 = i == n - 1 ? SCORE_GAP_TRAILING : SCORE_GAP_INNER
		prev_char: u8 = '/'
		for j in 0 ..< m {
			c := haystack[j]
			if lower(needle[i]) == lower(c) {
				score: f32 = SCORE_MIN
				b := bonus(prev_char, c)
				if i == 0 {
					score = f32(j) * SCORE_GAP_LEADING + b
				} else if j > 0 {
					score = max(M[(i - 1) * m + j - 1] + b, D[(i - 1) * m + j - 1] + SCORE_MATCH_CONSECUTIVE)
				}
				D[i * m + j] = score
				prev_score = max(score, prev_score + gap)
			} else {
				D[i * m + j] = SCORE_MIN
				prev_score = prev_score + gap
			}
			M[i * m + j] = prev_score
			prev_char = c
		}
	}
}

// Score matrices are reused across calls; matching runs on the main thread only.
@(private = "file")
scratch: [dynamic]f32

@(private = "file")
matrices :: proc(n, m: int) -> (D, M: []f32) {
	if len(scratch) < 2 * n * m do resize(&scratch, 2 * n * m)
	return scratch[:n * m], scratch[n * m:2 * n * m]
}

fuzzy_score :: proc(needle, haystack: string) -> (score: f32, ok: bool) {
	if len(needle) == 0 do return 0, true
	if len(needle) > len(haystack) || len(haystack) > MAX_MATCH_LEN do return 0, false
	if !is_subsequence(needle, haystack) do return 0, false
	if len(needle) == len(haystack) do return max(f32), true

	n, m := len(needle), len(haystack)
	D, M := matrices(n, m)
	compute(needle, haystack, D, M)
	return M[(n - 1) * m + m - 1], true
}

// Which bytes of haystack the best match used, for highlighting.
fuzzy_positions :: proc(needle, haystack: string, allocator := context.temp_allocator) -> []bool {
	if len(needle) == 0 || len(haystack) > MAX_MATCH_LEN || !is_subsequence(needle, haystack) do return nil
	n, m := len(needle), len(haystack)
	D, M := matrices(n, m)
	compute(needle, haystack, D, M)

	matched := make([]bool, m, allocator)
	match_required := false
	j := m - 1
	for i := n - 1; i >= 0; i -= 1 {
		for ; j >= 0; j -= 1 {
			// Take this position if the best score came from matching here, or
			// if the previous pick was part of a consecutive run that requires it.
			d := D[i * m + j]
			if d != SCORE_MIN && (match_required || d == M[i * m + j]) {
				match_required = i > 0 && j > 0 && M[i * m + j] == D[(i - 1) * m + j - 1] + SCORE_MATCH_CONSECUTIVE
				matched[j] = true
				j -= 1
				break
			}
		}
	}
	return matched
}
