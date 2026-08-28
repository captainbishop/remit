// SPDX-License-Identifier: MIT
//
// Mutation gate for the policy model. Run: node reference/mutation-gate.js
//
// WHY THIS EXISTS. `node --test reference/policy.test.js` printing 69/69 says the suite agrees
// with the model. It does not say the suite would NOTICE if the model stopped guarding
// something — and on 2026-08-28, while finishing F17, it did not: sixteen refusals in
// `approveCosignFor` were covered by new tests and one of them, `BAD_CONFIG` on a mandate with
// no cosigner, could be deleted with the whole suite still green. Deleting it did not make the
// call succeed; it made the call fail one line lower under `NOT_COSIGNER`, because nobody is
// null's cosigner. Two guards that refuse the same input for different reasons hide each other,
// and a green run cannot tell you which of them is load-bearing.
//
// So this script asks the only question that settles it: break one guard at a time and require
// a test to fail.
//
// It checks BOTH directions, because F17 is a claim in both directions.
//
//   REMOVAL   — for each `throw refuse(...)` in the target function, rewrite that single line
//               to `void refuse(...)`. Syntactically valid, keeps the message and the code
//               object, removes only the throw. A mutant that survives means no test asserts
//               that refusal, or a neighbouring guard is shadowing it.
//
//   INJECTION — add a guard the function is REQUIRED NOT to have. Removal-mutation cannot
//               reach a "must not refuse" requirement, and F17's harder half is exactly that:
//               a start date in the future, a currently full rolling window and an unfiled
//               ERC-8004 credential all CLEAR, so refusing them would turn our caution into
//               somebody's unapprovable payment. Each injection must be caught.
//
// A survivor is not automatically a gap in the suite. It may be a broken mutant: the first
// version of the window injection compared `windowUsage(...)` — which returns an object — to a
// BigInt, so `+` string-concatenated and the guard was never true. Treat a survivor as a
// hypothesis and probe it (a `console.error` inside the injected line is enough) before
// believing it.
//
// Every mutation runs against a COPY in the OS temp directory, never the working tree, so an
// interrupted run cannot leave a neutered guard behind.

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SRC_DIR = __dirname;
const TARGET = process.argv[2] || 'approveCosignFor';

// ---------------------------------------------------------------- the injections
//
// Keyed by the target function, because a guard that must be absent is specific to the
// function that must not have it. Each is inserted immediately after the anchor line, which is
// chosen to be past the point where `now` and `validUntil` exist.
const INJECTIONS = {
  approveCosignFor: {
    anchor: 'if (mandate.revoked) throw refuse(',
    cases: [
      [
        'a notBefore in the future',
        "  if (now < mandate.notBefore) throw refuse(Denial.NOT_YET_VALID, 'INJECTED');",
      ],
      [
        'a currently full rolling window',
        '  mandate.windows.forEach((w, i) => { if (windowUsage(w, mandate.windowState[i], now).effective' +
          " + BigInt(request.amount) > BigInt(w.cap)) { throw refuse(Denial.OVER_WINDOW_CAP, 'INJECTED'); } });",
      ],
      [
        'an unfiled ERC-8004 credential',
        "  if (mandate.credential) throw refuse(Denial.CREDENTIAL_MISSING, 'INJECTED');",
      ],
      [
        // The maximal version of the wrong design, and the one a reasonable person would write
        // first: only approve what could be spent this second. Every recoverable denial folds
        // into it at once, so if the three above are somehow all shadowed, this still fires.
        'the maximal wrong design: approve only what would spend RIGHT NOW',
        '  { const d = evaluate(mandate, { ...request, spender: mandate.spender }, { now,' +
          ' resolveIdentityOwner: () => null, resolveCredential: () => null });' +
          " if (!d.allowed && d.reason !== Denial.COSIGN_REQUIRED) throw refuse(d.reason, 'INJECTED'); }",
      ],
    ],
  },
};

// ---------------------------------------------------------------- harness

const original = fs.readFileSync(path.join(SRC_DIR, 'policy.js'), 'utf8').split('\n');

/** First line of `function NAME(` through the next line that is a bare `}`, 1-based inclusive. */
function functionBounds(lines, name) {
  const start = lines.findIndex((l) => l.startsWith(`function ${name}(`));
  if (start === -1) throw new Error(`mutation-gate: no top-level function ${name} in policy.js`);
  const end = lines.findIndex((l, i) => i > start && l === '}');
  if (end === -1) throw new Error(`mutation-gate: unterminated ${name}`);
  return [start + 1, end + 1];
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'remit-mutation-'));
fs.copyFileSync(path.join(SRC_DIR, 'policy.test.js'), path.join(tmp, 'policy.test.js'));
const victim = path.join(tmp, 'policy.js');

/** Write a mutated model, run the suite against it, return { fail, killers }. */
function runAgainst(lines) {
  fs.writeFileSync(victim, lines.join('\n'));
  let out;
  try {
    out = execFileSync(process.execPath, ['--test', path.join(tmp, 'policy.test.js')], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    // A non-zero exit is the ORDINARY outcome here — a mutant that gets caught fails tests.
    out = `${e.stdout || ''}${e.stderr || ''}`;
  }
  const m = /^# fail (\d+)$/m.exec(out);
  if (!m) {
    // No summary line at all means the run did not complete: a syntax error in the mutant, a
    // crash, or a runner change. Reporting it as "caught" would be a false pass.
    return { fail: null, killers: [], raw: out.split('\n').slice(0, 12) };
  }
  return {
    fail: Number(m[1]),
    killers: [...out.matchAll(/^not ok \d+ - (.+)$/gm)].map((k) => k[1]),
  };
}

// A green baseline is a precondition, not a result: if the unmutated suite is red, every
// "CAUGHT" below is meaningless because the failure was already there.
const baseline = runAgainst(original);
if (baseline.fail !== 0) {
  console.error(`mutation-gate: baseline suite is not green (fail=${baseline.fail}). Fix that first.`);
  if (baseline.raw) console.error(baseline.raw.join('\n'));
  process.exit(2);
}

const [start, end] = functionBounds(original, TARGET);
const results = [];

// ---- removal ----
const removalTargets = [];
for (let ln = start; ln <= end; ln++) {
  if (original[ln - 1].includes('throw refuse(')) removalTargets.push(ln);
}
if (removalTargets.length === 0) {
  console.error(`mutation-gate: ${TARGET} contains no \`throw refuse(\` guards to mutate`);
  process.exit(2);
}
for (const ln of removalTargets) {
  const blob = original.slice(ln - 1, ln + 2).join(' ');
  const code = (/(ApprovalRefusal|Denial)\.[A-Z_]+/.exec(blob) || ['?'])[0];
  const mutated = original.slice();
  mutated[ln - 1] = mutated[ln - 1].replace('throw refuse(', 'void refuse(');
  results.push({ kind: 'removed', label: `${code} (line ${ln})`, ...runAgainst(mutated) });
}

// ---- injection ----
const inj = INJECTIONS[TARGET];
if (inj) {
  const anchor = original.findIndex((l) => l.includes(inj.anchor));
  if (anchor === -1) throw new Error(`mutation-gate: anchor not found in ${TARGET}`);
  for (const [label, line] of inj.cases) {
    const mutated = [...original.slice(0, anchor + 1), line, ...original.slice(anchor + 1)];
    results.push({ kind: 'injected', label, ...runAgainst(mutated) });
  }
}

fs.rmSync(tmp, { recursive: true, force: true });

// ---------------------------------------------------------------- report

console.log(`mutation gate: ${TARGET}  (baseline green, ${results.length} mutants)\n`);
const survivors = [];
for (const r of results) {
  const verdict = r.fail === null ? 'INCONCLUSIVE' : r.fail > 0 ? 'caught' : 'SURVIVED';
  if (r.fail !== 0 && r.fail !== null) {
    console.log(`  ${verdict.padEnd(12)} ${r.kind.padEnd(9)} ${r.label}`);
    console.log(`               by: ${r.killers[0] || '(unnamed)'}`);
  } else {
    survivors.push(r);
    console.log(`  ${verdict.padEnd(12)} ${r.kind.padEnd(9)} ${r.label}`);
    if (r.raw) console.log(r.raw.map((l) => `               ${l}`).join('\n'));
  }
}

console.log();
if (survivors.length === 0) {
  console.log(`OK — every one of the ${results.length} mutants was caught by a named test.`);
  process.exit(0);
}
console.log(`${survivors.length} mutant(s) not caught. Each is a hypothesis: probe it before`);
console.log('believing it, then either fix the mutant or add the test it is missing.');
process.exit(1);
