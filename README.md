### Typo

Experimental text editor written in Odin,
using Clay for UI layout, rendered with SDL3.

The goal is a fast and lightweight IDE that
also prioritizes the terminal experience. Small single
executable, low memory footprint, instantaneous startup,
Obsidian-like MD rendering, etc. 

Currently supported:
- Open folders as projects, open files
- Window panes and splits
- Edit text files, search within files, go to line, multicursor
- Syntax highlighting (tree-sitter/custom lexer)
- Integrated terminal (libghostty-vt), optional persistence (herdr-core)
- Markdown live rendering/editing
- Git integration (libgit2 + git CLI), diff viewer
- LSP (goto definition, rename symbol, etc)

Might try soon:
- Tabular data rendering (CSV)

#### AI Acknowledgement
This project is sort of a personal test in LLM dev,
and an attempt at doing something different (Odin/Clay/SDL3),
with a strong focus on performance testing. It's mostly
developed using AI and really shouldn't be used at this point.

#### But hey, go ahead and install it if you want
Developed on Windows only currently.
It may be buildable on Linux/MacOS, try it at your own risk. Let me know how it goes.

```
python build.py --install
```
