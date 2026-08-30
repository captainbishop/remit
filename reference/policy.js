// SPDX-License-Identifier: MIT
//
// Remit — executable reference model for the spending-policy engine.
//
// WHY THIS FILE EXISTS
// This is the normative specification of the policy logic. MandateManager.sol is
// a line-for-line mirror of it. It was written first because the sandbox it was
// authored in could not compile Solidity, so the contract's *logic* had to be
// verified somewhere — here, in a dependency-free model with an adversarial test
// suite, with the contract held to match. The contract now compiles, passes 225
// Forge tests of its own, and runs on Arc Testnet, which makes this a cross-check
// rather than the only evidence, and that is strictly better: two independent
// implementations that agree are worth more than one that passes. Where the two
// disagree, this file is the bug report — except on the ten questions where the
// reverse turned out to be true and this model was corrected to match the contract.
//
// UNITS
// Every amount is a BigInt in ERC-20 USDC units: 6 decimals, so 1 USDC = 1_000_000n.
// Arc exposes USDC through two interfaces over ONE balance, native at 18 decimals and
// ERC-20 at 6 (arc/references/evm-differences.mdx). This engine speaks 6-decimal ERC-20 units
// exclusively, which is what the Arc docs recommend for application
// accounting, and never mixes in an 18-decimal value.
//
// TIME
// `now` is a block timestamp in seconds. Arc timestamps are NON-DECREASING but NOT
// strictly increasing: sub-second blocks (~0.48s average) can share a timestamp
// (arc/references/evm-differences.mdx). The engine therefore never treats a timestamp
// as unique, never uses it for ordering, and never assumes it advanced between calls.
// Replay protection and ordering come from explicit nonces instead.

'use strict';

const USDC = 1_000_000n; // one USDC in 6-decimal units

/** Parse a decimal USDC string ("12.50") into 6-decimal integer units. Exact, no floats. */
function usdc(value) {
  const s = String(value).trim();
  if (!/^\d+(\.\d{1,6})?$/.test(s)) {
    throw new Error(`usdc(): "${value}" must be a non-negative decimal with <= 6 dp`);
  }
  const [whole, frac = ''] = s.split('.');
  return BigInt(whole) * USDC + BigInt(frac.padEnd(6, '0'));
}

/** Format 6-decimal units back to a human string. */
function formatUsdc(units) {
  const n = BigInt(units);
  const whole = n / USDC;
  const frac = (n % USDC).toString().padStart(6, '0').replace(/0+$/, '');
  return frac ? `${whole}.${frac}` : `${whole}`;
}

// Denial reasons. These strings are mirrored 1:1 by custom errors in MandateManager.sol.
const Denial = {
  UNKNOWN_MANDATE: 'UNKNOWN_MANDATE',
  REVOKED: 'REVOKED',
  NOT_YET_VALID: 'NOT_YET_VALID',
  EXPIRED: 'EXPIRED',
  WRONG_SPENDER: 'WRONG_SPENDER',
  RECIPIENT_NOT_ALLOWED: 'RECIPIENT_NOT_ALLOWED',
  ZERO_AMOUNT: 'ZERO_AMOUNT',
  ZERO_RECIPIENT: 'ZERO_RECIPIENT',
  // NEW IN v2 (F19). `recipient === payer` was a legal spend that consumed every cap and moved
  // nothing, and Arc's system emitter writes no log for a self-transfer, so it was the one
  // class of spend a reconciler could not see. Refused on both the spend path and the cosign
  // approval, since `payer` is fixed at creation and the equality can never stop holding.
  SELF_PAYMENT: 'SELF_PAYMENT',
  // NEW IN v2 (F29), widened by F38. Four addresses can receive a payment and can never send it
  // on: the manager itself, which holds no USDC by design and has no sweep function; the token
  // contract, which has no recovery path either; and both ERC-8004 registries, which this
  // system only reads and whose interfaces carry no transfer at all. None is a plausible payee,
  // so refusing all four costs nothing legitimate — and unlike every other denial here, the
  // mistake it prevents cannot be undone by anyone once the transfer has settled.
  //
  // F29 named only the first two, in three hand-written copies. F38 replaced the copies with
  // `undebitableAddrs`, which is where the full list now lives.
  UNRECOVERABLE_RECIPIENT: 'UNRECOVERABLE_RECIPIENT',
  AMOUNT_TOO_LARGE: 'AMOUNT_TOO_LARGE',
  OVER_PER_TX_CAP: 'OVER_PER_TX_CAP',
  OVER_WINDOW_CAP: 'OVER_WINDOW_CAP',
  OVER_TOTAL_CAP: 'OVER_TOTAL_CAP',
  TOTAL_SPENT_CEILING: 'TOTAL_SPENT_CEILING',
  // NEW IN v2 (F3). The other unconditional ceiling, one counter over from the one above.
  // The contract packs its spend counter as a uint32 beside the uint96 total, and v1 let it
  // wrap into an unnamed arithmetic panic instead of denying. This code is the panic given a
  // name, and it is in the model for the same reason MAX_AMOUNT is: a BigInt has no width,
  // so leaving the bound out would make the model allow a spend the contract refuses.
  SPEND_COUNT_CEILING: 'SPEND_COUNT_CEILING',
  NONCE_ALREADY_USED: 'NONCE_ALREADY_USED',
  // NEW IN v2 (F30). A nonce named in a live co-signature is held for the exact spend that
  // signature approved. Without this, any spend on that nonce — a one-unit payment to an
  // address the agent controls — consumed the nonce and left the approval pointing at a hash
  // no spend could ever reach again, so the cosigner's signature was destroyed by a payment
  // they never saw. Distinct from NONCE_ALREADY_USED: that nonce is spent and gone, this one
  // is spoken for and the request that owns it still works.
  NONCE_RESERVED: 'NONCE_RESERVED',
  COSIGN_REQUIRED: 'COSIGN_REQUIRED',
  // NEW IN v2 (F16). Split from COSIGN_REQUIRED rather than folded into it: the two need
  // different actions from whoever reads the denial. COSIGN_REQUIRED means no approval was
  // recorded for this spend; COSIGN_EXPIRED means one was and its window has closed.
  COSIGN_EXPIRED: 'COSIGN_EXPIRED',
  IDENTITY_NOT_HELD: 'IDENTITY_NOT_HELD',
  IDENTITY_TRANSFERRED: 'IDENTITY_TRANSFERRED',
  CREDENTIAL_MISSING: 'CREDENTIAL_MISSING',
  CREDENTIAL_STALE: 'CREDENTIAL_STALE',
  CREDENTIAL_WRONG_VALIDATOR: 'CREDENTIAL_WRONG_VALIDATOR',
  CREDENTIAL_WRONG_AGENT: 'CREDENTIAL_WRONG_AGENT',
};

/**
 * Refusal codes `approveCosignFor` can raise that `evaluate` cannot, and the reason they are
 * NOT in `Denial`.
 *
 * NEW IN v2 (F17). `Denial` is the set of reasons a SPEND can be refused, mirrored 1:1 by the
 * contract's errors, and every value in it is reachable from `evaluate`, which is true of none
 * of the four above. Folding them in would put entries in an enum that the function the enum
 * describes can never produce — the same "displayed but dead" defect that `createMandate` now
 * refuses in three other places, so it is not a defect this model gets to commit itself.
 *
 * Every OTHER refusal `approveCosignFor` raises reuses a `Denial` value verbatim, and that
 * reuse is deliberate rather than cosmetic: it is what lets a test assert that a request
 * with one permanent defect is refused with the SAME code by both functions.
 */
const ApprovalRefusal = {
  // The contract's BadConfig(): F_COSIGN unset, so there is no cosign requirement to approve
  // against.
  BAD_CONFIG: 'BAD_CONFIG',
  // The contract's NotCosigner().
  NOT_COSIGNER: 'NOT_COSIGNER',
  // The contract's BadDeadline(validUntil), covering all four bounds on `validUntil`: the two
  // clock-relative ones from F16 and the two mandate-relative ones from F17. One code for all
  // four because the fix is the same in every case — send a different deadline.
  BAD_DEADLINE: 'BAD_DEADLINE',
  // The contract's CosignNotRequired(amount, threshold). The one F17 refusal that is not about
  // an approval being unconsumable; see the note in `approveCosignFor`.
  COSIGN_NOT_REQUIRED: 'COSIGN_NOT_REQUIRED',
};

const DAY = 86_400;
const WEEK = 7 * DAY;
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

// Bounds the on-chain implementation must enforce, mirrored here so the model and
// MandateManager.sol cannot drift. Each spend reads every ring slot of every
// window, so these caps are what keep the gas cost of a spend bounded and
// predictable rather than a function of untrusted grant-time input.
const MAX_WINDOWS = 4;
const MAX_BUCKETS = 32;

// NEW IN v2 (F16). Furthest ahead a cosigner may set an approval's deadline, mirrored from
// MandateManager.MAX_COSIGN_TTL. This one belongs in the model for the same reason the two
// caps above do and MAX_JOINT does not: it changes which spends are legal, rather than only
// rationing a read.
const MAX_COSIGN_TTL = 30n * 86_400n;

/**
 * Largest spendable amount: 2^96 - 1, about 7.9e22 USDC.
 *
 * This exists only because the contract does. `totalSpent` and every cap are packed
 * as uint96 so that a Mandate fits in few storage slots, and `spend` takes a uint256
 * amount which it casts down. An unchecked cast would truncate a huge amount into a
 * small one that passes every cap, so the contract refuses anything that does not fit
 * before consulting a single bound. JavaScript's BigInt has no such limit and would
 * diverge here without raising an error, which is the reason to mirror the constant
 * rather than let the model be more permissive than the thing it specifies.
 */
const MAX_AMOUNT = (1n << 96n) - 1n;

/**
 * Largest reachable spend counter: 2^32 - 1, about 4.29 billion spends.
 *
 * NEW IN v2 (F3). Here for the reason MAX_AMOUNT is here, applied to the counter beside
 * the total rather than to the total: the contract packs `spendCount` as a uint32, and a
 * BigInt would sail past that width and call a spend allowed that the contract refuses.
 *
 * The two ceilings are not equally remote, and the contract's changelist once argued the
 * reverse. Reaching 2^96 base units in fewer than 2^32 spends needs an average spend near
 * 2^64, about 18.4 trillion USDC, against a circulating supply near 6.1e10. Any history a real
 * balance can fund therefore meets this ceiling first, by a factor of roughly 300, which is
 * what makes it the one worth naming.
 */
const MAX_SPEND_COUNT = (1n << 32n) - 1n;

/**
 * Create a rolling-window spec.
 *
 * WHY A BUCKET RING, AND WHY IT ERRS STRICT
 *
 * An exact sliding window needs the timestamp of every spend, which is unbounded
 * storage and therefore not implementable on-chain. Two cheap approximations exist,
 * each with a distinct failure mode:
 *
 *   1. Tumbling window (reset the counter each period). The least expensive of the
 *      two, and badly broken: spend the full cap in the last second of period N and
 *      the full cap again in the first second of N+1 — 2x the cap inside two seconds.
 *
 *   2. Proportional two-bucket decay (the classic "sliding window counter") weights
 *      the previous period by how much of it still overlaps, which is closer, though
 *      it UNDERCOUNTS when spending is clustered at the end of the previous period:
 *      it assumes uniform distribution, so an agent that front-loads can still
 *      exceed the cap over a true trailing window.
 *
 * This implementation splits the window into K = `buckets` sub-periods of
 * S = L/K seconds and keeps a ring of per-sub-period counters. With b = now/S the
 * current sub-bucket, usage is the sum of buckets [b-K, b] — that is K+1 buckets
 * rather than K, and the +1 is what makes the guarantee below hold.
 *
 * WHY K+1 (this was a bug, caught by the fuzz test in policy.test.js)
 * Summing only [b-K+1, b] covers the span [(b-K+1)S, (b+1)S), which is L seconds
 * long but ends at the END of the current bucket — in the future relative to now.
 * The span is therefore shifted forward by up to S, and bucket b-K falls out of
 * the ring. Bucket b-K always still overlaps the true trailing window (t-L, t],
 * since its end (b-K+1)S = bS + S - L > t - L for every t < (b+1)S. A spend late in
 * bucket b-K therefore stopped being counted while it was still inside the window —
 * a real breach rather than a rounding artifact. The fuzz test found it at K=4 by
 * spending near the end of a sub-bucket and again exactly K buckets later.
 *
 * THE GUARANTEE, with the +1
 * Take any spend at time u in (t-L, t]. Its bucket is floor(u/S) <= b since u <= t,
 * and u > t-L >= bS - L = (b-K)S gives floor(u/S) >= b-K, so every spend in the true
 * trailing window sits in [b-K, b] and IS counted. The engine can therefore never
 * permit more than `cap` in any true trailing window of L.
 *
 * THE PRICE
 * The counted span is (K+1)S = L + S, so up to one extra sub-period of history is
 * charged against the cap. An agent spending at a perfectly steady rate settles
 * at K/(K+1) of its nominal cap: 92% at K=12, 96% at K=24. Raise `buckets` to
 * shrink the gap; the cost is one more storage slot and one more read per check.
 * That read was measured on 2026-08-24 at ~2,150 gas, 0.000043 USDC on Arc, so
 * K=12 -> K=24 costs about 0.0005 USDC per spend. The strict setting is cheap.
 *
 * For a safety primitive, denying slightly too often is the correct direction to
 * be wrong. Overspending is not recoverable; a retry is.
 */
function window(lengthSeconds, cap, buckets = 12) {
  const L = BigInt(lengthSeconds);
  const K = BigInt(buckets);
  if (L <= 0n) throw new Error('window(): lengthSeconds must be positive');
  if (K <= 0n) throw new Error('window(): buckets must be positive');
  if (K > BigInt(MAX_BUCKETS)) {
    throw new Error(`window(): buckets must be <= ${MAX_BUCKETS} to bound the gas cost of a spend`);
  }
  if (L % K !== 0n) {
    throw new Error(
      `window(): lengthSeconds (${L}) must be divisible by buckets (${K}) so sub-periods are uniform`,
    );
  }
  // A window whose cap is zero can never permit a spend, and it also satisfies the
  // "at least one bound" check in createMandate, so accepting it mints a mandate that
  // looks configured and is dead; the contract calls this BadWindow.
  if (BigInt(cap) <= 0n) throw new Error('window(): cap must be positive');
  // ringSize = K+1 so the K+1 live bucket indices never collide modulo the ring.
  return { lengthSeconds: L, cap: BigInt(cap), buckets: K, subLength: L / K, ringSize: K + 1n };
}

/**
 * Build a mandate. Only `payer`, `spender` and at least one bound are required;
 * everything else defaults to "unconstrained on that axis".
 *
 * A mandate with no bounds at all is rejected — refusing to mint an unbounded
 * authority is the entire point of the primitive.
 */
function createMandate(spec) {
  const {
    id,
    payer,
    spender,
    perTxCap = null,
    windows = [],
    totalCap = null,
    allowlist = null, // null = any recipient; array = only these
    notBefore = 0,
    expiresAt = null, // null = no expiry
    cosignThreshold = null, // amounts strictly above this need a co-signature
    cosigner = null,
    identity = null, // { agentId, expectedOwner }
    credential = null, // { validator, requestHash, minResponse, maxStaleness }
  } = spec;

  if (!id) throw new Error('createMandate(): id required');
  if (!payer) throw new Error('createMandate(): payer required');
  if (!spender) throw new Error('createMandate(): spender required');

  // The three checks above are truthiness tests, and the zero address is a truthy string.
  // Found by the mutation gate on 2026-08-29: neutering `spender required` changed no test
  // result, and probing why turned up a divergence rather than a missing test. The contract
  // refuses `p.spender == address(0)` outright with BadConfig, so this model was minting a
  // mandate the chain would reject — and minting one that reads as ordinary, since every
  // later guard treats the zero address as just another spender that never matches
  // `msg.sender`. The mandate would have been permanently unusable, not dangerous, but
  // "unusable" is exactly what the payer needed to be told at grant time.
  //
  // `payer` gets the same refusal for a different reason: on-chain the payer IS msg.sender,
  // so a zero payer is not refused anywhere in the contract because it cannot arise. A model
  // that accepts one describes a mandate with no counterpart, and every allowance and
  // transferFrom in it would be against an account that no key controls.
  if (normalizeAddr(payer) === ZERO_ADDRESS) {
    throw new Error(
      'createMandate(): payer cannot be the zero address — on-chain the payer is ' +
        'msg.sender, so this mandate has no on-chain counterpart',
    );
  }
  if (normalizeAddr(spender) === ZERO_ADDRESS) {
    throw new Error(
      'createMandate(): spender cannot be the zero address — the contract refuses this ' +
        'with BadConfig, and the mandate would be unspendable for its whole life',
    );
  }

  // Only `totalCap` and `expiresAt` bound LIFETIME exposure. A per-transaction cap alone
  // does not — the delegate spends it again, and again, until the payer's allowance is dry
  // — and neither does a window alone, which is bounded per period and unbounded over a
  // lifetime. This model and the contract both accepted perTxCap-only and window-only
  // grants until v2; both now refuse, because refusing to mint an unbounded authority is
  // the entire point of the primitive and the weaker check did not deliver it.
  //
  // The accepted cost: an open-ended arrangement (a monthly window, no end date) is no
  // longer creatable as written. Name a distant `expiresAt` instead — it costs nothing and
  // makes the horizon explicit rather than absent.
  //
  // Note there is no mirror here for the contract's companion rule refusing a nonzero
  // `expiresAt` with F_EXPIRY unset. That configuration cannot be expressed in this model
  // at all: `expiresAt: null` is the only way to say "no expiry", so the flag and the value
  // cannot disagree. The contract needs the rule because it stores them separately.
  const hasLifetimeBound = totalCap !== null || expiresAt !== null;
  if (!hasLifetimeBound) {
    throw new Error(
      'createMandate(): refusing to create a mandate with no lifetime bound — set ' +
        'totalCap or expiresAt. A perTxCap or a window bounds each spend or each ' +
        'period, not the total, so neither is sufficient on its own.',
    );
  }
  if (cosignThreshold !== null && !cosigner) {
    throw new Error('createMandate(): cosignThreshold requires a cosigner');
  }
  // The converse, which this model accepted until v2 and the contract never could, is
  // refused too. On-chain, F_COSIGN is derived from `cosigner != address(0)` and the
  // threshold is a plain uint96 whose zero is meaningful — "every spend needs a
  // signature", since the check tests `amount > threshold` strictly and amount is at
  // least 1. There is no on-chain state for "a cosigner is named but no spend requires
  // a signature", so a model that accepted one was describing a mandate that cannot
  // exist. Spell it `cosignThreshold: 0` to require a signature for every spend; that
  // is what the contract stores.
  if (cosigner && cosignThreshold === null) {
    throw new Error(
      'createMandate(): a cosigner requires a cosignThreshold — use 0 to require a ' +
        'signature for every spend, which is what the contract stores',
    );
  }
  // The agent may not be its own cosigner. `approveCosignFor` authorises on
  // `caller === mandate.cosigner` alone, so this configuration lets the spender approve
  // its own spend hash and then spend it — the gate becomes two transactions and no
  // second party. Worth refusing rather than documenting, because it is invisible in the
  // mandate object: the cosigner field is populated and the threshold looks plausible.
  // `cosigner === payer` stays legal and is the ordinary case.
  if (cosigner && normalizeAddr(cosigner) === normalizeAddr(spender)) {
    throw new Error(
      'createMandate(): the spender cannot be its own cosigner — it could approve its ' +
        'own spends, which is not a weaker control but the absence of one',
    );
  }

  // Grant-time refusals that mirror the contract's. Each of these is a configuration
  // the contract rejects outright, so a model that accepted them would be describing a
  // mandate that cannot exist on-chain — and in the minResponse case, describing one
  // that is dangerous rather than merely impossible.
  if (expiresAt !== null && BigInt(expiresAt) <= BigInt(notBefore)) {
    throw new Error('createMandate(): expiresAt must be after notBefore, or the mandate is never live');
  }
  if (credential) {
    if (!credential.validator) {
      throw new Error(
        'createMandate(): credential requires a validator — the on-chain flag is derived ' +
          'from `validator != address(0)`, so a credential gate without one cannot exist',
      );
    }
    // ERC-8004 encodes the outcome in `response`, where 100 means passed. A minResponse
    // of 0 therefore accepts every attestation INCLUDING failing ones, which inverts
    // the gate rather than loosening it. Zero is also the default value of the on-chain
    // uint8, so the contract refuses it explicitly instead of trusting the caller.
    if (credential.minResponse !== undefined && BigInt(credential.minResponse) <= 0n) {
      throw new Error(
        'createMandate(): credential minResponse must be positive — 0 accepts a FAILED ' +
          'attestation, because ERC-8004 encodes failure as a low response',
      );
    }
    // NEW IN v2. The other end of the same range. 100 is a pass under ERC-8004 and nothing
    // above it is reachable, so a higher threshold names a bar no honest attestation can clear
    // and the gate refuses every spend for the life of the mandate. The bound is `> 100` rather
    // than `!= 100` so a payer who wants a stricter partial score can still ask for one; that
    // choice can be tightened before deployment and never after, which is the note the
    // contract carries at the same check.
    if (credential.minResponse !== undefined && BigInt(credential.minResponse) > 100n) {
      throw new Error(
        'createMandate(): credential minResponse cannot exceed 100 — ERC-8004 scores a pass ' +
          'as 100, so a higher bar denies every spend rather than raising the standard',
      );
    }
    // NEW IN v2 (F34). `requestHash` is the entire lookup key: the registry is queried on it
    // alone. Zero is the default value of the on-chain bytes32 and cannot address a real
    // attestation, so a mandate carrying it is one whose credential check can only ever answer
    // CREDENTIAL_MISSING. Refused at the one moment the payer can still supply the right value.
    if (!credential.requestHash || /^0x0*$/.test(String(credential.requestHash))) {
      throw new Error(
        'createMandate(): credential requires a non-zero requestHash — it is the whole ' +
          'registry lookup key, so a zero one denies every spend',
      );
    }
  }
  // NEW IN v2 (F33). Both identity fields, refused for the same reason as the credential ones:
  // the configuration is unusable and this is the last moment it can be fixed.
  //
  // `agentId: 0` is not registrable under ERC-8004, so `ownerOf(0)` either reverts or answers
  // the zero address, and both land on IDENTITY_NOT_HELD forever.
  //
  // `expectedOwner` naming anyone other than the spender is the subtler one. The gate requires
  // the CALLER to hold the identity and `evaluate` requires the caller to be the spender, so a
  // pin at a third party contradicts a check the same function already made and refuses every
  // spend. It reads like a tightening and it is a brick, which is why it is refused rather than
  // documented. Zero still means "do not pin", and naming the spender is accepted as a no-op.
  if (identity) {
    if (identity.agentId === undefined || identity.agentId === null || BigInt(identity.agentId) === 0n) {
      throw new Error(
        'createMandate(): identity requires a non-zero agentId — agent 0 is not registrable, ' +
          'so the gate could never find an owner',
      );
    }
    if (
      identity.expectedOwner &&
      normalizeAddr(identity.expectedOwner) !== ZERO_ADDRESS &&
      normalizeAddr(identity.expectedOwner) !== normalizeAddr(spender)
    ) {
      throw new Error(
        'createMandate(): identity expectedOwner must be the spender or unset — the gate ' +
          'already requires the caller to hold the identity, so pinning anyone else refuses ' +
          'every spend for the life of the mandate',
      );
    }
  }
  if (allowlist !== null) {
    for (const a of allowlist) {
      if (!a || normalizeAddr(a) === ZERO_ADDRESS) {
        throw new Error('createMandate(): the zero address cannot be on an allowlist');
      }
    }
  }

  // Materialise the credential in its ON-CHAIN spelling, so the object this returns can
  // be encoded into the contract's CredentialGate struct with no defaults applied in
  // between. Applying them at read time instead would leave `undefined` in fields that
  // become uints, and a client encoder turning an omitted minResponse into 0 would emit
  // exactly the value createMandate refuses. Unset is 0 here, not null: that is the only
  // spelling a uint has, and the contract's semantics are written around it.
  const credentialGate =
    credential === null
      ? null
      : {
          validator: normalizeAddr(credential.validator),
          requestHash: credential.requestHash,
          agentId: credential.agentId === undefined || credential.agentId === null ? 0n : BigInt(credential.agentId),
          minResponse: credential.minResponse === undefined ? 100n : BigInt(credential.minResponse),
          maxStaleness:
            credential.maxStaleness === undefined || credential.maxStaleness === null
              ? 0n
              : BigInt(credential.maxStaleness),
        };
  for (const w of windows) {
    if (w.ringSize === undefined) {
      throw new Error('createMandate(): windows must be built with window() — got a raw object');
    }
  }
  if (windows.length > MAX_WINDOWS) {
    throw new Error(`createMandate(): at most ${MAX_WINDOWS} windows (gas bound)`);
  }

  // The co-signature requirement must be able to fire. `evaluate` demands a signature when
  // `amount > cosignThreshold`, strictly, so the requirement is dead unless the policy permits
  // at least one amount above the threshold. Compare against the largest single spend the
  // WHOLE policy allows, not against any one field:
  //
  //   effectiveMax = min(MAX_AMOUNT, perTxCap, totalCap, every window cap)
  //
  // MAX_AMOUNT is in there because it is the bound that applies when nothing else does —
  // a mandate bounded only by an expiry still caps amounts at the width of the on-chain
  // uint96, so a threshold of MAX_AMOUNT is unreachable even with no caps at all. totalCap
  // is evaluated at totalSpent = 0, which is right because reachability asks whether a
  // signature can EVER be demanded and the lifetime cap is loosest on the first spend.
  // Window caps enter as a minimum because the tightest one binds every spend.
  //
  // The obvious test, `perTxCap < cosignThreshold`, is wrong twice over: the comparison
  // is backwards, since equality is dead too (`amount > threshold` and `amount <= perTxCap`
  // cannot both hold when they are equal — confirmed on Arc Testnet, DESIGN.md:981), and
  // perTxCap is not the only ceiling, since `totalCap = 100` with `cosignThreshold = 100` and
  // no per-transaction cap is equally dead.
  if (cosignThreshold !== null) {
    let effectiveMax = MAX_AMOUNT;
    if (perTxCap !== null && BigInt(perTxCap) < effectiveMax) effectiveMax = BigInt(perTxCap);
    if (totalCap !== null && BigInt(totalCap) < effectiveMax) effectiveMax = BigInt(totalCap);
    for (const w of windows) {
      if (BigInt(w.cap) < effectiveMax) effectiveMax = BigInt(w.cap);
    }
    if (effectiveMax <= BigInt(cosignThreshold)) {
      throw new Error(
        `createMandate(): the cosign gate can never fire — the policy permits at most ` +
          `${effectiveMax} per spend and the threshold is ${cosignThreshold}, so no amount ` +
          `is strictly above it. Lower the threshold or raise a cap.`,
      );
    }
  }

  return {
    id,
    payer: normalizeAddr(payer),
    spender: normalizeAddr(spender),
    perTxCap: perTxCap === null ? null : BigInt(perTxCap),
    windows: windows.map((w) => ({ ...w })),
    totalCap: totalCap === null ? null : BigInt(totalCap),
    allowlist: allowlist === null ? null : new Set(allowlist.map(normalizeAddr)),
    notBefore: BigInt(notBefore),
    expiresAt: expiresAt === null ? null : BigInt(expiresAt),
    cosignThreshold: cosignThreshold === null ? null : BigInt(cosignThreshold),
    cosigner: cosigner ? normalizeAddr(cosigner) : null,
    identity,
    credential: credentialGate,

    // --- mutable state ---
    revoked: false,
    totalSpent: 0n,
    spendCount: 0n,
    // per window: a ring of `ringSize` (= buckets + 1) slots, each { index, amount }.
    // An untouched slot is amount === 0n. There is deliberately no "unused"
    // sentinel index: a sentinel of -1 collides with a legitimate `oldest` of -1
    // at timestamps near zero (a bug this model actually hit), and in Solidity any
    // uint256 sentinel collides with a real bucket index. Amount zero is the
    // honest emptiness test in both languages, since zero-amount spends are
    // rejected long before they could be committed.
    windowState: windows.map((w) =>
      Array.from({ length: Number(w.ringSize) }, () => ({ index: 0n, amount: 0n })),
    ),
    usedNonces: new Set(),
    // v2 (F16): a Map, not a Set. The key is still the spend hash; the value is the
    // timestamp the approval dies AT, exclusive. Absent from the Map is the model's
    // equivalent of the contract's stored zero.
    cosignApprovals: new Map(),
    // v2 (F30): nonce => the spend hash that nonce is held for; absence from the Map means
    // the nonce is free. Written by `approveCosignFor`, cleared by `commit` and by
    // `withdrawCosign`. Keyed on the nonce rather than on the hash because the question being
    // asked is "what is this nonce spoken for", and a hash cannot be turned back into the
    // nonce inside it.
    //
    // F39: an entry here carries no deadline of its own, so both readers pair it with
    // `cosignIsLive` against `cosignApprovals`. An entry whose approval has lapsed is inert
    // rather than binding, which is what stops it outliving the decision it records.
    cosignReservedNonces: new Map(),
  };
}

function normalizeAddr(a) {
  return String(a).toLowerCase();
}

/**
 * The deployment addresses that can receive USDC and can never send it on.
 *
 * F38 widened F29's original pair to four. The contract has no token-moving function other
 * than the `transferFrom` in `spend`, which always pays a third party; Circle's token holds no
 * recovery path for a balance credited to itself; and both ERC-8004 registries are contracts
 * this one only reads, whose interfaces carry no transfer of any kind. All four are permanent
 * properties of deployed code, so none of them can stop holding.
 *
 * Factored for the same reason the contract factored `_isUndebitable`: the spend path and the
 * approval path both ask this question, and F29 wrote the answer out by hand in three
 * places, which is how the registries came to be missing from all three.
 *
 * `filter(Boolean)` keeps a caller that supplies only some of the four honest rather than
 * broken — the model cannot learn a deployment's addresses on its own. Anything comparing this
 * model against a live deployment has to pass all four in `ctx` or it is comparing a weaker
 * rule than the contract enforces.
 */
function undebitableAddrs(ctx) {
  return [ctx.manager, ctx.token, ctx.identityRegistry, ctx.validationRegistry]
    .filter(Boolean)
    .map(normalizeAddr);
}

/**
 * Whether a stored co-sign approval is still live at `now`.
 *
 * F39. The boundary is the one `evaluate` enforces on the same Map: live while `now` is below
 * the deadline, exclusive, because Arc's sub-second blocks can share a timestamp and an
 * inclusive bound would leave an ambiguous final second.
 *
 * Factored so the two reservation checks that consult it — one on the spend path, one on the
 * approval path — cannot answer this question differently from the deadline test a few lines
 * below the first of them. It takes `now` as an argument rather than reading `ctx`, so a caller
 * cannot compare against a different instant than the one it judged the mandate against.
 */
function cosignIsLive(mandate, hash, now) {
  const validUntil = mandate.cosignApprovals.get(hash);
  return validUntil !== undefined && now < BigInt(validUntil);
}

/**
 * Usage within the trailing window, from the bucket ring.
 *
 * The trailing window ending at `now` is covered by sub-bucket indices
 * [b - K, b] where b = now / subLength — K+1 buckets, see window() for why the
 * +1 is required for soundness. Any slot holding an index at or after `oldest`
 * is counted in full; anything older is stale and ignored.
 *
 * NOTE ON THE MISSING UPPER BOUND
 * There is deliberately no `index <= b` filter. Arc documents timestamps as
 * non-decreasing, so a slot newer than b should be unreachable — but if it ever
 * happened, excluding it would make already-recorded spending invisible and hand
 * back headroom that was legitimately consumed. Counting it instead is the
 * conservative reading and costs nothing, so the cap does not depend on the
 * monotonicity promise holding.
 */
function windowUsage(win, ringState, now) {
  const b = BigInt(now) / win.subLength;
  const oldest = b - win.buckets;
  let effective = 0n;
  for (const slot of ringState) {
    if (slot.index >= oldest) effective += slot.amount;
  }
  return { bucket: b, oldest, effective };
}

/** Maps a sub-bucket index to its ring slot. The ring holds K+1 slots. */
function ringSlot(win, bucketIndex) {
  return Number(((bucketIndex % win.ringSize) + win.ringSize) % win.ringSize);
}

/**
 * Compute the spend hash used for co-signature approval and idempotency.
 * Binds every economically meaningful field, so an approval cannot be replayed
 * against a different recipient, amount, reference, or nonce.
 *
 * v2 (F15): takes the MANDATE rather than a free `spender`, mirroring the contract's
 * `spendHash` after its `spender_` parameter was retired. A caller could previously ask for
 * the hash of a spend by an address that is not the mandate's spender — a hash no spend can
 * ever match, and one a cosigner could nonetheless be handed and asked to approve.
 */
function spendHash({ mandate, recipient, amount, ref, nonce }) {
  return [
    'Remit:v1',
    mandate.id,
    normalizeAddr(mandate.spender),
    normalizeAddr(recipient),
    BigInt(amount).toString(),
    ref ?? '',
    nonce,
  ].join('|');
}

/**
 * Evaluate a spend request WITHOUT mutating the mandate.
 *
 * Returns { allowed: true, hash, effects } or { allowed: false, reason, detail }.
 * `effects` describes exactly what commit() would write, so tests can assert on
 * state transitions independently of whether they were applied.
 *
 * `ctx` supplies the environment:
 *   now                  — block timestamp (seconds)
 *   resolveIdentityOwner — (agentId) => address, mirrors ERC-8004 ownerOf(agentId)
 *   resolveCredential    — (validator, requestHash) => { response, lastUpdate } | null
 */
function evaluate(mandate, request, ctx) {
  const now = BigInt(ctx.now);
  const { spender, recipient, amount: rawAmount, ref = '', nonce } = request;
  const amount = BigInt(rawAmount);

  const deny = (reason, detail) => ({ allowed: false, reason, detail });

  if (!mandate) return deny(Denial.UNKNOWN_MANDATE);
  if (mandate.revoked) return deny(Denial.REVOKED);

  // --- validity period ---
  if (now < mandate.notBefore) {
    return deny(Denial.NOT_YET_VALID, { now, notBefore: mandate.notBefore });
  }
  // expiresAt is EXCLUSIVE: a mandate expiring at T is dead AT T. That is deliberate,
  // since with sub-second blocks sharing a timestamp an inclusive bound would leave an
  // ambiguous final second in which liveness depends on which block within that second
  // included the transaction.
  if (mandate.expiresAt !== null && now >= mandate.expiresAt) {
    return deny(Denial.EXPIRED, { now, expiresAt: mandate.expiresAt });
  }

  // --- authorisation ---
  if (normalizeAddr(spender) !== mandate.spender) {
    return deny(Denial.WRONG_SPENDER, { expected: mandate.spender, got: spender });
  }

  // --- recipient shape and policy ---
  if (!recipient || normalizeAddr(recipient) === ZERO_ADDRESS) {
    // Arc forbids value transfers to the zero address outright. Reject early
    // rather than burning the sender's gas on a guaranteed runtime revert.
    return deny(Denial.ZERO_RECIPIENT);
  }
  // F19, placed ahead of the allowlist deliberately: shape before policy. A self-payment is
  // never a payment regardless of who is allowlisted, and answering RECIPIENT_NOT_ALLOWED
  // would send the reader to edit a config when the request itself is the mistake.
  if (normalizeAddr(recipient) === mandate.payer) {
    return deny(Denial.SELF_PAYMENT, { payer: mandate.payer });
  }
  // F29, and ahead of the allowlist for F19's reason: the request is the mistake, not the
  // config. `undebitableAddrs` holds the destinations from which the money cannot be moved on
  // again — the contract's own address, USDC's, and both ERC-8004 registries after F38 widened
  // the list from the first two.
  //
  // A caller that names none of them cannot have this checked, because the model has no other
  // way to learn a deployment's addresses — a limitation of the model rather than of the
  // contract, which always knows all four. Anything comparing this model against a live
  // deployment has to supply them or it is comparing a weaker rule.
  if (undebitableAddrs(ctx).includes(normalizeAddr(recipient))) {
    return deny(Denial.UNRECOVERABLE_RECIPIENT, { recipient });
  }
  if (mandate.allowlist !== null && !mandate.allowlist.has(normalizeAddr(recipient))) {
    return deny(Denial.RECIPIENT_NOT_ALLOWED, { recipient });
  }

  if (amount <= 0n) return deny(Denial.ZERO_AMOUNT);

  // Refused before any cap, so the caller learns the amount is unrepresentable rather
  // than being told to try a smaller one — different problem, different fix. See
  // MAX_AMOUNT for why a model with unbounded integers carries this check at all.
  if (amount > MAX_AMOUNT) return deny(Denial.AMOUNT_TOO_LARGE, { amount, max: MAX_AMOUNT });

  // --- replay / idempotency ---
  // The nonce makes a spend idempotent: resubmitting the same nonce is refused
  // rather than paying twice. This is what makes a retrying caller safe, and it
  // matters more on Arc than elsewhere because finality at one confirmation
  // encourages aggressive retry logic in offchain workers.
  if (nonce === undefined || nonce === null || nonce === '') {
    throw new Error('evaluate(): nonce is required');
  }
  if (mandate.usedNonces.has(nonce)) {
    return deny(Denial.NONCE_ALREADY_USED, { nonce });
  }

  // --- identity gate (optional, ERC-8004) ---
  // ownerOf(agentId) is the only on-chain identity lookup Arc documents, and the
  // identity is a TRANSFERABLE ERC-721. Holding the token now is necessary but not
  // sufficient: the mandate also pins the owner the payer intended at grant time, or a
  // token transfer would move spending authority to a stranger without any denial.
  //
  // NOTE FOR THE CONTRACT: ownerOf is ERC-721, so it REVERTS for a nonexistent or
  // burned tokenId rather than returning address(0). MandateManager must therefore
  // use a low-level staticcall / try-catch and treat failure as IDENTITY_NOT_HELD,
  // otherwise a burned agent identity produces an opaque revert instead of a
  // legible denial. `resolveIdentityOwner` returning null models that failure.
  if (mandate.identity) {
    const owner = ctx.resolveIdentityOwner?.(mandate.identity.agentId) ?? null;
    if (!owner || normalizeAddr(owner) !== normalizeAddr(spender)) {
      return deny(Denial.IDENTITY_NOT_HELD, { agentId: mandate.identity.agentId, owner });
    }
    // FIXED IN v2 (F28). This used to test `mandate.identity.expectedOwner` for bare
    // truthiness, and the zero address as a STRING is truthy in JavaScript — so the one
    // spelling the contract documents as "do not pin" (MandateManager.sol reads
    // `g.expectedOwner != address(0)`) made the model deny every spend on a mandate the chain
    // would honour. Wrong in the safe direction for the money and the unsafe direction for the
    // payer, who is told their mandate is bricked while it works.
    //
    // Now compared against ZERO_ADDRESS explicitly, like the four other places in this file
    // that handle the same zero-means-unset hazard. `createMandate` also refuses a pin at
    // anyone but the spender, so the surviving branch is the redundant one — see the note at
    // Denial.IDENTITY_TRANSFERRED's contract twin about why it is kept rather than deleted.
    const pin = mandate.identity.expectedOwner
      ? normalizeAddr(mandate.identity.expectedOwner)
      : ZERO_ADDRESS;
    if (pin !== ZERO_ADDRESS && normalizeAddr(owner) !== pin) {
      return deny(Denial.IDENTITY_TRANSFERRED, {
        expected: mandate.identity.expectedOwner,
        got: owner,
      });
    }
  }

  // --- credential check (optional, ERC-8004 ValidationRegistry) ---
  // getValidationStatus is the one credential check Arc exposes on-chain.
  // Reputation is write-only in the documented ABI, so it is deliberately unused.
  //
  // THE TUPLE MUST BE CHECKED, NOT JUST THE RESPONSE
  // getValidationStatus(bytes32 requestHash) is keyed ONLY by requestHash and
  // returns (validatorAddress, agentId, response, responseHash, tag, lastUpdate).
  // Reading `response` alone makes the check theater: anyone can pick a requestHash and
  // have some cooperative validator answer it, or reuse an attestation issued about a
  // different agent. The validator that answered and the agent it answered about are
  // therefore both verified against what the payer named at grant time.
  if (mandate.credential) {
    const {
      validator,
      requestHash,
      minResponse = 100n, // ERC-8004: 100 == passed
      maxStaleness = null,
      agentId = null,
    } = mandate.credential;

    const att = ctx.resolveCredential?.(requestHash) ?? null;
    if (!att) return deny(Denial.CREDENTIAL_MISSING, { requestHash, got: null });

    if (normalizeAddr(att.validator ?? ZERO_ADDRESS) !== normalizeAddr(validator)) {
      return deny(Denial.CREDENTIAL_WRONG_VALIDATOR, {
        expected: validator,
        got: att.validator ?? null,
      });
    }

    // Bind the attestation to the agent. Prefer an explicit credential.agentId,
    // otherwise fall back to the identity the mandate is already bound to.
    //
    // Zero and null are treated identically as "not set", which matters because the
    // contract has no null: `c.agentId != 0 ? c.agentId : _identity[...].agentId` makes
    // an explicit zero fall through to the identity gate. Using `??` here instead would
    // have made `agentId: 0n` mean "require the attestation to be about agent 0", which
    // the contract can never express, for the same reason recorded at maxStaleness below.
    //
    // If BOTH are unset the check is SKIPPED, not failed, and the gate degrades to
    // "the named validator filed a passing, fresh attestation under this exact
    // requestHash" with nothing tying it to this spender. That is a documented gap, not
    // an oversight — see DESIGN.md, "The credential check had to be built twice". It is
    // bounded by requestHash being payer-fixed at grant time, so a spender cannot
    // redirect the lookup at an attestation of their own choosing.
    const explicitAgent = agentId === null || BigInt(agentId) === 0n ? null : BigInt(agentId);
    const inheritedAgent =
      mandate.identity?.agentId === undefined || mandate.identity?.agentId === null
        ? null
        : BigInt(mandate.identity.agentId);
    const expectedAgent = explicitAgent ?? (inheritedAgent === 0n ? null : inheritedAgent);
    if (expectedAgent !== null && BigInt(att.agentId) !== expectedAgent) {
      return deny(Denial.CREDENTIAL_WRONG_AGENT, {
        expected: expectedAgent,
        got: BigInt(att.agentId),
      });
    }

    if (BigInt(att.response) < BigInt(minResponse)) {
      return deny(Denial.CREDENTIAL_MISSING, { requestHash, got: BigInt(att.response) });
    }
    // Freshness. maxStaleness of null OR 0 means "no freshness requirement" — the
    // on-chain field is a uint40 with no null, so 0 is the unset value and it must
    // select the permissive branch, otherwise a payer who omits the field gets a
    // mandate that can never spend. Documented in the README as a known footgun.
    //
    // FIXED IN v2 (F31), and this model had the bug first. The old condition was
    // `now > lastUpdate && now - lastUpdate > staleAfter`, where the first conjunct existed
    // to stop the on-chain unsigned subtraction underflowing. It did that, and it also
    // skipped the freshness test entirely whenever `lastUpdate` was ahead of the clock — so
    // `maxStaleness` bound every attestation except the one class that cannot be honest about
    // its own age. One future-dated stamp bought a credential that never went stale.
    //
    // A registry with a fast clock produces that by accident, so it is not a story about a
    // malicious validator. An attestation dated in the future has an age that cannot be
    // computed, and refusing it is the only answer that does not amount to trusting it.
    const staleAfter = maxStaleness === null ? 0n : BigInt(maxStaleness);
    if (
      staleAfter > 0n &&
      (BigInt(att.lastUpdate) > now || now - BigInt(att.lastUpdate) > staleAfter)
    ) {
      return deny(Denial.CREDENTIAL_STALE, {
        age: BigInt(att.lastUpdate) > now ? null : now - BigInt(att.lastUpdate),
        lastUpdate: BigInt(att.lastUpdate),
        now,
        maxStaleness: staleAfter,
      });
    }
  }

  // --- amount bounds ---
  if (mandate.perTxCap !== null && amount > mandate.perTxCap) {
    return deny(Denial.OVER_PER_TX_CAP, { amount, cap: mandate.perTxCap });
  }
  if (mandate.totalCap !== null && mandate.totalSpent + amount > mandate.totalCap) {
    return deny(Denial.OVER_TOTAL_CAP, {
      amount,
      spent: mandate.totalSpent,
      cap: mandate.totalCap,
    });
  }
  // The contract's audit counter is a uint96 and a BigInt has no such width, so the
  // model has to carry the bound or it is more permissive than the thing it specifies
  // — the same reasoning as MAX_AMOUNT above, applied to the CUMULATIVE total rather
  // than to one amount. Reachable only when totalCap is null, because a lifetime cap
  // is itself a uint96 and so binds in the check above. v1 of the contract had no
  // equivalent: it panicked on the overflow instead of denying, and this model could
  // not express a panic, which is how the divergence stayed invisible.
  if (mandate.totalSpent + amount > MAX_AMOUNT) {
    return deny(Denial.TOTAL_SPENT_CEILING, {
      amount,
      spent: mandate.totalSpent,
      max: MAX_AMOUNT,
    });
  }
  // The counter ceiling, in the position the contract checks it and for the same reason the
  // one above is here. This is the divergence the note above describes, one counter over: v1
  // panicked here too, so both ceilings were invisible to a model that could not express a
  // panic, and only one of them was named when v2 fixed it.
  //
  // The comparison is `>=` where the contract writes `==`, and the two agree on every state
  // the contract can hold, because a uint32 cannot exceed its own maximum. The extra reach is
  // for the state only this model can reach: `applyEvent` copies `spendCount` from an event,
  // and a value above the ceiling should deny rather than slip through an equality test.
  if (mandate.spendCount >= MAX_SPEND_COUNT) {
    return deny(Denial.SPEND_COUNT_CEILING, {
      spendCount: mandate.spendCount,
      max: MAX_SPEND_COUNT,
    });
  }

  // --- rolling windows ---
  const windowEffects = [];
  for (let i = 0; i < mandate.windows.length; i++) {
    const win = mandate.windows[i];
    const usage = windowUsage(win, mandate.windowState[i], now);
    if (usage.effective + amount > win.cap) {
      return deny(Denial.OVER_WINDOW_CAP, {
        windowSeconds: win.lengthSeconds,
        cap: win.cap,
        effective: usage.effective,
        amount,
        headroom: win.cap > usage.effective ? win.cap - usage.effective : 0n,
      });
    }
    windowEffects.push({ windowIndex: i, bucket: usage.bucket, oldest: usage.oldest, add: amount });
  }

  // --- co-signature for large amounts ---
  // Checked last so a request failing a cheaper check reports that instead of
  // misleadingly demanding a co-signature.
  //
  // v2 (F15): the hash is derived from `mandate.spender`, not from `request.spender`. The
  // two are provably equal here because WRONG_SPENDER above already refused every other
  // case, so this is not a behaviour change in `evaluate` — it is what lets `spendHash` be
  // reachable ONLY with the mandate's own spender, closing the path where a cosigner is
  // handed the hash of a spend that cannot be performed.
  const hash = spendHash({ mandate, recipient, amount, ref, nonce });
  // F30, and OUTSIDE the cosign branch on purpose. A nonce held for a live approval is held
  // against every spend, not only against spends large enough to need a signature — the whole
  // attack was a spend too small to enter the branch below, consuming the nonce and stranding
  // the approval on a hash no spend could reach again. Checking inside the branch would leave
  // the hole exactly where it was.
  //
  // The reservation is satisfied by the request that owns it, so the comparison is against
  // this request's hash rather than merely against presence.
  //
  // F39: and only a LIVE approval is a decision worth protecting. The approvals Map carries a
  // deadline and this one does not, so a reservation could outlive the approval that created
  // it and then refuse every spend on that nonce for good — including the sub-threshold spends
  // this check deliberately covers, which the lapsed signature has no authority over. A dead
  // reservation is now ignored here and `commit` clears it as it clears any other, so the
  // payment continues. The live case is untouched and F30 holds exactly as written.
  const reservedHash = mandate.cosignReservedNonces.get(nonce);
  if (reservedHash !== undefined && reservedHash !== hash && cosignIsLive(mandate, reservedHash, now)) {
    return deny(Denial.NONCE_RESERVED, { nonce, reservedHash });
  }
  if (mandate.cosignThreshold !== null && amount > mandate.cosignThreshold) {
    // v2 (F16): a Map keyed by hash whose value is the deadline. Absent and expired are
    // distinct denials — see the note on Denial.COSIGN_EXPIRED.
    const validUntil = mandate.cosignApprovals.get(hash);
    if (validUntil === undefined) {
      return deny(Denial.COSIGN_REQUIRED, { amount, threshold: mandate.cosignThreshold, hash });
    }
    // `>=` because validUntil is EXCLUSIVE, matching expiresAt above and the contract.
    if (now >= validUntil) {
      return deny(Denial.COSIGN_EXPIRED, { amount, hash, now, validUntil });
    }
  }

  return {
    allowed: true,
    hash,
    effects: {
      totalSpent: mandate.totalSpent + amount,
      spendCount: mandate.spendCount + 1n,
      windows: windowEffects,
      nonce,
      consumesCosign: mandate.cosignThreshold !== null && amount > mandate.cosignThreshold,
    },
  };
}

/** Apply a previously-evaluated allowed decision, throwing if handed a denial. */
function commit(mandate, decision) {
  if (!decision.allowed) {
    throw new Error(`commit(): refusing to apply a denied decision (${decision.reason})`);
  }
  const e = decision.effects;
  mandate.totalSpent = e.totalSpent;
  mandate.spendCount = e.spendCount;

  for (const eff of e.windows) {
    const win = mandate.windows[eff.windowIndex];
    const ring = mandate.windowState[eff.windowIndex];
    const slot = ring[ringSlot(win, eff.bucket)];

    if (slot.amount === 0n) {
      // Empty slot: nothing to lose, claim it.
      slot.index = eff.bucket;
      slot.amount = eff.add;
    } else if (slot.index === eff.bucket) {
      slot.amount += eff.add;
    } else if (slot.index < eff.oldest) {
      // Slot holds a sub-bucket that has aged out of the window: recycle it.
      slot.index = eff.bucket;
      slot.amount = eff.add;
    } else {
      // Live collision. Unreachable while timestamps are non-decreasing: the K+1
      // live indices each map to a distinct ring slot, so a differing live index
      // can only be NEWER than eff.bucket, which needs the clock to have gone
      // backwards. Accumulate into the newer index rather than overwriting it —
      // overwriting would discard already-counted spending, while keeping the
      // newer index only makes this amount expire later than strictly necessary.
      slot.amount += eff.add;
    }
  }

  mandate.usedNonces.add(e.nonce);
  // F30. Unconditional, and the nonce is now spent, so the reservation has nothing left to
  // protect. Deleting a key that was never set is a no-op here; the contract guards the same
  // delete with a zero test only to avoid paying for a pointless storage write.
  mandate.cosignReservedNonces.delete(e.nonce);
  if (e.consumesCosign) {
    // A co-signature authorises exactly one spend.
    mandate.cosignApprovals.delete(decision.hash);
  }
  return mandate;
}

/** Convenience: evaluate, then commit when the decision allows it, returning it either way. */
function spend(mandate, request, ctx) {
  const decision = evaluate(mandate, request, ctx);
  if (decision.allowed) commit(mandate, decision);
  return decision;
}

/**
 * Revoke. The payer or the spender may revoke; revocation is immediate and permanent.
 *
 * The spender is included on purpose. An agent that has finished its work, or that
 * detects it has been compromised, should be able to surrender its own authority
 * without waiting for a human to act — and it cannot hurt the payer, because the only
 * power revocation removes is the agent's own. No third party may call it.
 *
 * On Arc this is stronger than on a probabilistic-finality chain: finality is
 * deterministic at one confirmation (arc/concepts/deterministic-finality.mdx),
 * so there is no reorg window in which a revoked mandate is still live and
 * spendable. On Ethereum a revocation is only economically final after minutes, which
 * is a real gap when the counterparty is an automated agent.
 *
 * NOTE FOR THE CONTRACT: v1 reverted with `NotPayer()` here even though the spender is
 * also permitted, and four places in the repo recorded that the name was misleading
 * while keeping it, because it was already in a deployed ABI. v2 renamed it to
 * `NotAuthorised()` — v1's ABI is pinned at v1's address by the tag v1.0.0-arc-testnet,
 * so a new deployment is free to be accurate. Two roles hold the authority; naming the
 * error after one of them was the defect.
 */
function revoke(mandate, caller) {
  const who = normalizeAddr(caller);
  if (who !== mandate.payer && who !== mandate.spender) {
    throw new Error('revoke(): only the payer or the spender may revoke');
  }
  mandate.revoked = true;
  return mandate;
}

/**
 * Pre-approve exactly one spend that exceeds the co-sign threshold. Cosigner only.
 *
 * RENAMED AND RESHAPED IN v2 (F15 + F16), mirroring the contract, where the opaque
 * two-argument `approveCosign(mandateId, hash)` was DELETED rather than kept alongside this
 * one. The reasoning is in MandateManager.sol's docstring and is restated here because a
 * reader will otherwise try to "restore" the deleted form: whoever asks for the signature
 * chooses the entry point, and that party is usually the agent, so a legibility control the
 * adversary can opt out of on the victim's behalf is not a control.
 *
 * Two changes beyond the name:
 *
 *   1. There is no `request.spender ?? mandate.spender` escape any more. The old form let a
 *      caller approve the hash of a spend by an address that is not the mandate's spender —
 *      a hash `evaluate` can never produce, so the approval was unspendable, and the
 *      cosigner had no way to notice from the arguments they were shown. `spendHash` now
 *      reads the spender off the mandate and there is nowhere to put a different one.
 *
 *   2. `validUntil` is required, and bounded. Zero still means "no approval" in the Map, so
 *      a deadline in the past or at `now` is refused rather than stored as a live-forever
 *      approval; `MAX_COSIGN_TTL` caps how far ahead it may sit, because an uncapped
 *      deadline leaves F16 advisory — the agent that builds the transaction would simply
 *      pre-fill the maximum.
 *
 * NEW IN v2 (F17): an approval that no spend could ever consume is refused rather than stored.
 * The conditions were derived from `evaluate` rather than from the list of four this comment
 * used to promise, because that list was wrong by omission — it missed a consumed nonce, both
 * permanent caps, the uint96 ceiling and the allowlist. Deriving found twelve conditions where
 * prose had found four, which is the argument for deriving.
 *
 * THE HARDER HALF WAS DECIDING WHAT NOT TO REFUSE. Three conditions that `evaluate` denies are
 * RECOVERABLE, and mirroring them here would be a mistake in the one direction that actually
 * hurts: an approval refused for a condition that later clears makes a legitimate large payment
 * unapprovable until the cosigner is chased a second time, which for a payments primitive is a
 * liveness failure of our own making. They are:
 *
 *   - `notBefore` in the future, which passes once the clock reaches it. Approving ahead of a
 *     start date is the ordinary case for a scheduled payment, not an error.
 *   - A full rolling window. The sharpest of the three, because the window arithmetic is the
 *     most tempting to mirror and the least safe to: `windowUsage` FALLS as buckets age out, so
 *     an amount refused now fits later with nothing else changed.
 *   - The ERC-8004 identity and credential checks, which a third party the cosigner does not
 *     control can restore. There is a second, structural reason visible only in this model:
 *     mirroring them would force `approveCosignFor` to take `ctx.resolveIdentityOwner` and
 *     `ctx.resolveCredential`, i.e. to consult live registry state before agreeing to store an
 *     approval. The contract's shape says the same thing in gas — two external staticcalls on
 *     the approval path.
 *
 * WHAT THE MIRRORED ORDER BUYS, stated exactly, because the obvious version of the claim is
 * false. It is NOT "these two functions always agree on which refusal to raise": they cannot,
 * since the recoverable conditions this one skips sit BETWEEN the permanent ones it keeps, so a
 * request that is both over `perTxCap` and behind a missing credential gets CREDENTIAL_MISSING
 * from `evaluate` and OVER_PER_TX_CAP from here. The true claim is narrower: FOR A REQUEST WHOSE
 * ONLY DEFECT IS ONE OF THE MIRRORED PERMANENT CONDITIONS, BOTH FUNCTIONS RAISE THE SAME CODE.
 * One defect at a time, which is also the only case a cosigner could act on. The nonce check
 * sitting ahead of the caps is part of that and is not free to move.
 *
 * AND WHAT IT DOES NOT BUY. F17 stops dead approvals being CREATED. It cannot collect the ones
 * already in the Map, and it cannot notice a live approval that goes dead afterwards — the
 * mandate is revoked, or the nonce is consumed by some other spend. `evaluate` remains the only
 * thing that decides whether an approval is honoured, and that is the correct division: this
 * function refuses what is provably useless at approval time, and nothing more.
 *
 * @param {object} mandate  the mandate, mutated on success
 * @param {string} caller   must be the cosigner
 * @param {object} request  { recipient, amount, ref, nonce, validUntil }
 * @param {object} ctx      { now, manager, token, identityRegistry, validationRegistry } — `now`
 * is required, because the deadline is checked against it. The four addresses are optional and
 * feed F38's unrecoverable-recipient mirror; omitting any of them makes this function accept an
 * approval the contract would refuse.
 * @returns {string} the spend hash that was approved
 */
function approveCosignFor(mandate, caller, request, ctx) {
  // Refusals carry a `code` so a test can compare them against `evaluate`'s denial reasons.
  // `ctx.now` is the one throw below with no code, and deliberately: it is a harness mistake,
  // not a policy outcome, and the contract has no analogue because `block.timestamp` cannot be
  // forgotten. Everything else the contract can revert with, this can name.
  const refuse = (code, message) => {
    const err = new Error(`approveCosignFor(): ${message}`);
    err.code = code;
    return err;
  };

  // Reuses `evaluate`'s code rather than getting its own, and unlike `ctx.now` this one is a
  // real policy outcome: the contract reverts `UnknownMandate()` here, in this position, as its
  // first check, because a typo'd id gives an empty struct whose cosigner is the zero address —
  // and answering `NotCosigner` to that is true and useless. Carrying the code was missed on
  // the first pass; a mutation run over this function caught it, because the guard beneath it
  // refuses the same input for the wrong reason and so hid the omission.
  if (!mandate) throw refuse(Denial.UNKNOWN_MANDATE, 'unknown mandate');
  // Configuration before authorisation, matching the contract's `F_COSIGN == 0` check ahead of
  // its `msg.sender != m.cosigner`. The order carries the whole answer: on a mandate with no
  // cosign requirement, NOT_COSIGNER would be technically true, since no caller matches a null
  // cosigner, and it would send the reader looking for a key that does not exist when the truth
  // is that this mandate requires no signature from anyone.
  if (!mandate.cosigner) {
    throw refuse(ApprovalRefusal.BAD_CONFIG, 'mandate has no cosigner');
  }
  if (normalizeAddr(caller) !== mandate.cosigner) {
    throw refuse(ApprovalRefusal.NOT_COSIGNER, 'only the cosigner may approve');
  }
  if (!ctx || ctx.now === undefined) {
    throw new Error('approveCosignFor(): ctx.now is required to bound the deadline');
  }

  const now = BigInt(ctx.now);
  const validUntil = BigInt(request.validUntil ?? 0);
  if (validUntil <= now || validUntil > now + MAX_COSIGN_TTL) {
    throw refuse(
      ApprovalRefusal.BAD_DEADLINE,
      `validUntil ${validUntil} must be strictly after ${now} and no later than ` +
        `${now + MAX_COSIGN_TTL} (now + MAX_COSIGN_TTL)`,
    );
  }

  // ---- F17: this must name a spend `evaluate` could accept ---------------------------------
  // Order mirrors `evaluate` so identical arguments produce the identical code. Only PERMANENT
  // refusals appear; the three recoverable ones and why they are absent are in the notes above.

  // Liveness first, and ahead of the two mandate-relative deadline bounds added below on
  // purpose: for a mandate that has already expired, any legal `validUntil` is necessarily past
  // `expiresAt` too, so checking the deadline first would answer "your deadline is wrong" when
  // the truth is "this mandate is dead". Sending the reader to fix the wrong thing is worse than
  // not refusing at all.
  //
  // `revoked` is one-way — `revoke` only ever sets it true — so this can never stop holding.
  // Same for `expiresAt`, which is fixed at creation and only recedes further into the past.
  // Exclusive bound, matching `evaluate`.
  if (mandate.revoked) throw refuse(Denial.REVOKED, 'the mandate is revoked');
  if (mandate.expiresAt !== null && now >= mandate.expiresAt) {
    throw refuse(Denial.EXPIRED, `the mandate expired at ${mandate.expiresAt}`);
  }

  const recipient = request.recipient;
  if (!recipient || normalizeAddr(recipient) === ZERO_ADDRESS) {
    throw refuse(Denial.ZERO_RECIPIENT, 'the recipient is the zero address');
  }
  // F19's mirror, and it belongs to F17's rule rather than being bolted onto it: `payer` is set
  // once at creation, so a self-payment is refused by `evaluate` now and forever. Same position
  // relative to the allowlist as on the spend path, which the parity note below depends on.
  if (normalizeAddr(recipient) === mandate.payer) {
    throw refuse(Denial.SELF_PAYMENT, 'the recipient is the payer, so no spend can ever consume this');
  }
  // F29's mirror, in the same position relative to the allowlist as on the spend path. It
  // belongs to F17's rule as squarely as F19 does: none of these addresses can stop being
  // unrecoverable, so an approval naming one is authority over a payment `evaluate` will refuse
  // forever. F38 took the list from two addresses to four here as well.
  if (undebitableAddrs(ctx).includes(normalizeAddr(recipient))) {
    throw refuse(
      Denial.UNRECOVERABLE_RECIPIENT,
      `${recipient} has no path to send the funds on, so no spend can ever consume this`,
    );
  }
  // The allowlist is fixed at creation in the contract and has no mutator, so absence is
  // permanent. F20 asks whether a payer-only REMOVE-only mutator should exist; it would not
  // weaken this, since removal shrinks the set and a recipient absent today can never become
  // present.
  if (mandate.allowlist !== null && !mandate.allowlist.has(normalizeAddr(recipient))) {
    throw refuse(Denial.RECIPIENT_NOT_ALLOWED, `${recipient} is not on the allowlist`);
  }

  const amount = BigInt(request.amount ?? 0);
  if (amount <= 0n) throw refuse(Denial.ZERO_AMOUNT, 'the amount is zero');
  if (amount > MAX_AMOUNT) {
    throw refuse(Denial.AMOUNT_TOO_LARGE, `the amount ${amount} exceeds ${MAX_AMOUNT}`);
  }

  // A consumed nonce is consumed for good, so this approval could only ever meet
  // NONCE_ALREADY_USED. Checked HERE, ahead of the caps, because that is where `evaluate` checks
  // it — the position is not arbitrary, and moving it would break the parity claimed above
  // without anything reporting the break. This is also the condition a cosigner is least placed
  // to notice: the agent supplies the nonce, and an agent that supplies a spent one is asking
  // for a signature on a payment that cannot happen.
  if (request.nonce === undefined || request.nonce === null || request.nonce === '') {
    throw new Error('approveCosignFor(): nonce is required');
  }
  if (mandate.usedNonces.has(request.nonce)) {
    throw refuse(Denial.NONCE_ALREADY_USED, `nonce ${request.nonce} is already used`);
  }

  // `perTxCap` is fixed at creation. `totalSpent` only ever grows, so headroom only ever
  // shrinks and a shortfall now is a shortfall forever — which is exactly what makes these two
  // safe to refuse and the rolling windows unsafe.
  if (mandate.perTxCap !== null && amount > mandate.perTxCap) {
    throw refuse(Denial.OVER_PER_TX_CAP, `${amount} exceeds the per-transaction cap`);
  }
  if (mandate.totalCap !== null && mandate.totalSpent + amount > mandate.totalCap) {
    throw refuse(Denial.OVER_TOTAL_CAP, `${amount} exceeds the remaining lifetime cap`);
  }
  if (mandate.totalSpent + amount > MAX_AMOUNT) {
    throw refuse(Denial.TOTAL_SPENT_CEILING, 'the lifetime total would exceed 2^96 - 1');
  }
  // The strongest bound in this block, and the only one that ignores `amount`. A mandate at the
  // counter ceiling cannot consume a spend of any size ever again, so an approval written
  // against it is unconsumable for its whole life rather than unconsumable at this amount.
  if (mandate.spendCount >= MAX_SPEND_COUNT) {
    throw refuse(Denial.SPEND_COUNT_CEILING, 'the spend counter is at 2^32 - 1');
  }

  // F40, and it sits where `evaluate` checks the windows so the two orders stay identical. The
  // note further up this block excluded the rolling windows as recoverable, which is true of
  // `used + amount > cap` and false of `amount > cap` on its own: usage only ever falls back
  // toward zero, and `cap` is fixed at creation, so an amount above a window's cap is refused
  // for the life of the mandate. Only that term is mirrored. An amount that fits the cap but
  // not today's remaining headroom stays approvable, because buckets age out.
  //
  // `effective` is reported as 0 rather than measured, since the refusal does not depend on
  // current usage — the same value the contract puts in `OverWindowCap`'s third field here.
  for (const win of mandate.windows) {
    if (amount > win.cap) {
      throw refuse(
        Denial.OVER_WINDOW_CAP,
        `${amount} exceeds the ${win.lengthSeconds}s window cap of ${win.cap}, which never ` +
          `rises, so no spend can ever consume this`,
      );
    }
  }

  // ---- F17: and it must name a spend that NEEDS a co-signature ------------------------------
  // The only refusal here that is not about consumability. `evaluate` consults the approval Map
  // solely when `amount > cosignThreshold`, so at or below the threshold this approval would sit
  // in the Map, cost the cosigner a transaction, and never be read — the payment goes through
  // with or without it. Refused because of what it would let the cosigner believe: that they had
  // imposed a requirement where none exists. The comparison is inclusive, because the threshold
  // itself needs no signature.
  //
  // Note this is guarded on `cosignThreshold !== null` for form only. `createMandate` forces the
  // threshold non-null whenever a cosigner is named, and the absence of a cosigner was already
  // refused at the top, so the null branch is unreachable — kept explicit rather than relying on
  // that coupling holding.
  if (mandate.cosignThreshold !== null && amount <= mandate.cosignThreshold) {
    throw refuse(
      ApprovalRefusal.COSIGN_NOT_REQUIRED,
      `${amount} is at or below the threshold ${mandate.cosignThreshold}, so no signature is ` +
        `required and this approval would never be read`,
    );
  }

  // ---- F17: two deadline bounds relative to the mandate, not the clock ----------------------
  // Refuse rather than clamp, for F16's reason: a deadline the model moved with no signal to
  // the cosigner is a deadline they did not agree to.
  //
  // An approval that dies at or before the mandate starts spans only the stretch in which
  // `evaluate` denies NOT_YET_VALID, so it is unconsumable for its whole life. This is the
  // mandate-relative twin of that condition and NOT a `notBefore` guard: approving ahead of a
  // start date stays legal, it just has to outlive the start.
  if (validUntil <= mandate.notBefore) {
    throw refuse(
      ApprovalRefusal.BAD_DEADLINE,
      `validUntil ${validUntil} is at or before the mandate's notBefore ${mandate.notBefore}, ` +
        `so no spend could ever fall inside it`,
    );
  }
  // The stretch of an approval that outlives the mandate is likewise authority that cannot be
  // exercised. Left unbounded, a 30-day approval on a mandate expiring tomorrow shows the
  // cosigner a month of authority and means a day of it. The cost is that a cosigner cannot pass
  // `now + MAX_COSIGN_TTL` blindly and has to read `expiresAt` first, which is the intended
  // direction of travel for this whole finding.
  if (mandate.expiresAt !== null && validUntil > mandate.expiresAt) {
    throw refuse(
      ApprovalRefusal.BAD_DEADLINE,
      `validUntil ${validUntil} outlives the mandate's expiresAt ${mandate.expiresAt}`,
    );
  }

  const hash = spendHash({
    mandate,
    recipient,
    amount,
    ref: request.ref ?? '',
    nonce: request.nonce,
  });
  // F30: one nonce holds one approval. A second approval on a nonce already held for a
  // different spend is refused rather than allowed to overwrite it, because the two cannot both
  // be consumed: the first spend to land burns the nonce and the survivor is stranded. The
  // cosigner who wants to replace an approval withdraws it first, which is one extra call and
  // an explicit decision instead of a silent loss.
  //
  // Re-approving the SAME request is allowed and lands on the write below, so extending a
  // deadline needs no withdrawal.
  //
  // F39's liveness term, for the reason it carries on the spend path. A reservation whose
  // approval has already lapsed protects nothing, and refusing on it would leave the cosigner
  // unable to approve a replacement on that nonce without first withdrawing an approval that
  // has expired. The write below overwrites the dead entry, so there is nothing to clear.
  const reservedHash = mandate.cosignReservedNonces.get(request.nonce);
  if (
    reservedHash !== undefined &&
    reservedHash !== hash &&
    cosignIsLive(mandate, reservedHash, now)
  ) {
    throw refuse(
      Denial.NONCE_RESERVED,
      `nonce ${request.nonce} is already held for a different approved spend — withdraw that ` +
        `approval first`,
    );
  }
  mandate.cosignReservedNonces.set(request.nonce, hash);
  mandate.cosignApprovals.set(hash, validUntil);
  return hash;
}

/**
 * Withdraw a co-signature before it is used. Only the cosigner may call it.
 *
 * NEW IN v2 (F30), and the reason this function exists in the model at all. The contract has
 * always had it; the model did not, because deleting an approval had no consequence beyond the
 * approval itself. The nonce reservation changes that: without a release path, a cosigner who
 * approved and then withdrew would leave the nonce held for a hash no longer in the Map, and
 * that nonce would be unspendable for the life of the mandate. The fix for one denial-of-service
 * would have introduced another.
 *
 * The nonce is a parameter because a hash cannot be turned back into the nonce inside it. The
 * release is conditional on the pair matching, so a wrong nonce cannot free a nonce belonging to
 * a different live approval — the call is simply repeatable with the right one.
 *
 * @param {object} mandate
 * @param {string} caller
 * @param {string} hash   the spend hash to withdraw, as returned by approveCosignFor
 * @param {string} nonce  the nonce that hash was approved under
 * @returns {boolean} whether an approval was actually present and removed
 */
function withdrawCosign(mandate, caller, hash, nonce) {
  if (!mandate) throw new Error('withdrawCosign(): unknown mandate');
  if (!mandate.cosigner || normalizeAddr(caller) !== mandate.cosigner) {
    const err = new Error('withdrawCosign(): only the cosigner may withdraw');
    err.code = ApprovalRefusal.NOT_COSIGNER;
    throw err;
  }
  const had = mandate.cosignApprovals.delete(hash);
  if (nonce !== undefined && mandate.cosignReservedNonces.get(nonce) === hash) {
    mandate.cosignReservedNonces.delete(nonce);
  }
  // Withdrawing an approval that is not there is not an error, matching the contract: the
  // post-state the caller asked for is the post-state they get, and a cosigner racing a spend
  // should not have their cancellation revert because the spend won.
  return had;
}

/**
 * Remaining headroom on every axis — what a dashboard or an agent's pre-flight
 * check should read. This function is pure and does not mutate the mandate.
 */
function headroom(mandate, now) {
  const t = BigInt(now);
  const perWindow = mandate.windows.map((win, i) => {
    const usage = windowUsage(win, mandate.windowState[i], t);
    return {
      lengthSeconds: win.lengthSeconds,
      cap: win.cap,
      used: usage.effective,
      remaining: win.cap > usage.effective ? win.cap - usage.effective : 0n,
    };
  });

  const candidates = [];
  if (mandate.perTxCap !== null) candidates.push(mandate.perTxCap);
  if (mandate.totalCap !== null) {
    candidates.push(
      mandate.totalCap > mandate.totalSpent ? mandate.totalCap - mandate.totalSpent : 0n,
    );
  }
  for (const w of perWindow) candidates.push(w.remaining);

  const live =
    !mandate.revoked &&
    t >= mandate.notBefore &&
    (mandate.expiresAt === null || t < mandate.expiresAt);

  return {
    live,
    revoked: mandate.revoked,
    totalSpent: mandate.totalSpent,
    spendCount: mandate.spendCount,
    windows: perWindow,
    // largest single spend that could succeed right now, ignoring cosign/allowlist
    maxSpendNow: live
      ? candidates.length
        ? candidates.reduce((a, b) => (a < b ? a : b))
        : null
      : 0n,
  };
}

/**
 * NEW IN v2. The joint ceiling across several mandates held against ONE payer.
 *
 * WHY THIS EXISTS. Every per-mandate view answers "what can this mandate move?"
 * and none of them can answer "what can all of them move?", because the thing
 * they share is not in any mandate: it is the payer's single ERC-20 allowance to
 * the manager. On 2026-08-24 two live mandates on Arc each reported 90,000
 * spendable against an allowance of exactly 90,000, and a 50,000 dry-run
 * succeeded on both. Summing the two per-mandate answers gives 180,000, which is
 * twice what the payer can actually lose. This does NOT fix that race — the race
 * is inherent to layering per-mandate policy on one shared allowance — it makes
 * the overlap a number you can read instead of an inference no reader would make.
 *
 * WHAT THE NUMBER MEANS, EXACTLY. The largest total that ONE spend from each
 * named mandate could move right now. It is deliberately NOT total flow: a
 * mandate with a rolling window permits repeated spends as buckets age out, so
 * flow over any interval longer than an instant is unbounded by this figure.
 *
 * EACH TERM IS CLAMPED AT MAX_AMOUNT, and that is not defensive padding — it is
 * the same correction #11 had to make to `effectiveMax`. `headroom()` reports
 * `null` for a mandate bounded only by an expiry, meaning "no cap on this axis",
 * but a spend from such a mandate is still refused above MAX_AMOUNT. So `null`
 * over-reports, and an uncorrected sum inherits the over-report. Clamping first
 * makes each term the true largest single spend, which has a second consequence
 * worth stating because it is easy to lose: the sum can then no longer be made
 * to overflow. The Solidity side caps the array at 8, so the widest possible
 * total is 8 * (2^96 - 1) < 2^99, against a uint256 ceiling of 2^256. **Do not
 * "harden" the addition with a saturating add.** A saturating add would give the
 * same answers and would destroy the reason they are correct, which is that the
 * terms are bounded, not that the sum is caught.
 *
 * WHAT IT OMITS, AND WHY THAT IS THE WHOLE DIFFERENCE FROM SOLIDITY. This model
 * has no token, so it can only compute the policy half of the answer. The
 * contract's `spendableAcross` finishes the job by intersecting this sum with
 * `allowance(payer, manager)` and `balanceOf(payer)`, and it is that intersection
 * that turns 180,000 into 90,000. A client running this model against a real
 * chain must apply both clamps itself.
 *
 * TWO REFUSALS, AND ONE THE CONTRACT HAS THAT THIS DOES NOT.
 * Mixed payers and duplicate ids throw, because both would return a confidently
 * wrong number: there is no joint ceiling across two payers (they have separate
 * allowances and separate balances, so no single clamp applies), and a repeated
 * id double-counts headroom that exists once. Note that duplicates are the more
 * dangerous of the two — mixing payers at least tends to produce a figure that
 * reads as wrong, whereas naming the same mandate twice produces a plausible one.
 * The contract additionally refuses arrays longer than 8, and that bound is
 * deliberately NOT mirrored here. The rule being followed: bounds that constrain
 * the state machine get mirrored, because they change which spends are legal
 * (MAX_WINDOWS, MAX_BUCKETS and MAX_AMOUNT are all in this file for that
 * reason); bounds that merely ration a read do not, because nothing downstream
 * depends on them. The 8 exists to keep ~139 storage reads per mandate inside
 * one call's gas budget, and JavaScript has no such budget. A caller with more
 * than eight mandates does exactly what this function does — read
 * `policyHeadroom` per id, clamp each at MAX_AMOUNT, add, then clamp the total
 * by allowance and balance off chain.
 */
function headroomAcross(mandates, now) {
  if (!Array.isArray(mandates)) {
    throw new Error('headroomAcross(): mandates must be an array');
  }
  // An empty request is answered, not refused. Zero mandates can move zero, and
  // reading `mandates[0].payer` to find the payer of nothing would throw a
  // TypeError that says nothing about policy.
  if (mandates.length === 0) {
    return { payer: null, count: 0, maxJointSpendNow: 0n };
  }

  const payer = mandates[0].payer;
  const seen = new Set();
  let total = 0n;

  for (const m of mandates) {
    if (m.payer !== payer) {
      throw new Error(
        `headroomAcross(): all mandates must share one payer — ${mandates[0].id} is held ` +
          `against ${payer} and ${m.id} against ${m.payer}. There is no joint ceiling ` +
          `across payers: each has its own allowance and its own balance, so no single ` +
          `clamp applies to the sum. Call once per payer.`,
      );
    }
    if (seen.has(m.id)) {
      throw new Error(
        `headroomAcross(): mandate ${m.id} named more than once. Its headroom exists ` +
          `once and would be counted twice, which returns a plausible wrong number ` +
          `rather than an obvious one.`,
      );
    }
    seen.add(m.id);

    // `null` means "unbounded on every axis the payer set", which is still bounded
    // by MAX_AMOUNT at spend time. See the note above on why this clamp, and not a
    // saturating add, is what makes the total safe.
    const one = headroom(m, now).maxSpendNow;
    total += one === null || one > MAX_AMOUNT ? MAX_AMOUNT : one;
  }

  return { payer, count: mandates.length, maxJointSpendNow: total };
}

module.exports = {
  USDC,
  DAY,
  WEEK,
  MAX_WINDOWS,
  MAX_BUCKETS,
  MAX_COSIGN_TTL,
  MAX_AMOUNT,
  MAX_SPEND_COUNT,
  Denial,
  // NEW IN v2 (F17). Kept out of Denial on purpose — see its own comment for why.
  ApprovalRefusal,
  ZERO_ADDRESS,
  usdc,
  formatUsdc,
  window,
  createMandate,
  windowUsage,
  ringSlot,
  spendHash,
  evaluate,
  commit,
  spend,
  revoke,
  approveCosignFor,
  withdrawCosign,
  headroom,
  headroomAcross,
};
