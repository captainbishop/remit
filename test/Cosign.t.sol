// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * Co-signing: a second signature required above an amount the payer chooses.
 *
 * The design decision worth defending is WHAT gets signed. A co-signature that
 * authorises "a spend on this mandate" is nearly worthless — the agent picks the
 * recipient and the amount afterwards. The cosigner therefore signs a hash committing
 * to the mandate, the spender, the recipient, the exact amount, the reference and the
 * nonce, on this chain, at this contract address. Changing any of those produces a
 * different hash and the approval simply does not apply.
 *
 * TWO THINGS CHANGED IN v2 and they change what this file has to prove.
 *
 * F15 removed the opaque `approveCosign(mandateId, hash)`, so approving now means naming the
 * recipient, amount, reference and nonce, with the contract deriving the hash itself: the
 * cosigner's transaction shows them what they are authorising instead of 32 opaque bytes.
 * It was deleted rather than kept alongside `approveCosignFor`, because whoever asks for the
 * signature chooses the entry point and that party is usually the agent: a legibility
 * control the adversary can opt out of on the victim's behalf is not a control. `spendHash`
 * lost its `spender_` parameter in the same change and reads the mandate's own spender, so
 * the hash of a spend no account can perform is no longer constructible.
 *
 * F16 gave every approval a deadline. There is no way to write a live-forever approval any
 * more: `validUntil` is required, must be strictly in the future, and may not sit further
 * ahead than `MAX_COSIGN_TTL`. The deadline is written out at each call site below rather
 * than defaulted by a local helper — a helper that supplied one implicitly would also hide
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
     * If a transient window breach burned the signature, every retry would need the human
     * again, which in practice means the human starts pre-approving in bulk and the control
     * stops meaning anything. The approval is deleted only on the path where the spend
     * actually succeeds, and a revert unwinds the delete anyway.
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

        // 20 is under the 25 threshold, so it needs no signature, and it has to be over
        // 10 for 20 + 90 to breach the 100 window cap, which is what makes the retry
        // below an *unrelated* failure. The threshold sits between the two for exactly
        // that reason.
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

    /// An expired approval reports EXPIRED, not REQUIRED. "No cosigner approved this" and
    /// "the cosigner approved it and you were too slow" call for different next actions —
    /// obtain a signature versus obtain a fresh one — and collapsing them sends an operator
    /// to chase the wrong party. The pair below is the whole point of splitting the error.
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
        mm.withdrawCosign(id, hash, nonce);
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
        bytes32 fresh = nextNonce();

        // Hoisted before any prank: `mm.spendHash(...)` sitting in an argument list is itself a
        // call, and `vm.prank` applies to the next one.
        bytes32 onFresh = mm.spendHash(id, other, usd(50), REF, fresh);

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        bytes32 redirected = mm.spendHash(id, other, usd(50), REF, nonce);
        assertTrue(approved != redirected, "the recipient must be inside the hash");

        // Reusing the approved nonce meets F30's reservation first. That nonce is committed to
        // `approved`, and the redirected spend is not it. Before F30 this reached the co-sign
        // check and answered `CosignRequired(redirected)`: the refusal is the same either way,
        // and the reason given is now the better one, because it names the payment the co-signer
        // authorised instead of inviting the agent to go and collect a signature for the
        // redirect.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.NonceReserved.selector, approved));
        mm.spend(id, other, usd(50), REF, nonce);

        // A fresh nonce carries no reservation, so this leg reaches the co-sign check, and there
        // is no approval for any hash with this recipient in it. This is the half that shows the
        // recipient is inside the hash, rather than only showing the nonce is spoken for.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, onFresh));
        mm.spend(id, other, usd(50), REF, fresh);

        assertEq(token.balanceOf(other), 0, "neither attempt moved money");
    }

    /// ATTACK: inflate an approved amount, which is the same attack against a different field.
    function test_ATTACK_inflatingAnApprovedSpend_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        // The inflated hash is computed BEFORE the prank. `vm.prank` applies to the next
        // call, and an `mm.spendHash(...)` sitting in an argument list is that call: it would
        // consume the prank and leave the approval arriving from the test contract rather than
        // from the cosigner, which is the hazard `Base.payReverts` exists to contain.
        //
        // v2 (F15) narrows this hazard without removing it: `approveCosignFor` no longer
        // takes a hash, so the pranked call cannot swallow a `spendHash` of its own — but
        // any `spendHash` used for an ASSERTION still has to be hoisted, as here.
        bytes32 inflated = mm.spendHash(id, vendor, usd(90), REF, nonce);
        bytes32 fresh = nextNonce();
        bytes32 onFresh = mm.spendHash(id, vendor, usd(90), REF, fresh);

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(approved != inflated, "the amount must be inside the hash");

        // F30's reservation answers first on the approved nonce; see the redirect test above for
        // why that is the better of the two refusals.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.NonceReserved.selector, approved));
        mm.spend(id, vendor, usd(90), REF, nonce);

        // On a fresh nonce the co-sign check runs and the inflated amount has no approval. 90 is
        // inside the per-transaction cap, so this really is the co-signature stopping it and not
        // a cap doing the work — the refusal names the inflated hash.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, onFresh));
        mm.spend(id, vendor, usd(90), REF, fresh);

        assertEq(token.balanceOf(vendor), 0, "neither attempt moved money");
    }

    /// ATTACK: reuse the approval for a different invoice by changing the reference.
    /// The reference is the payer's own bookkeeping field and it is signed too, so an
    /// approval for one invoice cannot be used to settle another.
    function test_ATTACK_swappingTheReference_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 otherRef = bytes32("invoice-9999");

        // Hoisted for the same reason as above.
        bytes32 swapped = mm.spendHash(id, vendor, usd(50), otherRef, nonce);
        bytes32 fresh = nextNonce();
        bytes32 onFresh = mm.spendHash(id, vendor, usd(50), otherRef, fresh);

        vm.prank(boss);
        bytes32 approved = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(approved != swapped, "the reference must be inside the hash");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.NonceReserved.selector, approved));
        mm.spend(id, vendor, usd(50), otherRef, nonce);

        // The fresh-nonce leg is the one that pins the reference itself: same mandate, same
        // recipient, same amount, everything a careless reading would call approved, and it is
        // still refused because invoice-9999 is not invoice-0001.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, onFresh));
        mm.spend(id, vendor, usd(50), otherRef, fresh);

        assertEq(token.balanceOf(vendor), 0, "neither attempt moved money");
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
     * ATTACK (F15): ask a cosigner to approve a spend no account can make.
     *
     * v1's `spendHash` took the spender as an argument and the two-argument `approveCosign`
     * took the resulting 32 bytes with no way to look inside them, so an agent could compute
     * the hash of a spend by ANOTHER ACCOUNT, hand it over, and collect a signature for an
     * authorisation that no `spend` call can ever match — `spend` refuses `WrongSpender`
     * before it hashes anything. The cosigner had no way to notice, because the argument was
     * opaque and the transaction succeeded.
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

        // The real spend still goes through, so the narrowing cost nothing functional.
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

        // Nor can the payer, without being named as the cosigner. If the payer wants that
        // power they name themselves at grant time; accepting the approval here without an
        // error would make the cosigner field advisory.
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
    /// true (no account is the zero address's cosigner) and completely unhelpful.
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
        mm.withdrawCosign(id, hash, nonce);
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
        mm.withdrawCosign(id, hash, bytes32("n"));
        assertTrue(mm.isCosignApproved(id, hash));
    }

    /// CHANGED IN v2 (F11). Existence is checked first here, as it is in the sibling that grants.
    /// `m.cosigner` on an absent mandate is the zero address and no transaction can come from
    /// there, so this call already reverted — with `NotCosigner`, which on an empty struct is true
    /// and useless. Nothing was exploitable; the fix is entirely about what the caller is told.
    function test_withdrawCosign_onUnknownMandate_reverts() public {
        vm.prank(boss);
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.withdrawCosign(bytes32("nope"), bytes32("h"), bytes32("n"));
    }

    /// CHANGED IN v2 (F11). A mandate without `F_COSIGN` has no approvals to withdraw and no
    /// cosigner either, because `createMandate` enforces the biconditional between the flag and the
    /// address. `BadConfig` names the missing configuration; `NotCosigner` invited the reader to go
    /// looking for a cosigner who was never set.
    function test_withdrawCosign_withoutTheCosignFlag_reverts() public {
        bytes32 id = grant(simpleParams());
        vm.prank(boss);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.withdrawCosign(id, bytes32("h"), bytes32("n"));
    }

    /**
     * CHANGED IN v2 (F11). A withdrawal that removes nothing has to say nothing.
     *
     * The delete stays unconditional, so the call still succeeds on a hash that was never approved.
     * Refusing it would let one stale entry in an atomic batch take the live withdrawals beside it
     * down, and removing authority must never be blocked. What was wrong is that it emitted
     * `CosignWithdrawn` regardless, putting a withdrawal in the audit trail with no approval to
     * match — the mirror image of the repeated `MandateRevoked` F11 also removed.
     *
     * Three shapes have to be silent. Nothing approved and nothing reserved; a hash of zero against
     * an unreserved nonce, which is the case the `reserved != 0` half of the condition exists for,
     * since without it the comparison reads zero against zero and calls that a removal; and a nonce
     * reserved for a different hash, which must also leave the live approval standing.
     */
    function test_f11_aWithdrawalThatRemovesNothing_emitsNothing() public {
        bytes32 id = grant(cosignParams());
        vm.startPrank(boss);

        vm.recordLogs();
        mm.withdrawCosign(id, bytes32("never approved"), bytes32("never reserved"));
        assertEq(vm.getRecordedLogs().length, 0, "nothing was removed, so nothing is announced");

        vm.recordLogs();
        mm.withdrawCosign(id, bytes32(0), bytes32("still unreserved"));
        assertEq(vm.getRecordedLogs().length, 0, "zero must not match an empty reservation");

        // A real approval, then a withdrawal naming its nonce and the wrong hash.
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.recordLogs();
        mm.withdrawCosign(id, bytes32("wrong hash"), nonce);
        assertEq(vm.getRecordedLogs().length, 0, "a mismatched hash removes nothing");
        vm.stopPrank();

        assertTrue(mm.isCosignApproved(id, hash), "and the live approval survived the no-op");
    }

    /**
     * CHANGED IN v2 (F11). Either half of the removal is enough to announce, which is why the
     * event's condition is a disjunction rather than the `hadApproval` test alone.
     *
     * The right hash under the wrong nonce clears the approval and leaves the reservation, so real
     * authority is removed twice over two calls: the first with `hadApproval` true, the repeat with
     * the right nonce while `hadApproval` is already false. A condition testing only the approval
     * would go quiet on the second call, and freeing a reserved nonce is the one thing a delegate
     * needs to see in the log — it is what tells them the nonce is spendable again.
     */
    function test_f11_eitherHalfOfTheRemovalIsEnoughToAnnounce() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.startPrank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.CosignWithdrawn(id, hash, boss);
        mm.withdrawCosign(id, hash, bytes32("wrong nonce"));

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.CosignWithdrawn(id, hash, boss);
        mm.withdrawCosign(id, hash, nonce);
        vm.stopPrank();

        // The nonce is spendable again, which is the authority the second call removed.
        vm.prank(agent);
        mm.spend(id, vendor, 1, REF, nonce);
        assertEq(token.balanceOf(vendor), 1, "the reservation was released by the repeat");
    }

    // ------------------------------------------------- F30: the nonce reservation

    /**
     * The defect, stated as the sequence that produced it.
     *
     * The co-signer approves 50 USDC to the vendor under nonce N. `_cosignApproved` is keyed by
     * hash and `_usedNonce` by nonce, and nothing joined them, so the delegate could spend one
     * base unit to the same vendor under the SAME nonce N. That spend is below the threshold, so
     * it never reads the approval mapping and never clears it; it writes `_usedNonce[N] = true`
     * on the way out. From that block on, the approval sits in storage as authority that can
     * never be exercised, because the only spend it matches carries a nonce already burned.
     *
     * The co-signer saw an approval, the payer saw a spend, and the 50 USDC the human actually
     * agreed to never moved. No party lost funds, which is why it survived four mutation gates and
     * 76/76 model parity — `reference/policy.js` adds the nonce unconditionally too, and the
     * model was where this would have been caught.
     */
    function test_f30_aTinySpendCannotBurnTheNonceUnderALiveApproval() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        // One base unit, same nonce, same recipient: below the threshold, so the old code took
        // no interest in the approval at all.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.NonceReserved.selector, hash));
        mm.spend(id, vendor, 1, REF, nonce);

        // The approval is untouched and the spend the human agreed to still works.
        assertTrue(mm.isCosignApproved(id, hash), "the approval must have survived the attempt");
        vm.prank(agent);
        mm.spend(id, vendor, usd(50), REF, nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    /// The reservation must not block the payment it exists to protect. Approve, then spend that
    /// exact request under that exact nonce, and nothing is in the way.
    function test_f30_theApprovedSpendPassesStraightThrough() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.prank(agent);
        mm.spend(id, vendor, usd(50), REF, nonce);

        assertEq(token.balanceOf(vendor), usd(50));
        assertEq(mm.cosignApprovalDeadline(id, hash), 0, "the approval is consumed");
    }

    /// A nonce with no reservation on it is unaffected — the delegate picks another one and the
    /// small payment goes through. The reservation binds one nonce, not the mandate.
    function test_f30_anUnreservedNonceIsUntouched() public {
        bytes32 id = grant(cosignParams());
        vm.prank(boss);
        mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));

        vm.prank(agent);
        mm.spend(id, vendor, 1, REF, nextNonce());
        assertEq(token.balanceOf(vendor), 1);
    }

    /// Withdrawing frees the nonce. Without this the fix would trade one defect for a worse one:
    /// a co-signer who approved and changed their mind would have burned that nonce for the life
    /// of the mandate, and the delegate would have no way to learn which nonces were safe.
    function test_f30_withdrawingTheApprovalReleasesTheNonce() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        vm.startPrank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        mm.withdrawCosign(id, hash, nonce);
        vm.stopPrank();

        vm.prank(agent);
        mm.spend(id, vendor, 1, REF, nonce);
        assertEq(token.balanceOf(vendor), 1, "the nonce is free again");
    }

    /// A second approval on the same nonce for a different request is refused rather than
    /// accepted with no error, which would orphan the first. The reasoning matches F17: the
    /// co-signer must not be able to create authority that cannot be consumed, and after this
    /// write the first approval's nonce would point somewhere else.
    function test_f30_twoApprovalsOnOneNonce_areRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 first = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        approveReverts(
            id, vendor, usd(60), nonce, abi.encodeWithSelector(MandateManager.NonceReserved.selector, first)
        );

        // Withdraw, then the replacement is accepted — the refusal is a sequencing rule, not a
        // one-approval-per-nonce-forever rule.
        vm.startPrank(boss);
        mm.withdrawCosign(id, first, nonce);
        mm.approveCosignFor(id, vendor, usd(60), REF, nonce, uint40(block.timestamp + DAY));
        vm.stopPrank();

        vm.prank(agent);
        mm.spend(id, vendor, usd(60), REF, nonce);
        assertEq(token.balanceOf(vendor), usd(60));
    }

    /// Re-approving the SAME request under the same nonce is not a collision, so a co-signer
    /// extending a deadline is not forced to withdraw first.
    function test_f30_reApprovingTheSameRequest_isAllowed() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        vm.startPrank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        bytes32 again = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + 2 * DAY));
        vm.stopPrank();

        assertEq(again, hash, "same request, same hash");
        assertEq(mm.cosignApprovalDeadline(id, hash), uint40(block.timestamp + 2 * DAY), "the later deadline won");
    }

    // --------------------------------------- F35: the liveness view tells the truth

    /// An approval against a revoked mandate can never be consumed, and the DELEGATE can produce
    /// that state alone, because `revoke` accepts the spender. The view used to report `true`
    /// anyway: the approval mapping knows nothing about the mandate it belongs to.
    function test_f35_isCosignApproved_isFalseOnceTheMandateIsRevoked() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash), "live before the revocation");

        vm.prank(agent); // the delegate revoking its own authority
        mm.revoke(id);

        assertFalse(mm.isCosignApproved(id, hash), "F35: and unconsumable after it");
        assertEq(mm.cosignApprovalDeadline(id, hash), uint40(block.timestamp + DAY), "the raw slot is unchanged");

        // The view and the payment agree, which is the whole claim.
        vm.prank(agent);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.spend(id, vendor, usd(50), REF, nonce);
    }

    /// The correction to F35, and the reason the view asks `_isPermanentlyDead` and not `isLive`.
    /// Revocation and expiry are permanent, and folding them in was right. A start date that has
    /// not arrived is a wait, and folding that in as well reported every scheduled payment's
    /// approval as unapproved until the mandate opened — the flow F17 went out of its way to keep
    /// legal. The contract has already proved such an approval outlives the wait, because
    /// `approveCosignFor` refuses a deadline at or before `notBefore`.
    ///
    /// The expiry half of that helper cannot be reached through this view at all, which is worth
    /// stating rather than testing: `approveCosignFor` also refuses a deadline past `expiresAt`, so
    /// `block.timestamp < validUntil` already implies the mandate has not expired. The clause stays
    /// because `isLive` needs it, one shared helper is safer than two copies of the rule, and it
    /// keeps its coverage there through the `isLive` boundary tests in Views and Bounds.
    function test_f35_aStartInTheFutureIsAWaitRatherThanADeath() public {
        MandateManager.MandateParams memory p = cosignParams();
        p.notBefore = uint40(block.timestamp + DAY);
        bytes32 id = grant(p);
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + 3 * DAY));

        assertFalse(mm.isLive(id), "the mandate has not opened");
        assertTrue(mm.isCosignApproved(id, hash), "the approval is good anyway, and says so");
        payReverts(id, vendor, usd(50), MandateManager.NotYetValid.selector);

        vm.warp(uint256(p.notBefore));
        assertTrue(mm.isCosignApproved(id, hash), "and it survives the mandate opening");
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50), "the view was telling the truth");
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

        // A spend over the per-tx cap too is refused by that cap, which outranks both.
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
     * auditing their own grant cannot tell the difference. v1's immutability also means a
     * combination left legal now is legal forever at that address; the cost of the rule
     * is one comparison at grant time, paid once per mandate, against a supervision check
     * that never fires and produces no error.
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
        // The horizon is required by the ASSERTION, not just by the second grant below.
        // `Unbounded()` is checked before every `BadConfig()` in `createMandate`, so without
        // it this test would still revert and would still pass a bare `vm.expectRevert()`
        // while proving nothing about the cosign check.
        p = withExpiry(p);

        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("dead-gate"), p);

        // The spends the old test performed are now unperformable, because there is no
        // mandate to spend from. That is asserted by reusing THE SAME SALT with the
        // threshold repaired: if the refused attempt had written any state, this would come
        // back `MandateExists` instead of succeeding, which is a stronger check than reading
        // a zeroed struct and needs no off-chain id derivation — there is no `mandateId`
        // view, the id is keccak over (DOMAIN, chainid, this, payer, salt).
        p.cosignThreshold = usd(9);
        vm.prank(payer);
        bytes32 id = mm.createMandate(bytes32("dead-gate"), p);

        // One base unit of threshold below the cap is all it takes, and the cosign check is
        // alive: the largest spend the mandate permits now demands a signature. This is the
        // same boundary the old test straddled from the wrong side.
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, vendor, usd(10), REF, nonce);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, usd(10), REF, nonce);
    }

    // ============================================================== F17 ===
    /**
     * NEW IN v2 (F17). An approval that no spend could ever consume is refused.
     *
     * v1 and the F15/F16 revision both let a cosigner write an authorisation into storage that
     * was dead on arrival: on a revoked mandate, past its expiry, for a recipient the allowlist
     * never contained, or on a nonce a spend had already consumed. Each one costs the cosigner
     * gas, leaves a slot no account is obliged to clean, and tells them they have authorised a
     * payment that `spend` will refuse every time.
     *
     * TWO THINGS THIS SECTION HAS TO PROVE, and the second is the one that could go wrong.
     *
     * The easy half is that the permanent conditions are refused. The hard half is that the
     * RECOVERABLE ones are not: a guard that rejects an approval a later spend could have used
     * turns the contract's own caution into a payer's unapprovable payment, which for a
     * payments primitive is a liveness failure of the contract's own making. Three conditions
     * look mirrorable and are not — a start date in the future, a rolling window that is
     * currently full, and an ERC-8004 credential that has not been filed yet — and each gets a
     * test below that approves successfully and then proves the approval was usable once the
     * condition cleared. Those three tests are the reason to trust the other nine.
     */

    /// Approve as the cosigner and report the revert data instead of propagating it.
    /// Deliberately shaped like `Base.trySpend`, because the parity claim at the end of this
    /// section is only worth anything if both sides are observed the same way.
    function tryApprove(bytes32 id, address to, uint256 amount, bytes32 nonce, uint40 validUntil)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.prank(boss);
        (ok, err) = address(mm).call(
            abi.encodeCall(MandateManager.approveCosignFor, (id, to, amount, REF, nonce, validUntil))
        );
    }

    /// Expect an approval to be refused with exactly this revert data. Prank before
    /// expectRevert, for the reason `Base.payReverts` documents.
    function approveReverts(bytes32 id, address to, uint256 amount, bytes32 nonce, bytes memory expectedError)
        internal
    {
        uint40 validUntil = uint40(block.timestamp + DAY);
        vm.prank(boss);
        vm.expectRevert(expectedError);
        mm.approveCosignFor(id, to, amount, REF, nonce, validUntil);
    }

    function approveReverts(bytes32 id, address to, uint256 amount, bytes32 nonce, bytes4 selector) internal {
        approveReverts(id, to, amount, nonce, abi.encodeWithSelector(selector));
    }

    /// The parity assertion is stated as narrowly as it is true: one defect at a time.
    /// `spend` and `approveCosignFor` cannot always agree, because the recoverable checks
    /// `approveCosignFor` skips sit BETWEEN the permanent ones it keeps: a request that is both
    /// over `perTxCap` and behind a missing credential gets `CredentialMissing` from one and
    /// `OverPerTxCap` from the other. With a single defect they must agree, and that single
    /// case is also the only one a cosigner could act on.
    function _assertSameRefusal(bytes32 id, address to, uint256 amount, bytes32 nonce, string memory what) internal {
        (bool spendOk, bytes memory spendErr) = trySpend(id, to, amount, nonce);
        (bool approveOk, bytes memory approveErr) = tryApprove(id, to, amount, nonce, uint40(block.timestamp + DAY));

        assertFalse(spendOk, string.concat("spend must refuse: ", what));
        assertFalse(approveOk, string.concat("approveCosignFor must refuse: ", what));
        assertTrue(spendErr.length >= 4, string.concat("spend must revert with a named error: ", what));
        assertTrue(approveErr.length >= 4, string.concat("approve must revert with a named error: ", what));
        assertEq(selectorOf(spendErr), selectorOf(approveErr), string.concat("same error for: ", what));
    }

    // ------------------------------------------- the mandate must be alive

    function test_f17_approvingOnARevokedMandate_isRefused() public {
        bytes32 id = grant(cosignParams());
        vm.prank(payer);
        mm.revoke(id);

        approveReverts(id, vendor, usd(50), nextNonce(), MandateManager.Revoked.selector);
        payReverts(id, vendor, usd(50), MandateManager.Revoked.selector);
    }

    /// This test also pins the guard ORDER. At the instant a mandate expires, any legal
    /// `validUntil` is necessarily past `m.expiresAt` too, so a contract that checked the
    /// deadline first would answer "your deadline is wrong" to someone whose actual problem
    /// is that the mandate is dead. Expiry outranks it, and this assertion is what stops the
    /// two blocks being reordered later for tidiness.
    function test_f17_approvingOnAnExpiredMandate_isRefused() public {
        MandateManager.MandateParams memory p = cosignParams(); // already carries F_EXPIRY
        p.expiresAt = uint40(block.timestamp + DAY);
        bytes32 id = grant(p);

        vm.warp(uint256(p.expiresAt)); // exclusive: dead AT expiresAt
        approveReverts(id, vendor, usd(50), nextNonce(), MandateManager.Expired.selector);
        payReverts(id, vendor, usd(50), MandateManager.Expired.selector);
    }

    // ------------------------------------------- the spend must be legal

    function test_f17_approvingANonAllowlistedRecipient_isRefused() public {
        bytes32 id = grant(withAllowlist(cosignParams(), vendor));

        approveReverts(id, other, usd(50), nextNonce(), MandateManager.RecipientNotAllowed.selector);
        payReverts(id, other, usd(50), MandateManager.RecipientNotAllowed.selector);

        // The allowlisted recipient is unaffected, which is what makes the refusal above a
        // guard rather than a break.
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash), "the allowlisted recipient still approves");
    }

    /// Zero amount reports `ZeroAmount`, NOT `CosignNotRequired`, and the ordering that
    /// produces that is deliberate: nothing is also at-or-below every threshold, so a contract
    /// that checked the threshold first would tell a cosigner "no signature needed" about a
    /// payment of nothing, which would be true and useless at once. `spend` says
    /// `ZeroAmount`, and so does this test.
    function test_f17_approvingAZeroOrOversizeAmountOrZeroRecipient_isRefused() public {
        bytes32 id = grant(cosignParams());

        approveReverts(id, address(0), usd(50), nextNonce(), MandateManager.ZeroRecipient.selector);
        approveReverts(id, vendor, 0, nextNonce(), MandateManager.ZeroAmount.selector);
        approveReverts(
            id, vendor, uint256(type(uint96).max) + 1, nextNonce(), MandateManager.AmountTooLarge.selector
        );
    }

    /// This test mirrors F19, and it is here because of F17's rule rather than as an
    /// afterthought to it. F17's list was derived by partitioning every refusal `spend` can
    /// make into permanent and recoverable and mirroring the permanent ones; `payer` is
    /// assigned once in `createMandate` and never again, so `recipient == m.payer` is exactly
    /// as permanent as a zero recipient and belongs to that partition. Without this guard the
    /// co-signer could pay gas to authorise a spend the contract would refuse forever — the
    /// false assurance F17 exists to prevent, reintroduced by the fix to a different finding.
    ///
    /// The second case pins the ordering against `CosignNotRequired`: one unit is also
    /// at-or-below the threshold, so a contract that consulted the threshold first would answer
    /// "no signature needed" about a payment that can never happen. `spend` settles the
    /// recipient's shape before it looks at any amount, and so does this.
    function test_f19_approvingThePayerAsRecipient_isRefused() public {
        bytes32 id = grant(cosignParams()); // threshold 10

        approveReverts(id, payer, usd(50), nextNonce(), MandateManager.SelfPayment.selector);
        approveReverts(id, payer, 1, nextNonce(), MandateManager.SelfPayment.selector);

        // The spend path agrees too, which is the whole point of the mirror: the same request
        // is refused with the same error whether it arrives as an approval or as a payment.
        payReverts(id, payer, usd(50), MandateManager.SelfPayment.selector);
    }

    /// F29's mirror on the approval path, and the guard the mutation gate found nothing asserting.
    /// `test/Views.t.sol:439-465` pins both selectors, and it pins them through `spend`, so
    /// deleting this line from `approveCosignFor` left all 207 tests passing.
    ///
    /// Both addresses belong in the same partition as the payer: an address cannot stop being
    /// itself, so `spend` refuses an approval naming either one for as long as the mandate
    /// exists. A co-signer able to authorise one would be paying gas for the false assurance
    /// F17 exists to prevent.
    function test_f29_approvingTheContractOrTheTokenAsRecipient_isRefused() public {
        bytes32 id = grant(cosignParams()); // threshold 10, and no allowlist

        approveReverts(id, address(mm), usd(50), nextNonce(), unrecoverable(address(mm)));
        approveReverts(id, address(token), usd(50), nextNonce(), unrecoverable(address(token)));

        // One unit is at or below the threshold, so this case also pins the ordering against
        // `CosignNotRequired`: a contract that consulted the threshold first would answer "no
        // signature needed" about a payment that can never happen.
        approveReverts(id, address(mm), 1, nextNonce(), unrecoverable(address(mm)));

        // The spend path refuses the same two addresses with the same two errors, which is what
        // makes this a mirror of `spend` rather than a rule the approval path invented.
        payReverts(id, address(mm), usd(50), unrecoverable(address(mm)));
        payReverts(id, address(token), usd(50), unrecoverable(address(token)));
    }

    /**
     * F22's mirror, and the one case on this path that must be ACCEPTED rather than refused.
     *
     * The three tests above refuse a recipient; this one requires a recipient to work. A
     * co-signer must be able to authorise a payment to the delegate itself, because a delegate
     * being paid by its own mandate is the ordinary case — an agent buying its own compute, a
     * contractor drawing their own invoice. F17's `_assertSameRefusal` parity cannot see this
     * direction. If the spender were ever folded into the `SelfPayment` guard, both paths would
     * refuse and the parity test would report them in agreement, because parity checks that the
     * two paths answer alike and not that either answers correctly.
     *
     * The approval and the spend share one nonce deliberately. `approveCosignFor` binds the hash,
     * which binds the nonce; only the spend consumes it. So the assertion that the money arrived
     * is also the proof that the approval covered this exact request rather than some other.
     */
    function test_f22_approvingTheSpenderAsRecipient_isAccepted() public {
        bytes32 id = grant(cosignParams()); // threshold 10, no allowlist
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, agent, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash), "the cosigner may approve a payment to the spender");

        payWithNonce(id, agent, usd(50), nonce);
        assertEq(token.balanceOf(agent), usd(50), "the co-signed self-payment actually paid");

        // The payer on the same mandate, so the acceptance above is not the guard being absent.
        approveReverts(id, payer, usd(50), nextNonce(), MandateManager.SelfPayment.selector);
    }

    /// `perTxCap` is fixed at creation and `totalSpent` only grows, so both refusals are
    /// permanent. The second case is the interesting one: the amount fits the lifetime cap in
    /// the abstract and does not fit what is LEFT of it, and since headroom never widens, no
    /// later spend could take it either.
    function test_f17_approvingOverAPermanentCap_isRefused() public {
        bytes32 id = grant(cosignParams()); // perTxCap 100
        approveReverts(id, vendor, uint256(usd(100)) + 1, nextNonce(), MandateManager.OverPerTxCap.selector);
        payReverts(id, vendor, uint256(usd(100)) + 1, MandateManager.OverPerTxCap.selector);

        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.totalCap = usd(100);
        p.flags = F_PER_TX | F_TOTAL;
        p = withCosign(p, boss, usd(10));
        p = withExpiry(p);
        bytes32 id2 = grant(p);

        // Five spends of exactly the threshold need no signature, which is what lets this test
        // consume the lifetime cap without first solving the problem it is trying to pose.
        for (uint256 i = 0; i < 5; ++i) {
            pay(id2, usd(10));
        }
        assertEq(mm.getMandate(id2).totalSpent, usd(50), "half the lifetime cap is gone");

        approveReverts(id2, vendor, usd(60), nextNonce(), MandateManager.OverTotalCap.selector);
        payReverts(id2, vendor, usd(60), MandateManager.OverTotalCap.selector);

        // Exactly the remaining headroom is still approvable, which is what makes the refusal
        // above a headroom reading rather than a blanket refusal on a partly spent mandate.
        // It also pins the boundary: the guard is `totalSpent > totalCap - amount`, so the
        // amount that lands precisely on the cap has to pass.
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id2, vendor, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id2, hash), "the remaining headroom exactly is approvable");
    }

    /**
     * THE UINT96 AUDIT COUNTER, which is the guard the twelve tests above missed.
     *
     * This test exists because `reference/mutation-gate-sol.py` found it. Neutering the ceiling
     * guard at the top of the F17 block left the whole suite green: 177 passed, 0 failed, with
     * the contract no longer refusing an approval whose spend could only ever meet
     * `TotalSpentCeiling`. It was the single survivor out of 21 mutants, and it survived not
     * because the guard is shadowed by a neighbour — the way `BadConfig` hides behind
     * `NotCosigner` in the model — but for the plainer reason that nothing asserted it at all.
     * `Bounds.t.sol` covers the identical guard on the spend path,
     * `contracts/MandateManager.sol:1060`, and that coverage reads, from a distance, like
     * coverage of both while covering only one: the twelve tests above assert eleven guards.
     *
     * Reaching it takes the same two conditions `Bounds.t.sol` documents at length, and the
     * first is a real constraint rather than a fixture convenience: the mandate must have NO
     * lifetime cap, because with `F_TOTAL` set the `OverTotalCap` check one line above refuses
     * first and the ceiling is unreachable. A window cap at `type(uint96).max` supplies the
     * bound the type can express without binding before the counter does. Second, the counter
     * has to be driven to its cliff, which needs a mint — the suite's default funding is about
     * 79 trillion times too small, which is also why this is a bounded-arithmetic guard rather
     * than a policy any payer will meet.
     *
     * `cosignThreshold` is 0 here, so every amount requires a signature, which is legal because
     * the biconditional in `createMandate` is on the cosigner ADDRESS, not the threshold. That
     * choice is what makes the boundary testable one base unit at a time: with a non-zero
     * threshold the passing half of the pair would be refused by `CosignNotRequired` instead,
     * and the test would prove the ordering of two guards rather than the width of the
     * counter.
     */
    function test_f17_approvingPastTheUint96AuditCeiling_isRefused() public {
        uint256 MAX = uint256(type(uint96).max);

        MandateManager.MandateParams memory p = windowOnlyParams(DAY, type(uint96).max, 12);
        p = withCosign(p, boss, 0);
        bytes32 id = grant(p);

        // Drive the counter to MAX - 1. The setup spend needs its own approval, since a
        // threshold of zero requires a signature for every amount, and that approval has to
        // CLEAR the guard under test: at `totalSpent == 0` the ceiling is not in reach, which
        // is the point.
        token.mint(payer, type(uint96).max);
        bytes32 n = nextNonce();
        vm.prank(boss);
        mm.approveCosignFor(id, vendor, MAX - 1, REF, n, uint40(block.timestamp + DAY));
        payWithNonce(id, vendor, MAX - 1, n);
        assertEq(mm.getMandate(id).totalSpent, type(uint96).max - 1, "counter one unit below its ceiling");

        // Two would wrap it. No spend could ever consume this approval — `totalSpent` is
        // monotonic, so the shortfall is permanent — so it is refused rather than stored.
        approveReverts(id, vendor, 2, nextNonce(), MandateManager.TotalSpentCeiling.selector);
        payReverts(id, vendor, 2, MandateManager.TotalSpentCeiling.selector);

        // One fits exactly, and this half is what pins the boundary to the width of the
        // counter: a guard that was off by one, or that refused any partly spent mandate,
        // would also have refused the request above and looked correct doing it.
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, 1, REF, nextNonce(), uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash), "the last base unit the counter can hold is approvable");
    }

    /**
     * NEW IN v2 (F3). THE COUNTER CEILING REACHES THIS FUNCTION TOO, and it is the strongest case
     * F17 has.
     *
     * Every other bound in the block refuses an approval for the AMOUNT it names: the same mandate
     * at a smaller amount would be approvable, so the refusal says "not this much, not yet". A
     * mandate at the spend-count ceiling can consume no spend of any size ever again, because
     * `spendCount` only grows and `spend` refuses the increment, so an approval written against it
     * is unconsumable for its whole life. Without the guard the co-signer pays for a transaction
     * that stores authority nothing can ever exercise, and the delegate is left holding it.
     *
     * `cosignThreshold: 0` for the reason its uint96 twin above gives, and the counter is placed
     * rather than reached for the reason `Base.placeSpendCount` gives.
     */
    function test_f3_approvingOnAMandateAtTheSpendCountCeiling_isRefused() public {
        MandateManager.MandateParams memory p = windowOnlyParams(DAY, type(uint96).max, 12);
        p = withCosign(p, boss, 0);
        bytes32 id = grant(p);

        placeSpendCount(id, type(uint32).max - 1);

        // One short of the ceiling the approval is legal and the spend consumes it. This half pins
        // the refusal below to the width of the counter rather than to any large value of it: a
        // guard off by one, or one refusing a heavily used mandate, would refuse this approval too.
        bytes32 n = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(1), REF, n, uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash), "the last spend the counter can hold is approvable");
        payWithNonce(id, vendor, usd(1), n);
        assertEq(uint256(mm.getMandate(id).spendCount), uint256(type(uint32).max), "the counter is at its ceiling");

        // Past it nothing can be approved, and the amount makes no difference — which is what
        // separates this refusal from every other one in the block.
        approveReverts(id, vendor, 1, nextNonce(), MandateManager.SpendCountCeiling.selector);
        approveReverts(id, vendor, usd(1000), nextNonce(), MandateManager.SpendCountCeiling.selector);
        payReverts(id, vendor, 1, MandateManager.SpendCountCeiling.selector);

        // The answer comes from the counter and not from its neighbour in the same word: one USDC
        // has moved, so the lifetime ceiling still has 2^96 - 1e6 - 1 of room.
        assertEq(uint256(mm.getMandate(id).totalSpent), uint256(usd(1)), "totalSpent is far from its own ceiling");
    }

    /// `_usedNonce` is write-once-true, so a consumed nonce can only ever produce
    /// `NonceAlreadyUsed`. This is the condition the earlier revision was least likely to have
    /// been reasoned about, because the nonce is the one argument a cosigner has no opinion
    /// about: the agent supplies it, and an agent that supplies a spent one gets a signature
    /// for a payment that cannot happen.
    function test_f17_approvingAConsumedNonce_isRefused() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        payWithNonce(id, vendor, usd(5), nonce); // under the threshold, so no signature needed

        approveReverts(id, vendor, usd(50), nonce, MandateManager.NonceAlreadyUsed.selector);
        (bool ok, bytes memory err) = trySpend(id, vendor, usd(50), nonce);
        assertFalse(ok);
        assertRevertedWith(err, MandateManager.NonceAlreadyUsed.selector, "spend agrees");
    }

    // ------------------------------- the spend must NEED a co-signature

    /// This is the one refusal in F17 that is not about consumability. At or below the
    /// threshold the approval is never CONSULTED — `spend` reads the mapping only when
    /// `amount > cosignThreshold` — so the payment goes through with or without it. It is
    /// refused because of what it would let the cosigner believe: that their approval had
    /// restricted a payment.
    function test_f17_approvingAtOrBelowTheThreshold_isRefused() public {
        bytes32 id = grant(cosignParams()); // threshold 10
        uint40 validUntil = uint40(block.timestamp + DAY);
        bytes32 n1 = nextNonce();
        bytes32 n2 = nextNonce();
        bytes32 n3 = nextNonce();

        // Exactly at the threshold. `spend` uses a strict `>`, so 10 needs no signature, and
        // `test_atTheThreshold_noSignatureRequired` at the top of this file proves it does not.
        vm.prank(boss);
        vm.expectRevert(
            abi.encodeWithSelector(MandateManager.CosignNotRequired.selector, uint256(usd(10)), usd(10))
        );
        mm.approveCosignFor(id, vendor, usd(10), REF, n1, validUntil);

        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignNotRequired.selector, uint256(usd(1)), usd(10)));
        mm.approveCosignFor(id, vendor, usd(1), REF, n2, validUntil);

        // One unit above is approvable, so the two functions read the same boundary the same
        // way. The error carries both numbers so the cosigner is told which side they landed
        // on rather than having to fetch the threshold to find out.
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, uint256(usd(10)) + 1, REF, n3, validUntil);
        assertTrue(mm.isCosignApproved(id, hash), "one unit above the threshold is approvable");
    }

    // ------------------------- the deadline, measured against the mandate

    /// F16 bounded `validUntil` against the clock. F17 bounds it against the mandate, in both
    /// directions, and both bounds refuse rather than clamp for F16's reason: a deadline the
    /// contract moved without reverting is a deadline the cosigner did not agree to.
    function test_f17_theDeadlineMustOutliveNotBeforeAndDieByTheExpiry() public {
        // (a) An approval whose whole life sits inside the mandate's not-yet-valid window.
        MandateManager.MandateParams memory p = cosignParams();
        p.notBefore = uint40(block.timestamp + 2 * DAY);
        bytes32 id = grant(p);

        // Nonces hoisted for legibility only. Calling `nextNonce()` inside the argument list
        // of a pranked, expect-reverted call is already the pattern used by
        // `test_deadlineInThePast_isRefused` above and is safe — it is an internal call, so it
        // consumes neither cheatcode. Named here because this test has five of them and the
        // reader should be able to see at a glance that each attempt uses a fresh one.
        bytes32 nA = nextNonce();
        bytes32 nB = nextNonce();
        bytes32 nC = nextNonce();

        uint40 tooEarly = uint40(block.timestamp + DAY);
        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, tooEarly));
        mm.approveCosignFor(id, vendor, usd(50), REF, nA, tooEarly);

        // Exactly AT notBefore is refused too. `validUntil` is exclusive and `notBefore` is
        // inclusive, so an approval ending at T and a mandate starting at T share no instant.
        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, p.notBefore));
        mm.approveCosignFor(id, vendor, usd(50), REF, nB, p.notBefore);

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nC, p.notBefore + 1);
        assertTrue(mm.isCosignApproved(id, hash), "one second of overlap is enough");

        // (b) An approval that would outlive the mandate. The tail past `expiresAt` is
        // authority that cannot be exercised, and showing a cosigner a month of it on a
        // mandate with a day to live is the misrepresentation F15 exists to end.
        MandateManager.MandateParams memory q = cosignParams();
        q.expiresAt = uint40(block.timestamp + DAY);
        bytes32 id2 = grant(q);

        bytes32 nD = nextNonce();
        bytes32 nE = nextNonce();

        uint40 tooLate = q.expiresAt + 1;
        vm.prank(boss);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.BadDeadline.selector, tooLate));
        mm.approveCosignFor(id2, vendor, usd(50), REF, nD, tooLate);

        // Exactly AT expiresAt is accepted, and that is the correct boundary rather than an
        // off-by-one: both values are exclusive, so an approval dying at T grants nothing on a
        // mandate that is also dead at T.
        vm.prank(boss);
        bytes32 hash2 = mm.approveCosignFor(id2, vendor, usd(50), REF, nE, q.expiresAt);
        assertEq(mm.cosignApprovalDeadline(id2, hash2), q.expiresAt, "a deadline at the expiry is legal");
    }

    // --------------- WHAT F17 MUST NOT REFUSE: the recoverable conditions

    /// A start date in the future is not a permanent refusal, so approving ahead of it stays
    /// legal. Approving early is also the normal case for a scheduled payment: the cosigner is
    /// available now and the mandate opens later.
    function test_f17_approvingBeforeTheMandateStarts_isAllowed() public {
        MandateManager.MandateParams memory p = cosignParams();
        p.notBefore = uint40(block.timestamp + DAY);
        bytes32 id = grant(p);
        bytes32 nonce = nextNonce();

        payReverts(id, vendor, usd(50), MandateManager.NotYetValid.selector);

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + 3 * DAY));
        assertTrue(mm.isCosignApproved(id, hash), "an approval ahead of the start is legal");

        vm.warp(uint256(p.notBefore));
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50), "and it was genuinely usable once time passed");
    }

    /// A full rolling window is the sharpest of the three, because the window arithmetic is
    /// the most tempting to mirror and the least safe to mirror: used totals FALL as buckets
    /// age out, so an amount refused now fits later with nothing else changing.
    function test_f17_approvingWhileAWindowIsFull_isAllowed() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.flags = F_PER_TX;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(50), buckets: 12});
        p = withCosign(p, boss, usd(10));
        p = withExpiry(p);
        bytes32 id = grant(p);

        // Align to a bucket boundary so the five spends share one bucket and age out together.
        uint64 t0 = uint64(((block.timestamp / (DAY / 12)) + 1) * (DAY / 12));
        vm.warp(t0);
        for (uint256 i = 0; i < 5; ++i) {
            pay(id, usd(10)); // at the threshold, so unsigned
        }
        payReverts(id, vendor, usd(50), overWindowCap(DAY, usd(50), usd(50)));

        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(t0 + 3 * uint256(DAY)));
        assertTrue(mm.isCosignApproved(id, hash), "a full window must not block an approval");

        vm.warp(uint256(t0) + DAY + DAY / 12); // the bucket ages out
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(100), "and the approval survived to be used");
    }

    /// An ERC-8004 credential that has not been filed yet is recoverable by a third party the
    /// cosigner does not control, which is precisely why refusing here would be wrong: the
    /// approval would have to be re-obtained for a condition that fixed itself.
    function test_f17_approvingWhileACredentialIsMissing_isAllowed() public {
        bytes32 request = bytes32("f17-not-attested-yet");
        bytes32 id = grant(withCredential(cosignParams(), boss, request, AGENT_ID, 1 days));
        bytes32 nonce = nextNonce();

        payReverts(id, vendor, usd(50), MandateManager.CredentialMissing.selector);

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + 3 * DAY));
        assertTrue(mm.isCosignApproved(id, hash), "a missing credential must not block an approval");

        validation.setStatus(request, boss, AGENT_ID, 100, block.timestamp);
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50), "and the approval was still there when it passed");
    }

    // ------------------------------------------------ the parity itself

    function test_f17_singleDefectRefusalsMatchSpend() public {
        bytes32 plain = grant(cosignParams());
        bytes32 gated = grant(withAllowlist(cosignParams(), vendor));

        bytes32 consumed = nextNonce();
        payWithNonce(plain, vendor, usd(5), consumed); // under the threshold, so unsigned

        _assertSameRefusal(plain, address(0), usd(50), nextNonce(), "zero recipient");
        _assertSameRefusal(gated, other, usd(50), nextNonce(), "recipient not allowlisted");
        _assertSameRefusal(plain, vendor, 0, nextNonce(), "zero amount");
        _assertSameRefusal(plain, vendor, uint256(type(uint96).max) + 1, nextNonce(), "amount above uint96");
        _assertSameRefusal(plain, vendor, uint256(usd(100)) + 1, nextNonce(), "over perTxCap");
        _assertSameRefusal(plain, vendor, usd(50), consumed, "nonce already consumed");
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
