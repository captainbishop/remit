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
//   REMOVAL   — for each refusal in the target function, neuter that single line. There are two
//               spellings in this model and the gate handles both, because they were written for
//               different call styles and a gate that knew only one silently covered half the
//               file: `throw refuse(...)` becomes `void refuse(...)`, and `return deny(...)`
//               becomes `void deny(...)`. Either rewrite is syntactically valid, keeps the
//               message and the code object, and removes only the transfer of control. A mutant
//               that survives means no test asserts that refusal, or a neighbouring guard is
//               shadowing it.
//
//   INJECTION — add a guard the function is REQUIRED NOT to have. Removal-mutation cannot
//               reach a "must not refuse" requirement, and F17's harder half is exactly that:
//               a start date in the future, a currently full rolling window and an unfiled
//               ERC-8004 credential all CLEAR, so refusing them would turn our caution into
//               somebody's unapprovable payment. Each injection must be caught.
//
// THE TWO SPELLINGS ARE NOT COSMETIC, AND UNTIL 2026-08-28 ONE OF THEM WAS UNGATED. Every one
// of the 18 `throw refuse(` lines is inside `approveCosignFor`; every one of the 24
// `return deny(` lines is inside `evaluate`. So a gate that mutated only `throw refuse(`
// reported a clean sweep while the spend path — the function that decides whether real money
// moves — had never had a single guard broken on purpose. `node reference/mutation-gate.js
// evaluate` is the run that closes that, and it is the more important of the two.
//
// A REMOVAL IN `evaluate` FALLS THROUGH RATHER THAN THROWING, WHICH CHANGES WHAT A KILL MEANS.
// Neutering a `throw` leaves the function to carry on with valid state. Neutering a `return`
// leaves it to carry on with state the guard existed to reject — `void deny(Denial.UNKNOWN_MANDATE)`
// then reads `mandate.revoked` off null. That still fails a test, so the mutant is caught, but it
// is caught by the model CRASHING rather than by the suite noticing a wrong answer. The report
// separates the two: a crash-kill proves the suite would not stay green, an assertion-kill proves
// the suite knows what the right answer was. Only the second is what this gate is for, so crash
// kills are counted and named instead of being folded into the total.
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
// function that must not have it. `anchor` is matched INSIDE the target's own bounds — it used
// to be matched against the whole file, which would have silently anchored in the wrong
// function the first time two functions shared a line — and `position` says which side of it
// the guard goes.
//
// WHERE AN INJECTION SITS DECIDES WHAT A KILL PROVES, and the two targets want opposite ends.
// `approveCosignFor`'s injections go near the TOP, because the claim is that a recoverable
// condition must not be refused at approval time at all. `evaluate`'s go at the very BOTTOM,
// immediately before the `return { allowed: true }`, because by that line every legitimate
// denial has already had its chance: a guard injected there can only fire on a request the
// model was about to ALLOW. So the only test that can catch it is one that expected an allow,
// which is exactly the property being claimed. An injection at the top of `evaluate` would
// instead be killed by whichever unrelated test asserted on a denial reason it displaced.
const INJECTIONS = {
  approveCosignFor: {
    anchor: 'if (mandate.revoked) throw refuse(',
    position: 'after',
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

  // Seven things `evaluate` must NOT refuse. One is a naming collision that would break the
  // product; the other six are the inclusive/exclusive edge of a bound, which is the class of
  // mistake a removal mutant cannot see at all — deleting a cap check makes the model too
  // permissive, and no amount of deleting makes it too strict.
  //
  // Each is written as the plausible WRONG version of a guard that already exists a few lines
  // above, `>` widened to `>=` or `<` to `<=`. That matters twice over: it is the mistake a
  // careful person actually makes, and because the correct guard has already run by the time
  // the injection does, the widened copy can only fire on the single boundary value the
  // original lets through. The mutant is therefore exactly as narrow as the claim.
  evaluate: {
    anchor: 'return {',
    position: 'before',
    cases: [
      [
        // THREAT-MODEL.md section 2. F19 refuses paying the PAYER; F22 is about paying the
        // SPENDER, and the two share the English phrase "self-payment" while being opposites.
        // A guard named SelfPayment that refused this would stop a delegate from ever being
        // paid by its own mandate, which is a supported and ordinary arrangement.
        'F22: a spend to the mandate own spender — a delegate paying itself — must stay ALLOWED',
        "  if (normalizeAddr(recipient) === mandate.spender) return deny(Denial.SELF_PAYMENT, 'INJECTED');",
      ],
      [
        'a spend of exactly perTxCap must be ALLOWED (the cap is a ceiling, not a limit below it)',
        '  if (mandate.perTxCap !== null && amount >= mandate.perTxCap)' +
          " return deny(Denial.OVER_PER_TX_CAP, 'INJECTED');",
      ],
      [
        'a spend that lands totalSpent exactly ON totalCap must be ALLOWED (spend it to zero)',
        '  if (mandate.totalCap !== null && mandate.totalSpent + amount >= mandate.totalCap)' +
          " return deny(Denial.OVER_TOTAL_CAP, 'INJECTED');",
      ],
      [
        'a spend that fills a rolling window exactly to its cap must be ALLOWED',
        '  if (mandate.windows.some((w, i) =>' +
          ' windowUsage(w, mandate.windowState[i], now).effective + amount >= w.cap))' +
          " return deny(Denial.OVER_WINDOW_CAP, 'INJECTED');",
      ],
      [
        'notBefore is INCLUSIVE: a spend at exactly notBefore must be ALLOWED',
        "  if (now <= mandate.notBefore) return deny(Denial.NOT_YET_VALID, 'INJECTED');",
      ],
      [
        // expiresAt being exclusive is a deliberate, documented choice (policy.js, "expiresAt is
        // EXCLUSIVE"), taken so that sub-second Arc blocks sharing a timestamp cannot leave an
        // ambiguous final second. The choice is only worth anything if the second before it works.
        'expiresAt is EXCLUSIVE: the last live second, expiresAt - 1, must be ALLOWED',
        '  if (mandate.expiresAt !== null && now + 1n >= mandate.expiresAt)' +
          " return deny(Denial.EXPIRED, 'INJECTED');",
      ],
      [
        'a spend of exactly cosignThreshold needs NO co-signature, and one above it with a live'
          + ' approval must be ALLOWED',
        '  if (mandate.cosignThreshold !== null && amount >= mandate.cosignThreshold)' +
          " return deny(Denial.COSIGN_REQUIRED, 'INJECTED');",
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

/** Write a mutated model, run the suite against it, return { fail, killers, crash }. */
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
    return { fail: null, killers: [], crash: null, raw: out.split('\n').slice(0, 12) };
  }
  // Did the suite catch this mutant by knowing the right answer, or only by the model blowing
  // up? `node --test` distinguishes the two in its own diagnostics: an `assert` failure carries
  // `code: 'ERR_ASSERTION'`, while a test that threw carries `code: 'ERR_TEST_FAILURE'` and
  // `name: 'TypeError'`. Verified against the runner rather than assumed.
  //
  // A mutant is flagged ONLY when NOT ONE of its killers reached an assertion, which is a
  // narrower and more useful claim than "an error appeared somewhere". The two readings differ,
  // and the difference has to be understood before acting on a flag: neutering the "no
  // attestation filed" denial makes `att.validator` read off null, so the two tests that DO
  // assert CREDENTIAL_MISSING fail with a TypeError before reaching their assert. That mutant is
  // still flagged, correctly — no killer asserted — but the answer is NOT "write a test". The
  // tests exist; once the guard is gone there is nothing left for them to assert against,
  // because the value the next line reads does not exist. So a flag means READ THIS ONE, not
  // FIX THIS ONE: some are inherent to what the guard was protecting, and some are a gap.
  const assertionKills = (out.match(/^\s*code: 'ERR_ASSERTION'$/gm) || []).length;
  const crashed = out.match(/^\s*name: '(TypeError|ReferenceError|RangeError)'$/gm) || [];
  const crash =
    assertionKills === 0 && crashed.length > 0
      ? (/(TypeError|ReferenceError|RangeError)/.exec(crashed[0]) || [null])[0]
      : null;
  return {
    fail: Number(m[1]),
    killers: [...out.matchAll(/^not ok \d+ - (.+)$/gm)].map((k) => k[1]),
    crash,
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
//
// The two spellings the model actually uses. Order matters only in that a line is mutated once:
// `throw refuse(` for the functions that signal by throwing, `return deny(` for the ones that
// return a decision object. A multi-line `return deny(Denial.X, {` is still handled by rewriting
// its FIRST line — `void deny(Denial.X, { ... });` remains one valid expression statement.
const NEUTERINGS = [
  ['throw refuse(', 'void refuse('],
  ['return deny(', 'void deny('],
];

const removalTargets = [];
for (let ln = start; ln <= end; ln++) {
  const found = NEUTERINGS.find(([from]) => original[ln - 1].includes(from));
  if (found) removalTargets.push([ln, found]);
}
if (removalTargets.length === 0) {
  const spellings = NEUTERINGS.map(([from]) => `\`${from}\``).join(' or ');
  console.error(`mutation-gate: ${TARGET} contains no ${spellings} guards to mutate`);
  process.exit(2);
}
for (const [ln, [from, to]] of removalTargets) {
  const blob = original.slice(ln - 1, ln + 2).join(' ');
  const code = (/(ApprovalRefusal|Denial)\.[A-Z_]+/.exec(blob) || ['?'])[0];
  const mutated = original.slice();
  mutated[ln - 1] = mutated[ln - 1].replace(from, to);
  results.push({ kind: 'removed', label: `${code} (line ${ln})`, ...runAgainst(mutated) });
}

// ---- injection ----
const inj = INJECTIONS[TARGET];
if (inj) {
  // Searched inside the target's own bounds. A whole-file search would have anchored in the
  // first function that happened to contain the string, and reported a clean sweep for a
  // guard injected somewhere the claim was never about.
  const anchor = original.findIndex(
    (l, i) => i >= start - 1 && i <= end - 1 && l.includes(inj.anchor),
  );
  if (anchor === -1) throw new Error(`mutation-gate: anchor not found inside ${TARGET}`);
  const at = inj.position === 'before' ? anchor : anchor + 1;
  for (const [label, line] of inj.cases) {
    const mutated = [...original.slice(0, at), line, ...original.slice(at)];
    results.push({ kind: 'injected', label, ...runAgainst(mutated) });
  }
}

fs.rmSync(tmp, { recursive: true, force: true });

// ---------------------------------------------------------------- report

console.log(`mutation gate: ${TARGET}  (baseline green, ${results.length} mutants)\n`);
const survivors = [];
const crashKills = [];
for (const r of results) {
  const verdict = r.fail === null ? 'INCONCLUSIVE' : r.fail > 0 ? 'caught' : 'SURVIVED';
  if (r.fail !== 0 && r.fail !== null) {
    console.log(`  ${verdict.padEnd(12)} ${r.kind.padEnd(9)} ${r.label}`);
    console.log(`               by: ${r.killers[0] || '(unnamed)'}`);
    if (r.crash) {
      crashKills.push(r);
      console.log(`               and NO killer asserted — every failure was a ${r.crash}`);
    }
  } else {
    survivors.push(r);
    console.log(`  ${verdict.padEnd(12)} ${r.kind.padEnd(9)} ${r.label}`);
    if (r.raw) console.log(r.raw.map((l) => `               ${l}`).join('\n'));
  }
}

console.log();
if (survivors.length === 0 && crashKills.length === 0) {
  console.log(`OK — every one of the ${results.length} mutants was caught by a named test.`);
  process.exit(0);
}
if (survivors.length === 0) {
  const n = crashKills.length;
  console.log(
    `OK — every one of the ${results.length} mutants was caught, but ${n} of them ${n === 1 ? 'was' : 'were'}`,
  );
  console.log('caught with NO killer reaching an assertion: every failing test threw instead.');
  console.log('That is a weaker result and not a failure — a fall-through past a guard whose whole');
  console.log('job was to reject unusable state often cannot reach an answer at all. Read each one');
  console.log('and decide whether a test should pin the DENIAL rather than merely provoke it:');
  for (const r of crashKills) console.log(`  - ${r.label}  (${r.crash})`);
  process.exit(0);
}
console.log(`${survivors.length} mutant(s) not caught. Each is a hypothesis: probe it before`);
console.log('believing it, then either fix the mutant or add the test it is missing.');
process.exit(1);
