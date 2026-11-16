import SwiftUI

enum EmojiPickerMetrics {
  static let contentWidth: CGFloat = 320
  static let topBarHeight: CGFloat = 49.5
  static let scrollHeight: CGFloat = 386.5
  static let categoryBarHeight: CGFloat = 44
  static let searchHeight: CGFloat = 28
  static let actionSize: CGFloat = 27
  static let searchTopInset: CGFloat = 11
  static let searchHorizontalInset: CGFloat = 10
  static let headerControlSpacing: CGFloat = 8
  static let headerCloseSize: CGFloat = 28
  static let headerCloseInset = headerCloseSize + headerControlSpacing
  static let columnCount = 6
  static let emojiCellSize: CGFloat = 40
  static let emojiFontSize: CGFloat = 32
  static let categoryButtonSize: CGFloat = 24
  static let categorySymbolSize: CGFloat = 14
  static let searchFontSize: CGFloat = 13
  static let gridHorizontalInset: CGFloat = 8
  static let rowSpacing: CGFloat = 4
  static let sectionSpacing: CGFloat = 14
  static let selectionSize = CGSize(width: 56, height: 42)
  static let selectionOpacity = 0.35
  static let searchResultsTopInset: CGFloat = 4
  static let browseTopInset: CGFloat = 12
  static let categoryChevronWidth: CGFloat = 18.5

  static var browserHeight: CGFloat {
    scrollHeight + categoryBarHeight
  }

  static var expandedHeight: CGFloat {
    topBarHeight + browserHeight
  }
}
