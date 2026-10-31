#!/usr/bin/env python3
"""Verify the source snapshot advertised by a native release, without extracting it."""
import hashlib
import json
from pathlib import Path
import re
import sys
import tarfile


def verify(path, expected_commit):
    if not re.fullmatch(r'[0-9a-f]{40}', expected_commit):
        raise ValueError('expected a full lowercase Git commit ID')
    checksum = Path(str(path) + '.sha256').read_text(encoding='utf-8').split()
    if len(checksum) != 2 or checksum[1].lstrip('*') != path.name:
        raise ValueError('invalid source checksum file')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != checksum[0].lower():
        raise ValueError('source archive checksum mismatch')
    with tarfile.open(path, 'r:gz') as archive:
        names = archive.getnames()
        for required in ('source/SOURCE_MANIFEST.json', 'source/Cargo.toml', 'source/Cargo.lock',
                         'source/.cargo/config.toml', 'source/vendor'):
            if names.count(required) != 1:
                raise ValueError(f'missing or duplicate archive member: {required}')
        manifest = json.load(archive.extractfile('source/SOURCE_MANIFEST.json'))
        if manifest.get('schema_version') != 1 or manifest.get('source_commit') != expected_commit:
            raise ValueError('source archive does not match native release tag')
        if not isinstance(manifest.get('packages'), list):
            raise ValueError('source archive lacks dependency inventory')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: verify_native_source.py ARCHIVE EXPECTED_COMMIT')
    try:
        verify(Path(sys.argv[1]), sys.argv[2])
    except (OSError, ValueError, tarfile.TarError) as exc:
        sys.exit(str(exc))
