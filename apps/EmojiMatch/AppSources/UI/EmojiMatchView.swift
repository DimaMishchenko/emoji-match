import AppKit
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

struct EmojiMatchView: View {
  let contentWidth: CGFloat
  let searchStore: EmojiSearchStore
  let usageStore: EmojiUsageStore
  let onSubmit: (EmojiSelection) -> Void
  let onSelectEmoji: (EmojiSelection) -> Void
  let onCreateGenmoji: ((String) -> Void)?
  let defaultSkinTone: DefaultSkinTone
  let allowsRichContent: Bool
  let onClose: () -> Void
  let onCopySelection: ((EmojiSelection) -> Void)?
  let onOpenSearchSettings: (() -> Void)?
  let multilingualModel: EmojiMultilingualModelStore?
  @State private var multilingualRefresh: Task<Void, Never>?

  @State private var query = ""
  @FocusState private var isGridFocused: Bool
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.emojiMatchPresentation) private var presentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.locale) private var locale
  let enabledSearchProviders: Set<EmojiSearchProvider>
  let groupSearchResultsByProvider: Bool
  @State private var searchModels: [EmojiSearchProviderModel]
  @State private var eligibleProviders: Set<EmojiSearchProvider>
  @State private var showsSearchDetails = false
  @State private var retryRevision = 0
  @State private var gridNavigationActive = false
  @State private var categoryPage = 0
  @State private var variantRequestID: String?
  @State private var navigation = EmojiMatchNavigationState()

  init(
    contentWidth: CGFloat,
    searchStore: EmojiSearchStore,
    usageStore: EmojiUsageStore,
    onSubmit: @escaping (EmojiSelection) -> Void,
    onSelectEmoji: @escaping (EmojiSelection) -> Void,
    onCreateGenmoji: ((String) -> Void)?,
    onClose: @escaping () -> Void,
    initialQuery: String = "",
    allowsRichContent: Bool = true,
    defaultSkinTone: DefaultSkinTone = .yellow,
    onCopySelection: ((EmojiSelection) -> Void)? = nil,
    enabledSearchProviders: Set<EmojiSearchProvider> = [.lexical],
    groupSearchResultsByProvider: Bool = false,
    searchModels: [EmojiSearchProviderModel] = [],
    multilingualModel: EmojiMultilingualModelStore? = nil,
    onOpenSearchSettings: (() -> Void)? = nil
  ) {
    self.defaultSkinTone = defaultSkinTone
    self.allowsRichContent = allowsRichContent
    self.contentWidth = contentWidth
    self.searchStore = searchStore
    self.usageStore = usageStore
    self.onSubmit = onSubmit
    self.onSelectEmoji = onSelectEmoji
    self.onCreateGenmoji = onCreateGenmoji
    self.onClose = onClose
    self.onCopySelection = onCopySelection
    self._query = State(initialValue: initialQuery)
    self.enabledSearchProviders = enabledSearchProviders
    self.groupSearchResultsByProvider = groupSearchResultsByProvider
    self._searchModels = State(initialValue: searchModels)
    self.onOpenSearchSettings = onOpenSearchSettings
    self.multilingualModel = multilingualModel
    self._eligibleProviders = State(
      initialValue: EmojiSemanticLanguageRouter.activeProviders(
        in: enabledSearchProviders, for: initialQuery))
  }

  var body: some View {
    let content = currentContent

    ZStack(alignment: .top) {
      BrowserView(
        contentWidth: contentWidth,
        horizontalContentInset: EmojiPickerMetrics.gridHorizontalInset,
        searchStore: searchStore,
        usageStore: usageStore,
        searchQuery: query,
        selectedItemID: gridNavigationActive ? navigation.selectedItemID : nil,
        onSelectItemID: { itemID in
          if !query.isEmpty { updateQuery("") }
          gridNavigationActive = !itemID.isEmpty
          navigation.selectItemID(itemID)
        },
        onSelectEmoji: onSelectEmoji,
        onCopySelection: onCopySelection,
        content: content,
        onOpenSearchSettings: onOpenSearchSettings,
        onDownloadMultilingualModel: multilingualModel.map { model in { model.startDownload() } },
        onCancelMultilingualModel: multilingualModel.map { model in
          { Task { await model.cancel() } }
        },
        multilingualDownloadDescription: multilingualModel.map { model in
          let download = ByteCountFormatter.string(
            fromByteCount: model.downloadBytes, countStyle: .file)
          let installed = ByteCountFormatter.string(
            fromByteCount: model.installedBytesEstimate, countStyle: .file)
          return "\(download) download · about \(installed) installed"
        },
        categoryPage: $categoryPage,
        variantRequestID: $variantRequestID
      )
      .focusable()
      .focusEffectDisabled()
      .focused($isGridFocused)
      .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
        guard isGridFocused else { return .ignored }
        return handleGridArrow(press)
      }
      .onKeyPress(keys: [.space]) { press in
        guard Self.handlesArrowModifiers(press.modifiers), isGridFocused, !isComposing else {
          return .ignored
        }
        return requestVariants()
      }
      .onKeyPress(keys: [.return]) { press in
        guard Self.handlesArrowModifiers(press.modifiers), isGridFocused else { return .ignored }
        submit()
        return .handled
      }
      .onKeyPress(.escape) { escape() }
      .padding(.top, EmojiPickerMetrics.topBarHeight)
      .frame(height: EmojiPickerMetrics.expandedHeight)

      topBar
    }
    .frame(
      width: contentWidth,
      height: EmojiPickerMetrics.expandedHeight,
      alignment: .top
    )
    .onChange(of: isGridFocused) { _, focused in
      if focused { gridNavigationActive = true }
    }
    .onChange(of: content.navigationLayout, initial: true) { _, layout in
      if gridNavigationActive {
        navigation.clampSelection(in: layout)
      } else {
        navigation.resetSelection(in: layout)
      }
    }
    .task(
      id: SearchInput(
        query: query, localeIdentifier: locale.identifier, providers: enabledSearchProviders,
        retryRevision: retryRevision)
    ) {
      let query = query
      let localeIdentifier = locale.identifier
      let activeProviders = eligibleProviders
      await withTaskGroup(of: Void.self) { group in
        for source in searchModels {
          let model = source.model
          if activeProviders.contains(source.provider) && source.provider != .lexical {
            group.addTask { @MainActor in
              await model.request(query: query, localeIdentifier: localeIdentifier)
            }
          } else {
            model.cancel()
          }
        }
      }
    }
    .onChange(of: multilingualModel?.state) { previous, current in
      refreshMultilingualModel(previous: previous, current: current)
    }
    .onChange(of: locale.identifier) { _, _ in
      multilingualRefresh?.cancel()
      multilingualRefresh = nil
    }
    .onDisappear { cancelSearches() }
  }

  private var showsHeaderClose: Bool {
    presentation?.showsHeaderClose == true
  }

  private var topBar: some View {
    HStack(spacing: EmojiPickerMetrics.headerControlSpacing) {
      NativeEmojiSearchField(
        text: Binding(get: { query }, set: updateQuery),
        onFocusSearch: { gridNavigationActive = false }, onKeyDown: handleSearchKey
      )
      .controlSize(.large)
      .frame(maxWidth: .infinity)
      .frame(height: EmojiPickerMetrics.searchHeight)
      .glassEffect(.regular.tint(.black.opacity(0.075)), in: Capsule())
      if providerResults.contains(where: \.isLoading) {
        ProgressView().controlSize(.mini).accessibilityLabel("Searching for emoji")
      }
      if !searchFailures.isEmpty {
        let failure = searchFailures.joined(separator: "\n")
        Button {
          showsSearchDetails.toggle()
        } label: {
          Image(systemName: "exclamationmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Search details")
        .accessibilityLabel("Search details: " + failure)
        .popover(isPresented: $showsSearchDetails) {
          VStack(alignment: .leading, spacing: .ds.spacing.sm) {
            Text(failure).font(.ds.caption)
            if providerResults.contains(where: {
              $0.issue?.recovery == .retry || $0.issue?.recovery == .wait
            }) {
              TimelineView(.periodic(from: .now, by: 1)) { context in
                let deadline = providerResults.compactMap { $0.issue?.retryAt }.max()
                VStack(alignment: .leading, spacing: .ds.spacing.xs) {
                  if let deadline, deadline > context.date {
                    Text(deadline, style: .relative).font(.ds.caption).foregroundStyle(.secondary)
                  }
                  Button("Try Again") {
                    showsSearchDetails = false
                    retryRevision &+= 1
                  }
                  .disabled(deadline.map { $0 > context.date } ?? false)
                }
              }
            }
            if let onOpenSearchSettings {
              Button("Search Settings…") {
                showsSearchDetails = false
                onOpenSearchSettings()
              }
            }
          }
          .padding(.ds.spacing.md)
          .frame(maxWidth: 300)
        }
      }
      if allowsRichContent, let onCreateGenmoji {
        Button {
          onCreateGenmoji(query.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
          GenmojiButtonArtwork().offset(y: -1)
            .frame(width: EmojiPickerMetrics.actionSize, height: EmojiPickerMetrics.actionSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: .emGenmojiButtonLabel))
        .help(String(localized: .emGenmojiButtonLabel))
        .background(Color.primary.opacity(0.15), in: Circle())
      }
    }
    .padding(.leading, showsHeaderClose ? EmojiPickerMetrics.headerCloseInset : 0)
    .overlay(alignment: .leading) {
      EmojiMatchNativeCloseButton(presentation: presentation)
        .frame(
          width: EmojiPickerMetrics.headerCloseSize,
          height: EmojiPickerMetrics.headerCloseSize
        )
    }
    .animation(
      reduceMotion ? nil : .easeInOut(duration: .ds.motion.quick),
      value: showsHeaderClose
    )
    .padding(.horizontal, EmojiPickerMetrics.searchHorizontalInset)
    .padding(.top, EmojiPickerMetrics.searchTopInset)
    .frame(width: contentWidth, height: EmojiPickerMetrics.topBarHeight, alignment: .topLeading)
    .background(Color.primary.opacity(0.015))
    .overlay(alignment: .top) {
      Color.clear
        .frame(height: EmojiPickerMetrics.searchTopInset)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture().onChanged { _ in presentation?.beginDrag() })
        .accessibilityHidden(true)
    }
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.primary.opacity(0.08)).frame(height: .ds.stroke.hairline)
    }
  }

  private func updateQuery(_ value: String) {
    guard query != value else { return }
    cancelSearches()
    eligibleProviders = EmojiSemanticLanguageRouter.activeProviders(
      in: enabledSearchProviders, for: value)
    query = value
    showsSearchDetails = false
    gridNavigationActive = false
    let content = EmojiMatchContent(
      query: value, searchStore: searchStore, usageStore: usageStore, page: categoryPage,
      allowsRichContent: allowsRichContent, defaultSkinTone: defaultSkinTone,
      enabledSearchProviders: eligibleProviders,
      groupSearchResultsByProvider: groupSearchResultsByProvider,
      configuredSearchProviders: enabledSearchProviders,
      providerResults: results(for: value),
      canDownloadMultilingualModel: EmojiMultilingualModelFeedback.canDownload(
        multilingualModel?.state),
      canCancelMultilingualModel: canCancelMultilingualModel)
    navigation.resetSelection(in: content.navigationLayout)
  }

  private func handleSearchKey(_ event: NSEvent, editor: NSTextView) -> Bool {
    guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
      !editor.hasMarkedText()
    else {
      gridNavigationActive = false
      return false
    }
    switch Int(event.keyCode) {
    case kVK_DownArrow:
      if gridNavigationActive { return moveSelection(.down) }
      guard editor.selectedRange().length == 0,
        editor.selectedRange().location == editor.string.utf16.count,
        !currentLayout.items.isEmpty
      else { return false }
      gridNavigationActive = true
      navigation.clampSelection(in: currentLayout)
      return true
    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow:
      guard gridNavigationActive else { return false }
      let direction: EmojiMatchNavigationDirection
      switch Int(event.keyCode) {
      case kVK_UpArrow: direction = .up
      case kVK_LeftArrow: direction = layoutDirection == .rightToLeft ? .right : .left
      default: direction = layoutDirection == .rightToLeft ? .left : .right
      }
      return moveSelection(direction)
    case kVK_Space where gridNavigationActive:
      _ = requestVariants()
      return true
    case kVK_Return, kVK_ANSI_KeypadEnter:
      submit()
      return true
    case kVK_Escape:
      _ = escape()
      return true
    default:
      return false
    }
  }

  private func submit() {
    guard !isComposing else { return }
    guard let selection = navigation.resolvedSelection(in: currentLayout) else { return }

    cancelSearches()
    onSubmit(selection)
  }

  private var currentContent: EmojiMatchContent {
    EmojiMatchContent(
      query: query, searchStore: searchStore, usageStore: usageStore, page: categoryPage,
      allowsRichContent: allowsRichContent, defaultSkinTone: defaultSkinTone,
      enabledSearchProviders: eligibleProviders,
      groupSearchResultsByProvider: groupSearchResultsByProvider,
      configuredSearchProviders: enabledSearchProviders,
      providerResults: providerResults,
      canDownloadMultilingualModel: EmojiMultilingualModelFeedback.canDownload(
        multilingualModel?.state),
      canCancelMultilingualModel: canCancelMultilingualModel)
  }

  private var providerResults: [EmojiSearchProviderResult] {
    results(for: query)
  }

  private var canCancelMultilingualModel: Bool {
    switch multilingualModel?.state {
    case .downloading?, .installing?: true
    default: false
    }
  }

  private var searchFailures: [String] {
    providerResults.filter { $0.issue?.kind != .modelNotInstalled }
      .compactMap { result in
        result.failure.map { "\(result.provider.title): \($0)" }
      }
  }

  private func results(for query: String) -> [EmojiSearchProviderResult] {
    let active = eligibleProviders
    return searchModels.filter { active.contains($0.provider) }
      .map {
        let result = $0.model.result(
          for: query, localeIdentifier: locale.identifier, provider: $0.provider)
        guard EmojiSearchInput.normalized(query)?.isEmpty == false else { return result }
        return EmojiMultilingualModelFeedback.result(result, state: multilingualModel?.state)
      }
  }

  private func refreshMultilingualModel(
    previous: EmojiMultilingualModelStore.State?, current: EmojiMultilingualModelStore.State?
  ) {
    guard eligibleProviders.contains(.multilingual),
      EmojiSearchInput.normalized(query)?.isEmpty == false,
      let source = searchModels.first(where: { $0.provider == .multilingual })
    else { return }
    let query = query
    let localeIdentifier = locale.identifier
    let result = source.model.result(
      for: query, localeIdentifier: localeIdentifier, provider: .multilingual)
    guard
      EmojiMultilingualModelFeedback.shouldRefresh(
        previous: previous, current: current, result: result)
    else { return }
    multilingualRefresh?.cancel()
    multilingualRefresh = Task { @MainActor in
      guard !Task.isCancelled, self.query == query, locale.identifier == localeIdentifier,
        eligibleProviders.contains(.multilingual), multilingualModel?.state == .ready
      else { return }
      await source.model.request(query: query, localeIdentifier: localeIdentifier)
    }
  }

  private func cancelSearches() {
    multilingualRefresh?.cancel()
    multilingualRefresh = nil
    for source in searchModels { source.model.cancel() }
  }

  private struct SearchInput: Hashable {
    let query: String
    let localeIdentifier: String
    let providers: Set<EmojiSearchProvider>
    let retryRevision: Int
  }

  private var currentLayout: EmojiMatchNavigationLayout {
    currentContent.navigationLayout
  }

  private var isComposing: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  private func escape() -> KeyPress.Result {
    guard !isComposing else { return .ignored }
    if query.isEmpty {
      cancelSearches()
      onClose()
    } else {
      updateQuery("")
      isGridFocused = false
      gridNavigationActive = false
      NativeEmojiSearchField.focus(in: NSApp.keyWindow)
    }
    return .handled
  }

  private func requestVariants() -> KeyPress.Result {
    guard let item = currentLayout.items.first(where: { $0.id == navigation.selectedItemID }),
      EmojiBrowserCatalog.shared.hasVariants(for: item.selection)
    else { return .handled }
    variantRequestID = item.id
    return .handled
  }

  private func handleGridArrow(_ press: KeyPress) -> KeyPress.Result {
    guard Self.handlesArrowModifiers(press.modifiers), !isComposing else { return .ignored }
    let direction: EmojiMatchNavigationDirection
    switch press.key {
    case .leftArrow: direction = layoutDirection == .rightToLeft ? .right : .left
    case .rightArrow: direction = layoutDirection == .rightToLeft ? .left : .right
    case .upArrow: direction = .up
    case .downArrow: direction = .down
    default: return .ignored
    }
    return moveSelection(direction) ? .handled : .ignored
  }

  nonisolated static func handlesArrowModifiers(_ modifiers: SwiftUI.EventModifiers) -> Bool {
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
