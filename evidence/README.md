# Evidence

> *Line numbers into `contracts/MandateManager.sol` in this document refer to the **tagged
> v1 source** — `git show v1.0.0-arc-testnet:contracts/MandateManager.sol` — and here that is
> not merely a convention but the only correct reading: every receipt in this folder was
> produced by v1's bytecode, so v1's source is the thing being annotated. v2 work has shifted
> the working tree's numbering; see FORGE.md.*

Every number published in `DESIGN.md`, `CHANGELIST.md`, `PRIVACY.md`, `FORGE.md`
and the comment block in `foundry.toml` was measured, not estimated. This folder
is the raw output those numbers came from, kept so that a reader — or an auditor —
can check a claim against the thing that produced it rather than taking it on
trust.

It is curated. Five files were deliberately left out because they are compiler and
CLI chatter that regenerates identically on demand and records no unique
observation: `build.log`, `create-help.log`, `test.log`, `testcount.log`,
`pre-deploy.log`. Everything kept here is either a receipt from Arc Testnet, a
state read against the live deployment, or a measurement that a document quotes.

Two caveats on reading them. First, `forge --gas-report` treats the two kinds of
call differently, and getting this backwards cost this project a published
conclusion. For **state-changing** functions the figures are transaction-equivalent:
they include the 21,000-gas intrinsic floor plus per-calldata-byte cost, so a row is
directly comparable to a receipt's `gasUsed`, and three of them have now been
reproduced against Arc to the gas. For **views** the figures are execution-only,
which is why `gas.log` lists `spendHash` at 1,003 gas — no transaction can cost
that, and a `staticcall` inside a test is not a transaction. Second, `gas.log` **is**
now generated at a pinned `--fuzz-seed 5042002`, and pinning it is necessary but not
sufficient: three runs at the same seed against the same bytecode still produced three
different tables. What the seed pins is `# Calls`, `Max` in every row, and `Min` in 48
of 49; `Avg` and both `Median` columns never reproduce. So compare **Min, Max and
`# Calls`** — never `Avg` or `Median` — and read `gas.log`'s own header before comparing
it against anything.

That caveat said "the fuzz seed is not pinned … compare the Min column" until
2026-08-26, which had been false since the regeneration in `1f19221` and was
contradicted by this file's own entry for `gas.log` two screens below. Same failure as
`DESIGN.md` stating a guard at line 1011 and refuting it at 1272: the correction landed
where the work happened and not in the summary at the top.

Unless a row names a different contract, everything below is against `MandateManager` at
`0x3744E93B9e796E05CB66311d897559B6F3860196`, Arc Testnet, chain 5042002.
Transaction hashes in these files remain independently checkable at
`https://testnet.arcscan.app` regardless of this repository.

## Deployment and verification

| File | What it establishes |
|---|---|
| `deploy-check.log` | On-chain code length **11,572 bytes**, and the three constructor immutables as actually stored. This is what corrected the long-published 11,964 figure, which matched neither the runtime nor the initcode column. |
| `verify.log` | `forge build --sizes` (11,572 runtime / 11,868 initcode) and the Blockscout source verification. |
| `create-calldata.txt` | The exact `createMandate` calldata for mandate 1, selector `0x9ab253da`. |
| `expected-id.txt` | The mandate ID predicted off-chain *before* sending. Matching the on-chain result is what proves the `keccak256(DOMAIN, chainid, address(this), msg.sender, salt)` derivation was understood correctly rather than reverse-engineered afterwards. |

## Arc's own behaviour, verified by observation rather than from the docs

| File | What it establishes |
|---|---|
| `arc-probe.log` | chain-id 5042002, USDC decimals 6, symbol `"USDC"`. |
| `arc-probe2.log` | Raw bytecode of the ERC-8004 identity registry, read before trusting any interface against it. |
| `arc-probe3.log` | The live attestation at `requestHash = 0`: validator `0xb152c3b6…`, agentId 16330, response **1**, tag **`"verified"`**, `lastUpdate` 1779177483. A real on-chain attestation tagged "verified" that is simultaneously a *failure* (Arc's own tutorial says 100 = passed) and 97 days stale. The contract reads the number and ignores the tag. |
| `rounding.log` | Arc debits exact 18-decimal wei while `balanceOf` **truncates** to 6 decimals. Three competing rounding models were refuted here; the truncating one was already documented correctly at `MandateManager.sol:856-863`. |
| `registry.log` | Our delegate's identity-registry `balanceOf` is **0**, and agent 16330 belongs to `0x2F061aA5…`, not to us. This is why the identity gate blocked the genuine impersonation case rather than a missing-token case — and why its positive path stays untestable without a mint. |
| `entrypoint.log` | **ERC-4337 EntryPoint v0.7 is live on Arc Testnet at `0x0000000071727De22E5E9d8BAf0edAc6f37da032`**, established by prediction rather than by presence. Arc's docs say to verify the address before use, and `cast code` showing 16,035 bytes there proves only that *a* contract is deployed. So `userophash.py` derived what v0.7 must answer for `getUserOpHash` on an all-zero `PackedUserOperation` — `0x07f96d30…c930` — and the chain returned exactly that, all 32 bytes. The value commits to the EntryPoint address and the chain ID, so the same bytecode elsewhere could not produce it, and the selector `0x22cdde4c` is v0.7's `PackedUserOperation` rather than v0.6's `UserOperation` at `0xa6193531`. What it proves is that the hashing path is v0.7's, which is what signature compatibility depends on — not that all 16,035 bytes are byte-identical to the canonical release, which would need a reference codehash this tooling cannot fetch. |

## Gas, and the optimizer decision

| File | What it establishes |
|---|---|
| `gas.log` | The full gas report at `optimizer_runs = 200`, **regenerated 2026-08-25 with `--fuzz-seed 5042002`** — the committed version had never been rebuilt since the root commit and still ended "9 test suites, 136 tests", predating `ArcParity.t.sol`. Also, read correctly, the file that overturned task #31: its five state-changing minima all sit just above 21,000 plus their own calldata while all ten view minima sit far below it, so the state-changing figures are transaction-equivalent and the view figures are not. `spendHash` at 1,003 gas proves that about views only. The file's own header documents which of its columns survive a re-run and which do not — read that before comparing this file against anything. |
| `gas-10000.log` | The same tree built at `optimizer_runs = 10000`. Six gas saved on a spend for 27% more bytecode — the measurement behind the decision to stay at 200, recorded in full in `foundry.toml`. |
| `marginal-a.log` | The steady-state marginal spend, **177,429 gas**, measured inside one already-written window bucket. This replaced the published ~142,500, which had wrongly compared a first-ever spend against a bare transfer. |
| `approve.log`, `approve-lo.log` | ERC-20 `approve` receipts: **55,438** onto a virgin allowance slot and **38,338** onto a live one. The 17,100 difference is the EIP-2200 storage-class gap, *not* an Arc premium — it appears identically on a plain mock, as `premium.log` shows. Both receipts were later reproduced to the gas with a different spender and amount. |
| `premium-check.log` | The read-only pre-flight for the premium measurement, at block 58680613. Establishes the preconditions the comparison depends on: the vendor's USDC balance is non-zero (0.35), `allowance(payer → agent)` is exactly zero, and no allowance is `uint256.max`. Also re-confirms the 6-decimal truncation — a native balance of `18575004317000000000` reads as `18575004`. |
| `premium.log` | **The USDC premium, measured without a harness: 9,300 gas on an `approve`, 13,110 on a `transferFrom`.** `MockUSDC` deployed to Arc at `0x5949872a6fB7928bC5507d9D03D4b8078C233303`, then the same operation run against both tokens with byte-identical calldata so intrinsic gas cancels exactly. Nine transactions, all status 1. Contains the self-check that validates the method: A−C equals **17,100 on each token independently**, which is `SSTORE_SET − SSTORE_RESET` and therefore cancels. This log replaces the 17,100 / 32,700 figures published for weeks. |
| `parity.log` | The first three harness-versus-receipt parity measurements: `createMandate`, `approve`, `spend`. |
| `cosign-parity.log` | The `approveCosign` parity measurement and the A/B cold-surcharge isolation. A = 36,231 all cold, B = 25,634 warm but for the target slot, A−B = **10,597** against a predicted 8,500. Landing *above* the prediction is what ruled out the possibility that Foundry carries warmth from `setUp` into the test body. The 2,097 excess is one unattributed cold-slot delta and is still open. |

`parity.log` and `cosign-parity.log` together are why the published USDC premium
figures of 17,100 and 32,700 were **withdrawn**, and `premium.log` is what replaced
them. The originals were derived by treating `createMandate`'s −6,337 harness
deviation as a flat calibration constant and adding it to two operations that touch
far more state. It is not constant: both USDC-free operations overshoot the real
receipt and both USDC-touching ones undershoot it, and the two overshoots differ from
each other in proportion to how much state each touches — 6,337 for `createMandate`
against 2,505 for `approveCosign`.

Since 2026-08-25 there is a stronger statement available: **both of those deviations are
the harness being wrong, not Arc being expensive.** `gas.log`'s own `approveCosign` figure
matches the Arc receipt exactly, so there was never a 2,505-gas discrepancy needing an
explanation, and the 2,097 "unattributed cold-slot delta" left open in the
`cosign-parity.log` row above is harness error too. The bespoke harness was the least
accurate instrument used in this project and the accurate one was in the same folder.

Two things the replacement measurement established that the original method could not
have caught. The premium is **very nearly per-call, not per-slot**: `approve` costs the
same 9,300 whether it writes a virgin slot or overwrites a live one, and a
`transferFrom` touching three slots costs 13,110 rather than the ~27,900 a per-slot
model predicts. DESIGN.md previously stated the opposite and instructed re-derivers to
assume per-slot. And **17,100 was never a premium** — it is the storage-class gap,
identical on both tokens. The discarded route reached 10,757 + 6,337 = 17,094 and
rounded, landing six gas from a constant with nothing to do with Arc. That near-collision
is the reason this folder exists: arithmetic that lands on a famous number is a prompt
to re-derive, not a confirmation.

## Live mandates and spends

| File | What it establishes |
|---|---|
| `create.log` | Mandate 1 granted. Caps 500,000 per tx / 2,000,000 total, one 24-bucket rolling window, allowlist of one vendor, flags 75. |
| `preflight.log`, `postflight.log` | State either side of the first live spend — `isLive`, `policyHeadroom`, `spendable`, and the vendor balance landing exactly on the requested amount. |
| `spend.log` | The first live spend receipt. |
| `fund.log` | Funding the delegate so it could pay its own gas, which on Arc is USDC. |
| `headroom.log` | `policyHeadroom` and `spendable` agreeing with the per-transaction cap. Confirms `spendable()` does traverse the rolling window rather than ignoring it. |
| `ceiling.log`, `race.log`, `restore.log`, `restored.log` | The allowance-ceiling failure shape. With the allowance at 90,000, **two** mandates each reported `spendable` = 90,000 — summing to 180,000 — and 50,000 dry-runs succeeded on both. No funds are at risk, because the losing `transferFrom` reverts, but per-mandate policy layered over one global ERC-20 allowance is silent about the joint constraint. This is the measurement behind the `spendableAcross` view, which v1 does not have and v2 does: it returns 90,000 here where the two `spendable` calls sum to 180,000. |
| `ref-spend.log`, `ref-after.log` | Spend #4, carrying `ref` as a commitment rather than a plaintext label: `keccak256(abi.encode(invoiceId, poNumber, amountMinor, vendor, salt))`. Two independent implementations produced the same digest. This is layer L0 in `PRIVACY.md`. It costs **240 gas**, not zero: the digest `0x4fa8c8c1…077a` has no zero bytes, so its calldata word costs 32×16 = 512 against 272 for `"invoice-0002"` zero-padded. Padding is what makes short plaintext cheap. |

## Cosignature

| File | What it establishes |
|---|---|
| `cosign-create.log` | Mandate 2, with a cosigner set and a 50,000 threshold, flags 79. |
| `cosign-dry.log` | Mandate 2 as actually stored, read back from storage rather than from the event. |
| `cosign-approve.log` | The `approveCosign` receipt: **53,114 gas**. `DESIGN.md` had published `approveCosign max = 53,114` from a mock gas report, and the identical digits looked like the harness working perfectly. Task #31 concluded it was a coincidence between figures measured 22,088 gas apart in basis; **that conclusion was wrong and was reversed on 2026-08-25.** The gas report includes intrinsic gas for state-changing functions, so the two figures are on the same basis and the match is real — both reduce to 31,026 gas of execution. |
| `cosign-pre.log`, `cosign-post.log` | The approval live before the spend and consumed after it — single-use, as designed. |
| `cosign-spend.log` | The cosigned spend receipt. |
| `subthreshold.log` | A spend below the threshold succeeding without any cosignature, which is what makes the gate meaningful rather than merely present. |

## The ERC-8004 gates

| File | What it establishes |
|---|---|
| `gates-pre.log` | Both registries correctly wired on the deployed contract: identity `0x8004A818…`, validation `0x8004Cb1B…`. |
| `gates-dry.log` | Three gated mandate IDs predicted off-chain and confirmed by simulation before any gas was spent. |
| `gate-m3.log` | Mandate 3, identity gate, flags 25. `gasUsed` 127,834. |
| `gate-m4.log` | Mandate 4, credential gate with no staleness bound, flags 41. `gasUsed` 151,036. |
| `gate-m5.log` | Mandate 5, credential gate with an 86,400-second staleness bound. `gasUsed` 151,072. |
| `gates-test.log` | All three gates firing against Arc's live registries with their predicted selectors — `IdentityNotHeld()` `0x6eab756c`, `CredentialMissing()` `0x9e586322`, `CredentialStale()` `0xca36b069` — **and the ungated control on mandate 1 succeeding**. The control is what makes the three failures evidence rather than three unexplained reverts. |

## Revoke, the last untouched path (2026-08-25)

| File | What it establishes |
|---|---|
| `revoke-pre.log` | Eleven read-only checks before anything irreversible was sent. Establishes the pre-state (mandate 3 unrevoked, gate-blocked with `IdentityNotHeld()` `0x6eab756c`; mandate 4 with `CredentialMissing()` `0x9e586322`), the authorisation boundary (a third-party address gets `NotPayer()` `0x1435e357`; an ungranted id gets `UnknownMandate()` `0x473251f4`, so line 703 precedes 704 and existence is not leaked), and **that the agent may revoke its own mandate** — which corrected my reading of line 704 before the test was designed around the wrong claim. |
| `revoke.log` | The two real revocations. Payer revokes mandate 3, `gasUsed` **30,808**, tx `0x8e92bed6…`. Agent revokes mandate 4, `gasUsed` **32,945**, tx `0x12d905a4…`. Then the proof, which is a *changed selector*: both mandates now revert `Revoked()` **`0x44825a4b`** where they previously returned their gate errors, so line 444 short-circuits ahead of the gates at 473-474. Mandate 5 still returns `CredentialStale()` `0xca36b069` and mandate 1 still simulates a successful spend, which is what confines the change to the two intended mandates. `getMandate` shows `revoked` = 1 with every other field intact. |
| `revoke-post.log` | The redundant revoke, `gasUsed` **28,008**, tx `0xe1d054e9…` — exactly 2,800 below the first, which is `SSTORE_RESET` 2,900 less a no-op write of 100, and **`MandateRevoked` is re-emitted** because line 705 has no guard. Also the allowance pair that actually governs a spend: `allowance(payer, MandateManager)` = 1,650,000 per line 868, against an unrelated payer→agent approval of 100,000 that had made `spendable` look broken and did not. Plus `usdc()` = `0x3600…0000`, `balanceOf(payer)` = 18,547,508, and `isLive` false / false / true / true across mandates 3, 4, 1 and 5. |

All three revoke receipts reconcile to the byte: identical intrinsic gas of 21,576, and a
dispatch residual of **532 on both payer-path transactions** despite storage costs differing by
2,800, with the agent path's 569 exceeding it by exactly the 37 gas of the second address
comparison. The gap between the two signers is 2,137, of which 2,100 is one cold `SLOAD` the
payer's path never performs — **Solidity's `&&` short-circuit, visible in a gas receipt.**

## Cosignature closed, the gap it exposed (2026-08-25)

| File | What it establishes |
|---|---|
| `cosign-withdraw.log` | The full cosign loop on mandate 2, whose cosigner is the payer: a 60,000 dry-run reverts `CosignRequired(0x47c56daa…)`, `approveCosign` of that hash costs **53,102** (tx `0xd545ff0f…`), the dry-run now succeeds and returns the same hash, `withdrawCosign` of it costs **26,889** (tx `0x6515918e…`), the dry-run reverts `CosignRequired` again, and a `withdrawCosign` of a hash never approved costs **28,901** (tx `0x7e10b4bd…`) — **2,012 more, for 2,800 less work**. Also `approveCosign`'s second-ever live run reproducing the first to the unit once calldata is subtracted (31,026 gas of execution, both), the guard asymmetry on the unknown-mandate probe (`NotCosigner()` instead of `UnknownMandate()`), and `totalSpent` / `policyHeadroom` / `isLive` / the nonce all unchanged after the loop. |

That last pair is the receipt-level demonstration of a rule the gas chapter learned the hard
way: the standing `SSTORE` to an already-zero slot at 100 gas, with **no refund to collect**,
costs more net than clearing a real slot at 2,900 with 4,800 back from EIP-3529. The gap is
2,000, which is 4,800 − 2,800 exactly; the extra 12 on the receipt is calldata, one zero byte
in the real hash where the ghost has none. Two constant residuals also fall out — 929 under a
two-cold-`SLOAD` decomposition, 3,029 under a one-`SLOAD` one, and an impossible −1,171 under
a third — which is the point of the caveat in the design doc: two receipts differing in one
term cannot discriminate between decompositions, so the difference, not the model, is what is
claimed.

Two corrections arrived with this run. The transaction total is **31**, not 27: counting
distinct `transactionHash` values across this directory and pairing each with its target shows
MockUSDC's deployment was included in the old figure while `MandateManager`'s own was omitted
— both seen here, the second in `deploy-check.log` and the first in the deploy output of
`premium.log`. And the state-changing surface is **five** functions, not six: parsing every
declaration in the contract for `external` or `public` without `view` or `pure` gives
`createMandate`, `spend`, `revoke`, `approveCosign`, `withdrawCosign`, and the count beside
that list had been wrong for weeks. All five now have live transactions.

**Everything in this directory is v1 evidence, so every `approveCosign` in this file is correct
and must stay.** #28 deleted that function from the source tree and replaced it with
`approveCosignFor`; the receipts here were produced by v1's bytecode at
`0x3744E93B9e796E05CB66311d897559B6F3860196`, which still holds the old function and always
will. Two consequences. The parse described above returns `approveCosignFor` if you run it on
the working tree, so run it on `git show v1.0.0-arc-testnet:contracts/MandateManager.sol` to
reproduce the five names. And "all five now have live transactions" is true of v1 and **false of
v2** — four of v2's five paths have a receipt for the same signature, and the cosign approval
path has none.

A third correction came out of these logs a day later, and it reverses a published finding.
Compare each receipt above against the corresponding row of `gas.log`, subtracting each
transaction's own intrinsic cost from both:

| | `gas.log` | Arc receipt | execution, both |
|---|---|---|---|
| `revoke`, payer path | 30,808 | 30,808 | 9,232 |
| `revoke`, spender path | 32,945 | 32,945 | 11,369 |
| `approveCosign` | 53,114 | 53,102 | 31,026 |
| `withdrawCosign` | 26,901 | 26,889 | 4,813 |

Four exact agreements, with the twelve-gas receipt gaps accounted for by one zero calldata
byte. **A mock gas report and an Arc receipt for a function that touches no token are the same
number**, which is only possible if the report includes intrinsic gas — so the caveat at the
top of this file was wrong for state-changing functions, and task #31's "coincidence" was
never a coincidence. The practical upside: `forge test --gas-report` now predicts an Arc
receipt to the gas for anything that does not touch USDC, which is how v2's `createMandate`,
`revoke`, `approveCosign` and `withdrawCosign` costs can be known before deploying.

*Three of those four, strictly.* The agreement is a property of the *report* — it includes
intrinsic gas — so the method transfers to any function. The demonstration does not:
`approveCosign` is gone, and `approveCosignFor` encodes 196 calldata bytes against 68, takes an
extra cold SLOAD, computes an extra keccak and logs three data words instead of none. Its
gas-report row is a prediction with no receipt to check it against, and there will not be one
until v2 is deployed.

## Toolchain

| File | What it establishes |
|---|---|
| `test140.log` | 140 tests passing across 13 suites, under **plain `forge test`**. The qualifier matters: the same suite reported 139 passed / 1 failed under `--gas-report` until 2026-08-25, because tracing overhead lands inside a `gasleft()` window in `ArcParity.t.sol` and inverted an unsigned subtraction. `grep -c "| Function Name" test140.log` returns 0, which is how you can tell this run did not use the flag. |
| `deep.log` | **The pre-audit deep gate: 140 passed, 0 failed, exit 0, 15m51.857s wall.** Each of the three `invariant_` functions ran 2,000 sequences of 256 calls — 512,000 handler calls apiece, 1,536,000 in total, against 16,384 apiece by default — and each of the four `testFuzz_` functions ran 20,000 cases instead of 512. No counterexample, no shrink. The `forge config` dump at the top is the point of the file as much as the result is: it is what proves the deep profile was actually resolved, with `runs = 20000`, `depth = 256`, `shrink_run_limit = 20000` and `optimizer_runs = 200` matching the default profile. A gate that silently compiles different bytecode from the one being audited is not a gate. |
| `lint.log` | The 91 `forge lint` warnings, 5 in the contract and 86 in the tests, as they stood when the split documented in `foundry.toml` was decided. Regenerable in principle, kept because any change to the contract stops it reproducing — at which point this is the only record of the state that comment describes. |

**Two of these three files are the reason this folder exists rather than a sentence in a
README.** `test140.log` and `deep.log` both say "140 passed", and they are not
interchangeable: one is a 12-second smoke test and the other is a 16-minute campaign, and
only the second one is a claim you could put in front of an auditor. The distinction is
invisible in the pass count and visible only in the config dump and the wall clock.
