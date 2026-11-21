import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiWebSearchProviderTests {
  @Test func requestPreservesQualifiersAndDecodesOnlyObservedText() async throws {
    let provider = DuckDuckGoEmojiSearchProvider { request in
      #expect(request.httpMethod == "GET")
      #expect(request.url?.scheme == "https")
      #expect(request.url?.host == "html.duckduckgo.com")
      #expect(
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.path
          == "/html/")
      #expect(request.timeoutInterval == 10)
      #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == nil)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
      let url = try #require(request.url)
      let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
      #expect(
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) == [
          "q": "emoji for woman scientist & flag + café copy and paste", "kl": "us-en"
        ])
      #expect(url.absoluteString.contains("%26"))
      #expect(url.absoluteString.contains("%2B"))
      #expect(url.absoluteString.contains("caf%C3%A9"))
      return try response(
        request,
        body: page(
          result(
            title: "<b>Scientist</b> 👩‍🔬 &amp; &#x1F1FA;&#x1F1E6;",
            snippet: "Observed &#129514; &copy; &nbsp; café <img alt='🦄' src='custom.png'>"
          )))
    }
    let documents = try await provider.documents(
      for: " \nwoman scientist & flag + café \t", localeIdentifier: "en_US")
    let document = try #require(documents.first)
    #expect(documents.count == 1)
    #expect(document.title == "Scientist 👩‍🔬 & 🇺🇦")
    #expect(document.text.contains("🧪 ©"))
    #expect(document.text.contains("café"))
    #expect(!document.text.contains("<"))
    #expect(!document.text.contains("🦄"))
  }

  @Test func regionUsesSupportedLocaleOrNeutralWithoutForcingEnglish() async throws {
    for (locale, region) in [
      ("cs_CZ", "cz-cs"), ("en_GB", "uk-en"), ("ja_JP", "jp-jp"),
      ("xx_ZZ", "wt-wt"), ("en", "wt-wt")
    ] {
      let provider = DuckDuckGoEmojiSearchProvider { request in
        let url = try #require(request.url)
        #expect(
          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first {
              $0.name == "kl"
            }?
            .value == region)
        return try response(request, body: page(noResults))
      }
      #expect(try await provider.documents(for: "test", localeIdentifier: locale).isEmpty)
    }
  }

  @Test func errorsAreOwnedAndDoNotExposeBodies() async throws {
    for status in [301, 403, 429, 500] {
      let provider = DuckDuckGoEmojiSearchProvider { request in
        try response(request, status: status, body: "private response")
      }
      await #expect(throws: DuckDuckGoEmojiSearchError.httpStatus(status)) {
        try await provider.documents(for: "test", localeIdentifier: "en")
      }
    }
    for body in [
      "not HTML", page("<main>unexpected page</main>"),
      page("<div class='result'><h2>missing link</h2></div>"),
      "<!DOCTYPE html [<!ENTITY private SYSTEM 'file:///etc/passwd'>]>" + page(result())
    ] {
      let provider = DuckDuckGoEmojiSearchProvider { request in
        try response(request, body: body)
      }
      await #expect(throws: DuckDuckGoEmojiSearchError.malformedResponse) {
        try await provider.documents(for: "test", localeIdentifier: "en")
      }
    }
    let failed = DuckDuckGoEmojiSearchProvider { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: DuckDuckGoEmojiSearchError.transportFailure) {
      try await failed.documents(for: "test", localeIdentifier: "en")
    }
  }

  @Test func challengesAreNeverReturnedAsResults() async throws {
    for (status, body) in [
      (202, "private challenge"),
      (
        200,
        page(
          "<form id='challenge-form' action='/anomaly.js'><div class='anomaly-modal'>verify</div></form>"
        )
      )
    ] {
      let provider = DuckDuckGoEmojiSearchProvider { request in
        try response(request, status: status, body: body)
      }
      await #expect(throws: DuckDuckGoEmojiSearchError.challenge) {
        try await provider.documents(for: "test", localeIdentifier: "en")
      }
    }
  }

  @Test func challengeNamesInStylesAreNotChallengeForms() async throws {
    let provider = DuckDuckGoEmojiSearchProvider { request in
      try response(
        request, body: page("<style>.anomaly-modal { color: red }</style>" + result()))
    }
    #expect(try await provider.documents(for: "test", localeIdentifier: "en").count == 1)
  }

  @Test func nonEnglishQueryInEnglishInterfaceUsesNativeWordingAndRegion() async throws {
    let provider = DuckDuckGoEmojiSearchProvider { request in
      let items = try #require(
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
      #expect(
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) == [
          "q": "ранкова кава емодзі", "kl": "ua-uk"
        ])
      return try response(request, body: page(noResults))
    }
    #expect(try await provider.documents(for: "ранкова кава", localeIdentifier: "en-US").isEmpty)
  }

  @Test func noResultsMissingSnippetsAndTenDocumentLimit() async throws {
    let empty = DuckDuckGoEmojiSearchProvider { request in
      try response(request, body: page(noResults))
    }
    #expect(try await empty.documents(for: "test", localeIdentifier: "en").isEmpty)
    let provider = DuckDuckGoEmojiSearchProvider { request in
      let results = (1...11).map { result(url: "https://example.com/\($0)", snippet: nil) }.joined()
      return try response(request, body: page(results))
    }
    let documents = try await provider.documents(for: "test", localeIdentifier: "en")
    #expect(documents.count == 10)
    #expect(documents.map(\.url.path) == (1...10).map { "/\($0)" })
    #expect(documents.allSatisfy { $0.text.isEmpty })
  }

  @Test func missingSnippetCannotConsumeNextResultAndNestedNavigationCannotVote() async throws {
    let provider = DuckDuckGoEmojiSearchProvider { request in
      try response(
        request,
        body: page(
          result(url: "https://one.example", title: "First", snippet: nil)
            + result(
              url: "https://two.example", title: "Second",
              snippet:
                "<nav data-label='a > b'><div>🔠<nav>💥</nav>🏗️</div></nav><script>const text = '</nav>';</script>🧪"
            )
        ))
    }
    let documents = try await provider.documents(for: "test", localeIdentifier: "en")
    #expect(documents.count == 2)
    #expect(documents[0].title == "First")
    #expect(documents[0].text.isEmpty)
    #expect(documents[1].title == "Second")
    #expect(documents[1].text == "🧪")
  }

  @Test func resolvesWrappedSourcesAndRejectsUnsafeSources() async throws {
    let wrapped = DuckDuckGoEmojiSearchProvider { request in
      try response(
        request,
        body: page(
          result(
            url:
              "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Femoji%3Fa%3D1%26b%3D2&amp;rut=ignored"
          )))
    }
    let documents = try await wrapped.documents(for: "test", localeIdentifier: "en")
    #expect(documents.first?.url.absoluteString == "https://example.com/emoji?a=1&b=2")
    for url in [
      "javascript:alert(1)", "file:///private/test", "/relative",
      "https://user:secret@example.com/",
      "https://duckduckgo.com/l/?uddg=javascript%3Aalert(1)", "https://duckduckgo.com/?q=test"
    ] {
      let provider = DuckDuckGoEmojiSearchProvider { request in
        try response(request, body: page(result(url: url)))
      }
      await #expect(throws: DuckDuckGoEmojiSearchError.malformedResponse) {
        try await provider.documents(for: "test", localeIdentifier: "en")
      }
    }
  }

  @Test func inputResponseAndCancellationAreBounded() async throws {
    let unused = DuckDuckGoEmojiSearchProvider { _ in
      Issue.record("Transport must not run")
      throw URLError(.unknown)
    }
    #expect(try await unused.documents(for: " \n\t ", localeIdentifier: "en").isEmpty)
    await #expect(throws: DuckDuckGoEmojiSearchError.queryTooLong) {
      try await unused.documents(for: String(repeating: "a", count: 257), localeIdentifier: "en")
    }
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await unused.documents(for: "test", localeIdentifier: "en")
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let transportCancelled = DuckDuckGoEmojiSearchProvider { _ in throw URLError(.cancelled) }
    await #expect(throws: CancellationError.self) {
      try await transportCancelled.documents(for: "test", localeIdentifier: "en")
    }
    let cancelledAfterResponse = DuckDuckGoEmojiSearchProvider { request in
      withUnsafeCurrentTask { $0?.cancel() }
      return try response(request, body: page(result()))
    }
    let postResponse = Task {
      try await cancelledAfterResponse.documents(for: "test", localeIdentifier: "en")
    }
    await #expect(throws: CancellationError.self) { try await postResponse.value }
    let large = DuckDuckGoEmojiSearchProvider { request in
      try response(request, body: String(repeating: "x", count: 1_048_577))
    }
    await #expect(throws: DuckDuckGoEmojiSearchError.responseTooLarge) {
      try await large.documents(for: "test", localeIdentifier: "en")
    }
  }

  @Test func rankingCapsDomainsKeepsSixUniqueAndUsesHistoricalTies() throws {
    let glyphs = ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🥲"]
    let ranking = EmojiWebSearchRanking(
      emojis: glyphs.enumerated().map { fixture(id: "id-\($0.offset)", value: $0.element) })
    let first = try document("https://one.example/a", "😃😀😄😁😆😅😂")
    let sameHost = try document("https://one.example/b", "😀😀😀😀😀")
    let otherHost = try document("https://two.example/a", "😀")
    let documents = [
      first, sameHost, otherHost,
      try document("https://three.example", ""), try document("https://four.example", ""),
      try document("https://ignored.example", "🥲")
    ]
    let matches = ranking.matches(in: documents, query: "")
    #expect(matches.map(\.id) == ["id-0", "id-1", "id-2", "id-3", "id-4", "id-5"])
    #expect(matches.first?.score == 1 + 1.0 / 3)
    #expect(matches.first?.sourceURLs == [first.url, sameHost.url, otherHost.url])
    #expect(matches[1].score == 1)
    #expect(ranking.matches(in: documents, limit: 1, query: "").count == 1)
    #expect(ranking.matches(in: documents, limit: 0, query: "").isEmpty)
    #expect(ranking.matches(in: documents, limit: -1, query: "").isEmpty)
    #expect(
      ranking.matches(in: [try document("https://none.example", "no glyph")], query: "").isEmpty)
  }

  @Test func laterRepeatedSourcesDoNotOutvoteEarlierResultOnSameHost() throws {
    let ranking = EmojiWebSearchRanking(
      emojis: [fixture(id: "z", value: "😀"), fixture(id: "a", value: "😃")])
    let matches = ranking.matches(
      in: [
        try document("https://one.example/a", "😀"),
        try document("https://two.example/a", "😃"),
        try document("https://two.example/b", "😃"),
        try document("https://one.example/b", "😀")
      ], query: "")
    #expect(matches.map(\.id) == ["z", "a"])
    #expect(matches.map(\.score) == [1, 0.5])
  }

  @Test func completeGraphemesMapOnlyCatalogFamiliesAndSuppliedVariants() throws {
    let emojis = try Emojis.fetch(locale: Locale(identifier: "en"), filter: .none)
    let ranking = EmojiWebSearchRanking(emojis: emojis)
    let matches = ranking.matches(
      in: [
        try document("https://example.com", "👩🏿‍🔬 🇺🇦 👨‍👩‍👧‍👦 ❤︎ ❤️")
      ], query: "")
    let values = matches.map(\.value)
    #expect(values == ["👩‍🔬", "🇺🇦", "👨‍👩‍👧‍👦", "❤️"])
    for match in matches {
      #expect(emojis.contains { $0.id.rawValue == match.id && $0.value == match.value })
    }
    #expect(ranking.matches(in: [try document("https://example.com", "🏻 🏿 🦰 🦱")], query: "").isEmpty)
    #expect(
      ranking.matches(
        in: [try document("https://example.com", ":custom_unicorn: scientist flag custom.png")],
        query: ""
      )
      .isEmpty)
  }

  @Test func doesNotInventToneOrZWJSequencesOrPresentationPositions() throws {
    let ranking = EmojiWebSearchRanking(emojis: [
      fixture(id: "scientist", value: "👩‍🔬", variants: ["👩🏻‍🔬"]),
      fixture(id: "heart", value: "❤️"), fixture(id: "face", value: "😀"),
      fixture(id: "modifier", value: "🏿"), fixture(id: "hair", value: "🦰", group: .component)
    ])
    #expect(
      ranking.matches(in: [try document("https://example.com", "👩🏿‍🔬 👩‍🦄 😀️ 🏿 🦰")], query: "").isEmpty)
    #expect(
      ranking.matches(in: [try document("https://example.com", "👩🏻‍🔬 ❤ ❤︎ ❤️")], query: "").map(\.id)
        == ["scientist", "heart"])
  }
  @Test func breadcrumbsDoNotVoteButTheirContentAndGenuineSymbolsSurvive() throws {
    let ranking = EmojiWebSearchRanking(emojis: [
      fixture(id: "alphabet", value: "🔠"), fixture(id: "books", value: "📚"),
      fixture(id: "mask", value: "🤿"), fixture(id: "goggles", value: "🥽")
    ])
    let breadcrumb = try document(
      "https://example.com", "🔠 Categories » 📚 Index » scuba 🤿 Diving Mask 🥽 Goggles")
    #expect(ranking.matches(in: [breadcrumb], query: "").map(\.id) == ["mask", "goggles"])
    #expect(
      ranking.matches(in: [try document("https://example.com", "🔠 alphabet > 📚 books")], query: "")
        .map(\.id) == ["alphabet", "books"])
  }

  @Test func danglingJoinerCannotTurnIntoGenderFragment() throws {
    let ranking = EmojiWebSearchRanking(emojis: [
      fixture(id: "male", value: "♂️"), fixture(id: "female", value: "♀️"),
      fixture(id: "mask", value: "🤿")
    ])
    #expect(
      ranking.matches(in: [try document("https://example.com", "Divers | ‍♂️ ‍♀️ 👩‍ 🤿")], query: "")
        .map(\.id) == ["mask"])
    #expect(
      ranking.matches(in: [try document("https://example.com", "♂️ male and ♀️ female")], query: "")
        .map(\.id) == ["male", "female"])
  }

  @Test func publisherNavigationHTMLIsRemovedBeforeUnicodeExtraction() async throws {
    let provider = DuckDuckGoEmojiSearchProvider { request in
      try response(
        request,
        body: page(
          "<header>💥 Header</header><nav>🔠 Navigation</nav><footer>🏗️ Footer</footer>"
            + "<div class='result result--ad'>"
            + "<a class='result__a' href='https://ads.example'>💥 Advertisement</a></div>"
            + "<div class='result'><span class='result__badge'>Ad</span><a class='result__a' href='https://ads.example'>🏗️</a></div>"
            + result(
              title: "Books 📚",
              snippet:
                "<nav>🔠 Menu</nav><header>💥 Home</header><footer>🏗️ links</footer><script>💥</script>📚 books"
            )
        ))
    }
    let ranking = EmojiWebSearchRanking(emojis: [
      fixture(id: "alphabet", value: "🔠"), fixture(id: "books", value: "📚"),
      fixture(id: "explosion", value: "💥"), fixture(id: "construction", value: "🏗️")
    ])
    let documents = try await provider.documents(for: "books", localeIdentifier: "en")
    #expect(ranking.matches(in: documents, query: "books").map(\.id) == ["books"])
  }

  @Test func unrelatedSlogansCannotBorrowRelevanceFromATopicTitle() throws {
    let ranking = EmojiWebSearchRanking(emojis: try Emojis.fetch(locale: Locale(identifier: "en")))
    let documents = [
      EmojiWebSearchDocument(
        url: try #require(URL(string: "https://one.example/apple")),
        title: "Apple iPhone Emoji List for iOS and macOS. Copy and paste!",
        text: "Apple Emoji is a set for iOS devices. 🤝 Copy, paste, communicate!"),
      EmojiWebSearchDocument(
        url: try #require(URL(string: "https://two.example/iphone")),
        title: "iPhone emojis", text: "Copy Paste Iphone Emojis tap an emoji to copy 📱 📠")
    ]
    let matches = ranking.matches(in: documents, query: "iphone")
    #expect(matches.map(\.value) == ["📱", "📠"])
    #expect(matches.allSatisfy { $0.sourceURLs == [documents[1].url] })
    #expect(ranking.matches(in: [documents[0]], query: "iphone").isEmpty)
  }

  @Test func directQueryAssociationPrecedesAnIsolatedTitleSample() throws {
    let ranking = EmojiWebSearchRanking(emojis: try Emojis.fetch(locale: Locale(identifier: "en")))
    let sample = EmojiWebSearchDocument(
      url: try #require(URL(string: "https://one.example/iphone")),
      title: "iPhone Emojis | ⏲ | Copy & Paste", text: "Browse this collection.")
    let direct = EmojiWebSearchDocument(
      url: try #require(URL(string: "https://two.example/iphone")),
      title: "iPhone emojis", text: "Copy Paste Iphone Emojis 📱 📠")
    #expect(
      ranking.matches(in: [sample, direct], query: "iphone").map(\.value)
        == ["📱", "📠", "⏲️"])
    let list = EmojiWebSearchDocument(
      url: direct.url, title: "Birthday emojis",
      text: "Copy and paste birthday emojis. Find cakes 🎂, party poppers 🎉 and balloons 🎈.")
    #expect(ranking.matches(in: [list], query: "birthday").map(\.value) == ["🎂", "🎉", "🎈"])
  }

  @Test func adjacentPromotionsCannotInheritDirectTopicEvidence() throws {
    let ranking = EmojiWebSearchRanking(emojis: try Emojis.fetch(locale: Locale(identifier: "en")))
    let source = try #require(URL(string: "https://one.example/iphone"))
    let phone = EmojiWebSearchDocument(
      url: try #require(URL(string: "https://two.example/iphone")),
      title: "iPhone 📱", text: "")
    for promotion in [
      "Follow us 🤝 and subscribe 👍!", "Follow us 🤝, subscribe 👍!",
      "Enjoy our website 🤝👍", "Copy, paste, communicate 🤝👍"
    ] {
      let generic = EmojiWebSearchDocument(
        url: source, title: "iPhone emojis", text: "iPhone emojis. " + promotion)
      #expect(ranking.matches(in: [generic, phone], query: "iphone").map(\.value) == ["📱"])
    }
  }

  @Test func groundedTitlesSentencesAndStandaloneListsKeepUsefulEmoji() throws {
    let ranking = EmojiWebSearchRanking(emojis: try Emojis.fetch(locale: Locale(identifier: "en")))
    let source = try #require(URL(string: "https://one.example/topic"))
    let cases: [(String, String, String, [String])] = [
      ("handshake", "Handshake 🤝", "Copy, paste, communicate!", ["🤝"]),
      ("handshake", "Handshake emojis", "A handshake 🤝 marks agreement.", ["🤝"]),
      ("birthday", "Birthday emojis", "🎂🎉", ["🎂", "🎉"]),
      ("rizz", "Rizz emojis", "Rizz suggestions 😏🔥. Subscribe 👍", ["😏", "🔥"]),
      ("кава", "Кава", "Кава ☕. Підпишись 🤝", ["☕"]),
      ("café", "Coffee", "CAFE ☕. Copy 🤝", ["☕"])
    ]
    for (query, title, text, expected) in cases {
      let documents = [EmojiWebSearchDocument(url: source, title: title, text: text)]
      #expect(ranking.matches(in: documents, query: query).map(\.value) == expected)
    }
  }

  @Test func hostAliasesShareOneVoteAndPreserveOriginalProvenance() throws {
    let ranking = EmojiWebSearchRanking(emojis: [fixture(id: "face", value: "😀")])
    let documents = try [
      document("https://www.example.com/a", "😀"), document("https://m.example.com/b", "😀"),
      document("https://example.com./c", "😀"), document("https://other.example/d", "😀")
    ]
    let result = try #require(ranking.matches(in: documents, query: "").first)
    #expect(result.score == 1.25)
    #expect(result.sourceURLs == documents.map(\.url))
  }

}

nonisolated private func response(
  _ request: URLRequest, status: Int = 200, body: String
) throws -> (Data, HTTPURLResponse) {
  let url = try #require(request.url)
  let response = try #require(
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
  return (Data(body.utf8), response)
}

nonisolated private func document(_ url: String, _ text: String) throws -> EmojiWebSearchDocument {
  EmojiWebSearchDocument(url: try #require(URL(string: url)), title: text, text: "")
}

nonisolated private func fixture(
  id: String, value: String, variants: [String] = [], group: Emoji.Group = .smileysEmotion
) -> Emoji {
  Emoji(
    id: .init(rawValue: id), value: value, group: group, subgroup: .init(rawValue: "fixture"),
    unicodeVersion: "1", sortOrder: 0, skinToneSupport: variants.isEmpty ? .none : .single,
    skinToneVariants: variants.enumerated()
      .map {
        Emoji.SkinToneVariant(
          id: .init(rawValue: "\(id)-\($0.offset)"), value: $0.element, tones: [.light])
      }, localization: .init(localeIdentifier: "en", name: id, searchTokens: []))
}

nonisolated private let noResults =
  "<div class='result result--no-result'><div class='no-results'>No results found</div></div>"

nonisolated private func page(_ content: String) -> String {
  "<!DOCTYPE html><html><head><meta charset='UTF-8'><title>DuckDuckGo</title></head><body><div id='links' class='results'>\(content)</div></body></html>"
}

nonisolated private func result(
  url: String = "https://example.com/emoji", title: String = "😀", snippet: String? = "Observed 😀"
) -> String {
  let snippet = snippet.map { "<a class='result__snippet'>\($0)</a>" } ?? ""
  return
    "<div class='result results_links results_links_deep web-result'><div class='result__body'><h2 class='result__title'><a class='result__a' href='\(url)'>\(title)</a></h2>\(snippet)</div></div>"
}
