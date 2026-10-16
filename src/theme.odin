package editor

import clay "../vendor/clay-odin"

import "syntax"

// Colors used by the UI, the text view and the terminal. Clay colors are
// 0..255 floats. The active set is `theme`, chosen by name in the settings.
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
	error:        clay.Color,
	selection:    clay.Color, // text selection
	current_line: clay.Color,
	caret:        clay.Color,
	backdrop:     clay.Color, // dims the window behind modal popups
	syntax:       [syntax.Highlight]clay.Color,
	ansi:         [16]clay.Color, // terminal colors 0-15: black red green yellow blue magenta cyan white, then bright
}

// GitHub Dark, softened: near-black blue-greys for surfaces, and muted, almost
// pastel reds and blues for syntax.
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
	error        = {232, 138, 136, 255},
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
	ansi         = {
		{72, 79, 88, 255},    {232, 138, 136, 255}, {126, 196, 142, 255}, {222, 190, 120, 255},
		{127, 177, 230, 255}, {196, 176, 236, 255}, {120, 200, 208, 255}, {177, 186, 196, 255},
		{110, 118, 129, 255}, {244, 168, 162, 255}, {150, 216, 162, 255}, {236, 206, 140, 255},
		{164, 198, 236, 255}, {214, 196, 244, 255}, {148, 216, 222, 255}, {230, 237, 243, 255},
	},
}

// GitHub Light, with the same roles. Syntax colors are deeper than the dark
// theme's but still muted.
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
	error        = {196, 64, 72, 255},
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
	ansi         = {
		{36, 41, 47, 255},   {196, 64, 72, 255},  {26, 127, 55, 255},  {154, 103, 0, 255},
		{28, 72, 140, 255},  {116, 80, 190, 255}, {27, 124, 131, 255}, {110, 119, 129, 255},
		{87, 96, 106, 255},  {164, 14, 38, 255},  {17, 99, 41, 255},   {125, 78, 0, 255},
		{9, 105, 218, 255},  {130, 80, 223, 255}, {49, 146, 170, 255}, {140, 149, 159, 255},
	},
}

// Built-in themes; THEME_NAMES[i] names THEMES[i] in the settings.
THEMES := [?]Theme{DARK_THEME, LIGHT_THEME}
THEME_NAMES := [?]string{"dark", "light"}
#assert(len(THEMES) == len(THEME_NAMES))

theme := DARK_THEME

theme_by_name :: proc(name: string) -> Theme {
	for n, i in THEME_NAMES do if n == name do return THEMES[i]
	return DARK_THEME
}
