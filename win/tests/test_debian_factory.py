#!/usr/bin/env python3
"""State/recovery and actual factory payload contracts; no physical disks."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
SOURCE=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(SOURCE/'win/factory'))
from common import Workspace, download, workspace_path
from build import Factory,resource_profile,validate_gpt
from inputs import runtime_records
from seed import make_seed,payloads,stage_iso_tree
from guest import valid_asset_target

class FactoryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name);self.source=self.root/'source';self.source.mkdir()
    def tearDown(self):self.temp.cleanup()

    def test_foreign_workspace_and_source_rejected(self):
        for path in (self.source,self.source/'build',self.root):
            with self.assertRaises(ValueError):workspace_path(path,self.source)
        foreign=self.root/'foreign';foreign.mkdir();(foreign/'user.txt').write_text('keep')
        with self.assertRaises(RuntimeError):Workspace(foreign,self.source)
        self.assertEqual((foreign/'user.txt').read_text(),'keep')

    def test_resume_does_not_rerun_completed_stage(self):
        path=self.root/'build';ws=Workspace(path,self.source).lock()
        calls=[]
        ws.stage('input',lambda:calls.append(1) or dict(sha='verified'));identity=ws.state['build_id'];ws.close()
        with self.assertRaises(RuntimeError):Workspace(path,self.source)
        ws=Workspace(path,self.source,True).lock()
        ws.stage('input',lambda:calls.append(2));self.assertEqual(calls,[1]);self.assertEqual(ws.state['build_id'],identity);ws.close()

    def test_published_receipt_can_checkpoint_without_duplicate_fields(self):
        ws=Workspace(self.root/'build',self.source).lock()
        ws.stage('finalize',lambda:dict(complete=True,image='new.img',sha256='verified'))
        self.assertTrue(ws.done('finalize'))
        with self.assertRaises(RuntimeError):ws.complete('failed',complete=False)
        self.assertFalse(ws.done('failed'));ws.close()

    def test_failed_stage_can_be_resumed(self):
        ws=Workspace(self.root/'build',self.source).lock()
        with self.assertRaises(RuntimeError):ws.stage('guest',lambda:(_ for _ in ()).throw(RuntimeError('interrupted')))
        self.assertFalse(ws.done('guest'))
        ws.stage('guest',lambda:dict(complete_receipt=True));self.assertTrue(ws.done('guest'));ws.close()

    def test_second_coordinator_cannot_take_workspace(self):
        path=self.root/'build';first=Workspace(path,self.source).lock()
        with self.assertRaises(RuntimeError):Workspace(path,self.source,True).lock()
        first.close()
        second=Workspace(path,self.source,True).lock();second.close()

    def test_changed_pins_do_not_mutate_existing_build(self):
        import types
        for name in ('win/factory/inputs.json','win/factory/runtime.lock','win/full-suite/fetch-inputs.py','win/unified/fetch-inputs.py'):
            p=self.source/name;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text(json.dumps(dict(linux_bytes=26*1024**3,usb_bytes=31042043904)) if name.endswith('.json') else 'pin')
        ws=Workspace(self.root/'build',self.source).lock()
        args=types.SimpleNamespace(refresh_sources=False)
        with patch('build.SOURCE',self.source):Factory(ws,args)
        original=ws.state['source_hash'];revisions=len(ws.state['source_revisions'])
        (self.source/'win/factory/runtime.lock').write_text('different pin')
        args.refresh_sources=True
        with patch('build.SOURCE',self.source),self.assertRaises(RuntimeError):Factory(ws,args)
        self.assertEqual(ws.state['source_hash'],original)
        self.assertEqual(len(ws.state['source_revisions']),revisions);ws.close()

    def test_media_capacity_is_persisted_and_cannot_change_on_resume(self):
        import types
        config=dict(linux_bytes=26*1024**3,usb_bytes=31042043904)
        for name in ('win/factory/inputs.json','win/factory/runtime.lock','win/full-suite/fetch-inputs.py','win/unified/fetch-inputs.py'):
            p=self.source/name;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text(json.dumps(config) if name.endswith('.json') else 'pin')
        ws=Workspace(self.root/'build',self.source)
        args=types.SimpleNamespace(refresh_sources=False,usb_bytes=32000000000)
        with patch('build.SOURCE',self.source):factory=Factory(ws,args)
        self.assertEqual(factory.config['usb_bytes'],32000000000)
        ws.close();ws=Workspace(self.root/'build',self.source,True)
        args.usb_bytes=0
        with patch('build.SOURCE',self.source):self.assertEqual(Factory(ws,args).config['usb_bytes'],32000000000)
        args.usb_bytes=31042043904
        with patch('build.SOURCE',self.source),self.assertRaises(RuntimeError):Factory(ws,args)
        self.assertEqual(ws.state['media_bytes'],32000000000);ws.close()

    def test_corrupt_cache_is_never_overwritten(self):
        cache=self.root/'cache';cache.mkdir();(cache/'input.bin').write_bytes(b'user-data')
        record=dict(name='input.bin',url='https://invalid.example/input',sha256=hashlib.sha256(b'expected').hexdigest())
        with self.assertRaises(RuntimeError):download(record,cache)
        self.assertEqual((cache/'input.bin').read_bytes(),b'user-data')

    def test_partial_download_is_verified_before_publish(self):
        import io
        record=dict(name='input.bin',url='https://invalid.example/input',sha256=hashlib.sha256(b'good').hexdigest())
        with patch('urllib.request.urlopen',return_value=io.BytesIO(b'bad')):
            with self.assertRaises(RuntimeError):download(record,self.root/'cache')
        self.assertFalse((self.root/'cache/input.bin').exists())
        with patch('urllib.request.urlopen',return_value=io.BytesIO(b'good')):
            self.assertEqual(download(record,self.root/'cache').read_bytes(),b'good')

    def test_source_snapshot_survives_repository_edits(self):
        (self.source/'code.py').write_text('old')
        ws=Workspace(self.root/'build',self.source).lock();snapshot=ws.source_snapshot(self.source)
        (self.source/'code.py').write_text('new')
        self.assertEqual(ws.source_snapshot(self.source),snapshot)
        self.assertEqual((snapshot/'code.py').read_text(),'old');ws.close()

    def test_pinned_runtime_is_not_a_rolling_database(self):
        records=runtime_records(SOURCE/'win/factory/runtime.lock')
        self.assertGreater(len(records),100)
        qemu=next(r for r in records if r['name']=='mingw-w64-ucrt-x86_64-qemu-11.1.2-1-any.pkg.tar.zst')
        self.assertEqual(qemu['sha256'],'55f87e3a1448f5cf1cd7d7b9f061846a13b9571eb9b1a1df51eab3d9a9d42429')

    def test_seed_has_no_password_keys_or_autologin(self):
        seed=make_seed(SOURCE,self.root,'new-build')
        text=(seed/'user-data').read_text()
        self.assertIn('lock_passwd: true',text);self.assertIn('ssh_pwauth: false',text)
        self.assertNotIn('ssh_authorized_keys:',text);self.assertNotIn('plain_text_passwd:',text)
        self.assertIn('pf-factory.service',text)
        registry=payloads(SOURCE)
        self.assertTrue(all(valid_asset_target(path) for path in registry))
        self.assertFalse(valid_asset_target('/usr/local/../../etc/shadow'))
        for path in ('/usr/local/bin/pf-verify-all','/usr/local/bin/pf-verify-cli','/usr/local/bin/pf-verify-python',
                     '/usr/local/bin/pf-verify-java','/usr/local/bin/pycharm','/usr/local/sbin/pf-factory-guest'):
            self.assertIn(path,registry);self.assertTrue(registry[path][0].is_file())

    def test_factory_resources_keep_host_reserve(self):
        self.assertEqual(resource_profile('WHPX',0,0,16384,9000,12),(6144,4))
        self.assertEqual(resource_profile('WHPX',0,0,16384,5500,12),(3072,4))
        self.assertEqual(resource_profile('TCG',0,0,16384,9000,12),(4096,2))
        with self.assertRaises(RuntimeError):resource_profile('WHPX',4096,4,16384,5000,12)

    def test_runtime_iso_contains_recovery_tools_and_effective_media_size(self):
        config=dict(base=dict(name='base.qcow2'),containers={},usb_bytes=32000000000)
        (self.root/'inputs-manifest.json').write_text(json.dumps(dict(inputs=[],config=config)))
        (self.root/'tools/qemu').mkdir(parents=True)
        tree=stage_iso_tree(SOURCE,self.root,'test-build',config)
        for name in ('backup-system.ps1','backup-system.bat','restore-system.bat','lib/portable-backup.ps1'):
            self.assertEqual((tree/'payload'/name).read_bytes(),(SOURCE/'win'/name).read_bytes())
        self.assertEqual(json.loads((tree/'factory.json').read_text())['config']['usb_bytes'],32000000000)

    def test_gpt_publication_checks_both_tables(self):
        import struct,zlib
        size=2*1024**2;last=size//512-1
        data=bytearray(size);data[510:512]=b'\x55\xaa'
        entries=bytearray(128*128);entries[:16]=bytes(range(1,17))
        struct.pack_into('<QQ',entries,32,2048,3000)
        data[1024:1024+len(entries)]=entries
        backup_table=last-32;data[backup_table*512:backup_table*512+len(entries)]=entries
        for lba,peer,table in ((1,last,2),(last,1,backup_table)):
            header=bytearray(512);header[:8]=b'EFI PART'
            struct.pack_into('<IIII',header,8,0x10000,92,0,0)
            struct.pack_into('<QQQQ',header,24,lba,peer,34,last-33)
            struct.pack_into('<QIII',header,72,table,128,128,zlib.crc32(entries))
            struct.pack_into('<I',header,16,zlib.crc32(header[:92]));data[lba*512:(lba+1)*512]=header
        image=self.root/'new-usb.img';image.write_bytes(data);validate_gpt(image)
        data[backup_table*512+17]^=1;image.write_bytes(data)
        with self.assertRaises(RuntimeError):validate_gpt(image)

if __name__=='__main__':unittest.main()
