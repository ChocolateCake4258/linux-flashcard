#!/usr/bin/env python3
"""Conservative three-way user-data merge into an already copied latest root."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import uuid

UUID = "7a328c21-d5fa-420e-ab31-3fa922210767"


def require(condition):
    if not condition:
        raise RuntimeError("Safety check failed")


def check_mounts(roots):
    require(os.geteuid() == 0)
    result = subprocess.run(
        ["findmnt", "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID,MAJ:MIN"],
        check=True, capture_output=True, text=True,
    )
    mounts = []

    def collect(items):
        for item in items:
            mounts.append(item)
            collect(item.get("children", []))

    collect(json.loads(result.stdout)["filesystems"])
    devices = []
    for index, root in enumerate(roots):
        require(root.is_absolute() and str(root) == os.path.realpath(root))
        matches = [m for m in mounts if m["target"] == str(root)]
        require(len(matches) == 1)
        mount = matches[0]
        options = set(mount["options"].split(","))
        require(mount["fstype"] == "ext4" and mount.get("uuid") == UUID)
        require(("ro" if index < 3 else "rw") in options)
        require(("rw" if index < 3 else "ro") not in options)
        require(not any(m["target"].startswith(str(root) + "/") for m in mounts))
        require(bool(mount.get("maj:min")))
        devices.append(mount["maj:min"])
        if index == 3:
            require(mount["source"] == "/dev/nbd3p3")
    require(len(set(devices)) == 4)


def safe_parents(root, relative):
    current = root
    for part in Path(relative).parts[:-1]:
        current = current / part
        require(stat.S_ISDIR(current.lstat().st_mode))


def inventory(root):
    entries = {}

    def visit(relative):
        path = root / relative
        info = path.lstat()
        mode = info.st_mode
        if stat.S_ISDIR(mode):
            kind, content = "directory", None
        elif stat.S_ISREG(mode):
            kind = "file"
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
                content = hashlib.file_digest(stream, "sha256").hexdigest()
        elif stat.S_ISLNK(mode):
            kind, content = "symlink", os.readlink(path)
        elif stat.S_ISFIFO(mode):
            kind, content = "fifo", None
        elif stat.S_ISSOCK(mode):
            kind, content = "socket", None
        elif stat.S_ISCHR(mode):
            kind, content = "character-device", info.st_rdev
        elif stat.S_ISBLK(mode):
            kind, content = "block-device", info.st_rdev
        else:
            kind, content = "special", info.st_rdev
        attrs = tuple(sorted(
            (name, os.getxattr(path, name, follow_symlinks=False))
            for name in os.listxattr(path, follow_symlinks=False)
        ))
        entries[relative] = (kind, content, info.st_uid, info.st_gid,
                             stat.S_IMODE(mode), attrs)
        if kind == "directory":
            with os.scandir(path) as children:
                for child in sorted(children, key=lambda item: item.name):
                    visit(relative + "/" + child.name)

    for relative in ("home", "root"):
        path = root / relative
        if os.path.lexists(path):
            require(stat.S_ISDIR(path.lstat().st_mode))
            visit(relative)
    return entries


def usernames(root):
    safe_parents(root, "etc/passwd")
    with os.fdopen(os.open(root / "etc/passwd", os.O_RDONLY | os.O_NOFOLLOW),
                   "r", encoding="utf-8") as stream:
        result = {}
        for line in stream:
            fields = line.rstrip("\n").split(":")
            require(len(fields) == 7 and fields[0] not in result)
            result[fields[0]] = int(fields[2])
    return result


def check_usernames(latest, prepared):
    latest_ids = {uid: name for name, uid in latest.items()}
    prepared_ids = {uid: name for name, uid in prepared.items()}
    require(len(latest_ids) == len(latest) and len(prepared_ids) == len(prepared))
    require(all(latest[name] == prepared[name] for name in latest.keys() & prepared.keys()))
    require(all(latest_ids[uid] == prepared_ids[uid]
                for uid in latest_ids.keys() & prepared_ids.keys()))
    return latest_ids, prepared_ids


def excluded(path):
    parts = path.split("/")
    return (
        any(part in {".cache", "__pycache__", ".pytest_cache", ".mypy_cache",
                     ".ruff_cache", "_cacache", "Cache", "Caches", "caches",
                     "Code Cache", "GPUCache"} for part in parts)
        or path in {"home/student/pf-geogebra-check.ggb",
                    "home/student/hs_err_pid3169.log", "root/.bash_history"}
        or "/.local/share/jupyter/runtime" in "/" + path
        or "/.jupyter/runtime" in "/" + path
    )


def protected(path):
    parts = path.split("/")
    return (
        any(part in {".ssh", ".gnupg", ".aws", ".azure", ".kube", ".npmrc",
                     ".netrc", ".git-credentials", ".env", "keyrings", "kwallet",
                     "kwalletd", ".mozilla", "chromium", "google-chrome",
                     "BraveSoftware", "firefox", "microsoft-edge", "opera",
                     "vivaldi"} or part.endswith(".kwl")
            or part.startswith(("google-chrome-", "chromium-", "microsoft-edge-"))
            for part in parts)
        or "/.docker/config.json" in "/" + path
    )


def plan_merge(base, latest, prepared):
    imports, conflicts = [], []
    for path, value in sorted(prepared.items(), key=lambda item: (item[0].count("/"), item[0])):
        if excluded(path) or value == latest.get(path):
            continue
        if value == base.get(path) and not protected(path):
            continue
        ancestors = [str(parent) for parent in Path(path).parents if str(parent) != "."]
        blocked = any(parent in latest and latest[parent][0] != "directory"
                      for parent in ancestors)
        collision = path in latest and latest[path][0] != value[0]
        if (value[0] not in {"file", "directory", "symlink"}
                or protected(path) or blocked or collision or latest.get(path) != base.get(path)):
            conflicts.append(path)
        else:
            imports.append(path)
    return imports, conflicts


def copy_selected(source, destination, paths):
    if not paths:
        return
    # Explicit directories carry metadata, never their unselected descendants.
    with tempfile.TemporaryFile() as manifest:
        manifest.write(b"".join(os.fsencode(path) + b"\0" for path in paths))
        manifest.seek(0)
        subprocess.run(
            ["rsync", "-aHAXS", "--numeric-ids", "--from0", "--files-from=-",
             "--no-recursive", "--dirs", "--relative", "--no-implied-dirs",
             "--", str(source) + "/", str(destination) + "/"],
            stdin=manifest, check=True, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def merge(base, latest, prepared, target):
    roots = tuple(Path(os.path.abspath(root)) for root in (base, latest, prepared, target))
    check_mounts(roots)
    base, latest, prepared, target = roots
    latest_ids, prepared_ids = check_usernames(usernames(latest), usernames(prepared))
    b, l, p, t = (inventory(root) for root in roots)
    require(t == l)
    imports, conflicts = plan_merge(b, l, p)
    # Missing target parent directories must be selected too, even if P metadata
    # matches B but L deleted them. Such deletions are conflicts, not resurrection.
    for path in imports[:]:
        for parent in Path(path).parents:
            name = str(parent)
            if name != "." and name not in t and name not in imports:
                imports.remove(path)
                conflicts.append(path)
                break
    for path in imports + conflicts:
        uid = p[path][2]
        require(uid in latest_ids and uid in prepared_ids
                and latest_ids[uid] == prepared_ids[uid])
    check_mounts(roots)
    backup = None
    if conflicts:
        safe_parents(target, "var/backups/placeholder")
        backup = target / "var/backups" / ("linux-flashcard-migration-" + uuid.uuid4().hex)
        os.mkdir(backup, 0o700)
        os.chmod(backup, 0o700)
        archive = backup / "prepared"
        os.mkdir(archive, 0o700)
        special_nodes = {
            path: {"kind": p[path][0], "device": p[path][1], "uid": p[path][2],
                   "gid": p[path][3], "mode": p[path][4],
                   "xattrs": {name: value.hex() for name, value in p[path][5]}}
            for path in sorted(set(conflicts))
            if p[path][0] not in {"file", "directory", "symlink"}
        }
        # Never recreate runtime IPC endpoints or devices, even in the archive.
        copy_selected(prepared, archive,
                      sorted(set(conflicts) - special_nodes.keys()))
        with os.fdopen(os.open(backup / "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                               0o600), "w", encoding="ascii") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump({"imported": imports, "archived": sorted(set(conflicts)),
                       "special_nodes": special_nodes}, stream,
                      ensure_ascii=True)
    copy_selected(prepared, target, imports)
    return {"imported": len(imports), "archived": len(set(conflicts))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base", "latest", "prepared", "target"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    try:
        counts = merge(args.base, args.latest, args.prepared, args.target)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("Merge failed; no source data was modified.")
        return 1
    print("Imported: {imported}; archived: {archived}".format(**counts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
