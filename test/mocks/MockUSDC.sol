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
 *
 * WHERE THIS MOCK DIVERGES FROM ARC AND WILL MISLEAD YOU (F25)
 * `_move` emits `Transfer(from, to, amount)` UNCONDITIONALLY, including when
 * `from == to`. Arc's `usdc-system-events` reference states the opposite for the
 * system emitter at 0xffff...fffe: "Self-transfers (from == to) emit no log."
 *
 * So NO LOG-COUNTING ASSERTION ABOUT A SELF-PAYMENT MEANS ANYTHING HERE. A test
 * that watched for a `Transfer` on a spend where recipient == payer would pass
 * while demonstrating the precise opposite of production, and it would be this
 * mock — our own code — answering a question about Arc. That is not a hypothetical
 * test: it is the one F19 invites, since F19's claim is that a self-payment is
 * invisible in the transfer log and must be reconciled from
 * `getMandate(id).totalSpent` instead. F19's guard is therefore asserted with
 * `vm.expectRevert(SelfPayment.selector)` in Bounds.t.sol and Cosign.t.sol, and
 * never by counting logs.
 *
 * One narrower question this mock also cannot answer: whether Arc's ERC-20 USDC at
 * 0x3600...0000 emits its own 6-decimal `Transfer` for a self-transfer. Arc
 * documents the rule only for the 18-decimal system emitter. Whatever this file
 * does is a description of our assumption, not of Arc; only a testnet transaction
 * against the real token settles it.
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
        // F25: unconditional, including from == to, where Arc's system emitter is silent.
        // Left divergent on purpose — matching Arc here would make the mock look
        // authoritative about a rule only a testnet transaction can confirm. See the header.
        emit Transfer(from, to, amount);
    }
}
