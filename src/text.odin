package editor

import "core:hash"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Clay works in logical (DPI-independent) units. Fonts are rasterized at
// fontSize * ui_scale so text stays crisp on high-DPI displays, and measurements
// are divided back down by ui_scale before being handed to Clay.

Font_Key :: struct {
	id:   Font_Id,
	size: u16,
}

Text_Key :: struct {
	font: ^ttf.Font,
	hash: u64,
	len:  int,
}

Text_Entry :: struct {
	text:      ^ttf.Text,
	last_used: u64,
}

// Cached ttf.Text objects not drawn for this many frames are destroyed.
TEXT_CACHE_EVICT_FRAMES :: 120

Text_System :: struct {
	engine:     ^ttf.TextEngine,
	base_path:  string,
	fonts:      map[Font_Key]^ttf.Font,
	texts:      map[Text_Key]Text_Entry,
	char_widths: map[Font_Key]f32,
	frame:      u64,
}

text_init :: proc(ts: ^Text_System, renderer: ^sdl.Renderer) -> bool {
	if !ttf.Init() {
		sdl.Log("TTF_Init failed: %s", sdl.GetError())
		return false
	}
	ts.engine = ttf.CreateRendererTextEngine(renderer)
	if ts.engine == nil {
		sdl.Log("TTF_CreateRendererTextEngine failed: %s", sdl.GetError())
		return false
	}
	ts.base_path = strings.clone_from_cstring(sdl.GetBasePath())
	return true
}

text_destroy :: proc(ts: ^Text_System) {
	text_clear_caches(ts)
	delete(ts.fonts)
	delete(ts.texts)
	delete(ts.char_widths)
	delete(ts.base_path)
	ttf.DestroyRendererTextEngine(ts.engine)
	ttf.Quit()
}

// Drops every font and text object, e.g. after the display scale changes.
text_clear_caches :: proc(ts: ^Text_System) {
	for _, entry in ts.texts {
		ttf.DestroyText(entry.text)
	}
	clear(&ts.texts)
	for _, font in ts.fonts {
		ttf.CloseFont(font)
	}
	clear(&ts.fonts)
	clear(&ts.char_widths)
}

text_get_font :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> ^ttf.Font {
	key := Font_Key{id, size}
	if font, ok := ts.fonts[key]; ok {
		return font
	}
	path := strings.concatenate({ts.base_path, FONT_FILES[id]}, context.temp_allocator)
	font := ttf.OpenFont(strings.clone_to_cstring(path, context.temp_allocator), f32(size) * g.ui_scale)
	if font == nil {
		sdl.Log("TTF_OpenFont(%s) failed: %s", strings.clone_to_cstring(path, context.temp_allocator), sdl.GetError())
		return nil
	}
	ttf.SetFontHinting(font, FONT_HINTING)
	ts.fonts[key] = font
	return font
}

// Returns a cached ttf.Text for the given string, creating it if needed.
text_get :: proc(ts: ^Text_System, font: ^ttf.Font, s: string) -> ^ttf.Text {
	key := Text_Key{font, hash.fnv64a(transmute([]u8)s), len(s)}
	if entry, ok := &ts.texts[key]; ok {
		entry.last_used = ts.frame
		return entry.text
	}
	text := ttf.CreateText(ts.engine, font, cstring(raw_data(s)), uint(len(s)))
	if text == nil {
		return nil
	}
	ts.texts[key] = {text, ts.frame}
	return text
}

text_end_frame :: proc(ts: ^Text_System) {
	stale := make([dynamic]Text_Key, context.temp_allocator)
	for key, entry in ts.texts {
		if ts.frame - entry.last_used > TEXT_CACHE_EVICT_FRAMES {
			ttf.DestroyText(entry.text)
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&ts.texts, key)
	}
	ts.frame += 1
}

// Advance width of one character of a monospace font, in logical pixels.
// Measured over many characters so fractional advances come out exact.
text_char_width :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> f32 {
	key := Font_Key{id, size}
	if w, ok := ts.char_widths[key]; ok do return w
	font := text_get_font(ts, id, size)
	if font == nil do return 8
	SAMPLE :: "0000000000000000000000000000000000000000000000000000000000000000"
	w, h: i32
	_ = ttf.GetStringSize(font, SAMPLE, len(SAMPLE), &w, &h)
	width := f32(w) / len(SAMPLE) / g.ui_scale
	ts.char_widths[key] = width
	return width
}

measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	context = g.ctx
	font := text_get_font(&g.text, Font_Id(config.fontId), config.fontSize)
	if font == nil || text.length == 0 {
		return {0, f32(config.fontSize)}
	}
	w, h: i32
	_ = ttf.GetStringSize(font, cstring(text.chars), uint(text.length), &w, &h)
	return {f32(w) / g.ui_scale, f32(h) / g.ui_scale}
}
