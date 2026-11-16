import AppKit
import Foundation
import ImageIO
import Testing

@testable import EmojiMatch

@MainActor
@Suite struct StickerLibraryModelTests {
  @Test func liveClipboardDecoderReportsMalformedItemsAlongsideSuccesses() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let valid = NSPasteboardItem()
    valid.setData(try pngBytes(), forType: .png)
    let invalid = NSPasteboardItem()
    invalid.setData(Data([1, 2, 3]), forType: .png)
    #expect(board.writeObjects([valid, invalid]))
    let model = StickerLibraryModel(
      store: context.store(), copy: { _ in false },
      readClipboard: { try RichContentImport.readReport(from: board) })
    model.importClipboard()
    #expect(model.items.count == 1)
    #expect(model.errorMessage?.contains("1 failed") == true)
    #expect(model.errorMessage?.contains("Clipboard item 2") == true)
  }

  @Test func clipboardDecodingFailuresRemainActionableWithoutSuccessfulItems() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let model = StickerLibraryModel(
      store: context.store(), copy: { _ in false },
      readClipboard: {
        .init(contents: [], failures: ["Clipboard item 1: Invalid image data."])
      })
    model.importClipboard()
    #expect(model.items.isEmpty)
    #expect(
      model.errorMessage?.contains("Imported 0 items; 0 already in the library; 1 failed.") == true)
    #expect(model.errorMessage?.contains("Clipboard item 1: Invalid image data.") == true)
    #expect(model.errorMessage?.contains("retry the failed items") == true)
  }

  @Test func clipboardImportsPersistSearchAndDeduplicateWithoutRecordingUsageOrCopying() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let png = try pngBytes()
    let gif = try gifBytes()
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphBytes())
    let store = context.store()
    var copies = 0
    var reads = 0
    let model = StickerLibraryModel(
      store: store,
      copy: { _ in
        copies += 1; return true
      },
      readClipboard: {
        reads += 1
        return .init(
          contents: [
            .image(data: png, typeIdentifier: "public.png", description: "Blue tile"),
            .image(data: gif, typeIdentifier: "com.compuserve.gif", description: "Tiny animation"),
            .adaptiveGlyph(glyph)
          ], failures: [])
      })
    model.importClipboard()
    #expect(reads == 1)
    #expect(copies == 0)
    #expect(model.items.count == 3)
    #expect(store.suggestions().isEmpty)
    #expect(model.errorMessage == nil)
    let imported = model.items
    model.importClipboard()
    #expect(reads == 2)
    #expect(copies == 0)
    #expect(model.items == imported)
    #expect(model.errorMessage == nil)
    model.query = "  BLUE  "
    let blue = try #require(model.items.first)
    #expect(model.items.count == 1)
    #expect(store.data(for: blue) == png)
    model.query = ""
    let sticker = try #require(model.items.first { $0.asset?.kind == .adaptiveGlyph })
    #expect(!store.isGenmoji(sticker))
    #expect(store.data(for: sticker) == glyph.imageContent)
    let restored = context.store()
    #expect(restored.importedSelections == model.items)
    #expect(restored.suggestions().isEmpty)
    #expect(restored.favorites.isEmpty)
    let restoredGIF = try #require(
      restored.importedSelections.first { $0.value == "Tiny animation" })
    #expect(restored.data(for: restoredGIF) == gif)
  }

  @Test func collectionsKeepIndependentSearchAndUseProvenanceInsteadOfPayloadKind() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphBytes())
    let sticker = try store.importAdaptiveGlyph(glyph)
    let stickers = StickerLibraryModel(store: store, copy: { _ in false })
    let genmoji = StickerLibraryModel(store: store, collection: .genmoji, copy: { _ in false })
    #expect(stickers.items == [sticker])
    #expect(genmoji.items.isEmpty)
    stickers.query = "no match"
    #expect(stickers.items.isEmpty)
    #expect(genmoji.query.isEmpty)
    let marked = try store.importAdaptiveGlyph(glyph, asGenmoji: true)
    #expect(marked.id == sticker.id)
    #expect(store.isGenmoji(marked))
    #expect(genmoji.items == [marked])
    stickers.query = ""
    #expect(stickers.items.isEmpty)
    #expect(context.store().isGenmoji(marked))
  }

  @Test func genmojiClipboardImportRejectsImagesAndPreservesKnownProvenance() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphBytes())
    let png = try pngBytes()
    let genmoji = StickerLibraryModel(
      store: store, collection: .genmoji, copy: { _ in false },
      readClipboard: {
        .init(
          contents: [
            .image(data: png, typeIdentifier: "public.png", description: "Image"),
            .adaptiveGlyph(glyph)
          ], failures: [])
      })
    genmoji.importClipboard()
    let item = try #require(genmoji.items.first)
    #expect(genmoji.items.count == 1)
    #expect(store.isGenmoji(item))
    #expect(genmoji.errorMessage?.contains("1 failed") == true)
    #expect(genmoji.errorMessage?.contains("Add it in Stickers") == true)
    let stickers = StickerLibraryModel(
      store: store, copy: { _ in false },
      readClipboard: { .init(contents: [.adaptiveGlyph(glyph)], failures: []) })
    stickers.importClipboard()
    #expect(stickers.items.isEmpty)
    #expect(stickers.errorMessage == nil)
    #expect(store.isGenmoji(item))
    #expect(genmoji.items == [item])
    #expect(context.store().isGenmoji(item))
    #expect(store.suggestions().isEmpty)
    #expect(store.favorites.isEmpty)
  }

  @Test func genmojiImageOnlyClipboardAndFileImportsGiveActionableGuidance() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let png = try pngBytes()
    let model = StickerLibraryModel(
      store: context.store(), collection: .genmoji, copy: { _ in false },
      readClipboard: {
        .init(
          contents: [.image(data: png, typeIdentifier: "public.png", description: "Image")],
          failures: [])
      })
    model.importClipboard()
    #expect(model.items.isEmpty)
    #expect(model.errorMessage?.contains("copy an original Genmoji") == true)
    model.importFiles([context.root.appendingPathComponent("Image.png")])
    #expect(model.errorMessage?.contains("Import images in Stickers") == true)
    #expect(model.items.isEmpty)
  }

  @Test func filesUseActualFormatAndExtensionlessNamesAndReportPartialFailures() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let png = try pngBytes()
    let gif = try gifBytes()
    let disguised = context.root.appendingPathComponent("Photo.txt")
    let animated = context.root.appendingPathComponent("Animation.png")
    let invalid = context.root.appendingPathComponent("Broken.png")
    try png.write(to: disguised)
    try gif.write(to: animated)
    try Data("not an image".utf8).write(to: invalid)
    let store = context.store()
    let model = StickerLibraryModel(
      store: store, copy: { _ in false }, readClipboard: { .init(contents: [], failures: []) })
    model.importFiles([disguised, invalid, animated, disguised])
    #expect(model.items.map(\.value) == ["Photo", "Animation"])
    #expect(model.items.map { $0.asset?.typeIdentifier } == ["public.png", "com.compuserve.gif"])
    #expect(store.data(for: model.items[0]) == png)
    #expect(store.data(for: model.items[1]) == gif)
    #expect(model.errorMessage?.contains("Imported 2") == true)
    #expect(model.errorMessage?.contains("1 already") == true)
    #expect(model.errorMessage?.contains("1 failed") == true)
    #expect(model.errorMessage?.contains("Broken.png") == true)
    #expect(store.suggestions().isEmpty)
    let imported = model.items
    model.importFiles([disguised])
    #expect(model.errorMessage == nil)
    #expect(model.items == imported)
    #expect(context.store().importedSelections == imported)
  }

  @Test func renameRefreshesSearchAndPreservesIdentityBytesFavoritesAndHistory() throws {
    for collection in [StickerLibraryModel.Collection.stickers, .genmoji] {
      let context = try StickerContext()
      defer { context.cleanUp() }
      let store = context.store()
      let original: EmojiSelection
      let bytes: Data
      if collection == .genmoji {
        let glyph = NSAdaptiveImageGlyph(imageContent: try glyphBytes())
        bytes = glyph.imageContent
        original = try store.importAdaptiveGlyph(glyph, asGenmoji: true)
      } else {
        bytes = try pngBytes()
        original = try store.importImage(
          data: bytes, typeIdentifier: "public.png", description: "Original tile")
      }
      store.toggleFavorite(original)
      store.record(original)
      let history = store.suggestions()
      let model = StickerLibraryModel(store: store, collection: collection, copy: { _ in false })
      model.query = original.value
      #expect(model.items.map(\.id) == [original.id])
      let renamed = try #require(model.rename(original, to: "Renamed artwork"))
      #expect(renamed.id == original.id)
      #expect(renamed.value == "Renamed artwork")
      #expect(renamed.asset == original.asset)
      #expect(model.items.isEmpty)
      model.query = "  RENAMED  "
      #expect(model.items.map(\.value) == ["Renamed artwork"])
      #expect(model.isFavorite(renamed))
      #expect(store.data(for: renamed) == bytes)
      #expect(store.suggestions().map { $0.selection.value } == ["Renamed artwork"])
      #expect(store.suggestions().map(\.lastUsedAt) == history.map(\.lastUsedAt))
      #expect(store.suggestions().map(\.count) == history.map(\.count))
      #expect(model.errorMessage == nil)
      model.refresh()
      #expect(model.items.map(\.value) == ["Renamed artwork"])
      let restored = context.store()
      #expect(restored.importedSelections.map(\.id) == [original.id])
      #expect(restored.importedSelections.map(\.value) == ["Renamed artwork"])
      #expect(restored.favorites.map(\.value) == ["Renamed artwork"])
      #expect(restored.suggestions().map { $0.selection.value } == ["Renamed artwork"])
      #expect(restored.data(for: renamed) == bytes)
      #expect(restored.isGenmoji(renamed) == (collection == .genmoji))
    }
  }

  @Test func renameRejectsBlankNamesWithoutChangingTheLibrary() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let bytes = try pngBytes()
    let item = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Original")
    store.toggleFavorite(item)
    store.record(item)
    let model = StickerLibraryModel(store: store, copy: { _ in false })
    #expect(model.rename(item, to: " \n\t ") == nil)
    #expect(model.errorMessage?.contains("Enter a nonempty name") == true)
    #expect(model.items.map(\.value) == ["Original"])
    #expect(store.data(for: item) == bytes)
    #expect(store.favorites.map(\.value) == ["Original"])
    #expect(store.suggestions().map { $0.selection.value } == ["Original"])
    #expect(context.store().importedSelections.map(\.value) == ["Original"])
  }

  @Test func failedRenameReportsRecoveryAndPreservesOriginalReferences() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let bytes = try pngBytes()
    let item = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Original")
    store.toggleFavorite(item)
    store.record(item)
    let manifest = context.library.appendingPathComponent("library.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    let model = StickerLibraryModel(store: store, copy: { _ in false })
    #expect(model.rename(item, to: "New name") == nil)
    #expect(model.errorMessage?.contains("library is writable") == true)
    #expect(model.items.map(\.value) == ["Original"])
    #expect(store.favorites.map(\.value) == ["Original"])
    #expect(store.suggestions().map { $0.selection.value } == ["Original"])
    #expect(store.data(for: item) == bytes)
  }

  @Test func clipboardBatchKeepsSuccessesWhenQuotaOrValidationFails() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let png = try pngBytes()
    let gif = try gifBytes()
    let model = StickerLibraryModel(
      store: context.store(countLimit: 1), copy: { _ in false },
      readClipboard: {
        .init(
          contents: [
            .image(data: png, typeIdentifier: "public.png", description: "Good"),
            .image(data: Data([1, 2, 3]), typeIdentifier: "public.png", description: "Broken"),
            .image(data: gif, typeIdentifier: "com.compuserve.gif", description: "Over quota")
          ], failures: [])
      })
    model.importClipboard()
    #expect(model.items.map(\.value) == ["Good"])
    #expect(model.errorMessage?.contains("2 failed") == true)
    #expect(model.errorMessage?.contains("Item 2:") == true)
    #expect(model.errorMessage?.contains("Item 3:") == true)
    #expect(model.errorMessage?.contains("library is full") == true)
    #expect(context.store().importedSelections == model.items)
  }

  @Test func filesRejectDirectoriesMissingAndOversizedFiles() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let oversized = context.root.appendingPathComponent("Oversized.png")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 100 * 1024 * 1024 + 1)
    let model = StickerLibraryModel(
      store: context.store(), copy: { _ in false },
      readClipboard: { .init(contents: [], failures: []) })
    model.importFiles([context.root, context.root.appendingPathComponent("Missing.png"), oversized])
    #expect(model.items.isEmpty)
    #expect(model.errorMessage?.contains("3 failed") == true)
    #expect(model.errorMessage?.contains("Missing.png") == true)
    #expect(model.errorMessage?.contains("100 MB") == true)
  }

  @Test func clipboardReadErrorsAndEmptyResultsAreActionable() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let model = StickerLibraryModel(
      store: context.store(), copy: { _ in false },
      readClipboard: { throw RichContentImport.ImportError.unsupportedContent })
    model.importClipboard()
    #expect(model.errorMessage?.contains("Copy a supported image or Genmoji") == true)
    let empty = StickerLibraryModel(
      store: context.store(), copy: { _ in false },
      readClipboard: { .init(contents: [], failures: []) })
    empty.importClipboard()
    #expect(empty.errorMessage != nil)
    #expect(empty.items.isEmpty)
  }

  @Test func deletionRemovesFavoritesAndRecentsAndSurvivesRestart() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: pngBytes(), typeIdentifier: "public.png", description: "Tile")
    store.record(item)
    let model = StickerLibraryModel(
      store: store, copy: { _ in false }, readClipboard: { .init(contents: [], failures: []) })
    model.toggleFavorite(item)
    #expect(model.isFavorite(item))
    #expect(model.errorMessage == nil)
    #expect(context.store().isFavorite(item))
    #expect(model.delete([item, item]))
    #expect(model.items.isEmpty)
    #expect(!model.isFavorite(item))
    let restored = context.store()
    #expect(restored.importedSelections.isEmpty)
    #expect(restored.favorites.isEmpty)
    #expect(restored.suggestions().isEmpty)
    #expect(restored.data(for: item) == nil)
  }

  @Test func corruptAssetsRetainCachedPreviewUntilRefreshAndRemainDeletable() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: pngBytes(), typeIdentifier: "public.png", description: "Tile")
    let model = StickerLibraryModel(
      store: store, copy: { _ in false }, readClipboard: { .init(contents: [], failures: []) })
    let preview = try #require(model.image(for: item))
    let asset = try #require(
      FileManager.default.contentsOfDirectory(at: context.library, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "asset" })
    try Data("corrupted".utf8).write(to: asset)
    #expect(model.image(for: item) === preview)
    model.refresh()
    #expect(model.image(for: item) == nil)
    #expect(model.items == [item])
    model.toggleFavorite(item)
    #expect(model.errorMessage != nil)
    #expect(model.delete([item]))
    #expect(model.items.isEmpty)
  }

  @Test func failedLibraryWritesReportFailuresAndPreserveReferences() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: pngBytes(), typeIdentifier: "public.png", description: "Tile")
    store.record(item)
    store.toggleFavorite(item)
    let manifest = context.library.appendingPathComponent("library.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    let model = StickerLibraryModel(
      store: store, copy: { _ in false }, readClipboard: { .init(contents: [], failures: []) })
    model.toggleFavorite(item)
    #expect(model.errorMessage != nil)
    #expect(model.isFavorite(item))
    #expect(!model.delete([item]))
    #expect(model.errorMessage?.contains("Tile") == true)
    #expect(model.items == [item])
    #expect(store.suggestions().map(\.selection) == [item])
    #expect(!store.deleteImported(item))
  }

  @Test func batchDeletionReportsMissingItemsWhileKeepingSuccessfulDeletion() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: pngBytes(), typeIdentifier: "public.png", description: "Tile")
    let model = StickerLibraryModel(
      store: store, copy: { _ in false }, readClipboard: { .init(contents: [], failures: []) })
    #expect(!model.delete([item, EmojiSelection(id: "missing", value: "Missing")]))
    #expect(model.items.isEmpty)
    #expect(model.errorMessage?.contains("Missing") == true)
  }

  @Test func copyCallsInjectedOperationOnceAndDoesNotRecordUsage() throws {
    let context = try StickerContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: pngBytes(), typeIdentifier: "public.png", description: "Tile")
    var copied: [EmojiSelection] = []
    var succeeds = false
    let model = StickerLibraryModel(
      store: store,
      copy: {
        copied.append($0); return succeeds
      }, readClipboard: { .init(contents: [], failures: []) })
    model.copy(item)
    #expect(copied == [item])
    #expect(model.errorMessage != nil)
    succeeds = true
    model.copy(item)
    #expect(copied == [item, item])
    #expect(model.errorMessage == nil)
    #expect(store.suggestions().isEmpty)
  }
}

@MainActor
private struct StickerContext {
  let suiteName = "StickerLibraryModelTests.\(UUID().uuidString)"
  let defaults: UserDefaults
  let root: URL
  var library: URL { root.appendingPathComponent("Library", isDirectory: true) }

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suiteName))
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func store(countLimit: Int = 256) -> EmojiUsageStore {
    EmojiUsageStore(
      defaults: defaults, storageKey: "usage", libraryDirectory: library,
      assetCountLimit: countLimit)
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor
private func pngBytes() throws -> Data {
  let source = try #require(CGImageSourceCreateWithData(try gifBytes() as CFData, nil))
  let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  return try #require(NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]))
}

@MainActor
private func gifBytes() throws -> Data {
  try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
}

@MainActor
private func glyphBytes() throws -> Data {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
  return try Data(contentsOf: url)
}
