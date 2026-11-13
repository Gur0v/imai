#!/bin/dash
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
reference=${1:-$root/../pkgutils/pkgmk.in}
binary=${2:-$root/build/pkgmk}
# Only trusted recipes run, with all writable paths on disposable tmpfs.
# shellcheck disable=SC2016
bwrap --unshare-all --die-with-parent --uid 0 --gid 0 --ro-bind / / \
    --dev /dev --proc /proc --tmpfs /tmp --chdir /tmp \
    --dir /tmp/tools --ro-bind "$binary" /tmp/tools/pkgmk \
    --ro-bind "$reference" /tmp/reference-pkgmk -- /bin/dash -eu -c '
[ ! -e /tmp/tools/pkgmk-bash ]
mkdir /tmp/port
cd /tmp/port
trap '\''status=$?; if [ "$status" != 0 ]; then cat out err >&2; fi'\'' 0
printf "" > config
/tmp/tools/pkgmk --version > version
grep -q "pkgmk (imai) 0.1.0" version
/tmp/tools/pkgmk --help > help
grep -q -- --refresh-signature help
if /tmp/tools/pkgmk -cf >out 2>err; then exit 1; fi
printf "pkgmk: option -cf requires an argument\n" >expected
cmp out expected
cat >Pkgfile <<"EOF"
name=tiny
version=1
release=1
source=(input)
renames=(SKIP)
private_state=("persistent value" second)
recipe_function() { printf "%s" "${private_state[0]}"; }
build() {
 mkdir -p "$PKG/usr/share/tiny"
 recipe_function > "$PKG/usr/share/tiny/value"
 cp "$SRC/input" "$PKG/usr/share/tiny/input"
 printf "%s" "$CONFIG_STATE" > "$PKG/usr/share/tiny/config"
}
EOF
printf "trusted input\n" >input
cat >config <<"EOF"
[[ ${private_state[1]} == second ]] || exit 91
CONFIG_STATE="config after recipe"
PKGMK_IGNORE_SIGNATURE=yes
PKGMK_IGNORE_MD5SUM=yes
PKGMK_IGNORE_FOOTPRINT=yes
PKGMK_NO_STRIP=yes
PKGMK_COMPRESSION_MODE=gz
EOF
/tmp/tools/pkgmk -cf config -kw >out 2>err
[ -f tiny#1-1.pkg.tar.gz ]
[ "$(cat work/pkg/usr/share/tiny/value)" = "persistent value" ]
[ "$(cat work/pkg/usr/share/tiny/config)" = "config after recipe" ]
cmp input work/pkg/usr/share/tiny/input
cp Pkgfile original-Pkgfile
cp config original-config
cat >>Pkgfile <<"EOF"
declare -A recipe_map=([key]="recipe state")
shopt -s extglob
recipe_suffix=from-recipe
EOF
cat >>config <<"EOF"
[[ ${recipe_map[key]} == "recipe state" ]] || exit 92
[[ from-recipe == @(from-recipe|other) ]] || exit 93
recipe_map[key]="config state"
[ "$PKGMK_UP_TO_DATE" = yes ] || exit 94
PKGMK_UP_TO_DATE=no
build() {
 mkdir -p "$PKG/usr/share/tiny"
 printf "%s:%s" "${recipe_map[key]}" "$recipe_suffix" > "$PKG/usr/share/tiny/state"
 cp "$SRC/input" "$PKG/usr/share/tiny/input"
}
EOF
/tmp/tools/pkgmk -cf config -utd -f -kw >out 2>err
[ "$(cat work/pkg/usr/share/tiny/state)" = "config state:from-recipe" ]
mv original-Pkgfile Pkgfile
mv original-config config
/tmp/tools/pkgmk -cf config -f -kw >out 2>err
bsdtar -tf tiny#1-1.pkg.tar.gz >members
grep -q usr/share/tiny/value members
/tmp/tools/pkgmk -cf config -um >out 2>err
md5sum input >expected
cmp expected .md5sum
/tmp/tools/pkgmk -cf config -cm >out 2>err
cat >>config <<"EOF"
PKGMK_IGNORE_MD5SUM=no
build_needed() { printf "no\n"; }
EOF
/tmp/tools/pkgmk -cf config -utd >out 2>err
grep -q "is up to date" out
/tmp/tools/pkgmk -cf config -eo >out 2>err
cmp input work/src/input
/tmp/tools/pkgmk -cf config -do >out 2>err
/tmp/tools/pkgmk -cf config -c >out 2>err
[ ! -f tiny#1-1.pkg.tar.gz ]
[ -f input ]
printf "bad\n" >.md5sum
if /tmp/tools/pkgmk -cf config -cm >out 2>err; then exit 1; else [ "$?" = 6 ]; fi
: >.footprint
signify -G -n -p port.pub -s port.sec
printf "downloaded payload\n" >/tmp/payload
cat >>Pkgfile <<"EOF"
source=(file:///tmp/payload)
renames=(renamed)
EOF
/tmp/tools/pkgmk -cf config -do >out 2>err
cmp /tmp/payload renamed
/tmp/tools/pkgmk -cf config -us -sk port.sec >out 2>err
/tmp/tools/pkgmk -cf config -cs -pk /tmp/port/port.pub >out 2>err
/tmp/tools/pkgmk -cf config -rs -sk port.sec >out 2>err
/tmp/tools/pkgmk -cf config --refresh-signature -sk port.sec >out 2>err
/tmp/tools/pkgmk -cf config -cs -pk /tmp/port/port.pub >out 2>err
printf "tamper\n" >>renamed
if /tmp/tools/pkgmk -cf config -cs -pk /tmp/port/port.pub >out 2>err; then exit 1; else [ "$?" = 10 ]; fi
printf "\nsource=(absent)\nrenames=()\n" >>Pkgfile
if /tmp/tools/pkgmk -cf config -do >out 2>err; then exit 1; else [ "$?" = 4 ]; fi
mkdir /tmp/download-tools
cat >/tmp/download-tools/curl <<"EOF"
#!/bin/dash
if [ "${1:-}" = --help ]; then printf "fixture downloader\n"; exit 0; fi
printf "%s\n" "$@" >/tmp/download-argv
output=
directory=
while [ "$#" -gt 0 ]; do
    case $1 in
    -o) output=$2; shift ;;
    --output-document=*|--out=*) output=${1#*=} ;;
    --dir=*) directory=${1#*=}/ ;;
    esac
    shift
done
printf "downloaded\n" >"$directory$output"
EOF
cp /tmp/download-tools/curl /tmp/download-tools/wget
cp /tmp/download-tools/curl /tmp/download-tools/wget2
cp /tmp/download-tools/curl /tmp/download-tools/aria2c
chmod +x /tmp/download-tools/curl /tmp/download-tools/wget /tmp/download-tools/wget2 /tmp/download-tools/aria2c
cp config option-config
cat >>option-config <<"EOF"
PKGMK_CURL_OPTS="--connect-timeout 1
--max-time 2
--literal *"
PKGMK_WGET_OPTS="--connect-timeout 1
--max-time 2
--literal *"
PKGMK_WGET2_OPTS="$PKGMK_WGET_OPTS"
PKGMK_ARIA2_OPTS="$PKGMK_WGET_OPTS"
EOF
printf "\nsource=(https://example.invalid/option-source)\nrenames=()\n" >>Pkgfile
printf "%s\n" --connect-timeout 1 --max-time 2 --literal "*" >expected-options
for downloader in aria2c wget2 curl wget; do
    printf "\nPKGMK_DOWNLOAD_PROG=%s\n" "$downloader" >>option-config
    rm -f option-source
    PATH=/tmp/download-tools:$PATH /tmp/tools/pkgmk -cf option-config -do >out 2>err
    sed -n "/^--connect-timeout$/,$ p" /tmp/download-argv |
        sed "/^https:/d; /^--server-response$/d; /^--output-file=/d" >actual-options
    cmp expected-options actual-options
done
# The network namespace has no external connectivity.
python3 -I - <<"PY"
import http.server
import pathlib
import shutil
import subprocess
import threading

requests = []
payload = bytes(range(256)) * 1024
resume_offset = 65536

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get("Range")))
        if self.path == "/missing":
            self.send_error(404)
            return
        start = 0
        if self.path == "/resume" and self.headers.get("Range"):
            start = int(self.headers["Range"].removeprefix("bytes=").split("-", 1)[0])
        self.send_response(206 if start else 200)
        if start:
            self.send_header("Content-Range", "bytes " + str(start) + "-" +
                             str(len(payload) - 1) + "/" + str(len(payload)))
        self.send_header("Content-Length", str(len(payload) - start))
        self.end_headers()
        self.wfile.write(payload[start:])

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever)
thread.start()
try:
    for backend in ("aria2c", "curl", "wget2"):
        if shutil.which(backend) is None:
            print("SKIP: actual " + backend + " backend (not installed)", flush=True)
            continue
        config = pathlib.Path(backend + "-config")
        config.write_text(pathlib.Path("config").read_text() +
                          "\nPKGMK_DOWNLOAD_PROG=" + backend + "\n")
        for endpoint in ("fresh", "resume", "restart", "missing"):
            final = pathlib.Path(backend + "-" + endpoint)
            partial = pathlib.Path(endpoint + ".partial")
            with pathlib.Path("Pkgfile").open("a") as recipe:
                recipe.write("\nsource=(http://127.0.0.1:" + str(server.server_port) +
                             "/" + endpoint + ")\nrenames=(" + str(final) + ")\n")
            if endpoint != "fresh":
                partial.write_bytes(payload[:resume_offset])
            requests.clear()
            with open("out", "w") as out, open("err", "w") as err:
                result = subprocess.run(["/tmp/tools/pkgmk", "-cf", str(config), "-do"],
                                        stdout=out, stderr=err, timeout=30)
            if endpoint == "missing":
                assert result.returncode == 4, (backend, endpoint, result.returncode)
                assert not final.exists()
                assert not pathlib.Path(endpoint).exists()
            else:
                assert result.returncode == 0, (backend, endpoint, result.returncode)
                assert final.read_bytes() == payload, (backend, endpoint)
                assert not partial.exists(), (backend, endpoint)
            if endpoint == "resume":
                assert any(path == "/resume" and value and
                           value.startswith("bytes=" + str(resume_offset) + "-")
                           for path, value in requests), (backend, requests)
            if endpoint == "restart":
                assert any(path == "/restart" and value and
                           value.startswith("bytes=" + str(resume_offset) + "-")
                           for path, value in requests), (backend, requests)
                assert ("/restart", None) in requests, (backend, requests)
finally:
    server.shutdown()
    thread.join()
    server.server_close()
PY
printf "\nsource=(https://example.invalid/option-source)\nrenames=()\n" >>Pkgfile
# BusyBox supplies standard utilities; Bash and specialized tools stay explicit.
mkdir /tmp/busy
busybox --install -s /tmp/busy
for tool in bash bsdtar signify file strip curl; do
    ln -sf "$(command -v "$tool")" "/tmp/busy/$tool"
done
rm -f option-source
if PATH=/tmp/busy /tmp/tools/pkgmk -cf option-config -do >out 2>err; then
    exit 1
else
    [ "$?" = 1 ]
fi
grep -q "GNU-compatible wget required" err
printf "\nsource=(input)\nrenames=(SKIP)\n" >>Pkgfile
rm -f .signature
PATH=/tmp/busy /tmp/tools/pkgmk -cf config -um >out 2>err
PATH=/tmp/busy /tmp/tools/pkgmk -cf config -f -kw >out 2>err
cmp input work/pkg/usr/share/tiny/input
mkdir -p /tmp/tree/"a port"
cp Pkgfile input /tmp/tree/"a port"/
cp config /tmp/tree/"config file"
printf "\\nprintf configured > /tmp/recursive-config-marker\\n" >>/tmp/tree/"config file"
(cd /tmp/tree && PATH=/tmp/busy /tmp/tools/pkgmk -r -cf "/tmp/tree/config file" -do) >out 2>err
grep -q "Entering directory" out
[ "$(cat /tmp/recursive-config-marker)" = configured ]
[ ! -s err ]
mkdir /tmp/new /tmp/old
cat >/tmp/fixture <<"EOF"
name=fixture
version=1
release=1
source=(input)
build() {
 mkdir -p "$PKG/usr/share/fixture" "$PKG/usr/share/man/man1"
 cp input "$PKG/usr/share/fixture/data"
 printf "manual\n" >"$PKG/usr/share/man/man1/fixture.1"
 ln -s fixture.1 "$PKG/usr/share/man/man1/alias.1"
}
EOF
for lane in old new; do
    cd "/tmp/$lane"
    cp /tmp/fixture Pkgfile
    printf "input\n" >input
    printf "PKGMK_IGNORE_SIGNATURE=yes\nPKGMK_NO_STRIP=yes\n" >config
    if [ "$lane" = old ]; then
        bash /tmp/reference-pkgmk -cf config -kw >out 2>err
    else
        /tmp/tools/pkgmk -cf config -kw >out 2>err
    fi
    [ -f fixture#1-1.pkg.tar.gz ]
    [ -f work/pkg/usr/share/man/man1/fixture.1.gz ]
    [ -L work/pkg/usr/share/man/man1/alias.1.gz ]
done
cmp /tmp/old/.footprint /tmp/new/.footprint
cmp /tmp/old/.md5sum /tmp/new/.md5sum
cmp /tmp/old/work/pkg/usr/share/fixture/data /tmp/new/work/pkg/usr/share/fixture/data
cd /tmp/new
cp Pkgfile newline-Pkgfile
cat >>Pkgfile <<"EOF"
build() {
 mkdir -p "$PKG/usr/share/man/man1"
 printf "manual\n" >"$PKG/usr/share/man/man1/line
break.1"
 ln -s "line
break.1" "$PKG/usr/share/man/man1/link
break.1"
}
EOF
/tmp/tools/pkgmk -cf config -if -f -kw >out 2>err
[ -f "work/pkg/usr/share/man/man1/line
break.1.gz" ]
[ -L "work/pkg/usr/share/man/man1/link
break.1.gz" ]
[ "$(readlink "work/pkg/usr/share/man/man1/link
break.1.gz")" = "line
break.1.gz" ]
mv newline-Pkgfile Pkgfile
/tmp/tools/pkgmk -cf config -f -kw >out 2>err
/tmp/tools/pkgmk -cf config -uf >out 2>err
grep -q "Footprint updated" out
# pkgadd remains external; a sandbox-local recorder checks delegation only.
mkdir /tmp/helpers
cat >/tmp/helpers/pkgadd <<"EOF"
#!/bin/dash
printf "%s\n" "$@" >/tmp/pkgadd-arguments
EOF
chmod +x /tmp/helpers/pkgadd
PATH=/tmp/helpers:$PATH /tmp/tools/pkgmk -cf config -i >out 2>err
printf "/tmp/new/fixture#1-1.pkg.tar.gz\n" >/tmp/expected-arguments
cmp /tmp/expected-arguments /tmp/pkgadd-arguments
PATH=/tmp/helpers:$PATH /tmp/tools/pkgmk -cf config -u >out 2>err
printf -- "-u\n/tmp/new/fixture#1-1.pkg.tar.gz\n" >/tmp/expected-arguments
cmp /tmp/expected-arguments /tmp/pkgadd-arguments
for compression in bz2 xz lz zst; do
    printf "\nPKGMK_COMPRESSION_MODE=%s\n" "$compression" >>config
    /tmp/tools/pkgmk -cf config -f >out 2>err
    bsdtar -xOf "fixture#1-1.pkg.tar.$compression" usr/share/fixture/data >payload
    cmp input payload
done
'
printf 'PASS: pkgmk persistent Bash build/config/source and CLI lifecycle\n'
