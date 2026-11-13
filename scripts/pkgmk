#!/bin/bash
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
#

E_GENERAL=1
E_PKGFILE=2
E_DIR_PERM=3
E_DOWNLOAD=4
E_UNPACK=5
E_MD5=6
# shellcheck disable=SC2034
E_FOOTPRINT=7
# shellcheck disable=SC2034
E_BUILD=8
# shellcheck disable=SC2034
E_INSTALL=9
E_SIGNATURE=10

info()
{
	printf '=======> %s\n' "$1"
}

warning()
{
	info "WARNING: $1" >&2
}

error()
{
	info "ERROR: $1" >&2
}

get_filename()
{
	local ABSOLUTE=""
	if [ "$1" = "-a" ]; then
		ABSOLUTE=1
		shift
	fi

	if [[ $1 =~ ^(http|https|ftp|file)://.*/(.+) ]]; then
		echo "$PKGMK_SOURCE_DIR/${BASH_REMATCH[2]}"
	else
		if [ "$ABSOLUTE" ]; then
			printf '%s/%s\n' "$PKGMK_ROOT" "$1"
		else
			printf '%s\n' "$1"
		fi
	fi
}

get_basename()
{
	local FILE=$1
	case $FILE in
	*://*/*)
		FILE=${FILE##*/}
		;;
	esac
	printf '%s\n' "$FILE"
}

check_pkgfile()
{
	if [ ! "$name" ]; then
		error "Variable 'name' not specified in $PKGMK_PKGFILE."
		exit $E_PKGFILE
	elif [ ! "$version" ]; then
		error "Variable 'version' not specified in $PKGMK_PKGFILE."
		exit $E_PKGFILE
	elif [ ! "$release" ]; then
		error "Variable 'release' not specified in $PKGMK_PKGFILE."
		exit $E_PKGFILE
	elif [ "$(type -t build)" != "function" ]; then
		error "Function 'build' not specified in $PKGMK_PKGFILE."
		exit $E_PKGFILE
	fi
}

check_directory()
{
	local status=0
	"$PKGMK_NATIVE_COMMAND" --imai-internal check-directory "$1" || status=$?
	case $status in
	0) return 0 ;;
	1) error "Directory '$1' does not exist." ;;
	2) error "Directory '$1' not writable." ;;
	3) error "Directory '$1' not readable." ;;
	*) return "$status" ;;
	esac
	exit $E_DIR_PERM
}

check_file()
{
	if ! "$PKGMK_NATIVE_COMMAND" --imai-internal check-file "$1"; then
		error "File '$1' is not writable."
		exit 1
	fi
}

# shellcheck disable=SC2329 # Selected through DOWNLOAD_CMD in download_file.
download_wget2()
{
	local log status response resuming=no
	if [ "${#RESUME_OPTS[@]}" -gt 0 ] && [ -f "$LOCAL_FILENAME_PARTIAL" ]; then
		resuming=yes
	fi
	log=$(mktemp) || return 1
	wget2 "$@" --server-response "--output-file=$log"
	status=$?
	cat "$log"
	# Wget2 2.3.0 can append HTTP 200 to partial files; require 206 on resume.
	if [ "$resuming" = yes ] && [ "$status" = 0 ]; then
		response=$(awk '/^HTTP\// { code = $2 } END { print code }' "$log")
		[ "$response" = 206 ] || status=1
	fi
	if [ "$resuming" = yes ] && [ "$status" != 0 ]; then
		rm -f "$LOCAL_FILENAME_PARTIAL"
	fi
	rm -f "$log"
	return "$status"
}

download_file()
{
	local -a DOWNLOAD_OPTS=() EXTRA_OPTS=() RESUME_OPTS=() DOWNLOAD_CMD=()
	info "Downloading '$1'."

	PKGMK_DOWNLOAD_PROG=${PKGMK_DOWNLOAD_PROG:-curl}
	DOWNLOAD_CMD=("$PKGMK_DOWNLOAD_PROG")
	if [ ! "$(command -v "${PKGMK_DOWNLOAD_PROG}")" ]; then
		error "Command '${PKGMK_DOWNLOAD_PROG}' not found."
		exit $E_GENERAL
	fi

	LOCAL_FILENAME=$(get_filename "$1")
	LOCAL_FILENAME_PARTIAL="$LOCAL_FILENAME.partial"

	case ${PKGMK_DOWNLOAD_PROG} in
	curl)
		RESUME_CMD="-C -"
		DOWNLOAD_OPTS=(-L --fail --ftp-pasv --retry 3 --retry-delay 3
			-o "$LOCAL_FILENAME_PARTIAL")
		read -r -d '' -a EXTRA_OPTS <<< "$PKGMK_CURL_OPTS" || :
		DOWNLOAD_OPTS+=("${EXTRA_OPTS[@]}")
		;;
	wget)
		case $(wget --help 2>&1) in
		*BusyBox*)
			error "GNU-compatible wget required; use curl instead of BusyBox wget."
			exit "$E_GENERAL"
			;;
		esac
		RESUME_CMD="-c"
		DOWNLOAD_OPTS=(--compression=none --passive-ftp --no-directories
			--tries=3 --waitretry=3
			"--directory-prefix=$PKGMK_SOURCE_DIR"
			"--output-document=$LOCAL_FILENAME_PARTIAL")
		read -r -d '' -a EXTRA_OPTS <<< "$PKGMK_WGET_OPTS" || :
		DOWNLOAD_OPTS+=("${EXTRA_OPTS[@]}")
		;;
	aria2c)
		RESUME_CMD="--continue=true"
		DOWNLOAD_OPTS=(--no-conf --auto-file-renaming=false
			--allow-overwrite=true
			--file-allocation=none --split=4 --max-connection-per-server=4
			--min-split-size=20M --connect-timeout=15 --timeout=60
			--max-tries=3 --retry-wait=3
			"--dir=${LOCAL_FILENAME_PARTIAL%/*}"
			"--out=${LOCAL_FILENAME_PARTIAL##*/}")
		read -r -d '' -a EXTRA_OPTS <<< "$PKGMK_ARIA2_OPTS" || :
		DOWNLOAD_OPTS+=("${EXTRA_OPTS[@]}")
		;;
	wget2)
		DOWNLOAD_CMD=(download_wget2)
		RESUME_CMD="-c"
		DOWNLOAD_OPTS=(--compression=identity --no-directories
			--tries=3 --waitretry=3
			"--output-document=$LOCAL_FILENAME_PARTIAL")
		read -r -d '' -a EXTRA_OPTS <<< "$PKGMK_WGET2_OPTS" || :
		DOWNLOAD_OPTS+=("${EXTRA_OPTS[@]}")
		;;
	esac

	if [ -f "$LOCAL_FILENAME_PARTIAL" ]; then
		info "Partial download found, trying to resume"
		read -r -a RESUME_OPTS <<< "$RESUME_CMD"
	fi

	error=1

	BASENAME=$(get_basename "$1")
	for REPO in "${PKGMK_SOURCE_MIRRORS[@]}"; do
		REPO=${REPO%/}
		"${DOWNLOAD_CMD[@]}" "${DOWNLOAD_OPTS[@]}" "${RESUME_OPTS[@]}" "$REPO"/"$BASENAME"
		error=$?
		if [ $error == 0 ]; then
			break
		fi
	done

	if [ $error != 0 ]; then
		while true; do
			"${DOWNLOAD_CMD[@]}" "${DOWNLOAD_OPTS[@]}" "${RESUME_OPTS[@]}" "$1"
			error=$?
			if [ $error != 0 ] && [ "${#RESUME_OPTS[@]}" -gt 0 ]; then
				info "Partial download failed, restarting"
				rm -f "$LOCAL_FILENAME_PARTIAL"
				RESUME_OPTS=()
			else
				break
			fi
		done
	fi

	if [ "$error" != 0 ] || [ ! -f "$LOCAL_FILENAME_PARTIAL" ]; then
		error "Downloading '$1' failed."
		exit $E_DOWNLOAD
	fi

	mv -f "$LOCAL_FILENAME_PARTIAL" "$LOCAL_FILENAME"
}

download_source()
{
	local RENAME LOCAL_FILE ORIG_FILE srcind

	srcind=0
	while [ $srcind -lt ${#source[@]} ]; do
		ORIG_FILE=$(get_filename "${source[$srcind]}")
		LOCAL_FILE=$ORIG_FILE
		RENAME="${renames[$srcind]}"
		[ -n "$RENAME" ] && [ "$RENAME" != SKIP ] && LOCAL_FILE="$PKGMK_SOURCE_DIR/$RENAME"
		if [ ! -e "$LOCAL_FILE" ]; then
			if [ "$ORIG_FILE" = "${source[$srcind]}" ]; then
				error "Source file '$LOCAL_FILE' not found (can not be downloaded, URL not specified)."
				exit $E_DOWNLOAD
			else
				if [ "$PKGMK_DOWNLOAD" = "yes" ]; then
					download_file "${source[$srcind]}"
					[ "$LOCAL_FILE" = "$ORIG_FILE" ] || mv "$ORIG_FILE" "$LOCAL_FILE"

				else
					error "Source file '$LOCAL_FILE' not found (use option -d to download)."
					exit $E_DOWNLOAD
				fi
			fi
		fi
		srcind=$(( srcind+1 ))
	done
}

unpack_source()
{
	local ORIG_FILE RENAME LOCAL_FILE srcind COMMAND

	srcind=0
	while [ $srcind -lt ${#source[@]} ]; do
		ORIG_FILE=$(get_filename "${source[$srcind]}")
		LOCAL_FILE=$ORIG_FILE
		RENAME="${renames[$srcind]}"
		[ -n "$RENAME" ] && [ "$RENAME" != SKIP ] && LOCAL_FILE="$PKGMK_SOURCE_DIR/$RENAME"
		case $LOCAL_FILE in
		*.tar|*.tar.gz|*.tar.Z|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar.lzma|*.tar.lz|*.tar.zst|*.tzst|*.zip|*.rpm|*.7z)
			COMMAND=(bsdtar -p -o -C "$SRC" -xf "$LOCAL_FILE")
			;;
		*)
			COMMAND=(cp "$LOCAL_FILE" "$SRC")
			;;
		esac

		printf '%s\n' "${COMMAND[*]}"

		if ! "${COMMAND[@]}"; then
			if [ "$PKGMK_KEEP_WORK" = "no" ]; then
				rm -rf "$PKGMK_WORK_DIR"
			fi
			error "Building '$TARGET' failed."
			exit $E_UNPACK
		fi
		srcind=$(( srcind+1 ))
	done
}

md5sum()
{
	local file
	for file do
		case $file in
		-?*|*\\*|*$'\n'*|*$'\r'*) command md5sum "$@"; return $? ;;
		esac
	done
	"$PKGMK_NATIVE_COMMAND" --imai-internal digest md5 "$@"
}

sha256sum()
{
	local file
	for file do
		case $file in
		-?*|*\\*|*$'\n'*|*$'\r'*) command sha256sum "$@"; return $? ;;
		esac
	done
	"$PKGMK_NATIVE_COMMAND" --imai-internal digest sha256 "$@"
}

make_md5sum()
{
	local i FILE
	local -a FILES=()
	for ((i=0; i<${#source[@]}; i++)); do
		FILE=$(get_filename "${source[i]}")
		if [ -n "${renames[i]}" ] && [ "${renames[i]}" != SKIP ]; then
			FILE="$PKGMK_SOURCE_DIR/${renames[i]}"
		fi
		FILES+=("$FILE")
	done
	if [ "${#FILES[@]}" -gt 0 ]; then
		md5sum "${FILES[@]}" | sed -e 's|  .*/|  |' | sort -k 2
	fi
}

make_footprint()
{
	pkginfo --footprint "$TARGET" | \
		sed "s|$(printf '\t')lib/modules/$(uname -r)/|$(printf '\t')lib/modules/<kernel-version>/|g" | \
		sort -k 3
}

check_md5sum()
{
	local FILE="$PKGMK_WORK_DIR/.tmp"

	cd "$PKGMK_ROOT"

	if [ -f $PKGMK_MD5SUM ]; then
		make_md5sum > "$FILE".md5sum
		sort -k 2 $PKGMK_MD5SUM > "$FILE".md5sum.orig
		diff -b "$FILE.md5sum.orig" "$FILE.md5sum" |
			sed -n -e 's/^> /NEW       /p' -e 's/^< /MISSING   /p'  > "$FILE".md5sum.diff
		if [ -s "$FILE".md5sum.diff ]; then
			error "Md5sum mismatch found:"
			cat "$FILE".md5sum.diff >&2

			if [ "$PKGMK_KEEP_WORK" = "no" ]; then
				rm -rf "$PKGMK_WORK_DIR"
			fi

			if [ "$PKGMK_CHECK_MD5SUM" = "yes" ]; then
				error "Md5sum not ok."
				exit $E_MD5
			fi

			error "Building '$TARGET' failed."
			exit $E_MD5
		fi
	else
		if [ "$PKGMK_CHECK_MD5SUM" = "yes" ]; then
			if [ "$PKGMK_KEEP_WORK" = "no" ]; then
				rm -rf "$PKGMK_WORK_DIR"
			fi
			info "Md5sum not found."
			exit $E_MD5
		fi

		warning "Md5sum not found, creating new."
		make_md5sum > $PKGMK_MD5SUM
	fi

	if [ "$PKGMK_CHECK_MD5SUM" = "yes" ]; then
		if [ "$PKGMK_KEEP_WORK" = "no" ]; then
			rm -rf "$PKGMK_WORK_DIR"
		fi
		info "Md5sum ok."
		exit 0
	fi
}

# requires a previous call of make_work_dir()
check_signature()
{
	local RESULT=0

	if [ -f "$PKGMK_ROOT"/$PKGMK_SIGNATURE ]; then
		cd "$SRC"
		local srcind=0

		while [ $srcind -lt ${#source[@]} ]; do
			if [ -n "${renames[$srcind]}" ] && [ "${renames[$srcind]}" != SKIP ]; then
				source[srcind]="http://somehost/${renames[$srcind]}"
			fi
			srcind=$(( srcind+1 ))
		done

		for FILE in "$PKGMK_PKGFILE" "$PKGMK_FOOTPRINT" "${source[@]}"; do
			ln -s "$(get_filename -a "$FILE")" .
		done

		if [ "$PKGMK_PUBLICKEY" ]; then
			err=$($PKGMK_SIGNIFY -q -C -p "$PKGMK_PUBLICKEY" -x "$PKGMK_ROOT/$PKGMK_SIGNATURE" 2>&1)
		else
			err=$($PKGMK_SIGNIFY -q -C -x "$PKGMK_ROOT/$PKGMK_SIGNATURE" 2>&1)
		fi

		RESULT=$?
		cd "$PKGMK_ROOT"

		if [ $RESULT -ne 0 ]; then
			if [ "$err" = "signify: signature verification failed" ]; then
				error "Failed verifying cryptographic digest"
			else
				error "Signature mismatch found:"
				echo "$err" | while IFS= read -r n; do
					echo 'MISMATCH	'"${n%%:*}"
				done
			fi

			if [ "$PKGMK_KEEP_WORK" = "no" ]; then
				rm -rf "$PKGMK_WORK_DIR"
			fi

			error "Building '$TARGET' failed."
			exit $E_SIGNATURE
		fi
	else
		if [ "$PKGMK_IGNORE_MD5SUM" = "no" ] && [ "$PKGMK_CHECK_SIGNATURE" = "no" ]; then
			warning "Signature file not found, falling back to old md5sum checking."
			return 1;
		fi
		if [ "$PKGMK_CHECK_SIGNATURE" = "yes" ]; then
			if [ "$PKGMK_KEEP_WORK" = "no" ]; then
				rm -rf "$PKGMK_WORK_DIR"
			fi
			info "Signature not found."
			exit $E_SIGNATURE
		fi

		warning "Signature not found, creating new."
		cd "$PKGMK_ROOT"
		make_signature
	fi

	if [ "$PKGMK_CHECK_SIGNATURE" = "yes" ]; then
		if [ "$PKGMK_KEEP_WORK" = "no" ]; then
			rm -rf "$PKGMK_WORK_DIR"
		fi
		info "Signature ok."
		exit 0
	fi

	for FILE in "$SRC"/* "$SRC"/.[!.]* "$SRC"/..?*; do
		[ ! -L "$FILE" ] || rm -f "$FILE"
	done
	return 0
}

# Both signature pipelines use the signer status, matching upstream.
make_signature()
{
	local FILE
	local -a LOCAL_FILENAMES=()
	local REPO

	local srcind=0
	while [ $srcind -lt ${#source[@]} ]; do
		if [ -n "${renames[$srcind]}" ] && [ "${renames[$srcind]}" != SKIP ]; then
			source[srcind]="http://somehost/${renames[$srcind]}"
		fi
		srcind=$(( srcind+1 ))
	done

	for FILE in "$PKGMK_PKGFILE" "$PKGMK_FOOTPRINT" "${source[@]}"; do
		LOCAL_FILENAMES+=("$(get_filename "$FILE")")
	done

	if [ ! "$PKGMK_PRIVATEKEY" ]; then
		REPO=${PWD%/*}
		REPO=${REPO##*/}
		REPO=${REPO%.git}
	fi

	if [ "$REPO" ]; then
		PKGMK_PRIVATEKEY="/etc/ports/${REPO}.sec"
	fi

	for FILE in "${LOCAL_FILENAMES[@]}"; do
		local HASH
		HASH=$(sha256sum "$FILE") || exit "$E_SIGNATURE"
		printf 'SHA256 (%s) = %s\n' "${FILE##*/}" "${HASH%% *}"
	done | \
		$PKGMK_SIGNIFY -S -e -x - -q -s "$PKGMK_PRIVATEKEY" -m - > ${PKGMK_SIGNATURE}.tmp

	# shellcheck disable=SC2181
	if [ $? -ne 0 ]; then
		rm ${PKGMK_SIGNATURE}.tmp
		error "Creating signature failed"
		exit $E_SIGNATURE
	else
		mv ${PKGMK_SIGNATURE}.tmp ${PKGMK_SIGNATURE}
	fi
}

refresh_signature()
{
	if [ ! "$PKGMK_PRIVATEKEY" ]; then
		REPO=${PWD%/*}
		REPO=${REPO##*/}
		REPO=${REPO%.git}
	fi

	if [ "$REPO" ]; then
		PKGMK_PRIVATEKEY="/etc/ports/${REPO}.sec"
	fi

	tail -n +3 ${PKGMK_SIGNATURE} | \
		$PKGMK_SIGNIFY -S -e -x - -q -s "$PKGMK_PRIVATEKEY" -m - > ${PKGMK_SIGNATURE}.tmp

	# shellcheck disable=SC2181
	if [ $? -ne 0 ]; then
		rm ${PKGMK_SIGNATURE}.tmp
		error "Refreshing signature failed"
		exit $E_SIGNATURE
	else
		mv ${PKGMK_SIGNATURE}.tmp ${PKGMK_SIGNATURE}
	fi
}

strip_files()
{
	cd "$PKG" || return
	# shellcheck disable=SC2016
	find . -type f -exec /bin/dash -c '
		filter=$1
		shift
		for path do
			if [ -f "$filter" ] && printf "%s\n" "${path#./}" |
			    grep -q -f "$filter"; then
				continue
			fi
			kind=$(file -b "$path") || exit 1
			case $kind in
			*ELF*executable*"not stripped"*) strip --strip-all "$path" ;;
			*ELF*"shared object"*"not stripped"*) strip --strip-unneeded "$path" ;;
			"current ar archive"*) strip --strip-debug "$path" ;;
			esac
		done
	' dash "$PKGMK_ROOT/$PKGMK_NOSTRIP" {} +
}

compress_manpages()
{
	cd "$PKG" || return
	# shellcheck disable=SC2016
	find . -type f -path '*/man/man*/*' -exec /bin/dash -c '
		for file do
			case $file in *.gz) continue ;; esac
			gzip -9 "$file" || exit 1
		done
	' dash {} +

	# Appending a sentinel preserves trailing newlines in link contents.
	# shellcheck disable=SC2016
	find . -type l -path '*/man/man*/*' -exec /bin/dash -c '
		for file do
			target=$(readlink "$file" && printf .) || exit 1
			target=${target%"$(printf "\n.")"}
			target=${target##*/}
			target=${target%.gz}.gz
			rm -f "$file" || exit 1
			file=${file%.gz}.gz
			dir=${file%/*}
			if [ -e "$dir/$target" ]; then
				ln -sf "$target" "$file" || exit 1
			fi
		done
	' dash {} +
}

check_footprint()
{
	local FILE="$PKGMK_WORK_DIR/.tmp"

	cd "$PKGMK_ROOT"

	if [ -f "$TARGET" ]; then
		make_footprint > "$FILE".footprint
		if [ -f $PKGMK_FOOTPRINT ]; then
			sort -k 3 $PKGMK_FOOTPRINT > "$FILE".footprint.orig
			diff -b "$FILE.footprint.orig" "$FILE.footprint" |
				sed -n -e 's/^> /NEW       /p' -e 's/^< /MISSING   /p'  > "$FILE".footprint.diff
			if [ -s "$FILE".footprint.diff ]; then
				if [ "$PKGMK_IGNORE_NEW" = "yes" ] && \
					! grep -q ^MISSING "$FILE.footprint.diff" ; then
					info "New files found:"
				else
					error "Footprint mismatch found:"
					BUILD_SUCCESSFUL="no"
				fi
				cat "$FILE".footprint.diff >&2
			fi
		else
			warning "Footprint not found, creating new."
			mv "$FILE".footprint $PKGMK_FOOTPRINT
		fi
	else
		error "Package '$TARGET' was not found."
		BUILD_SUCCESSFUL="no"
	fi
}

native_work_prepare()
{
	umask 022
	cd "$PKGMK_ROOT"
}

native_work_mkdir()
{
	mkdir -p "$SRC" "$PKG"
}

native_copy_signature()
{
	test -f $PKGMK_SIGNATURE && cp $PKGMK_SIGNATURE "$PKGMK_WORK_DIR"
}

native_md5_absent()
{
	test ! -f $PKGMK_MD5SUM
}

make_work_dir()
{
	native_rpc work-directory
}

remove_work_dir()
{
	rm -rf "$PKGMK_WORK_DIR"
}

native_recipe_build()
{
	cd "$SRC"
	# Preserve errexit in the recipe subshell, not an if/conditional context.
	(
		set -e -x
		build
	)
}

native_build_result()
{
	cd "$PKG"
	info "Build result:"
}

native_archive_package()
{
	bsdtar --format=gnutar -c "$COMPRESSION" -f "$TARGET" -- * &&
		bsdtar -t -v -f "$TARGET"
}

native_failed_touch()
{
	if [ -f "$TARGET" ]; then
		touch -r "$PKGMK_ROOT/$PKGMK_PKGFILE" "$TARGET" > /dev/null 2>&1
	fi
}

build_package()
{
	# C orchestration reads and updates these dynamically scoped locals.
	# shellcheck disable=SC2034
	local BUILD_SUCCESSFUL=no COMPRESSION build_status
	native_rpc build-package
}

native_install_command()
{
	if [ "$1" = install ]; then
		COMMAND=(pkgadd "$TARGET")
	else
		COMMAND=(pkgadd -u "$TARGET")
	fi
	cd "$PKGMK_ROOT"
	printf '%s\n' "${COMMAND[*]}"
	"${COMMAND[@]}"
}

install_package()
{
	local COMMAND
	native_rpc install-package
}

clean()
{
	local ORIG_FILE LOCAL_FILE srcind

	if [ -f "$TARGET" ]; then
		info "Removing $TARGET"
		rm -f "$TARGET"
	fi

	srcind=0
	while [ $srcind -lt ${#source[@]} ]; do
		ORIG_FILE="${source[$srcind]}"
		LOCAL_FILE=$(get_filename "$ORIG_FILE")
		RENAME="${renames[$srcind]}"
		if [ -n "$RENAME" ] && [ "$RENAME" != SKIP ]; then
			LOCAL_FILE="$PKGMK_SOURCE_DIR/$RENAME"
		fi
		if [ -e "$LOCAL_FILE" ] && [ "$LOCAL_FILE" != "$ORIG_FILE" ]; then
			info "Removing $LOCAL_FILE"
			rm -f "$LOCAL_FILE"
		fi
		srcind=$(( srcind+1 ))
	done
}

update_footprint()
{
	if [ ! -f "$TARGET" ]; then
		error "Unable to update footprint. File '$TARGET' not found."
		exit 1
	fi

	check_file "$PKGMK_FOOTPRINT"
	make_footprint > $PKGMK_FOOTPRINT
	touch "$TARGET"

	info "Footprint updated."
}

build_needed()
{
	local ORIG_FILE RENAME LOCAL_FILE srcind RESULT

	RESULT="yes"
	if [ -f "$TARGET" ]; then
		RESULT="no"
		srcind=0

		while [ $srcind -lt ${#source[@]} ]; do
			ORIG_FILE=$(get_filename "${source[$srcind]}")
			LOCAL_FILE=$ORIG_FILE
			RENAME="${renames[$srcind]}"
			if [ -n "$RENAME" ] && [ "$RENAME" != SKIP ]; then
				LOCAL_FILE="$PKGMK_SOURCE_DIR/$RENAME"
			fi
			if [ -e "$LOCAL_FILE" ] && [ ! "$TARGET" -nt "$LOCAL_FILE" ]; then
				RESULT="yes"
				break
			fi
			srcind=$(( srcind+1 ))
		done

		if [ -e $PKGMK_PKGFILE ] && [ ! "$TARGET" -nt $PKGMK_PKGFILE ]; then
			RESULT="yes"
		fi
	fi

	echo $RESULT
}

# shellcheck disable=SC2329
interrupted()
{
	echo ""
	error "Interrupted."

	if [ "$PKGMK_KEEP_WORK" = "no" ]; then
		rm -rf "$PKGMK_WORK_DIR"
	fi

	exit 1
}

print_help()
{
	echo "usage: $(basename "$PKGMK_COMMAND") [options]"
	echo "options:"
	echo "  -i,   --install             build and install package"
	echo "  -u,   --upgrade             build and install package (as upgrade)"
	echo "  -r,   --recursive           search for and build packages recursively"
	echo "  -d,   --download            download missing source file(s)"
	echo "  -do,  --download-only       do not build, only download missing source file(s)"
	echo "  -eo,  --extract-only        do not build, only extract source file(s)"
	echo "  -utd, --up-to-date          do not build, only check if package is up to date"
	echo "  -uf,  --update-footprint    update footprint using result from last build"
	echo "  -if,  --ignore-footprint    build package without checking footprint"
	echo "  -in,  --ignore-new          build package, ignore new files in a footprint missmatch"
	echo "  -um,  --update-md5sum       update md5sum"
	echo "  -im,  --ignore-md5sum       build package without checking md5sum"
	echo "  -cm,  --check-md5sum        do not build, only check md5sum"
	echo "  -us,  --update-signature    update signature including sha256 checksums"
	echo "  -cs,  --check-signature     check the validity of the port files"
	echo "  -is,  --ignore-signature    build package without checking the signature"
	echo "  -rs,  --refresh-signature   create new signature and keep existing sha256 checksums"
	echo "  -sk,  --secret-key <file>   use <file> to sign the port"
	echo "  -pk,  --public-key <file>   check the port signature using public-key <file>"
	echo "  -ns,  --no-strip            do not strip executable binaries or libraries"
	echo "  -f,   --force               build package even if it appears to be up to date"
	echo "  -c,   --clean               remove package and downloaded files"
	echo "  -kw,  --keep-work           keep temporary working directory"
	echo "  -cf,  --config-file <file>  use alternative configuration file"
	echo "  -v,   --version             print version and exit"
	echo "  -h,   --help                print help and exit"
}

native_rpc()
{
	local __imai_mode=$1
	shift
	printf '%s\0' RUN "$__imai_mode" "$#" "$@" >&63 || exit 1
	local __imai_operation __imai_count __imai_status __imai_value __imai_i
	local -a __imai_arguments
	while IFS= read -r -d '' __imai_operation <&63; do
		if [ "$__imai_operation" = R ]; then
			IFS= read -r -d '' __imai_status <&63 || exit 1
			IFS= read -r -d '' __imai_value <&63 || exit 1
			return "$__imai_status"
		fi
		IFS= read -r -d '' __imai_count <&63 || exit 1
		__imai_arguments=()
		for ((__imai_i=0; __imai_i<__imai_count; __imai_i++)); do
			IFS= read -r -d '' __imai_value <&63 || exit 1
			__imai_arguments+=("$__imai_value")
		done
		__imai_status=0
		__imai_value=
		case $__imai_operation in
		SOURCE)
			if [ ! -f "${__imai_arguments[0]}" ]; then
				error "File '${__imai_arguments[0]}' not found."
				exit 1
			fi
			# shellcheck disable=SC1090
			case ${__imai_arguments[0]} in
			/*|./*|../*) . "${__imai_arguments[0]}" ;;
			*) . "./${__imai_arguments[0]}" ;;
			esac
			;;
		GET) __imai_value=${!__imai_arguments[0]} ;;
		SET) printf -v "${__imai_arguments[0]}" '%s' "${__imai_arguments[1]}" ;;
		CALL)
			"${__imai_arguments[@]}"
			__imai_status=$?
			;;
		TEST)
			if "${__imai_arguments[@]}"; then
				__imai_status=0
			else
				__imai_status=$?
			fi
			;;
		CAPTURE)
			if __imai_value=$("${__imai_arguments[@]}"); then
				__imai_status=0
			else
				__imai_status=$?
			fi
			;;
		*) exit 1 ;;
		esac
		printf '%s\0' R "$__imai_status" "$__imai_value" >&63 || exit 1
	done
	exit 1
}

native_exit()
{
	exit "$1"
}

native_version()
{
	printf '%s (imai) %s\n' "${PKGMK_COMMAND##*/}" "$PKGMK_VERSION"
}

native_invalid_option()
{
	printf '%s: invalid option %s\n' "${PKGMK_COMMAND##*/}" "$1"
}

native_missing_argument()
{
	printf '%s: option %s requires an argument\n' "${PKGMK_COMMAND##*/}" "$1"
}

native_check_work_parent()
{
	check_directory "$(dirname "$PKGMK_WORK_DIR")"
}

native_write_md5sum()
{
	make_md5sum > $PKGMK_MD5SUM
}

native_extract_message()
{
	info "Extracting sources of package '$name-$version'."
}

parse_options()
{
	native_rpc parse "$@"
}

main()
{
	# shellcheck disable=SC2034
	PKGMK_ARCH=64
	if [ -f .32bit ]; then
		# shellcheck disable=SC2034
		PKGMK_ARCH=32
	fi
	local FILE TARGET
	native_rpc main "$@"
}

trap "interrupted" SIGHUP SIGINT SIGQUIT SIGTERM

export LC_ALL=C.UTF-8

readonly PKGMK_VERSION=$1
readonly PKGMK_NATIVE_COMMAND=$2
# shellcheck disable=SC2034
readonly PKGMK_NATIVE_WORKFLOW=1
shift 2
case $0 in
/proc/self/exe|/proc/thread-self/exe)
	PKGMK_COMMAND=$PKGMK_NATIVE_COMMAND
	;;
/*)
	PKGMK_COMMAND=$0
	;;
*/*)
	PKGMK_COMMAND=$PWD/$0
	;;
*)
	PKGMK_COMMAND=$(command -v "$0")
	;;
esac
readonly PKGMK_COMMAND
readonly PKGMK_ROOT="$PWD"
readonly PKGMK_SIGNIFY="/usr/bin/signify"

# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_CONFFILE="/etc/pkgmk.conf"
PKGMK_PKGFILE="Pkgfile"
PKGMK_FOOTPRINT=".footprint"
PKGMK_MD5SUM=".md5sum"
PKGMK_NOSTRIP=".nostrip"
PKGMK_SIGNATURE=".signature"

PKGMK_SOURCE_MIRRORS=()
PKGMK_SOURCE_DIR="$PWD"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_PACKAGE_DIR="$PWD"
PKGMK_WORK_DIR="$PWD/work"

# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_COMPRESSION_MODE="gz"

# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_INSTALL="no"
PKGMK_RECURSIVE="no"
PKGMK_DOWNLOAD="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_DOWNLOAD_ONLY="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_EXTRACT_ONLY="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_UP_TO_DATE="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_UPDATE_FOOTPRINT="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_IGNORE_FOOTPRINT="no"
PKGMK_IGNORE_NEW="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_FORCE="no"
PKGMK_KEEP_WORK="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_UPDATE_MD5SUM="no"
PKGMK_IGNORE_MD5SUM="no"
PKGMK_CHECK_MD5SUM="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_UPDATE_SIGNATURE="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_IGNORE_SIGNATURE="no"
PKGMK_CHECK_SIGNATURE="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_REFRESH_SIGNATURE="no"
PKGMK_PRIVATEKEY=""
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_NO_STRIP="no"
# shellcheck disable=SC2034 # Accessed by C orchestration through GET/SET.
PKGMK_CLEAN="no"

parse_options "$@"

if [ "$PKGMK_RECURSIVE" = yes ]; then
	trap 'exit 1' HUP INT QUIT TERM
	native_rpc recursive "$@"
	exit 0
fi

main "$@"
