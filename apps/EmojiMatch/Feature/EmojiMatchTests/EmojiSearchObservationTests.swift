import Emojis
import Observation
import Synchronization
import Testing

@testable import EmojiMatch

@Suite struct EmojiSearchObservationTests {
  @Test func cachedResultsRemainObservableWhenTheIndexReloads() {
    let index = SearchIndex(
      availableLocaleIdentifiers: ["en"],
      entries: [
        SearchIndex.Entry(
          id: .init(rawValue: "1F600"), value: "😀", skinToneSupport: .none,
          skinToneVariants: [],
          localizations: [
            Emoji.Localization(
              localeIdentifier: "en", name: "grinning face", searchTokens: ["face"])
          ])
      ])
    let fixture = SearchIndexFixture(index)
    let store = EmojiSearchStore(loadSearchIndex: { fixture.index })
    #expect(store.results(for: "face").count == 1)
    let changed = Mutex(false)
    withObservationTracking {
      #expect(store.results(for: "face").count == 1)
    } onChange: {
      changed.withLock { $0 = true }
    }
    fixture.index = SearchIndex(availableLocaleIdentifiers: ["en"], entries: [])
    store.reload()
    #expect(changed.withLock { $0 })
    #expect(store.results(for: "face").isEmpty)
  }
}

private final class SearchIndexFixture {
  var index: SearchIndex

  init(_ index: SearchIndex) {
    self.index = index
  }
}
