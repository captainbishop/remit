# Privacy in Remit

## Position

Privacy is a required option in Remit, not a feature to be talked down into
something cheaper.

The argument, which this document now holds: cash is being phased out, and money
that cannot be private is a different kind of money. The ability to shield funds
is what gives money fungibility and gives users a choice. Nothing is gained by
withholding the option. Most payers will never use it, and that is fine — the
option has to exist anyway, because a payer who needs it and cannot get it has no
recourse, while a payer who has it and does not want it loses nothing.

What follows is an honest map of what Remit leaks, what can be hidden, what it
costs, and what no design here can hide. It exists because "add a privacy layer"
is the easiest thing in this codebase to get catastrophically wrong — not by
writing a bug, but by shipping something whose name promises more than it
delivers and letting a payer believe their payments are confidential when they
are not.

## What the previous version of this document got wrong

It concluded: *"Build nothing that hides amounts."* That was the wrong
conclusion, reached through two specific errors. Both are left on the page,
because a design note that quietly changes its mind teaches nothing.

**Error one: a constraint of this architecture was generalised into a law of the
chain.** The old text said the invoice can be hidden but "the payment never can
be." The true version of that claim is narrow: *a Remit spend as currently
architected* cannot hide its amount or recipient, because the spend is
`transferFrom(payer → recipient)` and two system contracts log it — USDC at
`0x3600…0000` in 6 decimals, and Arc's EIP-7708 native emitter at `0xffff…fffe`
in 18 decimals. Neither event is Remit's, and neither is under Remit's control.
That is all true. What does not follow is that amounts are unhideable on Arc.
Transfers *inside* a shielded pool move no USDC and emit no `Transfer` at all.
Amounts are hideable. They are simply not hideable by a flag bolted onto this
design.

**Error two: stealth addresses were killed with an argument that does not
hold.** The old text said a freshly derived stealth address holds zero USDC,
therefore zero gas on Arc, therefore cannot move its own funds, therefore
whoever funds it creates exactly the linking transaction the scheme existed to
avoid. The recipient never needs gas at payment time. The delegate pays for the
spend, and `transferFrom` credits the stealth address while it does nothing at
all. Gas is needed only when the vendor eventually *sweeps*, which is deferrable
indefinitely, batchable across many stealth addresses at once, and exactly the
thing a paymaster sponsors. That is friction, and a real unsolved piece of work,
but it is not a disqualifier.

The same section also claimed stealth addresses "fight the allowlist," since a
one-time address cannot be pre-authorised without revealing it. Retracted:
commit to the recipient's *meta-address* and have the delegate prove derivation
at spend time. Stealth recipients and a merkle allowlist do not conflict — they
complete each other.

## The one fact that makes all of this composable

`MandateManager.sol:371` sets `payer: msg.sender`, and line 345 derives
`mandateId = keccak256(abi.encode(DOMAIN, block.chainid, address(this), msg.sender, salt))`.

Remit does not care who the payer is. Any address that can call `approve` on
USDC and `createMandate` on Remit can be a payer, and a contract can do both.

So: **privacy is a payer, not a flag.**

This matters more than it first sounds, because `MandateManager` is immutable —
no proxy, no admin, no owner, no upgrade hatch, deliberately, so that no key can
raise a cap or drop an allowlist after a payer has granted. A privacy feature
that required changing the contract would mean a redeploy that orphans every
live mandate and invalidates every gas measurement taken against the current
bytecode. A privacy feature that sits *above* it, as a payer, changes nothing,
spends no flag bits, and adds nothing to the audited surface of the one contract
that moves money.

## The leak inventory

Every field below is public today, readable from the live deployment at
`0x3744E93B9e796E05CB66311d897559B6F3860196` on Arc Testnet.

| What | Where it leaks from | Hideable, and by which layer |
|---|---|---|
| `ref` (invoice metadata) | `Spend` | **Yes — L0, 240 gas, already live** |
| Allowlisted vendors | `createMandate` calldata (`address[]`) | **Yes — L1, one flag bit** |
| Recipient address | `Spend` (indexed), ERC-20 `Transfer` | **Identity yes — L2 stealth** |
| Payer address | `MandateCreated`, `Transfer` `from` | **Yes — L3 vault** |
| Amount | `Spend`, plus **two** `Transfer` logs | **Only inside a pool — L3, partially** |
| Delegate address | `MandateCreated`, `Spend` (both indexed) | Only by making delegates one-time |
| Running `totalSpent` | `Spend`, `getMandate` | No — and see below |
| Caps, thresholds, expiry | `createMandate` calldata, `getMandate` | Only at ruinous cost |
| Cosigner address | `createMandate` calldata, `getMandate` | Only at ruinous cost |

Two entries need their "no" explained rather than asserted.

**The policy terms.** Caps and thresholds could be stored as
`keccak256(policy ‖ salt)` with the delegate presenting the policy in calldata on
every spend. Three reasons not to: it costs calldata and hashing on every spend
against an already-measured 177,429-gas marginal cost; it only hides the policy
until first use, because the revealing calldata is itself public; and it destroys
`spendable()`, the view an agent reads to learn its limit before building a
transaction. An agent that cannot ask "how much is left?" discovers its limits by
getting reverted, which is a materially worse system in exchange for
confidentiality lasting until the first payment.

**Storage is not secret — on the public EVM.** Gating `getMandate` on `msg.sender` would
hide nothing there: contract storage is world-readable with `eth_getStorageAt`, and this
repository documents the slot layout. An EVM contract on a public chain cannot keep a
secret it has stored — only one it never stored. Which is why every layer below is a
commitment or a proof, never an access-control check.

**That is an environmental fact, not a law, and Arc intends to change it.** The
qualification was added on 2026-08-25 after reading Arc's own privacy documentation:
under the Arc Privacy Sector (see below) storage is encrypted and per-selector access
policies are enforced at runtime, so access control *does* hide something there. The
reasoning above holds for every layer this document specs, because all of them target
today's public EVM. It does not generalise.

## The four layers

They stack. Each is independently useful and none blocks another.

| | Hides | Still public | Custody | Status |
|---|---|---|---|---|
| **L0** `ref` commitment | invoice, PO, line items | everything else | non-custodial | **live** |
| **L1** merkle allowlist | authorised-but-unpaid vendors | paid recipients | non-custodial | committed to v2 |
| **L2** stealth recipients | recipient *identity* | amount, payer, timing | non-custodial | spec |
| **L3** shielded vault | which depositor authorised | amount, recipient | opt-in custodial | spec — `L3-VAULT.md` |

There is a fifth architecture that is not ours and is not available yet: **Arc's own
Privacy Sector.** It belongs in this table's conversation even though it cannot be in the
table, and it is described after the four layers because it would change what they are
for rather than stack with them.

### L0 — `ref` as a commitment. 240 gas, and already done.

`ref` is a caller-supplied `bytes32` on `spend`, emitted in `Spend` and bound
into the `spendHash`. It is the only field Remit publishes that appears nowhere
else in the transaction — the `Transfer` logs do not carry it — so it is the one
thing Remit exclusively controls.

Demonstrated live as spend #4, tx `0x349770b853b0665260fac3640f3e3f687b9faeb8b4b84bfafb6940fccba2f616`:

```
ref = keccak256(abi.encode(invoiceId, poNumber, amountMinor, vendor, salt))
    = 0x4fa8c8c1c61e17f007f3c9e485abc8e332bcdcad37f2552f0a8f0fac8b98077a
```

Two independent tools — `cast abi-encode` piped to `cast keccak`, and a
standalone Python implementation — produced that value identically, which is
what makes selective disclosure real rather than claimed. An auditor handed the
preimage recomputes the hash and verifies it against an immutable on-chain
record. An observer handed nothing learns nothing beyond the amount and
recipient, which were public regardless.

Occupies the same 32-byte word as a plaintext label, but **not** the same gas, and
the earlier draft of this section claiming a zero delta was wrong. Calldata is
priced per byte — 16 for a non-zero byte, 4 for a zero one — and a keccak digest
has no zero bytes at all. So the commitment's word costs 32×16 = 512 gas, while
`"invoice-0002"` zero-padded to 32 bytes costs 12×16 + 20×4 = 272. **The
commitment costs 240 gas more**, about 0.13% of a spend. Padding is what makes
short plaintext cheap, and any privacy measure that fills a field with
high-entropy bytes gives that discount back.

That is still the cheapest thing in this document by a wide margin — no contract
change, no new storage, no audit surface, and chosen per *spend* by the caller —
but it is a number, not a zero, and the distinction matters here for the same
reason it mattered twice before in this file.

Two boundaries. The salt is mandatory — without it a guessable preimage like
`invoice-0002` is brute-forced in microseconds. And a vendor reconciling
payments against their own invoices now needs a side channel, which is a real
cost paid by someone other than the payer who chose it.

### L1 — merkle allowlist root. One flag bit, bounded cost.

Now committed rather than undecided. Spends **bit 7**, the last free bit in
`uint8 flags`.

The allowlist is passed as `address[] allowlist` and stored in a non-enumerable
mapping, so it cannot be dumped from storage — but the grant transaction's
calldata contains every address in the clear, permanently. That reveals the
vendors a payer has *authorised but not yet paid*: a supplier list, a hiring
pipeline, an acquisition target, visible before any money moves. The `Transfer`
logs never reveal that, so this is a leak unique to the grant.

Storing a root and having the delegate supply a proof closes it, and reveals
only the recipient actually being paid — already public from the `Transfer`, so
the incremental leak is zero. Merkle proofs are boring, battle-tested, no
trusted setup, no novel assumption. Eight vendors is a three-level proof: 96
bytes of calldata, roughly 1,536 gas, plus three hashes, against a 177,429-gas
baseline.

Costs are honest. It is a new branch in `spend`, the one function that must
never be wrong. It needs grant-time validation beside the existing invariant at
line 363 pairing `F_ALLOWLIST` with a non-empty list. It needs its own tests
added to the current 140. It widens the audit scope. And bit 7 is the last one —
widening `flags` to `uint16` is possible, since slot 3 uses 29 of 32 bytes, but
it would invalidate the storage-packing measurements already recorded in
DESIGN.md.

### L2 — stealth recipients. Non-custodial recipient privacy.

Under ERC-5564 the payer derives a fresh one-time address from the recipient's
published meta-address. The `Transfer` log then names an address that cannot be
linked to the vendor without their viewing key. No ZK, no pool, no new trust
assumption, and funds still never touch Remit.

Three things to solve, none of them fatal.

*Sweep gas.* On Arc, USDC is the gas token, so a stealth address holding only
USDC-as-value must acquire gas before it can move anything. The payment itself
is fine — the delegate pays. The sweep is the open problem, and it is deferrable,
batchable across many addresses in one transaction, and sponsorable. This is
where the EIP-7702 question already open in the backlog becomes load-bearing.

*Allowlist compatibility.* Commit the meta-address; prove derivation at spend
time. This is why L1 and L2 compose.

*Cost.* Every stealth address is a first-time USDC holder, and our own
measurements put the account-creation premium at roughly 5,333 gas — on every
payment, not once.

The boundary is sharp and must be stated: amount stays public, payer stays
public, timing stays public. A vendor with one customer is deanonymised by amount
and timing no matter how fresh the address is. L2 protects recipients with many
counterparties, and protects them well; it does very little for a vendor with
one.

### L3 — the shielded vault, as a payer.

**Specced in full in `L3-VAULT.md` as of 2026-08-25.** That document resolves the
three hazards below rather than restating them, and it overturns the first one's
stated fix — read it before building anything here. Its headline conclusion is a
sequencing constraint: L3 requires gas abstraction as a prerequisite, because a
depositor who submits their own `createMandate` transaction appears as that
transaction's `from` and has deanonymised the exact fact L3 exists to hide.

A separate contract. Depositors put USDC in and receive a commitment in a merkle
tree. To authorise spending, a depositor submits a proof that they own an unspent
commitment worth at least the amount, and the vault — as payer — grants the
mandate or spends against an existing one. `transferFrom(vault → recipient)`
executes exactly as it does today.

What this hides is **which depositor authorised the payment**, and that is the
one thing no commitment scheme can reach, because today the payer is the
allowance granter and appears as `from` on every single `Transfer`. Hiding it
requires the payer of record to be a contract that many people share.

`MandateManager` is untouched. It is immutable, and it does not need to change.

Three hazards, named now so they are designed against rather than discovered:

1. **The two-layer cap hazard.** Remit's cap is per mandate; the vault's cap is
   per depositor balance. If those can disagree, one depositor's mandate drains
   another depositor's funds — the pool makes every depositor a creditor of every
   mandate. This is the security-critical part of L3 and it has nothing to do with ZK.

   This entry used to continue *"the vault must debit the depositor's commitment
   atomically with the spend"*, and **that is unimplementable** — left on the page
   per the habit of this file. A spend runs `agent → MandateManager.spend →
   usdc.transferFrom(vault → recipient)` with no vault code executing: ERC-20
   offers the token holder no hook, and `spend` requires `msg.sender == m.spender`
   so the vault cannot interpose itself without becoming the agent. The second
   half of the old sentence was the whole answer — escrow at grant time, size
   `totalCap` to the nullified commitment, reclaim the remainder from the public
   `totalSpent`. See `L3-VAULT.md`.

2. **The delegate as pseudonym.** `MandateCreated` and `Spend` are both indexed
   on the spender. If each depositor brings their own agent, that agent address
   is a stable pseudonym for the depositor and the vault's privacy is cosmetic.
   Delegates have to be one-time, or genuinely shared.

3. **Amount privacy needs the other side in the pool.** A vault-to-external
   spend still publishes amount and recipient. Only vault-*internal* transfers
   publish nothing. So L3 delivers payer privacy on day one and amount privacy
   only in proportion to how many counterparties are inside. That is a
   network-effect problem, not a cryptography problem, and users should be told
   which one they are getting.

The honest costs. Funds enter a contract, so non-custody holds for the base layer
but not for depositors who opt in — that is the trade they are choosing, and it
should be presented as a choice rather than hidden. **Revocation is part of that trade,
and this paragraph used to omit it:** `revoke` admits the payer or the spender (line
704), and under L3 the payer is the vault, so a depositor cannot revoke their own
mandate and the operator can revoke anybody's. Remit's headline control is transferred
to the pool unless the circuit is designed to give it back — see `L3-VAULT.md`. Circle's
freeze authority compounds the same way: freezing the vault freezes every depositor at
once, so pooling converts individual freeze risk into shared fate. A ZK vault also means
a circuit, a verifier, nullifier handling, and either a trusted setup or a transparent
proof system; this is a project with its own timeline, not a sprint. And an anonymity
set of one is not an anonymity set — the set is the number of *unreleased mandates* the
vault holds, not the number of depositors, so the earliest depositors get the least
privacy, which is true of every shielded pool ever built and must be disclosed
rather than discovered.

## The fifth architecture, which is Circle's and is not ready

**Arc documents an opt-in confidential execution environment — the Arc Privacy Sector
(APS) — and this document did not mention it until 2026-08-25.** That was an omission, not
a judgement: two privacy layers were specced against this chain without reading the
chain's own page on privacy, and the search that found it took one query. See
`GAS-ABSTRACTION.md` for how it surfaced and the rule it earned.

What Arc describes: ordinary Solidity contracts deployed into a confidential environment
that runs alongside the public EVM, in hardware enclaves, with both state roots committed
in the **same block by the same validator set** — so private and public contracts compose
atomically, with no bridge and no asynchronous messaging. Isolation is **default-deny**:
every function and storage slot is closed until opened through per-selector
`Open`/`Restricted`/`Locked` policies and revocable `addTrustee` trust domains. Event
logging is off unless a contract explicitly asks for it, revert reasons are sanitised,
introspection opcodes return zero without trust, and gas reporting to external observers is
constant-time. Encryption is hybrid post-quantum, keyed by a master secret Shamir-shared
across validators and reconstructable only inside attested enclaves.

**Arc's own status line: *"Privacy features are on the roadmap and not yet available on
Arc."*** No date. So nothing here is buildable today, and everything below is about
sequencing rather than switching.

Three things it changes about this document.

**It would hide what the leak inventory above marks as unhideable.** Caps, thresholds,
cosigner, running `totalSpent` — the rows this file dismisses as "only at ruinous cost" —
are encrypted state under APS, at no cost in Solidity. Amounts and recipients too, if a
confidential USDC representation exists on the private side. That last point is an open
question the documentation does not answer, and it is the crux: Remit's amount leak comes
from USDC's own `Transfer` and Arc's EIP-7708 emitter, both public-side artefacts. Arc
says assets bridge between public and private contracts through precompiles within a
single block; it does not say what a private USDC balance looks like or whether one exists.
Do not assume it.

**It is a different trust model, and neither model dominates.** L3 as specced asks you to
trust mathematics and a circuit nobody has audited yet. APS asks you to trust hardware
enclaves, a validator-held master key, and an attestation policy. Enclave compromise and
side channels are real; so are circuit bugs and trusted setups. The honest framing is that
these are different failure modes for the same property, and a payer might reasonably
prefer either — which is an argument for eventually offering both, and against pretending
the choice is obvious.

**It reorders the work.** `L3-VAULT.md` is 537 lines specifying escrow accounting,
nullifiers and a circuit whose whole purpose is hiding which depositor authorised a
payment. APS would deliver that as a deployment target. The spec's *contract* findings are
permanent and were worth the session regardless — they are facts about `MandateManager`,
not about cryptography. But committing months of circuit engineering without knowing APS's
timeline would be a mistake, and the cheap move is to ask Circle before building.

One detail worth keeping even if Remit never deploys into APS: **constant-time gas
reporting is Circle acknowledging that gas is a side channel.** That directly supports
`L3-VAULT.md`'s finding that depositor-controlled spend gas is an information leak rather
than merely a cost.

## What no layer here can do

- **Circle retains freeze and blacklist authority over USDC.** Shielding hides
  participants from the public; it does not hide the pool from the issuer, and a
  vault's aggregate holdings stay visible and freezable. Anyone relying on L3
  should know this before depositing.
- **Amount and timing correlation** defeats address privacy for any low-volume
  counterparty, at every layer.
- **Whoever pays gas leaks**, and on Arc gas is USDC, so the gas payer is visible
  in the same asset as the payment. For L2 and L3 this is not a marginal
  correlation risk but a load-bearing dependency: a depositor who submits their own
  `createMandate` transaction is named as its `from` beside the mandate they just
  created, which is a direct and sufficient deanonymisation of the one fact L3
  hides. Gas abstraction is a prerequisite for both layers, not a refinement of
  either. See `L3-VAULT.md`.

  **The mechanism for it already exists on Arc, which this file previously implied it did
  not.** ERC-4337 with EntryPoint v0.7 and a USDC-funded paymaster is live on testnet and
  documented, so the grant can originate from a smart account rather than the depositor's
  own key. What that buys is real but bounded: **the leak moves to the sponsor.** A
  depositor's privacy set becomes whoever shares their paymaster or relayer, and Arc names
  a single third-party bundler as the documented path — so day-one L3 has one party who
  sees every grant request. Say "relayed", never "trustless". See `GAS-ABSTRACTION.md`.
- **Nothing is retroactive.** Every transaction already on chain — including our
  own four live spends and their plaintext `invoice-000N` refs — stays public
  forever.

## Naming

Never `F_PRIVATE`. Name the mechanism: `F_ALLOWLIST_ROOT` describes what the bit
does and promises nothing about outcomes. A user who toggles something called
"private," believes their payments are confidential, and is wrong has been
harmed by the name rather than by the code.

What Remit may truthfully claim, per layer: **selective disclosure** for L0 and
L1, **recipient privacy** for L2, **payer privacy** for L3. It may not claim
"private payments" until amounts are actually hidden, and it should not.

## The regulatory question, which is not mine to answer

Arc is Circle's chain and USDC is a regulated instrument. L0 and L1 are ordinary
business confidentiality of the kind every bank affords its customers, and
neither obscures who paid whom or how much. L2 and L3 are a different
conversation, and one for counsel before anything ships against real money.

That is a sequencing constraint, not a veto. Whether the capability should exist
and how it is lawfully shipped are separate questions, and the first one is
answered at the top of this document.

## Sequencing

L0 is done and demonstrated. L1 lands with the v2 redeploy, alongside the rest of
`CHANGELIST.md`, because bit 7 should be spent once and deliberately. L2 is the
next spec, being the largest privacy gain that keeps non-custody intact. L3 is
its own project and is now specced in `L3-VAULT.md`.

**One thing the spec changed about this ordering, and one thing the research changed
back.** L3 needs no change to `MandateManager`, so it is *not* blocked behind the v2
redeploy. It is bounded by gas abstraction, and so is L2's sweep — but that dependency is
**not** a missing chain feature, which is what the previous version of this paragraph
implied when it called the EIP-7702 question "the actual next piece of work". Arc already
ships ERC-4337 with EntryPoint v0.7 and USDC-funded paymasters, and EIP-7702 set-code
transactions behave as on Ethereum. What remains is an application-level sponsorship
policy of our own: who sponsors, how recipients are screened before a blocklisted address
burns the sponsor's gas, and what caps stop a depositor inflating a sponsored spend. See
`GAS-ABSTRACTION.md`.

L3's security-critical part is also not the cryptography: the escrow accounting, the
release condition and the forced flags are where funds can be lost, and all three are
testable against a placeholder verifier long before a circuit exists.

**And the open question that now outranks all of it.** Arc's own confidential execution
environment would deliver most of L3's purpose as a deployment target, and it is "on the
roadmap" with no date. Ask Circle before committing to a circuit. That is a question, not a
delay — L0 is live, L1 is a v2 flag bit, and neither waits on the answer.

Build the option. Name it accurately. Claim only what each layer supports.
