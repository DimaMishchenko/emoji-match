import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'apps/EmojiMatch/ModelResources/Multilingual'
parser = argparse.ArgumentParser(description='Refresh implementation hashes after verifying unchanged packaged resource hashes')
parser.parse_args()
path = OUT / 'multilingual-manifest.json'
manifest = json.loads(path.read_text())
for name, expected in manifest['files'].items():
    data = (OUT / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
    assert len(data) == expected['bytes'], name
implementation = [
    *ROOT.glob('apps/EmojiMatch/AppSources/Search/EmojiMultilingual*.swift'),
    *ROOT.glob('apps/EmojiMatch/Feature/EmojiMatchTests/EmojiMultilingual*.swift'),
    *ROOT.glob('scripts/emoji-multilingual/*.py'),
    *ROOT.glob('scripts/emoji-multilingual/*.swift'),
    *ROOT.glob('scripts/emoji-multilingual/*.sh'),
    *ROOT.glob('scripts/emoji-models/*.py'),
    ROOT / 'scripts/emoji-multilingual/requirements.txt',
    ROOT / 'apps/EmojiMatch/AppSources/Search/EmojiSearchInput.swift',
    ROOT / 'apps/EmojiMatch/AppSources/Search/EmojiModelResourceValidation.swift',
]
manifest['implementationFiles'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(implementation)}
path.write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Refreshed {len(implementation)} implementation hashes; packaged resource hashes unchanged')
