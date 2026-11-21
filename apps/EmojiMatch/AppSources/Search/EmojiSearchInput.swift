import Foundation

nonisolated enum EmojiSearchInput {
  static let maximumUnicodeScalars = 2_000
  static let maximumUTF8Bytes = 8_000

  static func accepts(_ query: String) -> Bool {
    query.utf8.prefix(maximumUTF8Bytes + 1).count <= maximumUTF8Bytes
      && query.unicodeScalars.prefix(maximumUnicodeScalars + 1).count <= maximumUnicodeScalars
  }

  static func normalized(_ query: String) -> String? {
    guard accepts(query) else { return nil }
    return query.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
