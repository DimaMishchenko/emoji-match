import AppKit
import DesignSystem
import SwiftUI

struct EmojiMatchView: View {
  let contentWidth: CGFloat
  let searchStore: EmojiSearchStore
  let usageStore: EmojiUsageStore
  let onSubmit: (EmojiSelection) -> Void
  let onSelectEmoji: (EmojiSelection) -> Void
  let onCreateGenmoji: ((String) -> Void)?
  let onClose: () -> Void

  @FocusState private var isSearchFocused: Bool
  @State private var query = ""
  @State private var navigation = EmojiMatchNavigationState()

  var body: some View {
    ZStack(alignment: .top) {
      BrowserView(
        contentWidth: contentWidth,
        horizontalContentInset: EmojiPickerMetrics.gridHorizontalInset,
        searchStore: searchStore,
        usageStore: usageStore,
        searchQuery: query,
        selectedItemID: navigation.selectedItemID,
        onSelectItemID: { itemID in
          navigation.selectItemID(itemID)
        },
        onSelectEmoji: onSelectEmoji
      )
      .padding(.top, EmojiPickerMetrics.topBarHeight)
      .frame(height: EmojiPickerMetrics.expandedHeight)

      topBar
    }
    .frame(
      width: contentWidth,
      height: EmojiPickerMetrics.expandedHeight,
      alignment: .top
    )
    .defaultFocus($isSearchFocused, true)
    .onChange(of: query, initial: true) { _, value in
      let normalizedQuery = normalizedQuery(from: value)

      navigation.resetSelection(
        in: normalizedQuery.isEmpty ? browseLayout : searchLayout(for: normalizedQuery)
      )
    }
  }

  private var topBar: some View {
    HStack(spacing: .ds.spacing.xs) {
      searchField
      if let onCreateGenmoji {
        genmojiButton(action: onCreateGenmoji)
      }
    }
    .padding(.horizontal, EmojiPickerMetrics.searchHorizontalInset)
    .padding(.top, EmojiPickerMetrics.searchTopInset)
    .frame(
      width: contentWidth,
      height: EmojiPickerMetrics.topBarHeight,
      alignment: .topLeading
    )
    .background(Color.ds.textPrimary.opacity(0.025))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.ds.textPrimary.opacity(0.08))
        .frame(height: .ds.stroke.hairline)
    }
  }

  private var searchField: some View {
    HStack(spacing: .ds.spacing.xxs) {
      Image(systemName: "magnifyingglass")
        .font(EmojiPickerMetrics.searchFont)
        .foregroundStyle(Color.ds.textSecondary)

      TextField(String(localized: .emSearchPlaceholder), text: $query)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .font(EmojiPickerMetrics.searchFont)
        .foregroundStyle(Color.ds.textPrimary)
        .onSubmit {
          submit()
        }
        .onKeyPress(keys: [.leftArrow]) { press in
          handleArrowPress(press, direction: .left)
        }
        .onKeyPress(keys: [.rightArrow]) { press in
          handleArrowPress(press, direction: .right)
        }
        .onKeyPress(keys: [.upArrow]) { press in
          handleArrowPress(press, direction: .up)
        }
        .onKeyPress(keys: [.downArrow]) { press in
          handleArrowPress(press, direction: .down)
        }
        .onKeyPress(.escape) {
          if normalizedQuery(from: query).isEmpty {
            onClose()
          } else {
            query = ""
          }
          return .handled
        }
    }
    .padding(.horizontal, .ds.spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: EmojiPickerMetrics.searchHeight)
    .background(Color.ds.textPrimary.opacity(0.12), in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(Color.ds.textPrimary.opacity(0.16), lineWidth: .ds.stroke.thin)
    }
    .overlay {
      if isSearchFocused {
        Capsule()
          .strokeBorder(Color.ds.primary.opacity(0.7), lineWidth: .ds.stroke.thick)
          .padding(-.ds.stroke.regular)
      }
    }
  }

  private func genmojiButton(action: @escaping (String) -> Void) -> some View {
    Button {
      action(query.trimmingCharacters(in: .whitespacesAndNewlines))
    } label: {
      GenmojiButtonArtwork()
        .offset(y: -1)
        .frame(width: EmojiPickerMetrics.actionSize, height: EmojiPickerMetrics.actionSize)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(localized: .emGenmojiButtonLabel))
    .help(String(localized: .emGenmojiButtonLabel))
    .background(Color.ds.textPrimary.opacity(0.12), in: Circle())
  }

  private func submit() {
    let selection =
      navigation.resolvedSelection(in: currentLayout)
      ?? defaultSelection

    guard let selection else {
      return
    }

    onSubmit(selection)
  }

  private var browseLayout: EmojiMatchNavigationLayout {
    let recentRows = EmojiMatchNavigationLayout(
      items: usageStore.suggestions().map(EmojiMatchItem.recentSuggestion),
      columnCount: EmojiPickerMetrics.columnCount
    )
    .rows
    return EmojiMatchNavigationLayout(
      rows: recentRows + catalog.navigationRows(columnCount: EmojiPickerMetrics.columnCount)
    )
  }

  private var currentLayout: EmojiMatchNavigationLayout {
    let normalizedQuery = normalizedQuery(from: query)
    return normalizedQuery.isEmpty ? browseLayout : searchLayout(for: normalizedQuery)
  }

  private var catalog: EmojiBrowserCatalog {
    EmojiBrowserCatalog.shared
  }

  private var defaultSelection: EmojiSelection? {
    let normalizedQuery = normalizedQuery(from: query)

    guard !normalizedQuery.isEmpty else {
      return usageStore.topSelection()
    }

    return searchStore.topResult(for: normalizedQuery)?.selection
  }

  private func searchLayout(for normalizedQuery: String) -> EmojiMatchNavigationLayout {
    EmojiMatchNavigationLayout(
      items: searchStore.results(for: normalizedQuery).map(EmojiMatchItem.searchResult),
      columnCount: EmojiPickerMetrics.columnCount
    )
  }

  private func handleArrowPress(
    _ press: KeyPress,
    direction: EmojiMatchNavigationDirection
  ) -> KeyPress.Result {
    guard Self.handlesArrowModifiers(press.modifiers) else {
      return .ignored
    }

    return moveSelection(direction) ? .handled : .ignored
  }

  nonisolated static func handlesArrowModifiers(_ modifiers: EventModifiers) -> Bool {
    modifiers.isDisjoint(with: [.shift, .control, .option, .command])
  }

  private func moveSelection(_ direction: EmojiMatchNavigationDirection) -> Bool {
    let layout = currentLayout

    guard !layout.items.isEmpty else {
      return false
    }

    if navigation.selectedItemID == nil
      || !layout.items.contains(where: { $0.id == navigation.selectedItemID })
    {
      navigation.resetSelection(in: layout)
    }

    if navigation.move(direction, in: layout) {
      announceSelection(in: layout)
    }
    return true
  }

  private func announceSelection(in layout: EmojiMatchNavigationLayout) {
    guard
      let selectedItemID = navigation.selectedItemID,
      let item = layout.items.first(where: { $0.id == selectedItemID })
    else {
      return
    }

    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: item.accessibilityLabel,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue
      ]
    )
  }

  private func normalizedQuery(from value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

#Preview {
  VStack {
    Spacer()
      .frame(height: .ds.spacing.xs)
    EmojiMatchView(
      contentWidth: EmojiPickerMetrics.contentWidth,
      searchStore: EmojiSearchStore(),
      usageStore: EmojiUsageStore(),
      onSubmit: { _ in },
      onSelectEmoji: { _ in },
      onCreateGenmoji: { _ in },
      onClose: {}
    )
    .frame(width: EmojiPickerMetrics.contentWidth, height: EmojiPickerMetrics.expandedHeight)
  }
}
