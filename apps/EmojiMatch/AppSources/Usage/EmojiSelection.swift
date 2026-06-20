import Foundation

struct EmojiSelection: Identifiable, Codable, Sendable {
  let id: String
  let value: String
}

extension EmojiSelection: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }
}

extension EmojiSelection: Hashable {
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
