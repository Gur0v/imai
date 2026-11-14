import io, tarfile

def make(name, entries):
    with tarfile.open('/tmp/'+name+'#1.pkg.tar', 'w') as tar:
        for path, kind, target in entries:
            e=tarfile.TarInfo(path); e.mode=0o751; e.mtime=123456789
            e.type=kind
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE): e.linkname=target
            if kind==tarfile.REGTYPE:
                data=target.encode(); e.size=len(data)
                tar.addfile(e,io.BytesIO(data))
            else: tar.addfile(e)
make('magic', [('victim',tarfile.REGTYPE,'bad'),('proc/self/fd/0/x',tarfile.REGTYPE,'bad')])
make('plannedmagic', [('alias',tarfile.SYMTYPE,'/proc/self/fd/0'),('alias/x',tarfile.REGTYPE,'bad')])
make('loop', [('a',tarfile.SYMTYPE,'b'),('b',tarfile.SYMTYPE,'a'),('a/x',tarfile.REGTYPE,'bad')])
make('fifo', [('pipe',tarfile.FIFOTYPE,''), ('payload',tarfile.REGTYPE,'safe')])
make('many', [('d'+str(i)+'/',tarfile.DIRTYPE,'') for i in range(128)]+[('d0/file',tarfile.REGTYPE,'safe')])
make('duplicate', [('duplicate/',tarfile.DIRTYPE,''),('duplicate/',tarfile.DIRTYPE,'')])
make('mixed', [('real/file',tarfile.REGTYPE,'new'), ('alias/file',tarfile.REGTYPE,'kept'), ('after',tarfile.REGTYPE,'safe')])
make('dangling', [('victim',tarfile.REGTYPE,'new'), ('dangling',tarfile.REGTYPE,'kept')])
make('implicit', [('created/file',tarfile.REGTYPE,'new'), ('created/',tarfile.DIRTYPE,'')])
make('stale', [('src',tarfile.REGTYPE,'new'), ('dest',tarfile.LNKTYPE,'src'), ('dest/',tarfile.DIRTYPE,''), ('dest/file',tarfile.REGTYPE,'safe')])
make('failure', [('victim',tarfile.REGTYPE,'new'), ('bad',tarfile.SYMTYPE,'/safe'), ('bad/proc/self/fd/0/x',tarfile.REGTYPE,'bad')])
make('stalechain', [('target',tarfile.REGTYPE,'new'), ('target/',tarfile.DIRTYPE,''), ('aliaschain/file',tarfile.REGTYPE,'safe')])
make('relativechain', [('relative',tarfile.REGTYPE,'new'), ('relative/',tarfile.DIRTYPE,''), ('relalias/file',tarfile.REGTYPE,'safe')])
make('livechain', [('victim',tarfile.REGTYPE,'bad'), ('aliaschain/file',tarfile.REGTYPE,'bad')])
make('dirparent', [('parent',tarfile.REGTYPE,'old'), ('parent/child/',tarfile.DIRTYPE,''), ('parent/child/file',tarfile.REGTYPE,'safe')])
make('regularchild', [('parent',tarfile.REGTYPE,'old'), ('parent/child',tarfile.REGTYPE,'new')])
make('danglingdir', [('parent/child/',tarfile.DIRTYPE,'')])
make('finalcycle', [('cycle',tarfile.SYMTYPE,'cycle'), ('cycle/',tarfile.DIRTYPE,''), ('cycle/file',tarfile.REGTYPE,'safe')])
make('selfhard', [('self',tarfile.SYMTYPE,'self'), ('self',tarfile.LNKTYPE,'self'), ('self/file',tarfile.REGTYPE,'safe')])
make('aliasselfhard', [('realself/',tarfile.DIRTYPE,''), ('selfalias',tarfile.SYMTYPE,'realself'), ('realself/link',tarfile.SYMTYPE,'link'), ('selfalias/link',tarfile.LNKTYPE,'realself/link'), ('realself/link/file',tarfile.REGTYPE,'safe')])
make('absentsource', [('missinglink',tarfile.LNKTYPE,'absent'), ('missinglink/file',tarfile.REGTYPE,'safe')])
make('finalmagic', [('victim',tarfile.REGTYPE,'bad'), ('proc/self/fd/0/',tarfile.DIRTYPE,'')])
make('plannedfinalmagic', [('victim',tarfile.REGTYPE,'bad'), ('magicfinal',tarfile.SYMTYPE,'proc/self/fd/0'), ('magicfinal/',tarfile.DIRTYPE,'')])
