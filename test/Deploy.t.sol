// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SilentRegistry} from "./mocks/MockRegistries.sol";

/**
 * script/Deploy.s.sol, exercised.
 *
 * WHY THIS FILE EXISTS. `forge coverage` put the deploy script at 0.00% on all four
 * columns — 0 of 59 lines, 0 of 82 statements, 0 of 17 branches, 0 of 6 functions. Nothing
 * in the repository ran it, so every check it makes before a deployment stood unexercised:
 * the chain-id pin, the six-decimal probe, the code test on each registry, the distinctness
 * test across the three arguments, and the read-backs afterwards. The script holds no funds
 * and a defect in it costs no gas. It is also the last code that runs before three addresses
 * become `immutable` in a contract with no upgrade path, which is the argument for exercising
 * it rather than dropping `script/` from the coverage denominator.
 *
 * WHAT IS REACHABLE AND WHAT IS NOT. Five of the script's seven errors can be raised from a
 * test through `runWith`, and the cases below raise each one. The other two cannot be, and
 * the reasons differ.
 *
 * `EmptyDeployment` needs `new MandateManager(...)` to yield an address holding no code. A
 * failed CREATE reverts the whole frame instead, so no input reaches that revert.
 *
 * `WiringMismatch` needs an immutable to read back as something other than what the
 * constructor stored. Inside `_deploy` both sides of each comparison come from the same three
 * locals; in `run()` the right-hand side is a constant that the call site one line above
 * passed in unchanged. Neither can fail while the source is correct, so both are tripwires
 * against a later edit rather than runtime checks. `TransposedRun` below makes the edit they
 * exist for, which is how the corrected comparison is shown to work rather than assumed to.
 *
 * HOW THE PINNED CHAIN IS REACHED. `run()` refuses every chain id except Arc Testnet and
 * reads three fixed addresses, none of which hold code in a fresh EVM. `_pinArcTestnet` sets
 * the chain id with `vm.chainId` and copies the three mocks' runtime code onto the pinned
 * addresses with `vm.etch`. The three constants are re-declared here rather than read out of
 * the script, for the reason `Base` re-declares the flag constants: a test that reads the
 * value it is checking cannot fail when that value changes. Editing an address in the script
 * now breaks this file, which is the second pin those addresses were missing.
 */

/// Answers `decimals()` with 18, which is the wrong token wearing the right interface.
/// Every amount in MandateManager is a 6-decimal `uint96`, so against this one a cap of
/// 100 USDC would authorise a hundred-millionth of a token.
contract Token18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/**
 * `Deploy.run()` with the two registry arguments swapped at the call site, in both the
 * uncorrected and the corrected shape.
 *
 * The script's own header records why the read-backs inside `_deploy` cannot see this
 * mistake: each one compares an immutable against the local the constructor was handed, so
 * both sides carry the same wrong address and the comparison holds. The correction was three
 * further comparisons in `run()`, against the pinned constants, which never travelled through
 * `_deploy`. Those three lines cannot fail while the call site above them is correct, so no
 * input to `run()` reaches them, and a green suite would say nothing about whether they work.
 *
 * Inheriting is what makes the reproduction run the script's real code. `_deploy` and the
 * three constants are `internal`, so a subclass reaches both, and the lines executed here are
 * the ones in script/Deploy.s.sol rather than a paraphrase of them.
 *
 * The identity and validation addresses are the pair to swap. Swapping USDC with either
 * registry is stopped earlier by the decimals probe, which has its own case below.
 */
contract TransposedRun is Deploy {
    /// The uncorrected shape: `_deploy` alone, which reports success on a backwards wiring.
    function runUnchecked() external returns (MandateManager mm) {
        mm = _deploy(ARC_TESTNET_USDC, ARC_TESTNET_VALIDATION, ARC_TESTNET_IDENTITY);
    }

    /// The corrected shape: the same swap, then the three comparisons `run()` makes against
    /// the constants. Copied by hand, so a change to those three lines has to be made twice.
    function runChecked() external returns (MandateManager mm) {
        mm = _deploy(ARC_TESTNET_USDC, ARC_TESTNET_VALIDATION, ARC_TESTNET_IDENTITY);
        if (address(mm.usdc()) != ARC_TESTNET_USDC) revert WiringMismatch();
        if (address(mm.identityRegistry()) != ARC_TESTNET_IDENTITY) revert WiringMismatch();
        if (address(mm.validationRegistry()) != ARC_TESTNET_VALIDATION) revert WiringMismatch();
    }
}

contract DeployTest is Base {
    /// Mirrors of the four values script/Deploy.s.sol pins, re-declared rather than read out
    /// of it. See this file's header for why they are copied.
    uint256 internal constant ARC_TESTNET = 5042002;
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_IDENTITY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address internal constant ARC_VALIDATION = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;

    Deploy internal script;

    /// An address holding no code, for the cases where the script has to refuse one.
    address internal codeless;

    function setUp() public override {
        super.setUp();
        script = new Deploy();
        codeless = makeAddr("codeless");
    }

    /// Puts Arc Testnet under the script: the pinned chain id, and code at each of the three
    /// pinned addresses. The code is copied from the mocks `Base` already deployed, so the
    /// etched USDC answers `decimals()` with 6 through MockUSDC's own constant. The four
    /// assertions catch a harness that stopped working, which would otherwise show up as a
    /// test passing for the wrong reason.
    function _pinArcTestnet() internal {
        vm.etch(ARC_USDC, address(token).code);
        vm.etch(ARC_IDENTITY, address(identity).code);
        vm.etch(ARC_VALIDATION, address(validation).code);
        vm.chainId(ARC_TESTNET);

        assertGt(ARC_USDC.code.length, 0, "harness: the pinned USDC address holds no code");
        assertGt(ARC_IDENTITY.code.length, 0, "harness: the pinned identity registry holds no code");
        assertGt(ARC_VALIDATION.code.length, 0, "harness: the pinned validation registry holds no code");
        assertEq(block.chainid, ARC_TESTNET, "harness: the chain id did not take");
    }

    // ---------------------------------------------------------- the chain-id pin

    /// Nothing is etched and the chain id is left alone, so the refusal has to come from the
    /// chain check rather than from a later one.
    function test_run_refusesAChainWithNoPinnedArguments() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnknownChain.selector, block.chainid));
        script.run();
    }

    /// One digit either side of the pinned id, which is what a typo in an RPC or a fork of the
    /// wrong network looks like.
    function test_run_refusesAChainIdOneAwayFromArcTestnet() public {
        _pinArcTestnet();

        vm.chainId(ARC_TESTNET - 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnknownChain.selector, ARC_TESTNET - 1));
        script.run();

        vm.chainId(ARC_TESTNET + 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnknownChain.selector, ARC_TESTNET + 1));
        script.run();
    }

    /// `runWith` takes its three addresses from the caller, and it refuses the one chain the
    /// script pins for itself, so Arc Testnet can only be deployed to through the checked
    /// path. The error name reads backwards on this branch — the chain is refused for being
    /// the known one — and the script's own comment covers that.
    function test_runWith_refusesTheChainThatRunAlreadyPins() public {
        _pinArcTestnet();
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnknownChain.selector, ARC_TESTNET));
        script.runWith(address(token), address(identity), address(validation));
    }

    // --------------------------------------------------------------- the wiring

    /// The whole point of the script, asserted against the copied literals rather than against
    /// anything the script returns about itself.
    function test_run_wiresTheThreePinnedAddresses() public {
        _pinArcTestnet();
        MandateManager deployed = script.run();

        assertGt(address(deployed).code.length, 0, "the deployment holds no code");
        assertEq(address(deployed.usdc()), ARC_USDC, "usdc");
        assertEq(address(deployed.identityRegistry()), ARC_IDENTITY, "identityRegistry");
        assertEq(address(deployed.validationRegistry()), ARC_VALIDATION, "validationRegistry");
        assertEq(deployed.DOMAIN(), keccak256("Remit:v1"), "DOMAIN, which every stored mandate id is built from");
    }

    function test_runWith_deploysWithTheArgumentsGiven() public {
        MandateManager deployed = script.runWith(address(token), address(identity), address(validation));

        assertEq(address(deployed.usdc()), address(token), "usdc");
        assertEq(address(deployed.identityRegistry()), address(identity), "identityRegistry");
        assertEq(address(deployed.validationRegistry()), address(validation), "validationRegistry");
    }

    // ------------------------------------------------------- the six-decimal probe

    /// The token that would do the most damage while looking correct: right interface, wrong
    /// scale. A cap meant as 100 USDC would authorise 0.0000000001 of this one.
    function test_runWith_refusesATokenReportingEighteenDecimals() public {
        address wrong = address(new Token18());
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedDecimals.selector, uint256(18)));
        script.runWith(wrong, address(0), address(0));
    }

    /// The staticcall failing outright, which is the `!ok` half of the probe. An ERC-721
    /// registry has no `decimals()` and no fallback, so the call reverts.
    function test_runWith_refusesATokenThatRevertsOnDecimals() public {
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.runWith(address(identity), address(0), address(0));
    }

    /// The staticcall succeeding with nothing to decode, which is the `ret.length != 32` half.
    /// `SilentRegistry` holds code and answers every selector with zero bytes.
    function test_runWith_refusesATokenThatAnswersWithNothing() public {
        address silent = address(new SilentRegistry());
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.runWith(silent, address(0), address(0));
    }

    /// An address holding no code reaches the same refusal by a third route: a staticcall to
    /// an empty account succeeds and returns nothing.
    function test_runWith_refusesAnAddressWithNoCodeAsUsdc() public {
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.runWith(codeless, address(0), address(0));
    }

    /// The constructor refuses a zero USDC with `BadConfig`, and the script refuses it one
    /// step earlier, so a deployer sees `DecimalsUnavailable`. Two independent refusals.
    function test_runWith_refusesZeroUsdcBeforeTheConstructorDoes() public {
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.runWith(address(0), address(0), address(0));
    }

    /// The pinned chain id with nothing at the pinned USDC address, which is what pointing the
    /// script at the wrong endpoint looks like. `run()` probes its constant rather than
    /// trusting it.
    function test_run_probesThePinnedUsdcRatherThanTrustingIt() public {
        vm.chainId(ARC_TESTNET);
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.run();
    }

    // ------------------------------------------------------------ the registries

    function test_runWith_refusesANonZeroIdentityRegistryHoldingNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.RegistryHasNoCode.selector, codeless));
        script.runWith(address(token), codeless, address(validation));
    }

    function test_runWith_refusesANonZeroValidationRegistryHoldingNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.RegistryHasNoCode.selector, codeless));
        script.runWith(address(token), address(identity), codeless);
    }

    /// `run()` applies the same check to its own constants, so the two ERC-8004 addresses are
    /// tested for code on the live chain rather than assumed to hold it.
    function test_run_refusesPinnedRegistriesHoldingNoCode() public {
        vm.etch(ARC_USDC, address(token).code);
        vm.chainId(ARC_TESTNET);

        vm.expectRevert(abi.encodeWithSelector(Deploy.RegistryHasNoCode.selector, ARC_IDENTITY));
        script.run();
    }

    /// Zero turns off the lookup that reads the registry, which the constructor accepts by
    /// design, so the script reads a pair of zeros as configuration and not as a mistake.
    /// This also takes the `identity_ != address(0)` branch in the distinctness check, where
    /// two zeros are the one repeat allowed.
    function test_runWith_acceptsBothRegistriesAtZero() public {
        MandateManager deployed = script.runWith(address(token), address(0), address(0));

        assertEq(address(deployed.usdc()), address(token), "usdc");
        assertEq(address(deployed.identityRegistry()), address(0), "identityRegistry");
        assertEq(address(deployed.validationRegistry()), address(0), "validationRegistry");
    }

    // ------------------------------------------------------ no repeated argument

    function test_runWith_refusesUsdcRepeatedAsTheIdentityRegistry() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.DuplicateArgument.selector, address(token)));
        script.runWith(address(token), address(token), address(validation));
    }

    function test_runWith_refusesUsdcRepeatedAsTheValidationRegistry() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.DuplicateArgument.selector, address(token)));
        script.runWith(address(token), address(identity), address(token));
    }

    /// One registry in both positions would collapse two of the four addresses a spend refuses
    /// as a recipient into one, which widens the set of recipients the contract accepts.
    function test_runWith_refusesOneRegistryInBothPositions() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.DuplicateArgument.selector, address(identity)));
        script.runWith(address(token), address(identity), address(identity));
    }

    // ------------------------------------------------------ a transposed argument

    /// Swapping USDC with the identity registry is stopped by the decimals probe, before the
    /// broadcast and before any read-back, because an ERC-721 registry has no `decimals()`.
    function test_runWith_ATTACK_usdcAndIdentityTransposed_stopsAtTheDecimalsProbe() public {
        vm.expectRevert(Deploy.DecimalsUnavailable.selector);
        script.runWith(address(identity), address(token), address(validation));
    }

    /// Swapping the two registries produces a deployment that reports success and is wired
    /// backwards. Both hold code, both differ from USDC and from each other, and the token
    /// still answers 6, so every check ahead of the broadcast passes. This is the mistake the
    /// read-backs inside `_deploy` cannot see, shown here against `runWith` where the caller
    /// supplies the order.
    function test_runWith_ATTACK_theTwoRegistriesTransposed_deploysWiredBackwards() public {
        MandateManager deployed = script.runWith(address(token), address(validation), address(identity));

        assertEq(address(deployed.identityRegistry()), address(validation), "backwards, and accepted");
        assertEq(address(deployed.validationRegistry()), address(identity), "backwards, and accepted");
    }

    /// The uncorrected shape of `run()`: `_deploy` alone, with the two registries swapped at
    /// the call site. Every read-back inside it passes, because each compares an immutable
    /// against the same local the constructor was handed.
    function test_REGRESSION_aTransposedCallSiteSurvivesTheSelfComparingReadBack() public {
        _pinArcTestnet();
        TransposedRun twin = new TransposedRun();

        MandateManager deployed = twin.runUnchecked();

        assertEq(address(deployed.identityRegistry()), ARC_VALIDATION, "the swap reached the immutable");
        assertEq(address(deployed.validationRegistry()), ARC_IDENTITY, "the swap reached the immutable");
    }

    /// The corrected shape: the same call site, plus the three comparisons against the pinned
    /// constants. `run()` cannot reach this revert while its own call site is right, so the
    /// twin is what shows those three lines refuse the mistake they were added for.
    function test_REGRESSION_theSameTransposedCallSiteIsCaughtByThePinnedConstants() public {
        _pinArcTestnet();
        TransposedRun twin = new TransposedRun();

        vm.expectRevert(Deploy.WiringMismatch.selector);
        twin.runChecked();
    }
}
