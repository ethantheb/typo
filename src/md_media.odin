package editor

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "buffer"
import "markdown"
import sdl "../vendor/sdl3"
import stbi "vendor:stb/image"

// Links and images in the rendered Markdown view. Ctrl+click opens web links in
// the browser and file links (relative to the document, or wikilinks found in
// the workspace) in the editor. Local images are decoded on a thread each and
// uploaded as textures; until then, and for remote ones, a placeholder shows.

// Larger images are scaled down to this size when decoded.
MD_IMAGE_MAX :: 2048
// Unused image textures are dropped after this many frames.
MD_IMAGE_EVICT_FRAMES :: 600

Md_Image_State :: enum u8 {
	Loading,
	Ready,
	Failed, // missing, unreadable, or remote
}

Md_Image :: struct {
	state:     Md_Image_State,
	texture:   ^sdl.Texture,
	w, h:      int,
	last_used: u64,
	job:       ^Image_Job,
}

// Shared with the decoding thread until `done`.
@(private = "file")
Image_Job :: struct {
	path:   string,
	thread: ^thread.Thread,
	done:   bool, // atomic
	pixels: []u8, // RGBA
	w, h:   int,
}

@(private = "file")
images: map[string]^Md_Image // by full path

// The image at `path` (a full path or a URL), loading it if it's new.
md_image :: proc(path: string) -> ^Md_Image {
	if img, ok := images[path]; ok {
		img.last_used = g.frame
		return img
	}
	img := new(Md_Image)
	img.last_used = g.frame
	images[strings.clone(path)] = img
	if has_scheme(path) || !os.exists(path) {
		img.state = .Failed
		return img
	}
	job := new(Image_Job)
	job.path = strings.clone(path)
	img.job = job
	job.thread = thread.create_and_start_with_poly_data(job, decode_image, init_context = runtime.default_context())
	return img
}

@(private = "file")
decode_image :: proc(job: ^Image_Job) {
	defer {
		sync.atomic_store(&job.done, true)
		wake_main_loop(nil)
	}
	data, err := os.read_entire_file(job.path, context.allocator)
	if err != nil do return
	defer delete(data)
	w, h, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)
	ow, oh := int(w), int(h)
	if ow > MD_IMAGE_MAX || oh > MD_IMAGE_MAX {
		f := f32(MD_IMAGE_MAX) / f32(max(ow, oh))
		ow, oh = max(int(f32(ow) * f), 1), max(int(f32(oh) * f), 1)
		job.pixels = make([]u8, ow * oh * 4)
		stbi.resize_uint8(pixels, w, h, 0, raw_data(job.pixels), i32(ow), i32(oh), 0, 4)
	} else {
		job.pixels = make([]u8, ow * oh * 4)
		copy(job.pixels, pixels[:ow * oh * 4])
	}
	job.w, job.h = ow, oh
}

// Uploads decoded images and drops unused ones. Returns true if any finished
// loading (their layouts change).
md_images_poll :: proc() -> bool {
	changed := false
	stale := make([dynamic]string, context.temp_allocator)
	for path, img in images {
		if job := img.job; job != nil && sync.atomic_load(&job.done) {
			img.state = .Failed
			if job.pixels != nil && g.renderer != nil {
				img.texture = sdl.CreateTexture(g.renderer, .RGBA32, .STATIC, i32(job.w), i32(job.h))
				if img.texture != nil {
					_ = sdl.UpdateTexture(img.texture, nil, raw_data(job.pixels), i32(job.w * 4))
					_ = sdl.SetTextureBlendMode(img.texture, {.BLEND})
					img.w, img.h = job.w, job.h
					img.state = .Ready
				}
			}
			free_job(job)
			img.job = nil
			changed = true
		}
		if img.job == nil && g.frame - img.last_used > MD_IMAGE_EVICT_FRAMES do append(&stale, path)
	}
	for path in stale {
		img := images[path]
		key, _ := delete_key(&images, path)
		if img.texture != nil do sdl.DestroyTexture(img.texture)
		free(img)
		delete(key)
	}
	return changed
}

// Waits for a decode job's thread and frees the job.
@(private = "file")
free_job :: proc(job: ^Image_Job) {
	thread.join(job.thread)
	thread.destroy(job.thread)
	delete(job.pixels)
	delete(job.path)
	free(job)
}

md_images_destroy :: proc() {
	for path, img in images {
		if img.job != nil do free_job(img.job)
		if img.texture != nil do sdl.DestroyTexture(img.texture)
		free(img)
		delete(path)
	}
	delete(images)
	images = nil
}

// An image destination as a full path (or the URL itself).
md_image_path :: proc(e: ^Editor, dest: string) -> string {
	if has_scheme(dest) do return dest
	path := dest
	if q := strings.index_any(path, "#?"); q >= 0 do path = path[:q]
	return relative_to_file(e, percent_decode(path))
}

// A path relative to the file's folder as a full path.
@(private = "file")
relative_to_file :: proc(e: ^Editor, path: string) -> string {
	if filepath.is_abs(path) do return path
	full, _ := filepath.join({filepath.dir(e.path), path}, context.temp_allocator)
	return full
}

// The link whose text is under a point: its destination.
md_link_at :: proc(e: ^Editor, x, y: f32) -> (target: string, wiki, ok: bool) {
	line, ly := md_line_at_y(e, y) or_return
	L := md_line_layout(e, line)
	lx := x - e.view.x - e.mdv.col_x
	start := buffer.line_start(&e.buf, line)
	hit := -1
	for run in L.runs {
		if run.kind != .Text || .Underline not_in run.style do continue
		r := L.rows[run.row]
		if lx >= run.x && lx <= run.x + run.w && ly >= r.y && ly <= r.y + r.h {
			hit = start + int(run.lo)
			break
		}
	}
	b := hit >= 0 ? md_block(e, line) : nil
	if b == nil do return
	for s in b.spans {
		#partial switch s.kind {
		case .Link, .Image, .Autolink, .Url, .Wikilink:
		case: continue
		}
		if hit < markdown.block_to_doc(&b.bt, int(s.open_hi)) || hit > markdown.block_to_doc(&b.bt, int(s.close_lo)) do continue
		url := b.bt.text[s.url[0]:s.url[1]]
		#partial switch s.kind {
		case .Link, .Image:
			if s.reference {
				url = markdown.reference_destination(e.md, &e.buf, url) or_return
			}
		case .Url:
			if strings.has_prefix(url, "www.") do url = strings.concatenate({"https://", url}, context.temp_allocator)
		case .Autolink:
			if !has_scheme(url) do url = strings.concatenate({"mailto:", url}, context.temp_allocator)
		}
		return url, s.kind == .Wikilink, true
	}
	return
}

// Whether a link destination starts with a URL scheme ("https:", "mailto:").
// One letter before ':' is a Windows drive.
@(private = "file")
has_scheme :: proc(s: string) -> bool {
	colon := strings.index_byte(s, ':')
	if colon < 2 do return false
	for c in transmute([]u8)s[:colon] {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-') do return false
	}
	return true
}

// Opens a link's destination.
md_open_link :: proc(e: ^Editor, target: string, wiki: bool) {
	if has_scheme(target) {
		_ = sdl.OpenURL(strings.clone_to_cstring(target, context.temp_allocator))
		return
	}
	path := target
	if hash := strings.index_byte(path, '#'); hash >= 0 do path = path[:hash]
	path = percent_decode(path)
	if path == "" do return
	if wiki && filepath.ext(path) == "" do path = strings.concatenate({path, ".md"}, context.temp_allocator)
	full := relative_to_file(e, path)
	if os.exists(full) && !os.is_dir(full) {
		g.pending = Open_File(strings.clone(full))
		return
	}
	// A wikilink names a note anywhere in the workspace.
	if wiki {
		name := filepath.base(path)
		for f in g.finder.files {
			if strings.equal_fold(filepath.base(f), name) {
				g.pending = Open_File(strings.clone(f))
				return
			}
		}
	}
}

// Decodes %XX escapes ("my%20notes.md").
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

// Whether the pointer is over something a click acts on: a task box, or a link
// with Ctrl held.
md_pointer_target :: proc(e: ^Editor) -> bool {
	if !editor_text_hit(e, g.mouse_pos) do return false
	if _, _, ok := md_checkbox_at(e, g.mouse_pos.x, g.mouse_pos.y); ok do return true
	if sdl.GetModState() & sdl.KMOD_CTRL == {} do return false
	_, _, ok := md_link_at(e, g.mouse_pos.x, g.mouse_pos.y)
	return ok
}
