# Emoji Match feature map

Inventory of implemented macOS capabilities, independent of a test framework. Stable IDs identify
entry points and observable acceptance outcomes; inclusion does not claim verification on every
recipient app or macOS version. The [working spec](../../../docs/specs/emoji-match-spec.md) also
contains planned behavior; this map describes the implemented app.

For functional changes, select affected IDs and dependent flows, then follow
[real-app verification](Verification.md). Update changed entries in the same change, preserving IDs.
These are current acceptance instructions, not a verification report.

## Opening and presentation

Owners: [app composition](../AppSources/App.swift),
[shortcut monitor](../AppSources/System/SystemShortcutMonitor.swift),
[destination capture](../AppSources/System/InsertionDestination.swift),
[anchor resolution](../Feature/AccessibilitySupport/Sources/Public/TextAnchorResolver.swift).

| ID | Capability / entry point | Observable outcome |
| --- | --- | --- |
| OPEN-01 | Menu bar → Open; configured global shortcut | Opens one picker with search ready for typing; repeated opening replaces the prior session and captures the intended recipient. Verify shortcut takeover and restoration through the actual system path. |
| OPEN-02 | Open with selected text; General → selected-text prefill toggle | Enabled prefill uses accessible selected text only for this lookup; disabled/unavailable selection starts empty. Opening alone does not edit the recipient. |
| OPEN-03 | Open at a text anchor or without an available anchor | Anchored presentation follows the resolved text location; missing anchors use the fallback panel. Dragging the top strip or the native header background detaches/moves the picker; the detached header moves the same native circled Close button into a vertically centered slot while search animates aside, without swapping icons. The same circled control is laid out against the actual search field before a short fade-in; Reduce Motion skips the fade. Control placement recovers after host/window migration, and native held-drag tracking shows no default-position X. Both paths remain searchable and dismissible. |

Presentation owners: [panel](../AppSources/UI/EmojiMatchPanel.swift),
[picker/header](../AppSources/UI/EmojiMatchView.swift),
[metrics](../AppSources/UI/EmojiPickerMetrics.swift).

## Finding and choosing

Owners: [browser](../AppSources/UI/BrowserView.swift),
[content](../AppSources/UI/EmojiMatchContent.swift),
[catalog](../AppSources/UI/EmojiMatchItem.swift),
[picker keyboard handling](../AppSources/UI/EmojiMatchView.swift),
[search field](../AppSources/UI/NativeEmojiSearchField.swift).

| ID | Capability / entry point | Observable outcome |
| --- | --- | --- |
| FIND-01 | Empty-query browser → category buttons and page controls | Catalog, Recents, Favorites and available custom content have visible, accessible section headings (including Genmoji) and remain browsable; changing category/page shows the corresponding items and keeps selection valid. |
| FIND-02 | Type/edit/clear a search query | Bundled multilingual names/keywords, derived shortcodes and maintained aliases produce source-aware local results; complete bounded typo/transposition matches precede partial matches, while categories and legacy extensions remain weak evidence and cannot suppress stronger authoritative corrections; changing the query resets selection appropriately. Empty/no-match states remain usable; clearing returns to browsing. |
| FIND-03 | Search/grid → arrows, Return, Escape | Down at the end of search enters result navigation; arrows move selection, Return submits the selected result. Escape clears a nonempty query before closing an empty-query picker. Normal text editing and marked-text composition retain their keyboard behavior. |
| FIND-04 | Supported item → variants by hold/context menu or Space during grid navigation | Available skin-tone/combined variants can be selected or cancelled. Choosing inserts the chosen variant and saves its preference for subsequent browsing. |
| FIND-05 | Settings → Search → independent source switches and grouped results; then type/edit/clear | Enabled names/keywords appear immediately; on-device query detection selects bundled MiniLM for English or explicitly installed E5 for other/uncertain languages after 50 ms, subject to each model’s switch. Missing E5 offers an explicit download action; no download starts from typing. Interface locale does not select the model. Enabled Luna and Web Search (DuckDuckGo) run separately after 300 ms. Mixed view protects exact lexical matches and fuses strong lexical, MiniLM, E5, Luna and web rank lists with stable ties; weak lexical matches remain at the tail. Grouped view shows only the applicable enabled local model, preserves each source order in labeled sections, permits cross-provider duplicate emoji with distinct navigation identities, and shows per-source status. Disabling a source removes its results and work; empty-query browsing is unchanged. Web Search extracts ten rows with images/media/fonts blocked and no automated challenge bypass. Provider input is bounded to 2,000 Unicode scalars/8,000 UTF-8 bytes before trimming or cache/model work. DDG independently prioritizes query-associated evidence over contextual lists and loose title samples; unanchored prose cannot vote solely because the title matches. It reuses MiniLM for guarded English candidate reranking only when MiniLM is enabled. Clear/dismiss cancels all searches; stale results and statuses are hidden by query/locale identity. Each model caches 64 queries for five minutes per picker. Injected tests do not count as live evidence. |

Variant owners: [cell actions](../AppSources/UI/EmojiMatchCell.swift),
[native variants](../AppSources/UI/NativeEmojiVariants.swift),
[skin-tone menu](../AppSources/UI/NativeSkinToneMenu.swift).

## Insertion and clipboard

Owners: [delivery coordination](../AppSources/App.swift),
[destination](../AppSources/System/InsertionDestination.swift),
[recipient policy](../AppSources/System/RecipientContentPolicy.swift),
[paste/copy transactions](../AppSources/System/TextPasteController.swift),
[rich paste command](../AppSources/System/RecipientPasteCommand.swift).

| ID | Capability / entry point | Observable outcome |
| --- | --- | --- |
| SEND-01 | Choose Unicode emoji by click or Return | Picker closes and the captured, still-valid recipient receives the exact emoji at its intended selection/caret. Invalid or changed destinations do not receive a stale insertion. Observe recipient content; posted events alone do not prove consumption. |
| SEND-02 | Choose imported sticker or adaptive glyph for a rich recipient | A compatible recipient receives the intended inline image/glyph rather than its title or a file path. Identified Terminal, web-search fields and inputs explicitly exposing source-code textual context offer Unicode-only content; unknown recipients remain eligible, without a compatibility guarantee. Failed delivery remains distinguishable from successful insertion. |
| SEND-03 | Item context menu/Settings → Copy; automatic paste restoration | Explicit Copy leaves the selected payload on the clipboard. Automatic paste restores the prior snapshot only while it owns the clipboard; an intervening copy survives. Failed writes/delivery do not silently replace unrelated clipboard contents. |

Image transport owner: [inline sticker conversion](../AppSources/System/InlineStickerImage.swift).
Native fields can temporarily report their window as focused while the picker is open. Restoration
may reassert the captured writable field only in the same window with a concrete, unchanged selection;
another field, window or application prevents recovery. Full destination validation still precedes
clipboard mutation. Verify both an empty native search field and ordinary document editors.
Finder fields, plain TextEdit and unknown rich editors need recipient-specific checks; a successful
rich TextEdit fixture or model test does not establish those outcomes. Record unverified or blocked
recipients explicitly rather than treating unknown policy assessment as confirmed rich support.

## Local library and history

Owners: [usage store](../AppSources/Usage/EmojiUsageStore.swift),
[library storage](../AppSources/Usage/EmojiLibraryStorage.swift),
[import decoding](../AppSources/System/RichContentImport.swift),
[library model](../AppSources/Settings/StickerLibraryModel.swift),
[library Settings](../AppSources/Settings/StickerLibrarySettingsView.swift).

| ID | Capability / entry point | Observable outcome |
| --- | --- | --- |
| LIB-01 | Settings → Stickers → Add Images / Import from Clipboard; Genmoji → Import from Clipboard | Supported originals are copied into the local library; partial failures report imported, duplicate and failed counts with recovery guidance; successful imports do not add status chrome. Genmoji accepts original adaptive glyphs, with ordinary images directed to Stickers. Imported file titles omit the extension by default; originals remain untouched. |
| LIB-02 | Settings → Stickers/Genmoji → search and select | Separate collections show compact frameless 72-point previews with titles. Search, mouse selection, Command multiselection, arrow/Shift-arrow navigation and context-menu Copy/Rename/Favorite/Delete operate on the intended items; there is no gallery footer. Delete on a selected tile applies to the multiselection; otherwise it applies only to that tile. Missing originals are visible. |
| LIB-03 | Library item → Rename | Nonempty names update the displayed/searchable title while preserving asset identity, favorites and history references. Cancelling or an invalid name does not change the item. |
| LIB-04 | Picker/library item → favorite, remove from Recents, delete custom item | Favorites update across picker and Settings. Removing a recent preserves its saved original; deleting a saved asset removes its library/favorite/history references. Settings deletion requires confirmation; failures remain visible. |
| LIB-05 | Successful delivery; General → Clear Recent; restart | Usage is recorded after a paste operation is accepted for dispatch, without claiming recipient consumption. Local recents/preferences/favorites/library survive restart; confirmed Clear Recent removes history while retaining saved items and favorites. |

## Genmoji and Settings

Owners: [native Genmoji](../AppSources/Genmoji/NativeGenmoji.swift),
[Genmoji capture](../AppSources/Genmoji/GenmojiCaptureSession.swift),
[app routing](../AppSources/App.swift),
[Settings](../AppSources/Settings/EmojiMatchSettingsView.swift),
[screen anchor button](../AppSources/Settings/ScreenAnchoredButton.swift).

| ID | Capability / entry point | Observable outcome |
| --- | --- | --- |
| SET-04 | Menu bar → Settings, including an inactive or minimized Settings window | After menu tracking ends, Settings becomes the active key/front window. Superseded requests, closure or an intervening app switch prevent delayed focus stealing. The Genmoji sidebar uses Apple Intelligence artwork. |
| GEN-01 | Eligible picker → Genmoji button | Available native creation opens with the current query/anchor and the same 320×480 content size as the picker. Picker-origin creation hides owned Settings before activation so a background Settings window does not come forward. Captured original is saved and delivered to the captured recipient; cancellation/error restores the appropriate focus without inserting stale content. Unavailable or Unicode-only destinations do not expose creation. |
| GEN-02 | Settings → Genmoji → Create Genmoji | Label has no ellipsis. Each click supplies the current AppKit button rectangle, including after moving/resizing Settings. The popover arrow aligns with the button’s horizontal center; Settings stays visible, capture updates its library without pasting into another app, and cancellation/failure leaves Settings usable. |
| SET-01 | Settings → General → record/reset shortcut and prefill | Valid modified shortcuts and prefill preference persist. Recording suspends the global trigger, stops on cancellation/focus loss/navigation, and reports invalid or failed registration; Reset restores the default shortcut. |
| SET-05 | Settings → Search → five provider switches, Group results by provider, Luna Save/Remove Key | Names & Keywords, MiniLM and E5 default on; Luna, Web Search and grouping default off. The compact form reveals key entry/save only when Luna is enabled; a saved key remains removable while disabled. The applicable enabled local model runs per query, while both online providers may run together; the UI explains language routing, query transmission including selected-text prefill, Luna billing, Web Search’s DuckDuckGo attribution, separate persistent WebKit profile and cooldowns. Only Luna uses Keychain. Grouping changes layout only and permits repeated emoji across providers. Reopen the picker to apply changes. E5 offers an explicit ~235 MB GitHub ZIP download, progress, Cancel, Remove and retry after failure; source plus compiled resources occupy ~575 MB and work offline after installation. Downloading sends no query; a pinned descriptor validates archive and exact file identities. Disabling MiniLM also disables web candidate reranking. One provider failure preserves other enabled sources. Typed recovery offers Settings, Retry, wait or query editing. The app-owned Luna gate spaces dispatches and retains rejected-key/cooldown state across picker presentations; explicit Retry-After deadlines are respected. |
| SET-03 | Settings → General → Default skin tone | Six hand choices persist: yellow plus five skin tones. Browse/search use supported supplied variants of the same emoji structure. Explicit per-emoji choices, including yellow, override the default; favorites/recents retain exact sequences. |
| SET-02 | Settings → Accessibility → status/system Settings | Granted/not-granted status reflects access when returning to the app. The action opens the correct macOS permission pane; denial/unavailable focused text remains distinguishable from verified positioning/insertion. |

## Acceptance dimensions

Apply relevant dimensions to the affected IDs: light/dark appearance, Reduce Motion, accessible
labels and keyboard focus, long titles, resizing, permission state, cold/warm launch, and local
storage/import failures. Nonactivating picker behavior may leave the recipient frontmost while
Emoji Match owns search input; frontmost application alone is not a focus failure.
