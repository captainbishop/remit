// SPDX-License-Identifier: MIT
//
// Mutation gate for the policy model. Run: node reference/mutation-gate.js
//
// WHY THIS EXISTS. `node --test reference/policy.test.js` printing 69/69 says the suite agrees
// with the model. It does not say the suite would NOTICE if the model stopped guarding
// something — and on 2026-08-28, while finishing F17, it did not: sixteen refusals in
// `approveCosignFor` were covered by new tests and one of them, `BAD_CONFIG` on a mandate with
// no cosigner, could be deleted with the whole suite still green. Deleting it did not make the
// call succeed; it made the call fail one line lower under `NOT_COSIGNER`, because no caller
// matches a null cosigner. Two guards that refuse the same input for different reasons hide
// each other, and a green run cannot tell which of the two is enforcing the rule.
//
// This script therefore asks the only question that settles it: break one guard at a time and
// require a test to fail.
//
// It checks BOTH directions, because F17 is a claim in both directions.
//
//   REMOVAL   — for each refusal in the target function, neuter that single line. There are
//               three spellings in this model and the gate handles all three, because a gate
//               that knew only one covered a third of the file while reporting a clean sweep:
//               `throw refuse(...)` becomes `void refuse(...)`, `return deny(...)` becomes
//               `void deny(...)`, and `throw new Error(...)` becomes `void new Error(...)`.
//               Each rewrite is syntactically valid, keeps the message and the code object, and
//               removes only the transfer of control. A mutant that survives means no test
//               asserts that refusal, or a neighbouring guard is shadowing it.
//
//   INJECTION — add a guard the function is REQUIRED NOT to have. Removal-mutation cannot
//               reach a "must not refuse" requirement, and F17's harder half is exactly that:
//               a start date in the future, a currently full rolling window and an unfiled
//               ERC-8004 credential all CLEAR, so refusing them would turn caution into a
//               legitimate payment that can never be approved. Each injection must be caught.
//
// THE SPELLINGS ARE NOT COSMETIC, AND EACH ONE ADDED HAS REACHED A FUNCTION THE GATE HAD NEVER
// TOUCHED. Counted from policy.js on 2026-08-30 rather than remembered: all 21 `throw refuse(`
// lines sit inside `approveCosignFor`, all 27 `return deny(` lines inside `evaluate`, and the 35
// `throw new Error(` lines are spread over nine functions with 20 of them inside `createMandate`.
// The two counts F3 moved are the first and the second, which each gained the spend-count ceiling.
// The last pair was stale before that: the figures here read 33 and 18 while the file held 35 and
// 20, which is what a count restated from a previous run looks like once the file has moved on.
// The first version of this script knew only `throw refuse(`, so it reported a clean sweep while
// the spend path — the function that decides whether real money moves — had never had a single
// guard broken on purpose, and the version after it still said nothing about the function that
// decides what a mandate may even be. `node reference/mutation-gate.js evaluate` closes the first
// gap, `node reference/mutation-gate.js createMandate` closes the second, and `evaluate` remains
// the most important of the three.
//
// The three targets do not partition the file. `evaluate` and `approveCosignFor` each contain a
// `throw new Error(` for a missing `ctx.now` or nonce — harness mistakes rather than policy
// outcomes, since the contract cannot forget `block.timestamp` — so those lines are now mutated
// as part of their own function's run and appear in its count.
//
// A REMOVAL IN `evaluate` FALLS THROUGH RATHER THAN THROWING, WHICH CHANGES WHAT A KILL MEANS.
// Neutering a `throw` leaves the function to carry on with valid state. Neutering a `return`
// leaves it to carry on with state the guard existed to reject — `void deny(Denial.UNKNOWN_MANDATE)`
// then reads `mandate.revoked` off null. That still fails a test, so the mutant is caught, but it
// is caught by the model CRASHING rather than by the suite noticing a wrong answer. The report
// separates the two: a crash-kill proves the suite would not stay green, an assertion-kill proves
// the suite knows what the right answer was. Only the second is what this script exists to
// establish, so crash kills are counted and named instead of being folded into the total.
//
// `evaluate` has exactly two of them, decided on 2026-08-29 and not to be re-probed:
// `reference/policy.js:626`'s `if (!mandate)` and `:752`'s `if (!att)`, both of which guard
// against an ABSENT object rather than a wrong value, so a fall-through immediately dereferences
// null — `mandate.revoked`, `att.validator` — and no test can ever observe a returned denial to
// assert on. Neither is a gap in the suite and neither can be converted into an assertion-kill
// without inventing state the guard exists to refuse. Any THIRD crash-kill appearing in
// `evaluate` is new and should be read rather than assumed to belong to this pair.
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
// to be matched against the whole file, which would have anchored in the wrong function
// without reporting anything the first time two functions shared a line — and `position`
// says which side of it the guard goes.
//
// WHERE AN INJECTION SITS DECIDES WHAT A KILL PROVES, and the two targets want opposite ends.
// `approveCosignFor`'s injections go near the TOP, because the claim is that a recoverable
// condition must not be refused at approval time at all. `evaluate`'s go at the very BOTTOM,
// immediately before the `return { allowed: true }`, because by that line every legitimate
// denial has already had its chance: a guard injected there can only fire on a request the
// model was about to ALLOW. The only test that can catch it is therefore one that expected an
// allow, which is exactly the property being claimed. An injection at the top of `evaluate` would
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
  // tests exist; once the guard is gone there is nothing left for them to assert against, because
  // the value the next line reads does not exist. A flag therefore means READ THIS ONE rather than
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
// The three spellings the model actually uses. Order matters only in that a line is mutated once:
// `throw refuse(` for the functions that signal by throwing a coded refusal, `return deny(` for
// the ones that return a decision object, and `throw new Error(` for `createMandate`, which
// refuses at GRANT time and has no decision object to return.
//
// THE THIRD SPELLING WAS ADDED ON 2026-08-29 AND IT REACHES A FUNCTION THIS SCRIPT HAD NEVER
// TOUCHED. `createMandate` states every rule about what a mandate may even BE, and all of its
// refusals are plain `throw new Error(`, so this script skipped all of them while the Solidity
// sibling had been mutating the same function since 2026-08-28 — and found a shadowed survivor
// there on its first run. Two suites, one of them covered by removal mutation and one not, is how
// a divergence lives for a week. `void new Error('...')` is a valid expression statement, so the
// rewrite keeps the message and removes only the transfer of control, exactly like the other two.
//
// A multi-line `throw new Error(` is handled the same way as a multi-line `return deny(`: only
// the FIRST line is rewritten, and `void new Error(` + the continuation lines is still one valid
// expression statement.
const NEUTERINGS = [
  ['throw refuse(', 'void refuse('],
  ['return deny(', 'void deny('],
  ['throw new Error(', 'void new Error('],
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
// A label a reader can act on. `throw refuse(` and `return deny(` carry a `Denial` or
// `ApprovalRefusal` code, which is the best label there is: it is the claim the test asserts.
// `throw new Error(` carries no code — that is the whole difference between a grant-time refusal
// and a spend-time denial — so the message stands in for one. Without this, every `createMandate`
// mutant would report as `? (line N)` and a survivor would be unreadable, which is the failure
// mode this script exists to avoid: evidence that degrades without the report saying so.
//
// Two corrections, both from watching the first `createMandate` run on 2026-08-29:
//
// All three of JavaScript's string delimiters have to be accepted, not just `'`. The MAX_WINDOWS
// guard interpolates the constant, so its message is a template literal, and it reported as
// `? (line 420)` — a survivor with no name, on the run whose whole purpose was to find out
// whether that guard had a test. The one label this script could not print was the one it was
// printing about.
//
// The search starts at the neutering marker rather than at the start of the blob, because the
// blob is three lines wide and any apostrophe in a nearby comment — "the payer's allowance" —
// matches `'([^']*)'` earlier than the real message does and wins. That was luck rather than
// design in the two-spelling version: every `refuse(`/`deny(` call sits on a line of its own with
// no prose around it.
function labelFor(blob, from) {
  const at = blob.indexOf(from);
  const tail = at === -1 ? blob : blob.slice(at + from.length);
  const code = /(ApprovalRefusal|Denial)\.[A-Z_]+/.exec(tail);
  if (code) return code[0];
  const msg = /'([^']*)'|"([^"]*)"|`([^`]*)`/.exec(tail);
  if (!msg) return '?';
  // Strip the `fn():` prefix every message in this model carries; it is the same on all of
  // them and consumes the room that distinguishes one guard from the next.
  const text = (msg[1] ?? msg[2] ?? msg[3]).replace(/^\w+\(\):\s*/, '').trim();
  return text.length > 56 ? `${text.slice(0, 56)}…` : text;
}

for (const [ln, [from, to]] of removalTargets) {
  const blob = original.slice(ln - 1, ln + 2).join(' ');
  const code = labelFor(blob, from);
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
