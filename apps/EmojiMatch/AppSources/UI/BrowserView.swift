import DesignSystem
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
  let usageStore: EmojiUsageStore
  let searchQuery: String
  let selectedItemID: String?
  let onSelectItemID: (String) -> Void
  let onSelectEmoji: (EmojiSelection) -> Void

  private let catalog = EmojiBrowserCatalog.shared

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
    usageStore: EmojiUsageStore,
    searchQuery: String,
    selectedItemID: String? = nil,
    onSelectItemID: @escaping (String) -> Void,
    onSelectEmoji: @escaping (EmojiSelection) -> Void
  ) {
    self.contentWidth = contentWidth
    self.horizontalContentInset = horizontalContentInset
    self.searchStore = searchStore
    self.usageStore = usageStore
    self.searchQuery = searchQuery
    self.selectedItemID = selectedItemID
    self.onSelectItemID = onSelectItemID
    self.onSelectEmoji = onSelectEmoji
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        if normalizedSearchQuery.isEmpty {
          browseView()
        } else {
          searchResultsView()
        }

        if normalizedSearchQuery.isEmpty {
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
      .onChange(of: selectedItemID, initial: true) { _, _ in
        scrollSelectionIntoView(proxy: proxy)
      }
    }
    .frame(width: contentWidth)
    .frame(maxHeight: .infinity)
  }

  private var normalizedSearchQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func browseView() -> some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(alignment: .leading, spacing: .ds.spacing.md) {
        let suggestions = usageStore.suggestions()

        if !suggestions.isEmpty {
          usageSectionView(suggestions)
        }

        ForEach(catalog.sections) { section in
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

  private func searchResultsView() -> some View {
    let results = searchItems

    return ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: .ds.spacing.md) {
        if results.isEmpty {
          Text(String(localized: .emNoResults))
            .font(.ds.caption.weight(.semibold))
            .foregroundStyle(Color.ds.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Constants.height - .ds.spacing.lg)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: .ds.spacing.xs) {
            ForEach(results) { item in
              emojiButton(
                item: item,
                isSelected: item.id == selectedItemID,
                action: {
                  onSelectEmoji(item.selection)
                }
              )
              .id(item.id)
            }
          }
        }
      }
      .padding(.horizontal, horizontalContentInset)
      .padding(.top, .ds.spacing.sm)
      .padding(.bottom, .ds.spacing.md)
    }
  }

  private var searchItems: [EmojiMatchItem] {
    searchStore.results(for: normalizedSearchQuery).map(EmojiMatchItem.searchResult)
  }

  private func sectionView(_ section: EmojiBrowserSection) -> some View {
    VStack(alignment: .leading, spacing: .ds.spacing.xs) {
      Text(section.title)
        .font(.ds.caption.weight(.semibold))
        .foregroundStyle(Color.ds.textSecondary)

      LazyVGrid(columns: columns, alignment: .leading, spacing: .ds.spacing.xs) {
        ForEach(section.items) { item in
          emojiButton(
            item: item,
            isSelected: item.id == selectedItemID,
            action: {
              onSelectEmoji(item.selection)
            }
          )
          .id(item.id)
        }
      }
    }
  }

  private func usageSectionView(_ suggestions: [EmojiUsageEntry]) -> some View {
    VStack(alignment: .leading, spacing: .ds.spacing.xs) {
      Text(String(localized: .emRecentSectionTitle))
        .font(.ds.caption.weight(.semibold))
        .foregroundStyle(Color.ds.textSecondary)

      LazyVGrid(columns: columns, alignment: .leading, spacing: .ds.spacing.xs) {
        ForEach(suggestions) { suggestion in
          let item = EmojiMatchItem.recentSuggestion(suggestion)

          emojiButton(
            item: item,
            isSelected: item.id == selectedItemID,
            action: {
              onSelectEmoji(item.selection)
            }
          )
          .id(item.id)
        }
      }
    }
  }

  private func emojiButton(
    item: EmojiMatchItem,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(item.selection.value)
        .font(.system(size: Constants.emojiFontSize))
        .frame(width: Constants.emojiCellSize, height: Constants.emojiCellSize)
        .background {
          RoundedRectangle(cornerRadius: .ds.radius.sm, style: .continuous)
            .fill(isSelected ? Color.ds.primary.opacity(0.16) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: .ds.radius.sm, style: .continuous)
            .stroke(
              isSelected ? Color.ds.primary.opacity(0.4) : .clear,
              lineWidth: .ds.stroke.thin
            )
        }
        .contentShape(
          RoundedRectangle(cornerRadius: .ds.radius.sm, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func categoryBar(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: .ds.spacing.xxs) {
      ForEach(catalog.sections) { section in
        Button {
          onSelectItemID(section.items.first?.id ?? section.id)
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

  private func scrollSelectionIntoView(proxy: ScrollViewProxy) {
    guard let selectedItemID else {
      return
    }

    withAnimation(.snappy(duration: .ds.motion.quick)) {
      proxy.scrollTo(selectedItemID, anchor: .center)
    }
  }
}

#Preview {
  BrowserView(
    searchStore: EmojiSearchStore(),
    usageStore: EmojiUsageStore(),
    searchQuery: "",
    selectedItemID: nil,
    onSelectItemID: { _ in },
    onSelectEmoji: { _ in }
  )
  .frame(width: 324, height: 376)
}
