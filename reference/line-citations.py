#!/usr/bin/env python3
"""
line-citations.py — find every "file:LINE" pointer in the repository and check it.

This repository cites itself by line number constantly: a threat-model
finding names the guard it is about as `contracts/MandateManager.sol:1479`, a
mutation gate's comment records which guard it deliberately skips as
"line 602's `if (!mandate)`", and a design note points at the test that
proves a claim. Those pointers are evidence, and a wording pass that reflows
a comment block moves the code below it, so a pointer that was exact becomes
a pointer at a blank line with nothing to announce the change.

    python3 reference/line-citations.py              # list every citation and what it points at now
    python3 reference/line-citations.py HEAD         # additionally, report drift since HEAD

With a revision argument the check is precise rather than advisory. For each
citation it reads the cited line at that revision and in the working tree; when
the two differ it searches the working tree for the revision's text, and if
that text now appears exactly once it prints the new line number. A citation
whose target text has been rewritten cannot be repaired mechanically and is
reported as needing a reading.

CITATION SHAPES RECOGNISED.

    path/to/File.sol:123        explicit, the common case
    File.sol:123-140            a range; the first number is checked
    `File.sol:123`              inside a code span, identical after the span is stripped
    v2:123                      the v2 convention, anchored below
    ... File.sol ... :123       a bare `:123` attributed to the last filename on the line
    ... File.sol ... line 123   the prose form, attributed the same way

Attribution looks back up to two lines for a filename, because a paragraph often
names the file once and then refers to several lines in it. A `:123` with no
filename in range is reported as unattributed rather than guessed at.

ANCHORED CITATIONS.

Four conventions in this repository point a citation at a historical blob
rather than at the working tree, and each one is declared in the documents
themselves:

    v2:NNN                                    contracts/MandateManager.sol at 92445dd,
                                              declared in THREAT-MODEL.md:9-19
    an unqualified contract line number in    the v1.0.0-arc-testnet tag,
    DESIGN.md, CHANGELIST.md, L3-VAULT.md,    declared in FORGE.md:111-128
    PRIVACY.md, GAS-ABSTRACTION.md,
    IMMUTABILITY.md and evidence/README.md
    an unqualified contract line number in    9fa7ece, declared in scope.md:7
    scope.md
    policy.js, policy.test.js and the         65f05d8 for F27 and F28, af9df40
    contract, cited from THREAT-MODEL.md      for F29 to F37, declared in
                                              THREAT-MODEL.md:172-182 and :203-216

THREAT-MODEL.md:139 states the rule those four conventions share: "Those
deltas are recorded rather than applied, because the numbers are correct as
written against the blob they now name and rewriting them would make them
wrong." A checker that compares such a citation against the working tree
reports drift on a document that is right, and forty such lines in one report
train a reader to skip the report. Each anchored citation is therefore read at
the revision it names and printed with that revision's text, so a reader can
confirm the match by eye.

The table pairs a citing file with a target file, so it exempts the
four declared conventions and nothing else. A pointer from THREAT-MODEL.md
into test/Creation.t.sol, or one from CHANGELIST.md into DESIGN.md, has no
declared anchor and is still checked against the working tree. Ten stale
pointers into DESIGN.md and four into the test tree were found that way and
repaired, along with three that named a revision this repository does not
declare at all.

TRACKED FILES WIN.

The resolver consults git's index before the working tree. The repository root
holds untracked scratch copies of three testnet logs whose committed homes are
under evidence/, and preferring the root copy made five citations in
evidence/README.md report as absent at HEAD, because an untracked file has no
blob at any revision. The set of files to scan and the set of files a citation
may name are therefore separate: scanning follows the working tree, so a
checker added but not yet committed still has its own citations read, while
resolution follows the index.

FALSE POSITIVES ARE EXPECTED AND ARE THE POINT.

A "line 420" quoted inside a pasted tool report is a historical record, not a
pointer into the current tree, and it must stay verbatim even though this check
will call it drifted. Timestamps, version numbers and gas figures in the same
sentence as a filename can also be captured. Read each hit; the value here is
that no pointer goes stale in silence, not that every hit is a defect.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"node_modules", "lib", ".git", "out", "cache", "broadcast"}
SUFFIXES = {".md", ".sol", ".js", ".py", ".toml"}

EXPLICIT = re.compile(r"([\w./-]+\.(?:sol|md|js|py|toml|json|log)):(\d+)")
FILENAME = re.compile(r"[\w./-]+\.(?:sol|md|js|py|toml|json|log)")
BARE = re.compile(r"(?<![\w.]):(\d+)\b|\bline\s+(\d+)\b|\blines\s+(\d+)")
V2 = re.compile(r"\bv2:(\d+)")
SELF = re.compile(r"\blines?\s+(\d+)(?:[-–]\d+)?\s+(?:above|below)\b")
FENCE = re.compile(r"^\s*```")
CONTRACT = "contracts/MandateManager.sol"

# (kind, citing files, target files, revisions, where the convention is declared).
# A kind set to None matches any shape, and an empty citer set matches any citing file.
# The rules are tried in order, so the v2 prefix takes its own anchor even inside a
# file that also declares a different one for the same target.
ANCHORS = [
    ("v2", set(), {CONTRACT}, ["92445dd"], "THREAT-MODEL.md:9-19"),
    (
        None,
        {
            "DESIGN.md",
            "CHANGELIST.md",
            "L3-VAULT.md",
            "PRIVACY.md",
            "GAS-ABSTRACTION.md",
            "evidence/README.md",
            "IMMUTABILITY.md",
        },
        {CONTRACT},
        ["v1.0.0-arc-testnet"],
        "FORGE.md:111-128",
    ),
    (
        None,
        {"scope.md"},
        {CONTRACT},
        ["9fa7ece"],
        "scope.md:7",
    ),
    (
        None,
        {"THREAT-MODEL.md"},
        {"reference/policy.js", "reference/policy.test.js", CONTRACT},
        ["af9df40", "65f05d8"],
        "THREAT-MODEL.md:172-182 and :203-216",
    ),
]

# The subject a bare "line NNN" takes in a file that carries no filename on the line.
# FORGE.md:111-128 names the documents whose unqualified line numbers point into the
# contract, and THREAT-MODEL.md:172-182 does the same for its own `:NNN` form. An
# attribution made this way is an inference from a declared convention rather than a
# citation that names its own file, so its failures are reported as advisory.
DEFAULT_TARGET = {name: CONTRACT for _, citers, _, _, _ in ANCHORS[1:] for name in citers}

# Verbatim quotations of tool output, exempted by their own words rather than by line
# number, because a line number decays the next time the file is edited. Each of these
# is a mutation-gate report or an edit record quoted as printed, so the number inside
# it describes a blob that the report itself names and must stay as written.
QUOTED = (
    "SelfPayment (line 1160)",
    "Expired (line 1136)",
    "? (line 420)",
    "at lines 217",
)

# Placeholder names this file's own documentation uses to show a citation shape. No file
# in the repository answers to either, so they resolve nowhere and would report as an
# unresolved filename on every run.
ILLUSTRATIVE = {"File.sol", "path/to/File.sol"}

_FILES: list[Path] = []
_TRACKED: set[str] = set()
_RESOLVED: dict[str, Path | None] = {}
_REV_CACHE: dict[tuple[str, str], list[str] | None] = {}
_NOW_CACHE: dict[Path, list[str]] = {}


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-c", "safe.directory=*", *args], cwd=ROOT, capture_output=True, text=True
    )


def tracked() -> set[str]:
    """The paths git holds in its index, read once, as repo-relative posix strings."""
    if not _TRACKED:
        r = git("ls-files")
        _TRACKED.update(line.strip() for line in r.stdout.split("\n") if line.strip())
    return _TRACKED


def repo_files():
    """Walked once. The resolver runs per citation and the tree has thousands of entries."""
    if not _FILES:
        _FILES.extend(
            sorted(
                p
                for p in ROOT.rglob("*")
                if p.suffix in SUFFIXES and not any(part in SKIP for part in p.parts)
            )
        )
    return _FILES


def resolve(name: str) -> Path | None:
    """A citation may be repo-relative or a bare basename. Refuse to guess when ambiguous.

    A tracked path wins over an untracked one of the same name, so a scratch copy at the
    repository root cannot shadow the committed file the citation means. A name that no
    tracked path answers to falls back to the working tree, which is how a citation into
    a file that has been written but not yet committed resolves.
    """
    if name in _RESOLVED:
        return _RESOLVED[name]
    rel = name.replace("\\", "/").lstrip("./")
    base = rel.rsplit("/", 1)[-1]
    result: Path | None = None
    if rel in tracked():
        result = ROOT / rel
    else:
        hits = sorted(t for t in tracked() if t.rsplit("/", 1)[-1] == base)
        if len(hits) == 1:
            result = ROOT / hits[0]
        elif not hits:
            direct = ROOT / rel
            loose = [p for p in repo_files() if p.name == base]
            if direct.is_file():
                result = direct
            elif len(loose) == 1:
                result = loose[0]
    _RESOLVED[name] = result
    return result


def lines_now(path: Path) -> list[str]:
    if path not in _NOW_CACHE:
        _NOW_CACHE[path] = path.read_text(encoding="utf-8", errors="replace").split("\n")
    return _NOW_CACHE[path]


def citations(path: Path):
    """Yield (lineno, raw_text, target_name, target_line, kind) for one citing file.

    Five kinds, in the order they are claimed. `v2` is the explicit `v2:NNN` form.
    `explicit` names its own file. `self` is a pointer inside the citing document itself,
    such as "the receipt eight lines below", which names no target and is counted only.
    `bare` takes a filename from elsewhere on the same line. `lookback` takes one from an
    earlier line of the same paragraph, and `default` takes the subject the citing file's
    convention declares, which is how the unqualified `line NNN` form in the seven
    documents listed at FORGE.md:111-128 reaches the contract it means.
    """
    text = path.read_text(encoding="utf-8", errors="replace").split("\n")
    citer_rel = str(path.relative_to(ROOT)).replace("\\", "/")
    default = DEFAULT_TARGET.get(citer_rel)
    recent: list[str] = []
    fenced = False
    for n, raw in enumerate(text, 1):
        if FENCE.match(raw):
            fenced = not fenced
            continue
        if fenced:
            continue
        line = raw.replace("`", "")
        claimed = set()
        for m in V2.finditer(line):
            claimed.add(m.span())
            yield n, raw.strip(), CONTRACT, int(m.group(1)), "v2"
        for m in EXPLICIT.finditer(line):
            if any(s <= m.start() < e for s, e in claimed):
                continue
            claimed.add(m.span())
            yield n, raw.strip(), m.group(1), int(m.group(2)), "explicit"
        for m in SELF.finditer(line):
            claimed.add(m.span())
            yield n, raw.strip(), None, int(m.group(1)), "self"
        names = FILENAME.findall(line)
        window = names or recent
        for m in BARE.finditer(line):
            if any(s <= m.start() <= e for s, e in claimed):
                continue
            num = next(g for g in m.groups() if g)
            if window:
                yield n, raw.strip(), window[-1], int(num), "bare" if names else "lookback"
            else:
                yield n, raw.strip(), default, int(num), "default"

        if names:
            recent = names
        elif not line.strip():
            recent = []


def anchor_for(kind: str, citer: str, target: str):
    """The revisions a citation is anchored to, and where that convention is declared."""
    for k, citers, targets, revs, declared in ANCHORS:
        if k is not None and k != kind:
            continue
        if citers and citer not in citers:
            continue
        if target in targets:
            return revs, declared
    return [], ""


def at_rev(rev: str, rel: str) -> list[str] | None:
    """One `git show` per file, not per citation."""
    key = (rev, rel)
    if key not in _REV_CACHE:
        r = git("show", f"{rev}:{rel}")
        _REV_CACHE[key] = r.stdout.split("\n") if r.returncode == 0 else None
    return _REV_CACHE[key]


def reading(rev: str, rel: str, target: int) -> str:
    """The cited line as it stands in one revision, or "" when it is absent or blank."""
    blob = at_rev(rev, rel)
    if blob is None:
        return ""
    return blob[target - 1].strip() if 0 < target <= len(blob) else ""


def edited_since(rev: str, citer_rel: str, raw: str) -> bool:
    """True when the citing line itself was written or reworded since `rev`.

    Drift compares the cited line at two revisions and reads the difference as the
    target having moved under a pointer that stayed still. A pointer that was itself
    just repaired fails that comparison by construction, since its old target text is
    whatever stood at the number it used to carry. The test is therefore whether the
    citing line survives verbatim at `rev`: a line that does is a still pointer and its
    target is compared, and a line that does not is reported separately for reading.
    Matching anywhere in the file rather than at the same number keeps a reflow above
    the citation from reading as an edit to the citation.
    """
    blob = at_rev(rev, citer_rel)
    if blob is None:
        return True
    body = raw.strip()
    if len(body) < 9:
        return False
    return not any(body == line.strip() for line in blob)



def main() -> int:
    rev = sys.argv[1] if len(sys.argv) > 1 else None
    rows = []
    for path in repo_files():
        for n, raw, name, target, kind in citations(path):
            rows.append((path, n, raw, name, target, kind))

    unattributed = [r for r in rows if r[3] is None and r[5] != "self"]
    quoted = ok = illustrative = selfref = 0
    live, anchored, broken, drifted, unresolved = [], [], [], [], []
    advisory, edited = [], []

    for path, n, raw, name, target, kind in rows:
        if kind == "self":
            selfref += 1
            continue
        if name is None:
            continue
        if name in ILLUSTRATIVE:
            illustrative += 1
            continue
        if any(q in raw for q in QUOTED):
            quoted += 1
            continue
        citer_rel = str(path.relative_to(ROOT)).replace("\\", "/")
        citer = f"{citer_rel}:{n}"
        tgt = resolve(name)
        if tgt is None:
            unresolved.append((citer, name, target))
            continue
        rel = str(tgt.relative_to(ROOT)).replace("\\", "/")
        now = lines_now(tgt)
        current = now[target - 1].strip() if 0 < target <= len(now) else "<past end of file>"
        revs, declared = anchor_for(kind, citer_rel, rel)
        inferred = kind in ("lookback", "default")
        if revs:
            readings = [(a, reading(a, rel, target)) for a in revs]
            if any(text for _, text in readings):
                anchored.append((citer, rel, target, declared, readings, raw, kind))
            elif inferred:
                advisory.append((citer, rel, target, current, raw, "absent at every anchor"))
            else:
                broken.append((citer, rel, target, declared, readings, raw))
            continue
        if rev is None:
            live.append((citer, rel, target, current))
            continue
        if edited_since(rev, citer_rel, raw):
            edited.append((citer, rel, target, current, raw))
            continue
        old = at_rev(rev, rel)
        if old is None:
            live.append((citer, rel, target, f"target absent at {rev}"))
            continue
        was = old[target - 1].strip() if 0 < target <= len(old) else "<past end of file>"
        if was == current:
            ok += 1
            continue
        matches = [i + 1 for i, line in enumerate(now) if line.strip() == was and was]
        suggestion = (
            f"moved to :{matches[0]}"
            if len(matches) == 1
            else (f"now at {matches}" if matches else "target text no longer present — read it")
        )
        row = (citer, rel, target, was, current, suggestion, raw)
        if inferred:
            advisory.append((citer, rel, target, current, raw, suggestion))
        else:
            drifted.append(row)


    print(f"{len(rows)} citation(s) found")
    print(f"    anchored to a declared revision : {len(anchored)}")
    print(f"    quoted tool output, exempt      : {quoted}")
    print(f"    illustrative placeholder names  : {illustrative}")
    print(f"    self-reference inside the citer : {selfref}")
    if rev:
        print(f"    unchanged since {rev:15s} : {ok}")
        print(f"    edited since {rev:18s} : {len(edited)}")
        print(f"    drifted                         : {len(drifted)}")
        print(f"    inferred attribution, advisory  : {len(advisory)}")
    else:
        print(f"    live pointers listed below      : {len(live)}")
    print(f"    unresolved filenames            : {len(unresolved)}")
    print(f"    unattributed bare line numbers  : {len(unattributed)}")
    print(f"    anchored but absent at anchor   : {len(broken)}")

    by_convention: dict[str, dict[str, int]] = {}
    for _, _, _, declared, _, _, kind in anchored:
        seen = by_convention.setdefault(declared, {})
        seen[kind] = seen.get(kind, 0) + 1
    print("\nanchored citations, per declared convention")
    for declared, kinds in sorted(by_convention.items(), key=lambda kv: -sum(kv[1].values())):
        shape = ", ".join(f"{k} {v}" for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]))
        print(f"    {sum(kinds.values()):4d}  declared in {declared}   ({shape})")
    for citer, rel, target, declared, readings, _, kind in anchored:
        shown = "  ".join(f"@{a} {text[:70] or '<absent>'}" for a, text in readings)
        print(f"    {citer:34s} -> {rel}:{target}   [{kind}]")
        print(f"    {'':34s}    {shown}")

    if live:
        print(f"\nlive pointers, checked against the working tree: {len(live)}")
        for citer, rel, target, current in live:
            print(f"    {citer:34s} -> {rel}:{target}")
            print(f"    {'':34s}    now: {current[:92]}")

    if broken:
        print(f"\nanchored citations whose line is absent at every declared anchor: {len(broken)}")
        for citer, rel, target, declared, readings, raw in broken:
            print(f"    {citer}  cites {rel}:{target}   convention declared in {declared}")
            print(f"        tried  : {', '.join(a for a, _ in readings)}")
            print(f"        citing : {raw[:100]}")

    if edited:
        print(f"\ncitations edited since {rev}, so drift against {rev} says nothing: {len(edited)}")
        for citer, rel, target, current, raw in edited:
            print(f"    {citer}  cites {rel}:{target}")
            print(f"        citing : {raw[:100]}")
            print(f"        target : {current[:100]}")

    if advisory:
        print(f"\nattributed by inference rather than by a filename on the line: {len(advisory)}")
        print("Each of these took its target from an earlier line or from the citing file's")
        print("declared subject, so the target may be the wrong file. Read the citing text; a")
        print("repair here is often an attribution rather than a number.")
        for citer, rel, target, current, raw, note in advisory:
            print(f"    {citer}  read as {rel}:{target}   {note}")
            print(f"        citing : {raw[:100]}")
            print(f"        target : {current[:100]}")

    if drifted:
        print(f"\ndrifted since {rev}: {len(drifted)}\n")
        for citer, rel, target, was, current, suggestion, raw in drifted:
            print(f"{citer}  cites {rel}:{target}   {suggestion}")
            print(f"    citing text : {raw[:100]}")
            print(f"    at {rev:8s}: {was[:100]}")
            print(f"    now         : {current[:100]}")
            print()

    if unresolved:
        print(f"unresolved filenames: {len(unresolved)}")
        for citer, name, target in unresolved:
            print(f"    {citer}  {name}:{target}")
    if unattributed:
        print(f"\nunattributed bare line numbers: {len(unattributed)}")
        for path, n, raw, _, target, _ in unattributed:
            print(f"    {path.relative_to(ROOT)}:{n}  :{target}  | {raw[:80]}")
    if drifted or broken:
        print("\nFAIL — read every drifted citation. A quoted tool report stays verbatim,")
        print("a pointer into the current tree gets the new number, and a pointer into a")
        print("declared anchor stays as written.")
        return 1
    if rev is None:
        return 0
    print("\nOK — every live citation still points at the same text, and every anchored")
    print("citation still resolves inside the revision it names.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
