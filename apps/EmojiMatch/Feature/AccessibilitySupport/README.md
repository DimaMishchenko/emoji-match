# AccessibilitySupport

Small app-local helper module for Accessibility-driven behavior in `EmojiMatch`.

## Purpose

This target owns:

- checking and requesting macOS Accessibility permission
- identifying the semantic focused text input for insertion capture
- resolving the best available text anchor near the current insertion point

It is intentionally app-specific. It is not meant to be shared through `Package.swift`.

## Public API

Use the module through static helpers:

```swift
import AccessibilitySupport

AccessibilityPermission.requestIfNeeded()
let anchorRect = TextAnchorResolver.anchorRect()
```

### `AccessibilityPermission`

- `AccessibilityPermission.status`
- `AccessibilityPermission.isGranted`
- `AccessibilityPermission.requestIfNeeded()`

This is the simple app-facing permission API. App code decides when to prompt, so onboarding and
future error handling can stay outside the resolver logic.

### `TextAnchorResolver`

- `TextAnchorResolver.anchorRect()`

Returns a `CGRect` for the focused text caret or selection when reliable AX geometry is available.
When caret geometry is unavailable, it can return an estimated caret or the focused input bounds.
Returns `nil` when Accessibility is unavailable or the current app does not expose enough text
context.

## Resolution Strategy

The resolver prefers:

1. exact AX text marker bounds
2. exact AX selected-range bounds
3. nearby character bounds
4. AX line range bounds at line starts
5. estimated caret position from text content and a valid selection
6. the focused input bounds when caret information is unavailable
7. `nil` so the app can fall back to screen center

Exact marker and selected-range bounds in the focused input subtree are checked before estimates.
Marker bounds do not require a numeric selected range. Valid exact geometry is preserved without
shifting it to estimated search-field insets or comparing its vertical position to estimated text
layout, which cannot model wrapping, scrolling, fonts, or rich text reliably.

Numeric ranges must be nonnegative, must not overflow, and must fit the exposed UTF-16 text when
available. Malformed ranges are never sent to parameterized AX lookups or clamped into an invented
selection. Optional invalid insertion-line attributes do not disqualify an otherwise editable input.
Text bounds must be finite with positive height; zero-width carets are supported. Bounds outside the
input rectangle are rejected, allowing two points of tolerance for AX edge rounding. This validation
also applies to nearby-character and line-range fallbacks and to nonempty selections.

Discovery normally starts at the nearest text input in the focused element ancestry. Static text
labels never qualify solely from insertion-line or selection attributes; nonstatic text wrappers
retain the valid insertion-line fallback.

For active-descendant result focus inside a dialog, the semantic input is instead the unique
editable input whose `AXOwns` or `AXLinkedUIElements` explicitly references the focused list ancestor.
Only the nearest dialog is searched (including `AXGroup` / `AXApplicationDialog`); nested dialogs
and the result list subtree are excluded. Search is limited to 12 focus ancestors, 8 descendant
levels and 128 distinct elements, with AX identity deduplication. Incomplete traversal, ambiguous
owners, missing/invalid geometry, or owner/list rectangles outside the dialog return `nil`. AX array
reads for owner discovery require the complete advertised `AXChildren` collection, capped at 128
elements. Visible children, rows or contents alone are partial and cannot establish completeness.
Failed advertised child/ownership reads return `nil`; an element advertising no child collections
is a leaf. Ordinary anchor geometry keeps its separate bounded best-effort descendant reads.
There is no whole-window field guess and an unrelated field cannot become the destination.

The warmup requests both `AXManualAccessibility` and `AXEnhancedUserInterface` once per recipient
process. The latter enabled the observed Chromium search accessibility tree even though its setter
returned an error; actual focus and input structure, not setter status, determine usability.

`TextInputFocusResolver.focusedElement(inApplication: pid_t) -> AXUIElement?` exposes this same
resolution for app-owned insertion destination capture and classification. Call it before showing
the picker, while the recipient app still owns focus. The app retains and validates the captured
destination; this module does not own insertion or app lifecycle. A resolved owner need not expose
`AXFocused=true` when its active descendant owns AX focus.

Once the input is chosen, geometry discovery stays within that input subtree with its existing
bounded traversal. It does not borrow caret/selection geometry from result rows or sibling inputs.

Estimated text layout remains approximate. A stale caret still inside the same field cannot always
be detected from AX alone, and an AX-poor app may provide only field-level placement. Native picker
parity, Electron behavior, Spotify behavior, scrolling, and rich-text placement require live app
verification beyond deterministic fixture tests.

For estimated insets only, a leading button/image (or a matching wrapper around one) can be read
from the field's same-bounds parent when it occupies the leading full-height control slot. This
supports search controls such as Spotify without searching sibling selections. Static text,
placeholders, and arbitrary groups do not qualify as leading accessories.

It also enables `AXManualAccessibility` on the frontmost app to improve support for Electron and
WebView wrappers.

## Internal Structure

- `Sources/Public`
  - app-facing helper API only
- `Sources/Internal/TextAnchorLocator.swift`
  - main resolution flow and fallback order
- `Sources/Internal/AccessibilityElementReader.swift`
  - AX tree and attribute access
- `Sources/Internal/ManualAccessibilityWarmup.swift`
  - `AXManualAccessibility` warmup cache
- `Sources/Internal/FocusedTextAnchorHeuristics.swift`
  - pure heuristics used by fallbacks
- `AccessibilityElementReading`
  - injectable internal AX-reading boundary for deterministic fixtures
- `Tests/TextAnchorHeuristicsTests.swift`
  - range and geometry validation plus fallback heuristics
- `Tests/TextAnchorLocatorTests.swift`
  - production resolver flow with controlled AX attributes, geometry, and focus trees

The internals are deliberately hidden behind the small public surface because this logic is
necessarily messy and platform-specific.
