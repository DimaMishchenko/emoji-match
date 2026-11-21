import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'apps/EmojiMatch/ModelResources/Multilingual'
DESCRIPTOR = ROOT / 'apps/EmojiMatch/Resources/multilingual-download.json'
REVISION = '614241f622f53c4eeff9890bdc4f31cfecc418b3'
HOSTS = {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def safe_name(name):
    if not isinstance(name, str) or not name or not all(32 <= ord(character) < 127 for character in name):
        return False
    path = PurePosixPath(name)
    return not path.is_absolute() and '\\' not in name and '\x00' not in name and all(
        part not in {'', '.', '..'} for part in name.split('/'))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_url(url):
    parsed = urlsplit(url)
    require(parsed.scheme == 'https' and parsed.hostname in HOSTS
            and parsed.username is None and parsed.password is None
            and parsed.port in (None, 443), 'Untrusted model URL')


def validate_files(files):
    require(isinstance(files, dict) and 0 < len(files) <= 128, 'Invalid file inventory')
    require(len({name.lower() for name in files}) == len(files), 'Case-alias resource paths')
    for name, identity in files.items():
        require(safe_name(name), f'Unsafe resource path: {name}')
        require(isinstance(identity, dict)
                and type(identity.get('bytes')) is int and 0 <= identity['bytes'] <= 1_073_741_824
                and isinstance(identity.get('sha256'), str)
                and re.fullmatch('[0-9a-f]{64}', identity['sha256']), f'Invalid identity: {name}')


def validate_descriptor(value):
    require(value['schema'] == 1 and value['modelRevision'] == REVISION, 'Invalid descriptor version')
    validate_url(value['url'])
    validate_files(value['files'])
    require('multilingual-manifest.json' in value['files'], 'Missing manifest identity')
    require(type(value['bytes']) is int and 0 < value['bytes'] <= 1_073_741_824
            and isinstance(value['sha256'], str)
            and re.fullmatch('[0-9a-f]{64}', value['sha256']), 'Invalid archive identity')


def inventory(source):
    require(source.is_dir() and not source.is_symlink(), 'Invalid resource directory')
    manifest_path = source / 'multilingual-manifest.json'
    require(manifest_path.is_file() and not manifest_path.is_symlink(), 'Invalid manifest')
    manifest = json.loads(manifest_path.read_text())
    require(manifest['schema'] == 1 and manifest['count'] == 1932 and manifest['dimensions'] == 384
            and manifest['revision'] == REVISION, 'Invalid manifest contract')
    files = dict(manifest['files'])
    require(manifest_path.name not in files, 'Manifest cannot inventory itself')
    files[manifest_path.name] = {'sha256': digest(manifest_path), 'bytes': manifest_path.stat().st_size}
    validate_files(files)
    actual = set()
    for path in source.rglob('*'):
        require(not path.is_symlink(), f'Symlink resource: {path.relative_to(source)}')
        if not path.is_dir():
            require(path.is_file(), f'Nonregular resource: {path}')
            actual.add(path.relative_to(source).as_posix())
    require(actual == set(files), 'Resource inventory mismatch')
    for name, expected in files.items():
        path = source / name
        require(path.is_file() and path.stat().st_size == expected['bytes']
                and digest(path) == expected['sha256'], f'Resource identity mismatch: {name}')
    return manifest['revision'], files


def pack(source, output, descriptor, url):
    revision, files = inventory(source)
    validate_url(url)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='emoji-model-pack-') as scratch:
        temporary = Path(scratch) / 'model.zip'
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for name in sorted(files):
                info = zipfile.ZipInfo(name, date_time=(2024, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                with (source / name).open('rb') as incoming, archive.open(info, 'w', force_zip64=True) as outgoing:
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
        value = dict(schema=1, url=url, sha256=digest(temporary), bytes=temporary.stat().st_size,
                     modelRevision=revision, files=files)
        validate_descriptor(value)
        shutil.copyfile(temporary, output)
        descriptor.parent.mkdir(parents=True, exist_ok=True)
        descriptor.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
        return value


def unpack(archive_path, destination, descriptor):
    validate_descriptor(descriptor)
    require(archive_path.stat().st_size == descriptor['bytes'], 'Archive size mismatch')
    require(digest(archive_path) == descriptor['sha256'], 'Archive digest mismatch')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='emoji-model-unpack-', dir=destination.parent) as scratch:
        stage = Path(scratch) / 'model'
        stage.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)) and set(names) == set(descriptor['files']),
                    'Archive inventory mismatch')
            for entry in archive.infolist():
                name = entry.filename
                mode = stat.S_IFMT(entry.external_attr >> 16)
                require(safe_name(name) and mode in (0, stat.S_IFREG), f'Unsafe archive entry: {name}')
                expected = descriptor['files'][name]
                require(entry.file_size == expected['bytes'], f'Entry size mismatch: {name}')
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                count = 0
                result = hashlib.sha256()
                with archive.open(entry) as incoming, path.open('wb') as outgoing:
                    for chunk in iter(lambda: incoming.read(1024 * 1024), b''):
                        count += len(chunk)
                        require(count <= expected['bytes'], f'Entry exceeds pinned size: {name}')
                        result.update(chunk)
                        outgoing.write(chunk)
                require(count == expected['bytes'] and result.hexdigest() == expected['sha256'],
                        f'Entry digest mismatch: {name}')
        revision, files = inventory(stage)
        require(revision == descriptor['modelRevision'] and files == descriptor['files'],
                'Manifest and descriptor disagree')
        if destination.exists() or destination.is_symlink():
            require(destination.is_dir() and not destination.is_symlink(), 'Invalid destination')
            directories = {parent.as_posix() for name in descriptor['files']
                           for parent in PurePosixPath(name).parents if parent != PurePosixPath('.')}
            for existing in destination.rglob('*'):
                name = existing.relative_to(destination).as_posix()
                require(not existing.is_symlink(), f'Symlink destination entry: {name}')
                require((existing.is_dir() and name in directories)
                        or (existing.is_file() and name in descriptor['files']),
                        f'Unexpected destination entry: {name}')
            for name, expected in descriptor['files'].items():
                existing = destination / name
                require(not any((destination / parent).is_symlink() for parent in PurePosixPath(name).parents),
                        f'Symlink destination parent: {name}')
                if existing.exists() or existing.is_symlink():
                    require(existing.is_file() and not existing.is_symlink()
                            and digest(existing) == expected['sha256'], f'Local resource changed: {name}')
            previous = Path(scratch) / 'previous'
            destination.rename(previous)
            try:
                stage.rename(destination)
            except BaseException:
                previous.rename(destination)
                raise
        else:
            stage.rename(destination)


class PinnedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        validate_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def fetch(descriptor_path, destination):
    value = json.loads(descriptor_path.read_text())
    validate_descriptor(value)
    with tempfile.TemporaryDirectory(prefix='emoji-model-fetch-') as scratch:
        temporary = Path(scratch) / 'model.zip'
        request = urllib.request.Request(value['url'], headers={'Accept': 'application/octet-stream'})
        opener = urllib.request.build_opener(PinnedRedirectHandler())
        with opener.open(request, timeout=60) as response, temporary.open('wb') as outgoing:
            validate_url(response.url)
            require(response.status == 200, 'Unexpected download status')
            count = 0
            for chunk in iter(lambda: response.read(1024 * 1024), b''):
                count += len(chunk)
                require(count <= value['bytes'], 'Download exceeds pinned size')
                outgoing.write(chunk)
        unpack(temporary, destination, value)
    print(f'Installed pinned multilingual resources at {destination}')


def main():
    parser = argparse.ArgumentParser(description='Prepare or fetch the pinned multilingual model asset')
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('pack')
    prepare.add_argument('--source', type=Path, default=SOURCE)
    prepare.add_argument('--output', type=Path, required=True)
    prepare.add_argument('--descriptor', type=Path, default=DESCRIPTOR)
    prepare.add_argument('--url', required=True)
    download = commands.add_parser('fetch')
    download.add_argument('--descriptor', type=Path, default=DESCRIPTOR)
    download.add_argument('--destination', type=Path, default=SOURCE)
    args = parser.parse_args()
    if args.command == 'pack':
        value = pack(args.source, args.output, args.descriptor, args.url)
        print(json.dumps({key: value[key] for key in ['bytes', 'sha256', 'url']}, indent=2))
    else:
        fetch(args.descriptor, args.destination)


if __name__ == '__main__':
    main()
