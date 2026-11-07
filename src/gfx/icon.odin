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
	File_Text,
	File_Code,
	Plus,
	Minus,
	Pencil,
	Trash,
	Alert,
	Folder_Plus,
	File_Plus,
	Folder_Open,
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
	.File_Text     = "\ue0cc", // file-text
	.File_Code     = "\ue0c3", // file-code
	.Plus          = "\ue13d",
	.Minus         = "\ue11c",
	.Pencil        = "\ue1f9",
	.Trash         = "\ue18e", // trash-2
	.Alert         = "\ue193", // triangle-alert
	.Folder_Plus   = "\ue0d9", // folder-plus
	.File_Plus     = "\ue0c9", // file-plus
	.Folder_Open   = "\ue247", // folder-open
}

// The color lives here rather than in backgroundColor, which Clay would draw
// as a filled rectangle.
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
}
