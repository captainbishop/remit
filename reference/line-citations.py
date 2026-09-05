#!/usr/bin/env python3
"""
line-citations.py — find every "file:LINE" pointer in the repository and check it.

This repository cites itself by line number constantly: a threat-model
finding names the guard it is about as `File.sol:1479`, a mutation gate's
comment records which guard it deliberately skips as "line 602's
`if (!mandate)`", and a design note points at the test that proves a claim.
Those pointers are evidence, and a wording pass that reflows a comment block
moves the code below it, so a pointer that was exact becomes a pointer at a
blank line with nothing to announce the change.

    python3 reference/line-citations.py              # list every citation, and check every quotation
    python3 reference/line-citations.py HEAD         # additionally, report drift since HEAD

With a revision argument the drift check is precise rather than advisory. For each
citation it reads the cited line at that revision and in the working tree; when
the two differ it searches the working tree for the revision's text, and if
that text now appears exactly once it prints the new line number. A citation
whose target text has been rewritten cannot be repaired mechanically and is
reported as needing a reading.

Both forms run the quotation check, and either can fail on it. A pointer into a
document is otherwise watched for movement and never for meaning, so a pointer
that lands on real but unrelated prose reports clean for as long as that prose
holds still. Two checks do reach past movement: where the citing sentence
attributes a quotation of four words or more to the target, the words themselves
say which line is meant and the run fails when they are not within reach of the
number, and a number landing on a blank line or past the end of the file cites
nothing at all, which fails whether the target is a declared anchor or the
working tree.

CITATION SHAPES RECOGNISED.

    path/to/File.sol:123        explicit, the common case
    File.sol:123-140            a range; the first number is checked
    `File.sol:123`              inside a code span, identical after the span is stripped
    v2:123                      the v2 convention, anchored below
    ... File.sol ... :123       a bare `:123`, owned by the nearest filename before it
    ... File.sol ... line 123   the prose form, attributed the same way, and `Line 123` too

Attribution looks back to the start of the paragraph for a filename, because a
paragraph often names the file once and then refers to several lines in it. A
filename standing after the number does not own it, since a sentence that names
two files usually cites a line in the first and mentions the second afterwards.
That reach is wide enough to capture a number meant for the file the citing
document declares as its subject, so write the pointer explicitly when its
paragraph names some other document. A `:123` with no filename in range is
reported as unattributed rather than guessed at.

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
    an unqualified contract line number in    58ef048, declared in scope.md:4-7
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
BARE = re.compile(r"(?<![\w.]):(\d+)\b|\bline\s+(\d+)\b|\blines\s+(\d+)", re.I)
V2 = re.compile(r"\bv2:(\d+)")
SELF = re.compile(r"\blines?\s+(\d+)(?:[-–]\d+)?\s+(?:above|below)\b", re.I)
FENCE = re.compile(r"^\s*```")
QUOTE_MARK = re.compile("[“”\"]")
ELLIPSIS = re.compile(r"…|\.\.\.")
BLOCKQUOTE = re.compile(r"^\s*(?:>\s*)+")
# A quotation is only a quotation of the target when the citing sentence says so. Without a
# verb of attribution the marks are scare quotes, a term being defined, or the citing
# document quoting its own earlier wording, and none of those are claims about the target.
SAYING = re.compile(
    r"\b(?:say|says|said|read|reads|state|states|stated|note|notes|noted|record|records"
    r"|recorded|conclude|concludes|concluded|quote|quotes|quoted|call|calls|called"
    r"|describe|describes|described|dismiss|dismisses|dismissed|put|puts|warn|warns"
    r"|warned|answer|answers|answered|require|requires|required)\b",
    re.I,
)
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
        ["58ef048"],
        # The pointer names the sentence that states the convention rather than the line
        # holding the revision, because that line is rewritten at every re-anchor and a
        # pointer at it comes back drifted each time. This entry read 2847c76 until
        # scope.md was re-anchored on 2026-09-05 and the drift report caught it.
        "scope.md:4-7",
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
#
# The docstring above uses one for a second reason, learned on 2026-08-30. It had shown
# the shape with a real filename and a real line number, which makes it a live citation
# this tool then follows, and it had been wrong for long enough that no one could say
# when: `:1479` was `address recipient,` rather than any guard, and the "line 602" beside
# it was where `reference/policy.js` held that guard at `af9df40`, which the file has
# since left behind. An illustration carries no evidence, so it should carry no target
# either. A count of how far a pointer has drifted is itself a pointer, and dates the
# same way.
ILLUSTRATIVE = {"File.sol", "File.md", "path/to/File.sol"}

_FILES: list[Path] = []
_TRACKED: set[str] = set()
_RESOLVED: dict[str, Path | None] = {}
_REV_CACHE: dict[tuple[str, str], list[str] | None] = {}
_NOW_CACHE: dict[Path, list[str]] = {}
_QUOTE_CACHE: dict[Path, list[tuple[int, int, str, int, int]]] = {}


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
    """Yield (lineno, raw_text, target_name, target_line, kind, col) for one citing file.

    Five kinds, in the order they are claimed. `v2` is the explicit `v2:NNN` form.
    `explicit` names its own file. `self` is a pointer inside the citing document itself,
    such as "the receipt eight lines below", which names no target and is counted only.
    `bare` takes a filename from elsewhere on the same line. `lookback` takes one from an
    earlier line of the same paragraph, and `default` takes the subject the citing file's
    convention declares, which is how the unqualified `line NNN` form in the seven
    documents listed at FORGE.md:111-128 reaches the contract it means.

    `col` is where the pointer sits on the backtick-stripped line. It exists so a quotation
    can be attributed to the pointer nearest it rather than to every pointer nearby.
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
            yield n, raw.strip(), CONTRACT, int(m.group(1)), "v2", m.start()
        for m in EXPLICIT.finditer(line):
            if any(s <= m.start() < e for s, e in claimed):
                continue
            claimed.add(m.span())
            yield n, raw.strip(), m.group(1), int(m.group(2)), "explicit", m.start()
        for m in SELF.finditer(line):
            claimed.add(m.span())
            yield n, raw.strip(), None, int(m.group(1)), "self", m.start()
        found = [(m.start(), m.group(0)) for m in FILENAME.finditer(line)]
        names = [name for _, name in found]
        for m in BARE.finditer(line):
            if any(s <= m.start() <= e for s, e in claimed):
                continue
            num = next(g for g in m.groups() if g)
            # The nearest filename at or before the pointer owns it, not the last one on
            # the line. A sentence that names one file, cites a line in it, and then names
            # a second file otherwise hands that number to the second file, which usually
            # holds a line at the same number and so reports clean.
            before = [name for start, name in found if start <= m.start()]
            if before:
                yield n, raw.strip(), before[-1], int(num), "bare", m.start()
            elif recent:
                yield n, raw.strip(), recent[-1], int(num), "lookback", m.start()
            else:
                yield n, raw.strip(), default, int(num), "default", m.start()

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


def norm(text: str) -> str:
    """Compare prose the way a reader does.

    Backticks, emphasis, wrapping, case and the blockquote markers that begin a line inside
    a quoted block are all presentation. A quotation lifted out of a blockquote loses the
    `> ` at each wrap, so a comparison that keeps them fails on text that matches.
    """
    plain = " ".join(BLOCKQUOTE.sub("", ln) for ln in text.split("\n"))
    return " ".join(plain.replace("`", "").replace("*", "").split()).lower()


def paragraph_quotes(path: Path) -> list[tuple[int, int, str, int, int]]:
    """Every quoted phrase of four words or more, with the paragraph that holds it.

    Returns (line, col, phrase, first, last). A quotation is attributed to a citation by
    proximity, so the search has to know where the paragraph begins and ends: a quotation
    further down the page belongs to some other pointer, or to none. Positions are measured
    on the backtick-stripped line, which is the coordinate space `citations` reports.
    """
    if path in _QUOTE_CACHE:
        return _QUOTE_CACHE[path]
    out: list[tuple[int, int, str, int, int]] = []

    def flush(block: list[tuple[int, str]]) -> None:
        if not block:
            return
        first, last = block[0][0], block[-1][0]
        joined, origin = "", []
        for n, body in block:
            if joined:
                joined += " "
                origin.append((n, 0))
            joined += body
            origin.extend((n, i) for i in range(len(body)))
        # Quotation marks pair, so the odd segments of a split are the quotations and the
        # even ones are the prose around them. A regex reading mark-to-mark cannot tell the
        # difference and will happily return the gap between two quotations as a third.
        cut = [(m.start(), m.end()) for m in QUOTE_MARK.finditer(joined)]
        for i in range(0, len(cut) - 1, 2):
            start, stop = cut[i][1], cut[i + 1][0]
            phrase = joined[start:stop]
            if len(phrase) >= 16 and len(phrase.split()) >= 4:
                qline, qcol = origin[start]
                out.append((qline, qcol, phrase, first, last))

    para: list[tuple[int, str]] = []
    fenced = False
    for n, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").split("\n"), 1):
        if FENCE.match(raw):
            fenced = not fenced
            flush(para)
            para = []
        elif fenced:
            continue
        elif raw.strip():
            para.append((n, raw.replace("`", "")))
        else:
            flush(para)
            para = []
    flush(para)
    _QUOTE_CACHE[path] = out
    return out


def phrase_present(phrase: str, blob: list[str], target: int, span: int = 4) -> bool:
    """True when the quoted words stand at the cited line, allowing for a wrap.

    A quotation out of a wrapped document spans two or three lines and the pointer names
    the line it starts on, so the window opens one line early and closes four late rather
    than reading the cited line alone. An elided quotation is satisfied when every
    fragment long enough to be evidence appears inside that window.
    """
    lo, hi = max(1, target - 1), min(len(blob), target + span)
    if lo > hi:
        return False
    hay = norm("\n".join(blob[lo - 1 : hi]))
    parts = [p for p in ELLIPSIS.split(phrase) if len(p.split()) >= 4] or [phrase]
    return all(norm(p) in hay for p in parts)


def phrase_locate(phrase: str, blob: list[str], span: int = 4) -> int | None:
    """Where the quoted words do stand, when they are not where the pointer says.

    A wrapped quotation matches from any window that contains it, and the first such window
    opens up to `span` lines above the words themselves. The line a reader wants is the one
    the phrase begins on, so the scan keeps sliding while the match survives.
    """
    part = next((p for p in ELLIPSIS.split(phrase) if len(p.split()) >= 4), phrase)
    needle = norm(part)
    for i in range(len(blob)):
        if needle in norm("\n".join(blob[i : i + span])):
            while i + 1 < len(blob) and needle in norm("\n".join(blob[i + 1 : i + 1 + span])):
                i += 1
            return i + 1
    return None


def owning_citation(
    quote: tuple[int, int, str, int, int], rows: list[tuple], stripped: list[str]
) -> tuple | None:
    """The pointer whose sentence introduces this quotation, or None.

    A paragraph often carries several pointers and several quotations, and testing every
    quotation against every pointer reports a failure for each pair that was never a claim.
    A citation owns a quotation only when it stands just before it — same line, or up to two
    lines earlier where the sentence wraps — and when the words in between attribute the
    quotation to it, which is what `File.md:262 reads "…"` does and a bare mention does not.
    A quotation with no pointer before it, or with nothing but connective prose in between,
    is a claim about something else: the citing document's own earlier wording, a term being
    introduced, or what a passage used to say before it was corrected.
    """
    qline, qcol, _, first, last = quote
    here = [
        r
        for r in rows
        if first <= r[1] <= last and qline - 2 <= r[1] and (r[1], r[6]) <= (qline, qcol)
    ]
    if not here:
        return None
    row = here[-1]
    pline, pcol = row[1], row[6]
    if pline == qline:
        gap = stripped[qline - 1][pcol:qcol]
    else:
        mid = " ".join(stripped[pline:qline - 1])
        gap = stripped[pline - 1][pcol:] + " " + mid + " " + stripped[qline - 1][:qcol]
    if len(gap) > 160 or not SAYING.search(gap):
        return None
    return row



def main() -> int:
    rev = sys.argv[1] if len(sys.argv) > 1 else None
    rows = []
    for path in repo_files():
        for n, raw, name, target, kind, col in citations(path):
            rows.append((path, n, raw, name, target, kind, col))

    unattributed = [r for r in rows if r[3] is None and r[5] != "self"]
    quoted = ok = illustrative = selfref = 0
    live, anchored, broken, drifted, unresolved = [], [], [], [], []
    advisory, edited, checkable, nothing = [], [], [], []

    for path, n, raw, name, target, kind, col in rows:
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
        checkable.append((path, n, raw, name, target, kind, col, rel, revs))
        if revs:
            readings = [(a, reading(a, rel, target)) for a in revs]
            if any(text for _, text in readings):
                anchored.append((citer, rel, target, declared, readings, raw, kind))
            elif inferred:
                advisory.append((citer, rel, target, current, raw, "absent at every anchor"))
            else:
                broken.append((citer, rel, target, declared, readings, raw))
            continue
        # An anchored citation whose line is blank at every anchor fails above. Give a live
        # citation the same verdict: a number that lands on a blank line or past the end of its
        # file cites nothing, whatever the sentence around it claims, and that holds in both
        # modes. Two exemptions apply, both of them narrow: a pointer attributed by inference
        # may simply name the wrong file, so it takes the advisory route this file already uses
        # for that doubt, and a `.log` target is a run's output, where a number beside a
        # filename is a gas figure or a mandate id rather than a position in a file.
        if not current or current == "<past end of file>":
            note = (
                f"past the end of a {len(now)}-line file"
                if target > len(now)
                else "a blank line"
            )
            if tgt.suffix != ".log":
                if inferred:
                    advisory.append((citer, rel, target, current, raw, note))
                else:
                    nothing.append((citer, rel, target, note, raw))
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

    # A pointer into a document is watched for movement, never for meaning: the report
    # prints the target's current text and the verdict ignores it, so five pointers once
    # sat on unrelated prose through clean runs. Where the citing sentence quotes the
    # target verbatim, the words themselves say which line is meant, and that is checkable.
    # Both ends of the check are markdown: a quotation mark inside a Python or Solidity
    # file delimits a string literal rather than a quotation, and a line of source carries
    # comment and box-drawing furniture that no quotation of it would reproduce.
    misquoted = []
    quotes_tested = 0
    prose = [c for c in checkable if c[0].suffix == ".md" and c[7].endswith(".md")]
    for path in sorted({c[0] for c in prose}):
        here = sorted((c for c in prose if c[0] == path), key=lambda c: (c[1], c[6]))
        stripped = [
            ln.replace("`", "")
            for ln in path.read_text(encoding="utf-8", errors="replace").split("\n")
        ]
        for quote in paragraph_quotes(path):
            owner = owning_citation(quote, here, stripped)
            if owner is None:
                continue
            _, n, raw, _, target, _, _, rel, revs = owner
            blob, where = None, ""
            for a in revs:
                candidate = at_rev(a, rel)
                if candidate and 0 < target <= len(candidate):
                    blob, where = candidate, f"@{a}"
                    break
            if not revs:
                blob, where = lines_now(ROOT / rel), "in the working tree"
            if blob is None:
                continue
            quotes_tested += 1
            phrase = quote[2]
            if phrase_present(phrase, blob, target):
                continue
            name = str(path.relative_to(ROOT)).replace("\\", "/")
            misquoted.append(
                (f"{name}:{n}", rel, target, where, phrase, phrase_locate(phrase, blob), raw)
            )

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
    print(f"    live pointer landing on nothing : {len(nothing)}")
    print(f"    verbatim quotations checked     : {quotes_tested}")

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

    if nothing:
        print(f"\nlive pointers that land on nothing: {len(nothing)}\n")
        print("The number names a blank line, or a line past the end of the file. A citation")
        print("like this cites nothing at all, so the sentence around it is unsupported until")
        print("the pointer is read and renumbered against the file as it stands now.\n")
        for citer, rel, target, note, raw in nothing:
            print(f"{citer}  cites {rel}:{target}   {note}")
            print(f"    citing text : {raw[:100]}")
            print()

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
        for path, n, raw, _, target, _, _ in unattributed:
            print(f"    {path.relative_to(ROOT)}:{n}  :{target}  | {raw[:80]}")

    if misquoted:
        print(f"\nquotations absent from the line they cite: {len(misquoted)}\n")
        print("The citing sentence quotes its target verbatim, and the words are not at the")
        print("number it names. Either the pointer has moved off them or the quotation is")
        print("attributed to the wrong file; the words decide which, so read them.\n")
        for citer, rel, target, where, phrase, at, raw in misquoted:
            found = f"the words stand at :{at}" if at else "the words are not in that file"
            print(f"{citer}  cites {rel}:{target} {where}   {found}")
            print(f"    citing text : {raw[:100]}")
            print(f"    quoted      : {phrase[:100]}")
            print()

    if drifted or broken or misquoted or nothing:
        print("\nFAIL — read every drifted citation. A quoted tool report stays verbatim,")
        print("a pointer into the current tree gets the new number, and a pointer into a")
        print("declared anchor stays as written.")
        return 1
    if rev is None:
        return 0
    print("\nOK — every live citation still points at the same text, every anchored citation")
    print("still resolves inside the revision it names, and every verbatim quotation stands")
    print("at the line that cites it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
