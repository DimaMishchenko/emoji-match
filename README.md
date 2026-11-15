# emoji-match

🎯 Emoji Match is a macOS utility for finding and inserting emoji while writing.

This repository contains the Emoji Match app, its shared Swift packages, and the tooling that generates its bundled emoji data. The app is under active development; the [working spec](docs/specs/emoji-match-spec.md) describes the intended experience.

## Development

Requires macOS 26 or later, Xcode with Swift 6.3 or later, and Tuist.

Generate the Xcode workspace:

```sh
tuist generate --no-open
open emoji-match.xcworkspace
```

Build and run the `EmojiMatch` scheme on your Mac. App targets live in `apps/EmojiMatch` and are managed by Tuist. The root Swift package contains `DesignSystem`, `Emojis`, and the `EmojiKit` data generator with its `emoji` command-line tool.

Run shared package tests and lint Swift code from the repository root:

```sh
swift test
swift format lint Sources Tests apps -r -p
```

See the [emoji data contract](docs/specs/emojis-spec.md) for generation and resource details.
