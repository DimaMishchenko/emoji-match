# Multilingual E5 maintenance

The optional model is `intfloat/multilingual-e5-small` at revision
`614241f622f53c4eeff9890bdc4f31cfecc418b3`. MIT and Apache licenses and NOTICE accompany the resources. The model card is linked
from `multilingual-NOTICE.txt`; a model-card file is not packaged. Keep all attribution files with redistributed resources.
The offline runtime uses fixed `[1,512]` inputs, the pinned SentencePiece normalization/Unigram
vocabulary, `query: ` and `passage: ` prefixes, masked mean pooling and L2 normalization.
The 1,932-row Float32 index preserves canonical order; cosine scores are not probabilities.
Only embedding gathers use float16; the encoder/pooling use float32 and CPU-only Core ML.

MiniLM ships in the app for English. E5 is an explicit on-demand download from the pinned GitHub
release ZIP, approximately 235 MB; retained source plus compiled resources occupy approximately
575 MB after installation. Search works offline after installation. Downloading the model sends no
search query. Settings offers download progress, cancellation, removal and retry after failure.
`apps/EmojiMatch/ModelResources/Multilingual` holds maintenance inputs and is excluded from the app
bundle; model `.mlpackage` directories are ignored by Git. The bundled
`apps/EmojiMatch/Resources/multilingual-download.json` pins the release URL, revision, archive size
and SHA256, and every extracted file's size and SHA256. Keep the complete exact file inventory.

From the repository root, restore the ignored model package once on a fresh checkout before
running E5 native checks or the full app test suite. This fetch is maintenance-only; app builds do
not require the E5 package and never bundle it.

```sh
python3 -B scripts/emoji-multilingual/resources.py fetch \
  --descriptor apps/EmojiMatch/Resources/multilingual-download.json \
  --destination apps/EmojiMatch/ModelResources/Multilingual
python3 -B scripts/emoji-models/contracts.py
python3 -B scripts/emoji-multilingual/verify_manifest.py
zsh scripts/emoji-multilingual/verify.sh
```

The Python contracts require only the standard library. Native verification needs selected Xcode
on macOS. It compiles production sources and focused tests, checks source and flattened compiled
resource layouts, token IDs, vectors/scores within 1e-4, and exact top-six parity. Scratch is removed
on exit and diagnostics print to stdout. These are parity checks, not relevance measurements.

For intentional regeneration, use Python 3.10 on Apple Silicon macOS in a separate venv with
`pip install -r scripts/emoji-multilingual/requirements.txt`. Pip resolves transitive dependencies;
the manifest records shipped conversion versions. Supply a local Hugging Face snapshot at the
revision above with all manifest `sourceFiles`. All source hashes are verified; export never downloads:

```sh
python -B scripts/emoji-multilingual/export.py --snapshot /absolute/path/to/pinned/snapshot
python -B scripts/emoji-models/reference.py multilingual --snapshot /absolute/path/to/pinned/snapshot
PYTHON=/absolute/path/to/venv/bin/python zsh scripts/emoji-multilingual/verify_tokenizer.sh --snapshot /absolute/path/to/pinned/snapshot
```

Export reuses an existing model package but rewrites index/tokenizer/parity resources. Remove the
package explicitly before an intentional model reconversion. Preserve packaged attribution files.
The shared descriptor helper derives canonical English descriptors from `Sources/Emojis/Resources`
and asserts the shipped descriptor SHA256 before model work. Reference verification checks every
index row and probe vector against PyTorch within 1e-5. Tokenizer probes cover normalization-map
changes, combining marks, seeded Unicode strings, special tokens and long inputs.

After implementation-only edits, `python3 -B scripts/emoji-multilingual/finalize_manifest.py`
refreshes implementation hashes while asserting resource bytes are unchanged. Core ML conversion
may produce different package identifiers. No experiment corpus, saved evidence or retired cache
is needed. OS Unicode-version drift remains a possible tokenizer edge outside the probes.

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

## Pack and fetch the release asset

Use the standard-library helper with a fully prepared local resource directory. Packing does not
fetch source models or publish a release; it writes the ZIP and descriptor. A fixed timestamp,
sorted paths and regular-file permissions make repeated packs byte-identical with the same inputs
and Python/zlib toolchain. Compression bytes are not promised across toolchain versions.

```sh
python3 -B scripts/emoji-multilingual/resources.py pack \
  --source apps/EmojiMatch/ModelResources/Multilingual \
  --output /tmp/multilingual-e5-small.zip \
  --descriptor /tmp/multilingual-download.json \
  --url https://github.com/DimaMishchenko/emoji-match/releases/download/models-e5-small-614241f-v1/multilingual-e5-small.zip
python3 -B scripts/emoji-multilingual/resources.py fetch \
  --descriptor apps/EmojiMatch/Resources/multilingual-download.json \
  --destination apps/EmojiMatch/ModelResources/Multilingual
python3 -B -m unittest discover -s scripts/emoji-multilingual -p 'test_resources.py' -v
```

`fetch` uses the network only when explicitly invoked, accepts HTTPS GitHub/release-asset hosts
and port 443 only, validates redirects before following them, bounds downloaded bytes, and verifies
the complete archive before staging extraction. Extraction rejects missing/extra/duplicate paths,
unsafe paths, nonregular entries, and incorrect sizes/digests, then checks the manifest against the
descriptor. Changed pinned files and unexpected destination entries (including symlinks and local notes)
are preserved and reported rather than replaced.
Failures clean staging directories and leave the existing destination intact. Validation uses
explicit errors and remains active under `python -O`. This helper installs maintenance source
resources; the app's installer additionally compiles Core ML and validates its installed layout.

The focused tests use tiny synthetic inventories and in-memory responses, deny real network calls,
and cover deterministic packing, round trips and rejection paths. They neither download the real
asset nor establish release availability or runtime model parity. Finalize implementation hashes,
repack, review the generated descriptor, and publish matching assets as a separate release step.
