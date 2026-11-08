package editor

import "core:math"

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"

import "gfx"

// Translates Clay render commands into gfx draw calls. Clay coordinates are
// logical; everything is multiplied by `scale` to get pixels


render_clay_commands :: proc(commands: ^clay.ClayArray(clay.RenderCommand), scale: f32) {
	gfx.begin_frame()

	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i)
		b := scale_box(cmd.boundingBox, scale)

		#partial switch cmd.commandType {
		case .Rectangle:
			data := cmd.renderData.rectangle
			gfx.fill_rounded_rect(b, scale_radius(data.cornerRadius, scale), data.backgroundColor)

		case .Text:
			data := cmd.renderData.text
			s := string(data.stringContents.chars[:data.stringContents.length])
			font := gfx.text_get_font(&gfx.text_system, gfx.Font_Id(data.fontId), data.fontSize)
			if font == nil do continue

			text := gfx.text_get(&gfx.text_system, font, s)
			gfx.draw_text(text, math.round(b.x), math.round(b.y), data.textColor)

		case .Border:
			data := cmd.renderData.border
			radius := scale_radius(data.cornerRadius, scale)
			gfx.draw_border(b, radius, data.width, data.color, scale)

		case .ScissorStart:
			gfx.push_clip({
				i32(math.round(b.x)),
				i32(math.round(b.y)),
				i32(math.round(b.width)),
				i32(math.round(b.height)),
			})

		case .ScissorEnd:
			gfx.pop_clip()

		case .OverlayColorStart:
			gfx.push_overlay(cmd.renderData.overlayColor.color)

		case .OverlayColorEnd:
			gfx.pop_overlay()

		case .Custom:
			data := cmd.renderData.custom
			if data.customData == nil do continue

			switch c in (^Custom_Data)(data.customData)^ {
			case gfx.Icon_Data:
				gfx.draw_icon(c, b)
			case ^Editor:
				draw_editor(c, b, scale)
			case ^Terminal:
				draw_terminal(c, b, scale)
			}

		case .Image:
			texture := (^sdl.Texture)(cmd.renderData.image.imageData)
			if texture == nil do continue

			dst := sdl.FRect{b.x, b.y, b.width, b.height}
			_ = sdl.RenderTexture(gfx.renderer, texture, nil, &dst)
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


// Clay's text measurement, in logical units
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	user_data: rawptr,
) -> clay.Dimensions {
	context = g.ctx

	ts := &gfx.text_system
	font := gfx.text_get_font(ts, gfx.Font_Id(config.fontId), config.fontSize)
	if font == nil || text.length == 0 {
		return {0, f32(config.fontSize)}
	}
	gfx.ensure_fallbacks(ts, font, string(text.chars[:text.length]))

	w, h: i32
	_ = ttf.GetStringSize(font, cstring(text.chars), uint(text.length), &w, &h)
	return {f32(w) / gfx.scale, f32(h) / gfx.scale}
}
