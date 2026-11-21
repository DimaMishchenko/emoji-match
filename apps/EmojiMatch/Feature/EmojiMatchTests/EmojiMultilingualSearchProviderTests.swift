import Foundation
import Testing

@testable import EmojiMatch

@Suite struct EmojiMultilingualSearchProviderTests {
  private var resourceDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "ModelResources/Multilingual")
  }

  private struct Probe: Decodable {
    let query: String
    let tokenIDs: [Int]
    let vector: [Float]
    let topIDs: [String]
    let scores: [Double]
  }

  @Test func tokenizerAndNativeVectorsMatchPinnedPythonOnAuthoredProbes() async throws {
    let probes = try JSONDecoder()
      .decode(
        [Probe].self,
        from: Data(contentsOf: resourceDirectory.appending(path: "multilingual-parity.json")))
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "multilingual-vocab.json"))
    let provider = try EmojiMultilingualSearchProvider(resourceDirectory: resourceDirectory)
    for probe in probes {
      if !EmojiSearchInput.accepts(probe.query) {
        #expect(throws: EmojiMultilingualTokenizer.Failure.invalidInput) {
          try tokenizer.tokenIDs(for: "query: " + probe.query)
        }
        continue
      }
      #expect(try tokenizer.tokenIDs(for: "query: " + probe.query) == probe.tokenIDs)
      let vector = try await provider.embedding(for: probe.query)
      #expect(vector.count == 384)
      #expect(zip(vector, probe.vector).allSatisfy { abs($0 - $1) < 0.0001 })
      let matches = try await provider.matches(for: probe.query, localeIdentifier: "en")
      if probe.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
      EmojiMultilingualSearchProvider.rankedIndices(for: [0.4, 0.8, 0.8, -0.1, 0.4, 0.8, 0.4, 0.4])
        == [1, 2, 5, 0, 4, 6])
  }

  @Test func emptyQueryNeedsNoResources() async throws {
    let provider = try EmojiMultilingualSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-multilingual-resources"))
    #expect(try await provider.matches(for: " \n\t", localeIdentifier: "en").isEmpty)
  }

  @Test func cancellationPrecedesLoading() async throws {
    let provider = try EmojiMultilingualSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-multilingual-resources"))
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

  @Test func oversizedTokenizerInputFailsBeforeCleaning() throws {
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "multilingual-vocab.json"))
    for text in [String(repeating: "a", count: 2049), String(repeating: "\u{0301}", count: 2049)] {
      #expect(throws: EmojiMultilingualTokenizer.Failure.invalidInput) {
        try tokenizer.tokenIDs(for: text)
      }
    }
    #expect(try !tokenizer.tokenIDs(for: "query: " + String(repeating: "a", count: 2000)).isEmpty)
  }

  @Test func cancelledTokenizerInputPrecedesBoundsCheck() async throws {
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "multilingual-vocab.json"))
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

  @Test func oversizedProviderInputsFailBeforeResourceLoading() async throws {
    let provider = try EmojiMultilingualSearchProvider(
      resourceDirectory: URL(fileURLWithPath: "/missing-model-resources"))
    for query in [String(repeating: " ", count: 2001), String(repeating: "a", count: 2001)] {
      do {
        _ = try await provider.matches(for: query, localeIdentifier: "en")
        Issue.record("Oversized query returned matches")
      } catch EmojiMultilingualSearchProvider.Failure.invalidInput {
      }
      do {
        _ = try await provider.embedding(for: query)
        Issue.record("Oversized query returned an embedding")
      } catch EmojiMultilingualSearchProvider.Failure.invalidInput {
      }
    }
  }

  @Test func cachedEmbeddingHonorsCancellationAndReleaseReloadsResources() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for file in try FileManager.default.contentsOfDirectory(
      at: resourceDirectory, includingPropertiesForKeys: nil)
    {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: file.lastPathComponent), withDestinationURL: file)
    }
    let provider = try EmojiMultilingualSearchProvider(resourceDirectory: directory)
    let vector = try await provider.embedding(for: "a paper kite")
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.embedding(for: "a paper kite")
    }
    do {
      _ = try await operation.value
      Issue.record("Cancelled cached embedding returned a vector")
    } catch is CancellationError {
    }
    try FileManager.default.removeItem(at: directory.appending(path: "multilingual-manifest.json"))
    #expect(try await provider.embedding(for: "a paper kite") == vector)
    await provider.releaseResources()
    do {
      _ = try await provider.embedding(for: "a paper kite")
      Issue.record("Released resources returned a cached embedding")
    } catch EmojiMultilingualSearchProvider.Failure.invalidResources {
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
    for name in ["multilingual-vocab.json", "multilingual-index.f32"] {
      let target = directory.appending(path: name)
      try FileManager.default.removeItem(at: target)
      var data = try Data(contentsOf: resourceDirectory.appending(path: name))
      data[data.startIndex] ^= 1
      try data.write(to: target)
      #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
        try EmojiModelResourceValidation.validate(directory: directory, profile: .multilingual)
      }
      try FileManager.default.removeItem(at: target)
      try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: resourceDirectory.appending(path: name))
    }
    let catalogURL = directory.appending(path: "multilingual-catalog.json")
    var entries = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [[String: Any]])
    entries.swapAt(0, 1)
    try FileManager.default.removeItem(at: catalogURL)
    try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
      .write(to: catalogURL)
    #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
      try EmojiModelResourceValidation.validate(directory: directory, profile: .multilingual)
    }
  }

  @Test func modelDigestRejectsChangedGraphBeforeLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in [
      "multilingual-vocab.json", "multilingual-catalog.json", "multilingual-index.f32",
      "multilingual-manifest.json"
    ] {
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: name),
        withDestinationURL: resourceDirectory.appending(path: name))
    }
    let package = directory.appending(path: "Multilingual.mlpackage")
    try FileManager.default.createDirectory(
      at: package.appending(path: "Data/com.apple.CoreML/weights"),
      withIntermediateDirectories: true)
    for name in ["Manifest.json", "Data/com.apple.CoreML/weights/weight.bin"] {
      try FileManager.default.createSymbolicLink(
        at: package.appending(path: name),
        withDestinationURL: resourceDirectory.appending(path: "Multilingual.mlpackage/" + name))
    }
    var graph = try Data(
      contentsOf: resourceDirectory.appending(
        path: "Multilingual.mlpackage/Data/com.apple.CoreML/model.mlmodel"))
    graph[graph.startIndex] ^= 1
    try graph.write(to: package.appending(path: "Data/com.apple.CoreML/model.mlmodel"))
    #expect(throws: EmojiModelResourceValidation.Failure.invalidResources) {
      try EmojiModelResourceValidation.validate(directory: directory, profile: .multilingual)
    }
  }

  @Test func malformedVocabularyThrowsInsteadOfCrashingOrAcceptingInvalidNormalization() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: resourceDirectory.appending(path: "multilingual-vocab.json")))
        as? [String: Any])
    for mutation in 0..<7 {
      var vocabulary = original
      var pieces = try #require(vocabulary["pieces"] as? [[String: Any]])
      let encoded = try #require(vocabulary["charsmap"] as? String)
      var charsmap = try #require(Data(base64Encoded: encoded))
      switch mutation {
      case 0: pieces[1000]["text"] = pieces[999]["text"]
      case 1: pieces.swapAt(0, 1)
      case 2: pieces[1000]["score"] = "NaN"
      case 3: charsmap[0..<4] = Data([255, 255, 255, 127])
      case 4: charsmap[4..<8] = Data([0, 0, 255, 127])
      case 5: charsmap[charsmap.count - 1] = 255
      default:
        let size = charsmap.withUnsafeBytes {
          Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        charsmap[4 + size] = 255
      }
      vocabulary["pieces"] = pieces
      vocabulary["charsmap"] = charsmap.base64EncodedString()
      try JSONSerialization.data(withJSONObject: vocabulary).write(to: url)
      #expect(throws: (any Error).self) {
        try EmojiMultilingualTokenizer(vocabularyURL: url)
      }
    }
  }

}
