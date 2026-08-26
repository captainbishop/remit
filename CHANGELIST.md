# Redeploy changelist

## Why this file exists

`MandateManager` has no proxy, no `initialize`, no `upgradeTo`, no `delegatecall`,
no `selfdestruct`, and no owner or admin role. It has a constructor and three
`immutable` fields. It cannot be modified after deployment by anyone, including
its authors.

> *Line numbers into `contracts/MandateManager.sol` in this document refer to the **tagged
> v1 source** — `git show v1.0.0-arc-testnet:contracts/MandateManager.sol` — which is the
> deployment each item is proposing to change. v2 edits have shifted the working tree; see
> FORGE.md.*

That is deliberate and it is the strongest thing the contract does. A payer who
grants a mandate is trusting the rules they read, not the people who wrote them.
An upgrade hatch would mean that trust was misplaced — whoever held the key could
raise a cap, drop an allowlist, or remove a cosigner requirement after the fact.
The absence of an upgrade path is the feature.

The cost of that choice is that "fix the contract" always means "deploy a new
contract at a new address and migrate." This file is the list of what would go
into that next deployment, so the decision is made once, deliberately, from a
written list — rather than piecemeal every time something turns up.

## Standing answer: has a bug been found since deployment?

**No.** As of 2026-08-25, with seventeen live transactions sent to
`0x3744E93B9e796E05CB66311d897559B6F3860196` and five live mandates exercised
against it — **thirty-one live transactions in total**, every one with `status 1`,
once the two contract deployments, Arc's own USDC and the stand-in token used for
the premium measurement are counted — nothing discovered on-chain has been a
defect in the deployed bytecode. All five state-changing functions have now run
live. That total is derived by counting distinct transaction hashes in
`evidence/` and pairing each with its target address, not by incrementing a
remembered figure, which is how the previous count of twenty-seven came to omit
`MandateManager`'s own deployment while including MockUSDC's.

What has actually been found sorts into four piles, and the distinction matters:

**Documentation errors — real, need fixing, cost nothing.** The published
marginal spend of ~142,500 gas was wrong; it compared a *first-ever* spend
against a bare transfer. The true steady-state marginal spend is 177,429 and the
policy overhead is 103,479, with 216,458 being the worst case rather than the
typical one. Separately, the contract size was published as 11,964 bytes when
the measured figures are 11,572 runtime and 11,868 initcode. Both are fixed in
prose, not in Solidity.

**Assumptions the contract already got right, now confirmed against live data.**
The 6-decimal truncation of Arc's 18-decimal balances was already documented
correctly at `MandateManager.sol:856-863`, including the direction of the error.
`getValidationStatus` really does return the six-value tuple the interface
expects. `ownerOf` really does revert for a nonexistent token rather than
returning the zero address — Arc's registry is OpenZeppelin v5 and raises
`ERC721NonexistentToken(uint256)` (`0x7e273289`), so the `try/catch` at line 628
has something real to catch. These are verifications, not discoveries, and a
local mock could not have established any of them.

**Design warts that were known and documented before deploying.** The credential
gate accepts an attestation with no agent binding, which has a test named after
the fact. A cosign threshold at or above the mandate's own spend ceiling is accepted at
grant time, producing a gate that can never fire — see the corrected statement of that
condition below; the version of it recorded here for weeks was off by one. Whether an
EIP-7702-delegated EOA counts as an EOA on the Memo and Multicall3From paths is
unresolved. None of these are new information.

**My own analysis mistakes, with zero contract impact.** The direction of the
cosign gas delta, a 160,000 prediction that came in at 193,837, a mis-designed
allowance-ceiling test, three refuted balance-rounding models, and a call to a
`getBucket` view that does not exist. All corrected in the record.

## When to cut the next deployment

Not yet, and for a concrete reason beyond tidiness.

Every gas figure measured this session is a property of *this exact bytecode*
compiled at `optimizer_runs = 200`. The 177,429 marginal spend, the 38,338
allowance reset, the 20,164 cosigner-slot delta, the 388-gas cosign gate, the
~5,333 first-credit premium — change one line and every one of those moves, and
the baseline that took a full session to establish is gone. The two live mandates
and their spend history are also tied to this address; a new deployment orphans
them and the ring-bucket state has to be rebuilt from scratch.

So: finish the live investigation against this deployment first. Cut v2 when the
ERC-8004 gate work (#32) is done, the 53,114 question (#31) is settled, and the
docs are corrected (#33) — then make every change below in one pass, re-run the
140 tests plus `forge test --profile deep`, redeploy, and re-measure.

*Status, 2026-08-25:* #32, #33, #44 and #45 are all done, so the live
investigation against this deployment is complete — all five state-changing
functions have receipts. #31 was answered on 2026-08-24 and **that answer was
wrong**: the 53,114 match is real, because `forge test --gas-report` includes
intrinsic gas for state-changing functions and the two figures were on the same
basis all along. See the closing section of `DESIGN.md`. Settling #31 the first
time did expose a real problem with the published USDC premium numbers, which #42
fixed by receipt-vs-receipt measurement that never used the harness — that fix
stands and is strengthened, since the harness deviations it distrusted are now
known to be harness error outright.

**One consequence for this changelist.** Every v2 gas estimate for a function that
does not touch USDC can be read straight off `forge test --gas-report` and will
match the eventual Arc receipt to within a calldata byte. That covers
`createMandate`, `revoke`, `approveCosign` and `withdrawCosign`; only `spend`
needs Arc's measured `transferFrom` premium of 13,110 added. Cost the changes
below before redeploying rather than after.

*The pre-audit gate is also now green, which unblocks the "re-run" half of the plan
above.* `FOUNDRY_PROFILE=deep forge test` was run on 2026-08-25: 140 passed, 0 failed,
15m52s, no counterexample. Each of the three invariants ran 512,000 handler calls
against 16,384 by default, and each of the four fuzz properties ran 20,000 cases
against 512. Evidence in `evidence/deep.log`, including the config dump that proves the
profile actually resolved.

*And one number in the plan above moved, which is worth naming because it is a v2
input.* Regenerating `evidence/gas.log` on the same day — it had never been rebuilt
since the root commit and still claimed 136 tests across 9 suites — shifted two
published figures. The `spend` median went from 110,380 to **105,935**, because the old
log was unseeded and the median is not reproducible without a pinned seed. The
deployment cost went from 2,557,693 to **2,557,681**, twelve gas, and that one is
**unattributed**: the contract is frozen, and restricting the run to the old log's exact
9 suites and 136 tests still gives 2,557,681, so it is not the four ArcParity suites
added since. Both corrections are in `DESIGN.md`, `README.md`, `START-HERE.md` and
`foundry.toml`. Neither disturbs a v2 decision below, but cost v2 off the regenerated
file, not off the old one.

## The changelist

**~~Certain, and free.~~ DONE in v2.** Update the file-header banner in `MandateManager.sol`. It was
correctly rewritten at deploy time — `NOT DEPLOYED. NEVER RUN AGAINST A LIVE CHAIN`
became `NOT AUDITED. LIVE ON ARC TESTNET SINCE 2026-08-24`, because the first was
false the moment the contract landed and a banner that lies trains readers to ignore
it. But its body has since gone stale: it says "one mandate has been granted and one
spend executed live" and "cosignature, both ERC-8004 gates and revoke have 139 passing
tests and zero live transactions." As of 2026-08-25 there are **five** live mandates,
**five** spends, three revocations, and **thirty-one** live transactions all with status 1;
cosignature now has four of them, both ERC-8004 gates have been exercised against Arc's live
registries, and neither `revoke` nor `withdrawCosign` is an exception any longer. The
replacement banner **may** say that every state-changing path has run live, which is newly
true and was false in every earlier draft of this note — but it must say **five** such paths,
not six. The list has always been `createMandate`, `spend`, `revoke`, `approveCosign`,
`withdrawCosign`; the count beside it said six for weeks because nobody parsed the source.
The test count is now 140. The unaudited / no-real-money half of the warning stays exactly
as it is.

The spend count in that paragraph said **four** until 2026-08-26, in the same sentence as
the correct total of thirty-one, which is how it was caught: a figure that moves with the
total and a figure that does not cannot both be current. Derived rather than remembered —
`Spend`'s topic0 is `0x8d09fb84…28b7`, and five distinct `transactionHash` values in
`evidence/` emit it, at blocks 58564785, 58593010, 58596088, 58599519 and 58667292. Only
the last of those postdates 2026-08-24, which is why `DESIGN.md`'s "five mandates, four
spends" is right where it stands — that sentence is explicitly scoped to the close of that
day — and this one was not. **Anything copied into the v2 banner gets re-derived from
`evidence/` first, not carried across from here.**

Line 26 of that banner also carries two superseded gas figures — `~142,500` for the
policy machinery and `~32,700` for Arc's native-USDC accounting. Both are corrected
elsewhere in the tree as of 2026-08-24: the policy overhead is **103,479** gas
(0.217 cents), measured as the steady-state marginal spend of 177,429 less a bare
transfer of 73,950 rather than a first-ever spend of 216,458, and the token premium is
**13,110** on a `transferFrom`, measured receipt-against-receipt in
`evidence/premium.log`. The replacement line should read: *"of which ~103,500 is the
policy machinery and ~13,100 is Arc's own native-USDC accounting."*

**Why this one waited, and what released it.** Solc appends a hash of the source
metadata to the bytecode, so editing even a comment changes the compiled bytes. The
deployment at `0x3744E93B9e796E05CB66311d897559B6F3860196` is verified against the tree
as it stood, and `FORGE.md` made that claim about the *working tree* — so any edit to
`contracts/MandateManager.sol`, a banner included, would silently retire a checkable
property in exchange for fixing a comment already published on Blockscout and
unrecallable there anyway. That is why the file was frozen from 2026-08-24 to 2026-08-26.

**Released on 2026-08-26 by tagging rather than by deciding the property was cheap.**
Commit `e040eba` — the last commit whose tree reproduces the live deployment — is now the
annotated tag `v1.0.0-arc-testnet`, whose message carries the address, the deploy
transaction, the compiler settings and the `DOMAIN` constant. `git checkout
v1.0.0-arc-testnet && forge build` reproduces the verified bytes forever, so the property
is preserved at a *name* instead of at a moving branch, and `FORGE.md` has been rewritten
to say so. That cost one command and it is strictly more precise than what it replaced: a
reproducibility claim tied to "the current tree" expires the first time anyone commits,
and nothing announces it.

So the banner edit no longer has to wait for anything, and neither does anything else on
this list. The one-pass discipline below is about the **deployment**, not about the
commits — v2 is cut once, from a finished tree, but it can be built up in as many commits
as the work naturally divides into. Anyone reading the v1 header on-chain should still
treat its gas numbers as a snapshot of 2026-08-24.

**What the replacement banner actually did, and the one instruction above it disobeyed.**
Every figure was re-derived from `evidence/` as required, and the five state-changing paths
were enumerated from the source rather than recalled. But the paragraph above says the v2
banner "may say that every state-changing path has run live" — and the banner that was
written declines to carry a test count or a gas table **of its own** at all. Those numbers
are properties of v1's *bytecode*, and v2 changes the ABI, adds a grant-time revert, a view
and a flag, so inheriting them would be a claim about bytes nobody has compiled yet. **An
inherited number is worse than a missing one**, because a missing number invites a
measurement and an inherited one invites trust. They get filled in only after v2's own suite
and gas report have been run. The banner instead attributes v1's evidence explicitly to v1,
names the tag that reproduces it, and carries a final paragraph saying it goes false the
moment v2 deploys — the same failure the v1 banner suffered for hours after it landed, which
is what put this item on the list to begin with.

**~~Near-certain.~~ DONE in v2, and it was three fixes rather than one.** Revert `BadConfig` at
grant time when `F_COSIGN` is set and the mandate's own policy makes the cosign gate
unreachable. Today that combination is
accepted and silently produces a mandate whose gate can never fire, because no amount
can be simultaneously under the per-transaction cap and over the cosign threshold. The
payer believes a human approves large spends; no spend is ever large enough to
ask. It is a footgun rather than an exploit — no funds are at risk and the caps
still bind — but it defeats a control the payer deliberately configured, which is
the worst kind of silent failure.

**The condition was stated wrongly here until 2026-08-25, in two ways, and the
correction is a v2 input rather than a note.** This file said `perTxCap <
cosignThreshold`. Line 492 tests `amount > m.cosignThreshold` *strictly* while line 476
caps `amount <= perTxCap`, so equality is dead too — and this repository already held
the receipt proving it, at `DESIGN.md:1272`: a 50,000 spend against a 50,000 threshold
did not trip the gate on Arc Testnet. The test is `perTxCap <= cosignThreshold`. It is
also incomplete, because with `F_PER_TX` unset the ceiling on a single spend is
`min(totalCap, window caps)` rather than `perTxCap`, so `totalCap = 100` with
`cosignThreshold = 100` and no per-transaction cap is equally unreachable and passes
both versions of the naive check. The guard must compare the threshold against the
effective maximum spend implied by the whole policy. Found by the review of
`L3-VAULT.md`, which had inherited the same error from this file.

**What v2 implements.** `effectiveMax <= cosignThreshold` refuses the grant, where
`effectiveMax = min(2^96 - 1, perTxCap if F_PER_TX, totalCap if F_TOTAL, every window cap)`.
Each term earns its place and one of them is not obvious. The `uint96` ceiling is the bound
that applies when the payer set no amount bound at all — a mandate bounded only by an expiry
still caps amounts, at `AmountTooLarge` — so a threshold of `2^96 - 1` is dead even there,
and a specification written in a language with arbitrary-precision integers has no reason to
invent that term. It went into `reference/policy.js` from the contract's direction, not the
reverse. `totalCap` is evaluated at `totalSpent == 0`, because reachability asks whether the
gate can *ever* fire and a lifetime cap is loosest on the first spend. Window caps enter as a
minimum, since the tightest one binds every spend, and the minimum is tracked inside the
existing validation loop so the check costs no second pass over calldata. The allowlist and
the two ERC-8004 gates are correctly absent: they deny by recipient or by identity, never by
amount, so they cannot strand a threshold.

**Two more dead-gate configurations, found by asking the general question, and neither was on
any list.** The item above describes one way to display a co-signature requirement without
having one. There are five, and enumerating them was worth more than implementing the item:
(a) `F_COSIGN` set with a zero cosigner — already refused in v1; (b) a cosigner named with
`F_COSIGN` unset — already refused in v1; (c) the unreachable gate above; (d) **a
`cosignThreshold` stored with `F_COSIGN` unset**, which `getMandate` returns to a reader as a
number that is measured against nothing; and (e) **`cosigner == spender`**, which is the
serious one. `approveCosign` authorises on `msg.sender == m.cosigner` and nothing else, so a
mandate whose cosigner is its own spender lets the agent approve its own spend hash and then
spend it — the gate becomes two transactions and no second party, which is not a weaker
control but the absence of one wearing its clothes. v2 refuses (c), (d) and (e).

Three things about (d) and (e) are worth recording. Neither is a divergence between the
contract and `reference/policy.js` — **the model accepted both as well**, so they are design
holes rather than implementation drift, and no amount of cross-checking the two suites against
each other could have surfaced them. (d) is deliberately *not* folded into the biconditional
that guards the cosigner address, because a threshold of zero is meaningful when `F_COSIGN`
is set: it means every spend needs a signature, since the gate is strict and an amount is at
least 1. So the address gets an iff and the threshold gets a one-directional rule. And (e)
had to be drawn narrowly: `cosigner == payer` is legitimate and stays legal, because the
payer is a genuine second party to the agent. It is what live mandate 2 does on Arc today, so
a rule that condemned it would have contradicted a receipt — which is also how the guard was
checked, by confirming that `ArcParity.t.sol`'s mirror of that live mandate still grants.

**One existing test had to be re-pointed, and it was the test that pinned the defect.**
`Cosign.t.sol` carried `test_DOCUMENTED_SOFT_SPOT_perTxCapBelowThresholdMakesCosignUnreachable`,
which granted exactly the configuration (c) now refuses and asserted it was accepted. This is
the second time in v2 that the thing standing in the way of a fix was a *passing* test
asserting the old behaviour, after the `totalSpent` cliff test below — a pattern worth naming
before the merkle allowlist lands. Nothing else broke: every other `withCosign` call site in
the suite was checked against all three new guards, and the tightest one, `Cosign.t.sol:107`
at threshold 25 against a window cap of 100, passes with room. A dead private helper,
`vmic_expectBadConfig`, was deleted from `Creation.t.sol` in passing — it had a comment
referring to "the call site above" and there was no call site anywhere.

**~~Certain, nearly free, and missing from this list until 2026-08-26.~~ DONE in v2, and the
fix is not the one described here.** Move the `newTotal` addition below the `F_TOTAL` check in
`spend`. Line 485 computes `m.totalSpent + uint96(amount)` unconditionally and line 486 only
then consults the flag, so the addition is evaluated even for a mandate that has no lifetime
cap. Under checked arithmetic that is a **panic rather than a graceful denial** once cumulative
spending approaches 2^96 base units — about 7.9e22 USDC — and the mandate becomes permanently
unusable rather than merely capped. The threshold is roughly ten billion times the total
supply of every currency on earth, which is exactly why it survived three verification
passes without being written down here.

**What was actually done, and why the instruction above could not be followed literally.**
`newTotal` is *consumed by* the `F_TOTAL` check, so it cannot simply be moved below it — the
check needed rewriting, not reordering. v2 compares without adding: `amount96 > m.totalCap ||
m.totalSpent > m.totalCap - amount96`, which is exactly `totalSpent + amount > totalCap` with no
addition to overflow, and whose first clause proves its own subtraction cannot underflow. The
counter then advances unconditionally, guarded by a new named error, `TotalSpentCeiling()`. That
guard is provably **unreachable** whenever `F_TOTAL` is set, because a lifetime cap is itself a
`uint96` and so binds first — which is now pinned by its own test rather than argued.

Four other checked accumulators in `spend` were enumerated before settling on that, so the fix
is not narrower than the defect: `spendCount` is a `uint32` and needs 4.29e9 real transactions
to wrap, which is a genuine difference in reachability rather than a convenience excuse; the
ring bucket's `cur.amount += amount` is *proven* safe by the pre-commit cap check, which
compares against a `uint256` before writing; and `used += a` is a `uint256`. Only `totalSpent`
needed changing. Slot 3 turned out to have exactly three spare bytes, so widening the counter to
`uint120` would have fit for free — **declined deliberately**, because it changes the `Spend`
event signature and therefore its topic0, while the actual defect was the illegibility of a
panic and not the range. The declined option and its reasoning are written into the contract so
an auditor can see it was considered rather than missed.

**And the test's own prediction was wrong, which is worth more than the fix.** `Bounds.t.sol`
said: *"If this test starts failing with `OverTotalCap` instead of a panic, someone moved the
addition below the flag check."* It does not, and could not. That test grants
`windowOnlyParams(...)`, which does **not** set `F_TOTAL`, so the lifetime cap is not what binds
— getting `OverTotalCap` there would mean the contract had invented a cap nobody granted. So the
change was *not* pre-authorised the way this file claimed; a prediction written next to a test
had gone unchecked because the test was green, and being green is not the same as being right
about what would turn it red. The divergence is now written into the replacement test's comment
so that the next reader who finds the old text in git history is not misled by it. Note also
that `totalSpent` must keep accumulating for mandates without `F_TOTAL` — it is an audit counter
carried in the `Spend` event, not merely an input to the cap — so v2 changes where the *check*
reads it, not whether it is maintained. Saturating it instead would quietly corrupt the audit
trail, which is worse than a cliff nobody can reach.

**How it went missing, which is the part worth keeping.** This is one of three "documented
soft spots" that the real-money decision of 2026-08-24 turned from curiosities into real
decisions. The other two — the unreachable cosign gate and the misleading `NotPayer()` —
are both above. This one is recorded in `README.md:339`, `FORGE.md:205` and the test's own
header, and was named in the same breath as the other two when the decision was made, and
it still reached this file's "changelist" section in none of them. Three of three
documented, two of three listed. **A list assembled by remembering what belongs on it will
be short by about a third**; it was found by grepping the tree for the cliff rather than by
re-reading this file.

**And the companion failure, one level up, found while fixing the cosign item.** Being *on*
the list is not the same as being described by it. The cosign entry named one of five ways to
grant a mandate that looks supervised and is not, and stated that one with the wrong operator
against the wrong field. So the list was short by a third, and one of the items that made it
on was short by four fifths. Both errors have the same cause — an item gets written down once,
at the moment somebody notices something, and is never re-derived from the contract afterwards.
The practice that caught it was asking the general question the specific item was an instance
of, which is now the first step for every remaining entry here.

**Not on this list at all until 2026-08-26, in either half. DONE in v2 as #22, and UNCOMPILED.**
Two grant-time refusals in the same block as the cosign guards above, both of them findings of
`THREAT-MODEL.md` rather than of this file — F5 and F1 there. They are the direct sequel to the
paragraph immediately above: the list was short by a third when it was checked against the tree,
and it was short by two more once a document written specifically to enumerate what the contract
fails to enforce was written. Neither could have been found by re-reading this file, because
neither was ever in it.

**F5 — `Unbounded()` was satisfied by things that bound nothing over a lifetime.** v1's
`hasBound` local (v1 lines 402–404) accepted `F_PER_TX` **or** `F_TOTAL` **or** `F_EXPIRY`
**or** any window, and the first and last of those are not lifetime bounds at all: a
per-transaction cap bounds one spend and permits unlimited spends, and a window bounds a
*rate* and permits unlimited cumulative spending given enough time. A mandate carrying
`perTxCap = 100` and nothing else is a standing instruction to spend 100 USDC forever, and v1
accepts it and still calls it bounded — while the contract's own comment beside the check
claimed the opposite. v2 narrows it, at `v2:424`:

```solidity
if ((flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)) revert Unbounded();
```

The alternative was to accept these configurations and document them, which is what v1 did by
default rather than by decision. Refused: the payer who writes a per-transaction cap and no
horizon has almost certainly not decided to grant authority in perpetuity, and the cost of
being wrong in that direction is unbounded while the cost of refusing is one extra field.

**F1 — `expiresAt` was the last field in the struct that could be displayed and unread.** With
`F_EXPIRY` unset, `spend` never reads `expiresAt`, so a payer could set it, see it returned by
`getMandate`, and have it enforce nothing. v2 refuses that at `v2:446`, immediately after the
existing `expiresAt <= notBefore` check at `v2:433`:

```solidity
if (flags & F_EXPIRY == 0 && p.expiresAt != 0) revert BadConfig();
```

One-directional on purpose, not the biconditional the other four flag/value pairs get. A zero
`expiresAt` with the flag unset is the ordinary encoding for "no expiry" and stays legal; an
iff would force every non-expiring mandate to set `F_EXPIRY` and thereby claim it expired at
the Unix epoch, which is worse than the defect. The order also matters: `Unbounded()` at
`v2:424` fires *first*, so the Solidity test for this has to set `totalCap` before it can reach
the check at all, and does.

**The expensive part was not either guard.** `v2:424` precedes every `BadConfig` check
(`429`–`448`, `465`, `482`) and `BadWindow` (`484`), so every revert-asserting test whose
params carried no lifetime bound had begun reverting for the *wrong reason* — and a bare
`vm.expectRevert()` in any of them would have passed while proving nothing. Seven such tests
were repaired by naming a reason explicitly. The shared builders in `Base.t.sol` now end with
`p = withExpiry(p)`, and every one of the thirty call sites that builds from `emptyParams()`
was accounted for individually rather than swept: a function-scoped `awk` pass over `test/`
found twenty-three functions that build from `emptyParams()` and grant, twenty-two carrying a
lifetime bound and exactly one — `test_createMandate_withNoLifetimeBound_reverts` — expecting
`Unbounded` four times. **Those four sites must never be "fixed".** An earlier fixed-window
version of the same sweep reported two false positives, because a 28-line window bleeds past a
function's closing brace into the next test's setup; the invariant had to be scoped to the
enclosing function before its output was worth anything.

**The convenience that was available and declined, for the third time in v2.** Making `grant()`
inject a lifetime bound would have fixed all of it in one edit. Refused: a helper that quietly
satisfies a security rule also hides it, and the next person to add a test would inherit
compliance without ever learning the rule exists. Both suites name their horizon out loud
instead. In Solidity that horizon is `type(uint40).max`, which is safe because `expiresAt` is
only ever *compared*, never used in arithmetic — its two readers are `v2:608` in `spend` and
`v2:1012` in `isLive`, and the only grant-time rule on the value is `v2:433`. There is no
requirement anywhere that it be in the future.

**The model mirrors F5 and deliberately does not mirror F1.** `reference/policy.js` renames
`hasBound` to `hasLifetimeBound` at lines 217–218 and the suite goes from 56 tests to **57**,
derived by running it rather than counted by hand: `node --test policy.test.js` reports
`# tests 57 / # pass 57 / # fail 0`. F1 gets no mirror because the model has no `getMandate`
and no storage struct, so it has no notion of a field being *displayed*; mirroring it there
would be inventing a behaviour to test. `THREAT-MODEL.md`'s F1 entry says so, so that the
asymmetry reads as a decision rather than an omission. The Solidity suite is now **157** test
functions by static count across eleven files, up two net — a static count, not a `forge test`
count, and therefore **unverified**, because forge does not run in the environment these edits
were made in.

**What it broke, honestly.** `DESIGN.md`'s flagship worked example and the narrative
`THREAT-MODEL.md` F2 is built on are now un-creatable for a *second and independent* reason:
they carry a per-transaction cap and a window and no lifetime bound at all, so `v2:424` refuses
them before the co-signature defect F2 describes can even be reached. That one is not
pre-existing — v1 accepted those examples and #22 made them invalid — and it is the expected
price of F5's decision rather than a surprise. Both are owned by #26, which already had to
revisit them for #11's reachability guard; #22 has recorded the new reason and extended the fix
recipe rather than half-fixing the prose, so the two edits cannot collide. The general lesson is
worth more than either guard: **every new grant-time refusal re-audits every configuration this
repository has ever printed**, including the ones in its own documentation, and that sweep is
the real cost line — not the two lines of Solidity.

**~~Likely, additive, low risk.~~ DONE in v2, and "low risk" was the wrong read.** A
`spendableAcross(bytes32[] mandateIds)` view.
Demonstrated live on 2026-08-24: with the allowance at 90,000, two mandates each
returned `spendable` = 90,000, summing to 180,000, and 50,000 dry-runs succeeded
on both. `spendable()` is honest per-mandate and silent about the joint
constraint, because the allowance is global and the view is not. No funds are at
risk — the losing delegate's transfer reverts — but two delegates sharing a payer
have no way to see the shared ceiling. A view that intersects the policy headroom
of several mandates with the single allowance would expose it. This does not fix
the race, which is inherent to layering per-mandate policy over one ERC-20
allowance; it makes it visible.

**What v2 implements.** `min(Σ min(policyHeadroom(id), 2^96 − 1), allowance(payer, manager),
balanceOf(payer))` over up to `MAX_JOINT = 8` ids, with three refusals. The description above
is still accurate about *purpose* and turned out to describe about a third of the *work*, which
is now the expected ratio for entries on this list rather than a surprise. "Additive" was
right — no existing function changed, and the only touched line outside the new code is the
errors comment. "Low risk" was wrong, because an additive **view** is exactly the kind of thing
that gets written in five lines and returns a plausible wrong number, and a payer auditing
their own exposure has no way to sanity-check a joint ceiling the way they can eyeball a single
mandate's cap.

**The bug the naive version has, which is #10's bug wearing a different hat.**
`for (…) sum += policyHeadroom(ids[i]);` **panics** — not over-reports, panics — on two
expiry-only mandates from one payer. `policyHeadroom` returns `type(uint256).max` there, and it
is right to: the payer set no amount bound. But `spend` still refuses anything above
`type(uint96).max` with `AmountTooLarge`, so `type(uint256).max` is not the largest single
spend, and two of them do not fit in a uint256. Same shape as the `totalSpent` cliff — a
faithful field read that is not the quantity the arithmetic needs — and, like that one, reachable
in two lines rather than astronomically. The fix is a clamp on each **term**, not a saturating
add on the **total**, and the difference matters beyond taste: with each term bounded by
2^96 − 1 and at most 8 terms, the widest possible sum is under 2^99 against a uint256 ceiling of
2^256, so the addition provably cannot overflow. A saturating add would return the same numbers
while destroying the reason they are correct, so both the contract and `reference/policy.js`
carry an explicit instruction not to add one. This is the second time in v2 that the `2^96 − 1`
ceiling had to be written into a calculation that looked like it only involved caps the payer
set — the cosign gate's `effectiveMax` was the first.

**Three refusals, chosen against the alternative of a plausible number.** `MixedPayers` (new
error) because there is no joint ceiling across two payers: separate allowances, separate
balances, no single clamp, so the sum is not a quantity. `DuplicateMandate` (new error) rather
than silent deduplication, because deduplicating returns the *right* number to a caller who
still holds the *wrong* belief about how many grants they have — and 200 is far more convincing
than 100 to somebody in that state. `UnknownMandate` (existing) rather than contributing zero,
which is a deliberate divergence from `spendable(unknownId) == 0`: one zero for one question is
unambiguous, whereas one bad id among eight vanishes into a total that still looks plausible and
leaves the caller believing they enumerated their exposure. Revoked and expired mandates *do*
contribute zero without reverting — they are the ordinary contents of any real caller's list,
and refusing them would make the view useless exactly when a payer wants to audit what is still
live. Duplicates are found by an O(n²) scan rather than by requiring ascending ids: at most 28
calldata comparisons against ~290k of storage reads per id, so demanding callers sort by keccak
hash would buy nothing measurable.

**`MAX_JOINT = 8`, and it is the first bound deliberately NOT mirrored in
`reference/policy.js`.** `policyHeadroom` costs up to 139 cold storage reads per mandate — 2 for
the struct slots `isLive` touches, 1 for `totalCap`, then 4 windows × (1 spec + 33 ring slots) —
so about 290k gas each and 2.3M for a full eight, which fits one `eth_call` at every default
node gas cap and one on-chain call inside a block. The rule the omission follows, which is worth
stating because `MAX_WINDOWS`, `MAX_BUCKETS` and `MAX_AMOUNT` are all in that file: bounds that
constrain the state machine get mirrored, because they change which mandates exist and therefore
which spends are legal; a bound that only rations a **read** has nothing downstream depending on
it, and JavaScript has no gas budget to ration. A payer with more than eight mandates does off
chain exactly what the view does on chain, and the model is the thing they would do it with.

**One inherited comment was measurably wrong and is now counted rather than asserted.** The
errors block claimed to be "One-to-one with the Denial reasons in reference/policy.js." The
correspondence is one-directional: all 21 of the model's `Denial` reasons have a matching error,
which is the direction that matters, but ten errors have no `Denial` counterpart because the
model reports those by *throwing* — nine caller or grant-time mistakes plus `TransferFailed`,
which a model with no token cannot have an opinion about. 21 + 10 = 31 with #12's two new
errors. Verified by extracting both lists and diffing them, not by reading down the file.

**Committed, as of 2026-08-24.** `F_ALLOWLIST_ROOT` on bit 7, storing a merkle
root instead of an `address[]`, so the vendors a payer has authorised but not yet
paid stop being public in the grant calldata. Previously listed here as undecided
and gated on the privacy decision; that decision is made — privacy is a required
user-facing option in Remit, and this is the one piece of it that belongs inside
the contract. See PRIVACY.md for the full four-layer argument, including why it
must not be named `F_PRIVATE`. Bit 7 is the last free bit in `uint8 flags`;
widening to `uint16` fits in slot 3's three spare bytes but would invalidate the
packing measurements. It needs grant-time validation beside the existing
invariant at line 363, a new branch in `spend`, and its own tests.

**~~Certain, free, and confirmed live on 2026-08-25.~~ DONE in v2.** Rename `NotPayer()` to
`NotAuthorised()`. The error is thrown by `revoke` at line 704, whose check is
`msg.sender != m.payer && msg.sender != m.spender` — the **spender is authorised
too**, deliberately, because renouncing your own authority cannot harm the payer
and it lets a compromised agent shut itself off. So the error fires on a path the
spender may legitimately take, and its name says otherwise. Confirmed on chain:
the agent revoked mandate 4 from its own key, tx `0x12d905a4…`, and a third-party
address still gets `NotPayer()` `0x1435e357`. Note this is an **ABI change, not a
comment change** — the selector becomes `0x1648fd01` — so anything decoding
reverts by selector must be updated with the redeploy. Purely cosmetic in
behaviour; a misleading error name is nonetheless a real cost paid by whoever
debugs against it.

**What unblocked it, since "it is in a deployed ABI" was a real reason and not an excuse.**
That reason expired with the tag `v1.0.0-arc-testnet`: the tag pins v1's ABI at v1's address,
and v2 is a different contract at a different address, so nothing that decodes v1's reverts is
affected by renaming the error here. Both selectors were computed with this repository's own
keccak implementation, which was **validated against three values already known** — the ERC-20
`Transfer` topic0, Remit's own `Spend` topic0, and `keccak256("Remit:v1")` — before being
trusted on new ones; `0x1435e357` was then independently corroborated by `DESIGN.md:1115`,
which records it from a real testnet revert. That check earned its keep: two fabricated
selectors had already been written into a contract comment and had to be removed. British
spelling was chosen to match the contract, which already says "authorises"; the American
`NotAuthorized()` would have been `0xea8e4eb5`. Updated in `reference/policy.js`,
`test/Bounds.t.sol`, `FORGE.md`, `README.md` and `DESIGN.md` in the same change — the v1
figures in `DESIGN.md` and `evidence/` were **relabelled as v1's rather than overwritten**,
because they are still exactly what the live contract returns.

**Certain, free, comment-only.** Complete `policyHeadroom`'s doc comment at lines
827-828. It says the view ignores "the allowlist and any co-signature
requirement", which is true but incomplete: it also ignores the ERC-8004 identity
and credential gates. Demonstrated live on 2026-08-25 — the identity-gated
mandate 3 reported `policyHeadroom` and `spendable` of 500,000 while every spend
attempt against it reverted `IdentityNotHeld()`. An agent pre-flighting against
that number would build a transaction that cannot succeed. The behaviour is
correct and should not change; the comment should name the gates. Rides with the
redeploy for the metadata-hash reason above.

**DONE in v2, and it grew in the writing.** The completed comment names both ERC-8004 gates
and, more usefully, says *why* they are absent: `isLive` covers revocation, `notBefore` and
expiry and stops there, making **no external calls at all**, while the identity and credential
gates read Arc's registries during `spend`. So the omission is deliberate rather than an
oversight — this is the pre-flight path, and it should neither cost two external calls nor stop
working when a registry is unreachable. Enumerating the surface properly turned up **four**
blind spots where the v1 comment named two: the allowlist (a property of the recipient, not the
amount), the co-signature requirement (which gates spends *above* a threshold rather than
capping them, so a large headroom figure may still need an `approveCosign` first), both gates
together, and the spend nonce — which is per-call rather than per-mandate, so replay is not
knowable from a mandate id alone. "Complete the comment" was filed as one missing clause and
was actually two.

EIP-7702-delegated EOA counts as an EOA for the Memo and Multicall3From paths —
now load-bearing beyond its original scope, because stealth-address sweeps on Arc
depend on gas sponsorship (PRIVACY.md, layer 2). **Escalated again on 2026-08-25 by
`L3-VAULT.md`:** the shielded vault needs sponsored submission of `createMandate`
itself, because a depositor who sends their own grant transaction is recorded as its
`from` beside the mandateId and the vault's payer privacy is worth nothing.

**Then half-answered the same day, from Arc's own documentation — and the two halves point
opposite ways.** `/integrate/evm-differences` states that EIP-7702 set-code transactions
"behave as on Ethereum", so a delegated EOA keeps its own address as `msg.sender` and
satisfies Remit's spender check at line 454 and payer assignment at line 371 natively:
**nothing in v2 needs to change for Remit's own paths.** But `/arc/concepts/transaction-memos`
says the `Memo` contract "must be invoked directly by an externally owned account" and
lists as unsupported "any other account-abstraction setup where the transaction originates
from a bundler, entry point, or other intermediary contract", because "sender spoofing
isn't allowed" — which **rules out ERC-4337 for the memo path outright**. 7702 is not named
there, and a delegated EOA originates its own transaction rather than routing through an
intermediary, so the documented reasoning suggests it passes. **That is an inference, not a
documented fact, and it needs one `cast send` against Arc to settle.** Do not write it into
a document as settled before that receipt exists.

The escalation itself was also overstated and is corrected in `GAS-ABSTRACTION.md`: gas
sponsorship on Arc is **not a missing chain feature**. ERC-4337 with EntryPoint v0.7 and
USDC-funded paymasters is live on testnet, so the gate in front of L2 and L3 is an
application-level sponsorship policy of ours, not something Arc has yet to ship. Two new
requirements fall out of it and belong with whoever builds that policy rather than in this
contract: a blocklisted `from` or `to` reverts at runtime and consumes the *submitter's*
gas, so a sponsor must screen recipients; and depositor-inflatable spend gas is charged to
the sponsor.

Also unresolved: whether the credential gate's
no-agent-binding shape should stay permitted, now that the attestation with
response 1 and the tag `"verified"` has been confirmed live and shown to be
refused by a correctly configured gate.

*Resolved since this file was written:* the ERC-8004 gate testing (#32) turned up
no contract defect. All three gates fired with their predicted selectors against
Arc's live registries with a passing control, and the grant-time guard at line 407
already refuses `minResponse == 0`. Nothing to change.

The revoke exercise (#44) likewise turned up no defect. Revocation short-circuits
ahead of every gate — the revert selector on a gate-blocked mandate changes from
the gate's error to `Revoked()` `0x44825a4b` — both views fall to zero through
`isLive`, the whole mandate struct survives revocation for auditing, and a
redundant revoke is harmless. Two consequences are for integrators rather than for
the contract: `MandateRevoked` **is re-emitted** on a redundant revoke, since line
705 has no already-revoked guard, so an indexer must tolerate duplicates; and the
approval a payer must zero to cut off Remit entirely is
`allowance(payer, MandateManager)`, never an approval held by the delegate, which
holds none. Both belong in integration notes. Adding a guard to line 705 would
cost gas on the common path to prevent a harmless duplicate, so it is explicitly
*not* on this list.

*Found while verifying that write-up, and worth more than the write-up:*
`withdrawCosign` at line 736 had **never run on chain** and was named in no
document in this repository. It is covered by the local suite and appears in the
gas report, which is why it stayed invisible — a green suite is not an inventory
of live coverage. Every earlier claim that `revoke` was "the only path with zero
live transactions" was wrong for that reason, and the enumeration that caught it
(parse every declaration for `external` or `public` without `view` or `pure`, then
grep the evidence for each) should be run before any future claim of live
coverage. It has since been exercised — `0x6515918e…` withdrew a real pending
approval and `0x7e10b4bd…` withdrew one that never existed — and neither turned up
a defect. Two properties are worth writing down. It checks only that the caller is
the cosigner, where `approveCosign` additionally checks that the mandate exists and
carries `F_COSIGN`; confirmed live, a call against a nonexistent mandate returns
`NotCosigner()` `0x1cf89d6f` rather than `UnknownMandate()` `0x473251f4`, which is
safe but names the wrong problem. And `delete _cosignApproved[...]` succeeds
whether or not an approval existed, so `CosignWithdrawn` was in fact emitted for
authority that was never granted, with nothing in the event to distinguish it from
a real withdrawal. Both are integrator notes rather than contract changes — the
guard asymmetry is defensible on the same reasoning that lets a spender revoke,
since giving up authority cannot harm the payer — and neither justifies gas on the
common path.

The same run re-measured `approveCosign` and the result retires a question this
file used to track. A second live approval cost **53,102** against the first one's
**53,114**, and the twelve-gas gap is entirely calldata: the new hash carries one
zero byte, which is priced at 4 rather than 16. Subtracting each transaction's
intrinsic cost leaves **31,026 gas of execution in both**, a day apart, to the
unit — so the 53,114 was representative and not an accident of one block.

And 31,026 is also what the mock gas report's 53,114 reduces to under the same
subtraction, which is how the "coincidence" verdict came apart the next day. Same
story for `revoke` and `withdrawCosign`: four functions, four exact agreements
between report and receipt. The consequence recorded above — that v2 costs are
predictable before deploying for everything except `spend` — comes directly from
this run's own receipts.

**Newly on this list as of 2026-08-26, from the #16a and #16b adversary sweeps, and one of
the four is time-limited.** `THREAT-MODEL.md` grew from fourteen findings to twenty-two that
day; four of the eight new ones change what the contract does and therefore belong here
rather than in a document sweep.

**F16 is the one with a deadline, and it is the reason this entry exists at all.** A
co-signature approval never expires: `_cosignApproved` is `mapping(bytes32 => mapping(bytes32
=> bool))` and the fix stores a `uint40` deadline instead of a `bool`. That is a **storage
layout change**, which costs nothing today and is unavailable the moment v2 is deployed — the
same class of constraint as any struct-field addition, and the only item on this list whose
cost depends on *when* it is done rather than on what it does. The suite's own
`test_approval_survivesAnUnrelatedFailure` demonstrates the edge: it approves a 90 spend, has
the window refuse it at `t0`, warps most of a day forward, and spends successfully — with a
docstring that argues persistence is *correct*, which it is, for the failure it was written
about. Persistence across a revert and persistence across a day are different properties and
the test only establishes the first.

**F15 and F17 are additive and can wait, but they are ordered.** F15 adds
`approveCosignFor(mandateId, recipient, amount, ref, nonce)`, computing the spend hash
internally from `m.spender` so a co-signer approving from a hardware wallet sees the payment
rather than a 32-byte hash — today `approveCosign` takes a hash and a hash is not invertible,
so the second signature is not a second opinion. F17 refuses approvals that can never be
consumed (a revoked mandate, an amount at or below the threshold); its threshold half needs
F15's explicit fields to be checkable at all, so F15 lands first or F17 lands half-done.
Neither changes `spend`, the mapping, or any event, so neither is deadline-bound.

**F19 is one line and closes a hole in the audit trail, not in the caps.** `recipient ==
m.payer` is a legal spend: it consumes `perTxCap`, the window ring and the lifetime cap, burns
its nonce, emits `Spend` — and moves nothing, because `transferFrom(payer, payer, amount)` is
a no-op. Arc's `usdc-system-events` reference makes it worse than cosmetic: *"self-transfers
(`from == to`) emit no log"*, so the 18-decimal system emitter that `evidence/` reconciles
against is silent for exactly these transactions. A reconciler sees a `Spend` with no transfer
and concludes its indexer dropped a log. The fix is `if (recipient == m.payer) revert
SelfPayment();` beside the existing `ZeroRecipient` guard. One sub-question is still open and
**cannot be settled locally**: whether Arc's ERC-20 USDC at `0x3600…0000` emits its own
6-decimal `Transfer` for a self-transfer is undocumented, and `MockUSDC` answering it would
only be our assumption answering itself. That needs one real transaction on Arc Testnet — the
first item on this list in a while that is blocked on a receipt rather than on a decision.

**And the corrective that matters more than any of the four.** F19 was already written down,
completely and correctly, at `L3-VAULT.md:492-496` — for somebody building a shielded vault.
That is the **third** time a hazard about `MandateManager` has been discovered while writing
for one audience and filed only against that audience (F1 was known to this file, F5 to the
reference model, F19 to the vault spec). Three makes it a process defect: from now on, a
document that discovers a hazard about the contract gets a line in `THREAT-MODEL.md` **in the
same commit**, even when it handles the hazard correctly for its own reader. Nothing in the
repository required that, which is precisely why it happened three times.

## What does not go in

**No privacy mechanism inside `MandateManager` beyond the allowlist root.** This
previously read "nothing that hides amounts or recipients," which was wrong, and
the reasoning behind the correction is in PRIVACY.md. Amounts and recipients
genuinely can be hidden — just not by this contract. Because `createMandate` sets
`payer: msg.sender` (line 371), any contract that can hold an allowance can be a
Remit payer, so a shielded vault composes *above* Remit without touching it.
Privacy is a payer, not a flag. That is what keeps it out of this changelist
rather than an argument that it should not exist.

No upgrade mechanism. If a future version needs one, that is a different product
with a different trust story, and it should be argued for on its own terms rather
than added because it would have been convenient this once.
