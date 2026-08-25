#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# revoke-post.sh — task #44, part 2. Settle two loose ends from revoke.log.
#
# ONE real transaction: a REDUNDANT revoke of M3, which is already revoked.
#
# Why spend gas on a no-op. revoke.log gave a gas *estimate* of 28,702 for the
# second revoke against a *receipt* of 30,808 for the first. Estimates and
# receipts are not the same instrument, and this project has already published
# two modelled numbers as if they were measured. So: measure it. The receipt
# also settles whether MandateRevoked is re-emitted, which matters to anyone
# indexing the event.
#
# Cost is about 0.0006 USDC.
#
#   bash revoke-post.sh
# ---------------------------------------------------------------------------
set -u

RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0

M1=0x5095a776d5353647b4df9642fd09b33fc4b2f335532ad8309f996e21a584f68e
M3=0xd97ac489ddcff3d515cbdf5b5a04d283f09c78b6bfd4c0e0211e82372ad4af61
M4=0x196db6b1679927aa20e05db057939393741f22e8ea93a748c2706ea78b11312a
M5=0xf1836df74ff8dfc0f79180085b2fbf7442cf8a860ae7bc07a04347aa69063986

hr() { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }

hr "1. Which token is this deployment actually bound to? (line 151, immutable)"
cast call $MM "usdc()" --rpc-url $RPC 2>&1 || true

hr "2. THE ALLOWANCE THAT MATTERS. Line 868 reads allowance(payer, THIS"
echo "   CONTRACT), not allowance(payer, agent). My earlier check asked the"
echo "   wrong pair. Expect >= 500,000 for spendable(M3)=500,000 to have been"
echo "   correct before revocation."
USDCADDR=$(cast call $MM "usdc()" --rpc-url $RPC 2>/dev/null | sed 's/^0x000000000000000000000000/0x/')
echo "   usdc = $USDCADDR"
echo "   allowance(payer -> MandateManager):"
cast call $USDCADDR "allowance(address,address)" $PAYER $MM --rpc-url $RPC 2>&1 || true
echo "   allowance(payer -> agent)  [irrelevant to Remit; #42 leftover]:"
cast call $USDCADDR "allowance(address,address)" $PAYER $AGENT --rpc-url $RPC 2>&1 || true
echo "   balanceOf(payer)  [the other clamp, line 870]:"
cast call $USDCADDR "balanceOf(address)" $PAYER --rpc-url $RPC 2>&1 || true

hr "3. isLive — the predicate both views funnel through (line 782)."
echo "   M3 revoked -> false, M4 revoked -> false, M1 -> true, M5 -> true."
for m in $M3 $M4 $M1 $M5; do
  printf "   %s  " "${m:0:10}"
  cast call $MM "isLive(bytes32)" $m --rpc-url $RPC 2>&1 || true
done

hr "4. M1 is still healthy — the real ceiling an agent would read."
echo "   policyHeadroom / spendable:"
cast call $MM "policyHeadroom(bytes32)" $M1 --rpc-url $RPC 2>&1 || true
cast call $MM "spendable(bytes32)" $M1 --rpc-url $RPC 2>&1 || true

hr "THE SEND — redundant revoke of M3, already revoked. Estimate said 28,702."
echo "   First revoke receipt was 30,808. Watch gasUsed, and watch whether a"
echo "   MandateRevoked log appears anyway. password for remit-testnet ..."
cast send $MM "revoke(bytes32)" $M3 \
  --rpc-url $RPC --account remit-testnet --from $PAYER 2>&1 || true

hr "5. Nothing else moved: getMandate(M3) tail, and M1 still spendable."
cast call $MM "getMandate(bytes32)" $M3 --rpc-url $RPC 2>&1 | tail -c 70
cast call $MM "spendable(bytes32)" $M1 --rpc-url $RPC 2>&1 || true

echo; echo "done. Three revoke transactions now exist: M3, M4, and M3 again."
