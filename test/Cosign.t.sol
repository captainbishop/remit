// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * Co-signing: a second signature required above an amount the payer chooses.
 *
 * The design decision worth defending is WHAT gets signed. A co-signature that
 * authorises "a spend on this mandate" is nearly worthless — the agent picks the
 * recipient and the amount afterwards. So the cosigner signs a hash committing to
 * the mandate, the spender, the recipient, the exact amount, the reference and the
 * nonce, on this chain, at this contract address. Changing any of those produces a
 * different hash and the approval simply does not apply.
 *
 * TWO THINGS CHANGED IN v2 and they change what this file has to prove.
 *
 * F15 removed the opaque `approveCosign(mandateId, hash)`. Approving now means naming the
 * recipient, amount, reference and nonce, and the contract derives the hash itself — so the
 * cosigner's transaction shows them what they are authorising instead of 32 opaque bytes.
 * It was deleted rather than kept alongside `approveCosignFor`, because whoever asks for the
 * signature chooses the entry point and that party is usually the agent: a legibility
 * control the adversary can opt out of on the victim's behalf is not a control. `spendHash`
 * lost its `spender_` parameter in the same change and reads the mandate's own spender, so
 * the hash of a spend nobody can perform is no longer constructible.
 *
 * F16 gave every approval a deadline. There is no way to write a live-forever approval any
 * more: `validUntil` is required, must be strictly in the future, and may not sit further
 * ahead than `MAX_COSIGN_TTL`. The deadline is written out at each call site below rather
 * than defaulted by a local helper — a helper that quietly supplied one would also hide
 * that a real cosigner has to choose it, which is the whole of the finding.
 */
contract CosignTest is Base {
    /// perTxCap 100, cosign above 10, daily window 500.
    function cosignParams() internal view returns (MandateManager.MandateParams memory) {
        return withCosign(simpleParams(), boss, usd(10));
    }

    // ------------------------------------------------------- the threshold

    /// The threshold comparison is `amount > cosignThreshold`, so a spend of exactly
    /// the threshold goes through unsigned. "Requires approval above 10" is what a
    /// payer means when they write 10, and a strict reading avoids the surprise of a
    /// round-number payment needing a human.
    function test_atTheThreshold_noSignatureRequired() public {
        bytes32 id = grant(cosignParams());
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    function test_aboveTheThreshold_requiresASignature() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, vendor, uint256(usd(10)) + 1, REF, nonce);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, uint256(usd(10)) + 1, REF, nonce);
    }

    /// The error carries the hash the cosigner needs to approve, so the agent can
    /// hand a human exactly one thing to sign without reconstructing the encoding.
    ///
    /// v2 (F15): the hash is no longer what the cosigner submits — `approveCosignFor` takes
    /// the tuple. The hash in the error is still the right thing for the agent to *quote*,
    /// because it lets a cosigner check that the tuple they were handed is the one the chain
    /// actually refused. That is the assertion below: reconstructing from the tuple must
    /// reproduce the reported hash, and approving the tuple must satisfy the spend.
    function test_cosignRequired_carriesTheHashToApprove() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        (bool ok, bytes memory err) = trySpend(id, vendor, usd(50), nonce);
        assertFalse(ok);
        assertRevertedWith(err, MandateManager.CosignRequired.selector, "expected CosignRequired");

        bytes32 reported = abi.decode(sliceArgs(err), (bytes32));
        assertEq(reported, mm.spendHash(id, vendor, usd(50), REF, nonce), "hash in the error is usable");

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertEq(approved, reported, "approving the tuple must produce the hash the spend demanded");

        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    function test_withApproval_theSpendGoesThrough() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, vendor, usd(50), REF, nonce);
        uint40 validUntil = uint40(block.timestamp + DAY);

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.CosignApproved(id, hash, boss, vendor, usd(50), validUntil);
        vm.prank(boss);
        mm.approveCosignFor(id, vendor, usd(50), REF, nonce, validUntil);

        assertTrue(mm.isCosignApproved(id, hash));
        assertEq(mm.cosignApprovalDeadline(id, hash), validUntil);
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    /// One signature authorises one spend. The approval is deleted on use, so it
    /// cannot accumulate into standing permission for a repeated payment.
    function test_approval_isConsumedByTheSpend() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        payWithNonce(id, vendor, usd(50), nonce);

        assertFalse(mm.isCosignApproved(id, hash), "approval must not survive its use");
        // Consumption is a `delete`, not an expiry, so the raw slot must read zero too —
        // otherwise `cosignApprovalDeadline` would keep reporting a deadline for an approval
        // that has already been spent, which is exactly the confusion the split view exists
        // to avoid.
        assertEq(mm.cosignApprovalDeadline(id, hash), 0, "the slot itself must be cleared");
    }

    /**
     * An approval must survive a spend that failed for an unrelated reason.
     *
     * If a transient window breach burned the signature, every retry would need the
     * human again — which in practice means the human starts pre-approving in bulk,
     * and the control stops meaning anything. The approval is deleted only on the
     * path where the spend actually succeeds, and a revert unwinds the delete anyway.
     *
     * THIS TEST IS THE FLOOR ON `MAX_COSIGN_TTL` and the reason it is 30 days rather than
     * something tidy like an hour. The retry happens after `t0 + DAY + DAY/12` — about 26
     * hours after the approval — so any cap below that would break the property this test
     * defends, in a way that looks like a timing flake rather than a design decision. The
     * deadline below is 3 days: comfortably over the floor, comfortably under the cap, and
     * written as a literal so the relationship is visible instead of inferred.
     */
    function test_approval_survivesAnUnrelatedFailure() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.flags = F_PER_TX;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(100), buckets: 12});
        p = withCosign(p, boss, usd(25));
        p = withExpiry(p); // v2: a perTxCap and a window are not a lifetime bound
        bytes32 id = grant(p);

        uint64 t0 = uint64(((block.timestamp / (DAY / 12)) + 1) * (DAY / 12));
        vm.warp(t0);

        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(90), REF, nonce, uint40(t0 + 3 days));

        // 20 is genuinely under the 25 threshold, so it needs no signature — and it
        // has to be over 10 for 20 + 90 to breach the 100 window cap, which is what
        // makes the retry below an *unrelated* failure. The threshold sits between
        // the two for exactly that reason.
        pay(id, usd(20));
        payReverts(id, usd(90), overWindowCap(DAY, usd(100), usd(20)));
        assertTrue(mm.isCosignApproved(id, hash), "the signature is still good");

        vm.warp(t0 + DAY + DAY / 12); // window refills
        payWithNonce(id, vendor, usd(90), nonce);
        assertEq(token.balanceOf(vendor), usd(110));
    }

    // -------------------------------------------------------- the deadline

    /**
     * NEW IN v2 (F16). An approval dies on its own.
     *
     * v1 had no way to write a signature that stopped mattering. A cosigner who approved a
     * payment the agent then never made left an authorisation sitting in storage forever,
     * spendable the moment the agent chose — months later, after the invoice was settled by
     * other means, after the cosigner left the company. `withdrawCosign` existed but required
     * the cosigner to *remember*, which is the property a control should not depend on.
     *
     * `validUntil` is EXCLUSIVE, matching `expiresAt`. Arc's blocks can share a timestamp, so
     * an inclusive bound would leave a final second in which the approval's liveness depends
     * on which block within that second included the spend.
     */
    function test_approval_expires() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        uint40 validUntil = uint40(block.timestamp + DAY);

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, validUntil);

        vm.warp(uint256(validUntil) - 1);
        assertTrue(mm.isCosignApproved(id, hash), "one second early it is still good");

        vm.warp(validUntil);
        assertFalse(mm.isCosignApproved(id, hash), "AT the deadline it is dead");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignExpired.selector, hash, validUntil));
        mm.spend(id, vendor, usd(50), REF, nonce);
        assertEq(token.balanceOf(vendor), 0);
    }

    /// An expired approval reports EXPIRED, not REQUIRED. "Nobody approved this" and "the
    /// cosigner approved it and you were too slow" call for different next actions — obtain a
    /// signature versus obtain a fresh one — and collapsing them sends an operator to chase
    /// the wrong party. The pair below is the whole point of splitting the error.
    function test_expiredAndAbsent_areDifferentErrors() public {
        bytes32 id = grant(cosignParams());

        bytes32 unapproved = nextNonce();
        bytes32 absentHash = mm.spendHash(id, vendor, usd(50), REF, unapproved);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, absentHash));
        mm.spend(id, vendor, usd(50), REF, unapproved);

        bytes32 nonce = nextNonce();
        uint40 validUntil = uint40(block.timestamp + DAY);
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, validUntil);

        vm.warp(uint256(validUntil) + 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignExpired.selector, hash, validUntil));
        mm.spend(id, vendor, usd(50), REF, nonce);
    }

    /// The stale entry LINGERS rather than being swept, and that is deliberate: no denial
    /// path in this contract writes storage, so a failed spend cannot be made to pay for a
    /// cleanup. It is inert, because every read compares it against the clock — but a payer
    /// reading the raw view must not mistake it for a live authorisation, which is why there
    /// are two views rather than one.
    function test_expiredApproval_lingersInStorageButIsInert() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        uint40 validUntil = uint40(block.timestamp + DAY);

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, validUntil);

        vm.warp(uint256(validUntil) + 10 days);
        assertEq(mm.cosignApprovalDeadline(id, hash), validUntil, "the raw slot still holds it");
        assertFalse(mm.isCosignApproved(id, hash), "and it is not honoured");

        // Withdrawal is what actually clears it, and it still works after expiry — a cosigner
        // tidying up must not be told the approval does not exist.
        vm.prank(boss);
        mm.withdrawCosign(id, hash);
        assertEq(mm.cosignApprovalDeadline(id, hash), 0);
    }

    /**
     * A deadline in the past, or at `now`, is refused rather than stored.
     *
     * Zero means "no approval exists", so a past deadline cannot be represented as anything
     * other than an approval that exists and can never be used — a signature the cosigner
     * believes they gave and that the chain will never honour. Refusing at the door is the
     * only reading that keeps the storage word honest.
     */
    function test_deadlineInThePast_isRefused() public {
        bytes32 id = grant(cosignParams());
        // Forward, not back. `Base.setUp` already warps to 1,000,000, and rewinding the clock
        // under a live mandate would test the contract against a state Arc cannot produce.
        vm.warp(2_000_000);

        uint40[4] memory bad = [uint40(0), uint40(1), uint40(1_999_999), uint40(2_000_000)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(boss);
            vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, bad[i]));
            mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), bad[i]);
        }
    }

    /**
     * A deadline beyond `MAX_COSIGN_TTL` is refused, and the cap is what keeps F16 from
     * being advisory rather than enforced.
     *
     * The agent constructs the transaction the cosigner signs. Without an upper bound it
     * would pre-fill `type(uint40).max`, the cosigner would see a field they have no reason
     * to question, and every approval would be immortal again — the exact state this finding
     * exists to end, restored through the one party the control is aimed at.
     */
    function test_deadlineBeyondTheCap_isRefused() public {
        bytes32 id = grant(cosignParams());
        uint40 tooFar = uint40(block.timestamp + mm.MAX_COSIGN_TTL() + 1);

        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, tooFar));
        mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), tooFar);

        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, type(uint40).max));
        mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), type(uint40).max);
    }

    /// Exactly at the cap is legal. The bound is inclusive on this side so a cosigner who
    /// wants the longest window the contract permits does not have to guess an off-by-one,
    /// and so the two tests above bracket the boundary from both directions rather than
    /// leaving the exact value untested.
    function test_deadlineExactlyAtTheCap_isAccepted() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        uint40 atCap = uint40(block.timestamp + mm.MAX_COSIGN_TTL());

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, atCap);
        assertEq(mm.cosignApprovalDeadline(id, hash), atCap);

        vm.warp(uint256(atCap) - 1);
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    // ------------------------------------------------------------- attacks

    /**
     * ATTACK: redirect an approved payment.
     *
     * The agent gets a signature for 50 to the vendor, then sends 50 to itself. The
     * recipient is inside the hash, so the approval does not apply and the spend is
     * refused — the agent has gained nothing from having been approved once.
     */
    function test_ATTACK_redirectingAnApprovedSpend_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        bytes32 redirected = mm.spendHash(id, other, usd(50), REF, nonce);
        assertTrue(approved != redirected, "the recipient must be inside the hash");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, redirected));
        mm.spend(id, other, usd(50), REF, nonce);
        assertEq(token.balanceOf(other), 0);
    }

    /// ATTACK: inflate an approved amount. Same idea, different field.
    function test_ATTACK_inflatingAnApprovedSpend_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        // The inflated hash is computed BEFORE the prank. `vm.prank` applies to the next
        // call, and an `mm.spendHash(...)` sitting in an argument list is that call — it
        // would consume the prank and leave the approval arriving from the test contract,
        // which is not the cosigner. Same hazard `Base.payReverts` exists to contain.
        //
        // v2 (F15) narrows this hazard without removing it: `approveCosignFor` no longer
        // takes a hash, so the pranked call cannot swallow a `spendHash` of its own — but
        // any `spendHash` used for an ASSERTION still has to be hoisted, as here.
        bytes32 inflated = mm.spendHash(id, vendor, usd(90), REF, nonce);

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(approved != inflated, "the amount must be inside the hash");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, inflated));
        mm.spend(id, vendor, usd(90), REF, nonce);
    }

    /// ATTACK: reuse the approval for a different invoice by changing the reference.
    /// The reference is the payer's own bookkeeping field and it is signed too, so an
    /// approval for one invoice cannot silently settle another.
    function test_ATTACK_swappingTheReference_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 otherRef = bytes32("invoice-9999");

        // Hoisted for the same reason as above.
        bytes32 swapped = mm.spendHash(id, vendor, usd(50), otherRef, nonce);

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(approved != swapped, "the reference must be inside the hash");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, swapped));
        mm.spend(id, vendor, usd(50), otherRef, nonce);
    }

    /// The hash is bound to this chain and this contract address, so an approval
    /// harvested from a testnet deployment cannot be replayed against mainnet.
    ///
    /// The preimage is UNCHANGED by v2 despite `spendHash` losing a parameter: the spender
    /// still occupies the fifth field, read from the mandate instead of taken from the
    /// caller. That is what this reconstruction pins — a same-shape preimage means an
    /// approval computed off-chain by v1 tooling still matches, so the change is a narrowing
    /// of who can *ask* for a hash and not a redefinition of the hash itself.
    function test_spendHash_isBoundToChainAndContract() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = bytes32("n");
        assertEq(
            mm.spendHash(id, vendor, usd(50), REF, nonce),
            keccak256(
                abi.encode(
                    mm.DOMAIN(), block.chainid, address(mm), id, agent, vendor, uint256(usd(50)), REF, nonce
                )
            )
        );
    }

    /**
     * ATTACK (F15): ask a cosigner to approve a spend nobody can make.
     *
     * v1's `spendHash` took the spender as an argument and the two-argument `approveCosign`
     * took the resulting 32 bytes with no way to look inside them. So an agent could compute
     * the hash of a spend by SOMEBODY ELSE, hand it over, and collect a signature for an
     * authorisation that no `spend` call can ever match — `spend` refuses `WrongSpender`
     * before it hashes anything. The cosigner had no way to notice: the argument was opaque
     * and the transaction succeeded.
     *
     * That is now unconstructible rather than merely detectable. `spendHash` reads
     * `m.spender`, so there is no argument to poison, and `approveCosignFor` derives the hash
     * from the mandate for itself. `other` is a perfectly good address that is simply not
     * this mandate's spender, and both halves of the old attack are checked below: the hash
     * the cosigner would have been shown no longer exists as a distinct value, and the
     * approval that results is live for the real spender.
     */
    function test_ATTACK_approvingASpendByANonSpender_isUnconstructible() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        // There is exactly one hash for this tuple on this mandate, and it is the one the
        // mandate's own spender will present.
        assertEq(approved, mm.spendHash(id, vendor, usd(50), REF, nonce));
        assertTrue(mm.isCosignApproved(id, approved), "and it is live, not a dead entry");

        // A mandate with a DIFFERENT spender and an otherwise identical tuple hashes
        // differently — which is the property that made the old attack possible and is now
        // reachable only by holding a second mandate, whose spender the payer chose.
        MandateManager.MandateParams memory p = withCosign(simpleParams(), boss, usd(10));
        p.spender = other;
        vm.prank(payer);
        bytes32 otherId = mm.createMandate(bytes32("other-spender"), p);
        assertTrue(
            approved != mm.spendHash(otherId, vendor, usd(50), REF, nonce),
            "the spender is still inside the preimage"
        );

        // And the real spend still goes through, so the narrowing cost nothing functional.
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    // The companion property — `spendHash` REFUSES an unknown mandate rather than returning
    // the hash of a spend by the zero address — is pinned once, in
    // `ViewsTest.test_spendHash_onUnknownMandate_reverts`, alongside the enumeration of which
    // views read as empty and which revert. It was written here too and the copy was deleted
    // on 2026-08-27: no mandate is granted and no fixture is touched, so the two bodies were
    // equivalent, and two suites asserting the same line inflates a count without testing
    // anything twice.

    // ------------------------------------------------------ who may approve

    function test_onlyTheNamedCosignerMayApprove() public {
        bytes32 id = grant(cosignParams());
        uint40 validUntil = uint40(block.timestamp + DAY);

        vm.prank(agent); // the agent cannot approve its own spend
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosignFor(id, vendor, usd(50), REF, bytes32("n"), validUntil);

        // Nor can the payer, without being named as the cosigner. If the payer wants
        // that power they name themselves at grant time — silently accepting it here
        // would make the cosigner field advisory.
        vm.prank(payer);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosignFor(id, vendor, usd(50), REF, bytes32("n"), validUntil);
    }

    function test_approveCosignFor_onAMandateWithoutCosigning_reverts() public {
        bytes32 id = grant(simpleParams());
        vm.prank(boss);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.approveCosignFor(id, vendor, usd(50), REF, bytes32("n"), uint40(block.timestamp + DAY));
    }

    /// Existence is checked before configuration and before authorisation, so a typo'd id
    /// reports the typo rather than `NotCosigner` — which on an empty struct is technically
    /// true (nobody is the zero address's cosigner) and completely unhelpful.
    function test_approveCosignFor_onUnknownMandate_reverts() public {
        vm.prank(boss);
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.approveCosignFor(bytes32("nope"), vendor, usd(50), REF, bytes32("n"), uint40(block.timestamp + DAY));
    }

    /// A cosigner who changes their mind before the agent acts can withdraw. Without
    /// this, approving is irreversible and a cosigner would rationally never approve
    /// early.
    function test_withdrawCosign_revokesAnUnusedApproval() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.startPrank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.CosignWithdrawn(id, hash, boss);
        mm.withdrawCosign(id, hash);
        vm.stopPrank();

        assertFalse(mm.isCosignApproved(id, hash));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, usd(50), REF, nonce);
    }

    function test_withdrawCosign_byAStranger_reverts() public {
        bytes32 id = grant(cosignParams());
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, bytes32("n"), uint40(block.timestamp + DAY));

        vm.prank(agent);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.withdrawCosign(id, hash);
        assertTrue(mm.isCosignApproved(id, hash));
    }

    // ------------------------------------------------------------ ordering

    /**
     * Co-signing is checked LAST, after every cap.
     *
     * A spend that would be refused anyway must not first demand a human signature.
     * Getting this backwards produces the worst possible workflow: the agent asks a
     * person to approve something, the person approves it, and the chain refuses it —
     * training the person to approve without reading.
     */
    function test_cosign_isCheckedAfterEveryCap() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.flags = F_PER_TX;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(50), buckets: 12});
        p = withCosign(p, boss, usd(10));
        p = withExpiry(p); // v2: a perTxCap and a window are not a lifetime bound
        bytes32 id = grant(p);

        // 90 is over the window cap AND over the cosign threshold. The window wins.
        payReverts(id, usd(90), overWindowCap(DAY, usd(50), 0));

        // And over the per-tx cap too — that wins over both.
        payReverts(id, usd(500), MandateManager.OverPerTxCap.selector);
    }

    /**
     * FIXED IN v2. This test used to be named `test_DOCUMENTED_SOFT_SPOT_...` and its
     * comment argued the opposite of what it now asserts, so the old text is worth
     * quoting rather than deleting: *"`createMandate` accepts this configuration rather
     * than rejecting it, which is a deliberate choice not to grow a validation rule for
     * every combination that is merely useless — but it IS a footgun, it is in the
     * README, and it is pinned here so the behaviour is a decision rather than an
     * accident."*
     *
     * Two things retired that reasoning. Remit is now intended to hold real money, which
     * turns "merely useless" into "advertises a control it does not have" — `getMandate`
     * returns a populated cosigner and a plausible threshold either way, so a payer
     * auditing their own grant cannot tell the difference. And v1's immutability means a
     * combination left legal now is legal forever at that address; the cost of the rule
     * is one comparison at grant time, paid once per mandate, against a supervision gate
     * that silently never fires.
     *
     * The refusal is deliberately NOT `perTxCap < cosignThreshold`, which the changelist
     * proposed and which is wrong twice over — see `Creation.t.sol`, where the whole
     * boundary lives. This test keeps only the shape it was originally written for.
     */
    function test_perTxCapBelowThreshold_isRefusedAtGrantTime() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(10);
        p.flags = F_PER_TX;
        p = withCosign(p, boss, usd(100)); // threshold above the per-tx cap
        // The horizon is load-bearing for the ASSERTION, not just for the second grant
        // below. `Unbounded()` is checked before every `BadConfig()` in `createMandate`,
        // so without it this test would still revert and would still pass a bare
        // `vm.expectRevert()` — while proving nothing about the cosign gate.
        p = withExpiry(p);

        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("dead-gate"), p);

        // And the spends the old test performed are now unperformable, because there is
        // no mandate to spend from. Asserted by reusing THE SAME SALT with the threshold
        // repaired: if the refused attempt had written any state, this would come back
        // `MandateExists` instead of succeeding. That is a stronger check than reading a
        // zeroed struct, and it needs no off-chain id derivation — there is no
        // `mandateId` view, the id is keccak over (DOMAIN, chainid, this, payer, salt).
        p.cosignThreshold = usd(9);
        vm.prank(payer);
        bytes32 id = mm.createMandate(bytes32("dead-gate"), p);

        // One base unit of threshold below the cap is all it takes, and the gate is
        // alive: the largest spend the mandate permits now demands a signature. This is
        // the same boundary the old test straddled from the wrong side.
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, vendor, usd(10), REF, nonce);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, usd(10), REF, nonce);
    }

    // ---------------------------------------------------------------- util

    /// Strip the 4-byte selector, leaving the ABI-encoded arguments.
    function sliceArgs(bytes memory data) internal pure returns (bytes memory args) {
        require(data.length >= 4, "no args");
        args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
    }
}
