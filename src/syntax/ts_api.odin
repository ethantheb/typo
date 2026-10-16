package syntax

// Bindings to the tree-sitter C API (vendor/tree-sitter, v0.25.9) and the
// grammars compiled into the same library by build.py.

when ODIN_OS == .Windows {
	foreign import ts "../../build/obj/tree_sitter.lib"
} else {
	foreign import ts "../../build/obj/libtree_sitter.a"
}

TSParser :: struct {}
TSTree :: struct {}
TSQuery :: struct {}
TSQueryCursor :: struct {}
TSLanguage :: struct {}

TSPoint :: struct {
	row:    u32,
	column: u32,
}

TSInputEncoding :: enum i32 {
	UTF8,
	UTF16LE,
	UTF16BE,
	Custom,
}

TSInput :: struct {
	payload:  rawptr,
	read:     proc "c" (payload: rawptr, byte_index: u32, position: TSPoint, bytes_read: ^u32) -> [^]u8,
	encoding: TSInputEncoding,
	decode:   rawptr,
}

TSInputEdit :: struct {
	start_byte:    u32,
	old_end_byte:  u32,
	new_end_byte:  u32,
	start_point:   TSPoint,
	old_end_point: TSPoint,
	new_end_point: TSPoint,
}

TSNode :: struct {
	ctx:  [4]u32,
	id:   rawptr,
	tree: ^TSTree,
}

TSQueryCapture :: struct {
	node:  TSNode,
	index: u32,
}

TSQueryMatch :: struct {
	id:            u32,
	pattern_index: u16,
	capture_count: u16,
	captures:      [^]TSQueryCapture,
}

TSQueryPredicateStepType :: enum i32 {
	Done,
	Capture,
	String,
}

TSQueryPredicateStep :: struct {
	type:     TSQueryPredicateStepType,
	value_id: u32,
}

TSQueryError :: enum i32 {
	None,
	Syntax,
	NodeType,
	Field,
	Capture,
	Structure,
	Language,
}

@(default_calling_convention = "c")
foreign ts {
	ts_parser_new :: proc() -> ^TSParser ---
	ts_parser_delete :: proc(self: ^TSParser) ---
	ts_parser_set_language :: proc(self: ^TSParser, language: ^TSLanguage) -> bool ---
	ts_parser_parse :: proc(self: ^TSParser, old_tree: ^TSTree, input: TSInput) -> ^TSTree ---

	ts_tree_delete :: proc(self: ^TSTree) ---
	ts_tree_edit :: proc(self: ^TSTree, edit: ^TSInputEdit) ---
	ts_tree_root_node :: proc(self: ^TSTree) -> TSNode ---

	ts_node_type :: proc(self: TSNode) -> cstring ---
	ts_node_start_byte :: proc(self: TSNode) -> u32 ---
	ts_node_end_byte :: proc(self: TSNode) -> u32 ---
	ts_node_is_null :: proc(self: TSNode) -> bool ---
	ts_node_parent :: proc(self: TSNode) -> TSNode ---

	ts_query_new :: proc(language: ^TSLanguage, source: [^]u8, source_len: u32, error_offset: ^u32, error_type: ^TSQueryError) -> ^TSQuery ---
	ts_query_pattern_count :: proc(self: ^TSQuery) -> u32 ---
	ts_query_capture_count :: proc(self: ^TSQuery) -> u32 ---
	ts_query_capture_name_for_id :: proc(self: ^TSQuery, index: u32, length: ^u32) -> [^]u8 ---
	ts_query_string_value_for_id :: proc(self: ^TSQuery, index: u32, length: ^u32) -> [^]u8 ---
	ts_query_predicates_for_pattern :: proc(self: ^TSQuery, pattern_index: u32, step_count: ^u32) -> [^]TSQueryPredicateStep ---

	ts_query_cursor_new :: proc() -> ^TSQueryCursor ---
	ts_query_cursor_delete :: proc(self: ^TSQueryCursor) ---
	ts_query_cursor_exec :: proc(self: ^TSQueryCursor, query: ^TSQuery, node: TSNode) ---
	ts_query_cursor_set_byte_range :: proc(self: ^TSQueryCursor, start_byte, end_byte: u32) -> bool ---
	ts_query_cursor_next_capture :: proc(self: ^TSQueryCursor, match: ^TSQueryMatch, capture_index: ^u32) -> bool ---

	// Grammars
	tree_sitter_odin :: proc() -> ^TSLanguage ---
	tree_sitter_toml :: proc() -> ^TSLanguage ---
}
