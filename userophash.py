#!/usr/bin/env python3
"""Derive, off-chain and from first principles, what ERC-4337 EntryPoint v0.7
must answer for getUserOpHash(PackedUserOperation) on Arc Testnet.

Why this exists
---------------
Arc's paymaster documentation gives the EntryPoint v0.7 address but tells you to
"verify the EntryPoint v0.7 address for Arc testnet before use". `cast code` shows
16,035 bytes are deployed there, which proves *a* contract is present and nothing
about *which* contract. The usual next step is to compare the codehash against a
published reference, which needs network access this project's tooling does not have.

The check therefore runs the other way round. v0.7's hash is fully specified:

    UserOperationLib.encode(op) = abi.encode(
        op.sender, op.nonce,
        keccak256(op.initCode), keccak256(op.callData),
        op.accountGasLimits, op.preVerificationGas, op.gasFees,
        keccak256(op.paymasterAndData))              # signature excluded

    UserOperationLib.hash(op)   = keccak256(encode(op))
    EntryPoint.getUserOpHash(op) = keccak256(abi.encode(hash(op), address(this), block.chainid))

Every input is known, so the output is predictable without asking the chain. If the
deployed code returns the predicted value, it implements v0.7's exact algorithm over
v0.7's exact ABI. A stub, a proxy to something else, or a v0.6 EntryPoint cannot.

The version discrimination is in the selector as much as the value: v0.7 takes
`PackedUserOperation` (9 fields, two bytes32 gas words) and v0.6 takes
`UserOperation` (11 fields, five separate uint256 gas fields). They are different
functions with different selectors, printed below.

This is the same method as `evidence/expected-id.txt`, which predicted mandate 1's
ID before the transaction was sent: a claim is stronger when the number is written
down first.

Standard library only, by design — there is no keccak256 in Python's hashlib
(hashlib.sha3_256 is the NIST variant, which uses a different pad byte), so one is
implemented here and checked against three published vectors before it is trusted.
If those checks fail, the script exits before printing a hash.

Usage:  python3 userophash.py
"""

RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
    0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
    0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
    0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
    0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
    0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]

M = (1 << 64) - 1

ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
CHAINID = 5042002  # Arc Testnet


def _rotl(x, n):
    n %= 64
    return ((x << n) | (x >> (64 - n))) & M


def _keccak_f(A):
    for rnd in range(24):
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        D = [C[(x - 1) % 5] ^ _rotl(C[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                A[x][y] ^= D[x]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y][(2 * x + 3 * y) % 5] = _rotl(A[x][y], ROT[x][y])
        for x in range(5):
            for y in range(5):
                A[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) & M
        A[0][0] ^= RC[rnd]
    return A


def keccak256(data: bytes) -> bytes:
    """Ethereum's Keccak-256: rate 1088 bits, domain pad byte 0x01."""
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] ^= 0x80

    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(padded), rate):
        block = padded[off:off + rate]
        for i in range(rate // 8):
            A[i % 5][i // 5] ^= int.from_bytes(block[i * 8:(i + 1) * 8], "little")
        A = _keccak_f(A)

    out = bytearray()
    for i in range(4):
        out += A[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out)


def h(b: bytes) -> str:
    return "0x" + b.hex()


def word(n: int) -> bytes:
    return n.to_bytes(32, "big")


def main() -> None:
    print("Self-test: keccak256 against published vectors")
    vectors = [
        (b"", "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"),
        (b"abc", "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"),
        (b"testing", "0x5f16f4c7f149ac4f9510d9cf8cf384038ad348b3bcdc01915f95de12df9d1b02"),
    ]
    ok = True
    for data, want in vectors:
        got = h(keccak256(data))
        if got != want:
            ok = False
        print(f"  {'OK  ' if got == want else 'FAIL'} keccak256({data!r}) = {got}")
    if not ok:
        raise SystemExit("keccak256 implementation is wrong; nothing below is valid")

    print("\nSelectors — these are what make the check version-specific")
    v07 = b"getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))"
    v06 = b"getUserOpHash((address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes))"
    print(f"  v0.7  PackedUserOperation, 9 fields   {h(keccak256(v07)[:4])}")
    print(f"  v0.6  UserOperation, 11 fields        {h(keccak256(v06)[:4])}")

    # ---- the prediction, for an all-zero PackedUserOperation ----
    Z = bytes(32)
    empty = keccak256(b"")

    inner = (
        Z          # sender, left-padded address
        + Z        # nonce
        + empty    # keccak256(initCode),         initCode = 0x
        + empty    # keccak256(callData),         callData = 0x
        + Z        # accountGasLimits
        + Z        # preVerificationGas
        + Z        # gasFees
        + empty    # keccak256(paymasterAndData), paymasterAndData = 0x
    )
    assert len(inner) == 256
    op_hash = keccak256(inner)

    outer = op_hash + bytes(12) + bytes.fromhex(ENTRYPOINT[2:]) + word(CHAINID)
    assert len(outer) == 96
    expected = keccak256(outer)

    print("\nPrediction")
    print(f"  UserOperationLib.hash(zeroed op)  {h(op_hash)}")
    print(f"  chainId                           {CHAINID}")
    print(f"  entryPoint                        {ENTRYPOINT}")
    print(f"  EXPECTED getUserOpHash            {h(expected)}")

    # ---- the calldata, built by hand so no ABI encoder is trusted either ----
    head = (
        Z + Z                      # sender, nonce
        + word(0x120)              # offset: initCode
        + word(0x140)              # offset: callData
        + Z + Z + Z                # accountGasLimits, preVerificationGas, gasFees
        + word(0x160)              # offset: paymasterAndData
        + word(0x180)              # offset: signature
    )
    assert len(head) == 288
    calldata = keccak256(v07)[:4] + word(0x20) + head + bytes(32) * 4
    assert len(calldata) == 452

    print("\nTo check it on chain:")
    print(f"  cast call {ENTRYPOINT} \\")
    print(f"    --data {h(calldata)} \\")
    print("    --rpc-url https://rpc.testnet.arc.io")
    print("\nA match means the deployed code implements v0.7's algorithm over v0.7's ABI.")
    print("Result of running this on 2026-08-26 is in evidence/entrypoint.log — it matched.")


if __name__ == "__main__":
    main()
