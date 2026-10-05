import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "merge_user_data", Path(__file__).with_name("merge-prepared-user-data.py"))
merge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merge)


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.roots = [Path(self.temp.name) / name for name in ("B", "L", "P", "T")]
        self.b, self.l, self.p, self.t = self.roots
        for root in self.roots:
            for directory in ("home/student", "root", "etc", "var/backups"):
                (root / directory).mkdir(parents=True, exist_ok=True)
            accounts = "root:x:0:0::/root:/bin/bash\nstudent:x:1000:1000::/home/student:/bin/bash\n"
            if os.getuid() not in {0, 1000}:
                accounts += f"fixture:x:{os.getuid()}:1000::/home/fixture:/bin/bash\n"
            (root / "etc/passwd").write_text(accounts)

    def put(self, root, path, content):
        destination = root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)

    def mounts(self):
        return {"filesystems": [
            {"target": str(root), "source": "/dev/nbd3p3" if i == 3 else f"/dev/nbd{i}p3",
             "fstype": "ext4", "uuid": merge.UUID, "options": "rw" if i == 3 else "ro",
             "maj:min": f"43:{i}"} for i, root in enumerate(self.roots)]}

    def execute(self, command, **kwargs):
        if command[0] == "findmnt":
            return type("Result", (), {"stdout": json.dumps(self.mounts())})()
        self.assertEqual(command[:5], ["rsync", "-aHAXS", "--numeric-ids", "--from0", "--files-from=-"])
        self.assertIn("--no-recursive", command)
        self.assertNotIn("--delete", command)
        source, target = map(Path, command[-2:])
        paths = kwargs["stdin"].read().split(b"\0")[:-1]
        for raw in paths:
            path = os.fsdecode(raw)
            src, dst = source / path, target / path
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_symlink():
                if os.path.lexists(dst):
                    dst.unlink()
                dst.symlink_to(os.readlink(src))
            elif src.is_dir():
                dst.mkdir(exist_ok=True)
                shutil.copystat(src, dst)
            else:
                shutil.copy2(src, dst)

    def run_merge(self):
        shutil.copytree(self.l, self.t, dirs_exist_ok=True, symlinks=True)
        before = [merge.inventory(root) for root in self.roots[:3]]
        with patch.object(merge.os, "geteuid", return_value=0), \
                patch.object(merge.subprocess, "run", side_effect=self.execute):
            result = merge.merge(*self.roots)
        self.assertEqual(before, [merge.inventory(root) for root in self.roots[:3]])
        return result

    def test_three_way_merge_and_deletion(self):
        for root in (self.b, self.l, self.p):
            self.put(root, "home/student/update", "base")
            self.put(root, "home/student/conflict", "base")
        self.put(self.p, "home/student/update", "prepared")
        self.put(self.l, "home/student/conflict", "latest")
        self.put(self.p, "home/student/conflict", "prepared")
        for root in (self.b, self.l):
            self.put(root, "home/student/deleted", "retain")
        counts = self.run_merge()
        self.assertEqual(counts, {"imported": 1, "archived": 1})
        self.assertEqual((self.t / "home/student/update").read_text(), "prepared")
        self.assertEqual((self.t / "home/student/conflict").read_text(), "latest")
        self.assertEqual((self.t / "home/student/deleted").read_text(), "retain")
        backup = next((self.t / "var/backups").iterdir())
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((backup / "manifest.json").stat().st_mode), 0o600)
        self.assertEqual((backup / "prepared/home/student/conflict").read_text(), "prepared")

    def test_project_settings_and_excluded_descendants(self):
        for path in ("project/main.py", "project/.idea/workspace.xml",
                     ".config/JetBrains/PyCharm2025/options/editor.xml"):
            self.put(self.p, "home/student/" + path, "settings")
        for path in ("project/__pycache__/module.pyc", ".cache/private",
                     ".local/share/jupyter/runtime/token", "pf-geogebra-check.ggb",
                     "hs_err_pid3169.log"):
            self.put(self.p, "home/student/" + path, "exclude")
        self.put(self.p, "root/.bash_history", "exclude")
        self.run_merge()
        self.assertTrue((self.t / "home/student/project/.idea/workspace.xml").is_file())
        self.assertTrue((self.t / "home/student/.config/JetBrains/PyCharm2025/options/editor.xml").is_file())
        self.assertFalse((self.t / "home/student/project/__pycache__").exists())
        self.assertFalse((self.t / "root/.bash_history").exists())

    def test_credentials_always_latest_even_when_unchanged_from_base(self):
        paths = [".ssh/id_ed25519", ".gnupg/key", ".aws/credentials", ".azure/token",
                 ".kube/config", ".docker/config.json", ".npmrc", ".netrc",
                 ".git-credentials", ".env", ".local/share/keyrings/login.keyring",
                 ".local/share/kwalletd/kdewallet.kwl", "snap/firefox/common/profile/key"]
        for path in paths:
            for root in (self.b, self.l):
                self.put(root, "home/student/" + path, "latest-secret")
            self.put(self.p, "home/student/" + path, "prepared-secret")
        self.run_merge()
        for path in paths:
            self.assertEqual((self.t / "home/student" / path).read_text(), "latest-secret")

    def test_type_collisions_and_symlink_escape(self):
        self.put(self.l, "home/student/file", "latest")
        self.put(self.p, "home/student/file/child", "prepared")
        self.put(self.l, "home/student/directory/child", "latest")
        self.put(self.p, "home/student/directory", "prepared")
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "secret").write_text("host")
        (self.l / "home/student/escape").symlink_to(outside)
        self.put(self.p, "home/student/escape/secret", "prepared")
        (self.p / "home/student/link").symlink_to(outside)
        self.run_merge()
        self.assertEqual((outside / "secret").read_text(), "host")
        self.assertEqual((self.t / "home/student/file").read_text(), "latest")
        self.assertEqual((self.t / "home/student/directory/child").read_text(), "latest")
        self.assertTrue((self.t / "home/student/link").is_symlink())

    def test_metadata_not_timestamps(self):
        for root in (self.b, self.l, self.p):
            self.put(root, "home/student/file", "same")
        os.utime(self.l / "home/student/file", (1, 1))
        os.chmod(self.p / "home/student/file", 0o600)
        self.assertEqual(self.run_merge()["imported"], 1)
        self.assertEqual(stat.S_IMODE((self.t / "home/student/file").stat().st_mode), 0o600)

    def test_xattrs_and_numeric_ownership_are_compared(self):
        value = ("file", "hash", 1000, 1000, 0o600, ())
        path = "home/student/file"
        for modified in (value[:2] + (1001,) + value[3:],
                         value[:3] + (1001,) + value[4:],
                         value[:5] + ((("user.test", b"value"),),)):
            with self.subTest(value=modified):
                self.assertEqual(merge.plan_merge({path: value}, {path: value},
                                                   {path: modified}), ([path], []))
                self.assertEqual(merge.plan_merge({path: value}, {path: modified},
                                                   {path: value}), ([], []))

    def test_latest_deleted_parent_is_not_resurrected(self):
        self.put(self.b, "home/student/project/old", "base")
        self.put(self.p, "home/student/project/old", "base")
        self.put(self.p, "home/student/project/new", "prepared")
        self.run_merge()
        self.assertFalse((self.t / "home/student/project").exists())
        backup = next((self.t / "var/backups").iterdir())
        self.assertEqual((backup / "prepared/home/student/project/new").read_text(), "prepared")

    def test_source_user_directory_symlink_rejected(self):
        shutil.rmtree(self.p / "root")
        (self.p / "root").symlink_to(self.l / "root")
        with self.assertRaises(RuntimeError):
            self.run_merge()

    def test_uid_mismatch_and_uncopied_target_fail_before_rsync(self):
        (self.p / "etc/passwd").write_text("student:x:1001:1000::/home/student:/bin/bash\n")
        with self.assertRaises(RuntimeError):
            self.run_merge()
        (self.p / "etc/passwd").write_text((self.l / "etc/passwd").read_text())
        self.put(self.t, "home/student/not-latest", "unexpected")
        with patch.object(merge.os, "geteuid", return_value=0), \
                patch.object(merge.subprocess, "run", side_effect=self.execute):
            with self.assertRaises(RuntimeError):
                merge.merge(*self.roots)

    def test_service_only_accounts_permitted_without_copying_passwd(self):
        latest_passwd = (self.l / "etc/passwd").read_text()
        (self.p / "etc/passwd").write_text(
            latest_passwd + "postgres:x:111:111::/var/lib/postgresql:/bin/false\n"
            "docker:x:112:112::/var/lib/docker:/bin/false\n")
        self.put(self.p, "home/student/project.py", "prepared")
        self.assertEqual(self.run_merge(), {"imported": 1, "archived": 0})
        self.assertEqual((self.t / "etc/passwd").read_text(), latest_passwd)

    def test_cross_name_uid_collisions_rejected_before_writes(self):
        latest_passwd = (self.l / "etc/passwd").read_text()
        for accounts in (latest_passwd + "postgres:x:1000:111::/var/lib/postgresql:/bin/false\n",
                         latest_passwd.replace("student:", "other:")):
            with self.subTest(accounts=accounts):
                (self.p / "etc/passwd").write_text(accounts)
                with patch.object(merge, "copy_selected") as copier:
                    with self.assertRaises(RuntimeError):
                        self.run_merge()
                    copier.assert_not_called()
                self.assertEqual(list((self.t / "var/backups").iterdir()), [])

    def test_selected_data_requires_existing_latest_identity(self):
        original_inventory = merge.inventory
        for path in ("home/student/project.py", "home/student/.env"):
            for uid in (111, 99999):
                with self.subTest(path=path, uid=uid):
                    (self.p / "etc/passwd").write_text(
                        (self.l / "etc/passwd").read_text()
                        + "postgres:x:111:111::/var/lib/postgresql:/bin/false\n")
                    self.put(self.p, path, "prepared")

                    def inventory(root):
                        entries = original_inventory(root)
                        if root == self.p:
                            entry = entries[path]
                            entries[path] = entry[:2] + (uid,) + entry[3:]
                        return entries

                    with patch.object(merge, "inventory", side_effect=inventory), \
                            patch.object(merge, "copy_selected") as copier:
                        with self.assertRaises(RuntimeError):
                            self.run_merge()
                        copier.assert_not_called()
                    self.assertEqual(list((self.t / "var/backups").iterdir()), [])
                    (self.p / path).unlink()

    def test_fifo_socket_inventory_and_metadata_only_archive(self):
        os.mkfifo(self.l / "home/student/latest-fifo")
        os.mkfifo(self.t / "home/student/latest-fifo")
        os.mkfifo(self.p / "home/student/prepared-fifo")
        for root, name in ((self.l, "latest-socket"), (self.t, "latest-socket"),
                           (self.p, "prepared-socket")):
            endpoint = socket.socket(socket.AF_UNIX)
            self.addCleanup(endpoint.close)
            endpoint.bind(str(root / "home/student" / name))
        with patch.object(merge.os, "open", side_effect=AssertionError("Must not open IPC nodes")):
            inventory = merge.inventory(self.p)
        self.assertEqual(inventory["home/student/prepared-fifo"][0], "fifo")
        self.assertEqual(inventory["home/student/prepared-socket"][0], "socket")
        with patch.object(merge.os, "geteuid", return_value=0), \
                patch.object(merge.subprocess, "run", side_effect=self.execute):
            self.assertEqual(merge.merge(*self.roots), {"imported": 0, "archived": 2})
        self.assertTrue(stat.S_ISFIFO((self.t / "home/student/latest-fifo").lstat().st_mode))
        self.assertTrue(stat.S_ISSOCK((self.t / "home/student/latest-socket").lstat().st_mode))
        backup = next((self.t / "var/backups").iterdir())
        manifest = json.loads((backup / "manifest.json").read_text())
        self.assertEqual(manifest["special_nodes"]["home/student/prepared-fifo"]["kind"], "fifo")
        self.assertEqual(manifest["special_nodes"]["home/student/prepared-socket"]["kind"], "socket")
        self.assertEqual(list((backup / "prepared").iterdir()), [])

    def test_device_nodes_are_metadata_only_without_creating_devices(self):
        original_inventory = merge.inventory
        for kind in ("character-device", "block-device"):
            with self.subTest(kind=kind):
                def inventory(root):
                    entries = original_inventory(root)
                    if root == self.p:
                        entries["home/student/device"] = (kind, 1234, os.getuid(), os.getgid(), 0o600, ())
                    return entries

                with patch.object(merge, "inventory", side_effect=inventory):
                    self.assertEqual(self.run_merge(), {"imported": 0, "archived": 1})
                self.assertFalse(os.path.lexists(self.t / "home/student/device"))
        for backup in (self.t / "var/backups").iterdir():
            manifest = json.loads((backup / "manifest.json").read_text())
            self.assertEqual(manifest["special_nodes"]["home/student/device"]["device"], 1234)
            self.assertFalse(os.path.lexists(backup / "prepared/home/student/device"))

    def test_mount_guards(self):
        for field, value in (("options", "rw"), ("fstype", "xfs"), ("uuid", "wrong"),
                             ("maj:min", "43:3")):
            mounts = self.mounts()
            mounts["filesystems"][0][field] = value
            with self.subTest(field=field), patch.object(merge.os, "geteuid", return_value=0), \
                    patch.object(merge.subprocess, "run", return_value=type(
                        "Result", (), {"stdout": json.dumps(mounts)})()):
                with self.assertRaises(RuntimeError):
                    merge.check_mounts(self.roots)
        mounts = self.mounts()
        mounts["filesystems"][3]["source"] = "/dev/nbd4p3"
        with patch.object(merge.os, "geteuid", return_value=0), \
                patch.object(merge.subprocess, "run", return_value=type(
                    "Result", (), {"stdout": json.dumps(mounts)})()):
            with self.assertRaises(RuntimeError):
                merge.check_mounts(self.roots)
        mounts = self.mounts()
        mounts["filesystems"][0]["children"] = [{"target": str(self.b / "home")}]
        with patch.object(merge.os, "geteuid", return_value=0), \
                patch.object(merge.subprocess, "run", return_value=type(
                    "Result", (), {"stdout": json.dumps(mounts)})()):
            with self.assertRaises(RuntimeError):
                merge.check_mounts(self.roots)
        with patch.object(merge.os, "geteuid", return_value=1000):
            with self.assertRaises(RuntimeError):
                merge.check_mounts(self.roots)


if __name__ == "__main__":
    unittest.main()
