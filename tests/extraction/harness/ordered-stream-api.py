import io
import tarfile

def make(name, entries):
    with tarfile.open('/tmp/' + name + '#1.pkg.tar', 'w') as archive:
        for path, value in entries:
            entry = tarfile.TarInfo(path)
            entry.mode = 0o755 if value is None else 0o644
            entry.mtime = 123456790 if isinstance(value, tuple) and value[0] == 'sym' else 123456789
            if value is None:
                entry.type = tarfile.DIRTYPE
            elif isinstance(value, tuple):
                entry.type = tarfile.LNKTYPE if value[0] == 'hard' else tarfile.SYMTYPE
                entry.linkname = value[1]
            else:
                value = value.encode()
                entry.size = len(value)
            archive.addfile(entry, io.BytesIO(value) if isinstance(value, bytes) else None)

make('ordered', [('real/', None), ('real/file', 'first'),
                 ('alias', ('sym', '/real')), ('alias/file', 'last'),
                 ('hard', ('hard', 'real/file')), ('chain', ('hard', 'hard')),
                 ('changed', 'regular'), ('changed', ('sym', 'real/file')),
                 ('nested/parent/file', 'nested')])
with tarfile.open('/tmp/payload#1.pkg.tar', 'w', format=tarfile.PAX_FORMAT) as archive:
    entry = tarfile.TarInfo('source'); entry.mode = 0o644; entry.size = 3
    archive.addfile(entry, io.BytesIO(b'old'))
    entry = tarfile.TarInfo('linked'); entry.type = tarfile.LNKTYPE
    entry.linkname = 'source'; entry.mode = 0o751; entry.size = 0
    archive.addfile(entry)
with tarfile.open('/tmp/unknown#1.pkg.tar', 'w') as archive:
    entry = tarfile.TarInfo('unknown'); entry.type = b's'; entry.mode = 0o600
    archive.addfile(entry)
with tarfile.open('/tmp/spelling#1.pkg.tar', 'w') as archive:
    for path, mode in [('./spelled/', 0o700), ('spelled/', 0o751)]:
        entry = tarfile.TarInfo(path); entry.type = tarfile.DIRTYPE
        entry.mode = mode; entry.mtime = 123456789
        archive.addfile(entry)
make('unsafe', [('victim', 'changed'), ('../outside/sentinel', 'bad')])
make('forward', [('partial/', None), ('partial/file', 'kept'),
                 ('forward', ('hard', 'future')), ('future', 'data')])
