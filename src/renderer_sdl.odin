package editor

import "core:math"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Translates Clay render commands into SDL_Renderer / SDL_ttf calls.
// Clay coordinates are logical; everything is multiplied by `scale` to get pixels.

CORNER_SEGMENTS :: 8

render_clay_commands :: proc(renderer: ^sdl.Renderer, commands: ^clay.ClayArray(clay.RenderCommand), scale: f32) {
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
			text := text_get(&g.text, font, s)
			if text == nil do continue
			c := data.textColor
			_ = ttf.SetTextColor(text, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
			_ = ttf.DrawRendererText(text, math.round(b.x), math.round(b.y))

		case .Border:
			data := cmd.renderData.border
			draw_border(renderer, b, scale_radius(data.cornerRadius, scale), data.width, data.color, scale)

		case .ScissorStart:
			r := sdl.Rect {
				i32(math.round(b.x)),
				i32(math.round(b.y)),
				i32(math.round(b.width)),
				i32(math.round(b.height)),
			}
			_ = sdl.SetRenderClipRect(renderer, &r)

		case .ScissorEnd:
			_ = sdl.SetRenderClipRect(renderer, nil)

		case .Custom:
			data := cmd.renderData.custom
			if data.customData == nil do continue
			switch c in (^Custom_Data)(data.customData)^ {
			case Icon_Data:
				draw_icon(renderer, c, b)
			case ^Editor:
				draw_editor(renderer, c, b, scale)
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
	return {c.r / 255, c.g / 255, c.b / 255, c.a / 255}
}

@(private = "file")
set_color :: proc(renderer: ^sdl.Renderer, c: clay.Color) {
	_ = sdl.SetRenderDrawColor(renderer, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
}

@(private = "file")
fill_rect :: proc(renderer: ^sdl.Renderer, x, y, w, h: f32, c: clay.Color) {
	if w <= 0 || h <= 0 do return
	set_color(renderer, c)
	r := sdl.FRect{x, y, w, h}
	_ = sdl.RenderFillRect(renderer, &r)
}

// Rounded rectangles are convex, so a triangle fan from the centre covers them.
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

	fc := to_fcolor(c)
	verts: [1 + 4 * (CORNER_SEGMENTS + 1)]sdl.Vertex
	verts[0] = {position = {b.x + b.width / 2, b.y + b.height / 2}, color = fc}
	n := 1
	for corner in corners {
		for s in 0 ..= CORNER_SEGMENTS {
			a := corner.start + f32(s) / CORNER_SEGMENTS * (math.PI / 2)
			verts[n] = {position = {corner.cx + math.cos(a) * corner.radius, corner.cy + math.sin(a) * corner.radius}, color = fc}
			n += 1
		}
	}

	ring := n - 1
	indices: [3 * (4 * (CORNER_SEGMENTS + 1))]i32
	for i in 0 ..< ring {
		indices[i * 3 + 0] = 0
		indices[i * 3 + 1] = i32(1 + i)
		indices[i * 3 + 2] = i32(1 + (i + 1) % ring)
	}
	_ = sdl.RenderGeometry(renderer, nil, &verts[0], i32(n), &indices[0], i32(ring * 3))
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

// Quarter-circle ring of the given thickness, starting at angle `start` (radians, clockwise in screen space).
@(private = "file")
draw_arc :: proc(renderer: ^sdl.Renderer, cx, cy, radius, thickness, start: f32, c: clay.Color) {
	if thickness <= 0 do return
	inner := max(radius - thickness, 0)
	fc := to_fcolor(c)

	verts: [2 * (CORNER_SEGMENTS + 1)]sdl.Vertex
	for s in 0 ..= CORNER_SEGMENTS {
		a := start + f32(s) / CORNER_SEGMENTS * (math.PI / 2)
		ca, sa := math.cos(a), math.sin(a)
		verts[s * 2 + 0] = {position = {cx + ca * radius, cy + sa * radius}, color = fc}
		verts[s * 2 + 1] = {position = {cx + ca * inner, cy + sa * inner}, color = fc}
	}

	indices: [6 * CORNER_SEGMENTS]i32
	for s in 0 ..< CORNER_SEGMENTS {
		o := i32(s * 2)
		indices[s * 6 + 0] = o
		indices[s * 6 + 1] = o + 1
		indices[s * 6 + 2] = o + 2
		indices[s * 6 + 3] = o + 1
		indices[s * 6 + 4] = o + 3
		indices[s * 6 + 5] = o + 2
	}
	_ = sdl.RenderGeometry(renderer, nil, &verts[0], len(verts), &indices[0], len(indices))
}

// Icons are Lucide glyphs, centred in the element's bounds.
@(private = "file")
draw_icon :: proc(renderer: ^sdl.Renderer, data: Icon_Data, b: clay.BoundingBox) {
	font := text_get_font(&g.text, .Icons, data.size)
	if font == nil do return
	text := text_get(&g.text, font, ICON_GLYPHS[data.kind])
	if text == nil do return
	// Lucide draws each icon in the em square, which spans baseline to ascent;
	// the text height also counts line gap, so centre on the ascent instead.
	w, h: i32
	_ = ttf.GetTextSize(text, &w, &h)
	em := f32(ttf.GetFontAscent(font))
	c := data.color
	_ = ttf.SetTextColor(text, u8(c.r), u8(c.g), u8(c.b), u8(c.a))
	_ = ttf.DrawRendererText(text, math.round(b.x + (b.width - f32(w)) / 2), math.round(b.y + (b.height - em) / 2))
}
