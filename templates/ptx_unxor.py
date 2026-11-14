# Pro Tools session files are XOR-obfuscated (see ptformat in Ardour); undo that.
import sys
def unxor(d):
    t, v = d[0x12], d[0x13]
    def delta(val, mul, neg):
        for i in range(256):
            if (i * mul) & 0xff == val: return (-i if neg else i)
        raise SystemExit("no delta")
    dl = delta(v, 53, False) if t == 1 else delta(v, 11, True)
    key = [(i * dl) & 0xff for i in range(256)]
    out = bytearray(d)
    for i in range(0x14, len(d)):
        k = key[i & 0xff] if t == 1 else key[(i >> 12) & 0xff]
        out[i] = d[i] ^ k
    return bytes(out)
if __name__ == "__main__":
    open(sys.argv[2], 'wb').write(unxor(open(sys.argv[1], 'rb').read()))
