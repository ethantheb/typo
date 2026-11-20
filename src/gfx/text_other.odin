#+build !windows
package gfx


// Subpixel text is only on by default on Windows; asked for, it assumes RGB
system_subpixel :: proc() -> (cleartype: bool, order: i32) {
	return false, 1
}
