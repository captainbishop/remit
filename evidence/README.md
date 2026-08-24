# Evidence

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

Two caveats on reading them. First, `forge --gas-report` figures are
**execution-only** and exclude the 21,000-gas intrinsic floor plus calldata cost,
so a gas-report column and a receipt's `gasUsed` are never directly comparable —
`gas.log` proves this on its own face by listing `spendHash` at 1,003 gas, which
no transaction can cost. Second, the fuzz seed is not pinned, so Median and Avg
columns are not comparable between two runs; compare the Min column.

Everything below is against `MandateManager` at
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

## Gas, and the optimizer decision

| File | What it establishes |
|---|---|
| `gas.log` | The full gas report at `optimizer_runs = 200`. Also the incidental proof that gas reports are execution-only: `spendHash` at 1,003 gas. |
| `gas-10000.log` | The same tree built at `optimizer_runs = 10000`. Six gas saved on a spend for 27% more bytecode — the measurement behind the decision to stay at 200, recorded in full in `foundry.toml`. |
| `marginal-a.log` | The steady-state marginal spend, **177,429 gas**, measured inside one already-written window bucket. This replaced the published ~142,500, which had wrongly compared a first-ever spend against a bare transfer. |
| `approve.log`, `approve-lo.log` | ERC-20 `approve` receipts, including the 38,338 reset and the ~17,100 virgin-slot premium. |
| `parity.log` | The first three harness-versus-receipt parity measurements: `createMandate`, `approve`, `spend`. |
| `cosign-parity.log` | The `approveCosign` parity measurement and the A/B cold-surcharge isolation. A = 36,231 all cold, B = 25,634 warm but for the target slot, A−B = **10,597** against a predicted 8,500. Landing *above* the prediction is what ruled out the possibility that Foundry carries warmth from `setUp` into the test body. The 2,097 excess is one unattributed cold-slot delta and is still open. |

`parity.log` and `cosign-parity.log` together are why the published USDC premium
figures of 17,100 and 32,700 should be treated as **unsound**. Both USDC-free
operations overshoot the real receipt and both USDC-touching ones undershoot it,
and the two USDC-free overshoots differ from each other in proportion to how much
state each touches — 6,337 for `createMandate` against 2,505 for `approveCosign`.
The premiums were derived by treating the first of those as a flat calibration
constant. It is not constant.

## Live mandates and spends

| File | What it establishes |
|---|---|
| `create.log` | Mandate 1 granted. Caps 500,000 per tx / 2,000,000 total, one 24-bucket rolling window, allowlist of one vendor, flags 75. |
| `preflight.log`, `postflight.log` | State either side of the first live spend — `isLive`, `policyHeadroom`, `spendable`, and the vendor balance landing exactly on the requested amount. |
| `spend.log` | The first live spend receipt. |
| `fund.log` | Funding the delegate so it could pay its own gas, which on Arc is USDC. |
| `headroom.log` | `policyHeadroom` and `spendable` agreeing with the per-transaction cap. Confirms `spendable()` does traverse the rolling window rather than ignoring it. |
| `ceiling.log`, `race.log`, `restore.log`, `restored.log` | The allowance-ceiling failure shape. With the allowance at 90,000, **two** mandates each reported `spendable` = 90,000 — summing to 180,000 — and 50,000 dry-runs succeeded on both. No funds are at risk, because the losing `transferFrom` reverts, but per-mandate policy layered over one global ERC-20 allowance is silent about the joint constraint. This is the measurement behind the proposed `spendableAcross` view. |
| `ref-spend.log`, `ref-after.log` | Spend #4, carrying `ref` as a commitment rather than a plaintext label: `keccak256(abi.encode(invoiceId, poNumber, amountMinor, vendor, salt))`. Two independent implementations produced the same digest. This is layer L0 in `PRIVACY.md`, and it costs zero extra gas. |

## Cosignature

| File | What it establishes |
|---|---|
| `cosign-create.log` | Mandate 2, with a cosigner set and a 50,000 threshold, flags 79. |
| `cosign-dry.log` | Mandate 2 as actually stored, read back from storage rather than from the event. |
| `cosign-approve.log` | The `approveCosign` receipt: **53,114 gas**. `DESIGN.md` had published `approveCosign max = 53,114` from a mock gas report, and the identical digits looked like the harness working perfectly. It is a coincidence between two figures measured 22,088 gas apart in basis. |
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

## Toolchain

| File | What it establishes |
|---|---|
| `test140.log` | 140 tests passing across 13 suites. |
| `lint.log` | The 91 `forge lint` warnings, 5 in the contract and 86 in the tests, as they stood when the split documented in `foundry.toml` was decided. Regenerable in principle, kept because any change to the contract stops it reproducing — at which point this is the only record of the state that comment describes. |
