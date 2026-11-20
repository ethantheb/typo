package diff

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"


// Diffs old and new, checks the hunks rebuild new and are sorted and apart, and
// returns them in the temp allocator
@(private = "file")
check_diff :: proc(t: ^testing.T, old, new: string, loc := #caller_location) -> []Hunk {
	a, b := transmute([]u8)old, transmute([]u8)new
	hunks := lines(a, b, context.temp_allocator)

	rebuilt := apply(a, b, hunks, context.temp_allocator)
	testing.expectf(t, string(rebuilt) == new, "%q -> %q gave %q", old, new, rebuilt, loc = loc)

	for h, i in hunks {
		testing.expect(t, h.old_lo <= h.old_hi && h.new_lo <= h.new_hi, loc = loc)
		if i > 0 {
			testing.expect(t, hunks[i - 1].old_hi < h.old_lo, "hunks touch", loc = loc)
		}
	}
	return hunks
}


@(test)
test_equal_texts_have_no_hunks :: proc(t: ^testing.T) {
	testing.expect_value(t, len(check_diff(t, "", "")), 0)
	testing.expect_value(t, len(check_diff(t, "a\nb\n", "a\nb\n")), 0)
	testing.expect_value(t, len(check_diff(t, "no newline", "no newline")), 0)
}


@(test)
test_one_changed_line :: proc(t: ^testing.T) {
	old := "one\ntwo\nthree\nfour\n"
	new := "one\nTWO\nthree\nfour\n"
	hunks := check_diff(t, old, new)

	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0], Hunk{4, 8, 4, 8})
}


@(test)
test_changes_far_apart_stay_apart :: proc(t: ^testing.T) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for i in 0 ..< 100 do fmt.sbprintf(&sb, "line %d\n", i)
	old := strings.clone(strings.to_string(sb), context.temp_allocator)

	new, _ := strings.replace(old, "line 3\n", "line three\n", 1, context.temp_allocator)
	new, _ = strings.replace(new, "line 90\n", "", 1, context.temp_allocator)
	new = strings.concatenate({new, "added\n"}, context.temp_allocator)

	hunks := check_diff(t, old, new)
	testing.expect_value(t, len(hunks), 3)
}


@(test)
test_inserts_and_deletes_at_the_edges :: proc(t: ^testing.T) {
	check_diff(t, "", "a\nb\n")
	check_diff(t, "a\nb\n", "")
	check_diff(t, "b\n", "a\nb\n")
	check_diff(t, "a\n", "a\nb\n")
	check_diff(t, "a\nb", "a\nb\n")
	check_diff(t, "a\r\nb\r\n", "a\nb\n")

	// Only the inserted line is a hunk
	hunks := check_diff(t, "a\nc\n", "a\nb\nc\n")
	testing.expect_value(t, len(hunks), 1)
	testing.expect_value(t, hunks[0], Hunk{2, 2, 2, 4})
}


@(test)
test_reordered_lines :: proc(t: ^testing.T) {
	check_diff(t, "a\nb\nc\nd\n", "d\nc\nb\na\n")
	check_diff(t, "x\na\nx\nb\nx\n", "a\nx\nb\nx\nx\n")
}


@(test)
test_random_edits_rebuild :: proc(t: ^testing.T) {
	rand.reset(11)
	words := []string{"alpha\n", "beta\n", "gamma\n", "\n", "delta", "x\n"}

	for _ in 0 ..< 300 {
		old_parts := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< rand.int_max(30) {
			append(&old_parts, rand.choice(words))
		}

		// Remove, insert and replace a few lines
		new_parts := make([dynamic]string, context.temp_allocator)
		append(&new_parts, ..old_parts[:])
		for _ in 0 ..< rand.int_max(6) {
			i := rand.int_max(len(new_parts) + 1)
			switch rand.int_max(3) {
			case 0:
				if i < len(new_parts) do ordered_remove(&new_parts, i)
			case 1:
				inject_at(&new_parts, i, rand.choice(words))
			case 2:
				if i < len(new_parts) do new_parts[i] = rand.choice(words)
			}
		}

		old := strings.concatenate(old_parts[:], context.temp_allocator)
		new := strings.concatenate(new_parts[:], context.temp_allocator)
		check_diff(t, old, new)
	}
}


@(test)
test_too_many_changes_give_one_hunk :: proc(t: ^testing.T) {
	old_sb, new_sb: strings.Builder
	strings.builder_init(&old_sb, context.temp_allocator)
	strings.builder_init(&new_sb, context.temp_allocator)
	fmt.sbprint(&old_sb, "same first\n")
	fmt.sbprint(&new_sb, "same first\n")
	for i in 0 ..< MAX_EDITS {
		fmt.sbprintf(&old_sb, "old %d\n", i)
		fmt.sbprintf(&new_sb, "new %d\n", i)
	}
	fmt.sbprint(&old_sb, "same last\n")
	fmt.sbprint(&new_sb, "same last\n")

	old, new := strings.to_string(old_sb), strings.to_string(new_sb)
	hunks := check_diff(t, old, new)

	// The middle, between the common first and last lines
	testing.expect_value(t, len(hunks), 1)
	first := len("same first\n")
	last := len("same last\n")
	testing.expect_value(t, hunks[0], Hunk{first, len(old) - last, first, len(new) - last})
}
