#!/usr/bin/env python3
"""
fact-diff.py — did a prose edit change any fact?

A wording pass over documentation is safe only if it leaves every number, hash,
address, path, identifier, command and code block exactly as it was. Reading a
large diff for that property does not work; the diff is mostly reflowed
sentences, and a digit that changed inside one of them is invisible.

So this compares the multiset of facts in each file against a git revision:

    python3 reference/fact-diff.py HEAD            # working tree vs HEAD
    python3 reference/fact-diff.py HEAD~1 README.md

For each file it extracts numbers (with separators and decimals intact), hex
literals, addresses and hashes, file paths, inline-code spans, fenced code block
contents, link targets, and CamelCase or snake_case identifiers. It then reports
anything present before and missing after, or the reverse. Prose is ignored
entirely, which is the point: the check is blind to the change being made and
sensitive only to the change that must not be made.

Exit status is 1 if any fact moved. Removing a sentence that contained a figure
will show up here as a removed fact, which is correct — deleting a number is a
content change and needs a human decision, not a silent pass.
"""

import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"node_modules", "lib", ".git", "out", "cache", "broadcast"}

PATTERNS = {
    "number": re.compile(r"\b\d[\d,_]*(?:\.\d+)?(?:e[+-]?\d+)?\b", re.I),
    "hex": re.compile(r"\b0x[0-9a-fA-F]+\b"),
    "code-span": re.compile(r"`([^`\n]+)`"),
    "link": re.compile(r"\]\(([^)]+)\)"),
    "path": re.compile(r"\b[\w./-]+\.(?:sol|md|py|js|json|toml|log|txt|lock|s\.sol|t\.sol)\b"),
    "identifier": re.compile(r"\b(?:[a-z]+[A-Z]\w*|[A-Z][a-z]+[A-Z]\w*|\w+_\w+)\b"),
}
FENCE = re.compile(r"```[^\n]*\n(.*?)```", re.S)


def facts(text: str) -> dict[str, Counter]:
    out = {}
    for name, rx in PATTERNS.items():
        found = [m.group(1) if rx.groups else m.group(0) for m in rx.finditer(text)]
        out[name] = Counter(found)
    out["fenced-block"] = Counter(b.strip() for b in FENCE.findall(text))
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
    if len(sys.argv) < 2:
        print("usage: fact-diff.py <git-rev> [file ...]", file=sys.stderr)
        return 2
    rev = sys.argv[1]
    if len(sys.argv) > 2:
        files = [ROOT / a for a in sys.argv[2:]]
    else:
        files = sorted(
            p
            for p in ROOT.rglob("*")
            if p.suffix in {".md", ".sol", ".js", ".py", ".toml"}
            and not any(part in SKIP for part in p.parts)
        )

    moved = 0
    checked = 0
    for path in files:
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        before = at_rev(rev, rel)
        if before is None:
            print(f"{rel:30s} new file, nothing to compare")
            continue
        after = path.read_text(encoding="utf-8", errors="replace")
        if before == after:
            continue
        checked += 1
        fb, fa = facts(before), facts(after)
        deltas = []
        for kind in fb:
            lost = fb[kind] - fa[kind]
            gained = fa[kind] - fb[kind]
            for v, c in lost.items():
                deltas.append((kind, "REMOVED", v, c))
            for v, c in gained.items():
                deltas.append((kind, "ADDED", v, c))
        if not deltas:
            print(f"{rel:30s} text changed, every fact preserved")
            continue
        moved += len(deltas)
        print(f"\n{rel} — {len(deltas)} fact difference(s)")
        for kind, direction, v, c in sorted(deltas):
            shown = v if len(v) <= 70 else v[:67] + "..."
            shown = shown.replace("\n", " \\n ")
            print(f"    {direction:8s} {kind:14s} x{c}  {shown}")

    print(f"\nfiles with text changes: {checked}   fact differences: {moved}")
    if moved:
        print("Read every one. A removed number is a content change, not a wording change.")
        return 1
    print("OK — wording changed, facts did not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
