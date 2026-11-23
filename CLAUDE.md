# typo

A code editor in Odin: SDL3 + SDL_ttf (window, text), Clay (layout), tree-sitter plus a
fallback lexer (highlighting), libghostty-vt (integrated terminal), a Language Server
Protocol client (src/lsp), and Git through libgit2 and the git command line (src/git).
Developed on Windows.

## How to work

- **The UI thread does only UI.** Anything that waits, parses, spawns, searches, walks
  files, writes logs or does file IO runs on another thread and hands over finished
  results, even if each is "only a few ms". Give such features a perf limit on their
  UI-thread share per frame (a thread-local `uitime.Share` its procs start with
  `uitime.timed`, read by perf.odin like `langs.ui_share` and `lsp_limit`), not just
  frame time.
- **Edit source with the Edit/Write tools**, not shell or Python scripts, so the style
  hook runs. If it doesn't report back, run `python .claude/hooks/check_style.py <files>`
  after a batch of edits.
- **Ask before reinventing.** Before writing something general (parsers, lexers,
  grammars, format handling), look for an established option (what Zed, Helix, Neovim
  use) and present options with a recommendation.
- **Test editing through keys.** Replay real keystrokes through the key handlers, cover
  the basics (letters, spaces, tabs, Enter, Backspace on every kind of line), keep
  invariants strict, and confirm a new test fails with the fix switched off.
  Width-dependent behavior also needs a real-font check (perf suite).
- **Don't commit unless asked.** If a file changes unexpectedly, ask rather than revert.
- **Perf noise:** the user runs heavy apps in the background. A result just over its
  limit in unchanged code: rerun once before investigating.
- **Sources:** `E:\Projects\sprawl` (Clay bindings, IBM Plex Mono) is read-only; copy
  from it, never modify it. The project was once called `odin_editor`.

### Testing the running app

- The user usually has their own typo open. Launch test instances with
  `Start-Process -PassThru` and target only that PID (screenshots, Stop-Process).
- Synthetic keys (SendKeys) and posted mouse messages don't reach SDL. Show states
  through launch arguments (`typo -t <folder>`, `typo <file>`) or perf phases. From a
  shell inside typo (`TYPO_IPC` set), `typo <file>` opens in that window: add `--new`.
- Screenshots: user32 `PrintWindow(hwnd, dc, 2)` on the test window's handle, bitmap
  sized from `GetWindowRect`. Not `CopyFromScreen` (it grabs whatever window is on top).
  Check new UI with a copy of the user's settings.toml too.
- Never modify the user's real settings.toml (%APPDATA%\typo\settings.toml); point
  `TYPO_SETTINGS` at a scratch file (with `[lsp.<name>] path = ...` entries for servers).
- Real language servers on the dev machine: clangd and gopls on PATH; ols, rust-analyzer,
  ty, ruff, pyright, basedpyright in Zed's folders (%LOCALAPPDATA%\Zed\languages\<name>\...,
  ols in Zed\extensions\work\odin\ols-dev-*\). On another machine, check what's
  installed. ols takes about 4 s to initialize on typo's source.
- herdr-core (`hc`, %LOCALAPPDATA%\Programs\herdr-core) runs the user's own agents:
  never stop, restart or update their core, or touch terminals you didn't start.
  Experiments and tests use a private session (`herdr.sandbox_begin`: `HC_SESSION`
  and scratch `XDG_STATE_HOME`/`XDG_CONFIG_HOME`), stopped at the end.

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
  libghostty-vt with a pinned Zig, SDL3/SDL3_ttf and libgit2 with CMake) and fetches the
  ConPTY files `src/term/pty_windows.odin` embeds. libgit2 (`LIBGIT2_VERSION`, bindings
  in vendor/libgit2 for what typo uses, license in vendor/libgit2/COPYING) is built with
  nothing that reaches the network (no HTTPS or SSH: the git command line pushes, pulls
  and fetches), with its bundled zlib, regex and http parser, as a build type of its own
  (`Optimized`): its Release flags on MSVC include /GL, which makes every link redo
  link-time code generation. Fonts and the icon (`assets/`, exe icon via
  `assets/icon/typo.rc`) are embedded: the executable is the only runtime file.
- `--test` and `--perf` first build `build/fake_lsp` (src/lsp/fake_server): a language
  server that keeps the documents it is sent ("fake/text" returns its copy), answers
  hover, reports "FIXME" as a diagnostic, lists lines "name :: ..." (with indented
  "name := ..." inside) as symbols and a word's places in its documents as
  references, completes every word of its documents (plus "fake_snippet", a snippet,
  and "fake_import", with an edit at the top; with `--incomplete`, only the first few
  words starting with the typed one, as an incomplete list), resolves items with
  documentation,
  gives "name(a, b, c)" as signature help in "name(", renames a word in its documents
  and in the small files of its root folder with the same extension that aren't open,
  sends workspace/applyEdit (each "FIXME" to "FIXED") on "fake/apply", takes `--utf16`
  (and `--incomplete`, `--complete-empty`, `--complete-error`, `--complete-delay <ms>`
  for completion), and exits on "fake/crash";
  `--copy-to <path>` copies the program there (the perf suite's install command).
  The lsp tests, the app's lsp_test and the perf suite's language server phase use it.
- Patched dependencies (patches made with `git diff` in `build/deps/<name>`; `build.py`
  rebuilds the library when its patch changes):
  - `patches/sdl_ttf.patch`: glyphs at quarter-pixel positions, with text measured
    the way it is drawn (`Glyph_Pixel_X`); `TTF_SetFontHinting` actually enabling
    subpixel rendering (upstream never stored it), and `TTF_SetFontSubpixelPositioning`
    turning quarter-pixel positions on whatever the hinting (`gfx.glyph_fit`: the
    editor font's faces are light-hinted, other fonts unhinted, since FreeType's
    hinter can close a bold i's dot onto its stem); `TTF_SetFontCoverageTable`, which
    `gfx/text.odin` uses for per-font gamma and contrast; glyph images exactly the
    size of the box the engine stretches them over (the glyph's box, padded for the
    LCD filter and the italic slant, `Glyph_Padding`); `TTF_SetFontCellAdvance`
    (advances in whole cells: the editor font's faces); `TTF_SetFontLCD` (FreeType's
    LCD rendering in the text engine, `TTF_IMAGE_LCD`, drawn in two passes with custom
    blend modes: `target * (1 - coverage) + color * coverage` per channel), queued and
    drawn together by `TTF_FlushRendererText`, which `gfx.flush_text` calls before
    anything else is drawn, a clip changes or the frame is presented. Overlapping
    glyphs in the queue go in separate layers (`LCDLayerFor`, a tile grid), each drawn
    in both passes before the next. Renderers without the blend modes (software) get
    grayscale text (`renderer_has_lcd_blend`).
  - `patches/ghostty.patch`: when scrollback isn't pulled on resize (set on Windows),
    reflow also trims trailing spaces, as ConPTY does (see Terminal below). Applied
    while `GHOSTTY_PATCH` is on.
- libghostty-vt is a pinned release (`GHOSTTY_VERSION`, Zig `ZIG_VERSION`), built from
  source with the patch. `GHOSTTY_PATCH = False` uses the release as it is: on Windows
  x64 its prebuilt static library, downloaded (linked with `-linker:lld`, as MSVC's
  link.exe rejects its MinGW objects), elsewhere built from source. `build.py` passes
  `-define:GHOSTTY_PATCHED` so tests that need the patch skip without it.
  `test_abi_matches_manifest` checks the bindings' struct sizes and every bound enum
  against the library's manifest: run it after changing the version.
- Markdown spec suite (`src/markdown/spec_test.odin`): CommonMark and GFM examples
  rendered to HTML. `testdata/spec_failures.txt` lists known failures with reasons; any
  other failure, or a listed example passing, fails the test. `-define:SPEC_WRITE=true`
  rewrites the list, `-define:SPEC_DETAILS=n` prints n failures.
- Perf suite (`src/perf.odin`, run as `typo-perf --perf`): an optimized build that opens
  a real window (shown unfocused behind the other windows; events other than quit,
  wake-ups and display scale changes are ignored), runs scripted phases (startup,
  text in cells and subpixels, read back from the window, selection shapes,
  parsing, typing, scrolling, resizing, the sideways scroll bar, rendered Markdown,
  huge files opened, saved and restored while frames go on (perf_files.odin), the
  large-file question, finder (open and recent files first), find in files and the
  terminal, moving lines, settings window (several bindings for a command), context
  menu and dialogs, the sidebar behind the panes (what shows between them read
  back from a real frame) and its search popup, RECENT and pinned files and the
  project's settings (the scope switch read back in a dark and a light theme),
  files changed on disk, the Git pane on a repository of its own (its status, keys
  and message box), a diff of a large file loaded, scrolled and its hunks reverted
  and staged by their buttons, both panes narrower than their content (cut off at
  their edge, read back) (perf_git.odin; `git_limit` limits Git's UI-thread
  share per frame), terminal, block
  elements and box drawing
  read back from the terminal and an editor, panes, zoom, `typo <file>` in the
  terminal, a persistent terminal shown again from a private herdr-core session
  (perf_persist.odin; skipped without hc), closing a terminal that runs a program
  (perf_terminal_close.odin), go to line, text fields, idle CPU/GPU) and
  exits
  non-zero if a check fails or a result exceeds its limit. Phases drive the UI by
  setting `g.mouse_pos`, `g.mouse_pressed`, `g.right_pressed`, sending other mouse
  buttons through `mouse_button_event` and keys through `handle_key_event`; chords
  match on the scancode, so a shortcut is run with `run_command`, or sent with its
  scancode (`press_chord`) when the key path is what is tested. A step reads back
  what a frame showed with `want_frame` (read once drawn, before it is presented,
  into `Perf.read_back` for the next step). Figures are affected
  by other load; rerun once before investigating a result just over. A feature with a
  per-frame or per-keystroke cost gets a phase or result; a UI behavior gets a check.
- `TYPO_SETTINGS` points typo at another settings.toml (the perf suite uses a temp one);
  state.json (the project to reopen) is kept beside it. A project's own data is in its
  `.typo/` folder; tests and perf phases use temp folders as projects.

## Architecture

Packages import downward only: `editor` (src/) -> `mdview` -> `textedit` -> `gfx`, with
`markdown`, `buffer` and `syntax` below them (gfx uses syntax for theme colors). For
language servers, `editor` -> `langs` -> `lsp`: `lsp` imports only core, `buffer`
(its copies of documents) and `process`; `langs` (the app's servers, documents,
problems and requests, no UI) imports `lsp`, `textedit`, `buffer` and `toml`, and
reaches the app only through `langs.env`, set in lsp.odin. `git` (a repository through
libgit2, the git command line, the worker thread) imports `process` and
vendor/libgit2 and `trash`; `herdr` (the herdr-core client) imports `process`;
`term` imports `herdr`. `process` (child processes without a console window, PATH
lookups), `fuzzy` (the fzy-style scorer), `ipc` (a typo's endpoint and its
clients), `diff` (line diffs, side-by-side rows, changed words), `trash` (the
system's trash, from any thread) and `uitime` (a feature's share of the UI thread)
stand alone; `words` (a document's words, for completion) imports `buffer` and
`textedit`; `langs` and `herdr` import `uitime`.

The UI thread does UI: input, editing buffers, layout, drawing. Work that waits on
something or can take long (language servers, file system searches, parsing what
other processes send) runs on other threads, which hand over finished results.

- **Views and kinds.** The editor shows its document through a `textedit.View`
  (buffer, selections, scroll, bounds). The view's `kind` (`textedit.Kind`, a table of
  procs) decides drawing, hit testing, scrolling, caret movement, editing keys, typing,
  clipboard and mouse behavior: `TEXT_KIND` (text_view.odin) or `mdview.KIND`. App code
  calls the kind and never branches on which view it is. A new view (e.g. CSV) is a new
  `Kind` with its state in `View.kind_data`. What is the same in every view (`move`,
  `key`, undo, multi-cursor, `copy_text`/`paste`) is in textedit.
- **Scrolling sideways.** A kind's `sideways` gives how far the view scrolls sideways
  and the part that does; the editor clamps to it and draws a bar along that part's
  bottom (editor_view.odin; bars on either axis share gfx/scrollbar.odin's geometry
  and dragging with list_scrollbar and code blocks' bars). TEXT_KIND scrolls as far as
  the widest line it has shown (`Widest_Line`: the lines in view and the caret's are
  measured; an edit to the widest forgets it until it is in view again), so a huge
  file costs no more than a small one. Rendered Markdown fits the pane; its code blocks scroll on their
  own (mdview/code.odin).
- **Selections** are drawn by `gfx.fill_selection` from a selection's rows: one shape,
  padded and rounded (`gfx.selection_look`), its inside corners curved. Both kinds draw
  what goes behind the text first, then the selections, then the text.
- **Markdown files** also have `Editor.md` (`markdown.Doc`) and `Editor.md_view`
  (`mdview.View`: points at the editor's textedit.View and the doc, holds the rendered
  state). `mdview.attach` connects them; `mdview.set_mode` switches the view's kind.
  mdview reaches app state (settings, pointer, frame, workspace files, opening a file,
  the text view's row height) only through `mdview.env`, set in `md_env.odin`.
- **Edits** go through `textedit.apply` (every selection, one undo step), or
  `textedit.apply_edits` (separate ranges with the selections they leave, or the
  selections moved through them; one undo step: completions, rename). Consumers take
  them once per frame with `textedit.take_changes`, which runs `View.on_edit`
  (highlighter, Markdown parse, rendered caches). `buffer.version` counts changes.
- **Snapshots** (buffer/snapshot.odin): a buffer's bytes never move. The original
  store is the file as loaded, and the add store fills blocks that double in size
  (`FIRST_BLOCK` first), with no piece spanning two. A store's blocks are a
  reference-counted `Store_Memory`. `buffer.snapshot` copies the piece list
  (O(pieces), never the text) and takes a reference, so any thread can read the text
  as it was (`snapshot_read`, `spans`, `snapshot_line_start`) while the UI thread goes
  on editing, and after the buffer is destroyed. Its holder releases it
  (`snapshot_release`, on any thread). Work on a document's text off the UI thread
  takes a snapshot: the language server's open, the reload diff, the word index, a
  save's write.
- **Opening and saving** (file_io.odin, file_load.odin): nothing waits on the disk on
  the UI thread. `editor_open` leaves the editor `.Loading` and queues a `Load_Job`
  for a pool of `LOAD_THREADS` loader threads (one queue; a huge file doesn't hold up
  small ones), which stat the file, read it (`read_file_shared`), check for binary,
  hash it, and build the buffer (newline index) and highlighter (tree-sitter's first
  parse; `syntax.highlighter_open` runs on any thread, queries load under a lock).
  `file_load_frame` takes the results (each tagged with the editor's `Load_State.id`;
  a result for a closed or reopened editor is dropped and freed, and a cancelled load
  stops at its next step) and `load_landed` only wires them up: Markdown, the
  watcher (`disk_opened`), language servers, then the editor's `When_Ready` (a jump's
  target, a Markdown heading, the session's caret and scroll), applied once. Anything
  that needs the text of a file it opens calls `editor_when_ready` (applied at once if
  it is there): `Open_File`, the jump list, session restore. A loading pane is drawn
  empty, then "Loading name… size" (`loading_message`) once `EDITOR_SHOW_WAIT` passed;
  keys and commands in it are ignored (`status != .Text`), Close works. A file over
  the `ask_above_mb` setting is only measured: a dialog (`Opening_Large`) asks once no
  other is open; Open reads it, Cancel closes its pane and puts back the file it took
  the place of (`Load_State.replaced`, kept open until the load lands). Files over
  `LARGE_FILE_BYTES` (`Editor.large`) aren't sent to language servers. `editor_save`
  takes a snapshot and `buffer.begin_save` and queues a `Write_Job` for one writer
  thread (writes land in order): temp file + rename, hashing what it writes, and
  telling the watcher (`watch_file_synced`) before handing the result over;
  `save_landed` then marks that text saved (`buffer.end_save`: edits made meanwhile
  keep the file modified; steps never merge into a state being written) or shows why
  it failed. The writer also patches a file no editor has open (`Patch_Job`, a diff
  view's revert), only if it still has the size and hash read, and deletes a tree item
  (`Delete_Job`: to the trash package's trash, or permanently once confirmed). A save
  asked for during a write follows it. The unsaved-changes flow
  waits for writes before each question and before closing or quitting
  (`unsaved_frame`); quitting with a write under way waits for it, and `io_destroy`
  finishes queued writes. Without the threads (unit tests that don't start them) a job
  runs at once on the calling thread.
- **Panes** (panes.odin): each open file (`^Editor`), terminal (`^Terminal`), the Git
  pane (`^Git_View`) or a diff (`^Diff_View`) is a `Pane` in `g.panes.open`. Shown panes are the leaves of a split tree (`Tile`) filling
  `work_rect()`; terminals not shown wait on the shelf, listed under the file tree.
  Files come from the tree (click, or drag into place); a file that loses its place to
  another closes unless it has unsaved changes (the tree marks those with a dot).
  Every pane, wherever it is in the tree, is a floating child of "Main" at its leaf's
  rect, so changes to the tree
  only move and resize panes and their transitions animate them (never reparented).
  A pane clips what it holds: its header and body are laid out at least their
  minimum width (`PANE_HEADER_MIN`, `pane_body_min`: 0 for editors and terminals,
  `GIT_MIN_WIDTH`, `DIFF_MIN_WIDTH`) and at most the pane's, so a narrower pane cuts
  them off at its edge; while they are built (`g.in_pane`) `ui_interactive` refuses
  the pointer outside the pane or under the maximized one.
  Every change of place is a `Drop` applied by `drop_apply` (also run on a temp copy
  of the tree for the drag preview); a pane leaving the layout fades out as an empty
  frame (`Leaving`). Keys go to `g.panes.focused`, which is always a pane in view:
  focusing a pane (`pane_focus`) restores a maximized pane that would cover it.
  `pane_fill` says how a pane takes the work area (beside others, maximized over
  them, or alone); the title's maximize button and the focus outline follow it, and
  the only pane shown is never maximized. Files from the tree or the finder open in
  place of the editor in use (`place_for`); files from the command line, from
  `typo <file>` in a terminal or a server's log open in a new pane, never in place
  of another (`panes_open_file_beside`: right of the editor in use, else above the
  rest; a file already shown is focused). Element ids carry `Pane.id`
  ("Pane", "PaneBody", "PaneTitle"); tree rows are keyed by path (`tree_row_id`), so
  a press matched against last frame's layout finds the same file after the tree
  re-sorts. Whatever holds a `^Pane` (menu, rename, drag, pending `Pane_Op`) is
  cleared in `pane_close`.
- **Sidebar** (sidebar.odin): the window's background at its left edge, flat on
  the window's color (no panel or border), always laid out (a flow child of "Main",
  its own width). The panes sit beside it on the window's color, the only raised
  elements. Toggle sidebar only moves `work_rect`'s left edge: the panes ease over
  the sidebar or away from it, and the sidebar fades into the window as they cover
  it and back as they leave (`sidebar_fade`: an overlay of the window's color,
  transitioned with the panes' duration and easing; its floating parts, the search
  field's clear button and key hint, take it too, as Clay's overlays don't reach
  floating children), so nothing of it shows between the panes while hidden. Hiding
  it drops a rename in the tree or shelf. "WorkArea" (`work_area` in panes.odin:
  floating at the work area under the panes, easing as they do, passthrough) marks
  what covers the sidebar: its
  own checks go through `pointer_on_sidebar` (shown, and left of "WorkArea" as last
  laid out, so rows the panes still cover while sliding back don't react, and not
  under the search's popup): `ui_interactive` refuses while building it
  (`g.in_sidebar`) elsewhere, as do tree and shelf hit tests, drops and the context
  menu. Top to bottom: the folder's name, the search field, the tree, RECENT and
  the shelf. RECENT (sidebar_recent.odin, `recent_rows`): the project's pinned files, each with
  a pin, then its recent files up to the `recent_files` setting, not repeating a
  pinned one; headed and spaced as the shelf, its rows the shelf's insets. A row
  acts as a tree row (a click opens it in place of the editor in use, a press can
  drag it, drag source `.Recent`; the focused file is selected); a right-click on it
  or on a file in the tree pins or unpins (`project_pin`). Not laid out while it
  would list nothing (0 and no pins). The tree
  marks open files with unsaved changes and every folder they are in, collapsed or
  not, with a dot (`unsaved_marks`: each modified file's ancestors below the root,
  by `path_key_ascii`, per frame from the open editors).
- **Sidebar search** (sidebar.odin, `g.sidebar_search`): a `Line_Edit` above the
  tree, showing Find file's key at its right while empty, that opens a popup as a
  browser's address bar does. Find file (Ctrl+E, `find_file`) opens it with the
  query selected while the sidebar shows, else opens the finder; so does a press
  on the field (`sidebar_search_open`). The popup (`sidebar_search_popup`, declared
  after the sidebar, floating on the field's place "SidebarSearchSlot" at the
  popups' layer) grows out of the field (its enter transition starts at the
  field's box) over the panes, with the field at its top exactly where it was in
  the sidebar (the slot is empty meanwhile) and the files under it: the finder's
  index and scoring (`Search`, finder.odin) with its own results, stepped in
  `sidebar_frame` within `SEARCH_BUDGET` (paused while the finder is open), open
  and recent files ranked when it opens: with no query only those and the
  shortest paths, as the finder lists them, marked "open" or "recent". It covers
  what is under it (`search_popup_covers_pointer` in `ui_interactive` and
  `pointer_on_sidebar`; built with `g.in_search_popup`). Up/Down and Page Up/Down
  select, Enter or a click on a row (opened next frame, `clicked`) opens through
  `Open_File` (as a tree click: in place of the editor in use, the tree revealing
  it). Opening a file or Escape empties the field and closes the popup
  (`sidebar_search_close`); a press outside it, hiding the sidebar, another
  shortcut (which then runs) or the finder opening closes it and keeps the query.
  With the sidebar hidden, Find file opens the finder popup, which has symbols and
  places as sources too.
- **Zoom** (zoom.odin): each pane's text has its own size, a step from 100% in
  `textedit.ZOOM_LEVELS` (50%..300%): `textedit.View.zoom` for an editor (both kinds),
  `Terminal.zoom`. The interface doesn't zoom. Zoom in/out/reset act on the focused
  pane, from keys or the status bar's zoom item and its popup; `pane_zoom`,
  `pane_set_zoom`. The metrics take the zoom factor: `editor_font_size(zoom)`,
  `editor_char_width(zoom)`, `editor_line_height(zoom)` (a text view's row:
  `text_line_height(v)`); mdview scales `mdview.Config`'s sizes (given at 100%) by
  `textedit.zoom`, so its caches, keyed by the font size, follow. `textedit.set_zoom`
  asks the kind for an anchor (`Kind.anchor`: the caret's line, else the top line)
  that the kind puts back in place on its next frame. A file opened in place of
  another takes its zoom; the session keeps each pane's (percent).
- **Find** (find.odin, find_term.odin): one bar (`g.find`), on one pane at a time, at
  its top right. In an editor the buffer is searched a slice per frame
  (`FIND_PLAIN_BYTES`, less with a regex), so huge files stay responsive; matches go
  to `View.marks`, which both kinds draw behind the text, and the current match is
  the selection. Case folding is ASCII only (offsets stay put). In a terminal,
  libghostty's search does the work (scrollback included, kept in step with output);
  it only ignores ASCII case, so the option buttons are off there, and "next" goes up
  toward older output. The field has the keys (`find_has_keys`) after Find or a
  press on it, until a press elsewhere in its pane or another pane is focused: then
  the bar stays on its pane without the keys, and Enter, Esc and typing go to the
  focused pane. While it has them it takes them first (`find_handle_event`), and
  `PANE_EDIT_COMMANDS` don't reach the pane behind it. Find, and Find next/previous
  (F3), act on the focused pane: from another pane they move the bar there. The bar
  covers what is under it (`find_bar_covers_pointer` in `ui_interactive`; it is
  built with `g.in_find_bar`), as it can reach past a narrow pane.
- **Go to line** (goto_line.odin, Ctrl+G): a bar (`g.goto_line`) centered at the top
  of the focused editor, over the find bar, with a `Line_Edit` whose placeholder is
  "Line 120 of 4,032". It takes "line" or "line:column" (`goto_parse`; columns count
  characters, out-of-range numbers clamp in `goto_offset`); typing moves the caret
  there with `View.center` + `reveal`, Enter puts the caret back and goes through
  `jump_to` (so Go back returns), Esc puts caret and scroll back, and a press outside
  it, another shortcut, another pane focused or a popup over the editors closes it,
  the caret put back. While open it takes the keys (`goto_line_handle_event`, before the find
  bar's); it covers what is under it (`goto_line_covers_pointer`, `g.in_goto_bar`).
  Lines are the document's, in rendered Markdown too.
- **Text fields** (line_edit.odin): every text input (find bar, finder, settings
  search, text settings and server fields, picker filter, renaming in place, the
  symbol rename field) is a `Line_Edit` drawn by `text_field`. Its owner decides
  focus (before calling, so the press that focuses it places the caret) and handles
  Enter, Esc, Tab and Up/Down; `line_edit_event` does the rest: editing keys, and
  `FIELD_COMMANDS` (select all, clipboard, undo) through the bindings, so they never
  reach a pane. `text_field` takes the mouse (press, Shift+press, double and triple
  press, drag, scrolling past either end) and scrolls the text to keep the caret in
  view. Its text is a custom element (`Field_Draw`, `draw_text_field`); positions
  come from `gfx.text_caret_x`/`text_caret_at`, the text engine's layout of the
  string it draws.
- **Moving lines** (`textedit.move_lines`): each block of lines the selections cover
  swaps with its neighbor line, keeping the line break between them, as one undo step.
- **Carets** and the terminal cursor don't blink. A press shows the caret at once; it
  hides only while a selection drag has moved (`Editor.drag_moved`).
- **Changes on disk** (fs_watch*.odin, file_sync.odin): a watcher thread, started at
  launch, waits on the workspace folder (ReadDirectoryChangesW, recursive, overlapped,
  woken by an event for stop, a new root or a job; elsewhere a 2 s walk, fs_watch_other)
  and polls open files outside it. Events inside `FINDER_IGNORED_DIRS` are dropped; the
  rest gather into a burst (`Watch_Pending`) handed over once quiet `WATCH_QUIET` or
  after `WATCH_MAX_DELAY`; an overflow looks at everything again. The thread lists the
  burst's folders among the tree's loaded ones (`watch_set_dirs`) and the tree takes
  them in place (`workspace_apply_listings`); added/removed/renamed entries mark the
  finder's index stale (rebuilt if it lists files, else dropped until needed). Open
  files are registered with the hash and size/write time of the text typo last read or
  wrote (`watch_file_open` once loaded, which has the thread look at it once in case
  it changed while it loaded; `watch_file_synced` after a reload or, from the writer
  thread, a save), so typo's own
  writes aren't changes; a changed one is read once it holds still (`WATCH_STABLE`),
  with full sharing (`read_file_shared`; retried while locked). Without unsaved edits
  it reloads: the thread diffs it against a snapshot of the text (`diff.lines`) and
  `reload_apply` makes the hunks one undo step, carets and scroll kept. With unsaved
  edits a dialog asks (Reload / Keep my version); saving over a version typo hasn't read
  asks first (`save_or_ask`). A deleted or moved-away file stays open, unsaved
  (`Disk_State.missing`). Results carry a generation (or a reload serial); older ones
  are dropped. Three things look at files on a timer, each where the watcher can't:
  this poll of open files outside the workspace, the config thread's poll of
  settings.toml and the project's .typo/settings.toml (`CONFIG_POLL_MS`; the stat
  outside its lock), and the Git worker's poll of the files that describe the
  repository (`git.POLL`). The watcher ignores typo's own saves of
  .typo/session.json (`watch_ignored`), so saving the session as it goes lists no
  folders and refreshes no Git status.
- **Terminal** (terminal*.odin, term/): a `term.Session` is libghostty-vt plus a
  `Backend`, where the program runs: `Local` (a pty and its reader thread) or
  `Remote` (a herdr-core terminal through a `herdr.Stream`). Only session.odin's
  backend procs (spawn/start/attach, write, resize, focus, kill/detach, the pump's
  source and state) differ; drawing, the row cache, find, selection and input
  encoding don't. `session_pump` returns a `Pump` (busy, a notice, ended). On Windows
  a local shell runs in ConPTY, which keeps its own copy of the screen, and the two
  must stay row for row the same or the shell draws on the wrong row. So on resize
  ghostty doesn't pull scrollback down (growing adds blank rows at the bottom) and its
  reflow trims trailing spaces (`pty_semantics`, patches/ghostty.patch). A herdr
  terminal resizes the same way: herdr-core passes on its ConPTY's live output, and
  the cursor positions in it are ConPTY's (test_remote_resize_keeps_rows). Only the
  repaint after an attach comes from herdr-core's own terminal, which reflows with
  Ghostty's defaults, so after resizes while typo wasn't attached that repaint can
  differ from ConPTY's screen until the shell redraws. The grid is resized only once
  panes stop animating.
- **Persistent terminals** (terminal_persist*.odin, herdr/, docs/terminal_persistence.md):
  the `terminal.backend` setting ("local", default, or "herdr") picks where new
  terminals run; a terminal keeps its backend (`Terminal.persistent`), Restart too.
  The UI calls persistent terminals pinned: their icon (title, shelf, drag chip) has
  an accent pin on its corner (`pane_badge`; `gfx.Icon_Badge`, the icon drawn
  through two clips that leave a notch around the badge, so it reads on any
  background) with a tooltip. A terminal's menu has Pin or Unpin, which restarts it
  in the other mode (`terminal_ask_repin`: the unsaved-changes flow's `Repinning`
  step, asking first if a program runs in it); right-click on the shelf's + or the
  status bar's terminal button picks what new terminals are ("New terminals: Local
  / Pinned", `persist_set_wanted`, changing the settings layer in effect), and that
  button shows the pin while new terminals are pinned.
  One `herdr.Client` per typo (`persist_init`): its reader thread finds hc (PATH, then
  its install folder), and once a stream or a command needs the core starts `hc
  connect` (herdr/hc.odin, through `process` with `discard_stderr` and `detached`:
  no window, outside typo's job objects, as a core it starts inherits its job; its
  stdin and stdout pipes are the line, with two locks so a write stuck on a core
  that stopped reading can't hold up the kill that ends it), says hello
  in framed mode, subscribes to events of terminals labeled `typo=1`, and reads
  frames (u32 channel, u8 kind, u32 length; JSON-RPC on channel 0), reconnecting with
  a backoff; its writer thread turns queued commands into frames. The UI thread only
  queues and takes (`herdr.ui_share`, limited per frame by the perf suite). Request
  frames carry the connection they were made for and are dropped after a reconnect. A terminal is
  started with `keep`, `outlive_parent`, labels `typo=1` and `typo.project=<root>`, the
  shell (split as Windows splits arguments), typo's shell identity
  (`term.shell_identity`: TERM_PROGRAM=typo, as herdr-core would claim Ghostty) and
  `TYPO_IPC` with the project's name, sized and colored like the pane. An attach is
  a full repaint with `herdr.DEFAULT_HISTORY` lines: the stream marks it, and the pump
  resets the terminal and parses it in one go. Streams attach again after a
  reconnect, a `restarted` event (a lost program replaced by a shell), and when
  typo gets the size back from another viewer (`size` events; herdr gives
  interactive viewers no repaint). Quitting and leaving the project detach
  (`panes_close_all` calls `terminal_detach`); closing a pane kills and removes
  its herdr terminal (`terminal_destroy`). The session keeps each
  persistent terminal's address and core (`Session_Pane.herdr`, `herdr_core`); a
  restored one attaches when first shown (`persist_restore`). One that ended while
  typo was closed shows its last screen and history as text with an "exited" line;
  Enter starts a new one. Without hc, new terminals start locally and say so.
- **Running programs** (terminal_programs.odin, term/processes_*.odin): closing a
  terminal whose shell is alive (either backend), quitting or opening another
  folder (local shells only: persistent ones go on) asks first if a program runs
  in it ("ping is still running in PowerShell"), as a step of the unsaved-changes
  flow after the files (`Unsaved_Flow.programs`). A terminal runs one when its
  shell has processes under it (`term.programs_under`: a Toolhelp snapshot, the
  shell's descendants level by level, console hosts left out, ids reused since
  the shell started skipped), from the shell's process id (`term.session_pid`; a
  herdr terminal's from its attach, as herdr's own foreground is always the shell
  on Windows). The snapshot runs on a thread per check (`Programs_Check`, freed by
  whichever side lets go last), so closing a terminal takes a frame or two. Not
  looked up on Unix yet: closing there doesn't ask.
- **Box drawing and blocks** (gfx/box_glyphs.odin): box drawing, block elements,
  Powerline separators and Symbols for Legacy Computing (`gfx.is_box_glyph`) aren't
  drawn from the font but as shapes filling the exact cell, so they join across cells
  and rows whatever the font's advance and the line height. The shapes and their
  snapping to pixels are Windows Terminal's built-in glyphs (MIT; the table in
  box_glyphs_table.odin), light lines as thick as the font's own `─`. Each glyph is
  rasterized once per cell size into an atlas; a `gfx.Box_Batch` draws a row's glyphs
  in one call. The terminal (runs of their own in `build_row`) and the text view
  (`editor_has_glyph`) both draw them this way; rendered Markdown doesn't.
- **Language servers** (lsp/, langs/, lsp*.odin): `lsp` knows servers, JSON-RPC and
  protocol types, not editors. Nothing about a server runs on the UI thread: each
  `lsp.Client` has its own thread (lsp/worker.odin) that starts the process, does the
  handshake, encodes and parses all JSON, writes the log, and keeps a copy of each
  open document's text (a `buffer.Buffer`, edited with `replace_untracked`) to convert
  between byte offsets and the server's lines and UTF-8/UTF-16 columns. The UI thread
  queues commands (`client_open` with a snapshot, `client_change` with byte-offset
  `lsp.Edit`s,
  `request` at an offset) and takes decoded events with `lsp.client_poll`
  (`Diagnostics` as sorted byte ranges, `Response` with `Hover` or `[]Place`), each
  tagged with the document version its offsets are in. The process has reader,
  writer and stderr threads (`lsp.Connection`). PATH searches and project roots are
  looked up on another thread (`lsp.Lookups`; `langs.server_path`, `langs.root` return
  "not known yet" and `langs.frame` attaches files when answers come). The servers are
  `lsp.SERVERS` merged with settings.toml's `[lsp.<name>]` tables (`langs.Server_Override`,
  langs/config.odin; `build_server_list`). A table's `path` points at the program (run
  with the command's arguments), else the command's first word is looked up on PATH.
  Defaults are the popular servers; alternatives (ty, basedpyright, taplo, marksman)
  are in the table, off. `langs` keeps the app's side in `langs.state`: a file's document
  (`Editor.lsp`, a `langs.Doc` whose `view` points at the editor's) attaches to every
  enabled, installed server of its language (one `langs.Client` per server and project
  root) and is opened on each at once (the client's thread holds it until the server
  is ready); requests go to the first that supports them. Edits go out from
  `editor_on_edit` (`langs.doc_changed`, `lsp.edits_for_changes`): in linear time when
  a frame's changes are in text order or in reverse, each against the text the edits
  before it left, else as the whole text. A crashed server restarts (up to 3 times in 3
  minutes). A stopped or replaced client "retires": its thread shuts the server down,
  reading nothing but shutdown's reply; a server that doesn't answer initialize within
  a minute is stopped. A settings change rebuilds the server list (it points into the
  settings) and, when the servers' settings changed, replaces only the clients whose
  server is now off, not found or set up differently (`Client.server_key`,
  `langs.reattach_all`); the others keep their documents. On Windows servers start
  without a console window, inherit only their pipes, and live in a job object that
  ends them with typo. `langs.ui_share` is the UI thread's share, which the perf suite
  limits per frame. The app answers `langs.env`: its open documents, a document
  closing (`doc_closing`), a client gone (`client_gone`: stopped, crashed, restarted or
  removed; whatever waits on it lets go) and responses (`lsp_response`).
- **Language servers in the settings** (settings_servers.odin): the "Language servers"
  section lists every server (`server_rows`, grouped by language) with its state,
  Install/Locate… when its program isn't found, and an Off/On switch; Enter opens its
  page, which edits its `[lsp.<name>]` table as text fields (`override_field_text`,
  `set_override_field_text`), plus Restart, Log, Reset or Remove; "Add a server" adds a
  table. Changes are queued (`Server_Op`) and applied next frame
  (`settings_servers_frame`), since this frame's render commands may use the strings
  they replace. Install (`lsp_install`) opens a terminal whose shell runs an install
  command and stays open (`panes_run_in_terminal`, `shell_running`); the program is
  looked for again as output comes (`watch_installs`), and once found the server
  starts. settings.toml is written on the config thread (`settings_save_later`).
- **Installing servers** (lsp/install.odin, `langs.server_installs`): a server has
  several install commands (`Server_Spec.install`; a table's `install`, one string or
  a list, replaces them). Each command's program (its first word) is looked up on PATH
  on the lookup thread, cached with the servers' programs (`state.programs`, looked up
  again when the settings window or the status popup opens), and only commands whose
  program is found are offered, ordered by `lsp.INSTALLERS` weights (uv/pipx, then
  pip as `pip`, `py -m pip`, `python -m pip`, and npm, then winget/scoop/choco/brew,
  rustup, go, unknown programs, cargo last; ties keep the server's order). Install
  (settings row, server page, status popup) runs the lightest, its tooltip the exact
  command; the server page lists every command found, each with its Install; go and
  cargo say "builds from source". With none found there is no Install, a "Needs uv,
  npm or pip" line instead, and Locate… stays.
- **Language features** (langs/requests.odin, langs/problems.odin, lsp.odin,
  lsp_hover.odin): a request goes to the first running client of the document that
  can do it (`langs.client_with`, `lsp.Feature`); `langs.Request` remembers the
  document (`request_editor` finds its editor), and a response read against other
  text than the buffer's, or from a client that restarted since, is dropped.
  Diagnostics for another version than the document's are dropped on the client's
  thread. They are per document and client (`Doc_Client.problems`, merged into
  `Doc.problems`); ones about older text are shifted through the edits since
  (`Doc.edits`), all are shifted with each frame's edits until the server publishes
  again (dropped when a frame has very many of both), and they are underlined through
  `View.problems`,
  which both kinds may draw. Hover needs the kind's `char_at` (the character under a
  point, never past a line's end) and `char_rect` (to anchor the popup); the pointer
  resting for `lsp.hover_delay` asks, problems there show at once. Going to a
  definition (F12, Ctrl+click, the editor menu) opens the file through `g.pending`
  with `g.open_target`; every jump records into `g.jumps` (Go back/forward). Jumps and
  F8 set `View.center` with `reveal`: a place out of view is scrolled to the middle. The
  editor's right-click menu (context_menu.odin) moves the caret to the click unless
  it is inside the selection, then lists Go to definition, Find references, Cut,
  Copy, Paste, Select all, each running its `Command`.
- **`typo <file>` in typo's terminals** (ipc/, ipc_open.odin): each typo listens on
  its own endpoint (`ipc.Server`, own thread): a named pipe `\\.\pipe\typo-<pid>-<random>`
  with a DACL for the current user only (the default one lets everyone read), else a
  Unix socket (0600) in a 0700 folder. Only its terminals' shells get it, as
  `TYPO_IPC` (`ipc_shell_env`, passed to `term.session_spawn`; typo's own environment
  and so language servers never have it, and a new typo unsets an inherited one, as
  it does Claude Code's session markers, `AGENT_SESSION_ENV` in main.odin). Run
  there, `typo <files>` (`forward_to_window`, before SDL starts) sends their absolute
  paths, prints the reply's messages (`attach_console`) and exits 1 if any was
  refused; a folder, `--new`/`-n`, `-t` or an endpoint that doesn't answer start a
  new window instead. Messages are length-prefixed frames of NUL-ended fields with a
  version (`ipc/message.odin`), validated on both sides. The server's thread checks the
  paths (a folder, or a missing parent folder, is refused; a missing file opens empty)
  and queues the rest; `ipc_frame` turns a request into `Open_Files`: each file in a
  new pane (`panes_open_file_beside`), the first right of the editor in use (above
  the rest when none is shown, so the terminal stays), the others each beside the one
  before, the last focused, and the window raised. No editor loses its place; a file
  already open is shown and focused. Persistent shells outlive their typo, so their
  `TYPO_IPC` is the project's name (`project:<hash of the folder>`,
  `ipc.project_name`) instead: each window lists its endpoint under the project it
  shows (ipc/projects.odin; a file per process in %LOCALAPPDATA%\typo\ipc\<hash>,
  else a 0700 folder of the user's runtime folder, refused if anyone else made it or
  may enter it), written by ipc_open.odin's registry thread as the folder changes,
  and `typo <file>` there tries them newest first through the usual checks,
  forgetting entries that don't answer.
- **The finder** (finder.odin) lists a `Finder_Source`: the workspace's files
  (Ctrl+E), or a server's `Finder_Item`s (lsp_symbols.odin): a file's outline
  (Ctrl+Shift+O, the caret's symbol selected), the project's symbols (Ctrl+T, asked
  again once the query rests `WORKSPACE_SYMBOLS_DELAY`, the earlier request
  cancelled), or places (Shift+F12 references, several definitions) with their
  lines. The client's thread decodes the answer (`[]lsp.Symbol`, `[]lsp.Place` with
  `preview`, files that aren't open read there), sorts an outline into the file's
  order and references by file (the asked one first); the items take the answer's
  strings over. Every source is filtered locally with `fuzzy.score`, incrementally
  (a `Search`: `search_step` scores rows within `SEARCH_BUDGET`, keeping the best;
  the sidebar's search field has another over the same index), and only the rows in
  view are laid out. Accepting goes through `jump_to`; a row
  clicked in the layout is opened next frame by `finder_frame`. Files open in typo
  (every editor pane, shown or kept for its unsaved changes) and recent files
  (recent.odin) come first, as in VS Code's quick open and Zed's file finder: they
  are ranked when the finder opens (`Search.ranked`, by `path_key_ascii`). With no
  query: the open files, most recently used first, then the recent ones, then the
  shortest paths; the focused file isn't listed, so Enter switches. With a query
  they get `FINDER_BOOST` on their score. Their rows say "open" or "recent".
- **Recent projects** (project_picker.odin, `g.project_picker`): state.json keeps
  the projects opened, most recent first (`state_project_opened` from
  `project_open`, at most `RECENT_PROJECTS_MAX`; folders gone are dropped when it is
  read at startup). Open project (Ctrl+R) or the sidebar's open folder button shows
  a popup of them, filtered as typed (fuzzy, the folder's name counting more),
  under that button while the sidebar shows, else at the top of the window, at the
  popups' layer (`project_picker_covers_pointer`, `g.in_project_picker`). Enter or a
  click opens one in this window (`Open_Folder`); Ctrl+Enter or a row's window
  button in another typo window (`Open_Window`: `launch_window` starts typo on the
  folder from a thread of its own, which waits on it to free its handle; a typo
  started outside its terminals never hands a folder to this one). Its last row,
  Open folder…, shows the system's folder dialog, whose choice opens the same way
  (`show_open_folder_dialog(new_window)`, `take_picked_folder`). Esc, a press
  outside or another shortcut closes it.
- **Recent files** (recent.odin, `g.recent`): the open project's files whose panes
  were focused, most recent first (at most `RECENT_MAX_FILES`; `recent_touch` from
  `pane_focus`). Renaming and deleting in typo update them; the project's
  session.json keeps them (`Session.recent_files`, saved even when sessions aren't
  restored), dropping files the finder's complete index doesn't have
  (`recent_drop_missing`).
- **Projects** (project.odin, `g.project`): the folder open is the project, with its
  data in a `.typo/` folder inside it, as Zed's `.zed/`: `.typo/settings.toml` (its
  settings layer and `[project] pinned`, paths relative to the project with forward
  slashes) and `.typo/session.json` (its last state, session.odin). `.typo/` is made
  only when there is something to write, then with a `.gitignore` holding
  `session.json` (`TYPO_GITIGNORE`), so the settings can be shared. `open_folder` calls
  `project_open`, which has the config thread read both; until they land
  (`project_read`) the pending Action waits (files from the command line, `-t`'s
  terminal and `typo <file>` go after the restored panes) and the window stays hidden
  at startup. Then the layer applies, pins and recent files are listed, and with
  `restore_session` the session is restored (the window's size only for the run's
  first project). Leaving a project (`project_leave`: opening another folder, after
  the unsaved-changes flow) saves its state and closes every pane (local shells
  end, persistent ones go on); quitting saves it. It is also saved as it goes
  (`session_save_frame`, at the end of a frame): at most every `SESSION_CHECK` the
  state is built and written on the config thread if it differs from the last
  write (`saving`), and a one-shot SDL timer wakes an idle loop for a last check
  after frames that weren't checked, so a crash loses little. Leaving also drops
  recent files the index no longer has (`recent_drop_missing`, which walks it);
  saving as it goes doesn't. A folder opened for a file given alone isn't a project (nothing
  restored or saved) unless it has `.typo/` or typo writes one there (a pin). Paths
  in the files go through `project_rel`/`project_abs`. state.json beside
  settings.toml (`App_State`, session.odin) keeps what isn't per project: the project
  reopened with no arguments; the first start without it takes over an older typo's
  session.json (`imported`: its layout for its folder, each folder's recent files),
  handed to each project when it next opens without a session of its own.
- **Settings layers** (settings.odin): `Settings` holds the values in effect
  (`using values: Setting_Values`, what the app reads as `g.settings.x`), the user's
  (`user`, settings.toml) and the project's (`project: Setting_Layer`, values and
  the `set` it names); `settings_resolve` works out the first from the others.
  Keybindings, servers' tables and `user_only` settings (restore_session, renderer,
  bundled ConPTY, collapsed sections) are the user's only; a project file setting one
  gets a problem. Files are parsed into `Loaded_Settings` (`settings_parse`, any
  thread) and taken in on the UI thread (`settings_take_user`/`_project`).
  `settings_changed` (user layer, bindings, servers) saves settings.toml;
  `project_settings_changed` saves the project's file with its pins. The settings
  window's User/Project switch (`scope`, `scope_switch_side`) picks the layer shown and
  changed (`shown_values`, `edit_values`: a change in Project scope starts from the
  user's value it followed); Project scope hides what is the user's only, notes each
  setting the project sets (Del follows the user's again), and its footer resets the
  project's values or opens `.typo/settings.toml` (written first if missing); User
  scope notes a setting the project sets in its place.
- **Config thread** (config_io.odin): settings files, projects' files and state.json
  are read and written on one thread, in order (a waiting write to a file is replaced
  by a newer one); results land in `config_frame`. A timer on SDL's timer thread polls
  the watched files' write times (`Watched_File`: settings.toml, the project's
  settings) and queues a read when one changed, made or deleted, not after typo's own
  writes. settings.toml and state.json are read at once at startup, before the window
  shows. Without the thread (unit tests) a job runs at once and its result applies.
- **Keybindings in the settings** (settings_ui.odin): a command's bindings (up to
  `MAX_CHORDS`) are chips, each with an x on hover; Add records one more (a key or a
  side button), taking it from the command that had it (`bindings_add`), which the
  row then says (`bind_note`); Reset puts the defaults back. Keys: Enter on the row
  adds, ←→ move the focus between the row and its chips (`chip`, `chip_command`),
  Delete or Backspace removes the focused chip, Delete on the row resets.
  At the row's right a terminal toggle says whether the command works while a
  terminal has focus (`Settings.terminal_commands`, settings.toml's
  `terminal.commands`, user only; `DEFAULT_TERMINAL_COMMANDS` when left out); other
  chords go to the shell, as do a set command's when it doesn't apply.
  `EDITOR_COMMANDS` (acting on an editor's text) have no toggle and always do.
- **Completion and signature help** (lsp_completion.odin): `lsp_typed` (from
  `editor_text_input`) marks completions due: once identifier typing rests
  `COMPLETION_DELAY` (not on a number, nor in a comment or string by the highlighter),
  at once on a trigger character, or on Trigger completion (Ctrl+Space). Requests go out
  in `lsp_completion_frame`, which runs after `panes_frame` so the frame's edits reached
  the server first. The client's thread decodes items (`lsp.Completion`: what each
  replaces as offsets, snippets reduced to plain text with what to select, other edits);
  the list takes them over and filters them against the word before the caret
  (`fuzzy.score`, then the server's sort text). An incomplete list is asked again
  whenever the buffer is past the version its items are about (`answered`), so text
  typed while an answer was on its way is asked about too. While the list shows,
  `lsp_completion_handle_key` takes Up/Down/Page Up/Down/Enter/Tab/Esc; a row clicked
  in the layout is inserted next frame (`lsp_completion_click_frame`, before the panes'
  frames). Inserting (`accept_completion`) moves the item's range by what
  was typed since it was asked, uses the same span at every caret, adds its other edits
  (e.g. an import) and makes them one undo step with `textedit.apply_edits`. The chosen
  item is resolved for its documentation. Signature help (Ctrl+Shift+Space, or a
  signature trigger character) is asked again while it shows and the caret moves or the
  text changes; a null answer closes it. Both close when their editor loses the keys.
- **Word completions** (word_completion.odin, words/), as Zed has them: the settings'
  completions section sets `words` ("fallback", "enabled", "disabled"),
  `words_min_length` (3), `lsp_fetch_timeout_ms` (500) and `words_in_text_files`
  (off: no words in Markdown or .txt files; files typo has no language for still get
  them). An editor's words (`words.Index`: identifier-like runs not starting with a
  digit, once each, sorted, from `words.WINDOW_LINES` either side of the caret's line
  but no more than `WINDOW_BYTES` either side of it, less the run at the caret) are
  collected by the words thread (`words.Indexer`) from a snapshot when the editor
  gets the keys, again once typing in it rests `WORDS_DELAY` (edits only:
  `take_changes` runs `on_edit` every frame), or when the caret nears an end of the
  bytes read (`words_frame`). Only the file's own words, as Zed. The list (`Server_Answer`) opens with words when no server
  completes, when the answer is empty or an error, or when it is late
  (`server_time_limit`); a later answer with items replaces them, unless a row was
  chosen with the keys (`navigated`), then they stay until the next letter. With
  "enabled" words follow the server's items. Word rows (`Shown_Completion.index`
  -1, kind "word") skip the word typed, what an item inserts and, unless a digit is
  typed, words with digits; the list holds the index its rows show (`word_index`).
  A typed word gets words once it is long enough; Trigger completion at any length.
  Accepting one replaces the word before every caret through `accept_completion`.
  `words_ui` is the UI thread's share, which the perf suite limits per frame
  (`words_limit`).
- **Rename and workspace edits** (lsp_rename.odin, lsp_edits.odin, lsp/edits.odin):
  Rename (F2) renames the symbol at the caret when the editor's server can, else the
  pane. prepareRename (or the identifier at the caret) gives the name; a field over it
  takes the new one; the answer, a WorkspaceEdit, is read on the client's thread as byte
  ranges per file (`lsp.File_Edit`: an open document's at its version, else the file
  read from disk with its size and hash). `lsp_apply_workspace_edit` refuses it if an
  open file changed since, edits files open in editors (`textedit.apply_edits`, carets
  kept, left unsaved), and asks before rewriting files that aren't open, which a writer
  thread does (`lsp.write_file_edit`, only if the file is unchanged). A server's
  workspace/applyEdit (`lsp.Apply_Edit` event) goes the same way and is answered with
  `lsp.reply_apply_edit`.
- **Git** (git/, git_state.odin): libgit2 does reads and the index in-process
  (git/repo.odin: finding the repository from the workspace folder, the status as
  `git.Status` entries by `git.Area` (conflicts, staged, changes, untracked), HEAD's
  branch and short id, the upstream and ahead/behind, file versions in HEAD or the
  index, staging, unstaging, discarding from the index, moving untracked files to the
  trash (`Delete_Untracked.to_trash`; tests delete them for good), and
  `splice_index` for a hunk); the git command line does commit (`--file=-`, so hooks
  and signing work), push, pull and fetch (git/cli.odin: no console window,
  `GIT_TERMINAL_PROMPT=0`, a credential helper's own window still shows). File
  versions are read as checked out (libgit2's smudge filters: the work tree's line
  endings) and text put in the index is cleaned first. Nothing of it runs on the UI
  thread: `git.Worker` (git/worker.odin) owns the repository for writes, takes
  requests in order, follows each change with a fresh status, and hands events over
  (`worker_take`); commands run one at a time on a thread of their own, which quitting
  ends (`running_end` kills git and what it started). The diff loader keeps a
  read-only repository handle of its own (HEAD and index versions). A folder change
  drops the requests and events still queued, and events from work begun before it
  (they carry the folder generation they were made under: their paths would name
  other files in the new repository). The status
  follows the repository: the watcher's bursts (any burst is handed over as a
  `Watch_Batch`, so files written in place count) call `git_workspace_changed`, and the
  worker polls the files that describe the repository every `git.POLL` (index, HEAD,
  the branch's and upstream's refs, packed-refs, FETCH_HEAD, MERGE_HEAD: outside the
  workspace for a linked worktree, and the watcher drops .git), so a commit in a
  terminal shows up. Refreshes asked for meanwhile are done once, never closer
  together than the last one took (`REFRESH_GAP` at least). A failed push, pull or
  fetch shows git's words in a dialog that can run the command in a typo terminal
  (`panes_run_in_terminal`). `git_ui` is the UI thread's share, which the perf suite
  limits (`git_limit`).
- **Git pane** (git_pane.odin, `Git_View`, one at most): beside its title, faded, the
  upstream (else the branch) and a merge or rebase under way (`git_title_note`); a
  commit message box (`Text_Area`, Ctrl+Enter commits), Commit (the key small at its
  right while it fits, `commit_hint_fits`) and the push, pull and fetch group with the
  commits to push and pull, how the last command went, and the files in collapsible
  sections, each
  row with its icon, name, folder and a letter colored by its change (`git_*` theme
  colors), stage/unstage/discard buttons on hover (per section on its header; discard
  asks first, `Git_Discarding`). Rows aren't stored: `row_at` finds one from the
  sections' sizes, and only the rows in view are laid out. Keys: Up/Down, Enter (diff
  or collapse), Space (stage or unstage), Delete (discard), Tab/Esc into and out of the
  box. Open Git pane (Ctrl+Shift+G, the status bar's branch item) opens it left of the
  editor in use or focuses it. A row clicked opens its diff next frame (`chosen`).
- **Text area** (text_area.odin): a multi-line field on `textedit.View` with its own
  kind (`AREA_KIND`) in the interface font: the editor's caret movement, selections,
  undo and clipboard; it grows with its lines up to `TEXT_AREA_MAX_LINES`, then
  scrolls. Its owner decides focus and takes the keys it wants first.
- **Diff view** (diff_view.odin, diff_load.odin, diff/rows.odin): a pane comparing a
  file's versions side by side: changes (index | work tree), staged (HEAD | index),
  untracked (nothing | work tree), conflict (HEAD | work tree). The work tree side is
  the open editor's text (a snapshot) when the file is open, else the file. The
  loader thread reads both, diffs them by lines (`diff.line_hunks`: line endings don't
  count, as git sees a file checked out with other endings), finds changed words
  (`diff.words`, within `WORD_LINE_MAX`/`WORD_PAIRS_MAX`), and builds each side's
  buffer and highlighter (Markdown is plain text); a job carries what the view shows
  (`Diff_Signature`), so a load that would change nothing costs nothing. Rows aren't
  stored (`diff.row_at` finds a row from the hunks); only rows in view are drawn, both
  sides scrolling together. Each hunk has buttons in the strip between the sides
  (laid out by Clay, scrolling with the rows): the arrow reverts it to the left
  side's text (in the open editor through `textedit.apply_edits`, one undo step,
  with that editor's line endings; else on the writer thread as a `Patch_Job`, only
  if the file is still as read), + stages it (`git_splice_index`), and in a staged
  diff the arrow unstages it. A press is recorded and applied next frame (`clicked`).
  A view loads again on every new status and once an open editor's edits rest
  `DIFF_EDIT_DELAY`; what it showed is freed on the loader thread
  (`diff_load_retire`). Clicking a file opens its diff in the diff pane shown, else in
  place of the editor in use, else right of the Git pane. Git and diff panes close
  when they leave the layout (no shelf); the session keeps both.

### A frame (`app_iterate`, main.odin)

1. Apply the config thread's results (`config_frame`: settings files read again, a
   project's files, writes), the pending `Action` (it waits while a project's files
   are read), the loader's and writer's results (`file_load_frame`;
   `unsaved_frame` goes on once writes landed or a programs check finished), the
   watcher's (`file_sync_frame`), the Git worker's (`git_frame`) and the diff
   loader's (`diff_views_frame`), update focus, run `finder_frame` and `panes_frame`
   (divider and pane drags, then each pane's `editor_frame`/`terminal_frame`), which
   read last frame's layout (`element_rect`, `pointer_in`) and handle the mouse.
2. `build_ui` (layout.odin) declares the Clay tree; editors and terminals are custom
   elements drawn by `draw_editor`/`draw_terminal`.
3. `render_clay_commands`, present, `free_all(context.temp_allocator)`.

- Nothing shows half ready: a new file isn't drawn (`Editor.shown`) until it has
  loaded, has real bounds and no image in view is loading (or `EDITOR_SHOW_WAIT`
  passed; a file still loading then says so); the window starts hidden until the
  first ready frame (`panes_ready`).
- The loop sleeps when idle: `needs_continuous_frames` lists what keeps it awake,
  other threads call `wake_main_loop`.
- Strings used by a frame's render commands must outlive the frame's drawing: per-frame
  strings use the temp allocator, and opening files/folders, closing panes and UI
  buttons that change the panes are deferred via `g.pending` (`defer_action`). A click
  found while declaring a list (`clicked`) that would free or replace what the list
  shows (its rows, the buffer) is only recorded, and applied before the next frame's
  panes (the finder's and completion list's rows, the context menu's `chosen`).

## Layout

```
src/                 package editor: the app
  main.odin          App state (global `g`), SDL callbacks, frame loop, idle, deferred actions
  keymap.odin        Command enum, default bindings, chords (a key, or a mouse side
                     button: "Mouse4" back, "Mouse5" forward), adding and removing
                     bindings, run_command
  settings.odin      Settings model: SETTINGS table, the user's and the project's layers
                     and the values in effect, parsing and writing both files
  config_io.odin     The config thread: settings files, projects' files and state.json
                     read and written in order; the watch timer
  project.odin       The project: its .typo folder, opening (files read, state restored)
                     and leaving, pinned files, project-relative paths
  settings_ui.odin   Settings window from SETTINGS, sections collapsible (kept in
                     collapsed_sections); the User/Project scope switch; theme/font
                     picker docked at the side; keybinding rows with a chip per binding
  settings_servers.odin  Language servers in the settings window: rows, a server's page,
                     Add/Remove, Install
  render.odin        Clay render commands -> gfx calls; Clay text measurement
  ui.odin            Widgets (label, button, icon, list_row, tooltip, modal),
                     hit tests (clicked, pointer_in), transition, element_at
  scrollbar.odin     Scroll bars (either axis, on gfx/scrollbar.odin), list_scrollbar,
                     wheel routing
  layout.odin        Window layout: "Main" (sidebar, panes), status bar, mouse cursor
  sidebar.odin       The sidebar behind the panes (folder name, search field and its
                     popup, file tree with unsaved dots, RECENT, shelf), fading as
                     they cover it
  sidebar_recent.odin  RECENT: pinned and recent files, their rows
  panes.odin         Panes: shelf, split tree, drops, divider and pane dragging,
                     pane UI, focus, pane commands
  editor.odin        Editor: state, Markdown attachment, renames, keys, commands,
                     clipboard (opening and saving are in file_load.odin)
  editor_view.odin   Editor per-frame update, mouse selection, scrolling, scroll bars,
                     drawing, all through the view's kind
  text_view.odin     TEXT_KIND: line grid, gutter, highlighting, line/column movement
  md_env.odin        mdview.env: the app state mdview may see
  terminal*.odin     Terminal: session, row cache, drawing, input
                     (terminal_persist*.odin: persistent terminals in herdr-core: the
                     client, starting and attaching, the session's ids, the
                     setting's note)
  terminal_programs.odin  Programs running in terminals, looked up on a thread
                     before closing a terminal, quitting or opening a folder
  dialog.odin        In-app dialogs (dialog_show; a choice applies next frame), the
                     unsaved-changes flow (resolve_unsaved; files, then running
                     programs), the delete prompt
  context_menu.odin  Right-click menu on tree rows, pane titles and shelf terminals
  rename.odin        Renaming in place (tree row, shelf row or pane title; F2), and
                     naming a new file or folder in a new tree row
  line_edit.odin     The text field every input uses: editing keys, words, clipboard,
                     undo, the mouse, sideways scrolling (Line_Edit, text_field)
  fs_ops.odin        Create, rename and delete, keeping open files (path, highlighting,
                     Markdown mode), the tree and the finder in step. Delete moves to
                     the trash (`TRASH_NAME`: Recycle Bin or Trash) on the writer
                     thread (`Delete_Job`, `delete_landed`); an item that can't go
                     there is not deleted, and the user is asked to delete it
                     permanently. Names Windows can't use are refused.
  finder.odin        The finder: files (Ctrl+E: background indexer, incremental
                     search, shared with the sidebar's field) or a server's symbols
                     and places; rows in view only
  find*.odin         Find in a pane (Ctrl+F): the bar, searching editors (plain, whole
                     word, case, regex), libghostty search in terminals
  goto_line.odin     Go to line (Ctrl+G): the bar, reading "line:column", previewing
  workspace.odin     Lazy file tree, folder dialog
  session.odin       A project's state (window, panes and layout, open folders, recent
                     files) in its .typo/session.json; state.json (the project to
                     reopen), taking over an older typo's session.json
  recent.odin        The project's recently used files, for RECENT and the finder
  project_picker.odin  Recent projects: the popup (Ctrl+R, the open folder button),
                     opening one here or in another window
  ipc_open.odin      `typo <file>` from typo's terminals: the listener, its queue, the
                     shells' TYPO_IPC, and the command line's side (forward_to_window)
  fs_walk*.odin      Directory listing (the tree's order: read_tree_folder), recursive
                     file listing
  fs_watch*.odin     Watcher thread: notifications, bursts, folder listings, reading
                     and diffing changed open files; file_stamp, read_file_shared
  file_sync.odin     The watcher's results applied: tree, finder, reloads, the
                     "changed on disk" dialogs, saving over a newer version
  file_io.odin       Loader threads and the writer thread: jobs, queues, results
                     (reading and building a document, writing a snapshot)
  file_load.odin     Opening and saving in the app: the Loading state, results
                     wired up, When_Ready, the large-file question, save results
  lsp.odin           Language servers in the app: langs.env, responses by feature, F8,
                     installs, go to definition, the jump list
  lsp_symbols.odin   Symbols and references in the finder: asking, answers as items
  lsp_completion.odin  Completion (list under the caret, filtering, inserting, the
                     file's words in it) and signature help (above the caret)
  word_completion.odin  Each editor's words for completion: the words thread, when
                     they are collected, words_mode per file
  lsp_rename.odin    Renaming a symbol: prepareRename, the field over the name
  lsp_edits.odin     Workspace edits: open files in their editors, other files after a
                     dialog on a writer thread, answering workspace/applyEdit
  lsp_hover.odin     Hover: pointer resting, the popup, simple Markdown rendering
  lsp_status.odin    The status bar item (language + state dot) and its popup: restart,
                     stop, disable, log; turn on, install (in a terminal), locate a
                     server's program (file dialog, saved as its path) or turn off
                     a server not found
  zoom.odin          Zoom per pane: commands, the status bar item and its popup
  git_state.odin     Git in the app: the worker's events, staging, discarding (asked
                     first), commit/push/pull/fetch, a failure's dialog, the status bar's
                     branch item, git_ui
  git_pane.odin      The Git pane: branch, message box, Commit and remote buttons,
                     sections of files (rows found, not stored), keys, opening diffs
  text_area.odin     A multi-line text field on textedit.View (AREA_KIND)
  diff_view.odin     The diff pane: following the file, hunk buttons (revert, stage,
                     unstage), scrolling, keys, drawing both sides
  diff_load.odin     The diff loader thread: reading both versions, diffing, changed
                     words, each side's buffer and highlighter; freeing retired sides
  perf*.odin         Perf suite and CPU/GPU counters (perf_persist.odin: the
                     persistent terminal phase)
  *_test.odin        App tests (editor_test, md_view_test: a Markdown file in the editor,
                     panes_test: the split tree, find_test: searching an editor,
                     line_edit_test: keys in a text field, fs_watch_test: bursts,
                     the tree following listings, reloads, recent_test: the recent
                     files, project_test: settings layers, pins written, each
                     project's state restored, the old session.json taken over,
                     goto_line_test: places and keys in the
                     bar, keymap_test: adding, taking and removing bindings,
                     file_load_test: loads and writes on their threads, the unsaved
                     flow waiting, sidebar_test: folders marked for unsaved files,
                     keys in the search popup, diff_view_test: hunks reverted on disk
                     and in an editor, staged and unstaged, on a temp repository)
src/gfx/             Drawing: draw.odin (primitives on gfx.renderer, clips, overlays,
                     selection shapes), scrollbar.odin (scroll bar geometry, dragging
                     and look along either axis),
                     text.odin (gfx.text_system, font ids, measurement, caret
                     positions, contrast),
                     fonts.odin (bundled IBM Plex, Instrument Sans, installed-font scan), theme.odin
                     (THEMES, gfx.theme), geometry.odin (Rect), icon.odin,
                     box_glyphs.odin (box drawing and blocks as shapes; data in
                     box_glyphs_table.odin)
src/textedit/        Editing core: view.odin (View, marks), kind.odin (Kind, move, key,
                     undo, multi-cursor, moving lines, clipboard), edit.odin (selections,
                     normalize, apply, line/column/word helpers, visible_runs)
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
src/buffer/          Piece table (treap), stores in blocks that never move, newline
                     index, undo, change log, snapshots
src/syntax/          Highlighter: tree-sitter (Odin, TOML), line lexer (others)
src/term/            libghostty-vt bindings, Session (vt + backend: pty and reader
                     thread, or a herdr-core stream), processes_*.odin (programs
                     running under a shell)
src/herdr/           herdr-core client: frame.odin (framing), protocol.odin (requests,
                     results, events), client.odin (threads, reconnects, streams),
                     hc.odin (finding hc, starting hc connect), sandbox.odin (private
                     sessions for tests and the perf suite, one at a time: they set
                     HC_SESSION process-wide; the stop at the end names its session
                     in its own environment, as hc without HC_SESSION reaches the
                     user's own core)
src/langs/           The app's language servers, no UI: config.odin ([lsp.<name>]
                     tables, the merged server list), clients.odin (state, env, the
                     clients, restarts, lookups, the frame, ui_share), docs.odin (documents
                     on their servers: open, change, save, close), problems.odin
                     (published, shifted by edits, counted), requests.odin (which
                     client, matching responses)
src/lsp/             LSP client: registry.odin (LANGUAGES, SERVERS, roots), install.odin
                     (INSTALLERS: install commands' programs and weights), client.odin
                     (the UI thread's side: commands, events), worker.odin (the
                     client's thread: handshake, documents, JSON, progress, log),
                     connection.odin (process threads), lookup.odin (PATH and root
                     lookups thread), edits.odin (workspace edits as byte ranges,
                     rewriting a file), changes.odin (a frame's changes as edits;
                     shifting and merging problems), rpc.odin (framing), protocol.odin
                     (capabilities, params, Feature), position.odin (columns, offsets
                     in a document, file URIs); fake_server/ for tests
src/fuzzy/           fzy-style scorer (files, symbols, completions)
src/words/           A document's words from a snapshot (collect, Index) and the
                     thread that collects them (Indexer)
src/ipc/             A typo's endpoint: message.odin (frames, requests, replies,
                     validation), server.odin (server thread, send), ipc_windows.odin
                     (named pipe, its DACL, overlapped I/O), ipc_unix.odin (socket),
                     projects.odin (endpoints by project, for persistent shells)
src/diff/            Line diffs (Myers): byte hunks for reloading files changed on disk,
                     line hunks and side-by-side rows (rows.odin) and changed words for
                     the diff view
src/git/             A repository: git.odin (Status, Entry, Area, paths), repo.odin
                     (libgit2: open, status, versions, stage, unstage, discard,
                     splice_index, the files the poll watches), worker.odin (the worker
                     thread: requests, events, refreshes, the poll), cli.odin (the git
                     command line on a thread of its own); git_test on temp repositories
src/process/         Child processes on pipes without a console window, in a job object
                     on Windows (unless `detached`), with extra environment variables
                     and stderr discarded if asked; PATH lookups; process_test
src/toml/            Minimal TOML reader
src/trash/           Moving to the system's trash from any thread: trash_windows.odin
                     (IFileOperation in a single-threaded apartment, stopped before
                     destroying what can't be recycled), trash_darwin.odin
                     (NSFileManager trashItemAtURL), trash_freedesktop.odin (Linux and
                     BSDs: the home trash or the device's .Trash-$uid, a .trashinfo
                     reserving each name; tested there with a temp XDG_DATA_HOME)
src/uitime/          A feature's share of the UI thread (Share, timed, take)
vendor/              clay-odin, tree-sitter* (do not edit); sdl3: Odin's SDL3 bindings with
                     foreign imports pointed at the static libraries; libgit2: bindings
                     for what typo uses, and its license
ref/clay_docs.md     Clay API reference
docs/                Design notes (terminal_persistence.md: herdr-core's protocol)
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
  terminal included, but not to floating children (Clay emits them as their own
  roots): give those the same overlay and transition.
- **Clipping changes layout**: Clay doesn't compress a clipping element's children
  along the clipped axis and grows its Grow children to their content. A Grow page
  directly in a clipping panel is as tall as its rows, so a list in it never scrolls
  and has no bar. Size what a clipping panel holds to the panel (`modal_at`'s pages
  are fixed; their lists are Grow inside them).
- **Clipping elements are few**: Clay's store of clip and scroll containers holds about
  100 (a changed list's old ones linger a frame); past that it fails with "out of
  bounds array access". Lists lay out only the rows in view, and a row clips its
  text through `row_clip()`, which stops clipping past `ROW_CLIP_BUDGET` a frame.
  Every perf phase checks Clay reported no error and no frame drew `CLIP_LIMIT` (80)
  clipping elements (`g.frame_clips`, counted in `render_clay_commands`).
- **Scrolling**: use `update_scroll_containers`, not `clay.UpdateScrollContainers`. The
  wheel goes to the topmost list registered with `wheel_scroll_list` (`list_scrollbar`
  does that), not to any clipping element.
- **Stacking** (floating zIndex): the sidebar in the base layout, "WorkArea" and
  leaving panes 1, panes 2 (maximized 4: `pane_layer`), find bar 5, go to line 6,
  popups (`modal`, finder, settings, sidebar search) 100 (`POPUP_LAYER`), hover
  popup 115, completion list, signature and rename field 116, context menu,
  language server and zoom popups 120, dialog 150, tooltips 300. A list's scroll bar
  thumb (`list_scrollbar`) floats one above the layer of what holds the list, so
  whatever covers the list covers it too.

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
- Follows Obsidian Live Preview (lists edit like Obsidian), except: the caretless
  reading state stays (clicking the side margin hides the caret), links follow on
  Ctrl+click only, and the selection grows on release to cover hidden syntax. Keep
  table code on cell byte ranges so a CSV view can reuse it.
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
- List numbers hang left of the item text, ending a few pixels before it; each digit
  takes a cell as wide as the font's widest digit (tabular figures, which SDL_ttf can't
  ask the font for), so numbers line up on their dot in any font (`add_marker`).
- While the mouse is down, reveal state is frozen (`hold_reveal`) so text doesn't move
  under a drag; on release the selection grows to what copying takes (`snap_selection`).
- Caches (`begin_caches`): per document (inlines, tables, code blocks, code highlights)
  and per document + selections + column width (line layouts). A new pane width only
  refits tables. Lines have their own heights in a `Height_Map` (top margin: `pad`).

## Code style

Code should read like the author's own: airy, one idea per line, grouped into steps.
New and changed code follows this; existing code is brought in line when touched.
`.claude/hooks/check_style.py` checks the width and `do` rules after every Edit/Write
of a file in src/ (so edit source with Edit/Write, not shell scripts).

- **Width**: at most 100 columns, tabs counted as 4. Break a long signature or call
  with its arguments on their own lines and the closing paren on its own line; break a
  long condition at `&&`/`||`. A named intermediate value beats one long expression.
- **Steps**: a procedure that does several things puts a blank line between them
  (setup, the work, the result). A block of more than a few lines that is one step
  starts with a short label comment.
- **One-liners**: `if x do y` only when x is a single simple condition and y one simple
  statement or call (`if !ok do return`). Anything more gets a braced block, guard
  clauses included.
- **One thing per line**: one statement per line. Multiple assignment only for values
  that come together (`value, ok := ...`). Ternaries for simple picks, never nested.
- **Top level**: two blank lines between procedures; constants and fields that belong
  together are grouped and aligned. No procedures nested in procedures: a helper is a
  top-level `@(private = "file")` proc beside its user.
- **Comments**: short and plain, no trailing period on one-liners. A procedure gets a
  one-line description of what it does when the name doesn't say it all ("Returns the
  pane under the pointer, if any"). Inside, steps get labels ("// Close the files that
  were inside it"). A comment says why when the code can't ("// ConPTY keeps its own
  screen"). Trailing comments on struct fields are fine; `// --- Section ---` banners
  split long files. About the current code only (no history, benchmarks, rejected
  options, conversations).

Example (before, then after):

```odin
path_deleted :: proc(path: string) {
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		if i >= len(g.panes.open) do continue
		if e, ok := g.panes.open[i].content.(^Editor); ok && path_within(e.path, path) {
			pane_close(g.panes.open[i], ask = false)
		}
	}
	workspace_refresh(&g.workspace)
	finder_invalidate()
}
```

```odin
// After deleting a file or folder: its open files close, and the tree and the
// finder forget it
path_deleted :: proc(path: string) {
	// Close the files that were inside it
	for i := len(g.panes.open) - 1; i >= 0; i -= 1 {
		if i >= len(g.panes.open) do continue

		pane := g.panes.open[i]
		e, is_editor := pane.content.(^Editor)
		if is_editor && path_within(e.path, path) {
			pane_close(pane, ask = false)
		}
	}

	workspace_refresh(&g.workspace)
	finder_invalidate()
}
```

## Conventions

- Reuse helpers: `clicked`, `pointer_in`, `element_rect`, `gfx.rect_contains`,
  `gfx.draw_text`, `gfx.fill_rect`, `gfx.push_clip_box`, `Line_Edit` + `text_field` +
  `line_edit_event` (any text input), `modal` + `clicked_outside`, `dialog_show`
  (never a blocking native box), `resolve_unsaved` before closing files, `textedit.line_span`,
  `textedit.next_col`, `set_string`, `list_scrollbar` (with `SCROLLBAR_GUTTER` right
  padding and the layer of what holds the list), `list_reveal_row` (the selected row
  in view), `list_row` (sidebar rows), `gfx.draw_caret`, `scroll_ease_step`,
  `WHEEL_LINES` and `WHEEL_COLUMNS` (scrolling text).
- New setting: a `Setting` value, a `Setting_Values` field, a `SETTINGS` entry, a
  `setting_value` case; `user_only` if a project can't set it. Long-list string
  settings set `picker = true` and fill `picker_options`; related number settings go
  in `picker_extras`. Code reads the values in effect (`g.settings.x`); a change goes
  to a layer (`g.settings.user`, or the settings window's `edit_values`), then
  `settings_changed` or `project_settings_changed`.
- New command: a `Command` value, a `COMMANDS` entry, a case in `run_command` or
  `editor_run_command`. A chord may name a mouse side button (`MOUSE_BUTTONS`); its
  press runs the command next frame on the pane under the pointer, which it focuses
  (`button_chord_frame`), or is recorded by the settings window.
- Tooltips (`tooltip`, right after their element) appear at the pointer where it
  rested: below it, above when there is no room, shifted to stay in the window.
- Pointer input goes through `ui_interactive` (via `clicked`, pane frame procs,
  tooltips); a new popup that blocks all or part of the window belongs there. While
  the dialog or context menu is open only their own UI (built with `g.in_popup`) reacts;
  showing a dialog closes the menu, and a rename field stays open under a dialog.
- A file or folder name typed by the user goes through `rename_path`/`create_path`,
  which refuse names the OS can't use; deleting goes through `ask_delete_file`.
- Reading a file the user works on goes through `read_file_shared` (never blocks other
  programs), off the UI thread; opening one in an editor goes through `editor_open`,
  and whatever needs its text then through `editor_when_ready`; writing one an editor
  shows goes through `editor_save` (the writer thread, which tells the watcher what it
  wrote). Perf phases and tests that use a file's text at once open it with
  `open_loaded`/`editor_wait_loaded`, and wait for saves with `wait_for_saves`.
- Fonts: three configurable families. The interface uses `.Body`/`.SemiBold`/`.Bold`
  (`ui_font`, default Instrument Sans Medium; set by `apply_ui_font`, which has Clay's
  measurements reset next frame); editor and terminal use `.Editor`/`.Editor_Bold`
  (set by `apply_editor_font`); rendered Markdown the `Md_*` ids
  (`apply_markdown_font`). Bundled faces are picked by weight. Column width:
  `editor_char_width` (includes letter spacing, whole device pixels: the editor
  font's faces are laid out in cells, `gfx.CELL_FONTS`); row height:
  `editor_line_height`; both at a pane's zoom factor (see Zoom). A caret's place in
  proportional text: `gfx.text_caret_x` and `gfx.text_caret_at` (`gfx.text_width`
  is the inked extent, short of a trailing space). Text antialiasing
  (`gfx.Antialiasing`): subpixel (LCD)
  below 2x scale when the system uses ClearType, else grayscale; drawing anything
  but text outside gfx calls `gfx.flush_text` first.
- Temp allocator for per-frame data; free owned data (tests use the tracking allocator).
- `@(private = "file")` for single-file helpers, `@(private)` for package internals.

## Planned directions

The architecture should allow these without rewrites:

- **Theming**: user themes from TOML would add `gfx.Theme_Spec` entries to `gfx.THEMES`
  and `gfx.THEME_NAMES`. UI colors come only from `gfx.theme`.
- **LSP features**: sync, diagnostics, hover, go to definition, the editor menu,
  symbols and references (in the finder), completion, signature help, rename and
  workspace/applyEdit are in place.
  Each is an `lsp.Feature` (`lsp.has_feature`), asked with `langs.send_request`, its
  result decoded on the client's thread (`answer_ui` in lsp/worker.odin, offsets
  converted there) and handled from `lsp_response` (lsp.odin). Don't call
  `buffer.take_changes` outside `textedit.take_changes`: it drains the changes.
  `syntax.Highlight` is per byte, so semantic tokens can overlay it. Features stay
  generic: driven by capabilities, nothing coded per language.
- **LSP decisions (the user's)**: servers come from `lsp.SERVERS` plus `[lsp.<name>]`
  tables in settings.toml (no separate languages.toml); pointing typo at a program
  (`path`) is preferred over searching other editors' folders; a missing server gets
  Install, which runs an install command in a terminal (no managed downloads): only
  commands whose installer is on PATH are offered, lightest installer first (if both
  uv and cargo are there, uv); install commands in the table are only ones verified to
  install a working server; popular servers on by default (pyright + ruff for Python,
  tombi for TOML), alternatives off (ty, basedpyright, taplo, marksman). The user uses
  ty, ols and rust-analyzer.
- **LSP gaps** (candidates for next):
  - Rendered Markdown doesn't draw `View.problems` or provide `char_at`/`char_rect`,
    so hover, completion, signature help and the rename field don't show there.
  - Rename has no preview; a WorkspaceEdit that creates, renames or deletes files is
    refused (no resourceOperations); change annotations are ignored.
  - Snippets select only the first tabstop (Tab doesn't move on); commit characters
    aren't used.
  - Completion closes when any caret leaves the word (multi-caret); re-filtering a
    long list isn't timed in `langs.ui_share`; a crash isn't noticed while a child of the
    server still holds its stdout.
  - Still on the UI thread: a file's stat before saving (`changed_since_read`).
  - On Windows `python` may be the Microsoft Store's alias, which only offers to
    install Python: `python -m pip` is offered then (when neither pip nor py is found).
  - A program installed where PATH only reaches in new processes isn't found until
    typo restarts (Locate… covers it). Workspace settings and initialization options
    are only edited in settings.toml.
  - Wire request ids count from 1 and stay in i32: servers on Rust's lsp-server (ty)
    read them as 32-bit (the fake server ignores larger ids to catch this).
- **Settings mini LSP**: hover help and diagnostics for settings.toml, built on the
  SETTINGS/COMMANDS tables, are planned; that's why `settings_save` writes no comments.
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
- **Several windows** (dragging panes between them): typo has one window, with one
  `g`, renderer, text system and Clay context. Several would need per-window state
  (renderer, gfx caches and atlas, Clay context, panes and layout, focus) split from
  what the process shares (settings, language servers, documents), with each
  window's frame run against its own state, and panes (with their editors or
  terminals) handed between windows. Keep new window-wide state in `g` grouped so
  it can move into a per-window struct.
