// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * F51 — the payer-nominated revoker.
 *
 * This file exists because of a sentence, and the sentence is worth stating before the code.
 * F42 recorded that on Arc gas and budget are one balance, so a delegate can spend a mandate down
 * to the point where the payer cannot afford the 30,808 gas that `revoke` costs. The answer taken
 * was to let the payer name one more address that may call `revoke`, funded separately, so the
 * escape does not depend on the balance the delegate is draining.
 *
 * Adding a third holder of a kill switch is adding a party who can act against the payer's wishes,
 * and the argument that this is acceptable rests entirely on how small that switch is. That
 * argument was written into `revoke`'s NatSpec as a list: the nominee cannot spend, cannot raise a
 * cap, cannot add a recipient, cannot clear a reservation, cannot un-revoke, cannot name a
 * different revoker, and cannot reach any other mandate. A list like that is a claim about this
 * contract, and a claim about a contract holding real money is worth nothing until something
 * attempts each item and fails.
 *
 * So every `_ATTACK_` test below is one line of that list, and each one ends by reading the payer's
 * USDC balance and the allowance they granted this contract. Those two numbers are the whole of
 * what any mandate can move — `spend` calls `transferFrom(payer, recipient, amount)`, which debits
 * the first and consumes the second — so an attempt that moved money cannot leave both unchanged.
 *
 * The nominee here is `guardian`, declared in this file rather than in `Base`, because it is the
 * only address in the suite whose entire purpose is to be refused.
 */
contract RevokerTest is Base {
    address internal guardian;
    address internal guardian2;

    function setUp() public override {
        super.setUp();
        guardian = makeAddr("guardian");
        guardian2 = makeAddr("guardian2");
        vm.label(guardian, "guardian");
    }

    // -- helpers -----------------------------------------------------------

    /// The payer's two exposed quantities. Read as a pair because a spend moves both, so
    /// checking one alone would miss a transfer that the other recorded.
    function _payerState() internal view returns (uint256 bal, uint256 allow) {
        bal = token.balanceOf(payer);
        allow = token.allowance(payer, address(mm));
    }

    /// A plain mandate with `guardian` nominated at grant time.
    function _guarded() internal returns (bytes32) {
        return grant(withRevoker(simpleParams(), guardian));
    }

    /// How many times `topic` appears as topic0 in the logs of the call just made.
    /// Used where the assertion is about an event NOT being emitted, which
    /// `vm.expectEmit` cannot express.
    function _countLogs(bytes32 topic) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) n++;
        }
    }

    // -- nomination at grant time -------------------------------------------

    function test_createMandate_recordsTheNominatedRevoker() public {
        bytes32 id = _guarded();
        assertEq(mm.getRevoker(id), guardian, "the nomination was not stored");
    }

    /// The default, and the whole of v1's behaviour: a grant that names no one stores no one.
    function test_createMandate_withoutRevoker_storesNobody() public {
        bytes32 id = grant(simpleParams());
        assertEq(mm.getRevoker(id), address(0), "a grant naming nobody stored somebody");
    }

    /// An unknown mandate and a known one with no revoker give the same answer, which
    /// `getRevoker`'s own NatSpec says and which a reader should not have to take on faith.
    function test_getRevoker_unknownMandateAnswersZero() public view {
        assertEq(mm.getRevoker(keccak256("never granted")), address(0), "an unknown mandate answered");
    }

    function test_createMandate_emitsRevokerSet() public {
        MandateManager.MandateParams memory p = withRevoker(simpleParams(), guardian);
        // Salt and prank spelled out rather than going through `grant()`, following
        // `Creation.t.sol`'s event test, so the predicted id depends on nothing private.
        bytes32 expectedId = keccak256(abi.encode(mm.DOMAIN(), block.chainid, address(mm), payer, bytes32(uint256(1))));

        vm.expectEmit(true, true, false, false, address(mm));
        emit MandateManager.RevokerSet(expectedId, guardian);

        vm.prank(payer);
        bytes32 id = mm.createMandate(bytes32(uint256(1)), p);
        assertEq(id, expectedId, "the id this test predicted is not the id granted");
    }

    /// The comment on the second half of the F51 block in `createMandate` says the emit is
    /// ordered after `MandateCreated` so a reader of the log stream learns the mandate exists
    /// before learning who may kill it. That is an ordering claim, and ordering is exactly what
    /// `vm.expectEmit` will not tell you when only one of the two is declared.
    function test_createMandate_emitsRevokerSetAfterMandateCreated() public {
        vm.recordLogs();
        _guarded();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 created = type(uint256).max;
        uint256 nominated = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == MandateManager.MandateCreated.selector) created = i;
            if (logs[i].topics[0] == MandateManager.RevokerSet.selector) nominated = i;
        }

        assertTrue(created != type(uint256).max, "MandateCreated was not emitted");
        assertTrue(nominated != type(uint256).max, "RevokerSet was not emitted");
        assertLt(created, nominated, "RevokerSet was announced before the mandate it belongs to");
    }

    function test_createMandate_withoutRevoker_emitsNoRevokerSet() public {
        vm.recordLogs();
        grant(simpleParams());
        assertEq(_countLogs(MandateManager.RevokerSet.selector), 0, "a grant naming nobody announced somebody");
    }

    // -- the three ineligible nominees --------------------------------------
    //
    // One argument applied three times, and the same argument that already refuses
    // `spender == address(this)` and `cosigner == spender`: a grant must not carry the
    // appearance of a control without its substance. `address(this)` can never call `revoke`;
    // the payer holds the authority already and is the address the gas lockout strands; the
    // spender holds it already and its spending is what creates the situation. A grant naming
    // any of the three would read as protection and provide none.

    function test_createMandate_refusesTheContractItself() public {
        MandateManager.MandateParams memory p = withRevoker(simpleParams(), address(mm));
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    function test_createMandate_refusesThePayer() public {
        MandateManager.MandateParams memory p = withRevoker(simpleParams(), payer);
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    function test_createMandate_refusesTheSpender() public {
        MandateManager.MandateParams memory p = withRevoker(simpleParams(), agent);
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The co-signer stays eligible, deliberately, and this test is here so that no one
    /// "tidies" the refusal list by adding a fourth case to it.
    ///
    /// The three above are refused because each one already holds the power, or can never
    /// exercise it. Neither is true of the co-signer: they cannot revoke in v1, and they are an
    /// address the payer already chose to trust with a decision about this mandate. A payer who
    /// wants one second party rather than two is expressing a preference, not making a mistake,
    /// and refusing it would send them to a fresh address for no gain in safety.
    function test_createMandate_permitsTheCosigner() public {
        MandateManager.MandateParams memory p = withCosign(simpleParams(), boss, usd(50));
        bytes32 id = grant(withRevoker(p, boss));
        assertEq(mm.getRevoker(id), boss, "the co-signer was refused as a revoker");

        vm.prank(boss);
        mm.revoke(id);
        assertFalse(mm.isLive(id), "the co-signer could not use the role the payer gave them");
    }

    // -- setRevoker: naming one after the fact ------------------------------

    function test_setRevoker_namesOneAfterTheGrant() public {
        bytes32 id = grant(simpleParams());
        assertEq(mm.getRevoker(id), address(0), "precondition: this mandate should start with none");

        vm.expectEmit(true, true, false, false, address(mm));
        emit MandateManager.RevokerSet(id, guardian);
        vm.prank(payer);
        mm.setRevoker(id, guardian);

        assertEq(mm.getRevoker(id), guardian, "the nomination was not stored");
        vm.prank(guardian);
        mm.revoke(id);
        assertFalse(mm.isLive(id), "the nominee could not use the role");
    }

    function test_setRevoker_replacesTheNominee() public {
        bytes32 id = _guarded();

        vm.prank(payer);
        mm.setRevoker(id, guardian2);
        assertEq(mm.getRevoker(id), guardian2, "the replacement was not stored");

        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(id);
        assertTrue(mm.isLive(id), "the replaced nominee still killed the mandate");

        vm.prank(guardian2);
        mm.revoke(id);
        assertFalse(mm.isLive(id), "the replacement could not use the role");
    }

    /// The way back to v1's behaviour, which is why `address(0)` must never be refusable.
    function test_setRevoker_removesWithZero() public {
        bytes32 id = _guarded();

        vm.expectEmit(true, true, false, false, address(mm));
        emit MandateManager.RevokerSet(id, address(0));
        vm.prank(payer);
        mm.setRevoker(id, address(0));

        assertEq(mm.getRevoker(id), address(0), "the removal did not clear the mapping");
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(id);
        assertTrue(mm.isLive(id), "a removed nominee still killed the mandate");
    }

    function test_setRevoker_refusesUnknownMandate() public {
        vm.prank(payer);
        vm.expectRevert(MandateManager.UnknownMandate.selector);
        mm.setRevoker(keccak256("never granted"), guardian);
    }

    /// Matching `approveCosignFor`. A revoked mandate is permanently dead, so nominating anyone
    /// on it writes storage that can never be read and announces a protection that protects
    /// nothing.
    function test_setRevoker_refusesRevokedMandate() public {
        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        mm.revoke(id);

        vm.prank(payer);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.setRevoker(id, guardian);
        assertEq(mm.getRevoker(id), address(0), "a refused call still wrote the mapping");
    }

    function test_setRevoker_refusesTheContractItself() public {
        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.setRevoker(id, address(mm));
    }

    function test_setRevoker_refusesThePayer() public {
        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.setRevoker(id, payer);
    }

    function test_setRevoker_refusesTheSpender() public {
        bytes32 id = grant(simpleParams());
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.setRevoker(id, agent);
    }

    // -- setRevoker: who may nominate ---------------------------------------
    //
    // Payer only, and not the spender, even though `revoke` accepts the spender. The two are
    // different powers. `revoke` accepting the spender rests on a delegate surrendering their own
    // authority, which harms no one but themselves. Choosing who else holds a kill switch is not
    // that: a spender who could replace the nominee would hand the role to an address it
    // controls, or remove the payer's escape and leave a mandate that still looks protected.

    function test_setRevoker_ATTACK_spenderCannotNominate() public {
        bytes32 id = _guarded();
        vm.prank(agent);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, guardian2);
        assertEq(mm.getRevoker(id), guardian, "the spender changed the nominee");
    }

    /// The most valuable of the four: a spender who cannot replace the nominee might still try to
    /// remove them, which costs the payer their escape without changing anything they can see
    /// unless they read the log.
    function test_setRevoker_ATTACK_spenderCannotRemoveTheNominee() public {
        bytes32 id = _guarded();
        vm.prank(agent);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, address(0));
        assertEq(mm.getRevoker(id), guardian, "the spender removed the payer's escape");
    }

    function test_setRevoker_ATTACK_strangerCannotNominate() public {
        bytes32 id = grant(simpleParams());
        vm.prank(other);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, other);
        assertEq(mm.getRevoker(id), address(0), "a stranger nominated themselves");
    }

    /// "Cannot name a different revoker" — one line of `revoke`'s list. A nominee who could pass
    /// the role on would make it outlive the payer's choice of who holds it.
    function test_setRevoker_ATTACK_nomineeCannotNominate() public {
        bytes32 id = _guarded();
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, guardian2);
        assertEq(mm.getRevoker(id), guardian, "the nominee passed the role on");
    }

    /// The co-signer is eligible to hold the role and still cannot award it.
    function test_setRevoker_ATTACK_cosignerCannotNominate() public {
        bytes32 id = grant(withCosign(simpleParams(), boss, usd(50)));
        vm.prank(boss);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, boss);
        assertEq(mm.getRevoker(id), address(0), "the co-signer nominated themselves");
    }

    // -- revoke: the one thing the nominee can do ----------------------------

    function test_revoke_nomineeCanKillTheMandate() public {
        bytes32 id = _guarded();
        assertTrue(mm.isLive(id), "precondition: the mandate should start live");

        vm.expectEmit(true, true, false, false, address(mm));
        emit MandateManager.MandateRevoked(id, guardian);
        vm.prank(guardian);
        mm.revoke(id);

        assertFalse(mm.isLive(id), "the nominee's revocation did not take");
        assertTrue(mm.getMandate(id).revoked, "the latch was not set");
        payReverts(id, usd(1), MandateManager.Revoked.selector);
    }

    /// `MandateRevoked` names the caller, so the log distinguishes a payer's revocation from a
    /// nominee's. Whoever reconciles this stream needs that: the two mean different things.
    function test_revoke_theEventNamesTheNominee() public {
        bytes32 id = _guarded();
        vm.recordLogs();
        vm.prank(guardian);
        mm.revoke(id);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a revocation should emit exactly one event");
        assertEq(logs[0].topics[0], MandateManager.MandateRevoked.selector, "the wrong event was emitted");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), guardian, "the log credits the wrong caller");
    }

    /// F11's latch, exercised through the new caller. The second call must not revert — an
    /// atomic batch that revokes twice has to survive — and must not emit, because v1's second
    /// emit is what F11 removed.
    function test_revoke_nomineeIsIdempotent() public {
        bytes32 id = _guarded();
        vm.prank(guardian);
        mm.revoke(id);

        vm.recordLogs();
        vm.prank(guardian);
        mm.revoke(id);
        assertEq(vm.getRecordedLogs().length, 0, "a repeat revocation must emit nothing");
        assertTrue(mm.getMandate(id).revoked, "the repeat cleared the latch");
    }

    /// The bit the nominee writes is read on two state-changing paths, not one. `spend` is the
    /// obvious half and every test above uses it; `approveCosignFor` is the other, and a
    /// revocation that stopped spends while still letting a co-signer authorise new ones would
    /// leave approvals standing against a dead mandate.
    function test_revoke_byTheNomineeAlsoStopsTheCosigner() public {
        bytes32 id = grant(withRevoker(withCosign(simpleParams(), boss, usd(10)), guardian));

        vm.prank(guardian);
        mm.revoke(id);

        vm.prank(boss);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.approveCosignFor(id, vendor, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));
    }

    // -- revoke: the guard still refuses everybody else -----------------------

    /// The widened guard must not have widened past its third term. A mandate that names a
    /// nominee is still refused to everyone who is not one of the three.
    function test_revoke_ATTACK_strangerStillRefused() public {
        bytes32 id = _guarded();
        vm.prank(other);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(id);
        assertTrue(mm.isLive(id), "a stranger killed a guarded mandate");
    }

    /// `_callerIsRevoker`'s zero test, which is the only line in F51 whose defect would be
    /// invisible today. `_revoker` answers `address(0)` for every mandate that named no one, so a
    /// guard written as `msg.sender == nominated` alone would authorise `address(0)` on all of
    /// them. Nothing on the EVM calls from the zero address, which makes that latent rather than
    /// live — but a latent hole in a kill switch on a contract with no upgrade path is worth a
    /// test, and `vm.prank` can reach it where a transaction cannot.
    function test_revoke_ATTACK_zeroAddressCannotRevokeAnUnguardedMandate() public {
        bytes32 id = grant(simpleParams());
        assertEq(mm.getRevoker(id), address(0), "precondition: this mandate should name nobody");

        vm.prank(address(0));
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(id);
        assertTrue(mm.isLive(id), "the zero address killed a mandate that named nobody");
    }

    /// "Cannot reach any other mandate." The nominee's authority is one entry in a mapping keyed
    /// by mandate, so it does not travel — including to another mandate of the same payer with
    /// the same spender, which is the case a per-payer role would have leaked into.
    function test_revoke_ATTACK_nomineeOfOneMandateCannotReachAnother() public {
        bytes32 guarded = _guarded();
        bytes32 unguarded = grant(simpleParams());

        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.revoke(unguarded);

        assertTrue(mm.isLive(unguarded), "the nominee reached a mandate they were not named on");
        assertTrue(mm.isLive(guarded), "the failed call disturbed the mandate they were named on");
    }

    /// Regression on the two callers v1 had. Adding a third term to an `&&` chain is exactly
    /// the edit that can invert one of the first two, and nothing else in this file would
    /// notice.
    function test_revoke_payerAndSpenderStillWork() public {
        bytes32 byPayer = _guarded();
        vm.prank(payer);
        mm.revoke(byPayer);
        assertFalse(mm.isLive(byPayer), "the payer lost the ability to revoke");

        bytes32 bySpender = _guarded();
        vm.prank(agent);
        mm.revoke(bySpender);
        assertFalse(mm.isLive(bySpender), "the spender lost the ability to revoke");
    }

    // -- containment: everything the nominee cannot do ------------------------
    //
    // The list from `revoke`'s NatSpec, one test each, every one ending on the payer's balance
    // and allowance. This is the section that decides whether F51 was worth doing: a role that
    // could reach any of these would be a second delegate rather than a kill switch.

    function test_revoker_ATTACK_cannotSpend() public {
        bytes32 id = _guarded();
        (uint256 bal, uint256 allow) = _payerState();

        vm.prank(guardian);
        vm.expectRevert(MandateManager.WrongSpender.selector);
        mm.spend(id, guardian, usd(1), REF, nextNonce());

        (uint256 bal2, uint256 allow2) = _payerState();
        assertEq(bal2, bal, "the payer's balance moved");
        assertEq(allow2, allow, "the allowance was consumed");
    }

    /// The same attempt after using the one power they have, because `spend`'s guard order puts
    /// `Revoked` above `WrongSpender` and a reader should be able to see both answers.
    function test_revoker_ATTACK_cannotSpendAfterRevoking() public {
        bytes32 id = _guarded();
        vm.prank(guardian);
        mm.revoke(id);
        (uint256 bal, uint256 allow) = _payerState();

        vm.prank(guardian);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.spend(id, guardian, usd(1), REF, nextNonce());

        (uint256 bal2, uint256 allow2) = _payerState();
        assertEq(bal2, bal, "the payer's balance moved");
        assertEq(allow2, allow, "the allowance was consumed");
    }

    /// Paying themselves is the attempt worth naming separately, since it is the only one with an
    /// obvious motive.
    function test_revoker_ATTACK_cannotPayThemselvesThroughAnotherMandate() public {
        _guarded();
        bytes32 open = grant(withRevoker(simpleParams(), guardian));
        (uint256 bal, uint256 allow) = _payerState();

        vm.prank(guardian);
        vm.expectRevert(MandateManager.WrongSpender.selector);
        mm.spend(open, guardian, usd(100), REF, nextNonce());

        (uint256 bal2, uint256 allow2) = _payerState();
        assertEq(bal2, bal, "the payer's balance moved");
        assertEq(allow2, allow, "the allowance was consumed");
    }

    function test_revoker_ATTACK_cannotApproveACosignature() public {
        bytes32 id = grant(withRevoker(withCosign(simpleParams(), boss, usd(10)), guardian));

        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosignFor(id, guardian, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));
    }

    function test_revoker_ATTACK_cannotWithdrawACosignature() public {
        bytes32 id = grant(withRevoker(withCosign(simpleParams(), boss, usd(10)), guardian));
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.withdrawCosign(id, hash, nonce);
        assertTrue(mm.isCosignApproved(id, hash), "the nominee removed the co-signer's approval");
    }

    /// "Cannot clear a reservation." The reservation is observable only through `spend` refusing
    /// on the reserved nonce, so that is what this asserts — and it asserts it after the failed
    /// call rather than trusting the revert.
    function test_revoker_ATTACK_cannotClearAReservation() public {
        bytes32 id = grant(withRevoker(withCosign(simpleParams(), boss, usd(10)), guardian));
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.clearReservation(id, nonce);

        // Still reserved: a one-unit spend on that nonce is refused, naming the approved hash.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.NonceReserved.selector, hash));
        mm.spend(id, vendor, 1, REF, nonce);
    }

    /// The payer can, which is F47's whole point, and is the comparison that makes the refusal
    /// above a limit on the nominee rather than a property of the function.
    function test_revoker_payerCanStillClearAReservation() public {
        bytes32 id = grant(withRevoker(withCosign(simpleParams(), boss, usd(10)), guardian));
        bytes32 nonce = nextNonce();

        vm.prank(boss);
        mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.prank(payer);
        mm.clearReservation(id, nonce);

        // Asserted rather than left to `payWithNonce` reverting on its own. A spend that returns
        // without moving money would satisfy the call and prove nothing, and the claim here is
        // that the nonce became spendable again — which is a balance, not an absence of a revert.
        uint256 before = token.balanceOf(vendor);
        payWithNonce(id, vendor, 1, nonce);
        assertEq(token.balanceOf(vendor), before + 1, "the released nonce did not pay");
        assertEq(mm.getMandate(id).totalSpent, 1, "the spend was not recorded against the mandate");
    }

    /**
     * The whole mutable surface, in one test, because two items on `revoke`'s list — "cannot
     * raise a cap" and "cannot add a recipient" — are claims about what this ABI does not
     * contain, and absence is not something a single call can demonstrate.
     *
     * There are seven state-changing external functions: `createMandate`, `spend`,
     * `revoke`, `setRevoker`, `approveCosignFor`, `withdrawCosign` and `clearReservation`. None of
     * them raises a cap or extends an allowlist for anyone, payer included — caps and allowlists
     * are written once in `createMandate` and never again. So this walks all seven as the
     * nominee and then reads back every field of the mandate, the allowlist answer for an address
     * that was never on it, the nomination itself, and the payer's two quantities. If some later
     * edit adds a mutator, this test is where the new reach shows up.
     *
     * The mandate is revoked first, deliberately. That is the state a nominee can actually put it
     * into, so it is the state their remaining reach has to be measured from, and it makes
     * `revoked` identical on both sides of the comparison instead of the one field allowed to
     * differ.
     */
    function test_revoker_ATTACK_theWholeMutableSurfaceMovesNothing() public {
        MandateManager.MandateParams memory p = withAllowlist(simpleParams(), vendor);
        p = withCosign(p, boss, usd(10));
        bytes32 id = grant(withRevoker(p, guardian));

        bytes32 nonce = nextNonce();
        vm.prank(boss);
        bytes32 hash = mm.approveCosignFor(id, vendor, usd(50), REF, nonce, uint40(block.timestamp + DAY));

        vm.prank(guardian);
        mm.revoke(id);

        MandateManager.Mandate memory before = mm.getMandate(id);
        (uint256 bal, uint256 allow) = _payerState();
        uint40 storedApproval = mm.cosignApprovalDeadline(id, hash);
        assertGt(uint256(storedApproval), 0, "precondition: the co-signer's approval is on record");
        assertFalse(mm.isAllowedRecipient(id, guardian), "precondition: the nominee is not on the allowlist");

        // 1 of 7. `createMandate` is not refused, and does not need to be: it records
        // `payer: msg.sender`, so what the nominee creates spends the nominee's own USDC and
        // reaches nothing here. The nomination is not a credential this function reads.
        MandateManager.MandateParams memory own = simpleParams();
        own.spender = other;
        vm.prank(guardian);
        bytes32 theirs = mm.createMandate(bytes32("guardians own"), own);
        assertEq(mm.getMandate(theirs).payer, guardian, "createMandate credited the wrong payer");

        // 2 of 7.
        vm.prank(guardian);
        vm.expectRevert(MandateManager.Revoked.selector);
        mm.spend(id, vendor, usd(1), REF, nextNonce());

        // 3 of 7. Permitted, and idempotent — the one power the role has, already used above.
        vm.prank(guardian);
        mm.revoke(id);

        // 4 of 7.
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.setRevoker(id, guardian2);

        // 5 of 7.
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.approveCosignFor(id, guardian, usd(50), REF, nextNonce(), uint40(block.timestamp + DAY));

        // 6 of 7.
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotCosigner.selector);
        mm.withdrawCosign(id, hash, nonce);

        // 7 of 7.
        vm.prank(guardian);
        vm.expectRevert(MandateManager.NotAuthorised.selector);
        mm.clearReservation(id, nonce);

        _assertMandateUnchanged(id, before);
        assertFalse(mm.isAllowedRecipient(id, guardian), "the nominee reached the allowlist");
        assertTrue(mm.isAllowedRecipient(id, vendor), "the sweep disturbed the allowlist");
        assertEq(mm.getRevoker(id), guardian, "the nomination itself changed");
        // The stored deadline, not the live answer. F35 folds the mandate's own death into
        // `isCosignApproved`, and this mandate is revoked, so that view reports false for a
        // reason the nominee had no part in. What the sweep is being held to is narrower: the
        // co-signer's record is exactly where the co-signer left it. Both reads are here so a
        // later change to either one has to come through this test.
        assertEq(
            uint256(mm.cosignApprovalDeadline(id, hash)),
            uint256(storedApproval),
            "the co-signer's stored approval changed"
        );
        assertFalse(mm.isCosignApproved(id, hash), "a revoked mandate must retire its approvals");

        (uint256 bal2, uint256 allow2) = _payerState();
        assertEq(bal2, bal, "the payer's balance moved");
        assertEq(allow2, allow, "the allowance was consumed");
    }

    /// Every field of the struct, named individually rather than compared as a blob, so a failure
    /// says which one moved. `assertEq` has no overload for a struct, and hashing the encoding
    /// would report only that something changed.
    function _assertMandateUnchanged(bytes32 id, MandateManager.Mandate memory before) internal view {
        MandateManager.Mandate memory now_ = mm.getMandate(id);
        assertEq(now_.payer, before.payer, "payer moved");
        assertEq(now_.spender, before.spender, "spender moved");
        assertEq(now_.cosigner, before.cosigner, "cosigner moved");
        assertEq(uint256(now_.perTxCap), uint256(before.perTxCap), "perTxCap moved");
        assertEq(uint256(now_.totalCap), uint256(before.totalCap), "totalCap moved");
        assertEq(uint256(now_.cosignThreshold), uint256(before.cosignThreshold), "cosignThreshold moved");
        assertEq(uint256(now_.totalSpent), uint256(before.totalSpent), "totalSpent moved");
        assertEq(uint256(now_.notBefore), uint256(before.notBefore), "notBefore moved");
        assertEq(uint256(now_.expiresAt), uint256(before.expiresAt), "expiresAt moved");
        assertEq(uint256(now_.spendCount), uint256(before.spendCount), "spendCount moved");
        assertEq(uint256(now_.flags), uint256(before.flags), "flags moved");
        assertEq(uint256(now_.windowCount), uint256(before.windowCount), "windowCount moved");
        assertEq(now_.revoked, before.revoked, "revoked moved");
    }

    // -- the case F51 exists for, and its two honest limits -------------------

    /**
     * The scenario, as far as this suite can reach it: a delegate spends, and the mandate dies
     * without the payer sending a transaction. After the grant the payer does not appear in this
     * test again.
     *
     * What cannot be reproduced here is the starvation itself. Foundry does not debit the caller's
     * balance for gas, so a payer with an empty balance revokes as happily as a funded one, and a
     * test that called `vm.deal(payer, 0)` and then watched the payer succeed would prove the
     * opposite of what it looked like it proved. The measurement that makes the problem real is on
     * Arc rather than in Solidity: 30,808 gas for the payer's revocation, recorded in
     * `evidence/revoke.log`, against a balance that is also the spending budget. F42 holds that
     * reasoning. What this test can show is that the escape works without the payer, which is the
     * half F51 adds.
     */
    function test_f51_theMandateDiesWithoutThePayerActing() public {
        bytes32 id = _guarded();
        pay(id, usd(100));
        pay(id, usd(100));
        assertGt(mm.spendable(id), 0, "precondition: there should be budget left to protect");

        vm.prank(guardian);
        mm.revoke(id);

        assertEq(mm.spendable(id), 0, "a revoked mandate still reports spendable budget");
        payReverts(id, usd(1), MandateManager.Revoked.selector);
    }

    /// The first honest limit: revocation stops the next spend and does not recover the last
    /// one. Nothing in this contract can, because the USDC left the payer's balance for the
    /// recipient's and neither address is ours to debit.
    function test_f51_revocationDoesNotRecoverWhatWasSpent() public {
        bytes32 id = _guarded();
        uint256 before = token.balanceOf(payer);
        pay(id, usd(100));
        uint256 afterSpend = token.balanceOf(payer);
        assertEq(afterSpend, before - usd(100), "precondition: the spend should have landed");

        vm.prank(guardian);
        mm.revoke(id);

        assertEq(token.balanceOf(payer), afterSpend, "revocation returned money it cannot reach");
        assertEq(token.balanceOf(vendor), usd(100), "the recipient's USDC moved");
    }

    /// The second honest limit: the role is named on one mandate, so it kills one mandate. The
    /// whole-account control is still the ERC-20 allowance, and setting it to zero is the payer's
    /// call — which is the sentence `IMMUTABILITY.md` already carries, and this is where it is
    /// checked rather than asserted.
    function test_f51_theAllowanceRemainsTheWholeAccountControl() public {
        bytes32 killed = _guarded();
        bytes32 survivor = grant(simpleParams());

        vm.prank(guardian);
        mm.revoke(killed);
        assertFalse(mm.isLive(killed), "the named mandate survived");
        assertTrue(mm.isLive(survivor), "the nominee reached a mandate they were not named on");
        pay(survivor, usd(1));

        vm.prank(payer);
        token.approve(address(mm), 0);
        // The refusal comes from USDC rather than from us, which is the point: the allowance is
        // the token's own record and no mandate can widen it. `MockUSDC` reverts where Circle's
        // implementation reverts, so the error named here is the mock's.
        payReverts(
            survivor,
            usd(1),
            abi.encodeWithSelector(MockUSDC.InsufficientAllowance.selector, uint256(0), uint256(usd(1)))
        );
    }
}
