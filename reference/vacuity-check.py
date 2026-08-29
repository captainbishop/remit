#!/usr/bin/env python3
"""
vacuity-check.py — confirm that every test in test/ asserts something.

A test body has no adversary. The only way it can hurt you is by passing without
asserting anything, so this is the one sweep over the test suite that is worth
mechanising. Run it from the repository root:

    python3 reference/vacuity-check.py

It prints a case count, the assertion-bearing helpers it discovered, the
assertion volume, the vm.expectRevert breakdown, the custom-error orphan check,
and a list of any test whose body cannot be shown to assert. Exit status is 1 if
anything is vacuous or any error is orphaned, so it is usable in CI.

WHY IT IS WRITTEN THIS WAY.

Two earlier versions of this check hand-listed the assertion vocabulary, and both
were wrong in the same direction. The first searched test bodies for the literal
string "expectRevert" and reported nineteen false positives, because most denials
in this suite route through Base.t.sol's payReverts helper, which contains no such
string. The second added payReverts and a few others to the list, and two months of
refactoring later it reported eight false positives, because five more helpers had
been written in the meantime. A hand-maintained vocabulary decays every time
someone factors a repeated assertion out of a test.

This version derives the vocabulary instead. It extracts every function body
under test/ by brace matching, seeds a set with the bodies that contain a Forge
assertion primitive, then closes that set under calling — a function that calls
a member of the set is itself a member — and only walks the tests afterwards. A
helper written tomorrow is found tomorrow. A helper that stops asserting drops
out on its own, which is how trySpend came to be excluded: it makes a low-level
call and hands back (ok, err) for the caller to judge, so crediting it as an
assertion would let a test spend and assert nothing while passing this check.

The rule both earlier versions establish: a vacuity check has to know the
harness's vocabulary, or it measures the harness instead of the tests.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_DIR = ROOT / "test"
CONTRACT = ROOT / "contracts" / "MandateManager.sol"

# A body containing one of these asserts by itself, with no help from the harness.
PRIMITIVE = re.compile(
    r"\bassert\w*\s*\(|vm\.expectRevert|vm\.expectEmit|vm\.expectCall|vm\.expectPartialRevert"
)
FUNC = re.compile(r"\n\s*function\s+(\w+)\s*\(")
CALL = re.compile(r"\b(\w+)\s*\(")
CONTRACT_DECL = re.compile(r"^(abstract contract|contract|library|interface)\s+(\w+)", re.M)
CASE_DECL = re.compile(r"function\s+(?:test|invariant_)\w*")


def suites(code: str):
    """Count the concrete contracts in one file that declare cases.

    Forge reports "Ran N test suites" where a suite is a CONTRACT, not a file, and
    the two counts differ here: ArcParity.t.sol holds four one-case contracts over
    a shared abstract base, and WindowInvariant.t.sol holds a handler with none. So
    eleven files, thirteen suites and 207 cases are all correct simultaneously.
    This is derived rather than typed because the hand-typed version of this number
    was the one figure in the last threat-model pass that came out wrong.
    """
    marks = [(m.start(), m.group(1)) for m in CONTRACT_DECL.finditer(code)]
    found = []
    for i, (pos, kind) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(code)
        if kind != "abstract contract" and CASE_DECL.search(code[pos:end]):
            found.append(CONTRACT_DECL.match(code[pos:]).group(2))
    return found


def strip_comments(src: str) -> str:
    """Comments discuss errors and helpers in prose. A grep counts text, not code."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def function_bodies(src: str):
    """Yield (name, body) by matching braces from the first { after each signature."""
    for m in FUNC.finditer(src):
        open_brace = src.find("{", m.end())
        semicolon = src.find(";", m.end())
        if open_brace < 0:
            continue
        if semicolon != -1 and semicolon < open_brace:
            continue  # a declaration with no body: interface or abstract
        depth = 0
        i = open_brace
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield m.group(1), src[open_brace + 1 : i]


def main() -> int:
    files = sorted(TEST_DIR.rglob("*.sol"))
    if not files:
        print(f"no .sol files under {TEST_DIR}", file=sys.stderr)
        return 2

    bodies: dict[str, list[str]] = {}
    declared_in: dict[str, set[str]] = {}
    per_file: dict[str, tuple[int, int]] = {}
    suite_names: dict[str, list[str]] = {}
    all_code = ""

    for path in files:
        raw = path.read_text(encoding="utf-8", errors="replace")
        code = strip_comments(raw)
        all_code += code + "\n"
        per_file[path.name] = (
            len(re.findall(r"function\s+test\w*", code)),
            len(re.findall(r"function\s+invariant_\w*", code)),
        )
        suite_names[path.name] = suites(code)
        for name, body in function_bodies(raw):
            bodies.setdefault(name, []).append(body)
            declared_in.setdefault(name, set()).add(path.name)

    names = set(bodies)
    calls = {
        n: {c for b in bs for c in CALL.findall(b) if c in names and c != n}
        for n, bs in bodies.items()
    }

    # Seed with the bodies that assert on their own, then close under calling.
    bearing = {n for n, bs in bodies.items() if any(PRIMITIVE.search(b) for b in bs)}
    changed = True
    while changed:
        changed = False
        for n in names - bearing:
            if calls[n] & bearing:
                bearing.add(n)
                changed = True

    cases = sorted(n for n in names if n.startswith(("test", "invariant_")))
    vacuous = [n for n in cases if n not in bearing]
    helpers = sorted(bearing - set(cases))

    print(f"cases walked: {len(cases)}")
    total_t = sum(t for t, _ in per_file.values())
    total_i = sum(i for _, i in per_file.values())
    print(f"  = {total_t} named test* + {total_i} named invariant_ = {total_t + total_i}")
    total_s = sum(len(v) for v in suite_names.values())
    n_cases_files = sum(1 for v in per_file.values() if sum(v))
    n_test_files = sum(1 for f in files if f.name.endswith(".t.sol"))
    print(
        f"  in {n_cases_files} case-bearing files of {n_test_files} *.t.sol "
        f"(+{len(files) - n_test_files} mocks), which Forge reports as {total_s} "
        f"suites, a suite being a contract and not a file"
    )
    for name in sorted(per_file, key=lambda k: -sum(per_file[k])):
        t, i = per_file[name]
        if t + i:
            s = len(suite_names[name])
            extra = f", {s} suites" if s != 1 else ""
            print(f"    {name:26s} {t + i:3d}   (test* {t}, invariant_ {i}{extra})")

    print(f"\nassertion-bearing helpers discovered: {len(helpers)}")
    for h in helpers:
        uses = len(re.findall(r"\b" + h + r"\s*\(", all_code)) - len(
            re.findall(r"function\s+" + h + r"\s*\(", all_code)
        )
        print(f"    {h:26s} {uses} call sites   {sorted(declared_in[h])}")

    kinds = {}
    for suffix in re.findall(r"\bassert(\w*)\s*\(", all_code):
        kinds["assert" + suffix] = kinds.get("assert" + suffix, 0) + 1
    helper_asserts = {h for h in helpers if h.startswith("assert")}
    primitives = sum(v for k, v in kinds.items() if k not in helper_asserts)
    print(f"\nprimitive assertion calls: {primitives}")
    for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]):
        note = "   (harness helper, listed above)" if k in helper_asserts else ""
        print(f"    {k:22s} {v}{note}")

    reverts = len(re.findall(r"vm\.expectRevert", all_code))
    bare = len(re.findall(r"vm\.expectRevert\(\s*\)", all_code))
    selector = len(re.findall(r"vm\.expectRevert\(\s*[A-Za-z_][\w.]*\.selector", all_code))
    encoded = len(re.findall(r"vm\.expectRevert\(\s*abi\.encode", all_code))
    print(f"\nvm.expectRevert in code: {reverts}")
    print(f"    bare vm.expectRevert(): {bare}")
    print(f"    names an error selector: {selector}")
    print(f"    abi.encode* (pins arguments too): {encoded}")
    print(f"    parameterised inside a helper: {reverts - bare - selector - encoded}")

    orphans = []
    if CONTRACT.exists():
        errors = re.findall(r"^\s*error\s+(\w+)", CONTRACT.read_text(encoding="utf-8"), re.M)
        counted = {
            e: len(re.findall(r"\b" + e + r"\.selector", all_code)) for e in errors
        }
        orphans = [e for e, n in counted.items() if n == 0]
        once = [e for e, n in counted.items() if n == 1]
        print(f"\ncustom errors declared: {len(errors)}")
        print(f"    orphaned (no test names the selector): {orphans if orphans else 'none'}")
        print(f"    named exactly once, so one deleted test orphans them: {once}")
        top = sorted(counted.items(), key=lambda kv: -kv[1])[:4]
        print("    most expected: " + ", ".join(f"{k} {v}" for k, v in top))

    print(f"\nvacuous bodies: {len(vacuous)}")
    for v in vacuous:
        print(f"    {v}   {sorted(declared_in[v])}")

    if vacuous or orphans:
        print("\nFAIL — a test that asserts nothing, or an error no test expects.")
        return 1
    print("\nOK — every case asserts, and every declared error is expected somewhere.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
