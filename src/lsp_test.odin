package editor

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "buffer"
import "langs"
import "lsp"
import "textedit"

// Language server tests with the fake server (src/lsp/fake_server, built by
// build.py --test): edits reach the server as the same text


@(private = "file")
FAKE_SERVER :: "build/fake_lsp.exe" when ODIN_OS == .Windows else "build/fake_lsp"


// Sets g.lsp up with the fake server for ".fake" files
@(private = "file")
use_fake_server :: proc(t: ^testing.T, utf16: bool) {
	if !os.exists(FAKE_SERVER) {
		testing.fail_now(t, "build/fake_lsp missing; build.py --test builds it")
	}

	// Its command names a program that isn't on PATH: `path` says where it is
	@(static) utf8_command := []string{"fake-lsp-not-on-path"}
	@(static) utf16_command := []string{"fake-lsp-not-on-path", "--utf16"}
	@(static) languages := []string{"fake"}
	@(static) extensions := []string{"fake"}

	server := langs.Server {
		spec = {
			name      = "fake",
			command   = utf16 ? utf16_command : utf8_command,
			languages = languages,
			enabled   = true,
		},
		path = FAKE_SERVER,
	}
	append(&langs.state.servers, server)
	append(&langs.state.languages, lsp.Language{id = "fake", extensions = extensions})
	langs.state.active = true
	g.settings.lsp_enabled = true
}


@(private = "file")
stop_fake_server :: proc() {
	lsp_destroy()
	g.settings.lsp_enabled = false
}


// Passes edits on as the app's editors do
@(private = "file")
test_on_edit :: proc(v: ^textedit.View, changes: []buffer.Change) {
	langs.doc_changed(&editor_of(v).lsp, changes)
}


// Runs frames until the editor's document is on a client (its program and root
// are looked up on another thread); false after a few seconds
@(private = "file")
attach_when_found :: proc(e: ^Editor) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		lsp_frame()
		lsp_doc_open(e)
		if len(e.lsp.clients) > 0 do return true
		time.sleep(2 * time.Millisecond)
	}
	return false
}


// Polls a client until `done`; the events are collected in `got`. False after a
// few seconds
@(private = "file")
poll_until :: proc(
	c: ^langs.Client,
	got: ^[dynamic]lsp.Event,
	done: proc(c: ^langs.Client, got: []lsp.Event) -> bool,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		lsp.client_poll(c.client, got)
		if done(c, got[:]) do return true
		time.sleep(2 * time.Millisecond)
	}
	return false
}


@(private = "file")
free_events :: proc(got: ^[dynamic]lsp.Event) {
	for &ev in got do lsp.event_destroy(&ev)
	delete(got^)
}


// A caret position not inside a character
@(private = "file")
random_offset :: proc(e: ^Editor) -> int {
	n := buffer.length(&e.buf)
	at := rand.int_max(n + 1)
	for at < n && buffer.byte_at(&e.buf, at) & 0xC0 == 0x80 {
		at += 1
	}
	return at
}


// The first offset from `at` that is between characters and not inside a line
// break "\r\n" (where a server can't be told about it)
@(private = "file")
char_boundary :: proc(e: ^Editor, at: int) -> int {
	at := at
	n := buffer.length(&e.buf)
	for at < n {
		inside_char := buffer.byte_at(&e.buf, at) & 0xC0 == 0x80
		inside_break := at > 0 && buffer.byte_at(&e.buf, at - 1) == '\r'
		if !inside_char && !inside_break {
			break
		}
		at += 1
	}
	return at
}


// Problems from a client (owned), sorted
@(private = "file")
make_problems :: proc(ranges: ..[2]int) -> []lsp.Problem {
	out := make([]lsp.Problem, len(ranges))
	for r, i in ranges {
		out[i] = {lo = r[0], hi = r[1], severity = 1, message = strings.clone("fix")}
	}
	return out
}


@(private = "file")
edit_at :: proc(e: ^Editor, at, remove: int, text: string) {
	textedit.set_single_selection(e, {at, at + remove, -1})
	textedit.insert(e, text, .Other)
	textedit.take_changes(e)
}


// A problem moves with edits before it and stretches over edits inside it;
// problems about older text are brought up to date with the edits since; two
// clients' problems are merged in order
@(test)
test_problems_follow_edits :: proc(t: ^testing.T) {
	e: Editor
	defer {
		langs.doc_close(&e.lsp)
		buffer.buffer_destroy(&e.buf)
		delete(e.sels)
	}
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone("abc FIXME def"))
	e.status = .Text
	e.kind = &TEXT_KIND
	e.on_edit = test_on_edit
	e.lsp.view = &e.tv
	append(&e.sels, Selection{0, 0, -1})

	// Two clients that never run (their documents aren't opened)
	a, b: langs.Client
	append(&e.lsp.clients, langs.Doc_Client{client = &a}, langs.Doc_Client{client = &b})
	langs.problems_set(&e.lsp, &a, make_problems({4, 9}), e.buf.version)

	edit_at(&e, 0, 0, "XX") // before it
	testing.expect_value(t, e.problems[0], textedit.Problem{6, 11, .Error})

	edit_at(&e, 8, 0, "Q") // inside it
	testing.expect_value(t, e.problems[0], textedit.Problem{6, 12, .Error})

	edit_at(&e, 0, 2, "") // removing text before it
	testing.expect_value(t, e.problems[0], textedit.Problem{4, 10, .Error})

	edit_at(&e, 10, 0, "!") // right after it: it doesn't grow
	testing.expect_value(t, e.problems[0], textedit.Problem{4, 10, .Error})

	problems := langs.problems_at(&e.lsp, 5)
	testing.expect_value(t, len(problems), 1)
	testing.expect_value(t, len(langs.problems_at(&e.lsp, 2)), 0)

	// About the text before "YYY" was typed at the start
	before := e.buf.version
	edit_at(&e, 0, 0, "YYY")
	langs.problems_set(&e.lsp, &b, make_problems({0, 1}, {11, 12}), before)
	testing.expect_value(t, len(e.problems), 3)
	if len(e.problems) == 3 {
		testing.expect_value(t, e.problems[0], textedit.Problem{3, 4, .Error})
		testing.expect_value(t, e.problems[1], textedit.Problem{7, 13, .Error})
		testing.expect_value(t, e.problems[2], textedit.Problem{14, 15, .Error})
	}

	// One client goes away
	langs.problems_clear(&e.lsp, only = &a)
	testing.expect_value(t, len(e.problems), 2)
}


// [lsp.<name>] tables load, change the server list, and survive a save
@(test)
test_lsp_settings_round_trip :: proc(t: ^testing.T) {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.tprintf("%s/typo-lsp-settings-%d.toml", dir, os.get_pid())
	defer os.remove(path)

	_ = os.write_entire_file(path, `
[lsp]
enabled = true

[lsp.pyright]
enabled = false
settings = { python = { analysis = { typeCheckingMode = "strict", extraPaths = ["a", "b"] } } }

[lsp.ty]
enabled = true
path = "C:/tools/ty.exe"

[lsp.mine]
path = "C:/tools/my-ls.exe"
languages = ["python"]

[lsp.zig-custom]
command = ["my-zls", "--stdio"]
languages = "zigx"
extensions = ["zigx"]
root_markers = ["build.zig"]

[lsp.ols]
colour = "red"
`)

	// Load
	s: Settings
	settings_reset_all(&s)
	s.path = strings.clone(path)
	defer settings_destroy(&s)
	settings_load(&s)

	testing.expect(t, s.lsp_enabled)
	testing.expect_value(t, len(s.servers), 5)
	testing.expect(t, strings.contains(s.error, "lsp.ols.colour"))

	// The server list
	servers: [dynamic]langs.Server
	languages: [dynamic]lsp.Language
	defer {
		delete(servers)
		delete(languages)
	}
	langs.build_server_list(s.servers[:], &servers, &languages)

	pyright, ty, custom, mine: ^langs.Server
	for &server in servers {
		switch server.name {
		case "pyright":    pyright = &server
		case "ty":         ty = &server
		case "zig-custom": custom = &server
		case "mine":       mine = &server
		}
	}
	testing.expect(t, pyright != nil && !pyright.enabled)
	testing.expect(t, custom != nil && !custom.builtin && custom.enabled)

	// A path keeps the built-in arguments; a path alone adds a server
	testing.expect(t, ty != nil && ty.enabled && ty.path == "C:/tools/ty.exe")
	if ty != nil do testing.expect_value(t, ty.command[1], "server")
	testing.expect(t, mine != nil && mine.path == "C:/tools/my-ls.exe" && len(mine.command) == 0)
	if pyright != nil {
		strict := lsp.get_string(
			lsp.parse_json(pyright.settings),
			"python",
			"analysis",
			"typeCheckingMode",
		)
		testing.expect_value(t, strict, "strict")
	}
	testing.expect_value(t, lsp.language_for_path("x.zigx", languages[:]), "zigx")

	// Save, and load again
	settings_save(&s)
	again: Settings
	settings_reset_all(&again)
	again.path = strings.clone(path)
	defer settings_destroy(&again)
	settings_load(&again)

	testing.expect_value(t, again.error, "")
	saved := langs.servers_fingerprint(s.lsp_enabled, s.servers[:])
	loaded := langs.servers_fingerprint(again.lsp_enabled, again.servers[:])
	testing.expect_value(t, loaded, saved)
}


// Install runs its command in the shell, which stays open after it
@(test)
test_shell_running :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		testing.expect_value(
			t,
			shell_running("pwsh -NoLogo", "npm install -g x"),
			"pwsh -NoLogo -NoExit -Command npm install -g x",
		)
		cmd := shell_running(`C:\Windows\cmd.exe`, "a b")
		testing.expect_value(t, cmd, `C:\Windows\cmd.exe /K a b`)
		cmd = shell_running("cmd /q /K prompt $G", "a b")
		testing.expect_value(t, cmd, "cmd /q /K prompt $G & a b")

		// A shell it can't hand a command to: the default shell runs it
		line := shell_running("nu", "a b")
		handed := strings.has_suffix(line, "-Command a b") || strings.has_suffix(line, "/K a b")
		testing.expect(t, handed)
	} else {
		testing.expect_value(t, shell_running("zsh -l", "a b"), "a b; exec zsh -l")
	}
}


// A path shown in a server's row keeps its start and file name, and is cut at
// the end when the name alone is too long
@(test)
test_short_path :: proc(t: ^testing.T) {
	testing.expect_value(t, short_path(`C:\bin\ols.exe`), `C:\bin\ols.exe`)

	long := `C:\Users\someone\AppData\Local\Zed\extensions\work\odin\ols-dev\ols-x86_64.exe`
	testing.expect_value(t, short_path(long), `C:\Users\someone\AppData\Local\Ze…\ols-x86_64.exe`)

	name := strings.repeat("x", 80, context.temp_allocator)
	shown := short_path(name)
	testing.expect(t, strings.has_suffix(shown, "…") && len(shown) < 60)

	under_slash := strings.concatenate({`C:\`, name}, context.temp_allocator)
	testing.expect(t, strings.has_prefix(short_path(under_slash), `C:\xxx`))

	free_all(context.temp_allocator)
}


// A save handed to the saver thread is written by the time the settings are
// destroyed
@(test)
test_settings_saved_later :: proc(t: ^testing.T) {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.tprintf("%s/typo-save-later-%d.toml", dir, os.get_pid())
	defer os.remove(path)

	s: Settings
	settings_reset_all(&s)
	s.path = strings.clone(path)
	set_string(&s.theme, "one-light")
	settings_save_later(&s)
	set_string(&s.theme, "one-dark")
	settings_save_later(&s)
	settings_destroy(&s)

	again: Settings
	settings_reset_all(&again)
	again.path = strings.clone(path)
	defer settings_destroy(&again)
	settings_load(&again)

	testing.expect_value(t, again.error, "")
	testing.expect_value(t, again.theme, "one-dark")
}


// Random multi-cursor edits, undo and redo, several per frame; after them the
// server's copy of the document is the buffer's text, in both encodings
@(test)
test_lsp_sync_edits :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	for utf16 in ([]bool{false, true}) {
		use_fake_server(t, utf16)
		defer stop_fake_server()

		// The editor, attached to the server
		e: Editor
		defer {
			langs.doc_close(&e.lsp)
			buffer.buffer_destroy(&e.buf)
			delete(e.sels)
			delete(e.path)
		}
		buffer.buffer_init(&e.buf, transmute([]u8)strings.clone("héllo 😀\r\nwörld\n"))
		e.status = .Text
		e.kind = &TEXT_KIND
		e.on_edit = test_on_edit
		e.path = strings.clone("doc.fake")
		append(&e.sels, Selection{0, 0, -1})
		testing.expect(t, attach_when_found(&e))
		testing.expect_value(t, len(e.lsp.clients), 1)
		if len(e.lsp.clients) != 1 do return
		c := e.lsp.clients[0].client
		testing.expect(t, e.lsp.clients[0].opened)

		// Frames of edits, from before the server is running (they wait for it)
		rand.reset(42)
		inserts := []string{"a", "é", "😀", "\n", "\r\n", "xyz", "ü😀ß", ""}
		for _ in 0 ..< 200 {
			for _ in 0 ..< 1 + rand.int_max(4) {
				switch rand.int_max(6) {
				case 0, 1, 2:
					// Typing at one to three carets
					clear(&e.sels)
					for _ in 0 ..< 1 + rand.int_max(3) {
						at := random_offset(&e)
						append(&e.sels, Selection{at, at, -1})
					}
					e.primary = 0
					textedit.normalize(&e)
					textedit.insert(&e, rand.choice(inserts), .Other)
				case 3:
					// Deleting a selection
					lo := random_offset(&e)
					hi := random_offset(&e)
					clear(&e.sels)
					append(&e.sels, Selection{min(lo, hi), max(lo, hi), -1})
					e.primary = 0
					textedit.normalize(&e)
					textedit.delete_text(&e, -1, word = false)
				case 4:
					textedit.undo(&e)
				case 5:
					textedit.redo(&e)
				}
			}
			textedit.take_changes(&e)
		}

		// Frames of many edits in text order (like a rename), then their undo
		for n in ([]int{100, 300}) {
			length := buffer.length(&e.buf)
			many := make([]textedit.Text_Edit, n, context.temp_allocator)
			for i in 0 ..< n {
				at := char_boundary(&e, i * length / n)
				many[i] = {lo = at, hi = at, text = "ü"}
			}
			textedit.apply_edits(&e, .Other, many)
			textedit.take_changes(&e)
			textedit.undo(&e)
			textedit.take_changes(&e)
			textedit.redo(&e)
			textedit.take_changes(&e)
		}

		// The server's copy
		params := fmt.tprintf(`{{"uri":%s}}`, lsp.to_json(e.lsp.uri))
		lsp.request_json(c.client, "fake/text", params)
		got: [dynamic]lsp.Event
		defer free_events(&got)
		answered := poll_until(c, &got, proc(c: ^langs.Client, got: []lsp.Event) -> bool {
			for ev in got {
				_, is_response := ev.(lsp.Response)
				if is_response do return true
			}
			return false
		})
		testing.expect(t, answered)
		testing.expect_value(t, c.encoding, utf16 ? lsp.Encoding.UTF16 : lsp.Encoding.UTF8)

		for ev in got {
			r, is_response := ev.(lsp.Response)
			if !is_response do continue

			raw, _ := r.result.(lsp.Raw_Result)
			server_text, _ := lsp.parse_json(string(raw)).(json.String)
			buffer_text := string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf)))
			testing.expect_value(t, server_text, buffer_text)
		}
	}
}
