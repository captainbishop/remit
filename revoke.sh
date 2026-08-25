#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# revoke.sh — task #44. Exercise revoke() on the live deployment.
#
# TWO real transactions, and they are PERMANENT:
#   send 1  revoke M3, signed by the PAYER
#   send 2  revoke M4, signed by the AGENT   <- the delegate renouncing itself
#
# Both mandates are already gate-blocked and unspendable, so nothing of value
# is destroyed. M1 (working), M2 (cosigned) and M5 (staleness) are left alive.
#
# You will be prompted for the keystore password twice. Because this is a
# script invoked as a single command, the prompts are safe — they are not
# competing with queued terminal input.
#
#   bash revoke.sh
# ---------------------------------------------------------------------------
set -u

RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
USDC=0x3600000000000000000000000000000000000000
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de

M1=0x5095a776d5353647b4df9642fd09b33fc4b2f335532ad8309f996e21a584f68e
M3=0xd97ac489ddcff3d515cbdf5b5a04d283f09c78b6bfd4c0e0211e82372ad4af61
M4=0x196db6b1679927aa20e05db057939393741f22e8ea93a748c2706ea78b11312a
M5=0xf1836df74ff8dfc0f79180085b2fbf7442cf8a860ae7bc07a04347aa69063986

N1=0x0000000000000000000000000000000000000000000000000000000000000001
R1=0x0000000000000000000000000000000000000000000000000000000000000002
SPEND="spend(bytes32,address,uint256,bytes32,bytes32)"

hr() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

hr "0a. Current allowance payer -> agent. spendable() returned 500,000 in the"
echo "    pre-run, which only makes sense if this is >= 500,000."
cast call $USDC "allowance(address,address)" $PAYER $AGENT --rpc-url $RPC 2>&1 || true

hr "0b. Confirm M3 and M4 are still unrevoked before we touch them."
cast call $MM "getMandate(bytes32)" $M3 --rpc-url $RPC 2>&1 | tail -c 70
cast call $MM "getMandate(bytes32)" $M4 --rpc-url $RPC 2>&1 | tail -c 70

# ---------------------------------------------------------------------------
hr "SEND 1 of 2 — revoke M3 as the PAYER.  Estimate was 31,160."
echo "    password for remit-testnet ..."
cast send $MM "revoke(bytes32)" $M3 \
  --rpc-url $RPC --account remit-testnet --from $PAYER 2>&1 || true

hr "SEND 2 of 2 — revoke M4 as the AGENT.  Estimate was 33,301."
echo "    The delegate renouncing its own authority. password for remit-agent ..."
cast send $MM "revoke(bytes32)" $M4 \
  --rpc-url $RPC --account remit-agent --from $AGENT 2>&1 || true

# ---------------------------------------------------------------------------
hr "1. THE KEY CHECK — M3 spend must now revert Revoked 0x44825a4b,"
echo "   NOT the gate error 0x6eab756c it returned before. A changed selector"
echo "   proves line 444 short-circuits ahead of the gates at 473-474."
cast call $MM "$SPEND" $M3 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "2. Same for M4: was CredentialMissing 0x9e586322, expect 0x44825a4b."
cast call $MM "$SPEND" $M4 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "3. M5 is UNTOUCHED — must still revert CredentialStale 0xca36b069."
echo "   Proves we revoked exactly what we meant to and nothing else."
cast call $MM "$SPEND" $M5 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "4. Control — M1 must STILL SUCCEED and return a spendHash."
cast call $MM "$SPEND" $M1 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "5. getMandate(M3) — last word must now be 1 (revoked)."
cast call $MM "getMandate(bytes32)" $M3 --rpc-url $RPC 2>&1 || true

hr "6. IDEMPOTENCY — revoke M3 again. Line 705 has no already-revoked guard,"
echo "   so this should SUCCEED and re-emit MandateRevoked rather than revert."
cast call $MM "revoke(bytes32)" $M3 --from $PAYER --rpc-url $RPC 2>&1 || true

hr "7. Gas for a second revoke. Writing true over true is a no-op SSTORE (100),"
echo "   so this should come in ~2,800 BELOW the 31,160 first revoke."
cast estimate $MM "revoke(bytes32)" $M3 --from $PAYER --rpc-url $RPC 2>&1 || true

hr "8. Can the AGENT revoke an ALREADY-revoked mandate? Still authorised."
cast call $MM "revoke(bytes32)" $M3 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "9. Views after revocation — spendable / policyHeadroom on M3."
echo "   Both returned 500,000 before. Does either notice the revocation?"
cast call $MM "spendable(bytes32)" $M3 --rpc-url $RPC 2>&1 || true
cast call $MM "policyHeadroom(bytes32)" $M3 --rpc-url $RPC 2>&1 || true

hr "10. Auth boundary still holds post-revocation: vendor -> NotPayer 0x1435e357."
cast call $MM "revoke(bytes32)" $M3 --from $VENDOR --rpc-url $RPC 2>&1 || true

echo; echo "done. Two mandates revoked, permanently. M1, M2 and M5 remain live."
