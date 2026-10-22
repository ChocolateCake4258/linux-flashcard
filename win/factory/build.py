#!/usr/bin/env python3
"""Supported fresh Debian factory. Never opens or selects a physical disk."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent))
from common import GIB, Workspace, atomic_json, digest, utcnow, workspace_path
from inputs import prepare_inputs
from seed import make_seed, stage_iso_tree
from storage import publish_fixed_vhd, retire, storage_usage

STAGES=('inputs','seed','images','provision','layout','assemble','direct1','ventoy2','direct3','finalize')
SOURCE=Path(__file__).resolve().parents[2]

def ps(script,*arguments,capture=False):
    command=['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(script),*map(str,arguments)]
    result=subprocess.run(command,check=True,stdout=subprocess.PIPE if capture else None,
                          text=True,encoding='utf-8-sig',errors='replace')
    return result.stdout.strip() if capture else None

def process_alive(pid):
    if os.name!='nt':
        try:os.kill(pid,0);return True
        except OSError:return False
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.OpenProcess.restype=ctypes.c_void_p
    kernel.OpenProcess.argtypes=[ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32]
    handle=kernel.OpenProcess(0x1000,0,int(pid))
    if not handle:return False
    code=ctypes.c_uint32()
    try:return bool(kernel.GetExitCodeProcess(ctypes.c_void_p(handle),ctypes.byref(code))) and code.value==259
    finally:kernel.CloseHandle(ctypes.c_void_p(handle))

def qmp(port,command):
    with socket.create_connection(('127.0.0.1',int(port)),timeout=10) as connection:
        reader=connection.makefile('rb');writer=connection.makefile('wb')
        json.loads(reader.readline())
        for name in ('qmp_capabilities',command):
            writer.write(json.dumps(dict(execute=name,id=name)).encode()+b'\n');writer.flush()
            while True:
                line=reader.readline()
                if not line:raise RuntimeError('Factory QMP closed before acknowledgement.')
                reply=json.loads(line)
                if reply.get('id')==name:break
            if 'error' in reply:raise RuntimeError(str(reply['error']))
        return reply.get('return')

def resource_profile(mode,ram,cores,total,free,logical):
    if logical<1:raise ValueError('Host logical CPU count unavailable.')
    if ram==0:
        limit=min(6144,(total//2//1024)*1024) if mode=='WHPX' else 4096
        ram=min(limit,((free-2048)//1024)*1024)
    if cores==0:cores=min(4,max(1,logical//2)) if mode=='WHPX' else min(2,logical)
    if ram<2048 or ram>total-2048 or free<ram+2048:raise RuntimeError(f'Need {max(2048,ram)+2048} MiB free including Windows reserve; found {free}.')
    if not 1<=cores<=logical:raise ValueError('Invalid factory CPU count.')
    return int(ram),int(cores)

class Factory:
    def __init__(self,workspace,args):
        self.ws=workspace;self.work=workspace.path;self.args=args
        pin_files=('win/factory/inputs.json','win/factory/runtime.lock','win/full-suite/fetch-inputs.py','win/unified/fetch-inputs.py')
        if args.refresh_sources and workspace.state.get('config_hash'):
            requested=''.join(digest(SOURCE/p) for p in pin_files)
            if requested!=workspace.state['config_hash']:raise RuntimeError('Pinned inputs changed; original workspace remains unchanged. Use a new workspace.')
        if args.refresh_sources and workspace.state.get('storage_policy')=='compact' and workspace.done('assemble'):
            raise RuntimeError('The standalone disk has been retired after assembly. Use a new workspace for changed sources.')
        self.source=workspace.source_snapshot(SOURCE,args.refresh_sources)
        self.config=json.loads((self.source/'win/factory/inputs.json').read_text())
        previous_media=workspace.state.get('media_bytes',self.config['usb_bytes'])
        requested_media=getattr(args,'usb_bytes',0) or previous_media
        if requested_media<self.config['linux_bytes']+2*GIB or requested_media%512:
            raise RuntimeError('USB capacity must be sector-aligned and leave at least 2 GiB outside the Linux file.')
        if workspace.state.get('media_bytes') and requested_media!=previous_media:
            raise RuntimeError('USB capacity changed; choose a new factory workspace.')
        if (workspace.done('seed') or workspace.done('images')) and requested_media!=previous_media:
            raise RuntimeError('Existing factory images were created for another capacity.')
        self.config['usb_bytes']=requested_media
        workspace.state['media_bytes']=requested_media
        config_hash=''.join(digest(self.source/p) for p in pin_files)
        previous=self.ws.state.get('config_hash')
        if previous and previous!=config_hash:raise RuntimeError('Pinned inputs changed; use a new build workspace.')
        self.ws.state['config_hash']=config_hash;self.ws.save()
        policy=self.ws.state.get('storage_policy')
        if policy is None:
            policy='keep' if workspace.state['stages'] or getattr(args,'keep_intermediates',False) else 'compact'
            self.ws.state['storage_policy']=policy;self.ws.save()
        if policy not in ('compact','keep') or (getattr(args,'keep_intermediates',False) and policy!='keep'):
            raise RuntimeError('Storage policy differs from this workspace; choose a new workspace.')
        self.compact=policy=='compact'
        self.working=self.work/'working';self.working.mkdir(exist_ok=True)
        self.root=self.working/'linux.img.vtoy';self.layout=self.working/'usb-layout.vhd'
        self.qemu=self.work/'tools/qemu/qemu-system-x86_64.exe'
        self.img=self.work/'tools/qemu/qemu-img.exe'
        self.mount=self.work/'mount'
        self.factory=self.source/'win/factory'

    def host_info(self):
        output=subprocess.check_output(['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',
            ". '"+str(self.source/'win/lib/pf-whpx.ps1').replace("'","''")+"';$c=Get-CimInstance Win32_ComputerSystem;$o=Get-CimInstance Win32_OperatingSystem;[ordered]@{Total=[math]::Floor($c.TotalPhysicalMemory/1MB);Free=[math]::Floor($o.FreePhysicalMemory/1024);Logical=$c.NumberOfLogicalProcessors;Whpx=(Get-PfWhpxStatus).Available}|ConvertTo-Json"],text=True,encoding='utf-8-sig')
        return json.loads(output)

    def ensure_space(self):
        if self.ws.done('images'):return
        need=self.config['linux_bytes']+(1 if self.compact else 2)*self.config['usb_bytes']+6*GIB
        if shutil.disk_usage(self.work).free<need:raise RuntimeError(f'Factory needs {need//GIB+1} GiB free before image creation.')

    def make_iso(self,directory,path,label):
        if path.exists():path.unlink()  # Owned, incomplete stage output only.
        ps(self.factory/'make-iso.ps1','-Directory',directory,'-Output',path,'-Label',label)

    def seed(self):
        seed=make_seed(self.source,self.work,self.ws.state['build_id'])
        self.make_iso(seed,self.work/'seed.iso','CIDATA')
        tree=stage_iso_tree(self.source,self.work,self.ws.state['build_id'],self.config)
        self.make_iso(tree,self.work/'inputs.iso','PFINPUTS')
        return dict(seed_sha256=digest(self.work/'seed.iso'),inputs_sha256=digest(self.work/'inputs.iso'))

    def images(self):
        receipt=self.working/'image-creation.json'
        if self.root.exists() or self.layout.exists():
            if not receipt.exists() or json.loads(receipt.read_text()).get('build_id')!=self.ws.state['build_id']:
                raise RuntimeError('Uncheckpointed image names are not owned by this factory.')
            if list((self.work/'jobs').glob('*')) if (self.work/'jobs').exists() else False:
                raise RuntimeError('Cannot recreate images after guest jobs have started.')
            for path in (self.root,self.layout):
                if path.exists():path.unlink()
        atomic_json(receipt,dict(build_id=self.ws.state['build_id'],root=str(self.root),layout=str(self.layout)))
        root=self.root.with_suffix('.partial');layout=self.layout.with_suffix('.partial')
        dense=self.root.with_suffix('.dense')
        for path in (root,layout,dense):
            if path.exists():path.unlink()
        self.ensure_space()
        # The Windows raw driver rejects preallocation=full. A real streamed
        # copy materializes every byte without relying on sparse raw options.
        subprocess.run([self.img,'convert','-f','qcow2','-O','raw',self.work/'cache'/self.config['base']['name'],root],check=True)
        subprocess.run([self.img,'resize','-f','raw',root,str(self.config['linux_bytes'])],check=True)
        with root.open('rb') as source,dense.open('wb') as target:
            shutil.copyfileobj(source,target,4*1024**2);target.flush();os.fsync(target.fileno())
        root.unlink();dense.rename(root)
        subprocess.run([self.img,'create','-f','vpc','-o','subformat=fixed,force_size=on',layout,str(self.config['usb_bytes'])],check=True)
        if root.stat().st_size!=self.config['linux_bytes'] or layout.stat().st_size!=self.config['usb_bytes']+512:raise RuntimeError('Factory image capacities differ.')
        for path in (root,layout):
            attributes=ctypes.windll.kernel32.GetFileAttributesW(str(path))
            if attributes==-1:raise RuntimeError('Cannot inspect factory file allocation attributes.')
            if attributes&0x200:subprocess.run(['fsutil.exe','sparse','setflag',str(path),'0'],check=True)
            if ctypes.windll.kernel32.GetFileAttributesW(str(path))&(0x200|0x800|0x4000):
                raise RuntimeError('Factory disks must be uncompressed, unencrypted and nonsparse.')
        root.rename(self.root);layout.rename(self.layout)
        shutil.copyfile(self.work/'tools/qemu/share/qemu/edk2-i386-vars.fd',Path(str(self.root)+'.uefi-vars.fd'))
        return dict(root_bytes=self.root.stat().st_size,layout_bytes=self.layout.stat().st_size)

    def mounted(self,unmount=False):
        flags=['-Workspace',self.work]
        if unmount:flags+=['-Unmount']
        ps(self.factory/'mount-layout.ps1',*flags)

    def assemble(self):
        self.mounted()
        try:
            identity=json.loads((self.mount/'factory-layout.json').read_text())
            if identity['build_id']!=self.ws.state['build_id']:raise RuntimeError('Mounted layout belongs to another build.')
            target=self.mount/'linux.img.vtoy';partial=self.mount/'linux.img.vtoy.partial'
            sha=digest(self.root)
            if target.exists():
                if digest(target)!=sha:raise RuntimeError('Uncheckpointed shared image changed; preserve before replacing.')
            else:
                with self.root.open('rb') as source,partial.open('wb') as output:
                    shutil.copyfileobj(source,output,4*1024**2);output.flush();os.fsync(output.fileno())
                if digest(partial)!=sha:raise RuntimeError('Shared-image assembly checksum mismatch.')
                partial.rename(target)
            vars=Path(str(target)+'.uefi-vars.fd')
            if not vars.exists():shutil.copyfile(str(self.root)+'.uefi-vars.fd',vars)
            vars_sha=digest(str(self.root)+'.uefi-vars.fd')
            if digest(vars)!=vars_sha:raise RuntimeError('Assembled persistent VARS differ from their source.')
            return dict(shared_image_sha256=sha,linux_bytes=target.stat().st_size,vars_sha256=vars_sha)
        finally:self.mounted(unmount=True)

    def retire_stage(self,stage):
        if not self.compact:return
        if stage=='seed' and any((self.work/name).exists() for name in ('iso-files','seed-files')):
            for name,key in (('seed.iso','seed_sha256'),('inputs.iso','inputs_sha256')):
                if digest(self.work/name)!=self.ws.state['stages']['seed'][key]:raise RuntimeError('Successor ISO changed; staging was retained.')
        if stage=='assemble':
            record=self.ws.state['stages']['assemble']
            for path,key in ((self.root,'shared_image_sha256'),(Path(str(self.root)+'.uefi-vars.fd'),'vars_sha256')):
                if path.exists() and (not record.get(key) or digest(path)!=record[key]):raise RuntimeError('Standalone source changed; it was not retired.')
        if stage in ('seed','assemble'):retire(self.ws,stage)

    def record_storage(self,stage):
        usage=storage_usage(self.work)
        self.ws.state.setdefault('storage_observations',{})[stage]=usage
        self.ws.state['peak_observed_file_bytes']=max(self.ws.state.get('peak_observed_file_bytes',0),usage['unique_file_bytes'])
        self.ws.save()

    def job(self,action):
        if action in ('direct1','direct3'):self.mounted()
        else:self.mounted(unmount=True) if self.ws.done('assemble') else None
        try:return self.run_job(action)
        finally:
            if action in ('direct1','direct3'):self.mounted(unmount=True)

    def run_job(self,action):
        running=self.ws.state.get('active_job')
        if running and running['action']!=action:raise RuntimeError('Another factory stage has an outstanding job; resume that stage first.')
        if running:
            directory=self.work/running['directory']
            config=json.loads((directory/'job.json').read_text())
            exit_path=directory/'exit.json'
            process_path=directory/'process.json'
            if not exit_path.exists() and process_path.exists():
                process=json.loads(process_path.read_text(encoding='utf-8-sig'))
                if not(process_alive(process['RunnerPid']) or process_alive(process['Pid'])):
                    self.ws.state.pop('active_job');self.ws.save();running=None
            elif not exit_path.exists() and (directory/'runner.json').exists():
                launcher=json.loads((directory/'runner.json').read_text())
                alive=self.task_running(directory) if config.get('runner_kind')=='task' else process_alive(launcher['pid'])
                if not alive:
                    self.ws.state.pop('active_job');self.ws.save();running=None
        if not running:
            directory=self.work/'jobs'/(action+'-'+uuid.uuid4().hex)
            directory.mkdir(parents=True)
            host=self.host_info()
            mode=self.args.accelerator
            if mode=='Auto':mode='WHPX' if host['Whpx'] else 'TCG'
            if mode=='WHPX' and not host['Whpx']:raise RuntimeError('WHPX unavailable; configure Windows or choose explicit TCG.')
            ram,cores=resource_profile(mode,self.args.ram_mb,self.args.cores,host['Total'],host['Free'],host['Logical'])
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            job_id=directory.name.split('-',1)[1]
            control=dict(action=action,build_id=self.ws.state['build_id'],job_id=job_id,
                         guest_sha256=digest(self.factory/'guest.py'))
            atomic_json(directory/'control.json',control)
            image=self.root if action in ('provision','layout') else self.mount/'linux.img.vtoy'
            vars=Path(str(image)+'.uefi-vars.fd')
            if action=='ventoy2':
                image=self.layout;vars=self.working/'ventoy.uefi-vars.fd'
                if not vars.exists():shutil.copyfile(self.work/'tools/qemu/share/qemu/edk2-i386-vars.fd',vars)
            esc=lambda p:str(p).replace(',',',,')
            guest_name='pf-factory-'+self.ws.state['build_id']+'-'+job_id
            arguments=['-name',guest_name,'-L',str(self.work/'tools/qemu/share/qemu'),'-machine','q35','-accel',
                       'whpx,kernel-irqchip=off' if mode=='WHPX' else 'tcg,thread=multi',
                       '-cpu','Westmere','-m',str(ram)+'M','-smp',str(cores),'-rtc','base=localtime',
                       '-vga','none','-device','VGA,id=pfgfx,edid=on,xres=1024,yres=768,refresh_rate=60',
                       '-display','none','-drive','if=pflash,format=raw,readonly=on,file='+esc(self.work/'tools/qemu/share/qemu/edk2-x86_64-code.fd'),
                       '-drive','if=pflash,format=raw,file='+esc(vars),'-serial','file:'+str(directory/'serial.log'),
                       '-qmp',f'tcp:127.0.0.1:{port},server=on,wait=off',
                       '-netdev','user,id=pfnet'+(',restrict=on' if self.config.get('prepared_template') else ''),'-device','virtio-net-pci,netdev=pfnet,addr=0x3',
                       '-fw_cfg','name=opt/pf.factory,file='+esc(directory/'control.json'),
                       '-device','virtio-serial-pci,addr=0x7','-chardev','file,id=pfresults,path='+esc(directory/'guest-result.json'),
                       '-device','virtserialport,chardev=pfresults,name=org.linuxflashcard.factory',
                       '-drive','file='+esc(self.work/'inputs.iso')+',format=raw,media=cdrom,readonly=on']
            if action in ('provision','layout'):
                arguments+=['-drive','if=none,id=pfroot,file='+esc(self.root)+',format=raw',
                            '-device','virtio-blk-pci,drive=pfroot,addr=0x4,bootindex=1','-boot','order=c']
                if action=='provision':arguments+=['-drive','file='+esc(self.work/'seed.iso')+',format=raw,media=cdrom,readonly=on']
                if action=='layout':arguments+=['-drive','if=none,id=pflayout,file='+esc(self.layout)+',format=vpc',
                                               '-device','virtio-blk-pci,drive=pflayout,serial=PF_FACTORY_LAYOUT,addr=0x9']
            elif action=='ventoy2':
                arguments+=['-device','qemu-xhci,id=usbctl,addr=0x5','-drive','if=none,id=pfusb,file='+esc(self.layout)+',format=vpc',
                            '-device','usb-storage,bus=usbctl.0,drive=pfusb,bootindex=1,removable=on']
            else:arguments+=['-drive','if=none,id=pfroot,file='+esc(image)+',format=raw',
                             '-device','virtio-blk-pci,drive=pfroot,addr=0x4,bootindex=1','-boot','order=c']
            config=dict(JobId=job_id,BuildId=self.ws.state['build_id'],Qemu=str(self.qemu),Arguments=arguments,
                        Guard=str(image)+'.launch.lock',port=port,mode=mode,ram_mb=ram,cores=cores,guest_name=guest_name,
                        runner_kind='task',RunnerScript=str(self.factory/'run-qemu.ps1'))
            atomic_json(directory/'job.json',config)
            self.ws.state['active_job']=dict(action=action,directory=str(directory.relative_to(self.work)));self.ws.save()
            started=json.loads(ps(self.factory/'background-job.ps1','-Job',directory/'job.json','-Action','Start',capture=True))
            atomic_json(directory/'runner.json',dict(**started,started_at=utcnow()))
        print(f'{action}: {config["mode"]}, {config["ram_mb"]} MiB / {config["cores"]} CPU; '+str(directory),flush=True)
        deadline=time.monotonic()+self.args.timeout_min*60
        last=-1
        waiting_since=time.monotonic()
        while not (directory/'exit.json').exists():
            if not (directory/'process.json').exists() and time.monotonic()-waiting_since>30:
                launcher_path=directory/'runner.json'
                launcher=json.loads(launcher_path.read_text()) if launcher_path.exists() else {}
                alive=self.task_running(directory) if config.get('runner_kind')=='task' else process_alive(launcher.get('pid',0))
                if launcher_path.exists() and not alive:
                    raise RuntimeError('Factory runner failed before QEMU startup; inspect runner-stderr.log. Resume retains this attempt.')
            serial=directory/'serial.log'
            size=serial.stat().st_size if serial.exists() else 0
            if size!=last:
                print(action+': serial '+str(size)+' bytes',flush=True);last=size
            if time.monotonic()>deadline:raise RuntimeError('Factory job timeout; runner/job retained. Use --status / --stop / --resume.')
            time.sleep(5)
        exit=json.loads((directory/'exit.json').read_text(encoding='utf-8-sig'))
        if config.get('runner_kind')=='task':
            for _ in range(20):
                if not self.task_running(directory):break
                time.sleep(.5)
            ps(self.factory/'background-job.ps1','-Job',directory/'job.json','-Action','Cleanup')
        self.ws.state.pop('active_job',None);self.ws.save()
        if exit['ExitCode']!=0:raise RuntimeError('QEMU runner failed: '+str(exit))
        result=json.loads((directory/'guest-result.json').read_text())
        if result.get('build_id')!=self.ws.state['build_id'] or result.get('job_id')!=config['JobId'] or result.get('action')!=action:
            raise RuntimeError('Stale/foreign factory guest receipt.')
        if not result.get('complete'):raise RuntimeError('Guest preparation failed: '+str(result.get('error')))
        if action=='direct3' and not(result.get('sealed') and result.get('first_password_pending')):raise RuntimeError('Image was not sealed with a private first-password gate.')
        return dict(job=str(directory.relative_to(self.work)),profile=config,result=result)

    def task_running(self,directory):
        status=json.loads(ps(self.factory/'background-job.ps1','-Job',directory/'job.json','-Action','Status',capture=True))
        return status['state'] in ('Running','Queued')

    def finalize(self):
        artifacts=self.work/'artifacts';artifacts.mkdir(exist_ok=True)
        output=artifacts/'linux-flashcard-usb.img'
        publication=artifacts/'publication.json'
        if output.exists():
            if not publication.exists():raise RuntimeError('Unowned published output exists.')
            result=json.loads(publication.read_text())
            if result['build_id']!=self.ws.state['build_id'] or digest(output)!=result['sha256']:raise RuntimeError('Published output differs from its receipt.')
            Path(str(output)+'.sha256').write_text(result['sha256']+'\n',encoding='ascii')
            Path(str(output)+'.sha256sum').write_text(result['sha256']+'  '+output.name+'\n',encoding='ascii')
            atomic_json(artifacts/'build-result.json',result)
            return result
        compact_receipt=artifacts/'compact-publication.json'
        if self.compact and compact_receipt.exists():
            result=publish_fixed_vhd(self.layout,output,self.config['usb_bytes'],self.ws.state['build_id'],self.ws.state['source_hash'],validate_gpt)
            return self.finish_sidecars(output,result)
        self.mounted()
        try:
            linux=self.mount/'linux.img.vtoy';sha=digest(linux)
            build=dict(schema=1,build_id=self.ws.state['build_id'],source_hash=self.ws.state['source_hash'],
                       linux_image_sha256=sha,linux_bytes=linux.stat().st_size,usb_bytes=self.config['usb_bytes'],
                       effective_config=self.config,
                       storage_policy=self.ws.state['storage_policy'],
                       first_password_pending=True,proof=self.ws.state['stages']['direct3']['result'],
                       provision=self.ws.state['stages']['provision']['result'],inputs=json.loads((self.work/'inputs-manifest.json').read_text()))
            atomic_json(self.mount/'BUILD-INFO.json',build)
        finally:self.mounted(unmount=True)
        if self.compact:
            result=publish_fixed_vhd(self.layout,output,self.config['usb_bytes'],self.ws.state['build_id'],self.ws.state['source_hash'],validate_gpt)
            return self.finish_sidecars(output,result)
        partial=output.with_suffix('.partial')
        if partial.exists():partial.unlink()
        subprocess.run([self.img,'convert','-f','vpc','-O','raw',self.layout,partial],check=True)
        if partial.stat().st_size!=self.config['usb_bytes']:raise RuntimeError('Final USB image capacity mismatch.')
        subprocess.run([self.img,'compare','-f','vpc','-F','raw',self.layout,partial],check=True)
        validate_gpt(partial)
        sha=digest(partial)
        result=dict(complete=True,build_id=self.ws.state['build_id'],image=str(output),bytes=partial.stat().st_size,
                    sha256=sha,source_hash=self.ws.state['source_hash'],first_password_pending=True)
        atomic_json(publication,result);partial.rename(output)
        (Path(str(output)+'.sha256')).write_text(sha+'\n',encoding='ascii')
        (Path(str(output)+'.sha256sum')).write_text(sha+'  '+output.name+'\n',encoding='ascii')
        atomic_json(artifacts/'build-result.json',result)
        return result

    def finish_sidecars(self,output,result):
        Path(str(output)+'.sha256').write_text(result['sha256']+'\n',encoding='ascii')
        Path(str(output)+'.sha256sum').write_text(result['sha256']+'  '+output.name+'\n',encoding='ascii')
        atomic_json(output.parent/'build-result.json',result)
        return result

def validate_gpt(path,disk_bytes=None):
    import struct,zlib
    with Path(path).open('rb') as stream:
        length=stream.seek(0,2);size=length if disk_bytes is None else disk_bytes
        if length<size or size<2*1024**2:raise RuntimeError('Truncated final disk data.')
        stream.seek(510)
        if stream.read(2)!=b'\x55\xaa' or size%512:raise RuntimeError('Invalid final protective MBR/capacity.')
        tables=[]
        for lba in (1,size//512-1):
            stream.seek(lba*512);header=bytearray(stream.read(512))
            if header[:8]!=b'EFI PART':raise RuntimeError('Missing final GPT header.')
            length=struct.unpack_from('<I',header,12)[0];expected=struct.unpack_from('<I',header,16)[0]
            if not 92<=length<=512:raise RuntimeError('Invalid GPT header length.')
            struct.pack_into('<I',header,16,0)
            if zlib.crc32(header[:length])!=expected:raise RuntimeError('Final GPT header CRC mismatch.')
            if struct.unpack_from('<Q',header,24)[0]!=lba:raise RuntimeError('Final GPT location mismatch.')
            if struct.unpack_from('<Q',header,32)[0]!=(size//512-1 if lba==1 else 1):raise RuntimeError('Final GPT peer location mismatch.')
            table,count,width,crc=struct.unpack_from('<QIII',header,72)
            if count*width>16*1024**2:raise RuntimeError('Invalid GPT table bounds.')
            stream.seek(table*512)
            entries=stream.read(count*width)
            if zlib.crc32(entries)!=crc:raise RuntimeError('Final GPT table CRC mismatch.')
            tables.append(entries)
        if tables[0]!=tables[1]:raise RuntimeError('Final GPT tables differ.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace',required=True,type=Path)
    parser.add_argument('--resume',action='store_true');parser.add_argument('--refresh-sources',action='store_true')
    parser.add_argument('--accelerator',choices=['Auto','WHPX','TCG'],default='Auto')
    parser.add_argument('--ram-mb',type=int,default=0);parser.add_argument('--cores',type=int,default=0)
    parser.add_argument('--usb-bytes',type=int,default=0)
    parser.add_argument('--to-stage',choices=STAGES,default='finalize');parser.add_argument('--timeout-min',type=int,default=240)
    parser.add_argument('--status',action='store_true');parser.add_argument('--stop',action='store_true')
    parser.add_argument('--force-stop',action='store_true')
    parser.add_argument('--keep-intermediates',action='store_true')
    args=parser.parse_args()
    if args.status:
        print((args.workspace/'factory-state.json').read_text(encoding='utf-8-sig'));return
    if os.name!='nt':raise SystemExit('The supported factory host is Windows 10/11 x64; use win/build-debian.bat.')
    if args.stop:
        work=workspace_path(args.workspace,SOURCE)
        state=json.loads((work/'factory-state.json').read_text(encoding='utf-8-sig'))
        if state.get('schema')!=1 or state.get('workspace')!=str(work):raise RuntimeError('Factory stop ownership mismatch.')
        active=state.get('active_job')
        if not active:raise RuntimeError('No owned factory job is active.')
        directory=(work/active['directory']).resolve()
        if work not in directory.parents:raise RuntimeError('Foreign factory job directory.')
        config=json.loads((directory/'job.json').read_text())
        if config['BuildId']!=state['build_id'] or qmp(config['port'],'query-name').get('name')!=config['guest_name']:
            raise RuntimeError('QMP endpoint no longer belongs to this factory job.')
        qmp(config['port'],'quit' if args.force_stop else 'system_powerdown');return
    if args.force_stop:raise RuntimeError('--force-stop requires --stop and an owned factory job.')
    ws=Workspace(args.workspace,SOURCE,args.resume).lock()
    try:
        factory=Factory(ws,args)
        if STAGES.index(args.to_stage)>=STAGES.index('images') and not(factory.working/'image-creation.json').exists():factory.ensure_space()
        if ws.done('inputs'):
            prepare_inputs(factory.source,ws.path)
            if digest(ws.path/'inputs-manifest.json')!=ws.state['stages']['inputs']['manifest_sha256']:
                raise RuntimeError('Verified factory input manifest changed.')
        actions=dict(inputs=lambda:prepare_inputs(factory.source,ws.path),seed=factory.seed,images=factory.images,
                     provision=lambda:factory.job('provision'),layout=lambda:factory.job('layout'),assemble=factory.assemble,
                     direct1=lambda:factory.job('direct1'),ventoy2=lambda:factory.job('ventoy2'),
                     direct3=lambda:factory.job('direct3'),finalize=factory.finalize)
        for stage in STAGES:
            if stage=='finalize' and ws.done(stage):
                evidence=ws.state['stages'][stage]
                if digest(evidence['image'])!=evidence['sha256']:raise RuntimeError('Published USB image changed.')
            ws.stage(stage,actions[stage])
            factory.record_storage(stage+'-before-retirement')
            factory.retire_stage(stage)
            factory.record_storage(stage+'-after-retirement')
            if stage==args.to_stage:break
        print(json.dumps(dict(complete=ws.done('finalize'),workspace=str(ws.path),last_stage=args.to_stage),indent=2))
    finally:ws.close()

if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('FACTORY ERROR: '+str(exc),file=sys.stderr,flush=True);sys.exit(1)
