import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiWebSearchContentTests {
  @Test func lexicalOnlyContentPreservesSubstringBeforeTypo() throws {
    try withUsageStore { usage in
      let rows = [("1F375", "🍵", "decafcofee"), ("2615", "☕", "coffee")]
      let search = EmojiSearchStore(
        searchIndex: SearchIndex(
          availableLocaleIdentifiers: ["en"],
          entries: rows.map { id, value, name in
            SearchIndex.Entry(
              id: .init(rawValue: id), value: value, skinToneSupport: .none,
              skinToneVariants: [],
              localizations: [.init(localeIdentifier: "en", name: name, searchTokens: [])])
          }), preferredLocaleIdentifier: "en")
      let expected = search.results(for: "cofee").map(\.id)
      #expect(expected == ["1F375", "2615"])
      let content = EmojiMatchContent(query: "cofee", searchStore: search, usageStore: usage)
      #expect(content.sections.flatMap(\.items).map(\.selection.id) == expected)
    }
  }

  @Test func partialSentenceTokensDoNotDisplaceSemanticCandidates() throws {
    try withUsageStore { usage in
      let search = EmojiSearchStore()
      let query = "A paper kite, in a breeze!"
      let kite = try #require(search.result(id: "1FA81"))
      let parachute = try #require(search.result(id: "1FA82"))
      let content = EmojiMatchContent(
        query: query, searchStore: search, usageStore: usage,
        enabledSearchProviders: [.lexical, .miniLM],
        providerResults: [.init(provider: .miniLM, matches: matches([kite, parachute]))])
      let ids = content.sections.flatMap(\.items).map(\.selection.id)
      #expect(Array(ids.prefix(2)) == [kite.id, parachute.id])
      #expect(search.results(for: query).allSatisfy { ids.contains($0.id) })
      #expect(Set(ids).count == ids.count)
    }
  }

  @Test func semanticAndOnlineResultsCannotDisplaceAnExactGlyph() throws {
    try withUsageStore { usage in
      let search = EmojiSearchStore()
      let tea = try #require(search.result(id: "1F375"))
      let coffee = try #require(search.result(id: "2615"))
      let catalog = EmojiBrowserCatalog(
        loadEmojis: { try Emojis.fetch(filter: .apple) },
        loadNativeCategories: { [] }, loadSymbols: { [] })
      let content = EmojiMatchContent(
        query: coffee.value, searchStore: search, usageStore: usage, catalog: catalog,
        enabledSearchProviders: [.lexical, .miniLM, .luna],
        providerResults: [
          .init(provider: .miniLM, matches: matches([tea, coffee])),
          .init(provider: .luna, matches: matches([tea]))
        ])
      let selections = content.sections.flatMap(\.items).map(\.selection)
      #expect(selections.first?.id == coffee.id)
      #expect(selections.dropFirst().first?.id == tea.id)
      #expect(Set(selections.map(\.id)).count == selections.count)
    }
  }

  @Test func corroboratedLocalMatchPrecedesUnsupportedOnlineWithoutDuplicateFamilies() throws {
    try withUsageStore { usage in
      let search = EmojiSearchStore()
      let tea = try #require(search.result(id: "1F375"))
      let coffee = try #require(search.result(id: "2615"))
      let catalog = EmojiBrowserCatalog(
        loadEmojis: { try Emojis.fetch(filter: .apple) },
        loadNativeCategories: { [] }, loadSymbols: { [] })
      let content = EmojiMatchContent(
        query: "coffee", searchStore: search, usageStore: usage, catalog: catalog,
        enabledSearchProviders: [.lexical, .luna],
        providerResults: [.init(provider: .luna, matches: matches([tea, coffee, tea]))])
      let selections = content.sections.flatMap(\.items).map(\.selection)
      #expect(Array(selections.prefix(2)).map(\.id) == [coffee.id, tea.id])
      #expect(Set(selections.map(\.id)).count == selections.count)
      #expect(content.navigationLayout.items.first?.selection.id == coffee.id)
      #expect(
        search.results(for: "coffee")
          .allSatisfy { result in
            selections.contains { $0.id == result.id }
          })
    }
  }

  @Test func clearingQueryReturnsToCatalogWithoutRemoteItems() throws {
    try withUsageStore { usage in
      let search = EmojiSearchStore()
      let catalog = EmojiBrowserCatalog(
        loadEmojis: { try Emojis.fetch(filter: .apple).prefix(3).map { $0 } },
        loadNativeCategories: { [] }, loadSymbols: { [] })
      let content = EmojiMatchContent(
        query: "", searchStore: search, usageStore: usage, catalog: catalog,
        enabledSearchProviders: [.lexical, .luna],
        providerResults: [
          .init(provider: .luna, matches: matches([try #require(search.result(id: "2615"))]))
        ])
      #expect(!content.sections.contains { $0.id == "search" })
      #expect(!content.navigationLayout.items.contains { $0.selection.id == "2615" })
    }
  }

  private func matches(_ results: [EmojiSearchResult]) -> [EmojiSearchMatch] {
    results.enumerated()
      .map { index, result in
        EmojiSearchMatch(
          id: result.id, value: result.value, score: 1 / Double(index + 1), sourceURLs: [])
      }
  }

  private func withUsageStore(_ operation: (EmojiUsageStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("emoji-match-web-content-\(UUID().uuidString)")
    let suite = "EmojiMatchWebContentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try operation(
      EmojiUsageStore(defaults: defaults, storageKey: "history", libraryDirectory: directory))
  }
}
