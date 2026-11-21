import Foundation

nonisolated struct EmojiMiniLMTokenizer: Sendable {
  enum Failure: Error { case invalidVocabulary, invalidInput }

  private let vocabulary: [String: Int]
  private let specialTokens = ["[UNK]", "[SEP]", "[PAD]", "[CLS]", "[MASK]"]

  init(vocabularyURL: URL) throws {
    var tokens = try String(contentsOf: vocabularyURL, encoding: .utf8)
      .components(separatedBy: "\n")
    if tokens.last == "" { tokens.removeLast() }
    guard tokens.count == 30522, Set(tokens).count == tokens.count,
      !tokens.contains(""), tokens[0] == "[PAD]", tokens[100] == "[UNK]",
      tokens[101] == "[CLS]", tokens[102] == "[SEP]", tokens[103] == "[MASK]"
    else { throw Failure.invalidVocabulary }
    vocabulary = Dictionary(
      uniqueKeysWithValues: tokens.enumerated().map { ($0.element, $0.offset) })
  }

  func tokenIDs(for text: String) throws -> [Int] {
    try Task.checkCancellation()
    guard text.utf8.prefix(8193).count <= 8192,
      text.unicodeScalars.prefix(2049).count <= 2048
    else { throw Failure.invalidInput }
    var pieces: [Int] = [101]
    var remaining = text[...]
    while !remaining.isEmpty && pieces.count < 255 {
      let found =
        try specialTokens.compactMap { token -> (Range<String.Index>, String)? in
          try Task.checkCancellation()
          return remaining.range(of: token).map { ($0, token) }
        }
        .min { $0.0.lowerBound < $1.0.lowerBound }
      guard let (range, token) = found else {
        try appendBasic(String(remaining), to: &pieces)
        break
      }
      try appendBasic(String(remaining[..<range.lowerBound]), to: &pieces)
      if pieces.count < 255 { pieces.append(vocabulary[token] ?? 100) }
      remaining = remaining[range.upperBound...]
    }
    return Array(pieces.prefix(255)) + [102]
  }

  private func appendBasic(_ text: String, to ids: inout [Int]) throws {
    var cleaned = ""
    for scalar in text.unicodeScalars {
      try Task.checkCancellation()
      if scalar.value == 0 || scalar.value == 0xFFFD { continue }
      let category = scalar.properties.generalCategory
      if [Unicode.GeneralCategory.control, .format, .privateUse, .surrogate, .unassigned]
        .contains(category)
        && ![9, 10, 13].contains(scalar.value)
      {
        continue
      }
      if scalar.properties.isWhitespace {
        cleaned.append(" ")
      } else if isChinese(scalar.value) {
        cleaned.append(" \(scalar) ")
      } else {
        cleaned.unicodeScalars.append(scalar)
      }
    }
    for word in cleaned.split(separator: " ") {
      try Task.checkCancellation()
      let normalized = String(word).lowercased().decomposedStringWithCanonicalMapping
      try Task.checkCancellation()
      var tokens: [String] = []
      var current = ""
      for scalar in normalized.unicodeScalars {
        try Task.checkCancellation()
        if scalar.properties.generalCategory == .nonspacingMark { continue }
        if isPunctuation(scalar) {
          if !current.isEmpty { tokens.append(current); current = "" }
          tokens.append(String(scalar))
        } else {
          current.unicodeScalars.append(scalar)
        }
      }
      if !current.isEmpty { tokens.append(current) }
      for token in tokens {
        try Task.checkCancellation()
        ids.append(contentsOf: wordPieces(token))
        if ids.count >= 255 { return }
      }
    }
  }

  private func wordPieces(_ token: String) -> [Int] {
    let scalars = Array(token.unicodeScalars.prefix(101))
    guard scalars.count <= 100 else { return [100] }
    var start = 0
    var result: [Int] = []
    while start < scalars.count {
      var end = scalars.count
      var match: Int?
      while start < end {
        let piece =
          (start == 0 ? "" : "##") + String(String.UnicodeScalarView(scalars[start..<end]))
        if let id = vocabulary[piece] { match = id; break }
        end -= 1
      }
      guard let match else { return [100] }
      result.append(match)
      start = end
    }
    return result
  }

  private func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value)
      || (123...126).contains(value)
    {
      return true
    }
    return [
      .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation
    ]
    .contains(scalar.properties.generalCategory)
  }

  private func isChinese(_ value: UInt32) -> Bool {
    [
      (0x4E00...0x9FFF), (0x3400...0x4DBF), (0x20000...0x2A6DF), (0x2A700...0x2B73F),
      (0x2B740...0x2B81F), (0x2B820...0x2CEAF), (0xF900...0xFAFF), (0x2F800...0x2FA1F)
    ]
    .contains { $0.contains(Int(value)) }
  }
}
