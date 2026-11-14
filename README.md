# imai

A C23 reimplementation of the CRUX utilities: `pkgadd`, `pkgrm`, `pkginfo`,
`pkgmk` and `rejmerge`. The latter two require Bash.

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
