# typo

A code editor in Odin: SDL3 + SDL_ttf (window, text), Clay (layout), tree-sitter plus a
fallback lexer (highlighting), libghostty-vt (integrated terminal). Developed on Windows.

## Build and test

```
python build.py            debug build -> build/typo.exe
python build.py --run      build and launch
python build.py --release  optimized build
python build.py --test     unit tests for every package (TEST_PACKAGES), then the perf suite
python build.py --perf     perf suite only
odin check src -vet-unused -vet-unused-imports    quick type check (after one build.py run)
```

- `build.py` builds the dependencies as static libraries (tree-sitter with clang,
  libghostty-vt with a pinned Zig, SDL3/SDL3_ttf with CMake) and fetches the ConPTY
  files `src/term/pty_windows.odin` embeds. Fonts and the icon (`assets/`, exe icon via
  `assets/icon/typo.rc`) are embedded: the executable is the only runtime file.
- Patched dependencies (patches made with `git diff` in `build/deps/<name>`; `build.py`
  rebuilds the library when its patch changes):
  - `patches/sdl_ttf.patch`: glyphs at quarter-pixel positions, with text measured
    the way it is drawn (`Glyph_Pixel_X`); `TTF_SetFontHinting` actually enabling
    subpixel rendering (upstream never stored it); `TTF_SetFontCoverageTable`, which
    `gfx/text.odin` uses for per-font gamma and contrast.
  - `patches/ghostty.patch`: when scrollback isn't pulled on resize (set on Windows),
    reflow also trims trailing spaces, as ConPTY does (see Terminal below).
- Markdown spec suite (`src/markdown/spec_test.odin`): CommonMark and GFM examples
  rendered to HTML. `testdata/spec_failures.txt` lists known failures with reasons; any
  other failure, or a listed example passing, fails the test. `-define:SPEC_WRITE=true`
  rewrites the list, `-define:SPEC_DETAILS=n` prints n failures.
- Perf suite (`src/perf.odin`, run as `typo-perf --perf`): an optimized build that opens
  a real window, runs scripted phases (startup, parsing, typing, scrolling, resizing,
  rendered Markdown, huge files, finder, settings window, context menu and dialogs,
  terminal, panes, idle CPU/GPU) and exits non-zero if a check fails or a result
  exceeds its limit. Phases drive the UI by setting `g.mouse_pos`, `g.mouse_pressed`,
  `g.right_pressed` and sending keys through `handle_key_event`. Figures are affected
  by other load; rerun once before investigating a result just over. A feature with a
  per-frame or per-keystroke cost gets a phase or result; a UI behavior gets a check.
- `TYPO_SETTINGS` points typo at another settings.toml (the perf suite uses a temp one);
  session.json is written beside it.

## Architecture

Packages import downward only: `editor` (src/) -> `mdview` -> `textedit` -> `gfx`, with
`markdown`, `buffer` and `syntax` below them (gfx uses syntax for theme colors).

- **Views and kinds.** The editor shows its document through a `textedit.View`
  (buffer, selections, scroll, bounds). The view's `kind` (`textedit.Kind`, a table of
  procs) decides drawing, hit testing, scrolling, caret movement, editing keys, typing,
  clipboard and mouse behavior: `TEXT_KIND` (text_view.odin) or `mdview.KIND`. App code
  calls the kind and never branches on which view it is. A new view (e.g. CSV) is a new
  `Kind` with its state in `View.kind_data`. What is the same in every view (`move`,
  `key`, undo, multi-cursor, `copy_text`/`paste`) is in textedit.
- **Markdown files** also have `Editor.md` (`markdown.Doc`) and `Editor.md_view`
  (`mdview.View`: points at the editor's textedit.View and the doc, holds the rendered
  state). `mdview.attach` connects them; `mdview.set_mode` switches the view's kind.
  mdview reaches app state (settings, pointer, frame, workspace files, opening a file)
  only through `mdview.env`, set in `md_env.odin`.
- **Edits** go through `textedit.apply` (every selection, one undo step). Consumers take
  them once per frame with `textedit.take_changes`, which runs `View.on_edit`
  (highlighter, Markdown parse, rendered caches). `buffer.version` counts changes.
- **Panes** (panes.odin): each open file (`^Editor`) or terminal (`^Terminal`) is a
  `Pane` in `g.panes.open`. Shown panes are the leaves of a split tree (`Tile`) filling
  `work_rect()`; terminals not shown wait on the shelf, listed under the file tree.
  Files come from the tree (click, or drag into place); a file that loses its place to
  another closes unless it has unsaved changes (the tree marks those with a dot).
  Every pane, wherever it is in the tree, is a floating child of "Main" at its leaf's
  rect, so changes to the tree
  only move and resize panes and their transitions animate them (never reparented).
  Every change of place is a `Drop` applied by `drop_apply` (also run on a temp copy
  of the tree for the drag preview); a pane leaving the layout fades out as an empty
  frame (`Leaving`). Keys go to `g.panes.focused`, which is always a pane in view:
  focusing a pane (`pane_focus`) restores a maximized pane that would cover it. Files
  open in place of the editor in use (`place_for`). Element ids carry `Pane.id`
  ("Pane", "PaneBody", "PaneTitle"); tree rows are keyed by path (`tree_row_id`), so
  a press matched against last frame's layout finds the same file after the tree
  re-sorts. Whatever holds a `^Pane` (menu, rename, drag, pending `Pane_Op`) is
  cleared in `pane_close`.
- **Carets** and the terminal cursor don't blink. A press shows the caret at once; it
  hides only while a selection drag has moved (`Editor.drag_moved`).
- **Terminal** (terminal*.odin, term/): on Windows the shell runs in ConPTY, which keeps
  its own copy of the screen, and the two must stay row for row the same or the shell
  draws on the wrong row. So on resize ghostty doesn't pull scrollback down (growing
  adds blank rows at the bottom) and its reflow trims trailing spaces
  (`term.session_init`, patches/ghostty.patch). The grid is resized only once panes
  stop animating.

### A frame (`app_iterate`, main.odin)

1. Apply the pending `Action`, update focus, run `finder_frame` and `panes_frame`
   (divider and pane drags, then each pane's `editor_frame`/`terminal_frame`), which
   read last frame's layout (`element_rect`, `pointer_in`) and handle the mouse.
2. `build_ui` (layout.odin) declares the Clay tree; editors and terminals are custom
   elements drawn by `draw_editor`/`draw_terminal`.
3. `render_clay_commands`, present, `free_all(context.temp_allocator)`.

- Nothing shows half ready: a new file isn't drawn (`Editor.shown`) until it has real
  bounds and no image in view is loading (or `EDITOR_SHOW_WAIT` passed); the window
  starts hidden until the first ready frame.
- The loop sleeps when idle: `needs_continuous_frames` lists what keeps it awake,
  other threads call `wake_main_loop`.
- Strings used by a frame's render commands must outlive the frame's drawing: per-frame
  strings use the temp allocator, and opening files/folders, closing panes and UI
  buttons that change the panes are deferred via `g.pending` (`defer_action`).

## Layout

```
src/                 package editor: the app
  main.odin          App state (global `g`), SDL callbacks, frame loop, idle, deferred actions
  keymap.odin        Command enum, default bindings, chords, run_command
  settings.odin      Settings model: SETTINGS table, TOML load/save, file watcher
  settings_ui.odin   Settings window from SETTINGS; theme/font picker docked at the side
  render.odin        Clay render commands -> gfx calls; Clay text measurement
  ui.odin            Widgets (label, button, icon, input_box, list_row, tooltip, modal),
                     hit tests (clicked, pointer_in), transition, element_at
  scrollbar.odin     Scroll bar parts, list_scrollbar, wheel routing
  layout.odin        Window layout: sidebar (file tree, shelf), status bar, mouse cursor
  panes.odin         Panes: shelf, split tree, drops, divider and pane dragging,
                     pane UI, focus, pane commands
  editor.odin        Editor: open/save, Markdown attachment, keys, commands, clipboard
  editor_view.odin   Editor per-frame update, mouse selection, scrolling, scroll bar,
                     drawing, all through the view's kind
  text_view.odin     TEXT_KIND: line grid, gutter, highlighting, line/column movement
  md_env.odin        mdview.env: the app state mdview may see
  terminal*.odin     Terminal: session, row cache, drawing, input
  dialog.odin        In-app dialogs (dialog_show; a choice applies next frame), the
                     unsaved-changes flow (resolve_unsaved), the delete prompt
  context_menu.odin  Right-click menu on tree rows, pane titles and shelf terminals
  rename.odin        Renaming in place (tree row, shelf row or pane title; F2), and
                     naming a new file or folder in a new tree row
  line_edit.odin     One-line text editing: caret, selection, words, clipboard
  fs_ops*.odin       Create, rename and delete, keeping open files (path, highlighting,
                     Markdown mode), the tree and the finder in step. On Windows,
                     delete goes to the Recycle Bin through IFileOperation; an item
                     that can't go there is not deleted, and the user is asked to
                     delete it permanently. Names Windows can't use are refused.
  finder.odin        Ctrl+E file finder (background indexer, incremental search)
  fuzzy.odin         fzy-style scorer
  workspace.odin     Lazy file tree, folder dialog
  session.odin       The session (folder, window, panes and layout) saved on exit to
                     session.json and reopened when started with no arguments
  fs_walk*.odin      Recursive file listing
  perf*.odin         Perf suite and CPU/GPU counters
  *_test.odin        App tests (editor_test, md_view_test: a Markdown file in the editor,
                     panes_test: the split tree)
src/gfx/             Drawing: draw.odin (primitives on gfx.renderer, clips, overlays),
                     text.odin (gfx.text_system, font ids, measurement, contrast),
                     fonts.odin (bundled IBM Plex, Instrument Sans, installed-font scan), theme.odin
                     (THEMES, gfx.theme), geometry.odin (Rect), icon.odin
src/textedit/        Editing core: view.odin (View), kind.odin (Kind, move, key, undo,
                     multi-cursor, clipboard), edit.odin (selections, normalize, apply,
                     line/column/word helpers, visible_runs)
src/mdview/          Rendered Markdown view
  kind.odin          KIND
  env.odin           Env: what the view needs from the app (settings, input, files)
  view.odin          Mode, caches, syntax reveal, estimated heights, movement by visual
                     row, hit tests
  layout.odin        A line's items wrapped into rows of runs; caret geometry; cache keys
  table.odin         Tables: column fitting, cell layout, in-place editing
  code.odin          Code blocks: extents, widths, sideways scrolling and scroll bar
  draw.odin          Drawing; code colored by language
  edit.odin          Editing keys (lists, quotes, indentation, renumbering, table cells,
                     <br> line breaks, fence closing), copy ranges
  media.odin         Links (Ctrl+click), wikilinks, images (thread-pool decoding)
  height_map.odin    Per-line heights in chunks with running sums
  *_test.odin        view_test (layout, geometry); edit_test (keys replayed through
                     textedit.key at every caret position of sample documents, checking
                     incremental parse = full parse, caret never in hidden text, typed
                     text drawn)
src/markdown/        Parser: doc.odin (incremental), block.odin (line classifier),
                     inline.odin, query.odin, refs.odin, html.odin, highlight.odin (text
                     view colors); spec suite
src/buffer/          Piece table (treap), newline index, undo, change log
src/syntax/          Highlighter: tree-sitter (Odin, TOML), line lexer (others)
src/term/            libghostty-vt bindings, Session (vt + pty + reader thread)
src/toml/            Minimal TOML reader
vendor/              clay-odin, tree-sitter* (do not edit); sdl3: Odin's SDL3 bindings with
                     foreign imports pointed at the static libraries
ref/clay_docs.md     Clay API reference
```

## Clay

Use Clay before writing UI machinery; read `ref/clay_docs.md` and
`vendor/clay-odin/clay.odin`.

- **Animation**: `transition()` (ui.odin). Elements ease to new layout and colors;
  `Enter` fades or slides in. Needs a fixed id. Sets `g.animating` to keep frames coming.
- **No exit transitions**: an exiting subtree would be drawn from freed temp memory. To
  animate closing, keep declaring the element at its closed size until `element_at`
  reports it there, then drop it.
- **Fades**: `overlayColor`, applied by the renderer to everything inside, editor and
  terminal included.
- **Scrolling**: use `update_scroll_containers`, not `clay.UpdateScrollContainers`. The
  wheel goes to the topmost list registered with `wheel_scroll_list` (`list_scrollbar`
  does that), not to any clipping element.
- **Stacking** (floating zIndex): panes 2-3, popups (`modal`, finder, settings) 100,
  scroll bar thumbs 110, context menu 120, dialog 150, tooltips 300.

## Markdown

Parser (`markdown.Doc`):
- Per-line block info, reparsed incrementally (`doc_edit`, `doc_update`). A line depends
  only on the previous line's end state; setext headings and table headers look one
  line ahead. `Line_Info.first`/`block_first` give a leaf block's start without
  scanning up. Inlines are parsed per block on demand (table rows cell by cell,
  paragraphs over `MAX_BLOCK_LINES` in pieces).
- CommonMark + GFM + extras, with two live-editing deviations: a lone marker plus space
  ("- ", "1. ") starts an item, and a single "-" is not a heading underline.
- Front matter is the only forward dependency: "---" on line 1 opens it only if a
  closing "---"/"..." follows (`doc_update` reparses from the top when that changes).
  Footnote references need a definition (`doc_labels`).

Rendered view (`mdview`):
- Syntax is hidden except where a selection touches it (a line's block markers, a
  span's inline markers, a whole fence), and the caret line's whitespace is shown, so
  the caret is never in hidden text and typed text is always drawn. Exception:
  indentation Markdown treats as syntax; the caret is drawn where the text starts.
- Tables stay rendered. `textedit.normalize` runs the kind's `snap`
  (`mdview.snap_carets`), keeping carets in cells. Tables fill the column and wrap, or widen via their header button
  (`State.wide_tables`). Dragging across cells selects a rectangle, one selection per
  row (`cell_drag`); typing, deleting, cutting or pasting over cells empties them and
  keeps the pipes (`replace_cells`). `<br>` breaks a cell's line; arrows, Backspace and
  Delete treat it as one character. Cells are byte ranges of a row (`Table_Cell`).
- While the mouse is down, reveal state is frozen (`hold_reveal`) so text doesn't move
  under a drag; on release the selection grows to what copying takes (`snap_selection`).
- Caches (`begin_caches`): per document (inlines, tables, code blocks, code highlights)
  and per document + selections + column width (line layouts). A new pane width only
  refits tables. Lines have their own heights in a `Height_Map` (top margin: `pad`).

## Conventions

- Comments: short, literal, about the current code only (no history, benchmarks,
  rejected options, conversations). Skip them when the code says it.
- Reuse helpers: `clicked`, `pointer_in`, `element_rect`, `gfx.rect_contains`,
  `gfx.draw_text`, `gfx.fill_rect`, `gfx.push_clip_box`, `input_box` +
  `text_field_event`, `modal` + `clicked_outside`, `dialog_show` (never a blocking
  native box), `resolve_unsaved` before closing files, `textedit.line_span`,
  `textedit.next_col`, `set_string`, `list_scrollbar` (with `SCROLLBAR_GUTTER` right
  padding), `list_row` (sidebar rows), `gfx.draw_caret`.
- New setting: a `Setting` value, a `Settings` field, a `SETTINGS` entry, a
  `setting_value` case. Long-list string settings set `picker = true` and fill
  `picker_options`; related number settings go in `picker_extras`.
- New command: a `Command` value, a `COMMANDS` entry, a case in `run_command` or
  `editor_run_command`.
- Pointer input goes through `ui_interactive` (via `clicked`, pane frame procs,
  tooltips); a new popup that blocks all or part of the window belongs there. While
  the dialog or context menu is open only their own UI (built with `g.in_popup`) reacts;
  showing a dialog closes the menu, and a rename field stays open under a dialog.
- A file or folder name typed by the user goes through `rename_path`/`create_path`,
  which refuse names the OS can't use; deleting goes through `ask_delete_file`.
- Fonts: UI uses bundled Instrument Sans (`gfx.Font_Id.Body`, Medium; bundled faces are
  picked by weight in `gfx/text.odin`); editor and terminal use
  `.Editor`/`.Editor_Bold` (set by `apply_editor_font`). Column width:
  `editor_char_width` (includes letter spacing); row height: `editor_line_height`.
- Temp allocator for per-frame data; free owned data (tests use the tracking allocator).
- `@(private = "file")` for single-file helpers, `@(private)` for package internals.

## Planned directions

The architecture should allow these without rewrites:

- **Theming**: user themes from TOML would add `gfx.Theme_Spec` entries to `gfx.THEMES`
  and `gfx.THEME_NAMES`. UI colors come only from `gfx.theme`.
- **LSP**: each edit's byte offsets and row/column points (`buffer.Change`) reach
  `editor_on_edit` (`View.on_edit`, via `textedit.take_changes`); send them to the
  server there, with `buffer.version` as the document version. Don't call
  `buffer.take_changes` elsewhere: it drains the changes. `syntax.Highlight` is per
  byte, so semantic tokens can overlay it.
- **One file in several panes**: `textedit.View` still holds the document (buf, path)
  with the view state, and `Editor` holds the rest of the document (hl, Markdown doc)
  plus per-view state (char_w, gutter_w, drag). TEXT_KIND finds its Editor with
  `container_of`, and `md_view` points into the Editor, so an Editor must not move
  (editors are behind pointers). Next: separate the document from its views so one
  document has several, each with its own kind state (TEXT_KIND's in `kind_data` too),
  `mdview.View` and pane.
- **CSV view**: a new `textedit.Kind`, shown in an editor pane (`pane_icon` gives it an
  icon). The table cell code (`Table_Cell`, cell lookup, rectangle drag,
  `replace_cells`) is private to mdview and reads the Markdown doc; move it to a shared
  place, over a source of rows, before reusing it.
