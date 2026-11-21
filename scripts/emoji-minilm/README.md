# MiniLM maintenance

The bundled English model is `sentence-transformers/all-MiniLM-L6-v2` at revision
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41` (Apache-2.0; model card and license are packaged).
The offline runtime uses fixed `[1,256]` inputs, BERT uncased WordPiece, masked mean pooling,
and L2-normalized 384-dimensional vectors. The Float32 index has 1,932 canonical rows;
scores are dot products, not probabilities. Ties preserve catalog order.

From the repository root:

```sh
python3 -B scripts/emoji-models/contracts.py
python3 -B scripts/emoji-minilm/verify_manifest.py
zsh scripts/emoji-minilm/verify.sh
```

The first two checks require only Python's standard library. The native check needs selected
Xcode on macOS, compiles production sources and focused tests, and checks packaged token IDs,
vectors and top-six order against parity fixtures. Scratch is removed on exit; diagnostics
print to stdout. These checks establish implementation parity, not retrieval quality.

For intentional regeneration, use Python 3.10 on Apple Silicon macOS in a separate venv with
`pip install -r scripts/emoji-minilm/requirements.txt`. Transitive dependencies are resolved by
pip; the manifest records the package versions used for the shipped conversion. Obtain a local
Hugging Face snapshot at the revision above with all manifest `sourceFiles`, including README.md,
and retain the packaged Apache license. Export validates every pinned source hash and never downloads:

```sh
python -B scripts/emoji-minilm/export.py --snapshot /absolute/path/to/pinned/snapshot
python -B scripts/emoji-models/reference.py minilm --snapshot /absolute/path/to/pinned/snapshot
```

Export deliberately rewrites model/index/parity resources. The shared descriptor helper derives
English names and deduplicated search tokens from `Sources/Emojis/Resources`, preserves canonical
order and asserts the shipped descriptor SHA256 before model work. Reference verification checks
all index rows and query vectors against PyTorch within 1e-5; native parity tolerance is 1e-4.
Core ML package identifiers may differ between conversions. No experiment directory, saved
evidence, original training data or historical cache is required.

Runtime resource loading validates manifest schema 1, pinned revision, dimensions and row count,
then streams SHA256 for the tokenizer, catalog and index once per lazy resource load. Source
packages additionally validate their package manifest, model graph and weights. Flattened compiled
models validate the weights against the source-package digest and the loaded model's revision
metadata. Both current compilers preserve the pinned weight bytes. The compiled graph and compiler
metadata have no portable pinned digest in these manifests; their byte identity is not established.
Changing the manifest alongside a resource is outside this integrity check's trust boundary.

Provider entry points reject raw queries above 2,000 Unicode scalars or 8,000 UTF-8 bytes before
trimming, cache lookup or model loading. Direct tokenizer inputs allow 2,048 scalars and 8,192 bytes
for prefixes. Existing oversized parity fixtures now verify rejection; in-bound fixtures retain
exact token/ranking and vector/score tolerance checks. Cancellation takes precedence over input
validation. `releaseResources()` clears the loaded resources and one-query embedding cache on the
provider actor; the next accepted nonempty operation reloads and revalidates resources. No automatic
eviction policy is imposed. These rules cover FIND-05's local model paths.
