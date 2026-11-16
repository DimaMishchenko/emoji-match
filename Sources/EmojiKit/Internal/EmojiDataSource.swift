import ArgumentParser
import Foundation

internal enum EmojiDataSource {
  static let unicodeDirectoryURL = requiredURL("https://unicode.org/Public/emoji/")
  static let unicodeLatestTestURL = requiredURL(
    "https://unicode.org/Public/emoji/latest/emoji-test.txt")
  static let cldrTagsURL = requiredURL(
    "https://api.github.com/repos/unicode-org/cldr-json/tags?per_page=100"
  )
  static let cldrContentsAPIBaseURL = requiredURL(
    "https://api.github.com/repos/unicode-org/cldr-json/contents/cldr-json"
  )

  private static func requiredURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
      preconditionFailure("Invalid supported upstream URL: \(string)")
    }
    return url
  }

  static func unicodeBaseURL(for version: String) -> URL {
    if (Int(version.split(separator: ".")[0]) ?? 0) >= 17 {
      return requiredURL("https://unicode.org/Public/\(version).0/emoji/")
    }
    return unicodeDirectoryURL.appending(path: version)
  }

  static func unicodePropertiesBaseURL(for version: String) -> URL {
    requiredURL("https://unicode.org/Public/\(version).0/ucd/emoji/")
  }

  static func cldrBaseURL(for tag: String) -> URL {
    requiredURL(
      "https://raw.githubusercontent.com/unicode-org/cldr-json/refs/tags/"
        + "\(tag)/cldr-json"
    )
  }

  static func cldrContentsURL(package packageName: String, directory: String, tag: String) -> URL {
    requiredURL(
      cldrContentsAPIBaseURL.absoluteString
        + "/\(packageName)/\(directory)?ref=\(tag)"
    )
  }
}

internal struct EmojiDataRelease: Equatable, Sendable {
  let unicodeEmojiVersion: String
  let cldrVersion: String
  let cldrTag: String

  var unicodeBaseURL: URL {
    EmojiDataSource.unicodeBaseURL(for: unicodeEmojiVersion)
  }

  var cldrBaseURL: URL {
    EmojiDataSource.cldrBaseURL(for: cldrTag)
  }
}

internal enum UnicodeReleaseResolver {
  internal static func version(fromEmojiTest data: Data) throws -> String {
    let text = String(decoding: data, as: UTF8.self)
    guard
      let line = text.split(whereSeparator: \.isNewline)
        .first(where: { $0.hasPrefix("# Version: ") }),
      let version = line.split(separator: " ").last,
      version.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
    else { throw ValidationError("Missing Unicode emoji release header.") }
    return String(version)
  }
}

internal enum CLDRReleaseResolver {
  internal static func latestTag(fromTagsJSON data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let tags = object as? [[String: Any]] else {
      throw ValidationError("Unable to resolve the latest CLDR JSON tag.")
    }

    let names = tags.compactMap { $0["name"] as? String }
      .filter {
        $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
      }
    guard let latest = names.max(by: isOrderedTag(_:lessThan:)) else {
      throw ValidationError("Unable to resolve the latest CLDR JSON tag.")
    }
    return latest
  }

  internal static func version(fromTag tag: String) -> String {
    tag.split(separator: ".").first.map(String.init) ?? tag
  }

  private static func isOrderedTag(_ lhs: String, lessThan rhs: String) -> Bool {
    let left = lhs.split(separator: ".").compactMap { Int($0) }
    let right = rhs.split(separator: ".").compactMap { Int($0) }
    let count = max(left.count, right.count)
    for index in 0..<count {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l != r {
        return l < r
      }
    }
    return false
  }

  internal static func localeIdentifiers(fromContentsJSON data: Data) throws -> [String] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let entries = object as? [[String: Any]] else {
      throw ValidationError("Unable to resolve CLDR annotation locale directories.")
    }

    return
      entries
      .compactMap { entry in
        guard entry["type"] as? String == "dir" else {
          return nil
        }
        return entry["name"] as? String
      }
      .sorted()
  }
}
