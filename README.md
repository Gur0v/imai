# imai

imai is a drop-in replacement for CRUX pkgutils, written in C23.
It provides pkgadd, pkgrm, pkginfo, pkgmk and rejmerge and supports
existing CRUX packages, databases, Pkgfiles and configuration files.
pkgmk and rejmerge require Bash.

pkgmk adds optional recipe logs, build timing and tmpfs builds.
See the manuals for configuration, compatibility details and runtime dependencies.

## Build

Tested on Linux x86-64 with GCC 14.4 and glibc 2.40.
Requires make, dash, pkg-config, libarchive, libcrypto and their
static dependencies.

    make
    make DESTDIR=/some/other/path install

Omit DESTDIR for host installation. Back up /etc/pkgadd.conf,
/etc/pkgmk.conf and /etc/rejmerge.conf first; installation overwrites them.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). Copyright and attribution notices are
retained in the source files.
