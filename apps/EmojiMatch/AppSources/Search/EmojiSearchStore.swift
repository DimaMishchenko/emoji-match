import Emojis
import Foundation

struct EmojiSearchResult: Identifiable, Equatable {
  let id: String
  let value: String
  let displayName: String

  var accessibilityLabel: String {
    "\(displayName) \(value)"
  }
}

struct EmojiSearchStore {
  private struct Entry {
    let id: String
    let value: String
    let sortOrder: Int
    let result: EmojiSearchResult
    let aliases: [String]
    let tokens: Set<String>
  }

  private struct RankedResult {
    let result: EmojiSearchResult
    let rank: Rank
  }

  private struct Rank: Comparable {
    let tier: Int
    let tokenMatches: Int
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

      if lhs.sortOrder != rhs.sortOrder {
        return lhs.sortOrder < rhs.sortOrder
      }

      if lhs.value != rhs.value {
        return lhs.value < rhs.value
      }

      return lhs.id < rhs.id
    }
  }

  private static let fallbackLimit = 24
  private let entries: [Entry]

  init() {
    self.entries = Self.loadEntries()
  }

  init(
    searchIndex: SearchIndex,
    displayNamesByID: [String: String] = [:],
    categoryAliasesByID: [String: [String]] = [:],
    keywordExtensions: [String: [String]] = [:],
    supportedEmojiIDs: Set<String>? = nil
  ) {
    self.entries = Self.makeEntries(
      searchIndex: searchIndex,
      displayNamesByID: displayNamesByID,
      categoryAliasesByID: categoryAliasesByID,
      keywordExtensions: keywordExtensions,
      supportedEmojiIDs: supportedEmojiIDs
    )
  }

  func results(for query: String, limit: Int = Self.fallbackLimit) -> [EmojiSearchResult] {
    let normalizedQuery = EmojiSearchNormalization.searchQuery(query)

    guard !normalizedQuery.isEmpty else {
      return []
    }

    let queryTokens = EmojiSearchNormalization.tokens(in: normalizedQuery)
    let ranked =
      entries
      .compactMap { entry -> RankedResult? in
        guard
          let rank = Self.rank(
            entry: entry,
            normalizedQuery: normalizedQuery,
            queryTokens: queryTokens
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

    return ranked.prefix(limit).map(\.result)
  }

  func topResult(for query: String) -> EmojiSearchResult? {
    results(for: query, limit: 1).first
  }
}

private extension EmojiSearchStore {
  private static func loadEntries() -> [Entry] {
    let keywordExtensions = (try? BundleEmojiKeywordExtensionsLoader().load()) ?? [:]
    let filter: Emojis.Filter

    #if canImport(CoreText)
      filter = .apple
    #else
      filter = .none
    #endif

    guard let displayEmojis = try? Emojis.fetch(filter: filter) else {
      return []
    }
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

    guard let searchIndex = try? Emojis.searchIndex(locales: .all) else {
      return []
    }

    return Self.makeEntries(
      searchIndex: searchIndex,
      displayNamesByID: displayNamesByID,
      categoryAliasesByID: categoryAliasesByID,
      keywordExtensions: keywordExtensions,
      supportedEmojiIDs: supportedEmojiIDs
    )
  }

  private static func makeEntries(
    searchIndex: SearchIndex,
    displayNamesByID: [String: String],
    categoryAliasesByID: [String: [String]],
    keywordExtensions: [String: [String]],
    supportedEmojiIDs: Set<String>?
  ) -> [Entry] {
    searchIndex.entries.enumerated()
      .compactMap { index, entry in
        if let supportedEmojiIDs, !supportedEmojiIDs.contains(entry.id.rawValue) {
          return nil
        }

        let localizedAliases = entry.localizations.flatMap { localization -> [String] in
          [localization.name] + localization.searchTokens
        }
        let categoryAliases = categoryAliasesByID[entry.id.rawValue] ?? []
        let extensionAliases = keywordExtensions[entry.id.rawValue] ?? []
        let aliases = Self.uniqueAliases(
          localizedAliases + categoryAliases + extensionAliases + [entry.value]
        )
        let tokens = Set(
          aliases
            .flatMap { EmojiSearchNormalization.tokens(in: $0) }
            .filter { !$0.isEmpty }
        )

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
          tokens: tokens
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
    queryTokens: [String]
  ) -> Rank? {
    let tokenMatches = queryTokens.filter(entry.tokens.contains).count
    let phraseTier = entry.aliases.compactMap { alias -> Int? in
      if alias == normalizedQuery {
        return 0
      } else if alias.hasPrefix(normalizedQuery) {
        return 1
      } else if alias.contains(normalizedQuery) {
        return 2
      } else {
        return nil
      }
    }

    guard !phraseTier.isEmpty || tokenMatches > 0 else {
      return nil
    }

    let tier = phraseTier.min() ?? (tokenMatches == queryTokens.count ? 3 : 4)

    return Rank(
      tier: tier,
      tokenMatches: tokenMatches,
      sortOrder: entry.sortOrder,
      value: entry.value,
      id: entry.id
    )
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
