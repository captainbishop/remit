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

    // ----------------------------------------------- spendableAcross (NEW IN v2)
    //
    // Eight tests for one view, because every one of them pins a case where the
    // obvious implementation — `for (..) sum += policyHeadroom(ids[i]);` — returns a
    // confidently wrong number or panics, rather than failing in a way anyone would
    // notice. The joint ceiling is the only figure in the contract that depends on
    // something no mandate contains: the payer's single ERC-20 allowance.

    /// The property that makes the joint view trustworthy: for one mandate it is not
    /// a second opinion, it is the same opinion. If these ever diverge, the joint path
    /// has grown a rule `spendable` does not have.
    function test_spendableAcross_ofOne_agreesWithSpendable() public {
        bytes32[] memory one = new bytes32[](1);

        one[0] = grant(simpleParams());
        assertEq(mm.spendableAcross(one), mm.spendable(one[0]), "policy binds");

        vm.prank(payer);
        token.approve(address(mm), usd(30));
        assertEq(mm.spendableAcross(one), mm.spendable(one[0]), "allowance binds");
        assertEq(mm.spendableAcross(one), usd(30));

        vm.prank(payer);
        token.approve(address(mm), type(uint256).max);
        vm.prank(payer);
        mm.revoke(one[0]);
        assertEq(mm.spendableAcross(one), mm.spendable(one[0]), "revoked");
        assertEq(mm.spendableAcross(one), 0);
    }

    /**
     * THE WHOLE REASON THIS VIEW EXISTS, in the exact shape it was found in.
     *
     * On 2026-08-24 two live mandates at 0x3744E93B…0196 each returned `spendable` of
     * 90,000 against an allowance of exactly 90,000, and a 50,000 dry-run succeeded on
     * both. Nothing was wrong with either answer. Adding them up gives 180,000, which
     * is twice what the payer could lose, and no view in v1 could say so.
     *
     * This does NOT fix the race — both delegates can still spend until the shared
     * allowance is dry, which is inherent to layering per-mandate policy over one
     * ERC-20 approval. It converts the overlap from an inference nobody makes into a
     * number one call away.
     */
    function test_spendableAcross_exposesTheSharedAllowanceOverlap() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = 90_000;
        p.flags = F_PER_TX;
        p = withExpiry(p); // v2: a perTxCap is not a lifetime bound
        bytes32 a = grant(p);
        p.spender = other; // a second delegate, same payer, same allowance
        bytes32 b = grant(p);

        vm.prank(payer);
        token.approve(address(mm), 90_000);

        assertEq(mm.spendable(a), 90_000, "each mandate's own answer is correct");
        assertEq(mm.spendable(b), 90_000);

        bytes32[] memory both = new bytes32[](2);
        both[0] = a;
        both[1] = b;
        assertEq(mm.spendableAcross(both), 90_000, "and the joint answer is half their sum");
        assertEq(mm.spendable(a) + mm.spendable(b), 180_000, "which is what a payer would add up");
    }

    /**
     * The overflow, and why the fix is a clamp on each term rather than a saturating
     * add on the total.
     *
     * `policyHeadroom` returns `type(uint256).max` for a mandate bounded only by an
     * expiry — correctly, since the payer set no amount bound. But `spend` refuses
     * anything above `type(uint96).max` with `AmountTooLarge`, so that return value
     * over-reports the largest single spend, and adding two of them PANICS. Two
     * expiry-only grants from one payer is a two-line construction, which puts this in
     * the same class as v1's `totalSpent` cliff rather than among the astronomical
     * edges. Clamping each term first makes every term the true largest single spend
     * AND makes the sum unable to overflow: MAX_JOINT * (2^96 - 1) < 2^99.
     */
    function test_spendableAcross_unboundedTermsClampInsteadOfOverflowing() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_EXPIRY;
        bytes32 a = grant(p);
        bytes32 b = grant(p);

        // The input condition that makes a naive sum panic, asserted rather than
        // asserted about: these are the two addends.
        assertEq(mm.policyHeadroom(a), type(uint256).max);
        assertEq(mm.policyHeadroom(b), type(uint256).max);

        // Base funds the payer with 1e15 base units, far below 2^96, so the balance
        // clamp would hide the arithmetic entirely. Mint past it to see the sum.
        token.mint(payer, type(uint128).max);

        bytes32[] memory both = new bytes32[](2);
        both[0] = a;
        both[1] = b;
        assertEq(mm.spendableAcross(both), 2 * uint256(type(uint96).max), "each term clamped, no panic");

        // The widest total the contract can be asked for, which is the arithmetic that
        // makes a saturating add unnecessary rather than merely unused.
        bytes32[] memory eight = new bytes32[](mm.MAX_JOINT());
        eight[0] = a;
        eight[1] = b;
        for (uint256 i = 2; i < eight.length; ++i) {
            eight[i] = grant(p);
        }
        uint256 widest = mm.spendableAcross(eight);
        assertEq(widest, mm.MAX_JOINT() * uint256(type(uint96).max));
        assertLt(widest, 2 ** 99);
    }

    /// There is no joint ceiling across two payers: each has a separate allowance and
    /// a separate balance, so no single clamp applies and the sum is meaningless.
    /// Refused in both orders — the payer is read from the first element, and taking
    /// whichever one happened to be named first would be exactly the silent summing
    /// this view exists to prevent.
    function test_spendableAcross_mixedPayers_reverts() public {
        bytes32 mine = grant(simpleParams());

        token.mint(other, 1_000_000 * ONE);
        vm.prank(other);
        token.approve(address(mm), type(uint256).max);
        vm.prank(other);
        bytes32 theirs = mm.createMandate(bytes32("other-payer"), simpleParams());

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = mine;
        ids[1] = theirs;
        vm.expectRevert(MandateManager.MixedPayers.selector);
        mm.spendableAcross(ids);

        ids[0] = theirs;
        ids[1] = mine;
        vm.expectRevert(MandateManager.MixedPayers.selector);
        mm.spendableAcross(ids);

        // Each is a perfectly good single-payer request on its own.
        bytes32[] memory one = new bytes32[](1);
        one[0] = mine;
        assertEq(mm.spendableAcross(one), usd(100));
        one[0] = theirs;
        assertEq(mm.spendableAcross(one), usd(100));
    }

    /// A repeated id would double-count headroom that exists once. Refused rather than
    /// deduplicated, because deduplicating hands the right number to a caller who
    /// still believes they hold two grants — and 200 is far more convincing than 100
    /// to somebody in that state.
    function test_spendableAcross_duplicateIds_revert() public {
        bytes32 a = grant(simpleParams());
        bytes32 b = grant(simpleParams());

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = a;
        vm.expectRevert(MandateManager.DuplicateMandate.selector);
        mm.spendableAcross(ids);

        // Non-adjacent too, which is what the O(n^2) scan buys over "must be sorted".
        bytes32[] memory three = new bytes32[](3);
        three[0] = a;
        three[1] = b;
        three[2] = a;
        vm.expectRevert(MandateManager.DuplicateMandate.selector);
        mm.spendableAcross(three);

        three[2] = grant(simpleParams());
        assertEq(mm.spendableAcross(three), usd(300), "three distinct mandates, nothing else binding");
    }

    /**
     * An id that resolves to nothing reverts, and this is a DELIBERATE divergence from
     * `spendable`, which returns 0 for an unknown mandate.
     *
     * The justification is that the two zeros mean different things. `spendable(x) ==
     * 0` for a single unknown id is unambiguous — the caller asked about one thing and
     * got nothing. One bad id among eight is invisible: it contributes 0 to a total
     * that still looks plausible, and the caller walks away believing they enumerated
     * their exposure when they enumerated seven eighths of it. This view exists to
     * surface what the per-mandate views hide, so it cannot itself hide a typo.
     */
    function test_spendableAcross_unknownId_reverts() public {
        assertEq(mm.spendable(bytes32("nope")), 0, "the single-mandate view is unchanged");

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32("nope");
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.spendableAcross(ids);

        // Buried among real ones, which is the case that matters.
        bytes32[] memory three = new bytes32[](3);
        three[0] = grant(simpleParams());
        three[1] = bytes32("nope");
        three[2] = grant(simpleParams());
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.spendableAcross(three);
    }

    /// Dead mandates contribute zero WITHOUT reverting — they are the ordinary
    /// contents of any real caller's list, and a view that refused them would be
    /// unusable exactly when a payer most wants to audit what is still live. Only
    /// malformed questions revert; a mandate that has simply run its course is a valid
    /// answer of nothing.
    function test_spendableAcross_revokedAndExpiredContributeZero() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100);
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_PER_TX | F_EXPIRY;

        bytes32 live = grant(p);
        bytes32 dead = grant(p);
        bytes32 lapsed = grant(p);
        vm.prank(payer);
        mm.revoke(dead);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = live;
        ids[1] = dead;
        ids[2] = lapsed;
        assertEq(mm.spendableAcross(ids), usd(200), "revoked drops out, the other two remain");

        vm.warp(block.timestamp + 2 days);
        assertEq(mm.spendableAcross(ids), 0, "all three are now dead");
    }

    /// The gas cap. `spendableAcross` performs up to 139 cold storage reads per
    /// mandate, so the length limit is what keeps an unbounded loop over untrusted
    /// input out of the contract — the same job MAX_WINDOWS and MAX_BUCKETS do for
    /// `spend`. The boundary is tested from both sides so the cap is exact.
    function test_spendableAcross_lengthCapIsExact() public {
        assertEq(mm.MAX_JOINT(), 8);

        bytes32[] memory ok = new bytes32[](8);
        bytes32[] memory tooMany = new bytes32[](9);
        for (uint256 i = 0; i < 9; ++i) {
            bytes32 id = grant(simpleParams());
            if (i < 8) ok[i] = id;
            tooMany[i] = id;
        }

        assertEq(mm.spendableAcross(ok), usd(800), "eight is allowed");
        vm.expectRevert(MandateManager.TooManyMandates.selector);
        mm.spendableAcross(tooMany);

        // An empty set is answered, not refused: nothing can move nothing, and reading
        // ids[0] to find the payer of an empty set would panic on an array bound.
        assertEq(mm.spendableAcross(new bytes32[](0)), 0);
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
        assertEq(mm.cosignApprovalDeadline(bytes32("nope"), bytes32("h")), 0, "zero means absent");
    }

    /// `spendHash` is the ONE view that reverts on an unknown mandate rather than reading as
    /// empty, and the asymmetry is deliberate rather than an oversight in the list above.
    ///
    /// v2 (F15) made it read the mandate's spender instead of taking one as an argument, so on
    /// an absent mandate it would otherwise return the hash of a spend by the zero address —
    /// a well-formed 32 bytes that no `spend` can ever match. Every other view here answers a
    /// question about state and "there is none" is a true answer; this one manufactures a
    /// value a caller would then hand to a cosigner, so silence is the wrong output.
    function test_spendHash_onUnknownMandate_reverts() public {
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.spendHash(bytes32("nope"), vendor, usd(10), REF, bytes32("n"));
    }

    /// `spendHash` is a pure function of its arguments and the mandate's spender, and must be
    /// stable across calls — an agent computes it, shows it to a human, and submits it later.
    ///
    /// v2 (F15) turned it from `pure`-in-spirit into a storage read, which is exactly why this
    /// test is worth more than it was: a spend and a 5,000-second warp both happen between the
    /// two calls, so the assertion now says the hash ignores the clock, the nonce counter, and
    /// every spend-mutated field of the mandate it reads — not merely that keccak is a function.
    function test_spendHash_isDeterministic() public {
        bytes32 id = grant(simpleParams());
        bytes32 a = mm.spendHash(id, vendor, usd(10), REF, bytes32("n"));
        vm.warp(block.timestamp + 5000);
        pay(id, usd(1));
        bytes32 b = mm.spendHash(id, vendor, usd(10), REF, bytes32("n"));
        assertEq(a, b, "no state and no clock in the hash");
    }

    /// Every field is inside the hash. If any one of these collides, a co-signature
    /// for one payment authorises a different one.
    ///
    /// Two of the six fields moved out of the argument list in v2 and are varied through a
    /// second mandate instead. That is a stronger test than the old one, not a weaker one:
    /// `spender` and `mandateId` used to be varied as free arguments, so the old assertions
    /// could be satisfied by a hash that no caller could ever actually obtain. Here both
    /// mandates exist, both hashes are obtainable, and they still differ.
    function test_spendHash_dependsOnEveryField() public {
        bytes32 id = grant(simpleParams());
        bytes32 base = mm.spendHash(id, vendor, usd(10), REF, bytes32("n"));

        assertTrue(base != mm.spendHash(id, other, usd(10), REF, bytes32("n")), "recipient");
        assertTrue(base != mm.spendHash(id, vendor, usd(11), REF, bytes32("n")), "amount");
        assertTrue(base != mm.spendHash(id, vendor, usd(10), bytes32("x"), bytes32("n")), "reference");
        assertTrue(base != mm.spendHash(id, vendor, usd(10), REF, bytes32("m")), "nonce");

        // Same payer, same salt-free everything, different SPENDER.
        MandateManager.MandateParams memory p = simpleParams();
        p.spender = other;
        vm.prank(payer);
        bytes32 otherSpender = mm.createMandate(bytes32("vh-spender"), p);
        assertTrue(base != mm.spendHash(otherSpender, vendor, usd(10), REF, bytes32("n")), "spender");

        // Same spender, different MANDATE. `grant` bumps the salt, so this is a distinct id
        // with identical policy — which isolates the id itself as the varying field.
        bytes32 otherId = grant(simpleParams());
        assertTrue(base != mm.spendHash(otherId, vendor, usd(10), REF, bytes32("n")), "mandate");
    }
}
