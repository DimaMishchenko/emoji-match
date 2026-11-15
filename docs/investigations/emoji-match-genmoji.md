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

## Product integration follow-up, 2026-11-15

The product now hands Genmoji creation to Character Palette's native input-method session. The
header icon is the original `emoji.face.grinning.and.plus.inverse` artwork from CoreGlyphsPrivate,
exported with a 15-point regular symbol configuration as a template PDF with vector preservation.
The creator itself is Apple's actual 320 × 480-point compact UI, including its native animation,
photo/person/emoji controls, generated-image editor, Add and dismissal behavior.

Why the final integration uses a system handoff:

- The public Image Playground controller generates and returns real glyphs, but its presentation
  enforces an 800 × 600-point content size on this runtime; setting a compact popover size does not
  turn it into the system's compact creator.
- Directly hosting `STKEmojiGenerationViewController` reproduces the layout but fails generation
  with ModelManager permission errors in an ordinary process.
- `CPKGenerationRemoteViewController` successfully hosts the privileged generation service and
  generates images. Its result is an NSUUID. Resolving that UUID requires sticker database access;
  `stickersd` rejects clients without `com.apple.private.stickers`. A disposable ad-hoc helper
  claiming that entitlement was killed by macOS. The app does not claim the entitlement.
- A prototype of `CPKShowGenmojiCreationFirstOnNextSession` did not provide a consistently correct
  insertion session when called from the replacement picker. The product instead opens the native
  picker in the original recipient, then advances its existing Genmoji control. No private creation
  function or direct sticker database reader remains in production.

An early handoff rendered the creator but did not prove insertion. Retaining and refocusing the
original AX input, allowing the replacement popover to release key focus, and focusing the native
prompt before prefill resolved the tested path. The production action generated a lemon wearing
sunglasses, and Add inserted it into a task-owned TextEdit RTFD document. Copy-back decoded as an
`NSAdaptiveImageGlyph`, identifier `A89DF024-4052-41D4-993F-0DF750A185D30`, with 7,373 image bytes.
This establishes semantic glyph delivery; it is not a comparison against inaccessible original
sticker-database bytes. The test clipboard was restored.

Recipient boundary observed in the follow-up: a task-owned Safari `contenteditable`/ARIA textbox
received the native system browser, but macOS omitted its Genmoji control entirely. Emoji Match did
not force a glyph or description into that field. This is an unsupported receiving context for the
native Genmoji path on this machine, rather than evidence that all Safari editors support it.

Notes also passed the production path. A temporary note received the native creator, query prefill,
generation and Add. Copy-back returned an adaptive glyph with identifier
`5D9C7B08-6294-49B1-A40F-16291C4C79440`, description `a smiling lime`, and 7,391 image bytes. No message
or email was sent. Test clipboard contents were restored. Both tested supported native recipients
retained the adaptive-glyph representation; this does not establish universal receiving-app support.

[Compact creator, dark backdrop](../verification/emoji-match-genmoji/generated.png),
[compact creator, Notes backdrop](../verification/emoji-match-genmoji/notes-generated.png),
[TextEdit copy-back](../verification/emoji-match-genmoji/textedit-copy.rtfd), and
[Notes copy-back](../verification/emoji-match-genmoji/notes-copy.rtfd).
