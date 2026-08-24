#!/usr/bin/env bash
# FREE. No password, no gas. Run this AFTER gates-send.sh.
# Dry-runs a spend against each gated mandate. Every one MUST revert, and the
# selector in the error data is the whole point of the test.
set -u
RPC=https://rpc.testnet.arc.io
MM=0x3744E93B9e796E05CB66311d897559B6F3860196
AGENT=0x88549F2128f16BdA5aA0b6aCBe5e70F8E876bbd0
VENDOR=0x000000000000000000000000000000000000c0de
Z32=0x0000000000000000000000000000000000000000000000000000000000000000
N1=0x0000000000000000000000000000000000000000000000000000000000000001

M3=0xd97ac489ddcff3d515cbdf5b5a04d283f09c78b6bfd4c0e0211e82372ad4af61
M4=0x196db6b1679927aa20e05db057939393741f22e8ea93a748c2706ea78b11312a
M5=0xf1836df74ff8dfc0f79180085b2fbf7442cf8a860ae7bc07a04347aa69063986

try () {
  echo "--- $1"
  echo "    expecting $2"
  cast call $MM "spend(bytes32,address,uint256,bytes32,bytes32)" \
    "$3" $VENDOR 10000 $Z32 $N1 --from $AGENT --rpc-url $RPC \
    && echo "    *** DID NOT REVERT -- the gate did not fire ***"
}

echo "=== are the three mandates live at all? (expect true,true,true) ==="
for m in $M3 $M4 $M5; do
  cast call $MM "isLive(bytes32)(bool)" $m --rpc-url $RPC
done
echo

try "salt 3 identity: agent 16330 belongs to 0x2F061aA5..., not our delegate" \
    "IdentityNotHeld()  0x6eab756c" $M3

try "salt 4 credential: live response is 1, gate demands 100" \
    "CredentialMissing()  0x9e586322" $M4

try "salt 5 credential: response 1 passes minResponse 1, then 97-day age fails" \
    "CredentialStale()  0xca36b069" $M5

echo
echo "=== control: mandate 1 has no gates, same shape of call should SUCCEED ==="
cast call $MM "spend(bytes32,address,uint256,bytes32,bytes32)" \
  0x5095a776d5353647b4df9642fd09b33fc4b2f335532ad8309f996e21a584f68e \
  $VENDOR 10000 $Z32 0x0000000000000000000000000000000000000000000000000000000000000009 \
  --from $AGENT --rpc-url $RPC
