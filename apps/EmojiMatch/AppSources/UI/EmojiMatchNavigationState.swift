import Foundation

enum EmojiMatchNavigationDirection {
  case left
  case right
  case up
  case down
}

struct EmojiMatchNavigationState: Equatable, Sendable {
  private(set) var selectedItemID: String?

  mutating func selectItemID(_ selectedItemID: String?) {
    self.selectedItemID = selectedItemID
  }

  mutating func resetSelection(in layout: EmojiMatchNavigationLayout) {
    selectedItemID = layout.items.first?.id
  }

  mutating func clampSelection(in layout: EmojiMatchNavigationLayout) {
    guard !layout.items.isEmpty else {
      selectedItemID = nil
      return
    }

    guard let selectedItemID, layout.items.contains(where: { $0.id == selectedItemID }) else {
      selectedItemID = layout.items.first?.id
      return
    }
  }

  mutating func move(
    _ direction: EmojiMatchNavigationDirection,
    in layout: EmojiMatchNavigationLayout
  ) -> Bool {
    guard !layout.rows.isEmpty else {
      selectedItemID = nil
      return false
    }

    let currentPosition = layout.position(of: selectedItemID) ?? (row: 0, column: 0)
    let nextPosition = layout.position(
      moving: direction,
      from: currentPosition
    )
    let nextID = layout.rows[nextPosition.row][nextPosition.column].id
    let didMove = nextID != selectedItemID
    selectedItemID = nextID
    return didMove
  }

  func resolvedSelection(in layout: EmojiMatchNavigationLayout) -> EmojiSelection? {
    guard let selectedItemID else {
      return layout.items.first?.selection
    }

    return layout.items.first(where: { $0.id == selectedItemID })?.selection
      ?? layout.items.first?.selection
  }
}

struct EmojiMatchNavigationLayout: Equatable, Sendable {
  let rows: [[EmojiMatchItem]]

  var items: [EmojiMatchItem] {
    rows.flatMap { $0 }
  }

  init(rows: [[EmojiMatchItem]]) {
    self.rows = rows.filter { !$0.isEmpty }
  }

  init(items: [EmojiMatchItem], columnCount: Int) {
    guard columnCount > 0 else {
      self.init(rows: [])
      return
    }

    self.init(
      rows: stride(from: 0, to: items.count, by: columnCount)
        .map { start in
          Array(items[start..<min(start + columnCount, items.count)])
        }
    )
  }
}

private extension EmojiMatchNavigationLayout {
  func position(of itemID: String?) -> (row: Int, column: Int)? {
    guard let itemID else {
      return nil
    }

    for (rowIndex, row) in rows.enumerated() {
      if let columnIndex = row.firstIndex(where: { $0.id == itemID }) {
        return (rowIndex, columnIndex)
      }
    }

    return nil
  }

  func position(
    moving direction: EmojiMatchNavigationDirection,
    from position: (row: Int, column: Int)
  ) -> (row: Int, column: Int) {
    switch direction {
    case .left:
      return (position.row, max(0, position.column - 1))
    case .right:
      return (position.row, min(rows[position.row].count - 1, position.column + 1))
    case .up:
      let row = max(0, position.row - 1)
      return (row, min(position.column, rows[row].count - 1))
    case .down:
      let row = min(rows.count - 1, position.row + 1)
      return (row, min(position.column, rows[row].count - 1))
    }
  }
}
