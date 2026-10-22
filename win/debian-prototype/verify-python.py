#!/usr/bin/python3
"""Exercise Python, offline pip/venv and an authenticated local notebook server."""
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check(work):
    project = work / 'project'
    shutil.copytree('/usr/local/share/linux-flashcard/examples/python', project)
    env = os.environ.copy()
    for key, directory in {
        'HOME': 'home', 'XDG_CACHE_HOME': 'cache', 'XDG_CONFIG_HOME': 'config',
        'XDG_DATA_HOME': 'data', 'XDG_STATE_HOME': 'state',
        'JUPYTER_CONFIG_DIR': 'jupyter-config', 'JUPYTER_DATA_DIR': 'jupyter-data',
        'JUPYTER_RUNTIME_DIR': 'jupyter-runtime',
    }.items():
        target = work / directory
        target.mkdir(mode=0o700)
        env[key] = str(target)
    env.update(LC_ALL='C.UTF-8', PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1',
               PIP_CONFIG_FILE=os.devnull, PIP_NO_INDEX='1',
               PIP_DISABLE_PIP_VERSION_CHECK='1', PIP_REQUIRE_VIRTUALENV='1')

    def run(*args, timeout=180):
        result = subprocess.run(args, cwd=project, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=timeout)
        if result.stdout:
            print(result.stdout, end='', flush=True)
        result.check_returncode()
        return result.stdout

    venv = project / '.venv'
    run('/usr/bin/python3', '-m', 'venv', '--system-site-packages', str(venv))
    python = str(venv / 'bin/python')
    env['VIRTUAL_ENV'] = str(venv)
    env['PATH'] = str(venv / 'bin') + os.pathsep + env.get('PATH', '/usr/local/bin:/usr/bin:/bin')
    run(python, '-m', 'pip', '--version')
    run(python, '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-build-isolation',
        str(project / 'demo-package'))
    run(python, '-c',
        'import sys, pathlib, pf_lesson_demo; '
        'assert sys.prefix != sys.base_prefix; '
        'assert pathlib.Path(pf_lesson_demo.__file__).is_relative_to(pathlib.Path(sys.prefix)); '
        'assert pf_lesson_demo.add(19, 23) == 42; '
        'print("[PASS] Real venv and offline pip package in project site-packages")')
    assert run(python, 'hello.py').strip() == 'Hello from Python: 42'

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    token = secrets.token_urlsafe(32)
    env['JUPYTER_TOKEN'] = token
    base = f'http://127.0.0.1:{port}'

    def api(path, data=None, method=None):
        headers = {'Authorization': 'token ' + token, 'Accept': 'application/json'}
        if data is not None:
            data = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=10) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    log_path = work / 'jupyter.log'
    with log_path.open('w') as log:
        server = subprocess.Popen(['/usr/local/bin/pf-jupyter', '--no-browser',
                                   f'--port={port}', '--port-retries=0'],
                                  cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT,
                                  start_new_session=True)
    try:
        deadline = time.monotonic() + 180
        while True:
            if server.poll() is not None:
                raise RuntimeError('Jupyter exited before its HTTP API was ready.')
            try:
                status, contents = api('/api/contents')
                assert status == 200 and contents['type'] == 'directory'
                break
            except (urllib.error.URLError, TimeoutError, ConnectionResetError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Timed out waiting for the local Jupyter API.')
                time.sleep(0.5)

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        try:
            opener.open(base + '/api/contents', timeout=10).close()
        except urllib.error.HTTPError as error:
            assert error.code in (302, 401, 403), error.code
        else:
            raise RuntimeError('Jupyter unexpectedly allowed an unauthenticated contents request.')
        print('[PASS] Authenticated local Jupyter API; unauthenticated access rejected', flush=True)

        status, session = api('/api/sessions', {
            'kernel': {'name': 'pf-python'}, 'name': 'lesson.ipynb',
            'path': 'lesson.ipynb', 'type': 'notebook',
        })
        assert status == 201 and session['kernel']['name'] == 'pf-python'
        assert api('/api/sessions/' + session['id'], method='DELETE')[0] == 204
        print('[PASS] Jupyter HTTP API started the private project kernel', flush=True)

        run(python, '-m', 'nbconvert', '--to', 'notebook', '--execute', 'lesson.ipynb',
            '--output', 'executed.ipynb', '--ExecutePreprocessor.timeout=180',
            '--ExecutePreprocessor.kernel_name=pf-python', timeout=240)
        notebook = json.loads((project / 'executed.ipynb').read_text(encoding='utf-8'))
        cells = [cell for cell in notebook['cells'] if cell['cell_type'] == 'code']
        assert [cell['execution_count'] for cell in cells] == [1, 2]
        assert all(output['output_type'] != 'error' for cell in cells for output in cell['outputs'])
        assert any(''.join(output.get('data', {}).get('text/plain', '')) == '42'
                   for cell in cells for output in cell['outputs'])
        expected = 'Python / Jupyter: 42\nПривет, LinuxFlashcard!\n'
        assert (project / 'result.txt').read_text(encoding='utf-8') == expected
        run(python, '-m', 'nbconvert', '--to', 'html', 'executed.ipynb', '--output', 'executed.html')
        assert 'Python / Jupyter: 42' in (project / 'executed.html').read_text(encoding='utf-8')
        status, saved = api('/api/contents/executed.ipynb')
        assert status == 200 and saved['content']['cells'][1]['execution_count'] == 1
        print('[PASS] Notebook executed in venv; Unicode result, saved outputs and HTML verified', flush=True)

        assert api('/api/shutdown', data={})[0] == 200
        assert server.wait(timeout=30) == 0
        assert json.loads((project / 'executed.ipynb').read_text(encoding='utf-8')) == notebook
        assert (project / 'result.txt').read_text(encoding='utf-8') == expected
        print('[PASS] Saved notebook and result remain intact after normal server shutdown', flush=True)
    except BaseException:
        print(log_path.read_text(encoding='utf-8', errors='replace').replace(token, '<test-token>'), flush=True)
        raise
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
    print(f'[PF_PYTHON_VERIFIED] Python, pip/venv, Jupyter kernel/notebook/HTML work as uid={os.geteuid()}', flush=True)


if __name__ == '__main__':
    if os.geteuid() == 0:
        raise SystemExit('Run as an ordinary Linux user, without sudo.')
    with tempfile.TemporaryDirectory(prefix='pf-python-check-', dir='/tmp') as temporary:
        check(Path(temporary))
