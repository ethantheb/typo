package syntax

import "core:path/filepath"
import "core:strings"

import "../buffer"

// Syntax highlighting with two interchangeable backends:
//  - Tree_Sitter: a real incremental parser for languages with a grammar, used
//    for files up to TREE_SITTER_MAX_BYTES.
//  - Lexer: a line-based tokenizer that only looks at what is on screen (plus
//    sparse state checkpoints), so it works at any file size.
// Both produce one Highlight per byte of a requested range, so the renderer
// doesn't care which one ran (and LSP semantic tokens could overlay either).

Highlight :: enum u8 {
	None,
	Comment,
	Keyword,
	String,
	Escape,
	Number,
	Constant,
	Type,
	Function,
	Variable_Builtin,
	Parameter,
	Property,
	Namespace,
	Operator,
	Punctuation,
	Attribute,
	Label,
}

Language :: enum u8 {
	None,
	Odin,
	C,
	Cpp,
	JavaScript,
	TypeScript,
	Rust,
	Go,
	Java,
	CSharp,
	Python,
	Toml,
}

// Tree-sitter re-parses synchronously after each edit, which grows with file
// size; larger files use the lexer to keep frames short.
TREE_SITTER_MAX_BYTES :: 512 << 10

Backend :: enum u8 {
	None,
	Tree_Sitter,
	Lexer,
}

Highlighter :: struct {
	lang:    Language,
	backend: Backend,
	ts:      TS_State,
	lx:      Lexer_State,
}

language_for_path :: proc(path: string) -> Language {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	switch ext {
	case ".odin":
		return .Odin
	case ".c", ".h":
		return .C
	case ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx":
		return .Cpp
	case ".js", ".mjs", ".cjs", ".jsx":
		return .JavaScript
	case ".ts", ".tsx":
		return .TypeScript
	case ".rs":
		return .Rust
	case ".go":
		return .Go
	case ".java":
		return .Java
	case ".cs":
		return .CSharp
	case ".py", ".pyw", ".pyi":
		return .Python
	case ".toml":
		return .Toml
	}
	return .None
}

@(private = "file")
LANGUAGE_ALIASES := [?]struct {
	name: string,
	lang: Language,
} {
	{"javascript", .JavaScript}, {"typescript", .TypeScript}, {"rust", .Rust}, {"golang", .Go},
	{"python", .Python}, {"csharp", .CSharp}, {"c#", .CSharp}, {"c++", .Cpp},
}

// The language named by a code fence's info string: a name ("python") or an
// extension ("py").
language_for_name :: proc(name: string) -> Language {
	if name == "" do return .None
	for a in LANGUAGE_ALIASES do if strings.equal_fold(name, a.name) do return a.lang
	return language_for_path(strings.concatenate({".", name}, context.temp_allocator))
}

highlighter_open :: proc(h: ^Highlighter, b: ^buffer.Buffer, path: string) {
	highlighter_close(h)
	h.lang = language_for_path(path)
	if h.lang == .None do return

	if buffer.length(b) <= TREE_SITTER_MAX_BYTES && ts_open(&h.ts, b, h.lang) {
		h.backend = .Tree_Sitter
	} else {
		lexer_open(&h.lx, h.lang)
		h.backend = .Lexer
	}
}

highlighter_close :: proc(h: ^Highlighter) {
	switch h.backend {
	case .Tree_Sitter: ts_close(&h.ts)
	case .Lexer:       lexer_close(&h.lx)
	case .None:
	}
	h^ = {}
}

// Applies the buffer's edits since the last call (buffer.take_changes) and
// continues background work. Call once per frame before drawing.
highlighter_update :: proc(h: ^Highlighter, b: ^buffer.Buffer, changes: []buffer.Change) {
	switch h.backend {
	case .Tree_Sitter:
		if len(changes) > 0 do ts_edit(&h.ts, b, changes)
	case .Lexer:
		lexer_edit(&h.lx, changes)
		lexer_catch_up(&h.lx, b)
	case .None:
	}
}

// Whether the highlighter still has background work (lexer checkpoints to
// rebuild after an edit) and wants more frames to do it in.
highlighter_busy :: proc(h: ^Highlighter, b: ^buffer.Buffer) -> bool {
	return h.backend == .Lexer && lexer_behind(&h.lx, b)
}

// Fills out[i] with the highlight of byte start+i, for [start, start+len(out)).
highlight_range :: proc(h: ^Highlighter, b: ^buffer.Buffer, start: int, out: []Highlight) {
	for &x in out do x = .None
	if len(out) == 0 do return
	switch h.backend {
	case .Tree_Sitter: ts_highlight(&h.ts, b, start, out)
	case .Lexer:       lexer_highlight(&h.lx, b, start, out)
	case .None:
	}
}

// Maps a tree-sitter capture name to a Highlight using the longest known
// dotted prefix ("function.call" -> Function). Includes the older
// nvim-treesitter names that grammar queries still use. ok=false means the
// capture should not paint anything (e.g. @spell).
highlight_for_capture :: proc(name: string) -> (hl: Highlight, ok: bool) {
	name := name
	for {
		switch name {
		case "comment":                                return .Comment, true
		case "keyword", "conditional", "repeat", "include", "storageclass", "preproc", "exception":
			return .Keyword, true
		case "keyword.operator":                       return .Keyword, true
		case "string", "character":                    return .String, true
		case "string.escape", "escape":                return .Escape, true
		case "number", "float":                        return .Number, true
		case "boolean", "constant", "constant.builtin": return .Constant, true
		case "type", "type.builtin":                   return .Type, true
		case "function", "method", "constructor":      return .Function, true
		case "function.macro":                         return .Constant, true
		case "variable.builtin":                       return .Variable_Builtin, true
		case "variable":                               return .None, true
		case "parameter", "variable.parameter":        return .Parameter, true
		case "field", "property", "variable.member":   return .Property, true
		case "namespace", "module":                    return .Namespace, true
		case "operator":                               return .Operator, true
		case "punctuation":                            return .Punctuation, true
		case "attribute":                              return .Attribute, true
		case "label":                                  return .Label, true
		}
		dot := strings.last_index_byte(name, '.')
		if dot < 0 do return .None, false
		name = name[:dot]
	}
}
