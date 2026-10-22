"""Shared reviewed payloads plus explicit factory-only preparation assets."""
import base64
import json
from pathlib import Path
import shutil
from common import atomic_json, digest

def payloads(source):
    source=Path(source);base=source/'win/debian-prototype';full=source/'win/full-suite';unified=source/'win/unified'
    entries={}
    def add(target,path,mode='0755'):entries[target]=(Path(path),mode)
    for name,target,mode in [
        ('prepare-desktop.sh','/usr/local/sbin/pf-prepare-desktop','0755'),
        ('configure-usability.sh','/usr/local/sbin/pf-configure-usability','0755'),
        ('first-password.sh','/usr/local/sbin/pf-first-password','0755'),
        ('first-password.service','/etc/systemd/system/pf-first-password.service','0644'),
        ('START-HERE.txt','/usr/local/share/linux-flashcard/START-HERE.txt','0644'),
        ('install-cli.sh','/usr/local/sbin/pf-install-cli','0755'),
        ('verify-cli.sh','/usr/local/bin/pf-verify-cli','0755'),
        ('CLI-START.txt','/usr/local/share/linux-flashcard/CLI-START.txt','0644'),
        ('install-python.sh','/usr/local/sbin/pf-install-python','0755'),
        ('verify-python.py','/usr/local/bin/pf-verify-python','0755'),
        ('jupyter-project.sh','/usr/local/bin/pf-jupyter','0755'),
        ('PYTHON-START.txt','/usr/local/share/linux-flashcard/PYTHON-START.txt','0644'),
        ('install-java.sh','/usr/local/sbin/pf-install-java','0755'),
        ('verify-java.sh','/usr/local/bin/pf-verify-java','0755'),
        ('JAVA-START.txt','/usr/local/share/linux-flashcard/JAVA-START.txt','0644')]:add(target,base/name,mode)
    for folder in ('cli','python','java'):
        for p in (base/'examples'/folder).rglob('*'):
            if p.is_file():add('/usr/local/share/linux-flashcard/examples/'+p.relative_to(base/'examples').as_posix(),p,'0644')
    for name,target,mode in [
        ('install-profile.sh','/usr/local/sbin/pf-install-full-suite','0755'),
        ('verify-all.py','/usr/local/bin/pf-verify-all','0755'),
        ('verify-desktop.py','/usr/local/bin/pf-verify-desktop','0755'),
        ('generate-documents.py','/usr/local/sbin/pf-make-full-examples','0755'),
        ('pycharm.sh','/usr/local/bin/pycharm','0755'),
        ('pycharm.desktop','/usr/share/applications/pycharm.desktop','0644'),
        ('FULL-START.txt','/usr/local/share/linux-flashcard/FULL-START.txt','0644')]:add(target,full/name,mode)
    for p in (full/'examples').rglob('*'):
        if p.is_file():add('/usr/local/share/linux-flashcard/examples/full-suite/'+p.relative_to(full/'examples').as_posix(),p,'0644')
    for name,target,mode in [('status.sh','/usr/local/bin/pf-unified-status','0755'),
                            ('record-boot.sh','/usr/local/sbin/pf-record-unified-boot','0755'),
                            ('record-boot.service','/etc/systemd/system/pf-record-unified-boot.service','0644')]:add(target,unified/name,mode)
    add('/usr/local/sbin/pf-factory-guest',source/'win/factory/guest.py')
    add('/usr/local/sbin/pf-factory-bootstrap',source/'win/factory/guest-bootstrap.py')
    add('/etc/systemd/system/pf-factory.service',source/'win/factory/guest.service','0644')
    add('/usr/lib/systemd/system-generators/pf-factory-generator',source/'win/factory/guest-generator.sh')
    return entries

def make_seed(source,workspace,build_id):
    source=Path(source);work=Path(workspace);out=work/'seed-files';out.mkdir(exist_ok=True)
    entries=payloads(source)
    data='''#cloud-config
hostname: linux-flashcard
manage_etc_hosts: true
disable_root: true
ssh_pwauth: false
users:
  - name: student
    gecos: Student
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
write_files:
'''
    generated={
        '/var/lib/linux-flashcard/factory-pending':(build_id+'\n','0644'),
        '/etc/systemd/system/pf-first-password.service.d/factory.conf':('[Unit]\nConditionPathExists=!/var/lib/linux-flashcard/factory-pending\n','0644')}
    for target,(path,mode) in entries.items():
        content=base64.b64encode(path.read_bytes()).decode()
        data+=f"  - path: {target}\n    permissions: '{mode}'\n    encoding: b64\n    content: {content}\n"
    for target,(text,mode) in generated.items():
        data+=f"  - path: {target}\n    permissions: '{mode}'\n    encoding: b64\n    content: {base64.b64encode(text.encode()).decode()}\n"
    data+='''runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, pf-factory.service]
  - [systemctl, --no-block, start, pf-factory.service]
'''
    (out/'user-data').write_text(data,encoding='utf-8')
    revision=digest(source/'win/factory/guest-bootstrap.py')[:16]
    (out/'meta-data').write_text('instance-id: pf-factory-'+build_id+'-'+revision+'\nlocal-hostname: linux-flashcard\n')
    return out

def stage_iso_tree(source,work,build_id,config=None):
    source=Path(source);work=Path(work);out=work/'iso-files'
    if out.exists():shutil.rmtree(out)
    out.mkdir()
    manifest=json.loads((work/'inputs-manifest.json').read_text())
    vendors=[]
    for item in manifest['inputs']:
        if item['name']==manifest['config']['base']['name']:continue
        # Hard links avoid duplicating the 1.5-GiB vendor cache on the build SSD.
        import os
        try:os.link(work/'cache'/item['name'],out/item['name'])
        except OSError:shutil.copyfile(work/'cache'/item['name'],out/item['name'])
        if item.get('version') not in ('1.1.18','1.0.36'):
            vendors.append(dict(**item,resolved_sha256=digest(out/item['name']),bytes=(out/item['name']).stat().st_size))
    atomic_json(out/'vendor-inputs.json',vendors)
    atomic_json(out/'runtime-images.json',manifest['config']['containers'])
    shutil.copytree(work/'tools/qemu',out/'qemu')
    runtime=out/'payload';runtime.mkdir()
    for relative,target in [
        ('win/run-from-usb.ps1','run-from-usb.ps1'),('win/run-from-usb.bat','run-from-usb.bat'),
        ('win/enable-acceleration.ps1','enable-acceleration.ps1'),('win/enable-acceleration.bat','enable-acceleration.bat'),
        ('win/backup-system.ps1','backup-system.ps1'),('win/backup-system.bat','backup-system.bat'),('win/restore-system.bat','restore-system.bat'),
        ('win/lib/portable-backup.ps1','lib/portable-backup.ps1'),
        ('win/lib/pf-storage.ps1','lib/pf-storage.ps1'),
        ('win/lib/pf-tools.psm1','lib/pf-tools.psm1'),('win/lib/pf-whpx.ps1','lib/pf-whpx.ps1'),
        ('win/full-suite/run-linux.bat','run-linux.bat'),('win/full-suite/run-linux-accelerated.bat','run-linux-accelerated.bat'),
        ('win/full-suite/FULL-START.txt','FULL-START.txt'),('win/full-suite/ACCELERATION.txt','ACCELERATION.txt'),
        ('win/unified/ventoy.json','ventoy/ventoy.json')]:
        dest=runtime/target;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source/relative,dest)
    assets=out/'guest-assets';assets.mkdir()
    registry=[]
    for index,(target,(path,mode)) in enumerate(payloads(source).items()):
        name=str(index);shutil.copyfile(path,assets/name)
        registry.append(dict(path=target,file=name,mode=mode,sha256=digest(path)))
    atomic_json(assets/'manifest.json',registry)
    atomic_json(out/'factory.json',dict(build_id=build_id,config=config or manifest['config']))
    shutil.copyfile(source/'win/factory/guest.py',out/'factory-guest.py')
    return out
