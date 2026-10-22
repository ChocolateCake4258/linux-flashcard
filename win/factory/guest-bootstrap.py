#!/usr/bin/python3
"""Small stable loader: source refreshes run from the verified read-only ISO."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import traceback

job={}
try:
    subprocess.run(['modprobe','qemu_fw_cfg'],check=True)
    subprocess.run(['modprobe','virtio_console'],check=True)
    job=json.loads(Path('/sys/firmware/qemu_fw_cfg/by_name/opt/pf.factory/raw').read_bytes().rstrip(b'\x00'))
    mount=Path('/mnt/pf-factory-inputs');mount.mkdir(parents=True,exist_ok=True)
    if subprocess.run(['mountpoint','-q',str(mount)]).returncode:
        device=subprocess.check_output(['findfs','LABEL=PFINPUTS'],text=True).strip()
        subprocess.run(['mount','-o','ro',device,str(mount)],check=True)
    script=mount/'factory-guest.py'
    with script.open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest()
    if sha!=job['guest_sha256']:raise RuntimeError('Factory controller checksum mismatch.')
    os.execv('/usr/bin/python3',['python3',str(script)])
except BaseException:
    error=traceback.format_exc();print(error,flush=True)
    data=dict(complete=False,error=error,build_id=job.get('build_id'),job_id=job.get('job_id'),action=job.get('action'))
    try:
        with open('/dev/virtio-ports/org.linuxflashcard.factory','wb',buffering=0) as stream:stream.write(json.dumps(data).encode())
    finally:
        subprocess.run(['sync']);subprocess.run(['systemctl','--no-block','poweroff'])
