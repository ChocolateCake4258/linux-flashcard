#!/usr/bin/python3
"""Run the installed development/server/network checks as the ordinary user."""
import argparse
import contextlib
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import sys
import urllib.request

EXAMPLES=Path('/usr/local/share/linux-flashcard/examples/full-suite')
MESSAGE='Привет, LinuxFlashcard!'

def verify(state,recheck):
    state=state.resolve()
    if not recheck and state.exists() and any(state.iterdir()):
        raise RuntimeError('Choose a NEW empty check directory, or --recheck an existing check.')
    state.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy()
    for key,directory in {'HOME':'home','XDG_CACHE_HOME':'cache','XDG_CONFIG_HOME':'config',
                          'XDG_DATA_HOME':'data','XDG_STATE_HOME':'state','DOTNET_CLI_HOME':'dotnet-home',
                          'CARGO_HOME':'cargo-home','GOPATH':'gopath','GOCACHE':'go-cache'}.items():
        target=state/directory;target.mkdir(exist_ok=True);env[key]=str(target)
    env.update(LC_ALL='C.UTF-8',DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
               DOTNET_NOLOGO='1',DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='1',
               GOTOOLCHAIN='local',CARGO_NET_OFFLINE='true')
    results={}
    def run(*args,cwd=state,timeout=300,input=None):
        result=subprocess.run(args,cwd=cwd,env=env,input=input,text=True,
                              stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
        if result.stdout:print(result.stdout,end='',flush=True)
        result.check_returncode()
        return result.stdout
    def passed(name):
        results[name]='passed';print('[PASS]',name,flush=True)
    profile=json.loads(Path('/usr/local/share/linux-flashcard/full-suite-runtime.json').read_text())
    suffix=hashlib.sha256(str(state).encode()).hexdigest()[:10]
    database=f'pf_check_{os.geteuid()}_{suffix}'
    volume=f'pf-full-check-{os.geteuid()}-{suffix}'
    pg_ready=subprocess.run(['pg_isready','-q'],env=env).returncode==0
    docker_ready=subprocess.run(['docker','info'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    if not (pg_ready and docker_ready):
        if not sys.stdin.isatty():
            raise RuntimeError('Preparation must start PostgreSQL and Docker before an unattended check.')
        clusters=subprocess.check_output(['pg_lsclusters','--no-header'],text=True).splitlines()
        if len(clusters)!=1:raise RuntimeError('Expected one prepared PostgreSQL cluster.')
        fields=clusters[0].split()
        subprocess.run(['sudo','systemctl','start','docker.service',f'postgresql@{fields[0]}-{fields[1]}.service'],check=True)
    project=state/'projects'
    if not recheck:
        if project.exists():raise RuntimeError('Existing check project tree; use --recheck or a new state directory.')
        shutil.copytree(EXAMPLES,project)
        run('dotnet','restore','Lesson.csproj','--configfile','NuGet.Config',cwd=project/'csharp')
        run('dotnet','build','Lesson.csproj','--no-restore','--configuration','Release',cwd=project/'csharp',timeout=600)
        run('dotnet',str(project/'csharp/bin/Release/net10.0/Lesson.dll'),cwd=project/'csharp')
        assert (project/'csharp/result.txt').read_text()==f'C#: 42\n{MESSAGE}\n'
        passed('C# build/run offline')
        run('go','build','-o','lesson','.',cwd=project/'go',timeout=600)
        run(str(project/'go/lesson'),cwd=project/'go')
        assert (project/'go/result.txt').read_text()==f'Go: 42\n{MESSAGE}\n'
        passed('Go build/run')
        run('cargo','build','--offline',cwd=project/'rust',timeout=600)
        run(str(project/'rust/target/debug/linux-flashcard-lesson'),cwd=project/'rust')
        assert (project/'rust/result.txt').read_text()==f'Rust: 42\n{MESSAGE}\n'
        passed('Rust/Cargo build/run offline')
        run('tsc','--project','tsconfig.json',cwd=project/'typescript')
        run('node','build/hello.js',cwd=project/'typescript')
        assert (project/'typescript/result.txt').read_text()==f'TypeScript: 42\n{MESSAGE}\n'
        passed('Node.js/TypeScript compile/run')
        with sqlite3.connect(state/'lesson.sqlite3') as db:
            db.executescript((project/'database/lesson.sql').read_text())
        run('createdb',database)
        run('psql','-X','-v','ON_ERROR_STOP=1','-d',database,'-c',
            "CREATE TABLE lesson(id integer PRIMARY KEY,message text NOT NULL); "
            "INSERT INTO lesson VALUES(1,'Привет, LinuxFlashcard!');")
        run('pg_dump','--file',str(state/'lesson-postgresql.sql'),database)
        passed('PostgreSQL create/write/dump')
        assert 'Hello from Docker!' in run('docker','run','--rm','--pull=never',profile['hello_world'])
        run('docker','volume','create','--label','io.linuxflashcard.owner=full-suite-check',volume)
        run('docker','run','--rm','--pull=never','-v',volume+':/data','-e','PF_VALUE='+MESSAGE,
            profile['busybox'],'sh','-c','printf "%s" "$PF_VALUE" > /data/result.txt')
        passed('Docker container and persistent volume')
        office=state/'office-output';office.mkdir()
        lo_profile=(state/'libreoffice-profile').as_uri()
        run('libreoffice','-env:UserInstallation='+lo_profile,'--headless','--convert-to','pdf',
            '--outdir',str(office),str(project/'documents/lesson.odt'),timeout=300)
        run('libreoffice','-env:UserInstallation='+lo_profile,'--headless','--convert-to','csv',
            '--outdir',str(office),str(project/'documents/lesson.ods'),timeout=300)
        assert (office/'lesson.pdf').read_bytes().startswith(b'%PDF')
        assert all(number in (office/'lesson.csv').read_text() for number in ['19','23','42'])
        passed('LibreOffice Writer/Calc read/export')
        # Capture only this guest's loopback traffic, using its actual dumpcap rights.
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self,*args):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(project)))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        capture=state/'lesson.pcapng'
        process=subprocess.Popen(['dumpcap','-i','lo','-a','duration:5','-w',str(capture)],env=env,
                                 stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:
            time.sleep(1)
            for _ in range(3):
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                    f'http://127.0.0.1:{server.server_port}/',timeout=10) as response:response.read()
            output,_=process.communicate(timeout=20)
            print(output,end='',flush=True)
            if process.returncode:raise RuntimeError('dumpcap live capture failed.')
        finally:
            server.shutdown();server.server_close()
            if process.poll() is None:process.terminate();process.wait(timeout=10)
        count=run('tshark','-r',str(capture),'-T','fields','-e','frame.number')
        assert any(line.isdigit() for line in count.splitlines())
        passed('Wireshark/dumpcap live pcap capture and tshark read')
        for command in ['pf-verify-cli','pf-verify-python','pf-verify-java']:
            run(command,timeout=600)
            passed(command)
        (state/'checks-created.json').write_text(json.dumps(results,indent=2))
    else:
        assert (state/'checks-created.json').is_file()
        run('dotnet',str(project/'csharp/bin/Release/net10.0/Lesson.dll'),cwd=project/'csharp')
        run(str(project/'go/lesson'),cwd=project/'go')
        run(str(project/'rust/target/debug/linux-flashcard-lesson'),cwd=project/'rust')
        run('node','build/hello.js',cwd=project/'typescript')
        for language,prefix in [('csharp','C#'),('go','Go'),('rust','Rust'),('typescript','TypeScript')]:
            assert (project/language/'result.txt').read_text()==f'{prefix}: 42\n{MESSAGE}\n'
        passed('Compiled language projects after restart')
    with sqlite3.connect(state/'lesson.sqlite3') as db:
        assert db.execute('SELECT message FROM lesson WHERE id=1').fetchone()[0]==MESSAGE
    passed('SQLite persistent data')
    assert run('psql','-X','-At','-d',database,'-c','SELECT message FROM lesson WHERE id=1;').strip()==MESSAGE
    passed('PostgreSQL persistent data')
    assert run('docker','run','--rm','--pull=never','-v',volume+':/data',profile['busybox'],
               'cat','/data/result.txt').strip()==MESSAGE
    passed('Docker volume data')
    (state/('checks-rechecked.json' if recheck else 'checks-complete.json')).write_text(json.dumps(results,indent=2))
    print('[PF_FULL_SUITE_VERIFIED] checks passed as uid='+str(os.geteuid()),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state',type=Path)
    parser.add_argument('--recheck',action='store_true')
    args=parser.parse_args()
    if os.geteuid()==0:raise SystemExit('Run as the ordinary Linux user, without sudo.')
    if args.recheck and not args.state:raise SystemExit('--recheck requires --state.')
    if args.state:
        verify(args.state,args.recheck)
    else:
        raise SystemExit('For the persistent full check, use pf-verify-all --state ~/full-suite-check (a NEW directory).')
