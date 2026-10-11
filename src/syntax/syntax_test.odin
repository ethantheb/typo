package syntax

import "core:log"
import "core:math/rand"
import "core:strings"
import "core:testing"

import "../buffer"

// Run with: python build.py --test  (builds the tree-sitter library first)

SAMPLE :: `package demo

import "core:fmt"

/* outer /* nested */ still comment */
Point :: struct {
	x, y: f32,
}

// add two numbers
add :: proc(a: int, b: int) -> int {
	s := "hi\n"
	return a + b + 42
}
`

@(private = "file")
make_buffer :: proc(s: string) -> buffer.Buffer {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(s))
	return b
}

@(private = "file")
highlight_all :: proc(h: ^Highlighter, b: ^buffer.Buffer) -> []Highlight {
	out := make([]Highlight, buffer.length(b), context.temp_allocator)
	highlight_range(h, b, 0, out)
	return out
}

// Highlight of the n-th occurrence (0-based) of `needle` in `text`, at its first byte.
@(private = "file")
hl_at :: proc(hl: []Highlight, text, needle: string, nth := 0, offset := 0) -> Highlight {
	pos := -1
	from := 0
	for _ in 0 ..= nth {
		i := strings.index(text[from:], needle)
		if i < 0 do return .None
		pos = from + i
		from = pos + 1
	}
	return hl[pos + offset]
}

@(private = "file")
check_sample :: proc(t: ^testing.T, hl: []Highlight, structural: bool) {
	testing.expect_value(t, hl_at(hl, SAMPLE, "package"), Highlight.Keyword)
	testing.expect_value(t, hl_at(hl, SAMPLE, `"core:fmt"`), Highlight.String)
	testing.expect_value(t, hl_at(hl, SAMPLE, "outer"), Highlight.Comment)
	testing.expect_value(t, hl_at(hl, SAMPLE, "still"), Highlight.Comment) // after the nested */
	testing.expect_value(t, hl_at(hl, SAMPLE, "add two"), Highlight.Comment)
	testing.expect_value(t, hl_at(hl, SAMPLE, "proc"), Highlight.Keyword)
	testing.expect_value(t, hl_at(hl, SAMPLE, "f32"), Highlight.Type)
	testing.expect_value(t, hl_at(hl, SAMPLE, "a: int", 0, 3), Highlight.Type)
	testing.expect_value(t, hl_at(hl, SAMPLE, "42"), Highlight.Number)
	testing.expect_value(t, hl_at(hl, SAMPLE, "return"), Highlight.Keyword)
	testing.expect_value(t, hl_at(hl, SAMPLE, `\n`), Highlight.Escape)
	testing.expect_value(t, hl_at(hl, SAMPLE, "Point"), Highlight.Type)
	if structural {
		// Only a parser knows these from context.
		testing.expect_value(t, hl_at(hl, SAMPLE, "add ::"), Highlight.Function)
		testing.expect_value(t, hl_at(hl, SAMPLE, "a: int"), Highlight.Parameter)
		testing.expect_value(t, hl_at(hl, SAMPLE, "x, y"), Highlight.Property)
	}
}

@(test)
test_tree_sitter_odin :: proc(t: ^testing.T) {
	b := make_buffer(SAMPLE)
	defer buffer.buffer_destroy(&b)
	h: Highlighter
	highlighter_open(&h, &b, "demo.odin")
	defer highlighter_close(&h)
	testing.expect_value(t, h.backend, Backend.Tree_Sitter)
	check_sample(t, highlight_all(&h, &b), true)
}

@(test)
test_lexer_odin :: proc(t: ^testing.T) {
	b := make_buffer(SAMPLE)
	defer buffer.buffer_destroy(&b)
	h: Highlighter
	h.lang = .Odin
	h.backend = .Lexer
	lexer_open(&h.lx, .Odin)
	defer highlighter_close(&h)
	check_sample(t, highlight_all(&h, &b), false)
}

// After random edits, the incrementally re-parsed tree highlights exactly like
// a fresh parse of the same text.
@(test)
test_tree_sitter_incremental :: proc(t: ^testing.T) {
	rand.reset(31337)
	b := make_buffer(SAMPLE)
	defer buffer.buffer_destroy(&b)
	h: Highlighter
	highlighter_open(&h, &b, "demo.odin")
	defer highlighter_close(&h)

	snippets := []string{"x", " ", "\n", "/*", "*/", `"`, "proc", "::", "{", "}", "// c\n", "123"}
	for step in 0 ..< 200 {
		n := buffer.length(&b)
		offset := rand.int_max(n + 1)
		buffer.begin(&b, .Other, u64(step) << 40, {})
		buffer.replace(&b, offset, min(rand.int_max(4), n - offset), rand.choice(snippets))
		buffer.end(&b, {})
		if rand.int_max(5) == 0 do buffer.undo(&b)
		highlighter_edit(&h, &b)

		incremental := highlight_all(&h, &b)
		text := string(buffer.read_alloc(&b, 0, buffer.length(&b)))
		fresh_b := make_buffer(text)
		fresh: Highlighter
		highlighter_open(&fresh, &fresh_b, "demo.odin")
		expected := highlight_all(&fresh, &fresh_b)
		if !testing.expect_value(t, string(transmute([]u8)incremental), string(transmute([]u8)expected)) {
			log.infof("step %d text:\n%s", step, text)
		}
		highlighter_close(&fresh)
		buffer.buffer_destroy(&fresh_b)
		free_all(context.temp_allocator)
		if t.error_count > 0 do break
	}
}

// Lexer state carries across checkpoints, and edits/undo invalidate correctly.
@(test)
test_lexer_checkpoints :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< 3000 do strings.write_string(&sb, "x := 1 // line\n")
	b := make_buffer(strings.to_string(sb))
	defer buffer.buffer_destroy(&b)
	h: Highlighter
	h.lang = .Odin
	h.backend = .Lexer
	lexer_open(&h.lx, .Odin)
	defer highlighter_close(&h)

	line_hl :: proc(h: ^Highlighter, b: ^buffer.Buffer, line: int) -> Highlight {
		out: [1]Highlight
		// Pretend the view is there, and give the catch-up enough frames.
		highlight_range(h, b, buffer.line_start(b, line), out[:])
		for _ in 0 ..< 100 do highlighter_edit(h, b)
		highlight_range(h, b, buffer.line_start(b, line), out[:])
		return out[0]
	}

	testing.expect_value(t, line_hl(&h, &b, 2500), Highlight.None) // "x"

	// Open a block comment at the top: everything below becomes comment.
	buffer.begin(&b, .Other, 0, {})
	buffer.replace(&b, 0, 0, "/*")
	buffer.end(&b, {})
	highlighter_edit(&h, &b)
	testing.expect_value(t, line_hl(&h, &b, 2500), Highlight.Comment)

	buffer.undo(&b)
	highlighter_edit(&h, &b)
	testing.expect_value(t, line_hl(&h, &b, 2500), Highlight.None)
}

PY_SAMPLE :: `# a comment
@dataclass
class Point:
    """Doc string
    spanning lines"""
    def norm(self, k=2):
        return f"{self.x}" + 'y' if True else None  # trailing
`

@(test)
test_lexer_python :: proc(t: ^testing.T) {
	b := make_buffer(PY_SAMPLE)
	defer buffer.buffer_destroy(&b)
	h: Highlighter
	highlighter_open(&h, &b, "point.py")
	defer highlighter_close(&h)
	testing.expect_value(t, h.backend, Backend.Lexer) // no Python grammar yet
	hl := highlight_all(&h, &b)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "a comment"), Highlight.Comment)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "@dataclass"), Highlight.Attribute)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "class Point"), Highlight.Keyword)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "Doc"), Highlight.String)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "spanning"), Highlight.String) // second line of """
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "def"), Highlight.Keyword)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "self"), Highlight.Variable_Builtin)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "2"), Highlight.Number)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "'y'"), Highlight.String)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "True"), Highlight.Constant)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "trailing"), Highlight.Comment)
	testing.expect_value(t, hl_at(hl, PY_SAMPLE, "return"), Highlight.Keyword) // after the """ closed
}
