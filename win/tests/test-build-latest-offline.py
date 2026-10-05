"""Offline fixtures only: no block devices, mounts, subprocesses, or disk images."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import mock_open, patch

spec = importlib.util.spec_from_file_location(
    "builder", Path(__file__).with_name("build-latest-offline.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.metadata = {"partitiontable": {
            "label": "gpt", "unit": "sectors", "sectorsize": 512,
            "id": "10000000-0000-4000-8000-000000000000",
            "partitions": [{"type": kind, "uuid": f"20000000-0000-4000-8000-{i:012d}",
                            "start": 2048, "size": 2048, "name": name}
                           for i, (kind, name) in enumerate(
                               zip(builder.TYPES, ("BIOS", "ESP", "root")), 1)]}}

    def test_exact_layout_and_preserved_identity(self):
        text, parts = builder.table_from_json(self.metadata)
        self.assertIn("label-id: " + self.metadata["partitiontable"]["id"], text)
        for part, (start, size) in zip(parts, builder.LAYOUT):
            self.assertIn(f"start={start}, size={size}", text)
            self.assertIn(part["uuid"], text)
        start, size = builder.LAYOUT[2]
        self.assertEqual(start * 512, 2050 * builder.MIB)
        self.assertEqual(size * 512, 28891414528)
        self.assertEqual((start + size) * 512, 29603 * builder.MIB)
        self.assertLess((start + size) * 512, builder.SIZE - 33 * 512)

    def test_missing_invalid_duplicate_guids_and_wrong_types(self):
        for field, value in (("uuid", None), ("uuid", "not-a-guid"),
                             ("uuid", self.metadata["partitiontable"]["id"]),
                             ("type", builder.TYPES[1]), ("name", 'bad"\n/dev/sda')):
            data = copy.deepcopy(self.metadata)
            if value is None:
                del data["partitiontable"]["partitions"][0][field]
            else:
                data["partitiontable"]["partitions"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises((ValueError, KeyError)):
                builder.table_from_json(data)
        self.metadata["partitiontable"]["sectorsize"] = 4096
        with self.assertRaises(ValueError):
            builder.table_from_json(self.metadata)

    def test_only_local_raw_nbd3_export(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            host = Path(directory) / "host-file"
            host.touch()
            good = ["/usr/bin/qemu-nbd", "--connect=/dev/nbd3", "--format=raw", str(host)]
            builder.check_export(host, good)
            builder.check_export(host, ["qemu-nbd", "-c", "/dev/nbd3", "-f", "raw", str(host)])
            for args in (["qemu-nbd", "-c", "/dev/sda", "-f", "raw", str(host)],
                         ["qemu-nbd", "-c", "/dev/nbd3", "-f", "qcow2", str(host)],
                         ["nbd-client", "/dev/nbd3", str(host)],
                         good[:-1] + ["--image-opts", str(host)]):
                with self.subTest(args=args), self.assertRaises(ValueError):
                    builder.check_export(host, args)

    def test_hash_count_and_content_changes(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            esp = Path(directory) / "esp"
            (esp / "qemu").mkdir(parents=True)
            (esp / "EFI/BOOT").mkdir(parents=True)
            qemu = esp / "qemu/qemu-system-x86_64.exe"
            fallback = esp / "EFI/BOOT/BOOTX64.EFI"
            qemu.write_bytes(b"fixture-windows-qemu")
            fallback.write_bytes(b"fixture-efi")
            original = builder.critical_manifest(esp)
            self.assertEqual(len(original), 2)
            fallback.write_bytes(b"changed")
            self.assertNotEqual(original, builder.critical_manifest(esp))
            (esp / "extra.cfg").write_bytes(b"extra")
            self.assertEqual(len(builder.critical_manifest(esp)), 3)
            qemu.unlink()
            with self.assertRaisesRegex(ValueError, "Windows QEMU"):
                builder.critical_manifest(esp)
            qemu.write_bytes(b"fixture-windows-qemu")
            fallback.unlink()
            with self.assertRaisesRegex(ValueError, "fallback"):
                builder.critical_manifest(esp)
            fallback.symlink_to("/etc/passwd")
            with self.assertRaisesRegex(ValueError, "escapes"):
                builder.critical_manifest(esp)

    def test_bios_metadata_geometry_required(self):
        for field in ("start", "size"):
            data = copy.deepcopy(self.metadata)
            data["partitiontable"]["partitions"][0][field] = 4096
            with self.assertRaises(ValueError):
                builder.table_from_json(data)

    def test_unicode_esp_manifest_names_and_hashes(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            source, target = Path(directory) / "source", Path(directory) / "target"
            relative = "docs/\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u044b/\u0423\u0440\u043e\u043a 1.txt"
            payload = "\u041f\u0440\u0438\u0432\u0435\u0442\n".encode("utf-8")
            for esp in (source, target):
                for name, data in (("qemu/qemu-system-x86_64.exe", b"fixture-qemu"),
                                   ("EFI/BOOT/BOOTX64.EFI", b"fixture-efi"),
                                   (relative, payload)):
                    path = esp / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
            manifest = builder.critical_manifest(source)
            self.assertEqual(len(manifest), 3)
            self.assertEqual(manifest["esp/" + relative], builder.hashlib.sha256(payload).hexdigest())
            self.assertEqual(manifest, builder.critical_manifest(target))
            (target / relative).write_bytes(b"changed")
            self.assertNotEqual(manifest, builder.critical_manifest(target))
            (target / relative).write_bytes(payload)
            (target / relative).rename((target / relative).with_name("???? 1.txt"))
            changed_names = builder.critical_manifest(target)
            self.assertEqual(len(changed_names), len(manifest))
            self.assertNotEqual(manifest, changed_names)

    def test_semantic_gpt_confirmation(self):
        actual = copy.deepcopy(self.metadata)
        actual["partitiontable"]["id"] = actual["partitiontable"]["id"].upper()
        for part, geometry in zip(actual["partitiontable"]["partitions"], builder.LAYOUT):
            part["start"], part["size"] = geometry
            part["type"] = part["type"].upper()
            part["uuid"] = part["uuid"].upper()
        # sfdisk may omit an empty name, or emit it as null/empty text.
        self.metadata["partitiontable"]["partitions"][0]["name"] = ""
        del actual["partitiontable"]["partitions"][0]["name"]
        builder.verify_table(actual, self.metadata)
        for field, value in (("start", 1), ("size", 1), ("uuid", actual["partitiontable"]["id"]),
                             ("type", builder.TYPES[0]), ("name", "changed")):
            changed = copy.deepcopy(actual)
            changed["partitiontable"]["partitions"][2][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                builder.verify_table(changed, self.metadata)

    def test_local_storage_and_real_free_space(self):
        filesystem = {"filesystems": [{"source": "/dev/nvme0n1p2", "fstype": "ext4", "options": "rw"}]}
        devices = {"blockdevices": [{"name": "/dev/nvme0n1p2", "type": "part", "children": [
            {"name": "/dev/nvme0n1", "type": "disk"}]}]}
        free = SimpleNamespace(f_bavail=50 * 1024**3, f_frsize=1)
        with patch.object(builder.os, "statvfs", return_value=free):
            with patch.object(builder, "run", side_effect=[json.dumps(filesystem), json.dumps(devices)]):
                builder.check_storage(Path("/fixture.raw"))
            free.f_bavail = builder.MIN_FREE - 1
            with patch.object(builder, "run", side_effect=[json.dumps(filesystem), json.dumps(devices)]):
                with self.assertRaisesRegex(ValueError, "19 GiB"):
                    builder.check_storage(Path("/fixture.raw"))
            free.f_bavail = builder.MIN_FREE
            devices["blockdevices"][0]["children"][0]["name"] = "/dev/nbd0"
            with patch.object(builder, "run", side_effect=[json.dumps(filesystem), json.dumps(devices)]):
                with self.assertRaisesRegex(ValueError, "local physical disk"):
                    builder.check_storage(Path("/fixture.raw"))
            for kind in ("tmpfs", "nfs", "cifs"):
                filesystem["filesystems"][0]["fstype"] = kind
                with patch.object(builder, "run", return_value=json.dumps(filesystem)):
                    with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "not tmpfs/network"):
                        builder.check_storage(Path("/fixture.raw"))

    def test_bounded_bios_read_identity_and_ro(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            sys_root = Path(directory)
            sys_part = sys_root / "nbd0/nbd0p1"
            sys_part.mkdir(parents=True)
            for name, value in (("partition", "1"), ("start", "2048"), ("size", "2048")):
                (sys_part / name).write_text(value)
            part = self.metadata["partitiontable"]["partitions"][0]
            payload = b"b" * builder.MIB
            def path_factory(path, *args):
                return sys_root if path == "/sys/class/block" else Path(path, *args)
            commands = [part["uuid"], "1", "1", str(builder.MIB)]
            opened = mock_open()
            opened.return_value.read.side_effect = [b"\0" * 440, payload]
            with patch.object(builder, "Path", side_effect=path_factory), patch("builtins.open", opened):
                with patch.object(builder, "run", side_effect=commands):
                    self.assertEqual(builder.read_bios("/dev/nbd0", part), payload)
                self.assertEqual(opened.call_args_list[0].args, ("/dev/nbd0", "rb"))
                self.assertEqual(opened.call_args_list[1].args, ("/dev/nbd0p1", "rb"))
                self.assertEqual([c.args for c in opened.return_value.read.call_args_list],
                                 [(440,), (builder.MIB,)])
                for bad_commands in (["wrong-guid"], [part["uuid"], "0"],
                                     [part["uuid"], "1", "1", "512"]):
                    with patch.object(builder, "run", side_effect=bad_commands):
                        with self.assertRaises(ValueError):
                            builder.read_bios("/dev/nbd0", part)
                for reads, message in (([b"x" * 440], "MBR boot code"),
                                       ([b"\0" * 440, payload[:-1]], "Short BIOS source read")):
                    opened.return_value.read.side_effect = reads
                    with patch.object(builder, "run", side_effect=commands):
                        with self.assertRaisesRegex(ValueError, message):
                            builder.read_bios("/dev/nbd0", part)
                (sys_part / "start").write_text("4096")
                with self.assertRaisesRegex(ValueError, "geometry"):
                    builder.read_bios("/dev/nbd0", part)

    def test_bounded_bios_write_and_zero_mbr(self):
        payload = b"b" * builder.MIB
        opened = mock_open()
        opened.return_value.write.return_value = builder.MIB
        opened.return_value.read.side_effect = [payload, b"\0" * 440]
        with patch("builtins.open", opened), patch.object(builder.os, "fsync"), \
                patch.object(builder, "run", return_value=str(builder.MIB)):
            builder.copy_bios(payload)
            opened.return_value.write.assert_called_once_with(payload)
            self.assertEqual(opened.call_args_list[0].args, ("/dev/nbd3p1", "r+b"))
            self.assertEqual(opened.call_args_list[1].args, ("/dev/nbd3", "rb"))
            with self.assertRaisesRegex(ValueError, "exactly 1 MiB"):
                builder.copy_bios(payload[:-1])
            opened.return_value.read.side_effect = [payload, b"x" * 440]
            with self.assertRaisesRegex(ValueError, "MBR boot code"):
                builder.copy_bios(payload)
            opened.return_value.write.return_value = builder.MIB - 1
            with self.assertRaisesRegex(ValueError, "Short target BIOS write"):
                builder.copy_bios(payload)

    def test_guest_escape_and_diagnostic_rejection(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            root = Path(directory)
            (root / "etc/systemd/system").mkdir(parents=True)
            unit = root / "etc/systemd/system/example.service"
            unit.write_text("[Service]\nUser=root\n")
            builder.reject_diagnostics(root)  # Normal root services are not diagnostic.
            unit.write_text("ExecStart=agetty --autologin root\n")
            with self.assertRaises(ValueError):
                builder.reject_diagnostics(root)
            unit.write_text("# Diagnostic overlay only: renamed fixture\n")
            with self.assertRaises(ValueError):
                builder.reject_diagnostics(root)
            (root / "escape").symlink_to("/etc", target_is_directory=True)
            with self.assertRaises(ValueError):
                builder.safe_guest(root, "escape/never-write")

    def test_source_must_be_ro_expected_uuid_and_not_target(self):
        record = {"fstype": "ext4", "uuid": builder.ROOT_UUID, "options": "rw",
                  "maj:min": "43:3"}
        with patch.object(builder, "mount_record", return_value=record):
            with self.assertRaisesRegex(ValueError, "read-only"):
                builder.source_check(Path("/fixture"), "ext4", builder.ROOT_UUID)
            record["options"] = "ro"
            record["uuid"] = builder.ESP_UUID
            with self.assertRaisesRegex(ValueError, "UUID"):
                builder.source_check(Path("/fixture"), "ext4", builder.ROOT_UUID)
            record["uuid"] = builder.ROOT_UUID
            with patch.object(Path, "resolve", return_value=Path("/sys/devices/virtual/block/nbd3/nbd3p3")):
                with self.assertRaisesRegex(ValueError, "overlaps"):
                    builder.source_check(Path("/fixture"), "ext4", builder.ROOT_UUID)

    def test_source_esp_requires_explicit_utf8(self):
        record = {"fstype": "vfat", "uuid": builder.ESP_UUID, "options": "ro",
                  "maj:min": "43:2"}
        aliases = {"filesystems": [{"maj:min": "43:2", "options": "ro"}]}
        with patch.object(builder, "mount_record", return_value=record), \
                patch.object(Path, "resolve", return_value=Path("/sys/devices/virtual/block/nbd0/nbd0p2")), \
                patch.object(builder, "run", return_value=json.dumps(aliases)) as command:
            for options in ("ro,iocharset=utf8", "ro,utf8", "ro,utf8=1",
                            "ro,iocharset=iso8859-1,utf8"):
                record["options"] = options
                with self.subTest(options=options):
                    self.assertIs(builder.source_check(Path("/fixture"), "vfat", builder.ESP_UUID), record)
            for options in ("ro", "ro,iocharset=iso8859-1", "ro,utf8=0",
                            "ro,iocharset=iso8859-1,utf8=0", "ro,iocharset=utf8x"):
                command.reset_mock()
                record["options"] = options
                with self.subTest(options=options), self.assertRaisesRegex(ValueError, "iocharset=utf8"):
                    builder.source_check(Path("/fixture"), "vfat", builder.ESP_UUID)
                command.assert_not_called()
            record["options"] = "rw,iocharset=utf8"
            with self.assertRaisesRegex(ValueError, "read-only"):
                builder.source_check(Path("/fixture"), "vfat", builder.ESP_UUID)


if __name__ == "__main__":
    unittest.main()
