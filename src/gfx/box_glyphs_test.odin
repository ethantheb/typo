package gfx

import "core:fmt"
import "core:testing"

// Cell sizes (pixels) and light line widths the glyphs are checked at
@(private = "file")
TEST_WIDTHS := []int{6, 7, 8, 9, 10, 11, 13, 20}
@(private = "file")
TEST_HEIGHTS := []int{12, 14, 17, 22, 23, 27, 28, 45}
@(private = "file")
TEST_LINES := []f32{1, 2, 3}


// A glyph rasterized in a cell
@(private = "file")
Test_Mask :: struct {
	w, h:   int,
	pixels: []u8,
}


@(private = "file")
raster :: proc(r: rune, w, h: int, line: f32) -> Test_Mask {
	m := Test_Mask{w, h, make([]u8, w * h, context.temp_allocator)}
	box_glyph_raster(box_glyph_slot(r), w, h, line, m.pixels)
	return m
}


@(private = "file")
at :: proc(m: Test_Mask, x, y: int) -> u8 {
	return m.pixels[y * m.w + x]
}


// A column of the mask, or a row
@(private = "file")
column :: proc(m: Test_Mask, x: int) -> []u8 {
	out := make([]u8, m.h, context.temp_allocator)
	for y in 0 ..< m.h do out[y] = at(m, x, y)
	return out
}


@(private = "file")
row :: proc(m: Test_Mask, y: int) -> []u8 {
	return m.pixels[y * m.w:][:m.w]
}


@(private = "file")
same :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for v, i in a {
		if v != b[i] do return false
	}
	return true
}


@(private = "file")
empty :: proc(a: []u8) -> bool {
	for v in a {
		if v != 0 do return false
	}
	return true
}


// Which characters are drawn as shapes
@(test)
test_box_glyph_ranges :: proc(t: ^testing.T) {
	for r in ([]rune{'─', '╭', '█', '░', '▟', 0xE0B0, 0xE0BF, 0x1FB00, 0x1FB94}) {
		testing.expectf(t, is_box_glyph(r), "U+%X is drawn as shapes", r)
	}
	for r in ([]rune{'a', ' ', 0x24FF, 0x25A0, 0xE0AF, 0xE0C0, 0x1FB93, 0x1FB95}) {
		testing.expectf(t, !is_box_glyph(r), "U+%X is drawn from the font", r)
	}

	_, one := box_glyph_in("█")
	_, two := box_glyph_in("██")
	_, combined := box_glyph_in("─́")
	_, none := box_glyph_in("")
	testing.expect(t, one)
	testing.expect(t, !two)
	testing.expect(t, !combined)
	testing.expect(t, !none)

	for ops, slot in BOX_GLYPHS {
		testing.expectf(t, len(ops) <= BOX_GLYPH_OPS, "slot %d has %d shapes", slot, len(ops))
	}
}


// Blocks fill their part of the cell exactly: no seams at the cell's edges,
// halves and quadrants that tile it, shades at their coverage
@(test)
test_box_glyph_blocks :: proc(t: ^testing.T) {
	for w in TEST_WIDTHS {
		for h in TEST_HEIGHTS {
			size := fmt.tprintf("%dx%d", w, h)
			full := raster('█', w, h, 1)
			upper, lower := raster('▀', w, h, 1), raster('▄', w, h, 1)
			left, right := raster('▌', w, h, 1), raster('▐', w, h, 1)
			quads := [4]Test_Mask {
				raster('▘', w, h, 1),
				raster('▝', w, h, 1),
				raster('▖', w, h, 1),
				raster('▗', w, h, 1),
			}
			three := raster('▛', w, h, 1)
			shades := [3]Test_Mask{raster('░', w, h, 1), raster('▒', w, h, 1), raster('▓', w, h, 1)}

			for y in 0 ..< h {
				for x in 0 ..< w {
					testing.expectf(t, at(full, x, y) == 255, "%s █ at %d,%d", size, x, y)

					halves := int(at(upper, x, y)) + int(at(lower, x, y))
					sides := int(at(left, x, y)) + int(at(right, x, y))
					testing.expectf(t, halves == 255, "%s ▀▄ at %d,%d: %d", size, x, y, halves)
					testing.expectf(t, sides == 255, "%s ▌▐ at %d,%d: %d", size, x, y, sides)

					quarters := 0
					for q in quads do quarters += int(at(q, x, y))
					testing.expectf(t, quarters == 255, "%s quadrants at %d,%d", size, x, y)

					q := max(at(quads[0], x, y), at(quads[1], x, y), at(quads[2], x, y))
					testing.expectf(t, at(three, x, y) == q, "%s ▛ at %d,%d", size, x, y)

					testing.expect_value(t, at(shades[0], x, y), 64)
					testing.expect_value(t, at(shades[1], x, y), 128)
					testing.expect_value(t, at(shades[2], x, y), 191)
				}
			}
		}
	}
}


// Lines run the cell's full length at the same pixels in every cell of a size,
// so they join across cells and rows; corners and crossings join without notches
@(test)
test_box_glyph_lines :: proc(t: ^testing.T) {
	for w in TEST_WIDTHS {
		for h in TEST_HEIGHTS {
			for line in TEST_LINES {
				if line * 2 >= f32(w) / 2 do continue
				check_lines(t, w, h, line)
			}
		}
	}
}


@(private = "file")
check_lines :: proc(t: ^testing.T, w, h: int, line: f32) {
	size := fmt.tprintf("%dx%d line %v", w, h, line)
	vertical := raster('│', w, h, line)
	horizontal := raster('─', w, h, line)

	// │ is the same solid columns in every row, a line width wide
	cols: [2]int = {-1, -1}
	for x in 0 ..< w {
		if at(vertical, x, 0) == 0 do continue
		testing.expectf(t, at(vertical, x, 0) == 255, "%s │ column %d is solid", size, x)
		if cols[0] < 0 do cols[0] = x
		cols[1] = x + 1
	}
	testing.expectf(t, cols[1] - cols[0] == int(line), "%s │ is %v wide", size, cols)
	for y in 1 ..< h {
		testing.expectf(t, same(row(vertical, y), row(vertical, 0)), "%s │ row %d", size, y)
	}

	// ─ is the same solid rows in every column
	rows: [2]int = {-1, -1}
	for y in 0 ..< h {
		if at(horizontal, 0, y) == 0 do continue
		testing.expectf(t, at(horizontal, 0, y) == 255, "%s ─ row %d is solid", size, y)
		if rows[0] < 0 do rows[0] = y
		rows[1] = y + 1
	}
	testing.expectf(t, rows[1] - rows[0] == int(line), "%s ─ is %v tall", size, rows)
	for x in 1 ..< w {
		col := column(horizontal, x)
		testing.expectf(t, same(col, column(horizontal, 0)), "%s ─ column %d", size, x)
	}

	// Corners and crossings are the parts of │ and ─ they reach
	Joined :: struct {
		r:                     rune,
		up, down, left, right: bool,
	}
	joined := []Joined {
		{'┌', false, true, false, true},
		{'┐', false, true, true, false},
		{'└', true, false, false, true},
		{'┘', true, false, true, false},
		{'├', true, true, false, true},
		{'┤', true, true, true, false},
		{'┬', false, true, true, true},
		{'┴', true, false, true, true},
		{'┼', true, true, true, true},
	}
	for j in joined {
		m := raster(j.r, w, h, line)
		for y in 0 ..< h {
			for x in 0 ..< w {
				reach_v := (j.up && y < rows[1]) || (j.down && y >= rows[0])
				reach_h := (j.left && x < cols[1]) || (j.right && x >= cols[0])
				in_v := at(vertical, x, y) == 255 && reach_v
				in_h := at(horizontal, x, y) == 255 && reach_h
				want: u8 = in_v || in_h ? 255 : 0
				testing.expectf(t, at(m, x, y) == want, "%s %c at %d,%d", size, j.r, x, y)
			}
		}
	}

	check_edges(t, w, h, line)
}


// Every straight box drawing character meets its neighbors: what reaches each
// edge of the cell is nothing, or exactly what a light, heavy or double line
// leaves there
@(private = "file")
check_edges :: proc(t: ^testing.T, w, h: int, line: f32) {
	size := fmt.tprintf("%dx%d line %v", w, h, line)
	side_lines := [3]rune{'─', '━', '═'}
	top_lines := [3]rune{'│', '┃', '║'}

	sides: [3][]u8
	tops: [3][]u8
	for r, i in side_lines do sides[i] = column(raster(r, w, h, line), 0)
	for r, i in top_lines do tops[i] = row(raster(r, w, h, line), 0)

	for r in rune(0x2500) ..= 0x257F {
		// Diagonals and arcs end between pixels
		if r >= 0x256D && r <= 0x2573 {
			continue
		}

		m := raster(r, w, h, line)
		edges := [4][]u8{column(m, 0), column(m, w - 1), row(m, 0), row(m, h - 1)}
		for edge, e in edges {
			allowed := e < 2 ? sides : tops
			ok := empty(edge)
			for a in allowed {
				ok ||= same(edge, a)
			}
			testing.expectf(t, ok, "%s U+%X %c: edge %d doesn't meet a line", size, r, r, e)
		}
	}
}


// Every glyph rasterizes to something at every size (narrower cells round
// eighths of their width away), and the arcs end where the straight lines they
// join do
@(test)
test_box_glyph_all :: proc(t: ^testing.T) {
	for w in TEST_WIDTHS {
		for h in TEST_HEIGHTS {
			for slot in 0 ..< BOX_GLYPH_COUNT {
				if len(BOX_GLYPHS[slot]) == 0 do continue

				mask := make([]u8, w * h, context.temp_allocator)
				box_glyph_raster(slot, w, h, 1, mask)
				if w >= 8 {
					testing.expectf(t, !empty(mask), "%dx%d slot %d draws nothing", w, h, slot)
				}
			}

			// ╭ goes down where │ does and right where ─ does
			ARC_TOLERANCE :: 2
			arc := raster('╭', w, h, 1)
			down := row(raster('│', w, h, 1), h - 1)
			right := column(raster('─', w, h, 1), w - 1)
			for v, x in row(arc, h - 1) {
				near := abs(int(v) - int(down[x])) <= ARC_TOLERANCE
				testing.expectf(t, near, "%dx%d ╭ bottom at %d: %d", w, h, x, v)
			}
			for v, y in column(arc, w - 1) {
				near := abs(int(v) - int(right[y])) <= ARC_TOLERANCE
				testing.expectf(t, near, "%dx%d ╭ right at %d: %d", w, h, y, v)
			}
		}
	}
	free_all(context.temp_allocator)
}
