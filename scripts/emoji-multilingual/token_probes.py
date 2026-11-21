import json
import random
import argparse
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description='Generate deterministic native tokenizer parity probes')
sys.path.insert(0, str(ROOT / 'scripts/emoji-models'))
from contracts import checked_snapshot
parser.add_argument('--snapshot', type=Path, required=True)
parser.add_argument('output', type=Path)
args = parser.parse_args()
manifest = json.loads((ROOT / 'apps/EmojiMatch/ModelResources/Multilingual/multilingual-manifest.json').read_text())
snapshot = checked_snapshot(args.snapshot, manifest)
from tokenizers import Tokenizer
tokenizer = Tokenizer.from_file(str(snapshot / 'tokenizer.json'))
tokenizer.enable_truncation(max_length=512)
texts = ['query: ' + s for s in ['A kite!', 'кошка', '日本語です。', 'příliš žluťoučký kůň', '▁́x', 'a<mask> b<s>c</s>', '\x00\x01\t\n', '  café  ', 'hello' * 1000, '👩🏽\u200d🚀🤷🏿\u200d♀️', '', '<mask><mask>', 'a▁▁b']]
random.seed(7823)
for _ in range(1000):
    texts.append('query: ' + ''.join(chr(random.choice([random.randrange(0x20, 0xd800), random.randrange(0xe000, 0x110000)])) for _ in range(20)))
for code in range(0x110000):
    if 0xd800 <= code <= 0xdfff: continue
    scalar = chr(code)
    if tokenizer.normalizer.normalize_str(scalar) != scalar:
        texts.extend(['query: x' + scalar + 'x', 'query: ' + scalar + '\u0301x'])
rows = [{'text': text, 'ids': tokenizer.encode(text).ids} for text in texts]
args.output.write_text(json.dumps(rows, ensure_ascii=False))
print(len(rows))
