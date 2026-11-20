package editor

// Word completions' source: each editor's words (`words.Index`), collected on
// the words thread from a snapshot of its text when it gets the keys, and again
// once typing in it rests WORDS_DELAY. The completion list (lsp_completion.odin)
// offers them as the settings' completions section says: as a fallback when the
// language server has nothing or doesn't answer in time, alongside its items,
// or never; in Markdown and plain text files only when asked to

import "core:strings"
import "core:time"

import "buffer"
import "words"


Word_State :: struct {
	index:   ^words.Index, // the latest collected, or nil
	pending: u64,          // the job waited for, or 0
	edited:  time.Tick,    // when the text last changed
}

Words_Mode :: enum {
	Disabled,
	Fallback, // when the server has nothing or doesn't answer in time
	Enabled,  // alongside the server's items
}

// How long typing rests before an editor's words are collected again
WORDS_DELAY :: 300 * time.Millisecond

// Spent on word completions on the UI thread since the perf suite last looked
// (`words_timed`)
words_ui_time: time.Duration

@(private = "file")
words_timing: int // `words_timed` calls under way
@(private = "file")
indexer: words.Indexer
@(private = "file")
last_job: u64


words_init :: proc() {
	words.indexer_start(&indexer, wake_main_loop, nil)
}


words_destroy :: proc() {
	words.indexer_stop(&indexer)
}


// How word completions go in this editor's file
words_mode :: proc(e: ^Editor) -> Words_Mode {
	if e.status != .Text do return .Disabled
	if !g.settings.words_in_text_files && is_prose(e) {
		return .Disabled
	}

	switch g.settings.words {
	case "enabled":  return .Enabled
	case "disabled": return .Disabled
	}
	return .Fallback
}


// Markdown, or plain text: a .txt file. Files typo has no language for aren't
// taken as plain text, as it knows few languages (YAML, HTML and CSS have none)
@(private = "file")
is_prose :: proc(e: ^Editor) -> bool {
	if e.md != nil do return true

	ext := strings.to_lower(file_extension(e.path), context.temp_allocator)
	return ext == "txt" || ext == "text"
}


@(private = "file")
file_extension :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if dot <= slash + 1 do return ""
	return path[dot + 1:]
}


// After an edit: its words are collected again once typing rests
words_edited :: proc(e: ^Editor) {
	e.words.edited = time.tick_now()
}


// An editor is closing: its words go (a job on its way finds no editor)
words_close :: proc(e: ^Editor) {
	words.index_release(e.words.index)
	e.words = {}
}


// Takes the collected words, and asks for the focused editor's when its text
// changed and typing rested, or the caret left the lines they are from
words_frame :: proc() {
	words_timed()

	for r in words.indexer_take(&indexer) {
		e := editor_waiting_for(r.id)
		if e == nil {
			words.index_release(r.index)
			continue
		}

		words.index_release(e.words.index)
		e.words.index = r.index
		e.words.pending = 0
	}

	e := focused_editor()
	if e == nil || !words_due(e) {
		return
	}

	caret := e.sels[e.primary].head
	last_job += 1
	job := words.Job {
		id         = last_job,
		text       = buffer.snapshot(&e.buf),
		caret      = caret,
		caret_line = buffer.offset_to_line(&e.buf, caret),
	}
	words.indexer_post(&indexer, job)
	e.words.pending = last_job
}


// Whether frames must keep coming: the focused editor's words are to be
// collected once typing rests
words_busy :: proc() -> bool {
	e := focused_editor()
	return e != nil && words_stale(e) && e.words.pending == 0
}


// Whether the editor's words are to be collected now
@(private = "file")
words_due :: proc(e: ^Editor) -> bool {
	if e.words.pending != 0 || !words_stale(e) {
		return false
	}
	if e.words.index == nil do return true
	return time.tick_since(e.words.edited) >= WORDS_DELAY
}


// Whether the editor's words are about other text, or another part of it than
// the caret's, and word completions may use them
@(private = "file")
words_stale :: proc(e: ^Editor) -> bool {
	if words_mode(e) == .Disabled do return false

	index := e.words.index
	if index == nil || index.version != e.buf.version {
		return true
	}

	// The caret keeps a quarter of the bytes read either side, where there are more
	caret := e.sels[e.primary].head
	quarter := (index.hi - index.lo) / 4
	before := index.lo > 0 && caret < index.lo + quarter
	after := index.hi < index.length && caret > index.hi - quarter
	return before || after
}


// Counts the time to the end of the caller's scope as word completion work on
// the UI thread, which the perf suite limits. Nested calls count once
@(deferred_out = words_timed_end)
words_timed :: proc() -> time.Tick {
	words_timing += 1
	return time.tick_now()
}


@(private = "file")
words_timed_end :: proc(start: time.Tick) {
	words_timing -= 1
	if words_timing == 0 do words_ui_time += time.tick_since(start)
}


@(private = "file")
editor_waiting_for :: proc(job: u64) -> ^Editor {
	for p in g.panes.open {
		e, is_editor := p.content.(^Editor)
		if is_editor && e.words.pending == job {
			return e
		}
	}
	return nil
}
