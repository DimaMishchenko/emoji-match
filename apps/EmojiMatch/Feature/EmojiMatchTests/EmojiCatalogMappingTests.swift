import Emojis
import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiCatalogMappingTests {
  @Test func completeSequencesPreserveFamiliesAndOrder() throws {
    let emojis = try Emojis.fetch(locale: Locale(identifier: "en"), filter: .none)
    let mapper = EmojiCatalogMapping(emojis: emojis)
    let matches = mapper.matches(for: [
      "invalid", "👩🏿‍🔬", "👩‍🔬", "🇺🇦", "👨‍👩‍👧‍👦", "❤︎", "❤️", "👨‍🔬"
    ])
    #expect(matches.map(\.value) == ["👩‍🔬", "🇺🇦", "👨‍👩‍👧‍👦", "❤️", "👨‍🔬"])
    #expect(matches.map(\.score) == [0.5, 0.25, 0.2, 1.0 / 6, 0.125])
    #expect(matches.allSatisfy { $0.sourceURLs.isEmpty })
    #expect(
      matches.allSatisfy { match in
        emojis.contains { $0.id.rawValue == match.id && $0.value == match.value }
      })
    #expect(mapper.match(for: "❤")?.value == "❤️")
  }

  @Test func rejectsComponentsCompositionsAndUnknownSequences() throws {
    let mapper = EmojiCatalogMapping(
      emojis: try Emojis.fetch(locale: Locale(identifier: "en"), filter: .none))
    for sequence in ["", "🏻", "🏿", "🦰", "🦱", "🇺", "😀😃", " 👩‍🔬", "👩‍🦄", "😀️", ":heart:", "heart"] {
      #expect(mapper.match(for: sequence) == nil)
    }
    #expect(mapper.matches(for: ["😀", "😃"], limit: 1).map(\.value) == ["😀"])
    #expect(mapper.matches(for: ["😀"], limit: 0).isEmpty)
    #expect(mapper.matches(for: ["😀"], limit: -1).isEmpty)
    #expect(mapper.matches(for: ["😀", "😃", "😄", "😁", "😆", "😅", "😂"]).count == 6)
  }
}
