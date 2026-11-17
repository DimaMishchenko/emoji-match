# Emoji Match 🎯

> Working spec for shaping the first version of the app. This document is intentionally temporary
> and may later be replaced by app-level documentation such as a README.

## Summary

Emoji Match is a macOS-first utility for finding and inserting the right emoji while writing.

It is a shortcut-driven replacement for the compact system emoji picker while the app is running.
It preserves Emoji Match’s search, usage history, and catalog features while aiming to match the
system picker’s presentation and placement.

The core loop is:

1. Trigger a global shortcut while typing.
2. Type what you mean, or use currently selected text as the starting query.
3. See a ranked list of emoji suggestions.
4. Press Enter to paste the best result into the current app.

## Problem

Default emoji pickers are good when the user already knows the emoji or exact keyword.

They are poor at intent-based lookup such as:

- `emoji for an "Architecture" section header`
- `emoji for a section header`
- `anime`
- `soft spring vibe`
- `subtle celebration`

The current workaround is to leave the writing flow and ask an LLM for emoji suggestions. That is
slow, repetitive, and unnecessary for such a small task.

## Current Development Target

- macOS only
- global shortcut first
- native-sized emoji popover, not a replacement keyboard
- default action is paste
- semantic lookup is core
- supports quick browsing of the full emoji library

## V1 Scope

### Core Features

#### 1. Global shortcut launcher

The app opens from a user-configurable global shortcut.

Expected behavior:

- opens directly into the full emoji browser in a native AppKit popover
- focuses the search field immediately
- can be used without touching the mouse
- still allows quick browsing of the full emoji library, similar to the default picker

#### 2. Query-based emoji search

The app supports:

- direct keyword search with normalized matching
- category and group search
- multilingual search across all bundled locales
- deterministic ranking of exact, prefix, and contains matches
- local keyword extensions bundled with the app

Examples:

- `sparkle`
- `flower`
- `emoji for an "Architecture" section header`
- `anime`
- `subtle celebration`

Concrete search behavior:

- normalize case, accents, and width before matching
- tokenize queries and emoji keywords on punctuation and whitespace
- search against every bundled locale loaded through `Emojis.searchIndex(locales: .all)`
- include the app-bundled `emoji-keyword-extensions.json` keywords in the same search index
- rank exact matches ahead of prefix matches, prefix matches ahead of contains matches, and use
  stable sort-order ties after that
- ignore unsupported Apple-only emoji in the same way the app’s browser already does

#### 3. Selected-text prefill

If the user has text selected when the shortcut is triggered, that text becomes the initial query.

Expected behavior:

- selected text is used only for the current lookup
- if selected text cannot be accessed, the launcher opens with an empty field
- no automatic replacement occurs in v1

If text is selected, the UI may also expose an explicit `Emojify` action that enriches the selected
text with emoji suggestions. This should be a deliberate secondary action, not the default path.

#### 4. Ranked suggestions

The app shows a small ranked list of emoji results.

The top result should usually be the default action.

The list should favor:

- strong exact matches
- semantically relevant results
- common and broadly useful emoji over overly obscure matches when relevance is similar

#### 5. Paste as the default action

Pressing Enter pastes the selected emoji into the current app.

This is the primary success path for the product.

Secondary actions may exist, but the default should remain:

- trigger
- query
- Enter

#### 6. Recents and most used

The app stores local usage history on device.

V1 behavior:

- recent selections
- frequently used selections
- local only
- deterministic ranking that favors recency first and frequency second
- stable tie-breaking by emoji id and displayed value
- empty-query browsing can surface history above the catalog without replacing catalog browsing
- persist to `UserDefaults` or an equivalent local store
- record only after the app successfully creates and posts the paste shortcut events
- merge repeated emoji selections by stable ID/value
- retain count and last-used timestamp for each emoji
- bound the retained history to a small fixed window
- sort empty-query suggestions by recency first, then frequency as a tie-breaker, then stable emoji key

The empty-query default state should surface these results above the catalog browser when history
exists, but it should not replace catalog browsing itself.

#### 7. Secondary copy actions

Secondary actions may include:

- copy emoji to clipboard
- copy emoji as image

These are useful, but not the defining behavior of v1.

## Core UX Flow

### Flow A: Direct lookup

1. User triggers the global shortcut.
2. Launcher appears and search field is focused.
3. User types a query such as `flower`.
4. Results update immediately.
5. User presses Enter to paste the top emoji, or chooses a different result.

### Flow B: Intent lookup

1. User triggers the global shortcut.
2. User types a natural-language query such as `emoji for an "Architecture" section header`.
3. Search system interprets the phrase as intent, not literal keyword matching only.
4. Results are ranked by semantic relevance.
5. User presses Enter to paste the best match.

### Flow C: Selected-text prefill

1. User selects text in another app.
2. User triggers the global shortcut.
3. The selected text is inserted into the search field automatically.
4. Results are shown immediately.
5. User chooses one and pastes it manually via Enter.

### Flow D: Selected-text emojify

1. User selects text in another app.
2. User triggers the global shortcut.
3. The selected text is inserted into the search field automatically.
4. User chooses the `Emojify` action instead of the default paste action.
5. The app produces an emoji-enriched version of the selected text and inserts it back only after
   explicit confirmation.

## Supported Flows

This section lists the flows the product should intentionally support, even while some details are
still open.

### Primary Flows

#### Flow 1: Open launcher

1. User triggers the global shortcut with no selected text.
2. Launcher appears and focuses the search field.
3. If the query is empty and history exists, the launcher may show recent/frequent suggestions as a
   lightweight default state above the catalog browser.
4. User can begin typing immediately.

#### Flow 2: Search and insert

1. User types a query such as `flower`, `sparkle`, or `emoji for a section header`.
2. Local search results appear immediately while typing when relevant matches exist.
3. AI-enhanced results may appear later as a secondary layer when helpful.
4. User can confirm a result without waiting for AI if the direct result is already good enough.
5. Confirming inserts the chosen emoji into the current app and closes the launcher.

Notes:
- direct and natural-language queries are not separate product flows; both use the same search UI
- natural-language queries may sometimes show mostly AI-driven results

#### Flow 3: Selected-text prefill

1. User selects text in another app.
2. User triggers the global shortcut.
3. The selected text becomes the initial query when available.
4. Results appear for that query.
5. User selects an emoji to insert.

#### Flow 4: Recents and most used

1. User opens the launcher with an empty query.
2. Launcher may show recent selections and frequently used emoji while keeping the catalog browser
   available below them.
3. User can choose one directly without typing.
4. Once typing starts, search results become the primary view.

#### Flow 5: Full catalog browsing

1. User opens the launcher.
2. The emoji catalog is visible immediately.
3. User browses by category, grouping, or search within the catalog.
4. User selects an emoji and inserts it into the current app.

### Result States

These are states within the main search flow, not separate top-level flows.

- `AI loading`
  - direct results may already be visible
  - AI results are still loading
  - launcher may show a lightweight placeholder for the AI section

- `Scrollable results`
  - the full-size picker displays the result grid immediately
  - the user scrolls to inspect results beyond the viewport

- `No results`
  - query returns no useful local match
  - AI may still be loading, unavailable, or also fail to produce a useful suggestion
  - launcher presents a clear no-results state with practical fallback actions

### Keyboard And Dismissal

#### Flow 6: Keyboard-only operation

1. User opens the launcher without using the mouse.
2. User types, navigates results and supplied variants, and confirms a choice.
3. The full primary flow can be completed entirely by keyboard.

Exact keyboard shortcuts are:

- `Control-Command-Space`: open Emoji Match in place of the native emoji picker while the app is running
- `Down` at the end of an unmarked search enters the grid; grid arrows move by row/cell.
- `Space` on a variant-bearing grid item opens its supplied variants.
- `Up` and `Down`: move the visible selection by one grid row, clamped at the top and bottom
- `Left` and `Right`: move the visible selection by one cell, clamped at the row edges
- `Return`: paste the currently selected emoji
- `Escape`: clear a non-empty query first, then close the launcher when the query is already empty
- `Tab`: keeps the platform focus chain and is not used as the primary emoji navigation key

Opening and typing do not display a grid selection. Return resolves to the first result until
keyboard navigation or a category choice establishes an explicit selection. The highlight is a
56 × 42-point gray capsule with no colored outline. A changed nonempty query scrolls to the top;
clicking a category clears search and scrolls to that category.

Current implementation uses an invisible, nonactivating all-spaces anchor panel and an AppKit
`NSPopover` for the picker. AppKit supplies the pointer, material, rounded corners, shadow,
screen-edge clamping, edge flipping, and outside-click dismissal. The anchor panel can accompany
fullscreen apps and uses the native picker's observed window level.
The picker opens directly at 320 × 480 points of content, matching native Genmoji creation for
a seamless transition. The scrolling viewport is 386.5 points; the header, cell and footer sizes
remain unchanged. There is no compact or expansion state.
The measured layout uses a 49.5-point header, 28-point search field, six emoji columns with a
44-point row pitch, 32-point emoji artwork with a measured one-point baseline adjustment,
and a 44-point category bar. Catalog section gaps are 14 points. Nonempty browse sections, including Recents and saved items,
have visible, accessible headings; search results have no artificial section heading. Static symbol glyphs use
the adaptive text color rather than label color. The scroll content continues behind the material footer, with bottom
content padding so final items can scroll fully clear of the controls.
Search uses AppKit's NSSearchField at 13 points, retaining the system bezel, focus ring, clear
button and text-editing behavior. Settings is available from the status menu; library import lives in Settings → Stickers; the footer
chevron pages between emoji and symbols in the same picker. Eight emoji category arrays, their
order and artwork come from signature-checked static CharacterPicker APIs on the installed OS.
The canonical Unicode/CLDR dataset remains independent and supplies search, names and variants.
If native emoji data is unavailable, canonical grouping is the fallback. The second page contains
the five installed static symbol categories, including their stored ASCII entries, with native
glyph filtering and names. No guessed emoticon catalog is synthesized. Stickers and Genmoji
footer entries browse the app-owned library; this does not enumerate the system sticker library. Grid intent is tracked
independently of AppKit's search responder: unmodified arrows and Space navigate/open variants;
modified editing keys, search focus and marked-text composition return control to native editing. Search, localized data, usage history, keyboard
navigation remain app-owned features. The adjacent header action opens Genmoji when system
generation is available. Escape clears search and returns to the catalog.
The default shortcut is registered only while Emoji Match is running, without changing macOS
keyboard settings. Quitting Emoji Match releases the shortcut so the native picker is available again.
Current implementation closes the launcher when the user clicks outside it.
Current implementation anchors the launcher near the focused text caret or selection when available.
It prefers exact AX marker and selected-range bounds within the nearest focused input subtree, then
nearby-character and line bounds, then estimates from a valid selection, then the focused input’s
bounds. Marker geometry does not require a numeric selection range. Numeric ranges must be valid
and fit exposed UTF-16 text before parameterized AX queries. Zero-width carets are valid; nonfinite,
negative-size, or out-of-input geometry is rejected. Exact geometry is not shifted or rejected based
on estimated text insets or estimated line layout. Discovery does not borrow sibling input selection
through a window or application ancestor. When no focused text input is identifiable, placement
falls back to the current screen center.
Field-bound placement and estimated layout are degraded fallbacks, not claims of native caret parity.
A bounded leading control in the same-bounds parent can inform estimated text insets when the
field lacks useful AX caret bounds. Sibling placeholders and arbitrary labels are not accessories.
Visual matching and cross-app verification evidence is maintained in
local, untracked validation notes.
Current implementation requests Accessibility access from app code when caret-based positioning is
first needed, while keeping the accessibility module itself limited to status and anchor utilities.
Current implementation requests `AXManualAccessibility` and `AXEnhancedUserInterface` on the
frontmost app before reading the accessibility tree, once per process, to support Electron and
Chromium/WebView accessibility exposure. Setter return status is not treated as proof of a usable
tree; focus resolution still validates the actual returned structure.
Current implementation pastes the current keyboard selection on Return, falling back to the top
search match or top recent/frequent selection when no explicit keyboard movement has occurred yet.
Insertion captures the original application, focused editable control and available selection range.
Anchoring and insertion use the same semantic input resolver. When focus is an active result inside
a list, it accepts exactly one editable input in the nearest dialog explicitly owning/linking that
list through AXOwns or AXLinkedUIElements. Ambiguous, incomplete or out-of-dialog matches fail closed;
result labels are not treated as input controls. Searches are bounded by depth and element count.
Unreadable child/ownership arrays cancel discovery; visible-only or other partial child collections
cannot establish a complete subtree. Unsupported child attributes on a true leaf are distinct from
failed reads of advertised attributes.
The application and control/range are checked again after dismissal and before delivery. Unicode uses
PID-targeted Cmd-V. Rich selections prefer the recipient's unique, enabled primary Cmd-V menu command
through AXPress. Discovery is shallow, bounded and independent of localized menu titles. Focus,
control/range and clipboard ownership are revalidated after discovery immediately before the action.
Unavailable discovery falls back to PID-targeted Cmd-V after another validation; a failed action or
validation cancels without a second paste.
A changed or destroyed destination cancels automatic delivery. Focus restoration explicitly activates
the validated recipient even when it appears frontmost, because a nonactivating native menu can
retain keyboard focus. Delivery waits one 20 ms suspension and revalidates. Application and focused
control identity are reread after AX range queries before posting. The last selection remains available
through explicit Copy; posting an event or completing AXPress does not acknowledge that the recipient
consumed the payload.
Clipboard writes must succeed. Restoration runs after one second only while our transaction still
owns the pasteboard change count; overlapping operations retain the original snapshot and stale
callbacks cannot overwrite a newer copy. This delay is not a universal slow-reader guarantee.

#### Flow 7: Dismiss without side effects

1. User opens the launcher.
2. User decides not to insert anything.
3. User dismisses the launcher.
4. No text is inserted and the prior app remains in focus or regains focus appropriately.

### System And Failure Cases

These are support cases around the main flows.

- `Accessibility permission missing`
  - selected-text retrieval or insertion needs Accessibility support
  - required permission is missing
  - app explains degraded behavior and guides the user if needed
  - core search should remain usable when possible

- `Selected text unavailable`
  - user expects selected-text prefill
  - current app does not expose selected text, or access fails
  - launcher opens with an empty query instead of failing

- `AI unavailable`
  - Foundation Models are unsupported, disabled, unavailable, or time out
  - launcher continues to operate using deterministic local search only

- `Insertion or paste failure`
  - user confirms an emoji
  - insertion into the current app fails or is unreliable in that context
  - app handles the failure gracefully

Exact fallback behavior remains open.

### Settings And App Management Flows

#### Flow 8: Settings

1. User opens settings.
2. User updates app preferences.
3. Changes take effect immediately or with clearly defined behavior.

Settings persist the opening shortcut and selected-text prefill preference. The shortcut recorder
supports reset and reports registration conflicts. Our registered shortcut is suspended while
recording; ending recording or losing the Settings window restores registration with the current
setting. Settings show Accessibility permission status,
link to its system settings, and clear recents without deleting favorites or saved items. The
system picker remains available after Emoji Match quits and releases its shortcut. When creation
is unavailable, importing copied Genmoji remains available. Launch-at-login and AI preferences are
outside this pass.

#### Flow 9: First run

1. User launches Emoji Match for the first time.
2. App explains the core shortcut-driven model briefly.
3. App may surface any important permission or setup steps.

Exact onboarding depth remains open.

#### Flow 10: Reopening while already running

1. Emoji Match is already running in the background.
2. User triggers the shortcut again.
3. Launcher opens or toggles predictably.

Exact toggle behavior remains open.

## Deferred decisions

Semantic search, Emojify, synchronization and launch-on-login remain future product decisions.
Current navigation, fixed picker dimensions, native catalog grouping, settings, copy actions and
clipboard ownership are specified by the implemented contracts below rather than undecided.
Finder direct input and generic plain/rich recipient capability detection remain open platform work.

## Search Model

The search stack is deterministic and local for this pass.

## Usage History Model

The usage-history stack is deterministic and local for this pass.

History entries are stored on device and merged by stable emoji selection identity. The primary
ordering is:

1. `lastUsedAt` descending
2. `count` descending
3. `emoji id` ascending
4. `emoji value` ascending

This keeps recency dominant while still letting frequency break ties in a deterministic way. The
empty-query browser can surface the top history entries above the full catalog sections, but it
does not replace catalog browsing.

### Local rich library, favorites and variants

The original v1 Unicode history remains readable with its IDs, counts and timestamps. Imported
content uses a typed adaptive-glyph/image asset reference. A version-1 Application Support manifest
owns favorites, exact family preferences and imported metadata; separate files retain original bytes
and SHA-256 hashes. Publication is atomic. Defaults are 256 assets and 100 MiB; quota rejects new
imports instead of evicting pinned content. Unreadable manifests are not overwritten.

Paste / Import is explicit and reads only the current clipboard. RTFD/RTF imports extract adaptive
glyphs and supported image attachments without surrounding text; direct PNG, JPEG, GIF, TIFF, HEIC,
WebP and BMP are validated with ImageIO. Richer animated representations take priority over TIFF.
Duplicate bytes are reused. Valid reimport repairs a missing or damaged asset. Unavailable custom
items remain visible for explicit deletion, and invalid bytes cannot be delivered. Deleting an
imported item removes its local references and unreferenced bytes, never Apple's system original.
Clearing recent usage preserves assets and favorites. GIF previews use AppKit animation unless
Reduce Motion is enabled; original-format retention does not imply every host preserves animation.

Favorites retain the selected concrete sequence. Catalog items may apply a separately remembered
family preference. Variant IDs are supplied by the dataset, never constructed from tone tuples;
base/reset, single and multiple-person variants use their exact supplied Unicode sequences after
Apple-font rendering validation. Context actions, press-and-hold and keyboard Space expose variants.
For base plus five tones, a signature-checked CPKHorizontalPopupMenu supplies the actual native
335 × 60-point window, default-tone divider and press-drag-release tracking. Its returned string
must match an offered exact selection. A single source dispatcher and session ownership prevent
multiple menus and stale callbacks. Larger multi-person sets and unavailable/mismatching private
runtime contracts use the accessible app-owned grid fallback.

Search displays every ranked keyword match by default and searches imported descriptions. Visible
items and keyboard navigation share one content model with separate occurrence IDs. Catalog/index
failures show unavailable/retry states. This is deterministic multilingual keyword matching, not
semantic search. Custom, Favorites and Recent sections augment the existing native-size grid.

### Baseline search

Use the bundled emoji dataset for:

- emoji value matching
- localized name matching
- localized keyword matching
- app-bundled keyword extensions
- exact, prefix, and contains ranking

This path should be deterministic and fast.

### Query interpretation

The app should treat the query as a normalized keyword lookup rather than a natural-language
inference problem for this pass. Framing text such as `emoji for` should not outrank real matches,
but it does not require model-based rewriting.

## Technical Notes

### App shape

Likely a small macOS utility app with:

- global shortcut support
- floating launcher panel
- accessibility integration where needed
- pasteboard and insertion support

### Search data

The app should use the existing `Emojis` package and bundled resources as the canonical search
dataset.

This gives:

- multilingual emoji names
- multilingual keywords
- group and subgroup metadata
- deterministic local search behavior
- app-side keyword extensions for extra aliases

### AI integration

Foundation Models should be treated as an enhancement layer, not the sole search implementation.

V1 should target Foundation Models first, but the intent-search layer should be structured so other
model providers can be added later if needed.

The app should still remain useful if:

- Foundation Models are unavailable
- model latency is too high
- the system does not support the desired features

### Selected text

Selected-text prefill captures at most 1,024 UTF-16 code units through AX before opening the panel,
when enabled. Secure, unavailable or unsupported controls produce an empty query. Surrounding
document text is neither collected nor persisted. Replacement uses the unchanged captured selection;
IME marked text does not submit or trigger grid navigation.

### Paste behavior

The default action attempts insertion into the captured destination using the checked clipboard
transaction above. Unicode is sent as text; adaptive glyphs offer RTFD, original glyph data and a
genuine PNG decoded from that data in one pasteboard item. The PNG retains up to 512 pixels on
its longest edge without upscaling. DPI metadata requests a 24-point maximum display edge for
native image readers. An additional self-contained HTML image uses the same PNG with a 24-CSS-pixel
maximum display edge for web editors. Both preserve aspect ratio; recipients that ignore sizing
metadata or choose raw PNG can display the full pixel dimensions. Original glyph bytes and RTFD
remain intact. The recipient chooses its supported representation in one paste. Copy offers the
same representations. Static photo stickers use the conversion described below; GIF and multi-frame
images retain their original type. The app does not replace a rich payload with a text description or retry insertion to discover
whether a first paste succeeded. Explicit Copy in the picker and library provides a manual fallback.
Recipient support is measured per control and payload; universal rich compatibility is not claimed.

### Destination rich-content capability

The intended policy is adaptive glyphs when supported, ordinary image fallback when only images are
supported, and no creation/rich-history UI when both are known unsupported. Detection must refer to
the captured original control, not Emoji Match's own creator receiver or a whole-app allowlist.
The same decision must cover creation, recents, favorites, imported sections and search.

The generic automatic capability query is not implemented. Visibility uses a structural web-search
heuristic: a web-backed single-line input is hidden when it exposes a search subrole, belongs to a
search landmark, or explicitly owns/links a result list inside the same nearest dialog. DOM class
values, placeholder strings and application names are not matched. Multiline inputs and inputs
inside multiline editable ancestors remain unknown/allowed. Parent traversal is bounded to 12
ancestors; missing, ambiguous or insufficient metadata does not become unsupported.

Terminal AXTextArea remains an explicit application exception. Spotify and T3 have no bundle-name
branches. Identical input traits have identical decisions across all other apps. Create and every
rich occurrence use this same captured visibility decision; delivery rejects hidden rich content
before clipboard mutation and preserves stored assets. Native Finder fields, Notes, rich TextEdit,
Safari contenteditable and T3 multiline composers remain unknown/allowed.

Search semantics do not prove the absence of a custom image-upload paste handler. This is a visibility
heuristic rather than a confirmed text-only capability. Plain TextEdit remains unknown despite its
observed failed rich paste; it is not solved by a web-search rule. Finder's native glyph insertion
continues to require a verified direct-input transport. See
generic rule review (local validation; artifacts not tracked).
The native picker obtains the explicit
adaptive-glyph flag from its active IMK client, but this investigation did not establish a passive
cross-process client channel for Emoji Match, nor an equivalent reliable image-paste flag. Missing
AX attributes, text-area roles, rich formatting and enabled Paste commands are not sufficient.
Unavailable evidence remains unknown, so existing rich UI stays available rather than being hidden
under an unsupported classification. Format negotiation provides a fallback; it does not establish
capability or acknowledge insertion. See the [capability investigation](../investigations/emoji-match-rich-content-capabilities.md).

### Copy as image

Copy as image can be implemented by rendering the selected emoji to an image using Apple emoji
rendering on macOS and writing that representation to the pasteboard.

This is a secondary feature and should not complicate the main insertion flow.

### Genmoji

- The header hosts `CPKGenmojiAnimationView` when its runtime contract is available. Each fresh
  presentation invokes Apple's `roll`, retaining its short, long and static choices. Query edits
  and hover do not restart it. The static asset is the actual held final animation frame, exported
  separately for light and dark appearances at 1x, 2x and 3x. Reduce Motion and unavailable private
  animation support use that same resting artwork. The viewport is 16 × 16 points.
- Creating closes the picker and starts one app-owned capture session. An invisible 2 × 2-point
  ordinary key window hosts a real rich NSTextView. The session waits for app activation and two
  stable checks of key window, first responder and current input-context ownership. It calls the
  guarded no-argument private `CPKShowGenmojiCreationFirstOnNextSession` entry, then opens Apple's
  actual compact creator through `orderFrontCharacterPalette`. The creation UI is not redrawn.
- A bounded accessibility pass fills only a successfully read empty native prompt. Existing input
  remains untouched. Apple owns generation and photo/person/emoji choices. Add delivers an
  NSAdaptiveImageGlyph to the owned input client. Original bytes, identifier and description are
  saved locally before optional delivery through the existing destination-validated rich transaction.
  Capture alone does not increment usage. The saved item remains available if delivery cannot proceed.
- Session tokens reject stale/duplicate callbacks. Reopening Emoji Match or Settings, switching to
  another app, native disappearance or Escape delivered to the owned input client cancels.
  The native creator may consume Escape while editing its prompt. Activation/input acquisition and first native
  presentation have deadlines. Cancellation does not reactivate an unrelated app. The invisible
  receiver and monitoring are removed at completion.
- If the native creator has never appeared after 500 ms, the session makes one startup retry only
  while it still owns app activation, the key window, first responder and current input context.
  Ownership and session identity are rechecked after diagnostics. A five-second deadline remains;
  disappearance after a visible presentation cancels rather than retries.
- Explicit clipboard import remains available for existing Genmoji and supported image attachments.
  App-owned Genmoji and ordinary image/sticker originals have separate footer sections. Clearing
  recents does not delete those originals. This implementation does not synchronize or enumerate the
  system sticker database, claim restricted entitlements, or support native collection management.
- Live macOS 27.2.1 evidence covers compact creation, Add, persistence, TextEdit delivery and reuse
  with exact adaptive-glyph bytes preserved. Other OS builds and recipient types require their own
  runtime verification. Plain-text recipients cannot preserve adaptive glyphs.

### Library rendering snapshot

Storage owns a validated availability set and bounded 256-pixel static thumbnail previews for Retina galleries.
Animated image previews retain original frame/timing representations in memory so Reduce Motion
can control playback without flattening them. Original assets remain bounded by library quotas. Rendering,
filtering favorites/recents and typing queries read this snapshot without reading or hashing asset
files. The snapshot is refreshed at library initialization and picker presentation and updated on
import, repair and deletion. External file changes appear at the next explicit refresh. Delivery
and Copy always reread original bytes and verify their digest; previews never authorize insertion.
The initial/explicit refresh remains synchronous and may affect opening latency for large libraries.

Fallback variant menus support arrow navigation by six-column rows, Return/Space submission of the
exact selected sequence, and Escape dismissal through the owning session. Modified keys retain
native handling. Obsolete native-animation presentation IDs and unused fallback assets are removed;
window attachment and Reduce Motion transitions own replay.

Context menus must not leave the picker open after an outside click. Local/global mouse-down
monitors supplement transient AppKit dismissal and are removed before panel closure. Picker and
visible auxiliary menu/child-window bounds remain interactive while clicks elsewhere close the
picker; closing is idempotent across menu, popover-delegate and monitor callbacks.

### Sidebar Settings and sticker management

Settings uses a resizable native macOS sidebar with General, Stickers, Genmoji and Accessibility
panels. The sidebar is always visible, without a toggle toolbar item. General owns shortcut
recording, selected-text prefill and a Clear Recent row with a trailing Clear button and confirmation.
Switching panels or leaving the window ends shortcut recording and resumes registration.
Accessibility shows permission status and the system-settings link; it has no storage section.

Settings → Stickers is a thumbnail gallery for saved images and photo stickers. Settings → Genmoji
is a separate gallery for items saved through Create Genmoji or explicitly imported there as adaptive
glyphs. Both use compact, frameless item galleries with 72-point artwork, centered titles, no type subtitles,
and selection-only highlighting. A compact header contains flexible search, Add Images or Create Genmoji,
and an icon-only clipboard import control. Add Images has no ellipsis. The galleries have no footer.
Copy, Rename, Favorite and confirmed Delete are available from item context menus. Delete on a selected
tile uses the multiselection; on an unselected tile it targets only that item.
Arrow, Shift-arrow and logical Command-C remain available with Caps Lock enabled.
The gallery has one keyboard focus owner. Native move commands advance the active item and
selection; if it disappears, a surviving selected item takes priority. Search editing, header
controls and sheets retain their own keyboard handling. Column counts and keyboard navigation adapt together to the available width. Stickers supports
image-file and clipboard import; Genmoji accepts adaptive glyphs from the clipboard and offers
Create Genmoji when available. The button has no ellipsis and supplies its current AppKit screen
rectangle at click time. The input caret anchor uses its horizontal midpoint and bottom edge, so
the native creator arrow is centered under the button while Settings remains visible.
Creating from Settings saves to the library without insertion into an external recipient.
Picker-origin creation orders out the owned Settings window before receiver activation, so a
previously open background Settings window cannot come forward. It retains its instance/page
and can be reopened explicitly; only Settings-origin creation keeps it visible. Repeated
creation requests cancel the prior capture session. Closing Settings prevents it from being reopened
by a later creator completion. There is no mixed-type filter or native-picker action.

Collection membership is persisted separately from payload type in optional library metadata.
Existing assets without this metadata remain in Stickers; adaptive format alone does not prove
Genmoji origin. Reimporting an existing glyph through Genmoji moves it into that collection without
changing its identity, bytes, favorites or history. Deletion also removes its collection membership.
The status menu contains only Open, Settings and Quit. Imports
retain originals and do not count as use or paste into the last recipient. Import reports partial
success, duplicate counts and actionable failures only when there are failures; successful imports
do not show a status footer. Original image content determines file type, not the extension. New file imports use the filename
without its final extension as the default title; existing user titles are not rewritten.
Missing/corrupt assets stay listed for deletion or reimport. Deletion removes local originals,
favorites and recent usage; clearing recent history retains saved assets. These changes do not
synchronize with or delete Apple's system sticker library.

File import uses the native chooser and scoped file access. Settings reuses the library's in-memory
preview/availability snapshot and existing integrity-checked copy transport. The status-menu import
command is removed; picker context actions remain shortcuts to the same saved library operations.

### Inline photo stickers

Static image selections now use a real adaptive-image-glyph representation for Copy and Paste,
matching the inline behavior of native photo stickers. The conversion decodes the original,
preserves orientation/aspect ratio on a transparent square canvas (maximum 512 px), and writes
HEIC with stable content identity and description metadata. The original asset remains unchanged
in local storage. Rich paste receives RTFD/glyph data; image-only recipients can negotiate the
high-resolution PNG/HTML fallback from the same clipboard item. Conversion occurs before clipboard mutation.
GIF and multi-frame images retain their original image transport and animation; unavailable HEIC
conversion also falls back to the validated original image instead of discarding the selection.

An adaptive glyph is not proof of AI generation: native photo stickers also use this format.
The picker labels its adaptive-glyph section and category Genmoji. This is a display label; captured
Genmoji and imported native stickers retain their original adaptive representation.
Settings separates Stickers and explicitly classified Genmoji rather than treating all glyphs as Genmoji.
The Create Genmoji action remains explicitly named for the system creation feature. Existing asset
IDs, original bytes, favorites and history remain intact; no library migration is required.

### Draggable picker

The native popover permits AppKit detachment. Dragging eligible native chrome/background detaches
the picker from its text-field anchor and allows it to move freely, including presentations without
a resolved text field. The same content, search state and captured insertion destination are retained.
A native window-drag gesture is confined to the empty 11-point strip above search so subsequent
moves remain available with SwiftUI content. Search editing and emoji/variant interactions remain
controls rather than drag handles. Outside-click
dismissal and idempotent teardown apply to the content’s current window, including detached windows.

### Saved-item names

Renaming a saved item updates its library title, favorite/preference references and recent-usage
titles while retaining the item ID, original asset reference and bytes, collection membership,
counts and usage timestamps. Names are trimmed and must be nonempty, single-line, and at most 256
UTF-16 code units; attachment replacement characters are rejected. Failed library metadata writes
leave the prior name and usage references intact. A rename does not modify an existing adaptive
glyph's embedded original description.

### Detached picker header

The detached header reserves a close-button slot and animates search into the remaining width,
keeping the close control and search vertically centered together. The header drag completes
native detachment through a runtime-signature-checked popover entry before applying detached chrome. Reduce Motion disables the
transition. The same native circled Close button is moved into an always-mounted header host when it can
be identified through the native window accessor or a unique accessibility close-button control.
Native-background dragging is handled while tracking, before AppKit's release-only detach callback.
Native-button suppression starts on initial presentation and detach preparation. Confirmed inset
state is independent of control readiness; host attachment, window migration, layout and drag events
reconcile a pending installation against the current, nonnil content window. Its artwork, native fitting size, target and action are preserved; there
is no custom-icon replacement. The control is hidden while it is reparented and initially laid out
against the actual search field’s vertical center. Once search has made space, the control fades in
over the quick motion interval,
with no fade under Reduce Motion. The reveal timer uses common run-loop modes so it can fire
during native mouse tracking; old host/window/button callbacks cannot reveal a superseded control. Any existing native button is hidden before detachment to avoid
showing its default position. Native detachment and reparenting suppress implicit layer animations. Search state and responder identity persist across detachment; attached picker geometry
remains unchanged.

### Verification scope

Automated tests cover models, persistence, search/navigation data, accessibility resolution and
clipboard/content transport. View/presentation and browser-rendering UI test suites are excluded.
Functional changes are verified in the real built app using the affected IDs in the maintained
[feature map](../../apps/EmojiMatch/Documentation/FeatureMap.md) and its
[verification guide](../../apps/EmojiMatch/Documentation/Verification.md). Native interaction tools
can drive those checks; build and unit-test results do not replace observing the user-visible outcome.

Favorite and per-family variant-preference writes return success to their callers. Settings reports
actionable save failures; picker actions beep without taking focus away from insertion. A failed
preference save does not prevent inserting the explicitly selected variant. Damaged metadata is
not overwritten.

### Default skin tone

General Settings offers six hand choices, yellow and the five Unicode skin tones, persisted by
AppSettings. Browse and search apply this default only to supplied, Apple-renderable variants
whose structure matches the base emoji after removing skin modifiers and variation selectors.
All present tone modifiers must match the selected default; unsupported or structurally different
variants leave the original item unchanged. Explicit per-family preferences, including yellow
and mixed tones, take precedence. Changing the default never rewrites favorites, recent usage,
original sequences or explicit family preferences, and yellow resets only the global default.

### Explicit Settings presentation

The status-menu Settings action is deferred to the default run-loop mode, after menu tracking ends.
It deminiaturizes and presents the existing Settings window, explicitly activates the app for this
user action, and makes Settings key/front after activation is confirmed. The initiating foreground
app is retained only to reject intervening app switches, not to assume cooperative activation.
Genmoji restoration remains a separate best-effort path guarded by foreground ownership. A bounded activation
wait revalidates the session, window visibility and foreground app; reopening the picker, closing
Settings or switching to another app prevents an old request from bringing Settings forward.
The Genmoji sidebar uses the Apple Intelligence symbol.
