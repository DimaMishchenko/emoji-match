# Emoji data and search maintenance

`Sources/EmojiKit` owns fetching, validation, canonical sequence exceptions and JSON generation.
`Sources/Emojis/Resources` is generated-only Unicode/CLDR data. Never hand-edit it.
`apps/EmojiMatch/AppSources/Search` owns lexical ranking and runtime-derived English-name shortcodes.
Shortcodes split normalized English names into words joined by underscores; optional surrounding
colons are query syntax. These are derived from existing Unicode/CLDR data, not GitHub/Slack aliases.
No external shortcode dataset or additional license dependency was added.

`apps/EmojiMatch/Resources/emoji-search-aliases.json` is the maintained product synonym list.
Its provenance identifies maintainer-authored synonyms. Review each addition against its canonical
ID and add a focused regression for surprising behavior. Keep product words out of generated CLDR.

`emoji-keyword-extensions.json` is a legacy 1,906-entry broad expansion file with unverified
provenance and no reproducible upstream generator in this repository. It is neither authoritative
Unicode data nor a reviewed curated dictionary. Preserve it as weak retrieval evidence while
incrementally reviewing it. This change corrects coffee's burning/danger/intense/trending/power/passion
aliases only; it does not claim to clean the whole file. Audited examples still include cheers →
ginger root and celebration → roasted sweet potato. All category/legacy extension evidence is
systematically below complete authoritative/curated matches, rather than special-casing these queries.
New product synonyms belong in the maintained file.

## Reproduce the bundled snapshot

The current snapshot is Unicode Emoji 18.0 / CLDR JSON 49.0.0, 20 locales, 1,932 bases/components
and 2,040 tone variants. Concrete source URLs and SHA-256 values live in `metadata.json`.
From repository root, regenerate into an automatically cleaned temporary directory and compare:

```sh
set -eu
output=$(mktemp -d "${TMPDIR:-/tmp}/emoji-data.XXXXXX")
trap 'rm -rf "$output"' EXIT
cp Sources/Emojis/Resources/metadata.json "$output/metadata.json"
locales=$(python3 -c 'import json; print(",".join(json.load(open("Sources/Emojis/Resources/metadata.json"))["availableLocaleIdentifiers"]))')
swift run emoji fetch pinned --unicode-version 18.0 --cldr-tag 49.0.0 \
  --locales "$locales" --output-root "$output"
diff -qr Sources/Emojis/Resources "$output"
```

Seeding matching metadata retains its timestamp. Sorted JSON, source ordering and per-file atomic
writes make repeated identical inputs byte-stable; writing a bundle is not one atomic transaction.
Explicit locales avoid unnecessary CLDR directory discovery. Only 404 makes an optional source
absent; rate limits, malformed required inputs and other errors fail generation. Optional Unicode
property/sequence files currently provide provenance, not additional sequence validation.

For upgrades, use `swift run emoji fetch latest --locales "$locales" --dry-run` first, then generate
without `--dry-run` and review source hashes, locale completeness, ID/tone/order differences and
parser exceptions. Update the pinned version/count assertions and specs deliberately when upstream
changes them. Keep generated resource changes reviewable separately from maintained logic/data.

```sh
swift test --filter EmojiKitTests
EMOJIKIT_LIVE_TESTS=1 swift test --filter EmojiKitIntegrationTests/bundledSequencesMatchPinnedUnicodeSource
swift format lint Sources Tests apps -r -p
```

All generator tests creating directories use `defer` cleanup; dry-run regression checks prove no
output directory is created. The live pinned test compares complete parsed records to the snapshot.

## Maintain local semantic search

The app bundles MiniLM for English and offers E5 as an explicit download in Settings → Search.
E5 works offline once installed and can be cancelled or removed through the app. Their conversion,
resource integrity and native parity checks live under `scripts/emoji-minilm` and
`scripts/emoji-multilingual`. Follow those maintained instructions when updating model resources.
Model indices must use the canonical generated catalog order; names, keywords and maintained aliases
remain separate from model weights. Keep model licenses and tokenizer/vector regression fixtures
with the resources. Model parity verifies implementation agreement, not relevance quality.

Use the app's focused search-store, fusion, provider, cancellation and composition tests for routine
changes. Historical benchmark runners, training attempts, exported predictions and per-run evidence
are not dependencies of the app or the model maintenance workflow.
