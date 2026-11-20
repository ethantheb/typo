package gfx

import "core:testing"

import clay "../../vendor/clay-odin"

// Every built-in theme has a unique key and all of its syntax colors set
@(test)
test_themes :: proc(t: ^testing.T) {
	for spec, i in THEMES {
		for other in THEMES[i + 1:] {
			testing.expectf(t, spec.key != other.key, "duplicate theme %s", spec.key)
		}
		for c, h in spec.syntax {
			testing.expectf(t, c != spec.bg, "%s: %v is the background color", spec.key, h)
		}
		testing.expect_value(t, theme_by_name(spec.key).bg, rgb(spec.bg))
	}
	testing.expect_value(t, theme_by_name("no-such-theme").bg, rgb(THEMES[0].bg))

	// Each family has a dark and a light theme, for the theme list's dark/light switch
	for spec in THEMES {
		other := false
		for o in THEMES {
			if o.family == spec.family && o.dark != spec.dark {
				other = true
			}
		}
		missing := spec.dark ? "light" : "dark"
		testing.expectf(t, other, "%s has no %s counterpart", spec.key, missing)
	}
}


// A selection's rows as one shape: corners rounded only where a row reaches
// past the one it joins, inside corners curved, rows that don't touch or
// overlap shapes of their own
@(test)
test_selection_shape :: proc(t: ^testing.T) {
	rows := []Rect {
		{100, 0, 100, 20}, // reaches past the next row on the right
		{0, 20, 150, 20},  // past the one above on the left, the next on the right
		{0, 40, 50, 20},   // the same left edge as the one above
		{300, 60, 20, 20}, // no overlap with the one above: on its own
		{300, 90, 20, 20}, // a gap above: on its own
	}
	R :: 4

	p := selection_piece(rows, 0, 0, R)
	testing.expect_value(t, p.corners, clay.CornerRadius{R, R, 0, R})
	testing.expect_value(t, p.n_fillets, 0)

	p = selection_piece(rows, 1, 0, R)
	testing.expect_value(t, p.corners, clay.CornerRadius{R, 0, 0, R})
	testing.expect_value(t, p.n_fillets, 2)
	testing.expect_value(t, p.fillets[0], Fillet{{100, 20}, {-1, -1}, R}) // in the row above
	testing.expect_value(t, p.fillets[1], Fillet{{150, 20}, {1, 1}, R})   // in this row

	p = selection_piece(rows, 2, 0, R)
	testing.expect_value(t, p.corners, clay.CornerRadius{0, 0, R, R})
	testing.expect_value(t, p.n_fillets, 1)
	testing.expect_value(t, p.fillets[0], Fillet{{50, 40}, {1, 1}, R})

	for i in 3 ..< 5 {
		p = selection_piece(rows, i, 0, R)
		testing.expect_value(t, p.corners, clay.CornerRadius{R, R, R, R})
		testing.expect_value(t, p.n_fillets, 0)
	}

	// Padding widens every row; a step narrower than two radii gets smaller curves
	p = selection_piece(rows, 0, 3, R)
	testing.expect_value(t, p.box, Rect{97, 0, 106, 20})
	steps := []Rect{{0, 0, 103, 20}, {0, 20, 100, 20}}
	p = selection_piece(steps, 0, 0, R)
	testing.expect_value(t, p.corners.bottomRight, 1.5)
	p = selection_piece(steps, 1, 0, R)
	testing.expect_value(t, p.fillets[0].radius, 1.5)
}


@(test)
test_font_weights :: proc(t: ^testing.T) {
	sf: System_Fonts

	// The editor's faces
	regular, bold, italic, found := font_family_sources(&sf, BUNDLED_FAMILY, 500)
	testing.expect(t, found)
	testing.expect(t, raw_data(regular.data) == raw_data(BUNDLED_FACES[3].data))
	testing.expect(t, raw_data(bold.data) == raw_data(BUNDLED_FACES[5].data))
	italic_face := raw_data(italic.data) == raw_data(BUNDLED_FACES[7].data)
	testing.expect(t, italic_face && !italic.synthetic_italic)

	regular, bold, _, _ = font_family_sources(&sf, BUNDLED_FAMILY, 100)
	testing.expect(t, raw_data(regular.data) == raw_data(BUNDLED_FACES[0].data))

	// Nothing heavier than Bold: bold text uses it too
	regular, bold, _, _ = font_family_sources(&sf, BUNDLED_FAMILY, 900)
	testing.expect(t, raw_data(bold.data) == raw_data(BUNDLED_FACES[5].data))

	_, _, _, found = font_family_sources(&sf, "Not A Font", 400)
	testing.expect(t, !found)

	// Rendered Markdown's faces
	md, md_found := markdown_family_sources(&sf, BUNDLED_MD_FAMILY)
	testing.expect(t, md_found)
	testing.expect(t, raw_data(md[.Bold_Italic].data) == raw_data(BUNDLED_MD_FACES[4].data))
	testing.expect(t, raw_data(md[.SemiBold].data) == raw_data(BUNDLED_MD_FACES[1].data))

	// A family without italics slants its upright faces
	md, _ = markdown_family_sources(&sf, BUNDLED_FAMILY)
	md_italic_face := raw_data(md[.Italic].data) == raw_data(BUNDLED_FACES[6].data)
	testing.expect(t, md_italic_face && !md[.Italic].synthetic_italic)

	sf.families = make([dynamic]Font_Family)
	defer delete(sf.families)
	append(&sf.families, Font_Family{name = "Upright", faces = make([dynamic]Font_Face)})
	defer delete(sf.families[0].faces)
	append(&sf.families[0].faces, Font_Face{weight = 400})

	md, _ = markdown_family_sources(&sf, "Upright")
	testing.expect(t, md[.Italic].synthetic_italic && !md[.Regular].synthetic_italic)
}
