import Foundation

struct EmojiUsageEntry: Identifiable, Equatable, Sendable {
  let selection: EmojiSelection
  let count: Int
  let lastUsedAt: Date

  var id: String {
    selection.id
  }
}

final class EmojiUsageStore {
  fileprivate struct Record: Codable, Equatable, Hashable, Sendable {
    let selection: EmojiSelection
    var count: Int
    var lastUsedAt: Date
  }

  private enum Constants {
    static let historyLimit = 64
    static let suggestionsLimit = 12
    static let storageKey = "com.dimasike.EmojiMatch.emojiUsageHistory.v1"
  }

  private let defaults: UserDefaults
  private let storageKey: String
  private let historyLimit: Int
  private let now: () -> Date
  private var records: [Record]

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = Constants.storageKey,
    historyLimit: Int = Constants.historyLimit,
    now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.historyLimit = max(0, historyLimit)
    self.now = now
    self.records = Self.loadRecords(from: defaults, storageKey: storageKey)
    normalizeAndPersist()
  }

  var isEmpty: Bool {
    records.isEmpty
  }

  func record(_ selection: EmojiSelection, at date: Date? = nil) {
    guard Self.isValid(selection) else {
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
    records.prefix(max(0, limit)).map(EmojiUsageEntry.init(record:))
  }

  func topSelection() -> EmojiSelection? {
    records.first?.selection
  }
}

private extension EmojiUsageStore {
  static func loadRecords(from defaults: UserDefaults, storageKey: String) -> [Record] {
    guard let data = defaults.data(forKey: storageKey) else {
      return []
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return (try? decoder.decode([Record].self, from: data)) ?? []
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
