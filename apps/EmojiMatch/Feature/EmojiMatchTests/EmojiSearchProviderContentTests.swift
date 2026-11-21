import AppKit
import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiSearchProviderContentTests {
  @Test func groupedSectionsKeepProviderOrderAndIndependentRanks() throws {
    try withStore { usage in
      let search = EmojiSearchStore()
      let content = EmojiMatchContent(
        query: "coffee", searchStore: search, usageStore: usage, catalog: catalog(),
        enabledSearchProviders: Set(EmojiSearchProvider.allCases),
        groupSearchResultsByProvider: true,
        providerResults: [
          result(.duckDuckGo, ["1F375", "2615"]), result(.luna, ["2615", "1F375"]),
          result(.multilingual, ["1FA81", "1F375"]),
          result(.miniLM, ["1F375", "2615", "1F375"])
        ])
      #expect(content.sections.map(\.title) == EmojiSearchProvider.allCases.map(\.title))
      #expect(
        content.sections.map(\.id) == EmojiSearchProvider.allCases.map { "provider:\($0.rawValue)" }
      )
      #expect(content.sections[1].items.map(\.selection.id) == ["1F375", "2615"])
      #expect(content.sections[2].items.map(\.selection.id) == ["1FA81", "1F375"])
      #expect(content.sections[3].items.map(\.selection.id) == ["2615", "1F375"])
      #expect(content.sections[4].items.map(\.selection.id) == ["1F375", "2615"])
      #expect(content.sections[0].items.first?.selection.id == "2615")
      #expect(content.navigationLayout.items == content.sections.flatMap(\.items))
      #expect(
        Set(content.navigationLayout.items.map(\.id)).count == content.navigationLayout.items.count)
    }
  }

  @Test func mixedContentCountsIndependentLocalProvidersAndFiltersDisabledEvidence() throws {
    try withStore { usage in
      let content = EmojiMatchContent(
        query: "unmatched phrase", searchStore: EmojiSearchStore(), usageStore: usage,
        catalog: catalog(), enabledSearchProviders: [.miniLM, .multilingual, .luna],
        providerResults: [
          result(.miniLM, ["1F375", "2615"]), result(.multilingual, ["2615"]),
          result(.luna, ["1FA81"]), result(.duckDuckGo, ["1FA81"])
        ])
      let ids = content.navigationLayout.items.map(\.selection.id)
      #expect(ids.first == "2615")
      #expect(Set(ids) == ["1F375", "2615", "1FA81"])
      #expect(ids.count == 3)
      #expect(content.sections.count == 1)
      #expect(content.sections.first?.id == "search")
    }
  }

  @Test func duplicateSelectionsRemainSeparatelyNavigableAcrossProviders() throws {
    try withStore { usage in
      let search = EmojiSearchStore()
      func content(_ results: [EmojiSearchProviderResult]) -> EmojiMatchContent {
        EmojiMatchContent(
          query: "unmatched phrase", searchStore: search, usageStore: usage, catalog: catalog(),
          enabledSearchProviders: [.miniLM, .luna], groupSearchResultsByProvider: true,
          providerResults: results)
      }
      let initial = content([result(.miniLM, ["2615", "2615"]), result(.luna, ["2615"])])
      let items = initial.navigationLayout.items
      #expect(items.count == 2)
      #expect(items[0].selection == items[1].selection)
      #expect(items[0].id != items[1].id)
      var navigation = EmojiMatchNavigationState()
      navigation.resetSelection(in: initial.navigationLayout)
      let moved = navigation.move(.down, in: initial.navigationLayout)
      #expect(moved)
      #expect(navigation.selectedItemID == items[1].id)
      #expect(navigation.resolvedSelection(in: initial.navigationLayout) == items[1].selection)
      let updated = content([result(.miniLM, ["1F375", "2615"]), result(.luna, ["2615", "1FA81"])])
      navigation.clampSelection(in: updated.navigationLayout)
      #expect(navigation.selectedItemID == items[1].id)
      #expect(navigation.resolvedSelection(in: updated.navigationLayout) == items[1].selection)
    }
  }

  @Test func groupedTonePreferencePreservesFamilyAndProviderIdentity() throws {
    try withStore { usage in
      let search = EmojiSearchStore()
      let catalog = catalog()
      let base = try #require(search.result(id: "1F44D"))
      let variant = try #require(catalog.variants(for: base.selection).first { $0.value == "👍🏿" })
      func content() -> EmojiMatchContent {
        EmojiMatchContent(
          query: "thumb", searchStore: search, usageStore: usage, catalog: catalog,
          enabledSearchProviders: [.miniLM, .luna], groupSearchResultsByProvider: true,
          providerResults: [result(.miniLM, [base.id, base.id]), result(.luna, [base.id])])
      }
      let originalIDs = content().navigationLayout.items.map(\.id)
      let defaultTone = EmojiMatchContent(
        query: "thumb", searchStore: search, usageStore: usage, catalog: catalog,
        defaultSkinTone: .dark, enabledSearchProviders: [.miniLM, .luna],
        groupSearchResultsByProvider: true,
        providerResults: [result(.miniLM, [base.id]), result(.luna, [base.id])])
      #expect(defaultTone.navigationLayout.items.map(\.id) == originalIDs)
      #expect(defaultTone.navigationLayout.items.allSatisfy { $0.selection == variant })
      usage.setPreferredSelection(variant, for: base.selection)
      let preferred = content()
      #expect(preferred.navigationLayout.items.map(\.id) == originalIDs)
      #expect(preferred.navigationLayout.items.count == 2)
      #expect(preferred.navigationLayout.items.allSatisfy { $0.selection == variant })
      #expect(preferred.navigationLayout.items.allSatisfy { $0.familyBase == base.selection })
      #expect(
        preferred.navigationLayout.items.allSatisfy { catalog.hasVariants(for: $0.selection) })
      for item in preferred.navigationLayout.items {
        var navigation = EmojiMatchNavigationState()
        navigation.selectItemID(item.id)
        #expect(navigation.resolvedSelection(in: preferred.navigationLayout) == variant)
      }
    }
  }

  @Test func disablingLexicalRemovesImportedSymbolsFuzzyAndExactBoost() throws {
    try withStore { usage in
      let search = EmojiSearchStore()
      let catalog = catalog()
      let imported = try importImage(into: usage, title: "coffee")
      for grouped in [false, true] {
        let content = EmojiMatchContent(
          query: "coffee", searchStore: search, usageStore: usage, catalog: catalog,
          enabledSearchProviders: [.miniLM], groupSearchResultsByProvider: grouped,
          providerResults: [result(.miniLM, ["1F375"]), result(.luna, ["2615"])])
        #expect(content.navigationLayout.items.map(\.selection.id) == ["1F375"])
        #expect(!content.navigationLayout.items.contains { $0.selection.id == imported.id })
        let noSources = EmojiMatchContent(
          query: "cofee", searchStore: search, usageStore: usage, catalog: catalog,
          enabledSearchProviders: [], groupSearchResultsByProvider: grouped,
          providerResults: [result(.miniLM, ["2615"])])
        #expect(noSources.navigationLayout.items.isEmpty)
        let exact = EmojiMatchContent(
          query: "☕", searchStore: search, usageStore: usage, catalog: catalog,
          enabledSearchProviders: [.miniLM], groupSearchResultsByProvider: grouped,
          providerResults: [result(.miniLM, ["1F375", "2615"])])
        #expect(exact.navigationLayout.items.map(\.selection.id) == ["1F375", "2615"])
      }
    }
  }

  @Test func lexicalGroupIncludesImportedCatalogAndSymbolMatches() throws {
    try withStore { usage in
      let imported = try importImage(into: usage, title: "coffee sticker")
      let content = EmojiMatchContent(
        query: "coffee", searchStore: EmojiSearchStore(), usageStore: usage, catalog: catalog(),
        enabledSearchProviders: [.lexical], groupSearchResultsByProvider: true)
      let section = try #require(content.sections.first)
      #expect(content.sections.count == 1)
      #expect(section.title == EmojiSearchProvider.lexical.title)
      #expect(section.items.first?.selection == imported)
      #expect(section.items.contains { $0.selection.id == "2615" })
      #expect(section.items.last?.selection.id == "symbol:coffee")
      #expect(section.items.allSatisfy { $0.id.hasPrefix("provider:lexical:") })
    }
  }

  @Test func groupedStatusesBelongToEnabledProvidersAndPreserveOtherResults() throws {
    try withStore { usage in
      let content = EmojiMatchContent(
        query: "zzzzzzzz", searchStore: EmojiSearchStore(), usageStore: usage, catalog: catalog(),
        enabledSearchProviders: [.lexical, .miniLM, .multilingual, .luna],
        groupSearchResultsByProvider: true,
        providerResults: [
          .init(provider: .miniLM, matches: [], isLoading: true),
          .init(provider: .multilingual, matches: [], failure: "Unavailable"),
          result(.luna, ["2615"]),
          .init(provider: .duckDuckGo, matches: [], failure: "Disabled failure")
        ])
      #expect(content.sections.count == 4)
      #expect(content.sections[0].status == "No results")
      #expect(content.sections[1].status == "Searching…")
      #expect(content.sections[2].status == "Unavailable")
      #expect(content.sections[3].status == nil)
      #expect(content.navigationLayout.items.map(\.selection.id) == ["2615"])
      let completed = EmojiMatchContent(
        query: "zzzzzzzz", searchStore: EmojiSearchStore(), usageStore: usage, catalog: catalog(),
        enabledSearchProviders: [.luna], groupSearchResultsByProvider: true,
        providerResults: [result(.luna, [])])
      #expect(completed.sections.first?.status == "No results")
    }
  }

  @Test func emptyQueryIgnoresProviderFlagsGroupingResultsAndStatuses() throws {
    try withStore { usage in
      let search = EmojiSearchStore()
      let catalog = catalog()
      for page in [0, 1] {
        let baseline = EmojiMatchContent(
          query: "", searchStore: search, usageStore: usage, catalog: catalog, page: page)
        let content = EmojiMatchContent(
          query: " \n", searchStore: search, usageStore: usage, catalog: catalog, page: page,
          enabledSearchProviders: [], groupSearchResultsByProvider: true,
          providerResults: [.init(provider: .miniLM, matches: [], isLoading: true)])
        #expect(content.sections.map(\.id) == baseline.sections.map(\.id))
        #expect(content.navigationLayout == baseline.navigationLayout)
        #expect(content.categories.map(\.id) == baseline.categories.map(\.id))
        #expect(content.sections.allSatisfy { $0.status == nil })
      }
    }
  }

  private func result(_ provider: EmojiSearchProvider, _ ids: [String]) -> EmojiSearchProviderResult
  {
    .init(
      provider: provider,
      matches: ids.enumerated()
        .map { index, id in
          EmojiSearchMatch(id: id, value: "", score: 1 / Double(index + 1), sourceURLs: [])
        })
  }

  private func catalog() -> EmojiBrowserCatalog {
    EmojiBrowserCatalog(
      loadEmojis: { try Emojis.fetch(filter: .apple) }, loadNativeCategories: { [] },
      loadSymbols: {
        [
          NativeSymbolCategory(
            id: "fixture", title: "Symbols", image: nil,
            entries: [.init(id: "symbol:coffee", value: "♨")],
            descriptionsByID: ["symbol:coffee": "coffee symbol"])
        ]
      })
  }

  private func importImage(into usage: EmojiUsageStore, title: String) throws -> EmojiSelection {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    return try usage.importImage(data: data, typeIdentifier: "public.png", description: title)
  }

  private func withStore(_ operation: (EmojiUsageStore) throws -> Void) throws {
    let suite = "EmojiSearchProviderContentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try operation(EmojiUsageStore(defaults: defaults, libraryDirectory: directory))
  }
}
