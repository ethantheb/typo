package editor

// Completion and signature help.
//
// Completions are asked for when an identifier is typed (once typing rests
// COMPLETION_DELAY, not in comments or strings), on the server's trigger
// characters, or on Trigger completion (Ctrl+Space). A list under the caret
// shows the items matching the word before the caret (fuzzy_score against an
// item's filter text, else its label); typing more filters again, or asks again
// when the server said the list was incomplete. Up/Down choose, Enter or Tab
// inserts, Esc closes. Inserting replaces what the item says (its range, moved
// by what was typed since it was asked for) at every caret, and makes the item's
// other edits (e.g. an import), as one undo step; a snippet goes in as plain
// text with its first placeholder selected. The chosen item's documentation is
// asked for (completionItem/resolve) and shown beside the list.
//
// Signature help is asked for on the server's signature trigger characters, or
// on Show signature help. While it shows, it is asked again as the caret moves
// or the text changes, and it closes when the server says the caret is in no
// call.
//
// Requests go out in lsp_completion_frame, after the panes' frames sent the
// frame's edits to the server, so the server has the text they are about

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import clay "../vendor/clay-odin"
import "buffer"
import "fuzzy"
import "gfx"
import "langs"
import "lsp"
import sdl "../vendor/sdl3"
import "syntax"
import "textedit"


Completion_State :: struct {
	// Asking
	editor:        ^Editor, // completed in, or nil
	client:        ^langs.Client,
	request:       int,              // the answer waited for, or 0
	asked_at:      int,              // the primary caret when it was asked
	due:           Maybe(time.Tick), // when to ask (typing has rested)
	due_reason:    lsp.Completion_Trigger, // why
	due_trigger:   string,           // owned; the trigger character typed
	due_invoked:   bool,             // asked for: also with no word, in comments

	// The list
	open:          bool,
	start:         int,                       // where the word completed starts
	items:         [dynamic]lsp.Completion,   // owned
	shown:         [dynamic]Shown_Completion, // the items matching the word, best first
	selected:      int,                       // in shown
	reveal:        bool,                      // scroll the selected row into view
	incomplete:    bool,                      // typing more asks again
	version:       u64,                       // of the buffer when last filtered
	caret:         int,                       // likewise
	generation:    int,                       // counts lists, for resolve answers

	// The chosen item's documentation, asked for
	resolving:     int, // the request, or 0
	resolve_index: int, // in items
	resolve_gen:   int,
}

Shown_Completion :: struct {
	index: int, // in items
	score: f32,
	key:   string, // the server's order: its sort text, else its label
}

Signature_State :: struct {
	editor:  ^Editor, // shown or asked about, or nil
	client:  ^langs.Client,
	request: int,  // the answer waited for, or 0
	due:     bool, // ask in this frame, after the edits went out
	open:    bool,
	help:    lsp.Signature_Help, // owned
	version: u64,  // of the buffer when last asked
	caret:   int,  // likewise
}

// How long identifier typing rests before completions are asked for
COMPLETION_DELAY :: 40 * time.Millisecond

@(private = "file")
LIST_ROWS :: 10
@(private = "file")
ROW_HEIGHT :: 24
@(private = "file")
LIST_WIDTH :: 420
@(private = "file")
DOCS_WIDTH :: 340
@(private = "file")
KIND_WIDTH :: 46
@(private = "file")
SIGNATURE_MAX_W :: 600
@(private = "file")
SIGNATURE_MAX_H :: 180
@(private = "file")
MAX_WORD :: 256 // bytes before the caret looked at for the word

@(private = "file")
Item_Kind :: struct {
	name:  string,
	color: syntax.Highlight,
}

// Short names of the CompletionItemKinds (1-25), and the color of their role
@(private = "file")
ITEM_KINDS := [26]Item_Kind {
	{"", .None},
	{"text", .None},
	{"method", .Function},
	{"fn", .Function},
	{"ctor", .Function},
	{"field", .Property},
	{"var", .Parameter},
	{"class", .Type},
	{"iface", .Type},
	{"module", .Namespace},
	{"prop", .Property},
	{"unit", .Number},
	{"value", .Constant},
	{"enum", .Type},
	{"keyword", .Keyword},
	{"snippet", .String},
	{"color", .Constant},
	{"file", .Namespace},
	{"ref", .Namespace},
	{"folder", .Namespace},
	{"member", .Constant},
	{"const", .Constant},
	{"struct", .Type},
	{"event", .Parameter},
	{"op", .Operator},
	{"param", .Type},
}


// --- Typing ------------------------------------------------------------------------

// After text was typed in an editor: asks for completions or signature help as
// the last character calls for, or closes the list when it ends the word
lsp_typed :: proc(e: ^Editor, text: string) {
	if len(text) == 0 || len(e.lsp.clients) == 0 {
		return
	}
	langs.timed()
	cs := &g.lsp.completion
	last := text[len(text) - 1:]

	// Signature help on its trigger characters
	sc := langs.client_with(&e.lsp, .Signature_Help)
	if sc != nil && has_string(sc.caps.signature_triggers, last) {
		sig := &g.lsp.signature
		if sig.editor != e do lsp_signature_close()
		sig.editor = e
		sig.due = true
	}

	c := langs.client_with(&e.lsp, .Completion)
	if c == nil do return

	switch {
	case has_string(c.caps.completion_triggers, last):
		lsp_completion_close()
		completion_due(e, .Character, last, 0)
	case textedit.is_word_byte(last[0]):
		// While the list shows, the frame filters it again
		listing := cs.open && cs.editor == e
		if !listing do completion_due(e, .Invoked, "", COMPLETION_DELAY)
	case:
		lsp_completion_close()
	}
}


// Trigger completion: asks at once, also with no word typed. False if none of
// the editor's servers completes
lsp_trigger_completion :: proc(e: ^Editor) -> bool {
	if langs.client_with(&e.lsp, .Completion) == nil do return false

	lsp_completion_close()
	completion_due(e, .Invoked, "", 0)
	g.lsp.completion.due_invoked = true
	return true
}


// Show signature help: for the call the caret is in. False if no server says
lsp_show_signature :: proc(e: ^Editor) -> bool {
	if langs.client_with(&e.lsp, .Signature_Help) == nil do return false

	sig := &g.lsp.signature
	if sig.editor != e do lsp_signature_close()
	sig.editor = e
	sig.due = true
	return true
}


@(private = "file")
completion_due :: proc(
	e: ^Editor,
	reason: lsp.Completion_Trigger,
	trigger: string,
	delay: time.Duration,
) {
	cs := &g.lsp.completion
	if cs.editor != e do lsp_completion_close()

	cs.editor = e
	cs.due = time.tick_add(time.tick_now(), delay)
	cs.due_reason = reason
	cs.due_invoked = false
	set_string(&cs.due_trigger, trigger)
}


@(private = "file")
has_string :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s do return true
	}
	return false
}


// --- Each frame --------------------------------------------------------------------

// After the panes' frames (the edits went out): asks what is due, follows the
// caret, and closes what lost its editor's focus
lsp_completion_frame :: proc() {
	cs := &g.lsp.completion
	sig := &g.lsp.signature
	focused := focused_editor()

	// Their editor lost the keys, or something covers it
	covered := editors_covered()
	if cs.editor != nil && (cs.editor != focused || covered) {
		lsp_completion_close()
	}
	if sig.editor != nil && (sig.editor != focused || covered) {
		lsp_signature_close()
	}

	// A press anywhere but on the list closes it
	if cs.open && g.mouse_pressed && !pointer_in(clay.ID("Completion")) {
		lsp_completion_close()
	}

	completion_step()
	signature_step()
}


// Whether frames must keep coming: something is to be asked once typing rests
lsp_completion_busy :: proc() -> bool {
	sig := &g.lsp.signature
	return g.lsp.completion.due != nil || (sig.due && sig.request == 0)
}


// Whether the list or the signature is under the pointer, so what is under them
// doesn't react
lsp_completion_covers_pointer :: proc() -> bool {
	cs := &g.lsp.completion
	listed := cs.open && len(cs.shown) > 0 && pointer_in(clay.ID("Completion"))
	signed := g.lsp.signature.open && pointer_in(clay.ID("Signature"))
	return listed || signed
}


@(private = "file")
completion_step :: proc() {
	cs := &g.lsp.completion
	e := cs.editor
	if e == nil do return
	caret := e.sels[e.primary].head

	// Typing has rested: ask
	due, has_due := cs.due.?
	if has_due && time.tick_since(due) >= 0 {
		cs.due = nil
		ask_completions(e, caret, cs.due_reason, cs.due_trigger, cs.due_invoked)
	}
	if !cs.open do return

	// The caret moved or the text changed: filter again while it is in the word
	if e.buf.version != cs.version || caret != cs.caret {
		if !in_word(e, cs.start, caret) {
			lsp_completion_close()
			return
		}

		edited := e.buf.version != cs.version
		filter_completions(e, caret)
		if edited && cs.incomplete && cs.request == 0 {
			ask_completions(e, caret, .Incomplete, "", true)
		}
	}

	resolve_chosen(e)
}


// Asks for completions at the caret, unless it is on a number, or (when not
// asked for) there is no word or it is in a comment or string
@(private = "file")
ask_completions :: proc(
	e: ^Editor,
	caret: int,
	reason: lsp.Completion_Trigger,
	trigger: string,
	invoked: bool,
) {
	langs.timed()
	cs := &g.lsp.completion
	c := langs.client_with(&e.lsp, .Completion)
	if c == nil do return

	// Where the word starts, for a new list
	if !cs.open {
		start, _ := textedit.word_span(e, caret, MAX_WORD)
		word := string(buffer.read_alloc(&e.buf, start, caret))
		number := len(word) > 0 && word[0] >= '0' && word[0] <= '9'
		no_word := reason == .Invoked && word == ""
		if number || (!invoked && (no_word || in_comment_or_string(e, caret))) {
			return
		}
		cs.start = start
	}

	if cs.request != 0 do langs.cancel_request(cs.request, cs.client)
	id := lsp.request_completion(c.client, e.lsp.uri, caret, reason, trigger)
	langs.track_request(&e.lsp, c, .Completion, id, caret)
	cs.client = c
	cs.request = id
	cs.asked_at = caret
}


// Whether [start, caret) is one word, on one line
@(private = "file")
in_word :: proc(e: ^Editor, start, caret: int) -> bool {
	if caret < start || caret - start > MAX_WORD {
		return false
	}

	text := buffer.read_alloc(&e.buf, start, caret)
	for c in text {
		if !textedit.is_word_byte(c) do return false
	}
	return true
}


// Whether the character before the caret is in a comment or a string
@(private = "file")
in_comment_or_string :: proc(e: ^Editor, caret: int) -> bool {
	if caret == 0 do return false

	hl: [1]syntax.Highlight
	syntax.highlight_range(&e.hl, &e.buf, caret - 1, hl[:])
	return hl[0] == .Comment || hl[0] == .String
}


// The items matching the word before the caret, best first (with no word, in
// the server's order, its preselected item chosen)
@(private = "file")
filter_completions :: proc(e: ^Editor, caret: int) {
	cs := &g.lsp.completion
	cs.version = e.buf.version
	cs.caret = caret
	word := string(buffer.read_alloc(&e.buf, cs.start, caret))

	clear(&cs.shown)
	for item, i in cs.items {
		key := item.sort != "" ? item.sort : item.label
		if word == "" {
			append(&cs.shown, Shown_Completion{i, 0, key})
			continue
		}

		matched := item.filter != "" ? item.filter : item.label
		score, ok := fuzzy.score(word, matched)
		if ok do append(&cs.shown, Shown_Completion{i, score, key})
	}
	slice.sort_by(cs.shown[:], shown_less)

	cs.selected = 0
	cs.reveal = true
	if word != "" do return
	for s, i in cs.shown {
		if cs.items[s.index].preselect {
			cs.selected = i
			break
		}
	}
}


@(private = "file")
shown_less :: proc(a, b: Shown_Completion) -> bool {
	if a.score != b.score do return a.score > b.score
	return a.key < b.key
}


// Asks for the chosen item's documentation, if the server keeps it for later
@(private = "file")
resolve_chosen :: proc(e: ^Editor) {
	cs := &g.lsp.completion
	if cs.selected < 0 || cs.selected >= len(cs.shown) {
		return
	}

	index := cs.shown[cs.selected].index
	item := &cs.items[index]
	asked := cs.resolving != 0 && cs.resolve_index == index
	if item.resolve == "" || item.documentation != "" || asked {
		return
	}

	langs.timed()
	c := cs.client
	if cs.resolving != 0 do langs.cancel_request(cs.resolving, c)
	if c == nil || c.state != .Running {
		return
	}

	id := lsp.request_resolve(c.client, e.lsp.uri, item.resolve)
	langs.track_request(&e.lsp, c, .Completion_Resolve, id, 0)
	cs.resolving = id
	cs.resolve_index = index
	cs.resolve_gen = cs.generation
}


// --- Answers -----------------------------------------------------------------------

// Completions (taken over), or a chosen item's documentation
lsp_completion_response :: proc(r: langs.Request, resp: lsp.Response) {
	langs.timed()
	cs := &g.lsp.completion
	if r.feature == .Completion_Resolve {
		resolve_response(r, resp)
		return
	}
	if r.id != cs.request || r.client != cs.client || request_editor(r) != cs.editor {
		return
	}
	cs.request = 0

	list, decoded := resp.result.(lsp.Completions)
	if resp.error != "" || !decoded || len(list.items) == 0 {
		lsp_completion_close()
		return
	}

	// The items, taken from the answer (which frees what is left)
	clear_completions()
	for &item in list.items {
		append(&cs.items, item)
		item = {}
	}
	cs.incomplete = list.incomplete
	cs.generation += 1
	cs.open = true

	// Filtered in this frame's completion_step (UI work, not the server's)
	clear(&cs.shown)
	cs.caret = -1
}


@(private = "file")
resolve_response :: proc(r: langs.Request, resp: lsp.Response) {
	cs := &g.lsp.completion
	if r.id != cs.resolving do return
	cs.resolving = 0

	stale := cs.resolve_gen != cs.generation || cs.resolve_index >= len(cs.items)
	if stale do return

	// Asked once: its documentation and detail, if it has them now
	item := &cs.items[cs.resolve_index]
	set_string(&item.resolve, "")
	resolved, decoded := resp.result.(lsp.Completion)
	if !decoded do return

	if resolved.documentation != "" do set_string(&item.documentation, resolved.documentation)
	if item.detail == "" do set_string(&item.detail, resolved.detail)
}


// --- Inserting ---------------------------------------------------------------------

// Inserts the shown item `index` at every caret, with its other edits, as one
// undo step, then closes the list
@(private = "file")
accept_completion :: proc(index: int) {
	cs := &g.lsp.completion
	e := cs.editor
	if e == nil || index < 0 || index >= len(cs.shown) {
		return
	}
	item := cs.items[cs.shown[index].index]

	// What it replaces now: text after where it was asked moved by what was
	// typed since
	caret := e.sels[e.primary].head
	delta := caret - cs.asked_at
	lo := item.lo > cs.asked_at ? item.lo + delta : item.lo
	hi := item.hi >= cs.asked_at ? item.hi + delta : item.hi
	if lo > caret || hi < caret {
		lsp_completion_close()
		return
	}

	// The same span around every caret
	length := buffer.length(&e.buf)
	edits := make([dynamic]textedit.Text_Edit, context.temp_allocator)
	for s, i in e.sels {
		edit := textedit.Text_Edit {
			lo      = max(s.head - (caret - lo), 0),
			hi      = min(s.head + (hi - caret), length),
			text    = item.text,
			selects = true,
			sel     = item.select,
			primary = i == e.primary,
		}
		if len(edits) > 0 && edit.lo < edits[len(edits) - 1].hi {
			continue
		}
		append(&edits, edit)
	}

	// Its other edits, moved likewise, where they don't overlap those
	for m in item.more {
		mlo, mhi := m.offset, m.offset + m.old_len
		if mlo > cs.asked_at do mlo += delta
		if mhi > cs.asked_at do mhi += delta
		if overlaps_any(edits[:], mlo, mhi) do continue
		append(&edits, textedit.Text_Edit{lo = mlo, hi = mhi, text = m.text})
	}
	slice.sort_by(edits[:], edit_less)

	textedit.show_caret(e, true)
	textedit.apply_edits(e, .Other, edits[:])
	lsp_completion_close()
}


@(private = "file")
overlaps_any :: proc(edits: []textedit.Text_Edit, lo, hi: int) -> bool {
	for e in edits {
		inside := lo < e.hi && hi > e.lo
		insert_inside := lo == hi && lo > e.lo && lo < e.hi
		if inside || insert_inside {
			return true
		}
	}
	return false
}


// By start; at the same start, an insertion before a replacement
@(private = "file")
edit_less :: proc(a, b: textedit.Text_Edit) -> bool {
	if a.lo != b.lo do return a.lo < b.lo
	return a.hi < b.hi
}


// --- Keys --------------------------------------------------------------------------

// Up, Down, Page Up/Down, Enter, Tab and Esc while the list shows; Esc also
// closes the signature. True if the key was taken
lsp_completion_handle_key :: proc(event: ^sdl.Event) -> bool {
	if event.type != .KEY_DOWN do return false
	cs := &g.lsp.completion
	key := event.key.key
	mods := event.key.mod
	plain := mods & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_SHIFT) == {}

	listed := cs.open && len(cs.shown) > 0 && cs.editor == focused_editor()
	if listed && plain {
		last := len(cs.shown) - 1
		switch key {
		case sdl.K_UP:
			choose(cs.selected - 1)
		case sdl.K_DOWN:
			choose(cs.selected + 1)
		case sdl.K_PAGEUP:
			choose(max(cs.selected - LIST_ROWS, 0))
		case sdl.K_PAGEDOWN:
			choose(min(cs.selected + LIST_ROWS, last))
		case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_TAB:
			accept_completion(cs.selected)
		case sdl.K_ESCAPE:
			lsp_completion_close()
		case:
			return false
		}
		return true
	}

	if key == sdl.K_ESCAPE && g.lsp.signature.open {
		lsp_signature_close()
		return true
	}
	return false
}


// Chooses a row, going round past the ends
@(private = "file")
choose :: proc(row: int) {
	cs := &g.lsp.completion
	n := len(cs.shown)
	if n == 0 do return

	cs.selected = (row % n + n) % n
	cs.reveal = true
}


// --- Closing -----------------------------------------------------------------------

lsp_completion_close :: proc() {
	cs := &g.lsp.completion
	if cs.request != 0 do langs.cancel_request(cs.request, cs.client)
	if cs.resolving != 0 do langs.cancel_request(cs.resolving, cs.client)

	clear_completions()
	clear(&cs.shown)
	cs.editor = nil
	cs.client = nil
	cs.request = 0
	cs.resolving = 0
	cs.due = nil
	cs.open = false
	cs.incomplete = false
}


lsp_signature_close :: proc() {
	sig := &g.lsp.signature
	if sig.request != 0 do langs.cancel_request(sig.request, sig.client)

	delete(sig.help.label)
	delete(sig.help.documentation)
	sig^ = {}
}


// A client stopped or is going away: the list and signature it gave close
lsp_completion_forget_client :: proc(c: ^langs.Client) {
	if g.lsp.completion.client == c do lsp_completion_close()
	if g.lsp.signature.client == c do lsp_signature_close()
}


// An editor is closing: nothing may point at it
lsp_completion_forget :: proc(e: ^Editor) {
	if g.lsp.completion.editor == e do lsp_completion_close()
	if g.lsp.signature.editor == e do lsp_signature_close()
}


lsp_completion_destroy :: proc() {
	cs := &g.lsp.completion
	lsp_completion_close()
	delete(cs.items)
	delete(cs.shown)
	delete(cs.due_trigger)
	cs^ = {}
	lsp_signature_close()
}


@(private = "file")
clear_completions :: proc() {
	cs := &g.lsp.completion
	for &item in cs.items do lsp.completion_destroy(&item)
	clear(&cs.items)
}


// --- Signature help ----------------------------------------------------------------

// Asks when it is due, and again while it shows and the caret moves or the
// text changes
@(private = "file")
signature_step :: proc() {
	sig := &g.lsp.signature
	e := sig.editor
	if e == nil || sig.request != 0 {
		return
	}

	caret := e.sels[e.primary].head
	moved := sig.open && (e.buf.version != sig.version || caret != sig.caret)
	if !sig.due && !moved {
		return
	}
	sig.due = false

	langs.timed()
	c := langs.client_with(&e.lsp, .Signature_Help)
	if c == nil {
		lsp_signature_close()
		return
	}

	sig.client = c
	method := "textDocument/signatureHelp"
	sig.request = langs.send_request(&e.lsp, c, .Signature_Help, method, caret)
	sig.version = e.buf.version
	sig.caret = caret
}


// The call the caret is in, or none: then it closes
lsp_signature_response :: proc(r: langs.Request, resp: lsp.Response) {
	langs.timed()
	sig := &g.lsp.signature
	if r.id != sig.request || r.client != sig.client {
		return
	}
	sig.request = 0

	help, decoded := resp.result.(lsp.Signature_Help)
	if resp.error != "" || !decoded || help.count == 0 {
		lsp_signature_close()
		return
	}

	delete(sig.help.label)
	delete(sig.help.documentation)
	sig.help = help
	sig.help.label = strings.clone(help.label)
	sig.help.documentation = strings.clone(help.documentation)
	sig.open = true
}


// --- The list ----------------------------------------------------------------------

// The list under the word, with the chosen item's documentation beside it, and
// the signature above the caret
lsp_completion_ui :: proc() {
	signature_ui()

	cs := &g.lsp.completion
	e := cs.editor
	if !cs.open || len(cs.shown) == 0 || e == nil || e.kind.char_rect == nil {
		return
	}
	anchor, in_view := e.kind.char_rect(e, cs.start)
	if !in_view do return

	// Below the line, or above it where there is no room below
	rows := min(len(cs.shown), LIST_ROWS)
	height := f32(rows * ROW_HEIGHT + 8)
	below := anchor.y + anchor.h + height < f32(g.window_h) - STATUSBAR_HEIGHT
	attach: clay.FloatingAttachPoints
	y: f32
	if below {
		attach = {element = .LeftTop, parent = .LeftTop}
		y = anchor.y + anchor.h + 2
	} else {
		attach = {element = .LeftBottom, parent = .LeftTop}
		y = anchor.y - 2
	}
	docs := chosen_docs()
	width := f32(LIST_WIDTH) + (docs ? DOCS_WIDTH : 0)
	x := clamp(anchor.x - KIND_WIDTH - 14, 4, max(f32(g.window_w) - width - 4, 4))

	g.in_popup = true
	defer g.in_popup = false

	if clay.UI(clay.ID("Completion"))({
		layout = {childAlignment = {y = below ? .Top : .Bottom}},
		floating = {attachTo = .Root, attachment = attach, offset = {x, y}, zIndex = 116},
	}) {
		completion_list(e, rows)
		if docs do completion_docs(e, height)
	}
}


@(private = "file")
completion_list :: proc(e: ^Editor, rows: int) {
	cs := &g.lsp.completion
	list := clay.ID("CompletionList")

	// Only the rows in view (and one more) are laid out, between spacers
	scroll := clay.GetScrollContainerData(list)
	if cs.reveal && scroll.found {
		scroll_to_chosen(&scroll)
		cs.reveal = false
	}
	first := 0
	if scroll.found {
		first = clamp(int(-scroll.scrollPosition.y / ROW_HEIGHT), 0, len(cs.shown))
	}
	last := min(first + LIST_ROWS + 1, len(cs.shown))

	word := string(buffer.read_alloc(&e.buf, cs.start, cs.caret))
	wheel_scroll_list(list)
	if clay.UI()({
		layout = {padding = clay.PaddingAll(4)},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
	}) {
		if clay.UI(list)({
			layout = {
				sizing = {
					clay.SizingFixed(LIST_WIDTH - 8),
					clay.SizingFixed(f32(rows * ROW_HEIGHT)),
				},
				layoutDirection = .TopToBottom,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			rows_space(first)
			for i in first ..< last {
				if completion_row(i, word) do accept_completion(i)
			}
			rows_space(len(cs.shown) - last)
		}
	}
}


@(private = "file")
rows_space :: proc(rows: int) {
	if rows <= 0 do return

	height := f32(rows * ROW_HEIGHT)
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(height)}}}) {}
}


// One item: its kind, its label (matched characters marked) and signature, and
// its detail at the right. True if it was clicked
@(private = "file")
completion_row :: proc(row: int, word: string) -> bool {
	cs := &g.lsp.completion
	item := cs.items[cs.shown[row].index]
	chosen := row == cs.selected
	id := clay.ID("CompletionRow", u32(row))

	if clay.UI(id)({
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(ROW_HEIGHT)},
			padding = {left = 8, right = 8},
			childGap = 8,
			childAlignment = {y = .Center},
		},
		backgroundColor = chosen ? gfx.theme.selected : (clay.Hovered() ? gfx.theme.hover : {}),
		cornerRadius = clay.CornerRadiusAll(4),
	}) {
		name, color := completion_kind(item.kind)
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(KIND_WIDTH)}}}) {
			label(name, color, FONT_SIZE_SMALL)
		}

		// The label and signature, cut off before the detail
		if clay.UI()({
			layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}},
			clip = {horizontal = true},
		}) {
			matched := fuzzy.positions(word, item.label)
			bright := gfx.theme.text_bright
			highlighted_text(item.label, 0, len(item.label), matched, bright, .Editor)
			if item.signature != "" {
				label(item.signature, gfx.theme.text_dim, FONT_SIZE_UI, .Editor)
			}
		}

		if item.detail != "" {
			if clay.UI()({
				layout = {sizing = {width = clay.SizingFit({max = 160})}},
				clip = {horizontal = true},
			}) {
				label(item.detail, gfx.theme.text_dim, FONT_SIZE_SMALL)
			}
		}
	}
	return clicked(id, clay.ID("CompletionList"))
}


// Whether the chosen item has documentation to show beside the list
@(private = "file")
chosen_docs :: proc() -> bool {
	cs := &g.lsp.completion
	if cs.selected < 0 || cs.selected >= len(cs.shown) {
		return false
	}
	return cs.items[cs.shown[cs.selected].index].documentation != ""
}


// The chosen item's detail and documentation
@(private = "file")
completion_docs :: proc(e: ^Editor, height: f32) {
	cs := &g.lsp.completion
	item := cs.items[cs.shown[cs.selected].index]

	body := clay.ID("CompletionDocs")
	wheel_scroll_list(body)
	if clay.UI(body)({
		layout = {
			sizing = {clay.SizingFixed(DOCS_WIDTH), clay.SizingFit({min = 0, max = height})},
			layoutDirection = .TopToBottom,
			padding = {10, 10, 8, 8},
			childGap = 8,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		if item.detail != "" {
			config := text_config(gfx.theme.text_dim, FONT_SIZE_SMALL, .Editor)
			config.wrapMode = .Words
			clay.TextDynamic(item.detail, config)
		}
		markdown_blocks(item.documentation, e.hl.lang)
	}
}


@(private = "file")
scroll_to_chosen :: proc(scroll: ^clay.ScrollContainerData) {
	cs := &g.lsp.completion
	top := f32(cs.selected * ROW_HEIGHT)
	view := scroll.scrollContainerDimensions.height

	// scrollPosition is negative: content offset upward
	if top < -scroll.scrollPosition.y {
		scroll.scrollPosition.y = -top
	} else if top + ROW_HEIGHT > -scroll.scrollPosition.y + view {
		scroll.scrollPosition.y = -(top + ROW_HEIGHT - view)
	}
}


// A completion kind's short name, in the color of its role
completion_kind :: proc(kind: int) -> (name: string, color: clay.Color) {
	if kind <= 0 || kind >= len(ITEM_KINDS) {
		return "", gfx.theme.text_dim
	}
	k := ITEM_KINDS[kind]
	if k.color == .None do return k.name, gfx.theme.text_dim
	return k.name, gfx.theme.syntax[k.color]
}


// --- The signature -----------------------------------------------------------------

// Above the caret's line: the signature with its active parameter marked, which
// of several it is, and the documentation
@(private = "file")
signature_ui :: proc() {
	sig := &g.lsp.signature
	e := sig.editor
	if !sig.open || e == nil || e.kind.char_rect == nil {
		return
	}
	anchor, in_view := e.kind.char_rect(e, e.sels[e.primary].head)
	if !in_view do return

	x := clamp(anchor.x - 16, 4, max(f32(g.window_w) - SIGNATURE_MAX_W - 4, 4))
	attach := clay.FloatingAttachPoints{element = .LeftBottom, parent = .LeftTop}

	g.in_popup = true
	defer g.in_popup = false

	help := sig.help
	if clay.UI(clay.ID("Signature"))({
		layout = {
			sizing = {
				clay.SizingFit({max = SIGNATURE_MAX_W}),
				clay.SizingFit({max = SIGNATURE_MAX_H}),
			},
			layoutDirection = .TopToBottom,
			padding = {10, 10, 6, 6},
			childGap = 6,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		clip = {vertical = true},
		floating = {
			attachTo = .Root,
			attachment = attach,
			offset = {x, anchor.y - 4},
			zIndex = 116,
		},
	}) {
		if clay.UI()({layout = {childGap = 8, childAlignment = {y = .Center}}}) {
			if help.count > 1 {
				which := fmt.tprintf("%d/%d", help.index + 1, help.count)
				label(which, gfx.theme.text_dim, FONT_SIZE_SMALL)
			}
			signature_label(help)
		}
		if help.documentation != "" do markdown_blocks(help.documentation, e.hl.lang)
	}
}


// The label in the editor font, its active parameter bold in the accent color
@(private = "file")
signature_label :: proc(help: lsp.Signature_Help) {
	text := help.label
	lo, hi := len(text), len(text) // no active parameter
	if help.param_lo >= 0 {
		lo = clamp(help.param_lo, 0, len(text))
		hi = clamp(help.param_hi, lo, len(text))
	}

	if clay.UI()({layout = {childAlignment = {y = .Center}}}) {
		if lo > 0 do label(text[:lo], gfx.theme.text, FONT_SIZE_UI, .Editor)
		if hi > lo do label(text[lo:hi], gfx.theme.accent, FONT_SIZE_UI, .Editor_Bold)
		if hi < len(text) do label(text[hi:], gfx.theme.text, FONT_SIZE_UI, .Editor)
	}
}
