import Accelerate
import CoreML
import Foundation

actor EmojiMultilingualSearchProvider {
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
    let tokenizer: EmojiMultilingualTokenizer
    let catalog: [Entry]
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

  func embedding(for query: String) throws -> [Float] {
    try Task.checkCancellation()
    guard EmojiSearchInput.accepts(query) else { throw Failure.invalidInput }
    if let lastEmbedding, lastEmbedding.query == query {
      try Task.checkCancellation()
      return lastEmbedding.vector
    }
    let resources = try loadResources()
    let ids = try resources.tokenizer.tokenIDs(for: "query: " + query)
    let input = try MLMultiArray(shape: [1, 512], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, 512], dataType: .int32)
    for index in 0..<512 {
      input[index] = NSNumber(value: index < ids.count ? ids[index] : 1)
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
    var vector = (0..<384).map { output[$0].floatValue }
    guard vector.allSatisfy(\.isFinite) else { throw Failure.invalidEmbedding }
    let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { throw Failure.invalidEmbedding }
    for index in vector.indices { vector[index] /= norm }
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
      try EmojiModelResourceValidation.validate(
        directory: resourceDirectory, profile: .multilingual)
    } catch {
      try Task.checkCancellation()
      throw Failure.invalidResources
    }
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: resourceDirectory.appending(path: "multilingual-vocab.json"))
    let catalog = try JSONDecoder()
      .decode(
        [Entry].self,
        from: Data(contentsOf: resourceDirectory.appending(path: "multilingual-catalog.json")))
    let data = try Data(contentsOf: resourceDirectory.appending(path: "multilingual-index.f32"))
    guard catalog.count == 1932, Set(catalog.map(\.id)).count == 1932,
      data.count == catalog.count * 384 * MemoryLayout<Float>.size
    else { throw Failure.invalidResources }
    let matrix = data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count, by: 4)
        .map { offset in
          Float(
            bitPattern: UInt32(
              littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
    }
    guard matrix.allSatisfy(\.isFinite) else { throw Failure.invalidResources }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let compiled = resourceDirectory.appending(path: "Multilingual.mlmodelc")
    let model: MLModel
    if FileManager.default.fileExists(atPath: compiled.path) {
      model = try MLModel(contentsOf: compiled, configuration: configuration)
    } else {
      let temporary = try MLModel.compileModel(
        at: resourceDirectory.appending(path: "Multilingual.mlpackage"))
      defer { try? FileManager.default.removeItem(at: temporary) }
      model = try MLModel(contentsOf: temporary, configuration: configuration)
    }
    guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
      metadata["revision"] == EmojiModelResourceValidation.Profile.multilingual.revision
    else { throw Failure.invalidResources }
    try Task.checkCancellation()
    let loaded = Resources(model: model, tokenizer: tokenizer, catalog: catalog, matrix: matrix)
    resources = loaded
    return loaded
  }
}
