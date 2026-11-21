import Foundation
import Testing

@testable import EmojiMatch

struct AppSettingsTests {
  @Test func localSourcesDefaultOnAndOnlineSourcesDefaultOff() throws {
    try withDefaults { defaults in
      let settings = AppSettings(defaults: defaults, prefix: "settings")
      #expect(settings.lexicalSearchEnabled)
      #expect(settings.miniLMSearchEnabled)
      #expect(settings.multilingualSearchEnabled)
      #expect(!settings.lunaSearchEnabled)
      #expect(!settings.duckDuckGoSearchEnabled)
      #expect(!settings.groupSearchResultsByProvider)
      #expect(settings.enabledSearchProviders == [.lexical, .miniLM, .multilingual])
      #expect(settings.searchCredentialService == "settings.search")
      #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("settings.") })
    }
  }

  @Test func allSourcesPersistIndependentlyFromLayout() throws {
    try withDefaults { defaults in
      let settings = AppSettings(defaults: defaults, prefix: "settings")
      settings.lexicalSearchEnabled = false
      settings.miniLMSearchEnabled = false
      settings.multilingualSearchEnabled = true
      settings.lunaSearchEnabled = true
      settings.duckDuckGoSearchEnabled = true
      settings.groupSearchResultsByProvider = true
      let restored = AppSettings(defaults: defaults, prefix: "settings")
      #expect(!restored.lexicalSearchEnabled)
      #expect(!restored.miniLMSearchEnabled)
      #expect(restored.multilingualSearchEnabled)
      #expect(restored.lunaSearchEnabled)
      #expect(restored.duckDuckGoSearchEnabled)
      #expect(restored.groupSearchResultsByProvider)
      #expect(restored.enabledSearchProviders == [.multilingual, .luna, .duckDuckGo])
      restored.groupSearchResultsByProvider = false
      #expect(restored.enabledSearchProviders == settings.enabledSearchProviders)
      #expect(!AppSettings(defaults: defaults, prefix: "settings").groupSearchResultsByProvider)
    }
  }

  @Test func everySourceCanBeEnabledAloneOrAllTogetherOrAllDisabled() throws {
    try withDefaults { defaults in
      let settings = AppSettings(defaults: defaults, prefix: "settings")
      for mask in 0..<32 {
        settings.lexicalSearchEnabled = mask & 1 != 0
        settings.miniLMSearchEnabled = mask & 2 != 0
        settings.multilingualSearchEnabled = mask & 4 != 0
        settings.lunaSearchEnabled = mask & 8 != 0
        settings.duckDuckGoSearchEnabled = mask & 16 != 0
        var expected: Set<EmojiSearchProvider> = []
        if mask & 1 != 0 { expected.insert(.lexical) }
        if mask & 2 != 0 { expected.insert(.miniLM) }
        if mask & 4 != 0 { expected.insert(.multilingual) }
        if mask & 8 != 0 { expected.insert(.luna) }
        if mask & 16 != 0 { expected.insert(.duckDuckGo) }
        #expect(settings.enabledSearchProviders == expected)
        #expect(
          AppSettings(defaults: defaults, prefix: "settings").enabledSearchProviders == expected)
      }
    }
  }

  private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "EmojiMatch.SearchSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
  }

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
