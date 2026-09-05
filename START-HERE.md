# Start here

This is the on-ramp. The other three documents in this folder — `README.md`,
`DESIGN.md`, `FORGE.md` — are written for someone who already builds software. This
one is written for someone who is starting out, and it assumes nothing.

## Where you are

**All five stages below are done, as of 2026-08-24.** Node is installed and the reference
tests pass — 102 of them in the current tree, since v2 has been adding to that suite. Foundry
is installed under WSL, the contract compiles, and all 320 Forge tests pass, including
2,048 randomised fuzz runs and 49,152 invariant calls. Gas is measured, and stage 4 is
complete: the contract is deployed to Arc Testnet with its source published, a mandate has
been granted, and **an agent has spent your money under policy without ever holding your
key.** Stage 5 was done before stage 4 because it needed only the local suite.

Your contract is live and anyone can look at it:
**[`0x3744E93B9e796E05CB66311d897559B6F3860196`](https://testnet.arcscan.app/address/0x3744e93b9e796e05cb66311d897559b6f3860196)**.

The stage write-ups are left in place because they record how it was done and what went
wrong. Read them for reference now, not as instructions.

**What comes next is no longer a stage in this guide.** It is the pre-audit work listed at
the end of README.md: the deep test profile, exercising the paths testnet has yet to touch
(cosignature, the two ERC-8004 checks, revocation), and an audit, because this is meant to
hold real money.

## What Remit is

Remit is a smart contract that lets you hand an AI agent a company card with real
limits on it. You keep your own money in your own wallet; the agent gets permission to
spend up to certain amounts, only to certain recipients, only for a while, and you can
cancel that permission instantly. Every spend leaves a receipt anyone can check.

Five things exist in this folder. All of them now work, and one of them has been proven on
a real blockchain rather than only in tests.

The **reference model** (`reference/policy.js`) is the rulebook, written in JavaScript.
It decides every question: is this spend allowed, and if not, exactly why. It works right
now, and its 102 tests pass.

The **contract** (`contracts/MandateManager.sol`) is that same rulebook rewritten in
Solidity, the language blockchains run. It first compiled on 2026-08-24 against 140 tests,
every one of which passed; the suite has since grown to 320, and all 320 pass. It is
**deployed and working on Arc's test network** — five real mandates, five real payments, and
thirty-one transactions in all, every one visible in the explorer.

The **Forge tests** (`test/`, 320 of them) check the contract against its real storage
layout, including thousands of randomised runs. They all pass.

The **demo** (`demo/playground.html`) is a web page that simulates the whole thing in a
browser. It works right now, needs nothing installed, and it is the fastest way to see
what you have built — double-click it.

The **documents** explain the reasoning, the threat model, and what the project does
*not* protect against. They state the gaps plainly, which is the main thing that
makes them useful.

## Where the project lives

```
C:\Users\DELL\projects\remit
```

It used to sit in a scratch directory inside `AppData`, which is no home for a project —
that folder gets cleaned up. It has been moved, and I work directly in the path above, so
nothing needs copying back and forth. Everything below assumes that is where it is. Inside
WSL the same folder is `/mnt/c/Users/DELL/projects/remit`.

## The decision that changes the plan — answered

**What do you want Remit to be?** There were two answers. As of 2026-08-24 you have
picked the second one: **something that holds real money.**

*Something you built and can show people* was the other option — deployed to Arc's test
network, where the money is fake and free, with a working demo and documentation
explaining why it exists. That version needs no audit, because nothing real can be lost.

*Something that holds real money* is the same code and an entirely different bar. Three
things follow from your choice, and they are worth knowing now rather than later.

A **professional security audit is now mandatory**, not advisory. For a contract this size
that realistically costs tens of thousands of dollars and takes weeks. I would tell you not
to skip it, and I would tell someone with five years of Solidity behind them exactly the
same thing — contracts that move other people's money get attacked by people who do this
full time, and they do not grade on a curve for a first project.

Before that audit, the suite gets run with `FOUNDRY_PROFILE=deep`: 20,000 fuzz runs instead of
512, and 2,000 invariant runs at four times the depth. It takes minutes rather than
seconds. The default profile is tuned to finish while you watch it, which is the right
setting for development and the wrong one for the last run before an audit.

The three "documented soft spots" in the README also stop being curiosities. The one to
revisit first is a mandate configured with `perTxCap` below `cosignThreshold`: it produces
a policy where no human is ever asked to approve anything. Right now the contract accepts
that configuration and we wrote it down. For fake money, documenting it is a reasonable
call. For real money, it should probably be refused at grant time.

That happened, and how it went is the pattern to expect from the rest of the list. The
refusal took four lines, and working out *what* to refuse took much longer: the version
written down here and in two other files was wrong in two separate ways — the comparison
needed to be `<=` rather than `<`, and `perTxCap` turned out not to be the only ceiling
that can strand a threshold. Then asking the general question rather than the specific
one — how many ways are there to look supervised without being supervised? — turned up two
more holes, one of which is worse than the item on the list: a mandate could name the agent
as its own cosigner, and `approveCosign` would let that agent approve its own spends.
Nothing in the suite failed for any of this beforehand. The point to carry to the next item
is that a documented soft spot is a description of what one person noticed, not a
specification of the defect.

(That function is now called `approveCosignFor` and takes explicit fields rather than a bare
hash — #28 — and it authorises exactly the same way, on `msg.sender == m.cosigner` alone. The
hole was closed at grant time instead, which is the only place it can be closed.)

None of this changed stages 4 or 5, which were identical either way and are now both done.
It changes what happens next.

## How we work together

You will not need to read Solidity or understand compiler errors. The loop is:

You run a command in your terminal. Something goes wrong, because something always goes
wrong. You copy everything the terminal printed — all of it, including the parts that
look like noise — and paste it to me. I read it, fix the file, and tell you what to run
next, and that repeats until the output is green.

Your job in that loop is to be an accurate messenger: paste error messages in full,
including the boring lines, which are usually the ones with the file name and line number
in them. If a command produces two hundred lines of output, paste two hundred lines.

Two habits to keep from day one, and stage 4 has now put both to work. Never paste a
private key or a seed phrase to me or to anyone else, in any context, ever — the safe way
is Foundry's encrypted keystore, which is what your two testnet wallets use. When a tool
asks whether you want to do something unexpected, read it before agreeing.

## Stage 1 — run the tests that already work ✅ done

Purpose: get one thing working end to end, and get comfortable with a terminal. This
should take fifteen minutes and it should succeed on the first try.

Install Node.js from [nodejs.org](https://nodejs.org) — the "LTS" version. Accept the
defaults.

You will need a terminal. If you have **Visual Studio Code**, use the one built into it:
open the `remit` folder with File → Open Folder, then press `Ctrl` and the backtick key
(`` ` ``, top-left of the keyboard, above Tab) to open a terminal already pointed at the
project. That is the easiest option, because the code and the terminal are in the same
window and selecting output to paste to me is just click-and-drag. Otherwise open
**PowerShell** — press Start, type `powershell`, hit enter — and `cd` to the project
yourself.

Check the install worked:

```
node --version
```

You should see something like `v22.11.0`. Anything starting `v18` or higher is fine.
If PowerShell fails to recognise `node`, close it and open a new one — the
installer changes the environment and only new terminals pick it up.

Now go to the project and run the test suite:

```
cd C:\Users\DELL\projects\remit
node --test reference/policy.test.js
```

The last lines should read:

```
# tests 102
# pass 102
# fail 0
```

That is the rulebook verifying itself, including six deliberately reconstructed attacks
it defeats. If you see `102 pass`, the foundation of the project is sound and you have run
your first test suite. If you see anything else, paste all of it to me — that would be
surprising, and I would want to know.

(It said 46 before v2 work began, and if you are reading an older screenshot of your own
terminal, that is why. The count went 46 → 47 → 50 → 56 → 57 across four v2 tasks: one test
pinning the audit counter's own upper bound, which the model previously could not express
because the contract panicked there and a JavaScript integer has no width to panic at;
three for the holes in the co-signature requirement; six for the joint-ceiling view; and
one for the narrowed definition of a bounded mandate — a per-transaction cap or a window is
no longer enough on its own, because neither limits what can be spent over a lifetime. It
then went 57 → 69 → 72 → 76 → 92 → 94 → 102 as later v2 tasks each brought their own
regression tests, so the merkle allowlist was never what moved it next.)

## Stage 2 — compile the contract ✅ done

Purpose: find out whether the Solidity is valid. This was the hard stage, and it was hard
in a boring way rather than a conceptual way. It took three rounds of errors, none of
which meant the project was broken — they meant it had never been proofread
mechanically. The three were a mistyped key in `foundry.toml`, a variable named
`reference` (a reserved word in Solidity), and one test function holding more local
variables than the EVM can reach past. `FORGE.md` records all three.

The tool is called Foundry. On Windows the well-trodden path is to install it inside
WSL, which is a real Linux system running alongside Windows. I cannot check Foundry's
current native-Windows support from this environment, so I am pointing you at the route
I am confident about rather than the one that might be shorter.

In PowerShell **as administrator** (right-click PowerShell, "Run as administrator"):

```
wsl --install
```

Reboot when it asks. It will set up Ubuntu and ask you to pick a username and password;
that password is for Linux, and it is normal that nothing appears on screen while you
type it.

From then on you will work in the **Ubuntu** terminal, not PowerShell. Inside it, your
Windows C: drive is at `/mnt/c`, so the project is at
`/mnt/c/Users/DELL/projects/remit`.

```
sudo apt update && sudo apt install -y git curl
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup
forge --version
```

Then try to build. There is nothing to fetch — forge-std, the one dependency, is
vendored into `lib/` and travels with the repository:

```
cd /mnt/c/Users/DELL/projects/remit
forge build
```

`forge build` is the moment of truth. It ends with `Compiler run successful` — for a
while it said `successful with warnings`, and the warnings were lint suggestions rather
than errors, 91 of them. They have since been read one at a time: five in the contract
now carry a written explanation of why that particular line is sound, three real problems
in the test harness were fixed, and the rest were a category the compiler already checks,
with the whole account in `FORGE.md`. The pattern matters more than the detail here: a
warning you have decided to ignore stops being read, and the count I was carrying in my
head had drifted from five to ninety-one without anyone noticing.

## Stage 3 — run the 320 contract tests ✅ done

```
forge test
```

All 320 pass. The last timed run took about ten seconds at 320 tests, so expect
roughly that. Then two specific checks, which matter more than they look:

```
forge test --match-test test_flagConstants_matchTheContract
forge test --match-test test_handlerCanActuallySpend_soTheInvariantsAreNotVacuous
```

The first catches a failure where the tests are checking the wrong thing while
appearing to pass. The second catches the classic lie in this style of testing, where
every test passes because nothing was actually attempted. A suite can be green and
worthless; those two commands are how you tell. Both pass.

Four tests failed on the first run, and all four were wrong about the contract rather
than the contract being wrong — which is the direction you want a first run to fail in.
When a test fails we have to decide which of the two is at fault, and that is a judgement
call, not a lookup: `FORGE.md` has a section on how to make it, and five tests are
deliberately pinning behaviour that *looks* like a bug and is not one.

## Stage 4 — put it on the test network ✅ done

Purpose: the thing exists in the world, done on 2026-08-24. The contract is at
[`0x3744E93B9e796E05CB66311d897559B6F3860196`](https://testnet.arcscan.app/address/0x3744e93b9e796e05cb66311d897559b6f3860196)
with its source published. Thirty-one real transactions have run against it since, and all
five of its state-changing functions have been exercised live. These four are the ones that
came first, on the day it went up:

| what happened | gas |
|---|---|
| [funded the agent with 1.00 USDC](https://testnet.arcscan.app/tx/0x122eb20985eb09a2774bc065abd51b49576dcc39bb63a1d7525d9440166250e4) — a plain transfer, the control | 73,950 |
| [approved a 2.00 budget](https://testnet.arcscan.app/tx/0x6fc4a422e4d2ce12e8402ae1a9485d03672d6e48fd9887a4befa745331b41754) | 55,438 |
| [granted the mandate](https://testnet.arcscan.app/tx/0xe286718d2b66d109c7decc5d7fd0c7c9c564422392f7cfa73e9e0bcf57376b73) | 152,243 |
| [the agent spent 0.10 of your money](https://testnet.arcscan.app/tx/0x52e878671acf3c85b639fab66bcbfc128e1581a40b975a9cf291a41af8930919) | 216,458 |

You made a **brand new wallet** for this, holding nothing real, stored in Foundry's
encrypted keystore rather than pasted into commands. That advice stands for every key you
ever handle: never paste a private key or a seed phrase to me or to anyone, in any context,
ever. I will never ask for one.

The one thing worth remembering from doing it is that on Arc, USDC *is* the gas token, so an
account with no USDC cannot do anything at all, not even fail — and that applies to the
*agent* as well as to you, which is easy to forget.

The most satisfying part is visible in the explorer without reading any code. On the spend,
the money moves **from your address to the vendor's**. The contract never appears as a
holder of anything; it only shows up as the thing that emitted the receipt. Non-custody
stopped being a claim in a document and became something you can point at.

Six of the policy refusals were then re-checked against the live contract for zero gas, by
asking it what *would* happen rather than doing it: a recipient not on the allowlist, an
amount over the per-transaction cap, the wrong spender, a zero amount, a mandate that
does not exist, and — the important one — replaying the payment that already went through.
Each was refused with exactly the error predicted. The replay refusal is the one that
matters, because it is the difference between a duplicated invoice and a rejected one.

The exact commands are in `README.md` under "Deployed on Arc Testnet", written so anyone
can reproduce the whole sequence from scratch.

## Stage 5 — measure what a spend costs ✅ done, out of order

```
forge test --gas-report
```

This one got done before stage 4, because it needed nothing but the local suite and it
was answering a question the design documents had been guessing at.

There was an open question about how finely the rolling spending window should be sliced.
More slices means more accurate rate limiting and a more expensive transaction, and the
trade-off point was unmeasured. The command turned that into arithmetic: **a median spend
cost 105,935 gas against the stand-in token** — v1's figure, from the 2026-08-25 report at
140 tests, and v2 has no gas report of its own yet. Each extra slice adds about 2,150 gas,
so going from 12 slices to 24 costs a twentieth of a cent and takes the rate limiter from
92% accurate to 96%. The margin is decisive, and the generous setting is the right default.
`DESIGN.md` has the full table and the three conditions on believing it.

The one thing this could not tell you was what the *real* USDC costs, because the tests use
a stand-in token. Arc's actual USDC does its own accounting on every transfer, and that is
not free. **Stage 4 produced that number: a real policed spend cost 216,458 gas, which at
the 21 Gwei the chain actually charged is 0.0045 USDC — under half a cent.**

Two figures in this section were wrong for weeks, and both were corrected on 2026-08-24 by
measuring instead of inferring. They are worth walking through, because the mistakes are the
ordinary kind rather than the exotic kind.

**How much of a spend is Arc's own token?** The way to find out is to put the stand-in
token *on Arc itself* and run the identical transaction against both, which is what
`evidence/premium.log` does, and the answer is **13,110 gas**, about 6% of a spend. This
file used to say the stand-in was "cheap by about 40%," a figure that was wrong for a
mundane reason: the earlier number came from comparing a test-harness prediction against a
real receipt, and a test harness has costs of its own that have nothing to do with Arc — so
the comparison was measuring the harness as much as the chain.

**What does the policy machinery cost?** Comparing the policed spend against the plain
transfer in the table above gives **103,479 gas, about 0.217 cents** — every cap, the
allowlist, the expiry, the replay check, the receipt. A payment with rules attached costs
roughly **2.4×** one without. This used to read 142,500 gas, a third of a cent, and three
times. The error is worth understanding because it is so easy to make: 216,458 was a
*first-ever* spend on a brand-new mandate, where every storage slot is being written for the
first time. Writing a fresh slot costs about seven times more than updating one that already
holds a value, so the first spend on any mandate is unusually expensive. Charging that
one-time setup to the recurring per-payment price overstated it by 39,029 gas. The right
comparison is the *second* spend and every one after — 177,429 gas, measured in
`evidence/marginal-a.log`.

Neither correction changes any decision in this project. Both make Remit look cheaper than
it was advertised as being, which is a pleasant direction for an error to run, and the
method behind both generalises: a number derived by subtracting two things measured on
different footings is not a measurement, and it will usually be wrong in the direction that
flatters whoever derived it.

## What you can safely defer

A **viem client**, which is a JavaScript library for talking to the contract from a normal
app — worth building only when you want a user interface, and not before.

The audit is no longer on this list, because you have said this will hold real money. It is
not urgent *yet* — auditing code that is still changing wastes the money, and the code is
still changing — but it is now a scheduled item rather than a hypothetical one. Stage 4 is
behind you, so the remaining condition is that the code stops moving; nothing real gets
deposited before an auditor has been through it.

The two unresolved factual questions in the README have also been promoted. When this was
going to be a showpiece they affected how you would *describe* Remit. Now one of them —
whether an EIP-7702-delegated EOA still counts as an EOA for Arc's Memo path — affects
whether part of the audit trail works, so it needs an answer before launch rather than
before publication.

One gap stage 4 opened rather than closed: it exercised exactly **one** shape of mandate —
a single spending window and a single approved recipient, with no cosigner, no
agent-identity check and no credential check. Everything else in the contract has passing
tests and zero real transactions behind it. The mandate you granted is still live with 1.90
of budget left, so those paths can be exercised without granting anything new. That is the
most useful next piece of work in this folder.

## When you get stuck

Paste the command you ran and everything it printed, and tell me which stage you are on.
That is enough: I have the whole project in front of me, so there is nothing for you to
diagnose.

If this stops being fun, say so. You have said this is meant to hold real money, which is a
legitimate goal and also the demanding version of the project, so it helps to know that a
working testnet deployment with good documentation is a complete, respectable thing to have
built on its own, and you now have exactly that. It is a fine place to stop or pause if you
decide to, and everything from here on is optional in a way that nothing before it was.

## Small glossary

The other documents use these without explaining them.

A **contract** is a program stored on a blockchain that anyone can call and that cannot be
secretly changed. **Solidity** is the language it is written in, and to **compile** is to
turn that source code into something the blockchain can execute, which is also the step
that tells you whether your code makes sense at all.

**Arc** is the blockchain this targets — built by Circle, the company behind USDC, and
unusual in that USDC is both the money and the fee you pay to transact. A **testnet**
is a full copy of it running on fake money for practice. **Gas** is that transaction
fee. The **faucet** hands out free testnet money.

An **EOA** is a normal wallet controlled by a private key, as opposed to a wallet
that is itself a contract. An **allowance** is the standard permission slip letting one
address move another's tokens — Remit exists because an allowance alone is a much
weaker limit than people assume, which `DESIGN.md` explains at length.

**Foundry** is the toolkit; **forge** is its command. A **fuzz test** throws thousands
of random inputs at the code hoping to find one that breaks it. An **invariant** is
something that must be true no matter what happens, and an invariant test lets the
computer choose the sequence of actions while checking the statement still holds.
