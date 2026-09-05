// SPDX-License-Identifier: MIT
//
// Adversarial test suite for the Remit policy engine.
// Run: node --test reference/policy.test.js
//
// This line used to read `node --test reference/`, which was correct on the Node that
// wrote it and fails on Node 22 with a MODULE_NOT_FOUND for the directory itself — the
// runner hands a bare positional to the CJS loader instead of walking it. Naming the
// file works on every version; `node --test 'reference/**/*.test.js'` also works, as does
// a bare `node --test` with the cwd inside reference/.
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
  // NEW IN v2 (F51). The payer names a third address that may revoke, so a payer whose USDC
  // has been spent down to where their own gas is unaffordable is not the only party who can
  // switch the mandate off. See F42 for the measurement behind that.
  setRevoker,
  approveCosignFor,
  // NEW IN v2 (F30). The model gained a withdrawal because the nonce reservation needs a release
  // path; without one, a fix for one denial-of-service would have introduced another.
  withdrawCosign,
  // NEW IN v2 (F47), the second release and the first one the payer can reach.
  // `withdrawCosign` answers to the cosigner, so a nonce a cosigner chose to hold was held
  // against the party whose funds the mandate spends.
  clearReservation,
  MAX_AMOUNT,
  // NEW IN v2 (F3). The uint32 counter ceiling, imported beside MAX_AMOUNT because the two
  // tests that use them are twins and both assert one base unit either side of the boundary.
  MAX_SPEND_COUNT,
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
// v2 (F51). The nominated revoker, and a second one so the replacement path has somewhere to
// move the nomination to. Neither is the payer, the spender or the cosigner, because those three
// are the values `createMandate` and `setRevoker` refuse and the tests below use them for that.
const GUARD = '0xGUARD00000000000000000000000000000000000A';
const GUARD2 = '0xGUARD20000000000000000000000000000000000B';
// v2 (F29). The two addresses a payment can reach and never leave: the manager, which holds no
// USDC by design and has no sweep function, and the token itself. They live in `ctx` rather than
// on the mandate because they are facts about a deployment, not about a grant — see the note at
// the check in policy.js about what an omitted pair costs.
//
// F38 made it four. Both ERC-8004 registries are contracts the manager only ever reads, and
// their interfaces carry no transfer of any kind, so a payment to either is as final as one to
// the manager or the token. `DEPLOY` names all four, which is what a caller comparing this model
// against a live deployment has to do.
const MANAGER = '0xMANAGER0000000000000000000000000000000006';
const TOKEN = '0xTOKEN000000000000000000000000000000000007';
const ID_REGISTRY = '0xIDREG000000000000000000000000000000000008';
const VAL_REGISTRY = '0xVALREG00000000000000000000000000000000009';
const DEPLOY = {
  manager: MANAGER,
  token: TOKEN,
  identityRegistry: ID_REGISTRY,
  validationRegistry: VAL_REGISTRY,
};

let nonceCounter = 0;
const n = () => `n${++nonceCounter}`;

// Every mandate needs a LIFETIME bound as of v2: `totalCap` or `expiresAt`. A per-transaction
// cap bounds each spend and a window bounds each period; neither bounds the total, so neither
// is accepted on its own any more. See policy.js's `hasLifetimeBound`.
//
// Most tests here are about caps, windows, cosign and identity checks, nonces or clocks;
// they are indifferent to the horizon, so they name FAR — past every timestamp this suite
// uses and inside the uint40 the contract stores `expiresAt` in, whose maximum is
// 1_099_511_627_775. The largest timestamp the suite actually reaches is 103_676_400,
// measured by the recorders above rather than estimated, which leaves FAR roughly 38x of
// headroom. Tests that are ABOUT the horizon name their own, and the ones asserting the
// refusal deliberately name none.
//
// It is written out at each call site rather than injected by a wrapper around
// `createMandate`, because a wrapper that satisfied the rule out of sight of each test would
// also hide it: the suite would stop demonstrating that a real caller has to supply a bound.
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

  // The documented migration for an open-ended arrangement keeps the window and names a
  // horizon. The point of refusing the shape above is that the horizon becomes explicit
  // rather than absent, not that recurring mandates stop being expressible.
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
  // zero is meaningful, so there is no state for "a cosigner is named and no spend requires
  // their approval". This model accepted one until v2, which made it MORE PERMISSIVE than the
  // thing it specifies — the same failure class as the uint96 counter, found the same way, by
  // asking what the contract can represent rather than what JavaScript can.
  assert.throws(
    () => createMandate({ id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR, cosigner: BOSS }),
    /requires a cosignThreshold/,
  );
  // Zero is the spelling that requires a cosignature on every spend, and it must be accepted.
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
  // threshold did not trip the gate (DESIGN.md:981).
  assert.throws(() => gate({ perTxCap: usdc('50'), cosignThreshold: usdc('50') }), /can never fire/);
  // One base unit lower and the gate is alive, which is what makes the bound exact rather
  // than merely conservative.
  const live = gate({ perTxCap: usdc('50'), cosignThreshold: usdc('50') - 1n });
  assert.equal(evaluate(live, req(usdc('50')), { now: 1 }).reason, Denial.COSIGN_REQUIRED);

  // perTxCap is NOT the only ceiling. With no per-transaction cap the lifetime cap binds, and
  // this shape passes both spellings of the naive `perTxCap < threshold` check because
  // perTxCap is absent entirely.
  assert.throws(() => gate({ totalCap: usdc('100'), cosignThreshold: usdc('100') }), /can never fire/);
  // A window cap is a ceiling too, so a threshold equal to it can never fire either.
  assert.throws(
    () => gate({ windows: [win(DAY, usdc('40'), 12)], cosignThreshold: usdc('40') }),
    /can never fire/,
  );
  // The check takes a MINIMUM over the windows, not the first or the last of them.
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
  // The ceiling itself is out of reach, because the contract refuses amounts above it
  // outright — the bound exists even where the payer set none, and this is the term in the
  // check that a model with arbitrary-precision integers has no reason to invent.
  assert.throws(() => gate({ expiresAt: 10_000, cosignThreshold: MAX }), /can never fire/);
  assert.doesNotThrow(() => gate({ expiresAt: 10_000, cosignThreshold: MAX - 1n }));
});

test('construction: window length must divide evenly into buckets', () => {
  assert.throws(() => win(100, usdc('1'), 12), /divisible/);
  assert.doesNotThrow(() => win(DAY, usdc('1'), 24));
});

test('construction: id, payer and spender are required, and the zero address is not one', () => {
  // All five guards this test and the next one cover already existed, and not one of them was
  // asserted. The mutation gate neutered each in turn on 2026-08-29 and the suite stayed green
  // at 89 passing, which is the whole argument for the gate: these three look self-evidently
  // covered, because every other mandate in this file supplies all three fields.
  const base = { id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR };
  assert.doesNotThrow(() => createMandate(base));

  // Each guard is checked in its own right, and against every falsy spelling a caller reaches by
  // accident: a field left off the object, one set to null by a serialiser, an empty string from
  // a form, a zero from a numeric default.
  for (const missing of [undefined, null, '', 0]) {
    assert.throws(() => createMandate({ ...base, id: missing }), /id required/);
    assert.throws(() => createMandate({ ...base, payer: missing }), /payer required/);
    assert.throws(() => createMandate({ ...base, spender: missing }), /spender required/);
  }

  // NEW IN v2. Probing the three survivors turned up a divergence rather than only a missing
  // test. The guards above are truthiness tests and the zero address is a truthy string, so the
  // model used to mint a mandate the contract refuses outright — MandateManager.sol reverts
  // BadConfig on `p.spender == address(0)`. Nothing downstream would have caught it either: the
  // zero address is simply a spender that never equals the caller, so the grant reads as
  // ordinary and denies every spend for the rest of its life. The payer learns at spend time
  // what they could have been told at grant time.
  assert.throws(
    () => createMandate({ ...base, spender: ZERO_ADDRESS }),
    /spender cannot be the zero address/,
  );
  // The payer is refused for the opposite reason: the contract has no check for it, because
  // on-chain the payer IS msg.sender and a transaction cannot come from the zero address. A
  // model that accepts one is describing a mandate with no on-chain counterpart at all.
  assert.throws(
    () => createMandate({ ...base, payer: ZERO_ADDRESS }),
    /payer cannot be the zero address/,
  );
  // Both normalise before comparing, so an uppercase `0X` prefix is the same refusal and not a
  // way around it. There are no letters in the zero address, so this is the only spelling that
  // differs, and it is one a hand-written config reaches.
  const upper = `0X${'0'.repeat(40)}`;
  assert.throws(() => createMandate({ ...base, spender: upper }), /spender cannot be/);
  assert.throws(() => createMandate({ ...base, payer: upper }), /payer cannot be/);
});

test('construction: windows must come from window(), and at most MAX_WINDOWS of them', () => {
  const base = { id: 'x', payer: PAYER, spender: AGENT, expiresAt: FAR };

  // A plain object with the two fields a caller thinks a window has is the plausible mistake,
  // and the guard exists because the failure without it lands nowhere near the cause: the
  // bucket ring is missing, so the first spend does arithmetic on undefined inside `headroom`.
  assert.throws(
    () => createMandate({ ...base, windows: [{ length: DAY, cap: usdc('500') }] }),
    /built with window\(\)/,
  );
  // One real window and one raw one still fails. The check is per window rather than "the
  // first one", which is the version of this guard that would pass a careless review.
  assert.throws(
    () =>
      createMandate({
        ...base,
        windows: [win(DAY, usdc('500'), 12), { length: WEEK, cap: usdc('1000') }],
      }),
    /built with window\(\)/,
  );

  // MAX_WINDOWS is a gas bound rather than a policy one: the contract walks every window's ring
  // on every spend, so an unbounded count is an unbounded cost per transaction, paid by the
  // delegate and unpayable at some size. The ceiling is inclusive — exactly MAX_WINDOWS is fine.
  const rings = (k) => Array.from({ length: k }, (_, i) => win(DAY * (i + 1), usdc('500'), 12));
  assert.doesNotThrow(() => createMandate({ ...base, windows: rings(P.MAX_WINDOWS) }));
  assert.throws(
    () => createMandate({ ...base, windows: rings(P.MAX_WINDOWS + 1) }),
    new RegExp(`at most ${P.MAX_WINDOWS} windows`),
  );
});

test('construction: every grant-time refusal the contract makes, the model makes too', () => {
  // Found by auditing zero-means-unset fields rather than by a failing test. The contract
  // refuses these at createMandate; the model used to accept all five and fail later, or in
  // one case not fail at all.
  const base = { id: 'x', payer: PAYER, spender: AGENT, perTxCap: usdc('1'), expiresAt: FAR };

  // A cap of zero makes a window that can never permit anything. The contract calls
  // this BadWindow rather than minting a mandate that is dead on arrival.
  assert.throws(() => win(DAY, 0, 12), /cap must be positive/);

  // THE IMPORTANT ONE. minResponse of 0 means "any response passes", and ERC-8004 encodes a
  // FAILED validation as a low response — 100 is the passing value. A zero here inverts the
  // credential check rather than merely weakening it: the check would accept precisely the
  // attestations it exists to reject, and the contract reverts BadConfig.
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

  // NEW IN v2. The other end of the minResponse range. 100 is a pass under ERC-8004 and
  // nothing above it can be scored, so a higher bar refuses every spend for the life of the
  // mandate — the same defect as a zero, pointing the other way.
  assert.throws(
    () => createMandate({ ...base, credential: { validator: BOSS, requestHash: '0xk', minResponse: 101n } }),
    /cannot exceed 100/,
  );
  assert.doesNotThrow(
    () => createMandate({ ...base, credential: { validator: BOSS, requestHash: '0xk', minResponse: 100n } }),
  );

  // F34. `requestHash` is the whole registry lookup key, so a zero one addresses no
  // attestation and the gate can only ever answer CREDENTIAL_MISSING.
  for (const empty of [undefined, '', '0x0', '0x00', '0x' + '0'.repeat(64)]) {
    assert.throws(
      () => createMandate({ ...base, credential: { validator: BOSS, requestHash: empty } }),
      /requestHash/,
      `requestHash ${JSON.stringify(empty)} must be refused`,
    );
  }

  // F33. Agent 0 is not registrable, so `ownerOf(0)` reverts or answers the zero address and
  // the identity gate denies forever.
  assert.throws(() => createMandate({ ...base, identity: { agentId: 0n } }), /agentId/);
  assert.throws(() => createMandate({ ...base, identity: {} }), /agentId/);

  // F33's second half, and the one that reads like a tightening. The gate requires the CALLER
  // to hold the identity and `evaluate` requires the caller to be the spender, so pinning
  // `expectedOwner` at a third party contradicts a check the same function already made. The
  // mandate is bricked by it rather than protected by it.
  assert.throws(
    () => createMandate({ ...base, identity: { agentId: 42n, expectedOwner: BOSS } }),
    /expectedOwner/,
  );
  // Unset, and pinned at the spender, are both accepted — the second as a deliberate no-op.
  assert.doesNotThrow(() => createMandate({ ...base, identity: { agentId: 42n } }));
  assert.doesNotThrow(
    () => createMandate({ ...base, identity: { agentId: 42n, expectedOwner: P.ZERO_ADDRESS } }),
  );
  assert.doesNotThrow(
    () => createMandate({ ...base, identity: { agentId: 42n, expectedOwner: AGENT } }),
  );

  // The shapes that are legitimate still construct: minResponse defaults to the
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
  // Construction therefore materialises every credential field in its ON-CHAIN spelling,
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

  // Explicit values survive untouched, including the permissive ones. `minResponse` is a
  // partial score rather than the 200n this test used before v2 bounded the field at 100 —
  // the point being made is pass-through, and 60 makes it against a value that is legal.
  const explicit = createMandate({
    id: 'y',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('1'),
    expiresAt: FAR,
    credential: { validator: BOSS, requestHash: '0xk', minResponse: 60n, maxStaleness: 0n, agentId: 42n },
  });
  assert.equal(explicit.credential.minResponse, 60n);
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

test('the uint32 spend counter denies by name rather than wrapping, whatever the amount', () => {
  // NEW IN v2 (F3). The twin of the test above, one counter over, and the ceiling any history a
  // real balance can fund meets first: reaching 2^96 base units in fewer than 2^32 spends needs
  // an average spend near 2^64, about 18.4 trillion USDC. The counter is placed rather than
  // reached, for the reason Bounds.t.sol has to use `vm.store` for its twin — 4.29 billion
  // spends are not affordable in either language.
  const m = createMandate({
    id: 'counter', payer: PAYER, spender: AGENT, windows: [], expiresAt: FAR,
  });

  // One short of the ceiling, so the last legal spend is asserted rather than assumed. A guard
  // written with `>` instead of `>=` would let one more through and fail here.
  m.spendCount = MAX_SPEND_COUNT - 1n;
  assert.equal(spend(m, req(usdc('1')), { now: 1 }).allowed, true, 'the last spend must fit');
  assert.equal(m.spendCount, MAX_SPEND_COUNT);

  const d = evaluate(m, req(usdc('1')), { now: 2 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.SPEND_COUNT_CEILING);
  assert.equal(d.detail.max, MAX_SPEND_COUNT);
  assert.equal(d.detail.spendCount, MAX_SPEND_COUNT);

  // Amount-independent, which nothing else in that block is. One base unit is refused for the
  // same reason as the largest amount the uint96 ceiling beside it still permits, and a guard
  // that consulted the amount by mistake would answer differently on one of the two.
  assert.equal(evaluate(m, req(1n), { now: 2 }).reason, Denial.SPEND_COUNT_CEILING);
  const largestThatClears = MAX_AMOUNT - usdc('1');
  assert.equal(
    evaluate(m, req(largestThatClears), { now: 2 }).reason,
    Denial.SPEND_COUNT_CEILING,
    'the counter answers even where the uint96 total still has room',
  );

  // And the answer comes from the counter rather than from its neighbour: `totalSpent` is one
  // USDC, so a guard aimed at the wrong field would have allowed all three calls above.
  assert.equal(m.totalSpent, usdc('1'));
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

test('F19: paying the payer is refused, and refused as SELF_PAYMENT', () => {
  // Before F19 this was a legal spend that consumed perTxCap, the window ring and the
  // lifetime cap, burned its nonce, emitted Spend, and moved nothing. Arc's system emitter
  // writes no log for a self-transfer, so it was also the one spend a reconciler could not
  // see. The interesting assertion is the CODE, not the refusal.
  const m = simpleMandate();
  const d = evaluate(m, req(usdc('10'), { recipient: PAYER }), { now: 1 });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.SELF_PAYMENT);
});

test('F19: the guard normalises, so mixed-case payer hex does not slip past it', () => {
  // `mandate.payer` is stored normalised, so a naive `recipient === mandate.payer` would
  // compare raw strings and let `0xPAYER…` through in any other casing — the same bypass the
  // allowlist test above pins for allowlisted recipients, and the reason both sides call
  // normalizeAddr.
  const m = simpleMandate();
  for (const cased of [PAYER.toUpperCase(), PAYER.toLowerCase()]) {
    assert.equal(evaluate(m, req(usdc('10'), { recipient: cased }), { now: 1 }).reason, Denial.SELF_PAYMENT);
  }
});

test('F19: SELF_PAYMENT outranks the allowlist, even when the payer is ON it', () => {
  // Pins the ordering decision rather than the guard. Both denials are true for this request
  // when the payer is absent from the allowlist, and only one of them is useful; putting the
  // allowlist first would answer "fix your config" when the request itself is the mistake.
  // Listing the payer explicitly is the case that makes the ordering observable at all.
  const onIt = simpleMandate({ allowlist: [PAYER, VENDOR] });
  assert.equal(evaluate(onIt, req(usdc('10'), { recipient: PAYER }), { now: 1 }).reason, Denial.SELF_PAYMENT);
  const offIt = simpleMandate({ allowlist: [VENDOR] });
  assert.equal(evaluate(offIt, req(usdc('10'), { recipient: PAYER }), { now: 1 }).reason, Denial.SELF_PAYMENT);
});

test('F29: the manager and the token are refused as recipients, because nobody can send it back', () => {
  // The failure mode is what separates this from every other denial in the file. An overspend
  // is refused and retried; a payment to an address with no way to move funds on is final, and
  // no key, signature or upgrade recovers it. The manager holds no USDC by design and has no
  // sweep function; the token contract has no recovery path either. Neither is a plausible
  // payee, so refusing both costs nothing anyone wanted.
  const m = simpleMandate();
  for (const bad of [MANAGER, TOKEN]) {
    const d = evaluate(m, req(usdc('10'), { recipient: bad }), { now: 1, ...DEPLOY });
    assert.equal(d.allowed, false);
    assert.equal(d.reason, Denial.UNRECOVERABLE_RECIPIENT);
  }
  // Case-insensitive, like every other address comparison here.
  assert.equal(
    evaluate(m, req(usdc('10'), { recipient: MANAGER.toUpperCase() }), { now: 1, ...DEPLOY }).reason,
    Denial.UNRECOVERABLE_RECIPIENT,
  );
  // An ordinary recipient is untouched, so the guard is not simply refusing more often.
  assert.equal(evaluate(m, req(usdc('10')), { now: 1, ...DEPLOY }).allowed, true);
});

test('F29: it is refused AHEAD of the allowlist, and refused whether or not it is on one', () => {
  // Shape before policy, the same ordering argument as F19: answering RECIPIENT_NOT_ALLOWED
  // would send a reader to edit a list when the request itself is the mistake. A payer who put
  // the token on an allowlist by mistake gets the same protection as one who did not — which
  // is the case that matters, because that payer believes the address is fine.
  const onIt = simpleMandate({ allowlist: [VENDOR, MANAGER, TOKEN] });
  const offIt = simpleMandate({ allowlist: [VENDOR] });
  for (const m of [onIt, offIt]) {
    for (const bad of [MANAGER, TOKEN]) {
      assert.equal(
        evaluate(m, req(usdc('10'), { recipient: bad }), { now: 1, ...DEPLOY }).reason,
        Denial.UNRECOVERABLE_RECIPIENT,
      );
    }
  }
});

test('F29: a cosigner cannot approve one either, so the refusal is not only on the spend path', () => {
  // F17's rule: an approval must name a spend `evaluate` could accept. Neither address can stop
  // being unrecoverable, so this approval is authority over a payment that is refused forever,
  // and it is refused with the SAME code by both functions — which is what lets a caller treat
  // the two surfaces as one policy.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  for (const bad of [MANAGER, TOKEN]) {
    assert.throws(
      () =>
        approveCosignFor(
          m,
          BOSS,
          { ...req(usdc('50'), { recipient: bad }), validUntil: DAY },
          { now: 1, ...DEPLOY },
        ),
      (err) => err.code === Denial.UNRECOVERABLE_RECIPIENT,
    );
  }
});

test('F29: a caller that names neither address gets the weaker rule, and that is the documented cost', () => {
  // Stated as a test rather than only in a comment, because it is the one way this mirror can be
  // less than the contract's: on-chain, `address(this)` and `address(usdc)` are always known, so
  // the guard cannot be skipped, whereas here they arrive in `ctx`. Anything comparing this
  // model to a live deployment has to supply them, and this test is where that obligation is
  // visible.
  const m = simpleMandate();
  assert.equal(evaluate(m, req(usdc('10'), { recipient: MANAGER }), { now: 1 }).allowed, true);
  assert.equal(
    evaluate(m, req(usdc('10'), { recipient: MANAGER }), { now: 1, token: TOKEN }).allowed,
    true,
    'naming only the token leaves the manager unchecked',
  );
  assert.equal(
    evaluate(m, req(usdc('10'), { recipient: MANAGER }), { now: 1, manager: MANAGER }).reason,
    Denial.UNRECOVERABLE_RECIPIENT,
  );
});

test('F38: both ERC-8004 registries are refused too, on the spend path and the approval path', () => {
  // F29 named the manager and the token and stopped there, and the argument it used covers two
  // more addresses it did not name. The registries are dependencies this system reads: an
  // identity lookup and a validation lookup, both `view`. Nothing in either interface moves a
  // token, so USDC credited to one stays there for as long as the contract exists — the same
  // finality that made F29 necessary, on addresses a payer is more likely to paste by
  // mistake than the token contract, because they appear in the mandate's own configuration.
  const m = simpleMandate();
  for (const bad of [ID_REGISTRY, VAL_REGISTRY]) {
    const d = evaluate(m, req(usdc('10'), { recipient: bad }), { now: 1, ...DEPLOY });
    assert.equal(d.allowed, false);
    assert.equal(d.reason, Denial.UNRECOVERABLE_RECIPIENT, `${bad} on the spend path`);
  }

  // Ahead of the allowlist and regardless of it, for F29's reason: the request is the mistake.
  const onIt = simpleMandate({ allowlist: [VENDOR, ID_REGISTRY, VAL_REGISTRY] });
  for (const bad of [ID_REGISTRY, VAL_REGISTRY]) {
    assert.equal(
      evaluate(onIt, req(usdc('10'), { recipient: bad }), { now: 1, ...DEPLOY }).reason,
      Denial.UNRECOVERABLE_RECIPIENT,
      `${bad} while sitting on the allowlist`,
    );
  }

  // And on the approval path, with the same code, so the two surfaces stay one policy.
  const c = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  for (const bad of [ID_REGISTRY, VAL_REGISTRY]) {
    assert.throws(
      () =>
        approveCosignFor(
          c,
          BOSS,
          { ...req(usdc('50'), { recipient: bad }), validUntil: DAY },
          { now: 1, ...DEPLOY },
        ),
      (err) => err.code === Denial.UNRECOVERABLE_RECIPIENT,
      `${bad} on the approval path`,
    );
  }
});

test('F38: the list has four live entries, and each is checked on its own', () => {
  // The point of the loop is that no entry rides on another. A list that lost one address would
  // still refuse the other three and still look correct from any test that checks the set as a
  // whole, which is how F29's two registries went missing from three hand-written copies. So
  // each address is supplied alone, and asked to be the only reason for a refusal.
  const m = simpleMandate();
  const addrs = { manager: MANAGER, token: TOKEN, identityRegistry: ID_REGISTRY, validationRegistry: VAL_REGISTRY };
  for (const field of Object.keys(addrs)) {
    const ctx = { now: 1, [field]: addrs[field] };
    assert.equal(
      evaluate(m, req(usdc('10'), { recipient: addrs[field] }), ctx).reason,
      Denial.UNRECOVERABLE_RECIPIENT,
      `${field} alone in ctx must refuse its own address`,
    );
    // The other three are unchecked in that ctx, which is the documented cost of the mirror and
    // also the proof that this refusal came from the field under test and not from a sibling.
    for (const otherField of Object.keys(addrs)) {
      if (otherField === field) continue;
      assert.equal(
        evaluate(m, req(usdc('10'), { recipient: addrs[otherField] }), ctx).allowed,
        true,
        `${otherField} must be unchecked when only ${field} is named`,
      );
    }
  }
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

test('revocation: the payer or the spender may revoke, and a stranger may not', () => {
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
  // Until v2 (F51) the title of this test ruled out every third address. A third address can
  // hold this now, but only one the payer named — an unnamed stranger is refused exactly as
  // before, and that is what this mandate is. The nominated case has its own block below.
  assert.throws(() => revoke(byStranger, OTHER), /only the payer, the spender or the nominated/);
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
// F51: the payer-nominated revoker.
//
// The role answers F42, which is a measurement rather than a theory: on Arc, gas and the
// spending budget are the same USDC balance, so a mandate can be spent down to the point where
// the payer cannot afford the 30,808 gas their own `revoke` costs. A third party who can switch
// the mandate off costs the payer nothing to arrange and does not have to be solvent for the
// payer to benefit.
//
// Adding a third holder of a kill switch is only acceptable if the switch is small, so these
// tests are mostly about how little the nominee can reach. In this model the whole of their
// power is `mandate.revoked`, which `evaluate` reads through `live` and `approveCosignFor` reads
// directly, and there is no other field they can write. The Solidity twin —
// `test/Revoker.t.sol` — walks all seven state-changing external functions as the nominee and
// then asserts the payer's balance and allowance, which is the claim this model cannot
// make because it moves no money.
// ---------------------------------------------------------------------------
test('F51: a grant records the nominee, and a grant without one records nobody', () => {
  assert.equal(simpleMandate({ revoker: GUARD }).revoker, GUARD.toLowerCase());
  assert.equal(simpleMandate().revoker, null, 'a grant naming nobody must be v1 exactly');
});

test('F51 ATTACK: the zero address is not a nominee, however it is spelled', () => {
  // The trap F28 sprang one field over: the zero address as a STRING is truthy in JavaScript,
  // so `if (revoker)` accepts it and the model would then hold a revoker of `0x000…0` on
  // mandates whose payer named no one. The contract cannot express the difference at all —
  // `address(0)` IS the empty mapping slot — which is why `_callerIsRevoker` tests for it
  // rather than comparing the caller alone.
  const m = simpleMandate({ revoker: ZERO_ADDRESS });
  assert.equal(m.revoker, null, 'the zero address must fold to nobody');
  assert.throws(() => revoke(m, ZERO_ADDRESS), /only the payer, the spender or the nominated/);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1 }).allowed, true, 'still live');

  // The same value through `setRevoker`, which is the removal path.
  const named = simpleMandate({ revoker: GUARD });
  setRevoker(named, PAYER, ZERO_ADDRESS);
  assert.equal(named.revoker, null);
  assert.throws(() => revoke(named, ZERO_ADDRESS), /only the payer, the spender or the nominated/);
});

test('F51: a grant refuses the payer and the spender as nominee, and permits the cosigner', () => {
  assert.throws(() => simpleMandate({ revoker: PAYER }), /payer cannot be their own revoker/);
  assert.throws(() => simpleMandate({ revoker: AGENT }), /spender cannot be the revoker/);

  // The cosigner stays eligible on purpose. They are an address the payer already trusted with
  // a decision about this mandate, and co-signing gives them no power this role duplicates.
  const m = simpleMandate({ cosigner: BOSS, cosignThreshold: usdc('10'), revoker: BOSS });
  assert.equal(m.revoker, BOSS.toLowerCase());
  revoke(m, BOSS);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1 }).reason, Denial.REVOKED);
});

test('F51: the nominee kills the mandate, and the views agree it is dead', () => {
  const m = simpleMandate({ revoker: GUARD });
  revoke(m, GUARD);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1 }).reason, Denial.REVOKED);
  assert.equal(headroom(m, 1).live, false);
  assert.equal(headroom(m, 1).maxSpendNow, 0n);
  // Idempotent, matching F11's latch in the contract: a second call is not an error.
  revoke(m, GUARD);
  assert.equal(m.revoked, true);
});

test('F51 ATTACK: the nominee of one mandate cannot reach another', () => {
  const guarded = createMandate({
    id: 'f51a',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('100'),
    expiresAt: FAR,
    revoker: GUARD,
  });
  const other = createMandate({
    id: 'f51b',
    payer: PAYER,
    spender: AGENT,
    perTxCap: usdc('100'),
    expiresAt: FAR,
  });
  assert.throws(() => revoke(other, GUARD), /only the payer, the spender or the nominated/);
  assert.equal(evaluate(other, req(usdc('1')), { now: 1 }).allowed, true, 'the second is live');
  revoke(guarded, GUARD);
  assert.equal(other.revoked, false, 'killing one must not kill the other');
});

test('F51 ATTACK: the nominee cannot spend, and revoking does not make them the spender', () => {
  const m = simpleMandate({ revoker: GUARD });
  const asGuard = { spender: GUARD, recipient: VENDOR, amount: usdc('1'), nonce: n() };
  assert.equal(evaluate(m, asGuard, { now: 1 }).reason, Denial.WRONG_SPENDER);
  revoke(m, GUARD);
  // After revocation the code changes, and REVOKED is not a smaller refusal than WRONG_SPENDER.
  assert.equal(evaluate(m, { ...asGuard, nonce: n() }, { now: 1 }).reason, Denial.REVOKED);
});

test('F51: setRevoker names, replaces and removes, and removal actually takes effect', () => {
  const m = simpleMandate();
  assert.equal(m.revoker, null);

  setRevoker(m, PAYER, GUARD);
  assert.equal(m.revoker, GUARD.toLowerCase());

  setRevoker(m, PAYER, GUARD2);
  assert.equal(m.revoker, GUARD2.toLowerCase());
  // The replaced nominee must lose the role, not share it.
  assert.throws(() => revoke(m, GUARD), /only the payer, the spender or the nominated/);

  setRevoker(m, PAYER, null);
  assert.equal(m.revoker, null, 'null is the way back to v1');
  assert.throws(() => revoke(m, GUARD2), /only the payer, the spender or the nominated/);
  assert.equal(evaluate(m, req(usdc('1')), { now: 1 }).allowed, true, 'still live after all that');
});

test('F51 ATTACK: only the payer may nominate — not the spender, the nominee or a stranger', () => {
  const m = simpleMandate({ revoker: GUARD });

  // The spender is the most valuable of these three. A spender who could remove the nominee
  // would undo the payer's arrangement with nothing to tell the payer it happened, and the
  // payer's next act — revoking once the budget is gone — is the one they cannot afford.
  assert.throws(() => setRevoker(m, AGENT, GUARD2), /only the payer may name a revoker/);
  assert.throws(() => setRevoker(m, AGENT, null), /only the payer may name a revoker/);
  assert.throws(() => setRevoker(m, GUARD, GUARD2), /only the payer may name a revoker/);
  assert.throws(() => setRevoker(m, OTHER, GUARD2), /only the payer may name a revoker/);
  assert.equal(m.revoker, GUARD.toLowerCase(), 'the nomination must be untouched');

  // A cosigner is eligible to HOLD the role and still may not hand it out.
  const withBoss = simpleMandate({ cosigner: BOSS, cosignThreshold: usdc('10'), revoker: GUARD });
  assert.throws(() => setRevoker(withBoss, BOSS, GUARD2), /only the payer may name a revoker/);
});

test('F51: setRevoker refuses a revoked mandate and the two ineligible values', () => {
  const dead = simpleMandate();
  revoke(dead, PAYER);
  assert.throws(() => setRevoker(dead, PAYER, GUARD), /the mandate is revoked/);
  assert.equal(dead.revoker, null, 'the refusal must not have written the field');

  const live = simpleMandate();
  assert.throws(() => setRevoker(live, PAYER, PAYER), /payer cannot be their own revoker/);
  assert.throws(() => setRevoker(live, PAYER, AGENT), /spender cannot be the revoker/);
  assert.equal(live.revoker, null);
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
  // down. An unchecked cast would truncate a huge amount into a small one that passes
  // every cap with no error raised — so the contract refuses it up front, and the model
  // has to agree or it stops being a specification of the thing that actually runs.
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
  // in the ring; a naive claim-the-slot would drop the earlier amount with no error.
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
// that supplied a deadline out of sight of each call would also hide the fact that a real
// cosigner has to choose one, and choosing one is the entire point of the finding.
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

  // CHANGED IN v2 (F30). A redirect on the APPROVED NONCE is now refused one step earlier than
  // it used to be. It answered COSIGN_REQUIRED, which was true — the redirected tuple hashes
  // differently and has no approval — and it also meant the redirected spend would have been
  // free to consume the nonce, stranding the cosigner's approval on a hash nothing could reach
  // again. The nonce is held for the tuple it was approved for, so the redirect never gets that
  // far. Strictly stronger, and the reason to assert the new code rather than loosen the test.
  const swapRecipient = { ...approved, recipient: OTHER };
  assert.equal(evaluate(m, swapRecipient, { now: 1 }).reason, Denial.NONCE_RESERVED);

  const swapAmount = { ...approved, amount: usdc('99') };
  assert.equal(evaluate(m, swapAmount, { now: 1 }).reason, Denial.NONCE_RESERVED);

  // The hash binding itself, which is what this test was always about, is shown on a FRESH
  // nonce where the reservation says nothing. Without this pair the two assertions above would
  // no longer be evidence that an approval is tuple-bound — only that a nonce is spoken for.
  assert.equal(
    evaluate(m, req(usdc('50'), { recipient: OTHER }), { now: 1 }).reason,
    Denial.COSIGN_REQUIRED,
  );
  assert.equal(evaluate(m, req(usdc('99'), { recipient: VENDOR }), { now: 1 }).reason, Denial.COSIGN_REQUIRED);

  // the exact approved tuple still works
  assert.equal(evaluate(m, approved, { now: 1 }).allowed, true);
});

test('ATTACK (F30): a tiny spend cannot burn the nonce out from under a live approval', () => {
  // THE ATTACK, as a sequence rather than as a claim.
  //
  // The cosigner approves 50 USDC to VENDOR under nonce N. The agent then spends one unit, on
  // nonce N, to an address it controls. Before v2 that spend was legal — it is below the
  // threshold, so it never consulted the approval — and it consumed N. The approval stayed in
  // the Map, pointing at a hash whose nonce was now spent, so the 50 could never be paid and the
  // cosigner's signature was destroyed by a payment they never saw. One unit of USDC to cancel
  // an arbitrary approval, repeatable for every approval the cosigner ever makes.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const approved = req(usdc('50'), { recipient: VENDOR });
  approveCosignFor(m, BOSS, { ...approved, validUntil: DAY }, { now: 1, ...DEPLOY });

  const burn = { ...approved, amount: 1n, recipient: OTHER };
  const d = evaluate(m, burn, { now: 1, ...DEPLOY });
  assert.equal(d.allowed, false);
  assert.equal(d.reason, Denial.NONCE_RESERVED, 'the nonce is held for the approved spend');

  // The approval survived, and the payment it authorises still goes through.
  assert.equal(spend(m, approved, { now: 1, ...DEPLOY }).allowed, true);
  assert.equal(m.totalSpent, usdc('50'));

  // The same small payment on its own nonce was never the problem, and still is not.
  assert.equal(spend(m, req(1n, { recipient: OTHER }), { now: 1, ...DEPLOY }).allowed, true);
});

test('F30: the approved spend passes straight through, and releases its own nonce', () => {
  // The reservation must not block the payment it exists to protect, and must not outlive it —
  // a reservation left behind after the nonce is spent would be invisible, because
  // NONCE_ALREADY_USED answers first from then on.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });
  assert.equal(m.cosignReservedNonces.get(r.nonce), hash);

  assert.equal(spend(m, r, { now: 1, ...DEPLOY }).allowed, true);
  assert.equal(m.cosignReservedNonces.has(r.nonce), false, 'spent nonces hold nothing');
  assert.equal(m.cosignApprovals.has(hash), false, 'one signature, one spend');
});

test('F30: a nonce nobody reserved is untouched, so the guard costs an ordinary spend nothing', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  assert.equal(m.cosignReservedNonces.size, 0);
  assert.equal(spend(m, req(usdc('10')), { now: 1, ...DEPLOY }).allowed, true);
  assert.equal(spend(m, req(usdc('20')), { now: 1, ...DEPLOY }).allowed, true);
  // The same holds on a mandate with no cosign requirement at all, which is the common case.
  const plain = simpleMandate();
  assert.equal(spend(plain, req(usdc('10')), { now: 1, ...DEPLOY }).allowed, true);
});

test('F30: withdrawing the approval releases the nonce, so the fix does not strand it instead', () => {
  // The half that makes the fix safe rather than merely stricter. A reservation with no release
  // path would mean a cosigner who approved and then changed their mind left that nonce
  // unspendable for the life of the mandate — trading one denial-of-service for another.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });

  assert.equal(withdrawCosign(m, BOSS, hash, r.nonce), true);
  assert.equal(m.cosignReservedNonces.has(r.nonce), false);

  // The nonce is ordinary again: usable for any spend, including one the cosigner never saw.
  assert.equal(spend(m, { ...r, amount: usdc('10'), recipient: OTHER }, { now: 1, ...DEPLOY }).allowed, true);

  // A wrong nonce cannot free a nonce belonging to a DIFFERENT live approval — that is what the
  // conditional release is for. What it does instead used to be the one rough edge of the pair:
  // the approval is deleted either way, so a wrong nonce cancelled the signature and left the
  // nonce held for a hash that no longer existed, and nothing could use that nonce until the
  // cosigner acted again.
  //
  // F39 removed the edge without touching the release. A reservation binds only while the
  // approval behind it is live, and a withdrawn approval is not live, so the leftover entry is
  // inert: still in the Map, and refusing nothing. What the reservation protects is the
  // cosigner's decision, and a withdrawal is that decision being taken back. The contract
  // behaves identically — `withdrawCosign` deletes the approval and skips the release, then the
  // next spend on that nonce finds nothing live behind the reservation and sweeps it.
  const other = req(usdc('60'));
  const otherHash = approveCosignFor(m, BOSS, { ...other, validUntil: DAY }, { now: 1, ...DEPLOY });
  assert.equal(withdrawCosign(m, BOSS, otherHash, 'not-the-nonce'), true, 'the approval went');
  assert.equal(m.cosignReservedNonces.get(other.nonce), otherHash, 'the reservation stayed');
  assert.equal(evaluate(m, other, { now: 1, ...DEPLOY }).reason, Denial.COSIGN_REQUIRED);
  assert.equal(
    evaluate(m, { ...other, amount: usdc('20') }, { now: 1, ...DEPLOY }).allowed,
    true,
    'an inert reservation refuses nothing',
  );

  // The Map entry can still be cleared outright, two ways, and neither needs the payer.
  // F47 adds a third, `clearReservation`, and that one is the payer's alone.
  // Repeating the withdrawal with the right nonce frees it.
  assert.equal(withdrawCosign(m, BOSS, otherHash, other.nonce), false, 'nothing left to cancel');
  assert.equal(m.cosignReservedNonces.has(other.nonce), false, 'but the nonce is free');
  assert.equal(spend(m, { ...other, amount: usdc('20') }, { now: 1, ...DEPLOY }).allowed, true);

  // Or re-approving the same request, which is satisfied by its own reservation and restores the
  // signature the wrong nonce cancelled.
  const third = req(usdc('60'));
  const thirdHash = approveCosignFor(m, BOSS, { ...third, validUntil: DAY }, { now: 1, ...DEPLOY });
  withdrawCosign(m, BOSS, thirdHash, 'not-the-nonce');
  assert.equal(
    approveCosignFor(m, BOSS, { ...third, validUntil: DAY }, { now: 1, ...DEPLOY }),
    thirdHash,
  );
  assert.equal(spend(m, third, { now: 1, ...DEPLOY }).allowed, true);
});

test('F30: only the cosigner may withdraw, and withdrawing nothing is not an error', () => {
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });
  // The unknown-mandate guard, asserted on 2026-09-02 because it had no test. F47 taught the
  // mutation gate a fourth spelling, which let `withdrawCosign` be run as a target for the first
  // time, and this line was the survivor: neutering it left the model dereferencing null instead
  // of naming the mistake, and the suite stayed green because no test ever called this with a
  // mandate that was absent. The sibling guard one line below was already covered.
  assert.throws(() => withdrawCosign(null, BOSS, hash, r.nonce), /unknown mandate/);
  for (const stranger of [AGENT, PAYER, OTHER]) {
    assert.throws(() => withdrawCosign(m, stranger, hash, r.nonce), /only the cosigner/);
  }
  assert.equal(m.cosignApprovals.has(hash), true, 'a stranger changed nothing');

  // Withdrawing an approval that is not there returns false rather than throwing: the caller
  // asked for a post-state and that is the post-state they get. A cosigner racing a spend should
  // not have their cancellation revert because the spend won.
  assert.equal(withdrawCosign(m, BOSS, 'no-such-hash', 'no-such-nonce'), false);
  assert.equal(withdrawCosign(m, BOSS, hash, r.nonce), true);
  assert.equal(withdrawCosign(m, BOSS, hash, r.nonce), false);
});

test('F30: two different approvals on one nonce are refused, and replacing one is explicit', () => {
  // Sequencing rule, not a prohibition. Both approvals could never be consumed — the first spend
  // to land burns the nonce and the survivor is stranded — so the second is refused at the moment
  // the cosigner can still choose. Replacing means withdrawing first, which is one extra call and
  // a decision instead of a silent loss.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const first = req(usdc('50'));
  const firstHash = approveCosignFor(m, BOSS, { ...first, validUntil: DAY }, { now: 1, ...DEPLOY });

  assert.throws(
    () =>
      approveCosignFor(
        m,
        BOSS,
        { ...first, amount: usdc('60'), validUntil: DAY },
        { now: 1, ...DEPLOY },
      ),
    (err) => {
      assert.equal(err.code, Denial.NONCE_RESERVED, err.message);
      return true;
    },
  );
  assert.throws(
    () =>
      approveCosignFor(
        m,
        BOSS,
        { ...first, recipient: OTHER, validUntil: DAY },
        { now: 1, ...DEPLOY },
      ),
    (err) => {
      assert.equal(err.code, Denial.NONCE_RESERVED, err.message);
      return true;
    },
  );
  assert.equal(m.cosignApprovals.get(firstHash), BigInt(DAY), 'the first approval is intact');

  withdrawCosign(m, BOSS, firstHash, first.nonce);
  const replaced = approveCosignFor(
    m,
    BOSS,
    { ...first, amount: usdc('60'), validUntil: DAY },
    { now: 1, ...DEPLOY },
  );
  assert.notEqual(replaced, firstHash);
  assert.equal(spend(m, { ...first, amount: usdc('60') }, { now: 1, ...DEPLOY }).allowed, true);
});

test('F30: re-approving the SAME request is allowed, so extending a deadline needs no withdrawal', () => {
  // The reservation is satisfied by the request that owns it, so this lands on the write rather
  // than the guard. Refusing it would make a deadline extension a two-call dance for no gain.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });
  const again = approveCosignFor(m, BOSS, { ...r, validUntil: 2 * DAY }, { now: 1, ...DEPLOY });
  assert.equal(again, hash);
  assert.equal(m.cosignApprovals.get(hash), BigInt(2 * DAY), 'the later deadline replaced it');
  assert.equal(m.cosignReservedNonces.get(r.nonce), hash);
  assert.equal(evaluate(m, r, { now: DAY + 1, ...DEPLOY }).allowed, true, 'past the old deadline');
});

test('F47: the payer can free a nonce the cosigner is holding, and the approval survives', () => {
  // The release the reservation Map was missing. F30 gave the cosigner one and F39 sweeps a
  // reservation whose approval has lapsed, which left the payer — the party whose funds and
  // mandate these are — with no route at all.
  //
  // The setup is the shape F17 deliberately allows, and the test below at 'what must NOT be
  // refused' is its other half: the mandate has not started, so the spend this approval names is
  // refused while the approval itself is live and legal. A cosigner can therefore write one and
  // hold the nonce for as long as it lives, up to `MAX_COSIGN_TTL`.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS, notBefore: 2 * DAY });
  const held = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...held, validUntil: 3 * DAY }, { now: 1, ...DEPLOY });
  assert.equal(m.cosignReservedNonces.get(held.nonce), hash, 'held from the moment it was written');
  // While the mandate sleeps `evaluate` names the earlier refusal, and the reservation sits in
  // the Map behind it either way.
  assert.equal(evaluate(m, held, { now: 1, ...DEPLOY }).reason, Denial.NOT_YET_VALID);

  // Once the mandate is live the reservation is what answers, and the amount does not enter into
  // it: 5 USDC is far below the threshold, so the signature has no authority over that payment.
  const small = { ...held, amount: usdc('5'), recipient: OTHER };
  assert.equal(evaluate(m, small, { now: 2 * DAY, ...DEPLOY }).reason, Denial.NONCE_RESERVED);

  // The payer frees the nonce. The approval stays in the Map with its deadline untouched, so the
  // cosigner keeps every bit of authority they were granted.
  assert.equal(clearReservation(m, PAYER, held.nonce), true, 'a reservation was there');
  assert.equal(m.cosignReservedNonces.has(held.nonce), false);
  assert.equal(m.cosignApprovals.get(hash), BigInt(3 * DAY), 'the approval is intact');
  assert.equal(spend(m, small, { now: 2 * DAY, ...DEPLOY }).allowed, true);

  // And the reason the caller must be the payer. The sub-threshold spend above consumed the
  // nonce, so the cosigner's own approved request can no longer be paid — releasing a reservation
  // grants nothing directly and does hand someone that indirectly. The payer may do it because
  // `revoke` already takes every approval on the mandate at once, so this is a smaller power in
  // the same hands; for the delegate it would be a new one.
  assert.equal(evaluate(m, held, { now: 2 * DAY, ...DEPLOY }).reason, Denial.NONCE_ALREADY_USED);
  assert.equal(m.cosignApprovals.has(hash), true, 'and the approval outlives its nonce');
});

test('F47: only the payer may clear a reservation, and without a cosigner there is none to clear', () => {
  // Three guards in the contract's order: unknown mandate, then configuration, then authority.
  // The middle one earns its place the way `approveCosignFor`'s does — a mandate with no cosign
  // requirement holds no reservations, so an answer about the caller's identity would send them
  // to fix the wrong thing.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  const hash = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });

  assert.throws(() => clearReservation(null, PAYER, r.nonce), /unknown mandate/);
  // The cosigner is refused here and served by `withdrawCosign`, which takes the approval with
  // it. The two releases answer to different parties and remove different things.
  assert.throws(() => clearReservation(m, BOSS, r.nonce), /only the payer/);
  assert.throws(() => clearReservation(m, AGENT, r.nonce), /only the payer/);
  assert.throws(() => clearReservation(m, OTHER, r.nonce), /only the payer/);
  assert.equal(m.cosignReservedNonces.get(r.nonce), hash, 'and none of them moved it');

  assert.throws(
    () => clearReservation(simpleMandate(), PAYER, r.nonce),
    (err) => {
      assert.equal(err.code, ApprovalRefusal.BAD_CONFIG, err.message);
      return true;
    },
  );
});

test('F47: clearing a nonce that holds no reservation is a no-op rather than a revert', () => {
  // Matching `withdrawCosign` and the contract: the post-state the caller asked for is the
  // post-state they get. The contract emits `ReservationCleared` only when one was there, so the
  // boolean here carries the same fact the log does.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const r = req(usdc('50'));
  assert.equal(clearReservation(m, PAYER, r.nonce), false, 'nothing was reserved');

  approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });
  assert.equal(clearReservation(m, PAYER, r.nonce), true);
  assert.equal(clearReservation(m, PAYER, r.nonce), false, 'and a second call changes nothing');

  // The nonce is free for the cosigner as well: re-approving the same request writes the
  // reservation back, so the payer's release costs one signature rather than the request.
  const again = approveCosignFor(m, BOSS, { ...r, validUntil: DAY }, { now: 1, ...DEPLOY });
  assert.equal(m.cosignReservedNonces.get(r.nonce), again);
  assert.equal(spend(m, r, { now: 1, ...DEPLOY }).allowed, true, 'and it still pays');
});

test('F39: a lapsed approval stops holding its nonce, and a live one still holds it', () => {
  // THE ATTACK F30 LEFT BEHIND. The approvals Map carries a deadline; the reservation Map does
  // not. So a cosigner could approve one request with the shortest legal deadline, let it lapse,
  // and leave the nonce refused for the life of the mandate. One transaction, and the refusal
  // landed on spends BELOW the threshold — the ones the signature has no authority over at
  // all — because the reservation is checked ahead of the branch that reads the threshold.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const held = req(usdc('50'));
  approveCosignFor(m, BOSS, { ...held, validUntil: 3 }, { now: 1, ...DEPLOY });

  // While the approval is live, F30 holds exactly as it always did: a different spend on that
  // nonce is refused, and this assertion is the regression guard for the fix below.
  const small = { ...held, amount: usdc('5'), recipient: OTHER };
  assert.equal(evaluate(m, small, { now: 1, ...DEPLOY }).reason, Denial.NONCE_RESERVED);
  assert.equal(evaluate(m, small, { now: 2, ...DEPLOY }).reason, Denial.NONCE_RESERVED);

  // At the deadline the approval is gone — the bound is exclusive, matching every other deadline
  // in the model — so the reservation has no decision left to protect and the spend goes through.
  // The Map entry is still there when the spend arrives; what changed is that it no longer binds.
  assert.equal(m.cosignReservedNonces.has(small.nonce), true, 'the lapse leaves the entry behind');
  const d = evaluate(m, small, { now: 3, ...DEPLOY });
  assert.equal(d.allowed, true, 'a dead reservation refuses nothing');
  assert.equal(spend(m, small, { now: 3, ...DEPLOY }).allowed, true);

  // The entry is cleared as any consumed nonce is, so nothing accumulates.
  assert.equal(m.cosignReservedNonces.has(small.nonce), false);
  assert.equal(evaluate(m, small, { now: 3, ...DEPLOY }).reason, Denial.NONCE_ALREADY_USED);

  // The lapsed approval itself is left in its Map, unreferenced and past its deadline, which is
  // what the contract does too: clearing it would cost a write to remove something already inert.
  assert.equal(m.cosignApprovals.size, 1);
});

test('F39: once an approval lapses the cosigner can approve a replacement on that nonce', () => {
  // The approval path carries the same guard as the spend path and needed the same term. Without
  // it, the cosigner whose approval expired could not approve anything else on that nonce without
  // first withdrawing an approval that had already gone — a call that changes nothing and exists
  // only to satisfy a check reading stale state.
  const m = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  const first = req(usdc('50'));
  const firstHash = approveCosignFor(m, BOSS, { ...first, validUntil: 3 }, { now: 1, ...DEPLOY });

  // Live: refused, which is F30 and stays.
  assert.throws(
    () =>
      approveCosignFor(m, BOSS, { ...first, amount: usdc('60'), validUntil: DAY }, { now: 1, ...DEPLOY }),
    (err) => err.code === Denial.NONCE_RESERVED,
  );

  // Lapsed: allowed, and the write replaces the dead entry rather than leaving two.
  const replaced = approveCosignFor(
    m,
    BOSS,
    { ...first, amount: usdc('60'), validUntil: DAY },
    { now: 3, ...DEPLOY },
  );
  assert.notEqual(replaced, firstHash);
  assert.equal(m.cosignReservedNonces.get(first.nonce), replaced, 'one reservation, the new one');
  assert.equal(m.cosignApprovals.has(replaced), true);
  assert.equal(spend(m, { ...first, amount: usdc('60') }, { now: 3, ...DEPLOY }).allowed, true);
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

  // Split from COSIGN_REQUIRED on purpose. "This spend has no approval" and "the cosigner
  // approved it and the deadline passed" call for different actions by the caller — ask for a
  // signature versus ask for a fresh one — and collapsing them tells an operator to chase the
  // wrong party. A mandate with no approval at all still reports absence.
  const never = simpleMandate({ cosignThreshold: usdc('25'), cosigner: BOSS });
  assert.equal(evaluate(never, req(usdc('50')), { now: DAY }).reason, Denial.COSIGN_REQUIRED);

  // The stale entry LINGERS in the map rather than being swept: nothing in a denial path
  // mutates state, and the contract behaves the same way — `cosignApprovalDeadline` keeps
  // returning the dead timestamp until the slot is overwritten or withdrawn. Every read
  // compares it against the clock, so the entry is inert.
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

  // The approval is live for the real spender's spend, rather than a dead entry.
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

  // A mandate with no cosigner at all — the ordinary grant, and the most likely way for a
  // caller to arrive here by mistake. BAD_CONFIG rather than NOT_COSIGNER: the second is
  // technically true (null has no cosigner) and would send whoever reads it hunting for a
  // signing key that does not exist, when this mandate requires no signature at all.
  const ungated = simpleMandate();
  assert.equal(ungated.cosigner, null);
  assert.throws(
    () => approveCosignFor(ungated, BOSS, { ...req(usdc('50')), ...at }, { now: 1 }),
    refusedWith(ApprovalRefusal.BAD_CONFIG),
  );

  // With a cosigner present, the wrong caller gets NOT_COSIGNER — so the two codes are
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

test('F51: a revocation by the nominee closes the cosign path too', () => {
  // `revoked` is read on two paths, not one — `evaluate`, through `live`, and here. A nominee
  // who could stop spends but not approvals would leave the cosigner able to record approvals
  // against a mandate that is dead, and this is the assertion that the second path sees the
  // nominee's write exactly as it sees the payer's.
  const dead = cosignMandate({ revoker: GUARD });
  revoke(dead, GUARD);
  assert.throws(
    () => approveCosignFor(dead, BOSS, { ...req(usdc('50')), validUntil: DAY }, { now: 1 }),
    refusedWith(Denial.REVOKED),
  );
});

test('cosign (F17): an approval at or below the threshold is refused', () => {
  const m = cosignMandate();

  // The one F17 refusal that is not about consumability. `evaluate` reads the approval Map
  // solely when `amount > cosignThreshold`, so at or below the threshold this approval would
  // sit in the Map, cost the cosigner a transaction, and never be read. Refused because of
  // what it would let them believe: that their signature restricts a payment it cannot reach.
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

  // F19's mirror. This is the guard F17's derivation rule demands and F17 shipped without,
  // because F19 had not landed yet: `payer` is fixed at creation, so an approval naming the
  // payer names a spend that can never be legal, and the co-signer would be paying gas to
  // authorise a payment that moves nothing. SELF_PAYMENT wins over COSIGN_NOT_REQUIRED here
  // too — the recipient's shape is settled before the threshold is consulted, same as ZERO_AMOUNT
  // above and same as the order `evaluate` uses.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('50')), recipient: PAYER, ...at }, { now: 1 }),
    refusedWith(Denial.SELF_PAYMENT),
  );
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('1')), recipient: PAYER, ...at }, { now: 1 }),
    refusedWith(Denial.SELF_PAYMENT),
  );

  // ZERO_AMOUNT, not COSIGN_NOT_REQUIRED, even though zero is also at-or-below every
  // threshold. Both statements are true and only one is useful, so the ordering decides, and
  // it decides the same way `evaluate` does.
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

test('a request with no nonce is refused by BOTH entry points, not stored or evaluated', () => {
  // FOUND BY THE MUTATION GATE, 2026-08-29, the first run after it learned to neuter
  // `throw new Error(`. Both of these guards could be deleted with the whole suite green: no
  // test in 88 had ever omitted a nonce. The gate does not care that omitting one is a caller
  // mistake — an unasserted guard is an unasserted guard.
  //
  // Why the approve-path one matters, in F17's own terms: `evaluate` requires a nonce, so an
  // approval stored under a nonce-less hash is authority that no spend can ever consume. It is
  // the same defect as approving a spent nonce, arriving by omission rather than by reuse, and
  // omission is the likelier of the two from a caller assembling a request field by field.
  //
  // These throw plain Errors rather than carrying a refusal code, and deliberately: a missing
  // nonce is a harness mistake, not a policy outcome. The contract has no analogue because
  // `bytes32` has no absent value — `0x00…00` is a nonce like any other, and the contract treats
  // it as one. This pair therefore guards the model against a shape the ABI cannot express, which
  // is exactly where a model needs its own rules.
  const m = cosignMandate();
  for (const missing of [undefined, null, '']) {
    assert.throws(
      () => approveCosignFor(m, BOSS, { ...req(usdc('50')), nonce: missing, validUntil: DAY }, { now: 1 }),
      /nonce is required/,
    );
    assert.throws(() => evaluate(m, { ...req(usdc('5')), nonce: missing }, { now: 1 }), /nonce is required/);
  }
  assert.equal(m.cosignApprovals.size, 0, 'nothing was stored under a nonce-less hash');
  assert.equal(m.cosignReservedNonces.size, 0);

  // Zero is a value, not an absence, and the contract stores exactly this nonce. `'0'` and `0n`
  // both have to work or the model would refuse a spend the chain accepts.
  for (const zero of ['0', 0n, '0x0']) {
    assert.equal(spend(m, { ...req(usdc('5')), nonce: zero }, { now: 1 }).allowed, true);
  }
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
  // the width of the counter. The contract's twin of this test,
  // `test_f17_approvingPastTheUint96AuditCeiling_isRefused`, is built the same way for the same
  // reason, and exists because the Solidity mutation gate found this guard unasserted there
  // while it was already asserted here.
  const uncapped = cosignMandate({ perTxCap: null, windows: [], cosignThreshold: 0n });
  uncapped.totalSpent = MAX_AMOUNT - 1n;
  assert.throws(
    () => approveCosignFor(uncapped, BOSS, { ...req(2n), ...at }, { now: 1 }),
    refusedWith(Denial.TOTAL_SPENT_CEILING),
  );

  // The last base unit the counter can hold is approvable, and spendable.
  const lastUnit = req(1n);
  approveCosignFor(uncapped, BOSS, { ...lastUnit, ...at }, { now: 1 });
  assert.equal(spend(uncapped, lastUnit, { now: 1 }).allowed, true);
  assert.equal(uncapped.totalSpent, MAX_AMOUNT);
});

test('cosign (F3): an approval on a mandate at the spend-count ceiling is refused', () => {
  // NEW IN v2 (F3). The counter ceiling reaches `approveCosignFor` for F17's reason, and it is
  // the strongest case F17 has: every other bound there refuses an approval for the amount it
  // names, while a mandate at this ceiling can consume no spend of any size ever again. The
  // approval would sit in storage, cost the co-signer a transaction, and be unconsumable for
  // its whole life.
  //
  // `cosignThreshold: 0n` for the reason the uint96 twin above gives: at the inherited 10 USDC
  // threshold a one-unit approval comes back COSIGN_NOT_REQUIRED, and this test would be
  // measuring guard order instead of the counter.
  const at = { validUntil: DAY };
  const m = cosignMandate({ perTxCap: null, windows: [], cosignThreshold: 0n });

  // One short of the ceiling the approval is legal, and consuming it arrives at the ceiling.
  // Asserting this side matters as much as the refusal: a guard off by one, or one aimed at a
  // merely large counter, would refuse this approval too.
  m.spendCount = MAX_SPEND_COUNT - 1n;
  const last = req(1n);
  approveCosignFor(m, BOSS, { ...last, ...at }, { now: 1 });
  assert.equal(spend(m, last, { now: 1 }).allowed, true);
  assert.equal(m.spendCount, MAX_SPEND_COUNT);

  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(1n), ...at }, { now: 1 }),
    refusedWith(Denial.SPEND_COUNT_CEILING),
  );

  // Amount-independent here as well, so the refusal is not the per-transaction cap or the
  // lifetime ceiling answering under another name.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...req(usdc('1000')), ...at }, { now: 1 }),
    refusedWith(Denial.SPEND_COUNT_CEILING),
  );
});

test('cosign (F17): the deadline must outlive notBefore and die by the expiry', () => {
  // Both bounds refuse rather than clamp, for F16's reason: a deadline the model moved with no
  // refusal is a deadline the cosigner did not agree to.
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
  // payments primitive is a self-inflicted liveness failure. Each case therefore proves
  // the approval was usable once the condition passed, rather than merely stored.

  // (a) A start date in the future. The ordinary case for a scheduled payment.
  const later = cosignMandate({ notBefore: DAY });
  const r1 = req(usdc('50'));
  assert.equal(evaluate(later, r1, { now: 1 }).reason, Denial.NOT_YET_VALID);
  approveCosignFor(later, BOSS, { ...r1, validUntil: 3 * DAY }, { now: 1 });
  assert.equal(spend(later, r1, { now: DAY }).allowed, true);

  // (b) A full rolling window — the sharpest of the three, because the window arithmetic is
  // the most tempting to mirror and the least safe to. `windowUsage` FALLS as buckets age
  // out, so an amount refused now fits later with nothing else changed.
  //
  // F40 mirrors the other half of the same comparison, so the amount here matters: 50 against a
  // cap of 50 is not above it, and the approval stands. An amount ABOVE the cap never fits, and
  // the test below is where that is asserted.
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

test('cosign (F40): an amount above a window cap is refused, and one that merely does not fit now is not', () => {
  // The half of `OVER_WINDOW_CAP` that is permanent, and the reason the test above needed care.
  // Usage falls back toward zero as buckets age out, so `used + amount > cap` clears and is not
  // mirrored. `amount > cap` cannot clear: usage never goes below zero and `cap` is fixed at
  // creation, so an amount above it is refused for the life of the mandate. Case (b) above sits
  // exactly AT the cap, which is why it stays approvable — the comparison is strict.
  const m = cosignMandate({ windows: [win(DAY, usdc('50'), 12)] });
  const over = req(usdc('60'));

  // The window is empty, so nothing about current usage is doing the work here.
  assert.equal(evaluate(m, over, { now: 1, ...DEPLOY }).reason, Denial.OVER_WINDOW_CAP);
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...over, validUntil: DAY }, { now: 1, ...DEPLOY }),
    (err) => err.code === Denial.OVER_WINDOW_CAP,
    'above the cap on an empty window',
  );
  // Still refused a week later, which is what "permanent" means.
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...over, validUntil: 8 * DAY }, { now: 7 * DAY, ...DEPLOY }),
    (err) => err.code === Denial.OVER_WINDOW_CAP,
  );

  // At the cap: approvable, and consumable, so the boundary is right rather than only permissive.
  const atCap = req(usdc('50'));
  approveCosignFor(m, BOSS, { ...atCap, validUntil: DAY }, { now: 1, ...DEPLOY });
  assert.equal(spend(m, atCap, { now: 1, ...DEPLOY }).allowed, true);

  // Every window is checked, not just the first. The daily cap here is generous and the weekly
  // one is not, so a mandate whose first window passes must still meet the second.
  const two = cosignMandate({
    perTxCap: usdc('1000'),
    windows: [win(DAY, usdc('500'), 12), win(7 * DAY, usdc('300'), 12)],
  });
  const past = req(usdc('400'));
  assert.throws(
    () => approveCosignFor(two, BOSS, { ...past, validUntil: DAY }, { now: 1, ...DEPLOY }),
    (err) => err.code === Denial.OVER_WINDOW_CAP,
    'the second window governs',
  );
  assert.equal(
    approveCosignFor(two, BOSS, { ...req(usdc('300')), validUntil: DAY }, { now: 1, ...DEPLOY })
      .length > 0,
    true,
    'at the tighter cap, still approvable',
  );
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

  // registry says no address holds it
  assert.equal(
    evaluate(m, req(usdc('10')), { now: 1, resolveIdentityOwner: () => null }).reason,
    Denial.IDENTITY_NOT_HELD,
  );
});

test('ATTACK: transferring the agent identity NFT does not carry spending authority', () => {
  // ERC-8004 identities are transferable ERC-721s, so a live ownerOf check alone
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
  // The cost is real and is in the README: a payer who forgets the field gets a credential
  // check that never expires. That is the better failure of the two.
  const zero = credMandate({ maxStaleness: 0n });
  const ancient = attestation({ lastUpdate: 1_000_000 - 3650 * DAY });
  assert.equal(evaluate(zero, req(usdc('10')), withCred(ancient)).allowed, true);

  // null keeps working and means the same thing, for callers writing the model
  // directly rather than encoding a struct.
  const omitted = credMandate({ maxStaleness: null });
  assert.equal(evaluate(omitted, req(usdc('10')), withCred(ancient)).allowed, true);

  // A positive value still enforces.
  const strict = credMandate({ maxStaleness: BigInt(DAY) });
  assert.equal(evaluate(strict, req(usdc('10')), withCred(ancient)).reason, Denial.CREDENTIAL_STALE);
});

test('credential gate (F31): a future-dated attestation is refused, not fresh forever', () => {
  // THE BUG THIS CLOSES: the old condition read
  //   `now > lastUpdate && now - lastUpdate > maxStaleness`
  // and the first half was there for one reason: `now - lastUpdate` is unsigned, so a stamp
  // ahead of the clock would underflow into an enormous age. It prevented that, and in doing so
  // it skipped the freshness test altogether for exactly the one class of attestation that
  // cannot be honest about its age. A validator whose clock runs fast files one stamp in the
  // future and buys a credential that never expires — no attack required, just a wrong clock.
  const m = credMandate({ maxStaleness: BigInt(DAY) });
  const future = attestation({ lastUpdate: 1_000_000 + 365 * DAY });
  assert.equal(evaluate(m, req(usdc('10')), withCred(future)).reason, Denial.CREDENTIAL_STALE);

  // Refused for as long as the stamp leads the clock, then ordinary once the clock catches up.
  // The rule is about an age that cannot be measured, not a permanent blacklisting of the stamp.
  assert.equal(
    evaluate(m, req(usdc('10')), { ...withCred(future), now: 1_000_000 + 364 * DAY }).reason,
    Denial.CREDENTIAL_STALE,
  );
  assert.equal(
    evaluate(m, req(usdc('10')), { ...withCred(future), now: 1_000_000 + 365 * DAY }).allowed,
    true,
  );

  // One second ahead is enough, which is what proves the guard is a comparison against the clock
  // and not a tolerance band — and it is also the case that would have underflowed.
  assert.equal(
    evaluate(m, req(usdc('10')), withCred(attestation({ lastUpdate: 1_000_001 }))).reason,
    Denial.CREDENTIAL_STALE,
  );

  // A stamp at exactly the current second is fresh, so the ordinary case is untouched: the new
  // first leg is a strict `>`, and getting that wrong would refuse every attestation filed in
  // the same block as the spend.
  assert.equal(
    evaluate(m, req(usdc('10')), withCred(attestation({ lastUpdate: 1_000_000 }))).allowed,
    true,
  );

  // The reported age is null rather than a wrapped number when the stamp leads the clock. A
  // denial that answered "age: 18446744073709551516" would send whoever read it hunting for a
  // stale credential instead of a broken validator clock.
  const d = evaluate(m, req(usdc('10')), withCred(future));
  assert.equal(d.detail.age, null);
  assert.equal(d.detail.lastUpdate, BigInt(1_000_000 + 365 * DAY));

  // maxStaleness 0 still means "no freshness requirement", so F31 tightened the freshness rule
  // without turning the permissive setting into a strict one.
  const zero = credMandate({ maxStaleness: 0n });
  assert.equal(evaluate(zero, req(usdc('10')), withCred(future)).allowed, true);
});

test('credential gate: agentId of 0 means unset, and unset with no identity skips the check', () => {
  // The same encoding hazard as maxStaleness, and the same resolution: the contract's
  // field is a uint256 with no null, so `c.agentId != 0` is what "unset" has to mean.
  // A model that used `??` here would treat 0 as "require the attestation to be about
  // agent 0" — a state the contract cannot express, and exactly the divergence that
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
  // A real, passing, fresh attestation from the right validator, issued about another
  // account's agentId, must not transfer to this mandate.
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
  // The property that makes the joint view trustworthy: the joint view sums the per-mandate
  // opinion rather than forming one of its own. If these ever diverge the joint view has
  // grown a rule the per-mandate view does not have.
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
  // bounded only by an expiry. In Solidity the same case returns type(uint256).max, so
  // `sum += policyHeadroom(id)` over two of these PANICS, and it is reachable in practice:
  // two expiry-only grants from one payer is a two-line construction, which is what
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

  // With every term bounded, the widest total the contract can be asked for —
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
  // reversed array must be refused for the same reason rather than accepting
  // whichever payer happened to be named first with no error.
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
  // 100 to a caller who believes they hold two mandates. Deduplicating would
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
  // above is the expiry doing the work rather than the clamp failing with no error.
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
    // never above the nominal cap
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
// The three tests in this block were not written from the spec. Each one exists because
// `node reference/mutation-gate.js evaluate` — the first mutation run ever aimed at the spend
// path rather than at `approveCosignFor` — broke a guard, or added one, and NOTHING in the
// suite noticed. A green 72/72 had been reporting on all three of them for weeks.

test('evaluate refuses a mandate that does not exist (the gate found this one unasserted)', () => {
  // `Denial.UNKNOWN_MANDATE` was asserted exactly once in this file, and for the WRONG
  // function: the F17 prologue test above pins it for `approveCosignFor`. The spend path's own
  // null check could therefore be deleted without any test asserting the denial it produces. The
  // deletion did not pass unnoticed, since the next line reads `mandate.revoked` off null and
  // throws, but a TypeError from a model is not a denial, and a caller integrating against it
  // cannot tell the two apart. The contract has this covered on both sides (test/Bounds.t.sol
  // pays an unknown id and expects UnknownMandate); until now the model only had it on one.
  for (const absent of [null, undefined]) {
    const d = evaluate(absent, req(usdc('10')), { now: 1 });
    assert.equal(d.allowed, false, `evaluate(${absent}) must deny rather than throw`);
    assert.equal(d.reason, Denial.UNKNOWN_MANDATE);
  }
});

test('identity gate (F27): pinning expectedOwner to anyone but the spender is refused at grant time', () => {
  // `Denial.IDENTITY_TRANSFERRED` had no test at all: every `expectedOwner` in this file was
  // set to AGENT, which is also the spender, so the guard was never once reached. Asking why
  // is what turned a coverage hole into a finding.
  //
  // The identity check is two conditions on one value: `owner` must equal the SPENDER and must
  // then equal `expectedOwner`. Both compare against the same `owner`, so together they say
  // `expectedOwner === spender` — and `spender` is already checked against the caller before the
  // identity check ever runs, which leaves the second condition stating no fact of its own. It
  // has exactly three outcomes, and none of them is what a payer expects from a field that reads
  // as pinning the owner they chose:
  //
  //   absent/zero          the guard is skipped
  //   equal to the spender the guard is redundant with the check above it
  //   anything else        NO caller can ever spend, for the mandate's whole life
  //
  // CHANGED IN v2 (F33). This test used to grant the third case and assert IDENTITY_TRANSFERRED.
  // That was accurate and was still endorsing a bug: the pin bricked the mandate rather than
  // protecting it, and the payer could not tell those apart from the denial. Both
  // `createMandate` and the contract now refuse the configuration at the one moment the payer
  // can still fix it, so the assertion is a throw and the old denial is unreachable.
  assert.throws(
    () => simpleMandate({ identity: { agentId: 42n, expectedOwner: BOSS } }),
    /expectedOwner/,
  );

  // The only pin that constructs is the one that repeats the spender check above it, and it
  // spends — which is the redundancy claim made concrete rather than asserted.
  const pinned = simpleMandate({ identity: { agentId: 42n, expectedOwner: AGENT } });
  assert.equal(
    evaluate(pinned, req(usdc('10')), { now: 1, resolveIdentityOwner: () => AGENT }).allowed,
    true,
  );

  // The first condition still does the work the pin was imagined to do: an identity the
  // spender does not hold denies, whoever holds it. This is the check that actually protects a
  // payer against the ERC-721 being sold, and it needs no `expectedOwner` at all.
  for (const owner of [BOSS, OTHER, null]) {
    const r = evaluate(pinned, req(usdc('10')), { now: 1, resolveIdentityOwner: () => owner });
    assert.equal(r.allowed, false, `owner=${owner} is not the spender, so the gate must deny`);
    assert.equal(r.reason, Denial.IDENTITY_NOT_HELD);
  }
});

test('identity gate (F28): expectedOwner = address(0) means "do not pin" in the model too, now', () => {
  // CLOSED DIVERGENCE, kept as a regression test rather than deleted.
  //
  // The model used to test `expectedOwner` for bare truthiness, and the zero address as a STRING
  // is truthy in JavaScript. The contract documents `address(0) = do not pin` and implements it
  // with an explicit `g.expectedOwner != address(0)`, so the same mandate was spendable
  // on-chain and permanently dead in the model.
  //
  // The direction is what made it worth fixing rather than noting. A model stricter than the
  // contract causes no bad spend, but it tells a payer their mandate is bricked when the chain
  // would honour it — and with F27 above, a reader told IDENTITY_TRANSFERRED had every reason
  // to believe it.
  //
  // It was fixed here, in the same pass as F33, because F33 made it untenable: `createMandate`
  // now refuses three configurations for being unspendable, and would have gone on minting this
  // one. The original note deferred the fix to #23 to keep a mutation run clean; the run it was
  // protecting is finished.
  //
  // This is one of two instances of a single hazard, a zero the contract reads as "unset" and
  // the model read as a value. The other is `maxStaleness`, where the model is still wrong and
  // test_credentialGate_zeroMaxStaleness_meansNoFreshnessRequirement in test/Gates.t.sol says so
  // in as many words.
  const zeroPinned = simpleMandate({ identity: { agentId: 42n, expectedOwner: ZERO_ADDRESS } });
  const d = evaluate(zeroPinned, req(usdc('10')), { now: 1, resolveIdentityOwner: () => AGENT });
  assert.equal(d.allowed, true, 'the zero address is the absence of a pin, not a pin at nobody');

  // Every spelling of "do not pin" behaves identically, which is the property that was missing:
  // the suite only ever used the third one, which is why nothing caught this.
  for (const identity of [
    { agentId: 42n, expectedOwner: ZERO_ADDRESS },
    { agentId: 42n, expectedOwner: null },
    { agentId: 42n },
  ]) {
    assert.equal(
      evaluate(simpleMandate({ identity }), req(usdc('10')), {
        now: 1,
        resolveIdentityOwner: () => AGENT,
      }).allowed,
      true,
    );
    // None of them weakens the check that matters: the spender must still hold the identity.
    assert.equal(
      evaluate(simpleMandate({ identity }), req(usdc('10')), {
        now: 1,
        resolveIdentityOwner: () => OTHER,
      }).reason,
      Denial.IDENTITY_NOT_HELD,
    );
  }
});

test('identity gate: IDENTITY_TRANSFERRED is unreachable by construction, and denies if reached', () => {
  // A test for dead code, written deliberately, and labelled so that it is not removed later as
  // redundant with F27 and F28 above.
  //
  // F33 closed the last route to this denial. A pin at anyone but the spender is refused at grant
  // time, the zero address means "do not pin", and so the only pin that constructs is the one
  // that repeats the ownership check sitting above it. The guard stays rather than being deleted
  // for two reasons: dead code whose only possible effect is to REFUSE a payment fails in the
  // safe direction, and the contract keeps its twin, so removing one would put the two languages
  // out of step over a branch neither can reach.
  //
  // The mutation gate reports that decision as a survivor — neuter the line and no test fails,
  // because nothing can build the state that reaches it. This reaches it by assigning the
  // forbidden pin straight onto the mandate, which is the only route left, and it buys two
  // things: the mutation gate goes clean, so a survivor at that line in future means something
  // changed instead of "that is the known one", and the retained branch is shown to deny rather
  // than assumed to.
  //
  // Expect the same survivor on the Solidity side for the same reason: test/Gates.t.sol carries
  // test_identityGate_expectedOwnerNotTheSpender_isRefusedAtGrantTime, which documents
  // `IdentityTransferred` as unreachable, and the spend path's mutation run was clean at 17/17
  // before F33.
  const m = simpleMandate({ identity: { agentId: 42n, expectedOwner: AGENT } });
  m.identity = { ...m.identity, expectedOwner: OTHER }; // the state createMandate refuses to mint

  const d = evaluate(m, req(usdc('10')), { now: 1, resolveIdentityOwner: () => AGENT });
  assert.equal(d.allowed, false, 'a pin the owner does not satisfy must deny');
  assert.equal(d.reason, Denial.IDENTITY_TRANSFERRED);
  // The detail is the whole reason this denial has its own code rather than reusing
  // IDENTITY_NOT_HELD: it tells the payer the identity exists and moved, and to whom.
  assert.equal(d.detail.expected, OTHER);
  assert.equal(d.detail.got, AGENT);

  // The ordering still holds underneath. The spender-holds-it check runs first, so an owner who
  // is neither the spender nor the pin gets the reachable denial, not this one.
  assert.equal(
    evaluate(m, req(usdc('10')), { now: 1, resolveIdentityOwner: () => BOSS }).reason,
    Denial.IDENTITY_NOT_HELD,
  );
  // `createMandate` still refuses to produce the object this test had to assemble by hand, which
  // is the claim that makes the guard dead in the first place.
  assert.throws(
    () => simpleMandate({ identity: { agentId: 42n, expectedOwner: OTHER } }),
    /expectedOwner/,
  );
});

test('F22: a delegate may be paid by its own mandate — recipient == spender stays ALLOWED', () => {
  // THE MOST IMPORTANT OF THESE THREE, and the one no removal-mutation could ever have found.
  // Deleting a guard makes the model more permissive; this is a claim that the model must not
  // become STRICTER. The gate reaches it by INJECTING the guard Remit must never have, at the
  // last line before `return { allowed: true }` — so it can only fire on a spend that was about
  // to be allowed, and only a test expecting an allow can kill it. Nothing did.
  //
  // THREAT-MODEL.md section 2 already warned about this in prose: F19 refuses paying the PAYER,
  // and the English phrase "self-payment" covers that and paying the SPENDER equally well while
  // the two are opposites. Paying the payer is a no-op that burns an allowance and forges an
  // audit trail. Paying the spender is an agent invoicing for its work, or a payroll delegate
  // taking its own salary line — ordinary, supported, and the reason someone was delegated to
  // in the first place. `Denial.SELF_PAYMENT` is the code F19 raises, so the plausible mistake
  // is not inventing a new guard but WIDENING that one, which is how the injection is written.
  //
  // The two cases therefore go in one test, on one mandate, three lines apart. Read together they
  // say what neither says alone: the condition is the claim, and the name covers both.
  const m = cosignMandate();

  const paysItself = evaluate(m, req(usdc('5'), { recipient: AGENT }), { now: 1 });
  assert.equal(paysItself.allowed, true, 'a delegate paying itself must not be refused');

  const paysPayer = evaluate(m, req(usdc('5'), { recipient: PAYER }), { now: 1 });
  assert.equal(paysPayer.allowed, false);
  assert.equal(paysPayer.reason, Denial.SELF_PAYMENT);

  // Above the cosign threshold the same asymmetry has to survive the mirror, because F17 makes
  // `approveCosignFor` refuse every PERMANENT denial `evaluate` would raise. A must-NOT-refuse
  // is mirrored too: if the spender were ever added to the payer guard, the cosigner would be
  // unable to approve the payment as well as the agent unable to make it, and F17's parity test
  // would keep passing throughout — both halves would be wrong in the same direction.
  const big = { ...req(usdc('50'), { recipient: AGENT }), validUntil: DAY };
  assert.doesNotThrow(() => approveCosignFor(m, BOSS, big, { now: 1 }));
  assert.throws(
    () => approveCosignFor(m, BOSS, { ...big, recipient: PAYER }, { now: 1 }),
    refusedWith(Denial.SELF_PAYMENT),
  );

  // An allowlist is the one thing that legitimately stops a delegate paying itself, and it does
  // so by naming who may be paid rather than by knowing anything about the spender. Pinning it
  // here keeps a future reader from "fixing" the allow above by reaching for a self-payment
  // check when the allowlist was the mechanism all along.
  const listed = cosignMandate({ allowlist: [VENDOR] });
  assert.equal(
    evaluate(listed, req(usdc('5'), { recipient: AGENT }), { now: 1 }).reason,
    Denial.RECIPIENT_NOT_ALLOWED,
  );
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

  // The direct check on vacuity: a large number of spends must actually have been
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
