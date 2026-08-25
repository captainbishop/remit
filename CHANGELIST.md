# Redeploy changelist

## Why this file exists

`MandateManager` has no proxy, no `initialize`, no `upgradeTo`, no `delegatecall`,
no `selfdestruct`, and no owner or admin role. It has a constructor and three
`immutable` fields. It cannot be modified after deployment by anyone, including
its authors.

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
the fact. `perTxCap < cosignThreshold` is accepted at grant time. Whether an
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

**Certain, and free.** Update the file-header banner in `MandateManager.sol`. It was
correctly rewritten at deploy time — `NOT DEPLOYED. NEVER RUN AGAINST A LIVE CHAIN`
became `NOT AUDITED. LIVE ON ARC TESTNET SINCE 2026-08-24`, because the first was
false the moment the contract landed and a banner that lies trains readers to ignore
it. But its body has since gone stale: it says "one mandate has been granted and one
spend executed live" and "cosignature, both ERC-8004 gates and revoke have 139 passing
tests and zero live transactions." As of 2026-08-25 there are **five** live mandates,
four spends, three revocations, and **thirty-one** live transactions all with status 1;
cosignature now has four of them, both ERC-8004 gates have been exercised against Arc's live
registries, and neither `revoke` nor `withdrawCosign` is an exception any longer. The
replacement banner **may** say that every state-changing path has run live, which is newly
true and was false in every earlier draft of this note — but it must say **five** such paths,
not six. The list has always been `createMandate`, `spend`, `revoke`, `approveCosign`,
`withdrawCosign`; the count beside it said six for weeks because nobody parsed the source.
The test count is now 140. The unaudited / no-real-money half of the warning stays exactly
as it is.

Line 26 of that banner also carries two superseded gas figures — `~142,500` for the
policy machinery and `~32,700` for Arc's native-USDC accounting. Both are corrected
elsewhere in the tree as of 2026-08-24: the policy overhead is **103,479** gas
(0.217 cents), measured as the steady-state marginal spend of 177,429 less a bare
transfer of 73,950 rather than a first-ever spend of 216,458, and the token premium is
**13,110** on a `transferFrom`, measured receipt-against-receipt in
`evidence/premium.log`. The replacement line should read: *"of which ~103,500 is the
policy machinery and ~13,100 is Arc's own native-USDC accounting."*

**Why this one waits, even though it is free.** Solc appends a hash of the source
metadata to the bytecode, so editing even a comment changes the compiled bytes. The
deployment at `0x3744E93B9e796E05CB66311d897559B6F3860196` is verified against the tree
as it stands, and `FORGE.md` makes that claim explicitly — vendoring `forge-std` into
`lib/` exists precisely so a clone reproduces those bytes. Editing the banner today
would silently retire a checkable property in exchange for fixing a comment that is
already published on Blockscout and cannot be recalled there anyway. Since v2 needs a
redeploy regardless — `F_ALLOWLIST_ROOT` claims bit 7 — the banner edit rides along with
it, and until then the corrected figures live in `DESIGN.md` and `README.md`. Anyone
reading the header on-chain should treat its gas numbers as a snapshot of 2026-08-24 and
the repository documents as current.

**Near-certain.** Revert `BadConfig` at grant time when `F_COSIGN` is set and
`perTxCap < cosignThreshold`. Today that combination is accepted and silently
produces a mandate whose cosign gate can never fire, because no amount can be
simultaneously under the per-transaction cap and over the cosign threshold. The
payer believes a human approves large spends; no spend is ever large enough to
ask. It is a footgun rather than an exploit — no funds are at risk and the caps
still bind — but it defeats a control the payer deliberately configured, which is
the worst kind of silent failure.

**Likely, additive, low risk.** A `spendableAcross(bytes32[] mandateIds)` view.
Demonstrated live on 2026-08-24: with the allowance at 90,000, two mandates each
returned `spendable` = 90,000, summing to 180,000, and 50,000 dry-runs succeeded
on both. `spendable()` is honest per-mandate and silent about the joint
constraint, because the allowance is global and the view is not. No funds are at
risk — the losing delegate's transfer reverts — but two delegates sharing a payer
have no way to see the shared ceiling. A view that intersects the policy headroom
of several mandates with the single allowance would expose it. This does not fix
the race, which is inherent to layering per-mandate policy over one ERC-20
allowance; it makes it visible.

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

**Certain, free, and confirmed live on 2026-08-25.** Rename `NotPayer()` to
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

**Certain, free, comment-only.** Complete `policyHeadroom`'s doc comment at lines
827-828. It says the view ignores "the allowlist and any co-signature
requirement", which is true but incomplete: it also ignores the ERC-8004 identity
and credential gates. Demonstrated live on 2026-08-25 — the identity-gated
mandate 3 reported `policyHeadroom` and `spendable` of 500,000 while every spend
attempt against it reverted `IdentityNotHeld()`. An agent pre-flighting against
that number would build a transaction that cannot succeed. The behaviour is
correct and should not change; the comment should name the gates. Rides with the
redeploy for the metadata-hash reason above.

EIP-7702-delegated EOA counts as an EOA for the Memo and Multicall3From paths —
now load-bearing beyond its original scope, because stealth-address sweeps on Arc
depend on gas sponsorship (PRIVACY.md, layer 2). Whether the credential gate's
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
