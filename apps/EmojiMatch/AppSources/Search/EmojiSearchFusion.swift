import Foundation

nonisolated enum EmojiSearchFusion {
  static func rankedIDs(
    exactIDs: [String], lexicalIDs: [String], providers: [EmojiSearchProviderResult]
  ) -> [String] {
    let sources = EmojiSearchProvider.allCases.filter { $0 != .lexical }
    var lists = [ranks(lexicalIDs)]
    var webHosts: [String: Set<String>] = [:]
    for source in sources {
      let matches = providers.filter { $0.provider == source }.flatMap(\.matches)
      lists.append(ranks(matches.map(\.id)))
      if source == .duckDuckGo {
        for match in matches {
          webHosts[match.id, default: []]
            .formUnion(
              match.sourceURLs.compactMap(EmojiWebSourceIdentity.host))
        }
      }
    }
    let candidates = Set(lists.flatMap(\.keys))
    let ranked = candidates.sorted { lhs, rhs in
      let left = lists.compactMap { $0[lhs] }
      let right = lists.compactMap { $0[rhs] }
      let leftCorroborated = left.count > 1 || (webHosts[lhs]?.count ?? 0) > 1
      let rightCorroborated = right.count > 1 || (webHosts[rhs]?.count ?? 0) > 1
      if leftCorroborated != rightCorroborated { return leftCorroborated }
      let leftScore = left.reduce(0.0) { $0 + 1 / Double(60 + $1) }
      let rightScore = right.reduce(0.0) { $0 + 1 / Double(60 + $1) }
      if leftScore != rightScore { return leftScore > rightScore }
      for list in lists {
        let leftRank = list[lhs] ?? .max
        let rightRank = list[rhs] ?? .max
        if leftRank != rightRank { return leftRank < rightRank }
      }
      return lhs < rhs
    }
    var seen = Set<String>()
    return (exactIDs + ranked).filter { seen.insert($0).inserted }
  }

  private static func ranks(_ ids: [String]) -> [String: Int] {
    var result: [String: Int] = [:]
    for id in ids where result[id] == nil { result[id] = result.count + 1 }
    return result
  }
}
