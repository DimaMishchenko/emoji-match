import Emojis
import Foundation

final class EmojiSearchServices {
  typealias Search = @Sendable (String, String) async throws -> [EmojiSearchMatch]
  typealias CandidateRanking = @Sendable (String, [String]) async throws -> [String]

  private let catalog = SearchCatalog()
  private let localSearch: SemanticProviderCache
  private let injectedWebTransport: DuckDuckGoEmojiSearchProvider.Transport?
  private let candidateRanking: CandidateRanking
  private let injectedLunaSearch: Search?
  private let persistentWebData: Bool
  private let lunaTransport: EmojiLunaSearchProvider.Transport
  private let lunaCredential: @MainActor @Sendable (String) throws -> String?
  private let lunaGate: EmojiLunaDispatchGate
  private let now: @Sendable () -> Date
  private var webBrowser: EmojiWebSearchBrowser?

  init(
    bundle: Bundle = .main,
    webTransport: DuckDuckGoEmojiSearchProvider.Transport? = nil,
    candidateRanking: CandidateRanking? = nil,
    persistentWebData: Bool = true,
    lunaSearch: Search? = nil,
    lunaTransport: @escaping EmojiLunaSearchProvider.Transport = {
      try await EmojiLunaSearchProvider.liveTransport($0)
    },
    lunaCredential: @escaping @MainActor @Sendable (String) throws -> String? = {
      try EmojiSearchCredentials.keychain(service: $0).read(.luna)
    },
    lunaGate: EmojiLunaDispatchGate = EmojiLunaDispatchGate(),
    now: @escaping @Sendable () -> Date = { Date() },
    multilingualResourceDirectory: (@Sendable () async throws -> URL)? = nil
  ) {
    let localSearch = SemanticProviderCache(
      resourceDirectory: bundle.resourceURL,
      multilingualResourceDirectory: multilingualResourceDirectory
        ?? { throw EmojiSearchIssue(.modelNotInstalled) })
    self.localSearch = localSearch
    self.injectedWebTransport = webTransport
    self.candidateRanking =
      candidateRanking ?? { query, ids in
        try await localSearch.rankedEnglishIDs(for: query, candidateIDs: ids)
      }
    self.persistentWebData = persistentWebData
    self.injectedLunaSearch = lunaSearch
    self.lunaTransport = lunaTransport
    self.lunaCredential = lunaCredential
    self.lunaGate = lunaGate
    self.now = now
  }

  func credentialsDidChange() async {
    await lunaGate.credentialsDidChange()
  }

  func releaseEnglishResources() async {
    await localSearch.releaseEnglishResources()
  }

  func releaseMultilingualResources() async {
    await localSearch.releaseMultilingualResources()
  }

  func models(settings: AppSettings) -> [EmojiSearchProviderModel] {
    EmojiSearchProvider.allCases.compactMap { provider in
      guard settings.enabledSearchProviders.contains(provider), provider != .lexical else {
        return nil
      }
      let model: EmojiAsyncSearchModel
      switch provider {
      case .lexical:
        return nil
      case .miniLM, .multilingual:
        model = EmojiAsyncSearchModel(
          search: { [localSearch] query, locale in
            do {
              return try await localSearch.matches(
                for: query, localeIdentifier: locale, provider: provider)
            } catch {
              try Task.checkCancellation()
              if error is CancellationError { throw error }
              if let issue = error as? EmojiSearchIssue { throw issue }
              throw EmojiSearchIssue(.modelUnavailable)
            }
          }, debounce: .milliseconds(50),
          failureMessage: "Model unavailable.")
      case .duckDuckGo:
        model = webModel(usesMiniLM: settings.miniLMSearchEnabled)
      case .luna:
        if let injectedLunaSearch {
          model = EmojiAsyncSearchModel(search: injectedLunaSearch)
        } else {
          model = lunaModel(settings: settings)
        }
      }
      return EmojiSearchProviderModel(provider: provider, model: model)
    }
  }

  private func webModel(usesMiniLM: Bool) -> EmojiAsyncSearchModel {
    let transport = webTransport()
    let web = DuckDuckGoEmojiSearchProvider { request in try await transport(request) }
    let candidateRanking = candidateRanking
    let catalog = catalog
    return EmojiAsyncSearchModel(
      search: { query, locale in
        let ranking = EmojiWebSearchRanking(mapper: try await catalog.mapping())
        try Task.checkCancellation()
        let documents = try await web.documents(for: query, localeIdentifier: locale)
        let candidates = ranking.matches(in: documents, limit: 1932, query: query)
        guard usesMiniLM, candidates.count > 1,
          EmojiWebSearchReranking.usesSemanticOrdering(for: query)
        else { return Array(candidates.prefix(6)) }
        do {
          let semanticIDs = try await candidateRanking(query, candidates.map(\.id))
          try Task.checkCancellation()
          return EmojiWebSearchReranking.matches(web: candidates, semanticIDs: semanticIDs)
        } catch {
          try Task.checkCancellation()
          if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
          }
          return Array(candidates.prefix(6))
        }
      },
      failureMessage:
        "Search temporarily unavailable. Try again later."
    )
  }

  private func lunaModel(settings: AppSettings) -> EmojiAsyncSearchModel {
    let service = settings.searchCredentialService
    let readCredential = lunaCredential
    let transport = lunaTransport
    let gate = lunaGate
    let catalog = catalog
    let currentTime: @Sendable () -> Date = self.now
    return EmojiAsyncSearchModel(search: { query, locale in
      let savedKey: String?
      do {
        savedKey = try await MainActor.run { try readCredential(service) }
      } catch {
        throw EmojiSearchIssue(.unreadableCredential)
      }
      guard let savedKey, !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw EmojiSearchIssue(.missingCredential)
      }
      let mapper: EmojiCatalogMapping
      do {
        mapper = try await catalog.mapping()
      } catch {
        throw EmojiSearchIssue(.modelUnavailable)
      }
      let luna = EmojiLunaSearchProvider(
        apiKey: savedKey, mapper: mapper,
        transport: { request in
          let admission = try await gate.waitToDispatch(credential: savedKey)
          try Task.checkCancellation()
          let result = try await transport(request)
          await gate.record(result.1, admission: admission)
          return result
        }, now: currentTime)
      return try await luna.matches(for: query, localeIdentifier: locale)
    })
  }

  private func webTransport() -> DuckDuckGoEmojiSearchProvider.Transport {
    if let injectedWebTransport {
      return { request in try await injectedWebTransport(request) }
    }
    let browser: EmojiWebSearchBrowser
    if let webBrowser {
      browser = webBrowser
    } else {
      browser =
        persistentWebData
        ? EmojiWebSearchBrowser() : EmojiWebSearchBrowser(profileIdentifier: nil)
      webBrowser = browser
    }
    return { request in try await browser.data(for: request) }
  }
}

private actor SemanticProviderCache {
  private let resourceDirectory: URL?
  private var provider: EmojiMiniLMSearchProvider?
  private var multilingual: EmojiMultilingualSearchProvider?
  private let multilingualResourceDirectory: @Sendable () async throws -> URL

  init(
    resourceDirectory: URL?,
    multilingualResourceDirectory: @escaping @Sendable () async throws -> URL
  ) {
    self.resourceDirectory = resourceDirectory
    self.multilingualResourceDirectory = multilingualResourceDirectory
  }

  func releaseEnglishResources() async {
    let previous = provider
    provider = nil
    await previous?.releaseResources()
  }

  func releaseMultilingualResources() async {
    let previous = multilingual
    multilingual = nil
    await previous?.releaseResources()
  }

  func matches(
    for query: String, localeIdentifier: String, provider source: EmojiSearchProvider
  ) async throws -> [EmojiSearchMatch] {
    try Task.checkCancellation()
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    guard EmojiSemanticLanguageRouter.encoder(for: query) == source else { return [] }
    if source == .multilingual {
      if multilingual == nil {
        let directory = try await multilingualResourceDirectory()
        try Task.checkCancellation()
        multilingual = try EmojiMultilingualSearchProvider(resourceDirectory: directory)
      }
      guard let multilingual else { throw ModelError.missingResources }
      return try await multilingual.matches(for: query, localeIdentifier: localeIdentifier)
    }
    if provider == nil {
      guard let resourceDirectory else { throw ModelError.missingResources }
      provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    }
    guard let provider else { throw ModelError.missingResources }
    return try await provider.matches(for: query, localeIdentifier: localeIdentifier)
  }

  func rankedEnglishIDs(for query: String, candidateIDs: [String]) async throws -> [String] {
    try Task.checkCancellation()
    if provider == nil {
      guard let resourceDirectory else { throw ModelError.missingResources }
      provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    }
    guard let provider else { throw ModelError.missingResources }
    return try await provider.rankedIDs(for: query, candidateIDs: candidateIDs)
  }

  private enum ModelError: Error {
    case missingResources
  }
}

private actor SearchCatalog {
  private var mapper: EmojiCatalogMapping?

  func mapping() throws -> EmojiCatalogMapping {
    try Task.checkCancellation()
    if let mapper { return mapper }
    let mapper = try EmojiCatalogMapping(emojis: Emojis.fetch())
    try Task.checkCancellation()
    self.mapper = mapper
    return mapper
  }
}
