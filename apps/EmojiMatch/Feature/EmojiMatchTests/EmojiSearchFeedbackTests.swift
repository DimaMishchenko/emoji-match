import Foundation
import Testing

@testable import EmojiMatch

struct EmojiSearchFeedbackTests {
  @Test func pendingAndLoadingAreNotCompletedEmpty() throws {
    try withStore { store in
      for grouped in [false, true] {
        for result in [
          EmojiSearchProviderResult(provider: .duckDuckGo, matches: [], isPending: true),
          EmojiSearchProviderResult(provider: .duckDuckGo, matches: [], isLoading: true)
        ] {
          let content = content(store: store, grouped: grouped, results: [result])
          #expect(content.sections.first?.status == "Searching…")
          #expect(content.navigationLayout.items.isEmpty)
        }
      }
      let completed = content(
        store: store, grouped: false,
        results: [
          .init(provider: .duckDuckGo, matches: [])
        ])
      #expect(completed.sections.first?.status == nil)
    }
  }

  @Test func activeModelDownloadOffersOneCancellationActionInEitherLayout() throws {
    try withStore { store in
      let result = EmojiMultilingualModelFeedback.result(
        .init(provider: .multilingual, matches: []), state: .downloading(progress: 0.5))
      for grouped in [false, true] {
        let content = EmojiMatchContent(
          query: "Ранкова кава", searchStore: EmojiSearchStore(), usageStore: store,
          enabledSearchProviders: [.multilingual], groupSearchResultsByProvider: grouped,
          providerResults: [result], canCancelMultilingualModel: true)
        #expect(content.sections.filter(\.cancelsModel).count == 1)
        #expect(content.sections.allSatisfy { !$0.downloadsModel })
        #expect(content.sections.first?.status?.contains("50%") == true)
      }
    }
  }

  @Test func failuresDescribeTheirSourceAndOfferAccurateRecovery() throws {
    try withStore { store in
      let missing = EmojiSearchIssue(.missingCredential)
      let result = EmojiSearchProviderResult(
        provider: .luna, matches: [], failure: missing.message,
        issue: missing)
      let failed = EmojiMatchContent(
        query: "zzzzzz", searchStore: EmojiSearchStore(), usageStore: store,
        enabledSearchProviders: [.luna], providerResults: [result])
      #expect(failed.sections.first?.status?.contains("Luna") == true)
      #expect(failed.sections.first?.status?.contains("API key") == true)
      #expect(failed.sections.first?.opensSettings == true)
      let offline = EmojiSearchIssue(.offline)
      let web = content(
        store: store, grouped: true,
        results: [
          .init(provider: .duckDuckGo, matches: [], failure: offline.message, issue: offline)
        ])
      #expect(web.sections.first?.title == "Web Search")
      #expect(web.sections.first?.status == offline.message)
      #expect(web.sections.first?.opensSettings == false)
    }
  }

  @Test func configurationIsNotPresentedAsACompletedLookup() throws {
    try withStore { store in
      let off = EmojiMatchContent(
        query: "coffee", searchStore: EmojiSearchStore(), usageStore: store,
        enabledSearchProviders: [])
      #expect(off.sections.first?.status == "Search sources are turned off.")
      #expect(off.sections.first?.opensSettings == true)
      let inapplicable = EmojiMatchContent(
        query: "Ранкова кава", searchStore: EmojiSearchStore(),
        usageStore: store, enabledSearchProviders: [], configuredSearchProviders: [.miniLM])
      #expect(inapplicable.sections.first?.status?.contains("language model") == true)
      #expect(inapplicable.sections.first?.opensSettings == true)
    }
  }

  @Test func validResultsSurviveAnotherSourceFailure() throws {
    try withStore { store in
      let result = EmojiSearchMatch(id: "2615", value: "☕", score: 1, sourceURLs: [])
      let content = EmojiMatchContent(
        query: "zzzzzz", searchStore: EmojiSearchStore(), usageStore: store,
        enabledSearchProviders: [.miniLM, .duckDuckGo],
        providerResults: [
          .init(provider: .miniLM, matches: [result]),
          .init(provider: .duckDuckGo, matches: [], failure: "Offline")
        ])
      #expect(content.navigationLayout.items.map(\.selection.id) == ["2615"])
      #expect(content.sections.first?.status == nil)
    }
  }

  @Test func oversizedInputHasOneClearMessageWithoutSearching() throws {
    try withStore { store in
      let content = EmojiMatchContent(
        query: String(repeating: "a", count: 100_000),
        searchStore: EmojiSearchStore(), usageStore: store,
        enabledSearchProviders: Set(EmojiSearchProvider.allCases),
        groupSearchResultsByProvider: true)
      #expect(content.sections.count == 1)
      #expect(content.sections.first?.status?.contains("too long") == true)
      #expect(content.navigationLayout.items.isEmpty)
    }
  }

  @Test func rawInputLimitsCoverWordsWhitespaceAndCombiningSequences() {
    #expect(EmojiSearchInput.accepts(String(repeating: "a", count: 2_000)))
    #expect(EmojiSearchInput.accepts(String(repeating: "😀", count: 2_000)))
    #expect(!EmojiSearchInput.accepts(String(repeating: "a", count: 2_001)))
    #expect(!EmojiSearchInput.accepts(String(repeating: " ", count: 100_000)))
    #expect(!EmojiSearchInput.accepts(String(repeating: "e\u{301}", count: 1_001)))
    #expect(EmojiSearchInput.normalized("  coffee \n") == "coffee")
  }

  @Test func multilingualInstallationStatesKeepProgressVisible() throws {
    try withStore { store in
      let original = EmojiSearchProviderResult(
        provider: .multilingual, matches: [], failure: "Old failure",
        issue: EmojiSearchIssue(.modelNotInstalled))
      for state in [
        EmojiMultilingualModelStore.State.checking, .downloading(progress: 0.42), .installing,
        .cancelling
      ] {
        let result = EmojiMultilingualModelFeedback.result(original, state: state)
        #expect(result.isLoading)
        #expect(result.failure == nil)
        #expect(result.issue == nil)
        #expect(result.progressMessage != nil)
        #expect(!EmojiMultilingualModelFeedback.canDownload(state))
        for grouped in [false, true] {
          let content = EmojiMatchContent(
            query: "Ранкова кава", searchStore: EmojiSearchStore(), usageStore: store,
            enabledSearchProviders: [.multilingual], groupSearchResultsByProvider: grouped,
            providerResults: [result], canDownloadMultilingualModel: false)
          #expect(content.sections.first?.status == result.progressMessage)
          #expect(content.sections.first?.downloadsModel == false)
          #expect(content.sections.first?.opensSettings == false)
          #expect(content.navigationLayout.items.isEmpty)
        }
      }
    }
  }

  @Test func multilingualProgressPreservesCompletedOtherSourceResults() throws {
    try withStore { store in
      let progress = EmojiMultilingualModelFeedback.result(
        .init(provider: .multilingual, matches: []), state: .downloading(progress: 0.25))
      for grouped in [false, true] {
        let content = EmojiMatchContent(
          query: "Ранкова кава", searchStore: EmojiSearchStore(), usageStore: store,
          enabledSearchProviders: [.multilingual, .luna], groupSearchResultsByProvider: grouped,
          providerResults: [
            progress,
            .init(
              provider: .luna,
              matches: [
                .init(id: "2615", value: "☕", score: 1, sourceURLs: [])
              ])
          ])
        #expect(content.navigationLayout.items.map(\.selection.id) == ["2615"])
        #expect(content.sections.contains { $0.status == progress.progressMessage })
        #expect(!content.sections.contains { $0.downloadsModel || $0.opensSettings })
      }
    }
  }

  @Test func multilingualDownloadRecoverySurvivesOtherSources() throws {
    try withStore { store in
      for state in [EmojiMultilingualModelStore.State.notInstalled, .failed("Install failed")] {
        let missing = EmojiMultilingualModelFeedback.result(
          .init(provider: .multilingual, matches: []), state: state)
        #expect(EmojiMultilingualModelFeedback.canDownload(state))
        for grouped in [false, true] {
          for other in [
            EmojiSearchProviderResult(provider: .luna, matches: [], isLoading: true),
            .init(provider: .luna, matches: [], failure: "Offline"),
            .init(
              provider: .luna,
              matches: [
                .init(id: "2615", value: "☕", score: 1, sourceURLs: [])
              ])
          ] {
            let content = EmojiMatchContent(
              query: "Ранкова кава", searchStore: EmojiSearchStore(), usageStore: store,
              enabledSearchProviders: [.multilingual, .luna], groupSearchResultsByProvider: grouped,
              providerResults: [other, missing], canDownloadMultilingualModel: true)
            #expect(content.sections.filter(\.downloadsModel).count == 1)
            #expect(content.sections.first(where: \.downloadsModel)?.opensSettings == false)
            #expect(content.navigationLayout.items.count == other.matches.count)
          }
        }
      }
    }
  }

  @Test func unavailableModelAndUnrelatedProvidersKeepAccurateFeedback() {
    let result = EmojiSearchProviderResult(provider: .multilingual, matches: [])
    let unavailable = EmojiMultilingualModelFeedback.result(result, state: nil)
    #expect(unavailable.failure == EmojiMultilingualModelFeedback.unavailableMessage)
    #expect(!EmojiMultilingualModelFeedback.canDownload(nil))
    #expect(unavailable.issue == nil)
    let web = EmojiSearchProviderResult(provider: .duckDuckGo, matches: [], failure: "Offline")
    #expect(EmojiMultilingualModelFeedback.result(web, state: .downloading(progress: 0.5)) == web)
    #expect(EmojiMultilingualModelFeedback.result(result, state: .ready) == result)
  }

  @Test func readyRefreshIsLimitedToInstallationAndDoesNotDuplicateValidationSearch() {
    let pending = EmojiSearchProviderResult(provider: .multilingual, matches: [], isPending: true)
    let loading = EmojiSearchProviderResult(provider: .multilingual, matches: [], isLoading: true)
    let completed = EmojiSearchProviderResult(provider: .multilingual, matches: [])
    for result in [pending, loading, completed] {
      #expect(
        !EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .checking, current: .ready, result: result))
      #expect(
        EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .installing, current: .ready, result: result))
      #expect(
        !EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .ready, current: .ready, result: result))
      #expect(
        !EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .installing, current: .notInstalled, result: result))
      #expect(
        !EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .cancelling, current: .ready, result: result))
    }
    for provider in [EmojiSearchProvider.miniLM, .luna, .duckDuckGo] {
      #expect(
        !EmojiMultilingualModelFeedback.shouldRefresh(
          previous: .installing, current: .ready,
          result: .init(provider: provider, matches: [])))
    }
  }

  private func content(
    store: EmojiUsageStore, grouped: Bool, results: [EmojiSearchProviderResult]
  )
    -> EmojiMatchContent
  {
    EmojiMatchContent(
      query: "zzzzzz", searchStore: EmojiSearchStore(), usageStore: store,
      enabledSearchProviders: [.duckDuckGo], groupSearchResultsByProvider: grouped,
      providerResults: results)
  }

  private func withStore(_ operation: (EmojiUsageStore) throws -> Void) throws {
    let suite = "EmojiMatch.SearchFeedback.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try operation(EmojiUsageStore(defaults: defaults, libraryDirectory: directory))
  }
}
