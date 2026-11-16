package fuzzy

import "core:strings"
import "core:testing"


@(test)
test_fuzzy :: proc(t: ^testing.T) {
	defer destroy()

	_, ok := score("edv", "src/editor_view.odin")
	testing.expect(t, ok)
	_, ok = score("xyz", "src/editor_view.odin")
	testing.expect(t, !ok)

	// Consecutive matches at a boundary beat scattered ones
	a, _ := score("term", "src/terminal.odin")
	b, _ := score("term", "src/theme_error_map.odin")
	testing.expect(t, a > b)

	// The matched characters
	path := "src/terminal_edit.odin"
	picked := strings.builder_make(context.temp_allocator)
	for m, i in positions("ted", path) {
		if m do strings.write_byte(&picked, path[i])
	}
	testing.expect_value(t, strings.to_string(picked), "ted")
}
