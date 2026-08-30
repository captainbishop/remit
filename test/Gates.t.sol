// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The two ERC-8004 checks: does the spender still hold the agent identity the payer
 * delegated to, and does a named validator still vouch for it?
 *
 * Both checks are read at SPEND time, not at grant time. That is the entire value:
 * a mandate granted to an agent whose compliance attestation later lapses stops
 * working without the payer having to notice. The cost is two external calls per
 * spend, and an external call to a registry that can revert — so both are wrapped
 * in try/catch and both failure modes are tested rather than assumed.
 */
contract GatesTest is Base {
    // ================================================== identity gate

    function test_identityGate_passesWhileTheSpenderHoldsTheIdentity() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /**
     * ATTACK: sell the agent identity.
     *
     * ERC-8004 identities are transferable ERC-721s. An operator who has a mandate
     * pointed at agent #42 can transfer #42 to a buyer — and if the gate only asked
     * "does #42 exist", the buyer would inherit the payer's money. The gate asks
     * whether the CALLER owns it, so the mandate dies the moment the identity moves.
     */
    function test_ATTACK_transferringTheAgentIdentity_killsTheMandate() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        pay(id, usd(10)); // works while agent holds it

        identity.transferAgent(AGENT_ID, other);
        payReverts(id, usd(10), MandateManager.IdentityNotHeld.selector);

        // The new owner cannot use it either, having never been the named spender.
        bytes32 nonce = nextNonce();
        vm.prank(other);
        vm.expectRevert(MandateManager.WrongSpender.selector);
        mm.spend(id, vendor, usd(10), REF, nonce);
    }

    /**
     * A burned identity must produce a legible denial, not an opaque bubbled revert.
     *
     * ERC-721 `ownerOf` REVERTS for a nonexistent token rather than returning the
     * zero address. Without the try/catch an agent sees `ERC721NonexistentToken`
     * from a contract it has never heard of and cannot tell a burned identity from a
     * broken registry.
     */
    function test_identityGate_burnedIdentity_deniesLegibly() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        identity.burn(AGENT_ID);
        payReverts(id, usd(10), MandateManager.IdentityNotHeld.selector);
    }

    /// CHANGED IN v2 (F33). This test used to grant a mandate pinning `expectedOwner` to `boss`
    /// while naming `agent` as the spender, and assert that the spend reverted
    /// `IdentityTransferred`. Every word of that was true and the test was still endorsing a
    /// bug: `_checkIdentity` requires `ownerOf(agentId) == msg.sender` and `spend` requires
    /// `msg.sender == m.spender`, so a pin at anyone other than the spender reverts on EVERY
    /// spend, for the life of the mandate. The mandate was bricked rather than protected, and
    /// the payer had no way to tell those apart from the error.
    ///
    /// `createMandate` now refuses the configuration instead, which is the only moment at which
    /// the payer can still fix it. `IdentityTransferred` is unreachable as a consequence — the
    /// check stays in `_checkIdentity` because unreachable code that can only ever REFUSE a
    /// payment is the safe direction for dead code, and the error declaration says so.
    function test_identityGate_expectedOwnerNotTheSpender_isRefusedAtGrantTime() public {
        grantReverts(withIdentity(simpleParams(), AGENT_ID, boss), MandateManager.BadConfig.selector);
    }

    /// The pin is still expressible when it names the spender, which is the only address it
    /// could ever have named without bricking the grant.
    function test_identityGate_expectedOwnerIsTheSpender_isAccepted() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// The other half of F33's disposition. `IdentityTransferred` is unreachable through the
    /// public interface, and this shows the branch behind it still refuses a payment rather
    /// than passing one.
    ///
    /// Three guards, each with its own test, make the state impossible to reach by calling the
    /// contract. `createMandate` refuses an `expectedOwner` that is neither zero nor the spender
    /// (the test two above this one), `spend` refuses any caller other than the spender
    /// (`Bounds.t.sol`, and the tail of the transfer attack further up), and `_checkIdentity`
    /// refuses unless the caller owns the identity — so by the time the pin is compared it can
    /// only agree with a test that has just passed. Nothing writes `_identity` after the grant.
    ///
    /// The state is therefore reached here by writing storage directly, which earns its keep
    /// twice over. The error declaration claims this dead code "can only ever REFUSE a payment",
    /// a claim about behaviour that nothing was checking. The mutation gate cannot see line
    /// 1229 without it either: deleting that `revert` left all 206 other tests passing, because
    /// none of them can make the condition true.
    ///
    /// The slot is derived and then verified before anything is written to it. The nine mappings
    /// take slots 0 through 8 in declaration order, `_identity` is the fourth, so one mandate's
    /// struct starts at `keccak256(abi.encode(mandateId, 3))` with `agentId` in that word and
    /// `expectedOwner` in the next. Both are read back and checked against values this test
    /// already knows, so a later change to the layout fails here with a message rather than
    /// overwriting some other mandate's window with no error at all.
    function test_f33_forcingTheUnreachablePin_stillRefusesTheSpend() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "the legal pin spends");

        bytes32 base = keccak256(abi.encode(id, uint256(3)));
        assertEq(uint256(vm.load(address(mm), base)), AGENT_ID, "slot 3 is no longer _identity");
        bytes32 pin = bytes32(uint256(base) + 1);
        assertEq(address(uint160(uint256(vm.load(address(mm), pin)))), agent, "expectedOwner moved");

        vm.store(address(mm), pin, bytes32(uint256(uint160(other))));

        payReverts(id, usd(10), MandateManager.IdentityTransferred.selector);
        assertEq(token.balanceOf(vendor), usd(10), "and nothing further moved");
    }

    /// F33. Agent id zero is not registrable under ERC-8004, so `ownerOf(0)` can only answer
    /// with the zero address or revert, and both land on `IdentityNotHeld` forever.
    function test_identityGate_zeroAgentId_isRefusedAtGrantTime() public {
        grantReverts(withIdentity(simpleParams(), 0, address(0)), MandateManager.BadConfig.selector);
    }

    /// expectedOwner = address(0) means "do not pin" — only require that the caller
    /// holds the identity. This is the common configuration and must not accidentally
    /// behave as "pinned to the zero address", which would deny everything.
    function test_identityGate_unpinnedExpectedOwner_onlyRequiresTheCallerToHoldIt() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, address(0)));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    // =============================================== credential check

    function test_credentialGate_passesWithAFreshAttestation() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    function test_credentialGate_missingAttestation_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    /// Whether the real registry reverts or returns a zero tuple for an unknown hash
    /// has not been verified against a deployed contract, so both behaviours must
    /// deny. The try/catch covers one; the `gotValidator == address(0)` check the other.
    function test_credentialGate_revertingRegistry_alsoDenies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        validation.setRevertOnUnknown(true);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    /// A FAILED attestation differs from a missing one and must be just as fatal.
    /// ERC-8004 encodes failure as a low response value, so a check that looked only
    /// for presence would treat "this agent failed KYC" as authorisation.
    function test_credentialGate_failingAttestation_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 0, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    function test_credentialGate_staleAttestation_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        pay(id, usd(10)); // fresh: attested 100s ago

        vm.warp(block.timestamp + 1 days + 1);
        payReverts(id, usd(10), MandateManager.CredentialStale.selector);

        // Re-attesting revives the mandate with no action from the payer. That is
        // the point of reading the credential at spend time.
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(20));
    }

    /// The staleness boundary is inclusive: exactly maxStaleness old still passes,
    /// one second more does not.
    function test_credentialGate_stalenessBoundaryIsInclusive() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        uint256 attestedAt = block.timestamp;
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, attestedAt);

        vm.warp(attestedAt + 1 days);
        pay(id, usd(10));

        vm.warp(attestedAt + 1 days + 1);
        payReverts(id, usd(10), MandateManager.CredentialStale.selector);
    }

    /**
     * F31. A future-dated attestation used to be fresh forever.
     *
     * The old condition was `nowTs > lastUpdate && nowTs - lastUpdate > maxStaleness`.
     * The first conjunct was there to stop an unsigned subtraction underflowing, and it did,
     * by skipping the whole freshness test whenever `lastUpdate` was ahead of the chain clock.
     * `maxStaleness` therefore applied to every attestation except the one class that cannot
     * be honest about its own age: a validator stamping a time in the future, once, bought a
     * credential that never expired.
     *
     * A registry with a fast clock produces this by accident, which is why it is a finding and
     * not a story about a malicious validator.
     *
     * The state is staged in one `setStatus` call, and this test is also the fifth of the five
     * that THREAT-MODEL.md section 5 owes.
     */
    function test_f31_aFutureDatedAttestationIsRefusedRatherThanFreshForever() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp + 365 days);

        payReverts(id, usd(10), MandateManager.CredentialStale.selector);

        // It stays refused for as long as the stamp is ahead of the clock, then behaves
        // ordinarily once the clock catches up — the guard is about an unknowable age, not a
        // permanent blacklisting of the attestation.
        vm.warp(block.timestamp + 364 days);
        payReverts(id, usd(10), MandateManager.CredentialStale.selector);

        vm.warp(block.timestamp + 1 days);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// The underflow the old conjunct was guarding against is still impossible, which is the one
    /// thing the fix must not lose. `lastUpdate` one second ahead of the clock takes the first
    /// leg and never reaches the subtraction.
    function test_f31_theSubtractionStillCannotUnderflow() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp + 1);
        payReverts(id, usd(10), MandateManager.CredentialStale.selector);
    }

    /// An attestation stamped at exactly the current block is fresh, so the new first leg is a
    /// strict `>` and does not refuse the ordinary case.
    function test_f31_anAttestationStampedThisBlockIsFresh() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /**
     * DOCUMENTED SEMANTICS: maxStaleness == 0 means "no freshness requirement".
     *
     * This is a real encoding hazard. Zero is the natural default a caller leaves in
     * a struct they did not think about, and it selects the MOST permissive setting.
     * The alternative reading — "must be attested this exact second" — would be
     * unusable, so the permissive one is right, but it means a payer who forgets the
     * field gets a check that never expires. The README says so, and this test makes
     * the choice explicit so no maintainer "fixes" it by accident.
     *
     * reference/policy.js reads zero the same way, at `staleAfter > 0n`, and has since
     * the root commit. An earlier version of this line said the model was wrong.
     */
    function test_credentialGate_zeroMaxStaleness_meansNoFreshnessRequirement() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);

        vm.warp(block.timestamp + 3650 days);
        pay(id, usd(10)); // a decade-old attestation still passes
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// The zero case and F31's refusal meet here, in a cell neither side of the repo covered:
    /// `maxStaleness == 0` with a stamp dated in the future spends, because both legs of the
    /// staleness guard sit under `maxStaleness != 0`. A payer who declined an age bound gets no
    /// age check at all, including the fail-closed one. The model asserts the same thing in the
    /// closing lines of `credential gate (F31)` in reference/policy.test.js.
    function test_credentialGate_zeroMaxStaleness_acceptsAFutureDatedStamp() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp + 365 days);

        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /**
     * ATTACK: forge the attestation by choosing a cooperative validator.
     *
     * `getValidationStatus` is keyed on requestHash ALONE. Anyone can file an
     * attestation under any hash they like, so a check that read only `response`
     * would be satisfied by an attacker attesting to their own agent's compliance.
     * The credential check therefore compares WHO answered against the validator
     * the payer named.
     */
    function test_ATTACK_attestationFromAnUnnamedValidator_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        // `other` files a perfectly well-formed, passing, fresh attestation.
        validation.setStatus(KYC_HASH, other, AGENT_ID, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongValidator.selector);
    }

    /**
     * ATTACK: point at a real attestation about a DIFFERENT agent.
     *
     * Subtler than the last one, because nothing is forged: the validator is the
     * right validator, the response is a real pass, and the timestamp is fresh. It is
     * simply an attestation about a different agent. Since the lookup key carries no
     * agent, only comparing the returned agentId catches this.
     */
    function test_ATTACK_realAttestationAboutADifferentAgent_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongAgent.selector);
    }

    /// The credential check can name its own agentId, or fall back to the identity gate's
    /// when it does not, and this test takes the fallback path.
    function test_credentialGate_fallsBackToTheIdentityGatesAgentId() public {
        MandateManager.MandateParams memory p = withIdentity(simpleParams(), AGENT_ID, agent);
        p = withCredential(p, boss, KYC_HASH, 0, 1 days); // agentId 0 = inherit
        bytes32 id = grant(p);

        pay(id, usd(10)); // attestation is about AGENT_ID, which the identity gate names

        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongAgent.selector);
    }

    /**
     * DOCUMENTED GAP, pinned deliberately rather than fixed.
     *
     * With F_CREDENTIAL set, `credential.agentId == 0`, and NO identity gate, there
     * is no agent id to compare against, so the wrong-agent check is skipped
     * entirely. The credential check then means only "the named validator has filed
     * a passing, fresh attestation under this exact requestHash" — which is weaker
     * than a reader of the config would assume.
     *
     * What still bounds it, and why createMandate accepts it anyway:
     * `requestHash` is fixed by the PAYER at grant time and is not chosen by the
     * caller, so an attacker cannot redirect the check at an attestation of their
     * choosing — unlike the first, broken version of this check, where the key was
     * caller-supplied. F_CREDENTIAL without a validator is also refused at grant
     * time, so the attestation must come from the validator the payer named.
     *
     * The residual exposure is therefore a mistake rather than an attack: a payer who pins a
     * requestHash that turns out to attest a DIFFERENT agent gets no warning, and the check
     * passes on the strength of another agent's good behaviour. Zero is the default value of
     * a struct field, so this is reachable by omission.
     *
     * Reverting at grant time was considered and rejected as over-strict: an
     * attestation about a request rather than about an agent is a legitimate shape.
     * The weakening is real, so it is asserted here and caveated in DESIGN.md.
     * If this test ever fails because the contract grew stricter, that is progress.
     */
    function test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, 0, 1 days); // no agentId, and no identity gate
        bytes32 id = grant(p);

        // An attestation by the right validator, under the right hash, about an
        // agent the mandate never named. It passes, because there is nothing to compare to.
        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "known weakening: see DESIGN.md");

        // The validator identity is still enforced, which is what keeps this bounded.
        validation.setStatus(KYC_HASH, other, 999, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongValidator.selector);
    }

    // ================================================ both checks together

    /// The two checks are independent and both must pass, and the redundancy is the point:
    /// identity answers "is this still the agent the payer chose", credentials answer "is it
    /// still allowed to act", and neither implies the other.
    function test_bothGates_mustPassIndependently() public {
        MandateManager.MandateParams memory p = withIdentity(simpleParams(), AGENT_ID, agent);
        p = withCredential(p, boss, KYC_HASH, AGENT_ID, 1 days);
        bytes32 id = grant(p);
        pay(id, usd(10));

        // Credential fine, identity gone.
        identity.transferAgent(AGENT_ID, other);
        payReverts(id, usd(10), MandateManager.IdentityNotHeld.selector);
        identity.transferAgent(AGENT_ID, agent);

        // Identity fine, credential gone.
        validation.clear(KYC_HASH);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    /// Both checks run AFTER the cheap structural checks and BEFORE the caps, so a spend that
    /// is both over the cap and failing a check reports the check failure. The ordering is
    /// deliberate: an agent that has lost its credential should be told that rather than told
    /// to try a smaller amount.
    function test_gates_areCheckedBeforeTheCaps() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        payReverts(id, usd(5000), MandateManager.CredentialMissing.selector);
    }
}
