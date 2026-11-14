#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -efu
harness=$(CDPATH='' cd -- "$(dirname "$0")/harness" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
# shellcheck disable=SC2046,SC2086
${CC:-cc} -std=c23 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    ${TEST_CFLAGS:-} -iquote src "$harness/failure-regressions.c" \
    src/commands/pkgadd/pkgadd.c src/commands/pkgrm/pkgrm.c src/commands/ldconfig.c src/archive/archive.c src/extraction/install.c src/config/config.c src/db/db.c \
    src/fs/fs.c src/cancel/cancel.c -Wl,--wrap=pipe2,--wrap=read,--wrap=fork,--wrap=waitpid,--wrap=fchdir,--wrap=db_commit,--wrap=cancel_child,--wrap=execl \
    $(pkg-config --cflags --libs libarchive) -lz -lbz2 ${TEST_LDFLAGS:-} -o "$work/failures"
printf '#!/bin/dash\nexit 0\n' >"$work/ldconfig"
chmod 755 "$work/ldconfig"
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind "$work/failures" /tmp/failures \
    --ro-bind "$work/ldconfig" /sbin/ldconfig -- /bin/dash -eu -c '
mkdir /tmp/payload
printf payload >/tmp/payload/victim
bsdtar -cf /tmp/alpha#1.pkg.tar.gz -C /tmp/payload victim
for command in pkgrm pkgadd; do
    for failure in pipe fork wait child signals exec read commit combined; do
        [ "$command:$failure" != pkgadd:combined ] || continue
        mkdir -p /tmp/root/var/lib/pkg /tmp/root/etc
        : >/tmp/root/etc/ld.so.conf
        if [ "$command" = pkgrm ]; then
            printf "alpha\n1\nvictim\n\nzeta\n2\nshared\n\n" >/tmp/root/var/lib/pkg/db
            : >/tmp/root/victim
            printf "zeta\n2\nshared\n\n" >/tmp/expected
        else
            printf "zeta\n2\nshared\n\n" >/tmp/root/var/lib/pkg/db
            printf "alpha\n1\nvictim\n\nzeta\n2\nshared\n\n" >/tmp/expected
        fi
        cp /tmp/root/var/lib/pkg/db /tmp/before
        /tmp/failures "$command" "$failure" >/tmp/out 2>/tmp/err || {
            printf "FAIL: %s %s\n" "$command" "$failure"
            cat /tmp/err
            exit 1
        }
        [ ! -s /tmp/out ]
        grep "termination request deferred" /tmp/err >/dev/null
        case $failure in
        pipe) grep "could not prepare helper:" /tmp/err >/dev/null ;;
        fork) grep "fork() failed:" /tmp/err >/dev/null ;;
        wait|combined) grep "waitpid() failed:" /tmp/err >/dev/null ;;
        child|signals) grep -E "could not .*root:|could not prepare helper:|could not restore helper signals:" /tmp/err >/dev/null ;;
        exec) grep "could not execute /sbin/ldconfig:" /tmp/err >/dev/null ;;
        read) grep "could not read helper status:" /tmp/err >/dev/null ;;
        esac
        case $failure in
        commit|combined)
            cmp /tmp/before /tmp/root/var/lib/pkg/db
            [ ! -e /tmp/root/var/lib/pkg/db.backup ]
            grep "could not write database:" /tmp/err >/dev/null
            ;;
        *)
            cmp /tmp/expected /tmp/root/var/lib/pkg/db
            cmp /tmp/before /tmp/root/var/lib/pkg/db.backup
            ;;
        esac
        if [ "$command" = pkgrm ]; then
            [ ! -e /tmp/root/victim ]
        elif [ "$failure" != commit ] && [ "$failure" != combined ]; then
            cmp /tmp/payload/victim /tmp/root/victim
        fi
        rm -rf /tmp/root
    done
done
'
printf 'PASS: helper failures finalize database and restore cancellation/locks\n'
