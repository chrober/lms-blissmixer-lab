import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'verify_native_source.py'


class VerifyNativeSourceTests(unittest.TestCase):
    def test_source_commit_and_checksum_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            commit = 'a' * 40
            (source / 'SOURCE_MANIFEST.json').write_text(json.dumps(
                {'schema_version': 1, 'source_commit': commit, 'packages': []}))
            (source / 'Cargo.toml').write_text('fixture')
            (source / 'Cargo.lock').write_text('fixture')
            (source / '.cargo').mkdir()
            (source / '.cargo' / 'config.toml').write_text('fixture')
            (source / 'vendor').mkdir()
            archive = root / 'component-source.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(source, arcname='source')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            Path(str(archive) + '.sha256').write_text(f'{digest}  {archive.name}\n')
            def run(expected):
                return subprocess.run([sys.executable, str(SCRIPT), str(archive), expected],
                                      capture_output=True, text=True)
            self.assertEqual(run(commit).returncode, 0)
            self.assertNotEqual(run('b' * 40).returncode, 0)
            self.assertNotEqual(run('').returncode, 0)
            archive.write_bytes(archive.read_bytes() + b'tampered')
            self.assertNotEqual(run(commit).returncode, 0)

    def test_rejects_archive_without_vendored_cargo_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            commit = 'a' * 40
            (source / 'SOURCE_MANIFEST.json').write_text(json.dumps(
                {'schema_version': 1, 'source_commit': commit, 'packages': []}))
            (source / 'Cargo.toml').write_text('fixture')
            (source / 'Cargo.lock').write_text('fixture')
            archive = root / 'component-source.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(source, arcname='source')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            Path(str(archive) + '.sha256').write_text(f'{digest}  {archive.name}\n')
            result = subprocess.run([sys.executable, str(SCRIPT), str(archive), commit], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
