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

  init(defaults: UserDefaults = .standard, prefix: String = "com.dimasike.EmojiMatch.settings") {
    self.defaults = defaults
    self.prefix = prefix
    openShortcut =
      defaults.data(forKey: prefix + ".shortcut")
      .flatMap {
        try? JSONDecoder().decode(Shortcut.self, from: $0)
      } ?? .defaultOpen
    defaultSkinTone =
      defaults.string(forKey: prefix + ".defaultSkinTone")
      .flatMap(DefaultSkinTone.init(rawValue:)) ?? .yellow
    prefillSelectedText = defaults.object(forKey: prefix + ".prefill") as? Bool ?? true
  }
}
