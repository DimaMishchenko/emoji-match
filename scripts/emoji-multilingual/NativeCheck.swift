import CoreML
import Foundation

nonisolated struct Probe: Decodable {
  let locale: String
  let query: String
  let tokenIDs: [Int]
  let vector: [Float]
  let topIDs: [String]
  let scores: [Double]
}

@main struct NativeCheck {
  static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    if CommandLine.arguments.count == 3 {
      let target = URL(fileURLWithPath: CommandLine.arguments[2])
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for file in try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      where file.pathExtension != "mlpackage" {
        try FileManager.default.createSymbolicLink(
          at: target.appending(path: file.lastPathComponent), withDestinationURL: file)
      }
      let compiled = try await MLModel.compileModel(
        at: directory.appending(path: "Multilingual.mlpackage"))
      defer { try? FileManager.default.removeItem(at: compiled) }
      try FileManager.default.copyItem(
        at: compiled, to: target.appending(path: "Multilingual.mlmodelc"))
      return
    }
    let probes = try JSONDecoder()
      .decode(
        [Probe].self, from: Data(contentsOf: directory.appending(path: "multilingual-parity.json")))
    let provider = try EmojiMultilingualSearchProvider(resourceDirectory: directory)
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: directory.appending(path: "multilingual-vocab.json"))
    var rows: [[String: Any]] = []
    for probe in probes {
      if !EmojiSearchInput.accepts(probe.query) {
        do {
          _ = try await provider.embedding(for: probe.query)
          fatalError("Oversized fixture returned a vector")
        } catch EmojiMultilingualSearchProvider.Failure.invalidInput {
        }
        do {
          _ = try tokenizer.tokenIDs(for: "query: " + probe.query)
          fatalError("Oversized fixture returned tokens")
        } catch EmojiMultilingualTokenizer.Failure.invalidInput {
        }
        rows.append(["rejectedOversizedInput": true])
        continue
      }
      let tokens = try tokenizer.tokenIDs(for: "query: " + probe.query)
      guard tokens == probe.tokenIDs else {
        fatalError("Token mismatch: \(probe.query.debugDescription)")
      }
      let vector = try await provider.embedding(for: probe.query)
      let error = zip(vector, probe.vector).map { abs($0 - $1) }.max() ?? .infinity
      guard error < 0.0001 else { fatalError("Vector mismatch: \(error)") }
      let matches = try await provider.matches(for: probe.query, localeIdentifier: probe.locale)
      let empty = probe.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      guard matches.map(\.id) == (empty ? [] : probe.topIDs) else {
        fatalError("Ranking mismatch: \(probe.query.debugDescription) \(matches)")
      }
      let scoreError = zip(matches, probe.scores).map { abs($0.score - $1) }.max() ?? 0
      guard scoreError < 0.0001 else { fatalError("Score mismatch: \(scoreError)") }
      rows.append([
        "locale": probe.locale, "query": String(probe.query.prefix(80)),
        "maxVectorError": error, "maxScoreError": scoreError,
        "topIDs": matches.map(\.id)
      ])
    }
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: [
            "computeUnits": "cpuOnly",
            "compiledModel": FileManager.default.fileExists(
              atPath: directory.appending(path: "Multilingual.mlmodelc").path),
            "probes": rows
          ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
