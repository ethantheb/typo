package mdview

import "../markdown"
import "../gfx"
import "../textedit"

// Code blocks in the rendered Markdown view: their extents and widths, and
// scrolling one wider than its box sideways, with the wheel or its scroll bar


// The code block (fenced, indented, math or front matter) containing line i
@(private)
code_block_at :: proc(e: ^View, i: int) -> (block: ^Code_Block, ok: bool) {
	if code_group(e.md.lines[i].kind) == .None do return

	begin_caches(e)
	mv := &e.mdv
	if b, found := mv.code_blocks[markdown.block_first(e.md, i)]; found {
		return b, true
	}

	first, last := code_lines(e.md, i)
	block = new_clone(Code_Block{first = first, last = last}, mv.doc_allocator)
	mv.code_blocks[first] = block
	return block, true
}


// The width of a code block's widest line, and of the box it shows in
@(private)
code_widths :: proc(e: ^View, b: ^Code_Block) -> (width, box: f32) {
	// Measure the first 2000 lines once
	if !b.measured {
		cw := gfx.text_char_width(&gfx.text_system, .Editor, code_size(font_size()))
		cols := 0
		for line in b.first ..= min(b.last, b.first + 2000) {
			text, _ := line_text(e, line)
			content := int(markdown.line_detail(e.md, line, text).content[0])
			cols = max(cols, textedit.visual_col(text[content:], len(text) - content))
		}
		b.width = f32(cols) * cw
		b.measured = true
	}

	L := line_layout(e, b.first)
	return b.width, L.code_bg[1] - L.code_bg[0] - 2 * CODE_PAD
}


// A code block under line i that is wider than its box, to scroll sideways
@(private = "file")
scrollable_code :: proc(e: ^View, i: int) -> (b: ^Code_Block, width, box: f32, ok: bool) {
	b = code_block_at(e, i) or_return
	width, box = code_widths(e, b)
	return b, width, box, width > box
}


// The sideways scroll bar of a code block wider than its box, drawn under its
// last line `line`, in logical window coordinates
@(private)
code_bar :: proc(e: ^View, line: int) -> (track, thumb: gfx.Rect, first: int, ok: bool) {
	b, width, box := scrollable_code(e, line) or_return
	if line != b.last do return

	mv := &e.mdv
	L := line_layout(e, line)

	// The track, under the line's text
	track_x := e.view.x + mv.col_x + L.code_bg[0] + CODE_PAD
	track_y := e.view.y + f32(hm_y(&mv.heights, line) - e.scroll_y) + L.height - 5
	track = {track_x, track_y, box, 3}

	// The thumb, sized by how much of the code shows
	tw := max(box * box / width, 24)
	thumb_x := track.x + (box - tw) * mv.code_scroll[b.first] / (width - box)
	thumb = {thumb_x, track.y, tw, track.h}

	return track, thumb, b.first, true
}


// Where a code block's thin scroll bar takes the pointer: taller than drawn
@(private)
code_bar_grab_area :: proc(track: gfx.Rect) -> gfx.Rect {
	return {track.x, track.y - 6, track.w, track.h + 9}
}


// The code block scroll bar under a point, if any
@(private)
code_bar_at :: proc(
	e: ^View,
	p: [2]f32,
) -> (track, thumb: gfx.Rect, first, last: int, ok: bool) {
	line, _ := line_at_y(e, p.y) or_return

	// The grab area reaches a little into the next line
	for l in max(line - 1, 0) ..= line {
		track, thumb, first, ok = code_bar(e, l)
		if ok && gfx.rect_contains(code_bar_grab_area(track), p) {
			return track, thumb, first, l, true
		}
	}
	return {}, {}, 0, 0, false
}


// Pressing and dragging a code block's scroll bar. Returns true while it owns the mouse
@(private)
code_bar_mouse :: proc(e: ^View) -> bool {
	d := &e.mdv.code_drag

	// A press on a scroll bar starts the drag
	if !d.active {
		if !env.input().mouse_pressed do return false

		mouse := env.input().mouse_pos
		_, thumb, _, last, ok := code_bar_at(e, mouse)
		if !ok do return false

		// Clicking the track centres the thumb there
		grab := gfx.rect_contains(thumb, mouse) ? mouse.x - thumb.x : thumb.w / 2
		d^ = {true, last, grab}
	}

	if !env.input().mouse_down {
		d.active = false
		return true
	}

	track, thumb, first, ok := code_bar(e, d.last)
	if !ok {
		d.active = false
		return true
	}

	// Scroll to where the thumb is dragged
	b, _ := code_block_at(e, first)
	width, box := code_widths(e, b)
	thumb_x := env.input().mouse_pos.x - d.grab - track.x
	frac := clamp(thumb_x / max(track.w - thumb.w, 1), 0, 1)
	set_code_scroll(e, first, frac * (width - box))
	return true
}


// While drag-selecting past the side of a code block, scrolls it that way
@(private)
drag_scroll_code :: proc(e: ^View) {
	mouse := env.input().mouse_pos
	y := clamp(mouse.y, e.view.y, e.view.y + e.view.h - 1)
	line, _, in_view := line_at_y(e, y)
	if !in_view do return

	b, width, box, ok := scrollable_code(e, line)
	if !ok do return

	// Faster the further past the code's box the pointer is
	L := line_layout(e, line)
	x0 := e.view.x + e.mdv.col_x + L.code_bg[0] + CODE_PAD
	x1 := x0 + box
	dx: f32
	if mouse.x < x0 do dx = -((x0 - mouse.x) * 0.25 + 2)
	if mouse.x > x1 do dx = (mouse.x - x1) * 0.25 + 2

	if dx != 0 {
		x := clamp(e.mdv.code_scroll[b.first] + dx, 0, width - box)
		set_code_scroll(e, b.first, x)
	}
}


@(private)
set_code_scroll :: proc(e: ^View, first: int, x: f32) {
	if e.mdv.code_scroll[first] != x do e.mdv.code_scroll[first] = x
}


// Scrolls the code block under a point sideways. Returns false if there is
// none, or it fits
@(private)
scroll_code_at :: proc(e: ^View, y: f32, dx: f32) -> bool {
	line, _ := line_at_y(e, y) or_return
	b, width, box := scrollable_code(e, line) or_return

	x := clamp(e.mdv.code_scroll[b.first] + dx, 0, width - box)
	set_code_scroll(e, b.first, x)
	return true
}
