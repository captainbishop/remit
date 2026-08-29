#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Mutation gate for the CONTRACT, run from the project root:
#
#     python3 reference/mutation-gate-sol.py [functionName]     # default: approveCosignFor
#
# WHY THIS EXISTS, and why it is a second file rather than a flag on the first.
#
# `reference/mutation-gate.js` asks whether the JS model's guards are asserted. It found a
# real hole on its first run and it cannot see Solidity at all. So on 2026-08-28 the repo was
# in a lopsided state worth naming plainly: the reference model — which holds no money — was
# mutation-tested, and the contract that will hold an allowance was not. Twelve new Solidity
# tests reported [PASS] and that is all anyone knew about them. A passing test is not evidence
# its assertion bites.
#
# The two mutation gates are deliberately siblings in the same directory, because the second
# is only findable by someone who read the first, and the idea is one idea in two languages.
#
# It checks BOTH directions, because F17 is a claim in both directions.
#
#   REMOVAL   — for each `revert X(...);` inside the target function, rewrite that one
#               statement to `{}`. Valid Solidity in both shapes the file uses (`if (c)
#               revert X();` becomes `if (c) {}`; a bare `revert X();` inside a block becomes
#               `{}`), and it removes only the refusal. A mutant that survives means no test
#               asserts that revert, or a neighbouring guard is shadowing it.
#
#               Shadowing is already present in this file: neutering `BadConfig` leaves a
#               mandate with no cosigner failing one line lower under `NotCosigner`, because
#               the zero address has no cosigner. That is exactly the pair that survived the
#               JS sweep. It should be caught here — `Cosign.t.sol` asserts the two
#               selectors in separate tests — and the interesting outcome is if it is not.
#
#   INJECTION — add a guard the function is REQUIRED NOT to have. Removal cannot reach a
#               "must not refuse" requirement, and F17's harder half is exactly that: a start
#               date in the future, a currently full rolling window and an unfiled ERC-8004
#               credential must all CLEAR, because refusing them turns our caution into
#               someone's unapprovable payment, and each injection must be caught.
#
# A survivor is a HYPOTHESIS, not a verdict. The first window injection written for the JS
# mutation gate compared an object to a BigInt and was never true, so it "survived" while
# proving nothing. Probe a survivor (an `emit log_uint` or a `console.log` in the injected
# line is enough) before believing it.
#
# SAFETY. Every mutation is written into a throwaway copy of the project under the OS temp
# directory; the working tree is never modified. That is a claim, so the script also hashes
# `contracts/MandateManager.sol` before and after and refuses to exit 0 if the two differ.
#
# COST. A full recompile of this tree is ~4s and the suite ~10s wall, so budget ~20 minutes
# for the default 21 mutants. The whole suite runs against every mutant — no --match-path
# shortcut — so "caught" means some named test in the repo noticed, not just a chosen one.

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REL_SRC = Path("contracts") / "MandateManager.sol"
TARGET = sys.argv[1] if len(sys.argv) > 1 else "approveCosignFor"

# The project's established seed. Pinned for the baseline AND every mutant, so a failure is
# attributable to the mutation rather than to a fresh fuzz corpus. See foundry.toml on what
# the seed does and does not pin.
SEED = "5042002"

# ---------------------------------------------------------------- the injections
#
# Keyed by target function, because a guard that must be ABSENT is a property of the specific
# function that must not have it. Each is inserted immediately after the anchor line, which is
# chosen so that `nowTs`, `m`, `mandateId`, `amount` and `recipient` are all already in scope.
# `amount96` is NOT — it is declared later — so these use `amount`.
INJECTIONS = {
    "approveCosignFor": {
        "anchor": "if (m.revoked) revert Revoked();",
        "cases": [
            (
                "a notBefore in the future",
                "        if (nowTs < m.notBefore) revert NotYetValid();",
            ),
            (
                "a currently full rolling window",
                "        for (uint256 _wi = 0; _wi < m.windowCount; ++_wi) {\n"
                "            if (windowRemaining(mandateId, _wi) < amount) revert OverWindowCap(0, 0, 0);\n"
                "        }",
            ),
            (
                "an unfiled ERC-8004 credential",
                "        if (m.flags & F_CREDENTIAL != 0) revert CredentialMissing();",
            ),
            (
                # The maximal version of the wrong design, and the one a reasonable person
                # writes first: only approve what could be spent this second. `policyHeadroom`
                # folds isLive (hence notBefore and expiry), perTxCap, the remaining totalCap
                # and every window into one number, so if the three above were somehow all
                # shadowed this still fires. `Unbounded()` is raised because nothing else in
                # this path can produce it, which makes the mutant unmistakable in the output.
                "the maximal wrong design: approve only what could be spent RIGHT NOW",
                "        if (policyHeadroom(mandateId) < amount) revert Unbounded();",
            ),
        ],
    },
}

# ---------------------------------------------------------------- harness

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# `[^;]*` deliberately stops at the statement terminator, so a one-line `if (c) revert X();`
# loses only the revert and keeps its condition.
REVERT = re.compile(r"revert\s+\w+\s*\([^;]*\);")

# Which test noticed. Anchored on the shape forge actually prints — `] name(` — rather than on
# the contents of the brackets, because the reason inside them can itself contain `]`: a fuzz
# failure ends `counterexample: calldata=0x…, args=[1]]`. The first version of this used
# `\[FAIL[^\]]*\]`, whose character class terminates on the `]` of `args=[1]` and therefore
# matched nothing at all on exactly the lines carrying the most information. It cost only the
# report — `Expired (line 1136)` came back `caught … by: (unnamed)` — but a mutation gate
# whose evidence line degrades with no error is one you stop reading.
KILLER = re.compile(r"\]\s+([A-Za-z_]\w*)\s*\(")


def die(msg, code=2):
    print(f"mutation-gate-sol: {msg}", file=sys.stderr)
    sys.exit(code)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_code(line):
    """A `revert` inside a comment is text, not a guard. This repo's comments discuss reverts
    at length — the prologue of the target function contains the word twice — so a raw grep
    over the line range overcounts by exactly those. Counting text and calling it a count of
    guards is the error this function exists to prevent."""
    s = line.lstrip()
    return not (s.startswith("//") or s.startswith("*") or s.startswith("/*"))


def function_bounds(lines, name):
    """First line of `    function NAME(` through the next line that is exactly `    }`."""
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith(f"    function {name}("))
    except StopIteration:
        die(f"no function {name}( at contract indentation in {REL_SRC}")
    try:
        end = next(i for i, l in enumerate(lines) if i > start and l == "    }")
    except StopIteration:
        die(f"unterminated {name}")
    return start, end


def run_forge(work, lines):
    """Write a mutated contract into the throwaway project, run the whole suite, and report
    whether anything failed. A run with no summary line is INCONCLUSIVE, never "caught" — a
    mutant that does not compile would otherwise read as a pass."""
    (work / REL_SRC).write_text("\n".join(lines), encoding="utf-8")
    env = dict(os.environ, NO_COLOR="1")
    proc = subprocess.run(
        ["forge", "test", "--fuzz-seed", SEED],
        cwd=work, env=env, capture_output=True, text=True,
    )
    out = ANSI.sub("", proc.stdout + proc.stderr)
    m = re.search(r"(\d+) tests passed, (\d+) failed, (\d+) skipped", out)
    if not m:
        tail = [l for l in out.strip().splitlines() if l.strip()][-14:]
        return {"failed": None, "passed": None, "killers": [], "tail": tail}
    seen, killers = set(), []
    for line in out.splitlines():
        if "[FAIL" not in line:
            continue
        for name in KILLER.findall(line):
            if name not in seen:
                seen.add(name)
                killers.append(name)
    return {"failed": int(m.group(2)), "passed": int(m.group(1)), "killers": killers, "tail": []}


# ---------------------------------------------------------------- setup

if shutil.which("forge") is None:
    die("forge is not on PATH. This gate needs it; the JS sibling does not.")

src = ROOT / REL_SRC
if not src.is_file():
    die(f"run me from anywhere, but {REL_SRC} must exist under {ROOT}")

before = sha(src)
original = src.read_text(encoding="utf-8").split("\n")

work = Path(tempfile.mkdtemp(prefix="remit-solmut-"))
for item in ("contracts", "test", "lib", "foundry.toml"):
    s = ROOT / item
    if not s.exists():
        die(f"missing {item} — cannot build a standalone copy of the project")
    if s.is_dir():
        shutil.copytree(s, work / item, symlinks=True)
    else:
        shutil.copy2(s, work / item)
print(f"mutation gate (solidity): {TARGET}")
print(f"  working copy: {work}   (the tree at {ROOT} is never written to)")

# A green baseline is a PRECONDITION, not a result. If the unmutated suite is red, every
# "caught" below is meaningless because the failure was already there.
t0 = time.time()
baseline = run_forge(work, original)
if baseline["failed"] is None:
    print("  baseline did not produce a summary line — the copy does not build:")
    print("\n".join(f"    {l}" for l in baseline["tail"]))
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(2)
if baseline["failed"] != 0:
    print(f"  baseline is NOT green ({baseline['failed']} failing). Fix that first.")
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(2)
print(f"  baseline: {baseline['passed']} passed, 0 failed  ({time.time() - t0:.0f}s)\n")

# ---------------------------------------------------------------- build the mutant list

start, end = function_bounds(original, TARGET)
mutants = []  # (kind, label, lines)

for i in range(start, end + 1):
    line = original[i]
    if "revert " not in line or not is_code(line) or not REVERT.search(line):
        continue
    err = re.search(r"revert\s+(\w+)", line).group(1)
    mutated = list(original)
    mutated[i] = REVERT.sub("{}", line, count=1)
    mutants.append(("removed", f"{err} (line {i + 1})", mutated))

if not mutants:
    shutil.rmtree(work, ignore_errors=True)
    die(f"{TARGET} contains no `revert` guards to mutate")

inj = INJECTIONS.get(TARGET)
if inj:
    anchor = [i for i in range(start, end + 1) if inj["anchor"] in original[i] and is_code(original[i])]
    if len(anchor) != 1:
        shutil.rmtree(work, ignore_errors=True)
        die(f"anchor {inj['anchor']!r} matched {len(anchor)} code lines in {TARGET}; need exactly 1")
    at = anchor[0]
    for label, code in inj["cases"]:
        mutants.append(("injected", label, original[: at + 1] + code.split("\n") + original[at + 1 :]))

# ---------------------------------------------------------------- run

results = []
for n, (kind, label, lines) in enumerate(mutants, 1):
    t = time.time()
    print(f"  [{n:2d}/{len(mutants)}] {kind:8s} {label} ... ", end="", flush=True)
    r = run_forge(work, lines)
    verdict = "INCONCLUSIVE" if r["failed"] is None else ("caught" if r["failed"] > 0 else "SURVIVED")
    print(f"{verdict}  ({time.time() - t:.0f}s)")
    results.append((kind, label, verdict, r))

shutil.rmtree(work, ignore_errors=True)

# ---------------------------------------------------------------- report

print(f"\nmutation gate: {TARGET} — {len(mutants)} mutants, baseline {baseline['passed']} green\n")
bad = []
for kind, label, verdict, r in results:
    print(f"  {verdict:12s} {kind:8s} {label}")
    if verdict == "caught":
        killed = ", ".join(r["killers"][:3]) or "(unnamed)"
        more = f" (+{len(r['killers']) - 3} more)" if len(r["killers"]) > 3 else ""
        print(f"               by: {killed}{more}   [{r['failed']} failing]")
    else:
        bad.append((kind, label, verdict))
        for l in r["tail"]:
            print(f"               {l}")

after = sha(src)
if after != before:
    print(f"\nWORKING TREE WAS MODIFIED — {REL_SRC} no longer matches its hash at startup.")
    print(f"  before {before[:16]}  after {after[:16]}")
    print("  Recover with: git diff contracts/MandateManager.sol   (then git checkout -- it)")
    sys.exit(3)

print()
if not bad:
    print(f"OK — every one of the {len(mutants)} mutants was caught by a named test.")
    sys.exit(0)
print(f"{len(bad)} mutant(s) not caught. Each is a HYPOTHESIS: probe it before believing it,")
print("then either fix the mutant or add the test it is missing.")
sys.exit(1)
