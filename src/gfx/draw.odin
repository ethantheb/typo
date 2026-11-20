package gfx

import "core:math"

import clay "../../vendor/clay-odin"
import sdl "../../vendor/sdl3"
import ttf "../../vendor/sdl3/ttf"

// Drawing primitives on the SDL renderer, in pixels


// The window's renderer, set by the app when it creates it
renderer: ^sdl.Renderer

CORNER_SEGMENTS :: 8


// --- Clips and overlays ------------------------------------------------------------

// Clip rectangles nest (a clipped text field inside a scrolling list): each one
// is intersected with the one around it, and ending it restores the outer one
@(private = "file")
clip_stack: [32]sdl.Rect
@(private = "file")
clip_depth: int

// Clay overlay colors (used to fade elements in): everything drawn inside one
// is mixed toward the overlay's color by its alpha. They nest
@(private = "file")
overlay_stack: [16]clay.Color
@(private = "file")
overlay_depth: int


// Starts a frame: no clips or overlays
begin_frame :: proc() {
	clip_depth = 0
	overlay_depth = 0
}


push_clip :: proc(r: sdl.Rect) {
	flush_text()

	r := r
	if clip_depth > 0 && !sdl.GetRectIntersection(r, clip_stack[clip_depth - 1], &r) {
		r = {} // no overlap: clip everything
	}

	if clip_depth < len(clip_stack) {
		clip_stack[clip_depth] = r
	}
	clip_depth += 1
	_ = sdl.SetRenderClipRect(renderer, &r)
}


pop_clip :: proc() {
	flush_text()

	clip_depth = max(clip_depth - 1, 0)

	if clip_depth == 0 {
		_ = sdl.SetRenderClipRect(renderer, nil)
	} else {
		outer := &clip_stack[min(clip_depth, len(clip_stack)) - 1]
		_ = sdl.SetRenderClipRect(renderer, outer)
	}
}


// Clips to a custom element's bounds (pixels), rounded outward
push_clip_box :: proc(b: clay.BoundingBox) {
	push_clip({i32(b.x), i32(b.y), i32(math.ceil(b.width)), i32(math.ceil(b.height))})
}


push_overlay :: proc(c: clay.Color) {
	if overlay_depth < len(overlay_stack) do overlay_stack[overlay_depth] = c
	overlay_depth += 1
}


pop_overlay :: proc() {
	overlay_depth = max(overlay_depth - 1, 0)
}


@(private = "file")
apply_overlays :: proc(c: clay.Color) -> clay.Color {
	c := c
	for o in overlay_stack[:min(overlay_depth, len(overlay_stack))] {
		t := o.a / 255
		c.rgb += (o.rgb - c.rgb) * t
	}
	return c
}


@(private)
to_fcolor :: proc(c: clay.Color) -> sdl.FColor {
	c := apply_overlays(c)
	return {c.r / 255, c.g / 255, c.b / 255, c.a / 255}
}


@(private = "file")
set_color :: proc(c: clay.Color) {
	c := apply_overlays(c)
	_ = sdl.SetRenderDrawColor(renderer, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
}


// --- Shapes and text ---------------------------------------------------------------

// Draws the subpixel text drawn so far: the text engine queues it to draw it
// all in its two passes. Anything else drawn, a clip change or presenting must
// come after this
flush_text :: proc() {
	if text_system.engine == nil do return

	_ = ttf.FlushRendererText(text_system.engine)
}


draw_text :: proc(text: ^ttf.Text, x, y: f32, c: clay.Color) {
	if text == nil do return

	c := apply_overlays(c)
	_ = ttf.SetTextColor(text, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
	_ = ttf.DrawRendererText(text, x, y)
}


fill_rect :: proc(x, y, w, h: f32, c: clay.Color) {
	if w <= 0 || h <= 0 {
		return
	}

	flush_text()
	set_color(c)
	r := sdl.FRect{x, y, w, h}
	_ = sdl.RenderFillRect(renderer, &r)
}


// Rounded rectangles are convex, so a triangle fan from the centre covers them,
// inset half a pixel; a ring fading out to half a pixel outside smooths the edge
fill_rounded_rect :: proc(b: clay.BoundingBox, r: clay.CornerRadius, c: clay.Color) {
	if r.topLeft <= 0 && r.topRight <= 0 && r.bottomLeft <= 0 && r.bottomRight <= 0 {
		fill_rect(b.x, b.y, b.width, b.height, c)
		return
	}

	flush_text()

	// Each corner's centre, radius and starting angle, clockwise from the top right
	max_r := min(b.width, b.height) / 2
	top_left := min(r.topLeft, max_r)
	top_right := min(r.topRight, max_r)
	bottom_right := min(r.bottomRight, max_r)
	bottom_left := min(r.bottomLeft, max_r)
	x_end := b.x + b.width
	y_end := b.y + b.height

	corners := [4]struct {
		cx, cy, radius, start: f32,
	} {
		{x_end - top_right, b.y + top_right, top_right, -math.PI / 2},
		{x_end - bottom_right, y_end - bottom_right, bottom_right, 0},
		{b.x + bottom_left, y_end - bottom_left, bottom_left, math.PI / 2},
		{b.x + top_left, b.y + top_left, top_left, math.PI},
	}

	// The fan's centre, then the ring around the corners: inner points, outer points
	RING :: 4 * (CORNER_SEGMENTS + 1)
	fc := to_fcolor(c)
	clear := fc
	clear.a = 0

	verts: [1 + 2 * RING]sdl.Vertex
	verts[0] = {position = {b.x + b.width / 2, b.y + b.height / 2}, color = fc}
	k := 0
	for corner in corners {
		for s in 0 ..= CORNER_SEGMENTS {
			a := corner.start + f32(s) / CORNER_SEGMENTS * (math.PI / 2)
			n := [2]f32{math.cos(a), math.sin(a)}
			p := [2]f32{corner.cx, corner.cy} + n * corner.radius
			verts[1 + k] = {position = sdl.FPoint(p - n * 0.5), color = fc}
			verts[1 + RING + k] = {position = sdl.FPoint(p + n * 0.5), color = clear}
			k += 1
		}
	}

	// A fan triangle and two ring triangles per step
	indices: [9 * RING]i32
	for i in 0 ..< RING {
		j := (i + 1) % RING
		in_i, in_j := i32(1 + i), i32(1 + j)
		out_i, out_j := in_i + RING, in_j + RING
		copy(indices[i * 9:], []i32{0, in_i, in_j, in_i, out_i, out_j, in_i, out_j, in_j})
	}

	_ = sdl.RenderGeometry(renderer, nil, &verts[0], len(verts), &indices[0], len(indices))
}


// --- Selections --------------------------------------------------------------------

// A selection's padding beside its text and the radius of its corners, for
// text of a size (all in pixels)
selection_look :: proc(text_size: f32) -> (pad, radius: f32) {
	return math.round(text_size * 0.2), math.round(text_size * 0.3)
}


// Draws one selection from its rows (pixels, top to bottom), each widened by
// `pad` on both sides. Rows that touch and overlap make one shape: rounded on
// the outside, curving into the inside corners where rows of different widths
// meet. Rows that don't (a gap, or no overlap) are shapes of their own
fill_selection :: proc(rows: []Rect, pad, radius: f32, c: clay.Color) {
	if len(rows) == 0 do return

	flush_text()
	fc := to_fcolor(c)

	for i in 0 ..< len(rows) {
		piece := selection_piece(rows, i, pad, radius)
		for f in piece.fillets[:piece.n_fillets] {
			fill_fillet(f.corner, f.dir, f.radius, fc)
		}

		box := piece.box
		fill_rounded_rect({box.x, box.y, box.w, box.h}, piece.corners, c)
	}
}


// A row of a selection's shape: its box (widened by the padding), the radius
// of each of its corners, and the inside corners where it meets the row above
Selection_Piece :: struct {
	box:       Rect,
	corners:   clay.CornerRadius,
	fillets:   [2]Fillet,
	n_fillets: int,
}

// An inside corner's curve: the square of side `radius` at `corner` toward
// `dir` (each ±1), less a quarter disc (see fill_fillet)
Fillet :: struct {
	corner, dir: [2]f32,
	radius:      f32,
}


// The shape of row i of a selection (see fill_selection)
selection_piece :: proc(rows: []Rect, i: int, pad, radius: f32) -> (p: Selection_Piece) {
	row := rows[i]
	r := Rect{row.x - pad, row.y, row.w + 2 * pad, row.h}
	p.box = r
	p.corners = {radius, radius, radius, radius}

	// Where a row above or below joins it, its corners are rounded only where
	// it reaches past that row
	if above, ok := joined_row(rows, i, i - 1, pad); ok {
		p.corners.topLeft = outer_radius(above.x - r.x, radius)
		p.corners.topRight = outer_radius(r.x + r.w - (above.x + above.w), radius)
		inner_corners(&p, above, r, radius)
	}
	if below, ok := joined_row(rows, i, i + 1, pad); ok {
		p.corners.bottomLeft = outer_radius(below.x - r.x, radius)
		p.corners.bottomRight = outer_radius(r.x + r.w - (below.x + below.w), radius)
	}
	return p
}


// Row j of a selection, widened, if it joins row i: right above or below it,
// overlapping it sideways
@(private = "file")
joined_row :: proc(rows: []Rect, i, j: int, pad: f32) -> (r: Rect, ok: bool) {
	if j < 0 || j >= len(rows) {
		return
	}

	a, b := rows[min(i, j)], rows[max(i, j)]
	touching := abs(a.y + a.h - b.y) <= 1
	overlap := min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
	if !touching || overlap + 2 * pad <= 0 {
		return
	}

	row := rows[j]
	return {row.x - pad, row.y, row.w + 2 * pad, row.h}, true
}


// The radius of a corner where a row reaches `past` beyond the row it joins:
// rounded if it does, square if not, and small enough to leave room for the
// inside corner across from it
@(private = "file")
outer_radius :: proc(past, radius: f32) -> f32 {
	if past < 0.5 do return 0
	return min(radius, past / 2)
}


// The inside corners where `above` meets `r` below it: on each side where one
// reaches further, a curve from its edge into the other's side
@(private = "file")
inner_corners :: proc(p: ^Selection_Piece, above, r: Rect, radius: f32) {
	y := r.y

	// Left: beside the narrower one's left edge, above or below the join
	left := r.x - above.x
	if left > 0.5 {
		add_fillet(p, {{r.x, y}, {-1, 1}, min(radius, left / 2, r.h / 2)})
	} else if left < -0.5 {
		add_fillet(p, {{above.x, y}, {-1, -1}, min(radius, -left / 2, above.h / 2)})
	}

	// Right
	right := above.x + above.w - (r.x + r.w)
	if right > 0.5 {
		add_fillet(p, {{r.x + r.w, y}, {1, 1}, min(radius, right / 2, r.h / 2)})
	} else if right < -0.5 {
		x := above.x + above.w
		add_fillet(p, {{x, y}, {1, -1}, min(radius, -right / 2, above.h / 2)})
	}
}


@(private = "file")
add_fillet :: proc(p: ^Selection_Piece, f: Fillet) {
	p.fillets[p.n_fillets] = f
	p.n_fillets += 1
}


// Fills the square of side `radius` beside an inside corner, toward `dir`
// (each ±1), less the quarter disc a curve of that radius leaves empty: the
// shape beside it turns the corner on that curve. Its curved edge fades over
// a pixel, like fill_rounded_rect's
@(private = "file")
fill_fillet :: proc(corner, dir: [2]f32, radius: f32, fc: sdl.FColor) {
	if radius < 1 do return

	clear := fc
	clear.a = 0
	centre := corner + dir * radius

	// The corner, then along the curve a solid point and a clear one per step
	verts: [1 + 2 * (CORNER_SEGMENTS + 1)]sdl.Vertex
	verts[0] = {position = sdl.FPoint(corner), color = fc}
	for s in 0 ..= CORNER_SEGMENTS {
		a := f32(s) / CORNER_SEGMENTS * (math.PI / 2)
		n := [2]f32{-dir.x * math.cos(a), -dir.y * math.sin(a)} // from the centre toward the corner
		p := centre + n * radius
		verts[1 + 2 * s] = {position = sdl.FPoint(p + n * 0.5), color = fc}
		verts[2 + 2 * s] = {position = sdl.FPoint(p - n * 0.5), color = clear}
	}

	// A fan triangle from the corner and two edge triangles per step
	indices: [9 * CORNER_SEGMENTS]i32
	for s in 0 ..< CORNER_SEGMENTS {
		solid, edge := i32(1 + 2 * s), i32(2 + 2 * s)
		next_solid, next_edge := solid + 2, edge + 2
		fan := []i32{0, solid, next_solid}
		ring := []i32{solid, edge, next_edge, solid, next_edge, next_solid}
		copy(indices[s * 9:], fan)
		copy(indices[s * 9 + 3:], ring)
	}

	_ = sdl.RenderGeometry(renderer, nil, &verts[0], len(verts), &indices[0], len(indices))
}


// A text caret at (x, y), h tall (pixels): a bar with rounded ends
draw_caret :: proc(x, y, h, scale: f32, c: clay.Color) {
	w := max(math.round(2 * scale), 2)
	inset := math.round(scale)
	fill_rounded_rect({x, y + inset, w, h - 2 * inset}, {w / 2, w / 2, w / 2, w / 2}, c)
}


draw_border :: proc(
	b: clay.BoundingBox,
	r: clay.CornerRadius,
	w: clay.BorderWidth,
	c: clay.Color,
	scale: f32,
) {
	left := f32(w.left) * scale
	right := f32(w.right) * scale
	top := f32(w.top) * scale
	bottom := f32(w.bottom) * scale
	x_end := b.x + b.width
	y_end := b.y + b.height

	// The straight sides, between the corners
	if left > 0 {
		length := b.height - r.topLeft - r.bottomLeft
		fill_rect(b.x, b.y + r.topLeft, left, length, c)
	}
	if right > 0 {
		length := b.height - r.topRight - r.bottomRight
		fill_rect(x_end - right, b.y + r.topRight, right, length, c)
	}
	if top > 0 {
		length := b.width - r.topLeft - r.topRight
		fill_rect(b.x + r.topLeft, b.y, length, top, c)
	}
	if bottom > 0 {
		length := b.width - r.bottomLeft - r.bottomRight
		fill_rect(b.x + r.bottomLeft, y_end - bottom, length, bottom, c)
	}

	// The rounded corners
	if r.topLeft > 0 {
		draw_arc(b.x + r.topLeft, b.y + r.topLeft, r.topLeft, top, math.PI, c)
	}
	if r.topRight > 0 {
		draw_arc(x_end - r.topRight, b.y + r.topRight, r.topRight, top, -math.PI / 2, c)
	}
	if r.bottomRight > 0 {
		draw_arc(x_end - r.bottomRight, y_end - r.bottomRight, r.bottomRight, bottom, 0, c)
	}
	if r.bottomLeft > 0 {
		draw_arc(b.x + r.bottomLeft, y_end - r.bottomLeft, r.bottomLeft, bottom, math.PI / 2, c)
	}
}


// Quarter-circle ring of the given thickness, starting at angle `start` (radians,
// clockwise in screen space), its edges fading out over a pixel
@(private = "file")
draw_arc :: proc(cx, cy, radius, thickness, start: f32, c: clay.Color) {
	if thickness <= 0 do return

	flush_text()

	inner := max(radius - thickness, 0)
	fc := to_fcolor(c)
	clear := fc
	clear.a = 0

	// Per step: outside the ring, its outer edge, its inner edge, inside it
	radii := [4]f32{radius + 0.5, radius - 0.5, inner + 0.5, max(inner - 0.5, 0)}
	colors := [4]sdl.FColor{clear, fc, fc, clear}
	if thickness < 1 {
		middle := radius - thickness / 2
		radii[1] = middle
		radii[2] = middle
	}

	verts: [4 * (CORNER_SEGMENTS + 1)]sdl.Vertex
	for s in 0 ..= CORNER_SEGMENTS {
		a := start + f32(s) / CORNER_SEGMENTS * (math.PI / 2)
		ca, sa := math.cos(a), math.sin(a)
		for k in 0 ..< 4 {
			verts[s * 4 + k] = {
				position = {cx + ca * radii[k], cy + sa * radii[k]},
				color    = colors[k],
			}
		}
	}

	// Two triangles between each pair of neighboring circles, per step
	indices: [18 * CORNER_SEGMENTS]i32
	n := 0
	for s in 0 ..< CORNER_SEGMENTS {
		for k in 0 ..< 3 {
			a, b := i32(s * 4 + k), i32((s + 1) * 4 + k)
			copy(indices[n:], []i32{a, a + 1, b, a + 1, b + 1, b})
			n += 6
		}
	}

	_ = sdl.RenderGeometry(renderer, nil, &verts[0], len(verts), &indices[0], len(indices))
}


// Icons are Lucide glyphs, centred in the element's bounds
draw_icon :: proc(data: Icon_Data, b: clay.BoundingBox) {
	font := text_get_font(&text_system, .Icons, data.size)
	if font == nil do return
	text := text_get(&text_system, font, ICON_GLYPHS[data.kind])
	if text == nil do return

	// Lucide draws each icon in the em square (baseline to ascent), so centre
	// on the ascent rather than the text height, which includes the line gap
	w, h: i32
	_ = ttf.GetTextSize(text, &w, &h)
	em := f32(ttf.GetFontAscent(font))
	x := math.round(b.x + (b.width - f32(w)) / 2)
	y := math.round(b.y + (b.height - em) / 2)
	draw_text(text, x, y, data.color)
}
