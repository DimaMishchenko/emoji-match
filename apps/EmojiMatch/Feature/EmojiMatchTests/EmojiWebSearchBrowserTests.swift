import Foundation
import Testing

@testable import EmojiMatch

struct EmojiWebSearchBrowserTests {
  @Test func dispatchSpacingUsesMonotonicTimeAcrossNavigations() {
    var gate = EmojiWebSearchBrowserGate()
    let instant = ContinuousClock.now
    #expect(gate.spacingDelay(at: instant) == .zero)
    let id = UUID()
    gate.begin(id, at: instant)
    let ended = gate.end(id)
    #expect(ended)
    #expect(gate.spacingDelay(at: instant + .milliseconds(250)) == .milliseconds(750))
    #expect(gate.spacingDelay(at: instant + .seconds(1)) == .zero)
  }

  @Test func onlyExpectedHTMLMainFrameURLsAreAllowed() {
    for value in [
      "https://html.duckduckgo.com/html/?q=test", "https://html.duckduckgo.com/html",
      "https://html.duckduckgo.com:443/html/"
    ] {
      #expect(EmojiWebSearchBrowserPolicy.allows(URL(string: value)))
    }
    for value in [
      "http://html.duckduckgo.com/html/", "https://duckduckgo.com/html/",
      "https://html.duckduckgo.com/l/?uddg=https://example.com",
      "https://html.duckduckgo.com.evil.example/html/", "https://example.com/",
      "https://user:secret@html.duckduckgo.com/html/", "https://html.duckduckgo.com:8443/html/",
      "https://html.duckduckgo.com/html/#fragment", "file:///html/"
    ] {
      #expect(!EmojiWebSearchBrowserPolicy.allows(URL(string: value)))
    }
    #expect(!EmojiWebSearchBrowserPolicy.allows(nil))
  }

  @Test func supersededCancellationAndLateCompletionCannotEndNewRequest() {
    var gate = EmojiWebSearchBrowserGate()
    let old = UUID()
    let current = UUID()
    gate.begin(old)
    let endedOld = gate.end(old)
    #expect(endedOld)
    gate.begin(current)
    #expect(!gate.accepts(old))
    let endedOldAgain = gate.end(old)
    #expect(!endedOldAgain)
    #expect(gate.accepts(current))
    let endedCurrent = gate.end(current)
    #expect(endedCurrent)
    let endedCurrentAgain = gate.end(current)
    #expect(!endedCurrentAgain)
    gate.begin(old)
    gate.begin(current)
    let endedReplaced = gate.end(old)
    #expect(!endedReplaced)
    #expect(gate.accepts(current))
  }

  @Test func cooldownSurvivesCompletionAndExpiresWithoutRetry() throws {
    var gate = EmojiWebSearchBrowserGate()
    let now = Date(timeIntervalSince1970: 1_000)
    let id = UUID()
    gate.begin(id)
    gate.pause(error: .challenge, response: nil, at: now)
    let endedPaused = gate.end(id)
    #expect(endedPaused)
    #expect(
      gate.dispatchError(at: now.addingTimeInterval(59))
        == EmojiSearchIssue(.challenge, retryAt: now.addingTimeInterval(60)))
    #expect(gate.dispatchError(at: now.addingTimeInterval(60)) == nil)
    let url = try #require(URL(string: "https://html.duckduckgo.com/html/"))
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: 429,
        httpVersion: nil, headerFields: ["Retry-After": "120"]))
    gate.pause(error: .httpStatus(429), response: response, at: now)
    #expect(
      gate.dispatchError(at: now.addingTimeInterval(119))
        == EmojiSearchIssue(.rateLimited, retryAt: now.addingTimeInterval(120)))
    #expect(gate.dispatchError(at: now.addingTimeInterval(120)) == nil)
  }

  @Test func retryAfterPreservesLongDeadlinesAndSupportsHTTPDate() throws {
    let now = Date(timeIntervalSince1970: 0)
    for (value, expected) in [
      ("0", 60.0), ("-10", 60), ("10000", 10000), ("nan", 60), ("invalid", 60),
      ("Thu, 01 Jan 1970 00:02:00 GMT", 120),
      ("Thu, 01 Jan 1970 01:00:00 GMT", 3600)
    ] {
      let url = try #require(URL(string: "https://html.duckduckgo.com/html/"))
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value]))
      #expect(EmojiWebSearchBrowserPolicy.pauseDuration(response: response, at: now) == expected)
    }
  }

  @Test func serializedDOMLimitCountsUTF8Bytes() throws {
    let limit = EmojiWebSearchBrowserPolicy.maximumDOMBytes
    let accepted = String(repeating: "é", count: limit / 2)
    let result = try EmojiWebSearchBrowserPolicy.decode([
      "challenge": false, "oversized": false, "html": accepted
    ])
    #expect(result.data.count == limit)
    #expect(!result.challenge)
    #expect(throws: DuckDuckGoEmojiSearchError.responseTooLarge) {
      try EmojiWebSearchBrowserPolicy.decode([
        "challenge": false, "oversized": false, "html": accepted + "é"
      ])
    }
    #expect(throws: DuckDuckGoEmojiSearchError.responseTooLarge) {
      try EmojiWebSearchBrowserPolicy.decode(["challenge": false, "oversized": true])
    }
  }

  @Test func contentDecodingRequiresStructuredDOMChallengeFlag() throws {
    let html = "<html><style>.anomaly-modal { color: red; }</style><body></body></html>"
    let content = try EmojiWebSearchBrowserPolicy.decode([
      "challenge": false, "oversized": false, "html": html
    ])
    #expect(!content.challenge)
    #expect(String(data: content.data, encoding: .utf8) == html)
    #expect(try EmojiWebSearchBrowserPolicy.decode(["challenge": true]).challenge)
    for body: [String: Any] in [[:], ["html": html], ["challenge": false], ["challenge": "true"]] {
      #expect(throws: DuckDuckGoEmojiSearchError.malformedResponse) {
        try EmojiWebSearchBrowserPolicy.decode(body)
      }
    }
  }
}
