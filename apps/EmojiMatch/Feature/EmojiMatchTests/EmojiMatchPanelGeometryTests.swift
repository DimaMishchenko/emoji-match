import CoreGraphics
import Testing

@testable import EmojiMatch

@Suite struct EmojiMatchPanelGeometryTests {
  @Test func zeroWidthCaretPreservesCoordinates() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 304, y: 173, width: 0, height: 14), primaryScreenHeight: 982)
        == CGRect(x: 304, y: 795, width: 0, height: 14))
  }

  @Test func displayAbovePrimaryUsesPrimaryBaseline() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 100, y: -500, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: 100, y: 1462, width: 1, height: 20))
  }

  @Test func displayLeftOfPrimaryPreservesNegativeX() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: -800, y: 200, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: -800, y: 762, width: 1, height: 20))
  }

  @Test func displayBelowPrimaryPreservesNegativeAppKitY() {
    #expect(
      EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: CGRect(x: 100, y: 1200, width: 1, height: 20), primaryScreenHeight: 982)
        == CGRect(x: 100, y: -238, width: 1, height: 20))
  }
}
