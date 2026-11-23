#+build !windows
package editor

import clay "../vendor/clay-odin"
import sdl "../vendor/sdl3"

// Elsewhere the window keeps the system's frame (see window_frame.odin)
frame_platform_init :: proc(window: ^sdl.Window) -> bool {
	return false
}


frame_platform_border :: proc(color: clay.Color) {}
