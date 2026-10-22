#!/usr/bin/python3
"""Explicit fresh-image factory jobs, authenticated by the build's fw_cfg ID."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import time
import traceback

BASE=Path('/var/lib/linux-flashcard')
INPUTS=Path('/mnt/pf-factory-inputs')
FW=Path('/sys/firmware/qemu_fw_cfg/by_name/opt/pf.factory/raw')
PORT=Path('/dev/virtio-ports/org.linuxflashcard.factory')
job={}
progress={}

def run(*args,env=None,**kwargs):
    return subprocess.run(args,env=env,check=True,**kwargs)

def text(*args):
    return subprocess.check_output(args,text=True).strip()

def store(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.new')
    temporary.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    os.replace(temporary,path)

def emit(marker):
    print(marker,flush=True)
    with open('/dev/kmsg','w') as stream:stream.write('<6>'+marker+'\n')

def report(data):
    data.update(build_id=job.get('build_id'),job_id=job.get('job_id'),action=job.get('action'))
    store(BASE/'factory-results'/((job.get('job_id') or 'unknown')+'.json'),data)
    for _ in range(50):
        if PORT.exists():break
        time.sleep(.1)
    payload=json.dumps(data,ensure_ascii=False).encode()
    with PORT.open('wb',buffering=0) as stream:
        offset=0
        while offset<len(payload):
            count=stream.write(payload[offset:])
            if not count:raise RuntimeError('Factory result channel closed early.')
            offset+=count

def step(name,check,action):
    if check():
        progress[name]='already complete';return
    if job.get('prepared_template'):
        raise RuntimeError('Prepared template prerequisite is missing: '+name)
    emit('[PF_FACTORY_STEP] '+name)
    action()
    if not check():raise RuntimeError('Stage postcondition failed: '+name)
    progress[name]='complete';store(BASE/'factory-progress.json',progress)

def mount_inputs():
    INPUTS.mkdir(parents=True,exist_ok=True)
    if subprocess.run(['mountpoint','-q',str(INPUTS)]).returncode:
        device=text('findfs','LABEL=PFINPUTS')
        run('mount','-o','ro',device,str(INPUTS))
    config=json.loads((INPUTS/'factory.json').read_text())
    if config['build_id']!=job['build_id']:raise RuntimeError('Factory input identity mismatch.')
    for item in json.loads((INPUTS/'vendor-inputs.json').read_text()):
        with (INPUTS/item['name']).open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest()
        if sha!=item['resolved_sha256']:raise RuntimeError('Factory vendor media checksum mismatch: '+item['name'])
    assets=json.loads((INPUTS/'guest-assets/manifest.json').read_text())
    for item in assets:
        source=INPUTS/'guest-assets'/item['file']
        with source.open('rb') as stream:actual=hashlib.file_digest(stream,'sha256').hexdigest()
        if actual!=item['sha256']:raise RuntimeError('Factory guest payload checksum mismatch.')
        target=Path(item['path'])
        if not valid_asset_target(target):
            raise RuntimeError('Unexpected guest asset destination: '+str(target))
    claim_origin(config['config'])
    for item in assets:
        source=INPUTS/'guest-assets'/item['file'];target=Path(item['path'])
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target);target.chmod(int(item['mode'],8))
    run('systemctl','daemon-reload')
    shared=Path('/usr/local/share/linux-flashcard')
    shutil.copyfile(INPUTS/'runtime-images.json',shared/'full-suite-runtime.json')
    return config['config']

def valid_asset_target(target):
    target=PurePosixPath(str(target))
    return target.is_absolute() and '..' not in target.parts and str(target).startswith(
        ('/usr/local/','/usr/lib/systemd/system-generators/','/usr/share/applications/','/etc/systemd/system/'))

def package_installed(name):
    p=subprocess.run(['dpkg-query','-W','-f=${db:Status-Status}',name],capture_output=True,text=True)
    return p.returncode==0 and p.stdout=='installed'

def apt(*packages):
    run('apt-get','-o','DPkg::Lock::Timeout=180','update')
    run('apt-get','-y','--no-remove','--no-install-recommends','-o','DPkg::Lock::Timeout=180','install',*packages)

def unified():
    sources=Path('/etc/apt/sources.list.d/debian.sources')
    value=sources.read_text()
    sources.write_text(value.replace('Components: main\n','Components: main non-free-firmware\n'))
    apt('mate-polkit','network-manager','network-manager-gnome','wpasupplicant','firmware-linux-free',
        'firmware-nvidia-graphics','firmware-amd-graphics','firmware-iwlwifi','firmware-realtek',
        'ntfs-3g','dosfstools','parted','dmsetup','initramfs-tools')
    if subprocess.run(['mountpoint','-q','/boot/efi']).returncode:run('mount','/boot/efi')
    root=text('findmnt','-n','-o','UUID','/');efi=text('findmnt','-n','-o','UUID','/boot/efi')
    if not root or not efi:raise RuntimeError('Cannot identify fresh root/EFI UUIDs.')
    Path('/etc/fstab').write_text(f'UUID={root} / ext4 rw,errors=remount-ro 0 1\nUUID={efi} /boot/efi vfat defaults,umask=077 0 2\n')
    Path('/etc/netplan/99-pf-unified.yaml').write_text('network:\n  version: 2\n  renderer: NetworkManager\n')
    Path('/etc/netplan/99-pf-unified.yaml').chmod(0o600)
    Path('/etc/default/grub.d/99-pf-unified.cfg').write_text('GRUB_TIMEOUT=1\nGRUB_TIMEOUT_STYLE=menu\nGRUB_DISABLE_LINUX_UUID=false\nGRUB_DISABLE_LINUX_PARTUUID=true\n')
    for unit in ('systemd-networkd.service','systemd-networkd.socket','systemd-networkd-wait-online.service'):
        subprocess.run(['systemctl','disable',unit],check=False)
    run('systemctl','enable','NetworkManager.service','pf-record-unified-boot.service')
    media=Path('/mnt/pf-vtoyboot');media.mkdir(exist_ok=True)
    if subprocess.run(['mountpoint','-q',str(media)]).returncode:run('mount','-o','loop,ro',str(INPUTS/'vtoyboot-1.0.36.iso'),str(media))
    vendor=Path('/usr/local/lib/linux-flashcard');vendor.mkdir(parents=True,exist_ok=True)
    if not (vendor/'vtoyboot-1.0.36/vtoyboot.sh').exists():
        archives=list(media.rglob('vtoyboot*.tar.gz'))
        if len(archives)!=1:raise RuntimeError('Unexpected vtoyboot ISO content.')
        with tarfile.open(archives[0]) as archive:archive.extractall(vendor,filter='data')
    run('bash','./vtoyboot.sh','-s',cwd=vendor/'vtoyboot-1.0.36')
    run('update-grub')
    Path('/etc/adjtime').write_text('0.0 0 0.0\n0\nLOCAL\n')
    (BASE/'unified-ready').touch()

def servers():
    clusters=text('pg_lsclusters','--no-header').splitlines()
    if len(clusters)!=1:raise RuntimeError('Expected one factory PostgreSQL cluster.')
    version,cluster,*_=clusters[0].split()
    run('systemctl','start','docker.service',f'postgresql@{version}-{cluster}.service')
    count=text('runuser','-u','postgres','--','psql','-X','-At','-c',"SELECT count(*) FROM pg_roles WHERE rolname='student';")
    if count=='0':run('runuser','-u','postgres','--','createuser','--createdb','student')
    return f'postgresql@{version}-{cluster}.service'

def stop_servers(cluster):
    run('systemctl','stop','docker.service','docker.socket','containerd.service',cluster)

def release_desktop(home=Path('/home/student')):
    # Only factory-supplied check sheets are removed from a fresh release image.
    names=('START-HERE.txt','FULL-START.txt','CLI-START.txt','PYTHON-START.txt','JAVA-START.txt')
    for folder in ('Desktop','Рабочий стол'):
        for name in names:
            path=home/folder/name
            if path.exists() or path.is_symlink():path.unlink()

def claim_origin(config):
    origin=BASE/'factory-origin.json'
    previous=json.loads(origin.read_text())['build_id'] if origin.exists() else None
    template=config.get('prepared_template')
    claim=BASE/'template-claim.json'
    intent=json.loads(claim.read_text()) if claim.exists() else None
    unfinished=intent and intent.get('target')==job['build_id'] and not intent.get('complete')
    if previous==job['build_id'] and not unfinished:return
    if previous is None:
        if (BASE/'factory-pending').read_text().strip()!=job['build_id']:raise RuntimeError('Unowned guest image.')
        store(origin,dict(build_id=job['build_id']));return
    if not template or template.get('schema')!=1:raise RuntimeError('Factory build identity changed.')
    if not unfinished:
        if previous!=template['build_id'] or not (BASE/'factory-ready').exists():raise RuntimeError('Prepared template origin/seal differs.')
        if (BASE/'password-ready').exists() or not text('getent','shadow','student').split(':')[1].startswith(('!','*')):
            raise RuntimeError('Prepared template must await its first user password.')
        packages=text('dpkg-query','-W','-f=${binary:Package}\t${Version}\t${db:Status-Status}\n')
        if hashlib.sha256(packages.encode()).hexdigest()!=template['packages_sha256']:
            raise RuntimeError('Prepared template package versions differ from the checkpoint.')
        intent=dict(source=previous,target=job['build_id'],packages_sha256=template['packages_sha256'],complete=False)
        store(claim,intent)
    if intent['source']!=template['build_id'] or intent['packages_sha256']!=template['packages_sha256']:
        raise RuntimeError('Prepared template claim changed.')
    (BASE/'factory-pending').write_text(job['build_id']+'\n')
    for name in ('factory-proof.json','factory-layout-ready','factory-ready','unified-route-proof-passed','full-suite-verified'):
        path=BASE/name
        if path.exists():path.unlink()
    store(origin,dict(build_id=job['build_id'],template_build_id=template['build_id']))
    intent['complete']=True;store(claim,intent)

def efi_fallback():
    if subprocess.run(['mountpoint','-q','/boot/efi']).returncode:run('mount','/boot/efi')
    if not shutil.which('grub-install'):apt('grub-efi-amd64-bin')
    run('grub-install','--target=x86_64-efi','--efi-directory=/boot/efi','--removable','--no-nvram')
    if not Path('/boot/efi/EFI/BOOT/BOOTX64.EFI').is_file():raise RuntimeError('UEFI removable loader missing.')
    (BASE/'factory-efi-fallback-ready').touch()

def desktop(state):
    # Rechecks must not inherit recovery dialogs from an earlier terminated GUI.
    directory=state/('d-'+job['job_id'][:8]);home=directory/'session-home'
    home.mkdir(parents=True,exist_ok=True)
    run('chown','-R','student:student',str(directory))
    run('runuser','-u','student','--','env',f'HOME={home}',f'XDG_CONFIG_HOME={home}/config',
        f'XDG_CACHE_HOME={home}/cache',f'XDG_DATA_HOME={home}/data',f'XDG_STATE_HOME={home}/state',
        'xvfb-run','-a','-s','-screen 0 1280x800x24','dbus-run-session','--',
        'pf-verify-desktop','--state',str(directory))
    return json.loads((directory/'desktop-checks.json').read_text())

def layout(config):
    device='/dev/vdb'
    if text('lsblk','-dn','-o','SERIAL',device)!='PF_FACTORY_LAYOUT':raise RuntimeError('Factory output device serial mismatch.')
    if int(text('blockdev','--getsize64',device))!=config['usb_bytes']:raise RuntimeError('Factory output capacity mismatch.')
    target=Path('/mnt/pf-factory-output');target.mkdir(exist_ok=True)
    if (BASE/'factory-layout-ready').exists():
        run('mount','-t','ntfs-3g',device+'1',str(target))
        try:
            if (target/'factory-layout.json').exists():return
        finally:run('umount',str(target))
    if text('lsblk','-n','-o','MOUNTPOINTS',device).strip():raise RuntimeError('Factory output already mounted.')
    vendor=Path('/usr/local/lib/linux-flashcard')
    if not (vendor/'ventoy-1.1.18/Ventoy2Disk.sh').exists():
        with tarfile.open(INPUTS/'ventoy-1.1.18-linux.tar.gz') as archive:archive.extractall(vendor,filter='data')
    run('bash','./Ventoy2Disk.sh','-I','-g','-L','FLASHCARD',device,cwd=vendor/'ventoy-1.1.18',input='y\ny\n',text=True)
    run('udevadm','settle')
    for _ in range(50):
        if Path(device+'1').exists() and Path(device+'2').exists():break
        time.sleep(.2)
    start=text('lsblk','-dn','-o','START',device+'1')
    if start!='2048':raise RuntimeError('Unexpected Ventoy data partition offset.')
    run('mkfs.ntfs','-F','-Q','-L','FLASHCARD','-s','512','-p',start,device+'1')
    run('mount','-t','ntfs-3g','-o','big_writes',device+'1',str(target))
    try:
        shutil.copytree(INPUTS/'qemu',target/'qemu',dirs_exist_ok=True)
        shutil.copytree(INPUTS/'payload',target,dirs_exist_ok=True)
        store(target/'factory-layout.json',dict(build_id=job['build_id'],linux_bytes=config['linux_bytes']))
    finally:run('umount',str(target))
    (BASE/'factory-layout-ready').touch()

def provision(config):
    release_desktop()
    env=os.environ.copy();env.update(DEBIAN_FRONTEND='noninteractive',LC_ALL='C',PF_NO_POWEROFF='1')
    # Finish interrupted package configuration before retrying a guest stage.
    inhibitor=Path('/usr/sbin/policy-rc.d')
    if inhibitor.exists() and inhibitor.read_text()=='#!/bin/sh\nexit 101\n':inhibitor.unlink()
    run('dpkg','--configure','-a',env=env)
    step('desktop',lambda:(BASE/'desktop-ready').exists(),lambda:run('bash','/usr/local/sbin/pf-prepare-desktop',env=env))
    step('desktop-icons',lambda:package_installed('librsvg2-common') and package_installed('shared-mime-info'),
         lambda:apt('librsvg2-common','shared-mime-info'))
    for key,package,helper in [('cli','gdb','pf-install-cli'),('python','firefox-esr-l10n-ru','pf-install-python'),('java','default-jdk-headless','pf-install-java')]:
        marker=BASE/('factory-'+key+'-ready')
        def install(helper=helper,marker=marker):
            run('bash','/usr/local/sbin/'+helper,env=env);marker.touch()
        step(key,lambda marker=marker,package=package:marker.exists() and package_installed(package),install)
    step('unified',lambda:(BASE/'unified-ready').exists() and Path('/sbin/vtoydump').exists(),unified)
    step('efi-fallback',lambda:(BASE/'factory-efi-fallback-ready').exists(),efi_fallback)
    env['PF_FULL_INPUTS']=str(INPUTS)
    step('applications',lambda:(BASE/'full-suite-installed').exists() and package_installed('docker-cli'),
         lambda:run('bash','/usr/local/sbin/pf-install-full-suite',env=env))
    if text('dpkg','--audit'):raise RuntimeError('Unfinished package configuration.')
    cluster=servers()
    images=json.loads((INPUTS/'runtime-images.json').read_text())
    for image in images.values():
        if subprocess.run(['docker','image','inspect',image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
            if config.get('prepared_template'):raise RuntimeError('Prepared container input is missing: '+image)
            run('docker','pull',image)
    receipt=BASE/'factory-checks.json'
    if receipt.exists():
        state=Path(json.loads(receipt.read_text())['state'])
        run('runuser','-u','student','--','pf-verify-all','--state',str(state),'--recheck')
    else:
        # Electron/JetBrains IPC uses Unix sockets with a 108-byte pathname limit.
        state=BASE/('fc-'+job['job_id'][:8])
        state.mkdir(exist_ok=True);run('chown','student:student',str(state))
        run('runuser','-u','student','--','pf-verify-all','--state',str(state))
        store(receipt,dict(state=str(state)))
    desktop_result=desktop(state)
    store(receipt,dict(state=str(state)))
    stop_servers(cluster)
    return dict(state=str(state),functional=json.loads((state/'checks-complete.json').read_text()),
                desktop=desktop_result)

def proof(action):
    expected={'direct1':1,'ventoy2':2,'direct3':3}[action]
    route='ventoy' if Path('/dev/mapper/ventoy').exists() else 'direct'
    if route!=('ventoy' if action=='ventoy2' else 'direct'):raise RuntimeError('Wrong actual boot route: '+route)
    ledger=BASE/'factory-proof.json'
    previous=json.loads(ledger.read_text()) if ledger.exists() else dict(count=0,build_id=job['build_id'])
    if previous['build_id']!=job['build_id'] or previous['count']<expected-1:raise RuntimeError('Shared boot proof did not persist.')
    current_uuid=text('findmnt','-n','-o','UUID','/')
    if previous.get('root_uuid') and previous['root_uuid']!=current_uuid:raise RuntimeError('Shared filesystem UUID changed between boot routes.')
    state=Path(json.loads((BASE/'factory-checks.json').read_text())['state'])
    cluster=servers()
    run('runuser','-u','student','--','pf-verify-all','--state',str(state),'--recheck')
    stop_servers(cluster)
    value=dict(build_id=job['build_id'],count=max(previous['count'],expected),route=route,
               root_uuid=current_uuid,kernel=text('uname','-r'))
    store(ledger,value)
    if action=='direct3':
        if not text('getent','shadow','student').split(':')[1].startswith(('!','*')):raise RuntimeError('Factory user must have no supplied password.')
        release_desktop()
        with Path('/usr/local/sbin/pf-first-password').open('rb') as stream:
            prompt_sha=hashlib.file_digest(stream,'sha256').hexdigest()
        value['release_ui']=dict(desktop_text_files=[str(path.relative_to('/home/student'))
            for folder in ('Desktop','Рабочий стол') for path in (Path('/home/student')/folder).glob('*.txt')],
            first_password_script_sha256=prompt_sha)
        run('systemctl','disable','pf-factory.service')
        (BASE/'unified-route-proof-passed').touch()
        (BASE/'full-suite-verified').touch()
        (BASE/'factory-ready').touch()
        pending=BASE/'factory-pending'
        if pending.exists():pending.unlink()
        value['sealed']=True;value['first_password_pending']=not (BASE/'password-ready').exists()
    value['persistent']=json.loads((state/'checks-rechecked.json').read_text())
    return value

def main():
    global job
    if os.geteuid()!=0:raise RuntimeError('Factory guest job requires its preparation service.')
    BASE.mkdir(exist_ok=True)
    run('modprobe','qemu_fw_cfg');run('modprobe','virtio_console')
    job=json.loads(FW.read_bytes().rstrip(b'\x00'))
    config=mount_inputs()
    job['prepared_template']=bool(config.get('prepared_template'))
    emit('[PF_FACTORY_START] '+job['action'])
    if job['action']=='provision':result=provision(config)
    elif job['action']=='layout':
        layout(config);result=dict(layout_ready=True)
    else:result=proof(job['action'])
    result.update(complete=True,progress=progress,packages=text('dpkg-query','-W','-f=${binary:Package}\t${Version}\t${db:Status-Status}\n'))
    report(result)
    emit('[PF_FACTORY_OK] '+job['action'])
    run('sync');run('systemctl','--no-block','poweroff')

if __name__=='__main__':
    try:main()
    except BaseException:
        error=traceback.format_exc();print(error,flush=True)
        diagnostics={}
        log=Path('/var/log/pf-factory.log')
        if log.exists():diagnostics['factory_log_tail']=log.read_text(errors='replace')[-16000:]
        for pattern in ('fc-*/desktop-ready/*.log','fc-*/d-*/*.log','factory-check-*/desktop-ready/*.log'):
            for path in BASE.glob(pattern):diagnostics[str(path)]=path.read_text(errors='replace')[-8000:]
        try:report(dict(complete=False,error=error,progress=progress,diagnostics=diagnostics))
        except BaseException:traceback.print_exc()
        emit('[PF_FACTORY_FAILED] '+str(job.get('action','unknown')))
        subprocess.run(['sync']);subprocess.run(['systemctl','--no-block','poweroff'])
        sys.exit(1)
