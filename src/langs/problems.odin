package langs

// Diagnostics: the problems each server reports for an open file, as byte
// ranges (converted on the client's thread) that follow the edits until the
// server reports again, underlined by the view (View.problems)

import "../buffer"
import "../lsp"
import "../textedit"


// Problems are moved through a frame's edits while edits x problems stays
// under this
@(private = "file")
MAX_SHIFT_WORK :: 1_000_000


// textDocument/publishDiagnostics: replaces what the client said before about
// the file, brought up to date with the edits made since the text it was
// about. Takes the problems
diagnostics_published :: proc(c: ^Client, x: ^lsp.Diagnostics) {
	problems := x.problems
	x.problems = nil

	for d in env.documents() {
		if d.uri == x.uri {
			problems_set(d, c, problems, x.version)
			return
		}
	}
	lsp.problems_destroy(problems)
}


// Replaces a client's problems in a document with `problems` (sorted, about
// the text at `version`), taking them
problems_set :: proc(d: ^Doc, c: ^Client, problems: []lsp.Problem, version: u64) {
	dc: ^Doc_Client
	for &x in d.clients {
		if x.client == c do dc = &x
	}
	if dc == nil {
		lsp.problems_destroy(problems)
		return
	}

	for edit in d.edits {
		if edit.version <= version do continue
		lsp.shift_problems(problems, edit.offset, edit.old_len, edit.new_len)
	}

	lsp.problems_destroy(dc.problems)
	dc.problems = problems
	problems_changed(d)
}


// Forgets a document's problems (closing it), or one client's (it went away)
problems_clear :: proc(d: ^Doc, only: ^Client = nil) {
	for &dc in d.clients {
		if only != nil && dc.client != only {
			continue
		}
		lsp.problems_destroy(dc.problems)
		dc.problems = nil
	}

	if only == nil {
		delete(d.problems)
		delete(d.marks)
		d.problems = nil
		d.marks = nil
		if d.view != nil do d.view.problems = nil
		return
	}
	problems_changed(d)
}


// Moves the problems with the frame's edits. With very many of both (a large
// rename in a file full of problems), they are dropped instead: the server
// publishes again for the new text
problems_edited :: proc(d: ^Doc, changes: []buffer.Change) {
	if len(d.problems) == 0 do return

	if len(changes) * len(d.problems) > MAX_SHIFT_WORK {
		problems_clear(d)
		return
	}

	for c in changes {
		for dc in d.clients {
			lsp.shift_problems(dc.problems, c.offset, c.old_len, c.new_len)
		}
	}
	problems_changed(d)
}


// Rebuilds the document's sorted list and the view's underlines from each
// client's (sorted) problems
@(private = "file")
problems_changed :: proc(d: ^Doc) {
	clear(&d.problems)
	for dc in d.clients do lsp.merge_problems(&d.problems, dc.problems)

	clear(&d.marks)
	for p in d.problems {
		append(&d.marks, textedit.Problem{p.lo, p.hi, problem_severity(p)})
	}
	if d.view != nil do d.view.problems = d.marks[:]
}


problem_severity :: proc(p: lsp.Problem) -> textedit.Severity {
	return textedit.Severity(clamp(p.severity, 1, 4) - 1)
}


// How many errors and warnings the file has
problem_counts :: proc(d: ^Doc) -> (errors, warnings: int) {
	for p in d.problems {
		switch p.severity {
		case 1: errors += 1
		case 2: warnings += 1
		}
	}
	return
}


// The problems at a document offset (an empty one counts at its own offset),
// from the temp allocator
problems_at :: proc(d: ^Doc, offset: int) -> []lsp.Problem {
	out := make([dynamic]lsp.Problem, context.temp_allocator)
	for p in d.problems {
		if p.lo > offset do break

		inside := offset >= p.lo && offset < max(p.hi, p.lo + 1)
		if inside do append(&out, p)
	}
	return out[:]
}
