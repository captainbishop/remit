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
        bytes32 hash = mm.spendHash(id, agent, vendor, uint256(usd(10)) + 1, REF, nonce);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, uint256(usd(10)) + 1, REF, nonce);
    }

    /// The error carries the hash the cosigner needs to approve, so the agent can
    /// hand a human exactly one thing to sign without reconstructing the encoding.
    function test_cosignRequired_carriesTheHashToApprove() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();

        (bool ok, bytes memory err) = trySpend(id, vendor, usd(50), nonce);
        assertFalse(ok);
        assertRevertedWith(err, MandateManager.CosignRequired.selector, "expected CosignRequired");

        bytes32 reported = abi.decode(sliceArgs(err), (bytes32));
        assertEq(reported, mm.spendHash(id, agent, vendor, usd(50), REF, nonce), "hash in the error is usable");

        vm.prank(boss);
        mm.approveCosign(id, reported);
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    function test_withApproval_theSpendGoesThrough() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.CosignApproved(id, hash, boss);
        vm.prank(boss);
        mm.approveCosign(id, hash);

        assertTrue(mm.isCosignApproved(id, hash));
        payWithNonce(id, vendor, usd(50), nonce);
        assertEq(token.balanceOf(vendor), usd(50));
    }

    /// One signature authorises one spend. The approval is deleted on use, so it
    /// cannot accumulate into standing permission for a repeated payment.
    function test_approval_isConsumedByTheSpend() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);

        vm.prank(boss);
        mm.approveCosign(id, hash);
        payWithNonce(id, vendor, usd(50), nonce);

        assertFalse(mm.isCosignApproved(id, hash), "approval must not survive its use");
    }

    /**
     * An approval must survive a spend that failed for an unrelated reason.
     *
     * If a transient window breach burned the signature, every retry would need the
     * human again — which in practice means the human starts pre-approving in bulk,
     * and the control stops meaning anything. The approval is deleted only on the
     * path where the spend actually succeeds, and a revert unwinds the delete anyway.
     */
    function test_approval_survivesAnUnrelatedFailure() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.flags = F_PER_TX;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(100), buckets: 12});
        p = withCosign(p, boss, usd(25));
        bytes32 id = grant(p);

        uint64 t0 = uint64(((block.timestamp / (DAY / 12)) + 1) * (DAY / 12));
        vm.warp(t0);

        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(90), REF, nonce);
        vm.prank(boss);
        mm.approveCosign(id, hash);

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
        bytes32 approved = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);

        vm.prank(boss);
        mm.approveCosign(id, approved);

        bytes32 redirected = mm.spendHash(id, agent, other, usd(50), REF, nonce);
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

        // Both hashes are computed BEFORE the pranks. `vm.prank` applies to the next
        // call, and an `mm.spendHash(...)` sitting in an argument list is that call —
        // it would consume the prank and leave `approveCosign` arriving from the test
        // contract, which is not the cosigner. Same hazard `Base.payReverts` exists
        // to contain.
        bytes32 approved = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);
        bytes32 inflated = mm.spendHash(id, agent, vendor, usd(90), REF, nonce);

        vm.prank(boss);
        mm.approveCosign(id, approved);

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
        bytes32 approved = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);
        bytes32 swapped = mm.spendHash(id, agent, vendor, usd(50), otherRef, nonce);
        assertTrue(approved != swapped, "the reference must be inside the hash");

        vm.prank(boss);
        mm.approveCosign(id, approved);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, swapped));
        mm.spend(id, vendor, usd(50), otherRef, nonce);
    }

    /// The hash is bound to this chain and this contract address, so an approval
    /// harvested from a testnet deployment cannot be replayed against mainnet.
    function test_spendHash_isBoundToChainAndContract() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = bytes32("n");
        assertEq(
            mm.spendHash(id, agent, vendor, usd(50), REF, nonce),
            keccak256(
                abi.encode(
                    mm.DOMAIN(), block.chainid, address(mm), id, agent, vendor, uint256(usd(50)), REF, nonce
                )
            )
        );
    }

    // ------------------------------------------------------ who may approve

    function test_onlyTheNamedCosignerMayApprove() public {
        bytes32 id = grant(cosignParams());
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(50), REF, bytes32("n"));

        vm.prank(agent); // the agent cannot approve its own spend
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosign(id, hash);

        // Nor can the payer, without being named as the cosigner. If the payer wants
        // that power they name themselves at grant time — silently accepting it here
        // would make the cosigner field advisory.
        vm.prank(payer);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosign(id, hash);
    }

    function test_approveCosign_onAMandateWithoutCosigning_reverts() public {
        bytes32 id = grant(simpleParams());
        vm.prank(boss);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.approveCosign(id, bytes32("h"));
    }

    function test_approveCosign_onUnknownMandate_reverts() public {
        vm.prank(boss);
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.approveCosign(bytes32("nope"), bytes32("h"));
    }

    /// A cosigner who changes their mind before the agent acts can withdraw. Without
    /// this, approving is irreversible and a cosigner would rationally never approve
    /// early.
    function test_withdrawCosign_revokesAnUnusedApproval() public {
        bytes32 id = grant(cosignParams());
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(50), REF, nonce);

        vm.startPrank(boss);
        mm.approveCosign(id, hash);
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
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(50), REF, bytes32("n"));
        vm.prank(boss);
        mm.approveCosign(id, hash);

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
        bytes32 hash = mm.spendHash(id, agent, vendor, usd(10), REF, nonce);
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
