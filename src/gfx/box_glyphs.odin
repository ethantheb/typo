package gfx

import "core:math"
import "core:unicode/utf8"

import clay "../../vendor/clay-odin"
import sdl "../../vendor/sdl3"
import ttf "../../vendor/sdl3/ttf"

// Box drawing, block elements, Powerline separators and Symbols for Legacy
// Computing, drawn as shapes that fill the cell exactly instead of from the
// font, so they join across cells and rows whatever the font's advance and the
// line height.
//
// The shapes (BOX_GLYPHS, box_glyphs_table.odin) and the way they snap to pixels
// are Windows Terminal's built-in glyphs: src/renderer/atlas/BuiltinGlyphs.cpp in
// github.com/microsoft/terminal, Copyright (c) Microsoft Corporation, MIT
// license. Shades are drawn as solid color at their coverage rather than as
// Windows Terminal's dot patterns.
//
// A glyph is rasterized once per cell size into that size's atlas texture, and
// a Box_Batch draws the cells that use one atlas in a single call


BOX_DRAWING_FIRST :: 0x2500  // box drawing, then block elements
BOX_DRAWING_COUNT :: 0xA0
POWERLINE_FIRST   :: 0xE0B0
POWERLINE_COUNT   :: 0x10
LEGACY_FIRST      :: 0x1FB00 // Symbols for Legacy Computing
LEGACY_COUNT      :: 0x95
BOX_GLYPH_COUNT   :: BOX_DRAWING_COUNT + POWERLINE_COUNT + LEGACY_COUNT

// Atlases kept at once (one per cell size and line width); the one used least
// recently goes first
BOX_ATLAS_MAX     :: 8
BOX_ATLAS_COLUMNS :: 32
BOX_ATLAS_ROWS    :: (BOX_GLYPH_COUNT + BOX_ATLAS_COLUMNS - 1) / BOX_ATLAS_COLUMNS

Box_Shape :: enum u8 {
	Fill_25,   // rectangle, a quarter covered
	Fill_50,    // rectangle, half covered
	Fill_75,    // rectangle, three quarters covered
	Fill,       // rectangle
	Invert_50,  // rectangle, half covered (an inverse shade)
	Light,      // line, a line width wide
	Heavy,      // line, two line widths wide
	Rect,       // rectangle outline
	Round_Rect, // rectangle outline with rounded corners
	Ellipse,    // filled ellipse: centre (x0, y0), radii (x1, y1)
	Ring,       // ellipse outline
	Path,       // filled polygon through the glyph's points
	Polyline,   // line through the glyph's points
}

// A place in the cell: a fraction of its width or height plus a number of line
// widths (BOX_POS). In a Path or Polyline, an x of Min leaves the point out
Box_Pos :: enum u8 {
	Min,
	Max,
	P0_1,
	P0_1_Add_0_5,
	P1_1,
	P1_1_Sub_0_5,
	P1_2,
	P1_2_Sub_0_5,
	P1_2_Add_0_5,
	P1_2_Sub_1,
	P1_2_Add_1,
	P1_4,
	P3_4,
	P2_6,
	P3_6,
	P5_6,
	P1_8,
	P3_8,
	P5_8,
	P7_8,
	P2_9,
	P3_9,
	P5_9,
	P6_9,
	P8_9,
	P2_12,
	P3_12,
	P5_12,
	P6_12,
	P8_12,
	P9_12,
	P11_12,
}

@(private = "file")
BOX_POS := [Box_Pos][2]f32 {
	.Min          = {-0.5, 0},
	.Max          = {1.5, 0},
	.P0_1         = {0, 0},
	.P0_1_Add_0_5 = {0, 0.5},
	.P1_1         = {1, 0},
	.P1_1_Sub_0_5 = {1, -0.5},
	.P1_2         = {1.0 / 2, 0},
	.P1_2_Sub_0_5 = {1.0 / 2, -0.5},
	.P1_2_Add_0_5 = {1.0 / 2, 0.5},
	.P1_2_Sub_1   = {1.0 / 2, -1},
	.P1_2_Add_1   = {1.0 / 2, 1},
	.P1_4         = {1.0 / 4, 0},
	.P3_4         = {3.0 / 4, 0},
	.P2_6         = {2.0 / 6, 0},
	.P3_6         = {3.0 / 6, 0},
	.P5_6         = {5.0 / 6, 0},
	.P1_8         = {1.0 / 8, 0},
	.P3_8         = {3.0 / 8, 0},
	.P5_8         = {5.0 / 8, 0},
	.P7_8         = {7.0 / 8, 0},
	.P2_9         = {2.0 / 9, 0},
	.P3_9         = {3.0 / 9, 0},
	.P5_9         = {5.0 / 9, 0},
	.P6_9         = {6.0 / 9, 0},
	.P8_9         = {8.0 / 9, 0},
	.P2_12        = {2.0 / 12, 0},
	.P3_12        = {3.0 / 12, 0},
	.P5_12        = {5.0 / 12, 0},
	.P6_12        = {6.0 / 12, 0},
	.P8_12        = {8.0 / 12, 0},
	.P9_12        = {9.0 / 12, 0},
	.P11_12       = {11.0 / 12, 0},
}

// The most shapes a glyph has
BOX_GLYPH_OPS :: 4

// One shape of a glyph, from (x0, y0) to (x1, y1)
Box_Op :: struct {
	shape:          Box_Shape,
	x0, y0, x1, y1: Box_Pos,
}

// The glyphs at one cell size and line width: a slot per glyph, white with the
// coverage as alpha (so vertex colors tint it), filled when first drawn
@(private = "file")
Box_Atlas :: struct {
	texture:   ^sdl.Texture,
	w, h:      int, // the cell, in pixels
	line:      f32,
	ready:     [BOX_GLYPH_COUNT]bool,
	last_used: u64, // text_system.frame
}

@(private = "file")
box_atlases: [dynamic]^Box_Atlas

// Glyphs to draw, in the temp allocator: their quads, per atlas
Box_Batch :: struct {
	parts: [dynamic]Box_Part,
}

@(private = "file")
Box_Part :: struct {
	atlas:   ^Box_Atlas,
	verts:   [dynamic]sdl.Vertex,
	indices: [dynamic]i32,
}


// --- Which characters --------------------------------------------------------------

// The character's glyph in BOX_GLYPHS, or -1 when it isn't drawn as shapes
box_glyph_slot :: proc(r: rune) -> int {
	if r < BOX_DRAWING_FIRST do return -1

	slot := -1
	switch {
	case r < BOX_DRAWING_FIRST + BOX_DRAWING_COUNT:
		slot = int(r - BOX_DRAWING_FIRST)
	case r >= POWERLINE_FIRST && r < POWERLINE_FIRST + POWERLINE_COUNT:
		slot = BOX_DRAWING_COUNT + int(r - POWERLINE_FIRST)
	case r >= LEGACY_FIRST && r < LEGACY_FIRST + LEGACY_COUNT:
		slot = BOX_DRAWING_COUNT + POWERLINE_COUNT + int(r - LEGACY_FIRST)
	}

	// Unassigned characters in the ranges have no shapes
	if slot < 0 || len(BOX_GLYPHS[slot]) == 0 {
		return -1
	}
	return slot
}


// Whether a character is drawn as shapes filling its cell rather than from the
// font
is_box_glyph :: proc(r: rune) -> bool {
	return box_glyph_slot(r) >= 0
}


// The character `s` is, when it is a single character drawn as shapes
box_glyph_in :: proc(s: string) -> (rune, bool) {
	r, size := utf8.decode_rune_in_string(s)
	if size == 0 || size != len(s) || !is_box_glyph(r) {
		return 0, false
	}
	return r, true
}


// The light line width for a font (`id`, opened as `font`), in whole pixels: as
// thick as the font's own light horizontal line (U+2500), else a sixth of the
// cell's width, as Windows Terminal picks it. A fallback font's line isn't
// used: whether one is attached yet would change the width mid-session
box_line_width :: proc(id: Font_Id, font: ^ttf.Font, cell_w: f32) -> f32 {
	own := font_has_own_glyph(&text_system, id, 0x2500)
	if font != nil && own {
		minx, maxx, miny, maxy, advance: i32
		has := ttf.GetGlyphMetrics(font, 0x2500, &minx, &maxx, &miny, &maxy, &advance)
		thick := f32(maxy - miny)
		if has && thick >= 1 && thick < cell_w / 2 {
			return thick
		}
	}
	return max(math.round(cell_w / 6), 1)
}


// --- Drawing -----------------------------------------------------------------------

// Adds a glyph filling the cell at (x, y), w by h (whole pixels), in color c,
// with light lines `line` pixels wide (box_line_width)
box_batch_add :: proc(batch: ^Box_Batch, r: rune, x, y, w, h, line: f32, c: clay.Color) {
	slot := box_glyph_slot(r)
	if slot < 0 || w < 1 || h < 1 {
		return
	}

	atlas := box_atlas(int(w), int(h), line)
	if atlas == nil do return
	if !atlas.ready[slot] do box_atlas_fill(atlas, slot)

	// The glyph's slot in the atlas, in texture coordinates
	tex_w := f32(atlas.w * BOX_ATLAS_COLUMNS)
	tex_h := f32(atlas.h * BOX_ATLAS_ROWS)
	u0 := f32(slot % BOX_ATLAS_COLUMNS * atlas.w) / tex_w
	v0 := f32(slot / BOX_ATLAS_COLUMNS * atlas.h) / tex_h
	u1 := u0 + f32(atlas.w) / tex_w
	v1 := v0 + f32(atlas.h) / tex_h

	// A quad over the cell
	part := box_part(batch, atlas)
	color := to_fcolor(c)
	first := i32(len(part.verts))
	append(
		&part.verts,
		sdl.Vertex{{x, y}, color, {u0, v0}},
		sdl.Vertex{{x + w, y}, color, {u1, v0}},
		sdl.Vertex{{x + w, y + h}, color, {u1, v1}},
		sdl.Vertex{{x, y + h}, color, {u0, v1}},
	)
	append(&part.indices, first, first + 1, first + 2, first, first + 2, first + 3)
}


// Draws the glyphs added since the last call: one draw call per atlas
box_batch_draw :: proc(batch: ^Box_Batch) {
	if len(batch.parts) == 0 do return

	flush_text()
	for part in batch.parts {
		_ = sdl.RenderGeometry(
			renderer,
			part.atlas.texture,
			raw_data(part.verts),
			i32(len(part.verts)),
			raw_data(part.indices),
			i32(len(part.indices)),
		)
	}
	clear(&batch.parts)
}


// Draws one glyph filling a cell
draw_box_glyph :: proc(r: rune, x, y, w, h, line: f32, c: clay.Color) {
	batch: Box_Batch
	box_batch_add(&batch, r, x, y, w, h, line, c)
	box_batch_draw(&batch)
}


box_glyphs_destroy :: proc() {
	for atlas in box_atlases {
		sdl.DestroyTexture(atlas.texture)
		free(atlas)
	}
	delete(box_atlases)
	box_atlases = nil
}


// The batch's quads for an atlas, started if needed
@(private = "file")
box_part :: proc(batch: ^Box_Batch, atlas: ^Box_Atlas) -> ^Box_Part {
	for &part in batch.parts {
		if part.atlas == atlas do return &part
	}

	if batch.parts == nil {
		batch.parts = make([dynamic]Box_Part, context.temp_allocator)
	}
	part := Box_Part {
		atlas   = atlas,
		verts   = make([dynamic]sdl.Vertex, 0, 64, context.temp_allocator),
		indices = make([dynamic]i32, 0, 96, context.temp_allocator),
	}
	append(&batch.parts, part)
	return &batch.parts[len(batch.parts) - 1]
}


// The atlas for a cell size and line width, made if needed
@(private = "file")
box_atlas :: proc(w, h: int, line: f32) -> ^Box_Atlas {
	frame := text_system.frame
	for atlas in box_atlases {
		if atlas.w == w && atlas.h == h && atlas.line == line {
			atlas.last_used = frame
			return atlas
		}
	}

	// Make room: the least recently used goes, unless a batch may hold it
	if len(box_atlases) >= BOX_ATLAS_MAX {
		oldest := 0
		for atlas, i in box_atlases {
			if atlas.last_used < box_atlases[oldest].last_used do oldest = i
		}
		if box_atlases[oldest].last_used < frame {
			sdl.DestroyTexture(box_atlases[oldest].texture)
			free(box_atlases[oldest])
			unordered_remove(&box_atlases, oldest)
		}
	}

	tex_w := i32(w * BOX_ATLAS_COLUMNS)
	tex_h := i32(h * BOX_ATLAS_ROWS)
	texture := sdl.CreateTexture(renderer, .RGBA32, .STATIC, tex_w, tex_h)
	if texture == nil do return nil
	_ = sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
	_ = sdl.SetTextureScaleMode(texture, .NEAREST)

	atlas := new(Box_Atlas)
	atlas^ = {
		texture   = texture,
		w         = w,
		h         = h,
		line      = line,
		last_used = frame,
	}
	append(&box_atlases, atlas)
	return atlas
}


// Rasterizes a glyph into its slot of the atlas
@(private = "file")
box_atlas_fill :: proc(atlas: ^Box_Atlas, slot: int) {
	w, h := atlas.w, atlas.h
	mask := make([]u8, w * h, context.temp_allocator)
	box_glyph_raster(slot, w, h, atlas.line, mask)

	// White, with the coverage as alpha, so the vertex color tints it
	pixels := make([][4]u8, w * h, context.temp_allocator)
	for m, i in mask do pixels[i] = {255, 255, 255, m}

	rect := sdl.Rect {
		i32(slot % BOX_ATLAS_COLUMNS * w),
		i32(slot / BOX_ATLAS_COLUMNS * h),
		i32(w),
		i32(h),
	}
	_ = sdl.UpdateTexture(atlas.texture, &rect, raw_data(pixels), i32(w * 4))
	atlas.ready[slot] = true
}


// --- Rasterizing -------------------------------------------------------------------

// What box_shape_distance needs of a shape, in the cell's pixels
@(private = "file")
Box_Paint :: struct {
	shape:  Box_Shape,
	a, b:   [2]f32,   // from and to, snapped to pixels (an ellipse's centre and radii)
	half:   f32,      // half the line width
	radius: f32,      // of rounded corners
	points: [][2]f32, // a Path's or Polyline's
}


// Rasterizes a glyph's coverage into `mask` (w * h bytes, row by row): its
// shapes in a cell w by h pixels, light lines `line` pixels wide
box_glyph_raster :: proc(slot: int, w, h: int, line: f32, mask: []u8) {
	cover := make([]f32, w * h, context.temp_allocator)
	cell := [2]f32{f32(w), f32(h)}
	ops := BOX_GLYPHS[slot]

	// Rounded corners, sized as Windows Terminal sizes them
	radius := min(line * 5, min(cell.x, cell.y) / 2)

	// Each shape, except a path's points, which are drawn together after
	points: [2 * BOX_GLYPH_OPS][2]f32
	point_count := 0
	for op in ops {
		width := op.shape == .Heavy ? line * 2 : line
		paint := Box_Paint {
			shape  = op.shape,
			half   = width / 2,
			radius = radius,
		}

		raw_a := [2]f32{box_place(op.x0, cell.x, line), box_place(op.y0, cell.y, line)}
		raw_b := [2]f32{box_place(op.x1, cell.x, line), box_place(op.y1, cell.y, line)}
		paint.a, paint.b = box_snap(op.shape, raw_a, raw_b, paint.half)

		#partial switch op.shape {
		case .Path, .Polyline:
			if op.x0 != .Min {
				points[point_count] = paint.a
				point_count += 1
			}
			if op.x1 != .Min {
				points[point_count] = paint.b
				point_count += 1
			}

		case .Ellipse, .Ring:
			paint.a, paint.b = raw_a, raw_b
			box_paint(cover, w, h, paint)

		case .Round_Rect:
			// The arc ends inside the cell, meeting the lines beside it straight
			paint.radius = min(radius, arc_room(paint.a, paint.b, cell))
			box_paint(cover, w, h, paint)

		case:
			box_paint(cover, w, h, paint)
		}
	}

	// The path through the points, in the first shape's way
	if point_count > 0 && len(ops) > 0 {
		paint := Box_Paint {
			shape  = ops[0].shape,
			half   = line / 2,
			points = points[:point_count],
		}
		box_paint(cover, w, h, paint)
	}

	for c, i in cover do mask[i] = u8(math.round(clamp(c, 0, 1) * 255))
}


// How far a rounded corner may bend: from the outline's side inside the cell to
// the middle of the last pixel before the edge its other side lies past, on
// each axis, so the pixels at the edge are those of a straight line
@(private = "file")
arc_room :: proc(a, b, cell: [2]f32) -> f32 {
	room := max(cell.x, cell.y)
	for axis in 0 ..< 2 {
		a_inside := a[axis] >= 0 && a[axis] <= cell[axis]
		inside := a_inside ? a[axis] : b[axis]
		outside := a_inside ? b[axis] : a[axis]
		room = min(room, outside > inside ? cell[axis] - inside : inside)
	}
	return max(room - 0.5, 0)
}


// A place in pixels along a side `size` long
@(private = "file")
box_place :: proc(pos: Box_Pos, size, line: f32) -> f32 {
	p := BOX_POS[pos]
	return p[0] * size + p[1] * line
}


// A shape's ends snapped to pixels. Lines and outlines are centred on their
// path, so it is their edges that land on whole pixels; every cell of a size
// gets the same pixels, and lines meet across cells
@(private = "file")
box_snap :: proc(shape: Box_Shape, a, b: [2]f32, half: f32) -> (snapped_a, snapped_b: [2]f32) {
	hollow := shape == .Rect || shape == .Round_Rect
	is_line := shape == .Light || shape == .Heavy

	offset: [2]f32
	for axis in 0 ..< 2 {
		along_axis := is_line && a[axis] == b[axis]
		offset[axis] = hollow || along_axis ? half : 0
	}

	for axis in 0 ..< 2 {
		snapped_a[axis] = math.round(a[axis] - offset[axis]) + offset[axis]
		snapped_b[axis] = math.round(b[axis] + offset[axis]) - offset[axis]
	}
	return
}


// Composites a shape over the coverage: each pixel covered as far as its centre
// is inside the shape's edge, smoothed over one pixel
@(private = "file")
box_paint :: proc(cover: []f32, w, h: int, paint: Box_Paint) {
	alpha: f32 = 1
	#partial switch paint.shape {
	case .Fill_25:            alpha = 0.25
	case .Fill_50, .Invert_50: alpha = 0.5
	case .Fill_75:            alpha = 0.75
	}

	for y in 0 ..< h {
		for x in 0 ..< w {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			inside := clamp(0.5 - box_shape_distance(paint, p), 0, 1) * alpha
			if inside <= 0 do continue

			c := &cover[y * w + x]
			c^ = inside + c^ * (1 - inside)
		}
	}
}


// The signed distance from p to a shape's edge: negative inside
@(private = "file")
box_shape_distance :: proc(paint: Box_Paint, p: [2]f32) -> f32 {
	a, b := paint.a, paint.b
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)}
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)}

	switch paint.shape {
	case .Fill_25, .Fill_50, .Fill_75, .Fill, .Invert_50:
		return box_distance(p, lo, hi, 0)
	case .Light, .Heavy:
		return segment_distance(p, a, b, paint.half)
	case .Rect:
		return abs(box_distance(p, lo, hi, 0)) - paint.half
	case .Round_Rect:
		return abs(box_distance(p, lo, hi, paint.radius)) - paint.half
	case .Ellipse:
		return ellipse_distance(p - a, b)
	case .Ring:
		return abs(ellipse_distance(p - a, b)) - paint.half
	case .Path:
		return polygon_distance(p, paint.points)
	case .Polyline:
		d: f32 = math.F32_MAX
		for i in 1 ..< len(paint.points) {
			d = min(d, line_distance(p, paint.points[i - 1], paint.points[i]))
		}
		return d - paint.half
	}
	return math.F32_MAX
}


// To the edge of a box from lo to hi with corners of the given radius
@(private = "file")
box_distance :: proc(p, lo, hi: [2]f32, radius: f32) -> f32 {
	centre := (lo + hi) / 2
	q := [2]f32{abs(p.x - centre.x), abs(p.y - centre.y)} - ((hi - lo) / 2 - radius)
	outside := [2]f32{max(q.x, 0), max(q.y, 0)}
	return math.sqrt(outside.x * outside.x + outside.y * outside.y) +
	       min(max(q.x, q.y), 0) -
	       radius
}


// To the edge of a line from a to b, `half` wide on each side, with flat ends
@(private = "file")
segment_distance :: proc(p, a, b: [2]f32, half: f32) -> f32 {
	d := b - a
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length <= 0 do return math.F32_MAX

	dir := d / length
	rel := p - a
	along := rel.x * dir.x + rel.y * dir.y
	across := rel.x * dir.y - rel.y * dir.x

	// A box around the line, in its own frame
	q := [2]f32{abs(along - length / 2) - length / 2, abs(across) - half}
	outside := [2]f32{max(q.x, 0), max(q.y, 0)}
	return math.sqrt(outside.x * outside.x + outside.y * outside.y) + min(max(q.x, q.y), 0)
}


// To the nearest point of the line from a to b
@(private = "file")
line_distance :: proc(p, a, b: [2]f32) -> f32 {
	d := b - a
	rel := p - a
	t := clamp((rel.x * d.x + rel.y * d.y) / max(d.x * d.x + d.y * d.y, 1e-6), 0, 1)
	off := rel - d * t
	return math.sqrt(off.x * off.x + off.y * off.y)
}


// To the edge of an ellipse around the origin, approximately (Inigo Quilez's
// estimate, close enough over the pixel the edge is smoothed across)
@(private = "file")
ellipse_distance :: proc(p, radii: [2]f32) -> f32 {
	if radii.x <= 0 || radii.y <= 0 {
		return math.F32_MAX
	}

	scaled := p / radii
	k0 := math.sqrt(scaled.x * scaled.x + scaled.y * scaled.y)
	grad := p / (radii * radii)
	k1 := math.sqrt(grad.x * grad.x + grad.y * grad.y)
	if k1 <= 0 do return -min(radii.x, radii.y)
	return k0 * (k0 - 1) / k1
}


// To the edge of a polygon, negative inside (the even-odd rule)
@(private = "file")
polygon_distance :: proc(p: [2]f32, points: [][2]f32) -> f32 {
	if len(points) < 3 do return math.F32_MAX

	nearest: f32 = math.F32_MAX
	inside := false
	j := len(points) - 1
	for i in 0 ..< len(points) {
		nearest = min(nearest, line_distance(p, points[j], points[i]))

		// Crossings of a ray to the right
		pi, pj := points[i], points[j]
		if (pi.y > p.y) != (pj.y > p.y) {
			x := pi.x + (p.y - pi.y) / (pj.y - pi.y) * (pj.x - pi.x)
			if p.x < x do inside = !inside
		}
		j = i
	}
	return inside ? -nearest : nearest
}
