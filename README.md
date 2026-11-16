### Typo

Experimental text editor written in Odin,
using Clay for UI layout, rendered with SDL3.

The goal is a fast and lightweight IDE that
also prioritizes the terminal experience. Small single
executable, low memory footprint, instantaneous startup,
Obsidian-like MD rendering, etc. 

Currently supported:
- Open folders, search files
- Text editing
- Syntax highlighting (tree-sitter/custom lexer)
- Themes
- Integrated terminal (libghostty-vt)
- Window panes and splits
- Markdown live rendering/editing
- LSP (early stages)

Might try soon:
- Tabular data rendering (CSV)
- Terminal persistence (herdr-core or something)

#### AI Acknowledgement
This project is sort of a personal test in LLM dev,
and an attempt at doing something different (Odin/Clay/SDL3),
with a strong focus on performance testing. It's mostly
developed using AI and really shouldn't be used at this point.

#### But hey, go ahead and install it if you want
Developed on Windows only currently.
It may be buildable on Linux/MacOS, no promises.

```
python build.py --install
```
