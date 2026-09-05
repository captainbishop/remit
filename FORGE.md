# Running the Forge suite

320 tests across thirteen files — which `forge test` reports as **15 suites**, for reasons
worked through under Layout — verifying `contracts/MandateManager.sol` against the real EVM:
packed structs, the bucket ring in actual storage mappings, and transactional rollback. This
is the port of `reference/policy.test.js`, which has 116 tests and verifies the *policy*.
Both matter, and they are not redundant — the section on what Solidity can prove that
JavaScript cannot is below.

**Status: all 320 pass; `forge lint` at default severity is clean on the v2 tree.** First
compiled and first run on 2026-08-24 at 140 tests, under `solc` 0.8.28 with the optimizer at
200 runs, in about twelve seconds; the last timed run was 9.62 seconds at 320. That covers
2,048 fuzz runs across the four property tests and 49,152 calls across the three invariants.
What the first compile and the first run each cost is recorded below, because a suite's
first green is the only time you learn whether it was testing anything.

**They also pass under `--gas-report`, but only since 2026-08-25, and the reason is worth
knowing before you trust a `gasleft()` figure.** `--gas-report` adds per-call tracing
overhead that lands *inside* a `gasleft()` window, and it is not constant between two calls.
`ArcParity.t.sol`'s A/B isolation measured A = 36,231 without the flag and **58,319** with
it, for identical bytecode, and B came out larger than A — so `used - usedWarm` panicked
`0x11` on the unsigned subtraction and the suite reported 139 passed, 1 failed. Both the
isolation and the residual bound are now guarded on `usedWarm >= used` and print a skip
notice instead. Two consequences: a `gasleft()` measurement is only quantitative under plain
`forge test`, and an unsigned subtraction in a test is an assertion with a worse error
message — `assertGt` first.

The same run made the larger point for free. Foundry's gas report listed `approveCosign` at
a max of **53,114** under the flag, which is the live Arc receipt to the gas, while the
harness wrapped around that identical call read 58,319. The tool this file was built to
check is mode-independent and correct; the harness is neither.

`ArcParity.t.sol` is not a correctness test, and it is not one suite — it declares four
contracts holding one test each, because every measurement needs its own cold storage.
Those four reproduce the exact four transactions that were sent to Arc Testnet — same
caps, same window, same recipient, same amounts — so that real receipts have something
honest to be compared against.

**Three of the four, since #28.** F15 deleted `approveCosign(bytes32,bytes32)`, so
`ArcParityApproveCosignTest` — now `test_arcParity_4_approveCosignFor` — no longer reproduces
any transaction that was ever sent to Arc. Its two assertions against the live 53,114 were
**deleted rather than loosened**, because widening a tolerance until a different function fits
inside it would have relabelled our own arithmetic as an Arc property. `ARC_LIVE_GASUSED` stays
in the file as history behind a banner explaining why it is unrepairable, and what survives in
that test is everything that never depended on it: the A/B cold-surcharge isolation, the hand
decomposition, the intrinsic-gas arithmetic, and a `used > 20_000` floor proving a virgin SSTORE
was really paid for. **What the repository lost is its only same-function comparison between a
Foundry prediction and a real Arc receipt on a USDC-free operation** — that check does not come
back until v2 deploys and earns a new anchor for the new function.

Two further findings sit in that file's comments. The header records that its first
version measured the wrong thing, passed every assertion while doing so, and reported an
`approve` costing 3,185 gas when the SSTORE alone is 20,000. The comment above
`ArcParityApproveCosignTest`, added on 2026-08-25, records the more uncomfortable of the
two: **this harness was less accurate than the tool it was built to check.** Its
`gasleft()` figure for `approveCosign` overstates real execution by about 5,205 gas, while
`forge test --gas-report` — which includes intrinsic gas for state-changing functions, the
fact the whole episode turned on — reproduces four Arc receipts to the gas with no
adjustment at all. The superseded reasoning is kept inside delimiters in that comment
rather than deleted, because the reasoning failure matters more than the number. The
closing section of `DESIGN.md` has the full argument.

This document used to open by warning that none of it had ever been compiled. That is no
longer true, and the sections that were written as predictions are now labelled as such
rather than deleted — a wrong prediction about where code breaks is more useful kept than
tidied away.

## Setup

forge-std 1.16.2 is **vendored into `lib/` and tracked in this repository**, so there is
nothing to install beyond Foundry itself. From the project root:

```
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge build
```

Those are bash commands. On Windows they belong in WSL rather than PowerShell, and
`START-HERE.md` has the step-by-step for setting that up.

Vendoring is deliberate, and the reason is reproducibility rather than convenience.
Every gas figure in `DESIGN.md` and every test in `test/` is a property of exact bytes compiled by
solc 0.8.28 at `optimizer_runs = 200`, and re-resolving the dependency — whether by
`forge install`, a submodule, or a fresh clone of a moving branch — risks fetching
different bytes with no error and invalidating the whole baseline. `forge install` is the
idiomatic route and was considered; it wants a git repository, manages submodules, and
the flag controlling whether it commits has changed across Foundry versions.
`libs = ["lib"]` in `foundry.toml` makes the `forge-std/` remapping resolve either way.

**The bytes the verification claim covers.** An earlier version of this section said the
deployment at `0x3744E93B9e796E05CB66311d897559B6F3860196` is verified on-chain against
*these* bytes, meaning whatever is in the working tree. That was true while
`contracts/MandateManager.sol` was frozen and it stopped being true the moment v2 work
began, so the claim now names a commit instead:

```
git checkout v1.0.0-arc-testnet && forge build
```

reproduces the runtime bytecode Blockscout verified — 11,572 bytes, initcode 11,868. The
tag is annotated and its message carries the address, the deploy transaction, the compiler
settings and the `DOMAIN` constant. `main` no longer reproduces that deployment and is not
supposed to; it is v2 in progress, and v2 gets its own address, its own verification and
its own gas baseline. A reproducibility claim has to name a revision to mean anything, and
tying one to "the current tree" guarantees it expires without anyone noticing.

The cost, stated plainly: `forge update` will fight this, and the diff on any future
forge-std bump will be large. Bump deliberately, in its own commit, and re-run the full
suite plus `FOUNDRY_PROFILE=deep forge test` afterwards.

**The same reasoning governs every line number in this repo.** Eighty references across
`DESIGN.md`, `CHANGELIST.md`, `L3-VAULT.md`, `PRIVACY.md`, `GAS-ABSTRACTION.md`,
`IMMUTABILITY.md` and `evidence/README.md` point into `contracts/MandateManager.sol`,
seventy-two of them written `line NNN` or `lines NNN` and eight naming the file. All
eighty were written against v1 and all eighty shifted the moment v2 edits began — the
header banner alone moved everything below it by sixteen lines. **Unqualified line numbers
therefore refer to the tagged v1 source**, which is where they are still exactly right:

```
git show v1.0.0-arc-testnet:contracts/MandateManager.sol
```

That is deliberately not a renumbering. Almost every one of those passages is describing
v1's live, verified behaviour — `evidence/README.md` is annotating real testnet receipts —
so v1 line numbers are the *correct* pointers, not stale ones. Renumbering to v2 would
make them wrong about their own subject and wrong again after the next commit. Where a v2
line is meant, the text says so; and new references should prefer a function name over a
number, because a name does not move.

If you ever need to restore `lib/` from scratch — a corrupted checkout, say — the exact
version is:

```
git clone --depth 1 --branch v1.16.2 https://github.com/foundry-rs/forge-std lib/forge-std
```

That tag resolved to commit `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` when the tree was
taken from it, which is the provenance `scope.md` records. Re-cloning the same tag and
diffing against `lib/` is how an auditor checks that nothing local was edited in.

The suite assumes **forge-std >= 1.9**, where the assertion helpers are `pure` and can
therefore be called from `view` test and invariant functions. On an older forge-std the
failures are compile errors of the form *"function declared as view, but this expression
modifies state"*, and the fix is either to upgrade or to delete the `view` keyword from
the handful of functions that carry it.

`solc 0.8.28` is pinned in `foundry.toml`. Foundry downloads it automatically; if that
is blocked, `svm install 0.8.28` or drop `solc_version` and loosen the pragma.

## Running

```
forge test                        # everything, default profile
forge test --summary              # per-file pass counts
forge test -vvv                   # traces for failures only
forge test --match-path 'test/Windows.t.sol'
forge test --match-test 'test_ATTACK'
forge test --gas-report           # run 2026-08-24; see DESIGN.md for the table
FOUNDRY_PROFILE=deep forge test   # 20k fuzz runs, 2000 invariant runs, depth 256
forge lint                        # run 2026-09-02; expect 0 — see the section below
```

The default profile is tuned to finish while you watch it. The deep profile is the
pre-audit setting and takes minutes.

**The deep profile was run on 2026-08-25 at 140 tests: 140 passed, 0 failed, 0 skipped,
exit 0, in 15m51.857s wall.** Full output including the config dump is `evidence/deep.log`.
**It was re-run on 2026-09-03 at 276 tests against forge-std 1.16.2: 276 passed, 0 failed,
0 skipped, exit 0, in 11m48.298s wall** — `evidence/deep-v2.log`. **Again on 2026-09-04
at 278 tests: 278 passed, 0 failed, 0 skipped, exit 0, in 10m50.560s wall** —
`evidence/deep-v3.log`. **And on 2026-09-05 at 320 tests, after F51 added the payer-nominated
revoker: 320 passed, 0 failed, 0 skipped, exit 0, in 9m21.166s wall** — `evidence/deep-v4.log`,
which is the gate in force. Each supersedes the one before it without replacing it, since the
first is the campaign the deployed v1 bytecode was cleared by. Every
later run beats the 140-test one despite carrying twice the tests or more; `deep-v3.log`
accounts for its own margin over `deep-v2.log`, `deep-v4.log` records a further 87.70s margin
it cannot account for, and the earliest gap still stands as an open question.
What each run bought, in calls rather than runs: each of the three `invariant_` functions in
`WindowInvariant.t.sol` ran 2,000 sequences of 256 handler calls, so 512,000 calls apiece
and 1,536,000 in total, against 16,384 apiece under the default profile. That budget is
fixed, so the fourth handler move added in the third run took a quarter of it rather than
adding to it: spend attempts per invariant fell from 341,447 to 256,473, and
`deep-v3.log`'s header sets the figure out beside the reason it was accepted. F51 added tests
without adding a handler move, so that share held: `deep-v4.log` reports 255,639, the
difference being the random selector draw rather than a further claim on the budget. Each of the four
`testFuzz_` functions in `WindowFuzz.t.sol` ran 20,000 cases instead of 512. Nothing new
was found — no counterexample, no shrink, no revert that the policy did not intend. The
only line in the log matching `panic` is the name of a test that asserts a panic.

Note the invocation. It is written above as `FOUNDRY_PROFILE=deep forge test` rather than
`forge test --profile deep`, and the reason is a failure mode this repo has now been bitten
by three times. Twice it was silent: a flag or glob that Foundry does not accept can fail
with no error, leaving you reading a run that used the default settings while looking like
success. The third time, on 2026-09-03, it was this flag — the installed Foundry answers
`error: unexpected argument '--profile' found` and runs nothing at all, which inside a
multi-line paste is indistinguishable from a command that printed no output. The env-var
form is the one guaranteed across versions. Whichever you use, put `forge config`
in front of it and check that `runs = 20000` and `depth = 256` actually come back — that
dump is the first thing in `evidence/deep.log` for exactly this reason. Do not infer that
the deep profile was live from the fact that the run took a long time.

Two timing figures for planning, and they disagree, so use the right one. `time` measured
`user 81m27.476s, sys 0m3.112s` against `real 15m51.857s`, which is about 5.1× parallelism.
Foundry's own self-reported aggregate is lower, 4124.55s (68m45s), because it sums per-test
time and does not account for compilation or its own overhead. By Foundry's accounting the
load is wildly lopsided: `WindowFuzz` 1,757s and `WindowInvariant` 2,086s, which is 93% of
its total between two files, while every other suite finished in milliseconds. If the deep
profile ever needs to be faster, those two files are the only ones worth looking at.

Two commands are worth running before believing any of the rest:

```
forge test --match-test test_flagConstants_matchTheContract
forge test --match-test test_handlerCanActuallySpend_soTheInvariantsAreNotVacuous
```

The first catches the failure mode where the test suite's mirrored flag constants drift
from the contract's, which would leave every flag-dependent test passing while asserting
against the wrong bit. The second catches the classic stateful-fuzzing lie: a handler
that fails on every call with no error satisfies every invariant, and the run reports
success having tested nothing.

## Layout

```
test/Base.t.sol            harness: mocks, actors, params builders, denial helpers
test/Creation.t.sol        56  grant-time validation — every way a mandate is refused
test/Bounds.t.sol          32  per-tx, lifetime, allowlist, spender, time, revocation
test/Revoker.t.sol         42  the payer's nominated revoker, and all it cannot touch
test/Windows.t.sol         20  the rolling-window ring, by hand, with the boundary probes
test/Gates.t.sol           26  ERC-8004 identity and credential gates
test/Cosign.t.sol          66  what a co-signature actually commits to
test/Idempotency.t.sol     13  nonce replay, and that a denial consumes nothing
test/Views.t.sol           28  the pre-flight views an agent decides on
test/WindowFuzz.t.sol       4  exact-ledger property tests, bounded loops
test/WindowInvariant.t.sol  7  the same property, fuzzed sequences, and a stray donation
test/ArcParity.t.sol        4  matched local control for the real Arc Testnet transactions
test/Deploy.t.sol          22  script/Deploy.s.sol: the chain pin, the probes, a bad wiring
test/mocks/                    USDC with Arc's failure modes; the two registries
```

The column sums to 320, which is the check worth running on it: a suite count swept in the
prose above and not here leaves a table that disagrees with its own headline. On 2026-09-02
this file still said 225 throughout, table included, so the column agreed with the headline
while both were stale against the suite, which is the version of the problem that reads as
correct. Getting from 225 to 254 moved four cells: `Creation` 44 → 56, `Cosign` 53 → 66,
`Gates` 24 → 26, `Views` 26 → 28. Reaching 276 took a whole row instead, added when the
deploy script stopped being the one file in the repository with no coverage at all. Reaching
278 moved one cell, `WindowInvariant` 5 → 7, on the day the claim that this contract never
holds funds acquired a handler move able to falsify it. Reaching 320 took another whole row,
`Revoker` at 42, when the payer gained a nominee able to revoke on their behalf.

Twenty-seven of the 320 are named attack simulations, with `ATTACK` in the function name, and
fifteen of those sit in `Revoker.t.sol`, where a third party able to revoke had to be shown
unable to do anything else. Three are regressions (`test_REGRESSION_*`) — one for a bug that
shipped into the model, two for the self-comparing
read-back that shipped in the deploy script — and three pin behaviour that is deliberately
weaker or stranger than a reader would assume (`test_DOCUMENTED_*`).

**`forge test` prints `Ran 15 test suites`, and the arithmetic reconciling that count with
thirteen files is as follows.** Forge counts *contracts with test functions*, not files.
Thirteen files hold eighteen non-abstract contracts; `ArcParity.t.sol` alone declares four,
one per measured transaction, because each needs cold storage. Subtract the three that
declare no test functions of their own — `WindowHandler`, a fuzzing handler, and
`Token18` and `TransposedRun` in `Deploy.t.sol` — and you get 15. `Base.t.sol` and
`ArcParityBase` are `abstract` and contribute nothing. In total: 13 files, 15 suites, 320
tests, and all three numbers are correct at the same time.

## What this proves that the JavaScript model cannot

Four properties are structural to the EVM and cannot be demonstrated in a model, only
imitated by one.

**A denial consumes nothing.** The contract writes the nonce and commits window buckets
*before* calling the token, and correctness comes from the whole transaction unwinding
when the transfer fails. `Idempotency.t.sol` blocklists the recipient mid-flight, drains
the allowance, empties the balance, and makes the token return `false` instead of
reverting — then asserts the nonce is still free, the window still has full headroom,
and a retry succeeds. A JS model can only split evaluate from commit and hope the split
is faithful.

**Storage aliasing in the ring.** With K+1 slots, a spend K+1 sub-periods later lands on
the same physical slot as an old one. `test_ATTACK_rewindOntoTheSameRingSlot_accumulatesRatherThanOverwrites`
proves the slot accumulates rather than overwrites — a distinction that exists only
because the ring is a real mapping and not a JavaScript array of every timestamp.

**Packed-struct arithmetic.** `totalSpent` is a `uint96`, and the model's integers are
arbitrary-precision, so the model cannot have this class of bug or find it. In v1 the contract
computed `m.totalSpent + uint96(amount)` unconditionally, *before* the `F_TOTAL` check, so the
addition was evaluated even for a mandate with no lifetime cap at all, and a cumulative total
near 2^96 base units — roughly 7.9e22 USDC — produced an arithmetic **panic** rather than a
denial, which `test_totalSpent_nearTwoToTheNinetySix_panicsRatherThanWrapping` pinned
exactly, using `stdError.arithmeticError`.

**v2 fixed it, so neither that test nor that import exists in this tree.** The lifetime cap is
now consulted without performing the addition (`totalSpent > totalCap - amount`, whose first
clause proves its own subtraction cannot underflow), and the counter itself is guarded by a
named `TotalSpentCeiling()`.
The two replacement tests are `test_totalSpent_atTheUint96Ceiling_deniesWithANameNotAPanic` and
`test_totalSpent_withMaximumLifetimeCap_deniesWithOverTotalCap` — the second pinning that
the ceiling guard is *unreachable* once `F_TOTAL` is set, because a lifetime cap is itself
a `uint96` and therefore binds first. The reachability boundary is what these tests pin;
the panic was only ever the symptom.

The point survives the fix, and is in fact sharpened by it: **the model could not express a
panic, which is how this divergence stayed invisible.** Closing it meant giving the model a
`TOTAL_SPENT_CEILING` denial it had no reason to invent on its own — the width of an EVM integer
leaking into a specification that has no widths.

**A ceiling that lives outside every mandate.** NEW WITH v2's `spendableAcross`. The model has
no token, so it cannot hold the fact that matters most about several mandates at once: they draw
on one ERC-20 allowance, which belongs to neither of them. `reference/policy.js` can compute the
policy half — `headroomAcross` sums each mandate's largest single spend and refuses mixed
payers and duplicate ids — and that is all a specification of *policy* can say, because the
allowance is not policy. It is the reason two mandates on Arc each reported 90,000 against
an allowance of 90,000. `Views.t.sol` closes the gap by asserting both halves in the same
test: that `spendable(a) + spendable(b)` is 180,000 and that `spendableAcross([a, b])` is 90,000,
against a real `MockUSDC` whose approval a real payer can change without touching this contract
at all. Note the shape this shares with the packed-struct case above — in both, the thing the
model cannot represent is the thing the contract has to be careful about, and in both the model
still had to be extended so the halves it *can* check cannot drift.

One asymmetry inside that is deliberate rather than drift: `MAX_JOINT = 8` is in the
contract and **not** in the model, unlike `MAX_WINDOWS`, `MAX_BUCKETS` and `MAX_AMOUNT`.
The rule is that a bound constraining the state machine gets mirrored, because it changes
which mandates can exist and therefore which spends are legal, whereas a bound that only
rations a **read** has nothing downstream depending on it. `MAX_JOINT` exists to keep 139
cold storage reads per mandate inside one call's gas budget, and JavaScript has no gas
budget.

The exact-ledger property tests are the crown of the port. `WindowFuzz.t.sol` records
every accepted spend and brute-forces the true trailing window after each step, asserting
both that no interval of length L exceeds the cap *and* that the ring never counts less
than the exact window — the second being the direction that would constitute a bypass
rather than mere stinginess. `WindowInvariant.t.sol` checks the same property with the
fuzzer choosing the call sequence, which reaches states a written loop does not.

## What the first compile found

Recorded because the predictions below were mostly wrong, which the reader needs before
trusting the rest of this section. On 2026-08-23 the project compiled for the first
time. Three things stood between it and `solc`, and none of them were on the list.

`foundry.toml` had `[profile deep]` with a space instead of a dot, which is a TOML
parse error and stops Foundry before it looks at any Solidity at all.

`reference` is a Solidity **reserved keyword** — reserved for future use, so it parses
as a keyword and not as an identifier — and it was the name of the fifth field of
`event Spend`, its matching `spend()` parameter, and the corresponding entry in the hash
preimage. Renamed to `ref` in six places in the contract and five in `reference/policy.js`
so the two keep identical names. This does not change any `spendHash`: only field order and
values are hashed, and both are unchanged.

`WindowFuzz.t.sol` hit **Stack too deep** in the legacy code generator. Nothing was
wrong with it; each of its replay functions simply kept eighteen to twenty-one values
alive at once, and legacy codegen can only reach sixteen slots down the EVM stack. The
fix was to box the loop state into one `Run` memory struct and move the oracle into a
shared helper, so the frame holds a pointer instead of a dozen scalars. `via_ir = true`
would also have fixed it, and was rejected deliberately: it would have changed how the
*contract* compiles in the same commit that first established the contract compiles at
all, and it costs minutes per build. If a future test does this again, prefer the struct.

The contract itself produced no errors, and the build now generates code for it too, so
it is past both the type checker and the code generator. Every construct the section
below flagged as suspect turned out to be fine: the `try/catch` destructuring of
`getValidationStatus` matched on arity and ordering, the nested `calldata` struct
encoded correctly, the memory-returning views compiled, and the `abi.encodeCall` type
strictness in the tests caught nothing because the casts were already explicit.

## What the first run found

On 2026-08-24 the suite ran for the first time: 125 passed, 4 failed. All four failures
were in the tests. That is the direction you want, but it is also the direction that
flatters the contract, so each of the four is set out precisely below.

Two were the same mistake. `vm.prank(x)` applies to the *next call*, and Solidity
evaluates arguments before the outer call — so `mm.approveCosign(id, mm.spendHash(...))`
spends the prank on `spendHash`, and `approveCosign` then arrives from the test contract,
which is not the cosigner. Both failed with `NotCosigner()`, several lines away from the
cause. The fix is to hoist the inner call into a local before the prank; `Base.payReverts`
exists to contain exactly this hazard, and the same trap applies inside a
`vm.expectRevert(...)` argument list.

*The hazard outlived the example.* That expression no longer compiles: #28 deleted
`approveCosign` and narrowed `spendHash` to five parameters. Written against the current
contract the same mistake is `mm.approveCosignFor(id, to, amt, ref, nonce, deadline)` with any
nested `mm.spendHash(...)` in the argument list, or the more tempting shape now that
`approveCosignFor` **returns** the hash — pranking one call and then using its return value in
a second call that also needs the prank. The rule is unchanged and does not depend on the
signature: **one `vm.prank` covers one call, and an argument that is itself a call goes first.**
The example above is kept as what actually happened on 2026-08-24 rather than repaired, because
the run it describes is v1's.

One was arithmetic in a comment that did not match the code. A `cosignThreshold` of 10
with a spend of 20 described as "under the threshold" — the threshold had to sit between
10 and 20 for the test's point to hold, and it was raised to 25 rather than shrinking the
spend, because the window cap needed that first spend above 10.

The fourth is the interesting one. A test asserted, via `vm.recordLogs()`, that a `Spend`
event emitted just before a reverting `transferFrom` leaves no log behind. That is true
of the chain and false of the recorder: `recordLogs` captures events at emit time and
does not model the EVM discarding them as a frame unwinds. The assertion was therefore
unanswerable rather than merely wrong — it was making a false claim about Foundry, not a
true one about Remit. It was replaced with the observable form of the same property:
nothing was consumed, nothing moved, the nonce is still free, and the identical spend
then settles exactly once.

Before reading an invariant report, note that `reverts: 0` on all three invariants is
correct rather than a sign the fuzzer never tripped anything. `WindowHandler` wraps each
attempt in a low-level call and tallies refusals in `handler.refusals()`, so a policy
denial is counted rather than propagated. Non-vacuity is established separately, by the
two guard tests named under "Running".

## What `forge lint` found, and why 91 warnings became seven annotations

`forge build` had been ending with *"Compiler run successful with warnings"* since the
first compile, and the warnings were left alone on the reasonable-sounding grounds that
they were lint suggestions rather than errors. On 2026-08-24 they were actually read.
There were **91**, not the five this document's author remembered: 5 in
`contracts/MandateManager.sol` and 86 across the test tree.

The gap between the remembered number and the real one is the useful part. Warnings you
have decided to ignore stop being read, and a count you carry in your head instead of in
a file drifts. `forge lint` is now a clean check rather than a stream — it should print
nothing and exit 0 — so a single new warning is visible instead of arriving into noise.
The decision that got it there is written down below rather than left as a habit. (The
working `*.log` captures from that session are gitignored and local; the numbers that
matter are in this document.)

**The contract's seven are annotated individually, in place.** The 2026-08-24 run produced
five of them, v2 added the sixth, and F45's past-expiry guard added the seventh. They are
three `unsafe-typecast` and four `block-timestamp`, each with a
`// forge-lint: disable-next-line(...)` pragma sitting under
a comment that gives the actual reason:

The two `uint96(amount)` casts — one in `spend`, one in `approveCosignFor` — cannot truncate
since `amount` is bounded by an unconditional `AmountTooLarge` guard that runs before any
policy check, and the comment beside each says explicitly that moving that guard behind a
flag makes the cast unsound, because a caller could then pass `2^96` and have it wrap to
`0`, spending nothing against the caps while the transfer moves the full amount. Both sat in
`spend` in v1, and the cosign approval surface v2 added carries the second one now.

The `uint64(nowTs / w.subLength)` cast in `_checkAndCommitWindows` is bounded above by
`block.timestamp` itself, since `subLength` is at least 1; `uint64` saturates around
584 billion years.

The four `block.timestamp` reads get the longest justification, because the lint's
objection — a proposer can nudge the clock — is answered structurally rather than
avoided. They sit in `createMandate`, `isCosignApproved`, `_isPermanentlyDead` and `isLive`;
v1 carried two and both were inside `isLive`, so a reader working from an older copy of this
section will look in the wrong place. Nothing in any of the four *grants* capacity from a
timestamp: window accounting deliberately has no upper bound on bucket index, so a clock
moved forward cannot age out live history and refill a cap (that was a real bug, and it is
now a named regression test), and a clock moved backwards can only make `isLive` return
false, which refuses spends. The payer's actual remedy, `revoke`, never consults the clock
at all.

The fourth, F45's `p.expiresAt <= block.timestamp` in `createMandate`, decides which refusal
the payer reads rather than whether a spend can happen. A clock a few seconds behind lets a
born-dead grant be written, and `spend` then refuses it on the same field; a clock a few
seconds ahead refuses a grant with a moment of life left, and the payer re-issues under
another salt.

Those seven are the first questions an auditor asks, and this is a contract that is meant
to hold real money, so the answers belong beside the code.

**The 86 in `test/` are excluded as a class**, via `[lint] ignore = ["**/*.t.sol"]` in
`foundry.toml`. Seventy-six of them are `bytes32("some literal")`, which forge-lint flags
as a potentially-truncating conversion. It cannot truncate: `solc` rejects the conversion
outright if the literal exceeds 32 bytes, so the check has already happened at compile
time and no runtime value is involved. One more is `uint256(x)` where `x` is a `uint96` —
a *widening* cast, which is arguably a forge-lint bug. Suppressing 76 provably impossible
cases one line at a time would be noise pretending to be rigour, and noise is precisely
how a real finding hides six months later.

**That glob is empirical, and the obvious spelling does nothing, with no error to say so.**
Read this before editing it. Measured by swapping the one line and re-running, against a
baseline of 85:

| `ignore` pattern | warnings left |
| --- | --- |
| `**/*.t.sol` | **0** — what we use |
| `test/**` | 85 — the spelling anyone writes first |
| `**/test/**` | 85 |
| `*.t.sol` | 85 — a single `*` does not cross `/` |
| `test` | 85 |
| `test/Views.t.sol` | 65 — so exact relative paths do match |

Matching is against the path relative to the project root, `*` stops at a path separator,
and a leading `**/` is required to reach into a directory. The trap is that a pattern
matching nothing fails with no error *and* `forge config` echoes it straight back at
you, so the exclusion looks applied when it is not. Check the warning count, never the
config dump.

Two further notes apply to anyone repeating that measurement.
`forge lint --config-path <file>` is not the way to test candidates: it demands the file be
named exactly `foundry.toml` and **panics with a backtrace** if it is not, which exits
non-zero, emits no warnings, and therefore looks exactly like a pattern that worked. Swap
`foundry.toml` in place instead. Include a control pattern that must come back non-zero —
`test/Views.t.sol → 65` is what proved the harness was sound, and its absence is what made
a first attempt at this report five identical crashes misread as five successes.

The pattern deliberately covers test *files* rather than the test *directory*, so
`test/mocks/` stays linted. `MockUSDC` reproduces Arc's real failure modes and is
source-like, and the false-positive class that motivates the exclusion lives in the
`.t.sol` files.

**The remaining ten were read rather than waved through, and three were real.**

`usd()` — the whole-USDC-to-6-decimals helper — computed `whole * ONE` in `uint256` and
narrowed the result to `uint96` with no bound. It was safe only *by current usage*: every
call site passes a literal, the largest being 5000. The failure mode it was one edit away
from is the bad kind, because it is silent — a test meaning to spend *over* a cap would
have truncated to a small amount and passed. It now carries a `require`, so the first
person to write `usd(fuzzInput)` gets a failure instead of a false green.

`assertRevertedWith` was marked non-`pure` with a comment explaining that `assertEq` logs
on failure. That was true of older forge-std; at 1.9.6, and still at 1.16.2, the assertions
route through `vm.assertEq` and are themselves `pure`, and `solc` emits Warning (2018)
saying so. The comment had outlived the fact it described, which is worse than no comment.
Now `pure`, with the history recorded.

Three helpers in `Base.t.sol` — `micro`, `payAs`, `balanceOfVendor` — were defined and
never called once. `micro`'s doc comment claimed it was "used to probe boundaries", which
was not true of this codebase. All three are deleted, since a harness documenting
behaviour that no test exercises will mislead its next reader.

One warning class was checked and left alone on its own merits: `uint8(buckets)` indexes
a fixed six-element array `{2,3,4,6,12,24}` with `idx % 6`, so it is safe by construction.
`uint96(room)` in a view was initially suspected of being safe only if the contract's cap
invariant holds — the very thing the test checks, which would have been circular.
Reading `windowRemaining` settled it: the return is `used >= w.cap ? 0 :
w.cap - used` and `w.cap` is a `uint96` field, so the result is either zero or strictly
less than a `uint96`, which holds from the *types* regardless of whether the cap logic is
correct. That earned a written reason rather than a defensive `assert` that would have
done nothing.

**What this sweep did not do.** It did not find a bug in the contract. Everything real
came out of the test harness, which is the same pattern as the first compile and the
first run — three passes now, and all the defects have been on the verification side.
That is reassuring about the contract and it is also exactly what you would expect from a
codebase whose contract has been read many times and whose harness has been read once.

### The 2026-08-30 re-run, and what a silent clean run proves on its own

`forge lint` on the v2 tree printed one line — `No files changed, compilation skipped` — and
nothing else. **A run that read the source and found nothing is byte-identical to a run that
read no source at all**, so that output certifies nothing by itself. It is the same trap the
glob table above records in its other form, and it takes the same answer: a control that has
to come back non-zero.

The control was `contracts/LintProbe.sol`, a throwaway file carrying four deliberate
violations — a constant named `lowerCaseConst`, a function named `Mixed_Case`, an unbounded
`uint64(x)`, and `(a / b) * 1e18`. It went inside `contracts/` on purpose, because
`src = "contracts"` makes that unambiguously the same source set as the contract; a probe
placed outside `src` could be skipped for being out of scope and would reproduce the silence
it exists to break. With the probe present the same bare invocation
reported `warning[divide-before-multiply]` and `warning[unsafe-typecast]` against it.
Removing the probe returned the 38-byte clean line. The file is untracked and was deleted
in the same paste that read it.

**Linting is independent of compiling, and that independence is what makes the clean result
usable.** Running the probe a second time against a warm cache printed `No files changed,
compilation skipped` *and* both warnings. Had the warnings vanished, every clean run in this
repo would have been an artefact of `out/` being up to date rather than a statement about
the code.

**The clean result is a claim about default severity, and the note class beneath it is not
empty.** `forge lint --severity info` returns twelve notes in real repo code, and every one
of them is a naming or file-layout convention rather than a defect:

| lint | where | count |
| --- | --- | --- |
| `multi-contract-file` | `MandateManager.sol` :147, :156, :164, :200 | 4 |
| `screaming-snake-case-immutable` | `MandateManager.sol` :211, :216, :220 | 3 |
| `screaming-snake-case-const` | `MockUSDC.sol` :52, :53, :54 | 3 |
| `multi-contract-file` | `MockRegistries.sol` :16, :74 | 2 |

`multi-contract-file` objects to the four declarations in one file, which is the zero-import
single-file design chosen on purpose and described under Layout; splitting the three
interfaces into their own files would add the imports that design exists to avoid. The three
`MockUSDC` constants are `name`, `symbol` and `decimals`, whose names ERC-20 fixes, so
renaming them to satisfy a style note would break the standard the mock exists to imitate.
The three immutables are `usdc`, `identityRegistry` and `validationRegistry`, each `public`.
The rename was measured against the repo rather than argued, and it is declined. The
measurement is recorded here so the reasoning can be checked instead of taken on trust.

Two of the costs expected of it turned out to be absent. Nothing breaks structurally: no
interface in the repo declares any of the three getters, and each getter has exactly one
call site, all three inside `script/Deploy.s.sol:148-150`. The rename also leaves every line
number where it stands, because `usdc` and `USDC` are the same width, so the two longest
reference lines at 111 columns do not move, and `identityRegistry` and `validationRegistry`
grow by one column each on the two `BadConfig` guards at 99 and 103. Line citations keep
resolving, since the lines hold still, though three need re-reading: the note table above
cites the three declarations by number, and the rename rewrites the text at each, so
`line-citations.py` would report three drifted rows until the table is read again. The ABI
argument an earlier draft of this section gave does not survive the same treatment: v1 is
testnet-only with no third-party integrator, and IMMUTABILITY.md records that there is no
upgrade path, so a v2 deploy reaches a fresh address that a caller has to point at
deliberately, reading the new ABI when it does.

The cost that decides the question is a token collision. The contract's comments and NatSpec
use `USDC` for the asset 40 times; `usdc` appears 12 times and always means the identifier;
and `USDC` as a word appears 125 times across the seven published documents. One `grep`
separates the two referents today, and the rename merges them, in a repo whose verification
is substantially textual — `line-citations.py`, `fact-diff.py`, `prose-check.py`,
`vacuity-check.py` and every published count read the source as text.

Two smaller findings finish the case against it. The convention's payload is already carried
by the `immutable` keyword on the declaration and by the absence of any setter, so capitals
would add emphasis rather than information. Renaming only the two registries, which carry no
collision, is worse than either alternative, since three sibling immutables in one
declaration block would then follow two naming schemes while
`screaming-snake-case-immutable` still fired on `usdc`. What remains is 21 contract lines and
3 call sites edited in a contract that moves money, for an `info`-severity style note with no
security effect, so the rename is declined as of 2026-08-30.

### The 2026-09-02 re-run, and how long a clean result stays true

The next `forge lint` after that one happened four commits later, and it reported a
warning: `block-timestamp` on `p.expiresAt <= block.timestamp` inside `createMandate`.
The line arrived with F45 in `9b701ee` on 2026-09-01 as the contract's seventh
`block.timestamp` comparison, and it was the only one of the seven with no
`disable-next-line` pragma beside it. It now has one, with its reason written above it in
the form the other six use, and the default-severity result is clean again.

Nothing about the 2026-08-30 method was wrong, and the logs from that session hold up: the
probe control fired, the warm-cache run proved linting runs independently of compiling, and
`lint-final.log`'s single line was a real clean tree rather than a lost stream — the sibling
captures in that same session carry full `warning[...]` blocks, so stderr was being read all
along, and what went stale was the result rather than the method. Three commits between
`9b701ee` and `6b1e4d7` each ran the tests and the formatter without running the linter, so a
warning introduced on 2026-09-01 first appeared in a log on 2026-09-02.

The rule that follows is worth more than the annotation: a clean checker log dates from the
run, and a code change after it revives every question that run answered. The four
`forge lint` captures in this repo that hold one line each are all older than `9b701ee`, so
each was accurate when written. Run the linter in the same paste as the tests, and a
comparison of counts against this section will catch the next one on the day it lands.

## What the first compile was predicted to find

Kept as a record of a prediction that was wrong. None of these were known-broken; they
were the constructs most likely to be wrong in code no compiler had read. All of them
have now cleared both the compiler and the suite, which is the useful part of keeping the
list: the things that actually broke were a TOML typo, a reserved word, and a stack
frame, and none of the three appear below.

The `try/catch` around `getValidationStatus` destructures six return values, one of them
a `string memory`, so the arity or the ordering might not have matched. Next,
`MandateParams` is an external `calldata` parameter carrying a nested dynamic array plus
nested structs, which is legal but easy to get wrong. The external views returning
`Mandate memory` and `WindowSpec memory` were also on the list, as was event-signature
drift: `vm.expectEmit` comparisons encode `MandateCreated` with nine parameters and `Spend`
with eight, and a mismatch there surfaces as a failing assertion rather than a compile
error — which is why only `forge test` could ever have spoken to it.

In the tests specifically, `abi.encodeCall` type strictness was the suspicion — it
type-checks against the real signature, so a `uint96` where the function takes `uint256`
is a compile error rather than a widening. Every call site casts explicitly for that
reason. And `bytes memory` cannot be cast to `bytes4`, which is why `Base.selectorOf`
uses assembly; if a new comparison is added inline it will still fail.

## When a test fails, which side is wrong

Usually the contract is the wrong side. Five tests, however, pin behaviour a reader is
likely to mistake for a bug, so a failure there may mean a later edit has helpfully
"fixed" something deliberate; all five are labelled in-file.

Three of them were places the contract was right and `reference/policy.js` was wrong.
Writing the Forge suite is what surfaced them, and the model has since been reconciled,
so both sides now agree and a failure is a real regression rather than a known gap. The
spender is permitted to call `revoke`, not only the payer — and v1's error was named
`NotPayer`, which is misleading and was pinned as-is because the name was in the deployed
ABI. v2 renames it `NotAuthorised` (selector `0x1435e357` → `0x1648fd01`); the tag
`v1.0.0-arc-testnet` pins v1's ABI at v1's address, which is what retired the objection.
`maxStaleness == 0` means *no* freshness requirement rather than *maximum* strictness:
the right reading of "maximum permitted age", and also the value a caller leaves in a
struct field they never thought about. And `amount > 2^96-1` is refused with
`AmountTooLarge` *before* any cap is consulted, because every cap is a packed `uint96`
and an unchecked downcast would truncate a huge amount into a small one that passes.

The other two are not divergences — the model and the contract agree, and both were
arguably wrong together, which is the interesting part: no amount of cross-checking two
implementations against each other can find a hole they share. `perTxCap < cosignThreshold`
makes the co-signature branch unreachable, so the policy never asks for a signature, and
v1's `createMandate` accepts the configuration anyway. **v2 refuses it, in
both implementations**, and the condition is not the one written here: it is `<=` rather
than `<`, and it compares against `min(2^96 - 1, perTxCap, totalCap, every window cap)`
rather than against `perTxCap` alone. Fixing it properly meant enumerating the whole
question — how many ways are there to display a co-signature requirement without having
one? — which produced two further holes that neither implementation refused and no document
listed: a threshold stored with `F_COSIGN` unset, and a mandate whose cosigner is its own
spender, which lets the agent approve its own spends.

The remaining one: with `F_CREDENTIAL` set, `credential.agentId == 0`, and no identity gate,
there is no agent id to compare against, so the wrong-agent check is skipped entirely —
bounded only by the fact that the payer fixes `requestHash` at grant time. That one is still
recorded in DESIGN.md rather than fixed, because the fix is a grant-time refusal that would
reject configurations a payer may want. Note that this was the reasoning offered for both,
and for the cosign case it did not survive contact with the real-money decision: a grant
that appears to carry a control it does not carry is not a configuration any payer wants.

That second one has a footnote to read before touching `_checkCredential`. Writing
the DESIGN.md caveat for it turned up a model divergence that no test had caught: the
model resolved the expected agent with `??`, which treats `0` as a real value, so
`agentId: 0n` meant "require the attestation to be about agent 0" while the contract's
`c.agentId != 0` falls through to the identity gate. On-chain there is no null, so zero is
the only spelling of "unset" and the contract's reading is the one that governs. Both
sides now agree, and the model has a test for it.

Auditing the rest of the zero-means-unset fields on the strength of that found five more,
and this time the Forge suite was already right about all five — `Creation.t.sol` asserts
each of them, and the model simply lacked the check. A window with `cap == 0`, an
`expiresAt` at or before `notBefore`, the zero address on an allowlist, a credential with
no validator, and `minResponse == 0`. The last is the one to remember, because it is not
a loosening: ERC-8004 encodes failure as a *low* response and 100 as passing, so a zero
threshold turns the credential check into one that accepts exactly the attestations it
exists to reject; `test_createMandate_credentialWithZeroMinResponse_reverts` is the test
that would have caught it on a first run, and did not get the chance.

One general shape carries into the audit: every `uint` field whose zero doubles as
"unset" is a place a model with real nulls can disagree with the bytecode without a test
failing, and a place a client encoder can disagree with both.
