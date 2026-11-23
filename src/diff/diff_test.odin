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


// --- Side by side ------------------------------------------------------------------

// The lines of a text as an editor counts them, without their endings
@(private = "file")
editor_lines :: proc(text: string) -> []string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for &l, i in lines {
		if i < len(lines) - 1 do l = strings.trim_suffix(l, "\r")
	}
	return lines
}


// Diffs old and new side by side and checks the rows: every line of each text
// shows exactly once, in order; Same rows hold equal lines; filler only in
// hunks; row_of_line finds each line's row
@(private = "file")
check_rows :: proc(t: ^testing.T, old, new: string, loc := #caller_location) -> Rows {
	a, b := transmute([]u8)old, transmute([]u8)new
	hunks, old_n, new_n := line_hunks(a, b, context.temp_allocator)
	r := rows_make(hunks, old_n, new_n, context.temp_allocator)

	old_lines, new_lines := editor_lines(old), editor_lines(new)
	testing.expect_value(t, old_n, len(old_lines), loc = loc)
	testing.expect_value(t, new_n, len(new_lines), loc = loc)

	next_old, next_new := 0, 0
	for row in 0 ..< r.count {
		x := row_at(&r, row)
		if x.old >= 0 {
			testing.expectf(t, x.old == next_old, "row %d: old line %d", row, x.old, loc = loc)
			testing.expect_value(t, row_of_line(&r, x.old, false), row, loc = loc)
			next_old += 1
		}
		if x.new >= 0 {
			testing.expectf(t, x.new == next_new, "row %d: new line %d", row, x.new, loc = loc)
			testing.expect_value(t, row_of_line(&r, x.new, true), row, loc = loc)
			next_new += 1
		}

		switch x.kind {
		case .Same:
			testing.expect(t, x.hunk == -1, loc = loc)
			testing.expect_value(t, old_lines[x.old], new_lines[x.new], loc = loc)
		case .Changed:
			testing.expect(t, x.old >= 0 && x.new >= 0 && x.hunk >= 0, loc = loc)
		case .Removed:
			testing.expect(t, x.old >= 0 && x.new == -1, loc = loc)
		case .Added:
			testing.expect(t, x.old == -1 && x.new >= 0, loc = loc)
		}
	}
	testing.expect_value(t, next_old, old_n, loc = loc)
	testing.expect_value(t, next_new, new_n, loc = loc)
	return r
}


@(test)
test_rows_line_up :: proc(t: ^testing.T) {
	check_rows(t, "", "")
	check_rows(t, "a\nb\n", "a\nb\n")
	check_rows(t, "", "a\nb\n")
	check_rows(t, "a\nb\n", "")
	check_rows(t, "a", "a\n")

	// Line endings don't count
	r_eol := check_rows(t, "a\r\nb\r\n", "a\nb\n")
	testing.expect_value(t, len(r_eol.hunks), 0)
	r_eol = check_rows(t, "a\r\nb\r\nc\r\n", "a\nB\nc\n")
	testing.expect_value(t, len(r_eol.hunks), 1)

	// A changed line, then an added one: filler on the old side
	r := check_rows(t, "one\ntwo\nthree\n", "one\nTWO\nnew\nthree\n")
	testing.expect_value(t, r.count, 5)
	testing.expect_value(t, row_at(&r, 1), Row{.Changed, 1, 1, 0})
	testing.expect_value(t, row_at(&r, 2), Row{.Added, -1, 2, 0})
	testing.expect_value(t, row_at(&r, 3), Row{.Same, 2, 3, -1})

	// Removed lines: filler on the new side
	r = check_rows(t, "a\nb\nc\nd\n", "a\nd\n")
	testing.expect_value(t, row_at(&r, 1), Row{.Removed, 1, -1, 0})
	testing.expect_value(t, row_at(&r, 2), Row{.Removed, 2, -1, 0})
	testing.expect_value(t, row_at(&r, 3), Row{.Same, 3, 1, -1})
}


@(test)
test_random_rows_line_up :: proc(t: ^testing.T) {
	rand.reset(23)
	words := []string{"alpha\n", "beta\n", "gamma\n", "\n", "delta", "x\r\n"}

	for _ in 0 ..< 300 {
		old_parts := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< rand.int_max(40) {
			append(&old_parts, rand.choice(words))
		}

		new_parts := make([dynamic]string, context.temp_allocator)
		append(&new_parts, ..old_parts[:])
		for _ in 0 ..< rand.int_max(8) {
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
		check_rows(t, old, new)
	}
}


@(test)
test_changed_words :: proc(t: ^testing.T) {
	// One word replaced: just it, on each side
	removed, added, ok := words("x := old_name + 1", "x := new_name + 1", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(removed), 1)
	testing.expect_value(t, len(added), 1)
	testing.expect_value(t, removed[0], [2]int{5, 13})
	testing.expect_value(t, added[0], [2]int{5, 13})

	// Something inserted: nothing removed
	removed, added, ok = words("f(a)", "f(a, b)", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(removed), 0)
	testing.expect_value(t, len(added), 1)
	testing.expect_value(t, added[0], [2]int{3, 6})

	// Nothing in common says nothing
	_, _, ok = words("alpha", "beta", context.temp_allocator)
	testing.expect(t, !ok)

	// The same line: no changes
	removed, added, ok = words("same", "same", context.temp_allocator)
	testing.expect(t, ok && len(removed) == 0 && len(added) == 0)
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
