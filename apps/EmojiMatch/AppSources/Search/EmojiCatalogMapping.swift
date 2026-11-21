import Emojis
import Foundation

nonisolated struct EmojiCatalogMapping: Sendable {
  private struct Family: Equatable, Sendable {
    let id: String
    let value: String
  }

  private let exact: [String: Family]
  private let aliases: [String: [Family]]

  init(emojis: [Emoji]) {
    var exact: [String: Family] = [:]
    var aliases: [String: [Family]] = [:]
    for emoji in emojis where emoji.group != .component {
      let family = Family(id: emoji.id.rawValue, value: emoji.value)
      for sequence in [emoji.value] + emoji.skinToneVariants.map(\.value) {
        guard sequence.count == 1, !Self.isComponent(sequence) else { continue }
        exact[sequence] = family
        for form in Self.presentationForms(sequence)
        where !aliases[form, default: []].contains(family) {
          aliases[form, default: []].append(family)
        }
      }
    }
    self.exact = exact
    self.aliases = aliases
  }

  func match(for sequence: String) -> EmojiSearchMatch? {
    guard sequence.count == 1 else { return nil }
    let family = exact[sequence] ?? aliases[sequence].flatMap { $0.count == 1 ? $0.first : nil }
    guard let family else { return nil }
    return EmojiSearchMatch(id: family.id, value: family.value, score: 1, sourceURLs: [])
  }

  func matches(for sequences: [String], limit: Int = 6) -> [EmojiSearchMatch] {
    guard limit > 0 else { return [] }
    var seen: Set<String> = []
    var result: [EmojiSearchMatch] = []
    for (index, sequence) in sequences.enumerated() {
      guard let match = match(for: sequence), seen.insert(match.id).inserted else { continue }
      result.append(
        EmojiSearchMatch(
          id: match.id, value: match.value, score: 1 / Double(index + 1), sourceURLs: []))
      if result.count == limit { break }
    }
    return result
  }

  private static func isComponent(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy {
      (0x1F3FB...0x1F3FF).contains($0.value) || (0x1F9B0...0x1F9B3).contains($0.value)
        || $0.value == 0xFE0E || $0.value == 0xFE0F
    }
  }

  private static func presentationForms(_ value: String) -> [String] {
    var forms = [""]
    for scalar in value.unicodeScalars {
      if scalar.value == 0xFE0F {
        forms = forms.flatMap { [$0, $0 + "\u{FE0E}", $0 + "\u{FE0F}"] }
      } else {
        forms = forms.map { $0 + String(scalar) }
      }
    }
    return forms
  }
}
