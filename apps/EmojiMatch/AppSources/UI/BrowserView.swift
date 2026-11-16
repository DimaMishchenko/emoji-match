import AppKit
import DesignSystem
import ObjectiveC
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
  let onCopySelection: ((EmojiSelection) -> Void)?
  let content: EmojiMatchContent
  @Binding var categoryPage: Int
  @Binding var variantRequestID: String?

  private let catalog = EmojiBrowserCatalog.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visibleSectionIDs: [String] = []
  @State private var activeCategoryID: String?

  init(
    contentWidth: CGFloat = EmojiPickerMetrics.contentWidth,
    horizontalContentInset: CGFloat = .ds.spacing.xs,
    searchStore: EmojiSearchStore,
    usageStore: EmojiUsageStore,
    searchQuery: String,
    selectedItemID: String? = nil,
    onSelectItemID: @escaping (String) -> Void,
    onSelectEmoji: @escaping (EmojiSelection) -> Void,
    onCopySelection: ((EmojiSelection) -> Void)? = nil,
    content: EmojiMatchContent? = nil,
    categoryPage: Binding<Int> = .constant(0),
    variantRequestID: Binding<String?> = .constant(nil)
  ) {
    self.contentWidth = contentWidth
    self.horizontalContentInset = horizontalContentInset
    self.searchStore = searchStore
    self.usageStore = usageStore
    self.searchQuery = searchQuery
    self.selectedItemID = selectedItemID
    self.onSelectItemID = onSelectItemID
    self.onSelectEmoji = onSelectEmoji
    self.onCopySelection = onCopySelection
    self._categoryPage = categoryPage
    self._variantRequestID = variantRequestID
    self.content =
      content
      ?? EmojiMatchContent(
        query: searchQuery, searchStore: searchStore, usageStore: usageStore,
        page: categoryPage.wrappedValue)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .bottom) {
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: EmojiPickerMetrics.sectionSpacing) {
            if let error = catalog.loadError ?? (isSearching ? searchStore.loadError : nil) {
              VStack(spacing: .ds.spacing.xs) {
                Text(String(localized: "Emoji unavailable"))
                Text(error).font(.ds.caption).foregroundStyle(Color.ds.textSecondary)
                Button(String(localized: "Retry")) {
                  catalog.reload()
                  searchStore.reload()
                }
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, .ds.spacing.sm)
            }
            ForEach(content.sections) { section in
              sectionView(section).id(section.id)
            }
            if isSearching && content.navigationLayout.items.isEmpty && searchStore.loadError == nil
              && catalog.loadError == nil
            {
              Text(String(localized: .emNoResults))
                .font(.ds.caption.weight(.semibold))
                .foregroundStyle(Color.ds.textSecondary)
                .frame(
                  maxWidth: .infinity, minHeight: EmojiPickerMetrics.scrollHeight - .ds.spacing.lg)
            }
          }
          .id("browser-top")
          .scrollTargetLayout()
          .padding(.horizontal, horizontalContentInset)
          .padding(
            .top,
            isSearching
              ? EmojiPickerMetrics.searchResultsTopInset : EmojiPickerMetrics.browseTopInset
          )
          .padding(.bottom, EmojiPickerMetrics.categoryBarHeight + .ds.spacing.xs)
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting { activeCategoryID = nil }
        }

        .frame(height: EmojiPickerMetrics.browserHeight)
        categoryBar(proxy: proxy)
          .padding(.horizontal, categoryPage == 1 ? 12 : 8)
          .frame(height: EmojiPickerMetrics.categoryBarHeight)
          .background(.ultraThinMaterial)
      }
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) {
        visibleSectionIDs = $0
      }
      .onChange(of: categoryPage) { oldPage, newPage in
        let section = newPage > oldPage ? content.categories.first : content.categories.last
        selectCategory(section, proxy: proxy)
      }
      .onChange(of: searchQuery) { _, newQuery in
        guard !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        proxy.scrollTo("browser-top", anchor: .top)
      }
      .onChange(of: selectedItemID, initial: true) { _, id in
        guard let id else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: .ds.motion.quick)) {
          proxy.scrollTo(id)
        }
      }
    }
    .frame(width: contentWidth, height: Self.preferredHeight)
  }

  private var isSearching: Bool {
    !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sectionView(_ section: EmojiMatchContent.Section) -> some View {
    VStack(alignment: .leading, spacing: .ds.spacing.xs) {
      if section.id == "favorites" {
        Text(section.title).font(.ds.caption.weight(.semibold))
          .foregroundStyle(Color.ds.textSecondary)
      }
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: .zero), count: EmojiPickerMetrics.columnCount),
        spacing: EmojiPickerMetrics.rowSpacing
      ) {
        ForEach(section.items) { item in
          EmojiMatchCell(
            item: item, isSelected: item.id == selectedItemID, usageStore: usageStore,
            onSelect: onSelectEmoji, onCopy: onCopySelection, variantRequestID: $variantRequestID
          )
          .id(item.id)
        }
      }
    }
  }

  @ViewBuilder private func categoryArtwork(_ symbol: String) -> some View {
    if let image = NativeCategoryArtwork.images[symbol] {
      Image(nsImage: image).renderingMode(.template)
    } else {
      Image(systemName: symbol).font(.system(size: EmojiPickerMetrics.categorySymbolSize))
    }
  }

  private func selectCategory(_ section: EmojiMatchContent.Section?, proxy: ScrollViewProxy) {
    guard let section else { return }
    activeCategoryID = section.id
    onSelectItemID(section.items.first?.id ?? "")
    Task { @MainActor in
      await Task.yield()
      withAnimation(reduceMotion ? nil : .snappy(duration: .ds.motion.quick)) {
        proxy.scrollTo(section.items.isEmpty ? "browser-top" : section.id, anchor: .top)
      }
    }
  }

  private func categoryBar(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: .zero) {
      if categoryPage == 1 {
        pageButton(forward: false)
      }
      ForEach(content.categories) { section in
        Button {
          selectCategory(section, proxy: proxy)
        } label: {
          Group {
            if let image = catalog.categoryImages[section.id] {
              Image(nsImage: image).renderingMode(.template)
            } else {
              categoryArtwork(section.symbolName)
            }
          }
          .foregroundStyle(Color.ds.textPrimary)
          .frame(
            width: EmojiPickerMetrics.categoryButtonSize,
            height: EmojiPickerMetrics.categoryButtonSize
          )
          .background {
            Circle()
              .fill(
                (activeCategoryID ?? visibleSectionIDs.first) == section.id
                  ? Color.ds.textPrimary.opacity(0.12) : .clear)
          }
          .frame(width: categoryPage == 1 ? 26 : nil)
          .frame(maxWidth: categoryPage == 0 ? .infinity : nil)
          .frame(height: EmojiPickerMetrics.categoryBarHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .help(section.title)
      }
      if categoryPage == 0 && !catalog.symbolSections.isEmpty {
        pageButton(forward: true)
      }
      if categoryPage == 1 { Spacer(minLength: 0) }
    }
  }

  private func pageButton(forward: Bool) -> some View {
    Button {
      categoryPage = forward ? 1 : 0
    } label: {
      categoryArtwork(forward ? "chevron.right" : "chevron.left")
        .foregroundStyle(Color.ds.textPrimary)
        .frame(
          width: forward ? EmojiPickerMetrics.categoryChevronWidth : 22.5,
          height: EmojiPickerMetrics.categoryBarHeight
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(localized: forward ? "Forward" : "Back"))
    .help(String(localized: forward ? "Symbols" : "Emoji"))
  }
}

private enum NativeCategoryArtwork {
  static let images: [String: NSImage] = {
    let symbols = [
      ("clock", "clock", "Recents"),
      ("face.smiling", "emoji.face.grinning", "People"),
      ("dog", "emoji.dog.face", "Nature"),
      ("fork.knife", "emoji.apple", "FoodAndDrink"),
      ("soccerball", "emoji.soccer.ball", "Activity"),
      ("car", "emoji.automobile", "TravelAndPlaces"),
      ("lightbulb", "lightbulb", "Objects"),
      ("heart", "emoji.heart", "Symbols"),
      ("flag", "flag", "Flags"),
      ("face.smiling.inverse", "sticker", "Custom")
    ]
    let selector = NSSelectorFromString("imageWithPrivateSystemSymbolName:")
    let method = class_getClassMethod(NSImage.self, selector)
    let supported =
      method.flatMap(method_getTypeEncoding).map { String(cString: $0) }
      == "@24@0:8@16"
    return Dictionary(
      uniqueKeysWithValues: symbols.compactMap { key, symbol, asset in
        if supported,
          let image = NSImage.perform(selector, with: symbol)?.takeUnretainedValue() as? NSImage
        {
          return (key, image)
        }
        return NSImage(named: "NativeCategory" + asset).map { (key, $0) }
      })
  }()
}
