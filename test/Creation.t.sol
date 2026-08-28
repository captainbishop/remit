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
    function test_flagConstants_matchTheContract() public view {
        assertEq(mm.F_PER_TX(), F_PER_TX, "F_PER_TX");
        assertEq(mm.F_TOTAL(), F_TOTAL, "F_TOTAL");
        assertEq(mm.F_COSIGN(), F_COSIGN, "F_COSIGN");
        assertEq(mm.F_EXPIRY(), F_EXPIRY, "F_EXPIRY");
        assertEq(mm.F_IDENTITY(), F_IDENTITY, "F_IDENTITY");
        assertEq(mm.F_CREDENTIAL(), F_CREDENTIAL, "F_CREDENTIAL");
        assertEq(mm.F_ALLOWLIST(), F_ALLOWLIST, "F_ALLOWLIST");
    }

    /// The domain separator is mixed into every mandateId and every spend hash, so
    /// changing the string silently invalidates every id already issued. Pin it.
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
        bytes32 expectedId =
            keccak256(abi.encode(mm.DOMAIN(), block.chainid, address(mm), payer, bytes32(uint256(1))));

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
        // silently edited case (3) as well.
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
     * `spend` and `isLive` gate the comparison on the flag. So `getMandate` could show a
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
     * Worth being clear about what the guard prevents, since a mandate with no spender is
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
     * Each flag must agree with the value it describes, in BOTH directions. A flag
     * set with a zero value would be a bound that never binds; a value set with no
     * flag would be a limit that is silently ignored. Both are the failure mode
     * this primitive exists to prevent, so both revert.
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
     * How that was found is worth recording, because reading the suite would not have
     * shown it. `forge coverage` reports the contract at 100% of lines and 99.10% of
     * branches, and the single unreached branch in the whole file was the revert arm of
     * the credential rule. Its four neighbours — per-tx, total, cosigner, allowlist —
     * each had at least one test that fired them; this one had none. A missing negative
     * test is invisible to a green suite by construction, since nothing fails.
     *
     * It also mattered more than the other four, because Gates.t.sol argues that the
     * documented no-agent-binding weakness stays bounded partly on the strength of
     * "F_CREDENTIAL without a validator is refused at grant time". That claim was true
     * and unpinned. Now it is pinned.
     *
     * Both directions are checked. A flag with no validator would be a gate that never
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

    // ------------------------------------------- the cosign gate as a whole
    //
    // NEW IN v2. The two tests above check the flag against the cosigner ADDRESS, which
    // is where v1 stopped. Enumerating the question properly — in how many ways can a
    // mandate display a co-signature requirement and not have one? — turned up three
    // more, and `getMandate` is honest about none of them: it returns a populated
    // cosigner and a plausible threshold in every case. The changelist named only the
    // third, and named it wrongly.

    /// A threshold with no gate behind it. The field is stored, a reader sees a number,
    /// and no spend is ever measured against it. Deliberately not folded into the
    /// biconditional on the address, because zero is MEANINGFUL when F_COSIGN is set — it
    /// means every spend needs a signature, since the gate tests `amount > threshold`
    /// strictly and an amount is at least 1. So the threshold gets a one-directional rule
    /// where the address gets an iff.
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
     * then spend it. Two transactions instead of one, and no second party anywhere. That
     * is not a weaker control, it is the absence of one wearing its clothes, and it is
     * exactly as invisible in `getMandate` as a supervised mandate would be.
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
     * The gate must be able to FIRE, measured against the whole policy.
     *
     * `spend` demands a signature when `amount > cosignThreshold`, strictly, so the gate
     * is dead unless the policy permits at least one amount above the threshold:
     *
     *   effectiveMax = min(2^96 - 1, perTxCap if F_PER_TX, totalCap if F_TOTAL, every
     *                      window cap)   and the grant is refused when
     *   effectiveMax <= cosignThreshold
     *
     * WHY THE CHANGELIST'S CONDITION WAS WRONG TWICE. It proposed `perTxCap <
     * cosignThreshold`. The comparison is backwards — equality is dead too, and this
     * repository already held the receipt for that, at `DESIGN.md:1272`, where a 50,000
     * spend against a 50,000 threshold did not trip the gate on Arc Testnet. And
     * `perTxCap` is not the only ceiling, so the check misses whole families of dead
     * configuration. `L3-VAULT.md` inherited the same error from the changelist.
     */
    function test_createMandate_deadCosignGate_perTxCapBoundaryIsExact() public {
        MandateManager.MandateParams memory p = withCosign(simpleParams(), boss, usd(100));
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct3"), p); // perTxCap 100 == threshold 100: dead

        // One base unit lower and the gate is alive, which is what makes the bound exact
        // rather than merely conservative. A guard written with `<` would accept the case
        // above and this one, and the difference between them is the entire point.
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
    /// gate is fine. Evaluated at `totalSpent == 0` because reachability asks whether the
    /// gate can EVER fire, and a lifetime cap is loosest on the first spend.
    function test_createMandate_deadCosignGate_lifetimeCapBinds() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.totalCap = usd(100);
        p.flags = F_TOTAL;
        p = withCosign(p, boss, usd(100));
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("ct4"), p);
    }

    /// And so does a window cap — as a MINIMUM over the windows, not the first or the
    /// last of them, and the minimum crosses cap KINDS: a generous per-transaction cap
    /// does not rescue a threshold the tightest window has already put out of reach.
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
     * below the uint96 ceiling is reachable and the grant is fine. But the ceiling ITSELF
     * is not reachable, because `spend` refuses amounts above it outright with
     * `AmountTooLarge` — the bound exists even where the payer set none. That term has no
     * analogue in a specification with arbitrary-precision integers, which is precisely
     * the kind of thing the reference model cannot be trusted to have invented on its
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

        // And one below it is fine, so this boundary is exact too.
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

    function test_createMandate_expiryNotAfterNotBefore_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p.notBefore = 2000;
        p.expiresAt = 2000; // exclusive expiry means this window is empty
        p.flags |= F_EXPIRY;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("h"), p);
    }

    /// minResponse of 0 would accept a FAILED attestation, since ERC-8004 uses 0
    /// for a negative result. A credential gate that accepts failure is theater.
    function test_createMandate_credentialWithZeroMinResponse_reverts() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, AGENT_ID, 0);
        p.credential.minResponse = 0;
        vm.prank(payer);
        vm.expectRevert(MandateManager.BadConfig.selector);
        mm.createMandate(bytes32("i"), p);
    }

    /// A gate that cannot be evaluated must not be grantable, or the mandate looks
    /// gated and is not.
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
}
