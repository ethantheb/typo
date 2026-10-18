package editor

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import sdl "../vendor/sdl3"
import ttf "../vendor/sdl3/ttf"

// Font families for the editor and terminal: the bundled IBM Plex Mono, and the
// monospace fonts installed on the system. Installed fonts are found by a
// background thread that opens every file in the system font folders. It runs
// the first time the list is needed (to load a configured family that isn't
// bundled, which shows the bundled font until then) and again each time the font
// list opens, so fonts installed meanwhile appear; the old list stays in use
// until the new one is ready.

BUNDLED_FAMILY :: "IBM Plex Mono"

// Where to load a font from.
Font_Source :: struct {
	data: []u8,   // a bundled font, or
	path: string, // a font file
	// Face in a collection; for a variable font, plus the named instance << 16.
	face: i64,
}

Font_Face :: struct {
	using source: Font_Source,
	weight:       int, // 100 (thin) to 900 (black)
}

Font_Family :: struct {
	name:  string,
	faces: [dynamic]Font_Face, // upright styles only
}

BUNDLED_FACES := [?]Font_Face {
	{{data = #load("../assets/fonts/IBMPlexMono-ExtraLight.ttf")}, 200},
	{{data = #load("../assets/fonts/IBMPlexMono-Light.ttf")}, 300},
	{{data = #load("../assets/fonts/IBMPlexMono-Regular.ttf")}, 400},
	{{data = #load("../assets/fonts/IBMPlexMono-Medium.ttf")}, 500},
	{{data = #load("../assets/fonts/IBMPlexMono-SemiBold.ttf")}, 600},
	{{data = #load("../assets/fonts/IBMPlexMono-Bold.ttf")}, 700},
}

System_Fonts :: struct {
	scan:      ^Font_Scan,
	scan_ms:   f64,                  // how long the scan took
	families:  [dynamic]Font_Family, // sorted by name; replaced when a scan finishes
	scanned:   bool,                 // a scan has finished
}

// Shared with the scanning thread.
Font_Scan :: struct {
	thread:   ^thread.Thread,
	mutex:    sync.Mutex,
	done:     bool,
	cancel:   bool, // read with atomics by the thread
	found:    [dynamic]Font_Family,
	started:  time.Tick,
	finished: time.Tick,
}

// The folders fonts are installed in. Not in the temp allocator, which the
// directory walk frees as it goes.
when ODIN_OS == .Windows {
	@(private = "file")
	font_dirs :: proc() -> [dynamic]string {
		windir := os.get_env("WINDIR", context.temp_allocator)
		local := os.get_env("LOCALAPPDATA", context.temp_allocator)
		dirs := make([dynamic]string)
		append(&dirs, strings.concatenate({windir != "" ? windir : `C:\Windows`, `\Fonts`}))
		if local != "" do append(&dirs, strings.concatenate({local, `\Microsoft\Windows\Fonts`}))
		return dirs
	}
} else when ODIN_OS == .Darwin {
	@(private = "file")
	font_dirs :: proc() -> [dynamic]string {
		home := os.get_env("HOME", context.temp_allocator)
		dirs := make([dynamic]string)
		append(&dirs, strings.clone("/System/Library/Fonts"), strings.clone("/Library/Fonts"))
		if home != "" do append(&dirs, strings.concatenate({home, "/Library/Fonts"}))
		return dirs
	}
} else {
	@(private = "file")
	font_dirs :: proc() -> [dynamic]string {
		home := os.get_env("HOME", context.temp_allocator)
		dirs := make([dynamic]string)
		append(&dirs, strings.clone("/usr/share/fonts"), strings.clone("/usr/local/share/fonts"))
		if home != "" {
			append(&dirs, strings.concatenate({home, "/.local/share/fonts"}))
			append(&dirs, strings.concatenate({home, "/.fonts"}))
		}
		return dirs
	}
}

// Starts looking for installed fonts on a background thread, unless a scan is
// running or (without `again`) one has already finished.
fonts_scan :: proc(sf: ^System_Fonts, again := false) {
	if sf.scan != nil || (sf.scanned && !again) do return
	sf.scan = new(Font_Scan)
	sf.scan.started = time.tick_now()
	sf.scan.thread = thread.create_and_start_with_poly_data(sf.scan, scan_fonts, init_context = runtime.default_context())
}

fonts_scanning :: proc(sf: ^System_Fonts) -> bool {
	return sf.scan != nil
}

// Takes the scan's results once it has finished. Returns true on that frame.
fonts_poll :: proc(sf: ^System_Fonts) -> bool {
	s := sf.scan
	if s == nil do return false
	done: bool
	if sync.guard(&s.mutex) do done = s.done
	if !done do return false
	thread.join(s.thread)
	thread.destroy(s.thread)
	families_destroy(&sf.families)
	sf.families = s.found
	sf.scan_ms = time.duration_milliseconds(time.tick_diff(s.started, s.finished))
	sf.scanned = true
	free(s)
	sf.scan = nil
	return true
}

fonts_destroy :: proc(sf: ^System_Fonts) {
	if s := sf.scan; s != nil {
		sync.atomic_store(&s.cancel, true)
		thread.join(s.thread)
		thread.destroy(s.thread)
		families_destroy(&s.found)
		free(s)
	}
	families_destroy(&sf.families)
	sf^ = {}
}

@(private = "file")
families_destroy :: proc(families: ^[dynamic]Font_Family) {
	for f in families {
		delete(f.name)
		for face in f.faces do delete(face.path)
		delete(f.faces)
	}
	delete(families^)
}

// The family names to choose from: the bundled one, then the installed ones.
font_family_names :: proc(sf: ^System_Fonts) -> []string {
	names := make([dynamic]string, 0, len(sf.families) + 1, context.temp_allocator)
	append(&names, BUNDLED_FAMILY)
	for f in sf.families do append(&names, f.name)
	return names[:]
}

// Whether `family` is known to be unavailable, so the bundled font is shown instead.
font_family_missing :: proc(sf: ^System_Fonts, family: string) -> bool {
	if family == BUNDLED_FAMILY || !sf.scanned do return false
	for f in sf.families do if f.name == family do return false
	return true
}

// The faces to draw the editor with: the family's regular and bold styles at
// the weights nearest the requested one. found is false (and the bundled family
// is used) while the installed fonts haven't been scanned or don't include it.
font_family_sources :: proc(sf: ^System_Fonts, family: string, weight: int) -> (regular, bold: Font_Source, found: bool) {
	faces := BUNDLED_FACES[:]
	found = family == BUNDLED_FAMILY
	if !found {
		for &f in sf.families {
			if f.name == family {
				faces, found = f.faces[:], true
				break
			}
		}
	}
	if !found do faces = BUNDLED_FACES[:]
	r := nearest_face(faces, weight)
	// Bold is two steps heavier than the text, and at least 700.
	b := nearest_face(faces, max(weight + 200, 700), heavier_than = r.weight)
	return r.source, b.source, found
}

@(private = "file")
nearest_face :: proc(faces: []Font_Face, weight: int, heavier_than := 0) -> Font_Face {
	best := faces[0]
	best_d := max(int)
	for f in faces {
		d := abs(f.weight - weight)
		// Fall back to lighter faces only when nothing heavier exists.
		if f.weight <= heavier_than do d += 1000
		if d < best_d do best, best_d = f, d
	}
	return best
}

// --- Scanning thread --------------------------------------------------------------

@(private = "file")
scan_fonts :: proc(s: ^Font_Scan) {
	State :: struct {
		scan:  ^Font_Scan,
		found: ^[dynamic]Font_Family,
	}
	visit :: proc(path: string, user: rawptr) -> bool {
		st := (^State)(user)
		ext := strings.to_lower(os.ext(path), context.temp_allocator)
		if ext == ".ttf" || ext == ".otf" || ext == ".ttc" || ext == ".otc" do add_font_file(st.found, path)
		return !sync.atomic_load(&st.scan.cancel)
	}

	found := make([dynamic]Font_Family)
	st := State{s, &found}
	dirs := font_dirs()
	for dir in dirs {
		walk_files(dir, nil, &s.cancel, &st, visit)
		delete(dir)
	}
	delete(dirs)
	slice.sort_by(found[:], proc(a, b: Font_Family) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
	for &f in found {
		slice.sort_by(f.faces[:], proc(a, b: Font_Face) -> bool {return a.weight < b.weight})
	}
	free_all(context.temp_allocator)
	sync.guard(&s.mutex)
	s.found = found
	s.done = true
	s.finished = time.tick_now()
	wake_main_loop(nil)
}

// Adds the upright monospace faces in one font file, including the named
// instances (Light, Bold, ...) of a variable font.
@(private = "file")
add_font_file :: proc(found: ^[dynamic]Font_Family, path: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	faces := 1
	for face := 0; face < faces; face += 1 {
		font := open_face(cpath, i64(face))
		if font == nil do return
		defer ttf.CloseFont(font)
		if face == 0 do faces = max(int(ttf.GetNumFontFaces(font)), 1)
		if !ttf.FontIsFixedWidth(font) || !has_ascii(font) do continue
		add_face(found, font, path, i64(face), int(ttf.GetFontWeight(font)))

		// FreeType ignores the instance bits for a font without variations, so
		// one whose first two instances look like the face itself has none.
		base := string(ttf.GetFontStyleName(font))
		for instance := 1; instance < 64; instance += 1 {
			index := i64(instance) << 16 | i64(face)
			inst := open_face(cpath, index)
			if inst == nil do break
			style := string(ttf.GetFontStyleName(inst))
			if instance <= 2 && style == base {
				ttf.CloseFont(inst)
				if instance == 2 do break
				continue
			}
			weight, named := weight_from_style(style)
			add_face(found, inst, path, index, named ? weight : int(ttf.GetFontWeight(inst)))
			ttf.CloseFont(inst)
		}
	}
}

// Some CJK fonts are fixed width without having Latin letters.
@(private = "file")
has_ascii :: proc(font: ^ttf.Font) -> bool {
	for r in "aZ09{}" do if !ttf.FontHasGlyph(font, u32(r)) do return false
	return true
}

@(private = "file")
open_face :: proc(path: cstring, index: i64) -> ^ttf.Font {
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetStringProperty(props, ttf.PROP_FONT_CREATE_FILENAME_STRING, path)
	_ = sdl.SetFloatProperty(props, ttf.PROP_FONT_CREATE_SIZE_FLOAT, 12)
	_ = sdl.SetNumberProperty(props, ttf.PROP_FONT_CREATE_FACE_NUMBER, index)
	return ttf.OpenFontWithProperties(props)
}

@(private = "file")
add_face :: proc(found: ^[dynamic]Font_Family, font: ^ttf.Font, path: string, index: i64, weight: int) {
	name := string(ttf.GetFontFamilyName(font))
	style := strings.to_lower(string(ttf.GetFontStyleName(font)), context.temp_allocator)
	if name == "" || name == BUNDLED_FAMILY do return
	if strings.contains(style, "italic") || strings.contains(style, "oblique") do return
	family: ^Font_Family
	for &f in found do if f.name == name do family = &f
	if family == nil {
		append(found, Font_Family{name = strings.clone(name)})
		family = &found[len(found) - 1]
	}
	for f in family.faces do if f.weight == weight do return
	append(&family.faces, Font_Face{{path = strings.clone(path), face = index}, clamp(weight, 100, 900)})
}

// The weight a style name such as "SemiBold" or "Extra Light" stands for.
@(private = "file")
weight_from_style :: proc(style: string) -> (int, bool) {
	s, _ := strings.replace_all(strings.to_lower(style, context.temp_allocator), " ", "", context.temp_allocator)
	s, _ = strings.replace_all(s, "-", "", context.temp_allocator)
	NAMES := [?]struct {
		name:   string,
		weight: int,
	} {
		// Longer names first, so "extrabold" isn't taken for "bold".
		{"extralight", 200}, {"ultralight", 200}, {"semilight", 350}, {"demilight", 350},
		{"extrabold", 800}, {"ultrabold", 800}, {"semibold", 600}, {"demibold", 600},
		{"hairline", 100}, {"thin", 100}, {"light", 300}, {"regular", 400}, {"normal", 400},
		{"book", 400}, {"medium", 500}, {"bold", 700}, {"black", 900}, {"heavy", 900},
	}
	for n in NAMES do if strings.contains(s, n.name) do return n.weight, true
	return 0, false
}
