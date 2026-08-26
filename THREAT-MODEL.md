# THREAT-MODEL.md

**Status: FIRST PASS, 2026-08-26. Not an audit.** Written by the same author as the
contract, which is the reason it cannot substitute for the professional audit already
scheduled. Its purpose is narrower and still worth something: to make the search for
defects *systematic* instead of opportunistic, and to write down what Remit protects,
what it does not, and what nobody has looked at yet.

> **Line numbers in this file are marked `v2:NNN` and are anchored to commit
> `f2d3b35`**, the commit that landed tasks #10–#12 and the exact code this review
> examined. Recover the source they refer to with
> `git show f2d3b35:contracts/MandateManager.sol`. That is a deliberate exception to the
> repo-wide convention recorded in `FORGE.md` (unqualified line numbers into
> `contracts/MandateManager.sol` mean the `v1.0.0-arc-testnet` tag), because this
> document is about the code being changed rather than about the code that is deployed.
> Anchoring to a commit rather than to "the working tree" is the point: the fixes this
> document argues for will move every line in it, and a reviewer needs to be able to
> reach what was actually read. Function names are used in preference to line numbers
> wherever one will do, since a function name does not move at all.

## Why this document exists

The instruction that produced it, 2026-08-26: *security is to be the utmost priority in
all design and contract work, "literally every nook and cranny", because this is
intended to hold real money.*

The honest response to that instruction is not a claim of completeness. It is a method.
Three times now, a defect has been found by asking the general question that a specific
written item was an instance of, rather than by working the item as written:

- `CHANGELIST.md` listed "revert when the cosign gate is unreachable". Asking instead
  *in how many ways can a mandate display a co-signature requirement without having
  one?* gave five, of which the worst — a mandate whose cosigner is its own spender, so
  the agent approves its own spend hash — was on no list anywhere and was accepted by
  both the contract and the reference model.
- The `uint96 totalSpent` liveness cliff was on no list at all.
- The joint-ceiling view was listed as "additive, low risk"; the naive implementation
  *panics* on a two-line construction.

The written list has been short every single time. So this pass does not work a list.
It enumerates a surface and asks a question of every element of it.

## 1. Assets, and who can move them

The only asset is **the payer's USDC balance**, held in the payer's own account. It is
never held by `MandateManager`, which has no balance, no `withdraw`, no sweep, no owner
and no admin. There is no protocol treasury, no fee, and nothing to steal from the
contract itself.

What the contract holds is *authority*: the standing ERC-20 allowance that the payer
granted it, which it may exercise only through `spend`. The blast radius of a total
compromise of Remit's logic is therefore exactly **the payer's allowance to this
contract, intersected with the payer's balance** — not the payer's whole balance, and
not any other payer's anything.

Five actors appear in the code. `payer` grants and revokes. `spender` (the delegate —
an AI agent, a payroll bot, a subscription service) spends. `cosigner` approves
individual spends above a threshold. `recipient` receives. Everyone else is a third
party with no role.

## 2. Trust boundaries — what Remit does not protect, by construction

These are not defects. They are the edges of what an on-chain spending mandate can do,
and a payer who does not know them will over-trust the primitive.

**The payer account's own security is outside the boundary, and on Arc this is sharper
than on other chains.** Arc's own wallet documentation states it plainly: *"An ERC-20
allowance is not a cap on total USDC spending: the same balance can also leave as
native value (`msg.value`). For smart contract accounts (embedded wallets, smart
wallets, and session-key systems), do not rely on allowance state as a safety
guarantee. Any module with execution rights can also transfer native USDC regardless of
allowance state."* So if the payer is a 4337 smart account, a Circle SCA or a Safe, any
module with execution rights on that account can move the same USDC without consulting
Remit at all. Remit bounds what *the delegate* can do through *this contract*. It cannot
bound what the payer's own account can do, and it never claimed to — `DESIGN.md` already
makes the `msg.value` point. What is added here is the smart-account consequence, which
matters because the L3 vault design in `L3-VAULT.md` makes a contract the payer.

**Circle is in the trust boundary.** USDC on Arc is a Circle-operated asset with a
runtime-enforced blocklist and an upgradeable implementation. A blocklisted payer or
recipient makes a spend revert. That is the correct outcome for Remit (nothing moves, no
cap consumed, no nonce burned) but it is not something Remit controls.

**The validator named in a credential gate is fully trusted, including about time.**
`_checkCredential` checks that the attestation came from the payer-named validator and
concerns the expected agent, which is what stops the gate being theatre. It cannot check
that the validator is *honest*. In particular the staleness test is
`nowTs > lastUpdate && nowTs - lastUpdate > c.maxStaleness`, so an attestation dated in
the **future** skips the freshness check entirely and is treated as fresh forever. A
validator can therefore defeat the payer's own freshness requirement permanently. This
is a trust statement rather than a bug — a payer who does not trust the validator should
not name it — but it is not currently written down anywhere.

A related property of the same gate **is** already written down, and the contrast is
instructive. When neither `credential.agentId` nor the identity gate's `agentId` is set,
`_checkCredential` skips the agent comparison entirely and the gate degrades to "the
named validator filed a passing, fresh attestation under this exact `requestHash`", with
nothing tying it to the spender. That is reachable by omission, since zero is a struct
field's default — and the source says so in ten lines of comment, names the design reason
(an attestation about a *request* rather than about an agent is a legitimate shape, and
`requestHash` is payer-fixed at grant time so the spender cannot redirect the lookup),
and points at a test that pins the behaviour by name,
`test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent`. It is not a finding
here precisely because that work was already done. It is the standard the future-dated
staleness hole should be brought up to.

**Everything is public.** Every mandate, every cap, every spend, every recipient, and
the whole commercial relationship it implies. This is the subject of `PRIVACY.md` and
`L3-VAULT.md` and is not restated here.

**The proposer chooses transaction order.** Arc's deterministic finality removes reorgs;
it does not remove the mempool. See F4.

## 3. Properties the contract does enforce, and the guard for each

Derived by walking the source, not by reading the test names. Five functions change
state: `createMandate`, `spend`, `revoke`, `approveCosign`, `withdrawCosign`. There are
no setters, no admin functions, no `delegatecall`, no `selfdestruct` and no upgrade
path.

| Property | Enforced by |
| :--- | :--- |
| Only the named spender can spend | `spend`: `msg.sender != m.spender` → `WrongSpender` |
| A mandate id is unique to one payer forever | id = `keccak256(DOMAIN, chainid, this, msg.sender, salt)`; `payer != address(0)` → `MandateExists`. `payer` is never cleared, so an id is single-use permanently and no revoked mandate's storage can be reinterpreted |
| No mandate can be created without some bound | `createMandate`: `hasBound` → `Unbounded`. **But see F5 for what "bound" does and does not mean** |
| Every flag agrees with the value it describes | five biconditionals in `createMandate`. **Except `F_EXPIRY` — see F1** |
| A displayed co-signature requirement is a real one | three grant-time guards: threshold-without-flag, `cosigner == spender`, and `effectiveMax <= cosignThreshold` |
| Caps cannot be exceeded per-transaction, per-window, or per-lifetime | `OverPerTxCap`, `OverWindowCap`, `OverTotalCap`; window accounting independently searched over 3.0M spend sequences with zero violations, on a harness that reproduces the historical K-bucket bug at 2× cap |
| A rolling window is genuinely rolling | K+1 bucket summation. The proof in the source is valid but proves less than the code guarantees: eviction (`bucketIndex < oldest`) is the exact negation of inclusion (`bucketIndex >= oldest`) computed from the same `oldest` in the same call, and `oldest` is monotone, so nothing counted is ever discarded. `createMandate`'s `lengthSeconds % buckets != 0` check is load-bearing for cap soundness, not merely for uniformity |
| A spend cannot be replayed | `_usedNonce[mandateId][nonce]`; a reverted spend does not consume its nonce |
| One co-signature authorises exactly one spend | the hash binds mandate, spender, recipient, amount, ref and nonce plus `DOMAIN`, chainid and `address(this)`; consumed with `delete` on use |
| Revocation is immediate and permanent | `revoke` sets `revoked = true`; no un-revoke exists |
| A compromised agent can shut itself off | `revoke` also accepts the spender |
| Caps hold even if the token misbehaves | see F7 — this is stronger than the source claims |

## 4. Findings

Ranked by what I would want fixed before this holds real money, not by CVSS. Severity
reflects consequence *and* reachability; several of the most interesting entries are
false or overstated claims in comments and documents rather than defects in code, which
for a primitive whose entire product is *legibility of authority* is not a lesser
category.

**Fourteen findings, counted from the headings below rather than asserted.** The count is
not a measure of anything — it is a function of how long the search ran. Triage:

| Fix before v2 freezes | Cost | Needs a decision first |
| :--- | :--- | :--- |
| F1 `expiresAt` grant-time refusal | 1 line + 1 test + model mirror | — |
| F2 `DESIGN.md` worked example | numbers derived, needs a doc sweep | — |
| F3 `SpendCountCeiling` guard | 1 error + 1 line | or leave it and fix the changelist text |
| F9 `spendable` clamp | 1 line | — |
| F10 four → five | comment only | — |
| F11 `withdrawCosign` two guards, `revoke` idempotence | 3 lines | — |
| F4, F7, F8, F14 wrong justifications | comment rewrites | — |
| F5 `Unbounded()` scope | new guard + tests + model mirror | **DECIDED 2026-08-26: refuse** |
| F6 threshold splitting | doc + one composition test | **DECIDED: document, recommend pairing with a window** |
| F13 gate pre-validation | 2 registry reads at grant + tests | **DECIDED 2026-08-26: validate at grant** |
| §5 coverage gaps | 4 tests | fold into #14, which needs the gas number anyway |

F12 is a design consequence rather than a defect and needs nothing. Nothing on this list
risks funds in the sense of letting a spend exceed a granted cap; the window search found
no such case in 3.0M sequences. What this list is mostly about is the gap between what a
payer is *shown* and what is *enforced*, which is the thing Remit sells.

---

### F1 — `expiresAt` is stored, emitted and displayed on a mandate that never expires

**Severity: medium. Status: OPEN. Confidence: certain.**

`createMandate` couples each flag to the value it describes with a biconditional, for
`F_PER_TX`, `F_TOTAL`, `F_COSIGN`, `F_CREDENTIAL` and `F_ALLOWLIST`. `F_EXPIRY` has no
such rule: `v2:413` validates `expiresAt` only *when the flag is set*
(`if (flags & F_EXPIRY != 0 && p.expiresAt <= p.notBefore)`). With the flag unset, any
`expiresAt` is accepted, written to storage, and emitted in `MandateCreated`, while
nothing ever reads it — `spend` and `isLive` both gate the comparison on the flag.

So a payer can be shown, by `getMandate` and by the creation event, a mandate that
expired last Tuesday and that will spend forever. This is the identical failure class as
the `cosignThreshold`-without-`F_COSIGN` lie that v2 already refuses at `v2:432`, and
the argument that settled that one applies verbatim: a grant that appears to carry a
control it does not carry is refused rather than documented.

The fact is not new — `L3-VAULT.md:218` records that `expiresAt` "is then an unvalidated
field that may be zero", and the arithmetic sweep independently reached the same place.
What is new is the framing: it was written down as a trap for a *future vault's* release
predicate, addressed to a reader building on top of Remit. It was never treated as a
property of the mandate that every direct payer also sees.

The asymmetry with `notBefore` is worth stating because it looks like the same problem
and is not: `notBefore` is enforced unconditionally, in both `spend` and `isLive`, with
no flag at all. It therefore cannot be displayed-but-dead, and needs no rule.

**Fix:** one line beside the existing guard —
`if (flags & F_EXPIRY == 0 && p.expiresAt != 0) revert BadConfig();` — one-directional
for the same reason the threshold rule is, plus its mirror in `reference/policy.js` and
a `Creation.t.sol` test. `expiresAt` is the last field in the struct that can lie; the
enumeration of all thirteen `Mandate` fields and three gate structs is in §6.

---

### F2 — `DESIGN.md`'s flagship worked example specifies a mandate v2 refuses to create, and its central claim was already false in v1

**Severity: medium (documentation, fail-closed). Status: OPEN. Confidence: certain.**

The narrative at `DESIGN.md:30-96` is the document's opening argument and the clearest
statement anywhere of what Remit is for. It specifies a mandate with an allowlist, a
**€5,000 per-transaction cap**, a **rolling 24-hour cap of €15,000**, and a **€10,000
co-signature threshold**. Two things are wrong with it.

**It cannot be created under v2.** The reachability guard added in #11 computes
`effectiveMax = min(2^96 - 1, perTxCap, minWindowCap) = min(5,000, 15,000) = 5,000` and
refuses when `effectiveMax <= cosignThreshold`. 5,000 ≤ 10,000, so `createMandate`
reverts `BadConfig`. A payer following the canonical example lands on a revert.

**Its conclusion was already false in v1.** The narrative says: *"Suppose they aimed at
€12,000, under every cap. That is above the €10,000 co-signature threshold, so Ada is
asked."* €12,000 is not under every cap — it is over the €5,000 per-transaction cap, so
v1 refuses it at `OverPerTxCap` and Ada is never asked. The example's stated
configuration could never have produced the human-in-the-loop moment the paragraph
exists to demonstrate. The v2 guard did not break the example; it detected that the
example had been broken since it was written, which is exactly what that guard is for.

This is the #11 pattern again, one layer out: the repository asserted a protection its
own configuration could not deliver. It matters more than an ordinary documentation
defect because this is the passage a payer reads to learn how to configure the thing.

**Fix:** the constraints determine the numbers almost uniquely. Raising the
per-transaction cap to **€12,000** and leaving the threshold at €10,000 satisfies all
five requirements the narrative makes: €48,000 is still refused by the cap; ten × €4,800
is still stopped at the fourth by the €15,000 rolling window (3 × 4,800 = 14,400 fits,
19,200 does not); €12,000 is now genuinely under every cap and above the threshold, so
Ada is asked; ordinary €4,800 invoices stay below the threshold, preserving the "once,
rather than two hundred times a month" point; and `effectiveMax = 12,000 > 10,000`, so
v2 creates it. Lowering the threshold instead would work arithmetically but would put it
below the €4,800 routine invoice and ask Ada about all of them.

Every other worked configuration in the repository needs the same check against the new
guard, which is a sweep, not an edit.

---

### F3 — The `uint32 spendCount` panic shadows the named `TotalSpentCeiling` error that #10 added

**Severity: low as a fault, medium as a correction to a documented rationale. Status: OPEN. Confidence: certain on the arithmetic.**

`m.spendCount += 1` at `v2:664` is the only checked arithmetic site in the contract with
no guard in front of it, and `spendCount` is `uint32`. At 2^32 spends it raises
Panic 0x11 rather than a named error. `CHANGELIST.md:294` already notes this and
dismisses it as "a genuine difference in reachability rather than a convenience excuse",
which is true in isolation and wrong as a comparison.

`TotalSpentCeiling` needs cumulative spending near 2^96 ≈ 7.92e28 base units. Nothing
forbids `recipient == m.payer`, so a self-spend preserves the balance and the sequence is
sustainable. Reaching 2^96 in fewer than 2^32 spends requires an average amount of at
least 2^96 / 2^32 = 2^64 ≈ 1.84e19 base units, i.e. **about 18.4 trillion USDC**.
Circulating USDC is roughly 6.1e10 USDC, some 300× below that. So in precisely the
`F_TOTAL`-unset case that `v2:649` was written for, the illegible panic fires about 300×
sooner than the legible error, for every balance that can actually exist.

Both are unreachable in practice and neither risks funds — `v2:664` sits above the
transfer, so nothing moves. The finding is that #10's stated achievement ("a denial with
a name instead of a panic") is not delivered on the path it claims, and the source
comment at `v2:636-641` reasons only about the `F_TOTAL`-set case.

Note also that the reason given for declining to widen `totalSpent` — it would change
the `Spend` event signature and therefore its topic0 — **does not apply to
`spendCount`**, which is confirmed absent from the `Spend` event (the event carries
`uint96 totalSpent` and no counter). Slot 3 has exactly three spare bytes: 29 of 32
used, per the layout comment `12 + 5 + 5 + 4 + 1 + 1 + 1 = 29`, which I re-added.

**Fix — and the three options are not independent.** Widening `spendCount` to `uint56`
would consume all three spare bytes exactly (`12 + 5 + 5 + 7 + 1 + 1 + 1 = 32`), and
`uint40` would consume one. But those are **the same three bytes** that
`CHANGELIST.md:298` reserves for the declined `totalSpent` → `uint120` option, so
taking them here forecloses that option permanently, and any widening past the three
spills `Mandate` into a fifth slot — which would add an SLOAD to every read path,
including the 139-cold-SLOAD budget that `MAX_JOINT = 8` was sized against.

The cheap branch is therefore the safe one for once: a named error and a guard,
`if (m.spendCount == type(uint32).max) revert SpendCountCeiling();`, which changes no
struct, no slot count, no event and no gas path. The honest minimum, independent of
whether the guard is added, is to correct `CHANGELIST.md`'s comparison, because the
current text argues the opposite of the arithmetic.

---

### F4 — `revoke`'s comment claims there is no window in which a revoked mandate is still spendable. There is: the mempool.

**Severity: low (inherent, unfixable on-chain) as a risk, medium as a false claim. Status: OPEN. Confidence: high.**

The doc comment on `revoke` says revocation on Arc is stronger than on a
probabilistic-finality chain because "one confirmation is final and reorgs are
impossible, so **there is no window in which a revoked mandate is still live and
spendable**."

The reorg half is correct and confirmed by Arc's docs. The conclusion is not. Arc has a
mempool and a rotating proposer — its own transaction-lifecycle page lists *"Pending —
Transaction is in the mempool, not yet mined"* as a state, and the consensus page
describes the proposer bundling pending transactions. So between a payer broadcasting
`revoke` and its inclusion, a spender watching the mempool can submit a final spend, and
which lands first is the proposer's choice, not the payer's. Deterministic finality
removes uncertainty about whether an *included* transaction stands; it says nothing about
*ordering* among pending ones.

The exposure is bounded by the mandate's own caps — a front-running spender gets at most
one more spend within `perTxCap` and the remaining window and lifetime headroom, which is
the whole point of having caps. It is not fixable inside the contract. But the sentence as
written would let a payer believe revocation is atomic with their decision to revoke, and
the correct advice — size caps so that one final unpoliced spend is survivable — follows
only from the accurate version.

---

### F5 — `Unbounded()` guarantees that *a* bound exists, not that *lifetime exposure* is bounded

**Severity: medium as a legibility gap. Status: OPEN (design question, not necessarily a code change). Confidence: certain.**

`hasBound` is satisfied by `F_PER_TX` **or** `F_TOTAL` **or** `F_EXPIRY` **or** any
window. So a mandate carrying only a per-transaction cap of 100 passes, and the delegate
may spend 100 repeatedly, forever, until the payer's allowance is dry. The same holds for
a window alone: bounded per window, unbounded over a lifetime.

Only `F_TOTAL` and `F_EXPIRY` bound total exposure. The contract's own comment beside the
check says *"refusing to mint an unbounded authority is the entire point of the
primitive, so it is enforced rather than documented"* — and what is enforced is weaker
than what that sentence promises.

`L3-VAULT.md:175-181` states this exactly and correctly, and concludes *"the vault must
require it in its own code."* As with F1, the knowledge is in the repository but is
addressed to somebody building a vault on top of Remit, not to the ordinary payer who
reads `README.md` and grants a mandate directly.

Whether to *change* it is a real design question rather than an obvious fix. Refusing
`F_PER_TX`-only grants breaks legitimately open-ended arrangements (a subscription with a
monthly window and no end date is a reasonable thing to want). An opt-in strictness flag
was considered and is not available: `flags` is a `uint8`, bit 7 is the last free bit, and
it is already committed to `F_ALLOWLIST_ROOT` in #13, so a new flag would mean widening
`flags` to `uint16` — touching every gate, every test and the `MandateCreated` signature.

**DECIDED 2026-08-26 — refuse.** `createMandate` will require `F_TOTAL` **or** `F_EXPIRY`
on every mandate. The open-ended case is served by setting a distant `expiresAt`, which
costs the payer nothing and makes the horizon explicit rather than absent; the reasoning
is the same one that retired the dead co-signature gate in #11 — "merely useless" is not a
reason to allow a configuration whose display and whose enforcement disagree. Note this
makes `hasBound` strictly stronger than its own comment currently claims, so the comment
becomes true rather than aspirational. Implementation belongs with F1's `expiresAt` fix,
since both touch the same block and both need the same mirror in `reference/policy.js`.

---

### F6 — A delegate can split spends to stay under the co-signature threshold indefinitely

**Severity: medium as a residual risk. Status: OPEN (documentation). Confidence: certain.**

The gate is `amount > m.cosignThreshold`, per transaction. A mandate with
`perTxCap = 12,000` and `cosignThreshold = 10,000` and no window lets a delegate move
9,999 as often as it likes without ever asking anyone. The threshold caps the size of an
*unsupervised single payment*; it does not cap unsupervised *total flow*.

`DESIGN.md` handles splitting attacks against **caps** explicitly and well — the ten
× €4,800 passage exists for exactly that — and then does not apply the same reasoning to
the **threshold** one paragraph later. The mitigation is the same mechanism: pair
`F_COSIGN` with a rolling window, so that splitting exhausts the window instead of
evading the signature. That composition is the actual security property and it is
nowhere stated.

Note the interaction with F2: fixing the example's numbers should not create a
configuration that silently has this weakness, so the corrected narrative should say why
the window is what makes the threshold meaningful.

---

### F7 — `spend`'s reentrancy comment gives the wrong reason for a correct conclusion

**Severity: low. Status: OPEN. Confidence: high on the reasoning; one Arc behaviour unverified.**

The comment before the transfer says there is no reentrancy guard "because `usdc` is
immutable and set to Circle's token — **there is no attacker-controlled callee**."

The callee is Circle's token, but the *recipient* is chosen by the spender, subject only
to the allowlist when one is set. Whether that matters depends on a question Arc's docs
do not answer: on Arc, an ERC-20 `transferFrom` moves the native balance through a
precompile, and the docs state that "sending native value to a contract is not guaranteed
to succeed" without saying whether recipient code executes. Standard ERC-20 semantics say
it does not, and no ERC-20 calls its recipient — but that is an inference about a
precompile-backed token, not a documented guarantee, and it belongs in §5.

The conclusion survives either way, and for a better reason than the one given: **every
state write happens before the transfer, and the transfer is the last statement in the
function.** `m.totalSpent`, `m.spendCount`, `_usedNonce` and every window bucket are all
committed first. A reentrant `spend` would therefore see fully updated state and be
policed by every cap exactly like any other spend. The safety comes from
checks-effects-interactions, which holds unconditionally, not from an absence of
untrusted callees, which does not. Stating the weaker reason is what would let a future
change — a post-transfer hook, a callback, a generalisation to arbitrary tokens — look
harmless.

---

### F8 — The forward clock-drift budget for a rolling window is exactly `subLength` seconds, and `isLive`'s comment says there is none

**Severity: low as shipped, medium for short-window grants. Status: OPEN. Confidence: high on the arithmetic.**

`isLive` carries a careful comment arguing that nothing in the contract *grants* capacity
from a timestamp, on the grounds that window accounting has no upper bound on bucket
index "so a timestamp moved forward cannot age out live history and refill a cap", and
concluding that "the worst a nudged clock can do to a live mandate is shift the expiry
boundary."

The missing upper bound defends the **backwards** direction — a slot from the future stays
counted — and the named regression test for it (`Windows.t.sol`,
`test_ATTACK_backwardsClockCannotRefillTheWindow`) warps backwards. Forward drift is a
different matter, and the source comments inside `_checkAndCommitWindows` and
`policy.js` both scope the claim correctly to "a slot newer than `b`"; only `isLive`
generalises it to a direction where it is false.

Worked, with `L = 32, K = 32, S = 1, cap = 100`: at true t=0 and stated t=0, spend 100 —
bucket 0, ring slot 0, `{0, 100}`. At true t=31 with stated t=33 (drift 2s), `bucket = 33`
and `oldest = 1`, so slot 0's index of 0 fails `>= oldest`, `used = 0`, and a second 100
is accepted. The true trailing 32-second window at t=31 contains both: **200 against a
cap of 100.** The general threshold is drift > `subLength`, verified at `S-1`, `S` and
`S+1` across six geometries.

For the live Arc grant (`L = 86400, K = 24`, so `S = 3600`) the budget is an hour, which
is safe against any plausible proposer skew. For a `lengthSeconds = 32, buckets = 32`
grant — which `createMandate` accepts today — it is **one** second, and the smallest
constructible geometry (`lengthSeconds = 1, buckets = 1`, which passes all three window
checks) also has a one-second budget. Arc's docs say
timestamps come from the proposer's wall clock at one-second granularity and specify no
maximum accepted skew, so the margin cannot be bounded from the platform side.

The K+1 design buys exactly one sub-period of forward-drift immunity. That is a clean,
derivable number and it should be in the source instead of a claim that it is infinite.
**No existing test can see this**, because every window test records its ledger against
the stated clock, making real time and stated time the same variable — real time is
never an independent quantity in the harness, so no assertion can be written about the
gap between them.

There is a second, compounding reason the suite cannot see it: the smallest sub-period
any test ever *spends* through is `DAY / 24 = 3600` seconds. `WindowFuzz`'s `bucketsFor`
returns exactly `{2, 3, 4, 6, 12, 24}` over a fixed `lengthSeconds = DAY`, and
`WindowInvariant` pins `L = DAY, BUCKETS = 12`. So every spend in the suite happens in
the geometry where the drift budget is comfortable, and the geometries where it is one
second wide are the ones nothing exercises.

---

### F9 — `spendable` omits the `uint96` clamp that `spendableAcross` spends fifteen lines justifying

**Severity: note (unreachable with real USDC). Status: OPEN. Confidence: certain.**

`spendableAcross` hoists `maxSingleSpend = type(uint96).max` and clamps every term,
because `policyHeadroom` returns `type(uint256).max` for a mandate bounded only by an
expiry while `spend` refuses anything above `type(uint96).max`. `spendable` calls the
same `policyHeadroom` and applies no clamp. Of the two reasons given for the clamp,
overflow genuinely does not apply here — there is no addition — but *correctness of the
reported largest single spend* does.

Reachable only with a balance above 7.9e22 USDC against a ~6.1e10 USDC supply, so not
with real USDC. It **is** reachable with `MockUSDC`, which means the test suite can
observe two sibling views disagreeing about the same mandate. One line, and it makes the
pair consistent.

---

### F10 — `policyHeadroom`'s doc comment counts four blind spots. There are five.

**Severity: note. Status: OPEN. Confidence: certain.**

The comment opens *"Four things can still deny a spend this function calls affordable"*
and enumerates the allowlist, the cosign threshold, both ERC-8004 gates and the nonce.
It omits the unconditional `TotalSpentCeiling` guard: for a mandate without `F_TOTAL`
whose `totalSpent` is near 2^96, `policyHeadroom` reports `type(uint256).max` while the
true largest single spend is tiny.

Doubly unreachable (it sits behind F3's astronomical path) and worth listing only
because it is a *counted* claim in a comment. The #12 lesson was that the errors block
had asserted a one-to-one correspondence nobody had counted; the fix was to count it.
Same discipline, same file, one comment over.

---

### F11 — `withdrawCosign` is missing both guards its sibling has

**Severity: low. Status: OPEN. Confidence: certain.**

`approveCosign` checks `payer == address(0)` → `UnknownMandate`, then
`F_COSIGN == 0` → `BadConfig`, then `msg.sender != m.cosigner` → `NotCosigner`.
`withdrawCosign` checks only the third.

Not exploitable: for an unknown mandate `m.cosigner` is `address(0)`, and `address(0)`
cannot send a transaction, so the call still reverts. But it reverts with `NotCosigner`
where the truth is `UnknownMandate`, which misdirects whoever is debugging. Two further
consequences worth noting: a cosigner can emit `CosignWithdrawn` for a hash that was
never approved, putting a withdrawal in the audit trail with no matching approval; and
`revoke` likewise does not check `m.revoked`, so a mandate can be revoked repeatedly and
emit duplicate `MandateRevoked` events. For a contract whose product is a reconcilable
audit trail, event pairs that do not reconcile are a real if minor cost.

---

### F12 — A payer cannot enumerate outstanding co-signature approvals

**Severity: low. Status: OPEN (design note). Confidence: certain.**

`_cosignApproved` is a mapping keyed by hash, and `isCosignApproved` requires the caller
to already know the hash — which means knowing the exact recipient, amount, ref and
nonce. A cosigner may pre-approve any number of future spends, and the payer has no
on-chain way to ask how many live approvals exist or what they authorise.

The `CosignApproved` and `CosignWithdrawn` events make this fully reconstructable
off-chain, and the repository's stated position is that the audit trail lives in events
precisely because the Memo wrapper cannot be relied on. So this is consistent with the
design rather than an oversight. It is listed because "the payer can see what authority
is outstanding" is a property a payer would reasonably assume of an oversight control,
and it holds only with an indexer.

---

### F13 — Grant-time validation does not exist for the ERC-8004 gates, so a typo produces a mandate that looks healthy and can never spend

**Severity: low (fail-closed). Status: OPEN. Confidence: certain.**

`createMandate` checks that the registries are non-zero when the corresponding flag is
set, and that `minResponse != 0`. It does not check that `identity.agentId` exists, or is
owned by the named spender, or that any attestation exists under
`credential.requestHash`. So `F_IDENTITY` with `agentId = 0` — a struct field's default,
reachable by omission — yields a mandate that `isLive` reports true for and `spendable`
reports full headroom for, while every `spend` reverts `IdentityNotHeld`.

Fail-closed, so no funds are at risk; the failure mode is a payer who believes they have
delegated and has not. `policyHeadroom`'s comment already explains why the pre-flight
views deliberately make no registry calls, and that reasoning is sound. Grant time is a
different moment with different economics — it happens once, the payer is already paying
for storage writes, and it is the only point where a typo can still be cheaply refused.

**DECIDED 2026-08-26 — validate at grant.** Two registry reads when a gate flag is set,
paid once. The accepted cost, which should be written into the source beside the check so
it is not rediscovered as a surprise: `createMandate` now **reverts when a registry is
unreachable**, which is a new failure mode for a function that previously touched nothing
external. That is the correct trade for a control whose whole purpose is that the payer can
believe it — but it means the grant path acquires a liveness dependency the spend path
already had, and `isLive`/`policyHeadroom` must keep making no external calls, since their
justification is unchanged.

Related: `_checkCredential` returns `CredentialMissing` at three distinct sites — the
registry call reverting (`catch`), a zero validator address, and a response *below*
`minResponse`. A payer debugging cannot distinguish "no attestation exists" from "the
attestation says this agent failed", which are very different facts about their agent —
the first is an integration problem, the second is a reason to revoke. The overload is
conspicuous rather than systemic, because the same function's other three branches are
precise: `CredentialWrongValidator`, `CredentialWrongAgent` and `CredentialStale` each
name exactly one condition. Splitting out a `CredentialFailed` for the `minResponse` case
would cost one error declaration and make "my agent is failing attestation" legible.

---

### F14 — The ring clamp's parity comment claims a conservatism it does not have

**Severity: note. Status: OPEN. Confidence: certain (pure reasoning, no reachability question).**

`_checkAndCommitWindows` computes
`uint64 oldest = bucket > w.buckets ? bucket - uint64(w.buckets) : 0;` and explains the
clamp as follows: *"Clamp instead of subtracting: 0.8 reverts on underflow, and the JS
model can go negative where this cannot. **Clamping to 0 counts more history, never
less**, so it stays on the conservative side."*

The clamp is correct and the divergence from `reference/policy.js` is harmless, but not
for the stated reason: clamping counts **exactly** the same history, never more.
`oldest` is used in exactly two places, and both are insensitive to the difference.
Inclusion is `slot.bucketIndex >= oldest`, and every bucket index is non-negative, so
`idx >= 0` and `idx >= (some negative)` are both unconditionally true. Eviction is
`cur.bucketIndex < oldest`, and `idx < 0` and `idx < (some negative)` are both
unconditionally false. So in the only regime where the two implementations differ —
`bucket <= buckets`, i.e. a window younger than its own length — Solidity and JS include
the same slots and evict the same slots.

Worth a line because the sentence is doing real work: it is the stated justification for
a deliberate Solidity/JS divergence in the component with the highest defect history in
the project. "Identical, because every index is non-negative and therefore at least any
negative bound" is a stronger claim than "conservative" and is the one that is true. The
weaker version would survive a change that made it false — a signed bucket index, or a
negative sentinel — while appearing to still cover it.

This is the fourth entry in what is now a visible pattern (F4, F7, F8, F14): the guards
are right and several of the *reasons written beside them* are not. For a contract whose
comments are explicitly addressed to a future auditor, that is its own category of
finding, and it is the category this pass was best placed to find, since it requires
reading the prose against the code rather than either alone.



- **Whether a precompile-backed ERC-20 `transferFrom` on Arc executes recipient code.**
  Bears on F7. Settleable with one testnet transaction to a contract recipient that logs
  on receipt.
- **Economic and game-theoretic attacks on the whole arrangement**, as opposed to the
  contract in isolation. Not reachable by reading source.
- **The real Circle USDC contract.** Every test runs against `MockUSDC`. Arc's own
  porting guide is explicit that a local EVM "cannot reproduce Arc's precompiles,
  EIP-7708 `Transfer` events, or USDC blocklist enforcement."
- **The identity gate's and credential gate's positive paths.** Never executed against a
  real registry: no identity NFT has been minted to our agent, and the only real
  attestation on Arc Testnet carries a failing response of 1.
- **Griefing economics of a sponsored-submission path.** Arc documents that a blocklist
  revert consumes the submitter's gas with no transfer, which is a direct cost model for
  any relayer or paymaster Remit adds.
- **The maximum-cost spend.** `MAX_WINDOWS × (MAX_BUCKETS + 1) = 132` cold ring reads in
  one `spend` is what those two constants exist to bound, and **no test spends against a
  four-window mandate at all** — `Creation.t.sol`'s
  `test_createMandate_fourWindows_isAccepted` builds one, asserts `windowCount == 4`, and
  stops. So the worst case those two caps exist to make survivable has never been
  executed, let alone measured. This is the single cheapest gap on this list to close and
  it belongs in #14, since it needs a gas number anyway.
- **Three accepted window geometries are never spent through**, confirmed by enumerating
  every window constructed in `test/`: `buckets == 1` (a ring of two, which charges up to
  twice the nominal window — correct, and startling enough to deserve a test that says
  so), `buckets == 32` exactly, and `subLength == 1`. `WindowFuzz.bucketsFor` returns
  `{2, 3, 4, 6, 12, 24}`; its own comment says it covers "K from tiny to 24 (the precise
  end of the practical range)", which is an accurate description of the *practical* range
  and not of the *accepted* one. `createMandate` accepts K up to 32 and
  `lengthSeconds = 1, buckets = 1`.
- **`forge lint` on the v2 tree.** `windowRemaining`'s `uint64` cast carries no
  suppression comment where its twin in `_checkAndCommitWindows` does; whether that is a
  new warning is #14's to find out.

## 6. Method, and the enumeration behind §3

Three sweeps, two of them run independently and every claim from them re-verified against
source before it entered this document. Two agent claims were checked by hand and
confirmed (`spendCount` has exactly one write site and no guard; the contract contains no
multiplication at all); the `DESIGN.md` and Arc-documentation findings are mine and were
verified by reading both sources directly.

The displayed-but-unenforced sweep behind F1 enumerated **all thirteen `Mandate` fields
and all three gate structs**, asking of each: *can a mandate be created that displays
this via `getMandate` while nothing measures against it?* `payer`, `spender`,
`totalSpent`, `spendCount`, `flags`, `windowCount`, `revoked` and `notBefore` are read
unconditionally. `perTxCap`, `totalCap`, `cosigner` and the allowlist are pinned by
biconditionals. `cosignThreshold` is pinned by the one-directional rule added in #11.
`IdentityGate` and `CredentialGate` are written *only* when their flags are set, which is
the cleanest form of the guarantee and the pattern the others should be read against.
That leaves exactly one: `expiresAt`.

**What has not been swept:** the actor-versus-actor matrix is complete for the delegate
and for third parties but only partial for a hostile *cosigner* and a hostile *recipient*;
and no sweep has been done of the four other Solidity files or the deploy script.

---

*Nothing in this document should be read as a claim that Remit is secure. It is a claim
about what has been looked at, by whom, and how — which is the only kind of claim its
author is in a position to make.*
