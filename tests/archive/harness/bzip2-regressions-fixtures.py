import bz2
import gzip
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w") as archive:
    entry = tarfile.TarInfo("file")
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b"x"))
first = bz2.compress(raw.getvalue())
second = bz2.compress(bytes(4096))
valid = first + second
assert bz2.decompress(valid) == raw.getvalue() + bytes(4096)
(root / "valid#1.pkg.tar.bz2").write_bytes(valid)
for length in (3, 4, 12, len(second) - 1):
    broken = first + second[:length]
    try:
        bz2.decompress(broken)
    except (OSError, EOFError, ValueError):
        pass
    else:
        raise AssertionError("independent decoder accepted truncated member")
    (root / ("truncated-" + str(length) + "#1.pkg.tar.bz2")).write_bytes(broken)
    (root / ("nested-" + str(length) + "#1.pkg.tar.gz")).write_bytes(
        gzip.compress(broken))
damaged = bytearray(second)
# The bzip2 block CRC starts immediately after its six-byte block marker.
damaged[10] ^= 1
try:
    bz2.decompress(damaged)
except OSError:
    pass
else:
    raise AssertionError("independent decoder accepted corrupted member CRC")
(root / "checksum-member#1.pkg.tar.bz2").write_bytes(first + damaged)
