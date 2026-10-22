"""Verified retirement and recoverable fixed-VHD -> RAW publication, without copying."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct

from common import atomic_json, utcnow

RETIRE = {'seed': ('iso-files', 'seed-files'),
          'assemble': ('working/linux.img.vtoy', 'working/linux.img.vtoy.uefi-vars.fd')}


def storage_usage(workspace):
    """Stage-boundary data footprint; exclude the mounted view and deduplicate hard links."""
    seen=set();total=0;count=0
    for path in Path(workspace).iterdir():
        if path.name=='mount':continue
        items=path.rglob('*') if path.is_dir() else (path,)
        for item in items:
            if item.is_file() and not item.is_symlink():
                info=item.stat();identity=(info.st_dev,info.st_ino)
                if identity not in seen:
                    seen.add(identity);total+=info.st_size;count+=1
    return dict(unique_file_bytes=total,files=count,time=utcnow())


def regular(path):
    path = Path(path)
    if path.is_symlink() or getattr(path.lstat(), 'st_file_attributes', 0) & 0x400:
        raise RuntimeError('Redirected factory storage is not supported: ' + str(path))
    return path


def retire(workspace, stage):
    """Only known factory-owned intermediates, after a durable successor receipt."""
    if not workspace.done(stage):
        raise RuntimeError('Cannot retire before successor stage is complete.')
    retired = workspace.state.setdefault('retired_artifacts', {})
    for name in RETIRE.get(stage, ()):
        path = workspace.path / name
        parent = path.parent
        while parent != workspace.path:
            if parent.exists():regular(parent)
            parent = parent.parent
        if not path.exists():
            continue
        regular(path)
        items = [path, *path.rglob('*')] if path.is_dir() else [path]
        for item in items:
            regular(item)
        record = dict(stage=stage, bytes=sum(p.stat().st_size for p in items if p.is_file()),
                      status='pending', time=utcnow())
        retired[name] = record; workspace.save()
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        record.update(status='removed', time=utcnow()); workspace.save()
        print('Retired verified intermediate: ' + name, flush=True)


def fixed_footer(footer, disk_bytes):
    if len(footer) != 512 or footer[:8] != b'conectix':
        raise RuntimeError('Missing fixed VHD footer.')
    if (struct.unpack_from('>I', footer, 12)[0] != 0x10000 or
            struct.unpack_from('>Q', footer, 16)[0] != 0xffffffffffffffff or
            struct.unpack_from('>I', footer, 60)[0] != 2 or footer[84] != 0):
        raise RuntimeError('Only an unsaved fixed VHD can be published in place.')
    if any(struct.unpack_from('>Q', footer, offset)[0] != disk_bytes for offset in (40, 48)):
        raise RuntimeError('Fixed VHD capacity differs from its owned layout.')
    clean = bytearray(footer); clean[64:68] = b'\0' * 4
    if struct.unpack_from('>I', footer, 64)[0] != (~sum(clean) & 0xffffffff):
        raise RuntimeError('Fixed VHD footer checksum mismatch.')


def region_sha(path, size):
    sha = hashlib.sha256()
    with Path(path).open('rb') as stream:
        remaining = size
        while remaining:
            block = stream.read(min(4 * 1024**2, remaining))
            if not block:
                raise RuntimeError('Unexpected end of fixed disk data.')
            sha.update(block); remaining -= len(block)
    return sha.hexdigest()


def publish_fixed_vhd(layout, output, disk_bytes, build_id, source_hash, validate, _checkpoint=None):
    """Fixed VHD data is RAW at offset zero; only its verified 512-byte footer is removed.

    The saved intent/footer permits restart after rename, truncation or publication.
    Hashes and GPT are checked both before conversion and before public success.
    """
    layout = Path(layout); output = Path(output)
    regular(layout.parent); regular(output.parent)
    partial = output.with_suffix('.partial')
    receipt = output.parent / 'compact-publication.json'
    publication = output.parent / 'publication.json'
    expected = dict(schema=1, method='fixed-vhd-inplace', layout=str(layout), image=str(output),
                    bytes=disk_bytes, build_id=build_id, source_hash=source_hash)
    def checkpoint(name):
        if _checkpoint:
            _checkpoint(name)
    if receipt.exists():
        plan = json.loads(receipt.read_text())
        if any(plan.get(k) != v for k, v in expected.items()):
            raise RuntimeError('Compact publication identity mismatch.')
        footer = base64.b64decode(plan['footer'], validate=True)
        fixed_footer(footer, disk_bytes)
        if len(plan.get('sha256', '')) != 64 or any(c not in '0123456789abcdef' for c in plan['sha256']):
            raise RuntimeError('Invalid compact publication hash.')
    else:
        if not layout.is_file() or partial.exists() or output.exists() or publication.exists():
            raise RuntimeError('Unowned compact publication files; preserve before retrying.')
        regular(layout)
        if layout.stat().st_size != disk_bytes + 512:
            raise RuntimeError('Unexpected fixed VHD file length.')
        with layout.open('rb') as stream:
            stream.seek(disk_bytes); footer = stream.read(512)
        fixed_footer(footer, disk_bytes)
        validate(layout, disk_bytes)
        plan = dict(expected, footer=base64.b64encode(footer).decode('ascii'),
                    sha256=region_sha(layout, disk_bytes), prepared=utcnow())
        atomic_json(receipt, plan)
    result = dict(complete=True, build_id=build_id, image=str(output), bytes=disk_bytes,
                  sha256=plan['sha256'], source_hash=source_hash, first_password_pending=True,
                  publication_method='verified-fixed-vhd-inplace')
    if publication.exists() and json.loads(publication.read_text()) != result:
        raise RuntimeError('Publication intent differs from compact receipt.')
    atomic_json(publication, result)
    checkpoint('prepared')
    present = [p for p in (layout, partial, output) if p.exists()]
    if len(present) != 1:
        raise RuntimeError('Ambiguous compact publication files; no file was overwritten.')
    current = regular(present[0])
    if current == layout:
        if current.stat().st_size != disk_bytes + 512:
            raise RuntimeError('Owned fixed layout length changed.')
        with current.open('rb') as stream:
            stream.seek(disk_bytes)
            if stream.read(512) != footer:
                raise RuntimeError('Owned fixed layout footer changed.')
        if region_sha(current, disk_bytes) != plan['sha256']:
            raise RuntimeError('Fixed layout changed after publication was prepared.')
        current.rename(partial); current = partial
        checkpoint('renamed')
    if current == partial:
        size = current.stat().st_size
        if size == disk_bytes + 512:
            with current.open('rb') as stream:
                stream.seek(disk_bytes)
                if stream.read(512) != footer:
                    raise RuntimeError('Partial fixed footer changed.')
            if region_sha(current, disk_bytes) != plan['sha256']:
                raise RuntimeError('Partial fixed disk data changed.')
            with current.open('r+b') as stream:
                stream.truncate(disk_bytes); stream.flush(); os.fsync(stream.fileno())
            checkpoint('truncated')
        elif size != disk_bytes:
            raise RuntimeError('Partial disk has an unexpected length.')
        validate(current, disk_bytes)
        if region_sha(current, disk_bytes) != plan['sha256']:
            raise RuntimeError('Compact RAW differs from verified disk data.')
        current.rename(output)
        checkpoint('published')
    if output.stat().st_size != disk_bytes or region_sha(output, disk_bytes) != plan['sha256']:
        raise RuntimeError('Published compact RAW differs from its verified receipt.')
    validate(output, disk_bytes)
    return result
