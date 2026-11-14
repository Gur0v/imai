import bz2
import gzip
import io
import lzma
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
    entry = tarfile.TarInfo("file")
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b"x"))
plain = buffer.getvalue()
for prefix in ("BZh-file", "LZIP-file"):
    other = io.BytesIO()
    with tarfile.open(fileobj=other, mode="w") as archive:
        entry = tarfile.TarInfo(prefix)
        archive.addfile(entry)
    (root / (prefix + "#1.pkg.tar.none")).write_bytes(other.getvalue())
padded = plain + bytes(4 * 1024 * 1024)
for suffix, encode, decode, data in [
    ("gzip", gzip.compress, gzip.decompress, plain),
    ("bzip2", bz2.compress, bz2.decompress, padded),
    ("xz", lzma.compress, lzma.decompress, padded),
]:
    encoded = encode(data)
    (root / ("valid#1.pkg.tar." + suffix)).write_bytes(encoded)
    damaged = bytearray(encoded)
    damaged[-8] ^= 1
    for kind, stream in [("checksum", damaged),
                         ("truncated", encoded[:-12])]:
        try:
            decode(stream)
        except (OSError, EOFError, ValueError, lzma.LZMAError):
            pass
        else:
            raise AssertionError("independent decoder accepted " + suffix)
        (root / (kind + "#1.pkg.tar." + suffix)).write_bytes(stream)
second = bytearray(gzip.compress(bytes(1024)))
second[-8] ^= 1
(root / "member-checksum#1.pkg.tar.gzip").write_bytes(
    gzip.compress(plain) + second)
(root / "members#1.pkg.tar.gzip").write_bytes(
    gzip.compress(plain[:512]) + gzip.compress(plain[512:]))
(root / "trailing#1.pkg.tar.gzip").write_bytes(gzip.compress(plain) + b"trailing")
(root / "nested#1.pkg.tar.xz").write_bytes(lzma.compress(gzip.compress(plain)))
(root / "nested-checksum#1.pkg.tar.xz").write_bytes(
    lzma.compress((root / "checksum#1.pkg.tar.gzip").read_bytes()))
size_bad = bytearray(gzip.compress(plain))
size_bad[-4] ^= 1
try:
    gzip.decompress(size_bad)
except OSError:
    pass
else:
    raise AssertionError("independent decoder accepted invalid ISIZE")
(root / "size#1.pkg.tar.gzip").write_bytes(size_bad)
