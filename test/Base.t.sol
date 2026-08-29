// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockIdentityRegistry, MockValidationRegistry} from "./mocks/MockRegistries.sol";

/**
 * Shared harness for the Remit test suite.
 *
 * This is the Forge port of reference/policy.test.js. The JS suite verifies the
 * POLICY; this one verifies the STORAGE — the packed structs, the bucket ring in
 * real mappings, the fused check-and-commit that the model cannot express because
 * JavaScript has no transactional rollback. Where the two disagree, one of them is
 * a bug, and the model is the specification.
 *
 * Naming convention, so a failure is readable without opening the file:
 *   test_*         deterministic unit test
 *   testFuzz_*     parameterised
 *   invariant_*    stateful, driven by a handler
 *   *_ATTACK_*     an adversary is being simulated, not an accident
 *   *_REGRESSION_* a bug that was actually shipped into the model once
 */
abstract contract Base is Test {
    MandateManager internal mm;
    MockUSDC internal token;
    MockIdentityRegistry internal identity;
    MockValidationRegistry internal validation;

    address internal payer;
    address internal agent;
    address internal vendor;
    address internal other;
    address internal boss; // cosigner, and the named validator

    uint256 internal constant ONE = 1e6; // 1 USDC, 6 decimals — the ERC-20 view
    uint32 internal constant DAY = 1 days;
    uint32 internal constant WEEK = 7 days;

    /**
     * The lifetime horizon nearly every mandate in this suite carries, and the reason it
     * is the largest representable value rather than a plausible far-future date.
     *
     * NEW IN v2: `createMandate` now refuses a mandate with no LIFETIME bound. A
     * per-transaction cap is not one — the delegate spends it again, and again — and
     * neither is a rolling window, which is bounded per period and unbounded over a
     * lifetime; `totalCap` and `expiresAt` are the only two. Almost every test here is
     * about something other than expiry, so each one needs a bound that cannot
     * interfere with whatever it is actually measuring.
     *
     * `expiresAt` is the right one of the two, and not merely the more convenient one.
     * `totalCap` enters the amount arithmetic everywhere — `spendable`,
     * `policyHeadroom`, the min-of across bounds, the totalSpent ceiling — so handing
     * every mandate one would make it an unannounced term in tests that are measuring
     * a window or a per-transaction cap, and some of those assert exact numbers. An
     * expiry is inert with respect to every amount in the system. It is either passed
     * or it is not.
     *
     * uint40 max, rather than a plausible date, because "far enough" has to hold
     * unconditionally. The model's `FAR` is 4e9 — year 2096, against a measured maximum
     * clock of 103,676,400 — and that is sound there because the JS suite's timestamps
     * are a fixed set of literals anyone can enumerate. This suite's are not:
     * `WindowInvariant` accumulates up to `depth * (windowLength + subLength + 1)`
     * seconds, and `depth` is a number in foundry.toml which the deep profile already
     * raises from 64 to 256. A horizon that is safe under one profile and not another is
     * a trap, so this is the one value no run can pass without first overflowing the
     * field it is stored in, which is the year 36812.
     *
     * The contract permits it. `expiresAt` is only ever compared, never used in
     * arithmetic — MandateManager.sol:608 in `spend` and :1012 in `isLive` are its only
     * two readers — and the only grant-time rule on the value is that it exceed
     * `notBefore`.
     */
    uint40 internal constant FAR = type(uint40).max;

    uint256 internal constant AGENT_ID = 42;
    bytes32 internal constant KYC_HASH = keccak256("kyc-request-1");
    bytes32 internal constant REF = bytes32("invoice-0001");

    /**
     * Mirrors of MandateManager's flag constants, deliberately re-declared rather
     * than read through the public getters. If the contract ever renumbers a flag,
     * these stop matching and test_flagConstants_matchTheContract fails loudly —
     * whereas reading the getters would keep every test passing with no failure at
     * all, while testing the wrong bit.
     */
    uint8 internal constant F_PER_TX = 1 << 0;
    uint8 internal constant F_TOTAL = 1 << 1;
    uint8 internal constant F_COSIGN = 1 << 2;
    uint8 internal constant F_EXPIRY = 1 << 3;
    uint8 internal constant F_IDENTITY = 1 << 4;
    uint8 internal constant F_CREDENTIAL = 1 << 5;
    uint8 internal constant F_ALLOWLIST = 1 << 6;

    uint256 private _nonceCounter;
    uint256 private _saltCounter;

    function setUp() public virtual {
        payer = makeAddr("payer");
        agent = makeAddr("agent");
        vendor = makeAddr("vendor");
        other = makeAddr("other");
        boss = makeAddr("boss");

        // Anvil starts at timestamp 1. Several window tests reason about "one day
        // ago", which underflows there, so start the clock somewhere harmless.
        vm.warp(1_000_000);

        token = new MockUSDC();
        identity = new MockIdentityRegistry();
        validation = new MockValidationRegistry();
        mm = new MandateManager(address(token), address(identity), address(validation));

        // Fund and approve generously by default. Tests about the allowance being
        // the outer ceiling set it explicitly; everywhere else the point is to
        // observe the POLICY denying, not the token running dry.
        token.mint(payer, 1_000_000_000 * ONE);
        vm.prank(payer);
        token.approve(address(mm), type(uint256).max);

        identity.mint(AGENT_ID, agent);
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp - 100);

        vm.label(address(mm), "MandateManager");
        vm.label(address(token), "USDC");
    }

    // -- amounts -----------------------------------------------------------

    /// Whole USDC to 6-decimal units. `usd(100)` is the JS suite's `usdc('100')`.
    ///
    /// The bound is not decoration. `whole * ONE` is uint256 arithmetic and the result is
    /// narrowed to uint96, so without this check a large argument would truncate into a
    /// small amount — and a test that meant to spend more than the cap would spend
    /// less than it and pass. Every current call site passes a literal (the largest
    /// is 5000), so this cannot fire today; it is here so that the first person to write
    /// `usd(fuzzInput)` gets a failure instead of a false green.
    function usd(uint256 whole) internal pure returns (uint96) {
        uint256 units = whole * ONE;
        require(units <= type(uint96).max, "usd(): exceeds uint96, would truncate");
        return uint96(units);
    }

    // -- parameter builders ------------------------------------------------

    /// Nothing set except the spender and the two empty arrays that every params
    /// struct needs. On its own this is an unbounded mandate and `createMandate` refuses
    /// it with `Unbounded()`.
    ///
    /// v2 widened what "unbounded" means, so read this before building on it: adding a
    /// `perTxCap`, or a window, or both, does NOT make the result creatable. Only
    /// `totalCap` or `expiresAt` does. Any test that builds from here and expects the
    /// grant to succeed — or to fail for some more specific reason than `Unbounded` —
    /// has to add one, and `withExpiry` is the simplest way.
    function emptyParams() internal view returns (MandateManager.MandateParams memory p) {
        p.spender = agent;
        p.windows = new MandateManager.WindowParams[](0);
        p.allowlist = new address[](0);
    }

    /// The JS suite's `simpleMandate`: 100 per transaction, 500 per rolling day,
    /// twelve buckets, any recipient — and since v2 a `FAR` expiry, because not one of
    /// those three is a lifetime bound. The model's helper carries the same horizon for
    /// the same reason.
    function simpleParams() internal view returns (MandateManager.MandateParams memory p) {
        p = emptyParams();
        p.perTxCap = usd(100);
        p.flags = F_PER_TX;
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(500), buckets: 12});
        p = withExpiry(p);
    }

    /// A single rolling window and no other AMOUNT bound — the shape the window tests
    /// want, so that a denial can only ever be OverWindowCap.
    ///
    /// Since v2 it also carries a `FAR` expiry, because a window alone is no longer a
    /// creatable mandate. That does not weaken the sentence above, and the reason is
    /// twofold: an expiry can produce only `Expired`, and `FAR` is uint40 max, so no
    /// run in this suite reaches it. If one ever did, the failure would be loud
    /// rather than silent in both places it could hide — `WindowFuzz` asserts that
    /// every refusal is `OverWindowCap` specifically, and `WindowInvariant`'s
    /// handler records the first refusal that is not, which
    /// `invariant_theWindowIsTheOnlyThingThatEverRefuses` then reads.
    function windowOnlyParams(uint32 lengthSeconds, uint96 cap, uint8 buckets)
        internal
        view
        returns (MandateManager.MandateParams memory p)
    {
        p = emptyParams();
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: lengthSeconds, cap: cap, buckets: buckets});
        p = withExpiry(p);
    }

    /// Give `p` the lifetime bound v2 requires, at the horizon that cannot interfere
    /// with anything — see `FAR` above for why it is uint40 max and why it is an expiry
    /// rather than a total.
    ///
    /// This is a `with*` helper rather than a bound `grant()` adds by itself, and that
    /// is deliberate. Making `grant` supply a bound would have repaired every failing
    /// test in this suite in one edit, and in the same edit stopped the suite from
    /// demonstrating that a real caller has to supply one. Every mandate here names its
    /// own horizon, either by calling this or by setting `expiresAt` and `F_EXPIRY` by
    /// hand. The model made the same call for the same reason.
    function withExpiry(MandateManager.MandateParams memory p)
        internal
        pure
        returns (MandateManager.MandateParams memory)
    {
        p.expiresAt = FAR;
        p.flags |= F_EXPIRY;
        return p;
    }

    function withAllowlist(MandateManager.MandateParams memory p, address one)
        internal
        pure
        returns (MandateManager.MandateParams memory)
    {
        p.allowlist = new address[](1);
        p.allowlist[0] = one;
        p.flags |= F_ALLOWLIST;
        return p;
    }

    function withCosign(MandateManager.MandateParams memory p, address cosigner, uint96 threshold)
        internal
        pure
        returns (MandateManager.MandateParams memory)
    {
        p.cosigner = cosigner;
        p.cosignThreshold = threshold;
        p.flags |= F_COSIGN;
        return p;
    }

    function withIdentity(MandateManager.MandateParams memory p, uint256 agentId, address expectedOwner)
        internal
        pure
        returns (MandateManager.MandateParams memory)
    {
        p.identity = MandateManager.IdentityGate({agentId: agentId, expectedOwner: expectedOwner});
        p.flags |= F_IDENTITY;
        return p;
    }

    function withCredential(
        MandateManager.MandateParams memory p,
        address validator,
        bytes32 requestHash,
        uint256 agentId,
        uint40 maxStaleness
    ) internal pure returns (MandateManager.MandateParams memory) {
        p.credential = MandateManager.CredentialGate({
            requestHash: requestHash,
            agentId: agentId,
            validator: validator,
            maxStaleness: maxStaleness,
            minResponse: 100 // ERC-8004: 100 == passed
        });
        p.flags |= F_CREDENTIAL;
        return p;
    }

    // -- actions -----------------------------------------------------------

    function nextNonce() internal returns (bytes32) {
        return bytes32(++_nonceCounter);
    }

    function grant(MandateManager.MandateParams memory p) internal returns (bytes32 id) {
        vm.prank(payer);
        id = mm.createMandate(bytes32(++_saltCounter), p);
    }

    /// Grant as the payer, expecting a refusal. Returns nothing, because nothing was created.
    ///
    /// The salt still advances, so a test can call this and then `grant` a corrected version of
    /// the same params without colliding on `MandateExists`.
    function grantReverts(MandateManager.MandateParams memory p, bytes4 selector) internal {
        vm.prank(payer);
        vm.expectRevert(selector);
        mm.createMandate(bytes32(++_saltCounter), p);
    }

    /// Spend as the agent, to the default vendor, with a fresh nonce.
    function pay(bytes32 id, uint256 amount) internal returns (bytes32) {
        vm.prank(agent);
        return mm.spend(id, vendor, amount, REF, nextNonce());
    }

    function payTo(bytes32 id, address to, uint256 amount) internal returns (bytes32) {
        vm.prank(agent);
        return mm.spend(id, to, amount, REF, nextNonce());
    }

    /// Spend with a caller-chosen nonce, for replay and idempotency tests.
    function payWithNonce(bytes32 id, address to, uint256 amount, bytes32 nonce) internal returns (bytes32) {
        vm.prank(agent);
        return mm.spend(id, to, amount, REF, nonce);
    }

    /// Attempt a spend and report the revert data instead of propagating it. Used
    /// where a test needs to inspect *which* denial came back, or to drive a loop
    /// in which most attempts are expected to be refused.
    function trySpend(bytes32 id, address to, uint256 amount, bytes32 nonce)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.prank(agent);
        (ok, err) = address(mm).call(abi.encodeCall(MandateManager.spend, (id, to, amount, REF, nonce)));
    }

    /**
     * Expect a spend to be refused with exactly this revert data.
     *
     * The prank is deliberately set BEFORE expectRevert. Both are cheatcode calls and
     * Foundry does not let one consume the other, but expectRevert applies to the next
     * real call, so anything that looks like a call must not sit between them.
     * Wrapping the pair here keeps every denial test in the right order instead of
     * relying on each one getting it right by hand.
     */
    function payReverts(bytes32 id, address to, uint256 amount, bytes memory expectedError) internal {
        bytes32 nonce = nextNonce();
        vm.prank(agent);
        vm.expectRevert(expectedError);
        mm.spend(id, to, amount, REF, nonce);
    }

    function payReverts(bytes32 id, address to, uint256 amount, bytes4 selector) internal {
        payReverts(id, to, amount, abi.encodeWithSelector(selector));
    }

    /// Denial for the default recipient, which is what most tests want.
    function payReverts(bytes32 id, uint256 amount, bytes4 selector) internal {
        payReverts(id, vendor, amount, abi.encodeWithSelector(selector));
    }

    function payReverts(bytes32 id, uint256 amount, bytes memory expectedError) internal {
        payReverts(id, vendor, amount, expectedError);
    }

    function overWindowCap(uint32 lengthSeconds, uint96 cap, uint256 used) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MandateManager.OverWindowCap.selector, lengthSeconds, cap, used);
    }

    // -- assertions --------------------------------------------------------

    /// First four bytes of revert data. `bytes memory` cannot be cast to bytes4
    /// directly, and getting this wrong compares zero to zero with no failing test.
    /// The extraction is done once here rather than inline at each call site.
    function selectorOf(bytes memory data) internal pure returns (bytes4 sel) {
        require(data.length >= 4, "selectorOf: revert data too short");
        assembly {
            sel := mload(add(data, 0x20))
        }
    }

    /// Widened to bytes32 because forge-std has no bytes4 assertEq overload, and
    /// bytes4 does not implicitly convert.
    ///
    /// This used to be non-`pure`, with a comment claiming "assertEq logs on failure".
    /// That was true of older forge-std; as of 1.9.6 the assertions route through
    /// `vm.assertEq` and are themselves `pure`, and solc emits Warning (2018) saying so.
    /// The comment outlived the fact it described.
    function assertRevertedWith(bytes memory err, bytes4 expected, string memory ctx) internal pure {
        assertEq(bytes32(selectorOf(err)), bytes32(expected), ctx);
    }
}
