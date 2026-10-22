#!/usr/bin/env python3
"""Create and verify a deterministic, source-only LinuxFlashcard release ZIP."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile

sys.dont_write_bytecode = True
DEFAULT_SOURCE = Path(__file__).resolve().parents[1]
REQUIRED = ('README.md', 'ИНСТРУКЦИЯ.md', 'win/build-all.bat', 'win/build-all.ps1',
            'win/build-debian.ps1', 'win/factory/build.py', 'win/lib/pf-tools.psm1',
            'win/backup-system.ps1', 'win/lib/portable-backup.ps1')
EXCLUDED_DIRECTORIES = {'.git', '__pycache__', '.cache', '.pytest_cache', '.venv', '_reserve'}
ARTIFACT_SUFFIXES = {'.raw', '.img', '.vtoy', '.vhd', '.vhdx', '.qcow2', '.iso',
                     '.exe', '.dll', '.zip', '.7z', '.log', '.pyc', '.partial'}
MAX_SOURCE_BYTES = 16 * 1024**2


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')


def safe_path(name):
    if not isinstance(name, str) or not name or any(c in name for c in '\\:\0'):
        raise ValueError('Unsafe source archive path.')
    parts = name.split('/')
    if PurePosixPath(name).is_absolute() or any(p in ('', '.', '..') for p in parts):
        raise ValueError('Unsafe source archive path.')
    for part in parts:
        if part.endswith((' ', '.')) or re.search(r'[<>"|?*\x00-\x1f]', part):
            raise ValueError('Unsafe Windows source path.')
        if re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', part, re.I):
            raise ValueError('Reserved Windows source path.')


def valid_version(version):
    if not isinstance(version, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,60}', version):
        raise ValueError('Use an ASCII release version containing letters, digits, dot, dash or underscore.')
    return version


def source_files(source):
    files = []
    pending = [source]
    while pending:
        directory = pending.pop()
        for path in directory.iterdir():
            if path.name in EXCLUDED_DIRECTORIES:
                continue
            if path.is_symlink() or getattr(path.lstat(), 'st_file_attributes', 0) & 0x400:
                raise ValueError('Source symlinks are not distributed: ' + str(path))
            if path.is_dir():
                pending.append(path)
                continue
            if not path.is_file():
                raise ValueError('Source contains a non-regular file.')
            name = path.relative_to(source).as_posix()
            safe_path(name)
            if path.suffix.lower() in ARTIFACT_SUFFIXES or path.stat().st_size > MAX_SOURCE_BYTES:
                raise ValueError('Move build artifacts outside source before packaging: ' + name)
            files.append((name, path))
    names = [name for name, _ in files]
    if len({name.casefold() for name in names}) != len(names):
        raise ValueError('Case-insensitive source filename collision.')
    if any(name not in names for name in REQUIRED):
        raise ValueError('Source tree is missing required entrypoints.')
    return sorted(files)


def verify_release(archive):
    with zipfile.ZipFile(archive) as stream:
        infos = stream.infolist()
        names = [item.filename for item in infos]
        if any(info.is_dir() or ((info.external_attr >> 16) & 0o170000) not in (0, stat.S_IFREG) for info in infos):
            raise ValueError('Non-regular release entry.')
        for name in names:
            safe_path(name)
        if len({n.casefold() for n in names}) != len(names):
            raise ValueError('Duplicate release entry.')
        manifests = [n for n in names if n.endswith('/RELEASE-MANIFEST.json')]
        if len(manifests) != 1 or stream.getinfo(manifests[0]).file_size > MAX_SOURCE_BYTES:
            raise ValueError('Missing or oversized release manifest.')
        manifest = json.loads(stream.read(manifests[0]))
        if manifest.get('schema') != 1 or manifest.get('format') != 'LinuxFlashcardSourceRelease':
            raise ValueError('Unsupported release manifest.')
        prefix = 'linux-flashcard-' + valid_version(manifest['version']) + '/'
        if manifests[0] != prefix + 'RELEASE-MANIFEST.json':
            raise ValueError('Release identity mismatch.')
        expected = {prefix + 'RELEASE-MANIFEST.json'}
        for record in manifest['files']:
            safe_path(record['path'])
            name = prefix + record['path']
            if name in expected:
                raise ValueError('Duplicate manifest path.')
            expected.add(name)
            info = stream.getinfo(name)
            if not 0 <= info.file_size <= MAX_SOURCE_BYTES or info.file_size != record['bytes']:
                raise ValueError('Release entry length mismatch.')
            if sha256(stream.read(name)) != record['sha256']:
                raise ValueError('Release entry SHA256 mismatch: ' + record['path'])
        if expected != set(names) or any(prefix + name not in expected for name in REQUIRED):
            raise ValueError('Missing or unlisted release entries.')
        return manifest


def build_release(source, output, version):
    source = Path(source).resolve()
    output = Path(output).resolve()
    version = valid_version(version)
    if output == source or source in output.parents:
        raise ValueError('Keep release output outside the source tree.')
    files = source_files(source)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ('linux-flashcard-' + version + '-source.zip')
    partial = archive.with_suffix('.zip.partial')
    sidecar = Path(str(archive) + '.sha256')
    receipt = output / 'release.json'
    if any(p.exists() for p in (archive, partial, sidecar, receipt)):
        raise ValueError('Release output exists; choose a new output directory.')
    records = []
    prefix = 'linux-flashcard-' + version + '/'

    def write(stream, name, data, mode=0o644):
        info = zipfile.ZipInfo(prefix + name, date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        stream.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

    with zipfile.ZipFile(partial, 'x', allowZip64=True) as stream:
        for name, path in files:
            data = path.read_bytes()
            records.append(dict(path=name, bytes=len(data), sha256=sha256(data)))
            write(stream, name, data, 0o755 if path.suffix in ('.sh', '.py') else 0o644)
        manifest = dict(schema=1, format='LinuxFlashcardSourceRelease', version=version, files=records)
        write(stream, 'RELEASE-MANIFEST.json', json_bytes(manifest))
    verify_release(partial)
    digest = sha256(partial.read_bytes())
    partial.rename(archive)
    sidecar.write_text(digest + '  ' + archive.name + '\n', encoding='ascii')
    result = dict(complete=True, version=version, archive=archive.name, sha256=digest,
                  source_files=len(records), archive_bytes=archive.stat().st_size,
                  source_manifest_sha256=sha256(json_bytes(manifest)))
    receipt.write_bytes(json_bytes(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.verify:
        result = verify_release(args.verify)
        print(json.dumps(dict(complete=True, version=result['version'], files=len(result['files']))))
    else:
        if not args.output or not args.version:
            parser.error('--output and --version are required when packaging')
        print(json.dumps(build_release(args.source, args.output, args.version), indent=2))


if __name__ == '__main__':
    main()
