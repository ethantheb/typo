# typo

A code editor in Odin: SDL3 + SDL_ttf (window, text), Clay (layout), tree-sitter plus a
fallback lexer (highlighting), libghostty-vt (integrated terminal), and a Language Server
Protocol client (src/lsp). Developed on Windows.

## How to work

- **The UI thread does only UI.** Anything that waits, parses, spawns, searches, walks
  files, writes logs or does file IO runs on another thread and hands over finished
  results, even if each is "only a few ms". Give such features a perf limit on their
  UI-thread share per frame (like `langs.timed` and `lsp_limit` in perf.odin), not just
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
  through launch arguments (`typo -t <folder>`, `typo <file>`) or perf phases.
- Screenshots: user32 `PrintWindow(hwnd, dc, 2)` on the test window's handle, bitmap
  sized from `GetWindowRect`. Not `CopyFromScreen` (it grabs whatever window is on top).
  Check new UI with a copy of the user's settings.toml too.
- Never modify the user's real settings.toml (%APPDATA%\typo\settings.toml); point
  `TYPO_SETTINGS` at a scratch file (with `[lsp.<name>] path = ...` entries for servers).
- Real language servers on the dev machine: clangd and gopls on PATH; ols, rust-analyzer,
  ty, ruff, pyright, basedpyright in Zed's folders (%LOCALAPPDATA%\Zed\languages\<name>\...,
  ols in Zed\extensions\work\odin\ols-dev-*\). On another machine, check what's
  installed. ols takes about 4 s to initialize on typo's source.

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
- `--test` and `--perf` first build `build/fake_lsp` (src/lsp/fake_server): a language
  server that keeps the documents it is sent ("fake/text" returns its copy), answers
  hover, reports "FIXME" as a diagnostic, lists lines "name :: ..." (with indented
  "name := ..." inside) as symbols and a word's places in its documents as
  references, completes every word of its documents (plus "fake_snippet", a snippet,
  and "fake_import", with an edit at the top), resolves items with documentation,
  gives "name(a, b, c)" as signature help in "name(", renames a word in its documents
  and in the small files of its root folder with the same extension that aren't open,
  sends workspace/applyEdit (each "FIXME" to "FIXED") on "fake/apply", takes `--utf16`,
  and exits on "fake/crash";
  `--copy-to <path>` copies the program there (the perf suite's install command).
  The lsp tests, the app's lsp_test and the perf suite's language server phase use it.
- Patched dependencies (patches made with `git diff` in `build/deps/<name>`; `build.py`
  rebuilds the library when its patch changes):
  - `patches/sdl_ttf.patch`: glyphs at quarter-pixel positions, with text measured
    the way it is drawn (`Glyph_Pixel_X`); `TTF_SetFontHinting` actually enabling
    subpixel rendering (upstream never stored it); `TTF_SetFontCoverageTable`, which
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
  wake-ups and display scale changes are ignored), runs scripted phases (startup, text in cells and subpixels, read back
  from the window, parsing, typing, scrolling, resizing,
  rendered Markdown, huge files, finder, find in files and the terminal, moving lines,
  settings window, context menu and dialogs, terminal, panes, idle CPU/GPU) and exits
  non-zero if a check fails or a result exceeds its limit. Phases drive the UI by
  setting `g.mouse_pos`, `g.mouse_pressed`, `g.right_pressed` and sending keys through
  `handle_key_event`; a synthetic key has no scancode, which chords match on, so
  shortcuts are run with `run_command`. Figures are affected
  by other load; rerun once before investigating a result just over. A feature with a
  per-frame or per-keystroke cost gets a phase or result; a UI behavior gets a check.
- `TYPO_SETTINGS` points typo at another settings.toml (the perf suite uses a temp one);
  session.json is written beside it.

## Architecture

Packages import downward only: `editor` (src/) -> `mdview` -> `textedit` -> `gfx`, with
`markdown`, `buffer` and `syntax` below them (gfx uses syntax for theme colors). For
language servers, `editor` -> `langs` -> `lsp`: `lsp` imports only core and `buffer`
(its copies of documents); `langs` (the app's servers, documents, problems and
requests, no UI) imports `lsp`, `textedit`, `buffer` and `toml`, and reaches the app
only through `langs.env`, set in lsp.odin. `fuzzy` (the fzy-style scorer) stands
alone.

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
- **Markdown files** also have `Editor.md` (`markdown.Doc`) and `Editor.md_view`
  (`mdview.View`: points at the editor's textedit.View and the doc, holds the rendered
  state). `mdview.attach` connects them; `mdview.set_mode` switches the view's kind.
  mdview reaches app state (settings, pointer, frame, workspace files, opening a file)
  only through `mdview.env`, set in `md_env.odin`.
- **Edits** go through `textedit.apply` (every selection, one undo step), or
  `textedit.apply_edits` (separate ranges with the selections they leave, or the
  selections moved through them; one undo step: completions, rename). Consumers take
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
- **Find** (find.odin, find_term.odin): one bar (`g.find`), on one pane at a time, at
  its top right. In an editor the buffer is searched a slice per frame
  (`FIND_PLAIN_BYTES`, less with a regex), so huge files stay responsive; matches go
  to `View.marks`, which both kinds draw behind the text, and the current match is
  the selection. Case folding is ASCII only (offsets stay put). In a terminal,
  libghostty's search does the work (scrollback included, kept in step with output);
  it only ignores ASCII case, so the option buttons are off there, and "next" goes up
  toward older output. While typing in the field it takes the keys first
  (`find_handle_event`); editing commands don't reach the pane behind it.
- **Moving lines** (`textedit.move_lines`): each block of lines the selections cover
  swaps with its neighbor line, keeping the line break between them, as one undo step.
- **Carets** and the terminal cursor don't blink. A press shows the caret at once; it
  hides only while a selection drag has moved (`Editor.drag_moved`).
- **Terminal** (terminal*.odin, term/): on Windows the shell runs in ConPTY, which keeps
  its own copy of the screen, and the two must stay row for row the same or the shell
  draws on the wrong row. So on resize ghostty doesn't pull scrollback down (growing
  adds blank rows at the bottom) and its reflow trims trailing spaces
  (`term.session_init`, patches/ghostty.patch). The grid is resized only once panes
  stop animating.
- **Language servers** (lsp/, langs/, lsp*.odin): `lsp` knows servers, JSON-RPC and
  protocol types, not editors. Nothing about a server runs on the UI thread: each
  `lsp.Client` has its own thread (lsp/worker.odin) that starts the process, does the
  handshake, encodes and parses all JSON, writes the log, and keeps a copy of each
  open document's text (a `buffer.Buffer`, edited with `replace_untracked`) to convert
  between byte offsets and the server's lines and UTF-8/UTF-16 columns. The UI thread
  queues commands (`client_open`, `client_change` with byte-offset `lsp.Edit`s,
  `request` at an offset) and takes decoded events with `lsp.client_poll`
  (`Diagnostics` as sorted byte ranges, `Response` with `Hover` or `[]Place`), each
  tagged with the document version its offsets are in. The process has reader,
  writer and stderr threads (`lsp.Connection`). PATH searches and project roots are
  looked up on another thread (`lsp.Lookups`; `langs.server_path`, `langs.root` return
  "not known yet" and `langs.frame` attaches files when answers come). The servers are
  `lsp.SERVERS` merged with settings.toml's `[lsp.<name>]` tables (`langs.Server_Override`,
  langs/config.odin; `build_server_list`). A table's `path` points at the program (run
  with the command's arguments), else the command's first word is looked up on PATH.
  Defaults are the popular servers; alternatives (ty, basedpyright, marksman) are in
  the table, off. `langs` keeps the app's side in `langs.state`: a file's document
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
  ends them with typo. `langs.timed` marks the UI thread's share, which the perf suite
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
  they replace. Install (`lsp_install`) opens a terminal whose shell runs the server's
  install command and stays open (`panes_run_in_terminal`, `shell_running`); the program
  is looked for again as output comes (`watch_installs`), and once found the server
  starts. settings.toml is written on a saver thread (`settings_save_later`).
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
- **The finder** (finder.odin) lists a `Finder_Source`: the workspace's files
  (Ctrl+E), or a server's `Finder_Item`s (lsp_symbols.odin): a file's outline
  (Ctrl+Shift+O, the caret's symbol selected), the project's symbols (Ctrl+T, asked
  again once the query rests `WORKSPACE_SYMBOLS_DELAY`, the earlier request
  cancelled), or places (Shift+F12 references, several definitions) with their
  lines. The client's thread decodes the answer (`[]lsp.Symbol`, `[]lsp.Place` with
  `preview`, files that aren't open read there), sorts an outline into the file's
  order and references by file (the asked one first); the items take the answer's
  strings over. Every source is filtered locally with `fuzzy.score`, incrementally,
  and only the rows in view are laid out. Accepting goes through `jump_to`.
- **Completion and signature help** (lsp_completion.odin): `lsp_typed` (from
  `editor_text_input`) marks completions due: once identifier typing rests
  `COMPLETION_DELAY` (not on a number, nor in a comment or string by the highlighter),
  at once on a trigger character, or on Trigger completion (Ctrl+Space). Requests go out
  in `lsp_completion_frame`, which runs after `panes_frame` so the frame's edits reached
  the server first. The client's thread decodes items (`lsp.Completion`: what each
  replaces as offsets, snippets reduced to plain text with what to select, other edits);
  the list takes them over and filters them against the word before the caret
  (`fuzzy.score`, then the server's sort text), asking again when the list was
  incomplete. While the list shows, `lsp_completion_handle_key` takes Up/Down/Page
  Up/Down/Enter/Tab/Esc. Inserting (`accept_completion`) moves the item's range by what
  was typed since it was asked, uses the same span at every caret, adds its other edits
  (e.g. an import) and makes them one undo step with `textedit.apply_edits`. The chosen
  item is resolved for its documentation. Signature help (Ctrl+Shift+Space, or a
  signature trigger character) is asked again while it shows and the caret moves or the
  text changes; a null answer closes it. Both close when their editor loses the keys.
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
  settings.odin      Settings model: SETTINGS table, TOML load/save (saver thread), file
                     watcher
  settings_ui.odin   Settings window from SETTINGS, sections collapsible (kept in
                     collapsed_sections); theme/font picker docked at the side
  settings_servers.odin  Language servers in the settings window: rows, a server's page,
                     Add/Remove, Install
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
  finder.odin        The finder: files (Ctrl+E: background indexer, incremental
                     search) or a server's symbols and places; rows in view only
  find*.odin         Find in a pane (Ctrl+F): the bar, searching editors (plain, whole
                     word, case, regex), libghostty search in terminals
  workspace.odin     Lazy file tree, folder dialog
  session.odin       The session (folder, window, panes and layout) saved on exit to
                     session.json and reopened when started with no arguments
  fs_walk*.odin      Recursive file listing
  lsp.odin           Language servers in the app: langs.env, responses by feature, F8,
                     installs, go to definition, the jump list
  lsp_symbols.odin   Symbols and references in the finder: asking, answers as items
  lsp_completion.odin  Completion (list under the caret, filtering, inserting) and
                     signature help (above the caret)
  lsp_rename.odin    Renaming a symbol: prepareRename, the field over the name
  lsp_edits.odin     Workspace edits: open files in their editors, other files after a
                     dialog on a writer thread, answering workspace/applyEdit
  lsp_hover.odin     Hover: pointer resting, the popup, simple Markdown rendering
  lsp_status.odin    The status bar item (language + state dot) and its popup: restart,
                     stop, disable, log; turn on, install (in a terminal), locate a
                     server's program (file dialog, saved as its path) or turn off
                     a server not found
  perf*.odin         Perf suite and CPU/GPU counters
  *_test.odin        App tests (editor_test, md_view_test: a Markdown file in the editor,
                     panes_test: the split tree, find_test: searching an editor)
src/gfx/             Drawing: draw.odin (primitives on gfx.renderer, clips, overlays),
                     text.odin (gfx.text_system, font ids, measurement, contrast),
                     fonts.odin (bundled IBM Plex, Instrument Sans, installed-font scan), theme.odin
                     (THEMES, gfx.theme), geometry.odin (Rect), icon.odin
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
src/buffer/          Piece table (treap), newline index, undo, change log
src/syntax/          Highlighter: tree-sitter (Odin, TOML), line lexer (others)
src/term/            libghostty-vt bindings, Session (vt + pty + reader thread)
src/langs/           The app's language servers, no UI: config.odin ([lsp.<name>]
                     tables, the merged server list), clients.odin (state, env, the
                     clients, restarts, lookups, the frame, timed), docs.odin (documents
                     on their servers: open, change, save, close), problems.odin
                     (published, shifted by edits, counted), requests.odin (which
                     client, matching responses)
src/lsp/             LSP client: registry.odin (LANGUAGES, SERVERS, roots), client.odin
                     (the UI thread's side: commands, events), worker.odin (the
                     client's thread: handshake, documents, JSON, progress, log),
                     connection.odin (process threads), lookup.odin (PATH and root
                     lookups thread), edits.odin (workspace edits as byte ranges,
                     rewriting a file), changes.odin (a frame's changes as edits;
                     shifting and merging problems), rpc.odin (framing), protocol.odin
                     (capabilities, params, Feature), position.odin (columns, offsets
                     in a document, file URIs), process_*/exec_* (spawning, PATH
                     search); fake_server/ for tests
src/fuzzy/           fzy-style scorer (files, symbols, completions)
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
- **Clipping changes layout**: Clay doesn't compress a clipping element's children
  along the clipped axis and grows its Grow children to their content. A Grow page
  directly in a clipping panel is as tall as its rows, so a list in it never scrolls
  and has no bar. Size what a clipping panel holds to the panel (`modal_at`'s pages
  are fixed; their lists are Grow inside them).
- **Scrolling**: use `update_scroll_containers`, not `clay.UpdateScrollContainers`. The
  wheel goes to the topmost list registered with `wheel_scroll_list` (`list_scrollbar`
  does that), not to any clipping element.
- **Stacking** (floating zIndex): panes 2-3, popups (`modal`, finder, settings) 100,
  scroll bar thumbs 110, hover popup 115, completion list, signature and rename field
  116, context menu and language server popup 120, dialog 150, tooltips 300.

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
- Fonts: three configurable families. The interface uses `.Body`/`.SemiBold`/`.Bold`
  (`ui_font`, default Instrument Sans Medium; set by `apply_ui_font`, which has Clay's
  measurements reset next frame); editor and terminal use `.Editor`/`.Editor_Bold`
  (set by `apply_editor_font`); rendered Markdown the `Md_*` ids
  (`apply_markdown_font`). Bundled faces are picked by weight. Column width:
  `editor_char_width` (includes letter spacing, whole device pixels: the editor
  font's faces are laid out in cells, `gfx.CELL_FONTS`); row height:
  `editor_line_height`. Text antialiasing (`gfx.Antialiasing`): subpixel (LCD)
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
  Install, which runs its install command in a terminal (no managed downloads);
  popular servers on by default (pyright + ruff for Python), alternatives off (ty,
  basedpyright, marksman). The user uses ty, ols and rust-analyzer.
- **LSP gaps** (candidates for next):
  - Rendered Markdown doesn't draw `View.problems` or provide `char_at`/`char_rect`,
    so hover, completion, signature help and the rename field don't show there.
  - Rename has no preview; a WorkspaceEdit that creates, renames or deletes files is
    refused (no resourceOperations); change annotations are ignored.
  - Snippets select only the first tabstop (Tab doesn't move on); commit characters
    aren't used.
  - Completion closes when any caret leaves the word (multi-caret); re-filtering a
    long list isn't inside `langs.timed`; a crash isn't noticed while a child of the
    server still holds its stdout.
  - Still on the UI thread: reading settings.toml when it changes on disk, reading a
    file when it opens, copying a document's text for `client_open` (~0.1 ms per
    400 KB).
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
