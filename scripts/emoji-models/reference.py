import argparse
import json
import os
from pathlib import Path

from contracts import ROOT, checked_snapshot, descriptors

parser = argparse.ArgumentParser(description='Compare packaged query and index vectors against a pinned offline PyTorch reference')
parser.add_argument('model', choices=['minilm', 'multilingual'])
parser.add_argument('--snapshot', required=True, type=Path)
args = parser.parse_args()
prefix = '' if args.model == 'minilm' else 'multilingual-'
resources = ROOT / 'apps/EmojiMatch' / ('Resources/MiniLM' if args.model == 'minilm' else 'ModelResources/Multilingual')
manifest = json.loads((resources / (prefix + 'manifest.json')).read_text())
snapshot = checked_snapshot(args.snapshot, manifest)
rows = descriptors()
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

torch.set_num_threads(1)
model = AutoModel.from_pretrained(snapshot, local_files_only=True, attn_implementation='eager').eval()
tokenizer = AutoTokenizer.from_pretrained(snapshot, local_files_only=True)


def encode(texts):
    batches = []
    with torch.no_grad():
        for start in range(0, len(texts), 32):
            batch = tokenizer(texts[start:start + 32], padding=True, truncation=True, max_length=manifest['maxTokens'], return_tensors='pt')
            hidden = model(**batch).last_hidden_state
            mask = batch['attention_mask'].unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
            batches.append(torch.nn.functional.normalize(pooled, p=2, dim=1).numpy())
    return np.concatenate(batches)


probes = json.loads((resources / (prefix + 'parity.json')).read_text())
query_vectors = encode([manifest.get('queryPrefix', '') + row['query'] for row in probes])
index = encode([manifest.get('passagePrefix', '') + row['text'] for row in rows])
actual = np.fromfile(resources / (prefix + 'index.f32'), dtype='<f4').reshape(len(rows), 384)
query_error = float(np.max(np.abs(query_vectors - np.array([row['vector'] for row in probes]))))
index_error = float(np.max(np.abs(index - actual)))
assert query_error < 1e-5 and index_error < 1e-5, (query_error, index_error)
print(json.dumps({'queryMaxAbsoluteError': query_error, 'indexMaxAbsoluteError': index_error, 'probeCount': len(probes), 'descriptorCount': len(rows)}, indent=2))
