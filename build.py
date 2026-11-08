#!/usr/bin/env python3
"""Build script for typo.

    python build.py            debug build
    python build.py --release  optimized build (no console window on Windows)
    python build.py --run      build, then launch the editor
    python build.py --test     run the unit tests, then the performance suite
    python build.py --perf     run only the performance suite
    python build.py --install  release build, installed to INSTALL_DIR (see below)

Steps:
  1. Compile the tree-sitter runtime + grammars (C) with clang into a static
     library, only when a C source is newer than the library. Always optimized,
     so parsing speed doesn't depend on the build mode.
  2. Build libghostty-vt (terminal emulation) from a pinned ghostty commit with
     patches/ghostty.patch applied (reflow trims trailing spaces when scrollback
     isn't pulled, as ConPTY does), with a pinned Zig, both downloaded into
     build/ on first use. Rebuilt only when GHOSTTY_COMMIT or the patch changes.
  3. Build SDL3 and SDL3_ttf (with FreeType, HarfBuzz and plutosvg) with CMake
     from pinned releases, downloaded into build/ on first use, SDL3_ttf with
     patches/sdl_ttf.patch applied (glyphs at quarter-pixel positions, and a
     glyph coverage table for gamma and contrast). Rebuilt only when
     SDL_VERSION, SDL_TTF_VERSION or the patch changes; these must match the
     bindings in vendor/sdl3.
  4. On Windows, fetch Microsoft's ConPTY package (conpty.dll + OpenConsole.exe,
     the pseudo console host Windows Terminal ships). It is newer and faster
     than the one built into Windows. The executable embeds both files and
     writes them out the first time the terminal starts.
  5. odin build src. A freshly linked executable is sometimes briefly locked
     (e.g. by antivirus scanning) and the next link fails; that is retried.

All libraries are linked statically and the fonts are embedded, so the
executable is the only file typo needs. It still links the system C library
dynamically on Linux and macOS, and SDL loads X11/Wayland there at runtime.

--test runs `odin test` on each package, then the performance suite: an
optimized build (build/typo-perf) run as `typo-perf --perf`, which opens a
window, drives the editor and terminal through scripted scenarios and fails if
any timing, CPU or GPU measurement is over its limit (see src/perf.odin).

--install puts a release build in its own folder, so the
installed copy can stay open while you keep developing in build/:
  Windows:      %LOCALAPPDATA%\\Programs\\typo   (add it to PATH to run `typo`)
  Linux, macOS: ~/.local/share/typo, linked as ~/.local/bin/typo
--install-dir DIR installs somewhere else. Installing again updates it, even
while the installed typo is running.

Requires: odin, clang, git, cmake with a C/C++ compiler (Visual Studio on
Windows), and on Windows llvm-lib (part of LLVM) / elsewhere ar. Building SDL
on Linux also needs the X11 and Wayland development packages.
"""

import argparse
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
OUT  = ROOT / "build"
OBJ  = OUT / "obj"

IS_WINDOWS = platform.system() == "Windows"
EXE        = OUT / ("typo.exe" if IS_WINDOWS else "typo")
PERF_EXE   = OUT / ("typo-perf.exe" if IS_WINDOWS else "typo-perf")

TEST_PACKAGES = [
    "src/buffer",
    "src/syntax",
    "src/markdown",
    "src/toml",
    "src/term",
    "src/gfx",
    "src/textedit",
    "src/mdview",
    "src",
]

# Tree-sitter: the runtime and grammars, compiled into one static library
TS_LIB = OBJ / ("tree_sitter.lib" if IS_WINDOWS else "libtree_sitter.a")
TS_SOURCES = [
    "vendor/tree-sitter/lib/src/lib.c",
    "vendor/tree-sitter-odin/src/parser.c",
    "vendor/tree-sitter-odin/src/scanner.c",
    "vendor/tree-sitter-toml/src/parser.c",
    "vendor/tree-sitter-toml/src/scanner.c",
]
TS_INPUT_DIRS = [
    "vendor/tree-sitter",
    "vendor/tree-sitter-odin/src",
    "vendor/tree-sitter-toml/src",
]

# libghostty-vt, built with a pinned Zig
ZIG_VERSION    = "0.16.0"
GHOSTTY_REPO   = "https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT = "6301810a48aaa3426887a4316668f18833a40138"
GHOSTTY_SRC    = OUT / "deps" / "ghostty"
GHOSTTY_OUT    = OBJ / "ghostty-vt"
GHOSTTY_PATCH  = ROOT / "patches" / "ghostty.patch"
GHOSTTY_LIB    = GHOSTTY_OUT / "lib" / (
    "ghostty-vt-static.lib" if IS_WINDOWS else "libghostty-vt.a"
)

# SDL3 and SDL3_ttf, built with CMake
SDL_VERSION        = "3.4.2"
SDL_TTF_VERSION    = "3.2.2"
SDL_REPO           = "https://github.com/libsdl-org/SDL.git"
SDL_TTF_REPO       = "https://github.com/libsdl-org/SDL_ttf.git"
SDL_TTF_SUBMODULES = [
    "external/freetype",
    "external/harfbuzz",
    "external/plutosvg",
    "external/plutovg",
]
SDL_SRC       = OUT / "deps" / "SDL"
SDL_TTF_SRC   = OUT / "deps" / "SDL_ttf"
SDL_TTF_PATCH = ROOT / "patches" / "sdl_ttf.patch"
SDL_OUT       = OBJ / "sdl"  # install prefix; vendor/sdl3 links the libraries in lib/

if IS_WINDOWS:
    SDL_LIBS = [SDL_OUT / "lib" / "SDL3-static.lib", SDL_OUT / "lib" / "SDL3_ttf-static.lib"]
else:
    SDL_LIBS = [SDL_OUT / "lib" / "libSDL3.a", SDL_OUT / "lib" / "libSDL3_ttf.a"]

# Microsoft's ConPTY package, embedded by src/term/pty_windows.odin
CONPTY_VERSION = "1.24.260710001"
CONPTY_SHA256  = "175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e"
CONPTY_OUT     = OBJ / "conpty"
CONPTY_FILES   = {  # file in the package -> name in CONPTY_OUT
    "runtimes/win-x64/native/conpty.dll": "conpty.dll",
    "build/native/runtimes/x64/OpenConsole.exe": "OpenConsole.exe",
}

# Linker errors for an executable that is briefly locked
LINK_LOCK_ERRORS = ("LNK1104", "LNK1201")


# --- Helpers ----------------------------------------------------------------------


def run(cmd, **kwargs):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, **kwargs)


def check(cmd):
    if run(cmd).returncode != 0:
        sys.exit(1)


def newest_mtime(dirs, suffixes):
    newest = 0.0
    for d in dirs:
        for path in (ROOT / d).rglob("*"):
            if path.suffix in suffixes:
                newest = max(newest, path.stat().st_mtime)
    return newest


def git_checkout(src, repo, ref, submodules=()):
    """Shallow-fetches `ref` (a commit or refs/tags/...) of `repo` into `src`."""
    if not (src / ".git").exists():
        src.mkdir(parents=True, exist_ok=True)
        check(["git", "-C", src, "init", "-q"])
        check(["git", "-C", src, "remote", "add", "origin", repo])

    check(["git", "-C", src, "fetch", "-q", "--depth", "1", "origin", ref])
    check(["git", "-C", src, "checkout", "-q", "--force", "FETCH_HEAD"])

    if submodules:
        update = ["git", "-C", src, "submodule", "update", "-q", "--init", "--depth", "1"]
        check([*update, *submodules])


def patch_hash(patch):
    return hashlib.sha256(patch.read_bytes()).hexdigest()[:12]


# --- Dependencies -----------------------------------------------------------------


def build_tree_sitter():
    newest_source = newest_mtime(TS_INPUT_DIRS, {".c", ".h"})
    if TS_LIB.exists() and TS_LIB.stat().st_mtime >= newest_source:
        return

    print("Building tree-sitter...", flush=True)
    OBJ.mkdir(parents=True, exist_ok=True)

    # Each source to an object file
    objs = []
    for src in TS_SOURCES:
        obj_name = src.replace("/", "_").removesuffix(".c") + (".obj" if IS_WINDOWS else ".o")
        obj = OBJ / obj_name
        cmd = [
            "clang", "-c", "-O2", "-std=c11", "-w",
            "-I", "vendor/tree-sitter/lib/include",
            "-I", "vendor/tree-sitter/lib/src",
            src, "-o", obj,
        ]
        if IS_WINDOWS:
            cmd.insert(1, "-D_CRT_SECURE_NO_WARNINGS")
        else:
            cmd.insert(1, "-fPIC")
        check(cmd)
        objs.append(obj)

    # Then into the library
    if IS_WINDOWS:
        check(["llvm-lib", "/nologo", f"/out:{TS_LIB}", *objs])
    else:
        TS_LIB.unlink(missing_ok=True)
        check(["ar", "rcs", TS_LIB, *objs])


def zig_exe():
    """A Zig matching ZIG_VERSION: from PATH if it matches, else downloaded into build/tools."""
    on_path = shutil.which("zig")
    if on_path:
        result = subprocess.run([on_path, "version"], capture_output=True, text=True)
        if result.stdout.strip() == ZIG_VERSION:
            return on_path

    arch_names = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }
    os_names = {"Windows": "windows", "Darwin": "macos", "Linux": "linux"}
    arch = arch_names[platform.machine().lower()]
    os_name = os_names[platform.system()]

    name = f"zig-{arch}-{os_name}-{ZIG_VERSION}"
    exe = OUT / "tools" / name / ("zig.exe" if IS_WINDOWS else "zig")
    if exe.exists():
        return str(exe)

    # Download and check it
    print(f"Downloading Zig {ZIG_VERSION}...", flush=True)
    with urllib.request.urlopen("https://ziglang.org/download/index.json") as r:
        entry = json.load(r)[ZIG_VERSION][f"{arch}-{os_name}"]
    with urllib.request.urlopen(entry["tarball"]) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != entry["shasum"]:
        sys.exit(f"Zig download checksum mismatch: {entry['tarball']}")

    (OUT / "tools").mkdir(parents=True, exist_ok=True)
    if entry["tarball"].endswith(".zip"):
        zipfile.ZipFile(io.BytesIO(data)).extractall(OUT / "tools")
    else:
        tarfile.open(fileobj=io.BytesIO(data)).extractall(OUT / "tools", filter="data")
    return str(exe)


def build_ghostty():
    stamp = GHOSTTY_OUT / "commit.txt"
    version = f"{GHOSTTY_COMMIT} {patch_hash(GHOSTTY_PATCH)}"
    if GHOSTTY_LIB.exists() and stamp.exists() and stamp.read_text().strip() == version:
        return

    print("Building libghostty-vt...", flush=True)
    git_checkout(GHOSTTY_SRC, GHOSTTY_REPO, GHOSTTY_COMMIT)
    check(["git", "-C", GHOSTTY_SRC, "apply", GHOSTTY_PATCH])

    # Zig builds from the ghostty checkout, not ROOT
    zig = zig_exe()
    cmd = [zig, "build", "-Demit-lib-vt", "-Doptimize=ReleaseFast", "--prefix", GHOSTTY_OUT]
    print("+", " ".join(str(c) for c in cmd), flush=True)
    if subprocess.run(cmd, cwd=GHOSTTY_SRC).returncode != 0:
        sys.exit(1)

    stamp.write_text(version)


def cmake_build(src, build_dir, options):
    """Configures, builds and installs a CMake project into SDL_OUT as static
    release libraries, with the static C runtime on Windows like Odin uses."""
    prefix = SDL_OUT.as_posix()
    check([
        "cmake", "-S", src, "-B", build_dir,
        f"-DCMAKE_INSTALL_PREFIX={prefix}",
        f"-DCMAKE_PREFIX_PATH={prefix}",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        *options,
    ])
    check(["cmake", "--build", build_dir, "--config", "Release", "--parallel"])
    check(["cmake", "--install", build_dir, "--config", "Release"])


def build_sdl():
    stamp = SDL_OUT / "versions.txt"
    versions = f"{SDL_VERSION} {SDL_TTF_VERSION} {patch_hash(SDL_TTF_PATCH)}"
    built = all(lib.exists() for lib in SDL_LIBS)
    if built and stamp.exists() and stamp.read_text().strip() == versions:
        return

    print("Building SDL3 and SDL3_ttf...", flush=True)
    shutil.rmtree(SDL_OUT, ignore_errors=True)

    # Sources, with SDL_ttf patched
    git_checkout(SDL_SRC, SDL_REPO, f"refs/tags/release-{SDL_VERSION}")
    git_checkout(
        SDL_TTF_SRC,
        SDL_TTF_REPO,
        f"refs/tags/release-{SDL_TTF_VERSION}",
        SDL_TTF_SUBMODULES,
    )
    check(["git", "-C", SDL_TTF_SRC, "apply", SDL_TTF_PATCH])

    # SDL first: SDL_ttf finds it in SDL_OUT
    build_dir = OBJ / "sdl-build"
    shutil.rmtree(build_dir, ignore_errors=True)
    cmake_build(SDL_SRC, build_dir / "SDL", [
        "-DSDL_SHARED=OFF",
        "-DSDL_STATIC=ON",
        "-DSDL_TEST_LIBRARY=OFF",
        "-DSDL_EXAMPLES=OFF",
        "-DSDL_TESTS=OFF",
    ])
    cmake_build(SDL_TTF_SRC, build_dir / "SDL_ttf", [
        "-DBUILD_SHARED_LIBS=OFF",
        "-DSDLTTF_VENDORED=ON",
        "-DSDLTTF_HARFBUZZ=ON",
        "-DSDLTTF_PLUTOSVG=ON",
        "-DSDLTTF_SAMPLES=OFF",
        "-DSDLTTF_STRICT=ON",
    ])

    stamp.write_text(versions)


def fetch_conpty():
    stamp = CONPTY_OUT / "version.txt"
    if not IS_WINDOWS:
        return
    if stamp.exists() and stamp.read_text().strip() == CONPTY_VERSION:
        return

    # Download and check the package
    print(f"Downloading ConPTY {CONPTY_VERSION}...", flush=True)
    url = (
        "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/"
        f"{CONPTY_VERSION}/microsoft.windows.console.conpty.{CONPTY_VERSION}.nupkg"
    )
    with urllib.request.urlopen(url) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != CONPTY_SHA256:
        sys.exit(f"ConPTY download checksum mismatch: {url}")

    # Then take the two files out of it
    CONPTY_OUT.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for src, name in CONPTY_FILES.items():
            (CONPTY_OUT / name).write_bytes(z.read(src))

    stamp.write_text(CONPTY_VERSION)


# --- typo -------------------------------------------------------------------------


def build_odin(release, exe=EXE, console=False):
    flags = ["-o:speed"] if release else ["-debug"]
    if release and IS_WINDOWS and not console:
        flags.append("-subsystem:windows")
    if IS_WINDOWS:
        flags.append("-resource:assets/icon/typo.rc")  # the executable's icon

    cmd = ["odin", "build", "src", f"-out:{exe}", *flags]

    # A link that fails on a locked executable is retried
    for attempt in range(1, 5):
        result = run(cmd, capture_output=True, text=True)
        output = result.stdout + result.stderr

        if result.returncode == 0:
            if output.strip():
                print(output, end="")
            return

        locked = any(e in output for e in LINK_LOCK_ERRORS)
        if attempt < 4 and locked:
            print(f"(executable locked, retrying in 1s: attempt {attempt})", flush=True)
            time.sleep(1)
            continue

        print(output, end="")
        sys.exit(result.returncode)


# --- Installing -------------------------------------------------------------------


def copy_if_changed(src, dst):
    # Skipping an unchanged file also avoids failing while a running typo holds it open
    if dst.exists():
        a, b = src.stat(), dst.stat()
        if a.st_size == b.st_size and int(a.st_mtime) == int(b.st_mtime):
            return
    shutil.copy2(src, dst)


def default_install_dir():
    if IS_WINDOWS:
        local = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return local / "Programs" / "typo"
    return Path.home() / ".local" / "share" / "typo"


def install_file(src, dst):
    """Copies src over dst. Windows won't overwrite a file that a running typo has
    loaded, but it will rename it, so a locked file is moved aside first."""
    try:
        copy_if_changed(src, dst)
    except PermissionError:
        aside = dst.with_name(dst.name + ".old")
        n = 1
        while aside.exists():
            try:
                aside.unlink()
            except OSError:
                aside = dst.with_name(f"{dst.name}.{n}.old")
                n += 1

        dst.rename(aside)
        shutil.copy2(src, dst)


def install(dest):
    dest = dest.resolve()

    # A release build of its own, so build/ stays free
    exe = OUT / "release" / EXE.name
    exe.parent.mkdir(exist_ok=True)
    build_odin(True, exe)

    dest.mkdir(parents=True, exist_ok=True)

    # Files moved aside by an earlier install; still locked if that typo is open
    for old in dest.rglob("*.old"):
        try:
            old.unlink()
        except OSError:
            pass

    install_file(exe, dest / EXE.name)
    print(f"Installed to {dest}")

    if IS_WINDOWS:
        tell_how_to_add_to_path(dest)
    else:
        link = Path.home() / ".local" / "bin" / "typo"
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(dest / EXE.name)
        print(f"Linked {link}")


def tell_how_to_add_to_path(dest):
    """On Windows, prints how to add `dest` to the user's PATH, unless it is there."""
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
        try:
            user_path = winreg.QueryValueEx(key, "Path")[0]
        except FileNotFoundError:
            user_path = ""

    entries = [Path(os.path.expandvars(e)).resolve() for e in user_path.split(";") if e]
    if dest.resolve() in entries:
        return

    print(
        "To run it as `typo` from any terminal, add the folder to your PATH "
        "(then open a new terminal):"
    )
    print(
        '  [Environment]::SetEnvironmentVariable("Path", '
        '[Environment]::GetEnvironmentVariable("Path", "User") + '
        f'";{dest}", "User")'
    )


# --- Tests ------------------------------------------------------------------------


def run_unit_tests():
    """Returns True if every package's tests pass."""
    ok = True
    for package in TEST_PACKAGES:
        name = Path(package).name if package != "src" else "typo"
        out = OUT / f"{name}_test{'.exe' if IS_WINDOWS else ''}"
        cmd = ["odin", "test", package, f"-out:{out}", "-define:ODIN_TEST_FANCY=false"]
        ok &= run(cmd).returncode == 0
    return ok


def run_perf():
    """Builds an optimized, console-attached binary and runs the performance suite."""
    build_odin(True, PERF_EXE, console=True)
    return run([PERF_EXE, "--perf"]).returncode == 0


# --- Main -------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    flags = [
        ("--release", "optimized build"),
        ("--run",     "launch the editor after building"),
        ("--test",    "run unit tests and the performance suite"),
        ("--perf",    "run only the performance suite"),
        ("--install", "install a release build"),
    ]
    for flag, help in flags:
        parser.add_argument(flag, action="store_true", help=help)
    parser.add_argument("--install-dir", type=Path, help="where --install puts it")
    args = parser.parse_args()

    # Dependencies, each only when missing or out of date
    OUT.mkdir(exist_ok=True)
    build_tree_sitter()
    build_ghostty()
    build_sdl()
    fetch_conpty()

    if args.test or args.perf:
        ok = run_unit_tests() if args.test else True
        ok &= run_perf()
        print("\nAll tests passed." if ok else "\nTests FAILED.")
        sys.exit(0 if ok else 1)

    if args.install or args.install_dir:
        install(args.install_dir or default_install_dir())
        return

    build_odin(args.release)
    if args.run:
        subprocess.run([EXE], cwd=ROOT)


if __name__ == "__main__":
    main()
