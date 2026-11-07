package gfx

import clay "../../vendor/clay-odin"

Icon :: enum u8 {
	Chevron_Left,
	Chevron_Right,
	Chevron_Down,
	Sidebar,
	Settings,
	Close,
	Restart,
	Terminal,
	Maximize,
	Restore,
	Eye,
	Code,
	Check,
	Image_Off,
	Move_Horizontal,
	Fold_Horizontal,
}

// Codepoints in assets/fonts/lucide.ttf (see lucide-static's font/codepoints.json).
ICON_GLYPHS := [Icon]string {
	.Chevron_Left  = "",
	.Chevron_Right = "",
	.Chevron_Down  = "",
	.Sidebar       = "", // panel-left
	.Settings      = "",
	.Close         = "", // x
	.Restart       = "", // rotate-ccw
	.Terminal      = "", // square-terminal
	.Maximize      = "", // maximize-2
	.Restore       = "", // minimize-2
	.Eye           = "",
	.Code          = "",
	.Check         = "",
	.Image_Off     = "",
	.Move_Horizontal = "\ue1c6", // move-horizontal
	.Fold_Horizontal = "\ue43b", // fold-horizontal
}

// The color lives here rather than in backgroundColor, which Clay would draw
// as a filled rectangle.
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
}
