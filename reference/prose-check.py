#!/usr/bin/env python3
"""
prose-check.py — flag unprofessional wording across the repository's prose.

Run it from the repository root:

    python3 reference/prose-check.py            # all prose files
    python3 reference/prose-check.py README.md  # one file

It reports, per file and per category, the lines that match a house-style rule,
and exits 1 if anything matched, so it can run in CI beside vacuity-check.py.

WHY THIS EXISTS.

The documentation in this repository was written across many sessions and drifted
into a recognisable voice: short declarative fragments in sequence, sentences that
define a thing by first saying what it is not, self-conscious asides about which
part of a paragraph is worth keeping, and the word "gated" standing in for a
precise verb. A reader who arrives to evaluate a contract that moves real money
should find a technical document, not a narrated one. A header reading "Status,
honestly" invites the question of which other sections were not.

The rules below are house style, not general English advice. Each category names
the shape it looks for and, where the shape has a legitimate use, what it allows:

  gated            "gated" and "gates" as prose verbs. The tool named "mutation
                   gate", the file Gates.t.sol, and "identity gate" as the name of
                   a contract feature are allowed; "X is gated by Y" is not, because
                   a precise verb always exists — requires, refuses, restricts.
  forced-negation  Defining by denial: "not X, it is Y", "isn't", "doesn't", "no X,
                   no Y". State what is true and stop.
  staccato         Two or more consecutive sentences under six words, sentence
                   fragments, and paragraphs of a single short sentence.
  fluff            honestly, genuinely, truly, obviously, simply put, needless to
                   say, at the end of the day, worth noting, worth keeping.
  meta-narration   Commentary on the writing rather than the subject: "the reusable
                   part", "the lesson", "which is the part worth keeping", "the
                   standing trap", "load-bearing".
  colloquial       somebody, nobody, quietly, silently, basically, pretty much,
                   sort of, on sight.
  confessional     First-person error narration: "the mistake was mine", "I got it
                   wrong", "cost us". Record the correction, not the apology.
  header-tone      Headers carrying any of the above, or ending in a question mark.

The categories are deliberately over-inclusive. A flag is a candidate for reading,
not a verdict; several matches per file will be correct as written, and technical
denials of fact ("the contract does not hold funds") are legitimate and common
here. The point of the script is that nobody has to re-derive the list of shapes
to look for, and that a document cannot quietly drift back into the old voice
without the check going red.
"""

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"node_modules", "lib", ".git", "out", "cache", "broadcast"}
# The style guide has to name the words it bans, so checking it against itself
# reports a hit for every rule it states. Exempt by name, not by a magic comment,
# so the exemption is visible here rather than hidden in the file being skipped.
# This file joined the list when Python docstrings came into scope, for the same
# reason and no other: the category descriptions above quote every banned word.
SKIP_FILES = {"HOUSE-STYLE.md", "prose-check.py"}

GATE_OK = re.compile(
    r"mutation[- ]gate|mutation gate|Gates\.t\.sol|gate-sol|gate\.js|identity gate|"
    r"the gate\b|gate target|gate run|gate log|prose-check|vacuity|"
    # Names, which HOUSE-STYLE exempts because a name is not prose. `credential gate
    # (F31)` is the literal title of a test in reference/policy.test.js, and a document
    # citing it as evidence has to spell it the way the runner prints it. `Gates` with
    # backticks is the Forge suite stem for test/Gates.t.sol, and it appears in
    # per-suite case distributions beside `Creation`, `Bounds`, `Cosign` and `Views`.
    r"credential gate \(F|`Gates`|"
    # The two ERC-8004 checks are declared in contracts/MandateManager.sol as the
    # structs IdentityGate and CredentialGate, and switched on by the flags F_IDENTITY
    # and F_CREDENTIAL. So "the identity gate", "the `F_IDENTITY` gate" and "the two
    # ERC-8004 gates" name a type that exists in the source, which is why they are
    # exempt while "X is gated by Y" stays banned. Renaming them in prose alone would
    # put the documentation at odds with the identifiers a reader compiles.
    r"IdentityGate|CredentialGate|ERC-8004 gate|`F_IDENTITY` gate|`F_CREDENTIAL` gate",
    re.I,
)

# Verbatim quotations from outside this repository, exempted by their own words rather
# than by line number, because a line number decays the next time the file is edited.
# A quotation cannot be reworded without becoming a misquotation, so each of these
# would otherwise be a permanent flag that a reader learns to scroll past.
QUOTED = (
    # Arc's transaction-memos page, quoted in GAS-ABSTRACTION.md and CHANGELIST.md as
    # the reason ERC-4337 cannot carry the memo path.
    "sender spoofing isn't allowed",
    # The banner of the deployed v1 contract, quoted in CHANGELIST.md. Rewording it
    # would misstate what is permanently on chain at the v1 address.
    "both ERC-8004 gates",
)

CHECKS = [
    (
        # The participle and the verb: always replaceable by a precise word.
        "gated-prose",
        re.compile(r"\bgated\b|\bgates\s+(?:the|a|an|it|them|this|that|#)\b|\bgating\b", re.I),
    ),
    (
        # The noun naming a check. Informational: reduce where it reads as jargon.
        "gate-noun",
        re.compile(r"\bgates?\b", re.I),
    ),
    (
        "forced-negation",
        re.compile(
            r"\b(?:is|was|are|were|does|do|did|has|have|had|will|would|can|could)\s+not\s+"
            r"[^.;:]{1,45},\s*(?:it|they|that|this|the)\b"
            r"|\b(?:isn't|wasn't|aren't|weren't|doesn't|don't|didn't|hasn't|haven't|"
            r"won't|wouldn't|can't|couldn't|shouldn't)\b"
            r"|\bnot\s+(?:because|that|a|an|the)\b[^.;:]{0,60}\bbut\b"
            r"|^\s*(?:No|Not)\s+\w+[.,]\s*(?:No|Not)\s+\w+",
            re.I,
        ),
    ),
    (
        "fluff",
        re.compile(
            r"\b(?:honestly|genuinely|truly|frankly|candidly|obviously|simply put|"
            r"needless to say|at the end of the day|in a nutshell|to be fair|"
            r"to be clear|it is worth|worth noting|worth recording|worth keeping|"
            r"worth writing|worth saying|worth reading|worth having|the honest answer|"
            r"make no mistake|the fact of the matter)\b",
            re.I,
        ),
    ),
    (
        "meta-narration",
        re.compile(
            r"\b(?:the reusable part|the part worth|the lesson (?:here|is|the)|"
            r"the takeaway|the standing trap|load-bearing|smoking gun|"
            r"the useful artefact|which is the part|worth recording because|"
            r"the moral|and that is the point|which is why this exists|"
            r"stated once|for the record)\b",
            re.I,
        ),
    ),
    (
        "colloquial",
        re.compile(
            r"\b(?:somebody|anybody|nobody|quietly|silently|basically|pretty much|"
            r"sort of|kind of|on sight|a thing|stuff|messy|nasty|ugly|awkward|"
            r"cheapest|handy|neat|nice)\b",
            re.I,
        ),
    ),
    (
        "confessional",
        re.compile(
            r"\b(?:the mistake was mine|my (?:own )?(?:mistake|error|fault|slip)|"
            r"I (?:got|had|wrote|typed|assumed|missed|forgot|was wrong)|cost us|"
            r"cost me|I should have|my first version|I then|I also)\b"
        ),
    ),
]

FRAG = re.compile(r"^(?:And|But|Which|Because|So|Except|Also|Plus|Hence|Though)\b", re.I)
SENT = re.compile(r"(?<=[.!?])\s+")


def python_prose(path: Path, src: str):
    """Yield (lineno, text) for a Python file's docstrings and `#` comments.

    The comment matcher below understands `//`, `*` and `/*`, which covers Solidity and
    JavaScript and silently covers nothing at all in Python. Every tool in reference/ is
    Python, so the checker was blind to the prose in its own directory: six files, all of
    them documentation-heavy, none of them ever scanned.

    Docstrings are located with `ast` rather than by matching quotes, so a triple-quoted
    string that is not a docstring stays out of scope. Inside a docstring, a line indented
    four or more spaces past the docstring's own margin is treated as a usage example and
    skipped, matching how the markdown branch skips an indented code block.
    """
    lines = src.split("\n")
    try:
        tree = ast.parse(src)
    except SyntaxError:
        tree = None
    doc = set()
    for node in ast.walk(tree) if tree else []:
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", None)
        if not body or not isinstance(body[0], ast.Expr):
            continue
        val = body[0].value
        if not (isinstance(val, ast.Constant) and isinstance(val.value, str)):
            continue
        span = range(body[0].lineno, (body[0].end_lineno or body[0].lineno) + 1)
        base = min(
            (len(lines[i - 1]) - len(lines[i - 1].lstrip()) for i in span if lines[i - 1].strip()),
            default=0,
        )
        for i in span:
            raw = lines[i - 1]
            if raw.strip() and len(raw) - len(raw.lstrip()) < base + 4:
                doc.add(i)
    for n, raw in enumerate(lines, 1):
        s = raw.strip()
        if n in doc:
            body = s.strip('"').strip()
        elif s.startswith("#") and not s.startswith("#!") and not re.match(r"#\s*(type|noqa):", s):
            body = s.lstrip("#").strip()
        else:
            continue
        # A bare `#` separates two paragraphs of a `#` block the way a blank line separates two
        # paragraphs of markdown, so it must not be yielded: `prose_paragraphs` joins any run of
        # consecutive line numbers, and yielding an empty body for the separator made the entire
        # 50-line prologue of reference/mutation-gate-sol.py one paragraph, whose joined text
        # then tripped staccato on the SPDX line beside the usage line.
        if body:
            yield n, body


def prose_lines(path: Path):
    """Yield (lineno, text) for prose only: markdown body, or comments in source.

    Fenced code blocks, tables, link-reference lines and indented code are skipped,
    because a style rule about sentences has nothing to say about a Solidity
    snippet or a column of numbers.
    """
    fenced = False
    src = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".py":
        yield from python_prose(path, src)
        return
    for n, raw in enumerate(src.split("\n"), 1):
        s = raw.strip()
        if s.startswith("```"):
            fenced = not fenced
            continue
        if fenced or not s:
            continue
        if path.suffix == ".md":
            if s.startswith("|") or s.startswith("    ") or raw.startswith("    "):
                continue
            yield n, raw
        else:
            m = re.match(r"\s*(?://+|\*|/\*+)\s?(.*)", raw)
            if m and m.group(1).strip():
                yield n, m.group(1)


BREAK = re.compile(r"^\s*(?:#|-\s|\*\s|\d+[.)]\s|@\w+\b|=+\s*$|-{4,})|// ----|\| ")


def prose_paragraphs(path: Path):
    """Group the lines above into paragraphs, and say which line each word came from.

    Every rule in this file is written against a sentence, and `prose_lines` hands out
    one physical line at a time, so a banned shape that happens to straddle a wrap is
    invisible to it. `contracts/MandateManager.sol` carried one for months: "That is not
    a weaker / control, it is the absence of one wearing its clothes" is a textbook
    forced-negation split across two lines, and no single-line regex could ever see it.

    A paragraph is a maximal run of consecutive prose lines. A header, a list item, a
    numbered item, a doc tag such as @param, a banner rule and a table row each start a
    new one, because each is a separate unit of prose rather than a continuation.

    Yields (bodies, owners): the joined text, and a list the same length as that text
    giving the source line number of every character, so a match can be attributed to
    the line it starts on and tested for whether it crosses a line boundary at all.
    """
    run: list[tuple[int, str]] = []
    for n, text in prose_lines(path):
        if run and (n != run[-1][0] + 1 or BREAK.search(text)):
            if len(run) > 1:
                yield _join(run)
            run = []
        run.append((n, text))
    if len(run) > 1:
        yield _join(run)


def _join(run: list[tuple[int, str]]):
    text, owners = "", []
    for n, body in run:
        piece = body.strip()
        if text:
            text += " "
            owners.append(n)
        text += piece
        owners.extend([n] * len(piece))
    return text, owners


def staccato(text: str):
    """Consecutive very short sentences, or a fragment opener.

    Headers are exempt: a header is meant to be short, and treating "## 4. Findings"
    as two five-word sentences was the detector's own first false positive.
    """
    body = re.sub(r"`[^`]*`", "X", text).strip()
    if body.startswith("#"):
        return None
    body = body.lstrip("*->_ ").strip()
    body = re.sub(r"^\d+[.)]\s*", "", body)
    if not body:
        return None
    if FRAG.match(body) and len(body.split()) < 14:
        return "fragment opener"
    parts = [p for p in SENT.split(body) if p.strip()]
    if len(parts) < 2:
        return None
    short = [p for p in parts if 0 < len(re.sub(r"[^\w\s]", "", p).split()) <= 5]
    if len(short) >= 2:
        return f"{len(short)} sentences under 6 words"
    return None


def scan(path: Path):
    hits = []
    for n, text in prose_lines(path):
        stripped = text.strip()
        if any(q in text for q in QUOTED):
            continue
        is_header = stripped.startswith("#")
        for name, rx in CHECKS:
            m = rx.search(text)
            if not m:
                continue
            if name.startswith("gate") and GATE_OK.search(text):
                continue
            if name == "gate-noun" and CHECKS[0][1].search(text):
                continue  # already reported as the stronger gated-prose hit
            hits.append((n, name, m.group(0).strip(), stripped, is_header))
        s = staccato(text)
        if s:
            hits.append((n, "staccato", s, stripped, is_header))
        if is_header and stripped.rstrip().endswith("?"):
            hits.append((n, "header-tone", "rhetorical header", stripped, True))
    hits += scan_wrapped(path, {(n, name) for n, name, _, _, _ in hits})
    return hits


def scan_wrapped(path: Path, seen: set):
    """The same rules again, over whole paragraphs, for shapes that cross a line break.

    A hit is reported only when the match itself spans two source lines, since anything
    contained in one line was already reported by the pass above. The staccato rule is
    the exception: two short consecutive sentences are a property of the paragraph, so
    it fires whenever the joined text trips it and no constituent line did.
    """
    hits = []
    for text, owners in prose_paragraphs(path):
        if any(q in text for q in QUOTED):
            continue
        for name, rx in CHECKS:
            for m in rx.finditer(text):
                a, b = owners[m.start()], owners[m.end() - 1]
                if a == b:
                    continue
                if name.startswith("gate") and GATE_OK.search(text):
                    continue
                if name == "gate-noun" and CHECKS[0][1].search(text):
                    continue
                frag = " ".join(m.group(0).split())
                hits.append((a, f"{name}-wrapped", frag, f"[{a}-{b}] {frag}", False))
                break
        s = staccato(text)
        if s and not any((n, "staccato") in seen for n in set(owners)):
            hits.append((owners[0], "staccato-wrapped", s, f"[{owners[0]}-{owners[-1]}] {text[:110]}", False))
    return hits


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    listing = "--list" in sys.argv[1:] or len(args) == 1
    if args:
        files = [ROOT / a for a in args]
    else:
        files = sorted(
            p
            for p in ROOT.rglob("*")
            if p.suffix in {".md", ".sol", ".js", ".py", ".toml"}
            and p.name not in SKIP_FILES
            and not any(part in SKIP for part in p.parts)
        )

    total = 0
    per_cat: dict[str, int] = {}
    print(f"{'file':28s} {'hits':>5s}  by category")
    print("-" * 100)
    rows = []
    for path in files:
        if not path.exists():
            print(f"missing: {path}", file=sys.stderr)
            continue
        hits = scan(path)
        if not hits:
            continue
        cats: dict[str, int] = {}
        for _, name, _, _, _ in hits:
            cats[name] = cats.get(name, 0) + 1
            per_cat[name] = per_cat.get(name, 0) + 1
        total += len(hits)
        rows.append((len(hits), path, cats, hits))

    for count, path, cats, _ in sorted(rows, key=lambda r: -r[0]):
        rel = str(path.relative_to(ROOT))
        summary = "  ".join(f"{k} {v}" for k, v in sorted(cats.items(), key=lambda kv: -kv[1]))
        print(f"{rel:28s} {count:5d}  {summary}")

    if listing:
        for _, path, _, hits in sorted(rows, key=lambda r: -r[0]):
            print(f"\n=== {path.relative_to(ROOT)} ===")
            for n, name, frag, line, _ in hits:
                print(f"{n:5d} [{name:15s}] {frag[:28]:28s} | {line[:120]}")

    print("-" * 100)
    print(f"{'TOTAL':28s} {total:5d}")
    for k, v in sorted(per_cat.items(), key=lambda kv: -kv[1]):
        print(f"    {k:18s} {v}")

    headers = [
        (path, n, name, frag, line)
        for _, path, _, hits in rows
        for n, name, frag, line, is_h in hits
        if is_h
    ]
    print(f"\nheaders carrying a flagged shape: {len(headers)}")
    for path, n, name, frag, line in headers:
        print(f"    {str(path.relative_to(ROOT))}:{n}  [{name}] {line[:88]}")

    if total:
        print("\nFAIL — house style rules matched. Each hit is a candidate to read, not a verdict.")
        return 1
    print("\nOK — no flagged shapes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
