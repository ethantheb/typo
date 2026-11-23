package editor

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "fuzzy"
import "gfx"

// The finder: a list fuzzy-matched against a query as it is typed, and opened
// at the row chosen. Its source is the workspace's files (Ctrl+E), or what a
// language server listed (lsp_symbols.odin): a file's symbols, the project's
// symbols, or places such as references.
//
// Files open in typo and recently used ones (recent.odin) come first, as in
// VS Code's quick open and Zed's file finder: with no query, the open files
// (most recently used first), then the recent ones, then the shortest paths;
// the focused file is left out, so Enter switches to another. With a query
// they get FINDER_BOOST on their score, so they rank above matches as good or
// a little better, but not above clearly better ones.
//
// Nothing here may block the UI, whatever the folder size:
//  - The file index is built by a background thread that hands paths over in
//    batches (finder_frame drains them); the finder is usable while it runs.
//  - Searching is incremental: each frame scores rows for at most
//    SEARCH_BUDGET, keeping the best, and resumes next frame. New keystrokes
//    restart it; files that arrive later are scored as they come.
//  - Only the rows in view are laid out


// Dependency, build-output and VCS folders, which are huge and rarely wanted
FINDER_IGNORED_DIRS := [?]string {
	".git", ".hg", ".svn", "node_modules", "__pycache__", ".cache", ".zig-cache", "zig-cache",
	"target", ".venv", "venv", ".godot", ".vs", ".idea", ".gradle", ".next",
}

FINDER_MAX_FILES    :: 200_000
FINDER_MAX_RESULTS  :: 50  // files listed for a query, or without one
FINDER_MAX_MATCHES  :: 500 // a server's items listed for a query
FINDER_VISIBLE_ROWS :: 14
FINDER_WIDTH        :: 720
FINDER_ROW_HEIGHT   :: 24
SEARCH_BUDGET       :: 4 * time.Millisecond
FINDER_BOOST        :: 0.5 // added to an open or recent file's score: half a word start

@(private = "file")
KIND_WIDTH :: 46 // a symbol's kind, before its name
@(private = "file")
DEPTH_INDENT :: 14 // per level of a file's outline

// What the finder lists
Finder_Source :: enum {
	Files,
	File_Symbols,      // the focused file's outline
	Workspace_Symbols, // the project's, asked of the server as the query changes
	Locations,         // places, e.g. references or several definitions
}

// A row of a source other than files
Finder_Item :: struct {
	label:  string, // owned; matched against the query
	detail: string, // owned; shown dim after the label, may be ""
	kind:   int,    // a symbol's kind (SymbolKind, 1-26), or 0
	depth:  int,    // nesting in a file's outline
	path:   string, // owned; the file it is in
	line:   int,    // shown with the path (from 0)
	target: Open_Target,
}

Finder :: struct {
	open:      bool,
	opened_at: u64, // frame it was opened on
	query:     Line_Edit,
	selected:  int,
	reveal:    bool,       // scroll the selected row into view, once laid out
	clicked:   Maybe(int), // a row clicked in the list (in `files` or `items`), opened next frame

	// What is listed (`source`: files, or a server's items), and the rows matched
	using search: Search,

	items:     [dynamic]Finder_Item,
	what:      string, // what the items are, for the query field ("references")
	status:    string, // owned; e.g. "Asking ols…", or why nothing is listed

	// Index. `files` is only touched on the main thread; the indexer appends to
	// `shared.pending`, which finder_frame moves over
	indexer:   ^thread.Thread,
	shared:    ^Index_Shared,
	indexing:  bool,
	stale:     bool,            // files changed on disk since indexing began
	files:     [dynamic]string, // full paths, in discovery order
	root_len:  int,             // prefix length to strip for display
}

// A fuzzy search of a source's rows, scored a slice per frame (search_step):
// the finder's, and the sidebar's search field (always the files)
Search :: struct {
	source:  Finder_Source,
	results: [dynamic]Match,  // best matches so far, best first
	scanned: int,             // rows[:scanned] have been scored

	// Open and recent files, listed first (see search_file_rank), by path_key_ascii
	ranked:  map[string]Rank, // keys owned
	current: string,          // owned key of the focused file, or ""
}

// An open or recent file's place at the top of the list
Rank :: struct {
	order: int,  // from 0: open files first, each kind most recently used first
	open:  bool, // open in typo, else recently used
}

Index_Shared :: struct {
	mutex:     sync.Mutex,
	pending:   [dynamic]string,
	done:      bool,
	truncated: bool,
	cancel:    bool, // read with atomics by the indexer
	root:      string,
}

// A row: an index into `files` or `items`
Match :: struct {
	index: int,
	score: f32,
}


// Ctrl+E: opens the files, or closes the finder showing them
finder_toggle :: proc() {
	if g.finder.open && g.finder.source == .Files {
		finder_close()
		return
	}
	finder_open(.Files)
}


// Opens the finder on a source, with an empty query. A server's items come
// later (finder_set_items); `what` names them, e.g. "references"
finder_open :: proc(source: Finder_Source, what := "") {
	f := &g.finder
	if f.open do finder_close()
	g.sidebar_search.open = false // one list of files at a time

	f.open = true
	f.opened_at = g.frame
	f.source = source
	f.what = what
	f.clicked = nil
	line_edit_clear(&f.query)
	set_string(&f.status, "")
	if source == .Files {
		if f.shared == nil do start_indexer()
		search_rank_files(&f.search)
	}
	finder_restart_search()
}


// Gives the finder a server's items (taken), with one selected
finder_set_items :: proc(items: []Finder_Item, selected := 0) {
	f := &g.finder
	clear_items()
	f.clicked = nil
	append(&f.items, ..items)
	set_string(&f.status, "")
	finder_restart_search()

	if selected > 0 && len(f.query.text) == 0 {
		f.selected = selected
		f.reveal = true
	}
}


// Says what the finder is waiting for, or why it lists nothing; "" for nothing
finder_set_status :: proc(status: string) {
	set_string(&g.finder.status, status)
}


finder_close :: proc() {
	f := &g.finder
	if !f.open do return

	if f.source != .Files do lsp_finder_closed()
	f.open = false
	f.clicked = nil
	clear_items()
	clear_ranks(&f.search)
	set_string(&f.status, "")
}


// Drops the index (stopping the indexer); called when the workspace root changes.
// The searches of the files start again
finder_invalidate :: proc() {
	f := &g.finder
	stop_indexer()

	for path in f.files do delete(path)
	clear(&f.files)

	if f.source == .Files do finder_restart_search()
	sidebar_search_restart()
}


// Files were added, removed or renamed on disk: an index built or being built
// is stale. Once any walk under way ends, it is built again if the finder lists
// files, else dropped until needed. Patching the list in place would need a
// lookup by path the finder doesn't keep (removing a folder removes every file
// under it)
finder_files_changed :: proc() {
	f := &g.finder
	if f.shared == nil do return // not indexed yet; built when first needed

	f.stale = true
}


finder_destroy :: proc() {
	finder_invalidate()
	clear_items()
	search_destroy(&g.finder.search)
	delete(g.finder.items)
	delete(g.finder.status)
	delete(g.finder.files)
	line_edit_destroy(&g.finder.query)
	fuzzy.destroy()
}


// Per-frame work, before the panes' frames: take newly indexed files, open a
// row clicked in the last frame, close on a press outside (which does nothing
// else), continue the search, and let the server's source ask what it needs.
// Clicks are handled here rather than in the list's layout, whose rows' strings
// this frame's drawing still uses
finder_frame :: proc() {
	f := &g.finder

	if f.shared != nil && f.indexing {
		sync.guard(&f.shared.mutex)
		append(&f.files, ..f.shared.pending[:])
		clear(&f.shared.pending)
		f.indexing = !f.shared.done
	}

	// Files changed on disk: index again if the files are listed, else drop the
	// index until it is needed
	if f.stale && !f.indexing {
		finder_invalidate()
		finder_lists_files := f.open && f.source == .Files
		if finder_lists_files || g.sidebar_search.open {
			start_indexer()
		}
	}

	if !f.open do return

	if row, was_clicked := f.clicked.?; was_clicked {
		open_row(row)
		return
	}
	if clicked_outside(clay.ID("Finder"), f.opened_at) {
		finder_close()
		g.mouse_pressed = false
		return
	}

	if f.source != .Files do lsp_finder_frame()
	search_step(&f.search, line_edit_string(&f.query))
}


// Indexing, searching, waiting to ask a server, or to scroll to the selected
// row while open: keep drawing frames
finder_busy :: proc() -> bool {
	f := &g.finder
	if !f.open do return false
	if f.reveal do return true

	if f.source == .Files {
		return f.indexing || search_busy(&f.search)
	}
	return search_busy(&f.search) || lsp_finder_busy()
}


// Starts indexing the workspace's files, if it hasn't, for lookups by name
finder_ensure_index :: proc() {
	if g.finder.shared == nil && g.workspace.root != "" {
		start_indexer()
	}
}


finder_display_path :: proc(i: int) -> string {
	path := g.finder.files[i]
	return path[min(g.finder.root_len, len(path)):]
}


@(private = "file")
clear_items :: proc() {
	f := &g.finder
	for item in f.items {
		delete(item.label)
		delete(item.detail)
		delete(item.path)
	}
	clear(&f.items)
}


// Which of `paths` the file index doesn't have; known only once the index is
// complete (built, not stale, not cut short), so a file not in it is gone
finder_unindexed :: proc(paths: []string) -> (missing: []bool, known: bool) {
	f := &g.finder
	complete := f.shared != nil && !f.indexing && !f.stale && !f.shared.truncated
	if !complete do return nil, false

	// The paths by key, then each indexed file looked up
	buf: [PATH_KEY_SIZE]u8
	wanted := make(map[string]int, len(paths), context.temp_allocator)
	for path, i in paths {
		key := strings.clone(path_key_ascii(path, buf[:]), context.temp_allocator)
		wanted[key] = i
	}

	missing = make([]bool, len(paths), context.temp_allocator)
	for &m in missing do m = true
	for file in f.files {
		if i, found := wanted[path_key_ascii(file, buf[:])]; found {
			missing[i] = false
		}
	}
	return missing, true
}


// --- Open and recent files ---------------------------------------------------------

// Ranks the open files, then the recent ones, each most recently used first;
// the focused file is left out
@(private)
search_rank_files :: proc(s: ^Search) {
	clear_ranks(s)

	if e := focused_editor(); e != nil {
		buf: [PATH_KEY_SIZE]u8
		s.current = strings.clone(path_key_ascii(e.path, buf[:]))
	}

	// Open files: the recently used first, then the others as they opened
	recent := recent_files()
	for path in recent {
		if pane_with_file(path) != nil do add_rank(s, path, open = true)
	}
	for p in g.panes.open {
		if e, ok := p.content.(^Editor); ok {
			add_rank(s, e.path, open = true)
		}
	}

	for path in recent do add_rank(s, path, open = false)
}


@(private = "file")
add_rank :: proc(s: ^Search, path: string, open: bool) {
	buf: [PATH_KEY_SIZE]u8
	key := path_key_ascii(path, buf[:])
	if key == s.current || key in s.ranked {
		return
	}

	s.ranked[strings.clone(key)] = {order = len(s.ranked), open = open}
}


@(private = "file")
clear_ranks :: proc(s: ^Search) {
	for key in s.ranked do delete(key)
	clear(&s.ranked)

	delete(s.current)
	s.current = ""
}


// An indexed file's rank, if it is open or recent; and whether it is the
// focused file
@(private)
search_file_rank :: proc(s: ^Search, i: int) -> (rank: Rank, ranked, current: bool) {
	if len(s.ranked) == 0 && s.current == "" {
		return
	}

	buf: [PATH_KEY_SIZE]u8
	key := path_key_ascii(g.finder.files[i], buf[:])
	rank, ranked = s.ranked[key]
	return rank, ranked, key == s.current
}


// Room for most paths' keys on the stack
@(private = "file")
PATH_KEY_SIZE :: 512



// --- Background indexer ------------------------------------------------------------

@(private = "file")
Walk_State :: struct {
	shared: ^Index_Shared,
	batch:  [dynamic]string,
	count:  int,
}


@(private = "file")
start_indexer :: proc() {
	f := &g.finder
	f.root_len = len(strings.trim_right(g.workspace.root, "/\\")) + 1
	f.shared = new(Index_Shared)
	f.shared.root = strings.clone(g.workspace.root)
	f.indexing = true

	// The default context: its heap allocator is thread-safe, and the thread's
	// temp memory is freed as it ends (it is started again whenever files change)
	f.indexer = thread.create_and_start_with_poly_data(f.shared, index_files)
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
	f.stale = false
}


// Runs on the indexer thread. Paths are allocated with the default heap
// allocator (thread-safe) and owned by the main thread once handed over
@(private = "file")
index_files :: proc(shared: ^Index_Shared) {
	st := Walk_State{shared = shared, batch = make([dynamic]string, 0, 512)}
	defer delete(st.batch)

	walk_files(shared.root, FINDER_IGNORED_DIRS[:], &shared.cancel, &st, visit_file)
	flush_batch(&st)

	sync.guard(&shared.mutex)
	shared.done = true
}


// Hands the batch over to the main thread
@(private = "file")
flush_batch :: proc(st: ^Walk_State) {
	sync.guard(&st.shared.mutex)
	append(&st.shared.pending, ..st.batch[:])
	clear(&st.batch)
}


// Adds a file to the batch; stops the walk at FINDER_MAX_FILES
@(private = "file")
visit_file :: proc(path: string, user: rawptr) -> bool {
	st := (^Walk_State)(user)
	if st.count >= FINDER_MAX_FILES {
		st.shared.truncated = true
		return false
	}

	append(&st.batch, strings.clone(path))
	st.count += 1
	if len(st.batch) >= 512 do flush_batch(st)
	return true
}


// --- Incremental search ------------------------------------------------------------

// Resets the search for a new query; finder_frame does the actual work (once
// per frame, however many keystrokes arrived)
finder_restart_search :: proc() {
	search_restart(&g.finder.search)
	g.finder.selected = 0
}


// Forgets a search's results, to score the rows again
@(private)
search_restart :: proc(s: ^Search) {
	clear(&s.results)
	s.scanned = 0
}


@(private)
search_destroy :: proc(s: ^Search) {
	clear_ranks(s)
	delete(s.ranked)
	delete(s.results)
	s^ = {}
}


// Whether rows are left to score
@(private)
search_busy :: proc(s: ^Search) -> bool {
	return s.scanned < row_count(s)
}


// How many rows the source has
@(private = "file")
row_count :: proc(s: ^Search) -> int {
	return s.source == .Files ? len(g.finder.files) : len(g.finder.items)
}


// Scores more rows against the query, within SEARCH_BUDGET
@(private)
search_step :: proc(s: ^Search, query: string) {
	count := row_count(s)

	// No query: a server's items in order
	if len(query) == 0 && s.source != .Files {
		for s.scanned < count {
			append(&s.results, Match{s.scanned, 0})
			s.scanned += 1
		}
		return
	}

	start := time.tick_now()
	for s.scanned < count {
		// Check the clock every 32 rows (long paths can take ~20 µs each in
		// debug builds)
		end := min(s.scanned + 32, count)
		for i in s.scanned ..< end {
			if score, ok := score_row(s, query, i); ok {
				insert_result(s, Match{i, score})
			}
		}

		s.scanned = end
		if time.tick_since(start) > SEARCH_BUDGET do break
	}
}


// How well a row matches: a file's path (ranked up if open or recent); an
// item's label, or for a place, the file it is in
@(private = "file")
score_row :: proc(s: ^Search, query: string, i: int) -> (score: f32, ok: bool) {
	if s.source == .Files do return score_file(s, query, i)

	item := g.finder.items[i]
	score, ok = fuzzy.score(query, item.label)
	if s.source != .Locations do return

	path_score, in_path := fuzzy.score(query, item_path(item))
	if in_path && (!ok || path_score > score) {
		score, ok = path_score, true
	}
	return
}


// A file's score. With no query, open and recent files score by their order
// above every other file (all 0) and the focused file isn't listed; with one,
// they get FINDER_BOOST
@(private = "file")
score_file :: proc(s: ^Search, query: string, i: int) -> (score: f32, ok: bool) {
	if len(query) == 0 {
		rank, ranked, current := search_file_rank(s, i)
		if current do return 0, false
		if ranked do return f32(len(s.ranked) - rank.order), true
		return 0, true
	}

	score, ok = fuzzy.score(query, finder_display_path(i))
	if !ok do return

	if _, ranked, _ := search_file_rank(s, i); ranked {
		score += FINDER_BOOST
	}
	return
}


// Keeps results sorted best-first and capped
@(private = "file")
insert_result :: proc(s: ^Search, m: Match) {
	n := len(s.results)
	limit := s.source == .Files ? FINDER_MAX_RESULTS : FINDER_MAX_MATCHES
	if n == limit && !better_match(s, m, s.results[n - 1]) {
		return
	}

	pos := n
	for pos > 0 && better_match(s, m, s.results[pos - 1]) {
		pos -= 1
	}

	if n < limit {
		inject_at(&s.results, pos, m)
	} else {
		copy(s.results[pos + 1:], s.results[pos:n - 1])
		s.results[pos] = m
	}
}


// A higher score; on the same score, a shorter path, or the item listed first
@(private = "file")
better_match :: proc(s: ^Search, a, b: Match) -> bool {
	if a.score != b.score do return a.score > b.score

	if s.source == .Files {
		files := g.finder.files
		return len(files[a.index]) < len(files[b.index])
	}
	return a.index < b.index
}


// Keys while the finder is open; it takes them all: the query field's, the
// list's, and shortcuts that don't act on the pane behind it (Ctrl+E closes)
finder_handle_event :: proc(event: ^sdl.Event) -> bool {
	f := &g.finder
	if !f.open do return false

	if handled, changed := line_edit_event(&f.query, event); handled {
		if changed {
			finder_restart_search()
			if f.source == .Workspace_Symbols do lsp_finder_query_changed()
		}
		return true
	}
	if event.type != .KEY_DOWN do return true

	last := len(f.results) - 1
	switch event.key.key {
	case sdl.K_ESCAPE:
		finder_close()
	case sdl.K_UP:
		move_selection(max(f.selected - 1, 0))
	case sdl.K_DOWN:
		move_selection(min(f.selected + 1, last))
	case sdl.K_PAGEUP:
		move_selection(max(f.selected - FINDER_VISIBLE_ROWS, 0))
	case sdl.K_PAGEDOWN:
		move_selection(min(f.selected + FINDER_VISIBLE_ROWS, last))
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		finder_accept(f.selected)
	case:
		cmd, is_command := command_for_key(event.key)
		if is_command && field_lets_through(cmd) {
			run_command(cmd)
		}
	}
	return true
}


@(private = "file")
move_selection :: proc(to: int) {
	g.finder.selected = max(to, 0)
	finder_scroll_to_selected()
}


// Opens the result `index` (Enter)
@(private = "file")
finder_accept :: proc(index: int) {
	f := &g.finder
	if index < 0 || index >= len(f.results) {
		return
	}
	open_row(f.results[index].index)
}


// Opens a row of the source: a file, or the place an item is at; then closes
@(private = "file")
open_row :: proc(row: int) {
	f := &g.finder
	if row >= 0 && row < row_count(&f.search) {
		if f.source == .Files {
			g.pending = Open_File(strings.clone(f.files[row]))
		} else if item := f.items[row]; item.path != "" {
			jump_to(item.path, item.target)
		}
	}
	finder_close()
}


// Scrolls the selected row into view, or to the middle of it
@(private = "file")
finder_scroll_to_selected :: proc(center := false) {
	scroll := clay.GetScrollContainerData(clay.ID("FinderResults"))
	if !scroll.found do return

	if !center {
		list_reveal_row(scroll, g.finder.selected, FINDER_ROW_HEIGHT)
		return
	}

	// scrollPosition is negative: content offset upward
	top := f32(g.finder.selected) * FINDER_ROW_HEIGHT
	view := scroll.scrollContainerDimensions.height
	total := f32(len(g.finder.results)) * FINDER_ROW_HEIGHT
	lowest := -max(total - view, 0)
	scroll.scrollPosition.y = clamp(-(top - (view - FINDER_ROW_HEIGHT) / 2), lowest, 0)
}


// An item's file, from the workspace's folder if it is in it
@(private = "file")
item_path :: proc(item: Finder_Item) -> string {
	root := strings.trim_right(g.workspace.root, "/\\")
	inside := root != "" && len(item.path) > len(root) && strings.has_prefix(item.path, root)
	if !inside do return item.path

	return strings.trim_left(item.path[len(root):], "/\\")
}


// --- UI ----------------------------------------------------------------------------

finder_ui :: proc() {
	f := &g.finder
	if !f.open do return

	panel := clay.ID("Finder")
	if modal(panel, FINDER_WIDTH, clay.SizingFit(), 64, clay.PaddingAll(6), 6) {
		text_field(clay.ID("FinderInput"), &f.query, query_hint(), true)
		finder_results()
	}
}


// What the query field says while empty
@(private = "file")
query_hint :: proc() -> string {
	f := &g.finder
	switch f.source {
	case .Files:             return "Search files by name"
	case .File_Symbols:      return "Go to a symbol in this file"
	case .Workspace_Symbols: return "Search the project's symbols"
	case .Locations:
		if len(f.items) == 0 do return fmt.tprintf("Filter %s", f.what)
		return fmt.tprintf("Filter %d %s", len(f.items), f.what)
	}
	return ""
}


@(private = "file")
finder_results :: proc() {
	f := &g.finder
	defer status_line()

	// Nothing to list: say why
	if len(f.results) == 0 {
		if clay.UI()({
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(FINDER_ROW_HEIGHT)},
				padding = {left = 10},
				childAlignment = {y = .Center},
			},
		}) {
			label(empty_message(), gfx.theme.text_dim)
		}
		return
	}

	// Only the rows in view (and one more) are laid out, between spacers
	list := clay.ID("FinderResults")
	scroll := clay.GetScrollContainerData(list)
	if f.reveal && scroll.found {
		finder_scroll_to_selected(center = true)
		f.reveal = false
	}
	first := 0
	if scroll.found {
		first = int(-scroll.scrollPosition.y / FINDER_ROW_HEIGHT)
		first = clamp(first, 0, len(f.results))
	}
	last := min(first + FINDER_VISIBLE_ROWS + 1, len(f.results))

	rows := min(len(f.results), FINDER_VISIBLE_ROWS)
	wheel_scroll_list(list)
	if clay.UI(list)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(f32(rows) * FINDER_ROW_HEIGHT)},
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, horizontal = true, childOffset = clay.GetScrollOffset()},
	}) {
		query := line_edit_string(&f.query)
		rows_spacer(first)
		for i in first ..< last {
			m := f.results[i]
			chosen: bool
			if f.source == .Files {
				path := finder_display_path(m.index)
				rank, ranked, _ := search_file_rank(&f.search, m.index)
				mark := ""
				if ranked {
					mark = rank.open ? "open" : "recent"
				}
				chosen = finder_row(i, path, query, i == f.selected, mark)
			} else {
				chosen = item_row(i, f.items[m.index], query, i == f.selected)
			}
			if chosen do f.clicked = m.index
		}
		rows_spacer(len(f.results) - last)
	}
}


// Room for rows not laid out
@(private = "file")
rows_spacer :: proc(rows: int) {
	if rows <= 0 do return

	height := f32(rows) * FINDER_ROW_HEIGHT
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(height)}}}) {}
}


// Why nothing is listed
@(private = "file")
empty_message :: proc() -> string {
	f := &g.finder
	searching := search_busy(&f.search)

	if f.source == .Files {
		switch {
		case f.indexing || searching: return "Searching…"
		case len(f.files) == 0:       return "No files in this folder"
		}
		return "No matching files"
	}

	switch {
	case f.status != "":   return f.status
	case searching:        return "Searching…"
	case len(f.query.text) > 0: return "No matches"
	}
	if f.source == .Workspace_Symbols do return "Type to search the project's symbols"
	return "Nothing found"
}


// A line under the rows: indexing or searching files, or a server's status
@(private = "file")
status_line :: proc() {
	f := &g.finder
	file_count := len(f.files)
	truncated := f.shared != nil && !f.indexing && f.shared.truncated

	msg: string
	if f.source == .Files {
		switch {
		case f.indexing:                  msg = fmt.tprintf("Indexing… %d files so far", file_count)
		case truncated:                   msg = fmt.tprintf("Index stopped at %d files", file_count)
		case f.scanned < len(f.files):    msg = fmt.tprintf("Searching %d files…", file_count)
		}
	} else if len(f.results) > 0 {
		msg = f.status
	}
	if msg == "" do return

	if clay.UI()({layout = {padding = {left = 10, bottom = 2}}}) {
		label(msg, gfx.theme.text_dim, 12)
	}
}


// A file: its name, its folder, and "open" or "recent" (`mark`) at the right
@(private = "file")
finder_row :: proc(index: int, path, query: string, selected: bool, mark: string) -> bool {
	id := clay.ID("FinderRow", u32(index))
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(FINDER_ROW_HEIGHT)},
			padding = {left = 10, right = 10},
			childAlignment = {y = .Center},
		},
		backgroundColor = finder_row_color(selected),
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		// File name first, then its directory, with matched characters highlighted
		slash := strings.last_index_any(path, "/\\")
		matched := fuzzy.positions(query, path, context.temp_allocator)
		highlighted_text(path, slash + 1, len(path), matched, gfx.theme.text_bright)
		if slash > 0 {
			spacer_x(10)
			highlighted_text(path, 0, slash, matched, gfx.theme.text_dim)
		}

		if mark != "" {
			push_right()
			spacer_x(10)
			label(mark, gfx.theme.text_faint, FONT_SIZE_SMALL)
		}
	}
	return clicked(id, clay.ID("FinderResults"))
}


// A server's item: its kind, its label (indented in a file's outline; code,
// for a place) and detail, then the file and line it is at
@(private = "file")
item_row :: proc(index: int, item: Finder_Item, query: string, selected: bool) -> bool {
	f := &g.finder
	id := clay.ID("FinderRow", u32(index))
	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(FINDER_ROW_HEIGHT)},
			padding = {left = 10, right = 10},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = finder_row_color(selected),
		cornerRadius = clay.CornerRadiusAll(3),
	}) {
		if item.kind > 0 {
			name, color := symbol_kind(item.kind)
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(KIND_WIDTH)}}}) {
				label(name, color, FONT_SIZE_SMALL)
			}
		}

		// The label and detail, cut off before the file
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
			clip = row_clip(),
		}) {
			outline := f.source == .File_Symbols && len(query) == 0
			if outline && item.depth > 0 {
				spacer_x(f32(item.depth * DEPTH_INDENT))
			}

			font := f.source == .Locations ? gfx.Font_Id.Editor : gfx.Font_Id.Body
			matched := fuzzy.positions(query, item.label, context.temp_allocator)
			bright := gfx.theme.text_bright
			highlighted_text(item.label, 0, len(item.label), matched, bright, font)
			if item.detail != "" {
				spacer_x(10)
				label(item.detail, gfx.theme.text_dim, FONT_SIZE_SMALL)
			}
		}

		// The file and line, for places in other files
		if f.source != .File_Symbols {
			path := item_path(item)
			at := fmt.tprintf("%s:%d", path, item.line + 1)
			matched := f.source == .Locations ? fuzzy.positions(query, path) : nil
			highlighted_text(at, 0, len(at), matched, gfx.theme.text_dim)
		}
	}
	return clicked(id, clay.ID("FinderResults"))
}


// A row's background. Called in the row's declaration, where clay.Hovered()
// is the row's
@(private = "file")
finder_row_color :: proc(selected: bool) -> clay.Color {
	if selected do return gfx.theme.selected
	return clay.Hovered() ? gfx.theme.hover : {}
}


// Emits s[lo:hi] as runs of plain and highlighted text; `matched` may cover
// less of s
@(private)
highlighted_text :: proc(
	s: string,
	lo, hi: int,
	matched: []bool,
	color: clay.Color,
	font := gfx.Font_Id.Body,
	size: u16 = FONT_SIZE_UI,
) {
	bold := font == .Editor ? gfx.Font_Id.Editor_Bold : gfx.Font_Id.Bold
	i := lo
	for i < hi {
		hl := i < len(matched) && matched[i]

		j := i + 1
		for j < hi && (j < len(matched) && matched[j]) == hl {
			j += 1
		}

		label(s[i:j], hl ? gfx.theme.accent : color, size, hl ? bold : font)
		i = j
	}
}
