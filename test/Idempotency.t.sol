// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * Idempotency and atomicity.
 *
 * Two properties, and they pull in opposite directions:
 *
 *   1. A nonce may be used at most once, so a retrying off-chain worker cannot pay
 *      twice. Arc's one-confirmation finality makes aggressive retry logic normal, so
 *      this is not a theoretical concern.
 *   2. A spend that FAILS must consume nothing at all — not the nonce, not window
 *      headroom, not the lifetime total. Otherwise property 1 turns into a denial of
 *      service: a transient failure would permanently burn the nonce and the caller
 *      could never complete the payment.
 *
 * Property 2 is why this file exists in Solidity and not just in the model. It rests
 * entirely on EVM transaction rollback — the contract writes `_usedNonce` and the
 * window buckets BEFORE calling the token, and correctness comes from the whole call
 * unwinding. A JavaScript model cannot demonstrate that; it can only imitate it by
 * splitting evaluate from commit.
 */
contract IdempotencyTest is Base {
    // ------------------------------------------------------- replay defence

    function test_replayingANonce_reverts() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("invoice-77");

        payWithNonce(id, vendor, usd(10), nonce);
        assertTrue(mm.isNonceUsed(id, nonce));

        vm.prank(agent);
        vm.expectRevert(MandateManager.NonceAlreadyUsed.selector);
        mm.spend(id, vendor, usd(10), REF, nonce);

        assertEq(token.balanceOf(vendor), usd(10), "paid exactly once");
        assertEq(mm.getMandate(id).spendCount, 1);
    }

    /// Changing the amount does not sidestep the nonce. The nonce is the unit of
    /// idempotency on its own, not in combination with the payload — a worker that
    /// retries with a corrected amount must mint a new nonce.
    function test_replayingANonceWithADifferentPayload_stillReverts() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("invoice-77");
        payWithNonce(id, vendor, usd(10), nonce);

        vm.prank(agent);
        vm.expectRevert(MandateManager.NonceAlreadyUsed.selector);
        mm.spend(id, other, usd(99), bytes32("different-ref"), nonce);
    }

    /// The nonce is checked ahead of every policy check, so a replay of a nonce
    /// that is ALSO over the cap reports the replay. The agent's correct response
    /// differs — mint a new nonce versus spend less — so the order matters.
    function test_nonceIsCheckedBeforeTheCaps() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("used");
        payWithNonce(id, vendor, usd(10), nonce);

        vm.prank(agent);
        vm.expectRevert(MandateManager.NonceAlreadyUsed.selector);
        mm.spend(id, vendor, usd(5000), REF, nonce); // also over perTxCap
    }

    /// Two legitimately identical payments — same recipient, same amount, same
    /// reference — must both succeed under different nonces. A vendor really can
    /// invoice the same amount twice, and refusing that would be its own bug.
    function test_identicalSpendsUnderDifferentNonces_bothSucceed() public {
        bytes32 id = grant(simpleParams());
        payWithNonce(id, vendor, usd(10), bytes32("a"));
        payWithNonce(id, vendor, usd(10), bytes32("b"));
        assertEq(token.balanceOf(vendor), usd(20));
        assertEq(mm.getMandate(id).spendCount, 2);
    }

    /// Nonces are namespaced per mandate. A payer running two mandates should not
    /// have to coordinate counters between two independent agents.
    function test_noncesAreScopedToTheMandate() public {
        bytes32 a = grant(simpleParams());
        bytes32 b = grant(simpleParams());
        bytes32 nonce = bytes32("shared");

        payWithNonce(a, vendor, usd(10), nonce);
        payWithNonce(b, vendor, usd(10), nonce);

        assertTrue(mm.isNonceUsed(a, nonce));
        assertTrue(mm.isNonceUsed(b, nonce));
        assertEq(token.balanceOf(vendor), usd(20));
    }

    // ------------------------------------------------- a denial costs nothing

    /**
     * The central atomicity claim, checked against every class of policy denial.
     *
     * After each refused attempt: the nonce is still free, the window still has its
     * full headroom, and the mandate's counters are untouched. Then the same nonce is
     * used successfully, proving the refusals really left it available.
     */
    function test_deniedSpends_consumeNothing() public {
        bytes32 id = grant(withAllowlist(simpleParams(), vendor));
        bytes32 nonce = bytes32("still-free");
        uint256 fullWindow = mm.windowRemaining(id, 0);

        payReverts(id, vendor, uint256(usd(100)) + 1, MandateManager.OverPerTxCap.selector);
        payReverts(id, other, usd(10), MandateManager.RecipientNotAllowed.selector);
        payReverts(id, address(0), usd(10), MandateManager.ZeroRecipient.selector);
        payReverts(id, vendor, 0, MandateManager.ZeroAmount.selector);

        MandateManager.Mandate memory m = mm.getMandate(id);
        assertEq(m.totalSpent, 0, "totalSpent untouched");
        assertEq(m.spendCount, 0, "spendCount untouched");
        assertEq(mm.windowRemaining(id, 0), fullWindow, "window untouched");
        assertFalse(mm.isNonceUsed(id, nonce), "nonce never reserved");
        assertEq(token.balanceOf(vendor), 0);

        payWithNonce(id, vendor, usd(10), nonce);
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// A window breach in particular must not partially consume the window. The
    /// contract checks and commits in one pass, so an over-cap spend gets as far as
    /// reading the ring before reverting.
    function test_windowBreach_doesNotPartiallyConsumeTheWindow() public {
        bytes32 id = grant(windowOnlyParams(DAY, usd(100), 12));
        pay(id, usd(60));
        assertEq(mm.windowRemaining(id, 0), usd(40));

        payReverts(id, usd(50), overWindowCap(DAY, usd(100), usd(60)));
        assertEq(mm.windowRemaining(id, 0), usd(40), "still exactly 40");

        pay(id, usd(40));
        assertEq(mm.windowRemaining(id, 0), 0);
    }

    // ------------------------------------------ token-layer failures unwind

    /**
     * Arc enforces the USDC blocklist at RUNTIME, and there is no view to pre-check
     * it. A spend to a newly blocklisted vendor therefore fails inside the token,
     * after this contract has already written the nonce and the window bucket. The
     * only correct outcome is that all of it unwinds — and then the same nonce works
     * once the recipient is cleared.
     */
    function test_blocklistedRecipient_unwindsTheEntireSpend() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("blocked-then-ok");
        uint256 fullWindow = mm.windowRemaining(id, 0);

        token.setBlocklisted(vendor, true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AccountBlocklisted.selector, vendor));
        mm.spend(id, vendor, usd(10), REF, nonce);

        assertFalse(mm.isNonceUsed(id, nonce), "nonce not burned by a token failure");
        assertEq(mm.windowRemaining(id, 0), fullWindow, "no cap consumed");
        assertEq(mm.getMandate(id).totalSpent, 0);

        token.setBlocklisted(vendor, false);
        payWithNonce(id, vendor, usd(10), nonce); // the retry is legitimate
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// The payer can be blocklisted too, which disables every mandate they granted
    /// at once. Same requirement: unwind cleanly rather than half-record the spend.
    function test_blocklistedPayer_unwindsTheEntireSpend() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("payer-blocked");

        token.setBlocklisted(payer, true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AccountBlocklisted.selector, payer));
        mm.spend(id, vendor, usd(10), REF, nonce);

        assertFalse(mm.isNonceUsed(id, nonce));
        assertEq(mm.getMandate(id).spendCount, 0);
    }

    /**
     * The allowance is the outer ceiling and the payer controls it independently.
     * Reducing it below the mandate's caps is a legitimate way to throttle without
     * revoking — and the failure it produces must be retryable, not terminal.
     */
    function test_insufficientAllowance_unwindsAndIsRetryable() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("allowance");

        vm.prank(payer);
        token.approve(address(mm), usd(50));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.InsufficientAllowance.selector, usd(50), usd(90)));
        mm.spend(id, vendor, usd(90), REF, nonce);
        assertFalse(mm.isNonceUsed(id, nonce));

        vm.prank(payer);
        token.approve(address(mm), usd(90));
        payWithNonce(id, vendor, usd(90), nonce);
        assertEq(token.balanceOf(vendor), usd(90));
    }

    /// A healthy mandate over an empty account. The policy says yes and the money
    /// says no, which is exactly why `spendable` exists as a pre-flight view.
    function test_insufficientBalance_unwinds() public {
        bytes32 id = grant(simpleParams());
        token.burnFrom(payer, token.balanceOf(payer) - usd(5));

        assertGt(mm.policyHeadroom(id), usd(5), "the policy still permits more than the balance");
        assertEq(mm.spendable(id), usd(5), "but spendable tells the truth");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.InsufficientBalance.selector, usd(5), usd(90)));
        mm.spend(id, vendor, usd(90), REF, bytes32("broke"));

        assertEq(mm.getMandate(id).spendCount, 0);
    }

    /**
     * Some ERC-20s signal failure by returning false instead of reverting. Arc's USDC
     * does not, but this contract checks the return value anyway, and an unchecked
     * branch is indistinguishable from a missing one. Without this test that check is
     * dead code with no evidence behind it.
     */
    function test_transferReturningFalse_raisesTransferFailed() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("silent-failure");
        token.setReturnFalseOnTransfer(true);

        vm.prank(agent);
        vm.expectRevert(MandateManager.TransferFailed.selector);
        mm.spend(id, vendor, usd(10), REF, nonce);

        assertFalse(mm.isNonceUsed(id, nonce), "a silent token failure must not burn the nonce either");
        assertEq(token.balanceOf(vendor), 0);
    }

    // ------------------------------------------------------- audit trail

    /**
     * The retry path: a spend that failed in the token can be re-submitted unchanged.
     *
     * `test_transferReturningFalse_raisesTransferFailed` above already shows the nonce
     * survives such a failure. This shows the consequence that actually matters — the
     * identical spend then settles, so a retry loop never has to invent a new nonce or
     * risk double-paying. On Arc this is not hypothetical: the blocklist is
     * enforced at runtime, so an otherwise valid spend can fail in the token and
     * succeed on a later attempt.
     *
     * The Spend event is emitted BEFORE the transfer, so an indexer sees the
     * authorisation decision ahead of the money movement. The transfer can still
     * revert, so an emitted Spend only ever appears in a transaction that succeeded,
     * making the event stream reconcilable against token transfers without needing
     * Arc's Memo precompile at all.
     *
     * That last property is worth stating and cannot be tested here. This test
     * previously tried, by asserting `vm.recordLogs()` returned nothing, and the
     * assertion was not merely wrong but unanswerable: the recorder captures events
     * when they are emitted and does not model the EVM discarding them as the frame
     * reverts, so it faithfully reports a `Spend` the chain would never keep. It was
     * asserting something false about Foundry rather than something true about Remit.
     * The rollback below is the observable form of the same claim.
     */
    function test_failedTransfer_rollsBackSoTheSameSpendCanBeRetried() public {
        bytes32 id = grant(simpleParams());
        bytes32 nonce = bytes32("n");
        token.setReturnFalseOnTransfer(true);

        vm.prank(agent);
        (bool ok, bytes memory err) =
            address(mm).call(abi.encodeCall(MandateManager.spend, (id, vendor, usd(10), REF, nonce)));

        assertFalse(ok, "the spend must fail when the token refuses");
        assertRevertedWith(err, MandateManager.TransferFailed.selector, "expected TransferFailed");

        assertEq(mm.getMandate(id).totalSpent, 0, "no cap was consumed");
        assertEq(mm.getMandate(id).spendCount, 0, "no spend was counted");
        assertEq(token.balanceOf(vendor), 0, "no money moved");
        assertFalse(mm.isNonceUsed(id, nonce), "and the nonce was not burned");

        token.setReturnFalseOnTransfer(false);
        payWithNonce(id, vendor, usd(10), nonce);

        assertEq(token.balanceOf(vendor), usd(10), "the identical retry settles");
        assertEq(mm.getMandate(id).totalSpent, usd(10), "and is counted exactly once");
        assertTrue(mm.isNonceUsed(id, nonce), "and only now is the nonce spent");
    }
}
