#!/usr/bin/env bash
# premium.sh — measure Arc USDC's gas premium by receipt-vs-receipt, on Arc.
# COSTS GAS. NINE password prompts. Each is announced before it appears.
#
# WHY THIS EXISTS
# DESIGN.md publishes "Arc's NativeFiatToken costs ~17,100 gas more than a
# minimal ERC-20 for an approve and ~32,700 more for a transferFrom". Both came
# from taking createMandate's -6,337 harness deviation as a FLAT calibration
# constant and adding it to two other deviations. Harness overhead has since
# been shown to scale with how much state an operation touches, so both numbers
# inherit that error.
#
# THE METHOD
# Run the same operation twice on the SAME chain: once against Arc's USDC at
# 0x3600..0000, once against a freshly deployed MockUSDC. No test harness in the
# comparison at all. Within each pair the calldata is byte-identical, because
# the token address rides in the transaction's `to` field and not in calldata.
# Intrinsic gas (21,000 + 4/zero byte + 16/non-zero byte) therefore cancels
# exactly, and the difference in receipt gasUsed IS the premium.
#
# THE TRAP THIS AVOIDS
# EIP-2200 charges 20,000 to write a storage slot that held zero and 2,900 to
# overwrite one that did not. That 17,100 gap is the same size as the number
# being measured, so every slot must be in the same class on both tokens:
#   payer balance    non-zero both  (Arc: 18.575 USDC; mock: minted in step 2)
#   vendor balance   non-zero both  (Arc: 0.35 USDC;   mock: minted in step 3)
#   allowance p->a   zero both      (Arc: verified 0;  mock: fresh deploy)
# All three confirmed by premium-check.log at block 58680613.
#
# Amounts are small enough that nothing is ever written back down to zero,
# which would earn an EIP-3529 refund and make the two receipts incomparable.
#
# RESUME: if the deploy lands but a later step fails, re-run with the mock
# address to skip redeploying and re-minting:
#     bash premium.sh 0xMOCKADDRESS --no-setup

set -u

DIR=/mnt/c/Users/DELL/projects/remit
LOG="$DIR/premium.log"
TMP="$DIR/premium-step.log"
CRE="$DIR/premium-create.log"

RPC=https://rpc.testnet.arc.io
USDC=0x3600000000000000000000000000000000000000
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de

# Fixed so the calldata is identical within each pair. Gas depends only on
# whether a slot is zero or non-zero, never on the value itself.
APPROVE_A=200000   # 0.20 USDC onto a ZERO allowance slot
XFER=10000         # 0.01 USDC moved payer -> vendor
APPROVE_C=100000   # 0.10 USDC onto a LIVE allowance slot

cd "$DIR" || { echo "cannot cd to $DIR"; exit 1; }
: > "$LOG"

log()   { printf '%s\n' "$*" >> "$LOG"; }
head2() { printf '\n\n=================== %s ===================\n' "$*" >> "$LOG"; }

# Read-only. Never prompts, so it is safe to redirect entirely.
peek() {
  local label="$1" tok="$2"; shift 2
  printf '  %-28s ' "$label" >> "$LOG"
  cast call "$tok" "$@" --rpc-url "$RPC" >> "$LOG" 2>&1
}

# One signed transaction. Foundry writes its password prompt straight to the
# terminal device, so redirecting both streams still leaves the prompt visible
# (proven by gates-send.sh). Full receipt to the log, headline to the screen.
send() {
  local step="$1" acct="$2" from="$3" label="$4"; shift 4
  printf '\n>>> [%s/9] %s\n    password for %s ...\n' "$step" "$label" "$acct"
  head2 "STEP $step -- $label"
  log "cast send $*"
  cast send "$@" --rpc-url "$RPC" --account "$acct" --from "$from" > "$TMP" 2>&1
  local rc=$?
  cat "$TMP" >> "$LOG"
  printf '    exit=%s  %s\n' "$rc" \
    "$(grep -E '^(status|gasUsed|transactionHash)' "$TMP" | tr '\n' ' ')"
  if [ "$rc" -ne 0 ]; then
    echo "    !! step $step failed -- stopping. see premium.log"
    exit 1
  fi
}

log "premium.sh   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "block at start: $(cast block-number --rpc-url $RPC 2>&1)"
log "gas price:      $(cast gas-price --rpc-url $RPC 2>&1)"

# ------------------------------------------------------------------ deploy ----
MOCK="${1:-}"
SKIP_SETUP="${2:-}"

if [ -z "$MOCK" ]; then
  head2 "STEP 1 -- deploy MockUSDC to Arc Testnet"
  printf '\n>>> [1/9] deploy MockUSDC\n    password for remit-testnet ...\n'
  forge create test/mocks/MockUSDC.sol:MockUSDC \
    --rpc-url "$RPC" --account remit-testnet --from "$PAYER" --broadcast \
    > "$CRE" 2>&1
  rc=$?
  cat "$CRE" >> "$LOG"
  MOCK=$(sed -n 's/^Deployed to: *//p' "$CRE" | tr -d '[:space:]')
  printf '    exit=%s  mock=%s\n' "$rc" "${MOCK:-NONE}"
  if [ -z "$MOCK" ]; then
    echo "    !! no address parsed. see premium-create.log"
    echo "    !! if it DID deploy: bash premium.sh 0xTHEADDRESS"
    exit 1
  fi
else
  head2 "STEP 1 -- skipped, reusing MockUSDC at $MOCK"
  printf '\n>>> [1/9] skipped, reusing mock at %s\n' "$MOCK"
fi
log "MOCK = $MOCK"

# -------------------------------------------------------------- mock setup ----
# Give the mock the same slot classes Arc already has. Not measured.
if [ -z "$SKIP_SETUP" ]; then
  send 2 remit-testnet "$PAYER" "setup: mint 20.0 mock USDC to payer" \
    "$MOCK" 'mint(address,uint256)' "$PAYER" 20000000
  send 3 remit-testnet "$PAYER" "setup: mint 0.35 mock USDC to vendor (matches Arc)" \
    "$MOCK" 'mint(address,uint256)' "$VENDOR" 350000
else
  printf '\n>>> [2/9] [3/9] setup skipped\n'
fi

# ----------------------------------------------------------------- PAIR A -----
# approve onto a ZERO slot. Both tokens: SSTORE 0 -> non-zero, one Approval log.
send 4 remit-testnet "$PAYER" "PAIR A / MOCK  approve(agent, 0.20)" \
  "$MOCK" 'approve(address,uint256)' "$AGENT" "$APPROVE_A"
send 5 remit-testnet "$PAYER" "PAIR A / ARC   approve(agent, 0.20)" \
  "$USDC" 'approve(address,uint256)' "$AGENT" "$APPROVE_A"

# ----------------------------------------------------------------- PAIR B -----
# transferFrom sent BY THE AGENT, spending the allowance PAIR A just created.
# Both tokens: three non-zero overwrites (allowance, payer bal, vendor bal).
send 6 remit-agent "$AGENT" "PAIR B / MOCK  transferFrom(payer, vendor, 0.01)" \
  "$MOCK" 'transferFrom(address,address,uint256)' "$PAYER" "$VENDOR" "$XFER"
send 7 remit-agent "$AGENT" "PAIR B / ARC   transferFrom(payer, vendor, 0.01)" \
  "$USDC" 'transferFrom(address,address,uint256)' "$PAYER" "$VENDOR" "$XFER"

# ----------------------------------------------------------------- PAIR C -----
# approve onto a LIVE slot (now 0.19 on both). Self-check: on each token
# separately, PAIR A minus PAIR C should land near 17,100.
send 8 remit-testnet "$PAYER" "PAIR C / MOCK  approve(agent, 0.10)" \
  "$MOCK" 'approve(address,uint256)' "$AGENT" "$APPROVE_C"
send 9 remit-testnet "$PAYER" "PAIR C / ARC   approve(agent, 0.10)" \
  "$USDC" 'approve(address,uint256)' "$AGENT" "$APPROVE_C"

# ------------------------------------------------------------------ verify ----
# If these do not match across tokens, a slot class diverged and the
# measurement is void.
head2 "final state -- mock and Arc must agree"
log "mock $MOCK"
peek "mock  payer balance"  "$MOCK" 'balanceOf(address)(uint256)' "$PAYER"
peek "mock  vendor balance" "$MOCK" 'balanceOf(address)(uint256)' "$VENDOR"
peek "mock  allowance p->a" "$MOCK" 'allowance(address,address)(uint256)' "$PAYER" "$AGENT"
log ""
peek "arc   payer balance"  "$USDC" 'balanceOf(address)(uint256)' "$PAYER"
peek "arc   vendor balance" "$USDC" 'balanceOf(address)(uint256)' "$VENDOR"
peek "arc   allowance p->a" "$USDC" 'allowance(address,address)(uint256)' "$PAYER" "$AGENT"
log ""
peek "arc   agent balance (gas)" "$USDC" 'balanceOf(address)(uint256)' "$AGENT"

SUMMARY=$(grep -E '^(gasUsed|status)' "$LOG" | tr '\n' ' ')
head2 "gasUsed and status, in step order"
log "$SUMMARY"

rm -f "$TMP"
echo
echo "done. MockUSDC = $MOCK"
echo "premium.log written."
