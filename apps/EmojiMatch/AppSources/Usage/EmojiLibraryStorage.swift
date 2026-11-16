import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class EmojiLibraryStorage {
  enum LibraryError: Error, LocalizedError {
    case invalidContent
    case quotaExceeded
    case unreadableManifest

    var errorDescription: String? {
      switch self {
      case .invalidContent: "This item does not contain a supported image and description."
      case .quotaExceeded:
        "The local library is full. Delete an imported item before importing more."
      case .unreadableManifest:
        "The local library metadata cannot be read. Restore it before making changes."
      }
    }
  }

  private struct Asset: Codable {
    let selection: EmojiSelection
    let digest: String
    let byteCount: Int
  }

  private struct Manifest: Codable {
    var version = 1
    var assets: [Asset] = []
    var favorites: [EmojiSelection] = []
    var preferences: [String: EmojiSelection] = [:]
    var hasUnreadableEntries = false

    private enum CodingKeys: String, CodingKey {
      case version, assets, favorites, preferences
    }

    init() {}

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = try container.decode(Int.self, forKey: .version)
      let decodedAssets = try container.decode([Decoded<Asset>].self, forKey: .assets)
      let decodedFavorites = try container.decode(
        [Decoded<EmojiSelection>].self, forKey: .favorites)
      let decodedPreferences = try container.decode(
        [String: Decoded<EmojiSelection>].self, forKey: .preferences)
      assets = decodedAssets.compactMap(\.value)
      favorites = decodedFavorites.compactMap(\.value)
      preferences = decodedPreferences.compactMapValues(\.value)
      hasUnreadableEntries =
        assets.count != decodedAssets.count
        || favorites.count != decodedFavorites.count
        || preferences.count != decodedPreferences.count
    }
  }

  private struct Decoded<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
      value = try? Value(from: decoder)
    }
  }

  private let directory: URL
  private let countLimit: Int
  private let byteLimit: Int
  private var manifest = Manifest()
  private var writable = true
  private var availableIDs: Set<String> = []
  private var thumbnails: [String: NSImage] = [:]

  init(directory: URL, countLimit: Int, byteLimit: Int) {
    self.directory = directory
    self.countLimit = max(0, countLimit)
    self.byteLimit = max(0, byteLimit)
    let url = directory.appendingPathComponent("library.json")
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else {
          throw LibraryError.unreadableManifest
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        guard decoded.version == 1 else { throw LibraryError.unreadableManifest }
        manifest = decoded
        writable = !decoded.hasUnreadableEntries
      } catch {
        writable = false
      }
    }
    refresh()
  }

  static func defaultDirectory(storageKey: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.dimasike.EmojiMatch/Library", isDirectory: true)
      .appendingPathComponent(digest(Data(storageKey.utf8)), isDirectory: true)
  }

  var favorites: [EmojiSelection] { manifest.favorites }
  var preferences: [String: EmojiSelection] { manifest.preferences }
  var importedSelections: [EmojiSelection] { manifest.assets.map(\.selection) }

  func toggleFavorite(_ selection: EmojiSelection) {
    var next = manifest
    if next.favorites.contains(selection) {
      next.favorites.removeAll { $0 == selection }
    } else {
      next.favorites.append(selection)
    }
    try? save(next)
  }

  func setPreferredSelection(_ selection: EmojiSelection, for base: EmojiSelection) {
    var next = manifest
    next.preferences[base.id] = selection == base ? nil : selection
    try? save(next)
  }

  func importData(
    _ data: Data, kind: EmojiAssetReference.Kind, identifier: String?,
    typeIdentifier: String, description: String
  ) throws -> EmojiSelection {
    guard writable else { throw LibraryError.unreadableManifest }
    guard !data.isEmpty, data.count <= byteLimit,
      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !description.contains("\u{FFFC}"),
      let type = UTType(typeIdentifier), type.conforms(to: .image),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sourceType = CGImageSourceGetType(source),
      UTType(sourceType as String)?.conforms(to: type) == true,
      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    else { throw LibraryError.invalidContent }
    let hash = Self.digest(data)
    if let existing = manifest.assets.first(where: {
      $0.digest == hash && $0.selection.asset?.kind == kind
    }) {
      if self.data(for: existing.selection) == nil {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: assetURL(hash), options: .atomic)
      }
      updatePreview(for: existing.selection, data: data)
      return existing.selection
    }
    guard manifest.assets.count < countLimit,
      manifest.assets.reduce(0, { $0 + max(0, min(byteLimit - $0, $1.byteCount)) })
        <= byteLimit - data.count
    else { throw LibraryError.quotaExceeded }
    let selection = EmojiSelection(
      id: "\(kind.rawValue):\(hash)", value: description,
      asset: EmojiAssetReference(
        kind: kind, identifier: identifier ?? hash, typeIdentifier: typeIdentifier
      )
    )
    let url = assetURL(hash)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let existed = FileManager.default.fileExists(atPath: url.path)
    try data.write(to: url, options: .atomic)
    var next = manifest
    next.assets.append(Asset(selection: selection, digest: hash, byteCount: data.count))
    do {
      try save(next)
    } catch {
      if !existed { try? FileManager.default.removeItem(at: url) }
      throw error
    }
    updatePreview(for: selection, data: data)
    return selection
  }

  func isAvailable(_ selection: EmojiSelection) -> Bool {
    selection.asset == nil || availableIDs.contains(selection.id)
  }

  func image(for selection: EmojiSelection) -> NSImage? {
    thumbnails[selection.id]
  }

  func refresh() {
    availableIDs.removeAll()
    thumbnails.removeAll()
    for asset in manifest.assets {
      if let bytes = data(for: asset.selection) {
        updatePreview(for: asset.selection, data: bytes)
      }
    }
  }

  private func updatePreview(for selection: EmojiSelection, data: Data) {
    availableIDs.insert(selection.id)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
    if CGImageSourceGetCount(source) > 1, selection.asset?.kind == .image,
      let representation = NSBitmapImageRep(data: data)
    {
      let image = NSImage(size: representation.size)
      image.addRepresentation(representation)
      thumbnails[selection.id] = image
      return
    }
    if let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 80
      ] as CFDictionary)
    {
      thumbnails[selection.id] = NSImage(cgImage: image, size: .zero)
    }
  }

  func data(for selection: EmojiSelection) -> Data? {
    guard
      let asset = manifest.assets.first(where: {
        $0.selection == selection && $0.selection.asset == selection.asset
      }), isSafeDigest(asset.digest),
      asset.byteCount > 0, asset.byteCount <= byteLimit,
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: assetURL(asset.digest).path),
      (attributes[.size] as? NSNumber)?.intValue == asset.byteCount,
      let bytes = try? Data(contentsOf: assetURL(asset.digest)),
      bytes.count == asset.byteCount, Self.digest(bytes) == asset.digest
    else { return nil }
    return bytes
  }

  func deleteImported(_ selection: EmojiSelection) -> Bool {
    guard let asset = manifest.assets.first(where: { $0.selection == selection }) else {
      return false
    }
    var next = manifest
    next.assets.removeAll { $0.selection == selection }
    next.favorites.removeAll { $0 == selection }
    next.preferences = next.preferences.filter { $0.value != selection }
    do { try save(next) } catch { return false }
    availableIDs.remove(selection.id)
    thumbnails.removeValue(forKey: selection.id)
    if !next.assets.contains(where: { $0.digest == asset.digest }), isSafeDigest(asset.digest) {
      try? FileManager.default.removeItem(at: assetURL(asset.digest))
    }
    return true
  }

  private func save(_ next: Manifest) throws {
    guard writable else { throw LibraryError.unreadableManifest }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(next)
      .write(
        to: directory.appendingPathComponent("library.json"), options: .atomic
      )
    manifest = next
  }

  private func assetURL(_ digest: String) -> URL {
    directory.appendingPathComponent(digest + ".asset")
  }

  private func isSafeDigest(_ digest: String) -> Bool {
    digest.count == 64
      && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
