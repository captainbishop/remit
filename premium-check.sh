#!/usr/bin/env bash
# premium-check.sh — READ-ONLY. No transactions, no gas, no password prompts.
#
# Purpose: confirm the on-chain state that a receipt-vs-receipt premium
# measurement depends on, BEFORE spending any faucet money.
#
# The comparison only holds if each storage slot is in the same class (zero vs
# non-zero) on Arc's USDC and on MockUSDC, because a write to a zero slot costs
# 20,000 gas and an overwrite costs 2,900. A 17,100 asymmetry hiding in the
# setup would swamp the number we are trying to measure.

set -u

RPC=https://rpc.testnet.arc.io
USDC=0x3600000000000000000000000000000000000000
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de
MANAGER=0x3744E93B9e796E05CB66311d897559B6F3860196

r() { cast call "$USDC" "$@" --rpc-url "$RPC" 2>&1; }

echo "=== chain ==="
echo "chainId:  $(cast chain-id --rpc-url $RPC 2>&1)"
echo "gasPrice: $(cast gas-price --rpc-url $RPC 2>&1)"
echo "block:    $(cast block-number --rpc-url $RPC 2>&1)"

echo
echo "=== USDC balances, 6 decimals (must all be NON-ZERO except where noted) ==="
echo "payer  balanceOf: $(r 'balanceOf(address)(uint256)' $PAYER)"
echo "agent  balanceOf: $(r 'balanceOf(address)(uint256)' $AGENT)   <- also pays gas for 2 txs"
echo "vendor balanceOf: $(r 'balanceOf(address)(uint256)' $VENDOR)   <- must be NON-ZERO for symmetry"

echo
echo "=== native balances, 18 decimals (gas) ==="
echo "payer: $(cast balance $PAYER --rpc-url $RPC 2>&1)"
echo "agent: $(cast balance $AGENT --rpc-url $RPC 2>&1)"

echo
echo "=== allowances ==="
echo "payer -> manager: $(r 'allowance(address,address)(uint256)' $PAYER $MANAGER)   <- expect 90000 from approve-lo"
echo "payer -> agent:   $(r 'allowance(address,address)(uint256)' $PAYER $AGENT)   <- expect 0, will be created as setup"

echo
echo "=== is the allowance infinite? (matters: neither token decrements uint256.max) ==="
echo "uint256 max is 115792089237316195423570985008687907853269984665640564039457584007913129639935"

echo
echo "=== toolchain ==="
cast --version 2>&1 | head -3
forge --version 2>&1 | head -3
