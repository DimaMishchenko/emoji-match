import AppKit
import DesignSystem
import SwiftUI

struct EmojiMatchCell: View {
  let item: EmojiMatchItem
  let isSelected: Bool
  let usageStore: EmojiUsageStore
  let onSelect: (EmojiSelection) -> Void
  let onCopy: ((EmojiSelection) -> Void)?
  @Binding var variantRequestID: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsVariants = false
  private let catalog = EmojiBrowserCatalog.shared

  var body: some View {
    preview(item.selection)
      .offset(y: 1)
      .frame(width: EmojiPickerMetrics.emojiCellSize, height: EmojiPickerMetrics.emojiCellSize)
      .background {
        Capsule()
          .fill(isSelected ? Color.primary.opacity(EmojiPickerMetrics.selectionOpacity) : .clear)
          .frame(
            width: EmojiPickerMetrics.selectionSize.width,
            height: EmojiPickerMetrics.selectionSize.height)
      }
      .contentShape(Rectangle())
      .onTapGesture { onSelect(item.selection) }
      .background {
        NativeEmojiVariants(
          identity: item.id,
          variants: catalog.hasVariants(for: item.selection)
            ? catalog.variants(for: item.selection) : [],
          labels: catalog.variants(for: item.selection).map { catalog.label(for: $0) },
          isPresented: $showsVariants
        ) { variant in
          guard let base = catalog.base(for: item.selection) else { return }
          if !usageStore.setPreferredSelection(variant, for: base) { NSSound.beep() }
          onSelect(variant)
        }
        .frame(width: EmojiPickerMetrics.emojiCellSize, height: EmojiPickerMetrics.emojiCellSize)
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { onSelect(item.selection) }
      .accessibilityLabel(item.accessibilityLabel)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityActions {
        if catalog.hasVariants(for: item.selection) {
          Button(String(localized: "Variants")) { openVariants() }
        }
      }
      .contextMenu {
        if catalog.hasVariants(for: item.selection) {
          Button(String(localized: .emVariantsMenuTitle)) { openVariants() }
        }
        Button(
          usageStore.isFavorite(item.selection)
            ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
        ) {
          if !usageStore.toggleFavorite(item.selection) { NSSound.beep() }
        }
        if item.id.hasPrefix("recent:") {
          Button(String(localized: "Remove from Recents")) {
            usageStore.removeRecent(item.selection)
          }
        }
        if let onCopy {
          Button(String(localized: "Copy")) { onCopy(item.selection) }
        }
        if item.selection.asset != nil {
          Divider()
          Button(String(localized: "Delete from Custom"), role: .destructive) {
            if !usageStore.deleteImported(item.selection) { NSSound.beep() }
          }
        }
      }
      .onChange(of: variantRequestID) { _, id in
        guard id == item.id else { return }
        openVariants()
        variantRequestID = nil
      }
  }

  @ViewBuilder private func preview(_ selection: EmojiSelection) -> some View {
    if selection.asset != nil {
      if let image = usageStore.image(for: selection) {
        EmojiAssetArtwork(image: image, animates: !reduceMotion && selection.asset?.kind == .image)
          .frame(width: EmojiPickerMetrics.emojiFontSize, height: EmojiPickerMetrics.emojiFontSize)
          .clipped()
      } else {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Color.ds.warning)
          .help("Unavailable item. Reimport it to repair or choose Delete from Custom.")
      }
    } else {
      Text(selection.value)
        .font(.system(size: EmojiPickerMetrics.emojiFontSize))
        .foregroundStyle(
          selection.id.hasPrefix("symbol:") ? Color(nsColor: .textColor) : Color.primary)
    }
  }

  private func openVariants() {
    guard catalog.hasVariants(for: item.selection) else { return }
    showsVariants = true
  }
}

struct EmojiAssetArtwork: NSViewRepresentable {
  let image: NSImage
  let animates: Bool
  var size: CGFloat = EmojiPickerMetrics.emojiFontSize

  func makeNSView(context: Context) -> NSImageView {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityElement(false)
    return view
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSImageView, context: Context
  ) -> CGSize? {
    CGSize(width: size, height: size)
  }

  func updateNSView(_ view: NSImageView, context: Context) {
    if view.image !== image { view.image = image }
    view.animates = animates
  }
}
