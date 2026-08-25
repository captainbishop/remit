# Running the Forge suite

140 tests across eleven files — which `forge test` reports as **13 suites**, for reasons
worked through under Layout — verifying `contracts/MandateManager.sol` against the real EVM:
packed structs, the bucket ring in actual storage mappings, and transactional rollback. This
is the port of `reference/policy.test.js`, which has 46 tests and verifies the *policy*.
Both matter, and they are not redundant — the section on what Solidity can prove that
JavaScript cannot is below.

**Status: all 140 pass, and `forge lint` is clean.** First compiled and first run on
2026-08-24, under `solc` 0.8.28
with the optimizer at 200 runs, in about twelve seconds. That covers 2,048 fuzz runs across
the four property tests and 49,152 calls across the three stateful invariants. What the
first compile and the first run each cost is recorded below, because a suite's first green
is the only time you learn whether it was testing anything.

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

It also carries the two most useful lessons in this file, both in comments. The header
records that it silently measured the wrong thing on its first version, passed every
assertion while doing so, and reported an `approve` costing 3,185 gas when the SSTORE
alone is 20,000. The comment above `ArcParityApproveCosignTest` records something more
uncomfortable, added on 2026-08-25: **this harness was less accurate than the tool it was
built to check.** Its `gasleft()` figure for `approveCosign` overstates real execution by
about 5,205 gas, while `forge test --gas-report` — which includes intrinsic gas for
state-changing functions, the fact the whole episode turned on — reproduces four Arc
receipts to the gas with no adjustment at all. The superseded reasoning is kept inside
delimiters in that comment rather than deleted, because the reasoning failure is worth
more than the number. The closing section of `DESIGN.md` has the full argument.

This document used to open by warning that none of it had ever been compiled. That is no
longer true, and the sections that were written as predictions are now labelled as such
rather than deleted — a wrong prediction about where code breaks is more useful kept than
tidied away.

## Setup

forge-std 1.9.6 is **vendored into `lib/` and tracked in this repository**, so there is
nothing to install beyond Foundry itself. From the project root:

```
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge build
```

Those are bash commands. On Windows they belong in WSL rather than PowerShell, and
`START-HERE.md` has the step-by-step for setting that up.

Vendoring is deliberate, and the reason is reproducibility rather than convenience.
Every gas figure in `DESIGN.md` and all 140 tests are properties of these exact bytes
compiled by solc 0.8.28 at `optimizer_runs = 200`, and the deployment at
`0x3744E93B9e796E05CB66311d897559B6F3860196` is verified on-chain against them.
Re-resolving the dependency — whether by `forge install`, a submodule, or a fresh clone
of a moving branch — risks silently fetching different bytes and invalidating the whole
baseline. `forge install` is the idiomatic route and was considered; it wants a git
repository, manages submodules, and the flag controlling whether it commits has changed
across Foundry versions. `libs = ["lib"]` in `foundry.toml` makes the `forge-std/`
remapping resolve either way.

The cost, stated plainly: `forge update` will fight this, and the diff on any future
forge-std bump will be large. Bump deliberately, in its own commit, and re-run the full
suite plus `forge test --profile deep` afterwards.

If you ever need to restore `lib/` from scratch — a corrupted checkout, say — the exact
version is:

```
git clone --depth 1 --branch v1.9.6 https://github.com/foundry-rs/forge-std lib/forge-std
```

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
forge lint                        # run 2026-08-24; expect 0 — see the section below
```

The default profile is tuned to finish while you watch it. The deep profile is the
pre-audit setting and takes minutes.

**The deep gate was run on 2026-08-25 and it passes: 140 passed, 0 failed, 0 skipped,
exit 0, in 15m51.857s wall.** Full output including the config dump is
`evidence/deep.log`. What that actually bought, stated in calls rather than in runs: each
of the three `invariant_` functions in `WindowInvariant.t.sol` ran 2,000 sequences of 256
handler calls, so 512,000 calls apiece and 1,536,000 in total, against 16,384 apiece under
the default profile. Each of the four `testFuzz_` functions in `WindowFuzz.t.sol` ran
20,000 cases instead of 512. Nothing new was found — no counterexample, no shrink, no
revert that the policy did not intend. The only line in the log matching `panic` is the
name of a test that asserts a panic.

Note the invocation. It is written above as `FOUNDRY_PROFILE=deep forge test` rather than
`forge test --profile deep`, and the reason is a failure mode this repo has already been
bitten by twice: a flag or glob that Foundry does not accept can fail *quietly* and leave
you reading a run that used the default settings while looking like success. The env-var
form is the one guaranteed across versions. Whichever you use, put `forge config` in front
of it and check that `runs = 20000` and `depth = 256` actually come back — that dump is the
first thing in `evidence/deep.log` for exactly this reason. Do not infer that the deep
profile was live from the fact that the run took a long time.

Two timing figures for planning, and they disagree, so use the right one. `time` measured
`user 81m27.476s, sys 0m3.112s` against `real 15m51.857s`, which is about 5.1× parallelism.
Foundry's own self-reported aggregate is lower, 4124.55s (68m45s), because it sums per-test
time and does not account for compilation or its own overhead. By Foundry's accounting the
load is wildly lopsided: `WindowFuzz` 1,757s and `WindowInvariant` 2,086s, which is 93% of
its total between two files, while every other suite finished in milliseconds. If the deep
gate ever needs to be faster, those two files are the only ones worth looking at.

Two commands are worth running before believing any of the rest:

```
forge test --match-test test_flagConstants_matchTheContract
forge test --match-test test_handlerCanActuallySpend_soTheInvariantsAreNotVacuous
```

The first catches the failure mode where the test suite's mirrored flag constants drift
from the contract's, which would leave every flag-dependent test passing while asserting
against the wrong bit. The second catches the classic stateful-fuzzing lie: a handler
that silently fails on every call satisfies every invariant, and the run reports success
having tested nothing.

## Layout

```
test/Base.t.sol            harness: mocks, actors, params builders, denial helpers
test/Creation.t.sol        26  grant-time validation — every way a mandate is refused
test/Bounds.t.sol          25  per-tx, lifetime, allowlist, spender, time, revocation
test/Windows.t.sol         14  the rolling-window ring, by hand, with the boundary probes
test/Gates.t.sol           18  ERC-8004 identity and credential gates
test/Cosign.t.sol          17  what a co-signature actually commits to
test/Idempotency.t.sol     13  nonce replay, and that a denial consumes nothing
test/Views.t.sol           14  the pre-flight views an agent decides on
test/WindowFuzz.t.sol       4  exact-ledger property tests, bounded loops
test/WindowInvariant.t.sol  5  the same property, with the fuzzer choosing the sequence
test/ArcParity.t.sol        4  matched local control for the real Arc Testnet transactions
test/mocks/                    USDC with Arc's failure modes; the two registries
```

Nine of the 140 are named attack simulations (`test_ATTACK_*`), one is a regression for
a bug that shipped into the model (`test_REGRESSION_*`), and four pin behaviour that is
deliberately weaker or stranger than a reader would assume (`test_DOCUMENTED_*`).

**`forge test` prints `Ran 13 test suites`, and the arithmetic is worth writing down once
so the number never looks wrong.** Forge counts *contracts with test functions*, not files.
Eleven files hold fourteen non-abstract contracts; `ArcParity.t.sol` alone declares four,
one per measured transaction, because each needs cold storage. Subtract `WindowHandler` —
non-abstract but a fuzzing handler with no test functions of its own — and you get 13.
`Base.t.sol` and `ArcParityBase` are `abstract` and contribute nothing. So: 11 files,
13 suites, 140 tests, and all three numbers are correct at the same time.

## What this proves that the JavaScript model cannot

Three properties are structural to the EVM and cannot be demonstrated in a model, only
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

**Packed-struct arithmetic.** `totalSpent` is a `uint96` and `m.totalSpent + uint96(amount)`
is computed unconditionally, before the `F_TOTAL` check. `test_totalSpent_nearTwoToTheNinetySix_panicsRatherThanWrapping`
pins the resulting liveness cliff at roughly 7.9e22 USDC using `stdError.arithmeticError`.
The model has arbitrary-precision integers and cannot have this bug, or find it.

The exact-ledger property tests are the crown of the port. `WindowFuzz.t.sol` records
every accepted spend and brute-forces the true trailing window after each step, asserting
both that no interval of length L exceeds the cap *and* that the ring never counts less
than the exact window — the second being the direction that would constitute a bypass
rather than mere stinginess. `WindowInvariant.t.sol` checks the same property with the
fuzzer choosing the call sequence, which reaches states a written loop does not.

## What the first compile actually found

Recorded because the predictions below were mostly wrong, which is worth knowing before
trusting the rest of this section. On 2026-08-23 the project compiled for the first
time. Three things stood between it and `solc`, and none of them were on the list.

`foundry.toml` had `[profile deep]` with a space instead of a dot, which is a TOML
parse error and stops Foundry before it looks at any Solidity at all.

`reference` is a Solidity **reserved keyword** — reserved for future use, so it parses
as a keyword and not as an identifier — and it was the name of the fifth field of
`event Spend`, its matching `spend()` parameter, and the corresponding entry in the hash
preimage. Renamed to `ref` in six places in the contract and five in `reference/policy.js`
so the two keep identical names. This does not change any `spendHash`: only field order
and values are hashed, and both are unchanged.

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

## What the first run actually found

On 2026-08-24 the suite ran for the first time: 125 passed, 4 failed. All four failures
were in the tests. That is the direction you want, but it is also the direction that
flatters the contract, so it is worth being precise about what each one was.

Two were the same mistake. `vm.prank(x)` applies to the *next call*, and Solidity
evaluates arguments before the outer call — so `mm.approveCosign(id, mm.spendHash(...))`
spends the prank on `spendHash`, and `approveCosign` then arrives from the test contract,
which is not the cosigner. Both failed with `NotCosigner()`, several lines away from the
cause. The fix is to hoist the inner call into a local before the prank; `Base.payReverts`
exists to contain exactly this hazard, and the same trap applies inside a
`vm.expectRevert(...)` argument list.

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

Also worth knowing before you read an invariant report: `reverts: 0` on all three
invariants is correct, not a sign the fuzzer never tripped anything. `WindowHandler`
wraps each attempt in a low-level call and tallies refusals in `handler.refusals()`, so a
policy denial is counted rather than propagated. Non-vacuity is established separately,
by the two guard tests named under "Running".

## What `forge lint` found, and why 91 warnings became five annotations

`forge build` had been ending with *"Compiler run successful with warnings"* since the
first compile, and the warnings were left alone on the reasonable-sounding grounds that
they were lint suggestions rather than errors. On 2026-08-24 they were actually read.
There were **91**, not the five this document's author remembered: 5 in
`contracts/MandateManager.sol` and 86 across the test tree.

The gap between the remembered number and the real one is the useful part. Warnings you
have decided to ignore stop being read, and a count you carry in your head instead of in
a file drifts. `forge lint` is now a clean gate rather than a stream — it should print
nothing and exit 0 — so a single new warning is visible instead of arriving into noise.
The decision that got it there is written down below rather than left as a habit. (The
working `*.log` captures from that session are gitignored and local; the numbers that
matter are in this document.)

**The contract's five are annotated individually, in place.** Three `unsafe-typecast`
and two `block-timestamp`, each with a `// forge-lint: disable-next-line(...)` pragma
sitting under a comment that gives the actual reason:

The two `uint96(amount)` casts in `spend` cannot truncate because `amount` is bounded by
an unconditional `AmountTooLarge` guard that runs before any policy check — and the
comment says explicitly that moving that guard behind a flag makes both casts unsound,
because a caller could then pass `2^96` and have it wrap to `0`, spending nothing against
the caps while the transfer moves the full amount.

The `uint64(nowTs / w.subLength)` cast in `_checkAndCommitWindows` is bounded above by
`block.timestamp` itself, since `subLength` is at least 1; `uint64` saturates around
584 billion years.

The two `block.timestamp` reads in `isLive` get the longest justification, because the
lint's objection — a proposer can nudge the clock — is answered structurally rather than
avoided. Nothing in that function *grants* capacity from a timestamp: window accounting
deliberately has no upper bound on bucket index, so a clock moved forward cannot age out
live history and refill a cap (that was a real bug, and it is now a named regression
test), and a clock moved backwards can only make `isLive` return false, which refuses
spends. The payer's actual remedy, `revoke`, never consults the clock at all.

Those five are the first questions an auditor asks, and this is a contract that is meant
to hold real money, so the answers belong beside the code.

**The 86 in `test/` are excluded as a class**, via `[lint] ignore = ["**/*.t.sol"]` in
`foundry.toml`. Seventy-six of them are `bytes32("some literal")`, which forge-lint flags
as a potentially-truncating conversion. It cannot truncate: `solc` rejects the conversion
outright if the literal exceeds 32 bytes, so the check has already happened at compile
time and no runtime value is involved. One more is `uint256(x)` where `x` is a `uint96` —
a *widening* cast, which is arguably a forge-lint bug. Suppressing 76 provably impossible
cases one line at a time would be noise pretending to be rigour, and noise is precisely
how a real finding hides six months later.

**That glob is empirical, and the obvious spelling silently does nothing.** Worth knowing
before editing it. Measured by swapping the one line and re-running, against a baseline of
85:

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
matching nothing fails silently *and* `forge config` echoes it straight back at you, so
the exclusion looks applied when it isn't. Check the warning count, never the config dump.

Two further notes for anyone repeating that measurement. `forge lint --config-path <file>`
is not the way to test candidates: it demands the file be named exactly `foundry.toml` and
**panics with a backtrace** if it isn't, which exits non-zero, emits no warnings, and
therefore looks exactly like a pattern that worked. Swap `foundry.toml` in place instead.
And include a control pattern that must come back non-zero — `test/Views.t.sol → 65` is
what proved the harness was sound, and its absence is what made a first attempt at this
report five identical crashes misread as five successes.

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
on failure. That was true of older forge-std; at 1.9.6 the assertions route through
`vm.assertEq` and are themselves `pure`, and `solc` emits Warning (2018) saying so. The
comment had outlived the fact it described, which is worse than no comment. Now `pure`,
with the history recorded.

Three helpers in `Base.t.sol` — `micro`, `payAs`, `balanceOfVendor` — were defined and
never called once. `micro`'s doc comment claimed it was "used to probe boundaries", which
was not true of this codebase. All three are deleted. A harness that documents behaviour
nobody exercises is a harness that will mislead somebody.

One warning class was checked and left alone on its own merits: `uint8(buckets)` indexes
a fixed six-element array `{2,3,4,6,12,24}` with `idx % 6`, so it is safe by
construction. And `uint96(room)` in a view was initially suspected of being safe only if
the contract's cap invariant holds — the very thing the test checks, which would have
been circular. Reading `windowRemaining` settled it: the return is `used >= w.cap ? 0 :
w.cap - used` and `w.cap` is a `uint96` field, so the result is either zero or strictly
less than a `uint96`, which holds from the *types* regardless of whether the cap logic is
correct. That earned a written reason rather than a defensive `assert` that would have
done nothing.

**What this sweep did not do.** It did not find a bug in the contract. Everything real
came out of the test harness, which is the same pattern as the first compile and the
first run — three passes now, and all the defects have been on the verification side.
That is reassuring about the contract and it is also exactly what you would expect from a
codebase whose contract has been read many times and whose harness has been read once.

## What the first compile was predicted to find

Kept as a record of a prediction that was wrong. None of these were known-broken; they
were the constructs most likely to be wrong in code no compiler had read. All of them
have now cleared both the compiler and the suite, which is the useful part of keeping the
list: the things that actually broke were a TOML typo, a reserved word, and a stack
frame, and none of the three appear below.

The `try/catch` around `getValidationStatus` destructures six return values, one of them
a `string memory`, so the arity or the ordering might not have matched. Next,
`MandateParams` is an external `calldata` parameter carrying a nested dynamic array plus
nested structs, which is legal but easy to get wrong. Then the external views returning
`Mandate memory` and `WindowSpec memory`. Then event-signature drift: `vm.expectEmit`
comparisons encode `MandateCreated` with nine parameters and `Spend` with eight, and a
mismatch there surfaces as a failing assertion rather than a compile error — which is why
only `forge test` could ever have spoken to it.

In the tests specifically, `abi.encodeCall` type strictness was the suspicion — it
type-checks against the real signature, so a `uint96` where the function takes `uint256`
is a compile error rather than a widening. Every call site casts explicitly for that
reason. And `bytes memory` cannot be cast to `bytes4`, which is why `Base.selectorOf`
uses assembly; if a new comparison is added inline it will still fail.

## When a test fails, which side is wrong

Usually the contract. But five tests pin behaviour a reader is likely to mistake for a
bug, so a failure there may mean somebody helpfully "fixed" something deliberate. All
five are labelled in-file.

Three of them were places the contract was right and `reference/policy.js` was wrong.
Writing the Forge suite is what surfaced them, and the model has since been reconciled,
so both sides now agree and a failure is a real regression rather than a known gap. The
spender is permitted to call `revoke`, not only the payer — and the error is still named
`NotPayer`, which is misleading and pinned as-is because the name is in the deployed ABI.
`maxStaleness == 0` means *no* freshness requirement rather than *maximum* strictness:
the right reading of "maximum permitted age", and also the value a caller leaves in a
struct field they never thought about. And `amount > 2^96-1` is refused with
`AmountTooLarge` *before* any cap is consulted, because every cap is a packed `uint96`
and an unchecked downcast would truncate a huge amount into a small one that passes.

The other two are not divergences — the model and the contract agree, and both are
arguably wrong together. `perTxCap < cosignThreshold` makes the co-signature branch
unreachable, so the policy silently never asks for a signature, and `createMandate`
accepts the configuration anyway. And with `F_CREDENTIAL` set, `credential.agentId == 0`,
and no identity gate, there is no agent id to compare against, so the wrong-agent check
is skipped entirely — bounded only by the fact that the payer fixes `requestHash` at
grant time. Both are recorded in DESIGN.md rather than fixed, because the fix in each
case is a grant-time refusal that would reject configurations somebody may want.

That second one has a footnote worth reading before touching `_checkCredential`. Writing
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
threshold turns the credential gate into one that accepts exactly the attestations it
exists to reject. `test_createMandate_credentialWithZeroMinResponse_reverts` is the test
that would have caught it on a first run, and did not get the chance.

The general shape is worth carrying into the audit: every `uint` field whose zero doubles
as "unset" is a place a model with real nulls will quietly disagree with the bytecode, and
a place a client encoder will quietly disagree with both.
