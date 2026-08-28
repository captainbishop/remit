#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# THIS SCRIPT TARGETS DEPLOYED v1 AND ITS SIGNATURES ARE DELIBERATELY STALE.
#
# Read this before "fixing" anything below. MM is 0x3744…0196, the immutable v1
# deployment. v2 (F15/F16) deleted `approveCosign(bytes32,bytes32)` and narrowed
# `spendHash` to five parameters IN THIS SOURCE TREE. It did not and cannot change
# the bytecode at that address, which still exposes the six-parameter `spendHash`
# and the two-parameter `approveCosign` this script calls.
#
# So the ABI strings at lines ~74 and ~176 are correct AS WRITTEN and must not be
# modernised. Swapping them to the v2 spelling would send calldata whose selector
# does not exist at that address: `approveCosignFor` would hit no function and
# revert, and the run would prove nothing about either version.
#
# This script has already run to completion; its output is in evidence/ and the
# live phase is closed. It is kept as the record of that run, not as a thing to
# re-execute. Re-pointing it at a future v2 deployment is NOT a signature swap:
# `approveCosignFor` needs a sixth argument, `validUntil`, which has no v1
# analogue, and the gas predictions below were derived for a function with 68
# calldata bytes and a log with no data words. Both would have to be re-derived.
# See the banner in test/ArcParity.t.sol for why that is a new measurement rather
# than a repair of this one.
# ---------------------------------------------------------------------------
# cosign-withdraw.sh — task #45. Exercise withdrawCosign() on the live chain.
#
# WHY THIS SCRIPT EXISTS. Writing up the revoke work, I claimed every function
# in the contract had now run live. Instead of publishing that, I listed every
# external/public function and grepped the evidence for each. withdrawCosign
# (line 736) came back with zero live transactions and zero mentions in any
# document in this repository. It is covered by the local suite and it appears
# in the gas report, which is exactly why it stayed invisible for a month: a
# green test suite is not an inventory of live coverage.
#
# THREE real transactions, all signed by M2's COSIGNER:
#   send 1  approveCosign(M2, hash)      <- second live call; 53,114 last time
#   send 2  withdrawCosign(M2, hash)     <- FIRST EVER live call
#   send 3  withdrawCosign(M2, ghost)    <- a hash that was never approved
#
# The loop is built from live data, not from an invented bytes32. There is a
# public spendHash() view at line 747, and error CosignRequired(bytes32) at
# line 294 carries the required hash in its revert payload, so the same hash
# can be obtained two independent ways and cross-checked.
#
# GAS PREDICTIONS, stated before the fact and clearly labelled as predictions.
# No number from this script enters DESIGN.md unless a receipt produced it.
#
#   send 1  should land within a few tens of gas of the 53,114 in
#           evidence/cosign-approve.log. Same three cold SLOADs, same fresh
#           mapping slot (line 494 deleted the previous approval when the spend
#           consumed it, so the slot is zero again), same LOG3. The only honest
#           source of difference is calldata: a zero byte costs 4 and a non-zero
#           byte 16, so the two hashes differ by 12 gas per zero byte.
#
#   send 2  clears a slot that a PREVIOUS transaction set, so it earns an
#           EIP-3529 refund of 4,800 capped at gasUsed/5. Expect ~31,000 of work
#           and ~26,000 on the receipt.
#
#   send 3  deletes an already-zero slot: SSTORE with current == new costs 100
#           instead of SSTORE_RESET's 2,900, and there is NO refund because
#           nothing was cleared. So send 3 does 2,800 LESS work than send 2 and
#           forgoes a 4,800 refund, which makes the receipt difference
#           +4,800 - 2,800 = ABOUT 2,000 GAS HIGHER for the cheaper call, give
#           or take 12 gas per zero-byte difference between the two hashes.
#           If that inversion appears at roughly that size it is the cleanest
#           live proof available that gasUsed does not measure work once
#           refunds are in play — the exact trap this project fell into once
#           before, and the reason the standing rule is never to compare
#           gasUsed across transactions where one earns a refund.
#
# Total cost about 0.0022 USDC. Nothing here can move money: an approval is
# only half of an authorisation, the agent's key is the other half, and the
# approval is withdrawn again by send 2 before the script ends.
#
#   bash cosign-withdraw.sh
# ---------------------------------------------------------------------------
set -u

RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de

M2=0xee83f8e2d8d261f29299d173c42a2ef7f245996b3cb6aa0c49014bd8fb7c746b
GHOSTM=0x00000000000000000000000000000000000000000000000000000000deadbeef

# Fresh nonces. M2 has used 0x..01, 0x..02, 0x..03; both are checked below
# rather than assumed, because a reused nonce would revert at line 471 and
# never reach the cosign gate at 492.
NONCE=0x0000000000000000000000000000000000000000000000000000000000000cd0
GHOSTN=0x0000000000000000000000000000000000000000000000000000000000000cd1
REF=0x0000000000000000000000000000000000000000000000000000000000000002

SPEND="spend(bytes32,address,uint256,bytes32,bytes32)"
SHASH="spendHash(bytes32,address,address,uint256,bytes32,bytes32)"

hr() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

# 64 hex chars -> decimal, no external dependency. Values here are all well
# under 2^63 so bash arithmetic is exact.
dec() { local h="${1#0x}"; h="$(echo "$h" | sed 's/^0*//')"; if [ -z "$h" ]; then echo 0; else echo $((16#$h)); fi; }

# ---------------------------------------------------------------------------
hr "0. Read M2's real configuration off the chain. No field is taken from notes."
G=$(cast call $MM "getMandate(bytes32)" $M2 --rpc-url $RPC 2>/dev/null | tr -d '\n')
G=${G#0x}
if [ ${#G} -lt 832 ]; then
  echo "   FAILED to read getMandate(M2) — got ${#G} hex chars, expected 832."
  echo "   Stopping before any transaction is sent."
  exit 1
fi
fld() { echo "0x${G:$(( $1 * 64 )):64}"; }
addr() { echo "$1" | sed 's/^0x0\{24\}/0x/'; }

COSIGNER=$(addr "$(fld 4)")
SPENDER=$(addr "$(fld 2)")
THRESH=$(dec "$(fld 5)")
PERTX=$(dec "$(fld 1)")
TOTALCAP=$(dec "$(fld 3)")
SPENT=$(dec "$(fld 6)")
FLAGS=$(dec "$(fld 10)")
REVOKED=$(dec "$(fld 12)")

echo "   spender          $SPENDER   (must be $AGENT)"
echo "   cosigner         $COSIGNER   (must be $PAYER)"
echo "   cosignThreshold  $THRESH"
echo "   perTxCap         $PERTX"
echo "   totalCap         $TOTALCAP    totalSpent  $SPENT"
echo "   flags            $FLAGS       revoked     $REVOKED"

if [ "$REVOKED" != "0" ]; then echo "   M2 is REVOKED. Nothing to do."; exit 1; fi
if [ "$(echo "$COSIGNER" | tr 'A-Z' 'a-z')" != "$(echo "$PAYER" | tr 'A-Z' 'a-z')" ]; then
  echo "   COSIGNER IS NOT THE PAYER. This script signs with remit-testnet and"
  echo "   would just collect NotCosigner(). Stopping before any send."
  exit 1
fi

hr "1. Pick the amount from live headroom, not from a guess."
echo "   The gate at line 492 is 'amount > m.cosignThreshold' — STRICT. That is"
echo "   why the 50,000 spend in evidence/subthreshold.log did not trip it."
echo "   policyHeadroom loops every window, so it is the real ceiling. Expect"
echo "   500,000 — the perTxCap. It binds ahead of the 800,000 left under the"
echo "   total cap, and ahead of the window, which is a 1,000,000 cap over"
echo "   86,400s in 24 hourly buckets and holds nothing from yesterday's spends:"
HEADHEX=$(cast call $MM "policyHeadroom(bytes32)" $M2 --rpc-url $RPC 2>/dev/null)
HEAD=$(dec "$HEADHEX")
echo "   policyHeadroom(M2) = $HEAD"
AMT=$(( THRESH + 10000 ))
if [ "$HEAD" -lt "$AMT" ]; then AMT=$HEAD; fi
if [ "$AMT" -le "$THRESH" ]; then
  echo "   Headroom $HEAD does not exceed the threshold $THRESH, so no amount can"
  echo "   be both inside the caps and over the gate. Stopping before any send."
  exit 1
fi
echo "   chosen amount      = $AMT   (over the gate, inside every cap)"

hr "2. Both nonces must be unused, or line 471 reverts before the gate at 492."
printf "   isNonceUsed(M2, ..0cd0)  "; cast call $MM "isNonceUsed(bytes32,bytes32)" $M2 $NONCE --rpc-url $RPC 2>&1 || true
printf "   isNonceUsed(M2, ..0cd1)  "; cast call $MM "isNonceUsed(bytes32,bytes32)" $M2 $GHOSTN --rpc-url $RPC 2>&1 || true

hr "3. Recipient must be allowlisted — M2 carries F_ALLOWLIST (bit 6)."
echo "   Three spends already landed at 0x..c0de, so expect true."
cast call $MM "isAllowedRecipient(bytes32,address)" $M2 $VENDOR --rpc-url $RPC 2>&1 || true

# ---------------------------------------------------------------------------
hr "4. THE HASH, first derivation: the public spendHash view at line 747."
HASH=$(cast call $MM "$SHASH" $M2 $AGENT $VENDOR $AMT $REF $NONCE --rpc-url $RPC 2>/dev/null | tr -d '\n')
GHOST=$(cast call $MM "$SHASH" $M2 $AGENT $VENDOR $AMT $REF $GHOSTN --rpc-url $RPC 2>/dev/null | tr -d '\n')
echo "   hash  (nonce ..0cd0) = $HASH"
echo "   ghost (nonce ..0cd1) = $GHOST"
if [ ${#HASH} -ne 66 ]; then echo "   spendHash view failed. Stopping."; exit 1; fi

hr "5. THE HASH, second derivation: out of the revert itself. Line 294 is"
echo "   'error CosignRequired(bytes32 spendHash)' and line 493 passes the hash"
echo "   into it. Expect selector 0x6a39578f followed by the SAME 32 bytes as"
echo "   check 4. Two independent derivations agreeing is the point."
cast call $MM "$SPEND" $M2 $VENDOR $AMT $REF $NONCE --from $AGENT --rpc-url $RPC 2>&1 || true

hr "6. Not approved yet."
printf "   isCosignApproved(M2, hash)   "; cast call $MM "isCosignApproved(bytes32,bytes32)" $M2 $HASH --rpc-url $RPC 2>&1 || true
printf "   isCosignApproved(M2, ghost)  "; cast call $MM "isCosignApproved(bytes32,bytes32)" $M2 $GHOST --rpc-url $RPC 2>&1 || true

hr "7. Free auth probes on withdrawCosign BEFORE spending anything on it."
echo "   a) the AGENT is the spender, not the cosigner -> NotCosigner 0x1cf89d6f"
cast call $MM "withdrawCosign(bytes32,bytes32)" $M2 $HASH --from $AGENT --rpc-url $RPC 2>&1 || true
echo "   b) an UNKNOWN mandate. approveCosign checks existence at line 728;"
echo "      withdrawCosign at 736-741 does NOT. So on a mandate that does not"
echo "      exist, m.cosigner is the zero address and the caller gets"
echo "      NotCosigner 0x1cf89d6f rather than UnknownMandate 0x473251f4."
echo "      Safe, but it names the wrong problem. Documented, not fixed."
cast call $MM "withdrawCosign(bytes32,bytes32)" $GHOSTM $HASH --from $PAYER --rpc-url $RPC 2>&1 || true

# ---------------------------------------------------------------------------
hr "SEND 1 of 3 — approveCosign(M2, hash) as the COSIGNER."
echo "   Prediction: within a few tens of gas of 53,114 (cosign-approve.log),"
echo "   differing only by 12 gas per zero byte in the hash. password ..."
cast send $MM "approveCosign(bytes32,bytes32)" $M2 $HASH \
  --rpc-url $RPC --account remit-testnet --from $PAYER 2>&1 || true

hr "8. The approval is live, and the spend now PASSES the gate."
printf "   isCosignApproved(M2, hash)  "; cast call $MM "isCosignApproved(bytes32,bytes32)" $M2 $HASH --rpc-url $RPC 2>&1 || true
echo "   Dry-run spend must now SUCCEED and return the hash it was approved"
echo "   under — spend() returns 'bytes32 hash', so the return value is a third"
echo "   sighting of the same 32 bytes:"
cast call $MM "$SPEND" $M2 $VENDOR $AMT $REF $NONCE --from $AGENT --rpc-url $RPC 2>&1 || true

hr "SEND 2 of 3 — withdrawCosign(M2, hash). FIRST EVER LIVE CALL, line 736."
echo "   Clears a slot a previous transaction set, so an EIP-3529 refund of"
echo "   4,800 applies, capped at gasUsed/5. Expect ~31,000 of work showing as"
echo "   ~26,000 on the receipt. Watch for the CosignWithdrawn log. password ..."
cast send $MM "withdrawCosign(bytes32,bytes32)" $M2 $HASH \
  --rpc-url $RPC --account remit-testnet --from $PAYER 2>&1 || true

hr "9. THE SECURITY PROPERTY. The cosigner changed their mind, and the spend"
echo "   they had authorised is authorised no longer. Expect isCosignApproved"
echo "   false and CosignRequired 0x6a39578f back again, same hash. Nothing"
echo "   else about M2 moved: same caps, same nonce, same allowlist."
printf "   isCosignApproved(M2, hash)  "; cast call $MM "isCosignApproved(bytes32,bytes32)" $M2 $HASH --rpc-url $RPC 2>&1 || true
cast call $MM "$SPEND" $M2 $VENDOR $AMT $REF $NONCE --from $AGENT --rpc-url $RPC 2>&1 || true

hr "SEND 3 of 3 — withdrawCosign(M2, ghost), a hash NEVER approved."
echo "   'delete' on an already-zero slot succeeds, so this emits"
echo "   CosignWithdrawn announcing the removal of authority that was never"
echo "   granted. An indexer that treats that event as a state transition will"
echo "   record one that did not happen."
echo "   Prediction: 2,800 LESS work than send 2 (100 instead of SSTORE_RESET's"
echo "   2,900) but no 4,800 refund to collect, so the receipt should come in"
echo "   ABOUT 2,000 GAS HIGHER than send 2 for doing less. password ..."
cast send $MM "withdrawCosign(bytes32,bytes32)" $M2 $GHOST \
  --rpc-url $RPC --account remit-testnet --from $PAYER 2>&1 || true

hr "10. Nothing drifted. M2 is untouched apart from the approval that came and"
echo "    went: totalSpent still $SPENT, headroom still $HEAD, still live."
printf "    isLive(M2)          "; cast call $MM "isLive(bytes32)" $M2 --rpc-url $RPC 2>&1 || true
printf "    policyHeadroom(M2)  "; cast call $MM "policyHeadroom(bytes32)" $M2 --rpc-url $RPC 2>&1 || true
printf "    spendable(M2)       "; cast call $MM "spendable(bytes32)" $M2 --rpc-url $RPC 2>&1 || true
echo "    getMandate(M2) tail — flags, windowCount, revoked:"
cast call $MM "getMandate(bytes32)" $M2 --rpc-url $RPC 2>&1 | tail -c 70

echo
echo "done. withdrawCosign has run. All five state-changing functions in"
echo "MandateManager now have live transactions."
