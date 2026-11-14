#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Usage: dash tests/toolchain/openssl-static-closure-build.sh archive NEW-output [absolute-sysroot]
# Requires GCC, Perl, make, tar, OpenSSL, readelf and bubblewrap; no downloads.
# Output retains source, build/logs and stage/usr/{include/openssl,lib/libcrypto.a}.
set -eu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
LC_ALL=C
export LC_ALL
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || {
    printf 'usage: %s archive NEW-output [absolute-sysroot]\n' "$0" >&2
    exit 1
}
archive=$(CDPATH='' cd -- "$(dirname "$1")" && pwd)/$(basename "$1")
output=$2
sysroot=${3:-}
case $sysroot in
'') ;;
/*) sysroot=$(CDPATH='' cd -- "$sysroot" && pwd) ;;
*) printf 'openssl-closure: sysroot must be absolute\n' >&2; exit 1 ;;
esac
expected=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
actual=$(openssl dgst -sha256 "$archive")
[ "${actual##* }" = "$expected" ] || {
    printf 'openssl-closure: source checksum mismatch\n' >&2
    exit 1
}
# mkdir must fail for any existing destination, including an empty directory.
mkdir -- "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
mkdir "$output/source" "$output/build" "$output/stage" "$output/control"
printf '%s\n' "$expected" >"$output/source.sha256"
printf '%s\n' "${sysroot:-native}" >"$output/sysroot.txt"
cat >"$output/control/cc" <<'EOF'
#!/bin/dash
set -eu
if [ -n "$PINNED_SYSROOT" ]; then
    exec gcc --sysroot="$PINNED_SYSROOT" -B"$PINNED_SYSROOT/usr/lib/" "$@"
fi
exec gcc "$@"
EOF
cat >"$output/control/build.sh" <<'EOF'
#!/bin/dash
set -eu
umask 022
export SOURCE_DATE_EPOCH=1775001600 ZERO_AR_DATE=1
export CC=/tmp/work/control/cc
cd /tmp/work/build
gcc --version > /tmp/work/compiler.txt
uname -a > /tmp/work/kernel.txt
tar -xzf /tmp/input.tar.gz -C /tmp/work/source
source=/tmp/work/source/openssl-3.6.5
grep -Fx 'MAJOR=3' "$source/VERSION.dat" >/dev/null
grep -Fx 'MINOR=6' "$source/VERSION.dat" >/dev/null
grep -Fx 'PATCH=5' "$source/VERSION.dat" >/dev/null
perl "$source/Configure" linux-x86_64 no-shared no-dso no-module \
    no-engine no-sock no-tests --prefix=/usr --libdir=lib \
    -O2 -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=3 \
    -ffile-prefix-map=/tmp/work=. -fdebug-prefix-map=/tmp/work=.
make -j2 ARFLAGS=rcD RANLIB='ranlib -D' build_generated libcrypto.a
mkdir -p /tmp/work/stage/usr/include/openssl /tmp/work/stage/usr/lib
for header in "$source"/include/openssl/*.h include/openssl/*.h; do
    cp "$header" /tmp/work/stage/usr/include/openssl/
done
cp libcrypto.a /tmp/work/stage/usr/lib/
chmod 644 /tmp/work/stage/usr/include/openssl/*.h /tmp/work/stage/usr/lib/libcrypto.a
"$CC" -static -I/tmp/work/stage/usr/include /tmp/work/control/probe.c \
    /tmp/work/stage/usr/lib/libcrypto.a -pthread -Wl,-t \
    -o /tmp/work/probe > /tmp/work/probe.link.trace 2> /tmp/work/probe.link.err
if [ -n "$PINNED_SYSROOT" ]; then
    gccdir=$(dirname "$(gcc -print-libgcc-file-name)")
    gccdir=$(CDPATH='' cd -- "$gccdir" && pwd)
    while IFS= read -r input; do
        case $input in
        "$PINNED_SYSROOT"/*|"$gccdir"/*|/tmp/work/*|/tmp/*) ;;
        *) printf 'unexpected pinned link input: %s\n' "$input" >&2; exit 1 ;;
        esac
    done < /tmp/work/probe.link.trace
    grep -Fx "$PINNED_SYSROOT/usr/lib/crt1.o" /tmp/work/probe.link.trace >/dev/null
    grep -Fx "$PINNED_SYSROOT/usr/lib/libc.a" /tmp/work/probe.link.trace >/dev/null
fi
if grep -E 'dlopen|getaddrinfo|gethostbyname' /tmp/work/probe.link.err; then
    exit 1
fi
nm -u /tmp/work/stage/usr/lib/libcrypto.a > /tmp/work/libcrypto.undefined
if grep -E ' U (dlopen|getaddrinfo|gethostbyname)(@.*)?$' /tmp/work/libcrypto.undefined; then
    exit 1
fi
readelf -lW /tmp/work/probe > /tmp/work/probe.elf-program
readelf -dW /tmp/work/probe > /tmp/work/probe.elf-dynamic
if grep -q INTERP /tmp/work/probe.elf-program || grep -q NEEDED /tmp/work/probe.elf-dynamic; then
    printf 'openssl-closure: probe is not static\n' >&2
    exit 1
fi
/tmp/work/probe
openssl dgst -sha256 /tmp/work/stage/usr/lib/libcrypto.a > /tmp/work/libcrypto.sha256
EOF
cp "$harness/openssl-static-closure-probe.c" "$output/control/probe.c"
chmod 755 "$output/control/cc"
set --
if [ -n "$sysroot" ]; then
    set -- --ro-bind "$sysroot" /tmp/pinned-sysroot
    sysroot=/tmp/pinned-sysroot
fi
if bwrap --unshare-all --die-with-parent --ro-bind / / \
    --tmpfs /tmp --bind "$output" /tmp/work \
    --ro-bind "$archive" /tmp/input.tar.gz \
    "$@" --proc /proc --dev /dev --chdir /tmp/work \
    --clearenv --setenv PATH /usr/bin:/bin --setenv HOME /tmp \
    --setenv LC_ALL C --setenv TZ UTC --setenv PINNED_SYSROOT "$sysroot" \
    /bin/dash /tmp/work/control/build.sh >"$output/build.log" 2>&1; then
    printf 'PASS: reduced OpenSSL 3.6.5 static closure: %s/stage\n' "$output"
else
    printf 'openssl-closure: failed; see %s/build.log\n' "$output" >&2
    exit 1
fi
