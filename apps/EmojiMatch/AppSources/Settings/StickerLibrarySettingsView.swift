import AppKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct StickerLibrarySettingsView: View {
  @Bindable var model: StickerLibraryModel
  var onCreateGenmoji: ((CGRect) -> Void)? = nil
  @State private var selectedIDs: Set<String> = []
  @State private var isImporting = false
  @State private var confirmsDeletion = false
  @State private var pendingDeletion: [EmojiSelection] = []
  @State private var pendingRename: EmojiSelection?
  @State private var renameText = ""
  @State private var focusedID: String?
  @FocusState private var galleryFocused: Bool
  @FocusState private var searchFocused: Bool
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var title: String { model.collection == .genmoji ? "Genmoji" : "Stickers" }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: CGFloat.ds.spacing.sm) {
        HStack(spacing: CGFloat.ds.spacing.sm) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(Color.ds.textSecondary)
            .accessibilityHidden(true)
          TextField("Search \(title.lowercased())", text: $model.query)
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .accessibilityLabel("Search saved \(title.lowercased())")
        }
        .font(.body)
        .padding(.horizontal, CGFloat.ds.spacing.sm)
        .frame(height: 28)
        .background {
          RoundedRectangle(cornerRadius: CGFloat.ds.radius.sm)
            .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
          RoundedRectangle(cornerRadius: CGFloat.ds.radius.sm)
            .strokeBorder(Color(nsColor: .separatorColor))
        }
        .layoutPriority(1)
        if model.collection == .stickers {
          Button("Add Images") { isImporting = true }
            .fixedSize()
        } else if let onCreateGenmoji {
          ScreenAnchoredButton(title: "Create Genmoji", action: onCreateGenmoji)
        }
        Button(action: model.importClipboard) {
          Label("Import from Clipboard", systemImage: "document.on.clipboard")
        }
        .labelStyle(.iconOnly)
        .help("Import from Clipboard")
        .accessibilityLabel("Import from Clipboard")
      }
      .controlSize(.regular)
      .padding(.horizontal, CGFloat.ds.spacing.lg)
      .padding(.top, CGFloat.ds.spacing.lg)
      .padding(.bottom, CGFloat.ds.spacing.sm)
      if model.items.isEmpty {
        ContentUnavailableView {
          Label(
            model.query.isEmpty ? "No Saved \(title)" : "No Matching \(title)",
            systemImage: model.collection == .genmoji ? "face.smiling" : "square.grid.2x2")
        } description: {
          Text(
            model.query.isEmpty
              ? (model.collection == .genmoji
                ? "Copy a Genmoji, then import it from the clipboard."
                : "Add images or import a copied sticker from the clipboard.")
              : "Try another search.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        gallery
      }
    }
    .onAppear { model.refresh() }
    .onChange(of: model.items.map(\.id)) { _, ids in
      selectedIDs.formIntersection(ids)
      if let focusedID, !ids.contains(focusedID) {
        self.focusedID = ids.first(where: { selectedIDs.contains($0) }) ?? ids.first
        if galleryFocused, selectedIDs.isEmpty, let first = ids.first { selectedIDs = [first] }
      }
    }
    .fileImporter(
      isPresented: $isImporting, allowedContentTypes: [.image], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): model.importFiles(urls)
      case .failure(let error): model.errorMessage = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Delete saved items?", isPresented: $confirmsDeletion, titleVisibility: .visible
    ) {
      Button(pendingDeletion.count == 1 ? "Delete Item" : "Delete Items", role: .destructive) {
        _ = model.delete(pendingDeletion)
        selectedIDs.formIntersection(model.items.map(\.id))
        pendingDeletion = []
      }
    } message: {
      Text("Removes the selected copies from Emoji Match, including favorites and recent history.")
    }
    .alert(
      "Rename Item",
      isPresented: Binding(
        get: { pendingRename != nil },
        set: { if !$0 { pendingRename = nil } }
      )
    ) {
      TextField("Name", text: $renameText)
        .lineLimit(1)
      Button("Cancel", role: .cancel) { pendingRename = nil }
      Button("Rename") {
        if let item = pendingRename { model.rename(item, to: renameText) }
        pendingRename = nil
      }
      .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert(
      "Couldn’t Complete Action",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var gallery: some View {
    GeometryReader { geometry in
      let spacing = CGFloat.ds.spacing.md
      let padding = CGFloat.ds.spacing.lg
      let columnCount = max(1, Int((geometry.size.width - 2 * padding + spacing) / (112 + spacing)))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(
            columns: Array(
              repeating: GridItem(.flexible(minimum: 108, maximum: 128), spacing: spacing),
              count: columnCount),
            spacing: spacing
          ) {
            ForEach(model.items) { item in
              tile(item)
                .id(item.id)
            }
          }
          .padding(padding)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($galleryFocused)
        .onChange(of: galleryFocused) { _, focused in
          if focused,
            let item = model.items.first(where: { $0.id == focusedID }) ?? model.items.first
          {
            focusedID = item.id
            if selectedIDs.isEmpty { selectedIDs = [item.id] }
          }
        }
        .onMoveCommand { direction in
          let modifiers = NSEvent.modifierFlags
          guard galleryFocused, modifiers.isDisjoint(with: [.command, .control, .option]),
            let item = model.items.first(where: { $0.id == focusedID })
          else { return }
          moveSelection(
            from: item, direction: direction, modifiers: modifiers, columnCount: columnCount)
        }
        .onKeyPress(keys: ["c"]) { key in
          guard galleryFocused, key.modifiers.subtracting([.capsLock, .numericPad]) == .command,
            selectedItems.count == 1, let selected = selectedItems.first
          else { return .ignored }
          model.copy(selected)
          return .handled
        }
        .onChange(of: focusedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .onDeleteCommand {
          if galleryFocused { requestDeletion(selectedItems) }
        }
      }
    }
  }

  private func tile(_ item: EmojiSelection) -> some View {
    Button {
      if NSEvent.modifierFlags.contains(.command) {
        if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
      } else {
        selectedIDs = [item.id]
      }
      focusedID = item.id
      galleryFocused = true
    } label: {
      VStack(spacing: CGFloat.ds.spacing.sm) {
        preview(item)
          .frame(width: 72, height: 72)
          .padding(CGFloat.ds.spacing.xs)
          .background {
            if selectedIDs.contains(item.id) {
              RoundedRectangle(cornerRadius: CGFloat.ds.radius.md)
                .fill(Color.accentColor.opacity(0.12))
            }
          }
          .overlay(alignment: .topTrailing) {
            if model.isFavorite(item) {
              Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
          }
          .accessibilityHidden(true)
        Text(item.value)
          .font(.body)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.value)
    .accessibilityAddTraits(selectedIDs.contains(item.id) ? .isSelected : [])
    .accessibilityHint(
      "Use the context menu to copy, rename, favorite, or delete. Use arrow keys to move between items."
    )
    .contextMenu {
      Button("Copy") { model.copy(item) }
      Button("Rename…") { requestRename(item) }
      Button(model.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites") {
        model.toggleFavorite(item)
      }
      Divider()
      Button("Delete…", role: .destructive) {
        requestDeletion(selectedIDs.contains(item.id) ? selectedItems : [item])
      }
    }
  }

  private func moveSelection(
    from item: EmojiSelection, direction: MoveCommandDirection, modifiers: NSEvent.ModifierFlags,
    columnCount: Int
  ) {
    let items = model.items
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    let offset: Int
    switch direction {
    case .left: offset = layoutDirection == .rightToLeft ? 1 : -1
    case .right: offset = layoutDirection == .rightToLeft ? -1 : 1
    case .up: offset = -columnCount
    case .down: offset = columnCount
    @unknown default: return
    }
    let next = items[min(max(index + offset, 0), items.count - 1)]
    if modifiers.contains(.shift) {
      selectedIDs.insert(item.id)
      selectedIDs.insert(next.id)
    } else {
      selectedIDs = [next.id]
    }
    focusedID = next.id
  }

  private func requestRename(_ item: EmojiSelection) {
    renameText = item.value
    pendingRename = item
  }

  private var selectedItems: [EmojiSelection] {
    model.items.filter { selectedIDs.contains($0.id) }
  }

  private func requestDeletion(_ items: [EmojiSelection]) {
    guard !items.isEmpty else { return }
    pendingDeletion = items
    confirmsDeletion = true
  }

  @ViewBuilder private func preview(_ item: EmojiSelection) -> some View {
    if let image = model.image(for: item) {
      EmojiAssetArtwork(
        image: image, animates: !reduceMotion && item.asset?.kind == .image, size: 72)
    } else {
      Image(systemName: "photo.badge.exclamationmark")
        .font(.title2).foregroundStyle(Color.ds.textSecondary)
        .help("Original image unavailable. You can delete it or import it again.")
    }
  }
}
