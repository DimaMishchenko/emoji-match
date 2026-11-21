import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiAsyncSearchModelTests {
  @Test func initialPrefillAndLaterEditsAreBothSearchQueries() async {
    let recorder = WebSearchRecorder(result: [Self.cat])
    let model = EmojiAsyncSearchModel(
      search: { await recorder.search($0, $1) }, debounce: .zero)
    await model.request(query: " selected phrase ", localeIdentifier: "en-GB")
    await model.request(query: "edited phrase", localeIdentifier: "en-GB")
    #expect(
      await recorder.calls == [
        .init(query: "selected phrase", locale: "en-GB"),
        .init(query: "edited phrase", locale: "en-GB")
      ])
    #expect(model.matches(for: "selected phrase", localeIdentifier: "en-GB").isEmpty)
    #expect(model.matches(for: "edited phrase", localeIdentifier: "en-GB") == [Self.cat])
  }

  @Test func debounceAndWhitespacePreventDispatch() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .milliseconds(40))
    let pending = Task { await model.request(query: "first", localeIdentifier: "en") }
    try await waitUntil { model.isLoading }
    await model.request(query: " \n\t ", localeIdentifier: "en")
    await pending.value
    try await Task.sleep(for: .milliseconds(60))
    #expect(await provider.calls.isEmpty)
    #expect(!model.isLoading)
    #expect(model.failure == nil)
    #expect(model.matches(for: "first", localeIdentifier: "en").isEmpty)

    let settled = Task { await model.request(query: "ordinary cat", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    await provider.complete(0, with: .success([Self.cat]))
    await settled.value
    #expect(model.matches(for: "ordinary cat", localeIdentifier: "en") == [Self.cat])
  }

  @Test func noncooperativeOldSuccessCannotReplaceNewResultsOrPopulateCache() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let old = Task { await model.request(query: "old", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    let current = Task { await model.request(query: "new", localeIdentifier: "en") }
    try await provider.waitForCalls(2)
    await provider.complete(1, with: .success([Self.cat]))
    await current.value
    await provider.complete(0, with: .success([Self.dog]))
    await old.value
    #expect(model.matches(for: "new", localeIdentifier: "en") == [Self.cat])
    #expect(model.failure == nil)
    #expect(!model.isLoading)

    let retry = Task { await model.request(query: "old", localeIdentifier: "en") }
    try await provider.waitForCalls(3)
    await provider.complete(2, with: .success([]))
    await retry.value
  }

  @Test func obsoleteFailureDoesNotStopCurrentLoadingOrPublishAnError() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let old = Task { await model.request(query: "old", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    let current = Task { await model.request(query: "current", localeIdentifier: "en") }
    try await provider.waitForCalls(2)
    await provider.complete(0, with: .failure(WebSearchFixtureError.privateServerBody))
    await old.value
    #expect(model.isLoading)
    #expect(model.failure == nil)
    await provider.complete(1, with: .success([Self.cat]))
    await current.value
    #expect(model.failure == nil)
  }

  @Test func currentFailureUsesOwnedMessageAndOldFailureCannotOverwriteIt() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let old = Task { await model.request(query: "old", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    let current = Task { await model.request(query: "current", localeIdentifier: "en") }
    try await provider.waitForCalls(2)
    await provider.complete(1, with: .failure(WebSearchFixtureError.privateServerBody))
    await current.value
    #expect(model.failure == "Online search is unavailable. Local results are still available.")
    #expect(!model.isLoading)
    #expect(model.matches(for: "current", localeIdentifier: "en").isEmpty)
    await provider.complete(0, with: .failure(CancellationError()))
    await old.value
    #expect(model.failure == "Online search is unavailable. Local results are still available.")
    await model.request(query: "", localeIdentifier: "en")
    #expect(model.failure == nil)
  }

  @Test func cachePreservesFullPhraseLocaleAndUsesBoundedLeastRecentEntries() async {
    let recorder = WebSearchRecorder(result: [Self.cat])
    let model = EmojiAsyncSearchModel(
      search: { await recorder.search($0, $1) }, debounce: .zero, cacheCapacity: 2)
    await model.request(query: "  cat with a hat \n", localeIdentifier: "en")
    await model.request(query: "cat with a hat", localeIdentifier: "fr")
    await model.request(query: "cat with a hat", localeIdentifier: "en")
    #expect(await recorder.calls.count == 2)
    await model.request(query: "cat", localeIdentifier: "en")
    await model.request(query: "cat with a hat", localeIdentifier: "en")
    #expect(await recorder.calls.count == 3)
    await model.request(query: "cat with a hat", localeIdentifier: "fr")
    #expect(
      await recorder.calls == [
        .init(query: "cat with a hat", locale: "en"),
        .init(query: "cat with a hat", locale: "fr"),
        .init(query: "cat", locale: "en"),
        .init(query: "cat with a hat", locale: "fr")
      ])
  }

  @Test func cacheExpiresAtTTLAndCanBeDisabled() async {
    let clock = WebSearchClockFixture()
    let recorder = WebSearchRecorder(result: [])
    let model = EmojiAsyncSearchModel(
      search: { await recorder.search($0, $1) }, debounce: .zero,
      cacheTTL: .seconds(10), now: { clock.instant })
    await model.request(query: "cat", localeIdentifier: "en")
    clock.instant += .seconds(9)
    await model.request(query: "cat", localeIdentifier: "en")
    #expect(await recorder.calls.count == 1)
    clock.instant += .seconds(1)
    await model.request(query: "cat", localeIdentifier: "en")
    #expect(await recorder.calls.count == 2)
    let uncached = EmojiAsyncSearchModel(
      search: { await recorder.search($0, $1) }, debounce: .zero, cacheCapacity: 0)
    await uncached.request(query: "cat", localeIdentifier: "en")
    await uncached.request(query: "cat", localeIdentifier: "en")
    #expect(await recorder.calls.count == 4)
  }

  @Test func visibleResultsMatchQueryAndLocaleBeforeAnotherRequestStarts() async {
    let result = [Self.cat]
    let model = EmojiAsyncSearchModel(search: { _, _ in result }, debounce: .zero)
    await model.request(query: "cat", localeIdentifier: "en")
    #expect(model.matches(for: " cat \n", localeIdentifier: "en") == result)
    #expect(model.matches(for: "cat with hat", localeIdentifier: "en").isEmpty)
    #expect(model.matches(for: "cat", localeIdentifier: "fr").isEmpty)
    #expect(model.matches(for: " \n", localeIdentifier: "en").isEmpty)
    #expect(model.matches(for: "cat", localeIdentifier: "en") == result)
  }

  @Test func providerSnapshotsHideStaleLoadingAndFailureAsWellAsMatches() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero,
      failureMessage: "Provider failed")
    let pending = Task { await model.request(query: "cat", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    #expect(model.result(for: "cat", localeIdentifier: "en", provider: .miniLM).isLoading)
    for (query, locale) in [("dog", "en"), ("cat", "fr"), ("", "en")] {
      #expect(
        model.result(for: query, localeIdentifier: locale, provider: .miniLM)
          == EmojiSearchProviderResult(provider: .miniLM, matches: [], isPending: !query.isEmpty))
    }
    await provider.complete(0, with: .failure(WebSearchFixtureError.privateServerBody))
    await pending.value
    #expect(
      model.result(for: "cat", localeIdentifier: "en", provider: .miniLM).failure
        == "Provider failed")
    #expect(model.result(for: "dog", localeIdentifier: "en", provider: .miniLM).failure == nil)
    model.cancel()
    #expect(model.result(for: "cat", localeIdentifier: "en", provider: .miniLM).failure == nil)
  }

  @Test func dismissRejectsPendingResultsAndRetainsUsefulCache() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let cached = Task { await model.request(query: "cached", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    await provider.complete(0, with: .success([Self.cat]))
    await cached.value
    let pending = Task { await model.request(query: "pending", localeIdentifier: "en") }
    try await provider.waitForCalls(2)
    model.cancel()
    #expect(!model.isLoading)
    #expect(model.matches(for: "cached", localeIdentifier: "en").isEmpty)
    await provider.complete(1, with: .success([Self.dog]))
    await pending.value
    #expect(model.matches(for: "pending", localeIdentifier: "en").isEmpty)
    #expect(model.failure == nil)
    await model.request(query: "cached", localeIdentifier: "en")
    #expect(model.matches(for: "cached", localeIdentifier: "en") == [Self.cat])
    #expect(await provider.calls.count == 2)
  }

  @Test func callerCancellationInvalidatesANoncooperativeOperation() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let pending = Task { await model.request(query: "cat", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    pending.cancel()
    try await waitUntil { !model.isLoading }
    await provider.complete(0, with: .failure(WebSearchFixtureError.privateServerBody))
    await pending.value
    #expect(model.failure == nil)
    #expect(model.matches(for: "cat", localeIdentifier: "en").isEmpty)
  }

  @Test func oversizedRawInputIsRejectedBeforeNormalizationCachingOrDispatch() async {
    let recorder = WebSearchRecorder(result: [Self.cat])
    let model = EmojiAsyncSearchModel(
      search: { await recorder.search($0, $1) }, debounce: .zero)
    await model.request(query: "cat", localeIdentifier: "en")
    await model.request(query: String(repeating: " ", count: 2001) + "cat", localeIdentifier: "en")
    #expect(model.issue == EmojiSearchIssue(.inputTooLong))
    #expect(model.failure == model.issue?.message)
    #expect(!model.isLoading)
    #expect(await recorder.calls.count == 1)
    #expect(model.matches(for: "cat", localeIdentifier: "en").isEmpty)
    await model.request(query: "cat", localeIdentifier: "en")
    #expect(model.issue == nil)
    #expect(model.matches(for: "cat", localeIdentifier: "en") == [Self.cat])
    #expect(await recorder.calls.count == 1)
  }

  @Test func typedIssueSurvivesNoncooperativeStaleFailureAndClearsOnCancel() async throws {
    let provider = WebSearchProviderFixture()
    let model = EmojiAsyncSearchModel(
      search: { try await provider.search($0, $1) }, debounce: .zero)
    let old = Task { await model.request(query: "old", localeIdentifier: "en") }
    try await provider.waitForCalls(1)
    let current = Task { await model.request(query: "new", localeIdentifier: "en") }
    try await provider.waitForCalls(2)
    let expected = EmojiSearchIssue(.rateLimited, retryAt: Date(timeIntervalSince1970: 5000))
    await provider.complete(1, with: .failure(expected))
    await current.value
    await provider.complete(0, with: .failure(EmojiSearchIssue(.rejectedCredential)))
    await old.value
    #expect(model.issue == expected)
    #expect(model.failure == expected.message)
    #expect(model.result(for: "new", localeIdentifier: "en", provider: .luna).issue == expected)
    #expect(!model.result(for: "new", localeIdentifier: "en", provider: .luna).isPending)
    #expect(model.result(for: "old", localeIdentifier: "en", provider: .luna).isPending)
    #expect(model.result(for: "old", localeIdentifier: "en", provider: .luna).issue == nil)
    model.cancel()
    #expect(model.issue == nil)
    #expect(model.failure == nil)
  }

  @Test func providerIssuesMapToOwnedMessagesAndUnknownErrorsUseInjectedFallback() async {
    let cases: [(any Error, EmojiSearchIssue.Kind)] = [
      (EmojiLunaSearchError.httpStatus(401), .rejectedCredential),
      (EmojiLunaSearchError.httpStatus(403), .rejectedCredential),
      (EmojiLunaSearchError.httpStatus(404), .modelUnavailable),
      (EmojiLunaSearchError.timedOut, .timedOut),
      (EmojiLunaSearchError.offline, .offline),
      (EmojiLunaSearchError.refusal, .refusal),
      (EmojiLunaSearchError.malformedResponse, .malformedResponse),
      (DuckDuckGoEmojiSearchError.challenge, .challenge),
      (URLError(.notConnectedToInternet), .offline)
    ]
    for (error, kind) in cases {
      let model = EmojiAsyncSearchModel(search: { _, _ in throw error }, debounce: .zero)
      await model.request(query: "cat", localeIdentifier: "en")
      #expect(model.issue?.kind == kind)
      #expect(model.failure == EmojiSearchIssue(kind).message)
    }
    let model = EmojiAsyncSearchModel(
      search: { _, _ in throw WebSearchFixtureError.privateServerBody }, debounce: .zero,
      failureMessage: "Owned fallback")
    await model.request(query: "cat", localeIdentifier: "en")
    #expect(model.issue?.message == "Owned fallback")
  }

  private static let cat = EmojiSearchMatch(id: "1F408", value: "🐈", score: 0.9, sourceURLs: [])
  private static let dog = EmojiSearchMatch(id: "1F415", value: "🐕", score: 0.8, sourceURLs: [])

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw WebSearchFixtureError.timeout }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

private struct WebSearchCall: Equatable, Sendable {
  let query: String
  let locale: String
}

private enum WebSearchFixtureError: Error {
  case privateServerBody
  case timeout
}

private final class WebSearchClockFixture {
  var instant = ContinuousClock.now
}

private actor WebSearchRecorder {
  private(set) var calls: [WebSearchCall] = []
  private let result: [EmojiSearchMatch]

  init(result: [EmojiSearchMatch]) {
    self.result = result
  }

  func search(_ query: String, _ locale: String) -> [EmojiSearchMatch] {
    calls.append(WebSearchCall(query: query, locale: locale))
    return result
  }
}

private actor WebSearchProviderFixture {
  private(set) var calls: [WebSearchCall] = []
  private var continuations: [Int: CheckedContinuation<[EmojiSearchMatch], Error>] = [:]

  func search(_ query: String, _ locale: String) async throws -> [EmojiSearchMatch] {
    let index = calls.count
    calls.append(WebSearchCall(query: query, locale: locale))
    return try await withCheckedThrowingContinuation { continuations[index] = $0 }
  }

  func complete(_ index: Int, with result: Result<[EmojiSearchMatch], Error>) {
    continuations.removeValue(forKey: index)?.resume(with: result)
  }

  func waitForCalls(_ count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while calls.count < count {
      guard ContinuousClock.now < deadline else { throw WebSearchFixtureError.timeout }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
