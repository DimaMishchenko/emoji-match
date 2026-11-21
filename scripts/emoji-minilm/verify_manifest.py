import argparse
import hashlib
import json
from pathlib import Path
argparse.ArgumentParser(description='Verify packaged resource SHA256 contracts').parse_args()
root = Path(__file__).resolve().parents[2]
resources = root / 'apps/EmojiMatch/Resources/MiniLM'
manifest = json.loads((resources / 'manifest.json').read_text())
for name, expected in manifest['files'].items():
    assert hashlib.sha256((resources / name).read_bytes()).hexdigest() == expected, name
print(f"Verified {len(manifest['files'])} packaged SHA256 values")

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'emoji-models'))
from contracts import descriptors
descriptors()
