"""Factory state, verified downloads and workspace ownership (standard library)."""
import contextlib
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.request
import uuid

GIB = 1024**3

def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def digest(path, algorithm='sha256'):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()

def atomic_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name+'.new')
    with temporary.open('w', encoding='utf-8', newline='\n') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)

def download(record, cache):
    """Untrusted partial data is never promoted into the verified input cache."""
    cache = Path(cache); cache.mkdir(parents=True, exist_ok=True)
    name = record['name']
    if Path(name).name != name or name in ('.', '..'):
        raise ValueError('Invalid input filename.')
    target = cache/name
    checks = {k: record[k] for k in ('sha256', 'sha512') if k in record}
    if not checks:
        raise ValueError('Input has no pinned checksum: '+name)
    def valid(path):
        return all(digest(path, kind) == expected.lower() for kind, expected in checks.items())
    if target.exists():
        if not valid(target):
            raise RuntimeError('Existing input checksum mismatch: '+str(target))
        return target
    partial = target.with_name(name+'.partial')
    bundled = os.environ.get('PF_INPUT_CACHE')
    if bundled:
        source = Path(bundled)/name
        if source.exists():
            if not source.is_file() or source.is_symlink() or not valid(source):
                raise RuntimeError('Bundled input checksum/type mismatch: '+name)
            staged=target.with_name(name+'.bundle-'+uuid.uuid4().hex+'.partial')
            try:
                try:os.link(source,staged)
                except OSError:shutil.copyfile(source,staged)
                if not valid(staged):raise RuntimeError('Bundled input copy differs: '+name)
                os.replace(staged,target)
            finally:
                if staged.exists():staged.unlink()
            return target
    if os.environ.get('PF_OFFLINE') == '1':
        raise RuntimeError('Offline pipeline input is missing: '+name)
    with urllib.request.urlopen(record['url'], timeout=120) as response, partial.open('wb') as stream:
        shutil.copyfileobj(response, stream, 4*1024**2)
    if not valid(partial):
        raise RuntimeError('Downloaded input checksum mismatch: '+name)
    os.replace(partial, target)
    print('Verified '+name, flush=True)
    return target

def workspace_path(value, source):
    result = Path(value).resolve(); source = Path(source).resolve()
    if result == source or source in result.parents or result in source.parents:
        raise ValueError('Use a dedicated build workspace outside the source tree.')
    if result == Path(result.anchor) or not result.name:
        raise ValueError('A volume/root directory cannot be a build workspace.')
    if any(part.startswith('\\\\.\\') for part in result.parts):
        raise ValueError('Only ordinary workspace directories are supported.')
    return result

class Workspace:
    def __init__(self, path, source, resume=False):
        self.path = workspace_path(path, source)
        self.path.mkdir(parents=True, exist_ok=True)
        self._lock = None
        state_path=self.path/'factory-state.json'
        if not state_path.exists() and any(p.name not in ('bootstrap','factory.lock') for p in self.path.iterdir()):
            raise RuntimeError('Refusing an unowned, nonempty workspace.')
        if state_path.exists() and not resume:raise RuntimeError('Workspace already initialized; use --resume.')
        self.lock()
        self.state_path = self.path/'factory-state.json'
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text(encoding='utf-8-sig'))
            if self.state.get('schema') != 1 or self.state.get('workspace') != str(self.path):
                self.close()
                raise RuntimeError('Workspace ownership/schema mismatch.')
        else:
            extras = [p for p in self.path.iterdir() if p.name not in ('bootstrap', 'factory.lock')]
            if extras:
                raise RuntimeError('Refusing an unowned, nonempty workspace.')
            self.state = dict(schema=1, build_id=str(uuid.uuid4()), workspace=str(self.path),
                              created=utcnow(), stages={}, source_revisions=[])
            self.save()

    def save(self):
        self.state['updated'] = utcnow()
        atomic_json(self.state_path, self.state)

    def lock(self):
        if self._lock:return self
        self._lock = (self.path/'factory.lock').open('a+b')
        if self._lock.seek(0,2)==0:self._lock.write(b'0');self._lock.flush()
        self._lock.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(self._lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._lock.close(); self._lock = None
            raise RuntimeError('Another factory coordinator owns this workspace.')
        return self

    def close(self):
        if self._lock:
            if os.name == 'nt':
                import msvcrt
                self._lock.seek(0); msvcrt.locking(self._lock.fileno(), msvcrt.LK_UNLCK, 1)
            self._lock.close(); self._lock = None

    def source_snapshot(self, source, refresh=False):
        source = Path(source)
        entries = {p.relative_to(source).as_posix(): digest(p) for p in source.rglob('*')
                   if p.is_file() and p.suffix not in ('.pyc',) and '__pycache__' not in p.parts}
        fingerprint = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
        previous = self.state.get('source_hash')
        if previous and previous != fingerprint and not refresh:
            # Normal resume always uses the original source snapshot.
            if len(previous)!=64 or any(c not in '0123456789abcdef' for c in previous):raise RuntimeError('Invalid source snapshot identity.')
            snapshot=self.path/'sources'/previous
            original=json.loads((snapshot/'factory-source-manifest.json').read_text())
            for name,sha in original.items():
                if Path(name).is_absolute() or '..' in Path(name).parts or digest(snapshot/name)!=sha:
                    raise RuntimeError('Original source snapshot changed.')
            return snapshot
        if previous and previous != fingerprint:
            if self.state['stages'].get('finalize', {}).get('complete'):
                raise RuntimeError('Published builds are immutable; choose a new workspace.')
            for phase in ('inputs-iso', 'seed', 'provision', 'layout', 'assemble', 'direct1', 'ventoy2', 'direct3', 'finalize'):
                self.state['stages'].pop(phase, None)
        destination = self.path/'sources'/fingerprint
        if not destination.exists():
            destination.mkdir(parents=True)
            for name in entries:
                target = destination/name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source/name, target)
            atomic_json(destination/'factory-source-manifest.json', entries)
        for name, sha in entries.items():
            if digest(destination/name) != sha:
                raise RuntimeError('Source snapshot changed: '+name)
        if previous != fingerprint:
            self.state['source_revisions'].append(dict(hash=fingerprint, time=utcnow()))
        self.state['source_hash'] = fingerprint; self.save()
        return destination

    def done(self, name):
        return self.state['stages'].get(name, {}).get('complete', False)

    def complete(self, name, **evidence):
        if evidence.get('complete',True) is not True:raise RuntimeError('An incomplete receipt cannot complete a factory stage.')
        record=dict(evidence);record.update(complete=True,time=utcnow())
        self.state['stages'][name] = record
        if self.state.get('failure',{}).get('stage')==name:self.state.pop('failure')
        self.save()

    def stage(self, name, action):
        if not self.done(name):
            print('\n=== '+name+' ===', flush=True)
            try:
                evidence = action() or {}
                self.complete(name, **evidence)
            except BaseException as exc:
                self.state['failure'] = dict(stage=name, time=utcnow(), error=str(exc)); self.save()
                raise
        return self.state['stages'][name]
