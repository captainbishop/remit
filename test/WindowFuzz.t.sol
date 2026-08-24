// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The exact-ledger property test.
 *
 * Everything else in this suite checks cases someone thought of. This checks the
 * property the design actually claims, against an independent oracle:
 *
 *     no interval of length L ever contains more than `cap` of accepted spending.
 *
 * The oracle is a brute-force replay. Every accepted spend is recorded as a
 * (timestamp, amount) pair, and after each step the exact trailing window (t-L, t] is
 * summed the slow honest way and compared against the cap. The bucket ring is an
 * APPROXIMATION of that sum; this test is the definition it approximates, so a
 * disagreement is unambiguous — no interpretation, no second model to be wrong in the
 * same way.
 *
 * The second assertion is the conservatism direction, and it is the one that would
 * catch a subtle indexing bug: the ring's reported remaining headroom plus the true
 * usage must never exceed the cap. Equivalently, the ring must never count LESS than
 * the exact window. A ring that over-counts is merely stingy; one that under-counts
 * is a bypass.
 *
 * Time steps are deliberately not uniform. Uniformly random offsets would almost
 * never land on a bucket or window boundary, which is exactly where a wrong
 * implementation fails, so the step sizes are drawn from a set aimed at boundaries and
 * one second either side of them — plus zero, because Arc's sub-second blocks share a
 * timestamp and that is a real input, not an edge case.
 */
contract WindowFuzzTest is Base {
    uint256 internal constant STEPS = 100;

    /**
     * Replay state, held in memory rather than as plain locals.
     *
     * Each test below needs a dozen values alive at once — the mandate, the window
     * geometry, the clock, the rng, and the growing ledger. Solidity's legacy code
     * generator can only reach sixteen slots down the EVM stack, and a frame that
     * wide overflows it: the compiler aborts with "Stack too deep" at whichever
     * expression happens to sit deepest, which was the innermost ledger read.
     * Boxing the state into one struct costs a single pointer instead of a dozen
     * slots, and needs no change to how the contract itself is compiled.
     *
     * Please do not flatten this back into separate locals to make it read more
     * plainly. It will compile for a while and then stop, somewhere unrelated.
     */
    struct Run {
        bytes32 id;
        uint32 l; // window length under test, seconds
        uint32 s; // bucket span, l / buckets
        uint96 cap;
        uint64 t; // the current block timestamp
        uint256 rng;
        uint64[] ts; // ledger: when each accepted spend landed
        uint96[] amts; // ledger: how much it was for
        uint256 n; // how much of the ledger is filled
    }

    /// Bucket counts that divide 86400 evenly, so the window is constructible. The
    /// suite covers K from tiny (where the K+1 overhead is enormous) to 24 (the
    /// precise end of the practical range).
    function bucketsFor(uint256 idx) internal pure returns (uint32) {
        uint32[6] memory ks;
        ks[0] = 2;
        ks[1] = 3;
        ks[2] = 4;
        ks[3] = 6;
        ks[4] = 12;
        ks[5] = 24;
        return ks[idx % 6];
    }

    /// Step sizes aimed at the places an off-by-one lives.
    function stepFor(uint256 rng, uint32 s, uint32 l) internal pure returns (uint64) {
        uint256 pick = rng % 11;
        if (pick == 0) return 0; // same second: two blocks, one timestamp
        if (pick == 1) return 1;
        if (pick == 2) return uint64(s) - 1;
        if (pick == 3) return uint64(s);
        if (pick == 4) return uint64(s) + 1;
        if (pick == 5) return uint64(l) - 1;
        if (pick == 6) return uint64(l);
        if (pick == 7) return uint64(l) + 1;
        if (pick == 8) return uint64(l) + uint64(s) - 1;
        if (pick == 9) return uint64(l) + uint64(s);
        return uint64(l) + uint64(s) + 1;
    }

    /// Allocate the ledger and start the clock on a bucket boundary, so that the
    /// step sizes above land exactly where they intend to. The mandate is granted by
    /// the caller, because the shape of it differs per test.
    function emptyRun(uint32 l, uint32 s, uint96 cap) internal view returns (Run memory r) {
        r.l = l;
        r.s = s;
        r.cap = cap;
        r.ts = new uint64[](STEPS);
        r.amts = new uint96[](STEPS);
        r.t = uint64(((block.timestamp / s) + 1) * s);
    }

    /// Append an accepted spend to the ledger at the current instant. `Run memory`
    /// is passed by reference between internal functions, so this writes through to
    /// the caller's struct — including the `++r.n`.
    function record(Run memory r, uint96 amount) internal pure {
        r.ts[r.n] = r.t;
        r.amts[r.n] = amount;
        ++r.n;
    }

    /// The oracle: sum the ledger over the exact half-open window (t-L, t]. Written
    /// as `ts + L > t` rather than `ts > t - L` so that an early timestamp cannot
    /// underflow the subtraction.
    function exactUsage(Run memory r, uint32 windowLen) internal pure returns (uint256 used) {
        for (uint256 j = 0; j < r.n; ++j) {
            if (uint256(r.ts[j]) + windowLen > r.t) used += r.amts[j];
        }
    }

    // ------------------------------------------------------------ one window

    function testFuzz_exactTrailingWindowNeverExceedsTheCap(uint256 seed, uint256 kIdx) public {
        uint32 buckets = bucketsFor(kIdx);
        Run memory r = emptyRun(DAY, DAY / buckets, usd(1000));
        r.id = grant(windowOnlyParams(r.l, r.cap, uint8(buckets)));
        r.rng = seed;

        for (uint256 i = 0; i < STEPS; ++i) {
            r.rng = uint256(keccak256(abi.encode(r.rng, i)));

            r.t += stepFor(r.rng, r.s, r.l);
            vm.warp(r.t);

            // Scoped so the attempt's locals are released before the assertions
            // below, which is the other half of keeping this frame narrow.
            {
                uint96 amount = uint96(1 + ((r.rng >> 128) % (uint256(r.cap) / 4)));

                (bool ok, bytes memory err) = trySpend(r.id, vendor, amount, bytes32(i + 1));
                if (ok) {
                    record(r, amount);
                } else {
                    // In this configuration the window is the only bound, so any
                    // other denial means something unrelated is broken and the
                    // property below would be passing for the wrong reason.
                    assertRevertedWith(err, MandateManager.OverWindowCap.selector, "only the window may deny");
                }
            }

            uint256 trueUsage = exactUsage(r, r.l);

            assertLe(trueUsage, r.cap, "exact trailing window exceeded the cap");
            assertLe(
                mm.windowRemaining(r.id, 0) + trueUsage,
                r.cap,
                "the ring under-counted: reported headroom plus real usage exceeds the cap"
            );
        }

        // Guard against a vacuous pass. If the run accepted nothing, the property
        // above is trivially true and proves nothing about the engine. `r.n` is the
        // count of accepted spends, since nothing else appends to the ledger.
        assertGt(r.n, 0, "the run must accept at least one spend");
    }

    /**
     * The greedy adversary: always ask for exactly the headroom the contract admits
     * to, at boundary-aligned instants.
     *
     * This is a strictly harder input distribution than random amounts, because every
     * accepted spend leaves the window exactly full — so any bug that releases a
     * bucket one instant early is immediately converted into a breach rather than
     * being absorbed by slack. This is the shape that found the original tumbling-
     * window flaw in the model.
     */
    function testFuzz_greedyAdversaryCannotBreachTheExactWindow(uint256 seed, uint256 kIdx) public {
        uint32 buckets = bucketsFor(kIdx);
        Run memory r = emptyRun(DAY, DAY / buckets, usd(1000));
        r.id = grant(windowOnlyParams(r.l, r.cap, uint8(buckets)));
        r.rng = seed;

        for (uint256 i = 0; i < STEPS; ++i) {
            r.rng = uint256(keccak256(abi.encode(r.rng, i)));
            r.t += stepFor(r.rng, r.s, r.l);
            vm.warp(r.t);

            uint256 room = mm.windowRemaining(r.id, 0);
            if (room == 0) {
                // Probe anyway: a single base unit must still be refused.
                (bool accepted,) = trySpend(r.id, vendor, 1, bytes32(i + 1));
                assertFalse(accepted, "a full window must refuse even one base unit");
                continue;
            }

            (bool ok,) = trySpend(r.id, vendor, room, bytes32(i + 1));
            assertTrue(ok, "the contract must honour the headroom it reported");
            record(r, uint96(room));

            assertLe(exactUsage(r, r.l), r.cap, "greedy spending breached the exact window");
        }
        assertGt(r.n, 0, "the run must accept at least one spend");
    }

    // --------------------------------------------------------- two windows

    /**
     * Two windows of different lengths must both hold simultaneously.
     *
     * Composition is where an implementation that shares state between windows, or
     * that commits window 0 before deciding about window 1, goes wrong. The exact
     * check is run independently for each window against the same ledger.
     */
    function testFuzz_twoWindowsBothHoldExactly(uint256 seed) public {
        uint32 longL = DAY; // daily, 12 buckets
        uint96 longCap = usd(600);

        // The run's own window is the hourly one, six buckets.
        Run memory r = emptyRun(3600, 3600 / 6, usd(100));
        r.rng = seed;

        {
            MandateManager.MandateParams memory p = emptyParams();
            p.windows = new MandateManager.WindowParams[](2);
            p.windows[0] = MandateManager.WindowParams({lengthSeconds: r.l, cap: r.cap, buckets: 6});
            p.windows[1] = MandateManager.WindowParams({lengthSeconds: longL, cap: longCap, buckets: 12});
            r.id = grant(p);
        }

        for (uint256 i = 0; i < STEPS; ++i) {
            r.rng = uint256(keccak256(abi.encode(r.rng, i)));
            r.t += stepFor(r.rng, r.s, r.l);
            vm.warp(r.t);

            {
                uint96 amount = uint96(1 + ((r.rng >> 128) % (uint256(r.cap) / 2)));
                (bool ok, bytes memory err) = trySpend(r.id, vendor, amount, bytes32(i + 1));
                if (ok) {
                    record(r, amount);
                } else {
                    assertRevertedWith(err, MandateManager.OverWindowCap.selector, "only the windows may deny");
                }
            }

            // Both windows read the same ledger. A ring that shared state between
            // windows, or that committed window 0 before deciding about window 1,
            // shows up here as one of these two holding and the other not.
            assertLe(exactUsage(r, r.l), r.cap, "hourly window breached");
            assertLe(exactUsage(r, longL), longCap, "daily window breached");
        }
        assertGt(r.n, 0, "the run must accept at least one spend");
    }

    // ---------------------------------------------------- scalar bounds too

    /// The lifetime cap is not a window and needs no ring, but it is worth fuzzing
    /// because it is the one bound with an unchecked-looking addition in front of it.
    /// Total spending must never exceed the cap regardless of how the spends arrive.
    function testFuzz_lifetimeCapIsNeverExceeded(uint256 seed) public {
        uint96 total = usd(500);
        MandateManager.MandateParams memory p = emptyParams();
        p.totalCap = total;
        p.perTxCap = usd(120);
        p.flags = F_TOTAL | F_PER_TX;
        bytes32 id = grant(p);

        uint256 rng = seed;
        uint256 sum;
        for (uint256 i = 0; i < 60; ++i) {
            rng = uint256(keccak256(abi.encode(rng, i)));
            uint256 amount = 1 + (rng % uint256(usd(150))); // deliberately spills over perTxCap
            (bool ok,) = trySpend(id, vendor, amount, bytes32(i + 1));
            if (ok) sum += amount;

            assertEq(mm.getMandate(id).totalSpent, sum, "totalSpent must equal accepted spending exactly");
            assertLe(sum, total, "lifetime cap exceeded");
            assertEq(token.balanceOf(vendor), sum, "and every accepted spend moved its amount");
        }
    }
}
