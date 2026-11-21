import Emojis
import Foundation

nonisolated struct EmojiWebSearchDocument: Equatable, Sendable {
  let url: URL
  let title: String
  let text: String

  init(url: URL, title: String, text: String) {
    self.url = url
    self.title = title
    self.text = text
  }
}

nonisolated struct EmojiWebSearchRanking: Sendable {
  private enum Relevance: Int, Comparable {
    case titleSample, contextualList, direct

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  private struct Evidence {
    let relevance: Relevance
    let candidate: EmojiSearchMatch
    let position: Int
    let occurrence: Int
    var votes: [String: Double]
    var urls: [URL]

    var score: Double { votes.values.sorted(by: >).reduce(0, +) }
  }

  private let mapper: EmojiCatalogMapping

  init(emojis: [Emoji]) {
    mapper = EmojiCatalogMapping(emojis: emojis)
  }

  init(mapper: EmojiCatalogMapping) { self.mapper = mapper }

  func matches(
    in documents: [EmojiWebSearchDocument], limit: Int = 6, query: String
  ) -> [EmojiSearchMatch] {
    guard limit > 0 else { return [] }
    let queryTerms = Self.terms(query)
    var evidence: [String: Evidence] = [:]
    var occurrence = 0
    for (index, document) in documents.prefix(10).enumerated() {
      let position = index + 1
      guard let domain = EmojiWebSourceIdentity.host(document.url) else { continue }
      for (text, relevance) in blocks(in: document, queryTerms: queryTerms) {
        var followsDanglingJoiner = false
        for character in text {
          defer { occurrence += 1 }
          let glyph = String(character)
          let followsJoiner = followsDanglingJoiner
          followsDanglingJoiner = glyph.unicodeScalars.last?.value == 0x200D
          guard !followsJoiner,
            glyph.unicodeScalars.first?.value != 0x200D,
            glyph.unicodeScalars.last?.value != 0x200D,
            let candidate = mapper.match(for: glyph)
          else { continue }
          let existing = evidence[candidate.id]
          if let existing, existing.relevance > relevance { continue }
          var item =
            existing.flatMap { $0.relevance == relevance ? $0 : nil }
            ?? Evidence(
              relevance: relevance, candidate: candidate, position: position,
              occurrence: occurrence, votes: [:], urls: [])
          item.votes[domain] = max(item.votes[domain] ?? 0, 1 / Double(position))
          if !item.urls.contains(document.url) { item.urls.append(document.url) }
          evidence[candidate.id] = item
        }
      }
    }
    return evidence.values
      .sorted {
        if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.position != $1.position { return $0.position < $1.position }
        if $0.occurrence != $1.occurrence { return $0.occurrence < $1.occurrence }
        return $0.candidate.id < $1.candidate.id
      }
      .prefix(limit)
      .map {
        EmojiSearchMatch(
          id: $0.candidate.id, value: $0.candidate.value, score: $0.score, sourceURLs: $0.urls)
      }
  }

  private func blocks(
    in document: EmojiWebSearchDocument, queryTerms: Set<String>
  ) -> [(String, Relevance)] {
    let title = Self.content(document.title)
    let titleIsRelated = !Self.terms(title).isDisjoint(with: queryTerms)
    var blocks = title.components(separatedBy: "|")
      .map { part in
        (
          part,
          Self.terms(part).isDisjoint(with: queryTerms)
            ? Relevance.titleSample : Relevance.direct
        )
      }
    var previousSentenceIsRelated = false
    document.text.enumerateSubstrings(
      in: document.text.startIndex..<document.text.endIndex, options: .bySentences
    ) { sentence, _, _, _ in
      guard let sentence else { return }
      let text = Self.content(sentence)
      let words = Self.terms(text)
      let related = !words.isDisjoint(with: queryTerms)
      let isPromotion = !words.isDisjoint(
        with: ["follow", "subscribe", "newsletter", "communicate", "share", "register", "sponsored"]
      )
      let leadingGlyphs = text.prefix { !$0.isLetter && !$0.isNumber }
        .reduce(0) { $0 + (mapper.match(for: String($1)) == nil ? 0 : 1) }
      let isList = text.contains(",") || text.contains(":") || leadingGlyphs > 1
      let glyphCount = text.reduce(0) { $0 + (mapper.match(for: String($1)) == nil ? 0 : 1) }
      if related || previousSentenceIsRelated && isList && glyphCount > 1 && !isPromotion {
        blocks.append((text, .direct))
      } else if titleIsRelated && !text.unicodeScalars.contains(where: \.properties.isAlphabetic) {
        blocks.append((text, .contextualList))
      }
      previousSentenceIsRelated = related
    }
    return blocks
  }

  private static func terms(_ text: String) -> Set<String> {
    let folded = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    let functionWords: Set<String> = [
      "a", "an", "the", "i", "we", "me", "my", "our", "for", "to", "of", "and", "in",
      "on", "with", "some", "need", "want", "emoji", "emojis"
    ]
    let words = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let meaningful = words.subtracting(functionWords)
    return meaningful.isEmpty ? words : meaningful
  }

  private static func content(_ text: String) -> String {
    text.components(separatedBy: .newlines)
      .map { line in
        let segments = line.components(separatedBy: CharacterSet(charactersIn: "›»>|"))
        let hasNavigationPrefix = segments.dropLast()
          .contains {
            $0.range(
              of: "(?i)(?:^|\\s)(home|categories|index|menu|navigation)\\s*$",
              options: .regularExpression) != nil
          }
        return hasNavigationPrefix ? (segments.last ?? line) : line
      }
      .joined(separator: "\n")
  }

}

nonisolated enum DuckDuckGoEmojiSearchError: Error, Equatable {
  case queryTooLong
  case responseTooLarge
  case httpStatus(Int)
  case challenge
  case malformedResponse
  case transportFailure
}

nonisolated struct DuckDuckGoEmojiSearchProvider: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private static let maximumResponseBytes = 1_048_576
  private let transport: Transport

  init(transport: @escaping Transport) {
    self.transport = transport
  }

  func documents(
    for query: String, localeIdentifier: String
  ) async throws -> [EmojiWebSearchDocument] {
    try Task.checkCancellation()
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    guard query.utf8.count <= 2_048, query.count <= 256 else {
      throw DuckDuckGoEmojiSearchError.queryTooLong
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "html.duckduckgo.com"
    components.path = "/html/"
    components.queryItems = [
      URLQueryItem(
        name: "q", value: EmojiWebSearchQuery.text(for: query, localeIdentifier: localeIdentifier)),
      URLQueryItem(
        name: "kl",
        value: Self.region(
          for: EmojiWebSearchQuery.regionLocale(for: query, localeIdentifier: localeIdentifier)))
    ]
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { throw DuckDuckGoEmojiSearchError.malformedResponse }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        throw CancellationError()
      }
      if let issue = error as? EmojiSearchIssue { throw issue }
      if let error = error as? DuckDuckGoEmojiSearchError { throw error }
      throw DuckDuckGoEmojiSearchError.transportFailure
    }
    try Task.checkCancellation()
    if response.statusCode == 202 { throw DuckDuckGoEmojiSearchError.challenge }
    guard response.statusCode == 200 else {
      throw DuckDuckGoEmojiSearchError.httpStatus(response.statusCode)
    }
    guard data.count <= Self.maximumResponseBytes else {
      throw DuckDuckGoEmojiSearchError.responseTooLarge
    }
    return try Self.parse(data)
  }

  private static func region(for identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    guard let country = locale.region?.identifier.lowercased(),
      let language = locale.language.languageCode?.identifier.lowercased()
    else { return "wt-wt" }
    let region = "\(country)-\(language)"
    let supported: Set<String> = [
      "ar-es", "au-en", "at-de", "be-fr", "be-nl", "br-pt", "bg-bg", "ca-en", "ca-fr",
      "ct-ca", "cl-es", "cn-zh", "co-es", "hr-hr", "cz-cs", "dk-da", "ee-et", "fi-fi",
      "fr-fr", "de-de", "gr-el", "hk-tzh", "hu-hu", "in-en", "id-en", "id-id", "ie-en",
      "il-en", "it-it", "jp-jp", "kr-kr", "lv-lv", "lt-lt", "my-en", "mx-es", "nl-nl",
      "nz-en", "no-no", "pk-en", "pe-es", "ph-en", "pl-pl", "pt-pt", "ro-ro", "ru-ru",
      "sa-ar", "sg-en", "sk-sk", "sl-sl", "za-en", "es-es", "se-sv", "ch-de", "ch-fr",
      "tw-tzh", "th-th", "tr-tr", "ua-uk", "uk-en", "us-en", "us-es", "ve-es", "vn-vi"
    ]
    let aliases = [
      "gb-en": "uk-en", "jp-ja": "jp-jp", "kr-ko": "kr-kr", "no-nb": "no-no",
      "hk-zh": "hk-tzh", "tw-zh": "tw-tzh"
    ]
    let candidate = aliases[region] ?? region
    return supported.contains(candidate) ? candidate : "wt-wt"
  }

  private static func parse(_ data: Data) throws -> [EmojiWebSearchDocument] {
    guard let html = String(data: data, encoding: .utf8),
      !html.localizedCaseInsensitiveContains("<!ENTITY")
    else { throw DuckDuckGoEmojiSearchError.malformedResponse }
    let document: XMLDocument
    do {
      document = try XMLDocument(
        xmlString: try removingExcludedElements(from: html),
        options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
    } catch {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
    guard document.rootElement()?.name?.lowercased() == "html",
      !(try nodes("//body", in: document)).isEmpty
    else { throw DuckDuckGoEmojiSearchError.malformedResponse }
    if !(try nodes(
      "//*[@id='challenge-form' or @id='anomaly-form' or \(hasClass("anomaly-modal")) or \(hasClass("anomaly-modal__modal"))] | //form[contains(@action, 'anomaly.js')]",
      in: document))
      .isEmpty
    {
      throw DuckDuckGoEmojiSearchError.challenge
    }
    let results = try nodes(
      "//div[\(hasClass("result")) and not(\(hasClass("result--ad"))) and not(\(hasClass("result--no-result"))) and not(ancestor::nav or ancestor::header or ancestor::footer)]",
      in: document)
    if results.isEmpty {
      guard
        !(try nodes(
          "//*[\(hasClass("no-results")) or \(hasClass("result--no-result"))]", in: document))
          .isEmpty
      else {
        throw DuckDuckGoEmojiSearchError.malformedResponse
      }
      return []
    }
    var documents: [EmojiWebSearchDocument] = []
    for result in results {
      try Task.checkCancellation()
      if !(try nodes(".//*[\(hasClass("result__badge")) or \(hasClass("result__ad"))]", in: result))
        .isEmpty
      {
        continue
      }
      guard
        let anchor = try nodes(".//a[\(hasClass("result__a"))]", in: result).first as? XMLElement,
        let href = anchor.attribute(forName: "href")?.stringValue,
        let url = sourceURL(href)
      else { throw DuckDuckGoEmojiSearchError.malformedResponse }
      let title = text(in: anchor).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw DuckDuckGoEmojiSearchError.malformedResponse }
      let snippets = try nodes(".//*[\(hasClass("result__snippet"))]", in: result)
      let snippet = snippets.map { text(in: $0) }.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      documents.append(EmojiWebSearchDocument(url: url, title: title, text: snippet))
      if documents.count == 10 { break }
    }
    return documents
  }

  private static let excludedElements: Set<String> = [
    "script", "style", "nav", "header", "footer", "noscript", "iframe", "object"
  ]

  private static func removingExcludedElements(from html: String) throws -> String {
    let tags = try NSRegularExpression(
      pattern:
        #"<!--[\s\S]*?-->|<![^>]*>|<\s*+(/?)\s*+([A-Za-z][A-Za-z0-9:-]*+)(?:"[^"]*+"|'[^']*+'|[^'"<>])*+>"#
    )
    let source = html as NSString
    var cursor = 0
    var excluded: [String] = []
    var output = ""
    for tag in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
      if excluded.isEmpty {
        output += source.substring(
          with: NSRange(location: cursor, length: tag.range.location - cursor))
      }
      let nameRange = tag.range(at: 2)
      if nameRange.location != NSNotFound {
        let name = source.substring(with: nameRange).lowercased()
        let closing = tag.range(at: 1).length > 0
        if let last = excluded.last, ["script", "style"].contains(last) {
          if closing && name == last { excluded.removeLast() }
        } else if excludedElements.contains(name) {
          if closing {
            if excluded.last == name { excluded.removeLast() }
          } else {
            excluded.append(name)
          }
        } else if excluded.isEmpty {
          output += source.substring(with: tag.range)
        }
      } else if excluded.isEmpty {
        output += source.substring(with: tag.range)
      }
      cursor = NSMaxRange(tag.range)
    }
    if excluded.isEmpty {
      output += source.substring(from: cursor)
    }
    return output
  }

  private static func nodes(_ xpath: String, in node: XMLNode) throws -> [XMLNode] {
    do { return try node.nodes(forXPath: xpath) } catch {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
  }

  private static func hasClass(_ name: String) -> String {
    "contains(concat(' ', normalize-space(@class), ' '), ' \(name) ')"
  }

  private static func text(in node: XMLNode) -> String {
    if node.kind == .text { return node.stringValue ?? "" }
    if excludedElements.contains(node.name?.lowercased() ?? "") {
      return ""
    }
    if node.name?.lowercased() == "br" { return "\n" }
    return (node.children ?? []).map { text(in: $0) }.joined()
  }

  private static func sourceURL(_ href: String) -> URL? {
    let href = href.hasPrefix("//") ? "https:" + href : href
    guard var components = URLComponents(string: href) else { return nil }
    if ["duckduckgo.com", "www.duckduckgo.com", "html.duckduckgo.com"]
      .contains(components.host?.lowercased() ?? "")
    {
      guard ["/l", "/l/"].contains(components.path),
        let destination = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
        let decoded = URLComponents(string: destination)
      else { return nil }
      components = decoded
    }
    guard ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      !["duckduckgo.com", "www.duckduckgo.com", "html.duckduckgo.com"].contains(host.lowercased())
    else { return nil }
    return components.url
  }

}

nonisolated enum EmojiWebSourceIdentity {
  static func host(_ url: URL) -> String? {
    guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host?.lowercased()
    else { return nil }
    var labels = host.split(separator: ".").map(String.init)
    while labels.count > 2, let first = labels.first,
      ["www", "m", "mobile", "amp"].contains(first)
    {
      labels.removeFirst()
    }
    return labels.isEmpty ? nil : labels.joined(separator: ".")
  }
}
