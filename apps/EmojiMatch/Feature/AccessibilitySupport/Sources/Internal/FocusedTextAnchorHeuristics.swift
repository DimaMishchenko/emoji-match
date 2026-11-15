import CoreFoundation
import CoreGraphics
import Foundation

enum FocusedTextAnchorHeuristics {
  nonisolated static let defaultEstimatedLineHeight: CGFloat = 22
  nonisolated static let defaultEstimatedCharacterWidth: CGFloat = 8
  nonisolated static let estimatedTextHorizontalInset: CGFloat = 12
  nonisolated static let estimatedSearchFieldHorizontalInset: CGFloat = 44
  nonisolated static let estimatedAccessoryTextSpacing: CGFloat = 8
  nonisolated static let maximumEstimatedAccessoryTextInset: CGFloat = 80
  nonisolated static let estimatedTextVerticalInset: CGFloat = 8
  nonisolated static let maximumPlausibleInsertionPointLine = 100_000

  nonisolated static func isPlausibleInsertionPointLine(_ insertionPointLine: Int) -> Bool {
    insertionPointLine >= 0 && insertionPointLine <= maximumPlausibleInsertionPointLine
  }

  nonisolated static func insertionIndex(in text: NSString, for selectedTextRange: CFRange) -> Int?
  {
    guard isValidRange(selectedTextRange, textLength: text.length) else {
      return nil
    }

    return selectedTextRange.location + selectedTextRange.length
  }

  nonisolated static func isValidRange(_ range: CFRange, textLength: Int? = nil) -> Bool {
    guard range.location >= 0, range.length >= 0,
      range.location <= Int.max - range.length
    else {
      return false
    }

    return textLength.map { range.location + range.length <= $0 } ?? true
  }

  nonisolated static func candidateCharacterRanges(for selectedTextRange: CFRange) -> [CFRange] {
    guard isValidRange(selectedTextRange), selectedTextRange.length == 0 else {
      return []
    }

    var ranges: [CFRange] = []
    if selectedTextRange.location > 0 {
      ranges.append(CFRange(location: selectedTextRange.location - 1, length: 1))
    }
    if selectedTextRange.location < Int.max {
      ranges.append(CFRange(location: selectedTextRange.location, length: 1))
    }
    return ranges
  }

  nonisolated static func isUsableRect(_ rect: CGRect) -> Bool {
    isUsableTextBounds(rect) && rect.width > 0
  }

  nonisolated static func isUsableTextBounds(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width >= 0 && rect.size.height > 0
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  nonisolated static func isPlausibleTextBounds(
    _ bounds: CGRect,
    selectionRange: CFRange?,
    elementRect: CGRect?
  ) -> Bool {
    guard isUsableTextBounds(bounds) else {
      return false
    }
    guard let elementRect else {
      return true
    }
    guard isUsableRect(elementRect) else {
      return false
    }

    let tolerance: CGFloat = 2
    guard bounds.minX >= elementRect.minX - tolerance,
      bounds.maxX <= elementRect.maxX + tolerance,
      bounds.minY >= elementRect.minY - tolerance,
      bounds.maxY <= elementRect.maxY + tolerance
    else {
      return false
    }

    guard selectionRange?.length == 0 else {
      return true
    }
    return bounds.width <= max(defaultEstimatedCharacterWidth * 2, elementRect.width * 0.1)
  }

  nonisolated static func isAtLineStart(in text: NSString, selectedTextRange: CFRange) -> Bool {
    guard let insertionIndex = insertionIndex(in: text, for: selectedTextRange) else {
      return false
    }

    if insertionIndex == 0 {
      return true
    }

    return text.substring(with: NSRange(location: insertionIndex - 1, length: 1)) == "\n"
  }

  nonisolated static func newlineCount(in string: String) -> Int {
    string.reduce(into: 0) { result, character in
      if character == "\n" {
        result += 1
      }
    }
  }

  nonisolated static func visualLineIndex(in prefix: String) -> Int {
    let newlineCount = newlineCount(in: prefix)
    let trailingNewlineCount = prefix.reversed().prefix { $0 == "\n" }.count
    return max(newlineCount - max(trailingNewlineCount - 2, 0), 0)
  }

  nonisolated static func horizontalInset(
    baseInset: CGFloat,
    elementMinX: CGFloat,
    leadingAccessoryTrailingEdge: CGFloat?,
    accessorySpacing: CGFloat = estimatedAccessoryTextSpacing
  ) -> CGFloat {
    guard let leadingAccessoryTrailingEdge else {
      return baseInset
    }

    let accessoryInset = leadingAccessoryTrailingEdge - elementMinX + accessorySpacing
    return min(max(baseInset, accessoryInset), maximumEstimatedAccessoryTextInset)
  }
}
