import Foundation
import NaturalLanguage

nonisolated enum EmojiSemanticLanguageRouter {
  static func encoder(for query: String) -> EmojiSearchProvider {
    guard let normalized = EmojiSearchInput.normalized(query) else { return .multilingual }
    let sample = String(String.UnicodeScalarView(normalized.unicodeScalars.prefix(512)))
    let letters = sample.unicodeScalars.filter(\.properties.isAlphabetic)
    guard !letters.isEmpty,
      letters.allSatisfy({ $0.value <= 0x024F || (0x1E00...0x1EFF).contains($0.value) })
    else { return .multilingual }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
    guard let first = hypotheses.first, first.key == .english,
      first.value >= 0.3, first.value - (hypotheses.dropFirst().first?.value ?? 0) >= 0.15
    else { return .multilingual }
    return .miniLM
  }

  static func activeProviders(
    in enabled: Set<EmojiSearchProvider>, for query: String
  ) -> Set<EmojiSearchProvider> {
    let selected = encoder(for: query)
    return enabled.filter { $0 != .miniLM && $0 != .multilingual || $0 == selected }
  }
}
