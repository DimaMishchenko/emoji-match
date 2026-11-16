import AppKit
import ImageIO
import Observation

@Observable
final class StickerLibraryModel {
  enum Collection {
    case stickers
    case genmoji
  }

  var query = ""
  let collection: Collection
  var errorMessage: String?

  private let store: EmojiUsageStore
  private let copySelection: (EmojiSelection) -> Bool
  private let readClipboard: () throws -> RichContentImport.ReadReport

  init(
    store: EmojiUsageStore,
    collection: Collection = .stickers,
    copy: @escaping (EmojiSelection) -> Bool,
    readClipboard: @escaping () throws -> RichContentImport.ReadReport = {
      try RichContentImport.readReport()
    }
  ) {
    self.store = store
    self.collection = collection
    self.copySelection = copy
    self.readClipboard = readClipboard
  }

  var items: [EmojiSelection] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.importedSelections.filter { selection in
      let matchesCollection = store.isGenmoji(selection) == (collection == .genmoji)
      return matchesCollection
        && (search.isEmpty || selection.value.localizedStandardContains(search))
    }
  }

  func refresh() {
    store.refreshLibrary()
  }

  func image(for selection: EmojiSelection) -> NSImage? {
    store.image(for: selection)
  }

  func isFavorite(_ selection: EmojiSelection) -> Bool {
    store.isFavorite(selection)
  }

  func toggleFavorite(_ selection: EmojiSelection) {
    clearError()
    guard store.toggleFavorite(selection) else {
      errorMessage =
        "Could not update the favorite. Check that the original image is available and the local library is writable, then try again."
      return
    }
  }

  func importClipboard() {
    clearError()
    do {
      let report = try readClipboard()
      let contents = report.contents
      guard !contents.isEmpty || !report.failures.isEmpty else {
        errorMessage = "\(clipboardInstruction), then try importing again."
        return
      }
      importBatch(contents.map { content in { content } }, decodingFailures: report.failures)
    } catch {
      errorMessage =
        "Could not import from the clipboard. \(clipboardInstruction) and try again. \(error.localizedDescription)"
    }
  }

  func importFiles(_ urls: [URL]) {
    clearError()
    guard !urls.isEmpty else { return }
    guard collection == .stickers else {
      errorMessage =
        "Import images in Stickers. To add a Genmoji, copy it and choose Import from Clipboard."
      return
    }
    importBatch(urls.map { url in { try Self.readFile(url) } })
  }

  @discardableResult
  func delete(_ selections: [EmojiSelection]) -> Bool {
    clearError()
    var failures: [String] = []
    for selection in Set(selections) where !store.deleteImported(selection) {
      failures.append(selection.value)
    }
    if !failures.isEmpty {
      errorMessage =
        "Could not delete: \(failures.sorted().joined(separator: ", ")). Check that the local library is writable, refresh, and try again."
    }
    return failures.isEmpty
  }

  @discardableResult
  func rename(_ selection: EmojiSelection, to name: String) -> EmojiSelection? {
    clearError()
    do {
      return try store.renameImported(selection, to: name)
    } catch {
      errorMessage =
        "Could not rename \(selection.value). Enter a nonempty name, check that the local library is writable, and try again. \(error.localizedDescription)"
      return nil
    }
  }

  func copy(_ selection: EmojiSelection) {
    clearError()
    if !copySelection(selection) {
      errorMessage =
        "Could not copy this item. Check that the original image is available, refresh, and try again."
    }
  }

  private var clipboardInstruction: String {
    collection == .genmoji ? "Copy an original Genmoji" : "Copy a supported image or Genmoji"
  }

  private func clearError() {
    errorMessage = nil
  }

  private func importBatch(
    _ readers: [() throws -> ImportedContent], decodingFailures: [String] = []
  ) {
    var imported = 0
    var duplicates = 0
    var failures = decodingFailures
    var knownIDs = Set(store.importedSelections.map(\.id))
    for (index, read) in readers.enumerated() {
      do {
        let selection: EmojiSelection
        switch try read() {
        case .adaptiveGlyph(let glyph):
          selection = try store.importAdaptiveGlyph(glyph, asGenmoji: collection == .genmoji)
        case .image(let data, let typeIdentifier, let description):
          guard collection == .stickers else {
            throw NSError(
              domain: "StickerLibraryImport", code: 3,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "This is an image. Add it in Stickers, or copy an original Genmoji and import again."
              ])
          }
          guard RichContentImport.isValidImage(data, typeIdentifier: typeIdentifier) else {
            throw RichContentImport.ImportError.invalidContent
          }
          selection = try store.importImage(
            data: data, typeIdentifier: typeIdentifier, description: description)
        }
        if knownIDs.insert(selection.id).inserted {
          imported += 1
        } else {
          duplicates += 1
        }
      } catch {
        failures.append("Item \(index + 1): \(error.localizedDescription)")
      }
    }
    if !failures.isEmpty {
      errorMessage =
        "Imported \(imported) \(imported == 1 ? "item" : "items"); \(duplicates) already in the library; \(failures.count) failed.\n\n"
        + failures.joined(separator: "\n")
        + "\n\(clipboardInstruction), check library space and write access, then retry the failed items."
    }
  }

  private static func readFile(_ url: URL) throws -> ImportedContent {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let maximumBytes = 100 * 1024 * 1024
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard url.isFileURL, values.isRegularFile == true else {
        throw RichContentImport.ImportError.unsupportedContent
      }
      guard (values.fileSize ?? 0) <= maximumBytes else {
        throw NSError(
          domain: "StickerLibraryImport", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Choose an image no larger than 100 MB."])
      }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
      guard data.count <= maximumBytes,
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let type = CGImageSourceGetType(source) as String?,
        RichContentImport.isValidImage(data, typeIdentifier: type)
      else { throw RichContentImport.ImportError.invalidContent }
      return .image(
        data: data, typeIdentifier: type, description: url.deletingPathExtension().lastPathComponent
      )
    } catch {
      throw NSError(
        domain: "StickerLibraryImport", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "\(url.lastPathComponent): \(error.localizedDescription)"
        ])
    }
  }
}
