import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiSearchStoreTests {
  @Test func defaultResultsIncludeEveryMatchBeyondTwentyFour() {
    let store = makeStore(
      entries: (0..<61)
        .map { index in
          entry(
            id: "result-\(index)", value: "😀",
            localizations: [localization("en", name: "face \(index)", tokens: ["face"])])
        })
    let results = store.results(for: "face")
    #expect(results.count == 61)
    #expect(Set(results.map(\.id)).count == 61)
    #expect(store.results(for: "face", limit: 24) == Array(results.prefix(24)))
    #expect(store.results(for: "face", limit: -1).isEmpty)
  }

  @Test func failedIndexLoadCanRetryWithoutBecomingAnEmptySuccess() {
    let retry = RetryState()
    let index = SearchIndex(
      availableLocaleIdentifiers: ["en"],
      entries: [
        entry(
          id: "1F600", value: "😀", localizations: [localization("en", name: "smile", tokens: [])])
      ])
    let store = EmojiSearchStore(loadSearchIndex: {
      if retry.shouldFail { throw CocoaError(.fileReadCorruptFile) }
      return index
    })
    #expect(store.loadError != nil)
    #expect(store.results(for: "smile").isEmpty)
    retry.shouldFail = false
    store.reload()
    #expect(store.loadError == nil)
    #expect(store.results(for: "smile").map(\.id) == ["1F600"])
  }

  @Test func normalizedSearchMatchesAcrossCaseDiacriticsAndWidth() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F600",
          value: "😀",
          localizations: [
            localization("en", name: "Café", tokens: ["coffee", "drink"])
          ]
        )
      ]
    )

    let results = store.results(for: "ＣＡＦＥ")

    #expect(results.first?.id == "1F600")
    #expect(results.first?.displayName == "Café")
  }

  @Test func multilingualTokensAreIncludedInSearch() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F600",
          value: "😀",
          localizations: [
            localization("en", name: "grinning face", tokens: ["grin", "smile"]),
            localization("fr", name: "visage souriant", tokens: ["visage", "souriant"])
          ]
        )
      ]
    )

    let results = store.results(for: "souriant")

    #expect(results.map(\.id) == ["1F600"])
  }

  @Test func bundledKeywordExtensionsParticipateInSearch() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F4A9",
          value: "💩",
          localizations: [
            localization("en", name: "pile of poo", tokens: ["poo"])
          ]
        )
      ],
      keywordExtensions: [
        "1F4A9": ["poop"]
      ]
    )

    let results = store.results(for: "poop")

    #expect(results.first?.id == "1F4A9")
  }

  @Test func productionStoreLoadsBundledKeywordExtensions() {
    let results = EmojiSearchStore().results(for: "anime")

    #expect(results.contains { $0.id == "2728" })
  }

  @Test func exactMatchesRankAheadOfPrefixAndContainsMatches() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F34E",
          value: "🍎",
          localizations: [
            localization("en", name: "apple", tokens: ["apple"])
          ]
        ),
        entry(
          id: "1F34F",
          value: "🍏",
          localizations: [
            localization("en", name: "apple juice", tokens: ["juice"])
          ]
        ),
        entry(
          id: "1F951",
          value: "🥑",
          localizations: [
            localization("en", name: "green apple avocado", tokens: ["green", "fruit"])
          ]
        )
      ]
    )

    let results = store.results(for: "apple")

    #expect(results.map(\.id) == ["1F34E", "1F34F", "1F951"])
  }

  @Test func partialTokenMatchesPrefixAndContainsAliases() {
    let store = makeStore(
      entries: [
        entry(
          id: "2728",
          value: "✨",
          localizations: [
            localization("en", name: "sparkles", tokens: ["sparkle"])
          ]
        ),
        entry(
          id: "1F31F",
          value: "🌟",
          localizations: [
            localization("en", name: "glowing sparkle", tokens: ["star"])
          ]
        )
      ]
    )

    let results = store.results(for: "spa")

    #expect(results.map(\.id) == ["2728", "1F31F"])
  }

  @Test func categoryAliasesParticipateInSearch() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F98A",
          value: "🦊",
          localizations: [
            localization("en", name: "fox", tokens: ["fox"])
          ]
        )
      ],
      categoryAliasesByID: [
        "1F98A": ["Animals & Nature", "animal-mammal"]
      ]
    )

    #expect(store.results(for: "animals").map(\.id) == ["1F98A"])
    #expect(store.results(for: "mammal").map(\.id) == ["1F98A"])
  }

  @Test func emptyQueryHasNoImplicitSelection() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F600",
          value: "😀",
          localizations: [
            localization("en", name: "grinning face", tokens: ["grin"])
          ]
        )
      ]
    )

    #expect(store.results(for: "").isEmpty)
    #expect(store.topResult(for: "   ") == nil)
  }

  @Test func framingPrefixDoesNotOutrankMeaningfulQuery() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F928",
          value: "🤨",
          localizations: [
            localization("en", name: "face with raised eyebrow", tokens: ["emoji"])
          ]
        ),
        entry(
          id: "1F33C",
          value: "🌼",
          localizations: [
            localization("en", name: "blossom", tokens: ["flower"])
          ]
        )
      ]
    )

    #expect(store.results(for: "emoji for a flower").map(\.id) == ["1F33C"])
  }

  @Test func unsupportedEmojiAreFilteredOutConsistently() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F600",
          value: "😀",
          localizations: [
            localization("en", name: "grinning face", tokens: ["grin"])
          ]
        ),
        entry(
          id: "1F4A9",
          value: "💩",
          localizations: [
            localization("en", name: "pile of poo", tokens: ["poo"])
          ]
        )
      ],
      supportedEmojiIDs: ["1F600"]
    )

    let grinResults = store.results(for: "grin")
    let pooResults = store.results(for: "poo")

    #expect(grinResults.map(\.id) == ["1F600"])
    #expect(pooResults.isEmpty)
  }

  @Test func emptySupportedSetFiltersEveryEmoji() {
    let store = makeStore(
      entries: [
        entry(
          id: "1F600",
          value: "😀",
          localizations: [
            localization("en", name: "grinning face", tokens: ["grin"])
          ]
        )
      ],
      supportedEmojiIDs: []
    )

    #expect(store.results(for: "grin").isEmpty)
  }
}

private func makeStore(
  entries: [SearchIndex.Entry],
  categoryAliasesByID: [String: [String]] = [:],
  keywordExtensions: [String: [String]] = [:],
  supportedEmojiIDs: Set<String>? = nil
) -> EmojiSearchStore {
  EmojiSearchStore(
    searchIndex: SearchIndex(
      availableLocaleIdentifiers: ["en", "fr"],
      entries: entries
    ),
    displayNamesByID: Dictionary(
      uniqueKeysWithValues: entries.map { entry in
        let displayName = entry.localizations.first?.name ?? entry.value
        return (entry.id.rawValue, displayName)
      }),
    categoryAliasesByID: categoryAliasesByID,
    keywordExtensions: keywordExtensions,
    supportedEmojiIDs: supportedEmojiIDs
  )
}

private func entry(
  id: String,
  value: String,
  localizations: [Emoji.Localization]
) -> SearchIndex.Entry {
  SearchIndex.Entry(
    id: .init(rawValue: id),
    value: value,
    skinToneSupport: .none,
    skinToneVariants: [],
    localizations: localizations
  )
}

private func localization(
  _ localeIdentifier: String,
  name: String,
  tokens: [String]
) -> Emoji.Localization {
  Emoji.Localization(
    localeIdentifier: localeIdentifier,
    name: name,
    searchTokens: tokens
  )
}

@MainActor
private final class RetryState {
  var shouldFail = true
}
