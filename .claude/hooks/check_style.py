"""Claude Code PostToolUse hook: checks new Odin code against the mechanical
rules of the Code style section in CLAUDE.md.

It reads the hook event (JSON) from stdin and looks only at the text the edit
wrote: Edit's new_string, or Write's content. Problems are printed to stderr
with exit code 2, which Claude Code shows to Claude next to the edit.
"""

import json
import re
import sys
from pathlib import PurePath


MAX_WIDTH = 100
TAB_WIDTH = 4

# A one-liner's condition may not combine or declare anything.
COMPLEX_CONDITION = re.compile(r"&&|\|\||:=|;")

# A one-liner's body is one simple statement or call.
COMPLEX_BODY = re.compile(r"\b(if|for|switch|do)\b|&&|\|\||\?")

# `if x do y`, `for x in y do z`, `else do y`, ...
DO_LINE = re.compile(r"^\s*(?:\}\s*)?(?:else\s+)?(if|for|when|switch)?\b(.*?)\bdo\b(.*)$")


def code_only(line: str) -> str:
    """The line without its comment and with string contents blanked."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"`[^`]*`", "``", line)
    line = re.sub(r"'(?:\\.|[^'\\])+'", "''", line)

    comment = line.find("//")
    if comment >= 0:
        line = line[:comment]

    return line


def line_problems(line: str) -> list[str]:
    problems = []

    width = len(line.expandtabs(TAB_WIDTH))
    if width > MAX_WIDTH:
        problems.append(f"{width} columns, over the {MAX_WIDTH} limit")

    match = DO_LINE.match(code_only(line))
    if match:
        condition, body = match.group(2), match.group(3)
        if COMPLEX_CONDITION.search(condition):
            problems.append("`do` one-liner with a compound condition; use a block")
        elif COMPLEX_BODY.search(body):
            problems.append("`do` one-liner with more than one simple statement; use a block")

    return problems


def check_files(paths: list[str]) -> int:
    """Command-line use: checks whole files, e.g. `python check_style.py src/*.odin`."""
    failed = 0

    for path in paths:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()

        for number, line in enumerate(lines, 1):
            for problem in line_problems(line):
                print(f"{path}:{number}: {problem}")
                failed += 1

    return 1 if failed else 0


def main() -> int:
    if len(sys.argv) > 1:
        return check_files(sys.argv[1:])

    event = json.load(sys.stdin)
    tool = event.get("tool_name")
    args = event.get("tool_input") or {}

    path = PurePath(str(args.get("file_path", "")).replace("\\", "/"))
    if path.suffix != ".odin" or "vendor" in path.parts or "src" not in path.parts:
        return 0

    if tool == "Edit":
        text = args.get("new_string", "")
    elif tool == "Write":
        text = args.get("content", "")
    else:
        return 0

    report = []
    for line in text.splitlines():
        for problem in line_problems(line):
            report.append(f"  {problem}:\n    {line.strip()[:90]}")

    if not report:
        return 0

    print(f"Code style (CLAUDE.md) in {path.name}; fix these lines:", file=sys.stderr)
    print("\n".join(report), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
