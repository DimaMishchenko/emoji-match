# Emojis and EmojiKit

## Summary

This package has two related targets:

- `Emojis`: a runtime library that loads bundled emoji data
- `EmojiKit`: a CLI that fetches Unicode + CLDR data and generates the bundled resources

The goal is to ship a deterministic emoji catalog that:

- works on Apple platforms and Linux
- provides localized display names and search tokens
- keeps one logical entry per emoji concept
- models skin-tone variants as variants, not separate top-level rows
- can optionally filter unsupported emoji on Apple platforms

## Core Idea

The runtime treats the emoji set as a catalog of logical entries.

Examples:

- `👍` is one logical emoji
- `👍🏻` / `👍🏽` / `👍🏿` are variants of that logical emoji
- `🤝` is one logical emoji
- mixed-tone handshakes are variants of that logical emoji

This keeps app-level presentation simpler:

- the app shows one row for `👍`
- the app chooses which tone variant to display
- search works against the logical entry, not every concrete tone sequence separately

## Targets

### `Emojis`

Runtime API for:

- reading metadata
- fetching localized emojis
- building a multilingual search index from bundled locale files
- applying an Apple-only support filter when requested

### `EmojiKit`

Generator/maintenance CLI for:

- resolving latest upstream Unicode + CLDR releases
- fetching source files
- generating bundled JSON
- writing deterministic output suitable for git

## Runtime Model

The important runtime concepts are:

- `Metadata`
  - schema version
  - Unicode version
  - CLDR version
  - generated timestamp
  - default locale
  - bundled locales
  - source file provenance
- `Emoji`
  - stable ID
  - base emoji value
  - group / subgroup
  - Unicode version
  - sort order
  - localized strings
  - skin-tone support
  - skin-tone variants
- `SearchIndex`
  - built at runtime from base emoji data plus selected locale files

Skin tone is modeled explicitly:

- `none`
- `single`
- `multiple`

Concrete tone-modified sequences live in `skinToneVariants`.

## Resource Layout

Generated resources live under `Sources/Emojis/Resources`:

```text
metadata.json
emojis.json
localizations/
  index.json
  <locale>.json
```

Notes:

- `emojis.json` stores base logical emoji entries
- `localizations/<locale>.json` stores effective localized values for those logical IDs
- there is no persisted all-locales `search-index.json`
- search data is built at runtime from the locale files already on disk

## Locale Behavior

Locale resolution is deterministic.

Resolution behavior:

- exact locale first
- then progressively less specific candidates
- language-only fallback last
- example: `en-GB -> en`

If no explicit locale can be resolved:

- `fetch(locale: someLocale)` throws `unsupportedLocale`

If the system locale is unsupported:

- `fetch(locale: nil)` falls back to the bundled default locale

## Localization Strategy

The generator produces effective localizations, not raw CLDR rows.

Current fallback idea:

1. direct CLDR annotation
2. derived CLDR annotation
3. alias handling where needed
4. `en` fallback
5. deterministic synthesized fallback from Unicode source naming

Important consequence:

- generated locale files are expected to be complete for every shipped logical emoji ID
- runtime should not need to invent missing localizations if the bundle is valid

## Skin-Tone Grouping

Skin-tone variants are collapsed into one logical base emoji entry.

Rules:

- keep the no-tone base emoji as the top-level entry when it exists
- store tone-modified Unicode sequences under `skinToneVariants`
- preserve tone-slot order for multi-tone variants
- resolve bases by scalar sequence after removing tone modifiers and normalizing presentation selectors for matching only; retain original fully-qualified IDs and values
- use explicit structural aliases for Unicode's legacy singleton handshake, holding-hands, kiss, heart-couple, bunny-ear and wrestling bases
- never infer identity from English names or synthesize an unlisted no-tone sequence; fail generation for an unresolved variant
- include standalone `component` rows as canonical entries alongside fully-qualified rows, preserving every RGI sequence exactly once across bases and variants
- omit minimally-qualified and unqualified aliases as separate rows
- preserve the source's CLDR ordering and illustrative groups/subgroups; native Apple picker grouping and ordering belong in app adapters
- do not collapse unrelated distinctions such as profession, gender, family composition, flags, or presentation variants

Examples:

- `👍` with five tone variants is `single`
- `🤝` with mixed-tone combinations is `multiple`

## Search

Search is designed for app-side instant lookup without shipping a duplicated bundle-wide index file.

Current approach:

- locale files contain both display names and search tokens
- `Emojis.searchIndex(...)` loads the requested locales
- runtime builds a search view from:
  - `emojis.json`
  - selected localization files

Why:

- avoids storing the same search data twice
- reduces git noise
- reduces bundled resource size
- keeps search flexible for:
  - one locale
  - all bundled locales
  - explicit locale combinations

## Apple Support Filter

`Filter.apple` is Apple-only and uses CoreText with `AppleColorEmoji`.

What it is for:

- hide emojis unsupported by the current Apple OS

What it is not:

- not a public general-purpose `isSupported` API
- not a Unicode conformance check
- not needed on Linux

Current behavior:

- on modern Apple runtimes it may filter nothing
- on older Apple OS versions it does matter for newer emoji releases

Known verified example:

- Unicode 16 emojis such as `🫩` and `🫆` were unsupported on an iOS 17.2 simulator
- the same emojis were supported on an iOS 18.5 simulator

So the filter is intentionally optional, but justified.

## CLI Behavior

Primary commands:

```bash
swift run emoji fetch latest
swift run emoji locales latest
```

Current expectations:

- default generated locale set is `en`
- callers can request explicit locales
- callers can request `all`
- generated output is deterministic
- writes are skipped when bytes are unchanged unless forced

## Requirements

- `Emojis` must compile on Apple platforms and Linux
- `EmojiKit` must compile and run on macOS and Linux
- generated resources must be deterministic and commit-friendly
- resources are generated-only and should not be hand-edited
- locale files must align with the logical IDs in `emojis.json`

## Known Limitations

- upstream CLDR coverage is incomplete for the full Unicode emoji set
- completeness relies on generator fallback behavior, not raw CLDR alone
- locale availability depends on upstream CLDR annotation packages
- some region/script-specific locale tags users may want are not present upstream as standalone generated locale files
- Apple emoji support filtering is heuristic and platform-specific

## Validation

Normal validation:

```bash
swift test
```

Integration validation:

```bash
EMOJIKIT_LIVE_TESTS=1 swift test --filter EmojiKitIntegrationTests
```

Useful manual checks:

```bash
swift run emoji fetch latest
swift run emoji locales latest
```

## Maintenance Notes

When changing the model or generator:

- update this document if the architecture or contract changed
- prefer test-first changes
- keep generated resource commits separate from logic/spec commits when possible
- treat the generated JSON as build artifacts that happen to be checked into git

Empty CLDR display names do not count as usable localization values, even when keywords exist. Generation applies English/synthesized fallback and validates nonempty display names and tokens before writing.

## Upstream Discovery And Provenance

`fetch latest` resolves the version from the official `emoji/latest/emoji-test.txt` header, then fetches a concrete versioned source and validates its header before generation. Numeric `/Public/emoji/` directories stop at 16.0; releases from 17 use `/Public/<version>.0/emoji/`. Unicode character properties and presentation variation sequences come from `/Public/<version>.0/ucd/emoji/`, not the keyboard data directory.

CLDR JSON discovery accepts only stable numeric `major.minor.patch` tags. Annotation URLs retain the exact tag, while `cldrVersion` records its major release. Every consumed upstream file has a concrete URL and SHA-256 in metadata; the floating discovery URL is never recorded as a pinned source.

The bundled snapshot uses Unicode Emoji 18.0 and CLDR 49 (`49.0.0`) with the existing 20 locales. It contains 1,932 canonical base/component entries and 2,040 concrete tone variants, covering all 3,963 fully-qualified sequences and nine components. No prior base IDs were removed from the 16.0 snapshot.

Generation validates the complete dataset before writing. JSON is sorted and newline-terminated; writes are atomic per file, not a transaction across the complete bundle. If release, locale set and upstream source hashes match existing metadata, its generation timestamp is retained so repeating a fetch produces identical bytes. A parser implementation change can still change payload bytes without changing the upstream-source timestamp.

Primary release sources: https://unicode.org/Public/18.0.0/emoji/emoji-test.txt and https://github.com/unicode-org/cldr-json/releases/tag/49.0.0. CLDR's release index is https://cldr.unicode.org/index/downloads.

## Generator maintenance

`emoji fetch pinned --unicode-version 18.0 --cldr-tag 49.0.0 --locales <comma-separated locales>`
uses concrete upstream versions without floating release or locale-directory discovery for explicit
locales. `fetch latest` retains release discovery for upgrades. Both paths use the same generator,
validate pinned Unicode headers, retain matching source timestamps and write deterministic bytes.
Version arguments must be numeric Unicode `major.minor` and stable CLDR `major.minor.patch`.

Tone variants accumulate by canonical base in source order and each immutable base is constructed
once. Explicit legacy sequence-to-base mappings remain maintained parser rules; names never establish
identity. The pinned integration check compares complete parsed records against the generated snapshot,
including order, grouping, names and tone slots. Optional upstream property/sequence files are fetched
and hashed when available; they do not currently add parser validation. Only HTTP 404 is optional;
other transport/status failures propagate.

Generated Unicode/CLDR resources are never edited manually. Product aliases and derived runtime
shortcodes belong to the app search layer and do not change this package's public schema. See
[emoji data maintenance](../emoji-data-maintenance.md) for ownership and reproducible commands.
