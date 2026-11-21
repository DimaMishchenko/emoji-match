import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiSearchFusionTests {
  @Test(arguments: ["exact-name", "exact-shortcode", "exact-glyph"])
  func exactProtection(_ id: String) {
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [id, id], lexicalIDs: ["local", id],
      providers: [
        .init(provider: .miniLM, matches: [match("local")]),
        .init(provider: .luna, matches: [match("local"), match(id)])
      ])
    #expect(result == [id, "local"])
  }

  @Test func semanticCorroborationPrecedesUnsupportedOnlineSingleton() {
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["weak", "supported", "tail"],
      providers: [
        .init(provider: .miniLM, matches: [match("supported", score: -10), match("semantic-only")]),
        .init(provider: .duckDuckGo, matches: [match("distraction", score: 1_000_000)])
      ])
    #expect(result.first == "supported")
    #expect(Set(result) == ["weak", "supported", "tail", "semantic-only", "distraction"])
  }

  @Test func independentWebEvidenceCanLeadConflictingLocalGuesses() throws {
    let slang = match(
      "online-only", urls: try [url("https://one.example/a"), url("https://two.example/b")])
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["lexical-guess"],
      providers: [
        .init(provider: .miniLM, matches: [match("semantic-guess")]),
        .init(provider: .duckDuckGo, matches: [slang])
      ])
    #expect(result == ["online-only", "lexical-guess", "semantic-guess"])
  }

  @Test func onlineSourceAgreementDoesNotRequireLocalPresence() {
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["guess"],
      providers: [
        .init(provider: .luna, matches: [match("slang")]),
        .init(provider: .duckDuckGo, matches: [match("slang")])
      ])
    #expect(result == ["slang", "guess"])
  }

  @Test func repeatedAndAliasedHostsAreNotIndependentEvidence() throws {
    let singleton = match(
      "web",
      urls: try [
        url("https://www.example.com/a"), url("https://m.example.com/b"),
        url("https://EXAMPLE.com./c"), url("file:///example")
      ])
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["local"],
      providers: [.init(provider: .duckDuckGo, matches: [singleton, singleton])])
    #expect(result == ["local", "web"])
  }

  @Test func duplicatesCannotCreateConsensusOrConsumeRanks() {
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["a", "a", "b"],
      providers: [
        .init(provider: .miniLM, matches: [match("c")]),
        .init(provider: .duckDuckGo, matches: [match("d"), match("d")]),
        .init(provider: .duckDuckGo, matches: [match("d")])
      ])
    #expect(result == ["a", "c", "d", "b"])
  }

  @Test func familyIDsDeduplicateToneVariantsAcrossSources() {
    let result = EmojiSearchFusion.rankedIDs(
      exactIDs: [], lexicalIDs: ["scientist"],
      providers: [
        .init(
          provider: .miniLM,
          matches: [.init(id: "scientist", value: "👩‍🔬", score: 0.7, sourceURLs: [])]),
        .init(
          provider: .luna,
          matches: [.init(id: "scientist", value: "👩🏿‍🔬", score: 2, sourceURLs: [])])
      ])
    #expect(result == ["scientist"])
  }

  @Test func scoresAreNotProbabilitiesOrCrossSourceThresholds() {
    func order(_ scores: [Double]) -> [String] {
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: ["a", "b"],
        providers: [
          .init(
            provider: .miniLM, matches: [match("b", score: scores[0]), match("c", score: scores[1])]
          ), .init(provider: .luna, matches: [match("c", score: scores[2])])
        ])
    }
    #expect(order([0.2, 0.1, 1]) == ["b", "c", "a"])
    #expect(order([-.infinity, .nan, .infinity]) == order([0.2, 0.1, 1]))
  }

  @Test func absentOrFailedSourcesRetainLocalOrderAndNeverForceNoMatch() {
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: ["a", "b"], providers: []) == ["a", "b"])
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: ["a", "b"],
        providers: [.init(provider: .duckDuckGo, matches: []), .init(provider: .luna, matches: [])])
        == ["a", "b"]
    )
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: [], providers: [.init(provider: .luna, matches: [match("only")])])
        == ["only"])
    #expect(
      EmojiSearchFusion.rankedIDs(exactIDs: [], lexicalIDs: [], providers: []).isEmpty)
  }

  @Test func bothLocalModelsContributeDistinctEvidenceButRepeatedProvidersDoNot() {
    let miniLM = EmojiSearchProviderResult(
      provider: .miniLM, matches: [match("a"), match("shared")])
    let e5 = EmojiSearchProviderResult(provider: .multilingual, matches: [match("shared")])
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: [], providers: [miniLM, e5]) == ["shared", "a"])
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: ["lexical"], providers: [e5, e5]) == ["lexical", "shared"])
    let fakeLexical = EmojiSearchProviderResult(provider: .lexical, matches: [match("fake")])
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: [], providers: [fakeLexical]
      )
      .isEmpty)
  }

  @Test func sourceGroupOrderDoesNotChangeRanking() {
    let luna = EmojiSearchProviderResult(provider: .luna, matches: [match("a"), match("b")])
    let web = EmojiSearchProviderResult(provider: .duckDuckGo, matches: [match("b"), match("a")])
    #expect(
      EmojiSearchFusion.rankedIDs(
        exactIDs: [], lexicalIDs: [], providers: [luna, web])
        == EmojiSearchFusion.rankedIDs(
          exactIDs: [], lexicalIDs: [], providers: [web, luna]))
  }
}

nonisolated private func match(
  _ id: String, score: Double = 1, urls: [URL] = []
) -> EmojiSearchMatch {
  EmojiSearchMatch(id: id, value: id, score: score, sourceURLs: urls)
}

nonisolated private func url(_ value: String) throws -> URL {
  try #require(URL(string: value))
}
