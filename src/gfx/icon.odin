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
	Pin,
	Pin_Off,
	Git_Branch,
	Git_Compare,
	Undo,
	Refresh,
	Arrow_Right,
	Cloud_Upload,
	Cloud_Download,
	Chevron_Up,
	Folder,
	App_Window,
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
	.Pin             = "\ue259", // pin
	.Pin_Off         = "\ue2b6", // pin-off
	.Git_Branch     = "\ue0e2", // git-branch
	.Git_Compare     = "\ue359", // git-compare
	.Undo            = "\ue2a1", // undo-2
	.Refresh         = "\ue145", // refresh-cw
	.Arrow_Right     = "\ue049", // arrow-right
	.Cloud_Upload    = "\ue091", // cloud-upload
	.Cloud_Download  = "\ue089", // cloud-download
	.Chevron_Up      = "\ue070", // chevron-up
	.Folder          = "\ue0d7", // folder
	.App_Window      = "\ue426", // app-window
}

// The color lives here rather than in backgroundColor, which Clay would draw
// as a filled rectangle
Icon_Data :: struct {
	kind:  Icon,
	color: clay.Color,
	size:  u16,
	badge: Maybe(Icon_Badge), // a small icon over its top right corner
}

// A small icon on another's top right corner (a pinned terminal's pin). The
// icon under it stops a gap short of it, so it reads on any background
Icon_Badge :: struct {
	kind:  Icon,
	color: clay.Color,
}

// A badge's size, as a share of its icon's
BADGE_SCALE :: 0.62
