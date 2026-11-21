import Carbon.HIToolbox
import Foundation
import Observation

enum DefaultSkinTone: String, CaseIterable, Identifiable {
  case yellow, light, mediumLight, medium, mediumDark, dark

  var id: Self { self }

  var modifier: Unicode.Scalar? {
    switch self {
    case .yellow: nil
    case .light: "\u{1F3FB}"
    case .mediumLight: "\u{1F3FC}"
    case .medium: "\u{1F3FD}"
    case .mediumDark: "\u{1F3FE}"
    case .dark: "\u{1F3FF}"
    }
  }

  var hand: String { "✋" + (modifier.map(String.init) ?? "") }

  var label: String {
    switch self {
    case .yellow: String(localized: "Yellow (default)")
    case .light: String(localized: "Light skin tone")
    case .mediumLight: String(localized: "Medium-light skin tone")
    case .medium: String(localized: "Medium skin tone")
    case .mediumDark: String(localized: "Medium-dark skin tone")
    case .dark: String(localized: "Dark skin tone")
    }
  }
}

@Observable
final class AppSettings {
  struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    var displayKey: String = "Space"

    static let defaultOpen = Shortcut(
      keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | controlKey)
    )

    var label: String {
      [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        .filter { carbonModifiers & UInt32($0.0) != 0 }.map(\.1).joined() + displayKey
    }
  }

  private let defaults: UserDefaults
  private let prefix: String
  var registrationError: String?
  var openShortcut: Shortcut {
    didSet {
      if let data = try? JSONEncoder().encode(openShortcut) {
        defaults.set(data, forKey: prefix + ".shortcut")
      }
    }
  }
  var defaultSkinTone: DefaultSkinTone {
    didSet { defaults.set(defaultSkinTone.rawValue, forKey: prefix + ".defaultSkinTone") }
  }
  var prefillSelectedText: Bool {
    didSet { defaults.set(prefillSelectedText, forKey: prefix + ".prefill") }
  }
  var lexicalSearchEnabled: Bool {
    didSet { defaults.set(lexicalSearchEnabled, forKey: prefix + ".lexicalSearchEnabled") }
  }
  var miniLMSearchEnabled: Bool {
    didSet { defaults.set(miniLMSearchEnabled, forKey: prefix + ".miniLMSearchEnabled") }
  }
  var multilingualSearchEnabled: Bool {
    didSet {
      defaults.set(multilingualSearchEnabled, forKey: prefix + ".multilingualSearchEnabled")
    }
  }
  var lunaSearchEnabled: Bool {
    didSet { defaults.set(lunaSearchEnabled, forKey: prefix + ".lunaSearchEnabled") }
  }
  var duckDuckGoSearchEnabled: Bool {
    didSet { defaults.set(duckDuckGoSearchEnabled, forKey: prefix + ".duckDuckGoSearchEnabled") }
  }
  var groupSearchResultsByProvider: Bool {
    didSet {
      defaults.set(groupSearchResultsByProvider, forKey: prefix + ".groupSearchResultsByProvider")
    }
  }

  var enabledSearchProviders: Set<EmojiSearchProvider> {
    var providers: Set<EmojiSearchProvider> = []
    if lexicalSearchEnabled { providers.insert(.lexical) }
    if miniLMSearchEnabled { providers.insert(.miniLM) }
    if multilingualSearchEnabled { providers.insert(.multilingual) }
    if lunaSearchEnabled { providers.insert(.luna) }
    if duckDuckGoSearchEnabled { providers.insert(.duckDuckGo) }
    return providers
  }

  let searchCredentialService: String

  init(
    defaults: UserDefaults = .standard, prefix: String = "com.dimasike.EmojiMatch.settings",
    credentialService: String? = nil
  ) {
    self.defaults = defaults
    self.prefix = prefix
    self.searchCredentialService = credentialService ?? prefix + ".search"
    openShortcut =
      defaults.data(forKey: prefix + ".shortcut")
      .flatMap {
        try? JSONDecoder().decode(Shortcut.self, from: $0)
      } ?? .defaultOpen
    defaultSkinTone =
      defaults.string(forKey: prefix + ".defaultSkinTone")
      .flatMap(DefaultSkinTone.init(rawValue:)) ?? .yellow
    prefillSelectedText = defaults.object(forKey: prefix + ".prefill") as? Bool ?? true
    lexicalSearchEnabled =
      defaults.object(forKey: prefix + ".lexicalSearchEnabled") as? Bool ?? true
    miniLMSearchEnabled =
      defaults.object(forKey: prefix + ".miniLMSearchEnabled") as? Bool ?? true
    multilingualSearchEnabled =
      defaults.object(forKey: prefix + ".multilingualSearchEnabled") as? Bool ?? true
    lunaSearchEnabled =
      defaults.object(forKey: prefix + ".lunaSearchEnabled") as? Bool ?? false
    duckDuckGoSearchEnabled =
      defaults.object(forKey: prefix + ".duckDuckGoSearchEnabled") as? Bool ?? false
    groupSearchResultsByProvider =
      defaults.object(forKey: prefix + ".groupSearchResultsByProvider") as? Bool ?? false
  }
}
