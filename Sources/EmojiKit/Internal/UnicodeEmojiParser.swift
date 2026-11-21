import ArgumentParser
import Foundation

internal struct UnicodeEmojiParser {
  private struct RawEmojiRecord: Sendable {
    let id: String
    let value: String
    let group: String
    let subgroup: String
    let unicodeVersion: String
    let sortOrder: Int
    let fallbackName: String
  }

  private static let componentGroup = "Component"

  private static let skinToneByScalar: [String: GeneratedSkinTone] = [
    "1F3FB": .light,
    "1F3FC": .mediumLight,
    "1F3FD": .medium,
    "1F3FE": .mediumDark,
    "1F3FF": .dark
  ]

  internal static func parseEmojiTest(_ data: Data) throws -> [GeneratedBaseEmoji] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw ValidationError("Unable to decode emoji-test.txt as UTF-8.")
    }

    let records = try parseRawEmojiRecords(from: text)
    guard !records.isEmpty, Set(records.map(\.id)).count == records.count else {
      throw ValidationError("Unicode emoji records must be nonempty and have unique sequence IDs.")
    }
    return try collapseSkinToneVariants(in: records)
  }

  private static func parseRawEmojiRecords(from text: String) throws -> [RawEmojiRecord] {
    var emojis: [RawEmojiRecord] = []
    var currentGroup = ""
    var currentSubgroup = ""
    var sortOrder = 0

    for line in text.split(whereSeparator: \.isNewline) {
      let rawLine = String(line)

      if rawLine.hasPrefix("# group: ") {
        currentGroup = String(rawLine.dropFirst("# group: ".count))
        continue
      }

      if rawLine.hasPrefix("# subgroup: ") {
        currentSubgroup = String(rawLine.dropFirst("# subgroup: ".count))
        continue
      }

      guard let hashIndex = rawLine.firstIndex(of: "#")
      else {
        continue
      }

      let left = rawLine[..<hashIndex]
      let fields = left.split(separator: ";")
      guard fields.count == 2 else { continue }
      let status = fields[1].trimmingCharacters(in: .whitespaces)
      guard status == "fully-qualified" || status == "component" else { continue }
      let right = rawLine[rawLine.index(after: hashIndex)...]
      let scalars = left.split(separator: ";")[0]
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }

      let rightParts = String(right).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
      guard rightParts.count >= 3 else {
        throw ValidationError("Unsupported emoji-test.txt format.")
      }

      let unicodeScalars = try scalars.map { component -> Unicode.Scalar in
        guard let codePoint = UInt32(component, radix: 16), let scalar = Unicode.Scalar(codePoint)
        else {
          throw ValidationError("Invalid Unicode scalar in emoji-test.txt.")
        }
        return scalar
      }
      let value = String(String.UnicodeScalarView(unicodeScalars))
      guard value == String(rightParts[0]), !currentGroup.isEmpty, !currentSubgroup.isEmpty else {
        throw ValidationError("Invalid sequence or missing Unicode grouping in emoji-test.txt.")
      }
      guard let versionIndex = rightParts.firstIndex(where: { $0.hasPrefix("E") }) else {
        throw ValidationError("Missing Unicode version in emoji-test.txt.")
      }
      let versionToken = rightParts[versionIndex]
      guard versionToken.range(of: #"^E\d+\.\d+$"#, options: .regularExpression) != nil,
        versionIndex == 1, versionIndex + 1 < rightParts.count
      else {
        throw ValidationError("Invalid Unicode version or missing name in emoji-test.txt.")
      }
      let fallbackName = rightParts[(versionIndex + 1)...].joined(separator: " ")

      sortOrder += 1
      emojis.append(
        RawEmojiRecord(
          id: normalizeID(from: scalars),
          value: value,
          group: currentGroup,
          subgroup: currentSubgroup,
          unicodeVersion: String(versionToken.dropFirst()),
          sortOrder: sortOrder,
          fallbackName: fallbackName
        )
      )
    }

    return emojis
  }

  private static func collapseSkinToneVariants(
    in rawRecords: [RawEmojiRecord]
  ) throws -> [GeneratedBaseEmoji] {
    var logicalByID: [String: RawEmojiRecord] = [:]
    var idsBySequence: [String: String] = [:]
    var orderedLogicalIDs: [String] = []

    for record in rawRecords where !isSkinToneVariant(record) {
      logicalByID[record.id] = record
      orderedLogicalIDs.append(record.id)
      idsBySequence[presentationIndependentID(record.id)] = record.id
    }

    var variantsByID: [String: [GeneratedSkinToneVariant]] = [:]
    for record in rawRecords where isSkinToneVariant(record) {
      let strippedID = presentationIndependentID(strippedSkinToneID(from: record.id))
      guard
        let logicalID = idsBySequence[strippedID]
          ?? legacyBaseIDs[strippedID].flatMap({ logicalByID[$0] == nil ? nil : $0 })
      else {
        throw ValidationError("No canonical base for skin-tone sequence \(record.id)")
      }

      let variant = GeneratedSkinToneVariant(
        id: .init(rawValue: record.id),
        value: record.value,
        tones: skinTones(in: record.id)
      )
      variantsByID[logicalID, default: []].append(variant)
    }

    return orderedLogicalIDs.compactMap { id in
      guard let logical = logicalByID[id] else { return nil }
      let variants = variantsByID[id] ?? []
      return GeneratedBaseEmoji(
        id: logical.id,
        value: logical.value,
        group: logical.group,
        subgroup: logical.subgroup,
        unicodeVersion: logical.unicodeVersion,
        sortOrder: logical.sortOrder,
        skinToneSupport: skinToneSupport(for: variants),
        skinToneVariants: variants,
        fallbackName: logical.fallbackName
      )
    }
  }

  private static func isSkinToneVariant(_ record: RawEmojiRecord) -> Bool {
    record.group != componentGroup && !skinTones(in: record.id).isEmpty
  }

  private static let legacyBaseIDs: [String: String] = [
    "1FAF1-200D-1FAF2": "1F91D",
    "1F469-200D-1F91D-200D-1F469": "1F46D",
    "1F469-200D-1F91D-200D-1F468": "1F46B",
    "1F468-200D-1F91D-200D-1F468": "1F46C",
    "1F9D1-200D-2764-200D-1F48B-200D-1F9D1": "1F48F",
    "1F9D1-200D-2764-200D-1F9D1": "1F491",
    "1F9D1-200D-1F430-200D-1F9D1": "1F46F",
    "1F468-200D-1F430-200D-1F468": "1F46F-200D-2642-FE0F",
    "1F469-200D-1F430-200D-1F469": "1F46F-200D-2640-FE0F",
    "1F9D1-200D-1FAEF-200D-1F9D1": "1F93C",
    "1F468-200D-1FAEF-200D-1F468": "1F93C-200D-2642-FE0F",
    "1F469-200D-1FAEF-200D-1F469": "1F93C-200D-2640-FE0F"
  ]

  private static func presentationIndependentID(_ id: String) -> String {
    id.split(separator: "-").filter { $0 != "FE0F" }.joined(separator: "-")
  }

  private static func strippedSkinToneID(from id: String) -> String {
    id.split(separator: "-")
      .map(String.init)
      .filter { skinToneByScalar[$0] == nil }
      .joined(separator: "-")
  }

  private static func skinTones(in emojiID: String) -> [GeneratedSkinTone] {
    emojiID.split(separator: "-")
      .map(String.init)
      .compactMap { skinToneByScalar[$0] }
  }

  private static func skinToneSupport(
    for variants: [GeneratedSkinToneVariant]
  ) -> GeneratedSkinToneSupport {
    let maximumToneCount = variants.map { $0.tones.count }.max() ?? 0
    if maximumToneCount == 0 {
      return .none
    }
    return maximumToneCount == 1 ? .single : .multiple
  }

  internal static func normalizeID(from scalars: [String]) -> String {
    scalars.map { $0.uppercased() }.joined(separator: "-")
  }
}
