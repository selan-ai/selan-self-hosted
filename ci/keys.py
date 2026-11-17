"""The key pairs a server makes for itself, for the CI stand-ins: Ed25519 (signing) and X25519 (sealing).

The stand-in images carry Python's standard library only, so the public halves are derived here, from
RFC 8032 and RFC 7748. `python keys.py` checks them against those RFCs' test vectors.
"""
import hashlib

P = 2**255 - 19
D = -121665 * pow(121666, P - 2, P) % P
BASE = (
    15112221349535400772501151409588531511454012693041857206046113283949847762202,
    46316835694926478169428394003475163141307993866256225615783033603165251855960,
)


def _edwards_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return e * f % P, g * h % P, f * g % P, e * h % P


def ed25519_public(seed: bytes) -> bytes:
    digest = bytearray(hashlib.sha512(seed).digest()[:32])
    digest[0] &= 248
    digest[31] &= 127
    digest[31] |= 64
    scalar = int.from_bytes(digest, "little")
    point, add = (0, 1, 1, 0), (BASE[0], BASE[1], 1, BASE[0] * BASE[1] % P)
    while scalar:
        if scalar & 1:
            point = _edwards_add(point, add)
        add = _edwards_add(add, add)
        scalar >>= 1
    inverse = pow(point[2], P - 2, P)
    x, y = point[0] * inverse % P, point[1] * inverse % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def x25519_public(private: bytes) -> bytes:
    k = bytearray(private)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    n = int.from_bytes(k, "little")
    x1, x2, z2, x3, z3, swap = 9, 1, 0, 9, 1, 0
    for t in reversed(range(255)):
        bit = (n >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b, c, d = x2 + z2, x2 - z2, x3 + z3, x3 - z3
        aa, bb, da, cb = a * a, b * b, d * a, c * b
        e = aa - bb
        x3, z3 = (da + cb) ** 2 % P, x1 * (da - cb) ** 2 % P
        x2, z2 = aa * bb % P, e * (aa + 121665 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


if __name__ == "__main__":
    assert ed25519_public(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).hex() == \
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "RFC 8032 test 1"
    assert x25519_public(bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")).hex() == \
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "RFC 7748 6.1, Alice"
    assert x25519_public(bytes.fromhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")).hex() == \
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "RFC 7748 6.1, Bob"
    print("ok: Ed25519 and X25519 public keys match RFC 8032 and RFC 7748")
