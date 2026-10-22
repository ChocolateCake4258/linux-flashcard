#!/usr/bin/env python3
"""Real fixed-disk conversion, crash recovery and verified retirement contracts."""
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

sys.dont_write_bytecode=True
SOURCE=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(SOURCE/'win/factory'))
from build import Factory, validate_gpt
from common import Workspace
from common import digest
from storage import fixed_footer,publish_fixed_vhd,retire


def fixture(size=4*1024**2):
    last=size//512-1
    data=bytearray(size);data[510:512]=b'\x55\xaa'
    entries=bytearray(128*128);entries[:16]=bytes(range(1,17))
    struct.pack_into('<QQ',entries,32,2048,last-34)
    backup=last-32
    data[1024:1024+len(entries)]=entries
    data[backup*512:backup*512+len(entries)]=entries
    for lba,peer,table in ((1,last,2),(last,1,backup)):
        header=bytearray(512);header[:8]=b'EFI PART'
        struct.pack_into('<IIII',header,8,0x10000,92,0,0)
        struct.pack_into('<QQQQ',header,24,lba,peer,34,last-33)
        struct.pack_into('<QIII',header,72,table,128,128,zlib.crc32(entries))
        struct.pack_into('<I',header,16,zlib.crc32(header[:92]));data[lba*512:(lba+1)*512]=header
    data[2*1024**2:2*1024**2+12]=b'saved-data!!'
    footer=bytearray(512);footer[:8]=b'conectix'
    struct.pack_into('>IIQ',footer,8,2,0x10000,0xffffffffffffffff)
    struct.pack_into('>QQ',footer,40,size,size);struct.pack_into('>I',footer,60,2)
    struct.pack_into('>I',footer,64,~sum(footer)&0xffffffff)
    return bytes(data),bytes(footer)


class CompactTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.layout=self.root/'layout.vhd';self.output=self.root/'usb.img'
        self.data,self.footer=fixture();self.layout.write_bytes(self.data+self.footer)
    def tearDown(self):self.temp.cleanup()
    def publish(self,hook=None,**kw):
        return publish_fixed_vhd(self.layout,self.output,len(self.data),'build-one','source-one',validate_gpt,_checkpoint=hook,**kw)

    def test_fixed_layout_is_published_without_second_copy(self):
        inode=self.layout.stat().st_ino
        result=self.publish()
        self.assertEqual(self.output.read_bytes(),self.data)
        self.assertEqual(self.output.stat().st_ino,inode)
        self.assertFalse(self.layout.exists())
        self.assertFalse(self.output.with_suffix('.partial').exists())
        self.assertEqual(result['sha256'],hashlib.sha256(self.data).hexdigest())
        self.assertEqual(self.publish(),result)
        receipt=json.loads((self.root/'compact-publication.json').read_text())
        self.assertEqual(base64.b64decode(receipt['footer']),self.footer)

    def test_each_interrupted_transition_resumes_without_recopy(self):
        for step in ('prepared','renamed','truncated','published'):
            with self.subTest(step=step),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);layout=root/'layout.vhd';output=root/'usb.img'
                layout.write_bytes(self.data+self.footer);inode=layout.stat().st_ino
                def interrupt(name):
                    if name==step:raise OSError('simulated interruption')
                with self.assertRaises(OSError):publish_fixed_vhd(layout,output,len(self.data),'build','source',validate_gpt,_checkpoint=interrupt)
                result=publish_fixed_vhd(layout,output,len(self.data),'build','source',validate_gpt)
                self.assertTrue(result['complete']);self.assertEqual(output.read_bytes(),self.data)
                self.assertEqual(output.stat().st_ino,inode)

    def test_corrupt_and_dynamic_footers_are_preserved(self):
        for offset in (0,12,16,40,48,60,64,84):
            bad=bytearray(self.footer);bad[offset]^=1
            self.layout.write_bytes(self.data+bad)
            with self.subTest(offset=offset),self.assertRaises(RuntimeError):self.publish()
            self.assertEqual(self.layout.read_bytes(),self.data+bad)
            self.assertFalse(self.output.exists())

    def test_bad_gpt_never_starts_conversion(self):
        data=bytearray(self.data);data[512+16]^=1
        self.layout.write_bytes(data+self.footer)
        with self.assertRaises(RuntimeError):self.publish()
        self.assertTrue(self.layout.exists());self.assertFalse(self.output.exists())
        self.assertFalse((self.root/'compact-publication.json').exists())

    def test_changed_data_after_receipt_is_not_published(self):
        def interrupt(step):
            if step=='renamed':raise OSError('stop')
        with self.assertRaises(OSError):self.publish(interrupt)
        partial=self.output.with_suffix('.partial')
        with partial.open('r+b') as stream:stream.seek(2*1024**2);stream.write(b'corrupt')
        with self.assertRaises(RuntimeError):self.publish()
        self.assertTrue(partial.exists());self.assertFalse(self.output.exists())

    def test_foreign_receipt_and_ambiguous_paths_fail_closed(self):
        def interrupt(step):
            if step=='prepared':raise OSError('stop')
        with self.assertRaises(OSError):self.publish(interrupt)
        with self.assertRaises(RuntimeError):publish_fixed_vhd(self.layout,self.output,len(self.data),'other','source-one',validate_gpt)
        self.output.with_suffix('.partial').write_bytes(b'keep')
        with self.assertRaises(RuntimeError):self.publish()
        self.assertEqual(self.output.with_suffix('.partial').read_bytes(),b'keep')

    def test_unowned_existing_partial_is_not_deleted(self):
        partial=self.output.with_suffix('.partial');partial.write_bytes(b'keep')
        with self.assertRaises(RuntimeError):self.publish()
        self.assertEqual(partial.read_bytes(),b'keep');self.assertTrue(self.layout.exists())

    def test_retirement_requires_success_and_only_removes_known_paths(self):
        source=self.root/'source';source.mkdir();ws=Workspace(self.root/'work',source)
        try:
            staging=ws.path/'iso-files';staging.mkdir();(staging/'input').write_text('verified ISO data')
            (ws.path/'keep.txt').write_text('user checkpoint')
            with self.assertRaises(RuntimeError):retire(ws,'seed')
            self.assertTrue(staging.exists())
            ws.complete('seed');retire(ws,'seed');retire(ws,'seed')
            self.assertFalse(staging.exists());self.assertEqual((ws.path/'keep.txt').read_text(),'user checkpoint')
            self.assertEqual(ws.state['retired_artifacts']['iso-files']['status'],'removed')
        finally:ws.close()

    def test_retirement_refuses_redirected_source(self):
        if sys.platform=='win32':self.skipTest('symlink privilege not assumed')
        source=self.root/'source';source.mkdir();ws=Workspace(self.root/'work',source)
        try:
            outside=self.root/'outside';outside.mkdir();(outside/'keep').write_text('keep')
            (ws.path/'iso-files').symlink_to(outside,target_is_directory=True)
            ws.complete('seed')
            with self.assertRaises(RuntimeError):retire(ws,'seed')
            self.assertEqual((outside/'keep').read_text(),'keep')
        finally:ws.close()

    def test_compact_policy_is_persistent_and_legacy_workspaces_keep_files(self):
        import types
        source=self.root/'source'
        for name in ('win/factory/inputs.json','win/factory/runtime.lock','win/full-suite/fetch-inputs.py','win/unified/fetch-inputs.py'):
            p=source/name;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text(json.dumps(dict(linux_bytes=26*1024**3,usb_bytes=31042043904)) if name.endswith('.json') else 'pin')
        args=types.SimpleNamespace(refresh_sources=False,keep_intermediates=False)
        ws=Workspace(self.root/'work',source)
        try:
            with patch('build.SOURCE',source):self.assertTrue(Factory(ws,args).compact)
            args.keep_intermediates=True
            with patch('build.SOURCE',source),self.assertRaises(RuntimeError):Factory(ws,args)
            ws.complete('assemble');args.refresh_sources=True;args.keep_intermediates=False
            with patch('build.SOURCE',source),self.assertRaises(RuntimeError):Factory(ws,args)
        finally:ws.close()
        legacy=Workspace(self.root/'legacy',source)
        try:
            legacy.complete('inputs');args.refresh_sources=False
            with patch('build.SOURCE',source):self.assertFalse(Factory(legacy,args).compact)
        finally:legacy.close()

    def test_assemble_retirement_requires_matching_image_and_firmware(self):
        source=self.root/'source';source.mkdir();ws=Workspace(self.root/'work',source)
        try:
            factory=Factory.__new__(Factory);factory.ws=ws;factory.work=ws.path;factory.compact=True
            factory.root=ws.path/'working/linux.img.vtoy';factory.root.parent.mkdir()
            factory.root.write_bytes(b'verified image');vars=Path(str(factory.root)+'.uefi-vars.fd');vars.write_bytes(b'firmware')
            newer=ws.path/'mounted-image';newer.write_bytes(b'newer shared data')
            ws.complete('assemble',shared_image_sha256=digest(factory.root),vars_sha256=digest(vars))
            factory.root.write_bytes(b'changed source')
            with self.assertRaises(RuntimeError):factory.retire_stage('assemble')
            self.assertTrue(factory.root.exists());self.assertTrue(vars.exists())
            factory.root.write_bytes(b'verified image');factory.retire_stage('assemble')
            self.assertFalse(factory.root.exists());self.assertFalse(vars.exists())
            self.assertEqual(newer.read_bytes(),b'newer shared data')
        finally:ws.close()

    def test_space_budget_removes_one_whole_disk_copy(self):
        import types
        factory=Factory.__new__(Factory);factory.work=self.root
        factory.config=dict(linux_bytes=26*1024**3,usb_bytes=31042043904)
        factory.ws=types.SimpleNamespace(done=lambda name:False)
        factory.compact=True
        with patch('build.shutil.disk_usage',return_value=types.SimpleNamespace(free=68*1000**3)):
            factory.ensure_space()
            factory.compact=False
            with self.assertRaises(RuntimeError):factory.ensure_space()


if __name__=='__main__':unittest.main()
