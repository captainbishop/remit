# Security policy

Remit moves real money, and its version 1 contract is deployed, verified, and immutable at
`0x3744E93B9e796E05CB66311d897559B6F3860196` on Arc Testnet. There is no upgrade path and no admin
key, so a reported flaw in a deployed contract cannot be patched in place. The response to a
confirmed flaw is to disclose it and deploy a corrected contract at a new address, since the
deployed version cannot change. Read `IMMUTABILITY.md` for what that constraint means for anyone
holding an allowance.

## Status

**Not audited.** No third party has reviewed this code. Do not put money behind it on a public
network. The repository publishes its own threat model in `THREAT-MODEL.md`, with 51 recorded
findings, and a full test and mutation record under `evidence/`, so a reader can judge the current
state from primary evidence rather than from a claim made here.

## Reporting a vulnerability

Report privately, never in a public issue or pull request, so a fix or a migration can land before
the flaw is widely known. Use GitHub's private vulnerability reporting on this repository: open the
Security tab and choose "Report a vulnerability". That channel reaches the maintainer directly and
keeps the report confidential until it is resolved.

A useful report names the affected function or file, the condition that triggers the problem, the
effect on a payer's funds or on a mandate's rules, and a transaction or test that reproduces it
where possible. A reproduction against the test suite or a local fork is more valuable than a
description, because it can become a regression test.

## What to expect

The maintainer will acknowledge a report, confirm or dispute the finding against the code, and
record the outcome. A confirmed flaw in deployed code is handled by publishing the finding and,
where it matters, deploying a corrected contract at a new address, since the deployed version
cannot change. Credit goes to the reporter unless they ask otherwise.

## Scope

The contract under `contracts/`, the reference model under `reference/`, and the deployment and
verification process are in scope. The test doubles under `test/` model external systems, namely
USDC and the ERC-8004 registries, and are in scope only where their behaviour informs a real
finding about the contract. Third-party dependencies, Arc itself, and the USDC token contract are
out of scope here; report those to their maintainers.
