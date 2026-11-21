import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiMiniLMSearchProviderTests {
  private var resourceDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Resources/MiniLM")
  }

  private struct Probe: Decodable {
    let query: String
    let tokenIDs: [Int]
    let vector: [Float]
    let topIDs: [String]
    let scores: [Double]
  }

  private struct CatalogEntry: Decodable {
    let id: String
  }

  @Test func tokenizerAndNativeVectorsMatchPinnedPythonOnAuthoredProbes() async throws {
    let probes = try JSONDecoder()
      .decode(
        [Probe].self, from: Data(contentsOf: resourceDirectory.appending(path: "parity.json")))
    let tokenizer = try EmojiMiniLMTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "vocab.txt"))
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    for probe in probes {
      if !EmojiSearchInput.accepts(probe.query) {
        #expect(throws: EmojiMiniLMTokenizer.Failure.invalidInput) {
          try tokenizer.tokenIDs(for: probe.query)
        }
        continue
      }
      #expect(try tokenizer.tokenIDs(for: probe.query) == probe.tokenIDs)
      let vector = try await provider.embedding(for: probe.query)
      #expect(vector.count == 384)
      #expect(zip(vector, probe.vector).allSatisfy { abs($0 - $1) < 0.0001 })
      let matches = try await provider.matches(for: probe.query, localeIdentifier: "en")
      if probe.query.isEmpty {
        #expect(matches.isEmpty)
      } else {
        #expect(matches.map(\.id) == probe.topIDs)
        #expect(zip(matches, probe.scores).allSatisfy { abs($0.score - $1) < 0.0001 })
        #expect(matches.allSatisfy { !$0.value.isEmpty && $0.sourceURLs.isEmpty })
        let repeated = try await provider.matches(for: probe.query, localeIdentifier: "ja")
        #expect(repeated == matches)
      }
    }
  }

  @Test func equalScoresKeepCanonicalCatalogOrder() {
    #expect(
      EmojiMiniLMSearchProvider.rankedIndices(for: [0.4, 0.8, 0.8, -0.1, 0.4, 0.8, 0.4, 0.4])
        == [1, 2, 5, 0, 4, 6])
  }

  @Test func candidateRanksMatchBundledVectorsAndIncludeTheEntireCatalog() async throws {
    let catalog = try JSONDecoder()
      .decode(
        [CatalogEntry].self,
        from: Data(contentsOf: resourceDirectory.appending(path: "catalog.json")))
    let probes = try JSONDecoder()
      .decode(
        [Probe].self, from: Data(contentsOf: resourceDirectory.appending(path: "parity.json")))
    let data = try Data(contentsOf: resourceDirectory.appending(path: "index.f32"))
    let matrix = data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count, by: 4)
        .map { offset in
          Float(
            bitPattern: UInt32(
              littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
    }
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    let candidates = catalog.map(\.id)
    for probe in probes where !probe.query.isEmpty && EmojiSearchInput.accepts(probe.query) {
      let vector = try await provider.embedding(for: probe.query)
      let scores = catalog.indices.map { row in
        (0..<384).reduce(0.0) { $0 + Double(matrix[row * 384 + $1]) * Double(vector[$1]) }
      }
      let expected = catalog.indices
        .sorted {
          scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
        }
        .map { candidates[$0] }
      let ranked = try await provider.rankedIDs(for: probe.query, candidateIDs: candidates)
      #expect(ranked == expected)
      #expect(ranked.count == 1932)
      #expect(Array(ranked.prefix(6)) == probe.topIDs)
      let subset = Array(ranked.suffix(12).reversed())
      let restricted = try await provider.rankedIDs(
        for: probe.query, candidateIDs: subset + [subset[0], subset[1]])
      let subsetSet = Set(subset)
      #expect(restricted == ranked.filter { subsetSet.contains($0) })
      #expect(restricted.count == 12)
    }
  }

  @Test func candidateScoreTiesKeepOriginalOrderWithoutTruncation() throws {
    #expect(
      try EmojiMiniLMSearchProvider.rankedCandidateIndices(
        for: [0.4, 0.8, 0.8, -0.1, 0.4, 0.8, 0.4, 0.4])
        == [1, 2, 5, 0, 4, 6, 7, 3])
  }

  @Test func unknownCandidateThrowsOwnedResourceFailure() async throws {
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    do {
      _ = try await provider.rankedIDs(for: "a paper kite", candidateIDs: ["unknown-family"])
      Issue.record("Unknown candidate returned ranks")
    } catch EmojiMiniLMSearchProvider.Failure.invalidResources {
    }
  }

  @Test func missingCandidateResourcesThrowOwnedFailure() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    do {
      _ = try await provider.rankedIDs(for: "a paper kite", candidateIDs: ["kite"])
      Issue.record("Missing resources returned ranks")
    } catch EmojiMiniLMSearchProvider.Failure.invalidResources {
    }
  }

  @Test func emptyCandidateInputsAvoidLoadingAndKeepStableUniqueOrder() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    #expect(try await provider.rankedIDs(for: "a paper kite", candidateIDs: []).isEmpty)
    #expect(
      try await provider.rankedIDs(for: " \n\t", candidateIDs: ["b", "a", "b", "c", "a"])
        == ["b", "a", "c"])
  }

  @Test func candidateCancellationPrecedesEmptyAndMissingResources() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    for candidates in [[], ["unknown-family"]] {
      let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await provider.rankedIDs(for: "a paper kite", candidateIDs: candidates)
      }
      do {
        _ = try await operation.value
        Issue.record("Cancelled candidate ranking returned results")
      } catch is CancellationError {
      }
    }
  }

  @Test func cachedEmbeddingStillHonorsCancellation() async throws {
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: resourceDirectory)
    _ = try await provider.embedding(for: "a paper kite")
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.embedding(for: "a paper kite")
    }
    do {
      _ = try await operation.value
      Issue.record("Cancelled cached embedding returned a vector")
    } catch is CancellationError {
    }
  }

  @Test func cancellationInterruptsLargeCandidateDeduplication() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    let candidates = [String](repeating: "unknown-family", count: 2_000_000)
    let operation = Task.detached {
      try await provider.rankedIDs(for: " ", candidateIDs: candidates)
    }
    try await Task.sleep(for: .milliseconds(10))
    operation.cancel()
    do {
      _ = try await operation.value
      Issue.record("Cancelled candidate deduplication returned results")
    } catch is CancellationError {
    }
  }

  @Test func oversizedTokenizerInputFailsBeforeCleaning() throws {
    let tokenizer = try EmojiMiniLMTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "vocab.txt"))
    for text in [String(repeating: "a", count: 2049), String(repeating: "\u{0301}", count: 2049)] {
      #expect(throws: EmojiMiniLMTokenizer.Failure.invalidInput) {
        try tokenizer.tokenIDs(for: text)
      }
    }
    #expect(try !tokenizer.tokenIDs(for: "query: " + String(repeating: "a", count: 2000)).isEmpty)
  }

  @Test func cancelledTokenizerInputPrecedesBoundsCheck() async throws {
    let tokenizer = try EmojiMiniLMTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "vocab.txt"))
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try tokenizer.tokenIDs(for: String(repeating: "a", count: 2049))
    }
    do {
      _ = try await operation.value
      Issue.record("Cancelled tokenizer returned tokens")
    } catch is CancellationError {
    }
  }

  @Test func emptyQueryNeedsNoResources() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    #expect(try await provider.matches(for: " \n\t", localeIdentifier: "en").isEmpty)
  }

  @Test func cancellationPrecedesLoading() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-minilm-resources"))
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.matches(for: "a paper kite", localeIdentifier: "en")
    }
    do {
      _ = try await operation.value
      Issue.record("Cancelled search returned results")
    } catch is CancellationError {
    }
  }
  @Test func oversizedProviderInputsFailBeforeResourceLoading() async throws {
    let provider = try EmojiMiniLMSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-model-resources"))
    for query in [String(repeating: " ", count: 2001), String(repeating: "a", count: 2001)] {
      do {
        _ = try await provider.matches(for: query, localeIdentifier: "en")
        Issue.record("Oversized query returned matches")
      } catch EmojiMiniLMSearchProvider.Failure.invalidInput {
      }
      do {
        _ = try await provider.embedding(for: query)
        Issue.record("Oversized query returned an embedding")
      } catch EmojiMiniLMSearchProvider.Failure.invalidInput {
      }
      do {
        _ = try await provider.rankedIDs(for: query, candidateIDs: [])
        Issue.record("Oversized candidate query returned ranks")
      } catch EmojiMiniLMSearchProvider.Failure.invalidInput {
      }
    }
  }

  @Test func resourceDigestsRejectSameSizeChangesAndCatalogReordering() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for file in try FileManager.default.contentsOfDirectory(
      at: resourceDirectory, includingPropertiesForKeys: nil)
    {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: file.lastPathComponent), withDestinationURL: file)
    }
    for name in ["vocab.txt", "index.f32"] {
      let target = directory.appending(path: name)
      try FileManager.default.removeItem(at: target)
      var data = try Data(contentsOf: resourceDirectory.appending(path: name))
      data[data.startIndex] ^= 1
      try data.write(to: target)
      #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
        try EmojiModelResourceValidation.validate(directory: directory, profile: .miniLM)
      }
      try FileManager.default.removeItem(at: target)
      try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: resourceDirectory.appending(path: name))
    }
    let catalogURL = directory.appending(path: "catalog.json")
    var entries = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [[String: Any]])
    entries.swapAt(0, 1)
    try FileManager.default.removeItem(at: catalogURL)
    try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
      .write(to: catalogURL)
    #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
      try EmojiModelResourceValidation.validate(directory: directory, profile: .miniLM)
    }
  }

  @Test func modelDigestRejectsChangedGraphBeforeLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["vocab.txt", "catalog.json", "index.f32", "manifest.json"] {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: name),
        withDestinationURL: resourceDirectory.appending(path: name))
    }
    let package = directory.appending(path: "MiniLM.mlpackage")
    try FileManager.default.createDirectory(
      at: package.appending(path: "Data/com.apple.CoreML/weights"),
      withIntermediateDirectories: true)
    for name in ["Manifest.json", "Data/com.apple.CoreML/weights/weight.bin"] {
      try FileManager.default.createSymbolicLink(
        at: package.appending(path: name),
        withDestinationURL: resourceDirectory.appending(path: "MiniLM.mlpackage/" + name))
    }
    var graph = try Data(
      contentsOf: resourceDirectory.appending(
        path: "MiniLM.mlpackage/Data/com.apple.CoreML/model.mlmodel"))
    graph[graph.startIndex] ^= 1
    try graph.write(to: package.appending(path: "Data/com.apple.CoreML/model.mlmodel"))
    #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
      try EmojiModelResourceValidation.validate(directory: directory, profile: .miniLM)
    }
  }

  @Test func malformedVocabularyThrowsInsteadOfOverwritingTokens() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try String(
      contentsOf: resourceDirectory.appending(path: "vocab.txt"), encoding: .utf8
    )
    .components(separatedBy: "\n")
    for position in [101, 1000] {
      var tokens = original
      tokens[position] = position == 101 ? "invalid-special" : tokens[999]
      try tokens.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
      #expect(throws: EmojiMiniLMTokenizer.Failure.invalidVocabulary) {
        try EmojiMiniLMTokenizer(vocabularyURL: url)
      }
    }
  }

  @Test func releasingResourcesClearsTheCachedEmbedding() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for file in try FileManager.default.contentsOfDirectory(
      at: resourceDirectory, includingPropertiesForKeys: nil)
    {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: file.lastPathComponent), withDestinationURL: file)
    }
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: directory)
    _ = try await provider.embedding(for: "a paper kite")
    try FileManager.default.removeItem(at: directory.appending(path: "manifest.json"))
    #expect(try await provider.embedding(for: "a paper kite").count == 384)
    await provider.releaseResources()
    do {
      _ = try await provider.embedding(for: "a paper kite")
      Issue.record("Released resources returned a cached embedding")
    } catch EmojiMiniLMSearchProvider.Failure.invalidResources {
    }
  }

}
