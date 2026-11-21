import Foundation

nonisolated struct EmojiMultilingualTokenizer: Sendable {
  enum Failure: Error { case invalidVocabulary, invalidInput }

  private struct Vocabulary: Decodable {
    let pieces: [Piece]
    let charsmap: Data
  }

  private struct Piece: Decodable {
    let text: String
    let score: Double
  }

  private let pieces: [Data: Int]
  private let scores: [Double]
  private let maximumPieceBytes: Int
  private let unknownScore: Double
  private let normalizationTrie: [UInt32]
  private let replacements: [UInt8]
  private let specials = [("<s>", 0), ("<pad>", 1), ("</s>", 2), ("<unk>", 3), ("<mask>", 250001)]

  init(vocabularyURL: URL) throws {
    let vocabulary = try JSONDecoder()
      .decode(
        Vocabulary.self, from: Data(contentsOf: vocabularyURL))
    guard vocabulary.pieces.count == 250002, vocabulary.charsmap.count >= 4 else {
      throw Failure.invalidVocabulary
    }
    guard Set(vocabulary.pieces.map { Data($0.text.utf8) }).count == vocabulary.pieces.count,
      vocabulary.pieces.allSatisfy({ !$0.text.isEmpty && $0.score.isFinite }),
      specials.allSatisfy({ vocabulary.pieces[$0.1].text == $0.0 })
    else { throw Failure.invalidVocabulary }
    pieces = Dictionary(
      uniqueKeysWithValues: vocabulary.pieces.enumerated()
        .map { (Data($0.element.text.utf8), $0.offset) })
    scores = vocabulary.pieces.map(\.score)
    maximumPieceBytes = vocabulary.pieces.map { $0.text.utf8.count }.max() ?? 0
    unknownScore = (scores.min() ?? 0) - 10
    let size = vocabulary.charsmap.withUnsafeBytes {
      Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
    }
    guard size > 0, size.isMultiple(of: 4), size + 4 <= vocabulary.charsmap.count,
      scores.allSatisfy(\.isFinite)
    else { throw Failure.invalidVocabulary }
    normalizationTrie = vocabulary.charsmap.withUnsafeBytes { bytes in
      stride(from: 4, to: size + 4, by: 4)
        .map {
          UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        }
    }
    replacements = Array(vocabulary.charsmap.dropFirst(size + 4))
    try Self.validateTrie(normalizationTrie, replacements: replacements)
  }

  private static func validateTrie(_ trie: [UInt32], replacements: [UInt8]) throws {
    guard !trie.isEmpty, trie[0] & ((1 << 31) | 255) == 0,
      replacements.last == 0
    else { throw Failure.invalidVocabulary }
    var validStarts = Set<Int>()
    var start = 0
    for end in replacements.indices where replacements[end] == 0 {
      guard String(bytes: replacements[start..<end], encoding: .utf8) != nil else {
        throw Failure.invalidVocabulary
      }
      validStarts.insert(start)
      start = end + 1
    }
    func offset(_ unit: UInt32) -> Int { Int(unit >> 10) << Int((unit & (1 << 9)) >> 6) }
    guard trie.indices.contains(offset(trie[0])) else { throw Failure.invalidVocabulary }
    for (index, unit) in trie.enumerated() {
      try Task.checkCancellation()
      if unit & (1 << 31) != 0 {
        guard validStarts.contains(Int(unit & ((1 << 31) - 1))) else {
          throw Failure.invalidVocabulary
        }
      } else {
        guard trie.indices.contains(index ^ offset(unit)) else { throw Failure.invalidVocabulary }
        if unit & (1 << 8) == 0 { continue }
        let leaf = index ^ offset(unit)
        guard trie.indices.contains(leaf), trie[leaf] & (1 << 31) != 0 else {
          throw Failure.invalidVocabulary
        }
      }
    }
  }

  func tokenIDs(for text: String) throws -> [Int] {
    try Task.checkCancellation()
    guard text.utf8.prefix(8193).count <= 8192,
      text.unicodeScalars.prefix(2049).count <= 2048
    else { throw Failure.invalidInput }
    var result = [0]
    var remaining = text[...]
    while !remaining.isEmpty && result.count < 511 {
      let next =
        try specials.compactMap { token, id -> (Range<String.Index>, Int)? in
          try Task.checkCancellation()
          return remaining.range(of: token, options: .literal).map { ($0, id) }
        }
        .min { $0.0.lowerBound < $1.0.lowerBound }
      guard let (range, id) = next else {
        result.append(contentsOf: try encodeOrdinary(String(remaining), limit: 511 - result.count))
        break
      }
      result.append(
        contentsOf: try encodeOrdinary(
          String(remaining[..<range.lowerBound]), limit: 511 - result.count))
      result.append(id)
      remaining = remaining[range.upperBound...]
    }
    return Array(result.prefix(511)) + [2]
  }

  private func replacement(for bytes: [UInt8]) -> String? {
    func offset(_ unit: UInt32) -> Int { Int(unit >> 10) << Int((unit & (1 << 9)) >> 6) }
    var position = offset(normalizationTrie[0])
    for byte in bytes {
      if byte == 0 { break }
      position ^= Int(byte)
      guard normalizationTrie.indices.contains(position) else { return nil }
      let unit = normalizationTrie[position]
      guard unit & ((1 << 31) | 255) == UInt32(byte) else { return nil }
      position ^= offset(unit)
      if unit & (1 << 8) != 0 {
        guard normalizationTrie.indices.contains(position) else { return nil }
        let start = Int(normalizationTrie[position] & ((1 << 31) - 1))
        guard replacements.indices.contains(start) else { return nil }
        let end = replacements[start...].firstIndex(of: 0) ?? replacements.endIndex
        return String(decoding: replacements[start..<end], as: UTF8.self)
      }
    }
    return nil
  }

  private func normalized(_ text: String) throws -> String {
    var result = ""
    for character in text {
      try Task.checkCancellation()
      let value = String(character)
      if value.utf8.count < 6, let replacement = replacement(for: Array(value.utf8)) {
        result += replacement
      } else {
        for scalar in character.unicodeScalars {
          try Task.checkCancellation()
          result += replacement(for: Array(String(scalar).utf8)) ?? String(scalar)
        }
      }
    }
    return result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
  }

  private func encodeOrdinary(_ text: String, limit: Int) throws -> [Int] {
    guard !text.isEmpty, limit > 0 else { return [] }
    var text = try normalized(text).replacingOccurrences(of: " ", with: "▁", options: .literal)
    if text.unicodeScalars.first != "▁" { text = "▁" + text }
    var result: [Int] = []
    var word = ""
    for scalar in text.unicodeScalars {
      try Task.checkCancellation()
      if scalar == "▁", !word.isEmpty {
        result.append(contentsOf: try unigram(word))
        if result.count >= limit { return Array(result.prefix(limit)) }
        word = ""
      }
      word.unicodeScalars.append(scalar)
    }
    if !word.isEmpty { result.append(contentsOf: try unigram(word)) }
    return Array(result.prefix(limit))
  }

  private func unigram(_ text: String) throws -> [Int] {
    try Task.checkCancellation()
    let bytes = Array(text.utf8)
    var boundaries = [0]
    for scalar in text.unicodeScalars {
      try Task.checkCancellation()
      boundaries.append((boundaries.last ?? 0) + scalar.utf8.count)
    }
    var best = [Double](repeating: -.infinity, count: bytes.count + 1)
    var previous = [Int](repeating: -1, count: bytes.count + 1)
    var ids = [Int](repeating: 3, count: bytes.count + 1)
    best[0] = 0
    for startIndex in 0..<(boundaries.count - 1) {
      try Task.checkCancellation()
      let start = boundaries[startIndex]
      let next = boundaries[startIndex + 1]
      var hasSingle = false
      for end in boundaries[(startIndex + 1)...] {
        if end - start > maximumPieceBytes { break }
        let piece = Data(bytes[start..<end])
        guard let id = pieces[piece] else { continue }
        if end == next { hasSingle = true }
        let candidate = best[start] + scores[id]
        if previous[end] == -1 || candidate > best[end] {
          best[end] = candidate
          previous[end] = start
          ids[end] = id
        }
      }
      if !hasSingle {
        let candidate = best[start] + unknownScore
        if previous[next] == -1 || candidate > best[next] {
          best[next] = candidate
          previous[next] = start
          ids[next] = 3
        }
      }
    }
    var result: [Int] = []
    var end = bytes.count
    while end > 0 {
      try Task.checkCancellation()
      let id = ids[end]
      if id != 3 || result.last != 3 { result.append(id) }
      end = previous[end]
    }
    return result.reversed()
  }
}
