# Adversarial sweep — PARTIAL RUN, 2026-09-15, extended 2026-09-17

> **THIS IS NOT A COMPLETE SWEEP.** Three of twelve lenses finished. Nine did not.
> Do not read the absence of a finding from lenses 2–5, 7–8, 10–12 as a clean result.
> This file exists so the three that *did* finish are not lost to a context boundary.

## Run metadata, derived not remembered

| | |
|---|---|
| Orchestrator | `solidity-auditor` v3 (pashov/skills), default mode |
| Bundle dir | `outputs/.audit-wZxgLE` (fresh build, **diff 0 lines vs working tree**) |
| In-scope | `contracts/MandateManager.sol` (2,969 lines) · `script/Deploy.s.sol` (298 lines) |
| `source.md` | 3,274 lines |
| Bundles | 12 × 3,430–3,482 lines; **44,651 total** |
| Agent model | Opus 5, by omission of the `model` parameter |
| Tree state | HEAD `0e77d62` + 10 uncommitted files (F13 working set) |

**Scope correction made during the build.** The skill's documented `find` lacks `-type f`. In a
Foundry repo `out/`, `broadcast/` and `cache/` contain *directories* named `*.sol`
(`out/MandateManager.sol/` holds the JSON artefact), so the documented command admits ~24 phantom
paths. Verified each with `[ -d ]` before excluding. Real in-scope set is two files.

## Lens completion table

| # | Lens | Outcome |
|---|---|---|
| 1 | math-precision | **COMPLETED** (batch 2, 2026-09-17) — 2 FINDINGs, 2 LEADs |
| 2 | access-control | **API `ENOTFOUND`, partial** — trail recovered, see below |
| 3 | economic-security | failed: prompt too long, automatic compaction failed |
| 4 | execution-trace | interrupted, no output |
| 5 | invariant | interrupted, no output |
| 6 | periphery | **COMPLETED** — 2 FINDINGs, 3 LEADs |
| 7 | first-principles | interrupted, no output |
| 8 | asymmetry | interrupted, no output |
| 9 | boundary | **COMPLETED** — 0 FINDINGs, 3 LEADs |
| 10 | numerical-gap | API `ENOTFOUND`, partial, no findings emitted |
| 11 | trust-gap | failed: malformed response (`StreamIdleTimeoutError`) |
| 12 | flow-gap | failed: malformed response (`StreamNoEventsError`) |

Completed: **3/12.** Emitted: **4 FINDINGs, 8 LEADs**, before judging.

**The failures are NOT quota this time.** Earlier rounds returned HTTP 403 on account quota; these
are transport-layer (`ENOTFOUND`, non-Anthropic request-ids, gateway content-type anomalies) plus
four interrupts. Different blocker, different fix.

**Batch structure.** Round 3 spawned all twelve at once and lost ten. The 2026-09-17 continuation
re-spawns in batches of three or four. Batch 2 (lenses 1, 4, 5, 7) returned lens 1 and lost the
other three to interrupts, so batch size alone is not the whole fix.

---

## LENS 1 — math-precision — COMPLETED (batch 2, 2026-09-17)

> **Provenance, stated rather than glossed.** The other two lenses below are the agent's verbatim
> text. Lens 1's is not: its reply was lost to a context boundary between the agent returning and
> this file being written. What is recorded here is the **orchestrator's re-derivation** — every
> claim re-checked against the working tree with `grep -n` / `sed -n` on 2026-09-17, nothing
> relayed. That makes the citations *stronger* than the two verbatim sections, which had to be
> corrected after the fact, but it means the phrasing is mine and the agent's own wording is gone.
> Both FINDINGs are documentation defects, and both are recorded because this project holds a
> comment to the same standard as a guard.

### FINDING | MandateManager (errors block) | stale-derived-count

**path:** reader → the errors block at `:544-576` → two numbers in it contradict two numbers four
lines above them, inside the very comment that warns *"a total that comes out right is not evidence
that its terms do."*

**proof, re-derived 2026-09-17:**

| claim | derived evidence |
|---|---|
| the census is 40 | `grep -cE '^\s*error [A-Za-z0-9_]+\('` = **40** |
| the partition holds | `:548` "the model's 27 `Denial` reasons", `:549` "all 4 of its `ApprovalRefusal` codes", `:552` "nine of the errors below have no model counterpart" — and `:554-558` names exactly nine: MandateExists, Unbounded, BadWindow, NotAuthorised, MixedPayers, DuplicateMandate, TooManyMandates, TransferFailed, RegistryHasNoCode |
| the model agrees | `node -e` over `reference/policy.js` → `Denial` = **27** keys, `ApprovalRefusal` = **4** keys. 27 + 4 + 9 = 40 |
| the block knows it is 27 | `:561-562` "The first term went from 26 to 27 on 2026-09-10, when F13 split `CredentialFailed` out of `CredentialMissing`" |
| the block knows it is nine | `:560` "the ninth term added on 2026-09-02" |
| **`:567` contradicts both** | "SpendCountCeiling is the newest of **the 26**" — the set is 27, **and** `CredentialFailed` (2026-09-10) is newer than `SpendCountCeiling`, so the count and the superlative are both stale |
| **`:573` contradicts `:552`** | "**The eight** above sit outside the model" — `:552` and the list at `:554-558` both say nine |

**description:** Two derived counts inside the errors block were not carried forward when F13 added
`CredentialFailed` as the 27th `Denial`, so the block states 27 and nine in its header and 26 and
eight in its body. The arithmetic that the header checks (`27 + 4 + 9 = 40`) is correct; the two
stale terms sit below it, which is the exact failure mode the same comment warns about.

**fix:** `:567` "the newest of the 26" → "one of the 27" (`CredentialFailed` is the newest);
`:573` "The eight above" → "The nine above". **Must be LINE-NEUTRAL** — 216 contract pointers
depend on these coordinates.

### FINDING | MandateManager.approveCosignFor | false-invariant-comment

**path:** reader or future editor → `:2145-2150` → believes spend-hash agreement depends on
`amount96`'s width → preserves a coupling that does not exist, or breaks the real one without
noticing.

**proof, re-derived 2026-09-17:** the comment at `:2148-2150` says narrowing here "keeps the local
the same width as the one `spend` hashes, which is what makes the two spend hashes agree."

| claim | derived evidence |
|---|---|
| `spendHash` takes a uint256 | `:2392 function spendHash(bytes32 mandateId, address recipient, uint256 amount, bytes32 ref, bytes32 nonce)` |
| `spend` passes the uint256 | `:1399 hash = spendHash(mandateId, recipient, amount, ref, nonce);` |
| `approveCosignFor` passes the uint256 | `:2236 hash = spendHash(mandateId, recipient, amount, ref, nonce);` |
| neither hashes `amount96` | `grep -n amount96` returns **nine** lines — `:1335, :1339, :1349, :1375, :1388, :1391` in `spend` and `:2152, :2175, :2179` in `approveCosignFor`. **Every one is cap arithmetic.** No `spendHash` call site is among them |

So "the one `spend` hashes" has **no referent**: `spend` hashes no uint96 local. The two hashes
agree because both functions pass the same `uint256 amount` into the same function — the width of
`amount96` is irrelevant to it. The rest of the comment is sound and must survive: the cast at
`:2152` is made safe by the unconditional `:2144 if (amount > type(uint96).max) revert
AmountTooLarge();` directly above it, and the closing warning "If the guard above is ever made
conditional this becomes unsound" is true, and `spend`'s twin at `:1327-1333` says the same thing
and says it correctly.

**description:** The comment attributes spend-hash agreement to a width coupling between two uint96
locals, but both hashes are computed from the `uint256 amount` parameter; the claimed invariant does
not exist and the sentence would mislead an editor into protecting the wrong property.

**fix:** delete the "and keeps the local the same width as the one `spend` hashes, which is what
makes the two spend hashes agree" clause; keep the narrowing rationale and keep the conditional-guard
warning. **LINE-NEUTRAL** — reflow within the existing line count.

### LEAD | MandateManager.spendableNow / previewSpend | truncation-scope

The ARC NOTE at `:2805-2813` scopes Arc's 6-over-18 decimal truncation to `balanceOf` alone — "this
is also the only place the contract reads a balance at all" — and derives a one-directional
under-report from it. **But the same views also read an allowance**, at `:2836` and `:2964`
(`usdc.allowance(m.payer, address(this))` and `usdc.allowance(payer, address(this))`), and the note
says nothing about whether that 6-decimal view sits over an 18-decimal native quantity the same way.
If it does, the min() these views take is truncated on a second input and the note's enumeration is
incomplete; the *direction* of the error would still be down, so the safety conclusion likely
survives even if the scope sentence does not. **Unverified:** whether Arc's native USDC stores
allowances at 18 decimals. The arc-docs MCP was disconnected at the time of writing, so this was not
resolved against Arc's own documentation — it must be, before either wording is changed.

### LEAD | MandateManager header banner | enumeration-does-not-sum

`:19-20` reads "Thirty-one live transactions, every one status 1: five mandates, five spends, three
revocations, two cosign approvals, two withdrawals." The colon reads as an enumeration, and the
enumeration sums to **17**, not 31. **Unverified:** whether the colon was meant as *namely* (in
which case one of the two numbers is wrong) or as *including* (in which case the sentence is merely
ambiguous and the remaining 14 are approvals, transfers and failed-path probes not broken out).
This sits inside the banner about v1's TAGGED source, so the resolution is a receipt count from the
deployment record, not from this file. Deliberately not "fixed" on a guess — see
[[remit-testnet-deployment]], which records the live phase closing at 31 txs.

### Proved clean and explicitly not reported by lens 1

Every downcast is guarded immediately above its use; every overflow guard is algebraically
rearranged to avoid the operation it tests (`totalCap - amount96` rather than `totalSpent +
amount96`); no division appears in a path that could see a zero divisor; the ring buffer's
`buckets + 1` sizing eliminates live-slot aliasing with the commit invariant holding on all four
branches; `spendableAcross`'s eight clamped uint96 terms max at `8 * (2^96 - 1) = 2^99 - 8`, far
inside uint256; the struct packing byte counts add up; `F_KNOWN = 0x7F` with `~F_KNOWN == 0x80` as
the single unused bit; Solidity's inverted `&`/`!=` precedence is respected at every flag test; and
the JS model mirrors the same arithmetic at `reference/policy.js:250-265` and `:1060-1078`.

---

## LENS 6 — periphery — COMPLETED

### FINDING | MandateManager.createMandate | missing-role-guard

**path:** payer → `createMandate(salt, p)` with `p.cosigner = address(mandateManager)` →
`_mandates[id].cosigner` written once, no mutator exists → every spend above `cosignThreshold`
reverts `CosignRequired` for the life of the mandate, while `getMandate` reports `F_COSIGN` set and
a plausible cosigner.

**proof (agent's, line numbers UNVERIFIED — see the correction note at the foot of this file):**
`createMandate` validates `cosigner` in exactly two places — the biconditional
(`(flags & F_COSIGN != 0) != (p.cosigner != address(0))`) and `if (p.cosigner == p.spender) revert
BadConfig();`. Neither refuses `address(this)`. `approveCosignFor` gates on
`if (msg.sender != m.cosigner) revert NotCosigner();`, and no path in the contract issues an
external CALL to itself (`spendHash` is called internally, which is a JUMP and leaves `msg.sender`
unchanged), so `msg.sender == address(this)` is unreachable there. Therefore no approval can ever
be written, and `spend`'s branch `if (validUntil == 0) revert CosignRequired(hash);` fires forever.
There is no `setCosigner`, and `revoke` leaves `_mandates[id].payer` non-zero so `createMandate`
answers `MandateExists` for that salt permanently. **The identical defect is refused on both sibling
role fields:** F45 (`p.spender == address(this)`, on the stated ground "no path in this contract
calls `spend`") and F51 (`p.revoker == address(this)`, "no path in this contract calls `revoke`, so
it could never exercise the role"). No test anywhere sets a cosigner to the manager's address.

**description:** `cosigner` is the only one of the three role fields not checked against
`address(this)`, so a grant can permanently name a co-signer that no caller can ever be, silently
capping the mandate at `cosignThreshold` while displaying a control it does not carry.

**fix:** Add `if (p.cosigner == address(this)) revert BadConfig();` beside the existing
`p.cosigner == p.spender` guard, mirroring F45's spender guard and leaving `cosigner == payer`
legal as the adjacent line requires.

### FINDING | MandateManager.isCosignApproved | view-enforcement-divergence

**path:** cosigner → `approveCosignFor` at `spendCount == type(uint32).max - 1` (accepted) →
spender consumes the last increment with any other nonce → `spendCount == type(uint32).max` → the
stored approval is unconsumable forever, and `isCosignApproved` still returns true.

**proof:** `approveCosignFor` refuses `if (m.spendCount == type(uint32).max) revert
SpendCountCeiling();`, and its own comment classifies this as permanent death and as "the one bound
in this block that ignores `amount`: the shortfall is total, instead of being relative to the sum
the co-signer named." `isCosignApproved` returns `validUntil != 0 && block.timestamp < validUntil
&& !_isPermanentlyDead(_mandates[mandateId])`, and `_isPermanentlyDead` tests only
`payer == address(0)`, `revoked`, and `F_EXPIRY && block.timestamp >= expiresAt`. The counter
ceiling is in neither. The docstring makes an explicit exhaustiveness claim — "What this still does
not cover, stated rather than implied: a lifetime cap with no headroom left, and a nonce already
burned. Both need the amount or the nonce, neither of which this signature carries" — which is
**false twice over**: `SpendCountCeiling` is not listed at all, and it needs neither the amount nor
the nonce, so the stated reason for excluding the listed pair does not reach it. `Cosign.t.sol:1572`
asserts the pre-ceiling half and stops one spend short of the divergence; no test covers the
post-ceiling view state.

**fix:** Add `if (m.spendCount == type(uint32).max) return true;` to `_isPermanentlyDead`, or the
equivalent test inline in `isCosignApproved`, and correct the exhaustiveness sentence.

### LEAD | Deploy._checkRegistries | weak-precondition-probe

The script probes USDC *behaviourally* — `_checkDecimals` issues `staticcall(decimals())`, requires
`ret.length == 32`, validates the decoded value — but probes the registries only *structurally*,
`identity_.code.length == 0`. The constructor makes the same structural check, and its comment
states precisely the failure mode being guarded: "Solidity's `catch` covers a call that reverted, so
it does not cover a success whose return data will not decode into the declared tuple — that revert
is raised while decoding, inside this contract's own frame, past the catch arm." A non-zero
`code.length` does not imply a decodable return: a minimal proxy whose implementation is codeless
has code, delegatecalls to nothing, succeeds, and returns zero bytes — and both ERC-8004 registries
sit behind upgradeable proxies by the contract's own account. The repo's `SilenceableRegistry` is
exactly this shape and would pass both guards. **Unverified:** deploy-time harm, since the pinned
Arc registries were measured answering correctly; the reachable case is a post-deploy proxy upgrade
no constructor check could catch, and the post-grant half is already tracked as open F49 work.

### LEAD | MandateManager.constructor | unmirrored-deploy-guard

The constructor adopted `RegistryHasNoCode` from the script with an explicit rationale — "Refused at
construction rather than at grant time because these addresses are immutable: past this line the
only remedy is a fresh deployment, and the script's copy of this test protects only deployments that
use the script." That argument is general, but `_checkDistinct` was **not** mirrored, and its own
comment concedes the gap in the same breath as the harm: "Nothing in the constructor requires the
three to differ, and one of the collisions does harm without looking wrong." Harm verified as real:
with `validation_ == identity_ == I`, `_isUndebitable` evaluates to `{this, usdc, I}`, so the
genuine ValidationRegistry becomes an accepted recipient — an address that can never return USDC
regardless of whether this deployment reads it. `Deploy.s.sol`'s header records that v1 shipped by
`forge create`, bypassing every semantic check in the script. **Unverified:** whether a non-script
deployment is still a supported path for v2.

### LEAD | MandateManager.createMandate | decorative-control

The file refuses `address(this)` on `spender` and `revoker` under one predicate — this party could
never exercise the role — then states, justifying why the other three undebitable addresses stay
legal as spenders, that "USDC on Arc is a precompile and cannot originate a call at all, while
either ERC-8004 registry sits behind an upgradeable proxy that could one day hold an implementation
calling `spend`." **The escape clause is written for the registries and does not cover USDC, yet the
sentence admits all three on it.** By the comment's own claim, `spender == address(usdc)` is exactly
as dead as `spender == address(this)`, and `revoker == address(usdc)` is a kill switch that can
never fire — the shape `setRevoker`'s comment calls "a protection that reads as arranged and can
never be used." **Unverified:** the CallFrom/precompile call-origination premise is recorded as
asserted from Arc documentation rather than measured.

**Proved clean and explicitly not reported by lens 6:** the ring-buffer ring (live-collision
else-branch unreachable under non-decreasing timestamps; slot `+=` cannot overflow because `used`
provably contains `cur.amount`); `windowRemaining` vs `_checkAndCommitWindows`; `spendHash` (spender
read from storage, nine static fields, no caller influence); `spendableAcross` (8 clamped uint96
terms cannot overflow); the F30/F39/F47 reservation sweep (`flags` and `cosignThreshold` both
write-once); `_isUndebitable` collapsing on a zero registry (all four call sites reject `address(0)`
first); and the registry-transposition hole in `_deploy`'s self-comparing read-backs, already a
named, tested, accepted tradeoff at `test/Deploy.t.sol:294-321`.

---

## LENS 9 — boundary — COMPLETED — 0 FINDINGs, 3 LEADs

### LEAD | MandateManager._isUndebitable | incomplete-denylist

**boundary:** MandateManager → Arc native USDC transferFrom destination.
**assumption:** the helper enumerates "the addresses that can accept USDC and can never send it
back," and F38 "widened F29's original pair to the full set."
**actual:** The set is four (`address(this)`, `usdc`, `identityRegistry`, `validationRegistry`).
Arc's system emitter `0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE` has the same property and is
absent. Arc's EVM-differences page establishes that transfers to codeless addresses **succeed**
("Sending to an address with no code (EXTCODESIZE == 0) succeeds and emits a Transfer log"), so the
chain does not refuse it the way it refuses precompiles.
**code smell:** the contract already names this exact address ~2,000 lines earlier, reasoning about
its logging behaviour for the `SelfPayment` guard — so the address was in the author's model but did
not reach the list.
**Same docs sentence REFUTES the precompile variant:** "Sending value to a precompile address
reverts," so `0x01`–`0x09` are not in the dangerous class and `address(usdc)` at `0x3600…0000` is
banned redundantly. Of the four entries, only the two registries and `address(this)` are
load-bearing.
**severity:** Low — this guard protects against payer/delegate mistakes, not attackers, and
`F_ALLOWLIST` is the real recipient control.
**fix if confirmed:** add `|| a == 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE` to `_isUndebitable`.

### LEAD | MandateManager.createMandate | phantom-control-nomination

Independently reaches the same doctrine lens 6's finding rests on, from the opposite side: the
contract refuses `address(this)` in caller-role fields under "a grant must not carry the appearance
of a control without its substance," but **accepts `address(usdc)` in both caller-role fields** while
asserting as established fact that "USDC on Arc is a precompile and cannot originate a call at all."
By that premise a revoker of `address(usdc)` can never call `revoke`. **The revoker half is not
self-harm:** F42's stated purpose is that "a payer whose USDC has been spent down to where their own
gas is unaffordable still has someone able to switch the mandate off" — so the failure is realised
exactly when a delegate is actively draining the payer and no solvent party can stop it. The spender
half is self-harm only (one salt consumed, recoverable under a new salt).
**Unverified:** whether Arc can ever present `0x3600…0000` as `msg.sender`; if it could, the
comment is what is false instead.

### LEAD | MandateManager contract header (SCOPE) | unsound-scope-claim

The header gives the sufficiency condition for the cap being real — "this is a real cap ONLY when
this contract is the spender's sole path to the payer's funds — payer is an EOA, agent holds no key
to it" — and frames the unsafe case as "if the payer is a smart account."
**The EOA / smart-account dichotomy is not stable on Arc.** EIP-7702 is live ("Arc's Osaka baseline
includes EIP-7702"), so a payer EOA can delegate code to a smart-account implementation **without
changing its address**. The payer then becomes precisely the "module with execution rights" case the
header says "enforces nothing" — after the mandate was granted, with no address change, no event,
and nothing the mandate can observe. Arc also runs live EIP-3009 `transferWithAuthorization` relayer
flows, a second signature-authorised path out of the payer's balance that consults neither the
allowance nor the mandate (that one needs the payer's own signature, so it does not break the stated
condition, but it widens the set of paths a reader of SCOPE would not expect).
**fix if confirmed:** restate the condition as *continuous* rather than initial — the payer address
must hold no delegated code for the life of the mandate — and name EIP-7702 explicitly alongside the
4337 limitation already documented.

### Actively refuted by lens 9 (recorded so future hits on these can be knocked down fast)

- **Hash-zero grant-time DoS** — a real record exists on live Arc at `requestHash == bytes32(0)`
  (validator `0xB152c3B6436318aD340153f1d30C9BBb8634681A`, agentId 16330). If
  `_requireCredentialAtGrant` could reach it with `c.validator == 0`, every grant would revert
  `CredentialWrongValidator`. **Refuted:** the `requestHash == 0` guard precedes the call, and the
  whole block is gated on `F_CREDENTIAL`.
- **Storage resurrection via mandateId reuse** — **refuted:** any id whose `payer != address(0)` is
  refused, and `revoke` only ever sets `revoked = true`, never clearing `payer`. No id is
  re-inhabitable; no `.flags =` exists outside the struct literal, so the
  `F_CREDENTIAL` ⟺ `validator != 0` biconditional is permanent.
- **Inline `IValidationRegistry` tuple-shape mismatch** — **retired**, not merely unproven: the
  6-field flat shape was decoded word by word from a live 2026-08-24 probe recorded at
  `test/mocks/MockRegistries.sol:92-107`. Single-sample, but a real measurement.
- **Precompiles as burn recipients** — **refuted by Arc**: "Sending value to a precompile address
  reverts."
- **Multicall3From cap bypass** — **refuted:** every cap is re-read from committed state per
  `spend`, so atomic batching accumulates rather than bypasses; `clearReservation` is payer-only and
  unreachable by the spender.
- **Memo/CallFrom sender spoofing** — **refuted:** CallFrom preserves the original sender and
  exposes no caller-chosen `from`.

---

## LENS 2 — access-control — PARTIAL, killed by `ENOTFOUND`

Recovered trail, verbatim, because it **independently converges on lens 6's finding**:

> The test corpus is the clincher: `Creation.t.sol:308` tests `p.spender = address(mm)`,
> `Revoker.t.sol:149` tests `revoker == address(mm)` at grant, `Revoker.t.sol:255` tests
> `setRevoker(id, address(mm))` — and there is **no `p.cosigner = address(mm)` anywhere in the
> suite**. Guard and test are both absent.

Two independent lenses reaching the same missing guard by different routes — lens 6 from the
contract's own role-guard doctrine, lens 2 from the test corpus — is the multi-agent convergence
`judging.md` treats as a promotion signal.

---

## Orchestrator verification — 2026-09-17, derived with `grep -n` against the working tree

**Lens 6 and lens 9 disagreed by ~350 lines about where the spender guard lives** (lens 6 cited
`:1212`, lens 9 cited `:860`). **Lens 9 was right; lens 6's coordinates were wrong** while its
substance was correct. Every citation below is re-derived, not relayed.

### Finding 1 — CONFIRMED, every link in the chain verified

| link | derived evidence |
|---|---|
| spender IS guarded | `:846 if (p.spender == address(0))`, `:860 if (p.spender == address(this))` — F45 |
| revoker IS guarded | `:1205 if (p.revoker == address(this) \|\| p.revoker == msg.sender \|\| p.revoker == p.spender)` — F51, mirrored in `setRevoker` at `:1945` |
| cosigner is NOT | only `:898` (the `F_COSIGN` ⟺ `cosigner != 0` biconditional) and `:985 if (p.cosigner == p.spender)`. **No `address(this)` test exists.** |
| the gate it bricks | `:2185 if (msg.sender != m.cosigner) revert NotCosigner();` |
| unreachable as sender | grep for `this.` / `address(this).call` / `delegatecall` returns **only comments** — the contract makes no external call to itself, so `msg.sender == address(this)` cannot occur |
| write-once | `grep -c 'function setCosigner'` = **0** |
| salt burned forever | `grep -c 'delete _mandates'` = **0**; `revoke` only sets `m.revoked = true` |
| the permanent revert | `:1448 if (validUntil == 0) revert CosignRequired(hash);` |
| fix must not break | `:983-984` — "`cosigner == payer` stays legal and is the ordinary case — it is what mandate 2 does on Arc today" |

The doctrine the gap violates is stated in this contract's own comment at `:978`: *"a control the
grant does not carry is refused rather than documented."*

**Judging, applied honestly rather than favourably.** By `judging.md` Gate 4 this is **self-harm →
REJECTED** as a finding: the payer bricks their own mandate, no attacker, no third-party victim, no
authority leak, fail-closed. By Remit's own bar it is a live defect — F45 and F51 both landed on
exactly this reasoning for the sibling fields, so the project has already committed to refusing this
class rather than documenting it. **Reported as a one-line consistency defect, not as a
vulnerability.** Tracked as task #21.

### Finding 2 — CONFIRMED as a documentation defect, DEMOTED as a vulnerability

`_isPermanentlyDead` at `:2672-2676` verified to test only `payer == address(0)`, `m.revoked`, and
`F_EXPIRY && block.timestamp >= m.expiresAt`. The ceiling is refused at `:2187` inside
`approveCosignFor` and read by `isCosignApproved` at `:2558`, so the divergence is real. But it needs
**2^32 = 4,294,967,296 spends**, which fails Gate 2 reachability and Gate 4 impact. What survives is
the docstring's false exhaustiveness claim, which this project does hold to a true standard. Tracked
as task #22.

### What this partial run does NOT license

Nine lenses produced nothing. `economic-security`, `execution-trace`, `invariant`,
`first-principles`, `asymmetry`, `numerical-gap`, `trust-gap` and `flow-gap` never reported, and
`access-control` died mid-trail. **No claim about economic, invariant or trace safety in the F13
change is supported by this run.** `math-precision` did report and swept arithmetic clean, but it
found nothing in F13's grant-time block either — **all four findings are in pre-existing v2 surface,
so F13 itself remains unswept.**
