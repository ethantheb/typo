package mdview

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode"

import "../buffer"
import "../markdown"
import sdl "../../vendor/sdl3"
import "../gfx"
import stbi "vendor:stb/image"
import "../textedit"

// Links and images in the rendered Markdown view. Ctrl+click opens web links in
// the browser and file links (relative to the document, or wikilinks found in
// the workspace) in the editor, at the heading a "#..." names, and footnote
// references at their definition. Local images (and ![[embeds]] of them) are
// decoded by a few worker threads and uploaded as textures; until then, and for
// remote ones, a placeholder shows


// --- Images ------------------------------------------------------------------------

// Larger images are scaled down to this size when decoded
@(private)
IMAGE_MAX :: 2048

// Unused image textures are dropped after this many frames
@(private)
IMAGE_EVICT_FRAMES :: 600

// Threads decoding images
@(private)
IMAGE_THREADS :: 4


@(private)
Image_State :: enum u8 {
	Loading,
	Ready,
	Failed, // missing, unreadable, or remote
}

@(private)
Image :: struct {
	state:     Image_State,
	texture:   ^sdl.Texture,
	w, h:      int, // also while loading again, if it was decoded before
	last_used: u64,
	job:       ^Image_Job,
}

// Shared with a decoding thread until `done`. Its memory is from the heap
// allocator, whichever thread frees it
@(private = "file")
Image_Job :: struct {
	path:   string,
	done:   bool, // atomic
	pixels: []u8, // RGBA
	w, h:   int,
}


@(private = "file")
images: map[string]^Image // by full path

// The size of each image decoded so far, so one whose texture was dropped is
// laid out at its size while it loads again
@(private = "file")
image_sizes: map[string][2]int

@(private = "file")
decoders: thread.Pool

@(private = "file")
decoders_running: bool


// The image at `path` (a full path or a URL), loading it if it's new
@(private)
get_image :: proc(path: string) -> ^Image {
	if img, ok := images[path]; ok {
		img.last_used = env.input().frame
		return img
	}

	img := new(Image)
	img.last_used = env.input().frame
	images[strings.clone(path)] = img
	if has_scheme(path) {
		img.state = .Failed
		return img
	}
	if size, ok := image_sizes[path]; ok {
		img.w, img.h = size.x, size.y
	}

	// Decode it on a worker thread
	if !decoders_running {
		thread.pool_init(&decoders, runtime.heap_allocator(), IMAGE_THREADS)
		thread.pool_start(&decoders)
		decoders_running = true
	}
	job := new(Image_Job, runtime.heap_allocator())
	job.path = strings.clone(path, runtime.heap_allocator())
	img.job = job
	thread.pool_add_task(&decoders, runtime.heap_allocator(), decode_image, job)

	return img
}


@(private = "file")
decode_image :: proc(task: thread.Task) {
	job := (^Image_Job)(task.data)
	defer {
		sync.atomic_store(&job.done, true)
		if env.wake != nil do env.wake(nil)
	}

	// Read and decode the file
	data, err := os.read_entire_file(job.path, runtime.heap_allocator())
	if err != nil do return
	defer delete(data, runtime.heap_allocator())

	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)

	// Keep its pixels, scaled down if it's too large
	ow, oh := int(w), int(h)
	if ow > IMAGE_MAX || oh > IMAGE_MAX {
		f := f32(IMAGE_MAX) / f32(max(ow, oh))
		ow, oh = max(int(f32(ow) * f), 1), max(int(f32(oh) * f), 1)
		job.pixels = make([]u8, ow * oh * 4, runtime.heap_allocator())
		stbi.resize_uint8(pixels, w, h, 0, raw_data(job.pixels), i32(ow), i32(oh), 0, 4)
	} else {
		job.pixels = make([]u8, ow * oh * 4, runtime.heap_allocator())
		copy(job.pixels, pixels[:ow * oh * 4])
	}
	job.w, job.h = ow, oh
}


// Uploads decoded images and drops unused ones. Returns true if any finished
// loading (their layouts change)
@(private)
images_poll :: proc() -> bool {
	changed := false
	if decoders_running {
		for _ in thread.pool_pop_done(&decoders) {}
	}

	stale := make([dynamic]string, context.temp_allocator)
	for path, img in images {
		// A decoded image becomes a texture
		if job := img.job; job != nil && sync.atomic_load(&job.done) {
			img.state = .Failed
			img.w, img.h = 0, 0
			if job.pixels != nil && gfx.renderer != nil {
				upload_image(path, img, job)
			}
			free_job(job)
			img.job = nil
			changed = true
		}

		unused := img.job == nil && env.input().frame - img.last_used > IMAGE_EVICT_FRAMES
		if unused do append(&stale, path)
	}

	// Drop the unused ones
	for path in stale {
		img := images[path]
		key, _ := delete_key(&images, path)
		if img.texture != nil do sdl.DestroyTexture(img.texture)
		free(img)
		delete(key)
	}

	return changed
}


// Makes a decoded image's texture. Without one the image stays Failed
@(private = "file")
upload_image :: proc(path: string, img: ^Image, job: ^Image_Job) {
	img.texture = sdl.CreateTexture(gfx.renderer, .RGBA32, .STATIC, i32(job.w), i32(job.h))
	if img.texture == nil do return

	_ = sdl.UpdateTexture(img.texture, nil, raw_data(job.pixels), i32(job.w * 4))
	_ = sdl.SetTextureBlendMode(img.texture, {.BLEND})
	img.w, img.h = job.w, job.h
	img.state = .Ready

	if path not_in image_sizes {
		image_sizes[strings.clone(path)] = {job.w, job.h}
	}
}


@(private = "file")
free_job :: proc(job: ^Image_Job) {
	delete(job.pixels, runtime.heap_allocator())
	delete(job.path, runtime.heap_allocator())
	free(job, runtime.heap_allocator())
}


images_destroy :: proc() {
	if decoders_running {
		thread.pool_join(&decoders)
		thread.pool_destroy(&decoders)
		decoders_running = false
	}

	// Images
	for path, img in images {
		if img.job != nil do free_job(img.job)
		if img.texture != nil do sdl.DestroyTexture(img.texture)
		free(img)
		delete(path)
	}
	delete(images)
	images = nil

	for path in image_sizes do delete(path)
	delete(image_sizes)
	image_sizes = nil

	// Wikilink targets
	wiki_clear()
	delete(wiki_paths)
	wiki_paths = nil
	wiki_files = 0
}


// An image destination as a full path (or the URL itself)
@(private)
image_path :: proc(e: ^View, dest: string) -> string {
	if has_scheme(dest) do return dest

	path := dest
	if q := strings.index_any(path, "#?"); q >= 0 {
		path = path[:q]
	}
	return relative_to_file(e, percent_decode(path))
}


// A path relative to the file's folder as a full path
@(private = "file")
relative_to_file :: proc(e: ^View, path: string) -> string {
	if filepath.is_abs(path) do return path

	full, _ := filepath.join({filepath.dir(e.path), path}, context.temp_allocator)
	return full
}


// --- Links -------------------------------------------------------------------------

// The link whose text is under a point: its destination
@(private)
link_at :: proc(e: ^View, x, y: f32) -> (target: string, wiki, ok: bool) {
	line, ly := line_at_y(e, y) or_return
	L := line_layout(e, line)
	lx := x - e.view.x - e.mdv.col_x
	start := buffer.line_start(&e.buf, line)

	// The link text run under the point
	hit := -1
	for run in L.runs {
		if run.kind != .Text || run.style & {.Underline, .Super} == {} {
			continue
		}

		r := L.rows[run.row]
		if lx >= run.x && lx <= run.x + run.w && ly >= r.y && ly <= r.y + r.h {
			hit = start + int(run.lo)
			break
		}
	}
	b := hit >= 0 ? block_at(e, line) : nil
	if b == nil do return

	// The link span it is in
	for s in b.spans {
		#partial switch s.kind {
		case .Link, .Image, .Autolink, .Url, .Wikilink, .Footnote_Ref:
		case: continue
		}

		lo := markdown.block_to_doc(&b.bt, int(s.open_hi))
		hi := markdown.block_to_doc(&b.bt, int(s.close_lo))
		if hit < lo || hit > hi {
			continue
		}

		// Its destination
		url := b.bt.text[s.url[0]:s.url[1]]
		#partial switch s.kind {
		case .Link, .Image:
			if s.reference {
				url = markdown.reference_destination(e.md, &e.buf, url) or_return
			}
			if !s.embed do url = markdown.unescape(url)

		case .Url:
			switch {
			case strings.has_prefix(url, "www."):
				url = strings.concatenate({"https://", url}, context.temp_allocator)
			case !has_scheme(url):
				url = strings.concatenate({"mailto:", url}, context.temp_allocator)
			}

		case .Autolink:
			if !has_scheme(url) {
				url = strings.concatenate({"mailto:", url}, context.temp_allocator)
			}

		case .Footnote_Ref:
			label := b.bt.text[s.open_hi:s.close_lo]
			url = strings.concatenate({"#^", label}, context.temp_allocator)
		}

		return url, s.kind == .Wikilink || s.embed, true
	}
	return
}


// Whether the pointer is over something a click acts on: a task box, or a link
// with Ctrl held
@(private)
pointer_target :: proc(e: ^View) -> bool {
	input := env.input()
	p := input.mouse_pos
	if _, _, ok := checkbox_at(e, p.x, p.y); ok {
		return true
	}
	if input.mods & sdl.KMOD_CTRL == {} do return false

	_, _, ok := link_at(e, p.x, p.y)
	return ok
}


// Whether a link destination starts with a URL scheme ("https:", "mailto:").
// One letter before ':' is a Windows drive
@(private = "file")
has_scheme :: proc(s: string) -> bool {
	colon := strings.index_byte(s, ':')
	if colon < 2 do return false

	for c in transmute([]u8)s[:colon] {
		if !is_scheme_char(c) do return false
	}
	return true
}


@(private = "file")
is_scheme_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') ||
	       (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') ||
	       c == '+' ||
	       c == '.' ||
	       c == '-'
}


// Opens a link's destination, at the heading its "#..." names
@(private)
open_link :: proc(e: ^View, target: string, wiki: bool) {
	if has_scheme(target) {
		_ = sdl.OpenURL(strings.clone_to_cstring(target, context.temp_allocator))
		return
	}

	// The file and the heading
	path, heading := target, ""
	if hash := strings.index_byte(path, '#'); hash >= 0 {
		path, heading = path[:hash], path[hash + 1:]
	}
	path, heading = percent_decode(path), percent_decode(heading)

	// The file's full path; no path is this document
	full := e.path
	if path != "" {
		found: bool
		if wiki {
			full, found = wiki_path(e, path)
		} else {
			full = relative_to_file(e, path)
			found = os.exists(full) && !os.is_dir(full)
		}
		if !found do return
	}

	if full == e.path {
		if heading != "" do jump_to_heading(e, heading)
		return
	}
	env.open_file(full, heading)
}


// Puts the caret on the first heading whose text matches `name`, compared as
// slugs ("My Heading" matches "my-heading"), or for "^label" on the footnote
// definition with that label
jump_to_heading :: proc(e: ^View, name: string) {
	if e.md == nil do return

	textedit.take_changes(e)
	markdown.doc_update(e.md, &e.buf, max(int), 0)

	// A footnote definition
	if strings.has_prefix(name, "^") {
		labels := markdown.doc_labels(e.md, &e.buf)
		if line, ok := labels[markdown.label_hash(name[1:], true)]; ok {
			at := buffer.line_start(&e.buf, line)
			textedit.set_single_selection(e, {at, at, -1})
			e.mdv.caretless = false
			e.reveal = true
		}
		return
	}

	// A heading
	want := heading_slug(name)
	for l, i in e.md.lines {
		line := i
		text: string
		#partial switch l.kind {
		case .Atx_Heading:
			t, _ := textedit.line_text(e, i)
			d := markdown.line_detail(e.md, i, t)
			text_end := d.close != {} ? int(d.close[0]) : len(t)
			text = t[d.open[1]:text_end]
		case .Setext_Underline:
			line = i - 1
			text, _ = textedit.line_text(e, line)
		case:
			continue
		}
		if heading_slug(text) != want do continue

		at := buffer.line_start(&e.buf, line)
		textedit.set_single_selection(e, {at, at, -1})
		e.mdv.caretless = false
		e.reveal = true
		return
	}
}


// Letters and digits lowercased, spaces as '-', other punctuation dropped
@(private = "file")
heading_slug :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.trim_space(s) {
		switch {
		case unicode.is_letter(r) || unicode.is_digit(r) || r == '_':
			strings.write_rune(&sb, unicode.to_lower(r))
		case r == ' ' || r == '-':
			strings.write_byte(&sb, '-')
		}
	}
	return strings.to_string(sb)
}


// --- Wikilinks ---------------------------------------------------------------------

// Resolved wikilink and embed targets by the document's folder and the target
// ("" when not found), for the workspace index of `wiki_files` files
@(private = "file")
wiki_paths: map[string]string

@(private = "file")
wiki_files: int


// A wikilink or embed target ("Note", "folder/Note", "pic.png") as a full
// path: "<target>.md", then the target itself, next to the document, else a
// file whose path ends with it in the workspace (indexed in the background, so
// not found until it is)
@(private)
wiki_path :: proc(e: ^View, target: string) -> (path: string, ok: bool) {
	wiki_poll()

	key := strings.concatenate({filepath.dir(e.path), "\x00", target}, context.temp_allocator)
	if p, found := wiki_paths[key]; found {
		return p, p != ""
	}

	md_name := strings.concatenate({target, ".md"}, context.temp_allocator)
	names := [2]string{md_name, target}
	search: {
		// Next to the document
		for name in names {
			path = relative_to_file(e, name)
			if os.exists(path) && !os.is_dir(path) {
				break search
			}
		}
		path = ""

		// A file in the workspace whose path ends with it
		env.ensure_index()
		for name in names {
			want, _ := strings.replace_all(name, "\\", "/", context.temp_allocator)
			for f in env.files() {
				if len(f) <= len(want) || !is_separator(f[len(f) - len(want) - 1]) {
					continue
				}

				tail := f[len(f) - len(want):]
				rest, _ := strings.replace_all(tail, "\\", "/", context.temp_allocator)
				if strings.equal_fold(rest, want) {
					path = f
					break search
				}
			}
		}
	}

	wiki_paths[strings.clone(key)] = strings.clone(path)
	return path, path != ""
}


// Forgets resolved targets when the workspace index has grown. Returns true if
// it did (layouts showing embeds may change)
@(private)
wiki_poll :: proc() -> bool {
	if wiki_files == len(env.files()) do return false

	wiki_files = len(env.files())
	if len(wiki_paths) == 0 do return false

	wiki_clear()
	return true
}


@(private = "file")
wiki_clear :: proc() {
	for key, path in wiki_paths {
		delete(key)
		delete(path)
	}
	clear(&wiki_paths)
}


// --- Paths -------------------------------------------------------------------------

// Decodes %XX escapes ("my%20notes.md")
@(private = "file")
percent_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s

	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_uint(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&sb, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}


@(private = "file")
is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}
