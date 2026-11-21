import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiSearchStoreTests {
  @Test func weakExactTokensDoNotSuppressAuthoritativeCorrections() {
    let entries = [
      entry(
        id: "meat", value: "🍖", localizations: [localization("en", name: "meat bone", tokens: [])]),
      entry(
        id: "category", value: "🍽️", localizations: [localization("en", name: "plate", tokens: [])]),
      entry(
        id: "partial", value: "🦴", localizations: [localization("en", name: "bone", tokens: [])])
    ]
    for extensions in [[String: [String]](), ["meat": ["meal"]]] {
      let store = makeStore(
        entries: entries, categoryAliasesByID: ["category": ["meal bone", "meal bone unknown"]],
        keywordExtensions: extensions)
      #expect(store.results(for: "meal bone").map(\.id) == ["meat", "category", "partial"])
      #expect(store.results(for: "meal bone unknown").first?.id == "category")
    }
  }

  @Test func completeMultiwordTypoBeatsUnrelatedPartialMatches() {
    let store = makeStore(entries: [
      entry(
        id: "red-fruit", value: "🍎",
        localizations: [localization("en", name: "red apple", tokens: [])]),
      entry(
        id: "heart", value: "❤️", localizations: [localization("en", name: "red heart", tokens: [])])
    ])
    #expect(store.results(for: "red haert").map(\.id) == ["heart", "red-fruit"])
  }

  @Test func multiwordCoverageKeepsFieldProvenanceAndWeakExtensionsStayBelowNames() {
    let store = makeStore(
      entries: [
        entry(
          id: "broad", value: "🔥", localizations: [localization("en", name: "fire", tokens: [])]),
        entry(
          id: "name", value: "❤️", localizations: [localization("en", name: "heart red", tokens: [])]
        ),
        entry(
          id: "prefix", value: "💗",
          localizations: [localization("en", name: "red heart growing", tokens: [])])
      ], keywordExtensions: ["broad": ["red", "heart", "red heart"]])
    #expect(store.results(for: "red heart").map(\.id) == ["prefix", "name", "broad"])
  }

  @Test func namesBeatKeywordsCategoriesAndBroadExtensions() {
    let entries = [
      entry(
        id: "keyword", value: "😃",
        localizations: [localization("en", name: "grinning", tokens: ["coffee"])]),
      entry(
        id: "name", value: "☕", localizations: [localization("en", name: "coffee", tokens: [])]),
      entry(
        id: "category", value: "🍵", localizations: [localization("en", name: "tea", tokens: [])]),
      entry(
        id: "extension", value: "🔥", localizations: [localization("en", name: "fire", tokens: [])])
    ]
    let store = makeStore(
      entries: entries, categoryAliasesByID: ["category": ["coffee"]],
      keywordExtensions: ["extension": ["coffee"]])
    #expect(store.results(for: "coffee").map(\.id) == ["name", "keyword", "category", "extension"])
  }

  @Test func preferredLanguageWinsTiesWithoutHidingOtherLocales() {
    let entries = [
      entry(
        id: "english", value: "😀", localizations: [localization("en", name: "chat", tokens: [])]),
      entry(id: "french", value: "🐈", localizations: [localization("fr", name: "chat", tokens: [])])
    ]
    let index = SearchIndex(availableLocaleIdentifiers: ["en", "fr"], entries: entries)
    #expect(
      EmojiSearchStore(searchIndex: index, preferredLocaleIdentifier: "fr_FR").results(for: "chat")
        .map(\.id) == ["french", "english"])
    #expect(
      EmojiSearchStore(searchIndex: index, preferredLocaleIdentifier: "en_US").results(for: "chat")
        .map(\.id) == ["english", "french"])
  }

  @Test func derivedShortcodesAndBoundedTyposFindCanonicalNames() {
    let store = makeStore(entries: [
      entry(
        id: "heart", value: "💔",
        localizations: [localization("en", name: "broken heart", tokens: [])]),
      entry(
        id: "coffee", value: "☕", localizations: [localization("en", name: "coffee", tokens: [])])
    ])
    #expect(store.results(for: ":broken_heart:").first?.id == "heart")
    for query in ["cofee", "cofffee", "coftee", "cofefe"] {
      #expect(store.results(for: query).first?.id == "coffee")
    }
    #expect(store.results(for: "cfee").isEmpty)
    #expect(store.results(for: "xyz").isEmpty)
    #expect(store.results(for: String(repeating: "q", count: 100)).isEmpty)
  }

  @Test func fuzzyMatchesFollowAllLexicalMatchesAndIgnoreBroadExtensions() {
    let store = makeStore(
      entries: [
        entry(
          id: "typo", value: "☕", localizations: [localization("en", name: "coffee", tokens: [])]),
        entry(
          id: "literal", value: "😀", localizations: [localization("en", name: "cofee", tokens: [])]),
        entry(
          id: "broad", value: "🔥", localizations: [localization("en", name: "fire", tokens: [])])
      ], keywordExtensions: ["broad": ["coffee"]])
    #expect(store.results(for: "cofee").map(\.id) == ["literal", "typo"])
  }

  @Test func productionCoffeeAliasesAndCuratedShortcodes() {
    let store = EmojiSearchStore()
    #expect(store.results(for: ":thumbsup:").first?.id == "1F44D")
    #expect(store.results(for: "espresso").contains { $0.id == "2615" })
    for query in ["burning", "danger", "trending"] {
      #expect(!store.results(for: query).contains { $0.id == "2615" })
    }
  }

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

  @Test func cachedNormalizedQueryRetainsCompleteResultsAndReloadInvalidatesThem() {
    let state = RetryState()
    state.shouldFail = false
    let index = SearchIndex(
      availableLocaleIdentifiers: ["en"],
      entries: (0..<30)
        .map { number in
          entry(
            id: "face-\(number)", value: "😀",
            localizations: [localization("en", name: "face \(number)", tokens: [])])
        })
    let store = EmojiSearchStore(loadSearchIndex: {
      if state.shouldFail { throw CocoaError(.fileReadCorruptFile) }
      return state.useReplacement
        ? SearchIndex(
          availableLocaleIdentifiers: ["en"],
          entries: [
            entry(
              id: "replacement", value: "😃",
              localizations: [localization("en", name: "face replacement", tokens: [])])
          ]) : index
    })
    #expect(store.results(for: "ＦＡＣＥ", limit: 1).count == 1)
    let all = store.results(for: "face")
    #expect(all.count == 30)
    #expect(store.results(for: " face ", limit: 3) == Array(all.prefix(3)))
    #expect(store.results(for: "face", limit: -1).isEmpty)
    state.shouldFail = true
    store.reload()
    #expect(store.results(for: "face").isEmpty)
    state.shouldFail = false
    store.reload()
    #expect(store.results(for: "face") == all)
    state.useReplacement = true
    store.reload()
    #expect(store.results(for: "face").map(\.id) == ["replacement"])
  }

  @Test func phraseMatchingPreservesCanonicalEquivalenceAndEmojiSequences() {
    let store = makeStore(entries: [
      entry(
        id: "accent", value: "👩‍💻", localizations: [localization("en", name: "café", tokens: [])]),
      entry(
        id: "heart", value: "❤️", localizations: [localization("en", name: "heart", tokens: [])]),
      entry(id: "hangul", value: "🇰🇷", localizations: [localization("ko", name: "가", tokens: [])])
    ])
    #expect(store.results(for: "\u{1100}\u{1161}").map(\.id) == ["hangul"])
    #expect(store.results(for: "cafe\u{301}").map(\.id) == ["accent"])
    #expect(store.results(for: "👩‍💻").map(\.id) == ["accent"])
    #expect(store.results(for: "❤️").map(\.id) == ["heart"])
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
    #expect(store.results(for: "   ", limit: 1).first == nil)
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
  var useReplacement = false
}
