package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "buffer"
import "diff"
import "textedit"

// Tests of watching for changes on disk: gathering events into bursts, the tree
// following listings, and reloading an open file as line edits


when ODIN_OS == .Windows {
	@(private = "file")
	ROOT :: `C:\work`
	@(private = "file")
	SEP :: `\`
} else {
	@(private = "file")
	ROOT :: "/work"
	@(private = "file")
	SEP :: "/"
}


@(private = "file")
at_ms :: proc(ms: i64) -> time.Tick {
	return time.Tick{ms * 1_000_000}
}


@(private = "file")
in_root :: proc(rel: string) -> string {
	return strings.concatenate({ROOT, SEP, rel}, context.temp_allocator)
}


@(test)
test_events_gather_by_folder :: proc(t: ^testing.T) {
	p: Watch_Pending
	defer pending_reset(&p)

	// A write changes no folder's entries; adding, removing and renaming do
	pending_add(&p, ROOT, {in_root("src" + SEP + "a.odin"), .Modified}, at_ms(0))
	testing.expect(t, !p.structure)
	testing.expect_value(t, len(p.dirs), 0)

	pending_add(&p, ROOT, {in_root("src" + SEP + "b.odin"), .Added}, at_ms(10))
	pending_add(&p, ROOT, {in_root("src" + SEP + "b.odin"), .Modified}, at_ms(20))
	pending_add(&p, ROOT, {in_root("old.txt"), .Renamed_From}, at_ms(30))
	pending_add(&p, ROOT, {in_root("new.txt"), .Renamed_To}, at_ms(30))
	testing.expect(t, p.structure)
	testing.expect_value(t, len(p.dirs), 2) // src and the root
	testing.expect_value(t, len(p.paths), 4)
	testing.expect_value(t, p.count, 5)

	// Inside an ignored folder: dropped. The folder itself counts
	pending_add(&p, ROOT, {in_root(".git" + SEP + "index"), .Modified}, at_ms(40))
	pending_add(&p, ROOT, {in_root("node_modules" + SEP + "x" + SEP + "y.js"), .Added}, at_ms(40))
	testing.expect_value(t, p.count, 5)
	pending_add(&p, ROOT, {in_root("node_modules"), .Added}, at_ms(40))
	testing.expect_value(t, p.count, 6)

	// A file, or a folder it is in
	key := path_key(in_root("src" + SEP + "a.odin"), context.temp_allocator)
	testing.expect(t, pending_touches(&p, key))
	inside := path_key(in_root("node_modules" + SEP + "z.js"), context.temp_allocator)
	testing.expect(t, pending_touches(&p, inside))
	other := path_key(in_root("docs" + SEP + "a.md"), context.temp_allocator)
	testing.expect(t, !pending_touches(&p, other))
}


@(test)
test_bursts_wait_until_quiet :: proc(t: ^testing.T) {
	p: Watch_Pending
	defer pending_reset(&p)

	_, due := pending_due_at(&p)
	testing.expect(t, !due, "nothing gathered, nothing due")

	// Each event pushes the burst back, until it has gone on too long
	quiet := i64(time.duration_milliseconds(WATCH_QUIET))
	longest := i64(time.duration_milliseconds(WATCH_MAX_DELAY))

	pending_add(&p, ROOT, {in_root("a"), .Added}, at_ms(0))
	at, _ := pending_due_at(&p)
	testing.expect_value(t, at, at_ms(quiet))

	pending_add(&p, ROOT, {in_root("b"), .Added}, at_ms(50))
	at, _ = pending_due_at(&p)
	testing.expect_value(t, at, at_ms(50 + quiet))

	for ms := i64(100); ms < 2 * longest; ms += 50 {
		pending_add(&p, ROOT, {in_root("c"), .Modified}, at_ms(ms))
	}
	at, _ = pending_due_at(&p)
	testing.expect_value(t, at, at_ms(longest))
}


@(test)
test_parent_dir :: proc(t: ^testing.T) {
	testing.expect_value(t, parent_dir(`C:\a\b.txt`), `C:\a`)
	testing.expect_value(t, parent_dir(`C:\a`), `C:\`)
	testing.expect_value(t, parent_dir("/a/b"), "/a")
	testing.expect_value(t, parent_dir("/a"), "/")
	testing.expect_value(t, parent_dir("a"), "")
}


// Folders listed again update the tree in place: new entries get rows, gone
// ones lose theirs, expanded folders stay expanded
@(test)
test_tree_follows_listings :: proc(t: ^testing.T) {
	dir := os.temp_directory(context.temp_allocator) or_else "."
	root := fmt.tprintf("%s%ctypo-watch-tree-%d", dir, os.Path_Separator, os.get_pid())

	sub := file_in(root, "sub")
	_ = os.make_directory_all(sub)
	_ = os.write_entire_file(file_in(root, "a.txt"), "")
	_ = os.write_entire_file(file_in(sub, "x.txt"), "")
	defer os.remove_all(root)

	ws: Workspace
	workspace_open(&ws, root)
	defer workspace_destroy(&ws)
	workspace_expand(&ws, {sub})

	// Changes on disk, then the two folders listed again
	_ = os.write_entire_file(file_in(root, "b.txt"), "")
	_ = os.remove(file_in(root, "a.txt"))
	_ = os.write_entire_file(file_in(sub, "y.txt"), "")
	relist(&ws, {root, sub})

	expect_rows(t, &ws, {"sub", "x.txt", "y.txt", "b.txt"})
	testing.expect(t, ws.nodes[ws.visible[0]].expanded, "the folder stays expanded")

	// A folder removed takes its rows along, and its nodes are freed
	version := ws.loaded_version
	_ = os.remove_all(sub)
	relist(&ws, {root})

	expect_rows(t, &ws, {"b.txt"})
	testing.expect_value(t, len(ws.nodes), 2)
	testing.expect(t, ws.loaded_version != version, "the loaded folders changed")
}


@(private = "file")
file_in :: proc(dir, name: string) -> string {
	return fmt.tprintf("%s%c%s", dir, os.Path_Separator, name)
}


@(private = "file")
relist :: proc(ws: ^Workspace, dirs: []string) {
	listings := make([dynamic]Folder_Listing, context.temp_allocator)
	for dir in dirs {
		if l, ok := folder_listing_read(dir); ok {
			append(&listings, l)
		}
	}
	workspace_apply_listings(ws, listings[:])
	for l in listings do folder_listing_destroy(l)
}


@(private = "file")
expect_rows :: proc(t: ^testing.T, ws: ^Workspace, names: []string, loc := #caller_location) {
	got := make([dynamic]string, context.temp_allocator)
	for i in ws.visible do append(&got, ws.nodes[i].name)

	same := len(got) == len(names)
	for name, i in names {
		if !same do break
		same = got[i] == name
	}
	testing.expectf(t, same, "rows %v, expected %v", got[:], names, loc = loc)
}


// A file reloaded under the editor changes only the lines that changed: carets
// elsewhere stay on their text, it is one undo step, and the text is saved
@(test)
test_reload_keeps_carets :: proc(t: ^testing.T) {
	old := "first\nsecond\nthird\nfourth\nfifth\n"
	new := "zeroth\nfirst\nsecond\nTHIRD\nfourth\nfifth\n"

	e: Editor
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone(old))
	defer buffer.buffer_destroy(&e.buf)
	e.status = .Text
	e.kind = &TEXT_KIND
	defer delete(e.sels)

	// Carets in "second" and in "fifth"
	second := strings.index(old, "second") + 3
	fifth := strings.index(old, "fifth") + 2
	append(&e.sels, Selection{second, second, -1}, Selection{fifth, fifth, -1})

	hunks := diff.lines(transmute([]u8)old, transmute([]u8)new, context.temp_allocator)
	reload_apply(&e, hunks, transmute([]u8)new)

	text := string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf), context.temp_allocator))
	testing.expect_value(t, text, new)
	testing.expect_value(t, e.sels[0].head, strings.index(new, "second") + 3)
	testing.expect_value(t, e.sels[1].head, strings.index(new, "fifth") + 2)
	testing.expect(t, !buffer.is_modified(&e.buf), "the text is the file's")

	// One undo step back to the text before
	textedit.undo(&e)
	text = string(buffer.read_alloc(&e.buf, 0, buffer.length(&e.buf), context.temp_allocator))
	testing.expect_value(t, text, old)
	testing.expect(t, buffer.is_modified(&e.buf), "the text before isn't the file's")
}


// What a save records is the hash a read of the file gives, so the watcher
// knows typo's own write
@(test)
test_save_records_what_it_wrote :: proc(t: ^testing.T) {
	sync.guard(&app_state_lock)

	dir := os.temp_directory(context.temp_allocator) or_else "."
	path := fmt.aprintf("%s%ctypo-watch-save-%d.txt", dir, os.Path_Separator, os.get_pid())
	defer os.remove(path)

	e: Editor
	buffer.buffer_init(&e.buf, transmute([]u8)strings.clone("hello\n"))
	defer buffer.buffer_destroy(&e.buf)
	e.status = .Text
	e.kind = &TEXT_KIND
	e.path = path
	defer delete(e.path)
	append(&e.sels, Selection{6, 6, -1})
	defer delete(e.sels)

	// Several pieces, so the hash is taken over several chunks
	textedit.insert(&e, "world\n")
	textedit.set_single_selection(&e, {0, 0, -1})
	textedit.insert(&e, "> ")

	testing.expect(t, editor_save(&e))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "> hello\nworld\n")
	testing.expect_value(t, e.disk.hash, file_hash(data))

	stamp, exists := file_stamp(path)
	testing.expect(t, exists)
	testing.expect_value(t, e.disk.stamp, stamp)

	// An empty file too
	textedit.select_all(&e)
	textedit.delete_text(&e, -1, word = false)
	testing.expect(t, editor_save(&e))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, len(data), 0)
	testing.expect_value(t, e.disk.hash, file_hash(data))
}
