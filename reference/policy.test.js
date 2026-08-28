// SPDX-License-Identifier: MIT
//
// Adversarial test suite for the Remit policy engine.
// Run: node --test reference/policy.test.js
//
// This line used to read `node --test reference/`, which was correct on the Node that
// wrote it and fails on Node 22 with a MODULE_NOT_FOUND for the directory itself — the
// runner hands a bare positional to the CJS loader instead of walking it. Naming the
// file works on every version; `node --test 'reference/**/*.test.js'` also works, and
// so does a bare `node --test` with the cwd inside reference/.
//
// These tests are the correctness evidence for MandateManager.sol. The contract
// cannot be compiled or deployed from the authoring sandbox, so the logic is
// pinned here instead. Tests are grouped by the property they defend, and the
// interesting ones are the attacks: boundary bursts, replay, cosign reuse,
// identity transfer, and non-monotonic clocks.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('./policy.js');
const {
  usdc,
  window: win,
  createMandate,
  revoke,
  approveCosignFor,
  MAX_AMOUNT,
  MAX_COSIGN_TTL,
  Denial,
  // NEW IN v2 (F17). The four refusal codes `approveCosignFor` can raise that `evaluate`
  // cannot. Imported separately rather than merged into Denial, which is the point of it.
  ApprovalRefusal,
  ZERO_ADDRESS,
  DAY,
  WEEK,
} = P;

// `evaluate`, `spend` and the two headroom views are wrapped rather than destructured, to
// close two vacuity traps that the introduction of FAR (below) created. Every mandate that
// names FAR as its horizon starts denying EXPIRED once the clock passes it — and a fuzzer
// whose every spend is denied satisfies "accepted spends never exceed the cap" trivially,
// so the suite would go green while measuring nothing. The recorders feed the meta test at
// the bottom of this file, which fails if either trap is live.
let maxTimeSeen = 0;
let allowedSeen = 0;
const noteTime = (t) => {
  const v = Number(t);
  if (Number.isFinite(v) && v > maxTimeSeen) maxTimeSeen = v;
};
const evaluate = (m, r, ctx, ...rest) => {
  if (ctx) noteTime(ctx.now);
  const out = P.evaluate(m, r, ctx, ...rest);
  if (out && out.allowed) allowedSeen++;
  return out;
};
const spend = (m, r, ctx, ...rest) => {
  if (ctx) noteTime(ctx.now);
  const out = P.spend(m, r, ctx, ...rest);
  if (out && out.allowed) allowedSeen++;
  return out;
};
const headroom = (m, t, ...rest) => {
  noteTime(t);
  return P.headroom(m, t, ...rest);
};
const headroomAcross = (l, t, ...rest) => {
  noteTime(t);
  return P.headroomAcross(l, t, ...rest);
};

const PAYER = '0xPAYER000000000000000000000000000000000001';
const AGENT = '0xAGENT000000000000000000000000000000000002';
const VENDOR = '0xVENDOR00000000000000000000000000000000003';
const OTHER = '0xOTHER000000000000000000000000000000000004';
const BOSS = '0xBOSS0000000000000000000000000000000000005';

let nonceCounter = 0;
const n = () => `n${++nonceCounter}`;

// Every mandate needs a LIFETIME bound as of v2: `totalCap` or `expiresAt`. A per-transaction
// cap bounds each spend and a window bounds each period; neither bounds the total, so neither
// is accepted on its own any more. See policy.js's `hasLifetimeBound`.
//
// Most tests here are about caps, windows, gates, nonces or clocks and are indifferent to the
// horizon, so they name FAR — past every timestamp this suite uses and inside the uint40 the
// contract stores `expiresAt` in, whose maximum is 1_099_511_627_775. The largest timestamp
// the suite actually reaches is 103_676_400, measured by the recorders above rather than
// estimated, which leaves FAR roughly 38x of headroom. Tests that are ABOUT the horizon name
// their own, and the ones asserting the refusal deliberately name none.
//
// It is written out at each call site rather than injected by a wrapper around
// `createMandate`, because a wrapper that quietly satisfies the rule would also hide it: the
// suite would stop demonstrating that a real caller has to supply a bound.
const FAR = 4_000_000_000; // year 2096

/** A simple mandate: 100 USDC per tx, 500/day, agent may pay anyone, distant horizon. */
function simpleMandate(overrides = {}) {
  return createMandate({
    id: 'm1',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('100'),
    windows: [win(DAY, usdc('500'), 12)],
    expiresAt: FAR,
    ...overrides,
  });
}

const req = (amount, extra = {}) => ({
  spender: AGENT,
  recipient: VENDOR,
  amount,
  nonce: n(),
  ...extra,
});

// ---------------------------------------------------------------------------
test('units: usdc() parses exactly and rejects junk', () => {
  assert.equal(usdc('1'), 1_000_000n);
  assert.equal(usdc('0.000001'), 1n);
  assert.equal(usdc('12.5'), 12_500_000n);
  assert.equal(usdc('0'), 0n);
  assert.throws(() => usdc('1.0000001'), /6 dp/); // sub-unit precision is not representable
  assert.throws(() => usdc('-1'), /non-negative/);
  assert.throws(() => usdc('abc'), /non-negative/);
  assert.equal(P.formatUsdc(12_500_000n), '12.5');
  assert.equal(P.formatUsdc(1n), '0.000001');
  assert.equal(P.formatUsdc(1_000_000n), '1');
});

test('construction: a mandate with no LIFETIME bound is refused, and a perTxCap is not one', () => {
  // Nothing at all: refused before v2 and still refused.
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT }),
    /no lifetime bound/,
  );

  // The two shapes v1 and the first draft of v2 both ACCEPTED, which is the finding. A
  // per-transaction cap of 100 lets the delegate spend 100 again, and again, until the
  // payer's allowance is dry; a window is bounded per period and unbounded over a lifetime.
  // Neither is a lifetime bound and neither is accepted now.
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('100') }),
    /no lifetime bound/,
  );
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, windows: [win(DAY, usdc('500'), 12)] }),
    /no lifetime bound/,
  );
  // Combining the two non-bounds does not produce one.
  assert.throws(
    () =>
      createMandate({
        id: 'x', payer: PAYER, spender: AGENT,
        perTxCap: usdc('100'), windows: [win(DAY, usdc('500'), 12)],
      }),
    /no lifetime bound/,
  );

  // Either lifetime bound alone suffices, and each is enough on its own.
  assert.doesNotThrow(() =>
    createMandate({ id: 'a', payer: PAYER, spender: AGENT, totalCap: usdc('500') }));
  assert.doesNotThrow(() =>
    createMandate({ id: 'b', payer: PAYER, spender: AGENT, expiresAt: FAR }));

  // And this is the documented migration for an open-ended arrangement: keep the window,
  // name a horizon. The point of refusing the shape above is that the horizon becomes
  // explicit rather than absent, not that recurring mandates stop being expressible.
  assert.doesNotThrow(() =>
    createMandate({
      id: 'c', payer: PAYER, spender: AGENT,
      windows: [win(DAY, usdc('500'), 12)], expiresAt: FAR,
    }));
});

test('construction: cosignThreshold without a cosigner is refused', () => {
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR, cosignThreshold: usdc('1') }),
    /requires a cosigner/,
  );
});

test('construction: a cosigner without a threshold is refused, because the contract cannot store it', () => {
  // The converse of the test above, and it is not symmetry for its own sake. On-chain
  // F_COSIGN is derived from `cosigner != address(0)` and the threshold is a uint96 whose
  // zero is meaningful, so there is no state for "a cosigner is named and nothing is
  // gated". This model accepted one until v2, which made it MORE PERMISSIVE than the thing
  // it specifies — the same failure class as the uint96 counter, found the same way, by
  // asking what the contract can represent rather than what JavaScript can.
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR, cosigner: BOSS }),
    /requires a cosignThreshold/,
  );
  // Zero is the spelling that gates everything, and it must be accepted.
  const all = createMandate({
    id: 'all', payer: PAYER, spender: AGENT, perTxCap: usdc('10'), expiresAt: FAR, cosigner: BOSS, cosignThreshold: 0n,
  });
  assert.equal(evaluate(all, req(1n), { now: 1 }).reason, Denial.COSIGN_REQUIRED);
});

test('construction: the spender cannot be its own cosigner', () => {
  // approveCosignFor authorises on `caller === mandate.cosigner` and nothing else, so this
  // configuration lets the agent approve its own spend hash and then spend it. The gate
  // becomes two transactions and no second party — not a weaker control, the absence of
  // one. It is invisible in the mandate object, which is what makes it worth refusing.
  assert.throws(
    () =>
      createMandate({
        id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR,
        cosigner: AGENT, cosignThreshold: usdc('10'),
      }),
    /cannot be its own cosigner/,
  );
  // The payer cosigning for itself is the ordinary case and stays legal — it is what
  // mandate 2 does on Arc today.
  assert.doesNotThrow(() =>
    createMandate({
      id: 'ok', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR,
      cosigner: PAYER, cosignThreshold: usdc('10'),
    }),
  );
});

test('construction: a cosign gate that can never fire is refused, measured against the whole policy', () => {
  const MAX = (1n << 96n) - 1n;
  const gate = (over) =>
    createMandate({ id: 'g', payer: PAYER, spender: AGENT, cosigner: BOSS, expiresAt: FAR, ...over });

  // The gate tests `amount > threshold` STRICTLY, so equality is dead: an amount both
  // above the threshold and within a per-transaction cap of the same value cannot exist.
  // Confirmed on Arc Testnet before it was ever fixed — a 50,000 spend against a 50,000
  // threshold did not trip the gate (DESIGN.md:1272).
  assert.throws(() => gate({ perTxCap: usdc('50'), cosignThreshold: usdc('50') }), /can never fire/);
  // One base unit lower and the gate is alive, which is what makes the bound exact rather
  // than merely conservative.
  const live = gate({ perTxCap: usdc('50'), cosignThreshold: usdc('50') - 1n });
  assert.equal(evaluate(live, req(usdc('50')), { now: 1 }).reason, Denial.COSIGN_REQUIRED);

  // perTxCap is NOT the only ceiling. With no per-transaction cap the lifetime cap binds,
  // and this shape passes both spellings of the naive `perTxCap < threshold` check because
  // perTxCap is absent entirely.
  assert.throws(() => gate({ totalCap: usdc('100'), cosignThreshold: usdc('100') }), /can never fire/);
  // So does a window cap.
  assert.throws(
    () => gate({ windows: [win(DAY, usdc('40'), 12)], cosignThreshold: usdc('40') }),
    /can never fire/,
  );
  // And it is a MINIMUM over the windows, not the first or the last of them.
  assert.throws(
    () => gate({ windows: [win(WEEK, usdc('900'), 7), win(DAY, usdc('40'), 12)], cosignThreshold: usdc('40') }),
    /can never fire/,
  );
  // The minimum also crosses cap KINDS: a generous per-transaction cap does not rescue a
  // threshold that the tightest window has already put out of reach.
  assert.throws(
    () => gate({ perTxCap: usdc('1000'), windows: [win(DAY, usdc('40'), 12)], cosignThreshold: usdc('100') }),
    /can never fire/,
  );

  // The UNBOUNDED-AMOUNT case must still be accepted. A mandate bounded only by an expiry
  // has no amount cap at all, so every threshold below the uint96 ceiling is reachable.
  assert.doesNotThrow(() => gate({ expiresAt: 10_000, cosignThreshold: usdc('1000000') }));
  // But the ceiling itself is not, because the contract refuses amounts above it outright
  // — the bound exists even where the payer set none, and this is the term in the check
  // that a model with arbitrary-precision integers has no reason to invent.
  assert.throws(() => gate({ expiresAt: 10_000, cosignThreshold: MAX }), /can never fire/);
  assert.doesNotThrow(() => gate({ expiresAt: 10_000, cosignThreshold: MAX - 1n }));
});

test('construction: window length must divide evenly into buckets', () => {
  assert.throws(() => win(100, usdc('1'), 12), /divisible/);
  assert.doesNotThrow(() => win(DAY, usdc('1'), 24));
});

test('construction: every grant-time refusal the contract makes, the model makes too', () => {
  // Found by auditing zero-means-unset fields, not by a failing test — which is why it
  // is worth having. The contract refuses these at createMandate; the model used to
  // accept all five and fail later, or in one case not fail at all.
  const base = { id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR };

  // A cap of zero makes a window that can never permit anything. The contract calls
  // this BadWindow rather than minting a mandate that is dead on arrival.
  assert.throws(() => win(DAY, 0, 12), /cap must be positive/);

  // THE IMPORTANT ONE. minResponse of 0 means "any response passes", and ERC-8004
  // encodes a FAILED validation as a low response — 100 is the passing value. So a
  // zero here does not merely weaken the gate, it inverts it: the gate would accept
  // precisely the attestations it exists to reject. The contract reverts BadConfig.
  assert.throws(
    () => createMandate({ ...base, credential: { validator: BOSS, requestHash: '0xk', minResponse: 0n } }),
    /minResponse/,
  );

  // A credential with no validator is unrepresentable on-chain: F_CREDENTIAL is
  // required to agree with `validator != address(0)`, so there is no such mandate.
  assert.throws(
    () => createMandate({ ...base, credential: { requestHash: '0xk' } }),
    /validator/,
  );

  // An expiry at or before notBefore is a mandate that is never live.
  assert.throws(
    () => createMandate({ ...base, notBefore: 1000, expiresAt: 1000 }),
    /expiresAt/,
  );
  assert.throws(
    () => createMandate({ ...base, notBefore: 1000, expiresAt: 999 }),
    /expiresAt/,
  );
  assert.doesNotThrow(() => createMandate({ ...base, notBefore: 1000, expiresAt: 1001 }));

  // The zero address on an allowlist is a typo, not a policy.
  assert.throws(
    () => createMandate({ ...base, allowlist: [VENDOR, P.ZERO_ADDRESS] }),
    /zero address/,
  );

  // And the shapes that are legitimate still construct: minResponse defaults to the
  // ERC-8004 passing value, and an omitted expiry means no expiry.
  assert.doesNotThrow(() => createMandate({ ...base, credential: { validator: BOSS, requestHash: '0xk' } }));
  assert.doesNotThrow(() => createMandate({ ...base, allowlist: [VENDOR] }));
});

test('construction: the stored credential is encodable — no undefined where a uint goes', () => {
  // The model earns its "normative spec" claim only if its output can be encoded into
  // the contract's struct without a translation layer that has defaults of its own.
  // Those defaults are exactly where a client bug lives: an encoder reading an omitted
  // minResponse as 0 would write the one value createMandate refuses, and an encoder
  // reading a null maxStaleness as 0 would be right by accident rather than by design.
  // So construction materialises every credential field in its ON-CHAIN spelling,
  // where 0 — not null, not undefined — is how "unset" is written.
  const m = createMandate({
    id: 'x',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('1'),
    expiresAt: FAR,
    credential: { validator: BOSS, requestHash: '0xk' },
  });

  assert.equal(m.credential.minResponse, 100n, 'the ERC-8004 passing value, not undefined');
  assert.equal(m.credential.maxStaleness, 0n, 'on-chain unset is 0, and 0 means no requirement');
  assert.equal(m.credential.agentId, 0n, 'on-chain unset is 0, which inherits the identity gate');
  for (const [k, v] of Object.entries(m.credential)) {
    assert.notEqual(v, undefined, `credential.${k} must be encodable`);
  }

  // Explicit values survive untouched, including the permissive ones.
  const explicit = createMandate({
    id: 'y',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('1'),
    expiresAt: FAR,
    credential: { validator: BOSS, requestHash: '0xk', minResponse: 200n, maxStaleness: 0n, agentId: 42n },
  });
  assert.equal(explicit.credential.minResponse, 200n);
  assert.equal(explicit.credential.maxStaleness, 0n);
  assert.equal(explicit.credential.agentId, 42n);

  // A null maxStaleness is accepted from a caller writing the model directly, and is
  // stored as the 0 the contract would hold.
  const nulled = createMandate({
    id: 'z',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('1'),
    expiresAt: FAR,
    credential: { validator: BOSS, requestHash: '0xk', maxStaleness: null },
  });
  assert.equal(nulled.credential.maxStaleness, 0n);
});

// ---------------------------------------------------------------------------
test('happy path: a spend inside every bound is allowed and accounted', () => {
  const m = simpleMandate();
  const d = spend(m, req(usdc('40')), { now: 1000 });
  assert.equal(d.allowed, true);
  assert.equal(m.totalSpent, usdc('40'));
  assert.equal(m.spendCount, 1n);
  const h = headroom(m, 1000);
  assert.equal(h.windows[0].used, usdc('40'));
  assert.equal(h.windows[0].remaining, usdc('460'));
});

test('evaluate() is pure — it never mutates the mandate', () => {
  const m = simpleMandate();
  const before = JSON.stringify(m, (k, v) => (typeof v === 'bigint' ? v.toString() : v));
  const d = evaluate(m, req(usdc('40')), { now: 1000 });
  assert.equal(d.allowed, true);
  const after = JSON.stringify(m, (k, v) => (typeof v === 'bigint' ? v.toString() : v));
  assert.equal(before, after, 'evaluate must not mutate; only commit may write');
});

test('per-transaction cap blocks an oversized single spend', () => {
  const m = simpleMandate();
  const d = evaluate(m, req(usdc('100.000001')), { now: 1000 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.OVER_PER_TX_CAP);
  // exactly at the cap is allowed — the bound is inclusive
  assert.equal(evaluate(m, req(usdc('100')), { now: 1000 }).allowed, true);
});

test('total lifetime cap blocks the spend that would cross it', () => {
  const m = createMandate({
    id: 'm', payer: PAYER, spender: AGENT,
    perTxCap: usdc('100'), totalCap: usdc('150'),
  });
  assert.equal(spend(m, req(usdc('100')), { now: 1 }).allowed, true);
  const d = evaluate(m, req(usdc('51')), { now: 2 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.OVER_TOTAL_CAP);
  assert.equal(spend(m, req(usdc('50')), { now: 2 }).allowed, true); // exact fit
  assert.equal(m.totalSpent, usdc('150'));
  assert.equal(evaluate(m, req(usdc('0.000001')), { now: 3 }).reason, Denial.OVER_TOTAL_CAP);
});

test('the uint96 audit counter denies by name rather than overflowing, and only without a total cap', () => {
  const MAX = (1n << 96n) - 1n;

  // A window cap at the maximum so nothing cheaper binds first, and deliberately NO
  // totalCap — the only shape that can reach the ceiling, because a lifetime cap is
  // itself a uint96 and is consulted above it. Mirrors Bounds.t.sol.
  const m = createMandate({
    id: 'ceiling', payer: PAYER, spender: AGENT, windows: [win(DAY, MAX, 12)], expiresAt: FAR,
  });
  assert.equal(spend(m, req(1n), { now: 1 }).allowed, true);
  assert.equal(m.totalSpent, 1n);

  const d = evaluate(m, req(MAX), { now: 2 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.TOTAL_SPENT_CEILING);

  // One base unit less fits exactly, so what binds is the width of the counter and not
  // an off-by-one in something cheaper.
  assert.equal(evaluate(m, req(MAX - 1n), { now: 2 }).allowed, true);

  // Given a lifetime cap, the identical request is refused for the truthful reason.
  const capped = createMandate({
    id: 'capped', payer: PAYER, spender: AGENT, totalCap: MAX, windows: [win(DAY, MAX, 12)],
  });
  assert.equal(spend(capped, req(1n), { now: 1 }).allowed, true);
  assert.equal(evaluate(capped, req(MAX), { now: 2 }).reason, Denial.OVER_TOTAL_CAP);
});

test('recipient allowlist blocks anyone not named at grant time', () => {
  const m = simpleMandate({ allowlist: [VENDOR] });
  assert.equal(spend(m, req(usdc('10')), { now: 1 }).allowed, true);
  const d = evaluate(m, req(usdc('10'), { recipient: OTHER }), { now: 1 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.RECIPIENT_NOT_ALLOWED);
});

test('allowlist matching is case-insensitive on address hex', () => {
  const m = simpleMandate({ allowlist: [VENDOR.toUpperCase()] });
  assert.equal(evaluate(m, req(usdc('10'), { recipient: VENDOR.toLowerCase() }), { now: 1 }).allowed, true);
});

test('zero recipient and zero amount are refused before touching the chain', () => {
  const m = simpleMandate();
  assert.equal(evaluate(m, req(usdc('1'), { recipient: P.ZERO_ADDRESS }), { now: 1 }).reason, Denial.ZERO_RECIPIENT);
  assert.equal(evaluate(m, req(0n), { now: 1 }).reason, Denial.ZERO_AMOUNT);
});

test('only the named spender may spend', () => {
  const m = simpleMandate();
  const d = evaluate(m, req(usdc('1'), { spender: OTHER }), { now: 1 });
  assert.equal(d.reason, Denial.WRONG_SPENDER);
});

// ---------------------------------------------------------------------------
test('validity period: notBefore and exclusive expiry', () => {
  const m = simpleMandate({ notBefore: 1000, expiresAt: 2000 });
  assert.equal(evaluate(m, req(usdc('1')), { now: 999 }).reason, Denial.NOT_YET_VALID);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1000 }).allowed, true);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1999 }).allowed, true);
  // exclusive: dead exactly AT expiresAt, so there is no ambiguous final second
  assert.equal(evaluate(m, req(usdc('1')), { now: 2000 }).reason, Denial.EXPIRED);
});

test('revocation: the payer or the spender may revoke, and nobody else', () => {
  const byPayer = simpleMandate();
  revoke(byPayer, PAYER);
  assert.equal(evaluate(byPayer, req(usdc('1')), { now: 1 }).reason, Denial.REVOKED);
  assert.equal(headroom(byPayer, 1).maxSpendNow, 0n);
  assert.equal(headroom(byPayer, 1).live, false);

  // The SPENDER may revoke too. An agent that has finished its job, or that detects
  // it has been compromised, should be able to surrender its own authority without
  // waiting for the payer to notice. It cannot hurt the payer: revocation only ever
  // removes power, and the only power it removes is the agent's own.
  const bySpender = simpleMandate();
  revoke(bySpender, AGENT);
  assert.equal(evaluate(bySpender, req(usdc('1')), { now: 1 }).reason, Denial.REVOKED);

  const byStranger = simpleMandate();
  assert.throws(() => revoke(byStranger, OTHER), /payer or the spender/);
  assert.equal(evaluate(byStranger, req(usdc('1')), { now: 1 }).allowed, true, 'still live');
});

test('revocation outranks every other check, including a valid cosign', () => {
  const m = simpleMandate({ cosignThreshold: usdc('10'), cosigner: BOSS });
  const r = req(usdc('50'));
  approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1 });
  revoke(m, PAYER);
  assert.equal(evaluate(m, r, { now: 1 }).reason, Denial.REVOKED);
});

// ---------------------------------------------------------------------------
test('nonce replay is refused — a resubmitted spend does not pay twice', () => {
  const m = simpleMandate();
  const r = req(usdc('10'));
  assert.equal(spend(m, r, { now: 1 }).allowed, true);
  const again = evaluate(m, r, { now: 1 });
  assert.equal(again.allowed, false);
  assert.equal(again.reason, Denial.NONCE_ALREADY_USED);
  assert.equal(m.totalSpent, usdc('10'), 'balance must not move twice');
  assert.equal(m.spendCount, 1n);
});

test('a denied spend consumes nothing — nonce stays reusable', () => {
  const m = simpleMandate();
  const r = req(usdc('999')); // over per-tx cap
  assert.equal(evaluate(m, r, { now: 1 }).reason, Denial.OVER_PER_TX_CAP);
  // same nonce, now a legal amount: must succeed, because the failure was not a spend
  assert.equal(spend(m, { ...r, amount: usdc('10') }, { now: 1 }).allowed, true);
});

test('an amount that does not fit in uint96 is refused before any cap is consulted', () => {
  // This model has arbitrary-precision integers and would happily accept 2^96, but
  // the contract stores every cap and `totalSpent` as uint96 and casts the amount
  // down. An unchecked cast would silently truncate a huge amount into a small one
  // that passes every cap — so the contract refuses it up front, and the model has to
  // agree or it stops being a specification of the thing that actually runs.
  const m = simpleMandate(); // perTxCap 100 USDC
  const d = evaluate(m, req(P.MAX_AMOUNT + 1n), { now: 1 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.AMOUNT_TOO_LARGE, 'the type bound outranks the cap');
  assert.equal(d.detail.max, P.MAX_AMOUNT);

  // The largest representable amount is refused by the CAP instead, which proves the
  // new check is a type bound rather than an accidental second cap.
  assert.equal(evaluate(m, req(P.MAX_AMOUNT), { now: 1 }).reason, Denial.OVER_PER_TX_CAP);
  assert.equal(P.MAX_AMOUNT, (1n << 96n) - 1n);
});

// ---------------------------------------------------------------------------
// The attack the window design exists to stop.
test('ATTACK: tumbling-window boundary burst is blocked', () => {
  // Daily cap of 500. A naive implementation that resets at midnight would let
  // the agent spend 500 just before the reset and 500 just after: 1000 in ~2s.
  const m = simpleMandate({ perTxCap: usdc('500'), windows: [win(DAY, usdc('500'), 12)] });

  const justBeforeMidnight = DAY - 1;
  assert.equal(spend(m, req(usdc('500')), { now: justBeforeMidnight }).allowed, true);

  // one second later, across the period boundary
  const justAfterMidnight = DAY + 1;
  const d = evaluate(m, req(usdc('500')), { now: justAfterMidnight });
  assert.equal(d.allowed, false, 'boundary burst must be refused');
  assert.equal(d.reason, Denial.OVER_WINDOW_CAP);
  assert.equal(d.detail.headroom, 0n);

  // and it stays refused well into the next period, while history is still in window
  assert.equal(evaluate(m, req(usdc('500')), { now: DAY + 3600 }).reason, Denial.OVER_WINDOW_CAP);
});

test('window headroom returns only after the spend ages fully out', () => {
  const buckets = 12;
  const sub = DAY / buckets;
  const m = simpleMandate({ perTxCap: usdc('500'), windows: [win(DAY, usdc('500'), buckets)] });
  const t0 = 10 * DAY; // aligned to a bucket boundary
  assert.equal(spend(m, req(usdc('500')), { now: t0 }).allowed, true);
  assert.equal(evaluate(m, req(usdc('1')), { now: t0 + DAY - 1 }).reason, Denial.OVER_WINDOW_CAP);

  // Still refused one second past the nominal window: the engine charges up to one
  // extra sub-period of history, which is the documented cost of never overshooting.
  assert.equal(evaluate(m, req(usdc('1')), { now: t0 + DAY + 1 }).reason, Denial.OVER_WINDOW_CAP);

  // Once the spend's sub-bucket leaves the K+1 ring, the full cap is available again.
  assert.equal(evaluate(m, req(usdc('500')), { now: t0 + DAY + sub }).allowed, true);
});

test('a long idle gap clears the window completely', () => {
  const m = simpleMandate();
  assert.equal(spend(m, req(usdc('100')), { now: 1000 }).allowed, true);
  const h = headroom(m, 1000 + 30 * DAY);
  assert.equal(h.windows[0].used, 0n);
  assert.equal(h.windows[0].remaining, usdc('500'));
});

test('multiple windows compose: the tightest one binds', () => {
  // 200/day and 300/week. Once the daily window has drained, the WEEKLY cap is
  // what stops the next spend — and the denial must name the week, not the day.
  const dailyBuckets = 12;
  const dailySub = DAY / dailyBuckets;
  const m = createMandate({
    id: 'm', payer: PAYER, spender: AGENT,
    perTxCap: usdc('200'),
    expiresAt: FAR,
    windows: [win(DAY, usdc('200'), dailyBuckets), win(WEEK, usdc('300'), 7)],
  });
  const base = 100 * WEEK;
  assert.equal(spend(m, req(usdc('200')), { now: base }).allowed, true);

  // Far enough out that the daily ring has fully released the first spend
  // (a day plus one sub-period), but well inside the same week.
  const later = base + DAY + dailySub + 10;
  assert.equal(headroom(m, later).windows[0].remaining, usdc('200'), 'daily window has drained');

  const d = evaluate(m, req(usdc('200')), { now: later });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.OVER_WINDOW_CAP);
  assert.equal(d.detail.windowSeconds, BigInt(WEEK), 'the weekly cap is the binding one');
  assert.equal(spend(m, req(usdc('100')), { now: later }).allowed, true);
});

test('non-monotonic clock: repeated identical timestamps are handled', () => {
  // Arc sub-second blocks can share a timestamp. Many spends at one instant must
  // accumulate normally rather than overwrite each other.
  const m = simpleMandate();
  for (let i = 0; i < 5; i++) {
    assert.equal(spend(m, req(usdc('100')), { now: 777 }).allowed, true);
  }
  assert.equal(m.totalSpent, usdc('500'));
  assert.equal(evaluate(m, req(usdc('0.000001')), { now: 777 }).reason, Denial.OVER_WINDOW_CAP);
});

test('non-monotonic clock: a backwards timestamp cannot refill the cap', () => {
  const m = simpleMandate({ perTxCap: usdc('500') });
  const t = 50 * DAY;
  assert.equal(spend(m, req(usdc('500')), { now: t }).allowed, true);
  // A stale/backwards timestamp within the same window must not open headroom.
  assert.equal(evaluate(m, req(usdc('100')), { now: t - 10 }).reason, Denial.OVER_WINDOW_CAP);
});

test('ATTACK: a backwards clock cannot erase already-counted spending', () => {
  // Arc documents non-decreasing timestamps, so this should be unreachable — but
  // the cap should not depend on that promise. Rewinding by exactly K+1
  // sub-periods lands on a bucket index that collides with the one just written
  // in the ring; a naive claim-the-slot would silently drop the earlier amount.
  const K = 12;
  const S = DAY / K;
  const m = simpleMandate({ perTxCap: usdc('500'), windows: [win(DAY, usdc('500'), K)] });

  const tNew = 600 * S;
  assert.equal(spend(m, req(usdc('200')), { now: tNew }).allowed, true);

  const tOld = (600 - (K + 1)) * S;
  assert.equal(spend(m, req(usdc('300')), { now: tOld }).allowed, true);

  // 500 of a 500 cap is now committed. Neither clock reading may yield more.
  assert.equal(evaluate(m, req(usdc('1')), { now: tOld }).reason, Denial.OVER_WINDOW_CAP);
  assert.equal(evaluate(m, req(usdc('1')), { now: tNew }).reason, Denial.OVER_WINDOW_CAP);
});

// ---------------------------------------------------------------------------
// Every approval carries a deadline as of v2 (F16), and it is written out at each call site
// rather than defaulted inside a local helper — the same reasoning as FAR above. A wrapper
// that quietly supplied a deadline would also hide the fact that a real cosigner has to
// choose one, and choosing one is the entire point of the finding.
test('cosign: large spends need approval, small ones do not', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  assert.equal(spend(m, req(usdc('25')), { now: 1 }).allowed, true, 'at threshold: no cosign needed');
  const big = req(usdc('26'));
  assert.equal(evaluate(m, big, { now: 1 }).reason, Denial.COSIGN_REQUIRED);
  approveCosignFor(m, BOSS, { ...big, validUntil: DAY }, { now: 1 });
  assert.equal(spend(m, big, { now: 1 }).allowed, true);
});

test('cosign: an approval is single-use', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1 });
  assert.equal(spend(m, r, { now: 1 }).allowed, true);
  // Replay is caught by the nonce; and the approval was consumed as well.
  assert.equal(m.cosignApprovals.size, 0);
  assert.equal(evaluate(m, r, { now: 1 }).reason, Denial.NONCE_ALREADY_USED);
});

test('ATTACK: a cosign approval cannot be redirected to another recipient or amount', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const approved = req(usdc('50'), { recipient: VENDOR });
  approveCosignFor(m, BOSS, { ...approved, validUntil: DAY }, { now: 1 });

  // same nonce, different recipient — must not inherit the approval
  const swapRecipient = { ...approved, recipient: OTHER };
  assert.equal(evaluate(m, swapRecipient, { now: 1 }).reason, Denial.COSIGN_REQUIRED);

  // same nonce and recipient, larger amount — must not inherit the approval
  const swapAmount = { ...approved, amount: usdc('99') };
  assert.equal(evaluate(m, swapAmount, { now: 1 }).reason, Denial.COSIGN_REQUIRED);

  // the exact approved tuple still works
  assert.equal(evaluate(m, approved, { now: 1 }).allowed, true);
});

test('cosign: only the named cosigner may approve', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const at = { validUntil: DAY };
  assert.throws(
    () => approveCosignFor(m, AGENT, { ...req(usdc('50')), ...at }, { now: 1 }),
    /only the cosigner/,
  );
  assert.throws(
    () => approveCosignFor(m, PAYER, { ...req(usdc('50')), ...at }, { now: 1 }),
    /only the cosigner/,
  );
});

test('cosign (F16): an approval expires, and expiry is a DIFFERENT denial from absence', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1 });

  // One second before the deadline it is honoured.
  assert.equal(evaluate(m, r, { now: DAY - 1 }).allowed, true);

  // AT the deadline it is not. validUntil is exclusive, matching expiresAt and the contract:
  // with sub-second blocks sharing a timestamp, an inclusive bound would leave an ambiguous
  // final second in which the approval's liveness depends on block ordering within it.
  assert.equal(evaluate(m, r, { now: DAY }).reason, Denial.COSIGN_EXPIRED);
  assert.equal(evaluate(m, r, { now: DAY + 1 }).reason, Denial.COSIGN_EXPIRED);

  // Split from COSIGN_REQUIRED on purpose. "Nobody approved this" and "the cosigner approved
  // it and you were too slow" call for different actions by the caller — ask for a signature
  // versus ask for a fresh one — and collapsing them tells an operator to chase the wrong
  // party. A mandate with no approval at all still reports absence.
  const never = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  assert.equal(evaluate(never, req(usdc('50')), { now: DAY }).reason, Denial.COSIGN_REQUIRED);

  // The stale entry LINGERS in the map rather than being swept: nothing in a denial path
  // mutates state, and the contract behaves the same way — `cosignApprovalDeadline` keeps
  // returning the dead timestamp until the slot is overwritten or withdrawn. It is inert,
  // because every read compares it against the clock.
  assert.equal(m.cosignApprovals.get(hash), BigInt(DAY));
});

test('cosign (F16): a deadline in the past, at now, or beyond MAX_COSIGN_TTL is refused', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const now = 1_000;

  // Already dead on arrival. Refused rather than stored, because zero means "absent" in the
  // map and a past deadline would otherwise be an approval that exists and can never be
  // used — exactly the unconsumable state F17 is about.
  for (const bad of [0, 1, now - 1, now]) {
    assert.throws(
      () => approveCosignFor(m, BOSS, { ...req(usdc('50')), validUntil: bad }, { now }),
      /must be strictly after/,
      `validUntil=${bad} should be refused`,
    );
  }

  // The cap is what keeps F16 from being advisory. Without it the agent that builds the
  // transaction pre-fills the maximum and every approval is immortal again.
  assert.throws(
    () =>
      approveCosignFor(
        m,
        BOSS,
        { ...req(usdc('50')), validUntil: BigInt(now) + MAX_COSIGN_TTL + 1n },
        { now },
      ),
    /MAX_COSIGN_TTL/,
  );

  // Exactly at the cap is legal — the bound is inclusive on this side, so a cosigner who
  // wants the longest permitted window does not have to guess an off-by-one.
  const far = BigInt(now) + MAX_COSIGN_TTL;
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: far }, { now });
  assert.equal(m.cosignApprovals.get(hash), far);
  assert.equal(evaluate(m, r, { now: Number(far) - 1 }).allowed, true);
});

test('cosign (F16): ctx.now is required, so a deadline can never go unchecked', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  // A missing clock must throw rather than default. Defaulting `now` to 0 would accept every
  // deadline in history as "in the future", which is the failure this guard exists for.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('50')), validUntil: DAY }),
    /ctx\.now is required/,
  );
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('50')), validUntil: DAY }, {}),
    /ctx\.now is required/,
  );
});

test('ATTACK (F15): an approval cannot be steered to a spender the mandate does not name', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });

  // The old signature took a `spender` and fell back to the mandate's, so a caller could ask
  // the cosigner to approve the hash of a spend by OTHER. That hash matched nothing
  // `evaluate` can ever produce — WRONG_SPENDER refuses first — so the approval was
  // unspendable, and the cosigner had no way to see that from the arguments in front of
  // them: a signature that appears to authorise a payment and authorises nothing.
  //
  // `spendHash` now reads the spender off the mandate, so there is nowhere to put a
  // different one. The field is inert if supplied, which is what these two assertions pin.
  const r = req(usdc('50'));
  const hijack = { ...r, spender: OTHER, validUntil: DAY };
  const hash = approveCosignFor(m, BOSS, hijack, { now: 1 });

  assert.equal(
    hash,
    P.spendHash({ mandate: m, recipient: r.recipient, amount: r.amount, ref: '', nonce: r.nonce }),
    'the approved hash must be the mandate-spender hash, not the hijacked one',
  );

  // And it is a live approval for the real spender's spend, rather than a dead entry.
  assert.equal(spend(m, r, { now: 1 }).allowed, true);
});

// ---------------------------------------------------------------------------
// F17: an approval no spend could ever consume is refused rather than stored.
//
// The refusal codes are asserted, not the messages, because the codes are the claim: every
// mirrored condition reuses the SAME `Denial` value `evaluate` would return, and the parity
// test at the end of this block is what that reuse is for. `assert.throws` with a predicate
// rather than a regex, so a test cannot pass on a coincidentally-matching message.
const refusedWith = (code) => (err) => {
  assert.equal(err.code, code, `expected refusal code ${code}, got ${err.code}: ${err.message}`);
  return true;
};

const cosignMandate = (over = {}) =>
  simpleMandate({ cosigner: BOSS, cosignThreshold: usdc('10'), ...over });

test('cosign (F17): the prologue answers WHY nobody may approve, not just that you may not', () => {
  // This test exists because a mutation run over `approveCosignFor` found all fifteen other
  // guards and lost this one: neutering the no-cosigner check still refused the same input,
  // one line lower, under the wrong code. Two guards that refuse the same call for different
  // reasons hide each other, so the codes need asserting even where the refusal is certain.
  const at = { validUntil: DAY };

  assert.throws(
    () => approveCosignFor(null, BOSS, { ...req(usdc('50')), ...at }, { now: 1 }),
    refusedWith(Denial.UNKNOWN_MANDATE),
  );

  // A mandate with no cosign gate at all — the ordinary ungated grant, and the most likely
  // way for a caller to arrive here by mistake. BAD_CONFIG, not NOT_COSIGNER: the second is
  // technically true (nobody is null's cosigner) and would send whoever reads it hunting for
  // a signing key that does not exist, when nothing on this mandate is gated.
  const ungated = simpleMandate();
  assert.equal(ungated.cosigner, null);
  assert.throws(
    () => approveCosignFor(ungated, BOSS, { ...req(usdc('50')), ...at }, { now: 1 }),
    refusedWith(ApprovalRefusal.BAD_CONFIG),
  );

  // And with a gate present, the wrong caller gets NOT_COSIGNER — so the two codes are
  // distinguishing the two situations rather than one of them shadowing the other.
  assert.throws(
    () => approveCosignFor(cosignMandate(), AGENT, { ...req(usdc('50')), ...at }, { now: 1 }),
    refusedWith(ApprovalRefusal.NOT_COSIGNER),
  );
});

test('cosign (F17): a revoked or expired mandate cannot be approved against', () => {
  const dead = cosignMandate();
  revoke(dead, PAYER);
  assert.throws(
    () => approveCosignFor(dead, BOSS, { ...req(usdc('50')), validUntil: DAY }, { now: 1 }),
    refusedWith(Denial.REVOKED),
  );

  // `revoked` is one-way and `expiresAt` is fixed at creation, which is what makes both of
  // these permanent and therefore safe to refuse.
  const expired = cosignMandate({ expiresAt: DAY });
  assert.throws(
    () => approveCosignFor(expired, BOSS, { ...req(usdc('50')), validUntil: DAY + 1 }, { now: DAY }),
    // EXPIRED, not BAD_DEADLINE, and that ordering is the point of this assertion. At the
    // instant a mandate dies, every legal `validUntil` is necessarily past `expiresAt` too, so
    // a version that checked the deadline first would tell the cosigner to send a different
    // deadline when no deadline can work. Sending the reader to fix the wrong thing is worse
    // than not refusing at all, so liveness is checked first and this pins it.
    refusedWith(Denial.EXPIRED),
  );
  assert.equal(evaluate(expired, req(usdc('50')), { now: DAY }).reason, Denial.EXPIRED);
});

test('cosign (F17): an approval at or below the threshold is refused', () => {
  const m = cosignMandate();

  // The one F17 refusal that is not about consumability. `evaluate` reads the approval Map
  // solely when `amount > cosignThreshold`, so at or below the threshold this approval would
  // sit in the Map, cost the cosigner a transaction, and never be read. Refused because of
  // what it would let them believe: that they had gated a payment that is not gated.
  for (const amount of [usdc('10'), usdc('1'), 1n]) {
    assert.throws(
      () => approveCosignFor(m, BOSS, { ...req(amount), validUntil: DAY }, { now: 1 }),
      refusedWith(ApprovalRefusal.COSIGN_NOT_REQUIRED),
      `${amount} should need no signature`,
    );
  }

  // One unit above the threshold is approvable, so both functions read the same boundary the
  // same way — `evaluate`'s comparison is a strict `>` and this one is its exact complement.
  const r = req(usdc('10') + 1n);
  assert.equal(evaluate(m, r, { now: 1 }).reason, Denial.COSIGN_REQUIRED);
  approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1 });
  assert.equal(spend(m, r, { now: 1 }).allowed, true);
});

test('cosign (F17): a malformed recipient, amount or nonce is refused', () => {
  const m = cosignMandate();
  const at = { validUntil: DAY };

  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('50')), recipient: ZERO_ADDRESS, ...at }, { now: 1 }),
    refusedWith(Denial.ZERO_RECIPIENT),
  );

  // ZERO_AMOUNT, not COSIGN_NOT_REQUIRED, even though zero is also at-or-below every
  // threshold. Both statements are true and only one is useful, so the ordering decides —
  // and it decides the same way `evaluate` does.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(0n), ...at }, { now: 1 }),
    refusedWith(Denial.ZERO_AMOUNT),
  );
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(MAX_AMOUNT + 1n), ...at }, { now: 1 }),
    refusedWith(Denial.AMOUNT_TOO_LARGE),
  );

  // A used nonce is used for good. This is the condition a cosigner is least placed to
  // notice, because the agent supplies the nonce — and an agent that supplies a spent one is
  // asking for a signature on a payment that cannot happen.
  const consumed = req(usdc('5')); // at or below the threshold, so it needs no signature
  assert.equal(spend(m, consumed, { now: 1 }).allowed, true);
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...consumed, amount: usdc('50'), ...at }, { now: 1 }),
    refusedWith(Denial.NONCE_ALREADY_USED),
  );

  const gated = cosignMandate({ allowlist: [VENDOR] });
  assert.throws(
    () => approveCosignFor(gated, BOSS, { ...req(usdc('50')), recipient: OTHER, ...at }, { now: 1 }),
    refusedWith(Denial.RECIPIENT_NOT_ALLOWED),
  );
  // The allowlisted recipient is unaffected, which is what makes the line above a guard
  // rather than a break.
  approveCosignFor(gated, BOSS, { ...req(usdc('50')), recipient: VENDOR, ...at }, { now: 1 });
});

test('cosign (F17): a PERMANENT cap shortfall is refused; a temporary one is not', () => {
  const m = cosignMandate({ perTxCap: usdc('100'), totalCap: usdc('100') });
  const at = { validUntil: DAY };

  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('100') + 1n), ...at }, { now: 1 }),
    refusedWith(Denial.OVER_PER_TX_CAP),
  );

  // Five spends at exactly the threshold need no signature, which is what lets this consume
  // the lifetime cap without first solving the problem it is trying to pose.
  for (let i = 0; i < 5; i++) {
    assert.equal(spend(m, req(usdc('10')), { now: 1 }).allowed, true);
  }
  assert.equal(m.totalSpent, usdc('50'));

  // `totalSpent` only grows, so headroom only shrinks and a shortfall now is a shortfall
  // forever. That is exactly what makes this safe to refuse and the rolling windows not.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('60')), ...at }, { now: 1 }),
    refusedWith(Denial.OVER_TOTAL_CAP),
  );

  // Precisely the remaining headroom must still be approvable, or the guard would be
  // refusing on a partly spent mandate rather than reading it.
  const fits = req(usdc('50'));
  approveCosignFor(m, BOSS, { ...fits, ...at }, { now: 1 });
  assert.equal(spend(m, fits, { now: 1 }).allowed, true);
  assert.equal(m.totalSpent, usdc('100'));

  // The uint96 audit ceiling, reachable only with no lifetime cap — see TOTAL_SPENT_CEILING.
  //
  // Asserted one base unit either side of the boundary, which the first version of this block
  // did not do: it sat `totalSpent` at MAX_AMOUNT - 10n and approved 100n, well past the cliff.
  // That refuses, but so would a guard off by one in either direction, and so would a guard
  // that refused any mandate whose counter was merely large. `cosignThreshold: 0n` is what
  // makes the tight version expressible — the model documents 0 as "require a signature for
  // every amount" — because at the inherited threshold of 10 USDC an approval for 1n or 2n
  // would come back COSIGN_NOT_REQUIRED and the test would be measuring guard ORDER instead of
  // the width of the counter. The contract's twin,
  // `test_f17_approvingPastTheUint96AuditCeiling_isRefused`, is built the same way for the same
  // reason, and exists because the Solidity mutation gate found this guard unasserted there
  // while it was already asserted here.
  const uncapped = cosignMandate({ perTxCap: null, windows: [], cosignThreshold: 0n });
  uncapped.totalSpent = MAX_AMOUNT - 1n;
  assert.throws(
    () => approveCosignFor(uncapped, BOSS, { ...req(2n), ...at }, { now: 1 }),
    refusedWith(Denial.TOTAL_SPENT_CEILING),
  );

  // And the last base unit the counter can hold is approvable, and spendable.
  const lastUnit = req(1n);
  approveCosignFor(uncapped, BOSS, { ...lastUnit, ...at }, { now: 1 });
  assert.equal(spend(uncapped, lastUnit, { now: 1 }).allowed, true);
  assert.equal(uncapped.totalSpent, MAX_AMOUNT);
});

test('cosign (F17): the deadline must outlive notBefore and die by the expiry', () => {
  // Both bounds refuse rather than clamp, for F16's reason: a deadline the model quietly
  // moved is a deadline the cosigner did not agree to.
  const late = cosignMandate({ notBefore: 2 * DAY });

  // An approval whose whole life sits inside the not-yet-valid window is unconsumable for
  // every second of it.
  for (const bad of [DAY, 2 * DAY]) {
    assert.throws(
      () => approveCosignFor(late, BOSS, { ...req(usdc('50')), validUntil: bad }, { now: 1 }),
      refusedWith(ApprovalRefusal.BAD_DEADLINE),
      `validUntil=${bad} against notBefore=${2 * DAY}`,
    );
  }
  // AT notBefore is refused because `validUntil` is exclusive and `notBefore` inclusive, so
  // an approval ending at T and a mandate starting at T share no instant. One second of
  // overlap is enough, and has to be.
  const usable = req(usdc('50'));
  approveCosignFor(late, BOSS, { ...usable, validUntil: 2 * DAY + 1 }, { now: 1 });
  assert.equal(spend(late, usable, { now: 2 * DAY }).allowed, true);

  // The other direction: the stretch of an approval that outlives the mandate is authority
  // that cannot be exercised. Unbounded, a 30-day approval on a mandate expiring tomorrow
  // shows the cosigner a month and means a day.
  const short = cosignMandate({ expiresAt: DAY });
  assert.throws(
    () => approveCosignFor(short, BOSS, { ...req(usdc('50')), validUntil: DAY + 1 }, { now: 1 }),
    refusedWith(ApprovalRefusal.BAD_DEADLINE),
  );
  // Exactly AT expiresAt is legal, and that is the correct boundary rather than an
  // off-by-one: both values are exclusive, so an approval dying at T grants nothing on a
  // mandate that is also dead at T.
  const hash = approveCosignFor(short, BOSS, { ...req(usdc('50')), validUntil: DAY }, { now: 1 });
  assert.equal(short.cosignApprovals.get(hash), BigInt(DAY));
});

test('cosign (F17): what must NOT be refused — notBefore, a full window, a missing credential', () => {
  // The hard half of the finding. Each of these three is a condition `evaluate` denies and
  // this function must NOT, because each one CLEARS: refusing here would make a legitimate
  // large payment unapprovable until the cosigner is chased a second time, which for a
  // payments primitive is a liveness failure of our own making. Each case therefore proves
  // the approval was genuinely usable once the condition passed, not merely that it stored.

  // (a) A start date in the future. The ordinary case for a scheduled payment.
  const later = cosignMandate({ notBefore: DAY });
  const r1 = req(usdc('50'));
  assert.equal(evaluate(later, r1, { now: 1 }).reason, Denial.NOT_YET_VALID);
  approveCosignFor(later, BOSS, { ...r1, validUntil: 3 * DAY }, { now: 1 });
  assert.equal(spend(later, r1, { now: DAY }).allowed, true);

  // (b) A full rolling window — the sharpest of the three, because the window arithmetic is
  // the most tempting to mirror and the least safe to. `windowUsage` FALLS as buckets age
  // out, so an amount refused now fits later with nothing else changed.
  const S = DAY / 12;
  const t0 = 100 * S; // aligned, so the five spends share one bucket and age out together
  const full = cosignMandate({ windows: [win(DAY, usdc('50'), 12)] });
  for (let i = 0; i < 5; i++) {
    assert.equal(spend(full, req(usdc('10')), { now: t0 }).allowed, true);
  }
  const r2 = req(usdc('50'));
  assert.equal(evaluate(full, r2, { now: t0 }).reason, Denial.OVER_WINDOW_CAP);
  approveCosignFor(full, BOSS, { ...r2, validUntil: t0 + 3 * DAY }, { now: t0 });
  // One bucket past the window: `oldest` has moved beyond the bucket the five spends landed
  // in, so usage is back to zero and the approved amount fits exactly.
  assert.equal(spend(full, r2, { now: t0 + DAY + S }).allowed, true);

  // (c) An ERC-8004 credential not yet filed. Recoverable by a third party the cosigner does
  // not control — and note what mirroring it would have cost, visible here in a way it is not
  // in the contract: `approveCosignFor` takes no ctx beyond `now`. To refuse on this it would
  // have to accept `resolveCredential` and consult live registry state before agreeing to
  // store an approval. The contract says the same thing in gas: two external staticcalls on
  // the approval path.
  const unattested = cosignMandate({
    identity: { agentId: 42n, expectedOwner: AGENT },
    credential: { validator: BOSS, requestHash: '0xkyc-f17', minResponse: 100n, maxStaleness: 30n * BigInt(DAY) },
  });
  const r3 = req(usdc('50'));
  assert.equal(evaluate(unattested, r3, withCred(() => null)).reason, Denial.CREDENTIAL_MISSING);
  approveCosignFor(unattested, BOSS, { ...r3, validUntil: 1_000_000 + DAY }, { now: 1_000_000 });
  assert.equal(spend(unattested, r3, withCred(attestation())).allowed, true);
});

test('cosign (F17): a single-defect request is refused with the SAME code by both functions', () => {
  // The claim stated exactly, because the obvious version of it is false. These two cannot
  // always agree: the recoverable conditions `approveCosignFor` skips sit BETWEEN the
  // permanent ones it keeps, so a request that is both over `perTxCap` and behind a missing
  // credential gets CREDENTIAL_MISSING from `evaluate` and OVER_PER_TX_CAP from the approval.
  // With ONE defect they must agree — which is also the only case a cosigner could act on.
  const m = cosignMandate({ perTxCap: usdc('100'), allowlist: [VENDOR] });
  const spent = req(usdc('5'), { recipient: VENDOR });
  assert.equal(spend(m, spent, { now: 1 }).allowed, true);

  const cases = [
    ['zero recipient', { ...req(usdc('50')), recipient: ZERO_ADDRESS }],
    ['recipient not allowlisted', { ...req(usdc('50')), recipient: OTHER }],
    ['zero amount', { ...req(0n), recipient: VENDOR }],
    ['amount above 2^96 - 1', { ...req(MAX_AMOUNT + 1n), recipient: VENDOR }],
    ['over perTxCap', { ...req(usdc('100') + 1n), recipient: VENDOR }],
    ['nonce already used', { ...spent, amount: usdc('50') }],
  ];

  for (const [what, request] of cases) {
    const denial = evaluate(m, request, { now: 1 });
    assert.equal(denial.allowed, false, `evaluate must refuse: ${what}`);
    assert.throws(
      () => approveCosignFor(m, BOSS, { ...request, validUntil: DAY }, { now: 1 }),
      refusedWith(denial.reason),
      `approveCosignFor must refuse ${what} with evaluate's code (${denial.reason})`,
    );
  }
});

// ---------------------------------------------------------------------------
test('identity gate: spender must currently hold the bound ERC-8004 agentId', () => {
  const m = simpleMandate({ identity: { agentId: 42n, expectedOwner: AGENT } });
  const ownerOf = (id) => (id === 42n ? AGENT : null);
  assert.equal(evaluate(m, req(usdc('10')), { now: 1, resolveIdentityOwner: ownerOf }).allowed, true);

  // registry says nobody holds it
  assert.equal(
    evaluate(m, req(usdc('10')), { now: 1, resolveIdentityOwner: () => null }).reason,
    Denial.IDENTITY_NOT_HELD,
  );
});

test('ATTACK: transferring the agent identity NFT does not carry spending authority', () => {
  // ERC-8004 identities are transferable ERC-721s. A live ownerOf check alone
  // would hand authority to whoever the token is sold to. Pinning the expected
  // owner at grant time is what stops that.
  const m = simpleMandate({ identity: { agentId: 42n, expectedOwner: AGENT } });
  const afterTransfer = { now: 1, resolveIdentityOwner: () => OTHER };
  // OTHER now holds the identity and tries to spend
  const d = evaluate(m, req(usdc('10'), { spender: OTHER }), afterTransfer);
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.WRONG_SPENDER);

  // and the original agent can no longer spend either, since it lost the token
  const d2 = evaluate(m, req(usdc('10')), afterTransfer);
  assert.equal(d2.reason, Denial.IDENTITY_NOT_HELD);
});

// Mirrors ERC-8004 getValidationStatus(bytes32) →
// (validatorAddress, agentId, response, responseHash, tag, lastUpdate)
const attestation = (over = {}) => () => ({
  validator: BOSS,
  agentId: 42n,
  response: 100n,
  lastUpdate: 1_000_000 - 100,
  ...over,
});

const credMandate = (over = {}) =>
  simpleMandate({
    identity: { agentId: 42n, expectedOwner: AGENT },
    credential: { validator: BOSS, requestHash: '0xkyc', minResponse: 100n, maxStaleness: 30n * BigInt(DAY), ...over },
  });

const withCred = (resolve) => ({
  now: 1_000_000,
  resolveIdentityOwner: () => AGENT,
  resolveCredential: resolve,
});

test('credential gate: requires a passing, fresh attestation', () => {
  const m = credMandate();
  assert.equal(evaluate(m, req(usdc('10')), withCred(attestation())).allowed, true);

  // no attestation at all
  assert.equal(evaluate(m, req(usdc('10')), withCred(() => null)).reason, Denial.CREDENTIAL_MISSING);

  // failing response (100 = passed per the ERC-8004 tutorial)
  assert.equal(
    evaluate(m, req(usdc('10')), withCred(attestation({ response: 0n }))).reason,
    Denial.CREDENTIAL_MISSING,
  );

  // passing but stale
  assert.equal(
    evaluate(m, req(usdc('10')), withCred(attestation({ lastUpdate: 1_000_000 - 31 * DAY }))).reason,
    Denial.CREDENTIAL_STALE,
  );
});

test('credential gate: maxStaleness of 0 means no freshness requirement at all', () => {
  // A real encoding hazard, and the contract's reading is the one that governs: the
  // on-chain field is a uint40 with no null, so 0 is the value a caller leaves in a
  // struct they did not think about. It therefore has to select the PERMISSIVE
  // branch — reading it as "must have been attested this very second" would make an
  // unset field mean a mandate that can never spend.
  //
  // The cost is real and is in the README: a payer who forgets the field gets a gate
  // that never expires. That is the better failure of the two.
  const zero = credMandate({ maxStaleness: 0n });
  const ancient = attestation({ lastUpdate: 1_000_000 - 3650 * DAY });
  assert.equal(evaluate(zero, req(usdc('10')), withCred(ancient)).allowed, true);

  // null keeps working and means the same thing, for callers writing the model
  // directly rather than encoding a struct.
  const omitted = credMandate({ maxStaleness: null });
  assert.equal(evaluate(omitted, req(usdc('10')), withCred(ancient)).allowed, true);

  // And a positive value still enforces.
  const strict = credMandate({ maxStaleness: BigInt(DAY) });
  assert.equal(evaluate(strict, req(usdc('10')), withCred(ancient)).reason, Denial.CREDENTIAL_STALE);
});

test('credential gate: agentId of 0 means unset, and unset with no identity skips the check', () => {
  // The same encoding hazard as maxStaleness, and the same resolution: the contract's
  // field is a uint256 with no null, so `c.agentId != 0` is what "unset" has to mean.
  // A model that used `??` here would treat 0 as "require the attestation to be about
  // agent 0" — a state the contract cannot express, and the kind of divergence that
  // makes the model useless as a specification precisely where it matters most.

  // An explicit 0 falls through to the identity gate, so agent 42 is still required.
  const zeroed = credMandate({ agentId: 0n });
  assert.equal(evaluate(zeroed, req(usdc('10')), withCred(attestation())).allowed, true);
  assert.equal(
    evaluate(zeroed, req(usdc('10')), withCred(attestation({ agentId: 999n }))).reason,
    Denial.CREDENTIAL_WRONG_AGENT,
    'an explicit zero must inherit the identity gate, not disable the check',
  );

  // DOCUMENTED GAP: zero on both sides skips the comparison entirely. With no identity
  // gate to inherit from there is no id to compare against, so the gate degrades to
  // "the named validator attested this exact requestHash". Bounded because the payer
  // fixes requestHash at grant time; caveated in DESIGN.md; pinned in Solidity as
  // test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent.
  const unbound = simpleMandate({
    credential: { validator: BOSS, requestHash: '0xkyc', minResponse: 100n, maxStaleness: null, agentId: 0n },
  });
  const strangerAttestation = attestation({ agentId: 999n });
  assert.equal(
    evaluate(unbound, req(usdc('10')), withCred(strangerAttestation)).allowed,
    true,
    'known weakening: an unbound credential accepts an attestation about anyone',
  );

  // What keeps it bounded: the validator is still checked, on the same tuple.
  assert.equal(
    evaluate(unbound, req(usdc('10')), withCred(attestation({ agentId: 999n, validator: OTHER }))).reason,
    Denial.CREDENTIAL_WRONG_VALIDATOR,
  );
});

test('ATTACK: an attestation from the wrong validator does not satisfy the gate', () => {
  // getValidationStatus is keyed only by requestHash, so an attacker can have a
  // cooperative validator answer any hash. The gate must check who answered.
  const m = credMandate();
  const d = evaluate(m, req(usdc('10')), withCred(attestation({ validator: OTHER })));
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.CREDENTIAL_WRONG_VALIDATOR);
});

test('ATTACK: an attestation about a different agent does not satisfy the gate', () => {
  // A real, passing, fresh attestation from the right validator — but issued
  // about somebody else's agentId. Must not transfer.
  const m = credMandate();
  const d = evaluate(m, req(usdc('10')), withCred(attestation({ agentId: 999n })));
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.CREDENTIAL_WRONG_AGENT);
});

// ---------------------------------------------------------------------------
test('headroom reports the binding constraint', () => {
  const m = createMandate({
    id: 'm', payer: PAYER, spender: AGENT,
    perTxCap: usdc('100'),
    totalCap: usdc('120'),
    windows: [win(DAY, usdc('500'), 12)],
  });
  assert.equal(headroom(m, 1).maxSpendNow, usdc('100'), 'per-tx cap binds first');
  spend(m, req(usdc('100')), { now: 1 });
  assert.equal(headroom(m, 1).maxSpendNow, usdc('20'), 'total cap now binds');
});

// ------------------------------------------------- the joint ceiling (NEW IN v2)
//
// Six tests for one small function, because every one of them pins a way the
// obvious implementation (`sum += headroom(m).maxSpendNow`) returns a confidently
// wrong number rather than failing loudly.

test('joint ceiling: one mandate agrees exactly with the single-mandate view', () => {
  const m = createMandate({
    id: 'j1', payer: PAYER, spender: AGENT,
    perTxCap: usdc('100'),
    expiresAt: FAR,
    windows: [win(DAY, usdc('500'), 12)],
  });
  // The property that makes the joint view trustworthy: it is not a separate
  // opinion about a mandate, it is the same opinion summed. If these ever diverge
  // the joint view has grown a rule the per-mandate view does not have.
  assert.equal(headroomAcross([m], 1).maxJointSpendNow, headroom(m, 1).maxSpendNow);
  assert.equal(headroomAcross([m], 1).payer, PAYER.toLowerCase());
  assert.equal(headroomAcross([m], 1).count, 1);
});

test('joint ceiling: the overlap the per-mandate views cannot show', () => {
  // The shape of the 2026-08-24 demonstration on Arc, with the caps chosen so the
  // policy half equals what `spendable` reported there — two mandates, each
  // reporting 90,000 base units, against one allowance of 90,000. What this model
  // can show is that the policy sum is 180,000; that the true joint ceiling is
  // 90,000 is the contract's clamp against allowance and balance, which this file
  // has no token to perform. Both halves matter: the sum is what a caller would
  // naively add up, and the clamp is what makes it a lie.
  const a = createMandate({ id: 'j2a', payer: PAYER, spender: AGENT, perTxCap: 90_000n, expiresAt: FAR });
  const b = createMandate({ id: 'j2b', payer: PAYER, spender: OTHER, perTxCap: 90_000n, expiresAt: FAR });
  assert.equal(headroom(a, 1).maxSpendNow, 90_000n);
  assert.equal(headroom(b, 1).maxSpendNow, 90_000n);
  assert.equal(headroomAcross([a, b], 1).maxJointSpendNow, 180_000n);
});

test('joint ceiling: an unbounded term clamps at MAX_AMOUNT instead of overflowing', () => {
  // `headroom()` reports null — "no cap on any axis the payer set" — for a mandate
  // bounded only by an expiry. In Solidity the same case returns type(uint256).max,
  // so `sum += policyHeadroom(id)` over two of these PANICS. Not remotely: two
  // expiry-only grants from one payer is a two-line construction, which is what
  // makes this the same failure class as the totalSpent cliff #10 fixed.
  const spec = (id) => ({ id, payer: PAYER, spender: AGENT, expiresAt: 10_000n });
  const a = createMandate(spec('j3a'));
  const b = createMandate(spec('j3b'));
  assert.equal(headroom(a, 1).maxSpendNow, null, 'unbounded on every axis the payer set');
  assert.equal(headroomAcross([a, b], 1).maxJointSpendNow, 2n * MAX_AMOUNT);

  // The other clamp path: a cap larger than a spend could ever be. Nothing rejects
  // this at grant time — perTxCap is not checked against MAX_AMOUNT — so the cap is
  // stored and `headroom` reports it faithfully. It is still not the largest single
  // spend, because AmountTooLarge refuses anything above MAX_AMOUNT first.
  const huge = createMandate({ id: 'j3c', payer: PAYER, spender: AGENT, perTxCap: 1n << 200n, expiresAt: FAR });
  assert.equal(headroom(huge, 1).maxSpendNow, 1n << 200n, 'the view repeats the stored cap');
  assert.equal(headroomAcross([huge], 1).maxJointSpendNow, MAX_AMOUNT, 'the joint view corrects it');

  // And with every term bounded, the widest total the contract can be asked for —
  // its array cap of 8, all unbounded — is nowhere near a uint256. This is the
  // arithmetic that makes a saturating add unnecessary rather than merely unused.
  const eight = Array.from({ length: 8 }, (_, i) => createMandate(spec(`j3d${i}`)));
  const widest = headroomAcross(eight, 1).maxJointSpendNow;
  assert.equal(widest, 8n * MAX_AMOUNT);
  assert.ok(widest < 1n << 99n);
  assert.ok(widest < (1n << 256n) - 1n);
});

test('joint ceiling: mandates held against different payers are refused, not summed', () => {
  const a = createMandate({ id: 'j4a', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  const b = createMandate({ id: 'j4b', payer: OTHER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  assert.throws(() => headroomAcross([a, b], 1), /must share one payer/);
  // Order does not matter — the payer is taken from the first element, so the
  // reversed array must be refused for the same reason and not silently accept
  // whichever payer happened to be named first.
  assert.throws(() => headroomAcross([b, a], 1), /must share one payer/);
  // Separately, each is a perfectly good single-payer request.
  assert.equal(headroomAcross([a], 1).maxJointSpendNow, usdc('100'));
  assert.equal(headroomAcross([b], 1).maxJointSpendNow, usdc('100'));
});

test('joint ceiling: naming the same mandate twice is refused', () => {
  const a = createMandate({ id: 'j5', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  assert.throws(() => headroomAcross([a, a], 1), /named more than once/);
  // The reason this is refused rather than deduplicated: the caller asked a
  // question about a set they got wrong, and 200 is a more convincing answer than
  // 100 to somebody who believes they hold two mandates. Deduplicating would
  // return the right number to a caller still holding the wrong belief.
  const b = createMandate({ id: 'j5b', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  assert.throws(() => headroomAcross([a, b, a], 1), /named more than once/);
  assert.equal(headroomAcross([a, b], 1).maxJointSpendNow, usdc('200'));
});

test('joint ceiling: an empty set is answered, and dead mandates contribute zero', () => {
  assert.deepEqual(headroomAcross([], 1), { payer: null, count: 0, maxJointSpendNow: 0n });

  // Revoked and expired mandates must NOT throw — they are the ordinary contents of
  // any real caller's list, and a view that refused them would be unusable exactly
  // when a payer most wants to check what is still live.
  const live = createMandate({ id: 'j6a', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  const dead = createMandate({ id: 'j6b', payer: PAYER, spender: AGENT, perTxCap: usdc('100'), expiresAt: FAR });
  const gone = createMandate({ id: 'j6c', payer: PAYER, spender: AGENT, expiresAt: 500n });
  revoke(dead, PAYER);
  assert.equal(headroomAcross([live, dead, gone], 1000).maxJointSpendNow, usdc('100'));
  // Sanity: the expiry-only one was worth MAX_AMOUNT before it lapsed, so the zero
  // above is the expiry doing the work and not the clamp silently failing.
  assert.equal(headroomAcross([gone], 1).maxJointSpendNow, MAX_AMOUNT);
});

test('REGRESSION: a spend late in a sub-bucket is still counted K buckets later', () => {
  // This is the minimal form of the bug the fuzz test found. The ring originally
  // summed buckets [b-K+1, b], which spans L seconds but ends at the END of the
  // current bucket — so it dropped bucket b-K while that bucket still overlapped
  // the true trailing window. Spending late in a sub-bucket and again exactly K
  // sub-buckets later therefore passed twice.
  const K = 4;
  const S = DAY / K; // 21600
  const m = createMandate({
    id: 'leak', payer: PAYER, spender: AGENT,
    expiresAt: FAR,
    windows: [win(DAY, usdc('1000'), K)],
  });

  const b0 = 16n; // arbitrary aligned bucket
  const lateInBucket = Number(b0 * BigInt(S)) + S - 1; // last second of b0
  assert.equal(spend(m, req(usdc('1000')), { now: lateInBucket }).allowed, true);

  // Exactly K sub-buckets later: b advances by K, so b-K == b0. The first spend
  // is still inside the true trailing window (t-L, t], so it must still count.
  const t2 = Number((b0 + BigInt(K)) * BigInt(S));
  assert.ok(lateInBucket > t2 - DAY, 'precondition: first spend is inside the true window');
  const d = evaluate(m, req(usdc('1000')), { now: t2 });
  assert.equal(d.allowed, false, 'the earlier spend must not have fallen out of the ring');
  assert.equal(d.reason, Denial.OVER_WINDOW_CAP);

  // One second past the full window from the original spend, it may age out.
  assert.equal(evaluate(m, req(usdc('1000')), { now: lateInBucket + DAY + S }).allowed, true);
});

// ---------------------------------------------------------------------------
// The central safety property, established by fuzzing rather than assertion.
test('PROPERTY (fuzz): accepted spends never exceed the cap in any true trailing window', () => {
  const L = DAY;
  const CAP = usdc('1000');

  for (let bucketCount of [4, 12, 24]) {
    for (let seed = 1; seed <= 40; seed++) {
      // deterministic LCG so a failure is reproducible from the seed
      let s = seed * 2654435761 % 2147483647;
      const rnd = (max) => { s = (s * 48271) % 2147483647; return s % max; };

      const m = createMandate({
        id: `fuzz-${bucketCount}-${seed}`, payer: PAYER, spender: AGENT,
        expiresAt: FAR,
        windows: [win(L, CAP, bucketCount)],
      });

      const accepted = []; // { t, amount } ledger of what actually went through
      let t = 1_000_000;

      for (let step = 0; step < 300; step++) {
        // non-decreasing clock, sometimes standing still (sub-second blocks),
        // sometimes jumping far enough to age history out
        t += [0, 0, 1, 37, 600, 5000, 30000, 90000][rnd(8)];
        const amount = BigInt(1 + rnd(400)) * 1_000_000n;

        const d = spend(m, { spender: AGENT, recipient: VENDOR, amount, nonce: `f${step}` }, { now: t });
        if (!d.allowed) {
          assert.equal(d.reason, Denial.OVER_WINDOW_CAP, `unexpected denial: ${d.reason}`);
          continue;
        }
        accepted.push({ t, amount });

        // EXACT sliding window, computed by brute force over the real ledger.
        // The window is (t - L, t]: everything strictly newer than t - L.
        const trueUsage = accepted
          .filter((e) => e.t > t - L)
          .reduce((sum, e) => sum + e.amount, 0n);

        assert.ok(
          trueUsage <= CAP,
          `cap breached: buckets=${bucketCount} seed=${seed} step=${step} ` +
            `trueUsage=${P.formatUsdc(trueUsage)} > cap=${P.formatUsdc(CAP)}`,
        );
      }
    }
  }
});

test('PROPERTY (fuzz): a GREEDY adversary aiming at bucket boundaries cannot exceed the cap', () => {
  // The strongest adversary for a rate cap: always ask for exactly the headroom
  // the engine is willing to give, and always land on a boundary-relevant offset.
  // Random amounts explore the space; this explores the edges on purpose.
  const L = DAY;
  const CAP = usdc('1000');

  for (const K of [2, 3, 4, 6, 12, 24]) {
    const S = L / K;
    // Offsets chosen to straddle every boundary the algorithm reasons about.
    const offsets = [0, 1, S - 1, S, S + 1, L - 1, L, L + 1, L + S - 1, L + S, L + S + 1];

    for (let seed = 1; seed <= 25; seed++) {
      let s = (seed * 2654435761) % 2147483647;
      const rnd = (max) => { s = (s * 48271) % 2147483647; return s % max; };

      const m = createMandate({
        id: `greedy-${K}-${seed}`, payer: PAYER, spender: AGENT,
        expiresAt: FAR,
        windows: [win(L, CAP, K)],
      });

      const accepted = [];
      let t = 1_000_000;

      for (let step = 0; step < 200; step++) {
        t += offsets[rnd(offsets.length)];

        // Ask for exactly what the engine says is available — the worst case.
        const avail = headroom(m, t).windows[0].remaining;
        const amount = rnd(4) === 0 ? avail / 2n : avail; // mostly greedy, sometimes not
        if (amount <= 0n) continue;

        const d = spend(m, { spender: AGENT, recipient: VENDOR, amount, nonce: `g${step}` }, { now: t });
        assert.equal(d.allowed, true, `engine offered ${amount} then refused it: ${d.reason}`);
        accepted.push({ t, amount });

        const trueUsage = accepted
          .filter((e) => e.t > t - L)
          .reduce((sum, e) => sum + e.amount, 0n);
        assert.ok(
          trueUsage <= CAP,
          `cap breached: K=${K} seed=${seed} step=${step} ` +
            `trueUsage=${P.formatUsdc(trueUsage)} > cap=${P.formatUsdc(CAP)}`,
        );
      }
    }
  }
});

test('PROPERTY (fuzz): two windows enforced together, neither leaks', () => {
  // A daily and a weekly cap on the same mandate. Both must hold simultaneously;
  // the ring for one window must not disturb the ring for the other.
  const DAILY = usdc('300');
  const WEEKLY = usdc('1000');

  for (let seed = 1; seed <= 30; seed++) {
    let s = (seed * 2654435761) % 2147483647;
    const rnd = (max) => { s = (s * 48271) % 2147483647; return s % max; };

    const m = createMandate({
      id: `two-${seed}`, payer: PAYER, spender: AGENT,
      expiresAt: FAR,
      windows: [win(DAY, DAILY, 12), win(WEEK, WEEKLY, 7)],
    });

    const accepted = [];
    let t = 5_000_000;

    for (let step = 0; step < 250; step++) {
      t += [0, 1, 3600, 7200, 7201, 43200, 86399, 86400, 86401, 200000, 604800][rnd(11)];
      const amount = BigInt(1 + rnd(150)) * 1_000_000n;

      const d = spend(m, { spender: AGENT, recipient: VENDOR, amount, nonce: `t${step}` }, { now: t });
      if (!d.allowed) continue;
      accepted.push({ t, amount });

      const usageOver = (span) =>
        accepted.filter((e) => e.t > t - span).reduce((sum, e) => sum + e.amount, 0n);

      assert.ok(usageOver(DAY) <= DAILY, `daily breached: seed=${seed} step=${step} ${P.formatUsdc(usageOver(DAY))}`);
      assert.ok(usageOver(WEEK) <= WEEKLY, `weekly breached: seed=${seed} step=${step} ${P.formatUsdc(usageOver(WEEK))}`);
    }
  }
});

test('DOCUMENTED COST: sustained throughput settles at K/(K+1) of the nominal cap', () => {
  // policy.js claims the price of soundness is K/(K+1) of nominal throughput
  // (~92% at K=12, ~96% at K=24). That is a number in a comment, so verify it
  // rather than trust it: run a greedy agent for 200 windows and measure.
  const CAP = usdc('1200');
  for (const K of [2, 4, 6, 12, 24]) {
    const S = DAY / K;
    const m = createMandate({
      id: `rate-${K}`, payer: PAYER, spender: AGENT,
      expiresAt: FAR,
      windows: [win(DAY, CAP, K)],
    });

    const WINDOWS = 200;
    let t = 1000 * DAY;
    let total = 0n;
    let i = 0;
    for (let step = 0; step < WINDOWS * K; step++) {
      const avail = headroom(m, t).windows[0].remaining;
      if (avail > 0n) {
        const d = spend(m, { spender: AGENT, recipient: VENDOR, amount: avail, nonce: `r${i++}` }, { now: t });
        if (d.allowed) total += avail;
      }
      t += S;
    }

    const perWindow = total / BigInt(WINDOWS);
    const predicted = (CAP * BigInt(K)) / BigInt(K + 1);
    // within 1% of the documented figure
    const delta = perWindow > predicted ? perWindow - predicted : predicted - perWindow;
    assert.ok(
      delta * 100n <= predicted,
      `K=${K}: sustained ${P.formatUsdc(perWindow)}/window vs predicted ${P.formatUsdc(predicted)}`,
    );
    // and never above the nominal cap
    assert.ok(perWindow <= CAP, `K=${K}: sustained rate exceeded the nominal cap`);
  }
});

test('PROPERTY: the engine is conservative but not uselessly strict', () => {
  // Sanity check on the other side: with spending spread evenly, a well-behaved
  // agent should get most of its cap through rather than being starved by the
  // over-counting of the trailing sub-bucket.
  const m = createMandate({
    id: 'live', payer: PAYER, spender: AGENT,
    expiresAt: FAR,
    windows: [win(DAY, usdc('240'), 24)],
  });
  let through = 0n;
  let t = 100 * DAY;
  for (let hour = 0; hour < 24; hour++) {
    const d = spend(m, { spender: AGENT, recipient: VENDOR, amount: usdc('10'), nonce: `h${hour}` }, { now: t });
    if (d.allowed) through += usdc('10');
    t += 3600;
  }
  assert.equal(through, usdc('240'), 'an evenly-paced agent should reach its full daily cap');
});

test('PROPERTY: cap is enforced per mandate, not shared or leaked between them', () => {
  const a = simpleMandate({ id: 'a' });
  const b = simpleMandate({ id: 'b' });
  for (let i = 0; i < 5; i++) spend(a, req(usdc('100')), { now: 1 });
  assert.equal(headroom(a, 1).windows[0].remaining, 0n);
  assert.equal(headroom(b, 1).windows[0].remaining, usdc('500'));
  assert.equal(evaluate(b, req(usdc('100')), { now: 1 }).allowed, true);
});

// ---------------------------------------------------------------------------
// This one guards the suite rather than the engine, and it exists because of FAR.
test('meta: no test runs past FAR, and the run is not vacuously green', () => {
  assert.ok(maxTimeSeen > 0, 'the recorders saw no timestamps at all, so they are not wired up');

  // If any test's clock reached FAR, every mandate carrying FAR would deny EXPIRED from that
  // point on. The window fuzzers would then still pass — "accepted spends never exceed the
  // cap" is satisfied by accepting nothing — so this is not a failure the property tests can
  // report themselves.
  assert.ok(
    maxTimeSeen < FAR,
    `a test used t=${maxTimeSeen}, which is at or past FAR=${FAR}. Every mandate carrying ` +
      'FAR would deny EXPIRED from there on, and the window fuzzers would stay green while ' +
      'measuring nothing. Raise FAR — it must stay under the uint40 max of 1099511627775 — ' +
      'or give that test its own horizon.',
  );

  // And the direct check on vacuity: a large number of spends must actually have been
  // allowed across the run. The run allows 45,058 as of this commit; the threshold sits an
  // order of magnitude below that on purpose, so it catches a collapse without pinning a
  // count that every new test would have to update.
  assert.ok(
    allowedSeen > 5_000,
    `only ${allowedSeen} spends were allowed across the whole run, which is too few for the ` +
      'fuzzers to have exercised anything — suspect a grant-time refusal or a gate denying ' +
      'everything rather than a genuine property.',
  );
});
