package syntax

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "../buffer"

// Built by build.py.
when ODIN_OS == .Windows {
	foreign import ts_bench "../../build/obj/tree_sitter.lib"
} else {
	foreign import ts_bench "../../build/obj/libtree_sitter.a"
}
@(default_calling_convention = "c")
foreign ts_bench {
	ts_parser_parse_string :: proc(self: ^TSParser, old_tree: ^TSTree, str: [^]u8, length: u32) -> ^TSTree ---
	ts_tree_copy :: proc(self: ^TSTree) -> ^TSTree ---
}

// Opt-in benchmark: BENCH_FILE=<file.odin> odin test src/syntax -o:speed
//   -define:ODIN_TEST_NAMES=syntax.bench_reparse
@(test)
bench_reparse :: proc(t: ^testing.T) {
	path := os.get_env("BENCH_FILE", context.temp_allocator)
	if path == "" do return
	data, _ := os.read_entire_file(path, context.allocator)
	b: buffer.Buffer
	buffer.buffer_init(&b, data)
	defer buffer.buffer_destroy(&b)

	parser := ts_parser_new()
	ts_parser_set_language(parser, tree_sitter_odin())
	start := time.tick_now()
	tree := ts_parser_parse(parser, nil, buffer_input_bench(&b))
	fmt.println("full parse (piece tree input):", time.tick_since(start))

	mid := buffer.line_start(&b, buffer.line_count(&b) / 2)
	for i in 0 ..< 5 {
		buffer.begin(&b, .Other, u64(i) << 40, {})
		buffer.replace(&b, mid, 0, "x")
		buffer.end(&b, {})
		for c in buffer.take_changes(&b) {
			e := TSInputEdit{u32(c.offset), u32(c.offset + c.old_len), u32(c.offset + c.new_len),
				{u32(c.start.row), u32(c.start.col)}, {u32(c.old_end.row), u32(c.old_end.col)}, {u32(c.new_end.row), u32(c.new_end.col)}}
			ts_tree_edit(tree, &e)
		}
		start = time.tick_now()
		new_tree := ts_parser_parse(parser, tree, buffer_input_bench(&b))
		fmt.println("incremental (piece tree input):", time.tick_since(start))
		ts_tree_delete(tree)
		tree = new_tree
	}

	// Same with a contiguous string.
	text := buffer.read_alloc(&b, 0, buffer.length(&b), context.allocator)
	defer delete(text)
	t2 := ts_parser_parse_string(parser, nil, raw_data(text), u32(len(text)))
	mid2 := u32(mid)
	pt := buffer.point_at(&b, mid)
	e := TSInputEdit{mid2, mid2, mid2 + 1, {u32(pt.row), u32(pt.col)}, {u32(pt.row), u32(pt.col)}, {u32(pt.row), u32(pt.col + 1)}}
	text2 := make([]u8, len(text) + 1)
	defer delete(text2)
	copy(text2, text[:mid]); text2[mid] = 'y'; copy(text2[mid + 1:], text[mid:])
	ts_tree_edit(t2, &e)
	start = time.tick_now()
	t3 := ts_parser_parse_string(parser, t2, raw_data(text2), u32(len(text2)))
	fmt.println("incremental (string input):", time.tick_since(start))
	ts_tree_delete(t2); ts_tree_delete(t3); ts_tree_delete(tree)
	ts_parser_delete(parser)
}

@(private = "file")
buffer_input_bench :: proc(b: ^buffer.Buffer) -> TSInput {
	read :: proc "c" (payload: rawptr, byte_index: u32, position: TSPoint, bytes_read: ^u32) -> [^]u8 {
		context = runtime.default_context()
		chunk := buffer.chunk_at((^buffer.Buffer)(payload), int(byte_index))
		bytes_read^ = u32(len(chunk))
		return raw_data(chunk)
	}
	return {payload = b, read = read, encoding = .UTF8}
}
