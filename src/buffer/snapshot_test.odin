package buffer

import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"


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
snapshot_text :: proc(s: ^Snapshot) -> string {
	return string(snapshot_read_alloc(s, 0, s.length))
}


// The snapshot reads as `text`: whole, in ranges, and by line
@(private = "file")
check_snapshot :: proc(t: ^testing.T, s: ^Snapshot, text: string) {
	testing.expect_value(t, s.length, len(text))
	testing.expect_value(t, snapshot_text(s), text)
	testing.expect_value(t, s.lines, strings.count(text, "\n") + 1)

	// Ranges starting and ending anywhere
	for _ in 0 ..< 20 {
		lo := rand.int_max(len(text) + 1)
		hi := lo + rand.int_max(len(text) - lo + 1)
		testing.expect_value(t, string(snapshot_read_alloc(s, lo, hi)), text[lo:hi])
	}

	// Line starts
	start := 0
	for line in 0 ..< s.lines {
		testing.expect_value(t, snapshot_line_start(s, line), start)
		next := strings.index_byte(text[start:], '\n')
		start += next + 1
	}
}


// Every piece of the add store lies in one block
@(private = "file")
check_pieces_in_blocks :: proc(t: ^testing.T, b: ^Buffer) {
	pieces := make([dynamic]Piece, context.temp_allocator)
	collect(b, b.root, &pieces)

	added := &b.stores[.Added]
	for p in pieces {
		if p.source != .Added do continue
		testing.expect(t, p.start + p.length <= block_end(added, p.start))
	}
}


// A snapshot keeps its text through edits, undo, redo and the buffer's end
@(test)
test_snapshot_keeps_text :: proc(t: ^testing.T) {
	rand.reset(77)
	b := make_buffer("first line\nsecond line\nthird")

	sels := []Selection{{0, 0, -1}}
	begin(&b, .Other, 0, sels)
	replace(&b, 6, 4, "row\nsplit")
	end(&b, sels)

	before := strings.clone(contents(&b))
	defer delete(before)
	s := snapshot(&b)
	defer snapshot_release(&s)
	testing.expect_value(t, s.version, b.version)
	check_snapshot(t, &s, before)

	// Edits, then undo and redo
	begin(&b, .Other, 10 * COALESCE_NS, sels)
	replace(&b, 0, 5, "")
	replace(&b, 3, 0, strings.repeat("added\n", 100, context.temp_allocator))
	end(&b, sels)
	check_snapshot(t, &s, before)

	undo(&b)
	undo(&b)
	check_snapshot(t, &s, before)
	redo(&b)
	replace_untracked(&b, 0, length(&b), "gone")
	check_snapshot(t, &s, before)

	// The buffer's end leaves the snapshot's blocks alive
	buffer_destroy(&b)
	check_snapshot(t, &s, before)
}


// Text crossing the add store's block boundaries: typed byte by byte, pasted
// in one piece larger than a block, and edited at random around them
@(test)
test_snapshot_block_boundaries :: proc(t: ^testing.T) {
	rand.reset(5150)
	b := make_buffer("start\n")
	defer buffer_destroy(&b)

	ref := make([dynamic]u8)
	defer delete(ref)
	append(&ref, "start\n")

	// Typing past the first block boundary
	sels := []Selection{{0, 0, -1}}
	letters := "abc\n"
	begin(&b, .Typing, 0, sels)
	for i in 0 ..< FIRST_BLOCK + 100 {
		c := letters[i % 4:][:1]
		replace(&b, len(ref), 0, c)
		append(&ref, c)
	}
	end(&b, sels)
	check_pieces_in_blocks(t, &b)

	// A paste larger than a block
	paste := strings.repeat("pasted text\n", 3 * FIRST_BLOCK / 12, context.temp_allocator)
	begin(&b, .Other, 10 * COALESCE_NS, sels)
	replace(&b, 3, 2, paste)
	end(&b, sels)
	remove_range_ref(&ref, 3, 2)
	inject_at(&ref, 3, ..transmute([]u8)paste)
	check_pieces_in_blocks(t, &b)
	testing.expect(t, len(b.stores[.Added].mem.blocks) >= 3)

	s := snapshot(&b)
	defer snapshot_release(&s)
	whole := strings.clone(string(ref[:]))
	defer delete(whole)
	check_snapshot(t, &s, whole)

	// Random edits; each step's snapshot matches the reference
	for step in 0 ..< 50 {
		offset := rand.int_max(len(ref) + 1)
		remove := min(rand.int_max(3000), len(ref) - offset)
		text := strings.repeat("xy\n", rand.int_max(2000), context.temp_allocator)

		begin(&b, .Other, u64(step + 20) * 10 * COALESCE_NS, sels)
		replace(&b, offset, remove, text)
		end(&b, sels)
		remove_range_ref(&ref, offset, remove)
		inject_at(&ref, offset, ..transmute([]u8)text)

		step_snapshot := snapshot(&b)
		testing.expect_value(t, snapshot_text(&step_snapshot), string(ref[:]))
		snapshot_release(&step_snapshot)
		free_all(context.temp_allocator)
	}
	check_pieces_in_blocks(t, &b)
	testing.expect_value(t, contents(&b), string(ref[:]))

	// The first snapshot still reads as it was
	check_snapshot(t, &s, whole)
}


@(private = "file")
Reader :: struct {
	mutex:   sync.Mutex,
	queue:   [dynamic]Snapshot_Check,
	done:    bool,
	checked: int,
	wrong:   int,
}

@(private = "file")
Snapshot_Check :: struct {
	snapshot: Snapshot,
	expected: string, // owned
}


// A thread reads snapshots while the test's thread goes on editing, then
// destroys the buffer before the reader is through
@(test)
test_snapshot_read_on_another_thread :: proc(t: ^testing.T) {
	rand.reset(8086)
	b := make_buffer(strings.repeat("some words on a line\n", 500, context.temp_allocator))

	reader: Reader
	worker := thread.create_and_start_with_poly_data(&reader, read_snapshots, context)

	sels := []Selection{{0, 0, -1}}
	for step in 0 ..< 300 {
		n := length(&b)
		offset := rand.int_max(n + 1)
		remove := min(rand.int_max(40), n - offset)
		text := strings.repeat("new text\n", rand.int_max(200), context.temp_allocator)

		begin(&b, .Other, u64(step) * 10 * COALESCE_NS, sels)
		replace(&b, offset, remove, text)
		end(&b, sels)
		if step % 7 == 3 do undo(&b)

		// Hand over the text and what it should read as
		check := Snapshot_Check{snapshot(&b), strings.clone(contents(&b))}
		sync.guard(&reader.mutex)
		append(&reader.queue, check)
		free_all(context.temp_allocator)
	}
	buffer_destroy(&b)

	sync.mutex_lock(&reader.mutex)
	reader.done = true
	sync.mutex_unlock(&reader.mutex)
	thread.join(worker)
	thread.destroy(worker)

	testing.expect_value(t, reader.checked, 300)
	testing.expect_value(t, reader.wrong, 0)
	delete(reader.queue)
}


@(private = "file")
read_snapshots :: proc(r: ^Reader) {
	for {
		sync.mutex_lock(&r.mutex)
		check, have := pop_front_safe(&r.queue)
		done := r.done
		sync.mutex_unlock(&r.mutex)

		if !have {
			if done do return
			thread.yield()
			continue
		}

		text := snapshot_read_alloc(&check.snapshot, 0, check.snapshot.length, context.allocator)
		if string(text) != check.expected do r.wrong += 1
		r.checked += 1

		delete(text)
		delete(check.expected)
		snapshot_release(&check.snapshot)
	}
}


@(private = "file")
remove_range_ref :: proc(ref: ^[dynamic]u8, offset, count: int) {
	copy(ref[offset:], ref[offset + count:])
	resize(ref, len(ref) - count)
}
