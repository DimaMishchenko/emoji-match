import Foundation

struct EmojiAssetReference: Codable, Sendable, Hashable {
  enum Kind: String, Codable, Sendable {
    case adaptiveGlyph
    case image
  }

  let kind: Kind
  let identifier: String
  let typeIdentifier: String
}

struct EmojiSelection: Identifiable, Codable, Sendable {
  let id: String
  let value: String
  let asset: EmojiAssetReference?

  nonisolated init(id: String, value: String, asset: EmojiAssetReference? = nil) {
    self.id = id
    self.value = value
    self.asset = asset
  }
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
