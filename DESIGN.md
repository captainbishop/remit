# Remit

**Bounded, revocable, non-custodial spending authority for autonomous agents.**

Remit is the protocol. A **mandate** is the object it issues — the term of art for
standing, bounded authority over someone else's account, kept because it is already
correct. Throughout this document, "a mandate" means one grant of authority.

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

`reference/policy.test.js` is 46 tests over that model: construction guards, each
cap and gate, named attack tests, and property-based fuzzers. It includes a greedy
adversary that aims spends at bucket boundaries across `K ∈ {2,3,4,6,12,24}` × 25
seeds × 200 steps, checked against a brute-force exact ledger. This is the primary
correctness evidence for the whole project.

`contracts/MandateManager.sol` is the on-chain implementation, written to mirror the
model, with every deliberate deviation commented at the point it occurs.

`test/` is the Forge port: 139 tests against the real storage layout, covering the same
ground plus the three properties a model structurally cannot express — transactional
rollback, storage aliasing in the bucket ring, and packed-`uint96` arithmetic. See
FORGE.md. As of 2026-08-24 it compiles and all 139 pass.

## Honest status

The reference model is real, executed, and passing: `node --test
reference/policy.test.js` reports 46 tests, 46 pass, 0 fail. It found six genuine
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
no errors, and `forge test` reports 139 of 139 passing: 2,048 fuzz runs across four
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
| deploy `MandateManager` | 2,557,693 predicted / **2,557,453 charged** | **0.0537** |
| `createMandate` median / max | 128,465 / 241,218 | 0.0027 / 0.0051 |
| **`spend` median / max** | **110,380 / 201,786** | **0.0023 / 0.0042** |
| `spend` min (simplest mandate) | 24,898 | 0.0005 |
| `revoke` max | 32,945 | 0.0007 |
| `approveCosign` max | 53,114 | 0.0011 |

Those are mock-USDC figures and are kept because they are the only ones covering the whole
configuration space. **For what a real spend actually costs, the live numbers below
supersede them.** Contract size is 11,572 bytes of runtime code against the EIP-170 limit
of 24,576, so a little over half the budget is still free. (This document previously said
11,964, which was wrong; see the size note in `foundry.toml`.)

### What it costs on Arc, measured against the live chain

`test/ArcParity.t.sol` exists because comparing one real receipt against the median above
would measure almost nothing — that median aggregates mandates with four windows, with
none, with credential gates, and spends denied before they touch the token. The parity
suite runs the *same three transactions* with the same constants, in three separate test
contracts so that storage is cold in each, and computes intrinsic gas from the real encoded
calldata so its predictions are directly comparable to a receipt.

| | predicted | charged on Arc | delta |
|---|---|---|---|
| `approve` 2.00 | 44,681 | **55,438** | +10,757 |
| `createMandate` | 158,580 | **152,243** | −6,337 |
| `spend` 0.10 | 190,120 | **216,458** | +26,338 |
| bare `transfer` 1.00, for reference | — | **73,950** | — |

`createMandate` touches no USDC, so its deviation is the harness, not Arc. Part of it is
that a real transaction gets its `to` address pre-warmed under EIP-2929 while the test pays
~2,600 for a cold `CALL` into the contract; the remainder is undecomposed and is recorded
as undecomposed. Using it as a calibration constant, Arc's `NativeFiatToken` costs roughly
**17,100 gas more than a minimal ERC-20 for an `approve`** (one slot, one log) and **32,700
more for a `transferFrom`** (three slots, two logs).

**The premium scales with balance slots touched, not per call.** This was got wrong in
advance: the spend was predicted at ~203,000 by carrying `approve`'s premium across and
adding one log, and it came in at 216,458. Anyone re-deriving these numbers should assume
the overhead is per-slot.

The intrinsic-gas model came out exact rather than approximate, which is what licenses
attributing the residual to Arc: 22,304 predicted and 22,304 charged for the spend's 164
calldata bytes, and 24,828 against the suite's 24,816 for `createMandate` — a 12-gas gap
caused by one byte of the spender address differing between the mock and the real agent.

**So the real price of the policy machinery is about 142,500 gas, or 0.3 cents.** A fully
policed spend is 216,458; a bare `transfer` to a fresh account on the same chain is 73,950.
The difference buys a per-transaction cap, a lifetime cap, a 24-bucket rolling daily window,
an expiry, an allowlist, an idempotency nonce and a reconcilable audit event. A policed
payment costs about 3× a bare one. The figure flatters itself slightly — `transferFrom`
touches the allowance slot and `transfer` does not — so read it as ~130,000–142,500.

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
cost strictly more, as predicted, and the magnitude is now measured: ~32,700 gas on the
`transferFrom`. It is a constant per spend, not a per-bucket cost, so it does not touch the
`K` decision — it raises every spend by the same amount whether the mandate has one window
or four.

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

Deploying to Arc confirmed this from the other direction. About 32,700 gas of a real spend
is Arc's own native-USDC accounting inside `transferFrom` — a cost no compiler flag can
reach. The gas case for raising `runs` is weaker on the real chain than it looked locally,
not stronger.

The general lesson is worth more than the setting. "This is the hot path, so optimise it
harder" is not an argument unless the hot *cost* is the kind of thing the optimiser can
reach. Here it never was.

**A methodological correction, which matters for anyone repeating this.** The fuzz seed is
not pinned, so two runs do not execute the same call sequences — `spend` was called 125,708
times in the first run and 125,447 in the second. The Median and Avg columns are therefore
not comparable across runs. On first reading, this table appeared to show `windowRemaining`
improving by 40%; that was entirely seed noise. Compare the Min column, which is the same
deterministic path in both runs, or pass `--fuzz-seed` to both.

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

The live exercise covered exactly one mandate shape: no cosigner, no identity gate, no
credential gate, one window, one allowlist entry. The cosignature path, both ERC-8004 gates
and `revoke` have 139 passing tests behind them and zero live transactions. That is a real
gap, because the ERC-8004 registries are ERC-1967 proxies whose behaviour can change under
us — and one of them already reverts with `Error(string) = "unknown"` where the design had
hedged that it might return a zero tuple.

Two Arc behaviours remain asserted from documentation rather than observed: sub-second
blocks sharing a timestamp, and the CallFrom precompile. Whether an EIP-7702-delegated EOA
counts as an EOA for the Memo path is also unresolved and matters for smart-account agents.

Before this is trusted with money: run the suite at `--profile deep`, exercise the untouched
paths on testnet, resolve the three documented soft spots as decisions, and get it audited.

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
