#!/usr/bin/env python3
"""Build only a NEW local raw-file /dev/nbd3 export; never attach an export.

Run with sudo python3. Sources must already be mounted read-only, with UTF-8
filename support on the source ESP. Preserve the
existing UEFI-only system; install reviewed applications later in the target VM.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import uuid

TARGET = "/dev/nbd3"
SIZE = 31042043904
ROOT_UUID = "7a328c21-d5fa-420e-ab31-3fa922210767"
ESP_UUID = "8732-FF9D"
MIB = 1024 * 1024
TYPES = ("21686148-6449-6e6f-744e-656564454649",
         "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
         "0fc63daf-8483-4772-8e79-3d69d8477de4")
LAYOUT = ((2048, 2048), (4096, 4194304), (4198400, 56428544))
MIN_FREE = 19 * 1024**3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          **kwargs).stdout.strip()


def table_from_json(data):
    table = data["partitiontable"]
    require(table["label"] == "gpt" and table["unit"] == "sectors"
            and table["sectorsize"] == 512, "Source metadata must be 512-sector GPT")
    parts = table["partitions"]
    require(len(parts) == 3, "Expected exactly BIOS, ESP, root partitions")
    require((parts[0]["start"], parts[0]["size"]) == LAYOUT[0],
            "Latest BIOS partition must start at 1 MiB and be exactly 1 MiB")
    ids = [str(uuid.UUID(table["id"]))]
    lines = ["label: gpt", "unit: sectors", "sector-size: 512",
             "label-id: " + ids[0]]
    for part, kind, (start, size) in zip(parts, TYPES, LAYOUT):
        require(part["type"].lower() == kind, "Unexpected partition order/type")
        guid = str(uuid.UUID(part["uuid"]))
        ids.append(guid)
        line = f"start={start}, size={size}, type={kind}, uuid={guid}"
        if "name" in part:
            require(re.fullmatch(r"[A-Za-z0-9 ._-]*", part["name"]) is not None,
                    "Unsafe partition name in metadata")
            line += ', name="' + part["name"] + '"'
        lines.append(line)
    require(len(set(ids)) == 4, "Disk and partition GUIDs must be unique")
    return "\n".join(lines) + "\n", parts


def verify_table(actual, latest):
    table, source = actual["partitiontable"], latest["partitiontable"]
    require(table["label"] == "gpt" and table["unit"] == "sectors"
            and table["sectorsize"] == 512, "Wrong target GPT geometry")
    require(uuid.UUID(table["id"]) == uuid.UUID(source["id"]), "Target disk GUID mismatch")
    require(len(table["partitions"]) == 3, "Wrong target partition count")
    for part, original, geometry in zip(table["partitions"], source["partitions"], LAYOUT):
        require((part["start"], part["size"]) == geometry, "Target partition geometry mismatch")
        require(uuid.UUID(part["uuid"]) == uuid.UUID(original["uuid"])
                and part["type"].lower() == original["type"].lower()
                and (part.get("name") or "") == (original.get("name") or ""),
                "Target partition identity mismatch")


def check_storage(export):
    rows = json.loads(run("findmnt", "--json", "--target", str(export),
                          "--output", "SOURCE,FSTYPE,OPTIONS"))["filesystems"]
    require(len(rows) == 1, "Cannot identify raw-file host filesystem")
    record = rows[0]
    require(record["fstype"] in ("ext4", "xfs", "btrfs")
            and "rw" in record["options"].split(",")
            and record["source"].startswith("/dev/"),
            "Raw file must reside on a writable local disk filesystem, not tmpfs/network")
    # Inverse lsblk follows device-mapper layers down to physical storage.
    devices = json.loads(run("lsblk", "--inverse", "--json", "--paths", "--output",
                             "NAME,TYPE", record["source"].split("[", 1)[0]))["blockdevices"]
    pending = list(devices)
    disks = []
    while pending:
        device = pending.pop()
        require(device["type"] in ("disk", "part", "lvm", "crypt", "raid0", "raid1",
                                  "raid5", "raid6", "raid10", "mpath"),
                "Unsupported host storage layer")
        if device["type"] == "disk":
            require(re.fullmatch(r"/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+)", device["name"]) is not None,
                    "Raw file storage is not a local physical disk")
            disks.append(device["name"])
        pending.extend(device.get("children", []))
    require(bool(disks), "Cannot establish local disk backing for raw file")
    space = os.statvfs(export)
    require(space.f_bavail * space.f_frsize >= MIN_FREE,
            "Raw-file host filesystem needs at least 19 GiB real free space")


def read_bios(source_disk, part):
    sys_disk = Path("/sys/class/block") / Path(source_disk).name
    candidates = [p for p in sys_disk.glob("*") if (p / "partition").is_file()
                  and (p / "partition").read_text().strip() == "1"]
    require(len(candidates) == 1, "Cannot identify latest BIOS source partition")
    sys_part = candidates[0]
    require((int((sys_part / "start").read_text()), int((sys_part / "size").read_text()))
            == LAYOUT[0], "Live BIOS source geometry differs from metadata")
    device = "/dev/" + sys_part.name
    require(run("blkid", "-s", "PARTUUID", "-o", "value", device).lower()
            == part["uuid"].lower(), "BIOS source partition GUID mismatch")
    require(run("blockdev", "--getro", source_disk) == "1"
            and run("blockdev", "--getro", device) == "1"
            and run("blockdev", "--getsize64", device) == str(MIB),
            "BIOS source disk/partition must be read-only and exactly 1 MiB")
    with open(source_disk, "rb", buffering=0) as disk:
        boot = disk.read(440)
        require(len(boot) == 440 and not any(boot), "Latest MBR boot code is not zero")
    with open(device, "rb", buffering=0) as disk:
        data = disk.read(MIB)
    require(len(data) == MIB, "Short BIOS source read")
    return data


def copy_bios(data):
    require(len(data) == MIB, "BIOS copy must be exactly 1 MiB")
    require(run("blockdev", "--getsize64", TARGET + "p1") == str(MIB),
            "Target BIOS partition size mismatch")
    with open(TARGET + "p1", "r+b", buffering=0) as disk:
        require(disk.write(data) == MIB, "Short target BIOS write")
        disk.flush()
        os.fsync(disk.fileno())
        disk.seek(0)
        require(disk.read(MIB) == data, "Target BIOS partition copy mismatch")
    with open(TARGET, "rb", buffering=0) as disk:
        boot = disk.read(440)
        require(len(boot) == 440 and not any(boot), "Target MBR boot code is not zero")


def check_export(path, cmdline):
    # Deliberately accept only the simple local qemu-nbd raw-file invocation.
    args = cmdline[1:]
    require(Path(cmdline[0]).name == "qemu-nbd", "Export is not local qemu-nbd")
    target = fmt = None
    files = []
    while args:
        arg = args.pop(0)
        if arg in ("--connect", "-c", "--format", "-f"):
            require(bool(args), "Missing qemu-nbd option value")
            value = args.pop(0)
            if arg in ("--connect", "-c"):
                target = value
            else:
                fmt = value
        elif arg.startswith("--connect="):
            target = arg.split("=", 1)[1]
        elif arg.startswith("--format="):
            fmt = arg.split("=", 1)[1]
        elif arg in ("--persistent", "--fork"):
            pass
        else:
            require(not arg.startswith("-"), "Unsupported qemu-nbd option: " + arg)
            files.append(arg)
    require(target == TARGET and fmt == "raw" and len(files) == 1,
            "Require local qemu-nbd --connect=/dev/nbd3 --format=raw FILE")
    require(Path(files[0]).resolve(strict=True) == path,
            "Export process does not name the supplied host file")


def mount_record(path):
    records = json.loads(run("findmnt", "--json", "--mountpoint", str(path),
                             "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID,LABEL,MAJ:MIN"))
    rows = records["filesystems"]
    require(len(rows) == 1 and Path(rows[0]["target"]) == path, "Exact mount required")
    return rows[0]


def source_check(path, kind, identity):
    record = mount_record(path)
    require(record["fstype"] == kind and record["uuid"].lower() == identity.lower(),
            "Wrong source filesystem/UUID")
    options = record["options"].split(",")
    require("ro" in options, "Source must be mounted read-only")
    if kind == "vfat":
        require(bool(set(options) & {"iocharset=utf8", "utf8", "utf8=1"}),
                "Source ESP must be mounted with iocharset=utf8 or explicit utf8")
    major_minor = record["maj:min"]
    device = Path("/sys/dev/block", major_minor).resolve(strict=True)
    require(device.name != "nbd3" and device.parent.name != "nbd3",
            "Source overlaps target")
    # A writable alias could modify a supposedly read-only source during copying.
    all_mounts = json.loads(run("findmnt", "--json", "--list", "--output",
                               "MAJ:MIN,OPTIONS"))["filesystems"]
    require(all("ro" in m["options"].split(",") for m in all_mounts
                if m["maj:min"] == major_minor), "Source has a writable mount alias")
    return record


def safe_guest(root, relative):
    path = root / relative
    require(path.parent.resolve(strict=True).is_relative_to(root),
            "Guest parent symlink escapes target: " + relative)
    return path


def critical_manifest(esp):
    files = [("esp/" + str(p.relative_to(esp)), p) for p in esp.rglob("*") if p.is_file()]
    names = {name.lower() for name, _ in files}
    require("esp/efi/boot/bootx64.efi" in names, "Missing EFI fallback executable")
    require("esp/qemu/qemu-system-x86_64.exe" in names, "Missing Windows QEMU executable")
    result = {}
    for name, path in files:
        require(path.resolve(strict=True).is_relative_to(esp), "Critical file escapes source")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(MIB), b""):
                digest.update(block)
        result[name] = digest.hexdigest()
    return result


def reject_diagnostics(root):
    for path in (root / "etc").rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name.startswith("diagnostic-"):
            raise ValueError("Diagnostic configuration in latest source: " + str(path))
        relative = str(path.relative_to(root))
        if relative.startswith(("etc/systemd/system/", "etc/sddm.conf", "etc/apparmor.d/")):
            data = path.read_bytes()
            require(not any(marker in data for marker in
                            (b"--autologin root", b"Diagnostic SSD trial only",
                             b"Diagnostic overlay only", b"pf-diagnostic-only",
                             b"pf-diagnostic", b"/tmp/pf-firefox")),
                    "Possible diagnostic configuration: " + relative)
            if relative.startswith("etc/sddm.conf"):
                require(b"User=root" not in data, "Root SDDM diagnostic autologin")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity-json", type=Path, required=True,
                        help="LATEST source disk sfdisk --json output, including all GUIDs")
    parser.add_argument("--latest-root", type=Path, required=True)
    parser.add_argument("--latest-esp", type=Path, required=True)
    parser.add_argument("--work-parent", type=Path, required=True,
                        help="Existing directory under /tmp/opencode")
    parser.add_argument("--export-file", type=Path, required=True,
                        help="New regular raw file already exported locally on /dev/nbd3")
    args = parser.parse_args()
    require(os.geteuid() == 0, "Root required")
    root, esp, parent, export = [p.resolve(strict=True) for p in
                                (args.latest_root, args.latest_esp,
                                 args.work_parent, args.export_file)]
    require(parent.is_dir() and parent.is_relative_to(Path("/tmp/opencode")),
            "Work parent must exist under /tmp/opencode")
    require(stat.S_ISREG(export.stat().st_mode) and export.stat().st_size == SIZE,
            "Export must be an exact-size regular host raw file")
    require(not export.is_relative_to(Path("/dev")), "No device-backed export path")
    check_storage(export)
    metadata = json.loads(args.identity_json.read_text())
    script, parts = table_from_json(metadata)
    root_info = source_check(root, "ext4", ROOT_UUID)
    esp_info = source_check(esp, "vfat", ESP_UUID)
    require(root_info["maj:min"] != esp_info["maj:min"], "Sources must be separate filesystems")
    export_fs = f"{os.major(export.stat().st_dev)}:{os.minor(export.stat().st_dev)}"
    require(export_fs not in (root_info["maj:min"], esp_info["maj:min"]),
            "Export file resides on a source filesystem")
    mount_targets = json.loads(run("findmnt", "--json", "--list", "--output", "TARGET"))["filesystems"]
    require(all(not Path(m["target"]).is_relative_to(root)
                or Path(m["target"]) in (root, esp) for m in mount_targets),
            "Unexpected nested source mount; refusing an incomplete root copy")
    source_disks = []
    for info, part in ((esp_info, parts[1]), (root_info, parts[2])):
        device = info["source"]
        require(device.startswith("/dev/") and "[" not in device, "Whole source partition mount required")
        require(run("blkid", "-s", "PARTUUID", "-o", "value", device).lower()
                == part["uuid"].lower(), "Source PARTUUID differs from supplied latest metadata")
        sys_device = Path("/sys/dev/block", info["maj:min"]).resolve(strict=True)
        require((sys_device / "partition").is_file(), "Source is not a whole partition")
        source_disk = "/dev/" + sys_device.parent.name
        source_disks.append(source_disk)
        require(run("blkid", "-s", "PTUUID", "-o", "value", source_disk).lower()
                == str(uuid.UUID(metadata["partitiontable"]["id"])),
                "Source disk GUID differs from supplied latest metadata")
    require(source_disks[0] == source_disks[1], "Sources must belong to the same latest disk")
    require(source_disks[0] != TARGET, "BIOS source disk overlaps target")
    bios = read_bios(source_disks[0], parts[0])
    reject_diagnostics(root)
    swap = root / "swap.img"
    require(swap.is_file() and not swap.is_symlink() and swap.stat().st_size == 4 * 1024**3,
            "Expected verified 4 GiB latest swap.img; refusing to reduce or guess")
    manifest = critical_manifest(esp)
    require(stat.S_ISBLK(os.stat(TARGET).st_mode), "Target is not a block device")
    pid = int(Path("/sys/block/nbd3/pid").read_text().strip())
    cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0").decode().split("\0")
    check_export(export, cmdline)
    require(run("blockdev", "--getsize64", TARGET) == str(SIZE)
            and run("blockdev", "--getss", TARGET) == "512"
            and run("blockdev", "--getro", TARGET) == "0", "Wrong target geometry/access")
    require(not list(Path("/sys/block/nbd3").glob("nbd3p*")), "Target already has partitions")
    target_id = Path("/sys/block/nbd3/dev").read_text().strip()
    mounts = json.loads(run("findmnt", "--json", "--list", "--output", "MAJ:MIN"))["filesystems"]
    require(all(m["maj:min"] != target_id for m in mounts), "Target is mounted")
    require(not list(Path("/sys/block/nbd3/holders").iterdir()), "Target has holders")
    # Inspect both GPT ends and all first boot/BIOS areas, not only the signature.
    with open(TARGET, "rb", buffering=0) as disk:
        require(not any(disk.read(2 * MIB)), "Target first GPT/boot areas are not zero")
        disk.seek(SIZE - MIB)
        require(not any(disk.read(MIB)), "Target backup GPT area is not zero")
    # Revalidate sources immediately before the first target write.
    source_check(root, "ext4", ROOT_UUID)
    source_check(esp, "vfat", ESP_UUID)
    work = Path(tempfile.mkdtemp(prefix="latest-offline-", dir=parent))
    target_root, target_esp = work / "root", work / "esp"
    target_root.mkdir()
    target_esp.mkdir()
    mounted = []
    def interrupted(signum, frame):
        raise SystemExit(f"Interrupted by signal {signum}; unmounting owned target mounts")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        run("sfdisk", "--wipe", "never", "--wipe-partitions", "never", TARGET, input=script)
        run("udevadm", "settle")
        run("sfdisk", "--verify", TARGET)
        actual = json.loads(run("sfdisk", "--json", TARGET))
        verify_table(actual, metadata)
        for index in (1, 2, 3):
            require(stat.S_ISBLK(os.stat(TARGET + f"p{index}").st_mode), "Missing target partition")
        copy_bios(bios)
        run("mkfs.vfat", "-F", "32", "-i", ESP_UUID.replace("-", ""),
            *(["-n", esp_info["label"]] if esp_info["label"] else []), TARGET + "p2")
        run("mkfs.ext4", "-U", ROOT_UUID,
            *(["-L", root_info["label"]] if root_info["label"] else []), TARGET + "p3")
        for device, destination, options in (
                (TARGET + "p3", target_root, "nodev,nosuid,noexec"),
                (TARGET + "p2", target_esp, "nodev,nosuid,noexec,iocharset=utf8")):
            run("mount", "-o", options, device, str(destination))
            mounted.append(destination)
        excludes = ["/dev/***", "/proc/***", "/sys/***", "/run/***", "/tmp/***",
                    "/mnt/***", "/media/***", "/boot/efi/***", "/swap.img"]
        run("rsync", "-aHAXS", "--numeric-ids", "--one-file-system",
            *("--exclude=" + item for item in excludes), str(root) + "/", str(target_root) + "/")
        run("rsync", "-rt", "--checksum", str(esp) + "/", str(target_esp) + "/")
        require(manifest == critical_manifest(target_esp),
                "EFI/QEMU file count or SHA256 mismatch")
        for directory in ("dev", "proc", "sys", "run", "tmp", "mnt", "media", "boot/efi"):
            path = safe_guest(target_root, directory)
            require(not path.is_symlink(), "Unsafe virtual directory")
            path.mkdir(exist_ok=True)
        (target_root / "tmp").chmod(0o1777)
        link = safe_guest(target_root, "etc/systemd/system/multi-user.target.wants/first-boot-setup.service")
        if link.is_symlink():
            require(os.readlink(link) == "/etc/systemd/system/first-boot-setup.service",
                    "Unexpected first-boot enablement link")
            link.unlink()
        require(not link.exists(), "First-boot enablement path is not a symlink")
        require(not list((target_root / "etc/systemd/system").glob(
            "*.wants/first-boot-setup.service")) and not list(
            (target_root / "etc/systemd/system").glob("*.requires/first-boot-setup.service")),
            "Another heavy first-boot enablement link remains")
        swap_target = safe_guest(target_root, "swap.img")
        run("fallocate", "-l", str(swap.stat().st_size), str(swap_target))
        swap_target.chmod(0o600)
        run("mkswap", str(swap_target))
        reject_diagnostics(target_root)
        run("sync", "-f", str(target_root))
        run("sync", "-f", str(target_esp))
        while mounted:
            run("umount", str(mounted[-1]))
            mounted.pop()
        run("sfdisk", "--verify", TARGET)
        run("e2fsck", "-f", "-n", TARGET + "p3")
        print(f"Built latest-source target. Verified {len(manifest)} EFI/QEMU hashes. Work: {work}")
        print("Preserved UEFI-only system and 1 MiB BIOS partition contents; no BIOS boot support added.")
        print("Install reviewed applications later in the target VM.")
    finally:
        # Never force/lazy unmount, delete mount trees, detach NBD, or touch sources.
        for destination in reversed(mounted):
            subprocess.run(["umount", str(destination)], check=False)
        print(f"Retained work directory: {work}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Refused/failed: {error}")
