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
	Arrow_Up,
	Arrow_Down,
	Case_Sensitive,
	Whole_Word,
	Regex,
	Scissors,
	Copy,
	Clipboard,
	Select_All,
	Go_To,
	Search,
}

// Codepoints in assets/fonts/lucide.ttf (see lucide-static's font/codepoints.json)
ICON_GLYPHS := [Icon]string {
	.Chevron_Left    = "",
	.Chevron_Right   = "",
	.Chevron_Down    = "",
	.Sidebar         = "", // panel-left
	.Settings        = "",
	.Close           = "", // x
	.Restart         = "", // rotate-ccw
	.Terminal        = "", // square-terminal
	.Maximize        = "", // maximize-2
	.Restore         = "", // minimize-2
	.Eye             = "",
	.Code            = "",
	.Check           = "",
	.Image_Off       = "",
	.Move_Horizontal = "", // move-horizontal
	.Fold_Horizontal = "", // fold-horizontal
	.File_Text       = "", // file-text
	.File_Code       = "", // file-code
	.Plus            = "",
	.Minus           = "",
	.Pencil          = "",
	.Trash           = "", // trash-2
	.Alert           = "", // triangle-alert
	.Folder_Plus     = "", // folder-plus
	.File_Plus       = "", // file-plus
	.Folder_Open     = "", // folder-open
	.Arrow_Up        = "\ue04a", // arrow-up
	.Arrow_Down      = "\ue042", // arrow-down
	.Case_Sensitive  = "\ue3d9", // case-sensitive
	.Whole_Word      = "\ue3df", // whole-word
	.Regex           = "\ue1fc", // regex
	.Scissors        = "\ue14e", // scissors
	.Copy            = "\ue09e", // copy
	.Clipboard       = "\ue3e8", // clipboard-paste
	.Select_All      = "\ue1cb", // box-select
	.Go_To           = "\ue0a2", // corner-down-right
	.Search          = "\ue151", // search
}

// The color lives here rather than in backgroundColor, which Clay would draw
// as a filled rectangle
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
}
