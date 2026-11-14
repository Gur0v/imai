#!/bin/bash
# shellcheck disable=SC2329
# SPDX-License-Identifier: GPL-3.0-or-later
#
#  pkgutils
#
#  Copyright (c) 2000-2005 Per Liden
#  Copyright (c) 2006-2021 by CRUX team (http://crux.nu)
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307,
#  USA.

info() { info_n "$1"; printf '\n'; }
info_n() { printf '=======> %s' "$1"; }
fail() { printf '%s: %s\n' "$REJMERGE_COMMAND" "$1" >&2; exit 1; }

rejmerge_diff()
{
	diff -u "$1" "$2" > "$3"
}

rejmerge_merge()
{
	diff --old-group-format='%<' --new-group-format='%>' \
	    --changed-group-format="<<<<< MERGE CONFLICT $1 >>>>>
%<<<<<< MERGE CONFLICT $2 >>>>>
%><<<<< END MERGE CONFLICT >>>>>
" "$1" "$2" > "$3"
	status=$?
	[ "$status" -le 1 ] || return "$status"
	REJMERGE_MERGE_INFO="$(grep -c \
	    '^<<<<< END MERGE CONFLICT >>>>>$' "$3") merge conflict(s)."
}

request()
{
	REJMERGE_MERGE_INFO=
	case $1 in
	diff)
		if rejmerge_diff "$2" "$3" "$TMPFILE"; then result=0; else result=$?; fi
		;;
	merge)
		if rejmerge_merge "$2" "$3" "$TMPFILE"; then result=0; else result=$?; fi
		;;
	edit)
		set -f
		# Preserve upstream EDITOR command-and-arguments splitting.
		# shellcheck disable=SC2086
		${EDITOR:-vi} "$TMPFILE"
		result=$?
		set +f
		;;
	esac
	case $1:$result in
	edit:0|diff:0|diff:1|merge:0|merge:1) ;;
	*) fail "$1 command failed (status $result)" ;;
	esac
}

atexit()
{
	[ -z "${TMPFILE-}" ] || rm -f "$TMPFILE"
	[ -z "${work-}" ] || rm -rf "$work"
}

interrupted()
{
	printf '\n'
	info 'Aborted.'
	exit 1
}

metadata()
{
	if [ "$(type -t stat)" = function ]; then
		stat -L -c '%a %u %g' "$1"
	else
		"$REJMERGE_NATIVE" --imai-internal metadata "$1"
	fi
}

copy_permissions()
{
	values=$(metadata "$1") || fail "cannot inspect $1"
	# shellcheck disable=SC2086
	set -- "$2" $values
	if [ "$(type -t chown)" = function ] ||
	    [ "$(type -t chmod)" = function ]; then
		if [ -L "$1" ]; then
			chown -h "$3:$4" "$1" || fail "cannot set owner of $1"
		elif ! chown "$3:$4" "$1" || ! chmod "$2" "$1"; then
			fail "cannot set permissions of $1"
		fi
	elif [ -L "$1" ]; then
		"$REJMERGE_NATIVE" --imai-internal set-permissions "$1" "$2" "$3" "$4" ||
		    fail "cannot set owner of $1"
	else
		"$REJMERGE_NATIVE" --imai-internal set-permissions "$1" "$2" "$3" "$4" ||
		    fail "cannot set permissions of $1"
	fi
}

files_regular()
{
	[ -f "$1" ] && [ ! -L "$1" ] && [ -f "$2" ] && [ ! -L "$2" ]
}

_native_permissions_display()
{
	stat -c '%A  %U %G  %n' "$1" "$2" || fail 'cannot inspect permissions'
}
_native_compare_permissions()
{
	left=$(stat -c '%A %u %g' "$1") || fail "cannot inspect $1"
	right=$(stat -c '%A %u %g' "$2") || fail "cannot inspect $2"
	REJMERGE_VALUE=same
	[ "$left" = "$right" ] || REJMERGE_VALUE=different
}
_native_compare()
{
	if cmp -s "$1" "$2"; then result=0; else result=$?; fi
	case $result in
	0|1) REJMERGE_VALUE=$result ;;
	*) fail "cannot compare $1 and $2" ;;
	esac
}
_native_more() { more < "$TMPFILE"; }
_native_types() { file "$1" "$2" || fail 'cannot inspect file types'; }
_native_remove() { rm -f "$1" || fail "cannot remove $1"; }
_native_upgrade() { mv -f "$2" "$1" || fail "cannot upgrade $1"; }
_native_rmdir() { rmdir "$1" 2>/dev/null || :; }
_native_nothing() { printf 'Nothing to merge\n'; }
_native_clear_temp() { : > "$TMPFILE"; }
_native_expand()
{
	_native_entries=("$1"/* "$1"/.[!.]* "$1"/..?*)
	REJMERGE_VALUE=${#_native_entries[@]}
}
_native_expanded() { REJMERGE_VALUE=${_native_entries[$1]}; }
_native_install_merge()
{
	mode=$(stat -L -c %a "$1") || fail 'cannot inspect mode'
	if ! chmod "$mode" "$TMPFILE" || ! mv -f "$TMPFILE" "$1" ||
	    ! rm -f "$2"; then
		fail 'cannot install merged file'
	fi
	: > "$TMPFILE"
}

_native_write()
{
	# Ignore peer-loss SIGPIPE only for protocol writes, not user callbacks.
	( trap '' PIPE; printf '%s\0' "$@" >&"$native_write" ) || exit 1
}
_native_send_state()
{
	_native_write "${CMD-}" "${REJECTED_FILES_FOUND-}" "${INSTALLED_FILE-}" "${entry-}" \
	    "$TMPFILE" "${REJMERGE_MERGE_INFO-}" "$REJMERGE_ROOT" \
	    "$REJECTED_DIR" "${REJMERGE_VALUE-}" "$PWD" "${REJECTED_FILE-}"
}
_native_read_state()
{
	IFS= read -r -d '' CMD <&"$native_read" &&
	IFS= read -r -d '' REJECTED_FILES_FOUND <&"$native_read" &&
	IFS= read -r -d '' INSTALLED_FILE <&"$native_read" &&
	IFS= read -r -d '' entry <&"$native_read" &&
	IFS= read -r -d '' TMPFILE <&"$native_read" &&
	IFS= read -r -d '' REJMERGE_MERGE_INFO <&"$native_read" &&
	IFS= read -r -d '' REJMERGE_ROOT <&"$native_read" &&
	IFS= read -r -d '' REJECTED_DIR <&"$native_read" &&
	IFS= read -r -d '' REJMERGE_VALUE <&"$native_read" &&
	IFS= read -r -d '' _native_cwd <&"$native_read" &&
	IFS= read -r -d '' REJECTED_FILE <&"$native_read"
}
_native_call()
{
	local _rm_kind _rm_function _rm_count _rm_status _rm_arg
	local -a _rm_args
	_native_write N "$1" "$(($# - 1))"
	shift
	[ "$#" = 0 ] || _native_write "$@"
	_native_send_state
	while IFS= read -r -d '' _rm_kind <&"$native_read"; do
		if [ "$_rm_kind" = D ]; then
			IFS= read -r -d '' _rm_status <&"$native_read" || exit 1
			_native_read_state || exit 1
			return "$_rm_status"
		fi
		[ "$_rm_kind" = C ] || exit 1
		IFS= read -r -d '' _rm_function <&"$native_read" || exit 1
		IFS= read -r -d '' _rm_count <&"$native_read" || exit 1
		_rm_args=()
		while [ "$_rm_count" -gt 0 ]; do
			IFS= read -r -d '' _rm_arg <&"$native_read" || exit 1
			_rm_args+=("$_rm_arg")
			_rm_count=$((_rm_count - 1))
		done
		_native_read_state || exit 1
		if [ "$_rm_function" = files_regular ]; then
			if "$_rm_function" "${_rm_args[@]}"; then
				_rm_status=0
			else
				_rm_status=$?
			fi
		else
			"$_rm_function" "${_rm_args[@]}"
			_rm_status=$?
		fi
		_native_write R "$_rm_status"
		_native_send_state
	done
	exit 1
}
key() { _native_call key "$@"; }
permissions_menu() { _native_call permissions_menu "$@"; }
merge_menu() { _native_call merge_menu "$@"; }
diff_menu() { _native_call diff_menu "$@"; }
file_menu() { _native_call file_menu "$@"; }
process_file() { _native_call process_file "$@"; }
walk() { _native_call walk "$@"; }
main() { _native_call main "$@"; }

_native_exit()
{
	if [ -n "${native_pid-}" ]; then
		kill -TERM "$native_pid" 2>/dev/null || :
		wait "$native_pid" 2>/dev/null || :
	fi
	atexit
}

REJMERGE_NATIVE=$1
shift
_native_original_args=("$@")
REJMERGE_COMMAND=${0##*/}
REJMERGE_ROOT=
REJMERGE_CONF=/etc/rejmerge.conf
REJECTED_DIR=/var/lib/pkg/rejected
export LC_ALL=POSIX
while [ "$#" -gt 0 ]; do
	case $1 in
	-r|--root)
		REJMERGE_ROOT=$2
		REJMERGE_CONF=$2$REJMERGE_CONF
		REJECTED_DIR=$2$REJECTED_DIR
		shift
		;;
	esac
	shift
done
case $REJMERGE_CONF in
/*) ;;
*) REJMERGE_CONF=./$REJMERGE_CONF ;;
esac
work=$(mktemp -d) || exit 1
TMPFILE=$work/merge
trap _native_exit EXIT
: > "$TMPFILE" || exit 1
trap interrupted HUP INT QUIT TERM
if [ -f "$REJMERGE_CONF" ]; then
	# shellcheck disable=SC1090
	. "$REJMERGE_CONF"
fi
exec {native_input}<&0 {native_output}>&1
coproc REJMERGE_WORKER { exec "$REJMERGE_NATIVE" --imai-workflow "$native_input" "$native_output"; }
native_pid=$REJMERGE_WORKER_PID
exec {native_read}<&"${REJMERGE_WORKER[0]}" {native_write}>&"${REJMERGE_WORKER[1]}"
main "${_native_original_args[@]}"
exit 0
