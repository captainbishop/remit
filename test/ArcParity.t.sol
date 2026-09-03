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
 * windows, some with none, some with a credential check, some denied before they
 * touch the token. Comparing ONE real on-chain spend against that median measures
 * almost nothing. To learn what Arc's real USDC costs that MockUSDC does not, the
 * two sides have to be the same transaction.
 *
 * Every number below is a constant, and the same constants are what get sent to
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
 * `transferFrom` decrements that same pre-warmed slot. The failure produced no
 * error: the test passed, the money moved, every assertion held.
 *
 * Each measurement now lives in its own contract, with all preparation moved into
 * `setUp`, which Foundry runs as a separate transaction, so the slots and accounts
 * are cold and the original values match the real chain.
 *
 * WHAT THE NUMBERS MEAN. A `gasleft()` delta measures EXECUTION only, while a
 * receipt's `gasUsed` also includes the intrinsic cost: 21,000 for the transaction
 * plus 4 gas per zero calldata byte and 16 per non-zero one. `_intrinsic` computes
 * that from the actual encoded calldata, so the printed PREDICTED figure is directly
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
    // it, shaped to exercise every low-cost check at once.

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

    /// `pure` is correct: forge-std 1.16.2's console.log is itself pure, which solc
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
        // FAILING response of 1. Requiring either would mean faking a credential
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
        // materially below that means the slot was pre-warmed and the figure measures
        // something other than a first write.
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

        bytes memory cd = abi.encodeCall(MandateManager.spend, (arcId, ARC_RECIPIENT, ARC_AMOUNT, ARC_REF, ARC_NONCE));
        vm.prank(agent);
        uint256 g = gasleft();
        mm.spend(arcId, ARC_RECIPIENT, ARC_AMOUNT, ARC_REF, ARC_NONCE);
        uint256 used = g - gasleft();

        // A gas measurement of a call that did nothing without reverting is worthless:
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
 * The consequence for THIS FILE is that the harness below was less accurate than the
 * tool it was built to check. Its `gasleft()` figure of 36,231 for `approveCosign`
 * overstates the true execution of 31,026 by about 5,205, of which only 2,700 is
 * accounted for by COLD_ACCOUNT_ADJ, while Foundry's own gas report needed no
 * adjustment at all. The residuals this file reports are therefore mostly
 * measurements of the harness, and the `createMandate` deviation of −6,337 that was
 * once used to calibrate an Arc "premium" was harness error, not a property of Arc.
 * The tests are kept because they document that, and because the intrinsic-gas
 * arithmetic in `_report` is still correct and still useful.
 *
 * ---- superseded reasoning, retained deliberately ----
 * It is an accident, and taking it at face value would mean misreading every other
 * figure in that table by the same 22,088 gas.
 *
 * The proof that it is an accident sits four rows above it in the same gas report:
 * `spendHash` is listed at 1,003 gas. No transaction can cost 1,003 gas, because the
 * intrinsic floor is 21,000, so forge's gas report measures EXECUTION inside the call
 * frame and excludes intrinsic cost entirely, while a receipt's `gasUsed` includes it.
 * The two columns were never comparable; they simply printed the same digits.
 *
 * That last paragraph is the error. `spendHash` is a `view`; every figure the argument
 * was applied to belongs to a state-changing function. A true observation about one
 * class of call was generalised to a class it does not describe, and the generalisation
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
 *
 * ============================================================================
 * THE ANCHOR IN THIS SUITE IS GONE AS OF v2, AND NOTHING CAN RESTORE IT.
 * ============================================================================
 *
 * `approveCosign(bytes32,bytes32)` was DELETED by F15, and every paragraph above
 * still describes something true, but it describes a function that no longer exists
 * at any address this repository can call, so the comparison this suite was built
 * to perform cannot be performed. The live receipt — tx `0x29eb5c24…`, 53,114 gas,
 * block on Arc Testnet — measured `approveCosign` running inside deployed v1 at
 * `0x3744E93B9e796E05CB66311d897559B6F3860196`. That deployment is immutable and still
 * holds the old function; this source tree no longer does. There is no way to put the
 * two back on the same basis:
 *
 *   - `approveCosignFor` is a DIFFERENT function. Six parameters instead of two (196
 *     calldata bytes instead of 68), one extra keccak for the hash it now derives itself,
 *     two extra comparisons for the deadline, and three data words in the log instead of
 *     none. Comparing its cost to 53,114 would be comparing two different computations
 *     and calling the difference an Arc property, which is the precise error the reversal
 *     note above exists to record.
 *   - Re-measuring on Arc would need `approveCosignFor` deployed there. That is a v2
 *     deployment, and when it happens it gives a NEW anchor for the NEW function — not a
 *     repair of this one.
 *
 * `ARC_LIVE_GASUSED` is retained below as history and is deliberately NOT asserted
 * against any more. What survives is everything that never depended on the live figure:
 * the A/B cold-surcharge isolation, the hand decomposition, the intrinsic-gas arithmetic,
 * and the `used > 20_000` floor proving a virgin SSTORE was actually paid for. What is
 * lost is the only same-function check in this repository between a Foundry prediction
 * and a real Arc receipt on a USDC-free operation. That cost was named and accepted when
 * the removal was chosen; it is written here rather than in a commit message because a
 * reader of this file six months from now needs it more than a reader of the log does.
 */
contract ArcParityApproveCosignTest is ArcParityBase {
    /// The live co-signed mandate: salt 2, cosigner == payer, threshold 0.05 USDC.
    bytes32 internal constant ARC_COSIGN_SALT = bytes32(uint256(2));
    uint96 internal constant ARC_COSIGN_TOTAL = 1_000_000; // 1.00 USDC lifetime
    uint96 internal constant ARC_COSIGN_THRESHOLD = 50_000; // 0.05 USDC
    uint8 internal constant ARC_COSIGN_FLAGS = 79; // asserted below, not trusted
    uint256 internal constant ARC_COSIGN_AMOUNT = 100_000; // above the threshold

    /// What Arc actually charged FOR THE DELETED TWO-ARGUMENT FUNCTION. Kept as history and
    /// as the figure DESIGN.md and evidence/README.md cite; no longer compared against
    /// anything measured here, because nothing measured here is that function. See the
    /// banner above for why this is unrepairable rather than merely stale.
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

        approvedHash = mm.spendHash(cosignId, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, ARC_NONCE);
        approvedBeforeMeasurement = mm.isCosignApproved(cosignId, approvedHash);
    }

    function _zeroBytes(bytes memory b) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == 0) ++n;
        }
    }

    function test_arcParity_4_approveCosignFor() public {
        _assertConstantsAgree();
        assertEq(
            uint256(ARC_COSIGN_FLAGS),
            uint256(F_PER_TX | F_TOTAL | F_COSIGN | F_EXPIRY | F_ALLOWLIST),
            "ARC_COSIGN_FLAGS: 79 must be PER_TX|TOTAL|COSIGN|EXPIRY|ALLOWLIST"
        );
        // The control, evaluated in setUp so that reading it cannot warm the slot.
        assertFalse(approvedBeforeMeasurement, "approval slot must start false, cold and virgin");

        uint40 validUntil = uint40(block.timestamp + 1 days);
        bytes memory cd = abi.encodeCall(
            MandateManager.approveCosignFor,
            (cosignId, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, ARC_NONCE, validUntil)
        );

        vm.prank(payer);
        uint256 g = gasleft();
        mm.approveCosignFor(cosignId, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, ARC_NONCE, validUntil);
        uint256 used = g - gasleft();

        assertTrue(mm.isCosignApproved(cosignId, approvedHash), "approval was actually recorded");
        assertEq(mm.cosignApprovalDeadline(cosignId, approvedHash), validUntil, "and at the deadline given");
        // A zero-to-non-zero SSTORE is 20,000 and cannot be avoided. Below that, the
        // slot was warm and this number is not what it looks like.
        assertGt(used, 20_000, "must pay a full SSTORE_SET; below this the slot was dirty");

        // ---- measurement B: the same call again, everything warm but the target slot.
        //
        // A minus B isolates exactly how much cold surcharge measurement A paid, which
        // is the only way to check the hand decomposition instead of asserting it. The
        // model says A should carry 2,500 of cold-account surcharge (2,600 EXTCODESIZE
        // less the 100 a warm one costs) plus 2,000 for each cold mandate slot, so
        // A − B should be a few thousand. A different answer means the model is wrong
        // about which slots are cold, and every other figure derived from it is suspect.
        //
        // v2 note: the 8,500 target originally quoted below was derived for the deleted
        // two-argument function, which read three mandate slots. F15 made `approveCosignFor`
        // read a fourth (`spender`, slot 1, for the hash it now derives itself), and F17 added
        // two MAPPING reads — the allowlist entry and the nonce entry — so the figure has moved
        // twice and is re-derived here rather than nudged:
        //
        //   4 cold mandate slots x 2,000 surcharge      8,000
        //   allowlist entry, cold in A and WARM in B    2,000   (same recipient both calls)
        //   cold-account surcharge on the inner call    2,500
        //   nonce entry                                     0   <- cold in BOTH, so it cancels
        //   ------------------------------------------------
        //   expected A - B                             12,500
        //
        // The nonce line is the one worth pausing on. It is not an omission: B deliberately
        // uses a different nonce so that its `_cosignApproved` slot is virgin, and that same
        // difference makes its `_usedNonce` slot cold too, so the surcharge appears on both
        // sides of the subtraction and isolates nothing. A/B isolation can only ever see the
        // reads whose KEYS the two calls share.
        //
        // Still PRINTED and not asserted, exactly as before.
        bytes32 secondHash = mm.spendHash(cosignId, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, bytes32(uint256(2)));
        assertTrue(secondHash != approvedHash, "second hash must be a genuinely different slot");

        vm.prank(payer);
        uint256 g2 = gasleft();
        mm.approveCosignFor(cosignId, ARC_RECIPIENT, ARC_COSIGN_AMOUNT, ARC_REF, bytes32(uint256(2)), validUntil);
        uint256 usedWarm = g2 - gasleft();

        assertTrue(mm.isCosignApproved(cosignId, secondHash), "second approval recorded too");

        // Intrinsic gas depends only on how many calldata bytes are zero. The old test
        // asserted EXACTLY ZERO zero-bytes, because the live transaction's two words were
        // both fully dense and intrinsic was only comparable if the local ones were too.
        // There is nothing to be comparable WITH any more, and the new calldata is sparse by
        // construction, so that assertion is replaced rather than weakened.
        //
        // What replaces it is a bound that is DERIVED rather than observed. Five of the six
        // argument words have known values, and each therefore has a known zero-byte count:
        // the recipient 0x…c0de is 30 zeros (a 2-byte value in a 32-byte word), the amount
        // 100000 = 0x0186a0 is 29, `bytes32("invoice-0001")` is 20 (12 ASCII bytes,
        // left-aligned), the nonce 1 is 31, and the deadline 1787086400 = 0x6a84c640 is 28.
        // That is 138, and it is a floor rather than an equality for two reasons: the
        // selector and `cosignId` contribute an unknown number on top, since a keccak
        // output's density is not knowable without computing it. Both can only ADD.
        //
        // A floor is a real assertion here — reordering the arguments, widening one, or
        // changing an ARC_* constant materially would break it — and unlike an equality it
        // cannot fail for a stochastic reason. The exact count is printed below.
        assertEq(cd.length, 196, "selector + six words");
        assertGe(
            _zeroBytes(cd),
            138,
            "five known argument words contribute 30+29+20+31+28 zero bytes; fewer means the encoding moved"
        );
        // Cross-check of `_intrinsic`'s loop against the closed form, using the
        // independently written `_zeroBytes`. This is the weakest assertion in the test and
        // is labelled as such: two implementations of one formula agreeing is not evidence
        // the formula is EIP-2028's, only that the arithmetic below is not a typo.
        assertEq(
            _intrinsic(cd),
            21_000 + 4 * _zeroBytes(cd) + 16 * (cd.length - _zeroBytes(cd)),
            "intrinsic must be 21k plus 4/16 per zero/non-zero calldata byte"
        );

        uint256 intrinsic = _intrinsic(cd);
        uint256 predicted = used - COLD_ACCOUNT_ADJ + intrinsic;

        _report("approveCosignFor(id, recipient, amount, ref, nonce, validUntil)", used, cd);
        console.log("  zero calldata bytes       ", _zeroBytes(cd));
        console.log("  less cold-account adj     ", COLD_ACCOUNT_ADJ);
        console.log("  PREDICTED, adjusted       ", predicted);
        console.log("");
        console.log("NOT COMPARABLE - read before using either number:");
        console.log("  Arc receipt for the DELETED approveCosign(id,hash)", ARC_LIVE_GASUSED);
        console.log("  That receipt measured a two-argument function with 68 calldata bytes,");
        console.log("  no derived hash and a log with no data words. This measurement is of a");
        console.log("  six-argument function with 196 calldata bytes, one extra cold SLOAD, an");
        console.log("  extra keccak and three data words in the log. The difference is a");
        console.log("  difference of computation, not an Arc property. No residual is asserted.");
        console.log("");
        console.log("A/B cold-surcharge isolation:");
        console.log("  A, everything cold        ", used);
        console.log("  B, warm but target slot   ", usedWarm);
        // A > B is a PROPERTY OF THE MEASUREMENT MODE, not of the contract, so it is
        // guarded rather than asserted, since under `--gas-report` Foundry adds per-call
        // tracing overhead that lands INSIDE the `gasleft()` window and is not constant
        // between two calls: on 2026-08-25 this read A = 58,319 against B = 60,222 and
        // the bare `used - usedWarm` below panicked with 0x11 on the unsigned subtraction
        // — 139 passed, 1 failed, from a comment-only commit. Plain `forge test` gives
        // A = 36,231 and a full pass. Same bytecode, ~22,000 gas of swing.
        //
        // That inversion is worth more than the isolation it breaks, and it is the one part
        // of this file's original finding that v2 did NOT cost. In the same failing trace
        // Foundry metered the inner call at exactly 53,114 — the live Arc receipt to the gas
        // — while this `gasleft()` wrapper around that identical call read 58,319. The
        // instrument this file was built to check is mode-independent and correct; the file's
        // own instrument is neither. That comparison was made against the old function while
        // it still existed, so it stands as a recorded observation even though it can no
        // longer be re-run. See the reversal note above and DESIGN.md.
        if (usedWarm >= used) {
            console.log("  A - B  SKIPPED: B >= A, so gasleft() is contaminated.");
            console.log("  Re-run without --gas-report for a meaningful A/B isolation.");
        } else {
            console.log("  A - B  (model says ~12500) ", used - usedWarm);
        }
        console.log("");
        console.log("hand decomposition, RE-DERIVED for the six-argument function AFTER F17:");
        console.log("  4 cold SLOAD: payer s0, flags s3, cosigner s2, spender s1     8400");
        console.log("  2 cold SLOAD added by F17: allowlist entry, nonce entry        4200");
        console.log("  1 warm SLOAD: payer s0 re-read inside spendHash                 100");
        console.log("  SSTORE_SET cold on a virgin _cosignApproved slot              22100");
        console.log("  LOG4: 375 + 4x375 topics + 8x96 for three data words           2643");
        console.log("  keccak256 over the 9-word (288 B) spendHash preimage              84");
        console.log("  keccak256(64) per mapping slot, 7 or 8 of them            294 or 336");
        console.log("  ---- accounted, 37821 or 37863 ----");
        console.log("  execution a real tx would pay (test - adj)   ", used - COLD_ACCOUNT_ADJ);
        console.log("");
        console.log("  F17 costs six of those keccaks and two of those cold SLOADs: the caps it");
        console.log("  checks live in mandate slots this function already loaded, but the");
        console.log("  allowlist and nonce checks each address a two-level mapping. That is the");
        console.log("  measured price of refusing an approval no spend could consume, on a call");
        console.log("  a human sends by hand. It is stated so the trade is auditable, not to");
        console.log("  argue it - see approveCosignFor's own notes for the argument.");
        console.log("");
        console.log("  Two honest caveats on that total. The mapping-keccak line is a RANGE");
        console.log("  because `_mandates[mandateId]` is addressed twice - once here, once in");
        console.log("  spendHash, which has its own storage pointer - and whether solc's");
        console.log("  optimiser computes that slot once or twice is not knowable from the");
        console.log("  source. The 42-gas spread is far below the ~2,700 of harness error this");
        console.log("  file has already documented, so it is stated rather than resolved.");
        console.log("  And the total is arithmetic from the EVM cost table, not a measurement:");
        console.log("  it has NOT been checked against a receipt for this function, because");
        console.log("  there is no such receipt until v2 is deployed. Treat any gap against");
        console.log("  the measured line as unexplained, NOT as an Arc premium.");

        // WHAT IS NO LONGER ASSERTED, and why the test still earns its place.
        //
        // The two removed assertions were `predicted > ARC_LIVE_GASUSED` and
        // `predicted - ARC_LIVE_GASUSED < 6_000`. Both compared this function to a receipt
        // for a different one. Keeping them by loosening the bound would have been worse
        // than deleting them: a passing test that compares incomparable things teaches a
        // reader that the comparison is valid.
        //
        // Each remaining assertion still does work. `used > 20_000` proves a virgin
        // SSTORE was paid for, which is the trap at the top of this file and the reason
        // `setUp` reads the slot instead of the test body. The calldata-shape and
        // intrinsic assertions pin the arithmetic `_report` prints, and the A/B isolation
        // still measures the harness against itself, which never needed Arc. The suite is
        // now a measurement rather than a parity check, and the banner at the top of this
        // file names it as such rather than leaving that correction to an inline comment.
        assertGt(usedWarm, 20_000, "B must also pay a full SSTORE_SET on its own virgin slot");
    }
}
