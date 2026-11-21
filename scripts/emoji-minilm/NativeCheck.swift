import CoreML
import Foundation

nonisolated struct Probe: Decodable {
  let query: String
  let tokenIDs: [Int]
  let vector: [Float]
  let topIDs: [String]
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
        at: directory.appending(path: "MiniLM.mlpackage"))
      defer { try? FileManager.default.removeItem(at: compiled) }
      try FileManager.default.copyItem(at: compiled, to: target.appending(path: "MiniLM.mlmodelc"))
      return
    }
    let probes = try JSONDecoder()
      .decode([Probe].self, from: Data(contentsOf: directory.appending(path: "parity.json")))
    let tokenizer = try EmojiMiniLMTokenizer(vocabularyURL: directory.appending(path: "vocab.txt"))
    let provider = try EmojiMiniLMSearchProvider(resourceDirectory: directory)
    var rows: [[String: Any]] = []
    for probe in probes {
      if !EmojiSearchInput.accepts(probe.query) {
        do {
          _ = try await provider.embedding(for: probe.query)
          fatalError("Oversized fixture returned a vector")
        } catch EmojiMiniLMSearchProvider.Failure.invalidInput {
        }
        do {
          _ = try tokenizer.tokenIDs(for: probe.query)
          fatalError("Oversized fixture returned tokens")
        } catch EmojiMiniLMTokenizer.Failure.invalidInput {
        }
        rows.append(["rejectedOversizedInput": true])
        continue
      }
      let tokens = try tokenizer.tokenIDs(for: probe.query)
      guard tokens == probe.tokenIDs else {
        fatalError("Token mismatch: \(probe.query) \(tokens) != \(probe.tokenIDs)")
      }
      let vector = try await provider.embedding(for: probe.query)
      let error = zip(vector, probe.vector).map { abs($0 - $1) }.max() ?? .infinity
      guard error < 0.0001 else { fatalError("Vector mismatch: \(error)") }
      let matches = try await provider.matches(for: probe.query, localeIdentifier: "en")
      guard matches.map(\.id) == (probe.query.isEmpty ? [] : probe.topIDs) else {
        fatalError("Ranking mismatch \(probe.query) \(matches)")
      }
      rows.append([
        "query": String(probe.query.prefix(80)), "maxVectorError": error,
        "topIDs": matches.map(\.id)
      ])
    }
    print(
      String(
        data: try JSONSerialization.data(
          withJSONObject: ["probes": rows], options: [.prettyPrinted, .sortedKeys]),
        encoding: .utf8) ?? "JSON encoding failed")
  }
}
