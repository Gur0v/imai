#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires the pinned CRUX 3.8 static dependency sysroot and trusted GCC 14.4.
set -eu
sysroot=${1:?usage: pinned-libc-core-build.sh /absolute/sysroot}
case $sysroot in
/*) ;;
*) printf 'baseline-build: sysroot must be absolute\n' >&2; exit 1 ;;
esac
work=$(mktemp -d)
printf 'Baseline build artifacts: %s\n' "$work"
dash tests/pinned-libc-c23-probe.sh "$sysroot"
for source in main db pkginfo archive fs cancel pkgrm pkgadd install config; do
    ${CC:-cc} --sysroot="$sysroot" -B"$sysroot/usr/lib/" -std=c23 \
        -D_POSIX_C_SOURCE=200809L -DVERSION=\"0.1.0\" -O2 \
        -Wall -Wextra -Wpedantic -Wformat=2 \
        -Werror=implicit-function-declaration -fstack-protector-strong \
        -fstack-clash-protection -D_FORTIFY_SOURCE=3 \
        -c "src/$source.c" -o "$work/$source.o"
done
${CC:-cc} --sysroot="$sysroot" -B"$sysroot/usr/lib/" \
    -static -Wl,-z,relro,-z,now,-z,noexecstack,-t \
    -o "$work/pkgadd" "$work/main.o" "$work/db.o" \
    "$work/pkginfo.o" "$work/archive.o" "$work/fs.o" \
    "$work/cancel.o" "$work/pkgrm.o" "$work/pkgadd.o" \
    "$work/install.o" "$work/config.o" \
    -larchive -lz -lbz2 -llzma -lzstd -lssl -lcrypto -lexpat -lacl \
    -lz -ldl -lm -pthread >"$work/link.trace" 2>"$work/link.err"
gccdir=$(dirname "$("${CC:-cc}" -print-libgcc-file-name)")
while IFS= read -r input; do
    case $input in
    "$sysroot"/*|"$work"/*|"$gccdir"/*) ;;
    *) printf 'baseline-build: unexpected link input: %s\n' "$input" >&2
       exit 1 ;;
    esac
done <"$work/link.trace"
ln -s pkgadd "$work/pkginfo"
ln -s pkgadd "$work/pkgrm"
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --tmpfs /tmp \
    --ro-bind "$work" /tmp/candidate --chdir "$PWD" -- \
    /bin/dash tests/cli-common-options.sh /tmp/candidate
bwrap --unshare-all --die-with-parent --ro-bind / / --dev /dev --tmpfs /tmp \
    --ro-bind "$work" /tmp/candidate --chdir "$PWD" -- \
    /bin/dash tests/pkginfo-database-queries.sh /tmp/candidate
printf 'PASS: full static baseline build and CLI/database queries\n'
