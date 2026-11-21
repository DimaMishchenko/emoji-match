import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESCRIPTOR_SHA256 = 'c27e62acb4473c6de09b681c345d6528a8fc0025ace974024b1949e77950b73b'


def descriptor_bytes():
    catalog = json.loads((ROOT / 'Sources/Emojis/Resources/emojis.json').read_text())
    english = json.loads((ROOT / 'Sources/Emojis/Resources/localizations/en.json').read_text())['entries']
    rows = []
    for entry in catalog:
        localized = english[entry['id']]
        tokens = list(dict.fromkeys(localized['searchTokens']))
        rows.append({'id': entry['id'], 'text': localized['name'] + '. Keywords: ' + ', '.join(tokens) + '.'})
    data = (json.dumps(rows, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    assert len(rows) == 1932
    assert hashlib.sha256(data).hexdigest() == DESCRIPTOR_SHA256, 'Canonical descriptors changed; shipped indices require coordinated regeneration'
    return data


def descriptors():
    return json.loads(descriptor_bytes())


def snapshot_argument(description):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--snapshot', type=Path, required=True, help='Local Hugging Face snapshot at the revision recorded in the packaged manifest')
    return parser


def checked_snapshot(path, manifest):
    path = path.resolve()
    assert path.is_dir(), f'Snapshot not found: {path}'
    for name, expected in manifest['sourceFiles'].items():
        assert hashlib.sha256((path / name).read_bytes()).hexdigest() == expected, f'Snapshot differs from pinned revision: {name}'
    return path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Verify current catalog descriptors match both shipped model contracts')
    parser.parse_args()
    rows = descriptors()
    catalog = json.loads((ROOT / 'Sources/Emojis/Resources/emojis.json').read_text())
    expected_catalog = [{'id': row['id'], 'value': row['value']} for row in catalog]
    for directory, prefix, manifest_name in [('MiniLM', '', 'manifest.json'), ('Multilingual', 'multilingual-', 'multilingual-manifest.json')]:
        resources = ROOT / 'apps/EmojiMatch' / ('Resources' if directory == 'MiniLM' else 'ModelResources') / directory
        manifest = json.loads((resources / manifest_name).read_text())
        assert manifest['descriptorSHA256'] == DESCRIPTOR_SHA256
        assert manifest['count'] == len(rows)
        assert manifest['dimensions'] == 384
        assert json.loads((resources / (prefix + 'catalog.json')).read_text()) == expected_catalog
        assert (resources / (prefix + 'index.f32')).stat().st_size == len(rows) * 384 * 4
    print(f'Verified {len(rows)} canonical descriptors, SHA256 {DESCRIPTOR_SHA256}; both catalog orders and index dimensions match')
