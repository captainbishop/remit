#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# revoke-pre.sh — read-only reconnaissance before task #44 (revoke).
#
# Nothing here sends a transaction. No keystore password is needed. Every call
# is `cast call` or `cast estimate`, which simulate against live state and cost
# nothing. Run this FIRST: revoke is permanent and irreversible, so we confirm
# the pre-state and the authorisation boundary before burning a mandate.
#
#   bash revoke-pre.sh
# ---------------------------------------------------------------------------
set -u

RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de

M1=0x5095a776d5353647b4df9642fd09b33fc4b2f335532ad8309f996e21a584f68e
M3=0xd97ac489ddcff3d515cbdf5b5a04d283f09c78b6bfd4c0e0211e82372ad4af61
M4=0x196db6b1679927aa20e05db057939393741f22e8ea93a748c2706ea78b11312a

N1=0x0000000000000000000000000000000000000000000000000000000000000001
R1=0x0000000000000000000000000000000000000000000000000000000000000002

SPEND="spend(bytes32,address,uint256,bytes32,bytes32)"

hr() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

hr "1. M3 pre-state — getMandate. Last field is 'revoked', expect false."
cast call $MM "getMandate(bytes32)" $M3 --rpc-url $RPC 2>&1 || true

hr "2. M3 pre-state — a spend today. Expect the GATE error IdentityNotHeld 0x6eab756c."
cast call $MM "$SPEND" $M3 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "3. M4 pre-state — expect the GATE error CredentialMissing 0x9e586322."
cast call $MM "$SPEND" $M4 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "4. AUTH BOUNDARY — revoke from the VENDOR (neither payer nor spender)."
echo "   Expect revert NotPayer 0x1435e357."
cast call $MM "revoke(bytes32)" $M3 --from $VENDOR --rpc-url $RPC 2>&1 || true

hr "5. AUTH — revoke M3 from the PAYER. Expect success (empty return)."
cast call $MM "revoke(bytes32)" $M3 --from $PAYER --rpc-url $RPC 2>&1 || true

hr "6. AUTH — revoke M4 from the AGENT. Expect SUCCESS: line 704 lets the"
echo "   spender renounce its own authority. This is the surprising one."
cast call $MM "revoke(bytes32)" $M4 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "7. Gas estimate, M3 from payer. Predicted 28,076 (21,576 intrinsic"
echo "   + 5,000 storage + 1,500 LOG3) plus dispatch."
cast estimate $MM "revoke(bytes32)" $M3 --from $PAYER --rpc-url $RPC 2>&1 || true

hr "8. Gas estimate, M4 from agent — should match M3's to the gas."
cast estimate $MM "revoke(bytes32)" $M4 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "9. Control — M1 is ungated and unrevoked. A spend must still SUCCEED,"
echo "   returning a spendHash. This is what makes the reverts above evidence."
cast call $MM "$SPEND" $M1 $VENDOR 10000 $N1 $R1 --from $AGENT --rpc-url $RPC 2>&1 || true

hr "10. Views before revocation: spendable / policyHeadroom on M3."
cast call $MM "spendable(bytes32)" $M3 --rpc-url $RPC 2>&1 || true
cast call $MM "policyHeadroom(bytes32)" $M3 --rpc-url $RPC 2>&1 || true

hr "11. UnknownMandate check — revoke a salt we never granted."
echo "   Expect revert UnknownMandate, NOT NotPayer: line 703 precedes 704."
cast call $MM "revoke(bytes32)" \
  0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  --from $PAYER --rpc-url $RPC 2>&1 || true

echo; echo "done — nothing was sent, no state changed."
