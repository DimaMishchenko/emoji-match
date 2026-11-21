import Foundation

struct EmojiMatchContent {
  struct Section: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let items: [EmojiMatchItem]
    var status: String? = nil
    var opensSettings = false
    var downloadsModel = false
    var cancelsModel = false
  }

  struct Category: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let firstItemID: String?
  }

  let sections: [Section]
  let categories: [Category]

  var navigationLayout: EmojiMatchNavigationLayout {
    EmojiMatchNavigationLayout(
      rows: sections.flatMap {
        EmojiMatchNavigationLayout(items: $0.items, columnCount: EmojiPickerMetrics.columnCount)
          .rows
      }
    )
  }

  init(
    query: String, searchStore: EmojiSearchStore, usageStore: EmojiUsageStore,
    catalog: EmojiBrowserCatalog = .shared, page: Int = 0, allowsRichContent: Bool = true,
    defaultSkinTone: DefaultSkinTone = .yellow,
    enabledSearchProviders: Set<EmojiSearchProvider> = [.lexical],
    groupSearchResultsByProvider: Bool = false,
    configuredSearchProviders: Set<EmojiSearchProvider>? = nil,
    providerResults: [EmojiSearchProviderResult] = [],
    canDownloadMultilingualModel: Bool = false,
    canCancelMultilingualModel: Bool = false
  ) {
    categories = Self.categories(
      catalog: catalog, usageStore: usageStore, page: page, allowsRichContent: allowsRichContent)
    guard let query = EmojiSearchInput.normalized(query) else {
      sections = [
        Section(
          id: "search", title: "", symbolName: "magnifyingglass", items: [],
          status: "Search is too long. Use up to 2,000 characters.")
      ]
      return
    }
    if !query.isEmpty {
      if enabledSearchProviders.isEmpty {
        let configured = configuredSearchProviders ?? enabledSearchProviders
        sections = [
          Section(
            id: "search", title: "", symbolName: "magnifyingglass", items: [],
            status: configured.isEmpty
              ? "Search sources are turned off."
              : "Turn on the language model for this query in Search settings.",
            opensSettings: true)
        ]
        return
      }
      let lexicalEnabled = enabledSearchProviders.contains(.lexical)
      let imported = (lexicalEnabled && allowsRichContent ? usageStore.importedSelections : [])
        .filter {
          $0.value
            .folding(
              options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
              locale: .current
            )
            .contains(
              query.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current))
        }
        .map {
          EmojiMatchItem(id: "search:\($0.id)", selection: $0, accessibilityLabel: $0.value)
        }
      let lexical = lexicalEnabled ? searchStore.results(for: query) : []
      let providers = providerResults.filter {
        $0.provider != .lexical && enabledSearchProviders.contains($0.provider)
      }
      func cancelsModel(_ result: EmojiSearchProviderResult?) -> Bool {
        canCancelMultilingualModel && result?.provider == .multilingual
          && result?.progressMessage != nil
      }
      func downloadsModel(_ result: EmojiSearchProviderResult?) -> Bool {
        canDownloadMultilingualModel && result?.provider == .multilingual
          && result?.issue?.kind == .modelNotInstalled
      }
      func items(for ids: [String], deduplicateFamilies: Bool = false) -> [EmojiMatchItem] {
        var seen = Set<String>()
        return ids.compactMap { id in
          guard let result = searchStore.result(id: id) else { return nil }
          var item = EmojiMatchItem.searchResult(result)
          item.familyBase = catalog.base(for: item.selection)
          let identity = deduplicateFamilies ? item.familyBase?.id ?? result.id : result.id
          guard seen.insert(identity).inserted else { return nil }
          return catalog.preferredItem(
            item, usageStore: usageStore, defaultSkinTone: defaultSkinTone)
        }
      }
      let symbols = (lexicalEnabled ? catalog.symbolSections.flatMap(\.items) : [])
        .filter {
          $0.accessibilityLabel.localizedStandardContains(query)
            || $0.selection.value.contains(query)
        }
        .map { item in
          EmojiMatchItem(
            id: "search:\(item.id)", selection: item.selection,
            accessibilityLabel: item.accessibilityLabel)
        }
      if groupSearchResultsByProvider {
        sections = EmojiSearchProvider.allCases.filter { enabledSearchProviders.contains($0) }
          .map { provider in
            let result = providers.first { $0.provider == provider }
            let sourceItems =
              provider == .lexical
              ? imported + items(for: lexical.map(\.id), deduplicateFamilies: true) + symbols
              : items(for: result?.matches.map(\.id) ?? [], deduplicateFamilies: true)
            var seen = Set<String>()
            let namespacedItems = sourceItems.filter { seen.insert($0.selection.id).inserted }
              .map { item in
                EmojiMatchItem(
                  id: "provider:\(provider.rawValue):\(item.id)", selection: item.selection,
                  accessibilityLabel: item.accessibilityLabel, familyBase: item.familyBase)
              }
            let status: String?
            if let progress = result?.progressMessage {
              status = progress
            } else if provider != .lexical
              && (result == nil || result?.isPending == true || result?.isLoading == true)
            {
              status = "Searching…"
            } else if let failure = result?.failure {
              status = failure
            } else if namespacedItems.isEmpty {
              status = "No results"
            } else {
              status = nil
            }
            return Section(
              id: "provider:\(provider.rawValue)", title: provider.title,
              symbolName: "magnifyingglass", items: namespacedItems, status: status,
              opensSettings: result?.issue?.recovery == .settings && !downloadsModel(result),
              downloadsModel: downloadsModel(result), cancelsModel: cancelsModel(result))
          }
      } else {
        let hasProviderMatches = providers.contains { !$0.matches.isEmpty }
        let fusedIDs =
          hasProviderMatches
          ? EmojiSearchFusion.rankedIDs(
            exactIDs: lexicalEnabled ? searchStore.exactResults(for: query).map(\.id) : [],
            lexicalIDs: lexicalEnabled ? searchStore.strongResults(for: query).map(\.id) : [],
            providers: providers)
          : lexical.map(\.id)
        let mixedItems = imported + items(for: fusedIDs + lexical.map(\.id)) + symbols
        let progress = providers.first { $0.progressMessage != nil }
        let waiting = providers.contains {
          $0.isPending || $0.isLoading || $0.progressMessage != nil
        }
        let failed = providers.first { $0.failure != nil }
        let status: String?
        if mixedItems.isEmpty && waiting {
          status = progress?.progressMessage ?? "Searching…"
        } else if mixedItems.isEmpty, let failed, let failure = failed.failure {
          status = "\(failed.provider.title): \(failure)"
        } else {
          status = nil
        }
        var mixedSections = [
          Section(
            id: "search", title: "", symbolName: "magnifyingglass", items: mixedItems,
            status: status,
            opensSettings: mixedItems.isEmpty && !waiting
              && failed?.issue?.recovery == .settings && !downloadsModel(failed),
            downloadsModel: mixedItems.isEmpty && !waiting && downloadsModel(failed),
            cancelsModel: mixedItems.isEmpty && cancelsModel(progress))
        ]
        let displayedProvider =
          mixedItems.isEmpty ? (waiting ? progress?.provider : failed?.provider) : nil
        if let multilingual = providers.first(where: { $0.provider == .multilingual }),
          displayedProvider != .multilingual,
          let message = multilingual.progressMessage ?? multilingual.failure
        {
          mixedSections.append(
            Section(
              id: "provider:multilingual", title: EmojiSearchProvider.multilingual.title,
              symbolName: "magnifyingglass", items: [], status: message,
              downloadsModel: downloadsModel(multilingual), cancelsModel: cancelsModel(multilingual)
            ))
        }
        sections = mixedSections
      }
      return
    }
    let catalogSections = (page == 1 ? catalog.symbolSections : catalog.sections)
      .map { section in
        Section(
          id: section.id, title: String(localized: section.title), symbolName: section.symbolName,
          items: section.items.map {
            catalog.preferredItem($0, usageStore: usageStore, defaultSkinTone: defaultSkinTone)
          })
      }
    if page == 1 {
      sections = catalogSections
      return
    }
    var sections: [Section] = []
    func append(_ id: String, _ title: String, _ symbol: String, _ selections: [EmojiSelection]) {
      let selections = selections.filter { allowsRichContent || $0.asset == nil }
      guard !selections.isEmpty else { return }
      sections.append(
        Section(
          id: id, title: title, symbolName: symbol,
          items: selections.map {
            EmojiMatchItem(id: "\(id):\($0.id)", selection: $0, accessibilityLabel: $0.value)
          }))
    }
    append("favorites", String(localized: "Favorites"), "star", usageStore.favorites)
    append(
      "recent", String(localized: .emRecentSectionTitle), "clock",
      usageStore.suggestions().map(\.selection))
    append(
      "imported", String(localized: "Stickers"), "face.smiling.inverse",
      usageStore.importedSelections.filter { $0.asset?.kind == .image }
    )
    append(
      "genmoji", String(localized: "Genmoji"), "apple.intelligence",
      usageStore.importedSelections.filter { $0.asset?.kind == .adaptiveGlyph })
    sections += catalogSections
    self.sections = sections
  }

  private static func categories(
    catalog: EmojiBrowserCatalog, usageStore: EmojiUsageStore, page: Int, allowsRichContent: Bool
  ) -> [Category] {
    let catalogCategories = (page == 1 ? catalog.symbolSections : catalog.sections)
      .map {
        Category(
          id: $0.id, title: String(localized: $0.title), symbolName: $0.symbolName,
          firstItemID: $0.items.first?.id)
      }
    guard page == 0 else { return catalogCategories }
    let imported = usageStore.importedSelections
    let stickers = imported.first { $0.asset?.kind == .image }
    let genmoji = imported.first { $0.asset?.kind == .adaptiveGlyph }
    let recent = usageStore.suggestions().first { allowsRichContent || $0.selection.asset == nil }?
      .selection
    var categories: [Category] = []
    if allowsRichContent {
      categories.append(
        Category(
          id: "imported", title: String(localized: "Stickers"),
          symbolName: "face.smiling.inverse", firstItemID: stickers.map { "imported:\($0.id)" }))
      categories.append(
        Category(
          id: "genmoji", title: String(localized: "Genmoji"),
          symbolName: "apple.intelligence", firstItemID: genmoji.map { "genmoji:\($0.id)" }))
    }
    categories.append(
      Category(
        id: "recent", title: String(localized: .emRecentSectionTitle),
        symbolName: "clock", firstItemID: recent.map { "recent:\($0.id)" }))
    return categories + catalogCategories
  }
}
