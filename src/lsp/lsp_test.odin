package lsp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../buffer"


// --- Framing -----------------------------------------------------------------------

@(test)
test_framing :: proc(t: ^testing.T) {
	f: Framer
	defer framer_destroy(&f)

	// Two messages in one read, the second split across reads
	stream := make([dynamic]u8, context.temp_allocator)
	frame_append(&stream, `{"a":1}`)
	append(&stream, "Content-Type: x\r\nContent-Length: 7\r\n\r\n{\"b\":2}")
	frame_append(&stream, `{"c":"é"}`)

	got := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(stream); i += 5 {
		framer_feed(&f, stream[i:min(i + 5, len(stream))])
		for body in framer_next(&f) {
			append(&got, strings.clone(string(body), context.temp_allocator))
		}
	}

	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0], `{"a":1}`)
		testing.expect_value(t, got[1], `{"b":2}`)
		testing.expect_value(t, got[2], `{"c":"é"}`)
	}
}


@(test)
test_framing_skips_header_without_length :: proc(t: ^testing.T) {
	f: Framer
	defer framer_destroy(&f)

	framer_feed(&f, transmute([]u8)string("X-Junk: 1\r\n\r\nContent-length: 2\r\n\r\n{}"))
	body, ok := framer_next(&f)
	testing.expect(t, ok)
	testing.expect_value(t, string(body), "{}")
}


// --- Positions and URIs ------------------------------------------------------------

@(test)
test_columns :: proc(t: ^testing.T) {
	text := "aé😀b" // 1, 2, 4 and 1 bytes; 1, 1, 2 and 1 UTF-16 units

	testing.expect_value(t, utf16_len(text), 5)
	testing.expect_value(t, to_column(text, 3, .UTF16), 2)
	testing.expect_value(t, to_column(text, 7, .UTF16), 4)
	testing.expect_value(t, to_column(text, 7, .UTF8), 7)
	testing.expect_value(t, to_column(text, 99, .UTF16), 5)

	testing.expect_value(t, from_column(text, 2, .UTF16), 3)
	testing.expect_value(t, from_column(text, 4, .UTF16), 7)
	testing.expect_value(t, from_column(text, 3, .UTF16), 7) // inside the pair: after it
	testing.expect_value(t, from_column(text, 99, .UTF16), len(text))
	testing.expect_value(t, from_column(text, 2, .UTF8), 3) // inside é: after it
	testing.expect_value(t, from_column(text, -1, .UTF8), 0)
}


@(test)
test_uris :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		uri := uri_from_path(`C:\src\a b\x#.odin`, context.temp_allocator)
		testing.expect_value(t, uri, "file:///C:/src/a%20b/x%23.odin")

		path, ok := path_from_uri("file:///c%3A/src/a%20b/x%23.odin", context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, path, `C:\src\a b\x#.odin`)

		unc := uri_from_path(`\\server\share\f.py`, context.temp_allocator)
		testing.expect_value(t, unc, "file://server/share/f.py")
		back, _ := path_from_uri(unc, context.temp_allocator)
		testing.expect_value(t, back, `\\server\share\f.py`)
	} else {
		uri := uri_from_path("/src/a b/x.odin", context.temp_allocator)
		testing.expect_value(t, uri, "file:///src/a%20b/x.odin")

		path, ok := path_from_uri(uri, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, path, "/src/a b/x.odin")
	}

	_, is_file := path_from_uri("untitled:1", context.temp_allocator)
	testing.expect(t, !is_file)
}


// --- Registry ----------------------------------------------------------------------

@(test)
test_languages :: proc(t: ^testing.T) {
	testing.expect_value(t, language_for_path("src/main.odin"), "odin")
	testing.expect_value(t, language_for_path("a/B.PY"), "python")
	testing.expect_value(t, language_for_path("x/CMakeLists.txt"), "cmake")
	testing.expect_value(t, language_for_path("notes.txt"), "")
	testing.expect_value(t, language_for_path("Makefile"), "")

	extra := []Language{{id = "fortran", extensions = {"f90"}}}
	testing.expect_value(t, language_for_path("x.f90", extra), "fortran")
	testing.expect_value(t, language_name("fortran", extra), "fortran")
	testing.expect_value(t, language_name("cpp"), "C++")

	testing.expect(t, serves(SERVERS[0], "odin"))
	testing.expect(t, !serves(SERVERS[0], "python"))
}


@(test)
test_find_root :: proc(t: ^testing.T) {
	sep := os.Path_Separator_String
	temp := os.get_env("TEMP", context.temp_allocator)
	if temp == "" do temp = "/tmp"
	base := fmt.tprintf("%s%stypo-lsp-root-%d", temp, sep, os.get_pid())
	defer os.remove_all(base)

	project := fmt.tprintf("%s%sproject", base, sep)
	src := fmt.tprintf("%s%ssrc", project, sep)
	_ = os.make_directory_all(src)
	_ = os.write_entire_file(fmt.tprintf("%s%sCargo.toml", project, sep), "")
	file := fmt.tprintf("%s%smain.rs", src, sep)

	root := find_root(file, base, {"Cargo.toml"}, context.temp_allocator)
	testing.expect_value(t, root, project)

	root = find_root(file, base, {"nothing"}, context.temp_allocator)
	testing.expect_value(t, root, base)

	// Outside the workspace: the file's own folder
	elsewhere := fmt.tprintf("%s%selsewhere", src, sep)
	root = find_root(file, elsewhere, {"Cargo.toml"}, context.temp_allocator)
	testing.expect_value(t, root, src)
}


// --- Protocol ----------------------------------------------------------------------

@(test)
test_capabilities :: proc(t: ^testing.T) {
	v := parse_json(
		`{"textDocumentSync": {"openClose": true, "change": 2, "save": {"includeText": true}},` +
		`"hoverProvider": {}, "definitionProvider": false, "renameProvider": ` +
		`{"prepareProvider": true}, "completionProvider": {"triggerCharacters": [".", ":"]}}`,
	)
	caps := parse_capabilities(v)
	defer capabilities_destroy(&caps)

	testing.expect_value(t, caps.sync, Sync_Kind.Incremental)
	testing.expect(t, caps.open_close)
	testing.expect(t, caps.save_text)
	testing.expect(t, caps.hover)
	testing.expect(t, !caps.definition)
	testing.expect(t, caps.rename && caps.prepare_rename)
	testing.expect(t, caps.completion)
	testing.expect_value(t, len(caps.completion_triggers), 2)

	// A bare sync kind
	full := parse_capabilities(parse_json(`{"textDocumentSync": 1}`))
	defer capabilities_destroy(&full)
	testing.expect_value(t, full.sync, Sync_Kind.Full)
	testing.expect(t, full.open_close)
}


// Hover contents in each shape servers send
@(test)
test_hover_markdown :: proc(t: ^testing.T) {
	markup := parse_json(`{"contents": {"kind": "markdown", "value": "**x**"}}`)
	testing.expect_value(t, hover_markdown(markup), "**x**")

	plain := parse_json(`{"contents": "just text"}`)
	testing.expect_value(t, hover_markdown(plain), "just text")

	code := parse_json(`{"contents": {"language": "odin", "value": "x :: 1"}}`)
	testing.expect_value(t, hover_markdown(code), "```odin\nx :: 1\n```")

	list := parse_json(`{"contents": [{"language": "c", "value": "int x"}, "doc"], ` +
		`"range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 3}}}`)
	testing.expect_value(t, hover_markdown(list), "```c\nint x\n```\n\ndoc")
	r, has_range := hover_range(list)
	testing.expect(t, has_range)
	testing.expect_value(t, r, Range{{1, 2}, {1, 3}})

	testing.expect_value(t, hover_markdown(nil), "")
}


// Definition results: one location, a list, or links (their selection range)
@(test)
test_locations :: proc(t: ^testing.T) {
	RANGE :: `{"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 9}}`

	one := parse_locations(parse_json(`{"uri": "file:///a", "range": ` + RANGE + `}`))
	testing.expect_value(t, len(one), 1)
	if len(one) == 1 {
		testing.expect_value(t, one[0].uri, "file:///a")
		testing.expect_value(t, one[0].range.start, Position{3, 4})
	}

	many := parse_locations(parse_json(`[{"uri": "file:///a", "range": ` + RANGE + `}, ` +
		`{"uri": "file:///b", "range": ` + RANGE + `}]`))
	testing.expect_value(t, len(many), 2)

	links := parse_locations(parse_json(`[{"targetUri": "file:///c", "targetRange": ` + RANGE +
		`, "targetSelectionRange": {"start": {"line": 3, "character": 6}, ` +
		`"end": {"line": 3, "character": 7}}}]`))
	testing.expect_value(t, len(links), 1)
	if len(links) == 1 {
		testing.expect_value(t, links[0].uri, "file:///c")
		testing.expect_value(t, links[0].range.start, Position{3, 6})
	}

	testing.expect_value(t, len(parse_locations(nil)), 0)
}


// Symbol results: a tree of DocumentSymbols (flattened, parents first) or a
// list of SymbolInformation
@(test)
test_symbols :: proc(t: ^testing.T) {
	RANGE :: `{"start": {"line": 1, "character": 0}, "end": {"line": 9, "character": 1}}`
	NAME :: `{"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 7}}`

	tree := parse_symbols(parse_json(`[{"name": "Foo", "detail": "struct", "kind": 23, ` +
		`"range": ` + RANGE + `, "selectionRange": ` + NAME + `, "children": [` +
		`{"name": "bar", "kind": 8, "range": ` + RANGE + `, "selectionRange": ` + NAME +
		`}]}, {"name": "baz", "kind": 12, "range": ` + RANGE + `, "selectionRange": ` + NAME +
		`}]`), "file:///a")
	testing.expect_value(t, len(tree), 3)
	if len(tree) == 3 {
		testing.expect_value(t, tree[0].name, "Foo")
		testing.expect_value(t, tree[0].detail, "struct")
		testing.expect_value(t, tree[0].start, Position{1, 4})
		testing.expect_value(t, tree[0].uri, "file:///a")
		testing.expect_value(t, tree[1].name, "bar")
		testing.expect_value(t, tree[1].depth, 1)
		testing.expect_value(t, tree[1].container, "Foo")
		testing.expect_value(t, tree[2].depth, 0)
	}

	flat := parse_symbols(parse_json(`[{"name": "qux", "kind": 12, "containerName": "M", ` +
		`"location": {"uri": "file:///b", "range": ` + NAME + `}}, ` +
		`{"name": "noRange", "kind": 13, "location": {"uri": "file:///c"}}]`))
	testing.expect_value(t, len(flat), 2)
	if len(flat) == 2 {
		testing.expect_value(t, flat[0].uri, "file:///b")
		testing.expect_value(t, flat[0].container, "M")
		testing.expect_value(t, flat[0].start, Position{1, 4})
		testing.expect_value(t, flat[1].start, Position{0, 0})
	}

	testing.expect_value(t, len(parse_symbols(nil)), 0)
}


// Snippets become plain text, selecting the first tabstop's placeholder
@(test)
test_snippets :: proc(t: ^testing.T) {
	Case :: struct {
		snippet, text: string,
		sel:           [2]int,
	}
	cases := []Case {
		{"call(${1:arg}, $2)$0", "call(arg, )", {5, 8}},
		{"for ${2:i} in ${1:list} {\n\t$0\n}", "for i in list {\n\t\n}", {9, 13}},
		{"x$0y", "xy", {1, 1}},
		{"plain", "plain", {5, 5}},
		{"${1|one,two|} \\$5 ${TM_FILENAME:file} $NAME", "one $5 file ", {0, 3}},
		{"${1:outer ${2:inner}}", "outer inner", {0, 11}},
	}
	for c in cases {
		text, sel := snippet_text(c.snippet)
		testing.expectf(t, text == c.text, "%q: got %q", c.snippet, text)
		testing.expectf(t, sel == c.sel, "%q: got %v", c.snippet, sel)
	}
}


// Completion results: a list or a CompletionList (with item defaults); edits
// of both shapes
@(test)
test_completions :: proc(t: ^testing.T) {
	RANGE :: `{"start": {"line": 2, "character": 1}, "end": {"line": 2, "character": 4}}`
	OTHER :: `{"start": {"line": 2, "character": 1}, "end": {"line": 2, "character": 9}}`

	items, incomplete := parse_completions(parse_json(`[` +
		`{"label": "a", "kind": 3, "detail": "fn()", "documentation": {"kind": "markdown", ` +
		`"value": "**a**"}, "textEdit": {"range": ` + RANGE + `, "newText": "aaa"}}, ` +
		`{"label": "b", "insertText": "b($1)", "insertTextFormat": 2, ` +
		`"labelDetails": {"detail": "(x)", "description": "mod"}, ` +
		`"textEdit": {"newText": "b", "insert": ` + RANGE + `, "replace": ` + OTHER + `}}, ` +
		`{"label": "c", "additionalTextEdits": [{"range": ` + RANGE + `, "newText": "i"}]}]`))
	testing.expect(t, !incomplete)
	testing.expect_value(t, len(items), 3)
	if len(items) == 3 {
		testing.expect_value(t, items[0].text, "aaa")
		testing.expect_value(t, items[0].range.?, Range{{2, 1}, {2, 4}})
		testing.expect_value(t, items[0].detail, "fn()")
		testing.expect_value(t, items[0].documentation, "**a**")
		testing.expect_value(t, items[1].signature, "(x)")
		testing.expect_value(t, items[1].detail, "mod")
		testing.expect_value(t, items[1].range.?, Range{{2, 1}, {2, 4}}) // the insert range
		testing.expect_value(t, items[2].text, "c")
		testing.expect(t, items[2].range == nil)
		testing.expect_value(t, len(items[2].more), 1)
	}

	// A list with defaults
	items, incomplete = parse_completions(parse_json(`{"isIncomplete": true, ` +
		`"itemDefaults": {"editRange": ` + RANGE + `, "insertTextFormat": 2}, ` +
		`"items": [{"label": "d", "textEditText": "d($0)"}]}`))
	testing.expect(t, incomplete)
	testing.expect_value(t, len(items), 1)
	if len(items) == 1 {
		testing.expect_value(t, items[0].text, "d($0)")
		testing.expect(t, items[0].snippet)
		testing.expect_value(t, items[0].range.?, Range{{2, 1}, {2, 4}})
	}
}


// The active signature and parameter, given as text or as columns
@(test)
test_signature_help :: proc(t: ^testing.T) {
	help := parse_signature_help(parse_json(`{"activeSignature": 1, "activeParameter": 1, ` +
		`"signatures": [{"label": "f()"}, {"label": "f(a, b)", "documentation": "F.", ` +
		`"parameters": [{"label": "a"}, {"label": [5, 6], "documentation": "B."}]}]}`))
	testing.expect_value(t, help.label, "f(a, b)")
	testing.expect_value(t, help.index, 1)
	testing.expect_value(t, help.count, 2)
	testing.expect_value(t, help.param.?, [2]int{5, 6})
	testing.expect_value(t, help.documentation, "B.\n\nF.")

	testing.expect_value(t, parse_signature_help(nil).count, 0)
}


@(test)
test_rename_results :: proc(t: ^testing.T) {
	RANGE :: `{"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}}`

	// prepareRename: a range, a range and a name, the default, or nothing
	prep, ok := parse_prepare_rename(parse_json(RANGE))
	testing.expect(t, ok)
	testing.expect_value(t, prep.range.?, Range{{0, 1}, {0, 3}})
	prep, ok = parse_prepare_rename(parse_json(`{"range": ` + RANGE + `, "placeholder": "ab"}`))
	testing.expect(t, ok)
	testing.expect_value(t, prep.placeholder, "ab")
	prep, ok = parse_prepare_rename(parse_json(`{"defaultBehavior": true}`))
	testing.expect(t, ok)
	testing.expect(t, prep.range == nil)
	_, ok = parse_prepare_rename(nil)
	testing.expect(t, !ok)

	// A WorkspaceEdit's documentChanges, with versions
	docs: []Document_Edit_Info
	docs, ok = parse_workspace_edit(parse_json(`{"documentChanges": [` +
		`{"textDocument": {"uri": "file:///a", "version": 4}, ` +
		`"edits": [{"range": ` + RANGE + `, "newText": "y"}]}, ` +
		`{"textDocument": {"uri": "file:///b", "version": null}, "edits": []}]}`))
	testing.expect(t, ok)
	testing.expect_value(t, len(docs), 2)
	if len(docs) == 2 {
		testing.expect_value(t, docs[0].version.?, 4)
		testing.expect_value(t, docs[0].edits[0].text, "y")
		testing.expect(t, docs[1].version == nil)
	}

	// Or its changes by URI; file operations aren't taken
	docs, ok = parse_workspace_edit(parse_json(`{"changes": {"file:///c": ` +
		`[{"range": ` + RANGE + `, "newText": "z"}]}}`))
	testing.expect(t, ok)
	testing.expect_value(t, len(docs), 1)
	_, ok = parse_workspace_edit(parse_json(`{"documentChanges": [` +
		`{"kind": "create", "uri": "file:///d"}]}`))
	testing.expect(t, !ok)
}


@(test)
test_diagnostics :: proc(t: ^testing.T) {
	params := parse_json(`{"uri": "file:///a", "diagnostics": [` +
		`{"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 2}}, ` +
		`"severity": 2, "message": "careful", "source": "lint"}, ` +
		`{"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}, ` +
		`"message": "no severity"}]}`)
	diags := parse_diagnostics(params)

	testing.expect_value(t, len(diags), 2)
	if len(diags) == 2 {
		testing.expect_value(t, diags[0].severity, 2)
		testing.expect_value(t, diags[0].message, "careful")
		testing.expect_value(t, diags[0].source, "lint")
		testing.expect_value(t, diags[1].severity, 1) // an error when unsaid
	}
}


@(test)
test_json_params :: proc(t: ^testing.T) {
	change := Did_Change_Params {
		document = {"file:///a", 3},
		changes  = {{range = Range{{0, 1}, {0, 2}}, text = "x"}, {text = "all"}},
	}
	testing.expect_value(
		t,
		to_json(change),
		`{"textDocument":{"uri":"file:///a","version":3},"contentChanges":[` +
		`{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},` +
		`"text":"x"},{"text":"all"}]}`,
	)
}


// --- A client and the fake server --------------------------------------------------

@(private = "file")
FAKE_SERVER :: "build/fake_lsp.exe" when ODIN_OS == .Windows else "build/fake_lsp"


@(private = "file")
no_wake :: proc "contextless" (userdata: rawptr) {}


// Polls until `done` or a few seconds pass; the events are collected in `got`
// (freed by free_events)
@(private = "file")
poll_until :: proc(
	c: ^Client,
	got: ^[dynamic]Event,
	done: proc(c: ^Client, got: []Event) -> bool,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		client_poll(c, got)
		if done(c, got[:]) do return true
		time.sleep(2 * time.Millisecond)
	}
	return false
}


@(private = "file")
free_events :: proc(got: ^[dynamic]Event) {
	for &ev in got do event_destroy(&ev)
	delete(got^)
}


@(private = "file")
start_fake :: proc(t: ^testing.T, c: ^Client, args: ..string) -> bool {
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	return start_fake_in(t, c, cwd, ..args)
}


// Starts the fake server with `root` as the project's folder
@(private = "file")
start_fake_in :: proc(t: ^testing.T, c: ^Client, root: string, args: ..string) -> bool {
	if !os.exists(FAKE_SERVER) {
		testing.fail_now(t, "build/fake_lsp missing; build.py --test builds it")
	}

	command := make([dynamic]string, context.temp_allocator)
	append(&command, FAKE_SERVER)
	append(&command, ..args)
	config := Client_Config{name = "fake", root = root, command = command[:]}
	client_start(c, config, no_wake, nil)

	got: [dynamic]Event
	defer free_events(&got)
	return poll_until(c, &got, proc(c: ^Client, _: []Event) -> bool {
		return c.state != .Starting
	})
}


// The first event of type T in `got`
@(private = "file")
find_event :: proc(got: []Event, $T: typeid) -> (T, bool) {
	for ev in got {
		x, is_t := ev.(T)
		if is_t do return x, true
	}
	return {}, false
}


@(private = "file")
has_response :: proc(c: ^Client, got: []Event) -> bool {
	_, found := find_event(got, Response)
	return found
}


@(private = "file")
has_diagnostics :: proc(c: ^Client, got: []Event) -> bool {
	_, found := find_event(got, Diagnostics)
	return found
}


@(private = "file")
open_text :: proc(c: ^Client, uri, text: string) {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(text))
	defer buffer.buffer_destroy(&b)

	b.version = 1
	client_open(c, uri, "plaintext", buffer.snapshot(&b))
}


// Edits given as byte offsets reach the server as the same text, in both
// encodings (the client converts each against the text before it)
@(test)
test_client_sync :: proc(t: ^testing.T) {
	for args in ([][]string{{}, {"--utf16"}}) {
		c: Client
		defer client_destroy(&c)
		if !start_fake(t, &c, ..args) {
			testing.fail_now(t, "the server never initialized")
		}
		testing.expect_value(t, c.state, State.Running)
		testing.expect_value(t, c.encoding, len(args) == 0 ? Encoding.UTF8 : Encoding.UTF16)

		// Open, then edit around wide characters
		uri := "file:///doc.txt"
		text := "héllo 😀 world\nsecond"
		open_text(&c, uri, text)

		emoji := strings.index(text, "😀")
		after_emoji := len(text) - len("😀") + len("X")
		edits := []Edit {
			{emoji, len("😀"), "X"},
			{after_emoji - 3, 3, "ond\nthird"}, // the end, as the first edit left it
		}
		client_change(&c, uri, 2, edits)
		testing.expect_value(t, server_text(t, &c, uri), "héllo X world\nsecond\nthird")

		// All of it, then more
		edits = []Edit{{0, -1, "whole"}, {5, 0, "ü😀"}, {1, 1, ""}}
		client_change(&c, uri, 3, edits)
		testing.expect_value(t, server_text(t, &c, uri), "woleü😀")
	}
}


// The server's copy of a document (fake/text), from the temp allocator
@(private = "file")
server_text :: proc(t: ^testing.T, c: ^Client, uri: string) -> string {
	params := fmt.tprintf(`{{"uri":%s}}`, to_json(uri))
	id := request_json(c, "fake/text", params)
	got: [dynamic]Event
	defer free_events(&got)
	if !poll_until(c, &got, has_response) {
		testing.fail_now(t, "no answer to fake/text")
	}

	r, _ := find_event(got[:], Response)
	testing.expect_value(t, r.id, id)
	raw, _ := r.result.(Raw_Result)
	text, _ := parse_json(string(raw)).(json.String)
	return text
}


// Problems arrive as byte ranges in the document, whatever the server counts
@(test)
test_client_diagnostics :: proc(t: ^testing.T) {
	for args in ([][]string{{}, {"--utf16"}}) {
		c: Client
		defer client_destroy(&c)
		if !start_fake(t, &c, ..args) do testing.fail_now(t, "the server never initialized")

		text := "é😀 FIXME b"
		open_text(&c, "file:///d.txt", text)
		got: [dynamic]Event
		defer free_events(&got)
		testing.expect(t, poll_until(&c, &got, has_diagnostics))

		d, _ := find_event(got[:], Diagnostics)
		testing.expect_value(t, d.uri, "file:///d.txt")
		testing.expect_value(t, len(d.problems), 1)
		if len(d.problems) == 1 {
			lo := strings.index(text, "FIXME")
			p := d.problems[0]
			testing.expect_value(t, [2]int{p.lo, p.hi}, [2]int{lo, lo + 5})
			testing.expect_value(t, p.severity, 2)
		}
	}
}


// Hover and definition answers come decoded, with offsets in the document
@(test)
test_client_requests :: proc(t: ^testing.T) {
	c: Client
	defer client_destroy(&c)
	if !start_fake(t, &c, "--utf16") do testing.fail_now(t, "the server never initialized")

	uri := "file:///r.txt"
	text := "😀 name = 1\nuse name"
	open_text(&c, uri, text)

	// Hover on the second "name"
	second := strings.last_index(text, "name")
	hover_id := request(&c, "textDocument/hover", uri, second + 1)
	got: [dynamic]Event
	defer free_events(&got)
	testing.expect(t, poll_until(&c, &got, has_response))

	r, _ := find_event(got[:], Response)
	testing.expect_value(t, r.id, hover_id)
	testing.expect_value(t, r.version, 1)
	hover, _ := r.result.(Hover)
	testing.expect_value(t, hover.markdown, "**name**")

	// Its definition: the first "name", as an offset in the open document
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request(&c, "textDocument/definition", uri, second + 1)
	testing.expect(t, poll_until(&c, &got, has_response))

	r, _ = find_event(got[:], Response)
	places, _ := r.result.([]Place)
	testing.expect_value(t, len(places), 1)
	if len(places) == 1 {
		testing.expect_value(t, places[0].offset, strings.index(text, "name"))
		testing.expect_value(t, places[0].position, Position{0, 3})
	}
}


// A document's symbols and the workspace's come decoded, with offsets in the
// open document; references come with their lines
@(test)
test_client_symbols_and_references :: proc(t: ^testing.T) {
	c: Client
	defer client_destroy(&c)
	if !start_fake(t, &c, "--utf16") do testing.fail_now(t, "the server never initialized")

	uri := "file:///s.txt"
	text := "😀 :: 1\nouter :: proc\n\tinner := outer\nother :: outer"
	open_text(&c, uri, text)
	got: [dynamic]Event
	defer free_events(&got)

	// The outline: two functions, one variable inside the first
	request(&c, "textDocument/documentSymbol", uri, 0)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ := find_event(got[:], Response)
	symbols, _ := r.result.([]Symbol)
	testing.expect_value(t, len(symbols), 4)
	if len(symbols) == 4 {
		testing.expect_value(t, symbols[1].name, "outer")
		testing.expect_value(t, symbols[1].detail, "proc")
		testing.expect_value(t, symbols[1].place.offset, strings.index(text, "outer"))
		testing.expect_value(t, symbols[2].name, "inner")
		testing.expect_value(t, symbols[2].depth, 1)
		testing.expect_value(t, symbols[2].detail, "outer") // what it is in
	}

	// The workspace's, by a query
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request_symbols(&c, "OTH")
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	symbols, _ = r.result.([]Symbol)
	testing.expect_value(t, len(symbols), 1)
	if len(symbols) == 1 {
		testing.expect_value(t, symbols[0].name, "other")
		testing.expect_value(t, symbols[0].place.offset, strings.index(text, "other"))
	}

	// References to "outer": its three places, each with its line
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request(&c, "textDocument/references", uri, strings.index(text, "outer") + 1)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	places, _ := r.result.([]Place)
	testing.expect_value(t, len(places), 3)
	if len(places) == 3 {
		testing.expect_value(t, places[1].preview, "inner := outer")
		testing.expect_value(t, places[1].offset, strings.index(text, "= outer") + 2)
		testing.expect_value(t, places[2].preview, "other :: outer")
	}
}


// Completions come with what they replace as offsets, a snippet as plain text
// and an import edit; resolving adds documentation; signature help has its
// active parameter as bytes of the label
@(test)
test_client_completion :: proc(t: ^testing.T) {
	c: Client
	defer client_destroy(&c)
	if !start_fake(t, &c, "--utf16") do testing.fail_now(t, "the server never initialized")

	uri := "file:///c.txt"
	text := "😀 alpha beta\nal"
	open_text(&c, uri, text)
	got: [dynamic]Event
	defer free_events(&got)

	// At the end: the word "al" is what items replace
	request_completion(&c, uri, len(text), .Invoked)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ := find_event(got[:], Response)
	list, _ := r.result.(Completions)
	alpha, snippet, import_item: Completion
	for item in list.items {
		switch item.label {
		case "alpha":        alpha = item
		case "fake_snippet": snippet = item
		case "fake_import":  import_item = item
		}
	}
	testing.expect_value(t, alpha.text, "alpha")
	testing.expect_value(t, alpha.lo, len(text) - 2)
	testing.expect_value(t, alpha.hi, len(text))
	testing.expect_value(t, snippet.text, "call(arg, )")
	testing.expect_value(t, snippet.select, [2]int{5, 8})
	testing.expect_value(t, snippet.lo, len(text) - 2) // the word before the caret
	testing.expect_value(t, len(import_item.more), 1)
	testing.expect(t, alpha.resolve != "")

	// Resolving it
	resolve := strings.clone(alpha.resolve, context.temp_allocator)
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request_resolve(&c, uri, resolve)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	resolved, _ := r.result.(Completion)
	testing.expect_value(t, resolved.documentation, "**alpha**\n\ndocs for alpha")

	// Signature help in "beta(x, " on a new line
	for &ev in got do event_destroy(&ev)
	clear(&got)
	call := "\nbeta(x, "
	client_change(&c, uri, 2, {{len(text), 0, call}})
	request(&c, "textDocument/signatureHelp", uri, len(text) + len(call))
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	help, _ := r.result.(Signature_Help)
	testing.expect_value(t, help.label, "beta(a, b, c)")
	testing.expect_value(t, help.label[help.param_lo:help.param_hi], "b")
}


// A rename comes as byte ranges: of the open document at its version, and of a
// file that isn't open (read from disk; write_file_edit rewrites it unless it
// changed since). The server's workspace/applyEdit comes as an event, and the
// answer given with reply_apply_edit reaches it
@(test)
test_client_rename :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "typo-rename-*", context.temp_allocator)
	if dir_err != nil do testing.fail_now(t, "no temp folder")
	defer os.remove_all(dir)

	closed, _ := filepath.join({dir, "closed.fake"}, context.temp_allocator)
	closed_text := "x := old\nold()\n"
	_ = os.write_entire_file(closed, transmute([]u8)closed_text)

	c: Client
	defer client_destroy(&c)
	if !start_fake_in(t, &c, dir, "--utf16") {
		testing.fail_now(t, "the server never initialized")
	}

	open_path, _ := filepath.join({dir, "open.fake"}, context.temp_allocator)
	uri := uri_from_path(open_path, context.temp_allocator)
	text := "😀 old = 1\nuse old FIXME"
	open_text(&c, uri, text)
	got: [dynamic]Event
	defer free_events(&got)

	// What the second "old" allows
	second := strings.last_index(text, "old")
	request(&c, "textDocument/prepareRename", uri, second + 1)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ := find_event(got[:], Response)
	prep, _ := r.result.(Prepare_Rename)
	testing.expect(t, prep.renamable)
	testing.expect_value(t, [2]int{prep.lo, prep.hi}, [2]int{second, second + 3})
	testing.expect_value(t, prep.placeholder, "old")

	// The rename: both files, sorted by path
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request_rename(&c, uri, second + 1, "new_name")
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	testing.expect_value(t, r.error, "")
	edit, _ := r.result.(Workspace_Edit)
	testing.expect_value(t, len(edit.files), 2)
	if len(edit.files) != 2 do return

	on_disk, in_doc := edit.files[0], edit.files[1]
	testing.expect(t, !on_disk.open)
	testing.expect_value(t, on_disk.size, len(closed_text))
	testing.expect(t, in_doc.open && !in_doc.stale)
	testing.expect_value(t, in_doc.version, 1)
	testing.expect_value(t, len(in_doc.edits), 2)
	if len(in_doc.edits) == 2 {
		first := Edit{strings.index(text, "old"), 3, "new_name"}
		testing.expect_value(t, in_doc.edits[0], first)
		testing.expect_value(t, in_doc.edits[1], Edit{second, 3, "new_name"})
	}

	// The file on disk rewritten; not again, as it changed since
	testing.expect_value(t, write_file_edit(on_disk), "")
	data, _ := os.read_entire_file(closed, context.temp_allocator)
	testing.expect_value(t, string(data), "x := new_name\nnew_name()\n")
	testing.expect(t, write_file_edit(on_disk) != "")

	// The server asks for "FIXME" to become "FIXED"; its request gets the answer
	for &ev in got do event_destroy(&ev)
	clear(&got)
	request_json(&c, "fake/apply", fmt.tprintf(`{{"uri":%s}}`, to_json(uri)))
	testing.expect(t, poll_until(&c, &got, has_apply_edit))
	apply, _ := find_event(got[:], Apply_Edit)
	testing.expect_value(t, apply.label, "fake")
	testing.expect_value(t, len(apply.edit.files), 1)
	if len(apply.edit.files) == 1 {
		fe := apply.edit.files[0]
		testing.expect(t, fe.open)
		testing.expect_value(t, fe.edits[0], Edit{strings.index(text, "FIXME"), 5, "FIXED"})
	}

	reply_apply_edit(&c, apply.id, true)
	testing.expect(t, poll_until(&c, &got, has_response))
	r, _ = find_event(got[:], Response)
	raw, _ := r.result.(Raw_Result)
	testing.expect_value(t, string(raw), `{"applied":true}`)
}


@(private = "file")
has_apply_edit :: proc(c: ^Client, got: []Event) -> bool {
	_, found := find_event(got, Apply_Edit)
	return found
}


@(test)
test_client_crash_and_stop :: proc(t: ^testing.T) {
	// A crash leaves it Crashed, with a reason
	{
		c: Client
		defer client_destroy(&c)
		if !start_fake(t, &c) do testing.fail_now(t, "the server never initialized")

		request_json(&c, "fake/crash", "{}")
		got: [dynamic]Event
		defer free_events(&got)
		ended := poll_until(&c, &got, proc(c: ^Client, _: []Event) -> bool {
			return c.state == .Crashed
		})
		testing.expect(t, ended)
		testing.expect_value(t, c.reason, "exited with code 3: fake server started")
	}

	// A shutdown leaves it Stopped
	{
		c: Client
		defer client_destroy(&c)
		if !start_fake(t, &c) do testing.fail_now(t, "the server never initialized")

		client_stop(&c)
		got: [dynamic]Event
		defer free_events(&got)
		stopped := poll_until(&c, &got, proc(c: ^Client, _: []Event) -> bool {
			return c.state == .Stopped
		})
		testing.expect(t, stopped)
	}

	// A missing program fails to start
	{
		c: Client
		defer client_destroy(&c)
		config := Client_Config{name = "none", root = ".", command = {"no-such-server-xyz"}}
		client_start(&c, config, no_wake, nil)

		got: [dynamic]Event
		defer free_events(&got)
		failed := poll_until(&c, &got, proc(c: ^Client, _: []Event) -> bool {
			return c.state == .Crashed
		})
		testing.expect(t, failed)
		testing.expect(t, strings.contains(c.reason, "not found"))
	}

	// Freeing a running client ends it
	{
		c: Client
		if !start_fake(t, &c) do testing.fail_now(t, "the server never initialized")
		client_destroy(&c, wait_ms = 100)
	}
}


// --- Positions in a document -------------------------------------------------------

@(test)
test_document_positions :: proc(t: ^testing.T) {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone("first\r\naé😀b"))
	defer buffer.buffer_destroy(&b)

	at_b := buffer.length(&b) - 1
	testing.expect_value(t, position_at(&b, at_b, .UTF16), Position{1, 4})
	testing.expect_value(t, position_at(&b, at_b, .UTF8), Position{1, 7})
	testing.expect_value(t, offset_at(&b, {1, 4}, .UTF16), at_b)
	testing.expect_value(t, offset_at(&b, {1, 7}, .UTF8), at_b)

	// Clamped: past a line's end (before its "\r\n"), past the last line
	testing.expect_value(t, offset_at(&b, {0, 99}, .UTF8), 5)
	testing.expect_value(t, offset_at(&b, {0, 99}, .UTF16), 5)
	testing.expect_value(t, offset_at(&b, {9, 0}, .UTF8), buffer.length(&b))

	// Never inside a character: column 2 is inside "é"
	testing.expect_value(t, offset_at(&b, {1, 2}, .UTF8), 10)
}


// --- Lookups -----------------------------------------------------------------------

@(test)
test_lookups :: proc(t: ^testing.T) {
	l: Lookups
	lookups_init(&l, no_wake, nil)
	defer lookups_destroy(&l)

	lookup_program(&l, "fake", FAKE_SERVER)
	lookup_program(&l, "none", "no-such-server-xyz")
	cwd := os.get_working_directory(context.temp_allocator) or_else "."
	file, _ := filepath.join({cwd, "src", "lsp", "lsp.odin"}, context.temp_allocator)
	lookup_root(&l, "root", file, cwd, {"build.py"})

	// The answers, by key
	answers := make(map[string]string, context.temp_allocator)
	got: [dynamic]Lookup
	defer delete(got)
	start := time.tick_now()
	for len(answers) < 3 && time.tick_since(start) < 5 * time.Second {
		lookups_take(&l, &got)
		for &x in got {
			answers[strings.clone(x.key, context.temp_allocator)] = strings.clone(
				x.answer,
				context.temp_allocator,
			)
			lookup_destroy(&x)
		}
		clear(&got)
		time.sleep(2 * time.Millisecond)
	}

	program := filepath.base(FAKE_SERVER)
	testing.expect(t, strings.has_suffix(answers["fake"], program))
	testing.expect(t, filepath.is_abs(answers["fake"]))
	testing.expect_value(t, answers["none"], "")
	testing.expect_value(t, answers["root"], cwd)
}
