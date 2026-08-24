// SPDX-License-Identifier: MIT
//
// Adversarial test suite for the Remit policy engine.
// Run: node --test reference/
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
const { usdc, window: win, createMandate, evaluate, spend, revoke, approveCosign, headroom, Denial, DAY, WEEK } = P;

const PAYER = '0xPAYER000000000000000000000000000000000001';
const AGENT = '0xAGENT000000000000000000000000000000000002';
const VENDOR = '0xVENDOR00000000000000000000000000000000003';
const OTHER = '0xOTHER000000000000000000000000000000000004';
const BOSS = '0xBOSS0000000000000000000000000000000000005';

let nonceCounter = 0;
const n = () => `n${++nonceCounter}`;

/** A simple mandate: 100 USDC per tx, 500/day, agent may pay anyone. */
function simpleMandate(overrides = {}) {
  return createMandate({
    id: 'm1',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('100'),
    windows: [win(DAY, usdc('500'), 12)],
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

test('construction: an unbounded mandate is refused', () => {
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT }),
    /refusing to create an unbounded mandate/,
  );
});

test('construction: cosignThreshold without a cosigner is refused', () => {
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), cosignThreshold: usdc('1') }),
    /requires a cosigner/,
  );
});

test('construction: window length must divide evenly into buckets', () => {
  assert.throws(() => win(100, usdc('1'), 12), /divisible/);
  assert.doesNotThrow(() => win(DAY, usdc('1'), 24));
});

test('construction: every grant-time refusal the contract makes, the model makes too', () => {
  // Found by auditing zero-means-unset fields, not by a failing test — which is why it
  // is worth having. The contract refuses these at createMandate; the model used to
  // accept all five and fail later, or in one case not fail at all.
  const base = { id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1') };

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
  approveCosign(m, BOSS, r);
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
test('cosign: large spends need approval, small ones do not', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  assert.equal(spend(m, req(usdc('25')), { now: 1 }).allowed, true, 'at threshold: no cosign needed');
  const big = req(usdc('26'));
  assert.equal(evaluate(m, big, { now: 1 }).reason, Denial.COSIGN_REQUIRED);
  approveCosign(m, BOSS, big);
  assert.equal(spend(m, big, { now: 1 }).allowed, true);
});

test('cosign: an approval is single-use', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  approveCosign(m, BOSS, r);
  assert.equal(spend(m, r, { now: 1 }).allowed, true);
  // Replay is caught by the nonce; and the approval was consumed as well.
  assert.equal(m.cosignApprovals.size, 0);
  assert.equal(evaluate(m, r, { now: 1 }).reason, Denial.NONCE_ALREADY_USED);
});

test('ATTACK: a cosign approval cannot be redirected to another recipient or amount', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const approved = req(usdc('50'), { recipient: VENDOR });
  approveCosign(m, BOSS, approved);

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
  assert.throws(() => approveCosign(m, AGENT, req(usdc('50'))), /only the cosigner/);
  assert.throws(() => approveCosign(m, PAYER, req(usdc('50'))), /only the cosigner/);
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
