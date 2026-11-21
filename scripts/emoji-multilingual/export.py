import hashlib
import importlib.metadata
import json
import os
import subprocess
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'apps/EmojiMatch/ModelResources/Multilingual'
REVISION = '614241f622f53c4eeff9890bdc4f31cfecc418b3'
sys.path.insert(0, str(ROOT / 'scripts/emoji-models'))
from contracts import checked_snapshot, descriptor_bytes, descriptors as canonical_descriptors, snapshot_argument
args = snapshot_argument('Offline Multilingual conversion using verified pinned source files').parse_args()
manifest_path = OUT / 'multilingual-manifest.json'
pinned_manifest = json.loads(manifest_path.read_text())
assert pinned_manifest['revision'] == REVISION
SNAPSHOT = checked_snapshot(args.snapshot, pinned_manifest)
descriptor_data = descriptor_bytes()
descriptors = canonical_descriptors()
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
os.environ['HF_HUB_OFFLINE'] = '1'
import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

torch.set_num_threads(1)
OUT.mkdir(parents=True, exist_ok=True)
model = AutoModel.from_pretrained(SNAPSHOT, local_files_only=True, attn_implementation='eager').eval()
tokenizer = AutoTokenizer.from_pretrained(SNAPSHOT, local_files_only=True)
def finite_attention_mask(attention_mask, input_shape, device=None, dtype=None):
    return (1.0 - attention_mask[:, None, None, :].to(torch.float32)) * -10000.0
model.get_extended_attention_mask = finite_attention_mask

class Encoder(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = model

    def forward(self, input_ids, attention_mask):
        hidden = self.encoder(input_ids=input_ids, attention_mask=attention_mask, return_dict=False)[0]
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, p=2, dim=1)

encoder = Encoder().eval()
example = tokenizer('query: a small native encoder', max_length=512, padding='max_length', truncation=True, return_tensors='pt')
if not (OUT / 'Multilingual.mlpackage').exists():
    with torch.no_grad():
        traced = torch.jit.trace(encoder, (example['input_ids'], example['attention_mask']))
    converted = ct.convert(traced, inputs=[ct.TensorType(name=name, shape=(1, 512), dtype=np.int32) for name in ['input_ids', 'attention_mask']], outputs=[ct.TensorType(name='embedding', dtype=np.float32)], minimum_deployment_target=ct.target.macOS14, compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type == 'gather'), compute_units=ct.ComputeUnit.CPU_ONLY)
    converted.short_description = 'Pinned multilingual-e5-small; masked mean pooling; normalized 384-dimensional embeddings.'
    converted.license = 'MIT'
    converted.user_defined_metadata['revision'] = REVISION
    converted.save(str(OUT / 'Multilingual.mlpackage'))
reloaded = ct.models.MLModel(str(OUT / 'Multilingual.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
catalog = json.loads((ROOT / 'Sources/Emojis/Resources/emojis.json').read_text())
assert [d['id'] for d in descriptors] == [d['id'] for d in catalog]
vectors = []
with torch.no_grad():
    for start in range(0, len(descriptors), 32):
        batch = tokenizer(['passage: ' + d['text'] for d in descriptors[start:start+32]], padding=True, truncation=True, max_length=512, return_tensors='pt')
        vectors.append(encoder(batch['input_ids'], batch['attention_mask']).numpy())
        print(f'index {start}/{len(descriptors)}', flush=True)
matrix = np.concatenate(vectors).astype('<f4')
matrix.tofile(OUT / 'multilingual-index.f32')
(OUT / 'multilingual-catalog.json').write_text(json.dumps([{'id': c['id'], 'value': c['value']} for c in catalog], ensure_ascii=False, indent=2) + '\n')
config = json.loads((SNAPSHOT / 'tokenizer.json').read_text())
assert config['model']['type'] == 'Unigram' and config['model']['unk_id'] == 3
(OUT / 'multilingual-vocab.json').write_text(json.dumps({'pieces': [{'text': p, 'score': s} for p,s in config['model']['vocab']], 'charsmap': config['normalizer']['normalizers'][0]['precompiled_charsmap']}, ensure_ascii=False, separators=(',', ':')) + '\n')
probes = [
    ('en', 'A paper kite, in a breeze!'), ('es', 'Un gato durmiendo en el sofá.'),
    ('fr', 'Je voudrais un café chaud.'), ('de', 'Ein Fahrrad im Regen.'),
    ('cs', 'Narozeninový dort se svíčkami.'), ('uk', 'Соняшник під сонячним небом.'),
    ('ja', '雨の日に傘をさす。'), ('en', "Can't stop: hello_world 😊!?"),
    ('cs', 'Café de\u0301ja\u0300 vu — Ｈｅｌｌｏ ① ㍿\u00a0\t\n'),
    ('en', '▁\u0301x 👩🏽\u200d🚀 \u0000\u0001 \U0001e030 \U0001fbf0'),
    ('en', '<mask><s>test</s><pad><unk>'), ('en', ''), ('en', ' \n\t'),
    ('en', ' '.join(['bright orchard'] * 300)),
]
rows = []
with torch.no_grad():
    for locale, query in probes:
        batch = tokenizer('query: ' + query, padding='max_length', truncation=True, max_length=512, return_tensors='pt')
        expected = encoder(batch['input_ids'], batch['attention_mask']).numpy()[0]
        actual = reloaded.predict({name: batch[name].numpy().astype(np.int32) for name in ['input_ids', 'attention_mask']})['embedding'][0]
        scores = matrix @ expected
        actual_scores = matrix @ actual
        top = np.argsort(-scores, kind='stable')[:6]
        actual_top = np.argsort(-actual_scores, kind='stable')[:6]
        error = float(np.max(np.abs(expected-actual)))
        score_error = float(np.max(np.abs(scores-actual_scores)))
        row = {'locale': locale, 'query': query, 'tokenIDs': batch['input_ids'][0][batch['attention_mask'][0].bool()].tolist(), 'vector': expected.tolist(), 'topIDs': [descriptors[i]['id'] for i in top], 'scores': scores[top].tolist(), 'coreMLMaxAbsoluteError': error, 'coreMLMaxScoreError': score_error, 'coreMLTopIDs': [descriptors[i]['id'] for i in actual_top]}
        rows.append(row)
        print(locale, repr(query[:60]), error, score_error, top.tolist(), actual_top.tolist(), flush=True)
(OUT / 'multilingual-parity.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
assert all(r['coreMLMaxAbsoluteError'] < 0.0001 and r['coreMLMaxScoreError'] < 0.0001 and r['topIDs'] == r['coreMLTopIDs'] for r in rows), 'float16 parity failed'
manifest = {'schema': 1, 'repository': 'intfloat/multilingual-e5-small', 'revision': REVISION, 'sourceFiles': {str(p.relative_to(SNAPSHOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(SNAPSHOT.rglob('*')) if p.is_file() and 'onnx' not in p.parts}, 'license': 'MIT', 'dimensions': 384, 'count': 1932, 'maxTokens': 512, 'precision': 'float16 embedding gathers, float32 encoder/pooling/output/index', 'computeUnits': 'cpuOnly', 'queryPrefix': 'query: ', 'passagePrefix': 'passage: ', 'pooling': 'attention-mask mean, L2 normalization', 'index': 'little-endian row-major Float32 normalized vectors in canonical catalog order', 'score': 'cosine similarity, not a probability', 'tieBreak': 'canonical catalog order', 'descriptorSHA256': hashlib.sha256(descriptor_data).hexdigest(), 'parityTolerance': {'vectorMaxAbsolute': 0.0001, 'scoreMaxAbsolute': 0.0001, 'top6Exact': True}, 'packages': {name: importlib.metadata.version(name) for name in ['coremltools', 'torch', 'transformers', 'tokenizers', 'numpy']}, 'implementationFiles': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted([*ROOT.glob('apps/EmojiMatch/AppSources/Search/EmojiMultilingual*.swift'), *ROOT.glob('scripts/emoji-multilingual/*.py'), ROOT / 'scripts/emoji-multilingual/requirements.txt'])}, 'files': {str(p.relative_to(OUT)): {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes': p.stat().st_size} for p in sorted(OUT.rglob('*')) if p.is_file() and p.name != 'multilingual-manifest.json'}}
(OUT / 'multilingual-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'exportReloadMaximumError': max(r['coreMLMaxAbsoluteError'] for r in rows), 'indexShape': list(matrix.shape), 'resourceBytes': sum(p.stat().st_size for p in OUT.rglob('*') if p.is_file())}, indent=2))

subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/emoji-multilingual/finalize_manifest.py')], check=True)
