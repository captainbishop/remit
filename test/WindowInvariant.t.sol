// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The handler the invariant fuzzer drives.
 *
 * Two things make this different from the bounded loop in WindowFuzz.t.sol. The fuzzer
 * chooses the *sequence* — how many spends, interleaved with how many idle gaps, in
 * what order — rather than following a shape fixed in advance, and that sequence
 * persists across calls, so state accumulated by call 40 is still there at call 400.
 *
 * The handler is itself the mandate's spender. Pranking from inside a handler is
 * possible but fragile once the fuzzer is choosing call order, so instead the mandate
 * is granted to `address(this)` and the handler simply spends in its own name.
 *
 * Bounds are applied with plain modulo rather than forge-std's `bound`, so the handler
 * needs no forge-std inheritance and cannot accidentally become a fuzz target for
 * inherited machinery.
 */
contract WindowHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MandateManager public immutable mm;
    address public immutable recipient;
    uint32 public immutable windowLength;
    uint32 public immutable subLength;
    uint96 public immutable cap;

    bytes32 public mandateId;

    uint64[] internal _ts;
    uint96[] internal _amt;

    uint256 public attempts;
    uint256 public refusals;

    /// The first refusal that was NOT a rolling-window denial, or zero if there has
    /// never been one. This is the anti-vacuity guard: if the handler were failing for
    /// some unrelated reason — an unset mandate, a dry account, a nonce collision —
    /// every window property below would hold trivially and the run would report
    /// success while testing nothing.
    bytes4 public unexpectedRefusal;

    uint256 private _nonce;

    constructor(MandateManager mm_, address recipient_, uint32 windowLength_, uint32 subLength_, uint96 cap_) {
        mm = mm_;
        recipient = recipient_;
        windowLength = windowLength_;
        subLength = subLength_;
        cap = cap_;
    }

    function setMandate(bytes32 id) external {
        require(mandateId == bytes32(0), "mandate already set");
        mandateId = id;
    }

    // ------------------------------------------------------ fuzzed entry points

    /// An arbitrary spend, up to a third of the cap so several fit in a window.
    function spendSome(uint256 amountSeed, uint256 timeSeed) external {
        _advance(timeSeed);
        _attempt(uint96(1 + (amountSeed % (uint256(cap) / 3))));
    }

    /// The greedy move: ask for exactly the headroom the contract reports. This is
    /// what leaves the window exactly full, so any bug that frees a bucket one instant
    /// early becomes an immediate breach instead of being absorbed by slack.
    function spendAll(uint256 timeSeed) external {
        _advance(timeSeed);
        uint256 room = mm.windowRemaining(mandateId, 0);
        _attempt(room == 0 ? 1 : uint96(room)); // probe with 1 when full: must be refused
    }

    /// Let time pass without spending, so the fuzzer can explore ageing as a move in
    /// its own right rather than only as a side effect of spending.
    function idle(uint256 timeSeed) external {
        _advance(timeSeed);
    }

    // ------------------------------------------------------------------ ledger

    function ledgerLength() external view returns (uint256) {
        return _ts.length;
    }

    function entry(uint256 i) external view returns (uint64 ts, uint96 amount) {
        return (_ts[i], _amt[i]);
    }

    // --------------------------------------------------------------- internals

    /**
     * Advance the clock by a step drawn from a set aimed at bucket and window
     * boundaries.
     *
     * Uniformly random deltas would be much worse inputs: with a 7200-second bucket,
     * a random step lands exactly on a boundary about once in 7200 tries, and boundary
     * behaviour is the entire question. Zero is in the set on purpose — Arc produces
     * sub-second blocks that share a timestamp, so two spends at the same instant is
     * ordinary traffic, not an edge case.
     */
    function _advance(uint256 seed) private {
        uint256 l = windowLength;
        uint256 s = subLength;
        uint256 pick = seed % 11;
        uint256 dt;

        if (pick == 0) dt = 0;
        else if (pick == 1) dt = 1;
        else if (pick == 2) dt = s - 1;
        else if (pick == 3) dt = s;
        else if (pick == 4) dt = s + 1;
        else if (pick == 5) dt = l - 1;
        else if (pick == 6) dt = l;
        else if (pick == 7) dt = l + 1;
        else if (pick == 8) dt = l + s - 1;
        else if (pick == 9) dt = l + s;
        else dt = l + s + 1;

        if (dt != 0) vm.warp(block.timestamp + dt);
    }

    function _attempt(uint96 amount) private {
        ++attempts;
        bytes32 nonce = bytes32(++_nonce);

        // A low-level call rather than try/catch, matching Base.trySpend: the revert
        // data is needed to classify the refusal, and a refusal must not abort the
        // handler.
        (bool ok, bytes memory err) = address(mm)
            .call(
                abi.encodeCall(
                    MandateManager.spend, (mandateId, recipient, uint256(amount), bytes32("invariant"), nonce)
                )
            );

        if (ok) {
            _ts.push(uint64(block.timestamp));
            _amt.push(amount);
        } else {
            ++refusals;
            bytes4 sel = _selectorOf(err);
            if (sel != MandateManager.OverWindowCap.selector && unexpectedRefusal == bytes4(0)) {
                unexpectedRefusal = sel;
            }
        }
    }

    function _selectorOf(bytes memory data) private pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0xffffffff); // no selector at all: still wrong
        assembly {
            sel := mload(add(data, 0x20))
        }
    }
}

/**
 * Stateful invariant test for the rolling-window engine.
 *
 * The property is the same one WindowFuzz.t.sol checks, but here the fuzzer builds the
 * call sequence, which reaches states a hand-written loop does not: long runs of idle
 * time punctuated by greedy bursts, spends that land repeatedly on one ring slot, and
 * sequences long enough to wrap the ring many times over.
 *
 * The efficiency decision worth explaining: the invariant checks only the trailing
 * window ending at `block.timestamp`, not the window ending at every accepted spend.
 * That is not a weakening. The invariant is evaluated after EVERY handler call, and a
 * spend only enters the ledger during a call, so the union of the per-call checks
 * already covers every window that ends at an accepted spend — which is the only place
 * a maximum can occur, since usage is constant between spends and only decays with
 * time. Checking all of them on every call would make the inner work O(depth^3): at
 * the deep profile's runs=2000, depth=256 that is on the order of 10^10 iterations and
 * the run stops being something anyone waits for. This way it is O(depth^2), which is
 * about 65 million even at deep settings and merely slow.
 *
 * NOTE: assumes forge-std >= 1.9, where the assertion helpers are `pure` and can be
 * called from a `view` invariant. The invariants are deliberately `view` — an invariant
 * that mutates state corrupts the very sequence it is judging.
 */
contract WindowInvariantTest is Base {
    uint32 internal constant L = DAY;
    uint8 internal constant BUCKETS = 12;
    uint32 internal constant S = DAY / 12; // 7200
    uint96 internal constant CAP = 1000e6; // 1000 USDC

    WindowHandler internal handler;
    bytes32 internal id;

    function setUp() public override {
        super.setUp();

        handler = new WindowHandler(mm, vendor, L, S, CAP);
        vm.label(address(handler), "WindowHandler");

        MandateManager.MandateParams memory p = emptyParams();
        p.spender = address(handler); // the handler spends in its own name
        p.windows = new MandateManager.WindowParams[](1);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: L, cap: CAP, buckets: BUCKETS});
        // v2 requires a lifetime bound and a window is not one. `FAR` is uint40 max, and
        // the arithmetic that matters here is the campaign's reachable clock: the start
        // is 1,000,000 and `_advance` adds at most `L + S + 1` = 93,601 seconds per call,
        // so even the deep profile's depth of 256 lands near 25,000,000 — five orders of
        // magnitude short of the horizon. If that ever stopped being true,
        // `invariant_theWindowIsTheOnlyThingThatEverRefuses` below would report the
        // `Expired` selector instead of allowing a green run that proves nothing.
        p = withExpiry(p);
        id = grant(p);
        handler.setMandate(id);

        // Restrict the fuzzer to the handler's three moves. Left unrestricted it would
        // call MandateManager and the mocks directly as well, spending most of its
        // budget on calls that revert at the front door and prove nothing.
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = WindowHandler.spendSome.selector;
        sels[1] = WindowHandler.spendAll.selector;
        sels[2] = WindowHandler.idle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // -------------------------------------------------------- the main property

    /// No interval of length L ever contains more than `cap` of accepted spending,
    /// measured from an independent ledger rather than from the contract's own ring.
    function invariant_exactTrailingWindowNeverExceedsTheCap() public view {
        uint256 t = block.timestamp;
        uint256 usage;
        uint256 n = handler.ledgerLength();

        for (uint256 i = 0; i < n; ++i) {
            (uint64 ts, uint96 amount) = handler.entry(i);
            if (uint256(ts) + L > t) usage += amount; // the half-open window (t-L, t]
        }

        assertLe(usage, CAP, "exact trailing window exceeded the cap");

        // The conservatism direction. The ring may count MORE than the exact window —
        // that is the documented K/(K+1) cost — but it must never count less, or the
        // headroom it advertises is a hole.
        assertLe(
            mm.windowRemaining(id, 0) + usage,
            CAP,
            "the ring under-counted: advertised headroom plus real usage exceeds the cap"
        );
    }

    // ------------------------------------------------------------ bookkeeping

    /**
     * The contract's own counters must agree with the independent ledger, and the
     * money must have actually moved.
     *
     * This catches a different failure class from the cap property: a contract that
     * recorded a spend it did not transfer, or transferred an amount it did not
     * record, would satisfy every cap while being unreconcilable — and reconciliation
     * against the event stream is the whole reason `Spend` carries `totalSpent`.
     */
    function invariant_theContractsBooksAgreeWithTheLedger() public view {
        uint256 n = handler.ledgerLength();
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) {
            (, uint96 amount) = handler.entry(i);
            sum += amount;
        }

        MandateManager.Mandate memory m = mm.getMandate(id);
        assertEq(m.spendCount, n, "spendCount must equal the number of accepted spends");
        assertEq(m.totalSpent, sum, "totalSpent must equal the sum of accepted spends");
        assertEq(token.balanceOf(vendor), sum, "every accepted spend moved exactly its amount");
        assertEq(token.balanceOf(address(mm)), 0, "the contract must never hold funds");
    }

    /// The window is the only bound on this mandate, so it must be the only reason a
    /// spend was ever refused. If anything else refused, the properties above are
    /// holding for the wrong reason and the run is vacuous.
    function invariant_theWindowIsTheOnlyThingThatEverRefuses() public view {
        assertEq(
            bytes32(handler.unexpectedRefusal()),
            bytes32(0),
            "a spend was refused for a reason other than the rolling window"
        );
    }

    // ------------------------------------------------------ anti-vacuity guard

    /**
     * A stateful fuzz run that accepts nothing passes every invariant above.
     *
     * The invariants cannot assert "at least one spend happened" — that would fail on
     * the first call if the fuzzer happened to pick `idle`, so the handler is driven
     * by hand here instead, proving it can accept, can be refused, and is refused only
     * by the window. If this test fails, the invariant run is not testing the engine.
     */
    function test_handlerCanActuallySpend_soTheInvariantsAreNotVacuous() public {
        for (uint256 i = 0; i < 20; ++i) {
            handler.spendSome(uint256(keccak256(abi.encode("amount", i))), uint256(keccak256(abi.encode("time", i))));
        }

        assertGt(handler.attempts(), 0, "the handler must have tried");
        assertGt(handler.ledgerLength(), 0, "the handler must be able to spend at all");
        assertEq(mm.getMandate(id).spendCount, handler.ledgerLength(), "and the contract agrees");
        assertEq(bytes32(handler.unexpectedRefusal()), bytes32(0), "only the window may refuse");
    }

    /// The greedy move must reach the refusing state, or the cap is never actually
    /// tested. With no time passing, the first greedy spend takes the entire cap and
    /// every probe after it must be denied.
    function test_greedyHandlerReachesTheCap_soRefusalIsExercised() public {
        for (uint256 i = 0; i < 6; ++i) {
            handler.spendAll(0); // timeSeed 0 == no time passes
        }

        assertEq(mm.windowRemaining(id, 0), 0, "the greedy spend must consume the whole window");
        assertEq(handler.ledgerLength(), 1, "and only the first attempt can succeed");
        assertEq(handler.refusals(), 5, "the rest are refused");
        assertEq(bytes32(handler.unexpectedRefusal()), bytes32(0), "by the window, specifically");
        assertEq(token.balanceOf(vendor), CAP, "with exactly the cap paid out");
    }
}
