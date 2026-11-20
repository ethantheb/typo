package editor

// Hover: when the pointer rests on text for the hover delay (or on Show hover,
// F8 or a failed Go to definition, at the caret), a popup by the text shows the
// problems there and what the server says about the symbol (Markdown: code
// blocks colored by language, paragraphs, headings). It closes when the pointer
// leaves the text and the popup, on a key, a click or an edit

import "core:strings"

import clay "../vendor/clay-odin"
import "gfx"
import "langs"
import "lsp"
import sdl "../vendor/sdl3"
import "syntax"
import "textedit"


Hover :: struct {
	// Where the pointer rests
	rest_editor: ^Editor,
	rest_offset: int,
	rest_since:  u64,  // ns
	rest_asked:  bool, // a popup was opened for this rest

	// The popup
	open:        bool,
	editor:      ^Editor,
	offset:      int,    // the character asked about
	lo, hi:      int,    // the text it is about: the word, or the server's range
	version:     u64,    // of the buffer; an edit closes it
	request:     int,    // the hover request waiting for its answer, or 0
	client:      ^langs.Client, // asked
	text:        string, // owned; the server's Markdown, "" for none (yet)
	message:     string, // owned; a note of typo's own ("No definition found")
	sticky:      bool,   // opened at the caret: the pointer moving doesn't close it
	opened:      u64,    // frame
	left_at:     u64,    // ns; when the pointer left the text and the popup, or 0
}

// How long the pointer may be off the text and the popup (crossing the gap
// between them) before the popup closes
@(private = "file")
HOVER_GRACE :: 250_000_000

@(private = "file")
HOVER_MAX_W :: 560

@(private = "file")
HOVER_MAX_H :: 340


// After the panes' frames: closes the popup when what it is about went away,
// and opens it where the pointer has rested long enough
lsp_hover_frame :: proc() {
	h := &g.lsp.hover

	// Close it when the text changed, a press landed elsewhere, or the pointer
	// has been away from the text and the popup for a moment
	if h.open {
		e := h.editor
		over_popup := pointer_in(clay.ID("LspHover"))
		pressed_away := g.mouse_pressed && h.opened != g.frame && !over_popup

		away := !h.sticky && !over_popup && !pointer_on_range(e, h.lo, h.hi)
		now := sdl.GetTicksNS()
		if !away {
			h.left_at = 0
		} else if h.left_at == 0 {
			h.left_at = now
		}
		gone := away && now - h.left_at > HOVER_GRACE

		if e.buf.version != h.version || pressed_away || gone {
			lsp_hover_close()
		}
	}

	// Where the pointer rests
	e, offset, resting := pointer_char()
	if !resting {
		h.rest_editor = nil
		return
	}
	if e != h.rest_editor || offset != h.rest_offset {
		h.rest_editor = e
		h.rest_offset = offset
		h.rest_since = sdl.GetTicksNS()
		h.rest_asked = false
	}

	delay := u64(g.settings.lsp_hover_delay) * 1_000_000
	waited := sdl.GetTicksNS() - h.rest_since >= delay
	on_open := h.open && h.editor == e && offset >= h.lo && offset < max(h.hi, h.lo + 1)
	if waited && !h.rest_asked && !on_open && delay > 0 {
		h.rest_asked = true
		open_hover(e, offset, sticky = false)
	}
}


// Whether the hover popup is under the pointer, so what is under it doesn't react
lsp_hover_covers_pointer :: proc() -> bool {
	return g.lsp.hover.open && pointer_in(clay.ID("LspHover"))
}


// Whether frames must keep coming: the pointer is resting, waiting for the delay
lsp_hover_busy :: proc() -> bool {
	h := &g.lsp.hover
	leaving := h.open && h.left_at != 0
	if leaving do return true
	if h.rest_editor == nil || h.rest_asked || g.settings.lsp_hover_delay <= 0 {
		return false
	}

	delay := u64(g.settings.lsp_hover_delay) * 1_000_000
	return sdl.GetTicksNS() - h.rest_since < delay + 50_000_000
}


// Shows what is at the caret (Show hover, stepping through problems)
lsp_hover_at_caret :: proc(e: ^Editor) {
	open_hover(e, e.sels[e.primary].head, sticky = true)
}


// Shows a note by the text at `offset`
lsp_hover_message :: proc(e: ^Editor, offset: int, message: string) {
	lsp_hover_close()

	h := &g.lsp.hover
	set_hover_place(e, offset, sticky = true)
	h.message = strings.clone(message)
}


lsp_hover_close :: proc() {
	h := &g.lsp.hover
	if h.request != 0 do langs.cancel_request(h.request, h.client)
	delete(h.text)
	delete(h.message)
	h.text, h.message = "", ""
	h.open = false
	h.editor = nil
	h.request = 0
	h.client = nil
	h.left_at = 0
}


// An editor is closing: nothing may point at it
lsp_hover_forget :: proc(e: ^Editor) {
	h := &g.lsp.hover
	if h.editor == e do lsp_hover_close()
	if h.rest_editor == e do h.rest_editor = nil
}


// The server's answer: the popup shows it, or closes if there is nothing to show
lsp_hover_response :: proc(r: langs.Request, resp: lsp.Response) {
	h := &g.lsp.hover
	if !h.open || h.editor != request_editor(r) || h.request != r.id || h.client != r.client {
		return
	}
	h.request = 0

	hover, decoded := resp.result.(lsp.Hover)
	if decoded && hover.lo >= 0 {
		h.lo = hover.lo
		h.hi = hover.hi
	}

	delete(h.text)
	h.text = strings.clone(hover.markdown)
	if !hover_has_content() do lsp_hover_close()
}


// Opens the popup for the character at `offset`: its problems at once, the
// server's answer when it comes
@(private = "file")
open_hover :: proc(e: ^Editor, offset: int, sticky: bool) {
	lsp_hover_close()

	problems := len(langs.problems_at(&e.lsp, offset)) > 0
	set_hover_place(e, offset, sticky)
	h := &g.lsp.hover
	h.request, h.client = lsp_request_hover(e, offset)
	if h.request == 0 && !problems {
		lsp_hover_close()
	}
}


@(private = "file")
set_hover_place :: proc(e: ^Editor, offset: int, sticky: bool) {
	h := &g.lsp.hover
	h.open = true
	h.editor = e
	h.offset = offset
	h.lo, h.hi = textedit.word_at(e, offset)
	if h.hi <= h.lo do h.hi = h.lo + 1
	h.version = e.buf.version
	h.sticky = sticky
	h.opened = g.frame
}


// Whether there is something to show yet
@(private = "file")
hover_has_content :: proc() -> bool {
	h := &g.lsp.hover
	if !h.open do return false
	return h.text != "" || h.message != "" || len(langs.problems_at(&h.editor.lsp, h.offset)) > 0
}


// The editor and character under the pointer, while it may hover there: over
// an editor's text, with no button down and nothing covering it
@(private = "file")
pointer_char :: proc() -> (e: ^Editor, offset: int, ok: bool) {
	if g.mouse_down || !ui_interactive() || pointer_in(clay.ID("LspHover")) {
		return
	}

	for p in g.panes.open {
		ed, is_editor := p.content.(^Editor)
		if !is_editor || !pane_live(p) || ed.status != .Text || ed.kind.char_at == nil {
			continue
		}

		// Without a server or problems there is nothing to show
		if len(ed.lsp.clients) == 0 && len(ed.lsp.problems) == 0 {
			continue
		}
		if !gfx.rect_contains(ed.view, g.mouse_pos) || !editor_text_hit(ed, g.mouse_pos) {
			continue
		}

		offset, ok = ed.kind.char_at(ed, g.mouse_pos)
		return ed, offset, ok
	}
	return
}


// Whether the pointer is on the text [lo, hi) of an editor
@(private = "file")
pointer_on_range :: proc(e: ^Editor, lo, hi: int) -> bool {
	if e.kind.char_at == nil || !gfx.rect_contains(e.view, g.mouse_pos) {
		return false
	}
	offset, on_char := e.kind.char_at(e, g.mouse_pos)
	return on_char && offset >= lo && offset < hi
}


// --- The popup ---------------------------------------------------------------------

lsp_hover_ui :: proc() {
	h := &g.lsp.hover
	if !h.open || !hover_has_content() {
		return
	}

	// By the text: above it, or below where there is no room above
	e := h.editor
	if e.kind.char_rect == nil do return
	anchor, in_view := e.kind.char_rect(e, h.lo)
	if !in_view do return

	above := anchor.y > HOVER_MAX_H * 0.6
	x := clamp(anchor.x - 8, 4, max(f32(g.window_w) - HOVER_MAX_W - 4, 4))
	attach: clay.FloatingAttachPoints
	y: f32
	if above {
		attach = {element = .LeftBottom, parent = .LeftTop}
		y = anchor.y - 4
	} else {
		attach = {element = .LeftTop, parent = .LeftTop}
		y = anchor.y + anchor.h + 4
	}

	g.in_popup = true
	defer g.in_popup = false

	if clay.UI(clay.ID("LspHover"))({
		layout = {
			sizing = {clay.SizingFit({max = HOVER_MAX_W}), clay.SizingFit({max = HOVER_MAX_H})},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {attachTo = .Root, attachment = attach, offset = {x, y}, zIndex = 115},
	}) {
		body := clay.ID("LspHoverBody")
		wheel_scroll_list(body)
		if clay.UI(body)({
			layout = {
				sizing = {clay.SizingFit({max = HOVER_MAX_W}), clay.SizingFit({max = HOVER_MAX_H})},
				layoutDirection = .TopToBottom,
				padding = {10, 10, 8, 8},
				childGap = 8,
			},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			hover_contents(e)
		}
	}
}


// What the popup says: typo's note, the problems, then the server's answer
@(private = "file")
hover_contents :: proc(e: ^Editor) {
	h := &g.lsp.hover

	if h.message != "" {
		paragraph(h.message, gfx.theme.text_dim)
	}

	problems := langs.problems_at(&e.lsp, h.offset)
	for p in problems {
		if clay.UI()({layout = {childGap = 8}}) {
			// The dot, level with the first line
			if clay.UI()({layout = {padding = {top = 5}}}) {
				if clay.UI()({
					layout = {sizing = {clay.SizingFixed(6), clay.SizingFixed(6)}},
					backgroundColor = severity_color(langs.problem_severity(p)),
					cornerRadius = clay.CornerRadiusAll(3),
				}) {}
			}

			text := p.message
			if p.source != "" {
				text = strings.concatenate({p.message, "  ", p.source}, context.temp_allocator)
			}
			paragraph(text, gfx.theme.text)
		}
	}

	if h.text == "" do return
	if len(problems) > 0 || h.message != "" {
		hover_rule()
	}
	markdown_blocks(h.text, e.hl.lang)
}


severity_color :: proc(s: textedit.Severity) -> clay.Color {
	switch s {
	case .Error:   return gfx.theme.error
	case .Warning: return gfx.theme.ansi[3] // yellow
	case .Info:    return gfx.theme.accent
	case .Hint:    return gfx.theme.text_faint
	}
	return gfx.theme.text_faint
}


@(private = "file")
hover_rule :: proc() {
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}},
		backgroundColor = gfx.theme.border,
	}) {}
}


// --- Markdown, simply ----------------------------------------------------------------

// Servers' hover text is short Markdown: code blocks, paragraphs, headings,
// rules and lists. Code is colored by its language (the fence's, else the
// file's); inline markers are dropped
@(private)
markdown_blocks :: proc(text: string, file_lang: syntax.Language) {
	paragraph_lines := make([dynamic]string, context.temp_allocator)
	text := text

	for {
		line, more := strings.split_lines_iterator(&text)
		if !more do break
		line = strings.trim_right(line, "\r")
		trimmed := strings.trim_space(line)

		switch {
		case strings.has_prefix(trimmed, "```"):
			flush_paragraph(&paragraph_lines)

			// The code, up to the closing fence
			lang := syntax.language_for_name(strings.trim_space(trimmed[3:]))
			if lang == .None do lang = file_lang
			code := make([dynamic]string, context.temp_allocator)
			for {
				code_line, has_line := strings.split_lines_iterator(&text)
				if !has_line do break
				if strings.has_prefix(strings.trim_space(code_line), "```") do break
				append(&code, strings.trim_right(code_line, "\r"))
			}
			code_block(code[:], lang)

		case trimmed == "":
			flush_paragraph(&paragraph_lines)

		case is_rule(trimmed):
			flush_paragraph(&paragraph_lines)
			hover_rule()

		case strings.has_prefix(trimmed, "#"):
			flush_paragraph(&paragraph_lines)
			heading := strings.trim_space(strings.trim_left(trimmed, "#"))
			config := text_config(gfx.theme.text_bright, FONT_SIZE_SMALL, .Bold)
			config.wrapMode = .Words
			clay.TextDynamic(plain_inline(heading), config)

		case is_list_item(trimmed):
			flush_paragraph(&paragraph_lines)
			item := strings.concatenate({"•  ", trimmed[2:]}, context.temp_allocator)
			append(&paragraph_lines, item)
			flush_paragraph(&paragraph_lines)

		case:
			append(&paragraph_lines, trimmed)

			// Two trailing spaces or a backslash end the line
			hard_break := strings.has_suffix(line, "  ") || strings.has_suffix(line, `\`)
			if hard_break do flush_paragraph(&paragraph_lines)
		}
	}
	flush_paragraph(&paragraph_lines)
}


// Shows the lines gathered so far as one wrapped paragraph
@(private = "file")
flush_paragraph :: proc(lines: ^[dynamic]string) {
	if len(lines) == 0 do return

	joined := strings.join(lines[:], " ", context.temp_allocator)
	joined = strings.trim_right(joined, `\`)
	paragraph(plain_inline(joined), gfx.theme.text)
	clear(lines)
}


// Text without inline Markdown: code spans, bold and escapes
@(private = "file")
plain_inline :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '`':
			continue
		case c == '*' && i + 1 < len(s) && s[i + 1] == '*':
			i += 1
			continue
		case c == '\\' && i + 1 < len(s) && is_punctuation(s[i + 1]):
			i += 1
			strings.write_byte(&sb, s[i])
			continue
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}


@(private = "file")
is_punctuation :: proc(c: u8) -> bool {
	return strings.index_byte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) >= 0
}


// "---", "***" or "___"
@(private = "file")
is_rule :: proc(s: string) -> bool {
	if len(s) < 3 do return false
	if s[0] != '-' && s[0] != '*' && s[0] != '_' {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] != s[0] do return false
	}
	return true
}


@(private = "file")
is_list_item :: proc(s: string) -> bool {
	return len(s) > 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' '
}


// Lines of code in the editor font, colored by the language's lexer. The popup
// is interface: it keeps its size when the pane zooms
@(private = "file")
code_block :: proc(lines: []string, lang: syntax.Language) {
	size := max(editor_font_size(1), 11) - 1
	rules := syntax.rules_for(lang)
	state: syntax.Lex_State

	if clay.UI()({
		layout = {
			sizing = {width = clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {8, 8, 6, 6},
		},
		backgroundColor = gfx.theme.md_code_bg,
		cornerRadius = clay.CornerRadiusAll(4),
		clip = {horizontal = true},
	}) {
		for line in lines {
			text, _ := strings.replace_all(line, "\t", "    ", context.temp_allocator)
			hl := make([]syntax.Highlight, len(text), context.temp_allocator)
			state = syntax.lex_line(rules, state, transmute([]u8)text, hl)

			// One text element per run of a color
			if clay.UI()({layout = {sizing = {height = clay.SizingFit({min = 1})}}}) {
				if len(text) == 0 {
					clay.TextDynamic(" ", text_config(gfx.theme.text, size, .Editor))
				}
				for start := 0; start < len(text); {
					end := start + 1
					for end < len(text) && hl[end] == hl[start] {
						end += 1
					}
					color := gfx.theme.syntax[hl[start]]
					clay.TextDynamic(text[start:end], text_config(color, size, .Editor))
					start = end
				}
			}
		}
	}
}
