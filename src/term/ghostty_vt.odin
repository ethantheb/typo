package term

// Bindings to libghostty-vt (include/ghostty/vt.h of the release pinned in
// build.py) for what typo uses. The C ABI is stable from 1.0; check these
// against the headers when GHOSTTY_VERSION changes (test_abi_matches_manifest
// catches size and key-value mismatches)

import "core:c"

// Whether build.py applied patches/ghostty.patch (reflow trims trailing spaces
// when scrollback isn't pulled)
GHOSTTY_PATCHED :: #config(GHOSTTY_PATCHED, true)

// The static library build.py builds or downloads
when ODIN_OS == .Windows {
	foreign import vt "../../build/obj/ghostty-vt/lib/ghostty-vt-static.lib"
} else {
	foreign import vt "../../build/obj/ghostty-vt/lib/libghostty-vt.a"
}


Result :: enum c.int {
	Success        = 0,
	Out_Of_Memory  = -1,
	Invalid_Value  = -2,
	Out_Of_Space   = -3,
	No_Value       = -4,
	Io_Error       = -5,
	Limit_Exceeded = -6,
	Rejected       = -7,
	Unsupported    = -8,
}

Terminal      :: distinct rawptr
Render_State  :: distinct rawptr
Row_Iterator  :: distinct rawptr
Row_Cells     :: distinct rawptr
Key_Event     :: distinct rawptr
Key_Encoder   :: distinct rawptr
Mouse_Event   :: distinct rawptr
Mouse_Encoder :: distinct rawptr

Color_Rgb :: struct {
	r, g, b: u8,
}


// --- Styles ------------------------------------------------------------------------

Style_Color_Tag :: enum u8 {
	None    = 0,
	Palette = 1,
	Rgb     = 2,
}

Style_Color :: struct {
	tag:   Style_Color_Tag,
	value: struct #raw_union {
		palette: u8,
		rgb:     Color_Rgb,
	},
}

// GhosttyStyleFlags: the attributes, and the underline style in bits 8-10
// (0 = none; otherwise single, double, curly, dotted, dashed)
Style_Flags :: bit_field u16 {
	bold:          bool | 1,
	italic:        bool | 1,
	faint:         bool | 1,
	blink:         bool | 1,
	inverse:       bool | 1,
	invisible:     bool | 1,
	strikethrough: bool | 1,
	overline:      bool | 1,
	underline:     u8   | 3,
}

Style :: struct {
	fg_color:        Style_Color,
	bg_color:        Style_Color,
	underline_color: Style_Color,
	flags:           Style_Flags,
	_:               u16,
}


// --- Cells -------------------------------------------------------------------------

Cell :: distinct u64

Cell_Wide :: enum c.int {
	Narrow      = 0,
	Wide        = 1,
	Spacer_Tail = 2,
	Spacer_Head = 3,
}

Cell_Data :: enum c.int {
	Codepoint = 1,
	Wide      = 3,
	Has_Text  = 4,
}


// --- Terminal ----------------------------------------------------------------------

Terminal_Option :: enum c.int {
	Userdata               = 1,
	Write_Pty              = 2,
	Bell                   = 3,
	Title_Changed          = 6,
	Size                   = 7,
	Color_Foreground       = 12,
	Color_Background       = 13,
	Color_Cursor           = 14,
	Color_Palette          = 15,
	Selection              = 22,
	Default_Cursor_Blink   = 24,
	Scrollback_Max_Bytes   = 28,
	Mode_Default           = 34,
	Mode                   = 35,
	Resize_Pull_Scrollback = 41,
}

Terminal_Data :: enum c.int {
	Cols            = 1,
	Rows            = 2,
	Active_Screen   = 6,
	Scrollbar       = 9,
	Mouse_Tracking  = 11,
	Title           = 12,
	Selection       = 31,
	Viewport_Active = 32,
	Mode            = 37,
}

// Rows of the scrollable area (scrollback and screen), and the viewport in it
Terminal_Scrollbar :: struct {
	total:  u64,
	offset: u64,
	len:    u64,
}

Scroll_Viewport_Tag :: enum c.int {
	Top    = 0,
	Bottom = 1,
	Delta  = 2,
	Row    = 3,
}

Scroll_Viewport :: struct {
	tag:   Scroll_Viewport_Tag,
	value: struct #raw_union {
		delta: int,
		row:   uint,
		_:     [2]u64,
	},
}

// A DEC private mode number (ANSI modes set bit 15), as in modes.h
Mode :: distinct u16

MODE_CURSOR_KEYS     :: Mode(1) // DECCKM: application cursor keys
MODE_CURSOR_BLINKING :: Mode(12)
MODE_BRACKETED_PASTE :: Mode(2004)

Mode_Config :: struct {
	mode:  Mode,
	value: bool,
}

Write_Pty_Fn :: #type proc "c" (t: Terminal, userdata: rawptr, data: [^]u8, len: c.size_t)


// --- Render state ------------------------------------------------------------------

Render_Dirty :: enum c.int {
	False   = 0,
	Partial = 1,
	Full    = 2,
}

Cursor_Visual_Style :: enum c.int {
	Bar          = 0,
	Block        = 1,
	Underline    = 2,
	Block_Hollow = 3,
}

Render_Data :: enum c.int {
	Cols         = 1,
	Rows         = 2,
	Dirty        = 3,
	Row_Iterator = 4,
	Cursor       = 18,
	Colors       = 19,
}

Row_Data :: enum c.int {
	Dirty     = 1,
	Cells     = 3,
	Selection = 4,
}

Row_Cells_Data :: enum c.int {
	Raw           = 1,
	Style         = 2,
	Graphemes_Len = 3,
	Graphemes_Buf = 4, // Codepoint_Buffer
	Bg_Color      = 5,
	Fg_Color      = 6,
	Selected      = 7,
	Has_Styling   = 8,
}

Render_Cursor :: struct {
	size:               c.size_t,
	viewport_has_value: bool,
	viewport_x:         u16,
	viewport_y:         u16,
	wide_tail:          bool,
	visible:            bool,
	blinking:           bool,
	password_input:     bool,
	visual_style:       Cursor_Visual_Style,
}

Render_Colors :: struct {
	size:             c.size_t,
	background:       Color_Rgb,
	foreground:       Color_Rgb,
	cursor:           Color_Rgb,
	cursor_has_value: bool,
	palette:          [256]Color_Rgb,
}

// A cell's codepoints: up to `cap` are written to `ptr`, `len` is how many
// the cell has (Out_Of_Space when more than `cap`)
Codepoint_Buffer :: struct {
	ptr: [^]u32,
	cap: c.size_t,
	len: c.size_t,
}

Row_Selection :: struct {
	size:    c.size_t,
	start_x: u16,
	end_x:   u16,
}


// --- Grid positions and selection --------------------------------------------------

Point_Tag :: enum c.int {
	Active   = 0,
	Viewport = 1,
	Screen   = 2,
	History  = 3,
}

Point :: struct {
	tag:   Point_Tag,
	value: struct #raw_union {
		coordinate: struct {
			x: u16,
			y: u32,
		},
		_:          [2]u64,
	},
}

// A cell reference; only valid until the terminal is next modified
Grid_Ref :: struct {
	node: rawptr,
	x:    u16,
	y:    u16,
}

Selection :: struct {
	start:     Grid_Ref,
	end:       Grid_Ref,
	rectangle: bool,
}

Formatter_Format :: enum c.int {
	Plain = 0,
	Vt    = 1,
	Html  = 2,
}

// Formatter (formatter.h): terminal content as text, e.g. a selection
Formatter :: distinct rawptr

Formatter_Option :: enum c.int {
	Emit      = 1, // Formatter_Format
	Unwrap    = 2, // bool
	Trim      = 3, // bool
	Selection = 4, // Selection
	Extras    = 5,
}

Selection_Gesture :: distinct rawptr
Gesture_Event     :: distinct rawptr

// Search (search.h): matches in the active area and scrollback, as selections
Search :: distinct rawptr

Search_Status :: enum c.int {
	Running       = 0,
	Feed_Required = 1,
	Complete      = 2,
}

Search_Data :: enum c.int {
	Status           = 1,
	Needle           = 2,
	Total_Matches    = 3,
	Selected_Index   = 4, // 0 is the newest match
	Selected_Match   = 5,
	Matches          = 6,
	Viewport_Matches = 7,
	Select_Scroll    = 8,
}

Search_Option :: enum c.int {
	Needle        = 1,
	Select_Scroll = 4,
}

Ghostty_String :: struct {
	ptr: [^]u8,
	len: c.size_t,
}

Selection_Buffer :: struct {
	ptr: [^]Selection,
	cap: c.size_t,
	len: c.size_t, // written, or the capacity needed on Out_Of_Space
}

Point_Coordinate :: struct {
	x: u16,
	y: u32,
}

Gesture_Event_Type :: enum c.int {
	Press           = 0,
	Release         = 1,
	Drag            = 2,
	Autoscroll_Tick = 3,
}

Gesture_Event_Option :: enum c.int {
	Ref                = 1,
	Position           = 2,
	Repeat_Distance    = 3,
	Time_Ns            = 4,
	Repeat_Interval_Ns = 5,
	Geometry           = 9,
}

Surface_Position :: struct {
	x, y: f64,
}

Gesture_Geometry :: struct {
	columns:       u32,
	cell_width:    u32,
	padding_left:  u32,
	screen_height: u32,
}


// --- Input encoding ----------------------------------------------------------------

Key_Action :: enum c.int {
	Release = 0,
	Press   = 1,
	Repeat  = 2,
}

Mods :: distinct u16

MOD_SHIFT :: Mods(1 << 0)
MOD_CTRL  :: Mods(1 << 1)
MOD_ALT   :: Mods(1 << 2)
MOD_SUPER :: Mods(1 << 3)

// Values follow GhosttyKey (key/event.h); only the keys typo maps are named
Key :: enum c.int {
	Unidentified = 0,
	Backquote, Backslash, Bracket_Left, Bracket_Right, Comma,
	Digit_0, Digit_1, Digit_2, Digit_3, Digit_4, Digit_5, Digit_6, Digit_7, Digit_8, Digit_9,
	Equal, Intl_Backslash, Intl_Ro, Intl_Yen,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Minus, Period, Quote, Semicolon, Slash,
	Alt_Left, Alt_Right, Backspace, Caps_Lock, Context_Menu, Control_Left, Control_Right,
	Enter, Meta_Left, Meta_Right, Shift_Left, Shift_Right, Space, Tab,
	Convert, Kana_Mode, Non_Convert,
	Delete, End, Help, Home, Insert, Page_Down, Page_Up,
	Arrow_Down, Arrow_Left, Arrow_Right, Arrow_Up,
	Num_Lock,
	Numpad_0, Numpad_1, Numpad_2, Numpad_3, Numpad_4,
	Numpad_5, Numpad_6, Numpad_7, Numpad_8, Numpad_9,
	Numpad_Add, Numpad_Backspace, Numpad_Clear, Numpad_Clear_Entry, Numpad_Comma, Numpad_Decimal,
	Numpad_Divide, Numpad_Enter, Numpad_Equal, Numpad_Memory_Add, Numpad_Memory_Clear,
	Numpad_Memory_Recall, Numpad_Memory_Store, Numpad_Memory_Subtract, Numpad_Multiply,
	Numpad_Paren_Left, Numpad_Paren_Right, Numpad_Subtract, Numpad_Separator,
	Numpad_Up, Numpad_Down, Numpad_Right, Numpad_Left, Numpad_Begin, Numpad_Home, Numpad_End,
	Numpad_Insert, Numpad_Delete, Numpad_Page_Up, Numpad_Page_Down,
	Escape,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

Mouse_Action :: enum c.int {
	Press   = 0,
	Release = 1,
	Motion  = 2,
}

Mouse_Button :: enum c.int {
	Unknown = 0,
	Left    = 1,
	Right   = 2,
	Middle  = 3,
	Four    = 4, // wheel up
	Five    = 5, // wheel down
}

Mouse_Position :: struct {
	x, y: f32,
}

Mouse_Encoder_Size :: struct {
	size:           c.size_t,
	screen_width:   u32,
	screen_height:  u32,
	cell_width:     u32,
	cell_height:    u32,
	padding_top:    u32,
	padding_bottom: u32,
	padding_right:  u32,
	padding_left:   u32,
}

Mouse_Encoder_Option :: enum c.int {
	Event              = 1,
	Format             = 2,
	Size               = 3,
	Any_Button_Pressed = 4,
	Track_Last_Cell    = 5,
}


// --- Procedures --------------------------------------------------------------------

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign vt {
	terminal_new :: proc(allocator: rawptr, terminal: ^Terminal, cols, rows: u16) -> Result ---
	terminal_free :: proc(terminal: Terminal) ---
	// Back to a new terminal's state, scrollback included (as RIS)
	terminal_reset :: proc(terminal: Terminal) ---
	terminal_resize :: proc(
		terminal: Terminal,
		cols, rows: u16,
		cell_width_px, cell_height_px: u32,
	) -> Result ---
	terminal_set :: proc(terminal: Terminal, option: Terminal_Option, value: rawptr) -> Result ---
	terminal_get :: proc(terminal: Terminal, data: Terminal_Data, out: rawptr) -> Result ---
	terminal_vt_write :: proc(terminal: Terminal, data: [^]u8, len: c.size_t) ---
	terminal_scroll_viewport :: proc(terminal: Terminal, behavior: Scroll_Viewport) -> Result ---

	render_state_new :: proc(allocator: rawptr, state: ^Render_State) -> Result ---
	render_state_free :: proc(state: Render_State) ---
	render_state_update :: proc(state: Render_State, terminal: Terminal) -> Result ---
	render_state_clean :: proc(state: Render_State) -> Result ---
	render_state_get :: proc(state: Render_State, data: Render_Data, out: rawptr) -> Result ---
	render_state_row_iterator_new :: proc(allocator: rawptr, iterator: ^Row_Iterator) -> Result ---
	render_state_row_iterator_free :: proc(iterator: Row_Iterator) ---
	render_state_row_iterator_next :: proc(iterator: Row_Iterator) -> bool ---
	render_state_row_get :: proc(iterator: Row_Iterator, data: Row_Data, out: rawptr) -> Result ---
	render_state_row_cells_new :: proc(allocator: rawptr, cells: ^Row_Cells) -> Result ---
	render_state_row_cells_free :: proc(cells: Row_Cells) ---
	render_state_row_cells_next :: proc(cells: Row_Cells) -> bool ---
	render_state_row_cells_get :: proc(
		cells: Row_Cells,
		data: Row_Cells_Data,
		out: rawptr,
	) -> Result ---

	cell_get :: proc(cell: Cell, data: Cell_Data, out: rawptr) -> Result ---

	key_event_new :: proc(allocator: rawptr, event: ^Key_Event) -> Result ---
	key_event_free :: proc(event: Key_Event) ---
	key_event_set_action :: proc(event: Key_Event, action: Key_Action) -> Result ---
	key_event_set_key :: proc(event: Key_Event, key: Key) -> Result ---
	key_event_set_mods :: proc(event: Key_Event, mods: Mods) -> Result ---
	key_event_set_utf8 :: proc(event: Key_Event, utf8: Ghostty_String) -> Result ---
	key_event_set_unshifted_codepoint :: proc(event: Key_Event, codepoint: u32) -> Result ---
	key_encoder_new :: proc(allocator: rawptr, encoder: ^Key_Encoder) -> Result ---
	key_encoder_free :: proc(encoder: Key_Encoder) ---
	key_encoder_set_from_terminal :: proc(encoder: Key_Encoder, terminal: Terminal) -> Result ---
	key_encoder_encode :: proc(
		encoder: Key_Encoder,
		event: Key_Event,
		out_buf: [^]u8,
		out_buf_size: c.size_t,
		out_len: ^c.size_t,
	) -> Result ---

	mouse_event_new :: proc(allocator: rawptr, event: ^Mouse_Event) -> Result ---
	mouse_event_free :: proc(event: Mouse_Event) ---
	mouse_event_set_action :: proc(event: Mouse_Event, action: Mouse_Action) -> Result ---
	mouse_event_set_button :: proc(event: Mouse_Event, button: Mouse_Button) -> Result ---
	mouse_event_clear_button :: proc(event: Mouse_Event) -> Result ---
	mouse_event_set_mods :: proc(event: Mouse_Event, mods: Mods) -> Result ---
	mouse_event_set_position :: proc(event: Mouse_Event, position: Mouse_Position) -> Result ---
	mouse_encoder_new :: proc(allocator: rawptr, encoder: ^Mouse_Encoder) -> Result ---
	mouse_encoder_free :: proc(encoder: Mouse_Encoder) ---
	mouse_encoder_set :: proc(
		encoder: Mouse_Encoder,
		option: Mouse_Encoder_Option,
		value: rawptr,
	) -> Result ---
	mouse_encoder_set_from_terminal :: proc(
		encoder: Mouse_Encoder,
		terminal: Terminal,
	) -> Result ---
	mouse_encoder_encode :: proc(
		encoder: Mouse_Encoder,
		event: Mouse_Event,
		out_buf: [^]u8,
		out_buf_size: c.size_t,
		out_len: ^c.size_t,
	) -> Result ---

	// The built-in 256-color palette (out must hold 256 entries)
	color_palette_default :: proc(out: [^]Color_Rgb) ---

	terminal_grid_ref :: proc(terminal: Terminal, point: Point, out_ref: ^Grid_Ref) -> Result ---
	formatter_terminal_new :: proc(
		allocator: rawptr,
		out_formatter: ^Formatter,
		terminal: Terminal,
	) -> Result ---
	formatter_set :: proc(
		formatter: Formatter,
		option: Formatter_Option,
		value: rawptr,
	) -> Result ---
	formatter_format_alloc :: proc(
		formatter: Formatter,
		allocator: rawptr,
		out_ptr: ^[^]u8,
		out_len: ^c.size_t,
	) -> Result ---
	formatter_free :: proc(formatter: Formatter) ---
	selection_gesture_new :: proc(allocator: rawptr, out_gesture: ^Selection_Gesture) -> Result ---
	selection_gesture_free :: proc(gesture: Selection_Gesture, terminal: Terminal) ---
	selection_gesture_event :: proc(
		gesture: Selection_Gesture,
		terminal: Terminal,
		event: Gesture_Event,
		out_selection: ^Selection,
	) -> Result ---
	selection_gesture_event_new :: proc(
		allocator: rawptr,
		out_event: ^Gesture_Event,
		type: Gesture_Event_Type,
	) -> Result ---
	selection_gesture_event_free :: proc(event: Gesture_Event) ---
	selection_gesture_event_set :: proc(
		event: Gesture_Event,
		option: Gesture_Event_Option,
		value: rawptr,
	) -> Result ---

	search_new :: proc(allocator: rawptr, out_search: ^Search, terminal: Terminal) -> Result ---
	search_free :: proc(search: Search) ---
	search_tick :: proc(search: Search, out_status: ^Search_Status) -> Result ---
	search_feed :: proc(search: Search) -> Result ---
	search_select_next :: proc(search: Search) -> Result --- // toward older content
	search_select_prev :: proc(search: Search) -> Result --- // toward newer content
	search_set :: proc(search: Search, option: Search_Option, value: rawptr) -> Result ---
	search_get :: proc(search: Search, data: Search_Data, value: rawptr) -> Result ---
	terminal_point_from_grid_ref :: proc(
		terminal: Terminal,
		ref: ^Grid_Ref,
		tag: Point_Tag,
		out: ^Point_Coordinate,
	) -> Result ---

	// JSON manifest of the library's C types (sizes, alignments, enum values)
	type_json :: proc() -> cstring ---

	paste_encode :: proc(
		data: [^]u8,
		data_len: c.size_t,
		bracketed: bool,
		buf: [^]u8,
		buf_len: c.size_t,
		out_written: ^c.size_t,
	) -> Result ---
}

// Frees memory the library allocated (e.g. formatted selection text)
@(default_calling_convention = "c")
foreign vt {
	@(link_name = "ghostty_free")
	ghostty_free :: proc(allocator: rawptr, ptr: rawptr, len: c.size_t) ---
}


// Sized structs (those with a `size` field) must carry their own size, like
// GHOSTTY_INIT_SIZED in C
init_sized :: proc($T: typeid) -> (v: T) {
	v.size = size_of(T)
	return
}
