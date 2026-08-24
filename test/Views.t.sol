// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The pre-flight views.
 *
 * These exist so an agent can decide what to do BEFORE spending gas on a call that
 * would be refused. That makes them part of the interface, not a convenience: an
 * agent that trusts `spendable` and then gets reverted has been lied to, and an agent
 * that is told 0 when it could actually spend will escalate to a human for nothing.
 * Both failure directions are tested.
 */
contract ViewsTest is Base {
    // ------------------------------------------------------------- isLive

    function test_isLive_tracksEveryLifecycleCondition() public {
        assertFalse(mm.isLive(bytes32("nope")), "unknown mandate is not live");

        uint40 start = uint40(block.timestamp + 100);
        uint40 end = uint40(block.timestamp + 200);
        MandateManager.MandateParams memory p = simpleParams();
        p.notBefore = start;
        p.expiresAt = end;
        p.flags |= F_EXPIRY;
        bytes32 id = grant(p);

        assertFalse(mm.isLive(id), "before notBefore");
        vm.warp(start);
        assertTrue(mm.isLive(id), "at notBefore");
        vm.warp(end - 1);
        assertTrue(mm.isLive(id), "last valid second");
        vm.warp(end);
        assertFalse(mm.isLive(id), "expiry is exclusive");

        vm.warp(start);
        assertTrue(mm.isLive(id));
        vm.prank(payer);
        mm.revoke(id);
        assertFalse(mm.isLive(id), "revoked");
    }

    // ------------------------------------------------------ policyHeadroom

    /// The headroom is the minimum across every active bound, and it must track
    /// which one is currently binding rather than reporting a favourite.
    function test_policyHeadroom_reportsTheBindingConstraint() public {
        MandateManager.MandateParams memory p = simpleParams(); // perTx 100, daily 500
        p.totalCap = usd(150);
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);

        // Fresh: the per-tx cap is smallest.
        assertEq(mm.policyHeadroom(id), usd(100), "per-tx binds first");

        pay(id, usd(100));
        // 50 of the lifetime cap remains, which is now the smallest.
        assertEq(mm.policyHeadroom(id), usd(50), "total cap now binds");

        pay(id, usd(50));
        assertEq(mm.policyHeadroom(id), 0, "lifetime cap exhausted");
    }

    function test_policyHeadroom_windowCanBeTheBindingConstraint() public {
        bytes32 id = grant(simpleParams()); // perTx 100, daily 500
        uint64 t0 = uint64(((block.timestamp / (DAY / 12)) + 1) * (DAY / 12));
        vm.warp(t0);

        for (uint256 i = 0; i < 4; ++i) {
            pay(id, usd(100));
        }
        // 400 of 500 used, so 100 of window left — equal to the per-tx cap.
        assertEq(mm.policyHeadroom(id), usd(100));

        pay(id, usd(60));
        assertEq(mm.policyHeadroom(id), usd(40), "the window is now tighter than per-tx");
    }

    /**
     * A mandate bounded only by expiry genuinely has no amount limit, so the honest
     * answer is "unlimited" rather than zero.
     *
     * Returning 0 here would be the more defensive-looking choice and it would be
     * wrong: a pre-flighting agent would conclude it cannot spend at all, and a payer
     * who deliberately granted a time-boxed unlimited mandate would find it inert.
     * `spendable` is where this gets clamped to a real number.
     */
    function test_policyHeadroom_expiryOnlyMandateIsUnlimited() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_EXPIRY;
        bytes32 id = grant(p);

        assertEq(mm.policyHeadroom(id), type(uint256).max, "no amount bound means no amount bound");
        assertEq(mm.spendable(id), token.balanceOf(payer), "clamped to what actually exists");
    }

    function test_policyHeadroom_isZeroWhenNotSpendable() public {
        assertEq(mm.policyHeadroom(bytes32("nope")), 0, "unknown");

        MandateManager.MandateParams memory p = simpleParams();
        p.notBefore = uint40(block.timestamp + 100);
        bytes32 early = grant(p);
        assertEq(mm.policyHeadroom(early), 0, "not yet valid");

        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        mm.revoke(id);
        assertEq(mm.policyHeadroom(id), 0, "revoked");
    }

    // ----------------------------------------------------------- spendable

    /**
     * `spendable` is the number an agent should actually build a transaction around:
     * the policy limit intersected with the payer's allowance and balance.
     *
     * The allowance is the reason this view is not redundant. A payer can throttle or
     * disarm a mandate entirely by touching only the ERC-20 approval, without ever
     * calling this contract — so a healthy-looking mandate can be worth nothing, and
     * only this view can tell.
     */
    function test_spendable_clampsToTheAllowance() public {
        bytes32 id = grant(simpleParams()); // policy allows 100
        assertEq(mm.spendable(id), usd(100));

        vm.prank(payer);
        token.approve(address(mm), usd(30));
        assertEq(mm.spendable(id), usd(30), "the allowance is the outer ceiling");

        vm.prank(payer);
        token.approve(address(mm), 0);
        assertEq(mm.spendable(id), 0, "revoking the approval disarms the mandate");
        assertGt(mm.policyHeadroom(id), 0, "though the policy itself is untouched");
    }

    function test_spendable_clampsToTheBalance() public {
        bytes32 id = grant(simpleParams());
        token.burnFrom(payer, token.balanceOf(payer) - usd(7));
        assertEq(mm.spendable(id), usd(7));

        token.burnFrom(payer, usd(7));
        assertEq(mm.spendable(id), 0, "an empty account can spend nothing");
    }

    function test_spendable_onUnknownMandate_isZero() public view {
        assertEq(mm.spendable(bytes32("nope")), 0);
    }

    /// The number `spendable` reports must actually be spendable. This is the one
    /// assertion that makes the view trustworthy rather than indicative.
    function test_spendable_isAchievable() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.totalCap = usd(137);
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);
        vm.prank(payer);
        token.approve(address(mm), usd(64));

        uint256 max = mm.spendable(id);
        assertEq(max, usd(64), "allowance binds");
        pay(id, max); // must not revert
        assertEq(token.balanceOf(vendor), max);
    }

    // ------------------------------------------------------- misc accessors

    function test_isAllowedRecipient_withoutAnAllowlist() public {
        bytes32 id = grant(simpleParams());
        assertTrue(mm.isAllowedRecipient(id, vendor));
        assertTrue(mm.isAllowedRecipient(id, other));
        // Not "anything goes": the zero address is still refused, matching `spend`.
        assertFalse(mm.isAllowedRecipient(id, address(0)));
    }

    function test_isAllowedRecipient_withAnAllowlist() public {
        bytes32 id = grant(withAllowlist(simpleParams(), vendor));
        assertTrue(mm.isAllowedRecipient(id, vendor));
        assertFalse(mm.isAllowedRecipient(id, other));
        assertFalse(mm.isAllowedRecipient(id, address(0)));
    }

    function test_unknownMandate_readsAsEmptyRatherThanReverting() public view {
        MandateManager.Mandate memory m = mm.getMandate(bytes32("nope"));
        assertEq(m.payer, address(0), "payer == 0 is how callers detect absence");
        assertEq(m.flags, 0);
        assertEq(m.windowCount, 0);

        MandateManager.WindowSpec memory w = mm.getWindow(bytes32("nope"), 0);
        assertEq(w.subLength, 0, "subLength == 0 is the guard windowRemaining uses");

        assertFalse(mm.isNonceUsed(bytes32("nope"), bytes32("n")));
        assertFalse(mm.isCosignApproved(bytes32("nope"), bytes32("h")));
    }

    /// `spendHash` is a pure function of its arguments and must be stable across
    /// calls — an agent computes it, shows it to a human, and submits it later.
    function test_spendHash_isDeterministic() public {
        bytes32 id = grant(simpleParams());
        bytes32 a = mm.spendHash(id, agent, vendor, usd(10), REF, bytes32("n"));
        vm.warp(block.timestamp + 5000);
        pay(id, usd(1));
        bytes32 b = mm.spendHash(id, agent, vendor, usd(10), REF, bytes32("n"));
        assertEq(a, b, "no state and no clock in the hash");
    }

    /// Every field is inside the hash. If any one of these collides, a co-signature
    /// for one payment authorises a different one.
    function test_spendHash_dependsOnEveryField() public {
        bytes32 id = grant(simpleParams());
        bytes32 base = mm.spendHash(id, agent, vendor, usd(10), REF, bytes32("n"));

        assertTrue(base != mm.spendHash(id, other, vendor, usd(10), REF, bytes32("n")), "spender");
        assertTrue(base != mm.spendHash(id, agent, other, usd(10), REF, bytes32("n")), "recipient");
        assertTrue(base != mm.spendHash(id, agent, vendor, usd(11), REF, bytes32("n")), "amount");
        assertTrue(base != mm.spendHash(id, agent, vendor, usd(10), bytes32("x"), bytes32("n")), "reference");
        assertTrue(base != mm.spendHash(id, agent, vendor, usd(10), REF, bytes32("m")), "nonce");
        assertTrue(base != mm.spendHash(bytes32("other-id"), agent, vendor, usd(10), REF, bytes32("n")), "mandate");
    }
}
