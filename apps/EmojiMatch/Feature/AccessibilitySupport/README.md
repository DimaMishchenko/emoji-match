# AccessibilitySupport

Small app-local helper module for Accessibility-driven behavior in `EmojiMatch`.

## Purpose

This target owns two things:

- checking and requesting macOS Accessibility permission
- resolving the best available text anchor near the current insertion point

It is intentionally app-specific. It is not meant to be shared through `Package.swift`.

## Public API

Use the module through two static helpers:

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

Discovery starts at the nearest text input in the focused element ancestry and stays within that
input subtree, with bounded traversal and AX identity deduplication. It does not search sibling
inputs through a window or application ancestor. When the app exposes only nontext focus or no
identifiable focused input, the resolver returns `nil`; it does not guess a field in the window.

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
