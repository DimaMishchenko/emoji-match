# Focused-input Genmoji and image capability

Investigated 2026-11-16 on macOS 27.2.1. The desired per-input policy is:

| Verified input support | Picker behavior |
| --- | --- |
| Adaptive glyphs | Show Create and saved Genmoji; deliver the original glyph |
| Images only | Show those items; let the recipient select an image representation |
| Neither | Hide creation and all rich items, including recents, favorites and search |
| Unknown | Keep separate from unsupported; no guessed classification |

## What shipped

Genmoji Copy and Paste now advertise one item containing original adaptive-glyph bytes, preserving
RTFD, and a real PNG fallback. The PNG is decoded/reencoded, not HEIC data labeled PNG. There is no
plain text description and no second paste. The existing destination/session/clipboard guards remain.
This enables recipient format negotiation without trying an insertion and attempting to infer failure.

A generic original-client capability query is **not shipped**. Visibility now applies a bounded
structural web-search heuristic (search subrole, search landmark, or same-dialog owned result list)
and an explicit Terminal exception. Spotify/T3 bundle checks were removed. Identical control traits
receive the same decision across other apps, with unknown/native/multiline editors left available.
The heuristic does not establish the absence of custom paste handlers and does not resolve native
plain TextEdit. See the generic rule review (local validation; artifacts not tracked).
No trustworthy generic probe for the original remote field
was established. Existing rich UI remains available for unknown destinations. Hiding all unknowns
would hide Genmoji even from the verified TextEdit rich field; treating all text areas as supported
would expose it in plain editors. Neither is evidence of the requested capability decision.

## Verified native flag path

Apple documents [NSTextInputClient.supportsAdaptiveImageGlyph](https://developer.apple.com/documentation/appkit/nstextinputclient)
as the document's adaptive-image support flag. Installed CharacterPalette's `CVInputController`
queries its existing IMK client's `getApplicationPropertyValue:` with property
`NSTextInputContextTIPropertySupportsEmojiImageTextAttachments`, whose scalar value is 16 on this
runtime. The recipient's `NSTextInputContext._valueForTIProperty:` maps that property to the modern
`supportsAdaptiveImageGlyph` method. CharacterPalette stores the result as
`CPKState.supportsInlineTextAttachments`.

That is an existing input-service session, not an AX element or an independently acquired remote
NSTextInputClient. Emoji Match's local `NSTextInputContext.current` and CPKState refer to its own
process. TSMGetActiveDocument is also local; it returned nil in an isolated helper while TextEdit
was visibly focused. No passive endpoint for acquiring the original IMK client was verified.
No private property number is hard-coded into production.

`CPKState.supportsImagePaste` exists separately. Its positive producer, format semantics and an
accessible destination query were not recovered. An explicit glyph-support false would still not
establish that ordinary images are unsupported.

## Checks against shortcuts

- Read-only AX probes on TextEdit and a T3 Electron text area returned no adaptive-glyph/image-paste
  support attributes or input-trait dictionary. No document text or clipboard data was collected.
- Local NSTextView controls reported adaptive support false for plain text and true for rich text,
  both with graphics import disabled and enabled. Graphics import alone is not the adaptive flag.
- Plain and rich text controls advertise overlapping readable pasteboard types, including RTFD.
  Type-list presence is not proof that a field preserves adaptive glyphs or accepts image insertion.
- An enabled Paste menu can reflect general editing state and current clipboard contents. It is not
  a verified per-format capability response. Opening a native picker to inspect its controls would
  add visible UI/focus changes to every Emoji Match presentation.

These are bounded negative findings, not proof that every private route is impossible. A future
classifier should require a concrete original-client acquisition route and compare it with direct
ground truth in plain, adaptive, image-only and web controls. Cooperative test endpoints establish
only the harness's behavior, not access to arbitrary applications. An input-method integration is a
different architecture and is not silently introduced by this change.

## Verification scope

The initial real HEIC fixture checks exercised exact original RTFD glyph identity/bytes, genuine PNG
signature, the original 160 × 160 fallback dimensions and equal decoded pixels, one paste event, Copy parity and invalid-asset
clipboard safety. Tests use temporary named pasteboards and clean them automatically. Arbitrary
Electron/browser/app acceptance and automatic UI visibility are not established by these tests.

The final integrated app suite passed **88 tests, zero failures or skips**. A real rich NSTextView
read the production item and retained exact glyph bytes; a deliberately PNG-only NSTextView subclass
with adaptive support false selected the same item's PNG and inserted an ordinary NSTextAttachment.
An independent source review found no important issues. The verification bundle (local validation; artifacts not tracked)
contains logs, the native-consumer harness and its output. This verifies AppKit format negotiation
and does not claim arbitrary app compatibility or acknowledgment of global paste events.

The follow-up caps only the PNG fallback at 24 pixels after proving that WebKit ignores PNG DPI for
this purpose and displays the original at 160 pixels. Real Safari paste into the existing fixture
now renders inline. Original HEIC and RTFD glyph data remain intact. Finder still requires a direct
text-input path: native inserts a real glyph, while Finder rejects even Paste of its own copied RTFD.
See recipient validation (local validation; artifacts not tracked).
