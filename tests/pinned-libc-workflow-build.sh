#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
# Requires the pinned CRUX 3.8 sysroot, GCC 14.4, readelf and fixture dependencies.
set -eu
LC_ALL=C
export LC_ALL
sysroot=${1:?usage: pinned-libc-workflow-build.sh /absolute/sysroot}
case $sysroot in
/*) ;;
*) printf 'baseline-native: sysroot must be absolute\n' >&2; exit 1 ;;
esac
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
sysroot=$(CDPATH='' cd -- "$sysroot" && pwd)
cc=${CC:-cc}
gccdir=$(dirname "$("$cc" -print-libgcc-file-name)")
gccdir=$(CDPATH='' cd -- "$gccdir" && pwd)
work=$(mktemp -d)
printf 'Native baseline artifacts: %s\n' "$work"
trap 'exit 1' HUP INT TERM

manifest()
{
    cksum Makefile ./*.in src/*.[ch] scripts/pkgmk scripts/rejmerge \
        tools/embed-pkgmk.sh tests/*.sh config/* >"$1"
}

run_test()
{
    label=$1
    shift
    if "$@" >"$work/$label.log" 2>&1; then
        cat "$work/$label.log"
    else
        cat "$work/$label.log" >&2
        printf 'baseline-native: failed %s (artifacts %s)\n' "$label" "$work" >&2
        exit 1
    fi
}

manifest "$work/inputs.before"
"$cc" --version >"$work/compiler.txt"
uname -a >"$work/kernel.txt"
run_test libc-probe dash tests/pinned-libc-c23-probe.sh "$sysroot"
for command in pkgmk rejmerge; do
    dash tools/embed-pkgmk.sh "scripts/$command" "${command}_controller" \
        >"$work/$command-controller.h"
    set -- "src/$command.c"
    if [ -f "src/$command-workflow.c" ]; then
        set -- "$@" "src/$command-workflow.c"
    fi
    for source do
        object=${source##*/}
        "$cc" --sysroot="$sysroot" -B"$sysroot/usr/lib/" -std=c23 \
            -D_POSIX_C_SOURCE=200809L -DVERSION=\"0.1.0\" -O2 \
            -Wall -Wextra -Wpedantic -Wformat=2 \
            -Werror=implicit-function-declaration -fstack-protector-strong \
            -fstack-clash-protection -D_FORTIFY_SOURCE=3 -iquote "$work" \
            -c "$source" -o "$work/${object%.c}.o" \
            >"$work/${object%.c}.compile.log" 2>&1 || {
                cat "$work/${object%.c}.compile.log" >&2
                exit 1
            }
    done
    set -- "$work/$command.o"
    if [ -f "src/$command-workflow.c" ]; then
        set -- "$@" "$work/$command-workflow.o"
    fi
    if [ "$command" = pkgmk ]; then
        set -- "$@" -lcrypto -lz -ldl -pthread
    fi
    "$cc" --sysroot="$sysroot" -B"$sysroot/usr/lib/" \
        -static -Wl,-z,relro,-z,now,-z,noexecstack,-t \
        -o "$work/$command" "$@" \
        >"$work/$command.link.trace" 2>"$work/$command.link.err" || {
            cat "$work/$command.link.err" >&2
            exit 1
        }
    while IFS= read -r input; do
        case $input in
        "$sysroot"/*|"$work"/*|"$gccdir"/*) ;;
        *) printf 'baseline-native: unexpected link input: %s\n' "$input" >&2
           exit 1 ;;
        esac
    done <"$work/$command.link.trace"
    grep -Fx "$sysroot/usr/lib/crt1.o" "$work/$command.link.trace" >/dev/null
    grep -Fx "$sysroot/usr/lib/libc.a" "$work/$command.link.trace" >/dev/null
    readelf -hW "$work/$command" >"$work/$command.elf-header"
    readelf -lW "$work/$command" >"$work/$command.elf-program"
    readelf -dW "$work/$command" >"$work/$command.elf-dynamic"
    grep -E 'Class: +ELF64' "$work/$command.elf-header" >/dev/null
    grep -E 'Type: +EXEC ' "$work/$command.elf-header" >/dev/null
    grep -F 'Advanced Micro Devices X86-64' "$work/$command.elf-header" >/dev/null
    if grep -q INTERP "$work/$command.elf-program" || \
        grep -q NEEDED "$work/$command.elf-dynamic"; then
        printf 'baseline-native: %s is not static\n' "$command" >&2
        exit 1
    fi
    grep -E 'GNU_STACK +.* RW +0x' "$work/$command.elf-program" >/dev/null
    grep -q GNU_RELRO "$work/$command.elf-program"
    openssl dgst -sha256 "$work/$command" >"$work/$command.sha256"
done
run_test pkgmk-native dash tests/pkgmk-native-boundary-regressions.sh "$work/pkgmk"
run_test rejmerge-native dash tests/rejmerge-native-boundary-regressions.sh "$work/rejmerge"
run_test pkgmk-workflow dash tests/pkgmk-build-download-integration.sh "$root/../pkgutils/pkgmk.in" "$work/pkgmk"
run_test rejmerge-workflow dash tests/rejmerge-menu-merge-integration.sh "$work/rejmerge"
run_test rejmerge-pty dash tests/rejmerge-terminal-signal-regressions.sh "$work/rejmerge"
for command in pkgmk rejmerge; do
    if [ -f "tests/$command-callback-state-regressions.sh" ]; then
        run_test "$command-native-workflow" dash "tests/$command-callback-state-regressions.sh" \
            "$work/$command"
    fi
done
manifest "$work/inputs.after"
cmp "$work/inputs.before" "$work/inputs.after"
printf 'PASS: frozen static glibc 2.40 native pkgmk/rejmerge and sandboxed workflows\n'
