"""Locked Windows QEMU/runtime and application input preparation."""
import concurrent.futures
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
from common import atomic_json, digest, download

EXES = {'qemu-system-x86_64.exe', 'qemu-system-x86_64w.exe', 'qemu-img.exe', 'qemu-nbd.exe'}
FIRMWARE = {'edk2-x86_64-code.fd','edk2-i386-vars.fd','bios.bin','bios-256k.bin',
            'vgabios-stdvga.bin','vgabios-virtio.bin','efi-virtio.rom','kvmvapic.bin'}

def runtime_records(lock):
    result=[]
    for line in Path(lock).read_text().splitlines():
        if not line.strip() or line.startswith('#'): continue
        name, sha = line.split()
        if not re.fullmatch(r'[a-zA-Z0-9_+~.\-]+\.pkg\.tar\.zst', name) or not re.fullmatch('[0-9a-f]{64}',sha):
            raise ValueError('Invalid runtime lock entry: '+line)
        full='mingw-w64-ucrt-x86_64-'+name
        result.append(dict(name=full,url='https://repo.msys2.org/mingw/ucrt64/'+full,sha256=sha))
    if len({r['name'] for r in result}) != len(result): raise ValueError('Duplicate runtime package.')
    return result

def extract_runtime(records, cache, output):
    output=Path(output)
    if output.exists():
        manifest=json.loads((output/'runtime-manifest.json').read_text())
        for name,sha in manifest['files'].items():
            if digest(output/name)!=sha:raise RuntimeError('Runtime file changed: '+name)
        return manifest
    temporary=output.with_name(output.name+'.partial')
    if temporary.exists():shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    manifest=dict(version='11.1.2-1',packages=records,files={})
    for record in records:
        path=download(record,cache)
        with tarfile.open(path) as archive:
            for member in archive:
                parts=PurePosixPath(member.name).parts
                if not member.isfile() or not parts or parts[0]!='ucrt64' or '..' in parts:continue
                relative=PurePosixPath(*parts[1:]);name=None
                if relative.parent==PurePosixPath('bin') and (relative.suffix.lower()=='.dll' or relative.name in EXES):name=relative.name
                elif str(relative).startswith('share/qemu/') and relative.name in FIRMWARE:name=str(relative)
                if name is None:continue
                target=temporary/name;target.parent.mkdir(parents=True,exist_ok=True)
                data=archive.extractfile(member).read()
                if target.exists() and target.read_bytes()!=data:raise RuntimeError('Conflicting runtime file: '+name)
                target.write_bytes(data);manifest['files'][name]=digest(target)
    for name in EXES|{'share/qemu/edk2-x86_64-code.fd','share/qemu/edk2-i386-vars.fd'}:
        if not (temporary/name).is_file():raise RuntimeError('Missing runtime payload: '+name)
    atomic_json(temporary/'runtime-manifest.json',manifest)
    temporary.rename(output)
    return manifest

def load_vendor_records(script):
    # Reuse the reviewed input declarations without executing that script's CLI.
    import ast
    tree=ast.parse(Path(script).read_text())
    assignment=next(n for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='INPUTS' for t in n.targets))
    expression=ast.Expression(assignment.value)
    return eval(compile(expression,str(script),'eval'),{'__builtins__':{},'dict':dict})

def prepare_inputs(source,workspace):
    source=Path(source);work=Path(workspace);cache=work/'cache';cache.mkdir(exist_ok=True)
    config=json.loads((source/'win/factory/inputs.json').read_text())
    all_records=[config['base']]+load_vendor_records(source/'win/unified/fetch-inputs.py')+load_vendor_records(source/'win/full-suite/fetch-inputs.py')
    # Registry SHA512 integrity values are the authoritative TS input pins.
    import base64
    for r in all_records:
        if 'integrity' in r:r['sha512']=base64.b64decode(r['integrity'].split('-',1)[1]).hex()
    runtime=runtime_records(source/'win/factory/runtime.lock')
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        list(pool.map(lambda r:download(r,cache),all_records+runtime))
    manifest=extract_runtime(runtime,cache,work/'tools/qemu')
    atomic_json(work/'inputs-manifest.json',dict(inputs=all_records,runtime=manifest,config=config))
    return dict(manifest_sha256=digest(work/'inputs-manifest.json'))
