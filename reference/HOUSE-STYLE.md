# House style for Remit's documentation

Remit's documents are read by two audiences: a security auditor deciding whether the contract is
safe, and a payer deciding whether to grant an agent authority over their money. Both need a
technical record. Neither needs the record narrated.

This file is the style contract. `reference/prose-check.py` enforces the mechanical half of it and
exits non-zero when a rule matches, so a document cannot drift back without the check going red.

## What must not appear

**"Gated", "gating", and "gates" as a verb.** A precise verb always exists: *requires*, *refuses*,
*restricts*, *validates*, *checks*, *rejects*. For the noun, prefer *check* or *requirement* — "the
credential check", "the identity requirement". Identifiers are exempt because they are names, not
prose: `Gates.t.sol`, `_checkIdentity`, the `mutation gate` tooling, `mutation-gate-sol.py`, and the
`mutgate-*.log` filenames. The two ERC-8004 checks are a case of this rather than an exception to
it. They are declared in `contracts/MandateManager.sol` as the structs `IdentityGate` and
`CredentialGate`, so "the identity gate", "the credential gate", "the `F_IDENTITY` gate" and "the
two ERC-8004 gates" all name a type that exists in the source. Renaming those in prose alone would
leave the documentation describing identifiers a reader cannot find, so they stay, and the
exemptions sit in `GATE_OK` inside `reference/prose-check.py` where the reason is recorded beside
them.

**Definition by denial.** Do not introduce a fact by first denying its opposite. "This is not a
custody model, it is an allowance model" becomes "This is an allowance model." Negation stays where
the negative fact is itself the point — "the contract never holds funds" and "the registry is not
read at grant time" are statements of behaviour and belong. Contractions do not appear at all;
write *is not*, *does not*, *cannot*.

**Staccato.** Consecutive sentences under six words, and sentence fragments, read as notes rather
than as a document. Merge them. No sentence begins with *And*, *But*, *So*, *Which*, *Because*,
*Plus*, *Also*, or *Except*. Where a run of fragments is really a list, make it a list or a full
sentence with a colon.

**Fluff.** *honestly*, *genuinely*, *truly*, *frankly*, *obviously*, *clearly*, *simply put*,
*needless to say*, *at the end of the day*, *in a nutshell*, *to be fair*, *to be clear*, *worth
noting*, *worth recording*, *worth keeping*, *the honest answer*. If a sentence needs "honestly" to
be believed, the surrounding text has a different problem.

**Commentary on the writing.** *the reusable part*, *the part worth keeping*, *the lesson*, *the
takeaway*, *the standing trap*, *load-bearing*, *smoking gun*, *stated once*, *for the record*.
State the content and let the reader decide what to keep.

**Colloquialisms.** *somebody*, *anybody*, *nobody*, *basically*, *pretty much*, *sort of*, *kind
of*, *on sight*, *handy*, *neat*, *nice*, *messy*, *ugly*, *awkward*, *a thing*. *Quietly* and
*silently* have a real technical meaning — a failure that produces no error — so write that
instead: "without reverting", "with no error", "without a failing test".

**First-person error narration.** No *the mistake was mine*, *I got this wrong*, *it cost us*, *I
assumed*. Corrections are recorded impersonally and with their evidence: "An earlier version of
this section reported eight vacuous bodies. All eight were false positives, caused by a
hand-listed assertion vocabulary; the derived vocabulary reports zero." Documents avoid the first
person entirely.

**Notes to the author.** A published document states what has been established and what has not,
and both statements are addressed to the reader. An instruction addressed to whoever writes next
belongs in a task list instead: *TODO*, *TBD*, *recalled from memory*, *not verified here*, *check
the current figure before citing one*, *come back to this*. `DESIGN.md` carried one of these in its
opening section for several weeks — "(Recalled from memory, not verified here — check current IC3
reporting before citing a figure.)" — attached to a sentence that quoted no figure at all. The
repair is to have the document take the position itself: "This document quotes no figure for that,
because none was verified while writing it; the FBI's IC3 annual report is where to check one."
Declaring a limit to the reader is the stronger form and is required throughout these documents, so
this rule turns on who the sentence addresses and in what mood, never on the admission itself.

**Informal or interrogative headers.** A header is a descriptive noun phrase. "Status, honestly"
becomes "Status". "Has a bug been found since deployment?" becomes "Bugs found since deployment".

## What must be preserved exactly

Every number, hash, address, file path, line reference, error name, function name, command, code
block, table value, and link. A wording change that alters a figure is a defect, not an
improvement. `reference/prose-check.py` does not verify this; the numeric-preservation diff in
the commit for this pass does, and any future prose pass should repeat it.

## What is deliberately allowed

Long sentences, semicolons, and subordinate clauses. Precision costs words, and the alternative to
a long accurate sentence is usually several short inaccurate ones. Bold stays for defined terms,
table emphasis, and the one claim a section turns on. Em dashes are permitted sparingly; a comma or
a semicolon is usually better.

## Running the check

```
python3 reference/prose-check.py                  # every prose file, summary
python3 reference/prose-check.py README.md        # one file, with every hit listed
python3 reference/prose-check.py --list           # every file, with every hit listed
```

Each hit is a candidate for reading rather than a verdict. Technical negations, the exempt
identifiers, and short sentences that carry a whole clause will match and are correct as written.
