package sdl3

// Copied from Odin's vendor:sdl3 (SDL 3.4.2); only this file and the
// foreign import in ttf/sdl3_ttf.odin differ. SDL is linked statically from
// the library build.py builds; the system libraries are those its CMake
// package lists for static linking.

when ODIN_OS == .Windows {
	@(export) foreign import lib {
		"../../build/obj/sdl/lib/SDL3-static.lib",
		"system:kernel32.lib",
		"system:user32.lib",
		"system:gdi32.lib",
		"system:winmm.lib",
		"system:imm32.lib",
		"system:ole32.lib",
		"system:oleaut32.lib",
		"system:version.lib",
		"system:uuid.lib",
		"system:advapi32.lib",
		"system:setupapi.lib",
		"system:shell32.lib",
		"system:dinput8.lib",
	}
} else when ODIN_OS == .Darwin {
	@(export) foreign import lib {
		"../../build/obj/sdl/lib/libSDL3.a",
		"system:Cocoa.framework",
		"system:Carbon.framework",
		"system:CoreVideo.framework",
		"system:CoreMedia.framework",
		"system:CoreAudio.framework",
		"system:AudioToolbox.framework",
		"system:AVFoundation.framework",
		"system:Foundation.framework",
		"system:IOKit.framework",
		"system:ForceFeedback.framework",
		"system:GameController.framework",
		"system:CoreHaptics.framework",
		"system:Metal.framework",
		"system:QuartzCore.framework",
		"system:UniformTypeIdentifiers.framework",
		"system:iconv",
	}
} else {
	// X11, Wayland and the rest are loaded at runtime with dlopen.
	@(export) foreign import lib {
		"../../build/obj/sdl/lib/libSDL3.a",
		"system:m",
		"system:dl",
		"system:pthread",
	}
}
