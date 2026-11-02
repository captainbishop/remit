# Contributing

Remit is a smart-contract project that moves real money, so every change needs evidence that it is
correct. This guide covers the toolchain, the checks a change must pass, and the house rules for
prose and commits.

## Toolchain

The contract and its tests build with Foundry under `solc` 0.8.28. The reference model and the
prose and evidence checkers run on Node and Python 3. Install Foundry from getfoundry.sh, then:

```
forge build                            # compile the contract
forge test                             # the Solidity suite
forge coverage                         # line, statement, branch, function coverage
node --test reference/policy.test.js   # the JavaScript reference model
```

## Checks a change must pass

A change to the contract keeps the Solidity suite and the reference model green and holds or
improves coverage. A change to documentation passes the house-style check and the citation and
fact checks:

```
python3 reference/prose-check.py             # house style
python3 reference/line-citations.py          # every "line NNN" pointer still resolves
python3 reference/fact-diff.py HEAD <file>   # no number, hash or address drifted
```

`reference/HOUSE-STYLE.md` states the prose rules in full, and `prose-check.py` enforces the
mechanical half of them. A documentation change that alters a number, hash, address, path, or
error name is a defect unless that change is the point of the edit, in which case the commit
message says so.

## Commits and pull requests

Keep a commit to one coherent change, with a message that states what changed and why. A change
that touches the contract names the test that covers it. Reference a finding by its number in
`THREAT-MODEL.md` where one applies. Do not push to `main`; open a pull request, and run the checks
above before you do.

## Security

Report a suspected vulnerability privately through the process in `SECURITY.md`, never in a public
issue or pull request.

## Scope and status

The contract is unaudited, and version 1 is immutable on Arc Testnet. Read `START-HERE.md` for the
layout of the repository and `IMMUTABILITY.md` for what the no-upgrade constraint means. Discuss a
large new feature in an issue before implementing it, so the design and its threat surface can be
reviewed before code is written.
