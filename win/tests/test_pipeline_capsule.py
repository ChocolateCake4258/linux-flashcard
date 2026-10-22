#!/usr/bin/env python3
"""Offline input integrity, locked template handoff and streaming capsule checks."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode=True
SOURCE=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(SOURCE/'win/factory'))
import guest
from common import download
spec=importlib.util.spec_from_file_location('pipeline_capsule',SOURCE/'tools/make-pipeline-capsule.py')
capsule=importlib.util.module_from_spec(spec);spec.loader.exec_module(capsule)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
    def tearDown(self):self.temporary.cleanup()

    def test_bundled_sha512_input_is_reused_with_network_forbidden(self):
        cache=self.root/'bundled';cache.mkdir();(cache/'input.bin').write_bytes(b'verified input')
        record=dict(name='input.bin',url='https://invalid.example',sha512=hashlib.sha512(b'verified input').hexdigest())
        with patch.dict(os.environ,PF_INPUT_CACHE=str(cache),PF_OFFLINE='1'),patch('urllib.request.urlopen') as network:
            result=download(record,self.root/'work')
        self.assertEqual(result.read_bytes(),b'verified input');network.assert_not_called()

    def test_missing_or_corrupt_offline_input_cannot_fall_back_to_network(self):
        bundled=self.root/'bundled';bundled.mkdir()
        record=dict(name='input.bin',url='https://invalid.example',sha256=hashlib.sha256(b'good').hexdigest())
        with patch.dict(os.environ,PF_INPUT_CACHE=str(bundled),PF_OFFLINE='1'),patch('urllib.request.urlopen') as network:
            with self.assertRaisesRegex(RuntimeError,'missing'):download(record,self.root/'work')
            (bundled/'input.bin').write_bytes(b'bad')
            with self.assertRaisesRegex(RuntimeError,'checksum'):download(record,self.root/'work')
            network.assert_not_called()
        self.assertFalse((self.root/'work/input.bin').exists());self.assertEqual((bundled/'input.bin').read_bytes(),b'bad')

    def template(self):
        base=self.root/'guest';base.mkdir();packages='example\t1.0\tinstalled'
        for name in ('factory-ready','factory-layout-ready','full-suite-verified'):(base/name).touch()
        (base/'factory-origin.json').write_text(json.dumps(dict(build_id='old')))
        (base/'factory-proof.json').write_text(json.dumps(dict(count=3)))
        (base/'factory-checks.json').write_text('preserve checks')
        config=dict(prepared_template=dict(schema=1,build_id='old',packages_sha256=hashlib.sha256(packages.encode()).hexdigest()))
        return base,packages,config

    def test_template_claim_resets_build_proofs_but_keeps_program_checks(self):
        base,packages,config=self.template()
        with patch.object(guest,'BASE',base),patch.dict(guest.job,build_id='new',clear=True),patch.object(guest,'text',side_effect=lambda *a: 'student:!:0' if a[0]=='getent' else packages),patch.object(guest,'run'):
            guest.claim_origin(config)
            self.assertEqual(json.loads((base/'factory-origin.json').read_text())['build_id'],'new')
            self.assertFalse((base/'factory-layout-ready').exists());self.assertFalse((base/'factory-proof.json').exists())
            self.assertEqual((base/'factory-checks.json').read_text(),'preserve checks')
            (base/'factory-proof.json').write_text('new proof')
            guest.claim_origin(config)
            self.assertEqual((base/'factory-proof.json').read_text(),'new proof')

    def test_personalized_image_and_changed_package_versions_are_rejected(self):
        base,packages,config=self.template()
        with patch.object(guest,'BASE',base),patch.dict(guest.job,build_id='new',clear=True),patch.object(guest,'text',return_value='student:password-hash:0'),patch.object(guest,'run') as run:
            with self.assertRaisesRegex(RuntimeError,'first user password'):guest.claim_origin(config)
            run.assert_not_called()
        with patch.object(guest,'BASE',base),patch.dict(guest.job,build_id='new',clear=True),patch.object(guest,'text',side_effect=lambda *a:'student:!:0' if a[0]=='getent' else 'changed'),patch.object(guest,'run'):
            with self.assertRaisesRegex(RuntimeError,'versions differ'):guest.claim_origin(config)
        self.assertEqual(json.loads((base/'factory-origin.json').read_text())['build_id'],'old')
        self.assertFalse((base/'template-claim.json').exists())

    def test_interrupted_template_claim_recovers_after_marker_removal(self):
        base,packages,config=self.template();store=guest.store
        def interrupt(path,value):
            if Path(path).name=='factory-origin.json':raise RuntimeError('interrupted')
            store(path,value)
        with patch.object(guest,'BASE',base),patch.dict(guest.job,build_id='new',clear=True),patch.object(guest,'text',side_effect=lambda *a:'student:!:0' if a[0]=='getent' else packages),patch.object(guest,'run'):
            with patch.object(guest,'store',side_effect=interrupt):
                with self.assertRaisesRegex(RuntimeError,'interrupted'):guest.claim_origin(config)
            self.assertFalse((base/'factory-ready').exists())
            guest.claim_origin(config)
        self.assertTrue(json.loads((base/'template-claim.json').read_text())['complete'])
        self.assertEqual((base/'factory-pending').read_text(),'new\n')

    def test_prepared_image_cannot_reinstall_a_missing_prerequisite(self):
        with patch.dict(guest.job,prepared_template=True,clear=True):
            with self.assertRaisesRegex(RuntimeError,'prerequisite'):guest.step('desktop',lambda:False,lambda:self.fail('Unexpected install'))

    def test_release_desktop_only_removes_supplied_check_sheets(self):
        home=self.root/'home';desktop=home/'Desktop';desktop.mkdir(parents=True)
        for name in ('START-HERE.txt','FULL-START.txt','CLI-START.txt','PYTHON-START.txt','JAVA-START.txt','notes.txt'):(desktop/name).write_text('text')
        guest.release_desktop(home)
        self.assertEqual([p.name for p in desktop.iterdir()],['notes.txt'])

    def source_and_inputs(self):
        source=self.root/'source';source.mkdir()
        for name in capsule.public.public_paths(SOURCE)+['win/pipeline-capsule.ps1']:
            target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(SOURCE/name,target)
        cache=self.root/'cache';cache.mkdir();data=b'fixture Python ZIP'
        config=json.loads((source/'win/factory/inputs.json').read_text())
        config['python']=dict(name='python.zip',url='https://invalid.example',sha256=hashlib.sha256(data).hexdigest())
        (source/'win/factory/inputs.json').write_text(json.dumps(config));(cache/'python.zip').write_bytes(data)
        template=self.root/'template';template.mkdir();image=template/'prepared.qcow2';image.write_bytes(b'fixture compressed base')
        packages='package\t1\tinstalled'
        (template/'packages.tsv').write_text(packages+'\n')
        (template/'template.json').write_text(json.dumps(dict(schema=1,build_id='factory',packages_sha256=hashlib.sha256(packages.encode()).hexdigest(),linux_bytes=26*1024**3,
            template=dict(name=image.name,bytes=image.stat().st_size,sha256=hashlib.sha256(image.read_bytes()).hexdigest()))))
        return source,cache,image

    def test_real_capsule_round_trip_entrypoints_and_unlisted_file_rejection(self):
        source,cache,image=self.source_and_inputs()
        with patch.object(capsule,'runtime_records',return_value=[]),patch.object(capsule,'load_vendor_records',return_value=[]):
            result=capsule.build_capsule(source,cache,image,self.root/'output','test')
        archive=self.root/'output'/result['archive'];manifest=capsule.verify_capsule(archive)
        paths={r['path'] for r in manifest['files']}
        self.assertTrue({'REBUILD.bat','START.bat','CHECK.bat','PACKAGES.tsv','inputs/prepared.qcow2'}<=paths)
        with zipfile.ZipFile(archive) as stream:
            config=json.loads(stream.read('linux-flashcard-pipeline-test/source/win/factory/inputs.json'))
            self.assertEqual(config['prepared_template']['build_id'],'factory')
            self.assertEqual(config['base']['name'],'prepared.qcow2')
        with zipfile.ZipFile(archive,'a') as stream:stream.writestr('linux-flashcard-pipeline-test/unlisted.txt',b'bad')
        with self.assertRaisesRegex(ValueError,'Unlisted'):capsule.verify_capsule(archive)

    def test_capsule_rejects_changed_cached_input_and_preserves_existing_output(self):
        source,cache,image=self.source_and_inputs();(cache/'python.zip').write_bytes(b'changed')
        with patch.object(capsule,'runtime_records',return_value=[]),patch.object(capsule,'load_vendor_records',return_value=[]):
            with self.assertRaisesRegex(ValueError,'checksum'):capsule.build_capsule(source,cache,image,self.root/'output','test')
            with self.assertRaisesRegex(ValueError,'exists'):capsule.build_capsule(source,cache,image,self.root/'output','test')
        self.assertEqual((cache/'python.zip').read_bytes(),b'changed')


if __name__=='__main__':unittest.main()
