#!/usr/bin/env python3
"""Actual deterministic ZIP packaging and tamper/path rejection."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('source_release', SOURCE / 'tools/make-source-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        for name in release.REQUIRED:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('fixture ' + name).encode())

    def tearDown(self):
        self.temp.cleanup()

    def test_zip_is_deterministic_and_contains_verified_unicode_files(self):
        first = release.build_release(self.source, self.root / 'a', '2026.10.18-rc1')
        for path in self.source.rglob('*'):
            os.utime(path, (1700000000, 1700000000))
        second = release.build_release(self.source, self.root / 'b', '2026.10.18-rc1')
        self.assertEqual(first['sha256'], second['sha256'])
        manifest = release.verify_release(self.root / 'a' / first['archive'])
        self.assertTrue(any(f['path'] == 'ИНСТРУКЦИЯ.md' for f in manifest['files']))

    def test_outputs_are_external_and_never_overwritten(self):
        with self.assertRaises(ValueError):
            release.build_release(self.source, self.source / 'dist', 'v1')
        release.build_release(self.source, self.root / 'a', 'v1')
        with self.assertRaises(ValueError):
            release.build_release(self.source, self.root / 'a', 'v1')

    def test_artifacts_and_ambiguous_windows_names_are_rejected(self):
        artifact = self.source / 'disk.img'
        artifact.write_bytes(b'disk')
        with self.assertRaises(ValueError):
            release.source_files(self.source)
        artifact.unlink()
        if os.name != 'nt':
            (self.source / 'readme.md').write_text('collision')
            with self.assertRaises(ValueError):
                release.source_files(self.source)

    def test_cached_bytecode_is_not_distributed(self):
        cache = self.source / '__pycache__'
        cache.mkdir(); (cache / 'test.pyc').write_bytes(b'cached')
        self.assertFalse(any('__pycache__' in name for name, _ in release.source_files(self.source)))

    def test_unsafe_versions_and_paths_are_rejected(self):
        for version in ('../v1', '', 'v1/other', 'version with spaces'):
            with self.assertRaises(ValueError):
                release.valid_version(version)
        for path in ('../escape', '/absolute', 'a\\b', 'file:stream', 'qemu/CON', 'file.'):
            with self.assertRaises(ValueError):
                release.safe_path(path)

    def test_changed_bytes_and_unlisted_entries_fail_verification(self):
        result = release.build_release(self.source, self.root / 'a', 'v1')
        original = self.root / 'a' / result['archive']
        with zipfile.ZipFile(original) as stream:
            contents = {i.filename: stream.read(i) for i in stream.infolist()}
        for mutation in ('changed', 'extra', 'traversal'):
            data = dict(contents)
            if mutation == 'changed':
                data['linux-flashcard-v1/README.md'] = b'changed contents'
            else:
                data['linux-flashcard-v1/' + ('extra.txt' if mutation == 'extra' else '../escape')] = b'x'
            target = self.root / (mutation + '.zip')
            with zipfile.ZipFile(target, 'w') as stream:
                for name, content in data.items():
                    stream.writestr(name, content)
            with self.assertRaises((ValueError, KeyError)):
                release.verify_release(target)

    def test_symlink_metadata_cannot_pass_manifest_verification(self):
        result = release.build_release(self.source, self.root / 'a', 'v1')
        original = self.root / 'a' / result['archive']
        target = self.root / 'symlink.zip'
        with zipfile.ZipFile(original) as source, zipfile.ZipFile(target, 'w') as output:
            for info in source.infolist():
                data = source.read(info)
                if info.filename.endswith('/README.md'):
                    info.external_attr = (0o120777 << 16)
                output.writestr(info, data)
        with self.assertRaises(ValueError):
            release.verify_release(target)


if __name__ == '__main__':
    unittest.main()
