import Foundation
import Synchronization
import Testing

@testable import EmojiMatch

struct EmojiLunaDispatchGateTests {
  @Test func rejectedCredentialsStayBlockedUntilKeyActuallyChanges() async throws {
    let gate = EmojiLunaDispatchGate(minimumSpacing: 0)
    let admission = try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(401), admission: admission)
    for _ in 0..<3 {
      await #expect(throws: EmojiSearchIssue(.rejectedCredential)) {
        try await gate.waitToDispatch(credential: "synthetic-a")
      }
    }
    let changed = try await gate.waitToDispatch(credential: "synthetic-b")
    await gate.record(try response(403), admission: admission)
    try await gate.waitToDispatch(credential: "synthetic-b")
    await gate.record(try response(403), admission: changed)
    await #expect(throws: EmojiSearchIssue(.rejectedCredential)) {
      try await gate.waitToDispatch(credential: "synthetic-b")
    }
  }

  @Test func rateLimitHasNoRetryAndSurvivesPickerRecreation() async throws {
    let clock = GateClock()
    let gate = EmojiLunaDispatchGate(minimumSpacing: 0, now: { clock.now })
    let admission = try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(429, retryAfter: "3600"), admission: admission)
    let issue = EmojiSearchIssue(.rateLimited, retryAt: clock.now.addingTimeInterval(3600))
    await #expect(throws: issue) { try await gate.waitToDispatch(credential: "synthetic-a") }
    clock.advance(3599)
    await #expect(throws: issue) { try await gate.waitToDispatch(credential: "synthetic-a") }
    clock.advance(1)
    let later = try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(429), admission: later)
    await #expect(throws: EmojiSearchIssue(.rateLimited, retryAt: clock.now.addingTimeInterval(60)))
    {
      try await gate.waitToDispatch(credential: "synthetic-a")
    }
  }

  @Test func spacingWaitIsCancelableAndDoesNotBecomeARetry() async throws {
    let clock = GateClock()
    let waits = Mutex<[Duration]>([])
    let gate = EmojiLunaDispatchGate(
      minimumSpacing: 1, now: { clock.now }, monotonicNow: { clock.instant },
      sleep: { duration in
        waits.withLock { $0.append(duration) }
        throw CancellationError()
      })
    try await gate.waitToDispatch(credential: "synthetic-a")
    await #expect(throws: CancellationError.self) {
      try await gate.waitToDispatch(credential: "synthetic-a")
    }
    #expect(waits.withLock { $0 } == [.seconds(1)])
    clock.advance(1)
    try await gate.waitToDispatch(credential: "synthetic-a")
    #expect(waits.withLock { $0.count } == 1)
  }

  @Test func spacingRechecksRejectionAfterSuspension() async throws {
    let clock = GateClock()
    let waiter = GateWaiter()
    let gate = EmojiLunaDispatchGate(
      minimumSpacing: 1, now: { clock.now }, monotonicNow: { clock.instant },
      sleep: { _ in await waiter.wait() })
    let admission = try await gate.waitToDispatch(credential: "synthetic-a")
    let pending = Task { try await gate.waitToDispatch(credential: "synthetic-a") }
    try await waiter.waitForSuspension()
    await gate.record(try response(401), admission: admission)
    await waiter.resume()
    await #expect(throws: EmojiSearchIssue(.rejectedCredential)) { try await pending.value }
  }

  @Test func explicitCredentialWriteClearsOnlyAuthAndIgnoresOldResponses() async throws {
    let clock = GateClock()
    let gate = EmojiLunaDispatchGate(minimumSpacing: 0, now: { clock.now })
    let old = try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(401), admission: old)
    await gate.credentialsDidChange()
    let fresh = try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(403), admission: old)
    try await gate.waitToDispatch(credential: "synthetic-a")
    await gate.record(try response(429, retryAfter: "3600"), admission: fresh)
    await gate.credentialsDidChange()
    await #expect(
      throws: EmojiSearchIssue(.rateLimited, retryAt: clock.now.addingTimeInterval(3600))
    ) {
      try await gate.waitToDispatch(credential: "synthetic-a")
    }
  }

  @Test func dispatchSpacingIgnoresForwardAndBackwardWallClockJumps() async throws {
    let clock = GateClock()
    let waits = Mutex<[Duration]>([])
    let gate = EmojiLunaDispatchGate(
      minimumSpacing: 1, now: { clock.now }, monotonicNow: { clock.instant },
      sleep: { duration in
        waits.withLock { $0.append(duration) }
        throw CancellationError()
      })
    try await gate.waitToDispatch(credential: "synthetic-a")
    for adjustment in [3600.0, -7200.0] {
      clock.jumpWallClock(adjustment)
      await #expect(throws: CancellationError.self) {
        try await gate.waitToDispatch(credential: "synthetic-a")
      }
    }
    #expect(waits.withLock { $0 } == [.seconds(1), .seconds(1)])
    clock.advance(1)
    try await gate.waitToDispatch(credential: "synthetic-a")
    #expect(waits.withLock { $0.count } == 2)
  }

  private func response(_ status: Int, retryAfter: String? = nil) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://example.invalid/"))
    return try #require(
      HTTPURLResponse(
        url: url, statusCode: status,
        httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] }))
  }
}

nonisolated private final class GateClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1000))
  private let monotonic = Mutex(ContinuousClock.now)
  var now: Date { date.withLock { $0 } }
  var instant: ContinuousClock.Instant { monotonic.withLock { $0 } }
  func jumpWallClock(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
  func advance(_ seconds: TimeInterval) {
    jumpWallClock(seconds)
    monotonic.withLock { $0 = $0.advanced(by: .seconds(seconds)) }
  }
}

private actor GateWaiter {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func resume() { continuation?.resume(); continuation = nil }
  func waitForSuspension() async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while continuation == nil {
      if ContinuousClock.now > deadline { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}
