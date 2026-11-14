# imai

A C23 replacement for CRUX pkgutils: `pkgadd`, `pkgrm`, `pkginfo`,
`pkgmk` and `rejmerge`. Supports existing CRUX packages, databases,
Pkgfiles and configuration files. The latter two commands require Bash.

## Features

- Full archive validation and destination preflight before installation.
- Root-scoped filesystem operations for package installation and removal.
- Optional tmpfs builds through `PKGMK_TMPFS="yes"` in pkgmk.conf.
- curl, wget, Wget2 and aria2 download backends.

See the manuals for configuration and compatibility details.

## Building and installing

Tested on Linux x86-64 with GCC 14.4 and glibc 2.40. Build dependencies:
make, dash, pkg-config, libarchive, libcrypto and their static dependencies.

```sh
make
make DESTDIR=/some/other/path install
```

Omit `DESTDIR` for host installation; back up `/etc/pkgadd.conf`,
`/etc/pkgmk.conf` and `/etc/rejmerge.conf` first, as installation overwrites them.
See the manuals for usage, runtime dependencies and limitations.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Copyright and attribution notices are
retained in the source files.
