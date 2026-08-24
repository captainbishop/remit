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
        assertEq(m.totalSpent, 0, "totalSpent");
        assertEq(m.spendCount, 0, "spendCount");
        assertEq(m.windowCount, 1, "windowCount");
        assertEq(m.flags, F_PER_TX | F_TOTAL, "flags");
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
        emit MandateManager.MandateCreated(expectedId, payer, agent, usd(100), 0, 0, 0, F_PER_TX, 1);

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

    /// The whole point of the primitive. A mandate with no bound is an allowance
    /// with extra steps, so it is refused rather than documented against.
    function test_createMandate_unbounded_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MandateManager.Unbounded.selector);
        mm.createMandate(bytes32("u"), emptyParams());
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
        bytes32 id = grant(p);
        assertEq(mm.getMandate(id).windowCount, 4);
    }

    // A tiny shim so the intent reads clearly at the call site above.
    function vmic_expectBadConfig() private {
        vm.expectRevert(MandateManager.BadConfig.selector);
    }
}
