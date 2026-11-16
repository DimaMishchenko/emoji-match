import Foundation
import Testing

@testable import EmojiKit

private let liveTestsEnabled = ProcessInfo.processInfo.environment["EMOJIKIT_LIVE_TESTS"] == "1"

@Suite struct EmojiKitIntegrationTests {
  @Test(.enabled(if: liveTestsEnabled))
  func bundledSequencesMatchPinnedUnicodeSource() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appending(path: "Sources/Emojis/Resources")
    let metadata = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: resources.appending(path: "metadata.json")))
        as? [String: Any])
    let version = try #require(metadata["unicodeEmojiVersion"] as? String)
    let release = EmojiDataRelease(
      unicodeEmojiVersion: version, cldrVersion: "49", cldrTag: "49.0.0")
    let sources = try await EmojiDataLoader().fetchUnicodeSourceFiles(release: release)
    let source = try #require(sources.first { $0.name == "emoji-test.txt" })
    let expected = try UnicodeEmojiParser.parseEmojiTest(source.data)
      .flatMap { [$0.id] + $0.skinToneVariants.map { $0.id.rawValue } }
    let records = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: resources.appending(path: "emojis.json")))
        as? [[String: Any]])
    let actual = try records.flatMap { record -> [String] in
      let id = try #require(record["id"] as? String)
      let variants = try #require(record["skinToneVariants"] as? [[String: Any]])
      return [id] + (try variants.map { try #require($0["id"] as? String) })
    }
    #expect(Set(actual) == Set(expected))
    #expect(actual.count == expected.count)
    #expect(Set(actual).count == actual.count)
  }

  @Test(.enabled(if: liveTestsEnabled))
  func liveParserPreservesEveryCanonicalSequenceExactlyOnce() async throws {
    let loader = EmojiDataLoader()
    let release = try await loader.fetchLatestRelease()
    let files = try await loader.fetchUnicodeSourceFiles(release: release)
    let source = try #require(files.first { $0.name == "emoji-test.txt" })
    let emojis = try UnicodeEmojiParser.parseEmojiTest(source.data)
    let expected = String(decoding: source.data, as: UTF8.self)
      .components(separatedBy: .newlines)
      .compactMap { line -> String? in
        let fields = line.components(separatedBy: ";")
        guard fields.count == 2 else { return nil }
        let status = fields[1].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
        guard status == "fully-qualified" || status == "component" else { return nil }
        return fields[0].split(whereSeparator: \.isWhitespace).joined(separator: "-")
      }
    let actual = emojis.flatMap { [$0.id] + $0.skinToneVariants.map { $0.id.rawValue } }
    #expect(Set(actual) == Set(expected))
    #expect(actual.count == expected.count)
    #expect(Set(actual).count == actual.count)
    let positions = Dictionary(
      uniqueKeysWithValues: expected.enumerated().map { ($0.element, $0.offset) })
    #expect(emojis.map { positions[$0.id]! } == emojis.map { positions[$0.id]! }.sorted())
  }

  @Test(.enabled(if: liveTestsEnabled))
  func liveIntegrationIsOptIn() async throws {
    let dataLoader = EmojiDataLoader()
    let release = try await dataLoader.fetchLatestRelease()
    let locales = try await dataLoader.fetchAvailableLocales(release: release)
    #expect(!locales.isEmpty)
  }

  @Test(.enabled(if: liveTestsEnabled))
  func liveFetchLatestWritesBundleToTempDirectory() async throws {
    let fileManager = FileManager.default
    let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? fileManager.removeItem(at: outputRoot)
    }

    let paths = try CLIOutputPaths(
      outputRoot: outputRoot.path,
      metadataPath: nil,
      emojisPath: nil,
      localizationsPath: nil
    )
    let generator = EmojiGenerator()

    let summary = try await generator.fetchLatest(
      paths: paths,
      localeSelection: .explicit(["en"]),
      defaultLocale: "en",
      force: false,
      dryRun: false
    )

    #expect(summary.localeCount == 1)
    #expect(fileManager.fileExists(atPath: paths.metadataPath))
    #expect(fileManager.fileExists(atPath: paths.emojisPath))
    #expect(fileManager.fileExists(atPath: "\(paths.localizationsPath)/index.json"))
    #expect(fileManager.fileExists(atPath: "\(paths.localizationsPath)/en.json"))
  }
}
