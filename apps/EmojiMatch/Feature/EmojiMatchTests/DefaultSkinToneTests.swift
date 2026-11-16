import Emojis
import Foundation
import Testing

@testable import EmojiMatch

struct DefaultSkinToneTests {
  @Test func persistsEveryToneAndFallsBackForInvalidPreference() throws {
    try withToneStore { defaults, _, _ in
      let settings = AppSettings(defaults: defaults, prefix: "settings")
      #expect(settings.defaultSkinTone == .yellow)
      #expect(DefaultSkinTone.allCases.map(\.hand) == ["✋", "✋🏻", "✋🏼", "✋🏽", "✋🏾", "✋🏿"])
      for tone in DefaultSkinTone.allCases {
        settings.defaultSkinTone = tone
        #expect(AppSettings(defaults: defaults, prefix: "settings").defaultSkinTone == tone)
      }
      defaults.set("invalid", forKey: "settings.defaultSkinTone")
      #expect(AppSettings(defaults: defaults, prefix: "settings").defaultSkinTone == .yellow)
    }
  }

  @Test func defaultsUseSupportedSuppliedVariantsAndPreserveStructure() throws {
    let catalog = EmojiBrowserCatalog.shared
    let bases = ["👍", "🤝", "👫", "👭", "🧑‍🤝‍🧑", "👩‍❤️‍👨", "🧑‍⚕️"]
    let emojis = try Emojis.fetch(filter: .apple)
    for value in bases {
      let emoji = try #require(emojis.first { $0.value == value })
      let base = EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
      #expect(catalog.defaultVariant(for: base, tone: .yellow) == nil)
      for tone in DefaultSkinTone.allCases where tone != .yellow {
        let variant = try #require(catalog.defaultVariant(for: base, tone: tone))
        #expect(
          emoji.skinToneVariants.contains {
            $0.value == variant.value && $0.id.rawValue == variant.id
          })
        #expect(catalog.variants(for: base).contains(variant))
        let modifiers = variant.value.unicodeScalars.filter {
          (0x1F3FB...0x1F3FF).contains($0.value)
        }
        #expect(!modifiers.isEmpty)
        #expect(modifiers.allSatisfy { $0 == tone.modifier })
      }
    }
    let face = EmojiSelection(id: "1F600", value: "😀")
    #expect(catalog.defaultVariant(for: face, tone: .dark) == nil)
  }

  @Test func matchingTonesCannotSelectDifferentGenderStructureOrUnsupportedGlyph() throws {
    let original = try #require(Emojis.fetch(filter: .apple).first { $0.value == "💑" })
    let emoji = Emoji(
      id: original.id, value: original.value, group: original.group, subgroup: original.subgroup,
      unicodeVersion: original.unicodeVersion, sortOrder: original.sortOrder,
      skinToneSupport: original.skinToneSupport,
      skinToneVariants: [
        .init(id: .init(rawValue: "different-structure"), value: "👩🏿‍❤️‍👨🏿", tones: [.dark, .dark]),
        .init(id: .init(rawValue: "unsupported"), value: "💑🏿\u{10FFFF}", tones: [.dark])
      ], localization: original.localization)
    let catalog = EmojiBrowserCatalog(
      loadEmojis: { [emoji] }, loadNativeCategories: { [] }, loadSymbols: { [] })
    let base = EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
    #expect(catalog.defaultVariant(for: base, tone: .dark) == nil)
  }

  @Test func explicitYellowAndMixedTonesOverrideDefaultAndSurviveReload() throws {
    try withToneStore { defaults, directory, store in
      let catalog = EmojiBrowserCatalog.shared
      let item = try #require(catalog.items.first { $0.selection.value == "🤝" })
      let base = try #require(item.familyBase)
      #expect(store.explicitPreferredSelection(for: base) == nil)
      #expect(
        catalog.preferredItem(item, usageStore: store, defaultSkinTone: .dark).selection.value
          == "🤝🏿")
      #expect(store.setPreferredSelection(base, for: base))
      let restored = EmojiUsageStore(defaults: defaults, libraryDirectory: directory)
      #expect(restored.explicitPreferredSelection(for: base) == base)
      #expect(
        catalog.preferredItem(item, usageStore: restored, defaultSkinTone: .dark).selection == base)
      let mixed = try #require(catalog.variants(for: base).first { $0.value == "🫱🏻‍🫲🏿" })
      #expect(restored.setPreferredSelection(mixed, for: base))
      let reloaded = EmojiUsageStore(defaults: defaults, libraryDirectory: directory)
      for tone in DefaultSkinTone.allCases {
        #expect(
          catalog.preferredItem(item, usageStore: reloaded, defaultSkinTone: tone).selection
            == mixed)
      }
    }
  }

  @Test func browseAndSearchApplyDefaultWhileFavoritesAndRecentsStayExact() throws {
    try withToneStore { _, _, store in
      let base = EmojiSelection(id: "1F44D", value: "👍")
      store.toggleFavorite(base)
      store.record(base)
      let searchStore = EmojiSearchStore()
      let catalog = EmojiBrowserCatalog.shared
      let item = try #require(catalog.items.first { $0.selection.id == base.id })
      let browse = EmojiMatchContent(
        query: "", searchStore: searchStore, usageStore: store, defaultSkinTone: .medium)
      #expect(browse.navigationLayout.items.first { $0.id == item.id }?.selection.value == "👍🏽")
      for sectionID in ["favorites", "recent"] {
        #expect(browse.sections.first { $0.id == sectionID }?.items.first?.selection == base)
      }
      let search = EmojiMatchContent(
        query: "thumbs up", searchStore: searchStore, usageStore: store, defaultSkinTone: .medium)
      #expect(
        search.navigationLayout.items.contains {
          $0.familyBase == base && $0.selection.value == "👍🏽"
        })
      #expect(search.categories.flatMap(\.items).first { $0.id == item.id }?.selection.value == "👍🏽")
    }
  }
}

private func withToneStore(
  _ operation: (UserDefaults, URL, EmojiUsageStore) throws -> Void
) throws {
  let suite = "DefaultSkinToneTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
  try operation(
    defaults, directory, EmojiUsageStore(defaults: defaults, libraryDirectory: directory))
}
