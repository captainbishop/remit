// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * ERC-8004 IdentityRegistry stand-in.
 *
 * The one behaviour that matters: identities are ERC-721 tokens, so `ownerOf`
 * REVERTS for a nonexistent or burned id rather than returning address(0). A check
 * that calls it naively turns a burned agent identity into an opaque revert instead
 * of a legible denial, which is why MandateManager wraps the call in try/catch.
 * `burn` here is what makes that branch reachable in a test.
 *
 * Identities are also TRANSFERABLE, which is the reason the gate pins an expected
 * owner. `transferAgent` is how the "identity sold to a stranger" attack is staged.
 *
 * `setRevertOnOwnerOf` is the SECOND failure mode, and it exists to make a claim
 * checkable rather than to widen coverage for its own sake. Burning was the only way
 * to make `ownerOf` revert here, so every reverting case in the suite was also a case
 * where the identity had in fact gone. The live registry sits behind an ERC-1967
 * proxy and can be upgraded, so a revert while the token is still held is a real
 * shape, and `_checkIdentity`'s catch arm maps every revert to the same
 * `IdentityNotHeld`. That indistinguishability is now asserted by a test instead of
 * being described in a comment that claimed the opposite.
 */
contract MockIdentityRegistry {
    mapping(uint256 => address) internal _owner;
    bool public revertOnOwnerOf;

    error ERC721NonexistentToken(uint256 tokenId);
    error RegistryUnavailable();

    function mint(uint256 agentId, address to) external {
        _owner[agentId] = to;
    }

    function transferAgent(uint256 agentId, address to) external {
        _owner[agentId] = to;
    }

    function burn(uint256 agentId) external {
        delete _owner[agentId];
    }

    /// Make `ownerOf` fail for a reason that is not "this identity is gone". The error
    /// is deliberately one neither this file nor `MandateManager` mentions anywhere
    /// else, so a test cannot pass by recognising it.
    function setRevertOnOwnerOf(bool value) external {
        revertOnOwnerOf = value;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        if (revertOnOwnerOf) revert RegistryUnavailable();
        address o = _owner[agentId];
        if (o == address(0)) revert ERC721NonexistentToken(agentId);
        return o;
    }
}

/**
 * ERC-8004 ValidationRegistry stand-in.
 *
 * THE POINT OF THIS MOCK IS THE LOOKUP KEY. `getValidationStatus` is keyed on
 * `requestHash` ALONE, and returns the validator and the agent the attestation is
 * about inside the tuple. A check that reads only `response` is therefore satisfied
 * by any attestation anyone managed to file under that hash, including a real
 * passing attestation about a DIFFERENT agent. Both of those were live bugs in this
 * project; `setStatus` takes validator and agentId as free parameters precisely so
 * the tests can forge those two cases.
 *
 * `revertOnUnknown` toggles between the two plausible registry behaviours for an
 * unset hash — revert, or return a zero tuple. MandateManager must deny either way
 * (CredentialMissing), and both paths are tested. **It defaults to `true`, which is
 * the behaviour measured on Arc**, so the whole suite exercises the arm production
 * takes and a test wanting the other shape asks for it by name. It defaulted to
 * `false` until 2026-09-06, which left one test out of the entire suite on the live
 * arm; the two shapes converge on the same error, so nothing about the contract
 * changed when the default flipped, but which code path 320-odd tests covered did.
 *
 * WHICH ONE IS REAL IS NOW OBSERVED, not assumed. On 2026-08-24 the live Arc Testnet
 * ValidationRegistry at 0x8004Cb1BF31DAf7788923b405b754f57acEB4272 was queried directly
 * with three request hashes that do not exist. All three REVERTED, with the standard
 * `Error(string)` selector 0x08c379a0 and the string "unknown", so `revertOnUnknown =
 * true` is the production behaviour, and the `catch { revert CredentialMissing(); }`
 * arm in _checkCredential is the arm Arc actually takes — without it, a spend against a
 * missing attestation would bubble `Error("unknown")` out of the registry instead of a
 * decodable custom error.
 *
 * The zero-tuple path stays tested anyway. It costs one boolean, the registry sits
 * behind an ERC-1967 proxy and can therefore be upgraded at any time, and a check that
 * denies correctly for only one of the two shapes has a scheduled expiry date.
 *
 * The same probe found a real record filed under requestHash == bytes32(0): validator
 * 0xB152c3B6436318aD340153f1d30C9BBb8634681A, agentId 16330, response 1, tag "verified".
 * Response 1 FAILS the ERC-8004 convention where 100 means passed, so that is a failing
 * attestation carrying a reassuring label, so the case for checking the number and
 * ignoring the tag is made by the live chain rather than by argument.
 *
 * That record is also the only measurement anyone has of the two fields `setStatus`
 * used to invent. Decoding `evidence/registry.log` word by word: responseHash is the
 * fourth word and reads zero, beside a response of 1, so the live registry does not
 * derive one from the other; and the tag is "verified", not "compliance". `setStatus`
 * now takes both as parameters with `setStatusFull`, and the five-argument form keeps
 * every existing call site working by passing the live pair — a zero hash and the
 * label that failing attestation actually carried. Inventing
 * `keccak256(requestHash, response)` made a relation up, and hardcoding "compliance"
 * made the mislabelled-attestation case this registry exists to model unstageable
 * from a test.
 */
contract MockValidationRegistry {
    struct Status {
        address validator;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
        bool set;
    }

    mapping(bytes32 => Status) internal _status;
    /// True is Arc's measured behaviour for an unknown hash. See the header.
    bool public revertOnUnknown = true;

    error NoSuchRequest(bytes32 requestHash);

    function setRevertOnUnknown(bool value) external {
        revertOnUnknown = value;
    }

    /// ERC-8004 convention: response 100 == passed.
    ///
    /// The two fields this does not take are filled with what the live registry returned:
    /// a zero responseHash and the tag "verified", which is the label the one real record
    /// carries on a response of 1. Neither is read by `MandateManager`, which decodes both
    /// positions and discards them, so this is about what the mock CLAIMS rather than about
    /// what any check sees. `setStatusFull` is for a test that needs to say otherwise.
    function setStatus(bytes32 requestHash, address validator, uint256 agentId, uint8 response, uint256 lastUpdate)
        external
    {
        _status[requestHash] = Status({
            validator: validator,
            agentId: agentId,
            response: response,
            responseHash: bytes32(0),
            tag: "verified",
            lastUpdate: lastUpdate,
            set: true
        });
    }

    /// The same record with the two discarded fields under the caller's control. It exists
    /// so a test can stage the case this registry's header gives as its own reason for
    /// being: a reassuring tag over a failing number.
    function setStatusFull(
        bytes32 requestHash,
        address validator,
        uint256 agentId,
        uint8 response,
        bytes32 responseHash,
        string calldata tag,
        uint256 lastUpdate
    ) external {
        _status[requestHash] = Status({
            validator: validator,
            agentId: agentId,
            response: response,
            responseHash: responseHash,
            tag: tag,
            lastUpdate: lastUpdate,
            set: true
        });
    }

    function clear(bytes32 requestHash) external {
        delete _status[requestHash];
    }

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
        )
    {
        Status memory s = _status[requestHash];
        if (!s.set && revertOnUnknown) revert NoSuchRequest(requestHash);
        return (s.validator, s.agentId, s.response, s.responseHash, s.tag, s.lastUpdate);
    }
}

/**
 * A registry that holds code and answers every call with zero bytes.
 *
 * NEW IN v2 (F49). This is the case Solidity's `catch` does NOT cover, and the mock exists so the
 * claim is demonstrated rather than argued. `catch` runs when the call failed; here the call
 * SUCCEEDS and returns nothing, so the revert happens while ABI decoding the empty answer into the
 * declared return type — an `address` for the identity check, a six-field tuple for the credential
 * check — inside MandateManager's own frame, past the catch arm. What reaches the caller is a
 * revert with no selector at all, rather than `IdentityNotHeld` or `CredentialMissing`.
 *
 * The constructor's `RegistryHasNoCode` guard closes the version of this a deployer can reach by
 * mistake, which is an address with no code behind it: EXTCODESIZE is zero, every call to it
 * succeeds with empty returndata, and every spend on a mandate carrying one of these checks dies
 * undecodably. This mock keeps code of its own, so that guard does not reach it, and covering
 * what is left would mean replacing both typed calls with a raw STATICCALL and a length check on
 * the answer. That is declined — the case left over needs a registry upgraded into returning the
 * wrong shape, and the spend is refused either way, so the whole cost is legibility, which
 * `MandateManager`'s comments record.
 *
 * A bare `fallback` is what makes one mock serve both registry positions: no function selector
 * matches, control lands here, and an empty body returns empty returndata for whatever was asked.
 */
contract SilentRegistry {
    fallback() external {}
}

