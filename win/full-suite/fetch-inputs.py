#!/usr/bin/env python3
"""Download verified vendor inputs outside the source tree for the full profile."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import urllib.request

INPUTS=[
    dict(name='code_1.142.0_amd64.deb',version='1.142.0',
         url='https://vscode.download.prss.microsoft.com/dbazure/download/stable/6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1/code_1.142.0-1792035033_amd64.deb',
         sha256='33454f7d2d7bc79a5925b3e794d106fb454a10c6a635ddfeb908a63659a44ec5'),
    dict(name='pycharm-2026.2.3.tar.gz',version='2026.2.3',
         url='https://download.jetbrains.com/python/pycharm-2026.2.3.tar.gz',
         sha256='e8e4fbe4dab44390d09f681e059a316e692cabd24b2e11ce98ff76c8120fa313'),
    dict(name='typescript-7.0.2.tgz',version='7.0.2',
         url='https://registry.npmjs.org/typescript/-/typescript-7.0.2.tgz',
         integrity='sha512-8FYau96o3NKOhbjKi/qNvG/W5jhzxkbdm5sj9AbZ/5T5sWqn3hJgLfGx27sRKZWTvyzCP8dLRBTf5tBTSRVUNA=='),
    dict(name='typescript-linux-x64-7.0.2.tgz',version='7.0.2',
         url='https://registry.npmjs.org/@typescript/typescript-linux-x64/-/typescript-linux-x64-7.0.2.tgz',
         integrity='sha512-EYdf2cNg7rgCWJnxCdJ+F3V39O8ihb37eHAu1LK8oAFizgTQbPOK7zHHXbPt8rX24COqODXeI3sIf0fCXG7H/A=='),
    dict(name='packages-microsoft-prod.deb',version='debian-13-bootstrap',
         url='https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb',
         sha256='d0c2f69250c6ce0d4c6220b142f999d039a3c560af7f980b943687d106ca8e38'),
]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
output=args.output.resolve()
source=Path(__file__).resolve().parents[2]
if output==source or source in output.parents:
    raise SystemExit('Vendor inputs must stay outside the source tree.')
output.mkdir(exist_ok=True)
records=[]
for item in INPUTS:
    path=output/item['name']
    if not path.exists():
        partial=path.with_name(path.name+'.partial')
        total=0
        with urllib.request.urlopen(item['url'],timeout=90) as response,partial.open('wb') as stream:
            while chunk:=response.read(1024*1024):
                stream.write(chunk);total+=len(chunk)
                if total%(128*1024*1024)==0:print(item['name'],total,'bytes downloaded',flush=True)
        partial.rename(path)
    with path.open('rb') as stream:
        sha256=hashlib.file_digest(stream,'sha256').hexdigest()
    if 'sha256' in item and sha256!=item['sha256']:
        raise SystemExit('SHA256 mismatch: '+str(path))
    if 'integrity' in item:
        with path.open('rb') as stream:
            digest=hashlib.file_digest(stream,'sha512').digest()
        if digest!=base64.b64decode(item['integrity'].removeprefix('sha512-')):
            raise SystemExit('Registry integrity mismatch: '+str(path))
    records.append(dict(**item,resolved_sha256=sha256,bytes=path.stat().st_size))
    print('Verified',item['name'],sha256,flush=True)
manifest=output/'vendor-inputs.json'
data=json.dumps(records,indent=2)+'\n'
if manifest.exists() and manifest.read_text()!=data:
    raise SystemExit('Existing vendor-input manifest differs; inspect before replacing it.')
if not manifest.exists():manifest.write_text(data)
