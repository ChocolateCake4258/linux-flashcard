#!/usr/bin/python3
"""Launch each desktop application on an isolated preparation X display."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--state',required=True,type=Path)
args=parser.parse_args()
if os.geteuid()==0:raise SystemExit('Run as the ordinary Linux user.')
state=args.state.resolve();state.mkdir(exist_ok=True)
env=os.environ.copy();env.update(QT_QUICK_BACKEND='software',LIBGL_ALWAYS_SOFTWARE='1',XDG_SESSION_TYPE='x11')
runtime=state/'runtime';runtime.mkdir(mode=0o700,exist_ok=True);runtime.chmod(0o700)
env['XDG_RUNTIME_DIR']=str(runtime)
wm_home=state/'window-manager-home';wm_home.mkdir(exist_ok=True)
env.update(HOME=str(wm_home),XDG_CONFIG_HOME=str(wm_home/'config'),XDG_CACHE_HOME=str(wm_home/'cache'),
           XDG_DATA_HOME=str(wm_home/'data'),XDG_STATE_HOME=str(wm_home/'state'))
wm_log=(state/'window-manager.log').open('w')
wm=subprocess.Popen(['xfwm4','--replace','--compositor=off'],env=env,stdout=wm_log,stderr=subprocess.STDOUT,start_new_session=True)
results={}
def windows():
    result=subprocess.run(['xprop','-root','_NET_CLIENT_LIST'],env=env,text=True,
                          stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    found={}
    for identifier in re.findall(r'0x[0-9a-fA-F]+',result.stdout):
        properties=subprocess.run(['xprop','-id',identifier,'-notype','_NET_WM_NAME','WM_NAME'],
                                  env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
        if properties.returncode:continue  # A window may close between the two queries.
        for line in properties.stdout.splitlines():
            if ' = "' in line:
                title=line.split(' = ',1)[1].strip().strip('"')
                if title:found[identifier]=title;break
    return found

def ready_window(name,title):
    title=title.casefold()
    if re.search(r'\bsplash\b|startup error|fatal error|cannot start',title):return False
    expected={'VS Code':r'typescript.*visual studio code',
              'PyCharm':r'pycharm|jetbrains|user agreement|license agreement|data sharing|import settings',
              'LibreOffice':r'lesson\.odt.*libreoffice',
              'GeoGebra':r'lesson\.ggb',
              'Wireshark':r'lesson\.pcapng'}
    return re.search(expected[name],title) is not None
try:
    time.sleep(2)
    project=args.state.parent/'projects'
    apps=[
        ('VS Code',['code','--disable-gpu','--skip-welcome','--skip-release-notes',str(project/'typescript')]),
        ('PyCharm',['pycharm',str(project/'python')]),
        ('LibreOffice',['libreoffice','--norestore','--writer',str(project/'documents/lesson.odt')]),
        ('GeoGebra',['geogebra',str(project/'documents/lesson.ggb')]),
        ('Wireshark',['wireshark','-r',str(args.state.parent/'lesson.pcapng')]),
    ]
    for name,command in apps:
        key=name.lower().replace(' ','-')
        home=state/key;home.mkdir(exist_ok=True)
        app_env=env.copy()
        app_env.update(HOME=str(home),XDG_CONFIG_HOME=str(home/'config'),XDG_CACHE_HOME=str(home/'cache'),
                       XDG_DATA_HOME=str(home/'data'),XDG_STATE_HOME=str(home/'state'))
        java_tmp=home/'java-tmp';java_tmp.mkdir(exist_ok=True)
        app_env['JAVA_TOOL_OPTIONS']='-Duser.home='+str(home)+' -Djava.io.tmpdir='+str(java_tmp)
        if name=='VS Code':
            settings=home/'code/User';settings.mkdir(parents=True,exist_ok=True)
            (settings/'settings.json').write_text(json.dumps({'security.workspace.trust.enabled':False,'workbench.startupEditor':'none'}))
            command+=['--user-data-dir='+str(home/'code'),'--extensions-dir='+str(home/'extensions')]
        if name=='PyCharm':
            props=home/'pycharm.properties'
            props.write_text('\n'.join(f'idea.{item}.path={home/item}' for item in ['config','system','plugins','log'])+'\n')
            app_env['PYCHARM_PROPERTIES']=str(props)
        if name=='LibreOffice':
            command.insert(1,'-env:UserInstallation='+(home/'lo-profile').as_uri())
            # An earlier stopped test may leave a document lock beside the
            # shared fixture; each GUI launch owns its own editable copy.
            document=home/'lesson.odt'
            shutil.copyfile(project/'documents/lesson.odt',document)
            command[-1]=str(document)
        before=windows()
        log_path=state/(key+'.log')
        with log_path.open('w') as log:
            process=subprocess.Popen(command,env=app_env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            deadline=time.monotonic()+(300 if name=='PyCharm' else 180)
            found={}
            while time.monotonic()<deadline:
                found={k:v for k,v in windows().items() if k not in before and ready_window(name,v)}
                if found:break
                if process.poll() is not None and process.returncode!=0:break
                time.sleep(1)
            if not found:
                print('Observed windows:',windows(),flush=True)
                print(log_path.read_text(errors='replace'),flush=True)
                raise RuntimeError(name+' did not reach its document/project or first-run window.')
            time.sleep(3)
            titles=list(found.values())
            results[name]=dict(Startup='passed',Windows=titles,WindowEvidence='document/project or first-run; splash excluded',
                               InteractiveProjectCheck='pending user')
            print('[PASS] GUI startup:',name,':',titles,flush=True)
        finally:
            try:os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            if process.poll() is None:
                try:process.wait(timeout=20)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
            # Close only windows created on this private test display.
            for identifier in set(windows())-set(before):
                subprocess.run(['wmctrl','-ic',identifier],env=env)
            time.sleep(1)
    (state/'desktop-checks.json').write_text(json.dumps(results,indent=2))
    print('[PF_DESKTOP_STARTUP_VERIFIED] five application windows opened',flush=True)
finally:
    if wm.poll() is None:
        wm.terminate()
        try:wm.wait(timeout=10)
        except subprocess.TimeoutExpired:wm.kill();wm.wait()
    wm_log.close()
