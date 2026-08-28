// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
 * ┌───────────────────────────────────────────────────────────────────────────┐
 * │  NOT AUDITED. NOT DEPLOYED - this is v2, in progress, and it has never    │
 * │  run against any chain. REAL MONEY IS OUT OF SCOPE UNTIL AN AUDIT SAYS    │
 * │  OTHERWISE.                                                               │
 * │                                                                           │
 * │  V1 IS LIVE AND VERIFIED, AND IT IS A DIFFERENT CONTRACT, at              │
 * │  0x3744E93B9e796E05CB66311d897559B6F3860196 on Arc Testnet (chain         │
 * │  5042002). There is no proxy and no upgrade path, deliberately, so v2     │
 * │  gets its own address and v1 keeps running until its payers revoke.       │
 * │  Check out the tag v1.0.0-arc-testnet to build the bytes Blockscout       │
 * │  verified against that address. This file no longer does, and is not      │
 * │  meant to.                                                                │
 * │                                                                           │
 * │  WHAT V1 ESTABLISHED - evidence for the design, not proof of these        │
 * │  bytes. Thirty-one live transactions, every one status 1: five mandates,  │
 * │  five spends, three revocations, two cosign approvals, two withdrawals.   │
 * │  That is all five state-changing paths V1 EXPOSED, with receipts -        │
 * │  createMandate, spend, revoke, approveCosign, withdrawCosign - and that   │
 * │  list is enumerated from the TAGGED source, because it is a claim about   │
 * │  v1. Do not read it as a list of THIS file's paths. #28 deleted           │
 * │  approveCosign outright and put approveCosignFor in its place, and        │
 * │  approveCosignFor has never run on any chain. So four of this file's five │
 * │  paths have a v1 receipt for the same signature, the cosign approval path │
 * │  has none at all, and even the four are v1's bytes and not these.         │
 * │  Every spend emitted two Transfer logs, one from USDC's ERC-20 view and   │
 * │  one from Arc's native emitter, and all ten carry the PAYER as sender,    │
 * │  never this contract, so non-custody is observable rather than argued.    │
 * │  Both ERC-8004 gates fired against Arc's real registries. Gas against     │
 * │  real Arc USDC at the 21 Gwei charged: a first-ever policed spend cost    │
 * │  216,458 and the steady state is 177,429, of which ~103,500 is the        │
 * │  policy machinery and ~13,100 is Arc's own native-USDC accounting.        │
 * │                                                                           │
 * │  WHAT NONE OF THAT ESTABLISHES ABOUT THIS FILE. Every figure above is a   │
 * │  property of v1's bytecode. v2 changes the ABI, adds a grant-time         │
 * │  revert, a view and a flag, so its own test count and gas table are       │
 * │  deliberately absent here until both have been re-run against it - an     │
 * │  inherited number is worse than a missing one. Sub-second blocks sharing  │
 * │  a timestamp and the CallFrom precompile are still asserted from          │
 * │  documentation, not observed. No third party has reviewed any of this. A  │
 * │  green suite says the implementation matches the model; it does not say   │
 * │  the model is right about the world. This is INTENDED to hold real        │
 * │  money, so the audit is a requirement, not advice.                        │
 * │                                                                           │
 * │  THIS BANNER GOES FALSE THE MOMENT V2 DEPLOYS. Rewrite it in that         │
 * │  deployment's own commit. V1's said NEVER RUN AGAINST A LIVE CHAIN for    │
 * │  hours after it had, and a banner that lies teaches readers to skip the   │
 * │  next one.                                                                │
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

    /// NEW IN v2. How many mandates `spendableAcross` will read in one call. Same
    /// purpose as the two caps above — bound the gas of a loop over untrusted input —
    /// but note the difference that keeps it OUT of reference/policy.js: those two
    /// change which mandates can exist and therefore which spends are legal, while
    /// this one only rations a read and nothing downstream depends on it. Sized from
    /// the worst case it permits: 8 * ~290k storage-read gas is about 2.3M, which
    /// fits one `eth_call` at every default node gas cap.
    uint256 public constant MAX_JOINT = 8;

    /// NEW IN v2 (F16). The furthest ahead a co-signer may set an approval's deadline.
    ///
    /// v1 approvals never decayed: `_cosignApproved` held a `bool` and the only ways out
    /// were consumption and withdrawal, so an approval was good for the whole life of the
    /// mandate. `Cosign.t.sol` still holds the receipt for why that tail is dangerous — it
    /// approves a spend, has it refused by a window cap, warps a day forward and settles it
    /// — which is *correct* on its own terms (burning a signature on a transient failure
    /// pushes a human into pre-approving in bulk, and the control stops meaning anything)
    /// but composes badly with #22's requirement that every mandate carry a lifetime bound,
    /// since the recommended way to keep an open-ended arrangement creatable is a distant
    /// `expiresAt`. "Until used or withdrawn" then means years.
    ///
    /// So the deadline is the co-signer's to choose and this is the ceiling on it. Thirty
    /// days is picked from both directions: the floor is that same test, which needs an
    /// approval to survive `DAY + DAY/12` — about 26 hours — so any ceiling near a day
    /// would contradict reasoning this contract deliberately keeps; the reason not to go
    /// further is that a co-signer who genuinely needs longer can approve again, and that
    /// is the gate firing a second time rather than a gate that stopped existing. An
    /// uncapped `validUntil` would leave F16 advisory, because an agent that constructs the
    /// transaction can pre-fill `type(uint40).max` and a co-signer who does not read the
    /// field is back to a multi-year approval.
    uint40 public constant MAX_COSIGN_TTL = 30 days;

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
    /// mandateId => spendHash => the timestamp the approval dies AT, exclusive.
    ///
    /// CHANGED IN v2 (F16) from `bool`. Zero keeps meaning "no approval exists", which is
    /// the same one-directional rule #22 applied to `expiresAt`: a field whose zero is
    /// "absent" must never be writable as a meaningful value, so `approveCosignFor` refuses
    /// any `validUntil` at or below `block.timestamp`. Widening the value costs nothing in
    /// layout — `forge inspect MandateManager storage-layout` puts all eight of these
    /// mappings at 32 bytes in slots 0-7 regardless of value type, and this one is last, so
    /// nothing follows it to shift.
    mapping(bytes32 => mapping(bytes32 => uint40)) private _cosignApproved;

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

    /// CHANGED IN v2 (F15/F16), and its topic0 with it, so a v1 indexer must be rebuilt.
    ///
    /// v1 emitted the mandate, the hash and the co-signer and nothing else, which made the
    /// audit trail exactly as illegible as the transaction that produced it: an indexer had
    /// to decode calldata to learn what had been approved, and a payer reading events could
    /// not tell a 5,000 approval from a 5,000,000 one. The contract now knows the recipient
    /// and the amount at approval time — that is the whole point of `approveCosignFor` — so
    /// withholding them from the log would move the illegibility rather than remove it.
    /// Three words of data, about 768 gas.
    ///
    /// It does NOT close F12. A payer still cannot ask the contract which approvals are
    /// outstanding; they can now RECONSTRUCT that from logs, by pairing each
    /// `CosignApproved` with the `Spend` or `CosignWithdrawn` that consumed it and treating
    /// anything past `validUntil` as dead. That is an indexer's job, not a view's.
    event CosignApproved(
        bytes32 indexed mandateId,
        bytes32 indexed spendHash,
        address indexed cosigner,
        address recipient,
        uint256 amount,
        uint40 validUntil
    );
    event CosignWithdrawn(bytes32 indexed mandateId, bytes32 indexed spendHash, address indexed cosigner);

    // ---------------------------------------------------------------------
    // Errors.
    //
    // The correspondence with reference/policy.js is one-directional, and v1's
    // comment here claimed it both ways. Every one of the model's 21 `Denial`
    // reasons has an error below with the same name — that is the direction that
    // matters, because a denial the contract could not express would be a real
    // divergence. The reverse does not hold: ten of the errors below have no
    // `Denial` counterpart because the model reports those conditions by THROWING
    // rather than denying. They are MandateExists, Unbounded, BadWindow, BadConfig,
    // NotAuthorised, NotCosigner, MixedPayers, DuplicateMandate, TooManyMandates —
    // all caller or grant-time mistakes rather than policy outcomes — plus
    // TransferFailed, which the model cannot have an opinion about because it has
    // no token. 21 + 10 = 31. Counted, not asserted.
    //
    // When called through Memo, Arc wraps a child revert in MemoFailed(bytes), so
    // clients must unwrap one layer before decoding these.
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
    /// The uint96 audit counter would wrap. Only reachable without F_TOTAL, since a
    /// lifetime cap is itself a uint96 and binds first. v1 panicked here instead.
    error TotalSpentCeiling();
    error NonceAlreadyUsed();
    error CosignRequired(bytes32 spendHash);
    /// NEW IN v2 (F16). Deliberately NOT folded into `CosignRequired`. The two conditions
    /// need different actions from whoever reads the revert: `CosignRequired` means nobody
    /// has approved this spend, `CosignExpired` means somebody did and the window closed, so
    /// the agent should ask the same human again rather than wonder whether the request ever
    /// reached them. Carrying the deadline says WHEN it died, which is the fact an operator
    /// reconstructing a failed run actually needs. Same reason #23 splits
    /// `CredentialMissing`.
    error CosignExpired(bytes32 spendHash, uint40 validUntil);
    /// NEW IN v2 (F16). A `validUntil` at or below `block.timestamp` would be born dead, and
    /// one past `MAX_COSIGN_TTL` is the tail F16 exists to end. Refused rather than clamped:
    /// silently moving a co-signer's deadline would make the value they signed and the value
    /// stored disagree, which is the defect this repository has now refused three times.
    error BadDeadline(uint40 validUntil);
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
    error NotAuthorised();
    error NotCosigner();
    error AmountTooLarge();

    /// NEW IN v2, all three raised only by `spendableAcross` — the first errors in
    /// this contract that report a badly formed QUESTION rather than a refused
    /// action. Each replaces a plausible wrong number with a diagnosis; see that
    /// function for why returning the number was not an option.
    error MixedPayers();
    error DuplicateMandate();
    error TooManyMandates();

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

        // ---------------------------------------------------------------------
        // Refusing to mint an unbounded authority is the entire point of the
        // primitive, so it is enforced rather than documented.
        //
        // What counts as a bound is deliberately narrow, and narrower than it was:
        // only `totalCap` and `expiresAt` bound LIFETIME exposure. A
        // per-transaction cap alone does not — the delegate spends it again, and
        // again, until the payer's allowance is dry — and neither does a window
        // alone, which is bounded per period and unbounded over a lifetime. v1 and
        // the first draft of v2 accepted `F_PER_TX`-only and window-only grants, so
        // the sentence above promised more than the code delivered. It is now true.
        //
        // The accepted cost, written here so it is not rediscovered later as a
        // surprise: an open-ended arrangement — a subscription with a monthly
        // window and no end date — is no longer creatable as written. It is served
        // by naming a distant `expiresAt`, which costs the payer nothing and makes
        // the horizon explicit rather than absent. An opt-in strictness flag was
        // considered and is not available: `flags` is a uint8 and bit 7, the last
        // free bit, is committed to the merkle allowlist.
        //
        // The reasoning is the one that retires the dead co-signature gate below:
        // "merely useless" is not a reason to allow a configuration whose display
        // and whose enforcement disagree.
        // ---------------------------------------------------------------------
        if ((flags & F_TOTAL == 0) && (flags & F_EXPIRY == 0)) revert Unbounded();

        // Every flag must agree with the value it describes, so a malformed
        // grant is rejected at creation instead of behaving surprisingly later.
        if ((flags & F_PER_TX != 0) != (p.perTxCap > 0)) revert BadConfig();
        if ((flags & F_TOTAL != 0) != (p.totalCap > 0)) revert BadConfig();
        if ((flags & F_COSIGN != 0) != (p.cosigner != address(0))) revert BadConfig();
        if ((flags & F_CREDENTIAL != 0) != (p.credential.validator != address(0))) revert BadConfig();
        if ((flags & F_ALLOWLIST != 0) != (p.allowlist.length > 0)) revert BadConfig();
        if (flags & F_EXPIRY != 0 && p.expiresAt <= p.notBefore) revert BadConfig();
        // The mirror of the line above, and the last field in the struct that could
        // lie. With F_EXPIRY unset, v1 accepted any `expiresAt`, wrote it to storage
        // and emitted it in `MandateCreated`, while nothing ever read it — both
        // `spend` and `isLive` gate the comparison on the flag. So `getMandate` could
        // show a payer a mandate that expired last Tuesday and that spends forever.
        // One-directional rather than an iff for the same reason the threshold rule
        // below is: with the flag SET, the paired guard above already constrains the
        // value, so only the flag-unset direction is left to close.
        //
        // `notBefore` needs no such rule and that asymmetry is deliberate: it is
        // enforced unconditionally, in both `spend` and `isLive`, with no flag at
        // all, so it cannot be displayed-but-dead.
        if (flags & F_EXPIRY == 0 && p.expiresAt != 0) revert BadConfig();
        if (flags & F_CREDENTIAL != 0 && address(validationRegistry) == address(0)) revert BadConfig();
        if (flags & F_IDENTITY != 0 && address(identityRegistry) == address(0)) revert BadConfig();

        // ---------------------------------------------------------------------
        // The co-signature gate has to be checked as a WHOLE, not field by field.
        // Three ways to grant a mandate that displays a co-signature requirement and
        // does not have one; v1 accepted all three. The first two are settled here
        // because they are pure comparisons, and the third waits for the window loop
        // below because it needs the window caps.
        // ---------------------------------------------------------------------

        // (1) A threshold with no gate behind it is a lie told by `getMandate`. The field
        // is stored, a reader sees a number, and no spend is ever measured against it.
        // Note this is deliberately NOT folded into the biconditional above: that one is
        // on the cosigner ADDRESS, because a threshold of zero is meaningful when F_COSIGN
        // is set — it means every spend needs a signature, since the gate tests
        // `amount > threshold` strictly and `amount` is at least 1. So the threshold gets
        // a one-directional rule rather than an iff.
        if (flags & F_COSIGN == 0 && p.cosignThreshold != 0) revert BadConfig();

        // (2) The agent may not be its own cosigner. `approveCosignFor` requires
        // msg.sender == m.cosigner and nothing else, so a mandate whose cosigner is its
        // spender lets the agent approve its own spend hash and then spend it: two
        // transactions instead of one, and no second party anywhere. That is not a weaker
        // control, it is the absence of one wearing its clothes — and it is invisible in
        // `getMandate`, which shows F_COSIGN set and a plausible threshold. Refusing it is
        // the same argument as Unbounded() above: this primitive exists to make authority
        // legible, so a grant that appears to carry a control it does not carry is refused
        // rather than documented.
        //
        // Written unconditionally because it is equivalent to the guarded form and
        // cheaper: with F_COSIGN unset the biconditional above has already forced
        // `cosigner == address(0)`, and `spender == address(0)` was refused at the top, so
        // this can only fire when a cosigner was actually named. `cosigner == payer`
        // stays legal and is the ordinary case — it is what mandate 2 does on Arc today.
        if (p.cosigner == p.spender) revert BadConfig();

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

        // Tracks the tightest window cap as the loop validates each one, so the cosign
        // reachability check below costs no second pass over calldata. The identity value
        // is the uint96 ceiling rather than zero, because "no windows" must mean "no
        // window constraint on a single spend", and a minimum initialised to zero would
        // say the opposite.
        uint96 minWindowCap = type(uint96).max;

        for (uint256 i = 0; i < p.windows.length; ++i) {
            WindowParams calldata w = p.windows[i];
            // Sub-periods must be uniform, so the length has to divide evenly.
            if (w.lengthSeconds == 0 || w.cap == 0) revert BadWindow();
            if (w.buckets == 0 || w.buckets > MAX_BUCKETS) revert BadWindow();
            if (w.lengthSeconds % w.buckets != 0) revert BadWindow();
            if (w.cap < minWindowCap) minWindowCap = w.cap;
            _windows[mandateId][i] = WindowSpec({
                lengthSeconds: w.lengthSeconds,
                subLength: w.lengthSeconds / w.buckets,
                cap: w.cap,
                buckets: w.buckets
            });
        }

        // (3) The gate must be able to fire. `spend` requires a co-signature when
        // `amount > cosignThreshold`, strictly, so the gate is dead unless the policy
        // permits at least one amount above the threshold. Compare the threshold against
        // the largest single spend the WHOLE policy allows:
        //
        //   effectiveMax = min(2^96 - 1, perTxCap if F_PER_TX, totalCap if F_TOTAL,
        //                      every window cap)
        //
        // and refuse when `effectiveMax <= cosignThreshold`. Each term earns its place.
        // The uint96 ceiling is the bound when nothing else applies — a mandate bounded
        // only by an expiry still caps amounts, at `AmountTooLarge`, so a threshold of
        // 2^96 - 1 is unreachable there and is caught here. `totalCap` is evaluated at
        // `totalSpent == 0`, which is correct because reachability asks whether the gate
        // can EVER fire, and the lifetime cap is loosest on the first spend. Window caps
        // enter as a minimum for the same reason: the tightest one binds every spend.
        //
        // WHY THE OBVIOUS TEST IS WRONG TWICE. `perTxCap < cosignThreshold` fails on both
        // counts. It has the comparison backwards — equality is dead too, since
        // `amount > threshold` and `amount <= perTxCap` cannot both hold when the two are
        // equal, and this repository already held the receipt: `DESIGN.md:1272` records a
        // 50,000 spend against a 50,000 threshold not tripping the gate on Arc Testnet.
        // And `perTxCap` is not the only ceiling — with F_PER_TX unset, `totalCap = 100`
        // with `cosignThreshold = 100` is equally dead and passes both spellings of the
        // naive check. `L3-VAULT.md` inherited that same error from `CHANGELIST.md`, which
        // is why the fix is phrased against the whole policy rather than against one field.
        if (flags & F_COSIGN != 0) {
            uint96 effectiveMax = minWindowCap;
            if (flags & F_PER_TX != 0 && p.perTxCap < effectiveMax) effectiveMax = p.perTxCap;
            if (flags & F_TOTAL != 0 && p.totalCap < effectiveMax) effectiveMax = p.totalCap;
            if (effectiveMax <= p.cosignThreshold) revert BadConfig();
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

        // `amount` is bounded by the `AmountTooLarge` guard above, which is
        // unconditional and runs before any policy check precisely so that this cast
        // is sound — see the comment there. If that guard is ever moved behind a flag
        // this becomes unsound: a caller could pass 2^96 and have it wrap to 0,
        // spending nothing against the caps while the transfer below moves the full
        // amount. Narrowed once into a local rather than cast at each of the four
        // uses below, so there is a single line to audit.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 amount96 = uint96(amount);

        // The lifetime cap is consulted BEFORE the counter advances, and is phrased so
        // that the check itself cannot overflow: comparing `totalSpent` against
        // `totalCap - amount96` is equivalent to comparing `totalSpent + amount96`
        // against `totalCap`, without performing the addition. The first clause also
        // proves the subtraction cannot underflow.
        //
        // v1 added first and read the flag second, which meant the addition was
        // evaluated even for a mandate with no lifetime cap — a panic rather than a
        // graceful denial near the uint96 ceiling. `_checkAndCommitWindows` already
        // used this compare-before-committing shape for window caps; the lifetime cap
        // was the only bound in the contract that did not.
        if (m.flags & F_TOTAL != 0) {
            if (amount96 > m.totalCap || m.totalSpent > m.totalCap - amount96) {
                revert OverTotalCap();
            }
        }

        // Advance the audit counter. This is deliberately NOT conditional on F_TOTAL:
        // `totalSpent` rides in the `Spend` event and reconcilers read it, so it must
        // record what was actually transferred even for a mandate that has no
        // lifetime cap. That is also why it is not saturated — a counter that quietly
        // stops counting understates real flow, which is a worse failure than a
        // mandate that stops working.
        //
        // So the uint96 ceiling remains, but as a denial with a name instead of a
        // panic. It is reachable ONLY when F_TOTAL is unset, because a lifetime cap is
        // itself a uint96 and therefore binds first. Widening `totalSpent` to uint120
        // would fit the struct's three spare bytes for free and push this 2^24 further
        // out; it was declined because the range was never the defect — the
        // illegibility of a panic was — and it would change the `Spend` event
        // signature, hence its topic0, for a condition this guard already answers.
        //
        // Placed here, above `_checkAndCommitWindows`, which is where v1 did the counter
        // arithmetic — so the fix reorders no policy check relative to any other, and the
        // audit diff is a rewritten comparison rather than a moved gate. One consequence
        // to know when reading a revert: at the ceiling this error is returned even when a
        // window cap would also have refused the request, because it is tested first.
        // `Bounds.t.sol` pins that ordering deliberately rather than relying on it.
        if (m.totalSpent > type(uint96).max - amount96) revert TotalSpentCeiling();
        uint96 newTotal;
        unchecked {
            newTotal = m.totalSpent + amount96; // cannot overflow: guarded above
        }

        _checkAndCommitWindows(mandateId, m.windowCount, amount96, nowTs);

        // `msg.sender == m.spender` was proven above, so reading the spender back out of
        // storage here is the same hash v1 computed from `msg.sender` — the change is to the
        // INTERFACE, not to the preimage. Calling the public view rather than inlining
        // `keccak256` keeps exactly one implementation of the encoding in the contract, which
        // is worth one warm SLOAD: two copies of a nine-field `abi.encode` is precisely the
        // kind of pair that drifts.
        hash = spendHash(mandateId, recipient, amount, ref, nonce);
        if (m.flags & F_COSIGN != 0 && amount > m.cosignThreshold) {
            uint40 validUntil = _cosignApproved[mandateId][hash];
            if (validUntil == 0) revert CosignRequired(hash);
            // Exclusive, exactly like `m.expiresAt` above and for the same reason: Arc's
            // sub-second blocks can share a timestamp, so an inclusive bound would leave an
            // ambiguous final second where liveness depends on which block within that
            // second included the transaction.
            if (nowTs >= validUntil) revert CosignExpired(hash, validUntil);
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
     *
     * The error is named for authority rather than for a role, because two roles
     * hold it. v1 called it NotPayer() and said so in four places while keeping
     * the name, on the grounds that it was already in a deployed ABI. That reason
     * expired with the tag v1.0.0-arc-testnet: v1's ABI is pinned at v1's address
     * and this is a different contract, so the selector changes here from
     * 0x1435e357 to 0x1648fd01 and clients decoding v2 must be rebuilt.
     */
    function revoke(bytes32 mandateId) external {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) revert UnknownMandate();
        if (msg.sender != m.payer && msg.sender != m.spender) revert NotAuthorised();
        m.revoked = true;
        emit MandateRevoked(mandateId, msg.sender);
    }

    /**
     * @notice Pre-approve exactly one spend above the co-sign threshold, by its fields.
     *
     * REPLACES v1's `approveCosign(bytes32 mandateId, bytes32 hash)`, which is gone rather
     * than kept alongside this (F15). The old function took a hash and nothing else, so it
     * never learned the recipient, the amount, the reference or the nonce — a hash is not
     * invertible and this contract keeps no reverse index. The transaction a co-signer signed
     * therefore carried two 32-byte words and no readable fact about the payment. On a
     * hardware wallet it read `approveCosign(0x…, 0x…)`; behind a Safe it was worse, because
     * the second and third signers were approving a hash of a claim made to somebody else.
     *
     * That is blind signing, and it mattered here more than it would anywhere else in this
     * contract. Every other control is enforced by the contract — caps, allowlist, expiry,
     * nonce, spender — and the co-signature gate is the one whose entire value is a human
     * judgment. It handed that human the least legible object it had.
     *
     * Deleting the old entry point rather than adding this one beside it is the part worth
     * defending, because it cost real work and one piece of evidence. Keeping both would have
     * left the choice of path with whoever asks for the signature, and the party most likely
     * to ask is the agent: an agent that wants a co-signer to approve something they have not
     * read would simply keep using the illegible call. A legibility control that the
     * adversary can opt out of on the victim's behalf is not a control. The evidence cost is
     * named in `test/ArcParity.t.sol`, where measurement 4 could compare a local
     * `approveCosign` against a real Arc receipt for the identical function, and now cannot.
     *
     * Deriving the hash from `m.spender` rather than a parameter also retires a footgun in
     * the public `spendHash`, whose `spender_` argument let an off-chain caller compute — and
     * a co-signer then approve — a hash that no spend could ever match. The preimage is
     * unchanged: same nine fields in the same order, with `m.spender` where `spender_` stood.
     *
     * @param validUntil The timestamp this approval dies AT, exclusive. The co-signer's
     * choice, bounded below by `block.timestamp` (a deadline already past would be born dead)
     * and above by `MAX_COSIGN_TTL`. See F16 on that constant for why both bounds exist.
     * @return hash The spend hash now approved. Returned rather than only logged so a
     * co-signer's own transaction receipt carries the one value `withdrawCosign` needs — F12
     * is that neither party can enumerate outstanding approvals, and this is the cheap half.
     *
     * What this deliberately does NOT do is refuse an approval that can never be consumed: a
     * revoked or expired mandate, or an amount at or below the threshold, or a zero amount or
     * recipient. Those are F17, they are next, and they are separable precisely because they
     * add no parameters — the reason F15 and F16 had to land together is that both rewrote
     * this signature, and F17 does not.
     *
     * This still requires the co-signer to send a transaction. An EIP-712 signature variant
     * would be better UX — the approver signs off-chain and the agent submits it — and it is
     * a deliberate omission rather than an oversight. It was originally left out because this
     * file was written with no compiler available and unverifiable signature-recovery code is
     * the worst possible thing to ship on trust. That reason has expired; the remaining one
     * is scope. If it is added, it needs its own malleability, replay and chain-binding
     * tests, not a green suite inherited from this path. Note it would also have to carry
     * these explicit fields rather than a bare hash, for the reason above.
     */
    function approveCosignFor(
        bytes32 mandateId,
        address recipient,
        uint256 amount,
        bytes32 ref,
        bytes32 nonce,
        uint40 validUntil
    ) external returns (bytes32 hash) {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) revert UnknownMandate();
        if (m.flags & F_COSIGN == 0) revert BadConfig();
        if (msg.sender != m.cosigner) revert NotCosigner();

        uint256 nowTs = block.timestamp;
        // Both bounds refuse rather than clamp, and the lower one is why zero can keep
        // meaning "no approval" in the mapping.
        if (validUntil <= nowTs || uint256(validUntil) > nowTs + MAX_COSIGN_TTL) {
            revert BadDeadline(validUntil);
        }

        hash = spendHash(mandateId, recipient, amount, ref, nonce);
        _cosignApproved[mandateId][hash] = validUntil;
        emit CosignApproved(mandateId, hash, msg.sender, recipient, amount, validUntil);
    }

    /// @notice Withdraw an approval that has not been used yet.
    ///
    /// Still keyed by hash, and that is deliberate rather than an oversight of F15's
    /// argument. The hazard F15 removes is a co-signer GRANTING authority they cannot read;
    /// withdrawing only ever removes authority, so the worst outcome of passing the wrong
    /// hash here is that nothing happens. `approveCosignFor` returns the hash and
    /// `CosignApproved` logs it, so a co-signer who approved through this contract has it.
    ///
    /// An expired approval is not cleared by the spend that trips over it — `spend` reverts,
    /// which rolls back any write — so it sits in storage reported by
    /// `cosignApprovalDeadline` until someone calls this. That is inert (`spend` refuses it
    /// on every future block) but it is storage nobody is obliged to clean, which is the same
    /// shape as F17's unconsumable approvals and is noted there.
    function withdrawCosign(bytes32 mandateId, bytes32 hash) external {
        Mandate storage m = _mandates[mandateId];
        if (msg.sender != m.cosigner) revert NotCosigner();
        delete _cosignApproved[mandateId][hash];
        emit CosignWithdrawn(mandateId, hash, msg.sender);
    }

    // =====================================================================
    // Views — pre-flight checks so an agent does not waste gas on a doomed call
    // =====================================================================

    /// @notice The hash a co-signature binds, and the idempotency key of a spend.
    ///
    /// CHANGED IN v2 (F15): the `spender_` parameter is gone and the spender is read from the
    /// mandate. The preimage is identical — same nine fields, same order — so this returns
    /// what v1 returned for the same mandate; what is no longer expressible is a hash naming
    /// a spender the mandate does not have, which nothing could ever match and which a
    /// co-signer could nonetheless have been handed and approved.
    ///
    /// Reverts on an unknown mandate rather than hashing `address(0)` as the spender. A view
    /// that answers a meaningless question with a plausible 32 bytes is the same defect one
    /// layer down.
    function spendHash(bytes32 mandateId, address recipient, uint256 amount, bytes32 ref, bytes32 nonce)
        public
        view
        returns (bytes32)
    {
        Mandate storage m = _mandates[mandateId];
        if (m.payer == address(0)) revert UnknownMandate();
        return keccak256(
            abi.encode(DOMAIN, block.chainid, address(this), mandateId, m.spender, recipient, amount, ref, nonce)
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

    /// @notice Whether this spend hash would be honoured RIGHT NOW.
    ///
    /// CHANGED IN v2 (F16). The signature is v1's, the meaning is not: it was a bare read of
    /// the mapping, so under a `uint40` value it would report `true` for an approval that
    /// expired months ago. That is the exact defect #11 and #22 each refused at grant time —
    /// state whose display and whose enforcement disagree — and refusing it there while
    /// shipping it in a view would make the doctrine a preference about two fields.
    ///
    /// Use `cosignApprovalDeadline` to see the stored value, including a dead one.
    function isCosignApproved(bytes32 mandateId, bytes32 hash) external view returns (bool) {
        uint40 validUntil = _cosignApproved[mandateId][hash];
        return validUntil != 0 && block.timestamp < validUntil;
    }

    /// @notice The raw deadline stored against a spend hash, exclusive.
    ///
    /// NEW IN v2 (F16). Zero means no approval was ever written. Any other value is the
    /// timestamp it dies at, which may already be past — that is the point of exposing it. A
    /// payer or co-signer auditing a mandate wants to distinguish "never approved" from
    /// "approved and it lapsed", and `isCosignApproved` returns `false` for both.
    function cosignApprovalDeadline(bytes32 mandateId, bytes32 hash) external view returns (uint40) {
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

    /// @notice Largest single spend the POLICY'S AMOUNT BOUNDS would currently
    /// permit: the per-transaction cap, the lifetime cap and every window,
    /// intersected, for a mandate `isLive` accepts.
    ///
    /// Four things can still deny a spend this function calls affordable, and the
    /// v1 comment here named only the first two. The allowlist is a property of the
    /// recipient rather than the amount. The co-signature requirement gates spends
    /// ABOVE a threshold instead of capping them, so a large number here may still
    /// need an `approveCosignFor` first. BOTH ERC-8004 GATES ARE ALSO INVISIBLE HERE:
    /// `isLive` covers revocation, `notBefore` and expiry and stops there, making no
    /// external calls, while the identity and credential gates read the registries
    /// during `spend` — so a mandate whose agent has transferred its identity NFT,
    /// or whose attestation has gone stale, reports full headroom here and reverts
    /// there. That omission is deliberate rather than an oversight: this is the
    /// pre-flight path, and it should not cost two external calls or stop working
    /// when a registry is unreachable. Lastly the spend nonce is per-call, not
    /// per-mandate, so replay is not knowable from a mandate id alone.
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

    /// @notice NEW IN v2. The joint ceiling across several mandates held against one
    /// payer: the largest total that ONE spend from each named mandate could move
    /// right now. Mirrored in reference/policy.js as `headroomAcross`.
    ///
    /// WHY IT EXISTS. `spendable` answers "what can this mandate move?" and cannot
    /// answer "what can all of them move?", because the thing they share is in no
    /// mandate — it is the payer's single ERC-20 allowance to this contract. On
    /// 2026-08-24 two live mandates at this address each returned `spendable` of
    /// 90,000 against an allowance of exactly 90,000, and a 50,000 dry-run succeeded
    /// on both. A payer adding those up gets 180,000, twice what they can lose; a
    /// payer reading this view gets 90,000. It does NOT fix the underlying race — two
    /// delegates can still both spend until the shared allowance is dry, which is
    /// inherent to layering per-mandate policy over one allowance and is the reason
    /// `MAX_JOINT` exists at all rather than a general-purpose batching API. It makes
    /// the overlap a number instead of an inference nobody makes.
    ///
    /// WHAT IT IS NOT. Not total flow. A mandate with a rolling window permits
    /// repeated spends as buckets age out, so over any interval longer than an
    /// instant the real total exceeds this. Not a promise either: like `spendable`,
    /// it is blind to the allowlist, the cosign threshold, both ERC-8004 gates and
    /// the per-call nonce — see `policyHeadroom` for why those are absent.
    ///
    /// WHY EACH TERM IS CLAMPED AT type(uint96).max. Not defensive padding: the same
    /// correction the cosign gate needed. `policyHeadroom` returns
    /// `type(uint256).max` for a mandate bounded only by an expiry, but `spend`
    /// refuses anything above `type(uint96).max` with `AmountTooLarge` — so that
    /// return value over-reports the largest single spend, and `sum += policyHeadroom`
    /// over two such mandates from one payer does not merely over-report, it PANICS.
    /// Two expiry-only grants is a two-line construction, so this is the same failure
    /// class as v1's `totalSpent` cliff rather than an astronomical edge. Clamping
    /// each term first makes every term the true largest single spend, and has a
    /// second consequence that is easy to lose: the sum can then not overflow at all.
    /// `MAX_JOINT * type(uint96).max` is 8 * (2^96 - 1) < 2^99, against a uint256
    /// ceiling of 2^256. Do NOT "harden" the addition with a saturating add or an
    /// unchecked block — either would give identical answers while destroying the
    /// reason they are correct, which is that the terms are bounded and not that the
    /// sum is caught.
    ///
    /// THREE REFUSALS, ALL BECAUSE THE ALTERNATIVE IS A PLAUSIBLE WRONG NUMBER.
    /// `MixedPayers` because there is no joint ceiling across payers — each has a
    /// separate allowance and balance, so no single clamp applies and the sum means
    /// nothing. `DuplicateMandate` because one mandate's headroom exists once, and
    /// deduplicating silently would hand the right number to a caller who still
    /// believes they hold two grants. `UnknownMandate` because a name that resolves
    /// to nothing must not quietly contribute zero: `spendable` returning 0 for an
    /// unknown id is unambiguous, but one bad id among eight is invisible, and this
    /// view exists precisely to surface what the per-mandate views hide. Revoked and
    /// expired mandates do contribute zero WITHOUT reverting — they are the ordinary
    /// contents of any real caller's list.
    ///
    /// GAS. Up to 139 cold storage reads per mandate (2 for the struct slots `isLive`
    /// touches, 1 for `totalCap`, then 4 windows x (1 spec + 33 ring slots)), so
    /// roughly 290k gas each and about 2.3M for a full eight. That fits one `eth_call`
    /// at every default node gas cap and one on-chain call inside a block, which is
    /// what `MAX_JOINT` is sized for. A payer with more than eight mandates on one
    /// allowance does off chain what this does on chain: read `policyHeadroom` per id,
    /// clamp each at `type(uint96).max`, add, then clamp by `allowance` and
    /// `balanceOf`. `MAX_JOINT` is deliberately NOT in reference/policy.js: bounds
    /// that constrain the state machine are mirrored there because they change which
    /// spends are legal, while a bound that only rations a read has nothing
    /// downstream depending on it, and JavaScript has no gas budget to ration.
    function spendableAcross(bytes32[] calldata mandateIds) external view returns (uint256) {
        uint256 n = mandateIds.length;
        // Answered, not refused. Nothing can move nothing, and reading `mandateIds[0]`
        // to find the payer of an empty set would revert with a panic that says
        // nothing about policy.
        if (n == 0) return 0;
        if (n > MAX_JOINT) revert TooManyMandates();

        // The payer is read from the first id rather than taken as a parameter — it is
        // derivable, and a parameter would let a caller assert a payer the ids do not
        // have. Checking it for existence here is what makes "the payer of nothing"
        // unreachable below. The loop reads slot 0 of this same mandate again at i == 0;
        // that is a warm SLOAD at 100 gas, bought deliberately to keep the loop body
        // uniform rather than branching on the first iteration.
        address payer = _mandates[mandateIds[0]].payer;
        if (payer == address(0)) revert UnknownMandate();

        // The largest amount `spend` will accept, and therefore the largest a single
        // spend from any mandate can be regardless of what caps the payer set. Hoisted
        // because it is the same bound for every term and because naming it is what
        // makes the loop body's clamp read as a correction rather than a guard.
        uint256 maxSingleSpend = type(uint96).max;

        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = mandateIds[i];
            address p = _mandates[id].payer;
            if (p == address(0)) revert UnknownMandate();
            if (p != payer) revert MixedPayers();

            // O(n^2) over at most 8 ids is at most 28 comparisons of already-warm
            // calldata, which is free beside the ~290k of storage reads each id costs.
            // The alternative — requiring strictly ascending ids so duplicates fall out
            // of one pass — would push a sort by keccak hash onto every caller to save
            // nothing measurable. A view cannot write the seen-set to storage.
            for (uint256 j = 0; j < i; ++j) {
                if (mandateIds[j] == id) revert DuplicateMandate();
            }

            uint256 one = policyHeadroom(id);
            total += one > maxSingleSpend ? maxSingleSpend : one;
        }

        uint256 allowed = usdc.allowance(payer, address(this));
        if (allowed < total) total = allowed;
        uint256 bal = usdc.balanceOf(payer);
        return bal < total ? bal : total;
    }
}
