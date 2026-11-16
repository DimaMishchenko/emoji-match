import Foundation

struct EmojiMatchContent {
  struct Section: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let items: [EmojiMatchItem]
  }

  let sections: [Section]
  let categories: [Section]

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
    defaultSkinTone: DefaultSkinTone = .yellow
  ) {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      let imported = (allowsRichContent ? usageStore.importedSelections : [])
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
      let results = searchStore.results(for: query)
        .map { result in
          var item = EmojiMatchItem.searchResult(result)
          item.familyBase = catalog.base(for: item.selection)
          return catalog.preferredItem(
            item, usageStore: usageStore, defaultSkinTone: defaultSkinTone)
        }
      let symbols = catalog.symbolSections.flatMap(\.items)
        .filter {
          $0.accessibilityLabel.localizedStandardContains(query)
            || $0.selection.value.contains(query)
        }
        .map { item in
          EmojiMatchItem(
            id: "search:\(item.id)", selection: item.selection,
            accessibilityLabel: item.accessibilityLabel)
        }
      let browse = EmojiMatchContent(
        query: "", searchStore: searchStore, usageStore: usageStore, catalog: catalog, page: page,
        allowsRichContent: allowsRichContent, defaultSkinTone: defaultSkinTone)
      categories = browse.categories
      sections = [
        Section(
          id: "search", title: "", symbolName: "magnifyingglass",
          items: imported + results + symbols)
      ]
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
      categories = catalogSections
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
      "genmoji", String(localized: "Emoji Stickers"), "apple.intelligence",
      usageStore.importedSelections.filter { $0.asset?.kind == .adaptiveGlyph })
    sections += catalogSections
    self.sections = sections
    categories =
      [
        Section(
          id: "imported", title: String(localized: "Stickers"), symbolName: "face.smiling.inverse",
          items: sections.first { $0.id == "imported" }?.items ?? []),
        Section(
          id: "genmoji", title: String(localized: "Emoji Stickers"),
          symbolName: "apple.intelligence",
          items: sections.first { $0.id == "genmoji" }?.items ?? []),
        Section(
          id: "recent", title: String(localized: .emRecentSectionTitle), symbolName: "clock",
          items: sections.first { $0.id == "recent" }?.items ?? [])
      ]
      .filter { allowsRichContent || !["imported", "genmoji"].contains($0.id) } + catalogSections
  }
}
