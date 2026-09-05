# Confidential USDC

> This document asks one question and does not answer it. The question came out of reading Arc's
> own privacy documentation on 2026-08-30, while deciding where Remit's privacy layer should
> live. `PRIVACY.md` names it in passing as the crux; this file is the long form, because the
> answer decides how much privacy a non-custodial payment primitive can ever offer.
>
> No line numbers appear below. This repository learned that an illustration should carry no
> target, and that a pointer into moving code dates faster than the argument around it.

## The question

**Arc says assets move between public and private contracts through controlled precompile
operations inside a single block. It does not say what a private USDC balance is, or whether one
exists.**

Everything else here is an attempt to show why that single unanswered sentence decides more than
it looks like it decides.

## What the documentation says, and how far that was checked

The claim above is a negative one, so it needs a method behind it rather than an impression.
Arc's published documentation was swept for the pairing on 2026-09-05, and three results bound
the answer.

**Four pages mention the Arc Privacy Sector at all:** the chain overview, the execution-layer
concept page, the system-overview concept page, and `/arc/concepts/opt-in-privacy` itself. The
overview's mention is a navigation card. The two concept pages carry a paragraph each, mark the
environment `Planned`, and sit beside a notice reading *"Arc Privacy Sector (APS) is on the
roadmap and not yet available on Arc."* A search pairing the environment with USDC, assets,
tokens, balances, bridging or precompiles returns no line that pairs the two subjects.

**The precompile that would carry a crossing has no published address.** The execution-layer
page enumerates Arc's five protocol precompiles at `0x1800…0000` through `0x1800…0004` — native
coin authority, native coin control, system accounting, call-from, and post-quantum signature
verification — and the privacy precompile that `/arc/concepts/opt-in-privacy` describes as
receiving the encrypted payload is absent from that list. The contract-address reference lists
no confidential predeploy either. The interface that question three below turns on therefore has
no address to call and no signature to read.

**The one asset example the privacy page offers cannot be applied to USDC.** That example is a
standard OpenZeppelin ERC-20 deployed into the confidential environment with unmodified
bytecode, its `transfer` left open to any caller and its `balanceOf` restricted to trusted
contracts. Arc's USDC is a different object, because `0x3600…0000` is documented as an optional
ERC-20 interface over the native balance and Arc's stablecoin-native page states that the two
interfaces share one balance: `USDC.balanceOf(addr)` and `addr.balance` report the same value in
six decimals and in eighteen. No USDC token contract exists to be redeployed anywhere, and an
ERC-20 deployed into the confidential environment would be a separate asset keeping its own
ledger.

What this settles is what a reader may assume today, which is nothing. Whether a confidential
USDC is planned stays a question only Circle can answer, which is why the list at the end of
this document is addressed to them.

## Why Remit is the sharpest way to ask it

Remit never holds money. A payer keeps their USDC in their own wallet, grants an ERC-20 allowance
to the Remit contract, and every payment is a `transferFrom` that moves value directly from payer
to recipient. Funds never enter the contract, which is the property the whole design is built
around: a payer can end all authority at any moment with `approve(remit, 0)`, and USDC enforces
that rather than Remit.

That property has a consequence for privacy which is easy to miss. **If Remit does not hold the
money, Remit does not do the settling — the token does.** Every observable fact about a payment is
therefore emitted by a contract Remit does not own and cannot change.

Arc makes this concrete in a way most chains do not. Every USDC value movement on Arc emits **two**
`Transfer` logs, not one: the ERC-20 view at `0x3600…0000` in six decimals, and Arc's EIP-7708
native emitter at `0xffff…fffe` in eighteen. Remit's own `Spend` event is a third record of the
same payment. Of those three, Remit controls exactly one.

So the ceiling on payment privacy in Remit is not set by Remit's engineering. It is set by what the
token and the chain emit, and a non-custodial design has no way to reach either.

## Privacy is two properties, and they have different owners

The useful move is to stop treating privacy as one property. A payment mandate leaks two distinct
classes of fact, and they belong to two different parties.

| Class | Examples | Emitted by | Who can close it |
|---|---|---|---|
| **Policy** | caps, per-window limits, expiry, allowlisted recipients, co-signer, running total spent, the delegate's identity | Remit's own storage, calldata and events | **The application.** APS closes all of it. |
| **Settlement** | amount, payer, recipient, timing | USDC's `Transfer`, Arc's EIP-7708 emitter, the payer's public `approve` | **The token issuer.** No application-side work closes it. |

The split is not a technicality. It means two thirds of the privacy question is ours to solve and
one third never was, and it explains why every layer specced in `PRIVACY.md` before APS was either
a commitment scheme or a proof: on a public EVM a contract cannot keep a secret it has stored, only
one it never stored.

Two settlement leaks are worth naming on their own, because they survive everything. **The
payer's allowance is public.** `approve(remit, X)` sits on the token, in the clear, and X is an
upper bound on every dollar that Remit deployment can ever move for that payer. A payer holding a
single mandate publishes that mandate's ceiling by granting the allowance, on a contract no
privacy environment can reach into, before any private state exists. Move the entire mandate
record into a confidential environment and the bound still stands in public.

**A private transaction also pays for itself in public.** Arc's execution pipeline deducts gas in
USDC on every transaction, one step ahead of the module that would process a confidential call,
so the fee for a private call leaves the same native balance the ERC-20 interface reads. The
envelope carrying the encrypted payload is an ordinary transaction with an ordinary sender, which
makes the caller and the fee visible while the payload stays opaque. Two details limit the leak
and neither closes it: the fee emits no `Transfer` log, since Arc's system-events reference puts
fees and block rewards out of scope for EIP-7708 and derives them from the receipt instead, and
the privacy precompile returns a predefined cost with constant-time reporting, so the fee says
nothing about the amount moved. What stays public is that an identified address paid to run
something confidential, and when.

## The half APS closes is the larger half

It would be easy to read the section above as bad news. It is closer to the opposite, because the
half that APS closes is the half that reveals more.

A single payment amount is one data point. A mandate is a policy. Its terms say how much authority
an agent holds, which vendors it may pay, how much it has already spent, whether a human must
co-sign above some threshold, and when the authority dies. Read a company's mandates and you learn
its supplier list, its budget structure, its approval hierarchy and its burn rate. Read one of its
payments and you learn that it paid someone some amount once.

Under APS those policy terms are encrypted contract state, with per-function access policies
enforced at runtime, and none of it costs the application anything in cryptography — the contract
stays ordinary Solidity. `PRIVACY.md` lists caps, thresholds, co-signer and running totals as
hideable "only at ruinous cost." That row is what APS turns into a deployment target.

The remaining question is whether the settlement half follows.

## Three shapes a confidential balance could take

Arc's documentation says assets bridge across the boundary through precompiles inside one block.
Something must therefore exist on the private side to receive value. Three shapes are consistent
with what is published, and they are not equivalent.

**A mirrored balance behind an escrow.** Public USDC is locked in a precompile-controlled
account, and a confidential balance is credited inside the private environment. Individual
balances go dark, while the escrow's total does not, so the size of the shielded set stays
public. Entering and leaving the shield are public events, so the boundary crossings leak
amount and timing even when the payments between them do not. For a spending mandate this
matters more than it first appears: a payer topping up a shielded balance before a payroll run
reveals the run's rough size and its timing, which is most of what payroll privacy was supposed
to protect. Circle's freeze authority applies to the escrow as a whole rather than to
individuals.

**Confidential state on the token itself.** USDC's own balance mapping stored confidentially
inside the private environment, with no separate escrow and no boundary to observe. This is the
strongest shape and the one that needs the most from Circle, and the sweep above shows why it
needs the protocol rather than a deployment: Arc's USDC has no token contract to move, the native
balance and the ERC-20 view are one balance, and that same balance pays for gas. A confidential
representation of it would be a change to how Arc accounts for its native asset, decided by
whoever ships the chain rather than by whoever deploys a contract into it.

**No private token at all.** The confidential environment holds application state only, and every
value movement settles publicly. Policy goes dark, payments do not, and the article ends where the
table above ends.

A reader who wants to know what Remit can promise has to know which of the three is real. So does
anyone building a payment application on Arc.

## The question that decides whether Remit deploys unmodified

Arc's page says existing Solidity contracts deploy into the confidential environment with minimal
modification, the main adaptation being how a contract exposes its interface. For most contracts
that is the end of it. Remit has one feature that makes it a harder case, and it is the same
feature that makes it non-custodial.

A Remit payment is `usdc.transferFrom(payer, recipient, amount)`, where the caller is the Remit
contract and the authority being drawn is an allowance the payer granted to Remit's own address. So
the settlement is not something Remit does to its own state. It is a call into a contract that
lives somewhere else, which must recognise Remit as the caller.

Put Remit inside the confidential environment and leave USDC on the public ledger, and two things
have to hold for the design to survive untouched: the call must be permitted across the boundary
at all, and the token must attribute it to the private contract's address so the allowance
resolves. Arc describes cross-boundary asset movement as precompile-mediated rather than as a
direct call, which is a reason to ask rather than assume. If the value moves through a precompile,
whose allowance does it draw, and what address does the token see?

The consequence of a negative answer is worth stating, because it is not a small refactor. A Remit
that cannot draw a public allowance from inside the confidential environment has to hold the funds
instead, and holding the funds is escrow. Escrow is exactly the cost that ruled out putting the
privacy layer on an external network, and it would arrive by a different road. Non-custody is not
a feature that survives being moved; it is a consequence of where the money sits.

## This is not a Remit problem

The split generalises past this project, which is why the question deserves a document rather than
a footnote.

Every allowance-based protocol has the same shape. A decentralised exchange, a lending market, a
subscription service, a payroll processor — each one holds policy in its own contract and delegates
settlement to a token it does not control. Each can therefore hide its policy in a confidential
execution environment and none can hide its settlement, unless the asset itself has a confidential
form. Custody is the only application-side lever, and using it means becoming the thing users have
to trust.

That is the trade sitting underneath every private-payments design, stated plainly: **you can have
privacy without custody only if the asset issuer participates.** Confidential execution for
applications is necessary and it is not sufficient. The missing half belongs to whoever issues the
money.

Which makes this a good moment to ask, rather than a good moment to build. Circle issues the asset
and is building the chain, so both halves are in one place for the first time.

## What we are asking Circle

Six questions, each answerable in a sentence, ordered by how much they change.

1. Does a confidential representation of USDC exist on the private side, or is it planned?
2. If value crosses the boundary through a precompile, is the crossing observable on the public
   ledger, and does it carry an amount?
3. Can a contract inside the confidential environment draw an ERC-20 allowance held against its
   own address on a public token, with the token seeing that contract as the caller?
4. If the answer to 3 is no, is there a mechanism for spending on a user's behalf that does not
   require the contract to hold the funds?
5. Does either `Transfer` emitter fire for a movement that begins or ends inside the confidential
   environment — the ERC-20 view, the EIP-7708 native emitter, or both?
6. Must the transaction carrying an encrypted payload be signed by the party whose private call
   it carries, or may a relayer submit it, so that the public fee names the relayer instead?

Question 3 is the one that decides whether this repository's contract is deployable into that
environment as written. Questions 1 and 5 decide what it could promise once it is there.
Question 6 decides whether the fee path undoes what the other five secure, and
`GAS-ABSTRACTION.md` already records which sponsorship standards Arc supports, so the answer has
somewhere to land.

## What this document does not claim

Arc's own status line reads *"Privacy features are on the roadmap and not yet available on Arc,"*
with no date. Nothing above is buildable today, and nothing above should be read as a commitment
by Circle to any of the three shapes.

The confidential environment's trust model is hardware enclaves plus a master secret shared
across validator organisations, which is a different set of failure modes from a zero-knowledge
proof rather than a strictly better one. Enclave side channels are real, and circuit bugs are
too. `PRIVACY.md` and `L3-VAULT.md` carry that comparison in full, and neither model dominates
the other.

No conclusion here rests on a claim about any confidential-computing network other than Arc's
own, since the only privacy documentation this project has read is Arc's.
