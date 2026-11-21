import Foundation

nonisolated enum EmojiWebSearchReranking {
  static func usesSemanticOrdering(for query: String) -> Bool {
    guard EmojiSemanticLanguageRouter.encoder(for: query) == .miniLM
    else { return false }
    let words = Set(
      query.lowercased().replacingOccurrences(of: "’", with: "'")
        .split { !$0.isLetter && $0 != "'" }.map(String.init))
    let constraints: Set<String> = [
      "no", "not", "never", "without", "off", "disabled", "unavailable", "delayed", "late",
      "cancelled", "canceled", "closed", "stopped", "sold", "out", "can't", "cannot",
      "don't", "doesn't", "isn't", "won't"
    ]
    guard words.isDisjoint(with: constraints) else { return false }
    let personal: Set<String> = ["i", "i'm", "we", "we're", "me", "my", "our"]
    let requests: Set<String> = ["need", "want", "wish", "prefer"]
    return words.isDisjoint(with: personal) || words.isDisjoint(with: requests)
  }

  static func matches(
    web: [EmojiSearchMatch], semanticIDs: [String], limit: Int = 6
  ) -> [EmojiSearchMatch] {
    guard limit > 0 else { return [] }
    var seen: Set<String> = []
    let candidates = web.filter { seen.insert($0.id).inserted }
    guard Set(semanticIDs) == seen, semanticIDs.count == seen.count else {
      return Array(candidates.prefix(limit))
    }
    let semantic = Dictionary(
      uniqueKeysWithValues: semanticIDs.enumerated().map { ($1, 1 / Double(61 + $0)) })
    let scores = candidates.enumerated()
      .map { index, match in
        1 / Double(61 + index) + (semantic[match.id] ?? 0)
      }
    return candidates.indices
      .sorted {
        scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
      }
      .prefix(limit)
      .map { index in
        let match = candidates[index]
        return EmojiSearchMatch(
          id: match.id, value: match.value, score: scores[index], sourceURLs: match.sourceURLs)
      }
  }
}
