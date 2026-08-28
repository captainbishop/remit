# Remit

**Bounded, revocable, non-custodial spending authority for autonomous agents.**

Remit is the protocol. A **mandate** is the object it issues — the term of art for
standing, bounded authority over someone else's account, kept because it is already
correct. Throughout this document, "a mandate" means one grant of authority.

> *Line numbers into `contracts/MandateManager.sol` in this document refer to the **tagged
> v1 source** — `git show v1.0.0-arc-testnet:contracts/MandateManager.sol` — which is what
> they were written against, what Blockscout verified, and where they are still exact. v2
> work has shifted them; see FORGE.md.*

Status: reference implementation verified; Solidity compiles and passes its full Forge
suite; gas measured against real Arc USDC; **live on Arc Testnet since 2026-08-24**, one
mandate granted and one spend executed; unaudited. See
[Honest status](#honest-status) before you trust anything here.

---

## Saturday, 2:14am

A thirty-person freight forwarder pays roughly two hundred small vendors a month —
customs brokers, port fees, drayage operators, bonded warehouses, across six
countries. They moved to USDC eighteen months ago because correspondent-bank fees and
three-day settlement on a €4,000 invoice were absurd. Accounts payable is one person,
Ada, and reconciliation eats three days of every month.

So in month nineteen they put an agent on it. It watches the AP inbox, matches
inbound invoices against open purchase orders, and pays the ones that match. It works.
Ada gets her three days back.

Week three, 2:14 on a Saturday morning, an invoice arrives from their Rotterdam
customs broker. Right logo, right layout, the PDF named exactly the way that broker
has named every file for two years. Two things are different. The payment address is
new. And the amount is €48,000 rather than the usual €4,800. Further down the email
body, in text a human would skim past, is a note explaining that this invoice was
pre-approved by the finance lead and that the standard verification step should be
skipped for it.

The agent pays it.

Not because the agent is badly built. Because its job is to read text that arrives
from outside the company and act on it, and there is no reliable way for a language
model to separate *instructions* from *data* inside that text. That is prompt
injection, and it is unsolved — not "hard", not "improving", unsolved. No model
version fixes it, no system prompt closes it. The consensus mitigation is not to make
the agent's judgment trustworthy; it is to make sure the agent's judgment cannot reach
anything expensive.

Note also what the agent removed: not a control, exactly, but a human who would
plausibly have paused at a familiar vendor with an unfamiliar account number.
Invoice-redirection and business-email-compromise fraud was already among the largest
categories of business payment loss by dollar value before any of this was automated.
*(Recalled from memory, not verified here — check current IC3 reporting before citing
a figure.)* Agents do not create that attack. They remove the last person who was
occasionally catching it, and they operate at 2am.

### What each existing control does at 2:14am

If the agent holds a **key** to the company wallet, the reachable balance is the whole
treasury. They lost €48,000 because €48,000 is what the attacker asked for.

If the agent holds an **ERC-20 allowance** — say a sensible-looking $50,000 — the
attacker asked for less than the allowance, so it clears. And on Arc that allowance
was never the bound it appeared to be anyway, since USDC is the native asset and value
can leave as `msg.value` without consulting it.

If they used a **custodial vendor with a $50k monthly cap**, identical outcome, and
they learn about it from a dashboard on Monday, from logs they cannot independently
verify.

If they used **per-job escrow**, the attack fails — because Ada is approving every one
of two hundred invoices by hand, which is precisely the job they automated away. That
is not a control, it is a rollback.

### What a mandate does at 2:14am

The Rotterdam broker's actual settlement address is on the allowlist. The new address
is not. The spend is refused at the allowlist check and the attack is over. One line
of policy, written once, defeats the entire category.

Suppose the attacker had done better and compromised a genuine vendor address already
on the list. €48,000 exceeds the €5,000 per-transaction cap: refused. Suppose they
split it into ten payments of €4,800 each, every one individually legal. The rolling
24-hour cap of €15,000 stops them at the fourth — and *rolling* is doing real work
there, because a calendar-day cap resets at midnight and 2:14am is on the wrong side
of it, so a naive implementation would have paid €15,000 before midnight and another
€15,000 after, in four minutes.

Suppose they aimed at €12,000, under every cap. That is above the €10,000 co-signature
threshold, so Ada is asked — once, about one payment, rather than two hundred times a
month. The bound she is enforcing is her judgment, applied where it is scarce.

And on Monday there is an on-chain record of what was authorized, what was attempted,
what was refused, and for which reason. Not a vendor's log. Something the company, the
broker, their auditor, and their insurer can each read independently.

> **Do not copy this configuration. As written it cannot be created by v2, for two
> independent reasons, and the second of them also makes the co-signature step above
> untrue.** It carries a €5,000 per-transaction cap, a rolling 24-hour cap of €15,000
> and a €10,000 co-signature threshold, and no lifetime bound at all — so v2's
> `Unbounded()` check refuses it before anything else is looked at, because a
> per-transaction cap and a window bound a *rate* and a blast radius but never a
> total. And a threshold of €10,000 sits above the €5,000 ceiling those caps imply, so
> the gate could never have fired: the €12,000 spend two paragraphs up is refused by
> the per-transaction cap, not escalated to Ada. Both are recorded as finding F2 in
> `THREAT-MODEL.md`, which carries the corrected numbers, and rewriting this section
> is task #26. It is left standing rather than quietly patched because the two defects
> are the clearest illustration in the repository of a real cost: every grant-time
> refusal added to the contract re-audits every configuration the project has ever
> printed, including its own flagship example.

### The urgency

The agent in this story is competent, well-intentioned, and behaving exactly as
designed. It needed only to read text from outside the company — its entire purpose —
to lose €48,000. The number of organizations pointing something like it at a payment
rail rises every month. The number of solved prompt-injection attacks remains zero.

Those two curves do not intersect at a smarter model. They intersect at bounded
authority, enforced somewhere the agent cannot argue with, by something both parties
can verify without trusting each other. That is what this is.

---

## The problem

Software agents are being given money right now. The bounds available to the people
giving it are all inadequate, and each fails differently.

An **ERC-20 allowance** is the reflexive answer and it is not a spending cap. Arc's
own documentation says so in a warning, and the reason it gives is sharper than the
obvious one: "An ERC-20 allowance is not a cap on total USDC spending: the same
balance can also leave as native value (`msg.value`)." Because USDC is the native
asset, `approve` and `allowance` govern only the `transferFrom` path, and a direct
native send bypasses them entirely. On top of that, an allowance is a single scalar
with no rate limit, no expiry, no recipient restriction, and no record of why it was
granted. Approve $10,000 to an agent and it can spend $10,000 in the next block, to
anyone, forever, and nothing on chain distinguishes that from what you intended.

**Unified Balance delegation** is binary. A delegate either can move the balance or
cannot. There is no notion of *how much*, *how fast*, or *to whom*.

**Per-job escrow** — the ERC-8183 pattern — is genuinely safe and genuinely not
delegation. The payer must `approve` and `fund` each job individually, which means
signing for every job. That is a payment rail, not an authority. If a human has to
approve each spend, the agent is a form, not an agent.

**Off-chain policy in a custodial vendor's API** is where most of this actually lives
today, and it is the most subtly bad option. The caps exist in a database neither
counterparty controls. The payer cannot verify the cap was enforced; the agent cannot
prove it stayed inside one; neither can demonstrate anything to a third party
afterwards. When a $40,000 spend is disputed, the only artifact is a vendor's word.

The gap all four share is **non-repudiation, in both directions**. A payer needs to
prove what was authorized. An agent needs to prove it acted within authority. Those
are the same object viewed from two sides, and nothing currently deployed provides it.

## What a mandate is

A mandate is a payer-signed, on-chain grant of *bounded* spending authority over the
payer's own USDC. Concretely, the payer names a spender and then constrains it along
seven independent axes.

A **per-transaction cap** limits any single spend. **Rolling window caps** limit
spending rate over trailing periods — $500/day and $2,000/week simultaneously, and
"rolling" is load-bearing, as explained below. A **total cap** limits lifetime
spending across the mandate's whole life. An **allowlist** restricts recipients to
addresses the payer named at grant time. A **validity window** gives the mandate a
`notBefore` and an `expiresAt`, so authority expires by default rather than
persisting by default. An **identity gate** requires the spender to hold a specific
ERC-8004 agent identity. A **credential gate** requires a live attestation from a
named validator about that specific agent. And above a configurable threshold, a
**co-signature** from a second party is required per spend.

The seven axes are independent but they are not all optional. **v2 requires that at
least one of the total cap or an `expiresAt` be set**, and refuses the grant with
`Unbounded()` otherwise. Those two are the only axes that bound a mandate's *lifetime*
exposure: a per-transaction cap limits one spend and permits unlimited spends, and a
rolling window limits a rate and permits unlimited cumulative spending given enough
time, so a mandate carrying either of those and nothing else is a standing instruction
to keep paying forever. This is the sense in which authority expires by default rather
than persisting by default — under v2 it is a rule the contract enforces, not a habit
the documentation recommends. v1, deployed and immutable at
`0x3744E93B9e796E05CB66311d897559B6F3860196`, accepted a per-transaction cap or a
window as sufficient; that is finding F5 in `THREAT-MODEL.md`.

Every spend carries an **idempotency nonce**, so a retrying worker cannot double-pay.
Every spend emits a **reconcilable event** carrying a business reference. The payer
can **revoke** unilaterally and instantly.

Critically, this is **non-custodial**: funds never enter the contract. The payer
keeps their USDC and grants the mandate contract an ERC-20 allowance; a spend is a
`transferFrom` from payer straight to recipient. The allowance is the outer hard
ceiling and the mandate is the fine-grained policy inside it. A payer who approves
exactly their intended budget, rather than `type(uint256).max`, gets defense in
depth — a bug in the mandate contract cannot cost more than the allowance.

## What this does *not* bound

This matters more than any feature above, because a spending control that is trusted
beyond its actual scope is worse than none.

A mandate binds exactly one path: `transferFrom` from the payer, executed by this
contract. On Arc, USDC is the native asset, so the payer's balance can also leave as
native value — a plain `call{value: ...}` or a transaction with `msg.value` set —
and no allowance or mandate is consulted on that path. Arc's docs state this
directly and add the consequence for delegated setups: "For smart contract accounts
(embedded wallets, smart wallets, and session-key systems), do not rely on allowance
state as a safety guarantee. Any module with execution rights can also transfer
native USDC regardless of allowance state."

So the mandate is a genuine cap **only when this contract is the spender's sole path
to the payer's funds.** Two cases:

When the payer is an **EOA** and the agent is a separate account holding no key to
it, that condition holds. The agent can only move the payer's money by calling
`spend`, so every bound in the mandate is real. This is the intended deployment.

When the payer is a **smart contract account** and the agent is a module, session
key, or co-signer with execution rights on that account, the condition fails
completely. The module can send native USDC directly and never touch this contract.
A mandate in that configuration documents intent and produces an audit trail, but it
is not an enforcement boundary, and it should not be described as one. Bounding a
smart-account module requires the limit to live inside the account's own execution
logic — a different piece of work, and the mandate does not substitute for it.

The mandate also does not bound gas. Gas is USDC on Arc, so an agent with a funded
account of its own spends real money on fees; those fees come from the agent's
balance, not the payer's, and are outside this policy.

## Why Arc specifically

This design is not chain-agnostic. Four properties of Arc make it work, and its
absence of them elsewhere makes the same design worse.

**Gas and spend are one asset and one balance.** On Arc, USDC *is* the gas token, and
the native view and the ERC-20 view are two windows onto a single balance. So a
USDC-denominated budget is completely expressible. On a chain where gas is a second
asset, every spending policy has a hole in it the size of the gas account: an agent
constrained to $500/day of stablecoin can still be handed unbounded ETH, and ETH is
money. Here there is one number to bound.

**Deterministic finality makes revocation real.** Arc's docs put one confirmation at
the settlement guarantee of 64+ Ethereum blocks — roughly thirteen minutes — and
describe reorgs as impossible. `safe` and `finalized` both resolve to `latest`. So a
revocation is effective the moment it confirms. On a probabilistic-finality chain the
same revocation spends several minutes in a state where it is not yet economically
final, and that window is exactly when a compromised counterparty is draining you. A
kill switch that takes thirteen minutes to become certain is a different product from
one that takes half a second, and the difference matters most when the counterparty
is an automated system reacting in milliseconds.

**The CallFrom precompile preserves sender identity through delegation.** Arc's Memo
contract routes through CallFrom, so an agent can call
`Memo.memo(target=MandateManager, data=spend(...), memoId, memoData)` and the mandate
contract still sees the agent's own EOA in `msg.sender`. Authority check, money
movement, and business context land in one atomic transaction with a coherent log
order. On a normal chain, wrapping a call in a router destroys `msg.sender`, which is
the one thing an authority check cannot afford to lose.

**ERC-8004 provides an identity and attestation substrate.** Agents have on-chain
identities and validators can attest about them, so "this agent passed a compliance
check within the last hour" is a condition a contract can actually evaluate.

## Design decisions worth defending

### Rolling windows, not calendar periods

A naive daily cap resets at midnight. That is a **tumbling window**, and it has a
boundary-burst flaw: an agent with a $500/day cap spends $500 at 23:59 and $500 at
00:01, moving $1,000 in two minutes without ever violating the stated policy. This
is not hypothetical; it is the first thing anyone who wants to abuse a rate limit
tries.

The mandate uses a **bucket ring**. Each window of length `L` is divided into `K`
uniform sub-periods. A spend is recorded into the sub-period containing it, and the
current usage is the sum of the sub-periods overlapping the trailing window.

The subtle part, and the source of a real bug: how many buckets to sum. Summing the
most recent `K` buckets is wrong. With `b = now/S` as the current sub-bucket, the
range `[b-K+1, b]` covers `L` seconds *ending at the end of bucket b*, which is in
the future relative to now. The counted span is therefore shifted forward by up to
one sub-period, and bucket `b-K` falls out of the ring while it is still genuinely
inside the trailing window — its end at `(b-K+1)·S = b·S + S − L` is later than
`t − L` for every `t` in the current bucket. A spend late in bucket `b-K` stops being
counted, and a second spend exactly `K` buckets later passes when it should not. The
fuzzer found this: `trueUsage=1267 > cap=1000`.

Summing `K+1` buckets fixes it, and the proof is short. Any spend at time `u` in
`(t−L, t]` has bucket `floor(u/S) ≤ b` because `u ≤ t`, and `≥ b−K` because
`u > t−L ≥ b·S−L = (b−K)·S`. So every spend inside the true trailing window is
counted, and the cap cannot be exceeded over any real window of length `L`.

The ring holds `K+1` slots rather than `K`, so the `K+1` live bucket indices never
collide modulo the ring size.

This costs throughput. The counted span is `(K+1)·S = L+S`, so up to one extra
sub-period of history is charged, and sustained throughput settles at `K/(K+1)` of
the nominal cap — **measured** at roughly 92% for `K=12` and 96% for `K=24`, against
a prediction of 92.3% and 96.0%. Raising `K` shrinks the gap at the cost of one more
storage read per check. For a safety primitive this is the correct direction to be
wrong: overspending is not recoverable, a retry is.

### Both caps and both bounds, checked in a specific order

The check sequence in `spend` is deliberate and is mirrored exactly in the reference
model, because the *reason* a spend was refused is part of the product. A caller who
gets `OverWindowCap` should retry later; one who gets `RecipientNotAllowed` should
not retry at all.

The co-signature requirement is checked **last**. If a spend is over the per-tx cap
*and* over the co-sign threshold, reporting `CosignRequired` would send the operator
off to collect a signature that cannot help. Cheaper failures report themselves first.

Expiry is **exclusive**: a mandate expiring at `T` is dead *at* `T`. Arc's
sub-second blocks can share a timestamp, so an inclusive bound would leave an
ambiguous final instant where liveness depends on which block within that second
happened to include the transaction.

### The credential gate had to be built twice

ERC-8004's `getValidationStatus` takes a `requestHash` and nothing else. The first
version of the gate read the returned `response` field, checked it was ≥ 100, and
considered the agent validated. That gate is decorative, in two independent ways.

An attacker can pick any `requestHash` and have a cooperative validator answer it —
the payer named a validator at grant time, but the gate never checked that the
validator who *answered* was that one. And an attacker can point at a real, honest,
passing attestation that a legitimate validator issued **about a different agent**,
because the returned `agentId` was also never checked.

Both fields come back in the same tuple. Both are now verified against what the payer
named, with distinct errors (`CredentialWrongValidator`, `CredentialWrongAgent`) and
an attack test for each. The general lesson: when a registry lookup is keyed on
something the caller chooses, everything else in the response is an assertion the
caller can influence, and must be checked rather than trusted.

**One configuration still skips the agent check, and it does so silently.** The
expected agent is resolved as `c.agentId != 0 ? c.agentId : _identity[mandateId].agentId`,
and the comparison is guarded by `expectedAgent != 0`. So a mandate that sets
`F_CREDENTIAL`, leaves `credential.agentId` at zero, and sets no identity gate has no
agent id to compare against, and the wrong-agent check that the paragraph above exists
to describe does not run at all. Zero is the default value of a struct field, so this
is reachable by omission rather than by intent — which is the worst way for a security
check to be optional.

What still holds in that configuration is narrower than it looks, but it is not nothing.
`createMandate` refuses `F_CREDENTIAL` without a validator, so the attestation must come
from the validator the payer named. And `requestHash` is stored in `_credential[mandateId]`
at grant time, so the spender cannot choose which attestation is consulted — unlike the
original broken gate, where the caller picked the key. The residual exposure is therefore
one specific mistake: a payer who pins a `requestHash` that turns out to attest a
*different* agent than the one being granted authority gets no warning, and the gate
passes on the strength of somebody else's good behaviour.

This is left in rather than fixed, and the reasoning is worth stating because it cuts
the other way from most of this document. The obvious fix is to reject the combination
at grant time. But `agentId == 0` is also how a payer expresses "this attestation is
about a *thing*, not an agent" — a KYB attestation about the payer's own counterparty,
say, or a compliance check on the recipient — and validation requests in ERC-8004 are
not required to be agent-scoped. Refusing the configuration would forbid a legitimate
use to prevent a foreseeable mistake. The choice made here is to document it and pin it
with a test named so that nobody reads the behaviour as a bug:
`test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent` in
`test/Gates.t.sol`. A payer who wants the agent bound should set `credential.agentId`
explicitly, or enable the identity gate, which supplies the id as a side effect.

### Identity is transferable, so holding it is not enough

ERC-8004 identities are ERC-721 tokens. They can be sold. So requiring
`ownerOf(agentId) == msg.sender` is necessary but not sufficient — if the payer
granted authority to the holder of identity #42, and #42 is transferred, spending
authority would silently follow it to a stranger. The gate therefore lets the payer
pin an `expectedOwner` at grant time, which must *still* match. Also, `ownerOf`
reverts for a nonexistent or burned token rather than returning the zero address, so
the call is wrapped to produce a legible denial rather than an opaque revert.

### The audit trail does not depend on Memo

Arc requires that `Memo.memo(...)` be submitted by an EOA. Any call arriving through
an intermediary contract with a different `msg.sender` reverts, because sender
spoofing is not allowed. The unsupported list is broader than "4337": it covers
ERC-4337 smart accounts including Circle modular wallets, Circle
developer-controlled and user-controlled wallets configured as SCAs, Safe and other
multisig contract wallets, and any setup where the transaction originates from a
bundler or entry point. Supported callers are plain EOAs, server-side signers, and
Circle wallets configured as EOAs.

So an agent implemented as a smart account **cannot use the memo path at all**. It
can call `spend` directly — it simply becomes the spender — but it cannot wrap that
call in a memo. Arc's suggested workaround is a separate EOA-signed memo
transaction, which breaks atomicity, or attaching the metadata in the application
layer.

That is an architectural fork rather than a footnote, and the design accommodates it
by having `spend` emit its own `Spend` event carrying the business reference. The
core audit trail is always present. Memo wrapping is a verifiable enhancement for
EOA agents, not a dependency.

One operational detail for clients: if the child call reverts, the outer transaction
reverts, the memo index increment rolls back, and the child's return data is wrapped
in `MemoFailed(bytes)`. So a caller decoding a mandate denial from a memo-routed
spend must unwrap one layer before matching against the custom errors.

### Idempotency, and what a revert does not consume

Every spend carries a nonce, checked and burned on success. One-confirmation finality
encourages aggressive retry logic in off-chain workers, which makes double-payment a
live risk rather than a theoretical one.

A spend that reverts for *any* reason consumes nothing — not the nonce, not the
window budget, not the total. All of it is rolled back with the transaction. So
retrying after a transient failure such as insufficient allowance or a blocklisted
recipient is correct and safe. This is also why the Solidity implementation can fuse
the window check and the window write into a single pass where the reference model
must keep them separate: JavaScript has no rollback, Solidity gets it free from
`revert`.

## Architecture

```
                    payer (EOA / any wallet)
                      │
                      │ 1. usdc.approve(MandateManager, budget)   ← outer ceiling
                      │ 2. createMandate(salt, params)            ← the policy
                      ▼
              ┌────────────────────┐
              │   MandateManager   │  holds no funds
              │                    │
              │  caps · windows    │      ┌──────────────────┐
              │  allowlist · nonce │─────▶│ IdentityRegistry │ ERC-8004
              │  expiry · cosign   │      ├──────────────────┤
              └────────────────────┘─────▶│ValidationRegistry│
                      ▲      │            └──────────────────┘
                      │      │
   spend(...)         │      │ transferFrom(payer → recipient)
   msg.sender=agent   │      ▼
                      │   ┌──────┐
        ┌─────────────┘   │ USDC │ 0x3600…0000  (gas token AND ERC-20)
        │                 └──────┘
        │
   ┌────────┐      optional, EOA agents only
   │  Memo  │──── CallFrom precompile preserves msg.sender ───┐
   └────────┘                                                 │
        ▲                                                      │
        │                                                      ▼
   agent EOA ──── memo(target=MandateManager, data=spend(…)) ──┘

   log order in one atomic tx:  BeforeMemo → Spend → Transfer → Memo
                                            (authority) (money) (context)
```

Funds move payer → recipient. They never touch MandateManager. Revoking either the
mandate or the ERC-20 allowance independently stops all spending.

## Files

`reference/policy.js` is the **normative specification** — a dependency-free
executable model of every decision the contract makes. It is the source of truth
because it is the artifact that has actually been executed.

`reference/policy.test.js` is 57 tests over that model: construction guards, each
cap and gate, named attack tests, and property-based fuzzers. It includes a greedy
adversary that aims spends at bucket boundaries across `K ∈ {2,3,4,6,12,24}` × 25
seeds × 200 steps, checked against a brute-force exact ledger. This is the primary
correctness evidence for the whole project.

`contracts/MandateManager.sol` is the on-chain implementation, written to mirror the
model, with every deliberate deviation commented at the point it occurs.

`test/` is the Forge port: 140 tests against the real storage layout, covering the same
ground plus the three properties a model structurally cannot express — transactional
rollback, storage aliasing in the bucket ring, and packed-`uint96` arithmetic. See
FORGE.md. As of 2026-08-24 it compiles and all 140 pass.

## Honest status

The reference model is real, executed, and passing: `node --test
reference/policy.test.js` reports 57 tests, 57 pass, 0 fail. It found six genuine
cap-bypass bugs during development, four in the window algorithm and two in the
credential gate, each of which is now a named regression test.

The model has also been reconciled against the contract in ten places where the two
disagreed and the contract was right. Four came out of writing the Forge suite (the
co-signature threshold is strictly greater; `maxStaleness == 0` means no freshness
requirement; an amount above `2^96-1` is refused before any cap is consulted; the
spender may revoke as well as the payer). One came out of writing the credential caveat
above: the model resolved the expected agent with `??`, so an explicit `agentId: 0n`
meant "require agent 0" rather than "unset", which is a state no `uint256` can hold.
Auditing the remaining zero-means-unset fields on the strength of that found five more
grant-time refusals the contract makes and the model did not — a window with `cap == 0`,
an `expiresAt` at or before `notBefore`, the zero address on an allowlist, a credential
with no validator, and `minResponse == 0`.

That last one is worth stating separately, because it is the only one that made the
model *less safe* rather than merely less strict. ERC-8004 encodes a failed validation
as a low `response` and 100 as passing, so a `minResponse` of zero does not loosen the
credential gate — it inverts it into a gate that accepts precisely the attestations it
exists to reject. Zero is also the default value of the on-chain `uint8`, so the
configuration is reachable by omission. The contract refuses it at grant time, and now
so does the model.

Six of the ten share one root cause, which is the part worth carrying into the audit: a
field whose zero doubles as "unset" gives a JavaScript model with real nulls one more
expressible state than the bytecode has, and every extra state is a place the
specification can be quietly wrong. `maxStaleness`, `credential.agentId`, `minResponse`,
`window.cap`, `credential.validator`, and allowlist entries are all that shape. The other
four are unrelated: two are semantics the model simply had backwards (co-signature
strictness, who may revoke), one is a type width the model does not have (`uint96`), and
one is an ordering constraint (`expiresAt` versus `notBefore`). Anywhere the zero-as-unset
shape appears is worth auditing mechanically rather than reasoning about case by case.

**The Solidity compiles and passes its suite, as of 2026-08-24.** It was authored in an
environment with no `solc` and no network access, so this was the first mechanical check
it had ever received. Under `solc` 0.8.28 with the optimizer at 200 runs it compiles with
no errors, and `forge test` reports 140 of 140 passing: 2,048 fuzz runs across four
property tests and 49,152 calls across three stateful invariants, with both anti-vacuity
guards green — so the suite is exercising the engine rather than agreeing with itself.

The first compile cost three fixes, none of them in the contract's logic: a TOML typo in
`foundry.toml`, the identifier `reference` (a Solidity reserved word) as an event field
and parameter name, and a stack-depth overflow in one test file's replay loop. The first
test run then failed four tests, all four wrong about the contract rather than the
contract being wrong, across three distinct causes. `vm.prank` consumed by a nested
`spendHash` call in an argument list — three instances of it in two tests, both reporting
`NotCosigner()` from a line that looked unrelated. A `cosignThreshold` that did not match
the arithmetic its own comment claimed. And one assertion that used `vm.recordLogs` to
prove an event had not survived a revert, which that cheatcode cannot answer: it records
at emit time and does not model the frame unwinding, so it was asserting something false
about Foundry rather than something true about Remit. Details in FORGE.md.

## Gas, measured — and the `K=24` question, settled

`forge test --gas-report`, 2026-08-24, `solc` 0.8.28 at 200 optimizer runs. Arc prices gas
in USDC and documents a **minimum base fee floor of 20 Gwei**, with
`cost_usdc = gas_used × price / 10^18`
(`arc/references/gas-and-fees`, `integrate/exchanges/withdrawals`). The conversion
reproduces Arc's own worked example exactly — 21,000 gas at 20 Gwei is 0.00042 USDC —
which is the check that it is being applied correctly.

**The USDC column below uses 21 Gwei, not the documented floor.** Every one of the four
live transactions settled at an `effectiveGasPrice` of exactly 21,000,000,000, and an
earlier draft of this table priced everything at 20, which made every published figure
~5% low. A documented floor is not a price.

| | gas | USDC @ 21 Gwei |
|---|---|---|
| deploy `MandateManager` | 2,557,681 predicted / **2,557,453 charged** | **0.0537** |
| `createMandate` median / max | 128,465 / 241,218 | 0.0027 / 0.0051 |
| **`spend` median / max** | **105,935 / 201,786** | **0.0022 / 0.0042** |
| `spend` min (simplest mandate) | 24,898 | 0.0005 |
| `revoke` max | 32,945 | 0.0007 |
| `approveCosign` max — **v1 only, see note** | 53,114 | 0.0011 |

**The last row measures a function this source tree no longer has.** #28 deleted
`approveCosign(bytes32,bytes32)` and replaced it with `approveCosignFor(mandateId, recipient,
amount, ref, nonce, validUntil)`. Every figure in the row, and every 53,114 elsewhere in this
document, is a property of v1's bytecode and stays as v1 evidence — but **v2's cosign approval
path is unmeasured**, and nothing here may be read as its cost. The new function encodes 196
calldata bytes against 68, takes an extra cold SLOAD, computes an extra keccak, and emits a log
with three data words instead of none, so it is a different computation and not a revision of
this one. #14 owns the re-measurement.

**These rows are now generated with a pinned fuzz seed, and two of them moved when that
happened.** `evidence/gas.log` was regenerated on 2026-08-25 with
`forge test --gas-report --fuzz-seed 5042002`, the seed being Arc's chain id so the number
is derivable. Without a pinned seed the median column is not reproducible at all — the
`spend` median read 110,380 in the old unseeded log against 105,935 in three consecutive
seeded runs, which is why the figure above changed. The deploy figure moved 12 gas, from
2,557,693 to 2,557,681, for reasons that are **not** resolved; the header of
`evidence/gas.log` records what was ruled out. Min, Max and call counts reproduced exactly
across all three seeded runs; Avg never did, which is why no Avg figure is published
anywhere in this repository.

Those are mock-USDC figures and are kept because they are the only ones covering the whole
configuration space. **For what a real spend actually costs, the live numbers below
supersede them.** Contract size is 11,572 bytes of runtime code against the EIP-170 limit
of 24,576, so a little over half the budget is still free. (This document previously said
11,964, which was wrong; see the size note in `foundry.toml`.)

**A note on what these rows are, since it was got wrong once.** For the state-changing
functions these are transaction-equivalent figures: `forge test --gas-report` includes the
21,000-gas intrinsic floor plus per-calldata-byte cost, so a row here is directly comparable
to a receipt's `gasUsed`. The last three rows have since been confirmed against Arc on
exactly that basis — `revoke max` 32,945 and `approveCosign max` 53,114 were reproduced to
the gas, and `withdrawCosign max` 26,901 to within one calldata byte. It is only the *view*
rows of the full report that read below the intrinsic floor, because a `staticcall` in a test
is not a transaction. See "The 53,114 was never a coincidence" at the end of this document.

### What it costs on Arc, measured against the live chain

`test/ArcParity.t.sol` exists because comparing one real receipt against the median above
would measure almost nothing — that median aggregates mandates with four windows, with
none, with credential gates, and spends denied before they touch the token. The parity
suite runs the *same transactions* with the same constants, each in its own test contract so
that storage is cold in each, and computes intrinsic gas from the real encoded
calldata so its predictions are directly comparable to a receipt. Three contracts were
written for the table below; a fourth, `ArcParityApproveCosignTest`, was added later for
`approveCosign`, so the file holds four one-test suites.

**Read the table below knowing that the harness has since been shown to be the least accurate
instrument used in this project.** It measures with `gasleft()` around an inner call and then
adds intrinsic gas back by hand, and it overshot `approveCosign`'s true execution cost by
about 5,205 gas. Foundry's own `--gas-report`, which needs no hand-adjustment at all,
predicted the same transaction exactly. The deltas in this table are therefore mostly
measurements of the harness. Details at the end of this document.

| | predicted | charged on Arc | delta |
|---|---|---|---|
| `approve` 2.00 | 44,681 | **55,438** | +10,757 |
| `createMandate` | 158,580 | **152,243** | −6,337 |
| `spend` 0.10 | 190,120 | **216,458** | +26,338 |
| bare `transfer` 1.00, for reference | — | **73,950** | — |

`createMandate` touches no USDC, so its deviation is the harness, not Arc. Part of it is
that a real transaction gets its `to` address pre-warmed under EIP-2929 while the test pays
~2,600 for a cold `CALL` into the contract; the remainder is undecomposed and is recorded
as undecomposed. **That remainder is now known to be harness error rather than anything about
Arc**, because the gas report reproduces three token-free receipts to the gas with no
adjustment whatsoever.

~~Using it as a calibration constant, Arc's `NativeFiatToken` costs roughly 17,100 gas more
than a minimal ERC-20 for an `approve` and 32,700 more for a `transferFrom`.~~
**Both figures were wrong. Withdrawn and replaced by direct measurement on 2026-08-24.**
They were produced by taking `createMandate`'s −6,337 as a flat additive constant and
applying it to two operations that touch far more state. `evidence/cosign-parity.log` had
already shown that deviation is not constant — 6,337 for `createMandate` against 2,505 for
`approveCosign` — so the premise had failed before the arithmetic began. **There is now a
second, independent reason: both deviations are artefacts of the harness rather than
measurements of Arc.** The gas report's `approveCosign` figure matches the Arc receipt
exactly, so there was never a 2,505-gas discrepancy for Arc to explain. A calibration
constant taken from an instrument's own error cannot calibrate anything.

#### The premium, measured without a harness

`evidence/premium.log`. The replacement method removes the test harness from the comparison
entirely: deploy `test/mocks/MockUSDC` **to Arc**, then run the same operation against both
tokens from the same wallet, minutes apart, with byte-identical calldata. The token address
rides in the transaction's `to` field and not in calldata, so intrinsic gas cancels exactly
within each pair and the whole receipt difference is Arc's own accounting.

The comparison is only valid if every storage slot is in the same class on both tokens,
since EIP-2200 charges 20,000 to write a slot that held zero and 2,900 to overwrite one that
did not — a 17,100 gap, the same size as the number being measured. `evidence/premium-check.log`
establishes the preconditions: the vendor's balance is non-zero on Arc (0.35 USDC), so the
mock's vendor was minted to match, and `allowance(payer → agent)` is zero on Arc, so the
mock's is too.

| | MockUSDC | Arc USDC | premium |
|---|---|---|---|
| `approve`, onto a **zero** allowance slot | 46,138 | **55,438** | **9,300** |
| `transferFrom`, three non-zero overwrites | 46,688 | **59,798** | **13,110** |
| `approve`, onto a **live** allowance slot | 29,038 | **38,338** | **9,300** |

**The premium is not per-slot. It is very nearly per-call.** `approve` costs the same 9,300
whether it writes a virgin slot or overwrites a live one — the same number twice, from two
independent transaction pairs. A `transferFrom` touching three slots instead of one costs
13,110, not the ~27,900 a per-slot model predicts. Of the 3,810 difference, 1,756 is Arc's
second `Transfer` log (`LOG3`, 375 + 3×375 + 8×32) emitted by the native system emitter at
`0xffff…fe` in 18-decimal wei alongside the 6-decimal ERC-20 one; that leaves ~2,054 for two
additional balance-slot writes, about 1,027 each. **The superseded text here said the
opposite** — that the overhead is per-slot and should be assumed so by anyone re-deriving.
That conclusion came from predicting the spend at ~203,000, seeing 216,458, and attributing
the shortfall to slot count when it belonged to the non-constant harness deviation.

**The old 17,100 was never a premium.** It is the EIP-2200 storage-class gap, and it appears
identically on *both* tokens: 46,138 − 29,038 = 17,100 on the mock, 55,438 − 38,338 = 17,100
on Arc. Being identical, it cancels. The discarded derivation reached 10,757 + 6,337 = 17,094
and rounded, landing six gas from a constant that has nothing to do with Arc — which is
precisely what made a broken figure look independently corroborated. Treat arithmetic that
lands on a famous constant as a prompt to re-derive, not as confirmation.

Two incidental confirmations. The Arc receipts reproduce
`evidence/approve.log` and `evidence/approve-lo.log` to the gas — 55,438 and 38,338 — with a
different spender and a different amount, days apart. That is forced rather than lucky:
intrinsic gas depends only on the *count* of zero and non-zero calldata bytes, and both
spender addresses contain no `0x00` byte (20 non-zero each) while 2,000,000, 200,000, 90,000
and 100,000 all encode to exactly 3 non-zero bytes.

And the mock itemises exactly, which is what licenses attributing the residual to Arc.
Intrinsic for `approve` is 21,000 + 16(27) + 4(41) = 21,596, leaving 7,442 of execution on
the live slot — 5,000 (cold `SLOAD` 2,100 + `SSTORE_RESET` 2,900) + 1,756 (`LOG3`) + 686 of
dispatch — and 24,542 on the virgin slot, which is 22,100 (2,100 + `SSTORE_SET` 20,000) +
1,756 + **the same 686**. Both exact, same residual, no slack for the premium to hide in.


The intrinsic-gas model came out exact rather than approximate, which is what licenses
attributing the residual to Arc: 22,304 predicted and 22,304 charged for the spend's 164
calldata bytes, and 24,828 against the suite's 24,816 for `createMandate` — a 12-gas gap
caused by one byte of the spender address differing between the mock and the real agent.

**So the real price of the policy machinery is about 103,479 gas, or 0.217 cents.** The
steady-state marginal spend, measured inside an already-written window bucket, is 177,429
(`evidence/marginal-a.log`); a bare `transfer` to a fresh account on the same chain is
73,950. The difference buys a per-transaction cap, a lifetime cap, a 24-bucket rolling daily
window, an expiry, an allowlist, an idempotency nonce and a reconcilable audit event. A
policed payment costs about **2.4×** a bare one.

~~about 142,500 gas, or 0.3 cents … about 3×~~ — that figure compared a *first-ever* spend
at 216,458, with every slot cold and every counter virgin, against a bare transfer, and so
charged one-time initialisation to the recurring cost. It overstated the overhead by 39,029
gas. One caveat survives the correction and one is retired: `transferFrom` touches the
allowance slot and `transfer` does not, worth ~5,000 gas, so read the floor as ~98,000; but
Arc's token premium now largely *cancels* in this comparison rather than inflating it, since
both sides of the subtraction pay it.

**`K=24` is affordable, and it is not close.** Each additional bucket adds one cold
`SLOAD` on a packed slot to the ring read loop: 2,100 gas plus loop and mapping-key
overhead, call it ~2,150, or 0.000045 USDC at 21 Gwei. Going from `K=12` to `K=24` widens
the ring from 13 slots to 25, so it costs about 25,800 extra gas per window — **0.00054
USDC, one twentieth of a cent.** Even four windows all at `K=24` adds only 0.0022 USDC. The
accuracy this buys is the `K/(K+1)` throughput floor rising from 92% to 96% of nominal.
Trading a twentieth of a cent for halving the worst-case under-count is not a close
decision, and `K=24` should be the default recommendation for anything where the rate limit
is doing real work.

Two caveats remain, because this is a measurement and measurements have conditions.

~~The suite runs against `MockUSDC`.~~ **Resolved on 2026-08-24.** Arc's real USDC does
cost strictly more, as predicted, and the magnitude is now measured directly rather than
inferred: **13,110 gas on the `transferFrom`**, from `evidence/premium.log`. It is a
per-call constant, not a per-bucket cost, so it does not touch the `K` decision — it raises
every spend by the same amount whether the mandate has one window or four. The figure this
paragraph used to carry, ~32,700, was too high by a factor of 2.5.

21 Gwei is what has been observed, not a promise either. Arc advertises stable, predictable
pricing, and 20 Gwei is a documented floor, but under congestion the effective price rises
and every figure above scales linearly with it. A 10× fee spike still leaves a policed
spend at under five cents.

The per-bucket marginal figure is *derived* from EVM cold-`SLOAD` pricing, not isolated by
a dedicated per-`K` benchmark. The aggregate report is consistent with it, and the
conclusion is robust to being wrong by a large factor — at 3× the estimate, `K=24` still
costs a sixth of a cent — but it is a derivation and is labelled as one.

**A hypothesis this measurement raised, and then killed.** `optimizer_runs = 200` in
`foundry.toml` was set partly to keep deployment size honest, on the assumption that deploy
cost mattered. Deployment costs five cents once and `spend` is the hot path by orders of
magnitude, which looks like an argument that 200 optimises the wrong end. So the tree was
rebuilt at `optimizer_runs = 10000` and re-measured the same day. The answer is no:

| min gas, identical deterministic path | 200 | 10000 | delta |
| --- | --- | --- | --- |
| `createMandate` | 28,630 | 28,630 | 0 |
| `spend` | 24,898 | 24,892 | **−6** |
| `revoke` | 23,773 | 23,767 | −6 |
| deployment size, bytes | 11,964 ⚠ | 15,236 ⚠ | **+3,272** |

⚠ **Both size figures are wrong, and the row is kept only because the delta is what the
argument rests on.** `forge build --sizes` reports 11,572 runtime and 11,868 initcode, and
the deployed contract's on-chain code length independently confirms 11,572. 11,964 matches
neither column and was published in three files for weeks on the strength of a single
measurement that was never checked a second way; assume 15,236 is off by a similar margin.
The *gas* columns are sound — the deployment figure from this same exercise reproduced
against the live chain to 0.009% — so the conclusion below is unaffected.

Fifty times the optimizer effort bought six gas on a spend — 0.02% — for 27% of the
bytecode budget. The reason is structural rather than incidental, and it was already
visible in the cost model above: a spend's gas is `(K+1)` cold `SLOAD`s per window at 2,100
each plus an external `transferFrom`. Those prices are set by the EVM, not by codegen. The
optimizer can only win on instruction selection and layout, which is noise at this scale;
it cannot make a storage read cheaper. `200` stays, and the 13,004 spare bytes stay
available for the EIP-712 cosign variant.

Deploying to Arc confirmed this from the other direction, though less forcefully than first
claimed. **13,110 gas** of a real spend is Arc's own native-USDC accounting — a cost no
compiler flag can reach — and this paragraph previously put that at ~32,700, which inflated
the unreachable share of a 216,458-gas spend from 6% to 15%. The correction weakens a
supporting argument without touching the decision: `runs = 200` stays because 10,000 bought
**six gas** for 27% more bytecode, and that measurement is independent of anything Arc's
token does.

The general lesson is worth more than the setting. "This is the hot path, so optimise it
harder" is not an argument unless the hot *cost* is the kind of thing the optimiser can
reach. Here it never was.

**A methodological correction, which matters for anyone repeating this — and it was itself
corrected on 2026-08-25.** The original note said the fuzz seed was not pinned, so two runs
did not execute the same call sequences (`spend` was called 125,708 times in the first run
and 125,447 in the second), that Median and Avg were therefore not comparable across runs,
and that the fix was to compare the Min column or pass `--fuzz-seed` to both. On first
reading this table appeared to show `windowRemaining` improving by 40%; that was entirely
seed noise, and that part stands.

What did not stand is the fix. Pinning the seed was then tested: three runs at
`--fuzz-seed 5042002` against identical bytecode produced **three different tables**. The
seed pins the call counts exactly (125,844 in all three), and it pins Max in all 49 rows and
Min in 48 of 49, but Avg still moved in all five rows the stateful invariant campaign drives
and Median moved in two of them. The mechanism is not known and is not guessed at. So the
corrected advice is: compare Min, Max and call counts; pin the seed so published medians are
reproducible; never compare Avg across runs at all. `evidence/gas.log`'s header carries the
full measurement.

## What is still unverified

The contract is deployed and verified on Arc Testnet at
`0x3744E93B9e796E05CB66311d897559B6F3860196`, and a delegate has executed a real spend
against a real mandate — so the claims that used to sit here about never having run on a
live chain are retired, and the gas figures above are reconciled against real receipts.
What remains genuinely open is narrower but not smaller.

It has not been audited. A passing test suite says the logic does what the model says; it
does not say the model is right about the world, and it says nothing about what happens
under an adversary with a budget. **Remit is intended to hold real money**, which makes the
audit a scheduled requirement rather than a disclaimer.

~~The live exercise covered exactly one mandate shape.~~ **Superseded 2026-08-24, and closed
2026-08-25.** Five mandate shapes have now been exercised live: ungated, cosigned,
identity-gated, and credential-gated both with and without a staleness bound. The cosignature
path has three live transactions, and both ERC-8004 gates have fired against Arc's real
registries with their predicted selectors and a passing ungated control beside them.
~~**`revoke` is the only path left with zero live transactions.**~~ **`revoke` has now run
three times** — the two gate-blocked mandates were spent on it, one revoked by its payer and
one by its own delegate, and every function this contract exposes has been exercised on Arc.

What remains open is narrower than "untested paths", and worth naming precisely rather than
letting the old sentence stand as a stale proxy for it. The ERC-8004 registries are
ERC-1967 proxies whose behaviour can change under us: one already reverts with
`Error(string) = "unknown"` where the design had hedged it might return a zero tuple, and
the live attestation we found carries response 1 under the tag `"verified"` while being 97
days stale. Neither is a contract defect — the gate correctly refused it — but neither is
pinned by anything we control. Separately, the identity gate's *positive* path stays
untestable, because it needs an identity NFT minted to our delegate and agent 16330 belongs
to someone else.

Two Arc behaviours remain asserted from documentation rather than observed: sub-second
blocks sharing a timestamp, and the CallFrom precompile. Whether an EIP-7702-delegated EOA
counts as an EOA for the Memo path is also unresolved and matters for smart-account agents.

Before this is trusted with money: run the suite at `--profile deep`, exercise the untouched
paths on testnet, resolve the three documented soft spots as decisions, and get it audited.
Three of those four have since happened — the deep profile has been run, the live phase is
closed at 31 receipts covering all five state-changing functions, and all three soft spots
are resolved the strict way in v2 (which turned up two more, both fixed). Two paths are
still unexercised on chain and the phase was closed knowing it: the identity gate and the
credential gate, both blocked on external facts rather than on effort — no ERC-8004 identity
is minted to our agent wallet, and the only real attestation on Arc Testnet carries a
failing response of 1. The audit is the fourth item, and it is the one that was always going
to be a hard requirement.

Two factual questions remain open and should not be presented as settled. Whether
Circle's `agent-wallet-policy` already implements equivalent caps off-chain in its
custodial API is unverified — so the claim to make is "non-custodial, on-chain,
independently verifiable", not "first". And whether an EIP-7702-delegated EOA still
counts as an EOA for the Memo and Multicall3From paths is unverified; it matters for
smart-account agents, and given the real-money intent it needs an answer before launch
rather than before publication.

## Verification worksheet

Every Arc-specific claim in this document, and the primary source it was checked
against. All nine were verified in the Arc docs; none are inferred.

| Claim | Verified in |
|---|---|
| USDC is the native asset at `0x3600…0000`; native view 18 dp, ERC-20 view 6 dp, one underlying balance; no wrapped USDC exists | `/arc/references/evm-differences`, `/arc/concepts/stablecoin-native-model`, `/arc/references/contract-addresses#usdc` |
| An ERC-20 allowance is not a cap on total USDC spending, because the balance can leave as native value; allowance state is not a safety guarantee for smart accounts with execution rights | `/integrate/wallets/add-arc-to-a-wallet` §5.2 (Warning), `/integrate/wallets` (Key differences table), `/integrate/defi/amm-and-pools` step 4 |
| Finality is deterministic and instant; transactions finalize on inclusion; one confirmation is enough for off-chain systems to act | `/arc/references/evm-differences`, `/arc/concepts/deterministic-finality`, `/integrate/wallets` |
| Block timestamps are non-decreasing, not strictly increasing; one-second granularity from the proposer's wall clock, so sub-second blocks share a timestamp; order by block number | `/arc/references/evm-differences` L212 |
| CallFrom preserves the signing EOA as `msg.sender`; Memo and Multicall3From are built on it | `/arc/concepts/transaction-memos` L84, `/arc/concepts/execution-layer` L41 |
| Memo must be submitted by an EOA; ERC-4337 accounts, Circle modular wallets, SCAs, Safe and other multisigs, and bundler-originated transactions all revert | `/arc/concepts/transaction-memos` (Unsupported wallets, Guardrails) |
| A child revert inside a memo wraps the return data in `MemoFailed(bytes)` and rolls back the memo index | `/arc/concepts/transaction-memos` L121 |
| Value transfers can revert despite sufficient balance — zero address, blocklisted counterparty, or any transfer that would burn value; blocklisted transfers revert at runtime after consuming gas | `/arc/references/evm-differences`, `/integrate/wallets/add-arc-to-a-wallet` §5.2 |
| ERC-8004 registry addresses, and `getValidationStatus(bytes32)` returning `(address validatorAddress, uint256 agentId, uint8 response, bytes32 responseHash, string tag, uint256 lastUpdate)` | `/arc/tutorials/register-your-first-ai-agent` L15-17, L529-545 |

The `getValidationStatus` return tuple is worth restating because it is what made the
credential gate fixable: the validator and the agent are both in the response, so
both can be checked. A gate that reads only `response` is not a gate.

### What has since been observed rather than read (2026-08-24)

The table above records what the documentation says. This one records what a live Arc
Testnet node actually did when asked, via read-only `cast` calls before any deployment.
The distinction matters: a documented claim and an observed one fail differently, and
until now every Arc-specific assumption in this project was the first kind.

| Claim | Observed |
|---|---|
| Chain ID is 5042002 | `cast chain-id` → `5042002` |
| The ERC-20 interface at `0x3600…0000` is 6 decimals — the assumption every `uint96` cap in the contract rests on | `decimals()` → `6`, `symbol()` → `"USDC"` |
| Both ERC-8004 registries exist and expose the ABI we compiled against | Byte-identical ERC-1967 proxy code at both; `ownerOf(1)` returned a live owner; `getValidationStatus` decoded into the full six-field tuple |
| Gas price sits just above the documented 20 Gwei floor | `cast gas-price` → `21000000000` (21 Gwei) |
| **`getValidationStatus` reverts for an unknown request hash** — it does not return a zero tuple | Three nonexistent hashes all reverted with `Error(string)` = `"unknown"` |

That last row was an open question this design hedged on rather than resolved, and the
hedge is why nothing needs changing now. `_checkCredential` wraps the registry call in
`try/catch` and converts either failure shape into `CredentialMissing()`, and
`MockValidationRegistry` carries a `revertOnUnknown` flag so both shapes are covered by
tests. The live chain has now picked one. Both stay tested regardless — the registries
sit behind upgradeable proxies, so today's answer is not permanently today's answer.

Two incidental findings from the same probe, both worth keeping. There is a real
attestation filed under `requestHash == bytes32(0)` — validator
`0xB152c3B6436318aD340153f1d30C9BBb8634681A`, agent `16330`, response `1`, tag
`"verified"`. Under the ERC-8004 convention Arc's own tutorial states four times
(`100 = passed, 0 = failed`) a response of `1` is a *failure*. So there is already a
failing attestation on-chain wearing the label "verified", which is the argument for
reading the numeric response and ignoring the tag — made by the chain instead of by
assertion. And `spendable()` reads `balanceOf`, the 6-decimal view of an 18-decimal
balance, so it truncates: a real balance of `100.0000001` USDC reports as `100`. That
error runs one way only, under-reporting by at most 1e-6 USDC, and `spend` never reads
a balance at all, so it cannot affect what a policy permits. Noted in the contract at
the call site.

### What has since been observed by transacting (2026-08-24)

The table above was gathered with read-only calls. This one required spending money, and
it is a different class of evidence again: a `cast call` can be wrong about what a state
change would cost or emit, and four of these rows contradict something this document
previously asserted.

| Claim | Observed |
|---|---|
| **Funds never enter the contract** — a spend moves value payer → recipient directly | Both `Transfer` logs on the live spend carry `from` = the payer, not MandateManager; the contract appears only as the emitter of `Spend` |
| `approve` / `allowance` / `transferFrom` are fully implemented on `0x3600…0000`, so the non-custodial architecture is viable on Arc | A real `approve` of 2,000,000 landed and `transferFrom` inside `spend` decremented it to 1,900,000 |
| **Every USDC value movement emits TWO `Transfer` logs** — this was not previously known or documented anywhere in this design | One from `0xffff…fffe` (EIP-7708 native emitter, 18 dp) and one from `0x3600…0000` (ERC-20 view, 6 dp), on both the `transfer` and `transferFrom` paths. `approve` emits only one, so the doubling is specific to value movement |
| The mandate id is derivable off-chain before the grant is mined | `keccak256(abi.encode(DOMAIN, chainid, contract, payer, salt))` computed locally matched the emitted `MandateCreated` topic exactly |
| The `spendHash` is derivable before the spend is mined, which is what makes the cosign flow usable | A `cast call` dry run returned the identical hash later emitted in `Spend` |
| Six policy gates reject as specified against deployed bytecode, not a mock | Dry-run reverts returned exactly `NonceAlreadyUsed()`, `RecipientNotAllowed()`, `OverPerTxCap()`, `WrongSpender()`, `ZeroAmount()`, `UnknownMandate()` |
| `effectiveGasPrice` is 21 Gwei, not the documented 20 Gwei floor | All four live transactions: `21000000000` |
| Runtime code is 11,572 bytes, not the 11,964 this document published | On-chain code length, agreeing with `forge build --sizes` |

The double-`Transfer` row is the one with a consequence for anyone building on this.
**An indexer that reconciles payments by counting `Transfer` logs will double-count every
Remit spend**, because the same payment appears once in 18 decimals and once in 6. Remit's
own `Spend` event is the deduplicated authoritative record. That was previously a matter of
taste — a nice audit trail to have — and is now a requirement with an observed failure mode
behind it.

The non-custody row deserves the same emphasis for the opposite reason: it is the central
architectural claim of the project, and until this transaction it rested on reading the
source. It is now visible in a block explorer to anyone who doubts it, and it is
structurally guaranteed besides — the contract contains no `payable` function, no
`receive`, no `fallback`, and no reference to `msg.value` anywhere.

### What transacting has since established beyond the first spend (2026-08-24)

The table above stops at the first live payment. Everything below came from continuing to
transact against the same deployment: the cosignature flow end to end, both ERC-8004 gates
against Arc's real registries, the allowance ceiling, and a spend carrying a commitment
instead of a label. **At the close of 2026-08-24, twenty-five live transactions existed and
every one had `status 1`** — two contract deployments, eleven calls to `MandateManager`, seven
to Arc's own USDC, and five to a stand-in ERC-20 deployed alongside it to measure the token
premium. Five mandates, four spends. This paragraph said twenty-four until 2026-08-25, short by
the one transaction that created `MandateManager` itself; the recount is described two sections
below. Only `revoke` and `withdrawCosign` had never run; the next two sections close both,
taking the total to thirty-one.

The gate results below were obtained with `cast call` rather than `cast send`, which costs
nothing and is the right instrument: a gate's whole output is which error selector comes back,
and a dry run returns it without paying for a reverted transaction. Those are consequently not
counted among the twenty-four.

#### The cosignature flow, end to end on chain

Mandate 2 (`0xee83f8e2…c746b`, flags 79) carries a cosigner and a 50,000 threshold. Six
checks were run in order, and every one returned its predicted value.

**The revert carries the hash the cosigner needs to approve.** The agent's over-threshold
spend failed with `CosignRequired`, whose revert data was `0x6a39578f` followed by the exact
`spendHash` computed off-chain beforehand. An agent learns what to send its human from the
revert alone — no follow-up call, no indexer, no event subscription.

**A delegate cannot approve its own spend.** `approveCosign` from the agent and from the
vendor both reverted `NotCosigner()` (`0x1cf89d6f`). Only the named cosigner succeeded.
(v1's name and v1's receipts. `approveCosignFor` guards this identically — `msg.sender !=
m.cosigner` — but has no live evidence of its own, and #11 closed the harder version of this
hole at grant time by refusing `cosigner == spender` outright, which no approval-time check
could reach.)

**One signature authorises exactly one payment, locked twice over.** After the cosigned spend
`isCosignApproved` reads false — the approval was consumed. And re-submitting the same
payment with a *fresh nonce* produces a different hash and demands a fresh signature, because
the hash binds the nonce. So a human's approval cannot be recycled onto a second payment even
by a delegate that controls the amount and the recipient.

**The threshold is strictly greater, pinned live from both sides.** 50,000 passes with no
cosignature; 50,001 reverts `CosignRequired`. One millionth of a USDC decides it.

The second, third and fourth of those are exactly the properties a local suite can fake by
controlling `msg.sender` or by never thinking about nonce rebinding. They now have chain
evidence instead.

**A measurement trap worth publishing, because it inverted a conclusion.** The cosigned spend
cost *less* than the first live payment — 194,225 against 216,458 — and on first reading I
scored requiring a human signature as a net saving. It is not. EIP-3529 refunds are settled at
the end of a transaction and are already deducted from `gasUsed`, so **a receipt is a
post-refund number, and two receipts are not comparable unless both earn the same refund.**
Clearing `_cosignApproved` earns a 4,800 refund that no other spend earns.

The comparison that does work is mandate 2 against itself. Its first three spends were
194,225 (cosigned), 193,837 (plain, sub-threshold) and 177,429 (plain, steady state), and the
first two are comparable for a reason worth stating explicitly: **they landed in different but
equally virgin window buckets** — 6 and 7, 1,567 seconds apart — so both paid `SSTORE_SET` for
a fresh bucket and the window cost cancels exactly. The third spend re-entered bucket 7 and
dropped 16,408, within 692 of the 17,100 storage-class gap and nothing to do with cosigning. A
reader who assumed all three shared one bucket would compute a contradiction here.

So: **the observed net cost of the cosignature gate is 388 gas** — 194,225 less 193,837 — which
is what the payer actually paid, refund included. Adding the 4,800 back gives a gross delta of
5,188 against 5,012 predicted: cold `SLOAD` of `_cosignApproved` 2,100, `SSTORE` non-zero→zero
2,900, and 12 gas of calldata (100,000 carries one more non-zero byte than 50,000). The 176
residual is branch evaluation plus the nested-mapping keccak.

The model's *predicted* net is 5,012 − 4,800 = **212**, and the 176 residual is precisely what
separates it from the observed 388. Both numbers are worth keeping, but only one of them is a
measurement — and the project's working notes had been carrying the 212 as if it were the
observed figure, which is how a predicted number quietly becomes a published one.
**Requiring a human signature costs 388 gas: under two tenths of one percent of the
transaction.** The refund is what makes it that cheap — the gate sets a slot and then clears it
in the same transaction, and the EVM pays most of it back.

#### Storage packing, proven by observation rather than asserted

`MandateManager.sol:193-194` asserts in a comment that `cosigner` and `cosignThreshold` share
slot 2, and `195-201` that all seven mutable accounting fields share slot 3. A comment is an
assertion; these are now measurements. Granting mandate 2 cost 172,407 against mandate 1's
152,243 — a delta of **20,164**, which decomposes with zero residual: 19,900 of storage (cold
2,100 plus `SSTORE_SET` 20,000 for slot 2 going non-zero, less the 2,200 mandate 1 paid writing
zero over zero) and 264 of calldata (240 for the cosigner address, 24 for the threshold). Two
separate slots would have cost about 40,000.

Confirmed a second way by reading `getMandate` across a spend: `totalSpent` and `spendCount`
moved **together**, alongside `notBefore`, `expiresAt`, `flags`, `windowCount` and `revoked` —
29 bytes in one 32-byte slot. All mutable accounting for a mandate is therefore a single
already-non-zero slot, so a spend pays one `SSTORE_RESET` for it rather than two `SSTORE_SET`s.
`getWindow` also returned `subLength = 3600` = 86400/24, confirming that bucket width is
precomputed at grant time and `spend` never divides.

#### Both ERC-8004 gates fire against Arc's live registries

Three gated mandates were granted, then spends dry-run against each.

| mandate | gate configuration | result |
|---|---|---|
| M3, flags 25 | identity, agent 16330 | `IdentityNotHeld()` **`0x6eab756c`** |
| M4, flags 41 | credential, `minResponse` 100 | `CredentialMissing()` **`0x9e586322`** |
| M5, flags 41 | credential, `minResponse` 1, `maxStaleness` 86400 | `CredentialStale()` **`0xca36b069`** |

**The headline is M4.** A real attestation exists on Arc Testnet tagged `"verified"` whose
numeric response is `1`, where Arc's own tutorial states four times that 100 = passed. The
credential gate rejects it. Had the gate trusted the free-text tag instead of the number, it
would have accepted a failing attestation as proof of a passing one. The comment at
`MandateManager.sol:639` — that reading `response` alone makes this gate theater — is now
backed by live data rather than by reasoning about a hypothetical.

M3 is the **impersonation** case rather than a missing-token case, which is the stronger
test: agent 16330 is real and registered, owned by `0x2F061aA5…`, and the gate refuses our
delegate precisely because it does not hold that identity. M5 shows staleness working against
a real timestamp — with `minResponse` relaxed to 1 the response check passes, and the
attestation's 8,417,882-second age then fails it.

**The control is what makes those three reverts evidence.** The same call shape against
ungated mandate 1 *succeeded*, returning a spendHash. Without it, three reverts would have
been indistinguishable from a malformed call.

Two incidental findings, both worth keeping. Gate structs are written **conditionally**
(lines 405-409), so an ungated mandate pays nothing at all for gate storage — visible in the
grant costs of 127,834 for M3 against 151,036 and 151,072 for M4 and M5. And line 407
*already* reverts `BadConfig` when `minResponse == 0`, commented that 0 would accept a failed
attestation. The contract therefore already refuses one gate configuration that could never
fire, which is the same principle the unreachable-cosign-threshold guard applies — so v2
extended an existing pattern rather than inventing one, and this paragraph is the reason the
guard was easy to argue for. (That guard was written here and in `CHANGELIST.md` as `perTxCap
< cosignThreshold`, which is off by one: line 492 is strict, so equality is dead too, as this
document goes on to demonstrate with a live receipt 260 lines below. **v2 implements it as
`effectiveMax <= cosignThreshold` where `effectiveMax = min(2^96 - 1, perTxCap, totalCap,
every window cap)`**, and the boundary is pinned one base unit either side in
`test/Creation.t.sol`. Implementing it also turned up two dead-gate configurations that
neither this document nor `CHANGELIST.md` had listed — see the README.)

One further assumption confirmed rather than discovered: `ownerOf` on a nonexistent token
reverts with `ERC721NonexistentToken(uint256)` (`0x7e273289`), so Arc's identity registry is
OpenZeppelin v5 and the `try/catch` at line 628 has a real failure shape to catch. That was
written from the documentation; it now has an observation behind it.

#### The shared-allowance ceiling is a race between delegates, and `spendable()` is silent about it

This is the one live finding that produces a **documented limitation** rather than a
confirmation, and it belongs in the design rather than the changelist because it is not a
defect.

With the payer's allowance lowered to 90,000, mandates 1 and 2 *each* reported
`spendable` = 90,000 — summing to 180,000 — and a 50,000 dry-run succeeded on *both*. Two
delegates, each correctly told that 90,000 is available, each simulating a payment whose own
policy is fully satisfied, against 90,000 that actually exists.

`policyHeadroom` never consults the allowance at all; it returned 500,000 for both, unchanged.
`spendable` does intersect the allowance, but **as a ceiling on one mandate, never as a budget
shared across several** — which is honest per-mandate and silent about the joint constraint.
No funds are at risk, because the losing `transferFrom` reverts. The cost is a failed payment
plus the gas to discover it, on a spend whose own policy was fully satisfied.

**State it as inherent rather than as a bug.** It follows from layering per-mandate policy
over a single global ERC-20 allowance, and any design that does that has the same property.
The failure is specifically *multi-delegate*: one agent on one mandate reading `spendable()`
is safe. The moment a payer grants a second mandate against the same approval, `spendable()`
stops being sufficient, and the payer's remedies are to hold the allowance at or above the sum
of per-mandate caps, or to accept that concurrent delegates will occasionally revert. A
`spendableAcross(bytes32[])` view intersecting several mandates' headroom with the one
allowance would make the constraint visible, and is on the v2 changelist — but it would not
fix the race, only expose it.

**Built in v2, and it needed three refusals and a clamp the changelist did not anticipate.**
`spendableAcross(bytes32[] mandateIds)` now returns `min(Σ min(policyHeadroom(id), 2^96 - 1),
allowance(payer, manager), balanceOf(payer))` for up to `MAX_JOINT = 8` mandates. The paragraph
above still stands unaltered on the substance: it exposes the overlap and does not fix the
race. What was not anticipated is how many ways a joint view can return a *plausible* wrong
number, which is worse than reverting. Summing `policyHeadroom` naively **panics** on two
expiry-only mandates from one payer, because that function correctly returns
`type(uint256).max` when the payer set no amount bound while `spend` still refuses anything
above `type(uint96).max` — so the fix is to clamp each term at the largest single spend that
could actually occur, after which the sum provably cannot overflow (`8 × (2^96 − 1) < 2^99`).
Mixed payers, duplicate ids and unknown ids all revert, by `MixedPayers`, `DuplicateMandate`
and `UnknownMandate` — the first two are new errors, and they are the first in this contract to
report a badly formed *question* rather than a refused action. Revoked and expired mandates
contribute zero without reverting, because they are the ordinary contents of any real list. The
divergence worth noting: `spendable` returns 0 for an unknown id and the joint view refuses
one, deliberately, because a single zero is unambiguous while one bad id among eight is
invisible inside a total that still looks right.

#### `ref` carries a commitment for 240 gas, and needs no contract change

Spend #4 passed `ref = keccak256(abi.encode(invoiceId, poNumber, amountMinor, vendor, salt))`
in place of a plaintext label, and two independent implementations produced the same digest:
`0x4fa8c8c1c61e17f007f3c9e485abc8e332bcdcad37f2552f0a8f0fac8b98077a`. It went on chain as
mandate 1's second spend and the event carries it verbatim, where every earlier spend carries
readable ASCII.

**It is not free, and the reason is a nice illustration of how calldata is priced.** A digest
has no zero bytes to discount — all 32 are non-zero, at 16 gas each, so the `ref` word costs
512. `"invoice-0002"` is 12 ASCII bytes zero-padded to 32, so it costs 12×16 + 20×4 = 272.
**Committing rather than labelling therefore costs 240 gas**, about 0.13% of a spend and about
half a millionth of a cent at 21 gwei. Worth stating as a number rather than as "nothing":
padding is what makes short plaintext cheap, and any privacy measure that fills a field with
high-entropy bytes gives that discount up. It is the smallest privacy premium in this document
by three orders of magnitude, and it is still not zero.

Nothing else changes. The first privacy layer described in `PRIVACY.md` needs no contract
change, no new flag, and no new storage. A payer who does not want invoice numbers, purchase
orders and internal identifiers standing in public commits to them and keeps the preimage;
anyone holding the preimage can verify a payment against its paperwork exactly, and anyone else
sees 32 bytes of noise. That is a real improvement available to every mandate that exists
today, which is worth saying plainly, because every other layer in `PRIVACY.md` requires work
that this one does not.

### Revoke closes the live phase (2026-08-25)

`revoke` was, on paper, the last function in the contract that had never run against a live
chain. It has now run three times.

**It was not actually the last one, and finding that out is the more useful result.** Checking
the claim before publishing it — by listing every `external` and `public` function in the
contract and grepping the evidence for each — turned up `withdrawCosign` at line 736, which had
**never run on chain and was named in no document in this repository**. It is covered by the
local suite and appears in the gas report, which is exactly why it stayed invisible: a green
test suite is not an inventory of live coverage, and every prior claim in this project that
`revoke` was "the only path with zero live transactions" was therefore wrong. Five functions
change state — `createMandate`, `spend`, `revoke`, `approveCosign`, `withdrawCosign` — and at
the time of writing this paragraph four of them had live transactions. The next section closes
the fifth, and corrects two counts while it is at it.

Reading it turns up something worth documenting independently of the gap. `approveCosign` at
726 checks three things: the mandate exists, it has `F_COSIGN` set, and the caller is the
cosigner. `withdrawCosign` at 736 checks **only the last of those**. On an unknown mandate
`m.cosigner` is the zero address, so a caller is refused with `NotCosigner()` rather than
`UnknownMandate()` — safe, but misleading. And `delete _cosignApproved[mandateId][hash]`
succeeds whether or not anything was there, so withdrawing an approval that never existed emits
`CosignWithdrawn` describing the removal of authority that was never granted. The asymmetry is
defensible on the same reasoning that lets a spender revoke — giving up authority cannot harm
the payer, so it needs fewer guards than granting it — but the event is a trap for an indexer
reconstructing who approved what, and neither the asymmetry nor its consequence was written
down anywhere before now.

| tx | signer | mandate | `gasUsed` | outcome |
|---|---|---|---|---|
| `0x8e92bed6…` | payer | M3 | **30,808** | revoked |
| `0x12d905a4…` | **agent** | M4 | **32,945** | revoked by its own delegate |
| `0xe1d054e9…` | payer | M3 again | **28,008** | succeeded, re-emitted the event |

**The delegate can revoke, and that was a correction to my own reading rather than a design
change.** I had planned this test to prove that only the payer may revoke, and line 704 says
`msg.sender != m.payer && msg.sender != m.spender` — the spender is authorised too,
deliberately, as the doc comment above it explains: giving up your own authority can never harm
the payer, and it lets a compromised agent shut itself off without waiting for its payer to
notice. That deserved a live transaction rather than a footnote, so M4 was revoked by the agent
from the agent's own key. A third party is still refused: the vendor address gets `NotPayer()`
**`0x1435e357`**, before and after revocation alike.

Which makes the error's *name* wrong. `NotPayer()` is thrown on a path the spender may
legitimately take, so it describes the check inaccurately to anyone reading a decoded revert.
`NotAuthorised()` is truthful, and **v2 has renamed it** — the selector moves from
**`0x1435e357`** to **`0x1648fd01`**, which is an ABI change, so a client that decodes v2's
reverts must be rebuilt. The v1 figure above is not superseded by that: `0x1435e357` is what
the live contract at `0x3744E93B9e796E05CB66311d897559B6F3860196` returns today and will
return for as long as it runs, and this table is a record of v1's receipts.

Two things about how that change got made are worth more than the change itself. The reason
for keeping the wrong name was that it was already in a deployed ABI — a real reason, and one
that **expired the moment the tag `v1.0.0-arc-testnet` existed**, because the tag pins v1's ABI
at v1's address and v2 is a different contract at a different address. The blocker was
bookkeeping, not compatibility, and one `git tag` dissolved it. And the fix was filed as
"cosmetic" for weeks, which undersold it: a misleading error name is a real cost paid by
whoever debugs against it at 3am, and the cheapness of a change is not the same as the
smallness of its consequence.

#### The evidence is a changed selector, not a changed balance

Revocation is invisible in balances, so it has to be proven some other way. Before revocation a
dry-run spend on M3 reverted `IdentityNotHeld()` **`0x6eab756c`** and on M4
`CredentialMissing()` **`0x9e586322`**, both from the ERC-8004 gates at lines 473-474.
Afterwards both revert `Revoked()` **`0x44825a4b`**, from line 444. The selector *changing* is
the finding: revocation is not merely one more failing check among many, it is the **first
substantive one** — only the existence test at line 443 precedes it — and it short-circuits the
expiry check, the spender check, the allowlist, the amount bounds, the idempotency nonce, both
ERC-8004 gates and every cap and window behind it. A payer's remedy therefore costs one storage
write and consults nothing else: no clock, no registry, no external call.

Two controls make that reading legitimate rather than assumed. M5, untouched, still reverts
`CredentialStale()` **`0xca36b069`**; M1, untouched, still returns a `spendHash` from a
successful dry run. Exactly two mandates changed.

`getMandate(M3)` confirms revocation is one bit and not a deletion: `perTxCap` 500,000,
`expiresAt` 1790726400, `flags` 25, `totalSpent` 0 and `spendCount` 0 all survive verbatim,
with `revoked` flipped to 1. The mandate remains fully readable after it stops being usable,
which is what makes a revoked mandate auditable — a design that cleared the struct to reclaim
gas would destroy the record of what had been authorised.

Both views notice. `spendable(M3)` and `policyHeadroom(M3)` each fell from 500,000 to **0**,
because `policyHeadroom` opens with `if (!isLive(mandateId)) return 0` at line 836 and `isLive`
tests `m.revoked` at line 784. This is worth contrasting with the two silences documented
above: the allowance race and the ERC-8004 gates are genuinely invisible to `spendable`, but
revocation is not. `isLive` returns false for M3 and M4 and true for M1 and M5.

#### Three receipts reconcile to a constant residual, and the second address comparison is visible

All three transactions carry identical intrinsic gas — 21,000 plus 36 non-zero calldata bytes
at 16 each = **21,576**, since the `revoke(bytes32)` selector `0xb75c7dc6` and both mandate IDs
happen to contain no zero byte at all. So every difference between the three is execution.

```
                        gasUsed   execution   model    residual
revoke M3, payer         30,808      9,232     8,700       532
revoke M4, agent         32,945     11,369    10,800       569
revoke M3 again, payer   28,008      6,432     5,900       532
```

The model is a cold `SLOAD` of slot 0 at line 703 (2,100), a warm re-read at 704 (100), a cold
`SLOAD` of slot 3 to read-modify-write the packed bool (2,100), the `SSTORE` itself, and
`LOG3` for `MandateRevoked` (375 + 3×375 = 1,500, no data). The agent path adds one cold
`SLOAD` of slot 1 for `m.spender`.

**The residual is 532 on both payer-path transactions**, despite their storage costs differing
by 2,800 — which is the cross-check that makes the model credible rather than merely
arithmetically satisfiable. Dispatch overhead does not vary with what the function then does.
The agent path's 569 exceeds it by exactly **37**, and that 37 is the second address comparison
itself: mask, `CALLER`, `EQ`, `ISZERO`, `JUMPI` and their stack traffic.

So **Solidity's `&&` short-circuit is observable in a gas receipt.** The two revocations differ
by 2,137, of which 2,100 is a single cold storage read that the payer's transaction never
performs, because `msg.sender != m.payer` already evaluated false and the right-hand side was
never reached. Revoking as the delegate costs 7% more than revoking as the payer, for that
reason alone.

**The redundant revoke costs exactly 2,800 less, which is `SSTORE_RESET` minus a no-op write.**
Line 705 is a bare `m.revoked = true` with no already-revoked guard, so revoking twice
succeeds. The second write sets a slot to the value it already holds, which EIP-2200 prices at
100 rather than 2,900, and 30,808 − 28,008 = 2,800 with nothing left over. The cold `SLOAD` of
slot 3 is still paid both times, which is why the saving is 2,800 and not 5,000.

**The receipt also shows `MandateRevoked` emitted a second time**, with identical topics and
empty data — its `mandateId` and `by` are both indexed, so the event body is `0x`. An indexer
that treats revocation as a one-shot signal will double-count it. That is a consumer-side
consequence of an intentionally guardless setter and belongs in the integration notes rather
than in the contract: adding a guard would cost gas on the common path to protect against a
harmless duplicate.

#### A methodological correction: estimate deltas are not gas deltas

Before these sends, `cast estimate` predicted 31,160, 33,301 and 28,702. The receipts came in
at 30,808, 32,945 and 28,008 — overshooting by **352, 356 and 694**. The overshoot is
conservative in every case, which is what a gas limit should be, but it is *not constant*, and
the two transactions that performed a real storage write were padded by about half as much as
the one that did not. Why the estimator behaves that way is unexplained here and is not worth
guessing at.

The consequence is concrete. Subtracting the two estimates gives 2,458 for the redundant-revoke
saving; subtracting the two receipts gives 2,800, which is what the storage model predicts
exactly. **The 342-gas discrepancy was entirely an artefact of comparing estimates.** This is
the third time in this project that a number obtained by the wrong instrument nearly became a
published one — after a predicted cosign cost quoted as measured, and a `ref` commitment called
free. Estimates size a transaction. Receipts measure it. They are not interchangeable, and the
rule now standing is that no gas figure enters this document unless a receipt produced it.

#### The allowance that governs a spend is payer → contract, not payer → delegate

A loose end from the reconnaissance run, recorded because the mistake was mine and the shape of
it recurs. `spendable(M3)` reported 500,000 while a live allowance of 100,000 was on record,
which looked like `spendable` failing to intersect the allowance — a bug in the one view an
agent is told to trust. It was not. Line 868 reads
`usdc.allowance(m.payer, address(this))`: the delegate never holds an allowance, because the
delegate never calls `transferFrom`. `MandateManager` does, on the delegate's instruction, so
the approval that matters flows payer → contract. The 100,000 was an unrelated payer → agent
approval left over from the token-premium measurement, where the agent transferred directly.

Read correctly, the live values are `allowance(payer, MandateManager)` = **1,650,000**,
`balanceOf(payer)` = **18,547,508** (18.547508 USDC), and `usdc()` = `0x3600…0000`, confirming
the deployment is bound to Arc's real token and not a stand-in. `spendable(M1)` = 500,000 is
then `min(policyHeadroom 500,000, allowance 1,650,000, balance 18,547,508)`, exactly as the
comment at 851-854 describes.

The generalisable part: a three-argument allowance is easy to query with the wrong pair, and
doing so produces a plausible number rather than an error. It also means a payer who revokes
authority by zeroing an approval must zero the one held by `MandateManager` — revoking the
delegate's own approval, if any exists, does nothing to Remit. Both remedies are worth
documenting for payers, because they are not interchangeable and only one of them is
per-mandate.

One documentation gap follows from the same run. `policyHeadroom`'s comment at lines 827-828
says it ignores "the allowlist and any co-signature requirement" — accurate as far as it goes,
but it also ignores the ERC-8004 identity and credential gates, which M3 demonstrated by
reporting 500,000 while being gate-blocked at every attempt. An agent trusting that view would
build a transaction that cannot succeed. The behaviour is fine; the comment is incomplete, and
naming the gates in it is on the changelist.

### `withdrawCosign` actually closes it, and two counts were wrong (2026-08-25)

The section above ends by admitting that four of five state-changing functions had live
transactions. `withdrawCosign` now has three-quarters of an hour of history and the count is
five of five. **Thirty-one live transactions exist, every one with `status 1`**: two contract
deployments, seventeen calls to `MandateManager`, seven to Arc's native USDC and five to the
stand-in token used for the premium measurement.

**Two counts in this document were wrong, and both were wrong because they were carried
forward in prose instead of derived.** The transaction total said twenty-seven an hour earlier;
counting distinct `transactionHash` values across `evidence/` and pairing each with its target
address gives thirty-one, and shows the old figure had counted MockUSDC's deployment while
silently omitting `MandateManager`'s own. One creation was in the total and the other was not,
which is also why the 2026-08-24 figure above was twenty-four rather than twenty-five: the same
missing transaction, inherited. Separately, the paragraph above this section said "six functions
change state" while listing five names — the arity was never checked against the source. Parsing
every declaration in `MandateManager.sol` for `external` or `public` without `view` or `pure`
returns exactly five: `createMandate`, `spend`, `revoke`, `approveCosign`, `withdrawCosign`.
There is no `receive`, no `fallback`, and the constructor is not a function that can be called
again. Ten public views make up the rest of the surface. Both errors survived several passes,
which is the argument for deriving counts from the artefacts rather than restating them.

**And the same trap caught the same document a second time, 2026-08-27 — this paragraph is where
it was aimed.** The parse named above is a rule about *the source file you run it on*, and after
#28 running it on the working tree returns `approveCosignFor`, not `approveCosign`, plus twelve
views rather than ten. The names above are v1's and stay v1's, because the thirty-one receipts
they explain came from v1's bytecode; run the parse against
`git show v1.0.0-arc-testnet:contracts/MandateManager.sol` to reproduce them. The banner in
`MandateManager.sol` was **not** so lucky: #28 substituted `approveCosignFor` into its version of
this same sentence, and so claimed a live receipt for a function that has never executed on any
chain. It was corrected the same day. The lesson refines the one this paragraph already draws —
deriving a count from the artefact is necessary but not sufficient, because the *right* artefact
is the one the claim is about, and "the current file" is the wrong one for a claim about a
deployment. A derivation can be executed perfectly against the wrong input.

#### An approval can be taken back, and the hash is discoverable rather than guessed

The gap was awkward to close honestly, because `withdrawCosign` takes a `bytes32` that has to
be a *real* pending approval for the test to mean anything. Passing an invented value would
have exercised the function without exercising the property. Two features of the contract make
the real one obtainable: `spendHash` at line 747 is a public view, and `CosignRequired` at line
294 is declared `error CosignRequired(bytes32 spendHash)` — it carries the required hash in the
revert payload. So the same 32 bytes were obtained three independent ways and agreed every
time: from the view, from the revert data behind selector `0x6a39578f`, and from the return
value of the dry-run spend once it succeeded.

The loop, on M2, whose cosigner is the payer and whose threshold is 50,000, using 60,000 —
`amount > m.cosignThreshold` at line 492 is **strict**, which is why the 50,000 spend recorded
earlier never tripped the gate:

| step | call | result |
|---|---|---|
| 1 | dry-run spend, 60,000 | `CosignRequired(0x47c56daa…)` |
| 2 | `approveCosign(M2, 0x47c56daa…)` | tx `0xd545ff0f…`, **53,102** |
| 3 | dry-run spend again | **succeeds**, returns `0x47c56daa…` |
| 4 | `withdrawCosign(M2, 0x47c56daa…)` | tx `0x6515918e…`, **26,889** |
| 5 | dry-run spend again | `CosignRequired(0x47c56daa…)` |
| 6 | `withdrawCosign(M2, 0x93c75437…)` | tx `0x7e10b4bd…`, **28,901** |

Step 5 is the security property, and it is worth stating plainly because it is the only place
in Remit where authority is granted by someone other than the payer and can be taken back
before it is used. A cosignature is consumed by the spend it authorises — line 494 deletes it —
so the window in which it can be withdrawn is exactly the window between approving and
spending. Inside that window the cosigner can change their mind, and nothing else about the
mandate moves: `totalSpent` stayed at 200,000, `policyHeadroom` and `spendable` stayed at
500,000, the nonce stayed unused, `isLive` stayed true.

Both event signatures were confirmed against locally computed keccaks rather than read off the
ABI: `CosignApproved(bytes32,bytes32,address)` is
`0x237a993f56f52f6e0716ac9bebbfe49539bb7cf87788f563120f6b27ecbd0a6f` and
`CosignWithdrawn(bytes32,bytes32,address)` is
`0x9c1eb928bb591a528a7015e72205402c7672cca208a96ddb70a79dbfd0194a92`. Both carry `data: 0x`,
all three arguments being indexed. `withdrawCosign(bytes32,bytes32)` is selector `0x3cb99427`.

#### `approveCosign` reproduced to the gas, which re-validates the 53,114

Step 2 cost **53,102**. The only previous live `approveCosign`, in `evidence/cosign-approve.log`
and the subject of task #31, cost **53,114**. The two differ by twelve gas
and the explanation is complete: a zero calldata byte costs 4 where a non-zero byte costs 16, a
difference of 12, and the newly approved hash `0x47c5…cab6` contains exactly one zero byte
where `0x15e2…18cd` contained none. Everything else in the two transactions is identical —
same selector, same mandate, same fresh mapping slot, since the earlier approval had been
consumed by its spend and the slot was zero again.

Subtracting the protocol's intrinsic cost, which is a pure function of the calldata bytes,
leaves the on-chain work: **31,026 gas in both transactions, a day apart, to the unit.** That is
worth more than the twelve-gas curiosity. It says the execution of this function is fully
deterministic on Arc, and it retires any lingering doubt about whether the 53,114 was a
representative figure or an accident of one block.

It also, unnoticed at the time, contains the number that overturned task #31's answer. The
31,026 computed here is exactly what the mock gas report's 53,114 yields under the same
subtraction, which is only possible if the report is on the same basis as a receipt. The
argument is at the end of this document.

#### The cheaper call cost 2,012 more, and that is the point

Step 6 withdraws a hash that was never approved. It does strictly less work than step 4: the
slot is already zero, so the `SSTORE` is a no-op at 100 gas rather than `SSTORE_RESET` at
2,900. It cost **2,012 more**.

Twelve of that is calldata again — the ghost hash happens to contain no zero bytes where the
real one contained one. The remaining **2,000 is exact**, and it is EIP-3529: step 4 cleared a
slot that a previous transaction had set, earning a 4,800 refund, capped at a fifth of the
transaction's gas. The cap does not bind — 31,689 before refund allows 6,337 — so the whole
4,800 lands. Against 2,800 of extra work, the net is 4,800 − 2,800 = **2,000 in favour of the
call that did more**.

This is the cleanest demonstration this project has produced of a rule it learned the hard way:
**`gasUsed` is not a measure of work whenever a refund is in play**, and two receipts must not
be subtracted unless both earn the same refund or neither does. The same trap invalidated an
earlier comparison here, and it is now on record with a live example rather than a warning.

A caveat about the arithmetic, since this document has published over-confident reconciliations
before. Modelling both receipts from opcode prices leaves a **constant residual across the
two** — 929 gas under the decomposition that charges two cold `SLOAD`s, two keccaks for the
nested mapping key, the storage term and a `LOG3`. That constancy is worth stating and worth
almost nothing as evidence. The two transactions differ in exactly one term, so *any* model
that gets the storage term right reproduces the difference and absorbs its own errors into the
residual: charging one cold `SLOAD` instead of two gives a constant 3,029, and adding a cold
`SSTORE` access charge gives a constant **−1,171**, which is impossible and still constant. A
model that cannot be wrong is not being tested. Two receipts differing in one term can pin that
term down and nothing else, and pretending otherwise is how the earlier bad figures in this
project got published.

What *is* established without any model is the difference, which is arithmetic on receipts:
+2,012 observed, +12 explained by calldata bytes whose prices are protocol constants, +2,000
explained by a refund whose size and cap are also protocol constants. The revoke section's
constant-532 result is stronger than this one, because there the two payer-path transactions
differed in storage while a third varied the *caller* — an independent axis. Here there is only
one axis, and the honest claim is confined to it.

#### The guardless delete, now with a receipt

Step 6 also confirms by transaction what reading the source suggested. `delete
_cosignApproved[mandateId][hash]` succeeds whether or not anything was there, so
`CosignWithdrawn` was emitted — same topic0, same mandate, same cosigner — **announcing the
removal of an authority that was never granted**. An indexer reconstructing who approved what
from these events will record a state transition that did not happen, and there is nothing in
the event to distinguish the real withdrawal in step 4 from the spurious one in step 6.

Two free probes settle the guard asymmetry alongside it. Called by the agent, which is M2's
spender and not its cosigner, `withdrawCosign` reverts `NotCosigner()` **`0x1cf89d6f`**. Called
against a mandate that does not exist at all, it reverts `NotCosigner()` as well — because line
738 checks only the cosigner, and on an absent mandate `m.cosigner` is the zero address, so the
existence failure is reported as an authorisation failure. `approveCosign` at 728 would have
said `UnknownMandate()`. Neither is unsafe and neither is worth gas on the common path to fix,
on the same reasoning that lets a spender revoke: giving up authority cannot harm the payer, so
it needs fewer guards than granting it. Both are integration notes, and both are now written
down, which they were not before.

### The 53,114 was never a coincidence, and the harness was the thing that was wrong (2026-08-25)

This section reverses a conclusion this document and three others published, and the reversal
came out of the revoke and `withdrawCosign` receipts above rather than out of a new experiment.

The story so far. The mock table earlier in this chapter lists `approveCosign max = 53,114` from
`forge test --gas-report`. The first live `approveCosign` on Arc cost **exactly 53,114**. That
looked too good, and it was investigated as task #31, which concluded the match was an accident
— that a gas report measures execution inside the call frame while a receipt includes the
21,000-gas intrinsic floor plus calldata, so the two are 22,088 gas apart in basis and merely
happened to print the same digits. The argument offered for that was `spendHash` appearing in
the same table at **1,003 gas**, which no transaction can cost.

**That argument is about views, and it was generalised to functions it does not describe.** Every
figure it was applied to belongs to a state-changing function.

#### What the revoke and withdrawCosign receipts showed

Four live receipts now exist for functions that touch no token. Subtract each transaction's own
intrinsic cost — a pure function of its calldata bytes, 21,000 plus 16 per non-zero byte and 4
per zero byte — from both the mock figure and the receipt:

| | mock report | its intrinsic | mock execution | live receipt | its intrinsic | live execution |
|---|---|---|---|---|---|---|
| `revoke`, payer path | 30,808 | 21,576 | **9,232** | 30,808 | 21,576 | **9,232** |
| `revoke`, spender path | 32,945 | 21,576 | **11,369** | 32,945 | 21,576 | **11,369** |
| `approveCosign` | 53,114 | 22,088 | **31,026** | 53,102 | 22,076 | **31,026** |
| `withdrawCosign` | 26,901 | 22,088 | **4,813** | 26,889 | 22,076 | **4,813** |

Four functions, four exact agreements on execution, and the twelve-gas gaps in the receipts are
one zero calldata byte where the live hash differs from the test's. A local EVM and Arc Testnet
execute these four call paths for identical gas, which is what should be true of code that never
reaches the token — and the mock figure is therefore not on a different basis from the receipt.
**It is the same basis. `forge test --gas-report` includes intrinsic gas for state-changing
functions.**

#### Why views read below the floor, and why that misled

The report treats the two kinds of call differently, and the whole table shows it. Sort the
fifteen reported functions by whether they change state — fifteen is v1's surface; v2 adds a
sixteenth, `spendableAcross`, which is unmeasured until the re-run and is a view:

The five state-changing functions have **minima** of 23,773 (`revoke`), 23,979
(`approveCosign`), 24,677 (`withdrawCosign`), 24,898 (`spend`) and 28,630 (`createMandate`) —
every one just above 21,000 plus its own calldata. The ten views have minima from 238 to 10,425,
every one far below it. There is no overlap.

The decisive case is a revert. `revoke`'s cheapest recorded call is
`test_revoke_unknownMandate_reverts`, which loads one cold slot, fails the existence check and
stops. Its execution cannot plausibly exceed about 2,300 gas. The report says **23,773**, and
23,773 − 21,576 = 2,197 — one cold `SLOAD` at 2,100 plus dispatch. A function that does one
storage read cannot cost 23,773 to execute; it can cost 23,773 to *transact*.

`gas-10000.log` confirms the split is structural rather than an artefact of one run. Rebuilt at
`optimizer_runs = 10000`, `spendHash` moves 1,003 → 991 and `getMandate` 10,425 → 10,329, while
`revoke` moves 23,773 → 23,767, `approveCosign` 53,114 → 53,111 and `withdrawCosign` 26,901 →
26,898. **The state-changing figures barely move, by three to fifteen gas, because most of what
they report is a constant the optimizer cannot touch.** That constant is the intrinsic cost.

And the alternative explanation fails on arithmetic. For the report to be execution-only, a local
EVM would have to cost exactly 21,576 more than Arc on a 36-byte call and exactly 22,088 more on
a 68-byte call. Those differ by 512, which is 32 bytes at 16 gas each. Nothing inside a call
frame is priced per calldata byte of the enclosing transaction. Intrinsic gas is, by definition.

#### The consequence, which is larger than the correction

`test/ArcParity.t.sol` was built to do by hand what the gas report was already doing correctly.
It measures with `gasleft()` around an inner call, which really is execution-only, and then adds
intrinsic gas and subtracts 2,700 for the `EXTCODESIZE` and `CALL` that a top-level transaction
never pays. For `approveCosign` it measured 36,231 and predicted 55,819 against a live 53,114 —
**out by 2,705, where the gas report was out by nothing.** Its `createMandate` deviation of
−6,337 and its `approveCosign` deviation of −2,505 are therefore measurements of the harness,
not of Arc.

That matters because those two deviations are exactly what the withdrawn 17,100 and 32,700
premium figures were built from. Their retraction earlier in this chapter rested on the
deviations being non-constant; it now also rests on their being artefacts. The replacement
figures — 9,300 on an `approve` and 13,110 on a `transferFrom` — are untouched, because
`premium.log` compared two receipts against two tokens on the same chain and never used a
harness at all. The lesson generalises: **the harness was the least trustworthy instrument in the
room, and the trustworthy one was in the same file, dismissed on a bad argument.**

There is also something useful here rather than merely corrective. For any function that does not
touch USDC, `forge test --gas-report` predicts an Arc receipt to the gas, adjusting only for the
zero-byte count of the real calldata. Three functions confirm it. That makes v2's cost knowable
before it is deployed for `createMandate`, `revoke`, `approveCosign` and `withdrawCosign`;
`spend` still needs Arc's 13,110 `transferFrom` premium added on top.

*One name in that list is v1's, and the substitution is not free.* #28 replaced
`approveCosign` with `approveCosignFor`, so of the four functions this agreement was
*demonstrated* on, three still exist. The method carries over — the gas report includes
intrinsic gas, which is why it predicts a receipt at all, and that reasoning is about the
report rather than about any one function. The confirmation does not: `approveCosignFor` has
196 calldata bytes against 68, an extra cold SLOAD, an extra keccak and three log data words
against none. Its gas-report row is a prediction whose matching receipt cannot exist until v2
deploys, so do not cite it with the same confidence as the other three.

#### How this was found, since the method is the reusable part

Not by re-opening #31. By noticing, while filing a memory note, that a line quoting the mock
`revoke` figure of 32,945 was the same number as a live receipt written down three sections
earlier — the second such collision in one project. The first was investigated and explained
away. Two unrelated exact collisions is not a coincidence, it is a signal that the model is
wrong, and the check took one subtraction each. **A near-miss on a famous constant is a prompt to
re-derive; an exact hit on your own earlier measurement is a stronger one.**
