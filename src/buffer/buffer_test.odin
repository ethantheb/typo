package buffer

import "core:math/rand"
import "core:strings"
import "core:testing"

// Randomized tests against a naive reference: a plain byte array edited the
// same way. Run with: odin test src/buffer

@(private = "file")
make_buffer :: proc(s: string) -> Buffer {
	b: Buffer
	buffer_init(&b, transmute([]u8)strings.clone(s))
	return b
}

@(private = "file")
contents :: proc(b: ^Buffer) -> string {
	return string(read_alloc(b, 0, length(b)))
}

@(private = "file")
check_lines :: proc(t: ^testing.T, b: ^Buffer, ref: string) {
	expected_lines := strings.count(ref, "\n") + 1
	testing.expect_value(t, line_count(b), expected_lines)

	start := 0
	for line in 0 ..< expected_lines {
		testing.expect_value(t, line_start(b, line), start)
		next := strings.index_byte(ref[start:], '\n')
		end := next < 0 ? len(ref) : start + next
		content_end := end
		// A '\r' is only part of the line ending when a '\n' follows it.
		if next >= 0 && content_end > start && ref[content_end - 1] == '\r' do content_end -= 1
		testing.expect_value(t, line_end(b, line), content_end)
		start = end + 1
	}
	for offset in 0 ..= len(ref) {
		testing.expect_value(t, offset_to_line(b, offset), strings.count(ref[:offset], "\n"))
	}
}

@(private = "file")
random_text :: proc(n: int) -> string {
	alphabet := "ab\nc\r\n xyz"
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< n {
		strings.write_byte(&sb, alphabet[rand.int_max(len(alphabet))])
	}
	return strings.to_string(sb)
}

@(test)
test_basic_edits :: proc(t: ^testing.T) {
	b := make_buffer("hello\nworld")
	defer buffer_destroy(&b)

	sels := []Selection{{0, 0, -1}}
	begin(&b, .Other, 0, sels)
	replace(&b, 5, 0, ", there")
	replace(&b, 0, 1, "J")
	end(&b, sels)
	testing.expect_value(t, contents(&b), "Jello, there\nworld")
	check_lines(t, &b, "Jello, there\nworld")

	_, ok := undo(&b)
	testing.expect(t, ok)
	testing.expect_value(t, contents(&b), "hello\nworld")
	_, ok = redo(&b)
	testing.expect(t, ok)
	testing.expect_value(t, contents(&b), "Jello, there\nworld")
}

@(test)
test_empty_buffer :: proc(t: ^testing.T) {
	b := make_buffer("")
	defer buffer_destroy(&b)
	testing.expect_value(t, length(&b), 0)
	testing.expect_value(t, line_count(&b), 1)
	testing.expect_value(t, line_start(&b, 0), 0)
	testing.expect_value(t, line_end(&b, 0), 0)

	begin(&b, .Typing, 0, {})
	replace(&b, 0, 0, "a\n")
	end(&b, {})
	check_lines(t, &b, "a\n")
}

@(test)
test_random_against_reference :: proc(t: ^testing.T) {
	rand.reset(1234)
	ref := make([dynamic]u8)
	defer delete(ref)
	append(&ref, random_text(200))
	b := make_buffer(string(ref[:]))
	defer buffer_destroy(&b)

	snapshots := make([dynamic]string)
	defer {
		for s in snapshots do delete(s)
		delete(snapshots)
	}
	append(&snapshots, strings.clone(string(ref[:])))

	for step in 0 ..< 400 {
		begin(&b, .Other, u64(step) * 10 * COALESCE_NS, {})
		for _ in 0 ..< 1 + rand.int_max(3) {
			offset := rand.int_max(len(ref) + 1)
			remove := min(rand.int_max(8), len(ref) - offset)
			text := random_text(rand.int_max(6))
			replace(&b, offset, remove, text)
			remove_range_ref(&ref, offset, remove)
			inject_at(&ref, offset, ..transmute([]u8)text)
		}
		end(&b, {})
		append(&snapshots, strings.clone(string(ref[:])))

		testing.expect_value(t, contents(&b), string(ref[:]))
		if step % 50 == 0 do check_lines(t, &b, string(ref[:]))
		free_all(context.temp_allocator)
	}
	check_lines(t, &b, string(ref[:]))

	// Undo everything, checking each intermediate state, then redo it all.
	for i := len(snapshots) - 2; i >= 0; i -= 1 {
		_, ok := undo(&b)
		testing.expect(t, ok)
		testing.expect_value(t, contents(&b), snapshots[i])
	}
	_, ok := undo(&b)
	testing.expect(t, !ok)
	for i in 1 ..< len(snapshots) {
		redo(&b)
		testing.expect_value(t, contents(&b), snapshots[i])
	}
	check_lines(t, &b, snapshots[len(snapshots) - 1])
}

@(test)
test_typing_coalesces :: proc(t: ^testing.T) {
	b := make_buffer("")
	defer buffer_destroy(&b)
	sel := []Selection{{0, 0, -1}}
	for c, i in "hello" {
		begin(&b, .Typing, u64(i), sel)
		replace(&b, i, 0, string([]u8{u8(c)}))
		sel[0] = {i + 1, i + 1, -1}
		end(&b, sel)
	}
	testing.expect_value(t, contents(&b), "hello")
	// One undo step for the whole word, and one tree node for all of it.
	testing.expect_value(t, len(b.history.groups), 1)
	testing.expect_value(t, len(b.nodes) - 1 - len(b.free), 1)
	undo(&b)
	testing.expect_value(t, contents(&b), "")
}

@(test)
test_large_blocks :: proc(t: ^testing.T) {
	// Spans many newline-index blocks.
	rand.reset(99)
	text := strings.repeat("line of text\r\n", 20_000)
	b := make_buffer(text)
	defer {
		buffer_destroy(&b)
		delete(text)
	}
	testing.expect(t, b.crlf)
	testing.expect_value(t, line_count(&b), 20_001)
	testing.expect_value(t, line_start(&b, 12_345), 12_345 * 14)
	testing.expect_value(t, line_end(&b, 12_345), 12_345 * 14 + 12)
	testing.expect_value(t, offset_to_line(&b, 12_345 * 14 + 5), 12_345)

	begin(&b, .Other, 0, {})
	replace(&b, 100_000, 50_000, "X\n")
	end(&b, {})
	ref := strings.concatenate({text[:100_000], "X\n", text[150_000:]})
	defer delete(ref)
	testing.expect_value(t, contents(&b), ref)
	testing.expect_value(t, line_count(&b), strings.count(ref, "\n") + 1)
	testing.expect_value(t, line_start(&b, 15_000), nth_line_start(ref, 15_000))
}

@(private = "file")
nth_line_start :: proc(s: string, n: int) -> int {
	if n == 0 do return 0
	count := 0
	for c, i in s {
		if c == '\n' {
			count += 1
			if count == n do return i + 1
		}
	}
	return len(s)
}

@(private = "file")
remove_range_ref :: proc(ref: ^[dynamic]u8, offset, count: int) {
	copy(ref[offset:], ref[offset + count:])
	resize(ref, len(ref) - count)
}

@(private = "file")
ref_point :: proc(s: string, offset: int) -> Point {
	row := strings.count(s[:offset], "\n")
	line_start := strings.last_index_byte(s[:offset], '\n') + 1
	return {row, offset - line_start}
}

// Every edit, undo and redo reports a Change that transforms the previous
// contents into the new ones, with correct row/column points.
@(test)
test_change_log :: proc(t: ^testing.T) {
	rand.reset(777)
	b := make_buffer(random_text(300))
	defer buffer_destroy(&b)
	prev := strings.clone(contents(&b))
	defer delete(prev)

	for step in 0 ..< 300 {
		switch rand.int_max(4) {
		case 0:
			undo(&b)
		case 1:
			redo(&b)
		case:
			n := length(&b)
			offset := rand.int_max(n + 1)
			begin(&b, .Other, u64(step) * 10 * COALESCE_NS, {})
			replace(&b, offset, min(rand.int_max(10), n - offset), random_text(rand.int_max(8)))
			end(&b, {})
		}
		cur := contents(&b)
		changes := take_changes(&b)
		if cur == prev {
			testing.expect(t, len(changes) <= 1)
		} else if testing.expect_value(t, len(changes), 1) {
			c := changes[0]
			rebuilt := strings.concatenate({prev[:c.offset], cur[c.offset:][:c.new_len], prev[c.offset + c.old_len:]}, context.temp_allocator)
			testing.expect_value(t, rebuilt, cur)
			testing.expect_value(t, c.start, ref_point(prev, c.offset))
			testing.expect_value(t, c.old_end, ref_point(prev, c.offset + c.old_len))
			testing.expect_value(t, c.new_end, ref_point(cur, c.offset + c.new_len))
		}
		delete(prev)
		prev = strings.clone(cur)
		free_all(context.temp_allocator)
	}
}

@(test)
test_chunk_at :: proc(t: ^testing.T) {
	rand.reset(4242)
	b := make_buffer(random_text(500))
	defer buffer_destroy(&b)
	begin(&b, .Other, 0, {})
	for _ in 0 ..< 50 {
		n := length(&b)
		offset := rand.int_max(n + 1)
		replace(&b, offset, min(rand.int_max(5), n - offset), random_text(rand.int_max(6)))
	}
	end(&b, {})

	sb := strings.builder_make(context.temp_allocator)
	for offset := 0; offset < length(&b); {
		chunk := chunk_at(&b, offset)
		testing.expect(t, len(chunk) > 0)
		strings.write_bytes(&sb, chunk)
		offset += len(chunk)
	}
	testing.expect_value(t, strings.to_string(sb), contents(&b))
	testing.expect_value(t, len(chunk_at(&b, length(&b))), 0)
	// Starting mid-piece returns the rest of that piece.
	whole := contents(&b)
	for offset in 0 ..< length(&b) {
		chunk := chunk_at(&b, offset)
		testing.expect_value(t, string(chunk), whole[offset:][:len(chunk)])
	}
}
