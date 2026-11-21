import Foundation

nonisolated enum EmojiSearchProvider: String, CaseIterable, Identifiable, Sendable {
  case lexical, miniLM, multilingual, luna, duckDuckGo

  var id: Self { self }

  var title: String {
    switch self {
    case .lexical: "Names & Keywords"
    case .miniLM: "MiniLM (English)"
    case .multilingual: "E5 (Multilingual)"
    case .luna: "Luna (OpenAI)"
    case .duckDuckGo: "Web Search"
    }
  }
}

nonisolated struct EmojiSearchProviderResult: Equatable, Sendable {
  let provider: EmojiSearchProvider
  let matches: [EmojiSearchMatch]
  var isLoading = false
  var failure: String?
  var isPending = false
  var issue: EmojiSearchIssue?
  var progressMessage: String?
}

struct EmojiSearchProviderModel: Identifiable {
  let provider: EmojiSearchProvider
  let model: EmojiAsyncSearchModel

  var id: EmojiSearchProvider { provider }
}
