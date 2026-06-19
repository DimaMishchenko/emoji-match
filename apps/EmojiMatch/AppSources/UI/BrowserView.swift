import DesignSystem
import Emojis
import SwiftUI

struct BrowserView: View {
  private enum Constants {
    static let height: CGFloat = 316
    static let columnCount = 6
    static let emojiCellSize: CGFloat = 40
    static let emojiFontSize: CGFloat = 30
    static let categoryButtonSize: CGFloat = 24
    static let bottomContentInset: CGFloat = categoryButtonSize + .ds.spacing.md

    static func gridSpacing(for width: CGFloat) -> CGFloat {
      let occupiedWidth = CGFloat(columnCount) * emojiCellSize
      return max(.zero, (width - occupiedWidth) / CGFloat(columnCount - 1))
    }
  }

  static let preferredHeight = Constants.height

  let contentWidth: CGFloat
  let horizontalContentInset: CGFloat
  let searchStore: EmojiSearchStore
  let searchQuery: String
  let onSelectEmoji: (String) -> Void

  private static let sections = Section.load()

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(Constants.emojiCellSize),
        spacing: Constants.gridSpacing(
          for: max(.zero, contentWidth - (horizontalContentInset * 2))
        )
      ),
      count: Constants.columnCount
    )
  }

  @State private var visibleSectionIDs: [String] = []

  init(
    contentWidth: CGFloat = 324,
    horizontalContentInset: CGFloat = .ds.spacing.xs,
    searchStore: EmojiSearchStore,
    searchQuery: String,
    onSelectEmoji: @escaping (String) -> Void
  ) {
    self.contentWidth = contentWidth
    self.horizontalContentInset = horizontalContentInset
    self.searchStore = searchStore
    self.searchQuery = searchQuery
    self.onSelectEmoji = onSelectEmoji
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          categoriesView(proxy: proxy)
        } else {
          searchResultsView
        }

        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          BlurEdge(
            height: .ds.spacing.xxl,
            direction: .up
          )

          categoryBar(proxy: proxy)
            .padding(.horizontal, horizontalContentInset)
            .padding(.bottom, .ds.spacing.xxs)
        }
      }
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
        self.visibleSectionIDs = ids
      }
    }
    .frame(width: contentWidth)
    .frame(maxHeight: .infinity)
  }

  private func categoriesView(proxy: ScrollViewProxy) -> some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(alignment: .leading, spacing: .ds.spacing.md) {
        ForEach(Self.sections) { section in
          sectionView(section)
            .id(section.id)
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, horizontalContentInset)
      .padding(.top, .ds.spacing.sm)
      .padding(.bottom, Constants.bottomContentInset)
    }
  }

  private var searchResultsView: some View {
    let results = searchStore.results(for: searchQuery)

    return ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: .ds.spacing.md) {
        if results.isEmpty {
          Text(String(localized: .emNoResults))
            .font(.ds.caption.weight(.semibold))
            .foregroundStyle(Color.ds.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Constants.height - .ds.spacing.lg)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: .ds.spacing.xs) {
            ForEach(results) { result in
              Button {
                onSelectEmoji(result.value)
              } label: {
                Text(result.value)
                  .font(.system(size: Constants.emojiFontSize))
                  .frame(width: Constants.emojiCellSize, height: Constants.emojiCellSize)
                  .contentShape(
                    RoundedRectangle(cornerRadius: .ds.radius.sm, style: .continuous)
                  )
              }
              .buttonStyle(.plain)
              .accessibilityLabel(result.accessibilityLabel)
            }
          }
        }
      }
      .padding(.horizontal, horizontalContentInset)
      .padding(.top, .ds.spacing.sm)
      .padding(.bottom, .ds.spacing.md)
    }
  }

  private func sectionView(_ section: Section) -> some View {
    VStack(alignment: .leading, spacing: .ds.spacing.xs) {
      Text(section.title)
        .font(.ds.caption.weight(.semibold))
        .foregroundStyle(Color.ds.textSecondary)

      LazyVGrid(columns: columns, alignment: .leading, spacing: .ds.spacing.xs) {
        ForEach(section.emojis) { emoji in
          Button {
            onSelectEmoji(emoji.value)
          } label: {
            Text(emoji.value)
              .font(.system(size: Constants.emojiFontSize))
              .frame(width: Constants.emojiCellSize, height: Constants.emojiCellSize)
              .contentShape(
                RoundedRectangle(cornerRadius: .ds.radius.sm, style: .continuous)
              )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(emoji.accessibilityLabel)
        }
      }
    }
  }

  private func categoryBar(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: .ds.spacing.xxs) {
      ForEach(Self.sections) { section in
        Button {
          withAnimation(.snappy(duration: .ds.motion.quick)) {
            proxy.scrollTo(section.id, anchor: .top)
          }
        } label: {
          Image(systemName: section.symbolName)
            .font(.ds.body.weight(.medium))
            .foregroundStyle(Color.ds.textPrimary)
        }
        .if(visibleSectionIDs.first == section.id) {
          $0.buttonStyle(.glass)
        } else: {
          $0.buttonStyle(.plain)
        }
        .buttonBorderShape(.capsule)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(section.title)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct Section: Identifiable {
  let id: String
  let title: LocalizedStringResource
  let symbolName: String
  let emojis: [Item]

  static func load() -> [Self] {
    let fetchedEmojis = loadAvailableEmojis()
    let lookup = Dictionary(grouping: fetchedEmojis, by: \.group)
    let groups = Group.all.compactMap { group -> Self? in
      guard let emojis = lookup[group.emojiGroup], !emojis.isEmpty else {
        return nil
      }

      let items =
        emojis
        .sorted { $0.sortOrder < $1.sortOrder }
        .map(Item.init(emoji:))

      return Self(
        id: group.id,
        title: group.title,
        symbolName: group.symbolName,
        emojis: items
      )
    }

    return groups
  }

  private static func loadAvailableEmojis() -> [Emoji] {
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

private struct Item: Identifiable {
  let id: String
  let value: String
  let accessibilityLabel: String

  nonisolated init(emoji: Emoji) {
    self.id = emoji.id.rawValue
    self.value = emoji.value
    self.accessibilityLabel = emoji.localization.name
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

#Preview {
  BrowserView(
    searchStore: EmojiSearchStore(),
    searchQuery: "",
    onSelectEmoji: { _ in }
  )
  .frame(width: 324, height: 376)
}
