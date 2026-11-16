import Carbon.HIToolbox
import Foundation
import Observation

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
    prefillSelectedText = defaults.object(forKey: prefix + ".prefill") as? Bool ?? true
  }
}
