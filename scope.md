# Audit scope

The material an auditor is being asked to read is listed below, together with the
material excluded from that request. Every count here comes from the tree at the commit
named in the next line; if that line is stale, the counts are too.

**Anchored at `58ef048` on branch `main`.** The deployed release is the annotated tag
`v1.0.0-arc-testnet`; `main` is v2 in progress and does not reproduce the deployed
bytecode. A scope statement tied to "the current tree" expires without anyone noticing;
re-derive these numbers against whatever commit is handed over.

## In scope

The in-scope code is one file, 2,764 lines, **17,888 bytes of runtime bytecode**
(initcode 18,370), leaving 6,688 bytes under the EIP-170 limit.

That figure describes the tree named above rather than the deployed contract, and it comes
from the `forge build --sizes` run recorded in `evidence/sizes-v2.log`, made on 2026-09-05
against the same warm `out/` the 320-test campaign in `evidence/deep-v4.log` used, so it
measures the bytecode those tests exercised. Deployed v1 is 11,572 bytes, confirmed by its
own on-chain code length, and that is the number most of this repo's other documents quote.
v2 is 6,316 bytes larger than what is deployed. The co-signature rework and `spendableAcross`
are the bulk of that, with `clearReservation` and the payer-nominated revoker the most recent
additions; the split between them has never been measured, so read the total rather than any
share of it. If a document quotes 11,572 without saying which release it means, it means v1.

| File | What it is |
|---|---|
| `contracts/MandateManager.sol` | The whole system. 39 custom errors, 7 events, no imports, no inheritance, no owner. |

There is nothing else in `contracts/`. The contract declares the three interfaces it
needs inline at lines 147, 156 and 164 rather than importing them, so the file is
self-contained and can be read start to finish without following a dependency.

## Supporting files outside the contract

| File | Why it is here |
|---|---|
| `test/mocks/MockUSDC.sol` (132 lines) | Stands in for Arc's native USDC. It reproduces failure modes rather than idealising them, so what it does and does not model is part of what the suite proves. |
| `test/mocks/MockRegistries.sol` (156 lines) | Stands in for the two ERC-8004 registries. `ownerOf` reverts for a nonexistent id, matching ERC-721, which is the behaviour the credential gate is written against. |
| `script/Deploy.s.sol` | Pins the three constructor arguments per chain and reads all three back after deploying. Not deployed code, but a mistake here becomes immutable. `test/Deploy.t.sol` exercises every check it makes. |

## Out of scope

- `test/` — 13 `.t.sol` files, 320 tests.
- `lib/forge-std/` — forge-std 1.16.2, vendored as 68 tracked files. Test-only;
  `grep -rc forge-std contracts/` returns 0, so none of it reaches deployed bytecode.
  It is vendored rather than submoduled, so the upstream commit is recorded here instead
  of in a `.gitmodules`: tag `v1.16.2`, commit
  `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b`. The tree was taken from a clone of that tag
  rather than diffed against it afterwards, so an auditor who wants byte-equality should
  re-clone the tag with the recipe in `FORGE.md` and diff the 68 files themselves.
- `reference/` — a JavaScript model of the policy (`policy.js`), its 112-test suite, and
  two mutation-testing scripts. The model exists to cross-check the contract, and the
  two have disagreed twice in ways that mattered, so it is useful context. It is not
  deployed and it holds nothing.

## Chains

| Chain | Chain id | Status |
|---|---|---|
| Arc Testnet | 5042002 | Deployed and verified at `0x3744E93B9e796E05CB66311d897559B6F3860196`, 31 transactions of live use recorded under `evidence/`. |
| Arc mainnet | not yet published | The intended target. `script/Deploy.s.sol` has no entry for it and will refuse to deploy there until one is added deliberately. |

The chain id is part of the replay argument: it is hashed into every spend hash alongside
`DOMAIN` and the contract address, so a co-signature produced for one chain cannot be
replayed on another or against a second deployment on the same chain.

## Entry points

Seven functions change state, and everything else reads.

| Function | Who may call it | What it does |
|---|---|---|
| `createMandate` | anyone, on their own behalf | Grants a mandate. `msg.sender` becomes the payer. 31 refusals guard the parameter set. |
| `spend` | the named spender | Moves `amount` USDC from payer to recipient via `transferFrom`. The one function that moves money. |
| `revoke` | the payer, the spender, or the revoker the payer named | Kills a mandate permanently, and with it every outstanding co-sign approval, since `spend` refuses a revoked mandate before it looks at anything else. The spender is allowed to revoke so a delegate can hand authority back. The nominated revoker is allowed so that the escape does not depend on the payer still being able to afford it, which is F51's whole reason. |
| `setRevoker` | the payer | Names or removes that third party, at grant time through `MandateParams.revoker` or afterwards through this function. `address(0)` removes. It refuses the contract, the payer and the spender, and it cannot reach a revoked mandate. Nominating gives away exactly one power, revocation, and the adversarial tests are the record of that. |
| `approveCosignFor` | the cosigner | Pre-approves one exact spend hash, with a deadline. |
| `withdrawCosign` | the cosigner | Cancels an approval before it is used. The payer cannot cancel one directly; revoking the mandate is the payer's route. |
| `clearReservation` | the payer | Releases the nonce a co-sign approval reserved, so a later spend can use it. The approval itself is left in place, which is what separates this from `withdrawCosign`. |

The contract exposes fifteen view functions, plus getters for `usdc`, `identityRegistry`,
`validationRegistry` and `DOMAIN`. The two an integrator is most likely to build on are
`spendable` and `spendableAcross`, and `spendableAcross` is the only place in the
contract where an error reports a badly formed question rather than a refused action.

The constructor takes three addresses and refuses only a zero USDC. A zero registry is a
valid configuration that disables the ERC-8004 credential check.

## Features deliberately omitted

The absences below remove whole classes of finding, so an auditor should not spend time
looking for them.

The contract has no owner, admin, role, pause, or upgrade path, and no `payable`,
`receive`, or `fallback`, so it cannot hold or move native value. It takes no custody of
USDC at any point: the payer's funds stay in the payer's wallet and a spend is
`transferFrom(payer → recipient)`, which means `approve(mandateManager, 0)` is a hard
stop the payer controls unilaterally. There is no proxy, no storage gaps and no
initialiser, and no `require`: every refusal is a named custom error.

The cost of that shape is that nothing can be fixed after deployment. `IMMUTABILITY.md`
is the document about what that means for a payer.

## Related documents

| Question | File |
|---|---|
| What is this and why | `README.md` |
| Design decisions and the arguments behind them | `DESIGN.md` |
| Trust assumptions, threat model, 51 recorded findings, 25 invariants | `THREAT-MODEL.md` |
| What immutability costs and what recourse a payer has | `IMMUTABILITY.md` |
| Test and tooling conventions, compiler settings | `FORGE.md` |
| Live transactions, gas measurements, verification output | `evidence/` |

`THREAT-MODEL.md` is the one to read first. Its finding register lists what is known to be
wrong or unresolved, including the items still open, and §5 names the tests it still owes.

## No prior audit

This has not been audited. There is no previous report to read and no fixed-finding list
to re-check. A security contact and disclosure channel are recorded as an open gap in
`IMMUTABILITY.md` and must exist before any third party is invited to grant a mandate.
