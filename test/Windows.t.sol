// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The rolling-window engine.
 *
 * This is the only novel part of the contract and the only part where a
 * plausible implementation is wrong in a way that costs money. The naive version is
 * a TUMBLING window: keep a counter, reset it when the period rolls over. It is
 * cheap, it reads correctly, and it lets an adversary spend the full cap in the last
 * second of one period and the full cap in the first second of the next — twice the
 * intended limit inside two seconds. Every "spent this month" counter written
 * without thinking has this property.
 *
 * Remit keeps a ring of K+1 sub-period buckets and counts every bucket whose index
 * is at least `currentBucket - K` at FULL weight. The extra slot is what makes the
 * approximation conservative in the safe direction: it can refuse a spend the exact
 * trailing window would have allowed, but it can never allow one the exact window
 * would have refused. The price is measured, not hand-waved, in the throughput test
 * at the bottom of this file: sustained rate settles at K/(K+1) of nominal.
 *
 * Notation used throughout: L = window length, K = bucket count, S = L/K = sub-period.
 */
contract WindowsTest is Base {
    uint32 internal constant K = 12;
    uint32 internal constant S = DAY / 12; // 7200s
    uint96 internal constant CAP = 1200e6; // 1200 USDC

    /// Start every window test on a sub-bucket boundary so the arithmetic in the
    /// comments is exact rather than approximate.
    function alignToBucket() internal returns (uint64 t0) {
        t0 = uint64(((block.timestamp / S) + 1) * S);
        vm.warp(t0);
    }

    // ------------------------------------------------------ the core attack

    /**
     * ATTACK: the tumbling-window boundary burst.
     *
     * Fill the window completely, then probe every instant on and around the
     * sub-bucket grid for a full window length. A tumbling implementation would open
     * a hole at whichever instant it calls the period boundary. The ring has no
     * boundary to find, so the answer is "denied" at all 36 probes, and the reported
     * `used` never partially decays.
     */
    function test_ATTACK_tumblingWindowBoundaryBurst_findsNoHole() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        uint64 t0 = alignToBucket();

        pay(id, CAP);
        assertEq(mm.windowRemaining(id, 0), 0, "window is full");

        for (uint64 i = 1; i <= K; ++i) {
            for (uint64 d = 0; d < 3; ++d) {
                // i*S - 1, i*S, i*S + 1 — the boundary and one second either side.
                vm.warp(t0 + i * S + d - 1);
                payReverts(id, 1, overWindowCap(DAY, CAP, CAP));
            }
        }
        assertEq(token.balanceOf(vendor), CAP, "36 refused attempts moved nothing");
    }

    /**
     * DOCUMENTED COST: a full refill takes L + S, not L.
     *
     * At exactly one window length after the spend, the bucket holding it satisfies
     * `bucketIndex >= currentBucket - K` by equality, so it is still counted. It
     * falls out one sub-period later. This is the K+1 conservatism stated as a
     * deadline, and it is the single most surprising thing about the engine for
     * anyone reading the storage layout — hence its own test rather than a comment.
     */
    function test_DOCUMENTED_COST_fullRefillTakesWindowPlusOneSubPeriod() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        uint64 t0 = alignToBucket();
        pay(id, CAP);

        vm.warp(t0 + DAY + S - 1); // the last denied instant
        assertEq(mm.windowRemaining(id, 0), 0);
        payReverts(id, 1, overWindowCap(DAY, CAP, CAP));

        vm.warp(t0 + DAY + S); // fully aged out
        assertEq(mm.windowRemaining(id, 0), CAP, "the whole cap is back");
        pay(id, CAP);
        assertEq(token.balanceOf(vendor), uint256(CAP) * 2);
    }

    /**
     * REGRESSION: a spend late in a sub-bucket is still counted K buckets later.
     *
     * The model once floored the spend to its bucket start and then aged from there,
     * which let a spend at the very end of a bucket expire almost a full sub-period
     * early — a real leak, small per event and unbounded in aggregate. The fix is
     * that aging is a comparison of bucket INDICES, never of timestamps.
     */
    function test_REGRESSION_spendLateInASubBucketIsStillCountedKBucketsLater() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        uint64 t0 = alignToBucket();

        vm.warp(t0 + S - 1); // final second of bucket b
        pay(id, CAP);

        vm.warp(t0 + S - 1 + DAY); // exactly one window later
        payReverts(id, 1, overWindowCap(DAY, CAP, CAP));

        vm.warp(t0 + S - 1 + DAY + S);
        assertEq(mm.windowRemaining(id, 0), CAP, "released only after the bucket index rolls");
    }

    // -------------------------------------------------------- aging shape

    /// Headroom returns bucket by bucket, not all at once. Twelve spends of 100 fill
    /// the cap; each then ages out one sub-period apart.
    function test_headroom_returnsIncrementallyAsBucketsAgeOut() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        uint64 t0 = alignToBucket();

        for (uint64 i = 0; i < K; ++i) {
            vm.warp(t0 + i * S);
            pay(id, usd(100));
        }
        assertEq(mm.windowRemaining(id, 0), 0, "12 x 100 fills a cap of 1200");

        // One sub-period after the last spend, the oldest bucket is still in range.
        vm.warp(t0 + K * S);
        assertEq(mm.windowRemaining(id, 0), 0);

        // One more, and exactly the first 100 comes back — not more.
        vm.warp(t0 + (K + 1) * S);
        assertEq(mm.windowRemaining(id, 0), usd(100), "exactly one bucket released");
        pay(id, usd(100));
        payReverts(id, 1, overWindowCap(DAY, CAP, CAP));

        vm.warp(t0 + (K + 2) * S);
        assertEq(mm.windowRemaining(id, 0), usd(100), "and then the next one");
    }

    /// A long silence must leave no ghosts. The ring is indexed modulo K+1, so a jump
    /// of many multiples of the ring size lands on slots holding ancient indices; they
    /// must read as empty rather than as fresh spending.
    function test_longIdleGap_clearsTheWindowCompletely() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        alignToBucket();
        pay(id, CAP);

        vm.warp(block.timestamp + 365 days);
        assertEq(mm.windowRemaining(id, 0), CAP, "no stale bucket survives a year");
        pay(id, CAP);
        assertEq(mm.getMandate(id).totalSpent, uint256(CAP) * 2);
    }

    /**
     * Arc produces sub-second blocks, and block timestamps are non-decreasing but
     * NOT strictly increasing — several blocks in a row can carry the same second.
     * Two spends at an identical timestamp must therefore both count. If they landed
     * in different buckets, or one overwrote the other, the cap would be bypassable
     * simply by transacting quickly, which on a 500ms chain is not a hard ask.
     */
    function test_repeatedIdenticalTimestamps_bothCount() public {
        bytes32 id = grant(windowOnlyParams(DAY, usd(100), uint8(K)));
        alignToBucket();

        pay(id, usd(60));
        payReverts(id, usd(60), overWindowCap(DAY, usd(100), usd(60)));
        pay(id, usd(40)); // exactly to the cap, same second
        assertEq(mm.windowRemaining(id, 0), 0);
        assertEq(token.balanceOf(vendor), usd(100));
    }

    // ------------------------------------------------------- clock attacks

    /**
     * ATTACK: a backwards clock cannot erase already-counted spending.
     *
     * Arc's timestamps are non-decreasing, so this should be impossible — but the
     * contract must not DEPEND on that, because "the sequencer is honest" is not a
     * security property. Buckets are counted by index comparison, and a future index
     * is never below `current - K`, so rewinding only makes the window stricter.
     */
    function test_ATTACK_backwardsClockCannotRefillTheWindow() public {
        bytes32 id = grant(windowOnlyParams(DAY, usd(100), uint8(K)));
        uint64 t0 = alignToBucket();

        vm.warp(t0 + K * S);
        pay(id, usd(100));

        vm.warp(t0); // rewind a full window
        payReverts(id, 1, overWindowCap(DAY, usd(100), usd(100)));
        assertEq(mm.windowRemaining(id, 0), 0, "spending from the future still counts");
    }

    /**
     * ATTACK: rewind by exactly K+1 sub-periods, landing on the SAME ring slot.
     *
     * This is the one input that reaches the ring's live-collision branch. Slot
     * (b+13) % 13 == b % 13, so a write for bucket b finds a slot already holding
     * bucket b+13. Overwriting would erase 100 USDC of counted spending; the branch
     * accumulates instead, which is why the second spend below lands on top of the
     * first rather than replacing it.
     */
    function test_ATTACK_rewindOntoTheSameRingSlot_accumulatesRatherThanOverwrites() public {
        bytes32 id = grant(windowOnlyParams(DAY, usd(150), uint8(K)));
        uint64 t0 = alignToBucket();

        vm.warp(t0 + (K + 1) * S); // bucket b+13
        pay(id, usd(100));

        vm.warp(t0); // bucket b — same ring slot
        assertEq(mm.windowRemaining(id, 0), usd(50), "the future spend is still counted");
        pay(id, usd(50)); // must accumulate into the occupied slot

        // Had the slot been overwritten, 100 more would now fit. It must not.
        assertEq(mm.windowRemaining(id, 0), 0, "150 total, not 50");
        payReverts(id, 1, overWindowCap(DAY, usd(150), usd(150)));
    }

    // ---------------------------------------------------- composed windows

    /**
     * Two windows compose, and the denial names the one that actually bound.
     *
     * A daily cap of 500 with a weekly cap of 1000 is the shape a real payer wants:
     * a fast limit for blast radius, a slow one for budget. After two daily cycles
     * the daily window is empty and the weekly is full, so the refusal must cite the
     * WEEK. An agent that cannot tell which limit it hit cannot decide whether to
     * retry in an hour or escalate to a human, so the error carries the window
     * length, its cap, and the amount used — and this test pins all three.
     */
    function test_multipleWindows_denialNamesTheBindingWindow() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](2);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(500), buckets: 12});
        p.windows[1] = MandateManager.WindowParams({lengthSeconds: WEEK, cap: usd(1000), buckets: 7});
        p = withExpiry(p); // v2: two windows are still not a lifetime bound
        bytes32 id = grant(p);

        uint64 t0 = uint64(((block.timestamp / DAY) + 1) * DAY);
        vm.warp(t0);

        pay(id, usd(500)); // daily full, weekly at 500

        vm.warp(t0 + DAY + S); // daily fully refilled; weekly still holds the first 500
        assertEq(mm.windowRemaining(id, 0), usd(500), "daily recovered");
        assertEq(mm.windowRemaining(id, 1), usd(500), "weekly did not");
        pay(id, usd(500)); // weekly now exactly at its cap

        vm.warp(t0 + 2 * (DAY + S));
        assertEq(mm.windowRemaining(id, 0), usd(500), "daily recovered again");
        assertEq(mm.windowRemaining(id, 1), 0, "weekly is spent");
        payReverts(id, 1, overWindowCap(WEEK, usd(1000), usd(1000)));
    }

    /**
     * A spend refused by the SECOND window must not consume the first.
     *
     * `_checkAndCommitWindows` checks and commits each window in turn, so window 0 is
     * already written to storage when window 1 raises OverWindowCap. Correctness here
     * rests entirely on the whole transaction reverting. This is the property the
     * JavaScript model cannot express — it has no rollback, so it separates `evaluate`
     * from `commit` to fake one — and it is the clearest single reason this suite
     * exists alongside the model rather than instead of it.
     */
    function test_refusalByLaterWindow_doesNotConsumeEarlierWindows() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](2);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(500), buckets: 12});
        p.windows[1] = MandateManager.WindowParams({lengthSeconds: WEEK, cap: usd(100), buckets: 7});
        p = withExpiry(p); // v2: two windows are still not a lifetime bound
        bytes32 id = grant(p);
        alignToBucket();

        uint256 dailyBefore = mm.windowRemaining(id, 0);
        assertEq(dailyBefore, usd(500));

        // Fits the daily window, breaches the weekly one.
        payReverts(id, usd(300), overWindowCap(WEEK, usd(100), 0));

        assertEq(mm.windowRemaining(id, 0), dailyBefore, "window 0 must be untouched");
        assertEq(mm.getMandate(id).totalSpent, 0, "and nothing recorded anywhere");
        assertEq(token.balanceOf(vendor), 0);

        // Proof the daily window really is intact: the full 500 is still spendable
        // in pieces that the weekly window tolerates.
        pay(id, usd(100));
        assertEq(mm.windowRemaining(id, 0), usd(400));
    }

    // -------------------------------------------------------- calibration

    /**
     * DOCUMENTED COST: sustained throughput settles at K/(K+1) of nominal.
     *
     * A payer who writes "1200 per day" and spends greedily will observe about
     * 1200 per 1.083 days. That is the price of never being wrong in the permissive
     * direction, and it is a number the payer should see in the docs rather than
     * discover from a refused invoice. Raising K shrinks the gap and costs one SLOAD
     * per bucket per window per spend — which is why the gas report decides K, not
     * taste.
     */
    function test_DOCUMENTED_COST_sustainedThroughputIsKOverKPlusOne() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(K)));
        uint64 t0 = alignToBucket();

        uint256 steps = 130; // ten full refill cycles of K+1 = 13 sub-periods
        uint256 total;
        for (uint256 i = 0; i < steps; ++i) {
            vm.warp(t0 + uint64(i) * S);
            uint256 room = mm.windowRemaining(id, 0);
            if (room > 0) {
                pay(id, room);
                total += room;
            }
        }

        uint256 cycles = steps / (K + 1);
        assertEq(total, uint256(CAP) * cycles, "one full cap per K+1 sub-periods, exactly");
        assertLt(total, (uint256(CAP) * steps) / K, "and strictly below the nominal cap-per-K rate");

        // Stated as the ratio the docs quote, in basis points, so a change to the
        // ring arithmetic shows up as a number a human recognises.
        uint256 ratioBps = (total * 10_000) / ((uint256(CAP) * steps) / K);
        assertApproxEqAbs(ratioBps, 9230, 30, "K/(K+1) at K=12 is ~92.3%");
    }

    /// Conservative is not the same as useless. At K=24 the overhead is one
    /// twenty-fifth of the window — about 4% — which is the regime a payer who cares
    /// about precision should be pointed at.
    function test_higherBucketCount_shrinksTheOverhead() public {
        uint32 buckets = 24;
        uint32 sub = DAY / buckets; // 3600
        bytes32 id = grant(windowOnlyParams(DAY, CAP, uint8(buckets)));

        uint64 t0 = uint64(((block.timestamp / sub) + 1) * sub);
        vm.warp(t0);
        pay(id, CAP);

        vm.warp(t0 + DAY + sub - 1);
        assertEq(mm.windowRemaining(id, 0), 0);

        vm.warp(t0 + DAY + sub);
        assertEq(mm.windowRemaining(id, 0), CAP, "refilled after L + L/24, ~4% overhead");
    }

    // ---------------------------------------------------------- isolation

    /// Two mandates from the same payer to the same spender share no window state.
    /// The ring is keyed by mandateId first, so the isolation is structural, and it
    /// is structure of the sort a refactor to save a mapping level would break.
    function test_windowsAreIsolatedPerMandate() public {
        bytes32 a = grant(windowOnlyParams(DAY, usd(100), uint8(K)));
        bytes32 b = grant(windowOnlyParams(DAY, usd(100), uint8(K)));
        alignToBucket();

        pay(a, usd(100));
        assertEq(mm.windowRemaining(a, 0), 0);
        assertEq(mm.windowRemaining(b, 0), usd(100), "the second mandate is untouched");
        pay(b, usd(100));
        assertEq(token.balanceOf(vendor), usd(200));
    }

    /// A window index that was never configured reports no headroom rather than
    /// reading uninitialised storage as an infinite allowance.
    function test_windowRemaining_onUnconfiguredIndex_isZero() public {
        bytes32 id = grant(windowOnlyParams(DAY, usd(100), uint8(K)));
        assertEq(mm.windowRemaining(id, 1), 0);
        assertEq(mm.windowRemaining(id, 3), 0);
    }

    // ---------------------------------------------------------------------------------
    // The accepted extremes of the geometry.
    //
    // Every window elsewhere in this file runs at K == 12 or K == 24, and the fuzzer
    // draws K from {2, 3, 4, 6, 12, 24}. createMandate accepts three shapes outside that
    // range — one bucket, thirty-two buckets, and a sub-period of one second — and until
    // this section no spend had ever run through any of them. The last two tests here
    // cover MAX_WINDOWS, which had been built once and never spent against.
    // ---------------------------------------------------------------------------------

    /**
     * One bucket is a ring of two slots, and it charges twice the nominal window.
     *
     * A window needs a non-zero length, a non-zero cap, a bucket count from 1 to
     * MAX_BUCKETS, and a length its bucket count divides evenly. One bucket satisfies all
     * four. The counted span is (K+1) sub-periods, which at K == 1 is two full windows, so a
     * payer who writes "1200 per day, one bucket" has asked for 1200 per two days. That is
     * the K/(K+1) conservatism at its widest: sustained throughput is half of nominal here,
     * against 92% at the K == 12 used by the rest of this file.
     */
    function test_bucketsOfOne_chargesTwoWindowsBeforeReleasing() public {
        bytes32 id = grant(windowOnlyParams(DAY, CAP, 1));
        MandateManager.WindowSpec memory w = mm.getWindow(id, 0);
        assertEq(uint256(w.buckets), 1, "one bucket, so the ring is two slots wide");
        assertEq(uint256(w.subLength), DAY, "and the sub-period is the whole window");

        uint64 t0 = uint64(((block.timestamp / DAY) + 1) * DAY);
        vm.warp(t0);
        pay(id, CAP);
        assertEq(mm.windowRemaining(id, 0), 0, "the cap is consumed");

        // A nominal window later the bucket index has advanced by one, and `oldest` is that
        // same index, so the spend still counts at full weight.
        vm.warp(t0 + DAY);
        assertEq(mm.windowRemaining(id, 0), 0, "one window on, none of it has come back");
        payReverts(id, 1, overWindowCap(DAY, CAP, CAP));

        vm.warp(t0 + 2 * DAY - 1);
        assertEq(mm.windowRemaining(id, 0), 0, "still none of it a second before 2L");

        vm.warp(t0 + 2 * DAY);
        assertEq(mm.windowRemaining(id, 0), CAP, "the whole cap returns at 2L");

        // Bucket b+2 shares a ring slot with bucket b, whose index has aged out, so this
        // spend takes the recycle branch. The refusal that follows reports `used` as one cap
        // rather than two, which is how recycling is told apart from accumulating.
        pay(id, CAP);
        payReverts(id, 1, overWindowCap(DAY, CAP, CAP));
        assertEq(token.balanceOf(vendor), uint256(CAP) * 2);
    }

    /**
     * MAX_BUCKETS is 32, and the ring it builds holds 33 live buckets at once.
     *
     * `Creation.t.sol` already covers the refusal above 32; acceptance at exactly 32 had no
     * test, and no spend in the suite had ever run against a ring wider than 25 slots. The
     * extra slot is the property here. A cap of 33 units is filled by 33 spends of one unit
     * at 33 consecutive sub-periods, because all 33 count at full weight. A 32-slot ring
     * would have overwritten the first of them when the thirty-third was written, and the
     * thirty-third spend would then have been admitted with room to spare.
     */
    function test_bucketsAtTheMaximum_keepsThirtyThreeBucketsLiveAtOnce() public {
        uint8 buckets = 32;
        uint32 sub = DAY / buckets; // 2700 seconds, and 86400 % 32 == 0, so the length divides evenly
        uint96 cap = usd(3300); // 33 buckets x 100

        bytes32 id = grant(windowOnlyParams(DAY, cap, buckets));
        assertEq(uint256(mm.getWindow(id, 0).subLength), sub, "MAX_BUCKETS is accepted as written");

        uint64 t0 = uint64(((block.timestamp / sub) + 1) * sub);
        for (uint64 i = 0; i <= buckets; ++i) {
            vm.warp(t0 + i * sub);
            pay(id, usd(100));
        }
        assertEq(mm.windowRemaining(id, 0), 0, "33 live buckets exactly fill a 33-unit cap");
        payReverts(id, 1, overWindowCap(DAY, cap, cap));

        // One sub-period on, the oldest of the 33 drops out and one bucket's worth returns.
        // Release is one bucket at a time at every K, and K == 32 is the finest release this
        // contract can be configured to give.
        vm.warp(t0 + 33 * sub);
        assertEq(mm.windowRemaining(id, 0), usd(100), "exactly one bucket released");
    }

    /**
     * A sub-period of one second, which needs lengthSeconds == buckets.
     *
     * The smallest window createMandate will build is one second with one bucket. At one
     * second per bucket the bucket index equals the raw timestamp, the largest value the ring
     * arithmetic is ever handed, and the reason `_checkAndCommitWindows` carries a written
     * justification for its uint64 cast. A one-second window releases after two seconds, for
     * the same reason the day-long window above releases after two days.
     */
    function test_subLengthOfOneSecond_releasesAfterTwoSeconds() public {
        bytes32 id = grant(windowOnlyParams(1, usd(100), 1));
        assertEq(uint256(mm.getWindow(id, 0).subLength), 1, "one second per bucket");

        uint64 t0 = uint64(block.timestamp);
        pay(id, usd(100));
        assertEq(mm.windowRemaining(id, 0), 0);

        vm.warp(t0 + 1);
        assertEq(mm.windowRemaining(id, 0), 0, "a second later the spend still counts");
        payReverts(id, 1, overWindowCap(1, usd(100), usd(100)));

        vm.warp(t0 + 2);
        assertEq(mm.windowRemaining(id, 0), usd(100), "released at two seconds");
        pay(id, usd(100));
        assertEq(token.balanceOf(vendor), uint256(usd(100)) * 2);
    }

    /**
     * The same one-second geometry at the last second a mandate can spend in.
     *
     * `FAR` is uint40 max and the expiry comparison is exclusive, so FAR - 1 is the last
     * live second. With a one-second sub-period the bucket index equals the timestamp, so
     * this is the largest index the ring can be given by any mandate the suite can build,
     * and it occupies 40 of the field's 64 bits. The closing refusal shows the expiry
     * arriving a second later, which is what bounds the index in the first place.
     */
    function test_subLengthOfOneSecond_atTheLastSpendableSecond_stillBuckets() public {
        bytes32 id = grant(windowOnlyParams(1, usd(100), 1));

        uint64 t0 = uint64(FAR) - 3;
        vm.warp(t0);
        pay(id, usd(100));
        assertEq(mm.windowRemaining(id, 0), 0, "an index of 2^40 - 4 behaves like any other");

        vm.warp(t0 + 1);
        payReverts(id, 1, overWindowCap(1, usd(100), usd(100)));

        vm.warp(t0 + 2); // FAR - 1
        assertEq(mm.windowRemaining(id, 0), usd(100), "and it ages out on schedule");
        pay(id, usd(100));

        vm.warp(t0 + 3); // FAR, which the exclusive comparison refuses
        payReverts(id, 1, MandateManager.Expired.selector);
    }

    /**
     * The most expensive spend this contract can be asked to perform.
     *
     * MAX_WINDOWS is 4 and MAX_BUCKETS is 32, so one spend reads at most 4 * (32 + 1) = 132
     * ring slots. Bounding that number is why those two constants exist.
     * `Creation.t.sol` builds a four-window mandate, asserts windowCount == 4 and stops, so
     * the worst case the limits are there to keep survivable had never executed.
     *
     * The four windows are identical because that is the only way all 132 slots hold an
     * amount at one instant: a slot stays live for (K+1) sub-periods, so windows of different
     * sub-lengths fill and empty on different schedules. A payer would write four different
     * lengths, and the test below does; this one is the cost ceiling rather than a shape
     * anyone would grant.
     *
     * The 33 spends fill every slot in every window. The spend after them reads all 132,
     * counts 128, and recycles the 4 that have aged out. Its gas belongs to the gas report
     * rather than to an assertion here, for two reasons: --gas-report perturbs `gasleft()` in
     * this suite, and all calls in one test function share a transaction, so the slots are
     * warm after the first spend and a figure taken here would understate a real one. Point
     * `forge test --isolate --gas-report` at this test for the cold number.
     */
    function test_fourWindowsAtMaxBuckets_theMaximumCostSpend_succeeds() public {
        uint96 cap = usd(3300); // 33 buckets x 100, in each of the four windows
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](4);
        for (uint256 i = 0; i < 4; ++i) {
            p.windows[i] = MandateManager.WindowParams({lengthSeconds: DAY, cap: cap, buckets: 32});
        }
        p = withExpiry(p); // v2: four windows are still no lifetime bound
        bytes32 id = grant(p);
        assertEq(uint256(mm.getMandate(id).windowCount), 4, "MAX_WINDOWS, each at MAX_BUCKETS");

        uint32 sub = DAY / 32;
        uint64 t0 = uint64(((block.timestamp / sub) + 1) * sub);
        for (uint64 i = 0; i <= 32; ++i) {
            vm.warp(t0 + i * sub);
            pay(id, usd(100));
        }
        for (uint256 wi = 0; wi < 4; ++wi) {
            assertEq(mm.windowRemaining(id, wi), 0, "all four windows are exactly full");
        }

        // 132 slots read, 128 counted, 4 recycled.
        vm.warp(t0 + 33 * sub);
        pay(id, usd(100));
        assertEq(mm.getMandate(id).totalSpent, usd(3400), "34 spends of 100 landed");

        // The windows are identical, so the first one binds and names itself.
        payReverts(id, 1, overWindowCap(DAY, cap, cap));
    }

    /**
     * Four windows of four different lengths, with the fourth one refusing.
     *
     * `_checkAndCommitWindows` walks the windows in order and writes each one before reading
     * the next, so a refusal raised by the fourth arrives with three windows already debited
     * in storage. Correctness rests on the whole transaction reverting, and at MAX_WINDOWS
     * there are three commits to unwind against the one the two-window test above unwinds.
     * The four lengths are the ones `Creation.t.sol` grants, with the caps rearranged to put
     * the tightest window last.
     */
    function test_fourWindows_refusalByTheLast_unwindsTheFirstThree() public {
        MandateManager.MandateParams memory p = emptyParams();
        p.windows = new MandateManager.WindowParams[](4);
        p.windows[0] = MandateManager.WindowParams({lengthSeconds: 3600, cap: usd(500), buckets: 6});
        p.windows[1] = MandateManager.WindowParams({lengthSeconds: DAY, cap: usd(1000), buckets: 12});
        p.windows[2] = MandateManager.WindowParams({lengthSeconds: WEEK, cap: usd(2000), buckets: 7});
        p.windows[3] = MandateManager.WindowParams({lengthSeconds: 30 days, cap: usd(300), buckets: 30});
        p = withExpiry(p);
        bytes32 id = grant(p);

        // The four sub-periods are 600, 7200, 86400 and 86400 seconds, and 86400 is a
        // multiple of each, so one warp puts all four windows on a bucket boundary together.
        vm.warp(((block.timestamp / DAY) + 1) * DAY);

        payReverts(id, usd(400), overWindowCap(30 days, usd(300), 0));
        assertEq(mm.windowRemaining(id, 0), usd(500), "window 0 kept nothing");
        assertEq(mm.windowRemaining(id, 1), usd(1000), "window 1 kept nothing");
        assertEq(mm.windowRemaining(id, 2), usd(2000), "window 2 kept nothing");
        assertEq(mm.windowRemaining(id, 3), usd(300), "and the window that refused is clean too");
        assertEq(mm.getMandate(id).totalSpent, 0);
        assertEq(token.balanceOf(vendor), 0);

        // The reads above report the three windows intact. This spend proves they are intact
        // in storage as well, by drawing the full headroom each one should still have.
        pay(id, usd(300));
        assertEq(mm.windowRemaining(id, 0), usd(200));
        assertEq(mm.windowRemaining(id, 1), usd(700));
        assertEq(mm.windowRemaining(id, 2), usd(1700));
        assertEq(mm.windowRemaining(id, 3), 0, "and the tightest window is now exactly full");
        payReverts(id, 1, overWindowCap(30 days, usd(300), usd(300)));
    }
}
