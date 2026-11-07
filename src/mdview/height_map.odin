package mdview

// Per-line heights in chunks with running sums, so that finding the line at a
// y position and splicing lines in or out are cheap on large documents.

@(private = "file")
HM_CHUNK :: 512

@(private)
Height_Map :: struct {
	chunks: [dynamic]Height_Chunk,
	total:  f64, // with pad
	lines:  int,
	pad:    f64, // space above the first line
}

@(private)
Height_Chunk :: struct {
	h:   [dynamic]f32,
	sum: f64,
}

@(private)
hm_destroy :: proc(hm: ^Height_Map) {
	for c in hm.chunks do delete(c.h)
	delete(hm.chunks)
	hm^ = {}
}

// The chunk and index within it of a line (or one past the last line).
@(private = "file")
hm_locate :: proc(hm: ^Height_Map, line: int) -> (c, k: int) {
	line := line
	for &ch, i in hm.chunks {
		if line < len(ch.h) || i == len(hm.chunks) - 1 do return i, min(line, len(ch.h))
		line -= len(ch.h)
	}
	return 0, 0
}

@(private)
hm_get :: proc(hm: ^Height_Map, line: int) -> f32 {
	if line < 0 || line >= hm.lines do return 0
	c, k := hm_locate(hm, line)
	return hm.chunks[c].h[k]
}

@(private)
hm_set :: proc(hm: ^Height_Map, line: int, h: f32) {
	if line < 0 || line >= hm.lines do return
	c, k := hm_locate(hm, line)
	ch := &hm.chunks[c]
	d := f64(h) - f64(ch.h[k])
	ch.h[k] = h
	ch.sum += d
	hm.total += d
}

// The y of a line's top.
@(private)
hm_y :: proc(hm: ^Height_Map, line: int) -> f64 {
	y := hm.pad
	line := clamp(line, 0, hm.lines)
	for &ch in hm.chunks {
		if line < len(ch.h) {
			for h in ch.h[:line] do y += f64(h)
			return y
		}
		line -= len(ch.h)
		y += ch.sum
	}
	return y
}

// The line at y, and its top.
@(private)
hm_find :: proc(hm: ^Height_Map, y: f64) -> (line: int, top: f64) {
	if hm.lines == 0 do return 0, hm.pad
	top = hm.pad
	for &ch, ci in hm.chunks {
		if y < top + ch.sum || ci == len(hm.chunks) - 1 {
			for h, k in ch.h {
				if y < top + f64(h) || k == len(ch.h) - 1 do return line + k, top
				top += f64(h)
			}
			return line, top
		}
		top += ch.sum
		line += len(ch.h)
	}
	return hm.lines - 1, top
}

// Removes `removed` lines at `at` and inserts lines of the given heights there.
@(private)
hm_splice :: proc(hm: ^Height_Map, at, removed: int, inserted: []f32) {
	if len(hm.chunks) == 0 do append(&hm.chunks, Height_Chunk{})
	at := clamp(at, 0, hm.lines)
	removed := min(removed, hm.lines - at)
	hm.lines -= removed
	for removed > 0 {
		c, k := hm_locate(hm, at)
		ch := &hm.chunks[c]
		take := min(removed, len(ch.h) - k)
		remove_range(&ch.h, k, k + take)
		removed -= take
		if len(ch.h) == 0 && len(hm.chunks) > 1 {
			delete(ch.h)
			ordered_remove(&hm.chunks, c)
		}
	}
	if len(inserted) > 0 {
		c, k := hm_locate(hm, at)
		hm.lines += len(inserted)
		if len(hm.chunks[c].h) + len(inserted) <= 2 * HM_CHUNK {
			inject_at(&hm.chunks[c].h, k, ..inserted)
		} else {
			// Re-chunk the chunk with the new lines in it.
			all := make([dynamic]f32, 0, len(hm.chunks[c].h) + len(inserted), context.temp_allocator)
			append(&all, ..hm.chunks[c].h[:k])
			append(&all, ..inserted)
			append(&all, ..hm.chunks[c].h[k:])
			delete(hm.chunks[c].h)
			ordered_remove(&hm.chunks, c)
			parts := make([dynamic]Height_Chunk, 0, len(all) / HM_CHUNK + 1, context.temp_allocator)
			for lo := 0; lo < len(all); lo += HM_CHUNK {
				h := make([dynamic]f32, 0, HM_CHUNK)
				append(&h, ..all[lo:min(lo + HM_CHUNK, len(all))])
				append(&parts, Height_Chunk{h = h})
			}
			inject_at(&hm.chunks, c, ..parts[:])
		}
	}
	hm.total = hm.pad
	for &ch in hm.chunks {
		ch.sum = 0
		for h in ch.h do ch.sum += f64(h)
		hm.total += ch.sum
	}
}
