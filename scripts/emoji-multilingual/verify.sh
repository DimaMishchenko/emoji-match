#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/emoji-multilingual-native-XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/module-cache"
frameworks="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"
flags=(-parse-as-library -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -module-cache-path "$work/module-cache")
sources=(apps/EmojiMatch/AppSources/Search/EmojiMultilingual*.swift apps/EmojiMatch/AppSources/Search/EmojiSearchMatch.swift apps/EmojiMatch/AppSources/Search/EmojiSearchInput.swift apps/EmojiMatch/AppSources/Search/EmojiModelResourceValidation.swift)
swiftc "${flags[@]}" "${sources[@]}" scripts/emoji-multilingual/NativeCheck.swift -o "$work/native-check"
"$work/native-check" "$PWD/apps/EmojiMatch/ModelResources/Multilingual" "$work/flat-app-resources"
"$work/native-check" "$work/flat-app-resources" > "$work/native-multilingual-parity.json"
swiftc "${flags[@]}" -enable-testing -emit-library -emit-module -module-name EmojiMatch -emit-module-path "$work/EmojiMatch.swiftmodule" "${sources[@]}" -o "$work/libEmojiMatch.dylib"
cat > "$work/TestMain.swift" <<'SWIFT'
import Testing
@main struct TestMain {
  static func main() async {
    let result: CInt = await Testing.__swiftPMEntryPoint()
    if result != 0 { fatalError("Tests failed with code \(result)") }
  }
}
SWIFT
swiftc "${flags[@]}" -load-plugin-library "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" -I "$work" -L "$work" -lEmojiMatch -F "$frameworks" -framework Testing -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$work" apps/EmojiMatch/Feature/EmojiMatchTests/EmojiMultilingual*.swift "$work/TestMain.swift" -o "$work/focused-tests"
"$work/focused-tests" 2>&1 | tee "$work/focused-tests.log"
cat "$work/native-multilingual-parity.json"
