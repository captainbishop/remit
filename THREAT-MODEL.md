# THREAT-MODEL.md

**Status: FIRST PASS, 2026-08-26. Not an audit.** Written by the same author as the
contract, which is the reason it cannot substitute for the professional audit this project
still requires before any mainnet deployment. Its purpose is narrower and still worth
something: to make the search for defects *systematic* instead of opportunistic, and to write
down what Remit protects, what it does not, and what nobody has looked at yet.

> **Line numbers in this file are marked `v2:NNN` and are anchored to commit
> `92445dd`**, the commit that landed task #22 and the tree that is green at 157/157.
> Recover the source they refer to with
> `git show 92445dd:contracts/MandateManager.sol`. That is a deliberate exception to the
> repo-wide convention recorded in `FORGE.md` (unqualified line numbers into
> `contracts/MandateManager.sol` mean the `v1.0.0-arc-testnet` tag), because this
> document is about the code being changed rather than about the code that is deployed.
> Anchoring to a commit rather than to "the working tree" is the point: the fixes this
> document argues for will move every line in it, and a reviewer needs to be able to
> reach what was actually read. Function names are used in preference to line numbers
> wherever one will do, since a function name does not move at all.
>
> **This anchor was `f2d3b35` and had already gone wrong, in one day, which is worth
> recording rather than quietly correcting.** #22 added 39 lines to the contract
> (1,171 → 1,204) and wrote *post*-#22 numbers into a document whose banner still said
> pre-#22 — so five of the nine distinct numbers here landed on a blank line under the
> banner's own recovery command (`v2:424`, `v2:433`, `v2:446`, `v2:608`, `v2:1012`) while
> the other four were correct only against the old blob (`v2:432` → `465`,
> `v2:636-641` → `669-674`, `v2:649` → `682`, `v2:664` → `697`). Both halves were verified
> by printing each line from both blobs, and all four stale citations are corrected above.
> The lesson is the one the banner already half-stated: a citation anchored to a commit is
> only safe while nothing edits the document, and *this* document exists in order to be
> edited. Prefer the function name; when a line number is unavoidable, quote the line's
> text beside it so a mismatch is self-announcing rather than silent.
>
> **The anchor was re-checked on 2026-08-26 when #16c added F23–F26, and it still holds:**
> `git diff 92445dd -- contracts/MandateManager.sol` is empty, so the anchor blob and the
> working tree are byte-identical and `v2:NNN` is unambiguous either way. Every number that
> sweep added was printed out of `git show 92445dd:contracts/MandateManager.sol` before being
> written down, which caught one wrong citation carried in from a working note — `v2:856-863`
> for the 6-decimal truncation note, which actually lives at `v2:1077-1084`; 856-863 is the
> credential `try`/`catch` body and has nothing to do with decimals.
>
> **That byte-identity ENDED on 2026-08-27, when #28 landed F15 and F16.** The anchor itself
> is unchanged and every `v2:NNN` in this file still resolves against `92445dd` exactly as it
> always did — but it is no longer *also* the working tree, so the sentence above must be read
> as history. `contracts/MandateManager.sol` went 1,204 → 1,376 lines, `approveCosign` was
> deleted outright and `spendHash` lost a parameter, which means every citation into the
> co-signature region now points at code that has been replaced. Those citations are kept
> rather than repointed, because a finding's evidence is the code that had the defect. Where
> this document describes what SHIPPED instead, it names functions and never lines, per the
> rule the first banner paragraph already states and this is now the second demonstration of.
>
> **The test tree moved with it, so "green at 157/157" above is now also history.** #28 took the
> source declaration count to 165 and the custom-error count from 31 to 33, and `forge test` has
> not been run since, so there is currently **no** green figure for the working tree — only a
> source count. §5's four mechanical checks were re-derived against it and say so in place.
> Nothing in this document should be read as claiming a v2 suite has passed; #14 owns that.
>
> **2026-08-28, F17: there are now THREE blobs, and this banner names only one of them.** F17 is
> written but *not committed*, so a reader has to distinguish the anchor, `HEAD`, and the working
> tree, and no two of the three agree:
>
> | | lines | `error` decls | `approveCosignFor` |
> |---|---|---|---|
> | `92445dd` — this banner's anchor | 1,204 | 31 | **absent** |
> | `4661bad` — `HEAD`, F15+F16 | 1,381 | 33 | present |
> | working tree — F17 on top | 1,501 | 34 | present |
>
> Three corrections fall out of that, and they are corrections *to the paragraphs above*, which is
> the pattern this banner has now demonstrated three times. **(1)** "went 1,204 → 1,376" is 5 short
> of the blob that actually landed; 1,376 was a working-tree reading taken before `4661bad` was
> written, and the committed figure is 1,381. The five lines are unattributed and the discrepancy
> is left visible rather than overwritten. **(2)** "from 31 to 33" was correct *for `HEAD`*; the
> working tree is at 34, F17 having added `CosignNotRequired`. **(3)** "there is currently **no**
> green figure for the working tree" has been retired: `forge test` was run on 2026-08-28 and the
> tree is **green at 178/178**, a figure derived twice — as the sum of the thirteen per-suite lines
> and again from the run's own summary — and matched by `grep -cE '^    function (test|invariant)'`
> over `test/*.t.sol`. #14 still owns re-measurement; what it no longer owns is the existence of a
> green run.
>
> **The F17 block below cites bare line numbers, and they are WORKING-TREE numbers, not `v2:NNN`.**
> This is stated rather than fixed because the alternative was to describe a seventeen-guard
> inventory without saying where the guards are. The rule the first paragraph states — prefer the
> function name — is why the numbers appear *beside* quoted guard text everywhere they appear. The
> danger is concrete, not theoretical: `approveCosignFor` does not exist in `92445dd` at all, so
> the banner's own recovery command cannot reach any of them, and it fails **silently** rather than
> landing on a blank line the way the `f2d3b35` breakage did. Checked one by one against the anchor
> blob, **eight of the nine land on a comment line and the ninth (`1194`) on a blank one**: `763` is
> `// any timestamp the chain can produce.`, `1101` and `1136` are `///` lines about the payer's
> allowance and about `DuplicateMandate`, `1132` is a bare `///` with nothing on it at all, `1130` is
> `///` prose about bounded terms, `1164` is a comment about which payer is read, `1173` is a comment
> about the largest amount `spend` accepts, and `1189` is a comment about sorting by keccak hash.
> Not one of them is code, and not one announces itself. `TotalSpentCeiling` is the single guard
> that exists in both blobs, and even it has moved: `92445dd:682`, working tree `763`. To reach what
> the F17 block read, use the working tree, or `4661bad` plus the F17 diff.
>
> **Do not "fix" the other bare-looking numbers — they are prefixed, and the prefix carries.** A
> grep for four-digit citations also returns `` `713` `` in §4 and §6, which look unanchored on
> their own line but are the tail of a `v2:`-prefixed run (`v2:614`, `615`, `690`, `713`) and are
> correct against the anchor. This was written wrong here first, on exactly one grep hit and
> without reading the line above it, which is the same mistake the document keeps recording in
> other people's code: **a grep returns a match, not a meaning.** The unanchored citations are all
> F17's and all inside §4 — **nine distinct numbers over eleven instances** (`763`, `1101`, `1130`,
> `1132`, `1136`, `1164`×2, `1173`, `1189`×2, `1194`), eight of them in the F17 finding and three
> in *"What a green suite cannot mean"*. That count is itself a correction: the first pass here
> said "five", because it was derived with a pattern matching only `at NNN` and `lines NNN` and so
> missed the parenthesised `(1132)`, `(1136)`, `(1173)` and the sentence-initial `1189`. Every one
> of the nine carries its error name or its condition text alongside it, which is the mitigation
> the first banner paragraph asks for.

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

**Both ERC-8004 registries are in the trust boundary, and Remit can never be pointed at
different ones.** `identityRegistry` and `validationRegistry` are `immutable`, set once in the
constructor, in a contract with no upgrade path — while the live Arc Testnet ValidationRegistry
was found on 2026-08-24 to sit behind an ERC-1967 proxy, so the code behind that fixed address
can be replaced without Remit knowing. Arc publishes the three registry addresses in a tutorial
rather than in its contract-address reference, with no stated stability or upgradeability
policy. The bound on the damage is worth knowing precisely, because it is narrower than it
sounds: the gates are conjunctive, so a replaced or hostile registry can only cause a gated
mandate to behave like an **ungated** one. It cannot raise a cap, extend an expiry, add a
recipient to the allowlist, or move one unit more than the amount bounds already allow. A payer
who is unwilling to accept that should not set `F_IDENTITY` or `F_CREDENTIAL` at all; the caps,
the allowlist, the expiry and `approve(usdc, remit, 0)` depend on no registry whatsoever. See
F23.

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

**A compromised delegate can pay *itself*, and without an allowlist that is the whole
attack.** `spend` requires `msg.sender == m.spender` (`v2:610`) and constrains the recipient
only against zero and against the allowlist (`v2:614-615`). So on a mandate granted without
`F_ALLOWLIST`, `recipient = m.spender` is a valid spend and the delegate needs no colluding
vendor, no second address and no cleverness — it transfers the payer's USDC to itself, up to
`perTxCap` per transaction and up to every window and lifetime cap in total. This is not a
defect and it is not fixable: a spending mandate that could stop the spender choosing the
recipient would not be a spending mandate. It is the sentence that says what the caps are
*for*. The caps are the entire protection, and they hold — the window search found no
sequence that exceeds them in 3.0M trials — but "the delegate cannot steal" is false and
"the delegate cannot steal more than the cap, and cannot steal at all from anyone the payer
did not allowlist" is true. **`F_ALLOWLIST` is what converts the bound from an amount into an
amount *and* a set of counterparties**, and it is the one flag whose absence changes the
threat model rather than the arithmetic. A payer granting to an agent they do not operate
should treat it as mandatory. `v2:482` refuses `cosigner == spender`, so the co-signature
route cannot be self-approved, but nothing refuses `recipient == spender` and nothing should.

**Everything is public.** Every mandate, every cap, every spend, every recipient, and
the whole commercial relationship it implies. This is the subject of `PRIVACY.md` and
`L3-VAULT.md` and is not restated here.

**The proposer chooses transaction order.** Arc's deterministic finality removes reorgs;
it does not remove the mempool. See F4.

## 3. Properties the contract does enforce, and the guard for each

Derived by walking the source, not by reading the test names. Five functions change
state: `createMandate`, `spend`, `revoke`, `approveCosignFor`, `withdrawCosign`. There are
no setters, no admin functions, no `delegatecall`, no `selfdestruct` and no upgrade
path.

| Property | Enforced by |
| :--- | :--- |
| Only the named spender can spend | `spend`: `msg.sender != m.spender` → `WrongSpender` |
| A mandate id is unique to one payer forever | id = `keccak256(DOMAIN, chainid, this, msg.sender, salt)`; `payer != address(0)` → `MandateExists`. `payer` is never cleared, so an id is single-use permanently and no revoked mandate's storage can be reinterpreted |
| No mandate can be created without a bound on **lifetime** exposure | `createMandate` at `v2:424`: `(flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)` → `Unbounded`. Narrowed in #22; v1's `hasBound` local also accepted `F_PER_TX` or a window, neither of which bounds a lifetime — that was F5, and this row is what the contract's own comment had been claiming all along |
| Every flag agrees with the value it describes | five biconditionals in `createMandate`, plus the one-directional `F_EXPIRY` rule at `v2:446` added in #22 — F1. No field in the struct can now be displayed and unread |
| A displayed co-signature requirement is a real one | three grant-time guards: threshold-without-flag, `cosigner == spender`, and `effectiveMax <= cosignThreshold` |
| Caps cannot be exceeded per-transaction, per-window, or per-lifetime | `OverPerTxCap`, `OverWindowCap`, `OverTotalCap`; window accounting independently searched over 3.0M spend sequences with zero violations, on a harness that reproduces the historical K-bucket bug at 2× cap |
| A rolling window is genuinely rolling | K+1 bucket summation. The proof in the source is valid but proves less than the code guarantees: eviction (`bucketIndex < oldest`) is the exact negation of inclusion (`bucketIndex >= oldest`) computed from the same `oldest` in the same call, and `oldest` is monotone, so nothing counted is ever discarded. `createMandate`'s `lengthSeconds % buckets != 0` check is load-bearing for cap soundness, not merely for uniformity |
| A spend cannot be replayed | `_usedNonce[mandateId][nonce]`; a reverted spend does not consume its nonce |
| One co-signature authorises exactly one spend | the hash binds mandate, spender, recipient, amount, ref and nonce plus `DOMAIN`, chainid and `address(this)`; consumed with `delete` on use |
| A co-signature cannot name a spender the mandate does not have | #28/F15: `spendHash` reads `m.spender` from storage instead of taking it as an argument, so a hash naming any other spender is not constructible through this contract — and `approveCosignFor` derives the hash itself rather than accepting one, so a co-signer cannot be handed a hash that disagrees with the fields they were shown |
| A co-signature expires | #28/F16: `approveCosignFor` refuses `validUntil <= block.timestamp` and `validUntil > block.timestamp + MAX_COSIGN_TTL` (30 days) with `BadDeadline`; `spend` refuses at or after the deadline with `CosignExpired`, distinct from `CosignRequired` for one never granted |
| Revocation is immediate and permanent | `revoke` sets `revoked = true`; no un-revoke exists |
| A compromised agent can shut itself off | `revoke` also accepts the spender |
| Caps hold even if the token misbehaves | see F7 — this is stronger than the source claims |

## 4. Findings

Ranked by what I would want fixed before this holds real money, not by CVSS. Severity
reflects consequence *and* reachability; several of the most interesting entries are
false or overstated claims in comments and documents rather than defects in code, which
for a primitive whose entire product is *legibility of authority* is not a lesser
category.

**Twenty-six findings, counted from the headings below rather than asserted** — `grep -c
"^\*\*Severity"` and `grep -c "^### F[0-9]"` both return 26, which is the check, not the
memory of having added some. The count is not a measure of anything — it is a function of how
long the search ran. They partition exactly, which is more useful than the total: **five are
already fixed in code** (F1, F5 in #22; F15, F16, F17 in #28 — the first two on 2026-08-27, F17
on 2026-08-28); **two were fixed in this document as it was being written** (F22 and F23, both
missing trust boundaries — §2 gained its sixth and seventh in one day); **five have a fix that
changes v2's behaviour** (F3, F9, F11, F13, F19); **eight are comment rewrites** that change
nothing any code does (F4, F7, F8, F10, F14, F21 in the contract, F25 and F26 in the mocks — and
the last two are in `test/`, so they are free of the frozen-metadata constraint that governs
`contracts/`); **three are documentation** (F2, F6, F18); **one needs a decision before it can be
sized** (F20, whether the contract gains a sixth state-changing function, and its first that
mutates a mandate after creation); **one needs a four-line test before it can be sized at all**,
because one of its two possible answers cannot be settled by reading source (F24); and **one
needs nothing** (F12).
5 + 2 + 5 + 8 + 3 + 1 + 1 + 1 = 26, which is the arithmetic and not a second assertion of the
same number. Triage:

| Fix before v2 freezes | Cost | Needs a decision first |
| :--- | :--- | :--- |
| ✅ F1 `expiresAt` grant-time refusal | **DONE in #22.** 1 line + 1 test; no model mirror, and F1 says why | — |
| F2 `DESIGN.md` worked example | numbers derived, needs a doc sweep — and it grew a second defect, see F2 | — |
| F3 `SpendCountCeiling` guard | 1 error + 1 line | or leave it and fix the changelist text |
| F9 `spendable` clamp | 1 line | — |
| F10 four → five | comment only | — |
| F11 `withdrawCosign` two guards, `revoke` idempotence | 3 lines | — |
| F4, F7, F8, F14 wrong justifications | comment rewrites | — |
| ✅ F5 `Unbounded()` scope | **DONE in #22.** 1 line, +1 model test, and a horizon threaded through both suites | **DECIDED 2026-08-26: refuse** |
| F6 threshold splitting | doc + one composition test | **DECIDED: document, recommend pairing with a window** |
| F13 gate pre-validation | 2 registry reads at grant + tests | **DECIDED 2026-08-26: validate at grant** |
| ✅ F15 `approveCosignFor`, explicit fields | **DONE in #28, 2026-08-27.** Not additive as proposed — the opaque `approveCosign` was DELETED, and `spendHash` lost its `spender_` parameter. See F15 for what that cost | **DECIDED 2026-08-27: remove it.** The row's own open question, answered against the recommendation in this row |
| ✅ F16 approval deadline | **DONE in #28, 2026-08-27.** `bool` → `uint40`, `MAX_COSIGN_TTL = 30 days`, 2 guards in `spend`, `isCosignApproved` re-meaninged, `cosignApprovalDeadline` added | **The "storage layout, so free now and not after v2 deploys" claim was DISPROVEN by `forge inspect` before the work started — a mapping occupies one slot whatever its value type. It was done for its own sake, not to beat a deadline that did not exist** |
| ✅ F17 dead approvals refused | **DONE in #28, 2026-08-28.** Not 2 lines — **17 guards**, derived from `spend`'s permanent refusals rather than from this row's list, plus 13 tests in `test/Cosign.t.sol` and a mutation gate that proves each guard is asserted. The hard half was deciding what NOT to refuse: `notBefore`, a full rolling window and an unfiled credential all recover, so refusing them would turn our caution into somebody's unapprovable payment | — |
| F18 co-signer rotation | documentation only — `README.md`, that re-granting resets the lifetime counters | whether a rotation path is wanted at all, which needs a setter and this contract has none |
| F19 refuse `recipient == m.payer` | 1 error + 1 line, beside `ZeroRecipient` | — |
| F20 recipient removal | either 0 lines (document it) or a payer-only remove-only mutator + event + tests | **whether the contract gains a sixth state-changing function — and its first that mutates a mandate after creation. Monotone, but §3's "no setters, no admin functions" is a sentence a payer can verify in ten seconds** |
| F21 `ZeroRecipient`'s Arc citation | comment only | — |
| ✅ F22 §2's missing self-payment boundary | **DONE 2026-08-26**, in this document, in the commit that found it | — |
| ✅ F23 §2's missing ERC-8004 registry boundary | **DONE 2026-08-26**, in this document — §2's seventh boundary; 0 lines of Solidity, and none available anyway since the addresses are `immutable` | — |
| F24 codeless-but-non-zero registry | a 4-line test, which decides whether there is anything else to fix | **what Solidity 0.8.28 does with a decode failure inside `try` — not settleable by reading source, and both answers are denials** |
| F25 `MockUSDC` self-transfer log | comment only, in `test/` | — |
| F26 mock revert shapes vs. the bare `catch` | comment only, in `test/` | — |
| §5 coverage gaps | **10 tests, 3 testnet transactions**, enumerated from §5 rather than summed from memory. This row previously said "9 tests, 1 testnet transaction" and undercounted the testnet side by two — the ERC-20 self-transfer log and the pending-validation state are both transactions, not tests | fold into #14, which needs the gas number anyway |

F12 is a design consequence rather than a defect and needs nothing. Nothing on this list
risks funds in the sense of letting a spend exceed a granted cap; the window search found
no such case in 3.0M sequences. **F23 is the closest thing to a counterexample and it is not
one** — a replaced ERC-8004 registry can make a gated mandate behave like an ungated one, which
widens the mandate back out to its caps and cannot take it past them, because the gates only
ever refuse. What this list is mostly about is the gap between what a
payer is *shown* and what is *enforced*, which is the thing Remit sells — and F15 extends
that gap to a second party, since the payer is not the only participant who is shown
something, while F19 extends it to a second *reader*, since a reconciler diffing `Spend`
events against Arc's system log is shown a discrepancy that is not one. F25 extends it once
more, to the most credulous reader of all: a passing test.

---

### F1 — `expiresAt` is stored, emitted and displayed on a mandate that never expires

**Severity: medium. Status: FIXED in v2 (#22), 2026-08-26. Confidence: certain.**

`createMandate` couples each flag to the value it describes with a biconditional, for
`F_PER_TX`, `F_TOTAL`, `F_COSIGN`, `F_CREDENTIAL` and `F_ALLOWLIST`. `F_EXPIRY` had no
such rule: `v2:433` validates `expiresAt` only *when the flag is set*
(`if (flags & F_EXPIRY != 0 && p.expiresAt <= p.notBefore)`). With the flag unset, any
`expiresAt` was accepted, written to storage, and emitted in `MandateCreated`, while
nothing ever read it — `spend` and `isLive` both gate the comparison on the flag.

So a payer could be shown, by `getMandate` and by the creation event, a mandate that
expired last Tuesday and that will spend forever. This is the identical failure class as
the `cosignThreshold`-without-`F_COSIGN` lie that v2 already refuses at `v2:465`, and
the argument that settled that one applies verbatim: a grant that appears to carry a
control it does not carry is refused rather than documented.

The fact was not new — `L3-VAULT.md:232` records that `expiresAt` "is then an unvalidated
field that may be zero", and the arithmetic sweep independently reached the same place.
What was new is the framing: it had been written down as a trap for a *future vault's*
release predicate, addressed to a reader building on top of Remit. It was never treated
as a property of the mandate that every direct payer also sees.

The asymmetry with `notBefore` is worth stating because it looks like the same problem
and is not: `notBefore` is enforced unconditionally, in both `spend` and `isLive`, with
no flag at all. It therefore cannot be displayed-but-dead, and needs no rule.

**Fixed in #22** by one line beside the existing guard, at `v2:446`:
`if (flags & F_EXPIRY == 0 && p.expiresAt != 0) revert BadConfig();` — one-directional
for the same reason the threshold rule is, since with the flag SET the paired guard at
`v2:433` already constrains the value, so only the flag-unset direction was open. Zero
with the flag unset stays legal, because that is how "no expiry" is spelled, and an iff
would have turned it into "expired at the epoch".

Two notes on the shape of the fix. It has **no mirror in `reference/policy.js`**, and
that is not an omission: the model has no flags, so `expiresAt: null` is the only way it
can say "no expiry" and the value and the flag cannot disagree there. The contract needs
the rule precisely because it encodes "unset" as a zero in a field of its own. And the
Solidity test that pins it — `test_createMandate_expiresAtWithoutTheFlag_reverts` — has
to set a `totalCap` first, because `Unbounded()` at `v2:424` is checked before every
`BadConfig()` and would otherwise be what fires.

`expiresAt` was the last field in the struct that could lie; the enumeration of all
thirteen `Mandate` fields and three gate structs is in §6, and it is now closed.

---

### F2 — `DESIGN.md`'s flagship worked example specifies a mandate v2 refuses to create, and its central claim was already false in v1

**Severity: medium (documentation, fail-closed). Status: OPEN, owned by #26. Confidence: certain.**

The narrative at `DESIGN.md:59-97` is the document's opening argument and the clearest
statement anywhere of what Remit is for. It specifies a mandate with an allowlist, a
**€5,000 per-transaction cap**, a **rolling 24-hour cap of €15,000**, and a **€10,000
co-signature threshold**. Three things are wrong with it, and they were found one at a
time, which is itself the point — each new grant-time guard re-audits every configuration
the repository has ever printed.

**It cannot be created under v2, for the co-signature reason.** The reachability guard
added in #11 computes `effectiveMax = min(2^96 - 1, perTxCap, minWindowCap) =
min(5,000, 15,000) = 5,000` and refuses when `effectiveMax <= cosignThreshold`.
5,000 ≤ 10,000, so `createMandate` reverts `BadConfig`. A payer following the canonical
example lands on a revert.

**It cannot be created under v2, for a second and independent reason.** As specified it
carries no `totalCap` and no `expiresAt`, so #22's narrowed guard at `v2:424` reverts
`Unbounded()` — and `Unbounded()` is checked *first*, so it is the error the payer
actually sees; the co-signature defect is hidden behind it. This one is not a
pre-existing flaw the way the other two are: v1 accepted the configuration, and #22
made it invalid. That is the honest description, and it is the expected cost of the
decision recorded in F5 rather than an argument against it. The narrative already
implies a horizon — it is a story about one night in a company's ordinary operations —
so naming one is an addition, not a change of meaning.

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
19,200 does not); €12,000 is now permitted by every cap — at the per-transaction cap
rather than under it, which passes because `spend` tests `amount > perTxCap` strictly —
and above the threshold, so Ada is asked; ordinary €4,800 invoices stay below the
threshold, preserving the "once, rather than two hundred times a month" point; and
`effectiveMax = 12,000 > 10,000`, so #11's guard accepts it. Lowering the threshold
instead would work arithmetically but would put it below the €4,800 routine invoice and
ask Ada about all of them. **Plus a lifetime bound**, for `v2:424` — an `expiresAt`
rather than a `totalCap`, since the narrative's caps are about rate and blast radius and
a lifetime total would be a fourth number the story does not need.

Every other worked configuration in the repository needs the same check against **both**
grant-time guards, which is a sweep, not an edit. #22 has already swept for `v2:424`;
what remains for #26 is #11's reachability guard.

---

### F3 — The `uint32 spendCount` panic shadows the named `TotalSpentCeiling` error that #10 added

**Severity: low as a fault, medium as a correction to a documented rationale. Status: OPEN. Confidence: certain on the arithmetic.**

`m.spendCount += 1` at `v2:697` is the only checked arithmetic site in the contract with
no guard in front of it, and `spendCount` is `uint32`. At 2^32 spends it raises
Panic 0x11 rather than a named error. `CHANGELIST.md:294` already notes this and
dismisses it as "a genuine difference in reachability rather than a convenience excuse",
which is true in isolation and wrong as a comparison.

`TotalSpentCeiling` needs cumulative spending near 2^96 ≈ 7.92e28 base units. Nothing
forbids `recipient == m.payer`, so a self-spend preserves the balance and the sequence is
sustainable. Reaching 2^96 in fewer than 2^32 spends requires an average amount of at
least 2^96 / 2^32 = 2^64 ≈ 1.84e19 base units, i.e. **about 18.4 trillion USDC**.
Circulating USDC is roughly 6.1e10 USDC, some 300× below that. So in precisely the
`F_TOTAL`-unset case that `v2:682` was written for, the illegible panic fires about 300×
sooner than the legible error, for every balance that can actually exist.

Both are unreachable in practice and neither risks funds — `v2:697` sits above the
transfer, so nothing moves. The finding is that #10's stated achievement ("a denial with
a name instead of a panic") is not delivered on the path it claims, and the source
comment at `v2:669-674` reasons only about the `F_TOTAL`-set case.

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

**Severity: medium as a legibility gap. Status: FIXED in v2 (#22), 2026-08-26. Confidence: certain.**

v1's `hasBound` local was satisfied by `F_PER_TX` **or** `F_TOTAL` **or** `F_EXPIRY`
**or** any window. So a mandate carrying only a per-transaction cap of 100 passed, and
the delegate could spend 100 repeatedly, forever, until the payer's allowance was dry.
The same held for a window alone: bounded per window, unbounded over a lifetime.

Only `F_TOTAL` and `F_EXPIRY` bound total exposure. The contract's own comment beside the
check said *"refusing to mint an unbounded authority is the entire point of the
primitive, so it is enforced rather than documented"* — and what was enforced was weaker
than what that sentence promised.

`L3-VAULT.md:174` states this exactly and correctly, and concludes *"the vault must require
it in its own code."* As with F1, the knowledge was in the repository but was addressed
to somebody building a vault on top of Remit, not to the ordinary payer who reads
`README.md` and grants a mandate directly. Both passages have since been extended to record
what v2 changed — and in each case the conclusion the vault spec had reached survives the
narrowing, for reasons the spec now states rather than leaves as an inference.

Whether to *change* it was a real design question rather than an obvious fix. Refusing
`F_PER_TX`-only grants breaks legitimately open-ended arrangements (a subscription with a
monthly window and no end date is a reasonable thing to want). An opt-in strictness flag
was considered and is not available: `flags` is a `uint8`, bit 7 is the last free bit, and
it is already committed to `F_ALLOWLIST_ROOT` in #13, so a new flag would mean widening
`flags` to `uint16` — touching every gate, every test and the `MandateCreated` signature.

**DECIDED 2026-08-26 — refuse. Implemented the same day in #22.** `v2:424` is now
`if ((flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)) revert Unbounded();` and the
`hasBound` local is gone. The open-ended case is served by setting a distant `expiresAt`,
which costs the payer nothing and makes the horizon explicit rather than absent; the
reasoning is the same one that retired the dead co-signature gate in #11 — "merely
useless" is not a reason to allow a configuration whose display and whose enforcement
disagree. The comment quoted above is now true rather than aspirational.

Three consequences worth having written down, because each cost something:

**The guard runs before every other validation.** `v2:424` precedes all six `BadConfig`
checks and `BadWindow`. So any revert-asserting test whose parameters lack a lifetime
bound now reverts for the *wrong reason* — and a bare `vm.expectRevert()` would still
pass while proving nothing. Seven tests in `test/` were in that position and each was
given an explicit horizon; `Cosign.t.sol`'s dead-gate test carries the note.

**The test suites had to name a horizon rather than be given one silently.** Both
`reference/policy.test.js` and `test/Base.t.sol` gained an explicit `FAR` constant and a
`withExpiry`-style helper that each mandate calls. Making the shared `grant()` inject a
bound would have repaired every failing test in one edit and, in the same edit, stopped
the suites from demonstrating that a real caller has to supply one. `FAR` in Solidity is
`type(uint40).max` rather than a plausible date, because `WindowInvariant`'s reachable
clock is `depth × (L + S + 1)` and `depth` is a `foundry.toml` knob the deep profile
already raises from 64 to 256 — a horizon safe under one profile and not another is a
trap. The contract permits it: `expiresAt` is only ever compared, never used in
arithmetic, at `v2:608` in `spend` and `v2:1012` in `isLive`.

**Every worked configuration in the repository had to be re-checked against it**, on top
of the #11 re-check that F2 already required. Two guards now, not one.

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

[**#28:** the comment was edited on 2026-08-27 and the count was **not** fixed — F15 renamed
the function it points at, so the sentence now reads "may still need an `approveCosignFor`
first", and the word "Four" survived the edit that touched the line beside it. That is the
sharpest available demonstration of why a counted claim in prose is a liability: the comment was
open in an editor, being changed, and the stale number went straight past. The cosign item also
gained a second failure mode in the same change — an approval can now be present but lapsed,
denied with `CosignExpired` — which does not move F10's count, because it is a second way for
the same listed item to deny, but does mean "needs an `approveCosignFor` first" is no longer the
whole of what the co-signature requirement can do to a spend this function called affordable.]

---

### F11 — `withdrawCosign` is missing both guards its sibling has

**Severity: low. Status: OPEN. Confidence: certain.**

`approveCosignFor` checks `payer == address(0)` → `UnknownMandate`, then
`F_COSIGN == 0` → `BadConfig`, then `msg.sender != m.cosigner` → `NotCosigner`.
`withdrawCosign` checks only the third. (The sibling was `approveCosign` when this was
written; F15 replaced it on 2026-08-27 and the replacement carries the same three checks in
the same order, so the asymmetry is unchanged.)

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

**#28 improved the off-chain half substantially without touching the on-chain half, and the
distinction is the whole finding.** Before F15, `CosignApproved` carried the mandate id, the
hash and the cosigner — so an indexer could count outstanding approvals but could not say what
any of them authorised without a side channel that supplied the preimage. It now carries
`recipient`, `amount` and `validUntil` as data, so the log alone answers "what did this
authorise, and until when". F16's `cosignApprovalDeadline` also lets a payer who *does* know a
hash distinguish "never approved" from "approved and lapsed", which `isCosignApproved` reports
identically. What is still absent is enumeration: nothing on chain lists the live approvals for
a mandate, because a Solidity mapping has no iterator and adding an index would mean an array
write on every approval. So the finding stands as written and its severity is unchanged — a
payer with an indexer is now materially better served, and a payer without one is exactly as
blind.

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

---

### F15 — The co-signer approves an opaque 32-byte hash, so what the payer buys is a second signature and not a second opinion

**Severity: medium as a degraded control, low as a fund risk. Status: FIXED in v2 (#28),
2026-08-27, but NOT the way this finding recommended — see "What actually shipped" at the end
of this section. Confidence: certain.**

`approveCosign(bytes32 mandateId, bytes32 hash)` at `v2:932` takes the hash and nothing
else. It checks that the mandate exists, that `F_COSIGN` is set and that the caller is the
named cosigner, then writes `_cosignApproved[mandateId][hash] = true`. It never learns the
recipient, the amount, the reference or the nonce, because a hash is not invertible and the
contract keeps no reverse index.

So the transaction a co-signer signs carries two 32-byte words and no readable fact about
the payment. Everything that makes the approval meaningful — that it is 5,000 and not
5,000,000, that it pays the vendor and not the agent — reaches the co-signer through a side
channel the contract cannot see, and the only on-chain way to check the claim is to call
`spendHash` (`v2:953`) with fields obtained from that same side channel and compare. A
co-signer on a hardware wallet sees `approveCosign(0x…, 0x…)`. Behind a Safe it is worse:
the second and third signers are approving a hash of a claim that was made to somebody
else.

This is blind signing, and it belongs here rather than under UX because of what this
particular gate is *for*. Every other control in the contract is enforced by the contract —
caps, allowlist, expiry, nonce, spender. The co-signature gate is the one control whose
entire value is a human judgment, and the contract hands that human the least legible
object it has.

Bounded, and worth saying so plainly: an approval authorises exactly one spend, that spend
is still policed by every cap, the allowlist and the expiry, and no approval moves money
without the delegate also acting. A co-signer who signs blindly cannot be made to exceed
the mandate. What is lost is the payer's belief that somebody looked.

**The fix is additive and cheap: an explicit-fields entry point.**

```solidity
function approveCosignFor(bytes32 mandateId, address recipient, uint256 amount, bytes32 ref, bytes32 nonce)
```

computing the hash internally from `m.spender` and the arguments, then taking the identical
path to the identical mapping. `spend`, the events, the mapping and the existing function
are untouched, so nothing that works today can break. The calldata then carries the
recipient and the amount as fields, which a wallet, a Safe, a block explorer and an auditor
can all read. Using `m.spender` rather than a parameter also removes a footgun in the
public `spendHash`, whose `spender_` argument lets an off-chain caller compute — and a
co-signer then approve — a hash that no spend can ever match.

Two secondary properties fall out of it, and the second is the one worth having:

- The hash can no longer disagree with the fields, because the contract derives it.
  `test_ATTACK_redirectingAnApprovedSpend_isRefused` and its two siblings already defeat
  the on-chain version of that attack at *spend* time, correctly. This defeats the *social*
  version at approval time: the agent can no longer show the co-signer one set of numbers
  and hand them the hash of another. The residual is address labelling — an agent can still
  claim `0xabc…` is the vendor — which is a different and much smaller problem, and one the
  allowlist is the right answer to.
- It makes F17's dead-approval check possible at all. `approveCosign` cannot refuse an
  approval for an amount at or below the threshold, because it does not know the amount.
  `approveCosignFor` does.

**What actually shipped, 2026-08-27, and where it departs from the paragraphs above.**

The proposal was additive: a new entry point beside the old one, "so nothing that works today
can break". That was rejected in favour of **deleting `approveCosign(bytes32,bytes32)`
outright**, and `spendHash` lost its `spender_` parameter in the same change. The reasoning is
worth keeping because it inverts the recommendation:

- A safe path that sits *beside* an unsafe one does not remove the unsafe one. Anything that
  can still be called still gets called — by an old integration, a copied snippet, or an agent
  that finds the two-argument form shorter. Leaving it in place would have converted a defect
  into a footgun and called it fixed, which is the same move as shipping a view whose display
  and enforcement disagree, refused twice already in #11 and #22.
- The `spender_` footgun in `spendHash` is a *removal*, not an addition. Widening the approval
  surface while leaving the hash constructor able to name a spender the mandate does not have
  would have left the social attack half-open: a co-signer could still be handed a hash nobody
  could spend, and now with a legible-looking function to approve it through.

Three consequences, none of them free:

1. **The ABI broke.** Two functions changed shape and one vanished, so nothing written against
   v1's ABI compiles or calls correctly against this tree. That is acceptable only because v1
   is a testnet deployment with no third-party integrations; it would not be acceptable after
   mainnet, and it is the strongest single argument in this document for finishing v2 before
   anyone builds on v1.
2. **`CosignApproved`'s topic0 changed**, because the event gained `recipient`, `amount` and
   `validUntil`. Any indexer filtering on the old topic silently sees nothing — not an error, no
   log, just an empty result, which is the worst failure mode an indexer has.
3. **The repository lost its only same-function gas anchor.** `approveCosign` was the one live
   Remit transaction that never touched USDC, which made it the cleanest control in
   `test/ArcParity.t.sol` for separating Arc's USDC premium from Remit's own cost — 53,114 gas,
   tx `0x29eb5c24…`. `approveCosignFor` is a different computation (196 calldata bytes against
   68, an extra cold `SLOAD`, an extra keccak, three data words in the log), so comparing it to
   that receipt would measure the redesign and call the difference an Arc property. The anchor
   is documented as lost in that file's header rather than quietly repointed, and the two
   assertions that depended on it were deleted rather than loosened. A v2 deployment will give a
   new anchor for the new function; it will not repair this one.

The cost in (3) was named before the change was made and accepted anyway, on the grounds that a
legible authorisation surface for a human co-signer outranks a gas measurement. That trade is
recorded here so it can be re-examined rather than rediscovered.

---

### F16 — An approval never expires, and the suite's own test shows one being consumed a day later under policy conditions that had refused it

**Severity: low as a risk, medium as an unstated property. Status: FIXED in v2 (#28),
2026-08-27. Confidence: certain — the behaviour is pinned by an existing test.**

Nothing decays an approval. `_cosignApproved` is `mapping(bytes32 => mapping(bytes32 =>
bool))` (`v2:266`), written at `v2:937` and cleared in exactly two places: consumption in
`spend` (`v2:693`) and `withdrawCosign` (`v2:945`). No timestamp is stored, so an approval
is good until it is used or withdrawn, for the whole life of the mandate.

The persistence is deliberate and the reason given for it is a good one.
`test_approval_survivesAnUnrelatedFailure` in `test/Cosign.t.sol` says it: *"If a transient
window breach burned the signature, every retry would need the human again — which in
practice means the human starts pre-approving in bulk, and the control stops meaning
anything."* That is right, and it is the kind of reasoning this repository should keep.

The same test then demonstrates the sharp edge, which nothing anywhere draws the
consequence of. It approves a 90 spend, has it refused by the rolling window at `t0`,
asserts the signature is still good, warps `DAY + DAY/12` so the window refills, and spends
the 90 successfully. So the repository already holds the receipt: **an approval outlives the
policy conditions under which it was given.** The co-signer approved a payment at a moment
when the policy would have refused it, and it settled a day later. Now extend the horizon —
#22 requires a lifetime bound and the recommended way to keep an open-ended arrangement
creatable is a distant `expiresAt` — and "until used or withdrawn" can mean years.

Compose with F12 and F15 and it is one situation seen from three sides: the payer cannot
enumerate outstanding approvals, the co-signer has no list either, and the remedy
(`withdrawCosign`) requires the co-signer to remember a hash they were never in a position
to read.

**What I would change, and what it must not break.** A co-signer-supplied deadline:
`approveCosignFor(..., uint40 validUntil)` storing `validUntil` in place of `true`, with
`spend` refusing when `block.timestamp >= validUntil`. That keeps the test's argument fully
intact — a retry minutes or hours later still works, so nobody is pushed into bulk
pre-approval — while ending the multi-year tail. Three notes on the cost. It changes the
mapping's value type from `bool` to `uint40`, which was believed to be a storage-layout change
and therefore free before v2 deploys and impossible after; **that belief was wrong, and it is
corrected below rather than above so the original reasoning stays readable.** It needs a
`validUntil > block.timestamp` guard, since `0` is already the absent value. And
`isCosignApproved` can keep its `bool` signature by returning `!= 0`, but would then be
withholding the fact a payer most wants, so it should gain a sibling that returns the deadline.

One imprecision in the sentence this paragraph used to end with, corrected because it was
wrong in a way that flatters the fix. It said the deadline "does not compose with the bare
`approveCosign` of F15 — an opaque-hash approval has no field to carry one". The second clause
is false as stated: `approveCosign(bytes32,bytes32)` could perfectly well have been widened to
`approveCosign(bytes32,bytes32,uint40)`, and a deadline would then have composed with an
opaque hash without difficulty. What is true is narrower and still sufficient: the *two*-
argument form has nowhere to put a deadline, so keeping the deadline meant either widening that
signature too — breaking its ABI, forfeiting the same gas anchor F15 forfeits, and getting a
function that is now three opaque words instead of two — or making the explicit entry point the
only path. That is an argument for F15, not a proof that a deadline is inexpressible without
it, and the difference matters because an argument that overstates itself is the thing this
document keeps finding in the contract's own comments.

**What actually shipped, 2026-08-27.**

`_cosignApproved`'s value type is now `uint40`, holding an exclusive deadline where `0` still
means "never approved". `approveCosignFor` refuses `validUntil <= block.timestamp` and
`validUntil > block.timestamp + MAX_COSIGN_TTL` with a named `BadDeadline(validUntil)`, refusing
rather than clamping so that a co-signer who miscalculates learns it instead of getting a
silently different authority than they asked for. `MAX_COSIGN_TTL` is **30 days**, an upper
bound the finding above did not ask for: a co-signer-supplied deadline alone still permits a
co-signer to type a date in 2040, which is the multi-year tail with an extra keystroke.
`spend` splits the two denials — `CosignRequired(hash)` when nothing was ever approved,
`CosignExpired(hash, validUntil)` when something was and lapsed — because a delegate that
cannot tell "never authorised" from "authorised and you were too slow" will retry the wrong
one. `isCosignApproved` keeps its `bool` signature but no longer means what it meant: it now
returns `validUntil != 0 && block.timestamp < validUntil`, so it answers "would this be
honoured right now" rather than "is there a row in the mapping". `cosignApprovalDeadline`
exposes the raw value, including a lapsed one, so a payer auditing a mandate can tell "never
approved" from "approved and it expired" — which `isCosignApproved` reports identically.

**And the correction the paragraph above defers to: there was no storage-layout deadline.**
The claim that `bool` → `uint40` on a mapping's value type is "free now and not after v2
deploys" is false, and `forge inspect MandateManager storage-layout` was run before any code
changed rather than after. A mapping occupies exactly one slot regardless of what it maps to;
the values live at `keccak256(key . slot)`, not in the declaring slot. All eight mappings sit
in slots 0–7 with `_cosignApproved` last at slot 7, and that is true of both versions.
Widening the value type moves nothing. So F16 was not urgent, it was merely correct, and it was
done for the second reason. This is recorded because the false urgency was in the triage table
above and could have been used to justify rushing the change past its tests, which is the
failure mode and not the fix.

---

### F17 — The approval function accepts a revoked mandate and an amount below the threshold, writing approvals that can never be consumed

**Severity: low (fail-closed). Status: FIXED in #28 on 2026-08-28. Confidence: certain.**

**What shipped, and why it is seven times the size this finding predicted.** `approveCosignFor`
now carries **17 guards**, counted from the file rather than from the two-line estimate in the
triage table above: `grep -c` over lines 1101–1194 returns 18 and the 18th is the word `revert`
inside a comment at 1130, which is one more reminder that a grep counts text and not guards. The
list was not extended from the two shapes named below; it was **derived from `spend`** by
partitioning every refusal `spend` can make into permanent and recoverable, and mirroring exactly
the permanent ones. That method is what found the eleven this finding never mentioned —
`RecipientNotAllowed`, `ZeroRecipient`, `ZeroAmount`, `AmountTooLarge`, `NonceAlreadyUsed`,
`OverPerTxCap`, `OverTotalCap`, `TotalSpentCeiling`, `Expired`, and the two mandate-relative
`BadDeadline` bounds. `reference/policy.js` has 17 `throw refuse(` in its twin, derived
independently from that file: the model and the contract agree on the count without either being
matched against the other.

**The hard half was deciding what NOT to refuse.** `notBefore`, a full rolling window and an
unfiled ERC-8004 credential all *recover*, so a shortfall in any of them says nothing about
whether a spend will be legal when the co-signature is actually used. Refusing them would convert
our caution into somebody's unapprovable payment, which is the failure mode this finding does not
have a name for. Three tests assert those three must CLEAR, and the mutation gate injects each of
them as a guard the function is required not to have — because removal-testing cannot reach a
"must not refuse" claim at all.

**Both halves named below are closed, and the second is closed by construction.** Approving on a
revoked or expired mandate now reverts `Revoked` (1132) and `Expired` (1136), the latter ordered
above the deadline checks on purpose so a dead mandate is not told its deadline is wrong. An
amount at or below the threshold reverts `CosignNotRequired` (1173). And the third shape §5 named
— an in-date approval outliving the mandate — is no longer *constructible*: 1189 refuses
`validUntil > m.expiresAt`, and a mandate without `F_EXPIRY` has no expiry to outlive, since
`createMandate` requires `F_TOTAL` in that case. That is a stronger closure than a test of the old
shape would have been, and it is the one place F17 removed a possibility rather than adding a
refusal.

**The evidence is a command, not this paragraph.** `python3 reference/mutation-gate-sol.py`
neuters each of the 17 guards in turn and injects the four guards the function must not have; on
2026-08-28 all 21 mutants were caught by a named test against a baseline of 178 green, with 0
survivors and 0 inconclusive. Its first run was **not** clean, and what it found is recorded under
*"What a green suite cannot mean"* below: `TotalSpentCeiling` at 1164 survived a green 177,
because every existing assertion of that guard exercised the identical line in `spend` instead.
Twelve F17 tests covered eleven of its guards, and no reading of the test names would have said so.

The rest of this finding is kept as written, because the gap between what it predicted and what
the fix cost is the useful part.

The heading used to name `approveCosign`, which no longer exists — F15 deleted it on 2026-08-27
and `approveCosignFor` is now the only way to write an approval. The defect carried over verbatim,
so this finding is re-pointed rather than closed: **the mechanism below is unchanged and the
missing guard is still missing** [**as of 2026-08-27, which is when that sentence was true. It was
still true one day and one commit later, at which point 17 guards landed rather than the 2 this
finding sized — see the block above**]. The three checks are the same three (`m.payer != 0`,
`F_COSIGN`
set, caller is `m.cosigner`), in the same order, and #28 added only the two deadline bounds —
which constrain *when* an approval dies, not *whether* it could ever have been used. Two
sentences below are now too strong and are corrected in place with `[#28:` notes rather than
rewritten, because what F16 bounded and what it did not is the interesting part. `v2:NNN`
citations resolve against the `92445dd` blob as the banner says; the function they point into has
been replaced, and the guard they observe missing is missing from the replacement too.

`approveCosignFor` checks three things and none of them is whether the approval it is about to
write can ever be used. Two shapes get through.

**A revoked or expired mandate.** `v2:933-936` reads `m.payer`, `m.flags` and `m.cosigner`,
and does not read `m.revoked` or `m.expiresAt`. `spend` reads both in its first four lines
(`v2:600`, `v2:608`), so the approval is inert — but it is paid for, written to storage,
reported `true` by `isCosignApproved` forever [**#28: for up to `MAX_COSIGN_TTL`, then `false`.
F16 bounded the display at 30 days; it did not stop the approval being written, paid for, or
logged**], and entered into the audit trail as `CosignApproved` for a mandate that can never
spend again. `revoke` is not idempotent either (F11), so a payer's reconstructed timeline can
carry a revocation followed by approvals, twice over.

**An amount at or below the threshold.** The gate at `v2:691` is
`amount > m.cosignThreshold`, strictly, and there is no threshold setter anywhere, so a
hash naming an amount at or under the threshold describes a spend that will never consult
the mapping. That approval is permanently unconsumable, and because only the consuming
path and `withdrawCosign` ever `delete`, it also never goes away [**#28: still exactly true —
the deadline governs whether the row is honoured, not whether it exists. `cosignApprovalDeadline`
keeps returning the stale value until someone withdraws it**].

Neither risks funds. They are listed because this repository has now twice refused a
configuration on exactly this ground and written the reason into the source: #11 refused a
`cosignThreshold` with no gate behind it (`v2:465`) and #22 refused an `expiresAt` that
nothing reads (`v2:446`), both on the stated principle that *merely useless* is not a reason
to allow state whose display and whose enforcement disagree. A live approval on a dead
mandate is that same shape one level down — `isCosignApproved` displaying an authority that
cannot exist. Either the doctrine is general or it was a preference about two fields.

The revoked-and-expired half is two lines inside the approval function. **The threshold half
was inexpressible when this finding was written and is expressible now:** F15 shipped on
2026-08-27, so the only approval entry point is `approveCosignFor`, which takes `amount` as an
argument and can compare it to `m.cosignThreshold` directly. That removes the reason this
finding was bundled with F15 and F16 as one change — F17 is now independent and can land on its
own.

Two things about F17 did NOT change when F15 and F16 shipped, and both are worth stating
because a reader might reasonably assume otherwise:

- **The deadline does not fix this.** An approval written against a revoked mandate now expires
  within `MAX_COSIGN_TTL` instead of persisting forever, which bounds the lie's duration but
  does not stop it being told. `CosignApproved` is still emitted for a mandate that can never
  spend, and `cosignApprovalDeadline` still reports a future deadline on it for up to 30 days.
- **A third unconsumable shape now exists, and it is F16's.** `spend` does not clear an approval
  it refuses — it reverts, and a revert rolls back every write — so a lapsed approval sits in
  storage until somebody calls `withdrawCosign`. `isCosignApproved` correctly reports `false`,
  so nothing is displayed as live that is not, and it is inert on every future block. It is
  noted here rather than as a new finding because it is the same shape as the two above: storage
  nobody is obliged to clean, harmless and untidy. `withdrawCosign`'s own docstring says so.

---

### F18 — The co-signer cannot be rotated, and the only remedy silently resets the lifetime cap

**Severity: note. Status: OPEN (documentation). Confidence: certain.**

`cosigner` is written once, in the struct literal at `v2:491`, and there is no setter — §3
already records that the contract has no setters at all. So a co-signer who loses their key,
goes on leave or turns hostile cannot be replaced. Above the threshold the co-signer is a
*liveness dependency*, so one who simply stops answering bricks the high-value half of a
mandate while the low-value half keeps working: griefing with no on-chain remedy. The
mirror-image move is available too — `withdrawCosign` can be front-run into the block ahead
of the spend that would have used the approval, so "the approval was live when the agent
submitted" is not a property. That is the F4 mechanism pointed the other way, and it is a
note rather than a finding because both directions *withhold* authority. Neither can move
money.

The payer's remedy is `revoke` and re-grant, and it always exists: the id is
`keccak256(DOMAIN, chainid, this, payer, salt)` (`v2:394`), so a fresh salt always yields a
fresh id. It carries a cost the payer has to be told about, because the reset is silent.

**`totalSpent`, `spendCount` and every window ring belong to the mandateId, so re-granting
resets all of them.** A payer who meant "this agent may spend 10,000 ever", has spent 8,000,
and re-grants in order to swap a co-signer gets a fresh 10,000 unless they think to grant
2,000. `IMMUTABILITY.md:160-171` states exactly this arithmetic — for the *migration* case,
where the whole contract is replaced. The identical arithmetic applies inside a single
deployment to a change of any parameter at all, which is a far more ordinary event than a
migration, and nothing in the repository says so. That belongs in `README.md` beside the
revocation guidance, not in a document about immutability.

---

### What a hostile co-signer cannot do

Derived by walking every site that reads `m.cosigner` or `_cosignApproved` — there are
seven, at `v2:266`, `491`, `692`, `693`, `937`, `945` and `979` — rather than by checking a
list of attacks. Recorded because a sweep that reports only findings tells a reader nothing
about what was ruled out.

**Re-derived against the working tree on 2026-08-27, after #28: the count is now eight, and
every conclusion below survives.** Under the same counting rule (the mapping declaration, the
`cosigner` write into the struct literal, and every read, write or `delete` of
`_cosignApproved`), #28 added exactly one site and it is `cosignApprovalDeadline`, a `view`.
The three that move — `approveCosignFor`'s write, `spend`'s read-and-delete, and
`withdrawCosign`'s delete — are the same three operations in the same three functions as
before. A view cannot be a capability, so nothing a hostile co-signer can do changed, which
is why the citations above are left pointing at the anchor rather than repointed: they are the
evidence for the ruling-out, and the ruling-out is what still holds. The one substantive
change inside an existing site is that `spend` now has **two** ways to refuse at the mapping
instead of one, `CosignRequired` and `CosignExpired`, and both are refusals.

- **Cause a transfer.** The only path to `usdc.transferFrom` is `v2:713`, inside `spend`,
  which requires `msg.sender == m.spender` at `v2:610`; and `v2:482` refuses
  `cosigner == spender` at grant time, so on one mandate the two roles can never be the same
  address. `cosigner == payer` *is* legal and is the ordinary case.
- **Escape a cap.** The mapping is consulted at `v2:692`, after the per-transaction,
  lifetime and window checks have all passed and committed — still true after #28, and
  `test_cosign_isCheckedAfterEveryCap` pins it. An approval satisfies extra conditions (two
  of them since F16, the second being that it has not lapsed); it cannot raise a bound.
- **Redirect or inflate an approved spend.** The hash binds recipient, amount and ref; three
  existing `ATTACK` tests pin it.
- **Replay an approval onto another mandate or another deployment.** Double-bound: the hash
  contains `mandateId`, `DOMAIN`, `block.chainid` and `address(this)`, *and* the mapping is
  keyed by `mandateId` as well. The `mandateId` term inside the hash is therefore redundant
  belt-and-braces rather than the load-bearing guard it looks like.
- **Inherit an approval from an earlier mandate.** That needs an id to be re-minted, and
  `payer` is never cleared, so `MandateExists` at `v2:395` refuses it forever. §3 carries
  this row already; it is restated here because `_cosignApproved` is one of the four
  per-mandate mappings deliberately left dirty on revocation, and a future "clear storage on
  revoke for the gas refund" change would break the invariant and reanimate all four
  mappings in the same edit.
- **Block a revocation, or extend a mandate.** `revoke` reads only `m.payer` and `m.spender`
  (`v2:909-910`), and nothing in the contract lets a co-signer write to a `Mandate`.

---

### F19 — `recipient == m.payer` is a legal spend that consumes every cap, moves nothing, and emits no system log

**Severity: low as a fund risk, medium as an audit-trail hole. Status: OPEN. Confidence: certain on the contract; the Arc half is documented, one sub-case is not.**

`spend` constrains the recipient twice and no more: `recipient == address(0)` is refused at
`v2:614`, and the allowlist is consulted at `v2:615` *only when `F_ALLOWLIST` is set*. So on
a mandate with no allowlist, `recipient = m.payer` is a valid spend. It passes every gate,
consumes `perTxCap`, the window buckets and the lifetime cap, burns its nonce, increments
`spendCount` and `totalSpent`, emits `Spend`, and then performs
`usdc.transferFrom(payer, payer, amount)` — which moves nothing.

Two consequences, and the second is the one that makes this more than a curiosity.

**A delegate can exhaust a mandate without being paid.** It gains nothing, so this is
griefing rather than theft: an agent that has been told to stop, or one that has been
compromised by somebody who wants the arrangement dead rather than drained, can zero the
lifetime cap in as many transactions as `perTxCap` requires and leave the payer holding a
mandate with no headroom. The remedy is `revoke` and re-grant, which is F18's remedy and
carries F18's silent reset.

**The audit trail cannot see it.** Arc's `usdc-system-events` reference states the rule
outright: *"Self-transfers (`from == to`) emit no log."* So the EIP-7708 system emitter at
`0xffff…fffe` — which the same page calls the universal record of balance changes, and which
`evidence/` reconciles against — is silent for exactly these spends. A reconciler diffing
Remit's `Spend` events against native `Transfer` logs finds `Spend` events with no
counterpart and concludes the indexer dropped something. Remit's own guidance has to be:
reconcile from `getMandate(mandateId).totalSpent`, never from transfer logs.

**One sub-case is genuinely unsettled and belongs in §5.** Arc's rule is stated for the
*system emitter*. Whether the ERC-20 USDC contract at `0x3600…0000` emits its own 6-decimal
`Transfer` for a self-transfer is not stated anywhere in Arc's docs, and it is
precompile-backed, so standard ERC-20 behaviour is an inference rather than a guarantee. One
testnet transaction settles it. The finding does not depend on the answer — the 18-decimal
stream is silent either way — but the size of the hole does.

**This is the third time the repository already held the finding and had it addressed to the
wrong reader.** `L3-VAULT.md:492-496` states this exactly, including the missing system log,
under the heading `recipient == vault` — where the vault is the payer. It is correct, and it
is written for somebody building a shielded vault, not for the payer who reads `README.md`
and grants a mandate to a payroll bot. F1 and F5 had the same shape, which is now a pattern
worth acting on rather than noting a fourth time: **when a hazard is discovered while writing
a document for one audience, it has to be filed against the audience that can be hurt by
it.**

**The fix I would take: refuse it.** `if (recipient == m.payer) revert SelfPayment();` beside
the existing `ZeroRecipient` guard, two lines including the error. A self-payment is never a
payment, and by the doctrine #11 and #22 already established — no state whose display and
whose enforcement disagree — a `Spend` event that transfers nothing is the purest example in
the contract. It closes the griefing vector as a side effect. The one configuration it would
break is a payer deliberately using a self-spend as a heartbeat or a cap-burning kill switch,
which is not a thing anyone here has ever wanted and which `revoke` does better.

---

### F20 — The allowlist is frozen for the life of the mandate, so a recipient that turns hostile cannot be removed

**Severity: low. Status: OPEN (needs a decision). Confidence: certain.**

`_allowlist` has exactly one write site in the contract: `v2:558`, inside `createMandate`'s
loop. There is no mutator, and §3 records why — the contract has no setters at all. So the
counterparty set is fixed at grant time. If an allowlisted vendor is compromised, changes
hands, or is simply finished with, the payer cannot narrow the mandate; they can only
`revoke` it whole and re-grant, paying F18's silent reset of `totalSpent`, `spendCount` and
every window ring.

The asymmetry is worth stating because the repository sells the immutability as protection
and only ever describes the loosening direction. `CHANGELIST.md:18` puts it as v1 being
unable to *"raise a cap, drop an allowlist, or remove a cosigner requirement after the
fact"* — all three of which are the payer being protected from the operator. The same
property also stops the payer **tightening** a mandate they still want, and nothing says so.

**The decision, because it is not obvious.** A payer-only, remove-only mutator —
`removeRecipient(bytes32 mandateId, address recipient)`, requiring `msg.sender == m.payer`
and only ever writing `false` — is *monotone*: it can reduce authority and cannot grant any.
That makes it categorically different from a setter, and it is the one shape of state change
this contract could take without weakening its central claim. Against it: §3's "no setters,
no admin functions" is a sentence a payer can verify in ten seconds, and every exception to
it costs something to explain. It also needs its own event to keep the audit trail
reconstructable, and it raises the obvious next question — whether `F_ALLOWLIST` can be
turned *on* for a mandate granted without one, which is also monotone-tightening and which I
would not add, because the flag is load-bearing in five places. My recommendation is the
remove-only mutator plus documentation of what it deliberately does not do; the alternative
is documentation alone, which is honest and leaves the payer with revoke-and-re-grant.

---

### F21 — `ZeroRecipient`'s comment cites an Arc rule about a different mechanism

**Severity: note. Status: OPEN. Confidence: certain that the citation is off; the guard is right regardless.**

The comment at `v2:612-613` reads: *"Arc forbids value transfers to the zero address; reject
up front rather than burning the caller's gas on a guaranteed runtime revert."*

Arc's `usdc-system-events` reference says: *"A native value transfer (`CALL`, `CREATE`, or
`SELFDESTRUCT`) to or from the zero address reverts with 'Zero address not allowed'."* That
is a rule about the three native mechanisms. `spend` uses none of them — it calls
`usdc.transferFrom`, the precompile-backed ERC-20 path. The same page adds that mint and burn
*"are the only paths that produce a `Transfer` involving `0x0`, and they go through the
precompile"*, from which the ERC-20 path almost certainly refuses `0x0` too — but that is an
inference from an absence, not the documented guarantee the comment presents it as.

The guard is correct and should stay, for a reason that needs no Arc citation at all: with
`F_ALLOWLIST` unset, `recipient == address(0)` is the one recipient that could destroy the
payer's funds rather than misdirect them, and refusing nonsense at the top of the function is
right whatever the token does with it. Stating it as *"Arc reverts on this"* is the fifth
instance of the pattern F14 names (F4, F7, F8, F14, F21): a correct guard with a
justification that would not survive scrutiny — and this one is the most brittle kind, since
it would go silently stale if Arc changed a rule the guard never actually depended on.

---

### F22 — §2 listed five trust boundaries and omitted the most important one: the delegate can pay itself

**Severity: medium as documentation, none as code. Status: FIXED in this document, 2026-08-26. Confidence: certain.**

Until today §2 named five boundaries — the payer's own account security, Circle, a
credential validator, publicity, and proposer ordering — and **the word "allowlist" did not
appear in the section at all.** Nowhere in this document, and nowhere in `README.md`, did a
sentence say that `recipient == m.spender` is a legal spend, so a compromised delegate needs
no accomplice: it pays itself, bounded only by the caps.

This was found by enumeration rather than by review. The recipient sweep asked which values
of `recipient` are legal, got the answer "everything except zero, plus the allowlist when
set", and then asked which of those legal values §2 had told the payer about. The answer was
none of them. I had assumed the section covered it, because it is the premise the whole
design rests on — which is exactly the kind of assumption that survives a review and dies to
a grep.

**Why it matters more than it looks.** The gap is not that a reader would think a delegate
cannot steal; anyone who understands "spending mandate" knows better. The gap is that
`F_ALLOWLIST` reads, in the current documentation, like one convenience flag among six.
It is not: it is the only flag whose presence changes *what kind* of bound the mandate is —
without it the payer has bounded an amount, with it they have bounded an amount and a set of
counterparties. A payer choosing flags from a list has no way to know that one of them is
load-bearing in a way the others are not.

**Fixed by the new §2 paragraph above**, which states the self-payment, states that it is
unfixable by construction, and says plainly which claim about Remit is false ("the delegate
cannot steal") and which is true. The residue is `README.md`, which describes the flags
without ranking them — that folds into F18's documentation pass rather than needing its own.

---

### What a hostile recipient cannot do

Derived from the four sites that read `recipient` inside `spend` — `v2:614`, `615`, `690`,
`713` — plus the allowlist's single write site.

- **Reach any Remit state.** A recipient is an address in an argument. It is compared to
  zero, looked up in a mapping, hashed, and passed to `transferFrom`. Nothing about a
  recipient can influence a cap, a window, a nonce or a flag.
- **Reenter profitably, if Arc executes recipient code at all** (unresolved, §5, bears on
  F7). `v2:713` is the last statement in `spend` and every state write precedes it, so a
  reentrant spend meets fully-updated state and is policed by every cap like any other. That
  is checks-effects-interactions, and it is why F7 argues the conclusion is right for a
  better reason than the one written down.
- **Escape the allowlist.** The check is a direct mapping read at `v2:615` with no
  normalisation, no fallback and no wildcard, against keys written only at `v2:558`.
- **Consume a cap by refusing the money.** A recipient that reverts on receipt, or that is
  USDC-blocklisted, unwinds the whole spend — no cap consumed, no nonce burned. The cost
  lands on the delegate, who paid the gas, not on the payer. Arc's own documentation of
  blocklist reverts consuming the submitter's gas is what makes that precise.

**Two things checked here that are deliberately *not* findings.** `p.allowlist.length` has no
maximum, making `v2:556-559` the only loop in the contract bounded by nothing but the block
gas limit — but the allowlist is never iterated in `spend`, which does a single mapping read,
so `MAX_WINDOWS`-style bounding would protect nothing; an over-long allowlist fails at grant
time, at the payer's own expense, discoverably. And Arc's *"zero-value transfers emit no
log"* rule cannot bite, because `v2:617` refuses `amount == 0` before any transfer is
reached.

---

### F23 — The two ERC-8004 registries are a trust boundary §2 never names, and Remit cannot re-point them

**Severity: medium as documentation, none as code. Status: FIXED in this document, 2026-08-26. Confidence: certain about the omission, certain about the immutability, second-hand about the proxy.**

`identityRegistry` and `validationRegistry` are `immutable` (`v2:168-169`, assigned once at
`v2:361-362`). §2 names Circle as a trust boundary *because USDC has an upgradeable
implementation*, and names a credential validator as a trust boundary *because it can lie,
including about time*. Neither sentence covers the registries themselves, and until today the
strings `registry`, `8004`, `proxy` and `1967` appeared **nowhere in §2**.

They belong there, because the registries are the one dependency Remit calls that is neither
Circle's asset nor the payer's chosen counterparty. `MockRegistries.sol`'s own header records
that on 2026-08-24 the live Arc Testnet ValidationRegistry at
`0x8004Cb1BF31DAf7788923b405b754f57acEB4272` was found sitting **behind an ERC-1967 proxy and
can therefore be upgraded under us**. That fact was discovered by inspection, by us. It is not
published: Arc documents the three registry addresses **only in a tutorial**
(`/arc/tutorials/register-your-first-ai-agent`), and **not** in
`/arc/references/contract-addresses`, which is the notes-bearing reference table that does
carry USDC, the CREATE2 factory, Multicall3 and Permit2. There is no stability guarantee, no
upgradeability statement, and no deprecation policy for these addresses anywhere in Arc's
documentation. A payer relying on a gate is relying on a tutorial.

**What a hostile or replaced registry can actually do, which is the part worth bounding.**
Both gates are conjunctive and can only ever *refuse* a spend or *fail to refuse* one. So a
compromised registry can make `ownerOf` return the spender and `getValidationStatus` return a
fresh passing attestation about the expected agent, and the effect is that **a gated mandate
degrades to an ungated one**. It cannot raise a cap, extend an expiry, reach the allowlist, or
move a single unit beyond what the amount bounds already permit. That is a genuinely
reassuring bound and it should be stated rather than left to be inferred: the ERC-8004 gates
are a *narrowing* layer, and their failure mode is to widen back to the caps, never past them.

**What makes it worth a finding anyway is that the address is immutable in a contract with no
upgrade path.** If a registry is replaced with something adversarial, Remit cannot be pointed
at a new one — there is no setter, by design (§3), and no proxy, by design
(`IMMUTABILITY.md`). The payer's only remedies are the two they already have: never set a
gate, or revoke. Both are real, and neither is discoverable from the current documentation.

**Fixed by the new §2 paragraph above**, which is that section's **seventh** boundary — F22
added the sixth an hour earlier, which is its own comment on how complete §2 felt before either
sweep ran. The paragraph states the immutability, states the proxy, states that Arc documents
these addresses in a tutorial rather than a reference, and states the bound: a hostile registry
degrades a gated mandate to an ungated one and cannot do more. The residue is a
`README.md`/`DESIGN.md` note that the two gate flags carry a dependency the other four do not,
which folds into F18's documentation pass.

---

### F24 — The grant-time registry guard is an address check, not a code check

**Severity: low. Status: open, and one of its two possible answers is not something this pass can settle. Confidence: certain about the guard, explicitly unresolved about the consequence.**

`createMandate` refuses a gate whose registry is missing — `v2:447` for `F_CREDENTIAL`,
`v2:448` for `F_IDENTITY`, both `BadConfig` — and `Creation.t.sol:498`
(`test_createMandate_gateWithoutRegistry_reverts`) pins both halves against a manager
constructed with `address(0), address(0)`. That is the right guard and it is tested.

It compares against `address(0)`. A registry address that is **non-zero and has no code** —
one digit wrong, an address from a different chain, a contract that was never deployed there —
passes it, and the mandate is created looking healthy. Every gated spend then reaches
`try validationRegistry.getValidationStatus(...)` or `try identityRegistry.ownerOf(...)` on a
codeless address, where the `CALL` succeeds and returns nothing.

**Whether the bare `catch` catches that, I do not know, and will not guess.** The external
call does not revert, so what fails is the ABI decode of the expected return — a six-component
tuple at `v2:852-854`, a single `address` at `v2:827` — and whether Solidity 0.8.28 routes a
decode failure into the `catch` clause or reverts the calling frame uncaught decides which
error the payer sees. Both outcomes are denials, so no funds are at risk either way; the
difference is `CredentialMissing()` and `IdentityNotHeld()` versus an opaque revert with no
selector. **No test covers it**, because `Base.t.sol:113` constructs the manager with two live
mocks and `Creation.t.sol:499` is the only other construction, using zero.

The test that settles it is four lines and belongs in #23:
`new MandateManager(address(token), address(0xdead), address(0xdead))`, grant a gated mandate
(which now succeeds, since `0xdead != address(0)`), spend, and assert whichever revert
actually comes back. Note the same class applies to `_usdc`, which `v2:359` zero-checks and
does not code-check — a codeless non-zero USDC makes every spend fail at `v2:713` instead.

**Why this is only low severity, and why it is still worth writing down.** It is a deployment
error, not an attack, and a deployment error that shows up on the first gated spend. But it
composes with the two findings either side of it: F13 (no grant-time validation, so the typo
survives until a spend) and F23 (the address is immutable, so the remedy is a redeploy). The
three together are the argument for F13's fix being an *eager* check rather than a lazy one.

---

### F25 — `MockUSDC` emits a `Transfer` on a self-payment; Arc does not, and that is precisely the point F19 turns on

**Severity: none as code, medium as a trap. Status: open, one comment in `test/mocks/MockUSDC.sol`. Confidence: certain.**

`MockUSDC._move` emits `Transfer(from, to, amount)` **unconditionally** at
`test/mocks/MockUSDC.sol:106` — including when `from == to`. Arc's `usdc-system-events`
reference states the opposite for the system emitter:
*"Self-transfers (`from == to`) emit no log."*

Taken on its own that is an unremarkable mock simplification. It is a finding because of what
F19 asks for next. F19's whole claim is that a self-payment is invisible in the transfer log
and must be reconciled from `getMandate(mandateId).totalSpent` instead. The obvious way to pin
that claim is a test — and **a test written against `MockUSDC` would pass while demonstrating
the opposite of production.** It would observe a `Transfer` on a self-spend, and the mock
would be answering a question about Arc with our own code.

This is the sharpest instance in the repository of the limit §5 already states in general
about `MockUSDC`, and unlike the general statement it names the exact test somebody is about
to write. The fix is a comment in the mock's header, beside the existing note about the
18-decimal dual view being unmodelled, saying that the unconditional emit diverges from Arc on
self-transfers and that no log-counting assertion about a self-payment means anything here.
`test/mocks/MockUSDC.sol` is not `contracts/`, so this costs nothing against the frozen
metadata hash.

---

### F26 — The mocks' revert shapes do not match production's, and the bare `catch` arms are the only reason that is currently harmless

**Severity: informational. Status: open, one comment. Confidence: certain, and this is the weakest finding in the document.**

`MockRegistries.sol:88` declares `error NoSuchRequest(bytes32 requestHash)` and reverts with it
for an unknown request. Its **own header** records that the live registry does something
different: on 2026-08-24 three non-existent request hashes were queried directly and all three
reverted with the standard `Error(string)` selector `0x08c379a0` and the string `"unknown"`.
Two different revert encodings, one asserted-equivalent path.

Every test passes because both arms are bare — `catch { }` at `v2:859` (revert
`CredentialMissing`) and `v2:829-831` (set `owner = address(0)`, then deny at `v2:833`) — and a
bare catch is indifferent to revert data. So **the bare catch is load-bearing for the mocks'
fidelity, and nothing in either file says so.**

Two things keep this informational rather than real, and both are worth stating because the
first is the opposite of what I assumed before checking. Narrowing either arm to
`catch Error(string memory)` — an obvious legibility improvement an auditor might well suggest
— would **fail loudly**, not silently: the mock's custom error would no longer be caught, it
would propagate, and the gate tests would report the wrong error. The suite defends itself
here. And `tag` and `responseHash` are the two tuple components the mock invents
(`tag: "compliance"` hardcoded, `responseHash` a `keccak256` of its own arguments), and
`v2:853` discards both with unnamed placeholders, so their fidelity cannot matter.

The residue is one comment in `MockRegistries.sol` recording that the divergence is deliberate
and that the bare catch is what absorbs it — so the next person to tidy the catch knows what
they are trading.

---

### What a green suite cannot mean, and four assumptions checked rather than assumed

Derived by reading the three files that decide what a green suite is evidence *of* —
`test/Base.t.sol` (361 lines), `test/mocks/MockUSDC.sol` (108), `test/mocks/MockRegistries.sol`
(129) — rather than by re-reading the tests themselves. The number of passing tests was 157 when
this was written, 165 declarations in source after F15 and F16, and **178** after F17 — the last
figure derived twice, from `grep -cE '^    function (test|invariant)' test/*.t.sol` and from the
run log's `13 test suites … 178 tests passed`, which agree. Nothing in this section depends on
which, because every limit below is a property of those three files.

**One limit is no longer structural, and this is what closing it looked like.** The heading's
subject used to be entirely a list of things a suite cannot reach. But the largest thing a green
suite cannot tell you is not in the mocks at all: it is whether any assertion would *notice* a
guard being removed. That question is answerable, and since 2026-08-28 it is answered by command
rather than by argument. `reference/mutation-gate.js` and `reference/mutation-gate-sol.py` neuter
one refusal at a time in a throwaway copy of the tree — `throw refuse(` → `void refuse(`,
`revert X(…);` → `{}` — and require a **named test** to fail for each; a mutant that will not
compile or will not run is reported INCONCLUSIVE and never "caught", because a gate that scored a
broken mutant as a pass would manufacture exactly the confidence this section exists to withhold.
Each also *injects* four guards the function is required NOT to have, since removal cannot reach
a "must not refuse" claim.

Both gates found real holes on their first run, which is the only reason to trust either. In the
model, `BAD_CONFIG` survived a green 68 because neutering the no-cosigner check left the same
input refused one line lower under `NOT_COSIGNER` — nobody is `null`'s cosigner, so **two guards
that refuse the same input for different reasons hide each other**. In the contract,
`TotalSpentCeiling` at 1164 survived a green 177 for a plainer reason: nothing asserted it.
`grep -rn TotalSpentCeiling test/` returned two hits, both in `Bounds.t.sol`, both exercising the
*identical* guard on the `spend` path at 763. Coverage of one path reads, from any distance, like
coverage of both. Twelve F17 tests, eleven of F17's guards — and the twelve were green throughout.
The gates also disagreed with each other, which is its own finding: the model already asserted
that guard, so the JS gate scored 21/21 while its Solidity sibling scored 20/21. **When one gate
is clean and its twin is not, the delta is a divergence report.** Both are 21/21 as of 2026-08-28.

What the gates still cannot mean: neither performs operator swaps, so a `>` quietly becoming `>=`
is invisible to both and only a boundary-tight assertion catches it. That is why the ceiling test
refuses at one base unit over and approves at exactly the limit, and why the model's version —
which sat ten units clear of the cliff and would have passed against an off-by-one — was tightened
to match rather than left as the twin that agreed for the wrong reason.

Four limits are structural, and no amount of test-writing moves them:

- **USDC is Arc's gas token and the mock has no gas coupling at all.** Foundry pays gas in
  ETH from a balance the mock does not model, so the entire class *"a spend succeeds and leaves
  the payer unable to fund their next transaction"*, and its mirror *"the delegate's own
  balance is consumed by gas until it cannot submit"*, is unreachable in CI by construction —
  not untested, untestable here.
- **The native/ERC-20 dual view is deliberately unmodelled**, and the mock's header says so
  with its reason (`MandateManager` only ever touches the ERC-20 interface). So the premise of
  the ARC NOTE at `v2:1077-1084` — one underlying balance, viewed at 18 decimals natively and 6
  through the façade, so `balanceOf` truncates — has no local counterexample and can only be
  established on Arc. The same note bounds how much that costs, which is why this is a limit and
  not a finding: the truncation is one-directional (`spendable` can under-report by up to
  1e-6 USDC and never over-report, so an agent trusting it at worst skips a spend it could have
  made), and `spendable` is **the only place the contract reads a balance at all** — the `spend`
  path never does, so no amount of truncation can change what a policy permits. An earlier draft
  of this bullet cited `v2:856-863` for that note, which is the credential `try`/`catch` body and
  has nothing to do with decimals; the number came from a summary instead of from the file.
- **No test stages a future-dated `lastUpdate`**, so §2's staleness boundary — the
  `nowTs > lastUpdate &&` conjunct at `v2:880`, which makes a future-dated attestation fresh
  forever — has no executing counterexample. Derived from all ten `setStatus` call sites: one
  in `Base.t.sol` at `block.timestamp - 100` and nine in `Gates.t.sol` at `block.timestamp` or
  a local `attestedAt` assigned from it. Every one is present or past.
- **The ERC-8004 ValidationRegistry has a third state neither the mock nor the live probe
  covers.** Arc documents a **two-step** flow — the agent owner calls `validationRequest`, then
  the validator calls `validationResponse` — so a `requestHash` can be *requested and
  unanswered*. `MockValidationRegistry` models a binary `set` flag, and the 2026-08-24 live
  probe used three hashes that had never been requested at all. Neither is the pending state.

And four assumptions that were checked and hold, recorded because a sweep that only reports
defects gives no way to tell a verified assumption from an unexamined one:

- **`getValidationStatus`'s return tuple matches Arc's published ABI exactly.** Six
  components, same order, same types: `(address validatorAddress, uint256 agentId, uint8
  response, bytes32 responseHash, string tag, uint256 lastUpdate)` in Arc's tutorial ABI, and
  identically at `v2:151-156`, with `v2:853` skipping positions four and five as unnamed
  placeholders in the right slots. **This is the assumption a mock is structurally incapable of
  testing** — `MockRegistries` implements our own declaration, so a wrong order would agree
  with itself and every gate test would pass while decoding garbage on Arc. It was the highest
  consequence item in this sweep and it is correct.
- **The pending state cannot pass the gate**, whichever way the live registry answers. A zero
  validator denies at `v2:863`; the requested validator with `response = 0` denies at `v2:879`,
  because `v2:563` refuses `minResponse == 0` at grant time. That guard is the one doing the
  work here, and its stated reason — the comment on its own line, and
  `Creation.t.sol:487`'s test name, both amount to *"0 would accept a failed attestation"* — is
  correct and does not mention this second consequence. Worth adding to it: the same line also
  makes an unanswered request unspendable.
- **The infinite-approval divergence cannot be observed.** `MockUSDC:90-91` skips the allowance
  decrement for `type(uint256).max`, claiming to match Circle's implementation, which is
  unverified against Arc. It cannot matter: `2^256-1` minus any `uint96` still exceeds every
  cap, so the allowance term in `spendable` and `policyHeadroom` is never the binding minimum
  either way. Finite allowances *are* exercised — nine explicit `approve` sites across
  `ArcParity`, `Idempotency` and `Views`, including two at `0`.
- **The constructor's zero-address asymmetry is deliberate and right.** `_usdc` is refused at
  zero (`v2:359`, pinned by `Creation.t.sol:514`); the registries are accepted at zero and
  refused only when a gate needs one (`v2:447-448`). A manager with no registries is a
  perfectly good manager for ungated mandates, and forcing two addresses on a deployment that
  will never gate anything would be worse. Likewise `MockUSDC.burnFrom` emitting
  `Transfer(from, address(0))` while bypassing `_move`'s zero-address refusal **matches** Arc,
  where burns happen only through the precompile.

## 5. Coverage gaps — what this pass could not reach, and what no test executes

Two kinds of gap are listed together because a reader deciding how much weight to put on
this document needs both: things a source review cannot settle in principle, and things the
test suite simply never runs. Neither kind is a finding. Each one is a reason a finding
could still be hiding there.

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
- **Three co-signature behaviours `test/Cosign.t.sol` never runs**, enumerated against the
  file rather than sampled, and all three are F17's: approving on a **revoked** mandate;
  approving on an **expired** one, or letting a live approval outlive the mandate's
  `expiresAt` before spending; and approving a hash whose amount is **at or below the
  threshold**, so the mapping is written and never consulted. All three are ordinary
  Foundry tests. Re-derived on 2026-08-27 rather than carried forward, and the re-derivation
  changed the bullet twice.

  **CLOSED 2026-08-28.** All three run now: `test_f17_approvingOnARevokedMandate_isRefused`,
  `test_f17_approvingOnAnExpiredMandate_isRefused` and
  `test_f17_approvingAtOrBelowTheThreshold_isRefused`. The second gap's other half — an in-date
  approval outliving the mandate — is closed by construction instead of by a test, because line
  1189 refuses `validUntil > m.expiresAt` and a mandate without `F_EXPIRY` has no expiry to
  outlive; `test_f17_theDeadlineMustOutliveNotBeforeAndDieByTheExpiry` pins both mandate-relative
  bounds. The file now declares **37** tests (`grep -c '^    function test'`, cross-checked
  against `Ran 37 tests for test/Cosign.t.sol` in the run log), of which **13** are `test_f17_*`.
  Read the following bullet before treating that as coverage: twelve of those thirteen were
  green while one of F17's seventeen guards was asserted by nothing at all.

  **This bullet said "four" and said "seventeen tests", and both were wrong.** The count is
  now **25** — `grep -c '^    function test'` — of which eight are new in #28 and two are the
  old `approveCosign_*` pair renamed. The four gaps were attributed to "F16 and F17";
  F16 has since shipped, and its behaviour is now covered by `test_approval_expires`,
  `test_deadlineInThePast_isRefused`, `test_deadlineBeyondTheCap_isRefused`,
  `test_deadlineExactlyAtTheCap_isAccepted`, `test_expiredAndAbsent_areDifferentErrors` and
  `test_expiredApproval_lingersInStorageButIsInert`, so what remains is F17's alone. Note
  that the surviving second gap is **not** what F16 fixed: F16 bounds an approval's own life,
  and this gap is an in-date approval outliving the *mandate*, which nothing bounds.

  **The retired fourth gap was never a gap.** It read "`withdrawCosign` **front-running** a
  spend that would have used the approval", and conceded in the same breath that what a test
  can pin is the two-transaction sequence rather than the mempool race. That sequence was
  already pinned, in the same file, at the anchor commit: `test_withdrawCosign_revokesAnUnusedApproval`
  approves, withdraws, asserts `isCosignApproved` false, and then has the agent's `spend`
  refused with `CosignRequired` carrying the same hash. So the bullet named as untested the
  one part of the property a test can reach, next to the test that reaches it — a gap found by
  reading test bodies instead of test names, which is exactly the discipline §3's opening
  sentence claims for itself and this bullet had not applied. The mempool race itself remains
  unpinnable, which is F4's limit and is recorded there, not here.
- **`recipient == m.payer`, which no test anywhere in the suite performs** — derived, not
  recalled. Every recipient argument reaching `spend` across all eleven test files and
  thirteen suite contracts is one of `vendor`, `other`, `boss`, `ARC_RECIPIENT`, the
  `0x…c0de` literal, or `address(0)` in the two tests that expect `ZeroRecipient`; `payer`
  is never among them, and `Base.t.sol:100-104` makes all five accounts distinct
  `makeAddr`s, so no fuzz path can collide into it either. The test F19 wants asserts the
  paradox directly: a self-spend succeeds, `totalSpent` and the window ring both advance by
  `amount`, the nonce is burned, `Spend` is emitted, and the payer's USDC balance is
  unchanged. It is also the test that would have to be **deleted** if F19's fix lands, so
  writing it now is only worth it as the fix's negative case
  (`vm.expectRevert(SelfPayment.selector)`).
- **Whether Arc's ERC-20 USDC at `0x3600…0000` emits its own 6-decimal `Transfer` on a
  self-transfer.** Arc's `usdc-system-events` page documents the rule only for the
  18-decimal system emitter at `0xffff…fffe`. `MockUSDC` cannot answer this — it is our own
  code, and whatever it does is a description of our assumption, not of Arc. This is the
  one gap in this document that **no test can close**: it needs one transaction on Arc
  Testnet against the real token, `cast send` plus `cast receipt --json`, counting logs.
  F19 holds either way; only the size of the audit hole moves.
- **A future-dated `lastUpdate`, which no test stages** — so §2's sharpest statement about the
  validator boundary, that an attestation dated in the future skips the freshness check at
  `v2:880` and stays fresh forever, has no executing counterexample. Derived from all ten
  `setStatus` call sites; every one is present or past. One ordinary Foundry test closes it,
  and it should assert the surprising direction: warp *backwards* relative to the attestation
  and watch `maxStaleness` stop applying.
- **The ValidationRegistry's pending state.** Arc documents a two-step flow, so a `requestHash`
  can be requested and unanswered — a state `MockValidationRegistry`'s binary `set` flag cannot
  express, and one the 2026-08-24 live probe did not reach, since those three hashes had never
  been requested at all. §4 argues it must deny whichever way the registry answers; that
  argument is sound and it is still an argument. One `validationRequest` on Arc Testnet with no
  response, then one `cast call`, converts it into an observation.

**And one thing this pass looked for and did not find, which bounds how much the gaps above
can be hiding.** The ten test files were swept for *vacuity* rather than for adversary surface,
on the reasoning that a test body has no adversary — the only way it can hurt you is by
passing without asserting anything. Four mechanical checks, all derived from the files. **All
four were re-run against the working tree on 2026-08-27 after #28, and both numbers are given
below: the anchor's figure first, then the current one.** Re-running them found an arithmetic
error in one of the four, recorded in place rather than quietly corrected.

- **157 → 165 `test_*`/`testFuzz_*`/`invariant_*` declarations counted from source**, now
  distributed `Creation` 34, `Bounds` 26, `Cosign` 24, `Views` 23, `Gates` 18, `Windows` 14,
  `Idempotency` 13, `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4, `Base` 0. The anchor's
  157 matched the runner's reported 157 exactly, which was the first time the count had been
  established **independently of `forge`'s own output** rather than quoted from it. **165 has
  not been reconciled against a runner** — `forge test` has not been run since #28 landed, so
  this is a source count and nothing more, and #14 owns the reconciliation. #28's arithmetic:
  Cosign 17 → 25 and Views 22 → 23, then Cosign 25 → 24 when a duplicate was deleted (the
  `spendHash`-on-unknown-mandate assertion had been written into both suites; the copy in
  `CosignTest` was removed on 2026-08-27 and a comment left in its place pointing at
  `ViewsTest`, because two suites asserting one line inflates this bullet without testing
  anything twice).
- **Zero vacuous bodies**, re-derived rather than restated: all 165 bodies were walked by
  brace-matching and every one contains at least one assertion or denial helper — 305 assertion
  calls (211 `assertEq`, 43 `assertTrue`, 29 `assertFalse`, 10 `assertGt`, 8 `assertLe`, 2
  `assertLt`, 1 `assertGe`, 1 `assertApproxEqAbs`), plus **49** `payReverts` call sites, 6
  `trySpend`, 4 `assertRevertedWith` and 5 `vm.expectEmit`.

  **Two of those helper figures were inflated by their own declarations, and the fix lowers
  them.** This bullet used to read 56 `payReverts`, 7 `trySpend`, 5 `assertRevertedWith`: raw
  grep totals over all eleven files, which count `Base.t.sol`'s four `payReverts` overloads and
  the three that delegate to a fourth, plus one declaration each for the other two. Subtracting
  the definitions leaves 49, 6 and 4 actual uses. None of it changes the conclusion — a helper
  declaration cannot make a vacuous body non-vacuous either way — and it is corrected here
  because the same slip in the same direction appears three times in this bullet's history, which
  makes it a habit rather than a typo: **a `grep -c` is a count of text, and calling it a count
  of call sites is a claim the grep did not check.**

  **The anchor's headline figure was wrong too, and its own parenthetical was the tell.** It read
  "287 assertion calls (202 `assertEq`, …)", and those components sum to 290, not 287. The true
  anchor count is **199 `assertEq`**, which makes the stated total of 287 add up exactly under
  the rule that produced it (every `assert*(` in all eleven `.t.sol` files, excluding the five
  `assertRevertedWith` listed separately as a denial helper). So the headline was right and one
  component was mistyped — the least harmful version of this error, and still the reason a
  document that reports sub-counts should have them checked against their own total.

  Two components moved for reasons worth naming rather than absorbing: `assertLt` 3 → 2 and a
  new `assertGe` 0 → 1 are the **same** edit, `ArcParity.t.sol`'s second `ARC_LIVE_GASUSED`
  comparison deleted and the derived zero-byte floor put in its place. That is the evidence loss
  F15 records, showing up here as a count.
- **Zero bare `vm.expectRevert()`.** Of 69 → **76** textual occurrences, exactly one is the
  shared helper's parameterised form in `Base.t.sol:318` and exactly one is inside a *comment*;
  the remaining 67 → **74** all name a specific error — 56 → 57 as
  `MandateManager.<Error>.selector` and 11 → **17** via `abi.encode*`, which pins the arguments
  too. The comment lives in `CosignTest.test_perTxCapBelowThreshold_isRefusedAtGrantTime`
  (cited by line number before #28 moved it), and it is warning against exactly this hazard in
  exactly these terms: without the expiry, that test *"would still revert and would still pass a
  bare `vm.expectRevert()` — while proving nothing about the cosign gate."* Somebody had already
  thought about this axis, in writing, before it was swept.
- **All 31 → 33 custom errors declared in `MandateManager.sol` are expected by at least one
  test.** No orphan error, checked by enumerating the declarations and grepping each name across
  `test/`. The two added by #28 are `CosignExpired(bytes32,uint40)` and `BadDeadline(uint40)`,
  named 2 and 3 times respectively; `BadConfig` remains the most-expected at 24.

**The first version of that sweep reported nineteen false positives, and the reason is worth
recording because it is the grep somebody will re-run.** Searching test bodies for
`expectRevert` under-reports badly, because most denials in this suite route through
`Base.t.sol`'s `payReverts` helper, which contains no such string. Nineteen perfectly
well-asserted tests looked empty. A vacuity check has to know the harness's vocabulary, or it
measures the harness instead of the tests.

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
That left exactly one: `expiresAt` — and #22 closed it at `v2:446`, so as of 2026-08-26 the
sweep finds no field in the struct that can be displayed and unread. That is a statement
about *this* struct and *these* thirteen fields only; it has to be re-run against any field
#13 or #23 adds, and neither of those has landed yet.

**The hostile-co-signer sweep, added 2026-08-26 as #16a**, was run the same way: not
against a list of attacks but by finding every site that reads `m.cosigner` or
`_cosignApproved` — seven at the time, listed in full after F18, where the post-#28 recount
to eight is also recorded — and asking of the role as a whole
*what can its holder do that the payer did not intend, including refusing to act.* It
produced F15 through F18 and one restatement of an existing §3 row. Two of the four are
about legibility rather than enforcement, which is now the dominant category in this
document; F15 is the first finding here about what a **participant** can see rather than
what the contract permits. The new entries are appended in sweep order rather than inserted
by severity, so that an F-number cited elsewhere never moves — F15 outranks F11 through F14
and sits below them.

**The hostile-recipient sweep, added 2026-08-26 as #16b**, was run identically: find every
site that reads `recipient` — four, all inside `spend` (`v2:614`, `615`, `690`, `713`), plus
the allowlist's single write site at `v2:558` — and then ask what the *absence* of a check
permits rather than what the present checks forbid. That inversion is what produced F19: the
recipient is constrained twice and only twice, so everything else is legal, and the most
interesting legal value is the payer's own address. It also produced two non-findings that
are recorded as non-findings rather than dropped, because an unbounded loop and an
Arc-documented no-log rule both look like findings until you check what reads them.

**One methodological result worth more than the findings.** F19 is the **third** time this
document has recorded a hazard that the repository already knew and had filed against the
wrong reader — F1 (`expiresAt`, known to `CHANGELIST.md`), F5 (`Unbounded`, known to the
model), and now F19, which `L3-VAULT.md:492-496` states completely, including the missing
system log, for an audience building a shielded vault. Three instances make it a process
defect, not a coincidence: **a hazard discovered while writing for one audience gets filed
against that audience and nowhere else.** The corrective is cheap and should be adopted — any
document that discovers a hazard about `MandateManager` gets a line in `THREAT-MODEL.md` in
the same commit, even when the discovering document handles it correctly for its own reader.
Nothing in the repository currently requires that, which is why it has now happened three
times.

**What has not been swept:** the actor-versus-actor matrix is complete for the delegate, for
third parties, for the **co-signer** and for the **recipient**, and as of 2026-08-26 the
Solidity surface is complete too — all eleven test files and both mocks have now been read,
deliberately not equally. `test/mocks/MockUSDC.sol`, `test/mocks/MockRegistries.sol` and
`test/Base.t.sol` were read in full, because they carry the trust assumptions that bound what a
green suite is able to mean; that produced F23, F24, F25, F26 and the two lists under *"What a
green suite cannot mean"*. The other ten were swept for **vacuity** rather than adversary
surface — a test body has no adversary, so the only way it can hurt you is by passing without
asserting anything — and that produced no findings at all, which is reported in §5 as a result
rather than omitted as a non-event. **There is no deploy script and there never has been:**
`git log --all --diff-filter=A --name-only` shows no `.s.sol` path and no `script/`
directory anywhere in the repository's history, because v1 was deployed by hand with
`forge create`. An earlier version of this paragraph was wrong on both counts, saying "the
four other Solidity files" when there are thirteen, and implying a deploy script existed to
be swept.

**How the trust-assumption sweep was run, and the two moves that produced everything in it.**
Neither was a search for bugs in the mocks; a mock has no users. The question was *what does a
passing test prove about Arc*, which turns every simplification in a mock into a claim, and
`MockUSDC`'s own header is a model for the practice by naming the one it makes most loudly (the
18-decimal dual view, unmodelled, with the reason). The first move was to **read each mock
against the platform documentation rather than against the contract** — which is how the
`getValidationStatus` tuple got checked against Arc's published ABI, an assumption no test in
this repository can reach, since the mock implements our own declaration and would agree with a
wrong one. The second was to ask, of every guard, *what the guard actually compares* — which
turned `Creation.t.sol`'s well-tested `address(0)` registry check into F24 the moment the
question became "and what about an address with no code".

**The correction owed to the first attempt, since this document is about method.** The vacuity
sweep was run once with a grep that under-reported nineteen tests as assertionless, because it
did not know that `payReverts` is where 49 of the suite's denials live — every one of them
routing through the single parameterised `vm.expectRevert` in `Base.t.sol`, which is why a grep
for `expectRevert` in test bodies finds none of them. It was caught by disbelief at the result
rather than by rigour — the list contained
`test_zeroAmount_reverts`, which cannot plausibly be assertionless — and that is a weaker
control than it should be. The general lesson is the one §5 now records: an automated check over
a codebase with a harness has to be told the harness's vocabulary, or it silently measures the
wrong thing and reports a clean-looking number either way.

---

*Nothing in this document should be read as a claim that Remit is secure. It is a claim
about what has been looked at, by whom, and how — which is the only kind of claim its
author is in a position to make.*
