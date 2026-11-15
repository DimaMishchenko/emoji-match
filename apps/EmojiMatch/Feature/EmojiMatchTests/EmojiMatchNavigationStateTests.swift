import Foundation
import SwiftUI
import Testing

@testable import EmojiMatch

@Suite struct EmojiMatchNavigationStateTests {
  @Test func resetSelectionDefaultsToFirstItem() {
    var state = EmojiMatchNavigationState()
    let layout = makeLayout(rowCounts: [3])

    state.resetSelection(in: layout)

    #expect(state.selectedItemID == layout.items.first?.id)
    #expect(state.resolvedSelection(in: layout) == layout.items.first?.selection)
  }

  @Test func horizontalMovementClampsAtRowEdges() {
    var state = EmojiMatchNavigationState()
    let layout = makeLayout(rowCounts: [6, 6])

    state.selectItemID(layout.rows[0][5].id)
    let movedRight = state.move(.right, in: layout)
    #expect(!movedRight)
    #expect(state.selectedItemID == layout.rows[0][5].id)

    state.selectItemID(layout.rows[1][0].id)
    let movedLeft = state.move(.left, in: layout)
    #expect(!movedLeft)
    #expect(state.selectedItemID == layout.rows[1][0].id)
  }

  @Test func verticalMovementPreservesColumnAndClampsInPartialRow() {
    var state = EmojiMatchNavigationState()
    let layout = makeLayout(rowCounts: [6, 3])

    state.selectItemID(layout.rows[0][1].id)
    let movedDown = state.move(.down, in: layout)
    #expect(movedDown)
    #expect(state.selectedItemID == layout.rows[1][1].id)

    state.selectItemID(layout.rows[0][5].id)
    let movedDownToPartialRow = state.move(.down, in: layout)
    #expect(movedDownToPartialRow)
    #expect(state.selectedItemID == layout.rows[1][2].id)

    let movedUp = state.move(.up, in: layout)
    #expect(movedUp)
    #expect(state.selectedItemID == layout.rows[0][2].id)
  }

  @Test func verticalMovementCrossesIndependentVisualSectionsByRow() {
    var state = EmojiMatchNavigationState()
    let layout = makeLayout(rowCounts: [2, 6, 4])

    state.selectItemID(layout.rows[0][1].id)
    let movedToNextSection = state.move(.down, in: layout)
    #expect(movedToNextSection)
    #expect(state.selectedItemID == layout.rows[1][1].id)

    state.selectItemID(layout.rows[1][5].id)
    let movedToPartialSection = state.move(.down, in: layout)
    #expect(movedToPartialSection)
    #expect(state.selectedItemID == layout.rows[2][3].id)
  }

  @Test func clampSelectionFallsBackWhenTheCurrentItemDisappears() {
    var state = EmojiMatchNavigationState()
    let originalLayout = makeLayout(rowCounts: [4])
    let nextLayout = EmojiMatchNavigationLayout(rows: [Array(originalLayout.items.dropFirst(2))])

    state.selectItemID(originalLayout.items[1].id)
    state.clampSelection(in: nextLayout)

    #expect(state.selectedItemID == nextLayout.items.first?.id)
  }

  @Test func emptyLayoutsClearSelectionAndIgnoreMovement() {
    var state = EmojiMatchNavigationState()
    let layout = EmojiMatchNavigationLayout(rows: [])

    state.resetSelection(in: layout)
    #expect(state.selectedItemID == nil)
    let didMove = state.move(.right, in: layout)
    #expect(!didMove)
    #expect(state.resolvedSelection(in: layout) == nil)
  }

  @Test func arrowModifierPolicyPreservesTextEditingShortcuts() {
    #expect(EmojiMatchView.handlesArrowModifiers([]))
    #expect(EmojiMatchView.handlesArrowModifiers(.capsLock))
    #expect(EmojiMatchView.handlesArrowModifiers(.numericPad))
    #expect(!EmojiMatchView.handlesArrowModifiers(.shift))
    #expect(!EmojiMatchView.handlesArrowModifiers(.control))
    #expect(!EmojiMatchView.handlesArrowModifiers(.option))
    #expect(!EmojiMatchView.handlesArrowModifiers(.command))
  }
}

private func makeLayout(rowCounts: [Int]) -> EmojiMatchNavigationLayout {
  var index = 0
  let rows = rowCounts.map { count in
    (0..<count)
      .map { _ in
        defer { index += 1 }
        return EmojiMatchItem(
          id: "item-\(index)",
          selection: EmojiSelection(id: "emoji-\(index)", value: "\(index)"),
          accessibilityLabel: "item \(index)"
        )
      }
  }
  return EmojiMatchNavigationLayout(rows: rows)
}
