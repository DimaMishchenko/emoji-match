import Foundation
import Testing

@testable import EmojiMatch

struct EmojiWebSearchRerankingTests {
  @Test func combinesCompleteCandidateRanksWithStableWebTiesAndProvenance() {
    let web = matches(["impact", "smirk", "wink", "eyes", "hand", "person", "heart"])
    let result = EmojiWebSearchReranking.matches(
      web: web, semanticIDs: ["wink", "smirk", "eyes", "impact", "heart", "hand", "person"])
    #expect(result.map(\.id) == ["wink", "smirk", "impact", "eyes", "hand", "heart"])
    #expect(result.allSatisfy { $0.sourceURLs == web.first?.sourceURLs })
    #expect(result.allSatisfy { $0.score.isFinite })
    #expect(Set(result.map(\.id)).count == result.count)
  }

  @Test func incompleteOrInvalidSemanticRanksKeepWebOrdering() {
    let web = matches(["camera", "prohibition", "phone"])
    for ids in [["camera"], ["camera", "camera", "phone"], ["camera", "phone", "unknown"]] {
      #expect(EmojiWebSearchReranking.matches(web: web, semanticIDs: ids) == web)
    }
    #expect(EmojiWebSearchReranking.matches(web: web, semanticIDs: [], limit: 0).isEmpty)
  }

  @Test func explicitConstraintsAndPersonalRequestsKeepWebOrdering() {
    for query in [
      "camera off", "train delayed", "sold out", "no photos", "not happy", "without sound",
      "I need some space", "we want a break", "I don’t want this", "service unavailable"
    ] {
      #expect(
        !EmojiWebSearchReranking.usesSemanticOrdering(for: query))
    }
    for query in ["coffee", "birthday", "proud of you", "launching a new feature"] {
      #expect(EmojiWebSearchReranking.usesSemanticOrdering(for: query))
    }
    #expect(
      !EmojiWebSearchReranking.usesSemanticOrdering(for: "Ранкова кава"))
  }

  @Test func nonEnglishAndUncertainQueriesNeverUseMiniLMWebOrdering() {
    for query in ["кіт", "дом", "hola", "bonjour", "おはよう", "📱"] {
      #expect(!EmojiWebSearchReranking.usesSemanticOrdering(for: query))
    }
  }

  @Test func queryWordingPreservesTextAndUsesTheDetectedLanguage() {
    for query in ["rizz", "crash", "birthday"] {
      #expect(
        EmojiWebSearchQuery.text(for: query, localeIdentifier: "en")
          == "emoji for \(query) copy and paste")
    }
    #expect(
      EmojiWebSearchQuery.text(for: "ранкова кава", localeIdentifier: "en")
        == "ранкова кава емодзі")
    #expect(EmojiWebSearchQuery.text(for: "お疲れ様", localeIdentifier: "en") == "お疲れ様 絵文字")
    #expect(EmojiWebSearchQuery.text(for: "생일", localeIdentifier: "en") == "생일 이모지")
    #expect(EmojiWebSearchQuery.text(for: "猫", localeIdentifier: "en") == "猫 表情符号")
    #expect(EmojiWebSearchQuery.text(for: "猫", localeIdentifier: "ja") == "猫 絵文字")
    #expect(EmojiWebSearchQuery.text(for: "猫", localeIdentifier: "zh-Hant-TW") == "猫 表情符號")
    #expect(
      EmojiWebSearchQuery.text(for: "anniversaire", localeIdentifier: "fr")
        == "anniversaire émoji")
  }

  private func matches(_ ids: [String]) -> [EmojiSearchMatch] {
    ids.enumerated()
      .map {
        EmojiSearchMatch(
          id: $0.element, value: $0.element, score: 1 / Double($0.offset + 1),
          sourceURLs: [URL(string: "https://example.com/topic")!])
      }
  }
}
