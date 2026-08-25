# Gas abstraction on Arc — what exists, and what it means for Remit

Research note for the gate `L3-VAULT.md` identified in front of both remaining privacy
layers. Task #5. Sourced entirely from Arc's own documentation via the arc-docs MCP; every
claim below cites the page it came from, and the section at the end lists what the docs do
**not** say, because that is as load-bearing as what they do.

**Headline: gas abstraction on Arc is not one mechanism but three, and the one that fits
Remit is the one I was not looking for.** Separately, this research turned up a documented
Arc feature that changes the privacy roadmap materially and was absent from every document
in this repository — see the last section, which is the most important part of this note.

## The three mechanisms Arc documents

| Path | What submits the transaction | `msg.sender` at the target | Status on Arc |
|---|---|---|---|
| **EIP-3009 relayer** | a funded relayer EOA | the **relayer**, not the user | live on testnet |
| **ERC-4337 paymaster** | a bundler, through EntryPoint v0.7 | the **smart account** | live; EntryPoint v0.7 verified on testnet, Pimlico is the documented bundler |
| **EIP-7702 set-code** | the EOA itself, with delegated code | the **EOA** | *"behaves as on Ethereum"* |

Sources: `/integrate/relayers-and-paymasters`, `/integrate/relayers-and-paymasters/eip-3009-relayer`,
`/integrate/relayers-and-paymasters/deploy-a-paymaster`, `/integrate/evm-differences`.

### EIP-3009 relayer — real, live, and wrong for Remit

Arc documents this fully, with working ethers v6 code. The user signs an EIP-712
`TransferWithAuthorization` off-chain; a relayer EOA submits it and pays gas from its own
USDC balance. USDC's domain on Arc testnet is `name: "USDC"`, `version: "2"`,
`chainId: 5042002`, `verifyingContract: 0x3600…0000`, and the authorization `nonce` is a
random `bytes32` rather than an account nonce — the same shape as Remit's own idempotency
nonce, which is a pleasing coincidence and nothing more.

**It cannot carry a Remit spend.** EIP-3009 authorises exactly one thing: a USDC transfer
from the signer to a named recipient. There is no field for a target contract or arbitrary
calldata, so `createMandate` and `spend` cannot travel this path. Arc's own framing agrees
— it is for *"users who hold USDC and want gasless transfers without account
abstraction."*

Two operational facts from that page are worth keeping regardless, because they are about
Arc rather than about EIP-3009. A `transferWithAuthorization` that **fully drains a
brand-new account** (zero balance, zero nonce, no code) currently reverts, with a fix
"planned for a future release" — so Arc has a documented first-touch/last-touch account
edge, which is the same neighbourhood as this project's measured ~5,333-gas first-credit
premium. And a blocklisted `from` or `to` **reverts at runtime and consumes the
submitter's gas with no transfer**, which is a direct cost model for any Remit relayer:
Circle's blocklist turns into wasted gas on the sponsor's bill, so a sponsor must screen
both addresses before submitting.

### ERC-4337 paymaster — real, live, and it breaks Remit's spender check

EntryPoint **v0.7**, documented at `0x0000000071727De22E5E9d8BAf0edAc6f37da032`. Arc's own
page hedges this with *"verify the EntryPoint v0.7 address for Arc testnet before use"* —
so it was verified, on 2026-08-25, against Arc testnet:

```
$ cast code 0x0000000071727De22E5E9d8BAf0edAc6f37da032 --rpc-url https://rpc.testnet.arc.io | wc -c
32073
```

32,073 output bytes, less the `0x` prefix and the trailing newline, halved: **16,035 bytes
of runtime bytecode**, comfortably under EIP-170's 24,576 limit and about 1.4× the size of
`MandateManager`'s own 11,572. So a substantial contract *is* deployed at the canonical
address on Arc testnet.

**That proves a contract is there, not that it is EntryPoint v0.7**, and the usual next
step — comparing the codehash against a published reference — needs network access this
environment does not have. So the identity was established the other way round, by
prediction, which is the same method `evidence/expected-id.txt` used to prove the mandate-ID
derivation before the first transaction was ever sent.

v0.7's hash is fully specified, so its answer for a chosen input is derivable off-chain:

```
UserOperationLib.encode(op) = abi.encode(
    op.sender, op.nonce,
    keccak256(op.initCode), keccak256(op.callData),
    op.accountGasLimits, op.preVerificationGas, op.gasFees,
    keccak256(op.paymasterAndData))            // signature deliberately excluded

hash(op)            = keccak256(encode(op))
getUserOpHash(op)   = keccak256(abi.encode(hash(op), address(this), block.chainid))
```

`userophash.py` in this repository derives that for an all-zero `PackedUserOperation`,
using a standard-library Keccak-256 checked against three published vectors first, and
hand-builds the 452-byte calldata so no ABI encoder is trusted either. It predicted
`0x07f96d30b0cc2f1c5f6381309cbc63d3c80eb361a777ff3b7d29ea473e06c930`. Arc returned:

```
$ cast call 0x0000000071727De22E5E9d8BAf0edAc6f37da032 --data 0x22cdde4c… --rpc-url https://rpc.testnet.arc.io
0x07f96d30b0cc2f1c5f6381309cbc63d3c80eb361a777ff3b7d29ea473e06c930
```

**Match, all 32 bytes** — `evidence/entrypoint.log`. Two things make that a version claim
rather than a liveness one. The selector `0x22cdde4c` is `getUserOpHash(PackedUserOperation)`,
v0.7's nine-field struct with its two packed `bytes32` gas words; v0.6's `UserOperation` is
eleven fields and hashes under `0xa6193531`, a different function that this call would not
have reached. And the returned value commits to `address(this)` and `block.chainid`, so the
same bytecode at another address, or on another chain, could not produce this number.

**The honest limit, still.** This proves the *hashing path* is v0.7's, which is precisely
what signature compatibility between a wallet, a bundler and a paymaster depends on. It does
not prove all 16,035 bytes are byte-identical to the canonical release — a modified
EntryPoint that kept `getUserOpHash` intact would pass. `balanceOf(payer)` also answered `0`
rather than reverting, so the deposit ABI is present and the payer has simply never
deposited. Both reads are in the same log.

Pimlico is the documented bundler. The one Arc-specific twist is decimals: the paymaster's
EntryPoint deposit is **native USDC at 18 decimals**, so 10 USDC is `10 * 10^18`, not
`10 * 10^6`. This is the same 6-vs-18 split already documented in `DESIGN.md` for
`balanceOf` versus the EIP-7708 emitter, and it is the single easiest way to over-fund a
paymaster by a factor of 10^12.

**The problem is `msg.sender`.** Under 4337 the transaction originates from the bundler,
passes through EntryPoint, and executes from the **smart account**. So:

- For a **spend**, `MandateManager` requires `msg.sender == m.spender` (line 454). A 4337
  route works *only if the mandate's spender is the smart account address itself* — which
  is fine, and in fact natural for an agent, but it means the agent is a 4337 account
  rather than an EOA, decided at grant time.
- For a **grant**, `createMandate` records `payer: msg.sender` (line 371). Under 4337 that
  is the smart account, not the human — which for L3 is *exactly what we want*, since the
  vault is the payer anyway.

So 4337 is usable, but it is a decision about **what kind of account the agent and the
vault are**, not a transport you can bolt on afterwards.

### EIP-7702 — the one that answers the open question

`/integrate/evm-differences` states plainly:

> EIP-7702 set-code transactions, `CREATE2` (including EIP-7610 residual-storage
> behavior), and EIP-2935 historical block hashes all behave as on Ethereum.

**This closes the question `CHANGELIST.md` has carried for weeks in the direction the
backlog hoped for, but only halfway, and the halves point opposite ways.** A 7702-delegated
EOA is still an EOA: it keeps its own address as `msg.sender`, `tx.origin` still equals it,
and it has code. So for Remit's own `spend` and `createMandate` paths, a delegated EOA
satisfies the spender and payer checks natively — no special handling, nothing to change
in v2.

**For Arc's `Memo` and `CallFrom` extensions, the answer is the opposite, and the docs are
explicit.** `/arc/concepts/transaction-memos` says the `Memo` contract *"must be invoked
directly by an externally owned account"* and lists as unsupported *"any other
account-abstraction setup where the transaction originates from a bundler, entry point, or
other intermediary contract,"* because *"sender spoofing isn't allowed."* That rules out
4337 for the memo path unambiguously. It does **not** name 7702, and 7702 does not involve
an intermediary — the delegated EOA signs and originates its own transaction — so the
documented reasoning suggests it should pass. That is an inference, not a documented fact,
and it is exactly the kind of inference this project has been burned by. **It needs one
`cast send` against Arc to settle, and that is cheap.**

## What this means for Remit, in order of how much it changes

**1. L3's blocker is smaller than the spec assumed.** `L3-VAULT.md` concluded that a
depositor who submits their own `createMandate` is deanonymised as the transaction's
`from`, making an unsponsored L3 worse than no L3. That conclusion stands. But the fix
does not require anything to be built on Arc — 4337 with a paymaster is live *today*, and
under it the grant originates from a smart account rather than the depositor's EOA. The
remaining work is our own relayer or paymaster policy, not a missing chain feature. **The
gate is open; it was never closed.** I should not have described it as the next piece of
work without checking whether the chain already offered it, and the honest version is that
I inferred a chain limitation from the fact that Arc's tutorials use a plain EOA.

**2. The relayer-sees-who-asked caveat gets sharper, and worse.** Under 4337, the
depositor's privacy set is whoever shares the paymaster; under an EIP-3009-style relayer it
would be whoever shares the relayer. Either way L3's payer privacy is *shifted to the
sponsor*. Arc names Pimlico as the documented bundler, so the realistic day-one L3 has a
single third party who sees every grant request. `L3-VAULT.md` says to disclose this rather
than let "relayed" be heard as "trustless"; that disclosure is now concrete enough to name
a company in.

**3. Blocklist reverts burn the sponsor's gas.** Documented for the 3009 path and true in
general on Arc. A Remit paymaster sponsoring spends to arbitrary recipients pays for every
blocklisted-recipient revert. Screen recipients before sponsoring, or the sponsor is a
free denial-of-wallet target. This is a new operational requirement that neither
`PRIVACY.md` nor `L3-VAULT.md` anticipated.

**4. `MAX_WINDOWS`-style thinking applies to sponsorship too.** A sponsor pays whatever
the spend costs, and `L3-VAULT.md` established that spend gas is depositor-inflatable by
~230,000 through ring buckets and effectively unbounded through the credential gate's
decoded string. Under sponsorship, that inflation is charged to *us*. The caps that spec
recommends for a vault are equally necessary for a paymaster, for a different reason.

## What the docs do not say

Recorded so nobody later mistakes absence for confirmation.

- **No `permit` / EIP-2612 on Arc's USDC.** `rg` found `permit` only in App Kit pages, and
  `receiveWithAuthorization` and `cancelAuthorization` appear **nowhere** in the docs even
  though both are part of standard EIP-3009. Whether Arc's USDC implements them is
  unestablished; the docs show only `transferWithAuthorization`.
- **The EntryPoint address is explicitly flagged as needing verification** by Arc's own
  page. **Settled 2026-08-26:** 16,035 bytes are deployed there, and the contract reproduced
  a locally predicted `getUserOpHash` exactly, over v0.7's `PackedUserOperation` ABI —
  `evidence/entrypoint.log`, derivation in `userophash.py`. What remains formally open is
  whether the *whole* bytecode is byte-identical to the canonical release, which needs a
  reference codehash this environment cannot fetch; the hashing path, which is the part
  signature compatibility rests on, is confirmed.
- **No native, protocol-level fee-payer field.** Arc has no documented "sponsor" or
  "fee payer" transaction type of the kind some chains offer. Sponsorship is entirely
  application-level: 3009, 4337, or your own relayer.
- **Nothing on whether a 7702-delegated EOA passes `Memo`/`CallFrom`.** Inference only,
  per above.
- **The 20 Gwei floor appears twice** (`maxFeePerGas` minimum, "transactions priced under
  this minimum may remain pending"), while this project has *measured* an effective 21 Gwei
  on Arc receipts. Not a contradiction — a floor is not a price — but the measured number
  is the one to cost with.

## The finding that is not about gas at all

`/arc/concepts/opt-in-privacy` documents the **Arc Privacy Sector (APS)**: a confidential
execution environment for ordinary Solidity contracts, running alongside the public EVM,
in hardware enclaves, with both state roots committed in the same block. Private and
public contracts compose **atomically, in one block, with no bridge**. Contract isolation
is **default-deny** — every function and storage slot is inaccessible until explicitly
opened via per-selector `Open`/`Restricted`/`Locked` policies and revocable `addTrustee`
trust domains. Event logging is off by default, revert reasons are sanitised, and **gas
reporting to external observers is constant-time**. Encryption is hybrid post-quantum
(X-Wing KEM = X25519 + ML-KEM-768, AES-256-GCM-SIV for state), keyed by a master secret
Shamir-shared across validators and reconstructable only inside attested enclaves.

**`<Info>Privacy features are on the roadmap and not yet available on Arc.</Info>`** —
Arc's own words, on that page. So none of it is usable today.

It matters anyway, for four reasons, and the third is uncomfortable.

**It is a fourth privacy architecture that `PRIVACY.md` does not contain.** That document
enumerates commitments (L0/L1), stealth addresses (L2) and a ZK shielded pool (L3), and
concludes amounts are hideable only inside a pool. APS would hide amounts, recipients,
payer, caps, thresholds and `totalSpent` *simultaneously*, by deploying `MandateManager`
itself into a confidential environment with no cryptography of our own — the exact thing
`PRIVACY.md`'s leak inventory marks as hideable "only at ruinous cost". It is a different
trust model (hardware enclaves and a validator-held master key, versus a proof anyone can
verify), and that trade deserves to be argued on the page rather than omitted from it.

**It moots much of L3's engineering if it ships.** `L3-VAULT.md` is 537 lines of escrow
accounting, nullifier handling and circuit design whose entire purpose is hiding which
depositor authorised a payment. APS would deliver that as a deployment target. The spec is
not wasted — its contract findings are permanent, and an enclave-based answer is not
strictly better than a ZK one — but building L3 without knowing APS's timeline would be a
mistake, and "not yet available" with no date is not a timeline.

**I specced two privacy layers against this chain without reading its privacy page.** The
search that found APS took one query. `PRIVACY.md` opens by saying privacy is the easiest
thing in this codebase to get catastrophically wrong; getting it wrong by not checking
whether the platform already has an answer was not the failure mode I was watching for.
The rule this earns: **before specifying a capability for a specific chain, read that
chain's own documentation on the capability.** The arc-docs MCP was available for both
prior sessions.

**Two APS details are directly useful even if we never deploy into it.** Constant-time gas
reporting to external observers is an acknowledgement, by Circle, that *gas is a side
channel* — which supports the finding in `L3-VAULT.md` that depositor-controlled spend gas
is an information leak and not merely a cost. And default-deny with per-selector policies
is a cleaner formulation of the thing `PRIVACY.md` correctly rejects for the public EVM
("storage is not secret", so access control hides nothing): under APS, access control
*does* hide something, because storage is encrypted. The reason `getMandate` cannot be
gated today is environmental, not a law.

## Recommended next steps

Cheap, and each settles a question rather than adding surface:

1. ~~`cast code` the EntryPoint, then confirm it is really v0.7.~~ **Done 2026-08-26.**
   16,035 bytes present, and a locally predicted `getUserOpHash` reproduced exactly over
   v0.7's ABI. See `evidence/entrypoint.log` and `userophash.py`. Nothing further is worth
   spending on this: the remaining gap is whole-bytecode canonicality, which needs a
   reference this environment cannot fetch and which a paymaster integration does not
   depend on.
2. **Test whether a 7702-delegated EOA passes `Memo`.** Settles the `CHANGELIST.md`
   question with a receipt instead of an inference. Needs a delegation and one memo call.
3. **Ask Circle about the APS timeline** before committing engineering to L3. "On the
   roadmap" with no date is a reason to sequence, not to stop.
4. **Only then** spec the sponsorship policy, which is now an application-level design
   question — who sponsors, how recipients are screened, and what caps protect the
   sponsor — rather than a question about what Arc supports.

Sources: [Relayers and paymasters](https://docs.arc.io/integrate/relayers-and-paymasters),
[EIP-3009 relayer](https://docs.arc.io/integrate/relayers-and-paymasters/eip-3009-relayer),
[Deploy a paymaster](https://docs.arc.io/integrate/relayers-and-paymasters/deploy-a-paymaster),
[EVM differences](https://docs.arc.io/integrate/evm-differences),
[Transaction memos](https://docs.arc.io/arc/concepts/transaction-memos),
[Opt-in privacy](https://docs.arc.io/arc/concepts/opt-in-privacy),
[Account abstraction tools](https://docs.arc.io/arc/tools/account-abstraction).
