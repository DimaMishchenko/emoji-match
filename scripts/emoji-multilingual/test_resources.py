import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('resources.py'))
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)


class ResourceTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='emoji-resource-tests-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        payload = b'offline model fixture'
        (self.source / 'model.bin').write_bytes(payload)
        manifest = dict(schema=1, count=1932, dimensions=384, revision=resources.REVISION,
                        files={'model.bin': self.identity(payload)})
        (self.source / 'multilingual-manifest.json').write_text(json.dumps(manifest))
        self.archive = self.root / 'model.zip'
        self.descriptor = self.root / 'download.json'
        self.value = resources.pack(self.source, self.archive, self.descriptor,
                                    'https://github.com/example/models/releases/download/v1/model.zip')
        self.destination = self.root / 'installed'
        guard = patch.object(resources.urllib.request.OpenerDirector, 'open',
                             side_effect=AssertionError('Network is forbidden'))
        guard.start()
        self.addCleanup(guard.stop)

    @staticmethod
    def identity(data):
        return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

    def rewrite_archive(self, entries):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.archive, 'w') as archive:
                for name, data, mode in entries:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    archive.writestr(info, data)
        self.value.update(self.identity(self.archive.read_bytes()))

    def entries(self):
        with zipfile.ZipFile(self.archive) as archive:
            return [(entry.filename, archive.read(entry), stat.S_IFREG | 0o644)
                    for entry in archive.infolist()]

    def reject(self):
        with self.assertRaises(ValueError):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.root.glob('emoji-model-unpack-*')), [])

    def test_deterministic_pack_and_round_trip(self):
        second = self.root / 'second.zip'
        result = resources.pack(self.source, second, self.root / 'second.json', self.value['url'])
        self.assertEqual(result, self.value)
        self.assertEqual(second.read_bytes(), self.archive.read_bytes())
        resources.unpack(self.archive, self.destination, self.value)
        resources.unpack(self.archive, self.destination, self.value)
        self.assertEqual(resources.inventory(self.destination), resources.inventory(self.source))

    def test_builder_filename_subset_rejects_unicode_controls_and_case_aliases(self):
        for name in ['modèle.bin', 'line\nbreak.bin', 'MODEL.BIN']:
            with self.subTest(name=name):
                files = dict(self.value['files'])
                files[name] = self.identity(b'fixture')
                with self.assertRaises(ValueError):
                    resources.validate_files(files)

    def test_changed_local_resource_preserved(self):
        resources.unpack(self.archive, self.destination, self.value)
        local = self.destination / 'model.bin'
        local.write_bytes(b'user edit')
        with self.assertRaisesRegex(ValueError, 'Local resource changed'):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertEqual(local.read_bytes(), b'user edit')

    def test_unexpected_local_notes_preserved(self):
        resources.unpack(self.archive, self.destination, self.value)
        notes = self.destination / 'local-notes.txt'
        notes.write_text('keep these notes')
        before = (self.destination / 'model.bin').read_bytes()
        with self.assertRaisesRegex(ValueError, 'Unexpected destination entry'):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertEqual(notes.read_text(), 'keep these notes')
        self.assertEqual((self.destination / 'model.bin').read_bytes(), before)
        self.assertEqual(list(self.root.glob('emoji-model-unpack-*')), [])

    def test_unexpected_destination_directory_and_symlinks_preserved(self):
        resources.unpack(self.archive, self.destination, self.value)
        entry = self.destination / 'extra'
        entry.mkdir()
        with self.assertRaisesRegex(ValueError, 'Unexpected destination entry'):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertTrue(entry.is_dir())
        entry.rmdir()
        entry.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlink destination entry'):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertTrue(entry.is_symlink())
        self.assertTrue((self.source / 'model.bin').is_file())
        entry.unlink()
        model = self.destination / 'model.bin'
        model.unlink()
        model.symlink_to(self.source / 'model.bin')
        with self.assertRaisesRegex(ValueError, 'Symlink destination entry'):
            resources.unpack(self.archive, self.destination, self.value)
        self.assertTrue(model.is_symlink())

    def test_archive_size_and_digest_rejected(self):
        for field, value in [('bytes', self.value['bytes'] + 1), ('sha256', '0' * 64)]:
            with self.subTest(field=field):
                original = self.value[field]
                self.value[field] = value
                self.reject()
                self.value[field] = original

    def test_missing_extra_duplicate_and_symlink_entries_rejected(self):
        entries = self.entries()
        variants = [entries[:-1], entries + [('extra', b'extra', stat.S_IFREG)],
                    entries + [entries[0]],
                    [(name, data, stat.S_IFLNK) for name, data, _ in entries]]
        for variant in variants:
            with self.subTest(entries=variant):
                self.rewrite_archive(variant)
                self.reject()

    def test_unsafe_paths_rejected(self):
        for name in ['', '/absolute', '../escape', 'a/../escape', 'a//b', './file',
                     'a\\b', 'a\x00b', 'a/']:
            with self.subTest(name=name):
                self.assertFalse(resources.safe_name(name))
                value = copy.deepcopy(self.value)
                value['files'][name] = self.identity(b'')
                with self.assertRaises(ValueError):
                    resources.validate_descriptor(value)

    def test_entry_size_and_digest_rejected_after_valid_archive_digest(self):
        entries = self.entries()
        for payload in [b'x', b'X' * len(entries[0][1])]:
            self.rewrite_archive([(entries[0][0], payload, stat.S_IFREG)] + entries[1:])
            self.reject()

    def test_manifest_descriptor_disagreement_rejected(self):
        entries = self.entries()
        replacement = []
        for name, data, mode in entries:
            if name == 'multilingual-manifest.json':
                manifest = json.loads(data)
                manifest['files']['model.bin']['sha256'] = '0' * 64
                data = json.dumps(manifest).encode()
                self.value['files'][name] = self.identity(data)
            replacement.append((name, data, mode))
        self.rewrite_archive(replacement)
        self.reject()

    def test_pack_rejects_extra_files_and_symlinks(self):
        extra = self.source / 'extra'
        extra.write_bytes(b'extra')
        with self.assertRaises(ValueError):
            resources.inventory(self.source)
        extra.unlink()
        model = self.source / 'model.bin'
        model.unlink()
        model.symlink_to(self.descriptor)
        with self.assertRaises(ValueError):
            resources.inventory(self.source)

    def test_descriptor_rejected_before_network(self):
        for field, value in [('schema', 2), ('modelRevision', 'wrong'), ('bytes', -1),
                             ('sha256', 'invalid'), ('url', 'https://example.com/model.zip')]:
            with self.subTest(field=field):
                descriptor = dict(self.value, **{field: value})
                self.descriptor.write_text(json.dumps(descriptor))
                with self.assertRaises(ValueError):
                    resources.fetch(self.descriptor, self.destination)

    def test_urls_and_redirects_rejected_offline(self):
        for url in ['http://github.com/file', 'https://example.com/file',
                    'https://github.com.evil.test/file', 'https://user@github.com/file',
                    'https://github.com:444/file']:
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    resources.validate_url(url)
                with self.assertRaises(ValueError):
                    resources.PinnedRedirectHandler().redirect_request(None, None, 302, '', {}, url)

    def fetch_response(self, data, url=None, status=200):
        response = io.BytesIO(data)
        response.url = url or self.value['url']
        response.status = status
        opener = unittest.mock.Mock()
        opener.open.return_value = response
        return patch.object(resources.urllib.request, 'build_opener', return_value=opener)

    def test_fetch_with_in_memory_transport(self):
        with self.fetch_response(self.archive.read_bytes()):
            resources.fetch(self.descriptor, self.destination)
        self.assertEqual(resources.inventory(self.destination), resources.inventory(self.source))

    def test_fetch_rejects_response_host_status_oversize_and_truncation(self):
        data = self.archive.read_bytes()
        for body, url, status in [(data, 'https://evil.test/file', 200), (data, None, 403),
                                  (data + b'extra', None, 200), (data[:-1], None, 200)]:
            with self.subTest(url=url, status=status, size=len(body)):
                with self.fetch_response(body, url, status), self.assertRaises(ValueError):
                    resources.fetch(self.descriptor, self.destination)
                self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
