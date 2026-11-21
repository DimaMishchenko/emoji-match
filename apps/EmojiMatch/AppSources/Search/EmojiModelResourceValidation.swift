import CryptoKit
import Foundation

nonisolated enum EmojiModelResourceValidation {
  enum Failure: Error { case invalidResources }

  enum Profile {
    case miniLM
    case multilingual

    var model: String { self == .miniLM ? "MiniLM" : "Multilingual" }
    var manifest: String { self == .miniLM ? "manifest.json" : "multilingual-manifest.json" }
    var revision: String {
      self == .miniLM
        ? "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
        : "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    }
    var dataFiles: [String] {
      self == .miniLM
        ? ["vocab.txt", "catalog.json", "index.f32"]
        : ["multilingual-vocab.json", "multilingual-catalog.json", "multilingual-index.f32"]
    }
  }

  private struct Manifest: Decodable {
    let schema: Int
    let revision: String
    let dimensions: Int
    let count: Int
    let files: [String: FileIdentity]
  }

  private struct FileIdentity: Decodable {
    let sha256: String
    let bytes: Int?

    init(from decoder: Decoder) throws {
      let single = try decoder.singleValueContainer()
      if let digest = try? single.decode(String.self) {
        sha256 = digest
        bytes = nil
      } else {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try container.decode(String.self, forKey: .sha256)
        bytes = try container.decode(Int.self, forKey: .bytes)
      }
    }

    private enum CodingKeys: String, CodingKey { case sha256, bytes }
  }

  static func validate(directory: URL, profile: Profile) throws {
    try Task.checkCancellation()
    let manifest = try JSONDecoder()
      .decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: profile.manifest)))
    guard manifest.schema == 1, manifest.revision == profile.revision,
      manifest.dimensions == 384, manifest.count == 1932
    else { throw Failure.invalidResources }
    for name in profile.dataFiles {
      guard let identity = manifest.files[name] else { throw Failure.invalidResources }
      try validateFile(directory.appending(path: name), identity: identity)
    }
    let package = profile.model + ".mlpackage/"
    let compiled = directory.appending(path: profile.model + ".mlmodelc")
    if FileManager.default.fileExists(atPath: compiled.path) {
      guard let identity = manifest.files[package + "Data/com.apple.CoreML/weights/weight.bin"]
      else {
        throw Failure.invalidResources
      }
      try validateFile(compiled.appending(path: "weights/weight.bin"), identity: identity)
    } else {
      for name in [
        "Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin"
      ] {
        guard let identity = manifest.files[package + name] else { throw Failure.invalidResources }
        try validateFile(directory.appending(path: package + name), identity: identity)
      }
    }
    try Task.checkCancellation()
  }

  private static func validateFile(_ url: URL, identity: FileIdentity) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    var count = 0
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      digest.update(data: chunk)
      count += chunk.count
    }
    let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
    guard actual == identity.sha256, identity.bytes.map({ $0 == count }) ?? true else {
      throw Failure.invalidResources
    }
  }
}
