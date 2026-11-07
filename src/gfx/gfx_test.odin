package gfx

import "core:testing"

// Every built-in theme has a unique key and all of its syntax colors set.
@(test)
test_themes :: proc(t: ^testing.T) {
	for spec, i in THEMES {
		for other in THEMES[i + 1:] do testing.expectf(t, spec.key != other.key, "duplicate theme %s", spec.key)
		for c, h in spec.syntax do testing.expectf(t, c != spec.bg, "%s: %v is the background color", spec.key, h)
		testing.expect_value(t, theme_by_name(spec.key).bg, rgb(spec.bg))
	}
	testing.expect_value(t, theme_by_name("no-such-theme").bg, rgb(THEMES[0].bg))
	// Each family has a dark and a light theme, for the theme list's dark/light switch.
	for spec in THEMES {
		other := false
		for o in THEMES do if o.family == spec.family && o.dark != spec.dark do other = true
		testing.expectf(t, other, "%s has no %s counterpart", spec.key, spec.dark ? "light" : "dark")
	}
}

@(test)
test_font_weights :: proc(t: ^testing.T) {
	sf: System_Fonts
	regular, bold, italic, found := font_family_sources(&sf, BUNDLED_FAMILY, 500)
	testing.expect(t, found)
	testing.expect(t, raw_data(regular.data) == raw_data(BUNDLED_FACES[3].data))
	testing.expect(t, raw_data(bold.data) == raw_data(BUNDLED_FACES[5].data))
	testing.expect(t, raw_data(italic.data) == raw_data(BUNDLED_FACES[7].data) && !italic.synthetic_italic)
	regular, bold, _, _ = font_family_sources(&sf, BUNDLED_FAMILY, 100)
	testing.expect(t, raw_data(regular.data) == raw_data(BUNDLED_FACES[0].data))
	// Nothing heavier than Bold: bold text uses it too.
	regular, bold, _, _ = font_family_sources(&sf, BUNDLED_FAMILY, 900)
	testing.expect(t, raw_data(bold.data) == raw_data(BUNDLED_FACES[5].data))
	_, _, _, found = font_family_sources(&sf, "Not A Font", 400)
	testing.expect(t, !found)

	md, md_found := markdown_family_sources(&sf, BUNDLED_MD_FAMILY)
	testing.expect(t, md_found)
	testing.expect(t, raw_data(md[.Bold_Italic].data) == raw_data(BUNDLED_MD_FACES[4].data))
	testing.expect(t, raw_data(md[.SemiBold].data) == raw_data(BUNDLED_MD_FACES[1].data))
	// A family without italics slants its upright faces.
	md, _ = markdown_family_sources(&sf, BUNDLED_FAMILY)
	testing.expect(t, raw_data(md[.Italic].data) == raw_data(BUNDLED_FACES[6].data) && !md[.Italic].synthetic_italic)
	sf.families = make([dynamic]Font_Family)
	defer delete(sf.families)
	append(&sf.families, Font_Family{name = "Upright", faces = make([dynamic]Font_Face)})
	defer delete(sf.families[0].faces)
	append(&sf.families[0].faces, Font_Face{weight = 400})
	md, _ = markdown_family_sources(&sf, "Upright")
	testing.expect(t, md[.Italic].synthetic_italic && !md[.Regular].synthetic_italic)
}
