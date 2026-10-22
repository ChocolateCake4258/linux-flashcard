#!/usr/bin/env python3
"""Fetch pinned unified-boot inputs outside the source tree and verify SHA256."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

INPUTS = [
    dict(name='ventoy-1.1.18-linux.tar.gz', version='1.1.18',
         url='https://github.com/ventoy/Ventoy/releases/download/v1.1.18/ventoy-1.1.18-linux.tar.gz',
         sha256='d86ff9de63d94c8b8f1f6b14d23c55af4b88e8207bf2893890892a6a97b1ad54'),
    dict(name='vtoyboot-1.0.36.iso', version='1.0.36',
         url='https://github.com/ventoy/vtoyboot/releases/download/v1.0.36/vtoyboot-1.0.36.iso',
         sha256='e0fd493014b57f2c72c7b1b45c53b3e7cd3b746fedee5a9f20b057811168267e'),
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
source = Path(__file__).resolve().parents[2]
output = args.output.resolve()
if output == source or source in output.parents:
    raise SystemExit('Inputs must stay outside the source tree.')
output.mkdir(exist_ok=True)
for item in INPUTS:
    target = output / item['name']
    if not target.exists():
        with urllib.request.urlopen(item['url'], timeout=60) as response, target.open('xb') as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
    with target.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != item['sha256']:
        raise SystemExit('Input checksum mismatch: ' + str(target))
    print('Verified ' + item['name'])
manifest = output / 'input-manifest.json'
data = json.dumps(INPUTS, indent=2) + '\n'
if manifest.exists() and manifest.read_text() != data:
    raise SystemExit('Existing input manifest differs; inspect before replacing it.')
if not manifest.exists():
    manifest.write_text(data)
