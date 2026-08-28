// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The scalar bounds: per-transaction cap, lifetime cap, recipient allowlist,
 * spender identity, validity period, revocation.
 *
 * These are the parts a reader assumes are trivially correct, which is exactly why
 * they are tested at the boundary and one base unit past it. A cap that is off by
 * one in the permissive direction is not a rounding error, it is an unbounded
 * authority with a plausible-looking number attached.
 */
contract BoundsTest is Base {
    // -------------------------------------------------------- happy path

    function test_spend_movesMoneyAndRecordsIt() public {
        bytes32 id = grant(simpleParams());
        uint256 payerBefore = token.balanceOf(payer);

        bytes32 nonce = bytes32("n1");
        bytes32 expectedHash = mm.spendHash(id, vendor, usd(40), REF, nonce);

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.Spend(id, agent, vendor, usd(40), REF, nonce, expectedHash, usd(40));

        vm.prank(agent);
        bytes32 hash = mm.spend(id, vendor, usd(40), REF, nonce);

        assertEq(hash, expectedHash, "returned hash must match the view");
        assertEq(token.balanceOf(vendor), usd(40), "vendor received");
        assertEq(token.balanceOf(payer), payerBefore - usd(40), "payer debited");
        assertEq(token.balanceOf(address(mm)), 0, "the contract must never hold funds");

        MandateManager.Mandate memory m = mm.getMandate(id);
        assertEq(m.totalSpent, usd(40), "totalSpent");
        assertEq(m.spendCount, 1, "spendCount");
        assertTrue(mm.isNonceUsed(id, nonce), "nonce consumed");
    }

    /// Funds move payer -> recipient directly. There is no custody step, so there is
    /// no balance for a bug in this contract to strand or steal.
    function test_spend_neverCustodiesFunds() public {
        bytes32 id = grant(simpleParams());
        pay(id, usd(10));
        pay(id, usd(10));
        assertEq(token.balanceOf(address(mm)), 0);
        assertEq(token.balanceOf(vendor), usd(20));
    }

    function test_spend_unknownMandate_reverts() public {
        payReverts(bytes32("nope"), usd(1), MandateManager.UnknownMandate.selector);
    }

    // ------------------------------------------------------- per-tx cap

    /// The cap is INCLUSIVE. Spending exactly the cap is the normal case, not an
    /// edge case, and a strict comparison here would silently make every mandate
    /// one base unit smaller than the payer wrote down.
    function test_perTxCap_isInclusiveAtTheCap() public {
        bytes32 id = grant(simpleParams());
        pay(id, usd(100));
        assertEq(token.balanceOf(vendor), usd(100));
    }

    function test_perTxCap_oneUnitOver_reverts() public {
        bytes32 id = grant(simpleParams());
        payReverts(id, uint256(usd(100)) + 1, MandateManager.OverPerTxCap.selector);
        assertEq(token.balanceOf(vendor), 0, "a denied spend must move nothing");
    }

    /// The per-tx cap bounds each transaction, not the total. Three spends at the
    /// cap are fine as long as the rolling window has room.
    function test_perTxCap_doesNotBoundTheTotal() public {
        bytes32 id = grant(simpleParams());
        pay(id, usd(100));
        pay(id, usd(100));
        pay(id, usd(100));
        assertEq(mm.getMandate(id).totalSpent, usd(300));
    }

    // -------------------------------------------------------- total cap

    function test_totalCap_exactFitThenRefusal() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.totalCap = usd(250);
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);

        pay(id, usd(100));
        pay(id, usd(100));
        pay(id, usd(50)); // exactly to the cap
        assertEq(mm.getMandate(id).totalSpent, usd(250));

        payReverts(id, 1, MandateManager.OverTotalCap.selector);
    }

    /// A lifetime cap does not heal. Unlike a window it has no aging term, so time
    /// passing must not restore headroom.
    function test_totalCap_doesNotRecoverWithTime() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.totalCap = usd(100);
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);

        pay(id, usd(100));
        vm.warp(block.timestamp + 365 days);
        payReverts(id, 1, MandateManager.OverTotalCap.selector);
    }

    /**
     * FIXED IN v2. The test is kept, re-pointed at the new behaviour, because the
     * boundary is still worth pinning even though it no longer panics.
     *
     * v1 computed `newTotal = m.totalSpent + uint96(amount)` BEFORE consulting the
     * F_TOTAL flag, so the addition was evaluated even for a mandate with no lifetime
     * cap at all, and a cumulative total near 2^96 base units produced an arithmetic
     * PANIC rather than a denial. That is about 7.9e22 USDC — unreachable in the
     * world, but reachable in two transactions right here, which is precisely why it
     * was pinned rather than waved away.
     *
     * v2 checks the lifetime cap without performing the addition, then guards the
     * counter with a named error. Three things deliberately did NOT change: the
     * counter is still exact (not saturated — `totalSpent` rides in the Spend event,
     * and a counter that quietly stops counting understates real flow), it still
     * advances for mandates without F_TOTAL, and the mandate still becomes unusable
     * at the ceiling, which is inherent to a bounded counter. What changed is that it
     * now says why.
     *
     * Note for anyone reading the old comment in git history: it predicted this test
     * would start failing with `OverTotalCap`. It does not, and could not — this
     * mandate has no F_TOTAL flag, so the cap is not what binds. Getting
     * `OverTotalCap` here would mean the contract had invented a cap nobody granted.
     */
    function test_totalSpent_atTheUint96Ceiling_deniesWithANameNotAPanic() public {
        // A window cap at the maximum, which is the loosest bound the type can express.
        // Note carefully what that does and does not achieve: it does NOT stop the window
        // from binding, because 1 + (2^96 - 1) exceeds 2^96 - 1 as surely as it exceeds any
        // smaller cap. Two bounds are violated by this request, and what decides which
        // error comes back is the ORDER of the checks — the ceiling guard sits with the
        // amount narrowing, above `_checkAndCommitWindows`. That order is deliberate and
        // inherited from v1, where the counter arithmetic was in the same place, so the fix
        // moved no policy check relative to any other. The maximum cap is here to make the
        // window the *last* thing that could bind rather than the first, so a regression
        // that reordered them would show up as `OverWindowCap` instead of a passing test.
        bytes32 id = grant(windowOnlyParams(DAY, type(uint96).max, 12));

        pay(id, 1); // totalSpent = 1
        assertEq(mm.getMandate(id).totalSpent, 1);

        // 1 + (2^96 - 1) would wrap the counter.
        payReverts(id, uint256(type(uint96).max), MandateManager.TotalSpentCeiling.selector);

        // And one base unit less fits exactly, which is what proves the boundary is the
        // width of the counter rather than an off-by-one in something cheaper. The
        // reverting half alone cannot prove that: a guard at 2^96 - 2 would also refuse
        // the request above.
        //
        // This needs a mint, and the size of that mint is the point. Base.t.sol funds the
        // payer with 1e9 USDC — 1e15 base units — which is generous for every other test
        // in the suite and about 79 trillion times too small to reach here. So the token
        // balance, not the counter, is what binds at default funding, and the ceiling is
        // unreachable in the tests for the same reason it is unreachable in the world.
        // The JS model has no token and asserts this boundary without ceremony; that
        // difference between the two suites is worth seeing rather than papering over.
        token.mint(payer, type(uint96).max);
        pay(id, uint256(type(uint96).max) - 1);
        assertEq(mm.getMandate(id).totalSpent, type(uint96).max, "counter should sit exactly at its ceiling");

        // At the ceiling the mandate is spent out, and the smallest possible request is
        // now refused by the same guard — a bounded counter's cliff is inherent, and what
        // v2 changed is only that it arrives with a name.
        payReverts(id, 1, MandateManager.TotalSpentCeiling.selector);
    }

    /**
     * The other half of that claim: the ceiling guard is UNREACHABLE once F_TOTAL is
     * set, because a lifetime cap is itself a uint96 and so binds first. Pinned so the
     * two denials on the same counter cannot be confused, at the largest cap the type
     * can express — the one case where they come closest to coinciding.
     */
    function test_totalSpent_withMaximumLifetimeCap_deniesWithOverTotalCap() public {
        MandateManager.MandateParams memory p = windowOnlyParams(DAY, type(uint96).max, 12);
        p.totalCap = type(uint96).max;
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);

        pay(id, 1);
        payReverts(id, uint256(type(uint96).max), MandateManager.OverTotalCap.selector);
    }

    /// The uint96 ceiling is enforced explicitly, and BEFORE the caps, so an
    /// absurd amount produces a legible error rather than a cast that silently
    /// truncates a huge number into a small permitted one.
    function test_amountAboveUint96_reverts_beforeTheCapIsConsulted() public {
        bytes32 id = grant(simpleParams()); // perTxCap = 100
        uint256 tooBig = uint256(type(uint96).max) + 1;
        // Note this is NOT OverPerTxCap, even though it is also over the per-tx cap.
        payReverts(id, tooBig, MandateManager.AmountTooLarge.selector);
    }

    // -------------------------------------------------------- allowlist

    function test_allowlist_permitsNamedRecipientOnly() public {
        bytes32 id = grant(withAllowlist(simpleParams(), vendor));

        payTo(id, vendor, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));

        payReverts(id, other, usd(10), MandateManager.RecipientNotAllowed.selector);
        assertEq(token.balanceOf(other), 0);
    }

    /// Addresses are compared as 20-byte values, so there is no checksum-casing
    /// hazard on chain — the equivalent JS test exists only because JavaScript
    /// compares strings. Pinned here so the two suites stay legibly parallel.
    function test_allowlist_isAddressValuedNotStringValued() public {
        bytes32 id = grant(withAllowlist(simpleParams(), vendor));
        assertTrue(mm.isAllowedRecipient(id, vendor));
        assertFalse(mm.isAllowedRecipient(id, other));
    }

    function test_allowlist_multipleRecipients() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.allowlist = new address[](2);
        p.allowlist[0] = vendor;
        p.allowlist[1] = boss;
        p.flags |= F_ALLOWLIST;
        bytes32 id = grant(p);

        payTo(id, vendor, usd(5));
        payTo(id, boss, usd(5));
        payReverts(id, other, usd(5), MandateManager.RecipientNotAllowed.selector);
    }

    /// With no allowlist, any non-zero recipient is fine — but the zero address is
    /// still refused, because Arc's USDC reverts on a transfer to it and a spend
    /// that consumes gas to fail at the token layer is worse than one denied up front.
    function test_zeroRecipient_reverts_evenWithNoAllowlist() public {
        bytes32 id = grant(simpleParams());
        payReverts(id, address(0), usd(10), MandateManager.ZeroRecipient.selector);
    }

    function test_zeroAmount_reverts() public {
        bytes32 id = grant(simpleParams());
        payReverts(id, vendor, 0, MandateManager.ZeroAmount.selector);
    }

    // ---------------------------------------------------------- spender

    /// A mandate names exactly one spender. This is what makes the grant a delegation
    /// rather than a public faucet: knowing the mandateId is not authority.
    function test_wrongSpender_reverts() public {
        bytes32 id = grant(simpleParams());

        bytes32 nonce = nextNonce();
        vm.prank(other);
        vm.expectRevert(MandateManager.WrongSpender.selector);
        mm.spend(id, vendor, usd(10), REF, nonce);

        // Not even the payer may spend their own mandate — the mandate describes
        // the delegate's authority, and the payer already has their own funds.
        vm.prank(payer);
        vm.expectRevert(MandateManager.WrongSpender.selector);
        mm.spend(id, vendor, usd(10), REF, nonce);
    }

    // --------------------------------------------------- validity period

    function test_notBefore_isInclusive() public {
        uint40 start = uint40(block.timestamp + 1000);
        MandateManager.MandateParams memory p = simpleParams();
        p.notBefore = start;
        bytes32 id = grant(p);

        payReverts(id, usd(10), MandateManager.NotYetValid.selector);
        assertFalse(mm.isLive(id), "not live before notBefore");

        vm.warp(start - 1);
        payReverts(id, usd(10), MandateManager.NotYetValid.selector);

        vm.warp(start); // the first permitted second
        assertTrue(mm.isLive(id));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /**
     * Expiry is EXCLUSIVE: valid at expiresAt - 1, dead at expiresAt.
     *
     * Arc block timestamps are non-decreasing but not strictly increasing — several
     * sub-second blocks share one timestamp — so an inclusive bound would make the
     * final second of a mandate's life mean "some unpredictable number of extra
     * spends". Exclusive makes the closing instant unambiguous.
     */
    function test_expiry_isExclusive() public {
        uint40 end = uint40(block.timestamp + 1000);
        MandateManager.MandateParams memory p = simpleParams();
        p.expiresAt = end;
        p.flags |= F_EXPIRY;
        bytes32 id = grant(p);

        vm.warp(end - 1);
        assertTrue(mm.isLive(id), "live on the last second");
        pay(id, usd(10));

        vm.warp(end);
        assertFalse(mm.isLive(id), "dead at expiresAt, not after it");
        payReverts(id, usd(10), MandateManager.Expired.selector);

        vm.warp(end + 10_000);
        payReverts(id, usd(10), MandateManager.Expired.selector);
    }

    // -------------------------------------------------------- revocation

    function test_revoke_byPayer_stopsEverything() public {
        bytes32 id = grant(simpleParams());
        pay(id, usd(10));

        vm.expectEmit(true, true, false, true, address(mm));
        emit MandateManager.MandateRevoked(id, payer);
        vm.prank(payer);
        mm.revoke(id);

        assertTrue(mm.getMandate(id).revoked);
        assertFalse(mm.isLive(id));
        assertEq(mm.policyHeadroom(id), 0, "a revoked mandate has no headroom");
        payReverts(id, usd(10), MandateManager.Revoked.selector);
    }

    /**
     * The spender may revoke as well as the payer, asserted against the CONTRACT.
     *
     * An agent that detects it has been compromised should be able to hand back its
     * own authority without waiting for a human, and doing so can only ever reduce its
     * own power, so there is nothing here to abuse.
     *
     * This comment used to open "KNOWN DIVERGENCE from reference/policy.js" and close
     * "the model is the one that needs updating". Both halves are stale: `revoke` in
     * policy.js accepts the payer or the spender, so the two sides agree and a failure
     * here is a real regression rather than a recorded gap. The third sentence is
     * stale too — v2 renamed the error, because two roles hold the authority and
     * naming it after one of them was the misleading part.
     */
    function test_revoke_bySpender_isAlsoPermitted() public {
        bytes32 id = grant(simpleParams());
        vm.prank(agent);
        mm.revoke(id);
        assertTrue(mm.getMandate(id).revoked, "the delegate may surrender its own authority");
    }

    function test_revoke_byStranger_reverts() public {
        bytes32 id = grant(simpleParams());
        vm.prank(other);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(id);
        assertFalse(mm.getMandate(id).revoked);
    }

    function test_revoke_unknownMandate_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.revoke(bytes32("nope"));
    }

    function test_revoke_isIdempotent() public {
        bytes32 id = grant(simpleParams());
        vm.startPrank(payer);
        mm.revoke(id);
        mm.revoke(id); // must not revert; revocation is a latch, not a toggle
        vm.stopPrank();
        assertTrue(mm.getMandate(id).revoked);
    }

    /// Revocation is checked second, immediately after existence, so it outranks
    /// every other condition including a co-signature that was already granted.
    /// "I have revoked" must never lose to "but it was approved".
    function test_revoke_outranksAValidCosignature() public {
        MandateManager.MandateParams memory p = withCosign(simpleParams(), boss, usd(10));
        bytes32 id = grant(p);

        bytes32 nonce = bytes32("n-cosigned");
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));
        assertTrue(mm.isCosignApproved(id, hash));

        vm.prank(payer);
        mm.revoke(id);

        vm.prank(agent);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.spend(id, vendor, usd(50), REF, nonce);
    }

    /// Revocation kills the mandate, not the allowance. The payer's ERC-20 approval
    /// to this contract survives and would authorise a NEW mandate — so revoking is
    /// necessary but not sufficient to fully disarm, and the README says so.
    function test_revoke_doesNotTouchTheUnderlyingAllowance() public {
        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        mm.revoke(id);
        assertEq(token.allowance(payer, address(mm)), type(uint256).max, "allowance is the payer's to manage");
        assertEq(mm.spendable(id), 0, "but this mandate can no longer reach it");
    }
}
