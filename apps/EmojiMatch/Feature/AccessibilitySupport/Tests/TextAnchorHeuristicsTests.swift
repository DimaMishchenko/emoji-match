import CoreFoundation
import Foundation
import Testing

@testable import AccessibilitySupport

@Suite struct TextAnchorHeuristicsTests {
  @Test func plausibleInsertionPointLineAcceptsReasonableValues() {
    #expect(FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(0))
    #expect(FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(42))
    #expect(
      FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(
        FocusedTextAnchorHeuristics.maximumPlausibleInsertionPointLine
      )
    )
  }

  @Test func plausibleInsertionPointLineRejectsBogusSentinels() {
    #expect(!FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(-1))
    #expect(!FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(.max))
  }

  @Test func candidateCharacterRangesIncludePreviousCharacterWhenPossible() {
    let ranges = FocusedTextAnchorHeuristics.candidateCharacterRanges(
      for: CFRange(location: 4, length: 0)
    )

    #expect(rangeDescriptions(ranges) == ["3:1", "4:1"])
  }

  @Test func candidateCharacterRangesAtDocumentStartSkipNegativeRange() {
    let ranges = FocusedTextAnchorHeuristics.candidateCharacterRanges(
      for: CFRange(location: 0, length: 0)
    )

    #expect(rangeDescriptions(ranges) == ["0:1"])
  }

  @Test func candidateCharacterRangesRejectUnknownSelection() {
    let ranges = FocusedTextAnchorHeuristics.candidateCharacterRanges(
      for: CFRange(location: kCFNotFound, length: 0)
    )

    #expect(ranges.isEmpty)
  }

  @Test func insertionIndexRejectsOutOfBoundsSelection() {
    let text = NSString(string: "hello")

    #expect(
      FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: CFRange(location: 99, length: 0)
      ) == nil
    )
    #expect(
      FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: CFRange(location: 2, length: 2)
      ) == 4
    )
  }

  @Test func malformedRangesAreRejectedWithoutOverflow() {
    for range in [
      CFRange(location: -2, length: 0), CFRange(location: 0, length: -1),
      CFRange(location: Int.max, length: 1), CFRange(location: 1, length: Int.max)
    ] {
      #expect(!FocusedTextAnchorHeuristics.isValidRange(range))
      #expect(FocusedTextAnchorHeuristics.candidateCharacterRanges(for: range).isEmpty)
      #expect(FocusedTextAnchorHeuristics.insertionIndex(in: "hello", for: range) == nil)
    }
  }

  @Test func selectedTextDoesNotProduceAdjacentCaretGuesses() {
    #expect(
      FocusedTextAnchorHeuristics.candidateCharacterRanges(
        for: CFRange(location: 2, length: 3)
      )
      .isEmpty)
  }

  @Test func zeroWidthCaretBoundsAreUsable() {
    #expect(
      FocusedTextAnchorHeuristics.isUsableTextBounds(
        CGRect(x: 10, y: 10, width: 0, height: 18)))
  }

  @Test func nonfiniteAndNegativeGeometryIsRejected() {
    for rect in [
      CGRect(x: CGFloat.nan, y: 0, width: 1, height: 18),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 18),
      CGRect(x: 0, y: 0, width: -1, height: 18),
      CGRect(x: 0, y: 0, width: 1, height: 0),
      CGRect(x: 0, y: 0, width: 1, height: -18)
    ] {
      #expect(!FocusedTextAnchorHeuristics.isUsableTextBounds(rect))
    }
  }

  @Test func insertionIndexRejectsUnknownSelection() {
    let text = NSString(string: "hello")

    #expect(
      FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: CFRange(location: kCFNotFound, length: 0)
      ) == nil
    )
  }

  @Test func lineStartRecognizesDocumentAndNewlineStarts() {
    let text = NSString(string: "hello\nworld")

    #expect(
      FocusedTextAnchorHeuristics.isAtLineStart(
        in: text,
        selectedTextRange: CFRange(location: 0, length: 0)
      )
    )
    #expect(
      FocusedTextAnchorHeuristics.isAtLineStart(
        in: text,
        selectedTextRange: CFRange(location: 6, length: 0)
      )
    )
    #expect(
      !FocusedTextAnchorHeuristics.isAtLineStart(
        in: text,
        selectedTextRange: CFRange(location: 7, length: 0)
      )
    )
  }

  @Test func visualLineIndexCollapsesTrailingStructuralNewlines() {
    #expect(FocusedTextAnchorHeuristics.visualLineIndex(in: "title") == 0)
    #expect(FocusedTextAnchorHeuristics.visualLineIndex(in: "title\n") == 1)
    #expect(FocusedTextAnchorHeuristics.visualLineIndex(in: "title\n\n") == 2)
    #expect(FocusedTextAnchorHeuristics.visualLineIndex(in: "title\n\n\n") == 2)
    #expect(FocusedTextAnchorHeuristics.visualLineIndex(in: "title\nbody\n") == 2)
  }

  @Test func horizontalInsetUsesLeadingAccessoryTrailingEdge() {
    #expect(
      FocusedTextAnchorHeuristics.horizontalInset(
        baseInset: 12,
        elementMinX: 20,
        leadingAccessoryTrailingEdge: 56
      ) == 44
    )
  }

  @Test func horizontalInsetCapsLargeAccessoryValues() {
    #expect(
      FocusedTextAnchorHeuristics.horizontalInset(
        baseInset: 12,
        elementMinX: 20,
        leadingAccessoryTrailingEdge: 200
      ) == FocusedTextAnchorHeuristics.maximumEstimatedAccessoryTextInset
    )
  }
}

private func rangeDescriptions(_ ranges: [CFRange]) -> [String] {
  ranges.map { "\($0.location):\($0.length)" }
}
