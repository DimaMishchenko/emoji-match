import DesignSystem
import SwiftUI

enum EmojiPickerMetrics {
  static let contentWidth: CGFloat = 320
  static let topBarHeight: CGFloat = 49.5
  static let scrollHeight: CGFloat = 350.5
  static let categoryBarHeight: CGFloat = 44
  static let searchHeight: CGFloat = 28
  static let actionSize: CGFloat = 27
  static let searchTopInset: CGFloat = 11
  static let searchHorizontalInset: CGFloat = 10
  static let columnCount = 6
  static let emojiCellSize: CGFloat = 40
  static let emojiFontSize: CGFloat = 30
  static let categoryButtonSize: CGFloat = 24
  static let categorySymbolSize: CGFloat = 14
  static let searchFont: Font = .system(size: 13)
  static let gridHorizontalInset: CGFloat = .ds.spacing.xs
  static let rowSpacing: CGFloat = .ds.spacing.xxs

  static var browserHeight: CGFloat {
    scrollHeight + categoryBarHeight
  }

  static var expandedHeight: CGFloat {
    topBarHeight + browserHeight
  }
}
