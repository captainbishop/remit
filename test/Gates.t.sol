// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";

/**
 * The ERC-8004 gates: does the spender still hold the agent identity the payer
 * delegated to, and does a named validator still vouch for it?
 *
 * Both gates are read at SPEND time, not at grant time. That is the entire value:
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

        // And the new owner cannot use it either — they are not the named spender.
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

    /// `expectedOwner` pins the identity to a specific address on top of requiring
    /// the caller to hold it. This is the case where the caller DOES hold the token
    /// but the payer named someone else — a distinct error, because it means the
    /// mandate's assumptions changed rather than that the agent lost its key.
    function test_identityGate_expectedOwnerMismatch_reportsIdentityTransferred() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, boss));
        // agent holds #42 and is the named spender, but the payer pinned boss.
        payReverts(id, usd(10), MandateManager.IdentityTransferred.selector);
    }

    /// expectedOwner = address(0) means "do not pin" — only require that the caller
    /// holds the identity. This is the common configuration and must not accidentally
    /// behave as "pinned to the zero address", which would deny everything.
    function test_identityGate_unpinnedExpectedOwner_onlyRequiresTheCallerToHoldIt() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, address(0)));
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    // ================================================ credential gate

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

    /// A FAILED attestation is not a missing one, but it must be just as fatal.
    /// ERC-8004 encodes failure as a low response value, so a gate that checked only
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
        // the point of reading the gate at spend time.
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
     * DOCUMENTED SEMANTICS: maxStaleness == 0 means "no freshness requirement".
     *
     * This is a real encoding hazard. Zero is the natural default a caller leaves in
     * a struct they did not think about, and it selects the MOST permissive setting.
     * The alternative reading — "must be attested this exact second" — would be
     * unusable, so the permissive one is right, but it means a payer who forgets the
     * field gets a gate that never expires. The README says so, and this test makes
     * the choice explicit so nobody "fixes" it by accident.
     *
     * reference/policy.js currently encodes zero the other way. The model is wrong;
     * the contract is right.
     */
    function test_credentialGate_zeroMaxStaleness_meansNoFreshnessRequirement() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 0));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);

        vm.warp(block.timestamp + 3650 days);
        pay(id, usd(10)); // a decade-old attestation still passes
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /**
     * ATTACK: forge the attestation by choosing a cooperative validator.
     *
     * `getValidationStatus` is keyed on requestHash ALONE. Anyone can file an
     * attestation under any hash they like, so a gate that read only `response`
     * would be satisfied by an attacker attesting to their own agent's compliance.
     * The gate therefore checks WHO answered against the validator the payer named.
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
     * right validator, the response is a genuine pass, the timestamp is fresh. It is
     * simply an attestation about somebody else. Since the lookup key carries no
     * agent, only comparing the returned agentId catches this.
     */
    function test_ATTACK_realAttestationAboutADifferentAgent_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongAgent.selector);
    }

    /// The credential gate can name its own agentId, or fall back to the identity
    /// gate's when it does not. This is the fallback path.
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
     * entirely. The gate then means only "the named validator has filed a passing,
     * fresh attestation under this exact requestHash" — which is weaker than a
     * reader of the config would assume.
     *
     * What still bounds it, and why createMandate accepts it anyway:
     * `requestHash` is fixed by the PAYER at grant time and is not chosen by the
     * caller, so an attacker cannot redirect the gate at an attestation of their
     * choosing — unlike the first, broken version of this gate, where the key was
     * caller-supplied. And F_CREDENTIAL without a validator is refused at grant
     * time, so the attestation must come from the validator the payer named.
     *
     * The residual exposure is therefore not an attack but a mistake: a payer who
     * pins a requestHash that turns out to attest a DIFFERENT agent gets no warning,
     * and the gate passes on the strength of somebody else's good behaviour. Zero is
     * the default value of a struct field, so this is reachable by omission.
     *
     * Reverting at grant time was considered and rejected as over-strict: an
     * attestation about a request rather than about an agent is a legitimate shape.
     * But the weakening is real, so it is asserted here and caveated in DESIGN.md.
     * If this test ever fails because the contract grew stricter, that is progress.
     */
    function test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent() public {
        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, 0, 1 days); // no agentId, and no identity gate
        bytes32 id = grant(p);

        // An attestation by the right validator, under the right hash, about an
        // agent nobody named. It passes, because there is nothing to compare to.
        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "known weakening: see DESIGN.md");

        // The validator identity is still enforced, which is what keeps this bounded.
        validation.setStatus(KYC_HASH, other, 999, 100, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialWrongValidator.selector);
    }

    // ================================================= both gates together

    /// The gates are independent and both must pass. Belt and braces is the point:
    /// identity answers "is this still the agent I chose", credentials answer "is it
    /// still allowed to act". Neither implies the other.
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

    /// Gates are checked AFTER the cheap structural checks and BEFORE the caps, so a
    /// spend that is both over the cap and ungated reports the gate failure. The
    /// ordering is deliberate: an agent that has lost its credential should be told
    /// that, not told to try a smaller amount.
    function test_gates_areCheckedBeforeTheCaps() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        payReverts(id, usd(5000), MandateManager.CredentialMissing.selector);
    }
}
