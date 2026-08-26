// SPDX-License-Identifier: MIT
//
// Remit — executable reference model for the spending-policy engine.
//
// WHY THIS FILE EXISTS
// This is the normative specification of the policy logic. MandateManager.sol is
// a line-for-line mirror of it. It was written first because the sandbox it was
// authored in could not compile Solidity, so the contract's *logic* had to be
// verified somewhere — here, in a dependency-free model with an adversarial test
// suite, with the contract held to match. The contract now compiles, passes 139
// Forge tests of its own, and runs on Arc Testnet, which makes this a cross-check
// rather than the only evidence, and that is strictly better: two independent
// implementations that agree are worth more than one that passes. Where the two
// disagree, this file is the bug report — except on the ten questions where the
// reverse turned out to be true and this model was corrected to match the contract.
//
// UNITS
// Every amount is a BigInt in ERC-20 USDC units: 6 decimals, so 1 USDC = 1_000_000n.
// Arc exposes USDC through two interfaces over ONE balance — native at 18 decimals
// and ERC-20 at 6 (arc/references/evm-differences.mdx). This engine speaks 6-decimal
// ERC-20 units exclusively, which is what the Arc docs recommend for application
// accounting, and never mixes in an 18-decimal value.
//
// TIME
// `now` is a block timestamp in seconds. Arc timestamps are NON-DECREASING but NOT
// strictly increasing: sub-second blocks (~0.48s average) can share a timestamp
// (arc/references/evm-differences.mdx). So the engine never treats a timestamp as
// unique, never uses it for ordering, and never assumes it advanced between calls.
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
  AMOUNT_TOO_LARGE: 'AMOUNT_TOO_LARGE',
  OVER_PER_TX_CAP: 'OVER_PER_TX_CAP',
  OVER_WINDOW_CAP: 'OVER_WINDOW_CAP',
  OVER_TOTAL_CAP: 'OVER_TOTAL_CAP',
  TOTAL_SPENT_CEILING: 'TOTAL_SPENT_CEILING',
  NONCE_ALREADY_USED: 'NONCE_ALREADY_USED',
  COSIGN_REQUIRED: 'COSIGN_REQUIRED',
  IDENTITY_NOT_HELD: 'IDENTITY_NOT_HELD',
  IDENTITY_TRANSFERRED: 'IDENTITY_TRANSFERRED',
  CREDENTIAL_MISSING: 'CREDENTIAL_MISSING',
  CREDENTIAL_STALE: 'CREDENTIAL_STALE',
  CREDENTIAL_WRONG_VALIDATOR: 'CREDENTIAL_WRONG_VALIDATOR',
  CREDENTIAL_WRONG_AGENT: 'CREDENTIAL_WRONG_AGENT',
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

/**
 * Largest spendable amount: 2^96 - 1, about 7.9e22 USDC.
 *
 * This exists only because the contract does. `totalSpent` and every cap are packed
 * as uint96 so that a Mandate fits in few storage slots, and `spend` takes a uint256
 * amount which it casts down. An unchecked cast would truncate a huge amount into a
 * small one that passes every cap, so the contract refuses anything that does not fit
 * before consulting a single bound. JavaScript's BigInt has no such limit and would
 * silently diverge here — which is the whole reason to mirror the constant rather
 * than let the model be more permissive than the thing it specifies.
 */
const MAX_AMOUNT = (1n << 96n) - 1n;

/**
 * Create a rolling-window spec.
 *
 * WHY A BUCKET RING, AND WHY IT ERRS STRICT
 *
 * An exact sliding window needs the timestamp of every spend — unbounded storage,
 * so it is not implementable on-chain. Two cheap approximations exist and both
 * have a failure mode worth naming:
 *
 *   1. Tumbling window (reset the counter each period). Cheapest, and badly
 *      broken: spend the full cap in the last second of period N and the full cap
 *      again in the first second of N+1 — 2x the cap inside two seconds.
 *
 *   2. Proportional two-bucket decay (the classic "sliding window counter"),
 *      which weights the previous period by how much of it still overlaps. Better,
 *      but it UNDERCOUNTS when spending is clustered at the end of the previous
 *      period: it assumes uniform distribution, so an agent that front-loads can
 *      still exceed the cap over a true trailing window.
 *
 * This implementation splits the window into K = `buckets` sub-periods of
 * S = L/K seconds and keeps a ring of per-sub-period counters. With b = now/S the
 * current sub-bucket, usage is the sum of buckets [b-K, b] — that is K+1 buckets,
 * not K, and the +1 is the load-bearing detail.
 *
 * WHY K+1 (this was a bug, caught by the fuzz test in policy.test.js)
 * Summing only [b-K+1, b] covers the span [(b-K+1)S, (b+1)S), which is L seconds
 * long but ends at the END of the current bucket — in the future relative to now.
 * The span is therefore shifted forward by up to S, and bucket b-K falls out of
 * the ring. But b-K always still overlaps the true trailing window (t-L, t],
 * because its end (b-K+1)S = bS + S - L > t - L for every t < (b+1)S. So a spend
 * late in bucket b-K stopped being counted while it was still genuinely inside
 * the window — a real breach, not a rounding artifact. The fuzz test found it at
 * K=4 by spending near the end of a sub-bucket and again exactly K buckets later.
 *
 * THE GUARANTEE, with the +1
 * Take any spend at time u in (t-L, t]. Its bucket is floor(u/S) <= b since
 * u <= t. And u > t-L >= bS - L = (b-K)S, so floor(u/S) >= b-K. Hence every spend
 * in the true trailing window sits in [b-K, b] and IS counted. The engine can
 * therefore never permit more than `cap` in any true trailing window of L.
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
  // "at least one bound" check in createMandate — so accepting it mints a mandate that
  // looks configured and is dead. The contract calls this BadWindow.
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

  const hasBound =
    perTxCap !== null || windows.length > 0 || totalCap !== null || expiresAt !== null;
  if (!hasBound) {
    throw new Error(
      'createMandate(): refusing to create an unbounded mandate — set at least one of ' +
        'perTxCap, windows, totalCap, expiresAt',
    );
  }
  if (cosignThreshold !== null && !cosigner) {
    throw new Error('createMandate(): cosignThreshold requires a cosigner');
  }
  // And the converse, which this model accepted until v2 and the contract never could.
  // On-chain, F_COSIGN is derived from `cosigner != address(0)` and the threshold is a
  // plain uint96 whose zero is meaningful — "every spend needs a signature", since the
  // gate tests `amount > threshold` strictly and amount is at least 1. There is no
  // on-chain state for "a cosigner is named but nothing is gated", so a model that
  // accepted one was describing a mandate that cannot exist. Spell it `cosignThreshold: 0`
  // to gate everything; that is what the contract stores.
  if (cosigner && cosignThreshold === null) {
    throw new Error(
      'createMandate(): a cosigner requires a cosignThreshold — use 0 to require a ' +
        'signature for every spend, which is what the contract stores',
    );
  }
  // The agent may not be its own cosigner. `approveCosign` authorises on
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

  // The co-signature gate must be able to fire. `evaluate` demands a signature when
  // `amount > cosignThreshold`, strictly, so the gate is dead unless the policy permits
  // at least one amount above the threshold. Compare against the largest single spend the
  // WHOLE policy allows, not against any one field:
  //
  //   effectiveMax = min(MAX_AMOUNT, perTxCap, totalCap, every window cap)
  //
  // MAX_AMOUNT is in there because it is the bound that applies when nothing else does —
  // a mandate bounded only by an expiry still caps amounts at the width of the on-chain
  // uint96, so a threshold of MAX_AMOUNT is unreachable even with no caps at all. totalCap
  // is evaluated at totalSpent = 0, which is right because reachability asks whether the
  // gate can EVER fire and the lifetime cap is loosest on the first spend. Window caps
  // enter as a minimum because the tightest one binds every spend.
  //
  // The obvious test, `perTxCap < cosignThreshold`, is wrong twice over: the comparison
  // is backwards, since equality is dead too (`amount > threshold` and `amount <= perTxCap`
  // cannot both hold when they are equal — confirmed on Arc Testnet, DESIGN.md:1272), and
  // perTxCap is not the only ceiling, since `totalCap = 100` with `cosignThreshold = 100`
  // and no per-transaction cap is equally dead.
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
    cosignApprovals: new Set(), // spend hashes pre-approved by the cosigner
  };
}

function normalizeAddr(a) {
  return String(a).toLowerCase();
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

/** Which ring slot a sub-bucket index maps to. Ring holds K+1 slots. */
function ringSlot(win, bucketIndex) {
  return Number(((bucketIndex % win.ringSize) + win.ringSize) % win.ringSize);
}

/**
 * Compute the spend hash used for co-signature approval and idempotency.
 * Binds every economically meaningful field, so an approval cannot be replayed
 * against a different recipient, amount, reference, or nonce.
 */
function spendHash({ mandateId, spender, recipient, amount, ref, nonce }) {
  return [
    'Remit:v1',
    mandateId,
    normalizeAddr(spender),
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
  // expiresAt is EXCLUSIVE: a mandate expiring at T is dead AT T. Chosen
  // deliberately — with sub-second blocks sharing a timestamp, an inclusive
  // bound would leave an ambiguous final second in which liveness depends on
  // which block within that second included the transaction.
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
  // identity is a TRANSFERABLE ERC-721. Holding the token now is necessary but
  // not sufficient: we also pin the owner the payer intended at grant time, or a
  // token transfer would silently move spending authority to a stranger.
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
    if (
      mandate.identity.expectedOwner &&
      normalizeAddr(owner) !== normalizeAddr(mandate.identity.expectedOwner)
    ) {
      return deny(Denial.IDENTITY_TRANSFERRED, {
        expected: mandate.identity.expectedOwner,
        got: owner,
      });
    }
  }

  // --- credential gate (optional, ERC-8004 ValidationRegistry) ---
  // getValidationStatus is the one credential check Arc exposes on-chain.
  // Reputation is write-only in the documented ABI, so it is deliberately unused.
  //
  // THE TUPLE MUST BE CHECKED, NOT JUST THE RESPONSE
  // getValidationStatus(bytes32 requestHash) is keyed ONLY by requestHash and
  // returns (validatorAddress, agentId, response, responseHash, tag, lastUpdate).
  // Reading `response` alone makes the gate theater: anyone can pick a requestHash
  // and have some cooperative validator answer it, or reuse an attestation issued
  // about a different agent. So the validator that answered and the agent it
  // answered about are both verified against what the payer named at grant time.
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
    // the contract can never express. Same reasoning as maxStaleness below.
    //
    // If BOTH are unset the check is SKIPPED, not failed, and the gate degrades to
    // "the named validator filed a passing, fresh attestation under this exact
    // requestHash" with nothing tying it to this spender. That is a documented gap, not
    // an oversight — see DESIGN.md, "The credential gate had to be built twice". It is
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
    // The `now > lastUpdate` guard matters on-chain: an attestation dated in the
    // future would underflow an unsigned subtraction. Kept here so the two read the
    // same, even though BigInt arithmetic would merely go negative.
    const staleAfter = maxStaleness === null ? 0n : BigInt(maxStaleness);
    if (staleAfter > 0n && now > BigInt(att.lastUpdate) && now - BigInt(att.lastUpdate) > staleAfter) {
      return deny(Denial.CREDENTIAL_STALE, {
        age: now - BigInt(att.lastUpdate),
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
  const hash = spendHash({ mandateId: mandate.id, spender, recipient, amount, ref, nonce });
  if (mandate.cosignThreshold !== null && amount > mandate.cosignThreshold) {
    if (!mandate.cosignApprovals.has(hash)) {
      return deny(Denial.COSIGN_REQUIRED, { amount, threshold: mandate.cosignThreshold, hash });
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

/** Apply a previously-evaluated allowed decision. Throws if handed a denial. */
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
  if (e.consumesCosign) {
    // A co-signature authorises exactly one spend.
    mandate.cosignApprovals.delete(decision.hash);
  }
  return mandate;
}

/** Convenience: evaluate then commit. Returns the decision either way. */
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
 * power revocation removes is the agent's own. Nobody else may call it.
 *
 * On Arc this is stronger than on a probabilistic-finality chain: finality is
 * deterministic at one confirmation (arc/concepts/deterministic-finality.mdx),
 * so there is no reorg window in which a revoked mandate is still live and
 * spendable. On Ethereum a revocation is only economically final after minutes,
 * which is a real gap when the counterparty is an automated agent.
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

/** Pre-approve exactly one spend that exceeds the co-sign threshold. Cosigner only. */
function approveCosign(mandate, caller, request) {
  if (!mandate.cosigner) throw new Error('approveCosign(): mandate has no cosigner');
  if (normalizeAddr(caller) !== mandate.cosigner) {
    throw new Error('approveCosign(): only the cosigner may approve');
  }
  const hash = spendHash({
    mandateId: mandate.id,
    spender: request.spender ?? mandate.spender,
    recipient: request.recipient,
    amount: request.amount,
    ref: request.ref ?? '',
    nonce: request.nonce,
  });
  mandate.cosignApprovals.add(hash);
  return hash;
}

/**
 * Remaining headroom on every axis — what a dashboard or an agent's pre-flight
 * check should read. Pure; does not mutate.
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
 * the overlap a number you can read instead of an inference nobody makes.
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
 * dangerous of the two — mixing payers at least tends to produce an obviously
 * odd figure, whereas naming the same mandate twice produces a plausible one.
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
  MAX_AMOUNT,
  Denial,
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
  approveCosign,
  headroom,
  headroomAcross,
};
