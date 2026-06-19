import DesignSystem
import SwiftUI

struct EmojiMatchView: View {
  private enum Constants {
    static let barHeight: CGFloat = 44
    static let fieldHeight: CGFloat = 24
    static let browserSpacing: CGFloat = .ds.spacing.xxs
    static let horizontalContentInset: CGFloat = .ds.spacing.xs

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
  let onSubmit: (String) -> Void
  let onSelectEmoji: (String) -> Void
  let onOpenBrowser: () -> Void

  @State private var query = ""
  @State private var isBrowserPresented = false

  var body: some View {
    ZStack(alignment: .top) {
      if isBrowserPresented {
        BrowserView(
          contentWidth: contentWidth,
          horizontalContentInset: Constants.horizontalContentInset,
          searchStore: searchStore,
          searchQuery: query,
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
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }

      openBrowser()
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
        .onKeyPress(.tab) {
          guard !isBrowserPresented else {
            return .ignored
          }

          openBrowser()
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
    guard let emoji = searchStore.topResult(for: query)?.value else {
      return
    }

    onSubmit(emoji)
  }
}

#Preview {
  VStack {
    Spacer()
      .frame(height: .ds.spacing.xs)
    EmojiMatchView(
      contentWidth: 324,
      searchStore: EmojiSearchStore(),
      onSubmit: { _ in },
      onSelectEmoji: { _ in },
      onOpenBrowser: {}
    )
    .frame(width: 324, height: 400)
  }
}
