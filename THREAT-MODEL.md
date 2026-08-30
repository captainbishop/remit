# THREAT-MODEL.md

**Status: FIRST PASS, 2026-08-26. Not an audit.** Written by the same author as the
contract, which is the reason it cannot substitute for the professional audit this project
still requires before any mainnet deployment. Its purpose is narrower: to make the search
for defects *systematic* instead of opportunistic, and to write down what Remit protects,
what it does not, and which areas remain unexamined.

> **Line numbers in this file are marked `v2:NNN` and are anchored to commit
> `92445dd`**, the commit that landed task #22 and the tree that is green at 157/157.
> Recover the source they refer to with
> `git show 92445dd:contracts/MandateManager.sol`. That is a deliberate exception to the
> repo-wide convention recorded in `FORGE.md` (unqualified line numbers into
> `contracts/MandateManager.sol` mean the `v1.0.0-arc-testnet` tag), because this
> document is about the code being changed rather than about the code that is deployed.
> Anchoring to a commit rather than to "the working tree" is the point: the fixes this
> document argues for will move every line in it, and a reviewer needs to be able to
> reach what was actually read. Function names are used in preference to line numbers
> wherever one will do, since a function name does not move at all.
>
> **This anchor was `f2d3b35` and had already gone wrong, in one day, which is recorded
> here rather than corrected without comment.** #22 added 39 lines to the contract
> (1,171 → 1,204) and wrote *post*-#22 numbers into a document whose banner still said
> pre-#22 — so five of the nine distinct numbers here landed on a blank line under the
> banner's own recovery command (`v2:424`, `v2:433`, `v2:446`, `v2:608`, `v2:1012`) while
> the other four were correct only against the old blob (`v2:432` → `465`,
> `v2:636-641` → `669-674`, `v2:649` → `682`, `v2:664` → `697`). Both halves were verified
> by printing each line from both blobs, and all four stale citations are corrected above.
> The banner above already half-stated the rule: a citation anchored to a commit is
> only safe while nothing edits the document, and *this* document exists in order to be
> edited. Prefer the function name; when a line number is unavoidable, quote the line's
> text beside it so a mismatch is self-announcing rather than silent.
>
> **The anchor was re-checked on 2026-08-26 when #16c added F23–F26, and it still holds:**
> `git diff 92445dd -- contracts/MandateManager.sol` is empty, so the anchor blob and the
> working tree are byte-identical and `v2:NNN` is unambiguous either way. Every number that
> sweep added was printed out of `git show 92445dd:contracts/MandateManager.sol` before being
> written down, which caught one wrong citation carried in from a working note — `v2:856-863`
> for the 6-decimal truncation note, which actually lives at `v2:1077-1084`; 856-863 is the
> credential `try`/`catch` body and has nothing to do with decimals.
>
> **That byte-identity ENDED on 2026-08-27, when #28 landed F15 and F16.** The anchor itself
> is unchanged and every `v2:NNN` in this file still resolves against `92445dd` exactly as it
> always did — but it is no longer *also* the working tree, so the sentence above must be read
> as history. `contracts/MandateManager.sol` went 1,204 → 1,376 lines, `approveCosign` was
> deleted outright and `spendHash` lost a parameter, which means every citation into the
> co-signature region now points at code that has been replaced. Those citations are kept
> rather than repointed, because a finding's evidence is the code that had the defect. Where
> this document describes what SHIPPED instead, it names functions and never lines, per the
> rule the first banner paragraph already states and this is now the second demonstration of.
>
> **The test tree moved with it, so "green at 157/157" above is now also history.** #28 took the
> source declaration count to 165 and the custom-error count from 31 to 33, and `forge test` has
> not been run since, so there is currently **no** green figure for the working tree — only a
> source count. §5's four mechanical checks were re-derived against it and say so in place.
> Nothing in this document should be read as claiming a v2 suite has passed; #14 owns that.
>
> **2026-08-28, F17: there are now THREE blobs, and this banner names only one of them.** F17 is
> written but *not committed*, so a reader has to distinguish the anchor, `HEAD`, and the working
> tree, and no two of the three agree:
>
> | | lines | `error` decls | `approveCosignFor` |
> |---|---|---|---|
> | `92445dd` — this banner's anchor | 1,204 | 31 | **absent** |
> | `4661bad` — `HEAD`, F15+F16 | 1,381 | 33 | present |
> | working tree — F17 on top | 1,501 | 34 | present |
>
> Three corrections fall out of that, and they are corrections *to the paragraphs above*, which is
> the pattern this banner has now demonstrated three times. **(1)** "went 1,204 → 1,376" is 5 short
> of the blob that actually landed; 1,376 was a working-tree reading taken before `4661bad` was
> written, and the committed figure is 1,381. The five lines are unattributed and the discrepancy
> is left visible rather than overwritten. **(2)** "from 31 to 33" was correct *for `HEAD`*; the
> working tree is at 34, F17 having added `CosignNotRequired`. **(3)** "there is currently **no**
> green figure for the working tree" has been retired: `forge test` was run on 2026-08-28 and the
> tree is **green at 178/178**, a figure derived twice — as the sum of the thirteen per-suite
> lines and again from the run's own summary — and matched by
> `grep -cE '^    function (test|invariant)'` over `test/*.t.sol`.
> #14 still owns re-measurement; what it no longer owns is the existence of a green run.
>
> **The F17 block below cites bare line numbers, and they are WORKING-TREE numbers, not `v2:NNN`.**
> This is stated rather than fixed because the alternative was to describe a seventeen-guard
> inventory without saying where the guards are. The rule the first paragraph states — prefer the
> function name — is why the numbers appear *beside* quoted guard text everywhere they appear. The
> danger is concrete, not theoretical: `approveCosignFor` does not exist in `92445dd` at all, so
> the banner's own recovery command cannot reach any of them, and it fails **with no error** rather than
> landing on a blank line the way the `f2d3b35` breakage did. Checked one by one against the anchor
> blob, **eight of the nine land on a comment line and the ninth (`1194`) on a blank one**: `763` is
> `// any timestamp the chain can produce.`, `1101` and `1136` are `///` lines about the payer's
> allowance and about `DuplicateMandate`, `1132` is a bare `///` with nothing on it at all, `1130` is
> `///` prose about bounded terms, `1164` is a comment about which payer is read, `1173` is a comment
> about the largest amount `spend` accepts, and `1189` is a comment about sorting by keccak hash.
> Not one of them is code, and not one announces itself. `TotalSpentCeiling` is the single guard
> that exists in both blobs, and even it has moved: `92445dd:682`, working tree `763`. To reach what
> the F17 block read, use the working tree, or `4661bad` plus the F17 diff.
>
> **Do not "fix" the other bare-looking numbers — they are prefixed, and the prefix carries.** A
> grep for four-digit citations also returns `` `713` `` in §4 and §6, which look unanchored on
> their own line but are the tail of a `v2:`-prefixed run (`v2:614`, `615`, `690`, `713`) and are
> correct against the anchor. This was written wrong here first, on exactly one grep hit and
> without reading the line above it, which is the same mistake the document keeps recording in
> other people's code: **a grep returns a match, not a meaning.** The unanchored citations are all
> F17's and all inside §4 — **nine distinct numbers over eleven instances** (`763`, `1101`, `1130`,
> `1132`, `1136`, `1164`×2, `1173`, `1189`×2, `1194`), eight of them in the F17 finding and three
> in *"What a green suite cannot mean"*. That count is itself a correction: the first pass here
> said "five", because it was derived with a pattern matching only `at NNN` and `lines NNN` and so
> missed the parenthesised `(1132)`, `(1136)`, `(1173)` and the sentence-initial `1189`. Every one
> of the nine carries its error name or its condition text alongside it, which is the mitigation
> the first banner paragraph asks for.
>
> **2026-08-28, F19+F25: the three blobs are still three, they are not the same three, and after
> `65f05d8` all three are actually blobs — none of them is a working tree any more.** F17 committed
> as `088813d`, which is
> the single most useful consequence of that commit for this document: the nine bare numbers
> described two paragraphs above as "WORKING-TREE numbers" have stopped being working-tree numbers
> and become citations into a blob. All nine were re-checked against it one at a time and all nine
> land on the code they claim — `763` and `1164` on the two `TotalSpentCeiling` guards, `1132` on
> `Revoked`, `1136` on `Expired`, `1173` on `CosignNotRequired`, `1189` on the
> `validUntil > m.expiresAt` `BadDeadline`, `1101` on `function approveCosignFor(`, `1130` on the
> comment it quotes, `1194` on the function's closing brace. **The recovery command for them is
> `git show 088813d:contracts/MandateManager.sol`**, and that is a real command that works, unlike
> the banner's `92445dd` one, which cannot reach `approveCosignFor` at all and fails with no error.
>
> | | lines | `error` decls | `SelfPayment` |
> |---|---|---|---|
> | `92445dd` — this banner's original anchor | 1,204 | 31 | absent |
> | `088813d` — F15+F16+F17 | 1,501 | 34 | absent |
> | `65f05d8` — `HEAD`, F19+F25, **byte-identical to the working tree** | 1,523 | 35 | present |
>
> **The third row is why this table exists at all.** It started as three rows with the working tree
> as the last one; F19+F25 committing turned that row into a named blob, which is the only form a
> citation survives in. Read the table top to bottom as a history of what this file's numbers have
> meant, and cite `65f05d8` for anything about today's code.
>
> **What that costs: the nine no longer match the working tree either.** F19 inserted its error
> declaration above them and its two guards among them, so every one of the nine has moved — by
> **+15** for those between the new `error SelfPayment();` and the cosign mirror (`1132`→`1147`,
> `1136`→`1151`), and by **+22** for those after it (`1164`→`1186`, `1173`→`1195`, `1189`→`1211`,
> `1194`→`1216`); `763`→`778` and `1101`→`1116`. Those deltas are recorded rather than applied,
> because the numbers are correct as written against the blob they now name and rewriting them
> would make them wrong. **The F17 finding's own text was updated to say `088813d` explicitly and
> to give the working-tree bounds `1116–1216` for the guard count**, which is the one place a
> reader needs today's tree rather than yesterday's blob.
>
> **F19's own citations — `710` and `1160` — are ANCHORED as of `65f05d8`, so this file has no
> floating line numbers left.** `git show 65f05d8:contracts/MandateManager.sol` is 1,523 lines and
> 35 `error` declarations, and both numbers were checked against it one at a time rather than
> assumed to have survived the commit. The blob table above is therefore four rows now, not three,
> and `65f05d8` is the row that agrees with the working tree. **`grep -n 'revert SelfPayment'
> contracts/MandateManager.sol` remains the better recovery command** than either number, because
> the guard is a single distinctive line in each function — `if (recipient == m.payer) revert
> SelfPayment();`, identical text in both places — and per the first paragraph's rule the function
> names are `spend` and `approveCosignFor`, which do not move at all. The next commit that touches
> the contract makes `710` and `1160` stale again; the grep will not go stale.
>
> **The green figure is now 182/182, not 178/178.** Derived the same two ways as before — the run's
> own summary line and the sum of the thirteen per-suite lines — and matched by
> `grep -chE '^    function (test|invariant_)' test/*.t.sol`, which is the corrected pattern: the
> earlier `^    function test` form returns 179 here because it misses the three `invariant_`
> functions in `WindowInvariant.t.sol`. That undercount was made and caught during F19, and
> #14 still owns re-measurement.
>
> **F19 and F25 changed nothing in the other seven markdown files, and that is a swept result, not
> an assumption.** `DESIGN.md`, `README.md`, `IMMUTABILITY.md`, `FORGE.md`, `GAS-ABSTRACTION.md`,
> `PRIVACY.md`, `START-HERE.md` and `evidence/README.md` were grepped for guard counts, error
> counts, and every spelling of self-payment, self-transfer and `recipient == m.payer`. **Not one
> of them makes a claim either fix touches** — the only stale numbers there are the v1-era `140
> tests` and `57 tests` figures, which predate v2 entirely and belong to #14's relabelling pass, not
> to this one. The F19/F25 blast radius inside the docs is therefore exactly three files: this one,
> `CHANGELIST.md` and `L3-VAULT.md`. Recorded so the next fix does not re-run the same eight greps
> to learn the same thing.
>
> **2026-08-28, F27 and F28: for the first time since #28 began, a new finding's contract
> citations are unambiguous.** Both cite bare `contracts/MandateManager.sol:NNN` rather than
> `v2:NNN`, on the F17 precedent above — but the hazard that precedent was hedging against is
> absent here, because **neither finding changes the contract.** `git diff --stat 65f05d8 --
> contracts/MandateManager.sol` is empty, so the blob table's last row and the working tree are
> byte-identical at 1,523 lines, and every number in F27 resolves identically against either.
> They were printed out of the working tree one at a time before being written down — `276`,
> `538`, `646`, `651`, `652`, `700`, `725`, `929`, `941`, `942` — and `_checkIdentity`'s
> single-caller claim was derived (`grep -c _checkIdentity` returns 2: the definition and the one
> call), not assumed. As always the function names are the durable citation: `_checkIdentity` and
> `createMandate` do not move.
>
> **What moved instead is the model and its suite, which this banner has never had to track
> before.** `reference/policy.test.js` went **72 → 76 tests**, all passing, and
> `reference/mutation-gate.js` grew a second target. The Solidity figure is untouched at
> **182/182** because no `.sol` file was edited — stated because "the tests went up by four" and
> "the suite is still 182" are both true here and describe different suites. The gate figures are
> the new evidence: `approveCosignFor` **22/22** (re-run as a regression on the refactor, not
> quoted from the earlier run) and `evaluate` **31/31**, from **31 mutants: 24 removals and 7
> injections**.
>
> **Two of those 31 kills are crash-kills, and the gate reports them separately on purpose.**
> Neutering `evaluate`'s `UNKNOWN_MANDATE` or `CREDENTIAL_MISSING` return leaves the next line
> dereferencing the very value the guard proved absent — `mandate.revoked` off `null`,
> `att.validator` off `null` — so the tests that assert those denials throw before reaching their
> assert. **That is structural and not a coverage gap:** no test written from outside the function
> can reach an assertion once the guard is gone. An assertion-kill proves the suite knows the
> right answer; a crash-kill proves only that it would not stay green. Both are kills; only the
> first is what a mutation gate is for, so the figure to quote is "31/31, two of them crash-only" rather
> than a bare 31/31.
>
> **2026-08-28, F27+F28 ANCHORED as of `d4f15ac`, and for once nothing had to be re-checked.**
> That commit carries `THREAT-MODEL.md`, `CHANGELIST.md`, `reference/mutation-gate.js` and
> `reference/policy.test.js` — and **neither of the two files F27 and F28 cite is among them.**
> `git diff --stat 01541e7 d4f15ac -- reference/policy.js` is empty and so is the same command for
> `contracts/`, so both findings' citations resolve against **`65f05d8`**, which is already the
> blob table's last row and is the commit that last touched *both* cited files. F28's `:578` was
> printed out of `git show d4f15ac:reference/policy.js` and reads
> `mandate.identity.expectedOwner &&`, which is the bare-truthiness test the finding is about.
>
> **The general rule this instance illustrates, since the last three commits each paid for it:** a
> finding's line numbers are floating until a commit exists, and anchoring them is a separate step.
> What made it free this time is that the commit changed **no cited file** — so the lowest-cost way to
> keep citations anchored is to keep evidence and subject in different commits, which is what
> "no `.sol` file is touched" bought here beyond sparing a `forge` run.
>
> **2026-08-29, F29–F37: the blob table gains a fifth row, and for the first time that row is
> `HEAD`, the working tree, and the subject of nine live findings all at once.** `af9df40` is
> `HEAD`, dated 2026-08-29, and `git diff af9df40 -- contracts/ reference/ test/ script/` is empty.
> The only modified file in the tree is this one, which cites nothing inside itself, so every
> citation in F29 through F37 resolves identically against the blob and against the working copy,
> and the hazard the four paragraphs above keep paying for is absent again — for the second commit
> running, and for the opposite reason: `d4f15ac` was safe because it touched no cited file, and
> `af9df40` is safe because it touched every cited file and then nothing else did.
>
> | | lines | `error` decls | `UnrecoverableRecipient` |
> |---|---|---|---|
> | `92445dd` — this banner's original anchor | 1,204 | 31 | absent |
> | `088813d` — F15+F16+F17 | 1,501 | 34 | absent |
> | `65f05d8` — F19+F25 | 1,523 | 35 | absent |
> | `af9df40` — `HEAD`, F29–F37, **byte-identical to the working tree** | 2,043 | 37 | present |
>
> **The two new errors are `NonceReserved` (F30) and `UnrecoverableRecipient` (F29)**, derived by
> diffing the sorted `error` declarations of `af9df40` against its parent rather than read off the
> commit message.
>
> **Most of that growth is not findings, and saying so is the point of the row.** 1,523 → 2,043 is
> +520 lines, and only **229** of them are `af9df40`'s. The other 291 arrived in three commits that
> changed no behaviour — `bda6dcf` and `51c5750` (NatSpec on every externally visible declaration,
> then the interfaces and every public constant) and `7223e73` (one uncovered branch closed, two
> lint notices annotated). A contract that grew by a third since F19 invites the reading that there
> is a third more surface to attack, and the derivation says otherwise: the majority of the new
> lines are comments a reader can check but an attacker cannot call.
>
> **The green figures are 207 Solidity cases and 92 model tests, and the Solidity one needs its
> provenance stated rather than quoted.** It comes from `mutgate-checkIdentity.log`'s control line,
> `baseline: 207 passed, 0 failed (17s)` — a real run of the whole suite, but one taken to be a
> *control* for a mutation gate rather than a measurement in its own right. #14 still owns a
> standalone `forge test`. What has been done here instead is reconcile it against source two ways:
> the tree declares **204 functions named `test*` plus 3 named `invariant_`**, which is 207 exactly,
> and the per-file distribution sums to the same. **The 182/182 figure four paragraphs above is now
> history**, as is 178/178 and 177/177 before it. The model went **76 → 92 tests**, all passing.
>
> **One thing this row cannot say is that the suite has caught up with the guards.** §5's owed-work
> tally rose in the same commit that fixed eleven findings — six tests now, five before — because
> two of `af9df40`'s new guards are asserted by nothing yet. A blob row showing more code, more
> errors and more tests is compatible with more untested behaviour than the row before it, and in
> this case that is what it shows.
>
> **2026-08-29, the repository-wide wording audit: the model moved and the contract held its
> line count.** `contracts/MandateManager.sol` is 2,043 lines before and after, and
> `git diff --numstat` reports 350 lines added against 350 deleted, the same figure on both
> sides. That was held deliberately: 209 pointers across this repository resolve to that file
> by line, and holding the count is what keeps the newest of them usable. Five are checked
> against the working tree, and of the 204 anchored to a historical revision, the 36 at
> `af9df40` land on the same numbers in the working tree because `af9df40` and the tree are
> both 2,043 lines. The rest sit at earlier widths and resolve inside the blob they name: 101
> at `92445dd` (1,204 lines), 66 at the `v1.0.0-arc-testnet` tag (873), and one at `9fa7ece`
> (1,537). The model carries no such load, so it took four one-line insertions —
> `reference/policy.js` went **1,444 → 1,448** and `reference/policy.test.js` **2,387 → 2,392**.
>
> **The eight citations into `reference/policy.js` in this file are anchored at `af9df40`, and
> the pass itself landed as `e7922c1`.** `git diff af9df40 d75355c -- reference/policy.js` is
> empty, so every one of the eight resolved unchanged for as long as `d75355c` was the tip. In
> `e7922c1` each has shifted by the number of insertions that precede it: `:271-282` by **+1**,
> `:366` and `:394-411` by **+2**, `:578`, `:634`, `:696` and `:773` by **+3**, and `:1256` by
> **+4**. The insertion points in the `af9df40` file are 115, 310, 518 and 1167, one line at
> each. Those deltas are recorded rather than applied, for the reason the F19 paragraph above
> gives: each number is correct against the blob it names, and rewriting it would make it wrong.
> The ladder is how to cross from one blob to the other. **`reference/policy.test.js` is cited by
> no line number anywhere in the repository**, which was checked by grep over every tracked
> `.md`, `.sol`, `.js` and `.py` file rather than assumed, so its five new lines cost nothing.
>
> **2026-08-30, the Solidity mutation gate finished: eleven of eleven targets, 89 of 89 mutants.**
> The green figure is now **209 Solidity cases and 92 model tests**, so the 207 five paragraphs
> above is history, as 182/182, 178/178 and 177/177 were before it. Derived the same two ways as
> every figure in this banner: the tree declares **206 functions named `test*` plus 3 named
> `invariant_`**, and both of the day's gate logs open with `baseline: 209 passed, 0 failed`. The
> per-file distribution sums to the same — `Cosign` 47, `Creation` 44, `Bounds` 29, `Views` 25,
> `Gates` 24, `Windows` 14, `Idempotency` 13, `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4,
> `Base` 0 — and the two files that moved are the two that gained a test, `Cosign` 46 → 47 for
> `test_f29_approvingTheContractOrTheTokenAsRecipient_isRefused` and `Creation` 43 → 44 for
> `test_createMandate_eachCredentialFieldWithoutTheFlag_isRefused`.
> Eleven files and thirteen suites both still hold, for the reasons
> `reference/vacuity-check.py:58-67` gives.
>
> **Eight targets and 84 mutants ran, all at that same baseline.** Six came back clean —
> `approveCosignFor` 24/24, `createMandate` 27/27, `spend` 19/19, `_checkAndCommitWindows` 1/1,
> `spendHash` 1/1, `constructor` 1/1 — and two returned one survivor each, `_checkCredential:1261` and
> `spendableAcross:2010`. Both are **equivalent mutants**, a fourth class this document had not met:
> the successor guard refuses the same input under the same error name, so no test can ever kill them.
> §5 carries the reasoning and the mechanism that holds them, and two `--only` runs closed the two
> survivors from the day before. **`constructor` ran for the first time in the gate's existence**,
> which moves the contract's one defence against a permanently mis-wired deployment inside a clean
> claim instead of outside every one.
>
> **The contract is 2,043 lines before and after, and every line pointer in this repository still
> resolves.** The day's only change to `contracts/MandateManager.sol` was a corrected comment above
> `:2010` — the mutation run contradicted a sentence claiming that guard is what makes "the payer of
> nothing" unreachable, which the loop's own check does anyway. Six lines were rewritten as six, and
> `python3 reference/code-unchanged.py HEAD` reports `540 code lines, all identical, none moved`.
> **A survivor is also a claim-checker**: the sentence explaining why a guard matters is exactly the
> sentence a mutation run is able to contradict.
>
> **2026-08-30, later the same day: F22's property reaches Solidity, and the census is 91 mutants.**
> The suite is **212 cases** — 209 named `test*` plus 3 named `invariant_`, which
> `reference/vacuity-check.py` reports directly — with `Cosign` 47 → 48, `Bounds` 29 → 31 and the
> other eight case-bearing files unmoved.
> `contracts/MandateManager.sol` is **byte-identical to HEAD**, so the census moved because the gate
> learned a property rather than because the contract grew a guard. That is a first for this banner,
> and it is the honest reading of the figure: a mutant count is a property of the pair (contract,
> operator set) and not of the contract alone.
>
> **What was missing.** `recipient == m.spender` is legal, and it is the case F22 exists to
> document — a delegate paid by its own mandate is most of what mandates are for. That property was
> asserted in `reference/policy.test.js` by name and nowhere in Solidity. No case among the 209 had
> ever named the delegate as a recipient, checked by grep over `test/` rather than assumed, so
> `if (recipient == m.spender) revert SelfPayment();` injected into `spend` would have survived a
> fully green suite. The guard it imitates is real and one identifier away:
> `contracts/MandateManager.sol:983` is F19's `if (recipient == m.payer) revert SelfPayment();`, and
> `:1476` is its mirror. **`payer` and `spender` in that position are opposite claims sharing one
> error name**, which is why F19's condition rather than its name is the claim.
>
> **Three cases close it, and both paths are mutated now.** `test/Bounds.t.sol` gained
> `test_f22_theSpenderMayBePaidByItsOwnMandate`, which asserts the money arrived at the delegate and
> left the payer instead of asserting that some revert failed to fire, and
> `test_f22_anAllowlistIsWhatStopsTheSpenderBeingPaid`, which pins `F_ALLOWLIST` as the only
> mechanism that refuses a delegate.
> `test/Cosign.t.sol` gained `test_f22_approvingTheSpenderAsRecipient_isAccepted`, the one case on
> the approval path that must be **accepted** — and F17's `_assertSameRefusal` parity could never
> have reached it, because parity checks that the two paths answer alike, so folding the spender
> into `SelfPayment` would make both paths refuse and report them in agreement.
>
> **The runs, at baseline 212 passed, 0 failed in both.** `spend`'s injection was caught by three
> cases, 3 failing — all three of the above, since each moves money to the delegate through
> `spend`. `approveCosignFor` returned **5 of 5 caught**: its four F17 injections unchanged, which
> is a regression check rather than a new result, and the fifth killed by exactly one case,
> `test_f22_approvingTheSpenderAsRecipient_isAccepted`. **A single killer is a fact to record rather
> than a result to be satisfied by** — delete that one case and the mirror injection survives again,
> with nothing else among the 212 noticing.
>
> **Both runs were narrowed, and each log says so on its closing line.** `--injections` is new today
> and builds a target's injection cases without its removals, taking these two questions from 45
> mutants to 6. The licence is directional, in that adding a case can only enlarge the killer set,
> so the bare removal census recorded earlier this same day cannot have regressed. The guard against
> misreading is the gate's own `SCOPE: injections only` block, which names the 19 and 20 removals it
> declined to build. **A narrowed log is not a census, and the gate now refuses to let one look like
> one.** The census stands at **91 — 85 removals plus 6 injections**, one of the six on `spend` and
> five on `approveCosignFor`, against the 89 this banner recorded earlier the same day.
>
> **2026-08-30, #24: four findings closed, and two of their own fix sketches were falsified on the
> way.** F3, F9, F10 and F11 all landed, taking the fixed-in-code bucket from eighteen to
> **twenty-two of thirty-seven**. `contracts/MandateManager.sol` is **2,138 lines and 38 errors**,
> from 2,043 and 37 at `db1c08c`, both counted from the file. The suite is **219 cases** — 216 named
> `test*` plus 3 named `invariant_`, which `reference/vacuity-check.py` reports directly. The
> per-file distribution sums to the same: `Cosign` 48 → 53, `Bounds` 31 → 32, `Views` 25 → 26, and
> the other seven case-bearing files unmoved at `Creation` 44, `Gates` 24, `Windows` 14,
> `Idempotency` 13, `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4 and `Base` 0. The model is
> **94 tests**, all passing, so 212 and 92 are history, as 209, 207, 182, 178 and 177 were before
> them.
>
> **The assertion figures moved further than the case count, and the checker's printed breakdown
> does not sum to its own total.** `reference/vacuity-check.py` now reports **402 primitive
> assertion calls** against 362 at `af9df40`, **92** in-code `vm.expectRevert` with **0** bare
> against 90, and **seven** assertion-bearing helpers against six, `payReverts` alone standing at 82
> call sites. Its components sum to **408**: `assertRevertedWith` appears in the list for
> information and stays out of the total, under the same rule §5 records for the 287-versus-290
> discrepancy in the anchor — every `assert*(` across the `.t.sol` files, less the denial helper
> counted once already. **A breakdown that has to be read with a rule will be re-added wrongly**, so
> the rule sits here beside the figure rather than only in the tool's output.
>
> **Both mutation censuses moved, and one of the moves has no fix behind it.** The Solidity census is
> **95 — 89 removals plus 6 injections** over eleven targets, from 91, and the four new sites are
> F3's two `SpendCountCeiling` guards and F11's `UnknownMandate` and `BadConfig` in
> `withdrawCosign`. The JS census is **82**, at 27 for `approveCosignFor`, 35 for `evaluate` and 20
> for `createMandate`, up from 78, and only two of those four new mutants came from F3. The other two
> came from a header in `reference/mutation-gate.js` that said 18 for `createMandate` while the file
> held 20: the `throw new Error(` spelling went 28 → 35 in `af9df40` and the target had not been run
> since, so a census sat restated rather than derived for a day. The run is clean at 20 of 20, so no
> test was ever missing, and the header now records the correction against itself.
>
> **Four targets were re-run, and the four were chosen by a comparison rather than by a reading.** A
> code-only diff of every gate target's body against `db1c08c` named `spend`, `approveCosignFor`,
> `withdrawCosign` and `revoke`. `revoke` is the one a quick reading would have skipped: its two
> refusals are untouched and its behaviour is unchanged, and its body is still not the body the
> earlier run mutated. All four ran bare rather than narrowed, so each re-establishes its own
> census — 21, 26, 3 and 2, for **52 mutants, every one caught by a named test at a baseline of 219
> green**.
>
> **Two of the four fixes are invisible to both censuses.** F9's clamp and F11's two conditional
> emits contain no `revert`, and removal mutation rewrites a `revert` and nothing else, so no mutant
> can reach any of the three. For those, a test read line by line is the whole of the evidence, which
> is the blind spot §5 already records for eleven view definitions that carry no refusal at all.
>
> **The two falsifications, and each was caught by something that already existed.** F11's sketch
> said `revoke` should check `m.revoked`; a guard there would have turned `test_revoke_isIdempotent`
> red, because that case asserts the second revoke succeeds on purpose, so the condition went on the
> event and `revoke` stayed idempotent. F10's sketch said "four → five"; F3 added a sixth denier to
> that same list inside the same pass, so the cardinal was removed and the deniers named instead.
> **A fix in one finding can falsify a premise in another with nothing failing**, which F3 recorded
> once already, and the two mutation gates still do not cover it.
>
> **2026-08-30, the window geometries: four accepted shapes now have a spend through them, and the
> suite is 225 cases.** Six tests went into `test/Windows.t.sol`, which moves 14 → 20, taking the
> total 219 → **225** — 222 named `test*` plus 3 named `invariant_`, read off
> `reference/vacuity-check.py` rather than counted by hand. The other case-bearing files are
> unmoved at `Cosign` 53, `Creation` 44, `Bounds` 32, `Views` 26, `Gates` 24, `Idempotency` 13,
> `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4 and `Base` 0, and `FORGE.md`'s per-file
> column was corrected in the same pass so the two agree. The model stays at **94**: none of the
> six describes behaviour the model has, because the model carries no window ring.
>
> **What the six pin is narrower than "the geometry is covered".** Two take the one-second
> sub-period, one at the ordinary release and one at `FAR - 3`, where the bucket index reaches
> `2^40 - 4`, the largest index this suite can construct and 40 of that field's 64 bits. One takes
> `buckets == 1`, whose ring is two slots wide and therefore charges up to twice the nominal
> window: the behaviour is correct and startling, so the test states it rather than leaving a
> reader to derive it. One takes `buckets == 32` with 33 spends into 33 consecutive sub-periods
> that a 32-slot ring would have admitted with a bucket to spare, so the assertion tells the two
> ring widths apart. One takes `MAX_WINDOWS` at `MAX_BUCKETS`, the 132-slot maximum-cost spend
> those two constants exist to bound. The sixth is no extreme at all: four windows of differing
> lengths with the tightest last, so a refusal raised by the fourth arrives after three have been
> written, and each of the three is then asserted back at its full cap.
>
> **The measurement §5 asked for is still owed, and the harness is the reason.** `--gas-report`
> perturbs `gasleft()` in this suite, and every call inside one Foundry test function shares a
> transaction, leaving a ring warm from the second spend onward. No assertion in the six names a
> gas number, and the cold figure needs `forge test --isolate --gas-report`, which stays with #14.
> **Much of what the six pin is also beyond either mutation census.** The recycle and accumulate
> branches of `_checkAndCommitWindows` contain no `revert`, and a released amount is a
> `windowRemaining` return, so removal mutation reaches neither: the arguments carried by the
> refusal after a spend are what tell one branch from the other. That is the blind spot #24
> recorded above, met a second time in a different function.
>
> **2026-08-30, F38 through F40: three findings from a twelve-agent sweep, and the first layer of
> this banner written against an uncommitted tree.** Every figure below is derived from the working
> copy rather than from a blob, because there is no blob yet: `git status --porcelain` reports six
> modified files and nothing staged. That is stated first because every other layer here names a
> commit, and a reader who assumes this one does too will look for a sha that does not exist. The
> `forge` half of the evidence is owed for the same reason — the contract, the model and the tests
> are written and `node --test reference/policy.test.js` is **99 of 99**, up from 94, but nothing
> has been compiled.
>
> **`contracts/MandateManager.sol` is 2,247 lines and still 38 errors and 5 events**, from 2,138
> lines at `efe43a7`. None of the three findings needed a new error: F38 widens the list behind
> `UnrecoverableRecipient`, F39 narrows a `NonceReserved` refusal, and F40 raises `OverWindowCap`
> on a path that already had the error but not the check. **+109 lines and no new selector is the
> shape to expect from a mirror-completion pass**, and it is the reason the blob table two
> paragraphs up needs no fifth row: its columns are lines and errors, and only one of them moved.
>
> **The one figure this layer must correct rather than extend.** The `af9df40` row is labelled
> **byte-identical to the working tree**, and that stopped being true at `db1c08c`, two commits
> and four findings ago. It is left as written because it was true of the tree the row was measured
> against, which is the rule the `reference/policy.js` ladder four paragraphs up states for
> itself — but a reader arriving at that table today should read the label as dated, not as live.
>
> **Two new private helpers, and both exist to stop a list disagreeing with a copy of itself.**
> `_isUndebitable` holds the four addresses that can accept USDC and never send it on, read by
> `spend`, by `approveCosignFor` and by `isAllowedRecipient`; F29 wrote that list out by hand in
> those same three places and the registries went missing from all three. `_cosignIsLive` answers
> the deadline question for the two nonce reservations that now consult it. Neither is reachable by
> the Solidity mutation gate, which rewrites `revert` statements: **the helpers carry no refusal,
> only the three call sites do**, so a term dropped from `_isUndebitable` has to be killed by a
> hand mutation, and the six by-name assertions in
> `test_isAllowedRecipient_appliesEveryRecipientRuleSpendApplies` are what kill it.
>
> **The suite should be 231 cases and the model census 83, both owed to a run.** Six Solidity tests
> were written — one for F38, three for F39 and two for F40, plus one existing case in
> `test/Views.t.sol` extended from four recipient rules to six — against 225 at `efe43a7`.
> `test/Cosign.t.sol` moves 53 → **59** and `Views` stays at **26**, because its change lengthened a
> case rather than adding one, and the per-file sum is 228 named `test*` plus 3 named `invariant_`.
> The JS mutation gate census goes 82 → **83**, the single new mutant being F40's `throw refuse(`
> on the approval path, so `approveCosignFor` reads 28 where it read 27. Those two totals are
> predictions until `forge test` and the gate print them, and this sentence is here so a later
> reader can tell which figures in this layer were measured and which were derived from source.

## Why this document exists

The instruction that produced it, 2026-08-26: *security is to be the utmost priority in
all design and contract work, "literally every nook and cranny", because this is
intended to hold real money.*

That instruction calls for a method rather than a claim of completeness. Three times now,
a defect has been found by asking the general question that a specific written item was
an instance of, rather than by working the item as written:

- `CHANGELIST.md` listed a revert for a cosign requirement that can never be met. Asking instead
  *in how many ways can a mandate display a co-signature requirement without having
  one?* gave five, of which the worst — a mandate whose cosigner is its own spender, so
  the agent approves its own spend hash — was on no list anywhere and was accepted by
  both the contract and the reference model.
- The `uint96 totalSpent` liveness cliff was on no list at all.
- The joint-ceiling view was listed as "additive, low risk"; the naive implementation
  *panics* on a two-line construction.

The written list has been short every single time, so this pass enumerates a surface and
asks a question of every element of it rather than working the list.

## 1. Assets, and who can move them

The only asset is **the payer's USDC balance**, held in the payer's own account. It is
never held by `MandateManager`, which has no balance, no `withdraw`, no sweep, no owner
and no admin. There is no protocol treasury, no fee, and nothing to steal from the
contract itself.

What the contract holds is *authority*: the standing ERC-20 allowance that the payer
granted it, which it may exercise only through `spend`. The blast radius of a total
compromise of Remit's logic is therefore exactly **the payer's allowance to this
contract, intersected with the payer's balance** — not the payer's whole balance, and
not any other payer's anything.

Five actors appear in the code: `payer` grants and revokes; `spender` (the delegate —
an AI agent, a payroll bot, a subscription service) spends; `cosigner` approves
individual spends above a threshold; `recipient` receives; and everyone else is a
third party with no role.

## 2. Trust boundaries — what Remit does not protect, by construction

These are the edges of what an on-chain spending mandate can do rather than defects, and
a payer who does not know them will over-trust the primitive.

**The payer account's own security is outside the boundary, and on Arc this is sharper
than on other chains.** Arc's own wallet documentation states it plainly: *"An ERC-20
allowance is not a cap on total USDC spending: the same balance can also leave as
native value (`msg.value`). For smart contract accounts (embedded wallets, smart
wallets, and session-key systems), do not rely on allowance state as a safety
guarantee. Any module with execution rights can also transfer native USDC regardless of
allowance state."* If the payer is a 4337 smart account, a Circle SCA or a Safe, any
module with execution rights on that account can therefore move the same USDC without
consulting Remit at all. Remit bounds what *the delegate* can do through *this contract*;
it cannot bound what the payer's own account can do, and it never claimed to — `DESIGN.md`
already makes the `msg.value` point. What is added here is the smart-account consequence,
which matters because the L3 vault design in `L3-VAULT.md` makes a contract the payer.

**Circle is in the trust boundary.** USDC on Arc is a Circle-operated asset with a
runtime-enforced blocklist and an upgradeable implementation. A blocklisted payer or
recipient makes a spend revert. That is the correct outcome for Remit (nothing moves, no
cap consumed, no nonce burned) but it is not something Remit controls.

**Both ERC-8004 registries are in the trust boundary, and Remit can never be pointed at
different ones.** `identityRegistry` and `validationRegistry` are `immutable`, set once in the
constructor, in a contract with no upgrade path — while the live Arc Testnet ValidationRegistry
was found on 2026-08-24 to sit behind an ERC-1967 proxy, so the code behind that fixed address
can be replaced without Remit knowing. Arc publishes the three registry addresses in a tutorial
rather than in its contract-address reference, with no stated stability or upgradeability
policy. The bound on the damage is narrower than it sounds, and knowing it precisely
matters: both registry checks are conjunctive, so a replaced or hostile registry can only
make a mandate that sets them behave like one that does not. It cannot raise a cap, extend
an expiry, add a recipient to the allowlist, or move one unit more than the amount bounds
already allow. A payer who is unwilling to accept that should not set `F_IDENTITY` or
`F_CREDENTIAL` at all; the caps, the allowlist, the expiry and `approve(usdc, remit, 0)`
depend on no registry whatsoever; see F23.

**The validator named in a credential check is fully trusted, including about time.**
`_checkCredential` checks that the attestation came from the payer-named validator and
concerns the expected agent, which is what stops the check being theatre. It cannot check
that the validator is *honest*. In particular the staleness test is
`nowTs > lastUpdate && nowTs - lastUpdate > c.maxStaleness`, so an attestation dated in
the **future** skips the freshness check entirely and is treated as fresh forever. A
validator can therefore defeat the payer's own freshness requirement permanently. This
is a trust statement rather than a bug — a payer who does not trust the validator should
not name it — but it is not currently written down anywhere.

A related property of the same check **is** already written down, and the contrast is
instructive. When neither `credential.agentId` nor the identity gate's `agentId` is set,
`_checkCredential` skips the agent comparison entirely and the check degrades to "the
named validator filed a passing, fresh attestation under this exact `requestHash`", with
nothing tying it to the spender. That is reachable by omission, since zero is a struct
field's default — and the source says so in ten lines of comment, names the design reason
(an attestation about a *request* rather than about an agent is a legitimate shape, and
`requestHash` is payer-fixed at grant time so the spender cannot redirect the lookup), and
points at a test that pins the behaviour by name:
`test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent`.
That work was already done, so this is not a finding here; it is the standard the
future-dated staleness hole should be brought up to.

**A compromised delegate can pay *itself*, and without an allowlist that is the whole
attack.** `spend` requires `msg.sender == m.spender` (`v2:610`) and constrains the recipient
only against zero and against the allowlist (`v2:614-615`), so on a mandate granted without
`F_ALLOWLIST`, `recipient = m.spender` is a valid spend and the delegate needs no colluding
vendor, no second address and no cleverness — it transfers the payer's USDC to itself, up to
`perTxCap` per transaction and up to every window and lifetime cap in total. This is not a
defect and it is not fixable: a spending mandate that could stop the spender choosing the
recipient would not be a spending mandate. It is the sentence that says what the caps are
*for*. The caps are the entire protection, and they hold — the window search found no
sequence that exceeds them in 3.0M trials — but "the delegate cannot steal" is false and
"the delegate cannot steal more than the cap, and cannot steal at all from anyone the payer
did not allowlist" is true. **`F_ALLOWLIST` is what converts the bound from an amount into an
amount *and* a set of counterparties**, and it is the one flag whose absence changes the
threat model rather than the arithmetic. A payer granting to an agent they do not operate
should treat it as mandatory. `v2:482` refuses `cosigner == spender`, so the co-signature
route cannot be self-approved, but nothing refuses `recipient == spender` and nothing should.

[**#28, F19: the recipient is constrained three ways in the working tree, not two** — zero, the
payer, and the allowlist. `v2:614-615` above is correct against this banner's anchor and is left
alone; `spend` additionally reverts `SelfPayment` on `recipient == m.payer` since 2026-08-28.
**None of this paragraph changes**, and the reason is a distinction the document now has to be
careful about: F19 refuses paying *the payer*, F22 is about paying *the spender*, and both get
called a "self-payment" in English although they are opposite cases. Paying the payer moves
nothing and was refused because it lies to a reconciler. Paying the spender moves everything and
must stay legal, because forbidding it would mean the delegate could not be the recipient of its
own mandate — which is most of what mandates are for. **A guard named `SelfPayment` that refused
`recipient == m.spender` would break Remit; the one that shipped refuses `recipient == m.payer`
and breaks nothing.** If that name ever has to be read quickly, read the condition instead.]

**Everything is public.** Every mandate, every cap, every spend, every recipient, and
the whole commercial relationship it implies. This is the subject of `PRIVACY.md` and
`L3-VAULT.md` and is not restated here.

**The proposer chooses transaction order.** Arc's deterministic finality removes reorgs;
it does not remove the mempool. See F4.

## 3. Properties the contract does enforce, and the guard for each

Derived by walking the source, not by reading the test names. Five functions change
state: `createMandate`, `spend`, `revoke`, `approveCosignFor`, `withdrawCosign`. There are no
setters, no admin functions, no `delegatecall`, no `selfdestruct` and no upgrade path.

| Property | Enforced by |
| :--- | :--- |
| Only the named spender can spend | `spend`: `msg.sender != m.spender` → `WrongSpender` |
| Every spend moves value to somebody other than the payer | `spend`: `recipient == address(0)` → `ZeroRecipient`, and #28/F19: `recipient == m.payer` → `SelfPayment`. Both are refused ahead of the allowlist on purpose — shape before policy, so a malformed request is not answered with a configuration error. The pair is what makes `Spend` events reconcilable at all: Arc's system emitter writes no log for a self-transfer, so before F19 a spend could consume every cap, emit `Spend`, and leave nothing for a reconciler to match against. Mirrored in `approveCosignFor`, since `m.payer` has one write site and no mutator, so an approval naming the payer could never be consumed |
| Every spend moves value somewhere it can move again | **Row added 2026-08-29 — F29.** `spend`: `recipient == address(this) \|\| recipient == address(usdc)` → `UnrecoverableRecipient`, mirrored in `approveCosignFor`. This contract calls exactly one balance-moving token function, the `transferFrom` in `spend`, and that always pays a third party, so USDC credited to `address(this)` has no exit and no upgrade path can add one. Refused in code rather than left to `F_ALLOWLIST`, because the allowlist is optional and this hazard is not |
| A mandate id is unique to one payer forever | id = `keccak256(DOMAIN, chainid, this, msg.sender, salt)`; `payer != address(0)` → `MandateExists`. `payer` is never cleared, so an id is single-use permanently and no revoked mandate's storage can be reinterpreted |
| No mandate can be created without a bound on **lifetime** exposure | `createMandate` at `v2:424`: `(flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)` → `Unbounded`. Narrowed in #22; v1's `hasBound` local also accepted `F_PER_TX` or a window, neither of which bounds a lifetime — that was F5, and this row is what the contract's own comment had been claiming all along |
| Every flag agrees with the value it describes | five biconditionals in `createMandate`, plus the one-directional `F_EXPIRY` rule at `v2:446` added in #22 — F1. **Extended 2026-08-29 by F32** to the two ERC-8004 gate structs, which are not single fields and so were outside the biconditionals: gate data supplied without its flag is now `BadConfig` rather than silently dropped, across all seven fields of the two structs. No field in the struct can now be displayed and unread, and none can be supplied and ignored |
| A displayed co-signature requirement is a real one | three grant-time guards: threshold-without-flag, `cosigner == spender`, and `effectiveMax <= cosignThreshold` |
| Caps cannot be exceeded per-transaction, per-window, or per-lifetime | `OverPerTxCap`, `OverWindowCap`, `OverTotalCap`; window accounting independently searched over 3.0M spend sequences with zero violations, on a harness that reproduces the historical K-bucket bug at 2× cap |
| A rolling window is genuinely rolling | K+1 bucket summation. The proof in the source is valid but proves less than the code guarantees: eviction (`bucketIndex < oldest`) is the exact negation of inclusion (`bucketIndex >= oldest`) computed from the same `oldest` in the same call, and `oldest` is monotone, so nothing counted is ever discarded. `createMandate`'s `lengthSeconds % buckets != 0` check is load-bearing for cap soundness, not merely for uniformity |
| A spend cannot be replayed | `_usedNonce[mandateId][nonce]`; a reverted spend does not consume its nonce |
| One co-signature authorises exactly one spend | the hash binds mandate, spender, recipient, amount, ref and nonce plus `DOMAIN`, chainid and `address(this)`; consumed with `delete` on use |
| An approved spend stays makeable until it is used, withdrawn, or expires | **Row added 2026-08-29 — F30; amended 2026-08-30 — F39.** `_cosignReservedNonce[mandateId][nonce]` holds the approved nonce for its exact hash, so any *other* spend on that nonce is `NonceReserved`. Before this the delegate could send a one-unit spend on the approved nonce, take the sub-threshold path that consumes no approval, and burn the nonce — leaving the approval in storage, reading as honourable, authorising a payment nobody could make. The reservation is read outside the co-sign branch, released on the spend that consumes it, and released by `withdrawCosign` only when the stored hash matches. **F39 added the missing half of "until it expires"**: the reservation carried no deadline of its own, so it outlived the approval and kept refusing on a nonce nobody could then free. Both readers now pair it with `_cosignIsLive`, so a lapsed reservation is swept rather than obeyed, and the invariant holds in the direction it was written for as well as against |
| A payment the payer cannot get back is refused rather than recorded | **Row added 2026-08-30 — F38, generalising F29.** `_isUndebitable` names the four addresses that can accept USDC and never send it on — this contract, the token, and both ERC-8004 registries — and all three sites that ask a recipient question read that one helper: `spend`, `approveCosignFor`, and `isAllowedRecipient`. Every one of the four is `immutable` or `address(this)`, so none can stop holding. F29 established the rule for the first two and wrote it out by hand three times; the registries were absent from all three copies, which is the reason the list is now a single line of code rather than three of them |
| A co-signature cannot name a spender the mandate does not have | #28/F15: `spendHash` reads `m.spender` from storage instead of taking it as an argument, so a hash naming any other spender is not constructible through this contract — and `approveCosignFor` derives the hash itself rather than accepting one, so a co-signer cannot be handed a hash that disagrees with the fields they were shown |
| A co-signature expires | #28/F16: `approveCosignFor` refuses `validUntil <= block.timestamp` and `validUntil > block.timestamp + MAX_COSIGN_TTL` (30 days) with `BadDeadline`; `spend` refuses at or after the deadline with `CosignExpired`, distinct from `CosignRequired` for one never granted |
| Revocation is immediate and permanent | `revoke` sets `revoked = true`; no un-revoke exists |
| A compromised agent can shut itself off | `revoke` also accepts the spender |
| Caps hold even if the token misbehaves | see F7 — this is stronger than the source claims |
| Authority follows the ERC-8004 agent identity, and dies when the identity moves | **Row added 2026-08-28; its absence is F27's other half.** `spend` at `:725` calls `_checkIdentity`, which reads `ownerOf(agentId)` live and refuses `IdentityNotHeld` unless the caller still holds it — so selling or burning a transferable identity NFT kills the mandate rather than transferring authority with the token. Read at **spend** time, not grant time, which is the whole value of the gate. The second guard on the next line, `expectedOwner`, adds nothing to this and can only subtract — which is why, since 2026-08-29, `createMandate` accepts it only as zero or the spender. See **F27** for the finding and **F33** for the guard |
| A gate a payer configures can actually open | **Row added 2026-08-29 — F33 and F34.** `createMandate` refuses four configurations that would make every spend revert for the life of the mandate: `identity.agentId == 0`, an `expectedOwner` naming anyone but the spender, `credential.minResponse > 100`, and `credential.requestHash == 0`. Each reads at the call site like extra strictness and is a brick. The mandate is checked for openability at the one moment it can still be edited, which is the same argument #22's `Unbounded` refusal makes about caps |
| A freshness requirement can measure the age of what it accepts | **Row added 2026-08-29 — F31.** `_checkCredential` refuses `lastUpdate > nowTs` outright rather than treating it as fresh. The condition it replaced existed to stop an unsigned subtraction underflowing and did so by exempting future-dated attestations from `maxStaleness` altogether, so one stamp ahead of the chain clock bought a credential that never went stale. The underflow is still impossible, by short-circuit rather than by the old conjunct |
| A pre-flight view agrees with the spend path, or says which question it answered | **Row added 2026-08-29 — F35 and F36.** `isAllowedRecipient` now applies every recipient rule `spend` applies and answers `false` for an unknown mandate; `isCosignApproved` now folds in `_isPermanentlyDead`, so a revoked or expired mandate no longer reports its stored approvals as honourable. Both are scoped in their own docstrings to what they do **not** cover, because these views are used as pre-flight checks and a `true` the contract then refuses is the display-versus-enforcement gap this document is mostly about. Not reachable by the mutation gate — it rewrites `revert` statements and a view has none, which is why both were found by reading the views against `spend`. **F38 tested the claim a day later and it held for the wrong reason**: `isAllowedRecipient` did apply every rule `spend` applied, and two of those rules were short by the same two addresses, so the agreement was real and the shared list was wrong. Since the fix, the view and both refusals read one helper, which makes the agreement structural rather than something a reader has to re-check |
| A gated mandate stops working when a named validator stops vouching for the agent | `spend` at `:726` calls `_checkCredential`, which refuses unless the ERC-8004 `getValidationStatus` tuple shows the payer's **named validator** answering about the payer's **named agent** with `response >= minResponse`, fresh within `maxStaleness`. Checking the tuple rather than `response` alone is what makes it a gate at all, since the registry is keyed on `requestHash` and anyone may file under any hash. Also spend-time: a lapsed attestation stops the mandate with no action from the payer, and re-attesting revives it. Both gates are independent and both must pass; neither implies the other. Bounded by **F13** (the registries are still not consulted until spend time — F33 and F34 validate the gate's *configuration* at grant time, which is a different claim and does not read the registry), **F23** (the registries are an unnameable trust boundary) and the documented weakening in `test/Gates.t.sol`'s `test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent` |

## 4. Findings

Ranked by what should be fixed before this holds real money, rather than by CVSS. Severity
reflects consequence *and* reachability; several of the most interesting entries are
false or overstated claims in comments and documents rather than defects in code, which
for a primitive whose entire product is *legibility of authority* is not a lesser
category.

**Forty findings, counted from the headings below rather than asserted** — `grep -c
"^\*\*Severity"` and `grep -c "^### F[0-9]"` both return 40, which is the check, not the
memory of having added some. The count is not a measure of anything — it is a function of how
long the search ran. They partition exactly, which is more useful than the total: **twenty-five are
already fixed in code** (F1, F5 in #22; F15, F16, F17, F19, F25 in #28; eleven in `af9df40` on
2026-08-29 — F27 and F29 through F36 in `contracts/`, F28 and F37 in `reference/policy.js`; F3,
F9, F10, F11 in #24 on 2026-08-30; and F38, F39, F40 later the same day); **two
were fixed in this document as it was being written** (F22 and F23, both missing trust boundaries —
§2 gained its sixth and seventh in one day); **one has a fix that changes v2's behaviour** (F13);
**six
are comment rewrites** that change nothing any code does (F4, F7, F8, F14, F21 in the
contract, F26 in the mocks — and the last is in `test/`, so it is free of the frozen-metadata
constraint that governs `contracts/`); **three are documentation** (F2, F6, F18); **one needs a
decision before it can be sized** (F20, whether the contract gains a sixth state-changing
function, and its first that mutates a mandate after creation); **one
needs a four-line test before it can be sized at all**,
because one of its two possible answers cannot be settled by reading source (F24); and **one
needs nothing** (F12).
25 + 2 + 1 + 6 + 3 + 1 + 1 + 1 = 40, which is the arithmetic and not a second assertion of the
same number.

**The fixed bucket now carries two statuses and the name no longer covers both.** F38, F39 and F40
are written in the working tree and nothing else: not committed, not compiled, and not yet run
against `forge`. They are counted as fixed because the code exists and the tests that assert it
exist, and each of their three entries below says so in its own status line rather than leaving a
reader to infer it from a missing sha. **Every other member of this bucket names a commit, and
these three name a tree**, which is a weaker claim and is the honest one until the run comes back.

**A whole bucket emptied on 2026-08-29, by this document's own rule.** The first bucket is a status
and the rest are costs, so a finding moves into it when it lands — F19 was in "changes v2's
behaviour" and F25 in "comment rewrites" until 2026-08-28. F27 made the same move a day later, and
F28 was the sole member of a ninth bucket for a divergence between the reference model and the
contract; both landed in `af9df40`, so that bucket has no members left and is gone from the list
above rather than sitting at zero. Nine of the eleven findings in `af9df40` were opened and closed
the same day, which is why the fixed bucket doubled while nothing else grew. F27 and F28 arrived on
2026-08-28 from a different direction entirely — neither came from reading the contract, which is
what §6 now has to account for, along with F37, which came from the same place a day later.

**Four more findings landed on 2026-08-30, and two of the eight buckets shrank to make room.** #24
took F3, F9, F10 and F11 — the four the table below priced at one error, five lines and a comment
between them. F3, F9 and F11 came out of "changes v2's behaviour", leaving F13 alone in it, and F10
came out of "comment rewrites", leaving six. The fixed bucket is twenty-two of thirty-seven now, so
a majority of the findings in this document are closed, and the remainder is one behavioural change,
six comments, three documents, one decision, one test and one finding that needs nothing.

**Two of the four cost more than the rows that priced them, both for one reason.** A fix sketch is
written against the guard the finding names, and this contract has mirrors: F3's guard needed F17's
twin in `approveCosignFor`, and F11's three lines became two guards, three reads and two conditional
emits across two functions. That is the third and fourth time a row in this table has undersized a
mirror, after F17 and F19, and the pattern is old enough now that a sketch naming one guard should be
read as naming a pair until `spend` and `approveCosignFor` are checked against each other.

**Three more landed later on 2026-08-30, and all three are mirrors, which is the fifth, sixth and
seventh time.** F38, F39 and F40 came in together from a twelve-agent parallel sweep, and none of
them opened a bucket or emptied one: each went straight into the fixed bucket, taking it to
twenty-five of forty. What they have in common is not a subject — an address list, a nonce
reservation and a window cap have nothing to do with each other — but a shape. **Each is one rule
holding on one path and not on its twin.** F38's list was written out by hand in three places and
two of the three entries were reasoned about in all three, so the two that were added later went
into none. F39's refusal was unconditional in `spend` and unconditional again in
`approveCosignFor`, and fixing the first without the second would have left the co-signer unable to
replace their own lapsed approval. F40's window check exists in `spend` and had no counterpart at
all in `approveCosignFor`, where a comment argued it should not have one.

**The paragraph above this one predicted them, which is worth stating plainly rather than treating
as a coincidence.** #24 recorded that "a sketch naming one guard should be read as naming a pair
until `spend` and `approveCosignFor` are checked against each other", and the next three findings
were all found by doing exactly that. A rule of thumb earned from four undercounts turned out to be
a search strategy, and F38's own fix — one helper read from three sites instead of three copies of
one condition — is the structural version of the same lesson: **a mirror that is a shared line of
code cannot fall out of step, and a mirror that is a copy always eventually does.**

**F13 is the only member of its bucket now, and this pass did not settle whether it belongs there.**
F32, F33 and F34 all validate ERC-8004 gate data at grant time, which is F13's stated remedy in a
narrower form. Recorded as a question rather than answered, because answering it means reading F13
against three fixes that postdate it.

**Two decisions are open and only one of them is a bucket, so counting buckets undercounts them.**
F20 cannot be sized until the decision is made. F34's decision is attached to a finding already
fixed: `minResponse` is bounded at `> 100` and could instead be pinned at `!= 100`, and the choice
only loosens in one direction, so it can be tightened before deployment and never after. Triage:

| Fix before v2 freezes | Cost | Needs a decision first |
| :--- | :--- | :--- |
| ✅ F1 `expiresAt` grant-time refusal | **DONE in #22.** 1 line + 1 test; no model mirror, and F1 says why | — |
| F2 `DESIGN.md` worked example | numbers derived, needs a doc sweep — and it grew a second defect, see F2 | — |
| ✅ F3 `SpendCountCeiling` guard | **DONE in #24, 2026-08-30.** Not "1 error + 1 line" — **1 error and 2 guards**, under F17's rule that a permanent refusal in `spend` is mirrored in `approveCosignFor`. Plus 2 Solidity tests, 2 model refusals, and 2 gate mutants, one per path, each caught by a named test. **The third mirror this table undercounted**, after F17 and F19 | **both branches were taken.** The guard shipped *and* `CHANGELIST.md`'s comparison was corrected, so the row's "or" was answered with "and" |
| ✅ F9 `spendable` clamp | **DONE in #24, 2026-08-30.** 1 line, as estimated. No mutant can reach a clamp, so a single Solidity test carries the whole proof, and it pins the clamped value rather than checking that the two views agree | — |
| ✅ F10 four → five | **DONE in #24, 2026-08-30.** Comment only, as estimated, but **not** "four → five": F3 added a sixth denier to the same list the same day, so the cardinal was removed and the deniers named | — |
| ✅ F11 `withdrawCosign` two guards, `revoke` idempotence | **DONE in #24, 2026-08-30.** Not 3 lines — 2 guards, 3 local reads and 2 conditional emits across two functions. **The `revoke` half of this row was wrong**: a guard there would have failed `test_revoke_isIdempotent`, which asserts the non-reverting behaviour on purpose, so the condition went on the event instead. 5 gate mutants re-run over the two functions, all caught, plus 2 tests for the emits, which no mutant can reach | — |
| F4, F7, F8, F14 wrong justifications | comment rewrites | — |
| ✅ F5 `Unbounded()` scope | **DONE in #22.** 1 line, +1 model test, and a horizon threaded through both suites | **DECIDED 2026-08-26: refuse** |
| F6 threshold splitting | doc + one composition test | **DECIDED: document, recommend pairing with a window** |
| F13 gate pre-validation | 2 registry reads at grant + tests | **DECIDED 2026-08-26: validate at grant** |
| ✅ F15 `approveCosignFor`, explicit fields | **DONE in #28, 2026-08-27.** Not additive as proposed — the opaque `approveCosign` was DELETED, and `spendHash` lost its `spender_` parameter. See F15 for what that cost | **DECIDED 2026-08-27: remove it.** The row's own open question, answered against the recommendation in this row |
| ✅ F16 approval deadline | **DONE in #28, 2026-08-27.** `bool` → `uint40`, `MAX_COSIGN_TTL = 30 days`, 2 guards in `spend`, `isCosignApproved` re-meaninged, `cosignApprovalDeadline` added | **The "storage layout, so free now and not after v2 deploys" claim was DISPROVEN by `forge inspect` before the work started — a mapping occupies one slot whatever its value type. It was done for its own sake, not to beat a deadline that did not exist** |
| ✅ F17 dead approvals refused | **DONE in #28, 2026-08-28.** Not 2 lines — **18 guards**, derived from `spend`'s permanent refusals rather than from this row's list, plus 13 tests in `test/Cosign.t.sol` and a mutation gate that proves each guard is asserted. The count was 17 on the day it shipped and F19 made it 18 the day after; see F19 for why that is a rule and not an accident. The hard half was deciding what NOT to refuse: `notBefore`, a full rolling window and an unfiled credential all recover, so refusing them would turn our caution into somebody's unapprovable payment | — |
| F18 co-signer rotation | documentation only — `README.md`, that re-granting resets the lifetime counters | whether a rotation path is wanted at all, which needs a setter and this contract has none |
| ✅ F19 refuse `recipient == m.payer` | **DONE in #28, 2026-08-28.** Not "1 error + 1 line" — **1 error and 2 guards**, because F17 had shipped the day before and F17's rule is that every permanent refusal `spend` makes is mirrored in `approveCosignFor`. `m.payer` is assigned once and has no mutator, so this is permanent, and omitting the mirror would have holed F17's invariant one day after it landed. Plus 4 tests (3 in `Bounds.t.sol`, 1 in `Cosign.t.sol`), 4 model refusals, and 2 more gate mutants — `approveCosignFor` 17 → 18 guards, both gates 21 → 22. **The undercount was mine and it is the second in a row**; see F17's row above for the first | — |
| F20 recipient removal | either 0 lines (document it) or a payer-only remove-only mutator + event + tests | **whether the contract gains a sixth state-changing function — and its first that mutates a mandate after creation. Monotone, but §3's "no setters, no admin functions" is a sentence a payer can verify in ten seconds** |
| F21 `ZeroRecipient`'s Arc citation | comment only | — |
| ✅ F22 §2's missing self-payment boundary | **DONE 2026-08-26**, in this document, in the commit that found it. **A second half landed 2026-08-30** — the property that paragraph asserts, `recipient == m.spender` staying ALLOWED, was executable nowhere in Solidity, so 3 tests and 2 gate injections hold it now, one injection on `spend` and one on `approveCosignFor`. Cost: 3 tests, one new `INJECTIONS` entry, and not a single contract line, which is why the census rose while the contract stayed byte-identical | — |
| ✅ F23 §2's missing ERC-8004 registry boundary | **DONE 2026-08-26**, in this document — §2's seventh boundary; 0 lines of Solidity, and none available anyway since the addresses are `immutable` | — |
| F24 codeless-but-non-zero registry | a 4-line test, which decides whether there is anything else to fix | **what Solidity 0.8.28 does with a decode failure inside `try` — not settleable by reading source, and both answers are denials** |
| ✅ F25 `MockUSDC` self-transfer log | **DONE in #28, 2026-08-28.** A 20-line header block plus a note at the `emit`, landing in the same change as F19 because F19 is the only reason the divergence matters. The mock's behaviour is deliberately left divergent rather than corrected: matching Arc here would make the mock look authoritative about a rule only a testnet transaction can confirm | — |
| F26 mock revert shapes vs. the bare `catch` | comment only, in `test/` | — |
| ✅ F27 `expectedOwner` is skipped, redundant, or bricking | **DONE in `af9df40`, 2026-08-29.** Cost as estimated — 1 guard in `createMandate`, tests, and the `test/Gates.t.sol` comment rewrite — but the guard shipped as F33's second half, so the code sits in F33's entry rather than this row's. One test was **deleted** rather than added: the guard made `IdentityTransferred` unreachable through the ordinary path, and `vm.store` now forces the state instead | **folded into #23 exactly as this row said, and the ERC-8004 half of #23 is what landed** |
| ✅ F28 model reads `expectedOwner = 0` as a pin | **DONE in `af9df40`, 2026-08-29.** 1 line in `reference/policy.js`. The pinning test was **rewritten to assert the agreement** rather than deleted, which keeps the alarm and costs nothing | **stayed sequenced behind F27 and the sequence held** — F27's guard made zero the only non-redundant value, which is what this row predicted would make the model's reading matter |
| ✅ F29 unrecoverable recipients | **DONE in `af9df40`, 2026-08-29.** 1 error + 2 guards (`spend` and the `approveCosignFor` mirror), 1 Solidity test shared with F36, 4 model tests. **The mirror at `contracts/MandateManager.sol:1479` is asserted by nothing**, so the owed `approveCosignFor` gate run should surface exactly one survivor there — see §5 | — |
| ✅ F30 one nonce, one reservation | **DONE in `af9df40`, 2026-08-29.** A ninth mapping, 1 error, 4 guards across three functions, a new `nonce` parameter on `withdrawCosign`, 6 Solidity tests, 7 model tests, and a `withdrawCosign` added to the model because the reservation needs a release. Three existing attack tests in `Cosign.t.sol` were **rewritten rather than retuned** when the fix changed which refusal fires first, so each now asserts both legs | — |
| ✅ F31 future-dated attestations were fresh forever | **DONE in `af9df40`, 2026-08-29.** 1 condition rewritten, 3 Solidity tests, 1 model test. The underflow argument was re-derived against the new condition rather than assumed to carry over | — |
| ✅ F32 gate data without its flag | **DONE in `af9df40`, 2026-08-29.** 2 guards covering all seven fields, 3 Solidity tests. **Cannot arise in the model** — it has no flags, so supplying the data is enabling the check | — |
| ✅ F33 an identity gate that can never open | **DONE in `af9df40`, 2026-08-29.** 2 guards, 4 Solidity tests + 1 `vm.store` test, both mirrored in the model. Carries F27 | — |
| ✅ F34 a credential threshold that cannot be met | **DONE in `af9df40`, 2026-08-29.** 2 guards, 3 Solidity tests, both mirrored in the model | **OPEN: `minResponse` bounded at `> 100`, or pinned at `!= 100`.** Tightening costs one contract line, one model line and one model assertion, breaks no Solidity test, and can only be done **before** deployment. It is a payer-facing policy question, not a code question |
| ✅ F35 `isCosignApproved` ignored the mandate's own death | **DONE in `af9df40`, 2026-08-29.** 1 conjunct + a factored `_isPermanentlyDead`, 2 Solidity tests. **Wrong on its first attempt** — it used `isLive`, which folded in `notBefore` and reported a live scheduled approval as dead; two tests caught it. No model surface, since the model has no pre-flight views | — |
| ✅ F36 `isAllowedRecipient` disagreed with `spend` | **DONE in `af9df40`, 2026-08-29.** 3 guards, 2 Solidity tests, one of them shared with F29 so the two claims check each other. No model surface | — |
| ✅ F37 the model minted mandates with a zero payer or spender | **DONE in `af9df40`, 2026-08-29.** 2 throws in `reference/policy.js`, asserted by the grant-time construction test. **Not named in that commit's message** — it was folded into the gate work; this document is where it gets named. Found by the JS mutation gate, which reported a survivor and turned out to be reporting a divergence | — |
| ✅ F38 the two ERC-8004 registries were payable recipients | **DONE in the working tree, 2026-08-30, uncommitted.** No new error and no new guard — the two hand-written conditions and the view's `return false` became three calls to one new `_isUndebitable`, which is why widening the list from two addresses to four cost 1 helper and 0 new comparisons at the call sites. Mirrored in `reference/policy.js` by `undebitableAddrs`. 1 Solidity case extended from four rules to six, 1 new Solidity case on the approval path, 3 model tests. **Unreachable by either mutation gate** — the helper holds no refusal — so the six by-name assertions are the whole of the evidence | — |
| ✅ F39 a reservation outliving its approval | **DONE in the working tree, 2026-08-30, uncommitted.** Not 1 condition — **2 conditions and a sweep**, plus `_cosignIsLive` so the two sites cannot answer the deadline question differently from the enforcer three lines below the first of them. The second site is the one the sweep that found this did not name: `approveCosignFor` carried the identical unconditional refusal, and fixing only `spend` would have left the co-signer unable to approve a replacement on a nonce their own lapsed approval had reserved. 3 Solidity tests, 4 model tests. **It also closes a rough edge the suite had already accepted in writing** — `withdrawCosign` with the wrong nonce left a reservation with no approval behind it, and F30's own test documented that as a known cost | — |
| ✅ F40 the permanent half of the window cap | **DONE in the working tree, 2026-08-30, uncommitted.** 1 loop, at most `MAX_WINDOWS` cold reads, on the one path that had argued in a comment for leaving it out. The finding is inside a sentence rather than inside code: "an amount refused now can fit later" is true of `used + amount > cap` and false of `amount > cap`, and F17's own note carried it as a single recoverable condition for two revisions. 2 Solidity tests, 1 model refusal, 1 new gate mutant. **The repository already held both halves in two tests that never met** — `test_cosign_isCheckedAfterEveryCap` asserted the permanent refusal with `used` written as a literal zero, and `test_f17_approvingWhileAWindowIsFull_isAllowed`, 545 lines below it at `efe43a7`, asserted that approving against a full window was allowed | — |
| §5 coverage gaps | **1 test, 4 testnet transactions, later the same day on 2026-08-30.** Six tests landed in `test/Windows.t.sol` and four items came off together — the four-window maximum-cost spend and all three window geometries — which is the largest single drop this row has recorded, and the four fell to one commit because they shared one file and one harness. What remains is 1 spend through a `minResponse` between 1 and 99, which is a decision before it is a test, and F34's OPEN cell in this table holds that same question. **Three findings landed after this layer was written and the count stayed at 1**, because F38, F39 and F40 each arrived with the Solidity and model tests their fix needs, so none of them opened a gap of the kind this row counts. What they did open is four hand mutations, which are owed and are recorded in §5, and they sit outside this tally under the rule the next sentence states. The gas measurement the maximum-cost item asked for stays out of this count, for the reason the view-reaching mutation operator stays out: a measurement is not a test. The layer this replaces follows, reading as it did. **5 tests, 4 testnet transactions as of 2026-08-30.** The `UnrecoverableRecipient` mirror came off because its test was written and `mutgate-only-approveCosignFor.log` shows the mutant caught, which leaves 1 four-window maximum-cost spend + 3 window geometries + 1 spend through a `minResponse` between 1 and 99. A sixth gap opened and closed inside the same day and so never entered this tally: the F32 credential guard at `createMandate:873` was shadowed rather than unasserted, and the two tests that isolate it landed with the finding. The layer it replaces read **6 tests, 4 testnet transactions as of 2026-08-29**, and that was the first time the tally had gone *up* — re-enumerated by walking §5's bullets, the same way every figure before it was built, which is the reason this row is appended to rather than decremented. Before it, **5 tests, 3 testnet transactions as of 2026-08-28**; before that **10 tests, 3 testnet transactions**, and before that "9 tests, 1 testnet transaction", which undercounted the testnet side by two: the ERC-20 self-transfer log and the pending-validation state are both transactions, not tests. The 10 decomposed, against `c46dccd`'s blob, as 1 four-window spend + 3 window geometries + 4 co-signature behaviours + 1 `recipient == m.payer` + 1 future-dated `lastUpdate`. **Five came off for three different reasons, and only three came off because somebody wrote the test the bullet asked for**: F17's three cosign tests now run; the fourth cosign gap was withdrawn as never having been one, since the test it named as missing already existed at the anchor commit; and `recipient == m.payer` came off with its test never written, because F19 made the behaviour unreachable and the bullet had itself said such a test *"would have to be **deleted** if F19's fix lands"*. So a shrinking tally here does not mean the suite grew by the difference. **The 6 decomposes as 1 four-window maximum-cost spend + 3 window geometries + 1 spend through a `minResponse` between 1 and 99 + 1 assertion on the `UnrecoverableRecipient` mirror in `approveCosignFor`.** One came off (the `lastUpdate` test was written, and writing it produced F31) and two went on, both from `af9df40` — a new guard that nothing asserts, and a bound whose permitted range nothing executes. **New guards create coverage gaps at roughly the rate they close findings**, which is the honest reading of a tally that rose while eleven findings were being fixed. The testnet side went 3 → 4 for the blocklist question `MockUSDC` cannot answer, and no amount of Solidity can move any of the four. One further owed item is deliberately *not* counted here because it is not a test: the view-reaching mutation operator. **The second such item is closed as of 2026-08-30** — the mutation-gate runs the contract still owed, which this row first put at 73 across five targets before §5 re-derived it as 33 across six, and all eleven targets have now run for 89 of 89 mutants attempted, nine clean and two holding one equivalent mutant apiece. **A third owed item closed later the same day, and it was never in this tally either** — F22's property had no Solidity test at all, while this tally counts only gaps §5's own bullets had named, and that one surfaced by asking what the mutation gate was unable to falsify. Closing it therefore leaves the count at **5 rather than 4**, which is the honest arithmetic, since a tally can shrink only by the items it once listed. What it moved instead is the mutant census, 89 → 91 | fold into #14, which needs the gas number anyway |

F12 is a design consequence rather than a defect and needs nothing. Nothing on this list risks funds in
the sense of letting a spend exceed a granted cap; the window search found no such case in 3.0M
sequences. **That sentence used to be the whole reassurance and F29 has narrowed it.** A spend to this
contract or to the token stayed inside every cap the payer granted and destroyed the money anyway, so
"no spend exceeds its cap" and "no spend loses funds" are two claims and only the first one was ever
proven. The first still holds, and the second held only after `af9df40`, because two addresses
are now refused rather than because anything about the caps changed. **F23 is the closest thing to a
counterexample on the cap claim and it is not one** — a replaced ERC-8004 registry can make a mandate
with the registry checks set behave like one without them, which widens the mandate back out to its
caps and cannot take it past them, because those checks only ever refuse. What this list is mostly
about is the gap between what a
payer is *shown* and what is *enforced*, which is the thing Remit sells — and F15 extends
that gap to a second party, since the payer is not the only participant who is shown
something, while F19 extends it to a second *reader*, since a reconciler diffing `Spend`
events against Arc's system log is shown a discrepancy that is not one. F25 extends it once
more, to the most credulous reader of all: a passing test.

Both of those last two closed on 2026-08-28, and **they closed by opposite means.** F19's
reader was satisfied by removing the state that lied — a spend that
emits `Spend` and moves nothing is now refused, so there is nothing left for a reconciler to
mis-see. F25's reader could not be satisfied that way, because the credulous reader is a test and
the lie is in Remit's own mock: the divergence was documented and deliberately *left in place*, since
making `MockUSDC` agree with Arc would have converted an honest simplification into an
unverified claim wearing the clothes of evidence. **A gap between display and enforcement is
closed by deleting the display or by deleting the enforcement gap — never by making the display
more convincing**, and F25 is the case where that distinction had teeth.

**`af9df40` added four more instalments of the same theme, and they landed at three different
layers.** F35 and F36 are the two views telling a co-signer and a caller something the spend path
would refuse, closed by making each view answer the question it was actually asked. F32 is the
version where the display is the payer's own flags: the receipt agreed with a grant the payer did
not make, and the fix refuses the ambiguous grant rather than improving the receipt. F29 is the
version where the display was correct and the *enforcement* was missing — the caps, the nonce and
the event all reported a real payment, because a real payment is what happened. Eleven findings
landed in that commit and four of them are a version of one participant being shown a claim about
storage and hearing a claim about a payment.

---

### F1 — `expiresAt` is stored, emitted and displayed on a mandate that never expires

**Severity: medium · Status: FIXED in v2 (#22), 2026-08-26 · Confidence: certain.**

`createMandate` couples each flag to the value it describes with a biconditional, for
`F_PER_TX`, `F_TOTAL`, `F_COSIGN`, `F_CREDENTIAL` and `F_ALLOWLIST`. `F_EXPIRY` had no
such rule: `v2:433` validates `expiresAt` only *when the flag is set*
(`if (flags & F_EXPIRY != 0 && p.expiresAt <= p.notBefore)`).
With the flag unset, any `expiresAt` was accepted, written to storage, and emitted in
`MandateCreated`, while nothing ever read it — `spend` and `isLive` both apply the
comparison only when the flag is set.

A payer could therefore be shown, by `getMandate` and by the creation event, a mandate that
expired last Tuesday and that will spend forever. This is the identical failure class as
the `cosignThreshold`-without-`F_COSIGN` lie that v2 already refuses at `v2:465`, and
the argument that settled that one applies verbatim: a grant that appears to carry a
control it does not carry is refused rather than documented.

The fact was not new — `L3-VAULT.md:231` records that `expiresAt` "is then an unvalidated
field that may be zero", and the arithmetic sweep independently reached the same place.
What was new is the framing: it had been written down as a trap for a *future vault's*
release predicate, addressed to a reader building on top of Remit. It was never treated
as a property of the mandate that every direct payer also sees.

The asymmetry with `notBefore` looks like the same problem and is not: `notBefore` is
enforced unconditionally, in both `spend` and `isLive`, with no flag at all. It therefore
cannot be displayed-but-dead, and needs no rule.

**Fixed in #22** by one line beside the existing guard, at `v2:446`:
`if (flags & F_EXPIRY == 0 && p.expiresAt != 0) revert BadConfig();` — one-directional
for the same reason the threshold rule is, since with the flag SET the paired guard at
`v2:433` already constrains the value, so only the flag-unset direction was open. Zero
with the flag unset stays legal, because that is how "no expiry" is spelled, and an iff
would have turned it into "expired at the epoch".

Two notes on the shape of the fix. It has **no mirror in `reference/policy.js`**, and
that is not an omission: the model has no flags, so `expiresAt: null` is the only way it
can say "no expiry" and the value and the flag cannot disagree there. The contract needs
the rule precisely because it encodes "unset" as a zero in a field of its own, and the
Solidity test that pins it — `test_createMandate_expiresAtWithoutTheFlag_reverts` — has
to set a `totalCap` first, because `Unbounded()` at `v2:424` is checked before every
`BadConfig()` and would otherwise be what fires.

`expiresAt` was the last field in the struct that could lie; the enumeration of all
thirteen `Mandate` fields and the three structs beside it is in §6, and it is now closed.

---

### F2 — `DESIGN.md`'s flagship worked example specifies a mandate v2 refuses to create, and its central claim was already false in v1

**Severity: medium (documentation, fail-closed) · Status: OPEN, owned by #26 · Confidence: certain.**

The narrative at `DESIGN.md:59-97` is the document's opening argument and the clearest
statement anywhere of what Remit is for. It specifies a mandate with an allowlist, a
**€5,000 per-transaction cap**, a **rolling 24-hour cap of €15,000**, and a **€10,000
co-signature threshold**. Three things are wrong with it, and they were found one at a
time, which is itself the point — each new grant-time guard re-audits every configuration
the repository has ever printed.

**It cannot be created under v2, for the co-signature reason.** The reachability guard
added in #11 computes `effectiveMax = min(2^96 - 1, perTxCap, minWindowCap) =
min(5,000, 15,000) = 5,000` and refuses when `effectiveMax <= cosignThreshold`.
5,000 ≤ 10,000, so `createMandate` reverts `BadConfig`. A payer following the canonical
example lands on a revert.

**It cannot be created under v2, for a second and independent reason.** As specified it
carries no `totalCap` and no `expiresAt`, so #22's narrowed guard at `v2:424` reverts
`Unbounded()` — and `Unbounded()` is checked *first*, so it is the error the payer
actually sees; the co-signature defect is hidden behind it. This one is not a
pre-existing flaw the way the other two are: v1 accepted the configuration, and #22
made it invalid. That is the honest description, and it is the expected cost of the
decision recorded in F5 rather than an argument against it. The narrative already
implies a horizon — it is a story about one night in a company's ordinary
operations — so naming one is an addition rather than a change of meaning.

**Its conclusion was already false in v1.** The narrative says: *"Suppose they aimed at
€12,000, under every cap. That is above the €10,000 co-signature threshold, so Ada is
asked."* €12,000 is not under every cap — it is over the €5,000 per-transaction cap, so
v1 refuses it at `OverPerTxCap` and Ada is never asked. The example's stated
configuration could never have produced the human-in-the-loop moment the paragraph
exists to demonstrate. The v2 guard did not break the example; it detected that the
example had been broken since it was written, which is exactly what that guard is for.

This is the #11 pattern again, one layer out: the repository asserted a protection its
own configuration could not deliver. It matters more than an ordinary documentation
defect because this is the passage a payer reads to learn how to configure the thing.

**Fix:** the constraints determine the numbers almost uniquely. Raising the
per-transaction cap to **€12,000** and leaving the threshold at €10,000 satisfies all
five requirements the narrative makes: €48,000 is still refused by the cap; ten × €4,800
is still stopped at the fourth by the €15,000 rolling window (3 × 4,800 = 14,400 fits,
19,200 does not); €12,000 is now permitted by every cap — at the per-transaction cap
rather than under it, which passes because `spend` tests `amount > perTxCap` strictly —
and above the threshold, so Ada is asked; ordinary €4,800 invoices stay below the
threshold, preserving the "once, rather than two hundred times a month" point; and
`effectiveMax = 12,000 > 10,000`, so #11's guard accepts it. Lowering the threshold
instead would work arithmetically but would put it below the €4,800 routine invoice and
ask Ada about all of them. **Plus a lifetime bound**, for `v2:424` — an `expiresAt`
rather than a `totalCap`, since the narrative's caps are about rate and blast radius and
a lifetime total would be a fourth number the story does not need.

Every other worked configuration in the repository needs the same check against **both**
grant-time guards, which is a sweep, not an edit. #22 has already swept for `v2:424`;
what remains for #26 is #11's reachability guard.

---

### F3 — The `uint32 spendCount` panic shadows the named `TotalSpentCeiling` error that #10 added

**Severity: low as a fault, medium as a correction to a documented rationale · Status: FIXED 2026-08-30 (#24) · Confidence: certain on the arithmetic.**

`m.spendCount += 1` at `v2:697` is the only checked arithmetic site in the contract with
no guard in front of it, and `spendCount` is `uint32`. At 2^32 spends it raises
Panic 0x11 rather than a named error. `CHANGELIST.md:294` already notes this and
dismisses it as "a genuine difference in reachability rather than a convenience
excuse", which is true in isolation and wrong as a comparison.

`TotalSpentCeiling` needs cumulative spending near 2^96 ≈ 7.92e28 base units. Nothing
forbids `recipient == m.payer`, so a self-spend preserves the balance and the sequence is
sustainable. Reaching 2^96 in fewer than 2^32 spends requires an average amount of at
least 2^96 / 2^32 = 2^64 ≈ 1.84e19 base units, i.e. **about 18.4 trillion USDC**.
Circulating USDC is roughly 6.1e10 USDC, some 300× below that, so in precisely the
`F_TOTAL`-unset case that `v2:682` was written for, the illegible panic fires about 300×
sooner than the legible error, for every balance that can actually exist.

[**#28, F19: "Nothing forbids `recipient == m.payer`" stopped being true on 2026-08-28** and this
is the only argument anywhere in the document that was leaning on it, which is why it is corrected
here rather than deleted. The conclusion survives while one step of the reasoning does not.
**What breaks:** the self-spend was the *cheap* way to sustain 2^32 spends, since it returned the
money in the same transaction, and `spend` now reverts `SelfPayment` before the transfer. **What
does not break:** the sequence is still sustainable, though no longer free — a recipient can return
the funds to the payer outside Remit, which the contract neither sees nor prevents, so an attacker
with one cooperating address and enough gas still gets an unbounded cumulative `totalSpent` from a
finite balance. The 300× figure is a *ratio between two ceilings* and never depended on how
the balance was recycled, so F3's actual claim — that the unnamed panic fires first on the path
#10 claimed to have fixed — is untouched. **F19 makes reaching either ceiling more expensive
without changing which one is reached first.** This is recorded because a fix in one finding
falsifying a premise in another with nothing failing is the failure mode this document is most
exposed to: there are 37 findings as of 2026-08-29 — 28 when this paragraph was first written, and
**40 as of 2026-08-30**, which is twelve more chances for the same unnoticed falsification than the
paragraph opened with and no new tooling against it. F40 is the clearest instance yet, and it ran
the other way: a sentence in F17's own note, written to justify an exclusion, kept a permanent
refusal out of the approval path for two revisions while every test in the file passed. The two
mutation gates are the nearest thing, and they do not cover it — they ask whether a test notices a
broken guard, not whether a prose argument in §4 still holds after the guard it cited changed.]

Both are unreachable in practice and neither risks funds — `v2:697` sits above the
transfer, so nothing moves. The finding is that #10's stated achievement ("a denial with
a name instead of a panic") is not delivered on the path it claims, and the source
comment at `v2:669-674` reasons only about the `F_TOTAL`-set case.

Note also that the reason given for declining to widen `totalSpent` — it would change
the `Spend` event signature and therefore its topic0 — **does not apply to
`spendCount`**, which is confirmed absent from the `Spend` event (the event carries
`uint96 totalSpent` and no counter). Slot 3 has exactly three spare bytes: 29 of 32
used, per the layout comment `12 + 5 + 5 + 4 + 1 + 1 + 1 = 29`, since restored.

**Fix — and the three options are not independent.** Widening `spendCount` to `uint56`
would consume all three spare bytes exactly (`12 + 5 + 5 + 7 + 1 + 1 + 1 = 32`), and
`uint40` would consume one. Those are **the same three bytes** that
`CHANGELIST.md:298` reserves for the declined `totalSpent` → `uint120` option, so
taking them here forecloses that option permanently, and any widening past the three
spills `Mandate` into a fifth slot — which would add an SLOAD to every read path,
including the 139-cold-SLOAD budget that `MAX_JOINT = 8` was sized against.

The cheap branch is therefore the safe one for once: a named error and a guard,
`if (m.spendCount == type(uint32).max) revert SpendCountCeiling();`, which changes no
struct, no slot count, no event and no gas path. The honest minimum, independent of
whether the guard is added, is to correct `CHANGELIST.md`'s comparison, because the
current text argues the opposite of the arithmetic.

[**#24, fixed 2026-08-30 — the cheap branch shipped, and it shipped in two places.** The guard is
`if (m.spendCount == type(uint32).max) revert SpendCountCeiling();`, with a new
`error SpendCountCeiling();` beside the other thirty-seven. This finding sized that at one error and
one line, and it went in at one error and two guards, because F17's rule is that a refusal reachable
through `spend` is reachable through `approveCosignFor` in the same form, so the approval path
carries a mirror. Sizing a fix by counting the guard the finding names is how a mirror gets dropped,
and F17's `_assertSameRefusal` harness is what would have failed. The reference model carries the
pair too, as `Denial.SPEND_COUNT_CEILING` in `evaluate` and a refusal in its own
`approveCosignFor`, since F28 is the finding that exists for a divergence between the model and the
contract.

**Both new guards were mutated and both were caught**, in whole-target runs at a baseline of 219
green:

```
mutation gate: spend — 21 mutants, baseline 219 green
  caught       removed  SpendCountCeiling (line 1093)
               by: test_spendCount_atTheUint32Ceiling_deniesWithANameNotAPanic, test_f3_approvingOnAMandateAtTheSpendCountCeiling_isRefused   [2 failing]

mutation gate: approveCosignFor — 26 mutants, baseline 219 green
  caught       removed  SpendCountCeiling (line 1565)
               by: test_f3_approvingOnAMandateAtTheSpendCountCeiling_isRefused   [1 failing]
```

The model's pair was killed in the JS mutation gate at 35 of 35 for `evaluate` and 27 of 27 for
`approveCosignFor`, by *the uint32 spend counter denies by name rather than wrapping, whatever the
amount* and *cosign (F3): an approval on a mandate at the spend-count ceiling is refused*. **The
Solidity mirror has exactly one killer** — delete
`test_f3_approvingOnAMandateAtTheSpendCountCeiling_isRefused` and that mutant survives a green
suite, which is the shape F22's single killer had one finding earlier.

**What the guard leaves standing.** The panic is gone from the counter, and the counter was the only
place it lived. The 300× ratio between the two ceilings stands as written, because the guard changes
which error names the refusal rather than which ceiling a real balance reaches first.
`CHANGELIST.md`'s comparison was corrected in the same pass, so both halves of the honest minimum
above were met rather than one.]

---

### F4 — `revoke`'s comment claims there is no window in which a revoked mandate is still spendable. There is: the mempool.

**Severity: low (inherent, unfixable on-chain) as a risk, medium as a false claim · Status: OPEN · Confidence: high.**

The doc comment on `revoke` says revocation on Arc is stronger than on a
probabilistic-finality chain because "one confirmation is final and reorgs are
impossible, so **there is no window in which a revoked mandate is still live and
spendable**."

The reorg half is correct and confirmed by Arc's docs; the conclusion drawn from it is
wrong. Arc has a mempool and a rotating proposer — its own transaction-lifecycle page
lists *"Pending — Transaction is in the mempool, not yet mined"* as a state, and the
consensus page describes the proposer bundling pending transactions. Between a payer
broadcasting `revoke` and its inclusion, a spender watching the mempool can submit a
final spend, and which lands first is the proposer's choice rather than the payer's.
Deterministic finality removes uncertainty about whether an *included* transaction
stands; it says nothing about *ordering* among pending ones.

The exposure is bounded by the mandate's own caps — a front-running spender gets at most
one more spend within `perTxCap` and the remaining window and lifetime headroom, which is
the whole point of having caps. The exposure is not fixable inside the contract, and the
sentence as written would let a payer believe revocation is atomic with their decision to
revoke; the correct advice — size caps so that one final unpoliced spend is survivable —
follows only from the accurate version.

---

### F5 — `Unbounded()` guarantees that *a* bound exists, not that *lifetime exposure* is bounded

**Severity: medium as a legibility gap · Status: FIXED in v2 (#22), 2026-08-26 · Confidence: certain.**

v1's `hasBound` local was satisfied by `F_PER_TX` **or** `F_TOTAL` **or** `F_EXPIRY`
**or** any window, so a mandate carrying only a per-transaction cap of 100 passed, and
the delegate could spend 100 repeatedly, forever, until the payer's allowance was dry.
The same held for a window alone: bounded per window, unbounded over a lifetime.

Only `F_TOTAL` and `F_EXPIRY` bound total exposure. The contract's own comment beside the
check said *"refusing to mint an unbounded authority is the entire point of the
primitive, so it is enforced rather than documented"* — and what was enforced was weaker
than what that sentence promised.

`L3-VAULT.md:174` states this exactly and correctly, and concludes *"the vault must require
it in its own code."* As with F1, the knowledge was in the repository but was addressed
to a developer building a vault on top of Remit, not to the ordinary payer who reads
`README.md` and grants a mandate directly. Both passages have since been extended to record
what v2 changed — and in each case the conclusion the vault spec had reached survives the
narrowing, for reasons the spec now states rather than leaves as an inference.

Whether to *change* it was a real design question rather than an obvious fix. Refusing
`F_PER_TX`-only grants breaks legitimately open-ended arrangements (a subscription with a
monthly window and no end date is a reasonable thing to want). An opt-in strictness flag
was considered and is not available: `flags` is a `uint8`, bit 7 is the last free bit, and
it is already committed to `F_ALLOWLIST_ROOT` in #13, so a new flag would mean widening
`flags` to `uint16` — touching every check, every test and the `MandateCreated` signature.

**DECIDED 2026-08-26 — refuse. Implemented the same day in #22.** `v2:424` is now
`if ((flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)) revert Unbounded();` and the
`hasBound` local is gone. The open-ended case is served by setting a distant `expiresAt`,
which costs the payer nothing and makes the horizon explicit rather than absent; the
reasoning is the same one that retired the dead co-signature check in #11 — "merely
useless" is not a reason to allow a configuration whose display and whose enforcement
disagree. The comment quoted above is now true rather than aspirational.

Three consequences followed, and each cost something:

**The guard runs before every other validation.** `v2:424` precedes all six `BadConfig`
checks and `BadWindow`, so any revert-asserting test whose parameters lack a lifetime
bound now reverts for the *wrong reason* — and a bare `vm.expectRevert()` would still
pass while proving nothing. Seven tests in `test/` were in that position and each was
given an explicit horizon; `Cosign.t.sol`'s test for the dead co-signature check carries
the note.

**The test suites had to name a horizon rather than have one injected for them.** Both
`reference/policy.test.js` and `test/Base.t.sol` gained an explicit `FAR` constant and a
`withExpiry`-style helper that each mandate calls. Making the shared `grant()` inject a
bound would have repaired every failing test in one edit and, in the same edit, stopped
the suites from demonstrating that a real caller has to supply one. `FAR` in Solidity is
`type(uint40).max` rather than a plausible date, because `WindowInvariant`'s reachable
clock is `depth × (L + S + 1)` and `depth` is a `foundry.toml` knob the deep profile
already raises from 64 to 256 — a horizon safe under one profile and not another is a
trap. The contract permits it: `expiresAt` is only ever compared, never used in
arithmetic, at `v2:608` in `spend` and `v2:1012` in `isLive`.

**Every worked configuration in the repository had to be re-checked against it**, on top
of the #11 re-check that F2 already required. Two guards now, not one.

---

### F6 — A delegate can split spends to stay under the co-signature threshold indefinitely

**Severity: medium as a residual risk · Status: OPEN (documentation) · Confidence: certain.**

The gate is `amount > m.cosignThreshold`, per transaction. A mandate with
`perTxCap = 12,000` and `cosignThreshold = 10,000` and no window lets a delegate move
9,999 as often as it likes without ever asking anyone. The threshold caps the size of an
*unsupervised single payment*; it does not cap unsupervised *total flow*.

`DESIGN.md` handles splitting attacks against **caps** explicitly and well — the ten
× €4,800 passage exists for exactly that — and then does not apply the same reasoning to
the **threshold** one paragraph later. The mitigation is the same mechanism: pair
`F_COSIGN` with a rolling window, so that splitting exhausts the window instead of
evading the signature. That composition is the actual security property and it is
nowhere stated.

Note the interaction with F2: fixing the example's numbers should not produce a
configuration that carries this weakness unremarked, so the corrected narrative should say
why the window is what makes the threshold meaningful.

---

### F7 — `spend`'s reentrancy comment gives the wrong reason for a correct conclusion

**Severity: low · Status: OPEN · Confidence: high on the reasoning; one Arc behaviour unverified.**

The comment before the transfer says there is no reentrancy guard "because `usdc` is
immutable and set to Circle's token — **there is no attacker-controlled callee**."

The callee is Circle's token, but the *recipient* is chosen by the spender, subject only
to the allowlist when one is set. Whether that matters depends on a question Arc's docs
do not answer: on Arc, an ERC-20 `transferFrom` moves the native balance through a
precompile, and the docs state that "sending native value to a contract is not guaranteed
to succeed" without saying whether recipient code executes. Standard ERC-20 semantics say
it does not, and no ERC-20 calls its recipient — but that is an inference about a
precompile-backed token, not a documented guarantee, and it belongs in §5.

The conclusion survives either way, and for a better reason than the one given: **every
state write happens before the transfer, and the transfer is the last statement in the
function.** `m.totalSpent`, `m.spendCount`, `_usedNonce` and every window bucket are all
committed first. A reentrant `spend` would therefore see fully updated state and be
policed by every cap exactly like any other spend. The safety comes from
checks-effects-interactions, which holds unconditionally, not from an absence of
untrusted callees, which does not. Stating the weaker reason is what would let a future
change — a post-transfer hook, a callback, a generalisation to arbitrary tokens — look
harmless.

---

### F8 — The forward clock-drift budget for a rolling window is exactly `subLength` seconds, and `isLive`'s comment says there is none

**Severity: low as shipped, medium for short-window grants · Status: OPEN · Confidence: high on the arithmetic.**

`isLive` carries a careful comment arguing that nothing in the contract *grants* capacity
from a timestamp, on the grounds that window accounting has no upper bound on bucket
index "so a timestamp moved forward cannot age out live history and refill a cap", and
concluding that "the worst a nudged clock can do to a live mandate is shift the expiry
boundary."

The missing upper bound defends the **backwards** direction — a slot from the future stays
counted — and the named regression test for it (`Windows.t.sol`,
`test_ATTACK_backwardsClockCannotRefillTheWindow`) warps backwards.
Forward drift is a different matter, and the source comments inside
`_checkAndCommitWindows` and `policy.js` both scope the claim correctly to "a slot newer
than `b`"; only `isLive` generalises it to a direction where it is false.

Worked, with `L = 32, K = 32, S = 1, cap = 100`: at true t=0 and stated t=0, spend 100 —
bucket 0, ring slot 0, `{0, 100}`. At true t=31 with stated t=33 (drift 2s), `bucket = 33`
and `oldest = 1`, so slot 0's index of 0 fails `>= oldest`, `used = 0`, and a second 100
is accepted. The true trailing 32-second window at t=31 contains both: **200 against a
cap of 100.** The general threshold is drift > `subLength`, verified at `S-1`, `S` and
`S+1` across six geometries.

For the live Arc grant (`L = 86400, K = 24`, so `S = 3600`) the budget is an hour, which
is safe against any plausible proposer skew. For a `lengthSeconds = 32, buckets = 32`
grant — which `createMandate` accepts today — it is **one** second, and the smallest
constructible geometry (`lengthSeconds = 1, buckets = 1`, which passes all three window
checks) also has a one-second budget. Arc's docs say
timestamps come from the proposer's wall clock at one-second granularity and specify no
maximum accepted skew, so the margin cannot be bounded from the platform side.

The K+1 design buys exactly one sub-period of forward-drift immunity. That is a clean,
derivable number and it should be in the source instead of a claim that it is infinite.
**No existing test can see this**, because every window test records its ledger against
the stated clock, making real time and stated time the same variable — real time is
never an independent quantity in the harness, so no assertion can be written about the
gap between them.

There is a second, compounding reason the suite cannot see it: the smallest sub-period
any test ever *spends* through is `DAY / 24 = 3600` seconds. `WindowFuzz`'s `bucketsFor`
returns exactly `{2, 3, 4, 6, 12, 24}` over a fixed `lengthSeconds = DAY`, and
`WindowInvariant` pins `L = DAY, BUCKETS = 12`, so every spend in the suite happens in
the geometry where the drift budget is comfortable, and the geometries where it is one
second wide are the ones nothing exercises.

---

### F9 — `spendable` omits the `uint96` clamp that `spendableAcross` spends fifteen lines justifying

**Severity: note (unreachable with real USDC) · Status: FIXED 2026-08-30 (#24) · Confidence: certain.**

`spendableAcross` hoists `maxSingleSpend = type(uint96).max` and clamps every term, because
`policyHeadroom` returns `type(uint256).max` for a mandate bounded only by an expiry while
`spend` refuses anything above `type(uint96).max`; `spendable` calls the same
`policyHeadroom` and applies no clamp. Of the two reasons given for the clamp, overflow
does not apply here — there is no addition — but *correctness of the reported largest
single spend* does.

This is reachable only with a balance above 7.9e22 USDC against a ~6.1e10 USDC supply, so
it cannot arise with real USDC. It **is** reachable with `MockUSDC`, which means the test
suite can observe two sibling views disagreeing about the same mandate. One line makes the
pair consistent.

[**#24, fixed 2026-08-30 — one line, and it sits outside the mutation gate's reach.** `spendable`
now clamps its policy limit before folding in the allowance and the balance:
`if (limit > type(uint96).max) limit = type(uint96).max;`. The sizing in the row above was right
for once, at one line and nothing else.

**No mutant can reach a clamp.** The Solidity mutation gate rewrites one `revert X(...);` to `{}`,
an operator that finds unasserted refusals and nothing else. A clamp refuses nothing, and
`spendable` carries no `revert` at all: it is one of eleven view definitions in that position,
recorded in §5 as the largest known hole in the operator set.

**A test is therefore the whole of the available evidence, so it was read rather than counted.**
`test/Views.t.sol`'s `test_spendable_agreesWithSpendableAcross_forASingleMandate` asserts
`policyHeadroom` at `type(uint256).max`, shows the balance deciding below 2^96 with both views in
agreement, then mints `type(uint128).max` and asserts `spendable` returns exactly
`type(uint96).max`. A case that asserted only that the two views agree would pass against an
unclamped `spendable` for every balance a fixture normally sets up, which is why the clamped value
is pinned rather than compared.

**The pair is consistent now, and the disagreement it removed was visible only under `MockUSDC`.**
Real USDC cannot mint past 2^96, so the fix changes a number no payer will ever read and closes the
one place the suite could have watched two siblings contradict each other.]

---

### F10 — `policyHeadroom`'s doc comment counts four blind spots. There are five.

**Severity: note · Status: FIXED 2026-08-30 (#24) · Confidence: certain.**

The comment opens *"Four things can still deny a spend this function calls affordable"* and
enumerates the allowlist, the cosign threshold, both ERC-8004 checks and the nonce.
It omits the unconditional `TotalSpentCeiling` guard: for a mandate without `F_TOTAL`
whose `totalSpent` is near 2^96, `policyHeadroom` reports `type(uint256).max` while the
true largest single spend is tiny.

This is doubly unreachable, since it sits behind F3's astronomical path, and is listed
only because it is a *counted* claim in a comment. #12 recorded the same discipline: the
errors block had asserted a one-to-one correspondence that had never been counted, and
the fix was to count it; the same discipline applies here, one comment over.

[**#28:** the comment was edited on 2026-08-27 and the count was **not** fixed — F15 renamed
the function it points at, so the sentence now reads "may still need an `approveCosignFor`
first", and the word "Four" survived the edit that touched the line beside it. That is the
sharpest available demonstration of why a counted claim in prose is a liability: the comment was
open in an editor, being changed, and the stale number went straight past. The cosign item also
gained a second failure mode in the same change — an approval can now be present but lapsed,
denied with `CosignExpired` — which does not move F10's count, because it is a second way for
the same listed item to deny, but does mean "needs an `approveCosignFor` first" is no longer the
whole of what the co-signature requirement can do to a spend this function called affordable.]

[**#24, fixed 2026-08-30 — the cardinal was removed rather than incremented, and the reason arrived
inside the same pass.** The sketch above says "four → five". Incrementing would have been stale
before the pass ended: F3's `SpendCountCeiling` landed the same day and added a sixth denier to the
very list this finding counts, so a comment reading "Five" would have aged between two edits to one
file. The replacement names the deniers, counts none of them, and says why the count went — a
cardinal in a comment goes stale in silence, and this one already had, reading "Four" while naming
five and surviving an edit to the line beside it.

**Both unconditional counter ceilings are named now**, `TotalSpentCeiling` and `SpendCountCeiling`,
alongside the allowlist, the two ERC-8004 checks, the nonce, and the co-signature requirement in
both of its failure modes: absent, and present but lapsed as `CosignExpired`. That second pair is
what #28 recorded above as one listed item denying two ways, a shape a cardinal cannot carry and a
list can.

**Nothing any code does changed.** The comment is prose in a view's doc block, so the mutation gate
has no opinion about it and `forge fmt` leaves it alone, which makes a careful reader the whole of
the available verification. The rule that would have caught the original is #12's: count a counted
claim, or stop counting in prose.]

---

### F11 — `withdrawCosign` is missing both guards its sibling has

**Severity: low · Status: FIXED 2026-08-30 (#24) · Confidence: certain.**

`approveCosignFor` checks `payer == address(0)` → `UnknownMandate`, then
`F_COSIGN == 0` → `BadConfig`, then `msg.sender != m.cosigner` → `NotCosigner`.
`withdrawCosign` checks only the third. (The sibling was `approveCosign` when this was
written; F15 replaced it on 2026-08-27 and the replacement carries the same three checks in
the same order, so the asymmetry is unchanged.)

This is not exploitable: for an unknown mandate `m.cosigner` is `address(0)`, and
`address(0)` cannot send a transaction, so the call still reverts. It reverts with
`NotCosigner` where the truth is `UnknownMandate`, which misdirects whoever is debugging.
Two further consequences follow: a cosigner can emit `CosignWithdrawn` for a hash that was
never approved, putting a withdrawal in the audit trail with no matching approval; and
`revoke` likewise does not check `m.revoked`, so a mandate can be revoked repeatedly and
emit duplicate `MandateRevoked` events. For a contract whose product is a reconcilable
audit trail, event pairs that do not reconcile are a real if minor cost.

[**#24, fixed 2026-08-30 — two parts landed as sketched, and the third was falsified by a test that
already existed.** `withdrawCosign` gained both missing guards,
`if (m.payer == address(0)) revert UnknownMandate();` and
`if (m.flags & F_COSIGN == 0) revert BadConfig();`, in the sibling's order, so an unknown mandate
reverts with the truth instead of with `NotCosigner`. All three of its refusals were mutated and all
three were caught:

```
mutation gate: withdrawCosign — 3 mutants, baseline 219 green

  caught       removed  UnknownMandate (line 1647)
               by: test_withdrawCosign_onUnknownMandate_reverts   [1 failing]
  caught       removed  BadConfig (line 1648)
               by: test_withdrawCosign_withoutTheCosignFlag_reverts   [1 failing]
  caught       removed  NotCosigner (line 1649)
               by: test_withdrawCosign_byAStranger_reverts   [1 failing]
```

**The third part of the sketch was wrong, and a green suite is what proved it.** This finding says
"`revoke` likewise does not check `m.revoked`" and priced the whole fix at three lines. A guard there
would have turned `test/Bounds.t.sol`'s `test_revoke_isIdempotent` red, because that case asserts a
second revoke succeeds, on purpose and by name. Idempotence is the documented behaviour and the
duplicate event is the defect, so the condition belongs on the event rather than on the call.
`revoke` now wraps its write and its `MandateRevoked` inside `if (!m.revoked)`, and a second revoke
is still accepted while announcing nothing. **A fix sketch is a hypothesis, and the suite is
entitled to refuse one** — this one was refused by a case written earlier for an unrelated reason.

`withdrawCosign`'s spurious event went the same way. The function reads the reservation and the
approval before deleting either, and emits `CosignWithdrawn` only when one of them was really
present, so a withdrawal in the audit trail again implies an approval it can be reconciled against.

**Both conditional emits sit in the mutation gate's blind spot.** Neither is a `revert`, so no
mutant reaches either, and the two cases that pin them had to be read rather than counted.
`test_f11_aWithdrawalThatRemovesNothing_emitsNothing` records logs and asserts an empty list three
times, once with `bytes32(0)` against an unreserved nonce, so that zero is refused as a match for
an empty reservation rather than accepted as one.
`test_f11_eitherHalfOfTheRemovalIsEnoughToAnnounce` uses `vm.expectEmit` twice, once per half, and
then shows the freed nonce spendable again. `revoke`'s own two mutants were re-run for a moved body
rather than for a changed refusal, and both came back caught:

```
mutation gate: revoke — 2 mutants, baseline 219 green

  caught       removed  UnknownMandate (line 1356)
               by: test_revoke_unknownMandate_reverts   [1 failing]
  caught       removed  NotAuthorised (line 1357)
               by: test_revoke_byStranger_reverts   [1 failing]
```

**What the sizing missed.** Three lines became two guards, three local reads, two conditional
emits and one wrapped block across two functions, so the shape of the fix moved as well as its
size. The row above is left as written, because a triage estimate corrected after the fact stops
being a record of what was known when it was made.]

---

### F12 — A payer cannot enumerate outstanding co-signature approvals

**Severity: low · Status: OPEN (design note) · Confidence: certain.**

`_cosignApproved` is a mapping keyed by hash, and `isCosignApproved` requires the caller
to already know the hash — which means knowing the exact recipient, amount, ref and
nonce. A cosigner may pre-approve any number of future spends, and the payer has no
on-chain way to ask how many live approvals exist or what they authorise.

The `CosignApproved` and `CosignWithdrawn` events make this fully reconstructable
off-chain, and the repository's stated position is that the audit trail lives in events
precisely because the Memo wrapper cannot be relied on. This is therefore consistent with
the design rather than an oversight. It is listed because "the payer can see what authority
is outstanding" is a property a payer would reasonably assume of an oversight control, and
it holds only with an indexer.

**#28 improved the off-chain half substantially without touching the on-chain half, and the
distinction is the whole finding.** Before F15, `CosignApproved` carried the mandate id, the
hash and the cosigner — so an indexer could count outstanding approvals but could not say what
any of them authorised without a side channel that supplied the preimage. It now carries
`recipient`, `amount` and `validUntil` as data, so the log alone answers "what did this
authorise, and until when". F16's `cosignApprovalDeadline` also lets a payer who *does* know a
hash distinguish "never approved" from "approved and lapsed", which `isCosignApproved` reports
identically. What is still absent is enumeration: nothing on chain lists the live approvals for
a mandate, because a Solidity mapping has no iterator and adding an index would mean an array
write on every approval. The finding therefore stands as written and its severity is unchanged —
a payer with an indexer is now materially better served, and a payer without one is exactly as
blind.

---

### F13 — Grant-time validation does not exist for the ERC-8004 checks, so a typo produces a mandate that looks healthy and can never spend

**Severity: low (fail-closed) · Status: OPEN · Confidence: certain.**

`createMandate` checks that the registries are non-zero when the corresponding flag is
set, and that `minResponse != 0`. It does not check that `identity.agentId` exists, or is
owned by the named spender, or that any attestation exists under
`credential.requestHash`, so `F_IDENTITY` with `agentId = 0` — a struct field's default,
reachable by omission — yields a mandate that `isLive` reports true for and `spendable`
reports full headroom for, while every `spend` reverts `IdentityNotHeld`.

Fail-closed, so no funds are at risk; the failure mode is a payer who believes they have
delegated and has not. `policyHeadroom`'s comment already explains why the pre-flight
views deliberately make no registry calls, and that reasoning is sound. Grant time is a
different moment with different economics — it happens once, the payer is already paying
for storage writes, and it is the only point where a typo can still be cheaply refused.

**DECIDED 2026-08-26 — validate at grant.** That is two registry reads when the
corresponding flag is set, paid once. The accepted cost, which should be written into the
source beside the check so it is not rediscovered as a surprise: `createMandate` now
**reverts when a registry is unreachable**, which is a new failure mode for a function that
previously touched nothing external. That is the correct trade for a control whose whole
purpose is that the payer can believe it — but it means the grant path acquires a liveness
dependency the spend path already had, and `isLive`/`policyHeadroom` must keep making no
external calls, since their justification is unchanged.

Related: `_checkCredential` returns `CredentialMissing` at three distinct sites — the
registry call reverting (`catch`), a zero validator address, and a response *below*
`minResponse`. A payer debugging cannot distinguish "no attestation exists" from "the
attestation says this agent failed", which are very different facts about their agent —
the first is an integration problem, the second is a reason to revoke. The overload is
conspicuous rather than systemic, because the same function's other three branches are
precise: `CredentialWrongValidator`, `CredentialWrongAgent` and `CredentialStale` each
name exactly one condition. Splitting out a `CredentialFailed` for the `minResponse` case
would cost one error declaration and make "my agent is failing attestation" legible.

---

### F14 — The ring clamp's parity comment claims a conservatism it does not have

**Severity: note · Status: OPEN · Confidence: certain (pure reasoning, no reachability question).**

`_checkAndCommitWindows` computes
`uint64 oldest = bucket > w.buckets ? bucket - uint64(w.buckets) : 0;` and explains the
clamp as follows: *"Clamp instead of subtracting: 0.8 reverts on underflow, and the JS
model can go negative where this cannot. **Clamping to 0 counts more history, never
less**, so it stays on the conservative side."*

The clamp is correct and the divergence from `reference/policy.js` is harmless, but not
for the stated reason: clamping counts **exactly** the same history, never more.
`oldest` is used in exactly two places, and both are insensitive to the difference.
Inclusion is `slot.bucketIndex >= oldest`, and every bucket index is non-negative, so
`idx >= 0` and `idx >= (some negative)` are both unconditionally true. Eviction is
`cur.bucketIndex < oldest`, and `idx < 0` and `idx < (some negative)` are both
unconditionally false. In the only regime where the two implementations differ —
`bucket <= buckets`, i.e. a window younger than its own length — Solidity and JS include
the same slots and evict the same slots.

This is recorded because the sentence is doing real work: it is the stated justification for
a deliberate Solidity/JS divergence in the component with the highest defect history in
the project. "Identical, because every index is non-negative and therefore at least any
negative bound" is a stronger claim than "conservative" and is the one that is true. The
weaker version would survive a change that made it false — a signed bucket index, or a
negative sentinel — while appearing to still cover it.

This is the fourth entry in what is now a visible pattern (F4, F7, F8, F14): the guards
are right and several of the *reasons written beside them* are not. For a contract whose
comments are explicitly addressed to a future auditor, that is its own category of
finding, and it is the category this pass was best placed to find, since it requires
reading the prose against the code rather than either alone.

---

### F15 — The co-signer approves an opaque 32-byte hash, so what the payer buys is a second signature and not a second opinion

**Severity: medium as a degraded control, low as a fund risk · Status: FIXED in v2 (#28),
2026-08-27, but NOT the way this finding recommended — see "What actually shipped" at the end
of this section · Confidence: certain.**

`approveCosign(bytes32 mandateId, bytes32 hash)` at `v2:932` takes the hash and nothing
else. It checks that the mandate exists, that `F_COSIGN` is set and that the caller is the
named cosigner, then writes `_cosignApproved[mandateId][hash] = true`.
It never learns the recipient, the amount, the reference or the nonce, because a hash is
not invertible and the contract keeps no reverse index.

The transaction a co-signer signs therefore carries two 32-byte words and no readable fact
about the payment. Everything that makes the approval meaningful — that it is 5,000 and not
5,000,000, that it pays the vendor and not the agent — reaches the co-signer through a side
channel the contract cannot see, and the only on-chain way to check the claim is to call
`spendHash` (`v2:953`) with fields obtained from that same side channel and compare. A
co-signer on a hardware wallet sees `approveCosign(0x…, 0x…)`. Behind a Safe it is worse:
the second and third signers are approving a hash of a claim that was made to someone
else.

This is blind signing, and it belongs here rather than under UX because of what this
particular control is *for*. Every other control in the contract is enforced by the contract —
caps, allowlist, expiry, nonce, spender. The co-signature requirement is the one control whose
entire value is a human judgment, and the contract hands that human the least legible
object it has.

The exposure is bounded: an approval authorises exactly one spend, that spend
is still policed by every cap, the allowlist and the expiry, and no approval moves money
without the delegate also acting. A co-signer who signs blindly cannot be made to exceed
the mandate. What is lost is the payer's belief that a human reviewed the payment.

**The fix is additive and cheap: an explicit-fields entry point.**

```solidity
function approveCosignFor(bytes32 mandateId, address recipient, uint256 amount, bytes32 ref, bytes32 nonce)
```

computing the hash internally from `m.spender` and the arguments, then taking the identical
path to the identical mapping. `spend`, the events, the mapping and the existing function
are untouched, so nothing that works today can break. The calldata then carries the
recipient and the amount as fields, which a wallet, a Safe, a block explorer and an auditor
can all read. Using `m.spender` rather than a parameter also removes a footgun in the
public `spendHash`, whose `spender_` argument lets an off-chain caller compute — and a
co-signer then approve — a hash that no spend can ever match.

Two secondary properties fall out of it, and the second matters more:

- The hash can no longer disagree with the fields, because the contract derives it.
  `test_ATTACK_redirectingAnApprovedSpend_isRefused` and its two siblings already defeat
  the on-chain version of that attack at *spend* time, correctly. This defeats the *social*
  version at approval time: the agent can no longer show the co-signer one set of numbers
  and hand them the hash of another. The residual is address labelling — an agent can still
  claim `0xabc…` is the vendor — which is a different and much smaller problem, and one the
  allowlist is the right answer to.
- It makes F17's dead-approval check possible at all. `approveCosign` cannot refuse an
  approval for an amount at or below the threshold, because it does not know the amount.
  `approveCosignFor` does.

**What actually shipped, 2026-08-27, and where it departs from the paragraphs above.**

The proposal was additive: a new entry point beside the old one, "so nothing that works today
can break". That was rejected in favour of **deleting `approveCosign(bytes32,bytes32)`
outright**, and `spendHash` lost its `spender_` parameter in the same change. The reasoning
inverts the recommendation:

- A safe path that sits *beside* an unsafe one does not remove the unsafe one. Anything that
  can still be called still gets called — by an old integration, a copied snippet, or an agent
  that finds the two-argument form shorter. Leaving it in place would have converted a defect
  into a footgun and called it fixed, which is the same move as shipping a view whose display and
  enforcement disagree, refused twice already in #11 and #22.
- The `spender_` footgun in `spendHash` is a *removal*, not an addition. Widening the approval
  surface while leaving the hash constructor able to name a spender the mandate does not have
  would have left the social attack half-open: a co-signer could still be handed a hash that no
  spend could ever match, and now with a legible-looking function to approve it through.

Three consequences, none of them free:

1. **The ABI broke.** Two functions changed shape and one vanished, so nothing written against
   v1's ABI compiles or calls correctly against this tree. That is acceptable only because v1
   is a testnet deployment with no third-party integrations; it would not be acceptable after
   mainnet, and it is the strongest single argument in this document for finishing v2 before
   anyone builds on v1.
2. **`CosignApproved`'s topic0 changed**, because the event gained `recipient`, `amount` and
   `validUntil`. An indexer filtering on the old topic sees nothing and gets no error — no log,
   just an empty result, which is the worst failure mode an indexer has.
3. **The repository lost its only same-function gas anchor.** `approveCosign` was the one live
   Remit transaction that never touched USDC, which made it the cleanest control in
   `test/ArcParity.t.sol` for separating Arc's USDC premium from Remit's own cost — 53,114 gas,
   tx `0x29eb5c24…`. `approveCosignFor` is a different computation (196 calldata bytes against
   68, an extra cold `SLOAD`, an extra keccak, three data words in the log), so comparing it to
   that receipt would measure the redesign and call the difference an Arc property. The anchor
   is documented as lost in that file's header rather than repointed without comment, and the two
   assertions that depended on it were deleted rather than loosened. A v2 deployment will give a
   new anchor for the new function; it will not repair this one.

The cost in (3) was named before the change was made and accepted anyway, on the grounds that a
legible authorisation surface for a human co-signer outranks a gas measurement. That trade is
recorded here so it can be re-examined rather than rediscovered.

---

### F16 — An approval never expires, and the suite's own test shows one being consumed a day later under policy conditions that had refused it

**Severity: low as a risk, medium as an unstated property · Status: FIXED in v2 (#28),
2026-08-27 · Confidence: certain — the behaviour is pinned by an existing test.**

Nothing decays an approval: `_cosignApproved` is
`mapping(bytes32 => mapping(bytes32 => bool))` (`v2:266`), written at `v2:937` and cleared in
exactly two places: consumption in `spend` (`v2:693`) and `withdrawCosign` (`v2:945`). No
timestamp is stored, so an approval is good until it is used or withdrawn, for the whole life
of the mandate.

The persistence is deliberate and the reason given for it is a good one.
`test_approval_survivesAnUnrelatedFailure` in `test/Cosign.t.sol` says it: *"If a transient
window breach burned the signature, every retry would need the human again — which in
practice means the human starts pre-approving in bulk, and the control stops meaning
anything."* That is right, and it is the reasoning this repository should keep.

The same test then demonstrates the sharp edge, which nothing anywhere draws the
consequence of. It approves a 90 spend, has it refused by the rolling window at `t0`,
asserts the signature is still good, warps `DAY + DAY/12` so the window refills, and spends
the 90 successfully. The repository therefore already holds the receipt: **an approval outlives the
policy conditions under which it was given.** The co-signer approved a payment at a moment
when the policy would have refused it, and it settled a day later. Now extend the horizon —
#22 requires a lifetime bound and the recommended way to keep an open-ended arrangement
creatable is a distant `expiresAt` — and "until used or withdrawn" can mean years.

Compose with F12 and F15 and it is one situation seen from three sides: the payer cannot
enumerate outstanding approvals, the co-signer has no list either, and the remedy
(`withdrawCosign`) requires the co-signer to remember a hash they were never in a position
to read.

**What should change, and what it must not break.** A co-signer-supplied deadline:
`approveCosignFor(..., uint40 validUntil)` storing `validUntil` in place of `true`, with
`spend` refusing when `block.timestamp >= validUntil`. That keeps the test's argument fully
intact — a retry minutes or hours later still works, so no co-signer is pushed into bulk
pre-approval — while ending the multi-year tail. Three costs come with it.
The mapping's value type changes from `bool` to `uint40`, which was believed to be a
storage-layout change and therefore free before v2 deploys and impossible after; **that belief
was wrong, and it is corrected below rather than above so the original reasoning stays
readable.** A `validUntil > block.timestamp` guard is needed, since `0` is already the absent
value. `isCosignApproved` can keep its `bool` signature by returning `!= 0`, but would then be
withholding the fact a payer most wants, so it should gain a sibling that returns the deadline.

The sentence this paragraph used to end with carried one imprecision, corrected here because
it was wrong in a way that flatters the fix. It said the deadline "does not compose with the
bare `approveCosign` of F15 — an opaque-hash approval has no field to carry one". The second
clause is false as stated: `approveCosign(bytes32,bytes32)` could perfectly well have been widened to
`approveCosign(bytes32,bytes32,uint40)`, and a deadline would then have composed with an
opaque hash without difficulty. What is true is narrower and still sufficient: the *two*-
argument form has nowhere to put a deadline, so keeping the deadline meant either widening that
signature too — breaking its ABI, forfeiting the same gas anchor F15 forfeits, and getting a
function that is now three opaque words instead of two — or making the explicit entry point the
only path. That is an argument for F15, not a proof that a deadline is inexpressible without
it, and the difference matters because an argument that overstates itself is the thing this
document keeps finding in the contract's own comments.

**What actually shipped, 2026-08-27.**

`_cosignApproved`'s value type is now `uint40`, holding an exclusive deadline where `0` still
means "never approved"; `approveCosignFor` refuses `validUntil <= block.timestamp` and
`validUntil > block.timestamp + MAX_COSIGN_TTL` with a named `BadDeadline(validUntil)`, refusing
rather than clamping so that a co-signer who miscalculates learns it instead of receiving, with
no error, a different authority than they asked for. `MAX_COSIGN_TTL` is **30 days**, an upper
bound the finding above did not ask for: a co-signer-supplied deadline alone still permits a
co-signer to type a date in 2040, which is the multi-year tail with an extra keystroke.
`spend` splits the two denials — `CosignRequired(hash)` when nothing was ever approved,
`CosignExpired(hash, validUntil)` when something was and lapsed — because a delegate that
cannot tell "never authorised" from "authorised and you were too slow" will retry the wrong
one. `isCosignApproved` keeps its `bool` signature but no longer means what it meant: it now
returns `validUntil != 0 && block.timestamp < validUntil`, so it answers "would this be
honoured right now" rather than "is there a row in the mapping". `cosignApprovalDeadline`
exposes the raw value, including a lapsed one, so a payer auditing a mandate can tell "never
approved" from "approved and it expired" — which `isCosignApproved` reports identically.

**The correction the paragraph above defers to: there was no storage-layout deadline.**
The claim that `bool` → `uint40` on a mapping's value type is "free now and not after v2
deploys" is false, and `forge inspect MandateManager storage-layout` was run before any code
changed rather than after. A mapping occupies exactly one slot regardless of what it maps to;
the values live at `keccak256(key . slot)`, not in the declaring slot. All eight mappings sit
in slots 0–7 with `_cosignApproved` last at slot 7, and that is true of both versions.
Widening the value type moves nothing. F16 was therefore merely correct rather than
urgent, and it was done for the second reason. This is recorded because the false urgency
was in the triage table above and could have been used to justify rushing the change past
its tests, which is the failure mode and not the fix.

---

### F17 — The approval function accepts a revoked mandate and an amount below the threshold, writing approvals that can never be consumed

**Severity: low (fail-closed) · Status: FIXED in #28 on 2026-08-28 · Confidence: certain.**

**What shipped, and why it is seven times the size this finding predicted.** `approveCosignFor`
shipped with **17 guards** — **18 as of 2026-08-28**, because F19 landed the next day and F17's
own rule required it to; see F19 for why that is a rule and not an accident. Both numbers were
counted from the file rather than taken from the two-line estimate in the triage table above:
`grep -c "revert "` over the function's current bounds, lines 1116–1216, returns 19, and the
19th is the word `revert` inside a comment at 1145 — one more reminder that a grep counts text
and not guards. The list was not extended from the two shapes named below; it was **derived from
`spend`** by partitioning every refusal `spend` can make into permanent and recoverable, and
mirroring exactly the permanent ones. That method is what found the eleven this finding never
mentioned — `RecipientNotAllowed`, `ZeroRecipient`, `ZeroAmount`, `AmountTooLarge`,
`NonceAlreadyUsed`, `OverPerTxCap`, `OverTotalCap`, `TotalSpentCeiling`, `Expired`, and the two
mandate-relative `BadDeadline` bounds. `reference/policy.js` has the same count in its twin —
17 on the day, 18 now — derived independently from that file: the model and the contract agree
without either being matched against the other.

**The hard half was deciding what NOT to refuse.** `notBefore`, a full rolling window and an
unfiled ERC-8004 credential all *recover*, so a shortfall in any of them says nothing about
whether a spend will be legal when the co-signature is actually used. Refusing them would convert
caution into a payment that cannot be approved, which is the failure mode this finding does not
have a name for. Three tests assert those three must CLEAR, and the mutation gate injects each of
them as a guard the function is required not to have — because removal-testing cannot reach a
"must not refuse" claim at all.

**Both halves named below are closed, and the second is closed by construction.** Approving on a
revoked or expired mandate now reverts `Revoked` (1132) and `Expired` (1136), the latter ordered
above the deadline checks on purpose so a dead mandate is not told its deadline is wrong. An
amount at or below the threshold reverts `CosignNotRequired` (1173). The third shape §5 named
— an in-date approval outliving the mandate — is no longer *constructible*: 1189 refuses
`validUntil > m.expiresAt`, and a mandate without `F_EXPIRY` has no expiry to outlive, since
`createMandate` requires `F_TOTAL` in that case. That is a stronger closure than a test of the old
shape would have been, and it is the one place F17 removed a possibility rather than adding a
refusal.

**The evidence is a command, not this paragraph.** `python3 reference/mutation-gate-sol.py`
neuters each of the guards in turn and injects the four guards the function must not have; on
2026-08-28 all 21 mutants were caught by a named test against a baseline of 178 green, with 0
survivors and 0 inconclusive. Its first run was **not** clean, and what it found is recorded under
*"What a green suite cannot mean"* below: `TotalSpentCeiling` at 1164 survived a green 177,
because every existing assertion of that guard exercised the identical line in `spend` instead.
Twelve F17 tests covered eleven of its guards, and no reading of the test names would have said so.

**Re-run later the same day, after F19: 22 mutants, 22 caught, baseline 182 green.** The gate was
not edited to get there — it discovers its own targets by scanning the function for `revert `
filtered through `is_code()`, so F19's mirror became mutant 19 by itself. Two properties of that
design are worth stating because they are what makes the count trustworthy: the gate cannot be
made to agree with the contract by hand, and a guard added without a test that bites will show up
as a survivor rather than as a larger number. **The gate was also pointed at `spend` for the first
time on the same day** — `python3 reference/mutation-gate-sol.py spend`, which works because
`INJECTIONS.get(TARGET)` returns `None` and the injection block is skipped — and it returned 17
mutants, 17 caught. **The prediction on record was that it would find a hole, "the way the first
Solidity run found `TotalSpentCeiling` unasserted on the approve path", and it did not.** That
prediction was wrong for a reason that generalises: `spend` is v1's function with the whole
project's history of tests aimed at it, while `approveCosignFor` was one day old when the gate
found a hole. **A mutation gate's yield tracks how long the tests have had to accumulate, not
how important the function is** — which also means a clean `spend` run is the weaker of the two
results, not the stronger.

[**2026-08-30: both counts in the two paragraphs above are stale, and one sentence has gone false
outright.** "Injects the four guards the function must not have" is **five** for `approveCosignFor`
as of 2026-08-30, F22's mirror having joined F17's four. The sentence that turned false is the
parenthetical about `spend` — *"which works because `INJECTIONS.get(TARGET)` returns `None` and the
injection block is skipped"*. That target has an `INJECTIONS` entry of its own now, holding one
case, so the injection block runs for it rather than being skipped, and a bare `spend` run today
builds 20 mutants rather than 19. The historical figures beside them stand exactly as written: 21
mutants at a baseline of 178 green on 2026-08-28, and 17 for `spend` the same day.
**Read this pair as the reason a dated note beats an edit** — those numbers are evidence of runs
that happened, and a run's count does not improve when the gate later grows.]

The rest of this finding is kept as written, so that the gap between what it predicted and what
the fix cost stays visible.

The heading used to name `approveCosign`, which no longer exists — F15 deleted it on 2026-08-27
and `approveCosignFor` is now the only way to write an approval. The defect carried over verbatim,
so this finding is re-pointed rather than closed: **the mechanism below is unchanged and the
missing guard is still missing** [**as of 2026-08-27, which is when that sentence was true. It was
still true one day and one commit later, at which point 17 guards landed rather than the 2 this
finding sized — see the block above**]. The three checks are the same three (`m.payer != 0`,
`F_COSIGN`
set, caller is `m.cosigner`), in the same order, and #28 added only the two deadline bounds —
which constrain *when* an approval dies, not *whether* it could ever have been used. Two
sentences below are now too strong and are corrected in place with `[#28:` notes rather than
rewritten, because what F16 bounded and what it did not is the interesting part. `v2:NNN`
citations resolve against the `92445dd` blob as the banner says; the function they point into has
been replaced, and the guard they observe missing is missing from the replacement too.

`approveCosignFor` checks three things and none of them is whether the approval it is about to
write can ever be used, so two shapes get through.

**A revoked or expired mandate.** `v2:933-936` reads `m.payer`, `m.flags` and `m.cosigner`,
and does not read `m.revoked` or `m.expiresAt`. `spend` reads both in its first four lines
(`v2:600`, `v2:608`), so the approval is inert — but it is paid for, written to storage,
reported `true` by `isCosignApproved` forever [**#28: for up to `MAX_COSIGN_TTL`, then `false`.
F16 bounded the display at 30 days; it did not stop the approval being written, paid for, or
logged**], and entered into the audit trail as `CosignApproved` for a mandate that can never
spend again. `revoke` is not idempotent either (F11), so a payer's reconstructed timeline can
carry a revocation followed by approvals, twice over.

**An amount at or below the threshold.** The gate at `v2:691` is
`amount > m.cosignThreshold`, strictly, and there is no threshold setter anywhere, so a
hash naming an amount at or under the threshold describes a spend that will never consult
the mapping. That approval is permanently unconsumable, and because only the consuming
path and `withdrawCosign` ever `delete`, it also never goes away [**#28: still exactly true —
the deadline governs whether the row is honoured, not whether it exists. `cosignApprovalDeadline`
keeps returning the stale value until someone withdraws it**].

Neither risks funds. They are listed because this repository has now twice refused a
configuration on exactly this ground and written the reason into the source: #11 refused a
`cosignThreshold` no spend could ever reach (`v2:465`) and #22 refused an `expiresAt` that
nothing reads (`v2:446`), both on the stated principle that *merely useless* is not a reason
to allow state whose display and whose enforcement disagree. A live approval on a dead
mandate is that same shape one level down — `isCosignApproved` displaying an authority that
cannot exist. Either the doctrine is general or it was a preference about two fields.

The revoked-and-expired half is two lines inside the approval function. **The threshold half
was inexpressible when this finding was written and is expressible now:** F15 shipped on
2026-08-27, so the only approval entry point is `approveCosignFor`, which takes `amount` as an
argument and can compare it to `m.cosignThreshold` directly. That removes the reason this
finding was bundled with F15 and F16 as one change — F17 is now independent and can land on its
own.

Two things about F17 did NOT change when F15 and F16 shipped, and a reader might
reasonably assume otherwise of both:

- **The deadline does not fix this.** An approval written against a revoked mandate now expires
  within `MAX_COSIGN_TTL` instead of persisting forever, which bounds the lie's duration but
  does not stop it being told. `CosignApproved` is still emitted for a mandate that can never
  spend, and `cosignApprovalDeadline` still reports a future deadline on it for up to 30 days.
- **A third unconsumable shape now exists, and it is F16's.** `spend` does not clear an approval
  it refuses — it reverts, and a revert rolls back every write — so a lapsed approval sits in
  storage until someone calls `withdrawCosign`.
  `isCosignApproved` correctly reports `false`, so nothing is displayed as live that is not, and
  it is inert on every future block. It is noted here rather than as a new finding because it is
  the same shape as the two above: storage no one is obliged to clean, harmless and untidy.
  `withdrawCosign`'s own docstring says so.

---

### F18 — The co-signer cannot be rotated, and the only remedy resets the lifetime cap with no warning

**Severity: note · Status: OPEN (documentation) · Confidence: certain.**

`cosigner` is written once, in the struct literal at `v2:491`, and there is no setter — §3
already records that the contract has no setters at all. A co-signer who loses their key,
goes on leave or turns hostile therefore cannot be replaced. Above the threshold the
co-signer is a *liveness dependency*, so one who simply stops answering bricks the
high-value half of a mandate while the low-value half keeps working: griefing with no
on-chain remedy. The mirror-image move is available too — `withdrawCosign` can be front-run
into the block ahead of the spend that would have used the approval, so "the approval was
live when the agent submitted" is not a property. That is the F4 mechanism pointed the other
way, and it is a note rather than a finding because both directions *withhold* authority.
Neither can move money.

The payer's remedy is `revoke` and re-grant, and it always exists: the id is
`keccak256(DOMAIN, chainid, this, payer, salt)` (`v2:394`), so a fresh salt always yields a
fresh id. It carries a cost the payer has to be told about, because nothing in the interface
reports the reset.

**`totalSpent`, `spendCount` and every window ring belong to the mandateId, so re-granting
resets all of them.** A payer who meant "this agent may spend 10,000 ever", has spent 8,000,
and re-grants in order to swap a co-signer gets a fresh 10,000 unless they think to grant
2,000. `IMMUTABILITY.md:183-188` states exactly this arithmetic — for the *migration* case,
where the whole contract is replaced. The identical arithmetic applies inside a single
deployment to a change of any parameter at all, which is a far more ordinary event than a
migration, and nothing in the repository says so. That belongs in `README.md` beside the
revocation guidance, not in a document about immutability.

---

### What a hostile co-signer cannot do

This was derived by walking every site that reads `m.cosigner` or `_cosignApproved` — there
are seven, at `v2:266`, `491`, `692`, `693`, `937`, `945` and `979` — rather than by checking
a list of attacks, and it is recorded because a sweep that reports only findings tells a
reader nothing about what was ruled out.

**Re-derived against the working tree on 2026-08-27, after #28: the count is now eight, and
every conclusion below survives.** Under the same counting rule (the mapping declaration, the
`cosigner` write into the struct literal, and every read, write or `delete` of
`_cosignApproved`), #28 added exactly one site and it is `cosignApprovalDeadline`, a `view`.
The three that move — `approveCosignFor`'s write, `spend`'s read-and-delete, and
`withdrawCosign`'s delete — are the same three operations in the same three functions as
before. A view cannot be a capability, so nothing a hostile co-signer can do changed, which
is why the citations above are left pointing at the anchor rather than repointed: they are the
evidence for the ruling-out, and the ruling-out is what still holds. The one substantive
change inside an existing site is that `spend` now has **two** ways to refuse at the mapping
instead of one, `CosignRequired` and `CosignExpired`, and both are refusals.

- **Cause a transfer.** The only path to `usdc.transferFrom` is `v2:713`, inside `spend`, which
  requires `msg.sender == m.spender` at `v2:610`; and `v2:482` refuses `cosigner == spender` at
  grant time, so on one mandate the two roles can never be the same address.
  `cosigner == payer` *is* legal and is the ordinary case.
- **Escape a cap.** The mapping is consulted at `v2:692`, after the per-transaction,
  lifetime and window checks have all passed and committed — still true after #28, and
  `test_cosign_isCheckedAfterEveryCap` pins it. An approval satisfies extra conditions (two
  of them since F16, the second being that it has not lapsed); it cannot raise a bound.
- **Redirect or inflate an approved spend.** The hash binds recipient, amount and ref; three
  existing `ATTACK` tests pin it.
- **Replay an approval onto another mandate or another deployment.** Double-bound: the hash
  contains `mandateId`, `DOMAIN`, `block.chainid` and `address(this)`, *and* the mapping is
  keyed by `mandateId` as well. The `mandateId` term inside the hash is therefore redundant
  belt-and-braces rather than the guard it appears to be.
- **Inherit an approval from an earlier mandate.** That needs an id to be re-minted, and
  `payer` is never cleared, so `MandateExists` at `v2:395` refuses it forever. §3 carries
  this row already; it is restated here because `_cosignApproved` is one of the four
  per-mandate mappings deliberately left dirty on revocation, and a future "clear storage on
  revoke for the gas refund" change would break the invariant and reanimate all four
  mappings in the same edit.
- **Block a revocation, or extend a mandate.** `revoke` reads only `m.payer` and `m.spender`
  (`v2:909-910`), and nothing in the contract lets a co-signer write to a `Mandate`.

---

### F19 — `recipient == m.payer` is a legal spend that consumes every cap, moves nothing, and emits no system log

**Severity: low as a fund risk, medium as an audit-trail hole · Status: FIXED in #28, 2026-08-28 — `SelfPayment` is refused on both the spend path and the cosign approval · Confidence: certain on the contract; the Arc half is documented, one sub-case is still not.**

**Everything below the next paragraph is written in the present tense and describes the
contract as deployed at `0x0139…9Ff5`, where it remains true and unfixable.** What changed is
the working tree: `spend` refuses it at `contracts/MandateManager.sol:710` and
`approveCosignFor` at `:1160`. See the closing paragraph for what shipped and what it cost.

`spend` constrains the recipient twice and no more: `recipient == address(0)` is refused at
`v2:614`, and the allowlist is consulted at `v2:615` *only when `F_ALLOWLIST` is set*. On a
mandate with no allowlist, `recipient = m.payer` is therefore a valid spend. It passes every
check, consumes `perTxCap`, the window buckets and the lifetime cap, burns its nonce,
increments `spendCount` and `totalSpent`, emits `Spend`, and then performs
`usdc.transferFrom(payer, payer, amount)` — which moves nothing.

There are two consequences, and the second makes this more than a curiosity.

**A delegate can exhaust a mandate without being paid.** It gains nothing, so this is
griefing rather than theft: an agent that has been told to stop, or one that has been
compromised by an attacker who wants the arrangement dead rather than drained, can zero the
lifetime cap in as many transactions as `perTxCap` requires and leave the payer holding a
mandate with no headroom. The remedy is `revoke` and re-grant, which is F18's remedy and
carries F18's reset of the lifetime cap.

**The audit trail cannot see it.** Arc's `usdc-system-events` reference states the rule
outright: *"Self-transfers (`from == to`) emit no log."* The EIP-7708 system emitter at
`0xffff…fffe` — which the same page calls the universal record of balance changes, and which
`evidence/` reconciles against — is therefore silent for exactly these spends. A reconciler
diffing Remit's `Spend` events against native `Transfer` logs finds `Spend` events with no
counterpart and concludes the indexer dropped something. Remit's own guidance has to be:
reconcile from `getMandate(mandateId).totalSpent`, never from transfer logs.

**One sub-case is unsettled and belongs in §5.** Arc's rule is stated for the
*system emitter*. Whether the ERC-20 USDC contract at `0x3600…0000` emits its own 6-decimal
`Transfer` for a self-transfer is not stated anywhere in Arc's docs, and it is
precompile-backed, so standard ERC-20 behaviour is an inference rather than a guarantee. One
testnet transaction settles it. The finding does not depend on the answer — the 18-decimal
stream is silent either way — but the size of the hole does.

**This is the third time the repository already held the finding and had it addressed to the
wrong reader.** `L3-VAULT.md:492-496` states this exactly, including the missing system log,
under the heading `recipient == vault` — where the vault is the payer. It is correct, and it
is written for a developer building a shielded vault, not for the payer who reads `README.md`
and grants a mandate to a payroll bot. F1 and F5 had the same shape, which is now a pattern
worth acting on rather than noting a fourth time: **when a hazard is discovered while writing
a document for one audience, it has to be filed against the audience that can be hurt by
it.**

**The fix: refuse it.** `if (recipient == m.payer) revert SelfPayment();` beside
the existing `ZeroRecipient` guard, two lines including the error. A self-payment is never a
payment, and by the doctrine #11 and #22 already established — no state whose display and
whose enforcement disagree — a `Spend` event that transfers nothing is the purest example in
the contract, and refusing it closes the griefing vector as a side effect. The one
configuration it would break is a payer deliberately using a self-spend as a heartbeat or a
cap-burning kill switch, which no one here has ever wanted and which `revoke` does better.

**What actually shipped, and why it was twice the size this finding predicted.** The guard is
`if (recipient == m.payer) revert SelfPayment();` as sized above, but it went in **twice** —
`spend:710` and `approveCosignFor:1160` — because F17 landed the day before this did, and
F17's rule is that every *permanent* refusal `spend` makes is mirrored in `approveCosignFor`.
The mirror is not a judgement call here. `m.payer` has exactly one write site in the whole
contract, `payer: msg.sender` inside `createMandate`'s struct literal; every other occurrence
is an `==` read, so the equality can never stop holding, which puts it in F17's permanent
partition beside `ZeroRecipient` — and `approveCosignFor` was **already** mirroring
`ZeroRecipient` one line above. Position matters too: `SelfPayment` sits between
`ZeroRecipient` and `RecipientNotAllowed` in both functions, shape before policy, because
`RecipientNotAllowed` would send the reader to edit a configuration that is not wrong.

Total cost: 1 error, 2 guards, 4 Solidity tests (3 in `test/Bounds.t.sol`, 1 in
`test/Cosign.t.sol`), 4 model refusals in `reference/policy.js` + `policy.test.js`, and 2 more
mutants per mutation gate — both went 21 → 22 without being edited, since each auto-discovers
its targets. Suite 178 → 182 green; model suite 69 → 72; both mutation gates 22/22 caught.
The cosign mutant `SelfPayment (line 1160)` has **exactly one killer**,
`test_f19_approvingThePayerAsRecipient_isRefused`, which makes that test the only thing
asserting the mirror, in the same way F17's `TotalSpentCeiling` case is — delete it and the
mirror stops being asserted at all.

**The sizing above — "two lines including the error" — was wrong, and it is the second
consecutive undercount.** F17 was sized at "two lines" and shipped as 17 guards; F19 was sized
at one guard and shipped as two. Neither estimate was careless about the guard itself; both
missed that a refusal in this repository is an edit propagated across the contract, the
reference model, two test suites and two mutation gates. **Every permanent refusal added to
`spend` from here on costs two guards, two model refusals and one extra mutant per
mutation gate.** That is now a rule, and any future finding in this document that proposes
a one-line guard should be read as proposing at least that.

**The deployed contract never exercised the behaviour F19 refuses, and that was checked rather
than assumed.** Every ERC-20 `Transfer` log in `evidence/*.log` was decoded — topic0
`0xddf252ad…`, then `from` and `to` off the next two topics — across all 31 live transactions.
`to` is the payer exactly once, in `premium.log`, and there `from` is the zero address, so it is
a faucet mint and not a spend. Every real spend runs `from` = payer `b56a7008…dcc0` to `to` =
`0x…c0de`. **No committed receipt therefore becomes unreproducible against the working
tree**, which is the property that needed confirming: F19 is the second fix in this document
to falsify a claim made somewhere else in the repository, and after F3's premise went stale
the cheap version of that check — grep the prose — is no longer good enough. Evidence has to
be re-derived from the receipts, because a log file is the one artefact in this repository
that must never be edited to agree with the code.

---

### F20 — The allowlist is frozen for the life of the mandate, so a recipient that turns hostile cannot be removed

**Severity: low · Status: OPEN (needs a decision) · Confidence: certain.**

`_allowlist` has exactly one write site in the contract: `v2:558`, inside `createMandate`'s
loop. There is no mutator, and §3 records why — the contract has no setters at all — so the
counterparty set is fixed at grant time. If an allowlisted vendor is compromised, changes
hands, or is simply finished with, the payer cannot narrow the mandate; they can only
`revoke` it whole and re-grant, paying F18's reset of `totalSpent`, `spendCount` and
every window ring.

The asymmetry matters because the repository sells the immutability as protection and only
ever describes the loosening direction. `CHANGELIST.md:18` puts it as v1 being
unable to *"raise a cap, drop an allowlist, or remove a cosigner requirement after the
fact"* — all three of which are the payer being protected from the operator. The same
property also stops the payer **tightening** a mandate they still want, and nothing says so.

**The decision, because it is not obvious.** A payer-only, remove-only mutator —
`removeRecipient(bytes32 mandateId, address recipient)`, requiring `msg.sender == m.payer`
and only ever writing `false` — is *monotone*: it can reduce authority and cannot grant any.
That makes it categorically different from a setter, and it is the one shape of state change
this contract could take without weakening its central claim. Against it: §3's "no setters,
no admin functions" is a sentence a payer can verify in ten seconds, and every exception to
it costs something to explain. It also needs its own event to keep the audit trail
reconstructable, and it raises the obvious next question — whether `F_ALLOWLIST` can be
turned *on* for a mandate granted without one, which is also monotone-tightening and which
this document does not recommend adding, because the flag is read in five places. The
recommendation is the remove-only mutator plus documentation of what it deliberately does
not do; the alternative is documentation alone, which is honest and leaves the payer with
revoke-and-re-grant.

---

### F21 — `ZeroRecipient`'s comment cites an Arc rule about a different mechanism

**Severity: note · Status: OPEN · Confidence: certain that the citation is off; the guard is right regardless.**

The comment at `v2:612-613` reads: *"Arc forbids value transfers to the zero address; reject
up front rather than burning the caller's gas on a guaranteed runtime revert."*

Arc's `usdc-system-events` reference says: *"A native value transfer (`CALL`, `CREATE`, or
`SELFDESTRUCT`) to or from the zero address reverts with 'Zero address not allowed'."* That
is a rule about the three native mechanisms. `spend` uses none of them — it calls
`usdc.transferFrom`, the precompile-backed ERC-20 path. The same page adds that mint and burn
*"are the only paths that produce a `Transfer` involving `0x0`, and they go through the
precompile"*, from which the ERC-20 path almost certainly refuses `0x0` too — but that is an
inference from an absence, not the documented guarantee the comment presents it as.

The guard is correct and should stay, for a reason that needs no Arc citation at all: with
`F_ALLOWLIST` unset, `recipient == address(0)` is the one recipient that could destroy the
payer's funds rather than misdirect them, and refusing nonsense at the top of the function is
right whatever the token does with it. Stating it as *"Arc reverts on this"* is the fifth
instance of the pattern F14 names (F4, F7, F8, F14, F21): a correct guard with a
justification that would not survive scrutiny — and this one is the most brittle kind, since
it would go stale unnoticed if Arc changed a rule the guard never actually depended on.

---

### F22 — §2 listed five trust boundaries and omitted the most important one: the delegate can pay itself

**Severity: medium as documentation, none as code · Status: FIXED in this document, 2026-08-26 · Confidence: certain.**

Until today §2 named five boundaries — the payer's own account security, Circle, a
credential validator, publicity, and proposer ordering — and **the word "allowlist" did not
appear in the section at all.** Nowhere in this document, and nowhere in `README.md`, did a
sentence say that `recipient == m.spender` is a legal spend, so a compromised delegate needs
no accomplice: it pays itself, bounded only by the caps.

This was found by enumeration rather than by review. The recipient sweep asked which values
of `recipient` are legal, got the answer "everything except zero, plus the allowlist when
set", and then asked which of those legal values §2 had told the payer about. The answer was
none of them. The section had been assumed to cover it, because it is the premise the whole
design rests on — an assumption that survives a review and dies to a grep.

**Why it matters more than it looks.** The gap is not that a reader would think a delegate
cannot steal; anyone who understands "spending mandate" knows better. The gap is that
`F_ALLOWLIST` reads, in the current documentation, like one convenience flag among six.
It is not: it is the only flag whose presence changes *what kind* of bound the mandate is —
without it the payer has bounded an amount, with it they have bounded an amount and a set of
counterparties. A payer choosing flags from a list has no way to know that one of them
changes the nature of the bound and the other five do not.

**Fixed by the new §2 paragraph above**, which states the self-payment, states that it is
unfixable by construction, and says plainly which claim about Remit is false ("the delegate
cannot steal") and which is true. The residue is `README.md`, which describes the flags
without ranking them — that folds into F18's documentation pass rather than needing its own.

[**2026-08-30: the §2 paragraph was the whole fix for four days, and a paragraph is not
executable.** F22 was filed and closed as documentation, which was right — the defect was that §2
never said `recipient == m.spender` is legal. What went unasked is whether anything *enforces* the
legality the paragraph asserts, and the answer was nothing. `reference/policy.test.js` asserts it
by name, while the 209-case Solidity suite had never named the delegate as a recipient at all,
checked by grep over `test/` rather than assumed. **A trust boundary that only prose defends is one
edit away from deletion by accident**, and the edit is small: F19's guard at
`contracts/MandateManager.sol:983` reads `if (recipient == m.payer) revert SelfPayment();`, and
changing `m.payer` to `m.spender` there inverts §2's most important sentence while leaving the
error name, the line count and the shape of the file untouched. **One identifier is the whole
product.** Three cases hold it now — `test_f22_theSpenderMayBePaidByItsOwnMandate` and
`test_f22_anAllowlistIsWhatStopsTheSpenderBeingPaid` in `test/Bounds.t.sol`, plus
`test_f22_approvingTheSpenderAsRecipient_isAccepted` in `test/Cosign.t.sol` — and the mutation gate
carries that exact inversion as an injection on both `spend` and `approveCosignFor`, caught
by three named cases on the first and by exactly one on the second. The status row above still
reads DONE 2026-08-26 and stays that way, because the documentation fix did land that day; what is
added is that the property became falsifiable four days later. **F19 and F22 are opposite claims
wearing one error name**, so a mutation gate holding both directions is the point — removal proves
`m.payer` is refused, and injection proves `m.spender` is not.]

---

### What a hostile recipient cannot do

Derived from the four sites that read `recipient` inside `spend` — `v2:614`, `615`, `690`,
`713` — plus the allowlist's single write site.

- **Reach any Remit state.** A recipient is an address in an argument. It is compared to
  zero, looked up in a mapping, hashed, and passed to `transferFrom`. Nothing about a
  recipient can influence a cap, a window, a nonce or a flag.
- **Reenter profitably, if Arc executes recipient code at all** (unresolved, §5, bears on
  F7). `v2:713` is the last statement in `spend` and every state write precedes it, so a
  reentrant spend meets fully-updated state and is policed by every cap like any other. That
  is checks-effects-interactions, and it is why F7 argues the conclusion is right for a
  better reason than the one written down.
- **Escape the allowlist.** The check is a direct mapping read at `v2:615` with no
  normalisation, no fallback and no wildcard, against keys written only at `v2:558`.
- **Consume a cap by refusing the money.** A recipient that reverts on receipt, or that is
  USDC-blocklisted, unwinds the whole spend — no cap consumed, no nonce burned. The cost
  lands on the delegate, who paid the gas, not on the payer. Arc's own documentation of
  blocklist reverts consuming the submitter's gas is what makes that precise.

**Two things checked here that are deliberately *not* findings.** `p.allowlist.length` has no
maximum, making `v2:556-559` the only loop in the contract bounded by nothing but the block
gas limit — but the allowlist is never iterated in `spend`, which does a single mapping read, so
`MAX_WINDOWS`-style bounding would protect nothing; an over-long allowlist fails at grant
time, at the payer's own expense, discoverably. Arc's *"zero-value transfers emit no
log"* rule cannot bite, because `v2:617` refuses `amount == 0` before any transfer is
reached.

---

### F23 — The two ERC-8004 registries are a trust boundary §2 never names, and Remit cannot re-point them

**Severity: medium as documentation, none as code · Status: FIXED in this document, 2026-08-26 · Confidence: certain about the omission, certain about the immutability, second-hand about the proxy.**

`identityRegistry` and `validationRegistry` are `immutable` (`v2:168-169`, assigned once at
`v2:361-362`). §2 names Circle as a trust boundary *because USDC has an upgradeable
implementation*, and names a credential validator as a trust boundary *because it can lie,
including about time*. Neither sentence covers the registries themselves, and until today the
strings `registry`, `8004`, `proxy` and `1967` appeared **nowhere in §2**.

They belong there, because the registries are the one dependency Remit calls that is neither
Circle's asset nor the payer's chosen counterparty. `MockRegistries.sol`'s own header records
that on 2026-08-24 the live Arc Testnet ValidationRegistry at
`0x8004Cb1BF31DAf7788923b405b754f57acEB4272` was found sitting **behind an ERC-1967 proxy and
can therefore be upgraded under Remit**. That fact was established by inspection rather than
found published: Arc documents the three registry addresses **only in a tutorial**
(`/arc/tutorials/register-your-first-ai-agent`), and **not** in
`/arc/references/contract-addresses`, which is the notes-bearing reference table that does
carry USDC, the CREATE2 factory, Multicall3 and Permit2. There is no stability guarantee, no
upgradeability statement, and no deprecation policy for these addresses anywhere in Arc's
documentation. A payer relying on either registry check is relying on a tutorial.

**What a hostile or replaced registry can actually do.**
Both checks are conjunctive and can only ever *refuse* a spend or *fail to refuse* one, so a
compromised registry can make `ownerOf` return the spender and `getValidationStatus` return a
fresh passing attestation about the expected agent, and the effect is that **a mandate with
the registry checks set degrades to one without them**. It cannot raise a cap, extend an
expiry, reach the allowlist, or move a single unit beyond what the amount bounds already
permit. That is a reassuring bound and it should be stated rather than left to be inferred:
the ERC-8004 checks are a *narrowing* layer, and their failure mode is to widen back to the
caps, never past them.

**What makes it worth a finding anyway is that the address is immutable in a contract with no
upgrade path.** If a registry is replaced with something adversarial, Remit cannot be pointed
at a new one — there is no setter, by design (§3), and no proxy, by design
(`IMMUTABILITY.md`). The payer's only remedies are the two they already have: never set
either flag, or revoke. Both are real, and neither is discoverable from the current
documentation.

**Fixed by the new §2 paragraph above**, which is that section's **seventh** boundary — F22
added the sixth an hour earlier, which is its own comment on how complete §2 felt before either
sweep ran. The paragraph states the immutability, states the proxy, states that Arc documents
these addresses in a tutorial rather than a reference, and states the bound: a hostile registry
degrades a mandate with the registry checks set to one without them and cannot do more. The
residue is a `README.md`/`DESIGN.md` note that the two registry flags carry a dependency the
other four do not, and that folds into F18's documentation pass.

---

### F24 — The grant-time registry guard is an address check, not a code check

**Severity: low · Status: open, and one of its two possible answers is not something this pass can settle · Confidence: certain about the guard, explicitly unresolved about the consequence.**

`createMandate` refuses a flag whose registry is missing — `v2:447` for `F_CREDENTIAL`,
`v2:448` for `F_IDENTITY`, both `BadConfig` — and `Creation.t.sol:657`
(`test_createMandate_gateWithoutRegistry_reverts`) pins both halves against a manager
constructed with `address(0), address(0)`. That is the right guard and it is tested.

It compares against `address(0)`. A registry address that is **non-zero and has no code** —
one digit wrong, an address from a different chain, a contract that was never deployed there —
passes it, and the mandate is created looking healthy. Every spend that consults a registry
then reaches `try validationRegistry.getValidationStatus(...)` or
`try identityRegistry.ownerOf(...)` on a codeless address, where the `CALL` succeeds and
returns nothing.

**Whether the bare `catch` catches that is unresolved here, and is not guessed at.** The external
call does not revert, so what fails is the ABI decode of the expected return — a six-component
tuple at `v2:852-854`, a single `address` at `v2:827` — and whether Solidity 0.8.28 routes a
decode failure into the `catch` clause or reverts the calling frame uncaught decides which
error the payer sees. Both outcomes are denials, so no funds are at risk either way; the
difference is `CredentialMissing()` and `IdentityNotHeld()` versus an opaque revert with no
selector. **No test covers it**, because `Base.t.sol`'s `setUp` constructs the manager with two
live mocks and `Creation.t.sol:658` is the only other construction, using zero.

The test that settles it is four lines and belongs in #23:
`new MandateManager(address(token), address(0xdead), address(0xdead))`, grant a mandate with a
registry flag set (which now succeeds, since `0xdead != address(0)`), spend, and assert
whichever revert actually comes back. Note the same class applies to `_usdc`, which `v2:359`
zero-checks and does not code-check — a codeless non-zero USDC makes every spend fail at
`v2:713` instead.

**Why this is only low severity, and why it is recorded anyway.** It is a deployment error
rather than an attack, and one that shows up on the first spend that consults a registry, yet
it composes with the two findings either side of it: F13 (no grant-time validation, so the typo
survives until a spend) and F23 (the address is immutable, so the remedy is a redeploy). The
three together are the argument for F13's fix being an *eager* check rather than a lazy one.

---

### F25 — `MockUSDC` emits a `Transfer` on a self-payment; Arc does not, and that is precisely the point F19 turns on

**Severity: none as code, medium as a trap · Status: FIXED in #28, 2026-08-28 — a `WHERE THIS MOCK DIVERGES FROM ARC AND WILL MISLEAD YOU` block in the mock's header plus a note at the `emit` itself · Confidence: certain.**

`MockUSDC._move` emits `Transfer(from, to, amount)` **unconditionally** at
`test/mocks/MockUSDC.sol:106`, including when `from == to`, whereas Arc's `usdc-system-events`
reference states the opposite for the system emitter:
*"Self-transfers (`from == to`) emit no log."*

Taken on its own that is an unremarkable mock simplification. It is a finding because of what
F19 asks for next. F19's whole claim is that a self-payment is invisible in the transfer log, so
it must be reconciled from `getMandate(mandateId).totalSpent` instead. The obvious way to pin
that claim is a test, and **a test written against `MockUSDC` would pass while demonstrating
the opposite of production.** It would observe a `Transfer` on a self-spend, and the mock
would be answering a question about Arc with this repository's own code.

This is the sharpest instance in the repository of the limit §5 already states in general
about `MockUSDC`, and unlike the general statement it names the exact test a developer is about
to write. The fix is a comment in the mock's header, beside the existing note about the
18-decimal dual view being unmodelled, saying that the unconditional emit diverges from Arc on
self-transfers and that no log-counting assertion about a self-payment means anything here.
`test/mocks/MockUSDC.sol` is not `contracts/`, so this costs nothing against the frozen
metadata hash.

**What shipped, 2026-08-28, alongside F19 rather than after it.** A titled block in the mock's
header — `WHERE THIS MOCK DIVERGES FROM ARC AND WILL MISLEAD YOU (F25)` — plus a three-line
note at the `emit` itself, now at `test/mocks/MockUSDC.sol:127-130`. Two decisions inside it
are worth naming because both could reasonably have gone the other way:

**The mock was left divergent on purpose; it was not corrected to match Arc.** Adding
`if (from != to)` around the emit would have made the mock *look* authoritative about a rule
that only a testnet transaction can confirm for the ERC-20 contract at `0x3600…0000`. Arc
documents the no-log rule for the 18-decimal system emitter at `0xffff…fffe` and says nothing
about the 6-decimal token. A mock that implemented the unconfirmed half of that anyway would
be a worse trap than the one this finding was filed about, because it would read as evidence.
The header says so explicitly, and names the testnet transaction as the only thing that settles
it — which is also how it stays on §5's list rather than disappearing from it.

**The comment names the assertion style, not just the hazard.** It ends by stating that F19's
guard is asserted with `vm.expectRevert(SelfPayment.selector)` in `Bounds.t.sol` and
`Cosign.t.sol` and **never** by counting logs. A warning that a test would lie is only half
useful; the reader still has to be told what to write instead. All four F19 tests follow it,
so the mock's header and the tests corroborate each other rather than the header being advice
no one took.

---

### F26 — The mocks' revert shapes do not match production's, and the bare `catch` arms are the only reason that is currently harmless

**Severity: informational · Status: open, one comment · Confidence: certain, and this is the weakest finding in the document.**

`MockRegistries.sol:88` declares `error NoSuchRequest(bytes32 requestHash)` and reverts with it
for an unknown request. Its **own header** records that the live registry does something
different: on 2026-08-24 three non-existent request hashes were queried directly and all three
reverted with the standard `Error(string)` selector `0x08c379a0` and the string `"unknown"`.
Two different revert encodings, one asserted-equivalent path.

Every test passes because both arms are bare — `catch { }` at `v2:859` (revert
`CredentialMissing`) and `v2:829-831` (set `owner = address(0)`, then deny at `v2:833`) — and a
bare catch is indifferent to revert data. **The bare catch is therefore the only reason the
divergence stays harmless, and nothing in either file says so.**

Two things keep this informational rather than real, and the first is the opposite of what the
narrowing looks like it would do. Narrowing either arm to
`catch Error(string memory)` — an obvious legibility improvement an auditor might well suggest
— would **fail loudly** rather than pass while wrong: the mock's custom error would no longer
be caught, it would propagate, and the gate tests would report the wrong error. The suite
defends itself here. `tag` and `responseHash` are the two tuple components the mock invents
(`tag: "compliance"` hardcoded, `responseHash` a `keccak256` of its own arguments), and
`v2:853` discards both with unnamed placeholders, so their fidelity cannot matter.

The residue is one comment in `MockRegistries.sol` recording that the divergence is deliberate
and that the bare catch is what absorbs it — so the next person to tidy the catch knows what
they are trading.

---

### What a green suite cannot mean, and four assumptions checked rather than assumed

Derived by reading the three files that decide what a green suite is evidence *of* —
`test/Base.t.sol` (361 lines), `test/mocks/MockUSDC.sol` (108, and **132 since F25**, which added
the divergence block described below), `test/mocks/MockRegistries.sol` (129) — rather than by
re-reading the tests themselves. The number of passing tests was 157 when this was written, 165
declarations in source after F15 and F16, **178** after F17, and **182** after F19 — the last two
derived twice each, from `grep -cE '^    function (test|invariant_)' test/*.t.sol` and from the run
log's own `13 test suites … N tests passed`, which agree. Nothing in this section depends on which,
because every limit below is a property of those three files. **The `invariant_` half of that
pattern is what makes the count right**: `^    function test` alone returns 179 rather than 182,
since `WindowInvariant.t.sol` declares three `invariant_` functions and no `test` prefix reaches
them. Getting that wrong is how the F19 sweep first reported 175 for a tree that was at 178.

**One limit is no longer structural, and this is what closing it looked like.** The heading's
subject used to be entirely a list of things a suite cannot reach. The largest thing a green
suite cannot tell you, however, is not in the mocks at all: it is whether any assertion would
*notice* a guard being removed. That question is answerable, and since 2026-08-28 it is answered
by command rather than by argument: `reference/mutation-gate.js` and
`reference/mutation-gate-sol.py` neuter one refusal at a time in a throwaway copy of the tree —
`throw refuse(` → `void refuse(`, `revert X(…);` → `{}` — and require a **named test** to fail
for each; a mutant that will not compile or will not run is reported INCONCLUSIVE and never
"caught", because a mutation gate that scored a broken mutant as a pass would manufacture
exactly the confidence this section exists to withhold. Each also *injects* guards the
function is required NOT to have, since removal cannot reach a "must not refuse" claim.
[**The figure here read "four guards" apiece when the sentence was written on 2026-08-28, and it is
neither of the two live figures now** — `reference/mutation-gate.js` reached 7 injections with
F27 and F28, while `reference/mutation-gate-sol.py` reached 6 on 2026-08-30, when F22's inversion
was added to `spend` and to `approveCosignFor`. The count has moved out of the sentence and into
this note, where going stale costs a reader nothing, which is the discipline F10 exists to argue
for.]

Both mutation gates found real holes on their first run, which is the only reason to trust
either. In the model, `BAD_CONFIG` survived a green 68 because neutering the no-cosigner check
left the same input refused one line lower under `NOT_COSIGNER` — no caller can be `null`'s
cosigner, so **two guards that refuse the same input for different reasons hide each other**.
In the contract,
`TotalSpentCeiling` at 1164 survived a green 177 for a plainer reason: nothing asserted it.
`grep -rn TotalSpentCeiling test/` returned two hits, both in `Bounds.t.sol`, both exercising the
*identical* guard on the `spend` path at 763. Coverage of one path reads, from any distance, like
coverage of both. Twelve F17 tests, eleven of F17's guards — and the twelve were green throughout.
The two mutation gates also disagreed with each other, which is its own finding: the model
already asserted that guard, so the JS mutation gate scored 21/21 while its Solidity sibling
scored 20/21. **When one mutation gate is clean and its twin is not, the delta is a divergence
report.** Both reached 21/21 on 2026-08-28 and **both are 22/22 later the same day**, F19's
mirror having enlarged each by one without either mutation gate being edited — they discover
their own targets, the JS one by scanning for `throw refuse(` and the Solidity one for
`revert ` filtered through `is_code()`. **A third run exists now and it is the one to be least
impressed by:** the Solidity mutation gate was pointed at `spend` for the first time and
returned 17 mutants, 17 caught. The prediction on record was that it would find something; it
did not, and the explanation is not that `spend` is better written — it is that `spend` has had
every test in the project aimed at it since v1, whereas `approveCosignFor` was a day old when
its own mutation gate caught `TotalSpentCeiling`. **Yield tracks the age of the tests, not the
importance of the function**, so a clean sweep over old code is weak evidence and a clean sweep
over new code is strong evidence, and this section should be read that way round.

What the mutation gates still cannot mean: neither performs operator swaps, so a `>` becoming
`>=` is invisible to both and only a boundary-tight assertion catches it. That is why the ceiling
test refuses at one base unit over and approves at exactly the limit, and why the model's
version — which sat ten units clear of the cliff and would have passed against an off-by-one —
was tightened to match rather than left as the twin that agreed for the wrong reason.

**One gap that F19 exposed rather than created: the JS mutation gate cannot reach `evaluate` at
all.** Its removal scan looks for `throw refuse(`, and `evaluate` denies by `return deny(…)`, so
the model's spend-path `SELF_PAYMENT` guard sits outside the JS mutation gate's reach — only
the `approveCosignFor` mirror is covered. This was true before F19 for every guard in
`evaluate`; F19 is simply the first finding whose fix lands on both sides of that line, which
is what made it visible. The Solidity mutation gate has no equivalent blind spot, since
`revert` is `revert` in both functions, and the spend-path guard is covered there as mutant
`SelfPayment (line 710)`. It is recorded here rather than fixed because extending the JS
mutation gate to `return deny(` is a change to the gate, and a gate edited in the same pass as
the code it judges is worth less than one that was not.

Four limits are structural, and no amount of test-writing moves them:

- **USDC is Arc's gas token and the mock has no gas coupling at all.** Foundry pays gas in
  ETH from a balance the mock does not model, so the entire class *"a spend succeeds and leaves
  the payer unable to fund their next transaction"*, and its mirror *"the delegate's own
  balance is consumed by gas until it cannot submit"*, is unreachable in CI by construction —
  not untested, untestable here.
- **The native/ERC-20 dual view is deliberately unmodelled**, and the mock's header says so
  with its reason (`MandateManager` only ever touches the ERC-20 interface), so the premise of
  the ARC NOTE at `v2:1077-1084` — one underlying balance, viewed at 18 decimals natively and 6
  through the façade, so `balanceOf` truncates — has no local counterexample and can only be
  established on Arc. The same note bounds how much that costs, which is why this is a limit and
  not a finding: the truncation is one-directional (`spendable` can under-report by up to
  1e-6 USDC and never over-report, so an agent trusting it at worst skips a spend it could have
  made), and `spendable` is **the only place the contract reads a balance at all** — the `spend`
  path never does, so no amount of truncation can change what a policy permits. An earlier draft
  of this bullet cited `v2:856-863` for that note, which is the credential `try`/`catch` body and
  has nothing to do with decimals; the number came from a summary instead of from the file.
- **No test stages a future-dated `lastUpdate`**, so §2's staleness boundary — the
  `nowTs > lastUpdate &&` conjunct at `v2:880`, which makes a future-dated attestation fresh
  forever — has no executing counterexample. Derived from all ten `setStatus` call sites: one
  in `Base.t.sol` at `block.timestamp - 100` and nine in `Gates.t.sol` at `block.timestamp` or
  a local `attestedAt` assigned from it. Every one is present or past.
- **The ERC-8004 ValidationRegistry has a third state neither the mock nor the live probe
  covers.** Arc documents a **two-step** flow — the agent owner calls `validationRequest`, then
  the validator calls `validationResponse` — so a `requestHash` can be *requested and
  unanswered*. `MockValidationRegistry` models a binary `set` flag, and the 2026-08-24 live
  probe used three hashes that had never been requested at all. Neither is the pending state.

Four assumptions were checked and hold, recorded because a sweep that only reports
defects gives no way to tell a verified assumption from an unexamined one:

- **`getValidationStatus`'s return tuple matches Arc's published ABI exactly.** Six
  components, same order, same types: `(address validatorAddress, uint256 agentId, uint8
  response, bytes32 responseHash, string tag, uint256 lastUpdate)` in Arc's tutorial ABI, and
  identically at `v2:151-156`, with `v2:853` skipping positions four and five as unnamed
  placeholders in the right slots. **This is the assumption a mock is structurally incapable of
  testing** — `MockRegistries` implements this repository's own declaration, so a wrong order
  would agree with itself and every test in the suite would pass while decoding garbage on Arc. It
  was the highest consequence item in this sweep and it is correct.
- **The pending state cannot pass the gate**, whichever way the live registry answers. A zero
  validator denies at `v2:863`; the requested validator with `response = 0` denies at `v2:879`,
  because `v2:563` refuses `minResponse == 0` at grant time. That guard is the one doing the
  work here, and its stated reason — the comment on its own line, and
  `Creation.t.sol:561`'s test name, both amount to *"0 would accept a failed attestation"* — is
  correct and does not mention this second consequence. Worth adding to it: the same line also
  makes an unanswered request unspendable.
- **The infinite-approval divergence cannot be observed.** `MockUSDC:90-91` skips the allowance
  decrement for `type(uint256).max`, claiming to match Circle's implementation, which is
  unverified against Arc. It cannot matter: `2^256-1` minus any `uint96` still exceeds every
  cap, so the allowance term in `spendable` and `policyHeadroom` is never the binding minimum
  either way. Finite allowances *are* exercised — nine explicit `approve` sites across
  `ArcParity`, `Idempotency` and `Views`, including two at `0`.
- **The constructor's zero-address asymmetry is deliberate and right.** `_usdc` is refused at
  zero (`v2:359`, pinned by `Creation.t.sol:673`); the registries are accepted at zero and
  refused only when a flag needs one (`v2:447-448`). A manager with no registries is a
  perfectly good manager for mandates that set neither flag, and forcing two addresses on a
  deployment that will never consult a registry would be worse. Likewise `MockUSDC.burnFrom`
  emitting `Transfer(from, address(0))` while bypassing `_move`'s zero-address refusal
  **matches** Arc, where burns happen only through the precompile.

---

### F27 — `expectedOwner` has three outcomes and two of them are useless: skipped, redundant, or a permanently unspendable mandate

**Severity: no fund loss and no bypass — the failure is total denial, not permission. Medium as a footgun, because the only value that does anything new is the one that kills the mandate · Status: open, belongs to #23 · Confidence: certain; derived from the contract, and the model agrees.**

`IdentityGate.expectedOwner` is documented at `contracts/MandateManager.sol:276` as
*"address(0) = do not pin, only require ownerOf == spender"*, and a payer reading that has every
reason to think the non-zero case pins the owner they intended at grant time. It does not, and
the reason is where the check runs rather than what it says.

`_checkIdentity` has **exactly one caller** — `spend` at `:725` — and `spend` has already run
`if (msg.sender != m.spender) revert WrongSpender();` at `:700`, so inside `_checkIdentity`
`owner == msg.sender` and `owner == m.spender` are the same statement. The two lines at the end
of the function are:

```solidity
if (owner == address(0) || owner != msg.sender) revert IdentityNotHeld();          // :941
if (g.expectedOwner != address(0) && owner != g.expectedOwner) revert IdentityTransferred(); // :942
```

Both compare against the same `owner`, and the first has already forced it to equal the spender.
Together they therefore require `expectedOwner == m.spender`. The second line is not a second
fact about the world; it is a second spelling of the first. That leaves three outcomes and no
fourth:

| `expectedOwner` | effect |
|---|---|
| `address(0)` | the pin is skipped — the documented and only sane configuration |
| `== m.spender` | the pin is **redundant** with `:941`, which ran one line earlier |
| anything else | **no caller can ever spend this mandate, for its whole life** |

Nothing refuses the third case. `createMandate` stores the struct verbatim at `:651`, and the
only grant-time check `F_IDENTITY` gets is `:538`, that a registry address exists — nothing about
the gate's contents. That is conspicuous rather than merely absent: **eight lines earlier
`createMandate` validates the neighbouring fields**, refusing an allowlist entry of `address(0)`
at `:646` and `credential.minResponse == 0` at `:652`. The identity gate is the one it stores
unread.

This is F5's shape (an `expiresAt` nothing reads) and F17's shape (a cosign approval nothing can
consume): **a configuration accepted at grant time that cannot work at spend time.** F17 was
fixed by refusing the unusable approval outright, and the same remedy fits here — refuse
`expectedOwner != 0 && expectedOwner != p.spender` in `createMandate`, which collapses the table
to the two rows that mean something. The alternative reading, that the pin is meant to survive
`m.spender` changing, has no support in the code: **`spender` is immutable for the life of a
mandate**, so there is no second owner the pin could ever be protecting against.

**How this was found, because the method is the transferable part.** Not by review — this
document's §3 enumeration walked past it twice. It came out of extending
`reference/mutation-gate.js` to `evaluate` on 2026-08-28: neutering the model's mirror of `:942`
killed no test, and the reason turned out to be that **every `expectedOwner` in
`reference/policy.test.js` was set to `AGENT`, which is also the spender**, so the guard had never
once been reached in a green suite. The question *"why is this guard unreachable in the tests"*
answered itself with *"because it is nearly unreachable in life"*. A coverage tool produced a
design finding, which is not what coverage tools are usually for.

**`test/Gates.t.sol:62-65` is a seventh instance of the #25 pattern — a wrong justification
beside a correct assertion.** Its comment explains the mismatch case as *"a distinct error,
because it means the mandate's assumptions changed rather than that the agent lost its key."*
The assumptions did not change. Nothing happened at all: the test's mandate is born unspendable
at grant time, and `test_identityGate_expectedOwnerMismatch_reportsIdentityTransferred` is
asserting the brick, not a transfer. The test is right and its name is right; the reason attached
to it teaches the reader the opposite of F27. It belongs on #25's list.

---

### F28 — The model reads `expectedOwner = address(0)` as a pin where the contract reads it as "do not pin", and the model is the wrong one

**Severity: informational for the chain, medium for anyone trusting the model — the divergence makes the reference implementation *stricter* than production, so it reports a live mandate as permanently dead · Status: FIXED in `af9df40`, 2026-08-29 — `reference/policy.js:699-702` now resolves the pin against `ZERO_ADDRESS` explicitly, and `reference/policy.test.js:2218` was rewritten to assert the agreement rather than deleted, which keeps the alarm and costs nothing. The status line below read "open, pinned by a test, one-line fix deferred to #23" until 2026-08-30, when this section was reconciled against the summary row that had recorded the fix a day earlier · Confidence: certain; both behaviours executed.**

`contracts/MandateManager.sol:942` tests `g.expectedOwner != address(0)` explicitly, implementing
the semantics its own `:276` documents. `reference/policy.js:578` tests bare truthiness:

```js
if (mandate.identity.expectedOwner && normalizeAddr(owner) !== normalizeAddr(mandate.identity.expectedOwner))
```

**The zero address as a JavaScript string is truthy.** So a mandate carrying
`expectedOwner: ZERO_ADDRESS` spends on Arc and denies `IDENTITY_TRANSFERRED` forever in the
model. Executed both ways rather than reasoned about: absent → allowed, `null` → allowed,
`ZERO_ADDRESS` → `IDENTITY_TRANSFERRED`, `== spender` → allowed.

The direction is what makes this worth a finding rather than a note. A model that is *looser*
than the contract invites a bad spend; a model that is *stricter* tells a payer their mandate is
bricked when the chain would honour it — and F27 above means a reader who is handed
`IDENTITY_TRANSFERRED` has every reason to believe it.

**This is the second instance of one hazard, and the file already knows about it.**
`test/Gates.t.sol:143-162` documents the first — `maxStaleness == 0` means "no freshness
requirement" in the contract, and it says in as many words that *"reference/policy.js currently
encodes zero the other way. The model is wrong; the contract is right."* A zero the contract
reads as **unset** and the model reads as a **value** has now appeared twice in the same two
registry checks. `policy.js` compares against its own `ZERO_ADDRESS` constant in four other places
(`:324`, `:527`, `:611`, `:956`), and `:623` documents this exact trap for `credential.agentId`
and handles it deliberately. `expectedOwner` is the one field left on truthiness — so this is a
missed instance of a rule the file follows everywhere else, not an unconsidered question.

**Pinned rather than fixed, and the reason is not convenience.** The one-line change belongs with
#23, which validates both ERC-8004 structs at grant time and is where F27 settles what
`expectedOwner` may contain at all; if `createMandate` refuses everything but zero and the
spender, the zero case becomes the *only* non-redundant value and the model's handling of it stops
being a detail. Changing `evaluate` in the same pass as the tests the mutation gate had just
demanded would also have muddied what the gate proved. Until then the divergence is asserted by
`policy.test.js`'s `identity gate (F28)` test, which fails the day the model is corrected — the
alarm being the point.

**Fixed on 2026-08-29, in the sequence this row asked for.** F33 below landed the grant-time
validation in `af9df40`, so `createMandate` now accepts `expectedOwner` only as zero or the
spender. That made zero the single remaining non-redundant value and the model's reading of it the
whole of the question, exactly as the row above predicted. `reference/policy.js:696` normalises
before comparing and treats `ZERO_ADDRESS` as "do not pin", and the pinning test at
`policy.test.js:2214` was rewritten from asserting the divergence to asserting the agreement.
`policy.test.js:2269` records the consequence for the suite: with a pin at anyone but the spender
refused at grant time, `IDENTITY_TRANSFERRED` is now unreachable through the ordinary path.

---

### F29 — A spend to this contract or to the USDC token is money no one can move again, and every recipient rule allowed it

**Severity: high — permanent loss of the transferred amount, with the caps, the nonce and the `Spend` event all recording an ordinary successful payment. Reachability is the delegate's alone, so a payer is exposed to a delegate's mistake or malice rather than to a stranger's · Status: FIXED in `af9df40` · Confidence: certain for `address(this)`, which is a property of this contract's own ABI; the token leg rests on one unverified link, named below.**

`MandateManager` calls exactly three USDC functions, and only one of them moves a balance:
`transferFrom` at `:1114`, inside `spend`, which always pays a third party. The other two are
`allowance` and `balanceOf`, both views, so USDC credited to `address(this)` has no exit — no
sweep, no owner, no rescue, and no upgrade path to add one later. The token's own address is the
same shape of hazard from the other side.

Before this fix a spend to either address passed every recipient rule the contract had.
`ZeroRecipient` refuses the zero address, F19's `SelfPayment` refuses the payer, and
`RecipientNotAllowed` refuses anything off the list — but the allowlist is optional, and the
widest mandate in the repository's own test helper sets none. On such a mandate the two most
destructive addresses on the chain were legal recipients, and the payment looked normal from every
angle a payer can see: the transfer succeeds, `totalSpent` advances, the nonce burns, `Spend`
fires, and a reconciler ticks it off.

The guard sits with the other shape checks, ahead of the allowlist:

```solidity
if (recipient == address(this) || recipient == address(usdc)) revert UnrecoverableRecipient(recipient); // :992
```

`error UnrecoverableRecipient(address recipient)` is declared at `:545` and carries the address, so
a caller learns which of the two it named. The refusal is mirrored in `approveCosignFor` at
`:1479`, under F17's rule that every permanent refusal `spend` makes is also made at approval time.

**What proves it.** `test_isAllowedRecipient_appliesEveryRecipientRuleSpendApplies`
(`test/Views.t.sol:439-465`) asserts both halves for both addresses: the view answers `false`, and
`spend` then reverts with the argument-encoded error. One test therefore covers F29's spend leg and
all of F36. The model carries the same refusal on both paths, at `reference/policy.js:634` for a
spend and `:1112` for an approval, with four `F29:` tests in `policy.test.js` including one that
proves the refusal lands ahead of the allowlist.

**The mirror at `:1479` is asserted by nothing, and that is a prediction rather than a worry.** No
Solidity test in the repository approves an unrecoverable recipient: the four occurrences of the
error in `test/` are all in `Views.t.sol`, and none of the 52 `approveCosignFor(` call sites names
the manager or the token, so the owed `approveCosignFor` mutation-gate run should report exactly
one survivor, at that line, and the repair is a test rather than a change to the contract. Written
down here so the survivor arrives expected. The model is ahead of the contract on this one point,
since `policy.test.js` does cover its approval leg.

**The one unverified link.** Whether Arc's precompile-backed USDC holds an administrative recovery
path for a balance credited to its own address is not readable from here, and if it does hold one it
belongs to Circle rather than to the payer. Neither answer changes the conclusion: `address(this)`
is unrecoverable whatever the token does, and a mandate primitive should not be able to spend a
payer's money into a place where recovery is someone else's decision. §5 lists the testnet
transaction that settles the related question of whether that token executes recipient code at all.

---

### F30 — A one-cent spend could burn the nonce out from under a co-signer's live approval

**Severity: high — a delegate could delete a human's approval decision at will and at negligible cost, leaving the approved payment permanently unmakeable while the approval still sat in storage reading as honourable · Status: FIXED in `af9df40` · Confidence: certain; executed as an attack test on both sides.**

A co-signature in v2 approves one exact request, and the request includes the nonce. The approval
lives in `_cosignApproved[mandateId][hash]`, keyed by a hash of nine fields. Nonces live in a
separate mapping, `_usedNonce[mandateId][nonce]`, and any successful spend sets one.

Nothing connected the two. A delegate holding a mandate with a co-signed approval outstanding could
send a spend of one unit to any allowed recipient, using the same nonce, and that spend would take
the ordinary sub-threshold path: below `cosignThreshold`, so no approval is required, no approval is
consumed, and the nonce is marked used on the way out. The co-signer's approval then referenced a
nonce that could never be presented again. The approval remained in storage, `isCosignApproved`
answered `true`, `cosignApprovalDeadline` returned a future timestamp, and the payment it authorised
was dead.

The cost of the attack was one unit of USDC against a cap the payer had already granted, so nothing
in the caps, the windows or the audit trail marks it as unusual. What made it worth a high rating is
the asymmetry: the delegate spends a cent and destroys a decision, and the co-signer's only recourse
is to notice, withdraw and approve again on a fresh nonce, which the delegate can defeat as often as
it likes.

The fix reserves the nonce for the exact hash it was approved against. `approveCosignFor` writes
`_cosignReservedNonce[mandateId][nonce] = hash` at `:1547`, and `spend` reads it back at `:1081`,
before the co-sign branch:

```solidity
bytes32 reservedHash = _cosignReservedNonce[mandateId][nonce];
if (reservedHash != 0 && reservedHash != hash) revert NonceReserved(reservedHash);   // :1081-1082
```

Three details in that placement carry the finding, and each was a choice:

The comparison is against the hash rather than a flag, so the ordinary path — approve a request, then
spend that same request — passes through untouched. A reservation only ever refuses a *different*
request on a *held* nonce.

The read sits **outside** the co-sign branch, because the branch is exactly the case that does not
need it. A spend that is itself over the threshold already has to produce a matching approval; the
spend that had to be stopped is the small one that skips the branch entirely.

The release at `:1095` is unconditional once the spend commits: the nonce is spent either way, so the
reservation has done its work and the gas refund is worth more than the record. `withdrawCosign`
releases it too, at `:1587`, but only when the stored hash matches the one being withdrawn — a
mismatched nonce leaves the reservation alone rather than freeing one that belongs to a different
live approval, which is why that function gained a `nonce` parameter in v2 and why the change is
listed in `CHANGELIST.md` beside `spendHash`'s.

Two approvals on one nonce for different requests are refused at `:1545-1546` for the same reason
F17 refuses a dead approval: the first could never be consumed, so writing the second would mint an
unconsumable authority. Re-approving the *same* request is allowed, which is how a co-signer extends
a deadline.

**What proves it.** Six Solidity tests, all named for the finding —
`test_f30_aTinySpendCannotBurnTheNonceUnderALiveApproval` is the attack in its original form, and the
other five cover the pass-through, an unreserved nonce, the withdrawal release, two approvals on one
nonce, and re-approval of the same request. The model gained seven `F30` tests and a
`withdrawCosign` function that exists solely because the reservation needs a release
(`reference/policy.js:1256`).

---

### F31 — A guard against arithmetic underflow was also handing out attestations that never went stale

**Severity: medium — `maxStaleness` bound every attestation except the one class that cannot be honest about its own age, so a single future-dated stamp bought a credential good for the life of the mandate. Reachable by accident as well as on purpose · Status: FIXED in `af9df40` · Confidence: certain; both branches executed, and the underflow argument re-checked against the new condition.**

The freshness rule compares an attestation's `lastUpdate` against the chain clock. `lastUpdate` is a
`uint40` and the subtraction is unsigned, so the old condition led with a guard:

```solidity
if (c.maxStaleness != 0 && nowTs > lastUpdate && nowTs - lastUpdate > c.maxStaleness)
```

That guard did its job — the subtraction could not underflow — and it did a second thing no one
chose. When `lastUpdate` was ahead of `nowTs`, the middle conjunct was false, the whole condition was
false, and the attestation passed as fresh. Not fresh once, but fresh on every spend, for as long as
the stamp stayed ahead of the clock. `maxStaleness` therefore applied to every attestation except
the ones dated in the future, which is the class most in need of scrutiny.

This does not need a malicious validator. A registry whose clock runs fast produces the same stamp by
accident, and the payer who set `maxStaleness` to an hour has no way to tell that their rule stopped
applying.

The new condition refuses instead:

```solidity
if (c.maxStaleness != 0 && (lastUpdate > nowTs || nowTs - lastUpdate > c.maxStaleness)) {
    revert CredentialStale();                                                            // :1293-1295
}
```

**The underflow is still impossible, and the reason is worth stating rather than trusting.** `||`
short-circuits: the first leg is true for every case where `lastUpdate > nowTs`, so the subtraction in
the second leg runs only when `nowTs >= lastUpdate`. That is exactly the guarantee the old conjunct
provided, obtained without also creating an exemption.

Refusing is the fail-closed reading. An attestation dated in the future has an age no one can
compute, and a freshness rule that cannot measure age should not return a pass.

**The model had this bug first**, and says so at `reference/policy.js:773`. Both were corrected in the
same pass, and `maxStaleness == 0` still means "no freshness requirement" on both sides — the F28
class of zero-as-unset error was not introduced while fixing this one. Three Solidity tests
(`test_f31_aFutureDatedAttestationIsRefusedRatherThanFreshForever`, one that re-executes the
subtraction at the boundary, and one that asserts an attestation stamped in the current block is
fresh) plus a `credential gate (F31)` test in the model.

---

### F32 — A payer could fill in a registry struct and forget its flag, and the contract would drop the data without a word

**Severity: medium — the mandate is created with a protection the payer believes is in place and the contract never applies, and the receipt they get back cannot show the difference · Status: FIXED in `af9df40` · Confidence: certain; the drop was a plain consequence of the storage writes being inside `if (flags & …)` blocks.**

`createMandate` takes a `Params` struct carrying both `flags` and the two ERC-8004 structs.
`flags` is `p.flags` verbatim, so nothing forced the bits and the fields to agree. That data is
only written to storage inside its own flag branch — `_identity[mandateId] = p.identity` at `:893`,
`_credential[mandateId] = p.credential` at `:912` — so a payer who filled in `identity` and left
`F_IDENTITY` clear got a mandate with no identity check at all.

The absence of any signal is the finding. There is no revert, no event field, and no view that
reports the difference: `MandateCreated` at `:915-917` logs `flags` and the window count, not the
two structs, so the payer's own receipt is consistent with both readings. Every later spend then
clears a check the payer believes is closed, and the audit trail records those spends as fully
authorised, because by the contract's lights they were.

There is no reading of such a grant that both sides would agree to, so it is refused rather than
resolved. The payer either meant the flag or meant an empty struct, and either is one edit away:

```solidity
if (flags & F_IDENTITY == 0 && (p.identity.agentId != 0 || p.identity.expectedOwner != address(0))) {
    revert BadConfig();                                                                  // :862-864
}
```

with the credential twin at `:865-874` covering all five of its fields, so no partial fill slips
through. Both refusals sit after the allowlist loop and ahead of the two flag branches, which is where
the data would otherwise be dropped.

**This one cannot arise in the model, by construction rather than by care.** `reference/policy.js` has
no `flags` at all — `grep -c flags` returns zero — because a mandate spec there uses nullable options
(`identity = null`, `credential = null`) instead of a bitfield beside a struct. Supplying the data *is*
enabling the check, so the two can never disagree. That is a genuine structural difference and not a
missing mirror, and it is the second time the model's shape has made a contract hazard unrepresentable
rather than merely untested.

**What proves it.** Two `test_createMandate_` tests, one per struct, plus a third asserting that a
mandate carrying neither the flags nor the data is still perfectly legal — the case that keeps these
guards from turning into a requirement to use the registry checks at all.

---

### F33 — Two identity settings produced a mandate that could never spend, and one of them was F27's open finding

**Severity: medium — the mandate is born dead: every spend for its whole life reverts, the payer's money is safe and their authority is worthless, and the revert reads at the call site like the identity check working correctly · Status: FIXED in `af9df40`, and this closes F27 · Confidence: certain; both settings traced through `_checkIdentity` to a specific revert.**

`_checkIdentity` calls `ownerOf(agentId)` on the ERC-8004 identity registry and refuses unless the
answer is the caller. Two grant-time values make that impossible to satisfy.

**Agent id zero.** Zero is not registrable under ERC-8004, so `ownerOf(0)` either reverts into the
`catch` arm or answers with the zero address, and both land on `IdentityNotHeld`. Not once — on every
spend, for the life of the mandate. This is the same class as the dead co-signature configuration
already refused a few lines above, and it is refused in the same place:

```solidity
if (p.identity.agentId == 0) revert BadConfig();                                          // :883
```

**A pin at anyone but the spender.** `_checkIdentity` has already required
`ownerOf(agentId) == msg.sender`, and `msg.sender` on the spend path is the spender, so a
non-zero `expectedOwner` either names the spender and repeats a test that just passed, or names a
third party and reverts `IdentityTransferred` on every spend. That is F27's finding stated as two
outcomes, and this is F27's fix:

```solidity
if (p.identity.expectedOwner != address(0) && p.identity.expectedOwner != p.spender) {
    revert BadConfig();                                                                  // :890-892
}
```

Pinning it to the spender rather than banning the field keeps it usable as a written record of intent
and removes the setting that bricks the grant. F27 asked for one guard in `createMandate` plus tests,
sequenced behind #23; what shipped is that guard, in the same commit as this finding's other half,
which is why F27 now reads as fixed above and this entry carries the code.

**A consequence for the suite, and it is not a small one.** With a pin at anyone but the spender
refused at grant time, `IdentityTransferred` became unreachable through the ordinary path. The test
that used to produce it (`test_identityGate_expectedOwnerMismatch_reportsIdentityTransferred`) was
deleted and replaced by `test_f33_forcingTheUnreachablePin_stillRefusesTheSpend`, which writes the
forbidden state directly into storage with `vm.store` and then asserts the spend still refuses. That
follows the rule this repository already uses for unreachable-by-construction cases: force the state
into existence rather than delete the check, so the guard stays proven and a real regression stays
visible. The mutation gate had been clean at 17/17 over the spend path before F33, and it is now
clean at 2/2 over `_checkIdentity`, with that test killing one of the two mutants on its own.

The model carries both refusals at `reference/policy.js:394-411`, asserted inside its grant-time
construction test — agent zero, an absent `agentId`, a pin at a third party, and the two accepted
shapes — plus the named `identity gate (F27)` test at `policy.test.js:2171`. On the Solidity side four
tests cover the same ground: `test_identityGate_zeroAgentId_isRefusedAtGrantTime`,
`_expectedOwnerNotTheSpender_isRefusedAtGrantTime`, `_expectedOwnerIsTheSpender_isAccepted`, and
`_unpinnedExpectedOwner_onlyRequiresTheCallerToHoldIt` — the last two being the pair that proves this
refuses a brick rather than a use.

---

### F34 — Two credential settings did the same thing, and the fix for one of them leaves a decision open

**Severity: medium for the defects, and the open decision below is the reason this entry matters after the fix. Both settings produce a mandate whose every spend reverts, and the revert reads like strictness working · Status: FIXED in `af9df40`, with one bound deliberately left loose and named here · Confidence: certain for both defects; the open question turns on ERC-8004's scoring semantics rather than on this contract.**

`Params.credential.minResponse` is a `uint8`, documented at `:337` as `ERC-8004: 100 == passed`. Two
values could not be met.

**A threshold above 100.** ERC-8004 carries the outcome in a `uint8` where 100 means passed, so
`minResponse = 101` refuses every attestation the standard can produce. The mandate is born dead and,
at the call site, indistinguishable from a payer asking for something stricter than usual.

**A zero request hash.** `requestHash` is the whole registry lookup key. `getValidationStatus(0)` names
no request, so it answers with an empty record, the zero-validator check refuses it, and
`CredentialMissing` is the only outcome that mandate can reach. This is the credential twin of F33's
zero agent id.

```solidity
if (p.credential.minResponse > 100) revert BadConfig();   // :906
if (p.credential.requestHash == 0) revert BadConfig();    // :911
```

The lower bound was already there: `:896` refuses `minResponse == 0`, because zero would accept a
failed attestation, so the accepted range is now 1 to 100.

**The open decision, which the contract's own comment at `:902-905` promises this document will carry.**
The bound is `> 100` rather than a pin at `!= 100`, so that a validator scoring on a finer scale stays
expressible. The cost of that choice follows from the same sentence the lower bound rests on.
If 100 is the only value ERC-8004 uses to mean *passed*, then a `minResponse` of 60 accepts a failed
attestation just as surely as a `minResponse` of 0 would, and the refusal at `:896` is drawing a line
at an arbitrary point on a scale where only one value carries meaning. Read that way, the honest guard
is `minResponse != 100`, and the range 1 to 99 is 99 ways to write a mandate that trusts a failure.

Read the other way, a registry is free to populate `response` with a real score, a payer may legitimately
want to accept 80, and pinning at 100 removes a policy the standard permits.

This only loosens in one direction, which sets the deadline: **the bound can be tightened before
deployment and never after.** It is a decision for the payer-facing product, not a code question, and it
belongs beside F20 as an open item rather than inside a bucket that implies work has been sized.

The model mirrors both refusals, at `reference/policy.js:366` and `:372`, including the same `> 100`
bound. **The cost of tightening is now measurable rather than a guess.** Every credential mandate in
the Solidity suite uses `minResponse: 100`, set once in `Base.t.sol`'s `withCredential` helper, and
the only three tests that name another value assert the refusals at 0 and 101 and the acceptance at
100 — so a pin at `!= 100` breaks no Solidity test at all. It breaks exactly one assertion anywhere:
`policy.test.js:490`, which constructs `minResponse: 60n` and checks it survives, under a comment
that calls it one of the permissive values, so the change is one line in the contract, one in the
model, and one test assertion.

That has a second reading, and it is the more uncomfortable one. **No test on either side exercises a
`minResponse` between 1 and 99 through an actual spend** — the range the loose bound exists to permit
is the range nothing executes. §5 carries that as a coverage gap.

Two `test_createMandate_` tests cover the threshold above and at the pass score, and a third covers the
zero hash.

---

### F35 — `isCosignApproved` answered a question about a mapping while the co-signer was asking about a payment

**Severity: medium — a co-signer reviewing their outstanding approvals was told a dead mandate's approvals were still honourable, and the delegate can produce that state on demand. No funds move on a wrong answer here; the damage is to the one participant whose whole job is to decide · Status: FIXED in `af9df40`, after one wrong first attempt described below · Confidence: certain; both the defect and the over-correction were executed.**

The approval mapping knows nothing about the mandate it belongs to. `_cosignApproved[mandateId][hash]`
stores a deadline, and the original view reported `validUntil != 0 && block.timestamp < validUntil` —
true for a stored, unexpired approval against a mandate that had been revoked or had expired weeks
earlier.

The delegate can produce the revoked case alone, because `revoke` accepts the spender as well as the
payer, so the co-signer's tool for reviewing what they still owe could be made to show honourable
approvals on a mandate the delegate had already killed. It reads as the same class as F15 and F19: a
participant is shown a claim about storage and hears a claim about a payment.

```solidity
return validUntil != 0 && block.timestamp < validUntil && !_isPermanentlyDead(_mandates[mandateId]); // :1715
```

**The first version of this fix was wrong, and the correction is the more useful half of the finding.**
It called `isLive`, which also refuses a mandate whose `notBefore` has not arrived. That made the view
answer `false` for an approval that is stored, unexpired and destined to work — the scheduled payment
F17 deliberately allows a co-signer to approve early, which two tests caught. The distinction that
survives runs through F16 and F17 both: revoked and expired are permanent, so an approval against
either is worthless, while not-yet-started is a wait. A view that says "no" to both has merged "is this
dead" with "is this ready", and the co-signer who asked cannot tell which answer they received.

`_isPermanentlyDead` was therefore factored out at `:1776-1781` — nonexistent, revoked, or past its
own expiry, three conditions no later block can undo. It is factored rather than copied, because the
expiry rule is now read from two places and two copies of a rule drift apart.

**What this still does not cover, stated rather than implied:** a lifetime cap with no headroom left, and
a nonce already burned. Both need the amount or the nonce, and this signature carries neither;
`spendable` answers the first.

**The reason this one survived every gate that existed.** `reference/mutation-gate-sol.py` rewrites
`revert …;` statements, so it structurally cannot reach a view whose logic is a returned boolean. F35
lived in exactly that blind spot for as long as the gate has existed, and no amount of re-running the
gate would have found it. That generalises past this finding: **the mutation gate proves the refusals are
asserted and says nothing whatever about the views**, which is now the largest known hole in this
project's verification and is listed in §5 as such. F35 and F36 were both found by reading the views
against `spend`, which is the only method that currently works on them.

Two `test_f35_` tests, one per half — the revoked mandate and the future start.

---

### F36 — `isAllowedRecipient` returned `true` for recipients `spend` refuses, and for every address on a mandate that does not exist

**Severity: medium — a pre-flight check that green-lights a payment the contract then refuses, which is the display-versus-enforcement gap this whole document is mostly about · Status: FIXED in `af9df40` · Confidence: certain; the omitted rules were readable side by side with `spend`.**

The view answered the allowlist question and only that: `F_ALLOWLIST` clear meant `true` for anything,
`F_ALLOWLIST` set meant a lookup. Meanwhile `spend` refuses the zero address, the payer, and — after F29
— this contract and the token. Its docstring listed the rules it left out, which was accurate and still
wrong for the job. Callers use this as a pre-flight check, and a `true` that `spend` then reverts is
exactly the disagreement between what a participant is shown and what is enforced that F15, F19 and F25
each closed in their own way. F29 was about to add a fourth omitted rule whose failure mode is
unrecoverable loss rather than a wasted revert, which is what turned a documented omission into a
finding.

An unknown mandate was the second half. With no payer, `m.payer == address(0)`, the allowlist flag is
clear, and the old view therefore returned `true` for every non-zero address on a mandate that has never
existed and against which no spend can ever succeed.

```solidity
Mandate storage m = _mandates[mandateId];
if (m.payer == address(0)) return false;
if (recipient == address(0) || recipient == m.payer) return false;
if (recipient == address(this) || recipient == address(usdc)) return false;
if (m.flags & F_ALLOWLIST == 0) return true;
return _allowlist[mandateId][recipient];                                        // :1753-1760
```

The rules are now in `spend`'s order, and the scope is stated in the docstring rather than left to a
reader: this is a recipient answer only. The caps, the nonce, the co-signature requirement and the two
ERC-8004 checks all remain outside it, so a `true` means "this payee is permitted", not "this spend will
succeed". `spendable` answers how much can move.

`test_isAllowedRecipient_appliesEveryRecipientRuleSpendApplies` (`test/Views.t.sol:439-465`) is the proof
for this finding and for F29's spend leg together: it asserts `false` for all four addresses and then
`payReverts` each of them, so the two claims are checked against each other rather than separately. A
second test covers the unknown mandate. The model has no equivalent view — `evaluate` answers the whole
question at once — so like F32 this is contract-only because of a shape difference, not an untested
mirror.

---

### F37 — The model would mint a mandate with a zero payer or a zero spender, and the chain refuses both

**Severity: informational for the chain, medium for anyone trusting the model — the model was minting a mandate the chain would reject, and minting one that reads as ordinary · Status: FIXED in `af9df40`, in `reference/policy.js` · Confidence: certain; found by a tool, then executed both ways.**

`createMandate` in the model opened with three truthiness tests — `id`, `payer`, `spender` — and the zero
address as a JavaScript string is truthy. This is the same trap as F28, in a different field, and it is
the third instance of it in this file.

**The route to this finding ran through a tool reporting nothing wrong.** The JS mutation gate was
extended to cover `createMandate`, and neutering the `spender required` throw changed no test result.
The obvious reading of a survivor is a missing test; probing it turned up a divergence instead.
The gate did not find the divergence — it found the *silence*, and the divergence was underneath.

The two halves fail for different reasons, which is why both throws are written out rather than folded
into one:

`spender` is refused by the contract outright, at `createMandate:689`, with `BadConfig`, so the model was
describing a mandate the chain will not create. On-chain that mandate would also have been permanently
unusable rather than dangerous, because every later check compares the spender against `msg.sender` and
the zero address never matches — but "unusable" is precisely what the payer needed to be told at grant
time, which is the same argument F33 and F34 make.

`payer` is not refused anywhere in the contract, and cannot be: the payer is `msg.sender`, so a zero payer
cannot arise. A model that accepts one describes a mandate with no counterpart, where every allowance and
`transferFrom` is against an account that has no holder. This half is therefore model-only in both
directions — the divergence exists because the model has a parameter the contract does not.

Both now throw with a message naming the on-chain reason (`reference/policy.js:271-282`), and the
grant-time construction test at `policy.test.js:288` asserts that the zero address is not one of the
three required values. No contract change, and none available: the spender case was already correct
on-chain before this finding existed.

**One bookkeeping note, because the commit is the record and it does not name this.** `af9df40`'s
message lists ten findings, F27 through F36. The fix for F37 is in that commit's `reference/policy.js`
blob all the same — it was written while clearing the `createMandate` survivors the message reports as
20/20 clean, and it was folded into the gate work rather than described separately. This entry is where
it gets named.

---

### F38 — Both ERC-8004 registries were legal recipients, and paying one destroys the money exactly the way F29 described

**Severity: high · Status: FIXED in the working tree, 2026-08-30, uncommitted and not yet compiled · Confidence: certain; the addresses are constructor arguments and the interfaces are in this repository.**

F29 refused two recipients that can accept USDC and never send it on: this contract, which holds no
balance by design and has no sweep, and the token itself, which has no recovery path for a balance
credited to its own address. The finding's argument was that such a spend stays inside every cap the
payer granted and destroys the money anyway, so `Spend`, the nonce and the counters all report a
successful payment that is really a burn.

**The constructor takes four addresses, and F29 reasoned about two of them.** `identityRegistry` and
`validationRegistry` are `immutable`, so they are as fixed as `address(this)`, and Remit only ever
reads them — `ownerOf` and `getValidationStatus`, both `view`. The ERC-8004 interfaces in this
repository carry no transfer, no approve and no withdraw of any kind, so a USDC balance credited to
either registry has no path out that Remit or the payer could take. Every argument F29 made applies
to them unchanged.

They were legal recipients on all three sites that ask the question — `spend`, `approveCosignFor`'s
F17 mirror, and `isAllowedRecipient` — so a delegate could name one and the payment would settle,
the caps would be consumed, and the event would read like any other spend to a third party.

**The reason all three sites were wrong together is the reason the fix is a helper.** F29 wrote
`recipient == address(this) || recipient == address(usdc)` out by hand three times. Three copies of
one rule is three places to remember, and the registries went missing from all three, which is what
a copied mirror does eventually rather than what it does by accident. The list now lives in
`_isUndebitable`, read from all three call sites, so **the rule and its mirrors are one line of code
that cannot fall out of step.** `reference/policy.js` took the same shape, in `undebitableAddrs`.

**Neither mutation gate can reach this, and the reason generalises.** Removal mutation rewrites
`revert` statements, and `_isUndebitable` has none — it returns a `bool`. The three refusals that
consult it are already mutated and already killed, and they stay killed if a term is dropped from
inside the helper, because the guard still exists and still fires for the two original addresses. So
the evidence has to be a test that names each address on its own:
`test_isAllowedRecipient_appliesEveryRecipientRuleSpendApplies` asserts all six recipient rules
individually, on the view and on the spend, and
`test_f38_approvingEitherRegistryAsRecipient_isRefused` does the same on the approval path. **A list
that loses an entry has to fail by name**, or the neighbouring assertion covers for it.

**What this does not claim.** A registry that is itself a contract with a token-recovery function
would not be undebitable in fact, and Remit cannot know that. The refusal is on the address rather
than on the address's capabilities, for the same reason F24 records: reading code at grant time
proves less than it appears to, and the failure this prevents is unrecoverable while the cost of the
refusal is that a registry cannot be paid, which no legitimate payment needs.

---

### F39 — A nonce reservation outlived the approval that created it, giving a co-signer a permanent veto over one nonce

**Severity: high · Status: FIXED in the working tree, 2026-08-30, uncommitted and not yet compiled · Confidence: certain; both routes into the state are executed by the new tests.**

F30 added `_cosignReservedNonce[mandateId][nonce]` so a delegate could not burn the nonce out from
under a live approval with a one-unit sub-threshold spend. The reservation is deliberately read
*outside* the co-sign branch, so it refuses every spend on that nonce, whatever the amount.

**The approval carries a deadline and the reservation did not.** F16 gave `_cosignApproved` a
`uint40 validUntil`; the reservation is a bare hash. So once the approval lapsed, the reservation
stayed and kept refusing, and the two routes out of it both closed:

- A spend naming a *different* hash reverted `NonceReserved` at the reservation check, which sits
  above the release at the foot of `spend`.
- A spend naming the *reserved* hash reached the co-sign branch and reverted `CosignExpired`.

So the nonce could not be spent, and the release that would have cleared the reservation is at the
end of a function neither route could reach. `revoke` does not touch the mapping. `createMandate`
refuses a second grant on the same salt, so the mandate cannot be re-minted around it. The mapping
is `private` and appears in no event, so the payer and the delegate cannot even learn which nonce is
affected.

**One party could clear it, which narrows the finding without closing it.** `withdrawCosign` takes
the nonce precisely so it can release the reservation, and its own doc says the call may be repeated
with the right value. So the co-signer always had a remedy. **The payer and the delegate had none**,
and the co-signer is exactly the party a payer adds because they are willing to distrust the
delegate — not a party the payer can compel. A co-signer who is hostile, or merely gone, left that
nonce dead, and the cost of buying that was one legal approval with a deadline one second out.

**The refusal also landed on spends the lapsed signature had no authority over.** The reservation
check sits above the branch that reads `cosignThreshold`, which is what F30 wanted, so a dead
reservation refused sub-threshold payments too — payments the co-signer was never asked about.

**The fix, and the second site the sweep that found this did not name.** A dead reservation is now
swept in `spend` and the payment continues; the live case is untouched, so F30 holds exactly as
written. Then `approveCosignFor` turned out to carry the identical unconditional refusal, and
fixing only `spend` would have left the co-signer told `NonceReserved` about their own expired
approval when trying to approve a replacement on that nonce. **The finding named one site and the
fix needed two**, which is the pattern §4's #24 paragraph had written down as a search strategy one
batch earlier. `_cosignIsLive` answers the deadline question for both, so neither can disagree with
the enforcer three lines below the first of them.

**It also closes a rough edge the suite had already accepted in writing.** `withdrawCosign` with a
nonce that does not match the stored reservation deletes the approval and deliberately leaves the
reservation — freeing a nonce that belongs to some *other* live approval would be worse. F30's own
test recorded the resulting stranded nonce as a known cost. Under F39 that reservation refuses
nothing, so the cost is gone without the rule that produced it changing.

**One mutant here is provably unkillable, recorded so no reader looks for a test.** `_cosignIsLive`
reads `return validUntil != 0 && nowTs < validUntil`. `validUntil` is unsigned, so `nowTs < 0` is
false for every `nowTs` and the first conjunct changes no answer at either call site — a mutation
dropping it is EQUIVALENT. Dropping `nowTs < validUntil`, or flipping `<` to `<=`, is killable, and
`test_f39_aLapsedReservationNoLongerBlocksTheSpend` asserts both boundaries: refused at
`validUntil - 1`, allowed at `validUntil`.

---

### F40 — Half of the rolling window cap is permanent, and the approval path left out both halves on the strength of one sentence about the other

**Severity: medium · Status: FIXED in the working tree, 2026-08-30, uncommitted and not yet compiled · Confidence: certain; `w.cap` has no mutator and `used` is unsigned.**

F17's rule is that `approveCosignFor` mirrors every *permanent* refusal `spend` makes, and mirrors
no recoverable one, because refusing an approval a later `spend` could have consumed turns our
caution into someone's unapprovable payment. The note at the head of that function listed three
conditions as recoverable and therefore excluded. The rolling window caps were the third, and the
reason given was: *a window's used total falls as buckets age out, so an amount refused now can fit
later.*

**That sentence is true of the sum and false of one of its terms.** `spend` refuses when
`used + amount > w.cap`. `used` is unsigned and only ever falls back toward zero, and `w.cap` is
written once in `createMandate` and has no mutator anywhere in this contract. So `amount > w.cap`
alone can never stop holding: no passage of time, and no amount of ageing out, makes an amount above
a window's cap fit inside it. That is permanent in exactly the sense every other condition in F17's
block is permanent, and it was excluded because it shares a revert with a recoverable neighbour.

The consequence is F17's own failure mode, in the one place F17's note said to look away from: a
co-signer could pay gas to authorise a payment, `CosignApproved` would fire, `isCosignApproved`
would report it live, and every spend consuming it would revert `OverWindowCap` for the life of the
mandate.

**The repository held both halves already, in two tests that never met.**
`test_cosign_isCheckedAfterEveryCap` refuses 90 against a cap of 50 on the spend path and writes the
reported `used` as a literal zero — the permanent half, stated as a constant.
`test_f17_approvingWhileAWindowIsFull_isAllowed`, 545 lines below it at `efe43a7`, approves 50
against the same cap of 50 and reasons in its docstring that the window caps are recoverable. Both
tests are correct. The docstring on the second was the defect, and it has been rewritten to name the
split and point at F40 directly below it, so the two are read as the two halves of one predicate.

**`reference/policy.js` carried the identical gap**, so the differential suite could not have caught
this: both sides agreed, and they agreed on the wrong thing. **A model finds divergence, not
error**, which is worth stating beside the 99 green model tests.

**Cost, and why the loop is cheap enough to be uncontroversial.** At most `MAX_WINDOWS` cold reads,
only for a mandate that configured windows, on a call a human sends by hand to authorise the largest
payments a mandate allows. The refusal reports `used = 0` rather than a measured figure, because the
answer does not depend on consumption — which is also what makes it safe to raise from a function
that commits nothing to the ring.

**Two tests, and each kills a mutation the gate cannot build.**
`test_f40_approvingAboveAWindowCap_isRefused` approves exactly the cap and then spends it, which
kills `>` flipped to `>=` — a flip that would otherwise refuse the largest payment the mandate was
configured to allow while satisfying every other assertion. It also re-runs the refusal a week
later with every bucket aged out, which is the assertion that separates F40's claim from the test
above it. `test_f40_theBindingWindowIsFoundWhereverItSits` puts the tighter cap second, so a loop
truncated to `windows[0]` fails, and asserts that both paths name the window that actually refused
rather than the first one they read.

## 5. Coverage gaps — what this pass could not reach, and what no test executes

Two kinds of gap are listed together because a reader deciding how much weight to put on
this document needs both: things a source review cannot settle in principle, and things the
test suite never runs. Neither kind is a finding in itself; each is a reason a finding could
still be hiding there.

- **Whether a precompile-backed ERC-20 `transferFrom` on Arc executes recipient code.**
  Bears on F7. Settleable with one testnet transaction to a contract recipient that logs
  on receipt.
- **Economic and game-theoretic attacks on the whole arrangement**, as opposed to the
  contract in isolation, which a source review cannot reach.
- **The real Circle USDC contract.** Every test runs against `MockUSDC`. Arc's own
  porting guide is explicit that a local EVM "cannot reproduce Arc's precompiles,
  EIP-7708 `Transfer` events, or USDC blocklist enforcement."
- **The identity gate's and credential gate's positive paths.** Never executed against a
  real registry: no identity NFT has been minted to Remit's agent, and the only real
  attestation on Arc Testnet carries a failing response of 1.
- **Griefing economics of a sponsored-submission path.** Arc documents that a blocklist
  revert consumes the submitter's gas with no transfer, which is a direct cost model for
  any relayer or paymaster Remit adds.
- **The maximum-cost spend.** `MAX_WINDOWS × (MAX_BUCKETS + 1) = 132` cold ring reads in
  one `spend` is what those two constants exist to bound, and **no test spends against a
  four-window mandate at all** — `Creation.t.sol`'s
  `test_createMandate_fourWindows_isAccepted` builds one, asserts `windowCount == 4`, and
  stops, so the worst case those two caps exist to make survivable has never been
  executed, let alone measured. Closing this costs less than any other gap on this list, and
  it belongs in #14, since it needs a gas number anyway.

  **CLOSED 2026-08-30.** `test_fourWindowsAtMaxBuckets_theMaximumCostSpend_succeeds` in
  `test/Windows.t.sol` executes it. The four windows are **identical**, at `(DAY, 3300, 32)` each,
  which is deliberate: a slot stays live for `K + 1` sub-periods, so windows of differing
  sub-lengths fill and empty on different schedules, and no instant exists at which all 132 slots
  hold an amount. Thirty-three spends of 100 at thirty-three consecutive sub-periods fill every
  slot in all four rings, `windowRemaining` reads 0 on each of the four, and the spend after them
  reads all 132 slots, counts 128 and recycles 4. The refusal that closes the test names the first
  window, since identical windows bind together and `spend` reports the first one to bind.

  **The measurement is still owed and still belongs to #14.** The test asserts no gas number, for
  two reasons that come from the harness rather than from the contract: `--gas-report` perturbs
  `gasleft()` in this suite, and every call inside one Foundry test function shares a transaction,
  leaving the ring warm from the second spend onward. The cold figure needs
  `forge test --isolate --gas-report` against this one test, and that figure is the one this
  bullet asked for rather than the 7,423,098 an ordinary run reports.
- **Three accepted window geometries are never spent through**, confirmed by enumerating
  every window constructed in `test/`: `buckets == 1`, `buckets == 32` exactly, and
  `subLength == 1`. The first is a ring of two, which charges up to twice the nominal window —
  correct, and startling enough to deserve a test that says so. `WindowFuzz.bucketsFor`
  returns `{2, 3, 4, 6, 12, 24}`; its own comment says it covers "K from tiny to 24 (the
  precise end of the practical range)", which is an accurate description of the *practical*
  range and not of the *accepted* one. `createMandate` accepts K up to 32 and
  `lengthSeconds = 1, buckets = 1`.

  **CLOSED 2026-08-30.** Four tests in `test/Windows.t.sol` cover all three geometries, and a
  fifth landed with them.
  `test_bucketsOfOne_chargesTwoWindowsBeforeReleasing` spends the cap, holds the mandate out to
  `2L` to watch the whole cap return at once, then spends onto the ring slot that bucket `b + 2`
  shares with bucket `b`. The refusal after that spend reports `used` as one cap rather than two,
  which is the only way to separate the recycle branch from the accumulate branch: neither branch
  contains a `revert`, so no removal mutant can reach either of them, and the test is the whole of
  the evidence there.
  `test_bucketsAtTheMaximum_keepsThirtyThreeBucketsLiveAtOnce` fills a 33-unit cap with 33 spends
  at 33 consecutive sub-periods, which a 32-slot ring would have admitted with a bucket to spare;
  the assertion therefore separates the two ring widths instead of restating the arithmetic, and a
  second assertion one sub-period later pins the finest release the contract can be configured to
  give. The one-second sub-period is taken twice:
  `test_subLengthOfOneSecond_releasesAfterTwoSeconds` covers the ordinary release, and
  `test_subLengthOfOneSecond_atTheLastSpendableSecond_stillBuckets` runs it at `FAR - 3`, where the
  bucket index reaches `2^40 - 4` — the largest value any mandate this suite can build hands to
  the `uint64` cast, and 40 of that field's 64 bits. The fifth test,
  `test_fourWindows_refusalByTheLast_unwindsTheFirstThree`, sits outside the accepted extremes and
  is instead the shape a payer would grant: four differing lengths with the tightest last, so a
  refusal raised by the fourth window arrives with three windows already written, and each of the
  three is asserted back at its full cap.
- **`forge lint` on the v2 tree.** `windowRemaining`'s `uint64` cast carries no
  suppression comment where its twin in `_checkAndCommitWindows` does; whether that is a
  new warning is #14's to find out.

  **CLOSED 2026-08-30.** It is not a new warning. `forge lint` on the v2 tree is clean at
  default severity, and the run was proved to have read the source rather than skipped it:
  a throwaway `contracts/LintProbe.sol` carrying four deliberate violations made the same
  bare invocation report two warnings, and a second run against a warm cache printed
  `No files changed, compilation skipped` *together with* both warnings, so linting does not
  depend on compiling. `FORGE.md:498-542` carries the method and the numbers.

  The commenting asymmetry is real and the reason for it is not established. Both casts have
  the same shape — `uint64` of a `uint256` divided by a `uint32` `subLength` — and only the
  one in `_checkAndCommitWindows` is annotated, yet the unannotated one in `windowRemaining`
  raises nothing. The visible difference is the numerator: the annotated cast takes the
  `nowTs` parameter, the unannotated one takes `block.timestamp` directly. Whether Foundry
  1.7.1's `unsafe-typecast` rule distinguishes those two is unverified here, so treat the
  silence as a measurement of this Foundry version and not as a property of the code. A
  version bump can make the unannotated line fire while the annotated one keeps its
  exemption, which is the wrong way round for whoever reads the warning first.
  `windowRemaining` is a `view` that grants nothing, so nothing turns on it today.

  The same run also established that a clean `forge lint` is a claim about **default**
  severity. `forge lint --severity info` returns 14 notes, 2 on the probe and 12 in repo
  code: four `multi-contract-file` in `MandateManager.sol`, one for each of the three
  interfaces and one for the contract; three `screaming-snake-case-immutable` there, on
  `usdc`, `identityRegistry` and `validationRegistry`; three `screaming-snake-case-const` in
  `MockUSDC.sol`, on `name`, `symbol` and `decimals`; and two `multi-contract-file` in
  `MockRegistries.sol`. Every one is a naming or file-layout convention rather than a defect,
  each judged in `FORGE.md`'s lint section.

  **The immutable rename was then measured, and it is declined.** Two costs expected of it
  turn out to be absent. No interface in the repo declares `usdc()`, `identityRegistry()` or
  `validationRegistry()`, and each getter has exactly one call site, all three in
  `script/Deploy.s.sol:148-150`. The rename is width-neutral too, since `USDC` matches `usdc`
  exactly and the two registry names grow one column each on two guard lines that sit well
  inside any formatter limit. Line citations are the one small cost that is real: three live
  pointers land on the immutable declarations, all three from `FORGE.md`'s own note table, and
  the rename rewrites the text they point at, so the table needs re-reading afterwards. The
  ABI reason this bullet carried until now does not survive measurement either, since v1 is
  testnet-only with no third-party integrator and carries no upgrade path, so a v2 deploy
  reaches a fresh address that a caller has to point at deliberately before reading its ABI.
  What decides the question is a token collision, in a repo whose
  verification is largely textual: the contract's own prose uses `USDC` for the asset 40
  times, `usdc` appears 12 times and always means the identifier, and `USDC` as a word
  appears 125 times across the seven published documents, so the rename would merge two
  referents into one token. The `immutable` keyword and the absence of any setter already
  carry what the capitals would add, and renaming two of the three is worse than either
  alternative, since one declaration block would then hold two naming schemes while the note
  still fired on `usdc`.

  Correcting the record on the way through: the contract carries **six** in-place
  suppressions, three `unsafe-typecast` and three `block-timestamp`, where both
  `foundry.toml` and `FORGE.md` had described v1's five. Fixed in `5653bcb`.
- **Three co-signature behaviours `test/Cosign.t.sol` never runs**, enumerated against the
  file rather than sampled, and all three are F17's: approving on a **revoked** mandate;
  approving on an **expired** one, or letting a live approval outlive the mandate's
  `expiresAt` before spending; and approving a hash whose amount is **at or below the
  threshold**, so the mapping is written and never consulted. All three are ordinary
  Foundry tests. Re-derived on 2026-08-27 rather than carried forward, and the re-derivation
  changed the bullet twice.

  **CLOSED 2026-08-28.** All three run now: `test_f17_approvingOnARevokedMandate_isRefused`,
  `test_f17_approvingOnAnExpiredMandate_isRefused` and
  `test_f17_approvingAtOrBelowTheThreshold_isRefused`. The second gap's other half — an in-date
  approval outliving the mandate — is closed by construction instead of by a test, because line
  1189 refuses `validUntil > m.expiresAt` and a mandate without `F_EXPIRY` has no expiry to
  outlive; `test_f17_theDeadlineMustOutliveNotBeforeAndDieByTheExpiry` pins both mandate-relative
  bounds. The file now declares **37** tests (`grep -c '^    function test'`, cross-checked
  against `Ran 37 tests for test/Cosign.t.sol` in the run log), of which **13** are `test_f17_*`.
  Read the following bullet before treating that as coverage: twelve of those thirteen were
  green while one of F17's seventeen guards was asserted by nothing at all. **38 and 18 as of
  2026-08-28**, cross-checked the same two ways (`Ran 38 tests for test/Cosign.t.sol`): F19 added
  `test_f19_approvingThePayerAsRecipient_isRefused` and the eighteenth guard it asserts. That test
  is the **sole** killer of its mutant, which is the same shape as the `TotalSpentCeiling` story
  below and the reason it is named here rather than left in a count.

  **This bullet said "four" and said "seventeen tests", and both were wrong** — and this
  paragraph is an *earlier* correction layer than the two above it, so **the 25 below is history,
  not the current figure**; the file is at 38. The layers are out of chronological order because
  each was appended where it was most readable rather than where it happened, which is worth
  knowing before quoting any number out of this bullet. The count was
  **25** — `grep -c '^    function test'` — of which eight are new in #28 and two are the
  old `approveCosign_*` pair renamed. The four gaps were attributed to "F16 and F17";
  F16 has since shipped, and its behaviour is now covered by `test_approval_expires`,
  `test_deadlineInThePast_isRefused`, `test_deadlineBeyondTheCap_isRefused`,
  `test_deadlineExactlyAtTheCap_isAccepted`, `test_expiredAndAbsent_areDifferentErrors` and
  `test_expiredApproval_lingersInStorageButIsInert`, so what remains is F17's alone. Note
  that the surviving second gap is **not** what F16 fixed: F16 bounds an approval's own
  life, and this gap is an in-date approval outliving the *mandate*, which nothing bounds.

  **The retired fourth gap was never a gap.** It read "`withdrawCosign` **front-running** a
  spend that would have used the approval", and conceded in the same breath that what a test
  can pin is the two-transaction sequence rather than the mempool race. That sequence was
  already pinned, in the same file, at the anchor commit: `test_withdrawCosign_revokesAnUnusedApproval`
  approves, withdraws, asserts `isCosignApproved` false, and then has the agent's `spend`
  refused with `CosignRequired` carrying the same hash. The bullet therefore named as untested the
  one part of the property a test can reach, next to the test that reaches it — a gap found by
  reading test bodies instead of test names, which is exactly the discipline §3's opening
  sentence claims for itself and this bullet had not applied. The mempool race itself remains
  unpinnable, which is F4's limit and is recorded there, not here.
- **`recipient == m.payer` — CLOSED 2026-08-28, and closed in the shape this bullet predicted.**
  When it was written, no test anywhere in the suite performed it, derived rather than recalled:
  every recipient argument reaching `spend` across all eleven test files and thirteen suite
  contracts was one of `vendor`, `other`, `boss`, `ARC_RECIPIENT`, the `0x…c0de` literal, or
  `address(0)` in the two tests that expect `ZeroRecipient`; `payer` was never among them, and
  `Base.t.sol`'s `setUp` makes all five accounts distinct `makeAddr`s, so no fuzz path could
  collide into it either — a claim that still holds, since no test function in `test/*.sol`
  takes an `address` parameter at all. This bullet then said the obvious test asserts the
  paradox directly (a self-spend succeeds, `totalSpent` and the window ring advance, the nonce
  burns, `Spend` fires, the balance does not move) and that it *"would have to be **deleted** if
  F19's fix lands, so writing it now is only worth it as the fix's negative case
  (`vm.expectRevert(SelfPayment.selector)`)"*. F19 landed, the paradox test was never written,
  and all four of its tests are that negative case. **Recorded rather than deleted, because the
  useful part was not the gap — it was declining to spend a test on a behaviour that was about
  to become unreachable.** The gap that remains here is not about the contract: it is the next
  bullet, and no test can close it.
- **Whether Arc's ERC-20 USDC at `0x3600…0000` emits its own 6-decimal `Transfer` on a
  self-transfer.** Arc's `usdc-system-events` page documents the rule only for the
  18-decimal system emitter at `0xffff…fffe`. `MockUSDC` cannot answer this — it is this
  repository's own code, and whatever it does is a description of the assumption, not of Arc. This
  is the one gap in this document that **no test can close**: it needs one transaction on Arc
  Testnet against the real token, `cast send` plus `cast receipt --json`, counting logs.
  F19 holds either way; only the size of the audit hole moves.
- **A future-dated `lastUpdate`, which no test stages** — so §2's sharpest statement about the
  validator boundary, that an attestation dated in the future skips the freshness check at
  `v2:880` and stays fresh forever, has no executing counterexample. Derived from all ten
  `setStatus` call sites; every one is present or past. One ordinary Foundry test closes it, and
  it should assert the surprising direction: warp *backwards* relative to the attestation and
  watch `maxStaleness` stop applying.

  **CLOSED 2026-08-29, and the behaviour it describes no longer exists.** Writing the test the
  bullet asked for is what produced **F31**: the exemption proved to be a defect rather than a
  quirk to be pinned, so the contract now refuses a future-dated attestation instead of treating
  it as fresh. Three Solidity tests now cover it —
  `test_f31_aFutureDatedAttestationIsRefusedRatherThanFreshForever`, one that re-executes the
  subtraction at the boundary to show the underflow is still impossible, and one that asserts an
  attestation stamped in the current block is fresh — plus `credential gate (F31)` in the model.
  **§2's statement about this boundary needs rereading against the fix**, since it describes the
  old condition and is now a history claim rather than a current one. The bullet is kept rather
  than deleted because it is the clearest case in this document of a coverage gap that was
  actually a finding: no reader reasoned their way to F31; the missing test did.
- **A `minResponse` between 1 and 99 is never spent through, on either side.** New on
  2026-08-29 and a consequence of F34's fix rather than of a gap in the old suite. Every
  credential mandate in the Solidity suite uses 100, set once in `Base.t.sol`'s `withCredential`
  helper, the three tests that name another value assert the refusals at 0 and 101 and the
  acceptance at 100, and the model asserts only that a `minResponse` of 60 *constructs*, so the
  range F34's bound exists to permit is the range nothing executes, which is also why tightening the
  bound to `!= 100` would break no Solidity test — see F34's open decision.
- **The `UnrecoverableRecipient` mirror in `approveCosignFor` was asserted by nothing. CLOSED
  2026-08-30.** New on 2026-08-29. All four occurrences of the error in `test/` were in
  `Views.t.sol`, on the spend path, and none of the 52 `approveCosignFor(` call sites in the suite
  named this contract or the token, while the model did cover its approval leg. The prediction
  recorded before the run said exactly that, and the run bore it out: the `approveCosignFor`
  mutation gate reported one survivor, at `contracts/MandateManager.sol:1479`.
  `test_f29_approvingTheContractOrTheTokenAsRecipient_isRefused` in `test/Cosign.t.sol` answers it, and
  `mutgate-only-approveCosignFor.log` shows the answer bites at baseline 209 green. **The full
  24-mutant sweep the same day reported 24/24 and shows none of this**, because the test was already
  in the tree when it ran. A survivor's repair is visible only in a run that predates the repair, or
  in the `--only` run written afterwards to recover the evidence.
- **The F32 credential guard at `createMandate:873` was shadowed rather than unasserted. CLOSED
  2026-08-30.** New on 2026-08-30. The guard refuses a credential field set without `F_CREDENTIAL`,
  and the test that appeared to cover it was refused one block earlier instead: the biconditional
  reads `(flags & F_CREDENTIAL != 0) != (p.credential.validator != address(0))`, `withCredential`
  always sets a validator, and both lines revert `BadConfig`, so the assertion held while F32 had
  nothing behind it. The gate deleted the guard and all 207 tests still passed.
  `test_createMandate_eachCredentialFieldWithoutTheFlag_isRefused` sets each of the four fields on
  its own with the validator left at zero, which leaves F32 the only line that can answer, and
  `test_createMandate_noGateDataAndNoGateFlags_isAccepted` is its control — without it the four
  refusals would also pass against a `createMandate` that refused every grant, and
  `mutgate-only-createMandate.log` shows the mutant caught.
  **Same mechanism as `BadConfig 486` on 2026-08-28 and the JS sibling's very first finding: two
  guards that refuse the same input under the same selector hide each other, and the shadowed one
  looks tested from every angle.**
- **The Solidity mutation gate reaches a view's refusals but not the value it returns, and both
  view findings came from reading.** New on 2026-08-29, and the largest known hole in this
  project's verification. `reference/mutation-gate-sol.py` rewrites `revert …;` statements one at a
  time, so logic that resolves to a returned value gives it nothing to mutate. F35 lived in that
  blind spot for as long as the gate has existed and no amount of re-running would have surfaced
  it; F36 the same. Every "the gate is clean" claim in this repository is therefore a claim about
  refusals only. Of the contract's 22 definitions, eleven carry no `revert` and sit wholly outside
  the gate: `getMandate`, `getWindow`, `isNonceUsed`, `isCosignApproved`, `cosignApprovalDeadline`,
  `isAllowedRecipient`, `_isPermanentlyDead`, `isLive`, `windowRemaining`, `policyHeadroom` and
  `spendable`. Two more are views reachable in their refusals alone, `spendHash` (1) and
  `spendableAcross` (5). Closing this needs a different operator — negate a returned boolean, or
  drop a conjunct — not another run.
  **The hole widened on 2026-08-30, and what it took in is unlike every earlier tenant.** F38's
  `_isUndebitable` and F39's `_cosignIsLive` both return `bool` and hold no `revert`, so the census
  is now 24 definitions with thirteen outside the gate. Every earlier member of that list is a
  reader that answers a caller and decides nothing, while these two are consulted at five sites
  between them — `_isUndebitable` by `spend`, `approveCosignFor` and `isAllowedRecipient`, and
  `_cosignIsLive` by `spend` and `approveCosignFor` — and four of those five are `revert` statements
  the gate does rewrite. That is the worst arrangement available: the gate deletes each consuming
  refusal, a test catches it, and the condition actually deciding the refusal is never touched. It
  is also self-defeating in the way factoring usually is not, since F38 and F39 were both fixed by
  moving a duplicated list or comparison into one place, and one place is the place the gate cannot
  see. Four hand mutations are owed against exactly this: drop either registry from
  `_isUndebitable`, drop `nowTs < validUntil` from `_cosignIsLive`, flip F40's `>` to `>=`, and
  truncate F40's window loop to `windows[0]`. Dropping `_cosignIsLive`'s `validUntil != 0` term
  instead is the one variant no test can kill, for the reason F39's entry sets out.
  **CLOSED 2026-08-30 — the operator exists, and the four owed mutations were six.**
  `reference/mutation-gate-sol.py` grew a third operator, `--hand`, beside REMOVAL and INJECTION. It
  keys a table by target, each case naming the exact consecutive source lines it replaces and the
  lines that replace them, so a rewrite of the guard breaks the case with an error rather than
  mutating nothing. Six cases are written over three targets: two dropping each registry from
  `_isUndebitable`, two on `_cosignIsLive`, and two on F40's window cap in `approveCosignFor`. Five
  of them expect to be caught, and the sixth — dropping `_cosignIsLive`'s `validUntil != 0` term —
  is recorded with the reason no test can kill it, so the gate reports it as `EQUIVALENT` rather
  than `SURVIVED`. If a test ever does kill that one, the run says the recorded reason has stopped
  being true and the case needs rewriting, which is the same two-way discipline `EQUIVALENT` already
  applies to removals. **The sentence above says four and its own list holds five**, and the
  unkillable variant named after it makes six, which is one more count written beside the list it
  counts. Re-derived today with the script's own `is_code` and `function_bounds`, the automatic
  census is 89 removals over 10 targets plus 6 injections, so the gate can build 101 mutants against
  this contract, and two of the three targets it reaches by hand hold no `revert` at all.
  **The first run of all six, the same evening: five caught, one `SURVIVED` where `EQUIVALENT` was
  promised, and the two `_cosignIsLive` cases had their labels crossed with their replacements.** The
  case labelled "the deadline stops being read" was built as `return nowTs < validUntil;`, which
  drops `validUntil != 0` and is the equivalent mutant. The case carrying the recorded reason was
  built as `return validUntil != 0;`, which drops the deadline, is killable, and was killed by the
  two F39 tests. The gate therefore reported the equivalent mutant as an unexplained survivor and
  printed the stale-reason `NOTE` against the one mutation of the two that a test should catch. A
  single swap of the two replacements fixes both halves, and it is in. An annotation saying a
  mutant will survive is a claim like any other: a pair whose labels do not match their
  replacements builds a table that reads complete while describing code it never compiled. The
  other four cases were clean against three baselines of 231 green apiece. `_isUndebitable`'s two
  registries die to `test_isAllowedRecipient_appliesEveryRecipientRuleSpendApplies` and
  `test_f38_approvingEitherRegistryAsRecipient_isRefused`; F40's `>=` swap dies to three tests; and
  F40's truncated loop dies to exactly one, `test_f40_theBindingWindowIsFoundWhereverItSits`, which
  is the only test in this repository standing behind the claim that every window is read.
  **Re-run of `_cosignIsLive --hand` alone after the swap, same day: `caught` then `EQUIVALENT`,
  baseline 231 green, and no `STALE`, `LAPSE`, `SURVIVED` or `INCONCLUSIVE` anywhere in the log.** The
  killable case died to exactly the two F39 tests, `test_f39_aLapsedReservationNoLongerBlocksTheSpend` and
  `test_f39_onceAnApprovalLapsesTheCosignerCanApproveAReplacement`; the equivalent one printed its
  widening reason in place of a verdict. The same run proves the hand cases still find the code they
  name: `_isUndebitable` grew by two lines this morning and pushed `_cosignIsLive`'s return from 1945
  to 1947, so a case keyed on a stale line number would have died rather than mutated. Its SCOPE line
  reads the way `_isUndebitable`'s does, hand cases only and they are everything the target offers,
  since the function holds no `revert` and has no injections.
- **Six mutation-gate targets are owed a run, and this bullet's own count was wrong. CLOSED
  2026-08-30 — all eleven targets have now run.** New on 2026-08-29, revised the same day, closed
  the next. A gate run is only as current as the function it targets, and `af9df40` grew three of
  them: `approveCosignFor` 22 mutants → 24, `spend` 17 → 19, `createMandate` 21 → 27, all counted
  from the file. The contract offers eleven reachable targets and 89 mutants, 85 removals plus four
  injections. At the time this bullet was written three had run clean (`_checkIdentity` 2, `revoke`
  2, `withdrawCosign` 1) and two ran with one survivor apiece (`approveCosignFor` 24,
  `createMandate` 27), leaving `spend` 19, `_checkCredential` 6, `spendableAcross` 5,
  `_checkAndCommitWindows` 1, `spendHash` 1 and `constructor` 1: 33 mutants, not the 73 across
  five targets this bullet first claimed. That figure counted two targets that had already run,
  and it folded two internal helpers into `spend`, which calls both and covers neither. A run
  names one function, so a refusal inside `_checkCredential` is `_checkCredential`'s to answer for.
  **The 84 outstanding mutants across eight targets all ran on 2026-08-30, every one at baseline
  209 passed, 0 failed.** Six came back fully clean — `approveCosignFor` 24/24, `createMandate`
  27/27, `spend` 19/19, `_checkAndCommitWindows` 1/1, `spendHash` 1/1, `constructor` 1/1 — and two
  returned one survivor each, both of them equivalent mutants no test can kill, covered in the next
  bullet. With `_checkIdentity`, `revoke` and `withdrawCosign` from 2026-08-29 that is 89 of 89
  mutants attempted and eleven of eleven targets run, so no clean claim in this document now rests
  on a function the gate has never addressed. The logs are `mutgate-sol-<target>.log`, plus
  `mutgate-only-approveCosignFor.log` and `mutgate-only-createMandate.log` for the two `--only`
  confirmations; they are on disk and they outrank this table.
  **The census moved 89 → 91 later the same day, with the contract byte-identical throughout.**
  F22's inversion was added to `INJECTIONS` for `spend`, which had none before, and as a fifth for
  `approveCosignFor`, so the totals are **91 mutants, 85 removals plus 6 injections** and the
  per-target figures become `approveCosignFor` 25 and `spend` 20. Nothing about the contract changed
  to produce that, which makes it the first census move in this project's history no `git diff` can
  explain: **a mutant count is a property of the pair (contract, operator set)**, so a mutation gate
  learning a new property raises it exactly the way a new guard does. Both confirmations ran under a
  new `--injections` flag at baseline **212 passed, 0 failed**, and each returned every queued mutant
  caught by a named test — 1 of 1 for `spend`, 5 of 5 for `approveCosignFor`. Each log closes with
  the gate's own `SCOPE: injections only` block naming the 19 and 20 removals the run declined to
  build, so neither is quotable as a census and the gate says so without being asked. What licenses
  skipping those removals is directional rather than convenient: adding a test can only enlarge the
  killer set, so the 84-mutant sweep recorded above cannot have regressed under three new tests. A
  bare run of either target is still the only thing that re-establishes a census, and #14 owns it.
  **A bare run happened on 2026-08-30, over four targets, and the census is 95.** #24 changed the
  bodies of `spend`, `approveCosignFor`, `withdrawCosign` and `revoke`, and those four were chosen by
  a code-only comparison of every target's body against `db1c08c` rather than by eye — which is what
  caught `revoke`, whose two refusals are untouched while its body is no longer the body the earlier
  run mutated. All four ran bare, so each re-establishes its own census: 21 for `spend`, 26 for
  `approveCosignFor`, 3 for `withdrawCosign` and 2 for `revoke`, 52 mutants in total, every one
  caught by a named test at a baseline of 219 green. The four new removal sites are the two
  `SpendCountCeiling` guards from F3 and `withdrawCosign`'s `UnknownMandate` and `BadConfig` from
  F11, which takes the whole-contract figure to **95 — 89 removals plus 6 injections** over eleven
  targets, against the 91 recorded earlier the same day. Both `EQUIVALENT` shadows were confirmed
  present exactly once inside their own target before the runs, so neither claim has lapsed.
- **Two mutants survive permanently, and they are a fourth class of survivor rather than two more
  coverage gaps.** New on 2026-08-30, from the sweep that closed the bullet above.
  `_checkCredential:1261` is the `catch` arm's
  `revert CredentialMissing();` and `spendableAcross:2010` is the hoisted
  `if (payer == address(0)) revert UnknownMandate();`. In each case the successor guard refuses the
  same input under the **same error name** one to twelve lines lower — `:1264` and `:2022` — so no
  input exists that reaches the mutated line and not its shadow, nothing outside the contract can
  observe the removal, and **no test can be written to kill either.** The three classes this
  document already describes all end in a test: unasserted wants one, shadowed wants one that
  isolates the guard, and unreachable-by-construction wants the state forced with `vm.store`. This
  one ends in no test. The diagnostic question that separates it from the merely shadowed is
  whether an input exists that reaches the mutated guard but not its shadow — for `BadConfig 486` on
  2026-08-28 the answer was yes and a test settled it, and here it is no for both.
  **Each shadow is itself a caught mutant in the same run** (`:1264` by four tests, `:2022` by
  `test_spendableAcross_unknownId_reverts`), so the behaviour is asserted; only the duplicate line
  is unobservable. **Neither wanted a contract change.** `_checkCredential`'s shared selector is
  deliberate and splitting it would be wrong: Arc Testnet's live ValidationRegistry was observed on
  2026-08-24 to revert `Error("unknown")` for an unset hash, so the catch arm carries the ordinary
  not-yet-filed case, and a separate error there would report that chain's commonest credential
  state as a registry failure. `spendableAcross`'s duplicate is the price of a uniform loop body, a
  warm SLOAD at 100 gas instead of branching on the first iteration. **Doing nothing was the worst
  option**, because two of eleven targets exiting 1 forever teaches a reader to skip survivors, and
  a real regression at those lines would then be indistinguishable from the known ones. So
  `reference/mutation-gate-sol.py` carries an `EQUIVALENT` table that earns each exemption: an entry
  names its shadow's exact source text, the gate honours the entry only while that text appears
  exactly once inside the same target, deleting the shadow makes the claim lapse and the mutant
  report SURVIVED at exit 1, and rewording the keyed line prints STALE ENTRY. It is keyed by source
  text rather than line number because mutants move — `_checkIdentity`'s pair shifted 1228/1229 to
  1234/1235 on a docstring edit alone. **Writing this up also caught a false claim in the
  contract**: the comment above `:2010` said the hoisted check is what makes "the payer of nothing"
  unreachable below, which the loop's own check does anyway. Corrected in place, comment-only and
  line-neutral.
- **The gate could not address the constructor at all, for as long as it has existed.** New on
  2026-08-29. `function_bounds` looked for `    function NAME(`, and a constructor carries no
  `function` keyword, so `constructor` as a target died on "no function constructor(" instead of
  running. Behind that gap sits the contract's whole defence against a permanently mis-wired
  deployment, `if (_usdc == address(0)) revert BadConfig();`, and it is the one refusal in the
  file that no "the gate is clean" claim has ever covered. `Creation.t.sol:673` does assert it, so
  this was a hole in the verification rather than in the contract. The opener now accepts both
  spellings and the target runs, which is how the census above reaches 89 and not 88. [**That step
  belongs to the constructor alone and it still does.** The census reads 91 as of 2026-08-30 for a
  separate reason, the two F22 injections, so read 88 → 89 as this bullet's own contribution rather
  than as a running total.]
- **The ValidationRegistry's pending state.** Arc documents a two-step flow, so a `requestHash`
  can be requested and unanswered — a state `MockValidationRegistry`'s binary `set` flag cannot
  express, and one the 2026-08-24 live probe did not reach, since those three hashes had never
  been requested at all. §4 argues it must deny whichever way the registry answers; that
  argument is sound and it is still an argument. One `validationRequest` on Arc Testnet with no
  response, then one `cast call`, converts it into an observation.
- **Whether Arc's USDC applies its blocklist to the *spender* leg, not only to payer and
  recipient.** New on 2026-08-29, and it comes out of the mock rather than the contract:
  `MockUSDC` has no blocklist at all, so `spend` has never run against a token that could refuse
  on account of the delegate. Arc's porting guide says a local EVM cannot reproduce blocklist
  enforcement, which makes this unanswerable here by construction. It matters because the answer
  decides whether a blocked delegate produces a clean `TransferFailed` or a mandate that looks
  live in every view and refuses every spend — the same display-versus-enforcement split F35 and
  F36 describe, arriving from outside the contract. One `cast call` against
  `0x3600…0000` for whatever blocklist view it exposes, plus one `spend` attempt from a blocked
  delegate if the faucet will produce one, settles it.

**That makes four testnet transactions owed, and they are the four named above**: the
self-transfer `Transfer` emit, the precompile `transferFrom` against a logging recipient, the
unanswered `validationRequest` plus its `cast call`, and the spender-leg blocklist question. The
first three are each a single observation that turns a documented argument into a measurement; the
fourth may not be reachable on a faucet-funded account, and if it is not, it stays on this list.

**One thing this pass looked for and did not find bounds how much the gaps above can be
hiding.** The ten test files were swept for *vacuity* rather than for adversary surface,
on the reasoning that a test body has no adversary — the only way it can hurt you is by
passing without asserting anything. Four mechanical checks were run, every one derived from the
files. **All four were re-run against the working tree on 2026-08-27 after #28, and both numbers
are given below: the anchor's figure first, then the current one.** Re-running them found an
arithmetic error in one of the four, recorded in place rather than corrected without a note.

- **157 → 165 `test_*`/`testFuzz_*`/`invariant_*` declarations counted from source**, now
  distributed `Creation` 34, `Bounds` 26, `Cosign` 24, `Views` 23, `Gates` 18, `Windows` 14,
  `Idempotency` 13, `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4, `Base` 0. The anchor's
  157 matched the runner's reported 157 exactly, which was the first time the count had been
  established **independently of `forge`'s own output** rather than quoted from it. **165 has
  not been reconciled against a runner** — `forge test` has not been run since #28 landed, so
  this is a source count and nothing more, and #14 owns the reconciliation. #28's arithmetic:
  Cosign 17 → 25 and Views 22 → 23, then Cosign 25 → 24 when a duplicate was deleted (the
  `spendHash`-on-unknown-mandate assertion had been written into both suites; the copy in
  `CosignTest` was removed on 2026-08-27 and a comment left in its place pointing at
  `ViewsTest`, because two suites asserting one line inflates this bullet without testing
  anything twice).
- **Zero vacuous bodies**, re-derived rather than restated: all 165 bodies were walked by
  brace-matching and every one contains at least one assertion or denial helper — 305 assertion
  calls (211 `assertEq`, 43 `assertTrue`, 29 `assertFalse`, 10 `assertGt`, 8 `assertLe`, 2
  `assertLt`, 1 `assertGe`, 1 `assertApproxEqAbs`), plus **49** `payReverts` call sites, 6
  `trySpend`, 4 `assertRevertedWith` and 5 `vm.expectEmit`.

  **Two of those helper figures were inflated by their own declarations, and the fix lowers
  them.** This bullet used to read 56 `payReverts`, 7 `trySpend`, 5 `assertRevertedWith`: raw
  grep totals over all eleven files, which count `Base.t.sol`'s four `payReverts` overloads and
  the three that delegate to a fourth, plus one declaration each for the other two. Subtracting
  the definitions leaves 49, 6 and 4 actual uses. None of it changes the conclusion — a helper
  declaration cannot make a vacuous body non-vacuous either way — and it is corrected here
  because the same slip in the same direction appears three times in this bullet's history, which
  makes it a habit rather than a typo: **a `grep -c` is a count of text, and calling it a count
  of call sites is a claim the grep did not check.**

  **The anchor's headline figure was wrong too, and its own parenthetical was the tell.** It read
  "287 assertion calls (202 `assertEq`, …)", and those components sum to 290, not 287. The true
  anchor count is **199 `assertEq`**, which makes the stated total of 287 add up exactly under
  the rule that produced it (every `assert*(` in all eleven `.t.sol` files, excluding the five
  `assertRevertedWith` listed separately as a denial helper), so the headline was right and one
  component was mistyped — the least harmful version of this error, and still the reason a
  document that reports sub-counts should have them checked against their own total.

  Two components moved for reasons worth naming rather than absorbing: `assertLt` 3 → 2 and a
  new `assertGe` 0 → 1 are the **same** edit, `ArcParity.t.sol`'s second `ARC_LIVE_GASUSED`
  comparison deleted and the derived zero-byte floor put in its place. That is the evidence loss
  F15 records, showing up here as a count.
- **Zero bare `vm.expectRevert()`.** Of 69 → **76** textual occurrences, exactly one is the shared
  helper's parameterised form in `payReverts` — named rather than numbered since 2026-08-30, when
  the number it carried was found stale — and exactly one is inside a *comment*; the remaining
  67 → **74** all name a specific error — 56 → 57 as `MandateManager.<Error>.selector` and
  11 → **17** via `abi.encode*`, which pins the arguments too.
  The comment lives in `CosignTest.test_perTxCapBelowThreshold_isRefusedAtGrantTime`
  (cited by line number before #28 moved it), and it is warning against exactly this hazard in
  exactly these terms: without the expiry, that test *"would still revert and would still pass a
  bare `vm.expectRevert()` — while proving nothing about the cosign check."* That comment's author
  had already thought about this axis, in writing, before the sweep.
- **All 31 → 33 custom errors declared in `MandateManager.sol` are expected by at least one
  test.** No orphan error, checked by enumerating the declarations and grepping each name across
  `test/`. The two added by #28 are `CosignExpired(bytes32,uint40)` and `BadDeadline(uint40)`,
  named 2 and 3 times respectively; `BadConfig` remains the most-expected at 24.

  **Re-derived 2026-08-28 at 35 declarations, and still no orphan.** `CosignNotRequired` (F17)
  and `SelfPayment` (F19) took the count 33 → 35, and every one of the 35 is named by at least
  one `X.selector` in `test/` — the check is the empty output of a loop over
  `grep -oP '^    error \K\w+'` that prints any name with zero `.selector` hits. `SelfPayment`
  arrives at **8**, which puts it above every error except `CosignRequired` (9) and `BadConfig`
  (24, unchanged and still the outlier); `BadDeadline` went 3 → 6 when F17 added the
  mandate-relative bounds. **The method matters more than the numbers**: counting bare error
  names instead of `X.selector` inflates several of these, because this document and the test
  files discuss errors in prose — `SelfPayment` reads as 9 that way and `TransferFailed` as 6
  against a real 2. Two counts of the same thing that disagree by a comment are a recurring
  hazard in this repository.

**Third layer, re-derived 2026-08-29 against `af9df40`, at 207 cases and 37 errors.** The two
figures above are kept as written; this one is added beside them, because a sweep whose history is
overwritten cannot show you which way its own numbers move.

- **207 cases, and this is the first layer since the anchor where a source count met a runner
  count.** The tree holds **204 functions named `test*` plus 3 named `invariant_`**, and the
  mutation gate's baseline line reports `207 passed, 0 failed`. Distribution by file: `Cosign` 46,
  `Creation` 43, `Bounds` 29, `Views` 25, `Gates` 24, `Windows` 14, `Idempotency` 13,
  `WindowInvariant` 5, `ArcParity` 4, `WindowFuzz` 4, `Base` 0. **`WindowInvariant`'s five are 2
  `test_` plus 3 `invariant_`**, which the 165 layer's identical "5" did not say — and that omission
  is why 204 and 207 are both true of this tree. A claim of "N tests" has to say which of the two
  it means. The 165 figure counted `test_*`, `testFuzz_*` and `invariant_*` together, so it is
  comparable to 207 rather than to 204.
- **Zero vacuous bodies at 207 — after the detector was rebuilt, because its first run said
  eight.** The eight were `test_f17_approvingAZeroOrOversizeAmountOrZeroRecipient…`,
  `test_f17_singleDefectRefusalsMatchSpend`,
  `test_createMandate_credentialMinResponseAboveThePassScore…`,
  `test_createMandate_credentialWithZeroRequestHash…`,
  `test_createMandate_identityDataWithoutTheFlag…`,
  `test_createMandate_credentialDataWithoutTheFlag…`,
  `test_identityGate_expectedOwnerNotTheSpender_isRefusedAtGrantTime` and
  `test_identityGate_zeroAgentId_isRefusedAtGrantTime`. Six of the eight assert a refusal in their
  first or only statement. The cause was the same one recorded one layer below: **the vocabulary was
  hand-listed**, and the hand list had grown stale the moment a new helper was written.

  **The rebuilt check therefore stops hand-listing and derives the vocabulary from the harness.** It
  extracts every function body under `test/` by brace matching, seeds a set with the bodies that
  contain a Forge primitive (`assert*(`, `vm.expectRevert`, `vm.expectEmit`, `vm.expectCall`), then
  closes that set under calling — a function that calls a member becomes a member — and walks the
  207 cases only afterwards. It finds **six assertion-bearing helpers, of which the hand list knew
  one**: `payReverts` (74 call sites) was known; `approveReverts` (14), `grantReverts` (6),
  `_assertSameRefusal` (6), `assertRevertedWith` (5) and `_assertConstantsAgree` (4) were not.

  **The same rebuild took away a name the hand list should never have had.** `trySpend` was in it,
  and `trySpend` asserts nothing at all — it makes a low-level `call` and hands back `(ok, err)` for
  the caller to judge. Crediting it as an assertion means a test could route eight call sites'
  worth of spending through it, assert nothing about the result, and still be reported as sound.
  Under the closed set it earns no credit, and the answer is still zero. That is the stronger
  reading of the same word: every test that reaches for `trySpend` goes on to assert on what came
  back.
- **362 primitive assertion calls**, counted after stripping `//` and `/* */` first: 238 `assertEq`,
  61 `assertTrue`, 41 `assertFalse`, 10 `assertGt`, 8 `assertLe`, 2 `assertLt`, 1 `assertGe`, 1
  `assertApproxEqAbs`, plus 5 `vm.expectEmit` and the 109 helper call sites listed above.
  Comment-stripping is this layer's version of the declaration-subtraction correction two bullets
  down: **the lesson that a `grep -c` counts text applies to prose in comments exactly as it applies
  to a helper's own signature**, and this repository discusses its errors in comments constantly.
- **Zero bare `vm.expectRevert()`, at 90 occurrences in code.** 61 name
  `MandateManager.<Error>.selector`, 26 route through `abi.encode*` — which pins the revert
  arguments as well as the error — and 3 are the parameterised forms inside `grantReverts`,
  `payReverts` and `approveReverts`. 61 + 26 + 3 = 90 with no overlap. The textual count is 91; the
  extra one is the comment the layer below quotes, still in place and still warning against exactly
  this hazard.
  **Re-derived on 2026-08-30 against the working tree: 95 in code, 64 + 28 + 3, textual 96, and
  still zero bare.** The three parameterised forms sit in the same three helpers, and the same
  counting rule reproduces this layer's 90 exactly when pointed at `af9df40`, which is what makes
  the two figures comparable. **This bullet named those three helpers by line until 2026-08-30, and
  the third pointer had been wrong since `22fc0fb` earlier the same day** — `Cosign.t.sol:866` was
  the parameterised form at `af9df40` and is a docstring line now. A `HEAD` run of
  `reference/line-citations.py` could not see it, because the working tree and `HEAD` agreed about
  866 itself; the bare run printed the docstring line as the target and reported nothing wrong,
  since a bare run lists rather than judges. **What surfaced it was luck**: six test inserts moved
  `HEAD`'s text off 866, and drift against `HEAD` is the one thing that run does fail on. The
  pointer is a helper's name now, which no insert above it can move.
- **All 37 declared errors are expected by at least one test, and there is no orphan.** Same loop as
  before. `BadConfig` 33, `CosignRequired` 9, `SelfPayment` 8, then `UnknownMandate`,
  `BadDeadline` and `CredentialMissing` at 6 apiece. **Four errors are named exactly once** —
  `MandateExists`, `IdentityTransferred`, `NotAuthorised` and `TooManyMandates` — so deleting one
  test could orphan any of them without touching the contract. This check has been re-run whenever
  an error was added; the four-way tie is the reason it also has to be re-run whenever a test is
  *removed*.

**The first version of that sweep reported nineteen false positives, and the cause is recorded
here because the grep will be re-run.** Searching test bodies for `expectRevert` under-reports
badly, because most denials in this suite route through `Base.t.sol`'s `payReverts` helper, which
contains no such string, so nineteen perfectly well-asserted tests looked empty. A vacuity check
has to know the harness's vocabulary, or it measures the harness instead of the tests.

**It then happened a second time, which is what moved the fix from a longer list to a different
method.** The nineteen were cured by adding `payReverts` to the list; two layers later the same
list produced the eight above, because five more helpers had been written in the meantime and a
hand-maintained vocabulary decays every time an author factors a repeated assertion out of a test.
Nineteen and eight are the same mistake at different sizes. Deriving the vocabulary by closing the
primitive set under calling is the version that cannot decay: a helper written tomorrow is found
tomorrow, and a helper that stops asserting with no test failing — the `trySpend` case — drops
out on its own.

**The first two versions were throwaway greps, so the third one is in the repository.**
It is `reference/vacuity-check.py`, it runs with no arguments from the repository root, and it
exits non-zero if any case is vacuous or any declared error is orphaned, so it can be a CI step
rather than a manual one. Every figure in the five bullets above is its output rather than a
transcription of its output: 207 cases as 204 plus 3, six helpers, 362 primitive calls, 90
`vm.expectRevert` with none bare, 37 errors with no orphan and four named once, zero vacuous. The
reason the method is written into the file's own docstring, at more length than the code, is that
the code is the easy half — a future reader who only has the code will fix the next false positive
by lengthening a list, which is the mistake this file exists to stop them making.

**One number nearby looked stale and was not, and the misreading was made with this document
open.** The check walks thirteen `.sol` files under `test/` — eleven `.t.sol` plus the two mocks
— and ten of the eleven declare cases, `Base.t.sol` being the harness. Several documents here say
the suite has *thirteen*, and an earlier reading matched that against eleven and recorded it as
drift from an older tree. Nothing had drifted, because a Forge *suite* is a **contract**, not a
file, and thirteen concrete contracts under `test/` declare cases: `ArcParity.t.sol` alone holds
four one-case contracts over a shared abstract base, and `WindowInvariant.t.sol` holds a handler
that declares none. 1+1+1+1 + 29 + 46 + 43 + 24 + 13 + 25 + 4 + 5 + 14 = 207.
Eleven test files, thirteen suites and 207 cases are all correct at once, and `FORGE.md` had
already written the arithmetic down for the older figure — one line into a file in this repository
would have stopped the misreading.

It is recorded here rather than reverted without a note, because the failure was not arithmetic. It
was reaching a conclusion about a *count* from a count of something adjacent, which is the same
move that produced the nineteen and the eight two paragraphs up, and it survived long enough to be
written down only because it was a claim about this repository's own paperwork rather than about the
contract. The tooling around it worked exactly as intended — every figure in the bullets above came
out of a script, and the one number entered by hand is the one that was wrong. The suite count is
therefore derived too: `vacuity-check.py` prints case-bearing files, `.t.sol` files, mocks and
suites on one line, which also keeps the two unrelated thirteens from being read as each other.

## 6. Method, and the enumeration behind §3

Three sweeps, two of them run independently and every claim from them re-verified against
source before it entered this document. Two agent claims were checked by hand and
confirmed (`spendCount` has exactly one write site and no guard; the contract contains no
multiplication at all); the `DESIGN.md` and Arc-documentation findings are mine and were
verified by reading both sources directly.

The displayed-but-unenforced sweep behind F1 enumerated **all thirteen `Mandate` fields
and all three of the structs beside it**, asking of each: *can a mandate be created that displays
this via `getMandate` while nothing measures against it?* `payer`, `spender`,
`totalSpent`, `spendCount`, `flags`, `windowCount`, `revoked` and `notBefore` are read
unconditionally. `perTxCap`, `totalCap`, `cosigner` and the allowlist are pinned by
biconditionals. `cosignThreshold` is pinned by the one-directional rule added in #11.
`IdentityGate` and `CredentialGate` are written *only* when their flags are set, which is
the cleanest form of the guarantee and the pattern the others should be read against.
That left exactly one: `expiresAt` — and #22 closed it at `v2:446`, so as of 2026-08-26 the
sweep finds no field in the struct that can be displayed and unread. That is a statement
about *this* struct and *these* thirteen fields only; it has to be re-run against any field
#13 or #23 adds, and neither of those has landed yet.

**The hostile-co-signer sweep, added 2026-08-26 as #16a**, was run the same way: not
against a list of attacks but by finding every site that reads `m.cosigner` or
`_cosignApproved` — seven at the time, listed in full after F18, where the post-#28 recount
to eight is also recorded — and asking of the role as a whole
*what can its holder do that the payer did not intend, including refusing to act.* It
produced F15 through F18 and one restatement of an existing §3 row. Two of the four are
about legibility rather than enforcement, which is now the dominant category in this
document; F15 is the first finding here about what a **participant** can see rather than
what the contract permits. The new entries are appended in sweep order rather than inserted
by severity, so that an F-number cited elsewhere never moves — F15 outranks F11 through F14 and
sits below them.

**The hostile-recipient sweep, added 2026-08-26 as #16b**, was run identically: find every
site that reads `recipient` — four, all inside `spend` (`v2:614`, `615`, `690`, `713`), plus
the allowlist's single write site at `v2:558` — and then ask what the *absence* of a check
permits rather than what the present checks forbid. That inversion is what produced F19: the
recipient is constrained twice and only twice, so everything else is legal, and the most
interesting legal value is the payer's own address. It also produced two non-findings that
are recorded as non-findings rather than dropped, because an unbounded loop and an
Arc-documented no-log rule both look like findings until you check what reads them.

**One methodological result worth more than the findings.** F19 is the **third** time this
document has recorded a hazard that the repository already knew and had filed against the
wrong reader — F1 (`expiresAt`, known to `CHANGELIST.md`), F5 (`Unbounded`, known to the
model), and now F19, which `L3-VAULT.md:492-496` states completely, including the missing
system log, for an audience building a shielded vault. Three instances make it a process
defect, not a coincidence: **a hazard discovered while writing for one audience gets filed
against that audience and nowhere else.** The corrective is cheap and should be adopted — any
document that discovers a hazard about `MandateManager` gets a line in `THREAT-MODEL.md` in
the same commit, even when the discovering document handles it correctly for its own reader.
Nothing in the repository currently requires that, which is why it has now happened three
times.

**A second methodological result, and the first one that did not come from reading.** Every
finding F1–F26 was produced by a human-or-model reading source against documentation, a
neighbouring file, or an adversary's incentives. **F27 and F28 were produced by a tool, and by
the tool failing to do its job rather than succeeding at it.** Extending
`reference/mutation-gate.js` to `evaluate` on 2026-08-28 broke each of the model's 24 denials in
turn and required a test to fail; three mutants survived a green 72/72, and one of them was the
mirror of `MandateManager.sol:942`. The finding is the answer to *why* that guard was untested:
**every `expectedOwner` in the suite was set to the spender, because that is the only non-zero
value that lets a mandate spend at all.** An unreachable guard in the tests turned out to be a
nearly unreachable guard in life, and F28 fell out of writing the test that F27 demanded.

That is worth stating as a method and not just as provenance, and the reason reading missed it is
worse than "reading is fallible". **§3 — "Properties the contract does enforce, and the guard for
each", the table this document's whole claim to systematicity rests on — had no row for either
ERC-8004 check.** Fifteen rows covering spender, recipient, ids, bounds, flags, caps, windows,
nonces, co-signatures and revocation, and nothing for the two checks that `spend` consults at
`:725` and `:726`. `:942` was therefore never walked past twice by accident; **the enumeration it
should have appeared in did not include it**, while §4 discussed both checks at length in F13,
F23 and F24 and §2 named the registries as a trust boundary. A finding-by-finding treatment of a
mechanism can look like coverage of it. The two rows have been added, which is a fix to this
document of the same kind F22 and F23 were.

**Reading finds guards that are wrong. It is much worse at finding guards that are
correct, asserted nowhere, and pointless** — all three of which look identical to a reader who is
checking whether the line does what it says. The transferable rule: **when a mutation gate reports
a survivor, the question to ask is not "which test is missing" but "why was it never written",**
and the second question is the one that reaches design. The gate's own header already said to
treat a survivor as a hypothesis; this extends it — a survivor is a hypothesis about the *code*,
not only about the suite.

The corrective is symmetric with the one above and just as cheap: **the two mutation gates should
be run against any function this document makes a claim about**, not only against the function
that shipped most recently. `evaluate` had never had a single guard broken on purpose before
2026-08-28, despite being the function that decides whether money moves, purely because the gate
had been written for `approveCosignFor` and scanned for `throw refuse(` while `evaluate` denies
with `return deny(`. A mutation gate that covers half a file reports a clean sweep in exactly the
same words as one that covers all of it.

**Where the 40 findings actually came from, since §4 now promises this accounting in writing.**
Sorted by what produced them rather than by what they are:

- **Reading source against something else — 32.** F1–F26, plus F29, F30, F32, F34, F35 and F36.
  The "something else" varies and matters: documentation, a neighbouring file, an adversary's
  incentives, or in F35's and F36's case **the contract's own views read line by line against
  `spend`**, which is a comparison this project had never made before 2026-08-29 and which paid out
  twice on its first run.
- **A mutation gate — 3.** F27 and F28 on 2026-08-28 from extending `reference/mutation-gate.js` to
  `evaluate`, and F37 on 2026-08-29 from the same mutation gate over `createMandate`.
- **A twelve-agent parallel sweep — 3.** F38, F39 and F40, all on 2026-08-30, from twelve readers
  run at once over one bundle of the whole in-scope source, each carrying a single specialty and a
  rule that a claim without a concrete trace is a lead rather than a finding.
- **This document's own coverage list — 1.** F31. §5 had carried a bullet asking for a test that
  stages a future-dated `lastUpdate`; writing it found the arithmetic underneath.
- **Another finding's fix — 1.** F33, whose second half is the grant-time validation F27 asked
  for and could not get until `createMandate` was being edited for another reason.

**The sweep is reading, and putting it in its own bucket is a claim about how much the parallelism
mattered rather than about a new class of instrument.** Twelve of the thirty-two above came from one
reader asking one question at a time, and the same reader had been over `spend` and
`approveCosignFor` repeatedly by 2026-08-30 without seeing any of these three. What the twelve had
that the one did not is a fixed narrow brief each: the finding that became F40 is a comparison
between a comment's justification and the code two functions away, which is a question no one asks
while working through a file in order. **The honest summary is that the same method run twelve ways
found three things it had missed four times running**, and that is a statement about coverage, not
about cleverness.

**One of the three arrived incomplete, and the gap is the same one this document keeps recording.**
The sweep named `spend` as F39's site and did not name `approveCosignFor`, which carried the
identical refusal; F38's registries were reported against the guard in `spend` with the
`isAllowedRecipient` mirror found while fixing it. So **a twelve-way read undercounted a mirror in
the same way four fix sketches before it did** — the fifth, sixth and seventh instances of the
pattern §4 tracks, and the first three not produced by a single reader.

**Three of the four single-source findings share a shape, and it is not the shape a tool is supposed
to have.** In each of F27, F37 and F31 the artefact reported nothing wrong. The gate said a mutant
survived — which by its own header means *a test is missing* — and the divergence was found by
asking why the test was missing. §5 said a boundary was unexercised, which means *a test is
missing*, and the arithmetic error was found by writing it. **Neither instrument found a defect; both
found a silence, and the defect was underneath it.** That is a cheaper thing to build than a bug
finder and it is the thing worth building next.

**The 32-to-8 split should not be read as reading winning.** The two verification instruments have
existed for three days between them, one covers a single function of a JavaScript model and the other
rewrites `revert` statements only, so it cannot see a view at all — §5 records that as the largest
known hole in this project's verification. A method's yield is not comparable to another's until
their coverage is, and on coverage these two are not close. What can be said is narrower and still
useful: **every finding either instrument has produced was invisible to a careful reader who had
already read the same lines**, which is four for four — and the three from the sweep say the same
thing about the reader from the other direction, since a careful reader is what they replaced.

**What has not been swept:** the actor-versus-actor matrix is complete for the delegate, for
third parties, for the **co-signer** and for the **recipient**, and as of 2026-08-26 the
Solidity surface is complete too — all eleven test files and both mocks have now been read,
deliberately not equally. Three were read in full — `test/mocks/MockUSDC.sol`,
`test/mocks/MockRegistries.sol` and `test/Base.t.sol` — because they carry the trust assumptions
that bound what a green suite is able to mean; that produced F23, F24, F25, F26 and the two lists
under *"What a green suite cannot mean"*. The other ten were swept for **vacuity** rather than
adversary surface — a test body has no adversary, so the only way it can hurt you is by passing
without asserting anything — and that produced no findings at all, which is reported in §5 as a
result rather than omitted as a non-event. **There is no deploy script and there never has been:**
`git log --all --diff-filter=A --name-only` shows no `.s.sol` path and no `script/`
directory anywhere in the repository's history, because v1 was deployed by hand with
`forge create`. An earlier version of this paragraph was wrong on both counts, saying "the
four other Solidity files" when there are thirteen, and implying a deploy script existed to
be swept.

**How the trust-assumption sweep was run, and the two moves that produced everything in it.**
Neither was a search for bugs in the mocks; a mock has no users. The question was *what does a
passing test prove about Arc*, which turns every simplification in a mock into a claim, and
`MockUSDC`'s own header is a model for the practice by naming the one it makes most loudly (the
18-decimal dual view, unmodelled, with the reason). The first move was to **read each mock
against the platform documentation rather than against the contract** — which is how the
`getValidationStatus` tuple got checked against Arc's published ABI, an assumption no test in
this repository can reach, since the mock implements Remit's own declaration and would agree with
a wrong one. The second was to ask, of every guard, *what the guard actually compares* — which
turned `Creation.t.sol`'s well-tested `address(0)` registry check into F24 the moment the
question became "and what about an address with no code".

**The correction owed to the first attempt, since this document is about method.** The vacuity
sweep was run once with a grep that under-reported nineteen tests as assertionless, because it
did not know that `payReverts` is where 49 of the suite's denials live — every one of them
routing through the single parameterised `vm.expectRevert` in `Base.t.sol`, which is why a grep
for `expectRevert` in test bodies finds none of them. It was caught by disbelief at the result
rather than by rigour — the list contained
`test_zeroAmount_reverts`, which cannot plausibly be assertionless — and that is a weaker
control than it should be. The general rule is the one §5 now records: an automated check over
a codebase with a harness has to be told the harness's vocabulary, or it measures the wrong
thing and reports a clean-looking number either way.

---

*Nothing in this document should be read as a claim that Remit is secure. It is a claim
about what has been looked at, by whom, and how — which is the only claim its
author is in a position to make.*
