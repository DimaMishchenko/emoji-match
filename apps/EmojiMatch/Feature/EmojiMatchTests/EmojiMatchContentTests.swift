import AppKit
import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiMatchContentTests {
  @Test func textOnlyPolicyFiltersAllRichOccurrencesButPreservesStoredItems() throws {
    _ = NSApplication.shared
    try withStore { store in
      let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
      let glyph = NSAdaptiveImageGlyph(imageContent: try Data(contentsOf: fixture))
      let rich = try store.importAdaptiveGlyph(glyph)
      let unicode = EmojiSelection(id: "1F44D", value: "👍")
      for item in [rich, unicode] { store.toggleFavorite(item); store.record(item) }
      for query in ["", rich.value] {
        let content = EmojiMatchContent(
          query: query, searchStore: EmojiSearchStore(), usageStore: store, allowsRichContent: false
        )
        #expect(content.navigationLayout.items.allSatisfy { $0.selection.asset == nil })
        #expect(!content.categories.contains { ["genmoji", "imported"].contains($0.id) })
        #expect(content.sections.allSatisfy { $0.items.allSatisfy { $0.selection.asset == nil } })
      }
      #expect(store.favorites.contains(rich))
      #expect(store.importedSelections.contains(rich))
      let restored = EmojiMatchContent(
        query: "", searchStore: EmojiSearchStore(), usageStore: store)
      #expect(restored.navigationLayout.items.contains { $0.selection == rich })
    }
  }

  @Test func nativeCategoriesPreserveEveryInstalledBaseInExactOrder() throws {
    let native = try NativeSymbolCatalog.loadEmojiCategories()
    let catalog = EmojiBrowserCatalog.shared
    #expect(catalog.sections.map(\.id) == native.map(\.id))
    #expect(catalog.sections.map { $0.items.map(\.selection.value) } == native.map(\.values))
    #expect(catalog.sections.count == 8)
    #expect(catalog.items.count == 1873)
    #expect(catalog.items.filter { $0.familyBase == nil }.map(\.selection.value).isEmpty)
    #expect(catalog.categoryImages.count == 15)
  }

  @Test func canonicalCatalogFallbackRetainsAllSupportedBases() throws {
    let emojis = try Emojis.fetch(filter: .apple).filter { $0.group != .component }
    let catalog = EmojiBrowserCatalog(
      loadEmojis: { emojis }, loadNativeCategories: { throw CocoaError(.fileReadUnknown) },
      loadSymbols: { [] })
    #expect(catalog.loadError == nil)
    #expect(catalog.sections.count == 8)
    #expect(catalog.items.count == emojis.count)
    #expect(Set(catalog.items.map(\.selection.id)) == Set(emojis.map { $0.id.rawValue }))
  }

  @Test func nativePresentationPreservesSequenceAndCanonicalPreferenceIdentity() throws {
    let emoji = try #require(
      Emojis.fetch(filter: .apple).first { $0.id.rawValue == "2764-FE0F" || $0.value == "❤️" })
    let catalog = EmojiBrowserCatalog(
      loadEmojis: { [emoji] },
      loadNativeCategories: {
        [NativeEmojiCategory(id: "native", title: "Native", image: nil, values: ["❤"])]
      },
      loadSymbols: { [] })
    let item = try #require(catalog.items.first)
    #expect(item.selection.value.unicodeScalars.map(\.value) == [0x2764])
    #expect(item.selection.id == emoji.id.rawValue)
    #expect(item.familyBase?.id == emoji.id.rawValue)
    #expect(catalog.base(for: item.selection)?.id == emoji.id.rawValue)
  }

  @Test func footerPagesRetainEmptyRecentAndNativeSymbolDescriptions() throws {
    try withStore { store in
      let catalog = EmojiBrowserCatalog.shared
      let search = EmojiSearchStore()
      let emoji = EmojiMatchContent(query: "", searchStore: search, usageStore: store)
      #expect(emoji.categories.count == 11)
      #expect(emoji.categories.prefix(3).map(\.id) == ["imported", "genmoji", "recent"])
      #expect(emoji.categories.prefix(3).allSatisfy { $0.firstItemID == nil })
      let symbols = EmojiMatchContent(query: "", searchStore: search, usageStore: store, page: 1)
      #expect(symbols.sections.map(\.id) == catalog.symbolSections.map(\.id))
      #expect(symbols.categories.map(\.id) == symbols.sections.map(\.id))
      #expect(symbols.navigationLayout.items.count == 827)
      let command = try #require(symbols.navigationLayout.items.first { $0.selection.value == "⌘" })
      #expect(command.accessibilityLabel == "PLACE OF INTEREST SIGN")
      let result = EmojiMatchContent(
        query: "place of interest", searchStore: search, usageStore: store)
      #expect(result.navigationLayout.items.contains { $0.selection == command.selection })
      #expect(result.categories.map(\.id) == emoji.categories.map(\.id))
      let symbolSearch = EmojiMatchContent(
        query: "hand", searchStore: search, usageStore: store, page: 1)
      #expect(symbolSearch.categories.map(\.id) == symbols.categories.map(\.id))
      #expect(symbolSearch.navigationLayout.items.contains { $0.selection.value == "✋" })
    }
  }

  @Test func variantsPreserveSuppliedIdentityAndUnequalTones() throws {
    let catalog = EmojiBrowserCatalog.shared
    let supplied = try #require(Emojis.fetch(filter: .apple).first { $0.id.rawValue == "1F91D" })
    let base = EmojiSelection(id: supplied.id.rawValue, value: supplied.value)
    let variants = catalog.variants(for: base)
    let unequal = try #require(variants.first { $0.id == "1FAF1-1F3FB-200D-1FAF2-1F3FF" })
    #expect(unequal.value == "🫱🏻‍🫲🏿")
    #expect(variants.first == base)
    #expect(Set(variants.map(\.id)).count == variants.count)
    for variant in variants.dropFirst() {
      #expect(
        supplied.skinToneVariants.contains {
          $0.id.rawValue == variant.id && $0.value == variant.value
        })
      #expect(catalog.base(for: variant) == base)
    }
    #expect(catalog.variants(for: unequal) == variants)
  }

  @Test func sameTonesInDifferentSuppliedGenderAlternativesRemainDistinct() throws {
    let catalog = EmojiBrowserCatalog.shared
    let people = EmojiSelection(id: "1F9D1-200D-1F91D-200D-1F9D1", value: "🧑‍🤝‍🧑")
    let couple = EmojiSelection(id: "1F46B", value: "👫")
    let first = try #require(catalog.variants(for: people).first { $0.value == "🧑🏻‍🤝‍🧑🏿" })
    let second = try #require(catalog.variants(for: couple).first { $0.value == "👩🏻‍🤝‍👨🏿" })
    #expect(first.id != second.id)
    #expect(catalog.base(for: first) == people)
    #expect(catalog.base(for: second) == couple)
  }

  @Test func familyPreferenceChangesCatalogSelectionButKeepsExactFavoriteAndRecent() throws {
    try withStore { store in
      let catalog = EmojiBrowserCatalog.shared
      let original = try #require(catalog.items.first { $0.selection.id == "1F44D" })
      let variant = try #require(
        catalog.variants(for: original.selection).first { $0.value == "👍🏿" })
      store.record(original.selection)
      store.toggleFavorite(original.selection)
      store.setPreferredSelection(variant, for: original.selection)
      let content = EmojiMatchContent(query: "", searchStore: EmojiSearchStore(), usageStore: store)
      #expect(content.sections.first { $0.id == "favorites" }?.items.first?.selection.value == "👍")
      #expect(content.sections.first { $0.id == "recent" }?.items.first?.selection.value == "👍")
      let preferred = try #require(content.navigationLayout.items.first { $0.id == original.id })
      #expect(preferred.selection.id == variant.id)
      #expect(preferred.selection.value == variant.value)
      #expect(preferred.familyBase == original.selection)
      store.setPreferredSelection(original.selection, for: original.selection)
      #expect(catalog.preferredItem(original, usageStore: store).selection.value == "👍")
    }
  }

  @Test func displaySectionsAndNavigationShareAllSearchResultsAndImportedPayload() throws {
    try withStore { store in
      let bitmap = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      let imported = try store.importImage(
        data: data, typeIdentifier: "public.png", description: "Smiling nebula")
      let search = EmojiSearchStore()
      let broadResults = search.results(for: "face")
      let broadContent = EmojiMatchContent(query: "face", searchStore: search, usageStore: store)
      #expect(broadResults.count > 24)
      #expect(
        broadContent.navigationLayout.items.filter { !$0.selection.id.hasPrefix("symbol:") }
          .map(\.selection.id) == broadResults.map(\.id))
      #expect(broadContent.navigationLayout.items == broadContent.sections.flatMap(\.items))
      let content = EmojiMatchContent(query: "smiling", searchStore: search, usageStore: store)
      let displayed = content.sections.flatMap(\.items)
      #expect(content.navigationLayout.items == displayed)
      #expect(
        displayed.filter { !$0.selection.id.hasPrefix("symbol:") }.count
          == search.results(for: "smiling").count + 1)
      let item = try #require(displayed.first { $0.selection.id == imported.id })
      #expect(item.selection.asset == imported.asset)
      #expect(item.selection.value == "Smiling nebula")
      var navigation = EmojiMatchNavigationState()
      navigation.selectItemID(item.id)
      #expect(navigation.resolvedSelection(in: content.navigationLayout)?.asset == imported.asset)
      store.toggleFavorite(imported)
      store.record(imported)
      let browse = EmojiMatchContent(query: "", searchStore: search, usageStore: store)
      #expect(browse.navigationLayout.items == browse.sections.flatMap(\.items))
      #expect(browse.sections.prefix(3).map(\.id) == ["favorites", "recent", "imported"])
      #expect(
        Set(browse.navigationLayout.items.map(\.id)).count == browse.navigationLayout.items.count)
    }
  }

  @Test func variantOfferRejectsMissingGlyphsAndDecomposedSequences() throws {
    let original = try #require(Emojis.fetch(filter: .apple).first { $0.id.rawValue == "1F44D" })
    let emoji = Emoji(
      id: original.id, value: original.value, group: original.group, subgroup: original.subgroup,
      unicodeVersion: original.unicodeVersion, sortOrder: original.sortOrder,
      skinToneSupport: .single,
      skinToneVariants: [
        .init(id: .init(rawValue: "valid"), value: "👍🏻", tones: [.light]),
        .init(id: .init(rawValue: "missing"), value: "\u{10FFFF}", tones: [.dark]),
        .init(id: .init(rawValue: "decomposed"), value: "👍🏻👍🏿", tones: [.light, .dark])
      ], localization: original.localization
    )
    let catalog = EmojiBrowserCatalog(loadEmojis: { [emoji] })
    let base = EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
    #expect(catalog.variants(for: base).map(\.id) == [base.id, "valid"])
    #expect(catalog.variants(for: base).map(\.value) == ["👍", "👍🏻"])
  }

  @Test func failedCatalogLoadCanRetry() throws {
    let retry = RetryState()
    let emojis = try Emojis.fetch(filter: .apple)
    let catalog = EmojiBrowserCatalog(loadEmojis: {
      if retry.shouldFail { throw CocoaError(.fileReadCorruptFile) }
      return emojis
    })
    #expect(catalog.loadError != nil)
    #expect(catalog.items.isEmpty)
    retry.shouldFail = false
    catalog.reload()
    #expect(catalog.loadError == nil)
    #expect(!catalog.items.isEmpty)
  }
}

private func withStore(_ operation: (EmojiUsageStore) throws -> Void) throws {
  let suite = "EmojiMatchContentTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
  try operation(EmojiUsageStore(defaults: defaults, libraryDirectory: directory))
}

@MainActor
private final class RetryState {
  var shouldFail = true
}
