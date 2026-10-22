#!/usr/bin/env python3
"""Freeze the reviewed factory, verified inputs and a clean prepared base in ZIP64."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import zipfile

sys.dont_write_bytecode=True
SOURCE=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('public_download',SOURCE/'tools/make-public-download.py')
public=importlib.util.module_from_spec(spec);spec.loader.exec_module(public)
release=public.release
sys.path.insert(0,str(SOURCE/'win/factory'))
from common import digest
from inputs import load_vendor_records,runtime_records

MANIFEST='PIPELINE-MANIFEST.json'


def record(path,name):
    return dict(path=name,bytes=path.stat().st_size,sha256=digest(path))


def copy_verified(source,target,pin):
    if not source.is_file() or source.is_symlink():raise ValueError('Missing/nonregular pipeline input: '+source.name)
    checks={kind:pin[kind] for kind in ('sha256','sha512') if kind in pin}
    if 'integrity' in pin:checks['sha512']=base64.b64decode(pin['integrity'].split('-',1)[1],validate=True).hex()
    if not checks or any(digest(source,kind)!=value.lower() for kind,value in checks.items()):
        raise ValueError('Pipeline input checksum mismatch: '+source.name)
    target.parent.mkdir(parents=True,exist_ok=True)
    # Staging can share immutable input bytes on the same volume.
    try:os.link(source,target)
    except OSError:shutil.copyfile(source,target)


def batch(mode,version):
    return ('\r\n'.join([
        '@echo off','setlocal DisableDelayedExpansion',
        'set "PF_STORAGE_ROOT=%~dp0..\\work-'+version+'"',
        'if not exist "%PF_STORAGE_ROOT%\\bootstrap\\temp" mkdir "%PF_STORAGE_ROOT%\\bootstrap\\temp"',
        'if not exist "%PF_STORAGE_ROOT%\\bootstrap\\profile" mkdir "%PF_STORAGE_ROOT%\\bootstrap\\profile"',
        'set "TEMP=%PF_STORAGE_ROOT%\\bootstrap\\temp"','set "TMP=%TEMP%"',
        'set "LOCALAPPDATA=%PF_STORAGE_ROOT%\\bootstrap\\profile"',
        'set "APPDATA=%LOCALAPPDATA%"','set "USERPROFILE=%LOCALAPPDATA%"','set "HOME=%LOCALAPPDATA%"',
        'set "PSModuleAnalysisCachePath=%LOCALAPPDATA%\\ModuleAnalysisCache"',
        '"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0source\\win\\pipeline-capsule.ps1" -Mode '+mode+' %*',
        'exit /b %errorlevel%',''])).encode('ascii')


def stage_capsule(source,cache,template,stage,version):
    source=Path(source);cache=Path(cache);template=Path(template);stage=Path(stage)
    if stage.exists():raise ValueError('Capsule staging already exists.')
    metadata=json.loads((template.parent/'template.json').read_text(encoding='utf-8-sig'))
    pin=metadata['template']
    if metadata.get('schema')!=1 or metadata.get('linux_bytes')!=26*1024**3 or pin['name']!=template.name:
        raise ValueError('Unsupported prepared template receipt.')
    packages=(template.parent/'packages.tsv').read_text(encoding='utf-8').rstrip('\n')
    if hashlib.sha256(packages.encode()).hexdigest()!=metadata['packages_sha256']:
        raise ValueError('Prepared package version manifest differs.')
    if template.stat().st_size!=pin['bytes']:raise ValueError('Prepared template length differs.')
    stage.mkdir(parents=True)
    bundled=stage/'source';bundled.mkdir()
    for name in public.public_paths(source)+['win/pipeline-capsule.ps1']:
        release.safe_path(name)
        original=source/name
        if not original.is_file() or original.is_symlink():raise ValueError('Missing pipeline source: '+name)
        target=bundled/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,target)
    config=json.loads((bundled/'win/factory/inputs.json').read_text())
    original_base=config['base']
    config['base']=dict(name=template.name,url='bundled:'+template.name,sha256=pin['sha256'])
    config['prepared_template']={key:metadata[key] for key in ('schema','build_id','packages_sha256')}
    (bundled/'win/factory/inputs.json').write_bytes(release.json_bytes(config))
    source_records=[record(path,name) for name,path in release.source_files(bundled)]
    (bundled/'RELEASE-MANIFEST.json').write_bytes(release.json_bytes(dict(schema=1,format='LinuxFlashcardSourceRelease',version=version,files=source_records)))
    pins=load_vendor_records(source/'win/unified/fetch-inputs.py')+load_vendor_records(source/'win/full-suite/fetch-inputs.py')+runtime_records(source/'win/factory/runtime.lock')+[config['python']]
    names=set()
    for item in pins:
        name=item['name'];release.safe_path(name)
        if '/' in name or name.casefold() in names:raise ValueError('Duplicate/unsafe cached input name.')
        names.add(name.casefold())
        original=cache/name
        if name==config['python']['name'] and not original.exists():original=cache.parent/'bootstrap'/name
        copy_verified(original,stage/'inputs'/name,item)
    release.safe_path(template.name)
    if template.name.casefold() in names:raise ValueError('Prepared template name collides with another input.')
    copy_verified(template,stage/'inputs'/template.name,pin)
    (stage/'REBUILD.bat').write_bytes(batch('Image',version))
    (stage/'START.bat').write_bytes(batch('Usb',version))
    (stage/'CHECK.bat').write_bytes(batch('Check',version))
    shutil.copyfile(source/'docs/pipeline-capsule.md',stage/'ИНСТРУКЦИЯ.md')
    (stage/'PACKAGES.tsv').write_text(packages+'\n',encoding='utf-8')
    (stage/'REFERENCE.json').write_bytes(release.json_bytes(dict(template=metadata,original_base=original_base,containers=config['containers'])))
    files=[record(path,path.relative_to(stage).as_posix()) for path in sorted(stage.rglob('*')) if path.is_file()]
    if len({r['path'].casefold() for r in files})!=len(files):raise ValueError('Case-insensitive pipeline path collision.')
    manifest=dict(schema=1,format='LinuxFlashcardPipelineCapsule',version=version,files=files,
                  prepared_template=config['prepared_template'],linux_bytes=config['linux_bytes'],usb_bytes=config['usb_bytes'])
    (stage/MANIFEST).write_bytes(release.json_bytes(manifest))
    return manifest


def verify_capsule(archive):
    with zipfile.ZipFile(archive) as stream:
        infos=stream.infolist();names=[entry.filename for entry in infos]
        for entry in infos:
            release.safe_path(entry.filename)
            if entry.is_dir() or ((entry.external_attr>>16)&0o170000) not in (0,stat.S_IFREG):raise ValueError('Nonregular capsule entry.')
        if len({name.casefold() for name in names})!=len(names):raise ValueError('Duplicate capsule entry.')
        manifests=[name for name in names if name.endswith('/'+MANIFEST)]
        if len(manifests)!=1 or stream.getinfo(manifests[0]).file_size>16*1024**2:raise ValueError('Missing/oversized capsule manifest.')
        manifest=json.loads(stream.read(manifests[0]))
        if manifest.get('schema')!=1 or manifest.get('format')!='LinuxFlashcardPipelineCapsule':raise ValueError('Unsupported capsule manifest.')
        prefix='linux-flashcard-pipeline-'+release.valid_version(manifest['version'])+'/'
        if manifests[0]!=prefix+MANIFEST:raise ValueError('Capsule root/version differs.')
        expected={prefix+MANIFEST}
        for item in manifest['files']:
            release.safe_path(item['path']);name=prefix+item['path']
            if name in expected:raise ValueError('Duplicate capsule manifest record.')
            expected.add(name)
            if stream.getinfo(name).file_size!=item['bytes']:raise ValueError('Capsule file length differs.')
            with stream.open(name) as entry:
                if hashlib.file_digest(entry,'sha256').hexdigest()!=item['sha256']:raise ValueError('Capsule SHA256 differs: '+item['path'])
        if expected!=set(names):raise ValueError('Unlisted/missing capsule files.')
        return manifest


def build_capsule(source,cache,template,output,version):
    output=Path(output).resolve();source=Path(source).resolve();version=release.valid_version(version)
    if output==source or source in output.parents:raise ValueError('Capsules must stay outside source.')
    output.mkdir(parents=True,exist_ok=True)
    root='linux-flashcard-pipeline-'+version
    archive=output/(root+'.zip');partial=output/(root+'.zip.partial');stage=output/root
    if any(path.exists() for path in (archive,partial,stage,output/'pipeline-capsule.json')):raise ValueError('Capsule output exists.')
    manifest=stage_capsule(source,cache,template,stage,version)
    with zipfile.ZipFile(partial,'x',allowZip64=True) as stream:
        for path in sorted(stage.rglob('*')):
            if not path.is_file():continue
            name=path.relative_to(stage).as_posix();release.safe_path(name)
            info=zipfile.ZipInfo(root+'/'+name,date_time=(1980,1,1,0,0,0));info.create_system=3
            info.external_attr=(stat.S_IFREG|0o644)<<16;info.file_size=path.stat().st_size
            # Inputs are compressed upstream; ZIP_STORED avoids recompression and
            # supports streaming the prepared QCOW2 without reading it into RAM.
            info.compress_type=zipfile.ZIP_STORED
            with path.open('rb') as source_stream,stream.open(info,'w',force_zip64=True) as target:
                shutil.copyfileobj(source_stream,target,4*1024**2)
    verify_capsule(partial);sha=digest(partial);partial.rename(archive)
    Path(str(archive)+'.sha256').write_text(sha+'  '+archive.name+'\n',encoding='ascii')
    result=dict(complete=True,version=version,archive=archive.name,sha256=sha,bytes=archive.stat().st_size,files=len(manifest['files']),
                directory=stage.name,offline=True,first_password_pending=True)
    (output/'pipeline-capsule.json').write_bytes(release.json_bytes(result))
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=SOURCE);parser.add_argument('--cache',type=Path)
    parser.add_argument('--template',type=Path);parser.add_argument('--output',type=Path);parser.add_argument('--version')
    parser.add_argument('--verify',type=Path);args=parser.parse_args()
    if args.verify:
        manifest=verify_capsule(args.verify);print(json.dumps(dict(complete=True,files=len(manifest['files']))))
    else:
        if not all((args.cache,args.template,args.output,args.version)):parser.error('--cache, --template, --output and --version are required')
        print(json.dumps(build_capsule(args.source,args.cache,args.template,args.output,args.version),indent=2))
