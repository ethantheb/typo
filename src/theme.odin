package editor

import "core:math"

import clay "../vendor/clay-odin"
import ttf "vendor:sdl3/ttf"

import "syntax"

// Font ids index into FONT_FILES; Clay passes these back to us in measure/render.
Font_Id :: enum u16 {
	Body,
	SemiBold,
	Bold,
	Icons,
}

FONT_FILES := [Font_Id]string {
	.Body     = "assets/fonts/IBMPlexMono-Medium.ttf",
	.SemiBold = "assets/fonts/IBMPlexMono-SemiBold.ttf",
	.Bold     = "assets/fonts/IBMPlexMono-Bold.ttf",
	.Icons    = "assets/fonts/lucide.ttf",
}

// Colors used by the UI and the text view. The active set is `theme`, switched
// at runtime by the settings (apply_settings). Clay colors are 0..255 floats.
Theme :: struct {
	bg:           clay.Color, // editor background
	panel:        clay.Color, // sidebar, popups
	statusbar:    clay.Color,
	border:       clay.Color,
	hover:        clay.Color,
	selected:     clay.Color, // selected list row
	text:         clay.Color,
	text_dim:     clay.Color,
	text_faint:   clay.Color, // line numbers
	text_bright:  clay.Color,
	gutter:       clay.Color,
	accent:       clay.Color,
	selection:    clay.Color, // text selection
	current_line: clay.Color,
	caret:        clay.Color,
	backdrop:     clay.Color, // dims the window behind modal popups
	syntax:       [syntax.Highlight]clay.Color,
}

// Based on GitHub's dark theme, softened: near-black blue-greys for surfaces,
// and muted, almost pastel reds and blues for syntax (GitHub Dark's roles:
// red keywords, blue strings/constants, lavender functions).
DARK_THEME :: Theme {
	bg           = {13, 17, 23, 255},
	panel        = {17, 21, 28, 255},
	statusbar    = {17, 21, 28, 255},
	border       = {38, 44, 54, 255},
	hover        = {30, 36, 46, 255},
	selected     = {30, 45, 68, 255},
	text         = {201, 209, 217, 255},
	text_dim     = {125, 133, 144, 255},
	text_faint   = {84, 92, 103, 255},
	text_bright  = {230, 237, 243, 255},
	gutter       = {13, 17, 23, 255},
	accent       = {121, 168, 232, 255},
	selection    = {35, 55, 85, 255},
	current_line = {20, 25, 33, 255},
	caret        = {201, 209, 217, 255},
	backdrop     = {0, 0, 0, 110},
	syntax       = {
		.None             = {201, 209, 217, 255},
		.Comment          = {125, 133, 144, 255}, // grey
		.Keyword          = {232, 138, 136, 255}, // soft red
		.String           = {164, 198, 236, 255}, // pale blue
		.Escape           = {121, 168, 232, 255}, // blue
		.Number           = {127, 177, 230, 255}, // blue
		.Constant         = {127, 177, 230, 255}, // blue
		.Type             = {228, 166, 160, 255}, // rose
		.Function         = {196, 176, 236, 255}, // lavender
		.Variable_Builtin = {232, 138, 136, 255}, // like keywords (self, context)
		.Parameter        = {214, 220, 228, 255}, // near text
		.Property         = {146, 186, 230, 255}, // light blue
		.Namespace        = {228, 166, 160, 255}, // rose, like types
		.Operator         = {214, 150, 148, 255}, // muted red
		.Punctuation      = {139, 148, 158, 255}, // grey
		.Attribute        = {146, 186, 230, 255}, // light blue
		.Label            = {201, 209, 217, 255},
	},
}

// GitHub Light, with the same roles. Syntax colors are deeper than the dark
// theme's (pastels wash out on white) but still muted rather than saturated.
LIGHT_THEME :: Theme {
	bg           = {255, 255, 255, 255},
	panel        = {246, 248, 250, 255},
	statusbar    = {246, 248, 250, 255},
	border       = {216, 222, 228, 255},
	hover        = {234, 238, 242, 255},
	selected     = {221, 234, 250, 255},
	text         = {36, 41, 47, 255},
	text_dim     = {101, 109, 118, 255},
	text_faint   = {150, 158, 167, 255},
	text_bright  = {15, 20, 25, 255},
	gutter       = {255, 255, 255, 255},
	accent       = {9, 105, 218, 255},
	selection    = {196, 222, 250, 255},
	current_line = {246, 248, 250, 255},
	caret        = {36, 41, 47, 255},
	backdrop     = {27, 31, 36, 60},
	syntax       = {
		.None             = {36, 41, 47, 255},
		.Comment          = {110, 119, 129, 255}, // grey
		.Keyword          = {196, 64, 72, 255},   // red
		.String           = {28, 72, 140, 255},   // deep blue
		.Escape           = {40, 100, 190, 255},
		.Number           = {30, 90, 170, 255},   // blue
		.Constant         = {30, 90, 170, 255},
		.Type             = {168, 78, 74, 255},   // brick
		.Function         = {116, 80, 190, 255},  // purple
		.Variable_Builtin = {196, 64, 72, 255},
		.Parameter        = {60, 66, 74, 255},
		.Property         = {40, 100, 170, 255},
		.Namespace        = {168, 78, 74, 255},
		.Operator         = {176, 80, 84, 255},
		.Punctuation      = {110, 119, 129, 255},
		.Attribute        = {40, 100, 170, 255},
		.Label            = {36, 41, 47, 255},
	},
}

theme := DARK_THEME

// Light hinting snaps glyphs only vertically, keeping their designed shapes;
// LIGHT_SUBPIXEL also positions glyphs at fractional pixels for even spacing.
FONT_HINTING :: ttf.Hinting.LIGHT_SUBPIXEL

FONT_SIZE_UI      :: 14
FONT_SIZE_SIDEBAR :: 13
UI_LINE_HEIGHT    :: 20

STATUSBAR_HEIGHT :: 24
SIDEBAR_WIDTH    :: 240

// Editor text size comes from the settings; the line height follows it.
editor_font_size :: proc() -> u16 {
	return u16(g.settings.font_size)
}

// Line numbers are a little smaller than the text they label.
gutter_font_size :: proc() -> u16 {
	return max(editor_font_size(), 10) - 2
}

editor_line_height :: proc() -> int {
	return int(math.round(f32(g.settings.font_size) * 1.35))
}
