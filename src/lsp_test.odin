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
import "fuzzy"
import "langs"
import "lsp"
import "markdown"
import "textedit"
import sdl "../vendor/sdl3"

// Language server tests with the fake server (src/lsp/fake_server, built by
// build.py --test): edits reach the server as the same text


@(private = "file")
FAKE_SERVER :: "build/fake_lsp.exe" when ODIN_OS == .Windows else "build/fake_lsp"


// How the fake server answers completion requests
@(private = "file")
Fake_Completion :: enum {
	Words,
	Incomplete, // short, incomplete lists
	Empty,
	Error,
	Late,       // after FAKE_DELAY
}

@(private = "file")
FAKE_DELAY :: "1500" // ms


// Sets g.lsp up with the fake server for ".fake" files, answering completion
// requests as `completion` says
@(private = "file")
use_fake_server :: proc(t: ^testing.T, utf16: bool, completion := Fake_Completion.Words) {
	if !os.exists(FAKE_SERVER) {
		testing.fail_now(t, "build/fake_lsp missing; build.py --test builds it")
	}

	// Its command names a program that isn't on PATH: `path` says where it is
	@(static) utf8_command := []string{"fake-lsp-not-on-path"}
	@(static) utf16_command := []string{"fake-lsp-not-on-path", "--utf16"}
	@(static) completion_commands := [Fake_Completion][]string {
		.Words      = {"fake-lsp-not-on-path"},
		.Incomplete = {"fake-lsp-not-on-path", "--incomplete"},
		.Empty      = {"fake-lsp-not-on-path", "--complete-empty"},
		.Error      = {"fake-lsp-not-on-path", "--complete-error"},
		.Late       = {"fake-lsp-not-on-path", "--complete-delay", FAKE_DELAY},
	}
	@(static) languages := []string{"fake"}
	@(static) extensions := []string{"fake"}

	command := utf16 ? utf16_command : utf8_command
	if completion != .Words do command = completion_commands[completion]

	server := langs.Server {
		spec = {
			name      = "fake",
			command   = command,
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


// Typing the start of a function defined above the caret offers it, and Enter
// inserts it. The server's lists are short and incomplete: the letters typed
// while an answer is on its way are asked about once it comes
@(test)
test_lsp_completion_while_typing :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_fake_server(t, false, .Incomplete)
	defer stop_fake_server()

	// A function and other words starting with "ta", then an empty line
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.tprintf("%s/typo-completion-%d.fake", dir, os.get_pid())
	text := "target_func :: proc() {}\ntab_1 tab_2 tab_3 tab_4 tab_5 tab_6\n\n"
	_ = os.write_entire_file(path, text)
	defer os.remove(path)

	// Opened in the focused pane
	words_init()
	e := new(Editor)
	pane := Pane{content = e}
	append(&g.panes.open, &pane)
	g.panes.focused = &pane
	defer {
		editor_destroy(e)
		free(e)
		delete(g.panes.open)
		g.panes.open = {}
		g.panes.focused = nil
		fuzzy.destroy()
		words_destroy()
	}
	editor_open(e, path)
	testing.expect(t, attach_when_found(e))
	testing.expect(t, completion_frames(e, completes))
	at := len(text) - 1
	textedit.set_single_selection(e, {at, at, -1})

	// "t" opens the list: its first few words
	cs := &g.lsp.completion
	editor_text_input(e, "t")
	listed := completion_frames(e, completion_listed)
	testing.expect(t, listed && cs.incomplete && !shows_completion("target_func"))

	// "a" asks again, and "rg" is typed before that answer comes
	editor_text_input(e, "a")
	completion_frame(e, poll = false)
	testing.expect(t, cs.request != 0)
	for letter in ([]string{"r", "g"}) {
		editor_text_input(e, letter)
		completion_frame(e, poll = false)
	}

	// The answers come: the function is listed, and Enter inserts it
	found := completion_frames(e, target_listed)
	testing.expect(t, found)
	enter: sdl.Event
	enter.type = .KEY_DOWN
	enter.key.key = sdl.K_RETURN
	testing.expect(t, lsp_completion_handle_key(&enter))
	line, _ := textedit.line_text(e, 2)
	testing.expect_value(t, line, "target_func")
}


// A frame of what completion depends on: answers, the editor's edits going
// out, its words, then asking and filtering
@(private = "file")
completion_frame :: proc(e: ^Editor, poll := true) {
	if poll do lsp_frame()
	textedit.take_changes(e)
	words_frame()
	lsp_completion_frame()
}


// Runs completion frames until `done`; false after a few seconds
@(private = "file")
completion_frames :: proc(e: ^Editor, done: proc() -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		completion_frame(e)
		if done() do return true
		time.sleep(2 * time.Millisecond)
	}
	return false
}


// The focused editor's server is running and completes
@(private = "file")
completes :: proc() -> bool {
	return langs.client_with(&focused_editor().lsp, .Completion) != nil
}


// The list is open with items, no answer on its way
@(private = "file")
completion_listed :: proc() -> bool {
	cs := &g.lsp.completion
	return cs.open && cs.request == 0 && len(cs.shown) > 0
}


@(private = "file")
target_listed :: proc() -> bool {
	return g.lsp.completion.request == 0 && shows_completion("target_func")
}


// Whether the completion list shows a server's item
@(private = "file")
shows_completion :: proc(label: string) -> bool {
	cs := &g.lsp.completion
	for s in cs.shown {
		if s.index < 0 do continue
		if cs.items[s.index].label == label do return true
	}
	return false
}


// --- Word completions --------------------------------------------------------------

@(private = "file")
WORDS_TEXT ::
	"alpha_one alpha_two beta_three utf8_name item_aaaaaaaa item_bbbbbbbb item_cccccccc " +
	"item_dddddddd item_eeeeeeee item_z\n\n\n"


@(private = "file")
use_words :: proc(mode: string) {
	g.settings.words = mode
	g.settings.words_min_length = 3
	g.settings.lsp_fetch_timeout = 100
	g.settings.words_in_text_files = false
}


@(private = "file")
reset_words :: proc() {
	g.settings.words = ""
	g.settings.words_min_length = 0
	g.settings.lsp_fetch_timeout = 0
}


// Writes WORDS_TEXT to a temp file with the extension and opens it in a focused
// pane, with the words thread running, the caret on the last line. Close with
// close_words_file
@(private = "file")
open_words_file :: proc(t: ^testing.T, ext: string) -> (e: ^Editor, path: string) {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	path = fmt.tprintf("%s/typo-words-%d.%s", dir, os.get_pid(), ext)
	_ = os.write_entire_file(path, WORDS_TEXT)

	words_init()
	e = new(Editor)
	pane := new(Pane)
	pane.content = e
	append(&g.panes.open, pane)
	g.panes.focused = pane
	editor_open(e, path)

	at := len(WORDS_TEXT) - 1
	textedit.set_single_selection(e, {at, at, -1})
	testing.expect(t, completion_frames(e, words_collected))
	return e, path
}


@(private = "file")
close_words_file :: proc(e: ^Editor, path: string) {
	lsp_completion_destroy()
	pane := g.panes.focused
	editor_destroy(e)
	free(e)
	free(pane)
	delete(g.panes.open)
	g.panes.open = {}
	g.panes.focused = nil
	fuzzy.destroy()
	words_destroy()
	os.remove(path)
}


@(private = "file")
words_collected :: proc() -> bool {
	return focused_editor().words.index != nil
}


// Types the text a character at a time, as keys do
@(private = "file")
type_text :: proc(e: ^Editor, text: string) {
	for i in 0 ..< len(text) {
		editor_text_input(e, text[i:][:1])
		completion_frame(e)
	}
}


// Runs completion frames for a while
@(private = "file")
settle :: proc(e: ^Editor, duration := 200 * time.Millisecond) {
	start := time.tick_now()
	for time.tick_since(start) < duration {
		completion_frame(e)
		time.sleep(2 * time.Millisecond)
	}
}


// Whether the completion list shows a word
@(private = "file")
shows_word :: proc(word: string) -> bool {
	for s in g.lsp.completion.shown {
		if s.index >= 0 do continue
		if s.word == word do return true
	}
	return false
}


@(private = "file")
alpha_listed :: proc() -> bool {
	return shows_word("alpha_one")
}


@(private = "file")
press_key :: proc(key: sdl.Keycode) -> bool {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.key = key
	return lsp_completion_handle_key(&event)
}


// With no server, typed words of three letters get the file's words (not ones
// with digits, nor the word typed); Enter puts the chosen one at every caret as
// one undo step
@(test)
test_words_without_server :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_words("fallback")
	defer reset_words()
	e, path := open_words_file(t, "code")
	defer close_words_file(e, path)

	// Carets on the last two lines
	second := len(WORDS_TEXT) - 2
	clear(&e.sels)
	append(&e.sels, Selection{second, second, -1}, Selection{second + 1, second + 1, -1})
	textedit.normalize(e)

	// Two letters: too short
	type_text(e, "al")
	settle(e)
	testing.expect(t, !shows_word("alpha_one"))

	// Three
	type_text(e, "p")
	testing.expect(t, completion_frames(e, alpha_listed))
	testing.expect(t, shows_word("alpha_two"))
	testing.expect(t, !shows_word("beta_three"))
	testing.expect(t, !shows_word("alp"))

	// Enter inserts the first at both carets
	testing.expect(t, press_key(sdl.K_RETURN))
	first, _ := textedit.line_text(e, 1)
	last, _ := textedit.line_text(e, 2)
	testing.expect_value(t, first, "alpha_one")
	testing.expect_value(t, last, "alpha_one")
	testing.expect(t, !g.lsp.completion.open)

	textedit.undo(e)
	first, _ = textedit.line_text(e, 1)
	testing.expect_value(t, first, "alp")
}


// After typing rests the words are collected again, and then nothing keeps
// frames coming
@(test)
test_words_collected_again :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_words("fallback")
	defer reset_words()
	e, path := open_words_file(t, "code")
	defer close_words_file(e, path)

	type_text(e, "gamma_four")
	testing.expect(t, words_busy())
	settle(e, 2 * WORDS_DELAY)
	testing.expect(t, completion_frames(e, proc() -> bool { return !words_busy() }))

	index := e.words.index
	testing.expect(t, index != nil && index.version == e.buf.version)
}


// Trigger completion offers words at any length (with digits once one is
// typed); with words disabled nothing is offered
@(test)
test_words_trigger_and_disabled :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_words("fallback")
	defer reset_words()
	e, path := open_words_file(t, "code")
	defer close_words_file(e, path)

	// One letter: words only when asked for
	type_text(e, "b")
	settle(e)
	testing.expect(t, !shows_word("beta_three"))
	testing.expect(t, editor_run_command(e, .Trigger_Completion))
	testing.expect(t, completion_frames(e, proc() -> bool { return shows_word("beta_three") }))

	// Words with digits once a digit is typed
	type_text(e, " u")
	testing.expect(t, editor_run_command(e, .Trigger_Completion))
	settle(e)
	testing.expect(t, g.lsp.completion.open)
	testing.expect(t, !shows_word("utf8_name"))
	type_text(e, "tf8")
	testing.expect(t, completion_frames(e, proc() -> bool { return shows_word("utf8_name") }))

	// Disabled
	lsp_completion_close()
	g.settings.words = "disabled"
	testing.expect(t, !editor_run_command(e, .Trigger_Completion))
	type_text(e, "tf8")
	settle(e)
	testing.expect_value(t, len(g.lsp.completion.shown), 0)
}


// Markdown and plain text files have no word completions unless asked for
@(test)
test_words_off_in_prose :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_words("fallback")
	defer reset_words()

	doc: markdown.Doc
	md, text, code: Editor
	md.status, md.path, md.md = .Text, "notes.md", &doc
	text.status, text.path = .Text, "notes.TXT"
	code.status, code.path = .Text, "config.yaml"
	testing.expect_value(t, words_mode(&md), Words_Mode.Disabled)
	testing.expect_value(t, words_mode(&text), Words_Mode.Disabled)
	testing.expect_value(t, words_mode(&code), Words_Mode.Fallback)

	// Typing asks for nothing
	lsp_typed(&md, "abc")
	testing.expect(t, g.lsp.completion.due == nil)
	testing.expect(t, !lsp_trigger_completion(&md))

	g.settings.words_in_text_files = true
	testing.expect_value(t, words_mode(&md), Words_Mode.Fallback)
	testing.expect_value(t, words_mode(&text), Words_Mode.Fallback)
}


// With "fallback", a server's items keep the words out; an empty answer, an
// error or no answer in time brings them
@(test)
test_words_fallback :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	for completion in ([]Fake_Completion{.Words, .Empty, .Error, .Late}) {
		use_fake_server(t, false, completion)
		defer stop_fake_server()
		use_words("fallback")
		defer reset_words()
		e, path := open_words_file(t, "fake")
		defer close_words_file(e, path)
		testing.expect(t, attach_when_found(e))
		testing.expect(t, completion_frames(e, completes))

		type_text(e, "alp")
		listed := completion_frames(e, proc() -> bool { return len(g.lsp.completion.shown) > 0 })
		testing.expect(t, listed)

		cs := &g.lsp.completion
		switch completion {
		case .Words:
			testing.expect(t, shows_completion("alpha_one"))
			testing.expect(t, !shows_word("alpha_one"))
		case .Empty, .Error:
			testing.expect(t, shows_word("alpha_one"))
			testing.expect_value(t, cs.server, Server_Answer.Failed)
		case .Late, .Incomplete:
			testing.expect(t, shows_word("alpha_one"))
			testing.expect_value(t, cs.server, Server_Answer.Waiting)
		}
	}
}


// A server's answer after the words showed replaces them, unless a word was
// chosen with the keys: then the words stay until the next letter
@(test)
test_words_replaced_by_late_answer :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	for navigate in ([]bool{false, true}) {
		use_fake_server(t, false, .Late)
		defer stop_fake_server()
		use_words("fallback")
		defer reset_words()
		e, path := open_words_file(t, "fake")
		defer close_words_file(e, path)
		testing.expect(t, attach_when_found(e))
		testing.expect(t, completion_frames(e, completes))

		type_text(e, "alp")
		testing.expect(t, completion_frames(e, alpha_listed))
		if navigate do testing.expect(t, press_key(sdl.K_DOWN))

		// The answer comes
		cs := &g.lsp.completion
		answered := completion_frames(e, proc() -> bool {
			return g.lsp.completion.server == .Items
		})
		testing.expect(t, answered)
		completion_frame(e)
		if navigate {
			testing.expect(t, shows_word("alpha_one"))
			testing.expect_value(t, cs.selected, 1)
			type_text(e, "h")
		}
		testing.expect(t, shows_completion("alpha_one"))
		testing.expect(t, !shows_word("alpha_one"))
	}
}


// With "enabled", words come after the server's items (even "item_z", which
// matches "ite" better than its long names), less those it lists
@(test)
test_words_enabled :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)
	use_fake_server(t, false, .Incomplete)
	defer stop_fake_server()
	use_words("enabled")
	defer reset_words()
	e, path := open_words_file(t, "fake")
	defer close_words_file(e, path)
	testing.expect(t, attach_when_found(e))
	testing.expect(t, completion_frames(e, completes))

	// The server lists five of the six "item_" words
	type_text(e, "ite")
	mixed := completion_frames(e, proc() -> bool {
		return shows_completion("item_aaaaaaaa") && shows_word("item_z")
	})
	testing.expect(t, mixed)
	testing.expect(t, !shows_word("item_aaaaaaaa"))

	cs := &g.lsp.completion
	seen_word := false
	for s in cs.shown {
		if s.index < 0 do seen_word = true
		if s.index >= 0 do testing.expect(t, !seen_word)
	}
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
