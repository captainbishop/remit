// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {MockIdentityRegistry, MockValidationRegistry} from "./mocks/MockRegistries.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * Grant-time validation.
 *
 * Every check here exists because a malformed mandate is worse than a rejected one:
 * it looks like a bound and behaves like an absence. The model's equivalents are the
 * three `construction:` tests in policy.test.js, but the contract has strictly more
 * to validate, because it encodes "unset" as a zero value and therefore needs the
 * flags to agree with the values they describe.
 */
contract CreationTest is Base {
    // ---------------------------------------------------------------- drift

    /// The flag mirrors in Base must match the contract, or every flag-dependent
    /// test in this suite is testing the wrong bit while still passing.
    ///
    /// F44 added the last two assertions, and they are drift checks of the same kind one
    /// level up: `F_KNOWN` is the set `createMandate` accepts, so a future eighth flag added
    /// without widening the mask would be refused by the very path that introduces it, and no
    /// test of that flag on its own would say why.
    function test_flagConstants_matchTheContract() public view {
        assertEq(mm.F_PER_TX(), F_PER_TX, "F_PER_TX");
        assertEq(mm.F_TOTAL(), F_TOTAL, "F_TOTAL");
        assertEq(mm.F_COSIGN(), F_COSIGN, "F_COSIGN");
        assertEq(mm.F_EXPIRY(), F_EXPIRY, "F_EXPIRY");
        assertEq(mm.F_IDENTITY(), F_IDENTITY, "F_IDENTITY");
        assertEq(mm.F_CREDENTIAL(), F_CREDENTIAL, "F_CREDENTIAL");
        assertEq(mm.F_ALLOWLIST(), F_ALLOWLIST, "F_ALLOWLIST");

        uint8 declared = F_PER_TX | F_TOTAL | F_COSIGN | F_EXPIRY | F_IDENTITY | F_CREDENTIAL | F_ALLOWLIST;
        assertEq(mm.F_KNOWN(), declared, "F_KNOWN must be the OR of every flag the contract declares");
        assertEq(mm.F_KNOWN(), 0x7F, "and that is bits 0 through 6, leaving bit 7 outside the set");
    }

    /// The domain separator is mixed into every mandateId and every spend hash, so
    /// changing the string invalidates every id already issued without producing an
    /// error, and this test pins the value.
    function test_domainSeparator_isRemitV1() public view {
        assertEq(mm.DOMAIN(), keccak256("Remit:v1"), "DOMAIN must stay Remit:v1 once deployed");
    }

    function test_gasBounds_areWhatTheModelAssumes() public view {
        assertEq(mm.MAX_WINDOWS(), 4);
        assertEq(mm.MAX_BUCKETS(), 32);
    }

    // ------------------------------------------------------------ happy path

    function test_createMandate_storesEveryField() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.totalCap = usd(1000);
        p.flags |= F_TOTAL;
        bytes32 id = grant(p);

        MandateManager.Mandate memory m = mm.getMandate(id);
        assertEq(m.payer, payer, "payer");
        assertEq(m.spender, agent, "spender");
        assertEq(m.perTxCap, usd(100), "perTxCap");
        assertEq(m.totalCap, usd(1000), "totalCap");
        assertEq(m.cosigner, address(0), "cosigner");
        assertEq(m.cosignThreshold, 0, "cosignThreshold");
        assertEq(m.notBefore, 0, "notBefore");
        assertEq(m.expiresAt, FAR, "expiresAt");
        assertEq(m.totalSpent, 0, "totalSpent");
        assertEq(m.spendCount, 0, "spendCount");
        assertEq(m.windowCount, 1, "windowCount");
        assertEq(m.flags, F_PER_TX | F_EXPIRY | F_TOTAL, "flags");
        assertFalse(m.revoked, "revoked");

        MandateManager.WindowSpec memory w = mm.getWindow(id, 0);
        assertEq(w.lengthSeconds, DAY, "window length");
        assertEq(w.cap, usd(500), "window cap");
        assertEq(w.buckets, 12, "buckets");
        assertEq(w.subLength, DAY / 12, "subLength must be derived, not supplied");
    }

    function test_createMandate_emitsMandateCreated() public {
        MandateManager.MandateParams memory p = simpleParams();
        bytes32 expectedId = keccak256(abi.encode(mm.DOMAIN(), block.chainid, address(mm), payer, bytes32(uint256(1))));

        vm.expectEmit(true, true, true, true, address(mm));
        emit MandateManager.MandateCreated(expectedId, payer, agent, usd(100), 0, 0, FAR, F_PER_TX | F_EXPIRY, 1);

        vm.prank(payer);
        bytes32 id = mm.createMandate(bytes32(uint256(1)), p);
        assertEq(id, expectedId, "id must be predictable off-chain before the tx lands");
    }

    /// The id derivation is a public interface: a payer computes it locally to
    /// build the follow-up transaction before the grant has even confirmed.
    function test_mandateId_isDerivedFromDomainChainContractPayerAndSalt() public {
        bytes32 salt = keccak256("payroll-2026-Q3");

        vm.prank(payer);
        bytes32 id = mm.createMandate(salt, simpleParams());
        assertEq(id, keccak256(abi.encode(mm.DOMAIN(), block.chainid, address(mm), payer, salt)));

        // Same salt, different payer: must not collide.
        MandateManager.MandateParams memory p = simpleParams();
        vm.prank(other);
        bytes32 id2 = mm.createMandate(salt, p);
        assertTrue(id != id2, "two payers using the same salt must get different ids");
    }

    function test_createMandate_sameSaltTwice_reverts() public {
        bytes32 salt = keccak256("only-once");
        vm.prank(payer);
        mm.createMandate(salt, simpleParams());

        vm.prank(payer);
        vm.expectRevert(MandateManager.MandateExists.selector);
        mm.createMandate(salt, simpleParams());
    }

    // ----------------------------------------------------------- refusals

    /**
     * The whole point of the primitive — and NEW IN v2 it is narrower than it was.
     *
     * v1 accepted a `perTxCap` alone, or a window alone, as a sufficient bound. Neither
     * bounds LIFETIME exposure: a per-transaction cap is spent again, and again, until
     * the payer's allowance is dry, and a window is bounded per period and unbounded over
     * a lifetime. The contract's own comment claimed the opposite, so the sentence
     * promised more than the code delivered — F5 in THREAT-MODEL.md. Only `totalCap` and
     * `expiresAt` count now.
     *
     * The four refusals here and the three acceptances below mirror the model's
     * `construction: a mandate with no LIFETIME bound is refused, and a perTxCap is not
     * one` one for one; both were written from the same list.
     */
    function test_createMandate_withNoLifetimeBound_reverts() public {
        vm.startPrank(payer);

        // (1) Nothing at all. The only one of the four v1 also refused.
        vm.expectRevert(MandateManager.Unbounded.selector);
        mm.createMandate(bytes32("u1"), emptyParams());

        // (2) A per-transaction cap alone.
        MandateManager.MandateParams memory perTx = emptyParams();
        perTx.perTxCap = usd(100);
        perTx.flags = F_PER_TX;
        vm.expectRevert(MandateManager.Unbounded.selector);
        mm.createMandate(bytes32("u2"), perTx);

        // (3) A rolling window alone. This is the refusal that costs something; the
        // replacement shape is the third acceptance below.
        MandateManager.MandateParams memory win = emptyParams();
        win.windows = new MandateManager.WindowParams[](1);
        win.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(500), buckets: 12});
        vm.expectRevert(MandateManager.Unbounded.selector);
        mm.createMandate(bytes32("u3"), win);

        // (4) Both together, because two bounds that each fail to bound a lifetime do not
        // combine into one that does. Built fresh rather than by mutating `win`: a memory
        // struct assignment in Solidity copies the pointer, so `both = win` would have
        // edited case (3) as well, with no failing test to show it.
        MandateManager.MandateParams memory both = emptyParams();
        both.perTxCap = usd(100);
        both.flags = F_PER_TX;
        both.windows = new MandateManager.WindowParams[](1);
        both.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(500), buckets: 12});
        vm.expectRevert(MandateManager.Unbounded.selector);
        mm.createMandate(bytes32("u4"), both);

        vm.stopPrank();
    }

    /// The shapes that ARE bounded, granted rather than merely validated — a rule that
    /// only ever refuses is indistinguishable from one that refuses everything.
    function test_createMandate_aLifetimeBoundIsEitherATotalOrAnExpiry() public {
        // (1) A lifetime cap alone: no expiry, no window, no per-transaction cap.
        MandateManager.MandateParams memory total = emptyParams();
        total.totalCap = usd(1000);
        total.flags = F_TOTAL;
        assertTrue(mm.isLive(grant(total)), "a lifetime cap alone is a bound");

        // (2) An expiry alone is the case test_createMandate_expiryAloneIsEnoughOfABound
        //     below already pins, from the isLive side.

        // (3) A window plus an expiry — THE MIGRATION for every open-ended arrangement v1
        //     would have accepted. A subscription with a monthly window and no end date is
        //     no longer creatable as written; naming a distant horizon costs the payer
        //     nothing and makes the horizon explicit rather than absent.
        MandateManager.MandateParams memory sub = emptyParams();
        sub.windows = new MandateManager.WindowParams[](1);
        sub.windows[0] = MandateManager.WindowParams({lengthSeconds: 30 days, cap: usd(50), buckets: 30});
        sub.expiresAt = uint40(block.timestamp + 3650 days);
        sub.flags = F_EXPIRY;
        bytes32 id = grant(sub);
        assertTrue(mm.isLive(id), "window plus a distant expiry is the documented replacement");
        assertEq(mm.getMandate(id).windowCount, 1, "and it is still a windowed mandate");
    }

    /**
     * An `expiresAt` with F_EXPIRY unset is refused. NEW IN v2, F1 in THREAT-MODEL.md.
     *
     * v1 stored the value, emitted it in `MandateCreated`, and never read it — both
     * `spend` and `isLive` test the flag before comparing, so `getMandate` could show a
     * payer a mandate that expired last Tuesday and that spends forever. That is the
     * precise failure this primitive exists to prevent: a control that is displayed and
     * not enforced. The value and the flag now have to agree.
     *
     * One-directional rather than an iff, because with the flag SET the `expiresAt >
     * notBefore` rule already constrains the value. Only the flag-unset direction was
     * open.
     *
     * There is deliberately no mirror of this in reference/policy.js, and that is not an
     * omission. The model has no flags: `expiresAt: null` is the only way to say "no
     * expiry", so the value and the flag cannot disagree there. The contract needs the
     * rule because it encodes "unset" as a zero in a field of its own.
     */
    function test_createMandate_expiresAtWithoutTheFlag_reverts() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.totalCap = usd(1000); // a real lifetime bound, so Unbounded() is not what fires
        p.flags = F_TOTAL;
        p.expiresAt = uint40(block.timestamp + 1 days); // ...but F_EXPIRY stays unset
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("x1"), p);

        // Zero with the flag unset stays legal, because that is how "no expiry" is
        // spelled — and it must not be read as "expired at the epoch", which is what a
        // guard written as an iff would have produced.
        p.expiresAt = 0;
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).expiresAt, 0, "no expiry is still expressible");
        assertTrue(mm.isLive(id), "and the mandate is live rather than instantly expired");
    }

    function test_createMandate_expiryAloneIsEnoughOfABound() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_EXPIRY;
        bytes32 id = grant(p);
        assertTrue(mm.isLive(id), "a time-boxed mandate is bounded, even with no cap");
    }

    function test_createMandate_zeroSpender_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.spender = address(0);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("z"), p);
    }

    /**
     * The same requirement, arranged so that only the intended guard can satisfy it.
     *
     * The test above passed for two reasons at once, which is one too many. Removing the
     * zero-spender check at the top of `createMandate` leaves it green, because a mandate
     * with no spender and no cosigner has `cosigner == spender` — both are the zero
     * address — so the self-cosigner rule further down refuses it under the same
     * `BadConfig` selector. The mutation gate is what surfaced that: 20 of the 21
     * refusals in `createMandate` failed a named test when removed, and this was the one
     * that did not.
     *
     * The contract states the dependency itself, in the comment above the self-cosigner
     * rule: that rule is written unconditionally because `spender == address(0)` "was
     * refused at the top". The two guards lean on each other, and a test that cannot
     * tell them apart is not holding either one in place.
     *
     * Naming a real cosigner separates them. Now `cosigner != spender`, the self-cosigner
     * rule has nothing to say, and the only thing left that can refuse a zero spender is
     * the guard this test is about.
     *
     * What the guard prevents is narrower than it looks, since a mandate with no spender is
     * unspendable either way — `msg.sender` is never the zero address. It prevents a
     * grant that reads as live and can never be used: `isLive` returns true, `getMandate`
     * shows caps and a window, and every spend refuses. That is the shape this contract
     * rejects everywhere else rather than documenting.
     */
    function test_createMandate_zeroSpenderWithACosigner_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCosign(p, boss, usd(10)); // a cosigner who is not the spender
        p.spender = address(0);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("z2"), p);
    }

    /**
     * F48. This contract as its own spender, refused for the reason the guard above is refused
     * and the reason F45 refuses an expiry already in the past: the payer would be buying
     * authority no caller can ever exercise, and paying a permanent cost for it.
     *
     * `spend` requires `msg.sender == m.spender` and no path in this contract calls `spend`, so
     * such a mandate answers `WrongSpender` on every attempt for its whole life. The permanent
     * part is the salt: `mandateId` is derived from (payer, salt), `revoke` never frees it, and
     * `MandateExists` refuses a second grant under the same value — so the payer cannot even
     * retry with a corrected spender under the salt they meant to use.
     *
     * Narrow on purpose, and the second half of this test is what pins that. The other three
     * addresses `_isUndebitable` refuses as RECIPIENTS stay legal as spenders, because that test
     * asks whether money sent somewhere can come back, which is a different question. Either
     * ERC-8004 registry sits behind an upgradeable proxy that could one day hold an
     * implementation calling `spend`, so refusing them here would refuse a configuration that
     * could work.
     */
    function test_f48_theContractAsItsOwnSpender_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.spender = address(mm);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("z3"), p);

        // And the guard reaches exactly one address. The token and both registries are accepted
        // here, which is the same set `test_f43_allowlistRefusesEveryAddressTheEnforcerRefuses`
        // shows being refused on the recipient side.
        address[3] memory stillLegal = [address(token), address(identity), address(validation)];
        for (uint256 i = 0; i < stillLegal.length; i++) {
            MandateManager.MandateParams memory q = simpleParams();
            q.spender = stillLegal[i];
            vm.prank(payer);
            bytes32 id = mm.createMandate(bytes32(uint256(0xf48) + i), q);
            assertEq(mm.getMandate(id).spender, stillLegal[i], "refused as a recipient, legal as a spender");
        }
    }

    /**
     * Each flag must agree with the value it describes, in BOTH directions. A flag
     * set with a zero value would be a bound that never binds; a value set with no
     * flag would be a limit that is never read. Both are the failure mode this
     * primitive exists to prevent, so both revert.
     */
    function test_createMandate_flagWithoutValue_reverts() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.flags = F_PER_TX; // but perTxCap stays 0
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags |= F_EXPIRY;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("a"), p);
    }

    function test_createMandate_valueWithoutFlag_reverts() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.perTxCap = usd(100); // but F_PER_TX is not set
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_EXPIRY;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("b"), p);
    }

    function test_createMandate_totalCapFlagMismatch_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.totalCap = usd(1000); // no F_TOTAL
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("c"), p);
    }

    /// The model's "cosignThreshold without a cosigner is refused", inverted: here
    /// the flag and the cosigner address are what must agree.
    function test_createMandate_cosignFlagWithoutCosigner_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.flags |= F_COSIGN;
        p.cosignThreshold = usd(10);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("d"), p);
    }

    function test_createMandate_cosignerWithoutFlag_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.cosigner = boss;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("e"), p);
    }

    /**
     * The credential mirror of the two tests above, and the one agreement rule in
     * `createMandate` that had no revert test at all.
     *
     * Reading the suite would not have shown this. `forge coverage` reports the contract
     * at 100% of lines and 99.10% of branches, and the single unreached branch in the
     * whole file was the revert arm of the credential rule. Its four neighbours — per-tx,
     * total, cosigner, allowlist — each had at least one test that fired them; this one
     * had none. A missing negative test is invisible to a green suite by construction,
     * since nothing fails.
     *
     * It also mattered more than the other four, because Gates.t.sol argues that the
     * documented no-agent-binding weakness stays bounded partly on the strength of
     * "F_CREDENTIAL without a validator is refused at grant time". That claim was true and
     * unpinned until this test pinned it.
     *
     * Both directions are checked. A flag with no validator would be a check that never
     * runs while `getMandate` shows one. A validator with no flag is the shape that
     * misleads a reader in the other direction: an address sits in the struct, and
     * `spend` never consults it.
     */
    function test_createMandate_credentialFlagWithoutValidator_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, address(0), KYC_HASH, AGENT_ID, 1 days);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("cr1"), p);
    }

    function test_createMandate_validatorWithoutTheFlag_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.credential.validator = boss; // ...and F_CREDENTIAL stays unset
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("cr2"), p);
    }

    // ------------------------------------ the cosign requirement as a whole
    //
    // NEW IN v2. The two tests above check the flag against the cosigner ADDRESS, which
    // is where v1 stopped. Enumerating the question properly — in how many ways can a
    // mandate display a co-signature requirement and not have one? — turned up three
    // more, and `getMandate` is honest about none of them: it returns a populated
    // cosigner and a plausible threshold in every case. The changelist named only the
    // third, and named it wrongly.

    /// A threshold with no requirement behind it: the field is stored, a reader sees a
    /// number, and no spend is ever measured against it. This is deliberately kept out of
    /// the biconditional on the address, because zero is MEANINGFUL when F_COSIGN is set —
    /// it means every spend needs a signature, since the check tests `amount > threshold`
    /// strictly and an amount is at least 1. The threshold therefore gets a
    /// one-directional rule where the address gets an iff.
    function test_createMandate_thresholdWithoutCosignFlag_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.cosignThreshold = usd(10); // F_COSIGN not set, cosigner still zero
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct1"), p);
    }

    /**
     * The agent may not be its own cosigner — the worst of the three, and the one that
     * was on no list anywhere.
     *
     * `approveCosign` authorises on `msg.sender == m.cosigner` and nothing else, so a
     * mandate whose cosigner is its spender lets the agent approve its own spend hash and
     * then spend it, taking two transactions instead of one with no second party anywhere.
     * That is the absence of a control wearing the clothes of one, and it is exactly as
     * invisible in `getMandate` as a supervised mandate would be.
     *
     * The distinction that makes this a rule rather than an over-reach: `cosigner ==
     * payer` is legitimate and stays legal, because the payer is a second party to the
     * agent. It is what live mandate 2 does on Arc today, so refusing it would have
     * condemned a configuration this repository has receipts for.
     */
    function test_createMandate_spenderAsItsOwnCosigner_reverts() public {
        MandateManager.MandateParams memory p = withCosign(simpleParams(), agent, usd(10));
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct2"), p);

        // The payer cosigning for its own agent is the ordinary case.
        bytes32 id = grant(withCosign(simpleParams(), payer, usd(10)));
        assertEq(mm.getMandate(id).cosigner, payer);
    }

    /**
     * The requirement must be able to FIRE, measured against the whole policy.
     *
     * `spend` demands a signature when `amount > cosignThreshold`, strictly, so the
     * requirement is dead unless the policy permits at least one amount above the threshold:
     *
     *   effectiveMax = min(2^96 - 1, perTxCap if F_PER_TX, totalCap if F_TOTAL, every
     *                      window cap)   and the grant is refused when
     *   effectiveMax <= cosignThreshold
     *
     * WHY THE CHANGELIST'S CONDITION WAS WRONG TWICE. It proposed `perTxCap <
     * cosignThreshold`. The comparison is backwards — equality is dead too, and this
     * repository already held the receipt for that, at `DESIGN.md:981`, where a 50,000
     * spend against a 50,000 threshold did not trip the requirement on Arc Testnet.
     * `perTxCap` is also not the only ceiling, so the check misses whole families of
     * dead configuration. `L3-VAULT.md` inherited the same error from the changelist.
     */
    function test_createMandate_deadCosignGate_perTxCapBoundaryIsExact() public {
        MandateManager.MandateParams memory p = withCosign(simpleParams(), boss, usd(100));
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct3"), p); // perTxCap 100 == threshold 100: dead

        // One base unit lower and the requirement is alive, which is what makes the bound
        // exact rather than merely conservative. A guard written with `<` would accept the
        // case above and this one, and the difference between them is the entire point.
        bytes32 id = grant(withCosign(simpleParams(), boss, usd(100) - 1));
        bytes32 nonce = nextNonce();
        bytes32 hash = mm.spendHash(id, vendor, usd(100), REF, nonce);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MandateManager.CosignRequired.selector, hash));
        mm.spend(id, vendor, usd(100), REF, nonce);
    }

    /// With no per-transaction cap the LIFETIME cap binds. This shape passes both
    /// spellings of the naive check for the same reason: `perTxCap` is absent entirely,
    /// so a condition phrased against it compares zero to a threshold and concludes the
    /// requirement is fine. Evaluated at `totalSpent == 0` because reachability asks
    /// whether the requirement can EVER fire, and a lifetime cap is loosest on the first
    /// spend.
    function test_createMandate_deadCosignGate_lifetimeCapBinds() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.totalCap = usd(100);
        p.flags = F_TOTAL;
        p = withCosign(p, boss, usd(100));
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct4"), p);
    }

    /// A window cap binds in the same way — as a MINIMUM over the windows, not the first
    /// or the last of them, and the minimum crosses cap KINDS: a generous per-transaction
    /// cap does not rescue a threshold the tightest window has already put out of reach.
    function test_createMandate_deadCosignGate_windowCapBinds() public {
        vm.startPrank(payer);

        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct5"), withCosign(windowOnlyParams(DAY, usd(40), 12), boss, usd(40)));

        // Two windows, the tighter one second, so a guard that read only `windows[0]`
        // would let this through.
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](2);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: WEEK, cap: usd(900), buckets: 7});
        p.windows[1] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(40), buckets: 12});
        p = withExpiry(p); // or Unbounded() fires first and the assertion below proves nothing
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct6"), withCosign(p, boss, usd(40)));

        // Across kinds: perTxCap 1000 is irrelevant once a 40 window exists.
        MandateManager.MandateParams memory q = emptyParams();
        q.perTxCap = usd(1000);
        q.flags = F_PER_TX;
        q.windows = new MandateManager.WindowParams[](1);
        q.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(40), buckets: 12});
        q = withExpiry(q);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct7"), withCosign(q, boss, usd(100)));

        vm.stopPrank();
    }

    /**
     * The UNBOUNDED-AMOUNT case must still be accepted, and the ceiling term is why the
     * check is not simply a loop over the caps the payer set.
     *
     * A mandate bounded only by an expiry has no amount cap at all, so every threshold
     * below the uint96 ceiling is reachable and the grant is fine. The ceiling ITSELF is
     * not reachable, because `spend` refuses amounts above it outright with
     * `AmountTooLarge` — the bound exists even where the payer set none. That term has no
     * analogue in a specification with arbitrary-precision integers, which is precisely
     * the class of rule the reference model cannot be trusted to have invented on its
     * own; it was added to `reference/policy.js` from this direction, not the reverse.
     */
    function test_createMandate_deadCosignGate_unboundedAmountIsStillAccepted() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.expiresAt = uint40(block.timestamp + 1 days);
        p.flags = F_EXPIRY;

        bytes32 id = grant(withCosign(p, boss, usd(1_000_000)));
        assertEq(mm.getMandate(id).cosignThreshold, usd(1_000_000), "no amount cap: any real threshold is reachable");

        vm.startPrank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct8"), withCosign(p, boss, type(uint96).max));

        // One below it is fine, so this boundary is exact too.
        mm.createMandate(bytes32("ct9"), withCosign(p, boss, type(uint96).max - 1));
        vm.stopPrank();
    }

    function test_createMandate_allowlistFlagMismatch_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.flags |= F_ALLOWLIST; // empty allowlist
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("f"), p);
    }

    function test_createMandate_zeroAddressInAllowlist_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.allowlist = new address[](2);
        p.allowlist[0] = vendor;
        p.allowlist[1] = address(0);
        p.flags |= F_ALLOWLIST;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("g"), p);
    }

    /**
     * Both bounds sit in the FUTURE, and that placement is the substance of this test.
     *
     * F45's clock guard sits immediately below the ordering guard and refuses any `expiresAt`
     * at or before `block.timestamp` under the same `BadConfig` name. This test used to name
     * 2000 for both fields, against a suite whose clock starts at 1,000,000 — so once F45
     * landed, the clock guard answered first and the expectation was satisfied whether the
     * ordering guard existed or not. The mutation gate is what showed it: deleting the
     * ordering guard left this test green, on a run where the other 28 mutants all failed a
     * named test. The contract was never wrong; the evidence for one of its lines was.
     *
     * Ahead of the clock, only the ordering guard can refuse these params, and it is the only
     * line in `createMandate` that reads `notBefore` at all. Keep the pair in the future.
     */
    function test_createMandate_expiryNotAfterNotBefore_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        uint40 t = uint40(block.timestamp + DAY);
        p.notBefore = t;
        p.expiresAt = t; // exclusive expiry means this window is empty
        p.flags |= F_EXPIRY;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("h"), p);

        // One second of window and the same mandate is granted, which is what makes the
        // refusal above evidence about the ordering rule rather than about these params being
        // unacceptable for some other reason. `isLive` is deliberately not asserted: the start
        // is still ahead of the clock, so a live mandate is not what this shape should produce.
        p.expiresAt = t + 1;
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).expiresAt, t + 1, "a non-empty window is written as given");
    }

    /// minResponse of 0 would accept a FAILED attestation, since ERC-8004 uses 0
    /// for a negative result. A credential check that accepts failure enforces nothing.
    function test_createMandate_credentialWithZeroMinResponse_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, AGENT_ID, 0);
        p.credential.minResponse = 0;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("i"), p);
    }

    /// F34, the other end of the same field. ERC-8004 puts a pass at 100, so a threshold above
    /// it refuses every attestation the standard can produce and the mandate is born dead —
    /// while reading, at the call site, like a payer being extra careful.
    function test_createMandate_credentialMinResponseAboveThePassScore_reverts() public {
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0);
        p.credential.minResponse = 101;
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// Exactly 100 stays creatable, so the bound above refuses the unmeetable values without
    /// taking the ordinary one with it.
    function test_createMandate_credentialMinResponseAtThePassScore_isAccepted() public {
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0);
        p.credential.minResponse = 100;
        bytes32 id = grant(p);
        assertTrue(mm.isLive(id));
    }

    /// F34. Zero is an occupied key on Arc Testnet, not an empty one: the live probe recorded in
    /// `mocks/MockRegistries.sol` found a real record filed under `bytes32(0)`. A mandate keyed
    /// there reads whatever a stranger filed, which is `CredentialWrongValidator` on every spend
    /// in the ordinary case and a failed attestation about an unnamed agent in the worst one.
    function test_createMandate_credentialWithZeroRequestHash_reverts() public {
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0);
        p.credential.requestHash = bytes32(0);
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// F32. `flags` is caller-supplied and nothing tied it to the structs, so a payer who filled
    /// the identity gate and forgot its flag got a mandate with no identity gate at all: the
    /// data was dropped on the floor here, and `MandateCreated` reports flags rather than
    /// fields, so the receipt gave no sign that the identity gate was missing.
    function test_createMandate_identityDataWithoutTheFlag_reverts() public {
        MandateManager.MandateParams memory p = withIdentity(simpleParams(), AGENT_ID, agent);
        p.flags &= ~F_IDENTITY; // the struct stays filled; only the bit is gone
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The credential half of the same mistake, and it is refused one guard earlier than the
    /// identity half is: the `F_CREDENTIAL` biconditional further up sees the validator that
    /// `withCredential` sets. The test below reaches the F32 credential block itself.
    function test_createMandate_credentialDataWithoutTheFlag_reverts() public {
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days);
        p.flags &= ~F_CREDENTIAL;
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The credential half again, with the biconditional avoided. That line reads
    /// `(flags & F_CREDENTIAL != 0) != (p.credential.validator != address(0))`, and
    /// `withCredential` always sets a validator, so the test above is refused there rather than
    /// by the F32 block. Both lines revert `BadConfig`, so the assertion held while the F32
    /// credential guard had nothing behind it: the mutation gate deleted that guard and all 207
    /// tests still passed.
    ///
    /// The four fields below are the ones only F32 can refuse. Each is set on its own, with the
    /// validator left at zero, so the F32 block is the only line in `createMandate` that can
    /// answer. One field at a time also means a condition that dropped any single disjunct would
    /// leave one of these four cases passing.
    ///
    /// `test_createMandate_noGateDataAndNoGateFlags_isAccepted` below is the control: without it
    /// these four refusals would also pass against a `createMandate` that refused every grant.
    function test_createMandate_eachCredentialFieldWithoutTheFlag_isRefused() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.credential.requestHash = KYC_HASH;
        grantReverts(p, MandateManager.BadConfig.selector);

        p = simpleParams();
        p.credential.agentId = AGENT_ID;
        grantReverts(p, MandateManager.BadConfig.selector);

        p = simpleParams();
        p.credential.maxStaleness = 1 days;
        grantReverts(p, MandateManager.BadConfig.selector);

        p = simpleParams();
        p.credential.minResponse = 100;
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The ordinary case is untouched: a mandate with neither identity nor credential
    /// data, and neither flag set, is still creatable. Without this the two tests above
    /// would also pass against a `createMandate` that refused every grant.
    function test_createMandate_noGateDataAndNoGateFlags_isAccepted() public {
        bytes32 id = grant(simpleParams());
        assertTrue(mm.isLive(id));
    }

    /// A requirement that cannot be evaluated must not be grantable, or the mandate
    /// displays a control the contract will never enforce.
    function test_createMandate_gateWithoutRegistry_reverts() public {
        MandateManager bare = new MandateManager(address(token), address(0), address(0));

        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, AGENT_ID, 0);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        bare.createMandate(bytes32("j"), p);

        MandateManager.MandateParams memory q = simpleParams();
        q = withIdentity(q, AGENT_ID, agent);
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        bare.createMandate(bytes32("k"), q);
    }

    function test_constructor_zeroUsdc_reverts() public {
        vm.expectRevert(MandateManager.BadConfig.selector);
        new MandateManager(address(0), address(identity), address(validation));
    }

    /**
     * F49. A registry address that holds no code is refused at construction, in both positions.
     *
     * Zero and non-zero-with-no-code look alike and mean opposite things. Zero says the ERC-8004
     * lookups are unavailable, and `createMandate` refuses every flag that needs one — the case
     * `test_createMandate_gateWithoutRegistry_reverts` above covers. Non-zero with no code says the
     * opposite while meaning the same thing: the grant succeeds, and the first spend reaches a
     * STATICCALL that returns zero bytes.
     *
     * Refusing it early matters because `catch` does not cover it. Solidity's `catch`
     * runs when the call itself failed; here the call SUCCEEDS and the revert happens while ABI
     * decoding zero bytes into the declared return type, inside this contract's own frame and past
     * the catch arm. So the spend is refused either way, and the difference is `IdentityNotHeld` or
     * `CredentialMissing` against a revert carrying no selector at all — nothing an agent can read.
     *
     * At construction rather than at grant time because these addresses are immutable: past the
     * constructor the only remedy is a fresh deployment. `script/Deploy.s.sol` runs the same
     * check, and that copy protects only deployments that use the script.
     */
    function test_f49_aRegistryWithNoCode_isRefusedAtConstruction() public {
        address codeless = makeAddr("codeless registry");
        assertEq(codeless.code.length, 0, "the premise of this test");

        vm.expectRevert(abi.encodeWithSelector(MandateManager.RegistryHasNoCode.selector, codeless));
        new MandateManager(address(token), codeless, address(validation));

        vm.expectRevert(abi.encodeWithSelector(MandateManager.RegistryHasNoCode.selector, codeless));
        new MandateManager(address(token), address(identity), codeless);

        // Both guards are separate statements, so a deployment with two codeless addresses is
        // named by the first one. Asserted because the error carries the address, and an operator
        // reading it needs to know it names one of possibly two mistakes.
        vm.expectRevert(abi.encodeWithSelector(MandateManager.RegistryHasNoCode.selector, codeless));
        new MandateManager(address(token), codeless, makeAddr("also codeless"));
    }

    /// The other two branches of the same pair of guards, so neither is over-broad: zero passes,
    /// because it is how a deployer says the lookups are unavailable, and a real contract passes.
    /// Without this half, a guard rewritten as `!= address(0)` alone would still look tested.
    function test_f49_zeroAndRealRegistriesAreBothAccepted() public {
        MandateManager bare = new MandateManager(address(token), address(0), address(0));
        assertEq(address(bare.identityRegistry()), address(0), "zero is a legal deployment");
        assertEq(address(bare.validationRegistry()), address(0));

        MandateManager full = new MandateManager(address(token), address(identity), address(validation));
        assertEq(address(full.identityRegistry()), address(identity));
        assertEq(address(full.validationRegistry()), address(validation));

        // And the third address gets no code check at all, which is the omission the constructor
        // argues for rather than an oversight: on Arc the token is the precompile at
        // 0x3600...0000, where the ERC-20 surface comes from the node instead of from deployed
        // bytecode, so a code test there could refuse the one deployment that matters. A codeless
        // token fails on the first `transferFrom` instead, before any funds move.
        address codelessToken = makeAddr("codeless token");
        MandateManager loose = new MandateManager(codelessToken, address(identity), address(validation));
        assertEq(address(loose.usdc()), codelessToken, "F24: deliberately not checked here");
    }

    // ------------------------------------------------------- window shape

    /// Sub-periods must be uniform, so the length has to divide evenly. The model
    /// throws on this too — it is the one construction rule shared verbatim.
    function test_createMandate_windowLengthNotDivisibleByBuckets_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w1"), windowOnlyParams(100, usd(1), 12));
    }

    function test_createMandate_zeroLengthOrCapOrBuckets_reverts() public {
        vm.startPrank(payer);
        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w2"), windowOnlyParams(0, usd(1), 12));

        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w3"), windowOnlyParams(DAY, 0, 12));

        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w4"), windowOnlyParams(DAY, usd(1), 0));
        vm.stopPrank();
    }

    /// MAX_BUCKETS and MAX_WINDOWS are the only things keeping the gas cost of a
    /// spend independent of untrusted grant-time input, so they are hard limits.
    /// 36 is used rather than 33 because 86400 % 36 == 0 — that isolates the
    /// bucket-count check instead of also tripping the divisibility check, which
    /// raises the same error and would make this test prove nothing.
    function test_createMandate_tooManyBuckets_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w5"), windowOnlyParams(DAY, usd(1), 36));
    }

    function test_createMandate_tooManyWindows_reverts() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](5);
        for (uint256 i = 0; i < 5; ++i) {
            p.windows[i] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(100), buckets: 12});
        }
        p = withExpiry(p); // or Unbounded() fires before the window count is even read
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadWindow.selector);
        mm.createMandate(bytes32("w6"), p);
    }

    function test_createMandate_fourWindows_isAccepted() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](4);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: 3600, cap: usd(50), buckets: 6});
        p.windows[1] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(200), buckets: 12});
        p.windows[2] = MandateManager.WindowParams({lengthSeconds: WEEK, cap: usd(800), buckets: 7});
        p.windows[3] = MandateManager.WindowParams({lengthSeconds: 30 days, cap: usd(2000), buckets: 30});
        p = withExpiry(p); // v2: four windows are still not a lifetime bound
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).windowCount, 4);
    }

    // --------------------------------------------------- F44: the flag mask

    /**
     * F44. A flags word carrying bit 7 is refused.
     *
     * `flags` is a uint8 with seven meanings, so bit 7 could be set, stored verbatim, returned
     * by `getMandate` and read by nothing. Every rule in this file exists to stop a mandate
     * whose display and whose enforcement disagree, and an inert eighth bit is that shape with
     * no field of its own to lie about.
     *
     * It is refused rather than masked away because this contract is immutable and its
     * mandates are permanent. The note in `createMandate` earmarks bit 7 for a merkle
     * allowlist in a later version, so a mandate created today with bit 7 set would read to
     * that version as carrying a check this one never applied, and there is no later pass that
     * could correct it.
     */
    function test_f44_unknownFlagBit_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.flags |= 0x80;
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The same word without bit 7 is accepted, so the guard refuses the bit rather than the
    /// mandate — and the stored value is checked, because what F44 protects is what
    /// `getMandate` reports.
    function test_f44_theSameMandateWithoutBit7_isAccepted() public {
        MandateManager.MandateParams memory p = simpleParams();
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).flags, p.flags, "the seven live bits are stored as given");
        assertEq(mm.getMandate(id).flags & 0x80, 0, "and bit 7 is not among them");
    }

    /// Bit 7 on its own is refused by the mask and not by `Unbounded`, which would fire on the
    /// same params if the mask ran later. That ordering is the assertion: the mask sits above
    /// every rule that reads the word, so nothing below it has to reason about the extra bit.
    function test_f44_bit7Alone_isRefusedByTheMaskNotByUnbounded() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.flags = 0x80;
        grantReverts(p, MandateManager.BadConfig.selector);

        // The same params with the bit cleared reach `Unbounded`, which is what makes the line
        // above evidence about the mask instead of a coincidence with a check further down.
        p.flags = 0;
        grantReverts(p, MandateManager.Unbounded.selector);
    }

    // ------------------------------------------------- F45: born expired

    /**
     * F45. A mandate whose expiry has already gone by is refused at creation.
     *
     * The paired guard beside it orders `expiresAt` after `notBefore` and says nothing about
     * the clock, so both values could sit in the past. What that produces reverts `Expired` on
     * its first spend and on every later one: authority that was never exercisable for a
     * single block.
     *
     * The cost of accepting it is more than a wasted grant. The (payer, salt) slot is consumed
     * permanently and `revoke` never clears it, so the payer cannot re-issue the mandate they
     * meant under the same salt, and anything pinned off-chain to that id has to be re-cut.
     * This is the rule F17 applies to a co-signature, applied one level up — an object no later
     * call could accept is refused where it would be created.
     */
    function test_f45_expiryAlreadyPast_reverts() public {
        MandateManager.MandateParams memory p = simpleParams(); // already carries F_EXPIRY
        p.expiresAt = uint40(block.timestamp - 1);
        grantReverts(p, MandateManager.BadConfig.selector);
    }

    /// The boundary. `expiresAt` is exclusive, so a mandate dying at the current second is
    /// already dead and is refused, while one second later is alive however briefly and is
    /// accepted. Refusing the second case would be the contract deciding how short a mandate a
    /// payer is allowed to want.
    function test_f45_theBoundaryIsTheCurrentSecond() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.expiresAt = uint40(block.timestamp);
        grantReverts(p, MandateManager.BadConfig.selector);

        p.expiresAt = uint40(block.timestamp + 1);
        bytes32 id = grant(p);
        assertTrue(mm.isLive(id), "one second of life is still life");
    }

    /// The guard is conditioned on the flag, and this is the test that says so. With `F_EXPIRY`
    /// unset the field must be zero, which the mirror beside F45 enforces — so a version of
    /// F45 that dropped its flag term would read `0 <= block.timestamp`, hold for every clock,
    /// and refuse every expiry-free mandate ever granted. The warp makes the clock large enough
    /// that no smaller reading of the comparison could pass by accident.
    function test_f45_doesNotReachAMandateWithNoExpiry() public {
        vm.warp(block.timestamp + 3650 days);
        MandateManager.MandateParams memory p = emptyParams();
        p.totalCap = usd(100);
        p.flags = F_TOTAL;
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).expiresAt, 0, "no expiry, so F45 had no field to test");
        assertTrue(mm.isLive(id), "and the mandate is live");
    }

    // ----------------------------------------- F43: the allowlist writer

    /**
     * F43. The allowlist writer refuses every address the enforcer refuses.
     *
     * `spend` and `isAllowedRecipient` reject six addresses outright: the zero address, the
     * payer, and the four in `_isUndebitable` — this contract, the token, and both ERC-8004
     * registries. The writer used to reject one of the six, so the other five could be stored
     * as a `true` that no spend could honour. F29 put the payer and two undebitable addresses
     * on the enforcer's list and F38 widened that list to four; neither pass came back to the
     * writer, so the two sets drifted apart at the commit meant to make them agree.
     *
     * The harm is a mandate the payer cannot use. An allowlist holding only refusable addresses
     * grants authority over no address the contract will pay, and the salt is consumed proving it.
     *
     * `vendor` sits first in every list below so the refusal is observably about the second
     * entry rather than about the list existing at all.
     */
    function test_f43_allowlistRefusesEveryAddressTheEnforcerRefuses() public {
        address[6] memory refused =
            [address(0), payer, address(mm), address(token), address(identity), address(validation)];

        for (uint256 i = 0; i < refused.length; ++i) {
            MandateManager.MandateParams memory p = simpleParams();
            p.allowlist = new address[](2);
            p.allowlist[0] = vendor;
            p.allowlist[1] = refused[i];
            p.flags |= F_ALLOWLIST;
            grantReverts(p, MandateManager.BadConfig.selector);
        }
    }

    /// The other half of the agreement. For each of the six the enforcer says no as well, so the
    /// writer now refuses what a spend would have refused rather than a set of its own. Read
    /// through `isAllowedRecipient` on a mandate carrying no allowlist, which is the widest
    /// configuration there is — a `false` there can only have come from the six.
    function test_f43_theEnforcerRefusesTheSameSix() public {
        bytes32 id = grant(simpleParams()); // no F_ALLOWLIST, so every other address is payable
        assertTrue(mm.isAllowedRecipient(id, vendor), "the control: an ordinary address is payable");

        address[6] memory refused =
            [address(0), payer, address(mm), address(token), address(identity), address(validation)];
        for (uint256 i = 0; i < refused.length; ++i) {
            assertFalse(mm.isAllowedRecipient(id, refused[i]), "the enforcer must refuse it too");
        }
    }

    /// And the writer refuses nothing beyond the six. An ordinary list is written, readable
    /// afterwards and spendable against, so F43 narrowed what the writer rejects without
    /// narrowing the feature.
    function test_f43_anOrdinaryAllowlistIsStillWritten() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.allowlist = new address[](2);
        p.allowlist[0] = vendor;
        p.allowlist[1] = other;
        p.flags |= F_ALLOWLIST;
        bytes32 id = grant(p);

        assertTrue(mm.isAllowedRecipient(id, vendor), "the first entry was written");
        assertTrue(mm.isAllowedRecipient(id, other), "and the second");
        assertFalse(mm.isAllowedRecipient(id, boss), "and nothing else was");
        payTo(id, vendor, usd(10));
    }
}
