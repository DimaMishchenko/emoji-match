import Foundation

nonisolated struct EmojiSearchIssue: Error, Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case missingCredential
    case unreadableCredential
    case rejectedCredential
    case rateLimited
    case challenge
    case offline
    case timedOut
    case inputTooLong
    case modelNotInstalled
    case modelUnavailable
    case malformedResponse
    case refusal
    case unavailable
  }

  enum Recovery: Sendable, Equatable {
    case settings
    case retry
    case wait
    case none
  }

  let kind: Kind
  let message: String
  let recovery: Recovery
  let retryAt: Date?

  init(_ kind: Kind, retryAt: Date? = nil) {
    self.kind = kind
    self.retryAt = retryAt
    switch kind {
    case .missingCredential:
      message = "Add an API key in Settings → Search."
      recovery = .settings
    case .unreadableCredential:
      message = "Couldn’t read the saved API key. Check Settings → Search."
      recovery = .settings
    case .rejectedCredential:
      message = "The API key was rejected. Update it in Settings → Search."
      recovery = .settings
    case .rateLimited:
      message = "Search is rate limited. Try again after the cooldown."
      recovery = .wait
    case .challenge:
      message = "Web search requested a verification challenge. Try again after the cooldown."
      recovery = .wait
    case .offline:
      message = "You appear to be offline. Check your connection and try again."
      recovery = .retry
    case .timedOut:
      message = "Search timed out. Try again."
      recovery = .retry
    case .inputTooLong:
      message = "This query is too long. Shorten it to search."
      recovery = .none
    case .modelNotInstalled:
      message = "Download multilingual search to use it offline."
      recovery = .settings
    case .modelUnavailable:
      message = "The search model is unavailable. Check Search settings."
      recovery = .settings
    case .malformedResponse:
      message = "Search returned an invalid response. Try again."
      recovery = .retry
    case .refusal:
      message = "Search couldn’t answer this query. Try different words."
      recovery = .none
    case .unavailable:
      message = "Search is temporarily unavailable. Try again."
      recovery = .retry
    }
  }

  private init(fallbackMessage: String) {
    kind = .unavailable
    message = fallbackMessage
    recovery = .retry
    retryAt = nil
  }

  static func from(_ error: any Error, fallbackMessage: String) -> Self {
    if let issue = error as? Self { return issue }
    if let error = error as? EmojiLunaSearchError {
      switch error {
      case .invalidInput: return Self(.inputTooLong)
      case .httpStatus(401), .httpStatus(403): return Self(.rejectedCredential)
      case .httpStatus(404), .unexpectedModel: return Self(.modelUnavailable)
      case .httpStatus(429): return Self(.rateLimited)
      case .rateLimited(let date): return Self(.rateLimited, retryAt: date)
      case .timedOut: return Self(.timedOut)
      case .offline: return Self(.offline)
      case .refusal: return Self(.refusal)
      case .malformedResponse, .incompleteResponse, .noValidMatches, .responseTooLarge:
        return Self(.malformedResponse)
      default: return Self(.unavailable)
      }
    }
    if let error = error as? DuckDuckGoEmojiSearchError {
      switch error {
      case .queryTooLong: return Self(.inputTooLong)
      case .challenge, .httpStatus(202), .httpStatus(403): return Self(.challenge)
      case .httpStatus(429): return Self(.rateLimited)
      case .malformedResponse, .responseTooLarge: return Self(.malformedResponse)
      default: return Self(.unavailable)
      }
    }
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
        return Self(.offline)
      case .timedOut: return Self(.timedOut)
      default: return Self(.unavailable)
      }
    }
    return Self(fallbackMessage: fallbackMessage)
  }
}
