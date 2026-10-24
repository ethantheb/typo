# typo

A small code editor in Odin: SDL3 + SDL_ttf for the window and text, Clay for layout,
tree-sitter (plus a fallback lexer) for highlighting, libghostty-vt for the integrated
terminal. Mainly developed and tested on Windows.

## Build and test

```
python build.py            debug build -> build/typo.exe
python build.py --run      build and launch
python build.py --release  optimized build
python build.py --test     unit tests for every package, then the performance suite
python build.py --perf     performance suite only
```

`build.py` also builds the dependencies as static libraries (tree-sitter with clang,
libghostty-vt with a pinned Zig, SDL3 and SDL3_ttf with CMake) and on Windows fetches the
ConPTY files that `src/term/pty_windows.odin` embeds. SDL3_ttf gets `patches/sdl_ttf.patch`
(make it with `git diff` in `build/deps/SDL_ttf`): glyphs placed at quarter-pixel
positions by its renderer text engine, and `TTF_SetFontCoverageTable`, through which
text.odin applies gamma and contrast correction to each font (less contrast for
heavier weights, which also get full hinting). The fonts and the window icon
(`assets/icon`, also the Windows executable's icon via `typo.rc`) are embedded too, so the
executable is the only runtime file. Run it once before using `odin` directly. Quick type
check: `odin check src -vet-unused -vet-unused-imports`.

The performance suite (`src/perf.odin`) is an optimized build run as `typo-perf --perf`.
It opens a real window, runs scripted phases (startup, buffer, syntax, Markdown parsing,
fuzzy search, VT parsing, typing, scrolling, rendered Markdown (opening, scrolling,
typing, moving through long tables and code blocks, typed spaces and tabs measured
with the real fonts), huge files, the finder, the settings window and its theme and
font lists, terminal redraws and shell output, idle CPU/GPU), prints a table and
exits non-zero if any result exceeds its limit. It ignores real keyboard and mouse
input. Its CPU and GPU figures are for its own process only, but they are affected by
load from other programs (e.g. other typo instances), so an idle result just over its
limit is worth one rerun before investigating. When adding a feature with a per-frame
or per-keystroke cost, add a phase or result for it.

## Layout

```
src/                 package editor: the app
  main.odin          App state (global `g`), SDL callbacks, frame loop, idle scheduling,
                     deferred actions (open file/folder)
  keymap.odin        Command enum, default bindings, chord parsing, run_command
  settings.odin      Settings model: SETTINGS table, TOML load/save, file watcher
  settings_ui.odin   Settings window, generated from the SETTINGS table; the option list
                     (picker) for the theme (dark/light) and font (with size/spacing
                     controls), which the panel animates into, docked at the side with
                     the rest of the window still usable
  theme.odin         Built-in themes (THEMES, as hex Theme_Spec values)
  fonts.odin         Bundled IBM Plex Mono weights and IBM Plex Sans (rendered Markdown),
                     installed font scan (background thread; monospace families for the
                     editor, all for Markdown), family + weight -> Font_Source
  text.odin          Font ids and their sources, fallback fonts, cached ttf.Text,
                     measurement, glyph gamma and contrast (text_set_contrast)
  renderer_sdl.odin  Clay render commands -> SDL draw calls; draw_text, fill_rect,
                     antialiased rounded shapes, clips, overlay colors
  ui.odin            Widgets: label, button, icon, input_box, text_field_event, tooltip,
                     modal/modal_at, ask (message box), clicked/pointer_in hit tests,
                     transition (Clay transitions), element_at
  scrollbar.odin     Scroll bars: geometry, dragging, look; list_scrollbar for any Clay
                     scroll container (the editor draws its own from the same parts);
                     smooth wheel scrolling (update_scroll_containers, smooth_scroll_list)
  layout.odin        Window layout: sidebar, editor pane, terminal panel and splitter,
                     status bar, focus, mouse cursor
  editor.odin        Editor: open/save, multi-selection, movement, editing, clipboard, keys
  editor_view.odin   Editor per-frame update, mouse, scrolling, scrollbar, drawing
  md_view.odin       Rendered Markdown view: mode toggle, height map, caches, caret
                     movement by visual row, code blocks scrolled sideways, reveal-aware
                     drawing
  md_layout.odin     Rendered Markdown layout: a line's items (shown/hidden bytes,
                     widgets) wrapped into rows of runs; tables; layout cache keys
  md_edit.odin       Rendered Markdown editing keys (md_handle_key): lists and quotes
                     continued by Enter, nested by Tab, indentation deleted by level,
                     numbered lists renumbered
  md_media.odin      Rendered Markdown links (Ctrl+click) and images (decoded on
                     threads with vendor:stb/image, uploaded as textures)
  terminal.odin      Terminal: session lifecycle, row cache, drawing
  terminal_input.odin  Keyboard/mouse -> terminal input
  finder.odin        Ctrl+E file finder (background indexer, incremental search)
  fuzzy.odin         fzy-style fuzzy scorer
  workspace.odin     Lazy file tree, folder dialog
  fs_walk*.odin      Recursive file listing (FindFirstFileW on Windows)
  perf*.odin         Performance suite and its CPU/GPU counters
  editor_test.odin   Unit tests for the main package (md_view_test.odin: rendered Markdown;
                     keys replayed through the key handlers, in scripted sequences and
                     at every caret position of sample documents, checking that the
                     incremental parse matches a full one, the caret is never in hidden
                     text or left of the text column, and what is typed is drawn)
src/buffer/          Piece table in a treap, newline index, undo history, change log
src/syntax/          Highlighter: tree-sitter backend (Odin, TOML) and line lexer (others)
src/markdown/        Markdown (CommonMark + GFM + extras): incremental line-by-line block
                     parser, inline parser, text-view highlighting
src/term/            libghostty-vt bindings, Session (vt + pty + reader thread), ptys
src/toml/            Minimal TOML reader for settings
vendor/              clay-odin, tree-sitter, tree-sitter-odin, tree-sitter-toml (do not edit);
                     sdl3, Odin's SDL3 bindings with foreign imports pointed at the static
                     libraries
ref/clay_docs.md     Clay's README: the reference for its API (layout, scrolling,
                     floating elements, transitions, overlay colors, ...)
```

## Clay

The UI is built on Clay; use what it provides before writing our own. Read
`ref/clay_docs.md` (and the bindings in `vendor/clay-odin/clay.odin`) when building UI:
layout, scroll containers, floating elements, hover/pointer queries and transitions are
all there. In particular:

- **Animation** uses Clay transitions, through `transition()` (ui.odin). An element
  with one eases to its new position, size or colors when its layout changes; children
  are laid out within its animated bounds; `Enter` makes it appear by fading or sliding
  in. Elements with a transition need a fixed id. The handler sets `g.animating`, which
  keeps the frame loop drawing until it finishes.
- **No exit transitions.** Clay keeps drawing an exiting subtree from the frame it was
  last declared in, and that frame's strings and custom data were in the temp allocator.
  To animate something closing (a sidebar, a terminal pane), keep declaring it at its
  closed size until `element_at` says it got there, then drop it.
- **Fades** use Clay overlay colors (`overlayColor`), which the renderer applies to
  everything drawn inside the element, editor and terminal included.
- A clipping element (`clip`) is a Clay scroll container and takes the mouse wheel from
  scroll containers inside it; clip a moving panel only while it moves.
- **Scrolling** goes through `update_scroll_containers` (scrollbar.odin) instead of
  `clay.UpdateScrollContainers`, which eases wheel scrolling for lists registered with
  `smooth_scroll_list` (`list_scrollbar` does that).

## How a frame works

`app_iterate` (main.odin) runs once per frame:

1. Apply the pending `Action`, update focus, then per-pane frame procs
   (`finder_frame`, `terminal_panel_frame`, `editor_frame`). These read last frame's
   layout through `element_rect`/`pointer_in` and handle the mouse.
2. `build_ui` (layout.odin) declares the Clay tree. The editor and terminal are Clay
   custom elements (`custom_element`) that the renderer draws itself
   (`draw_editor`, `draw_terminal`).
3. `render_clay_commands`, present, `free_all(context.temp_allocator)`.

The loop sleeps when nothing changes: `needs_continuous_frames` lists what keeps it
awake, and `schedule_next_frame` sets a timer only for a blinking cursor. Other threads
(pty reader, file indexer, settings watcher, dialogs) call `wake_main_loop`.

Strings referenced by this frame's render commands must stay alive until it is drawn,
which is why opening files and folders goes through `g.pending` (applied next frame),
and why per-frame strings use the temp allocator.

## Markdown

Markdown files have an `Editor.md` (`markdown.Doc`): per-line block info, reparsed
incrementally from `buffer.take_changes` (`doc_edit`, `doc_update`); a line's info
depends only on the previous line's end state, and setext headings and table headers
are found by looking at the next line. Inlines are parsed per block when needed.
The parser follows CommonMark (indented code included) with two deviations for live
editing: a lone list marker followed by a space ("- ", "1. "), or inside a list item,
starts an item, and a single "-" is not a heading underline.

The text view colors it through `markdown.highlight_range`. The rendered view
(`md_rendered`) is the same document and selections drawn by `draw_markdown`: syntax
is hidden except where a selection touches it (a line's block markers, a span's
inline markers, a whole fence or table), and the whitespace of the caret's line is
shown, so a caret is never in hidden text and whatever is typed is drawn. The only
exception is indentation that Markdown treats as syntax (before a marker, the one
space after it, indentation consumed by a container or an indented code block); the
caret is drawn where the text starts. While the mouse button is down, what is
revealed stays as it was before the press (`md_hold_reveal`), so the text doesn't
move under a drag. The first line starts below a margin (`Height_Map.pad`). Code that assumes
one row per line and a fixed column width (scrolling, hit testing, vertical movement)
branches on `md_rendered`. Its caches (`md_begin`) are in two parts: per document
(paragraph inlines, tables, code block extents and widths, code highlights) and per
document and selections (each line's layout). Editing keys take separate paths:
`editor_handle_key` sends the rendered view to `md_handle_key`, and the text view
edits like any other file; only caret movement (`navigation_key`) is shared.

## Conventions

- Comments are short and literal, and describe the current code only: no history,
  benchmarks, rejected alternatives or references to conversations. Skip a comment
  when the code already says it.
- Reuse the shared helpers instead of re-implementing them: `clicked`, `pointer_in`,
  `element_rect`/`rect_contains`, `draw_text`, `fill_rect`, `push_clip_box`,
  `input_box` + `text_field_event`, `modal` + `clicked_outside`, `ask`, `line_span`,
  `next_col`, `set_string`, `list_scrollbar` (give a scrolling list one, with
  `SCROLLBAR_GUTTER` of right padding).
- A new setting is an enum value in `Setting`, a field in `Settings`, a `SETTINGS`
  entry and a `setting_value` case. Loading, saving, reset and the settings window
  follow from those. A string setting chosen from a long list sets `picker = true`
  and lists its options in `picker_options` (settings_ui.odin); number settings that
  should be adjustable alongside it go in `picker_extras`.
- Pointer input goes through `ui_interactive` (via `clicked`, the pane frame procs,
  tooltips), which knows which popups block the window. A new popup that covers the
  window, or leaves parts of it usable, belongs there.
- The UI draws with the bundled fonts (`Font_Id.Body`, ...); the editor and terminal
  with `.Editor`/`.Editor_Bold`, which `apply_editor_font` points at the configured
  family and weight. Column width comes from `editor_char_width` (includes letter
  spacing), row height from `editor_line_height`.
- A new command is a `Command` value, a `COMMANDS` entry and a case in `run_command`
  (or `editor_run_command`).
- Editing goes through `apply` (editor.odin), which handles every selection and records
  one undo step. Consumers of document edits take them with `buffer.take_changes` once
  per frame (see `editor_frame`); `buffer.version` counts changes.
- Use the temp allocator for per-frame data; free owned data explicitly (the tests run
  with Odin's tracking allocator).
- `@(private = "file")` for helpers used in one file.

## Planned directions

The architecture should allow these without rewrites:

- **Animated panes**: the sidebar and terminal panel opening/closing, and later split
  panes and terminal tabs, animate with Clay transitions as described under Clay: give
  the pane a fixed id and a width/height transition, and keep a closing pane declared
  at zero size until `element_at` reports it there.
- **Theming**: themes are `Theme_Spec` entries in `THEMES`, selected by key
  (`theme_by_name`); loading user themes from TOML would add to that list (and to
  `THEME_NAMES`). UI code takes colors only from `theme`.
- **LSP**: `buffer.take_changes` yields byte offsets plus row/column points for each
  edit, and `buffer.version` gives document versions; feed both to the server in
  `editor_frame`. `syntax.Highlight` is per byte, so semantic tokens can overlay it.
- **Split views / multiple files**: `Editor` still combines the document (buf, hl,
  path) with the view (selections, scroll). Splitting those, and giving each view its
  own Clay element id instead of the fixed "EditorText", is the next step.
- **Multiple terminals**: `Terminal` is self-contained (session, row cache, input,
  drawing), and `terminal_frame` takes its element id. `Terminal_Panel` holds one;
  making that a list with tabs is local to layout.odin.
