import Foundation
import Observation

@Observable
final class EmojiAsyncSearchModel {
  private struct Key: Hashable {
    let query: String
    let localeIdentifier: String

    init(query: String, localeIdentifier: String) {
      self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      self.localeIdentifier = localeIdentifier
    }
  }

  private struct CacheEntry {
    let matches: [EmojiSearchMatch]
    let insertedAt: ContinuousClock.Instant
  }

  private(set) var isLoading = false
  private(set) var failure: String?
  private(set) var issue: EmojiSearchIssue?
  private var visibleKey: Key?
  private var visibleMatches: [EmojiSearchMatch] = []
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private var operation: Task<[EmojiSearchMatch], Error>?
  @ObservationIgnored private var cache: [Key: CacheEntry] = [:]
  @ObservationIgnored private var recency: [Key] = []
  private let failureMessage: String
  private let search: @Sendable (String, String) async throws -> [EmojiSearchMatch]
  private let debounce: Duration
  private let cacheCapacity: Int
  private let cacheTTL: Duration
  private let now: () -> ContinuousClock.Instant

  init(
    search: @escaping @Sendable (String, String) async throws -> [EmojiSearchMatch],
    debounce: Duration = .milliseconds(300),
    failureMessage: String = "Online search is unavailable. Local results are still available.",
    cacheCapacity: Int = 64,
    cacheTTL: Duration = .seconds(300),
    now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.search = search
    self.failureMessage = failureMessage
    self.debounce = max(.zero, debounce)
    self.cacheCapacity = max(0, cacheCapacity)
    self.cacheTTL = max(.zero, cacheTTL)
    self.now = now
  }

  func request(query: String, localeIdentifier: String) async {
    guard !Task.isCancelled else { return }
    cancel()
    guard EmojiSearchInput.accepts(query) else {
      issue = EmojiSearchIssue(.inputTooLong)
      failure = issue?.message
      return
    }
    let key = Key(query: query, localeIdentifier: localeIdentifier)
    guard !key.query.isEmpty else { return }
    visibleKey = key
    if let cached = cachedMatches(for: key) {
      visibleMatches = cached
      return
    }

    let id = requestID
    let search = search
    let debounce = debounce
    let task = Task {
      try await Task.sleep(for: debounce)
      try Task.checkCancellation()
      return try await search(key.query, key.localeIdentifier)
    }
    operation = task
    isLoading = true

    await withTaskCancellationHandler {
      do {
        let results = try await task.value
        guard requestID == id, !Task.isCancelled, !task.isCancelled else { return }
        visibleMatches = results
        store(results, for: key)
        isLoading = false
        operation = nil
      } catch {
        guard requestID == id, !Task.isCancelled, !task.isCancelled else { return }
        isLoading = false
        operation = nil
        if !(error is CancellationError) {
          issue = EmojiSearchIssue.from(error, fallbackMessage: failureMessage)
          failure = issue?.message
        }
      }
    } onCancel: {
      task.cancel()
      Task { @MainActor [weak self] in
        guard let self, self.requestID == id else { return }
        self.cancel()
      }
    }
  }

  func matches(for query: String, localeIdentifier: String) -> [EmojiSearchMatch] {
    guard EmojiSearchInput.accepts(query) else { return [] }
    let key = Key(query: query, localeIdentifier: localeIdentifier)
    guard !key.query.isEmpty, visibleKey == key else { return [] }
    return visibleMatches
  }

  func result(
    for query: String, localeIdentifier: String, provider: EmojiSearchProvider
  ) -> EmojiSearchProviderResult {
    guard EmojiSearchInput.accepts(query) else {
      return EmojiSearchProviderResult(provider: provider, matches: [])
    }
    let key = Key(query: query, localeIdentifier: localeIdentifier)
    guard !key.query.isEmpty else {
      return EmojiSearchProviderResult(provider: provider, matches: [])
    }
    guard visibleKey == key else {
      return EmojiSearchProviderResult(provider: provider, matches: [], isPending: true)
    }
    return EmojiSearchProviderResult(
      provider: provider, matches: visibleMatches, isLoading: isLoading, failure: failure,
      issue: issue)
  }

  func cancel() {
    requestID = UUID()
    operation?.cancel()
    operation = nil
    visibleKey = nil
    visibleMatches = []
    isLoading = false
    failure = nil
    issue = nil
  }

  private func cachedMatches(for key: Key) -> [EmojiSearchMatch]? {
    let instant = now()
    let expired = cache.keys.filter { key in
      guard let entry = cache[key] else { return true }
      return entry.insertedAt.duration(to: instant) >= cacheTTL
    }
    for key in expired {
      cache[key] = nil
      recency.removeAll { $0 == key }
    }
    guard let entry = cache[key] else { return nil }
    recency.removeAll { $0 == key }
    recency.append(key)
    return entry.matches
  }

  private func store(_ matches: [EmojiSearchMatch], for key: Key) {
    guard cacheCapacity > 0, cacheTTL > .zero else { return }
    cache[key] = CacheEntry(matches: matches, insertedAt: now())
    recency.removeAll { $0 == key }
    recency.append(key)
    while recency.count > cacheCapacity {
      cache[recency.removeFirst()] = nil
    }
  }
}
