import AppKit
import CoreText
import Emojis
import Foundation
import Observation

struct EmojiMatchItem: Identifiable, Equatable, Sendable {
  let id: String
  let selection: EmojiSelection
  let accessibilityLabel: String
  var familyBase: EmojiSelection? = nil
}

extension EmojiMatchItem {
  nonisolated static func searchResult(_ result: EmojiSearchResult) -> Self {
    Self(
      id: "search:\(result.id)",
      selection: result.selection,
      accessibilityLabel: result.accessibilityLabel
    )
  }

}

struct EmojiBrowserSection: Identifiable, Sendable {
  let id: String
  let title: LocalizedStringResource
  let symbolName: String
  let items: [EmojiMatchItem]
}

@Observable
final class EmojiBrowserCatalog {
  private(set) var sections: [EmojiBrowserSection] = []
  private(set) var symbolSections: [EmojiBrowserSection] = []
  private(set) var categoryImages: [String: NSImage] = [:]
  private(set) var loadError: String?
  private var emojisByID: [String: Emoji] = [:]
  private var basesByVariantID: [String: EmojiSelection] = [:]
  @ObservationIgnored private var variantsByBaseID: [String: [EmojiSelection]] = [:]
  @ObservationIgnored private var renderSupport: [String: Bool] = [:]

  private let loader: @MainActor () throws -> [Emoji]
  private let nativeLoader: @MainActor () throws -> [NativeEmojiCategory]
  private let symbolLoader: @MainActor () throws -> [NativeSymbolCategory]

  static let shared = EmojiBrowserCatalog()

  var items: [EmojiMatchItem] {
    sections.flatMap(\.items)
  }

  init(
    loadEmojis: (@MainActor () throws -> [Emoji])? = nil,
    loadNativeCategories: @escaping @MainActor () throws -> [NativeEmojiCategory] = {
      try NativeSymbolCatalog.loadEmojiCategories()
    },
    loadSymbols: @escaping @MainActor () throws -> [NativeSymbolCategory] = {
      try NativeSymbolCatalog.load()
    }
  ) {
    loader = loadEmojis ?? { try Self.loadAvailableEmojis() }
    nativeLoader = loadNativeCategories
    symbolLoader = loadSymbols
    reload()
  }
}

extension EmojiBrowserCatalog {
  func reload() {
    do {
      let emojis = try loader()
      let native = (try? nativeLoader()) ?? []
      let symbols = (try? symbolLoader()) ?? []
      sections =
        native.isEmpty ? Self.loadSections(emojis) : Self.loadNativeSections(native, emojis: emojis)
      symbolSections = symbols.map { category in
        EmojiBrowserSection(
          id: category.id, title: LocalizedStringResource(stringLiteral: category.title),
          symbolName: "character",
          items: category.entries.map { selection in
            EmojiMatchItem(
              id: "catalog:\(category.id):\(selection.id)", selection: selection,
              accessibilityLabel: category.descriptionsByID[selection.id] ?? selection.value)
          })
      }
      categoryImages = [:]
      for category in native { categoryImages[category.id] = category.image }
      for category in symbols { categoryImages[category.id] = category.image }
      if let images = try? NativeSymbolCatalog.loadStickerCategoryImages() {
        categoryImages["imported"] = images.first
        if images.count == 2 { categoryImages["genmoji"] = images[1] }
      }
      emojisByID = Dictionary(uniqueKeysWithValues: emojis.map { ($0.id.rawValue, $0) })
      basesByVariantID = [:]
      variantsByBaseID = [:]
      for emoji in emojis {
        let base = EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
        for variant in emoji.skinToneVariants {
          basesByVariantID[variant.id.rawValue] = base
        }
      }
      loadError = nil
    } catch {
      sections = []
      symbolSections = []
      categoryImages = [:]
      emojisByID = [:]
      basesByVariantID = [:]
      variantsByBaseID = [:]
      loadError = error.localizedDescription
    }
  }

  func base(for selection: EmojiSelection) -> EmojiSelection? {
    guard selection.asset == nil else { return nil }
    if let emoji = emojisByID[selection.id] {
      return EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
    }
    return basesByVariantID[selection.id]
  }

  func hasVariants(for selection: EmojiSelection) -> Bool {
    guard let base = base(for: selection) else { return false }
    return !(emojisByID[base.id]?.skinToneVariants.isEmpty ?? true)
  }

  func variants(for selection: EmojiSelection) -> [EmojiSelection] {
    guard let base = base(for: selection), let emoji = emojisByID[base.id] else { return [] }
    if let cached = variantsByBaseID[base.id] { return cached }
    let variants =
      [base]
      + emoji.skinToneVariants.compactMap { variant in
        supports(variant.value)
          ? EmojiSelection(id: variant.id.rawValue, value: variant.value) : nil
      }
    variantsByBaseID[base.id] = variants
    return variants
  }

  func label(for variant: EmojiSelection) -> String {
    guard let base = base(for: variant), let emoji = emojisByID[base.id] else {
      return variant.value
    }
    guard let supplied = emoji.skinToneVariants.first(where: { $0.id.rawValue == variant.id })
    else {
      return "\(emoji.localization.name), \(String(localized: "Default")) \(variant.value)"
    }
    let tones = supplied.tones
      .map { tone in
        switch tone {
        case .light: String(localized: "Light skin tone")
        case .mediumLight: String(localized: "Medium-light skin tone")
        case .medium: String(localized: "Medium skin tone")
        case .mediumDark: String(localized: "Medium-dark skin tone")
        case .dark: String(localized: "Dark skin tone")
        }
      }
      .joined(separator: ", ")
    return "\(emoji.localization.name), \(tones) \(variant.value)"
  }

  func preferredItem(
    _ item: EmojiMatchItem, usageStore: EmojiUsageStore, defaultSkinTone: DefaultSkinTone = .yellow
  ) -> EmojiMatchItem {
    guard let base = item.familyBase else { return item }
    let available = variants(for: base)
    let explicit = usageStore.explicitPreferredSelection(for: base)
    let preferred: EmojiSelection?
    if let explicit, available.contains(explicit) {
      preferred = explicit
    } else {
      preferred = defaultVariant(for: base, tone: defaultSkinTone)
    }
    guard let preferred else { return item }
    return EmojiMatchItem(
      id: item.id, selection: preferred,
      accessibilityLabel: label(for: preferred), familyBase: base
    )
  }

  func defaultVariant(for base: EmojiSelection, tone: DefaultSkinTone) -> EmojiSelection? {
    guard let modifier = tone.modifier else { return nil }
    func structure(_ value: String) -> [Unicode.Scalar] {
      value.unicodeScalars.filter { $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value) }
    }
    let baseStructure = structure(base.value)
    return variants(for: base).dropFirst()
      .first { variant in
        let modifiers = variant.value.unicodeScalars.filter {
          (0x1F3FB...0x1F3FF).contains($0.value)
        }
        return !modifiers.isEmpty && modifiers.allSatisfy { $0 == modifier }
          && structure(variant.value) == baseStructure
      }
  }

  private func supports(_ value: String) -> Bool {
    if let cached = renderSupport[value] { return cached }
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 30, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: value, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
    )
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
    let supported =
      value.count == 1 && !runs.isEmpty
      && runs.allSatisfy { run in
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        guard glyphs.allSatisfy({ $0 != 0 }),
          positions.allSatisfy({ abs($0.x) < 0.1 && abs($0.y) < 0.1 })
        else { return false }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let runFont = attributes[kCTFontAttributeName] else { return false }
        let name =
          CTFontCopyPostScriptName(unsafeDowncast(runFont as AnyObject, to: CTFont.self)) as String
        return name.contains("AppleColorEmoji")
      }
    renderSupport[value] = supported
    return supported
  }
}

private extension EmojiBrowserCatalog {
  enum Constants {
    static let itemIDPrefix = "catalog"
  }

  static func normalizedValue(_ value: String) -> String {
    String(value.unicodeScalars.filter { $0.value != 0xFE0F }.map(Character.init))
  }

  static func loadNativeSections(
    _ categories: [NativeEmojiCategory], emojis: [Emoji]
  ) -> [EmojiBrowserSection] {
    let exact = Dictionary(grouping: emojis, by: \.value)
    let normalized = Dictionary(grouping: emojis, by: { normalizedValue($0.value) })
    return categories.enumerated()
      .map { index, category in
        EmojiBrowserSection(
          id: category.id, title: LocalizedStringResource(stringLiteral: category.title),
          symbolName: Group.all.indices.contains(index)
            ? Group.all[index].symbolName : "face.smiling",
          items: category.values.map { value in
            let emoji = exact[value]?.first ?? normalized[normalizedValue(value)]?.first
            let id =
              emoji?.id.rawValue
              ?? value.unicodeScalars.map { String($0.value, radix: 16).uppercased() }
              .joined(separator: "-")
            let selection = EmojiSelection(id: id, value: value)
            return EmojiMatchItem(
              id: "\(Constants.itemIDPrefix):\(category.id):\(id)", selection: selection,
              accessibilityLabel: emoji?.localization.name ?? value,
              familyBase: emoji.map { EmojiSelection(id: $0.id.rawValue, value: $0.value) })
          })
      }
  }

  static func loadSections(_ fetchedEmojis: [Emoji]) -> [EmojiBrowserSection] {
    let lookup = Dictionary(grouping: fetchedEmojis, by: \.group)

    return Group.all.compactMap { group -> EmojiBrowserSection? in
      let emojis = group.emojiGroups.flatMap { lookup[$0] ?? [] }
      guard !emojis.isEmpty else {
        return nil
      }

      let items =
        emojis
        .sorted { $0.sortOrder < $1.sortOrder }
        .map { emoji in
          EmojiMatchItem(
            id: "\(Constants.itemIDPrefix):\(group.id):\(emoji.id.rawValue)",
            selection: EmojiSelection(id: emoji.id.rawValue, value: emoji.value),
            accessibilityLabel: emoji.localization.name,
            familyBase: EmojiSelection(id: emoji.id.rawValue, value: emoji.value)
          )
        }

      return EmojiBrowserSection(
        id: group.id,
        title: group.title,
        symbolName: group.symbolName,
        items: items
      )
    }
  }

  static func loadAvailableEmojis() throws -> [Emoji] {
    let emojis = try Emojis.fetch(filter: .apple)
    return emojis.filter { $0.group != .component }
  }
}

private struct Group {
  let emojiGroups: [Emoji.Group]
  let title: LocalizedStringResource
  let symbolName: String

  var id: String { emojiGroups[0].rawValue }

  static let all = [
    Self(
      emojiGroups: [.smileysEmotion, .peopleBody], title: .emojiCategorySmileys,
      symbolName: "face.smiling"),
    Self(emojiGroups: [.animalsNature], title: .emojiCategoryNature, symbolName: "dog"),
    Self(emojiGroups: [.foodDrink], title: .emojiCategoryFood, symbolName: "fork.knife"),
    Self(emojiGroups: [.activities], title: .emojiCategoryActivities, symbolName: "soccerball"),
    Self(emojiGroups: [.travelPlaces], title: .emojiCategoryTravel, symbolName: "car"),
    Self(emojiGroups: [.objects], title: .emojiCategoryObjects, symbolName: "lightbulb"),
    Self(emojiGroups: [.symbols], title: .emojiCategorySymbols, symbolName: "heart"),
    Self(emojiGroups: [.flags], title: .emojiCategoryFlags, symbolName: "flag")
  ]
}
