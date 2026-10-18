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

// A built-in theme, with colors as 0xRRGGBB. The status bar uses `panel`, the
// gutter `bg`, and the backdrop depends on `dark`.
Theme_Spec :: struct {
	key:          string, // in settings.toml
	name:         string, // in the theme list
	family:       string, // themes that are dark and light versions of one design
	dark:         bool,
	bg, panel, border, hover, selected: u32,
	text, text_dim, text_faint, text_bright: u32,
	accent, error, selection, current_line, caret: u32,
	syntax:       [syntax.Highlight]u32,
	ansi:         [16]u32,
}

DEFAULT_THEME :: "typo-dark"

THEMES := [?]Theme_Spec {
	// GitHub Dark, softened: near-black blue-greys for surfaces, and muted,
	// almost pastel reds and blues for syntax.
	{
		key = "typo-dark", name = "Typo Dark", family = "Typo", dark = true,
		bg = 0x0d1117, panel = 0x11151c, border = 0x262c36, hover = 0x1e242e, selected = 0x1e2d44,
		text = 0xc9d1d9, text_dim = 0x7d8590, text_faint = 0x545c67, text_bright = 0xe6edf3,
		accent = 0x79a8e8, error = 0xe88a88, selection = 0x233755, current_line = 0x141921, caret = 0xc9d1d9,
		syntax = {
			.None = 0xc9d1d9, .Comment = 0x7d8590, .Keyword = 0xe88a88, .String = 0xa4c6ec, .Escape = 0x79a8e8,
			.Number = 0x7fb1e6, .Constant = 0x7fb1e6, .Type = 0xe4a6a0, .Function = 0xc4b0ec,
			.Variable_Builtin = 0xe88a88, .Parameter = 0xd6dce4, .Property = 0x92bae6, .Namespace = 0xe4a6a0,
			.Operator = 0xd69694, .Punctuation = 0x8b949e, .Attribute = 0x92bae6, .Label = 0xc9d1d9,
		},
		ansi = {
			0x484f58, 0xe88a88, 0x7ec48e, 0xdebe78, 0x7fb1e6, 0xc4b0ec, 0x78c8d0, 0xb1bac4,
			0x6e7681, 0xf4a8a2, 0x96d8a2, 0xecce8c, 0xa4c6ec, 0xd6c4f4, 0x94d8de, 0xe6edf3,
		},
	},
	// GitHub Light with the same roles; syntax colors deeper but still muted.
	{
		key = "typo-light", name = "Typo Light", family = "Typo",
		bg = 0xffffff, panel = 0xf6f8fa, border = 0xd8dee4, hover = 0xeaeef2, selected = 0xddeafa,
		text = 0x24292f, text_dim = 0x656d76, text_faint = 0x969ea7, text_bright = 0x0f1419,
		accent = 0x0969da, error = 0xc44048, selection = 0xc4defa, current_line = 0xf6f8fa, caret = 0x24292f,
		syntax = {
			.None = 0x24292f, .Comment = 0x6e7781, .Keyword = 0xc44048, .String = 0x1c488c, .Escape = 0x2864be,
			.Number = 0x1e5aaa, .Constant = 0x1e5aaa, .Type = 0xa84e4a, .Function = 0x7450be,
			.Variable_Builtin = 0xc44048, .Parameter = 0x3c424a, .Property = 0x2864aa, .Namespace = 0xa84e4a,
			.Operator = 0xb05054, .Punctuation = 0x6e7781, .Attribute = 0x2864aa, .Label = 0x24292f,
		},
		ansi = {
			0x24292f, 0xc44048, 0x1a7f37, 0x9a6700, 0x1c488c, 0x7450be, 0x1b7c83, 0x6e7781,
			0x57606a, 0xa40e26, 0x116329, 0x7d4e00, 0x0969da, 0x8250df, 0x3192aa, 0x8c959f,
		},
	},
	{
		key = "one-dark", name = "One Dark", family = "One", dark = true,
		bg = 0x282c34, panel = 0x21252b, border = 0x181a1f, hover = 0x2c313a, selected = 0x323844,
		text = 0xabb2bf, text_dim = 0x7f848e, text_faint = 0x495162, text_bright = 0xd7dae0,
		accent = 0x528bff, error = 0xe06c75, selection = 0x3e4451, current_line = 0x2c313c, caret = 0x528bff,
		syntax = {
			.None = 0xabb2bf, .Comment = 0x5c6370, .Keyword = 0xc678dd, .String = 0x98c379, .Escape = 0x56b6c2,
			.Number = 0xd19a66, .Constant = 0xd19a66, .Type = 0xe5c07b, .Function = 0x61afef,
			.Variable_Builtin = 0xe06c75, .Parameter = 0xabb2bf, .Property = 0xe06c75, .Namespace = 0xe5c07b,
			.Operator = 0x56b6c2, .Punctuation = 0xabb2bf, .Attribute = 0xd19a66, .Label = 0xabb2bf,
		},
		ansi = {
			0x3f4451, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
			0x5c6370, 0xf07c85, 0xa8d389, 0xf0cb8b, 0x71bfff, 0xd688ed, 0x66c6d2, 0xdcdfe4,
		},
	},
	{
		key = "one-light", name = "One Light", family = "One",
		bg = 0xfafafa, panel = 0xeaeaeb, border = 0xdbdbdc, hover = 0xe2e2e3, selected = 0xd6d6d8,
		text = 0x383a42, text_dim = 0x696c77, text_faint = 0x9d9d9f, text_bright = 0x232324,
		accent = 0x526fff, error = 0xe45649, selection = 0xe0e0e2, current_line = 0xf0f0f1, caret = 0x526fff,
		syntax = {
			.None = 0x383a42, .Comment = 0xa0a1a7, .Keyword = 0xa626a4, .String = 0x50a14f, .Escape = 0x0184bc,
			.Number = 0x986801, .Constant = 0x986801, .Type = 0xc18401, .Function = 0x4078f2,
			.Variable_Builtin = 0xe45649, .Parameter = 0x383a42, .Property = 0xe45649, .Namespace = 0xc18401,
			.Operator = 0x0184bc, .Punctuation = 0x383a42, .Attribute = 0x986801, .Label = 0x383a42,
		},
		ansi = {
			0x383a42, 0xe45649, 0x50a14f, 0xc18401, 0x4078f2, 0xa626a4, 0x0184bc, 0xa0a1a7,
			0x4f525e, 0xca1243, 0x3d8c3c, 0x986801, 0x2e62d9, 0x8b2b89, 0x0997b3, 0x696c77,
		},
	},
	{
		key = "github-dark", name = "GitHub Dark", family = "GitHub", dark = true,
		bg = 0x0d1117, panel = 0x010409, border = 0x30363d, hover = 0x161b22, selected = 0x21262d,
		text = 0xe6edf3, text_dim = 0x8d96a0, text_faint = 0x6e7681, text_bright = 0xffffff,
		accent = 0x2f81f7, error = 0xf85149, selection = 0x264f78, current_line = 0x161b22, caret = 0x2f81f7,
		syntax = {
			.None = 0xe6edf3, .Comment = 0x8b949e, .Keyword = 0xff7b72, .String = 0xa5d6ff, .Escape = 0x7ee787,
			.Number = 0x79c0ff, .Constant = 0x79c0ff, .Type = 0xffa657, .Function = 0xd2a8ff,
			.Variable_Builtin = 0x79c0ff, .Parameter = 0xe6edf3, .Property = 0x79c0ff, .Namespace = 0xffa657,
			.Operator = 0xff7b72, .Punctuation = 0xe6edf3, .Attribute = 0x79c0ff, .Label = 0xe6edf3,
		},
		ansi = {
			0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
			0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff,
		},
	},
	{
		key = "github-light", name = "GitHub Light", family = "GitHub",
		bg = 0xffffff, panel = 0xf6f8fa, border = 0xd0d7de, hover = 0xeaeef2, selected = 0xddf4ff,
		text = 0x1f2328, text_dim = 0x656d76, text_faint = 0x8c959f, text_bright = 0x0d1117,
		accent = 0x0969da, error = 0xcf222e, selection = 0xb6e3ff, current_line = 0xf6f8fa, caret = 0x0969da,
		syntax = {
			.None = 0x1f2328, .Comment = 0x6e7781, .Keyword = 0xcf222e, .String = 0x0a3069, .Escape = 0x116329,
			.Number = 0x0550ae, .Constant = 0x0550ae, .Type = 0x953800, .Function = 0x8250df,
			.Variable_Builtin = 0x0550ae, .Parameter = 0x1f2328, .Property = 0x0550ae, .Namespace = 0x953800,
			.Operator = 0xcf222e, .Punctuation = 0x1f2328, .Attribute = 0x0550ae, .Label = 0x1f2328,
		},
		ansi = {
			0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
			0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
		},
	},
	// VS Code's Dark Modern and Light Modern, with Dark+ / Light+ syntax colors.
	{
		key = "vscode-dark", name = "VS Code Dark", family = "VS Code", dark = true,
		bg = 0x1f1f1f, panel = 0x181818, border = 0x2b2b2b, hover = 0x2a2d2e, selected = 0x04395e,
		text = 0xcccccc, text_dim = 0x9d9d9d, text_faint = 0x6e7681, text_bright = 0xffffff,
		accent = 0x0078d4, error = 0xf85149, selection = 0x264f78, current_line = 0x282828, caret = 0xaeafad,
		syntax = {
			.None = 0xd4d4d4, .Comment = 0x6a9955, .Keyword = 0x569cd6, .String = 0xce9178, .Escape = 0xd7ba7d,
			.Number = 0xb5cea8, .Constant = 0x4fc1ff, .Type = 0x4ec9b0, .Function = 0xdcdcaa,
			.Variable_Builtin = 0x569cd6, .Parameter = 0x9cdcfe, .Property = 0x9cdcfe, .Namespace = 0x4ec9b0,
			.Operator = 0xd4d4d4, .Punctuation = 0xd4d4d4, .Attribute = 0xdcdcaa, .Label = 0xc8c8c8,
		},
		ansi = {
			0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
			0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff,
		},
	},
	{
		key = "vscode-light", name = "VS Code Light", family = "VS Code",
		bg = 0xffffff, panel = 0xf8f8f8, border = 0xe5e5e5, hover = 0xf0f0f0, selected = 0xe4e6f1,
		text = 0x3b3b3b, text_dim = 0x6f6f6f, text_faint = 0x9e9e9e, text_bright = 0x000000,
		accent = 0x005fb8, error = 0xe51400, selection = 0xadd6ff, current_line = 0xf3f3f3, caret = 0x000000,
		syntax = {
			.None = 0x000000, .Comment = 0x008000, .Keyword = 0x0000ff, .String = 0xa31515, .Escape = 0xee0000,
			.Number = 0x098658, .Constant = 0x0070c1, .Type = 0x267f99, .Function = 0x795e26,
			.Variable_Builtin = 0x0000ff, .Parameter = 0x001080, .Property = 0x001080, .Namespace = 0x267f99,
			.Operator = 0x000000, .Punctuation = 0x000000, .Attribute = 0x795e26, .Label = 0x000000,
		},
		ansi = {
			0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555,
			0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5,
		},
	},
	{
		key = "solarized-dark", name = "Solarized Dark", family = "Solarized", dark = true,
		bg = 0x002b36, panel = 0x00212b, border = 0x0d3c48, hover = 0x073642, selected = 0x005a6f,
		text = 0x839496, text_dim = 0x657b83, text_faint = 0x47616a, text_bright = 0x93a1a1,
		accent = 0x268bd2, error = 0xdc322f, selection = 0x274642, current_line = 0x073642, caret = 0x93a1a1,
		syntax = {
			.None = 0x839496, .Comment = 0x586e75, .Keyword = 0x859900, .String = 0x2aa198, .Escape = 0xdc322f,
			.Number = 0xd33682, .Constant = 0xcb4b16, .Type = 0xb58900, .Function = 0x268bd2,
			.Variable_Builtin = 0xcb4b16, .Parameter = 0x839496, .Property = 0x6c71c4, .Namespace = 0xb58900,
			.Operator = 0x859900, .Punctuation = 0x657b83, .Attribute = 0xcb4b16, .Label = 0x6c71c4,
		},
		ansi = {
			0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
			0x586e75, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
		},
	},
	{
		key = "solarized-light", name = "Solarized Light", family = "Solarized",
		bg = 0xfdf6e3, panel = 0xeee8d5, border = 0xddd6c1, hover = 0xe6dfcb, selected = 0xdcd5c0,
		text = 0x657b83, text_dim = 0x839496, text_faint = 0xa9b1ad, text_bright = 0x073642,
		accent = 0x268bd2, error = 0xdc322f, selection = 0xe9e2cb, current_line = 0xf3ecd8, caret = 0x657b83,
		syntax = {
			.None = 0x657b83, .Comment = 0x93a1a1, .Keyword = 0x859900, .String = 0x2aa198, .Escape = 0xdc322f,
			.Number = 0xd33682, .Constant = 0xcb4b16, .Type = 0xb58900, .Function = 0x268bd2,
			.Variable_Builtin = 0xcb4b16, .Parameter = 0x657b83, .Property = 0x6c71c4, .Namespace = 0xb58900,
			.Operator = 0x859900, .Punctuation = 0x839496, .Attribute = 0xcb4b16, .Label = 0x6c71c4,
		},
		ansi = {
			0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0x93a1a1,
			0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0x839496,
		},
	},
	{
		key = "gruvbox-dark", name = "Gruvbox Dark", family = "Gruvbox", dark = true,
		bg = 0x282828, panel = 0x1d2021, border = 0x3c3836, hover = 0x32302f, selected = 0x504945,
		text = 0xebdbb2, text_dim = 0xa89984, text_faint = 0x7c6f64, text_bright = 0xfbf1c7,
		accent = 0xfabd2f, error = 0xfb4934, selection = 0x504945, current_line = 0x32302f, caret = 0xebdbb2,
		syntax = {
			.None = 0xebdbb2, .Comment = 0x928374, .Keyword = 0xfb4934, .String = 0xb8bb26, .Escape = 0xfe8019,
			.Number = 0xd3869b, .Constant = 0xd3869b, .Type = 0xfabd2f, .Function = 0x8ec07c,
			.Variable_Builtin = 0xfe8019, .Parameter = 0x83a598, .Property = 0x83a598, .Namespace = 0x8ec07c,
			.Operator = 0xfe8019, .Punctuation = 0xa89984, .Attribute = 0x8ec07c, .Label = 0x83a598,
		},
		ansi = {
			0x3c3836, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
			0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
		},
	},
	{
		key = "gruvbox-light", name = "Gruvbox Light", family = "Gruvbox",
		bg = 0xfbf1c7, panel = 0xf2e5bc, border = 0xd5c4a1, hover = 0xebdbb2, selected = 0xd5c4a1,
		text = 0x3c3836, text_dim = 0x7c6f64, text_faint = 0xa89984, text_bright = 0x282828,
		accent = 0xb57614, error = 0x9d0006, selection = 0xebdbb2, current_line = 0xf2e5bc, caret = 0x3c3836,
		syntax = {
			.None = 0x3c3836, .Comment = 0x928374, .Keyword = 0x9d0006, .String = 0x79740e, .Escape = 0xaf3a03,
			.Number = 0x8f3f71, .Constant = 0x8f3f71, .Type = 0xb57614, .Function = 0x427b58,
			.Variable_Builtin = 0xaf3a03, .Parameter = 0x076678, .Property = 0x076678, .Namespace = 0x427b58,
			.Operator = 0xaf3a03, .Punctuation = 0x7c6f64, .Attribute = 0x427b58, .Label = 0x076678,
		},
		ansi = {
			0x3c3836, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
			0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0xa89984,
		},
	},
	{
		key = "catppuccin-mocha", name = "Catppuccin Mocha", family = "Catppuccin", dark = true,
		bg = 0x1e1e2e, panel = 0x181825, border = 0x313244, hover = 0x262637, selected = 0x393b54,
		text = 0xcdd6f4, text_dim = 0x9399b2, text_faint = 0x6c7086, text_bright = 0xe6eafa,
		accent = 0xcba6f7, error = 0xf38ba8, selection = 0x414359, current_line = 0x262637, caret = 0xf5e0dc,
		syntax = {
			.None = 0xcdd6f4, .Comment = 0x9399b2, .Keyword = 0xcba6f7, .String = 0xa6e3a1, .Escape = 0xf5c2e7,
			.Number = 0xfab387, .Constant = 0xfab387, .Type = 0xf9e2af, .Function = 0x89b4fa,
			.Variable_Builtin = 0xf38ba8, .Parameter = 0xeba0ac, .Property = 0xb4befe, .Namespace = 0xf9e2af,
			.Operator = 0x89dceb, .Punctuation = 0x9399b2, .Attribute = 0x94e2d5, .Label = 0x74c7ec,
		},
		ansi = {
			0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
			0x585b70, 0xf37799, 0x89d88b, 0xebd391, 0x74a8fc, 0xf2aede, 0x6bd7ca, 0xa6adc8,
		},
	},
	{
		key = "catppuccin-latte", name = "Catppuccin Latte", family = "Catppuccin",
		bg = 0xeff1f5, panel = 0xe6e9ef, border = 0xccd0da, hover = 0xdce0e8, selected = 0xccd0da,
		text = 0x4c4f69, text_dim = 0x6c6f85, text_faint = 0x9ca0b0, text_bright = 0x303246,
		accent = 0x8839ef, error = 0xd20f39, selection = 0xd4d7e1, current_line = 0xe6e9ef, caret = 0xdc8a78,
		syntax = {
			.None = 0x4c4f69, .Comment = 0x7c7f93, .Keyword = 0x8839ef, .String = 0x40a02b, .Escape = 0xea76cb,
			.Number = 0xfe640b, .Constant = 0xfe640b, .Type = 0xdf8e1d, .Function = 0x1e66f5,
			.Variable_Builtin = 0xd20f39, .Parameter = 0xe64553, .Property = 0x7287fd, .Namespace = 0xdf8e1d,
			.Operator = 0x04a5e5, .Punctuation = 0x7c7f93, .Attribute = 0x179299, .Label = 0x209fb5,
		},
		ansi = {
			0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
			0x6c6f85, 0xde293e, 0x49af3d, 0xeea02d, 0x456eff, 0xfe85d8, 0x2d9fa8, 0xbcc0cc,
		},
	},
	{
		key = "tokyo-night", name = "Tokyo Night", family = "Tokyo Night", dark = true,
		bg = 0x1a1b26, panel = 0x16161e, border = 0x292e42, hover = 0x202330, selected = 0x2b3655,
		text = 0xc0caf5, text_dim = 0x737aa2, text_faint = 0x3b4261, text_bright = 0xdfe5ff,
		accent = 0x7aa2f7, error = 0xf7768e, selection = 0x283457, current_line = 0x1e202e, caret = 0xc0caf5,
		syntax = {
			.None = 0xc0caf5, .Comment = 0x565f89, .Keyword = 0xbb9af7, .String = 0x9ece6a, .Escape = 0x89ddff,
			.Number = 0xff9e64, .Constant = 0xff9e64, .Type = 0x2ac3de, .Function = 0x7aa2f7,
			.Variable_Builtin = 0xf7768e, .Parameter = 0xe0af68, .Property = 0x73daca, .Namespace = 0x7dcfff,
			.Operator = 0x89ddff, .Punctuation = 0x9aa5ce, .Attribute = 0xe0af68, .Label = 0x73daca,
		},
		ansi = {
			0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
			0x565f89, 0xff899d, 0x9fe044, 0xfaba4a, 0x8db0ff, 0xc7a9ff, 0xa4daff, 0xc0caf5,
		},
	},
	{
		key = "tokyo-night-day", name = "Tokyo Night Day", family = "Tokyo Night",
		bg = 0xe1e2e7, panel = 0xd0d5e3, border = 0xc4c8da, hover = 0xc8ccdc, selected = 0xb6bfe2,
		text = 0x3760bf, text_dim = 0x6172b0, text_faint = 0xa8aecb, text_bright = 0x2a4a99,
		accent = 0x2e7de9, error = 0xf52a65, selection = 0xb7c1e3, current_line = 0xd5d7df, caret = 0x3760bf,
		syntax = {
			.None = 0x3760bf, .Comment = 0x848cb5, .Keyword = 0x9854f1, .String = 0x587539, .Escape = 0x006a83,
			.Number = 0xb15c00, .Constant = 0xb15c00, .Type = 0x188092, .Function = 0x2e7de9,
			.Variable_Builtin = 0xf52a65, .Parameter = 0x8c6c3e, .Property = 0x387068, .Namespace = 0x007197,
			.Operator = 0x006a83, .Punctuation = 0x6172b0, .Attribute = 0x8c6c3e, .Label = 0x387068,
		},
		ansi = {
			0x343b58, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x6172b0,
			0x68709a, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x8990b3,
		},
	},
	{
		key = "dracula", name = "Dracula", family = "Dracula", dark = true,
		bg = 0x282a36, panel = 0x21222c, border = 0x191a21, hover = 0x313342, selected = 0x44475a,
		text = 0xf8f8f2, text_dim = 0x9da5c8, text_faint = 0x6272a4, text_bright = 0xffffff,
		accent = 0xbd93f9, error = 0xff5555, selection = 0x44475a, current_line = 0x343746, caret = 0xf8f8f2,
		syntax = {
			.None = 0xf8f8f2, .Comment = 0x6272a4, .Keyword = 0xff79c6, .String = 0xf1fa8c, .Escape = 0xff79c6,
			.Number = 0xbd93f9, .Constant = 0xbd93f9, .Type = 0x8be9fd, .Function = 0x50fa7b,
			.Variable_Builtin = 0xbd93f9, .Parameter = 0xffb86c, .Property = 0xf8f8f2, .Namespace = 0x8be9fd,
			.Operator = 0xff79c6, .Punctuation = 0xf8f8f2, .Attribute = 0x50fa7b, .Label = 0x8be9fd,
		},
		ansi = {
			0x44475a, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
			0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
		},
	},
	// Dracula's official light variant.
	{
		key = "alucard", name = "Alucard (Dracula)", family = "Dracula",
		bg = 0xfffbeb, panel = 0xf4eed8, border = 0xe0d9c1, hover = 0xebe5cf, selected = 0xcfcfde,
		text = 0x1f1f1f, text_dim = 0x6c664b, text_faint = 0xa39d84, text_bright = 0x000000,
		accent = 0x644ac9, error = 0xcb3a2a, selection = 0xcfcfde, current_line = 0xf6f1df, caret = 0x1f1f1f,
		syntax = {
			.None = 0x1f1f1f, .Comment = 0x6c664b, .Keyword = 0xa3144d, .String = 0x846e15, .Escape = 0xa3144d,
			.Number = 0x644ac9, .Constant = 0x644ac9, .Type = 0x036a96, .Function = 0x14710a,
			.Variable_Builtin = 0x644ac9, .Parameter = 0xa34d14, .Property = 0x1f1f1f, .Namespace = 0x036a96,
			.Operator = 0xa3144d, .Punctuation = 0x1f1f1f, .Attribute = 0x14710a, .Label = 0x036a96,
		},
		ansi = {
			0x1f1f1f, 0xcb3a2a, 0x14710a, 0x846e15, 0x644ac9, 0xa3144d, 0x036a96, 0x6c664b,
			0x4d4d4d, 0xd74c3d, 0x198d0c, 0x9e841a, 0x7862d0, 0xbf185a, 0x047fb4, 0x8a8468,
		},
	},
	{
		key = "rose-pine", name = "Rosé Pine", family = "Rosé Pine", dark = true,
		bg = 0x191724, panel = 0x1f1d2e, border = 0x2a273f, hover = 0x26233a, selected = 0x403d52,
		text = 0xe0def4, text_dim = 0x908caa, text_faint = 0x6e6a86, text_bright = 0xf4f2ff,
		accent = 0xebbcba, error = 0xeb6f92, selection = 0x403d52, current_line = 0x21202e, caret = 0xe0def4,
		syntax = {
			.None = 0xe0def4, .Comment = 0x6e6a86, .Keyword = 0x31748f, .String = 0xf6c177, .Escape = 0x31748f,
			.Number = 0xebbcba, .Constant = 0xebbcba, .Type = 0x9ccfd8, .Function = 0xebbcba,
			.Variable_Builtin = 0xeb6f92, .Parameter = 0xc4a7e7, .Property = 0x9ccfd8, .Namespace = 0xc4a7e7,
			.Operator = 0x908caa, .Punctuation = 0x908caa, .Attribute = 0xc4a7e7, .Label = 0x9ccfd8,
		},
		ansi = {
			0x26233a, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
			0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
		},
	},
	{
		key = "rose-pine-dawn", name = "Rosé Pine Dawn", family = "Rosé Pine",
		bg = 0xfaf4ed, panel = 0xfffaf3, border = 0xdfdad9, hover = 0xf2e9e1, selected = 0xdfdad9,
		text = 0x575279, text_dim = 0x797593, text_faint = 0x9893a5, text_bright = 0x3e3a5f,
		accent = 0xd7827e, error = 0xb4637a, selection = 0xdfdad9, current_line = 0xf4ede8, caret = 0x575279,
		syntax = {
			.None = 0x575279, .Comment = 0x9893a5, .Keyword = 0x286983, .String = 0xea9d34, .Escape = 0x286983,
			.Number = 0xd7827e, .Constant = 0xd7827e, .Type = 0x56949f, .Function = 0xd7827e,
			.Variable_Builtin = 0xb4637a, .Parameter = 0x907aa9, .Property = 0x56949f, .Namespace = 0x907aa9,
			.Operator = 0x797593, .Punctuation = 0x797593, .Attribute = 0x907aa9, .Label = 0x56949f,
		},
		ansi = {
			0x575279, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0x9893a5,
			0x797593, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0xcecacd,
		},
	},
	{
		key = "monokai-pro", name = "Monokai Pro", family = "Monokai Pro", dark = true,
		bg = 0x2d2a2e, panel = 0x221f22, border = 0x19181a, hover = 0x363337, selected = 0x403e41,
		text = 0xfcfcfa, text_dim = 0x939293, text_faint = 0x5b595c, text_bright = 0xffffff,
		accent = 0xffd866, error = 0xff6188, selection = 0x4a474b, current_line = 0x353236, caret = 0xfcfcfa,
		syntax = {
			.None = 0xfcfcfa, .Comment = 0x727072, .Keyword = 0xff6188, .String = 0xffd866, .Escape = 0xab9df2,
			.Number = 0xab9df2, .Constant = 0xab9df2, .Type = 0x78dce8, .Function = 0xa9dc76,
			.Variable_Builtin = 0xc1c0c0, .Parameter = 0xfc9867, .Property = 0xfcfcfa, .Namespace = 0x78dce8,
			.Operator = 0xff6188, .Punctuation = 0x939293, .Attribute = 0x78dce8, .Label = 0xfcfcfa,
		},
		ansi = {
			0x403e41, 0xff6188, 0xa9dc76, 0xffd866, 0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa,
			0x727072, 0xff6188, 0xa9dc76, 0xffd866, 0xfc9867, 0xab9df2, 0x78dce8, 0xfcfcfa,
		},
	},
	{
		key = "monokai-pro-light", name = "Monokai Pro Light", family = "Monokai Pro",
		bg = 0xfaf4f2, panel = 0xede7e5, border = 0xd3cdcc, hover = 0xe5dfdd, selected = 0xd3cdcc,
		text = 0x29242a, text_dim = 0x706b6e, text_faint = 0xa59fa0, text_bright = 0x19151a,
		accent = 0xcc7a0a, error = 0xe14775, selection = 0xe1dbd9, current_line = 0xf0eae8, caret = 0x29242a,
		syntax = {
			.None = 0x29242a, .Comment = 0xa59fa0, .Keyword = 0xe14775, .String = 0xcc7a0a, .Escape = 0x7058be,
			.Number = 0x7058be, .Constant = 0x7058be, .Type = 0x1c8ca8, .Function = 0x269d69,
			.Variable_Builtin = 0x706b6e, .Parameter = 0xe16032, .Property = 0x29242a, .Namespace = 0x1c8ca8,
			.Operator = 0xe14775, .Punctuation = 0x918c8e, .Attribute = 0x1c8ca8, .Label = 0x29242a,
		},
		ansi = {
			0x29242a, 0xe14775, 0x269d69, 0xcc7a0a, 0xe16032, 0x7058be, 0x1c8ca8, 0x918c8e,
			0x706b6e, 0xe14775, 0x269d69, 0xcc7a0a, 0xe16032, 0x7058be, 0x1c8ca8, 0xa59fa0,
		},
	},
}

// The theme keys, for the setting's allowed values.
THEME_NAMES: [len(THEMES)]string

theme: Theme

@(init, private = "file")
init_themes :: proc "contextless" () {
	for spec, i in THEMES do THEME_NAMES[i] = spec.key
	theme = theme_from_spec(THEMES[0])
}

theme_index :: proc(key: string) -> (int, bool) {
	for spec, i in THEMES do if spec.key == key do return i, true
	return 0, false
}

theme_by_name :: proc(key: string) -> Theme {
	i, _ := theme_index(key)
	return theme_from_spec(THEMES[i])
}

rgb :: proc "contextless" (c: u32) -> clay.Color {
	return {f32(c >> 16 & 0xff), f32(c >> 8 & 0xff), f32(c & 0xff), 255}
}

theme_from_spec :: proc "contextless" (s: Theme_Spec) -> (t: Theme) {
	t = {
		bg           = rgb(s.bg),
		panel        = rgb(s.panel),
		statusbar    = rgb(s.panel),
		border       = rgb(s.border),
		hover        = rgb(s.hover),
		selected     = rgb(s.selected),
		text         = rgb(s.text),
		text_dim     = rgb(s.text_dim),
		text_faint   = rgb(s.text_faint),
		text_bright  = rgb(s.text_bright),
		gutter       = rgb(s.bg),
		accent       = rgb(s.accent),
		error        = rgb(s.error),
		selection    = rgb(s.selection),
		current_line = rgb(s.current_line),
		caret        = rgb(s.caret),
		backdrop     = s.dark ? {0, 0, 0, 110} : {27, 31, 36, 60},
	}
	for c, h in s.syntax do t.syntax[h] = rgb(c)
	for c, i in s.ansi do t.ansi[i] = rgb(c)
	return
}
