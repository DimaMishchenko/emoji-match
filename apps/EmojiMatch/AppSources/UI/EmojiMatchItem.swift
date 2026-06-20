import Emojis
import Foundation

struct EmojiMatchItem: Identifiable, Equatable, Sendable {
  let id: String
  let selection: EmojiSelection
  let accessibilityLabel: String
}

extension EmojiMatchItem {
  nonisolated static func searchResult(_ result: EmojiSearchResult) -> Self {
    Self(
      id: "search:\(result.id)",
      selection: result.selection,
      accessibilityLabel: result.accessibilityLabel
    )
  }

  nonisolated static func recentSuggestion(_ suggestion: EmojiUsageEntry) -> Self {
    Self(
      id: "recent:\(suggestion.selection.id)",
      selection: suggestion.selection,
      accessibilityLabel: suggestion.selection.value
    )
  }
}

struct EmojiBrowserSection: Identifiable, Sendable {
  let id: String
  let title: LocalizedStringResource
  let symbolName: String
  let items: [EmojiMatchItem]
}

struct EmojiBrowserCatalog {
  let sections: [EmojiBrowserSection]

  static let shared = EmojiBrowserCatalog()

  var items: [EmojiMatchItem] {
    sections.flatMap(\.items)
  }

  func navigationRows(columnCount: Int) -> [[EmojiMatchItem]] {
    sections.flatMap { section in
      EmojiMatchNavigationLayout(
        items: section.items,
        columnCount: columnCount
      )
      .rows
    }
  }

  init() {
    self.sections = Self.loadSections()
  }
}

private extension EmojiBrowserCatalog {
  enum Constants {
    static let itemIDPrefix = "catalog"
  }

  static func loadSections() -> [EmojiBrowserSection] {
    let fetchedEmojis = loadAvailableEmojis()
    let lookup = Dictionary(grouping: fetchedEmojis, by: \.group)

    return Group.all.compactMap { group -> EmojiBrowserSection? in
      guard let emojis = lookup[group.emojiGroup], !emojis.isEmpty else {
        return nil
      }

      let items =
        emojis
        .sorted { $0.sortOrder < $1.sortOrder }
        .map { emoji in
          EmojiMatchItem(
            id: "\(Constants.itemIDPrefix):\(group.id):\(emoji.id.rawValue)",
            selection: EmojiSelection(id: emoji.id.rawValue, value: emoji.value),
            accessibilityLabel: emoji.localization.name
          )
        }

      return EmojiBrowserSection(
        id: group.id,
        title: group.title,
        symbolName: group.symbolName,
        items: items
      )
    }
  }

  static func loadAvailableEmojis() -> [Emoji] {
    let filter: Emojis.Filter

    #if canImport(CoreText)
      filter = .apple
    #else
      filter = .none
    #endif

    let emojis = (try? Emojis.fetch(filter: filter)) ?? []
    return emojis.filter { $0.group != .component }
  }
}

private struct Group {
  let emojiGroup: Emoji.Group
  let title: LocalizedStringResource
  let symbolName: String

  var id: String { emojiGroup.rawValue }

  static let all = [
    Self(emojiGroup: .smileysEmotion, title: .emojiCategorySmileys, symbolName: "face.smiling"),
    Self(emojiGroup: .peopleBody, title: .emojiCategoryPeople, symbolName: "figure.wave"),
    Self(emojiGroup: .animalsNature, title: .emojiCategoryNature, symbolName: "leaf"),
    Self(emojiGroup: .foodDrink, title: .emojiCategoryFood, symbolName: "fork.knife"),
    Self(emojiGroup: .travelPlaces, title: .emojiCategoryTravel, symbolName: "car"),
    Self(emojiGroup: .activities, title: .emojiCategoryActivities, symbolName: "soccerball"),
    Self(emojiGroup: .objects, title: .emojiCategoryObjects, symbolName: "lightbulb"),
    Self(emojiGroup: .symbols, title: .emojiCategorySymbols, symbolName: "heart"),
    Self(emojiGroup: .flags, title: .emojiCategoryFlags, symbolName: "flag")
  ]
}
