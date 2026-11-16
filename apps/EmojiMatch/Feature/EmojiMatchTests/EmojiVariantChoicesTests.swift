import AppKit
import Testing

@testable import EmojiMatch

@Suite struct EmojiVariantChoicesTests {
  @Test func fallbackMovesAcrossRowsAndSubmitsExactVariant() {
    _ = NSApplication.shared
    let variants = (0..<10).map { EmojiSelection(id: "variant:\($0)", value: "\($0)") }
    let choices = EmojiVariantChoices(variants: variants, labels: variants.map(\.value))
    var selected: EmojiSelection?
    choices.onSelect = { selected = variants[$0] }
    #expect(choices.handleKey(124))
    #expect(choices.selectedIndex == 1)
    #expect(choices.handleKey(125))
    #expect(choices.selectedIndex == 7)
    #expect(choices.handleKey(36))
    #expect(selected == variants[7])
    #expect(choices.handleKey(126))
    #expect(choices.selectedIndex == 1)
    #expect(choices.handleKey(123))
    #expect(choices.selectedIndex == 0)
    #expect(choices.handleKey(123))
    #expect(choices.selectedIndex == 0)
    #expect(!choices.handleKey(53))
  }

  @Test func compactFallbackClampsAtEdgesAndSpaceSubmits() {
    let variants = (0..<6).map { EmojiSelection(id: "tone:\($0)", value: "\($0)") }
    let choices = EmojiVariantChoices(variants: variants, labels: variants.map(\.value))
    var selected: Int?
    choices.onSelect = { selected = $0 }
    for _ in 0..<9 { #expect(choices.handleKey(124)) }
    #expect(choices.selectedIndex == 5)
    #expect(choices.handleKey(49))
    #expect(selected == 5)
  }
}
