package fake_server

// A language server for tests (build.py builds it as build/fake_lsp). It keeps
// the documents it is sent, applying each change the way a real server would,
// so a test can ask for its copy ("fake/text") and compare it with the buffer.
// Hover returns the word under the position; "FIXME" in a document is reported
// as a diagnostic. Symbols are lines "name :: ..." with indented "name := ..."
// inside them; references are the word wherever it is in the open documents.
// Completion offers every word of the open documents (but the one typed), a
// snippet ("fake_snippet") and an item that adds a line at the top
// ("fake_import"); resolving adds documentation; `--incomplete` makes it list
// only the first few words starting with the one typed, as an incomplete list.
// `--complete-empty` makes completion answer an empty list, `--complete-error`
// an error, and `--complete-delay <ms>` wait that long before answering.
// Signature help is for an unclosed "name(" on the line: "name(a, b, c)".
// Renaming changes the word in the open documents and in its root folder's
// files of the same kind (up to 1 MB) that aren't open. "fake/apply" makes it
// ask the client to replace each "FIXME" of a document with "FIXED"
// (workspace/applyEdit), and answers with the client's answer. `--utf16` makes
// it refuse UTF-8 positions; "fake/crash" makes it exit at once. `--copy-to
// <path>` copies the program there and exits (an install command for the perf
// suite)

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import lsp ".."


Server :: struct {
	encoding:   lsp.Encoding,
	incomplete: bool,              // completion lists a few words starting with the typed one
	completion: enum {
		Words,
		Empty,
		Error,
	},
	delay:      time.Duration,     // before answering completion
	root:       string,            // owned; the folder from initialize
	docs:       map[string]string, // by URI, owned
	versions:   map[string]int,    // by URI (keys are the docs' keys)
	applying:   json.Value,        // the id of a fake/apply waiting for the client
	out:        [dynamic]u8,
}

// The most words listed with --incomplete
@(private = "file")
INCOMPLETE_LIMIT :: 5


// Copies this program to `path`, making its folder
copy_self :: proc(path: string) -> bool {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return false

	data, read_err := os.read_entire_file(self, context.temp_allocator)
	if read_err != nil do return false

	_ = os.make_directory_all(os.dir(path))
	fmt.printfln("copying %s to %s", self, path)
	return os.write_entire_file(path, data) == nil
}


main :: proc() {
	s: Server
	utf16_only := false
	for arg, i in os.args[1:] {
		if arg == "--utf16" do utf16_only = true
		if arg == "--incomplete" do s.incomplete = true
		if arg == "--complete-empty" do s.completion = .Empty
		if arg == "--complete-error" do s.completion = .Error
		if arg == "--complete-delay" && i + 2 < len(os.args) {
			ms, _ := strconv.parse_int(os.args[i + 2])
			s.delay = time.Duration(ms) * time.Millisecond
		}
		if arg == "--copy-to" && i + 2 < len(os.args) {
			os.exit(copy_self(os.args[i + 2]) ? 0 : 1)
		}
	}
	s.encoding = utf16_only ? .UTF16 : .UTF8
	fmt.eprintln("fake server started")

	framer: lsp.Framer
	buf: [64 * 1024]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 {
			break
		}

		lsp.framer_feed(&framer, buf[:n])
		for body in lsp.framer_next(&framer) {
			handle(&s, string(body))
			free_all(context.temp_allocator)
		}
	}
	os.exit(1)
}


@(private = "file")
handle :: proc(s: ^Server, body: string) {
	v, err := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return

	// Like servers that read ids as 32-bit integers (Rust's lsp-server), a
	// message with a larger id can't be read
	id := lsp.get(v, "id")
	n, is_int := id.(json.Integer)
	if is_int && (n > i64(max(i32)) || n < i64(min(i32))) {
		return
	}

	params := lsp.get(v, "params")
	switch lsp.get_string(v, "method") {
	case "initialize":
		root, _ := lsp.path_from_uri(lsp.get_string(params, "rootUri"))
		s.root = root
		reply(s, id, initialize_result(s))

	case "shutdown":
		reply(s, id, nil)

	case "exit":
		os.exit(0)

	case "fake/crash":
		os.exit(3)

	case "fake/text":
		reply(s, id, s.docs[lsp.get_string(params, "uri")])

	case "textDocument/didOpen":
		uri := lsp.get_string(params, "textDocument", "uri")
		set_doc(s, uri, lsp.get_string(params, "textDocument", "text"))
		set_version(s, uri, params)
		publish(s, uri)

	case "textDocument/didChange":
		uri := lsp.get_string(params, "textDocument", "uri")
		for change in lsp.get_array(params, "contentChanges") {
			apply_change(s, uri, change)
		}
		set_version(s, uri, params)
		publish(s, uri)

	case "textDocument/didClose":
		uri := lsp.get_string(params, "textDocument", "uri")
		delete_key(&s.versions, uri)
		key, text := delete_key(&s.docs, uri)
		delete(key)
		delete(text)

	case "textDocument/definition":
		// The word's first occurrence in the document
		uri := lsp.get_string(params, "textDocument", "uri")
		doc := s.docs[uri]
		word := word_at(s, uri, lsp.get_position(lsp.get(params, "position")))
		at := word == "" ? -1 : strings.index(doc, word)
		if at < 0 {
			reply(s, id, nil)
		} else {
			start := position_of(doc, at, s.encoding)
			end := position_of(doc, at + len(word), s.encoding)
			reply(s, id, lsp.Location{uri, {start, end}})
		}

	case "textDocument/documentSymbol":
		uri := lsp.get_string(params, "textDocument", "uri")
		reply(s, id, document_symbols(s, s.docs[uri]))

	case "workspace/symbol":
		reply(s, id, workspace_symbols(s, lsp.get_string(params, "query")))

	case "textDocument/references":
		uri := lsp.get_string(params, "textDocument", "uri")
		word := word_at(s, uri, lsp.get_position(lsp.get(params, "position")))
		reply(s, id, references(s, word))

	case "textDocument/completion":
		uri := lsp.get_string(params, "textDocument", "uri")
		if s.delay > 0 do time.sleep(s.delay)
		switch s.completion {
		case .Words:
			reply(s, id, completions(s, uri, lsp.get_position(lsp.get(params, "position"))))
		case .Empty:
			reply(s, id, []Completion_Item{})
		case .Error:
			reply_error(s, id, "completion failed")
		}

	case "completionItem/resolve":
		label := lsp.get_string(params, "label")
		item := params.(json.Object) or_else {}
		item["documentation"] = json.String(fmt.tprintf("**%s**\n\ndocs for %s", label, label))
		reply(s, id, item)

	case "textDocument/signatureHelp":
		uri := lsp.get_string(params, "textDocument", "uri")
		help, in_call := signature_help(s, uri, lsp.get_position(lsp.get(params, "position")))
		if in_call {
			reply(s, id, help)
		} else {
			reply(s, id, nil)
		}

	case "textDocument/prepareRename":
		uri := lsp.get_string(params, "textDocument", "uri")
		p := lsp.get_position(lsp.get(params, "position"))
		lo, hi := word_span(s, uri, p)
		if lo == hi {
			reply(s, id, nil)
		} else {
			doc := s.docs[uri]
			r := lsp.Range{position_of(doc, lo, s.encoding), position_of(doc, hi, s.encoding)}
			reply(s, id, Prepare_Rename{r, doc[lo:hi]})
		}

	case "textDocument/rename":
		uri := lsp.get_string(params, "textDocument", "uri")
		word := word_at(s, uri, lsp.get_position(lsp.get(params, "position")))
		reply(s, id, rename_edit(s, uri, word, lsp.get_string(params, "newName")))

	case "fake/apply":
		s.applying = clone_id(id)
		uri := lsp.get_string(params, "uri")
		request(s, "fake-apply", "workspace/applyEdit", fixed_edit(s, uri))

	case "":
		// The client's answer to workspace/applyEdit, passed on
		if lsp.get_string(v, "id") == "fake-apply" && s.applying != nil {
			reply(s, s.applying, lsp.get(v, "result"))
			s.applying = nil
		}

	case "textDocument/hover":
		uri := lsp.get_string(params, "textDocument", "uri")
		word := word_at(s, uri, lsp.get_position(lsp.get(params, "position")))
		if word == "" {
			reply(s, id, nil)
		} else {
			Contents :: struct {
				kind:  string `json:"kind"`,
				value: string `json:"value"`,
			}
			Hover :: struct {
				contents: Contents `json:"contents"`,
			}
			reply(s, id, Hover{{"markdown", fmt.tprintf("**%s**", word)}})
		}
	}
}


@(private = "file")
initialize_result :: proc(s: ^Server) -> json.Value {
	encoding := s.encoding == .UTF8 ? "utf-8" : "utf-16"
	text := fmt.tprintf(
		`{{"capabilities": {{"positionEncoding": "%s", ` +
		`"textDocumentSync": {{"openClose": true, "change": 2, "save": {{}}}}, ` +
		`"hoverProvider": true, "definitionProvider": true, "referencesProvider": true, ` +
		`"documentSymbolProvider": true, "workspaceSymbolProvider": true, ` +
		`"completionProvider": {{"triggerCharacters": ["."], "resolveProvider": true}}, ` +
		`"signatureHelpProvider": {{"triggerCharacters": ["(", ","]}}, ` +
		`"renameProvider": {{"prepareProvider": true}}}}, ` +
		`"serverInfo": {{"name": "fake"}}}}`,
		encoding,
	)
	return lsp.parse_json(text)
}


@(private = "file")
set_doc :: proc(s: ^Server, uri, text: string) {
	if old, found := s.docs[uri]; found {
		delete(old)
		s.docs[uri] = strings.clone(text)
	} else {
		s.docs[strings.clone(uri)] = strings.clone(text)
	}
}


// Applies one content change: the range in the server's encoding, or the
// whole document
@(private = "file")
apply_change :: proc(s: ^Server, uri: string, change: json.Value) {
	text := lsp.get_string(change, "text")
	if lsp.get(change, "range") == nil {
		set_doc(s, uri, text)
		return
	}

	doc := s.docs[uri]
	r := lsp.get_range(lsp.get(change, "range"))
	lo := offset_of(doc, r.start, s.encoding)
	hi := offset_of(doc, r.end, s.encoding)
	updated := strings.concatenate({doc[:lo], text, doc[hi:]}, context.temp_allocator)
	set_doc(s, uri, updated)
}


// The byte offset of a position
@(private = "file")
offset_of :: proc(doc: string, p: lsp.Position, enc: lsp.Encoding) -> int {
	start := 0
	for _ in 0 ..< p.line {
		lf := strings.index_byte(doc[start:], '\n')
		if lf < 0 do return len(doc)
		start += lf + 1
	}

	end := strings.index_byte(doc[start:], '\n')
	line := end < 0 ? doc[start:] : doc[start:][:end]
	line = strings.trim_suffix(line, "\r")
	return start + lsp.from_column(line, p.character, enc)
}


// The position of a byte offset
@(private = "file")
position_of :: proc(doc: string, offset: int, enc: lsp.Encoding) -> lsp.Position {
	line := strings.count(doc[:offset], "\n")
	start := strings.last_index_byte(doc[:offset], '\n') + 1
	return {line, lsp.to_column(doc[start:], offset - start, enc)}
}


@(private = "file")
word_at :: proc(s: ^Server, uri: string, p: lsp.Position) -> string {
	lo, hi := word_span(s, uri, p)
	return s.docs[uri][lo:hi]
}


// The byte range of the word at a position
@(private = "file")
word_span :: proc(s: ^Server, uri: string, p: lsp.Position) -> (lo, hi: int) {
	doc := s.docs[uri]
	at := offset_of(doc, p, s.encoding)

	lo, hi = at, at
	for lo > 0 && is_word(doc[lo - 1]) {
		lo -= 1
	}
	for hi < len(doc) && is_word(doc[hi]) {
		hi += 1
	}
	return
}


@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}


// --- Symbols and references --------------------------------------------------------

@(private = "file")
Document_Symbol :: struct {
	name:            string `json:"name"`,
	detail:          string `json:"detail"`,
	kind:            int `json:"kind"`,
	range:           lsp.Range `json:"range"`,
	selection_range: lsp.Range `json:"selectionRange"`,
	children:        [dynamic]Document_Symbol `json:"children"`,
}

@(private = "file")
Symbol_Information :: struct {
	name:     string `json:"name"`,
	kind:     int `json:"kind"`,
	location: lsp.Location `json:"location"`,
}

@(private = "file")
FUNCTION :: 12
@(private = "file")
VARIABLE :: 13


// A document's outline: each line starting "name :: " is a function, and each
// indented "name := " under it a variable inside it
@(private = "file")
document_symbols :: proc(s: ^Server, doc: string) -> []Document_Symbol {
	out := make([dynamic]Document_Symbol, context.temp_allocator)
	lines := Line_Cursor{doc = doc, encoding = s.encoding}
	for start := 0; start < len(doc); {
		end := strings.index_byte(doc[start:], '\n')
		end = end < 0 ? len(doc) : start + end
		line := doc[start:end]
		line_start := start
		start = end + 1

		// "name :: " at the start of a line, or "name := " indented
		top := !strings.has_prefix(line, "\t")
		marker := top ? " :: " : " := "
		at := strings.index(line, marker)
		if at < 0 do continue

		name := strings.trim_space(line[:at])
		if name == "" || strings.contains_any(name, " ,(") {
			continue
		}

		lo := line_start + strings.index(line, name)
		r := name_range(&lines, lo, len(name))
		symbol := Document_Symbol{name = name, range = r, selection_range = r}
		symbol.children = make([dynamic]Document_Symbol, context.temp_allocator)
		if top {
			symbol.kind = FUNCTION
			symbol.detail = strings.trim_space(line[at + len(marker):])
			append(&out, symbol)
		} else if len(out) > 0 {
			symbol.kind = VARIABLE
			append(&out[len(out) - 1].children, symbol)
		}
	}
	return out[:]
}


// Positions in a document, worked out going forward from the last one
@(private = "file")
Line_Cursor :: struct {
	doc:        string,
	encoding:   lsp.Encoding,
	offset:     int, // lines before it are counted
	line:       int,
	line_start: int,
}


// The range of `n` bytes at `lo`, which is past the cursor's last one
@(private = "file")
name_range :: proc(c: ^Line_Cursor, lo, n: int) -> lsp.Range {
	for i in c.offset ..< lo {
		if c.doc[i] == '\n' {
			c.line += 1
			c.line_start = i + 1
		}
	}
	c.offset = lo

	text := c.doc[c.line_start:]
	col := lo - c.line_start
	start := lsp.Position{c.line, lsp.to_column(text, col, c.encoding)}
	end := lsp.Position{c.line, lsp.to_column(text, col + n, c.encoding)}
	return {start, end}
}


// The open documents' functions whose names contain the query (any case)
@(private = "file")
workspace_symbols :: proc(s: ^Server, query: string) -> []Symbol_Information {
	query := strings.to_lower(query, context.temp_allocator)
	out := make([dynamic]Symbol_Information, context.temp_allocator)
	for uri, doc in s.docs {
		for symbol in document_symbols(s, doc) {
			name := strings.to_lower(symbol.name, context.temp_allocator)
			if !strings.contains(name, query) do continue

			location := lsp.Location{uri, symbol.selection_range}
			append(&out, Symbol_Information{symbol.name, symbol.kind, location})
		}
	}
	return out[:]
}


// Every place the word is in the open documents, as a whole word
@(private = "file")
references :: proc(s: ^Server, word: string) -> []lsp.Location {
	out := make([dynamic]lsp.Location, context.temp_allocator)
	for uri, doc in s.docs {
		for r in word_ranges(s, doc, word) {
			append(&out, lsp.Location{uri, r})
		}
	}
	return out[:]
}


// The places of a whole word in a text
@(private = "file")
word_ranges :: proc(s: ^Server, doc, word: string) -> []lsp.Range {
	out := make([dynamic]lsp.Range, context.temp_allocator)
	if word == "" do return out[:]

	lines := Line_Cursor{doc = doc, encoding = s.encoding}
	from := 0
	for {
		at := strings.index(doc[from:], word)
		if at < 0 do break
		at += from
		from = at + len(word)

		before_ok := at == 0 || !is_word(doc[at - 1])
		after_ok := from >= len(doc) || !is_word(doc[from])
		whole := before_ok && after_ok
		if !whole do continue

		append(&out, name_range(&lines, at, len(word)))
	}
	return out[:]
}


// --- Rename and workspace/applyEdit --------------------------------------------------

// Larger files on disk aren't renamed in
@(private = "file")
MAX_RENAMED_FILE :: 1024 * 1024

@(private = "file")
Prepare_Rename :: struct {
	range:       lsp.Range `json:"range"`,
	placeholder: string `json:"placeholder"`,
}

@(private = "file")
Versioned_Id :: struct {
	uri:     string `json:"uri"`,
	version: Maybe(int) `json:"version"`, // null for a file that isn't open
}

@(private = "file")
Document_Edit :: struct {
	document: Versioned_Id `json:"textDocument"`,
	edits:    []Text_Edit `json:"edits"`,
}

@(private = "file")
Document_Changes :: struct {
	document_changes: []Document_Edit `json:"documentChanges"`,
}

@(private = "file")
Apply_Params :: struct {
	label: string `json:"label"`,
	edit:  json.Value `json:"edit"`,
}


@(private = "file")
set_version :: proc(s: ^Server, uri: string, params: json.Value) {
	version := lsp.get_int(params, "textDocument", "version") or_else 0
	for key in s.docs {
		if key == uri do s.versions[key] = version
	}
}


// The word replaced in the open documents (with their versions) and in the
// files of the root folder with the same extension as `uri` that aren't open
// (and aren't large)
@(private = "file")
rename_edit :: proc(s: ^Server, uri, word, new_name: string) -> Document_Changes {
	ext := uri[strings.last_index_byte(uri, '.') + 1:]
	out := make([dynamic]Document_Edit, context.temp_allocator)
	open_paths := make(map[string]bool, allocator = context.temp_allocator)

	for doc_uri, doc in s.docs {
		path, _ := lsp.path_from_uri(doc_uri, context.temp_allocator)
		open_paths[strings.to_lower(path, context.temp_allocator)] = true

		edits := rename_edits(s, doc, word, new_name)
		if len(edits) == 0 do continue
		append(&out, Document_Edit{{doc_uri, s.versions[doc_uri]}, edits})
	}

	files, _ := os.read_all_directory_by_path(s.root, context.temp_allocator)
	for f in files {
		lower := strings.to_lower(f.fullpath, context.temp_allocator)
		small := f.size <= MAX_RENAMED_FILE
		if !small || !strings.has_suffix(f.name, ext) || open_paths[lower] {
			continue
		}

		data, err := os.read_entire_file(f.fullpath, context.temp_allocator)
		if err != nil do continue

		edits := rename_edits(s, string(data), word, new_name)
		if len(edits) == 0 do continue
		file_uri := lsp.uri_from_path(f.fullpath, context.temp_allocator)
		append(&out, Document_Edit{{file_uri, nil}, edits})
	}
	return {out[:]}
}


@(private = "file")
rename_edits :: proc(s: ^Server, doc, word, new_name: string) -> []Text_Edit {
	ranges := word_ranges(s, doc, word)
	edits := make([]Text_Edit, len(ranges), context.temp_allocator)
	for r, i in ranges do edits[i] = {r, new_name}
	return edits
}


// Each "FIXME" of a document replaced by "FIXED", as a WorkspaceEdit's changes
@(private = "file")
fixed_edit :: proc(s: ^Server, uri: string) -> Apply_Params {
	edits := make(json.Array, context.temp_allocator)
	for r in word_ranges(s, s.docs[uri], "FIXME") {
		edit := make(json.Object, context.temp_allocator)
		edit["range"] = lsp.parse_json(lsp.to_json(r))
		edit["newText"] = json.String("FIXED")
		append(&edits, edit)
	}

	changes := make(json.Object, context.temp_allocator)
	changes[uri] = edits
	edit := make(json.Object, context.temp_allocator)
	edit["changes"] = changes
	return {"fake", edit}
}


// A request id that outlives this message
@(private = "file")
clone_id :: proc(id: json.Value) -> json.Value {
	#partial switch x in id {
	case json.String: return json.String(strings.clone(x))
	}
	return id
}


// --- Completion and signature help ---------------------------------------------------

@(private = "file")
Completion_Item :: struct {
	label:                 string `json:"label"`,
	kind:                  int `json:"kind"`,
	detail:                string `json:"detail"`,
	insert_text:           string `json:"insertText,omitempty"`,
	insert_text_format:    int `json:"insertTextFormat,omitempty"`,
	text_edit:             Maybe(Text_Edit) `json:"textEdit,omitempty"`,
	additional_text_edits: []Text_Edit `json:"additionalTextEdits,omitempty"`,
}

@(private = "file")
Text_Edit :: struct {
	range:    lsp.Range `json:"range"`,
	new_text: string `json:"newText"`,
}

@(private = "file")
Completion_List :: struct {
	is_incomplete: bool `json:"isIncomplete"`,
	items:         []Completion_Item `json:"items"`,
}


// Every word of the open documents (replacing the word before the position),
// sorted; then "fake_snippet", a snippet, and "fake_import", which also adds a
// line at the top. With --incomplete: the first few words that start with the
// one typed, the list incomplete if there are more
@(private = "file")
completions :: proc(s: ^Server, uri: string, p: lsp.Position) -> Completion_List {
	doc := s.docs[uri]
	at := offset_of(doc, p, s.encoding)
	lo := at
	for lo > 0 && is_word(doc[lo - 1]) {
		lo -= 1
	}
	replaced := lsp.Range{position_of(doc, lo, s.encoding), p}

	// The words, once each, but not the one being typed
	words := make(map[string]bool, allocator = context.temp_allocator)
	for _, text in s.docs {
		for i := 0; i < len(text); {
			if !is_word(text[i]) || (text[i] >= '0' && text[i] <= '9') {
				i += 1
				continue
			}
			j := i
			for j < len(text) && is_word(text[j]) {
				j += 1
			}
			typed := raw_data(text) == raw_data(doc) && i == lo
			if j - i >= 2 && !typed {
				words[text[i:j]] = true
			}
			i = j
		}
	}
	labels := make([dynamic]string, 0, len(words), context.temp_allocator)
	for word in words do append(&labels, word)
	slice.sort(labels[:])

	items := make([dynamic]Completion_Item, context.temp_allocator)
	for label in labels {
		edit := Text_Edit{replaced, label}
		append(&items, Completion_Item{label = label, kind = 6, detail = "fake", text_edit = edit})
	}
	if s.incomplete do return incomplete_list(items[:], doc[lo:at])
	append(&items, Completion_Item {
		label              = "fake_snippet",
		kind               = 15,
		insert_text        = "call(${1:arg}, $2)$0",
		insert_text_format = 2,
	})
	top := lsp.Range{{0, 0}, {0, 0}}
	more := make([]Text_Edit, 1, context.temp_allocator)
	more[0] = {top, "// imported\n"}
	append(&items, Completion_Item{label = "fake_import", kind = 9, additional_text_edits = more})
	return {false, items[:]}
}


// The first INCOMPLETE_LIMIT items whose label starts with `typed`, as servers
// that filter and cap their lists do
@(private = "file")
incomplete_list :: proc(items: []Completion_Item, typed: string) -> Completion_List {
	listed := make([dynamic]Completion_Item, context.temp_allocator)
	more := false
	for item in items {
		if !strings.has_prefix(item.label, typed) do continue

		if len(listed) == INCOMPLETE_LIMIT {
			more = true
			break
		}
		append(&listed, item)
	}
	return {more, listed[:]}
}


@(private = "file")
Signature_Information :: struct {
	label:      string `json:"label"`,
	parameters: []Parameter `json:"parameters"`,
}

@(private = "file")
Parameter :: struct {
	label: json.Value `json:"label"`, // a string, or [start, end] in the label
}

@(private = "file")
Signature_Help :: struct {
	signatures:       []Signature_Information `json:"signatures"`,
	active_signature: int `json:"activeSignature"`,
	active_parameter: int `json:"activeParameter"`,
}


// In a call on the position's line (an unclosed "name(" before it): the
// signature "name(a, b, c)", the active parameter counted by commas. Parameter
// c's label is given as columns, the others as text
@(private = "file")
signature_help :: proc(s: ^Server, uri: string, p: lsp.Position) -> (Signature_Help, bool) {
	doc := s.docs[uri]
	at := offset_of(doc, p, s.encoding)
	line_start := strings.last_index_byte(doc[:at], '\n') + 1

	// The unclosed parenthesis, and the commas after it
	depth, commas, paren := 0, 0, -1
	for i := at - 1; i >= line_start; i -= 1 {
		switch doc[i] {
		case ')':
			depth += 1
		case '(':
			if depth == 0 {
				paren = i
			} else {
				depth -= 1
			}
		case ',':
			if depth == 0 do commas += 1
		}
		if paren >= 0 do break
	}
	if paren < 0 do return {}, false

	name_lo := paren
	for name_lo > line_start && is_word(doc[name_lo - 1]) {
		name_lo -= 1
	}
	name := doc[name_lo:paren]
	if name == "" do return {}, false

	label := fmt.tprintf("%s(a, b, c)", name)
	c_at := len(label) - 2
	params := make([]Parameter, 3, context.temp_allocator)
	params[0] = {json.String("a")}
	params[1] = {json.String("b")}
	columns := make(json.Array, 2, context.temp_allocator)
	columns[0] = json.Integer(c_at)
	columns[1] = json.Integer(c_at + 1)
	params[2] = {columns}

	signatures := make([]Signature_Information, 1, context.temp_allocator)
	signatures[0] = {label, params}
	return {signatures, 0, commas}, true
}


// Reports each "FIXME" as a warning, for the document's version
@(private = "file")
publish :: proc(s: ^Server, uri: string) {
	Diagnostic :: struct {
		range:    lsp.Range `json:"range"`,
		severity: int `json:"severity"`,
		message:  string `json:"message"`,
	}
	Params :: struct {
		uri:         string `json:"uri"`,
		version:     int `json:"version"`,
		diagnostics: []Diagnostic `json:"diagnostics"`,
	}

	doc := s.docs[uri]
	found := make([dynamic]Diagnostic, context.temp_allocator)
	line, line_start := 0, 0
	for i := 0; i < len(doc); i += 1 {
		if doc[i] == '\n' {
			line += 1
			line_start = i + 1
			continue
		}
		if !strings.has_prefix(doc[i:], "FIXME") do continue

		text := doc[line_start:i]
		start := lsp.to_column(text, len(text), s.encoding)
		r := lsp.Range{{line, start}, {line, start + 5}}
		append(&found, Diagnostic{r, 2, "fix me"})
	}

	notify(s, "textDocument/publishDiagnostics", Params{uri, s.versions[uri], found[:]})
}


@(private = "file")
reply :: proc(s: ^Server, id: json.Value, result: any) {
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%s,"result":%s}}`,
		lsp.to_json(id),
		lsp.to_json(result),
	)
	write(s, body)
}


@(private = "file")
reply_error :: proc(s: ^Server, id: json.Value, message: string) {
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32603,"message":%s}}}}`,
		lsp.to_json(id),
		lsp.to_json(message),
	)
	write(s, body)
}


@(private = "file")
notify :: proc(s: ^Server, method: string, params: any) {
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","method":%s,"params":%s}}`,
		lsp.to_json(method),
		lsp.to_json(params),
	)
	write(s, body)
}


// A request to the client
@(private = "file")
request :: proc(s: ^Server, id, method: string, params: any) {
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":%s,"method":%s,"params":%s}}`,
		lsp.to_json(id),
		lsp.to_json(method),
		lsp.to_json(params),
	)
	write(s, body)
}


@(private = "file")
write :: proc(s: ^Server, body: string) {
	clear(&s.out)
	lsp.frame_append(&s.out, body)
	_, _ = os.write(os.stdout, s.out[:])
}
