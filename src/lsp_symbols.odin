package editor

// Symbols and references in the finder: a file's outline (Go to symbol in
// file), the project's symbols (Go to symbol in project: asked again once the
// query rests, each answer filtered and ranked by the finder), and the places
// a symbol is used (Find references) or defined (several definitions). The
// server's answers are decoded on its client's thread; here they become the
// finder's items, which take their strings over

import "core:fmt"
import "core:time"

import clay "../vendor/clay-odin"
import "gfx"
import "langs"
import "lsp"
import "syntax"
import "uitime"


// What the finder asked a server
Lsp_Finder :: struct {
	client:  ^langs.Client,      // asked last, or nil
	request: int,              // the answer waited for, or 0
	caret:   int,              // in the file whose outline was asked for
	query:   string,           // owned; the project query asked last
	due:     Maybe(time.Tick), // when a changed query is asked
}

// How long the query rests before the project's symbols are asked for again
WORKSPACE_SYMBOLS_DELAY :: 150 * time.Millisecond

@(private = "file")
Symbol_Kind :: struct {
	name:  string,
	color: syntax.Highlight,
}

// Short names of the SymbolKinds (1-26), and the color of their role
@(private = "file")
SYMBOL_KINDS := [27]Symbol_Kind {
	{"", .None},
	{"file", .Namespace},
	{"module", .Namespace},
	{"ns", .Namespace},
	{"pkg", .Namespace},
	{"class", .Type},
	{"method", .Function},
	{"prop", .Property},
	{"field", .Property},
	{"ctor", .Function},
	{"enum", .Type},
	{"iface", .Type},
	{"fn", .Function},
	{"var", .Parameter},
	{"const", .Constant},
	{"str", .String},
	{"num", .Number},
	{"bool", .Constant},
	{"array", .Parameter},
	{"obj", .Parameter},
	{"key", .Property},
	{"null", .Constant},
	{"member", .Constant},
	{"struct", .Type},
	{"event", .Parameter},
	{"op", .Operator},
	{"param", .Type},
}


// --- Asking ------------------------------------------------------------------------

// Lists the editor's symbols in the finder (or closes the finder showing them)
lsp_find_file_symbols :: proc(e: ^Editor) {
	uitime.timed(&langs.ui_share)
	if g.finder.open && g.finder.source == .File_Symbols {
		finder_close()
		return
	}

	finder_open(.File_Symbols)
	c := langs.client_with(&e.lsp, .File_Symbols)
	if c == nil {
		finder_set_status("No language server of this file lists its symbols")
		return
	}

	id := langs.send_request(&e.lsp, c, .File_Symbols, "textDocument/documentSymbol", 0)
	waiting_for(c, id)
	g.lsp.finder.caret = e.sels[e.primary].head
}


// Lists the project's symbols matching the query in the finder (or closes the
// finder showing them). The focused file's server is asked, else any running
// server that can
lsp_find_workspace_symbols :: proc() {
	uitime.timed(&langs.ui_share)
	if g.finder.open && g.finder.source == .Workspace_Symbols {
		finder_close()
		return
	}

	finder_open(.Workspace_Symbols)
	c := workspace_symbols_client()
	if c == nil {
		finder_set_status("No running language server lists the project's symbols")
		return
	}

	g.lsp.finder.client = c
	ask_workspace("")
}


// Lists the places the symbol at `offset` is used in the finder. False if none
// of the editor's servers can say
lsp_find_references :: proc(e: ^Editor, offset: int) -> bool {
	uitime.timed(&langs.ui_share)
	c := langs.client_with(&e.lsp, .References)
	if c == nil do return false

	finder_open(.Locations, "references")
	waiting_for(c, langs.send_request(&e.lsp, c, .References, "textDocument/references", offset))
	return true
}


// Several places (e.g. definitions) to choose from in the finder, taking their
// strings
lsp_list_places :: proc(r: langs.Request, places: []lsp.Place, what: string) {
	finder_open(.Locations, what)
	finder_set_items(place_items(places, r.client.encoding))
}


// The finder's query changed: the project's symbols are asked for once it rests
lsp_finder_query_changed :: proc() {
	g.lsp.finder.due = time.tick_add(time.tick_now(), WORKSPACE_SYMBOLS_DELAY)
}


// Each frame while the finder shows a server's list: asks for a query that has
// rested, and notices a server that went away without answering
lsp_finder_frame :: proc() {
	lf := &g.lsp.finder

	due, has_due := lf.due.?
	if has_due && time.tick_since(due) >= 0 {
		ask_workspace(line_edit_string(&g.finder.query))
	}

	if lf.request != 0 && !langs.request_waiting(lf.request, lf.client) {
		lf.request = 0
		finder_set_status("The language server stopped before answering")
	}
}


// A query is waiting to be asked: frames must keep coming until then
lsp_finder_busy :: proc() -> bool {
	return g.lsp.finder.due != nil
}


// The finder closed: its answer is no longer wanted
lsp_finder_closed :: proc() {
	lf := &g.lsp.finder
	if lf.request != 0 do langs.cancel_request(lf.request, lf.client)

	lf.client = nil
	lf.request = 0
	lf.due = nil
}


lsp_finder_destroy :: proc() {
	delete(g.lsp.finder.query)
	g.lsp.finder = {}
}


@(private = "file")
waiting_for :: proc(c: ^langs.Client, id: int) {
	lf := &g.lsp.finder
	lf.client = c
	lf.request = id
	finder_set_status(fmt.tprintf("Asking %s…", c.name))
}


@(private = "file")
workspace_symbols_client :: proc() -> ^langs.Client {
	if e := focused_editor(); e != nil {
		c := langs.client_with(&e.lsp, .Workspace_Symbols)
		if c != nil do return c
	}

	for c in langs.state.clients {
		if c.state == .Running && lsp.has_feature(c.caps, .Workspace_Symbols) {
			return c
		}
	}
	return nil
}


// Asks for the project's symbols matching `query`, instead of what was asked
// before
@(private = "file")
ask_workspace :: proc(query: string) {
	lf := &g.lsp.finder
	lf.due = nil
	if lf.request != 0 {
		langs.cancel_request(lf.request, lf.client)
		lf.request = 0
	}

	c := lf.client
	if !client_alive(c) || c.state != .Running {
		finder_set_status("The language server isn't running")
		return
	}

	id := lsp.request_symbols(c.client, query)
	langs.track_request(nil, c, .Workspace_Symbols, id, 0)
	waiting_for(c, id)
	set_string(&lf.query, query)
}


// Whether a client is still in the list (it may have been removed and freed)
@(private = "file")
client_alive :: proc(c: ^langs.Client) -> bool {
	if c == nil do return false
	for x in langs.state.clients {
		if x == c do return true
	}
	return false
}


// --- Answers -----------------------------------------------------------------------

// The answer the finder waits for: its items, or why there are none
lsp_finder_response :: proc(r: langs.Request, resp: lsp.Response) {
	uitime.timed(&langs.ui_share)
	lf := &g.lsp.finder
	if !g.finder.open || r.id != lf.request || r.client != lf.client {
		return
	}
	lf.request = 0

	if resp.error != "" {
		finder_set_status(fmt.tprintf("%s: %s", r.client.name, resp.error))
		return
	}

	#partial switch x in resp.result {
	case []lsp.Symbol:
		items := symbol_items(x, r.client.encoding)
		selected := 0
		if r.feature == .File_Symbols do selected = symbol_at(items, lf.caret)
		finder_set_items(items, selected)

	case []lsp.Place:
		finder_set_items(place_items(x, r.client.encoding))
	}

	if len(g.finder.items) > 0 do return
	#partial switch r.feature {
	case .References:   finder_set_status("No references found")
	case .File_Symbols: finder_set_status("No symbols in this file")
	case .Workspace_Symbols:
		if lf.query != "" do finder_set_status("No symbols found")
	}
}


// The finder's items for symbols (temp), taking their strings
@(private = "file")
symbol_items :: proc(symbols: []lsp.Symbol, encoding: lsp.Encoding) -> []Finder_Item {
	items := make([]Finder_Item, len(symbols), context.temp_allocator)
	targets: Target_Cache
	for &s, i in symbols {
		items[i] = {
			label  = s.name,
			detail = s.detail,
			kind   = s.kind,
			depth  = s.depth,
			path   = s.place.path,
			line   = s.place.position.line,
			target = cached_target(&targets, s.place, encoding),
		}
		s.name, s.detail, s.place.path = "", "", ""
	}
	return items
}


// The finder's items for places (temp), their lines as labels, taking their
// strings
@(private = "file")
place_items :: proc(places: []lsp.Place, encoding: lsp.Encoding) -> []Finder_Item {
	items := make([]Finder_Item, len(places), context.temp_allocator)
	targets: Target_Cache
	for &p, i in places {
		items[i] = {
			label  = p.preview,
			path   = p.path,
			line   = p.position.line,
			target = cached_target(&targets, p, encoding),
		}
		p.preview, p.path = "", ""
	}
	return items
}


// The last symbol at or before an offset of the outline's file: the one the
// caret is in, or after
@(private = "file")
symbol_at :: proc(items: []Finder_Item, offset: int) -> int {
	found := 0
	for item, i in items {
		at, known := item.target.(int)
		if known && at <= offset {
			found = i
		}
	}
	return found
}


// The open file of the places before, which are mostly in the same file
@(private = "file")
Target_Cache :: struct {
	path:   string,
	editor: ^Editor,
}


@(private = "file")
cached_target :: proc(
	cache: ^Target_Cache,
	place: lsp.Place,
	encoding: lsp.Encoding,
) -> Open_Target {
	if place.path != cache.path {
		cache.path = place.path
		cache.editor = editor_with_path(place.path)
	}
	return place_target(place, encoding, cache.editor)
}


// A symbol kind's short name, in the color of its role
symbol_kind :: proc(kind: int) -> (name: string, color: clay.Color) {
	if kind <= 0 || kind >= len(SYMBOL_KINDS) {
		return "", gfx.theme.text_dim
	}
	k := SYMBOL_KINDS[kind]
	return k.name, gfx.theme.syntax[k.color]
}
