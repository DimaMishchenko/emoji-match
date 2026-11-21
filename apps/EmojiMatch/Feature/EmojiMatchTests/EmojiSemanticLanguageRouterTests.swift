import Foundation
import Testing

@testable import EmojiMatch

struct EmojiSemanticLanguageRouterTests {
  @Test(arguments: ["coffee", "birthday", "good morning", "hello world", "I need a quiet moment"])
  func englishQueriesUseMiniLM(_ query: String) {
    #expect(EmojiSemanticLanguageRouter.encoder(for: query) == .miniLM)
  }

  @Test(arguments: [
    "Ранкова кава", "кіт", "дом", "おはよう", "猫", "생일", "مرحبا", "नमस्ते",
    "buenos días", "schönen guten Morgen", "wesołych świąt", "bonjour", "hola",
    "", "123", "📱"
  ])
  func otherOrUncertainQueriesUseE5(_ query: String) {
    #expect(EmojiSemanticLanguageRouter.encoder(for: query) == .multilingual)
  }

  @Test func routingChangesEligibilityWithoutEnablingDisabledSources() {
    let enabled = Set(EmojiSearchProvider.allCases)
    let english = EmojiSemanticLanguageRouter.activeProviders(in: enabled, for: "good morning")
    let ukrainian = EmojiSemanticLanguageRouter.activeProviders(in: enabled, for: "Ранкова кава")
    #expect(english == [.lexical, .miniLM, .luna, .duckDuckGo])
    #expect(ukrainian == [.lexical, .multilingual, .luna, .duckDuckGo])
    #expect(EmojiSemanticLanguageRouter.activeProviders(in: [.miniLM], for: "Ранкова кава").isEmpty)
    #expect(
      EmojiSemanticLanguageRouter.activeProviders(in: [.multilingual], for: "good morning").isEmpty)
    #expect(EmojiSemanticLanguageRouter.activeProviders(in: [], for: "coffee").isEmpty)
  }

  @Test func surroundingWhitespaceCannotChangeRoutingAtTheDispatchBoundary() {
    for query in ["good morning", "Ранкова кава"] {
      let padded = String(repeating: " ", count: 512) + query + " \n\t"
      #expect(
        EmojiSemanticLanguageRouter.encoder(for: padded)
          == EmojiSemanticLanguageRouter.encoder(for: query))
      #expect(
        EmojiSemanticLanguageRouter.activeProviders(in: [.miniLM, .multilingual], for: padded)
          == EmojiSemanticLanguageRouter.activeProviders(in: [.miniLM, .multilingual], for: query))
    }
  }

  @Test func languageSamplingIsBounded() {
    let prefix = String(repeating: "good morning ", count: 50)
    #expect(
      EmojiSemanticLanguageRouter.encoder(for: prefix + String(repeating: "a", count: 1_000))
        == EmojiSemanticLanguageRouter.encoder(for: prefix))
  }
}
