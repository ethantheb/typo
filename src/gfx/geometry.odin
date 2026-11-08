package gfx

// A rectangle in logical pixels
Rect :: struct {
	x, y, w, h: f32,
}


rect_contains :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}
