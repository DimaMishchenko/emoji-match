import CryptoKit
import Foundation

actor EmojiLunaDispatchGate {
  struct Admission: Sendable {
    fileprivate let revision: UUID
  }

  private var revision = UUID()
  private var credential: Data?
  private var rejected = false
  private var pauseUntil: Date?
  private var nextDispatch: ContinuousClock.Instant?
  private let spacing: TimeInterval
  private let monotonicNow: @Sendable () -> ContinuousClock.Instant
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    minimumSpacing: TimeInterval = 1,
    now: @escaping @Sendable () -> Date = { Date() },
    monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    spacing = minimumSpacing.isFinite ? max(0, minimumSpacing) : 1
    self.monotonicNow = monotonicNow
    self.now = now
    self.sleep = sleep
  }

  @discardableResult
  func waitToDispatch(credential key: String) async throws -> Admission {
    let digest = Data(SHA256.hash(data: Data(key.utf8)))
    if credential != digest {
      credential = digest
      rejected = false
      revision = UUID()
    }
    while true {
      try Task.checkCancellation()
      guard credential == digest else { throw CancellationError() }
      if rejected { throw EmojiSearchIssue(.rejectedCredential) }
      let instant = now()
      if let pauseUntil, instant < pauseUntil {
        throw EmojiSearchIssue(.rateLimited, retryAt: pauseUntil)
      }
      let monotonicInstant = monotonicNow()
      if let nextDispatch, monotonicInstant < nextDispatch {
        try await sleep(monotonicInstant.duration(to: nextDispatch))
        continue
      }
      nextDispatch = monotonicInstant.advanced(by: .seconds(spacing))
      return Admission(revision: revision)
    }
  }

  func credentialsDidChange() {
    rejected = false
    revision = UUID()
  }

  func record(_ response: HTTPURLResponse, admission: Admission) {
    guard admission.revision == revision else { return }
    if [401, 403].contains(response.statusCode) { rejected = true }
    if response.statusCode == 429 {
      let instant = now()
      let deadline = EmojiSearchRetryAfter.deadline(response: response, at: instant)
      pauseUntil = max(pauseUntil ?? deadline, deadline)
    }
  }
}

nonisolated enum EmojiSearchRetryAfter {
  static func deadline(response: HTTPURLResponse?, at now: Date) -> Date {
    guard let raw = response?.value(forHTTPHeaderField: "Retry-After") else {
      return now.addingTimeInterval(60)
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
      let deadline = now.addingTimeInterval(seconds)
      if deadline.timeIntervalSinceReferenceDate.isFinite { return deadline }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: value), date > now { return date }
    return now.addingTimeInterval(60)
  }
}
