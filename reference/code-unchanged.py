#!/usr/bin/env python3
"""
code-unchanged.py — prove a comment-only edit changed no code.

A wording pass over `contracts/MandateManager.sol`, `reference/policy.js` or a
`.t.sol` file is safe only if every executable line survives byte for byte. The
diff cannot establish that: a comment rewrite reflows dozens of lines, and a
changed operator sitting between two of them reads as part of the reflow.

    python3 reference/code-unchanged.py HEAD                    # every .sol and .js
    python3 reference/code-unchanged.py HEAD contracts/MandateManager.sol
    python3 reference/code-unchanged.py --pinned HEAD contracts/MandateManager.sol

For each file it strips comments from the revision and from the working tree, then
compares what is left. Blank lines and trailing whitespace are ignored, because a
comment removal legitimately leaves either behind. Anything else that differs is
printed as a unified diff and the exit status is 1.

`--pinned` adds a stricter requirement: every surviving code line must still sit at
the same line NUMBER. That matters for `contracts/MandateManager.sol`, which this
repository cites by line throughout — a threat-model finding names a guard by the
line it sits on, and the mutation gate's logs record which line each mutant came
from. Rewriting a comment block to a different number of lines would leave all of
that pointing one line off with nothing to announce it, so a comment pass over the
contract is written to keep each block's line count and is checked here.

The stripper is deliberate about one case: `//` inside a string literal is code,
not a comment. A Solidity or JavaScript file in this repository can contain a
URL, so the pattern only removes `//` when the quote count before it is even.
Being wrong here is safe in one direction — treating code as a comment would
hide a real change — so the check is written to prefer keeping text.

This does not replace `reference/fact-diff.py`. That one asks whether the prose
still states the same facts; this one asks whether the program is the same
program. A wording pass on source needs both.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"node_modules", "lib", ".git", "out", "cache", "broadcast"}
BLOCK = re.compile(r"/\*.*?\*/", re.S)


def strip_comments(text: str, keep_numbers: bool = False):
    """Remove block comments, then line comments outside string literals.

    With keep_numbers the result is (lineno, code) pairs, so a caller can ask the
    stronger question of whether a code line is still on the same line.
    """
    # A block comment is replaced by as many newlines as it spanned, so that the
    # numbering of everything after it is unaffected by the removal.
    def blank(m):
        return "\n" * m.group(0).count("\n")

    text = BLOCK.sub(blank, text)
    out = []
    for n, line in enumerate(text.split("\n"), 1):
        cut = None
        i = 0
        quote = None
        while i < len(line) - 1:
            c = line[i]
            if quote:
                if c == "\\":
                    i += 2
                    continue
                if c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "/" and line[i + 1] == "/":
                cut = i
                break
            i += 1
        if cut is not None:
            line = line[:cut]
        line = line.rstrip()
        if line.strip():
            out.append((n, line) if keep_numbers else line)
    return out


def at_rev(rev: str, rel: str) -> str | None:
    r = subprocess.run(
        ["git", "-c", "safe.directory=*", "show", f"{rev}:{rel}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return r.stdout if r.returncode == 0 else None


def main() -> int:
    args = sys.argv[1:]
    pinned = "--pinned" in args
    args = [a for a in args if a != "--pinned"]
    if not args:
        print("usage: code-unchanged.py [--pinned] <git-rev> [file ...]", file=sys.stderr)
        return 2
    rev = args[0]
    if len(args) > 1:
        files = [ROOT / a for a in args[1:]]
    else:
        files = sorted(
            p
            for p in ROOT.rglob("*")
            if p.suffix in {".sol", ".js"} and not any(part in SKIP for part in p.parts)
        )

    bad = 0
    moved_files = 0
    checked = 0
    for path in files:
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        before = at_rev(rev, rel)
        if before is None:
            print(f"{rel:36s} new file, nothing to compare")
            continue
        after = path.read_text(encoding="utf-8", errors="replace")
        if before == after:
            continue
        checked += 1
        a, b = strip_comments(before), strip_comments(after)
        if a != b:
            bad += 1
            print(f"\n{rel} — CODE CHANGED ({len(a)} lines at {rev}, {len(b)} now)")
            import difflib

            for line in list(difflib.unified_diff(a, b, rev, "working tree", lineterm=""))[:60]:
                print(f"    {line}")
            continue
        pa = strip_comments(before, keep_numbers=True)
        pb = strip_comments(after, keep_numbers=True)
        moved = [(x[0], y[0], x[1]) for x, y in zip(pa, pb) if x[0] != y[0]]
        if moved:
            moved_files += 1
            print(f"{rel:36s} {len(b):5d} code lines identical, {len(moved)} MOVED")
            for was, now, code in moved[:6]:
                print(f"{'':36s}    :{was} -> :{now}   {code.strip()[:60]}")
            if len(moved) > 6:
                print(f"{'':36s}    ... and {len(moved) - 6} more")
        else:
            print(f"{rel:36s} {len(b):5d} code lines, all identical, none moved")

    print(f"\nfiles with text changes: {checked}   files with code changes: {bad}", end="")
    print(f"   files with moved code lines: {moved_files}")
    if bad:
        print("A comment pass may not alter code. Restore every line above.")
        return 1
    if pinned and moved_files:
        print("--pinned was requested and code lines moved. Every citation of this file by")
        print("line number is now off. Re-wrap the comment block to its original line count.")
        return 1
    if moved_files:
        print("OK — comments changed, code did not. Line numbers moved; run")
        print("reference/line-citations.py to find every pointer that needs the new number.")
        return 0
    print("OK — comments changed, code did not, and no code line moved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
