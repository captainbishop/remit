# L3 — the shielded vault, as a Remit payer

Spec for privacy layer 3. Read `PRIVACY.md` first; this file assumes its position,
its leak inventory, and its naming rule. Task #39.

Status: **spec only.** Nothing here is built, and one of its conclusions is that L3
should not be built until a prerequisite outside this document is solved.

> *Line numbers into `contracts/MandateManager.sol` in this document refer to the **tagged
> v1 source** — `git show v1.0.0-arc-testnet:contracts/MandateManager.sol` — which is what
> they were written against and where they are still exact. v2 work has shifted them; see
> FORGE.md.*

Every line number below refers to `contracts/MandateManager.sol` at the deployed,
frozen revision, and every one was checked against the source rather than recalled.
The first draft of this document was checked a second time by an independent pass over
the contract; what that caught is recorded at the end, because four of the errors are
instructive and one of them is the exact mistake this document warns other people
about.

## What this changes about PRIVACY.md

PRIVACY.md used to state hazard 1 as: *"The vault must debit the depositor's
commitment atomically with the spend, and a mandate's cap must never exceed the proven
balance behind it."*

**The first half is unimplementable, and the second half is the entire solution.** The
correction has been applied to PRIVACY.md; this section records why.

Once the vault has granted a mandate and approved the allowance, a spend runs with
**no vault code executing at all**. The call path is
`agent → MandateManager.spend → usdc.transferFrom(vault → recipient)`. ERC-20 gives
the token holder no hook: there is no callback, no veto, no observation point. The
vault cannot be interposed as the spender either, because `spend` requires
`msg.sender == m.spender` (line 454) and the spender is the autonomous agent by
definition — making the vault the spender means the vault *is* the agent, which is a
different product.

The whole contract contains exactly three external calls: `usdc.transferFrom` (514),
`identityRegistry.ownerOf` (628), and `validationRegistry.getValidationStatus` (653).
All three targets are `immutable` (151-153), set once in the constructor (311-313),
with no setter — so **no per-mandate parameter can aim a call at the payer.** And both
registry calls are `view` calls from `private view` functions, which solc compiles to
`STATICCALL`: even in the impossible world where MandateManager had been deployed with
the vault as a registry address, a payer-as-registry could observe a spend but could
not write during one. Two independent reasons, which is the standard this project
holds itself to.

So there is no moment at which the vault can debit anything atomically with a spend.
Any design that needs that property is dead on arrival.

The fix is to move the debit earlier: **escrow at grant time.** Nullify the
depositor's commitment when the mandate is created, size `totalCap` to exactly the
nullified amount, and reclaim the unspent remainder afterwards from the public
`totalSpent`. This is strictly better than what PRIVACY.md described, because it needs
no atomicity the architecture cannot provide and it makes the safety property static
instead of dynamic.

The same fact that kills atomic debiting buys something real, and it is worth naming
in the same breath: because the vault is not in the spend path, **L3 adds zero gas to
a spend.** The measured 177,429-gas marginal spend is unchanged. The constraint and
the benefit are one fact seen from two sides.

## Architecture

The vault is a separate contract. It holds USDC, it grants an ERC-20 allowance to
`MandateManager`, and it calls `createMandate` — so line 371 records
`payer: msg.sender`, the vault, for every depositor, and `MandateCreated` and
`Transfer` name the vault rather than the person. That is the whole privacy mechanism,
and it is the one thing no commitment scheme can reach any other way.

**The load-bearing fact is that line 371 hardcodes `payer = msg.sender`.** No third
party can ever create a mandate whose payer is the vault. That, and not any check the
vault performs, is what makes it safe to grant `MandateManager` a pooled allowance at
all: the only mandates that can draw on the vault's balance are the ones the vault
itself created. If `createMandate` took the payer as a parameter, this entire design
would be unbuildable.

`MandateManager` is untouched. No flag bit, no redeploy, no metadata-hash break, no
addition to the audited surface of the contract that moves money. **L3 is therefore
not blocked by the v2 redeploy that L1 needs** — it is blocked by something else,
below.

Depositor flow, four steps, of which only the middle two are novel:

1. Deposit USDC. The vault mints a commitment into a merkle tree.
2. Prove ownership of an unspent commitment worth at least `e`. The vault nullifies
   it, mints a change commitment for the remainder, and calls `createMandate` with
   `totalCap == e`.
3. The agent spends against the mandate, directly on `MandateManager`, with the vault
   asleep.
4. After the mandate can no longer spend, release: the vault reads `totalSpent` and
   mints a commitment for `e − totalSpent`.

## The accounting invariant

For every mandate the vault has granted:

```
m.payer    == address(vault)
m.flags    has F_TOTAL and F_EXPIRY set
m.totalCap == escrow[mandateId]
```

and across the whole vault:

```
Σ unreleased mandates (escrow[id] − totalSpent(id))
    +  Σ unspent commitments
    +  gasReserve
    ≤  usdc.balanceOf(vault)
```

Three things about that sum are load-bearing and each was wrong in the first draft.

**It runs over *unreleased* mandates, not live ones.** A mandate before its
`notBefore` is not live (line 804) but its full `totalCap` is spendable later; a
mandate that is dead but not yet released is no longer spendable but the depositor's
claim to the remainder is not yet a commitment either. Summing over "live" mandates
drops the first case — permitting the vault to lend that money to another depositor —
and under-counts the second. Liveness plays no part in solvency. Only "has this escrow
been returned to the commitment tree yet" does.

**`gasReserve` is not padding.** On Arc, USDC *is* the native asset, so the vault's
USDC balance is also its gas balance. A contract cannot submit a transaction, so the
vault never pays gas directly — but the relayer this design requires has to be paid,
and the natural way to pay a relayer on Arc is in USDC out of the vault. Any such
reimbursement comes out of the same balance the invariant bounds against. It must be a
separate accounted term funded by fees or by the operator, never silently drawn from
depositor escrow. For the same reason the vault must expose no `payable` or
value-forwarding path and must never contain `SELFDESTRUCT`: on Arc a native-value
sweep moves depositors' USDC, and self-destruct hands the pool to the beneficiary.

**Cross-depositor safety is a conjunction, and `MandateManager` supplies only half of
it.** Line 486 (`newTotal > m.totalCap` reverts `OverTotalCap`) bounds each mandate
*individually*, permanently — `totalSpent` is written only at line 497, initialised at
377, and the cast at 485 cannot truncate because of the unconditional guard at 463. So
`totalSpent ≤ totalCap` for all time, enforced by the audited contract. But the *sum*
bound — the property that actually protects one depositor from another — exists only
because the vault escrowed each `totalCap` against a nullified commitment.
`MandateManager` has no concept of a pool and enforces nothing about the total. The
first draft claimed the guarantee lived "in the audited contract rather than the new
one"; that is the one reassurance this design cannot have, and pretending otherwise
would be the most dangerous sentence in the file.

Note that line 486 uses `>`, not `>=`, so `totalSpent` can reach exactly `totalCap`.
The release path must handle a zero-value change commitment rather than assuming a
positive remainder.

## What this means for `spendable()`

`policyHeadroom` (834-849) starts at `type(uint256).max` and mins in `perTxCap`,
`totalCap − totalSpent`, and each `windowRemaining`; `spendable` (864-872) then clamps
to `allowance(payer, MandateManager)` and `balanceOf(payer)`. With `F_TOTAL` forced,
the result is bounded by that mandate's own remaining cap no matter how large the pool
is.

The first draft claimed the vault's invariant is what makes `spendable` "honest" for a
pooled payer. That was the wrong word. `spendable` is already honest — for any single
call it reports what would actually succeed, because the balance and the allowance are
real and the spend really would move pool USDC. What it cannot express is that the
money is someone else's. The escrow accounting makes the number **attributable**, not
truthful.

Two corollaries. Under the exact-sum allowance policy below, the allowance clamp never
binds for a vault mandate, since the allowance is the sum of all remaining caps and
therefore at least any one of them. And without `F_TOTAL`, `policyHeadroom` returns
`type(uint256).max` and `spendable` reports the **entire pool** as available to a
single mandate — still technically honest, and exactly the disaster the next section
prevents.

## Two flags the vault must force, and why each

**`F_TOTAL` is mandatory, and `MandateManager` will not enforce it — in either version.**
The `hasBound` check at line 353 is satisfied by `F_PER_TX` *or* `F_EXPIRY` *or* any
window, so `F_TOTAL` is not required for a valid grant. A vault-granted mandate carrying
only `F_PER_TX` would let the agent spend `perTxCap` repeatedly until the pool was empty,
and `Unbounded()` would never fire. The vault must require it in its own code. One
convenience: line 360 couples flag to value as a biconditional
(`(flags & F_TOTAL != 0) != (p.totalCap > 0)` reverts `BadConfig`), so requiring
`totalCap > 0` is sufficient to force the flag.

**v2 narrows that check and it still does not help the vault, which is worth being
explicit about rather than leaving as an inference.** v2 accepts `F_TOTAL` *or*
`F_EXPIRY` only — a per-transaction cap and a window are no longer bounds, which is
finding F5 in `THREAT-MODEL.md`. But the next section requires the vault to force
`F_EXPIRY` for escrow liveness, so a vault mandate satisfies v2's guard on the expiry
alone and `F_TOTAL` remains unrequired by the contract. The narrowing removes the
specific `F_PER_TX`-only shape described above and leaves the hole the vault actually
cares about wide open: an expiry-only mandate against a *shared* pool lets the agent
spend the whole pool before the deadline arrives, which is the entire failure the
`F_TOTAL` requirement exists to prevent. This is a general property worth carrying into
any other contract built on Remit — **a grant-time bound the platform enforces for its
own reasons is not a substitute for the bound your own design needs**, and the two
being spelled with the same error name makes that easy to miss.

**`F_EXPIRY` is mandatory for escrow liveness.** Escrow can only be released when no
further spend is possible. Without the flag, `expiresAt` is ignored entirely — both
line 452 in `spend` and line 806 in `isLive` gate the comparison on it, and line 364
only validates `expiresAt > notBefore` when it is set — so an unrevoked mandate stays
live forever and its escrow is locked forever, with the depositor's funds depending on
the agent or the vault choosing to act. Requiring `F_EXPIRY` gives every escrow an
unconditional release date that needs no cooperation from anyone.

The vault must also bound the term, because `expiresAt` is a `uint40` good past the
year 36000 and an unbounded one is a permanent lock dressed as a mandate. Cap
`expiresAt − block.timestamp` at some `maxTerm`. Usefully, that single cap also bounds
`notBefore` transitively, because line 364 forces `notBefore < expiresAt` — so the
pre-window lock worried about below cannot be stretched either.

## The release condition, and a trap in the obvious helper

Release requires:

```
m.revoked  ||  ( (m.flags & F_EXPIRY != 0)  &&  block.timestamp >= m.expiresAt )
```

**Do not use `!isLive(mandateId)` for this.** `isLive` also returns false *before*
`notBefore` (line 804), during a pre-window in which the mandate has not started but
absolutely will. A vault that released escrow on `!isLive` would mint a change
commitment for the full amount, then watch the mandate go live and let the agent spend
the same USDC again. That is a double spend of pool funds reachable by setting
`notBefore` in the future — a parameter the depositor chooses.

This is the sharpest edge in the design, and it comes from reaching for a helper whose
name reads like the condition you want. `isLive` answers "can this spend right now",
which is not the same question as "can this ever spend again".

**The flag test in that predicate is not decoration, and the first draft omitted it.**
Written as bare `block.timestamp >= m.expiresAt`, the condition is *true from birth*
for any mandate without `F_EXPIRY`, since `expiresAt` is then an unvalidated field
that may be zero — an instant release of an escrow that can still be spent in full.
The first draft relied on `F_EXPIRY` being forced two sections earlier, which is true
but leaves a code block that is unsafe if anyone copies it alone. That is the same
class of error as the trap this section exists to describe, made in the act of
describing it.

**v2 makes this worse rather than better, which is the opposite of what a reader would
expect from a validation being added.** v2 refuses a grant that sets `expiresAt` with
`F_EXPIRY` unset (finding F1), so zero stops being one possible value of an unvalidated
field and becomes the *only* legal value. The bare predicate is therefore no longer
merely capable of being true from birth — under v2 it is true from birth for **every**
mandate without the flag, without exception. A validation that removes a variant can
tighten a bad assumption into a certainty, and the flag test is what makes the predicate
correct in both versions.

With the predicate written completely, `totalSpent` is provably final at release.
`revoked` is written only at 383 (`false`, at creation) and 705 (`true`), there is no
un-revoke, and line 346 makes a `mandateId` single-use forever so the struct can never
be reset — after which `spend` reverts at 444 permanently. On the expiry side `spend`
reverts at 452, Arc timestamps are non-decreasing so the condition is monotone, and
line 364 guarantees `expiresAt > notBefore`, so there is no configuration where the
condition holds while a spend can still land. A mandate born already expired is born
dead with `totalSpent == 0`, which releases correctly. A release and a spend in the
same block read the same `block.timestamp`, so exactly one of the two succeeds.

`totalSpent` also survives revocation — `revoke` (701-707) sets only `revoked = true`,
with no zeroing — and `getMandate` (760-762) returns the whole struct. So the refund
figure is readable on chain by anyone.

## Depositor revocation: pooling removes it, and the spec has to give it back

`revoke` requires `msg.sender == m.payer || msg.sender == m.spender` (line 704). The
payer is the vault. **So the depositor cannot revoke their own mandate, and the vault
can revoke anyone's.** Revocation is the headline feature of the primitive — the thing
a payer relies on when an agent misbehaves — and pooling silently transfers it to the
operator.

Three ways out, and only one is acceptable. An open `revokeFor(mandateId)` on the
vault lets anybody grief any depositor. No revocation path at all makes the vault
strictly worse than direct Remit for the case that matters most. So the vault needs an
*authenticated* per-mandate revoke, which means the circuit must also prove
authority-to-revoke for a given `mandateId` — a public input the first draft's list
omitted entirely. Design the commitment so that a depositor retains a revocation
secret bound to the mandate they created.

One consolation and one caution: the spender can still revoke (line 704), so a
compromised agent can shut itself off without asking anybody, exactly as in base
Remit; and because a spender-initiated revoke forces early release, the vault's
release path must tolerate revocation it did not initiate.

## What the circuit must prove, and what the vault must never accept

Without designing the circuit: public inputs must include the escrow amount `e`, the
nullifier, the change commitment, the mandate salt, **and a revocation authenticator**
per the section above. The proof establishes knowledge of an unspent commitment of
value `v ≥ e` and correct construction of the change commitment for `v − e`.

**The vault must compute `totalCap` from the proof's public input and never accept it
as a caller parameter.** If the depositor supplies `totalCap` separately, they prove
escrow of `e` and grant themselves a mandate for more. This is the single most
important line of the vault's code.

`salt` must not be a function of the depositor. Line 345 derives
`mandateId = keccak256(abi.encode(DOMAIN, block.chainid, <MandateManager address>, msg.sender, salt))`
with `msg.sender` constant at the vault, so the id leaks nothing — unless the salt is
a per-depositor counter or a hash of their address, in which case it leaks everything.
Deriving it from the nullifier is safe, and for a reason worth stating precisely: the
nullification and the `createMandate` call happen in the same transaction, so they are
already linked and `salt = f(nullifier)` reveals nothing new. A reused salt reverts
`MandateExists()` at 346, which is correct but should be surfaced legibly.

### The cosign footgun, stated correctly

The vault should refuse a configuration whose cosign gate can never fire, since it is
the depositor's own control being silently disabled. But the condition is **not**
`perTxCap < cosignThreshold`, which is what the first draft wrote and what
`CHANGELIST.md` said until this section was written.

Line 492 tests `amount > m.cosignThreshold`, strictly, and line 476 caps
`amount ≤ perTxCap`. So `perTxCap == cosignThreshold` is *also* dead, and this repo has
a live receipt proving it: `DESIGN.md:1272` records a 50,000 spend against a 50,000
threshold that did not trip the gate on Arc Testnet. The test is `perTxCap <=
cosignThreshold`.

It is also incomplete when `F_PER_TX` is unset, where the real ceiling is
`min(totalCap, window caps)` — so `totalCap = 100` with `cosignThreshold = 100` and no
per-transaction cap is equally dead and passes both versions of the naive check. The
vault should compare the threshold against the effective maximum spend implied by the
whole policy, not against one field. **This also means the `CHANGELIST.md` entry for
the v2 grant-time revert is stated with the wrong operator and should be corrected
there before v2 is cut.**

**Superseded, in the best way: `MandateManager` v2 does this itself.** The correction was
carried into `CHANGELIST.md` and then implemented, so the vault inherits the guard rather
than reimplementing it — a grant that a depositor's vault forwards to `createMandate` is
refused by the mandate contract before the vault has to have an opinion. Two amendments to
the paragraphs above follow from the implementation. The effective maximum includes a term
this section missed, `2^96 - 1`, which binds when the depositor set no amount bound at all;
and the enumeration turned up two further dead-gate shapes the vault would also have
forwarded happily, a threshold stored with `F_COSIGN` unset and `cosigner == spender`. The
second matters more here than in the base contract, because a vault that lets a depositor
name the spender as its own cosigner has built a supervision gate the spender operates. Both
are now refused underneath the vault. What the vault still owes its depositor is the *error
message*: `BadConfig` arriving from a nested call is legible to a developer and not to a
person, so the vault should pre-check and explain rather than forward and relay.

### The pass-through fields, and why "only narrows" is not the same as "harmless"

Every remaining policy field can only *narrow* authority. Windows add a constraint
(584), the allowlist restricts recipients (459), the identity gate adds
`ownerOf(agentId) == msg.sender` (634-635), and the credential gate adds requirements
(664-683). I looked specifically for a configuration that raises a cap and there is
none. On authority, pass-through is safe.

On **cost**, it is not, and the first draft's "without endangering the pool" overreached
on three counts.

Spend gas is depositor-controlled and can be inflated by roughly 230,000. `MAX_WINDOWS`
is 4 and `MAX_BUCKETS` is 32, giving ringSize 33 apiece, so up to 132 ring SLOADs per
spend in the loop at 555-582. The live spend used one 24-bucket window and cost
216,458; at the contract's own figure of ~2,150 gas per bucket (line 545), a maximal
configuration more than doubles every spend.

The credential gate makes spend gas effectively unbounded. The `getValidationStatus`
tuple decoded at 653-655 contains a `string` that the contract does not even keep — it
is unnamed in the destructuring and discarded — but it is decoded into memory before it
can be discarded, and memory expansion is quadratic in length. The depositor selects
which attestation is read via `requestHash`, so a large string inflates every spend or
runs it out of gas, with the `catch` at 660 converting an OOG into `CredentialMissing`
and hiding the cause. The cost is set by third-party registry state the depositor picks,
not by any constant in `MandateManager`.

The allowlist length is uncapped. Contrast line 368's `p.windows.length > MAX_WINDOWS`
with the loop at 400-403, which has no length check and performs a cold SSTORE per
entry. Grant cost is therefore unbounded depositor-chosen input.

For a depositor with their own agent all three are self-harm. **They become
cross-depositor the moment the vault adopts the shared agent that hazard 2 below
recommends** — one depositor then sets the gas bill that a shared, vault-funded agent
pays on everybody's spends. And the uncapped allowlist is paid by the relayer that
this design makes a prerequisite. So the vault should cap allowlist length, cap total
window buckets, and either forbid the credential gate or bound the attestation it will
accept.

## Allowance policy

The vault must approve `MandateManager`, and there are two shapes.

Exact sum, re-set on every grant and release, costs an allowance write each time —
this repo's measured allowance reset is 38,338 gas. Infinite approval costs nothing
after the first call, but then the vault's own `F_TOTAL` enforcement is the only thing
between one bad grant and the entire pool.

**Take the exact sum.** The extra 38,338 is defence in depth in exactly the situation
that justifies paying for it: a pooled contract where a single mis-granted mandate
damages other people's money rather than the granter's. The generic argument for
infinite approval — that the payer only risks their own funds — does not apply to a
vault.

Two things the first draft left out. The allowance is a **single shared scalar**, so it
must be recomputed from live state on every grant and release, never incremented or
`approve`d to one mandate's figure — a naive `approve(newCap)` erases every other
depositor's spendability at a stroke. And if it is ever under-set, the first mandates
to spend consume it and the rest fail: no solvency loss, since a failed
`transferFrom` reverts the whole spend at 514 consuming neither cap nor nonce, but a
genuine shared liveness failure that the defence-in-depth argument does not mention.

## Hazard 2: the delegate is a pseudonym, and gas is the real problem

`MandateCreated` and `Spend` are both indexed on the spender, so a depositor who
brings their own agent has published a stable pseudonym and the vault's payer privacy
is cosmetic. PRIVACY.md says delegates must be "one-time, or genuinely shared". Both
options have a cost that was not stated:

A one-time agent per mandate has zero USDC, and on Arc USDC *is* gas, so a fresh agent
cannot submit anything until it is funded — and whoever funds it creates the linking
transaction the fresh address existed to avoid. This is L2's stealth-sweep
bootstrapping problem reappearing one layer up, in the same shape.

A shared agent across all depositors makes `spender` constant and uninformative, but
it is then a single compromise point over every depositor's mandate; "bounded authority
for *my* agent" quietly becomes "bounded authority for *everyone's* agent"; and, per
the section above, it converts depositor-chosen gas inflation from self-harm into a
cost imposed on the pool. The trust story changes rather than improving.

Underneath both sits the finding that matters most in this document.

**L3's payer privacy is capped by gas-payer privacy, and it binds on the grant, not
just the spend.** `createMandate` is a transaction. Whoever submits it appears as the
transaction's `from`, permanently, next to the `mandateId` they just created. If a
depositor submits their own mandate creation, their address is on chain beside their
mandate and the vault has hidden nothing at all.

PRIVACY.md lists "whoever pays gas leaks" under what no layer can do, framed as a
correlation risk at the margin. For L3 it is not marginal and it is not a
correlation — it is a direct, sufficient deanonymisation of the exact fact L3 exists
to hide.

The consequence is a sequencing constraint, stated plainly: **a shielded vault whose
mandates are created by depositor-submitted transactions is strictly worse than no
vault at all.** The depositor surrenders non-custody and receives no privacy in
exchange. Gas abstraction — relayer, paymaster, or 7702-delegated submission — is a
*prerequisite* for L3, not a follow-on refinement.

That is the same prerequisite L2 needs for sweeps. One dependency bounds both privacy
layers.

**But it is not a missing chain feature, and the first draft of this section assumed it
was.** Researched against Arc's own documentation on 2026-08-25: ERC-4337 with EntryPoint
v0.7 and USDC-funded paymasters is live on Arc testnet, and EIP-7702 set-code transactions
behave as on Ethereum. Under 4337 the grant originates from a smart account rather than the
depositor's EOA, which is exactly the property this section demands. So the gate is open;
what is missing is a sponsorship *policy* of ours, not a capability of Arc's. I inferred a
chain limitation from the fact that Arc's tutorials use a plain EOA, which is not evidence
of anything. Details, including the EntryPoint address and the caveat that Arc's own page
flags it as needing verification, are in `GAS-ABSTRACTION.md`.

Two costs come with the fix, and neither was in the first draft. **A sponsor sees who
asked** — L3's payer privacy is *shifted to the sponsor*, not eliminated, and a depositor's
privacy set is whoever shares their paymaster; Arc documents a single third-party bundler
as the standard path, so disclose it and never let "relayed" be heard as "trustless". And
**a blocklisted `from` or `to` reverts at runtime while consuming the submitter's gas**,
which is documented Arc behaviour — so a sponsor that does not screen recipients before
submitting is a free denial-of-wallet target, and the depositor-controlled gas inflation
described above is charged to the sponsor rather than to the depositor.

## Hazard 3: amounts, and four leaks the first draft missed

A vault-to-external spend publishes amount and recipient three times over — Remit's
`Spend`, USDC's `Transfer`, and Arc's EIP-7708 native emitter at `0xffff…fffe`. None
of those is Remit's to suppress. The payment amount is the vendor's invoice and it is
public. There is no version of this design in which it is not.

Quantising escrow into fixed denominations was the first draft's one constructive
proposal — `totalCap` is public in `MandateCreated` and `getMandate`, so an arbitrary
escrow fingerprints the depositor's deposit, and standard denominations put many
depositors behind one value at the cost of capital efficiency. It survives, but weaker
than advertised, for four reasons found on review.

**The release amount is public, so the change commitment's value is known.** Both
`totalCap` and `totalSpent` are public, so `e − totalSpent` is public — the commitment
minted at release has a fully known value, and every later use of it is fingerprinted
by that value. This follows directly from reclaiming the remainder from on-chain state,
and it partly defeats quantisation, which produces *odd* residuals by construction.

**Quantising `totalCap` alone does not build a crowd.** `MandateCreated` also carries
`perTxCap`, `notBefore`, `expiresAt`, `flags` and `windowCount`. That tuple is a
high-entropy template fingerprint, and a depositor who grants twice with the same
shape has linked their own mandates to each other. Quantisation has to cover the whole
visible parameter vector or it accomplishes very little.

**Grant calldata leaks more than the events do**, and calldata is permanent.
`p.allowlist` publishes the depositor's entire intended counterparty set at grant
time — including their own withdrawal address, if allowlisted, long before any money
moves. `p.identity.expectedOwner` is typically an address the depositor pins to
themselves. `p.credential.validator` names a chosen third party. None of these has a
getter — `_identity` and `_credential` are private with no accessor — which makes them
easy to audit past, since they are visible only in the transaction that set them.

**`recipient == vault` is a legal spend.** It consumes `totalSpent` and allowance
while leaving the pool balance unchanged, so a compromised agent can burn a
depositor's escrow into unattributed pool surplus. Arc additionally emits no EIP-7708
system log for a self-transfer, so a vault reconciling escrow from logs would not see
it at all. Reconcile from `getMandate(mandateId).totalSpent`, never from transfer logs.

> **This paragraph is where the general form of the problem was found, and for a day it
> was filed only here.** It is not a vault-specific hazard: `recipient == m.payer` is a
> legal spend on *any* mandate, and the reconciliation hole is the same for a payer with a
> payroll bot as for a vault. It is now `THREAT-MODEL.md` **F19**, where a payer will
> actually read it, and the self-transfer rule this paragraph asserts has since been
> confirmed against Arc's `usdc-system-events` reference — *"self-transfers (`from == to`)
> emit no log"* — where before it was an unsourced claim. Keep both: this one for the vault
> reader, F19 for everyone.

Withdrawal deserves its own warning. A depositor who has their agent pay *themselves*
has published their own address as `recipient` and undone the vault. Withdrawals need
a distinct path — prove a commitment, transfer to a fresh address, submitted through a
relayer — and the fresh-address requirement falls on the depositor, not the contract.

So L3's amount story is: the escrow amount can be padded into a crowd only if the
whole parameter vector is padded with it, the residual is public regardless, the
payment amount cannot be hidden at all, and vault-internal transfers publish nothing
but help only in proportion to how many counterparties are inside. Payer privacy on
day one; amount privacy as a network effect, if ever.

## What pooling costs that individual payers do not pay

Non-custody holds for base Remit and does not hold for L3 depositors. PRIVACY.md
already says so and frames it as a choice, which is right. Three costs deserve
sharpening.

Escrowed funds are exposed to the vault's own bugs, and the vault is new code holding
other people's money — the category this project has been most careful about
everywhere else. Note also the deployed contract's own scope note (lines 69-85): a
mandate is a real cap only when `MandateManager` is the sole path to the payer's funds.
For an EOA payer that is a statement about approvals. For a vault it is a statement
about the vault's own code, which must therefore have **no other USDC-moving path at
all**.

Circle's freeze authority over USDC applies to the vault's address, and freezing the
vault freezes **every depositor simultaneously**. PRIVACY.md notes that aggregate
holdings stay visible and freezable; the part worth saying out loud is that pooling
converts individual freeze risk into shared fate. A payer holding their own USDC is
exposed to being frozen; a depositor in the vault is exposed to *anyone* in the vault
causing a freeze.

Revocation is no longer the depositor's, unless the circuit gives it back — see the
section above.

The anonymity set is the number of unreleased mandates the vault has outstanding — not
the number of depositors, not the number of deposits. A depositor with one mandate
among three is in a set of three, and the first depositor is in a set of one.

## Sequencing

0. **Ask Circle about the Arc Privacy Sector timeline.** Added 2026-08-25, and it precedes
   everything else: Arc documents a confidential execution environment that would deliver
   most of this document's purpose as a deployment target, marked "on the roadmap and not
   yet available" with no date. Committing to a circuit without asking would be
   negligent. See `PRIVACY.md` and `GAS-ABSTRACTION.md`. Everything below stays true
   whatever the answer — the contract findings are facts about `MandateManager` — but the
   order changes.
1. Decide the sponsorship policy for grant *and* spend submission. This is no longer
   "solve gas abstraction": Arc already has 4337 and 7702. It is choosing a sponsor,
   screening recipients so a blocklisted address cannot burn the sponsor's gas, and
   capping depositor-inflatable spend gas so the sponsor is not the victim of it.
2. Then build the escrow accounting, the invariant, the release predicate, the forced
   flags, the parameter caps and the allowance recomputation, with a full test suite
   under the deep profile. All of it is testable against a placeholder verifier: the
   money-loss bugs in L3 are not cryptographic, and every error the review of this
   document caught was in this layer.
3. Then the circuit, the verifier, nullifier handling, the revocation authenticator,
   and the trusted-setup-or-transparent-proof decision.
4. Counsel before real money, per PRIVACY.md.

The ordering matters: the security-critical part of L3 has nothing to do with ZK, so
building it first means the hard part is tested long before the cryptography arrives.

## What L3 may truthfully claim

**Payer privacy**, and only when the grant is relayed. Unchanged from PRIVACY.md's
naming section, which was already correct. Never "private payments": amounts and
recipients stay public, the residual escrow value is public, and the payer privacy on
offer is bounded by the size of the outstanding-mandate set and by trust in whoever
submits the transaction.

## What the review of this document caught

The first draft was checked against the contract by an independent pass. It confirmed
the central architectural claim — no payer code runs during a spend — and strengthened
it with the STATICCALL argument. It also found four errors and eight omissions, all now
folded in above. Four are worth naming, because of what they have in common.

**The invariant summed over "live" mandates.** Same word, same trap, same document as
the `isLive` warning. Having identified that liveness is the wrong question for escrow
release, I then used liveness as the filter for escrow solvency, one section later.

**The release predicate omitted the `F_EXPIRY` test**, making the copy-pasteable code
block an instant release of a fully spendable escrow. Written into the very section
whose purpose is to warn against a nearly identical mistake.

**Cross-depositor safety was attributed to line 486.** It is a conjunction: line 486
bounds each mandate, the vault's escrow bounds the sum. Claiming the audited contract
carried the whole guarantee was the most comfortable sentence in the draft and the
least true.

**The cosign check was off by one**, and this repository already held a live Arc
receipt disproving it — a 50,000 spend against a 50,000 threshold that did not trip
the gate, recorded at `DESIGN.md:1272`. The correct operator is `<=`, and the check is
incomplete without `F_PER_TX` anyway. `CHANGELIST.md` carries the same error and needs
correcting before v2.

The pattern is the one this project keeps rediscovering: the claim that never got
checked against a second method is the one that was wrong. Three of the four were
reachable by reading the contract, which I had open. The lesson is not "read more
carefully" — it is that a design document about a money-holding contract gets an
adversarial second pass before anyone starts building from it, and that the pass should
be given the contract rather than the document's own summary of it.
