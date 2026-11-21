import Foundation

nonisolated struct TokenProbe: Decodable {
  let text: String
  let ids: [Int]
}

@main struct TokenCheck {
  static func main() throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let tokenizer = try EmojiMultilingualTokenizer(
      vocabularyURL: directory.appending(path: "multilingual-vocab.json"))
    let probes = try JSONDecoder()
      .decode(
        [TokenProbe].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    var failures = 0
    for probe in probes {
      if probe.text.utf8.prefix(8193).count > 8192
        || probe.text.unicodeScalars.prefix(2049).count > 2048
      {
        do {
          _ = try tokenizer.tokenIDs(for: probe.text)
          failures += 1
        } catch EmojiMultilingualTokenizer.Failure.invalidInput {
        }
        continue
      }
      let actual = try tokenizer.tokenIDs(for: probe.text)
      if actual != probe.ids {
        failures += 1
        if failures < 20 {
          print("Token mismatch: \(probe.text.debugDescription) \(actual) != \(probe.ids)")
        }
      }
    }
    print("\(probes.count) probes; \(failures) failures")
    guard failures == 0 else { exit(1) }
  }
}
