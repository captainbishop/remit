#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Mutation gate for the CONTRACT, run from the project root:
#
#     python3 reference/mutation-gate-sol.py [functionName]              # default: approveCosignFor
#     python3 reference/mutation-gate-sol.py createMandate --only 873    # one guard, named by line
#     python3 reference/mutation-gate-sol.py spend --injections          # the must-not-refuse half
#     python3 reference/mutation-gate-sol.py _cosignIsLive --hand        # inside one condition
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
#   HAND      — rewrite one condition, or one loop bound, into a stated wrong version. The other
#               two operators work on whole statements, so neither reaches INSIDE a condition: an
#               `&&` losing a conjunct, a `>` written `>=`, a loop reading one element where it
#               should read every one. Three of this contract's claims sit at exactly that depth.
#               F38's list of four undebitable addresses is one `||` chain, F39's liveness test is
#               one `&&`, and F40's window bound is one comparison inside a loop. Worse, a
#               `private view` helper that holds no `revert` at all offers the removal operator
#               nothing to rewrite, so `_isUndebitable` and `_cosignIsLive` were unreachable by
#               construction until this operator existed. Each case names its before and after
#               text, must match exactly once inside the target, and declares whether it expects
#               to be caught or to survive.
#
# A survivor is a HYPOTHESIS, not a verdict. The first window injection written for the JS
# mutation gate compared an object to a BigInt and was never true, so it "survived" while
# proving nothing. Probe a survivor (an `emit log_uint` or a `console.log` in the injected
# line is enough) before believing it.
#
# Some survivors turn out to be unkillable rather than untested, because the guard below them
# refuses the same input under the same error name. `EQUIVALENT` records those, and it earns the
# right to exist by naming the shadow and refusing to apply when that shadow is gone. Read the
# comment on the table before adding to it; an entry written without probing the fall-through path
# is an exemption with a paragraph attached, which is worse than an unexplained survivor.
#
# SAFETY. Every mutation is written into a throwaway copy of the project under the OS temp
# directory; the working tree is never modified. That is a claim, so the script also hashes
# `contracts/MandateManager.sol` before and after and refuses to exit 0 if the two differ.
#
# COST. Ten runs on 2026-08-30 put this at 18-21s per mutant including its recompile, plus one
# baseline of about the same per target, so a census of the whole contract runs past half an hour.
# That census is 89 removals over 10 targets plus 6 injections, with 6 hand cases on top that the
# two automatic operators cannot build. It was derived on 2026-08-30 by counting mutable `revert`
# lines per target with this script's own `is_code` and `function_bounds`, and it moves whenever a
# guard is added, so re-derive it rather than quoting the figure here. An earlier note guessed ~57s
# per mutant from the compile and suite times measured separately, which overstated it threefold —
# forge caches almost all of that between mutants. The whole suite runs against every mutant, with
# no --match-path shortcut, so "caught" means some named test in the repo noticed rather than a
# chosen one. The hand cases cost the same per mutant, and were added on 2026-08-30.


import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

# Line-buffered, because this script is always run under `tee` and writes to both streams. Block
# buffered stdout against unbuffered stderr puts a `die` message above the header that should
# precede it, which in a log reads as though the tool failed before it started.
sys.stdout.reconfigure(line_buffering=True)


def die(msg, code=2):
    print(f"mutation-gate-sol: {msg}", file=sys.stderr)
    sys.exit(code)


ROOT = Path(__file__).resolve().parent.parent
REL_SRC = Path("contracts") / "MandateManager.sol"


# `--only` narrows a run to guards named by contract line. It exists because the gate's cost is
# per TARGET while the work it provokes is per MUTANT: a survivor is answered by writing one
# test, and confirming that the test bites meant re-running all 24 or 27 mutants of its
# function, eight minutes to settle one question. Both survivors of 2026-08-29 were repaired by
# a single new test each, and what you want next is that one mutant, not its two dozen siblings.
#
# It narrows the run and changes nothing else. The baseline still has to be green, the whole
# suite still runs against the mutant, and a line carrying no mutable `revert` is an error
# rather than a run of zero mutants reporting success. Injections have no line number to name, so
# `--only` skips them and reports that it did.
#
# `--injections` is the same economy for the other direction, and it was added on 2026-08-30 for
# the same reason: F22's new injection needed confirming, and reaching it bare meant 20 mutants of
# `spend` and 25 of `approveCosignFor` for two questions whose answer is one mutant each. It queues
# the target's injections and no removals. Neither flag can stand in for a full run — both print
# their partial scope on the last line, because the census claims in THREAT-MODEL.md rest on bare
# runs and a partial one must not be quotable as though it were.
#
# `--hand` is the third of these, and the only one that can be a target's whole run: two of the
# five functions it reaches hold no `revert` at all, so bare is not an option for them. It queues
# the target's hand cases and nothing else.
def parse_args(argv):
    target, only, inj_only, hand_only = None, None, False, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--only":
            i += 1
            if i >= len(argv):
                die("--only needs one or more contract line numbers, comma- or space-separated")
            only = argv[i]
        elif a.startswith("--only="):
            only = a.split("=", 1)[1]
        elif a == "--injections":
            inj_only = True
        elif a == "--hand":
            hand_only = True
        elif a.startswith("-"):
            die(
                f"unknown option {a!r}. The options are --only LINE[,LINE...], --injections "
                "and --hand"
            )
        elif target is None:
            target = a
        else:
            die(f"unexpected argument {a!r}. One target function per run.")
        i += 1
    if hand_only and (inj_only or only is not None):
        die("--hand builds only the hand cases, so it cannot be combined with the other two")
    if only is not None and inj_only:
        die("--only names removals by line and --injections excludes removals; pick one")
    if only is None:
        return target or "approveCosignFor", None, inj_only, hand_only
    try:
        wanted = {int(x) for x in only.replace(",", " ").split()}
    except ValueError:
        die(f"--only {only!r} is not a list of line numbers")
    if not wanted:
        die("--only was given no line numbers")
    return target or "approveCosignFor", wanted, inj_only, hand_only


TARGET, ONLY, INJ_ONLY, HAND_ONLY = parse_args(sys.argv[1:])

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
    "spend": {
        "anchor": "if (m.revoked) revert Revoked();",
        "cases": [
            (
                # F22, and the reason `SelfPayment`'s condition is the claim rather than its name.
                # F19 refuses `recipient == m.payer` and must; widening it to the spender would
                # forbid a delegate from being paid by its own mandate, which is most of what a
                # mandate is for. Every F19 test still passes under this mutant, so nothing in the
                # F19 block can be the thing that catches it — `test/Bounds.t.sol`'s
                # `test_f22_theSpenderMayBePaidByItsOwnMandate` is.
                "F22: the spender refused as its own recipient",
                "        if (recipient == m.spender) revert SelfPayment();",
            ),
        ],
    },
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
            (
                # The same mutant as `spend`'s, on the mirror. F17's parity test compares the two
                # paths' refusals and would report them in agreement if both grew the guard, so
                # the mirror needs its own case rather than inheriting the one above.
                "F22: the spender refused as its own recipient, on the approval path",
                "        if (recipient == m.spender) revert SelfPayment();",
            ),
        ],
    },
}

# ---------------------------------------------------------------- the hand cases
#
# Keyed by target, like the injections, and each case names the exact source lines it replaces so
# that a rewrite of the guard breaks the case loudly rather than mutating nothing at all. `find`
# is a list of consecutive stripped code lines and has to match exactly once inside the target;
# `replace` supplies the mutant's lines with their own indentation, because a two-line condition
# collapsing to one is the commonest shape here.
#
# `survives` is the difference between this table and the two automatic operators. A hand case is
# written by a reader who already believes something about the code, so the case has to state which
# outcome it expects; most expect to be caught, and the one that expects to survive says why. If a
# test ever kills that one, the gate reports that the recorded reason has stopped being true — the
# same discipline `EQUIVALENT` applies to the removals, for the same reason.
HAND = {
    "_isUndebitable": {
        "cases": [
            {
                # F38's whole finding is that this list was two entries long when the constructor
                # takes four addresses. Each entry is dropped on its own because `Views.t.sol`
                # asserts all four by name for exactly this reason: a list that loses one has to
                # fail on the entry it lost rather than shift the blame to a neighbour.
                "label": "the identity registry falls out of the list",
                "find": [
                    "return a == address(this) || a == address(usdc) || a == address(identityRegistry)",
                    "|| a == address(validationRegistry);",
                ],
                "replace": [
                    "        return a == address(this) || a == address(usdc)"
                    " || a == address(validationRegistry);",
                ],
            },
            {
                "label": "the validation registry falls out of the list",
                "find": [
                    "return a == address(this) || a == address(usdc) || a == address(identityRegistry)",
                    "|| a == address(validationRegistry);",
                ],
                "replace": [
                    "        return a == address(this) || a == address(usdc)"
                    " || a == address(identityRegistry);",
                ],
            },
        ],
    },
    "_cosignIsLive": {
        "cases": [
            {
                # F39 turns on this conjunct and nothing else. Without it a reservation outlives
                # the approval that created it, which is the stranding the finding is named for.
                "label": "the deadline stops being read, so an expired approval reads as live",
                "find": ["return validUntil != 0 && nowTs < validUntil;"],
                "replace": ["        return validUntil != 0;"],
            },
            {
                # The label and the replacement below were crossed with the pair above until the
                # first real run on 2026-08-30, which reported the wrong one of the two as a
                # survivor. A label that does not describe its own replacement is a claim about
                # code that is not being built, so check each against the other when editing here.
                "label": "the empty slot stops being distinguished from a live one",
                "find": ["return validUntil != 0 && nowTs < validUntil;"],
                "replace": ["        return nowTs < validUntil;"],
                "survives": (
                    "`validUntil` is a uint40 and `nowTs` a uint256, so the comparison widens "
                    "`validUntil` to uint256 and a never-approved slot reads 0, which makes "
                    "`nowTs < 0` false for every clock value there is. The conjunct removed here "
                    "therefore refuses the identical input the one left behind refuses, and no "
                    "test can separate them. THREAT-MODEL.md records this mutant as unkillable "
                    "rather than untested."
                ),
            },
        ],
    },
    "approveCosignFor": {
        "cases": [
            {
                # The comparison F40 turns on. `Cosign.t.sol` claims in a comment that a `>=`
                # here would satisfy every other check while refusing the largest payment the
                # mandate allows; this case is that claim run rather than asserted.
                "label": "F40's window cap becomes exclusive, refusing an amount equal to the cap",
                "find": ["if (amount > w.cap) revert OverWindowCap(w.lengthSeconds, w.cap, 0);"],
                "replace": [
                    "            if (amount >= w.cap) revert OverWindowCap(w.lengthSeconds, w.cap, 0);",
                ],
            },
            {
                # A loop that reads one element where it should read every one is the defect the
                # removal operator is least able to see, because every statement in it survives.
                "label": "F40 reads only the first window, so a second window's cap goes unchecked",
                "find": ["for (uint256 wi = 0; wi < m.windowCount; ++wi) {"],
                "replace": ["        for (uint256 wi = 0; wi < 1 && wi < m.windowCount; ++wi) {"],
            },
        ],
    },
}

# ---------------------------------------------------------------- proven equivalences
#
# A mutant that NO test can ever kill, because the guard it neuters refuses the same input under
# the same error name one or two lines lower. Removing it is then unobservable from outside the
# contract, which makes it a permanent property of the code rather than a hole in the suite. The
# two crash-kills recorded in the JS sibling's header are standing findings of the same shape.
#
# Both entries below came out of the 2026-08-30 sweep, and each was probed by reading the fall-
# through path before it was written here. That probe is the entire licence for an entry existing.
#
# THIS IS NOT A SUPPRESSION LIST, and the difference is mechanical rather than a promise. Every
# entry has to name the shadow that makes its mutant unobservable, and the gate declines the entry
# unless that shadow is still present, exactly once, inside the same target. Delete the shadow and
# the exemption lapses on the very next run, which is the regression a plain exemption list hides.
# An entry matching no mutant is reported too, so a claim cannot rot here unread.
#
# Keyed by the mutated line's own source text rather than by its line number, because mutants move:
# `_checkIdentity`'s pair shifted from 1228/1229 to 1234/1235 on a docstring edit that touched no
# code at all.
EQUIVALENT = {
    ("_checkCredential", "revert CredentialMissing();"): {
        "shadow": "if (gotValidator == address(0)) revert CredentialMissing();",
        "why": (
            "A reverting registry leaves all four locals at their zero defaults, so the "
            "zero-validator check refuses the identical call under the identical selector one "
            "line lower. Splitting the two apart would be actively WRONG rather than merely "
            "unnecessary: Arc's live registry was observed on 2026-08-24 to revert with "
            'Error("unknown") for an unset hash, so this catch arm carries the ordinary '
            "not-yet-filed case, and a separate error here would report Arc's commonest "
            "credential state as a registry failure. The header of test/mocks/MockRegistries.sol "
            "records that probe and its three transaction hashes."
        ),
    },
    ("spendableAcross", "if (payer == address(0)) revert UnknownMandate();"): {
        "shadow": "if (p == address(0)) revert UnknownMandate();",
        "why": (
            "The loop's first iteration reads the same storage slot as this hoisted payer read, "
            "and nothing between them can write it, because a view with no external call ahead "
            "of the loop cannot. An empty list returned earlier, so that iteration always runs. "
            "The contract says as much where the guard sits: the re-read at i == 0 is a "
            "deliberate warm SLOAD, bought to keep the loop body uniform, and this redundancy is "
            "what the purchase buys."
        ),
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
    """First line of `    function NAME(` through the next line that is exactly `    }`.

    `constructor` carries no `function` keyword, so it needs its own opener. Without this it
    matched nothing and the gate refused the target outright, which left the contract's only
    defence against a permanently mis-wired deployment — the `if (_usdc == address(0)) revert
    BadConfig();` in the constructor — as the one refusal in the file that the gate could not
    address, and `Creation.t.sol:673` already asserts it. So the omission was in the tooling and
    not in the contract, and this opener is what lets the gate confirm the assertion bites.
    """
    openers = ("    constructor(",) if name == "constructor" else (f"    function {name}(",)
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith(openers))
    except StopIteration:
        die(f"no {name} at contract indentation in {REL_SRC}")
    try:
        end = next(i for i, l in enumerate(lines) if i > start and l == "    }")
    except StopIteration:
        die(f"unterminated {name}")
    return start, end


def shadow_line(name, text):
    """The one code line inside `name` whose stripped source is exactly `text`, or None.

    None is returned both when the shadow has vanished and when it appears more than once, since
    an ambiguous match cannot support a claim about which line does the shadowing. Either answer
    withdraws the equivalence and lets the mutant report as a survivor again, which is the whole
    mechanism that separates `EQUIVALENT` from an exemption list."""
    s, e = function_bounds(original, name)
    hits = [i + 1 for i in range(s, e + 1) if is_code(original[i]) and original[i].strip() == text]
    return hits[0] if len(hits) == 1 else None


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

print(f"mutation gate (solidity): {TARGET}")

# ---------------------------------------------------------------- build the mutant list
#
# Ahead of both the copy and the baseline, because neither can rescue a target name that does
# not exist or an `--only` line that names no guard, and the baseline alone costs 18 seconds. It
# also means no `die` between here and the copy can leak a throwaway tree, because there is not
# one yet.

start, end = function_bounds(original, TARGET)
mutants = []  # (kind, label, lines, key) — key is the mutated line's source text, or None
mutable = []  # every line this target offers, so an --only miss can say what was available

for i in range(start, end + 1):
    line = original[i]
    if "revert " not in line or not is_code(line) or not REVERT.search(line):
        continue
    mutable.append(i + 1)
    if INJ_ONLY or HAND_ONLY or (ONLY is not None and i + 1 not in ONLY):
        continue
    err = re.search(r"revert\s+(\w+)", line).group(1)
    mutated = list(original)
    mutated[i] = REVERT.sub("{}", line, count=1)
    mutants.append(("removed", f"{err} (line {i + 1})", mutated, line.strip()))

if ONLY is not None:
    unmatched = sorted(ONLY - set(mutable))
    if unmatched:
        die(
            f"--only named {unmatched}, which carry no mutable `revert` in {TARGET} "
            f"(lines {start + 1}-{end + 1}). That target offers: {mutable}"
        )

# Looked up here rather than beside the build below, because a `--hand` run of a target with no
# hand cases has to die before anything prints how that run was scoped. A log saying injections
# were skipped, followed by a refusal to run at all, describes a run that never existed.
hand = HAND.get(TARGET)
EXPECT_SURVIVES = {}
if HAND_ONLY and not hand:
    die(
        f"--hand was asked for {TARGET}, which has no HAND entry. The {len(HAND)} targets that "
        f"have one are: {', '.join(sorted(HAND))}. A condition worth mutating by hand is worth "
        f"writing down first, so add the case before running it."
    )

inj = INJECTIONS.get(TARGET)
if INJ_ONLY and not inj:
    die(
        f"--injections was asked for {TARGET}, which has no INJECTIONS entry. A target with no "
        f"must-not-refuse property to state is not the same as one that passes; run it bare for "
        f"its {len(mutable)} removal(s), or write the entry first."
    )
if inj and (ONLY is not None or HAND_ONLY):
    flag = "--only" if ONLY is not None else "--hand"
    print(f"  {flag} is set, so the {len(inj['cases'])} injection(s) for {TARGET} are skipped")
elif inj:
    anchor = [i for i in range(start, end + 1) if inj["anchor"] in original[i] and is_code(original[i])]
    if len(anchor) != 1:
        die(f"anchor {inj['anchor']!r} matched {len(anchor)} code lines in {TARGET}; need exactly 1")
    at = anchor[0]
    if INJ_ONLY:
        print(f"  --injections is set, so the {len(mutable)} removal(s) for {TARGET} are skipped")
    for label, code in inj["cases"]:
        mutants.append(("injected", label, original[: at + 1] + code.split("\n") + original[at + 1 :], None))

# The hand cases. Built only under `--hand`, and a bare run says so rather than leaving them
# out unremarked: a target whose claims sit inside a condition would otherwise produce a full-
# looking census log with those claims never built, which is the one way this tool could mislead.
if hand and not HAND_ONLY:
    print(f"  {len(hand['cases'])} hand case(s) exist for {TARGET} and need --hand; not built here")
elif hand:
    if mutable:
        print(f"  --hand is set, so the {len(mutable)} removal(s) for {TARGET} are skipped")
    for case in hand["cases"]:
        find, repl = case["find"], case["replace"]
        hits = [
            i
            for i in range(start, end + 1 - len(find) + 1)
            if all(is_code(original[i + k]) and original[i + k].strip() == find[k] for k in range(len(find)))
        ]
        if len(hits) != 1:
            die(
                f"hand case {case['label']!r} matched {len(hits)} places in {TARGET}; need exactly "
                f"1. Its first line reads {find[0]!r}. The guard has been rewritten, so the case "
                f"is describing code that is not there and has to be updated before it can run."
            )
        i = hits[0]
        mutants.append(("hand", case["label"], original[:i] + repl + original[i + len(find) :], None))
        if case.get("survives"):
            EXPECT_SURVIVES[case["label"]] = case["survives"]

if not mutants:
    if hand:
        die(
            f"{TARGET} contains no `revert` guards to mutate, which is why it has {len(hand['cases'])} "
            f"hand case(s). Run: python3 reference/mutation-gate-sol.py {TARGET} --hand"
        )
    die(f"{TARGET} contains no `revert` guards to mutate")

# ---------------------------------------------------------------- the throwaway copy

COPY = ("contracts", "test", "lib", "foundry.toml")
for item in COPY:
    if not (ROOT / item).exists():
        die(f"missing {item} — cannot build a standalone copy of the project")

work = Path(tempfile.mkdtemp(prefix="remit-solmut-"))
for item in COPY:
    s = ROOT / item
    if s.is_dir():
        shutil.copytree(s, work / item, symlinks=True)
    else:
        shutil.copy2(s, work / item)
print(f"  working copy: {work}   (the tree at {ROOT} is never written to)")
print(f"  {len(mutants)} mutant(s) queued")

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

# ---------------------------------------------------------------- run

results = []
claimed = set()  # EQUIVALENT keys this run actually reached, so an unmatched one can be reported
for n, (kind, label, lines, key) in enumerate(mutants, 1):
    t = time.time()
    print(f"  [{n:2d}/{len(mutants)}] {kind:8s} {label} ... ", end="", flush=True)
    r = run_forge(work, lines)
    verdict = "INCONCLUSIVE" if r["failed"] is None else ("caught" if r["failed"] > 0 else "SURVIVED")
    eq = EQUIVALENT.get((TARGET, key)) if key else None
    note = None
    at = None
    if eq:
        claimed.add((TARGET, key))
        at = shadow_line(TARGET, eq["shadow"])
        if verdict == "SURVIVED" and at:
            verdict = "EQUIVALENT"
        elif verdict == "SURVIVED":
            note = (
                f"an EQUIVALENT entry claims the shadow {eq['shadow']!r} makes this mutant "
                "unobservable, and that line is no longer present exactly once in "
                f"{TARGET}. The claim has LAPSED, so this counts as a survivor. Either restore "
                "the shadow or write the test the guard now needs."
            )
        elif verdict == "caught":
            note = (
                "an EQUIVALENT entry expected this to survive and a test killed it, so the "
                "entry is stale and should come out. Being caught is the better outcome; the "
                "reason recorded in the entry is what has stopped being true."
            )
    # A hand case carries its own expectation, so the same two-way check applies to it. The
    # difference is that its twin sits on the mutated line rather than below it, which is why
    # there is no shadow line to look up and the verdict is reported without one.
    why = EXPECT_SURVIVES.get(label) if kind == "hand" else None
    if why and verdict == "SURVIVED":
        verdict = "EQUIVALENT"
        eq = {"shadow": None, "why": why}
    elif why and verdict == "caught":
        note = (
            "this hand case was written expecting to survive and a test killed it, so the reason "
            "recorded with the case has stopped being true and the case needs rewriting. Being "
            "caught is the better outcome of the two."
        )
    print(f"{verdict}  ({time.time() - t:.0f}s)")
    results.append((kind, label, verdict, r, eq, at, note))

shutil.rmtree(work, ignore_errors=True)

# ---------------------------------------------------------------- report

print(f"\nmutation gate: {TARGET} — {len(mutants)} mutants, baseline {baseline['passed']} green\n")
bad = []
for kind, label, verdict, r, eq, at, note in results:
    print(f"  {verdict:12s} {kind:8s} {label}")
    if verdict == "caught":
        killed = ", ".join(r["killers"][:3]) or "(unnamed)"
        more = f" (+{len(r['killers']) - 3} more)" if len(r["killers"]) > 3 else ""
        print(f"               by: {killed}{more}   [{r['failed']} failing]")
    elif verdict == "EQUIVALENT":
        if eq["shadow"] is None:
            print("               unkillable rather than untested:")
        else:
            print(f"               shadowed by line {at}: {eq['shadow']}")
        for para in textwrap.wrap(eq["why"], 84):
            print(f"               {para}")
    else:
        bad.append((kind, label, verdict))
        for l in r["tail"]:
            print(f"               {l}")
    if note:
        for para in textwrap.wrap(note, 84):
            print(f"               NOTE: {para}")

stale = []
for k in sorted(set(EQUIVALENT) - claimed):
    # A narrowed run reaches only some of the target's mutated lines, so an entry it never touched
    # is unexamined rather than stale. Reporting it as stale would teach the reader to ignore the
    # warning on the bare runs, where it means something.
    if k[0] != TARGET or ONLY is not None or INJ_ONLY:
        continue
    stale.append(k)
    print(f"\n  STALE ENTRY  EQUIVALENT names {k[1]!r} in {TARGET}, and no mutant this run carried")
    print("               that text. The line has been edited or removed, so the entry is now")
    print("               describing code that is not there. Delete it or update its key.")

after = sha(src)
if after != before:
    print(f"\nWORKING TREE WAS MODIFIED — {REL_SRC} no longer matches its hash at startup.")
    print(f"  before {before[:16]}  after {after[:16]}")
    print("  Recover with: git diff contracts/MandateManager.sol   (then git checkout -- it)")
    sys.exit(3)

print()
eqs = [label for _kind, label, verdict, _r, _eq, _at, _note in results if verdict == "EQUIVALENT"]
if not bad:
    # Two different claims, never merged into one sentence. A mutant a test killed and a mutant no
    # test could kill are both acceptable outcomes, and reporting the second as the first is how
    # the gate would start overstating what it knows.
    if not eqs:
        subject = "the one mutant was" if len(mutants) == 1 else f"all {len(mutants)} mutants were"
        print(f"OK — {subject} caught by a named test.")
    else:
        caught_n = len(mutants) - len(eqs)
        print(f"OK — {caught_n} of {len(mutants)} mutants were caught by a named test, and {len(eqs)}")
        print("     could not be by any test that could be written:")
        for label in eqs:
            print(f"       EQUIVALENT  {label}")
        print("     Each removal there neuters a guard whose successor refuses the same input under")
        print("     the same error name, and each hand case there drops a conjunct whose twin on the")
        print("     same line already refuses everything it would have. Every shadow a removal leans")
        print("     on was looked up above, and the exemption lapses if it disappears.")
    if stale:
        # Said again down here because the warning is easy to scroll past, and a reader who stops
        # at the last line would otherwise take a bookkeeping problem for a clean run.
        print(f"     {len(stale)} EQUIVALENT entr(y/ies) above no longer match any mutant. Verification")
        print("     is unaffected and the table needs an edit.")
    # The scope of the claim, on the same screen as the claim. A narrowed run says nothing about the
    # mutants it did not build, and this line is what stops its log being quoted as a clean target.
    if INJ_ONLY:
        print(f"     SCOPE: injections only. {TARGET}'s {len(mutable)} removal(s) were not built,")
        print("     so this run is not a census of the target. Run it bare for that.")
    elif ONLY is not None:
        print(f"     SCOPE: --only. {len(mutable) - len(mutants)} other removal(s) and every injection")
        print(f"     for {TARGET} were not built, so this run is not a census of the target.")
    elif HAND_ONLY:
        other = len(mutable) + (len(inj["cases"]) if inj else 0)
        if other:
            print(f"     SCOPE: hand cases only. {other} removal(s) and injection(s) for {TARGET}")
            print("     were not built, so this run is not a census of the target.")
        else:
            print(f"     SCOPE: hand cases only, and they are everything {TARGET} offers — it holds")
            print("     no `revert` and has no injections, so this run does cover the whole target.")
    sys.exit(0)
print(f"{len(bad)} mutant(s) not caught. Each is a HYPOTHESIS: probe it before believing it,")
print("then either fix the mutant or add the test it is missing.")
sys.exit(1)
