import Foundation

nonisolated struct EmojiSearchMatch: Equatable, Sendable {
  let id: String
  let value: String
  let score: Double
  let sourceURLs: [URL]
}
