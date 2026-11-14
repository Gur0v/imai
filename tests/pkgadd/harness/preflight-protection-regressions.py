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
    entry = tarfile.TarInfo("victim")
    entry.mode = 0o644
    entry.size = 11
    archive.addfile(entry, io.BytesIO(b"replacement"))
    entry = tarfile.TarInfo("new-directory/")
    entry.type = tarfile.DIRTYPE
    entry.mode = 0o700
    archive.addfile(entry)
plain = buffer.getvalue()
(root / "beta#1.pkg.tar.none").write_bytes(plain)
for suffix, encode, decode in [
    ("gzip", gzip.compress, gzip.decompress),
    ("bzip2", bz2.compress, bz2.decompress),
    ("xz", lzma.compress, lzma.decompress),
]:
    encoded = encode(plain + bytes(4 * 1024 * 1024))
    damaged = bytearray(encoded)
    damaged[-8] ^= 1
    for kind, stream in [("checksum", damaged), ("truncated", encoded[:-12])]:
        try:
            decode(stream)
        except (OSError, EOFError, ValueError, lzma.LZMAError):
            pass
        else:
            raise AssertionError("independent decoder accepted " + suffix)
        (root / (kind + "#1.pkg.tar." + suffix)).write_bytes(stream)
with tarfile.open(root / "chain#2.pkg.tar.none", "w") as archive:
    for path, kind, data in [("target", tarfile.REGTYPE, b"new"),
                             ("target/", tarfile.DIRTYPE, b""),
                             ("alias/file", tarfile.REGTYPE, b"safe")]:
        entry = tarfile.TarInfo(path)
        entry.type = kind
        entry.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
for filename, path in [("member#1.pkg.tar.none", "a\nb"),
                       ("bad\nname#1.pkg.tar.none", "victim"),
                       ("version#bad\nversion.pkg.tar.none", "victim")]:
    with tarfile.open(root / filename, "w") as archive:
        entry = tarfile.TarInfo(path)
        entry.size = 3
        archive.addfile(entry, io.BytesIO(b"bad"))
