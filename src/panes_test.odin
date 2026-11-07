package editor

import "core:fmt"
import "core:testing"

import "gfx"

// The tree as text: a pane's id, "(a|b)" side by side, "(a/b)" stacked.
@(private = "file")
shape :: proc(t: ^Tile) -> string {
	if t == nil do return ""
	if t.pane != nil do return fmt.tprintf("%d", t.pane.id)
	return fmt.tprintf("(%s%s%s)", shape(t.children[0]), t.axis == .Row ? "|" : "/", shape(t.children[1]))
}

// Whether every child points back at its parent.
@(private = "file")
linked :: proc(t: ^Tile) -> bool {
	if t == nil || t.pane != nil do return true
	return t.children[0].parent == t && t.children[1].parent == t && linked(t.children[0]) && linked(t.children[1])
}

@(private = "file")
free_tree :: proc(t: ^Tile) {
	if t == nil do return
	if t.pane == nil {
		free_tree(t.children[0])
		free_tree(t.children[1])
	}
	free(t)
}

@(test)
test_pane_drops :: proc(t: ^testing.T) {
	a, b, c := Pane{id = 1}, Pane{id = 2}, Pane{id = 3}
	root: ^Tile
	defer free_tree(root)
	expect :: proc(t: ^testing.T, root: ^Tile, want: string, loc := #caller_location) {
		testing.expect_value(t, shape(root), want, loc = loc)
		testing.expect(t, root == nil || root.parent == nil && linked(root), "parent links", loc = loc)
	}

	drop_apply(&root, &a, {kind = .Fill})
	expect(t, root, "1")
	drop_apply(&root, &b, {kind = .Split, target = &a, side = .Right})
	expect(t, root, "(1|2)")
	drop_apply(&root, &c, {kind = .Edge, side = .Bottom})
	expect(t, root, "((1|2)/3)")
	// Moving a shown pane takes it out first; its sibling takes its split's place.
	drop_apply(&root, &c, {kind = .Split, target = &a, side = .Top})
	expect(t, root, "((3/1)|2)")
	drop_apply(&root, &a, {kind = .Swap, target = &b})
	expect(t, root, "((3/2)|1)")
	drop_apply(&root, &b, {kind = .Shelf})
	expect(t, root, "(3|1)")
	// A pane from the shelf takes the target's place; the target goes to the shelf.
	drop_apply(&root, &b, {kind = .Swap, target = &a})
	expect(t, root, "(3|2)")
	// A split beside itself, or beside a pane that isn't shown, changes nothing.
	drop_apply(&root, &c, {kind = .Split, target = &c, side = .Left})
	expect(t, root, "(3|2)")
	drop_apply(&root, &c, {kind = .Split, target = &a, side = .Left})
	expect(t, root, "(3|2)")
	drop_apply(&root, &b, {kind = .Shelf})
	drop_apply(&root, &c, {kind = .Shelf})
	expect(t, root, "")
}

// Splits share the space left after the gap; an edge drop takes its share.
@(test)
test_pane_rects :: proc(t: ^testing.T) {
	a, b, c := Pane{id = 1}, Pane{id = 2}, Pane{id = 3}
	root: ^Tile
	defer free_tree(root)
	drop_apply(&root, &a, {kind = .Fill})
	drop_apply(&root, &b, {kind = .Edge, side = .Right})
	drop_apply(&root, &c, {kind = .Edge, side = .Bottom, share = 0.25})
	layout_tile(root, {0, 0, 206, 106})
	testing.expect_value(t, tile_find(root, &a).rect, gfx.Rect{0, 0, 100, 75})
	testing.expect_value(t, tile_find(root, &b).rect, gfx.Rect{106, 0, 100, 75})
	testing.expect_value(t, tile_find(root, &c).rect, gfx.Rect{0, 81, 206, 25})
}
