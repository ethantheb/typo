package editor

import "core:math"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"

// Translates Clay render commands into SDL_Renderer / SDL_ttf calls.
// Clay coordinates are logical; everything is multiplied by `scale` to get pixels.

CORNER_SEGMENTS :: 8

// Clip rectangles nest (a clipped text field inside a scrolling list): each one
// is intersected with the one around it, and ending it restores the outer one.
@(private = "file")
clip_stack: [32]sdl.Rect
@(private = "file")
clip_depth: int

push_clip :: proc(renderer: ^sdl.Renderer, r: sdl.Rect) {
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

pop_clip :: proc(renderer: ^sdl.Renderer) {
	clip_depth = max(clip_depth - 1, 0)
	if clip_depth == 0 {
		_ = sdl.SetRenderClipRect(renderer, nil)
	} else {
		_ = sdl.SetRenderClipRect(renderer, &clip_stack[min(clip_depth, len(clip_stack)) - 1])
	}
}

// Clay overlay colors (used to fade elements in): everything drawn inside one
// is mixed toward the overlay's color by its alpha. They nest.
@(private = "file")
overlay_stack: [16]clay.Color
@(private = "file")
overlay_depth: int

@(private = "file")
apply_overlays :: proc(c: clay.Color) -> clay.Color {
	c := c
	for o in overlay_stack[:min(overlay_depth, len(overlay_stack))] {
		t := o.a / 255
		c.rgb += (o.rgb - c.rgb) * t
	}
	return c
}

render_clay_commands :: proc(renderer: ^sdl.Renderer, commands: ^clay.ClayArray(clay.RenderCommand), scale: f32) {
	clip_depth = 0
	overlay_depth = 0
	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i)
		b := scale_box(cmd.boundingBox, scale)

		#partial switch cmd.commandType {
		case .Rectangle:
			data := cmd.renderData.rectangle
			fill_rounded_rect(renderer, b, scale_radius(data.cornerRadius, scale), data.backgroundColor)

		case .Text:
			data := cmd.renderData.text
			s := string(data.stringContents.chars[:data.stringContents.length])
			font := text_get_font(&g.text, Font_Id(data.fontId), data.fontSize)
			if font == nil do continue
			draw_text(text_get(&g.text, font, s), math.round(b.x), math.round(b.y), data.textColor)

		case .Border:
			data := cmd.renderData.border
			draw_border(renderer, b, scale_radius(data.cornerRadius, scale), data.width, data.color, scale)

		case .ScissorStart:
			push_clip(renderer, {i32(math.round(b.x)), i32(math.round(b.y)), i32(math.round(b.width)), i32(math.round(b.height))})

		case .ScissorEnd:
			pop_clip(renderer)

		case .OverlayColorStart:
			if overlay_depth < len(overlay_stack) do overlay_stack[overlay_depth] = cmd.renderData.overlayColor.color
			overlay_depth += 1

		case .OverlayColorEnd:
			overlay_depth = max(overlay_depth - 1, 0)

		case .Custom:
			data := cmd.renderData.custom
			if data.customData == nil do continue
			switch c in (^Custom_Data)(data.customData)^ {
			case Icon_Data:
				draw_icon(renderer, c, b)
			case ^Editor:
				draw_editor(renderer, c, b, scale)
			case ^Terminal:
				draw_terminal(renderer, c, b, scale)
			}

		case .Image:
			texture := (^sdl.Texture)(cmd.renderData.image.imageData)
			if texture == nil do continue
			dst := sdl.FRect{b.x, b.y, b.width, b.height}
			_ = sdl.RenderTexture(renderer, texture, nil, &dst)
		}
	}
}

@(private = "file")
scale_box :: proc(b: clay.BoundingBox, s: f32) -> clay.BoundingBox {
	return {b.x * s, b.y * s, b.width * s, b.height * s}
}

@(private = "file")
scale_radius :: proc(r: clay.CornerRadius, s: f32) -> clay.CornerRadius {
	return {r.topLeft * s, r.topRight * s, r.bottomLeft * s, r.bottomRight * s}
}

@(private = "file")
to_fcolor :: proc(c: clay.Color) -> sdl.FColor {
	c := apply_overlays(c)
	return {c.r / 255, c.g / 255, c.b / 255, c.a / 255}
}

@(private = "file")
set_color :: proc(renderer: ^sdl.Renderer, c: clay.Color) {
	c := apply_overlays(c)
	_ = sdl.SetRenderDrawColor(renderer, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
}

// Clips to a custom element's bounds (pixels), rounded outward.
push_clip_box :: proc(renderer: ^sdl.Renderer, b: clay.BoundingBox) {
	push_clip(renderer, {i32(b.x), i32(b.y), i32(math.ceil(b.width)), i32(math.ceil(b.height))})
}

draw_text :: proc(text: ^ttf.Text, x, y: f32, c: clay.Color) {
	if text == nil do return
	c := apply_overlays(c)
	_ = ttf.SetTextColor(text, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
	_ = ttf.DrawRendererText(text, x, y)
}

fill_rect :: proc(renderer: ^sdl.Renderer, x, y, w, h: f32, c: clay.Color) {
	if w <= 0 || h <= 0 do return
	set_color(renderer, c)
	r := sdl.FRect{x, y, w, h}
	_ = sdl.RenderFillRect(renderer, &r)
}

// Rounded rectangles are convex, so a triangle fan from the centre covers them,
// inset half a pixel; a ring fading out to half a pixel outside smooths the edge.
fill_rounded_rect :: proc(renderer: ^sdl.Renderer, b: clay.BoundingBox, r: clay.CornerRadius, c: clay.Color) {
	if r.topLeft <= 0 && r.topRight <= 0 && r.bottomLeft <= 0 && r.bottomRight <= 0 {
		fill_rect(renderer, b.x, b.y, b.width, b.height, c)
		return
	}

	max_r := min(b.width, b.height) / 2
	corners := [4]struct {
		cx, cy, radius, start: f32,
	} {
		{b.x + b.width - min(r.topRight, max_r), b.y + min(r.topRight, max_r), min(r.topRight, max_r), -math.PI / 2},
		{b.x + b.width - min(r.bottomRight, max_r), b.y + b.height - min(r.bottomRight, max_r), min(r.bottomRight, max_r), 0},
		{b.x + min(r.bottomLeft, max_r), b.y + b.height - min(r.bottomLeft, max_r), min(r.bottomLeft, max_r), math.PI / 2},
		{b.x + min(r.topLeft, max_r), b.y + min(r.topLeft, max_r), min(r.topLeft, max_r), math.PI},
	}

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

	indices: [9 * RING]i32
	for i in 0 ..< RING {
		j := (i + 1) % RING
		in_i, in_j := i32(1 + i), i32(1 + j)
		out_i, out_j := in_i + RING, in_j + RING
		copy(indices[i * 9:], []i32{0, in_i, in_j, in_i, out_i, out_j, in_i, out_j, in_j})
	}
	_ = sdl.RenderGeometry(renderer, nil, &verts[0], len(verts), &indices[0], len(indices))
}

@(private = "file")
draw_border :: proc(renderer: ^sdl.Renderer, b: clay.BoundingBox, r: clay.CornerRadius, w: clay.BorderWidth, c: clay.Color, scale: f32) {
	left, right, top, bottom := f32(w.left) * scale, f32(w.right) * scale, f32(w.top) * scale, f32(w.bottom) * scale

	if left > 0 do fill_rect(renderer, b.x, b.y + r.topLeft, left, b.height - r.topLeft - r.bottomLeft, c)
	if right > 0 do fill_rect(renderer, b.x + b.width - right, b.y + r.topRight, right, b.height - r.topRight - r.bottomRight, c)
	if top > 0 do fill_rect(renderer, b.x + r.topLeft, b.y, b.width - r.topLeft - r.topRight, top, c)
	if bottom > 0 do fill_rect(renderer, b.x + r.bottomLeft, b.y + b.height - bottom, b.width - r.bottomLeft - r.bottomRight, bottom, c)

	if r.topLeft > 0 do draw_arc(renderer, b.x + r.topLeft, b.y + r.topLeft, r.topLeft, top, math.PI, c)
	if r.topRight > 0 do draw_arc(renderer, b.x + b.width - r.topRight, b.y + r.topRight, r.topRight, top, -math.PI / 2, c)
	if r.bottomRight > 0 do draw_arc(renderer, b.x + b.width - r.bottomRight, b.y + b.height - r.bottomRight, r.bottomRight, bottom, 0, c)
	if r.bottomLeft > 0 do draw_arc(renderer, b.x + r.bottomLeft, b.y + b.height - r.bottomLeft, r.bottomLeft, bottom, math.PI / 2, c)
}

// Quarter-circle ring of the given thickness, starting at angle `start` (radians,
// clockwise in screen space), its edges fading out over a pixel.
@(private = "file")
draw_arc :: proc(renderer: ^sdl.Renderer, cx, cy, radius, thickness, start: f32, c: clay.Color) {
	if thickness <= 0 do return
	inner := max(radius - thickness, 0)
	fc := to_fcolor(c)
	clear := fc
	clear.a = 0
	// Per step: outside the ring, its outer edge, its inner edge, inside it.
	radii := [4]f32{radius + 0.5, radius - 0.5, inner + 0.5, max(inner - 0.5, 0)}
	colors := [4]sdl.FColor{clear, fc, fc, clear}
	if thickness < 1 do radii[1], radii[2] = radius - thickness / 2, radius - thickness / 2

	verts: [4 * (CORNER_SEGMENTS + 1)]sdl.Vertex
	for s in 0 ..= CORNER_SEGMENTS {
		a := start + f32(s) / CORNER_SEGMENTS * (math.PI / 2)
		ca, sa := math.cos(a), math.sin(a)
		for k in 0 ..< 4 do verts[s * 4 + k] = {position = {cx + ca * radii[k], cy + sa * radii[k]}, color = colors[k]}
	}

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

// Icons are Lucide glyphs, centred in the element's bounds.
draw_icon :: proc(renderer: ^sdl.Renderer, data: Icon_Data, b: clay.BoundingBox) {
	font := text_get_font(&g.text, .Icons, data.size)
	if font == nil do return
	text := text_get(&g.text, font, ICON_GLYPHS[data.kind])
	if text == nil do return
	// Lucide draws each icon in the em square (baseline to ascent), so centre
	// on the ascent rather than the text height, which includes the line gap.
	w, h: i32
	_ = ttf.GetTextSize(text, &w, &h)
	em := f32(ttf.GetFontAscent(font))
	draw_text(text, math.round(b.x + (b.width - f32(w)) / 2), math.round(b.y + (b.height - em) / 2), data.color)
}
