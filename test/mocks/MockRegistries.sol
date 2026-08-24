// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * ERC-8004 IdentityRegistry stand-in.
 *
 * The one behaviour that matters: identities are ERC-721 tokens, so `ownerOf`
 * REVERTS for a nonexistent or burned id rather than returning address(0). A gate
 * that calls it naively turns a burned agent identity into an opaque revert instead
 * of a legible denial, which is why MandateManager wraps the call in try/catch.
 * `burn` here is what makes that branch reachable in a test.
 *
 * Identities are also TRANSFERABLE, which is the reason the gate pins an expected
 * owner. `transferAgent` is how the "identity sold to a stranger" attack is staged.
 */
contract MockIdentityRegistry {
    mapping(uint256 => address) internal _owner;

    error ERC721NonexistentToken(uint256 tokenId);

    function mint(uint256 agentId, address to) external {
        _owner[agentId] = to;
    }

    function transferAgent(uint256 agentId, address to) external {
        _owner[agentId] = to;
    }

    function burn(uint256 agentId) external {
        delete _owner[agentId];
    }

    function ownerOf(uint256 agentId) external view returns (address) {
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
 * about inside the tuple. A gate that reads only `response` is therefore satisfied
 * by any attestation anyone managed to file under that hash, including a real
 * passing attestation about a DIFFERENT agent. Both of those were live bugs in this
 * project; `setStatus` takes validator and agentId as free parameters precisely so
 * the tests can forge those two cases.
 *
 * `revertOnUnknown` toggles between the two plausible registry behaviours for an
 * unset hash — revert, or return a zero tuple. MandateManager must deny either way
 * (CredentialMissing), and both paths are tested.
 *
 * WHICH ONE IS REAL IS NOW OBSERVED, not assumed. On 2026-08-24 the live Arc Testnet
 * ValidationRegistry at 0x8004Cb1BF31DAf7788923b405b754f57acEB4272 was queried directly
 * with three request hashes that do not exist. All three REVERTED, with the standard
 * `Error(string)` selector 0x08c379a0 and the string "unknown". So `revertOnUnknown =
 * true` is the production behaviour, and the `catch { revert CredentialMissing(); }`
 * arm in _checkCredential is the arm Arc actually takes — without it, a spend against a
 * missing attestation would bubble `Error("unknown")` out of the registry instead of a
 * decodable custom error.
 *
 * The zero-tuple path stays tested anyway. It costs one boolean, the registry sits
 * behind an ERC-1967 proxy and can therefore be upgraded under us, and a gate that only
 * denies correctly for one of the two shapes is a gate with a scheduled expiry date.
 *
 * The same probe found a real record filed under requestHash == bytes32(0): validator
 * 0xB152c3B6436318aD340153f1d30C9BBb8634681A, agentId 16330, response 1, tag "verified".
 * Response 1 FAILS the ERC-8004 convention where 100 means passed, so that is a failing
 * attestation carrying a reassuring label — which is the case for checking the number
 * and ignoring the tag, made by the live chain rather than by argument.
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
    bool public revertOnUnknown;

    error NoSuchRequest(bytes32 requestHash);

    function setRevertOnUnknown(bool value) external {
        revertOnUnknown = value;
    }

    /// ERC-8004 convention: response 100 == passed.
    function setStatus(bytes32 requestHash, address validator, uint256 agentId, uint8 response, uint256 lastUpdate)
        external
    {
        _status[requestHash] = Status({
            validator: validator,
            agentId: agentId,
            response: response,
            responseHash: keccak256(abi.encode(requestHash, response)),
            tag: "compliance",
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
