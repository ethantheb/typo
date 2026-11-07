package mdview

import "core:strings"

import clay "../../vendor/clay-odin"
import "../buffer"
import "../gfx"
import sdl "../../vendor/sdl3"
import "../textedit"

// The rendered view as a textedit.Kind: what a View of a Markdown document
// does while it is rendered (see set_mode). Its kind_data is the mdview.View.
KIND := textedit.Kind {
	frame_begin  = kind_frame_begin,
	frame_end    = kind_frame_end,
	ready        = kind_ready,
	draw         = kind_draw,
	offset_at    = kind_offset_at,
	over_text    = kind_over_text,
	max_scroll   = kind_max_scroll,
	scroll_step  = kind_scroll_step,
	reveal       = kind_reveal,
	same_row     = kind_same_row,
	move         = kind_move,
	page_height  = kind_page_height,
	snap         = kind_snap,
	edit_key     = kind_edit_key,
	text_input   = kind_text_input,
	copy_range   = kind_copy_range,
	replace      = kind_replace,
	edited       = kind_edited,
	caret_hidden = kind_caret_hidden,
	hidden_key   = kind_hidden_key,
	show_caret   = kind_show_caret,
	press        = kind_press,
	capture      = kind_capture,
	wheel_x      = kind_wheel_x,
	block_at     = kind_block_at,
	drag         = kind_drag,
	drag_x       = kind_drag_x,
	release      = kind_release,
	pointer      = kind_pointer,
}

@(private = "file")
md :: proc(v: ^textedit.View) -> ^View {
	return (^View)(v.kind_data)
}

@(private = "file")
kind_frame_begin :: proc(v: ^textedit.View) {
	e := md(v)
	if !env.input().mouse_down do e.mdv.holding = false
	frame_begin(e)
	layout_visible(e)
}

@(private = "file")
kind_frame_end :: proc(v: ^textedit.View) {
	e := md(v)
	layout_visible(e)
	end_frame(e)
}

@(private = "file")
kind_ready :: proc(v: ^textedit.View) -> bool {
	return !images_loading(md(v))
}

@(private = "file")
kind_draw :: proc(v: ^textedit.View, b: gfx.Rect, scale: f32, caret_on: bool) {
	draw(md(v), clay.BoundingBox{b.x, b.y, b.w, b.h}, scale, caret_on)
}

@(private = "file")
kind_offset_at :: proc(v: ^textedit.View, p: [2]f32) -> int {
	return offset_at_point(md(v), p.x, p.y)
}

@(private = "file")
kind_over_text :: proc(v: ^textedit.View, p: [2]f32) -> bool {
	return gfx.rect_contains(v.view, p) && column_hit(md(v), p.x, p.y)
}

@(private = "file")
kind_max_scroll :: proc(v: ^textedit.View) -> f64 {
	return max_scroll(md(v))
}

@(private = "file")
kind_scroll_step :: proc(v: ^textedit.View) -> f64 {
	return f64(body_line_height())
}

@(private = "file")
kind_reveal :: proc(v: ^textedit.View) {
	reveal_caret(md(v))
}

@(private = "file")
kind_same_row :: proc(v: ^textedit.View, a, b: int) -> bool {
	ca, cb := caret_at(md(v), a), caret_at(md(v), b)
	return ca.line == cb.line && ca.row == cb.row
}

@(private = "file")
kind_move :: proc(v: ^textedit.View, m: textedit.Move, s: Selection) -> (head, col: int) {
	e := md(v)
	#partial switch m {
	case .Left:      return move_left(e, s.head), -1
	case .Right:     return move_right(e, s.head), -1
	case .Up:        return move_vertical(e, s, -1)
	case .Down:      return move_vertical(e, s, +1)
	case .Page_Up:   return move_page(e, s, -1)
	case .Page_Down: return move_page(e, s, +1)
	case .Home:      return move_home(e, s.head), -1
	case .End:       return move_end(e, s.head), -1
	}
	return s.head, -1
}

@(private = "file")
kind_page_height :: proc(v: ^textedit.View) -> f64 {
	return page_height(md(v))
}

@(private = "file")
kind_snap :: proc(v: ^textedit.View) {
	snap_carets(md(v))
}

@(private = "file")
kind_edit_key :: proc(v: ^textedit.View, key: sdl.KeyboardEvent) -> bool {
	return handle_key(md(v), key)
}

@(private = "file")
kind_text_input :: proc(v: ^textedit.View, text: string) {
	e := md(v)
	text := typed_text(e, text)
	if !replace_cells(e, text, .Typing) do textedit.insert(e, text)
	close_fence(e, text)
}

@(private = "file")
kind_copy_range :: proc(v: ^textedit.View, lo, hi: int) -> (from, to: int, before, after: string) {
	return copy_range(md(v), lo, hi)
}

// Pasted text without its own cells, or a cut, over cells of a table row
// empties them, keeping the pipes; pasted text goes in the first.
@(private = "file")
kind_replace :: proc(v: ^textedit.View, text: string) -> bool {
	if strings.index_any(text, "\r\n|") >= 0 do return false
	return replace_cells(md(v), text, .Other)
}

@(private = "file")
kind_edited :: proc(v: ^textedit.View) {
	renumber(md(v))
}

@(private = "file")
kind_caret_hidden :: proc(v: ^textedit.View) -> bool {
	return md(v).mdv.caretless
}

@(private = "file")
kind_hidden_key :: proc(v: ^textedit.View, key: sdl.KeyboardEvent) -> (done, handled: bool) {
	return begin_key(md(v), key)
}

@(private = "file")
kind_show_caret :: proc(v: ^textedit.View, place: bool) {
	e := md(v)
	if place {
		show_caret(e)
	} else {
		e.mdv.caretless = false
	}
}

// A Ctrl+click on a link follows it, a click on a task box toggles it, a click
// on a table's expand button toggles that, and a click beside the text column
// hides the caret.
@(private = "file")
kind_press :: proc(v: ^textedit.View, p: [2]f32, mods: sdl.Keymod, clicks: int) -> bool {
	e := md(v)
	if mods & sdl.KMOD_CTRL != {} && clicks == 1 {
		if target, wiki, ok := link_at(e, p.x, p.y); ok {
			open_link(e, target, wiki)
			return true
		}
	}
	if mods & (sdl.KMOD_SHIFT | sdl.KMOD_ALT | sdl.KMOD_CTRL) == {} && clicks == 1 {
		if lo, hi, ok := checkbox_at(e, p.x, p.y); ok {
			box := string(buffer.read_alloc(&e.buf, lo, hi))
			textedit.replace_in_place(e, lo, hi, box == "[ ]" ? "[x]" : "[ ]")
			return true
		}
	}
	if clicks == 1 && table_button_click(e, p.x, p.y) do return true
	e.mdv.cell_drag = false
	if env.input().mouse_down do hold_reveal(e)
	e.mdv.caretless = !column_hit(e, p.x, p.y)
	return e.mdv.caretless
}

@(private = "file")
kind_capture :: proc(v: ^textedit.View) -> bool {
	return code_bar_mouse(md(v))
}

// Rendered Markdown scrolls sideways only within code blocks.
@(private = "file")
kind_wheel_x :: proc(v: ^textedit.View, p: [2]f32, dx: f32) -> bool {
	if dx != 0 do scroll_code_at(md(v), p.y, dx)
	return true
}

@(private = "file")
kind_block_at :: proc(v: ^textedit.View, offset: int) -> (lo, hi: int, ok: bool) {
	return cell_text_at(md(v), offset)
}

// From a cell into others selects the rectangle of cells. After a triple
// click in a cell, the cell stays selected while the drag is in its table.
@(private = "file")
kind_drag :: proc(v: ^textedit.View, origin: Selection, offset: int, block: bool) -> bool {
	e := md(v)
	if !block do return cell_drag(e, origin, offset)
	cell_drag(e, origin, offset)
	if e.mdv.cell_drag do return true
	t := table_at(e, buffer.offset_to_line(&e.buf, origin.anchor))
	if t == nil || table_at(e, buffer.offset_to_line(&e.buf, offset)) != t do return false
	e.sels[e.primary] = origin
	return true
}

@(private = "file")
kind_drag_x :: proc(v: ^textedit.View, p: [2]f32) {
	drag_scroll_code(md(v))
}

@(private = "file")
kind_release :: proc(v: ^textedit.View) {
	snap_selection(md(v))
}

@(private = "file")
kind_pointer :: proc(v: ^textedit.View, p: [2]f32, over_text: bool) -> textedit.Pointer {
	e := md(v)
	if _, _, _, _, ok := code_bar_at(e, p); ok || e.mdv.code_drag.active do return .Arrow
	if over_text && pointer_target(e) do return .Hand
	return .Text
}
