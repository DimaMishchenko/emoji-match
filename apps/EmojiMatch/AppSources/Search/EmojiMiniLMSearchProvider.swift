import Accelerate
import CoreML
import Foundation

actor EmojiMiniLMSearchProvider {
  enum Failure: Error {
    case invalidInput
    case invalidResources
    case invalidEmbedding
  }

  private struct Entry: Decodable {
    let id: String
    let value: String
  }

  private struct Resources {
    let model: MLModel
    let tokenizer: EmojiMiniLMTokenizer
    let catalog: [Entry]
    let indexByID: [String: Int]
    let matrix: [Float]
  }

  private let resourceDirectory: URL
  private var resources: Resources?
  private var lastEmbedding: (query: String, vector: [Float])?

  init(resourceDirectory: URL) throws {
    self.resourceDirectory = resourceDirectory
  }

  func matches(for query: String, localeIdentifier: String) async throws -> [EmojiSearchMatch] {
    try Task.checkCancellation()
    guard EmojiSearchInput.accepts(query) else { throw Failure.invalidInput }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    let vector = try embedding(for: query)
    guard let resources else { throw Failure.invalidResources }
    var scores = [Float](repeating: 0, count: resources.catalog.count)
    vDSP_mmul(
      resources.matrix, 1, vector, 1, &scores, 1,
      vDSP_Length(resources.catalog.count), 1, 384)
    try Task.checkCancellation()
    return Self.rankedIndices(for: scores)
      .map { index in
        let entry = resources.catalog[index]
        return EmojiSearchMatch(
          id: entry.id, value: entry.value, score: Double(scores[index]), sourceURLs: [])
      }
  }

  static func rankedIndices(for scores: [Float]) -> [Int] {
    Array(
      scores.indices
        .sorted {
          scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
        }
        .prefix(6))
  }

  func rankedIDs(for query: String, candidateIDs: [String]) async throws -> [String] {
    try Task.checkCancellation()
    guard EmojiSearchInput.accepts(query) else { throw Failure.invalidInput }
    guard !candidateIDs.isEmpty else { return [] }
    var seen = Set<String>()
    var candidates: [String] = []
    for id in candidateIDs {
      try Task.checkCancellation()
      if seen.insert(id).inserted { candidates.append(id) }
    }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try Task.checkCancellation()
      return candidates
    }
    let resources: Resources
    do {
      resources = try loadResources()
    } catch {
      try Task.checkCancellation()
      throw Failure.invalidResources
    }
    var indices: [Int] = []
    for id in candidates {
      try Task.checkCancellation()
      guard let index = resources.indexByID[id] else { throw Failure.invalidResources }
      indices.append(index)
    }
    let vector = try embedding(for: query)
    var scores = [Float](repeating: 0, count: resources.catalog.count)
    vDSP_mmul(
      resources.matrix, 1, vector, 1, &scores, 1,
      vDSP_Length(resources.catalog.count), 1, 384)
    let candidateScores = indices.map { scores[$0] }
    return try Self.rankedCandidateIndices(for: candidateScores).map { candidates[$0] }
  }

  static func rankedCandidateIndices(for scores: [Float]) throws -> [Int] {
    try Task.checkCancellation()
    let indices = scores.indices.sorted {
      scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
    }
    try Task.checkCancellation()
    return indices
  }

  func embedding(for query: String) throws -> [Float] {
    try Task.checkCancellation()
    guard EmojiSearchInput.accepts(query) else { throw Failure.invalidInput }
    if let lastEmbedding, lastEmbedding.query == query {
      guard lastEmbedding.vector.count == 384, lastEmbedding.vector.allSatisfy(\.isFinite) else {
        throw Failure.invalidEmbedding
      }
      try Task.checkCancellation()
      return lastEmbedding.vector
    }
    let resources = try loadResources()
    let ids = try resources.tokenizer.tokenIDs(for: query)
    let input = try MLMultiArray(shape: [1, 256], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, 256], dataType: .int32)
    for index in 0..<256 {
      input[index] = NSNumber(value: index < ids.count ? ids[index] : 0)
      mask[index] = NSNumber(value: index < ids.count ? 1 : 0)
    }
    try Task.checkCancellation()
    let prediction = try resources.model.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        "input_ids": input, "attention_mask": mask
      ]))
    try Task.checkCancellation()
    guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
      output.count == 384
    else {
      throw Failure.invalidEmbedding
    }
    let vector = (0..<384).map { output[$0].floatValue }
    guard vector.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
    try Task.checkCancellation()
    lastEmbedding = (query, vector)
    return vector
  }

  func releaseResources() {
    resources = nil
    lastEmbedding = nil
  }

  private func loadResources() throws -> Resources {
    if let resources { return resources }
    do {
      try EmojiModelResourceValidation.validate(directory: resourceDirectory, profile: .miniLM)
    } catch {
      try Task.checkCancellation()
      throw Failure.invalidResources
    }
    let tokenizer = try EmojiMiniLMTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "vocab.txt"))
    let catalog = try JSONDecoder()
      .decode(
        [Entry].self, from: Data(contentsOf: resourceDirectory.appending(path: "catalog.json")))
    let data = try Data(contentsOf: resourceDirectory.appending(path: "index.f32"))
    guard catalog.count == 1932, Set(catalog.map(\.id)).count == 1932,
      data.count == catalog.count * 384 * MemoryLayout<Float>.size
    else { throw Failure.invalidResources }
    let matrix = try data.withUnsafeBytes { bytes in
      try stride(from: 0, to: data.count, by: 4)
        .map { offset in
          if offset.isMultiple(of: 384 * 4) { try Task.checkCancellation() }
          return Float(
            bitPattern: UInt32(
              littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
    }
    guard matrix.allSatisfy(\.isFinite) else { throw Failure.invalidResources }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndGPU
    let compiled = resourceDirectory.appending(path: "MiniLM.mlmodelc")
    let model: MLModel
    if FileManager.default.fileExists(atPath: compiled.path) {
      model = try MLModel(contentsOf: compiled, configuration: configuration)
    } else {
      let temporary = try MLModel.compileModel(
        at: resourceDirectory.appending(path: "MiniLM.mlpackage"))
      defer { try? FileManager.default.removeItem(at: temporary) }
      model = try MLModel(contentsOf: temporary, configuration: configuration)
    }
    guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
      metadata["revision"] == EmojiModelResourceValidation.Profile.miniLM.revision
    else { throw Failure.invalidResources }
    try Task.checkCancellation()
    let loaded = Resources(
      model: model, tokenizer: tokenizer, catalog: catalog,
      indexByID: Dictionary(
        uniqueKeysWithValues: catalog.enumerated().map { ($0.element.id, $0.offset) }),
      matrix: matrix)
    resources = loaded
    return loaded
  }
}
