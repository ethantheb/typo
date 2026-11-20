package words

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "../buffer"


@(private = "file")
make_buffer :: proc(s: string) -> buffer.Buffer {
	b: buffer.Buffer
	buffer.buffer_init(&b, transmute([]u8)strings.clone(s))
	return b
}


// The words of the buffer, with the caret at `caret`
@(private = "file")
words_of :: proc(b: ^buffer.Buffer, caret: int) -> ^Index {
	s := buffer.snapshot(b)
	defer buffer.snapshot_release(&s)
	return collect(&s, caret, buffer.offset_to_line(b, caret))
}


@(private = "file")
expect_words :: proc(t: ^testing.T, index: ^Index, expected: []string, loc := #caller_location) {
	testing.expect_value(t, len(index.words), len(expected), loc)
	for word, i in expected {
		if i >= len(index.words) do break
		testing.expect_value(t, index.words[i], word, loc)
	}
}


// Identifier-like runs, each once and sorted; numbers, single characters and
// runs over MAX_LEN are left out, words with digits or non-ASCII letters kept
@(test)
test_collect_words :: proc(t: ^testing.T) {
	long := strings.repeat("x", MAX_LEN + 1, context.temp_allocator)
	text := fmt.tprintf(
		"main :: proc() {{\n\tcount := 42 + 0x1F\n\tcount += utf8_len(café) // a b\n\t%s\n}}\n",
		long,
	)
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)

	index := words_of(&b, len(text))
	defer index_release(index)
	expect_words(t, index, {"café", "count", "main", "proc", "utf8_len"})
	testing.expect_value(t, index.version, b.version)
	testing.expect_value(t, index.lo, 0)
	testing.expect_value(t, index.hi, len(text))
}


// The word the caret is in or ends is left out, unless it is elsewhere too
@(test)
test_collect_leaves_out_caret_word :: proc(t: ^testing.T) {
	b := make_buffer("alpha beta\ngamma alp")
	defer buffer.buffer_destroy(&b)

	end := buffer.length(&b)
	at_end := words_of(&b, end)
	defer index_release(at_end)
	expect_words(t, at_end, {"alpha", "beta", "gamma"})

	inside := words_of(&b, 2)
	defer index_release(inside)
	expect_words(t, inside, {"alp", "beta", "gamma"})

	// "beta" is also on the second line
	buffer.replace_untracked(&b, end, 0, " beta")
	twice := words_of(&b, 8)
	defer index_release(twice)
	expect_words(t, twice, {"alp", "alpha", "beta", "gamma"})
}


// A word split across pieces (an edit inside it) reads as one; edits show in
// the next collection
@(test)
test_collect_after_edits :: proc(t: ^testing.T) {
	b := make_buffer("first second\n")
	defer buffer.buffer_destroy(&b)

	before := words_of(&b, 0)
	defer index_release(before)

	sels := []buffer.Selection{{0, 0, -1}}
	buffer.begin(&b, .Other, 0, sels)
	buffer.replace(&b, 9, 0, "XY")  // "secXYond"
	buffer.replace(&b, 14, 0, " third_word")
	buffer.end(&b, sels)

	after := words_of(&b, 0)
	defer index_release(after)

	expect_words(t, before, {"second"})
	expect_words(t, after, {"secXYond", "third_word"})
	testing.expect(t, after.version != before.version)
}


// Only the lines within WINDOW_LINES of the caret's line are read (less the
// word at the caret, "word_10000")
@(test)
test_collect_window :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3 * WINDOW_LINES {
		fmt.sbprintf(&sb, "word_%d\n", i)
	}
	b := make_buffer(strings.to_string(sb))
	defer buffer.buffer_destroy(&b)

	caret := buffer.line_start(&b, 2 * WINDOW_LINES)
	index := words_of(&b, caret)
	defer index_release(index)

	testing.expect_value(t, index.lo, buffer.line_start(&b, WINDOW_LINES))
	testing.expect_value(t, index.hi, buffer.length(&b))
	testing.expect_value(t, len(index.words), 2 * WINDOW_LINES - 1)
	testing.expect_value(t, index.words[0], "word_10001")
}


// A long line is read WINDOW_BYTES either side of the caret; the words the
// window's edges cut into are left out
@(test)
test_collect_long_line :: proc(t: ^testing.T) {
	// "waaaaaa waaaaab ..." on one line, each word 8 bytes with its space
	sb := strings.builder_make(context.temp_allocator)
	count := 4 * WINDOW_BYTES / 8
	for i in 0 ..< count {
		letters: [6]u8
		n := i
		for k in 0 ..< 6 {
			letters[5 - k] = 'a' + u8(n % 26)
			n /= 26
		}
		fmt.sbprintf(&sb, "w%s ", string(letters[:]))
	}
	text := strings.to_string(sb)
	b := make_buffer(text)
	defer buffer.buffer_destroy(&b)

	// The caret inside a word; the window's edges inside words too
	caret := len(text) / 2 + 3
	index := words_of(&b, caret)
	defer index_release(index)

	testing.expect_value(t, index.lo, caret - WINDOW_BYTES)
	testing.expect_value(t, index.hi, caret + WINDOW_BYTES)
	for word in index.words {
		testing.expect_value(t, len(word), 7)
	}

	// The words wholly inside, less the caret's
	testing.expect_value(t, len(index.words), 2 * WINDOW_BYTES / 8 - 2)
}


@(private = "file")
Wake :: struct {
	count: int, // atomic
}


@(private = "file")
count_wake :: proc "contextless" (data: rawptr) {
	w := (^Wake)(data)
	sync.atomic_add(&w.count, 1)
}


// The thread collects posted snapshots and hands the indexes back
@(test)
test_indexer :: proc(t: ^testing.T) {
	b := make_buffer("one two three\n")

	wake: Wake
	ix: Indexer
	indexer_start(&ix, count_wake, &wake)
	defer indexer_stop(&ix)

	indexer_post(&ix, Job{id = 7, text = buffer.snapshot(&b), caret = 0, caret_line = 0})
	buffer.buffer_destroy(&b)

	// Taken once it is ready
	results: []Result
	deadline := time.tick_now()
	for len(results) == 0 && time.tick_since(deadline) < 5 * time.Second {
		time.sleep(time.Millisecond)
		results = indexer_take(&ix)
	}

	testing.expect_value(t, len(results), 1)
	if len(results) == 1 {
		testing.expect_value(t, results[0].id, 7)
		expect_words(t, results[0].index, {"three", "two"})
		index_release(results[0].index)
	}
	testing.expect(t, sync.atomic_load(&wake.count) >= 1)
}
