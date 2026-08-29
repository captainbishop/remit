# IMMUTABILITY.md

**Status: written 2026-08-26. Not an audit.** This document answers one question — *the
deployed contract cannot be changed, so what does that mean for me?* — and it answers it
about **v1 as deployed on Arc Testnet**, not about the v2 working tree.

It exists because the answer has two halves that are easy to confuse. The first half is a
verified mechanical fact: there is no admin, no owner, no pause and no upgrade path in the
deployed bytecode. The second half is a design judgement: that this is the right choice, and
that its cost is a migration rather than a vulnerability. The first half is checkable and is
checked below. The second half is an argument, and it is presented as one.

> **Unqualified line numbers in this file refer to the tagged v1 source**, per the repo-wide
> convention recorded in `FORGE.md`; recover that source with
> `git show v1.0.0-arc-testnet:contracts/MandateManager.sol`. This file needs no exception to
> that convention, unlike `THREAT-MODEL.md`: it is *about* the deployed code, which is
> exactly what the tag preserves.

**v1 is not correct.** `THREAT-MODEL.md` records twenty-six findings against the same
surface. Two are already fixed in v2's code and two in that document itself; eight more have
a fix that changes v2's behaviour, eight are comment rewrites, three are documentation, one
needs a decision, one needs a test before it can be sized, and one needs nothing — a
partition that carries more information than the total, since it says how much of the list is
about the code doing the wrong thing rather than about it being described wrongly. v1 has
never been audited, holds nothing but faucet money, and must not hold real money.
Immutable and correct are independent properties, and this document is only about the first.

---

## 1. What is deployed

| | |
|---|---|
| Contract | `MandateManager` |
| Address | `0x3744E93B9e796E05CB66311d897559B6F3860196` |
| Network | Arc Testnet, chain id `5042002` |
| Deploy tx | `0x5cb3fd0b6d543fecb56d62b7ca3fa36c88974ad0c3a69d2ec09edf524900849f` |
| Block | 58558548 |
| Gas used | 2,557,453 at 21 Gwei |
| Runtime size | 11,572 bytes |
| Source | verified on Blockscout; reproducible from tag `v1.0.0-arc-testnet` |

The three constructor arguments were read back off-chain after deployment
(`evidence/deploy-check.log`):

```
usdc:        0x3600000000000000000000000000000000000000
identity:    0x8004A818BFB912233c491871b3d84c89A494BD9e
validation:  0x8004Cb1BF31DAf7788923b405b754f57acEB4272
```

They are `immutable` (lines 151–153), so they are burned into the runtime bytecode at
construction and are not storage that anything could later rewrite. Note that `usdc` points
at Arc's real USDC precompile, not at the `MockUSDC` deployed for the gas-premium
measurement — the mock lives at `0x5949872a6fB7928bC5507d9D03D4b8078C233303` and the
deployed `MandateManager` has never referenced it.

## 2. What "no upgrade path" was verified to mean

Absence is harder to demonstrate than presence, so this was done by counting occurrences of
every name that an escape hatch would have to be spelled with, in the tagged source:

| Name searched | Occurrences in v1 |
|---|---|
| `admin` | 0 |
| `pause` | 0 |
| `upgrade` | 0 |
| `initialize` | 0 |
| `delegatecall` | 0 |
| `selfdestruct` | 0 |
| `onlyOwner` | 0 |
| `Ownable` | 0 |
| `proxy` | 0 |
| `setUsdc` | 0 |
| `sweep` | 0 |
| `rescue` | 0 |
| `withdraw(` | 0 |

Reproduce it:

```
git show v1.0.0-arc-testnet:contracts/MandateManager.sol > /tmp/v1.sol
grep -oiE "admin|pause|upgrade|initialize|delegatecall|selfdestruct" /tmp/v1.sol | wc -l
```

That prints `0`. It counts *occurrences* rather than matching lines, deliberately — see the
first note below for why that distinction cost this check four unexamined hits on the one term
where it mattered.

Two things that a naive sweep gets wrong, recorded because they are the places this check
could have produced a false clean bill:

**`owner` is not zero — it appears on 12 lines, 16 times, and all 16 were read
individually.** The distinction between those two numbers is not pedantry: `grep -c` counts
*lines*, so the first pass through this check reported 12 and would have left four
occurrences unexamined. Counted with `grep -oi owner | wc -l`, the 16 break down as:

| What it is | Occurrences | Lines |
|---|---|---|
| `ownerOf`, the ERC-721 accessor used to check the agent holds its identity NFT | 5 | 124 (declaration), 628 (call), 121 / 223 / 625 (prose) |
| the local variable `owner` inside `_checkIdentity` | 6 | 627, 629, 631, 634 (×2), 635 |
| `expectedOwner`, the optional field letting a payer pin who must hold the NFT | 3 | 223, 635 (×2) |
| the `owner` parameter in the IERC20 `allowance` signature | 1 | 117 |
| prose — "if the payer pinned an expected owner" | 1 | 618 |

None of them is an administrator. A count of zero for `onlyOwner` is not the same claim as a
count of zero for `owner`, and only reading all 16 distinguishes them.

**There is no contract-level mutable storage variable outside the mandate mappings.** A
sweep for declarations at contract scope that are neither `constant`, `immutable`, nor a
mapping returns nothing — every other hit is a struct field, a function parameter, an event
parameter or a local. There is therefore no global switch, no fee rate, no beneficiary, no
registry pointer that anything can move.

`implementation` appears exactly once, on line 28, inside the header banner's prose ("says
the implementation matches the model"). There is no second contract behind this one.

## 3. The complete surface that can change state

Five functions in `MandateManager` can write. Deriving this count needs care: `spend`
declares its visibility on a continuation line (437–440), so a same-line grep for `external`
misses it and produces a total that looks right for the wrong reason. The five, with the
guard that decides who may call:

| Function | Line | Who may call | What it can change |
|---|---|---|---|
| `createMandate` | 344 | anyone, for themselves | creates a mandate whose `payer` is `msg.sender` |
| `spend` | 437 | the mandate's `spender` only | consumes that mandate's caps; moves the payer's USDC |
| `revoke` | 701 | that mandate's `payer` **or** `spender` | sets `revoked = true`, permanently |
| `approveCosign` | 726 | that mandate's `cosigner` only | marks one spend hash pre-approved |
| `withdrawCosign` | 736 | that mandate's `cosigner` only | un-marks one spend hash |

`spendHash` (747) is `public view`; every other public entry point is a `view`. The whole
mutable state of the deployed contract is therefore mandates, created by the people they bind,
and altered only by those same people. There is no caller anywhere with authority over someone
else's mandate — and there is no caller with authority over *all* mandates, because no such
role exists in the code.

**This table describes the deployed contract and nothing else.** The line numbers and the
names are v1's, reproducible with
`git show v1.0.0-arc-testnet:contracts/MandateManager.sol`. v2 in the working tree renames
`approveCosign` to `approveCosignFor` and adds two views, and none of that reaches
`0x3744E93B9e796E05CB66311d897559B6F3860196` — there is no proxy, so the row above is what that
address exposes for as long as it exists. Do not update this table to match the source tree; a
payer deciding whether to trust the live deployment needs the live deployment's surface.

A detail that matters for §8: a mandate id is
`keccak256(abi.encode(DOMAIN, chainid, address(this), msg.sender, salt))`, so it binds the
deploying address. The same salt produces a *different* id on a different deployment, which
means a migration cannot collide with the ids it is migrating from, and a cosign approval
signed for one deployment cannot be replayed against another.

## 4. What it costs you

These costs are real, and they are not small.

**A bug means a new address, not a patch.** There is no mechanism by which the code at
`0x3744…0196` becomes different code. A fix is a second deployment somewhere else.

**Migration is per-payer, and no role in the contract can force it.** Because there is no
admin, there is also no party able to pause the flawed contract, freeze new grants, or push
users off it. Each payer has to act for themselves. Anyone who does not notice, or does not
bother, keeps using the flawed version — and it keeps working for them indefinitely. In a
system with an admin key, a critical bug is met with a pause; here the only response
available is an announcement that each payer must act on.

That difference is the single largest operational risk in this document, and it is **not
conditional on Remit becoming popular.** It applies in full to the first payer who is not the
author. Remit is a primitive meant to be granted by anyone — an unpermissioned contract at a
published address, with no allowlist of who may call `createMandate` — so "no third parties
yet" is a fact about the calendar, not a property of the design, and it stops being true the
first time someone reads the address off this repo.

The mitigation is entirely social: a disclosure channel people actually read, and integrators
who can be reached. It has to exist **before** the first third-party grant rather than after
the first bug, because a channel announced in response to an incident reaches no readers: the
people who need it are the ones who already stopped looking. As of this writing no such
channel exists, and nothing in this document closes that gap.

**Anyone integrating has to redeploy or reconfigure.** The address appears in this repo's
scripts, in `evidence/`, and in anything anyone builds. All of it has to move.

**Lifetime counters restart.** `totalSpent` and `spendCount` live in the old contract's
storage, so a re-granted mandate starts at zero. A payer who intended "this agent may spend
10,000 ever" and had already spent 8,000 gets a fresh 10,000 on the new contract unless they
grant 2,000 instead. The old figures stay readable forever via `getMandate` on the old
address, so this is recoverable, though only if you remember to look, which is what step 4 of
the runbook is for.

**Rolling windows restart too.** The ring buffer that enforces "no more than 15,000 per 24
hours" is storage in the old contract. Re-granting resets it, so the first day on the new
contract permits a full window's worth on top of whatever was already spent that day on the
old one. For a low-frequency mandate this is noise; for one running near its rate limit it is
a real, if one-off, doubling.

## 5. Why there is no upgrade key anyway

Every cost in §4 is real, and the design still declines an upgrade key.

Remit's entire proposition is that a payer's limits are properties of code rather than
promises from an operator. When you grant a mandate with a 5,000 per-transaction cap, a
three-address allowlist, a 24-hour ceiling and an expiry ninety days out — v2 requires that
last one, or a lifetime cap in its place, because the first three bound how fast money
leaves and never how much — the reason those hold is that the bytecode enforcing them
cannot be replaced. A contract that can be upgraded can be upgraded to remove
the cap check — so on an upgradeable Remit, the accurate description of a mandate is *capped,
unless whoever holds the key decides otherwise*, and the payer's real counterparty is the
key, not the code they read. That is the same trust relationship as a custodial policy
engine, which `DESIGN.md` exists to argue against; it would make the project a worse version
of the thing it is trying to replace.

The concentration is what makes it unacceptable rather than merely unfortunate. An upgrade
key on this contract sits in front of *every allowance every payer has ever granted to it* —
which makes it the highest-value single target in the system, permanently, and it stays that
way whether or not it is ever used. Approving an ERC-20 allowance to an upgradeable contract
is approving it to whatever that contract may later become.

The choice is therefore which failure you prefer: patchable bugs plus a standing trusted
party, or unpatchable bugs plus no trusted party. For a primitive whose only job is to bound
what someone else may take from your account, the second is the one that can be described
accurately to the person taking the risk.

This argument does **not** establish two further claims. It does not establish that
immutability makes v1 safe — §4's costs are the price of a *guarantee about the caps* rather
than evidence that the caps are correctly implemented, and `THREAT-MODEL.md` says they are
not yet. It also does not establish that no upgradeable design could be better: a timelocked,
publicly-announced upgrade with a payer veto window is a real design that real protocols use,
and the reason to decline it here is that it reintroduces a privileged party and a governance
surface for a contract whose whole appeal is having neither. That is a judgement about this
project's goals, not a proof.

## 6. What bounds the damage

The reason unpatchable bugs are survivable here is the shape of the exposure, and it differs
from most immutable contracts people are right to worry about.

**The contract holds nothing.** A spend is a single
`usdc.transferFrom(m.payer, recipient, amount)` at line 514, verified against receipts
rather than asserted: across the five live spends there are ten ERC-20 `Transfer` logs,
every one of them has the payer as `from` and the vendor as `to` — all ten `(from, to)`
pairs are byte-identical — and the contract's own address appears as neither party in any
of them, zero times in five receipts. Each spend emits exactly one `Spend` event and exactly
two `Transfer`s, the second being Arc's 18-decimal native emitter reporting the same movement
at a different scale. The evidence is in `evidence/spend.log`, `ref-spend.log`,
`cosign-spend.log`, `marginal-a.log`, and `subthreshold.log`.

There is therefore no pool to drain, no TVL, no liquidity, no share accounting, and nothing
that can be stranded at an address with no controller. Compare an immutable lending market,
where a bug means depositors' funds are permanently unreachable. Here, the worst case is
that a payer's own standing authorisation is abused, and the recovery is to withdraw the
authorisation.

**There is no cross-payer reach.** The `from` in that transfer is `m.payer`, a field stored
at grant time — never an argument the caller supplies. A defect in one mandate cannot reach a
different payer's balance, because the only address a mandate can debit is the one that
created it.

**The ceiling on any single payer's exposure is
`min(their allowance to Remit, their USDC balance)`**, and both are things the payer sets.

**What is *not* bounded is the allowance itself:** it is shared across *all* of that payer's
mandates, and Remit does not partition it. This was demonstrated live on 2026-08-24 — with
the allowance at 90,000, two separate mandates each reported `spendable` = 90,000, summing
to 180,000, and 50,000 dry-runs succeeded against both, which is 100,000 simulated against a
90,000 allowance (`evidence/ceiling.log`, `race.log`).

Be precise about what that does and does not mean, because the loose version of it is
alarmist. No funds beyond the allowance can actually leave: whichever `transferFrom` arrives
second simply reverts, and the allowance is a hard ceiling enforced by USDC itself. The defect
is in what the *views report*, not in what the contract permits. A payer reading `spendable`
on one mandate is told a number that is true of that mandate in isolation and false of their
account as a whole, and two agents each planning against it can each believe they have room
that only one of them has. The per-mandate caps are real; the *sum* of what all mandates could
take is bounded by the allowance rather than by the caps. `spendableAcross` in v2 reports the
true joint ceiling — and it is a view, so it corrects the reporting, not the sharing.

Circle's own wallet documentation makes a stronger version of the same point:
an ERC-20 allowance is not a cap on total USDC spending, because on Arc the same balance can
also leave as native value, and any module with execution rights on a smart-contract account
can move it regardless of allowance state. For a smart-contract payer the allowance is not a
safety guarantee at all. `L3-VAULT.md` makes a contract the payer, which is precisely why
that boundary is written down there too.

## 7. The two kill switches

Both belong to the payer alone. Neither requires anyone's cooperation.

**`revoke(mandateId)`** — line 701, callable by the mandate's payer or its spender, reverting
`NotPayer()` (selector `0x1435e357`; renamed `NotAuthorised()` in v2) for anyone else. It
sets `revoked = true` permanently; there is no un-revoke. That the spender may also call it is
deliberate: surrendering your own authority cannot harm the payer, and it lets a compromised
agent shut itself off.

One correction to the claim written beside that function in v1, which `THREAT-MODEL.md`
records as F4: the comment says there is "no window in which a revoked mandate is still live
and spendable". That is true of *reorgs* — Arc has BFT finality, so once the revocation is
included it cannot be undone, which is a genuine improvement over a probabilistic-finality
chain. It is not true of the *mempool*. Arc has a mempool and a rotating proposer, and a
spend submitted before your revocation can still be included before it. Revocation is
immediate on inclusion, not on submission. Do not plan around it being instantaneous.

**`approve(remit, 0)` on USDC** — the important one, because **it is not in Remit's code at
all**. The allowance lives in Arc's USDC contract at `0x3600…0000`; a spend is
`transferFrom`, and `transferFrom` cannot exceed the allowance, so zeroing it severs every
mandate at once and it keeps working even if `MandateManager` were broken in a way that made
`revoke` unreachable. It depends on Circle's token behaving as an ERC-20 rather than on
anything in this repository.

That is strictly stronger than the pause function this contract does not have. A pause
depends on the pauser being alive, reachable, honest and awake at the moment it matters; the
allowance depends on you sending one transaction. It is also why the migration runbook does
the allowance first.

Both switches assume that the payer's own account is secure and can still send
transactions, that Arc is producing blocks, and that USDC behaves as specified. Those are
trust boundaries, they are enumerated in `THREAT-MODEL.md` §2, and no amount of contract
design removes them.

## 8. Migration runbook

Use this if v1 ever needs abandoning. The ordering is deliberate: the step that does not
depend on `MandateManager` being correct comes first.

One mechanical warning that applies to every step involving `--account`: those commands prompt
for the keystore password, and a hidden prompt consumes whatever is still queued in the
terminal's input buffer. Paste them **one at a time, as the last line of the paste**, or
wrap them in a script and invoke that as a single command. The scripts already in this repo
(`revoke.sh`, `cosign-withdraw.sh`) exist for exactly that reason.

1. **Zero the allowance.** One transaction, and it stops every mandate on the old contract
   simultaneously.

   ```
   cast send 0x3600000000000000000000000000000000000000 \
     "approve(address,uint256)" 0x3744E93B9e796E05CB66311d897559B6F3860196 0 \
     --rpc-url https://rpc.testnet.arc.io --account remit-testnet
   ```

2. **Verify it landed** before doing anything else. Do not take step 1's receipt as proof.

   ```
   cast call 0x3600000000000000000000000000000000000000 \
     "allowance(address,address)(uint256)" \
     0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0 \
     0x3744E93B9e796E05CB66311d897559B6F3860196 \
     --rpc-url https://rpc.testnet.arc.io
   ```

   Expect `0`. At this point nothing can be spent through the old contract regardless of what
   its mandates say.

3. **Revoke each live mandate** on the old contract. The zeroed allowance has already
   stopped every spend, so this step is a precaution rather than a requirement, and it
   remains useful: it makes `isLive` return false so that any monitoring or accounting
   reading the old contract agrees with reality, and it leaves a `MandateRevoked` event in
   the audit trail. Use a script rather than separate pasted commands, so the keystore
   password prompts do not compete with queued terminal input — `revoke.sh` is the
   established pattern.

4. **Read the old counters off before you stop caring about them.** `getMandate(id)` on the
   old address returns `totalSpent` and `spendCount`, readable forever. Write them down for
   step 6, since after the migration nothing will remind you they existed.

5. **Deploy the new contract and verify it**, then confirm its three immutables by reading
   them back — the check in `evidence/deploy-check.log` is the template. A deployment whose
   `usdc` immutable is wrong is unrecoverable in exactly the way this whole document is about.

6. **Re-grant, adjusting for what was already spent.** If a lifetime cap was meant to be a
   lifetime cap, subtract step 4's `totalSpent` from it. If a rolling window matters, be aware
   its history is gone (§4) and consider a lower cap for the first period.

7. **Grant first, then approve.** Both orders are safe — an allowance with no mandate is
   inert, since `spend` requires a mandate naming the caller as spender — so this is a
   preference rather than a security requirement: it means you never hold a standing
   allowance to a contract you have not finished configuring.

8. **Verify the new setup with a view, not with a transfer.** `spendable(id)` returns what the
   agent can actually spend right now, folding in the caps, the allowance and the balance.
   Confirm it is the number you intended before telling the agent the new address.

9. **Update every integrator**, including this repo's scripts. Then keep the old address
   documented rather than deleted — the receipts in `evidence/` point at it, and they remain
   valid evidence about the old bytecode.

## 9. What is permanently wrong in v1, and cannot be fixed

Two things in v1 are permanently wrong.

**The header comment inside the verified source is wrong, and must stay wrong.** Correcting it
would change the source, which changes solc's appended metadata hash, which breaks the
byte-for-byte reproduction of the deployed bytecode. These are therefore permanent properties
of `0x3744…0196`. They are comments and affect no execution, but a reader of the on-chain
source is being misinformed and cannot be un-misinformed. The errors fall into two kinds:

*Wrong when it was deployed.* Line 11 and line 22 say the suite is **139 tests**; it was 140.
Line 26 attributes **~142,500** gas to the policy machinery and **~32,700** to Arc's
native-USDC accounting; the correctly-derived figures are **~103,500** and **~13,100**, and
the originals were measurement errors rather than drift.

*Accurate then, stale now.* Lines 14–15 say "one mandate has been granted and one spend
executed live", and lines 21–22 say cosignature, both ERC-8004 checks and revoke have "zero
live transactions". Both were true on 2026-08-24 and are badly understated today: the live
surface is five mandates, five spends, three revocations, four cosignature transactions, 31
in total, every one status 1, with both ERC-8004 checks having fired against Arc's real
registries. All five state-changing functions have now run live, so none of them stands at
zero. Line 13 likewise credits the reference model with 46 tests, which was right then and
is 57 now.

The one part of that banner which is correct and which the v2 replacement keeps verbatim is
the `NOT AUDITED` / no-real-money half.
`CHANGELIST.md:87` quotes the stale banner deliberately and annotates it four lines later;
that quotation is not a defect and should not be "fixed".

**A number written into an immutable contract is a permanent claim, so it has to be derived
at the moment of writing rather than carried over.** This is precisely why v2's banner
currently carries no test count and no gas table — an inherited number is worse than a
missing one, because a missing number invites a measurement and an inherited one invites
trust.

**`THREAT-MODEL.md`'s findings describe the deployed bytecode too.** They are being fixed in
v2, in the working tree, at a future address. Nothing in that document is fixed in v1 and
nothing in it can be. The ones that change which grants are legal — requiring a lifetime
bound, meaning a total cap or an expiry and not merely a rate; refusing an `expiresAt` that
nothing reads; refusing an unreachable cosign requirement — are exactly the class of defect
that costs one edit before a freeze and a migration after one.

## 10. What this document claims, and what it does not

It claims that the deployed contract has no administrator, no upgrade path, and no
privileged caller, and it shows the check. It claims that funds never enter the contract, and
shows ten `Transfer` logs across five receipts to that effect. It claims two independent kill
switches exist and that one of them lives outside this codebase.

It does not claim that v1 is correct, safe, or ready for real money. It is a testnet artifact
holding faucet funds, controlled by two throwaway wallets, with twenty-six known findings
against it and no audit. Immutability is what makes its *caps* trustworthy if they are
implemented correctly; it does nothing whatsoever to establish that they are. That is the
audit's job, and because this repository's contract, tests, reference model and threat model
were all written by the same author, the audit is a hard requirement rather than a formality —
same-author review cannot be the second pair of eyes it is meant to be.

The sequencing follows directly: finish v2, fix everything `THREAT-MODEL.md` found, commission
the audit, and only then consider a mainnet deployment — with low caps at first, since a
staged rollout is the one cheap way left to discover what review missed.
