// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * Minimal 6-decimal ERC-20 standing in for Arc's USDC at 0x3600...0000.
 *
 * WHY NOT A GENERIC MOCK
 * Arc's USDC is not a plain ERC-20 and the differences are exactly the ones that
 * break a naive spending contract, so they are modelled here rather than assumed
 * away:
 *
 *   - Transfers to the zero address REVERT. Arc forbids burning value, so a
 *     contract that lets address(0) through does not fail gracefully, it fails at
 *     runtime after consuming gas. MandateManager rejects it up front; this mock
 *     exists so that claim can be tested rather than asserted.
 *   - A blocklisted sender or recipient REVERTS at runtime. There is no way to
 *     pre-check it. The correct outcome is that the whole spend unwinds — no cap
 *     consumed, no nonce burned — and `setBlocklisted` is how that gets tested.
 *   - `returnFalseOnTransfer` models the other ERC-20 failure convention: a token
 *     that returns false instead of reverting. MandateManager checks the return
 *     value and raises TransferFailed. Without a token that can exercise it, that
 *     check would be indistinguishable from a missing one — two tests in
 *     Idempotency.t.sol depend on this flag for exactly that reason.
 *
 * The native/ERC-20 dual view (18 decimals native, 6 via ERC-20, one underlying
 * balance) is NOT modelled, because MandateManager only ever touches the ERC-20
 * interface. That is the whole reason the native path is out of scope: see the
 * SCOPE block in MandateManager.sol.
 */
contract MockUSDC {
    string public constant name = "USD Coin (mock)";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(address => bool) public blocklisted;
    bool public returnFalseOnTransfer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddressNotAllowed();
    error AccountBlocklisted(address account);
    error InsufficientBalance(uint256 have, uint256 need);
    error InsufficientAllowance(uint256 have, uint256 need);

    // --- test controls -----------------------------------------------------

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setBlocklisted(address account, bool value) external {
        blocklisted[account] = value;
    }

    function setReturnFalseOnTransfer(bool value) external {
        returnFalseOnTransfer = value;
    }

    // --- ERC-20 -----------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnFalseOnTransfer) return false;

        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(allowed, amount);
        // Infinite approval is not decremented, matching Circle's implementation.
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (blocklisted[from]) revert AccountBlocklisted(from);
        if (blocklisted[to]) revert AccountBlocklisted(to);

        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
