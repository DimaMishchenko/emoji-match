import DesignSystem
import SwiftUI

struct BrowserView: View {
  static let preferredHeight = EmojiPickerMetrics.browserHeight

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
      repeating: GridItem(.flexible(), spacing: .zero),
      count: EmojiPickerMetrics.columnCount
    )
  }

  @State private var visibleSectionIDs: [String] = []

  init(
    contentWidth: CGFloat = EmojiPickerMetrics.contentWidth,
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
      VStack(spacing: .zero) {
        Group {
          if normalizedSearchQuery.isEmpty {
            browseView()
          } else {
            searchResultsView()
          }
        }
        .frame(
          height: normalizedSearchQuery.isEmpty
            ? EmojiPickerMetrics.scrollHeight : Self.preferredHeight
        )

        if normalizedSearchQuery.isEmpty {
          categoryBar(proxy: proxy)
            .padding(.horizontal, horizontalContentInset)
            .frame(height: EmojiPickerMetrics.categoryBarHeight)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
              Rectangle()
                .fill(Color.ds.textPrimary.opacity(0.08))
                .frame(height: .ds.stroke.hairline)
            }
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
    .frame(height: Self.preferredHeight)
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
      .padding(.bottom, .ds.spacing.xs)
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
            .frame(maxWidth: .infinity, minHeight: EmojiPickerMetrics.scrollHeight - .ds.spacing.lg)
        } else {
          LazyVGrid(columns: columns, alignment: .center, spacing: EmojiPickerMetrics.rowSpacing) {
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

      LazyVGrid(columns: columns, alignment: .center, spacing: EmojiPickerMetrics.rowSpacing) {
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

      LazyVGrid(columns: columns, alignment: .center, spacing: EmojiPickerMetrics.rowSpacing) {
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
        .font(.system(size: EmojiPickerMetrics.emojiFontSize))
        .frame(width: EmojiPickerMetrics.emojiCellSize, height: EmojiPickerMetrics.emojiCellSize)
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
    HStack(spacing: .zero) {
      ForEach(catalog.sections) { section in
        Button {
          onSelectItemID(section.items.first?.id ?? section.id)
          withAnimation(.snappy(duration: .ds.motion.quick)) {
            proxy.scrollTo(section.id, anchor: .top)
          }
        } label: {
          Image(systemName: section.symbolName)
            .font(.system(size: EmojiPickerMetrics.categorySymbolSize))
            .foregroundStyle(Color.ds.textPrimary)
            .frame(
              width: EmojiPickerMetrics.categoryButtonSize,
              height: EmojiPickerMetrics.categoryButtonSize
            )
            .background {
              Circle()
                .fill(
                  visibleSectionIDs.first == section.id
                    ? Color.ds.textPrimary.opacity(0.12) : .clear
                )
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
  .frame(width: EmojiPickerMetrics.contentWidth, height: BrowserView.preferredHeight)
}
