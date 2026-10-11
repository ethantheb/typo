#!/usr/bin/env python3
"""Build script for typo.

    python build.py            debug build
    python build.py --release  optimized build (no console window on Windows)
    python build.py --run      build, then launch the editor
    python build.py --test     run the unit tests (buffer, syntax, toml)

Steps:
  1. Compile the tree-sitter runtime + grammars (C) with clang into a static
     library, only when a C source is newer than the library. Always optimized,
     so parsing speed doesn't depend on the build mode.
  2. odin build src. A freshly linked executable is sometimes briefly locked
     (e.g. by antivirus scanning) and the next link fails; that is retried.
  3. Copy runtime files next to the executable: SDL3 DLLs on Windows (they
     ship with Odin's vendor packages) and the fonts.

Requires: odin, clang, and on Windows llvm-lib (part of LLVM) / elsewhere ar.
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "build"
OBJ = OUT / "obj"

IS_WINDOWS = platform.system() == "Windows"
EXE = OUT / ("typo.exe" if IS_WINDOWS else "typo")
TS_LIB = OBJ / ("tree_sitter.lib" if IS_WINDOWS else "libtree_sitter.a")

TS_SOURCES = [
    "vendor/tree-sitter/lib/src/lib.c",
    "vendor/tree-sitter-odin/src/parser.c",
    "vendor/tree-sitter-odin/src/scanner.c",
]
TS_INPUT_DIRS = ["vendor/tree-sitter", "vendor/tree-sitter-odin/src"]

LINK_LOCK_ERRORS = ("LNK1104", "LNK1201")


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


def build_tree_sitter():
    if TS_LIB.exists() and TS_LIB.stat().st_mtime >= newest_mtime(TS_INPUT_DIRS, {".c", ".h"}):
        return
    print("Building tree-sitter...", flush=True)
    OBJ.mkdir(parents=True, exist_ok=True)
    objs = []
    for src in TS_SOURCES:
        obj = OBJ / (src.replace("/", "_").removesuffix(".c") + (".obj" if IS_WINDOWS else ".o"))
        cmd = ["clang", "-c", "-O2", "-std=c11", "-w",
               "-I", "vendor/tree-sitter/lib/include", "-I", "vendor/tree-sitter/lib/src",
               src, "-o", obj]
        if IS_WINDOWS:
            cmd.insert(1, "-D_CRT_SECURE_NO_WARNINGS")
        else:
            cmd.insert(1, "-fPIC")
        check(cmd)
        objs.append(obj)
    if IS_WINDOWS:
        check(["llvm-lib", "/nologo", f"/out:{TS_LIB}", *objs])
    else:
        TS_LIB.unlink(missing_ok=True)
        check(["ar", "rcs", TS_LIB, *objs])


def build_odin(release):
    flags = ["-o:speed"] if release else ["-debug"]
    if release and IS_WINDOWS:
        flags.append("-subsystem:windows")
    cmd = ["odin", "build", "src", f"-out:{EXE}", *flags]
    for attempt in range(1, 5):
        result = run(cmd, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            if output.strip():
                print(output, end="")
            return
        if attempt < 4 and any(e in output for e in LINK_LOCK_ERRORS):
            print(f"(executable locked, retrying in 1s: attempt {attempt})", flush=True)
            time.sleep(1)
            continue
        print(output, end="")
        sys.exit(result.returncode)


def copy_if_changed(src, dst):
    # Skipping unchanged files also avoids failing while a running editor holds them open.
    if dst.exists():
        a, b = src.stat(), dst.stat()
        if a.st_size == b.st_size and int(a.st_mtime) == int(b.st_mtime):
            return
    shutil.copy2(src, dst)


def copy_runtime_files():
    if IS_WINDOWS:
        odin_root = Path(subprocess.run(["odin", "root"], capture_output=True, text=True, check=True).stdout.strip())
        for dll in ["vendor/sdl3/SDL3.dll", "vendor/sdl3/ttf/SDL3_ttf.dll"]:
            copy_if_changed(odin_root / dll, OUT / Path(dll).name)
    # Fonts are loaded relative to the executable.
    for src in (ROOT / "assets").rglob("*"):
        if src.is_file():
            dst = OUT / "assets" / src.relative_to(ROOT / "assets")
            dst.parent.mkdir(parents=True, exist_ok=True)
            copy_if_changed(src, dst)


def run_tests():
    failed = False
    for package in ["buffer", "syntax", "toml"]:
        out = OUT / f"{package}_test{'.exe' if IS_WINDOWS else ''}"
        result = run(["odin", "test", f"src/{package}", f"-out:{out}", "-define:ODIN_TEST_FANCY=false"])
        failed |= result.returncode != 0
    sys.exit(1 if failed else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--release", action="store_true", help="optimized build")
    parser.add_argument("--run", action="store_true", help="launch the editor after building")
    parser.add_argument("--test", action="store_true", help="run unit tests")
    args = parser.parse_args()

    OUT.mkdir(exist_ok=True)
    build_tree_sitter()
    if args.test:
        run_tests()
    build_odin(args.release)
    copy_runtime_files()
    if args.run:
        subprocess.run([EXE], cwd=ROOT)


if __name__ == "__main__":
    main()
