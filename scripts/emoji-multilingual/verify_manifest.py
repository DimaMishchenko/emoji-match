import argparse
import hashlib
import json
from pathlib import Path
argparse.ArgumentParser(description='Verify packaged resource SHA256 contracts').parse_args()
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'apps/EmojiMatch/ModelResources/Multilingual'
manifest = json.loads((OUT / 'multilingual-manifest.json').read_text())
assert manifest['revision'] == '614241f622f53c4eeff9890bdc4f31cfecc418b3'
for name, expected in manifest['files'].items():
    data = (OUT / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
    assert len(data) == expected['bytes'], name
for name, expected in manifest['implementationFiles'].items():
    assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, name
print(f"Verified {len(manifest['files'])} resources; {sum(v['bytes'] for v in manifest['files'].values())} bytes")

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'emoji-models'))
from contracts import descriptors
descriptors()
