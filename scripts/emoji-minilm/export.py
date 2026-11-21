import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import shutil

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'apps/EmojiMatch/Resources/MiniLM'
REVISION = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
sys.path.insert(0, str(ROOT / 'scripts/emoji-models'))
from contracts import checked_snapshot, descriptor_bytes, descriptors as canonical_descriptors, snapshot_argument
args = snapshot_argument('Offline MiniLM conversion using verified pinned source files').parse_args()
manifest_path = OUT / 'manifest.json'
pinned_manifest = json.loads(manifest_path.read_text())
assert pinned_manifest['revision'] == REVISION
SNAPSHOT = checked_snapshot(args.snapshot, pinned_manifest)
descriptor_data = descriptor_bytes()
descriptors = canonical_descriptors()
assert (OUT / 'LICENSE').is_file()
assert (SNAPSHOT / 'README.md').is_file()
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
example = tokenizer('a small native encoder', max_length=256, padding='max_length', truncation=True, return_tensors='pt')
with torch.no_grad():
    traced = torch.jit.trace(encoder, (example['input_ids'], example['attention_mask']))
converted = ct.convert(traced, inputs=[ct.TensorType(name=name, shape=(1, 256), dtype=np.int32) for name in ['input_ids', 'attention_mask']], outputs=[ct.TensorType(name='embedding')], minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_AND_GPU)
converted.short_description = 'Pinned all-MiniLM-L6-v2; masked mean pooling; L2 normalized 384-dimensional embedding.'
converted.license = 'Apache-2.0'
converted.user_defined_metadata['revision'] = REVISION
converted.save(str(OUT / 'MiniLM.mlpackage'))
reloaded = ct.models.MLModel(str(OUT / 'MiniLM.mlpackage'), compute_units=ct.ComputeUnit.CPU_AND_GPU)
catalog = json.loads((ROOT / 'Sources/Emojis/Resources/emojis.json').read_text())
assert [d['id'] for d in descriptors] == [d['id'] for d in catalog]
vectors = []
with torch.no_grad():
    for start in range(0, len(descriptors), 64):
        batch = tokenizer([d['text'] for d in descriptors[start:start+64]], padding=True, truncation=True, max_length=256, return_tensors='pt')
        vectors.append(encoder(batch['input_ids'], batch['attention_mask']).numpy())
matrix = np.concatenate(vectors).astype('<f4')
matrix.tofile(OUT / 'index.f32')
(OUT / 'catalog.json').write_text(json.dumps([{'id': c['id'], 'value': c['value']} for c in catalog], ensure_ascii=False, indent=2) + '\n')
shutil.copyfile(SNAPSHOT / 'vocab.txt', OUT / 'vocab.txt')
probes = ['A paper kite, in a breeze!', 'Café déjà vu — naïve façade.', '猫と犬，中文。', '', ' '.join(['bright orchard'] * 300), "Can't stop: hello_world 😊", '[MASK] [CLS] test']
rows = []
with torch.no_grad():
    for query in probes:
        batch = tokenizer(query, padding='max_length', truncation=True, max_length=256, return_tensors='pt')
        expected = encoder(batch['input_ids'], batch['attention_mask']).numpy()[0]
        actual = reloaded.predict({name: batch[name].numpy().astype(np.int32) for name in ['input_ids', 'attention_mask']})['embedding'][0]
        scores = matrix @ expected
        top = np.argsort(-scores, kind='stable')[:6]
        rows.append({'query': query, 'tokenIDs': batch['input_ids'][0][batch['attention_mask'][0].bool()].tolist(), 'vector': expected.tolist(), 'topIDs': [descriptors[i]['id'] for i in top], 'scores': scores[top].tolist(), 'coreMLMaxAbsoluteError': float(np.max(np.abs(expected-actual)))})
        assert np.max(np.abs(expected-actual)) < 0.0001
(OUT / 'parity.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
shutil.copyfile(SNAPSHOT / 'README.md', OUT / 'MODEL_CARD.md')
manifest = {'schema': 1, 'sourceFiles': {str(p.relative_to(SNAPSHOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(SNAPSHOT.rglob('*')) if p.is_file()}, 'licenseURL': 'https://www.apache.org/licenses/LICENSE-2.0.txt', 'modelCardURL': f'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/blob/{REVISION}/README.md', 'repository': 'sentence-transformers/all-MiniLM-L6-v2', 'revision': REVISION, 'dimensions': 384, 'count': 1932, 'maxTokens': 256, 'precision': 'float32', 'computeUnits': 'cpuAndGPU', 'pooling': 'attention-mask mean, L2 normalization', 'index': 'little-endian row-major Float32 normalized vectors, canonical catalog order', 'score': 'dot product, not a probability', 'descriptorSHA256': hashlib.sha256(descriptor_data).hexdigest(), 'packages': {name: importlib.metadata.version(name) for name in ['coremltools', 'torch', 'transformers', 'numpy']}, 'files': {str(p.relative_to(OUT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUT.rglob('*')) if p.is_file() and p.name != 'manifest.json'}}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'exportReloadMaximumError': max(r['coreMLMaxAbsoluteError'] for r in rows), 'indexShape': list(matrix.shape)}, indent=2))
