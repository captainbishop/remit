// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {MandateManager} from "../contracts/MandateManager.sol";
import {SilenceableRegistry, SilentRegistry} from "./mocks/MockRegistries.sol";

/**
 * The two ERC-8004 checks: does the spender still hold the agent identity the payer
 * delegated to, and does a named validator still vouch for it?
 *
 * Both checks are read at every SPEND, which is the entire value: a mandate granted to an
 * agent whose compliance attestation later lapses stops working without the payer having to
 * notice. Since F13 the grant validates each check's IDENTIFIERS as well, never its verdict;
 * the F13 section at the foot of this file asserts that division arm by arm. The cost is two
 * external calls per spend to registries that can revert, so both arms are wrapped and tested.
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
     * from a contract it has never heard of, and gets a denial it cannot act on.
     *
     * What the try/catch does NOT give is the ability to tell a burned identity from a
     * registry that failed for some other reason — this docstring claimed it did until
     * 2026-09-06. The test below asserts the confusion instead of denying it.
     */
    function test_identityGate_burnedIdentity_deniesLegibly() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        identity.burn(AGENT_ID);
        payReverts(id, usd(10), MandateManager.IdentityNotHeld.selector);
    }

    /**
     * The catch arm flattens every registry failure into one error, so a burned identity and a
     * broken registry are indistinguishable to the agent. Both denials are correct — a check
     * that cannot read the registry must refuse — and the cost is diagnosis: an agent told
     * `IdentityNotHeld` cannot tell whether to stop asking or to retry later, and a payer
     * reading the same error cannot tell whether their agent lost the identity or Arc's
     * registry is having a bad day.
     *
     * `RegistryUnavailable` is an error neither `MockRegistries` nor `MandateManager` mentions
     * anywhere else, and the identity is still held by the spender throughout, so the only way
     * this can produce `IdentityNotHeld` is the catch arm mapping an unrecognised failure onto
     * it. The registry is reachable at all here because it is upgradeable in production: the
     * live one sits behind an ERC-1967 proxy, so "answers differently than it did yesterday" is
     * a live shape rather than a hypothetical.
     */
    function test_identityGate_aBrokenRegistryIsIndistinguishableFromABurnedIdentity() public {
        bytes32 id = grant(withIdentity(simpleParams(), AGENT_ID, agent));
        pay(id, usd(10)); // healthy while the registry answers

        identity.setRevertOnOwnerOf(true);
        assertEq(identity.revertOnOwnerOf(), true, "the registry is now failing, not the identity");
        payReverts(id, usd(10), MandateManager.IdentityNotHeld.selector);

        // The identity never moved, so the denial was about the registry alone.
        identity.setRevertOnOwnerOf(false);
        assertEq(identity.ownerOf(AGENT_ID), agent, "still held by the spender the whole time");
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(20), "and it spends again once the registry answers");
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

    /// With the mock defaulting to Arc's measured shape, this is the reverting-registry path:
    /// the cleared hash is unknown, the registry fails the call, and `_checkCredential`'s catch
    /// arm turns that into `CredentialMissing`. Until 2026-09-06 the default was the other way
    /// round and this test took the zero-tuple path instead, which no measurement supports.
    function test_credentialGate_missingAttestation_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    /// Which shape the real registry uses for an unknown hash IS verified: three nonexistent
    /// hashes were queried on Arc Testnet on 2026-08-24 and all three reverted, recorded in
    /// `test/mocks/MockRegistries.sol` and in `evidence/registry.log`.
    /// The mock defaults to that arm, so `test_credentialGate_missingAttestation_denies`
    /// above already covers it,
    /// and this test carries the other shape — a registry that answers a zero tuple instead
    /// of failing. Both must deny, because the registries sit behind upgradeable proxies and
    /// today's answer is not permanently today's answer. The try/catch covers the reverting
    /// shape; the `gotValidator == address(0)` check covers this one.
    ///
    /// This docstring said the opposite until 2026-09-06, claiming the behaviour "has not been
    /// verified against a deployed contract" three weeks after the probe that verified it.
    function test_credentialGate_zeroTupleRegistry_alsoDenies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.clear(KYC_HASH);
        validation.setRevertOnUnknown(false);
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);
    }

    /// A FAILED attestation differs from a missing one and must be just as fatal.
    /// ERC-8004 encodes failure as a low response value, so a check that looked only
    /// for presence would treat "this agent failed KYC" as authorisation.
    ///
    /// The error names that difference as of F13. This test asserted `CredentialMissing`
    /// until then, which contradicted the line above it: the docstring claimed failure and
    /// absence were distinct while the assertion accepted the error for absence. `CredentialFailed`
    /// is the more precise expectation, and it is what makes the first sentence checkable.
    function test_credentialGate_failingAttestation_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 0, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialFailed.selector);
    }

    /**
     * The live registry's one real record, replayed: response 1 under the tag "verified".
     *
     * `evidence/registry.log` holds it, filed under `requestHash == bytes32(0)` on Arc Testnet —
     * validator 0xB152…681A, agent 16330, response 1, tag "verified", responseHash zero. Under the
     * ERC-8004 convention Arc's own tutorial states, 100 means passed, so a response of 1 is a
     * failure wearing a reassuring label. That is the shape `MockValidationRegistry`'s header
     * gives as its own reason for being, and no test could stage it until `setStatusFull`
     * landed, because `setStatus` hardcoded the tag to "compliance".
     *
     * The number decides and the label is never read. A check that trusted the tag would
     * authorise this spend; the gate refuses it, because 1 falls below the floor of 100.
     */
    function test_credentialGate_aReassuringTagOverAFailingScore_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatusFull(KYC_HASH, boss, AGENT_ID, 1, bytes32(0), "verified", block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialFailed.selector);
    }

    /**
     * `test_credentialGate_failingAttestation_denies` and the ordinary passing case leave
     * `response` at only 0 or 100, and on a two-point scale a floor cannot be told apart from a
     * presence check. All three of `response < c.minResponse`, `response != c.minResponse` and
     * `response == 0` agree on both points, so either of the last two could stand in for the real
     * one and the suite would stay green. `evidence/mutgate-sol-census-320.log:87` shows why the
     * census did not settle it: the run deleted the guard rather than changing its operator, and
     * a deleted guard is caught.
     *
     * A middling score is what separates the three. Here 60 falls short of a floor of 100 and has
     * to be refused, where a presence check would let it spend. The live record replayed just
     * above rules out `== 0` on its own, since 1 is not zero and still has to be refused, and it
     * arrived from a measurement rather than from choosing a number to make a point.
     */
    function test_credentialGate_aPartialScoreBelowTheFloor_denies() public {
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 60, block.timestamp);
        payReverts(id, usd(10), MandateManager.CredentialFailed.selector);
    }

    /// The other half of the same pair: a score above the payer's floor spends. An equality
    /// check would refuse it, while a payer who set a floor of 60 was asking for a floor, which
    /// admits every score above it. With the test above, the comparison at
    /// `MandateManager.sol:1683` is pinned as an ordering rather than as a match.
    function test_credentialGate_aScoreAboveTheFloor_spends() public {
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days);
        p.credential.minResponse = 60;
        bytes32 id = grant(p);

        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "a floor of 60 admits a 100");
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

    // ============================== F49: what try/catch covers, and what it does not

    /**
     * F49, and the reason the constructor now refuses a codeless registry.
     *
     * Every other test in this file relies on `catch` turning a registry failure into a legible
     * denial. `catch` runs when the CALL failed. A registry that answers successfully with data
     * that will not decode into the declared return type fails somewhere else entirely: the revert
     * is raised while decoding, inside MandateManager's own frame, so the catch arm never runs and
     * what reaches the agent carries no selector at all.
     *
     * RE-STAGED BY F13, and the staging is now part of the argument. This test used
     * `SilentRegistry` — code present, zero bytes returned to every selector — until
     * `createMandate` began reading both registries itself, at which point no mandate could be
     * granted against such a registry at all and the spend under test here stopped being
     * reachable. The registry used now answers properly, is granted against, and is then told to
     * stop, which is the one route left to the gap F49 documents: a registry upgraded, behind a
     * proxy, into returning the wrong shape. Both registry addresses are `immutable`, so the
     * change has to come from inside the registry rather than from repointing this contract.
     *
     * Each path spends once before the flip. That is not scene-setting: without it, a refusal
     * afterwards would be equally consistent with a mandate that was never spendable, and the
     * assertion would pin nothing to the decode.
     *
     * That residual case is documented rather than handled. Covering it means replacing both typed
     * calls with a raw STATICCALL and validating the answer's length by hand, and the spend is
     * refused either way, so the whole difference is legibility. What this test buys is that the
     * claim is demonstrated: anyone who later reads the try/catch as covering decode failure has a
     * failing assertion to read instead.
     */
    function test_f49_aRegistryThatAnswersUndecodably_revertsPastTheCatch() public {
        SilenceableRegistry reg = new SilenceableRegistry();
        assertTrue(address(reg).code.length > 0, "past the constructor guard, which is the point");
        reg.mint(AGENT_ID, agent);
        reg.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);

        // The identity path decodes an address, so 32 bytes are needed and none will arrive.
        MandateManager mmIdentity = new MandateManager(address(token), address(reg), address(validation));
        vm.prank(payer);
        token.approve(address(mmIdentity), type(uint256).max);
        MandateManager.MandateParams memory idParams = withIdentity(simpleParams(), AGENT_ID, agent);
        vm.prank(payer);
        bytes32 idGate = mmIdentity.createMandate(bytes32("f49-identity"), idParams);

        // The credential path decodes six fields including a dynamic string, so it needs at
        // least 192 bytes, and the empty answer fails it the same way. Both paths are
        // asserted because the two calls sit in different helpers.
        MandateManager mmCredential = new MandateManager(address(token), address(identity), address(reg));
        vm.prank(payer);
        token.approve(address(mmCredential), type(uint256).max);
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days);
        vm.prank(payer);
        bytes32 credGate = mmCredential.createMandate(bytes32("f49-credential"), p);

        // Both mandates work while the registry is answering, which is what makes the refusals
        // below attributable to the answer changing shape and to nothing else.
        vm.prank(agent);
        mmIdentity.spend(idGate, vendor, usd(10), REF, nextNonce());
        vm.prank(agent);
        mmCredential.spend(credGate, vendor, usd(10), REF, nextNonce());
        assertEq(token.balanceOf(vendor), usd(20), "both gates passed before the upgrade");

        reg.goSilent();

        vm.prank(agent);
        (bool ok, bytes memory err) =
            address(mmIdentity).call(abi.encodeCall(MandateManager.spend, (idGate, vendor, usd(10), REF, nextNonce())));
        assertFalse(ok, "the spend is refused, which is the half that was never in doubt");
        assertEq(err.length, 0, "F49: a decode failure carries no selector, so `catch` did not run");

        vm.prank(agent);
        (ok, err) = address(mmCredential)
            .call(abi.encodeCall(MandateManager.spend, (credGate, vendor, usd(10), REF, nextNonce())));
        assertFalse(ok);
        assertEq(err.length, 0, "F49: and the six-field tuple decodes no better than the address");
    }

    /**
     * The staging F13 retired, kept for the assertion it can still make.
     *
     * A registry that returns zero bytes to everything is what an address holding no code does as
     * well, and it is the version a deployer reaches by mistake, by pasting an address from the
     * wrong chain. The constructor's `RegistryHasNoCode` guard refuses that one before the
     * deployment exists, and this mock is past the guard by having code, so what it stands for is
     * the case the guard cannot reach.
     *
     * F13 moved where that failure lands. `createMandate` reads both registries itself now, so
     * the decode revert meets a registry like this one at the GRANT rather than at the spend.
     * For the payer that is strictly better, since the refusal arrives before any authority is
     * written; what it does not change is that the revert carries no selector, so nothing
     * distinguishes an unreachable registry from a mistyped agent id.
     */
    function test_f49_aRegistrySilentFromTheStart_isRefusedAtGrantWithoutASelector() public {
        SilentRegistry silent = new SilentRegistry();
        assertTrue(address(silent).code.length > 0, "past the constructor guard, which is the point");

        MandateManager mmIdentity = new MandateManager(address(token), address(silent), address(validation));
        MandateManager.MandateParams memory idParams = withIdentity(simpleParams(), AGENT_ID, agent);
        bytes memory idGrant = abi.encodeCall(MandateManager.createMandate, (bytes32("f49-grant-id"), idParams));
        vm.prank(payer);
        (bool ok, bytes memory err) = address(mmIdentity).call(idGrant);
        assertFalse(ok, "the grant is refused, not the spend");
        assertEq(err.length, 0, "F49 at grant: the address decode reverts past the catch arm too");

        MandateManager mmCredential = new MandateManager(address(token), address(identity), address(silent));
        MandateManager.MandateParams memory p = withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days);
        bytes memory credGrant = abi.encodeCall(MandateManager.createMandate, (bytes32("f49-grant-cred"), p));
        vm.prank(payer);
        (ok, err) = address(mmCredential).call(credGrant);
        assertFalse(ok);
        assertEq(err.length, 0, "F49 at grant: and the six-field tuple decodes no better here either");
    }

    // ================================================== F13: the grant-time half

    /**
     * NEW IN v2 (F13). `createMandate` validates what the credential check POINTS AT, once, and
     * leaves what that attestation currently SAYS to `spend`. `_requireCredentialAtGrant` is
     * where the division is argued; this section is where each of its arms is asserted.
     *
     * The section exists because of a count derived from the call sites rather than assumed. Of
     * the thirty `withCredential` sites in this suite, every one except `test/Cosign.t.sol:1913`
     * names the validator and the agent id that `setUp` staged, so every one of them reaches the
     * helper's fall-through and returns. Three of the five arms had no grant that touched them,
     * and two of those three are refusals — which is exactly the shape a mutation census reports
     * as a survivor, since deleting the line turns nothing red.
     *
     * The identity half is deliberately absent here. `_requireIdentityAtGrant` REFUSES an absent
     * record while this helper PERMITS one, and whether that asymmetry is correct is an open
     * question for the payer-facing design rather than one an assertion here should foreclose.
     */

    /// Arc's measured shape for a hash the registry has never seen is a revert, so a payer who
    /// grants before the validator files arrives at the `catch` arm. The grant has to stand:
    /// the attestation is a third party's to file and the payer cannot wait on it.
    ///
    /// `test/Cosign.t.sol:1913` already reaches this arm on its way to an F17 assertion. It is
    /// restated here as the thing being tested rather than as a precondition of something else.
    function test_f13_grantingBeforeTheAttestationIsFiled_isAllowed() public {
        bytes32 unfiled = bytes32("f13-nothing-here-yet");
        bytes32 id = grant(withCredential(simpleParams(), boss, unfiled, AGENT_ID, 1 days));

        // Permitted at grant, refused at spend, and the two are consistent: the grant fixed the
        // identifiers and the spend asked the question the identifiers name.
        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);

        validation.setStatus(unfiled, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "the mandate was waiting, not broken");
    }

    /// The other shape a registry uses for "never seen" is a zero tuple, and the grant has to
    /// treat it the same way for the same reason. No test in this suite had ever staged that
    /// answer BEFORE a grant, so the `gotValidator == address(0)` return was uncovered.
    function test_f13_grantingAgainstAZeroTupleRegistry_isAllowed() public {
        validation.setRevertOnUnknown(false);
        bytes32 unfiled = bytes32("f13-zero-tuple");
        bytes32 id = grant(withCredential(simpleParams(), boss, unfiled, AGENT_ID, 1 days));

        payReverts(id, usd(10), MandateManager.CredentialMissing.selector);

        validation.setStatus(unfiled, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// The verdict is deferred, and this is the test that says so. A filed attestation whose
    /// response is BELOW the payer's floor is a real record under the right hash by the right
    /// validator about the right agent, so every identifier the grant checks agrees. Refusing
    /// here would refuse a mandate that the validator can revive without the payer acting.
    function test_f13_grantingWhileTheAttestationFails_isAllowed() public {
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 0, block.timestamp);
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));

        payReverts(id, usd(10), MandateManager.CredentialFailed.selector);

        // The revival is the argument. A grant refused above could not reach this line without
        // the payer noticing the failure and granting a second time.
        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// Staleness is the other half of the verdict, and it is the half that makes the grant-time
    /// reading actively wrong: the same configuration would be accepted on Friday and refused on
    /// Monday for no change in anything the payer controls.
    function test_f13_grantingWhileTheAttestationIsStale_isAllowed() public {
        vm.warp(block.timestamp + 2 days); // `setUp` attested 100 seconds in, against a 1-day rule
        bytes32 id = grant(withCredential(simpleParams(), boss, KYC_HASH, AGENT_ID, 1 days));

        payReverts(id, usd(10), MandateManager.CredentialStale.selector);

        validation.setStatus(KYC_HASH, boss, AGENT_ID, 100, block.timestamp);
        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10));
    }

    /// An identifier the payer got wrong is what F13 is for. `setUp` filed this record under
    /// `boss`, so a grant naming a different validator describes an attestation that does not
    /// exist and never will, and every spend on it would answer `CredentialWrongValidator`
    /// forever. The refusal moves that answer to the one transaction the payer is watching.
    function test_f13_grantNamingAValidatorTheRecordDoesNotCarry_isRefused() public {
        grantReverts(
            withCredential(simpleParams(), other, KYC_HASH, AGENT_ID, 1 days),
            MandateManager.CredentialWrongValidator.selector
        );
    }

    /// The same argument for the agent id. The record `setUp` filed is about `AGENT_ID`, so a
    /// grant naming any other agent is born dead in the sense F34 refuses.
    function test_f13_grantNamingAnAgentTheRecordDoesNotCarry_isRefused() public {
        grantReverts(
            withCredential(simpleParams(), boss, KYC_HASH, 999, 1 days), MandateManager.CredentialWrongAgent.selector
        );
    }

    /**
     * The fallback is wired at grant time too, and this is the only test that proves it.
     *
     * With `credential.agentId` left at zero the check inherits the identity gate's agent id, which
     * `_requireCredentialAtGrant` receives as an argument rather than reading it from storage.
     * The call site passes it THROUGH the `F_IDENTITY` flag, and a ternary that returned the
     * wrong side of that test would be invisible to every other test in this file, because they
     * all name the same agent in both places.
     *
     * Here the two disagree: agent 999 is minted and pinned by the identity gate, while the
     * filed record is about agent 42. The grant must refuse, and it can only refuse if the
     * inherited id reached the comparison.
     */
    function test_f13_theInheritedAgentIdIsTheOneComparedAtGrant() public {
        identity.mint(999, agent);
        MandateManager.MandateParams memory p = withIdentity(simpleParams(), 999, agent);
        p = withCredential(p, boss, KYC_HASH, 0, 1 days); // agentId 0 = inherit 999

        vm.prank(payer);
        vm.expectRevert(MandateManager.CredentialWrongAgent.selector);
        mm.createMandate(bytes32("f13-inherited-agent"), p);
    }

    /// F43 in the direction that matters: a grant the enforcer would honour must not be refused by
    /// the writer, and `test_DOCUMENTED_GAP_credentialWithNoAgentBinding_acceptsAnyAgent` above
    /// shows `spend` honouring an attestation about an agent the mandate never named, which is a
    /// weakening the repository keeps on purpose. The grant therefore has to accept it as well:
    /// closing the gap on this side alone would refuse a mandate that the enforcer still spends.
    function test_f43_theGrantKeepsTheSameAgentBindingGapAsTheSpend() public {
        validation.setStatus(KYC_HASH, boss, 999, 100, block.timestamp);

        MandateManager.MandateParams memory p = simpleParams();
        p = withCredential(p, boss, KYC_HASH, 0, 1 days); // no agentId, and no identity gate
        bytes32 id = grant(p);

        pay(id, usd(10));
        assertEq(token.balanceOf(vendor), usd(10), "the writer refuses nothing the enforcer allows");
    }
}
