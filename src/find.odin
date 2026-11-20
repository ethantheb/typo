package editor

import "core:fmt"
import "core:strings"
import "core:text/regex"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import "buffer"
import "gfx"
import "textedit"

// Find in a pane (Ctrl+F): a small bar at the pane's top right with the query,
// the match count, the options and the buttons. In an editor, shown as text or
// rendered, the matches are found in the buffer a slice per frame, so even
// huge files stay responsive; they are drawn behind the text (View.marks) and
// the current one is selected. Terminals search with libghostty (find_term)


Find_Option :: enum {
	Match_Case,
	Whole_Word,
	Regex,
}

Find :: struct {
	open:     bool,
	pane:     ^Pane, // the pane searched
	typing:   bool,  // the field has the keys (see find_has_keys)
	edit:     Line_Edit,
	options:  bit_set[Find_Option],

	// The search in an editor
	query:    string, // owned; what `matches` are for
	searched: bit_set[Find_Option],
	version:  u64,    // the buffer version they are for
	matches:  [dynamic][2]int,
	current:  int,    // index into matches, or -1
	scanned:  int,    // document offset searched up to
	done:     bool,
	capped:   bool,   // stopped at FIND_MAX_MATCHES
	invalid:  bool,   // the query isn't a valid regular expression
	jump:     bool,   // select the first match at or after `anchor` once found
	anchor:   int,
	marked:   ^Editor, // the editor showing the matches

	// The search in a terminal
	term:     Find_Term,
}

FIND_PLAIN_BYTES :: 4 << 20   // searched per frame without a regular expression
FIND_REGEX_BYTES :: 256 << 10 // with one
FIND_MAX_MATCHES :: 100_000
FIND_FIELD_WIDTH :: 200

// Commands the field takes itself while typing; other shortcuts still work
@(private = "file")
FIND_COMMANDS :: bit_set[Command]{
	.Find,
	.Find_Next,
	.Find_Previous,
	.Find_Match_Case,
	.Find_Whole_Word,
	.Find_Regex,
}


// --- Opening and closing -----------------------------------------------------------

// Opens the bar on the focused pane, with the selection as the query if it is
// on one line. Returns false if no pane is focused
find_open :: proc() -> bool {
	p := g.panes.focused
	if p == nil do return false

	f := &g.find
	if f.open && f.pane != p {
		find_close()
	}

	f.open = true
	f.pane = p
	f.typing = true

	// The selection becomes the query
	if e, ok := p.content.(^Editor); ok && e.status == .Text {
		s := e.sels[e.primary]
		lo, hi := textedit.sel_lo(s), textedit.sel_hi(s)
		if lo < hi && hi - lo < 1000 {
			text := string(buffer.read_alloc(&e.buf, lo, hi))
			if !strings.contains_any(text, "\r\n") {
				line_edit_set(&f.edit, text, 0, len(text))
			}
		}
	}

	// The whole query is selected, so typing replaces it
	line_edit_select_all(&f.edit)

	find_restart(f, jump = true)
	return true
}


find_close :: proc() {
	f := &g.find
	if !f.open do return

	if f.marked != nil do f.marked.marks = nil
	find_term_close(f)

	f.open = false
	f.pane = nil
	f.marked = nil
	f.typing = false
}


find_destroy :: proc() {
	find_close()
	find_term_destroy(&g.find)

	delete(g.find.query)
	delete(g.find.matches)
	line_edit_destroy(&g.find.edit)
}


// Whether the pointer is over the bar, which keeps what is under it from
// taking the mouse (see ui_interactive)
find_bar_covers_pointer :: proc() -> bool {
	return g.find.open && pointer_in(clay.ID("FindBar"))
}


// Whether keys go to the field: it was last given them, and its pane is the
// focused one
find_has_keys :: proc() -> bool {
	f := &g.find
	return f.open && f.typing && f.pane == g.panes.focused
}


// --- Per frame ---------------------------------------------------------------------

// Before the panes' frames: the field's keyboard focus follows the focused pane,
// and the search takes its next step
find_frame :: proc() {
	f := &g.find
	if !f.open do return

	// A press in the pane outside the bar gives the keys to the pane (a press
	// on the field gives them back: find_field)
	pressed := g.mouse_pressed || g.right_pressed
	if pressed && ui_interactive() && pointer_in(pane_id(f.pane)) {
		f.typing = false
	}

	// Focusing another pane takes the keys from the field for good; the bar
	// stays on its pane until the field is clicked or Find runs elsewhere
	if f.pane != g.panes.focused do f.typing = false

	switch c in f.pane.content {
	case ^Editor:   find_editor_frame(f, c)
	case ^Terminal: find_term_frame(f, c)
	}
}


// Whether the search still has work for the coming frames
find_busy :: proc() -> bool {
	f := &g.find
	if !f.open do return false

	switch c in f.pane.content {
	case ^Editor:   return !f.done && !f.invalid && f.query != ""
	case ^Terminal: return find_term_busy(f)
	}
	return false
}


@(private = "file")
find_editor_frame :: proc(f: ^Find, e: ^Editor) {
	if e.status != .Text do return

	// A new query or options start over, from the caret; an edit starts over
	// keeping the selection
	query := line_edit_string(&f.edit)
	if query != f.query || f.options != f.searched {
		find_restart(f, jump = true)
	} else if e.buf.version != f.version {
		find_restart(f, jump = false)
	}

	find_scan(f, e)
	find_settle_current(f, e)

	f.marked = e
	e.marks = f.matches[:]
}


// Starts the search over. With `jump`, the first match at or after the
// selection is selected once found; without, the match that is the selection
// (after an edit) becomes the current one
@(private)
find_restart :: proc(f: ^Find, jump: bool) {
	delete(f.query)
	f.query = strings.clone(line_edit_string(&f.edit))
	f.searched = f.options

	clear(&f.matches)
	f.current = -1
	f.scanned = 0
	f.done = false
	f.capped = false
	f.invalid = false
	f.jump = jump
	f.anchor = 0

	switch c in f.pane.content {
	case ^Editor:
		if c.status != .Text do return
		f.version = c.buf.version
		f.anchor = textedit.sel_lo(c.sels[c.primary])
		f.invalid = .Regex in f.options && !regex_compiles(f.query, f.options)

	case ^Terminal:
		find_term_restart(f, c)
	}
}


// Picks the current match: the first one at or after the anchor, or the one
// that is the selection
@(private = "file")
find_settle_current :: proc(f: ^Find, e: ^Editor) {
	if f.current >= 0 || len(f.matches) == 0 {
		return
	}

	if f.jump {
		i := first_match_from(f, f.anchor)
		if i < len(f.matches) {
			find_select(f, e, i)
		} else if f.done {
			find_select(f, e, 0) // wrapped around
		}
		return
	}

	// After an edit: the selection, if it is still a match
	s := e.sels[e.primary]
	i := first_match_from(f, textedit.sel_lo(s))
	if i < len(f.matches) && f.matches[i] == {textedit.sel_lo(s), textedit.sel_hi(s)} {
		f.current = i
	}
}


// Index of the first match starting at or after `offset`
@(private = "file")
first_match_from :: proc(f: ^Find, offset: int) -> int {
	lo, hi := 0, len(f.matches)
	for lo < hi {
		mid := (lo + hi) / 2
		if f.matches[mid][0] < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}


// Selects match i and scrolls to it
@(private = "file")
find_select :: proc(f: ^Find, e: ^Editor, i: int) {
	f.current = i
	f.jump = false

	m := f.matches[i]
	textedit.show_caret(e, false)
	textedit.set_single_selection(e, {m[0], m[1], -1})
	e.reveal = true
}


// --- Searching an editor -----------------------------------------------------------

// Searches the next slice of the document
@(private = "file")
find_scan :: proc(f: ^Find, e: ^Editor) {
	if f.done || f.invalid {
		return
	}
	if f.query == "" {
		f.done = true
		return
	}

	length := buffer.length(&e.buf)
	if .Regex in f.searched {
		find_scan_regex(f, e, length)
	} else {
		find_scan_plain(f, e, length)
	}

	if len(f.matches) >= FIND_MAX_MATCHES {
		f.capped = true
		f.done = true
	}
}


// Matches starting in [scanned, scanned + FIND_PLAIN_BYTES). The read starts a
// byte early and ends a query length (and a byte) late, for matches crossing
// the slice's end and for whole-word checks
@(private = "file")
find_scan_plain :: proc(f: ^Find, e: ^Editor, length: int) {
	from := f.scanned
	to := min(from + FIND_PLAIN_BYTES, length)
	read_lo := max(from - 1, 0)
	read_hi := min(to + len(f.query) + 1, length)

	text := buffer.read_alloc(&e.buf, read_lo, read_hi)
	query := f.query
	if .Match_Case not_in f.searched {
		ascii_lower(text)
		query = strings.to_lower(query, context.temp_allocator)
	}

	haystack := string(text)
	i := 0
	for len(f.matches) < FIND_MAX_MATCHES {
		k := strings.index(haystack[i:], query)
		if k < 0 do break

		at := i + k
		start := read_lo + at
		if start >= to do break

		// Before the slice: found by the last one
		if start < from {
			i = at + 1
			continue
		}

		whole := .Whole_Word not_in f.searched || word_bounded(haystack, at, at + len(query))
		if !whole {
			i = at + 1
			continue
		}

		append(&f.matches, [2]int{start, start + len(f.query)})
		i = at + len(query)
	}

	f.scanned = to
	f.done = to >= length
}


// Regular expression matches in the next lines. A slice ends at a line break
// (or, inside an enormous line, a little past the budget), so a match only
// spans lines within one slice
@(private = "file")
find_scan_regex :: proc(f: ^Find, e: ^Editor, length: int) {
	b := &e.buf
	from := f.scanned
	to := min(from + FIND_REGEX_BYTES, length)
	if to < length {
		next_line := buffer.offset_to_line(b, to) + 1
		line_end := next_line < buffer.line_count(b) ? buffer.line_start(b, next_line) : length
		to = min(line_end, from + 4 * FIND_REGEX_BYTES)
	}

	text := string(buffer.read_alloc(b, from, to))
	pattern, flags := regex_pattern(f.query, f.searched)
	it, err := regex.create_iterator(
		text,
		pattern,
		flags,
		context.temp_allocator,
		context.temp_allocator,
	)
	if err != nil {
		f.invalid = true
		return
	}

	for len(f.matches) < FIND_MAX_MATCHES {
		capture, _, ok := regex.match_iterator(&it)
		if !ok do break

		lo, hi := capture.pos[0][0], capture.pos[0][1]
		if hi > lo {
			append(&f.matches, [2]int{from + lo, from + hi})
		}
	}

	f.scanned = to
	f.done = to >= length
}


// The pattern and flags a query searches with
@(private = "file")
regex_pattern :: proc(query: string, options: bit_set[Find_Option]) -> (string, regex.Flags) {
	flags := regex.Flags{.Multiline, .Unicode}
	if .Match_Case not_in options do flags += {.Case_Insensitive}

	pattern := query
	if .Whole_Word in options {
		pattern = strings.concatenate({`\b(`, query, `)\b`}, context.temp_allocator)
	}
	return pattern, flags
}


@(private = "file")
regex_compiles :: proc(query: string, options: bit_set[Find_Option]) -> bool {
	pattern, flags := regex_pattern(query, options)
	_, err := regex.create(pattern, flags, context.temp_allocator, context.temp_allocator)
	return err == nil
}


// Whether text[lo:hi] has no word character just outside it
@(private = "file")
word_bounded :: proc(text: string, lo, hi: int) -> bool {
	before := lo > 0 && textedit.char_class(text[lo - 1]) == .Word
	after := hi < len(text) && textedit.char_class(text[hi]) == .Word
	return !before && !after
}


@(private = "file")
ascii_lower :: proc(text: []u8) {
	for &c in text {
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
	}
}


// --- Moving between matches --------------------------------------------------------

// The next match (dir = +1) or the previous one, wrapping around
find_step :: proc(dir: int) -> bool {
	f := &g.find
	if !f.open do return false

	switch c in f.pane.content {
	case ^Editor:
		find_editor_step(f, c, dir)
	case ^Terminal:
		find_term_step(f, c, dir)
	}
	return true
}


@(private = "file")
find_editor_step :: proc(f: ^Find, e: ^Editor, dir: int) {
	n := len(f.matches)
	if n == 0 || e.status != .Text {
		return
	}

	// From the current match, or else from the selection
	next := -1
	if f.current >= 0 {
		next = f.current + dir
	} else {
		s := e.sels[e.primary]
		next = first_match_from(f, textedit.sel_hi(s))
		if dir < 0 do next = first_match_from(f, textedit.sel_lo(s)) - 1
	}

	// Past either end wraps around, once the whole document is searched
	if next >= n {
		if !f.done do return
		next = 0
	}
	if next < 0 {
		if !f.done do return
		next = n - 1
	}

	find_select(f, e, next)
}


// --- Commands and keys -------------------------------------------------------------

// Runs a find command. Returns false if it doesn't apply
find_run_command :: proc(cmd: Command) -> bool {
	f := &g.find

	#partial switch cmd {
	case .Find:
		return find_open()

	case .Find_Next, .Find_Previous:
		// In the focused pane: the bar opens there, or moves there from another
		elsewhere := f.open && f.pane != g.panes.focused
		if (!f.open || elsewhere) && !find_open() {
			return false
		}
		return find_step(cmd == .Find_Next ? +1 : -1)

	case .Find_Match_Case, .Find_Whole_Word, .Find_Regex:
		if !f.open || !is_editor(f.pane) {
			return false
		}
		option := Find_Option.Match_Case
		if cmd == .Find_Whole_Word do option = .Whole_Word
		if cmd == .Find_Regex do option = .Regex
		f.options ~= {option}
		return true
	}
	return false
}


// Keys while the field has them; it takes them all, letting through shortcuts
// that don't act on the pane behind it. In the editor searched, Escape closes
// the bar too (a terminal's Escape goes to its program)
find_handle_event :: proc(event: ^sdl.Event) -> bool {
	f := &g.find
	if !f.open do return false

	if !find_has_keys() {
		escape := event.type == .KEY_DOWN && event.key.key == sdl.K_ESCAPE
		in_editor := f.pane == g.panes.focused && is_editor(f.pane)
		if escape && in_editor {
			find_close()
			return true
		}
		return false
	}

	if event.type == .TEXT_INPUT {
		line_edit_event(&f.edit, event)
		return true
	}
	if event.type != .KEY_DOWN do return true

	key := event.key
	shift := key.mod & sdl.KMOD_SHIFT != {}
	switch key.key {
	case sdl.K_ESCAPE:
		find_close()
		return true
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		find_step(shift ? -1 : +1)
		return true
	}

	// Find commands, then the field's own keys, then other shortcuts
	cmd, is_command := command_for_key(key)
	if is_command && cmd in FIND_COMMANDS {
		if cmd == .Find {
			line_edit_select_all(&f.edit)
		} else {
			find_run_command(cmd)
		}
		return true
	}

	handled, _ := line_edit_event(&f.edit, event)
	if handled do return true

	if is_command && field_lets_through(cmd) {
		run_command(cmd)
	}
	return true
}


// --- The bar -----------------------------------------------------------------------

// The bar, as a floating child of the pane element being declared
find_bar_ui :: proc(p: ^Pane) {
	f := &g.find
	if !f.open || f.pane != p {
		return
	}

	g.in_find_bar = true
	defer g.in_find_bar = false

	if clay.UI(clay.ID("FindBar"))({
		layout = {
			padding = {left = 4, right = 4, top = 4, bottom = 4},
			childGap = 2,
			childAlignment = {y = .Center},
		},
		backgroundColor = gfx.theme.panel,
		overlayColor = clear_overlay(gfx.theme.panel),
		cornerRadius = clay.CornerRadiusAll(8),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .Parent,
			attachment = {element = .RightTop, parent = .RightTop},
			offset = {-18, PANE_HEADER_HEIGHT + 6}, // clear of the scroll bar
			zIndex = 5,
		},
		transition = transition({.OverlayColor}, .Fade, 0.12),
	}) {
		find_field()

		// The options
		case_id, word_id, regex_id := clay.ID("FindCase"), clay.ID("FindWord"), clay.ID("FindRegex")
		find_toggle(case_id, .Case_Sensitive, .Match_Case, "Match case", .Find_Match_Case)
		find_toggle(word_id, .Whole_Word, .Whole_Word, "Whole word", .Find_Whole_Word)
		find_toggle(regex_id, .Regex, .Regex, "Regular expression", .Find_Regex)

		// The count
		if clay.UI()({
			layout = {
				sizing = {width = clay.SizingFixed(70)},
				padding = {left = 6, right = 4},
				childAlignment = {x = .Center},
			},
		}) {
			label(find_status(f), gfx.theme.text_dim, FONT_SIZE_SMALL)
		}

		previous := first_chord_label(.Find_Previous)
		next := first_chord_label(.Find_Next)
		if icon_button(clay.ID("FindPrevious"), .Arrow_Up, 24, 14, "Previous match", previous) {
			find_step(-1)
		}
		if icon_button(clay.ID("FindNext"), .Arrow_Down, 24, 14, "Next match", next) {
			find_step(+1)
		}
		if icon_button(clay.ID("FindClose"), .Close, 24, 14, "Close", "Escape") {
			find_close()
		}
	}
}


// The query field, with the caret while it has the keys. A press on it gives
// it the keys and focuses its pane
@(private = "file")
find_field :: proc() {
	f := &g.find
	id := clay.ID("FindField")
	if clicked(id) {
		pane_focus(f.pane)
		f.typing = true
	}

	look := Field_Look{
		width   = FIND_FIELD_WIDTH,
		height  = 24,
		size    = FONT_SIZE_SMALL,
		padding = 6,
	}
	if f.invalid do look.edge = gfx.theme.error

	text_field(id, &f.edit, "Find", find_has_keys(), look)
}


// An option button: highlighted while on. Terminals have no options, so there
// they are faint and do nothing
@(private = "file")
find_toggle :: proc(
	id: clay.ElementId,
	kind: gfx.Icon,
	option: Find_Option,
	tip: string,
	cmd: Command,
) {
	f := &g.find
	available := is_editor(f.pane)
	on := available && option in f.options

	fill: clay.Color
	if on {
		fill = gfx.theme.accent
		fill.a = 60
	} else if available && clay.PointerOver(id) {
		fill = gfx.theme.hover
	}

	color := gfx.theme.text_dim
	if on do color = gfx.theme.text_bright
	if !available do color = gfx.theme.text_faint

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingFixed(24), clay.SizingFixed(24)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = fill,
		cornerRadius = clay.CornerRadiusAll(5),
	}) {
		icon(kind, color, 15)
	}

	if !available {
		tooltip(id, "Not available in terminals")
		return
	}
	tooltip(id, tip, first_chord_label(cmd))
	if clicked(id) do f.options ~= {option}
}


// "3 of 12", "12" while none is current, "No results"; "+" while searching
@(private = "file")
find_status :: proc(f: ^Find) -> string {
	total, current, complete := find_counts(f)

	if f.invalid do return "Invalid"
	if total == 0 {
		return complete ? "No results" : "…"
	}

	more := complete ? "" : "+"
	if current < 0 {
		return fmt.tprintf("%d%s", total, more)
	}
	return fmt.tprintf("%d of %d%s", current + 1, total, more)
}


// The number of matches, the current one (or -1), and whether that is all
@(private = "file")
find_counts :: proc(f: ^Find) -> (total, current: int, complete: bool) {
	switch c in f.pane.content {
	case ^Editor:
		return len(f.matches), f.current, f.done && !f.capped
	case ^Terminal:
		return find_term_counts(f)
	}
	return
}
