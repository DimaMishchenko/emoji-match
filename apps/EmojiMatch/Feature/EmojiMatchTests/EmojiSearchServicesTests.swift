import Foundation
import Testing

@testable import EmojiMatch

struct EmojiSearchServicesTests {
  @Test func installedMultilingualModelWorksThroughApplicationRouting() async throws {
    let suite = "EmojiMatch.MultilingualComposition.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    let model = try #require(
      EmojiSearchServices(multilingualResourceDirectory: { Self.multilingualResources })
        .models(settings: settings).first { $0.provider == .multilingual }?
        .model
    )
    let query = "Ранкова кава"
    await model.request(query: query, localeIdentifier: "en-US")
    #expect(model.failure == nil)
    let matches = model.matches(for: query, localeIdentifier: "en-US")
    let direct = try EmojiMultilingualSearchProvider(
      resourceDirectory: Self.multilingualResources)
    let expected = try await direct.matches(for: query, localeIdentifier: "uk")
    #expect(matches == expected)
    #expect(matches.count == 6)
  }

  @Test func packagedModelWorksThroughApplicationCompositionWithoutAnOnlineKey() async throws {
    let suite = "EmojiMatch.SearchServicesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    let models = EmojiSearchServices().models(settings: settings)
    #expect(!models.contains { $0.provider == .luna || $0.provider == .duckDuckGo })
    let local = try #require(models.first { $0.provider == .miniLM }?.model)
    await local.request(query: "A paper kite, in a breeze!", localeIdentifier: "en")
    #expect(local.failure == nil)
    let matches = local.matches(for: "A paper kite, in a breeze!", localeIdentifier: "en")
    #expect(matches.count == 6)
    #expect(matches.first?.id == "1FA81")
    #expect(matches.allSatisfy { $0.score.isFinite && $0.sourceURLs.isEmpty })
    #expect(Set(matches.map(\.id)).count == 6)
    await local.request(query: "A paper kite, in a breeze!", localeIdentifier: "en")
    #expect(local.matches(for: "A paper kite, in a breeze!", localeIdentifier: "en") == matches)
    await local.request(query: "", localeIdentifier: "en")
    #expect(local.matches(for: "A paper kite, in a breeze!", localeIdentifier: "en").isEmpty)
  }

  @Test func duckDuckGoNeedsNoSavedCredential() throws {
    let suite = "EmojiMatch.KeylessSearch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    settings.miniLMSearchEnabled = false
    settings.multilingualSearchEnabled = false
    settings.duckDuckGoSearchEnabled = true
    let models = EmojiSearchServices().models(settings: settings)
    #expect(models.first { $0.provider == .miniLM }?.model == nil)
    #expect(models.map(\.provider) == [.duckDuckGo])
    #expect(try EmojiSearchCredentials.keychain(service: suite).read(.duckDuckGo) == nil)
  }

  @Test func disablingSemanticAndOnlineRequiresNoModelResources() throws {
    let suite = "EmojiMatch.SearchDisabledTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    settings.miniLMSearchEnabled = false
    settings.multilingualSearchEnabled = false
    let models = EmojiSearchServices().models(settings: settings)
    #expect(models.first { $0.provider == .miniLM }?.model == nil)
    #expect(!models.contains { $0.provider == .luna || $0.provider == .duckDuckGo })
  }

  @Test func webRerankingReceivesAllTenResultCandidatesAndOriginalQuery() async throws {
    try await withWebSettings { settings in
      let calls = CandidateCalls()
      let services = EmojiSearchServices(
        webTransport: Self.webResponse,
        candidateRanking: { query, ids in
          await calls.record(query, ids: ids)
          return Array(ids.reversed())
        })
      let online = try #require(
        services.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
      await online.request(query: "birthday", localeIdentifier: "en")
      #expect(online.failure == nil)
      let requests = await calls.requests
      #expect(requests.count == 1)
      #expect(requests.first?.0 == "birthday")
      #expect(requests.first?.1.count == 10)
      let result = online.matches(for: "birthday", localeIdentifier: "en")
      #expect(result.count == 6)
      #expect(result.allSatisfy { !$0.sourceURLs.isEmpty })
      #expect(Set(result.map(\.id)).count == 6)
    }
  }

  @Test func protectedQueriesAndDisabledMeaningSearchDoNotInvokeReranking() async throws {
    try await withWebSettings { settings in
      let calls = CandidateCalls()
      let services = EmojiSearchServices(
        webTransport: Self.webResponse,
        candidateRanking: { query, ids in
          await calls.record(query, ids: ids)
          return Array(ids.reversed())
        })
      for query in ["camera off", "train delayed", "I need some space"] {
        let online = try #require(
          services.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
        await online.request(query: query, localeIdentifier: "en")
        #expect(online.failure == nil)
        #expect(online.matches(for: query, localeIdentifier: "en").first?.id == "1F61C")
      }
      settings.miniLMSearchEnabled = false
      settings.multilingualSearchEnabled = false
      let online = try #require(
        services.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
      await online.request(query: "birthday", localeIdentifier: "en")
      #expect(online.failure == nil)
      #expect(online.matches(for: "birthday", localeIdentifier: "en").first?.id == "1F61C")
      #expect(await calls.requests.isEmpty)
    }
  }

  @Test func rankingFailurePreservesWebResultsAndCancellationStaysCancelled() async throws {
    try await withWebSettings { settings in
      let services = EmojiSearchServices(
        webTransport: Self.webResponse,
        candidateRanking: { _, _ in throw URLError(.cannotDecodeContentData) })
      let online = try #require(
        services.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
      await online.request(query: "birthday", localeIdentifier: "en")
      #expect(online.failure == nil)
      #expect(online.matches(for: "birthday", localeIdentifier: "en").count == 6)
      let cancelled = EmojiSearchServices(
        webTransport: Self.webResponse, candidateRanking: { _, _ in throw CancellationError() })
      let cancelledModel = try #require(
        cancelled.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
      await cancelledModel.request(query: "birthday", localeIdentifier: "en")
      #expect(cancelledModel.matches(for: "birthday", localeIdentifier: "en").isEmpty)
      #expect(cancelledModel.failure == nil)
    }
  }

  @Test func enabledProvidersAreIndependentAndOnlineFailureDoesNotSuppressWeb() async throws {
    try await withWebSettings { settings in
      settings.lunaSearchEnabled = true
      let calls = CandidateCalls()
      let services = EmojiSearchServices(
        webTransport: Self.webResponse, candidateRanking: { _, ids in ids },
        lunaSearch: { query, _ in
          await calls.record(query, ids: [])
          throw URLError(.userAuthenticationRequired)
        })
      let models = services.models(settings: settings)
      #expect(models.map(\.provider) == [.miniLM, .multilingual, .luna, .duckDuckGo])
      let online = models.filter { $0.provider == .luna || $0.provider == .duckDuckGo }
      await withTaskGroup(of: Void.self) { group in
        for model in online.map(\.model) {
          group.addTask {
            await model.request(query: "birthday", localeIdentifier: "en")
          }
        }
      }
      let luna = try #require(online.first { $0.provider == .luna }?.model)
      let web = try #require(online.first { $0.provider == .duckDuckGo }?.model)
      #expect(luna.failure != nil)
      #expect(web.failure == nil)
      #expect(web.matches(for: "birthday", localeIdentifier: "en").count == 6)
      #expect(await calls.requests.count == 1)
      settings.lunaSearchEnabled = false
      settings.duckDuckGoSearchEnabled = false
      settings.miniLMSearchEnabled = false
      settings.multilingualSearchEnabled = false
      settings.lexicalSearchEnabled = false
      #expect(services.models(settings: settings).isEmpty)
      #expect(await calls.requests.count == 1)
    }
  }

  @Test func ddgAloneRejectsSlogansAndRanksDirectPhoneEvidenceFirst() async throws {
    try await withWebSettings { settings in
      settings.miniLMSearchEnabled = false
      settings.multilingualSearchEnabled = false
      let calls = CandidateCalls()
      let services = EmojiSearchServices(
        webTransport: { request in
          let url = try #require(request.url)
          let response = try #require(
            HTTPURLResponse(
              url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
          let html = """
            <html><body>
            <div class="result"><a class="result__a" href="https://one.example/apple">Apple iPhone Emoji List</a>
            <div class="result__snippet">Apple Emoji is a set for iOS. 🤝 Copy, paste, communicate!</div></div>
            <div class="result"><a class="result__a" href="https://two.example/iphone">iPhone Emojis | ⏲ | Copy</a>
            <div class="result__snippet">iPhone emojis 📱 📠</div></div>
            </body></html>
            """
          return (Data(html.utf8), response)
        },
        candidateRanking: { query, ids in
          await calls.record(query, ids: ids)
          return ids
        })
      let model = try #require(
        services.models(settings: settings).first { $0.provider == .duckDuckGo }?.model)
      await model.request(query: "iphone", localeIdentifier: "en-US")
      #expect(model.failure == nil)
      #expect(
        model.matches(for: "iphone", localeIdentifier: "en-US").map(\.value) == ["📱", "📠", "⏲️"])
      #expect(await calls.requests.isEmpty)
    }
  }

  @Test func bothEnabledModelsOnlyAnswerTheirOwnQueryLanguage() async throws {
    let suite = "EmojiMatch.LanguageRouting.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    let models = EmojiSearchServices(multilingualResourceDirectory: { Self.multilingualResources })
      .models(settings: settings)
    let miniLM = try #require(models.first { $0.provider == .miniLM }?.model)
    let e5 = try #require(models.first { $0.provider == .multilingual }?.model)
    await miniLM.request(query: "Ранкова кава", localeIdentifier: "en-US")
    #expect(miniLM.failure == nil)
    #expect(miniLM.matches(for: "Ранкова кава", localeIdentifier: "en-US").isEmpty)
    await e5.request(query: "good morning", localeIdentifier: "uk-UA")
    #expect(e5.failure == nil)
    #expect(e5.matches(for: "good morning", localeIdentifier: "uk-UA").isEmpty)
    await miniLM.request(query: "good morning", localeIdentifier: "uk-UA")
    #expect(miniLM.failure == nil)
    #expect(miniLM.matches(for: "good morning", localeIdentifier: "uk-UA").count == 6)
    await e5.request(query: "Ранкова кава", localeIdentifier: "en-US")
    #expect(e5.failure == nil)
    #expect(e5.matches(for: "Ранкова кава", localeIdentifier: "en-US").count == 6)
  }

  @Test func credentialReadFailuresRemainDistinctAndNeverDispatch() async throws {
    try await withWebSettings { settings in
      settings.lunaSearchEnabled = true
      for unreadable in [false, true] {
        let services = EmojiSearchServices(
          lunaTransport: { _ in
            Issue.record("Unexpected credentialless dispatch")
            throw CancellationError()
          },
          lunaCredential: { _ in
            if unreadable { throw URLError(.noPermissionsToReadFile) }
            return nil
          })
        let model = try #require(
          services.models(settings: settings).first { $0.provider == .luna }?.model)
        await model.request(query: "cat", localeIdentifier: "en")
        #expect(model.issue?.kind == (unreadable ? .unreadableCredential : .missingCredential))
        #expect(model.issue?.recovery == .settings)
      }
    }
  }

  @Test(arguments: [401, 403])
  func rejectedCredentialBlocksOtherPickersUntilActualKeyChange(status: Int) async throws {
    try await withWebSettings { settings in
      settings.lunaSearchEnabled = true
      let credential = LunaCredentialFixture()
      let requests = CandidateCalls()
      let services = EmojiSearchServices(
        lunaTransport: { request in
          await requests.record(request.value(forHTTPHeaderField: "Authorization") ?? "", ids: [])
          let url = try #require(request.url)
          let response = try #require(
            HTTPURLResponse(
              url: url, statusCode: status, httpVersion: nil, headerFields: nil))
          return (Data("private server message".utf8), response)
        },
        lunaCredential: { _ in credential.key },
        lunaGate: EmojiLunaDispatchGate(minimumSpacing: 0))
      for query in ["cat", "dog", "bird"] {
        let model = try #require(
          services.models(settings: settings).first { $0.provider == .luna }?.model)
        await model.request(query: query, localeIdentifier: "en")
        #expect(model.issue?.kind == .rejectedCredential)
      }
      #expect(await requests.requests.count == 1)
      await services.credentialsDidChange()
      let resetModel = try #require(
        services.models(settings: settings).first { $0.provider == .luna }?.model)
      await resetModel.request(query: "after explicit save", localeIdentifier: "en")
      #expect(await requests.requests.count == 2)
      credential.key = "synthetic-changed-key"
      let model = try #require(
        services.models(settings: settings).first { $0.provider == .luna }?.model)
      await model.request(query: "fish", localeIdentifier: "en")
      #expect(await requests.requests.count == 3)
      #expect(await requests.requests.last?.0 == "Bearer synthetic-changed-key")
    }
  }

  @Test func serviceRateLimitBlocksNewPickerAndPreservesRetryDate() async throws {
    try await withWebSettings { settings in
      settings.lunaSearchEnabled = true
      let requests = CandidateCalls()
      let instant = Date(timeIntervalSince1970: 1000)
      let services = EmojiSearchServices(
        lunaTransport: { request in
          await requests.record("dispatch", ids: [])
          let url = try #require(request.url)
          let response = try #require(
            HTTPURLResponse(
              url: url, statusCode: 429, httpVersion: nil,
              headerFields: ["Retry-After": "3600"]))
          return (Data(), response)
        },
        lunaCredential: { _ in "synthetic-test-key" },
        lunaGate: EmojiLunaDispatchGate(now: { instant }), now: { instant })
      for query in ["cat", "dog"] {
        if query == "dog" { await services.credentialsDidChange() }
        let model = try #require(
          services.models(settings: settings).first { $0.provider == .luna }?.model)
        await model.request(query: query, localeIdentifier: "en")
        #expect(
          model.issue == EmojiSearchIssue(.rateLimited, retryAt: instant.addingTimeInterval(3600)))
      }
      #expect(await requests.requests.count == 1)
    }
  }

  nonisolated private static var multilingualResources: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "ModelResources/Multilingual")
  }

  @Test func absentMultilingualInstallationOffersSettingsWithoutDownload() async throws {
    let suite = "EmojiMatch.AbsentModel.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    let model = try #require(
      EmojiSearchServices().models(settings: settings)
        .first { $0.provider == .multilingual }?
        .model)
    await model.request(query: "Ранкова кава", localeIdentifier: "uk")
    #expect(model.issue?.kind == .modelNotInstalled)
    #expect(model.issue?.recovery == .settings)
    #expect(model.matches(for: "Ранкова кава", localeIdentifier: "uk").isEmpty)
  }

  private final class LunaCredentialFixture {
    var key = "synthetic-initial-key"
  }

  private actor CandidateCalls {
    private(set) var requests: [(String, [String])] = []

    func record(_ query: String, ids: [String]) { requests.append((query, ids)) }
  }

  private func withWebSettings(_ operation: (AppSettings) async throws -> Void) async throws {
    let suite = "EmojiMatch.WebComposition.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, prefix: "settings")
    settings.duckDuckGoSearchEnabled = true
    try await operation(settings)
  }

  nonisolated private static func webResponse(
    _ request: URLRequest
  ) async throws -> (
    Data, HTTPURLResponse
  ) {
    let glyphs = ["😜", "🎈", "🎉", "🥳", "😛", "👯", "🎂", "🎁", "❤️", "🕯️"]
    let results = glyphs.enumerated()
      .map { index, glyph in
        """
        <div class="result"><a class="result__a" href="https://example\(index).com/topic">\(glyph)</a>
        <div class="result__snippet">Birthday suggestions \(glyph)</div></div>
        """
      }
      .joined()
    let url = try #require(request.url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    return (Data("<html><body>\(results)</body></html>".utf8), response)
  }
}
