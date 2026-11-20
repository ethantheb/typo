package lsp

// Languages by file name, and the servers typo knows how to start. Users add
// servers and change these in settings.toml ([lsp.<name>] tables); the app
// merges those over this table

import "core:os"
import "core:path/filepath"
import "core:strings"


Language :: struct {
	id:         string,   // the LSP languageId
	name:       string,   // shown in the settings window
	extensions: []string, // lower case, without the dot
	file_names: []string, // whole names, e.g. "CMakeLists.txt"
}

LANGUAGES := [?]Language {
	{id = "odin", name = "Odin", extensions = {"odin"}},
	{id = "python", name = "Python", extensions = {"py", "pyi", "pyw"}},
	{id = "rust", name = "Rust", extensions = {"rs"}},
	{id = "c", name = "C", extensions = {"c", "h"}},
	{id = "cpp", name = "C++", extensions = {"cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "inl"}},
	{id = "go", name = "Go", extensions = {"go"}},
	{id = "javascript", name = "JavaScript", extensions = {"js", "mjs", "cjs"}},
	{id = "javascriptreact", name = "JavaScript (JSX)", extensions = {"jsx"}},
	{id = "typescript", name = "TypeScript", extensions = {"ts", "mts", "cts"}},
	{id = "typescriptreact", name = "TypeScript (TSX)", extensions = {"tsx"}},
	{id = "toml", name = "TOML", extensions = {"toml"}},
	{id = "zig", name = "Zig", extensions = {"zig", "zon"}},
	{id = "lua", name = "Lua", extensions = {"lua"}},
	{id = "markdown", name = "Markdown", extensions = {"md", "markdown"}},
	{id = "json", name = "JSON", extensions = {"json", "jsonc"}},
	{id = "java", name = "Java", extensions = {"java"}},
	{id = "csharp", name = "C#", extensions = {"cs"}},
	{id = "shellscript", name = "Shell", extensions = {"sh", "bash", "zsh"}},
	{id = "cmake", name = "CMake", extensions = {"cmake"}, file_names = {"CMakeLists.txt"}},
}

Server_Spec :: struct {
	name:         string,
	command:      []string, // program and arguments
	languages:    []string, // language ids
	root_markers: []string, // files or folders that mark a project's root
	install:      []string, // command lines that install it (see install.odin)
	url:          string,   // where to read about installing it
	settings:     string,   // JSON: the workspace configuration it is sent
	init_options: string,   // JSON: initializationOptions
	enabled:      bool,     // used when installed, unless the user turns it off
}

// In order of preference: a request goes to the first server of a file that
// supports it (diagnostics come from all of them)
SERVERS := [?]Server_Spec {
	{
		name = "ols",
		command = {"ols"},
		languages = {"odin"},
		root_markers = {"ols.json"},
		url = "https://github.com/DanielGavin/ols",
		enabled = true,
	},
	{
		name = "pyright",
		command = {"pyright-langserver", "--stdio"},
		languages = {"python"},
		root_markers = {"pyproject.toml", "pyrightconfig.json", "setup.py", "setup.cfg"},
		install = {
			"npm install -g pyright",
			"uv tool install pyright",
			"pipx install pyright",
			"pip install pyright",
			"py -m pip install pyright",
			"python -m pip install pyright",
			"brew install pyright",
		},
		url = "https://github.com/microsoft/pyright",
		settings = `{"python": {"analysis": {"autoSearchPaths": true, ` +
		           `"useLibraryCodeForTypes": true}}}`,
		enabled = true,
	},
	{
		name = "basedpyright",
		command = {"basedpyright-langserver", "--stdio"},
		languages = {"python"},
		root_markers = {"pyproject.toml", "pyrightconfig.json", "setup.py", "setup.cfg"},
		install = {
			"uv tool install basedpyright",
			"pipx install basedpyright",
			"pip install basedpyright",
			"py -m pip install basedpyright",
			"python -m pip install basedpyright",
			"npm install -g basedpyright",
			"brew install basedpyright",
		},
		url = "https://github.com/DetachHead/basedpyright",
	},
	{
		name = "ty",
		command = {"ty", "server"},
		languages = {"python"},
		root_markers = {"ty.toml", "pyproject.toml", "setup.py", "setup.cfg"},
		install = {
			"uv tool install ty",
			"pipx install ty",
			"pip install ty",
			"py -m pip install ty",
			"python -m pip install ty",
			"brew install ty",
		},
		url = "https://docs.astral.sh/ty/",
	},
	{
		name = "ruff",
		command = {"ruff", "server"},
		languages = {"python"},
		root_markers = {"pyproject.toml", "ruff.toml", ".ruff.toml"},
		install = {
			"uv tool install ruff",
			"pipx install ruff",
			"pip install ruff",
			"py -m pip install ruff",
			"python -m pip install ruff",
			"brew install ruff",
		},
		url = "https://docs.astral.sh/ruff/editors/",
		enabled = true,
	},
	{
		name = "rust-analyzer",
		command = {"rust-analyzer"},
		languages = {"rust"},
		root_markers = {"Cargo.toml"},
		install = {
			"rustup component add rust-analyzer",
			"scoop install rust-analyzer",
			"brew install rust-analyzer",
		},
		url = "https://rust-analyzer.github.io",
		enabled = true,
	},
	{
		name = "clangd",
		command = {"clangd"},
		languages = {"c", "cpp"},
		root_markers = {"compile_commands.json", "compile_flags.txt", ".clangd"},
		install = {
			"uv tool install clangd",
			"pipx install clangd",
			"pip install clangd",
			"py -m pip install clangd",
			"python -m pip install clangd",
			"scoop install llvm",
		},
		url ="https://clangd.llvm.org/installation",
		enabled = true,
	},
	{
		name = "gopls",
		command = {"gopls"},
		languages = {"go"},
		root_markers = {"go.work", "go.mod"},
		install = {"go install golang.org/x/tools/gopls@latest", "brew install gopls"},
		url = "https://go.dev/gopls",
		enabled = true,
	},
	{
		name = "typescript-language-server",
		command = {"typescript-language-server", "--stdio"},
		languages = {"javascript", "javascriptreact", "typescript", "typescriptreact"},
		root_markers = {"tsconfig.json", "jsconfig.json", "package.json"},
		install = {"npm install -g typescript typescript-language-server"},
		url = "https://github.com/typescript-language-server/typescript-language-server",
		enabled = true,
	},
	{
		name = "tombi",
		command = {"tombi", "lsp"},
		languages = {"toml"},
		root_markers = {"tombi.toml", ".tombi.toml"},
		install = {
			"uv tool install tombi",
			"pipx install tombi",
			"pip install tombi",
			"py -m pip install tombi",
			"python -m pip install tombi",
			"npm install -g tombi",
			"brew install tombi",
		},
		url = "https://tombi-toml.github.io/tombi/",
		enabled = true,
	},
	{
		name = "taplo",
		command = {"taplo", "lsp", "stdio"},
		languages = {"toml"},
		root_markers = {".taplo.toml", "taplo.toml"},
		install = {
			"uv tool install taplo",
			"pipx install taplo",
			"pip install taplo",
			"py -m pip install taplo",
			"python -m pip install taplo",
			"scoop install taplo",
			"choco install taplo",
			"brew install taplo",
			"cargo install taplo-cli --locked --features lsp",
		},
		url = "https://taplo.tamasfe.dev",
	},
	{
		name = "zls",
		command = {"zls"},
		languages = {"zig"},
		root_markers = {"build.zig", "zls.json"},
		install = {"brew install zls"},
		url = "https://github.com/zigtools/zls",
		enabled = true,
	},
	{
		name = "lua-language-server",
		command = {"lua-language-server"},
		languages = {"lua"},
		root_markers = {".luarc.json", ".luarc.jsonc"},
		install = {"scoop install lua-language-server", "brew install lua-language-server"},
		url = "https://luals.github.io/#install",
		enabled = true,
	},
	{
		name = "marksman",
		command = {"marksman", "server"},
		languages = {"markdown"},
		root_markers = {".marksman.toml"},
		install = {"scoop install marksman", "brew install marksman"},
		url = "https://github.com/artempyanykh/marksman",
	},
}


// The language of a file: from `extra` (languages users added) first, then
// LANGUAGES. "" if none
language_for_path :: proc(path: string, extra: []Language = nil) -> string {
	name := filepath.base(path)
	ext := strings.to_lower(strings.trim_prefix(filepath.ext(name), "."), context.temp_allocator)

	for list in ([][]Language{extra, LANGUAGES[:]}) {
		for lang in list {
			for n in lang.file_names {
				if n == name do return lang.id
			}
			if ext == "" do continue

			for e in lang.extensions {
				if e == ext do return lang.id
			}
		}
	}
	return ""
}


// The language's display name, or its id if it has none
language_name :: proc(id: string, extra: []Language = nil) -> string {
	for list in ([][]Language{extra, LANGUAGES[:]}) {
		for lang in list {
			if lang.id == id && lang.name != "" {
				return lang.name
			}
		}
	}
	return id
}


serves :: proc(spec: Server_Spec, language_id: string) -> bool {
	for id in spec.languages {
		if id == language_id do return true
	}
	return false
}


// The project root of a file for a server: the nearest folder above it, up to
// the workspace, that holds one of the markers, else the workspace (or the
// file's folder if it is outside the workspace)
find_root :: proc(
	file, workspace: string,
	markers: []string,
	allocator := context.allocator,
) -> string {
	dir := filepath.dir(file)
	inside := workspace != "" && is_within(dir, workspace)

	for {
		for marker in markers {
			candidate, _ := filepath.join({dir, marker}, context.temp_allocator)
			if os.exists(candidate) do return strings.clone(dir, allocator)
		}

		// Outside the workspace, only the file's own folder
		if !inside do break
		if len(dir) <= len(workspace) do break

		parent := filepath.dir(dir)
		if parent == dir do break
		dir = parent
	}

	if inside do return strings.clone(workspace, allocator)
	return strings.clone(filepath.dir(file), allocator)
}


// Whether `path` is `dir` or inside it
@(private = "file")
is_within :: proc(path, dir: string) -> bool {
	if path == dir do return true
	if len(path) <= len(dir) || !strings.has_prefix(path, dir) {
		return false
	}

	c := path[len(dir)]
	return c == '/' || c == '\\' || strings.has_suffix(dir, "/") || strings.has_suffix(dir, `\`)
}
