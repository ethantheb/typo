package lsp

// The parts of the protocol typo uses: what a server can do, and the
// parameters of the messages typo sends

import "core:encoding/json"
import "core:fmt"
import "core:strings"


Sync_Kind :: enum {
	None,
	Full,
	Incremental,
}

// What a server said it can do, from its initialize result
Capabilities :: struct {
	sync:                Sync_Kind,
	open_close:          bool,
	save:                bool,
	save_text:           bool, // didSave carries the text
	hover:               bool,
	definition:          bool,
	references:          bool,
	document_symbol:     bool,
	workspace_symbol:    bool,
	rename:              bool,
	prepare_rename:      bool,
	completion:          bool,
	completion_resolve:  bool,
	signature_help:      bool,
	completion_triggers: []string, // owned
	signature_triggers:  []string, // owned
}

// What typo asks servers for
Feature :: enum {
	Hover,
	Definition,
	References,
	File_Symbols,
	Workspace_Symbols,
	Completion,
	Completion_Resolve,
	Signature_Help,
	Prepare_Rename,
	Rename,
}


// Whether a server said it can do `feature`
has_feature :: proc(caps: Capabilities, feature: Feature) -> bool {
	switch feature {
	case .Hover:              return caps.hover
	case .Definition:         return caps.definition
	case .References:         return caps.references
	case .File_Symbols:       return caps.document_symbol
	case .Workspace_Symbols:  return caps.workspace_symbol
	case .Completion:         return caps.completion
	case .Completion_Resolve: return caps.completion_resolve
	case .Signature_Help:     return caps.signature_help
	case .Prepare_Rename:     return caps.prepare_rename
	case .Rename:             return caps.rename
	}
	return false
}


// What typo can do, sent with initialize
@(private = "file")
CLIENT_CAPABILITIES :: `{
	"general": {"positionEncodings": ["utf-8", "utf-16"]},
	"textDocument": {
		"synchronization": {"didSave": true},
		"hover": {"contentFormat": ["markdown", "plaintext"]},
		"definition": {"linkSupport": true},
		"references": {},
		"documentSymbol": {"hierarchicalDocumentSymbolSupport": true},
		"completion": {
			"completionItem": {
				"snippetSupport": true,
				"documentationFormat": ["markdown", "plaintext"],
				"resolveSupport": {"properties": ["documentation", "detail"]},
				"labelDetailsSupport": true
			},
			"completionList": {"itemDefaults": ["editRange", "insertTextFormat"]},
			"contextSupport": true
		},
		"signatureHelp": {
			"signatureInformation": {
				"documentationFormat": ["markdown", "plaintext"],
				"parameterInformation": {"labelOffsetSupport": true},
				"activeParameterSupport": true
			}
		},
		"rename": {"prepareSupport": true},
		"publishDiagnostics": {"versionSupport": true}
	},
	"workspace": {
		"workspaceFolders": true,
		"configuration": true,
		"symbol": {},
		"applyEdit": true,
		"workspaceEdit": {"documentChanges": true},
		"didChangeWatchedFiles": {}
	},
	"window": {"workDoneProgress": true}
}`


Workspace_Folder :: struct {
	uri:  string `json:"uri"`,
	name: string `json:"name"`,
}

@(private)
Client_Info :: struct {
	name:    string `json:"name"`,
	version: string `json:"version"`,
}

@(private)
Initialize_Params :: struct {
	process_id:   int `json:"processId"`,
	client_info:  Client_Info `json:"clientInfo"`,
	root_uri:     string `json:"rootUri"`,
	root_path:    string `json:"rootPath"`,
	folders:      []Workspace_Folder `json:"workspaceFolders"`,
	capabilities: json.Value `json:"capabilities"`,
	init_options: json.Value `json:"initializationOptions,omitempty"`,
}


@(private)
client_capabilities :: proc() -> json.Value {
	return parse_json(CLIENT_CAPABILITIES)
}


// Reads the capabilities object of an initialize result
parse_capabilities :: proc(v: json.Value, allocator := context.allocator) -> (caps: Capabilities) {
	// Document sync: a kind, or options
	#partial switch sync in get(v, "textDocumentSync") {
	case json.Integer:
		caps.sync = Sync_Kind(clamp(int(sync), 0, 2))
		caps.open_close = sync > 0
		caps.save = sync > 0
	case json.Object:
		kind, _ := get_int(sync, "change")
		caps.sync = Sync_Kind(clamp(kind, 0, 2))
		caps.open_close = get_bool(sync, "openClose")
		caps.save = has(sync, "save")
		caps.save_text = get_bool(sync, "save", "includeText")
	}

	caps.hover = has(v, "hoverProvider")
	caps.definition = has(v, "definitionProvider")
	caps.references = has(v, "referencesProvider")
	caps.document_symbol = has(v, "documentSymbolProvider")
	caps.workspace_symbol = has(v, "workspaceSymbolProvider")
	caps.rename = has(v, "renameProvider")
	caps.prepare_rename = get_bool(v, "renameProvider", "prepareProvider")
	caps.completion = has(v, "completionProvider")
	caps.completion_resolve = get_bool(v, "completionProvider", "resolveProvider")
	caps.signature_help = has(v, "signatureHelpProvider")

	completion_triggers := get_array(v, "completionProvider", "triggerCharacters")
	caps.completion_triggers = clone_strings(completion_triggers, allocator)
	signature_triggers := get_array(v, "signatureHelpProvider", "triggerCharacters")
	caps.signature_triggers = clone_strings(signature_triggers, allocator)
	return
}


capabilities_destroy :: proc(caps: ^Capabilities, allocator := context.allocator) {
	for s in caps.completion_triggers do delete(s, allocator)
	delete(caps.completion_triggers, allocator)
	for s in caps.signature_triggers do delete(s, allocator)
	delete(caps.signature_triggers, allocator)
	caps^ = {}
}


@(private = "file")
clone_strings :: proc(values: json.Array, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(values), allocator)
	for v in values {
		s, is_string := v.(json.String)
		if is_string do append(&out, strings.clone(s, allocator))
	}
	return out[:]
}


// --- Document sync -----------------------------------------------------------------

Text_Document_Item :: struct {
	uri:         string `json:"uri"`,
	language_id: string `json:"languageId"`,
	version:     int `json:"version"`,
	text:        string `json:"text"`,
}

Text_Document_Id :: struct {
	uri: string `json:"uri"`,
}

Versioned_Document_Id :: struct {
	uri:     string `json:"uri"`,
	version: int `json:"version"`,
}

Did_Open_Params :: struct {
	document: Text_Document_Item `json:"textDocument"`,
}

Did_Close_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
}

// One edit: `range` (in the document as left by the edits before it) replaced
// by `text`. A change without a range replaces the whole document
Content_Change :: struct {
	range: Maybe(Range) `json:"range,omitempty"`,
	text:  string `json:"text"`,
}

Did_Change_Params :: struct {
	document: Versioned_Document_Id `json:"textDocument"`,
	changes:  []Content_Change `json:"contentChanges"`,
}

Did_Save_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
	text:     Maybe(string) `json:"text,omitempty"`,
}

Text_Document_Position :: struct {
	document: Text_Document_Id `json:"textDocument"`,
	position: Position `json:"position"`,
}

Document_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
}

Reference_Context :: struct {
	include_declaration: bool `json:"includeDeclaration"`,
}

Reference_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
	position: Position `json:"position"`,
	ctx:      Reference_Context `json:"context"`,
}

Workspace_Symbol_Params :: struct {
	query: string `json:"query"`,
}

// Why completions are asked for (CompletionTriggerKind)
Completion_Trigger :: enum {
	Invoked    = 1, // typed, or asked for
	Character  = 2, // a trigger character was typed
	Incomplete = 3, // the last list was incomplete
}

Completion_Context :: struct {
	trigger_kind:      int `json:"triggerKind"`,
	trigger_character: string `json:"triggerCharacter,omitempty"`,
}

Completion_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
	position: Position `json:"position"`,
	ctx:      Completion_Context `json:"context"`,
}

Rename_Params :: struct {
	document: Text_Document_Id `json:"textDocument"`,
	position: Position `json:"position"`,
	new_name: string `json:"newName"`,
}

// A file changed on disk (type 2), e.g. rewritten by a rename
File_Event :: struct {
	uri:  string `json:"uri"`,
	type: int `json:"type"`,
}

Did_Change_Watched_Files_Params :: struct {
	changes: []File_Event `json:"changes"`,
}

Apply_Edit_Result :: struct {
	applied: bool `json:"applied"`,
	reason:  string `json:"failureReason,omitempty"`,
}


// --- Results -----------------------------------------------------------------------

Location :: struct {
	uri:   string,
	range: Range,
}

Diagnostic :: struct {
	range:    Range,
	severity: int, // 1 error, 2 warning, 3 information, 4 hint
	message:  string,
	source:   string,
}


// A hover result's contents as Markdown (from the temp allocator): markup, a
// marked string (plain text, or code in a language), or a list of those. ""
// when there is nothing
hover_markdown :: proc(result: json.Value) -> string {
	sb := strings.builder_make(context.temp_allocator)
	write_marked(&sb, get(result, "contents"))
	return strings.trim_space(strings.to_string(sb))
}


@(private = "file")
write_marked :: proc(sb: ^strings.Builder, v: json.Value) {
	#partial switch x in v {
	case json.String:
		strings.write_string(sb, x)

	case json.Object:
		// MarkupContent has a kind; a MarkedString with a language is code
		if language, has_language := x["language"].(json.String); has_language {
			value := get_string(x, "value")
			fmt.sbprintf(sb, "```%s\n%s\n```", language, value)
		} else {
			strings.write_string(sb, get_string(x, "value"))
		}

	case json.Array:
		for item, i in x {
			if i > 0 do strings.write_string(sb, "\n\n")
			write_marked(sb, item)
		}
	}
}


// A hover result's range, if it gave one
hover_range :: proc(result: json.Value) -> (r: Range, ok: bool) {
	range := get(result, "range")
	if range == nil do return {}, false
	return get_range(range), true
}


// The locations of a definition (or references) result, from the temp
// allocator: a Location, a list of them, or a list of LocationLinks (where the
// selection range is the name itself)
parse_locations :: proc(result: json.Value) -> []Location {
	out := make([dynamic]Location, context.temp_allocator)

	#partial switch x in result {
	case json.Object:
		append(&out, parse_location(x))
	case json.Array:
		for item in x do append(&out, parse_location(item))
	}
	return out[:]
}


@(private = "file")
parse_location :: proc(v: json.Value) -> Location {
	if target := get_string(v, "targetUri"); target != "" {
		return {target, get_range(get(v, "targetSelectionRange"))}
	}
	return {get_string(v, "uri"), get_range(get(v, "range"))}
}


// A symbol of a documentSymbol or workspace/symbol result (strings from the
// temp allocator)
Symbol_Info :: struct {
	name:      string,
	detail:    string, // e.g. its signature; may be ""
	container: string, // what it is in; may be ""
	kind:      int,    // SymbolKind, 1-26
	uri:       string,
	start:     Position, // of its name
	depth:     int,      // nesting in a document's outline
}


// The symbols of a result, in its order, from the temp allocator: a tree of
// DocumentSymbols (flattened, parents first; their URI is `uri`, the document
// asked about), or a list of SymbolInformation or WorkspaceSymbols. A
// WorkspaceSymbol whose location has no range is at the file's start
parse_symbols :: proc(result: json.Value, uri := "") -> []Symbol_Info {
	out := make([dynamic]Symbol_Info, context.temp_allocator)
	for v in result.(json.Array) or_else nil {
		if has(v, "selectionRange") {
			add_document_symbol(&out, v, uri, "", 0)
			continue
		}

		append(&out, Symbol_Info {
			name      = get_string(v, "name"),
			container = get_string(v, "containerName"),
			kind      = get_int(v, "kind") or_else 0,
			uri       = get_string(v, "location", "uri"),
			start     = get_position(get(v, "location", "range", "start")),
		})
	}
	return out[:]
}


// A DocumentSymbol, then its children
@(private = "file")
add_document_symbol :: proc(
	out: ^[dynamic]Symbol_Info,
	v: json.Value,
	uri, container: string,
	depth: int,
) {
	name := get_string(v, "name")
	append(out, Symbol_Info {
		name      = name,
		detail    = get_string(v, "detail"),
		container = container,
		kind      = get_int(v, "kind") or_else 0,
		uri       = uri,
		start     = get_position(get(v, "selectionRange", "start")),
		depth     = depth,
	})

	for child in get_array(v, "children") {
		add_document_symbol(out, child, uri, name, depth + 1)
	}
}


// --- Completion and signature help ---------------------------------------------------

// A completion item of a result (strings from the temp allocator)
Completion_Info :: struct {
	label:         string,
	signature:     string, // labelDetails.detail, shown after the label
	detail:        string, // labelDetails.description, else detail
	kind:          int,    // CompletionItemKind, 1-25
	filter:        string, // filterText, may be ""
	sort:          string, // sortText, may be ""
	text:          string, // what is inserted (a snippet if `snippet`)
	snippet:       bool,
	range:         Maybe(Range), // what it replaces; none: the word before the caret
	more:          []Text_Edit,  // additionalTextEdits, e.g. an import
	preselect:     bool,
	documentation: string, // Markdown
	raw:           json.Value, // the item, for completionItem/resolve
}

Text_Edit :: struct {
	range: Range,
	text:  string,
}


// The items of a completion result (a list, or a CompletionList with its item
// defaults), from the temp allocator, and whether the list is incomplete
parse_completions :: proc(result: json.Value) -> (items: []Completion_Info, incomplete: bool) {
	list := result.(json.Array) or_else get_array(result, "items")
	incomplete = get_bool(result, "isIncomplete")
	defaults := get(result, "itemDefaults")

	out := make([]Completion_Info, len(list), context.temp_allocator)
	for v, i in list {
		out[i] = parse_completion(v, defaults)
	}
	return out, incomplete
}


// One completion item, with the list's defaults for what it doesn't say
parse_completion :: proc(v: json.Value, defaults: json.Value = nil) -> Completion_Info {
	item := Completion_Info {
		label     = get_string(v, "label"),
		signature = get_string(v, "labelDetails", "detail"),
		detail    = get_string(v, "labelDetails", "description"),
		kind      = get_int(v, "kind") or_else 0,
		filter    = get_string(v, "filterText"),
		sort      = get_string(v, "sortText"),
		preselect = get_bool(v, "preselect"),
		raw       = v,
	}
	if item.detail == "" do item.detail = get_string(v, "detail")
	item.documentation = markup_text(get(v, "documentation"))

	// What it inserts, and where: its edit (or the list's edit range)
	default_format := get_int(defaults, "insertTextFormat") or_else 1
	format := get_int(v, "insertTextFormat") or_else default_format
	item.snippet = format == 2
	item.text = get_string(v, "insertText")
	if edit := get(v, "textEdit"); edit != nil {
		item.text = get_string(edit, "newText")
		item.range = edit_range(edit)
	} else if range := get(defaults, "editRange"); range != nil {
		text := get_string(v, "textEditText")
		if text != "" do item.text = text
		item.range = edit_range(range)
	}
	if item.text == "" do item.text = item.label

	// The edits elsewhere
	item.more = parse_text_edits(get_array(v, "additionalTextEdits"))
	return item
}


// The range an edit replaces: a TextEdit's, or an InsertReplaceEdit's insert
// range (completing inserts; the rest of the word stays). Also takes an
// item default's range, which has the same two shapes
@(private = "file")
edit_range :: proc(v: json.Value) -> Range {
	if has(v, "insert") do return get_range(get(v, "insert"))
	if has(v, "range") do return get_range(get(v, "range"))
	return get_range(v)
}


// Documentation: a string, or MarkupContent (Markdown or plain text)
markup_text :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return x
	case json.Object: return get_string(x, "value")
	}
	return ""
}


// A snippet as plain text (temp): placeholders become their text, choices their
// first option, variables their default. `sel` is what to select after
// inserting it: the first tabstop's placeholder, else where $0 is, else its end
snippet_text :: proc(snippet: string) -> (text: string, sel: [2]int) {
	p := Snippet_Parser{s = snippet, stop = max(int), final = -1}
	p.out = strings.builder_make(context.temp_allocator)
	snippet_part(&p, nested = false)

	text = strings.to_string(p.out)
	switch {
	case p.stop != max(int): sel = p.sel
	case p.final >= 0:       sel = {p.final, p.final}
	case:                    sel = {len(text), len(text)}
	}
	return
}


@(private = "file")
Snippet_Parser :: struct {
	s:     string,
	i:     int,
	out:   strings.Builder,
	stop:  int,    // the lowest tabstop above 0 so far
	sel:   [2]int, // its placeholder, in out
	final: int,    // where $0 is in out, or -1
}


// Text up to the end, or up to the '}' closing a placeholder (`nested`)
@(private = "file")
snippet_part :: proc(p: ^Snippet_Parser, nested: bool) {
	for p.i < len(p.s) {
		c := p.s[p.i]
		escaped := c == '\\' && p.i + 1 < len(p.s) && strings.index_byte(`$}\,|`, p.s[p.i + 1]) >= 0
		switch {
		case escaped:
			strings.write_byte(&p.out, p.s[p.i + 1])
			p.i += 2
		case c == '}' && nested:
			return
		case c == '$':
			snippet_dollar(p)
		case:
			strings.write_byte(&p.out, c)
			p.i += 1
		}
	}
}


// "$1", "${1}", "${1:text}", "${1|one,two|}", "$NAME" or "${NAME:default}"
@(private = "file")
snippet_dollar :: proc(p: ^Snippet_Parser) {
	p.i += 1
	if p.i >= len(p.s) {
		strings.write_byte(&p.out, '$')
		return
	}

	at := strings.builder_len(p.out)
	c := p.s[p.i]
	switch {
	case is_digit(c):
		snippet_stop(p, snippet_number(p), at, at)

	case c == '{':
		p.i += 1
		if p.i < len(p.s) && is_digit(p.s[p.i]) {
			n := snippet_number(p)
			if p.i < len(p.s) && p.s[p.i] == ':' {
				p.i += 1
				snippet_part(p, nested = true)
			} else if p.i < len(p.s) && p.s[p.i] == '|' {
				snippet_choice(p)
			}
			snippet_stop(p, n, at, strings.builder_len(p.out))
		} else {
			// A variable: its default, if any
			snippet_name(p)
			if p.i < len(p.s) && p.s[p.i] == ':' {
				p.i += 1
				snippet_part(p, nested = true)
			}
		}
		if p.i < len(p.s) && p.s[p.i] == '}' {
			p.i += 1
		}

	case is_name_char(c):
		snippet_name(p) // a variable without a default: nothing

	case:
		strings.write_byte(&p.out, '$')
	}
}


// A choice's first option; skips to the '}'
@(private = "file")
snippet_choice :: proc(p: ^Snippet_Parser) {
	p.i += 1 // '|'
	first := true
	for p.i < len(p.s) && p.s[p.i] != '}' {
		c := p.s[p.i]
		if c == ',' || c == '|' {
			first = false
		}
		if first do strings.write_byte(&p.out, c)
		p.i += 1
	}
}


@(private = "file")
snippet_stop :: proc(p: ^Snippet_Parser, n, lo, hi: int) {
	if n == 0 {
		if p.final < 0 do p.final = lo
	} else if n < p.stop {
		p.stop = n
		p.sel = {lo, hi}
	}
}


@(private = "file")
snippet_number :: proc(p: ^Snippet_Parser) -> int {
	n := 0
	for p.i < len(p.s) && is_digit(p.s[p.i]) {
		n = n * 10 + int(p.s[p.i] - '0')
		p.i += 1
	}
	return n
}


@(private = "file")
snippet_name :: proc(p: ^Snippet_Parser) {
	for p.i < len(p.s) && is_name_char(p.s[p.i]) {
		p.i += 1
	}
}


@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}


@(private = "file")
is_name_char :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c)
}


// The active signature of a signatureHelp result (temp)
Signature_Info :: struct {
	label:         string,
	param:         Maybe([2]int), // the active parameter in label, as the server's columns
	param_label:   string,        // or as its text, to look for in label
	documentation: string,        // Markdown: the parameter's, then the signature's
	index, count:  int,           // which signature of how many (0 = none)
}


parse_signature_help :: proc(result: json.Value) -> Signature_Info {
	signatures := get_array(result, "signatures")
	if len(signatures) == 0 do return {}

	index := clamp(get_int(result, "activeSignature") or_else 0, 0, len(signatures) - 1)
	s := signatures[index]
	info := Signature_Info {
		label = get_string(s, "label"),
		index = index,
		count = len(signatures),
	}

	// The active parameter: the signature's, else the result's
	active := get_int(s, "activeParameter") or_else (get_int(result, "activeParameter") or_else 0)
	params := get_array(s, "parameters")
	param_doc := ""
	if active >= 0 && active < len(params) {
		p := params[active]
		#partial switch label in get(p, "label") {
		case json.String:
			info.param_label = label
		case json.Array:
			if len(label) == 2 {
				lo, _ := get_int(label[0])
				hi, _ := get_int(label[1])
				info.param = [2]int{lo, hi}
			}
		}
		param_doc = markup_text(get(p, "documentation"))
	}

	signature_doc := markup_text(get(s, "documentation"))
	switch {
	case param_doc != "" && signature_doc != "":
		info.documentation = fmt.tprintf("%s\n\n%s", param_doc, signature_doc)
	case param_doc != "":
		info.documentation = param_doc
	case:
		info.documentation = signature_doc
	}
	return info
}


// --- Rename and workspace edits ------------------------------------------------------

// What a prepareRename result allows (temp)
Prepare_Info :: struct {
	range:       Maybe(Range), // the name; none: the word at the position
	placeholder: string,       // the name to start from; may be ""
}

// One document's edits of a WorkspaceEdit (temp)
Document_Edit_Info :: struct {
	uri:     string,
	version: Maybe(int), // the version of the document the edits are for, if said
	edits:   []Text_Edit,
}


// A prepareRename result: a Range, {range, placeholder}, or {defaultBehavior}.
// Not ok when it is null: nothing there can be renamed
parse_prepare_rename :: proc(result: json.Value) -> (info: Prepare_Info, ok: bool) {
	obj, is_object := result.(json.Object)
	if !is_object do return {}, false

	switch {
	case "range" in obj:
		info.range = get_range(obj["range"])
		info.placeholder = get_string(obj, "placeholder")
	case "start" in obj:
		info.range = get_range(obj)
	case get_bool(obj, "defaultBehavior"):
	case:
		return {}, false
	}
	return info, true
}


// The documents a WorkspaceEdit changes, from the temp allocator: its
// documentChanges (TextDocumentEdits), else its changes by URI. Not ok if it
// creates, renames or deletes files, which typo doesn't offer
parse_workspace_edit :: proc(v: json.Value) -> (docs: []Document_Edit_Info, ok: bool) {
	out := make([dynamic]Document_Edit_Info, context.temp_allocator)

	if changes, has_changes := get(v, "documentChanges").(json.Array); has_changes {
		for change in changes {
			if get_string(change, "kind") != "" do return nil, false

			info := Document_Edit_Info {
				uri   = get_string(change, "textDocument", "uri"),
				edits = parse_text_edits(get_array(change, "edits")),
			}
			if version, has_version := get_int(change, "textDocument", "version"); has_version {
				info.version = version
			}
			append(&out, info)
		}
		return out[:], true
	}

	changes, _ := get(v, "changes").(json.Object)
	for uri, edits in changes {
		edits_list, _ := edits.(json.Array)
		append(&out, Document_Edit_Info{uri = uri, edits = parse_text_edits(edits_list)})
	}
	return out[:], true
}


// TextEdits (or AnnotatedTextEdits), from the temp allocator
parse_text_edits :: proc(list: json.Array) -> []Text_Edit {
	out := make([]Text_Edit, len(list), context.temp_allocator)
	for edit, i in list {
		out[i] = {get_range(get(edit, "range")), get_string(edit, "newText")}
	}
	return out
}


// The diagnostics of a publishDiagnostics notification, from the temp
// allocator. A diagnostic without a severity counts as an error
parse_diagnostics :: proc(params: json.Value) -> []Diagnostic {
	list := get_array(params, "diagnostics")
	out := make([]Diagnostic, len(list), context.temp_allocator)
	for v, i in list {
		severity, has_severity := get_int(v, "severity")
		out[i] = {
			range    = get_range(get(v, "range")),
			severity = has_severity ? clamp(severity, 1, 4) : 1,
			message  = get_string(v, "message"),
			source   = get_string(v, "source"),
		}
	}
	return out
}
