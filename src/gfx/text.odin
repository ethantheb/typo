package gfx

import "core:hash"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

import clay "../../vendor/clay-odin"
import sdl "../../vendor/sdl3"
import ttf "../../vendor/sdl3/ttf"

// Fonts, glyph fallback and cached text objects. Clay works in logical
// (DPI-independent) units; fonts are rasterized at size * scale so text stays
// crisp on high-DPI displays, and measurements are divided back by scale


// Clay passes these back in measure/render. The UI uses bundled Instrument
// Sans (and Icons); the editor and terminal use the configured family, rendered
// Markdown its own (see text_set_source)
Font_Id :: enum u16 {
	Body,
	SemiBold,
	Bold,
	Icons,
	Editor,
	Editor_Bold,
	Editor_Italic,
	Md_Regular,
	Md_Italic,
	Md_SemiBold,
	Md_Bold,
	Md_Bold_Italic,
}

// The font id of each Markdown face
MD_FONTS := [Md_Face]Font_Id {
	.Regular     = .Md_Regular,
	.Italic      = .Md_Italic,
	.SemiBold    = .Md_SemiBold,
	.Bold        = .Md_Bold,
	.Bold_Italic = .Md_Bold_Italic,
}

ICON_FONT_DATA := #load("../../assets/fonts/lucide.ttf")

// Every font, every weight: snaps glyphs only vertically and places them at
// quarter pixels along the font's own (unrounded) advances
FONT_HINTING :: ttf.Hinting.LIGHT_SUBPIXEL

// Cached ttf.Text objects not drawn for this many frames are destroyed
TEXT_CACHE_EVICT_FRAMES :: 120

// System fonts tried, in order, for characters the bundled fonts lack:
// monospace symbols and box drawing first, then symbols and emoji, then other
// scripts. Missing files are skipped. A font gets them only once some text
// needs a character it lacks, since opening them all takes milliseconds
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
	fallback_paths: [dynamic]string, // FALLBACK_FONTS that exist on this system
	found_paths:    bool,            // fallback_paths has been filled in
	fonts:          map[Font_Key]^ttf.Font,
	fallbacks:      map[^ttf.Font][dynamic]^ttf.Font, // attached to each font, at its size
	// Each id's font without fallbacks, for asking what it covers itself
	// (TTF_FontHasGlyph on a font with fallbacks also searches them)
	bare:           [Font_Id]^ttf.Font,
	sources:        [Font_Id]Font_Source,
	texts:          map[Text_Key]Text_Entry,
	char_widths:    map[Font_Key]f32,
	metrics:        map[Font_Key]Font_Metrics,
	widths:         map[Width_Key]f32,
	frame:          u64,
	// Bumped whenever fonts are reopened, so measurements made with them are stale
	generation:     u64,
	// Text brightness and contrast the glyph coverage is mapped for (text_set_contrast)
	coverage_for:   [2]f32,
}

// The app's fonts and text objects
text_system: Text_System

// Pixels per logical unit
scale: f32

// Called from background threads when something finished that the main loop
// should draw (the installed font scan); set by the app
wake: proc "contextless" (userdata: rawptr)


// --- Setup -------------------------------------------------------------------------

// Sets up text drawing on gfx.renderer, at gfx.scale
text_init :: proc(ts: ^Text_System) -> bool {
	if !ttf.Init() {
		sdl.Log("TTF_Init failed: %s", sdl.GetError())
		return false
	}
	ts.engine = ttf.CreateRendererTextEngine(renderer)
	if ts.engine == nil {
		sdl.Log("TTF_CreateRendererTextEngine failed: %s", sdl.GetError())
		return false
	}

	ts.coverage_for = -1
	ts.sources = {
		.Body           = bundled_sans(500),
		.SemiBold       = bundled_sans(600),
		.Bold           = bundled_sans(700),
		.Icons          = {data = ICON_FONT_DATA},
		.Editor         = bundled_mono(500),
		.Editor_Bold    = bundled_mono(700),
		.Editor_Italic  = bundled_mono(500, italic = true),
		.Md_Regular     = bundled_sans(400),
		.Md_SemiBold    = bundled_sans(600),
		.Md_Bold        = bundled_sans(700),
		.Md_Italic      = bundled_sans(400, italic = true),
		.Md_Bold_Italic = bundled_sans(700, italic = true),
	}
	return true
}


// A bundled face by weight and style
@(private = "file")
bundled_face :: proc(faces: []Font_Face, weight: int, italic: bool) -> Font_Source {
	for f in faces {
		if f.weight == weight && f.italic == italic {
			return f.source
		}
	}
	panic("no such bundled face")
}


@(private = "file")
bundled_sans :: proc(weight: int, italic := false) -> Font_Source {
	return bundled_face(BUNDLED_MD_FACES[:], weight, italic)
}


@(private = "file")
bundled_mono :: proc(weight: int, italic := false) -> Font_Source {
	return bundled_face(BUNDLED_FACES[:], weight, italic)
}


text_destroy :: proc(ts: ^Text_System) {
	text_clear_caches(ts)
	delete(ts.fonts)
	delete(ts.fallbacks)

	for font in ts.bare {
		if font != nil do ttf.CloseFont(font)
	}
	for src in ts.sources do delete(src.path)
	for path in ts.fallback_paths do delete(path)
	delete(ts.fallback_paths)

	delete(ts.texts)
	delete(ts.char_widths)
	delete(ts.metrics)
	delete(ts.widths)
	ttf.DestroyRendererTextEngine(ts.engine)
	ttf.Quit()
}


// Re-rasterizes everything at a new display scale
set_scale :: proc(ts: ^Text_System, display_scale: f32) {
	if display_scale == scale do return

	scale = display_scale
	if ts.engine != nil do text_clear_caches(ts)
}


// Drops every font and text object
text_clear_caches :: proc(ts: ^Text_System) {
	for _, entry in ts.texts do ttf.DestroyText(entry.text)
	clear(&ts.texts)
	for _, font in ts.fonts do ttf.CloseFont(font)
	clear(&ts.fonts)

	// After the fonts that use them
	for _, list in ts.fallbacks {
		for font in list do ttf.CloseFont(font)
		delete(list)
	}
	clear(&ts.fallbacks)

	clear(&ts.char_widths)
	clear(&ts.metrics)
	clear(&ts.widths)
	ts.generation += 1
}


// --- Fonts -------------------------------------------------------------------------

// Sets what glyph coverage is mapped for (see set_coverage): text of the given
// color, with contrast enhanced by `contrast` (0 = none). Re-rasterizes
// everything when that changes
text_set_contrast :: proc(ts: ^Text_System, c: clay.Color, contrast: f32) {
	if ts.engine == nil do return

	// Rec. 601 brightness, in tenths so that similar themes share a mapping
	b := math.round((0.30 * c.r + 0.59 * c.g + 0.11 * c.b) / 255 * 10) / 10
	if ts.coverage_for == {b, contrast} do return

	ts.coverage_for = {b, contrast}
	text_clear_caches(ts)
}


// Maps a font's glyph coverage to alpha: grayscale DirectWrite's gamma
// correction (as in Windows Terminal's shader, which Zed uses too) after
// enhancing contrast, which DirectWrite does only for dark text but thin light
// text needs as much. Heavier weights get less, so the gaps in bold letters
// (the dot of an i) stay open; lighter ones more
@(private = "file")
set_coverage :: proc(ts: ^Text_System, font: ^ttf.Font) {
	b, contrast := ts.coverage_for[0], ts.coverage_for[1]
	if b < 0 do return

	k := contrast * clamp(f32(700 - ttf.GetFontWeight(font)) / 300, 0, 2)

	// DirectWrite's alpha correction for a gamma of 1.8 (from Windows Terminal,
	// MIT license, Copyright (c) Microsoft Corporation)
	g := [4]f32 {
		0.1469 * 0x10000 / (255 * 255),
		-0.8911 * 0x100 / 255,
		1.4644 * 0x10000 / (255 * 255),
		-0.3234 * 0x100 / 255,
	}

	table: [256]u8
	for &v, i in table {
		a := f32(i) / 255
		a = a * (k + 1) / (a * k + 1)
		a += a * (1 - a) * ((g[0] * b + g[1]) * a + (g[2] * b + g[3]))
		v = u8(math.round(clamp(a, 0, 1) * 255))
	}
	_ = ttf.SetFontCoverageTable(font, &table[0])
}


@(private = "file")
open_font :: proc(src: Font_Source, size: f32) -> ^ttf.Font {
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)

	// From memory or from a file
	if src.data != nil {
		stream := sdl.IOFromConstMem(raw_data(src.data), uint(len(src.data)))
		_ = sdl.SetPointerProperty(props, ttf.PROP_FONT_CREATE_IOSTREAM_POINTER, stream)
		_ = sdl.SetBooleanProperty(props, ttf.PROP_FONT_CREATE_IOSTREAM_AUTOCLOSE_BOOLEAN, true)
	} else {
		path := strings.clone_to_cstring(src.path, context.temp_allocator)
		_ = sdl.SetStringProperty(props, ttf.PROP_FONT_CREATE_FILENAME_STRING, path)
	}
	_ = sdl.SetFloatProperty(props, ttf.PROP_FONT_CREATE_SIZE_FLOAT, size)
	_ = sdl.SetNumberProperty(props, ttf.PROP_FONT_CREATE_FACE_NUMBER, src.face)

	font := ttf.OpenFontWithProperties(props)
	if font != nil {
		ttf.SetFontHinting(font, FONT_HINTING)
		if src.synthetic_italic do ttf.SetFontStyle(font, {.ITALIC})
	}
	return font
}


// Points a font id at another font, dropping what was opened from the old one
text_set_source :: proc(ts: ^Text_System, id: Font_Id, src: Font_Source) {
	old := &ts.sources[id]
	same := old.path == src.path &&
	        raw_data(old.data) == raw_data(src.data) &&
	        old.face == src.face &&
	        old.synthetic_italic == src.synthetic_italic
	if same do return

	ts.generation += 1

	// Close the fonts opened from it, with their text objects and fallbacks
	stale := make([dynamic]Font_Key, context.temp_allocator)
	for key, font in ts.fonts {
		if key.id != id do continue
		append(&stale, key)

		dead := make([dynamic]Text_Key, context.temp_allocator)
		for text_key, entry in ts.texts {
			if text_key.font != font do continue
			ttf.DestroyText(entry.text)
			append(&dead, text_key)
		}
		for k in dead do delete_key(&ts.texts, k)

		ttf.CloseFont(font)
		if list, ok := ts.fallbacks[font]; ok {
			for fallback in list do ttf.CloseFont(fallback)
			delete(list)
			delete_key(&ts.fallbacks, font)
		}
	}

	// Forget what was measured with them
	for key in stale {
		delete_key(&ts.fonts, key)
		delete_key(&ts.char_widths, key)
		delete_key(&ts.metrics, key)
	}
	clear(&ts.widths)
	if ts.bare[id] != nil {
		ttf.CloseFont(ts.bare[id])
		ts.bare[id] = nil
	}

	delete(old.path)
	old^ = src
	old.path = strings.clone(src.path)
}


text_get_font :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> ^ttf.Font {
	if ts.engine == nil do return nil

	key := Font_Key{id, size}
	if font, ok := ts.fonts[key]; ok {
		return font
	}

	font := open_font(ts.sources[id], f32(size) * scale)
	if font == nil {
		sdl.Log("opening font %d failed: %s", i32(id), sdl.GetError())
		return nil
	}
	set_coverage(ts, font)
	ts.fonts[key] = font
	return font
}


// --- Fallback fonts ----------------------------------------------------------------

// Attaches the fallback fonts to `font` if `s` has a character it lacks
ensure_fallbacks :: proc(ts: ^Text_System, font: ^ttf.Font, s: string) {
	if font in ts.fallbacks do return

	for r in s {
		// Until fallbacks are attached, this asks the font itself
		if r < 0x80 || ttf.FontHasGlyph(font, u32(r)) {
			continue
		}
		if !ts.found_paths do find_fallback_paths(ts)

		list := make([dynamic]^ttf.Font, 0, len(ts.fallback_paths))
		size := ttf.GetFontSize(font)
		for path in ts.fallback_paths {
			fallback := open_font({path = path}, size)
			if fallback == nil do continue

			set_coverage(ts, fallback)
			if ttf.AddFallbackFont(font, fallback) {
				append(&list, fallback)
			} else {
				ttf.CloseFont(fallback)
			}
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
		windows := windir != "" ? windir : `C:\Windows`
		font_dir := strings.concatenate({windows, `\Fonts\`}, context.temp_allocator)
	} else {
		font_dir := ""
	}

	for name in FALLBACK_FONTS {
		path := strings.concatenate({font_dir, name})
		if os.exists(path) {
			append(&ts.fallback_paths, path)
		} else {
			delete(path)
		}
	}
}


// Whether the font itself has a glyph for `r`, as opposed to one of
// its fallbacks. Fallback glyphs have their own advance, so monospace layouts
// (editor, terminal) draw them separately at their column
font_has_own_glyph :: proc(ts: ^Text_System, id: Font_Id, r: rune) -> bool {
	if r < 0x80 do return true

	if ts.bare[id] == nil {
		ts.bare[id] = open_font(ts.sources[id], 12)
		if ts.bare[id] == nil do return true
	}
	return ttf.FontHasGlyph(ts.bare[id], u32(r))
}


// --- Text objects ------------------------------------------------------------------

// A cached ttf.Text for the given string, created if needed
text_get :: proc(ts: ^Text_System, font: ^ttf.Font, s: string) -> ^ttf.Text {
	key := Text_Key{font, hash.fnv64a(transmute([]u8)s), len(s)}
	if entry, ok := &ts.texts[key]; ok {
		entry.last_used = ts.frame
		return entry.text
	}

	ensure_fallbacks(ts, font, s)
	text := ttf.CreateText(ts.engine, font, cstring(raw_data(s)), uint(len(s)))
	if text == nil do return nil

	// Otherwise SDL_ttf hides leading whitespace, shifting runs that start with a space
	_ = ttf.SetTextWrapWhitespaceVisible(text, true)
	ts.texts[key] = {text, ts.frame}
	return text
}


// Evicts text objects that haven't been drawn recently. Scans the cache only
// every 64 frames
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
// Measured over many characters so fractional advances come out exact
text_char_width :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> f32 {
	key := Font_Key{id, size}
	if w, ok := ts.char_widths[key]; ok {
		return w
	}

	font := text_get_font(ts, id, size)
	if font == nil do return 8

	SAMPLE :: "0000000000000000000000000000000000000000000000000000000000000000"
	w, h: i32
	_ = ttf.GetStringSize(font, SAMPLE, len(SAMPLE), &w, &h)
	width := f32(w) / len(SAMPLE) / scale

	ts.char_widths[key] = width
	return width
}


// --- Measuring proportional text (rendered Markdown) -------------------------------
// In logical pixels. Without a text engine (unit tests) each character is half
// the font size wide

Width_Key :: struct {
	font: Font_Key,
	hash: u64,
	len:  int,
}

// Cached widths are dropped when this many have built up
@(private = "file")
WIDTH_CACHE_MAX :: 1 << 16

// Ascent, descent and height of a font, in logical pixels
Font_Metrics :: struct {
	ascent, descent, height: f32,
}


font_metrics :: proc(ts: ^Text_System, id: Font_Id, size: u16) -> Font_Metrics {
	if ts.engine == nil do return {f32(size) * 0.8, f32(size) * 0.25, f32(size) * 1.05}

	key := Font_Key{id, size}
	if m, ok := ts.metrics[key]; ok {
		return m
	}

	font := text_get_font(ts, id, size)
	if font == nil do return {f32(size) * 0.8, f32(size) * 0.25, f32(size) * 1.05}

	m := Font_Metrics {
		ascent  = f32(ttf.GetFontAscent(font)) / scale,
		descent = f32(-ttf.GetFontDescent(font)) / scale,
		height  = f32(ttf.GetFontHeight(font)) / scale,
	}
	ts.metrics[key] = m
	return m
}


// Width of `s` (one line) drawn in a font, cached
text_width :: proc(ts: ^Text_System, id: Font_Id, size: u16, s: string) -> f32 {
	if len(s) == 0 do return 0
	if ts.engine == nil do return f32(strings.rune_count(s)) * f32(size) * 0.5

	key := Width_Key{{id, size}, hash.fnv64a(transmute([]u8)s), len(s)}
	if w, ok := ts.widths[key]; ok {
		return w
	}

	font := text_get_font(ts, id, size)
	if font == nil do return 0

	ensure_fallbacks(ts, font, s)
	w, h: i32
	_ = ttf.GetStringSize(font, cstring(raw_data(s)), uint(len(s)), &w, &h)

	if len(ts.widths) >= WIDTH_CACHE_MAX do clear(&ts.widths)
	width := f32(w) / scale
	ts.widths[key] = width
	return width
}


// How many bytes of `s` fit in `max_w` (at least one character)
text_fit :: proc(ts: ^Text_System, id: Font_Id, size: u16, s: string, max_w: f32) -> int {
	if len(s) == 0 do return 0

	n := 0

	// Without a text engine, every character is half the font size wide
	if ts.engine == nil {
		cols := max(int(max_w / (f32(size) * 0.5)), 0)
		for _, i in s {
			if cols == 0 do return max(i, first_rune_len(s))
			cols -= 1
		}
		return len(s)
	}

	if font := text_get_font(ts, id, size); font != nil {
		mw: i32
		ml: uint
		max_px := i32(max_w * scale)
		_ = ttf.MeasureString(font, cstring(raw_data(s)), uint(len(s)), max_px, &mw, &ml)
		n = int(ml)
	}
	return max(n, first_rune_len(s))
}


// The character boundary in `s` nearest to x
text_index_at :: proc(ts: ^Text_System, id: Font_Id, size: u16, s: string, x: f32) -> int {
	if x <= 0 || len(s) == 0 {
		return 0
	}

	i := min(text_fit(ts, id, size, s, x), len(s))
	if text_width(ts, id, size, s[:i]) > x do i = 0 // the first character alone is wider
	if i >= len(s) do return len(s)

	// The nearer edge of the character at i
	_, n := utf8.decode_rune_in_string(s[i:])
	left := text_width(ts, id, size, s[:i])
	right := text_width(ts, id, size, s[:i + n])
	return x - left <= right - x ? i : i + n
}


@(private = "file")
first_rune_len :: proc(s: string) -> int {
	_, n := utf8.decode_rune_in_string(s)
	return n
}
