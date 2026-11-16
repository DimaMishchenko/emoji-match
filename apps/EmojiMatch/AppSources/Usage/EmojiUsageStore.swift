import AppKit
import Foundation
import Observation

struct EmojiUsageEntry: Identifiable, Equatable, Sendable {
  let selection: EmojiSelection
  let count: Int
  let lastUsedAt: Date

  var id: String {
    selection.id
  }
}

@MainActor
@Observable
final class EmojiUsageStore {
  fileprivate struct Record: Codable, Equatable, Hashable, Sendable {
    let selection: EmojiSelection
    var count: Int
    var lastUsedAt: Date
  }

  private enum Constants {
    nonisolated static let historyLimit = 64
    nonisolated static let suggestionsLimit = 12
    nonisolated static let storageKey = "com.dimasike.EmojiMatch.emojiUsageHistory.v1"
  }

  private let defaults: UserDefaults
  private let storageKey: String
  private let historyLimit: Int
  private let now: () -> Date
  private var records: [Record]
  private let library: EmojiLibraryStorage
  private let historyWritable: Bool

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = Constants.storageKey,
    historyLimit: Int = Constants.historyLimit,
    now: @escaping () -> Date = Date.init,
    libraryDirectory: URL? = nil,
    assetCountLimit: Int = 256,
    assetByteLimit: Int = 100 * 1024 * 1024
  ) {
    self.library = EmojiLibraryStorage(
      directory: libraryDirectory ?? EmojiLibraryStorage.defaultDirectory(storageKey: storageKey),
      countLimit: assetCountLimit,
      byteLimit: assetByteLimit
    )
    self.defaults = defaults
    self.storageKey = storageKey
    self.historyLimit = max(0, historyLimit)
    self.now = now
    let loaded = Self.loadRecords(from: defaults, storageKey: storageKey)
    self.records = loaded ?? []
    self.historyWritable = loaded != nil
    normalizeAndPersist()
  }

  var favorites: [EmojiSelection] {
    library.favorites.filter(isAvailable)
  }

  var importedSelections: [EmojiSelection] {
    library.importedSelections
  }

  func isFavorite(_ selection: EmojiSelection) -> Bool {
    favorites.contains(selection)
  }

  func toggleFavorite(_ selection: EmojiSelection) {
    guard Self.isValid(selection), isAvailable(selection) else { return }
    library.toggleFavorite(selection)
  }

  func removeRecent(_ selection: EmojiSelection) {
    records.removeAll { $0.selection == selection }
    normalizeAndPersist()
  }

  func clearHistory() {
    records.removeAll()
    normalizeAndPersist()
  }

  func preferredSelection(for base: EmojiSelection) -> EmojiSelection {
    guard let selection = library.preferences[base.id], isAvailable(selection) else { return base }
    return selection
  }

  func setPreferredSelection(_ selection: EmojiSelection, for base: EmojiSelection) {
    guard Self.isValid(base), Self.isValid(selection), isAvailable(selection) else { return }
    library.setPreferredSelection(selection, for: base)
  }

  func importAdaptiveGlyph(_ glyph: NSAdaptiveImageGlyph) throws -> EmojiSelection {
    try library.importData(
      glyph.imageContent, kind: .adaptiveGlyph, identifier: glyph.contentIdentifier,
      typeIdentifier: NSAdaptiveImageGlyph.contentType.identifier,
      description: glyph.contentDescription
    )
  }

  func importImage(data: Data, typeIdentifier: String, description: String) throws -> EmojiSelection
  {
    try library.importData(
      data, kind: .image, identifier: nil, typeIdentifier: typeIdentifier, description: description
    )
  }

  func data(for selection: EmojiSelection) -> Data? {
    library.data(for: selection)
  }

  func refreshLibrary() {
    library.refresh()
  }

  func image(for selection: EmojiSelection) -> NSImage? {
    library.image(for: selection)
  }

  func deleteImported(_ selection: EmojiSelection) {
    guard library.deleteImported(selection) else { return }
    removeRecent(selection)
  }

  private func isAvailable(_ selection: EmojiSelection) -> Bool {
    library.isAvailable(selection)
  }

  var isEmpty: Bool {
    suggestions(limit: 1).isEmpty
  }

  func record(_ selection: EmojiSelection, at date: Date? = nil) {
    guard Self.isValid(selection), selection.asset == nil || library.data(for: selection) != nil
    else {
      return
    }

    let date = min(date ?? now(), now())

    if let index = records.firstIndex(where: { $0.selection == selection }) {
      records[index] = Record(
        selection: selection,
        count: Self.saturatingAdd(records[index].count, 1),
        lastUsedAt: date
      )
    } else {
      records.append(
        Record(
          selection: selection,
          count: 1,
          lastUsedAt: date
        )
      )
    }

    normalizeAndPersist()
  }

  func suggestions(limit: Int = Constants.suggestionsLimit) -> [EmojiUsageEntry] {
    records.filter { isAvailable($0.selection) }.prefix(max(0, limit))
      .map(EmojiUsageEntry.init(record:))
  }

  func topSelection() -> EmojiSelection? {
    suggestions(limit: 1).first?.selection
  }
}

private extension EmojiUsageStore {
  static func loadRecords(from defaults: UserDefaults, storageKey: String) -> [Record]? {
    guard let data = defaults.data(forKey: storageKey) else {
      return []
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
    return elements.compactMap { element in
      guard JSONSerialization.isValidJSONObject(element),
        let bytes = try? JSONSerialization.data(withJSONObject: element)
      else { return nil }
      return try? decoder.decode(Record.self, from: bytes)
    }
  }

  func normalizeAndPersist() {
    records = Self.canonicalize(
      records,
      historyLimit: historyLimit,
      maximumDate: now()
    )
    persist(records)
  }

  func persist(_ records: [Record]) {
    guard historyWritable else { return }
    guard !records.isEmpty else {
      defaults.removeObject(forKey: storageKey)
      return
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    if let data = try? encoder.encode(records) {
      defaults.set(data, forKey: storageKey)
    }
  }

  static func canonicalize(
    _ records: [Record],
    historyLimit: Int,
    maximumDate: Date
  ) -> [Record] {
    var merged: [EmojiSelection: Record] = [:]

    for record in records
    where isValid(record.selection) && record.count > 0 && record.lastUsedAt <= maximumDate {
      if let existing = merged[record.selection] {
        let latestSelection =
          record.lastUsedAt >= existing.lastUsedAt
          ? record.selection
          : existing.selection
        merged[record.selection] = Record(
          selection: latestSelection,
          count: saturatingAdd(existing.count, record.count),
          lastUsedAt: max(existing.lastUsedAt, record.lastUsedAt)
        )
      } else {
        merged[record.selection] = record
      }
    }

    return merged.values
      .sorted(by: Self.isHigherPriority(_:than:))
      .prefix(historyLimit)
      .map { $0 }
  }

  nonisolated static func isValid(_ selection: EmojiSelection) -> Bool {
    !selection.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !selection.value.isEmpty
  }

  nonisolated static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : result
  }

  nonisolated static func isHigherPriority(_ lhs: Record, than rhs: Record) -> Bool {
    if lhs.lastUsedAt != rhs.lastUsedAt {
      return lhs.lastUsedAt > rhs.lastUsedAt
    }

    if lhs.count != rhs.count {
      return lhs.count > rhs.count
    }

    if lhs.selection.id != rhs.selection.id {
      return lhs.selection.id < rhs.selection.id
    }

    return lhs.selection.value < rhs.selection.value
  }
}

private extension EmojiUsageEntry {
  nonisolated init(record: EmojiUsageStore.Record) {
    selection = record.selection
    count = record.count
    lastUsedAt = record.lastUsedAt
  }
}
