// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {console} from "forge-std/console.sol";

/**
 * ARC PARITY — the local control for the real Arc Testnet transactions.
 *
 * WHY THIS FILE EXISTS. The gas report gives a median `spend` across the whole
 * suite, aggregated over mandates with wildly different shapes: some with four
 * windows, some with none, some with a credential gate, some denied before they
 * touch the token. Comparing ONE real on-chain spend against that median measures
 * almost nothing. To learn what Arc's real USDC costs that MockUSDC does not, the
 * two sides have to be the same transaction.
 *
 * So every number below is a constant, and the same constants are what get sent to
 * Arc. If someone changes one here without changing the chain-side command, the
 * comparison is void — which is why they are named ARC_* and gathered in one block
 * rather than inlined.
 *
 * WHY A SEPARATE CONTRACT PER MEASUREMENT — and this is the whole reason this
 * file was rewritten. Storage is not priced against a slot's current value but
 * against the value it held when the TRANSACTION began: a first write to a slot that
 * started at zero costs 20,000 gas, while every later write to that same slot in the
 * same transaction costs about 100. A Foundry test function is one transaction, so
 * any preparation a test performs on a slot destroys the price of the write it then
 * measures.
 *
 * The first version of this file did exactly that. It zeroed the allowance inside the
 * test to get a clean zero-to-non-zero `approve`, but Base had already approved
 * type(uint256).max, so the slot's transaction-start value was non-zero and BOTH
 * writes were priced as dirty updates. `approve` reported 3,185 gas — impossible,
 * since the SSTORE alone is 20,000 — and `spend` came in ~4,900 low because
 * `transferFrom` decrements that same pre-warmed slot. The failure was silent: the
 * test passed, the money moved, every assertion held.
 *
 * So each measurement now lives in its own contract, with all preparation in `setUp`,
 * which Foundry runs as a separate transaction. Cold slots, cold accounts, original
 * values matching the real chain.
 *
 * WHAT THE NUMBERS MEAN. `gasleft()` deltas measure EXECUTION only. A receipt's
 * `gasUsed` also includes the intrinsic cost: 21,000 for the transaction plus 4 gas
 * per zero calldata byte and 16 per non-zero one. `_intrinsic` computes that from
 * the actual encoded calldata, so the printed PREDICTED figure is directly
 * comparable to `cast receipt`'s gasUsed. Any residual is Arc behaving differently
 * from a plain ERC-20 — which is the entire question.
 *
 * Caveat on the prediction: it assumes no EIP-7623 calldata floor and no access
 * list. If Arc applies a floor, a calldata-heavy call could come back higher for a
 * reason that has nothing to do with USDC.
 *
 * THE ONE DELIBERATE DIFFERENCE is the payer's balance: ~20 USDC on testnet against
 * a minted fortune here. That cannot change gas, because both are non-zero and the
 * SSTORE is non-zero to non-zero either way.
 */
abstract contract ArcParityBase is Base {
    // --- the mandate that was actually sent to Arc Testnet ------------------
    //
    // A courier agent with a 0.50 per-payment ceiling, 2.00 lifetime, 1.00 per
    // rolling day in hourly buckets, expiring 2026-09-30, allowed to pay exactly
    // one vendor. Small enough that the whole demo costs less than the gas to run
    // it, shaped to exercise every cheap gate at once.

    /// 0x…c0de. Written as a cast rather than a hex literal so no EIP-55 checksum
    /// can be got wrong; the chain-side command uses the lowercase form.
    address internal constant ARC_RECIPIENT = address(uint160(0xc0de));

    uint96 internal constant ARC_PER_TX = 500_000; // 0.50 USDC
    uint96 internal constant ARC_TOTAL = 2_000_000; // 2.00 USDC — also the allowance
    uint40 internal constant ARC_EXPIRES = 1_790_726_400; // 2026-09-30 00:00:00 UTC
    uint32 internal constant ARC_WINDOW_LEN = 86_400; // rolling day
    uint96 internal constant ARC_WINDOW_CAP = 1_000_000; // 1.00 USDC per day
    uint8 internal constant ARC_BUCKETS = 24; // hourly
    uint8 internal constant ARC_FLAGS = 75; // asserted below, not trusted
    uint256 internal constant ARC_AMOUNT = 100_000; // 0.10 USDC
    bytes32 internal constant ARC_SALT = bytes32(uint256(1));
    bytes32 internal constant ARC_NONCE = bytes32(uint256(1));
    bytes32 internal constant ARC_REF = bytes32("invoice-0001");

    /// Roughly Arc's clock in August 2026, so `notBefore`/`expiresAt` mean the same
    /// thing on both sides. Anvil's default timestamp of 1 would make ARC_EXPIRES
    /// an absurd 56 years out and the window arithmetic incomparable.
    uint256 internal constant ARC_NOW = 1_787_000_000;

    /// Base grants an infinite allowance so that policy denials are what its tests
    /// observe. The real payer approved exactly the budget, so undo it here — in
    /// setUp, where the write lands in a different transaction from any measurement.
    function setUp() public virtual override {
        super.setUp();
        vm.warp(ARC_NOW);
        vm.prank(payer);
        token.approve(address(mm), 0);
    }

    function _intrinsic(bytes memory cd) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i = 0; i < cd.length; ++i) {
            g += cd[i] == 0 ? 4 : 16;
        }
    }

    /// `pure` is correct: forge-std 1.9.6's console.log is itself pure, which solc
    /// confirmed by warning (2018) when this was first written as view.
    function _report(string memory label, uint256 execution, bytes memory cd) internal pure {
        uint256 intrinsic = _intrinsic(cd);
        console.log("");
        console.log(label);
        console.log("  calldata bytes            ", cd.length);
        console.log("  execution (gasleft delta) ", execution);
        console.log("  intrinsic (21k + bytes)   ", intrinsic);
        console.log("  PREDICTED receipt gasUsed ", execution + intrinsic);
    }

    function _arcParams() internal view returns (MandateManager.MandateParams memory p) {
        p.spender = agent;
        p.perTxCap = ARC_PER_TX;
        p.totalCap = ARC_TOTAL;
        p.cosigner = address(0);
        p.cosignThreshold = 0;
        p.notBefore = 0;
        p.expiresAt = ARC_EXPIRES;
        p.flags = ARC_FLAGS;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] =
            MandateManager.WindowParams({lengthSeconds: ARC_WINDOW_LEN, cap: ARC_WINDOW_CAP, buckets: ARC_BUCKETS});
        p.allowlist = new address[](1);
        p.allowlist[0] = ARC_RECIPIENT;
        // identity and credential stay zeroed: no agent identity is minted to this
        // throwaway wallet, and the only real attestation on Arc Testnet has a
        // FAILING response of 1. Gating on either would mean faking a credential
        // to demonstrate a credential check, which proves nothing.
    }

    /// Shared guard. The magic 75 in the chain-side command is derived here rather
    /// than trusted, and the window has to divide evenly or createMandate reverts.
    function _assertConstantsAgree() internal pure {
        assertEq(
            uint256(ARC_FLAGS),
            uint256(F_PER_TX | F_TOTAL | F_EXPIRY | F_ALLOWLIST),
            "ARC_FLAGS: 75 must be PER_TX|TOTAL|EXPIRY|ALLOWLIST"
        );
        assertEq(uint256(ARC_WINDOW_LEN) % uint256(ARC_BUCKETS), 0, "window must divide into buckets evenly");
    }
}

/// Transaction 1 of 3: the payer approves exactly the budget.
contract ArcParityApproveTest is ArcParityBase {
    function test_arcParity_1_approve() public {
        _assertConstantsAgree();
        // The control. If this is not zero the measurement below is worthless, which
        // is precisely the trap the first version of this file fell into.
        assertEq(token.allowance(payer, address(mm)), 0, "allowance must start at zero, cold and clean");

        bytes memory cd = abi.encodeWithSignature("approve(address,uint256)", address(mm), uint256(ARC_TOTAL));
        vm.prank(payer);
        uint256 g = gasleft();
        token.approve(address(mm), ARC_TOTAL);
        uint256 used = g - gasleft();

        assertEq(token.allowance(payer, address(mm)), ARC_TOTAL, "allowance was actually set");
        // A zero-to-non-zero SSTORE is 20,000 gas and cannot be avoided, so anything
        // materially below that means the slot was pre-warmed and this is not the
        // number we think it is.
        assertGt(used, 20_000, "approve must pay a full SSTORE_SET; below this the slot was dirty");

        _report("approve(MandateManager, 2.00 USDC)", used, cd);
    }
}

/// Transaction 2 of 3: the payer grants the mandate.
contract ArcParityCreateTest is ArcParityBase {
    function setUp() public override {
        super.setUp();
        vm.prank(payer);
        token.approve(address(mm), ARC_TOTAL);
    }

    function test_arcParity_2_createMandate() public {
        _assertConstantsAgree();

        MandateManager.MandateParams memory p = _arcParams();
        bytes memory cd = abi.encodeCall(MandateManager.createMandate, (ARC_SALT, p));
        vm.prank(payer);
        uint256 g = gasleft();
        bytes32 id = mm.createMandate(ARC_SALT, p);
        uint256 used = g - gasleft();

        assertTrue(mm.isLive(id), "mandate exists and is live");
        assertEq(mm.policyHeadroom(id), ARC_PER_TX, "per-tx cap is the binding limit at grant time");

        _report("createMandate(salt, params)", used, cd);
        console.log("");
        console.log("mandateId on THIS chain (the id is chain-scoped, so Arc's will differ):");
        console.logBytes32(id);
    }
}

/// Transaction 3 of 3: the agent spends. The mandate is granted in setUp so that its
/// storage is cold here, exactly as it is on Arc where the grant was a separate
/// transaction in an earlier block.
contract ArcParitySpendTest is ArcParityBase {
    bytes32 internal arcId;

    function setUp() public override {
        super.setUp();
        vm.prank(payer);
        token.approve(address(mm), ARC_TOTAL);
        vm.prank(payer);
        arcId = mm.createMandate(ARC_SALT, _arcParams());
    }

    function test_arcParity_3_spend() public {
        _assertConstantsAgree();
        assertEq(token.allowance(payer, address(mm)), ARC_TOTAL, "allowance is the exact budget, untouched");
        assertEq(token.balanceOf(ARC_RECIPIENT), 0, "recipient starts empty, as it does on Arc");

        bytes memory cd =
            abi.encodeCall(MandateManager.spend, (arcId, ARC_RECIPIENT, ARC_AMOUNT, ARC_REF, ARC_NONCE));
        vm.prank(agent);
        uint256 g = gasleft();
        mm.spend(arcId, ARC_RECIPIENT, ARC_AMOUNT, ARC_REF, ARC_NONCE);
        uint256 used = g - gasleft();

        // A gas measurement of a call that quietly did nothing is worthless, so
        // prove the money moved and the ceiling tightened before reporting.
        assertEq(token.balanceOf(ARC_RECIPIENT), ARC_AMOUNT, "recipient was actually paid");
        assertEq(token.allowance(payer, address(mm)), ARC_TOTAL - ARC_AMOUNT, "allowance decremented by the spend");
        assertEq(mm.spendable(arcId), ARC_PER_TX, "per-tx cap is the binding limit on the next spend");

        _report("spend(id, 0x...c0de, 0.10 USDC)", used, cd);
    }
}

/**
 * Transaction 4 of 4: the co-signer pre-approves exactly one spend.
 *
 * WHY THIS TEST EXISTS, AND IT IS NOT TO BUDGET GAS. DESIGN.md published
 * `approveCosign max = 53,114` in a table of MOCK gas-report figures, and the real Arc
 * receipt for `approveCosign` came in at exactly 53,114 too — tx 0x29eb5c24…, block
 * 58591691, `evidence/cosign-approve.log`. An exact match between mock and chain reads
 * like the harness working perfectly.
 *
 * READ THIS BEFORE THE REST OF THE COMMENT. Everything below the next paragraph was
 * written on 2026-08-24 and its central claim was REVERSED on 2026-08-25. The match is
 * real. `forge test --gas-report` INCLUDES intrinsic gas for state-changing functions
 * and excludes it only for views, so the mock column and a receipt's `gasUsed` are on
 * the same basis for every function this file measures. Four live receipts now confirm
 * it: `revoke` at 30,808 and 32,945, `approveCosign` at 53,102 and `withdrawCosign` at
 * 26,889 each reduce to exactly the execution the report implies. The full argument,
 * including why a reverting `revoke` cannot execute the 23,773 gas the report lists for
 * it, is the closing section of DESIGN.md.
 *
 * The consequence for THIS FILE is uncomfortable and worth stating plainly: the harness
 * below was less accurate than the tool it was built to check. Its `gasleft()` figure of
 * 36,231 for `approveCosign` overstates the true execution of 31,026 by about 5,205, of
 * which only 2,700 is accounted for by COLD_ACCOUNT_ADJ. Foundry's own gas report needed
 * no adjustment at all. So the residuals this file reports are mostly measurements of
 * the harness, and the `createMandate` deviation of −6,337 that was once used to
 * calibrate an Arc "premium" was harness error, not a property of Arc. The tests are
 * kept because they document that, and because the intrinsic-gas arithmetic in
 * `_report` is still correct and still useful.
 *
 * ---- superseded reasoning, retained deliberately ----
 * It is an accident, and taking it at face value would mean misreading every other
 * figure in that table by the same 22,088 gas.
 *
 * The proof that it is an accident sits four rows above it in the same gas report:
 * `spendHash` is listed at 1,003 gas. No transaction can cost 1,003 gas, because the
 * intrinsic floor is 21,000. So forge's gas report measures EXECUTION inside the call
 * frame and excludes intrinsic cost entirely, while a receipt's `gasUsed` includes it.
 * The two columns were never comparable; they simply printed the same digits.
 *
 * That last paragraph is the error. `spendHash` is a `view`; every figure the argument
 * was applied to belongs to a state-changing function. A true observation about one
 * kind of call was generalised to a kind it does not describe, and the generalisation
 * was never checked against a second method — which is exactly the failure mode this
 * repository keeps rediscovering.
 * ---- end superseded reasoning ----
 *
 * `approveCosign` is also the best control in this whole file, for a reason that has
 * nothing to do with co-signing: it is the only live Remit transaction that never
 * touches USDC. `approve`, `spend` and the bare `transfer` all pay Arc's
 * `NativeFiatToken` premium, which is what makes their deltas hard to attribute. This
 * one is pure Remit storage — three SLOADs, one SSTORE, one log. If the premium is a
 * property of the token contract rather than of the chain, the prediction here should
 * land on the receipt with a residual near zero, and any failure to do so is the
 * harness, not Arc. That last sentence turned out to be the useful one: the residual
 * was 2,705 and it was indeed the harness.
 */
contract ArcParityApproveCosignTest is ArcParityBase {
    /// The live co-signed mandate: salt 2, cosigner == payer, threshold 0.05 USDC.
    bytes32 internal constant ARC_COSIGN_SALT = bytes32(uint256(2));
    uint96 internal constant ARC_COSIGN_TOTAL = 1_000_000; // 1.00 USDC lifetime
    uint96 internal constant ARC_COSIGN_THRESHOLD = 50_000; // 0.05 USDC
    uint8 internal constant ARC_COSIGN_FLAGS = 79; // asserted below, not trusted
    uint256 internal constant ARC_COSIGN_AMOUNT = 100_000; // above the threshold

    /// What Arc actually charged. Not a target to tune towards — the point is the
    /// residual against a prediction built only from plain-EVM prices.
    uint256 internal constant ARC_LIVE_GASUSED = 53_114;

    /// EIP-2929 and the shape of a top-level call. A real transaction has NO `CALL`
    /// opcode at its entry point — the 21,000 intrinsic covers getting into the
    /// contract, and `tx.to` is warm before the first instruction runs. A Foundry test
    /// reaches `MandateManager` as an INNER call and pays for it twice over: solc emits
    /// an `EXTCODESIZE` check ahead of a call with no return value (2,600 cold), and
    /// then the `CALL` itself (100, now warm). Both are pure harness cost, so the whole
    /// 2,700 comes off rather than the 2,600−100 difference.
    uint256 internal constant COLD_ACCOUNT_ADJ = 2_700;

    bytes32 internal cosignId;
    bytes32 internal approvedHash;
    /// Read in `setUp`, deliberately. Reading it inside the test would warm the very
    /// slot being measured and turn a 22,100 cold SSTORE_SET into 20,100 — the exact
    /// trap described at the top of this file, which cost a whole rewrite once.
    bool internal approvedBeforeMeasurement;

    function setUp() public override {
        super.setUp();
        vm.prank(payer);
        token.approve(address(mm), ARC_COSIGN_TOTAL);

        MandateManager.MandateParams memory p = _arcParams();
        p.totalCap = ARC_COSIGN_TOTAL;
        p.cosigner = payer; // as on chain: the payer co-signed for itself
        p.cosignThreshold = ARC_COSIGN_THRESHOLD;
        p.flags = ARC_COSIGN_FLAGS;

        vm.prank(payer);
        cosignId = mm.createMandate(ARC_COSIGN_SALT, p);

        approvedHash = mm.spendHash(cosignId, agent, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, ARC_NONCE);
        approvedBeforeMeasurement = mm.isCosignApproved(cosignId, approvedHash);
    }

    function _zeroBytes(bytes memory b) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == 0) ++n;
        }
    }

    function test_arcParity_4_approveCosign() public {
        _assertConstantsAgree();
        assertEq(
            uint256(ARC_COSIGN_FLAGS),
            uint256(F_PER_TX | F_TOTAL | F_COSIGN | F_EXPIRY | F_ALLOWLIST),
            "ARC_COSIGN_FLAGS: 79 must be PER_TX|TOTAL|COSIGN|EXPIRY|ALLOWLIST"
        );
        // The control, evaluated in setUp so that reading it cannot warm the slot.
        assertFalse(approvedBeforeMeasurement, "approval slot must start false, cold and virgin");

        bytes memory cd = abi.encodeCall(MandateManager.approveCosign, (cosignId, approvedHash));

        vm.prank(payer);
        uint256 g = gasleft();
        mm.approveCosign(cosignId, approvedHash);
        uint256 used = g - gasleft();

        assertTrue(mm.isCosignApproved(cosignId, approvedHash), "approval was actually recorded");
        // A zero-to-non-zero SSTORE is 20,000 and cannot be avoided. Below that, the
        // slot was warm and this number is not what it looks like.
        assertGt(used, 20_000, "must pay a full SSTORE_SET; below this the slot was dirty");

        // ---- measurement B: the same call again, everything warm but the target slot.
        //
        // A minus B isolates exactly how much cold surcharge measurement A paid, which
        // is the only way to check the hand decomposition instead of asserting it. The
        // model says A should carry 2,500 of cold-account surcharge (2,600 EXTCODESIZE
        // less the 100 a warm one costs) plus 3 x 2,000 for the mandate slots, so
        // A − B should be 8,500. A different answer means the model is wrong about
        // which slots are cold, and every other figure derived from it is suspect.
        bytes32 secondHash =
            mm.spendHash(cosignId, agent, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, bytes32(uint256(2)));
        assertTrue(secondHash != approvedHash, "second hash must be a genuinely different slot");

        vm.prank(payer);
        uint256 g2 = gasleft();
        mm.approveCosign(cosignId, secondHash);
        uint256 usedWarm = g2 - gasleft();

        assertTrue(mm.isCosignApproved(cosignId, secondHash), "second approval recorded too");

        // Intrinsic gas depends only on how many calldata bytes are zero, so the local
        // mandateId and spendHash only give a comparable figure if they are as dense as
        // the live ones were. Both live words were fully non-zero; a keccak output has
        // a ~12% chance of containing at least one zero byte, so this is checked.
        assertEq(cd.length, 68, "selector + two words");
        assertEq(_zeroBytes(cd), 0, "live calldata had zero zero-bytes; intrinsic is only comparable if this does too");

        uint256 intrinsic = _intrinsic(cd);
        uint256 predicted = used - COLD_ACCOUNT_ADJ + intrinsic;

        _report("approveCosign(id, spendHash)", used, cd);
        console.log("  less cold-account adj     ", COLD_ACCOUNT_ADJ);
        console.log("  PREDICTED, adjusted       ", predicted);
        console.log("  charged on Arc            ", ARC_LIVE_GASUSED);
        console.log("  residual (predicted-live) ", predicted - ARC_LIVE_GASUSED);
        console.log("");
        console.log("A/B cold-surcharge isolation:");
        console.log("  A, everything cold        ", used);
        console.log("  B, warm but target slot   ", usedWarm);
        // A > B is a PROPERTY OF THE MEASUREMENT MODE, not of the contract, so it is
        // guarded rather than asserted. Under `--gas-report` Foundry adds per-call
        // tracing overhead that lands INSIDE the `gasleft()` window and is not constant
        // between two calls: on 2026-08-25 this read A = 58,319 against B = 60,222 and
        // the bare `used - usedWarm` below panicked with 0x11 on the unsigned subtraction
        // — 139 passed, 1 failed, from a comment-only commit. Plain `forge test` gives
        // A = 36,231 and 140/140. Same bytecode, ~22,000 gas of swing.
        //
        // That inversion is worth more than the isolation it breaks. In the same failing
        // trace Foundry metered the inner call at exactly 53,114 — the live Arc receipt to
        // the gas — while this `gasleft()` wrapper around that identical call read 58,319.
        // The instrument this file was built to check is mode-independent and correct; the
        // file's own instrument is neither. See the reversal note above and DESIGN.md.
        if (usedWarm >= used) {
            console.log("  A - B  SKIPPED: B >= A, so gasleft() is contaminated.");
            console.log("  Re-run without --gas-report for a meaningful A/B isolation.");
        } else {
            console.log("  A - B  (model says 8500)  ", used - usedWarm);
        }
        console.log("");
        console.log("hand decomposition of the execution a real tx would pay:");
        console.log("  3 cold SLOAD (payer s0, cosigner s2, flags s3)  6300");
        console.log("  SSTORE_SET cold on _cosignApproved             22100");
        console.log("  LOG4, three indexed args, empty data            1875");
        console.log("  3x keccak256(64 bytes): 1 mandate + 2 nested     126");
        console.log("  ---- accounted                                 30401");
        console.log("  execution a real tx would pay (test - adj)   ", used - COLD_ACCOUNT_ADJ);

        // The claim under test is the DIRECTION, which is the part that generalises:
        // on an operation that touches no USDC, the Foundry harness predicts HIGH.
        // `createMandate` also touches no USDC and also overshoots (−6,337), while
        // `approve` and `spend` both touch USDC and undershoot. A tight numeric bound
        // here would be tuning; the printed residual is the finding.
        //
        // The direction holds in every mode, so it is asserted unconditionally. The
        // MAGNITUDE does not: under `--gas-report` the residual inflates from ~2,700 to
        // 24,593 because tracing overhead is inside the `gasleft()` window, so bounding it
        // would fail for a reason that has nothing to do with the model. B >= A is the
        // signal that the measurement is contaminated — the same signal used above.
        assertGt(predicted, ARC_LIVE_GASUSED, "harness should overshoot on a USDC-free operation");
        if (usedWarm >= used) {
            console.log("");
            console.log("Residual bound SKIPPED: gasleft() contaminated by tracing overhead.");
            console.log("This test is only quantitative under plain `forge test`.");
        } else {
            assertLt(
                predicted - ARC_LIVE_GASUSED, 6_000, "overshoot should be small; a big one means the model is wrong"
            );
        }
    }
}
