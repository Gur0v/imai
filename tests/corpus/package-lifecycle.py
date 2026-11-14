#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fresh-root ISO differentials; not a cumulative system-installation sweep."""

import argparse
import base64
import hashlib
import json
import os
import posixpath
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


ISO_SHA256 = "8eebf2a58114def46b78fe4fb2afb3175d9becd583699ed2b5e9e2660521e31f"
SECTIONS = {"core": 126, "opt": 101, "xorg": 98}


def digest(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def encoded(data):
    return base64.b64encode(data).decode("ascii")


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def manifest(root, timestamp_paths):
    records = []
    links = {}
    # Never follow symlinks, and never open a FIFO, socket, or device for hashing.
    def visit(directory):
        for entry in sorted(os.scandir(directory), key=lambda e: os.fsencode(e.name)):
            path = Path(entry.path)
            info = entry.stat(follow_symlinks=False)
            name = str(path.relative_to(root))
            record = {"path": name, "type": stat.S_IFMT(info.st_mode),
                      "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid,
                      "gid": info.st_gid}
            if name in timestamp_paths:
                record["mtime_ns"] = info.st_mtime_ns
            if not stat.S_ISDIR(info.st_mode) and info.st_nlink > 1:
                key = (info.st_dev, info.st_ino)
                record["hardlink"] = links.setdefault(key, name)
                record["nlink"] = info.st_nlink
            if stat.S_ISREG(info.st_mode):
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    actual = os.fstat(stream.fileno())
                    if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
                        raise RuntimeError("file changed while manifesting")
                    record["size"] = actual.st_size
                    record["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
            elif stat.S_ISLNK(info.st_mode):
                record["target"] = os.readlink(path)
            elif stat.S_ISCHR(info.st_mode) or stat.S_ISBLK(info.st_mode):
                record["rdev"] = [os.major(info.st_rdev), os.minor(info.st_rdev)]
            records.append(record)
            if stat.S_ISDIR(info.st_mode):
                visit(path)
    visit(root)
    return sorted(records, key=lambda record: os.fsencode(record["path"]))


def database(root):
    result = {}
    for name in ("db", "db.backup", "db.incomplete_transaction"):
        path = root / "var/lib/pkg" / name
        if not path.exists():
            result[name] = None
            continue
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise RuntimeError("nonregular database artifact")
            result[name] = encoded(stream.read())
    return result


def worker(package_name):
    os.umask(0o022)
    os.chdir("/tmp")
    root = Path("/tmp/root")
    (root / "var/lib/pkg").mkdir(parents=True)
    (root / "var/lib/pkg/db").touch()
    archive_path = "/tmp/lane/" + os.environ["PACKAGE_BASENAME"]
    with tarfile.open(archive_path, "r:*") as archive:
        timestamp_paths = {posixpath.normpath(e.name) for e in archive
                           if not e.isdir()}
    # DB/helper outputs have runtime-generated mtimes, unlike package payloads.
    timestamp_paths -= {"var/lib/pkg/db", "var/lib/pkg/db.backup",
                        "etc/ld.so.cache", "etc/ld.so.cache~"}
    result = {}
    for phase, command in (
        ("install", ["/tmp/lane/pkgadd", "-r", str(root), "/tmp/lane/package"]),
        ("remove", ["/tmp/lane/pkgrm", "-r", str(root), package_name]),
    ):
        # Preserve the archive basename: pkgadd obtains package identity from it.
        if phase == "install":
            command[-1] = "/tmp/lane/" + os.environ["PACKAGE_BASENAME"]
        operation = subprocess.run(command, capture_output=True, check=False)
        result[phase] = {
            "status": operation.returncode,
            "stdout": encoded(operation.stdout), "stderr": encoded(operation.stderr),
            "database": database(root),
            "manifest": manifest(root, timestamp_paths),
        }
        if phase == "install" and operation.returncode != 0:
            result["remove"] = {"not_run": "installation returned nonzero"}
            break
    print(json.dumps(result, sort_keys=True))


def sandbox_options():
    # No writable host bind: results leave through the stdout pipe only.
    return ["bwrap", "--unshare-all", "--die-with-parent", "--new-session",
            "--uid", "0", "--gid", "0", "--ro-bind", "/", "/",
            "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
            "--tmpfs", "/run", "--tmpfs", "/tmp/lane", "--chdir", "/tmp",
            "--clearenv", "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "LC_ALL", "C", "--setenv", "HOME", "/tmp"]


def probe(python):
    code = """import errno,json,os,pathlib
p=pathlib.Path('/tmp/probe'); p.touch()
try:
    os.chown(p,1,1)
    owner={'nonroot_chown':True}
except OSError as error:
    owner={'nonroot_chown':False,'errno':error.errno}
try:
    os.mknod('/tmp/probe-device',0o020600,os.makedev(1,3))
    owner['mknod']=True
except OSError as error:
    owner['mknod']=False
    owner['mknod_errno']=error.errno
owner['uid_map']=pathlib.Path('/proc/self/uid_map').read_text()
owner['gid_map']=pathlib.Path('/proc/self/gid_map').read_text()
print(json.dumps(owner))
"""
    completed = subprocess.run(sandbox_options() + [python, "-I", "-c", code],
                               capture_output=True, check=True, timeout=30)
    return json.loads(completed.stdout)


def snapshot(source, destination):
    shutil.copyfile(source, destination)
    destination.chmod(0o555)
    value = digest(destination)
    if digest(source) != value:
        raise RuntimeError(f"source changed while snapshotting: {source}")
    return value


def run_side(work, side, package, name, python, timeout):
    options = sandbox_options()
    for command in ("pkgadd", "pkgrm"):
        options += ["--ro-bind", str(work / side / command), "/tmp/lane/" + command]
    options += ["--ro-bind", str(work / "worker.py"), "/tmp/lane/worker.py",
                "--ro-bind", str(package), "/tmp/lane/" + package.name,
                "--ro-bind", str(work / "ldconfig"), "/sbin/ldconfig",
                "--setenv", "PACKAGE_BASENAME", package.name]
    completed = subprocess.run(options + [python, "-I", "/tmp/lane/worker.py",
                                          "--worker", name],
                               capture_output=True, timeout=timeout, check=False)
    if completed.returncode != 0:
        raise RuntimeError(f"sandbox worker failed ({completed.returncode}): "
                           + completed.stderr.decode(errors="replace"))
    if completed.stderr:
        raise RuntimeError("unexpected sandbox worker stderr: "
                           + completed.stderr.decode(errors="replace"))
    return json.loads(completed.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("candidate", type=Path, help="directory containing pkgadd/pkgrm")
    parser.add_argument("reference", type=Path, help="directory containing pkgadd/pkgrm")
    parser.add_argument("--iso", required=True, type=Path,
                        help="pinned CRUX 3.8 ISO; checksum verified before use")
    parser.add_argument("--limit", type=int, default=3, help="smoke count (default 3)")
    parser.add_argument("--full", action="store_true", help="explicitly enable all 325")
    parser.add_argument("--package", action="append", default=[],
                        help="select package name for smoke testing (repeatable)")
    parser.add_argument("--timeout", type=int, default=600,
                        help="seconds per isolated install/remove pair")
    args = parser.parse_args()
    if args.limit < 1 or args.timeout < 1:
        parser.error("limit and timeout must be positive")
    if args.full and args.package:
        parser.error("--full cannot select a smoke subset")
    for utility in ("bwrap", "bsdtar"):
        if not shutil.which(utility):
            parser.error(f"required utility unavailable: {utility}")
    corpus = args.corpus.resolve(strict=True)
    iso = args.iso.resolve(strict=True)
    packages = []
    for section, count in SECTIONS.items():
        members = sorted((corpus / "crux" / section).glob("*.pkg.tar.*"))
        if len(members) != count:
            parser.error(f"expected {count} {section} archives, found {len(members)}")
        packages.extend(members)
    work = Path(tempfile.mkdtemp(prefix="imai-corpus-mutations."))
    print(f"results: {work}", flush=True)
    report = {"complete": False, "mode": "full" if args.full else "smoke",
              "iso_sha256": digest(iso), "packages": [], "limitations": [
                  "fresh per-package roots, not a cumulative installation",
                  "atime/ctime excluded; mtime compared for explicit non-directory payloads only",
                  "directory, DB and ldconfig-generated mtimes are runtime-dependent",
                  "actual host ldconfig snapshot used, with host runtime read-only",
                  "nonzero install/remove statuses never count as successful gates"]}
    save(work / "report.json", report)
    if report["iso_sha256"] != ISO_SHA256:
        raise RuntimeError("ISO does not match pinned CRUX 3.8 checksum")
    report["corpus"] = [{"path": str(p.relative_to(corpus)),
                          "sha256": digest(p)} for p in packages]
    for side in ("candidate", "reference"):
        (work / side).mkdir()
        directory = getattr(args, side).resolve(strict=True)
        report[side] = {command: snapshot(directory / command, work / side / command)
                        for command in ("pkgadd", "pkgrm")}
    report["ldconfig_sha256"] = snapshot(Path("/sbin/ldconfig"), work / "ldconfig")
    snapshot(Path(__file__).resolve(), work / "worker.py")
    python = str(Path(sys.executable).resolve())
    save(work / "report.json", report)
    report["ownership_probe"] = probe(python)
    save(work / "report.json", report)
    selected = packages
    if args.package:
        selected = [p for p in packages if p.name.split("#")[0] in args.package]
        if {p.name.split("#")[0] for p in selected} != set(args.package):
            raise RuntimeError("requested package missing from pinned corpus")
    elif not args.full:
        selected = packages[:args.limit]
    (work / "archives").mkdir()
    failed = blocked = 0
    for index, source in enumerate(selected, 1):
        member = str(source.relative_to(corpus))
        package = work / "archives" / source.name
        # bsdtar only streams this one member; it never extracts onto the host.
        with package.open("wb") as output:
            subprocess.run(["bsdtar", "-xOf", str(iso), member], stdout=output,
                           check=True, timeout=args.timeout)
        archive_hash = digest(package)
        expected = next(p["sha256"] for p in report["corpus"] if p["path"] == member)
        if archive_hash != expected:
            raise RuntimeError(f"corpus archive differs from pinned ISO: {member}")
        item = {"member": member, "sha256": archive_hash}
        with tarfile.open(package, "r:*") as archive:
            entries = archive.getmembers()
        owners = sorted({(e.uid, e.gid) for e in entries if e.uid or e.gid})
        devices = [e.name for e in entries if e.ischr() or e.isblk()]
        blockers = []
        if owners and not report["ownership_probe"]["nonroot_chown"]:
            blockers.append("non-root ownership unavailable in bubblewrap mapping")
        if devices and not report["ownership_probe"]["mknod"]:
            blockers.append("device creation unavailable in bubblewrap namespace")
        if blockers:
            item.update(result="environment-blocked", required_owners=owners,
                        required_devices=devices, reasons=blockers)
            blocked += 1
        else:
            directory = work / f"{index:03d}"
            directory.mkdir()
            results = {}
            for side in ("candidate", "reference"):
                results[side] = run_side(work, side, package,
                                         source.name.split("#")[0], python, args.timeout)
                save(directory / (side + ".json"), results[side])
            different = results["candidate"] != results["reference"]
            nonzero = any(value.get("status", 1) != 0
                          for result in results.values() for value in result.values())
            lifecycle_invalid = any(
                result["install"].get("database", {}).get("db") in (None, "")
                or result["remove"].get("database", {}).get("db") != ""
                for result in results.values())
            item.update(result="mismatch" if different else
                        "matching-failure" if nonzero or lifecycle_invalid else "exact",
                        artifacts=str(directory), lifecycle_invalid=lifecycle_invalid)
            if different or nonzero or lifecycle_invalid:
                failed += 1
        report["packages"].append(item)
        print(f"{index}/{len(selected)} {item['result']}: {member}", flush=True)
        save(work / "report.json", report)
    report.update(complete=True, selected=len(selected), failures=failed, blocked=blocked,
                  gate_passed=args.full and not failed and not blocked)
    save(work / "report.json", report)
    print(f"selected={len(selected)} failures={failed} blocked={blocked}", flush=True)
    return 1 if failed else 2 if blocked else 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        worker(sys.argv[2])
    else:
        try:
            sys.exit(main())
        except (OSError, RuntimeError, subprocess.SubprocessError, tarfile.TarError) as error:
            print(f"corpus-mutations: {error}", file=sys.stderr)
            sys.exit(2)
