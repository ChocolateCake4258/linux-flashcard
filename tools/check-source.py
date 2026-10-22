#!/usr/bin/env python3
"""Check the publishable tree without downloads, VMs or physical disks."""
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('public_download',ROOT/'tools/make-public-download.py')
public=importlib.util.module_from_spec(spec);spec.loader.exec_module(public)


def files():
    if (ROOT/'.git').exists():
        names=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=ROOT).decode().split('\0')
        return sorted({ROOT/name for name in names if name and (ROOT/name).exists()})
    return [path for _,path in public.release.source_files(ROOT)]


def main():
    selected=files();shell=[]
    for path in selected:
        name=path.relative_to(ROOT).as_posix();public.release.safe_path(name)
        if not path.is_file() or path.is_symlink():raise ValueError('Nonregular source: '+name)
        if path.suffix.lower() in public.release.ARTIFACT_SUFFIXES or path.stat().st_size>public.release.MAX_SOURCE_BYTES:
            raise ValueError('Build artifact in source selection: '+name)
        data=path.read_bytes();text=data.decode('utf-8-sig',errors='strict')
        public.check_public_content(data,name)
        if path.suffix in ('.bat','.cmd'):
            data.decode('ascii')
            if re.search(rb'(?<!\r)\n|\r(?!\n)',data):raise ValueError('BAT must use CRLF: '+name)
        elif b'\r' in data:raise ValueError('Source must use LF: '+name)
        if path.suffix in ('.ps1','.psm1') and not data.startswith(b'\xef\xbb\xbf'):
            raise ValueError('PowerShell 5.1 requires UTF-8 BOM: '+name)
        if path.suffix=='.py':ast.parse(text,filename=name)
        if path.suffix=='.json':json.loads(text)
        if path.suffix=='.sh':shell.append(str(path))
        if path.suffix=='.md':
            for target in re.findall(r'\]\(([^)\s]+)\)',text):
                if ':' in target or target.startswith('#'):continue
                target=target.split('#',1)[0]
                if target and not (path.parent/target).exists():raise ValueError('Broken Markdown link: '+name+' -> '+target)
    for name in public.public_paths(ROOT):
        if not (ROOT/name).is_file():raise ValueError('Missing public dependency: '+name)
    version=(ROOT/'VERSION').read_text(encoding='utf-8').strip();public.release.valid_version(version)
    if '\n## '+version+'\n' not in (ROOT/'CHANGELOG.md').read_text(encoding='utf-8'):raise ValueError('VERSION has no CHANGELOG section.')
    if os.name!='nt' and shell:subprocess.run(['bash','-n',shell[0]],check=True)
    if os.name!='nt':
        for script in shell[1:]:subprocess.run(['bash','-n',script],check=True)
    print(f'OK: {len(selected)} source files; encodings, syntax, public paths, links and release version checked.')


if __name__=='__main__':main()
