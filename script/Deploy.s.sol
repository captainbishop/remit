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
 * Before deploying, that the chain is one this file knows, and that whatever sits at
 * the pinned USDC address reports 6 decimals if it answers `decimals()` at all. Every
 * amount in this system is a 6-decimal `uint96`; against an 18-decimal token the same
 * numbers mean a millionth of the intended cap.
 *
 * After deploying, that the contract has code, and that all three immutables read back
 * as the addresses that went in. That last check is the point of the file. Constructor
 * arguments are ABI-encoded positionally, three addresses in a row, and nothing in
 * `forge create` or in a block explorer will tell you they went in the wrong order.
 * Reading them back does.
 *
 * The registries are allowed to be zero and the constructor accepts that; only USDC is
 * refused at zero. A zero registry disables the ERC-8004 credential check rather than
 * breaking it, which is why it is a configuration and not a mistake.
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
     */
    function runWith(address usdc_, address identity_, address validation_) external returns (MandateManager mm) {
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

        vm.startBroadcast();
        mm = new MandateManager(usdc_, identity_, validation_);
        vm.stopBroadcast();

        console.log("MandateManager  ", address(mm));

        // These four checks run in the dry run too, because `forge script` executes the
        // constructor against a fork whether or not `--broadcast` is passed. That is what
        // makes the dry run worth doing: an argument order mistake is caught before any
        // transaction is signed, on a chain state identical to the real one.
        if (address(mm).code.length == 0) revert EmptyDeployment();

        if (address(mm.usdc()) != usdc_) revert WiringMismatch();
        if (address(mm.identityRegistry()) != identity_) revert WiringMismatch();
        if (address(mm.validationRegistry()) != validation_) revert WiringMismatch();

        console.log("runtime bytes   ", address(mm).code.length);
        console.logBytes32(mm.DOMAIN());
        console.log("^ DOMAIN, which must equal keccak256(\"Remit:v1\")");
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
     * A 6-decimal check that fails closed on a wrong answer and stays quiet on no
     * answer.
     *
     * `decimals()` is not in the interface this contract uses, so it is called raw. If
     * the target answers and says anything other than 6, that is a different token and
     * the deployment stops: every cap, threshold and window budget in this system is a
     * 6-decimal `uint96`, and against an 18-decimal token a 100 USDC per-transaction cap
     * would be a hundred-millionth of a token.
     *
     * If the call fails or returns nothing, the run continues with a warning. Arc's USDC
     * is exposed at a fixed address rather than deployed as an ordinary contract, and
     * its code length has never been measured from here, so a hard requirement on an
     * answer could block a correct deployment for the wrong reason. The chain-id pin
     * above is what actually prevents the catastrophic mistake; this is a second look.
     */
    function _checkDecimals(address usdc_) internal view {
        (bool ok, bytes memory ret) = usdc_.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && ret.length == 32) {
            uint256 d = abi.decode(ret, (uint256));
            if (d != 6) revert UnexpectedDecimals(d);
            console.log("usdc decimals    6, as expected");
        } else {
            console.log("WARNING: the USDC address did not answer decimals(). Verify it by hand.");
        }
    }
}
