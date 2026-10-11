package syntax

// Lexer rules per language. These are the fallback used for huge files and for
// languages without a tree-sitter grammar, so they aim for "obviously right"
// rather than complete: keywords, literal types, comments, strings, numbers.

Lang_Rules :: struct {
	keywords:        []string,
	types:           []string,
	constants:       []string,
	builtins:        []string, // e.g. self, this
	line_comment:    string,   // "//", "#", or "" for none
	block_comments:  bool,     // /* ... */
	nested_comments: bool, // /* /* */ */ nests (Odin, Rust)
	char_quote:      bool, // '...' is a string/char literal
	raw_quote:       u8,   // quote that starts a multi-line raw string, or 0
	triple_quotes:   bool, // triple-quoted strings (Python)
	directives:      bool, // #name is a directive (Odin #partial, C #include)
	directive_hl:    Highlight,
	attributes:      bool, // @name is an attribute
}

@(private = "file")
odin_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords        = {
		"package", "import", "foreign", "proc", "struct", "enum", "union", "bit_set", "bit_field", "map", "matrix",
		"dynamic", "distinct", "using", "defer", "return", "or_return", "or_else", "or_break", "or_continue",
		"if", "else", "when", "for", "in", "not_in", "do", "switch", "case", "fallthrough", "break", "continue",
		"where", "cast", "transmute", "auto_cast", "context", "size_of", "align_of", "offset_of", "type_of",
		"typeid_of", "type_info_of",
	},
	types           = {
		"bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32",
		"u64", "u128", "uintptr", "f16", "f32", "f64", "complex32", "complex64", "complex128", "quaternion64",
		"quaternion128", "quaternion256", "rune", "string", "cstring", "rawptr", "typeid", "any", "byte",
	},
	constants       = {"true", "false", "nil"},
	nested_comments = true,
	char_quote      = true,
	raw_quote       = '`',
	directives      = true,
	directive_hl    = .Attribute,
	attributes      = true,
}

@(private = "file")
c_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords     = {
		"auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if",
		"inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union",
		"volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Generic", "_Noreturn", "_Static_assert",
		"_Thread_local",
		// C++
		"class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override",
		"final", "new", "delete", "this", "operator", "using", "constexpr", "consteval", "noexcept", "try", "catch",
		"throw", "friend", "mutable", "explicit", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast",
		"co_await", "co_return", "co_yield", "concept", "requires", "decltype",
	},
	types        = {
		"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t", "ssize_t",
		"ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
		"uint32_t", "uint64_t", "wchar_t", "auto",
	},
	constants    = {"true", "false", "NULL", "nullptr"},
	char_quote   = true,
	directives   = true,
	directive_hl = .Keyword,
}

@(private = "file")
js_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords   = {
		"break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
		"export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "return",
		"super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "async", "await",
		"of", "static", "get", "set", "from", "as",
		// TypeScript
		"interface", "type", "enum", "implements", "namespace", "declare", "abstract", "readonly", "private",
		"public", "protected", "keyof", "infer", "is", "satisfies",
	},
	types      = {"number", "string", "boolean", "any", "unknown", "never", "object", "symbol", "bigint"},
	constants  = {"true", "false", "null", "undefined", "NaN", "Infinity"},
	char_quote = true,
	raw_quote  = '`',
	attributes = true,
}

@(private = "file")
rust_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords        = {
		"as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for",
		"if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
		"static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
	},
	types           = {
		"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool",
		"char", "str",
	},
	constants       = {"true", "false", "None"},
	nested_comments = true,
	directives      = true,
	directive_hl    = .Attribute,
}

@(private = "file")
go_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords   = {
		"break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
		"goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type",
		"var",
	},
	types      = {
		"bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32",
		"int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any",
	},
	constants  = {"true", "false", "nil", "iota"},
	char_quote = true,
	raw_quote  = '`',
}

@(private = "file")
java_cs_rules := Lang_Rules {
	line_comment    = "//",
	block_comments  = true,
	keywords   = {
		"abstract", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum",
		"extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface",
		"native", "new", "package", "private", "protected", "public", "return", "static", "super", "switch",
		"synchronized", "this", "throw", "throws", "transient", "try", "volatile", "while", "var", "record",
		// C#
		"namespace", "using", "override", "virtual", "readonly", "sealed", "struct", "internal", "async", "await",
		"foreach", "in", "out", "ref", "is", "as", "get", "set", "lock", "base", "delegate", "event", "params",
	},
	types      = {"void", "boolean", "bool", "byte", "char", "short", "int", "long", "float", "double", "string", "object", "decimal"},
	constants  = {"true", "false", "null"},
	char_quote = true,
	attributes = true,
}

@(private = "file")
python_rules := Lang_Rules {
	keywords      = {
		"and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
		"except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
		"pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "type",
	},
	types         = {
		"int", "float", "complex", "str", "bytes", "bytearray", "bool", "list", "dict", "set", "frozenset", "tuple",
		"object", "range", "memoryview",
	},
	constants     = {"True", "False", "None", "NotImplemented", "Ellipsis", "__name__", "__file__"},
	builtins      = {"self", "cls"},
	line_comment  = "#",
	char_quote    = true,
	triple_quotes = true,
	attributes    = true, // @decorators
}

@(private = "file")
plain_rules := Lang_Rules{}

rules_for :: proc(lang: Language) -> ^Lang_Rules {
	switch lang {
	case .Odin:                    return &odin_rules
	case .C, .Cpp:                 return &c_rules
	case .JavaScript, .TypeScript: return &js_rules
	case .Rust:                    return &rust_rules
	case .Go:                      return &go_rules
	case .Java, .CSharp:           return &java_cs_rules
	case .Python:                  return &python_rules
	case .None:
	}
	return &plain_rules
}
