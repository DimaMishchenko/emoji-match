#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/emoji-token-check-XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/module-cache"
"${PYTHON:-python3}" -B scripts/emoji-multilingual/token_probes.py "$@" "$work/probes.json"
swiftc -parse-as-library -default-isolation MainActor -module-cache-path "$work/module-cache" apps/EmojiMatch/AppSources/Search/EmojiMultilingualTokenizer.swift scripts/emoji-multilingual/TokenCheck.swift -o "$work/token-check"
"$work/token-check" apps/EmojiMatch/ModelResources/Multilingual "$work/probes.json" > "$work/tokenizer-parity.txt"
cat "$work/tokenizer-parity.txt"
