import AppKit
import Foundation
import ImageIO
import Testing

@testable import EmojiMatch

@MainActor
@Suite struct EmojiLibraryTests {
  @Test func renamingPreservesOriginalIdentityUsageFavoritesAndPreferences() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let bytes = try imageBytes()
    let original = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Photo")
    let base = EmojiSelection(id: "base", value: "😀")
    store.toggleFavorite(original)
    store.setPreferredSelection(original, for: base)
    store.record(original, at: Date(timeIntervalSince1970: 12))
    store.record(original, at: Date(timeIntervalSince1970: 20))
    let previousUsage = try #require(store.suggestions().first)
    let renamed = try store.renameImported(original, to: "  Happy dog  ")
    #expect(renamed.id == original.id)
    #expect(renamed.asset == original.asset)
    #expect(renamed.value == "Happy dog")
    let reloaded = context.store()
    #expect(reloaded.importedSelections.first?.value == "Happy dog")
    #expect(reloaded.favorites.first?.value == "Happy dog")
    #expect(reloaded.explicitPreferredSelection(for: base)?.value == "Happy dog")
    #expect(reloaded.suggestions().first?.selection.value == "Happy dog")
    #expect(reloaded.suggestions().first?.count == previousUsage.count)
    #expect(reloaded.suggestions().first?.lastUsedAt == previousUsage.lastUsedAt)
    #expect(reloaded.data(for: original) == bytes)
    #expect(
      try reloaded
        .importImage(
          data: bytes, typeIdentifier: "public.png", description: "Different file name"
        )
        .value
        == "Happy dog")
  }

  @Test func invalidRenameAndFailedMetadataWritesLeaveSavedNamesUnchanged() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let bytes = try imageBytes()
    let item = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Original")
    store.toggleFavorite(item)
    store.record(item)
    for invalid in ["", "  \n ", "Two\nlines", "\u{FFFC}", String(repeating: "a", count: 257)] {
      #expect(throws: EmojiLibraryStorage.LibraryError.invalidName) {
        try store.renameImported(item, to: invalid)
      }
    }
    let metadata = context.directory.appendingPathComponent("library.json")
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.renameImported(item, to: "New name") }
    #expect(!store.toggleFavorite(item))
    let base = EmojiSelection(id: "base", value: "👍")
    let variant = EmojiSelection(id: "variant", value: "👍🏽")
    #expect(!store.setPreferredSelection(variant, for: base))
    #expect(store.explicitPreferredSelection(for: base) == nil)
    #expect(store.importedSelections.first?.value == "Original")
    #expect(store.favorites.first?.value == "Original")
    #expect(store.suggestions().first?.selection.value == "Original")
    #expect(store.data(for: item) == bytes)
  }

  @Test func genmojiCollectionIsExplicitAndPreservesPayloadIdentityAcrossRestart() throws {
    _ = NSApplication.shared
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
    let store = context.store()
    let sticker = try store.importAdaptiveGlyph(glyph)
    #expect(!store.isGenmoji(sticker))
    store.toggleFavorite(sticker)
    store.record(sticker)
    let genmoji = try store.importAdaptiveGlyph(glyph, asGenmoji: true)
    #expect(genmoji.asset == sticker.asset)
    #expect(genmoji.id == sticker.id)
    let reloaded = context.store()
    #expect(reloaded.isGenmoji(genmoji))
    #expect(reloaded.importedSelections == [sticker])
    #expect(reloaded.data(for: sticker) == bytes)
    #expect(reloaded.favorites == [sticker])
    #expect(reloaded.suggestions().map(\.selection) == [sticker])
    #expect(try reloaded.importAdaptiveGlyph(glyph) == sticker)
    #expect(reloaded.isGenmoji(sticker))
    #expect(reloaded.deleteImported(sticker))
    let reimported = try reloaded.importAdaptiveGlyph(glyph)
    #expect(!reloaded.isGenmoji(reimported))
  }

  @Test func oldLibraryWithoutCollectionMetadataKeepsAssetsAsStickers() throws {
    _ = NSApplication.shared
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let sticker = try context.store().importAdaptiveGlyph(NSAdaptiveImageGlyph(imageContent: bytes))
    let url = context.directory.appendingPathComponent("library.json")
    var manifest = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    manifest.removeValue(forKey: "genmojiIDs")
    try JSONSerialization.data(withJSONObject: manifest).write(to: url, options: .atomic)
    let reloaded = context.store()
    #expect(reloaded.importedSelections == [sticker])
    #expect(!reloaded.isGenmoji(sticker))
    #expect(reloaded.data(for: sticker) == bytes)
    let added = try reloaded.importImage(
      data: imageBytes(), typeIdentifier: "public.png", description: "New sticker")
    #expect(reloaded.importedSelections == [sticker, added])
  }

  @Test func previewSnapshotAvoidsDiskReadsUntilExplicitRefreshButDeliveryStillValidates() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: imageBytes(), typeIdentifier: "public.png", description: "Tile")
    store.toggleFavorite(item)
    store.record(item)
    let preview = try #require(store.image(for: item))
    let asset = try #require(
      FileManager.default
        .contentsOfDirectory(
          at: context.directory,
          includingPropertiesForKeys: nil
        )
        .first { $0.pathExtension == "asset" })
    try FileManager.default.removeItem(at: asset)
    #expect(store.image(for: item) === preview)
    #expect(store.favorites == [item])
    #expect(store.suggestions().map(\.selection) == [item])
    #expect(store.data(for: item) == nil)
    store.refreshLibrary()
    #expect(store.image(for: item) == nil)
    #expect(store.favorites.isEmpty)
    #expect(store.suggestions().isEmpty)
    #expect(store.importedSelections == [item])
  }

  @Test func animatedPreviewSnapshotPreservesFramesAndTiming() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let bytes = try #require(
      Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let output = NSMutableData()
    let encoder = try #require(
      CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, 2, nil))
    for delay in [0.1, 0.2] {
      CGImageDestinationAddImage(
        encoder, frame,
        [
          kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: delay]
        ] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(encoder))
    let animatedSource = try #require(CGImageSourceCreateWithData(output as CFData, nil))
    #expect(CGImageSourceGetCount(animatedSource) == 2)
    let store = context.store()
    let item = try store.importImage(
      data: output as Data, typeIdentifier: "com.compuserve.gif", description: "Animated tile")
    let image = try #require(store.image(for: item))
    let representation = try #require(
      image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    #expect((representation.value(forProperty: .frameCount) as? NSNumber)?.intValue == 2)
    representation.setProperty(.currentFrame, withValue: 1)
    let delay = try #require(
      (representation.value(forProperty: .currentFrameDuration) as? NSNumber)?.doubleValue)
    #expect(abs(delay - 0.2) < 0.01)
    store.refreshLibrary()
    #expect(
      store.image(for: item)?.representations.compactMap { $0 as? NSBitmapImageRep }.first?
        .value(forProperty: .frameCount) as? Int == 2)
  }

  @Test func historyWithoutAssetsPreservesIdentityAcrossRestart() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let legacy = Data(
      """
      [{"selection":{"id":"base","value":"👍"},"count":7,"lastUsedAt":42}]
      """
      .utf8
    )
    context.defaults.set(legacy, forKey: "usage")
    let first = context.store()
    #expect(first.suggestions().first?.count == 7)
    #expect(first.suggestions().first?.lastUsedAt == Date(timeIntervalSince1970: 42))
    #expect(first.suggestions(limit: 1).first?.selection.asset == nil)
    let variant = EmojiSelection(id: "exact-variant", value: "👍🏽")
    first.record(variant, at: Date(timeIntervalSince1970: 43))
    first.setPreferredSelection(variant, for: EmojiSelection(id: "base", value: "👍"))
    let reloaded = context.store()
    #expect(reloaded.suggestions().map(\.selection.id) == ["exact-variant", "base"])
    #expect(reloaded.suggestions().last?.count == 7)
    #expect(context.store().suggestions() == reloaded.suggestions())
    #expect(
      reloaded.explicitPreferredSelection(for: EmojiSelection(id: "base", value: "👍")) == variant)
    #expect(variant != EmojiSelection(id: "base", value: variant.value))
  }

  @Test func favoritesAndPreferencesSurviveClearingRecentsAndRestart() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let bytes = try imageBytes()
    let imported = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Blue tile")
    let base = EmojiSelection(id: "base", value: "😀")
    store.toggleFavorite(imported)
    store.setPreferredSelection(imported, for: base)
    store.record(imported)
    store.clearHistory()
    let reloaded = context.store()
    #expect(reloaded.suggestions().isEmpty)
    #expect(reloaded.favorites == [imported])
    #expect(reloaded.explicitPreferredSelection(for: base)?.asset == imported.asset)
    #expect(reloaded.data(for: imported) == bytes)
    #expect(reloaded.image(for: imported) != nil)
    #expect(reloaded.importedSelections == [imported])
    #expect(
      try reloaded.importImage(data: bytes, typeIdentifier: "public.png", description: "Other")
        == imported)
    reloaded.toggleFavorite(imported)
    #expect(!context.store().isFavorite(imported))
  }

  @Test func removeRecentPreservesFavoriteAndExplicitDeleteRemovesLocalReferences() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: imageBytes(), typeIdentifier: "public.png", description: "Tile")
    let base = EmojiSelection(id: "base", value: "😀")
    store.record(item)
    store.toggleFavorite(item)
    store.setPreferredSelection(item, for: base)
    store.removeRecent(item)
    #expect(store.suggestions(limit: 1).isEmpty)
    #expect(store.isFavorite(item))
    store.deleteImported(item)
    let reloaded = context.store()
    #expect(reloaded.importedSelections.isEmpty)
    #expect(reloaded.favorites.isEmpty)
    #expect(reloaded.explicitPreferredSelection(for: base) == nil)
    #expect(reloaded.data(for: item) == nil)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: context.directory.path) == [
        "library.json"
      ])
  }

  @Test func quotasRefuseImportsWithoutEvictingFavorites() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let bytes = try imageBytes()
    let store = context.store(countLimit: 1, byteLimit: bytes.count)
    let item = try store.importImage(data: bytes, typeIdentifier: "public.png", description: "Tile")
    store.toggleFavorite(item)
    #expect(throws: (any Error).self) {
      try store.importImage(
        data: imageBytes(color: .red), typeIdentifier: "public.png", description: "Red")
    }
    #expect(store.isFavorite(item))
    #expect(store.data(for: item) == bytes)
    #expect(
      try store.importImage(data: bytes, typeIdentifier: "public.png", description: "Duplicate")
        == item)
    #expect(throws: (any Error).self) {
      try context.store(byteLimit: 1)
        .importImage(data: bytes, typeIdentifier: "public.png", description: "Tile")
    }
  }

  @Test func invalidAndCorruptAssetsDeclineWithoutRemovingUnrelatedHistory() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    #expect(throws: (any Error).self) {
      try store.importImage(
        data: Data("invalid".utf8), typeIdentifier: "public.png", description: "Invalid")
    }
    #expect(throws: (any Error).self) {
      try store.importImage(
        data: imageBytes(), typeIdentifier: "public.jpeg", description: "Mismatch")
    }
    #expect(throws: (any Error).self) {
      try store.importImage(
        data: imageBytes(), typeIdentifier: "public.png", description: "\u{FFFC}")
    }
    let bytes = try imageBytes()
    let item = try store.importImage(data: bytes, typeIdentifier: "public.png", description: "Tile")
    let plain = EmojiSelection(id: "plain", value: "😀")
    store.record(plain)
    store.record(item)
    let asset = try #require(
      FileManager.default
        .contentsOfDirectory(at: context.directory, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "asset" })
    try Data(repeating: 0, count: bytes.count).write(to: asset)
    #expect(store.data(for: item) == nil)
    #expect(context.store().suggestions().map(\.selection) == [plain])
    #expect(context.store().importedSelections == [item])
    try FileManager.default.removeItem(at: asset)
    #expect(context.store().data(for: item) == nil)
  }

  @Test func damagedAssetCanBeRepairedAtQuotaAndMissingItemCanBeDeleted() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store(countLimit: 1)
    let bytes = try imageBytes()
    let item = try store.importImage(data: bytes, typeIdentifier: "public.png", description: "Tile")
    let asset = try #require(
      FileManager.default
        .contentsOfDirectory(at: context.directory, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "asset" })
    try Data(repeating: 0, count: bytes.count).write(to: asset)
    #expect(store.data(for: item) == nil)
    let repaired = try store.importImage(
      data: bytes, typeIdentifier: "public.png", description: "Tile")
    #expect(repaired == item)
    #expect(store.data(for: item) == bytes)
    try FileManager.default.removeItem(at: asset)
    #expect(context.store().importedSelections == [item])
    store.deleteImported(item)
    #expect(context.store().importedSelections.isEmpty)
    #expect(store.data(for: item) == nil)
  }

  @Test func unreadableManifestIsNeverOverwritten() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    try FileManager.default.createDirectory(
      at: context.directory, withIntermediateDirectories: true)
    let url = context.directory.appendingPathComponent("library.json")
    let corrupt = Data("unreadable metadata".utf8)
    try corrupt.write(to: url)
    let store = context.store()
    let plain = EmojiSelection(id: "plain", value: "😀")
    store.toggleFavorite(plain)
    store.record(plain)
    #expect(throws: (any Error).self) {
      try store.importImage(data: imageBytes(), typeIdentifier: "public.png", description: "Tile")
    }
    #expect(try Data(contentsOf: url) == corrupt)
    #expect(context.store().suggestions(limit: 1).first?.selection == plain)
  }

  @Test func damagedMetadataEntryPreservesOtherItemsWithoutRewritingManifest() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let item = try store.importImage(
      data: imageBytes(), typeIdentifier: "public.png", description: "Tile")
    store.toggleFavorite(item)
    let url = context.directory.appendingPathComponent("library.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var assets = try #require(json["assets"] as? [Any])
    assets.append(["damaged": true])
    json["assets"] = assets
    let damaged = try JSONSerialization.data(withJSONObject: json)
    try damaged.write(to: url)
    let reloaded = context.store()
    #expect(reloaded.importedSelections == [item])
    #expect(reloaded.favorites == [item])
    #expect(reloaded.data(for: item) != nil)
    #expect(!reloaded.toggleFavorite(item))
    let base = EmojiSelection(id: "base", value: "👍")
    let variant = EmojiSelection(id: "variant", value: "👍🏽")
    #expect(!reloaded.setPreferredSelection(variant, for: base))
    #expect(reloaded.explicitPreferredSelection(for: base) == nil)
    #expect(reloaded.favorites == [item])
    #expect(try Data(contentsOf: url) == damaged)
    #expect(throws: (any Error).self) {
      try reloaded.importImage(
        data: imageBytes(color: .red), typeIdentifier: "public.png", description: "Red")
    }
  }

  @Test func failedManifestWriteRemovesNewAssetWithoutPublishingImport() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let store = context.store()
    let manifestURL = context.directory.appendingPathComponent("library.json")
    try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      try store.importImage(data: imageBytes(), typeIdentifier: "public.png", description: "Tile")
    }
    #expect(store.importedSelections.isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: context.directory.path) == [
        "library.json"
      ])
  }

  @Test func unreadableLegacyHistoryIsPreservedAndMalformedEntriesAreIsolated() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let corrupt = Data("unreadable history".utf8)
    context.defaults.set(corrupt, forKey: "usage")
    context.store().record(EmojiSelection(id: "new", value: "😀"))
    #expect(context.defaults.data(forKey: "usage") == corrupt)
    let partial = Data(
      """
      [{"selection":{"id":"valid","value":"👍"},"count":7,"lastUsedAt":42},{"broken":true}]
      """
      .utf8
    )
    context.defaults.set(partial, forKey: "usage")
    #expect(context.store().suggestions().first?.count == 7)
    #expect(context.store().suggestions(limit: 1).first?.selection.id == "valid")
  }

  @Test func adaptiveGlyphPreservesOriginalBytesIdentifierAndDescription() throws {
    let context = try LibraryContext()
    defer { context.cleanUp() }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let local = context.directory.appendingPathComponent("fixture.heic")
    try FileManager.default.createDirectory(
      at: context.directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: local)
    let bytes = try Data(contentsOf: local)
    let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
    let store = context.store()
    let selection = try store.importAdaptiveGlyph(glyph)
    #expect(store.suggestions(limit: 1).isEmpty)
    #expect(selection.asset?.kind == .adaptiveGlyph)
    #expect(selection.asset?.identifier == glyph.contentIdentifier)
    #expect(selection.value == glyph.contentDescription)
    #expect(context.store().data(for: selection) == bytes)
    #expect(try store.importAdaptiveGlyph(glyph) == selection)
    store.toggleFavorite(selection)
    #expect(context.store().favorites.first?.asset == selection.asset)
    store.deleteImported(selection)
    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: local) == bytes)
  }
}

@MainActor
private struct LibraryContext {
  let suite = "EmojiLibraryTests.\(UUID().uuidString)"
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  func store(countLimit: Int = 256, byteLimit: Int = 100 * 1024 * 1024) -> EmojiUsageStore {
    EmojiUsageStore(
      defaults: defaults, storageKey: "usage", libraryDirectory: directory,
      assetCountLimit: countLimit, assetByteLimit: byteLimit
    )
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private func imageBytes(color: NSColor = .blue) throws -> Data {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
  let pixels = try #require(bitmap.bitmapData)
  let rgb = try #require(color.usingColorSpace(.deviceRGB))
  for y in 0..<2 {
    for x in 0..<2 {
      let offset = y * bitmap.bytesPerRow + x * 4
      pixels[offset] = UInt8(rgb.redComponent * 255)
      pixels[offset + 1] = UInt8(rgb.greenComponent * 255)
      pixels[offset + 2] = UInt8(rgb.blueComponent * 255)
      pixels[offset + 3] = 255
    }
  }
  return try #require(bitmap.representation(using: .png, properties: [:]))
}
