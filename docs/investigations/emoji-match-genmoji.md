# Genmoji integration feasibility

2026-11-15. Runtime macOS 27.2.1, Apple Silicon; Xcode/macOS SDK 27.2.

## Conclusion

Emoji Match can create real Genmoji using public Image Playground APIs and insert them into a
compatible rich-text recipient through the clipboard. A disposable prototype generated a glyph,
pasted it into a new TextEdit document, and copied it back with the same identifier and original
image bytes. No Genmoji feature was added to the product in this investigation.

The picker implementation was committed and pushed separately as
`0558411cf383459b9f458d3bdf8057163f2ab475` on `fix/emoji-match-native-picker-parity`.

## Verified creation path

The installed SDK and current Apple documentation expose `ImagePlaygroundStyle.emoji` and the
adaptive-image-glyph completion callback. A public AppKit prototype used:

```swift
let controller = ImagePlaygroundViewController()
controller.allowedGenerationStyles = [.emoji]
controller.selectedGenerationStyle = .emoji
controller.concepts = [.text("a smiling lemon wearing sunglasses")]
controller.delegate = delegate
host.presentAsSheet(controller)
```

`ImagePlaygroundViewController.isAvailable` returned true on this Mac. The system displayed a
Genmoji creator, generated the test description, and called:

```swift
func imagePlaygroundViewController(
  _ controller: ImagePlaygroundViewController,
  didCreate adaptiveImageGlyph: NSAdaptiveImageGlyph
)
```

The delegate must also implement the ordinary `didCreateImageAt: URL` callback. SwiftUI offers the
same route through `imagePlaygroundSheet(...onAdaptiveImageGlyphCreation:)` and
`imagePlaygroundGenerationStyle(.emoji, in: [.emoji])`.

[Creation screenshot](emoji-match-genmoji-evidence/creation-sheet.png).

## Verified rich insertion

The prototype constructed:

```swift
let text = NSAttributedString(
  adaptiveImageGlyph: glyph,
  attributes: [.font: NSFont.systemFont(ofSize: 24)]
)
pasteboard.writeObjects([text])
```

This exported flat RTFD, RTF and plain-text representations. A new empty TextEdit rich-text document
received Cmd+V. Selecting the inserted result and copying it back produced native RTFD clipboard
representations. Decoding the copy preserved the adaptive glyph identifier and its original image
content byte for byte.

- Content identifier: `64BF5C31-12F0-470E-8EBA-4183A8430DE90`
- Original image data: 30,986 bytes
- Original image SHA-256: `5b4ee55bcd65807bb9e1930419c8107bf5fefe6e6970388fb4b099d655670c80`
- Generated glyph → RTFD → glyph: identifier preserved
- Generated glyph → rich clipboard → TextEdit → copy-back → glyph: identifier and image bytes preserved
- Original clipboard restored after the experiment, guarded by its change count
- The unsaved task-created TextEdit document was discarded; the prototype was stopped

[Original glyph data](emoji-match-genmoji-evidence/generated.heic) and
[TextEdit copy-back](emoji-match-genmoji-evidence/textedit-copy.rtfd) are retained locally in the repo.

Decoder caveat observed during verification: a standalone decoder without initialized AppKit
returned `NSAttachment` with an `AdaptiveImageGlyph-<identifier>.heic` file wrapper. Initializing
`NSApplication.shared` before decoding returned the adaptive image provider attribute and original
glyph bytes. Do not misclassify that attachment fallback as loss of the stored glyph data, and do
not accept matching pixels alone as proof of semantic preservation.

## Private APIs examined

Runtime Objective-C introspection successfully loaded CharacterPicker and StickerKit from the
system dyld cache. The following concrete selectors/classes exist on this host:

- `CPKState.state`, `shouldShowGenmojiCreationUI`, `isShowingGenerationUI`
- `CPKState.supportsInlineTextAttachments`, `supportsImagePaste`
- `CPKCharactersView.createEmojiButtonPressed:`, `supportsEmojiGeneration`
- `NSTextInputContext.supportsAdaptiveImageGlyph`, `insertAdaptiveImageGlyph:replacementRange:`
- `NSTextInputContext.supportsAdaptiveImageGlyph_RTI`, `insertAdaptiveImageGlyph_RTI:replacementRange:`
- `STKImageGlyphDataSource.doesSupportGeneration`, `donateImageGlyphToRecents:`

The CharacterPalette executable links CharacterPicker, StickerKit and InputMethodKit and references
these paths. This is direct evidence of the native integration surface, not proof that invoking a
local singleton controls the remote CharacterPalette process. No private creation selector was
invoked and no process injection was performed. Public creation plus rich paste already passed the
first real recipient test, so private APIs are unnecessary for that route.

## Emoji Match implementation shape

1. Add a Genmoji action when Image Playground reports availability.
2. Retain the original target application and insertion context before dismissing the picker and
   presenting the system creation sheet. Cancellation restores focus without inserting content.
3. Keep the returned `NSAdaptiveImageGlyph`, including original `imageContent`; do not convert it to
   an ordinary emoji string or flatten it to PNG for compatible rich-text targets.
4. Extend `TextPasteController`, which currently accepts only `String`, with rich attributed-content
   insertion and explicit fallback behavior. Restore target focus before Cmd+V.
5. Verify clipboard restoration timing independently for rich data. The current 150 ms restoration
   delay and unconditional restore are not established as reliable for every rich-content consumer;
   preserve intervening user copies.
6. Define deliberate behavior for unsupported recipients: ordinary image/attachment or description,
   rather than silently pasting the attachment replacement character.
7. Extend usage history separately if generated glyphs should participate in recents. Existing usage
   selection and history are string-oriented, so generated binary content needs a distinct model.

## Compatibility boundary

`NSTextInputClient.supportsAdaptiveImageGlyph` and `insert(_:replacementRange:)` describe a receiving
text control, not a public cross-process endpoint. Emoji Match cannot make a plain-text field support
Genmoji. Its own `NSTextInputContext.current?.client` is not another app's focused editor. No public
remote capability query was established in this investigation.

Native rich-text controls and compatible WebKit editors are the intended integration path. Only
TextEdit was exercised for cross-app glyph insertion here; Notes, Messages, Mail, browser editors and
Electron applications still need per-app tests distinguishing inline adaptive glyph, ordinary image,
attachment, description and failure. No messages or emails were sent.

The creation API reports availability based on system support; generation also depends on Apple
Intelligence being available for the user's hardware, configuration, language and region. Rendering
an existing glyph is a separate capability. Current docs annotate `.emoji` as macOS 15.4+, but this
probe ran only on macOS 27.2.1. Do not infer older-runtime behavior from the current SDK's annotations
without testing the deployment versions actually supported by Emoji Match.

## Primary references

- [WWDC26 public Genmoji integration example, 11:02](https://developer.apple.com/videos/play/wwdc2026/375/?time=662)
- [ImagePlaygroundStyle.emoji](https://developer.apple.com/documentation/imageplayground/imageplaygroundstyle/emoji)
- [Image Playground availability](https://developer.apple.com/documentation/imageplayground/imageplaygroundviewcontroller/isavailable)
- [NSAdaptiveImageGlyph](https://developer.apple.com/documentation/appkit/nsadaptiveimageglyph)
- [WWDC24 rich-text support and compatibility](https://developer.apple.com/videos/play/wwdc2024/10220/)
- [Apple Intelligence requirements](https://support.apple.com/en-us/121115)

Installed SDK evidence: ImagePlayground.framework's `Modules/ImagePlayground.swiftmodule/arm64e-apple-macos.swiftinterface`,
and AppKit.framework's `Headers/NSAdaptiveImageGlyph.h`, `NSTextInputClient.h`, `NSTextInputContext.h`,
`NSAttributedString.h` and `NSTextView.h` under the active Xcode macOS SDK.
