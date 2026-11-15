import AppKit
import DesignSystem
import SwiftUI

struct EmojiMatchView: View {
  private enum Constants {
    static let barHeight: CGFloat = 44
    static let fieldHeight: CGFloat = 24
    static let browserSpacing: CGFloat = .ds.spacing.xxs
    static let horizontalContentInset: CGFloat = .ds.spacing.xs
    static let columnCount = 6

    static var expandedHeight: CGFloat {
      barHeight + browserSpacing + BrowserView.preferredHeight
    }
  }

  static func maximumContentSize(width: CGFloat) -> CGSize {
    CGSize(
      width: width,
      height: Constants.expandedHeight
    )
  }

  let contentWidth: CGFloat
  let searchStore: EmojiSearchStore
  let usageStore: EmojiUsageStore
  let onSubmit: (EmojiSelection) -> Void
  let onSelectEmoji: (EmojiSelection) -> Void
  let onOpenBrowser: () -> Void
  let onClose: () -> Void

  @State private var query = ""
  @State private var isBrowserPresented = false
  @State private var navigation = EmojiMatchNavigationState()

  var body: some View {
    ZStack(alignment: .top) {
      if isBrowserPresented {
        BrowserView(
          contentWidth: contentWidth,
          horizontalContentInset: Constants.horizontalContentInset,
          searchStore: searchStore,
          usageStore: usageStore,
          searchQuery: query,
          selectedItemID: navigation.selectedItemID,
          onSelectItemID: { itemID in
            navigation.selectItemID(itemID)
          },
          onSelectEmoji: onSelectEmoji
        )
        .scrollClipDisabled()
        .padding(.top, Constants.barHeight + Constants.browserSpacing)
        .frame(height: Constants.expandedHeight)

        BlurEdge(
          height: Constants.barHeight + Constants.browserSpacing,
          direction: .down
        )
      }

      topBar
    }
    .frame(
      width: contentWidth,
      height: isBrowserPresented ? Constants.expandedHeight : Constants.barHeight,
      alignment: .top
    )
    .onChange(of: query, initial: true) { _, value in
      let normalizedQuery = normalizedQuery(from: value)

      guard !normalizedQuery.isEmpty else {
        if isBrowserPresented {
          navigation.resetSelection(in: browseLayout)
        } else {
          navigation.resetSelection(in: .init(rows: []))
        }
        return
      }

      openBrowser()
      navigation.resetSelection(in: searchLayout(for: normalizedQuery))
    }
  }

  private var topBar: some View {
    GlassEffectContainer(spacing: .ds.spacing.xs) {
      HStack(spacing: .ds.spacing.xs) {
        searchField

        if !isBrowserPresented {
          browserButton
        }
      }
    }
    .padding(.horizontal, Constants.horizontalContentInset)
    .frame(
      width: contentWidth,
      height: Constants.barHeight,
      alignment: .leading
    )
  }

  private var searchField: some View {
    HStack(spacing: .ds.spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.ds.body.weight(.medium))
        .foregroundStyle(Color.ds.textSecondary)

      TextField(String(localized: .emSearchPlaceholder), text: $query)
        .textFieldStyle(.plain)
        .font(.ds.body.weight(.medium))
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
    .padding(.horizontal, .ds.spacing.sm)
    .padding(.vertical, .ds.spacing.xs)
    .frame(
      maxWidth: .infinity,
      minHeight: Constants.fieldHeight,
      alignment: .leading
    )
    .glassEffect(.clear, in: Capsule(style: .continuous))
  }

  private var browserButton: some View {
    let size = Constants.fieldHeight + .ds.spacing.xs

    return Button {
      openBrowser()
      navigation.resetSelection(in: browseLayout)
    } label: {
      HStack(spacing: .ds.spacing.xxs) {
        Image(systemName: "arrow.right.to.line")

        Text(String(localized: .emBrowserButtonTitle))
      }
      .font(.ds.callout.weight(.medium))
      .foregroundStyle(Color.ds.textSecondary)
      .padding(.horizontal, .ds.spacing.xs)
      .frame(height: size)
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(localized: .emBrowserButtonLabel))
    .accessibilityHint(String(localized: .emBrowserButtonHint))
    .help(String(localized: .emBrowserButtonLabel))
    .glassEffect(.clear.interactive(true), in: Capsule(style: .continuous))
  }

  private func openBrowser() {
    guard !isBrowserPresented else {
      return
    }

    isBrowserPresented = true
    onOpenBrowser()
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
      columnCount: Constants.columnCount
    )
    .rows
    return EmojiMatchNavigationLayout(
      rows: recentRows + catalog.navigationRows(columnCount: Constants.columnCount)
    )
  }

  private var currentLayout: EmojiMatchNavigationLayout {
    layout(for: isBrowserPresented)
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

  private func layout(
    for browserVisible: Bool, assumeBrowserVisible: Bool = false
  ) -> EmojiMatchNavigationLayout {
    let normalizedQuery = normalizedQuery(from: query)

    if !normalizedQuery.isEmpty {
      return searchLayout(for: normalizedQuery)
    }

    return browserVisible || assumeBrowserVisible ? browseLayout : .init(rows: [])
  }

  private func searchLayout(for normalizedQuery: String) -> EmojiMatchNavigationLayout {
    EmojiMatchNavigationLayout(
      items: searchStore.results(for: normalizedQuery).map(EmojiMatchItem.searchResult),
      columnCount: Constants.columnCount
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
    let layout = layout(for: isBrowserPresented, assumeBrowserVisible: true)

    guard !layout.items.isEmpty else {
      return false
    }

    if !isBrowserPresented {
      openBrowser()
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
      contentWidth: 324,
      searchStore: EmojiSearchStore(),
      usageStore: EmojiUsageStore(),
      onSubmit: { _ in },
      onSelectEmoji: { _ in },
      onOpenBrowser: {},
      onClose: {}
    )
    .frame(width: 324, height: 400)
  }
}
