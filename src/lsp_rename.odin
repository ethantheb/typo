package editor

// Renaming a symbol (Rename, F2, in an editor whose server renames). The server
// is asked what can be renamed at the caret (prepareRename; without it, the
// identifier there), and a field over the name takes the new one. Enter asks
// for the rename; its answer is applied as a workspace edit (lsp_edits.odin).
// Esc, a press outside the field, or the editor losing the keys drops it

import "core:strings"

import clay "../vendor/clay-odin"
import "buffer"
import "gfx"
import "langs"
import "lsp"
import sdl "../vendor/sdl3"
import "textedit"
import "uitime"


Symbol_Rename :: struct {
	editor:  ^Editor, // renamed in, or nil
	client:  ^langs.Client,
	request: int,  // the prepareRename or rename waited for, or 0
	open:    bool, // the field shows
	lo, hi:  int,  // the name, in the text at `version`
	version: u64,
	field:   Line_Edit,
	opened:  u64,  // frame
}

@(private = "file")
FIELD_MIN_WIDTH :: 180
@(private = "file")
MAX_NAME :: 256 // bytes looked at on each side of the caret for the name


// Starts renaming the symbol at the caret. False if none of the editor's
// servers renames
lsp_rename_start :: proc(e: ^Editor) -> bool {
	uitime.timed(&langs.ui_share)
	c := langs.client_with(&e.lsp, .Rename)
	if c == nil do return false

	lsp_rename_close()
	sr := &g.lsp.rename
	sr.editor = e
	sr.client = c
	caret := e.sels[e.primary].head

	if lsp.has_feature(c.caps, .Prepare_Rename) {
		method := "textDocument/prepareRename"
		sr.request = langs.send_request(&e.lsp, c, .Prepare_Rename, method, caret)
		return true
	}

	lo, hi := name_at(e, caret)
	if lo == hi {
		lsp_rename_close()
		lsp_hover_message(e, caret, "Nothing to rename here")
		return true
	}
	open_field(e, lo, hi, "")
	return true
}


// prepareRename's answer opens the field; the rename's is applied
lsp_rename_response :: proc(r: langs.Request, resp: lsp.Response) {
	uitime.timed(&langs.ui_share)
	sr := &g.lsp.rename
	if r.id != sr.request || r.client != sr.client || request_editor(r) != sr.editor {
		return
	}
	sr.request = 0
	e := request_editor(r)

	#partial switch r.feature {
	case .Prepare_Rename:
		prep, _ := resp.result.(lsp.Prepare_Rename)
		if e.buf.version != resp.version {
			lsp_rename_close()
			return
		}
		if resp.error != "" || !prep.renamable {
			lsp_rename_close()
			message := resp.error != "" ? resp.error : "This can't be renamed"
			lsp_hover_message(e, r.offset, message)
			return
		}

		lo, hi := prep.lo, prep.hi
		if lo < 0 do lo, hi = name_at(e, r.offset)
		if lo == hi {
			lsp_rename_close()
			lsp_hover_message(e, r.offset, "Nothing to rename here")
			return
		}
		open_field(e, lo, hi, prep.placeholder)

	case .Rename:
		lsp_rename_close()
		edit, _ := resp.result.(lsp.Workspace_Edit)
		switch {
		case resp.error != "":
			lsp_hover_message(e, r.offset, resp.error)
		case len(edit.files) == 0:
			lsp_hover_message(e, r.offset, "Nothing was renamed")
		case:
			lsp_apply_workspace_edit(r.client, take_edit(edit), "", "The rename")
		}
	}
}


// Each frame: dropped when its editor loses the keys or something covers it,
// or on a press outside the field
lsp_rename_frame :: proc() {
	sr := &g.lsp.rename
	if sr.editor == nil do return

	covered := editors_covered()
	pressed_outside := sr.open &&
	                   g.mouse_pressed &&
	                   sr.opened != g.frame &&
	                   !pointer_in(clay.ID("SymbolRename"))
	if sr.editor != focused_editor() || covered || pressed_outside {
		lsp_rename_close()
	}
}


// Keys while the field shows; it takes them all
lsp_rename_handle_event :: proc(event: ^sdl.Event) -> bool {
	sr := &g.lsp.rename
	if !sr.open do return false

	if event.type == .KEY_DOWN {
		switch event.key.key {
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			commit()
			return true
		case sdl.K_ESCAPE:
			lsp_rename_close()
			return true
		case sdl.K_TAB:
			return true
		}
	}
	line_edit_event(&sr.field, event)
	return true
}


// Whether the field is under the pointer, so what is under it doesn't react
lsp_rename_covers_pointer :: proc() -> bool {
	return g.lsp.rename.open && pointer_in(clay.ID("SymbolRename"))
}


lsp_rename_close :: proc() {
	sr := &g.lsp.rename
	if sr.request != 0 do langs.cancel_request(sr.request, sr.client)

	// The field is kept for the next rename
	field := sr.field
	line_edit_clear(&field)
	sr^ = {field = field}
}


// An editor is closing: nothing may point at it
lsp_rename_forget :: proc(e: ^Editor) {
	if g.lsp.rename.editor == e do lsp_rename_close()
}


lsp_rename_destroy :: proc() {
	lsp_rename_close()
	line_edit_destroy(&g.lsp.rename.field)
	g.lsp.rename = {}
}


// The field over the name, with a hint under it
lsp_rename_ui :: proc() {
	sr := &g.lsp.rename
	e := sr.editor
	if !sr.open || e == nil || e.kind.char_rect == nil {
		return
	}
	anchor, in_view := e.kind.char_rect(e, sr.lo)
	if !in_view do return

	g.in_popup = true
	defer g.in_popup = false

	if clay.UI(clay.ID("SymbolRename"))({
		layout = {
			sizing = {width = clay.SizingFit({min = FIELD_MIN_WIDTH})},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(4),
			childGap = 4,
		},
		backgroundColor = gfx.theme.panel,
		cornerRadius = clay.CornerRadiusAll(6),
		border = {color = gfx.theme.border, width = clay.BorderOutside(1)},
		floating = {
			attachTo = .Root,
			offset = {anchor.x - 9, anchor.y - 7},
			zIndex = 116,
		},
	}) {
		look := Field_Look{
			height  = FONT_SIZE_UI + 10,
			padding = 4,
			radius  = 4,
			fit     = true,
		}
		text_field(clay.ID("SymbolRenameField"), &sr.field, "", true, look)

		if clay.UI()({layout = {padding = {left = 4, right = 4}}}) {
			label("Enter to rename, Esc to cancel", gfx.theme.text_dim, FONT_SIZE_SMALL)
		}
	}
}


@(private = "file")
open_field :: proc(e: ^Editor, lo, hi: int, placeholder: string) {
	sr := &g.lsp.rename
	name := placeholder
	if name == "" do name = string(buffer.read_alloc(&e.buf, lo, hi))

	line_edit_set(&sr.field, name, 0, len(name))
	sr.open = true
	sr.lo, sr.hi = lo, hi
	sr.version = e.buf.version
	sr.opened = g.frame
}


// Enter: asks for the rename, unless the name is empty or the same
@(private = "file")
commit :: proc() {
	sr := &g.lsp.rename
	e := sr.editor
	c := sr.client
	name := strings.trim_space(line_edit_string(&sr.field))
	old := string(buffer.read_alloc(&e.buf, sr.lo, sr.hi))

	unchanged := name == "" || name == old
	gone := e.buf.version != sr.version || c.state != .Running
	if unchanged || gone {
		lsp_rename_close()
		return
	}

	uitime.timed(&langs.ui_share)
	id := lsp.request_rename(c.client, e.lsp.uri, sr.lo, name)
	langs.track_request(&e.lsp, c, .Rename, id, sr.lo)
	sr.request = id
	sr.open = false
}


// The identifier at or just before an offset, as a range; empty if there is
// none (or it is a number)
@(private = "file")
name_at :: proc(e: ^Editor, offset: int) -> (lo, hi: int) {
	lo, hi = textedit.word_span(e, offset, MAX_NAME)
	if lo == hi do return offset, offset

	first := buffer.byte_at(&e.buf, lo)
	if first >= '0' && first <= '9' {
		return offset, offset
	}
	return lo, hi
}


// An edit taken over from a response, which is freed after it is handled: its
// files move to a new list, leaving the response's empty
@(private = "file")
take_edit :: proc(edit: lsp.Workspace_Edit) -> lsp.Workspace_Edit {
	files := make([]lsp.File_Edit, len(edit.files))
	for &fe, i in edit.files {
		files[i] = fe
		fe = {}
	}
	return {files}
}
