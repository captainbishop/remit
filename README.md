# Remit

Bounded, revocable, non-custodial spending authority for autonomous agents on Arc.

A payer grants an agent capped, rate-limited, allowlisted, expiring authority to
spend the payer's USDC. Funds never leave the payer's wallet. Every spend carries an
idempotency nonce and emits a reconcilable event. The payer can revoke instantly.

**On naming.** The protocol is Remit; the object it issues is a **mandate**. That
split is deliberate. "Mandate" is the existing term of art for standing, bounded
authority to take money from someone else's account — SEPA direct debit runs on
mandates — so the on-chain type keeps a name that a payments person already
recognizes, and the contract stays `MandateManager`. "Remit" is the outward-facing
name because *within your remit* is precisely what the primitive expresses: authority
that is real, and also has an edge. One known sharp corner, recorded rather than
hidden: *to remit* also means to send payment, which is the one thing this protocol
does not do — it never holds or moves money on its own behalf, it bounds someone
else's ability to move yours.

**New to this?** Read **[START-HERE.md](START-HERE.md)** — it assumes no development
experience, explains what state each piece of the project is in, and gives the exact
commands for getting from here to a working testnet deployment.

Otherwise read **[DESIGN.md](DESIGN.md)** first — it covers why the four existing
options (allowance, unified-balance delegate, per-job escrow, custodial off-chain
policy) are all inadequate, and what this does *not* bound.

Two documents are about the limits rather than the capabilities, and they are the ones to
read before trusting anything here with money. **[THREAT-MODEL.md](THREAT-MODEL.md)** is the
adversarial review — what Remit protects, what it does not, and twenty-six findings against the
current surface. **[IMMUTABILITY.md](IMMUTABILITY.md)** answers the question a payer should
ask second: the deployed contract has no admin, no pause and no upgrade path, so what happens
when something is wrong with it? It includes the migration runbook and the two kill switches,
one of which lives in USDC rather than in this codebase.

## Layout

```
reference/policy.js        the normative spec — executable model of every decision
reference/policy.test.js   57 tests, including boundary-aiming fuzzers
contracts/MandateManager.sol   on-chain implementation (140 tests pass; live on Arc Testnet)
test/                      140 Forge tests against the real storage layout
test/ArcParity.t.sol       the matched local control for the real testnet transactions
demo/playground.html       browser simulation with 7 scripted attacks
DESIGN.md                  rationale, worked examples, verification worksheet
THREAT-MODEL.md            the adversarial review: assets, boundaries, 26 findings
IMMUTABILITY.md            what "no upgrade path" means for a payer, and the migration runbook
FORGE.md                   how to run the Forge suite, and what to expect
START-HERE.md              the on-ramp, if this is your first project
```

## Run the tests

Node 18+, no dependencies, no network.

```
node --test reference/policy.test.js
```

Expected: `# tests 57 / # pass 57 / # fail 0`.

The tests are the actual correctness evidence for this project. They include named
attack cases (tumbling-window boundary burst, backwards clock, co-signature
redirect, identity-NFT transfer, wrong-validator attestation, wrong-agent
attestation) and property-based fuzzers that check accepted spends against a
brute-force exact ledger across `K ∈ {2,3,4,6,12,24}` × 25 seeds × 200 steps.

There is now a second suite, in Solidity: 140 Forge tests in `test/`, covering the
same ground plus the three properties a JavaScript model structurally cannot express —
that a failed spend consumes nothing (real transaction rollback), that rewinding onto
the same physical ring slot accumulates rather than overwrites (real storage aliasing),
and that `totalSpent` panics rather than wrapping near 2^96 (real packed arithmetic).
All 140 pass, under `solc` 0.8.28 — 2,048 fuzz runs and 49,152 invariant calls.
**[FORGE.md](FORGE.md)** covers setup, the two commands that check the suite is not
passing vacuously, and what the first build and the first run actually found.

## Open the demo

```
open demo/playground.html          # macOS
xdg-open demo/playground.html      # Linux
start demo\playground.html         # Windows
```

Pure client-side, no build step, no network. Grant a mandate, then run the scripted
attacks and watch the ledger. Every request is also evaluated against a naive
calendar-day cap so you can see what that implementation leaks — it is exactly 2× in
every configuration tested.

## Deployed on Arc Testnet

**`MandateManager` is live at [`0x3744E93B9e796E05CB66311d897559B6F3860196`](https://testnet.arcscan.app/address/0x3744e93b9e796e05cb66311d897559b6f3860196)**,
source verified, deployed 2026-08-24 in block 58558548 by tx
[`0x5cb3fd0b…24900849f`](https://testnet.arcscan.app/tx/0x5cb3fd0b6d543fecb56d62b7ca3fa36c88974ad0c3a69d2ec09edf524900849f).
A mandate has been granted and a real spend executed against it — see
**Live on Arc** below for the four transaction hashes and the reconciliation.

Chain ID 5042002, explorer `https://testnet.arcscan.app`, faucet `https://faucet.circle.com`
(select **Arc Testnet**). USDC is the gas token, so an unfunded account cannot transact at
all — fund before anything else. That applies to the *delegate* too, which is easy to
forget: an agent with a valid mandate and a zero balance cannot spend, because it cannot
pay for the transaction that spends.

To reproduce from scratch:

Arc's own tutorial uses `cast wallet new` and a `PRIVATE_KEY` in `.env`. This uses the
encrypted keystore instead: the key is never printed and never written in plaintext.

```
forge build                                    # clean; forge-std 1.9.6 is vendored in lib/
forge test                                     # 140 tests, all passing

cast wallet new ~/.foundry/keystores remit-testnet   # prompts for a password;
                                                    # prints the address, never the key
forge create contracts/MandateManager.sol:MandateManager \
  --rpc-url https://rpc.testnet.arc.io \
  --account remit-testnet \
  --broadcast \
  --constructor-args \
    0x3600000000000000000000000000000000000000 \
    0x8004A818BFB912233c491871b3d84c89A494BD9e \
    0x8004Cb1BF31DAf7788923b405b754f57acEB4272
```

`--account remit-testnet` names a keystore in Foundry's default directory; the
`--keystore <path>` form works identically if the file lives elsewhere.

The positional `PATH` is not optional in spirit. `cast wallet new` with no path prints the
private key to the terminal; given a path it writes an encrypted keystore and prints only
the address. Verified against `cast wallet new --help` on Foundry 1.7.1 — an earlier draft
of this file invented a `--keystore-dir` flag that does not exist.

`--broadcast` is required. Without it `forge create` simulates and exits, printing what
looks like success while deploying nothing.

Then publish the source, so the explorer shows an ABI and a read/write UI rather than
bytecode. Arc Testnet Explorer runs Blockscout, and the compiler settings must match the
ones used to deploy:

```
cast abi-encode "constructor(address,address,address)" \
  0x3600000000000000000000000000000000000000 \
  0x8004A818BFB912233c491871b3d84c89A494BD9e \
  0x8004Cb1BF31DAf7788923b405b754f57acEB4272

forge verify-contract <deployed-address> \
  contracts/MandateManager.sol:MandateManager \
  --chain-id 5042002 \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api/ \
  --constructor-args <output of the command above>
```

A payer then calls `USDC.approve(mandateManager, budget)` — approve the intended
budget, not `type(uint256).max`, so the allowance is a hard outer ceiling — followed
by `createMandate(salt, params)`, and then the delegate can `spend`.

## Status, honestly

**Verified.** The reference model runs and passes 57 tests. It found six real
cap-bypass bugs during development: four in the window algorithm (K-bucket
undercount, backwards-clock refill, commit overwriting live history, sentinel
collision at low timestamps) and two in the credential gate (unchecked validator,
unchecked agent id). Each is now a named regression test. The `K/(K+1)` throughput
cost was measured, not assumed: ~92% of nominal at K=12, ~96% at K=24, both within
0.5% of prediction. The demo's engine was extracted from the HTML and exercised
headlessly to confirm it behaves as the page claims.

**Verified against primary source.** All nine Arc-specific claims the design rests
on were checked in the Arc docs; the worksheet at the end of DESIGN.md names the page
for each. One of them changed the design: the reason an allowance is not a spending
cap is that USDC is the native asset and value can leave via `msg.value`, which means
a mandate only enforces anything when this contract is the spender's sole path to the
payer's funds. That limitation is now stated in the contract header and in DESIGN.md
rather than left implicit.

**Verified on a live chain, as of 2026-08-24.** The contract is deployed to Arc Testnet
with verified source, and a delegate has spent a payer's USDC under policy. Four
transactions, all successful, all at an `effectiveGasPrice` of 21 Gwei:

| | tx | gas |
|---|---|---|
| fund the agent (bare `transfer`, 1.00) | [`0x122eb209…166250e4`](https://testnet.arcscan.app/tx/0x122eb20985eb09a2774bc065abd51b49576dcc39bb63a1d7525d9440166250e4) | 73,950 |
| `approve` 2.00 | [`0x6fc4a422…31b41754`](https://testnet.arcscan.app/tx/0x6fc4a422e4d2ce12e8402ae1a9485d03672d6e48fd9887a4befa745331b41754) | 55,438 |
| `createMandate` | [`0xe286718d…57376b73`](https://testnet.arcscan.app/tx/0xe286718d2b66d109c7decc5d7fd0c7c9c564422392f7cfa73e9e0bcf57376b73) | 152,243 |
| `spend` 0.10 | [`0x52e87867…f8930919`](https://testnet.arcscan.app/tx/0x52e878671acf3c85b639fab66bcbfc128e1581a40b975a9cf291a41af8930919) | 216,458 |

Four things were learned that no amount of local testing could have produced.

*Non-custody is now observable rather than argued.* Both `Transfer` logs on the spend
carry `from` = the payer. MandateManager appears in that transaction only as the emitter
of `Spend`. Every prior statement that funds never enter the contract was an inference
from source; this is a block explorer showing money going straight from payer to vendor
with the policy engine as a bystander.

*Every USDC movement emits two `Transfer` logs.* One from Arc's EIP-7708 native system
emitter at `0xfffffffffffffffffffffffffffffffffffffffe` in 18 decimals, one from the
ERC-20 interface at `0x3600…0000` in 6 decimals — the same payment, both decimal views,
one transaction. `approve` emits only one log, so the doubling is specific to value
movement. **Any indexer that reconciles payments by counting `Transfer` logs will
double-count every spend.** Remit's own `Spend` event is the deduplicated authoritative
record; that was a design preference and is now a documented requirement.

*Two identifiers are predictable off-chain, and both were checked against the chain
rather than assumed.* The mandate id computed from `(domain, chainid, contract, payer,
salt)` matched the emitted `MandateCreated` topic exactly, and the `spendHash` returned by
a dry run matched the one in the emitted `Spend` event exactly. So a payer can reference a
mandate, and a cosigner can approve a specific spend, before either is mined.

*Six policy gates were re-checked against the deployed bytecode*, not the mock, by
dry-running each rejection with `cast call` — which costs nothing. Replaying a used nonce
returns `NonceAlreadyUsed()`, a non-allowlisted recipient `RecipientNotAllowed()`, an
over-cap amount `OverPerTxCap()`, the payer signing in the delegate's place
`WrongSpender()`, a zero amount `ZeroAmount()`, an unknown id `UnknownMandate()`. A
legitimate spend with a fresh nonce still simulates clean afterwards, so the gate rejects
the duplicate rather than the mandate seizing up.

**Not verified.** It has not been audited. Five mandate shapes have now been exercised
live — ungated, cosigned, identity-gated, and credential-gated with and without a staleness
bound — and both ERC-8004 gates fired against Arc's real registries with a passing ungated
control beside them. `revoke` was exercised on 2026-08-25, once by a payer and once by a
delegate revoking its own authority, and `withdrawCosign` the same day, so **all five
state-changing functions now have live transactions across thirty-one of them, every one with
`status 1`**. Both of those numbers were wrong in an earlier version of this paragraph, which
said `revoke` was the only untried path and then said five of six functions rather than five of
five; the surface is five, obtained by parsing every declaration in the contract for `external`
or `public` without `view`. What stays untestable rather than merely untried is the identity
gate's *positive* path, until an identity NFT is minted to our delegate.
Sub-second blocks sharing a timestamp and the CallFrom precompile remain asserted from
documentation rather than observed.

**Measured against Arc's real USDC, as of 2026-08-24.** The steady-state marginal spend,
measured inside an already-written window bucket, costs **177,429 gas ≈ 0.0037 USDC**. A
bare `transfer` to a fresh account on the same chain costs 73,950. So the entire apparatus —
per-transaction cap, lifetime cap, 24-bucket rolling daily window, expiry, allowlist,
idempotency nonce, audit event — costs about **103,479 gas, roughly 0.217 cents per
payment**, and a policed payment is about **2.4×** a bare one. A *first-ever* spend on a
fresh mandate, with every slot cold and every counter virgin, costs 216,458; quoting that
against a bare transfer is what produced the ~142,500 figure this paragraph used to carry,
and it charged one-time initialisation to the recurring cost. One caveat survives:
`transferFrom` touches the allowance slot and `transfer` does not, worth ~5,000 gas, so read
the floor as ~98,000.

**Arc's native USDC is more expensive than a plain ERC-20, and the premium is very nearly a
per-call constant.** Both halves of that sentence used to read differently, and both were
wrong. The premium is now measured directly, with no test harness in the comparison:
`test/mocks/MockUSDC` was deployed **to Arc**, and the same operation run against both tokens
from the same wallet with byte-identical calldata, so intrinsic gas cancels exactly and the
whole receipt difference is Arc's own accounting.

| | mock | Arc USDC | premium |
|---|---|---|---|
| `approve`, zero slot | 46,138 | 55,438 | **9,300** |
| `transferFrom`, three overwrites | 46,688 | 59,798 | **13,110** |
| `approve`, live slot | 29,038 | 38,338 | **9,300** |

`approve` costs the same 9,300 whether it writes a virgin slot or overwrites a live one. A
`transferFrom` touching three slots costs 13,110, not the ~27,900 a per-slot model predicts —
1,756 of the difference is Arc's second `Transfer` log, emitted by the native system emitter
in 18-decimal wei alongside the 6-decimal ERC-20 one.

The superseded figures were **17,100 and 32,700**, too high by 1.8× and 2.5×. They came from
using `createMandate`'s harness deviation as a flat additive constant, which
`evidence/cosign-parity.log` had already shown it is not. Worse, 17,100 is not a premium at
all: it is the EIP-2200 zero-versus-non-zero storage gap, which shows up *identically* on both
tokens — 46,138 − 29,038 and 55,438 − 38,338 both equal exactly 17,100 — and therefore
cancels. The old route reached 10,757 + 6,337 = 17,094 and rounded, landing six gas from a
constant that has nothing to do with Arc, which is what made a broken number look
corroborated. DESIGN.md has the full derivation and the itemisation that closes the mock's
baseline to the gas.

The intrinsic-gas half of those predictions came out exact rather than approximate — 22,304
predicted and 22,304 charged for the spend's 164 bytes of calldata, and 24,828 against the
test's 24,816 for `createMandate`, a 12-gas gap caused by a single byte of the spender
address. Deployment reconciled to **0.009%**: 2,557,681 predicted against 2,557,453 charged.

Two numbers here were wrong in earlier drafts of this file and are worth naming. The
contract is **11,572 bytes** of runtime code, not the 11,964 published for weeks — the
real figure is confirmed twice, by `forge build --sizes` and by the on-chain code length,
whereas 11,964 came from a single unverified source and matches neither the runtime nor
the initcode (11,868). And Arc's 20 Gwei base fee is a *floor*, not a price: every
transaction so far settled at 21 Gwei, so every cost figure computed at the floor ran ~5%
low. Deployment cost **0.0537 USDC**, not the 0.051 published.

**`K=24` is affordable — the open question is closed.** Each extra bucket adds one cold
`SLOAD`, ~2,150 gas or 0.000045 USDC at 21 Gwei. Widening a window from `K=12` to `K=24`
costs about 25,800 gas, **0.00054 USDC — a twentieth of a cent** — and buys a rise in the
`K/(K+1)` throughput floor from 92% to 96% of nominal. `K=24` should be the default
wherever the rate limit is load-bearing. The caveat that used to sit here — that this was
measured against a mock and Arc's real token would cost more by an unknown margin — is
now answered: the margin is **13,110 gas** on the `transferFrom`, and it is a per-call
constant, not a per-bucket cost, so it does not change the K decision at all.

Writing the tests did surface real work: four places where the contract was right and
the reference model was wrong. The co-signature threshold is strictly greater, so an
at-threshold spend needs no signature. The staleness guard treats `maxStaleness == 0` as
no requirement at all rather than maximum strictness. An amount above `2^96-1` is
refused outright, before any cap is consulted, because every cap is a packed `uint96`
and an unchecked downcast would truncate a large amount into a small one that passes.
And the spender may revoke, not only the payer — an agent that has finished its work or
detects it is compromised can surrender its own authority, which cannot hurt the payer
because the only power it removes is the agent's own.

Writing the *documentation* then surfaced a fifth, which is the more interesting one.
Explaining the credential gate's agent binding carefully enough to caveat it exposed
that the model resolved the expected agent with `??`, so `agentId: 0n` meant "require
the attestation to be about agent 0" — a state the on-chain `uint256` cannot express,
where zero is the only available spelling of "unset". The divergence was invisible to
every existing test and sat on a security path.

Generalising *that* — auditing every field whose zero doubles as "unset" — found five
more, all in the same direction: the model's `createMandate` accepted configurations the
contract refuses. A window with `cap == 0`. An `expiresAt` at or before `notBefore`. The
zero address on an allowlist. A credential with no validator, which the on-chain flag
rules cannot represent. And `minResponse == 0`, which is the one that matters: ERC-8004
encodes a *failed* validation as a low response and 100 as passing, so a zero threshold
does not loosen the credential gate, it inverts it into one that accepts precisely the
attestations it exists to reject. The contract refuses all five. `Creation.t.sol` already
asserted all five. The model had none of them, so a first `forge test` would have caught
the lot — this reconciliation just got there without a compiler, by reading.

One more fix came out of it that is about the model's job rather than its logic. The
credential's defaults were applied at read time, so a constructed mandate carried
`undefined` in fields that become uints, and a client encoder turning an omitted
`minResponse` into `0` would emit exactly the value `createMandate` refuses. The
credential is now materialised at construction in its on-chain spelling, so the object
the model returns encodes directly into the contract's struct with no second layer of
defaults to disagree with. A specification that needs a translator has moved the bug
rather than fixed it.

The model now matches on all ten, which took its suite from 41 tests to 46 — and to 57 over
the course of v2, which added the counter-ceiling denial, three cosign-gate refusals, six
joint-ceiling tests and the lifetime-bound narrowing. One Forge
test was also rewritten for proving nothing — it tripped two `BadWindow` conditions at
once, so it would have passed with either check removed.

The first real run was informative in the way that matters: seven things had to be fixed
and all seven were in the tests, not the contract. Three were compile failures — a
malformed `foundry.toml` key, `reference` used as an identifier when it is a reserved
word, and a fuzz helper whose frame exceeded the EVM's 16-slot stack reach. Four were
failing assertions: two tests let a nested `spendHash` call consume the `vm.prank`
intended for `approveCosign`, one had arithmetic in its comment that did not match its
own threshold, and one asserted via `vm.recordLogs` that a reverted frame leaves no
event behind — which is true of the chain and not true of the recorder, so the assertion
was unanswerable rather than merely wrong. It was replaced with the observable form of
the same claim.

**v1's three known soft spots, and what v2 has done with them.** None was something the
compiler or a green suite would flag, because they are behaviours rather than errors —
two of the three were in fact pinned by *passing* tests, which is the point. All three
remain permanent properties of the deployed v1 at
`0x3744E93B9e796E05CB66311d897559B6F3860196`, which has no upgrade path. The fixes below
are in this tree, for a contract that has not been deployed. All three are now fixed, and
the third one turned up two further holes that no list anywhere had recorded — so read
"three" as the number that had been written down, not the number that existed.

*Fixed.* `m.totalSpent + uint96(amount)` was computed before the `F_TOTAL` check, so the
addition ran even for a mandate with no lifetime cap, and a cumulative total near 2^96
base units — roughly 7.9e22 USDC — produced an arithmetic **panic** rather than a
graceful stop. v2 consults the lifetime cap without performing the addition, then guards
the counter with a named `TotalSpentCeiling()`. The mandate still stops at the ceiling,
which is inherent to a counter that is bounded and must stay exact because the audit
trail carries it; what changed is that it now says why.

*Fixed.* `revoke` reverted with `NotPayer()` even though the spender is also permitted to
call it. Four places in this repo recorded that the name was misleading and kept it
anyway, on the grounds that it was already in a deployed ABI. Tagging
`v1.0.0-arc-testnet` retired that reason — v1's ABI is pinned at v1's address — so v2
calls it `NotAuthorised()`, moving the selector from `0x1435e357` to `0x1648fd01`.

*Fixed, and it grew.* A mandate whose co-signature threshold sits at or above the largest
single spend its other bounds permit makes the co-signature branch unreachable, producing a
policy that looks supervised and silently never asks for a signature; v1's `createMandate`
accepts it. Two details this paragraph previously got wrong: the condition is `<=` rather
than `<`, because `spend` tests `amount > cosignThreshold` strictly, so a threshold exactly
equal to the ceiling is dead too — and `perTxCap` is not the only ceiling, since with
`F_PER_TX` unset the effective one is the smaller of the lifetime cap and the window caps.
v2 refuses the grant, comparing the threshold against `min(2^96 - 1, perTxCap, totalCap,
every window cap)`, which still accepts a mandate that bounds no amount at all — an
expiry-only mandate is legal in v2 and the `2^96 - 1` term is what keeps the guard
meaningful there, since `AmountTooLarge` is then the only ceiling on a single spend.

Fixing it properly meant asking the general question — *in how many ways can a mandate
display a co-signature requirement and not have one?* — and the answer was five, not one.
Two were already refused in v1, this was the third, and **two more had never been written
down anywhere**. A threshold with `F_COSIGN` unset is stored and shown by `getMandate` and
measured against nothing. And, worse, `approveCosign` authorises on `msg.sender ==
m.cosigner` alone, so a mandate whose **cosigner is its own spender** lets the agent
approve its own spend hash and then spend it: the supervision gate becomes two
transactions and no second party. Neither is a divergence between the contract and
`reference/policy.js` — the model accepted both too, so no amount of cross-checking the
two implementations would have surfaced them. v2 refuses all three. `cosigner == payer`
remains legal and is the ordinary case; it is what live mandate 2 does on Arc today, and a
rule that condemned it would have contradicted a receipt. (v2's `approveCosignFor`
authorises the same way, which is the point: the fix belongs at grant time, because no check
inside an approval can tell a cosigner who is legitimately also the payer from one who is
illegitimately also the spender.)

**And two more that were on no list at all, found by writing the threat model.** Neither
belongs to the three above; both came out of a sweep asking which fields a mandate can
display without anything measuring against them, and both are grant-time refusals in v2.
The first is the bigger change. v1 called a mandate "bounded" if it carried a
per-transaction cap **or** a lifetime cap **or** an expiry **or** any window — but a
per-transaction cap bounds one spend and permits unlimited spends, and a window bounds a
*rate* and permits unlimited cumulative spending given enough time. So `perTxCap = 100`
and nothing else is a standing instruction to spend 100 USDC forever, and v1 accepts it
while its own comment beside the check claims otherwise. v2 requires a lifetime cap or an
expiry specifically, and refuses everything else with `Unbounded()`. The second: with
`F_EXPIRY` unset, `spend` never reads `expiresAt`, so a payer could set a deadline, see it
returned by `getMandate`, and have it enforce nothing — v2 refuses that pairing at grant
time, which closes the last field in the struct that could be shown and unread.

The cost of the first one is real and is worth stating plainly: it invalidates worked
examples in this repository's own documentation, including the flagship one in `DESIGN.md`,
which bounds a rate and a blast radius but never a lifetime. Those are being corrected
rather than grandfathered. Every new grant-time refusal re-audits every configuration the
project has ever printed, and that sweep is the expensive part, not the two lines of
Solidity.

**Not audited.** No third party has looked at this. Do not put money behind it.

This is a blocker rather than a disclaimer: Remit is intended to hold real money, not to
be a testnet demonstration. That intent is what makes the audit a scheduled line item and
what makes `forge test --profile deep` (20,000 fuzz runs, 2,000 invariant runs at depth
256) the gate to clear before it, rather than the default profile used during development.
It is also what reopened the three soft spots listed above as decisions rather than
curiosities, and what settled each of them the strict way — the dead co-signature gate in
particular, which had been left legal on the reasoning that a merely useless configuration
does not deserve a validation rule. Real money turns "useless" into "advertises a control
it does not have", and immutability means a combination left legal is legal forever at that
address.

**Unresolved factual questions.** Whether Circle's `agent-wallet-policy` already
implements equivalent caps off-chain in its custodial API — unverified, so the claim
to make is "non-custodial, on-chain, independently verifiable", not "first". And whether
an EIP-7702-delegated EOA still counts as an EOA for the Memo path, which matters for
smart-account agents and, given the real-money intent, needs an answer before launch.
The gas question that used to sit here is answered above.

## Next

The Forge port is written and runs — 140 tests, including exact-ledger property tests and
a stateful invariant that lets the fuzzer choose the call sequence. All pass. Gas is
measured against Arc's real USDC, `K=24` is settled as affordable, and the contract is
deployed and exercised on testnet.

Raising `optimizer_runs` was the obvious next move and it has been tried and rejected. The
reasoning was that 200 is low, deployment costs five cents once, and `spend` runs forever —
so 200 must be optimising the wrong end. Rebuilding the whole tree at 10,000 bought **six
gas** on a spend, 0.02%, for 27% more bytecode. A spend's cost is cold `SLOAD`s and an
external `transferFrom`, both priced by the EVM rather than by codegen, so there was never
anything there for the optimizer to win. The live measurements neither strengthen nor weaken
this much: **13,110** of a real spend is Arc's own token accounting, which no compiler setting
can touch — 6% of a 216,458-gas spend, not the 15% this line used to claim at ~32,700. 200
stays on the strength of the six-gas measurement alone. DESIGN.md has the table and the seed
caveat that nearly made this look like a 40% improvement.

What's left, in order:

Four items that used to head this list are done and are struck from it rather than quietly
dropped, because the order they came off in is itself a record. `forge test --profile deep`
— 20,000 fuzz runs, 2,000 invariant runs at depth 256 — has been run as the pre-audit gate.
The three soft spots have been resolved as decisions, all three the strict way, and the
third one uncovered two more. And the live exercises are closed: a cosigned spend and a
revocation both have receipts on Arc Testnet, along with `approveCosign` and
`withdrawCosign`, which is all five state-changing functions **that v1 exposed** — v2 renamed
one of them, so see the note below. The identity and credential
gates are the exception and are still unexercised on chain, blocked on something no amount
of care in this repository can supply — an ERC-8004 identity minted to our agent wallet,
and an attestation that passes rather than the one real attestation on Arc Testnet, whose
response is a failing 1.

**One of those five no longer exists.** #28 deleted `approveCosign(bytes32,bytes32)` in favour of
`approveCosignFor(mandateId, recipient, amount, ref, nonce, validUntil)`, so the sentence above
is a closed statement about v1 and **not** a claim that every path in the current source has a
receipt. Four of v2's five do, for the same signature; the cosign approval path has none, and
cannot until v2 deploys.

So: finish v2 — the merkle allowlist is the last change, the joint-ceiling view having landed
as `spendableAcross`, which exposes the shared-allowance overlap the live 2026-08-24 run found
and cost three new refusals and a `2^96 − 1` clamp on top of the sum the changelist described.
Then re-measure
the whole baseline against v2's bytecode, since the published gas figures describe v1's.
Then answer whether an EIP-7702-delegated EOA counts as an EOA for the Memo path. Then a
viem client. Then the audit, which is mandatory rather than optional, because this is meant
to hold real money.

The model has already been reconciled against every place the contract was right and it
was not — ten of them — so the two suites now agree on every question both of them ask.
