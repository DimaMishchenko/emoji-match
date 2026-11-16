import Foundation
import Testing

@testable import EmojiMatch

struct AppSettingsTests {
  @Test func persistsShortcutAndPrefill() throws {
    let suite = "EmojiMatch.SettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    #expect(settings.prefillSelectedText)
    let shortcut = AppSettings.Shortcut(keyCode: 14, carbonModifiers: 768, displayKey: "E")
    settings.openShortcut = shortcut
    settings.prefillSelectedText = false
    let restored = AppSettings(defaults: defaults, prefix: "settings")
    #expect(restored.openShortcut == shortcut)
    #expect(!restored.prefillSelectedText)
  }

  @Test func corruptShortcutUsesDefaultWithoutChangingHistory() throws {
    let suite = "EmojiMatch.SettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data([1, 2, 3]), forKey: "settings.shortcut")
    defaults.set("kept", forKey: "other.history")
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    #expect(settings.openShortcut == .defaultOpen)
    #expect(defaults.string(forKey: "other.history") == "kept")
  }
}
