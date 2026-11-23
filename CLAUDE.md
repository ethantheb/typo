# typo

A code editor in Odin: SDL3 + SDL_ttf (window, text), Clay (layout), tree-sitter plus a
fallback lexer (highlighting), libghostty-vt (terminal), a Language Server Protocol
client (src/lsp), and Git through libgit2 and the git command line (src/git).
Developed on Windows.

## How to work

- **The UI thread does only UI.** Anything that waits, parses, spawns, searches, walks
  files, writes logs or does file IO runs on another thread and hands over finished
  results, even if each is "only a few ms". Give such features a perf limit on their
  UI-thread share per frame (a thread-local `uitime.Share` its procs start with
  `uitime.timed`, read by perf.odin like `langs.ui_share` and `lsp_limit`), not just
  frame time.
- **Edit source with the Edit/Write tools**, not shell or Python scripts, so the style
  hook (`.claude/hooks/check_style.py`) runs. If it doesn't report back, run it on the
  files after a batch of edits.
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

### Testing the running app

- The user usually has their own typo open. Launch test instances with
  `Start-Process -PassThru` and target only that PID (screenshots, Stop-Process).
- Synthetic keys (SendKeys) and posted mouse messages don't reach SDL. Show states
  through launch arguments (`typo -t <folder>`, `typo <file>`), a project's
  `.typo/session.json` (it can restore a Git pane) or perf phases. From a shell inside
  typo (`TYPO_IPC` set), `typo <file>` opens in that window: add `--new`.
- Screenshots: user32 `PrintWindow(hwnd, dc, 2)` on the test window's handle, bitmap
  sized from `GetWindowRect`, not `CopyFromScreen` (it grabs whatever is on top).
  Check new UI with a copy of the user's settings.toml too.
- Never modify the user's real settings.toml (%APPDATA%\typo\settings.toml); point
  `TYPO_SETTINGS` at a scratch file (with `[lsp.<name>] path = ...` entries for servers).
- herdr-core (`hc`, %LOCALAPPDATA%\Programs\herdr-core) runs the user's own agents:
  never stop, restart or update their core, touch terminals you didn't start, or run
  hc from your own shell without a private `HC_SESSION` (it starts their core with
  your environment if it is down). Experiments and tests use a private session
  (`herdr.sandbox_begin`: `HC_SESSION` and scratch `XDG_STATE_HOME`/`XDG_CONFIG_HOME`),
  stopped at the end. The user's settings use `[terminal] backend = "herdr"`: a test
  instance on a copy of them sets `backend = "local"`, or it opens terminals in their
  core.
- Real language servers on the dev machine: clangd and gopls on PATH; ols, rust-analyzer,
  ty, ruff, pyright, basedpyright in Zed's folders (%LOCALAPPDATA%\Zed\languages\<name>\...,
  ols in Zed\extensions\work\odin\ols-dev-*\). ols takes about 4 s to initialize on
  typo's source.

## Build and test

```
python build.py            debug build -> build/typo.exe
python build.py --run      build and launch
python build.py --release  optimized build
python build.py --install  release build, copied to %LOCALAPPDATA%\Programs\typo
python build.py --test     unit tests for every package (TEST_PACKAGES), then the perf suite
python build.py --perf     perf suite only
odin check src -vet-unused -vet-unused-imports    quick type check (after one build.py run)
```

- `build.py` builds the dependencies as static libraries (tree-sitter with clang,
  libghostty-vt with a pinned Zig, SDL3/SDL3_ttf and libgit2 with CMake) and fetches the
  ConPTY files `src/term/pty_windows.odin` embeds. Fonts and the icon (`assets/`) are
  embedded: the executable is the only runtime file.
- libgit2 (`LIBGIT2_VERSION`; bindings for what typo uses and its license in
  vendor/libgit2) is built with nothing that reaches the network (the git command line
  pushes, pulls and fetches) and its bundled zlib, regex and http parser, as a build
  type of its own (`Optimized`): MSVC's Release flags include /GL, which makes every
  link redo link-time code generation.
- `--test` and `--perf` first build `build/fake_lsp`, a language server for tests
  (src/lsp/fake_server; its header lists what it answers and its flags), used by the
  lsp tests, the app's lsp_test and the perf suite's language server phase.
- Patched dependencies (patches made with `git diff` in `build/deps/<name>`; `build.py`
  rebuilds the library when its patch changes; keep `patches/*.patch` LF):
  - `patches/sdl_ttf.patch`: glyphs at quarter-pixel positions with text measured as
    it is drawn (`Glyph_Pixel_X`); `TTF_SetFontHinting` really enabling subpixel
    rendering and `TTF_SetFontSubpixelPositioning` working whatever the hinting
    (`gfx.glyph_fit`: the editor font light-hinted, other fonts unhinted, as FreeType's
    hinter can close a bold i's dot onto its stem); `TTF_SetFontCoverageTable` (per-font
    gamma and contrast); glyph images exactly the box they are stretched over
    (`Glyph_Padding`); `TTF_SetFontCellAdvance` (whole-cell advances for the editor
    font); `TTF_SetFontLCD` (FreeType's LCD rendering, `TTF_IMAGE_LCD`, drawn in two
    passes with custom blend modes, `target * (1 - coverage) + color * coverage` per
    channel, overlapping glyphs in separate layers, `LCDLayerFor`), queued and drawn by
    `TTF_FlushRendererText`, which `gfx.flush_text` calls before anything else is
    drawn, a clip changes or the frame is presented. Renderers without the blend modes
    get grayscale text (`renderer_has_lcd_blend`).
  - `patches/ghostty.patch`: when scrollback isn't pulled on resize (set on Windows),
    reflow also trims trailing spaces, as ConPTY does (see Terminal).
- libghostty-vt is a pinned release (`GHOSTTY_VERSION`, Zig `ZIG_VERSION`) built from
  source with the patch. `GHOSTTY_PATCH = False` uses the release as it is (on Windows
  x64 its prebuilt library, linked with `-linker:lld` as MSVC's link.exe rejects its
  MinGW objects); `-define:GHOSTTY_PATCHED` lets tests that need the patch skip.
  `test_abi_matches_manifest` checks the bindings against the library's manifest: run
  it after changing the version.
- Markdown spec suite (`src/markdown/spec_test.odin`): CommonMark and GFM examples.
  `testdata/spec_failures.txt` lists known failures with reasons; any other failure, or
  a listed example passing, fails it. `-define:SPEC_WRITE=true` rewrites the list,
  `-define:SPEC_DETAILS=n` prints n failures.
- Perf suite (`src/perf.odin`, `PHASES`; bigger phases in perf_*.odin): an optimized
  build that opens a real window (unfocused, behind the others; events other than quit,
  wake-ups and display scale changes are ignored), runs scripted phases and exits
  non-zero if a check fails or a result exceeds its limit. Phases drive the UI by
  setting `g.mouse_pos`, `g.mouse_pressed`, `g.right_pressed`, other mouse buttons
  through `mouse_button_event` and keys through `handle_key_event`. Chords match on
  the scancode: run a shortcut with `run_command`, or `press_chord` when the key path
  is what is tested. `want_frame` reads back what a frame showed (into
  `Perf.read_back` for the next step). Every phase checks Clay reported no error and
  no frame drew `CLIP_LIMIT` clipping elements. A feature with a per-frame or
  per-keystroke cost gets a result; a UI behavior gets a check.
- `TYPO_SETTINGS` points typo at another settings.toml (the perf suite uses a temp one);
  state.json (the project to reopen) is kept beside it. Tests and perf phases use temp
  folders as projects.

## Architecture

Packages import downward only: `editor` (src/) -> `mdview` -> `textedit` -> `gfx`, with
`markdown`, `buffer` and `syntax` below them (gfx uses syntax for theme colors). For
language servers, `editor` -> `langs` -> `lsp`: `lsp` imports only core, `buffer` and
`process`; `langs` (the app's servers, documents, problems and requests, no UI) imports
`lsp`, `textedit`, `buffer`, `toml` and `uitime`, and reaches the app only through
`langs.env` (lsp.odin). `git` imports `process`, `trash` and vendor/libgit2; `herdr`
imports `process` and `uitime`; `term` imports `herdr`; `words` imports `buffer` and
`textedit`. `process`, `fuzzy`, `ipc`, `diff`, `trash` and `uitime` stand alone.

- **Views and kinds.** The editor shows its document through a `textedit.View`
  (buffer, selections, scroll, bounds) whose `kind` (`textedit.Kind`, a table of procs)
  decides drawing, hit testing, scrolling, caret movement, keys, typing, clipboard and
  the mouse: `TEXT_KIND` (text_view.odin), `mdview.KIND`, or `AREA_KIND` (text_area.odin,
  the Git pane's message box). App code calls the kind and never branches on which it
  is; a new view (e.g. CSV) is a new `Kind` with its state in `View.kind_data`. What
  every view shares (`move`, `key`, undo, multi-cursor, `copy_text`/`paste`) is in
  textedit.
- **Scrolling sideways.** A kind's `sideways` gives how far its view scrolls and which
  part does; the editor clamps to it and draws a bar there (every scroll bar shares
  gfx/scrollbar.odin). TEXT_KIND scrolls as far as the widest line it has shown
  (`Widest_Line`), so a huge file costs no more than a small one. Rendered Markdown
  fits the pane; its code blocks scroll on their own (mdview/code.odin).
- **Selections** are one padded, rounded shape each (`gfx.fill_selection`,
  `gfx.selection_look`). Both kinds draw what goes behind the text, then the
  selections, then the text.
- **Markdown files** also have `Editor.md` (`markdown.Doc`) and `Editor.md_view`
  (`mdview.View`), connected by `mdview.attach`; `mdview.set_mode` switches the kind.
  mdview reaches app state only through `mdview.env` (md_env.odin).
- **Edits** go through `textedit.apply` (every selection, one undo step) or
  `textedit.apply_edits` (separate ranges, one undo step: completions, rename,
  reverts). Consumers take them once per frame with `textedit.take_changes`, which runs
  `View.on_edit` (highlighter, Markdown parse, caches). Never call
  `buffer.take_changes` elsewhere: it drains them. `buffer.version` counts changes.
- **Snapshots** (buffer/snapshot.odin): a buffer's bytes never move (the file as
  loaded, plus add blocks that double in size, no piece spanning two, in a
  reference-counted `Store_Memory`). `buffer.snapshot` copies the piece list and takes
  a reference, so any thread can read the text as it was while the UI thread edits,
  even after the buffer is destroyed; its holder calls `snapshot_release`. Work on a
  document's text off the UI thread takes one: a server's open, the reload diff, the
  word index, a save.
- **Opening and saving** (file_io.odin, file_load.odin): nothing waits on the disk on
  the UI thread. `editor_open` leaves the editor `.Loading` and queues a `Load_Job` for
  `LOAD_THREADS` loader threads, which read (`read_file_shared`), check for binary,
  hash, and build the buffer and highlighter (`syntax.highlighter_open` runs on any
  thread). `file_load_frame` takes the results (tagged with `Load_State.id`; stale ones
  are freed) and `load_landed` wires them up, then applies the editor's `When_Ready`
  (a jump's target, a heading, the session's caret and scroll): whatever needs a
  file's text goes through `editor_when_ready`. A loading pane is drawn empty, then
  says "Loading…" after `EDITOR_SHOW_WAIT`; keys and commands wait (`status != .Text`),
  Close works. A file over the `ask_above_mb` setting asks first (`Opening_Large`;
  Cancel puts back the file it replaced, `Load_State.replaced`); files over
  `LARGE_FILE_BYTES` aren't sent to language servers. `editor_save` queues a snapshot
  as a `Write_Job` for one writer thread (writes land in order): temp file + rename,
  hashing what it wrote and telling the watcher (`watch_file_synced`); `save_landed`
  marks that text saved (`buffer.end_save`: edits since keep it modified). The writer
  also patches a file no editor has open (`Patch_Job`, only if unchanged) and deletes
  (`Delete_Job`: to the trash, or permanently once confirmed). The unsaved-changes flow
  waits for writes (`unsaved_frame`); `io_destroy` finishes queued writes. Without the
  threads (unit tests) a job runs at once on the calling thread.
- **Panes** (panes.odin): each open file (`^Editor`), terminal (`^Terminal`), the Git
  pane (`^Git_View`) or a diff (`^Diff_View`) is a `Pane` in `g.panes.open`. Shown panes
  are the leaves of a split tree (`Tile`) filling `work_rect()`; terminals not shown
  wait on the shelf. Every pane floats at its leaf's rect, attached to the root
  (`work_rect` is in the window's coordinates), so changes to the tree only move and
  resize panes, animated, never reparented. Every change of place is a `Drop`
  (`drop_apply`, also run on a copy of the tree for the drag preview); a pane leaving
  fades out as an empty frame (`Leaving`). A pane clips what it holds: its header and
  body are laid out at least their minimum width (`PANE_HEADER_MIN`, `pane_body_min`)
  and at most the pane's; while they are built (`g.in_pane`) `ui_interactive` refuses
  the pointer outside the pane or under the maximized one. Keys go to
  `g.panes.focused`, always a pane in view (`pane_focus` restores a maximized pane
  covering it); `pane_fill` says whether a pane is beside others, maximized or alone
  (the only pane shown is never maximized). Files from the tree or the finder open in
  place of the editor in use (`place_for`; the one replaced closes unless it has
  unsaved changes); files from the command line, `typo <file>` or a server's log open
  beside it (`panes_open_file_beside`). Element ids carry `Pane.id`; tree rows are keyed
  by path (`tree_row_id`), so a press matched against last frame's layout finds the
  same file after a re-sort. Whatever holds a `^Pane` is cleared in `pane_close`.
- **Window frame** (window_frame*.odin, `CUSTOM_FRAME`, on for Windows): SDL's
  borderless window, which on Windows keeps the caption and sizing styles, so snapping,
  animations, rounded corners and the system menu stay native. typo draws a caption
  strip (`TITLE_BAR_HEIGHT`, "TitleBar") above "Main": the sidebar's header over the
  sidebar's column, and minimize, maximize and close (`Caption_Glyph`, drawn as
  shapes); `work_rect` starts below it (`frame_top`). A subclass of SDL's window
  procedure answers the hit test (`window_frame_hit`: edges resize; the strip and the
  window's background drag, `BACKGROUND_IDS` naming the elements whose empty space
  counts; the maximize button is the system's, for Snap Layouts, so its pointer comes
  as system messages), draws each new size during the system's size loop, sets DWM's
  border to the theme's and keeps an auto-hide taskbar reachable when maximized. The
  system takes a press that drags, so typo never sees it: while something is open that
  a press outside closes (`closes_on_press_outside`: menus, popups, the finder, a
  rename; not a dialog) the background is typo's and only the strip drags. Caption
  buttons act next frame (`window_frame_frame`). Elsewhere, or if the platform side
  can't set up, the system's frame stays.
- **Sidebar** (sidebar.odin): the window's background at its left edge, flat on the
  window's color and always laid out; the panes are the only raised elements. Top to
  bottom: the folder's name (in the caption strip with typo's frame; a press shows the
  recent projects), the search field, the tree, RECENT and the shelf. Toggle sidebar
  only moves `work_rect`'s left edge: the panes ease over the sidebar while it fades
  into the window (`sidebar_fade`, an overlay transitioned with the panes; its floating
  part, the search field's clear button, takes it too), and hiding it drops a rename
  in it. "WorkArea" (`work_area`: floating under the panes, easing as they do) marks
  what covers it: the sidebar's own pointer checks go through `pointer_on_sidebar`, and
  `ui_interactive` refuses while building it (`g.in_sidebar`) elsewhere. RECENT
  (sidebar_recent.odin, `recent_rows`): the project's pinned files, then its recent
  ones up to the `recent_files` setting; rows act as tree rows, a right-click on one or
  on a file in the tree pins or unpins (`project_pin`), and it isn't laid out while
  empty. The tree marks open files with unsaved changes, and every folder they are in,
  with a dot (`unsaved_marks`).
- **Sidebar search** (sidebar.odin, `g.sidebar_search`): a field above the tree that
  opens a popup as a browser's address bar does. Find file (Ctrl+E) or a press on the
  field opens it (`sidebar_search_open`) while the sidebar shows, else Find file opens
  the finder. The popup (`sidebar_search_popup`, floating on "SidebarSearchSlot" at the
  popups' layer) grows out of the field over the panes, with the field at its top where
  it was, and lists the finder's index scored by its own `Search` (stepped in
  `sidebar_frame` within `SEARCH_BUDGET`), open and recent files first, as the finder
  does. It covers what is under it (`search_popup_covers_pointer`, `g.in_search_popup`).
  Enter or a click opens through `Open_File`; opening or Escape empties and closes it
  (`sidebar_search_close`); a press outside, hiding the sidebar, another shortcut or the
  finder opening closes it and keeps the query.
- **Zoom** (zoom.odin): each pane's text has its own size, a step of
  `textedit.ZOOM_LEVELS` (`textedit.View.zoom`, `Terminal.zoom`); the interface doesn't
  zoom. The metrics take it: `editor_font_size(zoom)`, `editor_char_width(zoom)`,
  `editor_line_height(zoom)` (a text view's row: `text_line_height(v)`); mdview scales
  `mdview.Config`'s sizes by `textedit.zoom`. `textedit.set_zoom` keeps the kind's
  anchor (`Kind.anchor`) in place. A file opened in place of another takes its zoom.
- **Find** (find.odin, find_term.odin): one bar (`g.find`) on one pane at a time. In an
  editor the buffer is searched a slice per frame (`FIND_PLAIN_BYTES`, less with a
  regex) into `View.marks`, the current match being the selection; case folding is
  ASCII only. In a terminal, libghostty's search does the work (ASCII case only, so
  the option buttons are off; "next" goes toward older output). The field has the keys
  (`find_has_keys`) after Find or a press on it, until a press elsewhere or another
  pane is focused; while it has them it takes them first (`find_handle_event`) and
  `PANE_EDIT_COMMANDS` don't reach the pane. Find and F3 from another pane move the bar
  there. It covers what is under it (`find_bar_covers_pointer`, `g.in_find_bar`).
- **Go to line** (goto_line.odin, Ctrl+G): a bar (`g.goto_line`) at the top of the
  focused editor taking "line" or "line:column" (`goto_parse`, `goto_offset`). Typing
  previews (`View.center` + `reveal`), Enter jumps through `jump_to` (so Go back
  returns), Esc, a press outside, another shortcut or pane puts caret and scroll back.
  It takes the keys before the find bar and covers what is under it
  (`goto_line_covers_pointer`, `g.in_goto_bar`). Lines are the document's, in rendered
  Markdown too.
- **Text fields** (line_edit.odin): every single-line input is a `Line_Edit` drawn by
  `text_field`. Its owner decides focus (before calling, so the focusing press places
  the caret) and handles Enter, Esc, Tab and Up/Down; `line_edit_event` does editing
  keys and `FIELD_COMMANDS` (select all, clipboard, undo), so they never reach a pane.
  `text_field` takes the mouse and keeps the caret in view; positions come from
  `gfx.text_caret_x`/`text_caret_at`. Multi-line: `Text_Area` (text_area.odin, on
  `AREA_KIND`), growing to `TEXT_AREA_MAX_LINES`, its text as far from the box's sides
  as its capitals are from the top.
- **Carets** and the terminal cursor don't blink. A press shows the caret at once; it
  hides only while a selection drag has moved (`Editor.drag_moved`).
- **Changes on disk** (fs_watch*.odin, file_sync.odin): a watcher thread waits on the
  workspace folder (ReadDirectoryChangesW; elsewhere a 2 s walk) and polls open files
  outside it. Events outside `FINDER_IGNORED_DIRS` gather into a burst handed over once
  quiet (`WATCH_QUIET`, at most `WATCH_MAX_DELAY`); the thread lists the burst's loaded
  folders and the tree takes them in place (`workspace_apply_listings`), marking the
  finder's index stale. Open files are registered with the hash and stamp of the text
  typo last read or wrote (`watch_file_open`, `watch_file_synced`), so typo's own
  writes aren't changes, and `.typo/session.json` saves are ignored (`watch_ignored`).
  A changed file is read once it holds still (`WATCH_STABLE`): without unsaved edits it
  reloads as one undo step from a diff against a snapshot (`reload_apply`), with them a
  dialog asks; saving over a version typo hasn't read asks first (`save_or_ask`). A
  deleted file stays open, unsaved (`Disk_State.missing`). Three things poll where the
  watcher can't: open files outside the workspace, the config thread's settings files
  (`CONFIG_POLL_MS`) and the Git worker's repository files (`git.POLL`).
- **Terminal** (terminal*.odin, term/): a `term.Session` is libghostty-vt plus a
  `Backend`: `Local` (a pty and its reader thread) or `Remote` (a herdr-core terminal
  through a `herdr.Stream`); only session.odin's backend procs differ. On Windows a
  local shell runs in ConPTY, which keeps its own copy of the screen, and the two must
  stay row for row the same or the shell draws on the wrong row: on resize ghostty
  doesn't pull scrollback down and its reflow trims trailing spaces (`pty_semantics`,
  the ghostty patch). A herdr terminal resizes the same way (herdr-core passes on its
  ConPTY's output); only the repaint after an attach comes from herdr-core's own
  terminal, so after resizes while detached it can differ until the shell redraws.
  The grid is resized only once panes stop animating.
- **Persistent terminals** (terminal_persist*.odin, herdr/, docs/terminal_persistence.md):
  the `terminal.backend` setting ("local" or "herdr") picks where new terminals run; a
  terminal keeps its backend (`Terminal.persistent`). The UI calls them pinned: their
  icon has an accent pin (`pane_badge`, `gfx.Icon_Badge`); a terminal's menu has Pin or
  Unpin, which restarts it in the other mode (`terminal_ask_repin`), and right-click on
  the shelf's + or the status bar's terminal button picks what new terminals are
  (`persist_set_wanted`). One `herdr.Client` per typo (`persist_init`): its reader
  thread finds hc and, once needed, starts `hc connect` (herdr/hc.odin: detached, no
  window, outside typo's job objects), speaks framed JSON-RPC and subscribes to
  terminals labeled `typo=1`, reconnecting with a backoff; a writer thread sends queued
  commands. The UI thread only queues and takes (`herdr.ui_share`). A terminal starts
  with `keep`, `outlive_parent`, labels `typo=1` and `typo.project=<root>`, typo's shell
  identity (`term.shell_identity`) and `TYPO_IPC` with the project's name. An attach is
  a full repaint (`herdr.DEFAULT_HISTORY` lines), done again after a reconnect, a
  `restarted` event or a `size` event. Quitting and leaving the project detach; closing
  a pane kills its herdr terminal (`terminal_destroy`). The session keeps each one's
  address and core; a restored one attaches when first shown (`persist_restore`), and
  one that ended meanwhile shows its last screen with an "exited" line. Without hc, new
  terminals start locally and say so.
- **Running programs** (terminal_programs.odin, term/processes_*.odin): closing a
  terminal whose shell is alive, quitting or opening another folder (local shells only)
  asks first if a program runs in it, as a step of the unsaved-changes flow
  (`Unsaved_Flow.programs`). `term.programs_under` (a Toolhelp snapshot of the shell's
  descendants, on a thread per check, `Programs_Check`) finds them from
  `term.session_pid`. Not looked up on Unix yet.
- **Box drawing and blocks** (gfx/box_glyphs.odin): box drawing, block elements,
  Powerline separators and Symbols for Legacy Computing (`gfx.is_box_glyph`) are drawn
  as shapes filling the exact cell, so they join across cells and rows: Windows
  Terminal's built-in glyphs (MIT; box_glyphs_table.odin), rasterized once per cell
  size into an atlas and drawn a row at a time (`gfx.Box_Batch`). The terminal and the
  text view draw them this way; rendered Markdown doesn't.
- **Language servers** (lsp/, langs/, lsp*.odin): `lsp` knows servers, JSON-RPC and
  protocol types, not editors. Each `lsp.Client` has its own thread (lsp/worker.odin)
  that starts the process, does the handshake, encodes and parses all JSON, writes the
  log, and keeps a copy of each open document (a `buffer.Buffer`) to convert byte
  offsets to the server's lines and UTF-8/UTF-16 columns. The UI thread queues commands
  (`client_open` with a snapshot, `client_change` with byte-offset `lsp.Edit`s,
  `request`) and takes decoded events (`lsp.client_poll`), each tagged with the
  document version its offsets are in. PATH searches and project roots are looked up
  on another thread (`lsp.Lookups`). The servers are `lsp.SERVERS` merged with
  settings.toml's `[lsp.<name>]` tables (langs/config.odin): a table's `path` points at
  the program, else the command's first word is looked up on PATH. A file's document
  (`Editor.lsp`, a `langs.Doc`) attaches to every enabled, installed server of its
  language (one `langs.Client` per server and project root); requests go to the first
  that supports them. Edits go out from `editor_on_edit` (`lsp.edits_for_changes`). A
  crashed server restarts (3 times in 3 minutes); a stopped or replaced client
  "retires" (its thread shuts the server down). A settings change replaces only the
  clients whose server changed (`Client.server_key`, `langs.reattach_all`). On Windows
  servers start without a console window and live in a job object that ends them with
  typo. The app answers `langs.env` (open documents, `doc_closing`, `client_gone`,
  `lsp_response`).
- **Language servers in the settings** (settings_servers.odin): every server with its
  state, Install/Locate… when its program isn't found and an On/Off switch; its page
  edits its `[lsp.<name>]` table, with Restart, Log, Reset or Remove. Changes are
  queued (`Server_Op`) and applied next frame, as this frame's render commands may use
  the strings they replace.
- **Installing servers** (lsp/install.odin): a server has several install commands
  (`Server_Spec.install`, or a table's `install`). Only commands whose program is found
  on PATH are offered, ordered by `lsp.INSTALLERS` weights (uv/pipx, pip, npm, then
  system package managers, rustup, go, cargo last). Install runs the lightest in a
  terminal that stays open (`panes_run_in_terminal`), and the server starts once its
  program is found (`watch_installs`). With none found, a "Needs uv, npm or pip" line
  shows instead.
- **Language features** (langs/requests.odin, langs/problems.odin, lsp.odin,
  lsp_hover.odin): a request goes to the first running client that can do it
  (`langs.client_with`, `lsp.Feature`); a response read against other text than the
  buffer's, or from a client that restarted since, is dropped. Diagnostics are per
  document and client, shifted through the edits since the text they are about, and
  underlined through `View.problems`. Hover needs the kind's `char_at` and `char_rect`.
  Go to definition (F12, Ctrl+click, the editor menu) opens through `g.pending` with
  `g.open_target`; every jump records into `g.jumps` (Go back/forward); jumps and F8
  center a place out of view (`View.center` + `reveal`). The editor's right-click menu
  is context_menu.odin.
- **Completion and signature help** (lsp_completion.odin): `lsp_typed` marks
  completions due once typing rests `COMPLETION_DELAY` (not in a number, comment or
  string), at once on a trigger character, or on Ctrl+Space; requests go out in
  `lsp_completion_frame`, after `panes_frame`, so the frame's edits reached the server
  first. Items (`lsp.Completion`, snippets reduced to plain text) are filtered against
  the word before the caret (`fuzzy.score`, then sort text); an incomplete list is
  asked again whenever the buffer is past its version (`answered`). Inserting
  (`accept_completion`) shifts the item's range by what was typed since, applies it at
  every caret with its other edits as one undo step. Signature help (Ctrl+Shift+Space
  or a trigger character) follows the caret; both close when their editor loses the
  keys.
- **Word completions** (word_completion.odin, words/), as Zed has them: the settings'
  `words` ("fallback", "enabled", "disabled"), `words_min_length`,
  `lsp_fetch_timeout_ms` and `words_in_text_files`. The words thread (`words.Indexer`)
  collects a window of the file's words around the caret (`words.Index`) from a
  snapshot when the editor gets the keys, once typing rests `WORDS_DELAY`, or when the
  caret nears an end of what was read. The list opens with words when no server
  completes, its answer is empty or an error, or it is late (`server_time_limit`); a
  later answer replaces them unless a row was chosen with the keys (`navigated`).
  `words_ui` is the UI thread's share (`words_limit`).
- **Rename and workspace edits** (lsp_rename.odin, lsp_edits.odin, lsp/edits.odin): F2
  renames the symbol at the caret when the server can, else the pane. The answer is
  read on the client's thread as byte ranges per file (`lsp.File_Edit`);
  `lsp_apply_workspace_edit` refuses it if an open file changed since, edits open files
  in their editors (left unsaved), and asks before a writer thread rewrites files that
  aren't open (`lsp.write_file_edit`, only if unchanged). A server's workspace/applyEdit
  goes the same way.
- **`typo <file>` in typo's terminals** (ipc/, ipc_open.odin): each typo listens on its
  own endpoint (`ipc.Server`): a named pipe with a DACL for the current user only (the
  default lets everyone read), else a 0600 Unix socket in a 0700 folder. Only its
  terminals' shells get it, as `TYPO_IPC` (`ipc_shell_env`); a new typo unsets an
  inherited one, as it does Claude Code's session markers (`AGENT_SESSION_ENV`, main.odin).
  There `typo <files>` (`forward_to_window`, before SDL starts) sends absolute paths and
  prints the reply (`attach_console`); a folder, `--new`/`-n`, `-t` or an endpoint that
  doesn't answer start a new window. Messages are versioned, length-prefixed frames
  (ipc/message.odin), validated on both sides; each file opens in a new pane beside the
  editor in use (`panes_open_file_beside`), the last focused and the window raised.
  Persistent shells outlive their typo, so their `TYPO_IPC` is the project's name
  (`ipc.project_name`): each window lists its endpoint under the project it shows
  (ipc/projects.odin, a file per process in %LOCALAPPDATA%\typo\ipc\<hash> or a private
  runtime folder), tried newest first.
- **The finder** (finder.odin) lists a `Finder_Source`: the workspace's files (Ctrl+E
  with the sidebar hidden), or a server's `Finder_Item`s (lsp_symbols.odin): a file's
  outline (Ctrl+Shift+O), the project's symbols (Ctrl+T, asked again once the query
  rests `WORKSPACE_SYMBOLS_DELAY`) or places (Shift+F12 references, several
  definitions), decoded and sorted on the client's thread. Every source is filtered
  locally and incrementally (`Search`, `search_step` within `SEARCH_BUDGET`), and only
  rows in view are laid out. Open files and recent ones come first, as in VS Code and
  Zed (`Search.ranked`; with a query `FINDER_BOOST`); with no query the focused file
  isn't listed, so Enter switches.
- **Recent projects** (project_picker.odin, `g.project_picker`): state.json keeps the
  projects opened (`state_project_opened`, at most `RECENT_PROJECTS_MAX`). Open project
  (Ctrl+R) or a press on the folder's name shows them, filtered as typed, under the name
  while it shows, else at the window's top (`project_picker_covers_pointer`,
  `g.in_project_picker`). Enter or a click opens one here (`Open_Folder`); Ctrl+Enter
  or a row's window button in another window (`Open_Window`, `launch_window`). Its last
  row, Open folder…, shows the system's folder dialog.
- **Recent files** (recent.odin, `g.recent`): the project's files whose panes were
  focused, most recent first (`recent_touch` from `pane_focus`, at most
  `RECENT_MAX_FILES`), kept in session.json; files the finder's index lost are dropped
  on leaving (`recent_drop_missing`).
- **Projects** (project.odin, `g.project`): the folder open is the project, its data in
  `.typo/` as Zed's `.zed/`: `.typo/settings.toml` (its settings layer and `[project]
  pinned`) and `.typo/session.json` (its last state), made only when there is something
  to write, with a `.gitignore` holding `session.json` so the settings can be shared.
  `project_open` has the config thread read both; until they land the pending Action
  waits and the window stays hidden at startup. Then the layer applies and, with
  `restore_session`, the session is restored. Leaving (`project_leave`, after the
  unsaved-changes flow) saves its state and closes every pane (local shells end,
  persistent ones go on). It is also saved as it goes (`session_save_frame`: at most
  every `SESSION_CHECK`, written if it changed). A folder opened for a lone file isn't
  a project unless it has `.typo/`. Paths in the files go through
  `project_rel`/`project_abs`. state.json (`App_State`) keeps what isn't per project.
- **Settings layers** (settings.odin): `Settings` holds the values in effect (`using
  values: Setting_Values`, read as `g.settings.x`), the user's (`user`, settings.toml)
  and the project's (`project: Setting_Layer`); `settings_resolve` works out the first.
  Keybindings, servers' tables, `terminal.commands` and `user_only` settings are the
  user's only; a project file setting one gets a problem. Files are parsed anywhere
  (`settings_parse`) and taken in on the UI thread (`settings_take_user`/`_project`).
  `settings_changed` saves settings.toml, `project_settings_changed` the project's
  file. The settings window's User/Project switch picks the layer shown and changed
  (`shown_values`, `edit_values`).
- **Config thread** (config_io.odin): settings files, projects' files and state.json are
  read and written on one thread, in order; results land in `config_frame`. A timer on
  SDL's timer thread polls the watched files and queues a read when one changed, not
  after typo's own writes. Without the thread (unit tests) a job runs at once.
- **Keybindings in the settings** (settings_ui.odin): a command's bindings (up to
  `MAX_CHORDS`) are chips; Add records one (a key or a side button), taking it from the
  command that had it (`bindings_add`, `bind_note`); Reset puts the defaults back.
  Enter on the row adds, ←→ move between the row and its chips, Delete or Backspace
  removes a chip, Delete on the row resets. A terminal toggle at the row's right says
  whether the command works while a terminal has focus (`Settings.terminal_commands`,
  `DEFAULT_TERMINAL_COMMANDS`); other chords go to the shell. `EDITOR_COMMANDS` have no
  toggle.
- **Git** (git/, git_state.odin): libgit2 does reads and the index in-process
  (git/repo.odin: status by `git.Area`, branch, upstream and ahead/behind, file versions
  as checked out, staging, unstaging, discarding, untracked files to the trash,
  `splice_index` for a hunk); the git command line commits (`--file=-`, so hooks and
  signing work), pushes, pulls and fetches (git/cli.odin: no console window,
  `GIT_TERMINAL_PROMPT=0`). `git.Worker` owns the repository for writes on its thread,
  takes requests in order, follows each change with a fresh status and hands events
  over (`worker_take`); commands run one at a time on a thread of their own. Events
  from before a folder change are dropped (they carry the folder generation). The
  status follows the watcher's bursts (`git_workspace_changed`) and the worker's poll of
  the repository's files (`git.POLL`), so a commit in a terminal shows up; refreshes
  are never closer together than the last one took. A failed push, pull or fetch shows
  git's words in a dialog that can rerun it in a terminal. `git_ui` is the UI thread's
  share (`git_limit`).
- **Git pane** (git_pane.odin, `Git_View`, one at most): the upstream and an operation
  under way beside its title (`git_title_note`); a commit message box (Ctrl+Enter
  commits), Commit (its key in the tooltip) and push, pull and fetch; the files in
  collapsible sections with stage/unstage/discard buttons on hover (discard asks
  first). Rows aren't stored: `row_at` finds one from the sections' sizes. Keys:
  Up/Down, Enter (diff or collapse), Space (stage or unstage), Delete (discard),
  Tab/Esc into and out of the box. Ctrl+Shift+G or the status bar's branch item opens
  it left of the editor in use.
- **Diff view** (diff_view.odin, diff_load.odin, diff/rows.odin): a file's versions side
  by side: changes (index | work tree), staged (HEAD | index), untracked, conflict (HEAD
  | work tree); the work tree side is the open editor's text when open. The loader
  thread reads both, diffs by lines (line endings don't count), finds changed words and
  builds each side's buffer and highlighter; a job that would change nothing
  (`Diff_Signature`) costs nothing. Rows aren't stored (`diff.row_at`). Each hunk's
  buttons between the sides revert it (in the open editor, one undo step; else a
  `Patch_Job`), stage it (`git_splice_index`) or, staged, unstage it. A view reloads on
  every new status and once an open editor's edits rest `DIFF_EDIT_DELAY`. Git and diff
  panes close when they leave the layout (no shelf); the session keeps both.

### A frame (`app_iterate`, main.odin)

1. Apply what other threads handed over (`config_frame`, `file_load_frame`,
   `file_sync_frame`, `git_frame`, `diff_views_frame`, ...) and the pending `Action`,
   update focus, run `finder_frame` and `panes_frame` (drags, then each pane's frame),
   which read last frame's layout (`element_rect`, `pointer_in`) and handle the mouse.
2. `build_ui` (layout.odin) declares the Clay tree; editors and terminals are custom
   elements drawn by `draw_editor`/`draw_terminal`.
3. `render_clay_commands`, present, `free_all(context.temp_allocator)`.

- Nothing shows half ready: a new file isn't drawn (`Editor.shown`) until it has loaded
  and has real bounds (or `EDITOR_SHOW_WAIT` passed), and the window starts hidden until
  the first ready frame (`panes_ready`).
- The loop sleeps when idle: `needs_continuous_frames` lists what keeps it awake; other
  threads call `wake_main_loop`.
- Strings used by a frame's render commands must outlive its drawing: per-frame strings
  use the temp allocator, and actions that change the panes are deferred via
  `g.pending` (`defer_action`). A click found while declaring a list that would free or
  replace what the list shows is only recorded, and applied before the next frame's
  panes (`clicked`, `chosen`).

## Layout

```
src/                 package editor: the app
  main.odin          App state (global `g`), SDL callbacks, frame loop, deferred actions
  keymap.odin        Commands, default bindings, chords (keys or mouse side buttons)
  settings*.odin     Settings model and files; the settings window; its servers section
  config_io.odin     The config thread
  project.odin       The project and its .typo folder; session.odin its saved state
  layout.odin        Window layout: caption strip, "Main" (sidebar, panes), status bar
  window_frame*.odin typo's caption strip, the system's hit test and size loop
  ui.odin            Widgets, hit tests (clicked, pointer_in), transition, tooltips
  render.odin        Clay render commands -> gfx calls; text measurement
  scrollbar.odin     Scroll bars, list_scrollbar, wheel routing
  sidebar*.odin      The sidebar, its search popup and RECENT
  panes.odin         Panes: split tree, shelf, drops, dragging, pane UI, focus
  editor*.odin       Editor state, keys and commands; its per-frame update and drawing
  text_view.odin     TEXT_KIND
  md_env.odin        mdview.env
  terminal*.odin     Terminals: session, rows, drawing, input, persistence, programs
  dialog.odin        In-app dialogs, the unsaved-changes flow
  context_menu.odin  Right-click menus
  rename.odin        Renaming in place, naming new files
  line_edit.odin     Single-line text fields; text_area.odin multi-line
  fs_*.odin          File operations (to the trash), listing, the watcher thread
  file_*.odin        Loader and writer threads; opening and saving; changes on disk
  finder.odin        The finder; find*.odin find in a pane; goto_line.odin go to line
  workspace.odin     Lazy file tree, folder dialog
  recent.odin        Recent files; project_picker.odin recent projects
  ipc_open.odin      `typo <file>` from typo's terminals, both sides
  lsp*.odin          Language servers in the app: responses, symbols, completion,
                     rename, workspace edits, hover, the status bar item
  word_completion.odin  Each editor's words for completion
  zoom.odin          Zoom per pane
  git_*.odin         Git in the app, the Git pane; diff_*.odin the diff pane, its loader
  perf*.odin         Perf suite (phases in PHASES)
  *_test.odin        App tests, named after what they cover
src/gfx/             Drawing: primitives, clips, overlays, selections, scroll bars, text
                     and fonts (bundled IBM Plex, Instrument Sans, Lucide icons), themes,
                     icons, box glyphs
src/textedit/        Editing core: View, Kind, selections, apply, undo, multi-cursor
src/mdview/          Rendered Markdown: kind, layout, tables, code blocks, drawing,
                     editing keys, links and images, per-line heights
src/markdown/        Incremental parser, inlines, HTML (spec suite), text view colors
src/buffer/          Piece table (treap), stores that never move, undo, snapshots
src/syntax/          Highlighter: tree-sitter (Odin, TOML), line lexer (others)
src/term/            libghostty-vt bindings, Session and backends, programs under a shell
src/herdr/           herdr-core client: framing, protocol, client threads, hc, sandboxes
                     (private sessions for tests; they set HC_SESSION process-wide)
src/langs/           The app's language servers, no UI
src/lsp/             LSP client: registry (LANGUAGES, SERVERS), installs, the client's
                     thread, connections, lookups, edits, positions; fake_server/
src/git/             Repository (libgit2), worker thread, git command line
src/process/         Child processes without a console window, job objects, PATH lookups
src/ipc/             A typo's endpoint: messages, server, named pipe/socket, projects
src/diff/            Line diffs (Myers), side-by-side rows, changed words
src/fuzzy/ words/ toml/ trash/ uitime/   Scorer; document words; TOML reader; the
                     system's trash from any thread; a feature's UI-thread share
vendor/              clay-odin, tree-sitter* (do not edit); sdl3 bindings pointed at the
                     static libraries; libgit2 bindings and license
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
- **Fades**: `overlayColor` applies to everything inside, editor and terminal included,
  but not to floating children (Clay emits them as their own roots): give those the
  same overlay and transition.
- **Clipping changes layout**: Clay doesn't compress a clipping element's children
  along the clipped axis and grows its Grow children to their content, so a Grow list
  directly in a clipping panel never scrolls. Size what a clipping panel holds to the
  panel (`modal_at`'s pages are fixed; their lists are Grow inside them).
- **Clipping elements are few**: Clay's store of clip and scroll containers holds about
  100 (a changed list's old ones linger a frame); past that it fails with "out of
  bounds array access". Lists lay out only the rows in view, and a row clips its text
  through `row_clip()`, which stops clipping past `ROW_CLIP_BUDGET` a frame
  (`g.frame_clips` counts them).
- **Scrolling**: use `update_scroll_containers`, not `clay.UpdateScrollContainers`. The
  wheel goes to the topmost list registered with `wheel_scroll_list` (`list_scrollbar`
  does that), not to any clipping element.
- **Stacking** (floating zIndex): the sidebar and caption strip in the base layout,
  "WorkArea" and leaving panes 1, panes 2 (maximized 4: `pane_layer`), find bar 5, go
  to line 6, popups (`modal`, finder, settings, sidebar search, recent projects) 100
  (`POPUP_LAYER`), hover 115, completion, signature and rename field 116, context menu
  and status bar popups 120, dialog 150, tooltips 300. A list's scroll bar thumb floats
  one above the layer of what holds the list.

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
  Ctrl+click only, and the selection grows on release to cover hidden syntax.
- Syntax is hidden except where a selection touches it (a line's block markers, a
  span's inline markers, a whole fence), and the caret line's whitespace is shown, so
  the caret is never in hidden text and typed text is always drawn. Exception:
  indentation Markdown treats as syntax; the caret is drawn where the text starts.
- Tables stay rendered; `textedit.normalize` runs the kind's `snap`
  (`mdview.snap_carets`), keeping carets in cells. Tables fill the column and wrap, or
  widen via their header button (`State.wide_tables`). Dragging across cells selects a
  rectangle, one selection per row (`cell_drag`); typing, deleting, cutting or pasting
  over cells empties them and keeps the pipes (`replace_cells`). `<br>` breaks a cell's
  line and moves as one character. Cells are byte ranges of a row (`Table_Cell`): keep
  table code on them so a CSV view can reuse it.
- List numbers hang left of the item text; each digit takes a cell as wide as the
  font's widest digit, so numbers line up on their dot in any font (`add_marker`).
- While the mouse is down, reveal state is frozen (`hold_reveal`) so text doesn't move
  under a drag; on release the selection grows to what copying takes (`snap_selection`).
- Caches (`begin_caches`): per document (inlines, tables, code blocks, code highlights)
  and per document + selections + column width (line layouts). A new pane width only
  refits tables. Lines have their own heights in a `Height_Map`.

## Code style

Code should read like the author's own: airy, one idea per line, grouped into steps.
New and changed code follows this; existing code is brought in line when touched. The
style hook checks the width and `do` rules after every Edit/Write of a file in src/.

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
  `line_edit_event` (any text input), `modal` + `clicked_outside`, `dialog_show` (never
  a blocking native box), `resolve_unsaved` before closing files, `textedit.line_span`,
  `textedit.next_col`, `set_string`, `list_scrollbar` (with `SCROLLBAR_GUTTER` right
  padding and the layer of what holds the list), `list_reveal_row`, `list_row` (sidebar
  rows), `gfx.draw_caret`, `scroll_ease_step`, `WHEEL_LINES` and `WHEEL_COLUMNS`.
- New setting: a `Setting` value, a `Setting_Values` field, a `SETTINGS` entry, a
  `setting_value` case; `user_only` if a project can't set it. Long-list string
  settings set `picker = true` and fill `picker_options`; related number settings go
  in `picker_extras`. Code reads the values in effect (`g.settings.x`); a change goes
  to a layer (`g.settings.user`, or the settings window's `edit_values`), then
  `settings_changed` or `project_settings_changed`.
- New command: a `Command` value, a `COMMANDS` entry, a case in `run_command` or
  `editor_run_command`. A chord may name a mouse side button (`MOUSE_BUTTONS`); its
  press runs the command next frame on the pane under the pointer (`button_chord_frame`).
- Tooltips (`tooltip`, right after their element, with the command's key as its
  shortcut) appear where the pointer rested. Keys are shown in tooltips, not in the
  controls themselves.
- Pointer input goes through `ui_interactive` (via `clicked`, pane frame procs,
  tooltips); a new popup that blocks all or part of the window belongs there, and in
  `closes_on_press_outside` if a press outside closes it. While the dialog or context
  menu is open only their own UI (built with `g.in_popup`) reacts.
- A file or folder name typed by the user goes through `rename_path`/`create_path`,
  which refuse names the OS can't use; deleting goes through `ask_delete_file`.
- Reading a file the user works on goes through `read_file_shared` (never blocks other
  programs), off the UI thread; opening one in an editor through `editor_open`, then
  `editor_when_ready`; writing one an editor shows through `editor_save`. Perf phases
  and tests that use a file's text at once open it with
  `open_loaded`/`editor_wait_loaded`, and wait for saves with `wait_for_saves`.
- Fonts: three configurable families. The interface uses `.Body`/`.SemiBold`/`.Bold`
  (`ui_font`, default Instrument Sans Medium, `apply_ui_font`); editor and terminal
  `.Editor`/`.Editor_Bold` (`apply_editor_font`); rendered Markdown the `Md_*` ids
  (`apply_markdown_font`). Column width `editor_char_width` (whole device pixels: the
  editor font is laid out in cells, `gfx.CELL_FONTS`), row height `editor_line_height`.
  A caret's place in proportional text: `gfx.text_caret_x`/`text_caret_at`
  (`gfx.text_width` is the inked extent); `gfx.font_metrics` has the cap height for
  optical alignment. Text is subpixel (LCD) below 2x scale with ClearType, else
  grayscale; drawing anything but text outside gfx calls `gfx.flush_text` first.
- Temp allocator for per-frame data; free owned data (tests use the tracking allocator).
- `@(private = "file")` for single-file helpers, `@(private)` for package internals.

## Planned directions

The architecture should allow these without rewrites:

- **Theming**: user themes from TOML would add `gfx.Theme_Spec` entries to `gfx.THEMES`.
  UI colors come only from `gfx.theme`.
- **LSP features**: each is an `lsp.Feature` (`lsp.has_feature`), asked with
  `langs.send_request`, its result decoded on the client's thread (`answer_ui` in
  lsp/worker.odin, offsets converted there) and handled from `lsp_response`.
  `syntax.Highlight` is per byte, so semantic tokens can overlay it. Features stay
  generic: driven by capabilities, nothing coded per language.
- **LSP decisions (the user's)**: servers come from `lsp.SERVERS` plus `[lsp.<name>]`
  tables in settings.toml (no separate languages.toml); pointing typo at a program
  (`path`) is preferred over searching other editors' folders; a missing server gets
  Install, which runs an install command in a terminal (no managed downloads), lightest
  installer on PATH first; install commands in the table are only ones verified to
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
    long list isn't timed in `langs.ui_share`; a crash isn't noticed while a child of
    the server still holds its stdout.
  - Still on the UI thread: a file's stat before saving (`changed_since_read`).
  - A program installed where PATH only reaches in new processes isn't found until
    typo restarts (Locate… covers it). Workspace settings and initialization options
    are only edited in settings.toml.
  - Wire request ids count from 1 and stay in i32: servers on Rust's lsp-server (ty)
    read them as 32-bit (the fake server ignores larger ids to catch this).
- **Settings mini LSP**: hover help and diagnostics for settings.toml, built on the
  SETTINGS/COMMANDS tables, are planned; that's why `settings_save` writes no comments.
- **One file in several panes**: `textedit.View` still holds the document (buf, path)
  with the view state, and `Editor` holds the rest of the document (hl, Markdown doc)
  plus per-view state. TEXT_KIND finds its Editor with `container_of` and `md_view`
  points into it, so an Editor must not move. Next: separate the document from its
  views, each with its own kind state, `mdview.View` and pane.
- **CSV view**: a new `textedit.Kind` in an editor pane. The table cell code
  (`Table_Cell`, cell lookup, rectangle drag, `replace_cells`) is private to mdview and
  reads the Markdown doc; move it to a shared place, over a source of rows, first.
- **Several windows** (dragging panes between them): typo has one window, with one
  `g`, renderer, text system and Clay context. Several would need per-window state
  (renderer, gfx caches and atlas, Clay context, panes and layout, focus) split from
  what the process shares (settings, language servers, documents). Keep new
  window-wide state in `g` grouped so it can move into a per-window struct.
- **Window frame elsewhere**: `window_frame_hit` is platform-free; Linux and macOS
  could use it through SDL's `SetWindowHitTest` (macOS likely keeping its own buttons).
