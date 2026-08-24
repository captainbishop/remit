#!/usr/bin/env bash
# COSTS GAS. Prompts for the remit-testnet (payer) keystore password THREE
# TIMES -- once per mandate. Only run this after gates-dry.sh has printed three
# mandateIds matching the three predictions.
#
# Grants are signed by the PAYER, so the account is remit-testnet, not remit-agent.
set -u
RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
PAYER=0xB56A7008dcDa0B7c603a2E1fA15fef58cff0Dcc0

CD3=$(sed -n 's/^CD3=//p' gates-dry.sh)
CD4=$(sed -n 's/^CD4=//p' gates-dry.sh)
CD5=$(sed -n 's/^CD5=//p' gates-dry.sh)

for pair in "3:$CD3" "4:$CD4" "5:$CD5"; do
  s=${pair%%:*}; cd=${pair#*:}
  echo "=== granting mandate at salt $s (password prompt $s of 5, payer keystore) ==="
  cast send $MM "$cd" --rpc-url $RPC --account remit-testnet --from $PAYER \
    > "gate-m$s.log" 2>&1
  echo "  exit=$?  $(grep -E '^(status|gasUsed)' "gate-m$s.log" | tr '\n' ' ')"
done

echo
echo "=== all three, live state (expect payer / perTxCap 500000 / flags 25,41,41) ==="
for m in 0xd97ac489ddcff3d515cbdf5b5a04d283f09c78b6bfd4c0e0211e82372ad4af61 \
         0x196db6b1679927aa20e05db057939393741f22e8ea93a748c2706ea78b11312a \
         0xf1836df74ff8dfc0f79180085b2fbf7442cf8a860ae7bc07a04347aa69063986; do
  echo "--- $m"
  cast call $MM "isLive(bytes32)(bool)" $m --rpc-url $RPC
done
