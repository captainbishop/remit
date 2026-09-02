// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * Deploys MandateManager with its three constructor arguments pinned per chain.
 *
 * WHY THIS FILE EXISTS, given that the live contract was deployed without it.
 *
 * v1 went to Arc Testnet by a `forge create` command copied out of README.md. That
 * worked, and it is also the single riskiest step in the whole project. The three
 * arguments become `immutable` at construction and this contract has no upgrade path,
 * so a mistyped USDC address produces a deployment that looks healthy — it verifies on
 * the explorer, `getMandate` answers, `isLive` answers — and moves no money, or worse,
 * moves the wrong token. A hand-typed hex string is the wrong place to put that risk.
 *
 * The addresses therefore live here, keyed by chain id, and `run()` refuses to deploy
 * to a chain it has no entry for. Refusing is the correct default: a deployment that
 * does not happen costs a minute, and a deployment wired to the wrong token cannot be
 * undone.
 *
 * WHAT IT CHECKS, in order.
 *
 * Before deploying: that the chain is one this file knows; that whatever sits at the USDC
 * address reports 6 decimals, and refuses to continue if it will not say; that neither
 * registry address is non-zero yet codeless; and that no two of the three arguments name
 * the same address. Every amount in this system is a 6-decimal `uint96`, so against an
 * 18-decimal token the same numbers mean a millionth of the intended cap.
 *
 * After deploying: that the contract has code, that `DOMAIN` is the value v1 pinned, and
 * that all three immutables read back as the addresses that went in.
 *
 * WHAT THE READ-BACK DOES NOT CATCH, since an earlier version of this comment claimed it
 * did. Comparing `mm.usdc()` to the `usdc_` that was just handed to the constructor puts
 * one value on both sides of the comparison, so it holds for every input, including a
 * transposed one. Constructor arguments are ABI-encoded positionally, three addresses in a
 * row, and neither `forge create` nor a block explorer will tell you they went in the wrong
 * order — but neither will a read-back that compares an argument against itself. What
 * catches transposition is comparing against a value that did not travel through the same
 * call, which is why `run()` repeats the three comparisons against the pinned constants
 * after `_deploy` returns. The checks inside `_deploy` remain, because they are the only
 * ones `runWith` can have, and there they do catch a constructor that assigns in the wrong
 * order rather than a caller that passes in the wrong order.
 *
 * That distinction is worth a sentence because the two mistakes have the same symptom.
 * Swapping the USDC and identity arguments produces a deployment that verifies, answers
 * `getMandate` and `isLive`, and reverts every spend: ERC-20 and ERC-721 both declare
 * `transferFrom(address,address,uint256)` and therefore share selector `0x23b872dd`, so the
 * call dispatches into the registry's ERC-721 method, which returns nothing, and solc 0.8.28
 * reverts decoding a bool from empty return data.
 *
 * The registries are allowed to be zero and the constructor accepts that; only USDC is
 * refused at zero. A zero registry disables the ERC-8004 credential check rather than
 * breaking it, which is why it is a configuration and not a mistake. A registry that is
 * non-zero and codeless is the mistake, and it is refused: `_checkIdentity` and
 * `_checkCredential` wrap their calls in `try`/`catch`, and a `STATICCALL` to a codeless
 * address succeeds with empty return data, so the decode fails inside this frame where the
 * `catch` cannot see it. The documented `IdentityNotHeld` denial becomes a bare revert.
 */
contract Deploy is Script {
    /// The chain has no pinned argument set, so this script will not guess one.
    error UnknownChain(uint256 chainId);
    /// An immutable read back from the deployed contract is not what was passed in.
    error WiringMismatch();
    /// The address the broadcast reported has no code.
    error EmptyDeployment();
    /// The pinned USDC address answered `decimals()` with something other than 6.
    error UnexpectedDecimals(uint256 got);
    /// The USDC address did not answer `decimals()` at all. See `_checkDecimals`.
    error DecimalsUnavailable();
    /// A non-zero registry address holds no code, so every check reading it would fail
    /// undecodably rather than denying legibly.
    error RegistryHasNoCode(address registry);
    /// Two constructor arguments name the same address.
    error DuplicateArgument(address repeated);

    // ---------------------------------------------------------------------
    // Pinned arguments. Every address below is commented with what it is and
    // how it was confirmed, because an uncommented constant in a deploy script
    // is exactly what a reviewer reads past without re-checking.
    // ---------------------------------------------------------------------

    /// Arc Testnet. The value `spend` hashes into every co-signature, so it is also
    /// what makes a cosign approval from this chain unusable anywhere else.
    uint256 internal constant ARC_TESTNET = 5042002;

    /// Arc's native USDC, exposed as a standard ERC-20 at a fixed address rather than
    /// deployed as an ordinary token, with 6 decimals. This is the address the 31 live
    /// transactions in evidence/ spent through, so it is confirmed by use, not by
    /// documentation alone.
    address internal constant ARC_TESTNET_USDC = 0x3600000000000000000000000000000000000000;

    /// ERC-8004 IdentityRegistry. Agent identities are ERC-721 tokens here, which is
    /// why `_checkIdentity` treats a revert from `ownerOf` as "no such agent" rather
    /// than reading a zero address.
    address internal constant ARC_TESTNET_IDENTITY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    /// ERC-8004 ValidationRegistry. Keyed by `requestHash` alone, which is why
    /// `_checkCredential` has to re-check the validator and agent id that come back in
    /// the tuple instead of trusting the lookup.
    address internal constant ARC_TESTNET_VALIDATION = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    /**
     * The safe entry point, and the one to use.
     *
     * Dry run first — no `--broadcast`, so nothing is sent and every check below still
     * runs against the fork of the live chain:
     *
     *   forge script script/Deploy.s.sol:Deploy \
     *     --rpc-url https://rpc.testnet.arc.io \
     *     --account remit-testnet
     *
     * Then the real one, which is the same line plus `--broadcast`.
     *
     * `--account` names an encrypted keystore in ~/.foundry/keystores and prompts for
     * its password. There is deliberately no `vm.envUint("PRIVATE_KEY")` anywhere in
     * this file: a plaintext key in `.env` is one `git add -A` away from being
     * published, and this project treats that as the larger risk. Arc's own tutorial
     * does it the other way; this is a considered deviation, not an oversight.
     *
     * The prompt from `--account` makes this command the last line of anything pasted
     * into a terminal. A hidden password prompt reads whatever is still queued in the
     * input buffer, so a queued second command would be consumed as the password and
     * then run as a command.
     */
    function run() external returns (MandateManager mm) {
        if (block.chainid != ARC_TESTNET) revert UnknownChain(block.chainid);
        mm = _deploy(ARC_TESTNET_USDC, ARC_TESTNET_IDENTITY, ARC_TESTNET_VALIDATION);

        // The comparisons that actually catch a transposed argument order, because the right
        // hand side of each one did not travel through `_deploy`. Reading the immutables back
        // inside `_deploy` compares each argument against itself; these compare against the
        // constants at the top of this file. Repeating three lines is the price of that.
        if (address(mm.usdc()) != ARC_TESTNET_USDC) revert WiringMismatch();
        if (address(mm.identityRegistry()) != ARC_TESTNET_IDENTITY) revert WiringMismatch();
        if (address(mm.validationRegistry()) != ARC_TESTNET_VALIDATION) revert WiringMismatch();
        console.log("read back against the pinned constants, not against the arguments");
    }

    /**
     * The explicit-argument form, for a local chain or a network this file has no entry
     * for yet.
     *
     *   forge script script/Deploy.s.sol:Deploy \
     *     --sig 'runWith(address,address,address)' <usdc> <identity> <validation> \
     *     --rpc-url <url> --account <keystore>
     *
     * Kept separate on purpose. Reading the arguments from the environment would let a
     * stray variable replace the pinned set above without appearing anywhere in the
     * output, which would make the pinning decorative. Typing them makes the choice
     * visible in shell history and in whatever log the run is teed to.
     *
     * It refuses any chain this file pins, so the safe path cannot be reached the unsafe way.
     * Before that refusal existed, `runWith` was the whole of the file's protection turned
     * off by one flag: no chain check, and a decimals probe that continued when the token
     * said nothing. Announcing the bypass in a `console.log` is not a check — nothing reads
     * it, and a deployment that has already happened cannot be talked out of.
     */
    function runWith(address usdc_, address identity_, address validation_) external returns (MandateManager mm) {
        if (block.chainid == ARC_TESTNET) revert UnknownChain(block.chainid);
        console.log("runWith: pinned addresses bypassed, arguments taken from the command line");
        mm = _deploy(usdc_, identity_, validation_);
    }

    // ---------------------------------------------------------------------
    // The one code path both entry points share.
    // ---------------------------------------------------------------------

    function _deploy(address usdc_, address identity_, address validation_) internal returns (MandateManager mm) {
        console.log("chain id        ", block.chainid);
        console.log("usdc            ", usdc_);
        console.log("identityRegistry", identity_);
        console.log("validation      ", validation_);

        _checkDecimals(usdc_);
        _checkRegistries(identity_, validation_);
        _checkDistinct(usdc_, identity_, validation_);

        vm.startBroadcast();
        mm = new MandateManager(usdc_, identity_, validation_);
        vm.stopBroadcast();

        console.log("MandateManager  ", address(mm));

        // These checks run in the dry run too, because `forge script` executes the constructor
        // against a fork whether or not `--broadcast` is passed. That is what makes the dry run
        // worth doing: a mistake is caught before any transaction is signed, on a chain state
        // identical to the real one.
        //
        // The three read-backs below catch a constructor that assigns its arguments to the wrong
        // immutables. They cannot catch a caller that passes them in the wrong order, because
        // both sides of each comparison come from the same three locals. `run()` does that, by
        // comparing against the pinned constants after this function returns.
        if (address(mm).code.length == 0) revert EmptyDeployment();

        // A tripwire rather than a wiring check, and worth naming as such after the mistake
        // above. `DOMAIN` is a compile-time constant in the source this script imports, so this
        // comparison cannot fail for a deployment made from this tree. What it catches is a
        // later edit to the separator: the contract's own header calls `DOMAIN`
        // consensus-relevant, it is mixed into every mandate id and every co-signature hash,
        // and changing it invalidates every id a client has stored with no error to announce
        // the change. Whoever edits it has to edit this line too, which is the point.
        if (mm.DOMAIN() != keccak256("Remit:v1")) revert WiringMismatch();

        if (address(mm.usdc()) != usdc_) revert WiringMismatch();
        if (address(mm.identityRegistry()) != identity_) revert WiringMismatch();
        if (address(mm.validationRegistry()) != validation_) revert WiringMismatch();

        console.log("runtime bytes   ", address(mm).code.length);
        console.logBytes32(mm.DOMAIN());
        console.log("^ DOMAIN, asserted equal to keccak256(\"Remit:v1\")");
        console.log("all three immutables read back as passed");
        console.log("");
        console.log("Next, publish the source so the explorer shows an ABI instead of");
        console.log("bytecode. Arc Testnet Explorer runs Blockscout:");
        console.log("");
        console.log("  forge verify-contract <address> \\");
        console.log("    contracts/MandateManager.sol:MandateManager \\");
        console.log("    --chain-id 5042002 --verifier blockscout \\");
        console.log("    --verifier-url https://testnet.arcscan.app/api/ \\");
        console.log("    --constructor-args $(cast abi-encode \\");
        console.log("      'constructor(address,address,address)' <usdc> <identity> <validation>)");
        console.log("");
        console.log("The compiler settings must match the ones used here: solc 0.8.28,");
        console.log("optimizer on, 200 runs. See foundry.toml for why 200.");
    }

    /**
     * A 6-decimal check that fails closed on a wrong answer and on no answer.
     *
     * `decimals()` is not in the interface this contract uses, so it is called raw. If the
     * target answers and says anything other than 6, that is a different token and the
     * deployment stops: every cap, threshold and window budget in this system is a 6-decimal
     * `uint96`, and against an 18-decimal token a 100 USDC per-transaction cap would be a
     * hundred-millionth of a token.
     *
     * SILENCE USED TO BE ACCEPTED, AND IS NOT ANY MORE. The old reasoning was that Arc's USDC
     * sits at a fixed address rather than being deployed as an ordinary contract, and that its
     * behaviour from here had never been measured, so demanding an answer might block a correct
     * deployment for the wrong reason. `evidence/arc-probe.log` settles it the other way: run
     * against live Arc Testnet, the pinned address answered `decimals()` with 6 and `symbol()`
     * with "USDC". A demand that the live chain already satisfies cannot block the deployment
     * this file exists for, and Arc's own integration guidance is to always call `decimals()`.
     * On any other chain, a USDC that will not name its own precision is the case to refuse.
     *
     * A CODE-LENGTH CHECK ON USDC IS DECLINED, and the asymmetry with `_checkRegistries` is a
     * deliberate one. The probe measured what the token answers, not how much code backs it.
     * Arc's USDC is precompile-backed, so it may well report a zero-length `code` while working
     * perfectly, and a check that reads `usdc_.code.length` could refuse the one deployment
     * this file is written for. The registries are ordinary contracts and the same probe
     * measured 263 hex characters of code at each, so there the check is grounded.
     */
    function _checkDecimals(address usdc_) internal view {
        (bool ok, bytes memory ret) = usdc_.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length != 32) revert DecimalsUnavailable();
        uint256 d = abi.decode(ret, (uint256));
        if (d != 6) revert UnexpectedDecimals(d);
        console.log("usdc decimals    6, as expected");
    }

    /**
     * A non-zero registry must hold code, because the contract's denial depends on it.
     *
     * Zero is a configuration: it disables the ERC-8004 gate that reads it, and the
     * constructor accepts it on purpose. Non-zero and codeless is the mistake, and the
     * failure it produces is quiet. `_checkIdentity` wraps `ownerOf` in `try`/`catch` and
     * documents the catch as producing a legible denial; a `STATICCALL` to a codeless address
     * succeeds and returns nothing, so the ABI decode of the success branch fails in the
     * caller's own frame, where that `catch` cannot reach it. The mandate then fails with
     * empty return data instead of `IdentityNotHeld`, which tells an operator nothing.
     *
     * Checked before the broadcast rather than after, because the point is not to deploy.
     */
    function _checkRegistries(address identity_, address validation_) internal view {
        if (identity_ != address(0) && identity_.code.length == 0) revert RegistryHasNoCode(identity_);
        if (validation_ != address(0) && validation_.code.length == 0) revert RegistryHasNoCode(validation_);
        console.log("registries       non-zero addresses hold code");
    }

    /**
     * No two arguments may name the same address.
     *
     * Nothing in the constructor requires the three to differ, and one of the collisions does
     * harm without looking wrong. `_isUndebitable` refuses four recipients — this contract, the
     * token, and both registries — so passing the same address twice collapses four entries
     * into three and widens the set of recipients a spend will accept, with no error anywhere
     * to say so. Two zero registries are the exception and stay legal, since zero means the
     * check is off and both may be off at once.
     */
    function _checkDistinct(address usdc_, address identity_, address validation_) internal pure {
        if (usdc_ == identity_) revert DuplicateArgument(usdc_);
        if (usdc_ == validation_) revert DuplicateArgument(usdc_);
        if (identity_ == validation_ && identity_ != address(0)) revert DuplicateArgument(identity_);
    }
}
