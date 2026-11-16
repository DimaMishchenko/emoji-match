import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiUsageStoreTests {
  @Test func recordMergesRepeatedSelectionsAndUpdatesLastUsedAt() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8
    )
    let selection = EmojiSelection(id: "1F600", value: "😀")

    store.record(selection, at: Date(timeIntervalSince1970: 10))
    store.record(selection, at: Date(timeIntervalSince1970: 20))

    let entry = store.suggestions().first

    #expect(store.suggestions().count == 1)
    #expect(entry?.selection == selection)
    #expect(entry?.count == 2)
    #expect(entry?.lastUsedAt == Date(timeIntervalSince1970: 20))
  }

  @Test func rankingPrefersRecencyThenFrequency() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8
    )

    let olderFrequent = EmojiSelection(id: "1F31F", value: "🌟")
    let newerLessFrequent = EmojiSelection(id: "2728", value: "✨")
    let sameTimeMoreFrequent = EmojiSelection(id: "1F525", value: "🔥")
    let sameTimeLessFrequent = EmojiSelection(id: "1F4A1", value: "💡")

    store.record(olderFrequent, at: Date(timeIntervalSince1970: 10))
    store.record(olderFrequent, at: Date(timeIntervalSince1970: 20))
    store.record(olderFrequent, at: Date(timeIntervalSince1970: 30))
    store.record(newerLessFrequent, at: Date(timeIntervalSince1970: 40))
    store.record(sameTimeLessFrequent, at: Date(timeIntervalSince1970: 50))
    store.record(sameTimeMoreFrequent, at: Date(timeIntervalSince1970: 50))
    store.record(sameTimeMoreFrequent, at: Date(timeIntervalSince1970: 50))

    #expect(
      store.suggestions().map(\.selection.id) == [
        "1F525",
        "1F4A1",
        "2728",
        "1F31F"
      ]
    )
  }

  @Test func historyIsBoundedToConfiguredLimit() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 2
    )

    store.record(EmojiSelection(id: "1", value: "😀"), at: Date(timeIntervalSince1970: 1))
    store.record(EmojiSelection(id: "2", value: "😎"), at: Date(timeIntervalSince1970: 2))
    store.record(EmojiSelection(id: "3", value: "😍"), at: Date(timeIntervalSince1970: 3))

    #expect(store.suggestions().map(\.selection.id) == ["3", "2"])
  }

  @Test func historyPersistsAcrossStoreInstances() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let selection = EmojiSelection(id: "1F600", value: "😀")

    do {
      let store = EmojiUsageStore(
        defaults: context.defaults,
        storageKey: context.storageKey,
        historyLimit: 8
      )
      store.record(selection, at: Date(timeIntervalSince1970: 100))
    }

    let reloadedStore = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8
    )

    #expect(reloadedStore.suggestions(limit: 1).first?.selection == selection)
    #expect(reloadedStore.suggestions().first?.count == 1)
  }

  @Test func sameIDWithUpdatedValueMergesIntoOneRecord() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8
    )

    store.record(
      EmojiSelection(id: "1F600", value: "😀"),
      at: Date(timeIntervalSince1970: 10)
    )
    store.record(
      EmojiSelection(id: "1F600", value: "updated"),
      at: Date(timeIntervalSince1970: 20)
    )

    let suggestions = store.suggestions()
    #expect(suggestions.count == 1)
    #expect(suggestions.first?.selection.value == "updated")
    #expect(suggestions.first?.count == 2)
  }

  @Test func corruptPersistedRecordsAreSanitizedWithoutOverflow() throws {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let records = [
      persistedRecord(id: "1", value: "😀", count: Int.max, lastUsedAt: 10),
      persistedRecord(id: "1", value: "updated", count: 2, lastUsedAt: 20),
      persistedRecord(id: "", value: "😎", count: 1, lastUsedAt: 30),
      persistedRecord(id: "3", value: "😍", count: -1, lastUsedAt: 40),
      persistedRecord(id: "4", value: "🔥", count: 1, lastUsedAt: 200)
    ]
    let data = try JSONSerialization.data(withJSONObject: records)
    context.defaults.set(data, forKey: context.storageKey)

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8,
      now: { Date(timeIntervalSince1970: 100) }
    )

    let suggestions = store.suggestions()
    #expect(suggestions.count == 1)
    #expect(suggestions.first?.selection.value == "updated")
    #expect(suggestions.first?.count == Int.max)
  }

  @Test func persistedDuplicateUsesValueFromNewestRecordRegardlessOfOrder() throws {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let records = [
      persistedRecord(id: "1", value: "newest", count: 1, lastUsedAt: 20),
      persistedRecord(id: "1", value: "older", count: 1, lastUsedAt: 10)
    ]
    let data = try JSONSerialization.data(withJSONObject: records)
    context.defaults.set(data, forKey: context.storageKey)

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8,
      now: { Date(timeIntervalSince1970: 100) }
    )

    #expect(store.suggestions(limit: 1).first?.selection.value == "newest")
    #expect(store.suggestions().first?.count == 2)
  }

  @Test func emptyStoreHasNoSuggestions() {
    let context = makeContext()
    defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

    let store = EmojiUsageStore(
      defaults: context.defaults,
      storageKey: context.storageKey,
      historyLimit: 8
    )

    #expect(store.suggestions(limit: 1).isEmpty)
    #expect(store.suggestions(limit: 1).first?.selection == nil)
    #expect(store.suggestions().isEmpty)
  }
}

private struct TestContext {
  let suiteName: String
  let storageKey: String
  let defaults: UserDefaults
}

private func makeContext() -> TestContext {
  let suiteName = "EmojiUsageStoreTests.\(UUID().uuidString)"
  let storageKey = "EmojiUsageStoreTests.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    fatalError("Expected a test suite-backed UserDefaults instance")
  }
  defaults.removePersistentDomain(forName: suiteName)

  return TestContext(
    suiteName: suiteName,
    storageKey: storageKey,
    defaults: defaults
  )
}

private func persistedRecord(
  id: String,
  value: String,
  count: Int,
  lastUsedAt: TimeInterval
) -> [String: Any] {
  [
    "selection": [
      "id": id,
      "value": value
    ],
    "count": count,
    "lastUsedAt": lastUsedAt
  ]
}
