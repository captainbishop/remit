// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │  NOT AUDITED. LIVE ON ARC TESTNET SINCE 2026-08-24. REAL MONEY IS OUT OF  │
 * │  SCOPE UNTIL AN AUDIT SAYS OTHERWISE.                                     │
 * │                                                                           │
 * │  Deployed at 0x3744E93B9e796E05CB66311d897559B6F3860196 on Arc Testnet    │
 * │  (chain 5042002), source verified. It compiles under solc 0.8.28 and      │
 * │  passes the full Forge suite: 139 tests in test/, including 2,048 fuzz    │
 * │  runs and 49,152 stateful-invariant calls. The policy logic is            │
 * │  independently modelled by reference/policy.js, whose 46 tests found six  │
 * │  real cap-bypass bugs during development. One mandate has been granted    │
 * │  and one spend executed live; both Transfer logs on that spend carry the  │
 * │  payer as sender, never this contract, so non-custody is now observable   │
 * │  rather than argued.                                                      │
 * │                                                                           │
 * │  What that does NOT establish: testnet exercised exactly ONE mandate      │
 * │  shape — no cosigner, no identity gate, no credential gate, one window,   │
 * │  one allowlist entry. Cosignature, both ERC-8004 gates and revoke have    │
 * │  139 passing tests and zero live transactions. Sub-second blocks sharing  │
 * │  a timestamp and the CallFrom precompile are still asserted from          │
 * │  documentation, not observed. Gas IS now measured against real Arc USDC:  │
 * │  a policed spend cost 216,458 gas, ~0.0045 USDC at the 21 Gwei charged,   │
 * │  of which ~142,500 is the policy machinery and ~32,700 is Arc's own       │
 * │  native-USDC accounting. No third party has reviewed this. A green suite  │
 * │  says the implementation matches the model; it does not say the model is  │
 * │  right about the world. This is INTENDED to hold real money, so the audit │
 * │  is a requirement, not advice.                                            │
 * └───────────────────────────────────────────────────────────────────────────┘
 *
 * REMIT — bounded, revocable, non-custodial spending authority.
 *
 * Remit is the protocol; a "mandate" is the object it issues. The contract keeps the
 * descriptive name because what it manages is mandates. The brand appears in exactly
 * one consensus-relevant place: the DOMAIN separator below, which is mixed into every
 * mandateId. Change that string and every id changes, so it is fixed before deploy.
 *
 * THE PROBLEM
 * Software agents are being handed money. The tools available to bound them are
 * all unsatisfying:
 *   - An ERC-20 allowance is not a spending cap. Arc's own docs say so. It is a
 *     single scalar with no rate limit, no expiry, no recipient restriction, and
 *     no record of intent.
 *   - Per-job escrow (ERC-8183) requires the payer to sign for every single job.
 *     There is no standing authority, so there is no delegation.
 *   - Off-chain limits inside a custodial vendor's API cannot be independently
 *     verified by either party, and cannot be proven to a third party later.
 *
 * What is missing is non-repudiation in both directions: the payer needs to prove
 * what was authorized, and the agent needs to prove it acted within authority.
 *
 * WHAT THIS IS
 * A payer grants a spender (an AI agent, a payroll bot, a subscription service) a
 * mandate: capped per transaction, rate-limited over rolling windows, capped in
 * total, restricted to an allowlist, time-boxed, optionally gated on an ERC-8004
 * identity and a validator attestation, and optionally requiring a co-signature
 * above a threshold. Every spend carries an idempotency nonce and emits a
 * reconcilable event. The payer can revoke unilaterally and instantly.
 *
 * NON-CUSTODIAL: funds never move into this contract. The payer keeps their USDC
 * and grants this contract an ERC-20 allowance; a spend is a `transferFrom` from
 * payer straight to recipient. The allowance is the outer hard ceiling and the
 * mandate is the fine-grained policy inside it. Approving exactly the intended
 * budget rather than `type(uint256).max` gives defense in depth: a bug in this
 * contract cannot cost more than the allowance.
 *
 * SCOPE — READ THIS BEFORE TRUSTING A MANDATE AS AN ENFORCEMENT BOUNDARY.
 * A mandate binds exactly one path: `transferFrom` from the payer, executed here.
 * On Arc USDC is the native asset, so the payer's balance can also leave as native
 * value, and no allowance or mandate is consulted on that path. Arc's docs are
 * explicit: "An ERC-20 allowance is not a cap on total USDC spending: the same
 * balance can also leave as native value (msg.value)... For smart contract accounts
 * (embedded wallets, smart wallets, and session-key systems), do not rely on
 * allowance state as a safety guarantee. Any module with execution rights can also
 * transfer native USDC regardless of allowance state."
 *
 * Therefore this is a real cap ONLY when this contract is the spender's sole path to
 * the payer's funds — payer is an EOA, agent holds no key to it. If the payer is a
 * smart account and the agent is a module or session key with execution rights on
 * it, the module can send native USDC directly and never touch this contract; the
 * mandate then documents intent and produces an audit trail but enforces nothing.
 * Bounding a smart-account module requires the limit to live in the account's own
 * execution logic. Do not sell this contract as a substitute for that.
 *
 * WHY ARC SPECIFICALLY
 *   - Gas and spend are the same asset, so a USDC-denominated budget is fully
 *     expressible. On a chain where gas is a second asset, a spending policy has
 *     a hole in it the size of the gas account.
 *   - Deterministic finality at one confirmation means revocation is effective
 *     immediately. Arc's docs put one Arc confirmation at the settlement
 *     guarantee of 64+ Ethereum blocks (~13 min), with reorgs impossible. On
 *     Ethereum a revocation has a multi-minute window where it is not yet
 *     economically final — a real gap when the counterparty is an automated
 *     agent reacting in milliseconds.
 *   - The Memo contract routes calls through the CallFrom precompile, preserving
 *     the calling EOA as msg.sender. So an agent can call
 *     Memo.memo(target=MandateManager, data=spend(...), memoId, memoData) and
 *     this contract still sees the agent's EOA in msg.sender, while the memo
 *     event carries the business reference. Authority, money movement, and
 *     business context land in one atomic transaction.
 *   - ERC-8004 gives an on-chain identity and attestation registry to gate on.
 *
 * KNOWN LIMITATION — 4337 SMART ACCOUNTS CANNOT USE THE MEMO PATH.
 * Arc documents that Memo must be called directly by an EOA; smart contract
 * wallets revert because sender spoofing is not allowed. So an agent that is an
 * ERC-4337 smart account can call spend() directly (fine — it just becomes the
 * spender) but cannot wrap it in a memo. That is an architectural fork, not a
 * detail: EOA agents get the richer audit trail. This is why spend() emits its
 * own Spend event carrying the reference, so the core audit trail never depends
 * on the memo wrapper being available.
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// ERC-8004 IdentityRegistry. Agent identities are ERC-721 tokens, so `ownerOf`
/// REVERTS for a nonexistent or burned id rather than returning address(0).
interface IIdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// ERC-8004 ValidationRegistry. Note the lookup key: `requestHash` ALONE. The
/// validator and the agent the attestation is about come back in the tuple and
/// must be checked, or the gate is decorative. See _checkCredential.
interface IValidationRegistry {
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );
}

contract MandateManager {
    // ---------------------------------------------------------------------
    // Immutable wiring. Arc Testnet addresses are in the deploy script; they
    // are constructor arguments rather than constants so this can be tested
    // against mocks and deployed to mainnet without an edit.
    // ---------------------------------------------------------------------

    IERC20 public immutable usdc;
    IIdentityRegistry public immutable identityRegistry;
    IValidationRegistry public immutable validationRegistry;

    /// Domain tag. Included in every spend hash along with chainid and this
    /// address, so a co-signature can never be replayed on another chain or
    /// against another deployment of this contract.
    bytes32 public constant DOMAIN = keccak256("Remit:v1");

    /// Each spend reads every ring slot of every window, so these caps are what
    /// keep the gas cost of a spend bounded rather than a function of untrusted
    /// grant-time input. Mirrored in reference/policy.js so the two cannot drift.
    uint256 public constant MAX_WINDOWS = 4;
    uint256 public constant MAX_BUCKETS = 32;

    // Feature flags. Explicit rather than inferred from zero values, because
    // some zeros are meaningful: a cosignThreshold of 0 means "every spend needs
    // a co-signature", which is very different from "no co-signature required".
    //
    // Note on the unparenthesized `flags & F_X != 0` used throughout: Solidity's
    // precedence table places bitwise `&` ABOVE the comparison operators, unlike
    // C, so this parses as `(flags & F_X) != 0` — which is what is meant. It reads
    // like a bug and is not one. Parenthesize anyway if a reviewer objects.
    uint8 public constant F_PER_TX = 1 << 0;
    uint8 public constant F_TOTAL = 1 << 1;
    uint8 public constant F_COSIGN = 1 << 2;
    uint8 public constant F_EXPIRY = 1 << 3;
    uint8 public constant F_IDENTITY = 1 << 4;
    uint8 public constant F_CREDENTIAL = 1 << 5;
    uint8 public constant F_ALLOWLIST = 1 << 6;

    // ---------------------------------------------------------------------
    // Storage. Field order is chosen for slot packing; do not reorder casually.
    // uint96 holds ~7.9e28 base units = ~7.9e22 USDC at 6 decimals.
    // uint40 timestamps are good past the year 36000.
    // ---------------------------------------------------------------------

    struct Mandate {
        address payer; //            slot 0: 20 + 12 = 32
        uint96 perTxCap;
        address spender; //          slot 1: 20 + 12 = 32
        uint96 totalCap;
        address cosigner; //         slot 2: 20 + 12 = 32
        uint96 cosignThreshold;
        uint96 totalSpent; //        slot 3: 12 + 5 + 5 + 4 + 1 + 1 + 1 = 29
        uint40 notBefore;
        uint40 expiresAt;
        uint32 spendCount;
        uint8 flags;
        uint8 windowCount;
        bool revoked;
    }

    struct WindowSpec {
        uint32 lengthSeconds; //     slot: 4 + 4 + 12 + 1 = 21
        uint32 subLength;
        uint96 cap;
        uint8 buckets;
    }

    /// One sub-period counter. 8 + 12 = 20 bytes, so one storage slot and one
    /// SLOAD per bucket. An untouched slot is amount == 0; there is deliberately
    /// no sentinel bucketIndex, because every uint256 value is a legitimate
    /// bucket index. (The JS model originally used -1 here and it collided with
    /// a real `oldest` value near timestamp zero. Same class of bug, avoided.)
    struct RingSlot {
        uint64 bucketIndex;
        uint96 amount;
    }

    struct IdentityGate {
        uint256 agentId;
        address expectedOwner; // address(0) = do not pin, only require ownerOf == spender
    }

    struct CredentialGate {
        bytes32 requestHash;
        uint256 agentId; // 0 = fall back to the identity gate's agentId
        address validator;
        uint40 maxStaleness; // 0 = no freshness requirement
        uint8 minResponse; // ERC-8004: 100 == passed
    }

    mapping(bytes32 => Mandate) private _mandates;
    mapping(bytes32 => mapping(uint256 => WindowSpec)) private _windows;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => RingSlot))) private _ring;
    mapping(bytes32 => IdentityGate) private _identity;
    mapping(bytes32 => CredentialGate) private _credential;
    mapping(bytes32 => mapping(address => bool)) private _allowlist;
    mapping(bytes32 => mapping(bytes32 => bool)) private _usedNonce;
    mapping(bytes32 => mapping(bytes32 => bool)) private _cosignApproved;

    // ---------------------------------------------------------------------
    // Events. The audit trail lives here and does not depend on the Memo
    // wrapper being usable, because 4337 accounts cannot use it.
    // ---------------------------------------------------------------------

    event MandateCreated(
        bytes32 indexed mandateId,
        address indexed payer,
        address indexed spender,
        uint96 perTxCap,
        uint96 totalCap,
        uint40 notBefore,
        uint40 expiresAt,
        uint8 flags,
        uint8 windowCount
    );

    event Spend(
        bytes32 indexed mandateId,
        address indexed spender,
        address indexed recipient,
        uint256 amount,
        bytes32 ref,
        bytes32 nonce,
        bytes32 spendHash,
        uint96 totalSpent
    );

    event MandateRevoked(bytes32 indexed mandateId, address indexed by);
    event CosignApproved(bytes32 indexed mandateId, bytes32 indexed spendHash, address indexed cosigner);
    event CosignWithdrawn(bytes32 indexed mandateId, bytes32 indexed spendHash, address indexed cosigner);

    // ---------------------------------------------------------------------
    // Errors. One-to-one with the Denial reasons in reference/policy.js.
    // When called through Memo, Arc wraps a child revert in MemoFailed(bytes),
    // so clients must unwrap one layer before decoding these.
    // ---------------------------------------------------------------------

    error UnknownMandate();
    error MandateExists();
    error Revoked();
    error NotYetValid();
    error Expired();
    error WrongSpender();
    error RecipientNotAllowed();
    error ZeroAmount();
    error ZeroRecipient();
    error OverPerTxCap();
    error OverWindowCap(uint32 lengthSeconds, uint96 cap, uint256 used);
    error OverTotalCap();
    error NonceAlreadyUsed();
    error CosignRequired(bytes32 spendHash);
    error IdentityNotHeld();
    error IdentityTransferred();
    error CredentialMissing();
    error CredentialStale();
    error CredentialWrongValidator();
    error CredentialWrongAgent();
    error TransferFailed();
    error Unbounded();
    error BadWindow();
    error BadConfig();
    error NotPayer();
    error NotCosigner();
    error AmountTooLarge();

    constructor(address _usdc, address _identityRegistry, address _validationRegistry) {
        if (_usdc == address(0)) revert BadConfig();
        usdc = IERC20(_usdc);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        validationRegistry = IValidationRegistry(_validationRegistry);
    }

    // =====================================================================
    // Grant
    // =====================================================================

    struct WindowParams {
        uint32 lengthSeconds;
        uint96 cap;
        uint8 buckets;
    }

    struct MandateParams {
        address spender;
        uint96 perTxCap;
        uint96 totalCap;
        address cosigner;
        uint96 cosignThreshold;
        uint40 notBefore;
        uint40 expiresAt;
        uint8 flags;
        WindowParams[] windows;
        address[] allowlist;
        IdentityGate identity;
        CredentialGate credential;
    }

    /// @notice Grant a mandate. The id is derived from (this, chainid, payer,
    /// salt) so the payer can compute it off-chain before the transaction lands
    /// and two payers can never collide.
    function createMandate(bytes32 salt, MandateParams calldata p) external returns (bytes32 mandateId) {
        mandateId = keccak256(abi.encode(DOMAIN, block.chainid, address(this), msg.sender, salt));
        if (_mandates[mandateId].payer != address(0)) revert MandateExists();
        if (p.spender == address(0)) revert BadConfig();

        uint8 flags = p.flags;

        // Refusing to mint an unbounded authority is the entire point of the
        // primitive, so it is enforced rather than documented.
        bool hasBound = (flags & F_PER_TX != 0) || (flags & F_TOTAL != 0) || (flags & F_EXPIRY != 0)
            || p.windows.length > 0;
        if (!hasBound) revert Unbounded();

        // Every flag must agree with the value it describes, so a malformed
        // grant is rejected at creation instead of behaving surprisingly later.
        if ((flags & F_PER_TX != 0) != (p.perTxCap > 0)) revert BadConfig();
        if ((flags & F_TOTAL != 0) != (p.totalCap > 0)) revert BadConfig();
        if ((flags & F_COSIGN != 0) != (p.cosigner != address(0))) revert BadConfig();
        if ((flags & F_CREDENTIAL != 0) != (p.credential.validator != address(0))) revert BadConfig();
        if ((flags & F_ALLOWLIST != 0) != (p.allowlist.length > 0)) revert BadConfig();
        if (flags & F_EXPIRY != 0 && p.expiresAt <= p.notBefore) revert BadConfig();
        if (flags & F_CREDENTIAL != 0 && address(validationRegistry) == address(0)) revert BadConfig();
        if (flags & F_IDENTITY != 0 && address(identityRegistry) == address(0)) revert BadConfig();

        if (p.windows.length > MAX_WINDOWS) revert BadWindow();

        _mandates[mandateId] = Mandate({
            payer: msg.sender,
            perTxCap: p.perTxCap,
            spender: p.spender,
            totalCap: p.totalCap,
            cosigner: p.cosigner,
            cosignThreshold: p.cosignThreshold,
            totalSpent: 0,
            notBefore: p.notBefore,
            expiresAt: p.expiresAt,
            spendCount: 0,
            flags: flags,
            windowCount: uint8(p.windows.length),
            revoked: false
        });

        for (uint256 i = 0; i < p.windows.length; ++i) {
            WindowParams calldata w = p.windows[i];
            // Sub-periods must be uniform, so the length has to divide evenly.
            if (w.lengthSeconds == 0 || w.cap == 0) revert BadWindow();
            if (w.buckets == 0 || w.buckets > MAX_BUCKETS) revert BadWindow();
            if (w.lengthSeconds % w.buckets != 0) revert BadWindow();
            _windows[mandateId][i] = WindowSpec({
                lengthSeconds: w.lengthSeconds,
                subLength: w.lengthSeconds / w.buckets,
                cap: w.cap,
                buckets: w.buckets
            });
        }

        for (uint256 i = 0; i < p.allowlist.length; ++i) {
            if (p.allowlist[i] == address(0)) revert BadConfig();
            _allowlist[mandateId][p.allowlist[i]] = true;
        }

        if (flags & F_IDENTITY != 0) _identity[mandateId] = p.identity;
        if (flags & F_CREDENTIAL != 0) {
            if (p.credential.minResponse == 0) revert BadConfig(); // 0 would accept a failed attestation
            _credential[mandateId] = p.credential;
        }

        emit MandateCreated(
            mandateId, msg.sender, p.spender, p.perTxCap, p.totalCap, p.notBefore, p.expiresAt, flags, uint8(p.windows.length)
        );
    }

    // =====================================================================
    // Spend
    // =====================================================================

    /**
     * @notice Spend against a mandate. Callable directly by the spender, or via
     * Memo.memo(target=this, ...) which preserves the spender's EOA as
     * msg.sender through the CallFrom precompile.
     *
     * CHECK ORDER matters and mirrors reference/policy.js exactly. In particular
     * the co-signature requirement is checked LAST, so a request that fails a
     * cheaper check reports that instead of misleadingly demanding a signature.
     *
     * DEVIATION FROM THE REFERENCE MODEL, deliberately: the model separates a
     * pure `evaluate` from a mutating `commit` because JavaScript has no
     * rollback. Here the window check and the window write are fused into one
     * pass, which halves the storage reads. That is safe only because a revert
     * unwinds every prior write in the transaction — so a later check failing
     * cannot leave an earlier window incremented. Do not port this fusion back
     * into any context lacking transactional rollback.
     */
    function spend(bytes32 mandateId, address recipient, uint256 amount, bytes32 ref, bytes32 nonce)
        external
        returns (bytes32 hash)
    {
        Mandate storage m = _mandates[mandateId];

        if (m.payer == address(0)) revert UnknownMandate();
        if (m.revoked) revert Revoked();

        uint256 nowTs = block.timestamp;
        if (nowTs < m.notBefore) revert NotYetValid();
        // Expiry is EXCLUSIVE: a mandate expiring at T is dead AT T. Arc's
        // sub-second blocks can share a timestamp, so an inclusive bound would
        // leave an ambiguous final second where liveness depends on which block
        // within that second included the transaction.
        if (m.flags & F_EXPIRY != 0 && nowTs >= m.expiresAt) revert Expired();

        if (msg.sender != m.spender) revert WrongSpender();

        // Arc forbids value transfers to the zero address; reject up front
        // rather than burning the caller's gas on a guaranteed runtime revert.
        if (recipient == address(0)) revert ZeroRecipient();
        if (m.flags & F_ALLOWLIST != 0 && !_allowlist[mandateId][recipient]) revert RecipientNotAllowed();

        if (amount == 0) revert ZeroAmount();
        // Everything downstream stores amounts as uint96.
        if (amount > type(uint96).max) revert AmountTooLarge();

        // Idempotency. A retrying off-chain worker is safe: resubmitting a nonce
        // is refused rather than paying twice. This matters more on Arc than
        // elsewhere, because one-confirmation finality encourages aggressive
        // retry logic. Note a spend that reverts for any reason does NOT consume
        // its nonce — the write is rolled back — so retry after a transient
        // failure (insufficient allowance, blocklisted recipient) is correct.
        if (_usedNonce[mandateId][nonce]) revert NonceAlreadyUsed();

        if (m.flags & F_IDENTITY != 0) _checkIdentity(mandateId);
        if (m.flags & F_CREDENTIAL != 0) _checkCredential(mandateId, nowTs);

        if (m.flags & F_PER_TX != 0 && amount > m.perTxCap) revert OverPerTxCap();

        // The two `uint96(amount)` casts below cannot truncate. `amount` is bounded by
        // the `AmountTooLarge` guard above, which is unconditional and runs before any
        // policy check precisely so that this holds — see the comment there. If that
        // guard is ever moved behind a flag, both casts become unsound: a caller could
        // pass 2^96 and have it wrap to 0, spending nothing against the caps while the
        // transfer below moves the full amount.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 newTotal = m.totalSpent + uint96(amount);
        if (m.flags & F_TOTAL != 0 && newTotal > m.totalCap) revert OverTotalCap();

        // forge-lint: disable-next-line(unsafe-typecast)
        _checkAndCommitWindows(mandateId, m.windowCount, uint96(amount), nowTs);

        hash = spendHash(mandateId, msg.sender, recipient, amount, ref, nonce);
        if (m.flags & F_COSIGN != 0 && amount > m.cosignThreshold) {
            if (!_cosignApproved[mandateId][hash]) revert CosignRequired(hash);
            delete _cosignApproved[mandateId][hash]; // one signature authorises one spend
        }

        m.totalSpent = newTotal;
        m.spendCount += 1;
        _usedNonce[mandateId][nonce] = true;

        // Emitted before the transfer so an indexer reads the authorization
        // decision ahead of the money movement: BeforeMemo, Spend, Transfer, Memo.
        emit Spend(mandateId, msg.sender, recipient, amount, ref, nonce, hash, newTotal);

        // Checks-effects-interactions: all state is written above. No reentrancy
        // guard, because `usdc` is immutable and set to Circle's token — there is
        // no attacker-controlled callee. If this contract is ever generalised to
        // arbitrary tokens, add one.
        //
        // On Arc this can revert even with sufficient balance: the blocklist is
        // enforced at runtime and a transfer to or from a blocklisted address
        // reverts. That unwinds the whole spend atomically, which is the correct
        // outcome — no cap consumed, no nonce burned.
        if (!usdc.transferFrom(m.payer, recipient, amount)) revert TransferFailed();
    }

    // =====================================================================
    // Rolling windows
    // =====================================================================

    /**
     * Sum every sub-bucket that overlaps the trailing window, then record this
     * spend into the current sub-bucket.
     *
     * WHY K+1 BUCKETS AND NOT K
     * With b = now/S the current sub-bucket, summing [b-K+1, b] covers a span of
     * L seconds that ENDS at (b+1)*S — the end of the current bucket, which is in
     * the future relative to now. The span is therefore shifted forward by up to
     * S, and bucket b-K drops out of the ring while it is still genuinely inside
     * the trailing window (t-L, t], since its end (b-K+1)*S = b*S + S - L > t - L
     * for every t < (b+1)*S. A spend late in bucket b-K then stopped being
     * counted, and a second spend exactly K buckets later passed when it should
     * not have. That was a real cap bypass, found by the fuzz test in
     * reference/policy.test.js, not a rounding artifact.
     *
     * Summing [b-K, b] instead — K+1 buckets — fixes it. Any spend at time u in
     * (t-L, t] has bucket floor(u/S) <= b since u <= t, and >= b-K since
     * u > t-L >= b*S-L = (b-K)*S. So every spend in the true trailing window is
     * counted, and the cap can never be exceeded over any real window of L.
     *
     * THE COST: the counted span is (K+1)*S = L+S, so up to one extra sub-period
     * of history is charged. Sustained throughput settles at K/(K+1) of the
     * nominal cap — measured at ~92% for K=12 and ~96% for K=24. Raise buckets to
     * shrink the gap at the price of one more SLOAD per check, which as of
     * 2026-08-24 is a measured ~2,150 gas or ~0.000045 USDC at the 21 Gwei Arc
     * actually charged on the live spend. K=12 -> K=24 therefore costs about
     * 0.0005 USDC per spend to halve the under-count, so the strict setting is
     * cheap enough to be the default. The live spend also settles the question the
     * old version of this comment left open: at K=24 the whole transaction came in
     * at 216,458 gas, so the bucket ring is a legible fraction of a cost that is
     * still under half a cent. For a safety primitive, erring strict is the right
     * direction anyway: overspending is not recoverable, a retry is.
     */
    function _checkAndCommitWindows(bytes32 mandateId, uint8 windowCount, uint96 amount, uint256 nowTs) private {
        for (uint256 wi = 0; wi < windowCount; ++wi) {
            WindowSpec memory w = _windows[mandateId][wi];
            uint256 ringSize = uint256(w.buckets) + 1;

            // `nowTs` is block.timestamp and `w.subLength` is at least 1 (createMandate
            // rejects a zero sub-length), so this quotient is at most block.timestamp
            // itself. uint64 saturates at 1.8e19 seconds — about 584 billion years —
            // and the ring arithmetic below compares bucket indices of this same type,
            // so a wrap would break the window rather than merely narrow it. Safe for
            // any timestamp the chain can produce.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 bucket = uint64(nowTs / w.subLength);
            // Clamp instead of subtracting: 0.8 reverts on underflow, and the JS
            // model can go negative where this cannot. Clamping to 0 counts more
            // history, never less, so it stays on the conservative side.
            uint64 oldest = bucket > w.buckets ? bucket - uint64(w.buckets) : 0;

            uint256 used;
            for (uint256 s = 0; s < ringSize; ++s) {
                RingSlot storage slot = _ring[mandateId][wi][s];
                uint96 a = slot.amount;
                // No upper bound on bucketIndex on purpose. Arc timestamps are
                // non-decreasing so a slot newer than `bucket` should be
                // unreachable, but excluding one would make recorded spending
                // invisible and hand back headroom that was really consumed. The
                // cap must not depend on that promise holding.
                if (a != 0 && slot.bucketIndex >= oldest) used += a;
            }

            if (used + amount > w.cap) revert OverWindowCap(w.lengthSeconds, w.cap, used);

            RingSlot storage cur = _ring[mandateId][wi][uint256(bucket) % ringSize];
            if (cur.amount == 0) {
                // Empty slot: nothing to lose.
                cur.bucketIndex = bucket;
                cur.amount = amount;
            } else if (cur.bucketIndex == bucket) {
                cur.amount += amount;
            } else if (cur.bucketIndex < oldest) {
                // Aged out of the window: recycle.
                cur.bucketIndex = bucket;
                cur.amount = amount;
            } else {
                // Live collision. Unreachable while timestamps are
                // non-decreasing: the K+1 live indices each map to a distinct
                // ring slot, so a differing live index can only be NEWER than
                // `bucket`, which needs the clock to have gone backwards.
                // Accumulate rather than overwrite — overwriting would discard
                // already-counted spending, while keeping the newer index only
                // makes this amount expire later than strictly necessary.
                cur.amount += amount;
            }
            // No overflow: `used` includes cur.amount and used + amount <= cap,
            // and cap is uint96, so the slot total cannot exceed uint96.
        }
    }

    // =====================================================================
    // ERC-8004 gates
    // =====================================================================

    /**
     * ERC-8004 identities are TRANSFERABLE ERC-721s. Holding the token now is
     * necessary but not sufficient: if the payer pinned an expected owner at
     * grant time, that must still match, otherwise selling or transferring the
     * identity token would silently carry spending authority to a stranger.
     */
    function _checkIdentity(bytes32 mandateId) private view {
        IdentityGate memory g = _identity[mandateId];

        // ownerOf reverts for a nonexistent or burned tokenId rather than
        // returning address(0), so catch it and produce a legible denial.
        address owner;
        try identityRegistry.ownerOf(g.agentId) returns (address o) {
            owner = o;
        } catch {
            owner = address(0);
        }

        if (owner == address(0) || owner != msg.sender) revert IdentityNotHeld();
        if (g.expectedOwner != address(0) && owner != g.expectedOwner) revert IdentityTransferred();
    }

    /**
     * getValidationStatus is keyed ONLY by requestHash. Reading `response` alone
     * makes this gate theater: an attacker picks a requestHash and has some
     * cooperative validator answer it, or points at a real attestation that was
     * issued about a different agent. So the validator that answered and the
     * agent it answered about are both checked against what the payer named.
     */
    function _checkCredential(bytes32 mandateId, uint256 nowTs) private view {
        CredentialGate memory c = _credential[mandateId];

        address gotValidator;
        uint256 gotAgentId;
        uint8 response;
        uint256 lastUpdate;

        try validationRegistry.getValidationStatus(c.requestHash) returns (
            address v, uint256 aid, uint8 resp, bytes32, string memory, uint256 lu
        ) {
            gotValidator = v;
            gotAgentId = aid;
            response = resp;
            lastUpdate = lu;
        } catch {
            revert CredentialMissing();
        }

        if (gotValidator == address(0)) revert CredentialMissing();
        if (gotValidator != c.validator) revert CredentialWrongValidator();

        // The expected agent falls back to the identity gate's id when the credential
        // does not name one. If BOTH are zero the comparison is skipped entirely, and
        // the gate degrades to "the named validator filed a passing, fresh attestation
        // under this exact requestHash" with nothing tying it to this spender. That is
        // reachable by omission, since zero is a struct field's default, so it is a
        // documented gap rather than an accident: see DESIGN.md and
        // test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent. It stays
        // permitted because an attestation about a request rather than about an agent
        // is a legitimate shape, and requestHash is payer-fixed at grant time so the
        // spender cannot redirect the lookup.
        uint256 expectedAgent = c.agentId != 0 ? c.agentId : _identity[mandateId].agentId;
        if (expectedAgent != 0 && gotAgentId != expectedAgent) revert CredentialWrongAgent();

        if (response < c.minResponse) revert CredentialMissing();
        if (c.maxStaleness != 0 && nowTs > lastUpdate && nowTs - lastUpdate > c.maxStaleness) {
            revert CredentialStale();
        }
    }

    // =====================================================================
    // Revocation and co-signing
    // =====================================================================

    /**
     * @notice Kill a mandate. Immediate and permanent.
     *
     * On Arc this is stronger than on a probabilistic-finality chain: one
     * confirmation is final and reorgs are impossible, so there is no window in
     * which a revoked mandate is still live and spendable. On Ethereum the same
     * revocation is not economically final for minutes.
     *
     * The spender may also revoke. Giving up your own authority can never harm
     * the payer, and it lets a compromised agent shut itself off.
     */
    function revoke(bytes32 mandateId) external {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) revert UnknownMandate();
        if (msg.sender != m.payer && msg.sender != m.spender) revert NotPayer();
        m.revoked = true;
        emit MandateRevoked(mandateId, msg.sender);
    }

    /**
     * @notice Pre-approve exactly one spend above the co-sign threshold.
     *
     * The hash binds mandate, spender, recipient, amount, reference and nonce,
     * so an approval cannot be redirected to a different recipient or inflated
     * to a different amount. It also binds chainid and this contract's address,
     * so it cannot be replayed against another deployment.
     *
     * This requires the co-signer to send a transaction. An EIP-712 signature
     * variant would be better UX — the approver signs off-chain and the agent
     * submits it — and it is a deliberate omission rather than an oversight. It
     * was originally left out because this file was written with no compiler
     * available and unverifiable signature-recovery code is the worst possible
     * thing to ship on trust. That reason has expired; the remaining one is
     * scope. If it is added, it needs its own malleability, replay and
     * chain-binding tests, not a green suite inherited from this path.
     */
    function approveCosign(bytes32 mandateId, bytes32 hash) external {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) revert UnknownMandate();
        if (m.flags & F_COSIGN == 0) revert BadConfig();
        if (msg.sender != m.cosigner) revert NotCosigner();
        _cosignApproved[mandateId][hash] = true;
        emit CosignApproved(mandateId, hash, msg.sender);
    }

    /// @notice Withdraw an approval that has not been used yet.
    function withdrawCosign(bytes32 mandateId, bytes32 hash) external {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.cosigner) revert NotCosigner();
        delete _cosignApproved[mandateId][hash];
        emit CosignWithdrawn(mandateId, hash, msg.sender);
    }

    // =====================================================================
    // Views — pre-flight checks so an agent does not waste gas on a doomed call
    // =====================================================================

    function spendHash(
        bytes32 mandateId,
        address spender_,
        address recipient,
        uint256 amount,
        bytes32 ref,
        bytes32 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN, block.chainid, address(this), mandateId, spender_, recipient, amount, ref, nonce)
        );
    }

    function getMandate(bytes32 mandateId) external view returns (Mandate memory) {
        return _mandates[mandateId];
    }

    function getWindow(bytes32 mandateId, uint256 index) external view returns (WindowSpec memory) {
        return _windows[mandateId][index];
    }

    function isNonceUsed(bytes32 mandateId, bytes32 nonce) external view returns (bool) {
        return _usedNonce[mandateId][nonce];
    }

    function isCosignApproved(bytes32 mandateId, bytes32 hash) external view returns (bool) {
        return _cosignApproved[mandateId][hash];
    }

    function isAllowedRecipient(bytes32 mandateId, address recipient) external view returns (bool) {
        Mandate storage m = _mandates[mandateId];
        if (m.flags & F_ALLOWLIST == 0) return recipient != address(0);
        return _allowlist[mandateId][recipient];
    }

    function isLive(bytes32 mandateId) public view returns (bool) {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0) || m.revoked) return false;
        // Both timestamp reads below are deliberate, and the lint's usual objection —
        // that a proposer can nudge block.timestamp — is answered structurally rather
        // than by avoiding the opcode. There is no other clock available on-chain, and
        // "expires at a wall-clock time" is the semantics a payer actually wants.
        //
        // What matters is that nothing here *grants* capacity from a timestamp. Window
        // accounting deliberately has no upper bound on bucket index (see
        // _checkAndCommitWindows) so a timestamp moved forward cannot age out live
        // history and refill a cap — that was a real bug the reference model caught, and
        // it is now a named regression test. A timestamp moved backwards can only make
        // this function return false, which refuses spends. So the worst a nudged clock
        // can do to a live mandate is shift the expiry boundary by the manipulation
        // margin, in either direction, and the payer's real remedy — revoke — is
        // immediate and does not consult the clock at all.
        //
        // Arc-specific: timestamps are documented as non-decreasing but NOT strictly
        // increasing, because sub-second blocks share one. Nothing here assumes
        // strictness; equality is handled by the >= on expiresAt.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < m.notBefore) return false;
        // forge-lint: disable-next-line(block-timestamp)
        if (m.flags & F_EXPIRY != 0 && block.timestamp >= m.expiresAt) return false;
        return true;
    }

    /// @notice Remaining headroom in one rolling window right now.
    function windowRemaining(bytes32 mandateId, uint256 wi) public view returns (uint256) {
        WindowSpec memory w = _windows[mandateId][wi];
        if (w.subLength == 0) return 0;
        uint256 ringSize = uint256(w.buckets) + 1;
        uint64 bucket = uint64(block.timestamp / w.subLength);
        uint64 oldest = bucket > w.buckets ? bucket - uint64(w.buckets) : 0;

        uint256 used;
        for (uint256 s = 0; s < ringSize; ++s) {
            RingSlot storage slot = _ring[mandateId][wi][s];
            uint96 a = slot.amount;
            if (a != 0 && slot.bucketIndex >= oldest) used += a;
        }
        return used >= w.cap ? 0 : w.cap - used;
    }

    /// @notice Largest single spend the POLICY would currently permit, ignoring
    /// the allowlist and any co-signature requirement.
    ///
    /// Returns type(uint256).max for a live mandate bounded only by expiry — such a
    /// mandate genuinely has no amount limit, and reporting 0 would tell a
    /// pre-flighting agent it cannot spend when it can. `spendable` clamps this
    /// down to the allowance and balance, which is where the real number comes from.
    function policyHeadroom(bytes32 mandateId) public view returns (uint256) {
        Mandate storage m = _mandates[mandateId];
        if (!isLive(mandateId)) return 0;

        uint256 limit = type(uint256).max;
        if (m.flags & F_PER_TX != 0 && m.perTxCap < limit) limit = m.perTxCap;
        if (m.flags & F_TOTAL != 0) {
            uint256 left = m.totalCap > m.totalSpent ? m.totalCap - m.totalSpent : 0;
            if (left < limit) limit = left;
        }
        for (uint256 wi = 0; wi < m.windowCount; ++wi) {
            uint256 left = windowRemaining(mandateId, wi);
            if (left < limit) limit = left;
        }
        return limit;
    }

    /// @notice What can actually be spent right now: the policy limit intersected
    /// with the payer's ERC-20 allowance to this contract and their balance. An
    /// agent should read this before building a transaction — a mandate can be
    /// perfectly healthy while the payer has revoked the allowance or run dry.
    ///
    /// ARC NOTE: `balanceOf` here reads the 6-decimal ERC-20 view of a native
    /// balance held at 18 decimals, so it truncates — a native balance of
    /// 100.0000001 USDC reads as 100, and a non-zero balance below 1e-6 USDC
    /// reads as 0. That error is one-directional: this view can under-report by
    /// up to 1e-6 USDC, never over-report, so an agent that trusts it will at
    /// worst skip a spend it could have made. This is also the only place the
    /// contract reads a balance at all; the `spend` path never does, so the
    /// truncation cannot affect what a policy permits.
    function spendable(bytes32 mandateId) external view returns (uint256) {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) return 0;
        uint256 limit = policyHeadroom(mandateId);
        uint256 allowed = usdc.allowance(m.payer, address(this));
        if (allowed < limit) limit = allowed;
        uint256 bal = usdc.balanceOf(m.payer);
        return bal < limit ? bal : limit;
    }
}
