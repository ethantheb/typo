package editor

import "core:hash"
import "core:os"
import "core:strings"

import clay "../vendor/clay-odin"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Fonts, glyph fallback and cached text objects. Clay works in logical
// (DPI-independent) units; fonts are rasterized at size * scale so text stays
// crisp on high-DPI displays, and measurements are divided back by scale.

// Font ids index into FONT_FILES; Clay passes these back in measure/render.
Font_Id :: enum u16 {
	Body,
	SemiBold,
	Bold,
	Icons,
}

FONT_FILES := [Font_Id]string {
	.Body     = "assets/fonts/IBMPlexMono-Medium.ttf",
	.SemiBold = "assets/fonts/IBMPlexMono-SemiBold.ttf",
	.Bold     = "assets/fonts/IBMPlexMono-Bold.ttf",
	.Icons    = "assets/fonts/lucide.ttf",
}

// Snaps glyphs only vertically and positions them at fractional pixels.
FONT_HINTING :: ttf.Hinting.LIGHT_SUBPIXEL

// Cached ttf.Text objects not drawn for this many frames are destroyed.
TEXT_CACHE_EVICT_FRAMES :: 120

// System fonts tried, in order, for characters the bundled fonts lack:
// monospace symbols and box drawing first, then symbols and emoji, then other
// scripts. Missing files are skipped. A font gets them only once some text
// needs a character it lacks, since opening them all takes milliseconds.
when ODIN_OS == .Windows {
	FALLBACK_FONTS := []string {
		"CascadiaMono.ttf", // box drawing, block elements, powerline, braille
		"seguisym.ttf",     // dingbats, arrows, technical and geometric symbols
		"seguiemj.ttf",     // emoji
		"segoeui.ttf",      // Greek, Cyrillic, Arabic, Hebrew, ...
		"msyh.ttc",         // Chinese
		"YuGothM.ttc",      // Japanese
		"malgun.ttf",       // Korean
		"Nirmala.ttc",      // Indic scripts
		"LeelawUI.ttf",     // Thai, Lao, Khmer
		"ebrima.ttf",       // Ethiopic, N'Ko, Tifinagh
		"gadugi.ttf",       // Cherokee, Canadian syllabics
		"himalaya.ttf",     // Tibetan
		"mmrtext.ttf",      // Myanmar
		"seguihis.ttf",     // historic scripts
		"SimsunExtG.ttf",   // rare CJK extensions
	}
} else when ODIN_OS == .Darwin {
	FALLBACK_FONTS := []string {
		"/System/Library/Fonts/Menlo.ttc",
		"/System/Library/Fonts/Apple Symbols.ttf",
		"/System/Library/Fonts/Apple Color Emoji.ttc",
		"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
		"/System/Library/Fonts/PingFang.ttc",
		"/System/Library/Fonts/Hiragino Sans GB.ttc",
		"/System/Library/Fonts/AppleSDGothicNeo.ttc",
	}
} else {
	FALLBACK_FONTS := []string {
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
		"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
		"/usr/share/fonts/noto/NotoColorEmoji.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	}
}

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

Text_System :: struct {
	engine:         ^ttf.TextEngine,
	base_path:      string,
	scale:          f32,             // pixels per logical unit
	fallback_paths: [dynamic]string, // FALLBACK_FONTS that exist on this system
	found_paths:    bool,            // fallback_paths has been filled in
	fonts:          map[Font_Key]^ttf.Font,
	fallbacks:      map[^ttf.Font][dynamic]^ttf.Font, // attached to each font, at its size
	// Each bundled font without fallbacks, for asking what it covers itself
	// (TTF_FontHasGlyph on a font with fallbacks also searches them).
	bare:           [Font_Id]^ttf.Font,
	texts:          map[Text_Key]Text_Entry,
	char_widths:    map[Font_Key]f32,
	frame:          u64,
}

text_init :: proc(ts: ^Text_System, renderer: ^sdl.Renderer, scale: f32) -> bool {
	if !ttf.Init() {
		sdl.Log("TTF_Init failed: %s", sdl.GetError())
		return false
	}
	ts.engine = ttf.CreateRendererTextEngine(renderer)
	if ts.engine == nil {
		sdl.Log("TTF_CreateRendererTextEngine failed: %s", sdl.GetError())
		return false
	}
	ts.scale = scale
	ts.base_path = strings.clone_from_cstring(sdl.GetBasePath())
	return true
}

text_destroy :: proc(ts: ^Text_System) {
	text_clear_caches(ts)
	delete(ts.fonts)
	delete(ts.fallbacks)
	for font in ts.bare do if font != nil do ttf.CloseFont(font)
	for path in ts.fallback_paths do delete(path)
	delete(ts.fallback_paths)
	delete(ts.texts)
	delete(ts.char_widths)
	delete(ts.base_path)
	ttf.DestroyRendererTextEngine(ts.engine)
	ttf.Quit()
}

// Re-rasterizes everything at a new display scale.
text_set_scale :: proc(ts: ^Text_System, scale: f32) {
	if scale == ts.scale do return
	ts.scale = scale
	text_clear_caches(ts)
}

// Drops every font and text object.
text_clear_caches :: proc(ts: ^Text_System) {
	for _, entry in ts.texts do ttf.DestroyText(entry.text)
	clear(&ts.texts)
	for _, font in ts.fonts do ttf.CloseFont(font)
	clear(&ts.fonts)
	// After the fonts that use them.
	for _, list in ts.fallbacks {
		for font in list do ttf.CloseFont(font)
		delete(list)
	}
	clear(&ts.fallbacks)
	clear(&ts.char_widths)
}

@(private = "file")
open_font :: proc(ts: ^Text_System, path: string, size: f32) -> ^ttf.Font {
	font := ttf.OpenFont(strings.clone_to_cstring(path, context.temp_allocator), size)
	if font != nil do ttf.SetFontHinting(font, FONT_HINTING)
	return font
}

text_get_font :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> ^ttf.Font {
	key := Font_Key{id, size}
	if font, ok := ts.fonts[key]; ok do return font
	px := f32(size) * ts.scale
	path := strings.concatenate({ts.base_path, FONT_FILES[id]}, context.temp_allocator)
	font := open_font(ts, path, px)
	if font == nil {
		sdl.Log("TTF_OpenFont(%s) failed: %s", strings.clone_to_cstring(path, context.temp_allocator), sdl.GetError())
		return nil
	}
	ts.fonts[key] = font
	return font
}

// Attaches the fallback fonts to `font` if `s` has a character it lacks.
@(private = "file")
ensure_fallbacks :: proc(ts: ^Text_System, font: ^ttf.Font, s: string) {
	if font in ts.fallbacks do return
	for r in s {
		// Until fallbacks are attached, this asks the font itself.
		if r < 0x80 || ttf.FontHasGlyph(font, u32(r)) do continue
		if !ts.found_paths do find_fallback_paths(ts)
		list := make([dynamic]^ttf.Font, 0, len(ts.fallback_paths))
		size := ttf.GetFontSize(font)
		for path in ts.fallback_paths {
			fallback := open_font(ts, path, size)
			if fallback == nil do continue
			if ttf.AddFallbackFont(font, fallback) do append(&list, fallback)
			else do ttf.CloseFont(fallback)
		}
		ts.fallbacks[font] = list
		return
	}
}

@(private = "file")
find_fallback_paths :: proc(ts: ^Text_System) {
	ts.found_paths = true
	when ODIN_OS == .Windows {
		windir := os.get_env("WINDIR", context.temp_allocator)
		font_dir := strings.concatenate({windir != "" ? windir : `C:\Windows`, `\Fonts\`}, context.temp_allocator)
	} else {
		font_dir := ""
	}
	for name in FALLBACK_FONTS {
		path := strings.concatenate({font_dir, name})
		if os.exists(path) do append(&ts.fallback_paths, path)
		else do delete(path)
	}
}

// Whether the bundled font itself has a glyph for `r`, as opposed to one of
// its fallbacks. Fallback glyphs have their own advance, so monospace layouts
// (editor, terminal) draw them separately at their column.
font_has_own_glyph :: proc(ts: ^Text_System, id: Font_Id, r: rune) -> bool {
	if r < 0x80 do return true
	if ts.bare[id] == nil {
		ts.bare[id] = open_font(ts, strings.concatenate({ts.base_path, FONT_FILES[id]}, context.temp_allocator), 12)
		if ts.bare[id] == nil do return true
	}
	return ttf.FontHasGlyph(ts.bare[id], u32(r))
}

// A cached ttf.Text for the given string, created if needed.
text_get :: proc(ts: ^Text_System, font: ^ttf.Font, s: string) -> ^ttf.Text {
	key := Text_Key{font, hash.fnv64a(transmute([]u8)s), len(s)}
	if entry, ok := &ts.texts[key]; ok {
		entry.last_used = ts.frame
		return entry.text
	}
	ensure_fallbacks(ts, font, s)
	text := ttf.CreateText(ts.engine, font, cstring(raw_data(s)), uint(len(s)))
	if text == nil do return nil
	// Otherwise SDL_ttf hides leading whitespace, shifting runs that start with a space.
	_ = ttf.SetTextWrapWhitespaceVisible(text, true)
	ts.texts[key] = {text, ts.frame}
	return text
}

// Evicts text objects that haven't been drawn recently. Scans the cache only
// every 64 frames.
text_end_frame :: proc(ts: ^Text_System) {
	ts.frame += 1
	if ts.frame % 64 != 0 do return
	stale := make([dynamic]Text_Key, context.temp_allocator)
	for key, entry in ts.texts {
		if ts.frame - entry.last_used > TEXT_CACHE_EVICT_FRAMES {
			ttf.DestroyText(entry.text)
			append(&stale, key)
		}
	}
	for key in stale do delete_key(&ts.texts, key)
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
	width := f32(w) / len(SAMPLE) / ts.scale
	ts.char_widths[key] = width
	return width
}

measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	context = g.ctx
	ts := &g.text
	font := text_get_font(ts, Font_Id(config.fontId), config.fontSize)
	if font == nil || text.length == 0 do return {0, f32(config.fontSize)}
	ensure_fallbacks(ts, font, string(text.chars[:text.length]))
	w, h: i32
	_ = ttf.GetStringSize(font, cstring(text.chars), uint(text.length), &w, &h)
	return {f32(w) / ts.scale, f32(h) / ts.scale}
}
