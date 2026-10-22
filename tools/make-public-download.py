#!/usr/bin/env python3
"""Build the end-user download from an explicit, dependency-checked file list."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_release', SOURCE/'tools/make-source-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

ROOT_FILES = ['README.md', 'ИНСТРУКЦИЯ.md', 'CHANGELOG.md', 'LICENSE', 'VERSION', 'START.bat', 'BUILD-IMAGE.bat', 'CHECK.bat',
              'docs/backup-recovery.md', 'docs/accelerated-mode.md', 'docs/pipeline-capsule.md',
              'docs/architecture.md', 'docs/validation.md', 'win/factory/README.md']
WIN_FILES = ['build-all.bat', 'build-all.ps1', 'build-debian.bat', 'build-debian.ps1',
             'build-image.ps1', 'check-package.ps1', 'write-image.ps1',
             'run-from-usb.bat', 'run-from-usb.ps1', 'enable-acceleration.bat', 'enable-acceleration.ps1',
             'backup-system.bat', 'backup-system.ps1', 'restore-system.bat',
             'lib/pf-tools.psm1', 'lib/pf-whpx.ps1', 'lib/pf-storage.ps1', 'lib/portable-backup.ps1', 'lib/pf-deferred-write.ps1']
DESKTOP_FILES = ['prepare-desktop.sh', 'configure-usability.sh', 'first-password.sh', 'first-password.service',
                 'START-HERE.txt', 'install-cli.sh', 'verify-cli.sh', 'CLI-START.txt', 'install-python.sh',
                 'verify-python.py', 'jupyter-project.sh', 'PYTHON-START.txt', 'install-java.sh',
                 'verify-java.sh', 'JAVA-START.txt']
FULL_FILES = ['fetch-inputs.py', 'install-profile.sh', 'verify-all.py', 'verify-desktop.py',
              'generate-documents.py', 'pycharm.sh', 'pycharm.desktop', 'FULL-START.txt',
              'ACCELERATION.txt', 'run-linux.bat', 'run-linux-accelerated.bat']
UNIFIED_FILES = ['fetch-inputs.py', 'status.sh', 'record-boot.sh', 'record-boot.service', 'ventoy.json']

# Generic workstation/development markers; no real machine identifiers live here.
PRIVATE_PATTERNS = (
    rb'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b',
    rb'(?-i:\b(?:DESKTOP|LAPTOP)-[A-Z0-9]{5,}\b)',
    rb'[A-Z]:\\Users\\[^\\\s]+',
    rb'/home/(?!student(?:/|\b)|fixture(?:/|\b))[A-Za-z0-9_.-]+',
    rb'-----BEGIN [A-Z ]*PRIVATE KEY-----',
)


def check_public_content(data, name):
    if any(re.search(pattern, data, re.I) for pattern in PRIVATE_PATTERNS):
        raise ValueError('Machine-specific/private material in public file: '+name)


def public_paths(source):
    paths = set(ROOT_FILES)
    for prefix, names in [('win', WIN_FILES), ('win/debian-prototype', DESKTOP_FILES),
                          ('win/full-suite', FULL_FILES), ('win/unified', UNIFIED_FILES)]:
        paths.update(prefix+'/'+name for name in names)
    for prefix in ('win/debian-prototype/examples', 'win/full-suite/examples'):
        paths.update(p.relative_to(source).as_posix() for p in (source/prefix).rglob('*') if p.is_file())
    paths.update(p.relative_to(source).as_posix() for p in (source/'win/factory').iterdir()
                 if p.is_file() and p.suffix in ('.py', '.ps1', '.sh', '.json', '.lock', '.service'))
    return sorted(paths)


def build_public(source, output, version):
    source=Path(source).resolve(); output=Path(output).resolve()
    if source == output or source in output.parents:
        raise ValueError('Keep downloadable artifacts outside sources.')
    paths=public_paths(source)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='public-stage-', dir=output) as temporary:
        stage=Path(temporary)
        for name in paths:
            release.safe_path(name)
            path=source/name
            if not path.is_file() or path.is_symlink():
                raise ValueError('Missing/nonregular public dependency: '+name)
            data=path.read_bytes()
            check_public_content(data,name)
            target=stage/name; target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path,target)
        sys.path.insert(0, str(stage/'win/factory'))
        try:
            from seed import payloads
            for target, (path, _) in payloads(stage).items():
                if not path.is_file():
                    raise ValueError('Missing guest payload: '+target)
            for name in ('win/factory/inputs.json','win/factory/runtime.lock','win/full-suite/fetch-inputs.py','win/unified/fetch-inputs.py'):
                if not (stage/name).is_file():
                    raise ValueError('Missing pinned input definition: '+name)
        finally:
            sys.path.pop(0)
        result=release.build_release(stage,output,version)
    old_archive=output/result['archive']
    archive=output/('linux-flashcard-'+version+'-windows.zip')
    if archive.exists() or Path(str(archive)+'.sha256').exists():
        raise ValueError('Public download already exists.')
    old_archive.rename(archive)
    Path(str(old_archive)+'.sha256').unlink()
    Path(str(archive)+'.sha256').write_text(result['sha256']+'  '+archive.name+'\n',encoding='ascii')
    result['archive']=archive.name
    result['audience']='end-user Windows download'
    result['excluded']='host history, personal paths, old Kubuntu pipeline, developer transports and VM/backups'
    (output/'release.json').write_bytes(release.json_bytes(result))
    (output/'public-download.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=SOURCE); parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--version',required=True)
    args=parser.parse_args()
    print(json.dumps(build_public(args.source,args.output,args.version),ensure_ascii=False,indent=2))
