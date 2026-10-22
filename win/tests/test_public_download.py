#!/usr/bin/env python3
"""Verify the actual end-user file selection and its complete factory payload."""
import importlib.util
import ipaddress
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode=True
SOURCE=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('public_download',SOURCE/'tools/make-public-download.py')
public=importlib.util.module_from_spec(spec);spec.loader.exec_module(public)


class PublicDownloadTests(unittest.TestCase):
    def test_actual_public_package_has_no_host_history_and_complete_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);result=public.build_public(SOURCE,root/'dist','test-public')
            archive=root/'dist'/result['archive']
            manifest=public.release.verify_release(archive)
            paths={entry['path'] for entry in manifest['files']}
            self.assertTrue({'START.bat','BUILD-IMAGE.bat','CHECK.bat','LICENSE','VERSION','win/lib/pf-storage.ps1'} <= paths)
            self.assertFalse(any(p.startswith(('win/tests/','tools/','.github/')) or 'archive' in p or 'RESTART_CONTEXT' in p for p in paths))
            with zipfile.ZipFile(archive) as stream:stream.extractall(root/'unpacked')
            package=root/'unpacked/linux-flashcard-test-public'
            sys.path.insert(0,str(package/'win/factory'))
            try:
                from seed import stage_iso_tree
                work=root/'work';work.mkdir();(work/'tools/qemu').mkdir(parents=True)
                config=json.loads((package/'win/factory/inputs.json').read_text())
                (work/'inputs-manifest.json').write_text(json.dumps(dict(inputs=[],config=config)))
                tree=stage_iso_tree(package,work,'new-public-build',config)
                for name in ('pf-tools.psm1','pf-whpx.ps1','pf-storage.ps1','portable-backup.ps1'):
                    self.assertEqual((tree/'payload/lib'/name).read_bytes(),(package/'win/lib'/name).read_bytes())
            finally:sys.path.pop(0)

    def test_generic_private_content_guard_uses_no_real_host_identifiers(self):
        examples=[str(ipaddress.ip_address(0x0a000001)), 'DESKTOP'+'-'+'EXAMPLE1',
                  'C:'+chr(92)+'Users'+chr(92)+'fixture-user', '/home/'+'developer/project']
        for value in examples:
            with self.subTest(value=value),self.assertRaises(ValueError):
                public.check_public_content(value.encode(),'fixture.txt')

    def test_guest_home_loopback_and_portable_workspace_are_public(self):
        public.check_public_content(b'/home/student/project 127.0.0.1 E:\\LinuxFlashcard-work /var/lib/linux-flashcard/desktop-ready','fixture.txt')


if __name__=='__main__':unittest.main()
