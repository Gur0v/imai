import io
import pathlib
import tarfile

out = pathlib.Path('/tmp/archives')
out.mkdir()
cases = {
    'duplicate': [('file', 'one'), ('file', 'two')],
    'forward': [('alias', ('hard', 'file')), ('file', 'data')],
    'chain': [('file', 'data'), ('alias', ('hard', 'file')),
              ('second', ('hard', 'alias'))],
    'typechange': [('file', 'one'), ('file', ('symlink', 'target')),
                   ('target', 'data')],
    'alias': [('alias', ('symlink', 'real')), ('alias/file', 'data')],
    'spelling': [('./real//./file', 'data')],
    'hard-symlink': [('target', 'data'), ('alias', ('symlink', 'target')),
                     ('second', ('hard', 'alias'))],
}
for name, entries in cases.items():
    with tarfile.open(out / (name + '#1.pkg.tar.gz'), 'w:gz') as archive:
        for path, value in entries:
            entry = tarfile.TarInfo(path)
            entry.mode = 0o644
            if isinstance(value, tuple):
                entry.type = tarfile.LNKTYPE if value[0] == 'hard' else tarfile.SYMTYPE
                entry.linkname = value[1]
                archive.addfile(entry)
            else:
                payload = value.encode()
                entry.size = len(payload)
                archive.addfile(entry, io.BytesIO(payload))
