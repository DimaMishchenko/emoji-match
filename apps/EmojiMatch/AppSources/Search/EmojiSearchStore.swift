import Emojis
import Foundation
import Observation

struct EmojiSearchResult: Identifiable, Equatable {
  let id: String
  let value: String
  let displayName: String

  nonisolated var selection: EmojiSelection {
    EmojiSelection(id: id, value: value)
  }

  nonisolated var accessibilityLabel: String {
    "\(displayName) \(value)"
  }
}

@Observable
final class EmojiSearchStore {
  private struct Entry {
    let id: String
    let value: String
    let sortOrder: Int
    let result: EmojiSearchResult
    let aliases: [Alias]
    let tokenPriorities: [String: Int]
    let fuzzyTokenPriorities: [String: Int]
  }

  private enum Field: Int {
    case name = 0
    case derivedShortcode = 1
    case keyword = 3
    case curatedAlias = 6
    case category = 7
    case legacyExtension = 8
    case value = -1
  }

  private struct Alias {
    let text: String
    let field: Field
    let localePriority: Int

    var priority: Int { field.rawValue + localePriority }
  }

  private struct RankedResult {
    let result: EmojiSearchResult
    let rank: Rank
  }

  private struct Rank: Comparable {
    let tier: Int
    let tokenMatches: Int
    let priority: Int
    let sortOrder: Int
    let value: String
    let id: String

    static func < (lhs: Rank, rhs: Rank) -> Bool {
      if lhs.tier != rhs.tier {
        return lhs.tier < rhs.tier
      }

      if lhs.tokenMatches != rhs.tokenMatches {
        return lhs.tokenMatches > rhs.tokenMatches
      }

      if lhs.priority != rhs.priority {
        return lhs.priority < rhs.priority
      }

      if lhs.sortOrder != rhs.sortOrder {
        return lhs.sortOrder < rhs.sortOrder
      }

      if lhs.value != rhs.value {
        return lhs.value < rhs.value
      }

      return lhs.id < rhs.id
    }
  }

  private struct FuzzyCandidate {
    let bytes: [UInt8]
    let postings: [Int: Int]
  }

  private var entries: [Entry] = []
  private var resultsByID: [String: EmojiSearchResult] = [:]
  private var fuzzyCandidatesByLength: [Int: [FuzzyCandidate]] = [:]
  @ObservationIgnored private var cachedQuery: String?
  @ObservationIgnored private var cachedResults: [EmojiSearchResult] = []
  @ObservationIgnored private var cachedStrongResults: [EmojiSearchResult] = []
  private(set) var loadError: String?
  private let loader: @MainActor () throws -> [Entry]

  init(
    searchIndex: SearchIndex,
    displayNamesByID: [String: String] = [:],
    categoryAliasesByID: [String: [String]] = [:],
    keywordExtensions: [String: [String]] = [:],
    curatedAliases: [String: [String]] = [:],
    supportedEmojiIDs: Set<String>? = nil,
    preferredLocaleIdentifier: String = Locale.current.identifier
  ) {
    self.loader = {
      Self.makeEntries(
        searchIndex: searchIndex, displayNamesByID: displayNamesByID,
        categoryAliasesByID: categoryAliasesByID, keywordExtensions: keywordExtensions,
        curatedAliases: curatedAliases,
        supportedEmojiIDs: supportedEmojiIDs,
        preferredLocaleIdentifier: preferredLocaleIdentifier
      )
    }
    reload()
  }

  init(loadSearchIndex: (@MainActor () throws -> SearchIndex)? = nil) {
    if let loadSearchIndex {
      loader = {
        Self.makeEntries(
          searchIndex: try loadSearchIndex(), displayNamesByID: [:],
          categoryAliasesByID: [:], keywordExtensions: [:], supportedEmojiIDs: nil)
      }
    } else {
      loader = { try Self.loadEntries() }
    }
    reload()
  }

  func reload() {
    cachedQuery = nil
    cachedResults = []
    cachedStrongResults = []
    do {
      entries = try loader()
      loadError = nil
    } catch {
      entries = []
      loadError = error.localizedDescription
    }
    resultsByID = Dictionary(
      entries.map { ($0.id, $0.result) }, uniquingKeysWith: { first, _ in first })
    var postingsByToken: [String: [Int: Int]] = [:]
    for (index, entry) in entries.enumerated() {
      for (token, priority) in entry.fuzzyTokenPriorities {
        postingsByToken[token, default: [:]][index] = priority
      }
    }
    fuzzyCandidatesByLength = [:]
    for (token, postings) in postingsByToken {
      let bytes = Array(token.utf8)
      fuzzyCandidatesByLength[bytes.count, default: []]
        .append(
          FuzzyCandidate(bytes: bytes, postings: postings))
    }
  }

  func results(for query: String, limit: Int = .max) -> [EmojiSearchResult] {
    let normalizedQuery = EmojiSearchNormalization.searchQuery(query)

    guard !normalizedQuery.isEmpty else {
      return []
    }

    let currentEntries = entries
    if cachedQuery == normalizedQuery {
      return Array(cachedResults.prefix(max(0, limit)))
    }
    let queryTokens = EmojiSearchNormalization.tokens(in: normalizedQuery)
    let correctedPriorities = correctionPriorities(for: queryTokens)
    let ranked =
      currentEntries
      .enumerated()
      .compactMap { index, entry -> RankedResult? in
        guard
          let rank = Self.rank(
            entry: entry,
            normalizedQuery: normalizedQuery,
            queryTokens: queryTokens,
            correctedPriorities: correctedPriorities,
            entryIndex: index
          )
        else {
          return nil
        }

        return RankedResult(
          result: entry.result,
          rank: rank
        )
      }
      .sorted { lhs, rhs in
        lhs.rank < rhs.rank
      }

    cachedResults = ranked.map(\.result)
    cachedStrongResults =
      ranked.filter {
        [0, 1, 2, 4].contains($0.rank.tier) && $0.rank.priority < Field.category.rawValue
      }
      .map(\.result)
    cachedQuery = normalizedQuery
    return Array(cachedResults.prefix(max(0, limit)))
  }

  func result(id: String) -> EmojiSearchResult? {
    resultsByID[id]
  }

  func strongResults(for query: String) -> [EmojiSearchResult] {
    guard !EmojiSearchNormalization.searchQuery(query).isEmpty else { return [] }
    _ = results(for: query)
    return cachedStrongResults
  }

  func exactResults(for query: String) -> [EmojiSearchResult] {
    let normalized = EmojiSearchNormalization.searchQuery(query)
    guard !normalized.isEmpty else { return [] }
    let exactIDs = Set(
      entries.filter { entry in
        entry.aliases.contains {
          $0.text == normalized && [.name, .derivedShortcode, .value].contains($0.field)
        }
      }
      .map(\.id))
    return results(for: query).filter { exactIDs.contains($0.id) }
  }

}

private extension EmojiSearchStore {
  private func correctionPriorities(for tokens: [String]) -> [[Int: Int]] {
    guard !tokens.isEmpty, tokens.count <= 4 else { return [] }
    return tokens.map { token in
      guard Self.allowsTypo(token) else { return [:] }
      let bytes = Array(token.utf8)
      var priorities: [Int: Int] = [:]
      for length in (bytes.count - 1)...(bytes.count + 1) {
        for candidate in fuzzyCandidatesByLength[length] ?? []
        where Self.oneEditApart(bytes, candidate.bytes) {
          for (index, priority) in candidate.postings {
            priorities[index] = min(priorities[index] ?? Int.max, priority)
          }
        }
      }
      return priorities
    }
  }

  private static func loadEntries() throws -> [Entry] {
    let keywordExtensions = try BundleEmojiKeywordExtensionsLoader().load()
    let curatedAliases = try BundleEmojiKeywordExtensionsLoader().loadCuratedAliases()
    let displayEmojis = try Emojis.fetch(filter: .apple)
    let displayNamesByID = Dictionary(
      uniqueKeysWithValues: displayEmojis.map { emoji in
        (emoji.id.rawValue, emoji.localization.name)
      })
    let categoryAliasesByID = Dictionary(
      uniqueKeysWithValues: displayEmojis.map { emoji in
        (
          emoji.id.rawValue,
          [emoji.group.rawValue, emoji.subgroup.rawValue]
        )
      })
    let supportedEmojiIDs = Set(displayEmojis.map(\.id.rawValue))

    let searchIndex = try Emojis.searchIndex(locales: .all)

    return Self.makeEntries(
      searchIndex: searchIndex,
      displayNamesByID: displayNamesByID,
      categoryAliasesByID: categoryAliasesByID,
      keywordExtensions: keywordExtensions,
      curatedAliases: curatedAliases,
      supportedEmojiIDs: supportedEmojiIDs
    )
  }

  private static func makeEntries(
    searchIndex: SearchIndex,
    displayNamesByID: [String: String],
    categoryAliasesByID: [String: [String]],
    keywordExtensions: [String: [String]],
    curatedAliases: [String: [String]] = [:],
    supportedEmojiIDs: Set<String>?,
    preferredLocaleIdentifier: String = Locale.current.identifier
  ) -> [Entry] {
    searchIndex.entries.enumerated()
      .compactMap { index, entry in
        if let supportedEmojiIDs, !supportedEmojiIDs.contains(entry.id.rawValue) {
          return nil
        }

        let language =
          preferredLocaleIdentifier.replacingOccurrences(of: "_", with: "-")
          .split(separator: "-").first.map(String.init)?
          .lowercased() ?? "en"
        var aliasesByText: [String: Alias] = [:]
        var fuzzyTokenPriorities: [String: Int] = [:]
        func add(_ values: [String], field: Field, localePriority: Int = 0, fuzzy: Bool = false) {
          for text in Self.uniqueAliases(values) {
            let alias = Alias(text: text, field: field, localePriority: localePriority)
            if alias.priority < (aliasesByText[text]?.priority ?? Int.max) {
              aliasesByText[text] = alias
            }
            if fuzzy {
              for token in EmojiSearchNormalization.tokens(in: text) where Self.allowsTypo(token) {
                fuzzyTokenPriorities[token] = min(
                  fuzzyTokenPriorities[token] ?? Int.max, alias.priority)
              }
            }
          }
        }
        for localization in entry.localizations {
          let localeLanguage = localization.localeIdentifier.split(separator: "-").first
            .map(String.init)?
            .lowercased()
          let localePriority = localeLanguage == language ? 0 : (localeLanguage == "en" ? 1 : 2)
          add(
            [localization.name], field: .name, localePriority: localePriority,
            fuzzy: localePriority < 2)
          add(
            localization.searchTokens, field: .keyword, localePriority: localePriority,
            fuzzy: localePriority < 2)
          if localization.localeIdentifier == "en" {
            let words = EmojiSearchNormalization.tokens(in: localization.name)
            add([words.joined(separator: "_")], field: .derivedShortcode)
          }
        }
        add(curatedAliases[entry.id.rawValue] ?? [], field: .curatedAlias)
        add(categoryAliasesByID[entry.id.rawValue] ?? [], field: .category)
        add(keywordExtensions[entry.id.rawValue] ?? [], field: .legacyExtension)
        add([entry.value], field: .value)
        let aliases = aliasesByText.values
          .sorted { ($0.priority, $0.text) < ($1.priority, $1.text) }
        var tokenPriorities: [String: Int] = [:]
        for alias in aliases {
          for token in EmojiSearchNormalization.tokens(in: alias.text) {
            tokenPriorities[token] = min(tokenPriorities[token] ?? Int.max, alias.priority)
          }
        }

        let displayName =
          displayNamesByID[entry.id.rawValue]
          ?? entry.localizations.first?.name
          ?? entry.value

        return Entry(
          id: entry.id.rawValue,
          value: entry.value,
          sortOrder: index,
          result: EmojiSearchResult(
            id: entry.id.rawValue,
            value: entry.value,
            displayName: displayName
          ),
          aliases: aliases,
          tokenPriorities: tokenPriorities,
          fuzzyTokenPriorities: fuzzyTokenPriorities
        )
      }
  }

  static func uniqueAliases(_ aliases: [String]) -> [String] {
    var seen = Set<String>()
    var unique: [String] = []

    for alias in aliases {
      let normalized = EmojiSearchNormalization.normalize(alias)
      guard !normalized.isEmpty, seen.insert(normalized).inserted else {
        continue
      }
      unique.append(normalized)
    }

    return unique
  }

  private static func rank(
    entry: Entry,
    normalizedQuery: String,
    queryTokens: [String],
    correctedPriorities: [[Int: Int]],
    entryIndex: Int
  ) -> Rank? {
    let exactPriorities = queryTokens.compactMap { entry.tokenPriorities[$0] }
    let tokenMatches = exactPriorities.count
    var best: (tier: Int, priority: Int)?
    func consider(tier: Int, priority: Int) {
      if let current = best, (current.tier, current.priority) <= (tier, priority) { return }
      best = (tier, priority)
    }
    for alias in entry.aliases {
      let quality: Int
      if alias.text == normalizedQuery {
        quality = 0
      } else if alias.text.hasPrefix(normalizedQuery) {
        quality = 1
      } else if alias.text.contains(normalizedQuery) {
        quality = 3
      } else {
        continue
      }
      consider(
        tier: quality + (alias.priority >= Field.category.rawValue ? 5 : 0),
        priority: alias.priority)
    }
    if tokenMatches == queryTokens.count, let priority = exactPriorities.max() {
      consider(tier: priority >= Field.category.rawValue ? 7 : 2, priority: priority)
    } else if let priority = exactPriorities.min() {
      consider(tier: 9, priority: priority)
    }
    if !correctedPriorities.isEmpty {
      let completePriorities = zip(queryTokens, correctedPriorities)
        .compactMap { token, corrected -> Int? in
          let priority = min(
            entry.tokenPriorities[token] ?? Int.max, corrected[entryIndex] ?? Int.max)
          return priority == Int.max ? nil : priority
        }
      if completePriorities.count == queryTokens.count, let priority = completePriorities.max() {
        consider(tier: priority >= Field.category.rawValue ? 8 : 4, priority: priority)
      }
    }
    guard let best else { return nil }
    return Rank(
      tier: best.tier,
      tokenMatches: tokenMatches,
      priority: best.priority,
      sortOrder: entry.sortOrder,
      value: entry.value,
      id: entry.id
    )
  }

  static func allowsTypo(_ token: String) -> Bool {
    (4...32).contains(token.utf8.count) && token.utf8.allSatisfy { (97...122).contains($0) }
  }

  static func oneEditApart(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard abs(lhs.count - rhs.count) <= 1 else { return false }
    var index = 0
    while index < min(lhs.count, rhs.count), lhs[index] == rhs[index] { index += 1 }
    if index == min(lhs.count, rhs.count) { return true }
    if lhs.count == rhs.count {
      if lhs.dropFirst(index + 1).elementsEqual(rhs.dropFirst(index + 1)) { return true }
      return index + 1 < lhs.count && lhs[index] == rhs[index + 1]
        && lhs[index + 1] == rhs[index]
        && lhs.dropFirst(index + 2).elementsEqual(rhs.dropFirst(index + 2))
    }
    if lhs.count > rhs.count {
      return lhs.dropFirst(index + 1).elementsEqual(rhs.dropFirst(index))
    }
    return lhs.dropFirst(index).elementsEqual(rhs.dropFirst(index + 1))
  }

}

private enum EmojiSearchNormalization {
  private static let framingPrefixes = [
    "emoji for an ",
    "emoji for a ",
    "emoji for the ",
    "emoji for "
  ]
  private static let separatorScalars = CharacterSet.whitespacesAndNewlines
    .union(.punctuationCharacters)
    .union(.controlCharacters)

  static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [
        .caseInsensitive,
        .diacriticInsensitive,
        .widthInsensitive
      ],
      locale: Locale(identifier: "en_US_POSIX")
    )

    let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.replacingOccurrences(
      of: #"\s+"#,
      with: " ",
      options: .regularExpression
    )
  }

  static func searchQuery(_ value: String) -> String {
    let normalized = normalize(value)
    if normalized.hasPrefix(":"), normalized.hasSuffix(":"), normalized.count > 2 {
      return String(normalized.dropFirst().dropLast())
    }

    for prefix in framingPrefixes where normalized.hasPrefix(prefix) {
      return String(normalized.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return normalized
  }

  static func tokens(in value: String) -> [String] {
    let normalized = normalize(value)
    guard !normalized.isEmpty else {
      return []
    }

    var tokens: [String] = []
    var current = String()

    for scalar in normalized.unicodeScalars {
      if separatorScalars.contains(scalar) {
        if !current.isEmpty {
          tokens.append(current)
          current.removeAll(keepingCapacity: true)
        }
      } else {
        current.unicodeScalars.append(scalar)
      }
    }

    if !current.isEmpty {
      tokens.append(current)
    }

    return tokens
  }
}

private final class BundleEmojiKeywordExtensionsLoader {
  private let bundle: Bundle

  init(bundle: Bundle = Bundle(for: EmojiSearchBundleToken.self)) {
    self.bundle = bundle
  }

  private struct CuratedAliases: Decodable {
    let provenance: String
    let aliases: [String: [String]]
  }

  func loadCuratedAliases() throws -> [String: [String]] {
    guard let url = bundle.url(forResource: "emoji-search-aliases", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    let decoded = try JSONDecoder().decode(CuratedAliases.self, from: Data(contentsOf: url))
    guard !decoded.provenance.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    return decoded.aliases
  }

  func load() throws -> [String: [String]] {
    guard
      let url = bundle.url(
        forResource: "emoji-keyword-extensions",
        withExtension: "json"
      )
    else {
      throw CocoaError(.fileNoSuchFile)
    }

    let data = try Data(contentsOf: url)
    guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
      throw CocoaError(.fileReadCorruptFile)
    }

    return decoded
  }
}

private final class EmojiSearchBundleToken {}
